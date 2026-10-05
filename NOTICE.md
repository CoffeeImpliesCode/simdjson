# NOTICE.md — the per-file licence inventory

This file is the **inventory**: which bytes in this repository are simdjson's,
which are this fork's, which are a third worker's, and which term covers each.
[`FORK-LICENSE.md`](FORK-LICENSE.md) is the **grant**: the Apache-2.0 licence the
owner authorised over this fork's own files, its authority, and the one
file-level provenance that is not simply "written here".

A single label would be wrong for this package, and `AGENTS.md` §8 says so: a
tree is not licensed by its most prominent file. Three things make that concrete
here, and all three are tabulated below.

1. **simdjson is dual Apache-2.0 / MIT, and upstream offers a choice.**
   `src/README.md:269` says so in upstream's own words: "This code is made
   available under the Apache License 2.0 as well as under the MIT License. As a
   user, you can pick the license you prefer." Both texts ship unaltered.
2. **simdjson itself vendored five third-party works**, each keeping the term in
   its own file. Those terms are not reduced to either of simdjson's.
3. **One carried file has no notice at all**, and one has a notice that only
   applies behind a preprocessor guard.

Nothing in this file re-grants, narrows, widens, conditions or relabels any
upstream term. Nothing here asserts that any person named in this repository
wrote, reviewed, approved or endorsed a line of fork code.

---

## 1. simdjson's own grant: two licences, offered as a choice

| file | term | copyright |
|---|---|---|
| `src/LICENSE` | **Apache License, Version 2.0** -- complete text, `Terms and Conditions` at `:1-176`, `Appendix` at `:178-201` | `Copyright 2018-2025 The simdjson authors` |
| `src/LICENSE-MIT` | **MIT License** -- complete text | `Copyright 2018-2025 The simdjson authors` |
| `src/README.md:269-277` | the statement that the user may pick either | -- |

The two are an **alternative**, not a conjunction: a consumer picks one. Both
texts ship because reducing a dual grant to one label is the mistake this file
exists to prevent, and because a downstream who chooses MIT must be able to read
the MIT text without fetching it.

`src/LICENSE:176` reads `END OF TERMS AND CONDITIONS`. Everything after it is the
*Appendix* ("How to apply the Apache License to your work"), which is
instructional scaffolding and not part of the grant — so shipping that one file
discharges Apache-2.0 §4(a) for the carried work and for this fork's work alike.

The Apache-2.0 patent grant is `src/LICENSE:73-87`, §3, and it is quoted in full
in section 5 below because §4 of that licence obliges a redistributor to carry it.

**Authors credited for the carried tree.** `src/AUTHORS` and `src/CONTRIBUTORS`
are upstream's own lists and ship as source. Daniel Lemire, Geoff Langdale,
John Keiser, Paul Dreik, Martin Moene, Toni Ronkko, Junekey Jeon, Lars Melchior
and Jan Tojnar are named here because they wrote the files they are named for in
section 3, and for **nothing else**. No attribution of fork code to any of them
is made or implied anywhere in this repository.

---

## 2. The five vendored third-party works

These travel inside `src/`, each keeping the term written in its own file. This
package neither adds to nor subtracts from any of them, and none of them is
covered by either of simdjson's own licences. `src/README.md:269-277` names the
first four in prose; the fifth is not named there and is recorded here because
its own header is the only place it appears.

| # | file(s) | what | term | attribution |
|---|---|---|---|---|
| 1 | `src/include/simdjson/internal/fast_float.h` | **fast_float v8.2.10**, vendored by `src/tools/vendor_fast_float.sh` | **three-way, at the user's option**: Apache-2.0 **or** MIT **or** BSL-1.0. The file's own header states "Licensed under Apache-2.0 OR MIT OR BSL-1.0, at your option" and then reproduces the MIT notice in full. | the file's header names "simdjson_fast_float by Daniel Lemire", "simdjson_fast_float by Joao Paulo Magalhaes", and "with contributions from" Eugene Golushkov, Maksim Kita, Marcin Wojdyr, Neal Richardson, Tim Paine, Fabio Pellacini, Lenard Szolnoki, Jan Pharago, Maya Warrier, Taha Khokhar, Anders Dalvander. The `fast_float` authors generally are the upstream project's. |
| 2 | `src/include/simdjson/nonstd/string_view.hpp` | **string-view lite 1.8.0** by Martin Moene, `https://github.com/martinmoene/string-view-lite` | **Boost Software License, Version 1.0**, stated in the file's first lines with the URL | "Copyright 2017-2020 by Martin Moene" |
| 3 | `src/src/to_chars.cpp` | **Dragonbox**, a de-templated port of Junekey Jeon's reference `simple_dragonbox`, `https://github.com/jk-jeon/dragonbox` | **Boost Software License, Version 1.0**. The original is dual-licensed (Apache-2.0-with-LLVM-exceptions or BSL-1.0) and `src/README.md:275` says so; **this port is used under the BSL-1.0 terms**, as the file's own comment states. | "Copyright 2020-2025 Junekey Jeon (and contributors)." The file also cites "Junekey Jeon, 'Dragonbox: A New Floating-Point Binary-to-Decimal Conversion Algorithm' (2022)". |
| 4 | `src/src/internal/isadetection.h` | runtime CPU feature detection, derived from PyTorch's `torch/lib/TH/generic/simd/simd.h` and marked **"Highly modified"** | **3-clause BSD** (BSD-3-Clause). Both conditions and the disclaimer are in the file. | the file's header carries the full PyTorch TH/SYCL copyright list: Facebook, Inc (Adam Paszke, 2016-; Soumith Chintala, 2014-), Idiap Research Institute (Ronan Collobert, 2011-2014; Samy Bengio 2001-2004 and 2006-2010), Deepmind Technologies (Koray Kavukcuoglu, 2012-2014), NEC Laboratories America (Koray Kavukcuoglu 2011-2012; Ronan Collobert, Leon Bottou, Iain Melvin, Jason Weston 2006-2010), NYU (Clement Farabet, 2011-2013) |
| 5 | `src/windows/toni_ronnko_dirent.h` | **dirent** for Microsoft Visual Studio, used through `src/windows/dirent_portable.h` | **MIT**, stated in the file's own header. `src/README.md:271` says this file "is outside our library code". | "Copyright (C) 1998-2019 Toni Ronkko". The header gives `https://github.com/tronkko/dirent`. |

Two facts about item 1 that matter to a redistributor:

* It is a **vendored, modified copy**, not an upstream file. The two edits are
  applied by `src/tools/vendor_fast_float.sh` and are described in the vendored
  file's own header: every `fast_float` name is rewritten (`fast_float` namespace
  → `simdjson_fast_float`, `FASTFLOAT_*` → `SIMDJSON_FASTFLOAT_*`) so the copy
  cannot collide with a copy of fast_float the surrounding program includes for
  itself, and the accented letters in the attribution comments are folded to ASCII
  to keep upstream's tree ASCII-only. The script is carried unmodified, so the
  transformation is reproducible.
* Because it is **vendored rather than included by the build**, upstream's own
  Apache-2.0/MIT terms do not reach it, and neither do this package's. The
  file's own triple grant is the whole of its terms, and that is why a
  redistributor of `libsimdjson` owes fast_float's attribution separately from
  simdjson's.

Item 3 is the one where the reduced label would be wrong in both directions: the
*original* Dragonbox is dual Apache-2.0-with-LLVM-exceptions-or-BSL-1.0, and the
*port* is BSL-1.0 only. A downstream who read `src/README.md:275` and assumed
Apache-2.0-LLVM-exceptions applies to this port would be wrong.

---

## 3. Per-file exceptions inside the carried tree

### `src/windows/getopt.h` — two notices, one of them conditional on use

This is the only carried file whose own header records that it was **modified by
upstream**, and it carries two separate grants in one file:

```
/** This file has been modified by D. Lemire for use in simdjson. **/
/* From https://github.com/skandhurkat/Getopt-for-Visual-Studio/blob/master/getopt.h */
```

* An **ISC-style grant** from Todd C. Miller, copyright 2002, with the
  "Permission to use, copy, modify, and distribute this software for any purpose
  with or without fee is hereby granted" wording and the AS-IS disclaimer. The
  file records that it is "part of the mingw-w64 runtime package".
* A **BSD-style grant** from The NetBSD Foundation, copyright 2000, covering
  "software contributed to The NetBSD Foundation by Dieter Baron and Thomas
  Klausner", with its three conditions and disclaimer.
* A **DARPA sponsorship acknowledgement** (Contract Number F39502-99-1-0512) in
  the Todd C. Miller block.

This file is not a dependency of the compiled core: it is a Windows tool header
in upstream's `src/windows/` tree. This package's build compiles exactly
`src/src/simdjson.cpp` and `zig/bridge.cc`, so nothing this package delivers
links it. It ships because the whole upstream tree ships, and its notices are
recorded here because a redistributor who ships `src/` still carries them.

### `src/windows/dirent_portable.h` — no notice of its own

It is a five-line dispatch header with no copyright line: it includes the system
`<dirent.h>` off Windows and `toni_ronnko_dirent.h` on it. The term covering it
is therefore the term of the file it includes, which is item 5 above (MIT, Toni
Ronkko). Recorded here because "the file with no notice" is exactly the fact a
scanner cannot derive on its own.

### `src/dependencies/CMakeLists.txt` — the only file in that directory

`src/dependencies/` contains one file, a CMake script that fetches simdjson's
optional test dependencies. It carries simdjson's own terms. Recorded because a
reader who expects a `vendor/` directory there will not find one, and the reason
is that this package vendors nothing outside `src/` — the fast_float copy in item
1 is already committed into `src/include/`, not fetched at build time.

---

## 4. The three files deliberately absent

```
src/singleheader/simdjson.h
src/singleheader/simdjson.cpp
src/singleheader/singleheader.zip
```

Upstream's **generated** single-header amalgamation, the output of
`src/singleheader/amalgamate.py` (which *is* carried, unmodified). Their absence
is the package's design, not an omission: this build compiles upstream's own
`src/src/simdjson.cpp` directly, so an amalgamated copy of the same sources
beside it would be a second, buildable, drifting copy of the core. `UPSTREAM.md`,
"The generated amalgamation is deliberately not shipped", is the record, and
`tools/check-provenance.sh` fails if any of the three reappears.

A redistributor therefore owes no obligation for these three, and the shipped
artifact contains none of their bytes.

---

## 5. The Apache-2.0 obligations, and how this package meets each

Apache-2.0 §4 (`src/LICENSE:89-128`) states four conditions on redistribution.
This package meets each as follows, and a downstream who ships any part of this
package must meet them too.

### §4(a) — give recipients a copy of the Licence

`src/LICENSE` is the complete Apache License 2.0 text, installed verbatim at
`share/licenses/simdjson/LICENSE` by `zig build` and shipped in this repository at
its original path. `src/LICENSE-MIT` is the complete MIT text, installed at
`share/licenses/simdjson/LICENSE-MIT`. For the fork's own files, `FORK-LICENSE.md`
reproduces the substantive grants in prose and points at `src/LICENSE` for the
full text — and since the fork's grant adds no condition, that one file is the
licence for both the carried work and the fork's work.

### §4(b) — cause modified files to carry prominent notices stating the change

This package **modifies no file under `src/`.** All 771 are byte-identical to the
release tarball, and `UPSTREAM.sha256` records a SHA-256 for each one; a changed
byte is a failing `tools/check-provenance.sh` run, not a silent diff.

Where upstream itself modified a third-party file, that file says so in its own
header and this file records it: `src/windows/getopt.h:2` reads "This file has
been modified by D. Lemire for use in simdjson", and
`src/include/simdjson/internal/fast_float.h:1-2` records the vendoring and names
the script that performs it.

The fork-authored files are new files, so §4(b) asks for no marking of a modified
upstream file — and the fork's own files carry `// SPDX-License-Identifier:
Apache-2.0` where they are source. `CHANGELOG.md` is the change statement this
package points at.

### §4(c) — retain all copyright, patent, trademark and attribution notices from the Source form

Every carried file is shipped unmodified, so every notice it carries is retained
by construction. `src/AUTHORS`, `src/CONTRIBUTORS` and `src/README.md` ship as
source; the five vendored third-party notices in section 2 above are all inside
files that ship; and `src/.github/` ships in full, including all 45 of upstream's
workflows, which are carried because they are upstream's bytes and are **not**
executed here — they are not at this repository's `.github/workflows/` path. The
one workflow this repository *does* run is `.github/workflows/verify.yml`, which
is entirely this fork's and says so in its own header.

### §4(d) — if the Work includes a `NOTICE` text file, include the attribution notices it contains

**This file is that `NOTICE`.** Upstream ships no file named `NOTICE`, and none is
invented on its behalf; what upstream ships is `README.upstream.md` (preserved at
the package root, byte-identical to `src/README.md`), which contains the
attribution paragraphs reproduced in section 2 above. A downstream redistributing
the compiled `libsimdjson` must carry the attribution of the five vendored works
this file names, because those notices live in source files a binary-only
redistribution would not otherwise include.

### The patent grant and its termination

`src/LICENSE:73-87`, §3, is the grant this package's obligation turns on. Its
substance, in this package's own words:

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

**The termination clause is the part a downstream must know about**: the grant
ends *automatically* for the Work that is the subject of the suit, on the date the
suit is filed, with no notice and no cure. It is not a licence to be withdrawn;
it expires.

And the limitation that closes §2 (`src/LICENSE:70-72`, the last paragraph of the
grant):

> Copyright and related rights in the Work are automatically licensed under the
> terms and conditions stated above. Notwithstanding the above, nothing in this
> License shall be interpreted as limiting Your obligations under section 6 of
> the GNU General Public License version 3 ("GPLv3"), if You distribute the Work
> or any Derivative Works under a license that complies with GPLv3.

simdjson is not GPLv3-licensed, so that reference is inert here, and this package
makes no claim under it.

---

## 6. This fork's own files, and what covers them

Everything not under `src/`, not under `testdata/`, and not `README.upstream.md`
or `UPSTREAM.sha256` is fork-authored and is released under the **Apache License,
Version 2.0** under the owner's authorisation. The grant, its authority and its
limits are in [`FORK-LICENSE.md`](FORK-LICENSE.md); the identifier is the bare
`Apache-2.0` with no `LicenseRef-` wrapper, because the grant adds no condition.

That is a **subset** of what upstream already offers, not a new obligation, and
no fork addition is attributed to any upstream author.

| group | paths | SPDX on line 1? |
|---|---|---|
| Build | `build.zig`, `build.zig.zon`, `build_support/graph.zig` | `build.zig` and `build_support/graph.zig` yes; `build.zig.zon` yes |
| C ABI seam and facade | `zig/bridge.h`, `zig/bridge.cc`, `zig/root.zig`, `zig/translate.h` | **none of the four** — see below |
| Runtime route | `runtime/loader.zig`, `runtime/generate.zig`, `runtime/sync.c`, `runtime/sync.h` (all four **copied** from the workspace's shared core), `runtime/graph.zig`, `runtime/library.zig` | all six yes |
| Tests and example | `tests.zig`, `smoke.zig` | yes |
| Consumer package | `consumer/build.zig`, `consumer/src/main.zig` | yes; `consumer/build.zig.zon` carries a comment instead |
| Integrity and matrix | `tools/check-provenance.sh`, `cross-test.profile.sh`, `.github/workflows/verify.yml`, `.gitignore` | the two scripts yes; `.gitignore` and the workflow carry comments |
| Packaging | `package.nix`, `flake.nix`, `devenv.nix`, `devenv.yaml`, `.envrc` | the three `.nix` files yes; `devenv.yaml` and `.envrc` carry comments |
| Records | `UPSTREAM.md`, `README.md`, `README.zig.md`, `NOTICE.md`, `CHANGELOG.md`, `FORK-NOTES.md`, `FORK-LICENSE.md`, `testdata/README.md` | none — documentation records, named here so their absence of a tag reads as a decision |

**The three seam files carry no SPDX line**, and that is recorded rather than
glossed over: `zig/bridge.h`, `zig/bridge.cc` and `zig/root.zig` open on their own
documentation comments rather than on a licence header. The grant in
`FORK-LICENSE.md` and in this file covers them exactly as it covers the files that
do carry the identifier. A missing SPDX line does not narrow a grant; it only
makes the grant invisible to a tool that reads nothing but the first line. Any
later wave that adds a header to those three must use `Apache-2.0` and must not
restate the grant differently.

**Four of the runtime files are copied, not authored here.**
`runtime/loader.zig`, `runtime/generate.zig`, `runtime/sync.c` and
`runtime/sync.h` descend from the workspace's shared runtime core, which is
first-party code with no upstream provenance. The differences from the originals
are the SPDX identifier, plus an include-guard rename in `sync.h` that each SDK
in this workspace requires. `FORK-LICENSE.md` §5 is the full record, including the
boundary a later wave must not cross: if the core ever acquires provenance, an
edited SPDX line becomes a failure to retain the notice rather than a
re-election.

### `testdata/` — twenty-two records, and one of them upstream's

`UPSTREAM.sha256`'s last 22 records cover `testdata/`, totalling 645673 bytes.
They are not upstream files, and they are not all this fork's either:

* `testdata/large/twitter.json` is a **byte-identical copy of upstream's own
  `src/jsonexamples/twitter.json`** and is therefore **simdjson's**, under
  simdjson's terms. It is the one fixture that carries an upstream obligation.
* `testdata/rfc8259/` (5 files) are transcribed from **RFC 8259 section 13,
  "Examples"**, a published standard of the IETF. RFC 8259 §1 states that the
  examples "may be freely distributed"; no upstream copyright in the text of
  section 13 attaches to them.
* The other 16 are **fork-authored byte sequences**, licensed Apache-2.0 under
  this package's grant.

`testdata/README.md` gives each one's origin and the behaviour it exists for. It
is the authoritative list and is what `tools/check-provenance.sh` checks against.

### `README.upstream.md` and `UPSTREAM.sha256`

Both are this package's records and both are Apache-2.0 under this grant.
`README.upstream.md` is a byte-preserved **copy of simdjson's own `README.md`** —
its content is simdjson's, and it is kept unmodified as the record it is;
`tools/check-provenance.sh` fails if the two ever differ. `UPSTREAM.sha256` is 793
digests over immutable carried bytes and is this package's own file.

---

## 7. What this package ships, and what a redistributor still owes

The installed tree is, in full:

```
$prefix/lib/libsimdjson.a                    (or libsimdjson.so.34.0.0 + .so.34 + .so)
$prefix/include/simdjson.h
$prefix/include/simdjson/                     234 files, upstream's whole public tree
$prefix/include/simdjson_bridge.h             this fork's C ABI
$prefix/lib/pkgconfig/simdjson.pc             generated
$prefix/share/licenses/simdjson/LICENSE       upstream's Apache-2.0 text
$prefix/share/licenses/simdjson/LICENSE-MIT   upstream's MIT text
$prefix/share/licenses/simdjson/NOTICE.md     this file
$prefix/share/licenses/simdjson/FORK-LICENSE.md
$prefix/share/licenses/simdjson/FORK-NOTES.md
$prefix/share/licenses/simdjson/UPSTREAM.md
$prefix/share/licenses/simdjson/CHANGELOG.md
```

`build.zig` is the only writer of that directory. A second writer is how one
output ends up with two licence records that disagree about what they cover.

A downstream who ships the compiled `libsimdjson`, the static
`libsimdjson.a`, or any header installed from `include/simdjson/` **still owes
every notice the carried tree carries**, including the five vendored third-party
terms in section 2 above. Nothing in this repository discharges that.

---

## 8. What this file does not do

* It does not re-license, sublicense, condition or add a requirement to any file
  under `src/`. Those files keep their dual Apache-2.0/MIT grant and the per-file
  exceptions their own text carries.
* It does not relabel either upstream licence text. Both ship byte for byte as
  upstream wrote them.
* It does not assert that any upstream author reviewed, approved or is affiliated
  with this fork.
* It does not reduce the five vendored third-party terms in section 2 to
  simdjson's own dual grant, and it does not reduce either of simdjson's two
  terms to the other.
* It is not a legal opinion. It is an inventory of what is in this repository and
  which file says what about it, so that a reader can check any claim here against
  the file it names.

## Related records

* [`FORK-LICENSE.md`](FORK-LICENSE.md) — the grant over this fork's own files,
  its authority, and the four copied-from-core runtime files.
* [`UPSTREAM.md`](UPSTREAM.md) — the pin, both version numbers, every build
  deviation with the upstream line it comes from, and what is compiled but not
  wrapped.
* [`UPSTREAM.sha256`](UPSTREAM.sha256) — 793 digests: 771 under `src/`, 22 under
  `testdata/`.
* [`testdata/README.md`](testdata/README.md) — each fixture's origin and purpose.
* [`src/LICENSE`](src/LICENSE) and [`src/LICENSE-MIT`](src/LICENSE-MIT) — both
  upstream texts, complete and unaltered.
* [`tools/check-provenance.sh`](tools/check-provenance.sh) — the gate that checks
  the byte, file-set and licence claims in this file.