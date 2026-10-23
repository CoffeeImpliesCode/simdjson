// SPDX-License-Identifier: Apache-2.0
//
//! Runtime loader for generated C dispatch modules.
//! Loads an explicit path or system name, resolves symbols, and validates before publication.
//! Failed attempts close the candidate and leave the table unpublished; successful handles stay open.
//! Same-request callers share an attempt. Different providers and reentrant calls fail.
//! Calls before readiness panic; a provider cannot be unloaded or replaced.
//! Provider constructors must not block on another thread waiting in this loader.

const std = @import("std");
const builtin = @import("builtin");

/// Names an explicit path or system-library name. The loader never falls back between forms.
pub const LoadSource = union(enum) {
    /// Absolute file path; relative paths are invalid.
    path: []const u8,
    /// Basename or SONAME; path separators and NUL bytes are invalid.
    system: []const u8,
};

/// Errors returned when `load` declines a request.
pub const LoadError = error{
    /// Empty path or system name.
    EmptySource,
    /// Request exceeds `max_source_len`; it is refused, not truncated.
    SourceTooLong,
    /// Invalid path/name form or embedded NUL; no platform call is made.
    InvalidSource,
    /// Target has no dynamic loader.
    UnsupportedTarget,
    /// Platform loader refused the candidate.
    OpenFailed,
    /// Candidate lacks a required export; it is closed.
    MissingSymbol,
    /// Library-specific validation declined the candidate; it is closed.
    ValidationFailed,
    /// A different request already succeeded or is in flight.
    ProviderMismatch,
    /// The same thread called `load` during its current attempt.
    ReentrantLoad,
};

/// Maximum request length, in bytes.
pub const max_source_len = 32768;

/// Stores the tagged request in fixed process-lifetime storage.
const SourceRecord = struct {
    tag: enum(u8) { none = 0, path, system } = .none,
    len: u32 = 0,
    bytes: [max_source_len]u8 = undefined,

    /// Copies a validated request while the loader lock is held.
    fn set(self: *SourceRecord, request: LoadSource) void {
        const text = switch (request) {
            .path => |p| p,
            .system => |s| s,
        };
        @memcpy(self.bytes[0..text.len], text);
        self.len = @intCast(text.len);
        self.tag = switch (request) {
            .path => .path,
            .system => .system,
        };
    }

    /// Returns the remembered request; its bytes borrow this record.
    pub fn source(self: *const SourceRecord) ?LoadSource {
        const text = self.bytes[0..self.len];
        return switch (self.tag) {
            .none => null,
            .path => .{ .path = text },
            .system => .{ .system = text },
        };
    }
};

/// Compares request kind and bytes without path normalization.
pub fn eqlSource(a: LoadSource, b: LoadSource) bool {
    return switch (a) {
        .path => |pa| switch (b) {
            .path => |pb| std.mem.eql(u8, pa, pb),
            .system => false,
        },
        .system => |sa| switch (b) {
            .system => |sb| std.mem.eql(u8, sa, sb),
            .path => false,
        },
    };
}

fn validateSource(source: LoadSource) LoadError!void {
    const text = switch (source) {
        .path => |p| p,
        .system => |s| s,
    };
    if (text.len == 0) return error.EmptySource;
    if (text.len > max_source_len) return error.SourceTooLong;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidSource;
    switch (source) {
        .path => {
            const absolute = if (builtin.target.os.tag == .windows)
                switch (std.fs.path.getWin32PathType(u8, text)) {
                    .drive_absolute, .unc_absolute, .local_device, .root_local_device => true,
                    .relative, .rooted, .drive_relative => false,
                }
            else
                std.fs.path.isAbsolutePosix(text);
            if (!absolute) return error.InvalidSource;
        },
        .system => {
            for (text) |byte| {
                if (std.fs.path.isSep(byte)) return error.InvalidSource;
                if (builtin.target.os.tag == .windows and byte == ':') return error.InvalidSource;
            }
        },
    }
}

/// The loader table's publication state.
pub const Phase = enum(u8) {
    /// No successful load; a failed attempt can be retried.
    not_loaded = 0,
    /// One thread is filling the table.
    loading = 1,
    /// The table is published and routed calls are usable.
    ready = 2,
};

/// Publishes readiness with release/acquire ordering.
pub const Ready = struct {
    phase: std.atomic.Value(u8) = .init(@backingInt(Phase.not_loaded)),

    /// Checks readiness with acquire ordering.
    pub fn isReady(self: *const Ready) bool {
        return self.phase.load(.acquire) == @backingInt(Phase.ready);
    }

    /// Reads the current state.
    pub fn state(self: *const Ready) Phase {
        return @fromBackingInt(@intCast(self.phase.load(.acquire)));
    }

    /// Publishes a state with release ordering.
    pub fn set(self: *Ready, value: Phase) void {
        self.phase.store(@backingInt(value), .release);
    }
};

/// Kind of required provider export and table value.
pub const SymbolKind = enum {
    /// Function pointer with the translated header's exact type.
    function,
    /// Address of the provider-owned object, never a copy.
    data,
};

/// Required provider export name and kind.
pub const Symbol = struct {
    /// Exported name, as declared by the C header.
    name: [:0]const u8,
    /// Value stored in the dispatch table.
    kind: SymbolKind,
};

/// Panics with the library and symbol name when called before a successful load.
pub fn panicNotReady(library: []const u8, comptime symbol: []const u8) noreturn {
    std.debug.panic(
        "{s}: {s} was called before this module was loaded; call " ++
            "load({{ .path = \"...\" }}) or load({{ .system = \"...\" }}) first",
        .{ library, symbol },
    );
}

/// Whether the target has a dynamic loader; false for WASI, Emscripten, and freestanding.
pub const supported_target: bool = switch (builtin.target.os.tag) {
    .wasi, .emscripten, .freestanding => false,
    else => true,
};

/// Creates the loader type for one dispatch from `Config`'s table, symbols, sync, and optional validation.
/// `load` returns `LoadError`; successful provider handles stay open for process lifetime.
pub fn Loader(comptime Config: type) type {
    return struct {
        const LoaderType = @This();

        /// Table type supplied by the configuration.
        pub const table_type = Config.table;

        /// Current attempt, retained until its waiters have taken the result.
        attempt: ?Attempt = null,

        /// Request copy, immutable after publication.
        request: SourceRecord = .{},

        /// Copies the request, resolves and validates a provider, then publishes the table.
        /// Returns `LoadError` on refusal; successful handles remain open for process lifetime.
        pub fn load(self: *LoaderType, source: LoadSource) LoadError!void {
            try validateSource(source);
            // A ready same-request call needs one acquire load and no lock.
            if (Config.ready().isReady()) return self.accept(source);

            Config.sync.lock();
            while (true) {
                switch (Config.ready().state()) {
                    .ready => {
                        Config.sync.unlock();
                        return self.accept(source);
                    },
                    .loading => {
                        const attempt = &self.attempt.?;
                        if (attempt.owner == Config.sync.threadSelf()) {
                            Config.sync.unlock();
                            return error.ReentrantLoad;
                        }
                        if (!eqlSource(self.request.source().?, source)) {
                            Config.sync.unlock();
                            return error.ProviderMismatch;
                        }
                        // Join this attempt and return its result.
                        attempt.waiters += 1;
                        while (Config.ready().state() == .loading) Config.sync.wait();
                        const result = attempt.result;
                        attempt.waiters -= 1;
                        // Retain the result until every waiter has read it.
                        Config.sync.broadcast();
                        Config.sync.unlock();
                        return result;
                    },
                    .not_loaded => {
                        // Drain waiters before starting a retry.
                        if (self.attempt != null) {
                            Config.sync.wait();
                            continue;
                        }
                        break;
                    },
                }
            }

            self.request.set(source);
            self.attempt = .{ .owner = Config.sync.threadSelf() };
            Config.ready().set(.loading);
            Config.sync.unlock();

            // Run provider constructors without holding the loader lock.
            const outcome = runAttempt(self.request.source().?);
            const succeeded = if (outcome) |_| true else |_| false;

            Config.sync.lock();
            self.attempt.?.result = outcome;
            Config.ready().set(if (succeeded) .ready else .not_loaded);
            // Wake all waiters attached to this attempt.
            Config.sync.broadcast();
            // Keep the attempt record until all waiters leave.
            while (self.attempt.?.waiters > 0) Config.sync.wait();
            self.attempt = null;
            // Wake threads waiting to start a retry.
            Config.sync.broadcast();
            Config.sync.unlock();

            return outcome;
        }

        /// Returns the retained request, or null if no load succeeded.
        pub fn loadedSource(self: *const LoaderType) ?LoadSource {
            if (!Config.ready().isReady()) return null;
            return self.request.source();
        }

        /// Compares a new request with the published provider.
        fn accept(self: *const LoaderType, source: LoadSource) LoadError!void {
            // Read the request only after the acquire readiness check.
            const published = self.request.source() orelse unreachable;
            if (eqlSource(published, source)) return;
            return error.ProviderMismatch;
        }

        /// Opens, resolves, and validates a candidate without holding the lock.
        /// Closes its handle unless the attempt succeeds.
        fn runAttempt(source: LoadSource) LoadError!void {
            const handle = platform.open(source) catch |err| return err;

            var retain = false;
            defer if (!retain) platform.close(handle);

            if (@hasDecl(Config, "optional_symbols")) {
                inline for (Config.optional_symbols, 0..) |_, index| {
                    Config.assignMissing(index, Config.tablePtr());
                }
            }

            inline for (Config.symbols, 0..) |symbol, index| {
                const address = platform.lookup(handle, symbol.name) orelse
                    return error.MissingSymbol;
                Config.assign(index, Config.tablePtr(), address);
            }

            if (@hasDecl(Config, "optional_symbols")) {
                inline for (Config.optional_symbols, 0..) |symbol, index| {
                    if (platform.lookup(handle, symbol.name)) |address| {
                        Config.assignOptional(index, Config.tablePtr(), address);
                    }
                }
            }

            if (@hasDecl(Config, "validate")) {
                if (Config.validate(Config.tablePtr())) |refusal| {
                    // Report the library-specific refusal before closing the candidate.
                    std.debug.print("{s}: refusing this provider: {s}\n", .{
                        Config.library_name,
                        refusal,
                    });
                    return error.ValidationFailed;
                }
            }

            // Retain the handle while table pointers refer into it.
            retain = true;
        }
    };
}

// Platform loader backends.

/// One in-flight attempt or undrained result.
const Attempt = struct {
    /// Thread running the attempt, used to detect reentrancy.
    owner: u64,
    /// Result published under lock before waiters are woken.
    result: LoadError!void = error.OpenFailed,
    /// Waiters that must consume the result before this record is cleared.
    waiters: usize = 0,
};

/// Maximum path capacity in UTF-16 code units for the Windows loader.
const windows_path_units = 32768;

const platform = if (builtin.target.os.tag == .windows)
    Windows
else if (supported_target)
    Unix
else
    NoLoader;

/// Backend for targets without a dynamic loader.
const NoLoader = struct {
    const OpenError = error{ OpenFailed, UnsupportedTarget };

    fn open(source: LoadSource) OpenError!*anyopaque {
        _ = source;
        return error.UnsupportedTarget;
    }
    fn lookup(handle: *anyopaque, name: [:0]const u8) ?*const anyopaque {
        _ = handle;
        _ = name;
        return null;
    }
    fn close(handle: *anyopaque) void {
        _ = handle;
    }
};

/// Unix dynamic loader backend.
const Unix = struct {
    const OpenError = error{ OpenFailed, UnsupportedTarget };

    fn open(source: LoadSource) OpenError!*anyopaque {
        const text = switch (source) {
            .path => |p| p,
            .system => |s| s,
        };
        var buffer: [max_source_len + 1]u8 = undefined;
        @memcpy(buffer[0..text.len], text);
        buffer[text.len] = 0;
        // Use NOW to report missing dependencies here and LOCAL to avoid global symbol leakage.
        return std.c.dlopen(
            // Pass dlopen a sentinel-terminated path.
            buffer[0..text.len :0].ptr,
            .{ .NOW = true, .GLOBAL = false },
        ) orelse error.OpenFailed;
    }

    fn lookup(handle: *anyopaque, name: [:0]const u8) ?*const anyopaque {
        return std.c.dlsym(handle, name.ptr);
    }

    fn close(handle: *anyopaque) void {
        _ = std.c.dlclose(handle);
    }
};

/// Windows loader bindings from `kernel32`.
const kernel32 = struct {
    extern "kernel32" fn LoadLibraryExW(
        file_name: [*:0]const u16,
        file: ?*anyopaque,
        flags: u32,
    ) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(module: *anyopaque) callconv(.winapi) i32;
};

/// Windows dynamic loader backend.
const Windows = struct {
    const OpenError = error{ OpenFailed, UnsupportedTarget, SourceTooLong };

    /// Search standard directories without adding the current directory.
    const load_library_search_default_dirs: u32 = 0x0000_1000;
    const load_library_search_dll_load_dir: u32 = 0x0000_0100;

    fn open(source: LoadSource) OpenError!*anyopaque {
        const text = switch (source) {
            .path => |p| p,
            .system => |s| s,
        };
        if (text.len > windows_path_units) return error.SourceTooLong;
        var buffer: [windows_path_units + 1]u16 = undefined;
        const units = std.unicode.utf8ToUtf16Le(buffer[0..text.len], text) catch
            return error.OpenFailed;
        buffer[units] = 0;
        return kernel32.LoadLibraryExW(
            buffer[0..units :0],
            null,
            load_library_search_default_dirs | switch (source) {
                .path => load_library_search_dll_load_dir,
                .system => @as(u32, 0),
            },
        ) orelse error.OpenFailed;
    }

    fn lookup(handle: *anyopaque, name: [:0]const u8) ?*const anyopaque {
        return kernel32.GetProcAddress(handle, name.ptr);
    }

    fn close(handle: *anyopaque) void {
        _ = kernel32.FreeLibrary(handle);
    }
};
