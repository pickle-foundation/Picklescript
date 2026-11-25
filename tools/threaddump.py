"""Dump RIP and raw stack words of every thread in a running process.

Usage: python tools/threaddump.py <exe> [seconds]
"""
import ctypes
import ctypes.wintypes as wt
import subprocess
import sys
import time

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
psapi = ctypes.WinDLL("psapi", use_last_error=True)

TH32CS_SNAPTHREAD = 0x00000004
THREAD_SUSPEND_RESUME = 0x0002
THREAD_GET_CONTEXT = 0x0008
THREAD_QUERY_INFORMATION = 0x0040
CONTEXT_AMD64 = 0x00100000
CONTEXT_CONTROL = 0x00000001
CONTEXT_INTEGER = 0x00000002


class THREADENTRY32(ctypes.Structure):
    _fields_ = [
        ("dwSize", wt.DWORD),
        ("cntUsage", wt.DWORD),
        ("th32ThreadID", wt.DWORD),
        ("th32OwnerProcessID", wt.DWORD),
        ("tpBasePri", ctypes.c_long),
        ("tpDeltaPri", ctypes.c_long),
        ("dwFlags", wt.DWORD),
    ]


class MODULEINFO(ctypes.Structure):
    _fields_ = [
        ("lpBaseOfDll", ctypes.c_void_p),
        ("SizeOfImage", wt.DWORD),
        ("EntryPoint", ctypes.c_void_p),
    ]


k32.CreateToolhelp32Snapshot.restype = wt.HANDLE
k32.CreateToolhelp32Snapshot.argtypes = [wt.DWORD, wt.DWORD]
k32.Thread32First.argtypes = [wt.HANDLE, ctypes.POINTER(THREADENTRY32)]
k32.Thread32Next.argtypes = [wt.HANDLE, ctypes.POINTER(THREADENTRY32)]
k32.OpenThread.restype = wt.HANDLE
k32.OpenThread.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
k32.SuspendThread.argtypes = [wt.HANDLE]
k32.ResumeThread.argtypes = [wt.HANDLE]
k32.CloseHandle.argtypes = [wt.HANDLE]
k32.ReadProcessMemory.argtypes = [
    wt.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_size_t),
]
psapi.EnumProcessModules.argtypes = [
    wt.HANDLE, ctypes.POINTER(wt.HMODULE), wt.DWORD, ctypes.POINTER(wt.DWORD)]
psapi.GetModuleInformation.argtypes = [
    wt.HANDLE, wt.HMODULE, ctypes.POINTER(MODULEINFO), wt.DWORD]
psapi.GetModuleBaseNameW.argtypes = [wt.HANDLE, wt.HMODULE, wt.LPWSTR, wt.DWORD]


def main():
    # Two modes: launch an exe (`<exe> [seconds] [arg...]`) or attach to a
    # running process (`--pid <pid>`).
    if sys.argv[1] == "--pid":
        pid = int(sys.argv[2])
        proc = None
    else:
        exe = sys.argv[1]
        wait = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0
        extra = sys.argv[3:]
        proc = subprocess.Popen([exe] + extra, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE)
        time.sleep(wait)
        if proc.poll() is not None:
            print("process already exited:", proc.returncode)
            print(proc.stdout.read().decode(errors="replace"))
            return
        pid = proc.pid
    hproc = k32.OpenProcess(0x0010 | 0x0400, False, pid)  # VM_READ | QUERY_INFO
    mods = (wt.HMODULE * 256)()
    need = wt.DWORD(0)
    psapi.EnumProcessModules(hproc, mods, ctypes.sizeof(mods), ctypes.byref(need))
    nmods = need.value // ctypes.sizeof(wt.HMODULE)
    modranges = []
    for i in range(nmods):
        mi = MODULEINFO()
        psapi.GetModuleInformation(hproc, mods[i], ctypes.byref(mi), ctypes.sizeof(mi))
        name = ctypes.create_unicode_buffer(260)
        psapi.GetModuleBaseNameW(hproc, mods[i], name, 260)
        modranges.append((mi.lpBaseOfDll, mi.lpBaseOfDll + mi.SizeOfImage, name.value))

    def where(addr):
        for lo, hi, name in modranges:
            if lo <= addr < hi:
                return "%s+%X" % (name, addr - lo)
        return None

    snap = k32.CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0)
    entry = THREADENTRY32()
    entry.dwSize = ctypes.sizeof(THREADENTRY32)
    tids = []
    ok = k32.Thread32First(snap, ctypes.byref(entry))
    while ok:
        if entry.th32OwnerProcessID == pid:
            tids.append(entry.th32ThreadID)
        ok = k32.Thread32Next(snap, ctypes.byref(entry))
    k32.CloseHandle(snap)

    print("pid", pid, "threads", tids)
    ntdll = ctypes.WinDLL("ntdll", use_last_error=True)
    ntdll.NtQueryInformationThread.argtypes = [
        wt.HANDLE, ctypes.c_int, ctypes.c_void_p, wt.ULONG,
        ctypes.POINTER(wt.ULONG)]
    for tid in tids:
        h0 = k32.OpenThread(THREAD_QUERY_INFORMATION, False, tid)
        if h0:
            buf = ctypes.c_void_p(0)
            ret = wt.ULONG(0)
            st = ntdll.NtQueryInformationThread(h0, 9, ctypes.byref(buf), 8,
                                                ctypes.byref(ret))
            if st == 0 and buf.value:
                print("  tid %6d start=%016X %s"
                      % (tid, buf.value, where(buf.value)))
            k32.CloseHandle(h0)
    for tid in tids:
        h = k32.OpenThread(
            THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION,
            False, tid)
        if not h:
            print("  tid", tid, "open failed", ctypes.get_last_error())
            continue
        k32.SuspendThread(h)
        ctx = ctypes.create_string_buffer(0x4D0)
        ctypes.memset(ctx, 0, 0x4D0)
        ctypes.cast(ctx, ctypes.POINTER(ctypes.c_uint32))[0x30 // 4] = CONTEXT_AMD64 | CONTEXT_CONTROL | CONTEXT_INTEGER
        ok = k32.GetThreadContext(h, ctx)
        if not ok:
            print("  tid", tid, "GetThreadContext failed", ctypes.get_last_error())
            k32.ResumeThread(h)
            k32.CloseHandle(h)
            continue
        rip = ctypes.cast(ctypes.byref(ctx, 0xF8), ctypes.POINTER(ctypes.c_uint64))[0]
        rsp = ctypes.cast(ctypes.byref(ctx, 0x98), ctypes.POINTER(ctypes.c_uint64))[0]
        print("  tid %6d rip=%016X %s rsp=%016X" % (tid, rip, where(rip), rsp))
        names = [("rax", 0x78), ("rcx", 0x80), ("rdx", 0x88), ("rbx", 0x90),
                 ("rbp", 0xA0), ("rsi", 0xA8), ("rdi", 0xB0), ("r8", 0xB8),
                 ("r9", 0xC0), ("r10", 0xC8), ("r11", 0xD0), ("r12", 0xD8),
                 ("r13", 0xE0), ("r14", 0xE8), ("r15", 0xF0)]
        regs = []
        for nm, off in names:
            v = ctypes.cast(ctypes.byref(ctx, off),
                            ctypes.POINTER(ctypes.c_uint64))[0]
            regs.append("%s=%016X" % (nm, v))
        print("        " + " ".join(regs))
        buf = ctypes.create_string_buffer(8 * 64)
        got = ctypes.c_size_t(0)
        if k32.ReadProcessMemory(hproc, ctypes.c_void_p(rsp), buf, 8 * 64,
                                 ctypes.byref(got)):
            words = [ctypes.cast(ctypes.byref(buf, 8 * i), ctypes.POINTER(ctypes.c_uint64))[0]
                     for i in range(64)]
            for i, w in enumerate(words):
                loc = where(w)
                if loc:
                    print("        +%03X %016X %s" % (i * 8, w, loc))
        k32.ResumeThread(h)
        k32.CloseHandle(h)
    if proc is not None:
        proc.kill()


if __name__ == "__main__":
    main()
