//! Telling that something under a directory changed, by the operating system's own word
//! (`platform-interface.md`'s deferred file watching; M26 Step 11).
//!
//! **A watch answers one question: did anything under this directory change since you last
//! asked?** It never says what. Which file changed, and whether it changed in a way that
//! matters, is still decided by the caller's comparison of what it read (`asset.Registry`'s
//! stamps), so a notification that arrives for nothing costs one comparison and a missed one
//! costs nothing a timer would not have caught. That is also why events are coalesced rather
//! than queued: a save that touches a file four times is one answer.
//!
//! **Asking never waits.** `changed` drains what the system has queued and returns, so it can
//! sit at the top of a frame.
//!
//! Each system's own mechanism:
//! - Linux: inotify, one watch per directory, added for a directory created later;
//! - macOS: kqueue vnode events on every directory and file, rebuilt when anything changes,
//!   because a directory's events only report entries added or removed;
//! - Windows: a change notification over the whole tree.
//!
//! **No watch is a normal answer**: `Unsupported` elsewhere, and `TooManyEntries` for a tree
//! larger than `max_entries`, where a timer is the better tool. The caller falls back.

const std = @import("std");
const builtin = @import("builtin");
const os_mod = @import("os.zig");

const Allocator = std.mem.Allocator;
const Os = os_mod.Os;

pub const Error = error{
    OutOfMemory,
    /// No watch on this system, or the system refused one. The caller polls instead.
    Unsupported,
    /// More files and directories than `max_entries` beneath the root.
    TooManyEntries,
    /// The root is not a directory that can be listed.
    NotADirectory,
};

/// Bound on the files and directories a watch registers, so a watch pointed at a large tree
/// is refused rather than holding thousands of descriptors.
pub const max_entries = 4096;

pub const Watch = switch (builtin.os.tag) {
    .linux => Inotify,
    .macos => Kqueue,
    .windows => Notification,
    else => Unavailable,
};

// -- Linux ---------------------------------------------------------------------------------

const Inotify = struct {
    gpa: Allocator,
    fd: c_int,
    /// The directory each watch descriptor names, so a directory created later can be watched.
    dirs: std.ArrayList(struct { wd: c_int, path: []u8 }) = .empty,

    const mask = std.os.linux.IN.MODIFY | std.os.linux.IN.CLOSE_WRITE | std.os.linux.IN.ATTRIB |
        std.os.linux.IN.CREATE | std.os.linux.IN.DELETE | std.os.linux.IN.MOVED_FROM |
        std.os.linux.IN.MOVED_TO | std.os.linux.IN.DELETE_SELF | std.os.linux.IN.MOVE_SELF;

    pub fn init(gpa: Allocator, os: *Os, root: []const u8) Error!Inotify {
        const fd = std.c.inotify_init1(std.os.linux.IN.NONBLOCK | std.os.linux.IN.CLOEXEC);
        if (fd < 0) return error.Unsupported;
        var self: Inotify = .{ .gpa = gpa, .fd = fd };
        errdefer self.deinit();
        var tree: Tree = .{};
        defer tree.deinit(gpa);
        try tree.walk(gpa, os, root, .directories);
        for (tree.paths.items) |path| try self.add(path);
        return self;
    }

    pub fn deinit(self: *Inotify) void {
        for (self.dirs.items) |d| self.gpa.free(d.path);
        self.dirs.deinit(self.gpa);
        _ = std.c.close(self.fd);
        self.* = undefined;
    }

    fn add(self: *Inotify, path: []const u8) Error!void {
        if (self.dirs.items.len >= max_entries) return error.TooManyEntries;
        const z = try self.gpa.dupeZ(u8, path);
        defer self.gpa.free(z);
        const wd = std.c.inotify_add_watch(self.fd, z, mask);
        if (wd < 0) return error.Unsupported;
        try self.dirs.append(self.gpa, .{ .wd = wd, .path = try self.gpa.dupe(u8, path) });
    }

    pub fn changed(self: *Inotify) bool {
        var any = false;
        var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
        while (true) {
            const n = std.c.read(self.fd, &buf, buf.len);
            if (n <= 0) break; // EAGAIN: nothing more queued.
            any = true;
            var at: usize = 0;
            while (at + @sizeOf(std.os.linux.inotify_event) <= @as(usize, @intCast(n))) {
                const event: *const std.os.linux.inotify_event = @ptrCast(@alignCast(&buf[at]));
                const name_bytes = buf[at + @sizeOf(std.os.linux.inotify_event) ..][0..event.len];
                const name = std.mem.sliceTo(name_bytes, 0);
                if (event.mask & std.os.linux.IN.CREATE != 0 and event.mask & std.os.linux.IN.ISDIR != 0) {
                    self.watchCreated(event.wd, name);
                }
                at += @sizeOf(std.os.linux.inotify_event) + event.len;
            }
        }
        return any;
    }

    /// A directory made after the watch began is watched too; failing that is logged by
    /// omission only, since the stamps still catch a change a timer would.
    fn watchCreated(self: *Inotify, wd: c_int, name: []const u8) void {
        const parent = for (self.dirs.items) |d| {
            if (d.wd == wd) break d.path;
        } else return;
        const path = std.fs.path.join(self.gpa, &.{ parent, name }) catch return;
        defer self.gpa.free(path);
        self.add(path) catch {}; // Best effort: see above.
    }
};

// -- macOS ---------------------------------------------------------------------------------

const Kqueue = struct {
    gpa: Allocator,
    os: *Os,
    root: []u8,
    kq: c_int,
    fds: std.ArrayList(c_int) = .empty,

    const flags = std.c.NOTE.WRITE | std.c.NOTE.EXTEND | std.c.NOTE.ATTRIB | std.c.NOTE.DELETE | std.c.NOTE.RENAME;

    pub fn init(gpa: Allocator, os: *Os, root: []const u8) Error!Kqueue {
        const kq = std.c.kqueue();
        if (kq < 0) return error.Unsupported;
        var self: Kqueue = .{ .gpa = gpa, .os = os, .root = try gpa.dupe(u8, root), .kq = kq };
        errdefer self.deinit();
        try self.register();
        return self;
    }

    pub fn deinit(self: *Kqueue) void {
        self.closeAll();
        self.fds.deinit(self.gpa);
        self.gpa.free(self.root);
        _ = std.c.close(self.kq);
        self.* = undefined;
    }

    fn closeAll(self: *Kqueue) void {
        for (self.fds.items) |fd| _ = std.c.close(fd);
        self.fds.clearRetainingCapacity();
    }

    /// Every directory and file under the root, each with a vnode event of its own.
    fn register(self: *Kqueue) Error!void {
        var tree: Tree = .{};
        defer tree.deinit(self.gpa);
        try tree.walk(self.gpa, self.os, self.root, .everything);
        for (tree.paths.items) |path| {
            const z = try self.gpa.dupeZ(u8, path);
            defer self.gpa.free(z);
            const fd = std.c.open(z, .{ .EVTONLY = true, .CLOEXEC = true });
            if (fd < 0) continue; // Gone already, or unreadable: the stamps still cover it.
            self.fds.append(self.gpa, fd) catch |err| {
                _ = std.c.close(fd);
                return err;
            };
            const change: std.c.Kevent = .{
                .ident = @intCast(fd),
                .filter = std.c.EVFILT.VNODE,
                .flags = std.c.EV.ADD | std.c.EV.CLEAR,
                .fflags = flags,
                .data = 0,
                .udata = 0,
            };
            var none: [0]std.c.Kevent = undefined;
            if (std.c.kevent(self.kq, @ptrCast(&change), 1, &none, 0, null) < 0) return error.Unsupported;
        }
    }

    pub fn changed(self: *Kqueue) bool {
        var events: [64]std.c.Kevent = undefined;
        const zero: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        var any = false;
        while (true) {
            const n = std.c.kevent(self.kq, &events, 0, &events, events.len, &zero);
            if (n <= 0) break;
            any = true;
            if (n < events.len) break;
        }
        if (any) {
            // A file added, renamed or replaced has a new vnode the old descriptors cannot
            // see, so the registration is rebuilt. Only on a change, so a still tree costs
            // nothing.
            self.closeAll();
            self.register() catch {}; // Best effort: the stamps still catch what this misses.
        }
        return any;
    }
};

// -- Windows -------------------------------------------------------------------------------

const windows = std.os.windows;

extern "kernel32" fn FindFirstChangeNotificationW(path: [*:0]const u16, subtree: windows.BOOL, filter: windows.DWORD) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn FindNextChangeNotification(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn FindCloseChangeNotification(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, milliseconds: windows.DWORD) callconv(.winapi) windows.DWORD;

const Notification = struct {
    handle: windows.HANDLE,

    // FILE_NOTIFY_CHANGE_FILE_NAME, _DIR_NAME, _SIZE and _LAST_WRITE.
    const filter: windows.DWORD = 0x1 | 0x2 | 0x8 | 0x10;
    const wait_object_0: windows.DWORD = 0;

    pub fn init(gpa: Allocator, os: *Os, root: []const u8) Error!Notification {
        _ = os; // The system watches the whole tree itself.
        const w = std.unicode.wtf8ToWtf16LeAllocZ(gpa, root) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NotADirectory,
        };
        defer gpa.free(w);
        const handle = FindFirstChangeNotificationW(w.ptr, .TRUE, filter);
        if (handle == windows.INVALID_HANDLE_VALUE) return error.Unsupported;
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Notification) void {
        _ = FindCloseChangeNotification(self.handle);
        self.* = undefined;
    }

    pub fn changed(self: *Notification) bool {
        var any = false;
        // Each signal is re-armed by FindNextChangeNotification; drain what is already there.
        while (WaitForSingleObject(self.handle, 0) == wait_object_0) {
            any = true;
            if (FindNextChangeNotification(self.handle) == .FALSE) break;
        }
        return any;
    }
};

// -- elsewhere -----------------------------------------------------------------------------

const Unavailable = struct {
    pub fn init(gpa: Allocator, os: *Os, root: []const u8) Error!Unavailable {
        _ = gpa;
        _ = os;
        _ = root;
        return error.Unsupported;
    }
    pub fn deinit(self: *Unavailable) void {
        self.* = undefined;
    }
    pub fn changed(self: *Unavailable) bool {
        _ = self;
        return false;
    }
};

// -- the tree a watch registers ------------------------------------------------------------

const Tree = struct {
    paths: std.ArrayList([]u8) = .empty,

    const Kinds = enum { directories, everything };

    fn deinit(self: *Tree, gpa: Allocator) void {
        for (self.paths.items) |p| gpa.free(p);
        self.paths.deinit(gpa);
    }

    fn walk(self: *Tree, gpa: Allocator, os: *Os, dir: []const u8, kinds: Kinds) Error!void {
        if (self.paths.items.len >= max_entries) return error.TooManyEntries;
        var listing = os.listDir(gpa, dir) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NotADirectory,
        };
        defer listing.deinit();
        try self.paths.append(gpa, try gpa.dupe(u8, dir));
        for (listing.entries) |entry| {
            const child = os_mod.joinPath(gpa, &.{ dir, entry.name }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NotADirectory,
            };
            defer gpa.free(child);
            switch (entry.kind) {
                .directory => self.walk(gpa, os, child, kinds) catch |err| switch (err) {
                    // A directory that vanished or cannot be read is skipped, not fatal.
                    error.NotADirectory => {},
                    else => return err,
                },
                .file => if (kinds == .everything) {
                    if (self.paths.items.len >= max_entries) return error.TooManyEntries;
                    try self.paths.append(gpa, try gpa.dupe(u8, child));
                },
                .other => {},
            }
        }
    }
};

// -- tests ---------------------------------------------------------------------------------

const testing = std.testing;

/// Waits briefly for a watch to report, since the system delivers asynchronously.
fn eventually(w: *Watch) bool {
    for (0..200) |_| {
        if (w.changed()) return true;
        std.Io.sleep(testing.io, .fromNanoseconds(10_000_000), .awake) catch {};
    }
    return false;
}

test "a watch reports an edit, a new file and one in a new directory, and is quiet otherwise" {
    if (Watch == Unavailable) return error.SkipZigTest;
    const gpa = testing.allocator;
    const os = try Os.init(gpa, .{});
    defer os.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const file = try os_mod.joinPath(gpa, &.{ root, "a.fpk" });
    defer gpa.free(file);
    try os.writeFile(file, "one");

    var w = try Watch.init(gpa, os, root);
    defer w.deinit();
    _ = w.changed(); // Anything the set-up itself produced.
    try testing.expect(!w.changed());

    try os.writeFile(file, "two, longer");
    try testing.expect(eventually(&w));
    while (w.changed()) {}

    const other = try os_mod.joinPath(gpa, &.{ root, "b.png" });
    defer gpa.free(other);
    try os.writeFile(other, "new");
    try testing.expect(eventually(&w));
    while (w.changed()) {}

    const sub = try os_mod.joinPath(gpa, &.{ root, "textures" });
    defer gpa.free(sub);
    try os.createDirPath(sub);
    try testing.expect(eventually(&w));
    while (w.changed()) {}
    const deep = try os_mod.joinPath(gpa, &.{ sub, "sprites.png" });
    defer gpa.free(deep);
    try os.writeFile(deep, "deep");
    try testing.expect(eventually(&w));
}

test "a watch on a path that is not a directory is refused" {
    if (Watch == Unavailable) return error.SkipZigTest;
    const gpa = testing.allocator;
    const os = try Os.init(gpa, .{});
    defer os.deinit();
    if (builtin.os.tag == .windows) return error.SkipZigTest; // The system decides there.
    try testing.expectError(error.NotADirectory, Watch.init(gpa, os, "/nonexistent/foundry-watch-test"));
}
