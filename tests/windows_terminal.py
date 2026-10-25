"""Owned ConPTY sessions for native package task acceptance."""
import ctypes as c
from ctypes import wintypes as w
import os
from pathlib import Path
import re
import subprocess
import threading
import time

from windows_process import Job, checked, close, function


class Coord(c.Structure):
    _fields_ = [('x', c.c_short), ('y', c.c_short)]


class Startup(c.Structure):
    _fields_ = [('cb', w.DWORD), ('reserved', w.LPWSTR), ('desktop', w.LPWSTR),
                ('title', w.LPWSTR), ('x', w.DWORD), ('y', w.DWORD),
                ('width', w.DWORD), ('height', w.DWORD), ('columns', w.DWORD),
                ('rows', w.DWORD), ('fill', w.DWORD), ('flags', w.DWORD),
                ('show', w.WORD), ('reserved_size', w.WORD), ('reserved_bytes', c.c_void_p),
                ('input', w.HANDLE), ('output', w.HANDLE), ('error', w.HANDLE)]


class ExtendedStartup(c.Structure):
    _fields_ = [('basic', Startup), ('attributes', c.c_void_p)]


class Process(c.Structure):
    _fields_ = [('process', w.HANDLE), ('thread', w.HANDLE), ('pid', w.DWORD), ('tid', w.DWORD)]


pipe = function('CreatePipe', [c.POINTER(w.HANDLE), c.POINTER(w.HANDLE), c.c_void_p, w.DWORD])
create_console = function('CreatePseudoConsole', [Coord, w.HANDLE, w.HANDLE, w.DWORD, c.POINTER(w.HANDLE)], c.c_long)
resize_console = function('ResizePseudoConsole', [w.HANDLE, Coord], c.c_long)
close_console = function('ClosePseudoConsole', [w.HANDLE], None)
attributes = function('InitializeProcThreadAttributeList', [c.c_void_p, w.DWORD, w.DWORD, c.POINTER(c.c_size_t)])
attribute = function('UpdateProcThreadAttribute', [c.c_void_p, w.DWORD, c.c_size_t, c.c_void_p, c.c_size_t, c.c_void_p, c.c_void_p])
delete_attributes = function('DeleteProcThreadAttributeList', [c.c_void_p], None)
create_process = function('CreateProcessW', [w.LPCWSTR, w.LPWSTR, c.c_void_p, c.c_void_p, w.BOOL,
    w.DWORD, c.c_void_p, w.LPCWSTR, c.POINTER(Startup), c.POINTER(Process)])
assign = function('AssignProcessToJobObject', [w.HANDLE, w.HANDLE])
resume = function('ResumeThread', [w.HANDLE], w.DWORD)
peek = function('PeekNamedPipe', [w.HANDLE, c.c_void_p, w.DWORD, c.c_void_p, c.POINTER(w.DWORD), c.c_void_p])
read = function('ReadFile', [w.HANDLE, c.c_void_p, w.DWORD, c.POINTER(w.DWORD), c.c_void_p])
write = function('WriteFile', [w.HANDLE, c.c_void_p, w.DWORD, c.POINTER(w.DWORD), c.c_void_p])
wait = function('WaitForSingleObject', [w.HANDLE, w.DWORD], w.DWORD)
exit_code = function('GetExitCodeProcess', [w.HANDLE, c.POINTER(w.DWORD)])
terminate_process = function('TerminateProcess', [w.HANDLE, w.UINT])


def success(hr):
    if hr < 0:
        raise OSError(f'ConPTY HRESULT 0x{hr & 0xffffffff:08x}')


class Terminal:
    def __init__(self, command, *, cwd, env, columns=80, rows=25):
        self.console = w.HANDLE()
        self.handles = []
        self.process = Process()
        self.job = Job()
        self.stop = threading.Event()
        self.output = bytearray()
        self.error = None
        self.reader = None
        try:
            input_read, self.input = w.HANDLE(), w.HANDLE()
            self.output_handle, output_write = w.HANDLE(), w.HANDLE()
            checked(pipe(c.byref(input_read), c.byref(self.input), None, 0))
            self.handles.extend([input_read, self.input])
            checked(pipe(c.byref(self.output_handle), c.byref(output_write), None, 0))
            self.handles.extend([self.output_handle, output_write])
            success(create_console(Coord(columns, rows), input_read, output_write, 0, c.byref(self.console)))
            checked(close(input_read)); self.handles.remove(input_read)
            checked(close(output_write)); self.handles.remove(output_write)
            size = c.c_size_t()
            attributes(None, 1, 0, c.byref(size))
            storage = c.create_string_buffer(size.value)
            checked(attributes(storage, 1, 0, c.byref(size)))
            try:
                checked(attribute(storage, 0, 0x20016, self.console, c.sizeof(w.HANDLE), None, None))
                startup = ExtendedStartup()
                startup.basic.cb = c.sizeof(startup)
                startup.attributes = c.cast(storage, c.c_void_p)
                block = c.create_unicode_buffer('\0'.join(f'{key}={value}' for key, value in
                    sorted(env.items(), key=lambda item: item[0].upper())) + '\0\0')
                arguments = c.create_unicode_buffer(subprocess.list2cmdline(list(map(str, command))))
                executable = Path(command[0])
                if not executable.is_file():
                    executable = executable.with_suffix('.exe')
                checked(create_process(str(executable), arguments, None, None, False,
                    0x80000 | 0x400 | 4, block, str(cwd), c.byref(startup.basic), c.byref(self.process)))
                checked(assign(self.job.handle, self.process.process))
                if resume(self.process.thread) != 1:
                    raise AssertionError('ConPTY initial thread suspension changed')
            finally:
                delete_attributes(storage)
            checked(close(self.process.thread)); self.process.thread = None
            self.reader = threading.Thread(target=self._read, daemon=True)
            self.reader.start()
        except BaseException:
            self.close()
            raise

    @property
    def pid(self):
        return self.process.pid

    def _read(self):
        try:
            while not self.stop.is_set():
                available = w.DWORD()
                if not peek(self.output_handle, None, 0, None, c.byref(available), None):
                    if c.get_last_error() == 109:
                        break
                    raise c.WinError(c.get_last_error())
                if available.value:
                    buffer = c.create_string_buffer(min(available.value, 4096))
                    count = w.DWORD()
                    checked(read(self.output_handle, buffer, len(buffer), c.byref(count), None))
                    self.output.extend(buffer.raw[:count.value])
                    if len(self.output) > 1024 * 1024:
                        raise AssertionError('ConPTY output exceeded its bound')
                else:
                    self.stop.wait(0.01)
        except BaseException as error:
            self.error = error

    def text(self):
        if self.error:
            raise self.error
        return re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b'', bytes(self.output))

    def read_until(self, pattern, timeout=30):
        deadline = time.monotonic() + timeout
        while True:
            found = re.search(pattern, self.text())
            if found:
                return found
            if time.monotonic() >= deadline:
                raise AssertionError(f'ConPTY output timed out: {self.text()!r}')
            self.stop.wait(0.01)

    def write(self, value):
        count = w.DWORD()
        checked(write(self.input, value, len(value), c.byref(count), None))
        if count.value != len(value):
            raise AssertionError('Partial ConPTY input write')

    def resize(self, columns, rows):
        success(resize_console(self.console, Coord(columns, rows)))

    def wait(self, timeout=10):
        outcome = wait(self.process.process, int(timeout * 1000))
        if outcome != 0:
            raise AssertionError(f'ConPTY process wait failed: {outcome}')
        result = w.DWORD()
        checked(exit_code(self.process.process, c.byref(result)))
        if not self.job.settled():
            raise AssertionError('ConPTY task left owned descendants')
        return result.value

    def close(self):
        if self.process.process and wait(self.process.process, 0) == 258:
            checked(terminate_process(self.process.process, 1))
            if wait(self.process.process, 5000) != 0:
                raise AssertionError('ConPTY child did not stop')
        if self.job:
            try:
                if self.job.active():
                    self.job.terminate()
            finally:
                self.job.close(); self.job = None
        if self.console:
            close_console(self.console)
            self.console = None
        self.stop.set()
        if self.reader:
            self.reader.join(5)
            if self.reader.is_alive():
                raise AssertionError('ConPTY output observer did not stop')
        for handle in (self.process.thread, self.process.process, *self.handles):
            if handle:
                checked(close(handle))
        self.handles.clear()
        self.process = Process()

    def __enter__(self):
        return self

    def __exit__(self, *exception):
        self.close()
