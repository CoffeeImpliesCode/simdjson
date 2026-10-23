// SPDX-License-Identifier: Apache-2.0
// See FORK-LICENSE.md for the grant over this fork's own files.
//! Deterministic facade example that reads recorded fixtures.
//! Prints computed values and expectations; reports kernel details without comparing them.

const std = @import("std");
const simdjson = @import("simdjson");

/// Build-provided fixture directory.
const paths = @import("simdjson_paths");

/// Maximum fixture read size.
const fixture_bound: std.Io.Limit = .limited(8 * 1024 * 1024);

/// Count of failed checks.
var failures: usize = 0;

/// Reads one fixture from the build-provided directory.
fn fixture(io: std.Io, allocator: std.mem.Allocator, relative: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ paths.fixture_dir, relative });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, fixture_bound);
}

/// Prints and counts a value comparison.
fn check(w: *std.Io.Writer, what: []const u8, got: anytype, expected: anytype) !void {
    const ok = got == expected;
    try w.print("{s: <44}{s}\n", .{ what, if (ok) "ok" else "MISMATCH" });
    if (ok) return;
    try w.print("{s: <44}expected {}, computed {}\n", .{ what, expected, got });
    failures += 1;
}

/// Compares and prints strings with visible boundaries.
fn checkString(w: *std.Io.Writer, what: []const u8, got: []const u8, expected: []const u8) !void {
    const ok = std.mem.eql(u8, got, expected);
    try w.print("{s: <44}{s}\n", .{ what, if (ok) "ok" else "MISMATCH" });
    if (ok) return;
    try w.print("{s: <44}expected \"{s}\", computed \"{s}\"\n", .{ what, expected, got });
    failures += 1;
}

/// Buffer for bridge strings.
const string_buffer_size = 256;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    var out_buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    const w = &stdout.interface;

    // Runtime-loaded builds require an explicit provider.
    if (comptime simdjson.runtime_loaded) {
        const request = providerRequest(init) catch |err| {
            std.debug.print(
                "\nsimdjson smoke: this is a runtime-loading build (-Druntime=true), so no\n" ++
                    "provider is named yet. Pass --provider <path>, or export\n" ++
                    "SIMDJSON_SMOKE_PROVIDER, with a shared object exporting the eleven\n" ++
                    "entry points of zig/bridge.h. Nothing is loaded by default and no other\n" ++
                    "file is tried.\n",
                .{},
            );
            return err;
        };
        try simdjson.load(.{ .path = request });
    }

    try w.print("simdjson smoke example\n", .{});
    try w.print("{s: <44}{s}\n", .{
        "configuration",
        if (simdjson.runtime_loaded) "runtime-loaded" else "linked",
    });
    if (simdjson.loadedSource()) |source| {
        switch (source) {
            .path => |path| try w.print("{s: <44}{s}\n", .{ "loaded provider", path }),
            .system => |name| try w.print("{s: <44}{s}\n", .{ "loaded provider", name }),
        }
    }

    var text: [string_buffer_size]u8 = undefined;
    try w.print("{s: <44}{s}\n", .{ "SIMDJSON_VERSION", simdjson.version(&text) catch |err| {
        std.debug.print("simdjson smoke: version(): {s}\n", .{@errorName(err)});
        return err;
    } });

    try w.writeAll(
        "\n" ++
            "  which kernel this artifact was compiled for\n" ++
            "  which kernel the run-time dispatcher picked here\n" ++
            "  Neither is compared: both are facts about the build flags and the\n" ++
            "  host, and On-Demand is statically bound to the first of them\n",
    );
    try w.print("{s: <44}{s}\n", .{
        "builtinImplementation (compile time)",
        simdjson.builtinImplementation(&text) catch "unavailable",
    });
    try w.print("{s: <44}{s}\n", .{
        "activeImplementation (host + environment)",
        simdjson.activeImplementation(&text) catch "unavailable",
    });
    // Kernel count depends on build flags.
    try w.print("{s: <44}{d}\n", .{ "availableImplementationCount", simdjson.availableImplementationCount() });

    try runChecks(io, w, allocator);
    try w.flush();

    if (failures == 0) {
        try w.print("\nevery answer matched its expected value\n", .{});
        return;
    }
    std.debug.print("\nsimdjson smoke: {d} check(s) did not match\n", .{failures});
    return error.ExpectedValuesDidNotMatch;
}

/// Runs the fixture-backed checks.
fn runChecks(io: std.Io, w: *std.Io.Writer, allocator: std.mem.Allocator) !void {
    // RFC 8259 example: the scalar value 42.
    {
        const json = try fixture(io, allocator, "rfc8259/13-value-number.json");
        try w.writeAll("\nRFC 8259 examples\n");
        var document = try simdjson.parse(json);
        defer document.deinit();
        var walk = try document.walk(allocator);
        defer walk.deinit();
        const root = walk.root() orelse return error.NoRoot;
        try check(w, "section 13 number: int()", root.int().?, @as(i64, 42));
        try check(w, "section 13 number: numberType", root.numberType(), simdjson.NumberType.signed);
        try check(w, "section 13 number: double() is null", root.double() == null, true);

        // The string example uses the same RFC section.
        const string_json = try fixture(io, allocator, "rfc8259/13-value-string.json");
        var string_document = try simdjson.parse(string_json);
        defer string_document.deinit();
        var string_walk = try string_document.walk(allocator);
        defer string_walk.deinit();
        const string_root = string_walk.root() orelse return error.NoRoot;
        try checkString(w, "section 13 string", string_root.string().?, "Hello world!");
    }

    // Check the fixture's numeric values, including binary64 limits.
    {
        const json = try fixture(io, allocator, "values/number-grammar.json");
        try w.writeAll("\nnumber grammar\n");
        var document = try simdjson.parse(json);
        defer document.deinit();
        var walk = try document.walk(allocator);
        defer walk.deinit();
        const items = (walk.root() orelse return error.NoRoot).array() orelse
            return error.NotAnArray;

        try check(w, "elements", @as(usize, items.len()), @as(usize, 17));
        try check(w, "3.5 is exactly representable", items.get(5).?.double().?, @as(f64, 3.5));
        try check(w, "-3.5 is exactly representable", items.get(6).?.double().?, @as(f64, -3.5));
        try check(w, "1.5e10 is exactly representable", items.get(7).?.double().?, @as(f64, 1.5e10));
        try check(w, "the largest finite binary64", items.get(15).?.double().?, std.math.floatMax(f64));
        try check(w, "its negative", items.get(16).?.double().?, -std.math.floatMax(f64));
    }

    // Check escapes and Unicode decoding against RFC 8259.
    {
        const json = try fixture(io, allocator, "values/string-escapes.json");
        try w.writeAll("\nstring escapes\n");
        var document = try simdjson.parse(json);
        defer document.deinit();
        var walk = try document.walk(allocator);
        defer walk.deinit();
        const items = (walk.root() orelse return error.NoRoot).array() orelse
            return error.NotAnArray;

        try checkString(w, "\\\"", items.get(0).?.string().?, "\"");
        try checkString(w, "\\/", items.get(2).?.string().?, "/");
        try checkString(w, "\\u0041", items.get(8).?.string().?, "A");
        try checkString(w, "\\u00e9", items.get(9).?.string().?, "\u{00E9}");
        try checkString(w, "\\u4e2d\\u6587", items.get(10).?.string().?, "\u{4E2D}\u{6587}");
        // The surrogate pair for U+1D11E: one code point, four UTF-8 bytes.
        try checkString(w, "\\ud834\\udd1e", items.get(11).?.string().?, "\u{1D11E}");
        try check(w, "U+1D11E is four bytes", @as(usize, items.get(11).?.string().?.len), @as(usize, 4));
    }

    // Check the upstream error assigned to each malformed document.
    {
        try w.writeAll("\nrefusals\n");
        try reportRefusal(io, w, "01-trailing-comma-object", simdjson.Error.UpstreamTape);
        try reportRefusal(io, w, "02-single-quoted-string", simdjson.Error.UpstreamTape);
        try reportRefusal(io, w, "03-unquoted-key", simdjson.Error.UpstreamTape);
        try reportRefusal(io, w, "04-nan-literal", simdjson.Error.UpstreamTape);
        try reportRefusal(io, w, "05-leading-plus-number", simdjson.Error.UpstreamTape);
        try reportRefusal(io, w, "07-missing-colon", simdjson.Error.UpstreamTape);
        try reportRefusal(io, w, "08-unterminated-string", simdjson.Error.UpstreamUnclosedString);
        try reportRefusal(io, w, "09-empty-input", simdjson.Error.UpstreamEmpty);

        // Literal cases pin number boundaries that are clearer inline.
        try reportLiteralRefusal(w, "{\"a\":01}", simdjson.Error.UpstreamNumber);
        // Binary64 overflow is a number error, not infinity.
        try reportLiteralRefusal(w, "1e400", simdjson.Error.UpstreamNumber);
    }

    // Check leaf values and depth in fixtures with two nesting levels.
    {
        try w.writeAll("\nnesting\n");
        try reportLeaf(io, w, allocator, "values/nesting-32.json", 32);
        try reportLeaf(io, w, allocator, "values/nesting-64.json", 64);
    }

    // Duplicate keys remain in the walk, and lookup returns the first.
    {
        const json = try fixture(io, allocator, "values/duplicate-keys.json");
        try w.writeAll("\nduplicate keys\n");
        var document = try simdjson.parse(json);
        defer document.deinit();
        var walk = try document.walk(allocator);
        defer walk.deinit();
        const object = (walk.root() orelse return error.NoRoot).object() orelse
            return error.NotAnObject;
        try check(w, "fields kept, not collapsed", @as(usize, object.len()), @as(usize, 3));
        try check(w, "get(\"a\") is the first", (object.get("a") orelse return error.MissingKey).value.int().?, @as(i64, 1));
        try check(w, "the third field is the second \"a\"", (object.at(2) orelse return error.NoField).value.int().?, @as(i64, 3));
        try check(w, "records", @as(usize, walk.count()), @as(usize, 4));
    }

    // Walk the upstream Twitter example and read each status object.
    {
        const json = try fixture(io, allocator, "large/twitter.json");
        try w.writeAll("\nlarge document\n");
        var document = try simdjson.parse(json);
        defer document.deinit();
        var walk = try document.walk(allocator);
        defer walk.deinit();
        const object = (walk.root() orelse return error.NoRoot).object() orelse
            return error.NotAnObject;

        try check(w, "input bytes", @as(usize, json.len), @as(usize, 631515));
        // The document has two top-level keys; `query` is nested.
        try check(w, "top-level keys", @as(usize, object.len()), @as(usize, 2));
        var label_buffer: [64]u8 = undefined;
        for ([_][]const u8{ "statuses", "search_metadata" }) |key| {
            try check(w, try std.fmt.bufPrint(&label_buffer, "has {s}", .{key}), object.get(key) != null, true);
        }
        const statuses = (object.get("statuses") orelse return error.MissingKey).value.array() orelse
            return error.NotAnArray;
        try check(w, "statuses walked", statuses.len() > 0, true);

        var seen: usize = 0;
        var iterator = statuses.iterator();
        while (iterator.next()) |status| : (seen += 1) {
            const status_object = status.object() orelse return error.NotAnObject;
            _ = status_object.get("text") orelse return error.MissingKey;
        }
        try check(w, "every status has a text", @as(usize, seen), @as(usize, statuses.len()));
        try check(w, "records walked", walk.count() > 0, true);
    }

    // Check that deinit clears the walk's records.
    {
        try w.writeAll("\nownership\n");
        var document = try simdjson.parse("{\"a\":[1,2,3]}");
        defer document.deinit();
        var walk = try document.walk(allocator);
        // The document has one record per value.
        try check(w, "records before deinit", @as(usize, walk.count()), @as(usize, 5));
        walk.deinit();
        try check(w, "records after deinit", @as(usize, walk.count()), @as(usize, 0));
        try check(w, "root after deinit is null", walk.root() == null, true);
    }
}

/// Reads one malformed fixture and checks its error.
fn reportRefusal(
    io: std.Io,
    w: *std.Io.Writer,
    name: []const u8,
    expected: simdjson.Error,
) !void {
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "malformed/{s}.json", .{name});
    const json = try fixture(io, std.heap.page_allocator, path);
    defer std.heap.page_allocator.free(json);
    try report(w, name, json, expected);
}

/// Reads a literal and checks its error.
fn reportLiteralRefusal(w: *std.Io.Writer, json: []const u8, expected: simdjson.Error) !void {
    try report(w, json, json, expected);
}

/// Reads a document through the facade and checks its error.
fn report(w: *std.Io.Writer, what: []const u8, json: []const u8, expected: simdjson.Error) !void {
    const got: ?simdjson.Error = if (simdjson.parse(json)) |document| blk: {
        var owned = document;
        defer owned.deinit();
        break :blk if (owned.walk(std.heap.page_allocator)) |walk| read: {
            var filled = walk;
            defer filled.deinit();
            break :read null;
        } else |err| err;
    } else |err| err;
    if (std.meta.eql(got, expected)) {
        try w.print("{s: <44}{s} (as expected)\n", .{ what, @errorName(expected) });
        return;
    }
    try w.print("{s: <44}expected {s}, computed {s}\n", .{
        what,
        @errorName(expected),
        if (got) |e| @errorName(e) else "success",
    });
    failures += 1;
}

/// Walks a nesting fixture and reports its leaf depth.
fn reportLeaf(
    io: std.Io,
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    relative: []const u8,
    levels: u32,
) !void {
    const json = try fixture(io, allocator, relative);
    var document = try simdjson.parse(json);
    defer document.deinit();
    var walk = try document.walk(allocator);
    defer walk.deinit();

    var node = walk.root() orelse return error.NoRoot;
    var depth: u32 = 0;
    while (true) {
        const object = node.object() orelse return error.NotAnObject;
        const next = object.get("a") orelse {
            const leaf = object.get("leaf") orelse return error.NoLeaf;
            var label_buffer: [128]u8 = undefined;
            try check(w, try std.fmt.bufPrint(&label_buffer, "{s}: leaf value", .{relative}), leaf.value.int().?, @as(i64, 1));
            // The leaf value is two records deeper than the numbered levels.
            try check(w, try std.fmt.bufPrint(&label_buffer, "{s}: leaf depth", .{relative}), walk.nodes[leaf.value.index].depth, levels + 1);
            try check(w, try std.fmt.bufPrint(&label_buffer, "{s}: records", .{relative}), @as(usize, walk.count()), @as(usize, levels + 2));
            return;
        };
        depth += 1;
        node = next.value;
    }
}

/// Returns the explicit provider path or `NoProviderConfigured`.
fn providerRequest(init: std.process.Init) ![]const u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--provider")) {
            if (index + 1 >= args.len) return error.NoProviderConfigured;
            return args[index + 1];
        }
    }
    return init.environ_map.get("SIMDJSON_SMOKE_PROVIDER") orelse
        error.NoProviderConfigured;
}
