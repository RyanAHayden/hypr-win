import ctypes
import time
from ctypes import wintypes


TH32CS_SNAPPROCESS = 0x00000002
ERROR_NO_MORE_FILES = 18
SW_HIDE = 0

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

user32.EnumWindows.argtypes = [
    ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM),
    wintypes.LPARAM,
]
user32.EnumWindows.restype = wintypes.BOOL
user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.IsWindowVisible.restype = wintypes.BOOL
user32.GetWindowThreadProcessId.argtypes = [
    wintypes.HWND,
    ctypes.POINTER(wintypes.DWORD),
]
user32.GetWindowThreadProcessId.restype = wintypes.DWORD
user32.ShowWindowAsync.argtypes = [wintypes.HWND, ctypes.c_int]
user32.ShowWindowAsync.restype = wintypes.BOOL

kernel32.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
kernel32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE


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

kernel32.Process32FirstW.argtypes = [
    wintypes.HANDLE,
    ctypes.POINTER(PROCESSENTRY32W),
]
kernel32.Process32FirstW.restype = wintypes.BOOL
kernel32.Process32NextW.argtypes = kernel32.Process32FirstW.argtypes
kernel32.Process32NextW.restype = wintypes.BOOL
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
kernel32.CloseHandle.restype = wintypes.BOOL


def get_processes():
    snapshot = kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if snapshot == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())

    processes = {}
    try:
        entry = PROCESSENTRY32W()
        entry.dwSize = ctypes.sizeof(entry)
        if not kernel32.Process32FirstW(snapshot, ctypes.byref(entry)):
            raise ctypes.WinError(ctypes.get_last_error())
        while True:
            processes[entry.th32ProcessID] = (
                entry.szExeFile,
                entry.th32ParentProcessID,
            )
            ctypes.set_last_error(0)
            if not kernel32.Process32NextW(snapshot, ctypes.byref(entry)):
                error = ctypes.get_last_error()
                if error != ERROR_NO_MORE_FILES:
                    raise ctypes.WinError(error)
                break
    finally:
        if not kernel32.CloseHandle(snapshot):
            raise ctypes.WinError(ctypes.get_last_error())
    return processes


def is_sshd_descendant(process_id, processes):
    seen = set()
    while process_id in processes and process_id not in seen:
        image_name, parent_id = processes[process_id]
        if image_name.casefold() == "sshd.exe":
            return True
        seen.add(process_id)
        process_id = parent_id
    return False


def hide_sshd_windows():
    processes = get_processes()

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def hide_window(handle, _):
        if not user32.IsWindowVisible(handle):
            return True
        process_id = wintypes.DWORD()
        if not user32.GetWindowThreadProcessId(handle, ctypes.byref(process_id)):
            return True
        if is_sshd_descendant(process_id.value, processes):
            user32.ShowWindowAsync(handle, SW_HIDE)
        return True

    if not user32.EnumWindows(hide_window, 0):
        raise ctypes.WinError(ctypes.get_last_error())


def main():
    while True:
        hide_sshd_windows()
        time.sleep(1)


if __name__ == "__main__":
    main()
