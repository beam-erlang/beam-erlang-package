# beam-erlang-package

Read `../AGENTS.md` for workspace rules. This repository owns `beam-pkg` policy,
its source/module inventory, compilation recipe, behavior tests and canonical
package-format proposal. Native hosting belongs to `beam-erlang`.

- Preserve the installed command syntax and status contract until deliberately revised.
  Package build/install/tree remain explicit stubs; do not claim a working package engine.
- Keep one explicit inventory in `cmake/PackageTool.cmake`. Both standalone and
  distribution builds use this recipe with caller-supplied compiler commands/dependencies.
- Standalone builds use an installed matching BEAM SDK; distribution builds use its
  internal OTP-pinned bootstrap. Never substitute system Erlang, Rebar or a package fetch.
- Tests use newly compiled payloads in disposable copied prefixes. Do not modify the
  input SDK or import tests/runtime sources from sibling repositories.
- The private host pins the tool module inventory. Inventory changes require a matching
  distribution rebuild; this is not a public plugin or release-compatibility interface.
- Keep ordinary package and OTP application boundaries in `docs/package-format.md`.
  One complete OTP application maps to one package. Do not bypass the unresolved
  BEAM/STDLIB ownership conflict with subsets or duplicate providers.
- Keep framework and consumer manifests with their sources. Historical workspace
  candidates remain historical; update active guidance when ownership changes.
- Build and test under ignored `build/<flavor>` and install under `install/<flavor>`.
  Preserve Apache-2.0 notices and write session-independent documentation and commits.
- Validate against both supported installed flavors. Changes to distribution integration
  also require the distribution's full CTest suites and retained playground acceptance.
- This repository is local-only. Do not invent a remote, publish, or silently fetch sources.
