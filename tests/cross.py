"""Cross-target provenance, installed selection, and atomic export acceptance."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tomllib
from scratch import scratch


def main():
    p=argparse.ArgumentParser()
    for key in ('beam','payload','work'):
        p.add_argument('--'+key,required=True,type=Path)
    p.add_argument('--first-sdk','--device-sdk',dest='first_sdk',required=True,type=Path)
    p.add_argument('--second-sdk','--simulator-sdk',dest='second_sdk',required=True,type=Path)
    a=p.parse_args();root=a.work.resolve();root.mkdir(parents=True,exist_ok=True)
    with scratch(root):
        host=root/'host';shutil.copytree(a.beam.resolve().parent.parent,host,symlinks=True)
        payload=host/'lib/beam/apps/beam-pkg';shutil.rmtree(payload);shutil.copytree(a.payload,payload)
        tool=host/'bin/beam-pkg'
        project=root/'package';project.mkdir();native=project/'native';native.mkdir()
        (project/'beam.toml').write_text('''format=2
[package]
name="test/cross"
version="1"
[build]
sources=["cross.erl"]
[build.native]
cmake="native"
outputs=["cross_native", "support"]
[build.native.nifs]
cross="cross_native"
[exports]
resources=["payload.txt"]
[host]
modules=["erlang"]
''')
        (project/'cross.erl').write_text('-module(cross).\n-export([value/0]).\nvalue()->erlang:nif_error(unloaded).\n')
        (project/'payload.txt').write_text('exported resource\n')
        (native/'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.25)
project(cross_native LANGUAGES C CXX)
find_package(BEAM CONFIG REQUIRED COMPONENTS NIF)
add_library(cross_native STATIC probe.c)
beam_target_nif(cross_native MODULE cross)
beam_package_native_output(cross_native NAME cross_native)
add_library(support STATIC support.cpp)
target_link_libraries(cross_native PRIVATE support)
beam_package_native_output(support NAME support)
''')
        (native/'support.cpp').write_text('#include <string>\nextern \"C\" int support_value(void) { return std::string(\"native\").size()+36; }\n')
        (native/'probe.c').write_text('''#include <erl_nif.h>
extern int support_value(void);
static ERL_NIF_TERM value(ErlNifEnv *e,int n,const ERL_NIF_TERM v[]) { return enif_make_int(e,support_value()); }
static ErlNifFunc f[]={{"value",0,value,0}};
ERL_NIF_INIT(cross,f,NULL,NULL,NULL,NULL)
''')
        def run(*args,ok=True):
            r=subprocess.run(list(map(str,args)),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=180)
            assert (r.returncode==0)==ok,(args,r.returncode,r.stdout)
            return r.stdout
        def invoke(command,sdk,*extra,ok=True):
            return run(tool,command,'--target-sdk',sdk,*extra,project,ok=ok)
        selections=[];archives={}
        for sdk in (a.first_sdk.resolve(),a.second_sdk.resolve()):
            invoke('build',sdk)
            lock=tomllib.loads((project/'beam.lock').read_text());assert lock['format']==2
            assert len(lock['selections'])==len(selections)+1
            sdk_meta=tomllib.loads((sdk/'lib/beam/sdk.toml').read_text())
            matches=[v for v in lock['selections'].values() if v['sdk']==sdk_meta]
            assert len(matches)==1,lock
            digest=matches[0]['root'];selections.append(digest)
            archive=project/'build/beam-pkg/artifacts'/f'{digest}.bpkg.tar.gz'
            with tarfile.open(archive) as t: meta=tomllib.loads(t.extractfile('package.toml').read().decode())
            assert meta['format']==3 and meta['compiler']==tomllib.loads((host/'lib/beam/sdk.toml').read_text())
            assert meta['native']['sdk']==sdk_meta
            record=meta['native']['artifacts']['cross_native']
            assert record['kind']=='static' and record['module']=='cross',record
            assert all(not Path(x).is_absolute() for x in record['files'])
            assert record['dependencies']==['output:support'],record
            assert meta['native']['artifacts']['support']['language']=='CXX'
            archives[archive]=archive.read_bytes()
            invoke('install',sdk)
        # Two exact target selections survive; immutable prior archives survive.
        for path,data in archives.items(): assert path.read_bytes()==data
        environment_files=list((project/'.beam/environments').glob('*/environment.toml'))
        assert len(environment_files)==2
        # A well-formed lock cannot substitute a another target native archive for the first SDK.
        lock_path=project/'beam.lock';saved_lock=lock_path.read_text()
        lock_path.write_text(saved_lock.replace(selections[0],selections[1]))
        message=invoke('install',a.first_sdk,ok=False)
        assert 'SDK/target mismatch' in message,message
        lock_path.write_text(saved_lock)
        # Undeclared native link inputs cannot leak absolute build-host paths.
        recipe=native/'CMakeLists.txt';recipe.write_text(recipe.read_text()+
            '\ntarget_link_libraries(cross_native PRIVATE "/undeclared/host/library.a")\n')
        invoke('build',a.first_sdk,ok=False)
        assert lock_path.read_text()==saved_lock
        # Attested generation facts are verified before either compiler is selected.
        bad_generation=root/'wrong-generation';shutil.copytree(a.first_sdk,bad_generation,symlinks=True)
        facts_path=bad_generation/'lib/beam/target.toml';facts=facts_path.read_text()
        generation=tomllib.loads(facts)['compiler-generation']
        facts_path.write_text(facts.replace(generation,'0'*64))
        invoke('build',bad_generation,ok=False)
        # A self-consistent target with another attested generation also fails.
        generation_file=bad_generation/'lib/beam/compiler-generation.json'
        generation_file.write_bytes(generation_file.read_bytes()+b'\n')
        different=hashlib.sha256(generation_file.read_bytes()).hexdigest()
        facts_path.write_text(facts.replace(generation,different))
        inventory_path=bad_generation/'lib/beam/runtime-artifacts.json'
        inventory=json.loads(inventory_path.read_text())
        for name,file in (('compiler.generation',generation_file),('sdk.target',facts_path)):
            inventory['artifacts'][name]['sha256']=hashlib.sha256(file.read_bytes()).hexdigest()
        inventory_path.write_text(json.dumps(inventory))
        message=invoke('build',bad_generation,ok=False)
        assert 'compiler generations differ' in message,message
        # Source and build outputs are not inputs to export.
        shutil.rmtree(native);(project/'cross.erl').unlink();shutil.rmtree(project/'build')
        output=root/'export'
        invoke('export',a.first_sdk,'--output',output)
        first=os.readlink(output/'current')
        exported=tomllib.loads((output/'current/export.toml').read_text());assert exported['format']==1
        assert list((output/'current').rglob('payload.txt'))
        assert 'beam_package_linked_nifs' in (output/'current/registration.c').read_text()
        assert str(root) not in (output/'current/package.cmake').read_text()
        invoke('export',a.second_sdk,'--output',output)
        assert os.readlink(output/'current')!=first
        consumer=root/'consumer';consumer.mkdir()
        (consumer/'main.c').write_text('#include "registration.h"\nint main(void) { return beam_package_linked_nifs(0,0)!=1; }\n')
        (consumer/'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.25)
project(export_consumer LANGUAGES C)
find_package(BEAM CONFIG REQUIRED COMPONENTS Runtime)
include("${EXPORT}/BEAMPackageExport.cmake")
add_executable(consumer main.c)
target_link_libraries(consumer PRIVATE BEAMPackageInputs BEAM::Runtime)
''')
        def configure(sdk,build,ok=True):
            return run('cmake','-S',consumer,'-B',build,'-G','Ninja',
                '-DCMAKE_TOOLCHAIN_FILE='+str(sdk.resolve()/'lib/cmake/BEAM/BEAMToolchain.cmake'),
                '-DEXPORT='+str(output),ok=ok)
        configure(a.first_sdk,root/'wrong-slice',ok=False)
        configure(a.second_sdk,root/'consumer-build')
        run('cmake','--build',root/'consumer-build')

        # Failure after a prior export must leave its selected generation usable.
        selected=os.readlink(output/'current')
        files=[x for x in (project/'.beam/environments').rglob('payload.txt')]
        for x in files:x.write_text('tampered installed resource\n')
        invoke('export',a.second_sdk,'--output',output,ok=False)
        assert os.readlink(output/'current')==selected
        assert (output/'current/registration.c').is_file()
        # The installed toolchain is a verified input, never an optional host fallback.
        bad=root/'missing-toolchain';shutil.copytree(a.first_sdk,bad,symlinks=True)
        (bad/'lib/cmake/BEAM/BEAMToolchain.cmake').unlink()
        invoke('build',bad,ok=False)
        # No target executable is needed or permitted by the SDK contract.
        for sdk in (a.first_sdk,a.second_sdk):
            assert not (sdk/'bin/beam').exists() and not (sdk/'bin/beam-pkg').exists()
        print('cross-target selections, provenance, installed-only export, atomic recovery: passed')


if __name__=='__main__': main()
