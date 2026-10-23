# Zig facade API

Public declarations are in `zig/root.zig`. `parse` returns a `Document`; `Document.walk` copies values into a `Walk`. Views borrow from that walk.

```zig
const std = @import("std");
const simdjson = @import("simdjson");

fn printName(allocator: std.mem.Allocator, json: []const u8) !void {
    var document = try simdjson.parse(json);
    defer document.deinit();

    var walk = try document.walk(allocator);
    defer walk.deinit();

    const root = walk.root() orelse return;
    const object = root.object() orelse return;
    const field = object.get("name") orelse return;
    const name = field.value.string() orelse return;
    std.debug.print("{s}\n", .{name});
}
```

## Ownership and records

- `parse` copies the input into bridge-owned padded storage. The input may be reused after `parse` returns. Parse and walk failures use `Error`.
- `Document` owns the bridge handle and padded input; release it with `deinit`.
- `Document.walk(allocator)` allocates `nodes` and `blobs` from that allocator. `Walk.deinit` frees both with the same allocator. It contains every value in preorder.
- `Value`, `Array`, `Object`, `Field` and iterators borrow from `Walk`; do not use them or their byte slices after `Walk.deinit`.
- `blobs` stores unescaped keys and string bytes without NUL terminators. `Record` offsets and lengths are `u32`; `0xFFFFFFFF` marks absent bytes. A document that cannot fit this record format returns `UpstreamCapacity`.

`Record` has `depth`, `type`, `count`, `number_type`, `key_off`, `key_len`, `str_off`, `str_len`, `i`, `u` and `d`. Tags and offsets are `u32`; numeric storage is `i64`, `u64` and `f64`. `Record.bytes`, `key` and `string` return checked slices from `blobs`; `valueType` and `numberType` map unknown tags to `.unknown` and `.none`.

`ValueType` is `.unknown`, `.array`, `.object`, `.number`, `.string`, `.boolean` or `.null`. `NumberType` is `.none`, `.floating_point`, `.signed`, `.unsigned` or `.big`; big integers expose decimal text.

## Facade calls

| Call | Result |
|---|---|
| `parse(json)` | `Error!Document`; `walk` materializes value records. |
| `validateUtf8(bytes)` | `Error!bool`; checks UTF-8, not JSON grammar. |
| `version(out)`, `builtinImplementation(out)`, `activeImplementation(out)`, `activeImplementationDescription(out)` | `Error![]const u8`; returned bytes borrow from `out`. |
| `availableImplementationCount()` | Number of compiled kernels. |
| `availableImplementationName(index, out)` | `Error![]const u8`; invalid indices return `InvalidArgument`, bytes borrow from `out`. |
| `upstreamError(code)` | Maps a raw upstream code to `Error`; unknown codes map to `UpstreamUnnamed`. |

`Document` provides `walk(allocator)` and `deinit()`. `Walk` provides `root()`, `count()`, `nodes`, `blobs` and `deinit()`; `root()` is null only when no records exist.

| View | Methods |
|---|---|
| `Value` | `valueType()`, `count()`, `numberType()`, `array()`, `object()`, `string()`, `int()`, `uint()`, `double()`, `boolean()`, `isNull()`, `bigIntegerText()`, `at(n)`. |
| `Array` | `len()`, `get(n)`, `iterator()`, `reset()`, `items()`. |
| `Object` | `len()`, `at(n)`, `get(name)`, `iterator()`, `reset()`, `items()`. `get` returns the first matching field in document order. |
| `Field` | `key: []const u8`, `value: Value`; the key borrows from `Walk.blobs` and is not NUL-terminated. |

`Value` conversions return `null` for a different JSON or number type; they do not convert numeric types. `isNull()` returns `true` for JSON null and `null` for other types. `ArrayIterator` and `ObjectIterator` provide `next()` and `remaining()`; `reset()` and `items()` return a fresh iterator.

`Error` contains `InvalidArgument`, `BufferTooSmall`, `OutOfMemory` and `UnknownStatus`, plus mapped upstream errors: `UpstreamCapacity`, `UpstreamMalloc`, `UpstreamTape`, `UpstreamDepth`, `UpstreamString`, `UpstreamTAtom`, `UpstreamFAtom`, `UpstreamNAtom`, `UpstreamNumber`, `UpstreamBigint`, `UpstreamUtf8`, `UpstreamUninitialized`, `UpstreamEmpty`, `UpstreamUnescapedChars`, `UpstreamUnclosedString`, `UpstreamUnsupportedArchitecture`, `UpstreamIncorrectType`, `UpstreamNumberOutOfRange`, `UpstreamIndexOutOfBounds`, `UpstreamNoSuchField`, `UpstreamIoError`, `UpstreamInvalidJsonPointer`, `UpstreamInvalidUriFragment`, `UpstreamUnexpected`, `UpstreamParserInUse`, `UpstreamOutOfOrderIteration`, `UpstreamInsufficientPadding`, `UpstreamIncompleteArrayOrObject`, `UpstreamScalarDocumentAsValue`, `UpstreamOutOfBounds`, `UpstreamTrailingContent`, `UpstreamOutOfCapacity`, `UpstreamUnknownField` and `UpstreamUnnamed`.

## Runtime loader API

`runtime_loaded` is a comptime constant. `LoadSource` is `.path` (absolute file path) or `.system` (platform loader name without path separators or NUL). `load(source)` returns `LoadError!void`; `loadedSource()` returns the retained request or null. In a linked build, `load` panics and `loadedSource()` returns null.

`LoadError` variants are `EmptySource`, `SourceTooLong`, `InvalidSource`, `UnsupportedTarget`, `OpenFailed`, `MissingSymbol`, `ValidationFailed`, `ProviderMismatch` and `ReentrantLoad`. The loader requires one explicit provider; it does not fall back between path and system name. It validates the provider before publishing its table, and retains a successful handle for process lifetime. A repeated identical request succeeds; a different request fails. Failed loads can be retried. Same-request concurrent callers share an attempt; recursive loading returns `ReentrantLoad`. Calling a facade function before a successful load panics.

## Raw bridge

`c` is the translated `zig/bridge.h` import. Raw callers manage handles, buffer capacities and status codes. `simdjson_br_walk` supports a sizing pass; a short fill returns `BUFFER_TOO_SMALL` and required sizes without a partial result.