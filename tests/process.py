"""Bound an acceptance command and its owned process group."""
import os
import signal
import subprocess


def capture(command, *, cwd, env, input=None, text=True, capture_output=True, timeout=90):
    if not capture_output:
        raise ValueError('Acceptance commands require captured output')
    command=[str(arg) for arg in command]
    job = None
    if os.name == 'nt':
        from windows_process import Job
        job = Job()
    try:
        child=subprocess.Popen(command,cwd=cwd,env=env,text=text,encoding='utf-8' if text else None,
            stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=not job,
            creationflags=4 if job else 0,close_fds=True)
        if job:
            job.start(child)
    except BaseException:
        if job:
            job.close()
        if 'child' in locals():
            child.kill()
            child.communicate(timeout=5)
        raise
    try:
        out,err=child.communicate(input,timeout=timeout)
        if job and job.active():
            raise AssertionError('Owned package descendants survived the command')
    except BaseException:
        if job:
            job.terminate()
        else:
            try:
                os.killpg(child.pid,signal.SIGKILL)
            except ProcessLookupError:
                pass
        child.communicate()
        raise
    finally:
        if job:
            job.close()
            child._handle.Close()
    result = subprocess.CompletedProcess(command,child.returncode,out,err)
    result.pid = child.pid
    return result
