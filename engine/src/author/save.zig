//! Conflict-safe persistence for authoring documents.
//!
//! A save is one file, never a package transaction (ADR-0043). Cooperating writers use one
//! exclusive token under the source root; while it is held, disk bytes are compared with the
//! document's last-read/saved baseline and a complete temporary sibling is atomically
//! published. An unrelated editor can still race after the comparison, which is an explicit
//! limit rather than a reason to overwrite a conflict silently.

const std = @import("std");
const data = @import("data");
const platform = @import("platform");

const edit = @import("edit.zig");

const Allocator = std.mem.Allocator;
const Diagnostics = data.Diagnostics;
const Document = edit.Document;
const Os = platform.os.Os;

pub const lock_file = ".foundry-author.lock";

pub const Error = error{
    StaleRevision,
    RevisionExhausted,
    InvalidDocument,
    WriteNotGranted,
    Busy,
    ExternalChange,
    DocumentBudget,
    IoFailed,
} || Allocator.Error;

pub const Context = struct {
    gpa: Allocator,
    os: *Os,
    root: []const u8,
    documents: []Document,
    state: *edit.State,
    max_source_bytes: usize,
    max_document_bytes: usize,
    write_granted: bool,
};

pub const Result = struct {
    document: u32,
    revision: u64,
    published: bool,
    durability: ?platform.os.Durability = null,
    /// False means the source bytes were handled, but the cooperating-writer token could
    /// not safely be removed. A later save will report Busy until the owner recovers it.
    lock_released: bool = true,
};

pub const Failure = enum {
    external_change,
    document_budget,
    io_failed,
    out_of_memory,
};

pub const AllEntry = struct {
    document: u32,
    outcome: union(enum) {
        saved: platform.os.Durability,
        unchanged,
        failed: Failure,
    },
};

pub const AllResult = struct {
    entries: []AllEntry,
    count: usize,
    revision: u64,
    lock_released: bool,

    pub fn deinit(self: *AllResult, gpa: Allocator) void {
        gpa.free(self.entries);
        self.* = undefined;
    }

    pub fn items(self: *const AllResult) []const AllEntry {
        return self.entries[0..self.count];
    }
};

/// The token is content as well as exclusion: cleanup rereads it and removes the name only
/// when it still contains this operation's bytes. A crash deliberately leaves it behind.
pub const Lock = struct {
    gpa: Allocator,
    os: *Os,
    root: []const u8,
    token: []u8,
    held: bool = true,

    pub fn acquire(
        gpa: Allocator,
        os: *Os,
        root: []const u8,
        revision: u64,
        diags: *Diagnostics,
    ) Error!Lock {
        const token = try std.fmt.allocPrint(gpa, "{x}:{x}\n", .{
            @as(u64, @bitCast(os.wallClockNanos())),
            revision ^ @as(u64, @intCast(@intFromPtr(os))),
        });
        errdefer gpa.free(token);

        _ = os.createFileConfined(root, lock_file, token, 128) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.AlreadyExists => {
                try diags.addFmt(gpa, .err, .whole(lock_file), 1, "", "the workspace is locked by another cooperating writer; if an editor crashed, confirm no editor owns it and remove this lock file manually", .{});
                return error.Busy;
            },
            else => {
                try diags.addFmt(gpa, .err, .whole(lock_file), 1, "", "the workspace lock could not be created: {s}", .{@errorName(err)});
                return error.IoFailed;
            },
        };
        return .{ .gpa = gpa, .os = os, .root = root, .token = token };
    }

    /// Releases only a token whose bytes still match. False leaves the name in place and
    /// lets the caller report recovery rather than guessing that it owns another session's
    /// file.
    pub fn release(self: *Lock) bool {
        if (!self.held) return true;
        defer {
            self.gpa.free(self.token);
            self.held = false;
        }
        const read = self.os.readFileConfined(self.gpa, self.root, lock_file, 128) catch return false;
        defer self.gpa.free(read.bytes);
        if (!std.mem.eql(u8, read.bytes, self.token)) return false;
        self.os.deleteFileConfined(self.root, lock_file) catch return false;
        return true;
    }
};

pub fn saveOne(ctx: Context, expected_revision: u64, document_index: u32, diags: *Diagnostics) Error!Result {
    try begin(ctx, expected_revision);
    if (document_index >= ctx.documents.len) return error.InvalidDocument;

    var lock = try Lock.acquire(ctx.gpa, ctx.os, ctx.root, expected_revision, diags);
    const inner = saveLocked(ctx, document_index, diags) catch |err| {
        reportLockRelease(ctx.gpa, &lock, diags);
        return err;
    };
    var result = inner;
    result.lock_released = lock.release();
    if (!result.lock_released) addLockCleanupDiagnostic(ctx.gpa, diags);
    return result;
}

pub fn saveAll(ctx: Context, expected_revision: u64, diags: *Diagnostics) Error!AllResult {
    try begin(ctx, expected_revision);

    const order = try ctx.gpa.alloc(u32, ctx.documents.len);
    defer ctx.gpa.free(order);
    for (order, 0..) |*slot, i| slot.* = @intCast(i);
    std.mem.sort(u32, order, ctx.documents, lessDocumentPath);

    const entries = try ctx.gpa.alloc(AllEntry, ctx.documents.len);
    errdefer ctx.gpa.free(entries);
    var count: usize = 0;

    var lock = try Lock.acquire(ctx.gpa, ctx.os, ctx.root, expected_revision, diags);
    for (order) |document_index| {
        const saved = saveLocked(ctx, document_index, diags) catch |err| {
            entries[count] = .{ .document = document_index, .outcome = .{ .failed = failureOf(err) } };
            count += 1;
            break;
        };
        entries[count] = .{
            .document = document_index,
            .outcome = if (saved.published)
                .{ .saved = saved.durability.? }
            else
                .unchanged,
        };
        count += 1;
    }

    const released = lock.release();
    if (!released) addLockCleanupDiagnostic(ctx.gpa, diags);
    return .{
        .entries = entries,
        .count = count,
        .revision = ctx.state.revision,
        .lock_released = released,
    };
}

fn begin(ctx: Context, expected_revision: u64) Error!void {
    if (!ctx.write_granted) return error.WriteNotGranted;
    if (expected_revision != ctx.state.revision) return error.StaleRevision;
    if (ctx.state.revision == std.math.maxInt(u64)) return error.RevisionExhausted;
}

fn saveLocked(ctx: Context, document_index: u32, diags: *Diagnostics) Error!Result {
    const document = &ctx.documents[document_index];
    if (document.bytes.len > ctx.max_source_bytes) return error.DocumentBudget;

    if (document.on_disk) {
        const read = ctx.os.readFileConfined(ctx.gpa, ctx.root, document.path, ctx.max_source_bytes) catch |err| {
            document.externally_changed = true;
            try diags.addFmt(ctx.gpa, .err, .whole(document.path), 1, "", "changed outside the workspace and cannot be saved over: {s}", .{@errorName(err)});
            return error.ExternalChange;
        };
        defer ctx.gpa.free(read.bytes);
        if (!std.mem.eql(u8, read.bytes, document.baseline)) {
            document.externally_changed = true;
            try diags.addFmt(ctx.gpa, .err, .whole(document.path), 1, "", "changed outside the workspace; the draft and disk file were both kept", .{});
            return error.ExternalChange;
        }
    } else {
        if (ctx.os.statFileConfined(ctx.root, document.path)) |_| {
            document.externally_changed = true;
            try diags.addFmt(ctx.gpa, .err, .whole(document.path), 1, "", "cannot be created because another writer already created that name", .{});
            return error.ExternalChange;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => {
                document.externally_changed = true;
                try diags.addFmt(ctx.gpa, .err, .whole(document.path), 1, "", "cannot be checked before creation: {s}", .{@errorName(err)});
                return error.ExternalChange;
            },
        }
    }

    if (document.on_disk and !document.dirty()) {
        document.externally_changed = false;
        return .{ .document = document_index, .revision = ctx.state.revision, .published = false };
    }

    try checkBaselineBudget(ctx, document_index, document.bytes.len);
    const next_baseline = try ctx.gpa.dupe(u8, document.bytes);
    errdefer ctx.gpa.free(next_baseline);

    const durability = if (document.on_disk)
        ctx.os.replaceFileConfined(ctx.root, document.path, document.bytes, ctx.max_source_bytes)
    else
        ctx.os.createFileConfined(ctx.root, document.path, document.bytes, ctx.max_source_bytes);
    const published = durability catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.AlreadyExists => {
            document.externally_changed = true;
            try diags.addFmt(ctx.gpa, .err, .whole(document.path), 1, "", "another writer created the file before this save could publish it", .{});
            return error.ExternalChange;
        },
        else => {
            try diags.addFmt(ctx.gpa, .err, .whole(document.path), 1, "", "could not be saved: {s}", .{@errorName(err)});
            return error.IoFailed;
        },
    };

    const old_baseline = document.baseline;
    document.baseline = next_baseline;
    ctx.gpa.free(old_baseline);
    document.on_disk = true;
    document.externally_changed = false;
    document.disk = ctx.os.statFileConfined(ctx.root, document.path) catch document.disk;
    ctx.state.revision += 1;
    return .{
        .document = document_index,
        .revision = ctx.state.revision,
        .published = true,
        .durability = published,
    };
}

fn checkBaselineBudget(ctx: Context, changed: u32, next_len: usize) Error!void {
    var retained = ctx.state.history.retained_bytes;
    for (ctx.documents, 0..) |document, i| {
        retained = std.math.add(usize, retained, document.bytes.len) catch return error.DocumentBudget;
        retained = std.math.add(usize, retained, if (i == changed) next_len else document.baseline.len) catch return error.DocumentBudget;
    }
    if (retained > ctx.max_document_bytes) return error.DocumentBudget;
    // The new baseline exists alongside the old one until publication succeeds.
    const peak = std.math.add(usize, retained, ctx.documents[changed].baseline.len) catch return error.DocumentBudget;
    if (peak > ctx.max_document_bytes) return error.DocumentBudget;
}

fn lessDocumentPath(documents: []Document, a: u32, b: u32) bool {
    return std.mem.lessThan(u8, documents[a].path, documents[b].path);
}

fn failureOf(err: anyerror) Failure {
    return switch (err) {
        error.ExternalChange => .external_change,
        error.DocumentBudget => .document_budget,
        error.OutOfMemory => .out_of_memory,
        else => .io_failed,
    };
}

fn reportLockRelease(gpa: Allocator, lock: *Lock, diags: *Diagnostics) void {
    if (!lock.release()) addLockCleanupDiagnostic(gpa, diags);
}

fn addLockCleanupDiagnostic(gpa: Allocator, diags: *Diagnostics) void {
    diags.addFmt(gpa, .warning, .whole(lock_file), 1, "", "the operation finished but its workspace lock could not be removed safely; confirm no editor owns it before manual recovery", .{}) catch {};
}
