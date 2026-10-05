# FORK-LICENSE.md — the grant for this fork's own files

[`NOTICE.md`](NOTICE.md) is the inventory: which bytes in this repository are
simdjson's, which are this fork's, which are a third worker's, and which term
covers each. This file is the **grant** itself, for the second group only.

Everything this fork has written so far is `PENDING-VERIFICATION`: no gate has
run it, and nothing below asserts a build, a test or a digest that was not read
out of a file.

## 1. The native source is not covered by anything below

The **771 files** under `src/`, totalling **10,317,170 bytes**, are simdjson
5.0.2's, whole, extracted from the official release tarball and never edited.
They are **dual Apache-2.0 / MIT**: `src/LICENSE` is the Apache License 2.0 and
`src/LICENSE-MIT` is the MIT License, both carrying `Copyright 2018-2025 The
simdjson authors`. `src/README.upstream.md` — the byte-preserved copy at the
package root — says the same at its lines 269-277 and names four further
third-party terms that travel with individual files.

Nothing in this file re-grants, narrows, widens, conditions or relabels any of
that, and nothing here asserts that **The simdjson authors**, Daniel Lemire,
Geoff Langdale, John Keiser, Paul Dreik, Martin Moene, Toni Ronkko, Junekey
Jeon, Lars Melchior, Jan Tojnar or any other person named anywhere in the
vendored tree wrote, reviewed, approved or endorses a line of fork code. Those
people are credited in `NOTICE.md` for the files they actually wrote and for
nothing else.

## 2. The fork-authored material

Everything else in this repository is fork work, licensed under the Apache
License 2.0 on the owner's authorization.

### The grant

```
SPDX-License-Identifier: Apache-2.0
```

The fork-authored files listed in section 4 are released under the **Apache
License, Version 2.0**, with no additional term, no additional condition and no
`LicenseRef-` wrapper. The complete, unmodified text of that licence ships in
this package at **`src/LICENSE`**, whose *Terms and Conditions* occupy
`src/LICENSE:1-176` and whose *Appendix* ("How to apply the Apache License to
your work") occupies `src/LICENSE:178-201`. That appendix is instructional
scaffolding, not part of the grant — `src/LICENSE:176` reads `END OF TERMS AND
CONDITIONS` — so shipping that one file discharges §4(a) for the carried work
and for the fork's work alike.

The substantive grants are reproduced here so that a reader of this file does
not have to hold the other one open:

* **`src/LICENSE:66-71`, §2, Grant of Copyright License.** "each Contributor
  hereby grants to You a perpetual, worldwide, non-exclusive, no-charge,
  royalty-free, irrevocable copyright license to reproduce, prepare Derivative
  Works of, publicly display, publicly perform, sublicense, and distribute the
  Work and such Derivative Works in Source or Object form."
* **`src/LICENSE:73-87`, §3, Grant of Patent License.** A perpetual, worldwide,
  non-exclusive, no-charge, royalty-free, irrevocable patent licence, limited to
  claims licensable by the contributor and necessarily infringed by that
  contribution alone or in combination with the Work, **terminating on the date
  patent litigation is filed** — the clause quoted in full in `NOTICE.md`.
* **`src/LICENSE:89-128`, §4, Redistribution.** The four conditions are
  `(a)` give recipients a copy of the Licence, `(b)` cause modified files to
  carry prominent notices stating the change, `(c)` retain all copyright,
  patent, trademark and attribution notices from the Source form, `(d)` if the
  Work includes a `NOTICE` text file, include the attribution notices it
  contains. How this package meets each is tabulated in `NOTICE.md`.

### Authority for that grant

The owner of this workspace authorized per-project licensing for fork-authored
additions as part of the SDK contract migration, with the term chosen per
project to match that project's primary upstream terms where that is
appropriate. simdjson's primary upstream term is the Apache License 2.0, so
**Apache-2.0** is the choice. The authorization is a workspace rule recorded in
the workspace's own `AGENTS.md` §8 and it is restated here and in `NOTICE.md`.
The term above is the **owner's**, reached by that authorization. It is not
borrowed from simdjson, not derived from it, and does not reach a single byte
under `src/`.

The owner is not named and no individual copyright holder is invented. No
copyright line is asserted for the fork-authored files beyond the SPDX
identifier, because the grant is recorded here rather than stamped into files
that upstream never saw.

### Why Apache-2.0 and not the upstream `OR`

Upstream offers a **choice**: Apache-2.0 **or** MIT, in upstream's own words at
`src/README.md:269` — "This code is made available under the Apache License 2.0
as well as under the MIT License. As a user, you can pick the license you
prefer."

The fork-authored files are **not** offered that choice. They are covered by
the Apache-2.0 grant and by nothing else, for two reasons that are worth stating
rather than leaving implicit:

1. **Upstream's terms grant nothing to fork-authored files.** `src/LICENSE` and
   `src/LICENSE-MIT` grant rights in "the Work", which upstream defines at
   `src/LICENSE:9-14` as the work of authorship **"marked as subject to this
   License"** — that is, upstream's own marked files. A Zig build script, a
   `static_assert` over `simdjson::error_code`, and a documentation record are
   not marked by anyone as subject to upstream's licence, are not upstream's
   Contributions under `src/LICENSE:60-63`, and therefore fall under neither
   upstream grant. Claiming otherwise would be claiming rights this repository
   does not have.
2. **The election is per package, not per file group.** The workspace rule is to
   pick the term matching the project's primary upstream terms. simdjson's
   primary term is Apache-2.0, so the fork's additions are Apache-2.0 only. A
   downstream that would rather have MIT for the fork's own files has no route
   to it here and is not offered one.

**Nothing here attributes a fork addition to an upstream author.** Not to
simdjson's authors, not to the authors of any vendored third party, not to the
authors of the workspace's own shared runtime core. See section 5 for that last
case, which is a distinct and separately-recorded provenance.

## 3. The SPDX identifier, and where it is actually written

The registered identifier is the bare `Apache-2.0` with no `LicenseRef-`
wrapper, because the grant adds no conditions to the plain Apache-2.0: no
additional restriction, no additional notice requirement beyond §4, and no
linking exception. A `LicenseRef-` would misrepresent a plain grant as a
variant one, the same distinction `lua/FORK-LICENSE.md` draws for MIT.

Which fork-authored file carries it on disk is a separate, **observable** fact,
and it is not uniform:

| Fork file | SPDX identifier on line 1 | Status |
|---|---|---|
| `runtime/loader.zig:1` | `// SPDX-License-Identifier: Apache-2.0` | `OBSERVED` on disk |
| `runtime/generate.zig:1` | `// SPDX-License-Identifier: Apache-2.0` | `OBSERVED` on disk |
| `runtime/sync.c:1` | `/* SPDX-License-Identifier: Apache-2.0` | `OBSERVED` on disk |
| `runtime/sync.h:1` | `/* SPDX-License-Identifier: Apache-2.0` | `OBSERVED` on disk |
| `runtime/graph.zig:1` | `// SPDX-License-Identifier: Apache-2.0` | `OBSERVED` on disk |
| `runtime/library.zig:1` | `// SPDX-License-Identifier: Apache-2.0` | `OBSERVED` on disk |
| `zig/bridge.h:1-4` | **none** — opens on a `/* The simdjson bridge: …` block comment | `OBSERVED` absent |
| `zig/bridge.cc:1-3` | **none** — opens on `// Implementation of the \`extern "C"\` bridge …` | `OBSERVED` absent |
| `zig/root.zig:1-4` | **none** — opens on `//! Public Zig surface of the simdjson fork.` | `OBSERVED` absent |

Six of the nine carry the identifier; **three do not**. That is recorded rather
than glossed: a scanner reading `zig/root.zig` finds no SPDX tag and should find
a recorded reason rather than an apparent gap. The reason is that the seam files
and the facade were written before the owner's per-package election was
settled, and their opening comments are the seam's own documentation rather than
a licence header. The grant in this file and in `NOTICE.md` covers them exactly
as it covers the six that do carry the identifier — **a missing SPDX line does
not narrow a grant**, it only makes the grant invisible to a tool that reads
nothing but the first line. Any later wave that adds a header to those three
must use this file's identifier and must not restate the grant differently.

The remaining fork-authored files are documentation, prose records, data,
licence material and packaging, and they carry no SPDX line either. Each is
named in `NOTICE.md`, so "no identifier in `UPSTREAM.md`" reads as a recorded
decision and not as a gap. That is the same treatment `lua/FORK-LICENSE.md`
gives its documentation and digest records.

## 4. The full file list

Every path below is fork-authored and is Apache-2.0 under this grant. Nothing
else in this repository is.

### Build, manifest and build support

| Path | What it is |
|---|---|
| `build.zig` | the Zig build: the `libsimdjson` archive, the translated `c` module, the six-target `check` matrix, and the entry points |
| `build.zig.zon` | the package manifest — `.name`, `.fingerprint`, `.version`, `.paths` |
| `build_support/graph.zig` | per-target assembly of the module, flags and archive from the pinned upstream facts |

### The C ABI seam and the Zig facade

| Path | What it is |
|---|---|
| `zig/bridge.h` | plain C99 with `extern "C"` guards: the eleven-entry-point surface the Zig module translates |
| `zig/bridge.cc` | the C++ over that surface; one validation, at most one upstream call, and a copy out per entry point |
| `zig/root.zig` | the public Zig surface: `LoadSource`, `load`, `Error`, `parse`, `Document`, `Walk`, `Value`, `Array`, `Object` and the version and implementation accessors |

### The runtime-loading route

| Path | What it is | Provenance |
|---|---|---|
| `runtime/loader.zig` | the reusable loader core | **copied** — section 5 |
| `runtime/generate.zig` | the build-time dispatch generator | **copied** — section 5 |
| `runtime/sync.c` | the statically initialized mutex and condition variable per `RT_SYNC_PREFIX`, weak so repeated imports share them | **copied** — section 5 |
| `runtime/sync.h` | the process-global mutex, wake-up and thread identity the descriptor binds | **copied** — section 5 |
| `runtime/graph.zig` | the build half of the route: three modules and one generated file | authored here |
| `runtime/library.zig` | this SDK's descriptor — the synchronization symbols it needs and the load-time checks it makes | authored here |

### Tests, example, consumer

| Path | What it is |
|---|---|
| `tests.zig` | the behavioural test root |
| `smoke.zig` | the smoke example |
| `consumer/*` | the separate package that consumes this one by relative path — its `build.zig`, `build.zig.zon`, the consumer source and its own records |

### Integrity, matrix and CI

| Path | What it is |
|---|---|
| `tools/check-provenance.sh` | reads `UPSTREAM.sha256`, re-hashes every recorded byte, rejects the three generated amalgamation files reappearing, and rejects `README.upstream.md` drifting from `src/README.md` |
| `cross-test.profile.sh` | settings for the `cross-test` matrix driver: the build step and build defaults, no target list and no machine path |
| `.github/workflows/verify.yml` | this fork's verification workflow. **Not** upstream's: every file under `src/.github/` is carried untouched, including all 45 workflows there |

### Packaging

| Path | What it is |
|---|---|
| `package.nix` | standalone Nix packaging |
| `flake.nix`, `devenv.nix`, `devenv.yaml`, `.envrc` | the development environment |

### Records and documentation

| Path | What it is |
|---|---|
| `README.md` | this fork's README. Upstream's bytes are preserved at `README.upstream.md` |
| `README.zig.md` | the Zig interface documentation |
| `UPSTREAM.md` | provenance: both pins, both version numbers, what ships and what does not, and every build deviation with the upstream line it comes from |
| `UPSTREAM.sha256` | 793 digests — 771 under `src/`, 22 under `testdata/` |
| `NOTICE.md` | the per-file inventory, both upstream grants, the embedded third-party notices and the Apache-2.0 §4 obligations |
| `FORK-LICENSE.md` | this file |
| `FORK-NOTES.md` | the dated record of decisions that are this fork's rather than upstream's |
| `CHANGELOG.md` | the change statement §4(b) points at |
| `testdata/README.md` | where each of the 22 fixtures came from and what each is for |

**Presence on disk.** When this file was written, `runtime/*`, `zig/*`,
`UPSTREAM.sha256` and `README.upstream.md` were present and were read;
`build.zig`, `build.zig.zon`, `build_support/graph.zig`, `tests.zig`, `smoke.zig`,
`consumer/*`, `tools/*`, `cross-test.profile.sh`, the Nix and devenv files and
the records other than this one were being written concurrently and were **not
observed** at the time. Their absence from disk is a fact about the moment of
writing and says nothing about the grant, which covers each by path. All of them
are `PENDING-VERIFICATION`.

## 5. Four files copied from the workspace's shared runtime core

`runtime/loader.zig`, `runtime/generate.zig`, `runtime/sync.c` and
`runtime/sync.h` are **not independently authored for this package**. They are
the workspace's shared runtime core, copied forward. This is recorded because it
is a distinct provenance, not because it changes the grant.

### Where they came from

The core lives at `lua/runtime/` and is, as `lua/FORK-LICENSE.md` §3 states,
first-party code written for this private workspace: it has **no upstream
provenance**, it is not derived from simdjson or from any third party, and its
MIT identifier in the Lua package is the owner's own election for *that*
package, not a term inherited from anywhere else.

The differences between this package's copies and the Lua originals are exactly
what the contract records, and a `diff` run here confirms it — every hunk, no
others:

| File | Difference from `lua/runtime/<file>` | Lines touched |
|---|---|---|
| `runtime/loader.zig` | the SPDX identifier only: `MIT` → `Apache-2.0` | 1 |
| `runtime/generate.zig` | the SPDX identifier only: `MIT` → `Apache-2.0` | 1 |
| `runtime/sync.c` | the SPDX identifier only: `MIT` → `Apache-2.0` | 1 |
| `runtime/sync.h` | the SPDX identifier only, **and** the include guard `LUA_RUNTIME_SYNC_H` → `SIMDJSON_RUNTIME_SYNC_H` in the `#ifndef`, the `#define` and the closing `#endif` comment | 1, 7, 8, 40 |

That is the whole of the modification. **No logic changed, no comment other
than the SPDX line changed, and the guard rename is required**: each SDK in this
workspace supplies its own `RT_SYNC_PREFIX`, and a shared guard macro would let
two SDKs' copies of the header collide in one translation unit. The rename is
therefore not cosmetic, and a wave that skipped it would produce a
redefinition — see the boundary in the next subsection.

### Why the identifier change is the owner's election, not a relicensing of someone else's work

The bytes descend from a file the same private owner already released under MIT
in the Lua package. MIT places no restriction on relicensing one's own
copyright, and this repository's sole other holder of those bytes is that same
owner, so the Apache-2.0 election in section 2 governs the copies as they stand
here. **The Lua package is untouched by it**: `lua/runtime/loader.zig:1` still
reads `MIT`, and the terms under which the Lua package is distributed do not
change because a later package copied the file with a different identifier.

### The boundary a later wave must not cross

**Condition.** The four files are copied core, and the copy is licensed by
electing an identifier on line 1 and changing nothing else.

**Symptom.** If the shared runtime core ever acquires provenance — if it is
vendored from an external upstream, or absorbs code from one — then editing one
SPDX line is no longer a re-election, it is a **failure to retain the notice**,
and the copy's licence is not the one this file asserts.

**Fix.** Re-audit the provenance of the core before the next copy, treat any new
external origin as a per-file exception in `NOTICE.md` the way
`src/windows/getopt.h` is one here, and carry the original notice in the copy
rather than replacing it.

**Targets bound.** `runtime/loader.zig`, `runtime/generate.zig`,
`runtime/sync.c`, `runtime/sync.h`. The two other files in `runtime/`,
`graph.zig` and `library.zig`, are this SDK's own and would not be bound by
that change; `library.zig` is where a new core's provider interface would be
adapted.

## 6. What this grant does not do

* It does not re-license, sublicense, condition or add a requirement to any
  file under `src/`. Those files keep the dual Apache-2.0 / MIT grant and the
  per-file exceptions their own text carries.
* It does not relabel either upstream licence text. `src/LICENSE` and
  `src/LICENSE-MIT` ship byte for byte as upstream wrote them, and this fork has
  not edited, shortened, merged or restated either of them. The dual grant
  remains a dual grant, and this file does not reduce it to one label.
* It does not discharge any upstream obligation. A consumer who ships a
  `libsimdjson.so.34.0.0`, a static `libsimdjson.a`, or any header installed
  from `src/include/simdjson/` still owes every notice the carried tree carries,
  including the four embedded third-party terms itemised in `NOTICE.md`.
* It does not assert that any upstream author reviewed, approved or is
  affiliated with this fork.
* It does not extend over `README.upstream.md`, `UPSTREAM.sha256`, `src/` or
  `testdata/`, all four of which are recorded in `NOTICE.md` under their own
  terms. `testdata/large/twitter.json` in particular is a byte-identical copy of
  upstream's own `src/jsonexamples/twitter.json` and is upstream's; the other
  21 fixtures are fork-authored byte sequences and are named individually in
  `NOTICE.md`.
* It does not cover the third-party works that simdjson itself vendored. Those
  keep the terms written inside their own files — fast_float's triple grant, the
  PyTorch-derived BSD-3-Clause, BSL-1.0 from two unrelated authors, ISC and BSD
  from mingw-w64 and NetBSD, and MIT from Toni Ronkko — and this package neither
  adds to nor subtracts from any of them.

## 7. Why a separate file at all

`NOTICE.md` is the inventory: it names every path, says which term covers it,
and for the carried tree says which files carry no notice at all. This file
holds the grant, the authority for it, the limits of it, and the one file-level
provenance that is not simply "written here" — the four copies from the shared
runtime core. Keeping them apart means a downstream can read one file and know
exactly what the fork promises about its own bytes, without having to
reconstruct it from an inventory of 771 third-party files.

## Related records

* `NOTICE.md` — the per-file inventory, both upstream grants, the embedded
  third-party notices, the Apache-2.0 §4 obligations, and the fork-authored
  files with this grant cross-referenced.
* `UPSTREAM.md` — the pinned tag, commit, tarball digest, both version numbers,
  and every build deviation with the upstream source line it comes from.
* `UPSTREAM.sha256` — 793 digests over the immutable carried bytes.