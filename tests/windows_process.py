"""Package-owned native process containment; independent of the runtime tests."""
import ctypes
from ctypes import wintypes
import time
from pathlib import Path
import os

k = ctypes.WinDLL('kernel32', use_last_error=True)


def function(name, arguments, result=wintypes.BOOL):
    value = getattr(k, name)
    value.argtypes, value.restype = arguments, result
    return value


create = function('CreateJobObjectW', [ctypes.c_void_p, wintypes.LPCWSTR], wintypes.HANDLE)
close = function('CloseHandle', [wintypes.HANDLE])
set_info = function('SetInformationJobObject', [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD])
query = function('QueryInformationJobObject', [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD, ctypes.c_void_p])
assign = function('AssignProcessToJobObject', [wintypes.HANDLE, wintypes.HANDLE])
stop = function('TerminateJobObject', [wintypes.HANDLE, wintypes.UINT])
snapshot = function('CreateToolhelp32Snapshot', [wintypes.DWORD, wintypes.DWORD], wintypes.HANDLE)
open_thread = function('OpenThread', [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD], wintypes.HANDLE)
resume = function('ResumeThread', [wintypes.HANDLE], wintypes.DWORD)


def checked(value):
    if not value:
        raise ctypes.WinError(ctypes.get_last_error())
    return value


class Limits(ctypes.Structure):
    _fields_ = [('times', ctypes.c_int64 * 2), ('flags', wintypes.DWORD),
                ('working', ctypes.c_size_t * 2), ('active', wintypes.DWORD),
                ('affinity', ctypes.c_size_t), ('priority', wintypes.DWORD), ('scheduling', wintypes.DWORD)]


class Extended(ctypes.Structure):
    _fields_ = [('basic', Limits), ('io', ctypes.c_uint64 * 6), ('memory', ctypes.c_size_t * 4)]


class Accounting(ctypes.Structure):
    _fields_ = [('times', ctypes.c_int64 * 4), ('faults', wintypes.DWORD),
                ('total', wintypes.DWORD), ('active', wintypes.DWORD), ('terminated', wintypes.DWORD)]


class Thread(ctypes.Structure):
    _fields_ = [('size', wintypes.DWORD), ('usage', wintypes.DWORD), ('id', wintypes.DWORD),
                ('owner', wintypes.DWORD), ('priority', wintypes.LONG), ('delta', wintypes.LONG),
                ('flags', wintypes.DWORD)]


first = function('Thread32First', [wintypes.HANDLE, ctypes.POINTER(Thread)])
next_thread = function('Thread32Next', [wintypes.HANDLE, ctypes.POINTER(Thread)])


class Job:
    def __init__(self):
        self.handle = checked(create(None, None))
        limits = Extended()
        limits.basic.flags = 0x2000
        try:
            checked(set_info(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)))
        except BaseException:
            self.close()
            raise

    def start(self, child):
        checked(assign(self.handle, int(child._handle)))
        inventory = snapshot(4, 0)
        if inventory == ctypes.c_void_p(-1).value:
            raise ctypes.WinError(ctypes.get_last_error())
        ids = []
        try:
            entry = Thread(size=ctypes.sizeof(Thread))
            checked(first(inventory, ctypes.byref(entry)))
            while True:
                if entry.owner == child.pid:
                    ids.append(entry.id)
                if not next_thread(inventory, ctypes.byref(entry)):
                    if ctypes.get_last_error() != 18:
                        raise ctypes.WinError(ctypes.get_last_error())
                    break
        finally:
            checked(close(inventory))
        if len(ids) != 1:
            raise AssertionError(f'Unexpected suspended thread inventory: {ids}')
        thread = checked(open_thread(2, False, ids[0]))
        try:
            if resume(thread) != 1:
                raise AssertionError('Initial thread did not have one suspension')
        finally:
            checked(close(thread))

    def active(self):
        data = Accounting()
        checked(query(self.handle, 1, ctypes.byref(data), ctypes.sizeof(data), None))
        return data.active

    def settled(self):
        # Job accounting can lag the process-handle signal at CRT exit.
        # Require an empty job within a bounded grace period; live descendants
        # still fail acceptance and are terminated by the caller.
        deadline = time.monotonic() + 0.2
        while self.active():
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.01)
        return True

    def retire_helpers(self, selected):
        class Inventory(ctypes.Structure):
            _fields_ = [('assigned', wintypes.DWORD), ('count', wintypes.DWORD),
                        ('pids', ctypes.c_size_t * 256)]
        inventory = Inventory()
        checked(query(self.handle, 3, ctypes.byref(inventory), ctypes.sizeof(inventory), None))
        if inventory.count > 256:
            raise AssertionError('Compiler helper inventory exceeded its bound')
        allowed = {os.path.normcase(str(Path(p).resolve(strict=True))) for p in selected}
        open_process = function('OpenProcess', [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD], wintypes.HANDLE)
        image = function('QueryFullProcessImageNameW', [wintypes.HANDLE, wintypes.DWORD,
                                                      wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)])
        observed = []
        for pid in inventory.pids[:inventory.count]:
            process = checked(open_process(0x1000, False, pid))
            try:
                path = ctypes.create_unicode_buffer(32768)
                length = wintypes.DWORD(len(path))
                checked(image(process, 0, path, ctypes.byref(length)))
                if os.path.normcase(path.value) not in allowed:
                    raise AssertionError(f'Unexpected build descendant: {pid} {path.value}')
                observed.append((pid, path.value))
            finally:
                checked(close(process))
        self.terminate()
        return observed

    def terminate(self):
        checked(stop(self.handle, 1))
        deadline = time.monotonic() + 5
        while self.active():
            if time.monotonic() >= deadline:
                raise AssertionError('Owned package process tree did not stop')
            time.sleep(0.01)

    def close(self):
        if self.handle:
            handle, self.handle = self.handle, None
            checked(close(handle))
