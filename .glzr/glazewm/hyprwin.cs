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
//   hyprwin move left|right|up|down  SUPER+SHIFT+HJKL: split the next window over with the focused one (Hyprland's movewindow)
//   hyprwin fullscreen [max]  toggle fullscreen (or maximized), returning the window to its old spot
//   hyprwin powermenu         SUPER+ESC: system menu (lock, sleep, hibernate, keep awake, relaunch, log out, restart, shut down)
//   hyprwin dwindle           stays running (GlazeWM startup): new windows split the focused one along its longer side
//   hyprwin switcher          stays running (GlazeWM startup): SUPER+Tab window switcher; see the Switcher section.
//                             It also stops SUPER alone opening Start; tapping SUPER+Alt opens it instead.
//                             SUPER+C / SUPER+V copy / paste everywhere. SUPER+Space, SUPER+Ctrl+V and SUPER+Ctrl+E open
//                             Vicinae, its clipboard history and its emoji picker.
//                             SUPER+F / SUPER+ALT+F run fullscreen max / fullscreen without starting a process.
//                             The switcher also runs every bind above without starting a process (~100 ms each);
//                             GlazeWM has no binds for them: they would fire as well when its hook runs first.
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
		if (args.Length > 0 && args[0] == "powermenu") return PowerMenu();
		if (args.Length > 0 && args[0] == "togglezebar") { ToggleZebar(); return 0; }
		if (args.Length > 0 && args[0] == "focuslock") { ToggleFocusLock(); return 0; }
		if (args.Length > 0 && args[0] == "scale") { ScaleDisplay(args.Length > 1 && args[1] == "down" ? -1 : 1); return 0; }
		// GlazeWM has uiAccess, which only the shell's launch path honours: started directly (as by Task Scheduler) it fails.
		if (args.Length > 1 && args[0] == "launch")
		{
			using (var process = Process.Start(new ProcessStartInfo(args[1], string.Join(" ", args, 2, args.Length - 2)) { UseShellExecute = true }))
			{
				if (process == null) throw new InvalidOperationException("The shell did not return a process for " + args[1]);
				// Keep the logon task attached so it can restart GlazeWM if startup fails.
				process.WaitForExit();
				return process.ExitCode;
			}
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
				case "move": if (args.Length < 2) return 2; MoveWindow(args[1]); break;
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

	// Like Hyprland's dwindle movewindow: the window leaves its spot and splits the window next to it along that one's
	// longer side. GlazeWM's own move would instead add it to the nearest ancestor tiling that way, e.g. as a new column.
	static void MoveWindow(string direction)
	{
		var focused = Map(Map(Query("focused"))["focused"]);
		var path = focused != null && (string)focused["type"] == "window" && State(focused) == "tiling" ? PathTo((string)focused["id"]) : null;
		if (path == null) { Command("move --direction " + direction); return; }
		var id = (string)focused["id"];
		bool alongX = direction == "left" || direction == "right", backward = direction == "left" || direction == "up";
		double x = Number(focused, "x"), y = Number(focused, "y"), width = Number(focused, "width"), height = Number(focused, "height");
		double middle = alongX ? y + height / 2 : x + width / 2;

		// The nearest tiling window in the direction, across from the window's middle.
		var windows = new List<Dictionary<string, object>>();
		CollectWindows(path[0], windows, c => State(c) == "tiling" && !id.Equals(c["id"]));
		Dictionary<string, object> target = null;
		double nearest = double.MaxValue;
		foreach (var c in windows)
		{
			double cx = Number(c, "x"), cy = Number(c, "y"), cw = Number(c, "width"), ch = Number(c, "height");
			double distance = alongX ? (backward ? x - (cx + cw) : cx - (x + width)) : (backward ? y - (cy + ch) : cy - (y + height));
			double start = alongX ? cy : cx, end = alongX ? cy + ch : cx + cw;
			if (distance < -1 || middle < start || middle > end || distance >= nearest) continue;
			nearest = distance;
			target = c;
		}
		// Nothing there: GlazeWM's move takes it to the next monitor.
		if (target == null) { Command("move --direction " + direction); return; }
		var targetId = (string)target["id"];

		// Floating lifts the window out. Alone in a split, its old spot is gone, so GlazeWM retiles it beside the focused window.
		if (TilingChildren(ParentOf(id)).Count > 1) Command("--id " + id + " toggle-tiling-direction");
		// Float it where it is, so it doesn't pop out to the centre while the layout changes under it.
		Command("--id " + id + " set-floating --centered=false --x-pos " + (int)x + " --y-pos " + (int)y
			+ " --width " + (int)width + "px --height " + (int)height + "px");
		var floatingPath = PathTo(id);
		if (floatingPath != null) FlattenNestedSplits(floatingPath[0]);

		// Split the target along its longer side, measured with the window gone, as dwindle does.
		var targetPath = PathTo(targetId);
		if (targetPath == null) { Command("--id " + id + " set-tiling"); return; }
		target = targetPath[targetPath.Count - 1];
		double tx = Number(target, "x"), ty = Number(target, "y"), tw = Number(target, "width"), th = Number(target, "height");
		bool wide = tw >= th;
		string split = wide ? "horizontal" : "vertical";
		for (int i = 0; i < 4 && Direction(ParentOf(targetId)) != split; i++)
			Command("--id " + targetId + " set-tiling-direction " + split);
		targetPath = PathTo(targetId);
		double share = TilingSize(targetPath[targetPath.Count - 1]);
		bool hasSiblings = TilingChildren(targetPath[targetPath.Count - 2]).Count > 1;

		Command("focus --container-id " + targetId);
		Command("--id " + id + " set-tiling");
		// Along the move it passes the target if the target took its spot, else stays on its side; across, its middle decides.
		bool first;
		if (wide == alongX)
		{
			double center = alongX ? x + width / 2 : y + height / 2;
			bool tookSpot = alongX ? center >= tx && center <= tx + tw : center >= ty && center <= ty + th;
			first = tookSpot == backward;
		}
		else first = middle < (alongX ? ty + th / 2 : tx + tw / 2);
		if (first) Command("--id " + id + " move --direction " + (wide ? "left" : "up"));
		// Sharing a parent with others, it took space from all of them: split only the target's.
		if (hasSiblings) ResizePair(first ? id : targetId, first ? targetId : id, share / 2, share / 2, wide);
		Command("focus --container-id " + id);
	}

	static double Number(Dictionary<string, object> container, string key) { return Convert.ToDouble(container[key]); }

	// GlazeWM doesn't flatten the split a window leaves by turning floating (or fullscreen, minimized). If the remaining
	// window is then wrapped twice, closing it leaves the outer split behind, empty but still taking up space.
	static void FlattenNestedSplits(Dictionary<string, object> workspace)
	{
		for (int i = 0; i < 16 && workspace != null; i++)
		{
			var id = DoublyWrappedWindow(workspace, false);
			if (id == null) return;
			// Toggling an only child flattens its split.
			Command("--id " + id + " toggle-tiling-direction");
			var path = PathTo(id);
			workspace = path == null ? null : path[0];
		}
	}

	static string DoublyWrappedWindow(Dictionary<string, object> container, bool isOnlyChildOfSplit)
	{
		var children = TilingChildren(container);
		bool isLoneSplit = (string)container["type"] == "split" && children.Count == 1;
		foreach (var child in children)
		{
			if ((string)child["type"] == "window") { if (isLoneSplit && isOnlyChildOfSplit) return (string)child["id"]; }
			else
			{
				var id = DoublyWrappedWindow(child, isLoneSplit);
				if (id != null) return id;
			}
		}
		return null;
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
		// Focus follows the cursor, so focus events are frequent: skip windows already split for their shape and parent.
		var applied = new HashSet<string>();
		while (true)
		{
			var text = Receive();
			if (!text.Contains("\"event_subscription\"")) continue;
			var data = Map(Map(json.DeserializeObject(text))["data"]);
			Dictionary<string, object> focused = null;
			if (data != null && "focus_changed".Equals(data["eventType"])) focused = Map(data["focusedContainer"]);
			else focused = Map(Map(Query("focused"))["focused"]);
			if (focused == null || (string)focused["type"] != "window" || State(focused) != "tiling") continue;
			// Changing splits would lose the spot GlazeWM returns a fullscreen window to.
			var path = PathTo((string)focused["id"]);
			if (path == null) continue;
			bool hasFullscreen = false;
			foreach (var c in List(path[0]["children"]))
				if ((string)Map(c)["type"] == "window" && State(Map(c)) == "fullscreen") hasFullscreen = true;
			if (hasFullscreen) continue;
			FlattenNestedSplits(path[0]);
			bool isWide = Convert.ToDouble(focused["width"]) >= Convert.ToDouble(focused["height"]);
			var key = focused["id"] + "|" + focused["parentId"] + "|" + isWide;
			if (applied.Contains(key)) continue;
			Command("--id " + focused["id"] + " set-tiling-direction " + (isWide ? "horizontal" : "vertical"));
			if (applied.Count > 512) applied.Clear();
			applied.Add(key);
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

	// --- Power menu: SUPER+Escape, like hypr-mac's power-menu.swift ---
	// A native menu centered on the screen with the mouse: the underlined letters or arrows/Enter pick an item, Escape
	// closes it. The actions are the "Power:" Script Commands (%LOCALAPPDATA%\vicinae\data\scripts\power-*.ps1, from
	// Vicinae/scripts), so they're also searchable in Vicinae. Picking a toggle (check mark) reopens the menu.

	[DllImport("user32.dll")] static extern IntPtr CreatePopupMenu();
	[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool AppendMenu(IntPtr menu, uint flags, UIntPtr id, string text);
	[DllImport("user32.dll")] static extern bool DestroyMenu(IntPtr menu);
	[DllImport("user32.dll")] static extern int TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr hwnd, IntPtr parameters);
	[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowEx(uint exStyle, string className, string title, uint style,
		int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
	[DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr hwnd);
	[DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
	[DllImport("user32.dll")] static extern bool GetCursorPos(out long point);
	[DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(long point, uint flags);
	[DllImport("uxtheme.dll", EntryPoint = "#135")] static extern int SetPreferredAppMode(int mode);
	[DllImport("uxtheme.dll", EntryPoint = "#136")] static extern void FlushMenuThemes();

	static readonly string[][] PowerItems =
	{
		new[] { "&Lock", "power-lock.ps1" },
		new[] { "&Sleep", "power-sleep.ps1" },
		new[] { "&Hibernate", "power-hibernate.ps1" },
		new[] { "&Keep Awake With Lid Closed", "power-lid-sleep.ps1" },
		new[] { "Reopen &Apps at Login", "power-reopen-apps.ps1" },
		null,
		new[] { "Relaunch &Window Manager", "power-relaunch-wm.ps1" },
		null,
		new[] { "Log &Out", "power-logout.ps1" },
		new[] { "&Restart", "power-restart.ps1" },
		new[] { "Shut &Down", "power-shutdown.ps1" },
	};

	// Runs a Vicinae deeplink (https://docs.vicinae.com/deeplinks), as hypr-mac's binds do with raycast:// links.
	static void Vicinae(string link)
	{
		string exe = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Programs\Vicinae\bin\vicinae.exe");
		try { using (Process.Start(new ProcessStartInfo(exe, "\"" + link + "\"") { CreateNoWindow = true, UseShellExecute = false })) { } }
		catch (Exception) { }
	}

	static int PowerMenu()
	{
		bool first;
		using (new System.Threading.Mutex(true, "hyprwin-powermenu", out first))
		{
			if (!first) return 0;
			string scripts = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"vicinae\data\scripts");
			// Dark menus when Windows is in dark mode.
			try { SetPreferredAppMode(1); FlushMenuThemes(); } catch (Exception) { }
			while (true)
			{
				string script = PickPower();
				if (script == null) return 0;
				RunScript(Path.Combine(scripts, script));
				if (script != "power-lid-sleep.ps1" && script != "power-reopen-apps.ps1") return 0;
			}
		}
	}

	static string PickPower()
	{
		var menu = CreatePopupMenu();
		const uint MF_STRING = 0, MF_SEPARATOR = 0x800, MF_CHECKED = 8;
		for (int i = 0; i < PowerItems.Length; i++)
		{
			var item = PowerItems[i];
			if (item == null) { AppendMenu(menu, MF_SEPARATOR, UIntPtr.Zero, null); continue; }
			bool on = item[1] == "power-lid-sleep.ps1" ? LidStaysAwake() : item[1] == "power-reopen-apps.ps1" && ReopensApps();
			AppendMenu(menu, MF_STRING | (on ? MF_CHECKED : 0), (UIntPtr)(i + 1), item[0]);
		}

		// The menu takes keys only while its owner is the foreground window. A key sent from here makes this process the
		// last to give input, which lets it take the foreground (PowerToys and the switcher skip keys with our flag).
		var owner = CreateWindowEx(0x80 /* WS_EX_TOOLWINDOW */, "STATIC", "hyprwin power menu", 0x80000000 /* WS_POPUP */,
			0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
		keybd_event(0xFF, 0, 0, new UIntPtr((ulong)OurFlag));
		keybd_event(0xFF, 0, 2, new UIntPtr((ulong)OurFlag));
		SetForegroundWindow(owner);

		// The center of the work area of the monitor with the mouse (MONITORINFO: rcWork at byte 20).
		long cursor;
		GetCursorPos(out cursor);
		var info = new byte[40];
		BitConverter.GetBytes(info.Length).CopyTo(info, 0);
		GetMonitorInfo(MonitorFromPoint(cursor, 2), info);
		int x = (BitConverter.ToInt32(info, 20) + BitConverter.ToInt32(info, 28)) / 2;
		int y = (BitConverter.ToInt32(info, 24) + BitConverter.ToInt32(info, 32)) / 2;

		const uint TPM_CENTERALIGN = 0x4, TPM_VCENTERALIGN = 0x10, TPM_NONOTIFY = 0x80, TPM_RETURNCMD = 0x100;
		int picked = TrackPopupMenuEx(menu, TPM_CENTERALIGN | TPM_VCENTERALIGN | TPM_NONOTIFY | TPM_RETURNCMD, x, y, owner, IntPtr.Zero);
		PostMessage(owner, 0 /* WM_NULL */, IntPtr.Zero, IntPtr.Zero);
		DestroyMenu(menu);
		DestroyWindow(owner);
		return picked > 0 ? PowerItems[picked - 1][1] : null;
	}

	static void RunScript(string path)
	{
		var info = new ProcessStartInfo("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + path + "\"")
			{ CreateNoWindow = true, UseShellExecute = false };
		using (var process = Process.Start(info)) process.WaitForExit();
	}

	[DllImport("powrprof.dll")] static extern uint PowerGetActiveScheme(IntPtr rootKey, out IntPtr scheme);
	[DllImport("powrprof.dll")] static extern uint PowerReadACValueIndex(IntPtr rootKey, IntPtr scheme, ref Guid subgroup, ref Guid setting, out uint value);
	[DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);

	// Lid close does nothing (Keep Awake With Lid Closed is on) when its AC action is 0.
	static bool LidStaysAwake()
	{
		IntPtr scheme;
		if (PowerGetActiveScheme(IntPtr.Zero, out scheme) != 0) return false;
		try
		{
			var buttons = new Guid("4f971e89-eebd-4455-a8de-9e59040e7347");
			var lidAction = new Guid("5ca83367-6e45-459f-a27b-476b1d01c936");
			uint value;
			return PowerReadACValueIndex(IntPtr.Zero, scheme, ref buttons, ref lidAction, out value) == 0 && value == 0;
		}
		finally { LocalFree(scheme); }
	}

	static bool ReopensApps()
	{
		using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows NT\CurrentVersion\Winlogon"))
			return key != null && 1.Equals(key.GetValue("RestartApps"));
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

	const int VK_TAB = 0x09, VK_SHIFT = 0x10, VK_ESCAPE = 0x1B, VK_LEFT = 0x25, VK_UP = 0x26, VK_RIGHT = 0x27, VK_DOWN = 0x28, VK_DELETE = 0x2E;
	const int VK_H = 0x48, VK_J = 0x4A, VK_K = 0x4B, VK_L = 0x4C, VK_Q = 0x51, VK_C = 0x43, VK_V = 0x56, VK_F = 0x46, VK_E = 0x45, VK_INSERT = 0x2D;
	const int VK_W = 0x57, VK_M = 0x4D, VK_S = 0x53, VK_O = 0x4F, VK_SPACE = 0x20, VK_BACKSLASH = 0xDC, VK_SLASH = 0xBF, VK_F13 = 0x7C, VK_F14 = 0x7D, VK_F22 = 0x85;
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
		// AltSnap drags without focusing (focusing mid-drag stops GlazeWM's drag-to-swap), so raise the window instead.
		// Raising without activating isn't a focus change, so GlazeWM leaves the drag alone.
		const uint EVENT_SYSTEM_MOVESIZESTART = 0x000A, WINEVENT_OUTOFCONTEXT = 0, WINEVENT_SKIPOWNPROCESS = 2;
		SetWinEventHook(EVENT_SYSTEM_MOVESIZESTART, EVENT_SYSTEM_MOVESIZESTART, IntPtr.Zero, moveStartProc, 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
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

	delegate void WinEventProc(IntPtr hook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
	[DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc proc, uint process, uint thread, uint flags);
	[DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
	static readonly WinEventProc moveStartProc = OnMoveStart;

	static void OnMoveStart(IntPtr hook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
	{
		const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOACTIVATE = 0x10, SWP_NOOWNERZORDER = 0x200;
		if (idObject == 0 && hwnd != IntPtr.Zero)
			SetWindowPos(hwnd, IntPtr.Zero /* HWND_TOP */, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
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
	// (SUPER+Ctrl+V is Vicinae's clipboard history, in WmAction.)
	static bool ClipboardKey(int vk, bool up)
	{
		if (vk == clipboardKey) { if (up) clipboardKey = 0; return true; }
		if (up || (vk != VK_C && vk != VK_V) || !SuperHeld()) return false;
		if (GetAsyncKeyState(VK_CONTROL) < 0) return false;
		clipboardKey = vk;
		bool lwin = GetAsyncKeyState(VK_LWIN) < 0, rwin = GetAsyncKeyState(VK_RWIN) < 0;
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
		if (!up && vk == VK_S && SuperHeld() && GetAsyncKeyState(VK_SHIFT) < 0 &&
			!AltHeld() && GetAsyncKeyState(VK_CONTROL) >= 0)
		{
			// Windows reserves Win+Shift+S, so Greenshot's region capture listens on plain F22 instead (F23/F24 are taken).
			wmKey = vk;
			bool lwin = GetAsyncKeyState(VK_LWIN) < 0, rwin = GetAsyncKeyState(VK_RWIN) < 0;
			bool lshift = GetAsyncKeyState(VK_LSHIFT) < 0, rshift = GetAsyncKeyState(VK_RSHIFT) < 0;
			Key(VK_DUMMY, false); Key(VK_DUMMY, true);
			if (lwin) Key(VK_LWIN, true);
			if (rwin) Key(VK_RWIN, true);
			if (lshift) Key(VK_LSHIFT, true);
			if (rshift) Key(VK_RSHIFT, true);
			Tap(VK_F22);
			if (lshift) Key(VK_LSHIFT, false);
			if (rshift) Key(VK_RSHIFT, false);
			if (lwin) Key(VK_LWIN, false);
			if (rwin) Key(VK_RWIN, false);
			return true;
		}
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
		if (!SuperHeld()) return null;
		bool shift = GetAsyncKeyState(VK_SHIFT) < 0, alt = AltHeld();
		if (GetAsyncKeyState(VK_CONTROL) < 0)
		{
			// hypr-mac's launcher binds: SUPER+Ctrl+V clipboard history, SUPER+Ctrl+E emoji picker.
			if (shift || alt) return null;
			if (vk == VK_V) return () => Vicinae("vicinae://launch/clipboard/history?toggle=true");
			if (vk == VK_E) return () => Vicinae("vicinae://launch/core/search-emojis?toggle=true");
			return null;
		}
		switch (vk)
		{
			case VK_F: return shift ? null : alt ? (Action)(() => Fullscreen(false)) : () => Fullscreen(true);
			case VK_Q: return shift || alt ? null : (Action)(() => Quit(false));
			case VK_W: return shift && !alt ? (Action)(() => Quit(true)) : null;
			case VK_M: return alt && !shift ? (Action)Unminimize : null;
			case VK_S: return shift ? null : alt ? (Action)Scratchpad : ToggleScratchpad;
			case VK_BACKSLASH: return shift || alt ? null : (Action)ToggleSplit;
			case VK_H: case VK_LEFT: return shift && !alt ? (Action)(() => MoveWindow("left")) : null;
			case VK_L: case VK_RIGHT: return shift && !alt ? (Action)(() => MoveWindow("right")) : null;
			case VK_K: case VK_UP: return shift && !alt ? (Action)(() => MoveWindow("up")) : null;
			case VK_J: case VK_DOWN: return shift && !alt ? (Action)(() => MoveWindow("down")) : null;
			// SUPER+Space: Windows keeps Win+Space for itself, so Vicinae can't take it; PowerToys doesn't chain its
			// Win+Space -> Alt+Space remap onto the Win it makes from left Alt either.
			case VK_SPACE: return alt ? null : shift ? (Action)ToggleZebar : () => Vicinae("vicinae://toggle");
			case VK_O: return shift && !alt ? (Action)ToggleFocusLock : null;
			case VK_SLASH: return shift ? null : alt ? (Action)(() => ScaleDisplay(-1)) : () => ScaleDisplay(1);
			// Its own process, so the menu's modal loop never blocks this hook; GlazeWM fires its bind only on release.
			case VK_ESCAPE: return shift || alt ? null : (Action)(() => Process.Start(new ProcessStartInfo(
				Process.GetCurrentProcess().MainModule.FileName, "powermenu") { UseShellExecute = false }).Dispose());
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
