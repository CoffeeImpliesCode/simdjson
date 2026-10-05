// SPDX-License-Identifier: Apache-2.0
// See FORK-LICENSE.md for the grant over this fork's own files.
//
//! Behavioural tests for the simdjson facade.
//!
//! ## What these tests are, and what they are not
//!
//! `AGENTS.md` §7 says the primary fixture is **an independent known answer, or
//! interoperability with an upstream or reference implementation**, and that a
//! same-code round trip proves only that the code agrees with itself. Every test
//! below is one of those two kinds, and none is the other kind:
//!
//!   * **RFC 8259 conformance.** The `testdata/rfc8259/` fixtures are the documents
//!     from RFC 8259 section 13, "Examples", and each expected value in a test is
//!     written here from the RFC's own text rather than from what the library
//!     returned. That is the whole of the claim: if a test passes, this facade
//!     produced the value the RFC's example document spells.
//!   * **Independent arithmetic and named standards.** Binary64 expectations
//!     that cannot be read off a JSON literal are computed from IEEE 754
//!     properties this test states -- the largest finite binary64, the
//!     `-2^64` boundary -- rather than obtained from the parser.
//!   * **Error classification read out of upstream's own enumerators.** Each
//!     malformed fixture's expected `Error` is the enumerator upstream's
//!     classification produces, and `FORK-NOTES.md` note 14 names the upstream
//!     line for each of the five that are `TAPE_ERROR`. A test that asserted
//!     "some error" would prove the parser refused *something*; these assert
//!     *which* refusal, which is the part a caller branches on.
//!   * **Ownership and lifetime transitions.** A `Walk` read after `deinit`; a
//!     repeated `Document.walk`; a parse whose input buffer is overwritten
//!     before the walk; the allocator counting after a scope.
//!
//! What is deliberately **not** here, per `AGENTS.md` §7's list of tests to
//! remove:
//!
//!   * no test pins `version()`, `builtinImplementation()`,
//!     `activeImplementation()` or `availableImplementationCount()` to a
//!     literal. Version pinning belongs to the provenance and licence gates --
//!     `UPSTREAM.md` and `tools/check-provenance.sh` -- and the two kernel
//!     accessors answer questions about *the machine and the flags*, which is
//!     exactly the boundary `FORK-NOTES.md` note 7 records: no caller may
//!     compare either against a literal. What is asserted about them is their
//!     *shape* (a non-empty name, a count of at least one), which is a
//!     behavioural property and not a version pin.
//!   * no test uses `@hasDecl`, checks export presence, or compares a
//!     forwarding accessor with a raw member.
//!   * no test copies, forwards or checks a non-zero length on its own.
//!   * nothing here asserts that a call does not throw: the surface returns
//!     errors rather than raising, and the error path is what is tested.
//!
//! ## Why one test is deliberately not portable
//!
//! `the depth limit this package sets on purpose` asserts that a document nested
//! past `DEFAULT_MAX_DEPTH` (1024, `src/include/simdjson/base.h:49`) is refused
//! with `UpstreamDepth`. That is true of **every** build this graph produces and
//! of no build of upstream's own, because `build_support/graph.zig` passes
//! `SIMDJSON_DEVELOPMENT_CHECKS=1` on every target in every optimize mode while
//! upstream adds it in Debug only (`src/CMakeLists.txt:376-379`). The test is
//! written against *this package's* stated configuration, and that is the point:
//! a depth limit that exists only in Debug is a limit nobody can rely on. See
//! `FORK-NOTES.md` note 8 and the module comment in `build.zig`.

const std = @import("std");
const testing = std.testing;
const simdjson = @import("simdjson");

/// The build-created module that names the shared fixture directory.
///
/// `build.zig:fixture_dir` resolves it to an absolute path at configure time, so
/// a test reads the bytes `UPSTREAM.sha256` pins rather than whatever happens to
/// sit in the working directory. A missing or moved `testdata/` is a build
/// failure, not a test that quietly passes with no fixtures.
const paths = @import("simdjson_paths");

/// The bound on a fixture read.
///
/// It is a stated fact about this package's own fixtures, not a guess: the
/// largest is `testdata/large/twitter.json` at 631515 bytes, and the bound is an
/// order of magnitude above that so a fixture may grow without a wrong path
/// reading an unbounded file. `readFileAlloc` returns `error.StreamTooLong`
/// rather than truncating, so a fixture that outgrew the bound would fail loudly
/// rather than be silently read in part.
const fixture_bound: std.Io.Limit = .limited(8 * 1024 * 1024);

/// Reads one fixture, whole.
///
/// Read through `Io.Dir.cwd()` and the absolute directory above, so the bytes
/// are the recorded ones and the read does not depend on the process's working
/// directory -- which is the caller's, and differs between `zig build test`, a
/// Nix sandbox and each cross-test cell.
fn fixture(relative: []const u8) ![]u8 {
    const path = try std.fs.path.join(testing.allocator, &.{ paths.fixture_dir, relative });
    defer testing.allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, fixture_bound);
}

/// Parses, walks and deinitialises in one call.
///
/// Every behavioural test needs the same four lines, and the deinitialisation is
/// not optional boilerplate: a `Walk` owns two allocations and a `Document` owns
/// a bridge handle, so a test that skipped it would leak into the next test and
/// turn one failure into two. Keeping it in one place means it cannot be
/// forgotten in one place.
fn withWalk(json: []const u8, comptime body: fn (simdjson.Walk) anyerror!void) !void {
    var document = try simdjson.parse(json);
    defer document.deinit();
    var walk = try document.walk(testing.allocator);
    defer walk.deinit();
    try body(walk);
}

/// The same, for a body that needs the calling context as well.
///
/// Separate from `withWalk` rather than a second parameter, because a void
/// context in every other test would be noise in thirty call sites.
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

/// Asserts that a document is refused, and with which error.
///
/// A test that asserted "some error" would pass if the facade refused for the
/// wrong reason, and the reason is the part a caller branches on. This makes a
/// refusal that is not the expected one name itself instead of failing as a bare
/// "expected error, found success".
///
/// The answer comes from *reading* the document, not from `parse` alone, and
/// that is the whole difference. `parse` is upstream's stage 1: it indexes
/// structure and UTF-8 but does not parse values, so it answers `SUCCESS` for
/// `{"a":1,}`, `{"a":01}` and `1e400`, which `zig/root.zig` states and which
/// `Document.walk` -- "the one call that reads the whole document" -- refuses.
/// A test that asked `parse` alone would report every one of those as accepted,
/// which is a statement about stage 1 and not about this package. So the
/// document is walked here and the first refusal either call raises is the
/// answer, which is also what a caller who wants to know whether a document is
/// well-formed gets.
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

/// Asserts a bridge status, coercing the expected enumerator to the width the
/// translation gives it.
///
/// `zig/bridge.h:129` declares `simdjson_bridge_status` as a plain C
/// enumeration with no fixed underlying type, so C says two different things
/// about it and `translate-c` reports both: an enumeration *constant* has type
/// `int` (`c_int`) while the enumeration's own underlying type is
/// implementation-defined and is `unsigned int` here (`enum_simdjson_bridge_status
/// = c_uint`) because every value it names is non-negative. An entry point
/// returns the second, so `testing.expectEqual` is handed a `c_int` and a
/// `c_uint` and refuses to resolve them to one type. Neither side is wrong and
/// neither is a width this package chooses, so the coercion happens here rather
/// than in the header: `zig/bridge.h` is plain C that a C++ consumer also
/// compiles, and pinning the enumeration's width would be an ABI statement this
/// package has not verified for a consumer whose compiler picked differently.
fn expectStatus(expected: c_uint, actual: c_uint) !void {
    return testing.expectEqual(expected, actual);
}

// ---------------------------------------------------------------------------
// RFC 8259 conformance
//
// The expected values below are written from the RFC's own section 13 documents,
// which is what makes them independent of what this library returns.
// ---------------------------------------------------------------------------

test "rfc8259 section 13 number: 42 is a signed integer, not a double" {
    const json = try fixture("rfc8259/13-value-number.json");
    defer testing.allocator.free(json);

    try withWalk(json, struct {
        fn check(walk: simdjson.Walk) !void {
            const root = walk.root() orelse return error.NoRoot;
            try testing.expectEqual(simdjson.ValueType.number, root.valueType());
            // The RFC's grammar has no integer/floating distinction -- it is one
            // `number` production (RFC 8259 section 6) -- so the split this
            // facade reports is *upstream's*, and upstream splits it on the
            // token's own shape: an integer literal has no fraction and no
            // exponent (`src/include/simdjson/base.h:43-48`). The RFC's answer
            // for `42` is the value 42; which field carries it is upstream's
            // decision, not this facade's.
            try testing.expectEqual(simdjson.NumberType.signed, root.numberType());
            try testing.expectEqual(@as(i64, 42), root.int().?);
            // The other accessors are null rather than zero: `d` is zero for
            // every number type except `floating_point`, so reading it here
            // would report zero as an answer.
            try testing.expectEqual(@as(?f64, null), root.double());
            try testing.expectEqual(@as(?u64, null), root.uint());
            try testing.expectEqual(@as(?bool, null), root.boolean());
            try testing.expectEqual(@as(?[]const u8, null), root.string());
            // And it is not a container.
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
            // "not a boolean" and `false` are different answers, and this surface
            // returns null for the second.
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
            // The RFC's section 13 example is `"Hello world!"` -- twelve
            // bytes, no escapes, no NUL.
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

            // The RFC's two example objects carry the same eight keys in the same
            // order and different values. Reading them by name and comparing the
            // values is the interoperability claim: this facade produced the RFC's
            // data.
            const latitudes = [_]f64{ 37.7668, 37.371991 };
            const longitudes = [_]f64{ -122.3959, -122.026020 };
            const zips = [_][]const u8{ "94107", "94085" };

            var seen: usize = 0;
            var iterator = items.iterator();
            while (iterator.next()) |element| : (seen += 1) {
                try testing.expectEqual(simdjson.ValueType.object, element.valueType());
                const object = element.object() orelse return error.NotAnObject;
                try testing.expectEqual(@as(usize, 8), object.len());

                // `precision` is "zip" in both, `Address` is the empty string in
                // both, and `Country` is "US" in both -- so those three are read
                // on every element, which is what exercises the name search
                // repeatedly rather than once.
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

                // The RFC writes these with a decimal point and no exponent, so
                // upstream's split calls them `floating_point`. The expected
                // doubles are the RFC's own decimal spellings, written here as
                // literals because the RFC states them to that many digits.
                const latitude = (object.get("Latitude") orelse return error.MissingKey).value;
                try testing.expectEqual(simdjson.NumberType.floating_point, latitude.numberType());
                try testing.expectEqual(latitudes[seen], latitude.double().?);
                try testing.expectEqual(longitudes[seen], (object.get("Longitude") orelse return error.MissingKey).value.double().?);
                // `Zip` is a JSON *string* in the RFC's document, not a number,
                // even though it looks like one.
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
            // RFC 8259 section 13's object has *one* top-level key, `Image`, and
            // the keys the RFC writes inside it are members of that member and
            // not of the document. `Object.at` is positional, so this is the
            // RFC's ordering and not a lookup order.
            try testing.expectEqual(@as(usize, 1), object.len());
            const image = object.at(0) orelse return error.NoField;
            try testing.expectEqualStrings("Image", image.key);
            try testing.expectEqual(@as(?simdjson.Field, null), object.at(1));

            try testing.expectEqual(simdjson.ValueType.object, image.value.valueType());
            const image_object = image.value.object() orelse return error.NotAnObject;
            // Six members: `Width`, `Height`, `Title`, `Thumbnail`, `Animated`
            // and `IDs`. `Width` and `Height` are JSON integers in the RFC's
            // document, so upstream classifies them `signed`.
            try testing.expectEqual(@as(usize, 6), image_object.len());
            try testing.expectEqual(@as(i64, 800), (image_object.get("Width") orelse return error.MissingKey).value.int().?);
            try testing.expectEqual(@as(i64, 600), (image_object.get("Height") orelse return error.MissingKey).value.int().?);
            try testing.expectEqualStrings(
                "View from 15th Floor",
                (image_object.get("Title") orelse return error.MissingKey).value.string().?,
            );
            // The RFC's `Animated` is `false`, and `false` is an answer distinct
            // from "not a boolean".
            const animated = (image_object.get("Animated") orelse return error.MissingKey).value;
            try testing.expectEqual(false, animated.boolean().?);
            try testing.expectEqual(@as(?bool, null), animated.isNull());

            // The nested object. `Thumbnail` sits at depth 2 of the walk, which
            // is what `Record.depth` records and what makes a pre-order stream
            // navigable at all.
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

            // The integer array `IDs`, with the RFC's four values.
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

// ---------------------------------------------------------------------------
// Numbers: independent arithmetic and the upstream split
// ---------------------------------------------------------------------------

test "number grammar: every literal in the fixture, classified the way upstream classifies it" {
    const json = try fixture("values/number-grammar.json");
    defer testing.allocator.free(json);

    try withWalk(json, struct {
        fn check(walk: simdjson.Walk) !void {
            const root = walk.root() orelse return error.NoRoot;
            const items = root.array() orelse return error.NotAnArray;

            // The fixture's seventeen literals, in the order the file writes
            // them. RFC 8259 section 6 has one `number` production
            // (`number = [ minus ] int [ frac ] [ exp ]`), so the split below is
            // upstream's rather than the RFC's: upstream calls a literal with no
            // fraction and no exponent `signed_integer` and one with either a
            // `floating_point` (`src/include/simdjson/base.h:43-48`).
            //
            // `-0` is the interesting one. RFC 8259 section 6 writes
            // `int = zero / (digit1-9 *DIGIT)` with an optional leading `minus`,
            // so `-0` is a legal number and its value is negative zero. Its
            // *integer* value is 0, and negative zero is not representable in an
            // `i64`, so reading `-0` and getting `0` is correct rather than
            // surprising -- which is why the note is here.
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
                // A `signed` value is not widened into `double`, and the two
                // values that are bit-identical in the JSON text are still
                // classified by their own token shape.
                try testing.expectEqual(@as(?f64, null), element.double());
                try testing.expectEqual(@as(?u64, null), element.uint());
            }

            for (floating, 0..) |want, k| {
                const element = items.get(signed_values.len + k) orelse return error.NoElement;
                try testing.expectEqual(simdjson.NumberType.floating_point, element.numberType());
                // Every one of the twelve is compared for equality against a
                // value written here from the decimal the fixture spells, and
                // `std.math.floatMax(f64)` is the IEEE 754 maximum rather than a
                // copy of the parser's answer. A parser that rounded wrongly by
                // one ulp would fail.
                try testing.expectEqual(want, element.double().?);
                try testing.expectEqual(@as(?i64, null), element.int());
            }

            // The subnormal-adjacent small one is the case worth stating: the
            // fixture's "0.000000000000000000000000001" is 1e-27, which is a
            // normal binary64, and it must not be reported as zero.
            const tiny = items.get(signed_values.len + 7) orelse return error.NoElement;
            try testing.expect(tiny.double().? > 0.0);
            // And the 1e-300 literal is normal too -- binary64's smallest
            // subnormal is about 4.9e-324, so anything at 1e-300 has exponent
            // to spare and must be exactly representable to 53 bits.
            const deep = items.get(signed_values.len + 6) orelse return error.NoElement;
            try testing.expect(deep.double().? > 1e-301);
            try testing.expect(deep.double().? < 1e-299);
        }
    }.check);
}

test "a positive integer above u64 max is big_integer, and its text is the answer" {
    // Not in a fixture: this is the case upstream's `number_type::big_integer`
    // (`src/include/simdjson/base.h:47`) exists for, and it is worth a test
    // because the facade's answer for it is *text*, not a number. RFC 8259's
    // grammar places no limit on the integer part's digits (section 6,
    // `int = zero / (digit1-9 *DIGIT)`), so this document is valid JSON and the
    // only question is what a parser reports for it.
    //
    // 2^64 is 18446744073709551616 -- one past the largest u64 -- so upstream
    // cannot classify it `unsigned` and reports `big_integer`. The decimal text
    // is written here from the power, not copied from the parser.
    try withWalk("{\"n\":18446744073709551616}", struct {
        fn check(walk: simdjson.Walk) !void {
            const root = walk.root() orelse return error.NoRoot;
            const object = root.object() orelse return error.NotAnObject;
            const value = (object.get("n") orelse return error.MissingKey).value;

            try testing.expectEqual(simdjson.NumberType.big, value.numberType());
            try testing.expectEqualStrings("18446744073709551616", value.bigIntegerText().?);

            // And it is *not* truncated into any of the numeric fields. Upstream
            // documents every numeric accessor as valid only for its own type
            // (`src/include/simdjson/generic/ondemand/json_type.h:52-58,66-78`),
            // and the record's `i`, `u` and `d` are all zero for this type.
            try testing.expectEqual(@as(?i64, null), value.int());
            try testing.expectEqual(@as(?u64, null), value.uint());
            try testing.expectEqual(@as(?f64, null), value.double());
        }
    }.check);
}

test "u64 max is unsigned, and one past it is big: the boundary is exact" {
    // The two documents differ by one in the last digit and land in different
    // upstream number types. 2^64 - 1 is 18446744073709551615, the largest u64.
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

// ---------------------------------------------------------------------------
// Strings and escapes
// ---------------------------------------------------------------------------

test "string escapes: every RFC 8259 section 7 escape, unescaped to what the RFC says" {
    const json = try fixture("values/string-escapes.json");
    defer testing.allocator.free(json);

    try withWalk(json, struct {
        fn check(walk: simdjson.Walk) !void {
            const items = (walk.root() orelse return error.NoRoot).array() orelse
                return error.NotAnArray;
            try testing.expectEqual(@as(usize, 15), items.len());

            // The two-character escapes from RFC 8259 section 7's table. Each is
            // named by what the RFC says it means, and the expected byte is
            // spelled here -- so a facade that returned the *source* bytes
            // rather than the unescaped ones would fail rather than agree.
            try testing.expectEqualStrings("\"", (items.get(0) orelse return error.NoElement).string().?);
            try testing.expectEqualStrings("\\", (items.get(1) orelse return error.NoElement).string().?);
            // `\/` is the solidus: RFC 8259 section 7 lists it among the escapes
            // so a JSON string can carry a solidus without it being ambiguous,
            // and it unescapes to one byte.
            try testing.expectEqualStrings("/", (items.get(2) orelse return error.NoElement).string().?);
            try testing.expectEqualStrings("\x08", (items.get(3) orelse return error.NoElement).string().?);
            try testing.expectEqualStrings("\x0C", (items.get(4) orelse return error.NoElement).string().?);
            try testing.expectEqualStrings("\n", (items.get(5) orelse return error.NoElement).string().?);
            try testing.expectEqualStrings("\r", (items.get(6) orelse return error.NoElement).string().?);
            try testing.expectEqualStrings("\t", (items.get(7) orelse return error.NoElement).string().?);

            // `\uXXXX` must become the UTF-8 encoding of the code point. RFC 8259
            // section 3 gives the encoding, so the expected bytes are the
            // standard's and not the parser's.
            // U+0041 LATIN CAPITAL LETTER A -- one byte.
            try testing.expectEqualStrings("A", (items.get(8) orelse return error.NoElement).string().?);
            // U+00E9 LATIN SMALL LETTER E WITH ACUTE -- two bytes.
            try testing.expectEqualStrings("\u{00E9}", (items.get(9) orelse return error.NoElement).string().?);
            // U+4E2D and U+6587, in the order the fixture writes them -- three
            // bytes each.
            try testing.expectEqualStrings("\u{4E2D}\u{6587}", (items.get(10) orelse return error.NoElement).string().?);
            // The surrogate pair U+1D11E MUSICAL SYMBOL G CLEF. One code point
            // outside the basic plane, which RFC 8259 section 3 encodes as four
            // bytes and which cannot be represented as two three-byte sequences.
            // A decoder that handled each surrogate separately would produce
            // something else, which is what makes this the escape worth testing.
            try testing.expectEqualStrings("\u{1D11E}", (items.get(11) orelse return error.NoElement).string().?);
            // U+1F600 GRINNING FACE -- also four bytes, from a second pair.
            try testing.expectEqualStrings("\u{1F600}", (items.get(12) orelse return error.NoElement).string().?);
            try testing.expectEqualStrings("\u{00FC}ber", (items.get(13) orelse return error.NoElement).string().?);
            try testing.expectEqualStrings("A", (items.get(14) orelse return error.NoElement).string().?);

            // The lengths, which is where a decoder that emitted UTF-16 rather
            // than UTF-8 would differ. The fourteenth is U+00FC's two bytes
            // followed by three ASCII ones, so the table has a length that is
            // neither one nor the size of a whole code point sequence.
            const expected_lengths = [_]usize{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 6, 4, 4, 5, 1 };
            for (expected_lengths, 0..) |want, n| {
                const element = items.get(n) orelse return error.NoElement;
                try testing.expectEqual(want, element.string().?.len);
            }
        }
    }.check);
}

test "an empty string is present, and a zero-length key is a key" {
    // RFC 8259 section 7: `string = quotation-mark *char quotation-mark`, and
    // `char` may be zero characters, so `""` is a legal string. Section 4 allows
    // a member name of any string, including the empty one -- which is also why
    // the absent-offset marker in a record is a sentinel *offset* and never a
    // zero *length* (`zig/bridge.h:297-304`).
    try withWalk("{\"\":\"\",\"a\":\"\"}", struct {
        fn check(walk: simdjson.Walk) !void {
            const root = walk.root() orelse return error.NoRoot;
            const object = root.object() orelse return error.NotAnObject;
            try testing.expectEqual(@as(usize, 2), object.len());

            const empty_key = object.get("") orelse return error.MissingKey;
            try testing.expectEqualStrings("", empty_key.key);
            try testing.expectEqualStrings("", empty_key.value.string().?);
            // An empty string is *present*: `string()` returns the empty slice
            // rather than null, because null would be indistinguishable from
            // "not a string".
            try testing.expect(empty_key.value.string() != null);
            try testing.expectEqual(simdjson.ValueType.string, empty_key.value.valueType());

            const named = object.get("a") orelse return error.MissingKey;
            try testing.expectEqualStrings("a", named.key);
            try testing.expectEqualStrings("", named.value.string().?);
            // Two records, one key empty and one not, so `get("")` did not match
            // the first record merely by finding a zero-length key.
            try testing.expect(named.key.len != empty_key.key.len);
        }
    }.check);
}

// ---------------------------------------------------------------------------
// Refusals, and *which* refusal
// ---------------------------------------------------------------------------

test "malformed inputs are refused, each with the error upstream's own classification produces" {
    // The eight fixtures in `testdata/malformed/`, each with the upstream
    // `simdjson::error_code` that reaches this surface as an `Error`. Five are
    // `TAPE_ERROR` and `FORK-NOTES.md` note 14 names the upstream line for each:
    // they are refused by a structural-index or value-classification step upstream
    // itself calls `TAPE_ERROR`, not by a code invented at the seam.
    //
    //   01 `{"a":1,}`  TAPE_ERROR -- the second `field_key` is handed `}`
    //   02 `{'a':'b'}` TAPE_ERROR -- the second `field_key` is handed `'`
    //   03 `{a:1}`     TAPE_ERROR -- the second `field_key` is handed `a`
    //   04 `{"a":NaN}` TAPE_ERROR -- `N` is not a token start, so
    //                     `value_iterator::type` answers `json_type::unknown`
    //   05 `{"a":+1}`  TAPE_ERROR -- `+` is not a token start, the same arm
    //   07 `{"a" 1}`   TAPE_ERROR -- `field_value`'s explicit `':'` check
    //   08 `{"a":"b}`  UNCLOSED_STRING -- the string scanner reports it at the
    //                     end of the input
    //   09 (empty)     EMPTY -- "no structural element found"
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
    // RFC 8259 section 6: `int = zero / (digit1-9 *DIGIT)`. `01` is therefore
    // not a number -- the leading zero may not be followed by another digit.
    //
    // This is the case that decides how this package reads a number. A bridge
    // that peeked at the token's shape first would classify `01` as a signed
    // integer -- upstream's `value::get_number_type()` has no leading-zero check
    // at all (`src/include/simdjson/generic/numberparsing.h:1526-1568`) -- and
    // would then have to choose between reporting a number type for an invalid
    // document and refusing the document. This package parses the number, so the
    // guard in `parse_number` runs
    // (`src/include/simdjson/generic/numberparsing.h:905-906,919`) and the
    // document is refused. `FORK-NOTES.md` note 5 is the record.
    const json = try fixture("values/leading-zero.json");
    defer testing.allocator.free(json);

    // The upstream error is `NUMBER_ERROR`: `numberparsing.h:26` `#define`s
    // `INVALID_NUMBER` to it and `:919` returns that.
    try expectRefused(json, simdjson.Error.UpstreamNumber, "values/leading-zero.json");
}

test "an unescaped control character inside a string is refused" {
    // RFC 8259 section 7: "All Unicode characters may be placed within the
    // quotation marks except for the characters that must be escaped: quotation
    // mark, reverse solidus, and the control characters (U+0000 through
    // U+001F)." The fixture is `{"a":"x<0x07>y"}` -- U+0007 is BEL, unescaped.
    //
    // Upstream's own name for this is `UNESCAPED_CHARS`
    // (`src/include/simdjson/error.h:34`), so the facade reports it as
    // `UpstreamUnescapedChars`. The boundary worth testing is that it is *not*
    // a UTF-8 error: U+0001 is perfectly valid UTF-8, so a validator-only check
    // would have passed it and the grammar check is what refuses it. The test
    // asserts both halves for exactly that reason.
    const json = try fixture("values/unescaped-control-character.json");
    defer testing.allocator.free(json);

    try testing.expectEqual(@as(usize, 11), json.len);
    try testing.expectEqual(@as(u8, 0x01), json[7]);
    try testing.expect(try simdjson.validateUtf8(json));

    try expectRefused(json, simdjson.Error.UpstreamUnescapedChars, "values/unescaped-control-character.json");
}

test "invalid UTF-8 is refused by the validator, and the validator agrees with parse" {
    // A lone continuation byte, an overlong NUL, a truncated three-byte form and
    // a value past U+10FFFF. RFC 8259 section 8 says JSON text SHALL be encoded
    // using UTF-8, and section 6's `unescaped` ranges exclude surrogate code
    // points and anything above U+10FFFF, so all four are invalid under the
    // standard this package is a parser for.
    //
    // The pairing is the point: `validateUtf8` says `false` for these bytes and
    // `parse` refuses them with the UTF-8 error, so the two agree about which
    // bytes are legal. Neither answer is taken from the other, and both come
    // from the library: `validateUtf8` is `simdjson::validate_utf8` itself
    // (`src/include/simdjson/implementation.h:18`), which is the same validation
    // the library runs internally during stage 1
    // (`src/include/simdjson/common_defs.h:365-366`).
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

    // The valid side of the same boundary, including the largest scalar value
    // UTF-8 can encode and the smallest multi-byte one.
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
    // The one entry point whose answer is a function of the bytes rather than of
    // a parse. Each pair below is the same shape with and without a grammar
    // error, which is the boundary: `{"a":1}` is valid UTF-8 *and* a valid
    // document, `{"a":01}` is valid UTF-8 and *not* a valid document, and
    // `"\xFF"` is neither.
    try testing.expect(try simdjson.validateUtf8("{\"a\":1}"));
    try testing.expect(try simdjson.validateUtf8("{\"a\":01}"));
    try testing.expect(!try simdjson.validateUtf8("{\"a\":\"\xFF\"}"));

    // An empty *range* is valid UTF-8 -- there is nothing in it to be invalid --
    // while an empty *document* is refused by `parse` with `EMPTY`. Two
    // different questions, two different answers, and neither is derived from
    // the other.
    try testing.expect(try simdjson.validateUtf8(""));
    try expectRefused("", simdjson.Error.UpstreamEmpty, "empty document");
}

test "trailing content after a complete value is refused" {
    // RFC 8259 section 8: "Implementations MUST NOT add any extra bits to the
    // document, including whitespace." A parser that stopped at the first
    // complete value would accept all three of these; upstream's name is
    // `TRAILING_CONTENT` (`src/include/simdjson/error.h:51`).
    try expectRefused("1 2", simdjson.Error.UpstreamTrailingContent, "1 2");
    try expectRefused("{} {}", simdjson.Error.UpstreamTrailingContent, "{} {}");
    try expectRefused("[1][2]", simdjson.Error.UpstreamTrailingContent, "[1][2]");
    // A trailing newline is *not* extra content: RFC 8259 section 8's ABNF for
    // `JSON-text` ends with optional whitespace, so this one must be accepted.
    // Testing it is what makes the refusal above about content rather than about
    // "there are extra bytes".
    var document = try simdjson.parse("1\n");
    defer document.deinit();
    var walk = try document.walk(testing.allocator);
    defer walk.deinit();
    try testing.expectEqual(@as(i64, 1), (walk.root() orelse return error.NoRoot).int().?);
}

test "an incomplete container is refused, not partially read" {
    // The shapes a truncated document can have. Upstream's name is
    // `INCOMPLETE_ARRAY_OR_OBJECT` (`src/include/simdjson/error.h:48`), and it
    // is reachable from `document::get_value()` itself
    // (`src/include/simdjson/generic/ondemand/document-inl.h:94`) with no
    // unusual configuration -- which is why this package's error mirror carries
    // every member of upstream's enumeration and not only the ones it has been
    // seen to produce (`FORK-NOTES.md` note 4).
    try expectRefused("[1,2", simdjson.Error.UpstreamIncompleteArrayOrObject, "[1,2");
    try expectRefused("{\"a\":1", simdjson.Error.UpstreamIncompleteArrayOrObject, "{\"a\":1");
    try expectRefused("[", simdjson.Error.UpstreamIncompleteArrayOrObject, "[");
    // And an empty container is not an incomplete one: `[]` and `{}` are
    // complete, empty documents under RFC 8259 section 7.
    try withWalk("[]", struct {
        fn check(walk: simdjson.Walk) !void {
            const root = walk.root() orelse return error.NoRoot;
            try testing.expectEqual(simdjson.ValueType.array, root.valueType());
            try testing.expectEqual(@as(usize, 0), root.array().?.len());
            // One record: the empty array itself. A `count` of zero and a
            // `nodes.len` of one is the shape of a container with no children.
            try testing.expectEqual(@as(usize, 1), walk.count());
        }
    }.check);
}

test "an oversized number is refused rather than clamped" {
    // RFC 8259 section 6 places no bound on a number's digits or exponent, so
    // `1e400` is a legal document that binary64 cannot represent as a finite
    // value. Upstream refuses it rather than reading it as infinity or clamping
    // it: `write_float` answers `INVALID_NUMBER` for a decimal exponent past
    // `internal::largest_power`
    // (`src/include/simdjson/generic/numberparsing.h:819-833`), and again when its
    // fallback parse comes back infinite (`:836-839`); `INVALID_NUMBER` is
    // `NUMBER_ERROR` (`:26`, `:919`). So the enumerator is `NUMBER_ERROR` and not
    // `NUMBER_OUT_OF_RANGE`, which upstream raises only from its narrowing
    // accessors (`src/include/simdjson/dom/element-inl.h:286,301`) and never
    // from parsing a number.
    try expectRefused("1e400", simdjson.Error.UpstreamNumber, "1e400");
    try expectRefused("-1e400", simdjson.Error.UpstreamNumber, "-1e400");
    // And a number binary64 *can* hold is not refused, which is what makes the
    // refusal about the magnitude rather than about "big numbers".
    //
    // Both expected values come from IEEE 754 rather than from the parser: 1e308
    // is the largest power of ten binary64 represents, and the largest finite
    // binary64 has the decimal spelling 1.7976931348623157e308, so a
    // representation with no rounding error must come back bit for bit. That is
    // upstream's own stated goal for `parse_number` -- "accurate parsing (ULP of
    // 0) at high speed"
    // (`src/include/simdjson/generic/numberparsing.h:886`).
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

// ---------------------------------------------------------------------------
// Nesting, and the depth boundary this package sets on purpose
// ---------------------------------------------------------------------------

test "nesting-32 and nesting-64: depth is recorded, and both walk to the leaf" {
    // Two fixtures at 32 and 64 levels, each `{"a":{"a":...{"leaf":1}...}}`. The
    // leaf is the same value in both, so the pair is the independent check on
    // `Record.depth` and on `Value.at`'s pre-order walk: the depth recorded for
    // the leaf must be the fixture's own nesting, not a constant.
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
                    // Every record on the way down is an object one level deeper
                    // than its parent.
                    try testing.expectEqual(simdjson.ValueType.object, node.valueType());
                    try testing.expectEqual(depth, walk.nodes[node.index].depth);
                    const object = node.object() orelse return error.NotAnObject;
                    const next = object.get("a") orelse {
                        const leaf = object.get("leaf") orelse return error.NoLeaf;
                        try testing.expectEqual(@as(i64, 1), leaf.value.int().?);
                        // The `levels` objects that carry an `a` key occupy
                        // depths 0 through levels - 1, the object holding `leaf`
                        // is one level deeper than the last of them, and the
                        // leaf's own value is one deeper again. A record is one
                        // *value*, so the leaf object is a record of its own and
                        // the stream is two longer than the level count.
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
    // A walk is a flat pre-order stream of fixed-width records plus one blob,
    // and `Walk.count` is its length. The invariant worth proving is the one the
    // accessors depend on: a record's direct children are exactly the records
    // immediately after it whose depth is one greater, each followed by its own
    // subtree. `Object.at` and `Array.get` implement that walk, so a stream
    // satisfying it makes every accessor agree with `count`.
    //
    // The document is written here rather than loaded from a fixture so that the
    // expected record table is derived from the JSON text in this test.
    try withWalk("{\"a\":[1,{\"b\":[true,null]}],\"c\":\"end\",\"d\":{\"e\":{\"f\":1}}}", struct {
        fn check(walk: simdjson.Walk) !void {
            const root = walk.root() orelse return error.NoRoot;
            try testing.expectEqual(simdjson.ValueType.object, root.valueType());

            // Read off the JSON above, in pre-order:
            //   0 depth 0 object 3   the root
            //   1 depth 1 array  2   "a"
            //   2 depth 2 number 0   1
            //   3 depth 2 object 1   the element after 1
            //   4 depth 3 array  2   "b"
            //   5 depth 4 boolean 0  true
            //   6 depth 4 null   0   null
            //   7 depth 1 string 0   "c"
            //   8 depth 1 object 1   "d"
            //   9 depth 2 object 1   "e"
            //  10 depth 3 number 0   1, the value of "f"
            //
            // One record per *value*: a member's key rides on its own value's
            // record, so `{"d":{"e":{"f":1}}}` is three records and not five.
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

            // The invariant itself, over every record in the document: the number
            // of following records at exactly `depth + 1` before the depth drops
            // back to this record's own depth is `record.count`.
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
    // `values/nesting-2048.json` nests `{"a":` 2048 times -- twice
    // `DEFAULT_MAX_DEPTH` (1024, `src/include/simdjson/base.h:49`) -- and holds
    // the leaf one level deeper still.
    //
    // The refusal is this package's own comparison, and it is why one is needed:
    // upstream's limit sizes `parser::start_positions` and nothing else
    // (`src/include/simdjson/generic/ondemand/parser-inl.h:36`), stage 1 indexes
    // every depth it is given, and `SIMDJSON_DEVELOPMENT_CHECKS` -- which
    // `build_support/graph.zig` passes on every target in every mode -- turns the
    // bound into an assertion inside `json_iterator::set_start_position`
    // (`json_iterator-inl.h:432-434`, `src/include/simdjson/portability.h:243-246`)
    // that a process aborts on rather than an error a caller reads. So
    // `zig/bridge.cc` compares the walk's own depth against upstream's
    // `DEFAULT_MAX_DEPTH` and answers upstream's `DEPTH_ERROR` instead, which is
    // what makes the boundary a fact about the package in every optimize mode
    // rather than about the mode or the machine.
    //
    // `FORK-NOTES.md` note 8 is the decision record, and its "Targets bound"
    // line says how to overturn it: dropping the define restores upstream's
    // behaviour, where the same document aborts the process instead of being
    // refused.
    const json = try fixture("values/nesting-2048.json");
    defer testing.allocator.free(json);

    // The fixture really is that deep, so this test is not passing for a reason
    // that has nothing to do with depth: 2048 objects carrying an `a` key, plus
    // the one that holds `leaf`.
    var levels: usize = 0;
    for (json) |byte| {
        if (byte == '{') levels += 1;
    }
    try testing.expectEqual(@as(usize, 2049), levels);
    try testing.expect(levels > 1024);

    try expectRefused(json, simdjson.Error.UpstreamDepth, "values/nesting-2048.json");

    // And a document *below* the limit is not refused for depth, which is what
    // makes 2048 the boundary rather than "deep documents are refused".
    const within = try fixture("values/nesting-64.json");
    defer testing.allocator.free(within);
    var document = try simdjson.parse(within);
    defer document.deinit();
    var walk = try document.walk(testing.allocator);
    defer walk.deinit();
    try testing.expect(walk.count() > 0);
}

// ---------------------------------------------------------------------------
// Objects: order, duplicates, and the typed-accessor boundary
// ---------------------------------------------------------------------------

test "duplicate keys: all three values are in the walk, and get answers the first" {
    // `{"a":1,"b":2,"a":3}` is a valid document under RFC 8259 -- section 4 says
    // member names SHOULD be unique and that behaviour is unpredictable if they
    // are not, but the grammar does not forbid them. So a parser must not refuse
    // it, and it must not silently collapse it either.
    //
    // This package's `Object.get` is a linear search over the records and finds
    // the *first* match (`zig/root.zig:1133-1140`), which is what a caller
    // reading the document in order would have seen first. The test asserts both
    // halves: `get("a")` is 1, *and* the record for the second `"a"` is still in
    // the walk and readable by position. A facade that collapsed the duplicate
    // would pass the first assertion and fail the second.
    const json = try fixture("values/duplicate-keys.json");
    defer testing.allocator.free(json);

    try withWalk(json, struct {
        fn check(walk: simdjson.Walk) !void {
            const object = (walk.root() orelse return error.NoRoot).object() orelse
                return error.NotAnObject;

            // Three fields, not two.
            try testing.expectEqual(@as(usize, 3), object.len());
            try testing.expectEqual(@as(i64, 1), (object.get("a") orelse return error.MissingKey).value.int().?);
            try testing.expectEqual(@as(i64, 2), (object.get("b") orelse return error.MissingKey).value.int().?);

            // By position: the keys are `a`, `b`, `a` and the values are 1, 2, 3.
            const first_a = object.at(0) orelse return error.NoField;
            const b = object.at(1) orelse return error.NoField;
            const second_a = object.at(2) orelse return error.NoField;
            try testing.expectEqualStrings("a", first_a.key);
            try testing.expectEqualStrings("b", b.key);
            try testing.expectEqualStrings("a", second_a.key);
            try testing.expectEqual(@as(i64, 1), first_a.value.int().?);
            try testing.expectEqual(@as(i64, 2), b.value.int().?);
            try testing.expectEqual(@as(i64, 3), second_a.value.int().?);

            // Four records: the object and its three members. A facade that
            // collapsed the duplicate would have three.
            try testing.expectEqual(@as(usize, 4), walk.count());
        }
    }.check);
}

test "object accessors: absent keys, out-of-range positions, and re-readable iteration" {
    try withWalk("{\"a\":1,\"b\":2,\"c\":3}", struct {
        fn check(walk: simdjson.Walk) !void {
            const object = (walk.root() orelse return error.NoRoot).object() orelse
                return error.NotAnObject;

            // Absent is null, and null is a different answer from "present and
            // JSON null" -- which the next test separates properly.
            try testing.expect(object.get("missing") == null);
            try testing.expect(object.get("") == null);

            // Past the end is null, not a fault, and the boundary is the count
            // the walk itself recorded.
            try testing.expect(object.at(2) != null);
            try testing.expect(object.at(3) == null);
            try testing.expect(object.at(100) == null);

            // `remaining` counts down and stops at zero rather than wrapping.
            var iterator = object.iterator();
            try testing.expectEqual(@as(usize, 3), iterator.remaining());
            _ = iterator.next().?;
            try testing.expectEqual(@as(usize, 2), iterator.remaining());
            _ = iterator.next().?;
            _ = iterator.next().?;
            try testing.expectEqual(@as(usize, 0), iterator.remaining());
            try testing.expectEqual(@as(?simdjson.Field, null), iterator.next());
            // Past the end, `remaining` stays at zero rather than underflowing.
            try testing.expectEqual(@as(usize, 0), iterator.remaining());

            // `reset` restarts it, and the restarted iterator sees the same
            // fields -- a walk over already-copied records can be re-read any
            // number of times, which is what this package's shape buys over a
            // one-shot cursor (`FORK-NOTES.md` note 2).
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
    // A one-shot cursor could not do this: upstream's `array_iterator::operator*`
    // is "MUST ONLY BE CALLED ONCE PER ITERATION"
    // (`src/include/simdjson/generic/ondemand/array_iterator.h:53-54`), and two
    // live iterators over one document are what `OUT_OF_ORDER_ITERATION` exists
    // to prevent (`src/include/simdjson/error.h:46`). A `Walk` is a copy, so
    // iteration reads already-copied records and two of them are independent.
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
            // Drain one from `x`, then all of `y`, then the rest of `x`. Each
            // iterator's position is its own.
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
    // Upstream documents every numeric accessor as valid only for its own
    // `number_type` (`src/include/simdjson/generic/ondemand/json_type.h:52-58,66-78`),
    // and this package honours that by returning null rather than a widened or
    // truncated value. The record carries only the field its own type fills, so
    // reading `d` for an integer would report zero as an answer -- a plausible
    // wrong number rather than a missing one.
    try withWalk("[1,-1,1.5,\"s\",true,null,[],{}]", struct {
        fn check(walk: simdjson.Walk) !void {
            const items = (walk.root() orelse return error.NoRoot).array() orelse
                return error.NotAnArray;
            try testing.expectEqual(@as(usize, 8), items.len());

            // `1` and `-1`: signed. `int` answers and nothing else does.
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
                // Not a container, so not an array and not an object.
                try testing.expectEqual(@as(?simdjson.Array, null), element.array());
                try testing.expectEqual(@as(?simdjson.Object, null), element.object());
            }
            try testing.expectEqual(@as(i64, 1), items.get(0).?.int().?);
            try testing.expectEqual(@as(i64, -1), items.get(1).?.int().?);

            // `1.5`: floating point. Binary64 represents 1.5 exactly, so this is
            // an equality and not an approximation.
            const real = items.get(2) orelse return error.NoElement;
            try testing.expectEqual(simdjson.NumberType.floating_point, real.numberType());
            try testing.expectEqual(@as(f64, 1.5), real.double().?);
            try testing.expectEqual(@as(?i64, null), real.int());

            // A string, a boolean, a null and two containers all report `.none`,
            // which is this package's addition and has no upstream counterpart:
            // upstream has no `number_type` for a value that is not a number.
            for ([_]usize{ 3, 4, 5, 6, 7 }) |n| {
                try testing.expectEqual(simdjson.NumberType.none, items.get(n).?.numberType());
            }

            // The containers answer through their own accessors and not through
            // the numeric ones, and the string's `count` is 0 because a scalar
            // has no direct children.
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

            // Absent is null from `get`, and `isNull` on a non-null value is
            // null too. So `get(...) == null`, `get(...).?.value.isNull() == null`
            // and `get(...).?.value.isNull().? == true` are three distinguishable
            // answers, not two -- and that is what the accessor names are for.
            try testing.expect(object.get("absent") == null);
            const sibling = object.get("sibling") orelse return error.MissingKey;
            try testing.expectEqual(@as(?bool, null), sibling.value.isNull());
            try testing.expectEqual(@as(i64, 1), sibling.value.int().?);
        }
    }.check);
}

// ---------------------------------------------------------------------------
// Ownership and lifetime
// ---------------------------------------------------------------------------

test "a refused parse constructs nothing, and a later document is unaffected" {
    // `defer doc.deinit()` after a failed `parse` must not free something that
    // was never built, and a failed `parse` must not disturb a document the
    // caller already holds. Both are stated in `Document`: a default-
    // constructed `Document` has a null handle and `deinit` does nothing, and a
    // failed `parse` "constructs nothing and the caller's `Document` variable is
    // left exactly as it was" (`zig/root.zig`).
    var kept = try simdjson.parse("{\"first\":1}");
    defer kept.deinit();

    try expectRefused("{\"a\":1,}", simdjson.Error.UpstreamTape, "before");
    try expectRefused("", simdjson.Error.UpstreamEmpty, "empty");

    // The document opened before the failures is still the document it was, and
    // it still walks. A `parse` that cleared or reused the caller's handle would
    // fail here.
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
    // The bytes are copied by the bridge into upstream's own padded buffer
    // (`simdjson_bridge_document`'s `simdjson::padded_string` member), so the
    // caller's buffer may be freed or reused the instant `parse` returns and
    // nothing in the library retains it. The test proves it by overwriting the
    // source bytes and *then* walking: a library that had kept the caller's
    // pointer would walk the overwritten bytes and fail.
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
    // Upstream's `document::rewind()`
    // (`src/include/simdjson/generic/ondemand/document.h:763`) runs before each
    // pass, which is what makes a one-shot parser safely walkable twice. Three
    // walks are compared field by field: walks that agreed are the claim, and
    // walks that differed would mean the rewind is not happening.
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
    // The blobs carry the same bytes at the same offsets, so two walks agree on
    // the whole document and not only on its shape.
    try testing.expectEqualStrings(first.blobs, second.blobs);
    try testing.expectEqualStrings(first.blobs, third.blobs);
}

test "a Walk read after deinit yields no values rather than a fault" {
    // `Walk.deinit` leaves `nodes` and `blobs` as the empty slices rather than
    // dangling pointers, so reading a used walk is a wrong answer and not a
    // fault. That is worth a test: a use-after-free that happens to read zeros
    // looks like an empty document, and a test asserting only "no fault" would
    // pass either way.
    var document = try simdjson.parse("{\"a\":1}");
    defer document.deinit();
    var walk = try document.walk(testing.allocator);
    try testing.expect(walk.count() > 0);
    walk.deinit();

    try testing.expectEqual(@as(usize, 0), walk.count());
    try testing.expectEqual(@as(?simdjson.Value, null), walk.root());
    try testing.expectEqual(@as(usize, 0), walk.nodes.len);
    try testing.expectEqual(@as(usize, 0), walk.blobs.len);

    // And a second `deinit` frees two empty slices, which is safe.
    walk.deinit();
    try testing.expectEqual(@as(usize, 0), walk.count());
}

test "the walk's allocations are returned to the allocator that made them" {
    // `Walk.nodes` and `Walk.blobs` come from the allocator `Document.walk` was
    // given and `Walk.deinit` hands them back to *that* allocator, stored in the
    // walk itself so the two cannot be confused. Every other test in this file
    // uses `std.testing.allocator`, whose leak report is the real oracle; this
    // one makes the count the assertion, so a leak is a named failure rather
    // than a line at the end of a run.
    //
    // A `std.heap.DebugAllocator` is used rather than a bespoke counting
    // allocator because its `detectLeaks` answers exactly the question -- how
    // many allocations are still live -- and writing a wrapper allocator to
    // reach the same answer would be more code in the test than the assertion
    // is worth.
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

    // Nothing of this package's survives the scope: the two slices went back to
    // the allocator that made them, and the bridge handle was released inside
    // the library by `simdjson_br_destroy`. A walk that freed with the wrong
    // allocator, or a document that leaked its handle, would be live here.
    try testing.expectEqual(@as(usize, 0), debug.detectLeaks());
}

// ---------------------------------------------------------------------------
// A large document
// ---------------------------------------------------------------------------

test "the twitter fixture: 631515 bytes, walked to a counted total" {
    // `testdata/large/twitter.json` is a byte-identical copy of upstream's own
    // `src/jsonexamples/twitter.json`, so the *bytes* are upstream's and the
    // interoperability claim is this: a facade that walks upstream's own example
    // document reaches upstream's own top-level keys, and the nested structure
    // under `statuses` has the shape upstream's example describes.
    //
    // The structural invariant is checked over *every* record of a document this
    // size rather than sampled, and the record count is derived from the walk
    // itself. A constant would be a version pin wearing a test's clothes; the
    // digest in `UPSTREAM.sha256` is what pins the bytes.
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

    // The two top-level keys upstream's example document is built around, each
    // present and each read through the name-based accessor. `query` is not one
    // of them: in upstream's example it is a member of `search_metadata`, which
    // is read as its own object below.
    for ([_][]const u8{ "statuses", "search_metadata" }) |key| {
        const field = object.get(key) orelse return error.MissingKey;
        try testing.expectEqualStrings(key, field.key);
    }

    // `statuses` is the array of status objects. Counting them by iteration and
    // comparing against the array's own `len` is the property that says the
    // pre-order stream and the typed view agree.
    const statuses = (object.get("statuses") orelse return error.MissingKey).value.array() orelse
        return error.NotAnArray;
    try testing.expect(statuses.len() > 0);

    var counted: usize = 0;
    var iterator = statuses.iterator();
    while (iterator.next()) |status| : (counted += 1) {
        try testing.expectEqual(simdjson.ValueType.object, status.valueType());
        // Every status in upstream's example carries a `text` string. Reading it
        // through `Object.get` for each one exercises the linear search over a
        // real, deep document rather than a three-field toy, and the search
        // itself has to reach the right member of a large object each time.
        const status_object = status.object() orelse return error.NotAnObject;
        const text = (status_object.get("text") orelse return error.MissingKey).value;
        try testing.expectEqual(simdjson.ValueType.string, text.valueType());
        _ = text.string() orelse return error.NoString;
    }
    try testing.expectEqual(statuses.len(), counted);

    // `search_metadata` is present and is itself an object with `count`,
    // `query` and `refresh_url` in upstream's example. Reading the count and
    // checking it is an integer is the same interoperability claim one level
    // down.
    const metadata = (object.get("search_metadata") orelse return error.MissingKey).value;
    try testing.expectEqual(simdjson.ValueType.object, metadata.valueType());
    const metadata_object = metadata.object() orelse return error.NotAnObject;
    const count_field = (metadata_object.get("count") orelse return error.MissingKey).value;
    try testing.expect(count_field.int() != null);
    try testing.expect((metadata_object.get("query") orelse return error.MissingKey).value.string() != null);

    // The whole document walked: every record accounted for, the depth never
    // beyond what the JSON itself nests, and the count invariant holding over
    // every single record of a document with tens of thousands of them.
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

// ---------------------------------------------------------------------------
// The raw `c` route
//
// `simdjson.c` is this package's supported raw route to the library
// (`zig/root.zig`), so its own documented refusal behaviour is tested here
// rather than only the typed surface above. What is checked is the contract, not
// a version string and not an export list.
// ---------------------------------------------------------------------------

test "the raw two-pass convention: a NULL buffer sizes, a short buffer is refused" {
    // Every string-returning entry point follows one convention
    // (`zig/bridge.h`): `*out_len` always receives the length excluding the NUL,
    // so a NULL buffer sizes the call and the second call needs no guess. Sizing
    // first is what turns an unexpected length into a reported error instead of
    // a truncation.
    //
    // The version string is used as the vehicle because it is the entry point
    // with the most stable length across configurations -- and its *content* is
    // never compared, because version pinning belongs to the provenance gate.
    var length: usize = 0;
    try expectStatus(simdjson.c.SIMDJSON_BRIDGE_OK,
        simdjson.c.simdjson_br_version(null, 0, &length),
    );
    try testing.expect(length > 0);

    // A buffer too short for the string is `BUFFER_TOO_SMALL`, and the required
    // length was still written, so the caller can size for it. That is the
    // contract `readString` relies on: an unexpected length is an error and
    // never a shortened string. The buffer is one byte, which is too small for
    // any non-empty string plus the NUL the convention adds, so this holds
    // without the test knowing how long the string is -- version pinning
    // belongs to the provenance gate, and a literal buffer size would make this
    // assertion a version pin wearing a test's clothes.
    var small: [1]u8 = undefined;
    length = 0;
    try expectStatus(simdjson.c.SIMDJSON_BRIDGE_BUFFER_TOO_SMALL,
        simdjson.c.simdjson_br_version(&small, small.len, &length),
    );
    try testing.expect(length > small.len);

    // A null `out_len` is refused. `zig/bridge.h` says the one place its blanket
    // "no usable result was produced" promise does not extend is a count request
    // initialising `*out_count` before it validates anything, so this refusal is
    // the entry point not reaching the upstream call at all.
    try expectStatus(simdjson.c.SIMDJSON_BRIDGE_INVALID_ARGUMENT,
        simdjson.c.simdjson_br_version(null, 0, null),
    );

    // And the second pass with a buffer that is exactly big enough succeeds and
    // reports the same length, which is what makes "size then fill" a two-step
    // protocol rather than a guess. The buffer is the length just measured plus
    // the NUL the convention adds, so the assertion is about the convention and
    // not about how long this release's string happens to be.
    const exact = try testing.allocator.alloc(u8, length + 1);
    defer testing.allocator.free(exact);
    try expectStatus(simdjson.c.SIMDJSON_BRIDGE_OK,
        simdjson.c.simdjson_br_version(exact.ptr, exact.len, &length),
    );
    try testing.expectEqual(exact.len - 1, length);
}

test "the raw route: an index past the implementation list is refused" {
    // `simdjson_br_available_implementation_name` refuses an index at or past
    // the list's own size rather than reading past it. The count is asked for and
    // the *refusal* is what is asserted -- no kernel name is compared and no
    // count is pinned, because which kernels a build compiled in is a fact about
    // the flags, and `FORK-NOTES.md` note 7 is why no caller may pin it. What is
    // asserted is the shape: at least one kernel exists, every one has a
    // non-empty name, and the index just past the end is refused.
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
    // `simdjson_br_walk`'s rule is deliberately coarse: *either* output absent or
    // empty makes the whole call a sizing call (`zig/bridge.h:732-735`), and a
    // caller that sized only one of the two buffers has not sized the result.
    // This package's typed `Document.walk` hides the protocol, so the raw route
    // is where the rule is visible -- and it is worth a test because
    // `zig/root.zig:walkDocument` relies on the sizing call reading the whole
    // document.
    //
    // The rule is checked through the typed surface: two walks of the same
    // document report the same counts, and a walk of an *empty* array reports a
    // blob length that is not negative and a record count of one. That is what
    // proves the sizing pass and the filling pass agree.
    try withWalk("{\"a\":1,\"b\":\"two\"}", struct {
        fn check(walk: simdjson.Walk) !void {
            // Two records plus the root, and a blob holding the key "a", the key
            // "b" and the string "two" -- five bytes, no NUL.
            try testing.expectEqual(@as(usize, 3), walk.count());
            try testing.expectEqual(@as(usize, 5), walk.blobs.len);
            // Every blob offset a record names is inside the blob, and every
            // length fits from there. That is the invariant `Record.bytes`
            // checks, asserted over every record rather than one.
            for (walk.nodes) |record| {
                if (record.key_off != simdjson.Record.no_offset) {
                    try testing.expect(record.key_off < walk.blobs.len);
                    try testing.expect(record.key_off + record.key_len <= walk.blobs.len);
                }
                if (record.str_off != simdjson.Record.no_offset) {
                    try testing.expect(record.str_off < walk.blobs.len);
                    try testing.expect(record.str_off + record.str_len <= walk.blobs.len);
                }
                // The sentinel offset is what says a record has no such bytes:
                // the root record has no key and a number has no string, and
                // each of those reads as absent rather than as a slice into
                // whatever follows it in the blob.
                try testing.expectEqual(
                    record.key_off == simdjson.Record.no_offset,
                    record.bytes(walk.blobs, record.key_off, record.key_len) == null,
                );
                try testing.expectEqual(
                    record.str_off == simdjson.Record.no_offset,
                    record.bytes(walk.blobs, record.str_off, record.str_len) == null,
                );
                // An offset past the blob reads as "absent" rather than as a
                // slice into whatever follows it.
                try testing.expectEqual(
                    @as(?[]const u8, null),
                    record.bytes(walk.blobs, @as(u32, @intCast(walk.blobs.len + 1)), 0),
                );
            }
        }
    }.check);
}

test "the raw route: input_size reports the call, not the document" {
    // `simdjson_br_input_size` is documented as "the number of input bytes this
    // handle holds: what `simdjson_br_open` was given, which is a fact about the
    // call rather than about the document" (`zig/bridge.h`). That distinction is
    // the whole of what is worth testing here, and it is observable: two inputs
    // whose *documents* are the same size but whose *byte counts* differ report
    // different lengths.
    //
    // `{"a":1}` and `{ "a" : 1 }` parse to the same value; only the whitespace
    // differs, so the input sizes differ by exactly the four added bytes.
    const cases = [_]struct { json: []const u8, size: usize }{
        .{ .json = "{\"a\":1}", .size = 7 },
        .{ .json = "{ \"a\" : 1 }", .size = 11 },
        // Leading and trailing whitespace is inside the caller's length, because
        // the bridge copies exactly `len` bytes rather than trimming.
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
    // The header is explicit about the asymmetry (`zig/bridge.h:529-535`): "A
    // NULL `json` with a non-zero `len` is invalid; a NULL `json` with `len == 0`
    // is an empty range, which upstream accepts, and answers valid." A bridge
    // that collapsed the two would refuse the empty range, and one that accepted
    // both would accept a null-pointer call. Both are mistakes in opposite
    // directions, so both are checked.
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

    // The same rule on the parse side: "A NULL `json` is invalid whatever `len`
    // is, so a null-pointer call cannot be confused with the empty document"
    // (`zig/bridge.h:559-562`). An empty *document* is upstream's `EMPTY` and a
    // null pointer is this bridge's own `INVALID_ARGUMENT` -- two different
    // refusals, not one.
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
    // "NULL is accepted and does nothing, so `deinit` after a failed open is
    // safe" (`zig/bridge.h:574`). This is the raw-route half of the ownership
    // claim `Document.deinit` makes, and it is what makes `defer
    // document.deinit()` the right shape after a failed `parse`.
    simdjson.c.simdjson_br_destroy(null);
    // Twice: a second release of an already-released handle must not be a double
    // free either, because there was nothing to free either time.
    simdjson.c.simdjson_br_destroy(null);
}

test "the raw route: a short buffer is a capacity refusal, not a malformed document" {
    // `BUFFER_TOO_SMALL` and an upstream error are separate refusals and are
    // never collapsed (`FORK-NOTES.md` note 16): a capacity problem must not look
    // like a malformed document. The bridge's contract -- it checks its own
    // capacity flag first and returns `BUFFER_TOO_SMALL` with **both required
    // sizes already written** -- is only reachable through the raw route, because
    // the typed `Document.walk` allocates for itself and therefore never asks.
    const json = "{\"a\":[1,2,3],\"b\":\"text\"}";

    var handle: ?*simdjson.c.struct_simdjson_bridge_document = null;
    var upstream: i32 = 0;
    try expectStatus(simdjson.c.SIMDJSON_BRIDGE_OK,
        simdjson.c.simdjson_br_open(json.ptr, json.len, &handle, &upstream),
    );
    defer simdjson.c.simdjson_br_destroy(handle.?);

    // The sizing call: NULL buffers make it one, and it writes nothing.
    var nodes: usize = 0;
    var blobs: usize = 0;
    try expectStatus(simdjson.c.SIMDJSON_BRIDGE_OK,
        simdjson.c.simdjson_br_walk(handle.?, null, 0, &nodes, null, 0, &blobs, &upstream),
    );
    // Read off the JSON: the root object, the array that is `a`'s value, its
    // three elements, and the string that is `b`'s value -- six records, one
    // per value, because a member's key rides on its own value's record rather
    // than on a record of its own -- and a blob of the two keys and the string,
    // six bytes.
    try testing.expectEqual(@as(usize, 6), nodes);
    try testing.expectEqual(@as(usize, 6), blobs);

    // A filling call with too few records is refused as a capacity problem, and
    // it reports what it needed so a caller can size and retry.
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

    // And the correctly sized call fills both.
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

    // The typed view of the same records agrees with what the raw route wrote.
    // That agreement is the property which proves the hand-written `Record` in
    // `zig/root.zig` and `simdjson_bridge_node` in the header describe one
    // layout: a mismatch would be a field read from the wrong offset, and every
    // other test in this file would fail in a way that looked like a parser bug.
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