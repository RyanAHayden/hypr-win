import asyncio
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import focus_lock


class KeyboardLayoutTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.layout = Path(self.temporary.name) / "default.json"
        self.path_patch = patch.object(focus_lock, "KEYBOARD_LAYOUT_PATH", self.layout)
        self.path_patch.start()
        self.addCleanup(self.path_patch.stop)
        self.templates = Path(__file__).resolve().parents[2] / "PowerToys" / "Keyboard Manager"

    def use_layout(self, name):
        self.layout.write_bytes((self.templates / name).read_bytes())

    def test_laptop_layout(self):
        self.use_layout("layout_remapped.json")
        self.assertIs(focus_lock.laptop_keyboard(), True)

    def test_external_layout(self):
        self.use_layout("layout_default.json")
        self.assertIs(focus_lock.laptop_keyboard(), False)

    def test_unrelated_remap_is_not_laptop_mode(self):
        self.layout.write_text(json.dumps({
            "remapKeys": {"inProcess": [{"originalKeys": "20", "newRemapKeys": "162"}]},
        }))
        self.assertIs(focus_lock.laptop_keyboard(), False)

    def test_utf8_bom(self):
        self.use_layout("layout_remapped.json")
        text = self.layout.read_text(encoding="utf-8-sig")
        self.layout.write_text(text, encoding="utf-8-sig")
        self.assertIs(focus_lock.laptop_keyboard(), True)

    def test_unavailable_layout_is_unknown_and_logged(self):
        for contents in (None, "{", "{}", "null"):
            with self.subTest(contents=contents):
                if contents is not None:
                    self.layout.write_text(contents)
                with self.assertLogs(level="WARNING"):
                    self.assertIsNone(focus_lock.laptop_keyboard())

    async def test_status_tracks_layout_changes_and_preserves_focus_lock(self):
        async with await asyncio.start_server(focus_lock.serve_status, "127.0.0.1", 0) as server:
            port = server.sockets[0].getsockname()[1]
            for name, expected in (("layout_remapped.json", True), ("layout_default.json", False)):
                self.use_layout(name)
                with patch.object(focus_lock, "read_state", return_value={"locked": True}):
                    reader, writer = await asyncio.open_connection("127.0.0.1", port)
                    writer.write(b"POST /status HTTP/1.1\r\nHost: localhost\r\n\r\n")
                    await writer.drain()
                    response = await reader.read()
                    writer.close()
                    await writer.wait_closed()
                headers, body = response.split(b"\r\n\r\n", 1)
                self.assertIn(b"200 OK", headers)
                self.assertEqual(json.loads(body), {"locked": True, "laptopKeyboard": expected})


if __name__ == "__main__":
    unittest.main()
