"""Exercise immutable installed projects with the freshly compiled package tool."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tomllib


def main():
    p = argparse.ArgumentParser()
    for key in ('beam', 'payload', 'work'):
        p.add_argument('--' + key, type=Path, required=True)
    a = p.parse_args()
    work = a.work.resolve()
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    prefix = work / 'SDK λ'
    shutil.copytree(a.beam.resolve().parent.parent, prefix, symlinks=True)
    payload = prefix / 'lib/beam/tools/pkg'
    shutil.rmtree(payload)
    shutil.copytree(a.payload, payload)
    env = os.environ.copy()
    for k in list(env):
        if k.startswith(('ERL_', 'BEAM_', 'LD_', 'DYLD_')):
            env.pop(k)
    def run(command, status=0, input=None):
        r = subprocess.run([str(x) for x in command], cwd=work, env=env, input=input,
                           text=True, capture_output=True, timeout=90)
        assert r.returncode == status, (command, r.returncode, r.stdout, r.stderr)
        return r
    beam = prefix / 'bin/beam'
    pkg = prefix / 'bin/beam-pkg'
    assert 'usage: beam build' in run([beam, 'help', 'build']).stdout
    run([beam, '--runtime=otp', 'build'], 1)
    project = work / 'project 日本語'
    project.mkdir()
    manifest = '''format = 1
[package]
name = "fixture/project"
version = "1"
[build]
sources = ["entry.erl"]
[host]
modules = ["erlang", "io"]
[entry]
module = "entry"
'''
    (project / 'beam.toml').write_text(manifest)
    (project / 'entry.erl').write_text('''-module(entry).
-export([main/1]).
main(["halt"]) -> erlang:halt(7);
main(["exception"]) -> erlang:error(project_exception);
main(["input"]) -> io:put_chars(io:get_line("prompt> "));
main(Args) -> false = erlang:module_loaded(beam_pkg),
              false = erlang:module_loaded(compile),
              false = erlang:module_loaded(code),
              io:format("ARGS ~tp~n", [Args]),
              [io:format("ARG ~ts~n", [A]) || A <- Args], ok.
''')
    run([beam, '--runtime=beam', 'build', project])
    lock = (project / 'beam.lock').read_bytes()
    run([pkg, 'install', project])
    current = project / '.beam/current.toml'
    old = current.read_bytes()
    # Installation uses only the selected locked archives.
    (project / 'beam.toml').unlink()
    (project / 'entry.erl').unlink()
    run([pkg, 'install', project])
    assert current.read_bytes() != old
    old = current.read_bytes()
    archives = list((project / 'build/beam-pkg/artifacts').glob('*.bpkg.tar.gz'))
    archive = archives[0]
    data = archive.read_bytes()
    archive.write_bytes(b'corrupt')
    run([pkg, 'install', project], 1)
    assert current.read_bytes() == old and (project / 'beam.lock').read_bytes() == lock
    assert not list((project / '.beam/environments').glob('stage-*'))
    archive.write_bytes(data)
    run([beam, '--runtime=otp', 'run', '--project', project], 1)
    run([beam, 'run', '--project', project, '--', 'halt'], 7)
    assert 'project_exception' in run([beam, 'run', '--project', project, '--', 'exception'], 1).stderr
    assert run([beam, 'run', '--project', project, '--', 'input'], input='hello λ\n').stdout == 'prompt> hello λ\n'
    # Malformed selection cannot cause fallback acquisition or launch.
    current.write_text('format = 1\ngeneration = "../escape"\n')
    run([beam, 'run', '--project', project], 1)
    current.write_bytes(old)
    generation = tomllib.loads(old.decode())['generation']
    selected = project / '.beam/environments' / generation
    record = selected / 'environment.toml'
    record_data = record.read_bytes()
    record.write_text(record.read_text() + '\nunknown = true\n')
    run([beam, 'run', '--project', project], 1)
    record.write_bytes(record_data)
    # Library roots can be installed, but have no launch entry.
    lib = work / 'library'
    lib.mkdir()
    (lib / 'beam.toml').write_text(manifest.replace('[entry]\nmodule = "entry"\n', ''))
    (lib / 'entry.erl').write_text('-module(entry).\n-export([value/0]).\nvalue() -> ok.\n')
    run([beam, 'build', lib])
    run([pkg, 'install', lib])
    assert 'no main/1 entry' in run([beam, 'run', '--project', lib], 1).stderr
    shell = run([beam, 'shell', '--project', lib], input='entry:value().\nq().\n')
    assert 'ok' in shell.stdout and not shell.stderr, shell
    run([beam, '--runtime=otp', 'shell', '--project', lib], 1)
    run([beam, 'shell', '--project', lib, '--'], 1)
    (lib / 'beam.toml').write_text(manifest)
    run([beam, 'build', lib])
    run([pkg, 'install', lib])
    assert 'missing_project_entry' in run([beam, 'run', '--project', lib], 1).stderr
    # Host requirements are checked against the prospective project VM.
    (lib / 'beam.toml').write_text(manifest.replace('"io"]', '"missing_host"]'))
    run([beam, 'build', lib])
    run([pkg, 'install', lib])
    assert 'missing host module' in run([beam, 'run', '--project', lib], 1).stderr
    collision = work / 'collision'
    collision.mkdir()
    (collision / 'beam.toml').write_text(manifest.replace('entry.erl', 'io.erl').replace('module = "entry"', 'module = "io"').replace('["erlang", "io"]', '["erlang"]'))
    (collision / 'io.erl').write_text('-module(io).\n-export([main/1]).\nmain(_) -> ok.\n')
    run([beam, 'build', collision])
    run([pkg, 'install', collision])
    assert 'conflicts with host module' in run([beam, 'run', '--project', collision], 1).stderr
    # Binding declarations must identify real, supplied modules and outputs.
    (lib / 'CMakeLists.txt').write_text("""cmake_minimum_required(VERSION 3.25)
project(binding_schema LANGUAGES NONE)
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/x.so" "inventory-only fixture")
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/x.so" DESTINATION priv)
""")
    for binding in ('{ missing = "priv/x.so" }', '{ entry = "priv/not-declared.so" }',
                    '{ entry = "priv/x.so", other = "priv/x.so" }'):
        (lib / 'beam.toml').write_text(manifest + '[build.native]\ncmake = "."\noutputs = ["priv/x.so"]\nnifs = ' + binding + '\n')
        assert 'binding' in run([beam, 'build', lib], 1).stderr
    (lib / 'beam.toml').write_text(manifest + '[build.native]\ncmake = "."\noutputs = ["priv/x.so"]\nnifs = { entry = "priv/x.so" }\n')
    run([beam, 'build', lib])
    native_lock = tomllib.loads((lib / 'beam.lock').read_text())
    native_archive = lib / native_lock['artifacts'][native_lock['root']]['archive']
    with tarfile.open(native_archive) as t:
        m = tomllib.loads(t.extractfile('package.toml').read().decode())
        assert m['native']['nifs'] == {'entry': 'priv/x.so'}
    run([pkg, 'install', lib])
    # A declared output is not sufficient to make invalid native bytes executable.
    run([beam, 'run', '--project', lib], 1)
    deployed = work / 'deployed λ'
    shutil.copytree(project / '.beam', deployed / '.beam')
    shutil.rmtree(project)
    for relative in ('lib/beam/apps', 'lib/beam/tools/compiler', 'libexec'):
        shutil.rmtree(prefix / relative)
    relocated = work / 'relocated SDK 日本語'
    prefix.rename(relocated)
    beam = relocated / 'bin/beam'
    env['PATH'] = ''
    def snapshot():
        return {str(f.relative_to(deployed)): hashlib.sha256(f.read_bytes()).hexdigest()
                for f in deployed.rglob('*') if f.is_file()}
    before = snapshot()
    r = run([beam, 'run', '--project', deployed, '--', 'literal $(touch surprise)', '日本語'])
    assert 'literal $(touch surprise)' in r.stdout and '日本語' in r.stdout
    shell = run([beam, 'shell', '--project', deployed], input='false=erlang:module_loaded(beam_pkg), false=erlang:module_loaded(compile), 42.\nq().\n')
    assert '42' in shell.stdout and not shell.stderr, shell
    assert snapshot() == before
    print('Installed project lifecycle, failures, isolation and relocation passed.')


if __name__ == '__main__':
    main()
