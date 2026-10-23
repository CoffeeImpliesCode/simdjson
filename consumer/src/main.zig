// SPDX-License-Identifier: Apache-2.0
// See ../FORK-LICENSE.md for the grant over this fork's own files.

//! Uses only the published `simdjson` module and checks results against RFC 8259, IEEE 754, and upstream error values.
//! Prints provider version and SIMD choices because they vary by build and host.
//! The same program exercises linked and runtime-loaded configurations.

const std = @import("std");
const simdjson = @import("simdjson");

/// Error reported when runtime mode has no named provider.
const ConfigurationError = error{NoProviderConfigured};

/// Reads the runtime provider from `--provider` or `SIMDJSON_PROVIDER`; no implicit lookup.
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

/// Prints the missing-provider diagnostic.
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

    // Load the runtime provider before making native calls.
    if (comptime simdjson.runtime_loaded) {
        try simdjson.load(.{ .path = try providerRequest(init) });
    }

    try w.print("simdjson consumer\n", .{});
    // Print the provider version for provenance; it is not a test expectation.
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
    // Report compiled and active implementations; they depend on build, host, and environment.
    try w.print("{s: <44}{d} compiled in\n", .{
        "kernels in this artifact",
        simdjson.availableImplementationCount(),
    });

    // Release document handles inside the provider.
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

        // Exercise nested object lookup by name.
        try checkString(w, "nested b.c", object.get("b").?.value.object().?.get("c").?.value.string().?, "d");
    }

    // Check RFC 8259 object and array examples.
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
        // Signed integer records do not expose a double value.
        try checkInt(w, "RFC 8259 A: not a double", @as(u8, @intFromBool(walk.root().?.double() == null)), @as(u8, 1));
    }
    {
        var document = try simdjson.parse("true");
        defer document.deinit();
        var walk = try document.walk(init.arena.allocator());
        defer walk.deinit();
        try checkInt(w, "RFC 8259 A: boolean true", @as(u8, @intFromBool(walk.root().?.boolean().?)), @as(u8, 1));
    }

    // Check JSON escape decoding and UTF-8 output.
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
        // A surrogate pair decodes to one code point and four UTF-8 bytes.
        try checkString(w, "surrogate pair -> U+1D11E", items.get(4).?.string().?, "\u{1D11E}");
        try checkInt(w, "U+1D11E is four bytes", items.get(4).?.string().?.len, @as(usize, 4));
    }

    // Check exact binary64 boundary values.
    {
        var document = try simdjson.parse("[1.5,2.2250738585072011e-308,1.7976931348623157e308]");
        defer document.deinit();
        var walk = try document.walk(init.arena.allocator());
        defer walk.deinit();
        const items = walk.root().?.array().?;
        try checkFloat(w, "1.5 is exact", items.get(0).?.double().?, 1.5);
        try checkFloat(w, "smallest normal", items.get(1).?.double().?, 2.2250738585072011e-308);
        try checkFloat(w, "largest finite", items.get(2).?.double().?, std.math.floatMax(f64));
    }

    // Check the boundary between values that fit in `u64` and those that do not.
    {
        var document = try simdjson.parse("[18446744073709551615,18446744073709551616]");
        defer document.deinit();
        var walk = try document.walk(init.arena.allocator());
        defer walk.deinit();
        const items = walk.root().?.array().?;
        try checkInt(w, "u64 max is unsigned", items.get(0).?.uint().?, @as(u64, std.math.maxInt(u64)));
        try checkString(w, "past u64 is big, and text is the answer", items.get(1).?.bigIntegerText().?, "18446744073709551616");
    }

    // Check malformed JSON, empty input, overflow, and trailing content by error class.
    {
        try checkRefusal(w, init.arena.allocator(), "{\"a\":01}", simdjson.Error.UpstreamNumber);
        try checkRefusal(w, init.arena.allocator(), "{\"a\":1,}", simdjson.Error.UpstreamTape);
        try checkRefusal(w, init.arena.allocator(), "{\"a\":NaN}", simdjson.Error.UpstreamTape);
        try checkRefusal(w, init.arena.allocator(), "{\"a\":\"b}", simdjson.Error.UpstreamUnclosedString);
        try checkRefusal(w, init.arena.allocator(), "", simdjson.Error.UpstreamEmpty);
        try checkRefusal(w, init.arena.allocator(), "1 2", simdjson.Error.UpstreamTrailingContent);
        // `1e400` is legal JSON but exceeds binary64; upstream reports `NUMBER_ERROR`.
        try checkRefusal(w, init.arena.allocator(), "1e400", simdjson.Error.UpstreamNumber);
    }

    // Exercise a bridge call not wrapped by the Zig facade.
    {
        const count = simdjson.c.simdjson_br_available_implementation_count();
        try checkInt(w, "raw: at least one kernel is compiled in", @as(u8, @intFromBool(count >= 1)), @as(u8, 1));
        // Out-of-range implementation indices are rejected.
        var length: usize = 0;
        const status = simdjson.c.simdjson_br_available_implementation_name(count, null, 0, &length);
        try checkInt(
            w,
            "raw: an index past the list is refused",
            @as(u8, @intFromBool(status == simdjson.c.SIMDJSON_BRIDGE_INVALID_ARGUMENT)),
            @as(u8, 1),
        );
    }

    // Exercise document ownership and `deinit`, including an empty handle.
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
    // Compare exact values rather than using an epsilon.
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
    // Check both parse and walk stages; malformed JSON can reach either stage.
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
    // Compare error names because Zig error sets do not support `!=`.
    if (!std.mem.eql(u8, name, @errorName(expected))) {
        std.debug.print("consumer: {s}: expected {s}, computed {s}\n", .{
            json,
            @errorName(expected),
            name,
        });
        return error.ConsumerCheckFailed;
    }
}
