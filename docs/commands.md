# Package commands

`beam` and its relative alias `beam-pkg` use the selected prefix's package policy
and SDK. No system Erlang or Rebar is used. Package policy belongs to this
repository; native hosting belongs to the distribution.

```sh
beam build .
beam-pkg install .
beam run --project . -- arguments
```

These are separate operations. Launch never builds, installs or resolves sources.

| Command | Behavior |
|---|---|
| `beam help build` | Build syntax; exit 0 |
| `beam build [directory]` | Build local source/archive graph; success 0, failure 1 |
| `beam-pkg build [directory]` | Build the local source/archive graph |
| `beam-pkg help [command]` | Syntax and experimental status; exit 0 |
| `beam-pkg version` | Distribution identity and implementation status; exit 0 |
| `beam-pkg install [project]` | Install the locked archive selection; success 0, failure 1 |
| `beam-pkg tree [project]` | Not implemented; stderr, exit 2 |
| `beam-pkg run --project <directory> [-- args...]` (also `beam run`) | Execute an installed root's `main/1` |
| `beam-pkg shell --project <directory>` (also `beam shell`) | Open the installed selection interactively, including library roots |
| `beam task [--project <directory>] [name [-- arguments...]]` | List or execute root-manifest development tasks |
| `beam help task` | Task syntax; exit 0 |

Packaging directories default to `.`; prefix names beginning with `-` with `./`.
Malformed arguments return 1. Both obsolete runtime selectors are rejected.
Arguments after `--` remain literal program arguments. Project execution preserves normal return,
requested halt status and exception diagnostics. Arguments are Unicode charlists.

Help/version and tree do not read project inputs or require compiler/file/program/
zlib assets. Build requires CMake 3.25+ on PATH, the selected prefix's compiler and
file/program/zlib services. Native recipes additionally need their C/C++ toolchain.
Installation uses CMake for SHA-256 verification, but never invokes compilation
or recipes and never reads source manifests. Launch needs neither CMake nor compiler
assets and reads only the installed selection and selected prefix's runtime assets.

Build writes private staging and content-addressed archives below `build/beam-pkg/`,
then atomically publishes `beam.lock` after graph success. It reports the root
archive on stdout; compiler/native diagnostics go to stderr. Failure preserves the
previous lock and artifacts; unused archives can remain. Explicit builds recompile
source inputs. Build does not create `.beam/` or start applications.

Install materializes the compiled root and selected dependencies in a new immutable
generation beneath `.beam/environments/`, then atomically replaces `.beam/current-<SDK-build-id>.toml`.
Failed installation preserves the previous selection and lock and removes staging.
Previous successful generations remain. Concurrent installation is unsupported.

Project preparation checks records, bytecode identities, dependency closure,
providers and native SDK compatibility in a temporary tool VM. That VM terminates
before the fresh execution VM starts. The execution profile contains core/base
code, private standard I/O support and selected package modules/native bindings.
It excludes tool modules, OTP applications, files, sockets, zlib, external programs
and implicit code acquisition. Missing host requirements fail. A library without
entry metadata is installable and usable in project shell, but cannot be run with `beam run`. Launch trusts installed file
contents locally; it does not claim fresh cryptographic verification.

Whole OTP application recipes, `.app.src` generation, build dependencies, compiler
transforms, registry access and OTP project execution remain deferred. See the
[package format](package-format.md) for records and native binding policy.

The private host passes `{{Identity, Prefix, WorkingDirectory, SearchPath},
ArgumentBinaries}`. Build/install select their required services; preparation selects
files and output. Inventory changes require a matching distribution host rebuild.
This private contract is not a general plugin interface.

## Project shell

`beam shell --project .` selects BEAM and reads only the installed environment.
It never invokes the root entry. Its execution VM adds the exact interactive
inventory to the project profile; those modules participate in provider and host
requirement checks. Native bindings activate before the prompt. Files, sockets,
zlib, external programs, implicit code acquisition and OTP startup remain absent.
Bindings, local functions, history, editing, error recovery, `q()`, EOF and explicit
halt use the real shell. Exit reclaims its native resources. Plain `beam shell`
uses the modern BEAM profile; obsolete OTP selectors are rejected before VM creation.
Missing installation is an error, not a request to build or install.

## Development tasks

```toml
[scripts]
shell = ["beam", "shell", "--project", "."]
demo = ["beam", "run", "--project", ".", "--"]
```

`beam task` lists names in sorted order from `./beam.toml`. `--project` selects
another directory without ancestor discovery. `beam task demo -- arguments`
appends literal arguments after removing the task command's separator. The demo
array includes its own `--` because project run requires one before program arguments.
Arrays require a nonempty executable; later strings
may be empty. NULs and invalid UTF-8 are rejected. Limits are 1 MiB for the task
manifest/combined argument bytes, 1024 tasks or arguments, and 16 KiB per string.
Task preparation checks format, identity and scripts independently of build
support; missing sources or deferred recipes do not block development commands.
Only the selected root's scripts are read. Scripts are excluded from archives,
locks and installed environments, so they require a source checkout.

The tool VM uses files/output, copies the command, and terminates with its system
before native hosting changes to the project directory and calls `execve`.
Standard descriptors, terminal, process group, signals and environment are
preserved. Bare `beam` and `beam-pkg` select this prefix's executables; other bare
names search inherited PATH, with relative entries interpreted in the project.
Paths containing slashes are relative to that directory unless absolute. There
is no implicit shell fallback; shell syntax requires an explicit interpreter.
Preparation/exec errors return 1; a launched command owns its output and status.
Explicit OTP task preparation is rejected; task arguments may select OTP for a
child command. Built-ins cannot be shadowed. No hooks, dependency scripts,
chaining, automatic build/install or project discovery are provided.

## Explicit target build, install and export

```sh
"$HOST_SDK/bin/beam-pkg" build --target-sdk "$TARGET_SDK" .
"$HOST_SDK/bin/beam-pkg" install --target-sdk "$TARGET_SDK" .
"$HOST_SDK/bin/beam-pkg" export --target-sdk "$TARGET_SDK" --output build/export .
```

The target defaults to the executing SDK. The executing SDK supplies the verified
compiler; the target supplies native headers, libraries, capabilities, identity
and installed consumer toolchain. iOS builds require explicit `DEVELOPER_DIR`.
Target binaries never execute. Compatible compiler generations permit portable
bytecode; native archives require exact target identity. `run`, `shell` and
`task` continue to operate on the local host selection.

Export reads one installed selection and its target SDK. It does not rebuild,
read source manifests, resolve dependencies or run package code. Missing or
invalid installed inputs fail before replacing the prior output. Formats and
the relocatable output tree are owned by [package formats](package-format.md).
Keep the full export directory for builds; copy only declared runtime assets
into an application. Xcode handles framework embedding and signing.
