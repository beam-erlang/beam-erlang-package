"""Bound an acceptance command and its owned process group."""
import os
import signal
import subprocess


def capture(command, *, cwd, env, input=None, text=True, capture_output=True, timeout=90):
    if not capture_output:
        raise ValueError('Acceptance commands require captured output')
    command=[str(arg) for arg in command]
    child=subprocess.Popen(command,cwd=cwd,env=env,text=text,
        stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True,close_fds=True)
    try:
        out,err=child.communicate(input,timeout=timeout)
    except BaseException:
        try:
            os.killpg(child.pid,signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.communicate()
        raise
    result = subprocess.CompletedProcess(command,child.returncode,out,err)
    result.pid = child.pid
    return result
