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
    assert lock["format"] == 1
    selection=next(iter(lock["selections"].values()))
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


def check_schema(prefix, payload, work, env):
    root = work / 'schema checks'
    shutil.copytree(payload / 'ebin', root / 'ebin')
    fixture = Path(__file__).with_name('package_schema.erl')
    run([prefix/'bin/beam', 'compile', '--deterministic', '-o', root/'ebin', '--', fixture], work, env=env)
    modules = (payload/'modules.txt').read_text() + 'package_schema\n'
    (root/'modules.txt').write_text(modules)
    descriptor = root/'application.etf'
    run([sys.executable, prefix/'share/beam/tools/beam-application.py', 'create',
         '--root', root, '--inventory', root/'modules.txt', '--entry', 'package_schema:main',
         '--name', 'package-schema', '--version', '1', '--service', 'output', '--service', 'zlib',
         '--output', descriptor], work, env=env)
    out, err = run([prefix/'bin/beam', 'run', '--application', descriptor], work, env=env)
    assert out == b'Package schema and serialization boundaries passed\n' and not err, (out, err)
    shutil.rmtree(root)


def main():
    parser = argparse.ArgumentParser()
    for key in ('beam', 'payload', 'work'):
        parser.add_argument('--' + key, type=Path, required=True)
    parser.add_argument('--opposite-libc-sdk', type=Path)
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
        helper = payload / 'cmake/BEAMPackageNative.cmake'
        helper_bytes = helper.read_bytes()
        assert helper_bytes == (Path(__file__).parents[1] / 'cmake/BEAMPackageNative.cmake').read_bytes()
        work = root / 'unrelated 日本語'
        work.mkdir()
        env = os.environ.copy()
        for k in list(env):
            if k.startswith(('ERL_', 'BEAM_', 'LD_', 'DYLD_')):
                env.pop(k)
        env['HOME'] = str(work)
        exe = prefix / 'bin/beam-pkg'
        check_schema(prefix, payload, work, env)

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
        (resource_only / 'beam.toml').write_text('format=1\n[package]\nname="test/resources"\nversion="1"\n[exports]\nresources=["message.txt"]\n')
        (resource_only / 'message.txt').write_text('packaged resource\n')
        build(resource_only)
        run([exe, 'install', resource_only], work, 0, env)
        exported = work / 'resource export'
        run([exe, 'export', '--output', exported, resource_only], work, 0, env)
        def export_snapshot():
            return {str(p.relative_to(exported)):
                    ('link', os.readlink(p)) if p.is_symlink() else
                    ('file', p.read_bytes()) if p.is_file() else ('directory',)
                    for p in exported.rglob('*')}
        export_before = export_snapshot()
        integrity, = (resource_only / '.beam/environments').rglob('integrity.toml')
        integrity_bytes = integrity.read_bytes()
        for version in (2, 3):
            integrity.write_bytes(re.sub(rb'(?m)^("format"\s*=\s*)1',
                                         rb'\g<1>' + str(version).encode(), integrity_bytes, count=1))
            run([exe, 'export', '--output', exported, resource_only], work, 1, env)
        integrity.write_bytes(integrity_bytes)
        installed_resource, = (resource_only / '.beam/environments').rglob('message.txt')
        installed_bytes = installed_resource.read_bytes()
        installed_resource.write_bytes(b'tampered resource\n')
        _, diagnostic = run([exe, 'export', '--output', exported, resource_only], work, 1, env)
        assert b'integrity' in diagnostic, diagnostic
        assert export_before == export_snapshot()
        installed_resource.write_bytes(installed_bytes)
        # Publishing another generation must replace the selection atomically,
        # including Windows exports without symbolic-link privileges.
        run([exe, 'export', '--output', exported, resource_only], work, 0, env)
        consumer_c = work / 'resource consumer'
        consumer_c.mkdir()
        (consumer_c / 'main.c').write_text('#include "registration.h"\n#include "package_inventory.h"\nint other(void);\nint from_cpp(void);\nint main(void) { return beam_package_inventory.count != 0 || beam_package_linked_nifs(0,0) != 0 || other() || from_cpp(); }\n')
        (consumer_c / 'other.c').write_text('#include "package_inventory.h"\nint other(void) { return beam_package_inventory.count != 0; }\n')
        (consumer_c / 'other.cpp').write_text('#include "package_inventory.h"\nextern "C" int from_cpp(void) { return beam_package_inventory.count != 0; }\n')
        (consumer_c / 'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.25)
project(resource_export LANGUAGES C CXX)
find_package(BEAM CONFIG REQUIRED COMPONENTS Runtime)
include("${EXPORT}/BEAMPackageExport.cmake")
add_executable(resource_consumer main.c other.c other.cpp)
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

        # Current archives are immutable; obsolete metadata and locks are rejected.
        current_archive = artifact(leaf)
        current_bytes = current_archive.read_bytes()
        with tarfile.open(current_archive, 'r:gz') as tar:
            entries = [(m.name, tar.extractfile(m).read(), tarfile.REGTYPE) for m in tar]
        invalid_archive = work / 'invalid-metadata.bpkg.tar.gz'
        archive_root = package(work / 'archive-read', 'archive-read', 'archive_read',
            extra=f'[dependencies]\n"test/leaf"={{version="1.0.0",archive="{invalid_archive.as_posix()}"}}\n')
        for change, diagnostic in (
            (lambda data: re.sub(rb'(?m)^("format"\s*=\s*)1', rb'\g<1>2', data, count=1), 'unsupported package format'),
            (lambda data: re.sub(rb'(?m)^("format"\s*=\s*)1', rb'\g<1>3', data, count=1), 'unsupported package format'),
            (lambda data: re.sub(rb'^"compiler-generation"[^\n]*\n', b'', data, flags=re.M), 'provenance; rebuild'),
        ):
            invalid_archive.write_bytes(tar_bytes([(n, change(d) if n == 'package.toml' else d, k)
                                                   for n, d, k in entries]))
            build(archive_root, False, diagnostic)
        invalid_archive.write_bytes(current_bytes)
        build(archive_root)
        lock_path = archive_root / 'beam.lock'
        lock_bytes = lock_path.read_bytes()
        selection = next(iter(tomllib.loads(lock_bytes.decode())['selections'].values()))

        def inline(value):
            if isinstance(value, dict):
                return '{' + ','.join(json.dumps(k, ensure_ascii=False) + '=' + inline(v)
                                      for k, v in value.items()) + '}'
            return json.dumps(value, ensure_ascii=False)

        for obsolete in (
            re.sub(rb'(?m)^("format"\s*=\s*)1', rb'\g<1>2', lock_bytes, count=1),
            ('format = 1\nroot = ' + inline(selection['root']) +
             '\nartifacts = ' + inline(selection['artifacts']) + '\n').encode(),
        ):
            lock_path.write_bytes(obsolete)
            run([exe, 'install', archive_root], work, 1, env)
            build(archive_root, False)
            assert lock_path.read_bytes() == obsolete
        lock_path.write_bytes(lock_bytes)
        run([exe, 'install', archive_root], work, 0, env)
        assert current_archive.read_bytes() == current_bytes

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
        run([exe, 'install', consumer], work, 1, env)
        lock_path.write_text(selected_lock.replace('"artifacts" = {', '"artifacts" = {"' + 'f' * 64 +
                            '" = {name = "test/unselected", version = "1", archive = "absent-unselected", dependencies = {}}, ', 1))
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
            (good.replace('format = 1', 'format = 2'), 'unsupported package format'),
            (good.replace('format = 1', 'format = 3'), 'unsupported package format'),
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
        # A source record can fit while its generated provenance record exceeds the limit.
        version = 'v' * (4194304 - len(good.encode()))
        (invalid / 'beam.toml').write_text(good.replace('version = "1.0.0"', 'version = "' + version + '"'))
        build(invalid, False, 'TOML exceeds 4 MiB')
        assert (invalid / 'beam.lock').read_bytes() == baseline_invalid
        assert not list((invalid / 'build/beam-pkg').glob('s-*'))
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
        (native / 'beam.toml').write_text((native / 'beam.toml').read_text().replace('["native.erl"]','["native.erl", "nif.erl"]'))
        build(native)
        # SDK-only native consumers get admission stamps without package policy.
        direct = work / 'direct native consumer λ'
        direct.mkdir()
        shutil.copy2(native / 'probe.c', direct / 'probe.c')
        direct_recipe = '''cmake_minimum_required(VERSION 3.25)
project(direct_native LANGUAGES C)
find_package(BEAM CONFIG REQUIRED COMPONENTS NIF)
if(COMMAND beam_package_native_output)
  message(FATAL_ERROR "SDK discovery supplied package output policy")
endif()
add_library(probe MODULE probe.c)
beam_target_nif(probe)
'''
        (direct / 'CMakeLists.txt').write_text(direct_recipe)
        direct_build = work / 'direct SDK-only build'
        run(['cmake', '-S', direct, '-B', direct_build,
             '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_PREFIX_PATH=' + str(prefix)], work, env=env)
        run(['cmake', '--build', direct_build, '--config', 'Release'], work, env=env)
        # Direct package consumers select the package-owned helper explicitly.
        (direct / 'CMakeLists.txt').write_text(direct_recipe + '''
include("${PACKAGE_HELPER}")
beam_package_native_output(probe NAME direct)
''')
        direct_build = work / 'direct package build'
        direct_install = work / 'direct package install'
        run(['cmake', '-S', direct, '-B', direct_build,
             '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_PREFIX_PATH=' + str(prefix), '-DPACKAGE_HELPER=' + str(helper),
             '-DCMAKE_INSTALL_PREFIX=' + str(direct_install)], work, env=env)
        run(['cmake', '--build', direct_build, '--config', 'Release'], work, env=env)
        run(['cmake', '--install', direct_build, '--config', 'Release'], work, env=env)
        direct_record = tomllib.loads((direct_build / 'beam-native-outputs/direct.toml').read_text())
        assert direct_record['name'] == 'direct' and (direct_install / direct_record['path']).is_file()

        native_lock = (native / 'beam.lock').read_bytes()
        native_archives = {p.name: p.read_bytes() for p in (native / 'build/beam-pkg/artifacts').iterdir()}

        def unchanged_native_selection():
            assert (native / 'beam.lock').read_bytes() == native_lock
            assert {p.name: p.read_bytes() for p in (native / 'build/beam-pkg/artifacts').iterdir()} == native_archives
            assert not list((native / 'build/beam-pkg').glob('s-*'))

        custom_payload = work / 'custom package application 日本'
        shutil.copytree(payload, custom_payload)
        custom_command = [prefix / 'bin/beam', 'run', '--application', custom_payload / 'application.etf', '--']
        helper.unlink()
        build(native, False, 'BEAMPackageNative.cmake')
        unchanged_native_selection()
        build(leaf)  # Pure bytecode builds do not require native output policy.
        # The actual application root supplies the helper, independent of Prefix.
        run([*custom_command, 'build', native], work, env=env)
        native_lock = (native / 'beam.lock').read_bytes()
        native_archives = {p.name: p.read_bytes() for p in (native / 'build/beam-pkg/artifacts').iterdir()}
        helper.write_bytes(helper_bytes)
        custom_helper = custom_payload / 'cmake/BEAMPackageNative.cmake'
        custom_helper.unlink()
        out, err = run([*custom_command, 'build', native], work, 1, env)
        assert not out and b'BEAMPackageNative.cmake' in err, err
        unchanged_native_selection()
        helper.write_bytes(helper_bytes + b'\n# altered helper\n')
        build(native, False, 'package native helper differs from its compiled identity')
        unchanged_native_selection()
        helper.write_bytes(helper_bytes)
        # Each project() guard verifies its private snapshot before inclusion.
        recipe = native / 'CMakeLists.txt'
        native_recipe = recipe.read_text()
        recipe.write_text(native_recipe + '''
get_filename_component(_guard_directory "${CMAKE_PROJECT_INCLUDE}" DIRECTORY)
file(APPEND "${_guard_directory}/BEAMPackageNative.cmake" "\\n# changed staged helper\\n")
project(second_native_project LANGUAGES C)
''')
        build(native, False, 'Package native helper differs from its compiled identity')
        unchanged_native_selection()
        recipe.write_text(native_recipe)
        build(native)
        if args.opposite_libc_sdk:
            old_lock = (native/'beam.lock').read_bytes()
            old_archives = {p.name:p.read_bytes() for p in (native/'build/beam-pkg/artifacts').iterdir()}
            out, err = run([exe,'build','--target-sdk',args.opposite_libc_sdk,native],work,1,env)
            assert not out and b'target SDK has no supported consumer toolchain' in err, err
            assert (native/'beam.lock').read_bytes() == old_lock
            assert {p.name:p.read_bytes() for p in (native/'build/beam-pkg/artifacts').iterdir()} == old_archives
            assert not list((native/'build/beam-pkg').glob('s-*'))
            run([exe,'build','--target-sdk',args.opposite_libc_sdk,leaf],work,env=env)
            run([exe,'install','--target-sdk',args.opposite_libc_sdk,leaf],work,env=env)
        narchive = artifact(native)
        extracted = work / 'extracted native'
        extracted.mkdir()
        with tarfile.open(narchive, 'r:gz') as tar:
            native_record = tomllib.loads(tar.extractfile('package.toml').read().decode())
            native_path = native_record['native']['artifacts']['probe']['path']
            assert native_record['native']['artifacts']['probe']['files'] == [native_path]
            assert set(native_record['native']) == {'artifacts', 'nifs', 'recipe', 'sdk'}
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
