# UPSTREAM.md — the pin, and every deviation from it

Everything in this file was read out of a file in this repository. Nothing here
was executed, and nothing here is a receipt: the gates are the driver's, and their
output belongs in `FORKS.json`. Where a statement is about a *build* rather than
about a file, it is marked `PENDING-VERIFICATION`, because no compiler has run it
in this repository.

## 1. The pin

One upstream, one release, four facts.

| what | value | read out of |
|---|---|---|
| source | `simdjson/simdjson` | `UPSTREAM.sha256:4` |
| archive | `https://codeload.github.com/simdjson/simdjson/tar.gz/refs/tags/v5.0.2` | `UPSTREAM.sha256:4` |
| tag | `v5.0.2` | `UPSTREAM.sha256:5` |
| tag commit | `c9030726ebbf5f9fe9f9facb4a401f6d3ccd77a2` | `UPSTREAM.sha256:5` |
| released | 2026-10-04 (committer date of that tag) | `UPSTREAM.sha256:6` |
| tarball size | 8331647 bytes | `UPSTREAM.sha256:6` |
| tarball sha256 | `09de4289a26d3a0453569901a3837450b5b98a5c317d635eeee8e2a82b1ebe6b` | `UPSTREAM.sha256:7` |

`SOURCE-CONFIRMED` for every row: each is a line of `UPSTREAM.sha256`, and
`tools/check-provenance.sh` compares this file's digest against that file's so
the two cannot drift apart.

**The version that is not a version.** simdjson's *release* number is 5.0.2:
`src/include/simdjson/simdjson_version.h:7` is `#define SIMDJSON_VERSION
"5.0.2"`, `src/CMakeLists.txt:15` is `project(simdjson ... VERSION 5.0.2 ...)`
and `src/simdjson.pc.in:8` carries `Version: @PROJECT_VERSION@`, which that
`project(... VERSION 5.0.2 ...)` supplies. Its *ABI* number is 34:
`src/CMakeLists.txt:32-33` are `set(SIMDJSON_LIB_VERSION "34.0.0" CACHE STRING
...)` and `set(SIMDJSON_LIB_SOVERSION "34" CACHE STRING ...)`, both with the
comment at `:31` "These version numbers are modified by tools/release.py", applied
as `VERSION` and `SOVERSION` at `:253-254`.

So a shared build of this package is `libsimdjson.so.34.0.0` with soname
`libsimdjson.so.34`, and the runtime-load example throughout this package names
`.system = "libsimdjson.so.34"`. `libsimdjson.so.5.0.2` is not a thing upstream
produces and this package does not produce it either.
`std.SemanticVersion` has exactly three components where an ELF shared object has
four, so `build_support/graph.zig:abi_version` is
`{ .major = 34, .minor = 0, .patch = 0 }` and produces exactly those two names.
`FORK-NOTES.md` note 19 is the record.

There is no second ABI number to reconcile: `src/CMakeLists.txt:464-468` adds only
`-DSIMDJSON_THREADS_ENABLED=1` to the `.pc` `Cflags` and
`CMAKE_THREAD_LIBS_INIT` to `Libs.private`, so upstream writes no other number into
a soname.

## 2. What ships

**771 files under `src/`, 10317170 bytes.** That is the complete extracted
tarball tree, and every one of them has a digest in `UPSTREAM.sha256`. It
includes everything, and nothing is dropped for being uncompiled by this package:

* the whole public header tree, 234 files under `src/include/simdjson/` plus the
  umbrella `src/include/simdjson.h`;
* the compiled core: `src/src/simdjson.cpp` and every per-architecture kernel
  behind `src/src/`;
* upstream's own test suite under `src/tests/`;
* upstream's documentation, benchmarks, fuzzers, tools, CMake tree, `doc/`, and
  the json examples under `src/jsonexamples/`;
* both licence texts, `src/LICENSE` and `src/LICENSE-MIT`;
* `src/AUTHORS` and `src/CONTRIBUTORS`;
* all 45 workflows under `src/.github/workflows/`.

The whole directory travels rather than a hand-picked file list, so a dependent
receives upstream's project rather than a subset of it. `build.zig.zon .paths`
names `src`; a build that needed a file outside this closure would have to edit
upstream to get it.

`sha256sum -c UPSTREAM.sha256` from the repository root checks every one of the
771 bytes. `tools/check-provenance.sh` does that plus the file-set check that a
plain checksum run cannot see.

## 3. The generated amalgamation is deliberately not shipped

Three files of the tarball are absent, and recorded as **absent** rather than
omitted quietly:

```
src/singleheader/simdjson.h
src/singleheader/simdjson.cpp
src/singleheader/singleheader.zip
```

They are upstream's *generated* single-header amalgamation -- the output of
`src/singleheader/amalgamate.py`, which is itself carried here unmodified.

The reason is the package's whole point. This build compiles upstream's own
`src/src/simdjson.cpp` translation unit directly (`src/CMakeLists.txt:204` is
`set(SIMDJSON_SOURCES src/simdjson.cpp)`), so an amalgamated copy of the same
sources sitting beside it would be a second, buildable, drifting copy of the
upstream core with nothing keeping the two in step, and a reader would have no
way to tell which one `build.zig` compiles.

The generator is present, so the amalgamation is reproducible on demand rather
than stale. `tools/check-provenance.sh` fails if any of the three reappears, and
the header of `UPSTREAM.sha256` states the same.

## 4. What the compiled core is

Upstream's build has exactly one source file, and this package compiles exactly
the one upstream would plus one of its own.

| unit | what it is |
|---|---|
| `src/src/simdjson.cpp` | upstream's core, byte for byte, and the whole of `SIMDJSON_SOURCES` (`src/CMakeLists.txt:204,206`) |
| `zig/bridge.cc` | **this fork's**, the `extern "C"` seam. The only translation unit that compiles `<simdjson.h>` |

There is no source list beyond those two, and no hand-kept kernel list:
`src/src/simdjson.cpp:23-49` is one `#include <KERNEL>.cpp` per
`SIMDJSON_IMPLEMENTATION_<ARCH>`, with `fallback.cpp` last at `:47-49`, so the
whole kernel set arrives through that one file's own preprocessor cascade.

Two programs upstream builds (`src/examples/`, `src/benchmark/`, `src/fuzz/`)
are **not** built by this package. They are compiled by upstream's own CMake
against its own Catch2 harness, they are not part of the library this package
delivers, and building them would mean either running CMake or re-authoring
their build lines. They ship as source, unmodified, and `src/tests/` likewise.

## 5. Every build deviation, with the upstream line it comes from

Each row is a decision this package made that a reader could otherwise mistake
for upstream's default. "Upstream's default" is the *header* default or the CMake
option default; where those two agree, upstream needs no flag at all and this
package passes one anyway, which is a deviation in the weaker sense of *being
explicit*.

| what this build passes | upstream's own answer | the line | what changes |
|---|---|---|---|
| `-std=c++17` | `set(SIMDJSON_CXX_STANDARD 17 CACHE STRING ...)`, applied to `CMAKE_CXX_STANDARD` at `:127-129` only when unset | `src/cmake/developer-options.cmake:125,127-129` | Nothing. Passed explicitly so the standard is a fact of this build rather than a property of whichever clang the toolchain ships. Note that `src/CMakeLists.txt:335` propagates only `cxx_std_11` -- that is a *floor for consumers* of the installed headers, a different question, and reading it as "the library needs C++11" is wrong. |
| `-fno-exceptions -fno-rtti`, `-DSIMDJSON_EXCEPTIONS=0` | Same: `SIMDJSON_EXCEPTIONS` option at `:1`, define `PUBLIC` at `:5`, `-fno-exceptions` for GCC at `:27` | `src/cmake/exception-flags.cmake:1,5,27` | Nothing, and upstream supports it. The header agrees on its own from `__cpp_exceptions`/`_CPPUNWIND` (`src/include/simdjson/common_defs.h:53-59`), so the define is belt and braces. This is why the whole closure needs no external C++ runtime and no external WASI sysroot. |
| `-DSIMDJSON_DEVELOPMENT_CHECKS=1`, on **every target in every optimize mode** | Debug only: the option at `:146-147`, added at `:376-379` behind the comment at `:374-375` ("-Og defines __OPTIMIZE__, so the header would not auto-enable SIMDJSON_DEVELOPMENT_CHECKS in Debug. Keep the checks in Debug only") | `src/CMakeLists.txt:146-147,374-379`; `src/include/simdjson/common_defs.h:304-305` | **This package's decision, and the one with a real cost.** `DEFAULT_MAX_DEPTH` (1024, `src/include/simdjson/base.h:49`) becomes an enforced boundary in a release build, and `OUT_OF_ORDER_ITERATION` (`src/include/simdjson/error.h:46`, "checked when SIMDJSON_DEVELOPMENT_CHECKS=1") is compiled in. A depth limit that exists only in Debug is a limit nobody can rely on. `testdata/values/nesting-2048.json` is the fixture that exercises it, and `FORK-NOTES.md` note 8 is the decision record -- including how to overturn it. |
| `-DSIMDJSON_THREADS_ENABLED=1` | `ON`: `option(SIMDJSON_ENABLE_THREADS ... ON)` at `:41`, added `PUBLIC` at `:382-386`, and put in the `.pc` `Cflags` at `:464-468` | `src/CMakeLists.txt:41,382-386,464-468` | Nothing on the compiled core. The macro gates nothing on the On-Demand path and this package does not claim it does. It is passed because `PUBLIC` means the macro also reaches the *installed headers'* consumers, and this package installs upstream's whole header tree -- so a C++ consumer who links the delivered `libsimdjson` and includes `include/simdjson/` must not be handed different declarations from the ones the library was compiled with. |
| `-DSIMDJSON_ENABLE_NAN_INF=0` | Header default `0` at `common_defs.h:61-63`; CMake option default `OFF` at `:355` | `src/include/simdjson/common_defs.h:61-63`; `src/CMakeLists.txt:355` | Nothing. Passed explicitly so that the refusal of `{"a":NaN}` is this package's stated configuration rather than an inherited one that would change silently if upstream moved the default. The observable answer is `TAPE_ERROR`, not `NUMBER_ERROR`, and for a second upstream reason: `value_iterator::type` answers `json_type::unknown` for a byte that is not a token start, and the bridge dispatches on `type()` before reaching a number accessor. `FORK-NOTES.md` notes 10 and 14. |
| `-Dcpu=baseline`, in `package.nix` only | Nothing -- CMake has no equivalent, and `src/CMakeLists.txt` compiles whatever the host compiler targets | `src/include/simdjson/implementation_detection.h:31-35,46-58,75-79,101-105,137-145` | **Decides which SIMD kernels are compiled in.** At baseline on x86-64, `__AVX2__`, `__SSE4_2__`, `__PCLMUL__` and the `__AVX512*` set are all absent, so `SIMDJSON_CAN_ALWAYS_RUN_{HASWELL,ICELAKE,WESTMERE}` are all 0 and `SIMDJSON_IMPLEMENTATION_FALLBACK` stays 1: the artifact carries the **scalar kernel alone**. On an aarch64 baseline NEON is always present, so that target carries `arm64`. A Nix derivation must not depend on the CPU of whichever machine built it, which is why the flag is there and not in `devenv.nix`'s local tasks. |
| Zig's own bundled libc++ | upstream expects a C++11 runtime to be provided | `src/cmake/exception-flags.cmake:27` is the only place upstream names one, and it names no sysroot | Nothing for a native build. It is what removes the need for an external WASI SDK sysroot on the `wasm32-wasi` matrix row. |
| No CMake, no autotools, no `make` | `src/CMakeLists.txt` is upstream's own build | `src/CMakeLists.txt:204` | Nothing is downloaded and no build script of upstream's is executed. Upstream's CMake tree ships as source. |
| `-Dlinkage=dynamic` refused on `wasm32-wasi` | `BUILD_SHARED_LIBS` (`:193`) is a boolean upstream would honour everywhere | `lib/std/Target.zig:2345` (`DynamicLinker.kind` is `.none` for WASI) | A `.so` on WASI is a file nothing can open. The graph refuses the combination rather than answering it with an archive. Windows is *not* refused: `.none` there only because a PE/COFF image has no interpreter path, and a Windows target does carry a DLL. |

### The SIMD-fallback boundary, in one paragraph

At `-Dcpu=baseline` on x86-64 this package compiles the scalar `fallback` kernel
and no other. That is not a degraded build and not a rescue path: it is upstream's
own answer for a target with no guaranteed SIMD, it parses correctly at every
level of correctness these tests cover, and it is slower by an amount that is a
fact about the kernel and the input. What does **not** exist is a run-time
fallback behind a slow kernel -- `#include <simdjson/ondemand.h>` is statically
bound to `SIMDJSON_BUILTIN_IMPLEMENTATION`
(`src/include/simdjson/builtin/ondemand.h:11-31,39`), so there is no slower kernel
to fall back to at all. `SIMDJSON_FORCE_IMPLEMENTATION` does not change that: it
overrides the DOM-side run-time dispatcher, and naming a kernel that is not
compiled in makes upstream latch onto the unsupported implementation so that
every later parse fails with `UNSUPPORTED_ARCHITECTURE`
(`src/src/implementation.cpp:296-312`, latch at `:308`). The honest summary for a
dependent is that **which kernel you get is a build-time property of the flags
you built with and is not negotiable at run time**. `FORK-NOTES.md` notes 6 and 7
are the records.

## 6. What is compiled but not wrapped

The installed `include/simdjson/` tree is upstream's **complete** public header
set, 234 files, unmodified and complete. The Zig facade reaches none of it.

The reason is upstream's own structure. `simdjson::ondemand` is a namespace alias
bound to exactly one compile-time-selected kernel through
`src/include/simdjson/builtin/ondemand.h:39`, and its members are class
templates returning `simdjson_result<T>`. No C or Zig translation can name any of
that, which is the whole reason `zig/bridge.cc` exists.

So the facade binds **On-Demand only**, and a C++ consumer of this package has
all of upstream's API through the installed headers: `simdjson::dom::parser`,
`document_stream`, `minify`, compile-time JSON, and every public header
underneath them. `zig/root.zig` says so in prose, and `FORK-NOTES.md` note 1 is
the decision record for the absence.

The surface that *is* wrapped is `zig/bridge.h`: eleven C entry points, no data
symbol. `build_support/graph.zig:bridge_abi_symbols` names all eleven and
`runtime/library.zig` refuses a runtime provider that does not export every one.

## 7. No system mode

This package has no `-Dsystem` option, and that is a decision rather than an
omission.

`AGENTS.md` §4 permits a system mode only where a real compiled system library
exists, and requires that a fork with no system mode record the rule as vacuous
rather than satisfied. The vendored `src/` **is** the library: 771 files,
10317170 bytes, the complete release. A `-Dsystem` switch here would select a
*different version of the same project* on the build machine, which is a second
source of truth about which declarations are in play -- exactly the failure
`WISDOM.md` W14 records, and the one that makes a bundled new-release header
against an older installed library compile and then fail silently.

So: `build.zig` declares no `b.systemIntegrationOption`, `consumer/build.zig`
forwards no `-fsys` flag and says why, and `AGENTS.md` §1's "System mode is not
part of this wave" is recorded here as satisfied by having no such mode at all.

## 8. The test fixtures

22 fixtures under `testdata/`, totalling 645673 bytes, recorded in the last 22
lines of `UPSTREAM.sha256`. They are **not** upstream files. Each one's origin
and the behaviour it exists for is in [`testdata/README.md`](testdata/README.md),
which is the authoritative list; in summary:

* **5** under `testdata/rfc8259/` are the documents of RFC 8259 section 13,
  transcribed byte for byte.
* **1** under `testdata/large/`, `testdata/large/twitter.json`, is a
  byte-identical copy of upstream's own `src/jsonexexamples/twitter.json`.
* **16** are fork-authored byte sequences, one per behaviour.

`tests.zig` and `smoke.zig` read them through the build-created `simdjson_paths`
import, which `build.zig` resolves to an **absolute** path from the build root.
That is why the fixtures are read from this checkout and never from an installed
prefix: nothing in the install layout installs them, and a test binary that found
them under `--prefix` would be reading files no gate had recorded. It is also why
`package.nix:163-167` sets `doCheck = false`: a Nix derivation does not control
where this checkout is, and the fixtures are not part of its output.

## 9. Upstream's test suite

Upstream *does* ship one, and it is carried whole and unmodified under
`src/tests/`. It was never deleted and is never skipped by this package.

This graph does not run it, and does not pretend to. `src/tests/CMakeLists.txt`
builds it with upstream's own CMake and its own Catch2 harness; this graph runs no
CMake and vendors no Catch2. So `tools/check-provenance.sh` asserts that those
sources are **present and unedited** -- their digests are in `UPSTREAM.sha256` --
and `zig build test` runs this package's own behavioural tests instead.

Saying that plainly is better than a step that appears to run a suite it does not.
What a downstream consumer of the *library* gets is unaffected: the library is
the one translation unit, and upstream's suite tests the same sources it does.

## 10. Remote hygiene

`origin` and `upstream` are the downstream's business, not this package's. This
file records one thing about it, because it decides what a re-sync looks like:
simdjson has real upstream Git history, so a re-sync is the §9 procedure of
`AGENTS.md` -- add the upstream remote, fetch, merge the tag, and keep this fork's
changes as separate commits in separate regions. It is not the archive-import
procedure that a project without history would need, and nothing in this package
invents a SHA: the tag commit above was recorded at import from
`UPSTREAM.sha256:5` and is not re-derived here.

## Related records

* `UPSTREAM.sha256` -- 793 digests: 771 under `src/`, 22 under `testdata/`.
* `testdata/README.md` -- each fixture's origin and the behaviour it exists for.
* `NOTICE.md` -- the per-file licence inventory, including the four embedded
  third-party terms and the per-file exceptions.
* `FORK-LICENSE.md` -- the grant over this fork's own files.
* `FORK-NOTES.md` -- the decisions, in condition/symptom/cause/fix form.
* `README.md` -- this fork's README, in the workspace's required order.
* `README.upstream.md` -- upstream's README, preserved byte for byte.
* `README.zig.md` -- the Zig interface documentation.
* `tools/check-provenance.sh` -- the gate that checks every claim above about
  bytes and file sets.