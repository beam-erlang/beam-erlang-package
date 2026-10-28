# BEAM package format 1

## Status and lifecycle

Format 1 is the current experimental, revisable package format. Every package-owned
TOML record requires `format = 1`; each record has its own schema. Unsupported
versions, unknown fields and obsolete record structures fail. There are no older
readers, conversions or fallback selection locations. Regenerate obsolete archives,
locks, installations and exports from current sources; do not relabel their bytes.
Remove an obsolete generated lock explicitly before rebuilding its project.

Package versions, the package tool's application version, SDK metadata and generic
application/command protocols are independent identities. Format 1 does not freeze
a public native ABI or promise compatibility with earlier development artifacts.

```text
beam.toml -> package archives + beam.lock -> .beam/ installation -> execution/export
```

| Record | Producer and consumer | Required fields | Optional fields/defaults |
| --- | --- | --- | --- |
| `beam.toml` | Author; build and source tasks | `format`, `package` | `build`, `exports`, `dependencies`, `build-dependencies`, `host`, `application`, `entry`, `scripts`: empty tables |
| Archive `package.toml` | Build; acquisition, install and preparation | `format`, `package`, `modules`, `compiler`, `compiler-generation` | `dependencies`, `exports`, `host`, `application`, `entry`: empty tables; `native`: absent |
| `beam.lock` | Build; build/acquisition and install | `format`, `selections` | None |
| `environment.toml` | Install; run, shell and export preparation | `format`, `sdk`, `root`, `packages` | None |
| `current-<sdk-build-id>.toml` | Install; preparation | `format`, `generation` | None |
| `integrity.toml` | Install; export | `format`, `packages` | None |
| `export.toml` | Export; application build inspection | `format`, `sdk`, `compiler-generation`, `root`, `packages` | None |

Build, install and launch are separate explicit operations. Launch never builds,
installs, resolves source dependencies or executes tasks. See [commands](commands.md).
The independent [OTP distribution](../../erlang-otp/README.md) is not delivered
through this experimental workflow. Whole OTP application recipes and project
startup remain deferred; proposed OTP packages retain complete applications.

## Shared syntax and identifiers

Records use a subset of TOML 1.0: tables and dotted table paths, bare/quoted keys,
basic/literal single-line strings, escapes, signed decimal 64-bit integers,
booleans, arrays and inline tables. Comments and multiline arrays are supported.
Dates, floats, multiline strings, nondecimal integers and arrays of tables are
unsupported. Duplicate definitions fail. This is not a general TOML parser.

`package` requires `name` and `version`. Names contain lowercase ASCII letters,
digits, `/`, `_`, `-` and `.`, with nonempty path components other than `.` or `..`.
Versions are nonempty exact strings: SemVer and version-range solving are not
required or implemented. Dependency versions use the same exact identity rule.
Module identifiers start with a lowercase ASCII letter, followed by ASCII letters,
digits, `_` or `@`. SHA-256 values are 64 lowercase hexadecimal characters.

Source paths resolve relative to their manifest; lock archive locators resolve
relative to their lock. Portable artifact paths are relative, slash-separated,
with no empty, `.` or `..` component, backslash, control character or absolute
root. Files must remain under their declared export directory. Source/acquisition
paths never enter portable archive metadata. Export additionally rejects path
characters unsafe for its generated CMake/Xcode inputs (`$`, `"`, `;`, backtick).

An SDK record requires its independently owned `format = 1`, `identity`, `build-id`,
`os`, `architecture`, `triple` and `flavor`. The build ID is a SHA-256 identity;
other fields are nonempty strings. Exact SDK comparisons include the whole record.
`compiler-generation` identifies the attested compiler seed manifest by SHA-256.

Native SDK selection includes libc through the existing SDK identity and target
metadata. glibc and musl native artifacts are distinct selections. Native builds
verify the actual C/C++ toolchain's OS, architecture and libc and retain compiler
environment matching. A same-architecture host toolchain is not a cross-libc
fallback; absent an installed consumer toolchain, such a native build fails
before publishing artifacts or changing the previous lock. Generated CMake
exports repeat native target verification. Pure-bytecode packages may still be
built and installed for a target with the same compiler generation. These checks
use the existing format 1 records; no additional manifest field is required.

## Source manifests

```toml
format = 1
[package]
name = "example/math"
version = "1.0.0"
[build]
sources = ["src/math_helpers.erl"]
include-directories = ["include"]
[exports]
headers = ["include/math_helpers.hrl"]
resources = []
licenses = ["LICENSE.md"]
[dependencies]
"example/constants" = { version = "1.0.0", path = "../constants" }
[host]
modules = ["erlang"]
```

`build.sources` and `build.include-directories` default to empty string arrays.
Sources are explicit files, without globbing or implicit acquisition. Compilation
uses the selected installed `beam compile --deterministic --no-transforms`;
execution-dependency headers become explicit include inputs. Builds never execute
package code. Nonempty `build-dependencies`, compiler transforms and
`build.otp-application` recipes are unsupported.

Each `dependencies` entry is keyed by package name and requires `version` plus
exactly one `path` or `archive`. Only an archive dependency may also specify `lock`:

```toml
[dependencies]
"example/math" = { version = "1.0.0", archive = "../artifacts/math.bpkg.tar.gz", lock = "../producer/beam.lock" }
```

An archive with dependencies requires an explicit companion lock. Its selected
record and transitive edges must agree with portable metadata; only the selected
closure is imported. Every consumed archive digest is verified. Missing inputs,
cycles and conflicting package versions, artifact selections or source locations
fail without cache scanning, source fallback or network acquisition.

`host.modules` defaults to an empty module-name array. `host.applications` defaults
to an empty application-name-to-exact-version table. These declare supplied
execution requirements; they neither acquire packages nor start applications.
Compiler-private modules are not execution providers.

`exports.headers`, `exports.resources` and `exports.licenses` default to empty
source-file arrays. Exports use basenames under `include/`, `priv/` and `licenses/`;
collisions fail. Optional `application.file` names a resolved `.app` file copied
unchanged to `ebin/`. Templates (`application.source`) are unsupported. Optional
`entry.module` must name a supplied package module; execution additionally requires
its `main/1` export. Ordinary libraries need neither application nor entry metadata.

Optional `[scripts]` maps task names to literal argv arrays. Build validates but
never executes or publishes scripts. Task preparation checks format, package
identity and scripts independently of build support or source-file existence.
Scripts never enter archives, locks, environments or exports. See the
[task command and limits](commands.md#development-tasks).

## Native recipes and portable metadata

```toml
[build.native]
cmake = "."
outputs = ["glm"]
nifs = { glm_raw = "glm" }
```

A source native recipe requires `cmake` and a unique `outputs` array; `nifs`
defaults to an empty table. Output identifiers are logical names (ASCII letters,
digits, `_`, `-`) or explicit paths under `priv/`. Source bindings map supplied
module names to declared output identifiers, with one module per library.

`beam_package_native_output(target NAME identifier)` records actual installed
filenames and structured artifacts; no platform suffix is guessed. The selected
SDK supplies native headers, libraries, capabilities and consumer toolchain.
The output helper belongs to `beam-pkg`, in
`lib/beam/apps/beam-pkg/cmake/BEAMPackageNative.cmake`. Native package builds
automatically verify a private snapshot against the executing tool's compiled
helper identity and include it before the recipe runs. Direct CMake consumers
select that package-owned file explicitly with `include()` after selecting their
BEAM SDK; SDK discovery alone does not provide package output policy.
The executing SDK supplies the attested compiler. Cross-target compilation
requires matching compiler generations and never executes target binaries.
Host builds support their installed Linux, Darwin and Windows toolchains;
iOS and Android use explicitly selected target SDKs and platform tools.

The recipe installs exactly its declared file inventory under `priv/` in private
staging, using Release configuration and out-of-source output. CMake registry
lookup and FetchContent acquisition are disabled. Recipes and native libraries
are trusted code with explicit offline inputs, not sandboxed code. System C/C++
runtime dependencies are not bundled by the package archive writer.

Generated `native` requires `sdk`, `recipe = "cmake"` and `artifacts`; `nifs` is
optional and defaults to an empty table. **`artifacts` is the authoritative native
inventory.** There are no generated `outputs` or `identities` fields.

`native.artifacts` maps output identifiers to these records:

| Field | Requirement and meaning |
| --- | --- |
| `path` | Required primary installed path under `priv/`. |
| `files` | Required nonempty array of all installed files for this artifact, including `path` and any registration header. |
| `kind` | Required `static` or `shared`, supported by the target SDK. |
| `sdk-build-id` | Required exact match to `native.sdk.build-id`. |
| `language` | Required `C` or `CXX`. |
| `dependencies` | Required ordered array; may be empty. Supports `output:<identifier>`, `sdk:runtime`, `system:m`, `system:c++`; Android also permits `system:android`, `system:log`, `system:dl`, `system:c++_shared`. |
| `module`, `binding`, `header` | Optional complete static linked-NIF registration triplet: module identifier, C accessor symbol and header included in `files`. |

All artifact files are unique within and across records. Their union supplies the
native archive inventory. Dependencies resolve within the same package, preserve
link order, have no repeated edges or cycles, and have at most 128 artifact levels
on any path. Arbitrary linker flags and absolute host paths are unsupported.

Generated `native.nifs` maps package modules to concrete artifact primary paths,
never auxiliary files. Bound static artifacts require matching registration
metadata. Unbound artifacts, including artifacts with registration metadata, remain
valid and are never implicitly activated. Native compatibility requires the exact
target SDK; this is a matching-build contract, not a stable ABI promise.

A host-only recipe using an explicit `priv/` output without structured CMake output
metadata retains its singleton shared/C artifact with no declared link dependencies.
Cross-target recipes require structured records.

Build does not execute native code. Preparation and public composition perform
explicit native admission and activation. Mapping dynamic libraries can execute
platform constructors. Static NIFs use generated resident selections; activation
checks module identity, ABI and function tables. Initial load information is
`undefined`. Implicit loading, arbitrary `on_load`, rebinding and hot upgrades are
unsupported. These provisional loading/lifetime rules do not change OTP's native
loading semantics.

## Archives and locks

A `.bpkg.tar.gz` contains generated `package.toml`, compiled `ebin/`, optional
`include/` and `priv/`, and license files under `licenses/`. Metadata `modules` is
an explicit inventory. Module names are checked against bytecode without loading
it. The entire archive inventory must equal the metadata's module, application,
export and native file inventories, without duplicate destinations.

Archive `dependencies` maps package names to `{ version, sha256 }` records.
`compiler` describes the actual executing host SDK; `compiler-generation` must
match the selected target's verified generation. `native.sdk` describes the native
destination. Package names do not namespace Erlang modules: duplicate providers
and collisions with declared host providers fail.

Encoding is gzip plus POSIX ustar. Writers emit sorted regular files with
normalized metadata. Readers accept regular files and directories, and reject
links, special entries, extensions, unsafe paths, conflicting destinations,
bad checksums, truncation and invalid inventories. Paths must fit ustar fields.
SHA-256 identifies the complete archive bytes. The builder uses CMake's SHA-256
command and stores archives in `build/beam-pkg/artifacts/<digest>.bpkg.tar.gz`.
An explicit rebuild may select different bytes for the same package identity.
Consumed archives are copied to the same immutable local store.

`beam.lock.selections` is a nonempty table keyed by
`OS/architecture/flavor/build-id` from the exact selected SDK. Every selection
requires `sdk`, `root` (archive digest) and `artifacts`. Artifact records are keyed
by digest and contain `name`, `version`, `archive` and `dependencies` (defaulting
to an empty table). Dependency edges must agree exactly with archive metadata;
archive locators are local to the lock and are not portable metadata.

A build replaces only its matching selection and preserves other validated target
selections. Install and companion-lock acquisition require an exact SDK key, never
another flavor or target implicitly. Archives are published before atomic lock
replacement. Failed builds preserve the previous lock; unselected immutable archives
may remain. Staging is cleaned on success and failure. Cleanup errors are diagnosed
without converting successful publication to failure. Concurrent publication into
one project is unsupported.

## Installed environments and execution

Install reads only the selected lock closure, verifies hashes and edges, and
extracts packages to a private generation beneath `.beam/environments/`.
`environment.toml` records the selected `sdk`, root digest and `packages`, a
nonempty digest-to-relative-location table. Each location is exactly
`packages/<digest>` beneath the generation.

`integrity.toml.packages` maps those same digests to complete path-to-SHA-256
inventories, including `package.toml`. Installation always writes this inventory;
export requires it and checks captured bytes against it.

After completing the generation, install atomically replaces
`.beam/current-<sdk-build-id>.toml`. Its `generation` is a single safe directory
name beneath `.beam/environments/`. Failed publication removes the unpublished
generation and temporary pointer, preserving earlier selections and successful
generations. Successful generations are retained and treated as immutable.
There is no `current.toml` discovery or missing-SDK default.

Launch validates records, bytecode identities, dependency edges, provider conflicts,
host requirements and native SDK compatibility. It trusts installed files locally
without rehashing them. Neither sources, source manifests, locks nor archive stores
are needed in deployment; launch writes none of them. Library roots without entry
metadata can be used in project shell.

A temporary tool VM prepares bytecode and explicit native bindings, then terminates.
A fresh execution VM receives the selected composition, core/base code and private
standard I/O support. Shell additionally selects its interactive inventory. Files,
sockets, programs, zlib, implicit acquisition and OTP application startup are absent.
Missing host modules, provider collisions and nonempty OTP application requirements
fail before execution. Deployment uses a copied installed project and an explicitly
selected matching distribution prefix.

## Application exports

Export reads an installed selection and its integrity inventory, without source
resolution, rebuilding or package execution. Complete generations live beneath
`.generations/`. Unix selects one with a relative `current` symlink; Windows uses
a regular `current.cmake` selector. Publication uses one atomic rename after
validation; failure preserves the previous selection and removes unpublished data.

Each generation contains `export.toml`, files beneath `packages/<archive-digest>`,
`registration.c/.h`, `package_inventory.c/.h` and `package.cmake`.
The inventory header declares `beam_package_inventory` with C/C++ linkage; its
implementation owns the private record definitions. `BEAMPackageInputs` supplies
both generated C implementations to the host. Apple selections
also produce `package.xcconfig`. `export.toml.packages` maps each archive digest to
`metadata` (its complete package record), `path` (its relative export location)
and `files` (path-to-digest inventory, excluding separately captured metadata).
The top-level record pins SDK, compiler generation and root identity.

`BEAMPackageExport.cmake` is the stable entry. Generated CMake verifies file hashes
and target SDK identity, exposes `BEAMPackageInputs`, `BEAM_PACKAGE_ASSETS` and
`BEAM_PACKAGE_NATIVE_TARGETS`, and imports native link inputs. Registration accessors
select only explicitly bound NIFs. Android also receives shared-NIF module/library
name arrays; the host resolves them against explicitly selected images.

Copy the complete export directory for relocation. CMake resolves its generation
at configuration time; reconfigure to adopt a new selection. Apple configuration
uses the consumer's `BEAM_PACKAGE_EXPORT` path. No producer build/source paths
are retained. SDK framework deployment, signing and final application assembly
remain outside package export.

Android build/export inspect native primary artifacts with the selected NDK's
host `llvm-readelf`. Shared libraries require the selected ABI, 16 KB load
alignment, a basename SONAME and a complete supported ELF dependency closure.
Unsupported search paths, dependencies or conflicting names fail before publication.

## Limits and deferred work

| Boundary | Limit |
| --- | --- |
| Each TOML record, read or generated | 4 MiB after serialization/escaping |
| Each archive, compressed and expanded | 256 MiB each; expanded size includes headers, padding and terminator |
| Each archive | 10,000 tar entries |
| Package dependency graph | 128 levels; 1,024 selected packages |
| Lock | 1,024 SDK selections |
| Native dependency graph | 128 artifact levels; node/file inventory and metadata size also apply |
| Installed preparation, complete closure | 1,024 packages; 10,000 filesystem entries; 256 MiB file contents; 4,096 modules; 1,024 native bindings |

These boundaries count different representations. Tar limits apply per archive;
installed preparation counts files and directories across the selected closure.
A valid archive does not guarantee an arbitrarily large closure can be launched.
Writers reject oversized output before publishing its lock or selection.

Registry access, version solving, whole-application recipes, build-time plugins,
OTP project startup and independent native release compatibility remain deferred.
The Erlangsters framework's complete STDLIB dependency overlaps BEAM-host providers;
removing modules or declaring subsets is not a workaround. Dependency-tree display
remains a command stub. No format change makes those deferred compositions runnable.
