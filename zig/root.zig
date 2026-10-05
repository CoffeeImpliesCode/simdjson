//! Public Zig surface of the simdjson fork.
//!
//! Scope: simdjson 5.0.2's **On-Demand** API -- one-shot, forward-only
//! iteration over a single cursor -- for one document at a time. Nothing below
//! parses, validates UTF-8, unescapes a string, rounds a number or decides what
//! a valid document is: every value comes out of the C bridge in
//! `zig/bridge.cc`, which calls upstream's compiled C++ and reports what
//! upstream returned. Each declaration names the header and line it was read out
//! of, so a reader can check the binding against upstream rather than against
//! this file.
//!
//! The DOM API is deliberately absent, and so is every other part of upstream:
//! `simdjson.h` also offers `dom::parser`, `document_stream`, `minify` and
//! compile-time JSON, none of which this facade reaches. A C++ consumer that
//! wants them has the whole installed upstream header tree beside this library;
//! see `zig/root.zig`'s module documentation in `README.zig.md`.
//!
//! Three ways in:
//!   * `pub const c` is the complete `zig/bridge.h` surface, not a filtered
//!     view: the eleven entry points and every `SIMDJSON_BRIDGE_*` constant are
//!     all there. Reach for it when a caller needs something this facade does not
//!     wrap, or the raw integer behind an upstream error code.
//!   * `parse` gives a `Document`, and `Document.walk` gives a `Walk`: a
//!     self-contained, pre-order copy of the whole document.
//!   * The typed accessors on `Value`, `Array` and `Object` read that copy.
//!
//! Shortest usage sequence:
//!
//! ```zig
//! const std = @import("std");
//! const simdjson = @import("simdjson");
//!
//! pub fn main() !void {
//!     const doc = try simdjson.parse("{\"a\":[1,2,3]}");
//!     var walk = try doc.walk(std.heap.page_allocator);
//!     defer walk.deinit(std.heap.page_allocator);
//!
//!     const root = walk.root();
//!     if (root != .object) return error.NotAnObject;
//!     const a = root.object.get("a") orelse return error.NoSuchField;
//!     const numbers = a.value.array();
//!     for (numbers.items()) |item| {
//!         std.debug.print("{d}\n", .{item.value.int()});
//!     }
//! }
//! ```
//!
//! In a runtime-loading build one line comes before the first parse, and it is
//! the only difference in the program:
//!
//! ```zig
//!     try simdjson.load(.{ .path = "/usr/lib/libsimdjson.so.34" });
//! ```
//!
//! Routes: a dependent imports this one module, `dep.module("simdjson")` from
//! `b.dependency("simdjson", ...)`, and the build binds `c` and, in a linked
//! build, links the compiled library into it; in a runtime-loading build nothing
//! is linked and `c` resolves the same names through the loader. `c` is a
//! supported route of its own and carries the obligations stated on its
//! declaration. There is no second module name, no per-target name and no
//! relative-import route.
//!
//! ## Two configurations: linked and runtime-loaded
//!
//! This module is built in one of two shapes, and `runtime_loaded` says which
//! at comptime.
//!
//! *Linked* is the default. The library is linked, `c` is the translated header,
//! and every call below -- the typed ones and the raw eleven -- is a direct call
//! to the compiled C++ with no table, no readiness check and no cost.
//!
//! *Runtime-loaded* is opt-in (`-Druntime`). The library is not linked; `c` is a
//! dispatch generated from the same translation step's output, and the eleven
//! entry points `zig/bridge.h` declares are resolved through the platform loader
//! when the caller calls
//!
//! ```zig
//! try simdjson.load(.{ .path = "/usr/lib/libsimdjson.so.34" });
//! ```
//!
//! before using anything else. A call into a module that has not loaded stops
//! the program with a message naming the function, in every optimization mode.
//! That is a programming error rather than a recoverable condition: the table
//! does not exist yet, and there is no partial state to fall back on. The load
//! itself reports a missing file, a provider that does not export all eleven
//! entry points, a provider whose entry points do not behave as this header
//! declares, a request that cannot be honoured because a different provider
//! already won, or a reentrant call, as errors rather than as a different library
//! being loaded instead.
//!
//! The provider is reached, never guessed. `.path` names a file and `.system`
//! names a library for the platform loader; neither falls back to the other, the
//! module has no unload and no reset, and it keeps the handle and its own copy of
//! the request to the end of the process. What a provider has to be is stated in
//! `runtime/library.zig`, next to the ABI boundary and what is and is not checked
//! about it.
//!
//! Compiler and ABI: this module is written for Zig 0.16.0, which is what
//! `build.zig.zon` states as `minimum_zig_version`. Every value it returns
//! crosses the C ABI `zig/bridge.h` declares, so what a caller is bound to is
//! that header's record layout and status values -- not upstream's C++ API, which
//! is class hierarchies in a namespace bound to a compile-time-selected kernel
//! and has no symbol a C translation could name. The library behind that ABI is
//! compiled out of upstream's own headers and translation unit at a pinned
//! `-std=c++17` (`build_support/graph.zig`); a dependent that reaches this module
//! through `dep.module` in a linked build gets it with libc and the C++ runtime.
//! In a runtime-loading build the same eleven entry points arrive from a provider
//! named at run time instead, and `runtime/library.zig` records what such a
//! provider has to match and what is checked about it.
//!
//! Allocation: exactly two things cross into the caller's allocator and both are
//! caller-chosen. `Walk.nodes` and `Walk.blobs` come from the allocator
//! `Document.walk` is given, and `Walk.deinit` hands them back to that same
//! allocator. Nothing else in this module allocates: the input bytes are copied
//! by the bridge into upstream's own padded buffer, every string is copied out
//! of that buffer into the caller's blob, and the one handle a `Document` owns is
//! freed by `simdjson_br_destroy` inside the library.
//!
//! What this module deliberately does not do: it exposes no DOM, no
//! `document_stream`, no minifier, no JSON writer, no JSON-Pointer or JSONPath
//! lookup, no builder, and no UTF-8 validator of its own -- `validateUtf8` is
//! `simdjson::validate_utf8` itself (`zig/bridge.h:529-530`), which the library
//! also uses internally.
//!
//! Ownership and lifetime:
//!   * The input slice passed to `parse` is borrowed for the duration of the
//!     call and is copied by the bridge; it may be freed or reused the instant
//!     `parse` returns, and nothing here retains it.
//!   * A `Document` owns exactly one thing: the bridge handle. `deinit` calls
//!     `simdjson_br_destroy` and accepts a default-constructed `Document`, so
//!     `defer doc.deinit()` after a failed `parse` is safe.
//!   * `Document.walk` allocates both of its buffers with the allocator it is
//!     given. A `Walk` owns them; `Value`, `Array`, `Object` and `Field` borrow
//!     from it and are invalid the moment it is deinitialized.
//!   * A rejected parse constructs nothing. `parse` returns an error and the
//!     caller's `Document` variable is left exactly as it was -- a failed `parse`
//!     does not clear a previous document and does not hand back a half-open
//!     one. On the `c` route the same fact is stronger and stated there.
//!   * A `Walk` whose own `deinit` has run hands nothing back: `Walk.deinit`
//!     leaves `nodes` and `blobs` as the empty slices rather than dangling
//!     pointers, so reading a used `Walk` yields "no values" instead of a fault.
//!   * In a runtime-loading build the process handle and the loader's own copy of
//!     the request outlive every call here, and there is no call that gives them
//!     back. That is a property of the loader, not of these functions: it holds
//!     one table for the life of the process because other code may already have
//!     parsed through it.
//!
//! The upstream C++ headers are installed too, under `include/simdjson/`,
//! unmodified and complete, so a C++ caller can use simdjson directly without
//! going through this binding at all. They are not reachable through Zig,
//! because On-Demand is a set of C++ class templates and namespace aliases and
//! has no symbol a C translation can name; that is the whole reason `bridge.cc`
//! exists.
const std = @import("std");

/// The complete translated `zig/bridge.h`, and this fork's supported raw route
/// to the library.
///
/// Upstream's own C++ API is deliberately absent from it: `simdjson::ondemand`
/// is a namespace alias bound to one compile-time-selected kernel
/// (`src/include/simdjson/builtin/ondemand.h:39`) whose members are class
/// templates and `simdjson_result<T>` returns, and `zig translate-c` cannot see
/// one. What is here is what `bridge.cc` compiles from `<simdjson.h>`, so the two
/// cannot disagree.
///
/// The eleven entry points are `simdjson_br_version`, `simdjson_br_builtin_implementation`,
/// `simdjson_br_active_implementation`, `simdjson_br_active_implementation_description`,
/// `simdjson_br_available_implementation_count`, `simdjson_br_available_implementation_name`,
/// `simdjson_br_validate_utf8`, `simdjson_br_open`, `simdjson_br_destroy`,
/// `simdjson_br_input_size` and `simdjson_br_walk`; see `zig/bridge.h` for each
/// one's exact argument list and for the two-pass and ownership rules they obey.
///
/// A raw call carries three obligations the caller does not have to satisfy. On
/// this route they are the caller's:
///
///   * `out` pointers must be non-null except where a particular entry point's
///     comment says otherwise. There is no null check on the value outputs of
///     most of them and no way to drop an out-parameter.
///   * `simdjson_br_walk`'s buffers and capacities are a two-pass contract, and
///     a caller that gets it wrong is told `SIMDJSON_BRIDGE_BUFFER_TOO_SMALL`
///     with both required counts written -- but a caller that reads those counts
///     as "how much was written" has misread them: they are the sizes required,
///     on every status including success.
///   * An upstream error arrives as `SIMDJSON_BRIDGE_UPSTREAM_ERROR` plus an
///     integer in `out_error`. That integer is the raw value of a
///     `simdjson::error_code` enumerator, and `upstreamErrorCode` below is the
///     only place in this module that turns one into a name. Reading that
///     residue is the only way this package exposes which upstream error a
///     refusal was; the typed functions report the same condition and discard it.
///
/// In a runtime-loading build this module is a generated dispatch instead of the
/// translation step's own output. It publishes the same namespace: the
/// `SIMDJSON_BRIDGE_*` constants are re-exported from the translated header
/// rather than restated, so there is one spelling of each of them either way.
/// What differs is how a name reaches the library. In the linked configuration a
/// call is direct; in the runtime-loaded one it goes through a table that `load`
/// fills, and a call before that fill stops the program with a message naming
/// the function. `runtime_loaded` says which configuration this is, at comptime.
pub const c = @import("c");

/// The loader core, which is where a linked build's two public types come from.
///
/// It is imported only by the linked configuration. In a runtime-loading build
/// the dispatch carries its own copy of the same declarations and this module is
/// never referenced, so it is never resolved and never compiled. Either way
/// there is exactly one `LoadSource` and one `LoadError` in a build, which is
/// what keeps them one type for a consumer that names them.
const rt = @import("rt");

/// Whether this module was configured to resolve its native symbols at run
/// time.
///
/// False for the ordinary build, where the library is linked and `c` is the
/// translated header itself. True when the build generated a dispatch that
/// resolves the same symbols through the platform loader, in which case `load`
/// is the call that makes the library usable.
///
/// It is a comptime constant, so a consumer can write two different code paths
/// and have only the one it chose analysed.
pub const runtime_loaded: bool = if (@hasDecl(c, "rt_runtime_loaded")) c.rt_runtime_loaded else false;

/// Which native library `load` should open.
///
/// `.path` is an explicit file path and `.system` is an explicit name for the
/// platform loader. There is no path-to-system fallback and no implicit fallback
/// of any kind; a request that cannot be honoured is an error, not a different
/// library.
pub const LoadSource = if (runtime_loaded) c.LoadSource else rt.LoadSource;

/// Every way `load` can decline.
///
/// Declared here, in the module a consumer imports, rather than only inside the
/// loader: the caller names the failure it is handling.
pub const LoadError = if (runtime_loaded) c.LoadError else rt.LoadError;

/// Load the native library this module dispatches to.
///
/// In a runtime-loading build this is the whole contract: call it once, then use
/// this module as if it were linked. Calling it again with the same request
/// succeeds and changes nothing; calling it with a different request after a
/// success is `ProviderMismatch`, and the library already in use stays in use. A
/// failed attempt publishes nothing and can be retried explicitly, by calling
/// this again: there is no automatic retry, and no implicit second source.
///
/// It keeps the process handle and its own copy of the request to the end of the
/// process. There is no unload and no reset, because the table is process-global
/// state that other code may already have called through.
///
/// Safe to call from any thread. A thread that arrives while an attempt for the
/// same request is in flight waits for that attempt and gets its result,
/// whatever it was. A call from the thread that is running the attempt is
/// `ReentrantLoad` rather than a deadlock.
///
/// In a linked build there is no provider, no table and nothing to resolve, so
/// this stops the program with a message saying so instead of quietly
/// succeeding. `runtime_loaded` is false there, so a consumer that supports
/// both configurations can tell the two apart at comptime instead of meeting
/// this at run time.
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

/// The request that succeeded, or null when nothing has loaded yet.
///
/// The answer is the loader's own retained copy and stays valid for the life of
/// the process. Null in a linked build, which has no request.
pub fn loadedSource() ?LoadSource {
    if (comptime !runtime_loaded) return null;
    return c.loadedSource();
}

/// Everything these functions can refuse to do.
///
/// The taxonomy has two halves and they are not interchangeable.
///
/// The first three names are this bridge's own statuses
/// (`zig/bridge.h:127-148`): a bad argument, a caller buffer too small, and an
/// allocation that failed. `UnknownStatus` covers a status outside that
/// enumeration, which a correctly built provider cannot return and which is named
/// rather than folded into a neighbour.
///
/// Every name after that is one member of upstream's `simdjson::error_code`
/// (`src/include/simdjson/error.h:19-54`), named after its enumerator and
/// carrying that enumerator's own integer. The whole enumeration is present, not
/// only the members this package has been seen to produce, because the walk can
/// be handed any of them and a caller reading a refusal deserves a name.
/// `UpstreamUnnamed` is the one addition: an integer outside the enumeration,
/// which is a fact about the provider rather than about upstream.
///
/// Each name below is a claim about a comparison this package's own code made:
/// `statusError` compared a bridge status against `zig/bridge.h`'s enumerators,
/// and `upstreamError` compared an integer against the values recorded in
/// `zig/bridge.cc`'s `static_assert` block, which are the real enumerators'
/// checked by the C++ compiler on every target that builds the library.
pub const Error = error{
    /// `SIMDJSON_BRIDGE_INVALID_ARGUMENT` (`zig/bridge.h:136`).
    InvalidArgument,
    /// `SIMDJSON_BRIDGE_BUFFER_TOO_SMALL` (`zig/bridge.h:141`).  The typed
    /// surface cannot produce this: every buffer-taking call here allocates for
    /// itself.  It is in the set because a caller reading `c` can.
    BufferTooSmall,
    /// `SIMDJSON_BRIDGE_OUT_OF_MEMORY` (`zig/bridge.h:145`).
    OutOfMemory,
    /// A bridge status outside `zig/bridge.h:127-148`.
    UnknownStatus,
    /// `simdjson::CAPACITY` (`error.h:21`).
    UpstreamCapacity,
    /// `simdjson::MEMALLOC` (`error.h:22`).
    UpstreamMalloc,
    /// `simdjson::TAPE_ERROR` (`error.h:23`).
    UpstreamTape,
    /// `simdjson::DEPTH_ERROR` (`error.h:24`).
    UpstreamDepth,
    /// `simdjson::STRING_ERROR` (`error.h:25`).
    UpstreamString,
    /// `simdjson::T_ATOM_ERROR` (`error.h:26`).
    UpstreamTAtom,
    /// `simdjson::F_ATOM_ERROR` (`error.h:27`).
    UpstreamFAtom,
    /// `simdjson::N_ATOM_ERROR` (`error.h:28`).
    UpstreamNAtom,
    /// `simdjson::NUMBER_ERROR` (`error.h:29`).  This is what a JSON number
    /// that violates the grammar produces -- a leading zero, a trailing digit
    /// after a complete number, a `+` where a digit was required.
    UpstreamNumber,
    /// `simdjson::BIGINT_ERROR` (`error.h:30`).
    UpstreamBigint,
    /// `simdjson::UTF8_ERROR` (`error.h:31`).
    UpstreamUtf8,
    /// `simdjson::UNINITIALIZED` (`error.h:32`).
    UpstreamUninitialized,
    /// `simdjson::EMPTY` (`error.h:33`): "no structural element found".
    UpstreamEmpty,
    /// `simdjson::UNESCAPED_CHARS` (`error.h:34`): a control character inside a
    /// string that RFC 8259 section 7 requires to be escaped.
    UpstreamUnescapedChars,
    /// `simdjson::UNCLOSED_STRING` (`error.h:35`).
    UpstreamUnclosedString,
    /// `simdjson::UNSUPPORTED_ARCHITECTURE` (`error.h:36`).
    UpstreamUnsupportedArchitecture,
    /// `simdjson::INCORRECT_TYPE` (`error.h:37`).
    UpstreamIncorrectType,
    /// `simdjson::NUMBER_OUT_OF_RANGE` (`error.h:38`).
    UpstreamNumberOutOfRange,
    /// `simdjson::INDEX_OUT_OF_BOUNDS` (`error.h:39`).
    UpstreamIndexOutOfBounds,
    /// `simdjson::NO_SUCH_FIELD` (`error.h:40`).
    UpstreamNoSuchField,
    /// `simdjson::IO_ERROR` (`error.h:41`).
    UpstreamIoError,
    /// `simdjson::INVALID_JSON_POINTER` (`error.h:42`).
    UpstreamInvalidJsonPointer,
    /// `simdjson::INVALID_URI_FRAGMENT` (`error.h:43`).
    UpstreamInvalidUriFragment,
    /// `simdjson::UNEXPECTED_ERROR` (`error.h:44`).
    UpstreamUnexpected,
    /// `simdjson::PARSER_IN_USE` (`error.h:45`).
    UpstreamParserInUse,
    /// `simdjson::OUT_OF_ORDER_ITERATION` (`error.h:46`).  The walk cannot
    /// raise it -- it descends into a child and consumes it fully before
    /// advancing the parent, which is the order upstream documents -- and this
    /// build compiles the check in on every target, so seeing it means
    /// something reached the document out of order.
    UpstreamOutOfOrderIteration,
    /// `simdjson::INSUFFICIENT_PADDING` (`error.h:47`).  Unreachable: the
    /// bridge always hands upstream a padded copy of the input.
    UpstreamInsufficientPadding,
    /// `simdjson::INCOMPLETE_ARRAY_OR_OBJECT` (`error.h:48`).
    UpstreamIncompleteArrayOrObject,
    /// `simdjson::SCALAR_DOCUMENT_AS_VALUE` (`error.h:49`).
    UpstreamScalarDocumentAsValue,
    /// `simdjson::OUT_OF_BOUNDS` (`error.h:50`).
    UpstreamOutOfBounds,
    /// `simdjson::TRAILING_CONTENT` (`error.h:51`).
    UpstreamTrailingContent,
    /// `simdjson::OUT_OF_CAPACITY` (`error.h:52`).
    UpstreamOutOfCapacity,
    /// `simdjson::UNKNOWN_FIELD` (`error.h:53`).
    UpstreamUnknownField,
    /// An integer outside upstream's `error_code`.  A correctly built provider
    /// cannot produce one; a hand-written or mismatched one can.
    UpstreamUnnamed,
};

/// The bridge's spelling of `simdjson::ondemand::json_type`
/// (`src/include/simdjson/generic/ondemand/json_type.h:17-26`), with upstream's
/// own values.
///
/// `unknown` is not a "no idea" filler: it is what upstream answers for a value
/// whose first byte is not a JSON token start, so a `Walk` that contains one was
/// produced by a provider that let such a value through rather than refusing the
/// document, and the walk refuses it in turn. See `simdjson_br_walk`.
pub const ValueType = enum(u32) {
    unknown = 0,
    array = 1,
    object = 2,
    number = 3,
    string = 4,
    boolean = 5,
    null = 6,
};

/// The bridge's spelling of `simdjson::number_type`
/// (`src/include/simdjson/generic/base.h:43-48`), with upstream's own values.
///
/// `none` is this fork's addition and has no upstream counterpart: it is the
/// value on a record that is not a number at all, where upstream has no
/// `number_type`. `big` is upstream's `big_integer` -- a JSON integer too large
/// for 64 bits -- whose decimal text is in the record's string bytes and whose
/// numeric fields are all zero.
pub const NumberType = enum(u32) {
    none = 0,
    floating_point = 1,
    signed = 2,
    unsigned = 3,
    big = 4,
};

/// One value from a walked document.
///
/// A hand-written duplicate of `simdjson_bridge_node`
/// (`zig/bridge.h:319-367`), for the same reason `runtime/library.zig` has one:
/// this module *is* the thing that imports the translated header, so it could
/// import it -- but it must not, because the record is then handed to a caller
/// whose code was compiled against a possibly different header, and one
/// definition of the layout in the module that publishes it is what keeps the
/// two describable. Every field below carries the header line and the upstream
/// accessor it came from.
pub const Record = extern struct {
    /// Nesting level, 0 at the root.  From the bridge's own field
    /// (`zig/bridge.h:320-330`), which fills it from the walk's depth counter.
    depth: u32,
    /// A `ValueType`.
    type: u32,
    /// Direct children: elements for an array, fields for an object, 0 for
    /// anything else.  Counted while the container was iterated, never asked
    /// for separately.
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
    /// A boolean as 0 or 1 (`value::get_bool`, `value.h:391`), or a signed
    /// integer (`number::get_int64`, `json_type.h:72`).
    i: i64,
    /// An unsigned integer (`number::get_uint64`, `json_type.h:56`).
    u: u64,
    /// A binary64 number (`number::get_double`, `json_type.h:78`).
    d: f64,

    /// `SIMDJSON_BRIDGE_NO_OFFSET` (`zig/bridge.h:304`): the value of `key_off`
    /// and `str_off` when the record has no such bytes.
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

    /// This record's type, narrowed.
    ///
    /// An integer outside `ValueType` becomes `.unknown` rather than being
    /// reported: it is a fact about the provider, and a walk whose records
    /// disagree with the header they were produced for is already refused by
    /// the load-time check in `runtime/library.zig`.
    pub fn valueType(self: Record) ValueType {
        return std.enums.fromInt(ValueType, self.type) orelse ValueType.unknown;
    }

    /// This record's number type, narrowed, with `.none` for anything outside
    /// the enumeration.
    pub fn numberType(self: Record) NumberType {
        return std.enums.fromInt(NumberType, self.number_type) orelse NumberType.none;
    }
};

/// Maps a bridge status to an error, or `null` when the status is
/// `SIMDJSON_BRIDGE_OK`.
///
/// The `else` arm is not defensive padding: it is what makes the mapping total
/// without pretending the enumeration is exhaustive.  A status outside
/// `zig/bridge.h:127-148` cannot come from a correctly built provider, and
/// naming that (`UnknownStatus`) is more honest than folding it into
/// `InvalidArgument` or letting the switch fail to compile on a header edit that
/// nobody re-reads.
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

/// Maps an upstream `simdjson::error_code` integer to an error.
///
/// The integers are upstream's, and `zig/bridge.cc` static-asserts every one of
/// them against the real enumerator on every target that builds the library, so
/// this switch cannot disagree with what the library reports.  `else` covers an
/// integer outside the enumeration, which is `UpstreamUnnamed` for the same
/// reason `statusError` has an `else`.
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

/// Turns one `(status, upstream_code)` pair into a result.
///
/// `SIMDJSON_BRIDGE_UPSTREAM_ERROR` means the status alone says nothing useful,
/// so the code beside it is what the caller gets.  Every other non-success
/// status is this bridge's own and is reported as itself.
fn fail(raw: c_uint, code: i32) Error {
    if (raw == c.SIMDJSON_BRIDGE_UPSTREAM_ERROR) return upstreamError(code);
    return statusError(raw) orelse Error.UnknownStatus;
}

/// Reads one of the bridge's two-pass strings into a caller-supplied buffer.
///
/// The convention is `zig/bridge.h`'s: `*out_len` always receives the length
/// excluding the NUL, so a NULL buffer sizes the call and the second call needs
/// no guess.  Sizing first is what makes an unexpected length a reported error
/// rather than a truncation: a value that does not fit `out` is
/// `Error.BufferTooSmall`, not a silently shortened string.
///
/// `out` is borrowed only for the duration of the call; the returned slice
/// points into it and dies with it.
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

/// `SIMDJSON_VERSION` (`src/include/simdjson/simdjson_version.h:7`), reported
/// through the bridge's two-pass string entry point
/// (`zig/bridge.h:409-410`).
///
/// `out` is the caller's buffer and the returned slice borrows it.  A release
/// string longer than `out` is `Error.BufferTooSmall` and nothing is written.
pub fn version(out: []u8) Error![]const u8 {
    return readString(out, c.simdjson_br_version);
}

/// The SIMD kernel this artifact's On-Demand API is bound to, by name
/// (`zig/bridge.h:439-440`).
///
/// A compile-time property of how the library was built, not of the machine it
/// runs on.  It is not the same fact as `activeImplementation`; see
/// `zig/bridge.h:445-478` for what selects it and why the two are separate.
pub fn builtinImplementation(out: []u8) Error![]const u8 {
    return readString(out, c.simdjson_br_builtin_implementation);
}

/// The kernel the library's run-time dispatcher selected on this machine
/// (`zig/bridge.h:479-480`).
///
/// A property of the host CPU *and* of the `SIMDJSON_FORCE_IMPLEMENTATION`
/// environment variable, so no caller may compare it against a literal; see
/// `zig/bridge.h:445-478` for both.  It is also not a statement about which
/// kernel parsed through this bridge: On-Demand is statically bound to
/// `builtinImplementation`.
pub fn activeImplementation(out: []u8) Error![]const u8 {
    return readString(out, c.simdjson_br_active_implementation);
}

/// `simdjson::get_active_implementation()->description()`
/// (`src/include/simdjson/implementation.h:66`), under the same rules and the
/// same caveats as `activeImplementation` (`zig/bridge.h:485-487`).
pub fn activeImplementationDescription(out: []u8) Error![]const u8 {
    return readString(out, c.simdjson_br_active_implementation_description);
}

/// How many kernels were compiled into this library
/// (`src/include/simdjson/implementation.h:173`).
///
/// At least 1, and not always more: see `zig/bridge.h:498-503` for which
/// kernels a given target compiles.  A total function, so it cannot fail and has
/// no error arm.
pub fn availableImplementationCount() usize {
    return c.simdjson_br_available_implementation_count();
}

/// The `index`-th name in `availableImplementationCount`, or
/// `Error.InvalidArgument` for an index at or past it
/// (`zig/bridge.h:514-515`).
///
/// `out` is the caller's buffer and the returned slice borrows it.
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

/// Whether `bytes` is valid UTF-8, as `simdjson::validate_utf8`
/// (`src/include/simdjson/implementation.h:18`) answers it.
///
/// The only entry point here whose answer is a function of the bytes alone
/// rather than of how they parse, and the one the library also uses internally
/// during stage 1 (`src/include/simdjson/common_defs.h:365-366`
/// `SIMDJSON_UTF8VALIDATION`).  An empty range is valid.
pub fn validateUtf8(bytes: []const u8) Error!bool {
    var ok: c_int = 0;
    const status = c.simdjson_br_validate_utf8(bytes.ptr, bytes.len, &ok);
    if (status != c.SIMDJSON_BRIDGE_OK) return fail(status, 0);
    return ok == 1;
}

/// One open On-Demand document.
///
/// Owns exactly one thing: the bridge handle from `simdjson_br_open`
/// (`zig/bridge.h:566-568`).  The handle owns the bridge's padded copy of the
/// input, its parser and its document, and `deinit` releases all three through
/// `simdjson_br_destroy` (`zig/bridge.h:574`).
///
/// A `Document` is a *parsed* document, not a read one: opening it runs stage 1
/// over the whole input and reports every structural error there, so a `Document`
/// that exists has a structurally sound input.  Reading it is `walk`, and it is
/// one call because On-Demand is one-shot: there is no cursor a caller can hold
/// between two calls, and holding one is what upstream's
/// `OUT_OF_ORDER_ITERATION` exists to prevent
/// (`src/include/simdjson/generic/ondemand/document.h:560-569`).
pub const Document = struct {
    /// The bridge handle.  Private: a caller that could write to it could make
    /// `deinit` free something else.
    handle: *c.struct_simdjson_bridge_document,

    /// Releases the handle.  A default-constructed `Document` has a null handle
    /// and `deinit` does nothing, so `defer doc.deinit()` after a failed `parse`
    /// is safe.
    pub fn deinit(self: *Document) void {
        c.simdjson_br_destroy(self.handle);
        self.handle = undefined;
    }

    /// Walks the whole document and copies it out, allocating both buffers from
    /// `allocator`.
    ///
    /// Two passes, both inside this function: the first asks the bridge how many
    /// records and how many blob bytes the document needs, the second fills two
    /// allocations of exactly those sizes.  The caller never sees the two-pass
    /// protocol and cannot get it half right.
    ///
    /// A document that fails to walk leaves nothing allocated and returns the
    /// upstream error, because both allocations happen only after the sizing call
    /// has succeeded -- and the sizing call is the one that reads the whole
    /// document.
    ///
    /// The returned `Walk` owns the two slices and frees them with the same
    /// allocator, so `deinit` takes no allocator argument.
    ///
    /// Walking consumes the document's parser state and then puts it back:
    /// upstream's `document::rewind`
    /// (`src/include/simdjson/generic/ondemand/document.h:763`) runs before each
    /// pass, so this may be called more than once on the same `Document` and
    /// each call sees the same document.
    pub fn walk(self: *const Document, allocator: std.mem.Allocator) Error!Walk {
        return walkDocument(self, allocator);
    }
};

/// Parses `json` and returns a `Document` to walk.
///
/// The bytes are borrowed for the duration of the call and copied by the bridge
/// into a padded buffer upstream owns; the caller's buffer may be freed or reused
/// the instant this returns (`zig/bridge.h:349-380`).
///
/// On any error this constructs nothing and the caller's `Document` variable is
/// left exactly as it was.  `parser::iterate` runs stage 1 over the whole input
/// and reports through its result
/// (`src/include/simdjson/generic/ondemand/parser-inl.h:54-67`), so the refusals
/// stage 1 owns -- an empty input, invalid UTF-8, an unterminated string, a
/// document nested past the depth limit -- are reported here.
///
/// Stage 1 does not read the value-level grammar, so this call on its own is not
/// a verdict on the document.  Measured against this tree's own archive,
/// `iterate` answers `SUCCESS` for `{"a":1,}`, `{"a":01}`, `1e400` and `1 2`, and
/// each of those is refused by `Document.walk`, which is the one call that reads
/// the whole document.  A caller that needs to know whether a document is
/// well-formed asks `walk`, and that is where the remaining upstream codes come
/// from.
///
/// The two arguments that are refused rather than reported are a null pointer
/// and a length that cannot be padded; both are `Error.InvalidArgument`, decided
/// by comparisons in `zig/bridge.cc` before anything is allocated.
pub fn parse(json: []const u8) Error!Document {
    var handle: ?*c.struct_simdjson_bridge_document = null;
    var code: i32 = 0;
    const status = c.simdjson_br_open(json.ptr, json.len, &handle, &code);
    if (status != c.SIMDJSON_BRIDGE_OK) return fail(status, code);
    // A status of OK with no handle would mean the bridge reported success and
    // produced nothing.  `zig/bridge.cc` cannot do that, and a dereference of a
    // null handle would; refusing it here is the honest reading of the pair.
    if (handle == null) return Error.UnknownStatus;
    return Document{ .handle = handle.? };
}

/// A whole document, copied out of the parser in pre-order.
///
/// This is the only readable form of a `Document`, and it exists because
/// On-Demand is one-shot: upstream's `value`, `object` and `array` are positions
/// in a shared cursor and cannot be held across calls
/// (`src/include/simdjson/generic/ondemand/array_iterator.h:53-54`,
/// `object_iterator.h:38,44-46`), so a caller in another language needs the
/// document handed to it whole rather than a cursor to drive.
///
/// `nodes` is in pre-order: a container's record precedes every record beneath
/// it, and within a container the records appear in document order.  `blobs`
/// holds every object key and every string value, unescaped and not
/// NUL-terminated, at the offsets the records name.  `depth` on each record is
/// 0 at the root and one more per level of nesting.
///
/// Allocation is entirely the caller's: both slices come from the allocator
/// `Document.walk` was given, and `deinit` returns both to it.  The document
/// itself stays in the `Document`, so the two are independent lifetimes and
/// either may go first.
pub const Walk = struct {
    /// The allocator `deinit` must be given back the two slices to.  Stored so
    /// `deinit` cannot be called with the wrong one, which for most allocators
    /// is undefined rather than merely wrong.
    backing_allocator: std.mem.Allocator,
    /// Every value in the document, in pre-order.
    nodes: []Record,
    /// Every key and string value, at the offsets the records name.
    blobs: []u8,

    /// Releases both slices.  Leaves `nodes` and `blobs` empty, so reading a
    /// used `Walk` yields "no values" instead of a fault.  Calling it twice is
    /// safe: the second call frees two empty slices.
    pub fn deinit(self: *Walk) void {
        self.backing_allocator.free(self.blobs);
        self.backing_allocator.free(self.nodes);
        self.* = .{ .backing_allocator = self.backing_allocator, .nodes = &.{}, .blobs = &.{} };
    }

    /// The root value, or null for a `Walk` with no records.
    ///
    /// A `Walk` with no records is not something a successful parse produces; it
    /// is what a used `Walk` looks like, and returning null for it is what keeps
    /// that case a wrong answer rather than a fault.
    pub fn root(self: Walk) ?Value {
        if (self.nodes.len == 0) return null;
        return Value{ .walk = self, .index = 0 };
    }

    /// How many records the document has, counting every nested value.
    pub fn count(self: Walk) usize {
        return self.nodes.len;
    }

    /// The index of the `n`-th direct child of the record at `index`, or null
    /// when there is no such child.
    ///
    /// Pre-order makes this a walk rather than an arithmetic step: the children
    /// of a record are the records immediately after it whose `depth` is one
    /// greater, and each of those is followed by its own subtree.  `n` is bounded
    /// by the parent's `count`, which the walk counted, so a bad `n` costs a
    /// compare and not a scan of the document.
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

/// The implementation behind `Document.walk`, named separately so `Walk` -- the
/// type it returns -- and `walk` -- the module-level spelling -- cannot be
/// confused for one another in a reader's mind.  `Document.walk` is the route a
/// caller uses.
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

    // A zero record count from a successful sizing call would mean a document
    // with no root, which `parser::iterate` does not produce: `document::get_value`
    // answers `TAPE_ERROR` or `EMPTY` for that (`src/include/simdjson/generic/ondemand/document-inl.h:94`,
    // `src/generic/stage1/json_structural_indexer.h:197`).  Refusing it is what
    // stops `Walk.root` from having to return null for a walk that never
    // happened.
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

    // The two passes read the same document through the same code, so the counts
    // cannot differ.  Checking them anyway turns a hypothetical disagreement
    // into a named error instead of a `Walk` whose last record reads whatever
    // followed it in the buffer.
    if (filled_nodes != node_count or filled_blobs != blob_len) {
        return Error.UpstreamUnnamed;
    }

    return Walk{
        .backing_allocator = allocator,
        .nodes = nodes,
        .blobs = blobs,
    };
}

/// One value inside a `Walk`.
///
/// Borrows from the `Walk` that produced it and is invalid the moment that
/// `Walk` is deinitialized.  Holding one across a `deinit` is the only lifetime
/// rule on this type, and it is the same rule upstream's own iterators have.
pub const Value = struct {
    walk: Walk,
    index: usize,

    /// This value's record.  Internal; the accessors below read through it so
    /// a caller never has to hold a `Record` and keep it in step.
    fn record(self: Value) Record {
        return self.walk.nodes[self.index];
    }

    /// This value's type.
    pub fn valueType(self: Value) ValueType {
        return self.record().valueType();
    }

    /// How many direct children this value has: elements for an array, fields for
    /// an object, 0 for anything else.
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

    /// This value's string bytes, or null when it is not a string.
    ///
    /// Unescaped, not NUL-terminated, and borrowed from the `Walk`'s blob.
    pub fn string(self: Value) ?[]const u8 {
        return self.record().string(self.walk.blobs);
    }

    /// This value's signed integer, or null when its number type is not
    /// `signed`.
    ///
    /// Not a conversion: a `NumberType.unsigned` value is not narrowed into this
    /// and a `NumberType.big` value is not truncated, because the record carries
    /// only the field its own number type fills
    /// (`src/include/simdjson/generic/ondemand/json_type.h:52-58,66-78`).
    pub fn int(self: Value) ?i64 {
        if (self.record().numberType() != .signed) return null;
        return self.record().i;
    }

    /// This value's unsigned integer, or null when its number type is not
    /// `unsigned`.
    pub fn uint(self: Value) ?u64 {
        if (self.record().numberType() != .unsigned) return null;
        return self.record().u;
    }

    /// This value's binary64 number, or null when its number type is not
    /// `floating_point`.
    ///
    /// For an integer-typed value this is null rather than a widening: the
    /// record's `d` is zero for every number type except
    /// `floating_point`, and reading it as a double would report zero as an
    /// answer.
    pub fn double(self: Value) ?f64 {
        if (self.record().numberType() != .floating_point) return null;
        return self.record().d;
    }

    /// This value's boolean, or null when it is not one.
    ///
    /// `false` and "not a boolean" are different answers and this returns null
    /// for the second.
    pub fn boolean(self: Value) ?bool {
        if (self.valueType() != .boolean) return null;
        return self.record().i != 0;
    }

    /// Whether this value is JSON `null`, or null when it is not.
    ///
    /// Named for what it asks, not for what it returns: `null` the JSON value
    /// and "not null" are the same word in Zig, so the question and the answer
    /// cannot both be `null`.
    pub fn isNull(self: Value) ?bool {
        if (self.valueType() != .null) return null;
        return true;
    }

    /// This value's number type, `.none` for anything that is not a number.
    pub fn numberType(self: Value) NumberType {
        return self.record().numberType();
    }

    /// This value's decimal text when it is a `NumberType.big` integer, or null
    /// otherwise.
    ///
    /// Upstream reports an integer too large for 64 bits through
    /// `number_type::big_integer` (`src/include/simdjson/generic/base.h:47`) and
    /// documents every numeric accessor as valid only for its own type, so the
    /// decimal text is the whole of the answer.
    pub fn bigIntegerText(self: Value) ?[]const u8 {
        if (self.record().numberType() != .big) return null;
        return self.record().string(self.walk.blobs);
    }

    /// The `n`-th element, or null when this value is not an array or `n` is past
    /// its end.
    pub fn at(self: Value, n: usize) ?Value {
        const child = self.walk.nthChild(self.index, n) orelse return null;
        return Value{ .walk = self.walk, .index = child };
    }
};

/// One array inside a `Walk`.
///
/// Borrows from the `Walk` that produced it.  It is a *view over the walk's
/// records*, not a cursor into upstream's parser: iteration is a walk over
/// already-copied records, so it can be repeated, interleaved and nested without
/// any of upstream's one-shot restrictions.  That is what this package's shape
/// buys, and it is the reason the price is a copy of the document.
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

    /// A fresh iterator over this array's elements, in document order.
    ///
    /// Named apart from `iterator` so a caller who keeps one and re-starts can
    /// say so; the two are the same value otherwise.
    pub fn reset(self: Array) ArrayIterator {
        return self.iterator();
    }

    /// Every element, in document order.
    ///
    /// O(len^2) in the worst case, because each element is reached by a walk
    /// over the records under this array.  That is the honest cost of reading a
    /// pre-order stream by index, and it is why `iterator` exists: it advances a
    /// single position and is linear.  Use it for anything but a handful of
    /// elements.
    pub fn items(self: Array) ArrayIterator {
        return self.iterator();
    }
};

/// An iterator over an `Array`'s elements, in document order.
///
/// Advance it with `next`.  It borrows the `Walk` and is invalid once that is
/// deinitialized.
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

/// One object inside a `Walk`.
///
/// Borrows from the `Walk` that produced it.  See `Array` for what "a view over
/// the walk's records rather than a cursor" means.
pub const Object = struct {
    walk: Walk,
    index: usize,

    /// How many fields this object has.
    pub fn len(self: Object) usize {
        return self.walk.nodes[self.index].count;
    }

    /// The `n`-th field, or null when `n` is past the end.
    ///
    /// By position, not by name: the records are in document order, so this is
    /// the `n`-th key the document spells.
    pub fn at(self: Object, n: usize) ?Field {
        const child = self.walk.nthChild(self.index, n) orelse return null;
        return Field{
            .key = self.walk.nodes[child].key(self.walk.blobs) orelse &.{},
            .value = Value{ .walk = self.walk, .index = child },
        };
    }

    /// The field whose key equals `name`, or null when the object has no such
    /// field.
    ///
    /// This is a search over the records, not upstream's `find_field`: it costs
    /// a comparison per field and finds a key wherever it is, and it finds the
    /// *first* one -- an object with a repeated key has more than one answer and
    /// this reports the earlier one, which is what a caller reading the document
    /// in order would have seen first.
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

    /// Every field, in document order.
    ///
    /// O(len^2) in the worst case, for the reason `Array.items` gives.
    pub fn items(self: Object) ObjectIterator {
        return self.iterator();
    }
};

/// One field of an `Object`: its unescaped key and its value.
///
/// The key borrows from the `Walk`'s blob and is not NUL-terminated; an object
/// member whose key could not be read -- which a correctly built walk cannot
/// produce -- reports the empty slice rather than a fabricated name.
pub const Field = struct {
    key: []const u8,
    value: Value,
};

/// An iterator over an `Object`'s fields, in document order.
///
/// Advance it with `next`.  It borrows the `Walk` and is invalid once that is
/// deinitialized.
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