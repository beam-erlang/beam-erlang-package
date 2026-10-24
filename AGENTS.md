# beam-erlang-package

Read `../AGENTS.md` for workspace rules. This repository owns `beam-pkg` policy,
its source/module inventory, compilation recipe, behavior tests and canonical
package-format proposal. Native hosting belongs to `beam-erlang`.

- Preserve the installed command syntax and status contract until deliberately revised.
  Build supports ordinary local Erlang/native graphs; install selects locked archives
  and project launch uses only installed generations. Tree remains a stub.
  Do not claim whole OTP application builds or compiler plugins.
- Keep one explicit inventory in `cmake/PackageTool.cmake`. Both standalone and
  distribution builds use this recipe with caller-supplied compiler commands/dependencies.
- Standalone builds use an installed matching BEAM SDK; distribution builds use its
  internal OTP-pinned bootstrap. Never substitute system Erlang, Rebar or a package fetch.
- Tests use newly compiled payloads in disposable copied prefixes. Do not modify the
  input SDK or import tests/runtime sources from sibling repositories.
- The generic application descriptor pins the tool module inventory. Inventory changes require a matching
  distribution rebuild; this is not a public plugin or release-compatibility interface.
- Keep ordinary package and OTP application boundaries in `docs/package-format.md`.
  The format is independently revisable; delivering OTP as BEAM packages is not
  a prerequisite for the separate OTP distribution. Existing OTP package drafts
  retain one complete application per package. Do not bypass the unresolved
  BEAM/STDLIB ownership conflict with subsets or duplicate providers.
- Keep framework and consumer manifests with their sources. Historical workspace
  candidates remain historical; update active guidance when ownership changes.
- Build and test under ignored `build/<flavor>` and install under `install/<flavor>`.
  Preserve Apache-2.0 notices and write session-independent documentation and commits.
- Validate against both supported installed flavors. Changes to distribution integration
  also require the distribution's full CTest suites and retained playground acceptance.
- This repository is local-only. Do not invent a remote, publish, or silently fetch sources.

- Build policy, TOML/ustar validation and locks remain package-owned Erlang code.
  Use selected installed compilation and CMake with literal argv, never shell strings.
- Keep help/version usable with output-only assets. Build/install select file/program/zlib; project preparation uses files.
  Failed builds preserve the prior lock; archives are immutable by digest.
- Explicit native bindings use beam_target_nif and public composition activation.
  Preserve optional unbound outputs and retained OTP compatibility coverage.
  Project launch uses a fresh VM without package/compiler modules; never bypass
  native admission or import OTP application services into that profile.

## Installed project shell and source tasks

`beam shell --project .` opens an installed BEAM selection, including library
roots without main/1. Preparation checks the complete interactive host inventory;
execution uses public composition and explicit native activation with host I/O.
Plain shell uses the modern BEAM profile. Project shell adds no filesystem, network,
program or implicit acquisition services. Never auto-build or install on launch.
`beam task [--project dir] [name [-- args...]]` lists or executes root-manifest
`[scripts]` literal argv arrays. Task policy belongs to beam-erlang-package;
native exec hosting belongs to beam-erlang and terminates the tool VM/system
before handing off terminal, streams and status. Scripts are source-only and
excluded from archives/locks/environments. Preserve GLM's unused test/ directory.
