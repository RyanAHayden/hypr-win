#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

static int report_error(const wchar_t *operation, DWORD error)
{
    wchar_t message[1024];
    char utf8[4096];
    DWORD written;
    _snwprintf_s(message, 1024, _TRUNCATE,
        L"powershell-ssh: %ls failed (Windows error %lu).\r\n", operation, error);
    int length = WideCharToMultiByte(CP_UTF8, 0, message, -1,
        utf8, sizeof(utf8), NULL, NULL);
    if (length > 0) {
        WriteFile(GetStdHandle(STD_ERROR_HANDLE), utf8, (DWORD)length - 1,
            &written, NULL);
    }
    return 255;
}

static BOOL WINAPI handle_control(DWORD event)
{
    // Let PowerShell handle Ctrl+C without terminating this waiting launcher.
    return event == CTRL_C_EVENT || event == CTRL_BREAK_EVENT;
}

int wmain(void)
{
    wchar_t *arguments = GetCommandLineW();
    if (*arguments == L'"') {
        arguments++;
        while (*arguments && *arguments != L'"') {
            arguments++;
        }
        if (*arguments) {
            arguments++;
        }
    } else {
        while (*arguments && *arguments != L' ' && *arguments != L'\t') {
            arguments++;
        }
    }
    while (*arguments == L' ' || *arguments == L'\t') {
        arguments++;
    }
    wchar_t config[32768];
    wchar_t shell[32768];
    DWORD length = GetModuleFileNameW(NULL, config, 32768);
    if (!length || length >= 32768) {
        return report_error(L"GetModuleFileNameW", GetLastError());
    }
    wchar_t *filename = wcsrchr(config, L'\\');
    if (!filename || (size_t)(filename - config) + 1 + wcslen(L"launcher.ini") >= 32768) {
        return report_error(L"configuration path", ERROR_BAD_PATHNAME);
    }
    wcscpy(filename + 1, L"launcher.ini");
    length = GetPrivateProfileStringW(L"shell", L"path", L"", shell, 32768, config);
    if (!length || length >= 32767) {
        return report_error(L"reading launcher.ini shell path", ERROR_INVALID_DATA);
    }
    DWORD attributes = GetFileAttributesW(shell);
    if (attributes == INVALID_FILE_ATTRIBUTES) {
        return report_error(L"locating PowerShell", GetLastError());
    }
    if (attributes & FILE_ATTRIBUTE_DIRECTORY) {
        return report_error(L"PowerShell executable path", ERROR_DIRECTORY);
    }

    size_t command_size = wcslen(shell) + wcslen(arguments) + 4;
    if (command_size > 32767) {
        return report_error(L"command length", ERROR_FILENAME_EXCED_RANGE);
    }
    wchar_t *command = calloc(command_size, sizeof(wchar_t));
    if (!command) {
        return report_error(L"command allocation", ERROR_NOT_ENOUGH_MEMORY);
    }
    swprintf(command, command_size, L"\"%ls\" %ls", shell, arguments);

    STARTUPINFOW inherited = {0};
    GetStartupInfoW(&inherited);
    // The manifest inherits an existing PTY but prevents new console allocation.
    BOOL has_console = GetConsoleCP() != 0;
    if (has_console && !SetConsoleCtrlHandler(handle_control, TRUE)) {
        DWORD error = GetLastError();
        free(command);
        return report_error(L"SetConsoleCtrlHandler", error);
    }
    STARTUPINFOW startup = {0};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    if (inherited.dwFlags & STARTF_USESTDHANDLES) {
        startup.hStdInput = inherited.hStdInput;
        startup.hStdOutput = inherited.hStdOutput;
        startup.hStdError = inherited.hStdError;
    } else {
        startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
        startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
        startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    }
    PROCESS_INFORMATION process = {0};
    BOOL created = CreateProcessW(shell, command, NULL, NULL, TRUE,
        has_console ? 0 : CREATE_NO_WINDOW, NULL, NULL, &startup, &process);
    DWORD error = GetLastError();
    free(command);
    if (!created) {
        return report_error(L"CreateProcessW", error);
    }
    CloseHandle(process.hThread);
    DWORD wait = WaitForSingleObject(process.hProcess, INFINITE);
    DWORD exit_code = 255;
    if (wait != WAIT_OBJECT_0 || !GetExitCodeProcess(process.hProcess, &exit_code)) {
        error = GetLastError();
        CloseHandle(process.hProcess);
        return report_error(L"waiting for PowerShell", error);
    }
    CloseHandle(process.hProcess);
    return (int)exit_code;
}
