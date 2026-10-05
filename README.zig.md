# README.zig.md — the Zig interface

What `@import("simdjson")` gives a dependent: every declaration, what it promises,
what it refuses, and what it does not do. `zig/root.zig` carries the same contract
in doc comments; this file is the reader's view of it, with the reasoning that
does not belong on a declaration.

**No gate has been run against any of it.** Everything here is
`PENDING-VERIFICATION`.

---

## What this module is

One Zig module, reachable three ways and always by the same name:

```zig
const dep = b.dependency("simdjson", .{ .target = target, .optimize = optimize });
exe_mod.addImport("simdjson", dep.module("simdjson"));
```

```zig
const simdjson = @import("simdjson");
```

That is the whole integration. There is no second module name, no per-target name
and no relative-import route. The module carries the library, the C runtime and the
C++ runtime with it, so a dependent states none of them.

## The shape of the thing

```zig
const doc  = try simdjson.parse(json);      // a *parsed* document
var walk   = try doc.walk(allocator);       // the only readable form
const root = walk.root().?;                 // one Value
const obj  = root.object().?;               // a view over walk's records
for (obj.get("a").?.value.array().?.items()) |item| { ... }
```

Three properties are worth stating before any individual function, because every
type below is a consequence of them.

### 1. `parse` gives a parsed document, not a read one

Opening a document runs stage 1 over the whole input and reports every structural
error there. A `Document` that exists has a structurally sound input; reading it is
`walk`, and it is one call.

That split exists because upstream's On-Demand API is **one-shot**: upstream states
the rule in its own words at
`src/include/simdjson/generic/ondemand/document.h:560-569` — "You must consume the
fields on an object one at a time. A request for a new key invalidates previous
field values" — and again at `:587-611` for `operator[]` and `:595-604` for
`find_field_unordered`. `document::find_field` additionally refuses outright when
the document is not at its root
(`src/include/simdjson/generic/ondemand/document-inl.h:77-79`). The compiler-visible
form of the same rule is `OUT_OF_ORDER_ITERATION`
(`src/include/simdjson/error.h:46`), and the iterator contracts are tighter still:
`array_iterator::operator*` is "MUST ONLY BE CALLED ONCE PER ITERATION"
(`src/include/simdjson/generic/ondemand/array_iterator.h:53-54`).

### 2. `Walk` is a copy, not a cursor

A cursor cannot cross a C ABI here: `value_iterator`'s validity depends on parser
state a caller in another language has no way to maintain, and `OUT_OF_ORDER_ITERATION`
exists precisely because that invariant is not expressible in a signature.

So `simdjson_br_walk` is the only way to read a document through the bridge, and it
produces a flat pre-order sequence of fixed-width records plus one blob buffer.
`Array` and `Object` are then **views over those records**: iteration reads
already-copied memory, so it can be repeated, interleaved and nested with none of
upstream's restrictions, and `Object.get` is an ordinary linear search rather than a
`find_field` that refuses out-of-order access.

**What it costs, stated plainly:** one full copy of every value in the document.
`Walk.nodes` is one `Record` per value and `Walk.blobs` is one byte per key byte
and per string byte. On a document you do not parse twice, that is memory the DOM
path would not have needed. The offset buys no borrowed value with a hidden
lifetime, no way to trip `OUT_OF_ORDER_ITERATION` at all, a walk that can be
re-read and randomly indexed, and `Document.walk` being callable more than once.
`FORK-NOTES.md` note 2 is the record.

### 3. This is On-Demand, and only On-Demand

`simdjson.h` also offers `dom::parser`, `document_stream`, `minify` and compile-time
JSON. **None of them is in this module**, and none of the DOM API's types is.

The absence is a decision with a reason, not an omission. `simdjson::ondemand` is a
namespace alias bound to one compile-time-selected kernel through
`src/include/simdjson/builtin/ondemand.h:39`, its members are class templates, and
`simdjson_result<T>` returns cannot be named by a C translation. `zig/bridge.cc`
exists because of that, and what it wraps is On-Demand.

**A C++ consumer is not affected**: the installed `include/simdjson/` tree is
upstream's complete public header set, 234 files, unmodified, so every one of those
APIs is reachable without going through this binding at all.

---

## The types

### `Document`

Owns exactly one thing: the bridge handle. That handle owns the padded copy of the
input, the parser and the document, and `deinit` releases all three.

```zig
var doc = try simdjson.parse(json);
defer doc.deinit();
var walk = try doc.walk(allocator);
defer walk.deinit();
```

* **`deinit` on a default-constructed `Document` does nothing.** The handle is null
  and the function checks it, which is what makes `defer doc.deinit()` after a
  *failed* `parse` the right shape rather than a double free.
* **A rejected `parse` constructs nothing.** The caller's `Document` variable is
  left exactly as it was — a failed parse does not clear a previous document and
  does not hand back a half-open one.
* **`walk` may be called more than once on the same `Document`**, and each call sees
  the same document. Upstream's `document::rewind()`
  (`src/include/simdjson/generic/ondemand/document.h:763`) runs before each pass.
* **A failed `walk` leaves nothing allocated.** Both allocations happen only after
  the sizing call has succeeded, and the sizing call is the one that reads the whole
  document.

### `Walk`

```zig
pub const Walk = struct {
    backing_allocator: std.mem.Allocator,
    nodes: []Record,
    blobs: []u8,

    pub fn deinit(self: *Walk) void;
    pub fn root(self: Walk) ?Value;
    pub fn count(self: Walk) usize;
};
```

* **`nodes` is in pre-order**: a container's record precedes every record beneath
  it, and within a container the records appear in document order.
* **`blobs` holds every object key and every string value**, unescaped and **not
  NUL-terminated**, at the offsets the records name.
* **`depth`** on each record is 0 at the root and one more per level of nesting.
* **`deinit` leaves `nodes` and `blobs` as the empty slices** rather than dangling
  pointers, so reading a used `Walk` yields "no values" instead of a fault.
  Calling it twice is safe: the second call frees two empty slices.
* **The allocator is stored in the walk** so `deinit` cannot be called with the
  wrong one, which for most allocators is undefined rather than merely wrong.

### `Value`, `Array`, `Object`, `Field`

All four borrow from the `Walk` that produced them and are invalid the moment that
walk is deinitialized. Holding one across a `deinit` is the only lifetime rule on
them, and it is the same rule upstream's own iterators have.

```zig
// Object
obj.len()                      // how many fields
obj.at(n)          ?Field      // by position, in document order
obj.get("name")    ?Field      // by name; the FIRST match
obj.iterator()     ObjectIterator
obj.reset()        ObjectIterator
obj.items()        ObjectIterator

// Array
arr.len()
arr.get(n)         ?Value
arr.iterator()     ArrayIterator
arr.reset()        ArrayIterator
arr.items()        ArrayIterator

// Field
field.key          []const u8  // unescaped, borrowed, not NUL-terminated
field.value        Value

// Value
v.type()          ValueType
v.count()         usize
v.array()         ?Array
v.object()        ?Object
v.string()        ?[]const u8
v.int()           ?i64
v.uint()          ?u64
v.double()        ?f64
v.bool()          ?bool
v.isNull()        ?bool
v.numberType()    NumberType
v.bigIntegerText() ?[]const u8
v.at(n)           ?Value
```

**`items()` is O(len²)** in the worst case, because each element is reached by a
walk over the records under that container. That is the honest cost of reading a
pre-order stream by index, and it is why `iterator()` exists: it advances a single
position and is linear. Use `iterator()` for anything but a handful of elements.

**`Object.get` returns the first match.** An object with a repeated key has more
than one answer, and this reports the earlier one — which is what a caller reading
the document in order would have seen first. RFC 8259 §4 says member names SHOULD
be unique and that behaviour is unpredictable otherwise; a parser must neither
refuse such a document nor collapse it.

**Absent is not the same answer as present-and-null.** `obj.get("x") == null` means
no such field. `v.isNull() == null` means `v` is not JSON null. `v.isNull().? ==
true` means it is. Three distinguishable answers.

### `Record`

A hand-written duplicate of `simdjson_bridge_node` (`zig/bridge.h:319-367`). It is
hand-written rather than imported because this module *is* the thing that imports the
translated header, and the record is handed to a caller whose code was compiled
against a possibly different header; one definition of the layout in the module
that publishes it is what keeps the two describable.

`Record` is exposed for reading. The typed accessors above read through it so a
caller never has to hold one and keep it in step.

### `ValueType` and `NumberType`

```zig
pub const ValueType = enum(u32) { unknown = 0, array = 1, object = 2,
                                  number = 3, string = 4, boolean = 5, null = 6 };

pub const NumberType = enum(u32) { none = 0, floating_point = 1,
                                   signed = 2, unsigned = 3, big = 4 };
```

`ValueType.unknown` is **not** a "no idea" filler: it is what upstream answers for a
value whose first byte is not a JSON token start, so a `Walk` containing one was
produced by a provider that let such a value through rather than refusing the
document — and the walk refuses it in turn.

`NumberType.none` is **this package's addition** and has no upstream counterpart:
it is the value on a record that is not a number at all. `NumberType.big` is
upstream's `big_integer`, a JSON integer too large for 64 bits, whose decimal text
is in the record's string bytes and whose numeric fields are all zero.

### `Error`

The taxonomy has two halves and they are not interchangeable.

The first three are this bridge's own statuses: `InvalidArgument` (a bad argument),
`BufferTooSmall` (a caller buffer too small), `OutOfMemory` (an allocation that
failed), plus `UnknownStatus` for a status outside the enumeration.

**Every name after that is one member of upstream's `simdjson::error_code`
(`src/include/simdjson/error.h:19-54`), at upstream's own integer.** The whole
enumeration is present, not only the members this bridge has been seen to produce,
because the walk can be handed any of them and a caller reading a refusal deserves a
name. `zig/bridge.cc` `static_assert`s every value against the real enumerator on
every target that builds the library, so the mirror cannot disagree with what the
library reports. `UpstreamUnnamed` is the one addition: an integer outside the
enumeration, which is a fact about the provider rather than about upstream.

`BufferTooSmall` is documented as unreachable from the typed surface: every
buffer-taking call there allocates for itself. It is in the set because a caller
reading `c` can produce it.

`upstreamError(code)` is the only place in the module that turns a raw
`simdjson::error_code` integer into a name.

### `c` — the raw route

`pub const c` is the **complete** translated `zig/bridge.h`, not a filtered view:
the eleven entry points and every `SIMDJSON_BRIDGE_*` constant are all there. Reach
for it when you need something this facade does not wrap, or the raw integer behind
an upstream error code.

In a runtime-loaded build `c` is a generated dispatch rather than the translation
step's own output. It publishes the same namespace: the constants are re-exported
from the translated header rather than restated, so there is one spelling of each
either way. What differs is how a name reaches the library — direct in a linked
build, through a table that `load` fills in a runtime-loaded one.

**Three obligations a raw call carries that the typed surface does not:**

1. `out` pointers must be non-null except where a particular entry point's comment
   says otherwise. There is no null check on the value outputs of most of them and
   no way to drop an out-parameter.
2. `simdjson_br_walk`'s buffers and capacities are a two-pass contract, and a caller
   that gets it wrong is told `BUFFER_TOO_SMALL` with both required counts written —
   but a caller that reads those counts as "how much was written" has misread them:
   **they are the sizes required, on every status including success**.
3. An upstream error arrives as `SIMDJSON_BRIDGE_UPSTREAM_ERROR` plus an integer in
   `out_error`. That integer is the raw value of a `simdjson::error_code`
   enumerator, and `upstreamError` is the only place it becomes a name.

---

## Allocation

Exactly two things cross into the caller's allocator, and both are caller-chosen.

| allocated by | with | freed by |
|---|---|---|
| the input bytes | the bridge's own `padded_string` | `simdjson_br_destroy`, inside `Document.deinit` |
| `Walk.nodes` | the allocator `Document.walk` is given | `Walk.deinit`, to **that** allocator |
| `Walk.blobs` | the same | the same |
| every string and key | the walk's blob, copied out of upstream's buffer | with the blob |

Nothing else in this module allocates.

**The input slice is borrowed for the duration of `parse` and copied by the
bridge.** It may be freed or reused the instant `parse` returns, and nothing here
retains it. The copy exists because upstream refuses an unpadded buffer:
`SIMDJSON_PADDING` is 64 (`src/include/simdjson/base.h:42`) and `parser::iterate`
returns `INSUFFICIENT_PADDING` before it reads a single byte otherwise
(`src/include/simdjson/generic/ondemand/parser-inl.h:54-55`). The padding is
load-bearing, not a formality: stage 2's `parse_string` takes no end pointer and
scans until it finds a closing quote
(`src/src/generic/stage2/stringparsing.h:151-159`).

Where memory crosses into a third-party allocator — upstream's `std::string`
returns, `padded_string`'s buffer — **the test framework cannot supply a leak
oracle for it.** `Document.deinit` is what releases those, and it is inside the
library.

---

## Runtime loading

`-Druntime=true` selects a second configuration of the same graph. In it:

* the module links **no archive**, and nothing in the consumer's link line refers
  to one;
* the eleven entry points are resolved through the platform loader when you call
  `load(source)`;
* a call into a module that has not loaded **stops the program** with a message
  naming the function, in every optimization mode.

```zig
if (comptime simdjson.runtime_loaded) {
    try simdjson.load(.{ .path = "/usr/lib/libsimdjson.so.34" });
}
```

`runtime_loaded` is a comptime constant, so a consumer that supports both
configurations writes one branch and only the branch it chose is analysed.

### The contract

* **The provider is reached, never guessed.** `.path` names a file and `.system`
  names a library for the platform loader. There is **no path-to-system fallback**
  and no implicit fallback of any kind; a request that cannot be honoured is an
  error, not a different library.
* **The request must match.** Calling `load` again with the same request succeeds
  and changes nothing; calling it with a different request after a success is
  `ProviderMismatch`, and the library already in use stays in use.
* **A failed attempt publishes nothing** and can be retried explicitly, by calling
  `load` again. There is no automatic retry and no implicit second source.
* **There is no unload and no reset.** The table is process-global state that other
  code may already have called through, so the handle and the loader's own copy of
  the request live to the end of the process.
* **Safe from any thread.** A thread arriving while an attempt for the same request
  is in flight waits for it and gets its result, whatever it was. A call from the
  thread running the attempt is `ReentrantLoad` rather than a deadlock.
* **A pre-load call is a programming error, not a recoverable condition.** The
  table does not exist yet and there is no partial state to fall back on, so it
  stops the program rather than returning something plausible.

### What a provider must be

A shared object exporting all eleven entry points, and **nothing else is
required**. `runtime/library.zig` states the full contract and what the load-time
check does and does not prove. Two things it does **not** check, and they are worth
knowing:

* **Which kernel the provider's dispatcher selected is not a compatibility
  requirement and is not checked.** `SIMDJSON_FORCE_IMPLEMENTATION` moves it, and
  it is a fact about the host and the environment rather than about the ABI.
* **The ABI is `zig/bridge.h`'s record layout and status values**, not upstream's
  C++ API. Those are class hierarchies in a namespace bound to a compile-time-
  selected kernel, and there is no symbol a C translation could name.

### What a *static* install cannot be

A static install cannot itself be a provider: **an archive is not a file the
platform loader can open.** What a runtime-loaded caller needs is the shared object
`-Dlinkage=dynamic` installs — `libsimdjson.so.34.0.0`, soname
`libsimdjson.so.34` — or some other shared object exporting the same eleven
symbols. `build.zig` says so at configure time rather than letting you discover it
as a missing file from the loader.

---

## What this module deliberately does not do

No DOM. No `document_stream`. No minifier. No JSON writer. No JSON-Pointer or
JSONPath lookup. No builder. No UTF-8 validator of its own — `validateUtf8` *is*
`simdjson::validate_utf8` (`src/include/simdjson/implementation.h:18`), which is
also the validation the library runs internally during stage 1
(`src/include/simdjson/common_defs.h:365-366`).

Every one of those is reachable from C++ through the installed `include/simdjson/`
tree, which ships whole and unmodified. The list is here so a reader knows the
boundary was chosen rather than missed.

---

## The build facts a consumer is bound to

**Compiler.** Zig 0.16.0, which is what `build.zig.zon` states as
`minimum_zig_version`.

**ABI.** Everything this module returns crosses the C ABI `zig/bridge.h` declares,
so what you are bound to is *that header's* record layout and status values.

**Compiled from.** Upstream's own headers and translation unit at a pinned
`-std=c++17`, plus this fork's `zig/bridge.cc` at the same standard and under the
same configuration macros. A dependent that reaches this module through
`dep.module` in a linked build gets it with libc and the C++ runtime.

**The configuration macros.** Three are this package's choice and are the same
everywhere: `SIMDJSON_DEVELOPMENT_CHECKS=1`, `SIMDJSON_ENABLE_NAN_INF=0`,
`SIMDJSON_EXCEPTIONS=0`. The first is **this package's decision, not upstream's
default**, and it means `DEFAULT_MAX_DEPTH` (1024) is an enforced boundary in
release builds too — a document nested past 1024 is refused with
`UpstreamDepth`. `FORK-NOTES.md` note 8 is the record and says how to overturn it.
Two are the target's own facts and are read from the resolved target rather than
from the host: `SIMDJSON_THREADS_ENABLED=1` on every target whose C++ runtime
provides `std::thread` (not `wasm32-wasi`), and `SIMDJSON_AVX512_ALLOWED=0` on an
x86-64 target whose CPU model has no AVX-512. Both are upstream's own switches;
`FORK-NOTES.md` note 9 is the record.

**Six required targets.** `build_support/graph.zig:required_targets`:
`x86_64-linux-gnu`, `aarch64-linux-gnu`, `aarch64-macos-none`,
`x86_64-windows-gnu`, `riscv64-linux-gnu`, `wasm32-wasi`.

**Which kernel you get.** A build-time property of the flags, not negotiable at run
time. `README.md` §2 has the whole boundary; `FORK-NOTES.md` notes 6 and 7 have the
detail. The short version: at `-Dcpu=baseline` on x86-64 the artifact carries the
scalar fallback kernel alone, which is upstream's own answer for a target with no
guaranteed SIMD, and there is no faster kernel to fall back to at run time because
On-Demand is statically bound to the builtin one.

**Export surface.** Eleven functions and no data symbol. ELF gets no version script
and COFF gets a generated `.def`, because nothing in `zig/bridge.h` can carry
`__declspec(dllexport)` without breaking the C translation the same header exists to
serve. **Mach-O has neither mechanism**, so a Darwin shared object from this graph
exports more than the eleven names and a Darwin consumer must select by name.
`FORK-NOTES.md` note 18 is the record.

---

## Errors you will actually meet

| situation | the error |
|---|---|
| trailing comma in an object | `UpstreamTape` |
| single-quoted string | `UpstreamTape` |
| unquoted key | `UpstreamTape` |
| `{"a":NaN}` | `UpstreamTape` |
| `{"a":+1}` | `UpstreamTape` |
| missing `:` between key and value | `UpstreamTape` |
| leading zero, `{"a":01}` | `UpstreamNumber` |
| unescaped control character in a string | `UpstreamUnescapedChars` |
| unterminated string | `UpstreamUnclosedString` |
| invalid UTF-8 | `UpstreamUtf8` |
| empty input | `UpstreamEmpty` |
| extra content after a complete value | `UpstreamTrailingContent` |
| truncated container | `UpstreamIncompleteArrayOrObject` |
| `1e400`, and any value binary64 cannot hold | `UpstreamNumber` |
| nested past `DEFAULT_MAX_DEPTH` | `UpstreamDepth` |
| `SIMDJSON_FORCE_IMPLEMENTATION` naming an uncompiled kernel | `UpstreamUnsupportedArchitecture` |
| no provider named, or a mismatched one, under `-Druntime` | `LoadError` |

Five of the `TAPE_ERROR`s are `TAPE_ERROR` rather than something more specific
because that is upstream's own classification carried across the API boundary, not
a code invented at the seam: a byte that is neither a digit, a `-` nor a token start
falls to `default:` in upstream's stage 2, logs "Non-value found when value was
expected!" and returns `TAPE_ERROR`
(`src/src/generic/stage2/json_iterator.h:363-365`). `FORK-NOTES.md` note 14 is the
record, and it is the reason this table exists.

---

## See also

* `zig/root.zig` — the same contract, as doc comments on each declaration.
* `zig/bridge.h` — the C ABI, with the reasoning for each entry point.
* `README.md` — the fork README: deviations, matrix, consumption.
* `UPSTREAM.md` — what is compiled, what is not, and every build deviation.
* `FORK-NOTES.md` — twenty decisions in condition / symptom / cause / fix form.
* `NOTICE.md` — the licence inventory.
* `CHANGELOG.md` — the change statement and the open questions.