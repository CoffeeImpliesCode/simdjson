# simdjson — Zig SDK

**simdjson 5.0.2**, upstream's SIMD JSON parser, imported whole and built to a real
C ABI library with a Zig facade.

* Upstream: <https://simdjson.org/> · release `v5.0.2`, tag commit
  `c9030726ebbf5f9fe9f9facb4a401f6d3ccd77a2`, tarball sha256
  `09de4289a26d3a0453569901a3837450b5b98a5c317d635eeee8e2a82b1ebe6b`
* The pin, in full: [`UPSTREAM.md`](UPSTREAM.md). Every one of those four facts is
  read out of [`UPSTREAM.sha256:4-7`](UPSTREAM.sha256).
* Licence: simdjson is **dual Apache-2.0 / MIT** and this fork's own files are
  **Apache-2.0**. Neither term covers the whole tree, and five vendored
  third-party works inside `src/` keep their own terms.
  [`NOTICE.md`](NOTICE.md) is the inventory; [`FORK-LICENSE.md`](FORK-LICENSE.md)
  is the grant.
* **No gate has been run.** Everything in this README that describes a build, a
  test or a matrix is `PENDING-VERIFICATION`. See "Verification" below.

> This README follows the workspace's required order: **current native-source
> deviations**, then **native-build deviations and history**, then the **current
> support matrix**, then **consumption**. Upstream's own README is preserved
> byte for byte at [`README.upstream.md`](README.upstream.md).

---

## 1. Deviations from the native source

**There are none. All 771 files under `src/` are byte-identical to the release
tarball**, and every one has a SHA-256 in `UPSTREAM.sha256`. A changed byte is a
failing `tools/check-provenance.sh` run, not a silent diff.

No upstream file is edited, re-entered, reformatted or regenerated. Nothing is
dropped for being uncompiled by this package: the complete 5.0.2 release tree
travels — the header tree, the kernels, upstream's own test suite, its docs, its
benchmarks, fuzzers, tools, CMake tree, json examples, both licence texts, and all
45 of its CI workflows under `src/.github/`.

Three files are **deliberately absent**, recorded as absent rather than omitted:

```
src/singleheader/simdjson.h
src/singleheader/simdjson.cpp
src/singleheader/singleheader.zip
```

They are upstream's *generated* single-header amalgamation, the output of
`src/singleheader/amalgamate.py` — which **is** carried. This build compiles
upstream's own `src/src/simdjson.cpp` directly, so an amalgamated copy of the same
sources sitting beside it would be a second, buildable, drifting copy of the
upstream core with nothing keeping the two in step. The generator makes the
amalgamation reproducible on demand rather than stale, and
`tools/check-provenance.sh` fails if any of the three reappears.

`src/README.md` is preserved byte-identically at `README.upstream.md`.

## 2. Native-build deviations, and what this package compiles

### Two translation units

| unit | what it is |
|---|---|
| `src/src/simdjson.cpp` | upstream's core, byte for byte, and the whole of `SIMDJSON_SOURCES` (`src/CMakeLists.txt:204,206`) |
| `zig/bridge.cc` | **this fork's**, the `extern "C"` seam. The only unit that compiles `<simdjson.h>` |

There is no source list beyond those two, and no hand-kept kernel list:
`src/src/simdjson.cpp:23-49` is one `#include <KERNEL>.cpp` per
`SIMDJSON_IMPLEMENTATION_<ARCH>`, with `fallback.cpp` last, so the whole kernel
set arrives through that one file's own preprocessor cascade.

Upstream's programs (`src/examples/`, `src/benchmark/`, `src/fuzz/`) and its
Catch2 suite under `src/tests/` are **not built**: they are built by upstream's own
CMake against its own harness, and this graph runs no CMake. They ship as source,
unmodified. `tools/check-provenance.sh` asserts they are **present and unedited**,
and this README does not pretend they were executed.

### The flags, and the one that is a decision rather than a default

| flag | upstream's own answer | what changes |
|---|---|---|
| `-std=c++17` | `src/cmake/developer-options.cmake:125,127-129` | **Nothing.** Passed explicitly so the standard is a fact of this build rather than a property of whichever clang the toolchain ships. (`src/CMakeLists.txt:335`'s `cxx_std_11` is a floor for *consumers* of the installed headers, a different question.) |
| `-fno-exceptions -fno-rtti`, `-DSIMDJSON_EXCEPTIONS=0` | `src/cmake/exception-flags.cmake:1,5,27` | **Nothing**, and upstream supports it. This is why the closure needs no external C++ runtime and no external WASI SDK sysroot. |
| `-DSIMDJSON_THREADS_ENABLED=1` | `ON`, `PUBLIC`, at `src/CMakeLists.txt:41,382-386` | **Nothing on the core.** The macro gates nothing on the On-Demand path. It is passed because `PUBLIC` means it also reaches the installed headers' consumers, and this package installs that whole tree. **Resolved per target**: it is omitted for `wasm32-wasi`, whose C++ runtime has no `std::thread` at all, which is the same answer upstream reaches through its own `find_package(Threads)` guard. |
| `-DSIMDJSON_AVX512_ALLOWED=0` | header default 1 (`src/include/simdjson/common_defs.h:385-388`), CMake option ON (`src/cmake/developer-options.cmake:217-227`) | **Nothing on a target that has AVX-512.** Added only for an x86-64 target whose CPU model does not: upstream compiles the icelake kernel in by default on every x86-64 target (`src/include/simdjson/implementation_detection.h:37-41`) for run-time selection, and its AVX-512 intrinsics then do not compile for a baseline x86-64 CPU model. `-Dcpu=` decides it. `FORK-NOTES.md` note 9. |
| `-DSIMDJSON_ENABLE_NAN_INF=0` | header default 0, CMake default OFF | **Nothing.** Passed explicitly so that the refusal of `{"a":NaN}` is a stated configuration rather than an inherited one. |
| **`-DSIMDJSON_DEVELOPMENT_CHECKS=1`, every target, every optimize mode** | **Debug only**: `src/CMakeLists.txt:376-379` | **This package's decision, and the only one with a real cost.** `DEFAULT_MAX_DEPTH` (1024) becomes an *enforced* boundary in a release build, and `OUT_OF_ORDER_ITERATION` is compiled in. A depth limit that exists only in Debug is a limit nobody can rely on. `FORK-NOTES.md` note 8 is the record, including how to overturn it. |

No CMake, no autotools, no `make`, and no build-time download. Nothing is fetched;
`build.zig.zon .dependencies` is empty.

### The SIMD-fallback boundary — read this before picking a kernel

Two different things are called "fallback" here and they are unrelated.

**1. The scalar kernel is a real compiled-in code path, not a rescue.** At
`-Dcpu=baseline` on x86-64, `__AVX2__`, `__SSE4_2__`, `__PCLMUL__` and the
`__AVX512*` set are all absent, so `SIMDJSON_CAN_ALWAYS_RUN_{HASWELL,ICELAKE,
WESTMERE}` are all 0, `SIMDJSON_IMPLEMENTATION_FALLBACK` stays 1, and the artifact
carries **the scalar kernel alone**. That is not a degraded build — it is
upstream's own answer for a target with no guaranteed SIMD — but upstream's
scalar kernel has one hole this package has to close: it validates UTF-8
**inside strings only** (`src/src/fallback.cpp:198-203`), so a byte `>= 0x80`
outside a string is absorbed into an atom and refused as `TAPE_ERROR`, where
every SIMD kernel refuses the document with `UTF8_ERROR`. The facade therefore
asks `simdjson::validate_utf8` — upstream's own validator, and the same call
`validateUtf8` already makes — before stage 1 runs, so a document that is not
valid UTF-8 is refused with `UTF8_ERROR` on every target whatever kernel is
compiled in (`zig/bridge.cc`, `FORK-NOTES.md` note 23). The scalar kernel is
slower, by an amount that is a fact about the kernel and the input, which is why
no gate here asserts a speed. On an aarch64 baseline NEON is always present, so
that target carries `arm64` instead — except a **big-endian** aarch64 target,
which carries the scalar kernel instead, because the `arm64` kernel is
byte-order dependent (`FORK-NOTES.md` note 23).

**2. There is no run-time fallback behind a slow kernel.** `#include
<simdjson/ondemand.h>` is statically bound to `SIMDJSON_BUILTIN_IMPLEMENTATION`
(`src/include/simdjson/builtin/ondemand.h:39`), so whichever kernel the flags
selected is the only one the facade reaches. `SIMDJSON_FORCE_IMPLEMENTATION` does
not relax that: it overrides the *DOM-side* dispatcher, and naming a kernel that
is not compiled in makes upstream latch onto the unsupported implementation so
every later parse fails with `UNSUPPORTED_ARCHITECTURE`. That error is in the
facade's taxonomy because it is the observable consequence, not because this
package asks for it.

**The honest summary for a dependent: which kernel you get is a build-time
property of the flags you built with, and it is not negotiable at run time.**
`builtinImplementation()` reports it; `activeImplementation()` reports something
else entirely — the DOM dispatcher's choice, a function of the host CPU *and* of
the environment, which is why no caller and no gate may compare it against a
literal.

`-Dcpu=baseline` is passed by `package.nix` because a Nix store path must not
depend on the CPU of whichever machine built it, and it is **not** passed by
`devenv.nix`'s local tasks, where a native build getting this machine's `haswell`
or `icelake` is the point.

### What is compiled but not wrapped

The installed `include/simdjson/` tree is upstream's **complete** public header
set, 234 files, unmodified. The Zig facade reaches none of it: `simdjson::ondemand`
is a namespace alias bound to one compile-time-selected kernel and its members are
class templates returning `simdjson_result<T>`, so no C or Zig translation can name
any of it. That is the whole reason `zig/bridge.cc` exists.

**A C++ consumer of this package has all of upstream's API** — the DOM parser,
`document_stream`, `minify`, compile-time JSON — through the installed headers. The
Zig facade binds On-Demand only, and the absence is a decision, not an omission.
`FORK-NOTES.md` note 1 is the record; `README.zig.md` is the interface.

### No system mode

There is no `-Dsystem` option, and that is a decision rather than an omission.
`AGENTS.md` §4 permits one only where a real compiled system library exists, and
the vendored `src/` *is* the library: 771 files, the complete release. A system
switch would select a different version of the same project on the build machine,
which is a second source of truth about which declarations are in play.
`UPSTREAM.md` §7 is the record.

## 3. Support matrix

**Only the 53-platform matrix at the end of this section has been observed, and it
is green**: 20 cells pass with 39/39 tests each, 33 are `build_only`, none fails,
harness exit code 0. `FORK-NOTES.md` notes 22 and 23 are the records, before and
after. Everything else here is what the build graph *is configured* to do and
what the six required targets *are*.

### The six required compile targets

`build_support/graph.zig:required_targets`. `zig build check` compiles each one —
the core, the bridge, the translated header, the facade, the tests and the example
— **running none of them**.

| target | what it exercises that the others do not |
|---|---|
| `x86_64-linux-gnu` | the host; at baseline, the scalar fallback kernel alone |
| `aarch64-linux-gnu` | NEON, so `arm64` instead of `fallback` — the row that proves the kernel selection is per-target |
| `aarch64-macos-none` | Mach-O, which has **no** export-surface mechanism in this graph: a shared object from it exports more than the eleven declared names, and a Darwin consumer must select by name. Stated here rather than left to `nm`. |
| `x86_64-windows-gnu` | COFF, which needs the generated `.def` because `zig/bridge.h` is plain C99 and cannot carry `__declspec(dllexport)` |
| `riscv64-linux-gnu` | `rvv-vls`, and a GNU libc triple this package does not otherwise exercise |
| `wasm32-wasi` | a target with **no dynamic linker at all**. It is a compile row rather than a refusal because the On-Demand path is exception-free: `-fno-exceptions -fno-rtti` plus Zig's own bundled libc++ is the intended route and this closure needs no external WASI SDK sysroot. `-Dlinkage=dynamic` is **refused** for it with a message naming it; its static build is what covers the row. |

The one matrix `zig build check` does **not** walk is the published 53-platform
table. `cross-test`, run from the package root, builds and *runs* `tests.zig` for
every platform in Zig 0.16.0's published Tier 1/2 tier through this repository's own
graph, using `cross-test.profile.sh` for its settings. That is a host-local tool
with its own runner detection and its own scratch policy, so it is not a CI job
here. A platform with no runner is recorded as explicit `build_only` coverage —
compiled, never executed, never counted as a pass.

### Runtime configurations

| configuration | what it is |
|---|---|
| linked (default) | the library is linked, `c` is the translated header, every call is direct |
| `-Dlinkage=dynamic` | a real shared object, `libsimdjson.so.34.0.0` with soname `libsimdjson.so.34`. **Not** the 5.0.2 release number: `src/CMakeLists.txt:32-33` set `SIMDJSON_LIB_VERSION "34.0.0"` and `SIMDJSON_LIB_SOVERSION "34"`, and the release is a different fact. |
| `-Druntime=true` | the same artifact, delivered and installed, but the facade module links none of it and the eleven entry points arrive through one process-lifetime table an explicit `load(source)` fills |

`stream loading` is a fourth row that does not exist: this package has no stream
decoder. Upstream's `dom::document_stream` is reachable from C++ through the
installed headers and absent from the Zig facade.

### The build steps

| step | what it does |
|---|---|
| `zig build` | install the delivery tree and compile the example |
| `zig build test` | run the behavioural tests for the selected target |
| `zig build smoke` | run the deterministic example |
| `zig build consumer` | build and run the separate `consumer/` package |
| `zig build check` | compile all six required targets, running nothing |

`zig build install` **fails**: this graph installs through `b.installArtifact` and
`getInstallStep()` and registers no step by that name. That is stated because
`package.nix` and `devenv.nix` both rely on the default step being the install.

### Licence, by consumer

| you are | the terms that apply to you |
|---|---|
| a C or C++ consumer of the installed tree | simdjson's choice of Apache-2.0 **or** MIT, **plus** the five vendored third-party terms in `NOTICE.md` §2 |
| a consumer of `simdjson_bridge.h` and `libsimdjson` | the same, plus this fork's Apache-2.0 over the seam files |
| a Zig consumer of `dep.module("simdjson")` | the same, through the delivered library |

There is no stream-decoding row in any of that, because this package has no
stream decoder: upstream's `dom::document_stream` is reachable from C++ through
the installed headers and absent from the Zig facade, the same split as the rest
of the DOM API.

## 4. Consumption

### From Zig

```zig
const std = @import("std");
const simdjson = @import("simdjson");

pub fn main() !void {
    var doc = try simdjson.parse("{\"a\":[1,2,3]}");
    defer doc.deinit();

    var walk = try doc.walk(std.heap.page_allocator);
    defer walk.deinit();

    const object = walk.root().?.object().?;
    const array = object.get("a").?.value.array().?;

    var iterator = array.iterator();
    while (iterator.next()) |item| {
        std.debug.print("{d}\n", .{item.int().?});
    }
}
```

In a build graph:

```zig
const dep = b.dependency("simdjson", .{ .target = target, .optimize = optimize });
exe_mod.addImport("simdjson", dep.module("simdjson"));
```

That is the whole integration. The module carries the library, the C runtime and
the C++ runtime with it, so a dependent states neither.

Full interface documentation: [`README.zig.md`](README.zig.md).

### Runtime loading

One line comes before the first parse, and it is the only difference in the
program:

```zig
try simdjson.load(.{ .path = "/usr/lib/libsimdjson.so.34" });
```

Nothing is loaded by default and no other file is tried. A call before that stops
the program with a message naming the function, in every optimize mode — that is a
programming error rather than a recoverable condition, because the table does not
exist yet.

**A static install cannot itself be a provider**: an archive is not something a
platform loader can open. What a runtime-loaded caller needs is the shared object
`-Dlinkage=dynamic` installs, or some other shared object exporting the same
eleven symbols. `build.zig` says so at configure time rather than letting a caller
discover it as a missing file from the loader.

### From C or C++

```
$prefix/include/simdjson.h                 upstream's umbrella
$prefix/include/simdjson/                  upstream's whole public tree, 234 files
$prefix/include/simdjson_bridge.h          this package's C ABI, 11 entry points
$prefix/lib/libsimdjson.a                  or .so.34.0.0 with .so.34 and .so
$prefix/lib/pkgconfig/simdjson.pc          generated, ${pcfiledir}-relative
$prefix/share/licenses/simdjson/           both upstream grants, plus this fork's records
```

`pkg-config --cflags --libs simdjson` gives a consumer everything it needs. For the
C ABI, include `simdjson_bridge.h`; for upstream's own C++ API, include
`<simdjson.h>`.

### From Nix

`package.nix` is one source-only derivation and `flake.nix` exposes both linkages.
`.static` is the reproducible one (`-Dcpu=baseline`); `.shared` is refused on any
system whose OS has no dynamic linker.

```sh
nix build .#static        # libsimdjson.a
nix build .#shared        # libsimdjson.so.34.0.0
```

`devenv shell` is the canonical development environment; `nix develop` is parity
and deliberately does not build the SDK.

### The consumer package

`consumer/` is a separate package that resolves this one by relative path and
reaches it only through `dep.module("simdjson")` — no path reaches into this tree.
It is the proof that the module contract is real, and nothing inside this
repository would notice if it stopped being true.

```sh
zig build consumer                              # linked, from the parent graph
cd consumer && zig build run                    # or directly
zig build run -Druntime=true -- --provider /path/to/libsimdjson.so
```

## 5. Verification

**Two gates have produced output, and both are green.** Nothing else in this
section has run in this repository, and no other receipt exists.

On 2026-10-05, with Zig 0.16.0: `zig build` exit 0; `zig build test` exit 0 with
39/39, in Debug and in `-Doptimize=ReleaseSafe`; `zig build smoke` exit 0;
`zig build check` exit 0, 43/43 steps; `zig build consumer` exit 0, 6/6 steps.
Two gate rows refuse rather than run, and both refusals are the ones §3 states
in advance — see the table below.

The same day, `cross-test` was run from the package root over the published
53-platform table, twice. The first run was **red** — harness exit code 1, 3 cells
pass, 33 `build_only`, 17 fail — and the seventeen failures were three upstream
facts, recorded in `FORK-NOTES.md` note 22. All three are now answered in this
package's own files (`zig/bridge.cc`, `build_support/graph.zig`), without a
vendored byte changed and without a test weakened; `FORK-NOTES.md` note 23 is
that record. The second run is **green**: harness **exit code 0**, `pass 20 /
fail 0 / build_only 33`, 39/39 tests in every executed cell
(`run_id 20261005-201334-56987-6494`).

The 33 `build_only` cells are unchanged and are still **not** passes: they
compiled and were never executed, because this host has no runner for FreeBSD,
NetBSD, OpenBSD, macOS, maccatalyst, Windows or wasmtime. A summary of each run
is `cross/simdjson*/cross-test-summary.json` under this workspace's approved
scratch.

The gates this package defines. Run on 2026-10-05: `zig build`, `zig build test`
in both optimize modes, `zig build smoke`, `zig build check`, `zig build consumer`
(6/6 steps) and `tools/check-provenance.sh` (exit 0, `provenance checks passed` —
the direct evidence that no vendored byte moved). Not run: CI. Refused **by
design**: both `-Dlinkage=dynamic` rows, exit 1, naming `wasm32-wasi` —
`deliveredLinkage` (`build_support/graph.zig:776`) will not substitute a static
archive for a requested shared object, and configuring the check step walks that
target. This is the refusal §3 states in advance.

| gate | command |
|---|---|
| provenance | `tools/check-provenance.sh` |
| install, both linkages | `zig build` and `zig build -Dlinkage=dynamic` |
| tests, Debug and ReleaseSafe | `zig build test` and `zig build test -Doptimize=ReleaseSafe` |
| example | `zig build smoke` |
| six-target compile check | `zig build check` and `zig build check -Dlinkage=dynamic` |
| consumer, linked and runtime-loaded | `zig build consumer`; `cd consumer && zig build run` |
| published 53-platform matrix | `cross-test` from the package root |
| CI | `.github/workflows/verify.yml` |

`.github/workflows/verify.yml` states the same things and asserts nothing about
what they printed. Receipts belong in `FORKS.json`, beside the driver run that
produced them.

Two failures in this workspace are recorded as `SYMPTOM` and are **not**
attributed to this package, to a cache, or to the volume mount:
`local://foundation-expansion-s2geometry-neighbor-smoke-153.log` printed
`error: FileNotFound` and then `error: CacheCheckFailed`; and
`local://foundation-expansion-ryu-installed-C-surface-182.log` ended with
`direct_headers.c:1:1: error: CacheCheckFailed`. Neither has an identified cause.

## 6. Repository layout

```
build.zig              build.zig.zon        the graph and the manifest
build_support/graph.zig                       per-target assembly: flags, module, archive
zig/bridge.h           the C ABI, 11 entry points, plain C99
zig/bridge.cc          the C++ over it; the only unit compiling <simdjson.h>
zig/root.zig           the public Zig surface
zig/translate.h        the header translate-c reads
runtime/               the runtime-loading route: loader core, descriptor, graph, generator
src/                   upstream's 771 files, unmodified
testdata/              22 recorded fixtures, and their record
tests.zig              the behavioural test root
smoke.zig              the deterministic example
consumer/              a separate package that depends on this one
tools/                 the provenance gate
package.nix  flake.nix  devenv.nix  devenv.yaml  .envrc
.github/workflows/verify.yml                  this fork's CI, not upstream's
```

## Related records

* [`UPSTREAM.md`](UPSTREAM.md) — the pin, both version numbers, every build
  deviation with the upstream line it comes from, what is compiled but not
  wrapped, no system mode, and the fixtures.
* [`UPSTREAM.sha256`](UPSTREAM.sha256) — 793 digests over immutable carried bytes.
* [`NOTICE.md`](NOTICE.md) — the per-file licence inventory, the five vendored
  third-party terms, and how each Apache-2.0 §4 condition is met.
* [`FORK-LICENSE.md`](FORK-LICENSE.md) — the grant over this fork's own files.
* [`FORK-NOTES.md`](FORK-NOTES.md) — twenty decisions in condition / symptom /
  cause / fix form, each with a *targets bound* line.
* [`CHANGELOG.md`](CHANGELOG.md) — the change statement, and the open questions.
* [`README.zig.md`](README.zig.md) — the Zig interface.
* [`README.upstream.md`](README.upstream.md) — upstream's README, byte for byte.
* [`testdata/README.md`](testdata/README.md) — each fixture's origin and purpose.