# FORK-LICENSE.md — grant for this fork's own files

[`NOTICE.md`](NOTICE.md) inventories file provenance and licence terms. This file grants rights to fork-authored files only.

## Upstream source

The 771 files under `src/`, totalling 10,317,170 bytes, are simdjson 5.0.2's, extracted whole from the official release tarball and never edited. They are dual Apache-2.0 / MIT: `src/LICENSE` is the Apache License 2.0 and `src/LICENSE-MIT` is the MIT License, both carrying `Copyright 2018-2025 The simdjson authors`. `README.upstream.md` is the byte-preserved copy of upstream's README; it names four further third-party terms that apply to individual files.

Nothing in this file re-grants, narrows, widens, conditions or relabels those terms. It does not attribute fork code to The simdjson authors, Daniel Lemire, Geoff Langdale, John Keiser, Paul Dreik, Martin Moene, Toni Ronkko, Junekey Jeon, Lars Melchior, Jan Tojnar or any other person named in the vendored tree. `NOTICE.md` credits those people for the files they wrote.

## Fork-authored files and grant

Everything else in this repository is fork work, licensed under the Apache License 2.0 on the owner's authorization.

### The grant

```
SPDX-License-Identifier: Apache-2.0
```

The fork-authored files listed below are released under the **Apache License, Version 2.0**, with no additional term, no additional condition and no `LicenseRef-` wrapper. The complete, unmodified text of that licence ships in `src/LICENSE`. Its *Terms and Conditions* end at `END OF TERMS AND CONDITIONS`; the following appendix is instructional scaffolding. Shipping `src/LICENSE` discharges §4(a) for upstream and fork work alike.

The substantive grants are:

* **§2, Grant of Copyright License.** "each Contributor hereby grants to You a perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable copyright license to reproduce, prepare Derivative Works of, publicly display, publicly perform, sublicense, and distribute the Work and such Derivative Works in Source or Object form."
* **§3, Grant of Patent License.** A perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable patent licence, limited to claims licensable by the contributor and necessarily infringed by that contribution alone or in combination with the Work, **terminating on the date patent litigation is filed**.
* **§4, Redistribution.** The four conditions are `(a)` give recipients a copy of the Licence, `(b)` cause modified files to carry prominent notices stating the change, `(c)` retain all copyright, patent, trademark and attribution notices from the Source form, and `(d)` if the Work includes a `NOTICE` text file, include its attribution notices.

The owner of this workspace authorized per-project licensing for fork-authored additions. Apache-2.0 is this package's election. The grant is the owner's, not borrowed from simdjson, and it does not reach `src/`. No individual copyright holder is named or asserted for fork-authored files.

### SPDX identifiers

The registered identifier is bare `Apache-2.0`; this grant has no `LicenseRef-` variant. These six fork files carry the identifier: `runtime/loader.zig`, `runtime/generate.zig`, `runtime/graph.zig`, `runtime/library.zig`, `runtime/sync.c`, and `runtime/sync.h`. These three do not: `zig/bridge.h`, `zig/bridge.cc`, and `zig/root.zig`. The grant covers all fork-authored files listed below, whether or not a source file carries an SPDX line. Other fork-authored documentation, records, data, licence material and packaging carry no SPDX line; `NOTICE.md` lists them.

## Files covered by this grant

Every path below is fork-authored and Apache-2.0 under this grant. Nothing else in this repository is.

| Path | What it is |
|---|---|
| `build.zig` | Zig build and package entry points |
| `build.zig.zon` | package manifest |
| `build_support/graph.zig` | per-target module, flags and archive assembly |
| `zig/bridge.h` | C99 bridge surface translated by the Zig module |
| `zig/bridge.cc` | C++ implementation of the bridge |
| `zig/root.zig` | public Zig facade |
| `runtime/loader.zig` | reusable loader core; copied workspace code |
| `runtime/generate.zig` | build-time dispatch generator; copied workspace code |
| `runtime/sync.c` | mutex and condition variable per `RT_SYNC_PREFIX`; copied workspace code |
| `runtime/sync.h` | process-global synchronization declarations; copied workspace code |
| `runtime/graph.zig` | build half of the runtime-loading route |
| `runtime/library.zig` | simdjson descriptor and load-time checks |
| `tests.zig` | behavioural test root |
| `smoke.zig` | smoke example |
| `consumer/*` | separate package that consumes this package by relative path |
| `tools/check-provenance.sh` | provenance checker |
| `cross-test.profile.sh` | `cross-test` settings |
| `package.nix` | standalone Nix packaging |
| `flake.nix`, `devenv.nix`, `devenv.yaml`, `.envrc` | development environment |
| `README.md` | fork README |
| `README.zig.md` | Zig interface reference |
| `UPSTREAM.md` | source provenance and build deviations |
| `UPSTREAM.sha256` | digests for carried bytes |
| `NOTICE.md` | per-file inventory, upstream and third-party notices, and §4 obligations |
| `FORK-LICENSE.md` | this grant |
| `FORK-NOTES.md` | fork source and build deviations |
| `CHANGELOG.md` | consumer-visible changes |
| `testdata/README.md` | fixture provenance and purpose |

## Shared runtime-core copies

`runtime/loader.zig`, `runtime/generate.zig`, `runtime/sync.c` and `runtime/sync.h` are copied from the workspace's shared runtime core, not independently authored for this package. The core lives at `lua/runtime/`; it is first-party workspace code with no upstream provenance. The MIT identifier in the Lua package is the owner's election for that package.

| File | Difference from `lua/runtime/` |
|---|---|
| `runtime/loader.zig` | SPDX identifier: `MIT` → `Apache-2.0` |
| `runtime/generate.zig` | SPDX identifier: `MIT` → `Apache-2.0` |
| `runtime/sync.c` | SPDX identifier: `MIT` → `Apache-2.0` |
| `runtime/sync.h` | SPDX identifier and include guard changed to `SIMDJSON_RUNTIME_SYNC_H` |

The Lua package remains under MIT. `runtime/graph.zig` and `runtime/library.zig` are authored for this SDK.

## Excluded works and upstream obligations

* This grant does not re-license, sublicense, condition or add a requirement to any file under `src/`. Those files keep the dual Apache-2.0 / MIT grant and per-file exceptions in their own text.
* `src/LICENSE` and `src/LICENSE-MIT` ship byte for byte as upstream wrote them. The dual grant remains a dual grant; this file does not reduce it to one label.
* Consumers who ship `libsimdjson.so.34.0.0`, a static `libsimdjson.a`, or any header installed from `src/include/simdjson/` still owe every notice in the carried tree, including the four embedded third-party terms listed in `NOTICE.md`.
* This file does not assert that an upstream author reviewed, approved or is affiliated with this fork.
* This grant does not extend over `README.upstream.md`, `UPSTREAM.sha256`, `src/` or `testdata/`; `NOTICE.md` records their terms. `testdata/large/twitter.json` is a byte-identical copy of upstream's `src/jsonexamples/twitter.json` and is upstream's; the other 21 fixtures are fork-authored byte sequences named individually in `NOTICE.md`.
* This grant does not cover third-party works vendored by simdjson. They retain the terms written in their own files: fast_float's triple grant, the PyTorch-derived BSD-3-Clause, BSL-1.0 from two unrelated authors, ISC and BSD from mingw-w64 and NetBSD, and MIT from Toni Ronkko. `src/windows/getopt.h` is a per-file exception recorded in `NOTICE.md`.
