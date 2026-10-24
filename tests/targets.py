# SPDX-License-Identifier: Apache-2.0
"""Keep two real SDK target closures and installed selections in one project."""
import argparse
import json
import os
from pathlib import Path
import tomllib
from process import capture
from scratch import scratch


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', type=Path, action='append', required=True)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--result', type=Path, help='External compact result; defaults beside --work')
    args = parser.parse_args()
    if len(args.prefix) != 2:
        parser.error('Select exactly two independently installed SDKs')
    prefixes = [path.resolve(strict=True) for path in args.prefix]
    sdks = [tomllib.loads((path / 'lib/beam/sdk.toml').read_text()) for path in prefixes]
    if len({item['build-id'] for item in sdks}) != 2:
        parser.error('The selected SDKs must have distinct build identities')
    root = args.work.resolve()
    result_path = args.result.resolve() if args.result else root.parent / (root.name + '.json')
    if result_path.is_relative_to(root):
        parser.error('The result must be outside disposable work')
    root.mkdir(parents=True, exist_ok=False)
    with scratch(root):
        project = root / 'shared project 日本'
        project.mkdir()
        (project / 'beam.toml').write_text('''format = 2
[package]
name = "test/targets"
version = "1.0.0"
[build]
sources = ["entry.erl"]
[host]
modules = ["erlang", "io"]
[entry]
module = "entry"
''')
        (project / 'entry.erl').write_text('-module(entry).\n-export([main/1]).\n'
            'main([])->io:format("~p~n",[erlang:system_info(emu_flavor)]).\n')
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(('ERL_', 'BEAM_', 'LD_', 'DYLD_'))}
        env['HOME'] = str(root)

        def run(prefix, *arguments, expected=0):
            tool = 'beam-pkg' if arguments[0] == 'install' else 'beam'
            result = capture([str(prefix / 'bin' / tool), *map(str, arguments)],
                             cwd=root, env=env, text=True, timeout=180)
            with (root / 'commands.log').open('a') as log:
                log.write(json.dumps([str(prefix), *map(str, arguments)]) + '\n' + result.stdout + result.stderr)
            assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
            return result.stdout

        first_lock = None
        for prefix in prefixes:
            run(prefix, 'build', project)
            lock = tomllib.loads((project / 'beam.lock').read_text())
            assert lock['format'] == 2
            if first_lock is None:
                first_lock = lock['selections'].copy()
            else:
                assert len(lock['selections']) == 2
                assert all(lock['selections'][key] == value for key, value in first_lock.items())
            run(prefix, 'install', project)
        pointers = [project / '.beam' / ('current-' + sdk['build-id'] + '.toml') for sdk in sdks]
        saved = [path.read_bytes() for path in pointers]
        for prefix, sdk in zip(prefixes, sdks):
            assert run(prefix, 'run', '--project', project) == sdk['flavor'] + '\n'
        pointers[1].write_text('format = 2\ngeneration = "../escape"\n')
        assert run(prefixes[0], 'run', '--project', project) == sdks[0]['flavor'] + '\n'
        run(prefixes[1], 'run', '--project', project, expected=1)
        pointers[1].write_bytes(saved[1])
        assert run(prefixes[1], 'run', '--project', project) == sdks[1]['flavor'] + '\n'
        assert [path.read_bytes() for path in pointers] == saved
        record = {'status': 'passed',
            'sdks': sdks, 'target_selections': len(lock['selections']),
            'checks': ['preserved closures', 'independent installed pointers',
                       'selected runtime flavors', 'corrupt other target isolation', 'recovery']}
    record['payloads_removed'] = not root.exists()
    result_path.write_text(json.dumps(record, indent=2) + '\n')
    print('Two real SDK target closures, independent launch and recovery passed')


if __name__ == '__main__':
    main()
