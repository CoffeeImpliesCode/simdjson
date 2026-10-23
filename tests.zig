// SPDX-License-Identifier: Apache-2.0
// See FORK-LICENSE.md for the grant over this fork's own files.
//! Behavioral tests for the simdjson facade.

const std = @import("std");
const testing = std.testing;
const simdjson = @import("simdjson");

/// Build-provided directory of test fixtures.
const paths = @import("simdjson_paths");

const fixture_bound: std.Io.Limit = .limited(8 * 1024 * 1024);

/// Reads one fixture from the build-provided directory.
fn fixture(relative: []const u8) ![]u8 {
    const path = try std.fs.path.join(testing.allocator, &.{ paths.fixture_dir, relative });
    defer testing.allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, fixture_bound);
}

/// Parses and walks the input, then deinitializes both resources.
fn withWalk(json: []const u8, comptime body: fn (simdjson.Walk) anyerror!void) !void {
    var document = try simdjson.parse(json);
    defer document.deinit();
    var walk = try document.walk(testing.allocator);
    defer walk.deinit();
    try body(walk);
}

/// Runs a walk check with case-specific context.
fn withWalkCase(
    context: anytype,
    json: []const u8,
    comptime body: fn (@TypeOf(context), simdjson.Walk) anyerror!void,
) !void {
    var document = try simdjson.parse(json);
    defer document.deinit();
    var walk = try document.walk(testing.allocator);
    defer walk.deinit();
    try body(context, walk);
}

/// Expects a walk to return the specified parser error.
fn expectRefused(json: []const u8, expected: simdjson.Error, what: []const u8) !void {
    const got: ?simdjson.Error = if (simdjson.parse(json)) |document| blk: {
        var owned = document;
        defer owned.deinit();
        break :blk if (owned.walk(testing.allocator)) |walk| read: {
            var filled = walk;
            defer filled.deinit();
            break :read null;
        } else |err| err;
    } else |err| err;
    if (std.meta.eql(got, expected)) return;
    std.debug.print(
        "tests: {s}: expected {s}, the facade reported {s}\n",
        .{ what, @errorName(expected), if (got) |e| @errorName(e) else "success" },
    );
    return error.RefusalWasNotTheExpectedOne;
}

/// Compares bridge statuses as translated C integers.
fn expectStatus(expected: c_uint, actual: c_uint) !void {
    return testing.expectEqual(expected, actual);
}

test "rfc8259 section 13 number: 42 is a signed integer, not a double" {
    const json = try fixture("rfc8259/13-value-number.json");
    defer testing.allocator.free(json);

    try withWalk(json, struct {
        fn check(walk: simdjson.Walk) !void {
            const root = walk.root() orelse return error.NoRoot;
            try testing.expectEqual(simdjson.ValueType.number, root.valueType());
            // Expected values follow RFC 8259, not parser output.
            try testing.expectEqual(simdjson.NumberType.signed, root.numberType());
            try testing.expectEqual(@as(i64, 42), root.int().?);
            try testing.expectEqual(@as(?f64, null), root.double());
            try testing.expectEqual(@as(?u64, null), root.uint());
            try testing.expectEqual(@as(?bool, null), root.boolean());
            try testing.expectEqual(@as(?[]const u8, null), root.string());
            try testing.expectEqual(@as(?simdjson.Array, null), root.array());
            try testing.expectEqual(@as(?simdjson.Object, null), root.object());
        }
    }.check);
}

test "rfc8259 section 13 boolean: true is a boolean and not a string" {
    const json = try fixture("rfc8259/13-value-boolean.json");
    defer testing.allocator.free(json);

    try withWalk(json, struct {
        fn check(walk: simdjson.Walk) !void {
            const root = walk.root() orelse return error.NoRoot;
            try testing.expectEqual(simdjson.ValueType.boolean, root.valueType());
            try testing.expectEqual(true, root.boolean().?);
            try testing.expectEqual(@as(?bool, null), root.isNull());
            try testing.expectEqual(simdjson.NumberType.none, root.numberType());
        }
    }.check);
}

test "rfc8259 section 13 string: the RFC's own text, unescaped and not NUL-terminated" {
    const json = try fixture("rfc8259/13-value-string.json");
    defer testing.allocator.free(json);

    try withWalk(json, struct {
        fn check(walk: simdjson.Walk) !void {
            const root = walk.root() orelse return error.NoRoot;
            try testing.expectEqual(simdjson.ValueType.string, root.valueType());
            try testing.expectEqualStrings("Hello world!", root.string().?);
            try testing.expectEqual(@as(usize, 12), root.string().?.len);
        }
    }.check);
}

test "rfc8259 section 13 array: two objects with the same eight keys and different values" {
    const json = try fixture("rfc8259/13-array.json");
    defer testing.allocator.free(json);

    try withWalk(json, struct {
        fn check(walk: simdjson.Walk) !void {
            const root = walk.root() orelse return error.NoRoot;
            try testing.expectEqual(simdjson.ValueType.array, root.valueType());
            const items = root.array() orelse return error.NotAnArray;
            try testing.expectEqual(@as(usize, 2), items.len());

            const latitudes = [_]f64{ 37.7668, 37.371991 };
            const longitudes = [_]f64{ -122.3959, -122.026020 };
            const zips = [_][]const u8{ "94107", "94085" };

            var seen: usize = 0;
            var iterator = items.iterator();
            while (iterator.next()) |element| : (seen += 1) {
                try testing.expectEqual(simdjson.ValueType.object, element.valueType());
                const object = element.object() orelse return error.NotAnObject;
                try testing.expectEqual(@as(usize, 8), object.len());

                const precision = object.get("precision") orelse return error.MissingKey;
                try testing.expectEqualStrings("zip", precision.value.string().?);
                const address = object.get("Address") orelse return error.MissingKey;
                try testing.expectEqualStrings("", address.value.string().?);
                try testing.expectEqual(simdjson.ValueType.string, address.value.valueType());
                const country = object.get("Country") orelse return error.MissingKey;
                try testing.expectEqualStrings("US", country.value.string().?);
                const state = object.get("State") orelse return error.MissingKey;
                try testing.expectEqualStrings("CA", state.value.string().?);
                const city = object.get("City") orelse return error.MissingKey;
                try testing.expect(city.value.string().?.len > 0);

                // RFC decimal spellings provide the expected floating-point values.
                const latitude = (object.get("Latitude") orelse return error.MissingKey).value;
                try testing.expectEqual(simdjson.NumberType.floating_point, latitude.numberType());
                try testing.expectEqual(latitudes[seen], latitude.double().?);
                try testing.expectEqual(longitudes[seen], (object.get("Longitude") orelse return error.MissingKey).value.double().?);
                try testing.expectEqualStrings(zips[seen], (object.get("Zip") orelse return error.MissingKey).value.string().?);
            }
            try testing.expectEqual(@as(usize, 2), seen);
        }
    }.check);
}

test "rfc8259 section 13 object: nested Thumbnail, an integer array, and a false" {
    const json = try fixture("rfc8259/13-object.json");
    defer testing.allocator.free(json);

    try withWalk(json, struct {
        fn check(walk: simdjson.Walk) !void {
            const root = walk.root() orelse return error.NoRoot;
            const object = root.object() orelse return error.NotAnObject;
            try testing.expectEqual(@as(usize, 1), object.len());
            const image = object.at(0) orelse return error.NoField;
            try testing.expectEqualStrings("Image", image.key);
            try testing.expectEqual(@as(?simdjson.Field, null), object.at(1));

            try testing.expectEqual(simdjson.ValueType.object, image.value.valueType());
            const image_object = image.value.object() orelse return error.NotAnObject;
            try testing.expectEqual(@as(usize, 6), image_object.len());
            try testing.expectEqual(@as(i64, 800), (image_object.get("Width") orelse return error.MissingKey).value.int().?);
            try testing.expectEqual(@as(i64, 600), (image_object.get("Height") orelse return error.MissingKey).value.int().?);
            try testing.expectEqualStrings(
                "View from 15th Floor",
                (image_object.get("Title") orelse return error.MissingKey).value.string().?,
            );
            const animated = (image_object.get("Animated") orelse return error.MissingKey).value;
            try testing.expectEqual(false, animated.boolean().?);
            try testing.expectEqual(@as(?bool, null), animated.isNull());

            const thumbnail = (image_object.get("Thumbnail") orelse return error.MissingKey).value;
            try testing.expectEqual(@as(u32, 2), walk.nodes[thumbnail.index].depth);
            const thumbnail_object = thumbnail.object() orelse return error.NotAnObject;
            try testing.expectEqual(@as(usize, 3), thumbnail_object.len());
            try testing.expectEqualStrings(
                "http://www.example.com/image/481989943",
                (thumbnail_object.get("Url") orelse return error.MissingKey).value.string().?,
            );
            try testing.expectEqual(@as(i64, 125), (thumbnail_object.get("Height") orelse return error.MissingKey).value.int().?);
            try testing.expectEqual(@as(i64, 100), (thumbnail_object.get("Width") orelse return error.MissingKey).value.int().?);

            const ids = (image_object.get("IDs") orelse return error.MissingKey).value.array() orelse
                return error.NotAnArray;
            const expected_ids = [_]i64{ 116, 943, 234, 38793 };
            try testing.expectEqual(expected_ids.len, ids.len());
            for (expected_ids, 0..) |want, n| {
                const element = ids.get(n) orelse return error.NoElement;
                try testing.expectEqual(want, element.int().?);
            }
            try testing.expectEqual(@as(?simdjson.Value, null), ids.get(expected_ids.len));
        }
    }.check);
}

test "number grammar: every literal in the fixture, classified the way upstream classifies it" {
    const json = try fixture("values/number-grammar.json");
    defer testing.allocator.free(json);

    try withWalk(json, struct {
        fn check(walk: simdjson.Walk) !void {
            const root = walk.root() orelse return error.NoRoot;
            const items = root.array() orelse return error.NotAnArray;

            // RFC 8259 accepts `-0`, but its integer value is zero.
            const signed_values = [_]i64{ 0, 0, 1, -1, 42 };
            const floating = [_]f64{
                3.5,
                -3.5,
                1.5e10,
                -1.5e10,
                1e22,
                1e-2,
                1.5e-300,
                1e-27, // "0.000000000000000000000000001"
                1.23e67, // "123e65"
                2.2250738585072011e-308,
                std.math.floatMax(f64),
                -std.math.floatMax(f64),
            };

            try testing.expectEqual(signed_values.len + floating.len, items.len());

            var n: usize = 0;
            while (n < signed_values.len) : (n += 1) {
                const element = items.get(n) orelse return error.NoElement;
                try testing.expectEqual(simdjson.NumberType.signed, element.numberType());
                try testing.expectEqual(signed_values[n], element.int().?);
                try testing.expectEqual(@as(?f64, null), element.double());
                try testing.expectEqual(@as(?u64, null), element.uint());
            }

            for (floating, 0..) |want, k| {
                const element = items.get(signed_values.len + k) orelse return error.NoElement;
                try testing.expectEqual(simdjson.NumberType.floating_point, element.numberType());
                try testing.expectEqual(want, element.double().?);
                try testing.expectEqual(@as(?i64, null), element.int());
            }

            const tiny = items.get(signed_values.len + 7) orelse return error.NoElement;
            try testing.expect(tiny.double().? > 0.0);
            const deep = items.get(signed_values.len + 6) orelse return error.NoElement;
            try testing.expect(deep.double().? > 1e-301);
            try testing.expect(deep.double().? < 1e-299);
        }
    }.check);
}

test "a positive integer above u64 max is big_integer, and its text is the answer" {
    try withWalk("{\"n\":18446744073709551616}", struct {
        fn check(walk: simdjson.Walk) !void {
            const root = walk.root() orelse return error.NoRoot;
            const object = root.object() orelse return error.NotAnObject;
            const value = (object.get("n") orelse return error.MissingKey).value;

            try testing.expectEqual(simdjson.NumberType.big, value.numberType());
            try testing.expectEqualStrings("18446744073709551616", value.bigIntegerText().?);

            try testing.expectEqual(@as(?i64, null), value.int());
            try testing.expectEqual(@as(?u64, null), value.uint());
            try testing.expectEqual(@as(?f64, null), value.double());
        }
    }.check);
}

test "u64 max is unsigned, and one past it is big: the boundary is exact" {
    // Adjacent values straddle the `u64` maximum.
    try withWalk("[18446744073709551615,18446744073709551616]", struct {
        fn check(walk: simdjson.Walk) !void {
            const items = (walk.root() orelse return error.NoRoot).array() orelse
                return error.NotAnArray;
            try testing.expectEqual(@as(usize, 2), items.len());

            const max = items.get(0) orelse return error.NoElement;
            try testing.expectEqual(simdjson.NumberType.unsigned, max.numberType());
            try testing.expectEqual(std.math.maxInt(u64), max.uint().?);
            try testing.expectEqual(@as(?i64, null), max.int());

            const past = items.get(1) orelse return error.NoElement;
            try testing.expectEqual(simdjson.NumberType.big, past.numberType());
            try testing.expectEqual(@as(?u64, null), past.uint());
            try testing.expectEqualStrings("18446744073709551616", past.bigIntegerText().?);
        }
    }.check);
}

test "string escapes: every RFC 8259 section 7 escape, unescaped to what the RFC says" {
    const json = try fixture("values/string-escapes.json");
    defer testing.allocator.free(json);

    try withWalk(json, struct {
        fn check(walk: simdjson.Walk) !void {
            const items = (walk.root() orelse return error.NoRoot).array() orelse
                return error.NotAnArray;
            try testing.expectEqual(@as(usize, 15), items.len());

            // Expected strings follow RFC 8259's escape table.
            try testing.expectEqualStrings("\"", (items.get(0) orelse return error.NoElement).string().?);
            try testing.expectEqualStrings("\\", (items.get(1) orelse return error.NoElement).string().?);
            try testing.expectEqualStrings("/", (items.get(2) orelse return error.NoElement).string().?);
            try testing.expectEqualStrings("\x08", (items.get(3) orelse return error.NoElement).string().?);
            try testing.expectEqualStrings("\x0C", (items.get(4) orelse return error.NoElement).string().?);
            try testing.expectEqualStrings("\n", (items.get(5) orelse return error.NoElement).string().?);
            try testing.expectEqualStrings("\r", (items.get(6) orelse return error.NoElement).string().?);
            try testing.expectEqualStrings("\t", (items.get(7) orelse return error.NoElement).string().?);

            // Unicode escapes decode to UTF-8.
            try testing.expectEqualStrings("A", (items.get(8) orelse return error.NoElement).string().?);
            try testing.expectEqualStrings("\u{00E9}", (items.get(9) orelse return error.NoElement).string().?);
            // The surrogate pair becomes one four-byte UTF-8 code point.
            try testing.expectEqualStrings("\u{4E2D}\u{6587}", (items.get(10) orelse return error.NoElement).string().?);
            try testing.expectEqualStrings("\u{1D11E}", (items.get(11) orelse return error.NoElement).string().?);
            try testing.expectEqualStrings("\u{1F600}", (items.get(12) orelse return error.NoElement).string().?);
            try testing.expectEqualStrings("\u{00FC}ber", (items.get(13) orelse return error.NoElement).string().?);
            try testing.expectEqualStrings("A", (items.get(14) orelse return error.NoElement).string().?);

            const expected_lengths = [_]usize{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 6, 4, 4, 5, 1 };
            for (expected_lengths, 0..) |want, n| {
                const element = items.get(n) orelse return error.NoElement;
                try testing.expectEqual(want, element.string().?.len);
            }
        }
    }.check);
}

test "an empty string is present, and a zero-length key is a key" {
    // Empty strings and keys are distinct from absent values.
    try withWalk("{\"\":\"\",\"a\":\"\"}", struct {
        fn check(walk: simdjson.Walk) !void {
            const root = walk.root() orelse return error.NoRoot;
            const object = root.object() orelse return error.NotAnObject;
            try testing.expectEqual(@as(usize, 2), object.len());

            const empty_key = object.get("") orelse return error.MissingKey;
            try testing.expectEqualStrings("", empty_key.key);
            try testing.expectEqualStrings("", empty_key.value.string().?);
            try testing.expect(empty_key.value.string() != null);
            try testing.expectEqual(simdjson.ValueType.string, empty_key.value.valueType());

            const named = object.get("a") orelse return error.MissingKey;
            try testing.expectEqualStrings("a", named.key);
            try testing.expectEqualStrings("", named.value.string().?);
            try testing.expect(named.key.len != empty_key.key.len);
        }
    }.check);
}

test "malformed inputs are refused, each with the error upstream's own classification produces" {
    const cases = [_]struct { name: []const u8, expected: simdjson.Error }{
        .{ .name = "01-trailing-comma-object.json", .expected = simdjson.Error.UpstreamTape },
        .{ .name = "02-single-quoted-string.json", .expected = simdjson.Error.UpstreamTape },
        .{ .name = "03-unquoted-key.json", .expected = simdjson.Error.UpstreamTape },
        .{ .name = "04-nan-literal.json", .expected = simdjson.Error.UpstreamTape },
        .{ .name = "05-leading-plus-number.json", .expected = simdjson.Error.UpstreamTape },
        .{ .name = "07-missing-colon.json", .expected = simdjson.Error.UpstreamTape },
        .{ .name = "08-unterminated-string.json", .expected = simdjson.Error.UpstreamUnclosedString },
        .{ .name = "09-empty-input.json", .expected = simdjson.Error.UpstreamEmpty },
    };

    for (cases) |case| {
        var path_buffer: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "malformed/{s}", .{case.name});
        const json = try fixture(path);
        defer testing.allocator.free(json);
        try expectRefused(json, case.expected, case.name);
    }
}

test "a leading zero is refused rather than read as 0" {
    // RFC 8259 forbids a digit after a leading zero.
    const json = try fixture("values/leading-zero.json");
    defer testing.allocator.free(json);

    try expectRefused(json, simdjson.Error.UpstreamNumber, "values/leading-zero.json");
}

test "an unescaped control character inside a string is refused" {
    // An unescaped control character is a grammar error, not invalid UTF-8.
    const json = try fixture("values/unescaped-control-character.json");
    defer testing.allocator.free(json);

    try testing.expectEqual(@as(usize, 11), json.len);
    try testing.expectEqual(@as(u8, 0x01), json[7]);
    try testing.expect(try simdjson.validateUtf8(json));

    try expectRefused(json, simdjson.Error.UpstreamUnescapedChars, "values/unescaped-control-character.json");
}

test "invalid UTF-8 is refused by the validator, and the validator agrees with parse" {
    // Invalid UTF-8 samples must fail validation and parsing.
    const invalid = [_][]const u8{
        "\x80",
        "\xC0\x80",
        "\xE0\x80\x80",
        "\xF5\x80\x80\x80",
        "{\"a\":\"\xFF\"}",
    };
    for (invalid) |bytes| {
        try testing.expect(!try simdjson.validateUtf8(bytes));
        try expectRefused(bytes, simdjson.Error.UpstreamUtf8, "invalid UTF-8");
    }

    const valid = [_][]const u8{
        "",
        "plain ASCII",
        "\u{00E9}",
        "\u{4E2D}\u{6587}",
        "\u{1D11E}",
        "\u{10FFFF}",
    };
    for (valid) |bytes| try testing.expect(try simdjson.validateUtf8(bytes));
}

test "validateUtf8 answers about the bytes alone, not about how they parse" {
    // UTF-8 validity is independent of JSON syntax.
    try testing.expect(try simdjson.validateUtf8("{\"a\":1}"));
    try testing.expect(try simdjson.validateUtf8("{\"a\":01}"));
    try testing.expect(!try simdjson.validateUtf8("{\"a\":\"\xFF\"}"));

    // An empty byte range is valid UTF-8, but an empty document is not.
    try testing.expect(try simdjson.validateUtf8(""));
    try expectRefused("", simdjson.Error.UpstreamEmpty, "empty document");
}

test "trailing content after a complete value is refused" {
    // RFC 8259 permits trailing whitespace, but not a second value.
    try expectRefused("1 2", simdjson.Error.UpstreamTrailingContent, "1 2");
    try expectRefused("{} {}", simdjson.Error.UpstreamTrailingContent, "{} {}");
    try expectRefused("[1][2]", simdjson.Error.UpstreamTrailingContent, "[1][2]");
    var document = try simdjson.parse("1\n");
    defer document.deinit();
    var walk = try document.walk(testing.allocator);
    defer walk.deinit();
    try testing.expectEqual(@as(i64, 1), (walk.root() orelse return error.NoRoot).int().?);
}

test "an incomplete container is refused, not partially read" {
    try expectRefused("[1,2", simdjson.Error.UpstreamIncompleteArrayOrObject, "[1,2");
    try expectRefused("{\"a\":1", simdjson.Error.UpstreamIncompleteArrayOrObject, "{\"a\":1");
    try expectRefused("[", simdjson.Error.UpstreamIncompleteArrayOrObject, "[");
    try withWalk("[]", struct {
        fn check(walk: simdjson.Walk) !void {
            const root = walk.root() orelse return error.NoRoot;
            try testing.expectEqual(simdjson.ValueType.array, root.valueType());
            try testing.expectEqual(@as(usize, 0), root.array().?.len());
            try testing.expectEqual(@as(usize, 1), walk.count());
        }
    }.check);
}

test "an oversized number is refused rather than clamped" {
    // The parser rejects an exponent that exceeds finite binary64 range.
    try expectRefused("1e400", simdjson.Error.UpstreamNumber, "1e400");
    try expectRefused("-1e400", simdjson.Error.UpstreamNumber, "-1e400");
    try withWalk("1e308", struct {
        fn check(walk: simdjson.Walk) !void {
            try testing.expectEqual(@as(f64, 1e308), (walk.root() orelse return error.NoRoot).double().?);
        }
    }.check);
    try withWalk("1.7976931348623157e308", struct {
        fn check(walk: simdjson.Walk) !void {
            try testing.expectEqual(std.math.floatMax(f64), (walk.root() orelse return error.NoRoot).double().?);
        }
    }.check);
}

test "nesting-32 and nesting-64: depth is recorded, and both walk to the leaf" {
    const Case = struct { name: []const u8, levels: u32 };
    const cases = [_]Case{
        .{ .name = "values/nesting-32.json", .levels = 32 },
        .{ .name = "values/nesting-64.json", .levels = 64 },
    };

    for (cases) |nesting_case| {
        const json = try fixture(nesting_case.name);
        defer testing.allocator.free(json);

        try withWalkCase(nesting_case, json, struct {
            fn check(fixture_case: Case, walk: simdjson.Walk) !void {
                var node = walk.root() orelse return error.NoRoot;
                var depth: u32 = 0;
                while (true) {
                    try testing.expectEqual(simdjson.ValueType.object, node.valueType());
                    try testing.expectEqual(depth, walk.nodes[node.index].depth);
                    const object = node.object() orelse return error.NotAnObject;
                    const next = object.get("a") orelse {
                        const leaf = object.get("leaf") orelse return error.NoLeaf;
                        try testing.expectEqual(@as(i64, 1), leaf.value.int().?);
                        try testing.expectEqual(
                            fixture_case.levels + 1,
                            walk.nodes[leaf.value.index].depth,
                        );
                        try testing.expectEqual(
                            @as(usize, fixture_case.levels + 2),
                            walk.count(),
                        );
                        return;
                    };
                    depth += 1;
                    node = next.value;
                }
            }
        }.check);
    }
}

test "the pre-order record stream is consistent with every record's own count" {
    // The expected records follow the document's pre-order layout.
    try withWalk("{\"a\":[1,{\"b\":[true,null]}],\"c\":\"end\",\"d\":{\"e\":{\"f\":1}}}", struct {
        fn check(walk: simdjson.Walk) !void {
            const root = walk.root() orelse return error.NoRoot;
            try testing.expectEqual(simdjson.ValueType.object, root.valueType());

            const expected = [_]struct {
                depth: u32,
                type: simdjson.ValueType,
                count: u32,
            }{
                .{ .depth = 0, .type = .object, .count = 3 },
                .{ .depth = 1, .type = .array, .count = 2 },
                .{ .depth = 2, .type = .number, .count = 0 },
                .{ .depth = 2, .type = .object, .count = 1 },
                .{ .depth = 3, .type = .array, .count = 2 },
                .{ .depth = 4, .type = .boolean, .count = 0 },
                .{ .depth = 4, .type = .null, .count = 0 },
                .{ .depth = 1, .type = .string, .count = 0 },
                .{ .depth = 1, .type = .object, .count = 1 },
                .{ .depth = 2, .type = .object, .count = 1 },
                .{ .depth = 3, .type = .number, .count = 0 },
            };
            try testing.expectEqual(expected.len, walk.count());

            for (expected, 0..) |want, n| {
                const record = walk.nodes[n];
                try testing.expectEqual(want.depth, record.depth);
                try testing.expectEqual(want.type, record.valueType());
                try testing.expectEqual(want.count, record.count);
            }

            for (walk.nodes, 0..) |record, n| {
                if (record.count == 0) continue;
                var seen: u32 = 0;
                var probe = n + 1;
                while (probe < walk.nodes.len and walk.nodes[probe].depth > record.depth) : (probe += 1) {
                    if (walk.nodes[probe].depth == record.depth + 1) seen += 1;
                }
                try testing.expectEqual(record.count, seen);
            }
        }
    }.check);
}

test "the depth limit this package sets on purpose" {
    // The bridge checks the package's depth limit in every optimization mode.
    // Upstream's assertion would abort instead of returning an error.
    const json = try fixture("values/nesting-2048.json");
    defer testing.allocator.free(json);

    var levels: usize = 0;
    for (json) |byte| {
        if (byte == '{') levels += 1;
    }
    try testing.expectEqual(@as(usize, 2049), levels);
    try testing.expect(levels > 1024);

    try expectRefused(json, simdjson.Error.UpstreamDepth, "values/nesting-2048.json");

    const within = try fixture("values/nesting-64.json");
    defer testing.allocator.free(within);
    var document = try simdjson.parse(within);
    defer document.deinit();
    var walk = try document.walk(testing.allocator);
    defer walk.deinit();
    try testing.expect(walk.count() > 0);
}

test "duplicate keys: all three values are in the walk, and get answers the first" {
    // Duplicate keys remain in the walk, and name lookup returns the first.
    const json = try fixture("values/duplicate-keys.json");
    defer testing.allocator.free(json);

    try withWalk(json, struct {
        fn check(walk: simdjson.Walk) !void {
            const object = (walk.root() orelse return error.NoRoot).object() orelse
                return error.NotAnObject;

            try testing.expectEqual(@as(usize, 3), object.len());
            try testing.expectEqual(@as(i64, 1), (object.get("a") orelse return error.MissingKey).value.int().?);
            try testing.expectEqual(@as(i64, 2), (object.get("b") orelse return error.MissingKey).value.int().?);

            const first_a = object.at(0) orelse return error.NoField;
            const b = object.at(1) orelse return error.NoField;
            const second_a = object.at(2) orelse return error.NoField;
            try testing.expectEqualStrings("a", first_a.key);
            try testing.expectEqualStrings("b", b.key);
            try testing.expectEqualStrings("a", second_a.key);
            try testing.expectEqual(@as(i64, 1), first_a.value.int().?);
            try testing.expectEqual(@as(i64, 2), b.value.int().?);
            try testing.expectEqual(@as(i64, 3), second_a.value.int().?);

            try testing.expectEqual(@as(usize, 4), walk.count());
        }
    }.check);
}

test "object accessors: absent keys, out-of-range positions, and re-readable iteration" {
    try withWalk("{\"a\":1,\"b\":2,\"c\":3}", struct {
        fn check(walk: simdjson.Walk) !void {
            const object = (walk.root() orelse return error.NoRoot).object() orelse
                return error.NotAnObject;

            // A missing key differs from a present JSON null.
            try testing.expect(object.get("missing") == null);
            try testing.expect(object.get("") == null);

            try testing.expect(object.at(2) != null);
            try testing.expect(object.at(3) == null);
            try testing.expect(object.at(100) == null);

            var iterator = object.iterator();
            try testing.expectEqual(@as(usize, 3), iterator.remaining());
            _ = iterator.next().?;
            try testing.expectEqual(@as(usize, 2), iterator.remaining());
            _ = iterator.next().?;
            _ = iterator.next().?;
            try testing.expectEqual(@as(usize, 0), iterator.remaining());
            try testing.expectEqual(@as(?simdjson.Field, null), iterator.next());
            try testing.expectEqual(@as(usize, 0), iterator.remaining());

            var again = object.reset();
            var keys_seen: usize = 0;
            while (again.next()) |field| : (keys_seen += 1) {
                try testing.expectEqual(@as(usize, 1), field.key.len);
            }
            try testing.expectEqual(@as(usize, 3), keys_seen);
        }
    }.check);
}

test "two arrays from one walk iterate independently and interleaved" {
    // A copied walk supports independent iterators over different arrays.
    try withWalk("{\"x\":[1,2,3],\"y\":[9,8]}", struct {
        fn check(walk: simdjson.Walk) !void {
            const object = (walk.root() orelse return error.NoRoot).object() orelse
                return error.NotAnObject;
            const xs = (object.get("x") orelse return error.MissingKey).value.array() orelse
                return error.NotAnArray;
            const ys = (object.get("y") orelse return error.MissingKey).value.array() orelse
                return error.NotAnArray;

            var x_iter = xs.iterator();
            var y_iter = ys.iterator();
            var total: i64 = 0;
            var from_x: usize = 0;
            if (x_iter.next()) |element| {
                total += element.int().?;
                from_x += 1;
            }
            while (y_iter.next()) |element| total += element.int().?;
            while (x_iter.next()) |element| {
                total += element.int().?;
                from_x += 1;
            }
            try testing.expectEqual(@as(usize, 3), from_x);
            try testing.expectEqual(@as(i64, 1 + 2 + 3 + 9 + 8), total);
            try testing.expectEqual(@as(usize, 0), x_iter.remaining());
            try testing.expectEqual(@as(usize, 0), y_iter.remaining());
        }
    }.check);
}

test "accessors refuse to convert: each numeric accessor answers only its own type" {
    // Numeric accessors return null instead of converting number types.
    try withWalk("[1,-1,1.5,\"s\",true,null,[],{}]", struct {
        fn check(walk: simdjson.Walk) !void {
            const items = (walk.root() orelse return error.NoRoot).array() orelse
                return error.NotAnArray;
            try testing.expectEqual(@as(usize, 8), items.len());

            for ([_]usize{ 0, 1 }) |n| {
                const element = items.get(n) orelse return error.NoElement;
                try testing.expectEqual(simdjson.NumberType.signed, element.numberType());
                try testing.expect(element.int() != null);
                try testing.expectEqual(@as(?u64, null), element.uint());
                try testing.expectEqual(@as(?f64, null), element.double());
                try testing.expectEqual(@as(?[]const u8, null), element.string());
                try testing.expectEqual(@as(?bool, null), element.boolean());
                try testing.expectEqual(@as(?bool, null), element.isNull());
                try testing.expectEqual(@as(?[]const u8, null), element.bigIntegerText());
                try testing.expectEqual(@as(?simdjson.Array, null), element.array());
                try testing.expectEqual(@as(?simdjson.Object, null), element.object());
            }
            try testing.expectEqual(@as(i64, 1), items.get(0).?.int().?);
            try testing.expectEqual(@as(i64, -1), items.get(1).?.int().?);

            const real = items.get(2) orelse return error.NoElement;
            try testing.expectEqual(simdjson.NumberType.floating_point, real.numberType());
            try testing.expectEqual(@as(f64, 1.5), real.double().?);
            try testing.expectEqual(@as(?i64, null), real.int());

            for ([_]usize{ 3, 4, 5, 6, 7 }) |n| {
                try testing.expectEqual(simdjson.NumberType.none, items.get(n).?.numberType());
            }

            try testing.expectEqual(simdjson.ValueType.array, items.get(6).?.valueType());
            try testing.expectEqual(simdjson.ValueType.object, items.get(7).?.valueType());
            try testing.expectEqual(@as(usize, 0), items.get(3).?.count());
            try testing.expectEqual(@as(usize, 0), items.get(4).?.count());
        }
    }.check);
}

test "null is a value, and it is not the same answer as absent" {
    try withWalk("{\"present\":null,\"sibling\":1}", struct {
        fn check(walk: simdjson.Walk) !void {
            const object = (walk.root() orelse return error.NoRoot).object() orelse
                return error.NotAnObject;

            const present = object.get("present") orelse return error.MissingKey;
            try testing.expectEqual(simdjson.ValueType.null, present.value.valueType());
            try testing.expectEqual(true, present.value.isNull().?);
            try testing.expectEqual(@as(?bool, null), present.value.boolean());
            try testing.expectEqual(@as(?[]const u8, null), present.value.string());
            try testing.expectEqual(simdjson.NumberType.none, present.value.numberType());

            // A missing field differs from a present JSON null.
            try testing.expect(object.get("absent") == null);
            const sibling = object.get("sibling") orelse return error.MissingKey;
            try testing.expectEqual(@as(?bool, null), sibling.value.isNull());
            try testing.expectEqual(@as(i64, 1), sibling.value.int().?);
        }
    }.check);
}

test "a refused parse constructs nothing, and a later document is unaffected" {
    // A failed parse leaves an existing document unchanged.
    var kept = try simdjson.parse("{\"first\":1}");
    defer kept.deinit();

    try expectRefused("{\"a\":1,}", simdjson.Error.UpstreamTape, "before");
    try expectRefused("", simdjson.Error.UpstreamEmpty, "empty");

    var walk = try kept.walk(testing.allocator);
    defer walk.deinit();
    const object = (walk.root() orelse return error.NoRoot).object() orelse
        return error.NotAnObject;
    try testing.expectEqual(
        @as(i64, 1),
        (object.get("first") orelse return error.MissingKey).value.int().?,
    );
    try testing.expectEqual(@as(usize, 1), object.len());
}

test "the input slice is borrowed only for the parse call" {
    // The bridge copies input before parse returns.
    const source = try testing.allocator.dupe(u8, "{\"value\":1}");

    var document = try simdjson.parse(source);
    defer document.deinit();

    @memset(source, 'x');

    var walk = try document.walk(testing.allocator);
    defer walk.deinit();
    const object = (walk.root() orelse return error.NoRoot).object() orelse
        return error.NotAnObject;
    try testing.expectEqual(
        @as(i64, 1),
        (object.get("value") orelse return error.MissingKey).value.int().?,
    );
    testing.allocator.free(source);
}

test "Document.walk may be called more than once, and each call sees the same document" {
    // Each walk rewinds the upstream document.
    var document = try simdjson.parse("{\"a\":[1,2,3],\"b\":{\"c\":\"d\"}}");
    defer document.deinit();

    var first = try document.walk(testing.allocator);
    defer first.deinit();
    var second = try document.walk(testing.allocator);
    defer second.deinit();
    var third = try document.walk(testing.allocator);
    defer third.deinit();

    try testing.expectEqual(first.count(), second.count());
    try testing.expectEqual(first.count(), third.count());
    try testing.expectEqual(first.blobs.len, second.blobs.len);
    try testing.expectEqual(first.blobs.len, third.blobs.len);
    for (first.nodes, second.nodes) |a, b| {
        try testing.expectEqual(a.depth, b.depth);
        try testing.expectEqual(a.type, b.type);
        try testing.expectEqual(a.count, b.count);
        try testing.expectEqual(a.key_off, b.key_off);
        try testing.expectEqual(a.key_len, b.key_len);
        try testing.expectEqual(a.str_off, b.str_off);
        try testing.expectEqual(a.str_len, b.str_len);
        try testing.expectEqual(a.i, b.i);
        try testing.expectEqual(a.u, b.u);
        try testing.expectEqual(a.d, b.d);
    }
    try testing.expectEqualStrings(first.blobs, second.blobs);
    try testing.expectEqualStrings(first.blobs, third.blobs);
}

test "a Walk read after deinit yields no values rather than a fault" {
    // Deinit clears slices so a used walk reads as empty.
    var document = try simdjson.parse("{\"a\":1}");
    defer document.deinit();
    var walk = try document.walk(testing.allocator);
    try testing.expect(walk.count() > 0);
    walk.deinit();

    try testing.expectEqual(@as(usize, 0), walk.count());
    try testing.expectEqual(@as(?simdjson.Value, null), walk.root());
    try testing.expectEqual(@as(usize, 0), walk.nodes.len);
    try testing.expectEqual(@as(usize, 0), walk.blobs.len);

    // Repeated deinit is safe.
    walk.deinit();
    try testing.expectEqual(@as(usize, 0), walk.count());
}

test "the walk's allocations are returned to the allocator that made them" {
    // Both walk buffers return to the allocator that created them.
    var debug: std.heap.DebugAllocator(.{}) = .init;
    const allocator = debug.allocator();

    {
        var document = try simdjson.parse("{\"a\":[1,2,3],\"b\":\"text\"}");
        defer document.deinit();
        var walk = try document.walk(allocator);
        try testing.expect(walk.count() > 0);
        walk.deinit();
        try testing.expectEqual(@as(usize, 0), walk.count());
    }

    try testing.expectEqual(@as(usize, 0), debug.detectLeaks());
}

test "the twitter fixture: 631515 bytes, walked to a counted total" {
    // The upstream Twitter fixture exercises large-document traversal.
    const json = try fixture("large/twitter.json");
    defer testing.allocator.free(json);
    try testing.expectEqual(@as(usize, 631515), json.len);

    var document = try simdjson.parse(json);
    defer document.deinit();
    var walk = try document.walk(testing.allocator);
    defer walk.deinit();

    const root = walk.root() orelse return error.NoRoot;
    try testing.expectEqual(simdjson.ValueType.object, root.valueType());
    const object = root.object() orelse return error.NotAnObject;

    for ([_][]const u8{ "statuses", "search_metadata" }) |key| {
        const field = object.get(key) orelse return error.MissingKey;
        try testing.expectEqualStrings(key, field.key);
    }

    const statuses = (object.get("statuses") orelse return error.MissingKey).value.array() orelse
        return error.NotAnArray;
    try testing.expect(statuses.len() > 0);

    var counted: usize = 0;
    var iterator = statuses.iterator();
    while (iterator.next()) |status| : (counted += 1) {
        try testing.expectEqual(simdjson.ValueType.object, status.valueType());
        const status_object = status.object() orelse return error.NotAnObject;
        const text = (status_object.get("text") orelse return error.MissingKey).value;
        try testing.expectEqual(simdjson.ValueType.string, text.valueType());
        _ = text.string() orelse return error.NoString;
    }
    try testing.expectEqual(statuses.len(), counted);

    const metadata = (object.get("search_metadata") orelse return error.MissingKey).value;
    try testing.expectEqual(simdjson.ValueType.object, metadata.valueType());
    const metadata_object = metadata.object() orelse return error.NotAnObject;
    const count_field = (metadata_object.get("count") orelse return error.MissingKey).value;
    try testing.expect(count_field.int() != null);
    try testing.expect((metadata_object.get("query") orelse return error.MissingKey).value.string() != null);

    try testing.expect(walk.count() > statuses.len());
    var deepest: u32 = 0;
    for (walk.nodes) |record| deepest = @max(deepest, record.depth);
    try testing.expect(deepest > 1);
    for (walk.nodes, 0..) |record, n| {
        if (record.count == 0) continue;
        var seen: u32 = 0;
        var probe = n + 1;
        while (probe < walk.nodes.len and walk.nodes[probe].depth > record.depth) : (probe += 1) {
            if (walk.nodes[probe].depth == record.depth + 1) seen += 1;
        }
        try testing.expectEqual(record.count, seen);
    }
}

test "the raw two-pass convention: a NULL buffer sizes, a short buffer is refused" {
    // A null output buffer reports required length before filling.
    var length: usize = 0;
    try expectStatus(simdjson.c.SIMDJSON_BRIDGE_OK,
        simdjson.c.simdjson_br_version(null, 0, &length),
    );
    try testing.expect(length > 0);

    // A short buffer reports required length without truncating.
    var small: [1]u8 = undefined;
    length = 0;
    try expectStatus(simdjson.c.SIMDJSON_BRIDGE_BUFFER_TOO_SMALL,
        simdjson.c.simdjson_br_version(&small, small.len, &length),
    );
    try testing.expect(length > small.len);

    // A null length pointer is invalid.
    try expectStatus(simdjson.c.SIMDJSON_BRIDGE_INVALID_ARGUMENT,
        simdjson.c.simdjson_br_version(null, 0, null),
    );

    const exact = try testing.allocator.alloc(u8, length + 1);
    defer testing.allocator.free(exact);
    try expectStatus(simdjson.c.SIMDJSON_BRIDGE_OK,
        simdjson.c.simdjson_br_version(exact.ptr, exact.len, &length),
    );
    try testing.expectEqual(exact.len - 1, length);
}

test "the raw route: an index past the implementation list is refused" {
    // The kernel list depends on build flags; only out-of-range refusal is stable.
    const count = simdjson.c.simdjson_br_available_implementation_count();
    try testing.expect(count >= 1);

    for (0..count) |n| {
        var name_buffer: [64]u8 = undefined;
        var length: usize = 0;
        try expectStatus(simdjson.c.SIMDJSON_BRIDGE_OK,
            simdjson.c.simdjson_br_available_implementation_name(n, &name_buffer, name_buffer.len, &length),
        );
        try testing.expect(length > 0);
        try testing.expect(length < name_buffer.len);
    }

    var length: usize = 0;
    try expectStatus(simdjson.c.SIMDJSON_BRIDGE_INVALID_ARGUMENT,
        simdjson.c.simdjson_br_available_implementation_name(count, null, 0, &length),
    );
}

test "the raw route: the walk's two-pass buffers are both required" {
    // A null or empty output buffer requests both record and blob sizes.
    try withWalk("{\"a\":1,\"b\":\"two\"}", struct {
        fn check(walk: simdjson.Walk) !void {
            try testing.expectEqual(@as(usize, 3), walk.count());
            try testing.expectEqual(@as(usize, 5), walk.blobs.len);
            // Every record offset and length must fit the copied blob.
            for (walk.nodes) |record| {
                if (record.key_off != simdjson.Record.no_offset) {
                    try testing.expect(record.key_off < walk.blobs.len);
                    try testing.expect(record.key_off + record.key_len <= walk.blobs.len);
                }
                if (record.str_off != simdjson.Record.no_offset) {
                    try testing.expect(record.str_off < walk.blobs.len);
                    try testing.expect(record.str_off + record.str_len <= walk.blobs.len);
                }
                // Sentinel offsets represent absent bytes.
                try testing.expectEqual(
                    record.key_off == simdjson.Record.no_offset,
                    record.bytes(walk.blobs, record.key_off, record.key_len) == null,
                );
                try testing.expectEqual(
                    record.str_off == simdjson.Record.no_offset,
                    record.bytes(walk.blobs, record.str_off, record.str_len) == null,
                );
                try testing.expectEqual(
                    @as(?[]const u8, null),
                    record.bytes(walk.blobs, @as(u32, @intCast(walk.blobs.len + 1)), 0),
                );
            }
        }
    }.check);
}

test "the raw route: input_size reports the call, not the document" {
    // Input size counts the full caller-provided range, including whitespace.
    const cases = [_]struct { json: []const u8, size: usize }{
        .{ .json = "{\"a\":1}", .size = 7 },
        .{ .json = "{ \"a\" : 1 }", .size = 11 },
        .{ .json = " 1 ", .size = 3 },
    };

    for (cases) |case| {
        var handle: ?*simdjson.c.struct_simdjson_bridge_document = null;
        var upstream: i32 = 0;
        try expectStatus(simdjson.c.SIMDJSON_BRIDGE_OK,
            simdjson.c.simdjson_br_open(case.json.ptr, case.json.len, &handle, &upstream),
        );
        try testing.expectEqual(@as(i32, 0), upstream);
        try testing.expect(handle != null);
        defer simdjson.c.simdjson_br_destroy(handle.?);

        var reported: usize = 0;
        try expectStatus(simdjson.c.SIMDJSON_BRIDGE_OK,
            simdjson.c.simdjson_br_input_size(handle.?, &reported),
        );
        try testing.expectEqual(case.size, reported);
    }
}

test "the raw route: a NULL pointer is refused, and a NULL with length 0 is a range" {
    // Validation accepts null only for a zero-length range.
    var ok: c_int = -1;
    try expectStatus(
        simdjson.c.SIMDJSON_BRIDGE_OK,
        simdjson.c.simdjson_br_validate_utf8(null, 0, &ok),
    );
    try testing.expectEqual(@as(c_int, 1), ok);

    try expectStatus(
        simdjson.c.SIMDJSON_BRIDGE_INVALID_ARGUMENT,
        simdjson.c.simdjson_br_validate_utf8(null, 1, &ok),
    );

    // Parse rejects null pointers, even for a zero-length range.
    var handle: ?*simdjson.c.struct_simdjson_bridge_document = null;
    var upstream: i32 = 0;
    try expectStatus(simdjson.c.SIMDJSON_BRIDGE_INVALID_ARGUMENT,
        simdjson.c.simdjson_br_open(null, 0, &handle, &upstream),
    );
    try testing.expect(handle == null);

    const empty = "";
    try expectStatus(simdjson.c.SIMDJSON_BRIDGE_UPSTREAM_ERROR,
        simdjson.c.simdjson_br_open(empty.ptr, 0, &handle, &upstream),
    );
    try testing.expectEqual(@as(i32, 13), upstream); // upstream's EMPTY
    try testing.expectEqual(simdjson.Error.UpstreamEmpty, simdjson.upstreamError(upstream));
}

test "the raw route: destroy accepts a NULL handle" {
    // Destroy accepts a null handle, including after failed open.
    simdjson.c.simdjson_br_destroy(null);
    // Releasing null twice must remain safe.
    simdjson.c.simdjson_br_destroy(null);
}

test "the raw route: a short buffer is a capacity refusal, not a malformed document" {
    // Capacity failures report both required sizes without becoming parser errors.
    const json = "{\"a\":[1,2,3],\"b\":\"text\"}";

    var handle: ?*simdjson.c.struct_simdjson_bridge_document = null;
    var upstream: i32 = 0;
    try expectStatus(simdjson.c.SIMDJSON_BRIDGE_OK,
        simdjson.c.simdjson_br_open(json.ptr, json.len, &handle, &upstream),
    );
    defer simdjson.c.simdjson_br_destroy(handle.?);

    var nodes: usize = 0;
    var blobs: usize = 0;
    try expectStatus(simdjson.c.SIMDJSON_BRIDGE_OK,
        simdjson.c.simdjson_br_walk(handle.?, null, 0, &nodes, null, 0, &blobs, &upstream),
    );
    try testing.expectEqual(@as(usize, 6), nodes);
    try testing.expectEqual(@as(usize, 6), blobs);

    // A short node buffer reports capacity failure and required sizes.
    var tiny_nodes: [2]simdjson.c.simdjson_bridge_node = undefined;
    var blob_storage: [6]u8 = undefined;
    var got_nodes: usize = 0;
    var got_blobs: usize = 0;
    upstream = 0;
    try expectStatus(simdjson.c.SIMDJSON_BRIDGE_BUFFER_TOO_SMALL,
        simdjson.c.simdjson_br_walk(
            handle.?,
            &tiny_nodes,
            tiny_nodes.len,
            &got_nodes,
            &blob_storage,
            blob_storage.len,
            &got_blobs,
            &upstream,
        ),
    );
    try testing.expectEqual(nodes, got_nodes);
    try testing.expectEqual(blobs, got_blobs);

    var records: [8]simdjson.c.simdjson_bridge_node = undefined;
    var big_enough: [6]u8 = undefined;
    got_nodes = 0;
    got_blobs = 0;
    upstream = 0;
    try expectStatus(simdjson.c.SIMDJSON_BRIDGE_OK,
        simdjson.c.simdjson_br_walk(
            handle.?,
            &records,
            records.len,
            &got_nodes,
            &big_enough,
            big_enough.len,
            &got_blobs,
            &upstream,
        ),
    );
    try testing.expectEqual(nodes, got_nodes);
    try testing.expectEqual(blobs, got_blobs);

    // Raw records and the typed facade must agree on the C struct layout.
    var document = try simdjson.parse(json);
    defer document.deinit();
    var typed = try document.walk(testing.allocator);
    defer typed.deinit();
    try testing.expectEqual(typed.count(), got_nodes);
    for (typed.nodes, records[0..got_nodes]) |a, b| {
        try testing.expectEqual(a.depth, b.depth);
        try testing.expectEqual(a.type, b.type);
        try testing.expectEqual(a.count, b.count);
        try testing.expectEqual(a.key_off, b.key_off);
        try testing.expectEqual(a.key_len, b.key_len);
        try testing.expectEqual(a.str_off, b.str_off);
        try testing.expectEqual(a.str_len, b.str_len);
        try testing.expectEqual(a.i, b.i);
        try testing.expectEqual(a.u, b.u);
        try testing.expectEqual(a.d, b.d);
    }
    try testing.expectEqualStrings(typed.blobs, big_enough[0..got_blobs]);
}
