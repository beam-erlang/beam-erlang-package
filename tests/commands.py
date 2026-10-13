"""Run the freshly built tool with an installed matching BEAM host."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess


def run(command, work, env, expected=0):
    child = subprocess.Popen([str(value) for value in command], cwd=work, env=env,
                             stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, start_new_session=True)
    try:
        stdout, stderr = child.communicate(timeout=20)
    except BaseException:
        os.killpg(child.pid, signal.SIGKILL)
        child.communicate()
        raise
    assert child.returncode == expected, (command, child.returncode, stdout, stderr)
    return stdout.decode('utf-8'), stderr.decode('utf-8')


def snapshot(root):
    result = {}
    for path in root.rglob('*'):
        info = path.lstat()
        content = hashlib.sha256(path.read_bytes()).hexdigest() if stat.S_ISREG(info.st_mode) else None
        result[str(path.relative_to(root))] = (info.st_mode, info.st_mtime_ns, content)
    return result


def check_commands(prefix, work, identity):
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(('ERL_', 'BEAM_', 'LD_', 'DYLD_')) or key in ('ROOTDIR', 'BINDIR', 'EMU'):
            env.pop(key)
    env.update(PATH=str(prefix / 'bin'), HOME=str(work), LANG='C.UTF-8')
    for kind in ('CONFIG', 'DATA', 'CACHE', 'STATE', 'RUNTIME'):
        env[f'XDG_{kind}_HOME' if kind != 'RUNTIME' else 'XDG_RUNTIME_DIR'] = str(work)
    before = snapshot(work)

    def invoke(arguments, status, expected):
        out, err = run(['beam-pkg', *arguments], work, env, status)
        assert not (out if status else err), (arguments, out, err)
        assert expected in (err if status else out), (arguments, out, err)

    for arguments in ([], ['help']):
        invoke(arguments, 0, 'usage: beam-pkg <command> [args]')
    for command in ('help', 'version', 'build', 'install', 'tree'):
        invoke(['help', command], 0, f'usage: beam-pkg {command}')
    invoke(['version'], 0, identity + '\nbeam-pkg: experimental local packages; tree is not implemented\n')
    for command in ('tree',):
        for tail in ([], ['.'], [str(work / 'project λ')], ['missing 日本語'], ['./-literal'], ['$(touch unwanted)']):
            invoke([command, *tail], 2, f'beam-pkg: {command}: not implemented (experimental scaffold)\n')
        for tail in ([''], ['--option'], ['one', 'two']):
            invoke([command, *tail], 1, 'beam-pkg: invalid arguments\n')
    for arguments in (['unknown'], ['version', 'extra'], ['help', 'unknown'],
                      ['help', 'build', 'extra'], ['--runtime=beam', 'help']):
        invoke(arguments, 1, 'beam-pkg: invalid arguments\n')
    assert snapshot(work) == before, 'command modified project/home files'


def main():
    parser = argparse.ArgumentParser()
    for option in ('beam', 'runtime', 'boot', 'payload', 'work'):
        parser.add_argument('--' + option, type=Path, required=True)
    args = parser.parse_args()
    root = args.work.resolve()
    if root.exists():
        shutil.rmtree(root)
    root.mkdir(parents=True)
    prefix = root / 'fresh prefix'
    (prefix / 'bin').mkdir(parents=True)
    (prefix / 'lib').mkdir()
    # Copy hosts, never symlink to the input prefix. Runtime discovery follows
    # the copied libbeam location and must select only the new payload.
    shutil.copy2(args.beam, prefix / 'bin/beam')
    shutil.copy2(args.runtime, prefix / 'lib/libbeam.so')
    shutil.copy2(args.boot, prefix / 'lib/libbeam-boot.so')
    (prefix / 'bin/beam-pkg').symlink_to('beam')
    payload = prefix / 'lib/beam/tools/pkg'
    shutil.copytree(args.payload, payload)
    modules = (args.payload / 'modules.txt').read_text().splitlines()
    assert (payload / 'modules.txt').read_text().splitlines() == modules
    assert {p.name for p in (payload / 'ebin').iterdir()} == {name + '.beam' for name in modules}
    assert (payload / 'ebin/beam_pkg.beam').read_bytes() == (args.payload / 'ebin/beam_pkg.beam').read_bytes()
    work = root / 'unrelated work 日本語'
    project = work / 'project λ'
    project.mkdir(parents=True)
    os.mkfifo(project / 'beam.toml')  # Reading this manifest would block.
    (project / 'beam.lock').write_text('unchanged sentinel\n')
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(('LD_', 'DYLD_')):
            env.pop(key)
    identity, error = run([prefix / 'bin/beam', 'version'], work, env)
    assert not error
    for destination in (None, root / 'relocated prefix 日本語'):
        if destination:
            prefix.rename(destination)
            prefix = destination
        check_commands(prefix, work, identity.strip())
    # There is no installed-policy fallback when the newly built module is absent.
    module = prefix / 'lib/beam/tools/pkg/ebin/beam_pkg.beam'
    module.unlink()
    out, err = run([prefix / 'bin/beam-pkg', 'help'], work, env, 1)
    assert not out and 'beam_pkg' in err
    print('Package command behavior passed with fresh, relocated and missing-policy payloads.')


if __name__ == '__main__':
    main()
