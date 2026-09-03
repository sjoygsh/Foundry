//! Operating-system services: filesystem, base directories, dynamic libraries and the
//! wall clock.
//!
//! ## Why this is separate from `Platform`
//!
//! `Platform` is what differs between *windowing* backends — windows, events, input,
//! the monotonic clock, the native surface. `Os` is what does not. A hand-written
//! Cocoa backend and a hand-written Win32 backend would share this file byte for byte,
//! so putting it behind the backend seam would only duplicate it, and would force the
//! null backend (§9) to carry a fake filesystem it has no use for. Splitting them
//! keeps the conformance interface focused on what genuinely varies.
//!
//! ## Why `std.Io` stops here
//!
//! Zig 0.16 makes I/O an explicit capability: every filesystem call takes an `Io`, and
//! `std.fs` is a deprecation shim over `std.Io.Dir`. `Os` owns one `std.Io.Threaded`
//! and never lets it out. No `std` type appears in any Foundry interface, so when that
//! API moves again — and in a pre-1.0 language it will — this file changes and nothing
//! else does. That is the same containment ADR-0001 asks of `core`, applied to the
//! module that exists to own OS specifics.
//!
//! ## Why the environment is passed in
//!
//! Zig 0.16 removed ambient environment access outright: `std.posix.getenv`,
//! `std.os.environ` and `std.process.getEnvVarOwned` are all gone, and the process
//! entry point receives the environment instead. That suits Foundry — configuration
//! read from the air is exactly the sort of hidden input I9 objects to — so `Os` takes
//! the variables it is allowed to see and reads nothing else.
//!
//! **Mounts, overlays, package layering and override resolution are NOT here.** They
//! belong to `data` and `asset`: they are content policy, not OS access, and I3
//! requires the base game to load through the same path a mod does. Putting that logic
//! here would make it OS-shaped instead of content-shaped, and would be the beginning
//! of a privileged loading path.
//!
//! Design: `docs/design/platform-interface.md` §5, §6, §7.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const library = @import("library.zig");

const Allocator = std.mem.Allocator;
const log = core.log.scoped(.platform);

pub const Library = library.Library;
pub const LibraryError = library.LibraryError;

pub const InitError = error{OutOfMemory};

/// Errors from filesystem access.
///
/// Deliberately narrow: `std`'s open and read error sets carry several dozen members
/// between them, and propagating those upward would make every caller in the engine
/// handle conditions it cannot distinguish or act on. Anything without a distinct
/// remedy collapses into `IoFailed` and is logged where it happens.
pub const FileError = error{
    FileNotFound,
    AccessDenied,
    /// The path names a directory where a file was wanted, or the reverse.
    WrongFileKind,
    /// Malformed, too long, or (for untrusted callers) escaping its root.
    InvalidPath,
    /// The file is larger than the caller said it was willing to read.
    FileTooLarge,
    OutOfMemory,
    /// Anything else the OS reported. Logged at the site with the underlying cause.
    IoFailed,
};

/// Errors from resolving a well-known directory.
pub const PathError = error{
    /// The location cannot be determined — usually a missing environment variable,
    /// which is a legitimate state (a stripped container, a service account) rather
    /// than a bug to assert on.
    PathUnavailable,
    OutOfMemory,
    IoFailed,
};

pub const FileKind = enum { file, directory, other };

pub const FileInfo = struct {
    size: u64,
    kind: FileKind,
    /// Modification time in nanoseconds since the Unix epoch.
    ///
    /// Wall-clock, and therefore not monotonic: it can move backwards when a clock is
    /// corrected or a file is copied. Fine for "did this change?" in hot reload (M2+),
    /// wrong for measuring anything.
    modified_ns: i64,
};

pub const DirEntry = struct {
    name: []const u8,
    kind: FileKind,
};

/// The result of listing a directory. Owns its entries; free with `deinit`.
pub const DirListing = struct {
    entries: []const DirEntry,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *DirListing) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// One environment variable, as supplied by whoever owns `main`.
pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

pub const Options = struct {
    /// The variables `Os` is permitted to see. Borrowed: they must outlive the `Os`.
    /// An empty list is valid and simply makes the environment-derived directories
    /// return `error.PathUnavailable`.
    env: []const EnvVar = &.{},
    /// Directory name for user data, under the OS's per-user location. A name mods
    /// and users will see on disk, so it is chosen once and not changed casually.
    app_name: []const u8 = "foundry",
};

pub const Os = struct {
    gpa: Allocator,
    threaded: std.Io.Threaded,
    env: []const EnvVar,
    app_name: []const u8,

    /// Heap-allocated because `std.Io.Threaded` publishes its own address inside the
    /// `Io` it hands out; an `Os` that moved after init would leave that dangling.
    /// One allocation for the lifetime of the process is a fair price for making the
    /// hazard structurally impossible.
    pub fn init(gpa: Allocator, options: Options) InitError!*Os {
        const self = try gpa.create(Os);
        self.* = .{
            .gpa = gpa,
            // The environment is deliberately not handed to `std`: Foundry answers
            // environment questions from `options.env` and nothing else.
            .threaded = .init(gpa, .{}),
            .env = options.env,
            .app_name = options.app_name,
        };
        return self;
    }

    pub fn deinit(self: *Os) void {
        const gpa = self.gpa;
        self.threaded.deinit();
        gpa.destroy(self);
    }

    fn io(self: *Os) std.Io {
        return self.threaded.io();
    }

    // -- environment ---------------------------------------------------------------

    pub fn envVar(self: *Os, name: []const u8) ?[]const u8 {
        for (self.env) |v| {
            if (std.mem.eql(u8, v.name, name)) return v.value;
        }
        return null;
    }

    // -- wall clock ----------------------------------------------------------------

    /// Nanoseconds since the Unix epoch.
    ///
    /// **Never for simulation.** It jumps when the system clock is corrected, when NTP
    /// steps it, and across daylight-saving boundaries; I9 forbids simulation reading
    /// it at all. Logs need timestamps and saves need dates — that is what this is for.
    ///
    /// It returns a plain integer rather than a `core.time.Instant` on purpose: the
    /// two are not interchangeable, and the type system is a better guard against
    /// mixing them than a naming convention would be. Monotonic time comes from
    /// `Platform.now`.
    pub fn wallClockNanos(self: *Os) i64 {
        const ts = std.Io.Clock.real.now(self.io());
        return std.math.cast(i64, ts.nanoseconds) orelse std.math.maxInt(i64);
    }

    /// Yields the thread for approximately `duration`.
    ///
    /// Real time, necessarily: sleeping against a synthetic clock would not sleep. It
    /// lives here rather than on `Platform` for that reason — it is an OS service like
    /// the filesystem, not something a windowing backend varies.
    ///
    /// Approximate by nature. The OS guarantees *at least* this long, and schedulers
    /// routinely overshoot by a millisecond or more, so nothing whose correctness
    /// depends on the duration may use it. The fixed timestep exists precisely so that
    /// simulation does not care how long a frame actually took.
    pub fn sleep(self: *Os, duration: core.time.Duration) void {
        if (duration.ns <= 0) return;
        std.Io.sleep(
            self.io(),
            .fromNanoseconds(duration.ns),
            .awake,
        ) catch |err| {
            log.debug("sleep interrupted: {t}", .{err});
        };
    }

    // -- filesystem ----------------------------------------------------------------

    /// Reads a whole file. The caller owns the returned bytes.
    ///
    /// `max_bytes` is required rather than optional: every caller knows roughly how
    /// big the thing it is reading should be, and a content package naming a
    /// hundred-gigabyte file should fail with `FileTooLarge` rather than exhaust
    /// memory. Untrusted input is bounded at the boundary, not after it.
    pub fn readFile(self: *Os, gpa: Allocator, path: []const u8, max_bytes: usize) FileError![]u8 {
        const the_io = self.io();
        const limit: std.Io.Limit = .limited(max_bytes);
        const bytes = if (isAbsolute(path))
            openDirAbsoluteRead(the_io, gpa, path, limit)
        else
            std.Io.Dir.cwd().readFileAlloc(the_io, path, gpa, limit);

        return bytes catch |err| return mapFileError(err, "read", path);
    }

    fn openDirAbsoluteRead(the_io: std.Io, gpa: Allocator, path: []const u8, limit: std.Io.Limit) ![]u8 {
        var file = try std.Io.Dir.openFileAbsolute(the_io, path, .{});
        defer file.close(the_io);
        var reader = file.reader(the_io, &.{});
        return reader.interface.allocRemaining(gpa, limit);
    }

    /// Writes a whole file, replacing anything already there.
    pub fn writeFile(self: *Os, path: []const u8, bytes: []const u8) FileError!void {
        const the_io = self.io();
        if (isAbsolute(path)) {
            var file = std.Io.Dir.createFileAbsolute(the_io, path, .{}) catch |err|
                return mapFileError(err, "create", path);
            defer file.close(the_io);
            var buffer: [4096]u8 = undefined;
            var writer = file.writer(the_io, &buffer);
            writer.interface.writeAll(bytes) catch |err| return mapFileError(err, "write", path);
            writer.interface.flush() catch |err| return mapFileError(err, "flush", path);
            return;
        }
        std.Io.Dir.cwd().writeFile(the_io, .{ .sub_path = path, .data = bytes }) catch |err|
            return mapFileError(err, "write", path);
    }

    /// Whether something exists at `path`. Says nothing about what kind of thing.
    pub fn exists(self: *Os, path: []const u8) bool {
        _ = self.statFile(path) catch return false;
        return true;
    }

    pub fn statFile(self: *Os, path: []const u8) FileError!FileInfo {
        const the_io = self.io();
        const st = (if (isAbsolute(path))
            statAbsolute(the_io, path)
        else
            std.Io.Dir.cwd().statFile(the_io, path, .{})) catch |err|
            return mapFileError(err, "stat", path);

        return .{
            .size = st.size,
            .kind = mapKind(st.kind),
            .modified_ns = std.math.cast(i64, st.mtime.nanoseconds) orelse 0,
        };
    }

    fn statAbsolute(the_io: std.Io, path: []const u8) !std.Io.File.Stat {
        var file = try std.Io.Dir.openFileAbsolute(the_io, path, .{});
        defer file.close(the_io);
        return file.stat(the_io);
    }

    /// Creates a directory and any missing parents. Succeeds if it already exists.
    pub fn createDirPath(self: *Os, path: []const u8) FileError!void {
        const the_io = self.io();
        var dir = std.Io.Dir.cwd();
        var opened: ?std.Io.Dir = null;
        defer if (opened) |*d| d.close(the_io);

        if (isAbsolute(path)) {
            // Split "/a/b/c" into the root and the rest, since createDirPath is
            // relative-only. On Windows the root includes the drive.
            const root_len = absoluteRootLength(path);
            opened = std.Io.Dir.openDirAbsolute(the_io, path[0..root_len], .{}) catch |err|
                return mapFileError(err, "open root of", path);
            dir = opened.?;
            const rest = std.mem.trimStart(u8, path[root_len..], "/\\");
            if (rest.len == 0) return;
            return dir.createDirPath(the_io, rest) catch |err| mapFileError(err, "create", path);
        }

        dir.createDirPath(the_io, path) catch |err| return mapFileError(err, "create", path);
    }

    /// Lists a directory's immediate children. Order is whatever the OS returns and is
    /// **not** stable across platforms or runs, so anything order-sensitive — content
    /// package discovery above all (I9) — must sort the result itself.
    pub fn listDir(self: *Os, gpa: Allocator, path: []const u8) FileError!DirListing {
        const the_io = self.io();
        var dir = (if (isAbsolute(path))
            std.Io.Dir.openDirAbsolute(the_io, path, .{ .iterate = true })
        else
            std.Io.Dir.cwd().openDir(the_io, path, .{ .iterate = true })) catch |err|
            return mapFileError(err, "open", path);
        defer dir.close(the_io);

        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const arena_gpa = arena.allocator();

        var entries: std.ArrayList(DirEntry) = .empty;
        var it = dir.iterate();
        while (it.next(the_io) catch |err| return mapFileError(err, "iterate", path)) |entry| {
            const name = try arena_gpa.dupe(u8, entry.name);
            try entries.append(arena_gpa, .{ .name = name, .kind = mapKind(entry.kind) });
        }

        return .{ .entries = try entries.toOwnedSlice(arena_gpa), .arena = arena };
    }

    // -- base directories ----------------------------------------------------------

    /// The directory containing the running executable. The caller owns the result.
    pub fn executableDirAlloc(self: *Os, gpa: Allocator) PathError![]u8 {
        return std.process.executableDirPathAlloc(self.io(), gpa) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => {
                log.warn("could not determine the executable directory: {t}", .{err});
                return error.PathUnavailable;
            },
        };
    }

    /// Where this application may write per-user data: saves, settings, logs.
    ///
    /// Not created by this call — deciding whether to create it belongs to whoever is
    /// about to write there. Derived from the environment, so it is unavailable rather
    /// than guessed when the relevant variables are absent.
    pub fn userDataDirAlloc(self: *Os, gpa: Allocator) PathError![]u8 {
        return switch (builtin.os.tag) {
            .windows => blk: {
                const appdata = self.envVar("APPDATA") orelse break :blk error.PathUnavailable;
                break :blk joinPath(gpa, &.{ appdata, self.app_name });
            },
            .macos, .ios, .tvos, .watchos, .visionos => blk: {
                const home = self.envVar("HOME") orelse break :blk error.PathUnavailable;
                break :blk joinPath(gpa, &.{ home, "Library", "Application Support", self.app_name });
            },
            // The XDG base directory specification, which Linux and the BSDs follow.
            else => blk: {
                if (self.envVar("XDG_DATA_HOME")) |xdg| {
                    if (xdg.len > 0) break :blk joinPath(gpa, &.{ xdg, self.app_name });
                }
                const home = self.envVar("HOME") orelse break :blk error.PathUnavailable;
                break :blk joinPath(gpa, &.{ home, ".local", "share", self.app_name });
            },
        };
    }

    /// A directory for files that may vanish at any time.
    pub fn tempDirAlloc(self: *Os, gpa: Allocator) PathError![]u8 {
        const names: []const []const u8 = if (builtin.os.tag == .windows)
            &.{ "TEMP", "TMP" }
        else
            &.{ "TMPDIR", "TMP" };

        for (names) |name| {
            if (self.envVar(name)) |value| {
                if (value.len > 0) return gpa.dupe(u8, std.mem.trimEnd(u8, value, "/\\"));
            }
        }
        // POSIX guarantees /tmp exists; Windows has no equivalent fallback worth
        // guessing at, so it reports the truth instead.
        if (builtin.os.tag == .windows) return error.PathUnavailable;
        return gpa.dupe(u8, "/tmp");
    }

    // -- dynamic libraries ---------------------------------------------------------

    pub fn openLibrary(self: *Os, path: []const u8) LibraryError!Library {
        return Library.open(self.gpa, path);
    }
};

// -- paths ---------------------------------------------------------------------------

/// Joins path components with `/`, skipping empty ones. The caller owns the result.
pub fn joinPath(gpa: Allocator, parts: []const []const u8) PathError![]u8 {
    var total: usize = 0;
    var count: usize = 0;
    for (parts) |p| {
        const trimmed = std.mem.trim(u8, p, "/");
        if (trimmed.len == 0) continue;
        total += trimmed.len;
        count += 1;
    }
    if (count == 0) return gpa.dupe(u8, "");
    // On Windows an absolute path starts with a drive letter rather than a separator,
    // so only re-add a leading slash when the original had one.
    const leading = parts.len > 0 and parts[0].len > 0 and (parts[0][0] == '/' or parts[0][0] == '\\');
    total += count - 1 + @intFromBool(leading);

    const out = try gpa.alloc(u8, total);
    var i: usize = 0;
    if (leading) {
        out[0] = '/';
        i = 1;
    }
    var written: usize = 0;
    for (parts) |p| {
        const trimmed = std.mem.trim(u8, p, "/");
        if (trimmed.len == 0) continue;
        if (written > 0) {
            out[i] = '/';
            i += 1;
        }
        @memcpy(out[i..][0..trimmed.len], trimmed);
        i += trimmed.len;
        written += 1;
    }
    return out;
}

/// Whether a path is safe to resolve relative to a content root.
///
/// **The check that keeps a mod from reading `/etc/passwd` or writing over the engine.**
/// It is here, in force, before there are any mods, because retrofitting path
/// validation after untrusted paths are already flowing means auditing every call site
/// instead of one. Rejects absolute paths, drive letters, backslashes (so a Windows
/// separator cannot slip past a `/`-based check), `..` components, and embedded NULs.
///
/// This is validation, not an assertion: a path that fails is bad external input and
/// the caller reports it (`docs/design/core-memory-and-handles.md` §5).
pub fn isSafeRelativePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '\\') return false;
    if (path.len >= 2 and path[1] == ':') return false; // C:\... and C:...
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn isAbsolute(path: []const u8) bool {
    if (path.len == 0) return false;
    if (builtin.os.tag == .windows) {
        if (path.len >= 2 and path[1] == ':') return true;
        return path[0] == '\\' or path[0] == '/';
    }
    return path[0] == '/';
}

fn absoluteRootLength(path: []const u8) usize {
    if (builtin.os.tag == .windows and path.len >= 3 and path[1] == ':') return 3; // "C:\"
    return 1; // "/"
}

// -- error mapping -------------------------------------------------------------------

/// Collapses `std`'s wide error sets into Foundry's narrow ones.
///
/// Takes `anyerror` deliberately. Matching on a concrete `std` error set would make
/// this file fail to compile every time `std` adds or renames a member — which, in a
/// pre-1.0 language, is a maintenance tax with no safety benefit, since the `else`
/// branch is the right answer for anything Foundry cannot act on differently.
fn mapFileError(err: anyerror, comptime verb: []const u8, path: []const u8) FileError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.IsDir, error.NotDir => error.WrongFileKind,
        error.NameTooLong, error.BadPathName, error.InvalidUtf8, error.InvalidWtf8 => error.InvalidPath,
        error.StreamTooLong, error.FileTooBig => error.FileTooLarge,
        else => {
            log.warn("failed to " ++ verb ++ " '{s}': {t}", .{ path, err });
            return error.IoFailed;
        },
    };
}

fn mapKind(kind: std.Io.File.Kind) FileKind {
    return switch (kind) {
        .file => .file,
        .directory => .directory,
        else => .other,
    };
}

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

fn testOs(env: []const EnvVar) !*Os {
    return Os.init(testing.allocator, .{ .env = env, .app_name = "foundry-test" });
}

/// The absolute path of a test's temporary directory. Tests exercise absolute paths
/// deliberately: content roots and user data directories are absolute in practice, and
/// the absolute and relative code paths differ (see `isAbsolute`).
fn tmpPath(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    const n = try tmp.dir.realPath(testing.io, buf);
    return buf[0..n];
}

test "reads back what it writes" {
    var os = try testOs(&.{});
    defer os.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try tmpPath(&tmp, &buf);
    const path = try joinPath(testing.allocator, &.{ dir, "hello.txt" });
    defer testing.allocator.free(path);

    try os.writeFile(path, "content is data");
    try testing.expect(os.exists(path));

    const read = try os.readFile(testing.allocator, path, 1024);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("content is data", read);

    const info = try os.statFile(path);
    try testing.expectEqual(FileKind.file, info.kind);
    try testing.expectEqual(@as(u64, 15), info.size);
}

test "a missing file is an error, never a panic" {
    var os = try testOs(&.{});
    defer os.deinit();

    try testing.expectError(error.FileNotFound, os.readFile(testing.allocator, "/definitely/not/here", 16));
    try testing.expectError(error.FileNotFound, os.statFile("/definitely/not/here"));
    try testing.expect(!os.exists("/definitely/not/here"));
}

test "a path of the wrong kind is an error, never a panic" {
    var os = try testOs(&.{});
    defer os.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try tmpPath(&tmp, &buf);
    const file = try joinPath(testing.allocator, &.{ dir, "a-file" });
    defer testing.allocator.free(file);
    try os.writeFile(file, "x");

    // Listing a file: the OS says "not a directory" and Foundry says WrongFileKind.
    try testing.expectError(error.WrongFileKind, os.listDir(testing.allocator, file));

    // Reading a directory as a file. What the OS reports here varies — macOS opens the
    // directory happily and fails at the read — so this asserts only that it is an
    // error, and the warn it logs is the engine correctly reporting an OS failure it
    // cannot classify, not a broken test.
    try testing.expect(std.meta.isError(os.readFile(testing.allocator, dir, 16)));
}

test "a file larger than the caller allowed is refused" {
    // Bounding untrusted input at the boundary: a content package must not be able to
    // ask the engine to allocate whatever it likes.
    var os = try testOs(&.{});
    defer os.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try tmpPath(&tmp, &buf);
    const path = try joinPath(testing.allocator, &.{ dir, "big.bin" });
    defer testing.allocator.free(path);

    try os.writeFile(path, "x" ** 100);
    try testing.expectError(error.FileTooLarge, os.readFile(testing.allocator, path, 10));
}

test "listing a directory finds what was written into it" {
    var os = try testOs(&.{});
    defer os.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try tmpPath(&tmp, &buf);

    const a = try joinPath(testing.allocator, &.{ dir, "a.txt" });
    defer testing.allocator.free(a);
    try os.writeFile(a, "a");

    var listing = try os.listDir(testing.allocator, dir);
    defer listing.deinit();

    var found = false;
    for (listing.entries) |entry| {
        if (std.mem.eql(u8, entry.name, "a.txt")) {
            found = true;
            try testing.expectEqual(FileKind.file, entry.kind);
        }
    }
    try testing.expect(found);
}

test "listing something that is not a directory is an error" {
    var os = try testOs(&.{});
    defer os.deinit();
    const result = os.listDir(testing.allocator, "/definitely/not/here");
    try testing.expect(std.meta.isError(result));
}

test "path traversal is rejected" {
    // Every one of these is something a mod could put in a manifest.
    try testing.expect(!isSafeRelativePath("../../etc/passwd"));
    try testing.expect(!isSafeRelativePath("textures/../../secret"));
    try testing.expect(!isSafeRelativePath("/etc/passwd"));
    try testing.expect(!isSafeRelativePath("\\windows\\system32"));
    try testing.expect(!isSafeRelativePath("C:\\windows"));
    try testing.expect(!isSafeRelativePath("C:relative"));
    try testing.expect(!isSafeRelativePath("textures\\sneaky.png")); // backslash separator
    try testing.expect(!isSafeRelativePath("nul\x00byte"));
    try testing.expect(!isSafeRelativePath(""));
}

test "ordinary relative paths are accepted" {
    try testing.expect(isSafeRelativePath("textures/hero.png"));
    try testing.expect(isSafeRelativePath("a"));
    try testing.expect(isSafeRelativePath("./config.ftx"));
    // A file merely containing dots is not a traversal.
    try testing.expect(isSafeRelativePath("weird..name/file.txt"));
}

test "path joining" {
    const cases = [_]struct { parts: []const []const u8, want: []const u8 }{
        .{ .parts = &.{ "/home/user", "Library", "Application Support", "foundry" }, .want = "/home/user/Library/Application Support/foundry" },
        .{ .parts = &.{ "a", "b" }, .want = "a/b" },
        .{ .parts = &.{ "a/", "/b" }, .want = "a/b" },
        .{ .parts = &.{ "", "b" }, .want = "b" },
        .{ .parts = &.{"/root"}, .want = "/root" },
    };
    for (cases) |c| {
        const got = try joinPath(testing.allocator, c.parts);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "environment lookup sees only what it was given" {
    var os = try testOs(&.{
        .{ .name = "HOME", .value = "/home/tester" },
        .{ .name = "EMPTY", .value = "" },
    });
    defer os.deinit();

    try testing.expectEqualStrings("/home/tester", os.envVar("HOME").?);
    try testing.expectEqualStrings("", os.envVar("EMPTY").?);
    // Nothing is read from the real process environment.
    try testing.expectEqual(@as(?[]const u8, null), os.envVar("PATH"));
}

test "user data directory is derived, not guessed" {
    var os = try testOs(&.{.{ .name = "HOME", .value = "/home/tester" }});
    defer os.deinit();

    if (builtin.os.tag == .macos) {
        const path = try os.userDataDirAlloc(testing.allocator);
        defer testing.allocator.free(path);
        try testing.expectEqualStrings("/home/tester/Library/Application Support/foundry-test", path);
    }
}

test "an unavailable directory says so instead of inventing one" {
    var os = try testOs(&.{});
    defer os.deinit();
    try testing.expectError(error.PathUnavailable, os.userDataDirAlloc(testing.allocator));
}

test "the executable directory is discoverable" {
    var os = try testOs(&.{});
    defer os.deinit();
    const dir = try os.executableDirAlloc(testing.allocator);
    defer testing.allocator.free(dir);
    try testing.expect(dir.len > 0);
    try testing.expect(os.exists(dir));
}

test "sleeping advances real time and refuses nonsense" {
    var os = try testOs(&.{});
    defer os.deinit();

    // Zero and negative durations return immediately rather than blocking forever or
    // trapping on an unsigned conversion.
    os.sleep(.zero);
    os.sleep(.fromNanos(-1));

    const before = os.wallClockNanos();
    os.sleep(.fromMillis(5));
    const slept = os.wallClockNanos() - before;

    // At least the requested time. No upper bound is asserted: schedulers overshoot,
    // and a test that demanded precision here would fail on a loaded machine.
    try testing.expect(slept >= 5 * std.time.ns_per_ms);
}

test "the wall clock is plausible and is not an Instant" {
    var os = try testOs(&.{});
    defer os.deinit();

    // 2020-01-01 in nanoseconds. Anything earlier means the clock is not what we think.
    try testing.expect(os.wallClockNanos() > 1_577_836_800 * std.time.ns_per_s);

    // The type is the enforcement: simulation code takes `core.time.Instant`, and this
    // is not one, so wall-clock time cannot reach it by accident (I9).
    try testing.expect(@TypeOf(os.wallClockNanos()) != core.time.Instant);
}

test "creating a directory path is idempotent" {
    var os = try testOs(&.{});
    defer os.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try tmpPath(&tmp, &buf);
    const nested = try joinPath(testing.allocator, &.{ dir, "a", "b", "c" });
    defer testing.allocator.free(nested);

    try os.createDirPath(nested);
    try os.createDirPath(nested); // again: not an error
    const info = try os.statFile(nested);
    try testing.expectEqual(FileKind.directory, info.kind);
}
