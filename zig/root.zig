//! Typed Zig facade for simdjson's On-Demand API.
//! `parse` returns a `Document`. `walk` copies values into a caller-owned `Walk`.
//! Views borrow from `Walk`. Calls return bridge, upstream, or load errors.
const std = @import("std");

/// Raw bridge API. Callers manage its buffers, handles, and status codes.
pub const c = @import("c");

const rt = @import("rt");

/// Comptime flag for runtime-loaded versus linked builds.
pub const runtime_loaded: bool = if (@hasDecl(c, "rt_runtime_loaded")) c.rt_runtime_loaded else false;

/// Selects a library by explicit path or platform loader name.
pub const LoadSource = if (runtime_loaded) c.LoadSource else rt.LoadSource;

/// Errors returned by `load`.
pub const LoadError = if (runtime_loaded) c.LoadError else rt.LoadError;

/// Loads the selected provider and retains its handle for the process lifetime.
/// Returns load errors. Linked builds panic because no provider is available.
pub fn load(source: LoadSource) LoadError!void {
    if (comptime !runtime_loaded) {
        std.debug.panic(
            "simdjson: load was called on a linked build; this module is not " ++
                "runtime-loaded, so there is no library to load. Build with " ++
                "runtime loading configured, or do not call load.",
            .{},
        );
    }
    return c.load(source);
}

/// Returns the retained request, or null before loading and in linked builds.
pub fn loadedSource() ?LoadSource {
    if (comptime !runtime_loaded) return null;
    return c.loadedSource();
}

/// Bridge, upstream, and provider errors reported by the facade.
pub const Error = error{
    /// Bridge invalid-argument status.
    InvalidArgument,
    /// `SIMDJSON_BRIDGE_BUFFER_TOO_SMALL`: a raw caller buffer is short.
    BufferTooSmall,
    /// Bridge out-of-memory status.
    OutOfMemory,
    /// An unknown bridge status.
    UnknownStatus,
    /// `simdjson::CAPACITY`.
    UpstreamCapacity,
    /// `simdjson::MEMALLOC`.
    UpstreamMalloc,
    /// `simdjson::TAPE_ERROR`.
    UpstreamTape,
    /// `simdjson::DEPTH_ERROR`.
    UpstreamDepth,
    /// `simdjson::STRING_ERROR`.
    UpstreamString,
    /// `simdjson::T_ATOM_ERROR`.
    UpstreamTAtom,
    /// `simdjson::F_ATOM_ERROR`.
    UpstreamFAtom,
    /// `simdjson::N_ATOM_ERROR`.
    UpstreamNAtom,
    /// Upstream `NUMBER_ERROR` for invalid JSON numbers.
    UpstreamNumber,
    /// `simdjson::BIGINT_ERROR`.
    UpstreamBigint,
    /// `simdjson::UTF8_ERROR`.
    UpstreamUtf8,
    /// `simdjson::UNINITIALIZED`.
    UpstreamUninitialized,
    /// `simdjson::EMPTY`.
    UpstreamEmpty,
    /// Upstream `UNESCAPED_CHARS` error for an unescaped control character.
    UpstreamUnescapedChars,
    /// `simdjson::UNCLOSED_STRING`.
    UpstreamUnclosedString,
    /// `simdjson::UNSUPPORTED_ARCHITECTURE`.
    UpstreamUnsupportedArchitecture,
    /// `simdjson::INCORRECT_TYPE`.
    UpstreamIncorrectType,
    /// `simdjson::NUMBER_OUT_OF_RANGE`.
    UpstreamNumberOutOfRange,
    /// `simdjson::INDEX_OUT_OF_BOUNDS`.
    UpstreamIndexOutOfBounds,
    /// `simdjson::NO_SUCH_FIELD`.
    UpstreamNoSuchField,
    /// `simdjson::IO_ERROR`.
    UpstreamIoError,
    /// `simdjson::INVALID_JSON_POINTER`.
    UpstreamInvalidJsonPointer,
    /// `simdjson::INVALID_URI_FRAGMENT`.
    UpstreamInvalidUriFragment,
    /// `simdjson::UNEXPECTED_ERROR`.
    UpstreamUnexpected,
    /// `simdjson::PARSER_IN_USE`.
    UpstreamParserInUse,
    /// Upstream `OUT_OF_ORDER_ITERATION` error.
    UpstreamOutOfOrderIteration,
    /// Upstream `INSUFFICIENT_PADDING` error. The bridge passes padded input.
    UpstreamInsufficientPadding,
    /// `simdjson::INCOMPLETE_ARRAY_OR_OBJECT`.
    UpstreamIncompleteArrayOrObject,
    /// `simdjson::SCALAR_DOCUMENT_AS_VALUE`.
    UpstreamScalarDocumentAsValue,
    /// `simdjson::OUT_OF_BOUNDS`.
    UpstreamOutOfBounds,
    /// `simdjson::TRAILING_CONTENT`.
    UpstreamTrailingContent,
    /// `simdjson::OUT_OF_CAPACITY`.
    UpstreamOutOfCapacity,
    /// `simdjson::UNKNOWN_FIELD`.
    UpstreamUnknownField,
    /// Provider returned an integer outside upstream's `error_code` values.
    UpstreamUnnamed,
};

/// JSON value kinds reported by the bridge, including `.unknown`.
pub const ValueType = enum(u32) {
    unknown = 0,
    array = 1,
    object = 2,
    number = 3,
    string = 4,
    boolean = 5,
    null = 6,
};

/// Number kinds. `.none` means non-numeric and `.big` uses decimal text.
pub const NumberType = enum(u32) {
    none = 0,
    floating_point = 1,
    signed = 2,
    unsigned = 3,
    big = 4,
};

/// ABI-compatible copy of one value record.
/// String and key bytes borrow from `Walk.blobs`.
pub const Record = extern struct {
    /// Nesting depth; root is zero.
    depth: u32,
    /// A `ValueType`.
    type: u32,
    /// Direct child count; zero for scalars.
    count: u32,
    /// A `NumberType`.
    number_type: u32,
    /// Byte offset of this record's key in `Walk.blobs`.
    key_off: u32,
    /// Length of that key.
    key_len: u32,
    /// Byte offset of this record's string bytes in `Walk.blobs`.
    str_off: u32,
    /// Length of that string.
    str_len: u32,
    /// Boolean as 0/1 or signed integer.
    i: i64,
    /// An unsigned integer.
    u: u64,
    /// A binary64 value.
    d: f64,

    /// Sentinel offset for absent key or string bytes.
    pub const no_offset: u32 = 0xFFFFFFFF;

    /// The bytes this record names in `Walk.blobs`, or `null` when it has none.
    pub fn bytes(_: Record, blobs: []const u8, offset: u32, len: u32) ?[]const u8 {
        if (offset == Record.no_offset) return null;
        const at: usize = offset;
        const n: usize = len;
        if (at > blobs.len or n > blobs.len - at) return null;
        return blobs[at .. at + n];
    }

    /// This record's key, or null when it is not an object member.
    pub fn key(self: Record, blobs: []const u8) ?[]const u8 {
        return self.bytes(blobs, self.key_off, self.key_len);
    }

    /// This record's string bytes, or null when it is not a string.
    pub fn string(self: Record, blobs: []const u8) ?[]const u8 {
        return self.bytes(blobs, self.str_off, self.str_len);
    }

    /// Returns `.unknown` when the tag is outside `ValueType`.
    pub fn valueType(self: Record) ValueType {
        return std.enums.fromInt(ValueType, self.type) orelse ValueType.unknown;
    }

    /// Returns `.none` when the tag is outside `NumberType`.
    pub fn numberType(self: Record) NumberType {
        return std.enums.fromInt(NumberType, self.number_type) orelse NumberType.none;
    }
};

/// Maps a bridge status to an error, or null for success.
fn statusError(raw: c_uint) ?Error {
    return switch (raw) {
        c.SIMDJSON_BRIDGE_OK => null,
        c.SIMDJSON_BRIDGE_INVALID_ARGUMENT => Error.InvalidArgument,
        c.SIMDJSON_BRIDGE_BUFFER_TOO_SMALL => Error.BufferTooSmall,
        c.SIMDJSON_BRIDGE_OUT_OF_MEMORY => Error.OutOfMemory,
        c.SIMDJSON_BRIDGE_UPSTREAM_ERROR => Error.UpstreamUnexpected,
        else => Error.UnknownStatus,
    };
}

/// Maps an upstream error code to `Error`.
/// Unknown values become `UpstreamUnnamed`.
pub fn upstreamError(code: i32) Error {
    return switch (@as(u32, @intCast(code))) {
        0 => Error.UpstreamUnnamed, // SUCCESS is not an error; see upstreamErrorCode
        1 => Error.UpstreamCapacity,
        2 => Error.UpstreamMalloc,
        3 => Error.UpstreamTape,
        4 => Error.UpstreamDepth,
        5 => Error.UpstreamString,
        6 => Error.UpstreamTAtom,
        7 => Error.UpstreamFAtom,
        8 => Error.UpstreamNAtom,
        9 => Error.UpstreamNumber,
        10 => Error.UpstreamBigint,
        11 => Error.UpstreamUtf8,
        12 => Error.UpstreamUninitialized,
        13 => Error.UpstreamEmpty,
        14 => Error.UpstreamUnescapedChars,
        15 => Error.UpstreamUnclosedString,
        16 => Error.UpstreamUnsupportedArchitecture,
        17 => Error.UpstreamIncorrectType,
        18 => Error.UpstreamNumberOutOfRange,
        19 => Error.UpstreamIndexOutOfBounds,
        20 => Error.UpstreamNoSuchField,
        21 => Error.UpstreamIoError,
        22 => Error.UpstreamInvalidJsonPointer,
        23 => Error.UpstreamInvalidUriFragment,
        24 => Error.UpstreamUnexpected,
        25 => Error.UpstreamParserInUse,
        26 => Error.UpstreamOutOfOrderIteration,
        27 => Error.UpstreamInsufficientPadding,
        28 => Error.UpstreamIncompleteArrayOrObject,
        29 => Error.UpstreamScalarDocumentAsValue,
        30 => Error.UpstreamOutOfBounds,
        31 => Error.UpstreamTrailingContent,
        32 => Error.UpstreamOutOfCapacity,
        33 => Error.UpstreamUnknownField,
        else => Error.UpstreamUnnamed,
    };
}

fn fail(raw: c_uint, code: i32) Error {
    if (raw == c.SIMDJSON_BRIDGE_UPSTREAM_ERROR) return upstreamError(code);
    return statusError(raw) orelse Error.UnknownStatus;
}

/// Queries the required length, fills `out`, and returns a slice borrowed from it.
fn readString(
    out: []u8,
    comptime call: fn ([*c]u8, usize, *usize) callconv(.c) c_uint,
) Error![]const u8 {
    var len: usize = 0;
    var status = call(null, 0, &len);
    if (status != c.SIMDJSON_BRIDGE_OK) return fail(status, 0);
    if (len >= out.len) return Error.BufferTooSmall;
    status = call(out.ptr, out.len, &len);
    if (status != c.SIMDJSON_BRIDGE_OK) return fail(status, 0);
    if (len >= out.len) return Error.BufferTooSmall;
    return out[0..len];
}

/// Writes the library version into `out` and returns bridge errors.
/// The returned slice borrows from `out`.
pub fn version(out: []u8) Error![]const u8 {
    return readString(out, c.simdjson_br_version);
}

/// Writes the compiled On-Demand kernel name into `out` and returns bridge errors.
/// The returned slice borrows from `out`.
pub fn builtinImplementation(out: []u8) Error![]const u8 {
    return readString(out, c.simdjson_br_builtin_implementation);
}

/// Writes the runtime-selected kernel name into `out` and returns bridge errors.
/// The returned slice borrows from `out`.
pub fn activeImplementation(out: []u8) Error![]const u8 {
    return readString(out, c.simdjson_br_active_implementation);
}

/// Writes the active kernel description into `out` and returns bridge errors.
/// The returned slice borrows from `out`.
pub fn activeImplementationDescription(out: []u8) Error![]const u8 {
    return readString(out, c.simdjson_br_active_implementation_description);
}

/// Returns the number of kernels compiled into the library.
pub fn availableImplementationCount() usize {
    return c.simdjson_br_available_implementation_count();
}

/// Writes the indexed kernel name into `out`. The slice borrows from it.
/// Returns `InvalidArgument` for an invalid index and bridge errors otherwise.
pub fn availableImplementationName(index: usize, out: []u8) Error![]const u8 {
    var len: usize = 0;
    var status = c.simdjson_br_available_implementation_name(index, null, 0, &len);
    if (status != c.SIMDJSON_BRIDGE_OK) return fail(status, 0);
    if (len >= out.len) return Error.BufferTooSmall;
    status = c.simdjson_br_available_implementation_name(index, out.ptr, out.len, &len);
    if (status != c.SIMDJSON_BRIDGE_OK) return fail(status, 0);
    if (len >= out.len) return Error.BufferTooSmall;
    return out[0..len];
}

/// Returns whether `bytes` is valid UTF-8, independent of JSON grammar.
/// Returns bridge errors when validation fails.
pub fn validateUtf8(bytes: []const u8) Error!bool {
    var ok: c_int = 0;
    const status = c.simdjson_br_validate_utf8(bytes.ptr, bytes.len, &ok);
    if (status != c.SIMDJSON_BRIDGE_OK) return fail(status, 0);
    return ok == 1;
}

/// Owns a bridge handle and its padded copy of the input.
/// `walk` copies values into a caller-owned `Walk` and returns parse errors.
pub const Document = struct {
    handle: *c.struct_simdjson_bridge_document,

    /// Releases the handle. Safe for a default-constructed document.
    pub fn deinit(self: *Document) void {
        c.simdjson_br_destroy(self.handle);
        self.handle = undefined;
    }

    /// Copies the full document into a caller-allocated `Walk`.
    /// The walk owns both buffers. Failures return `Error`.
    pub fn walk(self: *const Document, allocator: std.mem.Allocator) Error!Walk {
        return walkDocument(self, allocator);
    }
};

/// Copies `json` into bridge-owned storage and returns a parsed document.
/// Returns parse errors. `walk` checks value-level grammar.
pub fn parse(json: []const u8) Error!Document {
    var handle: ?*c.struct_simdjson_bridge_document = null;
    var code: i32 = 0;
    const status = c.simdjson_br_open(json.ptr, json.len, &handle, &code);
    if (status != c.SIMDJSON_BRIDGE_OK) return fail(status, code);
    // A successful bridge call must return a handle.
    if (handle == null) return Error.UnknownStatus;
    return Document{ .handle = handle.? };
}

/// Owns pre-order records and string bytes allocated by `Document.walk`.
/// Values and views borrow from this walk until `deinit`.
pub const Walk = struct {
    /// Allocator used to release `nodes` and `blobs`.
    backing_allocator: std.mem.Allocator,
    /// Every value in the document, in pre-order.
    nodes: []Record,
    /// Every key and string value, at the offsets the records name.
    blobs: []u8,

    /// Frees both slices and resets them to empty.
    pub fn deinit(self: *Walk) void {
        self.backing_allocator.free(self.blobs);
        self.backing_allocator.free(self.nodes);
        self.* = .{ .backing_allocator = self.backing_allocator, .nodes = &.{}, .blobs = &.{} };
    }

    /// Returns the root value, or null when the walk has no records.
    pub fn root(self: Walk) ?Value {
        if (self.nodes.len == 0) return null;
        return Value{ .walk = self, .index = 0 };
    }

    /// How many records the document has, counting every nested value.
    pub fn count(self: Walk) usize {
        return self.nodes.len;
    }

    /// Finds the `n`-th direct child in the pre-order records.
    fn nthChild(self: Walk, index: usize, n: usize) ?usize {
        if (index >= self.nodes.len) return null;
        if (n >= self.nodes[index].count) return null;
        const parent_depth = self.nodes[index].depth;
        var at = index + 1;
        var seen: usize = 0;
        while (seen < n) : (seen += 1) {
            if (at >= self.nodes.len) return null;
            if (self.nodes[at].depth != parent_depth + 1) return null;
            const child_depth = self.nodes[at].depth;
            var after = at + 1;
            while (after < self.nodes.len and self.nodes[after].depth > child_depth) : (after += 1) {}
            at = after;
        }
        if (at >= self.nodes.len) return null;
        if (self.nodes[at].depth != parent_depth + 1) return null;
        return at;
    }
};

pub fn walkDocument(self: *const Document, allocator: std.mem.Allocator) Error!Walk {
    var node_count: usize = 0;
    var blob_len: usize = 0;
    var code: i32 = 0;

    const sizing = c.simdjson_br_walk(
        @constCast(self.handle),
        null,
        0,
        &node_count,
        null,
        0,
        &blob_len,
        &code,
    );
    if (sizing != c.SIMDJSON_BRIDGE_OK) return fail(sizing, code);

    // A successful walk must contain a root record.
    if (node_count == 0) return Error.UpstreamEmpty;

    const nodes = try allocator.alloc(Record, node_count);
    errdefer allocator.free(nodes);
    const blobs = try allocator.alloc(u8, blob_len);
    errdefer allocator.free(blobs);

    var filled_nodes: usize = 0;
    var filled_blobs: usize = 0;
    const filling = c.simdjson_br_walk(
        @constCast(self.handle),
        @ptrCast(nodes.ptr),
        node_count,
        &filled_nodes,
        blobs.ptr,
        blob_len,
        &filled_blobs,
        &code,
    );
    if (filling != c.SIMDJSON_BRIDGE_OK) return fail(filling, code);

    // Reject inconsistent counts before exposing the filled buffers.
    if (filled_nodes != node_count or filled_blobs != blob_len) {
        return Error.UpstreamUnnamed;
    }

    return Walk{
        .backing_allocator = allocator,
        .nodes = nodes,
        .blobs = blobs,
    };
}

/// A value view that borrows its record and bytes from a `Walk`.
pub const Value = struct {
    walk: Walk,
    index: usize,

    fn record(self: Value) Record {
        return self.walk.nodes[self.index];
    }

    /// This value's type.
    pub fn valueType(self: Value) ValueType {
        return self.record().valueType();
    }

    /// Returns the number of direct child values.
    pub fn count(self: Value) usize {
        return self.record().count;
    }

    /// This value as an `Array`, or null when it is not one.
    pub fn array(self: Value) ?Array {
        if (self.valueType() != .array) return null;
        return Array{ .walk = self.walk, .index = self.index };
    }

    /// This value as an `Object`, or null when it is not one.
    pub fn object(self: Value) ?Object {
        if (self.valueType() != .object) return null;
        return Object{ .walk = self.walk, .index = self.index };
    }

    /// Returns unescaped string bytes borrowed from the walk, or null for other types.
    pub fn string(self: Value) ?[]const u8 {
        return self.record().string(self.walk.blobs);
    }

    /// Returns the signed integer, or null when the value has another number type.
    /// Does not convert or truncate other numeric types.
    pub fn int(self: Value) ?i64 {
        if (self.record().numberType() != .signed) return null;
        return self.record().i;
    }

    /// Returns the unsigned integer, or null when the value has another number type.
    pub fn uint(self: Value) ?u64 {
        if (self.record().numberType() != .unsigned) return null;
        return self.record().u;
    }

    /// Returns the binary64 value, or null for non-floating values.
    /// Does not convert integer values.
    pub fn double(self: Value) ?f64 {
        if (self.record().numberType() != .floating_point) return null;
        return self.record().d;
    }

    /// Returns the boolean value, or null for other types.
    pub fn boolean(self: Value) ?bool {
        if (self.valueType() != .boolean) return null;
        return self.record().i != 0;
    }

    /// Returns true for JSON null, or null for other types.
    pub fn isNull(self: Value) ?bool {
        if (self.valueType() != .null) return null;
        return true;
    }

    /// This value's number type, `.none` for anything that is not a number.
    pub fn numberType(self: Value) NumberType {
        return self.record().numberType();
    }

    /// Returns big-integer decimal text borrowed from the walk, or null otherwise.
    pub fn bigIntegerText(self: Value) ?[]const u8 {
        if (self.record().numberType() != .big) return null;
        return self.record().string(self.walk.blobs);
    }

    /// Returns the `n`-th direct child, or null when absent.
    pub fn at(self: Value, n: usize) ?Value {
        const child = self.walk.nthChild(self.index, n) orelse return null;
        return Value{ .walk = self.walk, .index = child };
    }
};

/// A view of array elements that borrows from its `Walk`.
pub const Array = struct {
    walk: Walk,
    index: usize,

    /// How many elements this array has.
    pub fn len(self: Array) usize {
        return self.walk.nodes[self.index].count;
    }

    /// The `n`-th element, or null when `n` is past the end.
    pub fn get(self: Array, n: usize) ?Value {
        const child = self.walk.nthChild(self.index, n) orelse return null;
        return Value{ .walk = self.walk, .index = child };
    }

    /// An iterator over this array's elements, in document order.
    pub fn iterator(self: Array) ArrayIterator {
        return ArrayIterator{ .array = self, .next_child = 0 };
    }

    /// Returns a fresh iterator from the first element.
    pub fn reset(self: Array) ArrayIterator {
        return self.iterator();
    }

    /// Returns an iterator over all elements.
    /// Indexed iteration is O(n²). `iterator` advances in linear time.
    pub fn items(self: Array) ArrayIterator {
        return self.iterator();
    }
};

/// An array iterator that borrows from its `Walk`.
pub const ArrayIterator = struct {
    array: Array,
    next_child: usize,

    /// The next element, or null at the end of the array.
    pub fn next(self: *ArrayIterator) ?Value {
        const value = self.array.get(self.next_child) orelse return null;
        self.next_child += 1;
        return value;
    }

    /// How many elements are left.
    pub fn remaining(self: ArrayIterator) usize {
        const left = self.array.len();
        return if (self.next_child >= left) 0 else left - self.next_child;
    }
};

/// A view of object fields that borrows from its `Walk`.
pub const Object = struct {
    walk: Walk,
    index: usize,

    /// How many fields this object has.
    pub fn len(self: Object) usize {
        return self.walk.nodes[self.index].count;
    }

    /// Returns the `n`-th field in document order, or null when absent.
    pub fn at(self: Object, n: usize) ?Field {
        const child = self.walk.nthChild(self.index, n) orelse return null;
        return Field{
            .key = self.walk.nodes[child].key(self.walk.blobs) orelse &.{},
            .value = Value{ .walk = self.walk, .index = child },
        };
    }

    /// Returns the first matching field, or null when absent.
    /// Searches in document order.
    pub fn get(self: Object, name: []const u8) ?Field {
        var n: usize = 0;
        while (n < self.len()) : (n += 1) {
            const field = self.at(n) orelse return null;
            if (std.mem.eql(u8, field.key, name)) return field;
        }
        return null;
    }

    /// An iterator over this object's fields, in document order.
    pub fn iterator(self: Object) ObjectIterator {
        return ObjectIterator{ .object = self, .next_child = 0 };
    }

    /// A fresh iterator over this object's fields, in document order.
    pub fn reset(self: Object) ObjectIterator {
        return self.iterator();
    }

    /// Returns an iterator over all fields. Indexed iteration is O(n²).
    pub fn items(self: Object) ObjectIterator {
        return self.iterator();
    }
};

/// An object's unescaped key and value. The key borrows from `Walk.blobs`.
/// Keys are not NUL-terminated.
pub const Field = struct {
    key: []const u8,
    value: Value,
};

/// An object iterator that borrows from its `Walk`.
pub const ObjectIterator = struct {
    object: Object,
    next_child: usize,

    /// The next field, or null at the end of the object.
    pub fn next(self: *ObjectIterator) ?Field {
        const field = self.object.at(self.next_child) orelse return null;
        self.next_child += 1;
        return field;
    }

    /// How many fields are left.
    pub fn remaining(self: ObjectIterator) usize {
        const left = self.object.len();
        return if (self.next_child >= left) 0 else left - self.next_child;
    }
};
