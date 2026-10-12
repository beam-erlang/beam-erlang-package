# Package commands

The distribution installs `beam-pkg` as a relative alias of `beam`. This repository
owns the Erlang command policy; the distribution owns alias dispatch and hosting.

| Command | Scaffold behavior |
|---------|-------------------|
| `beam-pkg help [command]` | Syntax and experimental status; exit 0 |
| `beam-pkg version` | Distribution identity and scaffold status; exit 0 |
| `beam-pkg build [directory]` | “Not implemented” on stderr; exit 2 |
| `beam-pkg install [project]` | “Not implemented” on stderr; exit 2 |
| `beam-pkg tree [project]` | “Not implemented” on stderr; exit 2 |

No arguments shows help. Packaging directories default to `.`. Malformed arguments
exit 1; use `./` for directory names beginning with `-`. The stubs accept nonexistent
paths, do not read manifests, write locks, create directories or access the network.
There is no package-tool runtime selector. `version` reports the supplied distribution
identity; independent package-manager release versioning is deferred.

The output-only returning host needs neither OTP applications nor compiler,
interactive or source-run tooling. Package help/version start this small Erlang
composition. Arguments arrive as literal binaries; they are never evaluated as code.

The distribution separately recognizes
`beam [--runtime=otp|beam] run --project <directory> [-- args...]` and reports
“not implemented” with status 2 before starting a VM. Its existing source-run form
and runtime selection remain unchanged. Project launching is distribution policy;
its future installed-environment input is described in the [format proposal](package-format.md).
