//! Finding out what is installed.
//!
//! Opens every `.fpk` in a directory, reads each one's manifest, and hands back the list.
//! Nothing is merged, nothing is loaded, and no engine exists yet — a launcher can do
//! exactly this much and then show a list (`public-abi.md` §13, phase 1).
//!
//! **A bad package is a diagnostic and a skipped candidate**, never a failure to look. A
//! directory a player has been dropping files into will contain something that is not a
//! package sooner or later, and the correct response is to say which file and carry on.
//!
//! Design: `docs/design/public-abi.md` §12.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");

const manifest_mod = @import("manifest.zig");

const Allocator = std.mem.Allocator;
const Diagnostics = data.Diagnostics;
const Manifest = manifest_mod.Manifest;
const Os = platform.os.Os;

const log = core.log.scoped(.mod);

pub const extension = ".fpk";

pub const Options = struct {
    limits: data.Limits = .default,
    /// Bound on one compiled package, matching `app.Config.max_package_bytes`. Generous,
    /// because a package is records rather than payloads.
    max_package_bytes: usize = 64 << 20,
};

/// One installed package: what it says about itself, and where its two halves are.
///
/// `file` and `root` are relative to the directory that was searched, and are exactly the
/// pair `app.Config.content` takes — which is the point. `mod` computes an order; it does
/// not load anything, and it hands its answer to the thing that does.
pub const Candidate = struct {
    manifest: Manifest,
    /// The compiled package, e.g. `core.fpk`.
    file: []const u8,
    /// Where the files its asset records name live, e.g. `core`. Derived from the `.fpk`'s
    /// own name, so a package is one file and one directory beside it and there is nothing
    /// further to configure.
    root: []const u8,
};

/// Everything found, owning its strings.
pub const Discovery = struct {
    arena: core.Arena,
    candidates: []const Candidate = &.{},

    pub fn deinit(self: *Discovery) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The candidate with this id, or null. Linear, because the list is short and a map
    /// would be a second structure to keep correct for no measurable gain.
    pub fn find(self: *const Discovery, id: core.ContentId) ?*const Candidate {
        for (self.candidates) |*c| if (c.manifest.id.eql(id)) return c;
        return null;
    }
};

/// Reads every package in `dir`.
///
/// Returns an empty discovery if the directory does not exist, which is the ordinary case
/// for a user mod directory nobody has put anything in yet.
pub fn discover(
    gpa: Allocator,
    os: *Os,
    dir: []const u8,
    options: Options,
    diags: *Diagnostics,
) Allocator.Error!Discovery {
    var out: Discovery = .{ .arena = .init(gpa) };
    errdefer out.arena.deinit();
    const arena = out.arena.allocator();

    var listing = os.listDir(gpa, dir) catch |err| {
        // Not having a mod directory is not a problem to report; not being able to read
        // one that exists is.
        if (err != error.FileNotFound) {
            try diags.addFmt(gpa, .warning, .whole(dir), 0, "", "could not be listed: {s}", .{@errorName(err)});
        }
        return out;
    };
    defer listing.deinit();

    // **Sorted before anything is opened.** A directory listing is in whatever order the
    // filesystem felt like, and every answer downstream of this has to be a function of
    // the packages and not of the disk (I9).
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    for (listing.entries) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, extension)) continue;
        try names.append(gpa, entry.name);
    }
    std.mem.sort([]const u8, names.items, {}, lessByName);

    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(gpa);

    for (names.items) |file_name| {
        const path = platform.os.joinPath(gpa, &.{ dir, file_name }) catch |err| {
            try diags.addFmt(gpa, .warning, .whole(file_name), 0, "", "path could not be built: {s}", .{@errorName(err)});
            continue;
        };
        defer gpa.free(path);

        const bytes = os.readFile(gpa, path, options.max_package_bytes) catch |err| {
            try diags.addFmt(gpa, .warning, .whole(file_name), 0, "", "could not be read: {s}", .{@errorName(err)});
            continue;
        };
        defer gpa.free(bytes);

        var reader = data.fpk.Reader.open(gpa, bytes, options.limits) catch |err| {
            try diags.addFmt(gpa, .warning, .whole(file_name), 0, "", "is not a readable package: {s}", .{@errorName(err)});
            continue;
        };
        defer reader.deinit();

        const m = manifest_mod.read(arena, &reader) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try diags.addFmt(gpa, .warning, .whole(file_name), 0, "", "has no usable manifest: {s}", .{@errorName(err)});
                continue;
            },
        };

        const stem = file_name[0 .. file_name.len - extension.len];
        try candidates.append(gpa, .{
            .manifest = m,
            .file = try arena.dupe(u8, file_name),
            .root = try arena.dupe(u8, stem),
        });
        log.debug("found {s} version {d} in {s}", .{ m.id_name, m.version, file_name });
    }

    out.candidates = try arena.dupe(Candidate, candidates.items);
    return out;
}

fn lessByName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

test "a directory that is not there yields nothing and says nothing" {
    var os = try Os.init(testing.allocator, .{});
    defer os.deinit();

    var diags: Diagnostics = .init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);

    var found = try discover(testing.allocator, os, "no-such-directory-for-mods", .{}, &diags);
    defer found.deinit();

    try testing.expectEqual(@as(usize, 0), found.candidates.len);
    // A user mod directory that has never been created is the ordinary case, not a
    // complaint worth making on every start.
    try testing.expectEqual(@as(usize, 0), diags.count());
}

test "sorting happens on names, so the answer does not depend on the filesystem" {
    var names = [_][]const u8{ "z.fpk", "a.fpk", "m.fpk" };
    std.mem.sort([]const u8, &names, {}, lessByName);
    try testing.expectEqualStrings("a.fpk", names[0]);
    try testing.expectEqualStrings("m.fpk", names[1]);
    try testing.expectEqualStrings("z.fpk", names[2]);
}
