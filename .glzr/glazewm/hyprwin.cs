// hyprwin.exe: fast GlazeWM helpers (hypr-mac's window-cycle, quit-app, force-kill-window, scratchpad, unminimize).
// Talks to GlazeWM's IPC websocket directly; ~60 ms per key press instead of ~650 ms for a PowerShell script.
// Built by setup-windows.ps1 with the .NET Framework csc.exe that ships with Windows:
//   csc /nologo /target:winexe /r:System.Web.Extensions.dll /out:%USERPROFILE%\.glzr\glazewm\hyprwin.exe hyprwin.cs
// Usage:
//   hyprwin cycle next|prev   ALT+TAB / ALT+SHIFT+TAB: focus the next/previous window on this workspace (not minimized)
//   hyprwin quit              SUPER+Q: close every window of the focused window's app (it can still ask to save)
//   hyprwin kill              SUPER+SHIFT+W: force kill the focused window's app
//   hyprwin unminimize        SUPER+ALT+M: restore a minimized window, preferring one from this workspace
//   hyprwin scratchpad        SUPER+ALT+S: send the focused window to workspace S; on S, send it back
//   hyprwin switcher          stays running (GlazeWM startup): SUPER+Tab window switcher; see the Switcher section.
//                             It also stops SUPER alone opening Start; tapping SUPER+Alt opens it instead.
//                             Starting it again replaces the running one.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;

static class HyprWin
{
	[DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
	[DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

	static NetworkStream stream;
	static readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };

	static int Main(string[] args)
	{
		if (args.Length > 0 && args[0] == "switcher") return Switcher();
		try
		{
			var tcp = new TcpClient { NoDelay = true };
			tcp.Connect("127.0.0.1", 6123);
			stream = tcp.GetStream();
			Handshake();
			switch (args.Length > 0 ? args[0] : "")
			{
				case "cycle": Cycle(args.Length > 1 && args[1] == "prev" ? -1 : 1); break;
				case "quit": Quit(false); break;
				case "kill": Quit(true); break;
				case "unminimize": Unminimize(); break;
				case "scratchpad": Scratchpad(); break;
				default: return 2;
			}
			return 0;
		}
		catch (Exception) { return 1; }
	}

	static void Cycle(int step)
	{
		var workspace = FocusedWorkspace();
		if (workspace == null) return;
		var windows = new List<Dictionary<string, object>>();
		CollectWindows(workspace, windows, w => State(w) != "minimized");
		if (windows.Count < 2) return;
		int index = windows.FindIndex(w => true.Equals(w["hasFocus"]));
		var target = windows[((index + step) % windows.Count + windows.Count) % windows.Count];
		Command("focus --container-id " + target["id"]);
	}

	static void Quit(bool force)
	{
		var focused = Map(Map(Query("focused"))["focused"]);
		if (focused == null || (string)focused["type"] != "window") return;
		uint pid = ProcessId(focused);
		if (pid == 0) return;
		if (force)
		{
			try { Process.GetProcessById((int)pid).Kill(); return; }
			catch (Exception) { } // can't kill it (protected/elevated): close its windows instead
		}
		foreach (var w in List(Map(Query("windows"))["windows"]))
			if (ProcessId(Map(w)) == pid) Command("--id " + Map(w)["id"] + " close");
	}

	static void Unminimize()
	{
		var minimized = new List<Dictionary<string, object>>();
		var workspace = FocusedWorkspace();
		if (workspace != null) CollectWindows(workspace, minimized, w => State(w) == "minimized");
		if (minimized.Count == 0)
			foreach (var w in List(Map(Query("windows"))["windows"]))
				if (State(Map(w)) == "minimized") minimized.Add(Map(w));
		if (minimized.Count == 0) return;
		var id = minimized[minimized.Count - 1]["id"];
		Command("--id " + id + " toggle-minimized");
		Command("focus --container-id " + id);
	}

	static void Scratchpad()
	{
		var workspace = FocusedWorkspace();
		Command(workspace != null && (string)workspace["name"] == "S" ? "move --recent-workspace" : "move --workspace S");
	}

	// --- Switcher: SUPER+Tab, hypr-mac style ---
	// Holding SUPER, Tab opens the Windows Alt+Tab switcher (sent as Alt+Tab) and moves forward; tapping Shift, or Shift+Tab,
	// moves back; H/J/K/L move left/down/up/right; Q closes the highlighted window. Releasing SUPER picks the window.
	// It's a low-level keyboard hook rather than a PowerToys remap: PowerToys releases Alt on any other key, closing the switcher.

	delegate IntPtr KeyboardProc(int code, IntPtr message, IntPtr data);
	[DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, KeyboardProc proc, IntPtr module, uint thread);
	[DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
	[DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
	[DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
	[DllImport("user32.dll")] static extern int GetMessage(out MSG msg, IntPtr hwnd, uint min, uint max);
	[DllImport("user32.dll")] static extern bool PostThreadMessage(uint thread, uint message, IntPtr wParam, IntPtr lParam);
	[DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
	[DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
	[DllImport("user32.dll")] static extern IntPtr FindWindow(string className, string title);
	[DllImport("user32.dll")] static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
	[StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }

	const int VK_TAB = 0x09, VK_SHIFT = 0x10, VK_LEFT = 0x25, VK_UP = 0x26, VK_RIGHT = 0x27, VK_DOWN = 0x28, VK_DELETE = 0x2E;
	const int VK_H = 0x48, VK_J = 0x4A, VK_K = 0x4B, VK_L = 0x4C, VK_Q = 0x51;
	const int VK_LWIN = 0x5B, VK_RWIN = 0x5C, VK_LSHIFT = 0xA0, VK_RSHIFT = 0xA1, VK_MENU = 0x12, VK_LMENU = 0xA4, VK_RMENU = 0xA5, VK_DUMMY = 0xFF;
	const uint KEYEVENTF_EXTENDEDKEY = 0x1, KEYEVENTF_KEYUP = 0x2, WM_APP = 0x8000, WM_MODIFIER_DOWN = WM_APP + 1;
	const uint WM_SYSCOMMAND = 0x0112, SC_TASKLIST = 0xF130;
	// PowerToys' shortcut flag: PowerToys leaves keys sent with it alone, and this hook skips them too.
	const long OurFlag = 0x101;

	static KeyboardProc keyboardProc = OnKey;
	static IntPtr keyboardHook;
	static uint mainThread;
	static bool active, shiftTap, shiftTapUsed;
	static bool chordHeld, chordClean;
	static int keySeq;

	static int Switcher()
	{
		// Replace a running instance (e.g. after a rebuild): signal it to exit, then take over.
		var quit = new System.Threading.EventWaitHandle(false, System.Threading.EventResetMode.AutoReset, "hyprwin-switcher-quit");
		var single = new System.Threading.Mutex(false, "hyprwin-switcher");
		quit.Set();
		try { if (!single.WaitOne(3000)) return 1; }
		catch (System.Threading.AbandonedMutexException) { }
		quit.Reset();
		new System.Threading.Thread(() => { quit.WaitOne(); Environment.Exit(0); }) { IsBackground = true }.Start();

		mainThread = GetCurrentThreadId();
		Hook();
		MSG msg;
		while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0)
		{
			if (msg.message == WM_APP) Hook();
			else if (msg.message == WM_MODIFIER_DOWN)
			{
				// Check the system's key state once the key has reached it (PowerToys may have swapped Alt and Win).
				System.Threading.Thread.Sleep(10);
				if (!chordHeld && (int)msg.wParam == keySeq && SuperHeld() && AltHeld()) chordHeld = chordClean = true;
			}
		}
		return 0;
	}

	static void Hook()
	{
		// The newest low-level hook runs first. Re-hook each time the switcher opens so Shift/Tab/Q/HJKL reach this hook
		// before PowerToys (which re-hooks when its layout reloads) turns them into its own shortcuts.
		if (keyboardHook != IntPtr.Zero) UnhookWindowsHookEx(keyboardHook);
		const int WH_KEYBOARD_LL = 13;
		keyboardHook = SetWindowsHookEx(WH_KEYBOARD_LL, keyboardProc, GetModuleHandle(null), 0);
	}

	static IntPtr OnKey(int code, IntPtr message, IntPtr data)
	{
		if (code < 0 || Marshal.ReadInt64(data, 16) == OurFlag) return CallNextHookEx(IntPtr.Zero, code, message, data);
		int vk = Marshal.ReadInt32(data);
		bool up = (Marshal.ReadInt32(data, 8) & 0x80) != 0;
		bool swallow = active ? WhileOpen(vk, up) : vk == VK_TAB && !up && SuperHeld() && Open();
		if (!active && !swallow) StartMenuKey(vk, up);
		return swallow ? (IntPtr)1 : CallNextHookEx(IntPtr.Zero, code, message, data);
	}

	// SUPER is whatever the system currently sees as Win (PowerToys may have remapped physical Alt to it).
	static bool SuperHeld() { return (GetAsyncKeyState(VK_LWIN) | GetAsyncKeyState(VK_RWIN)) < 0; }
	static bool AltHeld() { return GetAsyncKeyState(VK_MENU) < 0; }

	// SUPER's release opens Start whenever a SUPER bind swallowed its key, so mask every release with the dummy key.
	// Start opens instead when SUPER+Alt is released with no other key pressed during it.
	static void StartMenuKey(int vk, bool up)
	{
		if (vk != VK_LWIN && vk != VK_RWIN && vk != VK_MENU && vk != VK_LMENU && vk != VK_RMENU)
		{
			if (!up) { keySeq++; chordClean = false; }
			return;
		}
		if (!up) { PostThreadMessage(mainThread, WM_MODIFIER_DOWN, (IntPtr)keySeq, IntPtr.Zero); return; }
		if (chordHeld && chordClean) PostMessage(FindWindow("Shell_TrayWnd", null), WM_SYSCOMMAND, (IntPtr)SC_TASKLIST, IntPtr.Zero);
		chordHeld = false;
		if (SuperHeld()) Tap(VK_DUMMY);
	}

	static bool Open()
	{
		// Swap the held Win for Alt (the dummy key stops Win's release from opening Start), then Alt+Tab.
		Key(VK_DUMMY, false); Key(VK_DUMMY, true);
		if (GetAsyncKeyState(VK_LWIN) < 0) Key(VK_LWIN, true);
		if (GetAsyncKeyState(VK_RWIN) < 0) Key(VK_RWIN, true);
		Key(VK_LMENU, false);
		Tap(VK_TAB);
		active = true;
		shiftTap = false;
		PostThreadMessage(mainThread, WM_APP, IntPtr.Zero, IntPtr.Zero);
		return true;
	}

	static bool WhileOpen(int vk, bool up)
	{
		switch (vk)
		{
			case VK_LWIN:
			case VK_RWIN:
				// Win is already released as far as the system knows: swallow its repeats, and its release picks the window.
				if (up) { Key(VK_LMENU, true); active = false; }
				return true;
			case VK_SHIFT:
			case VK_LSHIFT:
			case VK_RSHIFT:
				if (!up && !shiftTap && (GetAsyncKeyState(VK_SHIFT) < 0)) return false; // held since before the switcher opened
				if (!up) { if (!shiftTap) { shiftTap = true; shiftTapUsed = false; } return true; }
				if (!shiftTap) return false;
				shiftTap = false;
				if (!shiftTapUsed) Back();
				return true;
			case VK_TAB:
				if (!up) { if (shiftTap) { Back(); shiftTapUsed = true; } else Tap(VK_TAB); }
				return true;
			case VK_H: if (!up) Tap(VK_LEFT, true); return true;
			case VK_J: if (!up) Tap(VK_DOWN, true); return true;
			case VK_K: if (!up) Tap(VK_UP, true); return true;
			case VK_L: if (!up) Tap(VK_RIGHT, true); return true;
			case VK_Q: if (!up) Tap(VK_DELETE, true); return true;
			default: return false;
		}
	}

	static void Back() { Key(VK_LSHIFT, false); Tap(VK_TAB); Key(VK_LSHIFT, true); }

	static void Tap(int vk, bool extended = false) { Key(vk, false, extended); Key(vk, true, extended); }

	static void Key(int vk, bool up, bool extended = false)
	{
		keybd_event((byte)vk, 0, (up ? KEYEVENTF_KEYUP : 0) | (extended ? KEYEVENTF_EXTENDEDKEY : 0), new UIntPtr((ulong)OurFlag));
	}
	// --- GlazeWM data ---

	static Dictionary<string, object> FocusedWorkspace()
	{
		foreach (var w in List(Map(Query("workspaces"))["workspaces"]))
			if (true.Equals(Map(w)["hasFocus"])) return Map(w);
		return null;
	}

	static void CollectWindows(Dictionary<string, object> container, List<Dictionary<string, object>> into, Predicate<Dictionary<string, object>> keep)
	{
		foreach (var c in List(container["children"]))
		{
			var child = Map(c);
			if ((string)child["type"] == "window") { if (keep(child)) into.Add(child); }
			else if (child.ContainsKey("children")) CollectWindows(child, into, keep);
		}
	}

	static string State(Dictionary<string, object> window) { return (string)Map(window["state"])["type"]; }

	static uint ProcessId(Dictionary<string, object> window)
	{
		uint pid;
		GetWindowThreadProcessId(new IntPtr(Convert.ToInt64(window["handle"])), out pid);
		return pid;
	}

	static Dictionary<string, object> Map(object o) { return o as Dictionary<string, object>; }
	static IEnumerable List(object o) { return (o as IEnumerable) ?? new object[0]; }

	// --- IPC: a minimal websocket client (ClientWebSocket alone adds ~45 ms of startup) ---

	static object Query(string what)
	{
		var response = Map(json.DeserializeObject(Request("query " + what)));
		return response["data"];
	}

	static void Command(string command) { Request("command " + command); }

	static string Request(string message)
	{
		Send(message);
		while (true)
		{
			var text = Receive();
			// Skip anything that isn't the reply to this message (e.g. event subscriptions).
			if (text.Contains("\"client_response\"")) return text;
		}
	}

	static void Handshake()
	{
		var request = Encoding.ASCII.GetBytes("GET / HTTP/1.1\r\nHost: 127.0.0.1:6123\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
			"Sec-WebSocket-Key: aHlwcndpbmh5cHJ3aW4hIQ==\r\nSec-WebSocket-Version: 13\r\n\r\n");
		stream.Write(request, 0, request.Length);
		for (int newlines = 0; newlines < 4;)
		{
			int b = stream.ReadByte();
			if (b < 0) throw new IOException("GlazeWM closed the connection");
			newlines = b == '\r' || b == '\n' ? newlines + 1 : 0;
		}
	}

	static void Send(string message)
	{
		var payload = Encoding.UTF8.GetBytes(message);
		var frame = new MemoryStream();
		frame.WriteByte(0x81); // final text frame
		if (payload.Length < 126) frame.WriteByte((byte)(0x80 | payload.Length));
		else { frame.WriteByte(0x80 | 126); frame.WriteByte((byte)(payload.Length >> 8)); frame.WriteByte((byte)payload.Length); }
		frame.Write(new byte[4], 0, 4); // zero mask key: client frames must be masked, and XOR with 0 is a no-op
		frame.Write(payload, 0, payload.Length);
		var bytes = frame.ToArray();
		stream.Write(bytes, 0, bytes.Length);
	}

	static string Receive()
	{
		var message = new MemoryStream();
		while (true)
		{
			var header = Read(2);
			long length = header[1] & 0x7F;
			if (length == 126) { var ext = Read(2); length = (ext[0] << 8) | ext[1]; }
			else if (length == 127) { var ext = Read(8); length = 0; foreach (var b in ext) length = (length << 8) | b; }
			var payload = Read((int)length);
			int opcode = header[0] & 0x0F;
			if (opcode == 0x8) throw new IOException("GlazeWM closed the connection");
			if (opcode == 0x0 || opcode == 0x1 || opcode == 0x2) message.Write(payload, 0, payload.Length);
			if ((header[0] & 0x80) != 0 && opcode < 0x8) return Encoding.UTF8.GetString(message.ToArray());
		}
	}

	static byte[] Read(int count)
	{
		var buffer = new byte[count];
		for (int offset = 0; offset < count;)
		{
			int n = stream.Read(buffer, offset, count - offset);
			if (n <= 0) throw new IOException("GlazeWM closed the connection");
			offset += n;
		}
		return buffer;
	}
}
