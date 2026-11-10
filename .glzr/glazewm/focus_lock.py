import argparse
import asyncio
import ctypes
import json
import shutil
import subprocess
import time
from ctypes import wintypes
from pathlib import Path

import websockets


STATE_PATH = Path.home() / ".glzr" / "glazewm" / "focus-lock.json"
STOP_PATH = STATE_PATH.with_suffix(".stop")
IPC_URL = "ws://127.0.0.1:6123"
STATUS_HOST = "127.0.0.1"
STATUS_PORT = 6125
# GlazeWM's raw-input listener ignores input tagged with its own marker.
GLAZEWM_INPUT_MARKER = 6379
# How long after a window opens its focus is treated as stealing.
STEAL_GRACE_SECONDS = 1.0

user32 = ctypes.WinDLL("user32", use_last_error=True)
user32.GetForegroundWindow.restype = wintypes.HWND
user32.GetShellWindow.restype = wintypes.HWND
user32.SetForegroundWindow.argtypes = [wintypes.HWND]


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", wintypes.LONG),
        ("dy", wintypes.LONG),
        ("mouseData", wintypes.DWORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ctypes.c_size_t),
    ]


class INPUT(ctypes.Structure):
    class _INPUT(ctypes.Union):
        _fields_ = [("mi", MOUSEINPUT), ("padding", ctypes.c_byte * 32)]

    _anonymous_ = ("input",)
    _fields_ = [("type", wintypes.DWORD), ("input", _INPUT)]


def send_dummy_input():
    # Recent input grants this process permission to change the foreground window.
    dummy = INPUT(type=0)
    dummy.mi = MOUSEINPUT(0, 0, 0, 0x0001, 0, GLAZEWM_INPUT_MARKER)
    user32.SendInput(1, ctypes.byref(dummy), ctypes.sizeof(INPUT))


def resync_native_focus(handle):
    # GlazeWM 3.10.1 disables focus_follows_cursor when a window becomes
    # foreground before it is managed: refocusing an already-foreground window
    # emits no foreground event, so its focus-sync flag is never restored.
    # Bouncing foreground through the shell window emits that event.
    if not handle or user32.GetForegroundWindow() != handle:
        return
    send_dummy_input()
    if user32.SetForegroundWindow(user32.GetShellWindow()):
        send_dummy_input()
        user32.SetForegroundWindow(handle)


async def resync_after_manage(handle):
    await asyncio.sleep(0.15)
    if not read_state().get("locked"):
        resync_native_focus(handle)


ZEBAR_CHECK_SECONDS = 5
# Require consecutive misses so GlazeWM's shutdown taskkill isn't undone.
ZEBAR_MISSES_BEFORE_RESTART = 2


class PROCESSENTRY32W(ctypes.Structure):
    _fields_ = [
        ("dwSize", wintypes.DWORD),
        ("cntUsage", wintypes.DWORD),
        ("th32ProcessID", wintypes.DWORD),
        ("th32DefaultHeapID", ctypes.c_size_t),
        ("th32ModuleID", wintypes.DWORD),
        ("cntThreads", wintypes.DWORD),
        ("th32ParentProcessID", wintypes.DWORD),
        ("pcPriClassBase", wintypes.LONG),
        ("dwFlags", wintypes.DWORD),
        ("szExeFile", wintypes.WCHAR * 260),
    ]


kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
kernel32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
kernel32.Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.POINTER(PROCESSENTRY32W)]
kernel32.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(PROCESSENTRY32W)]
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
INVALID_HANDLE_VALUE = wintypes.HANDLE(-1).value


def running_processes():
    # One in-process snapshot instead of spawning tasklist.
    snapshot = kernel32.CreateToolhelp32Snapshot(0x2, 0)
    if snapshot == INVALID_HANDLE_VALUE:
        return None
    names = set()
    try:
        entry = PROCESSENTRY32W(dwSize=ctypes.sizeof(PROCESSENTRY32W))
        ok = kernel32.Process32FirstW(snapshot, ctypes.byref(entry))
        while ok:
            names.add(entry.szExeFile.lower())
            ok = kernel32.Process32NextW(snapshot, ctypes.byref(entry))
    finally:
        kernel32.CloseHandle(snapshot)
    return names


def start_zebar():
    zebar = shutil.which("zebar")
    if not zebar:
        return
    # Detach so Zebar doesn't die with whichever process tree launched it.
    flags = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
    try:
        subprocess.Popen([zebar], creationflags=flags | subprocess.CREATE_BREAKAWAY_FROM_JOB)
    except OSError:
        subprocess.Popen([zebar], creationflags=flags)


async def keep_zebar_running(stop_event):
    misses = 0
    while not stop_event.is_set():
        await asyncio.sleep(ZEBAR_CHECK_SECONDS)
        names = await asyncio.to_thread(running_processes)
        if names is None:
            continue
        if "zebar.exe" in names or "glazewm.exe" not in names:
            misses = 0
            continue
        misses += 1
        if misses >= ZEBAR_MISSES_BEFORE_RESTART and not stop_event.is_set():
            start_zebar()
            misses = 0


def read_state():
    try:
        return json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"locked": False, "revision": 0}


def write_state(locked):
    state = read_state()
    next_state = {"locked": locked, "revision": state.get("revision", 0) + 1}
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = STATE_PATH.with_suffix(".tmp")
    temporary_path.write_text(json.dumps(next_state), encoding="utf-8")
    temporary_path.replace(STATE_PATH)


class FocusLockState:
    def __init__(self):
        self.locked = False
        self.target_id = None
        self.new_windows = {}

    def set_locked(self, locked, focused_id=None):
        self.locked = locked
        self.new_windows.clear()
        self.target_id = focused_id if locked else None

    def window_managed(self, container_id):
        if self.locked and container_id:
            now = time.monotonic()
            self.new_windows = {
                window_id: managed_at
                for window_id, managed_at in self.new_windows.items()
                if now - managed_at < STEAL_GRACE_SECONDS
            }
            self.new_windows[container_id] = now
            return self.target_id
        return None

    def focus_changed(self, container_id):
        if not self.locked or not container_id:
            return None
        # Only focus that arrives right after a window opens counts as stealing;
        # later focus (keybinds, hover) moves the lock target to that window.
        managed_at = self.new_windows.pop(container_id, None)
        if managed_at is not None and time.monotonic() - managed_at < STEAL_GRACE_SECONDS:
            self.new_windows[container_id] = managed_at
            return self.target_id
        self.target_id = container_id
        return None


def container_id(container):
    if not isinstance(container, dict) or container.get("type") != "window":
        return None
    return container.get("id")


async def restore_focus(websocket, target_id):
    if target_id:
        await websocket.send(f"c focus --container-id {target_id}")


async def restore_after_sync(websocket, lock_state, expected_revision, focus_target):
    await asyncio.sleep(0.15)
    current_state = read_state()
    if (
        current_state.get("locked")
        and current_state.get("revision") == expected_revision
        and lock_state.target_id
    ):
        await restore_focus(websocket, lock_state.target_id or focus_target)


async def handle_event(websocket, lock_state, data, revision):
    event_type = data.get("eventType")
    if event_type == "window_managed":
        window = data.get("managedWindow") or {}
        target_id = lock_state.window_managed(container_id(window))
        if target_id:
            asyncio.create_task(
                restore_after_sync(websocket, lock_state, revision, target_id)
            )
        else:
            asyncio.create_task(resync_after_manage(window.get("handle")))
    elif event_type == "focus_changed":
        focused = data.get("focusedContainer") or {}
        target_id = lock_state.focus_changed(container_id(focused))
        await restore_focus(websocket, target_id)


async def sync_lock_state(websocket, lock_state, observed_revision):
    state = read_state()
    revision = state.get("revision", 0)
    if revision == observed_revision:
        return observed_revision
    if state.get("locked"):
        await websocket.send("q focused")
    else:
        lock_state.set_locked(False)
    return revision


def handle_focus_response(lock_state, data):
    if "focused" not in data:
        return
    if read_state().get("locked"):
        lock_state.set_locked(True, container_id(data["focused"]))
    else:
        lock_state.set_locked(False)


async def handle_ipc(websocket, stop_event):
    lock_state = FocusLockState()
    observed_revision = read_state().get("revision", 0)

    await websocket.send("sub -e window_managed -e focus_changed")
    await websocket.send("q focused")

    async def watch_lock_state():
        nonlocal observed_revision
        while True:
            observed_revision = await sync_lock_state(
                websocket, lock_state, observed_revision
            )
            await asyncio.sleep(0.1)

    watcher = asyncio.create_task(watch_lock_state())
    try:
        async for raw in websocket:
            if stop_event.is_set():
                break
            message = json.loads(raw)
            data = message.get("data") or {}
            if message.get("messageType") == "client_response":
                handle_focus_response(lock_state, data)
            elif message.get("messageType") == "event_subscription":
                await handle_event(websocket, lock_state, data, observed_revision)
    finally:
        watcher.cancel()


async def run_ipc(stop_event):
    while not stop_event.is_set():
        try:
            async with websockets.connect(IPC_URL) as websocket:
                await handle_ipc(websocket, stop_event)
        except (OSError, websockets.WebSocketException):
            await asyncio.sleep(1)


async def serve_status(reader, writer):
    try:
        request = await reader.readline()
        while True:
            header = await reader.readline()
            if header in (b"\r\n", b"\n", b""):
                break

        if request.startswith(b"OPTIONS "):
            status = b"204 No Content"
            body = b""
        elif request.startswith((b"GET /status ", b"POST /status ")):
            status = b"200 OK"
            body = json.dumps({"locked": read_state().get("locked", False)}).encode()
        else:
            status = b"404 Not Found"
            body = b"{}"

        headers = (
            f"HTTP/1.1 {status.decode()}\r\n"
            "Access-Control-Allow-Origin: *\r\n"
            "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
            "Cache-Control: no-store\r\n"
            "Content-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\n"
            "Connection: close\r\n\r\n"
        ).encode()
        writer.write(headers + body)
        await writer.drain()
    finally:
        writer.close()
        await writer.wait_closed()


async def run_service():
    STOP_PATH.unlink(missing_ok=True)
    read_state()
    stop_event = asyncio.Event()
    server = await asyncio.start_server(serve_status, STATUS_HOST, STATUS_PORT)
    ipc_task = asyncio.create_task(run_ipc(stop_event))
    zebar_task = asyncio.create_task(keep_zebar_running(stop_event))

    async with server:
        while not STOP_PATH.exists():
            await asyncio.sleep(0.2)

    stop_event.set()
    ipc_task.cancel()
    zebar_task.cancel()
    await asyncio.gather(ipc_task, zebar_task, return_exceptions=True)
    write_state(False)


def main():
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--service", action="store_true")
    mode.add_argument("--toggle", action="store_true")
    mode.add_argument("--stop", action="store_true")
    args = parser.parse_args()

    if args.toggle:
        write_state(not read_state().get("locked", False))
    elif args.stop:
        write_state(False)
        STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        STOP_PATH.touch()
    else:
        asyncio.run(run_service())


if __name__ == "__main__":
    main()