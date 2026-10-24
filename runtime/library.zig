// SPDX-License-Identifier: Apache-2.0
//
//! simdjson-specific ABI and validation for the generic runtime loader.
//! Providers export all eleven bridge functions and match record layout, status values,
//! upstream error values, and two-pass buffer rules. No allocator crosses the ABI.
//! Load checks cover version, implementation names, ASCII/empty UTF-8 ranges, and a parse round trip.
//! Kernel choices vary by provider and host. A different bridge header can change `Record` layout.
const std = @import("std");
const rt = @import("rt");

/// Namespaced synchronization symbols must match `runtime/sync.c`.
/// The generic loader owns no library-specific symbols.
pub const Sync = struct {
    extern fn simdjson_rt_lock() void;
    extern fn simdjson_rt_unlock() void;
    extern fn simdjson_rt_wait() void;
    extern fn simdjson_rt_broadcast() void;
    // `u64` matches `unsigned long long` on every supported ABI.
    extern fn simdjson_rt_thread_self() u64;

    pub fn lock() void {
        simdjson_rt_lock();
    }
    pub fn unlock() void {
        simdjson_rt_unlock();
    }
    pub fn wait() void {
        simdjson_rt_wait();
    }
    pub fn broadcast() void {
        simdjson_rt_broadcast();
    }
    pub fn threadSelf() u64 {
        return simdjson_rt_thread_self();
    }
};

/// Required release string for provider validation.
const expected_version = "5.0.2";

/// Minimal document that exercises record, key, number, and offset fields.
const probe_document = "{\"a\":1}";

/// ASCII input with a malformed number; validation checks it as bytes.
const probe_bad_utf8 = "{\"a\":01}";

/// Bridge success status.
const bridge_ok: u32 = 0;

/// Object record type value.
const probe_object_type: u32 = 2;
/// Number record type value.
const probe_number_type: u32 = 3;
/// Signed number representation value.
const probe_number_signed: u32 = 2;
/// No-offset sentinel.
const no_offset: u32 = 0xFFFFFFFF;

/// C ABI record layout mirrored from `zig/bridge.h`.
/// Keep the layouts aligned; runtime checks cannot prove compatibility.
pub const Record = extern struct {
    depth: u32,
    type: u32,
    count: u32,
    number_type: u32,
    key_off: u32,
    key_len: u32,
    str_off: u32,
    str_len: u32,
    i: i64,
    u: u64,
    d: f64,
};

/// Creates the simdjson-specific loader configuration for a generated dispatch.
pub fn Config(comptime dispatch: type) type {
    return struct {
        /// Library name used in the pre-load panic.
        pub const library_name = "simdjson";

        /// Dispatch table and required/optional provider symbols.
        pub const table = dispatch.Table;
        pub const symbols = dispatch.symbols;
        pub const optional_symbols = dispatch.optional_symbols;

        /// This package's namespaced synchronization binding.
        pub const sync = Sync;

        pub fn tablePtr() *table {
            return dispatch.tablePtr();
        }

        pub fn ready() *rt.Ready {
            return &dispatch.ready;
        }

        pub fn assign(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assign(index, dst, address);
        }

        pub inline fn assignOptional(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assignOptional(index, dst, address);
        }

        pub inline fn assignMissing(comptime index: usize, dst: *table) void {
            dispatch.assignMissing(index, dst);
        }

        /// Validates a provider after symbol resolution and before publication.
        /// Uses local storage and closes its probe document before returning.
        pub fn validate(dst: *const table) ?[]const u8 {
            {
                var len: usize = 0;
                var storage: [8]u8 = undefined;
                // Leave room for a NUL; version comparison rejects longer content.
                const cap = storage.len;
                if (dst.simdjson_br_version(storage[0..cap].ptr, cap, &len) != bridge_ok) {
                    return "simdjson_br_version did not succeed on the sizing " ++
                        "call, so the resolved symbol does not follow the " ++
                        "header's two-pass string convention";
                }
                if (len != expected_version.len) {
                    return "this provider reports a simdjson release whose " ++
                        "version string is not the length this build was " ++
                        "configured against, so its error_code values and its " ++
                        "ondemand record layout are not the ones this module " ++
                        "was generated from";
                }
                if (dst.simdjson_br_version(storage[0..cap].ptr, cap, &len) != bridge_ok) {
                    return "simdjson_br_version did not succeed on the reading " ++
                        "call with the capacity it just reported";
                }
                if (!std.mem.eql(u8, storage[0..len], expected_version)) {
                    return "this provider reports a simdjson release other than " ++
                        "the one this build was configured against, so its " ++
                        "error_code values and its ondemand record layout are " ++
                        "not the ones this module was generated from";
                }
            }

            {
                var len: usize = 0;
                var storage: [16]u8 = undefined;
                const cap = storage.len;
                if (dst.simdjson_br_builtin_implementation(storage[0..cap].ptr, cap, &len) != bridge_ok or len == 0) {
                    return "simdjson_br_builtin_implementation reported no " ++
                        "kernel name, so the resolved provider is not a simdjson " ++
                        "build at all";
                }
            }

            {
                // Require named implementations without pinning provider-specific choices.
                const count = dst.simdjson_br_available_implementation_count();
                if (count == 0) {
                    return "this provider reports no compiled-in simdjson " ++
                        "implementations, so every parse through it would be " ++
                        "answered by the \"unsupported\" implementation";
                }
                var index: usize = 0;
                while (index < count) : (index += 1) {
                    var len: usize = 0;
                    if (dst.simdjson_br_available_implementation_name(index, null, 0, &len) != bridge_ok or len == 0) {
                        return "this provider reported a compiled-in " ++
                            "implementation with no name, so the " ++
                            "SIMDJSON_FORCE_IMPLEMENTATION override cannot be " ++
                            "resolved against its list";
                    }
                }
            }

            {
                // Check ASCII and empty UTF-8 ranges without parsing either as JSON.
                var ok: c_int = -1;
                if (dst.simdjson_br_validate_utf8(probe_bad_utf8.ptr, probe_bad_utf8.len, &ok) != bridge_ok) {
                    return "simdjson_br_validate_utf8 did not succeed on a " ++
                        "byte range it must be able to answer about, so the " ++
                        "resolved symbol does not follow the header's contract";
                }
                if (ok != 1) {
                    return "simdjson_br_validate_utf8 refused {" ++
                        "\"a\":01}, which is pure ASCII, so the resolved " ++
                        "validator is not the one this library's own accepted " ++
                        "documents were checked against";
                }
                if (dst.simdjson_br_validate_utf8(probe_document.ptr, 0, &ok) != bridge_ok or ok != 1) {
                    return "simdjson_br_validate_utf8 did not answer that an " ++
                        "empty byte range is valid UTF-8, which is the answer " ++
                        "upstream's own declaration gives for it";
                }
            }

            {
                // Exercise one open, sizing walk, filling walk, and destroy.
                var doc: ?*dispatch.struct_simdjson_bridge_document = null;
                var error_code: i32 = 0;
                const open = dst.simdjson_br_open(
                    probe_document.ptr,
                    probe_document.len,
                    &doc,
                    &error_code,
                );
                if (open != bridge_ok or doc == null) {
                    return "simdjson_br_open refused the literal document " ++
                        "{\"a\":1}, so the resolved symbols are callable but " ++
                        "the provider behind them is not a working simdjson";
                }
                defer dst.simdjson_br_destroy(doc);
                if (error_code != 0) {
                    return "simdjson_br_open reported success and an error code " ++
                        "at the same time, so its two out-parameters cannot be " ++
                        "trusted";
                }

                var input_len: usize = 0;
                if (dst.simdjson_br_input_size(doc, &input_len) != bridge_ok or
                    input_len != probe_document.len)
                {
                    return "simdjson_br_input_size did not report the length " ++
                        "simdjson_br_open was given, so the handle does not " ++
                        "hold the document it was opened for";
                }

                var node_count: usize = 0;
                var blob_len: usize = 0;
                if (dst.simdjson_br_walk(doc, null, 0, &node_count, null, 0, &blob_len, &error_code) != bridge_ok) {
                    return "the sizing simdjson_br_walk on the literal document " ++
                        "{\"a\":1} did not succeed, so the two-pass walk " ++
                        "convention does not hold across this ABI";
                }
                if (node_count != 2 or blob_len != 1) {
                    return "the sizing simdjson_br_walk on the literal document " ++
                        "{\"a\":1} did not report one object record, one member " ++
                        "record and one key byte, so the record layout this " ++
                        "module was generated from is not the provider's";
                }

                var nodes: [2]Record = undefined;
                var blobs: [1]u8 = undefined;
                if (dst.simdjson_br_walk(
                    doc,
                    @ptrCast(&nodes),
                    nodes.len,
                    &node_count,
                    &blobs,
                    blobs.len,
                    &blob_len,
                    &error_code,
                ) != bridge_ok) {
                    return "the filling simdjson_br_walk on the literal document " ++
                        "{\"a\":1} did not succeed with the capacities the sizing " ++
                        "walk reported, so the two passes cannot be the same walk";
                }
                if (error_code != 0) {
                    return "simdjson_br_walk reported success and an error code " ++
                        "at the same time, so its two out-parameters cannot be " ++
                        "trusted";
                }
                if (nodes[0].depth != 0 or nodes[0].type != probe_object_type or nodes[0].count != 1) {
                    return "the record for the document's root was not an object " ++
                        "with one field at depth 0, so the walk is not walking " ++
                        "what it claims to walk";
                }
                if (nodes[0].key_off != no_offset or nodes[0].str_off != no_offset) {
                    return "the root record reported key or string bytes, which " ++
                        "upstream's absent-offset marker says it cannot have";
                }
                if (nodes[1].depth != 1 or nodes[1].type != probe_number_type) {
                    return "the second record was not a number at depth 1, so " ++
                        "the walk is not visiting a member of the root object";
                }
                if (nodes[1].key_off != 0 or nodes[1].key_len != 1 or
                    blobs[0] != 'a')
                {
                    return "the member record did not carry the one-byte key \"a\", " ++
                        "so the blob offsets and lengths in the record layout " ++
                        "are not the provider's";
                }
                if (nodes[1].number_type != probe_number_signed or
                    nodes[1].i != 1 or nodes[1].u != 0 or nodes[1].d != 0)
                {
                    return "the member record did not carry the signed integer 1, " ++
                        "so the number payload fields of the record layout are " ++
                        "not the provider's";
                }
            }

            return null;
        }
    };
}
