// SPDX-License-Identifier: Apache-2.0
//
//! simdjson's side of the runtime loader: the names its synchronization binding
//! has, and what it requires of a provider beyond resolving its symbols.
//!
//! Everything else about the runtime route is generic. `runtime/loader.zig` is
//! the state machine and the platform layer; `runtime/generate.zig` builds the
//! dispatch from whatever the translation step actually produced;
//! `runtime/graph.zig` wires them together. This file is what makes them
//! simdjson's, and it is the file another SDK replaces.
//!
//! ## What a provider must be
//!
//! A shared object exporting all eleven entry points this fork's C ABI declares
//! (`build_support/graph.zig:bridge_abi_symbols`), and nothing else is
//! required:
//!
//!   * `simdjson_br_version` — `zig/bridge.h:409-410`;
//!   * `simdjson_br_builtin_implementation` — `zig/bridge.h:439-440`;
//!   * `simdjson_br_active_implementation` — `zig/bridge.h:479-480`;
//!   * `simdjson_br_active_implementation_description` — `zig/bridge.h:485-487`;
//!   * `simdjson_br_available_implementation_count` — `zig/bridge.h:504`;
//!   * `simdjson_br_available_implementation_name` — `zig/bridge.h:514-515`;
//!   * `simdjson_br_validate_utf8` — `zig/bridge.h:529-530`;
//!   * `simdjson_br_open` — `zig/bridge.h:566-568`;
//!   * `simdjson_br_destroy` — `zig/bridge.h:574`;
//!   * `simdjson_br_input_size` — `zig/bridge.h:578-579`;
//!   * `simdjson_br_walk` — `zig/bridge.h:650-657`.
//!
//! That is the whole externally linked ABI this package publishes, so it is
//! also the whole of the generated table: eleven fields, all functions, no data
//! symbol, and therefore no `NAMEAddr()` accessor and nothing to keep live as
//! an address.
//!
//! ## The ABI boundary, stated honestly
//!
//! The boundary is the C ABI this fork declares, and it is narrow. What a
//! provider has to match is:
//!
//!   * **The record layout of `simdjson_bridge_node`** (`zig/bridge.h:319-367`).
//!     Its fields are eight `uint32_t` and one each of `int64_t`, `uint64_t` and
//!     `double`, so its size and alignment are fixed by the C ABI on every
//!     target this SDK builds for, and the argument order of `simdjson_br_walk`
//!     is likewise fixed. A provider compiled against a *different*
//!     `zig/bridge.h` could lay that struct out differently, and nothing at run
//!     time can detect it.
//!   * **The status values**, which are `0` through `4`
//!     (`zig/bridge.h:127-148`) and are pinned by the `static_assert` block at
//!     the end of `zig/bridge.cc`, checked by the C++ compiler on every target
//!     that builds the bridge.
//!   * **The upstream error values** carried in `out_error`, which are
//!     `simdjson::error_code`'s own integers
//!     (`src/include/simdjson/error.h:19-54`) and are pinned the same way.
//!   * **The out-parameter convention of every two-pass entry point**: on
//!     `SIMDJSON_BRIDGE_OK` both counts are the true sizes, and on
//!     `SIMDJSON_BRIDGE_BUFFER_TOO_SMALL` both are still the true sizes and
//!     neither buffer is written. That is the part that is easy to get wrong
//!     and is therefore what the checks below exercise.
//!   * **No allocator crossing.** The bridge's own allocations are upstream's
//!     `padded_string` and `std::string`, and every one of them is freed inside
//!     the provider — `simdjson_br_destroy` is the only free a caller can reach.
//!     A caller never receives a pointer the provider allocated, so no allocator
//!     has to be shared with it and the two halves of a process need not agree
//!     about one.
//!
//! Two things are deliberately *not* compatibility requirements and are
//! therefore not checked:
//!
//!   * **Which SIMD kernel the provider compiled.**
//!     `simdjson_br_builtin_implementation` reports it and it is a fact about
//!     the provider's build, not about this ABI; a `fallback` provider and an
//!     `arm64` provider both export the same eleven symbols and are equally
//!     usable. The check below reads it only to prove the string is non-empty.
//!   * **Which kernel the provider's runtime dispatcher selected.**
//!     `simdjson_br_active_implementation` is a property of the machine the
//!     provider runs on *and* of the `SIMDJSON_FORCE_IMPLEMENTATION` environment
//!     variable (`src/implementation.cpp:296-312`), so no expected value could
//!     honestly be stated for it. The check below proves only that every
//!     available implementation has a non-empty name.
//!
//! ## What is checked at load time, and what is not
//!
//! Resolving a symbol and translating a header are the boundary. They are not
//! proof that a provider is compatible. Five groups of calls are made after
//! every symbol resolved and before anything is published, and all of them are
//! on this ABI's own example data:
//!
//!   * `simdjson_br_version` must report exactly the release string this build
//!     was configured against — `SIMDJSON_VERSION` read out of
//!     `src/include/simdjson/simdjson_version.h:7`, and the same string
//!     `build.zig.zon .version` and `build.zig` agree on. A provider built from a
//!     different simdjson release has different `error_code` values and a
//!     possibly different record reader, so this is the one check that can catch
//!     a version skew before a document is parsed.
//!   * `simdjson_br_builtin_implementation` must report a non-empty name. That
//!     is all that is checkable about it without pinning a target-specific
//!     answer.
//!   * `simdjson_br_available_implementation_count` must be at least 1, and
//!     every name in the list must be non-empty. That list is what
//!     `SIMDJSON_FORCE_IMPLEMENTATION` is resolved against
//!     (`src/implementation.cpp:299-306`), so an empty or nameless list would
//!     make that override latch onto the `"unsupported"` implementation and fail
//!     every later parse.
//!   * `simdjson_br_validate_utf8` must agree with the parser on a byte range
//!     the parser has already accepted and on one it has already refused, which
//!     is the only way to observe that the provider is answering from the same
//!     stage-1 validator rather than from a stub.
//!   * `simdjson_br_open` on the literal `{"a":1}` must succeed, one sizing
//!     `simdjson_br_walk` must report exactly two records and a blob of exactly
//!     one byte, and one filling walk with those exact capacities must produce
//!     the object record followed by the member record with key `a`, type
//!     number, `number_type` signed and value 1.
//!
//! Together those say the resolved symbols are callable with this header's
//! calling convention, that the record layout and the two-pass convention agree
//! across the boundary, and that the provider really is a working simdjson parse
//! of the document it was asked about. They are checks that the entry points
//! *behave*. They are not, and cannot be, a check of anything the caller and the
//! provider must have compiled from the same header — which is the only thing
//! that could rule out a provider built against a different `zig/bridge.h` with
//! a different record layout. That gap is inherent to a C ABI over a struct this
//! package hands out, and it is why `Record` below is a hand-written duplicate
//! of the header's struct rather than an import.
const std = @import("std");
const rt = @import("rt");

/// The synchronization this loader calls, bound by exact name.
///
/// The names below are `runtime/sync.h` compiled with
/// `RT_SYNC_PREFIX=simdjson_rt`, which is what `runtime/graph.zig` passes. Two
/// spellings of that prefix have to agree: this file names the symbols, and
/// graph.zig defines the macro. A build where they disagree does not link, and
/// that is the whole error report: there is no runtime path that could hide it.
///
/// The core in `runtime/loader.zig` never names a symbol of its own, which is
/// what lets two SDKs, or two configurations of one SDK, hold their own loader
/// state in one process without sharing any of it.
pub const Sync = struct {
    extern fn simdjson_rt_lock() void;
    extern fn simdjson_rt_unlock() void;
    extern fn simdjson_rt_wait() void;
    extern fn simdjson_rt_broadcast() void;
    // `unsigned long long`. Declared as u64, which is the same type in every
    // ABI this SDK targets: 64-bit on x86_64, aarch64, riscv64 and wasm32.
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

/// The release string this build was configured against.
///
/// It has to be the same string the compiled library reports, because
/// `zig/bridge.h`'s `simdjson_br_version` exists precisely so a loaded provider
/// can be asked (`zig/bridge.h:395-410`) and comparing the two is the only
/// version check that can run before a document is parsed. Upstream writes that
/// string into `src/include/simdjson/simdjson_version.h:7` and
/// `src/CMakeLists.txt:31-33` says in terms that `tools/release.py` rewrites the
/// numbers beside it, so this constant, that header, `build.zig.zon .version`
/// and the installed `simdjson.pc` are all one fact; `build.zig` refuses to
/// configure if the manifest and the header stop agreeing.
const expected_version = "5.0.2";

/// The document every load-time parse check uses.
///
/// A two-record document with one byte of blob, which is the smallest shape
/// that exercises every part of the record layout at once: the container record
/// (`SIMDJSON_BRIDGE_TYPE_OBJECT`, `count == 1`), the member record
/// (`SIMDJSON_BRIDGE_TYPE_NUMBER`, `number_type` signed), the key blob
/// (`key_off == 0`, `key_len == 1`, `blobs[0] == 'a'`) and the absent-offset
/// markers on the container (`key_off == str_off == SIMDJSON_BRIDGE_NO_OFFSET`).
/// Nothing about the sizes is a coincidence of length: two records because there
/// is one object and one member, and one blob byte because there is one one-byte
/// key and no string values.
const probe_document = "{\"a\":1}";

/// A byte range the parser accepts, and one it refuses, both already read out of
/// this package's fixture corpus so the two halves of the check cannot be
/// mistaken for one implementation's opinion.
///
/// The refused range is `{"a":01}`: RFC 8259 §6 forbids a leading zero, and
/// upstream's own number parser refuses it with `NUMBER_ERROR`
/// (`src/include/simdjson/generic/numberparsing.h:906,919`). The accepted range
/// is the whole object `{"a":1}` reduced to nothing: an empty byte range is
/// valid UTF-8 and is not refused by `simdjson::validate_utf8`
/// (`src/include/simdjson/implementation.h:18`).
const probe_bad_utf8 = "{\"a\":01}";

/// `SIMDJSON_BRIDGE_OK` (`zig/bridge.h:129`).
const bridge_ok: u32 = 0;

/// `SIMDJSON_BRIDGE_TYPE_OBJECT` (`zig/bridge.h:269`).
const probe_object_type: u32 = 2;
/// `SIMDJSON_BRIDGE_TYPE_NUMBER` (`zig/bridge.h:272`).
const probe_number_type: u32 = 3;
/// `SIMDJSON_BRIDGE_NUMBER_SIGNED` (`zig/bridge.h:293`).
const probe_number_signed: u32 = 2;
/// `SIMDJSON_BRIDGE_NO_OFFSET` (`zig/bridge.h:304`).
const no_offset: u32 = 0xFFFFFFFF;

/// The provider's `simdjson_bridge_node`, laid out by hand.
///
/// This is a deliberate duplicate of `zig/bridge.h:319-367` and it is the one
/// place in the runtime route where a layout change has to be mirrored by hand.
/// It cannot be avoided by importing the translated header: this module is
/// compiled into the dispatch, and the dispatch is what the translation's
/// patched root imports back, so an import here would be a cycle.
///
/// The duplication is exactly what the parse check in `validate` exists to
/// catch. If the two layouts ever differ, that check fails and says so, rather
/// than a caller reading a plausible wrong answer out of the wrong bytes.
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

/// The loader's configuration for this SDK, given the dispatch that owns the
/// table.
///
/// `dispatch` is the generated module, passed as a type by the dispatch itself
/// so that this file never has to import it. The direction is one-way on
/// purpose: the descriptor knows what the loader needs, the dispatch knows what
/// the header said, and neither imports the other.
pub fn Config(comptime dispatch: type) type {
    return struct {
        /// Named in the pre-load panic, so the message says which library was
        /// reached for before it was loaded.
        pub const library_name = "simdjson";

        /// The table the generated dispatch declares, and the symbols it needs
        /// to fill it. Both come from the translated header, not from this file.
        pub const table = dispatch.Table;
        pub const symbols = dispatch.symbols;
        pub const optional_symbols = dispatch.optional_symbols;

        /// The project's namespaced synchronization binding.
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

        /// The library-specific checks, run after every symbol resolved and
        /// before anything is published.
        ///
        /// Every call below writes into a local of this function and reads a
        /// stack-allocated string. Nothing here allocates, takes a lock, touches
        /// a process global, or leaves anything behind: the one handle it opens is
        /// destroyed before this returns, on every path, because a check that
        /// leaked a document would make every later `load` in the same process
        /// behave differently depending on whether one had run.
        ///
        /// A failure message is a string literal. Every number involved is a
        /// compile-time constant of this file, so nothing is formatted, nothing
        /// is buffered, and there is no allocation whose lifetime this file would
        /// have to argue about.
        pub fn validate(dst: *const table) ?[]const u8 {
            {
                var len: usize = 0;
                var storage: [8]u8 = undefined;
                // "5.0.2" is five characters; eight leaves room for the NUL and
                // for a longer release string, which this check would then
                // refuse on its content rather than on its length.
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
                // The available list is what SIMDJSON_FORCE_IMPLEMENTATION is
                // resolved against (`src/implementation.cpp:299-306`), so a list
                // that is empty or that carries a nameless entry would make that
                // override latch onto the "unsupported" implementation and fail
                // every later parse with UNSUPPORTED_ARCHITECTURE. Both are
                // checked; neither is pinned to a value, because the value
                // depends on which kernels the provider's build compiled in.
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
                // The UTF-8 validator, asked twice: once about bytes that are
                // valid UTF-8 and once about bytes that are not. Without the
                // second call a provider whose validator answers "always valid"
                // would pass, and that is the failure this is here for.
                //
                // The bytes are `{"a":01}` and an empty range. Neither is a
                // document this check parses, so the check is about the
                // validator alone: `simdjson_br_validate_utf8` is a virtual on
                // the active implementation
                // (`src/include/simdjson/implementation.h:18,128`), and an
                // implementation that answered "valid" for a lone `0x01`-free
                // but otherwise arbitrary range would still be wrong for the
                // overlong and surrogate forms this package does not hand it.
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
                // The parse check. One open, one sizing walk, one filling walk,
                // one destroy, in that order with nothing between them that can
                // fail: the point is to observe a complete round trip through
                // every routed entry point that matters.
                var doc: ?*anyopaque = null;
                var error: i32 = 0;
                const open = dst.simdjson_br_open(
                    probe_document.ptr,
                    probe_document.len,
                    &doc,
                    &error,
                );
                if (open != bridge_ok or doc == null) {
                    return "simdjson_br_open refused the literal document " ++
                        "{\"a\":1}, so the resolved symbols are callable but " ++
                        "the provider behind them is not a working simdjson";
                }
                defer dst.simdjson_br_destroy(doc);
                if (error != 0) {
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
                if (dst.simdjson_br_walk(doc, null, 0, &node_count, null, 0, &blob_len, &error) != bridge_ok) {
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
                    &error,
                ) != bridge_ok) {
                    return "the filling simdjson_br_walk on the literal document " ++
                        "{\"a\":1} did not succeed with the capacities the sizing " ++
                        "walk reported, so the two passes cannot be the same walk";
                }
                if (error != 0) {
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