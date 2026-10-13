"""Literal development commands using a fresh payload and disposable SDK."""
import argparse
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import subprocess
import sys
import tarfile
import time
import tomllib


def main():
    p = argparse.ArgumentParser()
    for name in ('beam', 'payload', 'work'):
        p.add_argument('--' + name, type=Path, required=True)
    a = p.parse_args()
    root = a.work.resolve()
    shutil.rmtree(root, ignore_errors=True)
    root.mkdir(parents=True)
    prefix = root / 'SDK λ'
    shutil.copytree(a.beam.resolve().parent.parent, prefix, symlinks=True)
    shutil.rmtree(prefix / 'lib/beam/tools/pkg')
    shutil.copytree(a.payload, prefix / 'lib/beam/tools/pkg')
    beam = prefix / 'bin/beam'
    project = root / 'project 日本語'
    project.mkdir()
    manifest = project / 'beam.toml'
    base = 'format = 1\n[package]\nname = "fixture/tasks"\nversion = "1"\n'
    env = {k: v for k, v in os.environ.items() if not k.startswith(('ERL_', 'BEAM_', 'LD_', 'DYLD_'))}
    def run(args, status=0, input=None, cwd=None):
        r = subprocess.run([str(beam), *map(str, args)], cwd=cwd or root, env=env,
                           input=input, text=True, capture_output=True, timeout=60)
        assert r.returncode == status, (args, r.returncode, r.stdout, r.stderr)
        return r
    def task(args=(), **kw):
        return run(['task', '--project', project, *args], **kw)
    assert 'usage: beam task' in run(['help', 'task']).stdout
    run(['--runtime=otp', 'task'], 1)
    run(['task'], 1)  # No sibling manifest discovery.
    manifest.write_text(base)
    assert task().stdout == 'No development tasks defined.\n'
    assert run(['task'], cwd=project).stdout == 'No development tasks defined.\n'
    nested = project / 'nested'
    nested.mkdir()
    run(['task'], 1, cwd=nested)  # No ancestor manifest discovery.
    helper = project / 'inspect.py'
    helper.write_text('import os,sys,json,signal\n'
                     'print(json.dumps([os.getcwd(),sys.argv[1:],os.getpgrp(),os.getpid()]))\n'
                     'print(sys.stdin.readline(),end="")\n'
                     'print("ERR",file=sys.stderr)\n')
    scripts = {'z': [sys.executable, 'inspect.py', '', '$(touch surprise)', 'λ'],
               'a': ['beam', 'version'], 'pkg': ['beam-pkg', 'version'],
               'status': [sys.executable, '-c', 'raise SystemExit(17)'],
               'signal': [sys.executable, '-c', 'import os,signal;os.kill(os.getpid(),signal.SIGTERM)'],
               'pipe': ['/bin/sh', '-c', 'kill -PIPE $$'],
               'lookup': ['local-command'], 'relative': ['./local-command'],
               'missing': ['not-a-real-executable'], 'nonexec': ['./no-permission'],
               'noshell': ['./no-shebang']}
    def write(scripts=scripts, build='[build]\notp-application = "absent"\n'):
        manifest.write_text(base + build + '[scripts]\n' + ''.join(
            json.dumps(k) + ' = ' + json.dumps(v, ensure_ascii=False) + '\n' for k, v in scripts.items()))
    write()
    before = manifest.read_bytes()
    assert task().stdout.splitlines() == sorted(scripts)
    r = task(['z', '--', '--runtime=otp', '日本語', ''], input='input λ\n')
    data = json.loads(r.stdout.splitlines()[0])
    assert data[2] == os.getpgrp()
    assert data[:2] == [str(project), ['', '$(touch surprise)', 'λ', '--runtime=otp', '日本語', '']]
    assert r.stdout.endswith('input λ\n') and r.stderr == 'ERR\n'
    assert not (project / 'surprise').exists() and manifest.read_bytes() == before
    task(['status'], status=17)
    task(['signal'], status=-signal.SIGTERM)
    task(['pipe'], status=-signal.SIGPIPE)
    for name in ('missing', 'nonexec', 'noshell'):
        target = project / ('no-permission' if name == 'nonexec' else 'no-shebang')
        target.write_text('echo IMPLICIT_SHELL\n')
        target.chmod(0o644 if name == 'nonexec' else 0o755)
        r = task([name], status=1)
        assert 'cannot execute task' in r.stderr and not r.stdout
    target = project / 'local-command'
    target.write_text('#!/bin/sh\nprintf "LOCAL\\n"\n')
    target.chmod(0o755)
    denied = project / 'denied'
    denied.mkdir()
    (denied / 'local-command').write_text('not executable')
    env['PATH'] = 'denied:.'
    assert task(['lookup']).stdout == 'LOCAL\n'
    assert task(['relative']).stdout == 'LOCAL\n'
    # Bare distribution commands ignore a shadowing PATH executable.
    shadow = project / 'beam'
    shadow.write_text('#!/bin/sh\nexit 98\n'); shadow.chmod(0o755)
    assert task(['a']).stdout == run(['version']).stdout
    assert 'beam-pkg:' in task(['pkg']).stdout
    for args in (['unknown'], ['z', 'bad'], ['--bad'], ['--project']):
        task(args, status=1)
    for invalid in ([], [''], ['echo', 1], 'echo string', ['echo', '\x00']):
        write({'bad': invalid})
        task(status=1)
    write(build='[build]\nsources = ["entry.erl"]\n')
    (project / 'entry.erl').write_text('-module(entry).\n-export([value/0]).\nvalue()->ok.\n')
    env['PATH'] = os.environ['PATH']
    run(['build', project])
    lock = tomllib.loads((project / 'beam.lock').read_text())
    archive = project / lock['artifacts'][lock['root']]['archive']
    with tarfile.open(archive) as tar:
        assert 'scripts' not in tomllib.loads(tar.extractfile('package.toml').read().decode())
    assert 'scripts' not in lock
    # exec preserves the terminal and the process id; the target is not a child.
    write({'terminal': [sys.executable, '-c', 'import os;print("READY",os.getpid(),os.isatty(0),flush=True);print(input())']})
    master, slave = pty.openpty()
    child = subprocess.Popen([str(beam), 'task', '--project', str(project), 'terminal'],
                             stdin=slave, stdout=slave, stderr=slave, env=env)
    os.close(slave)
    try:
        output = b''
        deadline = time.monotonic() + 30
        while b'READY' not in output and time.monotonic() < deadline:
            if select.select([master], [], [], .1)[0]: output += os.read(master, 4096)
        assert f'READY {child.pid} True'.encode() in output, output
        os.write(master, 'terminal λ\n'.encode())
        assert child.wait(10) == 0
    finally:
        if child.poll() is None: child.kill(); child.wait()
        os.close(master)
    write()
    for relative in ('lib/beam/apps', 'lib/beam/tools/compiler', 'libexec'):
        shutil.rmtree(prefix / relative)
    moved = root / 'relocated SDK 日本語'
    prefix.rename(moved); beam = moved / 'bin/beam'
    env['PATH'] = ''
    assert task(['a']).stdout == run(['version']).stdout
    assert 'usage: beam task' in run(['help', 'task']).stdout
    for component in ('libbeam-file.so', 'libbeam-program.so', 'libbeam-zlib.so'):
        asset = moved / 'lib' / component
        if asset.exists(): asset.unlink()
    assert 'usage: beam task' in run(['help', 'task']).stdout
    print('Task literals, validation, streams, terminal, signals, status, metadata and relocation passed.')


if __name__ == '__main__':
    main()
