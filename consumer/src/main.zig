// SPDX-License-Identifier: Apache-2.0
// See ../FORK-LICENSE.md for the grant over this fork's own files.

//! Consumes the `simdjson` package the way an outside project would.
//!
//! Everything here goes through the published surface only: `dep.module` in
//! `build.zig`, and `@import("simdjson")` here. No path reaches into the
//! library's own tree, so if this builds and produces the answers below, the
//! module contract is real: the typed facade, the translated header it re-exports
//! as `c`, and the native library behind both arrived through one dependency
//! line.
//!
//! ## What the answers are
//!
//! Two kinds, and neither is a version pin:
//!
//!   * **RFC 8259.** Every expected value here is written from the RFC's own
//!     section 13 documents and its section 7 escape table, not from what the
//!     library returned. RFC 8259 is a published standard, so a consumer that
//!     disagrees with it is wrong in a way anybody can check.
//!   * **IEEE 754 and upstream's own error enumeration.** The binary64 boundary
//!     values are the standard's, and each refusal is checked for the specific
//!     `simdjson::error_code` rather than for "some error" -- because the
//!     classification is what a caller branches on.
//!
//! Anything that would change between two machines running the same binary is
//! **printed, never compared**: the version string, and both kernel names. Which
//! kernel a build carries is decided by the compile flags, and which one the
//! run-time dispatcher picks is decided by the host and the environment -- so
//! neither is an answer this program may assert on.
//!
//! ## One source, two configurations
//!
//! The same file builds against a linked package and against a runtime-loaded
//! one. `simdjson.runtime_loaded` is a comptime constant, so the difference is
//! one branch and no duplicated program: in the runtime-loaded build the
//! provider is named on the command line (`--provider <path>`) or in
//! `SIMDJSON_PROVIDER`, loaded once, and the same answers follow.

const std = @import("std");
const simdjson = @import("simdjson");

/// A runtime-loading build has no provider until one is named.
///
/// Its own error rather than the loader's, so a run without a provider reports
/// *this* program's configuration problem rather than a load failure the caller
/// would read as "the library is broken".
const ConfigurationError = error{NoProviderConfigured};

/// The provider this run should load, from `--provider <path>` or from
/// `SIMDJSON_PROVIDER`.
///
/// Both are explicit. Nothing here looks in a default location, and a build that
/// was not told which file to load says so rather than loading something else --
/// which is the whole contract of `-Druntime`, and the reason a missing provider
/// is an error here rather than a fallback to another library.
fn providerRequest(init: std.process.Init) ConfigurationError![]const u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch
        return noProvider();
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--provider")) {
            if (index + 1 >= args.len) return noProvider();
            return args[index + 1];
        }
    }
    return init.environ_map.get("SIMDJSON_PROVIDER") orelse
        return noProvider();
}

/// Say which variable is missing.
///
/// An error name on its own would send the next person into the loader instead of
/// to the command line.
fn noProvider() ConfigurationError {
    std.debug.print(
        "\nconsumer: this is a runtime-loading build, so no provider is named yet.\n" ++
            "Pass --provider <path>, or export SIMDJSON_PROVIDER, with a shared\n" ++
            "object exporting the eleven entry points of simdjson_bridge.h.\n" ++
            "Nothing is loaded by default and no other file is tried.\n",
        .{},
    );
    return error.NoProviderConfigured;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;

    // In a runtime-loading build every native call below goes through a table
    // that this one call fills. In a linked build the branch is not analysed at
    // all, so there is no second code path to keep in step.
    if (comptime simdjson.runtime_loaded) {
        try simdjson.load(.{ .path = try providerRequest(init) });
    }

    try w.print("simdjson consumer\n", .{});
    // Printed, not compared: a version string is provenance, and the provenance
    // gate is the library's own `tools/check-provenance.sh`.
    var text: [256]u8 = undefined;
    try w.print("{s: <44}{s}\n", .{
        if (simdjson.runtime_loaded) "loaded provider reports" else "linked provider reports",
        simdjson.version(&text) catch |err| @errorName(err),
    });
    try w.print("{s: <44}{s}\n", .{
        "built for kernel",
        simdjson.builtinImplementation(&text) catch |err| @errorName(err),
    });
    try w.print("{s: <44}{s}\n", .{
        "dispatcher picked here",
        simdjson.activeImplementation(&text) catch |err| @errorName(err),
    });
    // One machine's answer is not another's, which is why the two lines above
    // are printed. There is no run-time fallback behind a slow kernel:
    // `#include <simdjson/ondemand.h>` is statically bound to the builtin one
    // (`src/include/simdjson/builtin/ondemand.h:39`), so "built for kernel" above
    // *is* the kernel that parsed through this bridge, and "dispatcher picked
    // here" is a statement about something else entirely.
    try w.print("{s: <44}{d} compiled in\n", .{
        "kernels in this artifact",
        simdjson.availableImplementationCount(),
    });

    // A dependent gets a document that owns itself and says what closing it
    // means.
    {
        var document = try simdjson.parse("{\"a\":[1,2,3],\"b\":{\"c\":\"d\"}}");
        defer document.deinit();
        var walk = try document.walk(init.arena.allocator());
        defer walk.deinit();

        const object = walk.root().?.object().?;
        const array = object.get("a").?.value.array().?;
        var sum: i64 = 0;
        var iterator = array.iterator();
        while (iterator.next()) |element| sum += element.int().?;
        try checkInt(w, "1 + 2 + 3", sum, 6);

        // Nested object by name, which is the thing a caller in another language
        // most wants and the thing upstream's one-shot cursor cannot offer.
        try checkString(w, "nested b.c", object.get("b").?.value.object().?.get("c").?.value.string().?, "d");
    }

    // RFC 8259 section 13's own examples, read through the published surface.
    {
        var document = try simdjson.parse("\"Hello world!\"");
        defer document.deinit();
        var walk = try document.walk(init.arena.allocator());
        defer walk.deinit();
        try checkString(w, "RFC 8259 A: string", walk.root().?.string().?, "Hello world!");
    }
    {
        var document = try simdjson.parse("42");
        defer document.deinit();
        var walk = try document.walk(init.arena.allocator());
        defer walk.deinit();
        try checkInt(w, "RFC 8259 A: number", walk.root().?.int().?, 42);
        // Not widened: a `signed` value answers `int()` and nothing else, because
        // the record's `d` field is zero for every type but `floating_point`.
        try checkInt(w, "RFC 8259 A: not a double", @as(u8, @intFromBool(walk.root().?.double() == null)), @as(u8, 1));
    }
    {
        var document = try simdjson.parse("true");
        defer document.deinit();
        var walk = try document.walk(init.arena.allocator());
        defer walk.deinit();
        try checkInt(w, "RFC 8259 A: boolean true", @as(u8, @intFromBool(walk.root().?.boolean().?)), @as(u8, 1));
    }

    // RFC 8259 section 7's escapes and section 3's UTF-8, in one array.
    {
        var document = try simdjson.parse("[\"\\\"\",\"\\/\",\"\\u0041\",\"\\u00e9\",\"\\ud834\\udd1e\"]");
        defer document.deinit();
        var walk = try document.walk(init.arena.allocator());
        defer walk.deinit();
        const items = walk.root().?.array().?;
        try checkInt(w, "escapes: five elements", items.len(), @as(usize, 5));
        try checkString(w, "escape \\\"", items.get(0).?.string().?, "\"");
        try checkString(w, "escape \\/", items.get(1).?.string().?, "/");
        try checkString(w, "@escape @\\u0041", items.get(2).?.string().?, "A");
        try checkString(w, "@escape @\\u00e9", items.get(3).?.string().?, "\u{00E9}");
        // The surrogate pair for U+1D11E: one code point, four UTF-8 bytes. A
        // consumer that decoded each surrogate separately would produce six
        // bytes of something else, so the length is checked alongside the value.
        try checkString(w, "surrogate pair -> U+1D11E", items.get(4).?.string().?, "\u{1D11E}");
        try checkInt(w, "U+1D11E is four bytes", items.get(4).?.string().?.len, @as(usize, 4));
    }

    // IEEE 754 boundaries, from the standard rather than from the parser.
    {
        var document = try simdjson.parse("[1.5,2.2250738585072011e-308,1.7976931348623157e308]");
        defer document.deinit();
        var walk = try document.walk(init.arena.allocator());
        defer walk.deinit();
        const items = walk.root().?.array().?;
        // 1.5 is exactly representable, so this is an equality.
        try checkFloat(w, "1.5 is exact", items.get(0).?.double().?, 1.5);
        // The smallest normal binary64.
        try checkFloat(w, "smallest normal", items.get(1).?.double().?, 2.2250738585072011e-308);
        // The largest finite binary64.
        try checkFloat(w, "largest finite", items.get(2).?.double().?, std.math.floatMax(f64));
    }

    // The big-integer boundary: 2^64 - 1 fits a u64, and 2^64 does not.
    {
        var document = try simdjson.parse("[18446744073709551615,18446744073709551616]");
        defer document.deinit();
        var walk = try document.walk(init.arena.allocator());
        defer walk.deinit();
        const items = walk.root().?.array().?;
        try checkInt(w, "u64 max is unsigned", items.get(0).?.uint().?, @as(u64, std.math.maxInt(u64)));
        try checkString(w, "past u64 is big, and text is the answer", items.get(1).?.bigIntegerText().?, "18446744073709551616");
    }

    // Refusals, with the classification each one carries. RFC 8259 section 6
    // (`int = zero / (digit1-9 *DIGIT)`) forbids `01`; section 8 forbids extra
    // content after a complete value.
    {
        try checkRefusal(w, init.arena.allocator(), "{\"a\":01}", simdjson.Error.UpstreamNumber);
        try checkRefusal(w, init.arena.allocator(), "{\"a\":1,}", simdjson.Error.UpstreamTape);
        try checkRefusal(w, init.arena.allocator(), "{\"a\":NaN}", simdjson.Error.UpstreamTape);
        try checkRefusal(w, init.arena.allocator(), "{\"a\":\"b}", simdjson.Error.UpstreamUnclosedString);
        try checkRefusal(w, init.arena.allocator(), "", simdjson.Error.UpstreamEmpty);
        try checkRefusal(w, init.arena.allocator(), "1 2", simdjson.Error.UpstreamTrailingContent);
        // `1e400` is a legal document that binary64 cannot hold, and upstream
        // refuses it rather than answering infinity or a clamp. The enumerator
        // is `NUMBER_ERROR`, not `NUMBER_OUT_OF_RANGE`: this refusal comes out
        // of `numberparsing::parse_number`, whose float paths reach
        // `parse_float_fallback`, and that "will return an error (false) if the
        // parsed number is infinite"
        // (`src/include/simdjson/generic/numberparsing.h:532-533`) and convert
        // it to `NUMBER_ERROR` (`:1416, :1507, :1647, :1738, :1831`).
        // `NUMBER_OUT_OF_RANGE` (`error.h:38`) is raised by the typed getters in
        // `generic/ondemand/value-inl.h`, which this path never calls.
        try checkRefusal(w, init.arena.allocator(), "1e400", simdjson.Error.UpstreamNumber);
    }

    // The raw route, reached through the same published module. A declaration
    // the facade does not wrap, called from outside the library -- which is the
    // point of `simdjson.c`.
    {
        const count = simdjson.c.simdjson_br_available_implementation_count();
        try checkInt(w, "raw: at least one kernel is compiled in", @as(u8, @intFromBool(count >= 1)), @as(u8, 1));
        // An index past the list is refused rather than read past, which is the
        // raw route's own argument check.
        var length: usize = 0;
        const status = simdjson.c.simdjson_br_available_implementation_name(count, null, 0, &length);
        try checkInt(
            w,
            "raw: an index past the list is refused",
            @as(u8, @intFromBool(status == simdjson.c.SIMDJSON_BRIDGE_INVALID_ARGUMENT)),
            @as(u8, 1),
        );
    }

    // Ownership, because a leaking consumer is worse than a failing one. A
    // `Walk` read after `deinit` yields no values rather than a fault, and the
    // arena this run allocates from is freed with the process, so the thing a
    // consumer actually has to get right is the *handle*: `Document.deinit`
    // releases it inside the library and accepts a default-constructed document,
    // which is what makes `defer` after a failed `parse` the right shape.
    {
        var kept = try simdjson.parse("{\"kept\":1}");
        defer kept.deinit();
        _ = try simdjson.parse("{\"a\":1,}"); // refused; constructs nothing
        var walk = try kept.walk(init.arena.allocator());
        defer walk.deinit();
        try checkInt(
            w,
            "a refused parse left the open document alone",
            walk.root().?.object().?.get("kept").?.value.int().?,
            @as(i64, 1),
        );
    }

    try w.print("\nevery answer matched its expected value\n", .{});
    try w.flush();
}

fn checkInt(w: *std.Io.Writer, what: []const u8, got: anytype, expected: anytype) !void {
    try w.print("{s: <52}{d}\n", .{ what, got });
    if (got != expected) {
        std.debug.print("consumer: {s}: expected {d}, computed {d}\n", .{ what, expected, got });
        return error.ConsumerCheckFailed;
    }
}

fn checkFloat(w: *std.Io.Writer, what: []const u8, got: f64, expected: f64) !void {
    // Bit equality rather than an epsilon. Every float this program compares is
    // one the standard says is exactly representable -- 1.5, the smallest normal
    // binary64, the largest finite binary64 -- so a tolerance would be a weaker
    // test than the fact allows.
    try w.print("{s: <52}{d}\n", .{ what, got });
    if (got != expected) {
        std.debug.print("consumer: {s}: expected {d}, computed {d}\n", .{ what, expected, got });
        return error.ConsumerCheckFailed;
    }
}

fn checkString(w: *std.Io.Writer, what: []const u8, got: []const u8, expected: []const u8) !void {
    try w.print("{s: <52}{s}\n", .{ what, got });
    if (!std.mem.eql(u8, got, expected)) {
        std.debug.print("consumer: {s}: expected \"{s}\", computed \"{s}\"\n", .{
            what,
            expected,
            got,
        });
        return error.ConsumerCheckFailed;
    }
}

fn checkRefusal(
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    json: []const u8,
    expected: simdjson.Error,
) !void {
    // `parse` is upstream's stage 1 (`zig/bridge.h:547-554`), and `zig/bridge.cc`
    // records, measured against this tree's own archive, that `iterate` returns
    // SUCCESS for `{"a":01}`, `{"a":1,}`, `{"a":NaN}` and `1 2`: those are
    // refused later, from the walk. So the refusal has to be looked for at both
    // entry points, and it is the pair that has to refuse with the expected
    // enumerator -- checking `parse` alone would accept a build that refused
    // nothing at all.
    var got: ?simdjson.Error = null;
    if (simdjson.parse(json)) |document| {
        var owned = document;
        defer owned.deinit();
        if (owned.walk(allocator)) |walk| {
            var walked = walk;
            defer walked.deinit();
        } else |err| {
            got = err;
        }
    } else |err| {
        got = err;
    }
    const name: []const u8 = if (got) |err| @errorName(err) else "success";
    try w.print("{s: <52}{s}\n", .{ json, name });
    // Error sets have no `!=`, and `name` is already `@errorName` of the value
    // `got` holds, with "success" standing for the null case. Names are unique
    // within one error set, so comparing the names is the same answer, and a
    // parse that succeeded reports "success", which no expected error name
    // equals.
    if (!std.mem.eql(u8, name, @errorName(expected))) {
        std.debug.print("consumer: {s}: expected {s}, computed {s}\n", .{
            json,
            @errorName(expected),
            name,
        });
        return error.ConsumerCheckFailed;
    }
}