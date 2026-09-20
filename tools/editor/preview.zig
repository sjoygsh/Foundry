//! Host-owned preview publication (`docs/design/editor.md` §11).
//!
//! **Loading a build is the host's policy, never a client capability.**  The client asks
//! through `author_preview_activate`; the service hands *this* code the confined candidate
//! names it chose, and nothing else.  A path never crosses the table in either direction.
//!
//! Candidate bytes are read beneath the granted output root, resolved with ordinary
//! `mod.resolve` and loaded into a *fresh* registry and store.  Only once every package has
//! loaded does the new publication replace the old one, so a candidate that fails leaves
//! whatever was loaded before exactly where it was.
//!
//! It lives beside `main.zig` rather than inside it because the editor's own workflow test
//! is a different module and needs the same publication path: a preview the test exercised
//! and the application did not would prove nothing about the application.

const std = @import("std");
const author = @import("author");
const core = @import("core");
const data = @import("data");
const mod = @import("mod");
const platform = @import("platform");

const log = core.log.scoped(.editor);

pub const max_package_bytes = 16 * 1024 * 1024;
pub const max_total_bytes = 64 * 1024 * 1024;

/// One host-owned preview publication.
pub const State = struct {
    gpa: std.mem.Allocator,
    os: *platform.os.Os,
    active: ?*Loaded = null,
    generation: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, os: *platform.os.Os) State {
        return .{ .gpa = gpa, .os = os };
    }

    pub fn deinit(self: *State) void {
        if (self.active) |loaded| loaded.destroy(self.gpa);
        self.* = undefined;
    }

    /// The `author.PreviewGrant` callback.  Returning null is a decline, which the service
    /// reports as `PreviewRefused` and which leaves the previous publication loaded.
    pub fn activate(ctx: ?*anyopaque, request: author.PreviewRequest) ?author.Publication {
        const self: *State = @ptrCast(@alignCast(ctx orelse return null));
        const next = Loaded.create(self.gpa, self.os, request) catch |err| {
            log.warn("preview candidate was refused ({t})", .{err});
            return null;
        };
        const previous = self.active;
        self.active = next;
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        if (previous) |old| old.destroy(self.gpa);
        return .{
            .content_generation = self.generation,
            .store = &next.store,
            .registry = &next.registry,
        };
    }
};

pub const Loaded = struct {
    bytes: [][]u8,
    ids: []core.ContentId,
    registry: data.Registry,
    store: data.Store,

    fn create(
        gpa: std.mem.Allocator,
        os: *platform.os.Os,
        request: author.PreviewRequest,
    ) !*Loaded {
        const count: usize = @as(usize, request.dependency_count) + 1;
        const self = try gpa.create(Loaded);
        errdefer gpa.destroy(self);
        self.* = .{
            .bytes = try gpa.alloc([]u8, count),
            .ids = try gpa.alloc(core.ContentId, count),
            .registry = .init(gpa, .default),
            .store = .init(gpa, .default),
        };
        var read_count: usize = 0;
        errdefer {
            self.store.deinit(gpa);
            self.registry.deinit(gpa);
            for (self.bytes[0..read_count]) |bytes| gpa.free(bytes);
            gpa.free(self.ids);
            gpa.free(self.bytes);
        }

        var arena: core.Arena = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const candidates = try a.alloc(mod.Candidate, count);
        const enabled = try a.alloc(core.ContentId, count);
        const labels = try a.alloc([]const u8, count);
        var total: usize = 0;

        for (0..request.dependency_count) |index| {
            const path = try std.fmt.allocPrint(a, "{s}/dependencies/{d}/package.fpk", .{ request.candidate, index });
            try readCandidate(gpa, os, request.output_root, path, &self.bytes[index], &total);
            read_count += 1;
            var reader = try data.fpk.Reader.open(gpa, self.bytes[index], .default);
            defer reader.deinit();
            const manifest = try mod.manifest.read(a, &reader);
            self.ids[index] = manifest.id;
            enabled[index] = manifest.id;
            labels[index] = path;
            candidates[index] = .{
                .manifest = manifest,
                .base_dir = request.output_root,
                .file = path,
                .root = "",
                .origin = .installed,
            };
        }

        const own = count - 1;
        try readCandidate(gpa, os, request.output_root, request.package, &self.bytes[own], &total);
        read_count += 1;
        var own_reader = try data.fpk.Reader.open(gpa, self.bytes[own], .default);
        defer own_reader.deinit();
        const own_manifest = try mod.manifest.read(a, &own_reader);
        self.ids[own] = own_manifest.id;
        enabled[own] = own_manifest.id;
        labels[own] = request.package;
        candidates[own] = .{
            .manifest = own_manifest,
            .base_dir = request.output_root,
            .file = request.package,
            .root = request.assets,
            .origin = .installed,
        };

        var diagnostics: data.Diagnostics = .init(gpa, .default);
        defer diagnostics.deinit(gpa);
        var resolution = try mod.resolve(gpa, candidates, .{
            .enabled = enabled,
            .required = &.{own_manifest.id},
        }, &diagnostics);
        defer resolution.deinit();
        for (diagnostics.items.items) |entry| log.warn("preview: {s}", .{entry.message});

        for (resolution.order) |entry| {
            const at = for (self.ids, 0..) |candidate_id, index| {
                if (candidate_id.eql(entry.id)) break index;
            } else return error.ContentInvalid;
            _ = try self.store.add(gpa, labels[at], self.bytes[at], &self.registry, &diagnostics);
        }
        return self;
    }

    fn destroy(self: *Loaded, gpa: std.mem.Allocator) void {
        self.store.deinit(gpa);
        self.registry.deinit(gpa);
        for (self.bytes) |bytes| gpa.free(bytes);
        gpa.free(self.ids);
        gpa.free(self.bytes);
        gpa.destroy(self);
    }
};

fn readCandidate(
    gpa: std.mem.Allocator,
    os: *platform.os.Os,
    root: []const u8,
    relative: []const u8,
    out: *[]u8,
    total: *usize,
) !void {
    const read = try os.readFileConfined(gpa, root, relative, max_package_bytes);
    errdefer gpa.free(read.bytes);
    total.* = std.math.add(usize, total.*, read.bytes.len) catch return error.OverBudget;
    if (total.* > max_total_bytes) return error.OverBudget;
    out.* = read.bytes;
}
