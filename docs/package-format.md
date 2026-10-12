# First BEAM package format

## Status and scope

This is a working proposal, deliberately small and revisable. `beam-pkg` supplies
installed help, version and argument handling; build, install, tree and
`beam run --project` report **not implemented**. No manifest parser, package
builder, archive writer, installer or project launcher exists yet. Draft
manifests are design inputs, not evidence that these packages build or run.

The first working milestone will pair the [counter consumers](../../beam-erlang/docs/framework-consumers.md):
Erlangsters on BEAM with explicit dependencies, and OTP using the retained
installed framework. In `otp-framework`, one package corresponds to one complete
OTP application; no package selects a subset of an application’s modules.
Externalizing Kernel/STDLIB, resolving overlap with host-owned modules and deciding
boot boundaries are later work. A package does not select a runtime family.

## Source manifest

Use `beam.toml`, written in [TOML 1.0](https://toml.io/en/v1.0.0). This illustrative
manifest describes an ordinary module package:

```toml
format = 1

[package]
name = "erlangsters/worker"
version = "0.0.2"

[build]
sources = ["src/worker.erl"]

[exports]
headers = []
resources = []
licenses = ["LICENSE.md"]

[dependencies]
"erlangsters/spawn_mode" = { version = "0.0.2", path = "../spawn_mode" }
"otp/stdlib" = { version = "8.0", path = "../../../otp-framework/lib/stdlib" }

[build-dependencies]

[host]
modules = ["erlang"]
```

Paths are relative to the manifest directory. Ordinary library inputs are explicit
files, without implicit globbing. The whole-application form below instead
describes an application build unit. Built artifacts must contain the selected
outputs and never depend on source paths. `headers` export files under `include/`,
`resources` under `priv/`, and `licenses` under `licenses/`; initially use each
input's basename and reject destination collisions. Private include search
paths may be listed as `build.include-directories`. Source files are not shipped
in the initial built artifact. Preserve license and copyright notices.

`dependencies` are needed during execution. `build-dependencies` provide only
compilation-time code, such as behaviors; a library needed in both places is
listed in both tables. Tooling availability does not make a module an execution
dependency. Compiler behavior-module inputs and transform handling are deferred.
`host.modules` declares modules supplied by the selected execution environment;
`host.applications`, when present, declares retained OTP applications by name and
exact version. A future build record must also identify the compiler and host
used. Host declarations are requirements, not downloads or startup instructions.

Each dependency names an exact package version and exactly one locator: `path`
for a local source directory containing `beam.toml`, or `archive` for a local
built archive. For example:

```toml
[dependencies]
"erlangsters/spawn_mode" = { version = "0.0.2", archive = "../artifacts/spawn_mode-0.0.2.bpkg.tar.gz" }
```

The declared identity must agree with the selected manifest/artifact. Conflicting
versions or artifact selections for the same package fail; there is no version
solver, registry, network acquisition or global installation in this iteration.
Local paths are acquisition hints only, removed from published metadata.

A package is an ordinary library unless it supplies application metadata:

```toml
[application]
file = "resources/counters.app"

[entry]
module = "otp_counters_main"
```

Initially at most one supplied `.app` is copied to `ebin/`; its OTP metadata is
preserved. Whole OTP application source packages use a template instead:

```toml
format = 1

[package]
name = "otp/stdlib"
version = "8.0"

[build]
otp-application = "."

[application]
source = "src/stdlib.app.src"

[dependencies]
"otp/kernel" = { version = "11.0", path = "../kernel" }
```

`build.otp-application` names the complete application source directory, not a
module selection. It is an alternative to `build.sources`. The package preserves
the application identity, module inventory, public headers, private resources and
application metadata. `application.source` is an alternative to a supplied
`application.file`: the future application build will resolve the template and
produce the `.app` under `ebin/`. Application-specific generators, native outputs
and template/version substitution remain unimplemented. This form is a draft
build-unit declaration, not a claim that a directory scan is a sufficient recipe.
Omitted header/resource lists in these manifests do not mean empty application
contents; the complete application build owns their inventory.

Installing a package never starts an OTP application. Executable roots optionally name an entry
module exporting `main/1`; application startup remains explicit consumer policy.
The Erlangsters drafts are ordinary module packages and omit `application`:
their imported `.app.src` declarations do not impose Kernel/STDLIB startup.

## Built artifact and selected results

A `.bpkg.tar.gz` is a gzip-compressed tar with these relative entries:

```text
package.toml          generated portable metadata, format = 1
ebin/                 compiled modules and optional resolved .app
include/              exported headers, if any
priv/                 exported resources, if any
licenses/             selected license files
```

Generated metadata records identity, module inventory, exact dependency
identities, host requirements, exports and optional application/entry. It must
not contain source checkout locations or acquisition paths. Package metadata is
separate from OTP `.app` metadata. Safe archive extraction and bytecode provenance
handling belong to the future implementation; this layout is not a native-code
ABI or a cross-version bytecode compatibility promise.

The SHA-256 of the complete archive identifies exact bytes. Name/version is a
human identity and does not guarantee byte equality. Rebuilding the same version
may produce a different digest; an explicit build updates selected results.
Installation consumes locked archives and must reject digest mismatches rather
than silently rebuilding. Hashing, reproducibility details and archive machinery
remain unimplemented.

## Intended local workflow

```text
source manifests -> compiled archives + beam.lock -> .beam/ environment -> execution
```

- `beam-pkg build [directory]` will build the root and its local dependency graph,
  producing archives and selecting exact results in the root's `beam.lock`.
- `beam-pkg install [project]` will verify the lock and materialize a project-local
  `.beam/` environment containing the compiled root, execution dependencies and
  generated launch metadata. Build-only code is excluded unless also needed at runtime.
- `beam-pkg tree [project]` will show selected dependencies and host requirements.
- `beam [--runtime=otp|beam] run --project <directory> [-- args...]` will launch the
  installed root's `main/1`, without compiling sources or resolving dependencies.

Packaging directories default to `.`. The implemented stubs return 2 and write
“not implemented” to stderr, without reading manifests or changing the filesystem.
Malformed arguments return 1; help and version return 0. Project launch requires
an explicit directory. Use `./` for a directory name beginning with `-`.

The following are illustrative record fields, not generated files or a frozen
serialization. `beam.lock` will carry a root selection and one record per selected
artifact; each record needs `name`, `version`, its actual archive SHA-256, a local
archive locator, and exact dependency edges. For example, the worker selection
will point to the spawn_mode selection by its real digest, not just `0.0.2`.
Locators may be machine-local in a lock and must not leak into portable metadata.
No placeholder hashes should be accepted as real lock records.

The installed environment record will identify the root entry, relative artifact
locations, exact identities/digests, module-to-provider mapping and host requirements.
For the worker example that mapping assigns `worker` to the worker artifact,
`spawner` to spawn_mode, and `lists` to STDLIB. A copied project needs only its
`.beam/` tree and a compatible explicitly selected distribution prefix; sources,
source `beam.toml`, source lock locators and original checkout paths must not be
needed at launch. The exact internal environment layout remains open. This is
not an executable/runtime bundle.

## Composition and iteration

One provider owns each module name in an execution composition, including host
modules whether already loaded or reserved for later loading. Package names do
not namespace Erlang modules. Conflicts must fail before package entry or
application callbacks run. Package metadata alone cannot certify host compatibility.

The Erlangsters drafts declare the complete `otp/stdlib` package for their uses
of `lists`, `maps`, `sets` and other STDLIB modules. STDLIB retains its declared
`otp/kernel` application dependency. The imported Erlangsters `.app.src` files
do not themselves impose application startup; actual calls and lifetimes still
need auditing. The OTP counter draft instead requires retained installed Kernel
and STDLIB as host applications for its initial milestone.

The current BEAM host supplies modules also owned by STDLIB. These draft packages
do **not** establish an executable Erlangsters composition. A later architectural
step must resolve module ownership and framework startup requirements before
launching that graph. Do not silently allow duplicate providers, borrow private
shell inventories, or split OTP applications into subset packages to bypass this
boundary. Installing an application package and starting its application remain
separate operations; availability of a module does not prove it works without
the containing application’s services.

Next implement parsing/validation, then a single leaf build and archive round-trip,
then dependency builds and installation, and finally both bounded counter workloads.
Each step should replace proposed behavior with measured installed acceptance.
Native packages, arbitrary transforms, registry operations, version ranges,
compiler self-hosting and externalized Kernel/STDLIB remain deferred. Historical
package candidates in workspace `notes/` are background, not this format's contract.
