#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <string.h>
#include <string>

bool EnableDebugPrivilege() {
    HANDLE token;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &token))
        return false;

    TOKEN_PRIVILEGES tp;
    tp.PrivilegeCount = 1;
    tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    if (!LookupPrivilegeValueA(NULL, "SeDebugPrivilege", &tp.Privileges[0].Luid)) {
        CloseHandle(token);
        return false;
    }

    BOOL ok = AdjustTokenPrivileges(token, FALSE, &tp, sizeof(tp), NULL, NULL);
    DWORD err = GetLastError();
    CloseHandle(token);
    return ok && err == ERROR_SUCCESS;
}

DWORD FindProcessId(const char* processName) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;

    PROCESSENTRY32 pe;
    pe.dwSize = sizeof(pe);

    if (Process32First(snap, &pe)) {
        do {
            if (lstrcmpiA(pe.szExeFile, processName) == 0) {
                CloseHandle(snap);
                return pe.th32ProcessID;
            }
        } while (Process32Next(snap, &pe));
    }
    CloseHandle(snap);
    return 0;
}

bool InjectDLL(DWORD pid, const char* dllPath) {
    HANDLE proc = OpenProcess(PROCESS_ALL_ACCESS, FALSE, pid);
    if (!proc) {
        printf("  [ERROR] Failed to open process (PID: %lu). Run as administrator?\n", pid);
        return false;
    }

    // Allocate memory in target process for DLL path
    size_t pathLen = strlen(dllPath) + 1;
    LPVOID remoteMem = VirtualAllocEx(proc, NULL, pathLen, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!remoteMem) {
        printf("  [ERROR] Failed to allocate memory in target process.\n");
        CloseHandle(proc);
        return false;
    }

    // Write DLL path into target process
    if (!WriteProcessMemory(proc, remoteMem, dllPath, pathLen, NULL)) {
        printf("  [ERROR] Failed to write DLL path to target process.\n");
        VirtualFreeEx(proc, remoteMem, 0, MEM_RELEASE);
        CloseHandle(proc);
        return false;
    }

    // Get LoadLibraryA address (same in all processes)
    HMODULE kernel32 = GetModuleHandleA("kernel32.dll");
    FARPROC loadLib = GetProcAddress(kernel32, "LoadLibraryA");

    // Create remote thread that calls LoadLibraryA with our DLL path
    HANDLE thread = CreateRemoteThread(proc, NULL, 0,
        (LPTHREAD_START_ROUTINE)loadLib, remoteMem, 0, NULL);
    if (!thread) {
        printf("  [ERROR] Failed to create remote thread. Error: %lu\n", GetLastError());
        VirtualFreeEx(proc, remoteMem, 0, MEM_RELEASE);
        CloseHandle(proc);
        return false;
    }

    // Wait for injection to complete
    DWORD waitResult = WaitForSingleObject(thread, 10000);
    if (waitResult == WAIT_TIMEOUT) {
        printf("  [ERROR] Remote thread timed out (10s)\n");
    }

    // Check if DLL was loaded
    DWORD exitCode = 0;
    GetExitCodeThread(thread, &exitCode);
    printf("  [DEBUG] Remote thread exit code: 0x%lX (%s)\n", exitCode,
        exitCode != 0 ? "LoadLibrary succeeded" : "LoadLibrary FAILED");

    if (exitCode == 0) {
        // LoadLibraryA returned NULL — get the error from the target process
        printf("  [DEBUG] DLL path sent: %s\n", dllPath);
        printf("  [DEBUG] Path length: %zu\n", strlen(dllPath));
        printf("  [HINT] Possible causes:\n");
        printf("         - DLL has missing dependencies (run: dumpbin /dependents overlay.dll)\n");
        printf("         - DLL path too long or has special characters\n");
        printf("         - DLL architecture mismatch (must be x64 for RPCS3)\n");
    }

    CloseHandle(thread);
    VirtualFreeEx(proc, remoteMem, 0, MEM_RELEASE);
    CloseHandle(proc);

    return exitCode != 0;
}

int main(int argc, char* argv[]) {
    printf("============================================\n");
    printf("  RandOverlay Vulkan Injector\n");
    printf("============================================\n\n");

    // Get DLL path (same directory as injector)
    char exePath[MAX_PATH];
    GetModuleFileNameA(NULL, exePath, MAX_PATH);
    std::string dllPath(exePath);
    size_t lastSlash = dllPath.find_last_of("\\/");
    dllPath = dllPath.substr(0, lastSlash + 1) + "overlay.dll";

    // Check DLL exists
    if (GetFileAttributesA(dllPath.c_str()) == INVALID_FILE_ATTRIBUTES) {
        printf("  [ERROR] overlay.dll not found at:\n  %s\n", dllPath.c_str());
        printf("\nPress Enter to exit...");
        getchar();
        return 1;
    }

    if (EnableDebugPrivilege()) {
        printf("  SeDebugPrivilege enabled\n");
    } else {
        printf("  [WARN] Could not enable SeDebugPrivilege (Error: %lu)\n", GetLastError());
    }

    printf("  Searching for RPCS3 process...\n");
    DWORD pid = FindProcessId("rpcs3.exe");
    if (!pid) {
        printf("  [ERROR] RPCS3 not running. Launch it first.\n");
        printf("\nPress Enter to exit...");
        getchar();
        return 1;
    }
    printf("  Found RPCS3 (PID: %lu)\n", pid);

    printf("  Injecting overlay DLL...\n");
    if (InjectDLL(pid, dllPath.c_str())) {
        printf("  [OK] Overlay DLL injected successfully!\n\n");
        printf("  The overlay is now active in RPCS3.\n");
        printf("  Monitoring Archipelago log for events.\n");
    } else {
        printf("  [FAILED] Injection failed.\n");
        printf("  Use borderless windowed + AHK/PS1 overlay instead.\n");
    }

    printf("\nPress Enter to exit...");
    getchar();
    return 0;
}
