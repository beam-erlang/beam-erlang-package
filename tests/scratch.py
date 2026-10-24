"""Disposable package acceptance payloads and catchable interruption cleanup."""
from contextlib import contextmanager
import os
from pathlib import Path
import shutil
import signal
import sys


@contextmanager
def scratch(root):
    previous=signal.getsignal(signal.SIGTERM)
    def interrupted(number,frame):
        raise SystemExit(128+number)
    signal.signal(signal.SIGTERM,interrupted)
    try:
        yield
    finally:
        signal.signal(signal.SIGTERM,previous)
        if os.environ.get('BEAM_TEST_KEEP_WORK')=='1':
            size=sum(p.stat().st_size for p in Path(root).rglob('*') if p.is_file() and not p.is_symlink())
            print(f'Retained debug payload: {root} ({size} bytes)',file=sys.stderr)
        else:
            shutil.rmtree(root)
