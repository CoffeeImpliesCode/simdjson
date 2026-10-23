# simdjson for Zig

A Zig package for upstream simdjson 5.0.2, with its C++ core behind a C bridge and typed Zig facade.
The upstream release tree is unchanged except for the generated single-header outputs listed below.

## Source deviations from upstream

| Path | Change and reason |
|---|---|
| `src/singleheader/simdjson.h`, `src/singleheader/simdjson.cpp`, `src/singleheader/singleheader.zip` | Omitted generated amalgamation outputs; `amalgamate.py` remains. |
| `zig/translate.h` | Gives `translate-c` the fork's C header because upstream exposes C++ templates. |
| `zig/bridge.h` | Defines eleven C entry points and fixed-width walk records for C and Zig callers. |
| `zig/bridge.cc` | Owns padded input and copies On-Demand values into preorder records. |
| `zig/root.zig` | Maps bridge and upstream errors to typed Zig views over copied records. |
| `runtime/graph.zig`, `runtime/generate.zig` | Build dispatch from translated C declarations without linking an archive in runtime mode. |
| `runtime/library.zig` | Checks provider version, exports, record behavior and parsing before publication. |
| `runtime/loader.zig` | Loads one explicit path or system name; does not search, unload or replace providers. |
| `runtime/sync.h`, `runtime/sync.c` | Prefix synchronization symbols; implement Windows, POSIX and single-threaded WASI/Emscripten behavior. |

The Zig facade wraps On-Demand only. The installed upstream C++ headers retain the DOM, document streams, minifier and compile-time JSON APIs.

## Build deviations

- The library compiles upstream `src/src/simdjson.cpp` and fork `zig/bridge.cc` as C++17 units; it does not run upstream's build system or build its tests, examples, benchmarks or fuzzers.
- The core disables exceptions and RTTI. The bridge disables RTTI but retains exceptions to catch `std::bad_alloc`. Both use `SIMDJSON_EXCEPTIONS=0`; the graph enables development checks, disables NaN/Inf, enables threads where `std::thread` is available, and disables AVX-512 when the target CPU lacks it.
- `-Dlinkage=static` is the default. `-Dlinkage=dynamic` uses upstream ABI version 34, not release version 5.0.2. There is no system-library mode.
- `-Druntime=true` selects explicit runtime dispatch independently of delivery: the build still installs its artifact, while the facade module links no archive.
- Installation includes the library, the complete upstream `include/simdjson` tree, `simdjson.h`, `simdjson_bridge.h` and `lib/pkgconfig/simdjson.pc`.
- COFF shared libraries use a generated `.def` with the eleven bridge exports. ELF has no version script; Darwin has no export map and can expose symbols beyond the bridge ABI.

## Support matrix

The build graph's `check` step compiles the library, facade, tests and example for these targets; it does not run them.

| Target | Boundary |
|---|---|
| `x86_64-linux-gnu` | `-Dcpu=baseline` selects the scalar kernel. |
| `aarch64-linux-gnu` | NEON is part of the baseline CPU. |
| `aarch64-macos-none` | Darwin shared libraries have no export map. |
| `x86_64-windows-gnu` | COFF shared libraries use the generated `.def`. |
| `riscv64-linux-gnu` | The target feature set selects the RVV VLS kernel when available. |
| `wasm32-wasi` | Static linkage only; no dynamic loader or `std::thread`. |

The On-Demand kernel is selected at build time; there is no runtime fallback. Big-endian AArch64 uses the scalar kernel. LoongArch builds define the HWCAP values used by upstream ISA detection. Runtime loading is unavailable on WASI, Emscripten and freestanding targets.

## Consumption

The manifest requires Zig 0.17.0 and declares no Zig package dependencies. For a sibling checkout, add this path dependency to `build.zig.zon`:

```zon
.dependencies = .{
    .simdjson = .{ .path = "../simdjson" },
},
```

The module and native artifact are both named `simdjson`. Import the facade from a dependent build:

```zig
const dep = b.dependency("simdjson", .{ .target = target, .optimize = optimize });
exe_mod.addImport("simdjson", dep.module("simdjson"));
```

Build options are `-Dtarget`, `-Dcpu` and `-Doptimize` (Zig standard options), `-Dlinkage=static|dynamic` (default `static`) and `-Druntime=true|false` (default `false`). `-Dcpu` selects the compiled kernel; it does not enable runtime fallback. A dynamic request on a target without a loader is refused rather than replaced with a static archive. On ELF, the shared file is `libsimdjson.so.34.0.0` with SONAME `libsimdjson.so.34`.