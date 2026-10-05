# Fork notes

Every decision this package took, recorded so that a later wave in another
directory, against another toolchain, or after a re-sync to a different simdjson
release can apply it without re-deriving it.

Each note is **Condition**, **Symptom**, **Cause** where a cause exists, **Fix**,
and **Targets bound** — what the decision is tied to, so a wave that moves to a
different target, a different Zig release or a different upstream tag knows
whether the note still applies or has to be re-derived. A **Status** line closes
each note and says what the note rests on.

**Two gates have run.** Note 22 records the 53-platform matrix as it was red, and
note 23 records the three fixes and the same matrix as it is green; both are
`OBSERVED` and both name their receipts. Every other note here is
`PENDING-VERIFICATION` unless it says `SOURCE-CONFIRMED`, which means the fact
was read out of a file in this repository and names the file and line. There is
no `VERIFIED` in this file. Nothing else here is a receipt.

## Evidence vocabulary, as used below

| word | meaning |
|---|---|
| `OBSERVED` | a command ran and its output is quoted with the receipt path. Only notes 22 and 23 claim this. |
| `VERIFIED` | a driver-observed gate passed. Nothing in this file claims this. |
| `SOURCE-CONFIRMED` | read out of a file, manifest or configuration; never executed. Always names the file and line. |
| `PENDING-VERIFICATION` | landed, and no gate has seen it. The status of nearly everything here. |
| `CONSTRAINT` | a binding design rule with no observation behind it. |
| `HYPOTHESIS` | reasoned and unexecuted. |
| `SYMPTOM` | reported but not yet caused, or a failure mode a note rules out by construction rather than by observation. |
| `WITHDRAWN` | a claim that was refuted and is kept only so it is not repeated. |

## What was read from disk, and what was read from the wave contract

This file is written by one slice of a wave. Being exact about which inputs were
on disk and which were taken from `local://simdjson-sdk-contract.md` matters more
than usual here, because the whole point of these notes is that a later wave can
tell a decision from a recollection.

**Read in full from disk, and every line reference to them below is one I read:**

* `zig/bridge.h` (661 lines), `zig/bridge.cc` (935 lines), `zig/root.zig`
  (1190 lines), `runtime/graph.zig`, `runtime/library.zig`, `runtime/loader.zig`
  (the declaration surface and the module documentation),
  `runtime/sync.h`.
* The vendored upstream tree under `src/`, for every `src/...` reference here.

**Not on disk when this file was written.** These were described from the wave
contract, not read:

* `build.zig`, `build.zig.zon`, `build_support/graph.zig`, `tests.zig`,
  `smoke.zig`, `consumer/`, `package.nix`, `tools/check-provenance.sh`,
  `UPSTREAM.md`, `NOTICE.md`, `FORK-LICENSE.md`, `README.md`, `README.zig.md`,
  `CHANGELOG.md`.

Where a note below is a statement about one of those files, it is marked
**(from the contract, not from disk)** and it carries the upstream facts that
motivate it rather than a line number in the file. `build_support/` and `tools/`
and `consumer/src/` were empty directories when this file was written;
`consumer/` held its subdirectory and nothing else.

## Path convention

Upstream line references are written relative to this package's `src/`, exactly
as upstream's own comments write them. `src/src/implementation.cpp:296-312`
therefore means "the 296th through 312th line of `simdjson/src/src/implementation.cpp`"
— the file is `src/src/implementation.cpp` because upstream's source root is
`src/src/` inside the `src/` directory this package vendors. Two files are named
this way in notes below and the double `src/` is deliberate, not a typo:
`src/src/implementation.cpp` and `src/src/simdjson.cpp`.

---

## 1. On-Demand, not DOM — one decision that fixes the shape of every type in the facade

**Condition.** simdjson 5.0.2 ships two parsers. The DOM one
(`simdjson::dom::parser`, reached from `simdjson.h`) builds a tree of nodes whose
children are indices into a tape, and is re-readable and randomly accessible.
The On-Demand one (`simdjson::ondemand`, `src/include/simdjson/ondemand.h:4,10`)
is a forward-only cursor over a stage-1 index, and `#include <simdjson/ondemand.h>`
binds it to exactly one compile-time-selected kernel through
`src/include/simdjson/builtin/ondemand.h:11-31,39`. `SOURCE-CONFIRMED`.

**Symptom.** Not a failure — a fork with two obviously usable parsers and one
seam to write. Either is buildable. Choosing the DOM one would have made almost
every type in the facade a thin mirror of an upstream DOM node, and choosing
On-Demand makes almost every type a *copy* of something instead.

**Cause.** What On-Demand does not have is a value a caller can hold. Upstream
states the rule in its own words at
`src/include/simdjson/generic/ondemand/document.h:560-569`: "You must consume the
fields on an object one at a time. A request for a new key invalidates previous
field values" — repeated for `find_field_unordered` at `:595-604`, and again for
`operator[]` at `:587-611`. `document::find_field` additionally refuses outright
when the document is not at its root
(`src/include/simdjson/generic/ondemand/document-inl.h:77-79`).
`src/include/simdjson/error.h:46` is the compiler-visible form of the same rule:
`OUT_OF_ORDER_ITERATION`, documented "checked when
SIMDJSON_DEVELOPMENT_CHECKS=1". The iterator contracts are tighter still:
`array_iterator::operator*` is "MUST ONLY BE CALLED ONCE PER ITERATION"
(`src/include/simdjson/generic/ondemand/array_iterator.h:53-54`), and
`object_iterator::operator++` is "YOU MUST NOT CALL THIS IF operator* YIELDED AN
ERROR" and "WITHOUT A CORRESPONDING operator* CALL"
(`object_iterator.h:44-46`, with the same one-shot note at `:38`).
`field::unescaped_key` consumes the key and forbids any other key accessor after
it (`src/include/simdjson/generic/ondemand/field.h:32-40`).

**Fix.** This package binds **On-Demand only**, and the consequence is accepted
in full rather than papered over: no `value`, `object`, `array`, `field`,
`document` or iterator type crosses `zig/bridge.h`. A caller receives
`simdjson_bridge_document` and can ask it for one thing — a finished,
self-contained copy of the whole document — and nothing else. The DOM API, the
minifier, `document_stream` and compile-time JSON are all reachable by a C++
consumer from the installed upstream headers and are deliberately absent from
the Zig facade; `zig/root.zig:12-16` says so, and the absence is a decision
rather than an omission.

**Targets bound.** The upstream On-Demand consumption contract at release 5.0.2.
It does not depend on a Zig version, a target, or an optimize mode. It would
have to be re-derived if a future release made a `value` independently
re-readable — upstream would have to remove the one-shot rule, which is the
headline property of the API and is not expected to change.

**Status.** `SOURCE-CONFIRMED` for every upstream line above; `CONSTRAINT` for
the choice itself.

## 2. The walk copies the document; a cursor cannot cross the boundary

**Condition.** A C or Zig caller cannot hold a `value` across two calls
(note 1). The most direct binding would therefore be a streaming interface: one
call per token, a cursor held by the caller, and nothing copied.

**Symptom.** Not a failure — three plausible shapes and one of them is a trap.
A cursor crosses a C ABI as an integer or a pointer, and this package cannot own
the thing behind it: `value_iterator`'s validity depends on parser state
(`_max_depth`, `depth()`, the structural index) that a caller in another language
has no way to maintain, and `OUT_OF_ORDER_ITERATION` exists precisely because
the invariant is not expressible in a signature. A cursor type would also make
`Document` a *reading* object rather than a *parsed* one, and every error a
caller could meet would be an error from a call rather than from a parse.

**Fix.** `simdjson_br_walk` (`zig/bridge.h:650-657`, `zig/bridge.cc:715-792`) is
the only way to read a document through this bridge, and it produces a flat
pre-order sequence of fixed-width `simdjson_bridge_node` records plus one blob
buffer holding every key and every string value. `zig/root.zig`'s `Array`
(`:1038-1076`) and `Object` (`:1104-1158`) are then **views over those records**,
not cursors into upstream's parser: iteration reads already-copied memory, so it
can be repeated, interleaved and nested with none of upstream's restrictions,
and `Object.get` (`:1133-1140`) is an ordinary linear search rather than a
`find_field` that refuses out-of-order access.

**What it costs, stated plainly.** The caller pays for one full copy of every
value in the document: `Walk.nodes` is one `Record` per value and `Walk.blobs` is
one byte per key byte and per string byte. On a document this package does not
parse twice, that is memory the DOM path would not have needed. The offset is
paid in exchange for: no borrowed value with a hidden lifetime; no way for a
caller to trip `OUT_OF_ORDER_ITERATION` at all; a `Walk` that can be re-read,
filtered and randomly indexed; and `Document.walk` being callable more than once
(note 5's rewind).

**Targets bound.** Nothing outside upstream's one-shot rule. The copy is this
fork's design and would survive a future upstream release; only the *reason* it
exists would have to be re-checked.

**Status.** `PENDING-VERIFICATION` for the shape; `SOURCE-CONFIRMED` for the
upstream constraint it answers.

## 3. The input is copied, because upstream refuses an unpadded buffer

**Condition.** `simdjson::padded_string` allocates `length + SIMDJSON_PADDING`
(`src/include/simdjson/padded_string-inl.h:66-74`) and `SIMDJSON_PADDING` is 64
(`src/include/simdjson/base.h:42`). `parser::iterate` returns
`INSUFFICIENT_PADDING` before it reads a single byte when the input view is not
padded (`src/include/simdjson/generic/ondemand/parser-inl.h:54-55`; the error is
`error.h:47`). `SOURCE-CONFIRMED`.

**Symptom.** Two ways to get this wrong, both with a plausible-looking
signature. Borrowing the caller's slice and refusing it as unpadded would make
`parse` refuse most callers, because an ordinary Zig slice has no padding. Adding
padding to a copy of the caller's bytes on the stack would put a
64-byte-bounded read past the end of an object whose size the caller chose.

**Cause.** The padding is load-bearing for an unbounded scan, not a formality.
Stage 2's `stringparsing::parse_string` takes no end pointer and scans until it
finds a closing quote
(`src/src/generic/stage2/stringparsing.h:151-159`), which is why stage 1's
string scanner tracks `prev_in_string` across blocks and reports
`UNCLOSED_STRING` only at the end
(`src/src/generic/stage1/json_string_scanner.h:87-92`).

**Fix.** `simdjson_bridge_document` (`zig/bridge.cc:525-529`) owns three members
in construction order — a `simdjson::padded_string input`, a
`std::unique_ptr<simdjson::ondemand::parser> parser`, and a
`simdjson::ondemand::document doc` — and `simdjson_br_open` fills the input
first, allocates the parser, and only then runs `iterate`. The bytes are copied,
so the caller's buffer may be freed or reused the instant `parse` returns
(`zig/bridge.h:536-540`, `zig/root.zig:738-742`). The copy is also what makes
`INSUFFICIENT_PADDING` unreachable through this bridge, which is why
`Error.UpstreamInsufficientPadding` is documented as unreachable at
`zig/root.zig:373-375`.

A length that could not be padded is refused before anything is allocated: the
allocation is `len + SIMDJSON_PADDING` with a 64-byte constant, so
`len > SIZE_MAX - SIMDJSON_PADDING` is the first thing that can wrap and it is
the first check after the null check (`zig/bridge.cc:647-649`). `SIZE_MAX` here
is the upstream `SIMDJSON_PADDING` macro, not a literal, so the guard moves if
upstream changes the constant.

**Targets bound.** `SIMDJSON_PADDING` and the shape of
`padded_string_view::has_sufficient_padding`. A future release that removed the
unbounded scan could relax this — but the public `iterate(padded_string_view)`
signature would have to change first, and that is an upstream ABI change this
package would not survive silently.

**Status.** `SOURCE-CONFIRMED` for every upstream line; `PENDING-VERIFICATION`
for the bridge.

## 4. The error mirror carries every member of upstream's enumeration

**Condition.** `simdjson::error_code` is an **unscoped** enumeration at
`src/include/simdjson/error.h:19-55`: `SUCCESS = 0` on `:20`, then contiguous
members through `UNKNOWN_FIELD` (33) and `NUM_ERROR_CODES` (34). There is no
`SIMDJSON_ERR_*` spelling anywhere in the tree — a name that suggests one is
wrong, and this fork does not invent it. `SOURCE-CONFIRMED`.

**Symptom.** A bridge that mirrors only the members it has been seen to produce
looks tidier and is wrong on first contact. Upstream reaches
`INCOMPLETE_ARRAY_OR_OBJECT` out of `document::get_value()` itself
(`src/include/simdjson/generic/ondemand/document-inl.h:94`,
`src/include/simdjson/generic/ondemand/value_iterator-inl.h:84`), so a walk of a
truncated document produces it with no unusual configuration. A header that
stopped at the seventeen members this bridge is known to produce would hand that
caller an unnamed integer.

**Fix.** `simdjson_bridge_error_code` (`zig/bridge.h:171-255`) names **every**
member, at upstream's own integer values, including `NUM_ERROR_CODES` — upstream's
end-of-list placeholder, carried so the enumeration has the same length upstream's
does. `SIMDJSON_BRIDGE_ERROR_NONE = 0` is this fork's spelling of
`simdjson::SUCCESS`, so a successful call's out-parameter and the enumerator
cannot disagree.

Drift is made impossible rather than documented: `zig/bridge.cc:795-856` carries
a `static_assert` per member against the real `simdjson::error_code` enumerator,
which the C++ compiler checks on every target that builds the bridge. The same
block static-asserts the seven `json_type` values
(`src/include/simdjson/generic/ondemand/json_type.h:17-26`) and the four
`number_type` values (`src/include/simdjson/base.h:43-48`), and
`zig/bridge.cc:934-935` pins the absent-offset marker.

**Targets bound.** Zig 0.16.0 and the pinned upstream tag. The `static_assert`
block is what makes renumbering a build failure rather than a silent behaviour
change; a re-sync to a release that inserted a member would fail the build at
the first new member, which is the intended outcome.

**Status.** `SOURCE-CONFIRMED` for the enumeration and the mirror;
`PENDING-VERIFICATION` for the assertions, which no compiler has run.

## 5. `get_number` classifies a number; `get_number_type` is never asked

**Condition.** `value::get_number_type()` is a cheap peek at the token's first
bytes; `value::get_number()` runs the real parser.

**Symptom.** Not a failure — a classification that is right for every valid
number and wrong for exactly the document this package's own fixture corpus
contains. `get_number_type` has no leading-zero check at all
(`src/include/simdjson/generic/numberparsing.h:1526-1568`), so `{"a":01}` — which
RFC 8259 §6 forbids and which upstream's number parser refuses — is classified
`signed_integer`. A bridge that peeked first would report `signed_integer` for a
number it must then refuse, and would have to choose between reporting a number
type for an invalid document and refusing the document.

**Cause.** `parse_number` is the entry point that carries the guard.
`src/include/simdjson/generic/numberparsing.h:905-906` computes the digit count
and refuses `digit_count == 0 || ('0' == *start_digits && digit_count > 1)`,
returning at `:919` through `INVALID_NUMBER`, which is `#define`d to
`NUMBER_ERROR` at `:26`. `SOURCE-CONFIRMED`.

**Fix.** `WalkScalar` (`zig/bridge.cc:238-298`) calls `v.get_number()` **once**,
then reads the payload that parse produced with the accessor the resulting
`number_type` selects. There is no second parse and no separate classification
pass. The consequence is that `{"a":01}` is refused with `NUMBER_ERROR` (9)
rather than being read as `0`.

**Targets bound.** `numberparsing::parse_number`'s guard at `:906`. A future
release that moved the leading-zero check into `get_number_type` would make the
peek sufficient and cheaper; until then, the classification is the parse.

**Status.** `SOURCE-CONFIRMED`.

## 6. The builtin kernel is a preprocessor cascade, not a call

**Condition.** `#include <simdjson/ondemand.h>` does not reach a
runtime-dispatched kernel. It includes `simdjson/builtin/ondemand.h`, which
selects exactly one `simdjson/<arch>/ondemand.h` and aliases `simdjson::ondemand`
to that architecture's namespace
(`src/include/simdjson/builtin/ondemand.h:11-31,39`;
`src/include/simdjson/ondemand.h:4,10`). The selection itself is
`SIMDJSON_BUILTIN_IMPLEMENTATION`, a priority cascade over
`SIMDJSON_CAN_ALWAYS_RUN_*` at
`src/include/simdjson/implementation_detection.h:148-172`, with the comparison
macro `SIMDJSON_BUILTIN_IMPLEMENTATION_IS(IMPL)` at `:175`. `SOURCE-CONFIRMED`.

**Symptom.** The obvious implementation of "tell me which kernel this artifact
is bound to" is to call `simdjson::builtin_implementation()`
(`src/include/simdjson/builtin/implementation.h:41`). That accessor looks the name
up in the available list and its only guard is `assert(builtin_impl)` at
`src/src/implementation.cpp:342`, inside a function at `:340-344`. `assert` is
removed in every optimize mode but Debug, so on a build where the builtin kernel
was compiled out this accessor dereferences a null pointer and returns it — the
one function in this package that would turn a misconfiguration into a
segfault rather than a string. Upstream's own header comment admits the
assert is debug-only; this package does not build on that.

**Fix.** `zig/bridge.cc:96-116` is a nine-arm `#if`/`#elif` cascade that mirrors
`implementation_detection.h:148-172` exactly — same nine kernels, same order
(icelake, haswell, westmere, arm64, ppc64, lsx, lasx, rvv_vls, fallback), same
last-resort `fallback` — and the `#else` is an `#error` rather than a default, so
a target where upstream's cascade would itself have failed cannot silently get a
name here. It is a preprocessor question answered by a preprocessor cascade, at
zero run-time cost, with no failure mode.

**Targets bound.** The nine kernels and their order at
`implementation_detection.h:148-172`, and the `IS` macro at `:175`. A future
release adding a kernel (or reordering the cascade) requires editing
`zig/bridge.cc:96-116` to match; nothing checks that the two agree at build time,
which is the sharp edge of this decision and is recorded again as an open
question.

**Status.** `SOURCE-CONFIRMED` for the cascade and for the `assert`; the
`#if` cascade itself is `PENDING-VERIFICATION`.

## 7. `activeImplementation` is a different fact, and nothing may pin it

**Condition.** `simdjson::get_active_implementation()`
(`src/include/simdjson/implementation.h:226`) is the DOM-side runtime
dispatcher's choice, and it is perturbed by the environment.

**Symptom.** Not a failure — a value that looks like a constant and is a
function of the host and of the environment. Three separate things move it:

1. `SIMDJSON_FORCE_IMPLEMENTATION` overrides the whole choice. If it names a
   kernel that is not compiled in, upstream does **not** fall back to detection:
   it latches onto the unsupported implementation, and every later parse fails
   with `UNSUPPORTED_ARCHITECTURE` (`src/src/implementation.cpp:296-312`, with
   the `getenv` at `:299` and the latch at `:308`).
2. With more than one kernel compiled in, the first call to any accessor is what
   performs detection and memoises the winner; the installed value before that is
   a proxy whose own name is `"best_supported_detector"`
   (`src/src/implementation.cpp:186-207`, the name at `:204`).
   With `SIMDJSON_SINGLE_IMPLEMENTATION` the answer is that kernel with no
   detection at all (`:321-327`).
3. The host feature bits come from CPUID on x86-64
   (`src/internal/isadetection.h:141,202-215`), from `getauxval` on aarch64,
   from nothing at all on ppc64 (`:79-80`), and from a constant elsewhere
   (`:321-322`).

**Fix.** Three responses, all in this package:

* `simdjson_br_active_implementation` dereferences the accessor once so the
  proxy's own name is never returned (`zig/bridge.h:467-471`,
  `zig/bridge.cc:548-566`), and its doc comment lists all three perturbations
  so a caller reading the header learns not to compare it against a literal.
* `runtime/library.zig:74-79` states that which kernel the provider's dispatcher
  selected is **not** a compatibility requirement and is **not** checked; the
  load-time check proves only that every available implementation has a non-empty
  name.
* `Error.UpstreamUnsupportedArchitecture` exists in the facade's set for the
  case where the environment forced an uncompiled kernel
  (`zig/root.zig:347-348`), which is the observable consequence of (1).

**Targets bound.** Nothing — the three perturbations are upstream behaviour at
this tag and are environment-dependent at every target. This is the one value in
the package whose correct answer differs between two machines running the same
binary, and it is the reason no gate may assert on it.

**Status.** `SOURCE-CONFIRMED`.

## 8. `SIMDJSON_DEVELOPMENT_CHECKS=1` on every target, not only Debug

**Condition.** Upstream adds `SIMDJSON_DEVELOPMENT_CHECKS` in a Debug
configuration only: `src/CMakeLists.txt:376-379`, guarded by the comment at
`:374-375` ("-Og defines __OPTIMIZE__, so the header would not auto-enable
SIMDJSON_DEVELOPMENT_CHECKS in Debug. Keep the checks in Debug only"), with the
option itself at `:146-147`. The header also auto-enables it under debug builds
unless the programmer set it (`src/include/simdjson/common_defs.h:304-305`).

**Symptom.** Not a failure — a boundary that would exist in one gate and not in
another. This package's test suite is meant to run in Debug **and** ReleaseSafe.
With upstream's own rule, `OUT_OF_ORDER_ITERATION` (documented "checked when
SIMDJSON_DEVELOPMENT_CHECKS=1", `src/include/simdjson/error.h:46`) would be
live in Debug and absent in ReleaseSafe, so any behaviour depending on it would
be a fact about the optimize mode rather than about the package. The same is true
of `DEPTH_ERROR` for a document deeper than `DEFAULT_MAX_DEPTH`: the depth
parameter is "only relevant when the macro SIMDJSON_DEVELOPMENT_CHECKS is set to
true" (`src/include/simdjson/generic/ondemand/parser.h:344`).

**Fix.** `-DSIMDJSON_DEVELOPMENT_CHECKS=1` is passed on **every** target and in
every optimize mode, for both C++ translation units. **This is this fork's
decision and not upstream's default**, and it is recorded that way in every
document that mentions it. The cost is real and is stated: with the checks on,
starting a container *asserts* that its depth is inside upstream's
`parser::start_positions` (`src/include/simdjson/generic/ondemand/json_iterator-inl.h:432-434`,
whose `SIMDJSON_ASSUME` is `assert` in every build that keeps development checks
on, `src/include/simdjson/portability.h:243-246`), and stage 1 does not bound the
depth at all, so a document nested past `DEFAULT_MAX_DEPTH` (1024,
`src/include/simdjson/base.h:49`) aborts the process instead of being refused.
`zig/bridge.cc` therefore makes the bound an ordinary comparison against
upstream's own `DEFAULT_MAX_DEPTH` and answers upstream's own `DEPTH_ERROR`, one
level short of the assert. That is the intended behaviour — a depth limit that is
an abort in one mode and nothing in another is a limit nobody can rely on.

**Targets bound.** `SIMDJSON_DEVELOPMENT_CHECKS` at this upstream tag, and this
package's choice to apply it uniformly. It is independent of target and of Zig
version. It is also the kind of decision a later wave should be able to
overturn deliberately: dropping the define leaves the comparison in place but
removes the assertion it guards, so the refusal stops depending on the
optimize mode for a second reason and the upstream behaviour that note 8 was
written against — an out-of-order-iteration check that is live in Debug and
absent in ReleaseSafe — returns.

**Status.** `CONSTRAINT` (a binding choice) plus `SOURCE-CONFIRMED` for the
upstream rule it departs from.

## 9. `SIMDJSON_THREADS_ENABLED=1`, although the On-Demand path never reads it

**Condition.** Upstream's default enables threads:
`src/CMakeLists.txt:41` is `option(SIMDJSON_ENABLE_THREADS ... ON)` and
`:382-386` adds `Threads::Threads` and `SIMDJSON_THREADS_ENABLED=1` **PUBLIC**.
`simdjson.pc.in` adds the same define to `Cflags`
(`src/CMakeLists.txt:464-468`). `SOURCE-CONFIRMED`.

**Symptom.** Not a failure — an ODR-shaped trap. `SIMDJSON_THREADS_ENABLED` is
`PUBLIC` in upstream, which means it lands in the *installed headers'*
consumers' compile lines as well as the library's own. A provider built with the
define and a consumer that included the installed upstream headers without it
would disagree about the declarations in
`src/include/simdjson/dom/document_stream.h:7-16,288-310` and
`src/include/simdjson/dom/parser.h:655-664`. This fork does not reach those
headers — the DOM API is absent (note 1) and `zig/bridge.h` includes only
`<stddef.h>` and `<stdint.h>` — so the disagreement is not reachable through
the Zig route today.

**Fix.** The define is passed on every target whose C++ runtime provides
`std::thread`, and the reason is stated rather than assumed: it makes the
compiled core and the installed upstream header tree agree about every target,
so a C++ consumer who links the delivered `libsimdjson` and includes
`include/simdjson/` does not silently get different declarations from the ones
the library was compiled with. The installed tree ships the whole upstream header
set unmodified, so that consumer exists and must not be handed a mismatch. It
also matches `simdjson.pc`'s own `Cflags`, so the pkg-config route and the header
route say the same thing.

**The target-dependent half.** `build_support/graph.zig`'s `cppMacros` resolves
this one per target and omits it for `wasm32-wasi`, because
`SIMDJSON_THREADS_ENABLED` turns on `document_stream`'s worker, which is
`std::thread` (`src/include/simdjson/dom/document_stream.h:46,61,62`) and does not
exist there at all. Upstream arrives at the same answer through its own
`find_package(Threads)` guard (`src/CMakeLists.txt:382-386`), so the target
without the define is an upstream-supported configuration and not a degraded
build. The same function adds `SIMDJSON_AVX512_ALLOWED=0` for an x86-64 target
whose CPU model has no AVX-512, which is upstream's own switch
(`src/include/simdjson/common_defs.h:385-388`) and the reason a baseline
x86-64 cross target compiles at all.

The macro gates nothing on the On-Demand path; this package does not use it and
does not claim to.

**Targets bound.** Upstream's `PUBLIC` propagation at `src/CMakeLists.txt:385`
and the `.pc` `Cflags` at `:465`. If a future release made the macro `PRIVATE`,
or moved it out of the installed headers' reach, this note's reason evaporates
and the define becomes harmless-but-pointless.

**Status.** `SOURCE-CONFIRMED` for the propagation; the decision is
`CONSTRAINT`.

## 10. `SIMDJSON_ENABLE_NAN_INF=0` stated, so `{"a":NaN}` is a build fact

**Condition.** `src/include/simdjson/common_defs.h:61-63` defaults
`SIMDJSON_ENABLE_NAN_INF` to `0`, and `src/CMakeLists.txt:355` has the CMake
option default OFF. `SOURCE-CONFIRMED`.

**Symptom.** Not a failure — an answer inherited rather than chosen. On a build
that did not pass the define, `{"a":NaN}` would be refused because the compiler
happened to take the header's default. That is an accident of the header, and it
would change silently if upstream moved the default.

**Fix.** `-DSIMDJSON_ENABLE_NAN_INF=0` is passed explicitly on every target, so
the refusal of `{"a":NaN}` is this package's stated configuration and not an
inherited one. The effect is inside `parse_number`: with the macro off, the
`#if SIMDJSON_ENABLE_NAN_INF` arm at
`src/include/simdjson/generic/numberparsing.h:908-917` is not compiled, so `N`
fails the digit-count guard at `:906` and returns `INVALID_NUMBER` at `:919`.

The observable answer through this package is `TAPE_ERROR`, not
`NUMBER_ERROR`, and the reason is a second upstream fact: `value_iterator::type`
answers `json_type::unknown` for a first byte that is not a token start
(`src/include/simdjson/generic/ondemand/value_iterator-inl.h:1170-1188`, default
arm at `:1187`), and the bridge dispatches on `type()` before it reaches a number
accessor at all. Upstream's own verdict for a non-value is `TAPE_ERROR` on its
DOM path, where such a byte falls to `default:` and logs "Non-value found when
value was expected!" (`src/src/generic/stage2/json_iterator.h:363-365`). See
note 14.

Had a caller asked `get_double` instead of `type()` first, `+` in `{"a":+1}`
would reach `numberparsing::parse_double` and answer `INCORRECT_TYPE`
(`src/include/simdjson/generic/numberparsing.h:1359`). This package's walk never
takes that path, so `TAPE_ERROR` is the answer it produces.

**Targets bound.** The default at `common_defs.h:61-63` and the guard at
`numberparsing.h:906`. Both are upstream-version facts.

**Status.** `SOURCE-CONFIRMED`.

## 11. `-std=c++17` is pinned, and upstream's propagated feature is only a floor

**Condition.** `src/cmake/developer-options.cmake:125` is
`set(SIMDJSON_CXX_STANDARD 17 CACHE STRING ...)`, applied to
`CMAKE_CXX_STANDARD` at `:127-129` only when the user has not set one, with
`CMAKE_CXX_STANDARD_REQUIRED ON` and `CMAKE_CXX_EXTENSIONS OFF` at `:131-132`.
Separately, `src/CMakeLists.txt:335` propagates only
`simdjson_add_props(target_compile_features PUBLIC cxx_std_11)`.
`SOURCE-CONFIRMED`.

**Symptom.** A reader who sees `cxx_std_11` concludes the library needs only
C++11, and a build that leaves the standard to the compiler's default depends on
which clang the Zig release ships.

**Cause.** The two numbers answer different questions. The `cxx_std_11` compile
feature is a floor for *consumers* of the installed headers; the C++17 in
`developer-options.cmake` is what the library's own sources are compiled at. The
bridge's translation unit is library source, not a consumer, so C++17 is the
relevant number for it.

**Fix.** `-std=c++17` is passed explicitly to both C++ translation units
(`src/src/simdjson.cpp` and `zig/bridge.cc`), so the standard is a fact of this
build rather than a property of the compiler default. This matches upstream's own
default, so it is not a divergence; the divergence would be silence.

Note the adjacent reflection arm: `developer-options.cmake:123` selects C++26 when
`SIMDJSON_STATIC_REFLECTION_ENABLED`, and `src/CMakeLists.txt:329-332` adds
`-std=c++26` with it. That path is off here, because `compile_time_json.h`'s whole
body is inside `#if SIMDJSON_STATIC_REFLECTION`
(`src/include/simdjson/compile_time_json.h:10`) and this build is at C++17 —
which is why the umbrella `src/include/simdjson.h:61` include of that header is
inert in `zig/bridge.cc`.

**Targets bound.** Zig 0.16.0 for the flag spelling, upstream 5.0.2 for the
number. A future release that required C++20 would need both.

**Status.** `SOURCE-CONFIRMED`.

## 12. Arguments are validated by comparison, never by `assert`

**Condition.** `zig/bridge.h:28-36` states the rule: "Nothing is `assert`ed: an
`assert` is removed in ReleaseFast, so a bound check that vanishes is a bound
check that lies."

**Symptom.** Not hypothetical in this library. Upstream has a debug-only
`assert(builtin_impl)` guarding the builtin-kernel lookup at
`src/src/implementation.cpp:342` — see note 6 — so the precedent for relying on
`assert` in this codebase is a precedent that crashes.

**Fix.** Every entry point in `zig/bridge.cc` checks its arguments with ordinary
comparisons before the upstream call and returns
`SIMDJSON_BRIDGE_INVALID_ARGUMENT`. The counts this buys are: `out` cleared to
null **before** anything is validated, so a caller that ignores the status never
dereferences a stale handle (`zig/bridge.cc:634-639`); both out-counts of
`simdjson_br_walk` written before anything can fail (`:725-727`); a null `doc`,
null `out_node_count` or null `out_blob_len` refused (`:721-723`); the null
`out_len` of every two-pass call refused before the length is written
(`:45-47`, `:65-67`); the `SIZE_MAX - SIMDJSON_PADDING` overflow guard before any
allocation (`:647-649`); and an index at or past the implementation list's own
size refused (`:595-597`).

The header states the one place this is *not* a blanket promise
(`zig/bridge.h:130-135`): on `SIMDJSON_BRIDGE_INVALID_ARGUMENT` a count request
initialises `*out_count` before it validates anything, and a constructor clears
its handle to NULL before it allocates. "No usable result was produced" is not
the same claim as "every output was left byte-for-byte alone", and pretending it
is would be a false promise in the header.

**Targets bound.** Zig's `assert` semantics, which are the reason. Independent of
target and of upstream version.

**Status.** `PENDING-VERIFICATION` for the bridge, `SOURCE-CONFIRMED` for
upstream's own `assert`.

## 13. Only `std::bad_alloc` is caught

**Condition.** Both C++ translation units are built `-fno-exceptions
-fno-rtti` with `-DSIMDJSON_EXCEPTIONS=0`. Upstream supports exactly this:
`src/cmake/exception-flags.cmake:1` is the option, `:5` adds the define and `:27`
adds `-fno-exceptions` for GCC, and the header decides on its own otherwise
(`src/include/simdjson/common_defs.h:53-59`, from `__cpp_exceptions` or
`_CPPUNWIND`). `SOURCE-CONFIRMED`.

**Symptom.** On a `-fno-exceptions` translation unit, a `try` block that catches
`std::bad_alloc` is not contradictory — libc++ still raises it — but a `try` that
catches `...` would silently turn any failure into a status, and a bridge with no
`try` at all would let an allocation failure escape through an `extern "C"`
boundary into a Zig caller, which cannot catch it.

**Cause.** On-Demand accessors are declared `noexcept` and report through
`simdjson_result<T>`. That is why the bridge unwraps every result explicitly:
`simdjson_result<T>`'s converting `operator T&&` at
`src/include/simdjson/error.h:223` is inside `#if SIMDJSON_EXCEPTIONS`
(`:180-225`), so with the define at 0 the only ways to get a value out are
`get(T&)` (`error.h:169`) and `tie` (`:162`), and both must have their error
checked. `zig/bridge.cc:394-407` and `:418-424` do exactly that for every
`begin()`, `end()` and dereference. See note 33: the comment in `zig/bridge.h`
that cites `error.h:162-164` for `simdjson_result<T>::error()` is superseded by
the exact lines.

**Fix.** `std::bad_alloc` is caught in the five entry points where an allocation
can happen — `simdjson_br_active_implementation` (`zig/bridge.cc:563-565`), its
description (`:575-577`), `simdjson_br_available_implementation_name`
(`:604-606`), `simdjson_br_open` (`:688-690`) and `simdjson_br_walk` (`:789-791`)
— and nothing else is. The `name()` and `description()` accessors are
`virtual std::string name() const` (`src/include/simdjson/implementation.h:56`)
and return by value, which is why those two are inside a `try` at all.
`simdjson_br_open` additionally reports `padded_string`'s own allocation failure
signal — it leaves `data_ptr` null and zeroes `viable_size`
(`src/include/simdjson/padded_string-inl.h:67,71-73`) — as upstream's own
`MEMALLOC` (`src/include/simdjson/error.h:22`) rather than as a
bridge-specific code, because it is the code upstream's own parser would have
produced (`zig/bridge.cc:655-666`).

Nothing else can be raised on this translation unit, and nothing else is caught,
so nothing is silently turned into a success.

**Targets bound.** `-fno-exceptions` at every target. A target whose libc++
disables `bad_alloc` under `-fno-exceptions` would need this re-examined; that
has not been observed here.

**Status.** `SOURCE-CONFIRMED` for upstream's side; `PENDING-VERIFICATION` for
the bridge.

## 14. `TAPE_ERROR` for `json_type::unknown` is upstream's classification, carried across

**Condition.** The bridge dispatches on `value::type()`
(`src/include/simdjson/generic/ondemand/value.h:608`) before reading a value.
Upstream documents `type()` as not consuming the value
(`src/include/simdjson/generic/ondemand/document.h:619`), so the same `value` can
then be read with the accessor its type selects — except when the type is
`json_type::unknown`.

**Symptom.** A `json_type::unknown` record has no accessor. Any code that
"handles" it must invent a reading, and inventing one produces a plausible wrong
answer for a malformed document.

**Fix.** `WalkScalar`'s default arm (`zig/bridge.cc:351-359`) stops the walk with
`simdjson::TAPE_ERROR` rather than reading the value. `TAPE_ERROR` is upstream's
own verdict for the same byte on its DOM path: a byte that is neither a digit, a
`-` nor a token start falls to `default:`, logs "Non-value found when value was
expected!" and returns `TAPE_ERROR`
(`src/src/generic/stage2/json_iterator.h:363-365`). So this is upstream's
classification carried across the API boundary, not a code invented in the seam.
The same arm covers the two unreachable container cases at `:347-350`, which
exist so the switch is total.

This one decision is what makes five of the eight `malformed/` fixtures answer
`TAPE_ERROR`: `01-trailing-comma-object.json`, `02-single-quoted-string.json` and
`03-unquoted-key.json` are refused by the second `value_iterator::field_key`
being handed `}` or `'` or `a` (`src/include/simdjson/generic/ondemand/value_iterator-inl.h:422`),
`04-nan-literal.json` and `05-leading-plus-number.json` by `N` and `+` not being
token starts (note 10), and `07-missing-colon.json` by
`value_iterator::field_value`'s explicit check at `:445`
(`if (*_json_iter->return_current_and_advance() != ':') { return report_error(TAPE_ERROR, "Missing colon in object field"); }`).

**Targets bound.** The DOM path's own classification at
`src/src/generic/stage2/json_iterator.h:363-365`. If upstream ever gave
On-Demand its own error for a non-value, this would become that error and the
fixture table in `README.md` would be wrong — which is the point of recording it.

**Status.** `SOURCE-CONFIRMED`.

## 15. Both walk outputs are two-pass, and the sizing rule is deliberately coarse

**Condition.** A call needs to know how many records and how many blob bytes a
document has before it can allocate either. `zig/bridge.h:581-602` states the
protocol: pass `nodes == NULL` or `node_cap == 0`, or `blobs == NULL` or
`blob_cap == 0`, and the call sizes; anything else fills.

**Symptom.** Three tempting simplifications, each wrong. Making "either buffer
absent" mean "size both" is wrong for a caller that sized one and not the other.
Truncating instead of refusing is dishonest. Reporting the two-pass refusal as an
upstream error is worse: it would make a capacity problem look like a malformed
document.

**Fix.** The rule is deliberately coarse — **either** output absent or empty
makes the whole call a sizing call (`zig/bridge.cc:736-737`), and the header says
why (`zig/bridge.h:732-735`): a caller that sized only one of the two buffers has
not sized the result, and discovering that halfway through a fill is worse than
being told now. The `Walker` struct (`zig/bridge.cc:131-221`) carries a single
`sizing` flag and treats the counts as *required* sizes in both modes, which is
what lets one pair of out-parameters answer the sizing call and the
`BUFFER_TOO_SMALL` refusal identically. `ReserveBlob` (`:159-168`) computes the
offset even in sizing mode so the two passes agree on every offset.

The two passes see the same document because the walk rewinds before each of
them: `document::rewind()`
(`src/include/simdjson/generic/ondemand/document.h:763`,
`document-inl.h:35-36`) resets the cursor to the state `iterate` left it in
(`zig/bridge.cc:751-756`).

`zig/root.zig`'s `walkDocument` (`:852-909`) hides the protocol completely: it
performs the sizing call, refuses a zero record count as `UpstreamEmpty`, then
allocates both slices with `errdefer` on each, then fills, then compares the
filled counts against the sized ones and reports `UpstreamUnnamed` on a
disagreement. The caller never sees the two-pass contract and cannot get it half
right.

**Targets bound.** `document::rewind()` existing at all. It is what makes a
one-shot parser safely walkable twice, and without it the whole design in note 2
would have to change.

**Status.** `SOURCE-CONFIRMED` for `rewind`; `PENDING-VERIFICATION` for the rest.

## 16. `BUFFER_TOO_SMALL` and `UPSTREAM_ERROR` are separate refusals and are never collapsed

**Condition.** `Walker` keeps two failure kinds apart on purpose
(`zig/bridge.cc:126-130`): `error` is an upstream `simdjson::error_code` and means
the document was refused, and `can_write` is the bridge's own two-pass state --
false from the first record or blob byte the caller's buffers could not hold --
which is what the entry point turns into `BUFFER_TOO_SMALL` from the two totals.

**Symptom.** Collapsing them would mean either reporting a capacity problem as
an upstream failure — so `Error.BufferTooSmall` and an upstream error name become
the same thing to a Zig caller — or truncating, which produces a `Walk` whose
last record reads whatever followed it in the buffer.

**Fix.** `simdjson_br_walk` keeps the two apart at the end of the walk: the two
totals are re-checked with ordinary comparisons and answer
`SIMDJSON_BRIDGE_BUFFER_TOO_SMALL` with both required sizes already written, and
an upstream failure goes to `out_error` unchanged. The walk does **not** stop
when a buffer runs out — a short filling call runs to the end of the document and
writes nothing further, because the sizes it reports are the ones the caller must
allocate for, and a count that stopped where the buffers stopped would be the
wrong number to size a retry from (`zig/bridge.h:600-607`). Upstream errors go to
`out_error` unchanged. After a *successful* pass the entry point re-checks the
totals anyway, which makes the refusal a property of the call rather than of the
walk's internal state, at the cost of two comparisons.

In the facade the two are also kept apart: `statusError`
(`zig/root.zig:514-523`) maps the four bridge statuses and `upstreamError`
(`:532-570`) maps the upstream integer, and `fail` (`:577-580`) routes
`SIMDJSON_BRIDGE_UPSTREAM_ERROR` to the code beside it because the status alone
says nothing useful. `Error.BufferTooSmall` is documented as unreachable from the
typed surface, because every buffer-taking call there allocates for itself
(`zig/root.zig:306-309`).

**Targets bound.** Nothing outside this fork's design.

**Status.** `PENDING-VERIFICATION`.

## 17. A count that will not fit a `uint32_t` is `CAPACITY`, not truncation

**Condition.** `simdjson_bridge_node`'s offsets and lengths are `uint32_t`
(`zig/bridge.h:319-367`) and the absent-offset marker is `0xFFFFFFFFu`
(`:304`).

**Symptom.** Silently narrowing a `size_t` count into a `uint32_t` produces a
record that points somewhere else in the blob, which is a memory-safety defect
wearing a parse result.

**Fix.** `ReserveBlob` refuses when the running offset would pass
`SIMDJSON_BRIDGE_NO_OFFSET` or when the requested length would carry it past that
value (`zig/bridge.cc:159-168`), and `PushNode` refuses past `0xFFFFFFFFu` records
(`:186-188`). Both report upstream's own `CAPACITY` — "This parser can't support a
document that big" (`src/include/simdjson/error.h:21`) — rather than a
bridge-specific code, because a document of that size is a limit of the record
format, not a malformed input. `zig/root.zig` maps it to `Error.UpstreamCapacity`
(`:314-315`).

The marker choice is deliberate and documented: 0xFFFFFFFF is not a legal offset
into a buffer the sizing call could have described, so it is outside every real
offset (`zig/bridge.cc:932-935`). A zero **length** is explicitly not the absent
marker — a JSON member may genuinely have a zero-length key and `{"":1}` is such
a document (`zig/bridge.h:297-304`).

**Targets bound.** The record field widths, which are this fork's ABI.

**Status.** `PENDING-VERIFICATION`.

## 18. No version script on ELF; a `.def` on COFF

**Condition.** This package's externally linked ABI is **eleven functions and no
data symbol**: `simdjson_br_version` (`zig/bridge.h:409-410`),
`simdjson_br_builtin_implementation` (`:439-440`), `simdjson_br_active_implementation`
(`:479-480`), `simdjson_br_active_implementation_description` (`:485-487`),
`simdjson_br_available_implementation_count` (`:504`),
`simdjson_br_available_implementation_name` (`:514-515`),
`simdjson_br_validate_utf8` (`:529-530`), `simdjson_br_open` (`:566-568`),
`simdjson_br_destroy` (`:574`), `simdjson_br_input_size` (`:578-579`) and
`simdjson_br_walk` (`:650-657`). No entry point is conditional; there is no `#if`
around any definition in the bridge. `SOURCE-CONFIRMED` for the list.

**Symptom.** The Lua template this package follows uses a generated ELF version
script, because Lua's public surface is a *namespace* — `lua_*`, `luaL_*`,
`luaopen_*` — and a version script can export a namespace by pattern. This
package's surface is eleven names sharing a prefix and nothing else. A generated
version script that enumerated exactly those eleven would be a second
declaration convention: it would need editing when the header gains an entry
point, and it would export nothing on a target whose toolchain does not read it.

Upstream's own build takes the opposite and simpler route:
`src/CMakeLists.txt:256` sets `WINDOWS_EXPORT_ALL_SYMBOLS YES` on the `simdjson`
target and does nothing about ELF visibility. There is no visibility control in
the headers and no export macro on any declaration.

**Fix.** On ELF, no version script: nothing here needs one, and adding one would
be the second convention. On COFF, a module-definition (`.def`) file, because
nothing in `zig/bridge.h` carries `__declspec(dllexport)` — the header is plain
C99 with `extern "C"` guards (`zig/bridge.h:116-124`) and cannot be given one
without breaking the C translation the same header exists to serve. COFF has no
"export everything" default, so a `.def` listing the eleven names is the only
mechanism available, and it is generated rather than hand-maintained.

**Targets bound.** ELF and COFF toolchain behaviour. Darwin has no equivalent of
either and is not claimed a clean export surface by this note; a Darwin consumer
must select by name. *(This note is a decision record. The build-graph
implementation that carries it — `build_support/graph.zig` — was not on disk when
this file was written, so no line number in that file is cited here; the upstream
`WINDOWS_EXPORT_ALL_SYMBOLS` fact at `src/CMakeLists.txt:256` is the part a
re-derivation needs.)*

**Status.** `CONSTRAINT` for the decision; `SOURCE-CONFIRMED` for the eleven
names and for upstream's export-all choice.

## 19. The soname is 34 and the release is 5.0.2, and they are different facts

**Condition.** `src/CMakeLists.txt:32-33` are
`set(SIMDJSON_LIB_VERSION "34.0.0" CACHE STRING ...)` and
`set(SIMDJSON_LIB_SOVERSION "34" CACHE STRING ...)`, with the comment at `:31`
"These version numbers are modified by tools/release.py" — and the same comment
again over the project version at `:14`. They are applied as `VERSION` and
`SOVERSION` on the target at `:253-254`. The release number is a different fact:
`src/include/simdjson/simdjson_version.h:7` is `#define SIMDJSON_VERSION "5.0.2"`,
`src/CMakeLists.txt:15` is `VERSION 5.0.2`, and `simdjson.pc.in:1-11` states
`Version: 5.0.2`. `SOURCE-CONFIRMED`.

**Symptom.** "libsimdjson.so.5.0.2" and "libsimdjson.so.34" are both things a
careless writer produces, and only one of them is the soname. `std.SemanticVersion`
has exactly three components, so Zig can express `{ .major = 34, .minor = 0,
.patch = 0 }` and produce exactly the two names upstream's own build would.

**Fix.** A shared build of this package is `libsimdjson.so.34.0.0` with soname
`libsimdjson.so.34`, matching upstream's own output, and the runtime-load example
throughout this package names `.system = "libsimdjson.so.34"`. The distinction
belongs in `UPSTREAM.md` and is stated in every document that shows the name.

Also note that upstream's build writes no other number into a soname:
`src/CMakeLists.txt:464-468` adds only `-DSIMDJSON_THREADS_ENABLED=1` to
`Cflags` and `CMAKE_THREAD_LIBS_INIT` to `Libs.private`. So there is no second
ABI number to reconcile.

**Targets bound.** `SIMDJSON_LIB_SOVERSION` at this upstream tag. A release that
moved it would change every soname this package's runtime route names.

**Status.** `SOURCE-CONFIRMED`.

## 20. `-Dlinkage=dynamic` is refused where no shared object can exist, and Windows is the exception

**Condition.** One of the six required cross targets is `wasm32-wasi`, whose OS
has no dynamic linker: `std.Target.DynamicLinker.kind` is `.none` for both WASI
and Windows (`lib/std/Target.zig:2345`, whose `Kind` is `{ none, arch_os,
arch_os_abi }` at `:2336-2342`).

**Symptom.** Not a build failure — a decision with three plausible answers, two
of them wrong. Emit an archive silently and `-Dlinkage=dynamic` quietly means two
things on different targets. Fail the configure outright and one target in six
looks unbuildable. Drop `wasm32-wasi` from the matrix and the problem disappears
by deleting the question.

**The Windows exception is the part that makes this a decision rather than a
lookup.** `DynamicLinker.kind` is `.none` on Windows too, but a Windows target
*does* carry a shared object — a DLL — so keying the refusal on `.none` would
wrongly refuse the platform whose shared-object story is most conventional. The
refusal is therefore keyed on whether a shared object can exist at all, and
Windows is named separately from WASI for exactly that reason. The two families
must not be folded into one predicate.

**Fix.** `-Dlinkage=dynamic` is **refused** for a target that cannot carry one,
with a message naming the target, rather than substituted with an archive.
`wasm32-wasi` stays in the six-target `check` matrix and is covered by its static
build. The static and default builds are what cover that row.

**Targets bound.** `std.Target.DynamicLinker.kind` in Zig 0.16.0 and the set of
targets whose OS has no dynamic loader. The lesson is not "refuse more": an
option whose result depends on the target must have one meaning, and a platform
property is answered by refusing the combination rather than by inventing a
result.

**Status.** `SOURCE-CONFIRMED` for the Zig fact; the refusal itself is a
`CONSTRAINT` recorded from the wave contract **(from the contract, not from
disk)** — `build_support/graph.zig` was not on disk when this file was written, so
the check's line number and its exact message are not cited here.

## 21. Two refusals upstream offers but never raises on this path are asked of it by name

**Condition.** `document::at_end()`
(`src/include/simdjson/generic/ondemand/document.h:780-784`) is upstream's own
answer to "was the whole text read", and upstream tells the caller to ask it at
both container ends — "Users concerned with garbage content should call
`at_end()` on the document instance at the end of the processing"
(`src/include/simdjson/generic/ondemand/value_iterator-inl.h:78-80`, `:489-491`).
Upstream raises `TRAILING_CONTENT` itself only for a **root scalar**, through the
`check_trailing` argument on its `get_root_*` accessors
(`value_iterator-inl.h:664,678,710,735,902,913`); after a container root nothing
upstream looks at what follows.

The second is the same shape. A JSON integer outside 64 bits reaches this
package as `BIGINT_ERROR`, never as `number_type::big_integer`, because
`parse_number` refuses the token and returns no `number` to classify
(`src/include/simdjson/generic/numberparsing.h:949,953,969`). That is upstream's
own documented route: "If you try to parse such a number of `get_number()`, you
get the error `BIGINT_ERROR`. You can access the underlying string of digits with
the function `raw_json_token()`" (`src/doc/basics.md:3532-3533`).

**Symptom.** Two refusals the surface promises that never arrive. `{} {}` and
`[1][2]` are JSON texts with two values in them and the walk accepted both.
`{"n":18446744073709551616}` came back as `UpstreamBigint` instead of the
`NumberType.big` record the facade documents, so `bigIntegerText()` was
unreachable on every input.

**Fix.** `simdjson_br_walk` asks `document::at_end()` once, after the root value
is consumed, and answers `TRAILING_CONTENT` when it is false; and `WalkScalar`
treats `BIGINT_ERROR` as `big_integer` and takes the decimal text from
`raw_json_token()`. Both answers are upstream's own enumerators and both come
from upstream's own accessors. Neither is a rule this package invented, neither
is a second parse, and neither touches the SIMD boundary: no run-time dispatch
decision and no kernel-name comparison was added.

**Targets bound.** `document::at_end()` existing at this tag, and
`raw_json_token()` on both sources (`document.h:756`, `value.h:731`). If a later
upstream made the container ends check trailing content themselves, the ask here
becomes redundant rather than wrong.

**Status.** `PENDING-VERIFICATION`.

## 22. The 53-platform matrix is red, and the three causes are upstream's

**Condition.** `cross-test` over the published 53-platform table, run from the
package root with the package's own `cross-test.profile.sh` and this host's
approved Zig 0.16.0
(`/home/tmp2/gertullj/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/zig`),
command `cross-test --output
$HOST_SCRATCH_ROOT/scratch/foundation-libs/cross/simdjson --jobs 8 --build-jobs 8`,
run on 2026-10-05. `run_id 20261005-191536-35482-1400`, 1395 s wall clock,
harness **exit code 1**, `target_count` 53, `bookkeeping_failure` false,
counts `pass 3, fail 17, build_only 33, partial 0`. The harness reported 39 tests
per executed cell; 19 cells executed, 34 did not.

**Symptom.** Three cells pass (`x86_64-linux`, `aarch64-linux`,
`powerpc64le-linux`). Thirty-three are `build_only`, all with the harness reason
`runtime_unavailable`, because this host has no runner for them. Seventeen fail:
fifteen of them at exactly one test, one fails 34 of 39 and leaks, and one does
not build at all.

**Cause.** Three causes, all upstream's, none of them this fork's wiring.

1. **The scalar `fallback` kernel does not validate UTF-8 outside a string.**
   `src/src/fallback.cpp:198-203` calls `validate_utf8_character()` only from
   `validate_string()`; every other byte `>= 0x80` falls through to the atom
   branch at `:227-240` and is refused by stage 2 as `TAPE_ERROR`. The SIMD
   kernels do not have this hole, because their indexer runs the checker on
   every block (`src/generic/stage1/json_structural_indexer.h:241-243`). Fifteen
   cells select `fallback` as the only compiled kernel and fail
   `invalid UTF-8 is refused by the validator, and the validator agrees with
   parse` with `expected UpstreamUtf8, the facade reported UpstreamTape`: `arm`,
   `armeb`, `thumb`, `thumbeb`, `mips`, `mipsel`, `mips64`, `mips64el`,
   `powerpc`, `powerpc64`, `riscv32`, `riscv64`, `s390x`, `hexagon`, `x86`. Every
   other test passes in those cells (38 of 39).
2. **`aarch64_be-linux` runs the `arm64` kernel on a big-endian target.** 34 of
   39 tests fail and one leaks. Malformed fixtures are *accepted* —
   `01-trailing-comma-object.json` and `values/leading-zero.json` both come back
   `success` where `TAPE_ERROR` and `NUMBER_ERROR` are required, and
   `values/unescaped-control-character.json` comes back `UNEXPECTED_ERROR` — which
   is a misparse and not a difference of opinion about error codes. Upstream
   consults `SIMDJSON_IS_BIG_ENDIAN` in exactly one place in this kernel,
   `include/simdjson/arm64/numberparsing_defs.h:54-58`, and nowhere in the SIMD
   stage 1; the stage-1 table and shuffle masks are built by reinterpreting
   64-bit integers as byte vectors
   (`include/simdjson/arm64/simd.h:258-259`, and the byte-order-dependent lane
   literal at `:264`), which places the table bytes in the opposite lane order on
   a big-endian AArch64 target.
3. **`loongarch64-linux` does not build.**
   `src/src/internal/isadetection.h:298,301` read `HWCAP_LOONGARCH_LSX` and
   `HWCAP_LOONGARCH_LASX`, and the pinned toolchain's loongarch64 libc headers
   define neither. Observed compiler output:
   `use of undeclared identifier 'HWCAP_LOONGARCH_LSX'`, twice, then
   `Build Summary: 3/7 steps succeeded (1 failed)`. `__loongarch_sx` *is* defined
   for the target, so `lsx.cpp` is compiled in and the failure is inside upstream's
   own ISA detection, not in this package's target selection.

The three causes were reproduced outside this repository, so that none of them
rests on reading the log alone. A scratch package at
`$HOST_SCRATCH_ROOT/scratch/foundation-libs/cross/simdjson-probe` resolves this
package by relative path, prints `builtinImplementation()` and
`activeImplementation()`, and asks the facade what it answers for the five
invalid inputs of the failing test. Its output:

```text
builtin=fallback active=fallback          # x86-linux and riscv64-linux
validate=false parse=success len=1        # "\x80"
validate=false parse=success len=2        # "\xC0\x80"
validate=false parse=success len=3        # "\xE0\x80\x80"
validate=false parse=success len=4        # "\xF5\x80\x80\x80"
validate=false parse=UpstreamUtf8 len=9   # {"a":"\xFF"}

builtin=arm64 active=arm64                # aarch64_be-linux, under qemu-aarch64_be
parse=UpstreamUnexpected                  # where aarch64-linux answers UpstreamUtf8

builtin=fallback active=fallback          # the same haswell build, forced
parse=success len=1                       # SIMDJSON_FORCE_IMPLEMENTATION=fallback
```

The last pair matters because `x86_64-linux` is the one `x86-64` cell that
passes: the kernel this repository's graph selects for it is `haswell`, not
`fallback`, so cause 1 does not reach it. Forcing `fallback` on that same build
reproduces cause 1 exactly, which is what ties the fifteen failures to the
kernel rather than to the architecture.

**Fix.** Landed, in **note 23**. When this note was written all three causes were
recorded and none was fixed; the decision recorded here — not to weaken the test
that asserts against cause 1, and not to edit anything under `src/` — is the one
note 23 carries out. All three were fixed in this fork's own files, and no test
was weakened, no cell dropped and no failure relabelled.

**Targets bound.** Cause 1: `fallback` compiled alone, which `SIMDJSON_IS_X86_64`
and `SIMDJSON_IS_ARM64` both being false decides
(`include/simdjson/portability.h:42-103`,
`include/simdjson/implementation_detection.h:150-176`). Cause 2: `arm64` on a
target where `__BYTE_ORDER__ == __ORDER_BIG_ENDIAN__`. Cause 3: Zig 0.16.0's
loongarch64 libc headers; a toolchain that defines the two `HWCAP_LOONGARCH_*`
macros removes it, and so would a target where `__loongarch_sx` is undefined.
All three are re-derivable at a later upstream tag only by re-reading the three
named places.

**Receipts.** `cross/simdjson/cross-test-summary.json` and
`cross/simdjson/runs/20261005-191536-35482-1400/build-*.log` under this
workspace's approved scratch; `cross/simdjson-console.log`;
`cross/simdjson-runners.txt` for the runner inventory; and the per-cell table
with its classification in `cross/simdjson-matrix-report.md`.

**Status.** `OBSERVED`.

## 23. Three per-target answers that close the three boundaries of note 22

**Condition.** The same `cross-test` matrix, the same toolchain and the same host
as note 22, re-run after three changes in this repository's own files. No file
under `src/` was touched, and no test was changed.

**Symptom.** Seventeen cells failed on the first run and none fails on the second.
Harness exit code **0**, `run_id 20261005-201334-56987-6494`, 536 s,
`target_count` 53, overall `partial`, counts `pass 20 / fail 0 / build_only 33`.
The twenty executed cells all report 39/39. Against note 22's
`pass 3 / runtime_fail 16 / build-refusal 1 / build_only 33`, every one of the
seventeen is now a passing runtime cell, and the thirty-three `build_only` cells
are unchanged and are still not passes: this host has no runner for any of them,
so they compiled and were never executed.

**Cause.** Each fix answers one of note 22's three causes, and none of them is a
change to upstream.

1. **`zig/bridge.cc`, `simdjson_br_open`: UTF-8 is refused before stage 1.**
   `simdjson::validate_utf8(json, len)` is asked first, and a false answer returns
   upstream's own `UTF8_ERROR`. That is the same call `simdjson_br_validate_utf8`
   already made (`src/include/simdjson/implementation.h:18`), so `parse` and
   `validateUtf8` now agree by construction and the answer does not depend on
   which kernel the target's flags compiled in. It runs *first* so that
   `UTF8_ERROR` takes the same precedence on every target that it takes inside
   stage 1 on the SIMD ones; an empty document is valid UTF-8, so `EMPTY` is
   still stage 1's to raise. The cost is one extra linear pass over the input per
   `open`, which is a real cost and is stated here rather than hidden: it is the
   price of a refusal that does not depend on the kernel.
2. **`build_support/graph.zig`, `SIMDJSON_IMPLEMENTATION_ARM64=0` for
   `Arch.aarch64_be`.** Upstream's own switch, in its own `#ifndef` form
   (`src/include/simdjson/implementation_detection.h:28-33`), asked of the
   resolved target by `targetCanRunArm64Kernel`. It moves a big-endian AArch64
   build to upstream's scalar `fallback` kernel, which is byte-order agnostic —
   `s390x-linux` is big-endian and runs it. Zig carries the byte order in the
   architecture itself, so the check names `.aarch64_be` as its own value
   (`lib/std/Target.zig:1328`) and not a flag on `.aarch64`; an earlier version
   of this check asked `Arch.endian()` behind an `arch != .aarch64` guard, which
   never fired for the target it was written for and left the cell red. That
   mistake is this note's own and is recorded rather than removed.
3. **`build_support/graph.zig`, `HWCAP_LOONGARCH_LSX` and
   `HWCAP_LOONGARCH_LASX` for `loongarch64`.** The two kernel capability
   constants, `(1 << 4)` and `(1 << 5)`, passed on the compile line for that
   target only. Upstream's LoongArch ISA detection reads them with no `#ifndef`
   guard (`src/src/internal/isadetection.h:298,301`) and the only headers that
   define them are the kernel's `asm/hwcap.h`, which a C library need not ship.
   Upstream already closes this exact gap for its own AArch64 branch in the same
   file, for the same reason, by defining the kernel's values itself rather than
   including `<asm/hwcap.h>` (`:86-97`); this is that answer for the branch
   upstream left open. The values are the kernel's own
   (`arch/loongarch/include/uapi/asm/hwcap.h:10-11`, Linux v6.19-rc8) and are
   passed as the same token sequence the kernel header uses, so a toolchain that
   does define them redefines them identically and no diagnostic follows.

**Fix.** The three above. All three are build-configuration or facade changes in
this repository's own files: no vendored header was edited, no test expectation
was changed, no skip and no `|| true` was added, and the two assertions that
failed — that a document which is not valid UTF-8 is refused with `UpstreamUtf8`,
and that `validateUtf8` agrees — are still there and now hold on every target.

**Targets bound.** Fix 1 is bound to no target: it is the same on all of them,
and it is redundant on a target whose kernel already validates. Fix 2 is bound to
`Arch.aarch64_be`; any other architecture keeps `arm64`'s upstream answer, and a
little-endian AArch64 target keeps the `arm64` kernel. Fix 3 is bound to
`loongarch64`; no other target compiles upstream's LoongArch branch. Both
per-target macros live in `cppMacros`, which is a per-target call
(`build_support/graph.zig:319`), so neither is ever decided from the host. A later
upstream that closes any of the three in its own source makes the matching macro
redundant rather than wrong; the `#ifndef`-guarded form upstream uses for its own
constants means passing them stays correct either way.

**Status.** `OBSERVED`. `zig build` exit 0; `zig build test` exit 0, 39/39, Debug
and `-Doptimize=ReleaseSafe`; `zig build smoke` exit 0; `zig build check` exit 0,
43/43 steps; `zig build consumer` exit 0, 6/6 steps; `tools/check-provenance.sh`
exit 0, `provenance checks passed`. `zig build -Dlinkage=dynamic` and
`zig build check -Dlinkage=dynamic` each exit 1 by the refusal `README.md` §3
states in advance, which names `wasm32-wasi` and comes from `deliveredLinkage`
(`build_support/graph.zig:776`), a path this work does not touch.