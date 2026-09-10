//! Native-library loading: phases 5 and 7 of the M7 lifecycle.
//!
//! Package discovery and dependency resolution deliberately happen in `mod`, below the
//! engine loop and with no code loading. Once content is live, a host gives this loader the
//! resolved entries. It opens an optional library from each package's own directory, hands it
//! the public table, and preserves its image for the process lifetime. A library that failed
//! to initialise is diagnosed but its package's content remains loaded.
//!
//! Design: docs/design/public-abi.md §13 and §14.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const data = @import("data");
const mod = @import("mod");
const platform = @import("platform");

const api = @import("api.zig");
const host_mod = @import("host.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Diagnostics = data.Diagnostics;
const log = core.log.scoped(.abi);

/// Every public table this build can hand to a native consumer. Kept as a set rather than a
/// hardcoded latest number: additive versions coexist, and a v1-only native mod must remain
/// loadable after v2 arrives in Step 3.
const offered_api_versions = [_]u32{ types.api_version_1, types.api_version_2 };

fn acceptsOffered(range: mod.Range) bool {
    for (offered_api_versions) |version| if (range.accepts(version)) return true;
    return false;
}

/// Apply the host's library-name convention to a manifest's platform-neutral `native`
/// value. A package says `lanterns`, never `liblanterns.dylib`.
pub fn libraryFileNameAlloc(gpa: Allocator, native: []const u8) Allocator.Error![]u8 {
    return switch (builtin.os.tag) {
        .windows => std.fmt.allocPrint(gpa, "{s}.dll", .{native}),
        .macos => std.fmt.allocPrint(gpa, "lib{s}.dylib", .{native}),
        else => std.fmt.allocPrint(gpa, "lib{s}.so", .{native}),
    };
}

/// Kept after init so the optional shutdown callback remains callable. The `Library` value
/// is intentionally never closed in M7: a mod may have placed one of its function pointers
/// in a world component or system, and closing it would turn that into a use-after-unload.
pub const Loaded = struct {
    id: core.ContentId,
    self: types.Mod,
    library: platform.os.Library,
    shutdown: ?types.ModShutdown,
};

/// A loader bound to one table/host type.
pub fn LoaderOf(comptime H: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        host: *H,
        loaded: std.ArrayList(Loaded) = .empty,

        pub fn init(gpa: Allocator, host: *H) Self {
            return .{ .gpa = gpa, .host = host };
        }

        /// Try every code-bearing package in resolved order. Failure is local to the
        /// library: it adds a diagnostic and moves on, preserving Tier 1 content.
        pub fn load(
            self: *Self,
            content_dir: []const u8,
            entries: []const mod.Entry,
            diags: *Diagnostics,
        ) Allocator.Error!void {
            for (entries) |entry| {
                const native = entry.native orelse continue;
                if (entry.script != null) {
                    try report(self.gpa, diags, entry, "names both native and script code; activating both tiers is unsupported", .{});
                    continue;
                }
                if (!mod.manifest.isBareName(native)) {
                    try report(self.gpa, diags, entry, "native library name is not a bare name", .{});
                    continue;
                }
                if (!validPackageRoot(entry.root)) {
                    try report(self.gpa, diags, entry, "package root is not one relative directory", .{});
                    continue;
                }
                const range = entry.abi orelse {
                    try report(self.gpa, diags, entry, "names a native library but declares no ABI range", .{});
                    continue;
                };
                if (!acceptsOffered(range)) {
                    try report(self.gpa, diags, entry, "requires ABI {d} through {d}; this host offers {d} through {d}", .{
                        range.min,
                        range.max orelse std.math.maxInt(u32),
                        offered_api_versions[0],
                        offered_api_versions[offered_api_versions.len - 1],
                    });
                    continue;
                }

                const file = try libraryFileNameAlloc(self.gpa, native);
                defer self.gpa.free(file);
                const path = platform.os.joinPath(self.gpa, &.{ content_dir, entry.root, file }) catch |err| {
                    try report(self.gpa, diags, entry, "could not form its native-library path: {s}", .{@errorName(err)});
                    continue;
                };
                defer self.gpa.free(path);

                // Reserve bookkeeping before opening the image or issuing an identity.
                // After foreign code runs neither can safely be taken back.
                try self.loaded.ensureUnusedCapacity(self.gpa, 1);

                var library = platform.os.Library.open(self.gpa, path) catch |err| {
                    try report(self.gpa, diags, entry, "could not open native library '{s}': {s}", .{ file, @errorName(err) });
                    continue;
                };

                const init_callback = library.symbol(types.ModInit, types.init_symbol) orelse {
                    library.close();
                    try report(self.gpa, diags, entry, "native library has no required symbol '{s}'", .{types.init_symbol});
                    continue;
                };
                const self_handle = self.host.issueMod(entry.id, entry.name) catch |err| {
                    // It was only opened; it has run no code and resolving no callback can
                    // leave a pointer behind, so closing is safe on this refusal path.
                    library.close();
                    switch (err) {
                        error.InvalidArgument => try report(self.gpa, diags, entry, "package identity and name disagree", .{}),
                        error.Limit => try report(self.gpa, diags, entry, "native-mod limit ({d}) reached", .{host_mod.max_mods}),
                    }
                    continue;
                };

                const result_code = init_callback(api.TableOf(H).getApi, self_handle);
                const shutdown_callback = library.symbol(types.ModShutdown, types.shutdown_symbol);
                const result = types.Result.fromCode(result_code);

                // Once init was invoked, the library stays mapped even when it returns an
                // error: a dishonest mod could have registered a callback before returning,
                // and closing its code then would crash the game later. Keep the image in
                // the list, but only a successful init participates in phase 7.
                self.loaded.appendAssumeCapacity(.{
                    .id = entry.id,
                    .self = self_handle,
                    .library = library,
                    // The public contract says nothing else is called after init refuses.
                    // The image still stays mapped because init may already have leaked a
                    // callback into a subsystem, but it is not part of phase 7.
                    .shutdown = if (result == .ok) shutdown_callback else null,
                });

                const known = result orelse {
                    self.host.refuseMod(self_handle);
                    try report(self.gpa, diags, entry, "native init returned unknown result code {d}", .{result_code});
                    continue;
                };
                if (known != .ok) {
                    self.host.refuseMod(self_handle);
                    try report(self.gpa, diags, entry, "native init returned {s}", .{known.name()});
                }
            }
        }

        /// Phase 7. Reverse order is dependency-safe: a dependent stops first while the
        /// package it called into remains alive. Mapping stays in place until process exit.
        pub fn shutdown(self: *Self) void {
            var i = self.loaded.items.len;
            while (i > 0) {
                i -= 1;
                const item = &self.loaded.items[i];
                if (item.shutdown) |callback| callback(item.self);
                item.shutdown = null;
            }
        }

        pub fn deinit(self: *Self) void {
            self.shutdown();
            self.loaded.deinit(self.gpa);
            self.* = undefined;
        }

        fn report(gpa: Allocator, diags: *Diagnostics, entry: mod.Entry, comptime format: []const u8, args: anytype) Allocator.Error!void {
            try diags.addFmt(gpa, .warning, .whole(entry.name), 0, "", format, args);
            log.warn("native mod {s}: " ++ format, .{entry.name} ++ args);
        }
    };
}

fn validPackageRoot(root: []const u8) bool {
    if (!platform.os.isSafeRelativePath(root)) return false;
    if (std.mem.eql(u8, root, ".")) return false;
    return std.mem.indexOfAny(u8, root, "/\\") == null;
}

const testing = std.testing;

test "a native-library name is decorated by the host, not by package content" {
    const name = try libraryFileNameAlloc(testing.allocator, "brighter");
    defer testing.allocator.free(name);
    const expected = switch (builtin.os.tag) {
        .windows => "brighter.dll",
        .macos => "libbrighter.dylib",
        else => "libbrighter.so",
    };
    try testing.expectEqualStrings(expected, name);
}

test "a native library root is exactly one relative package directory" {
    try testing.expect(validPackageRoot("brighter"));
    try testing.expect(validPackageRoot("brighter.v2"));
    try testing.expect(!validPackageRoot(""));
    try testing.expect(!validPackageRoot("."));
    try testing.expect(!validPackageRoot(".."));
    try testing.expect(!validPackageRoot("mods/brighter"));
    try testing.expect(!validPackageRoot("mods\\brighter"));
    try testing.expect(!validPackageRoot("/brighter"));
}

test "native compatibility considers every offered table version" {
    try testing.expect(acceptsOffered(.{ .min = 1, .max = 1 }));
    try testing.expect(acceptsOffered(.{ .min = 2, .max = 2 }));
    try testing.expect(!acceptsOffered(.{ .min = 3 }));
}
