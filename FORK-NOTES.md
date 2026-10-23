# Fork notes

This fork builds simdjson 5.0.2 as a C++ library with a C ABI and Zig facade. The upstream source under `src/` remains unmodified.

## Source deviations

| File | Change and reason |
|---|---|
| `zig/translate.h` | Points `translate-c` at the fork's C header because upstream's public interface uses C++ templates. |
| `zig/bridge.h` | Defines eleven C entry points and fixed-width walk records so C and Zig callers avoid upstream C++ types. |
| `zig/bridge.cc` | Owns padded input and copies On-Demand results into preorder records, so callers do not hold upstream cursors or borrowed bytes. |
| `zig/root.zig` | Exposes typed views over copied records and maps bridge and upstream errors to Zig errors. |
| `runtime/graph.zig` | Builds runtime dispatch from translated declarations and shares one loader core, so runtime mode does not link the artifact. |
| `runtime/generate.zig` | Generates dispatch wrappers and patched translations so routed calls retain the translated C types. |
| `runtime/library.zig` | Defines the provider ABI and checks version, exports, record behavior and parsing before publication. |
| `runtime/loader.zig` | Loads one explicit path or system name and publishes one provider without automatic search, unload or replacement. |
| `runtime/sync.h` | Declares prefixed locks, waits, wakeups and thread identity so SDK instances do not share symbols. |
| `runtime/sync.c` | Implements those symbols with Windows locks, POSIX threads, or single-threaded WASI/Emscripten no-ops. |

The Zig facade binds upstream On-Demand only. Its `Document`, `Walk`, `Array` and `Object` values refer to copied records, not parser cursors. The installed C++ headers still expose upstream's DOM, document streams, minifier and compile-time JSON APIs.

`parse` copies input into upstream's padded storage, so callers can reuse their input after the call. `walk` sizes both outputs when either buffer is absent or empty. A short fill returns `BUFFER_TOO_SMALL` and both required sizes, never a partial result. Record offsets and lengths use 32-bit fields, so unrepresentable documents return upstream `CAPACITY`. `0xFFFFFFFF` marks an absent offset, while zero-length keys remain valid.

The bridge checks arguments with comparisons, keeps bridge statuses separate from upstream errors, and catches only `std::bad_alloc`. It mirrors every upstream error value and checks the mirror with compile-time assertions. It validates UTF-8 before parsing, enforces the default depth limit before upstream's assertion, rejects trailing content, and maps unknown JSON values to upstream `TAPE_ERROR`. For numbers, it parses before classification and exposes out-of-range integer text through `raw_json_token()`.

## Build graph

- Compile upstream `src/src/simdjson.cpp` and fork-owned `zig/bridge.cc` as the two C++ units. The graph does not build upstream examples, benchmarks, fuzzers or tests.
- Pin C++17 and disable exceptions and RTTI. Set `SIMDJSON_DEVELOPMENT_CHECKS=1` and `SIMDJSON_ENABLE_NAN_INF=0` for every target and optimize mode.
- Set `SIMDJSON_THREADS_ENABLED=1` only where the C++ runtime has `std::thread`. Set `SIMDJSON_AVX512_ALLOWED=0` for x86-64 targets without AVX-512.
- The default `-Dlinkage=static` builds an archive. Dynamic builds use upstream ABI version 34, not release version 5.0.2. No system-library mode exists.
- `-Druntime=true` changes dispatch, not delivery. The package still builds and installs its artifact, while the facade loads an explicit provider and links no archive.
- COFF shared builds use a generated `.def` export list. ELF builds have no version script. Darwin builds do not restrict exports to the eleven C entry points, so consumers must resolve names explicitly.
- `check` compiles the facade, tests and example for the six required targets. It does not run them.

## Platform boundaries

The six compile-check targets are `x86_64-linux-gnu`, `aarch64-linux-gnu`, `aarch64-macos-none`, `x86_64-windows-gnu`, `riscv64-linux-gnu` and `wasm32-wasi`. Targets without an available runner receive compile-only coverage, not runtime coverage.

The build selects one On-Demand kernel from target features. It has no runtime fallback. `builtinImplementation()` reports that build-time choice. `activeImplementation()` reports upstream's environment-dependent DOM dispatcher and is not a provider compatibility requirement.

- Baseline x86-64 uses the scalar kernel; the graph disables AVX-512 when the target CPU lacks it.
- Big-endian AArch64 uses the scalar kernel because upstream's `arm64` implementation is byte-order dependent.
- LoongArch builds define the two HWCAP values that upstream ISA detection expects but some libc headers omit.
- WASI has no dynamic loader or `std::thread`; it supports static linkage only and cannot provide runtime-loaded libraries.
- Windows supports dynamic libraries despite having no ELF-style dynamic linker, and the generated `.def` supplies its exports.
- A Darwin shared library has no export map in this graph, so its exported symbols can exceed the bridge ABI.
