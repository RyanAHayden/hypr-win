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
//   hyprwin togglescratchpad  SUPER+S: go to workspace S; on S, go back to the previous workspace
//   hyprwin togglezebar       SUPER+SHIFT+SPACE: show / hide the Zebar bar
//   hyprwin focuslock         SUPER+SHIFT+O: toggle focus_lock.py's lock (stops focus following the cursor)
//   hyprwin scale up|down     SUPER+/ / SUPER+ALT+/: display scaling of the focused window's monitor, bigger / more space
//   hyprwin launch <file> [args]  start a program through the shell; the logon task starts GlazeWM with it
//   hyprwin togglesplit       SUPER+\: flip the split between the focused window and its sibling (Hyprland's togglesplit)
//   hyprwin fullscreen [max]  toggle fullscreen (or maximized), returning the window to its old spot
//   hyprwin dwindle           stays running (GlazeWM startup): new windows split the focused one along its longer side
//   hyprwin switcher          stays running (GlazeWM startup): SUPER+Tab window switcher; see the Switcher section.
//                             It also stops SUPER alone opening Start; tapping SUPER+Alt opens it instead.
//                             SUPER+C / SUPER+V copy / paste everywhere; SUPER+Ctrl+V opens clipboard history.
//                             SUPER+F / SUPER+ALT+F run fullscreen max / fullscreen without starting a process.
//                             The switcher also runs every bind above without starting a process (~100 ms each);
//                             GlazeWM's binds for them only run if the switcher isn't.
//                             Starting either again replaces the running one.
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
		if (args.Length > 0 && args[0] == "togglezebar") { ToggleZebar(); return 0; }
		if (args.Length > 0 && args[0] == "focuslock") { ToggleFocusLock(); return 0; }
		if (args.Length > 0 && args[0] == "scale") { ScaleDisplay(args.Length > 1 && args[1] == "down" ? -1 : 1); return 0; }
		// GlazeWM has uiAccess, which only the shell's launch path honours: started directly (as by Task Scheduler) it fails.
		if (args.Length > 1 && args[0] == "launch")
		{
			Process.Start(new ProcessStartInfo(args[1], string.Join(" ", args, 2, args.Length - 2)) { UseShellExecute = true });
			return 0;
		}
		try
		{
			Connect();
			switch (args.Length > 0 ? args[0] : "")
			{
				case "cycle": Cycle(args.Length > 1 && args[1] == "prev" ? -1 : 1); break;
				case "quit": Quit(false); break;
				case "kill": Quit(true); break;
				case "unminimize": Unminimize(); break;
				case "scratchpad": Scratchpad(); break;
				case "togglescratchpad": ToggleScratchpad(); break;
				case "togglesplit": ToggleSplit(); break;
				case "fullscreen": Fullscreen(args.Length > 1 && args[1] == "max"); break;
				case "dwindle": return Dwindle();
				default: return 2;
			}
			return 0;
		}
		catch (Exception) { return 1; }
	}

	static void Connect()
	{
		var tcp = new TcpClient { NoDelay = true };
		tcp.Connect("127.0.0.1", 6123);
		stream = tcp.GetStream();
		Handshake();
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

	static void ToggleScratchpad()
	{
		var workspace = FocusedWorkspace();
		Command(workspace != null && (string)workspace["name"] == "S" ? "focus --recent-workspace" : "focus --workspace S");
	}

	delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);
	[DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
	[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr window, StringBuilder text, int count);
	[DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
	[DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr window, int command);

	static void ToggleZebar()
	{
		var zebar = new HashSet<uint>();
		foreach (var p in Process.GetProcessesByName("zebar")) zebar.Add((uint)p.Id);
		var bars = new List<IntPtr>();
		EnumWindows((window, _) =>
		{
			uint pid;
			GetWindowThreadProcessId(window, out pid);
			var title = new StringBuilder(512);
			if (zebar.Contains(pid) && GetWindowText(window, title, title.Capacity) > 0
				&& title.ToString().EndsWith(" / bar", StringComparison.OrdinalIgnoreCase)) bars.Add(window);
			return true;
		}, IntPtr.Zero);
		bool show = bars.Exists(w => !IsWindowVisible(w));
		foreach (var w in bars) ShowWindowAsync(w, show ? 5 : 0);
	}

	// --- Display scaling: the undocumented DisplayConfig DPI calls Settings > Display uses ---
	[DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
	[DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint paths, byte[] pathArray, ref uint modes, byte[] modeArray, IntPtr topology);
	[DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(byte[] packet);
	[DllImport("user32.dll")] static extern int DisplayConfigSetDeviceInfo(byte[] packet);
	[DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
	[DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
	[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr monitor, byte[] info);

	// Steps the scale of the focused window's monitor through Windows' list (100%, 125%, ...) by one, within its range.
	static void ScaleDisplay(int step)
	{
		// MONITORINFOEX: cbSize, rcMonitor, rcWork, dwFlags, then the device name (\\.\DISPLAYn) at byte 40.
		var monitorInfo = new byte[104];
		BitConverter.GetBytes(monitorInfo.Length).CopyTo(monitorInfo, 0);
		if (!GetMonitorInfo(MonitorFromWindow(GetForegroundWindow(), 2), monitorInfo)) return;
		string device = Encoding.Unicode.GetString(monitorInfo, 40, 64).TrimEnd('\0');

		const uint QDC_ONLY_ACTIVE_PATHS = 2;
		const int PathSize = 72, ModeSize = 64;
		uint pathCount, modeCount;
		if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out pathCount, out modeCount) != 0) return;
		var paths = new byte[pathCount * PathSize];
		var modes = new byte[modeCount * ModeSize];
		if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero) != 0) return;
		for (int i = 0; i < pathCount; i++)
		{
			// A path starts with its source: adapter LUID (8 bytes), then source id.
			var adapter = new byte[12];
			Array.Copy(paths, i * PathSize, adapter, 0, 12);
			var name = DeviceInfo(1, 84, adapter); // source name: GDI device name at byte 20
			if (name == null || Encoding.Unicode.GetString(name, 20, 64).TrimEnd('\0') != device) continue;
			var dpi = DeviceInfo(-3, 32, adapter); // DPI scale: min, current, max steps from the recommended one
			if (dpi == null) return;
			int min = BitConverter.ToInt32(dpi, 20), current = BitConverter.ToInt32(dpi, 24), max = BitConverter.ToInt32(dpi, 28);
			int next = Math.Max(min, Math.Min(max, current + step));
			if (next == current) return;
			var set = Packet(-4, 24, adapter);
			BitConverter.GetBytes(next).CopyTo(set, 20);
			DisplayConfigSetDeviceInfo(set);
			return;
		}
	}

	// DISPLAYCONFIG_DEVICE_INFO_HEADER: type, size, adapter LUID and source id; the rest of the packet follows it.
	static byte[] Packet(int type, int size, byte[] adapterAndSource)
	{
		var packet = new byte[size];
		BitConverter.GetBytes(type).CopyTo(packet, 0);
		BitConverter.GetBytes(size).CopyTo(packet, 4);
		adapterAndSource.CopyTo(packet, 8);
		return packet;
	}

	static byte[] DeviceInfo(int type, int size, byte[] adapterAndSource)
	{
		var packet = Packet(type, size, adapterAndSource);
		return DisplayConfigGetDeviceInfo(packet) == 0 ? packet : null;
	}

	// focus_lock.py --service watches this file for a new revision.
	static void ToggleFocusLock()
	{
		var file = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), @".glzr\glazewm\focus-lock.json");
		Dictionary<string, object> state = null;
		try { state = Map(json.DeserializeObject(File.ReadAllText(file))); }
		catch (Exception) { }
		bool locked = state != null && true.Equals(state["locked"]);
		int revision = state != null && state.ContainsKey("revision") ? Convert.ToInt32(state["revision"]) : 0;
		var temporary = Path.ChangeExtension(file, ".tmp");
		File.WriteAllText(temporary, json.Serialize(new Dictionary<string, object> { { "locked", !locked }, { "revision", revision + 1 } }));
		if (File.Exists(file)) File.Replace(temporary, file, null);
		else File.Move(temporary, file);
	}

	static void ToggleSplit()
	{
		var focused = Map(Map(Query("focused"))["focused"]);
		if (focused == null || (string)focused["type"] != "window" || State(focused) != "tiling") return;
		var id = (string)focused["id"];
		var parent = Unwrap(id);
		if (parent == null) return;
		var children = TilingChildren(parent);
		if (children.Count < 2) return;
		if ((string)parent["type"] == "workspace" && children.Count == 2)
		{
			Command("--id " + parent["id"] + " toggle-tiling-direction");
			Command("wm-redraw");
			return;
		}
		int index = children.FindIndex(c => id.Equals(c["id"]));
		bool horizontal = (string)parent["tilingDirection"] == "horizontal";
		int pair = PairOf(children, index);
		var other = SoleWindow(children[pair]);
		// GlazeWM can't move a group of windows, so it can't be wrapped together with this window.
		if (other == null && children.Count > 2) return;
		string otherId = other == null ? null : (string)other["id"];
		string firstId = index < pair ? id : otherId, secondId = index < pair ? otherId : id;
		double firstShare = TilingSize(children[Math.Min(index, pair)]), secondShare = TilingSize(children[Math.Max(index, pair)]);
		if (otherId != null) Unwrap(otherId);
		if (children.Count == 2)
		{
			// Flipped, the split would tile the same way as its parent, which GlazeWM flattens: move the windows into the parent.
			double size = TilingSize(parent);
			bool moveFirst = otherId == null && index < pair;
			Command("--id " + (moveFirst ? firstId : secondId) + " move --direction " + (horizontal ? (moveFirst ? "up" : "down") : (moveFirst ? "left" : "right")));
			if (otherId != null) Unwrap(firstId);
			// Moving in took space from every window in the parent; give it back.
			if (otherId == null) Resize(id, size * (index < pair ? firstShare : secondShare), !horizontal);
			else ResizePair(firstId, secondId, size * firstShare, size * secondShare, !horizontal);
		}
		else
		{
			// GlazeWM can't flip a split: wrap the first window in a split running the other way, then move the second into it.
			Command("--id " + firstId + " toggle-tiling-direction");
			Command("--id " + secondId + " move --direction " + (horizontal ? "left" : "up"));
			Resize(id, firstShare + secondShare, horizontal);
		}
		Command("focus --container-id " + id);
	}

	// GlazeWM flattens a split into a parent that tiles the same way, so a child's pair is the neighbour closest in size.
	static int PairOf(List<Dictionary<string, object>> children, int index)
	{
		int pair = -1;
		foreach (int i in new[] { index - 1, index + 1 })
			if (i >= 0 && i < children.Count
				&& (pair < 0 || Math.Abs(TilingSize(children[i]) - TilingSize(children[index])) < Math.Abs(TilingSize(children[pair]) - TilingSize(children[index]))))
				pair = i;
		return pair;
	}

	// GlazeWM returns a window to its old split, but a single-window split dwindle wrapped it in is gone by then.
	static void Fullscreen(bool maximized)
	{
		var focused = Map(Map(Query("focused"))["focused"]);
		if (focused == null || (string)focused["type"] != "window") return;
		var id = (string)focused["id"];
		if (State(focused) == "tiling") Unwrap(id);
		Command("--id " + id + " toggle-fullscreen" + (maximized ? " --maximized" : ""));
	}

	// Resize the window's container that tiles along the given axis to a share of its parent.
	static void Resize(string id, double share, bool horizontal)
	{
		var path = PathTo(id);
		if (path == null) return;
		int i = AxisNode(path, horizontal);
		if (i == 0) return;
		double length = Convert.ToDouble(path[path.Count - 1][horizontal ? "width" : "height"]);
		int delta = (int)Math.Round(length * (share / TilingSize(path[i]) - 1));
		if (Math.Abs(delta) > 1) Command("--id " + id + " resize --" + (horizontal ? "width " : "height ") + (delta > 0 ? "+" : "") + delta + "px");
	}

	// The window's ancestor (or the window) whose parent tiles along the axis: what GlazeWM resizes along it.
	static int AxisNode(List<Dictionary<string, object>> path, bool horizontal)
	{
		int i = path.Count - 1;
		while (i > 0 && Direction(path[i - 1]) != (horizontal ? "horizontal" : "vertical")) i--;
		return i;
	}

	// Resizing a container moves every sibling, the other window included, so one pass of two resizes can't land both.
	// Simulate GlazeWM's resize to find the first size that leaves both on target once the second is resized.
	static void ResizePair(string firstId, string secondId, double firstShare, double secondShare, bool horizontal)
	{
		var path = PathTo(firstId);
		int node = path == null ? 0 : AxisNode(path, horizontal);
		if (node == 0) return;
		var siblings = TilingChildren(path[node - 1]);
		var sizes = siblings.ConvertAll(TilingSize).ToArray();
		int first = siblings.FindIndex(c => path[node]["id"].Equals(c["id"]));
		int second = siblings.FindIndex(c => SoleWindow(c) != null && secondId.Equals(SoleWindow(c)["id"]));
		double size = firstShare;
		if (first >= 0 && second >= 0)
		{
			double low = MinTilingSize, high = 1;
			for (int n = 0; n < 40; n++)
			{
				size = (low + high) / 2;
				if (SimulateResize(SimulateResize(sizes, first, size), second, secondShare)[first] < firstShare) low = size;
				else high = size;
			}
		}
		Resize(firstId, size, horizontal);
		Resize(secondId, secondShare, horizontal);
	}

	// GlazeWM's resize_tiling_container: siblings give up the change in proportion to their size above the minimum.
	const double MinTilingSize = 0.01;
	static double[] SimulateResize(double[] sizes, int index, double target)
	{
		var result = (double[])sizes.Clone();
		target = Math.Max(MinTilingSize, Math.Min(target, 1 - MinTilingSize * (sizes.Length - 1)));
		double delta = target - sizes[index], available = 0;
		for (int k = 0; k < sizes.Length; k++) if (k != index) available += sizes[k] - MinTilingSize;
		for (int k = 0; k < sizes.Length; k++) if (k != index) result[k] -= delta * (sizes[k] - MinTilingSize) / available;
		result[index] = target;
		return result;
	}

	static string Direction(Dictionary<string, object> container)
	{
		object direction;
		container.TryGetValue("tilingDirection", out direction);
		return direction as string;
	}

	// Dwindle leaves windows wrapped in single-window splits; toggling an only child flattens its split.
	static Dictionary<string, object> Unwrap(string id)
	{
		for (int i = 0; i < 10; i++)
		{
			var parent = ParentOf(id);
			if (parent == null || (string)parent["type"] != "split" || TilingChildren(parent).Count != 1) return parent;
			Command("--id " + id + " toggle-tiling-direction");
		}
		return null;
	}

	static Dictionary<string, object> SoleWindow(Dictionary<string, object> container)
	{
		while ((string)container["type"] == "split")
		{
			var children = TilingChildren(container);
			if (children.Count != 1) return null;
			container = children[0];
		}
		return container;
	}

	static double TilingSize(Dictionary<string, object> container) { return Convert.ToDouble(container["tilingSize"]); }

	static List<Dictionary<string, object>> TilingChildren(Dictionary<string, object> container)
	{
		var children = new List<Dictionary<string, object>>();
		foreach (var c in List(container["children"]))
		{
			var type = (string)Map(c)["type"];
			if (type == "split" || (type == "window" && State(Map(c)) == "tiling")) children.Add(Map(c));
		}
		return children;
	}

	static Dictionary<string, object> ParentOf(string id)
	{
		var path = PathTo(id);
		return path != null && path.Count > 1 ? path[path.Count - 2] : null;
	}

	// The containers from the workspace down to the given one.
	static List<Dictionary<string, object>> PathTo(string id)
	{
		foreach (var w in List(Map(Query("workspaces"))["workspaces"]))
		{
			var path = new List<Dictionary<string, object>>();
			if (FindPath(Map(w), id, path)) return path;
		}
		return null;
	}

	static bool FindPath(Dictionary<string, object> container, string id, List<Dictionary<string, object>> path)
	{
		path.Add(container);
		if (id.Equals(container["id"])) return true;
		object children;
		container.TryGetValue("children", out children);
		foreach (var c in List(children))
			if (FindPath(Map(c), id, path)) return true;
		path.RemoveAt(path.Count - 1);
		return false;
	}

	// --- Dwindle: like Hyprland's dwindle layout, the next window splits the focused one along its longer side ---

	static int Dwindle()
	{
		if (!TakeOver("hyprwin-dwindle")) return 1;
		Send("sub --events focus_changed window_managed window_unmanaged");
		while (true)
		{
			if (!Receive().Contains("\"event_subscription\"")) continue;
			var focused = Map(Map(Query("focused"))["focused"]);
			if (focused == null || (string)focused["type"] != "window" || State(focused) != "tiling") continue;
			// Changing splits would lose the spot GlazeWM returns a fullscreen window to.
			var path = PathTo((string)focused["id"]);
			if (path == null) continue;
			bool hasFullscreen = false;
			foreach (var c in List(path[0]["children"]))
				if ((string)Map(c)["type"] == "window" && State(Map(c)) == "fullscreen") hasFullscreen = true;
			if (hasFullscreen) continue;
			bool wide = Convert.ToDouble(focused["width"]) >= Convert.ToDouble(focused["height"]);
			Command("--id " + focused["id"] + " set-tiling-direction " + (wide ? "horizontal" : "vertical"));
		}
	}

	static System.Threading.Mutex instance;

	static bool IsElevated()
	{
		return new System.Security.Principal.WindowsPrincipal(System.Security.Principal.WindowsIdentity.GetCurrent())
			.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
	}

	static bool RunTask(string name)
	{
		try
		{
			var info = new ProcessStartInfo("schtasks.exe", "/run /tn \"" + name + "\"") { CreateNoWindow = true, UseShellExecute = false };
			using (var process = Process.Start(info)) return process.WaitForExit(5000) && process.ExitCode == 0;
		}
		catch (Exception) { return false; }
	}

	// Replace a running instance (e.g. after a rebuild): signal it to exit, then take over.
	static bool TakeOver(string name)
	{
		var quit = new System.Threading.EventWaitHandle(false, System.Threading.EventResetMode.AutoReset, name + "-quit");
		instance = new System.Threading.Mutex(false, name);
		quit.Set();
		try { if (!instance.WaitOne(3000)) return false; }
		catch (System.Threading.AbandonedMutexException) { }
		quit.Reset();
		new System.Threading.Thread(() => { quit.WaitOne(); Environment.Exit(0); }) { IsBackground = true }.Start();
		return true;
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
	const int VK_H = 0x48, VK_J = 0x4A, VK_K = 0x4B, VK_L = 0x4C, VK_Q = 0x51, VK_C = 0x43, VK_V = 0x56, VK_F = 0x46, VK_INSERT = 0x2D;
	const int VK_W = 0x57, VK_M = 0x4D, VK_S = 0x53, VK_O = 0x4F, VK_SPACE = 0x20, VK_BACKSLASH = 0xDC, VK_SLASH = 0xBF, VK_F13 = 0x7C, VK_F14 = 0x7D;
	const int VK_CONTROL = 0x11, VK_LCONTROL = 0xA2, VK_RCONTROL = 0xA3;
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
	static int keySeq, clipboardKey, wmKey;
	static readonly System.Collections.Concurrent.BlockingCollection<Action> jobs = new System.Collections.Concurrent.BlockingCollection<Action>();

	static int Switcher()
	{
		// A normal process's hook and keys don't reach elevated windows (so SUPER opened Start over them): hand over to the
		// elevated copy setup-elevated-windows.ps1 registers, if there is one.
		if (!IsElevated() && RunTask("Ryha hyprwin switcher")) return 0;
		if (!TakeOver("hyprwin-switcher")) return 1;

		// GlazeWM commands from the hook run here, on one connection kept open (reconnecting if GlazeWM restarted).
		new System.Threading.Thread(() =>
		{
			// Connect and run the JSON code once now, so the first key press doesn't pay for it (~150 ms).
			try { Connect(); FocusedWorkspace(); PathTo(""); }
			catch (Exception) { stream = null; }
			foreach (var job in jobs.GetConsumingEnumerable())
				for (int attempt = 0; attempt < 2; attempt++)
				{
					try { if (stream == null) Connect(); job(); break; }
					catch (Exception) { stream = null; }
				}
		}) { IsBackground = true }.Start();

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
		if (code < 0) return CallNextHookEx(IntPtr.Zero, code, message, data);
		int vk = Marshal.ReadInt32(data);
		bool up = (Marshal.ReadInt32(data, 8) & 0x80) != 0;
		// PowerToys sends F13/F14 (from Alt+Tab) with the flag this hook otherwise skips.
		if (!active && (vk == VK_F13 || vk == VK_F14) && WmKey(vk, up)) return (IntPtr)1;
		if (Marshal.ReadInt64(data, 16) == OurFlag) return CallNextHookEx(IntPtr.Zero, code, message, data);
		bool wasActive = active;
		bool swallow = active ? WhileOpen(vk, up) : (vk == VK_TAB && !up && SuperHeld() && Open()) || ClipboardKey(vk, up) || WmKey(vk, up);
		if (!wasActive && !active) StartMenuKey(vk, up);
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

	// SUPER+C / SUPER+V send Ctrl+Insert / Shift+Insert (copy / paste in terminals too) with Win briefly let go.
	// SUPER+Ctrl+V sends Win+V (clipboard history), then lets Win go so its release can't close the history.
	static bool ClipboardKey(int vk, bool up)
	{
		if (vk == clipboardKey) { if (up) clipboardKey = 0; return true; }
		if (up || (vk != VK_C && vk != VK_V) || !SuperHeld()) return false;
		bool ctrl = GetAsyncKeyState(VK_CONTROL) < 0;
		if (ctrl && vk == VK_C) return false;
		clipboardKey = vk;
		bool lwin = GetAsyncKeyState(VK_LWIN) < 0, rwin = GetAsyncKeyState(VK_RWIN) < 0;
		if (ctrl)
		{
			if (GetAsyncKeyState(VK_LCONTROL) < 0) Key(VK_LCONTROL, true);
			if (GetAsyncKeyState(VK_RCONTROL) < 0) Key(VK_RCONTROL, true);
			Tap(VK_V);
			if (lwin) Key(VK_LWIN, true);
			if (rwin) Key(VK_RWIN, true);
			return true;
		}
		Key(VK_DUMMY, false); Key(VK_DUMMY, true);
		if (lwin) Key(VK_LWIN, true);
		if (rwin) Key(VK_RWIN, true);
		int modifier = vk == VK_C ? VK_LCONTROL : VK_LSHIFT;
		Key(modifier, false); Tap(VK_INSERT, true); Key(modifier, true);
		if (lwin) Key(VK_LWIN, false);
		if (rwin) Key(VK_RWIN, false);
		return true;
	}

	// The binds above, run here rather than by GlazeWM starting hyprwin.exe (~100 ms) or a script for each press.
	static bool WmKey(int vk, bool up)
	{
		if (vk == wmKey) { if (up) wmKey = 0; return true; }
		if (up) return false;
		var action = WmAction(vk);
		if (action == null) return false;
		wmKey = vk;
		jobs.Add(action);
		return true;
	}

	static Action WmAction(int vk)
	{
		if (vk == VK_F13) return () => Cycle(1);
		if (vk == VK_F14) return () => Cycle(-1);
		if (!SuperHeld() || GetAsyncKeyState(VK_CONTROL) < 0) return null;
		bool shift = GetAsyncKeyState(VK_SHIFT) < 0, alt = AltHeld();
		switch (vk)
		{
			case VK_F: return shift ? null : alt ? (Action)(() => Fullscreen(false)) : () => Fullscreen(true);
			case VK_Q: return shift || alt ? null : (Action)(() => Quit(false));
			case VK_W: return shift && !alt ? (Action)(() => Quit(true)) : null;
			case VK_M: return alt && !shift ? (Action)Unminimize : null;
			case VK_S: return shift ? null : alt ? (Action)Scratchpad : ToggleScratchpad;
			case VK_BACKSLASH: return shift || alt ? null : (Action)ToggleSplit;
			case VK_SPACE: return shift && !alt ? (Action)ToggleZebar : null;
			case VK_O: return shift && !alt ? (Action)ToggleFocusLock : null;
			case VK_SLASH: return shift ? null : alt ? (Action)(() => ScaleDisplay(-1)) : () => ScaleDisplay(1);
		}
		return null;
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
