import argparse
import asyncio
import json
from pathlib import Path

import websockets


STATE_PATH = Path.home() / ".glzr" / "glazewm" / "focus-lock.json"
STOP_PATH = STATE_PATH.with_suffix(".stop")
IPC_URL = "ws://127.0.0.1:6123"
STATUS_HOST = "127.0.0.1"
STATUS_PORT = 6125


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
        self.managed_ids = set()

    def set_locked(self, locked, focused_id=None):
        self.locked = locked
        self.managed_ids.clear()
        self.target_id = focused_id if locked else None

    def window_managed(self, container_id):
        if self.locked and container_id:
            self.managed_ids.add(container_id)
            return self.target_id
        return None

    def focus_changed(self, container_id):
        if not self.locked or not container_id:
            return None
        if container_id in self.managed_ids:
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

    while not stop_event.is_set():
        observed_revision = await sync_lock_state(
            websocket, lock_state, observed_revision
        )
        try:
            message = json.loads(await asyncio.wait_for(websocket.recv(), timeout=0.1))
        except asyncio.TimeoutError:
            continue

        data = message.get("data") or {}
        if message.get("messageType") == "client_response":
            handle_focus_response(lock_state, data)
        elif message.get("messageType") == "event_subscription":
            await handle_event(websocket, lock_state, data, observed_revision)


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

    async with server:
        while not STOP_PATH.exists():
            await asyncio.sleep(0.2)

    stop_event.set()
    ipc_task.cancel()
    await asyncio.gather(ipc_task, return_exceptions=True)
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