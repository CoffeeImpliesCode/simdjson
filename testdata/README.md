# testdata/README.md — where each fixture came from, and what it is for

22 fixtures, 645673 bytes. Every one has a SHA-256 in `UPSTREAM.sha256` (the
last 22 records), so `tools/check-provenance.sh` fails if any of them changes by a
byte without the record changing with it.

`tests.zig` and `smoke.zig` read them through the build-created `simdjson_paths`
import, whose value `build.zig` resolves to an **absolute** path from the build
root at configure time. That is deliberate: the fixtures are read from this
checkout and never from an installed prefix, because nothing in the install
layout installs them, and a test binary that found them under `--prefix` would be
reading files no gate had recorded. It is also why `package.nix` sets
`doCheck = false` -- a Nix derivation does not control where this checkout is.

## The three groups

| group | count | whose bytes are they |
|---|---|---|
| `testdata/rfc8259/` | 5 | transcribed from **RFC 8259**, a published standard |
| `testdata/large/` | 1 | a byte-identical copy of **upstream's own** `src/jsonexamples/twitter.json` |
| `testdata/malformed/`, `testdata/values/` | 16 | **authored by this fork**, one per behaviour |

The middle group is upstream's and is the interoperability fixture: the tests read
it as a large, deeply nested real document and check that this facade reaches the
structure upstream's own example describes. The other two groups exist because a
standard and a specific behaviour each need something the other cannot supply.

Nothing here is a *snapshot of what the parser produced*. Every expected value in
`tests.zig` and `smoke.zig` is written in the test from the RFC's own text, from
IEEE 754's properties, or from upstream's own error enumeration -- which is what
`AGENTS.md` §7 requires, and why a test here can fail when the library is wrong
rather than only when the fixture drifts.

---

## `testdata/rfc8259/` — RFC 8259 section 13

The five documents of **RFC 8259 section 13, "Examples"**: one JSON object, one
JSON array containing two objects, and the three small texts that hold only a
value. The grammar they exercise is section 2's object/array, section 3's
string, section 6's `number` and `int`, and section 7's `string` and escapes.
The `13-` prefix in each file's name is that section number.

### `rfc8259/13-value-number.json` — 3 bytes

```
42
```

The section 13 text `42`. The value it denotes is 42, and a parser must
report it as an **integer**: upstream's split classifies a literal with no
fraction and no exponent as `signed_integer`
(`src/include/simdjson/base.h:43-48`). That split is upstream's, not the RFC's --
RFC 8259 section 6 has one `number` production -- and the fixture is what proves
this facade reaches the value the RFC spells.

Used by: the RFC-8259-number test in `tests.zig` and the first check in
`smoke.zig`.

### `rfc8259/13-value-string.json` — 15 bytes

```
"Hello world!"
```

The section 13 text `"Hello world!"`. Twelve bytes of text between the quotation
marks, with no escape sequence in it. It is the smallest fixture that proves the
walk copies string bytes out of upstream's padded buffer and hands back a slice
that is *not* NUL-terminated -- appending to the returned slice must not touch
what follows it in the blob.

Used by: the RFC-8259-string test and the `smoke.zig` check.

### `rfc8259/13-value-boolean.json` — 5 bytes

```
true
```

The section 13 text `true`. Two things are worth testing about a boolean in
this surface: `true` is an answer and "not a boolean" is a *different* answer
(`bool()` returns `?bool`), and a boolean is not a number, so its `numberType` is
`.none` -- this package's addition, since upstream has no `number_type` for a
value that is not a number.

### `rfc8259/13-array.json` — 445 bytes

Section 13's first example, "This is a JSON array containing two objects". Two
objects with the same eight keys in the same order and different values:
`precision`, `Latitude`, `Longitude`, `Address`, `City`, `State`, `Zip`,
`Country`.

It is the only fixture that exercises several things at once on real data:

* `Zip` is a JSON **string** (`"94107"`) that looks like an integer. A parser that
  guessed from the text would report a number; the test asserts `string()` and
  that `bigIntegerText()` is null for it.
* `Latitude` and `Longitude` are written with a decimal point and no exponent, so
  upstream calls them `floating_point` and the facade answers `double()`.
* `Address` is `""` -- an empty string, which is *present* and must not read as
  absent.
* Every key is read by name, twice, through `Object.get`'s linear search over a
  real record stream rather than a three-field toy.

### `rfc8259/13-object.json` — 308 bytes

Section 13's second example, "This is a JSON object". **One** top-level key,
`Image`, whose value is an object with **six** members -- `Width`, `Height`,
`Title`, `Thumbnail`, `Animated: false` and an `IDs` array of four integers
(`116, 943, 234, 38793`) -- and whose `Thumbnail` member is an object three
levels down from the document's root value.

The nesting is the point: `Thumbnail`'s record is at `depth` 2 of the walk, which
is what makes a pre-order record stream navigable at all. The test also checks
the **document order** of `Image`'s six members through the positional
`Object.at`, because `at` is positional and `get` is not.

---

## `testdata/large/`

### `large/twitter.json` — 631515 bytes

```
sha256 30721e496a8d73cfc50658923c34eb2c0fbe15ee6835005e43ee624d8dedf200
```

A **byte-identical copy of upstream's own `src/jsonexamples/twitter.json`**. This
is the interoperability fixture: the bytes are upstream's, so a test that walks
them and reaches upstream's own top-level structure is a test against a reference
this package did not author.

What it is for, and what it is *not* for:

* **It is not a speed test.** A timing assertion here would be a claim about the
  machine that ran it, about which SIMD kernel the flags selected, and about the
  input. The first two are exactly the facts `FORK-NOTES.md` note 7 says a caller
  must not pin. `smoke.zig` walks this document and prints nothing about time.
* **Its record count is derived, not pinned.** The test walks it and checks the
  structural invariant -- every record's `count` equals the number of following
  records at exactly `depth + 1` -- over *every* record. A constant record count
  would be a version pin wearing a test's clothes; the digest in `UPSTREAM.sha256`
  is what pins the bytes.
* The three top-level keys (`statuses`, `search_metadata`, `query`) and the
  `text` member of every status are read through `Object.get`, which exercises
  the linear search over a genuinely deep, large document rather than a toy one.

It is also the reason `build.zig:fixture_bound` is 8 MiB rather than something
smaller: `readFileAlloc` returns `error.StreamTooLong` rather than truncating, so
a fixture that outgrew the bound would fail loudly instead of being read in part.

---

## `testdata/malformed/` — eight refusals, one per upstream error

Each file is a document RFC 8259's grammar does not admit. Each test asserts the
**specific** upstream `simdjson::error_code`, not merely that parsing failed: the
classification is what a caller branches on, and a test that accepted any error
would pass for the wrong reason.

`FORK-NOTES.md` note 14 names the upstream line for each, and the reason five of
them are `TAPE_ERROR` rather than a more specific code is upstream's own
classification carried across the API boundary -- not a code invented at the seam.

| file | bytes | document | error | why, in upstream's terms |
|---|---|---|---|---|
| `malformed/01-trailing-comma-object.json` | 8 | `{"a":1,}` | `TAPE_ERROR` | RFC 8259 section 4's `members` production is a comma-separated list with no trailing comma. The second `field_key` is handed `}`, which is not a token start. |
| `malformed/02-single-quoted-string.json` | 9 | `{'a':'b'}` | `TAPE_ERROR` | RFC 8259 section 7 defines strings with `quotation-mark` = `"` only. The second `field_key` is handed `'`. |
| `malformed/03-unquoted-key.json` | 5 | `{a:1}` | `TAPE_ERROR` | RFC 8259 section 4 requires a member name to be a string. The second `field_key` is handed `a`. |
| `malformed/04-nan-literal.json` | 9 | `{"a":NaN}` | `TAPE_ERROR` | `N` is not a token start, so `value_iterator::type` answers `json_type::unknown` and the bridge stops the walk. With `SIMDJSON_ENABLE_NAN_INF=0` (which this package passes explicitly) the number parser would also refuse it -- but the bridge dispatches on `type()` first, so `TAPE_ERROR` is the answer that arrives. |
| `malformed/05-leading-plus-number.json` | 8 | `{"a":+1}` | `TAPE_ERROR` | RFC 8259 section 6's `number = [ minus ] int ...` allows `minus` but not `plus`. `+` is not a token start, the same arm as above. |
| `malformed/07-missing-colon.json` | 7 | `{"a" 1}` | `TAPE_ERROR` | RFC 8259 section 4 requires `name ":" value`. `field_value` checks for the `:` explicitly. |
| `malformed/08-unterminated-string.json` | 8 | `{"a":"b}` | `UNCLOSED_STRING` | The opening quote has no partner. Upstream's string scanner tracks `prev_in_string` across blocks and reports it only at the end of the input, which is why this one is *not* `TAPE_ERROR`. |

| `malformed/09-empty-input.json` | 0 | *(empty)* | `EMPTY` | RFC 8259 section 8's `JSON-text = ws value ws` requires a value. Upstream's name is "no structural element found". |

**The numbering has a gap on purpose.** There is no `06-*.json`. The files are
named for the order in which a reader would look for them, and `06` was never
needed; renaming a recorded fixture would change its digest, and `UPSTREAM.sha256`
is the authority on that. The gap is recorded here rather than papered over with
a renumbering.

The empty file's digest is
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`, the SHA-256
of the empty byte sequence. That is what an empty file hashes to; it is recorded
rather than left as a blank line, because `sha256sum` prints it that way and a
reader comparing the two must not have to guess whether the absence is a typo.

---

## `testdata/values/` — eight authored behaviours

### `values/number-grammar.json` — 217 bytes

Seventeen JSON numbers, chosen to cover the whole of RFC 8259 section 6's grammar
and the edges of binary64:

```
-0, 0, 1, -1, 42, 3.5, -3.5, 1.5e10, -1.5e10, 1E22, 1e-2, 1.5e-300,
0.000000000000000000000000001, 123e65, 2.2250738585072011e-308,
1.7976931348623157e308, -1.7976931348623157e308
```

* The five integer literals exercise upstream's `signed_integer` classification,
  and include `-0`: RFC 8259 section 6's `int = zero / (digit1-9 *DIGIT)` with an
  optional leading `minus` makes `-0` legal, its value is negative zero, and its
  *integer* value is `0` -- negative zero is not representable in an `i64`. The
  test says so rather than leaving a reader to wonder.
* `2.2250738585072011e-308` is the smallest normal binary64 and
  `1.7976931348623157e308` is the largest finite one. The test compares them
  against IEEE 754's own values, not against a copy of the parser's output.
* The twelve floating literals are compared for **equality**, not for an
  epsilon, because each is either exactly representable or has a single correct
  binary64 rounding.

### `values/leading-zero.json` — 8 bytes

```
{"a":01}
```

The single fixture that decides how this package reads a number, and the reason
it exists at all.

RFC 8259 section 6 forbids it: `int = zero / (digit1-9 *DIGIT)`, so a leading zero
may not be followed by another digit. Upstream's *peek* at a number's shape --
`value::get_number_type()` -- has **no leading-zero check at all**
(`src/include/simdjson/generic/numberparsing.h:1526-1568`), so it classifies `01`
as a signed integer. The guard lives in the real parser instead, at
`numberparsing.h:905-906,919`.

This package parses the number rather than peeking, so `{"a":01}` is **refused**
with upstream's `NUMBER_ERROR` (9) instead of being read as `0` with a number type
attached. A bridge that peeked first would have had to choose between reporting a
number type for an invalid document and refusing it; this one refuses. The test
asserts the refusal *and* the error, because a parser that returned `0` would be
the specific bug this fixture exists to catch. `FORK-NOTES.md` note 5 is the
decision record.

### `values/unescaped-control-character.json` — 11 bytes

```
{"a":"x<0x01>y"}
```

where `<0x01>` is a literal SOH byte (U+0001) at index 7 and the file therefore
contains a raw control character, not an escape.

RFC 8259 section 7: "All Unicode characters may be placed within the quotation
marks except for the characters that must be escaped: quotation mark, reverse
solidus, and the control characters (U+0000 through U+001F)."

This fixture is here for the *pairing*. U+0007 is perfectly valid UTF-8, so a
validator-only check would pass it -- and upstream's own name for the refusal is
`UNESCAPED_CHARS` (`src/include/simdjson/error.h:34`), not `UTF8_ERROR`. The test
asserts both halves: `validateUtf8` says **valid**, and `parse` refuses with
`UpstreamUnescapedChars`. A facade that reported a UTF-8 error here would be
wrong, and this is the fixture that says so.

### `values/duplicate-keys.json` — 32 bytes

```json
{
  "a": 1,
  "b": 2,
  "a": 3
}
```

RFC 8259 section 4 says member names "SHOULD be unique" and that behaviour is
"unpredictable" if they are not -- but the grammar does not forbid them. So a
parser must neither refuse the document nor silently collapse it.

This package's `Object.get` is a linear search over the records and finds the
**first** match, which is what a caller reading the document in order would have
seen first. The test asserts both halves: `get("a")` is `1`, *and* the record for
the second `"a"` is still in the walk and readable through `Object.at(2)` with the
value `3`. A facade that collapsed the duplicate would pass the first assertion
and fail the second, which is why both are here.

### `values/string-escapes.json` — 166 bytes

Fifteen strings covering RFC 8259 section 7's entire escape table and section 3's
UTF-8 encoding. The file's own text:

```
[
  "\"",
  "\\",
  "\/",
  "\b",
  "\f",
  "\n",
  "\r",
  "\t",
  "\u0041",
  "\u00e9",
  "\u4e2d\u6587",
  "\ud834\udd1e",
  "\ud83d\ude00",
  "\u00fcber",
  "A"
]
```

The first eight are section 7's two-character escapes, and each is compared in
the test against the byte it names -- `"\b"` is checked against `\x08` rather
than against `\b`, so the two spellings cannot agree by accident. The last
element is a plain `"A"` with no escape at all, so a test cannot pass by
assuming every element starts with a backslash.

The two surrogate pairs are the reason this fixture exists. `\ud834\udd1e` is one
code point, U+1D11E MUSICAL SYMBOL G CLEF, outside the basic plane, and RFC 8259
section 3 encodes it as **four** UTF-8 bytes. A decoder that handled each
surrogate separately would produce six bytes of something else. The test asserts
both the value and the byte length -- `1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 6, 4, 4, 5, 1`
for the fifteen -- which is where a UTF-16 output would differ most visibly. The
fourteenth is `ü` (two bytes) followed by `ber`, so it is the one length that is
neither one byte nor a whole multi-byte sequence.

### `values/nesting-32.json` — 202 bytes, and `values/nesting-64.json` — 394 bytes

```
{"a":{"a":{ ... 32 levels ... {"leaf":1} }}}
{"a":{"a":{ ... 64 levels ... {"leaf":1} }}}
```

Two documents that differ only in depth and carry the same leaf. They are the
independent check on `Record.depth` and on `Value.at`'s pre-order walk: the depth
recorded for the leaf must be *the fixture's own nesting*, not a constant, and
both are below `DEFAULT_MAX_DEPTH` so neither is refused.

The counts they establish: the `levels` objects carrying an `a` key occupy depths
0 through `levels - 1`, the object that holds `leaf` is the next one down at
depth `levels`, the leaf's own value is at depth `levels + 1`, and a record is
one *value*, so the walk holds `levels + 2` records. Both tests in `tests.zig`
and both reports in `smoke.zig` assert all four.

### `values/nesting-2048.json` — 12298 bytes

The same shape at **2048 levels** -- 2048 `{"a":` nestings and the object that
holds `leaf`, so 2049 `{` bytes in all -- which is twice `DEFAULT_MAX_DEPTH`
(1024, `src/include/simdjson/base.h:49`).

This fixture is `PENDING-VERIFICATION` on one specific point, and the point is
this package's decision rather than upstream's. Upstream's depth limit sizes
`parser::start_positions` and nothing else
(`src/include/simdjson/generic/ondemand/parser-inl.h:36`); stage 1 indexes every
depth it is given, and with `SIMDJSON_DEVELOPMENT_CHECKS` the bound reaches an
assertion in `json_iterator::set_start_position`
(`src/include/simdjson/generic/ondemand/json_iterator-inl.h:432-434`,
`src/include/simdjson/portability.h:243-246`) that a process aborts on rather
than an error a caller reads. `build_support/graph.zig` passes
`SIMDJSON_DEVELOPMENT_CHECKS=1` on **every** target in **every** optimize mode,
and `zig/bridge.cc` therefore compares the walk's own depth against upstream's
`DEFAULT_MAX_DEPTH` and answers upstream's `DEPTH_ERROR`.

So on this build the fixture is refused with upstream's `DEPTH_ERROR`, and it is
refused the same way in Debug and in ReleaseSafe. That is the whole reason: a
depth limit that is an abort in one mode and nothing in another is a limit
nobody can rely on.

**The boundary this is not.** `FORK-NOTES.md` note 8 is the decision record, and
its "Targets bound" line says how to overturn it: dropping the define restores
upstream's behaviour, where the same document aborts the process instead of being
refused. If a later wave drops it, this fixture's refusal becomes this bridge's
alone, and that is a decision to be made deliberately and recorded, not a drift
to be discovered.

The test also counts the `{` bytes in the file before parsing it, so a fixture
that stopped being deeply nested would fail for a reason that has nothing to do
with depth.

---

## How to add one

An authored fixture is a small thing and the rules for it are short:

1. One file, one behaviour. If a test needs two documents, it says so in a
   literal -- literals are clearer than files for a boundary, and the four
   refusals in `tests.zig` that use literals say so.
2. Give it a name that says the behaviour, not the syntax. `leading-zero.json`,
   not `06-malformed.json`.
3. Add its `sha256sum` line to `UPSTREAM.sha256` under the `testdata/` block.
4. Add a row here: what it is, where it came from, and which test reads it.
5. If the fixture needed a comment to be understandable, put that comment **here**
   rather than inside the file -- a JSON document carrying a comment in it is no
   longer a JSON document, and being loadable by the library under test is the
   only reason these files exist.

`tools/check-provenance.sh` then checks all of it, including that no file under
`testdata/` is missing from the manifest or present without one.