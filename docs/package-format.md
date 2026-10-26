# BEAM package formats

## Status and supported inputs

This format is experimental and revisable. New archives use metadata format 3; source manifests accept formats 1/2 and locks/installed environments remain format 2. Valid format-1/2 archives remain readable without rewriting their bytes. Format-1 locks describe
one selection; matching native SDK checks still apply. Ambiguous or unsupported
older records require an explicit rebuild/install. `beam build` (also `beam-pkg build`)
builds ordinary libraries, local execution-dependency graphs and CMake native
outputs into archives and locks. `beam-pkg install` materializes the locked selection;
`beam run --project` executes it on BEAM. Dependency-tree display remains a stub. See [commands](commands.md).

The separate OTP distribution will assemble its own environment around
`libbeam`; this experimental format is not its required delivery mechanism.
See the [runtime strategy](../../beam-erlang/docs/runtime-evolution-strategy.md).
Existing OTP package drafts each describe one complete application.
Kernel/STDLIB package build recipes and the overlap between STDLIB and BEAM-owned
modules remain unresolved. Those recipes are not prerequisites for the OTP
distribution milestone. The draft manifests and the
[counter consumers](../../beam-erlang/docs/framework-consumers.md) are not
currently buildable compositions. Never replace a complete OTP application with
selected-module packages to bypass this boundary.

## Source manifests

`beam.toml` uses a documented subset of TOML 1.0: tables and dotted table paths,
bare/quoted keys, basic/literal single-line strings, escapes, signed decimal
64-bit integers, booleans, arrays and inline tables. Comments and multiline
arrays are supported. Dates, floats, multiline strings, nondecimal integers and
arrays of tables are unsupported. Unsupported syntax, unknown schema fields and
duplicate definitions fail. This is not a general TOML parser.

```toml
format = 2
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
[build-dependencies]
[host]
modules = ["erlang"]
```

Paths resolve relative to the manifest. Source inventories are explicit files;
there is no globbing or implicit acquisition. Compilation uses the selected
installed `beam compile --deterministic --no-transforms`.
Runtime dependency headers are made available through explicit include paths.
Behavior-module inputs and compiler plugins are deferred: nonempty
`build-dependencies` and source-declared parse/core transforms fail.

`dependencies` describes execution edges. `build-dependencies` reserves the
separate build-time graph. `host.modules` and optional `host.applications`
(name-to-exact-version table) describe supplied execution requirements; they
neither download packages nor start applications. Building a library does not
run its code. Compiler-private modules are not execution providers.

Package versions are exact identities, without range solving. Each dependency
has exactly one `path` or `archive`. Archive inputs may name a companion lock:

```toml
[dependencies]
"example/math" = { version = "1.0.0", archive = "../artifacts/math.bpkg.tar.gz", lock = "../producer/beam.lock" }
```

An archive with dependencies requires an explicit companion lock. Its selected
record and transitive edges must agree with portable metadata; archive locations
resolve relative to the supplied lock. Only the selected closure is imported.
Every archive digest is verified. Missing inputs, cycles, conflicting versions,
artifact selections or source locations fail without cache scanning, source
fallback or network acquisition. The initial graph limits are 128 dependency
levels and 1,024 selected packages.

A library can supply a resolved application resource and optional entry:

```toml
[application]
file = "resources/math.app"
[entry]
module = "math_main"
```

The `.app` is copied unchanged to `ebin/`. Entry modules must belong to the
package; launching additionally requires that module to export `main/1`. Ordinary Erlangsters libraries
remain ordinary module packages unless they explicitly supply application
metadata. Imported `.app.src` files do not create startup requirements.

Whole OTP application drafts retain their separate, currently unsupported form:

```toml
format = 2
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

This describes the complete application's modules, headers, resources and
metadata, including its future generators and resolved `.app`. It is not an
instruction to compile a directory scan. Installation does not start applications.

## Native recipe

```toml
[build.native]
cmake = "."
outputs = ["glm"]
nifs = { glm_raw = "glm" }
```

A format-2 native output can be a logical name or an explicit `priv/` path.
A recipe declares a logical output with
`beam_package_native_output(target NAME logical_name)`. The SDK helper installs
the target under `priv/` and records its actual filename in build-local metadata;
it does not guess a platform suffix. Portable native metadata retains the
logical-to-installed-path `identities` map and concrete output/NIF paths.

One package-owned CMake recipe installs exactly the declared files under `priv/`
in a private staging prefix. The builder supplies the selected SDK through
`CMAKE_PREFIX_PATH`, uses Release configuration and out-of-source build output,
and disables CMake package-registry lookup and FetchContent acquisition.
Recipes are trusted code, not sandboxed; they must use explicit offline inputs.
GLM vendors upstream headers and uses the installed `beam_target_nif(target)`
CMake helper. The helper links the interface-only `BEAM::NIF` target and embeds a
matching-build SDK descriptor without an absolute runtime-link path.

Native builds support matching host Linux and Darwin interpreter and JIT prefixes,
and explicit iOS device/simulator or Android ABI/flavor targets using the target SDK’s installed
consumer toolchain. The executing SDK supplies the attested Erlang compiler. Native metadata records output paths, the `cmake`
recipe kind and matching SDK provenance (distribution identity, source/config
build ID, OS, architecture, triple and flavor). Native archive dependencies must
match the selected SDK. This conservative rule is not a stable ABI promise.
System C/C++ runtime dependencies are not bundled into these archives.

The optional `nifs` table maps supplied package modules to declared native outputs,
with one module per library. It is retained in portable metadata and validated
again when consuming archives. Outputs without bindings are never implicitly
activated. Build does not execute native code. Dynamic runtime preparation maps explicitly
selected libraries and compares their embedded SDK descriptor. Static package
NIFs instead supply generated resident linked-NIF selections; activation validates
actual module identity, ABI and function tables before publishing NIFs. Load
information is initially `undefined`. Native libraries and recipes are trusted
code; mapping may execute platform constructors. Arbitrary `on_load`, implicit
native loading, rebinding and hot upgrades remain unsupported.

GLM is an ordinary OTP-free library with an explicit `glm_raw` binding. It needs
neither application metadata nor OTP resource lookup. Generic optional `.app`
metadata remains available for packages representing OTP applications.

## Archives, locks and publication

A `.bpkg.tar.gz` contains generated `package.toml`, compiled `ebin/`, optional
`include/` and `priv/`, and `licenses/`. Exported source resources use their
basenames within the corresponding directory; collisions fail. Local source
and acquisition paths never enter portable metadata.

Metadata records format, identity, module inventory, exact dependency digest
edges, exports, host requirements and optional application/entry/native fields.
Compiler SDK provenance is included. Archive module names are checked against
bytecode without loading it. All files must agree with the metadata inventory.
Package names do not namespace Erlang modules: duplicate package providers and
collisions with declared host modules fail. Project launch additionally checks the
prospective host inventory and rejects missing host modules, collisions with host
providers and nonempty OTP application requirements.

The archive encoding is gzip plus POSIX ustar, using regular files and directories.
Readers reject links, special entries, unsupported extensions, unsafe paths,
duplicate or conflicting destinations, bad checksums, truncation and invalid
inventories. Limits are 256 MiB compressed/expanded input and 10,000 tar entries;
paths must fit ustar fields. TOML records are bounded to 4 MiB.

SHA-256 identifies the complete archive bytes. The builder uses CMake's SHA-256
command and stores archives as `build/beam-pkg/artifacts/<digest>.bpkg.tar.gz`.
An explicit rebuild can select different bytes for the same name/version.
Consumed archives are copied into that same local artifact store.

`beam.lock` is generated TOML with `format = 2` and a `selections` table.
Each key is `OS/architecture/flavor/build-id` from the exact selected SDK. Its
record contains that `sdk`, a `root` digest and an `artifacts` table keyed by
actual digests. A successful build replaces only its matching selection and
preserves other validated target selections. Installation and companion-lock
acquisition require the selected SDK's exact key; they never choose another
flavor or target implicitly. Each record contains `name`, `version`, a local
`archive` locator and exact `dependencies` edges. Locators are relative to the
lock. No placeholder hashes or fake generated files are part of the format.

Staging directories are removed after success or failure. An OS cleanup failure
is diagnosed without changing a successfully published selection into a failure.
Archives are published before the root lock is atomically replaced. Failed builds preserve the prior
selection; unselected archives may remain. Concurrent publication to the same
project is not a supported workflow. Native recipes may have their own effects;
the package tool does not claim to sandbox them.

## Installed environments and execution

```text
source manifests -> archives + beam.lock -> project-local .beam/ -> execution
```

Installation reads only the lock and its selected archive closure, verifies every
hash and edge, and extracts compiled packages into a private generation. Package
locations are `packages/<archive-digest>` beneath that generation. A generated
`environment.toml` contains `format = 2`, the selected `sdk`, the root digest and a `packages` table
mapping each selected digest to its relative location. After publishing the complete
generation, installation atomically replaces `.beam/current-<sdk-build-id>.toml`, containing
`format = 2` and its `generation` directory name. No illustrative fake hashes or
pre-generated selections are supplied. A missing target pointer may read an
unambiguous legacy format-1 `current.toml`; a format-2 record at that legacy
location is rejected. Native contents must still match the selected SDK.

Successful generations are retained and treated as immutable. Failure removes
staging without changing the old selection or lock. Concurrent publication into
one project is unsupported. Launch validates selection structure, module identities,
dependency edges, providers and native compatibility. It trusts installed files
locally, without rehashing every file. Preparation is bounded to 1,024 packages,
10,000 filesystem entries, 256 MiB of selected file contents, 4,096 modules and
1,024 native bindings. No source manifest, source tree, lock or archive store is
needed in a deployed project. Launch writes none of them.

A temporary package-tool VM prepares copied bytecode, exact origins and explicit
native bindings. A fresh execution VM receives only the selected composition,
core/base code and private standard I/O support. Native admission belongs to its
public composition lifecycle. Files, sockets, external programs, zlib, implicit
code acquisition and OTP application startup are outside this initial profile.
Deployment is a copied installed project using an explicitly selected matching
distribution prefix, not a bundled executable/runtime.

The Erlangsters framework drafts still depend on complete STDLIB, whose modules
overlap with the current BEAM host; STDLIB retains its Kernel dependency. The OTP
counter draft records retained Kernel/STDLIB requirements; the future OTP
consumer targets the separate distribution. Neither draft becomes runnable through
this workflow. Registry access, version solving, whole-application recipes,
build-time plugins, OTP project launching and independent native release
compatibility remain deferred. Historical format candidates remain unchanged.

## Source-only development tasks

An optional `[scripts]` table maps task names to literal argument arrays:

```toml
[scripts]
shell = ["beam", "shell", "--project", "."]
demo = ["beam", "run", "--project", ".", "--"]
```

Build validates these declarations but never executes them or publishes them in
metadata, locks or environments. `beam task` reads only the root source manifest;
it does not require supported build recipes or existing source inputs. See
[command policy and limits](commands.md#development-tasks). Installed shell uses
the selected closure without requiring root entry metadata; it does not read scripts.

## Archive metadata format 3

The compiler record describes the actual executing host SDK, independently of
the destination. `compiler-generation` is the SHA-256 identity of the attested
compiler seed manifest. Build/install compare it with the selected target's
verified generation. Native metadata keeps its exact destination `sdk`. Old
archives lacking cross-target compiler evidence require rebuilding; immutable
older archives and other lock selections are preserved.

`native.artifacts` maps logical output names to structured records:

| Field | Meaning |
| --- | --- |
| `kind` | `static` or `shared`, supported by the target SDK. |
| `path` | Primary installed artifact, relative under `priv/`. |
| `files` | Complete installed file inventory, including generated registration headers. |
| `sdk-build-id` | Exact target SDK identity. |
| `language` | `C` or `CXX`. |
| `dependencies` | Supported `output:<logical-name>`, `sdk:runtime`, `system:m`, or `system:c++` dependencies; Android additionally permits `system:android`, `system:log`, `system:dl`, and `system:c++_shared`; arbitrary flags and absolute host paths are rejected. |
| `module`, `binding`, `header` | Optional complete static linked-NIF registration selection, C accessor symbol and installed header. |

The existing `outputs`, `identities` and module-to-path `nifs` mappings remain
available and must agree with these records. Dependency closures must be complete
and acyclic. `beam_package_native_output` produces this data from declared CMake
targets. Package NIF activation remains explicit; registering a static artifact
does not change OTP built-in NIF loading semantics.

Installation writes `integrity.toml` beside the format-2 environment, with a
digest inventory of the installed files. Export verifies captured bytes against
that inventory. Existing environments without it remain usable through their
existing local workflow but must be reinstalled before export.

## Application export format 1

An export contains complete generations beneath `.generations/`. On Unix,
`current` is a relative symlink; Windows uses a regular `current.cmake` selector
so publication does not require symbolic-link privileges. Both are switched by
one atomic rename only after validation and staging.
The stable `BEAMPackageExport.cmake` entry selects it; Apple targets additionally
emit `BEAMPackageExport.xcconfig`. A failed
export preserves the previous selection. Copy the complete directory when
relocating it. CMake resolves the generation at configuration time; consumers
must reconfigure to adopt a newer selection.

Each generation contains `export.toml` (format 1), package files by archive digest,
`registration.c/.h`, `package_inventory.h`, `package.cmake`, and
Apple-only `package.xcconfig`. The inventory records exact SDK identity, compiler generation,
the selected root, package metadata and file digests. Generated registration
accessors select only declared linked NIFs. CMake verifies package file hashes
and target SDK identity, exposes `BEAMPackageInputs` and `BEAM_PACKAGE_ASSETS`,
and imports native link inputs. Xcode configuration paths use the consumer's
`BEAM_PACKAGE_EXPORT` setting. No producer source/build paths are retained.

SDK framework deployment belongs to SDK tooling. The exporter neither assembles
nor signs an application, executes target code, nor acquires source dependencies.


### Android native validation

Android supports static linked NIFs and shared native artifacts. Build and export
inspect every native primary artifact with the explicitly selected NDK host
`llvm-readelf`; neither operation executes target code. Shared libraries require
the selected ABI, 16 KB load alignment, a basename SONAME, and a complete supported
ELF dependency closure. Conflicting names, absolute/unsupported search paths and
undeclared public dependency kinds fail before lock or export publication.

CMake exports remain platform neutral. Android assembly consumes the selected
SDK and export separately, stages assets under an ABI-specific root without
merging same-named files, and packages dependencies through Gradle's native graph.
SDK AAR/Prefab generation and final APK/AAB assembly are outside package export.
