# CHANGELOG.md

The change statement Apache-2.0 §4(b) points at: which files changed, and why.
Format is Keep a Changelog's, because it is the convention this workspace's other
forks use.

**No release has been published.** Two gates have run and both are recorded as
`OBSERVED` under "Observed" below: the published 53-platform `cross-test`
matrix, twice, and the host gates. `FORK-NOTES.md` notes 22 and 23 are their
records. Everything else below is `PENDING-VERIFICATION`. Nothing in this file
asserts a build, a test, a digest or a result that was not read out of a file or
printed by a command that ran; `AGENTS.md` §2's four kinds of statement are not
mixed here, and there is no `VERIFIED` anywhere in this file. The remaining gates
are the driver's, and their receipts belong in `FORKS.json`.

## [Unreleased]

The initial import of the simdjson 5.0.2 Zig SDK. Nothing here is a change to an
earlier release, because there is no earlier release.

### Observed — the published 53-platform matrix, twice

- **`cross-test`, run 1**, from the package root on 2026-10-05 against Zig 0.16.0:
  harness **exit code 1**, 53 targets, `pass 3 / build_only 33 / fail 17`
  (`run_id 20261005-191536-35482-1400`). `FORK-NOTES.md` note 22 is that record,
  with the per-cell table and every receipt path.
- **`cross-test`, run 2**, same day, after the three fixes below: harness
  **exit code 0**, 53 targets, `pass 20 / fail 0 / build_only 33`, 39/39 tests in
  every executed cell (`run_id 20261005-201334-56987-6494`). `FORK-NOTES.md`
  note 23 is that record.
- **Host gates, run 2**, same toolchain: `zig build` exit 0; `zig build test`
  exit 0, 39/39, in Debug and `-Doptimize=ReleaseSafe`; `zig build smoke` exit 0;
  `zig build check` exit 0, 43/43 steps; `zig build consumer` exit 0, 6/6 steps;
  `tools/check-provenance.sh` exit 0, `provenance checks passed` — the direct
  evidence that no vendored byte moved.
- **Refused by design**: `zig build -Dlinkage=dynamic` and
  `zig build check -Dlinkage=dynamic` both exit
  **1 by the refusal this file and `README.md` §3 state in advance**:
  `deliveredLinkage` (`build_support/graph.zig:776`) will not substitute a static
  archive for a requested shared object, and `wasm32-wasi` has no dynamic linker.
- The **33 `build_only` cells are unchanged in both runs and are not passes** in
  either: they compiled and were never executed, because this host has no runner
  for FreeBSD, NetBSD, OpenBSD, macOS, maccatalyst, Windows or wasmtime.
- The three causes of run 1's seventeen failures were upstream's, and all three
  are answered in this package's own files — see the three entries under
  "Fixed" that carry note 23. No vendored byte changed and no test expectation
  changed.

### Added — the vendored upstream tree

- **771 files, 10317170 bytes**, under `src/`: the complete extracted
  `simdjson-5.0.2` release tarball, byte for byte. Tag `v5.0.2`, tag commit
  `c9030726ebbf5f9fe9f9facb4a401f6d3ccd77a2`, tarball sha256
  `09de4289a26d3a0453569901a3837450b5b98a5c317d635eeee8e2a82b1ebe6b`. Every file
  has a digest in `UPSTREAM.sha256`. See `UPSTREAM.md` §1 and §2.
- **Three files deliberately absent**, recorded as absent rather than omitted:
  `src/singleheader/simdjson.h`, `src/singleheader/simdjson.cpp` and
  `src/singleheader/singleheader.zip`. They are upstream's *generated*
  amalgamation, and this build compiles upstream's own `src/src/simdjson.cpp`
  directly, so a second buildable copy of the same sources would be a second,
  drifting core. The generator that makes them is carried.
  `tools/check-provenance.sh` fails if any of the three reappears.
- **`README.upstream.md`**: upstream's README preserved byte for byte.
- **`UPSTREAM.sha256`**: 793 digests, 771 under `src/` and 22 under `testdata/`.
- **`testdata/`**: 22 recorded fixtures, 645673 bytes. Five transcribed from
  RFC 8259's section 13 ("Examples"), one a byte-identical copy of upstream's own
  `src/jsonexamples/twitter.json`, sixteen authored for a specific behaviour.
  `testdata/README.md` gives each one's origin.

### Added — the C ABI seam

- **`zig/bridge.h`**: plain C99 with `extern "C"` guards, eleven entry points, and
  an include set of exactly `<stddef.h>` and `<stdint.h>`. This package's
  externally linked ABI is those eleven functions and no data symbol; every
  declaration is unconditional.
- **`zig/bridge.cc`**: the C++ over that surface. One validation, at most one
  upstream call and one copy out per entry point. It is the only translation unit
  that compiles `<simdjson.h>`, because upstream's public interface is C++
  namespaces and class templates and no C or Zig translation can name any of it.
- **Binds On-Demand, and only On-Demand.** The DOM API, `document_stream`, the
  minifier and compile-time JSON are absent from the Zig facade by decision and
  are reachable from C++ through the installed `include/simdjson/` tree, which
  ships whole and unmodified. `FORK-NOTES.md` note 1 is the record.
- **The walk copies the document.** No borrowed value crosses the boundary and no
  cursor is exported, so no caller can trip `OUT_OF_ORDER_ITERATION`; the price is
  one copy of every value, stated plainly in `FORK-NOTES.md` note 2.

### Added — the Zig surface

- **`zig/root.zig`**: `LoadSource`, `load`, `loadedSource`, `Error`, `ValueType`,
  `NumberType`, `Record`, `parse`, `Document`, `Walk`, `Value`, `Array`, `Object`,
  `Field`, the two iterators, `version`, `builtinImplementation`,
  `activeImplementation`, `activeImplementationDescription`,
  `availableImplementationCount`, `availableImplementationName`,
  `validateUtf8` and `upstreamErrorCode`.
- **The whole of upstream's `simdjson::error_code` is mirrored**, at upstream's own
  integers, including the members this bridge has never been seen to produce --
  because a walk can be handed any of them and a caller reading a refusal deserves
  a name. `zig/bridge.cc` `static_assert`s every value against the real enumerator
  on every target that builds the library, so the mirror cannot drift from it.
- **`zig/translate.h`**: the aggregate header `translate-c` reads. It names one
  header -- this package's own `zig/bridge.h` -- and nothing else.
- **`Error.BufferTooSmall`, `Error.UnknownStatus` and `Error.UpstreamUnnamed`**
  exist because the taxonomy is cut at what this package's own code checked, not
  at what it has been seen to produce.

### Added — the runtime-loading route

- **`runtime/graph.zig`**: the build half. Three modules and one generated file,
  from the real translation step's output.
- **`runtime/library.zig`**: this SDK's descriptor -- the namespaced
  synchronization binding and the load-time checks a provider must pass.
- **`runtime/loader.zig`, `runtime/generate.zig`, `runtime/sync.c`,
  `runtime/sync.h`**: **copied** from the workspace's shared runtime core, not
  authored here. Differences from the originals are the SPDX identifier and, in
  `sync.h`, an include-guard rename each SDK requires.
  `FORK-LICENSE.md` §5 is the full record, including the boundary a later wave
  must not cross.
- **`-Druntime=true`**, orthogonal to `-Dlinkage`: the artifact is still built and
  installed, and the facade module links none of it. One process-lifetime table,
  an explicit `load(source)`, no unload and no reset, and a pre-initialization
  panic naming the function in every optimize mode.

### Added — the build

- **`build.zig`**: two C++ translation units at `-std=c++17 -fno-exceptions
  -fno-rtti`, one translation step, one facade module, the install layout, the
  generated `simdjson.pc`, the licence records, the six-target `check` matrix, and
  the `test`, `smoke` and `consumer` steps.
- **`build_support/graph.zig`**: per-target assembly. `artifact_name`,
  `bridge_abi_symbols`, `required_targets` and `addGraph`.
- **The configuration macros**, resolved per target by
  `build_support/graph.zig`'s `cppMacros`. Three are this package's choice and the
  same everywhere: `SIMDJSON_DEVELOPMENT_CHECKS=1`, `SIMDJSON_ENABLE_NAN_INF=0`,
  `SIMDJSON_EXCEPTIONS=0`. The first of those is **this package's decision, not
  upstream's default**, and it has a real cost: `DEFAULT_MAX_DEPTH` (1024)
  becomes an enforced boundary in a release build. `FORK-NOTES.md` note 8 is the
  record, including how to overturn it. Two are the target's own facts and are
  read from the resolved target rather than from the host:
  `SIMDJSON_THREADS_ENABLED=1` on every target whose C++ runtime has
  `std::thread`, and `SIMDJSON_AVX512_ALLOWED=0` on an x86-64 target whose CPU
  model has no AVX-512 — both upstream's own switches
  (`src/CMakeLists.txt:382-386` and
  `src/include/simdjson/common_defs.h:385-388`). The configure-time banner prints
  what the target being built actually received rather than a literal.
- **`-Dlinkage=static|dynamic`**, with the soname upstream's own
  `SIMDJSON_LIB_SOVERSION` -- `libsimdjson.so.34.0.0`, soname
  `libsimdjson.so.34` -- and **not** the 5.0.2 release number. A shared request on
  a target that cannot carry one is refused with a message naming it; Windows is
  named separately from WASI for the reason `FORK-NOTES.md` note 20 gives.
- **No version script on ELF, a generated `.def` on COFF**, and nothing on
  Mach-O -- which is stated rather than hidden, because a Darwin shared object
  from this graph exports more than the eleven declared names.
- **No system mode**, recorded as vacuous rather than satisfied.
  `UPSTREAM.md` §7.

### Added — tests, example and consumer

- **`tests.zig`**: 39 behavioural tests. Every expectation is an independent known
  answer -- RFC 8259's own section 13 documents and section 7 table, IEEE 754's
  own boundary values, upstream's own error enumeration -- or an
  interoperability claim against upstream's own `twitter.json`. None is a
  version-string pin, an `@hasDecl`, an export check, a forwarding comparison or
  a non-zero-length check.
- **`smoke.zig`**: the deterministic example. It prints the two facts that differ
  between machines and compares neither, and says why.
- **`consumer/`**: a separate package that resolves this one by relative path and
  reaches it only through `dep.module("simdjson")`, in linked and runtime-loaded
  configurations.

### Added — provenance, licence and CI

- **`tools/check-provenance.sh`**: the recorded bytes, the exact file set, the
  absence of the three generated files, the preserved upstream README, and the
  dual Apache-2.0/MIT grant with its patent-grant termination clause.
- **`NOTICE.md`**: the per-file inventory. Five vendored third-party terms, two
  per-file exceptions inside the carried tree, both upstream licences, and how
  each of Apache-2.0 §4's four conditions is met.
- **`FORK-LICENSE.md`**, **`FORK-NOTES.md`**, **`UPSTREAM.md`**,
  **`testdata/README.md`**, **`README.md`**, **`README.zig.md`**: the records.
- **`package.nix`**, **`flake.nix`**, **`devenv.nix`**, **`devenv.yaml`**,
  **`.envrc`**: standalone Nix packaging and the canonical development shell.
  `-Dcpu=baseline` in `package.nix` is what makes a store path reproducible; at
  that baseline on x86-64 the artifact carries the scalar `fallback` kernel alone.
- **`cross-test.profile.sh`**: settings for the 53-platform matrix driver. No
  target list and no machine path, so the harness's published table is the matrix.
- **`.github/workflows/verify.yml`**: this fork's workflow, and **not** upstream's.
  All 45 workflows under `src/.github/` are carried untouched and are inert,
  because they are not at this repository's `.github/workflows/` path.

### Fixed

Every entry below was found by running a gate against this tree, and each names
what forced it. The last three were found by the published 53-platform
`cross-test` matrix, which no host gate can reach: each is a kernel, an
endianness or a toolchain fact that only a foreign target exposes.

- **`zig/bridge.cc`: a JSON integer outside 64 bits is now recorded as
  `big_integer` instead of refused.** `WalkScalar` classified only a *successful*
  `get_number()`, but `parse_number` refuses such a token with `BIGINT_ERROR` and
  returns no `number` to classify, so the `big_integer` arm was unreachable on every
  input and `{"n":18446744073709551616}` came back as `Error.UpstreamBigint`. The
  route taken now is upstream's own: `BIGINT_ERROR` plus `raw_json_token()`
  (`src/doc/basics.md:3532-3533`). `FORK-NOTES.md` note 21.
- **`zig/bridge.cc`: trailing content after a container root is refused.** `{} {}`
  and `[1][2]` were accepted, because upstream checks trailing content itself only
  for a *root scalar* and asks the caller to call `document::at_end()` at both
  container ends. The walk now asks. `FORK-NOTES.md` note 21.
- **`zig/bridge.cc`: a document nested past `DEFAULT_MAX_DEPTH` is refused rather
  than aborting the process.** Stage 1 does not bound the depth, and with
  `SIMDJSON_DEVELOPMENT_CHECKS` the bound reaches an `assert` in
  `json_iterator::set_start_position`; the observed failure was `Assertion
  'size_t(depth) < parser->max_depth()' failed` and a SIGABRT that took the test
  binary with it. The walk now compares its own depth against upstream's own
  `DEFAULT_MAX_DEPTH` and answers upstream's own `DEPTH_ERROR`. `FORK-NOTES.md`
  note 8.
- **`zig/bridge.cc`: a filling call that runs out of buffers reports the sizes the
  document requires.** `zig/bridge.h` has always promised them; the walk instead
  stopped at the first record that did not fit, so a caller sizing a retry from the
  answer got two records for a six-record document. It now runs to the end of the
  document and writes nothing further. `FORK-NOTES.md` note 16.
- **`build_support/graph.zig`: two configuration macros are resolved per target.**
  `SIMDJSON_THREADS_ENABLED=1` on a target whose C++ runtime has no `std::thread`
  failed to compile `document_stream` on `wasm32-wasi`, and the icelake kernel's
  AVX-512 intrinsics failed on a baseline x86-64 cross target, because
  `SIMDJSON_AVX512_ALLOWED` defaults to 1 on every x86-64 target. Both are
  upstream's own switches and both are now asked of the resolved target, never of
  the host. `FORK-NOTES.md` note 9.
- **`smoke.zig`: the example now fails its step on a mismatch.** It printed
  `MISMATCH` and exited 0, which made `zig build smoke` report success for a
  program that had just said fifteen of its checked answers were wrong.
- **Fixture provenance corrected** in `tests.zig`, `smoke.zig`,
  `testdata/README.md`, `CHANGELOG.md`, `UPSTREAM.md` and `NOTICE.md`. The five RFC
  fixtures are the documents of **RFC 8259 section 13**, not of an "Appendix A":
  RFC 8259's Appendix A is "Changes from RFC 7159", and the bytes were right all
  along. `13-object.json` has **one** top-level key (`Image`) whose value has
  **six**; the test and the fixture record each said five at the top level.
- **Expectations corrected against the fixtures they read**: the nesting
  fixtures' record counts and leaf depths (a record is one *value*, and the object
  holding `leaf` is a record of its own), the 2049 `{` bytes in `nesting-2048`,
  the escape fixture's fourteenth length (U+00FC plus `ber` is five bytes), the
  control character's byte and index (`0x01` at index 7), the two top-level keys of
  upstream's own `twitter.json` (`query` is a member of `search_metadata`), the
  record count `Record.bytes` is asked to return for a record that has no bytes,
  and `1e400`, which upstream refuses as `NUMBER_ERROR` and not as
  `NUMBER_OUT_OF_RANGE`.
- **`expectRefused` and `smoke.zig`'s `report` now walk the document** as well as
  parsing it. `parse` is upstream's stage 1, which indexes structure and does not
  parse values, so asking it alone reported `{"a":1,}`, `{"a":01}` and `1e400` as
  accepted — a statement about stage 1, not about this package.
- **`tools/check-provenance.sh`: the file-set check no longer trips over the file
  the same script requires.** It compared `find src testdata -type f` against the
  manifest and so reported `testdata/README.md` as an unrecorded vendored file,
  while `:201` requires that file to exist and `:208-214` reads it. The record is
  deliberately not a fixture and so has no digest; the comparison now excludes it.
  The observed failure was `the vendored file set differs from the recorded one`
  with `+testdata/README.md` as the only difference, and all 793 recorded digests
  already matched.
- **`zig/bridge.cc`: a document that is not valid UTF-8 is refused with
  `UTF8_ERROR` on every target, before stage 1 runs.** Upstream's SIMD
  implementations validate the whole buffer inside stage 1
  (`src/generic/stage1/json_structural_indexer.h:241-243`); its scalar `fallback`
  implementation validates inside strings only
  (`src/src/fallback.cpp:198-203`), so a byte `>= 0x80` outside a string was
  absorbed into an atom and refused as `TAPE_ERROR` — or accepted outright. Which
  kernel is compiled in is a property of the target's flags, so fifteen cells of
> the 53-platform matrix refused the same bytes with a different enumerator, or
> accepted them. `simdjson_br_open` now asks `simdjson::validate_utf8` first —
  upstream's own validator, and the call `simdjson_br_validate_utf8` already made —
  so the answer no longer depends on the kernel and `parse` agrees with
  `validateUtf8` by construction. It costs one extra linear pass per `open`. The
  test that caught this is unchanged. `FORK-NOTES.md` notes 22 and 23.
- **`build_support/graph.zig`: a big-endian AArch64 target compiles upstream's
  scalar kernel instead of `arm64`.** The `arm64` kernel's stage-1 table and
  shuffle masks are built by reinterpreting 64-bit integers as byte vectors
  (`src/include/simdjson/arm64/simd.h:258-259`, `:264`), which places the table
  bytes in the opposite lane order on a big-endian target; upstream guards only
  its number parsing (`src/include/simdjson/arm64/numberparsing_defs.h:54-58`).
  Observed on `aarch64_be-linux`: 34 of 39 tests failed, one leaked, and malformed
  fixtures were accepted. `SIMDJSON_IMPLEMENTATION_ARM64=0` — upstream's own
  switch, in its own `#ifndef` form
  (`src/include/simdjson/implementation_detection.h:28-33`) — is now passed for
  that target and asked of the resolved target, never of the host.
  `FORK-NOTES.md` note 23.
- **`build_support/graph.zig`: a LoongArch target is given the two kernel
  capability constants its ISA detection reads.**
  `src/src/internal/isadetection.h:298,301` reads `HWCAP_LOONGARCH_LSX` and
  `HWCAP_LOONGARCH_LASX` with no `#ifndef` guard, and only the kernel's
  `asm/hwcap.h` defines them (`arch/loongarch/include/uapi/asm/hwcap.h:10-11`),
  which the pinned toolchain's C library does not ship, so `loongarch64-linux`
  did not compile. Upstream closes this same gap for its own AArch64 branch by
  defining the kernel's values itself (`src/src/internal/isadetection.h:86-97`),
  and this graph now passes them for `loongarch64` in the same way.
  `FORK-NOTES.md` note 23.

## Decisions a later wave should read before changing anything

Each is a `FORK-NOTES.md` note with a condition, a symptom, a cause, a fix and a
*targets bound* line. The bound is the part that says when the decision has to be
re-derived rather than inherited.

| note | decision | bound |
|---|---|---|
| 1 | On-Demand only; no DOM, no `document_stream`, no minifier | upstream's one-shot consumption contract at 5.0.2. Independent of Zig version and target. |
| 2 | The walk copies the document; no cursor crosses the ABI | upstream's one-shot rule. The copy is this fork's design and would survive a future release; only the *reason* it exists would need re-checking. |
| 3 | The input is copied, because upstream refuses an unpadded buffer | `SIMDJSON_PADDING` and `padded_string_view::has_sufficient_padding`. |
| 5 | `get_number` classifies a number; `get_number_type` is never asked | `numberparsing::parse_number`'s leading-zero guard at `:906`. |
| 8 | `SIMDJSON_DEVELOPMENT_CHECKS=1` on every target in every mode, and the depth bound is an ordinary comparison rather than the assert it guards | upstream's Debug-only default, and this package's choice to override it. **The one decision here a later wave should be able to overturn deliberately.** |
| 12 | Arguments are validated by comparison, never by `assert` | Zig's `assert` semantics, which are the reason. Independent of target and of upstream. |
| 13 | Only `std::bad_alloc` is caught | `-fno-exceptions` at every target. |
| 15 | Both walk outputs are two-pass, and the sizing rule is coarse | `document::rewind()` existing at all. |
| 18 | No version script on ELF; a `.def` on COFF | ELF and COFF toolchain behaviour. Darwin is **not** claimed to have a clean export surface. |
| 19 | The soname is 34 and the release is 5.0.2, and they are different facts | upstream's `SIMDJSON_LIB_SOVERSION` at this tag. |
| 20 | `-Dlinkage=dynamic` is refused where no shared object can exist, and Windows is the exception | `std.Target.DynamicLinker.kind` in Zig 0.16.0. |
| 21 | Trailing content and the big-integer route are asked of upstream by name | `document::at_end()` and `raw_json_token()` existing at this tag. |

## Open questions this release does not answer

Recorded because a later wave needs to know they were open, and because an open
question that is not written down becomes a claim.

1. **The builtin-kernel cascade is duplicated.** `zig/bridge.cc:96-116` is a
   nine-arm `#if` cascade mirroring
   `src/include/simdjson/implementation_detection.h:148-172` exactly, because
   upstream's own `simdjson::builtin_implementation()` guards its lookup with a
   debug-only `assert` (`src/src/implementation.cpp:342`) and would dereference a
   null pointer in a release build. **Nothing checks at build time that the two
   agree.** A future upstream release that adds or reorders a kernel needs
   `zig/bridge.cc` edited to match, and a mistake here is a wrong *name* rather
   than a failure. `FORK-NOTES.md` note 6 is the record; closing it would mean
   generating the cascade from the same header upstream's preprocessor reads.
2. **The depth boundary is a package decision, not an upstream fact.** If
   `SIMDJSON_DEVELOPMENT_CHECKS` is ever dropped,
   `testdata/values/nesting-2048.json` is still refused — the comparison is this
   bridge's own and does not depend on the macro — but the assertion the
   comparison guards disappears with it. `FORK-NOTES.md` note 8 is the record.
3. **A Mach-O shared object from this graph exports more than the eleven
   declared names**, because there is no version-script or `.def` mechanism to
   narrow it. Upstream ships no Darwin shared object to match, so there is no
   reference answer. A Darwin consumer must select by name. This is stated in
   `build.zig`'s configure output and in `README.md` rather than left to be found
   with `nm`.
4. **CI and the two `-Dlinkage=dynamic` rows are still open.** Nothing in this
   file is `VERIFIED`. The matrix has run twice and the second run is green; its
   first run's three failures were all answered in this package's own files,
   recorded under "Observed" above and in `FORK-NOTES.md` notes 22 and 23.
   `tools/check-provenance.sh` exits 0, which is the direct evidence that no
   vendored byte moved. The `-Dlinkage=dynamic` rows refuse by design rather than
   run. What is left for the driver is the linked and runtime-loaded consumer in
   both configurations.

## Related records

* `UPSTREAM.md` -- the pin, both version numbers, every build deviation with its
  upstream line, and the SIMD-fallback boundary.
* `FORK-NOTES.md` -- the twenty-three decisions, in condition/symptom/cause/fix
  form.
* `NOTICE.md` -- the licence inventory.
* `FORK-LICENSE.md` -- the grant over this fork's own files.
* `testdata/README.md` -- each fixture's origin and purpose.
* `README.md` -- the fork README, in the workspace's required order.