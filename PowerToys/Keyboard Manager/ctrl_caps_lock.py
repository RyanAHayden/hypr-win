"""Make the physical Ctrl + Caps Lock chord toggle Caps Lock.

Keyboard Manager remaps Caps Lock to Ctrl, so Caps Lock can get stuck on with
no key left to turn it off. This hook sees physical keys before Keyboard
Manager, swallows Caps Lock while a physical Ctrl key is held, and injects a
real Caps Lock tap tagged so Keyboard Manager ignores it.

Low-level hooks run newest-first and Keyboard Manager reinstalls its hook when
its engine restarts, so this hook is reinstalled periodically to stay in front.
Run elevated so the hook also sees input aimed at elevated windows.
"""

import ctypes
from ctypes import wintypes


WH_KEYBOARD_LL = 13
HC_ACTION = 0
WM_KEYDOWN = 0x0100
WM_KEYUP = 0x0101
WM_SYSKEYDOWN = 0x0104
WM_SYSKEYUP = 0x0105
WM_TIMER = 0x0113
WM_APP = 0x8000
LLKHF_INJECTED = 0x10
VK_CAPITAL = 0x14
VK_LCONTROL = 0xA2
VK_RCONTROL = 0xA3
INPUT_KEYBOARD = 1
KEYEVENTF_KEYUP = 0x0002
# PowerToys CommonSharedConstants::KEYBOARDMANAGER_INJECTED_FLAG.
KEYBOARDMANAGER_INJECTED_FLAG = 0x1
REHOOK_INTERVAL_MS = 2000

ULONG_PTR = ctypes.c_size_t
LRESULT = ctypes.c_ssize_t

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)


class KBDLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [
        ("vkCode", wintypes.DWORD),
        ("scanCode", wintypes.DWORD),
        ("flags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ULONG_PTR),
    ]


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", wintypes.LONG),
        ("dy", wintypes.LONG),
        ("mouseData", wintypes.DWORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ULONG_PTR),
    ]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", wintypes.WORD),
        ("wScan", wintypes.WORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ULONG_PTR),
    ]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT)]


class INPUT(ctypes.Structure):
    _anonymous_ = ("u",)
    _fields_ = [("type", wintypes.DWORD), ("u", _INPUTUNION)]


HOOKPROC = ctypes.WINFUNCTYPE(LRESULT, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM)

user32.SetWindowsHookExW.argtypes = [ctypes.c_int, HOOKPROC, wintypes.HINSTANCE, wintypes.DWORD]
user32.SetWindowsHookExW.restype = wintypes.HHOOK
user32.UnhookWindowsHookEx.argtypes = [wintypes.HHOOK]
user32.UnhookWindowsHookEx.restype = wintypes.BOOL
user32.CallNextHookEx.argtypes = [wintypes.HHOOK, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM]
user32.CallNextHookEx.restype = LRESULT
user32.GetMessageW.argtypes = [ctypes.POINTER(wintypes.MSG), wintypes.HWND, wintypes.UINT, wintypes.UINT]
user32.GetMessageW.restype = wintypes.BOOL
user32.PostThreadMessageW.argtypes = [wintypes.DWORD, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
user32.PostThreadMessageW.restype = wintypes.BOOL
user32.SetTimer.argtypes = [wintypes.HWND, ULONG_PTR, wintypes.UINT, ctypes.c_void_p]
user32.SetTimer.restype = ULONG_PTR
user32.SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
user32.SendInput.restype = wintypes.UINT
kernel32.GetModuleHandleW.argtypes = [wintypes.LPCWSTR]
kernel32.GetModuleHandleW.restype = wintypes.HMODULE
kernel32.GetCurrentThreadId.restype = wintypes.DWORD


class CtrlCapsLock:
    def __init__(self):
        self.thread_id = kernel32.GetCurrentThreadId()
        self.module = kernel32.GetModuleHandleW(None)
        self.proc = HOOKPROC(self.on_key)
        self.hook = None
        self.ctrl_down = set()
        self.caps_passed = False
        self.caps_swallowed = False

    def install(self):
        hook = user32.SetWindowsHookExW(WH_KEYBOARD_LL, self.proc, self.module, 0)
        if not hook:
            raise ctypes.WinError(ctypes.get_last_error())
        old, self.hook = self.hook, hook
        if old:
            user32.UnhookWindowsHookEx(old)

    def on_key(self, code, w_param, l_param):
        if code == HC_ACTION:
            event = ctypes.cast(l_param, ctypes.POINTER(KBDLLHOOKSTRUCT)).contents
            if not event.flags & LLKHF_INJECTED and self.handle(event.vkCode, w_param):
                return 1
        return user32.CallNextHookEx(self.hook, code, w_param, l_param)

    def handle(self, vk, w_param):
        down = w_param in (WM_KEYDOWN, WM_SYSKEYDOWN)
        up = w_param in (WM_KEYUP, WM_SYSKEYUP)

        if vk in (VK_LCONTROL, VK_RCONTROL):
            if down:
                self.ctrl_down.add(vk)
            elif up:
                self.ctrl_down.discard(vk)
            return False

        if vk != VK_CAPITAL:
            return False

        if down:
            if self.caps_swallowed:
                return True
            if self.caps_passed:
                return False
            if self.ctrl_down:
                self.caps_swallowed = True
                user32.PostThreadMessageW(self.thread_id, WM_APP, 0, 0)
                return True
            self.caps_passed = True
            return False

        if up:
            swallowed = self.caps_swallowed
            self.caps_swallowed = False
            self.caps_passed = False
            return swallowed
        return False

    @staticmethod
    def tap_caps_lock():
        inputs = (INPUT * 2)()
        for item, flags in zip(inputs, (0, KEYEVENTF_KEYUP)):
            item.type = INPUT_KEYBOARD
            item.ki = KEYBDINPUT(VK_CAPITAL, 0, flags, 0, KEYBOARDMANAGER_INJECTED_FLAG)
        if user32.SendInput(2, inputs, ctypes.sizeof(INPUT)) != 2:
            raise ctypes.WinError(ctypes.get_last_error())

    def run(self):
        self.install()
        if not user32.SetTimer(None, 0, REHOOK_INTERVAL_MS, None):
            raise ctypes.WinError(ctypes.get_last_error())
        message = wintypes.MSG()
        while user32.GetMessageW(ctypes.byref(message), None, 0, 0) > 0:
            if message.message == WM_TIMER:
                self.install()
            elif message.message == WM_APP:
                self.tap_caps_lock()


if __name__ == "__main__":
    CtrlCapsLock().run()
