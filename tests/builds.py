"""Black-box local builds using fresh payloads and disposable installed prefixes."""
import argparse
import hashlib
import io
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tarfile
import gzip


def run(argv, cwd, status=0, env=None):
    p = subprocess.Popen([str(x) for x in argv], cwd=cwd, env=env,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        out, err = p.communicate(timeout=180)
    except BaseException:
        os.killpg(p.pid, signal.SIGKILL)
        p.communicate()
        raise
    assert p.returncode == status, (argv, p.returncode, out, err)
    return out, err


def package(root, name, module, body='value()->42.', extra=''):
    root.mkdir(parents=True, exist_ok=True)
    (root / f'{module}.erl').write_text(f'-module({module}).\n-export([value/0]).\n{body}\n')
    (root / 'beam.toml').write_text(f'''format = 1
[package]
name = "test/{name}"
version = "1.0.0"
[build]
sources = ["{module}.erl"]
[host]
modules = ["erlang"]
''' + extra)
    return root


def artifact(project):
    lock = (project / 'beam.lock').read_text()
    digest = re.search(r'^"root" = "([a-f0-9]{64})"$', lock, re.M).group(1)
    path = project / 'build/beam-pkg/artifacts' / (digest + '.bpkg.tar.gz')
    assert hashlib.sha256(path.read_bytes()).hexdigest() == digest
    return path


def tar_bytes(entries):
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode='w', format=tarfile.USTAR_FORMAT) as tar:
        for name, data, kind in entries:
            info = tarfile.TarInfo(name)
            info.type = kind
            info.size = len(data)
            if kind == tarfile.SYMTYPE:
                info.linkname = '/tmp/escape'
            tar.addfile(info, io.BytesIO(data))
    return gzip.compress(out.getvalue(), mtime=0)


def main():
    parser = argparse.ArgumentParser()
    for key in ('beam', 'payload', 'work'):
        parser.add_argument('--' + key, type=Path, required=True)
    args = parser.parse_args()
    root = args.work.resolve()
    if root.exists():
        shutil.rmtree(root)
    root.mkdir(parents=True)
    original = args.beam.resolve().parent.parent
    before = {str(p.relative_to(original)): (p.stat().st_size, p.stat().st_mtime_ns)
              for p in original.rglob('*') if p.is_file()}
    prefix = root / 'SDK prefix λ'
    shutil.copytree(original, prefix, symlinks=True)
    payload = prefix / 'lib/beam/tools/pkg'
    shutil.rmtree(payload)
    shutil.copytree(args.payload, payload)
    work = root / 'unrelated 日本語'
    work.mkdir()
    env = os.environ.copy()
    for k in list(env):
        if k.startswith(('ERL_', 'BEAM_', 'LD_', 'DYLD_')):
            env.pop(k)
    env['HOME'] = str(work)
    exe = prefix / 'bin/beam-pkg'

    def build(p, ok=True, needle=None):
        out, err = run([exe, 'build', p], work, 0 if ok else 1, env)
        if not ok:
            assert not out
            if needle:
                assert needle.encode() in err, err
        return out, err

    leaf = package(work / 'leaf λ', 'leaf', 'leaf')
    build(leaf)
    first = artifact(leaf)
    assert not (leaf / '.beam').exists()
    baseline = (leaf / 'beam.lock').read_bytes()
    (leaf / 'leaf.erl').write_text('invalid erlang')
    build(leaf, False, 'tool failed')
    assert (leaf / 'beam.lock').read_bytes() == baseline
    (leaf / 'leaf.erl').write_text('-module(leaf).\n-export([value/0]).\nvalue()->43.\n')
    build(leaf)
    assert artifact(leaf) != first
    # Header changes are real compilation inputs.
    (leaf / 'value.hrl').write_text('-define(VALUE, 44).\n')
    (leaf / 'leaf.erl').write_text('-module(leaf).\n-include("value.hrl").\n-export([value/0]).\nvalue()->?VALUE.\n')
    build(leaf)
    h1 = artifact(leaf)
    (leaf / 'value.hrl').write_text('-define(VALUE, 45).\n')
    build(leaf)
    assert artifact(leaf) != h1

    dep = '[dependencies]\n"test/leaf" = {version="1.0.0", path="../leaf λ"}\n'
    parent = package(work / 'parent', 'parent', 'parent', 'value()->leaf:value().', dep)
    build(parent)
    parent_archive = artifact(parent)
    archive_dep = f'[dependencies]\n"test/parent" = {{version="1.0.0", archive="{parent_archive}", lock="{parent / "beam.lock"}"}}\n'
    consumer = package(work / 'consumer', 'consumer', 'consumer', extra=archive_dep)
    build(consumer)
    assert len(list((consumer / 'build/beam-pkg/artifacts').glob('*.gz'))) == 3
    # Installation selects the transitive closure solely from the lock.
    lock_path = consumer / 'beam.lock'
    selected_lock = lock_path.read_text()
    lock_path.write_text(selected_lock.replace('"artifacts" = {', '"artifacts" = {"' + 'f' * 64 + '" = {archive = "absent-unselected"}, ', 1))
    run([exe, 'install', consumer], work, 0, env)
    assert len(list((consumer / '.beam/environments').glob('*/packages/*'))) == 3
    lock_path.write_text(selected_lock)
    current = (consumer / '.beam/current.toml').read_bytes()
    lock_path.write_text(selected_lock.replace('"version" = "1.0.0"', '"version" = "broken"', 1))
    run([exe, 'install', consumer], work, 1, env)
    assert (consumer / '.beam/current.toml').read_bytes() == current
    lock_path.write_text(selected_lock)
    text = (consumer / 'beam.toml').read_text()
    (consumer / 'beam.toml').write_text(text.replace(f', lock="{parent / "beam.lock"}"', ''))
    build(consumer, False, 'companion lock')
    (consumer / 'beam.toml').write_text(text)
    old = parent_archive.read_bytes()
    parent_archive.write_bytes(old + b'corrupt')
    build(consumer, False)
    parent_archive.write_bytes(old)
    fifo_project = work / 'fifo'
    fifo_project.mkdir()
    os.mkfifo(fifo_project / 'beam.toml')
    build(fifo_project, False, 'regular file')
    # Literal shell punctuation remains a directory name.
    literal = package(work / '$(touch unwanted); literal', 'literal', 'literal')
    build(literal)
    assert not (work / 'unwanted').exists()

    invalid = package(work / 'invalid', 'invalid', 'invalid')
    good = (invalid / 'beam.toml').read_text()
    failures = [
        (good + '\nunknown = true\n', 'unknown fields'),
        (good.replace('format = 1', 'format = 1\nformat = 1'), 'duplicate key'),
        (good.replace('format = 1', 'format = 1.0'), 'unsupported or invalid'),
        (good + '\n[build-dependencies]\n"test/leaf"={version="1.0.0",path="../leaf λ"}\n', 'build-dependencies'),
        (good.replace('sources = ["invalid.erl"]', 'otp-application = "."'), 'whole OTP'),
        (good + '\n[dependencies]\n"test/invalid"={version="1.0.0",path="."}\n', 'cycle'),
        (good + dep.replace('1.0.0', '2.0.0'), 'identity mismatch'),
        (good + '\n[application]\nsource = "x.app.src"\n', 'application templates'),
        ('a={b=1}\n[a]\nc=2\n', 'sealed table'),
        ('a.b=1\n[a]\nc=2\n', 'duplicate or sealed table'),
        (good.replace('modules = ["erlang"]', 'modules = ["invalid"]'), 'host provider'),
    ]
    for content, needle in failures:
        (invalid / 'beam.toml').write_text(content)
        build(invalid, False, needle)
    # Valid quoted keys, Unicode escapes, literal strings, multiline arrays and comments.
    valid = good.replace('format = 1', '"format" = +1 # integer')
    valid = valid.replace('["invalid.erl"]', "[\n'invalid.erl', # source\n]")
    (invalid / 'beam.toml').write_text(valid)
    build(invalid)
    baseline_invalid = (invalid / 'beam.lock').read_bytes()
    (invalid / 'beam.toml').write_text(good)
    (invalid / 'invalid.erl').write_text('-module(invalid).\n-compile({parse_transform, should_not_run}).\n-export([value/0]).\nvalue()->ok.\n')
    build(invalid, False, 'compiler_transforms')
    assert (invalid / 'beam.lock').read_bytes() == baseline_invalid

    malformed = work / 'malformed.bpkg.tar.gz'
    badroot = package(work / 'badarchive', 'badarchive', 'badarchive', extra=f'[dependencies]\n"test/x"={{version="1.0.0",archive="{malformed}"}}\n')
    for entries in [
        [('../escape', b'x', tarfile.REGTYPE)],
        [('/absolute', b'x', tarfile.REGTYPE)],
        [('link', b'', tarfile.SYMTYPE)],
        [('same', b'a', tarfile.REGTYPE), ('same', b'b', tarfile.REGTYPE)],
        [('dir', b'x', tarfile.REGTYPE), ('dir/file', b'y', tarfile.REGTYPE)],
    ]:
        malformed.write_bytes(tar_bytes(entries))
        build(badroot, False)
    malformed.write_bytes(gzip.compress(b'x' * 1024))
    build(badroot, False)
    data = bytearray(gzip.decompress(tar_bytes([('a', b'x', tarfile.REGTYPE)])))
    data[0] = ord('b')
    malformed.write_bytes(gzip.compress(data))
    build(badroot, False, 'checksum')
    malformed.write_bytes(tar_bytes([('a', b'x', tarfile.REGTYPE)])[:-8])
    build(badroot, False, 'gzip')
    oversized = tarfile.TarInfo('large')
    oversized.size = 268435457
    malformed.write_bytes(gzip.compress(oversized.tobuf(format=tarfile.USTAR_FORMAT) + bytes(1024)))
    build(badroot, False, 'size')
    collision = package(work / 'collision', 'collision', 'leaf', extra=dep)
    build(collision, False, 'duplicate module providers')


    native = package(work / 'native', 'native', 'native', 'value()->nif:value().', '''[build.native]
cmake = "."
outputs = ["priv/probe.so"]
''')
    (native / 'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.25)
project(probe LANGUAGES C)
find_package(BEAM CONFIG REQUIRED)
add_library(probe MODULE probe.c)
target_link_libraries(probe PRIVATE BEAM::NIF)
set_target_properties(probe PROPERTIES PREFIX "")
install(TARGETS probe LIBRARY DESTINATION priv)
''')
    (native / 'probe.c').write_text('''#include <erl_nif.h>
static ERL_NIF_TERM value(ErlNifEnv* env,int argc,const ERL_NIF_TERM argv[]) {return enif_make_int(env,73);}
static ErlNifFunc funcs[]={{"value",0,value,0}};
ERL_NIF_INIT(nif,funcs,NULL,NULL,NULL,NULL)
''')
    (native / 'nif.erl').write_text('''-module(nif).
-export([load/1,value/0]).
load(P)->erlang:load_nif(P,0).
value()->erlang:nif_error(not_loaded).
''')
    (native / 'beam.toml').write_text((native / 'beam.toml').read_text().replace('["native.erl"]','["native.erl", "nif.erl"]'))
    build(native)
    narchive = artifact(native)
    extracted = work / 'extracted native'
    extracted.mkdir()
    with tarfile.open(narchive, 'r:gz') as tar:
        for item in tar:
            assert item.isfile() and not item.name.startswith('/') and '..' not in Path(item.name).parts
            dest = extracted / item.name
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(tar.extractfile(item).read())
    smoke = work / 'smoke.erl'
    smoke.write_text('''-module(smoke).
-export([main/1]).
main([Root])->true=code:add_patha(filename:join(Root,"ebin")),ok=nif:load(filename:join([Root,"priv","probe"])),73=nif:value(),io:format("NATIVE_OK~n").
''')
    out, _ = run([prefix / 'bin/beam','--runtime=otp','run',smoke,'--',extracted], work, env=env)
    assert out == b'NATIVE_OK\n'
    # A native inventory mismatch cannot change the selected lock.
    native_manifest = (native / 'beam.toml').read_text()
    native_lock = (native / 'beam.lock').read_bytes()
    (native / 'beam.toml').write_text(native_manifest.replace('priv/probe.so', 'priv/missing.so'))
    build(native, False, 'inventory')
    assert (native / 'beam.lock').read_bytes() == native_lock
    (native / 'beam.toml').write_text(native_manifest)
    # Matching-build native provenance is mandatory even for leaf archive inputs.
    with tarfile.open(narchive, 'r:gz') as tar:
        items = [(m.name, tar.extractfile(m).read(), tarfile.REGTYPE) for m in tar]
    changed = []
    for name, data, kind in items:
        if name == 'package.toml':
            data = re.sub(rb'("build-id" = ")[a-f0-9]{64}', lambda m: m[1] + b'0' * 64, data)
        changed.append((name, data, kind))
    mismatch = work / 'mismatched.bpkg.tar.gz'
    mismatch.write_bytes(tar_bytes(changed))
    mismatched_root = package(work / 'mismatched', 'mismatched', 'mismatched', extra=f'[dependencies]\n"test/native"={{version="1.0.0",archive="{mismatch}"}}\n')
    build(mismatched_root, False, 'SDK/target mismatch')
    # Relocate and remove all OTP assets; both builders remain usable.

    moved = root / 'relocated SDK 日本語'
    prefix.rename(moved)
    prefix = moved
    exe = prefix / 'bin/beam-pkg'
    shutil.rmtree(prefix / 'lib/beam/apps')
    shutil.rmtree(prefix / 'lib/beam/runtime/otp')
    build(leaf)
    build(native)
    compiler_dir = prefix / 'lib/beam/tools/compiler'
    compiler_dir.rename(compiler_dir.with_name('compiler.hidden'))
    try:
        build(leaf, False)
    finally:
        compiler_dir.with_name('compiler.hidden').rename(compiler_dir)
    saved = env['PATH']
    env['PATH'] = ''
    build(leaf, False, 'required executable')
    env['PATH'] = saved
    after = {str(p.relative_to(original)): (p.stat().st_size, p.stat().st_mtime_ns)
             for p in original.rglob('*') if p.is_file()}
    assert before == after, 'supplied SDK changed'
    print('Local source/archive/native builds, failure publication, relocation and OTP-free building passed.')


if __name__ == '__main__':
    main()
