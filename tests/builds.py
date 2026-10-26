"""Black-box local builds using fresh payloads and disposable installed prefixes."""
from scratch import scratch
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tarfile
import gzip
import sys
import tomllib
from process import capture


def run(argv, cwd, status=0, env=None):
    result = capture(argv, cwd=cwd, env=env, text=False, timeout=180)
    assert result.returncode == status, (argv, result.returncode, result.stdout, result.stderr)
    return result.stdout, result.stderr


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
    lock = tomllib.loads((project / 'beam.lock').read_text())
    selection=next(iter(lock["selections"].values())) if lock["format"]==2 else lock
    digest=selection["root"]
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
    with scratch(root):
        original = args.beam.resolve().parent.parent
        before = {str(p.relative_to(original)): (p.stat().st_size, p.stat().st_mtime_ns)
                  for p in original.rglob('*') if p.is_file()}
        prefix = root / 'SDK prefix λ'
        shutil.copytree(original, prefix, symlinks=True)
        payload = prefix / 'lib/beam/apps/beam-pkg'
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

        # Resource-only exports have valid portable C and no implicit NIFs.
        resource_only = work / 'resource-only'
        resource_only.mkdir()
        (resource_only / 'beam.toml').write_text('format=2\n[package]\nname="test/resources"\nversion="1"\n[exports]\nresources=["message.txt"]\n')
        (resource_only / 'message.txt').write_text('packaged resource\n')
        build(resource_only)
        run([exe, 'install', resource_only], work, 0, env)
        exported = work / 'resource export'
        run([exe, 'export', '--output', exported, resource_only], work, 0, env)
        # Publishing another generation must replace the selection atomically,
        # including Windows exports without symbolic-link privileges.
        run([exe, 'export', '--output', exported, resource_only], work, 0, env)
        consumer_c = work / 'resource consumer'
        consumer_c.mkdir()
        (consumer_c / 'main.c').write_text('#include "registration.h"\n#include "package_inventory.h"\nint main(void) { return beam_package_inventory.count != 0 || beam_package_linked_nifs(0,0) != 0; }\n')
        (consumer_c / 'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.25)
project(resource_export LANGUAGES C)
find_package(BEAM CONFIG REQUIRED COMPONENTS Runtime)
include("${EXPORT}/BEAMPackageExport.cmake")
add_executable(resource_consumer main.c)
if(CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
  target_compile_options(resource_consumer PRIVATE -Wall -Wextra -Werror -pedantic-errors)
endif()
target_link_libraries(resource_consumer PRIVATE BEAMPackageInputs BEAM::Runtime)
add_custom_target(resource-check COMMAND "$<TARGET_FILE:resource_consumer>" DEPENDS resource_consumer)
''')
        resource_build = work / 'resource consumer build'
        run(['cmake', '-S', consumer_c, '-B', resource_build,
             '-DCMAKE_PREFIX_PATH='+str(prefix), '-DEXPORT='+str(exported)], work, 0, env)
        run(['cmake', '--build', resource_build, '--config', 'Release', '--target', 'resource-check'], work, 0, env)

        # Read a valid, separately created format-1 archive and closure without
        # mutating an immutable format-3 archive. New archive records use format 3.
        modern_leaf = artifact(leaf)
        modern_bytes = modern_leaf.read_bytes()
        with tarfile.open(modern_leaf, 'r:gz') as tar:
            legacy_entries = []
            for member in tar:
                data = tar.extractfile(member).read()
                if member.name == 'package.toml':
                    assert tomllib.loads(data.decode())['format'] == 3
                    data = re.sub(rb'^"compiler-generation"[^\n]*\n', b'', data, flags=re.M)
                    data, count = re.subn(rb'("format"\s*=\s*)3', rb'\g<1>1', data, count=1)
                    assert count == 1 and tomllib.loads(data.decode())['format'] == 1
                legacy_entries.append((member.name, data, tarfile.REGTYPE))
        legacy_archive = work / 'legacy-format-1.bpkg.tar.gz'
        legacy_bytes = tar_bytes(legacy_entries)
        legacy_archive.write_bytes(legacy_bytes)
        legacy_dep = f'[dependencies]\n"test/leaf"={{version="1.0.0",archive="{legacy_archive.as_posix()}"}}\n'
        legacy_root = package(work / 'legacy-read', 'legacy-read', 'legacy_read', extra=legacy_dep)
        manifest = legacy_root / 'beam.toml'
        manifest.write_text(manifest.read_text().replace('format = 1', 'format = 2', 1))
        build(legacy_root)
        legacy_lock = legacy_root / 'beam.lock'
        lock = tomllib.loads(legacy_lock.read_text())
        assert lock['format'] == 2 and len(lock['selections']) == 1
        selection = next(iter(lock['selections'].values()))

        def inline(value):
            if isinstance(value, dict):
                return '{' + ','.join(json.dumps(k, ensure_ascii=False) + '=' + inline(v)
                                      for k, v in value.items()) + '}'
            return json.dumps(value, ensure_ascii=False)

        legacy_lock.write_text('format = 1\nroot = ' + inline(selection['root']) +
                               '\nartifacts = ' + inline(selection['artifacts']) + '\n')
        run([exe, 'install', legacy_root], work, 0, env)
        installed_environments = list((legacy_root / '.beam/environments').glob('*/environment.toml'))
        assert len(installed_environments) == 1
        assert tomllib.loads(installed_environments[0].read_text())['format'] == 2
        build(legacy_root)
        assert tomllib.loads(legacy_lock.read_text())['format'] == 2
        assert legacy_archive.read_bytes() == legacy_bytes and modern_leaf.read_bytes() == modern_bytes

        dep = '[dependencies]\n"test/leaf" = {version="1.0.0", path="../leaf λ"}\n'
        parent = package(work / 'parent', 'parent', 'parent', 'value()->leaf:value().', dep)
        build(parent)
        parent_archive = artifact(parent)
        archive_dep = f'[dependencies]\n"test/parent" = {{version="1.0.0", archive="{parent_archive.as_posix()}", lock="{(parent / "beam.lock").as_posix()}"}}\n'
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
        current = (consumer / '.beam' / ('current-'+tomllib.loads((prefix/'lib/beam/sdk.toml').read_text())['build-id']+'.toml')).read_bytes()
        lock_path.write_text(selected_lock.replace('"version" = "1.0.0"', '"version" = "broken"', 1))
        run([exe, 'install', consumer], work, 1, env)
        assert (consumer / '.beam' / ('current-'+tomllib.loads((prefix/'lib/beam/sdk.toml').read_text())['build-id']+'.toml')).read_bytes() == current
        lock_path.write_text(selected_lock)
        text = (consumer / 'beam.toml').read_text()
        (consumer / 'beam.toml').write_text(text.replace(f', lock="{(parent / "beam.lock").as_posix()}"', ''))
        build(consumer, False, 'companion lock')
        (consumer / 'beam.toml').write_text(text)
        old = parent_archive.read_bytes()
        parent_archive.write_bytes(old + b'corrupt')
        build(consumer, False)
        parent_archive.write_bytes(old)
        fifo_project = work / 'fifo'
        fifo_project.mkdir()
        if os.name == 'nt':
            (fifo_project / 'beam.toml').mkdir()
        else:
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
        badroot = package(work / 'badarchive', 'badarchive', 'badarchive', extra=f'[dependencies]\n"test/x"={{version="1.0.0",archive="{malformed.as_posix()}"}}\n')
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
    outputs = ["probe"]
    ''')
        (native / 'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.25)
    project(probe LANGUAGES C)
    find_package(BEAM CONFIG REQUIRED)
    add_library(probe MODULE probe.c)
    beam_target_nif(probe)
    set_target_properties(probe PROPERTIES PREFIX "")
    beam_package_native_output(probe NAME probe)
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
        (native / 'beam.toml').write_text((native / 'beam.toml').read_text().replace('format = 1','format = 2',1).replace('["native.erl"]','["native.erl", "nif.erl"]'))
        build(native)
        narchive = artifact(native)
        extracted = work / 'extracted native'
        extracted.mkdir()
        with tarfile.open(narchive, 'r:gz') as tar:
            native_record = tomllib.loads(tar.extractfile('package.toml').read().decode())
            native_path = native_record['native']['identities']['probe']
            assert native_record['native']['outputs'] == [native_path]
            for item in tar:
                assert item.isfile() and not item.name.startswith('/') and '..' not in Path(item.name).parts
                dest = extracted / item.name
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(tar.extractfile(item).read())
        smoke = extracted / 'smoke.erl'
        smoke.write_text('-module(smoke).\n-export([main/1]).\nmain([])->73=nif:value(),io:format("NATIVE_OK~n").\n')
        run([prefix/'bin/beam','compile','--deterministic','-o',extracted/'ebin','--',smoke],work,env=env)
        (extracted/'modules.txt').write_text('native\nnif\nsmoke\n')
        run([sys.executable,prefix/'share/beam/tools/beam-application.py','create',
             '--root',extracted,'--inventory',extracted/'modules.txt','--entry','smoke:main',
             '--name','native-smoke','--version','1','--service','output',
             '--native','nif='+native_path,'--output',extracted/'application.etf'],work,env=env)
        out,_=run([prefix/'bin/beam','run','--application',extracted/'application.etf'],work,env=env)
        assert out == b'NATIVE_OK\n'
        if os.name == 'nt' and tomllib.loads((prefix/'lib/beam/target.toml').read_text())['compiler-environment'] == 'GNU-MinGW':
            # C++-only recipes must select G++ from the SDK's compiler family.
            # Their installed extensions need the bundled C++ runtime on EMU too.
            recipe = native/'CMakeLists.txt'
            recipe.write_text(recipe.read_text().replace('LANGUAGES C)', 'LANGUAGES CXX)').replace('probe.c)', 'probe.cpp)'))
            source = (native/'probe.c').read_text().replace('#include <erl_nif.h>', '#include <erl_nif.h>\n#include <string>')
            source = source.replace('return enif_make_int(env,73);',
                'std::string text(128, char(argc+1)); return enif_make_int(env,int(text.size())-55);')
            (native/'probe.cpp').write_text(source)
            build(native)
            with tarfile.open(artifact(native), 'r:gz') as tar:
                (extracted/native_path).write_bytes(tar.extractfile(native_path).read())
            run([sys.executable,prefix/'share/beam/tools/beam-application.py','create',
                 '--root',extracted,'--inventory',extracted/'modules.txt','--entry','smoke:main',
                 '--name','native-smoke','--version','1','--service','output',
                 '--native','nif='+native_path,'--output',extracted/'application.etf'],work,env=env)
            runtime_env = env.copy()
            runtime_env['PATH'] = os.pathsep.join([str(prefix/'bin'), str(Path(os.environ['SystemRoot'])/'System32'), os.environ['SystemRoot']])
            out,err=run([prefix/'bin/beam','run','--application',extracted/'application.etf'],work,env=runtime_env)
            assert out == b'NATIVE_OK\n' and not err, (out,err)
        # A native inventory mismatch cannot change the selected lock.
        native_manifest = (native / 'beam.toml').read_text()
        native_lock = (native / 'beam.lock').read_bytes()
        (native / 'beam.toml').write_text(native_manifest.replace('outputs = ["probe"]', 'outputs = ["missing"]'))
        build(native, False, 'native output')
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
        mismatched_root = package(work / 'mismatched', 'mismatched', 'mismatched', extra=f'[dependencies]\n"test/native"={{version="1.0.0",archive="{mismatch.as_posix()}"}}\n')
        build(mismatched_root, False, 'SDK/target mismatch')
        # Relocate and remove all OTP assets; both builders remain usable.

        moved = root / 'relocated SDK 日本語'
        prefix.rename(moved)
        prefix = moved
        exe = prefix / 'bin/beam-pkg'
        assert {p.name for p in (prefix/'lib/beam/apps').iterdir()} == {'beam-pkg'}
        assert not (prefix/'lib/beam/runtime/otp').exists()
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
