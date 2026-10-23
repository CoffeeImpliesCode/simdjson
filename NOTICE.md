# NOTICE

The `src/` tree is the complete, unmodified simdjson 5.0.2 release. For simdjson-authored files, upstream offers either Apache-2.0 (`src/LICENSE`) or MIT (`src/LICENSE-MIT`). Both full texts are preserved, with `Copyright 2018-2025 The simdjson authors`. `src/AUTHORS`, `src/CONTRIBUTORS`, and file-level notices are preserved. Daniel Lemire, Geoff Langdale, John Keiser, Paul Dreik, Martin Moene, Toni Ronkko, Junekey Jeon, Lars Melchior, and Jan Tojnar are attributed only to the files that name them. This notice inventories terms; it does not change the terms for files under `src/`. The third-party files below retain their own terms, which do not derive from simdjson's dual grant.

## Terms within `src/`

| Path | Work and terms | Attribution |
|---|---|---|
| `src/` | simdjson; Apache-2.0 or MIT, at the user's option, except files with their own terms below | `Copyright 2018-2025 The simdjson authors` |
| `src/include/simdjson/internal/fast_float.h` | fast_float 8.2.10; Apache-2.0 or MIT or BSL-1.0, at the user's option | The header credits simdjson_fast_float by Daniel Lemire and Joao Paulo Magalhaes, with contributions from Eugene Golushkov, Maksim Kita, Marcin Wojdyr, Neal Richardson, Tim Paine, Fabio Pellacini, Lenard Szolnoki, Jan Pharago, Maya Warrier, Taha Khokhar, and Anders Dalvander. |
| `src/include/simdjson/nonstd/string_view.hpp` | string-view lite 1.8.0; Boost Software License 1.0 | `Copyright 2017-2020 by Martin Moene`; https://github.com/martinmoene/string-view-lite |
| `src/src/to_chars.cpp` | De-templated port of Dragonbox's `simple_dragonbox`; BSL-1.0. The original is Apache-2.0-with-LLVM-exceptions or BSL-1.0; this port uses BSL-1.0. | `Copyright 2020-2025 Junekey Jeon (and contributors)`; Junekey Jeon, “Dragonbox: A New Floating-Point Binary-to-Decimal Conversion Algorithm” (2022). |
| `src/src/internal/isadetection.h` | Modified PyTorch TH/SYCL-derived code; BSD-3-Clause | Facebook, Inc (Adam Paszke, 2016-; Soumith Chintala, 2014-), Idiap Research Institute (Ronan Collobert, 2011-2014; Samy Bengio 2001-2004 and 2006-2010), Deepmind Technologies (Koray Kavukcuoglu, 2012-2014), NEC Laboratories America (Koray Kavukcuoglu 2011-2012; Ronan Collobert, Leon Bottou, Iain Melvin, Jason Weston 2006-2010), NYU (Clement Farabet, 2011-2013). |
| `src/windows/toni_ronnko_dirent.h` | dirent for Microsoft Visual Studio; MIT | `Copyright (C) 1998-2019 Toni Ronkko`; https://github.com/tronkko/dirent |

`fast_float` is a modified vendored copy: `src/tools/vendor_fast_float.sh` renames its namespace and macros and folds accented attribution characters to ASCII. The file header records those changes.

Other per-file terms and exceptions:

- `src/windows/getopt.h` carries an ISC-style grant from Todd C. Miller (copyright 2002), with the wording “Permission to use, copy, modify, and distribute this software for any purpose with or without fee is hereby granted” and the AS-IS disclaimer; a BSD-style grant from The NetBSD Foundation for work by Dieter Baron and Thomas Klausner (copyright 2000), with its three conditions and disclaimer; and a DARPA sponsorship acknowledgement (Contract Number F39502-99-1-0512). It says it is part of the mingw-w64 runtime package and includes: “This file has been modified by D. Lemire for use in simdjson.”
- `src/windows/dirent_portable.h` has no notice of its own. It selects the system `<dirent.h>` off Windows and `toni_ronnko_dirent.h` on Windows; the latter's MIT terms cover the Windows implementation.
- `src/dependencies/CMakeLists.txt` is the only file in `src/dependencies/` and carries simdjson's terms.
- `testdata/large/twitter.json` is byte-identical to upstream's `src/jsonexamples/twitter.json` and retains simdjson's terms.

## Fork-authored files

Everything outside `src/` and `testdata/`, except `README.upstream.md` and `UPSTREAM.sha256`, is fork-authored under Apache-2.0, as granted in `FORK-LICENSE.md`. The five files under `testdata/rfc8259/` reproduce RFC 8259 section 13 examples, which the RFC permits to be freely distributed. The other 16 fixtures and `testdata/README.md` are fork-authored under Apache-2.0. `README.upstream.md` is a byte-identical copy of upstream's README; its content is simdjson's. `README.upstream.md` and `UPSTREAM.sha256` are package records also covered by this fork's Apache-2.0 grant. No upstream author is attributed with fork-authored code.

| Group | Paths | SPDX on line 1 |
|---|---|---|
| Build | `build.zig`, `build.zig.zon`, `build_support/graph.zig` | All three |
| C ABI and facade | `zig/bridge.h`, `zig/bridge.cc`, `zig/root.zig`, `zig/translate.h` | None |
| Runtime | `runtime/loader.zig`, `runtime/generate.zig`, `runtime/sync.c`, `runtime/sync.h`, `runtime/graph.zig`, `runtime/library.zig` | All six |
| Tests and example | `tests.zig`, `smoke.zig` | Both |
| Consumer | `consumer/build.zig`, `consumer/src/main.zig`, `consumer/build.zig.zon` | First two; `consumer/build.zig.zon` has a comment instead |
| Integrity and matrix | `tools/check-provenance.sh`, `cross-test.profile.sh`, `.gitignore` | The scripts; `.gitignore` has comments |
| Packaging | `package.nix`, `flake.nix`, `devenv.nix`, `devenv.yaml`, `.envrc` | The three `.nix` files; the others have comments |
| Records | `UPSTREAM.md`, `UPSTREAM.sha256`, `README.md`, `README.upstream.md`, `README.zig.md`, `NOTICE.md`, `CHANGELOG.md`, `FORK-NOTES.md`, `FORK-LICENSE.md`, `testdata/README.md` | Documentation and manifest records; no SPDX line |

Four runtime files are copied from the workspace's shared runtime core, not authored in this package: `runtime/loader.zig`, `runtime/generate.zig`, `runtime/sync.c`, and `runtime/sync.h`. Their changes are SPDX identifiers and an include-guard rename in `sync.h`.

The C ABI seam files `zig/bridge.h`, `zig/bridge.cc`, and `zig/root.zig` have no SPDX line. The Apache-2.0 grant in `FORK-LICENSE.md` covers them as it covers the other fork-authored files.

Apache-2.0 patent grant:

> Subject to the terms and conditions of this License, each Contributor hereby
> grants to You a perpetual, worldwide, non-exclusive, no-charge, royalty-free,
> irrevocable (except as stated in this section) patent license to make, have
> made, use, offer to sell, sell, import, and otherwise transfer the Work, where
> such license applies only to those patent claims licensable by such Contributor
> that are necessarily infringed by their Contribution(s) alone or by
> combination of their Contribution(s) with the Work to which such Contribution(s)
> was submitted. If You institute patent litigation against any entity (including
> a cross-claim or counterclaim in a lawsuit) alleging that the Work or a
> Contribution incorporated within the Work constitutes direct or contributory
> patent infringement, then any patent licenses granted to You under this License
> for that Work shall terminate as of the date such litigation is filed.

Apache-2.0 limitation for GPLv3 distributions:

> Copyright and related rights in the Work are automatically licensed under the
> terms and conditions stated above. Notwithstanding the above, nothing in this
> License shall be interpreted as limiting Your obligations under section 6 of
> the GNU General Public License version 3 ("GPLv3"), if You distribute the Work
> or any Derivative Works under a license that complies with GPLv3.
