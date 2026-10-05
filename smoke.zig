// SPDX-License-Identifier: Apache-2.0
// See FORK-LICENSE.md for the grant over this fork's own files.
//
//! The example program: `zig build smoke` runs this.
//!
//! It is deliberately **deterministic**. It reads the fixtures under `testdata/`
//! through the same build-created `simdjson_paths` module `tests.zig` uses, and
//! every number it prints is one it either read from a recorded byte sequence or
//! computed here from what that sequence means. It times nothing, samples
//! nothing, and depends on no environment beyond the arguments it is given. A
//! run on a different machine, in a different optimize mode or against a
//! different kernel prints the same answers, with two named exceptions below.
//!
//! ## What this program is for
//!
//! It is not a benchmark and it does not claim to be one. A speed comparison
//! here would be a claim about the machine that ran it, about which SIMD kernel
//! the build flags selected, and about the input -- and the first two of those
//! are exactly the facts this package says a caller must not pin
//! (`FORK-NOTES.md` note 7). What the example proves instead is that the
//! compiled C++, the translated `zig/bridge.h` and the Zig facade agree: if the
//! C ABI's record layout and the facade's hand-written `Record` disagreed, every
//! answer below would be wrong.
//!
//! ## The two things it prints that are not the same on every machine
//!
//! 1. **Which kernel this artifact was built for**, from `builtinImplementation`.
//!    That is a *preprocessor* answer -- a cascade over
//!    `SIMDJSON_CAN_ALWAYS_RUN_*` at
//!    `src/include/simdjson/implementation_detection.h:148-172` -- decided by the
//!    flags this build used. It is printed, never compared.
//! 2. **Which kernel the run-time dispatcher chose here**, from
//!    `activeImplementation`. That is a function of the host CPU *and* of
//!    `SIMDJSON_FORCE_IMPLEMENTATION`, which upstream uses to latch onto a kernel
//!    that is not compiled in and make every later parse fail with
//!    `UNSUPPORTED_ARCHITECTURE` (`src/src/implementation.cpp:296-312`). It is
//!    printed with that warning attached and never compared either.
//!
//! On-Demand is statically bound to the *builtin* kernel
//! (`src/include/simdjson/builtin/ondemand.h:39`), so the second number is not a
//! statement about which kernel parsed through this bridge. Saying so here is
//! the honest thing; leaving it out would invite a reader to compare the two.
//!
//! ## Exit status
//!
//! Zero only when every check passed. Each check prints what it computed next to
//! what it expected, and a mismatch prints both and exits non-zero, so a failing
//! run is readable without a debugger.

const std = @import("std");
const simdjson = @import("simdjson");

/// The build-created module that names the shared fixture directory.
///
/// The same anonymous import `tests.zig` receives, resolved to an absolute path
/// at configure time. The example reads the same recorded bytes the tests read,
/// so it cannot be showing answers for a document the gates never saw.
const paths = @import("simdjson_paths");

/// Upper bound on a fixture read here, as in `tests.zig`: the largest is
/// `testdata/large/twitter.json` at 631515 bytes.
const fixture_bound: std.Io.Limit = .limited(8 * 1024 * 1024);

/// How many checks have failed so far.
///
/// Counted rather than returned on the first failure: an example that stops at
/// the first problem tells the reader one thing, and this one is cheap enough to
/// tell them all of them in one run.
var failures: usize = 0;

/// Read one fixture, whole.
///
/// `io` is `init.io`, not `std.testing.io`: this is an executable, and the
/// testing instance exists only in a test binary.
fn fixture(io: std.Io, allocator: std.mem.Allocator, relative: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ paths.fixture_dir, relative });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, fixture_bound);
}

/// Records one checked answer.
///
/// `expected` is printed even on success, so a successful run is a transcript of
/// what the package computed rather than a bare "ok" -- which is the whole point
/// of a deterministic example.
fn check(w: *std.Io.Writer, what: []const u8, got: anytype, expected: anytype) !void {
    const ok = got == expected;
    try w.print("{s: <44}{s}\n", .{ what, if (ok) "ok" else "MISMATCH" });
    if (ok) return;
    try w.print("{s: <44}expected {}, computed {}\n", .{ what, expected, got });
    failures += 1;
}

/// Records one checked string answer, with both sides quoted so whitespace and
/// escapes are visible.
fn checkString(w: *std.Io.Writer, what: []const u8, got: []const u8, expected: []const u8) !void {
    const ok = std.mem.eql(u8, got, expected);
    try w.print("{s: <44}{s}\n", .{ what, if (ok) "ok" else "MISMATCH" });
    if (ok) return;
    try w.print("{s: <44}expected \"{s}\", computed \"{s}\"\n", .{ what, expected, got });
    failures += 1;
}

/// A buffer the two-pass string accessors borrow into.
///
/// `version`, `builtinImplementation` and the two implementation accessors all
/// write into a caller-supplied buffer and report a length excluding the NUL
/// (`zig/bridge.h`'s convention), so one buffer sized for the longest of them
/// serves all four.
const string_buffer_size = 256;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    var out_buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    const w = &stdout.interface;

    // A runtime-loading build has no provider until one is named. The option is
    // read from the command line exactly as `consumer/src/main.zig` reads it, so
    // the two programs are configured the same way and the difference between
    // them is what they do rather than how they are told.
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

    // What this build actually is. Printed, never compared: a version string is
    // provenance, and the provenance gate is `tools/check-provenance.sh`.
    var text: [string_buffer_size]u8 = undefined;
    try w.print("{s: <44}{s}\n", .{ "SIMDJSON_VERSION", simdjson.version(&text) catch |err| {
        std.debug.print("simdjson smoke: version(): {s}\n", .{@errorName(err)});
        return err;
    } });

    // Written as plain lines rather than through a format specifier: a literal
    // string is not a format placeholder, and there is nothing to interpolate
    // into it.
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
    // How many kernels this artifact carries at all. At `-Dcpu=baseline` on
    // x86-64 that is one -- the scalar fallback -- and on an aarch64 baseline it
    // is `arm64`; the number is a property of the flags, so it is printed and
    // not asserted.
    try w.print("{s: <44}{d}\n", .{ "availableImplementationCount", simdjson.availableImplementationCount() });

    try runChecks(io, w, allocator);
    try w.flush();

    if (failures == 0) {
        try w.print("\nevery answer matched its expected value\n", .{});
        return;
    }
    // A mismatch is a failed example, not an observation to print and carry on
    // from: the step has to fail, or `zig build smoke` reports success for a
    // program that has just said every one of its checked answers was wrong.
    std.debug.print("\nsimdjson smoke: {d} check(s) did not match\n", .{failures});
    return error.ExpectedValuesDidNotMatch;
}

/// Every checked answer, in one place.
///
/// The order is the order of the fixtures and not an argument for anything: an
/// example reads top to bottom.
fn runChecks(io: std.Io, w: *std.Io.Writer, allocator: std.mem.Allocator) !void {
    // 1. A scalar document, from the RFC's own example. RFC 8259 section 13's
    //    number example is `42`, and the value it denotes is 42.
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

        // The string example, from the same section.
        const string_json = try fixture(io, allocator, "rfc8259/13-value-string.json");
        var string_document = try simdjson.parse(string_json);
        defer string_document.deinit();
        var string_walk = try string_document.walk(allocator);
        defer string_walk.deinit();
        const string_root = string_walk.root() orelse return error.NoRoot;
        try checkString(w, "section 13 string", string_root.string().?, "Hello world!");
    }

    // 2. Number grammar, from the recorded fixture. The fixture's seventeen
    //    literals are read and compared against the values they denote; the
    //    extremes are the IEEE 754 boundary values rather than copies.
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

    // 3. String escapes, from the recorded fixture. The expectations are RFC
    //    8259 section 7's table and section 3's UTF-8 encoding.
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

    // 4. Refusals, with the upstream error each one carries. A malformed
    //    document that produced *some* error would pass a weaker example; the
    //    classification is what a caller branches on.
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

        // The two refusals that are not in a fixture, because a literal states
        // the boundary more clearly than a file does.
        // `{"a":01}` violates RFC 8259 section 6's `int` production.
        try reportLiteralRefusal(w, "{\"a\":01}", simdjson.Error.UpstreamNumber);
        // `1e400` is a legal document that binary64 cannot hold: upstream refuses
        // it as a number error rather than reading it as infinity or clamping it
        // (`src/include/simdjson/generic/numberparsing.h:819-839`, `:26`).
        try reportLiteralRefusal(w, "1e400", simdjson.Error.UpstreamNumber);
    }

    // 5. Nesting, from the two small recorded fixtures.
    {
        try w.writeAll("\nnesting\n");
        try reportLeaf(io, w, allocator, "values/nesting-32.json", 32);
        try reportLeaf(io, w, allocator, "values/nesting-64.json", 64);
    }

    // 6. Duplicate keys, from the recorded fixture. `get` finds the first; both
    //    values are still in the walk and readable by position.
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

    // 7. A large document, from upstream's own example file. The count is
    //    derived from the walk rather than pinned, so this cannot become a
    //    version test; what is shown is that a 631515-byte document walks.
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
        // The two top-level keys upstream's example is built around. `query` is a
        // member of `search_metadata`, not a key of the document.
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

    // 8. Ownership, because a leaking example is worse than a failing one.
    {
        try w.writeAll("\nownership\n");
        var document = try simdjson.parse("{\"a\":[1,2,3]}");
        defer document.deinit();
        var walk = try document.walk(allocator);
        // One record per value: the object, the array that is `a`'s value, and its
        // three elements.
        try check(w, "records before deinit", @as(usize, walk.count()), @as(usize, 5));
        walk.deinit();
        try check(w, "records after deinit", @as(usize, walk.count()), @as(usize, 0));
        try check(w, "root after deinit is null", walk.root() == null, true);
    }
}

/// Reads one malformed fixture and reports the error it produced.
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

/// Reads one literal and reports the error it produced.
fn reportLiteralRefusal(w: *std.Io.Writer, json: []const u8, expected: simdjson.Error) !void {
    try report(w, json, json, expected);
}

/// Reports one refusal and what the facade said about it.
///
/// The answer comes from reading the document, not from `parse` alone: `parse` is
/// upstream's stage 1, which indexes structure and does not parse values, so it
/// answers `SUCCESS` for `{"a":1,}`, `{"a":01}` and `1e400` -- and `zig/root.zig`
/// says so. `Document.walk` is the call that reads the whole document, so that is
/// what this asks.
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

/// Walks one nesting fixture to its leaf and reports the depth it reached.
///
/// The leaf's own depth is compared against the fixture's stated level count, so
/// a walk that recorded depths off by one would be visible here as well as in
/// `tests.zig`.
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
            // The "levels" objects carrying an `a` key occupy depths 0 through
            // levels - 1, the object that holds `leaf` is one level deeper, and
            // the leaf's own value is one deeper again -- so a record per value
            // leaves the stream two records longer than the level count.
            try check(w, try std.fmt.bufPrint(&label_buffer, "{s}: leaf depth", .{relative}), walk.nodes[leaf.value.index].depth, levels + 1);
            try check(w, try std.fmt.bufPrint(&label_buffer, "{s}: records", .{relative}), @as(usize, walk.count()), @as(usize, levels + 2));
            return;
        };
        depth += 1;
        node = next.value;
    }
}

/// The provider a runtime-loading run was told to load.
///
/// `--provider <path>` first, then `SIMDJSON_SMOKE_PROVIDER`. Both are explicit:
/// nothing looks in a default location, and a build that was not told which file
/// to load says so rather than loading something else.
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