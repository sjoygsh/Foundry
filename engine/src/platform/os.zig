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

pub const InitError = error{
    OutOfMemory,
    /// `Options.app_name` is not one ordinary directory name. It becomes a component of a
    /// path in the user's own data directory, so it is checked once here rather than
    /// trusted at every place that builds one (`distribution.md` §4).
    InvalidAppName,
};

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

/// Whether a file being written is a program.
///
/// Two values rather than a permission number, because the only thing above this layer has
/// an opinion about is that one file: a release stages a program the operating system will
/// be asked to run, and a program written as ordinary data does not run
/// (`distribution.md` §8). Everything finer — owners, groups, read-only — belongs to
/// whoever installs the file, not to whoever wrote it.
pub const FileMode = enum {
    regular,
    executable,

    /// Whether this system has an executable bit at all. False on Windows, which decides by
    /// extension, and where asking for one is not an error but is not a change either.
    pub const has_bit = std.Io.File.Permissions.has_executable_bit;

    fn permissions(self: FileMode) std.Io.File.Permissions {
        return switch (self) {
            .regular => .default_file,
            .executable => .executable_file,
        };
    }
};

pub const FileInfo = struct {
    size: u64,
    kind: FileKind,
    /// Whether the system would let anyone execute this file.
    ///
    /// Always false where there is no such bit — Windows decides by extension — so a
    /// caller that copies it is copying "nothing to preserve" rather than a wrong answer.
    executable: bool = false,
    /// Modification time in nanoseconds since the Unix epoch.
    ///
    /// Wall-clock, and therefore not monotonic: it can move backwards when a clock is
    /// corrected or a file is copied. Fine for "did this change?" in hot reload (M2+),
    /// wrong for measuring anything.
    modified_ns: i64,
};

/// Bytes and metadata obtained from the same opened file.
///
/// Keeping these together matters for confined package reads: checking one path and then
/// opening it again would leave a race in which a symlink could replace the checked object.
pub const FileRead = struct {
    bytes: []u8,
    info: FileInfo,
};

/// Whether a completed replacement is known to have reached the disk.
///
/// Two outcomes rather than one, because the second is not a failure and must not be
/// reported as one: by the time it can happen the destination already names the new
/// bytes, and there is nothing left to roll back. Only a power loss in the window that
/// follows can still show the old file.
pub const Durability = enum {
    /// The bytes and the directory entry naming them were both flushed.
    durable,
    /// The new bytes are in place and readable; the entry naming them was not confirmed
    /// flushed. Some systems do not permit flushing a directory at all — Windows among
    /// them — so this is the ordinary answer there rather than a sign of trouble.
    entry_unflushed,
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
    /// Must satisfy `isValidAppName`.
    app_name: []const u8 = "foundry",
};

/// The decoration `Os.tempName` wraps a destination name in: a leading dot, `.tmp-`, and
/// sixteen hex digits.
const temp_decoration = 1 + 5 + 16;

/// Effectively every filesystem in use limits one path component to 255 bytes, and a
/// replacement that cannot name its own temporary file has to say so rather than build a
/// name the OS will refuse.
const temp_name_max = 255;

/// The longest destination name `Os.replaceFileConfined` can build a temporary sibling
/// for. Public because a caller that chooses its own file names needs to be able to refuse
/// one it could never replace, rather than discovering that on the first save.
pub const max_replaceable_name = temp_name_max - temp_decoration;

/// How many names a replacement tries before giving up. Exclusive creation can only lose
/// to a name that already exists, and the counter guarantees a different one next time, so
/// reaching the end of this means something other than a collision is wrong.
const temp_name_attempts = 8;

pub const Os = struct {
    gpa: Allocator,
    threaded: std.Io.Threaded,
    env: []const EnvVar,
    app_name: []const u8,
    /// Distinguishes the temporary files this process's replacements create. Neither
    /// randomness nor security: exclusive creation is what makes a name ours, and this
    /// only has to stop two replacements in one process from choosing the same one.
    temp_sequence: u64 = 0,

    /// Heap-allocated because `std.Io.Threaded` publishes its own address inside the
    /// `Io` it hands out; an `Os` that moved after init would leave that dangling.
    /// One allocation for the lifetime of the process is a fair price for making the
    /// hazard structurally impossible.
    pub fn init(gpa: Allocator, options: Options) InitError!*Os {
        if (!isValidAppName(options.app_name)) return error.InvalidAppName;
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

    /// Reads one package-relative file without following a symlink or reparse point below
    /// `root`. The root itself is a host-supplied capability and may be a symlink; every
    /// component selected by untrusted package content is opened relative to an already-open
    /// directory handle with following disabled.
    ///
    /// This deliberately rejects symlinks rather than resolving and comparing paths. The
    /// latter is a check-then-open race; handle-relative traversal validates the object that
    /// is actually read. `info` describes that same opened object.
    pub fn readFileConfined(
        self: *Os,
        gpa: Allocator,
        root: []const u8,
        relative: []const u8,
        max_bytes: usize,
    ) FileError!FileRead {
        const the_io = self.io();
        var file = try self.openFileConfined(root, relative);
        defer file.close(the_io);

        const st = file.stat(the_io) catch |err| return mapConfinedError(err, "stat", relative);
        if (st.kind != .file) return error.WrongFileKind;
        if (st.size > max_bytes) return error.FileTooLarge;

        var reader = file.reader(the_io, &.{});
        const bytes = reader.interface.allocRemaining(gpa, .limited(max_bytes)) catch |err|
            return mapConfinedError(err, "read", relative);
        return .{ .bytes = bytes, .info = infoFromStat(st) };
    }

    /// Metadata for a confined file. This opens the object under the same no-symlink rules
    /// as `readFileConfined`; it is suitable for change detection, not as authorization for
    /// a later ordinary path open.
    pub fn statFileConfined(self: *Os, root: []const u8, relative: []const u8) FileError!FileInfo {
        const the_io = self.io();
        var file = try self.openFileConfined(root, relative);
        defer file.close(the_io);
        const st = file.stat(the_io) catch |err| return mapConfinedError(err, "stat", relative);
        if (st.kind != .file) return error.WrongFileKind;
        return infoFromStat(st);
    }

    /// The directory holding a confined path's last component, and that component.
    ///
    /// The caller closes `dir`. Split out because reading a confined file and replacing
    /// one need the same walk and must not disagree about it: a second implementation of
    /// "open every component without following a link" is a second place for the rule to
    /// be almost right.
    const ConfinedParent = struct {
        dir: std.Io.Dir,
        /// Borrowed from the caller's `relative`.
        leaf: []const u8,
    };

    fn openParentConfined(self: *Os, root: []const u8, relative: []const u8) FileError!ConfinedParent {
        if (!isSafeRelativePath(relative)) return error.InvalidPath;

        var component_count: usize = 0;
        var leaf: []const u8 = &.{};
        var count_it = std.mem.splitScalar(u8, relative, '/');
        while (count_it.next()) |component| {
            if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
            component_count += 1;
            leaf = component;
        }
        if (component_count == 0) return error.InvalidPath;

        const the_io = self.io();
        var current = (if (isAbsolute(root))
            std.Io.Dir.openDirAbsolute(the_io, root, .{})
        else
            std.Io.Dir.cwd().openDir(the_io, root, .{})) catch |err|
            return mapConfinedError(err, "open root for", relative);
        errdefer current.close(the_io);

        var component_index: usize = 0;
        var it = std.mem.splitScalar(u8, relative, '/');
        while (it.next()) |component| {
            if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
            component_index += 1;
            if (component_index == component_count) break;

            const next = current.openDir(the_io, component, .{
                .follow_symlinks = false,
            }) catch |err| return mapConfinedError(err, "open", relative);
            current.close(the_io);
            current = next;
        }
        return .{ .dir = current, .leaf = leaf };
    }

    fn openFileConfined(self: *Os, root: []const u8, relative: []const u8) FileError!std.Io.File {
        const the_io = self.io();
        var parent = try self.openParentConfined(root, relative);
        defer parent.dir.close(the_io);

        return parent.dir.openFile(the_io, parent.leaf, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| return mapConfinedError(err, "open", relative);
    }

    fn openDirAbsoluteRead(the_io: std.Io, gpa: Allocator, path: []const u8, limit: std.Io.Limit) ![]u8 {
        var file = try std.Io.Dir.openFileAbsolute(the_io, path, .{});
        defer file.close(the_io);
        var reader = file.reader(the_io, &.{});
        return reader.interface.allocRemaining(gpa, limit);
    }

    /// Writes a whole file, replacing anything already there.
    pub fn writeFile(self: *Os, path: []const u8, bytes: []const u8) FileError!void {
        return self.writeFileMode(path, bytes, .regular);
    }

    /// Writes a whole file that the system will be asked to execute.
    ///
    /// Separate from `writeFile` rather than a default argument, because "this file is a
    /// program" is a decision a caller makes deliberately and exactly once per file.
    pub fn writeFileMode(self: *Os, path: []const u8, bytes: []const u8, mode: FileMode) FileError!void {
        const the_io = self.io();
        const flags: std.Io.Dir.CreateFileOptions = .{ .permissions = mode.permissions() };
        if (isAbsolute(path)) {
            var file = std.Io.Dir.createFileAbsolute(the_io, path, flags) catch |err|
                return mapFileError(err, "create", path);
            defer file.close(the_io);
            var buffer: [4096]u8 = undefined;
            var writer = file.writer(the_io, &buffer);
            writer.interface.writeAll(bytes) catch |err| return mapFileError(err, "write", path);
            writer.interface.flush() catch |err| return mapFileError(err, "flush", path);
            return;
        }
        std.Io.Dir.cwd().writeFile(the_io, .{ .sub_path = path, .data = bytes, .flags = flags }) catch |err|
            return mapFileError(err, "write", path);
    }

    /// Replaces one confined file with `bytes`, without the destination ever naming a
    /// partly written file.
    ///
    /// The counterpart of `readFileConfined`, and confined for the same reason: `root` is
    /// a capability the host supplies, every component below it is opened with following
    /// disabled, and nothing the caller passes can name a file outside it. `relative`'s
    /// last component is the destination, and it is replaced as a *leaf* — a symlink
    /// sitting there is overwritten, never followed to whatever it points at.
    ///
    /// The order is what makes it safe. A temporary sibling is created exclusively, the
    /// bytes are written and flushed to the device, and only then does one rename put the
    /// new file where the old one was. Nothing truncates the destination, so every failure
    /// before the rename leaves the previous file exactly as it was, and every failure
    /// after it has already succeeded. The temporary file is removed on any failure — that
    /// one and no other, since a name this call did not create is not this call's to
    /// delete.
    ///
    /// `max_bytes` is checked before anything is opened: a caller that cannot say how big
    /// its own file should be has no business replacing one.
    pub fn replaceFileConfined(
        self: *Os,
        root: []const u8,
        relative: []const u8,
        bytes: []const u8,
        max_bytes: usize,
    ) FileError!Durability {
        if (bytes.len > max_bytes) return error.FileTooLarge;

        const the_io = self.io();
        var parent = try self.openParentConfined(root, relative);
        defer parent.dir.close(the_io);

        var name_buf: [temp_name_max]u8 = undefined;
        var temp_name: []const u8 = undefined;
        var file: std.Io.File = undefined;
        var created = false;
        var attempt: u32 = 0;
        while (attempt < temp_name_attempts) : (attempt += 1) {
            temp_name = try self.tempName(&name_buf, parent.leaf);
            file = parent.dir.createFile(the_io, temp_name, .{
                .truncate = false,
                // Exclusive creation is the whole of the claim to this name, and it is
                // also why the temporary file needs no symlink check of its own: a name
                // already taken by anything, a dangling link included, fails here.
                .exclusive = true,
                .resolve_beneath = true,
            }) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return mapConfinedError(err, "create a temporary file beside", relative),
            };
            created = true;
            break;
        }
        if (!created) {
            log.warn("could not find an unused temporary name beside '{s}'", .{relative});
            return error.IoFailed;
        }

        self.writeSynced(file, bytes, relative) catch |err| {
            parent.dir.deleteFile(the_io, temp_name) catch {};
            return err;
        };

        std.Io.Dir.rename(parent.dir, temp_name, parent.dir, parent.leaf, the_io) catch |err| {
            parent.dir.deleteFile(the_io, temp_name) catch {};
            return mapConfinedError(err, "replace", relative);
        };

        // The destination now names the new bytes. Flushing the directory is what makes
        // that survive a power loss, and it is reported rather than retried: the
        // replacement has happened, so a failure here is a weaker guarantee and not a
        // failed write. Systems that do not allow flushing a directory land here too.
        var dir_file = parent.dir.openFile(the_io, ".", .{ .allow_directory = true }) catch
            return .entry_unflushed;
        defer dir_file.close(the_io);
        dir_file.sync(the_io) catch return .entry_unflushed;
        return .durable;
    }

    /// Writes a whole open file and puts it on the device. Closes it either way.
    fn writeSynced(self: *Os, file: std.Io.File, bytes: []const u8, what: []const u8) FileError!void {
        const the_io = self.io();
        defer file.close(the_io);

        var buffer: [4096]u8 = undefined;
        var writer = file.writer(the_io, &buffer);
        writer.interface.writeAll(bytes) catch |err| return mapFileError(err, "write", what);
        writer.interface.flush() catch |err| return mapFileError(err, "flush", what);
        // Before the rename, not after. A rename publishes whatever the file contains, so
        // syncing afterwards would be publishing bytes and then hoping.
        file.sync(the_io) catch |err| return mapFileError(err, "sync", what);
    }

    /// A name for the temporary file a replacement writes before it renames.
    ///
    /// Leading dot so that a half-finished replacement does not show up among the user's
    /// own files, and the destination's name inside it so that a leftover one — which only
    /// a crash between creation and rename can produce — says what it belonged to.
    fn tempName(self: *Os, buf: []u8, leaf: []const u8) FileError![]const u8 {
        if (leaf.len > max_replaceable_name) return error.InvalidPath;
        self.temp_sequence +%= 1;
        // Deliberately not random. Uniqueness within a process comes from the counter and
        // between processes from the clock, and exclusive creation is what actually
        // guarantees the name is ours — so this only has to make a collision rare, without
        // threading a generator through the filesystem to do it (CLAUDE.md §7).
        const stamp = @as(u64, @bitCast(self.wallClockNanos())) ^
            (self.temp_sequence *% 0x9e3779b97f4a7c15);
        return std.fmt.bufPrint(buf, ".{s}.tmp-{x:0>16}", .{ leaf, stamp }) catch
            return error.InvalidPath;
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

        return infoFromStat(st);
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
                if (!isAbsolute(appdata)) break :blk error.PathUnavailable;
                break :blk joinPath(gpa, &.{ appdata, self.app_name });
            },
            .macos, .ios, .tvos, .watchos, .visionos => blk: {
                const home = self.envVar("HOME") orelse break :blk error.PathUnavailable;
                if (!isAbsolute(home)) break :blk error.PathUnavailable;
                break :blk joinPath(gpa, &.{ home, "Library", "Application Support", self.app_name });
            },
            // The XDG base directory specification, which Linux and the BSDs follow.
            else => blk: {
                if (self.envVar("XDG_DATA_HOME")) |xdg| {
                    if (xdg.len > 0) {
                        if (!isAbsolute(xdg)) break :blk error.PathUnavailable;
                        break :blk joinPath(gpa, &.{ xdg, self.app_name });
                    }
                }
                const home = self.envVar("HOME") orelse break :blk error.PathUnavailable;
                if (!isAbsolute(home)) break :blk error.PathUnavailable;
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

/// Whether `name` is one ordinary directory name for an application's user data.
///
/// One ASCII component of at most 64 bytes, made of letters, digits, `.`, `_` and `-`, and
/// neither `.` nor `..`. Deliberately narrower than what a filesystem would accept: this
/// name is chosen by a build and is seen by users and mod authors on disk, so the bound
/// worth enforcing is "a name a person can type", not "a name the OS tolerates".
pub fn isValidAppName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// Whether `path` names a location from the filesystem root rather than from wherever the
/// process happens to be. Public because a host directory that is not absolute is one a
/// caller must refuse: resolving it would write beside the current directory, which in a
/// shipped application is an app bundle or a read-only install (`distribution.md` §6).
pub fn isAbsolute(path: []const u8) bool {
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

/// Confined traversal treats a symlink loop and an intermediate non-directory as a rejected
/// path. Both are the observable results of opening a component with following disabled, and
/// neither may be softened into "missing" at the asset boundary.
fn mapConfinedError(err: anyerror, comptime verb: []const u8, relative: []const u8) FileError {
    return switch (err) {
        error.SymLinkLoop, error.NotDir => error.InvalidPath,
        else => mapFileError(err, verb, relative),
    };
}

fn infoFromStat(st: std.Io.File.Stat) FileInfo {
    return .{
        .size = st.size,
        .kind = mapKind(st.kind),
        .modified_ns = std.math.cast(i64, st.mtime.nanoseconds) orelse 0,
        .executable = FileMode.has_bit and (st.permissions.toMode() & 0o111) != 0,
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

test "a confined read returns bytes and metadata from an ordinary package file" {
    var os = try testOs(&.{});
    defer os.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try tmpPath(&tmp, &buf);
    const nested = try joinPath(testing.allocator, &.{ dir, "scripts" });
    defer testing.allocator.free(nested);
    try os.createDirPath(nested);
    const path = try joinPath(testing.allocator, &.{ nested, "main.lua" });
    defer testing.allocator.free(path);
    try os.writeFile(path, "return 42");

    const read = try os.readFileConfined(testing.allocator, dir, "scripts/main.lua", 256 << 10);
    defer testing.allocator.free(read.bytes);
    try testing.expectEqualStrings("return 42", read.bytes);
    try testing.expectEqual(@as(u64, 9), read.info.size);
    try testing.expectEqual(FileKind.file, read.info.kind);

    const info = try os.statFileConfined(dir, "scripts/main.lua");
    try testing.expectEqual(read.info.size, info.size);
    try testing.expectEqual(read.info.modified_ns, info.modified_ns);
}

test "a confined read rejects final and intermediate symlinks" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var os = try testOs(&.{});
    defer os.deinit();

    var root_tmp = testing.tmpDir(.{});
    defer root_tmp.cleanup();
    var outside_tmp = testing.tmpDir(.{});
    defer outside_tmp.cleanup();
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var outside_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpPath(&root_tmp, &root_buf);
    const outside = try tmpPath(&outside_tmp, &outside_buf);
    const secret = try joinPath(testing.allocator, &.{ outside, "secret.lua" });
    defer testing.allocator.free(secret);
    try os.writeFile(secret, "outside");

    try root_tmp.dir.symLink(testing.io, secret, "final.lua", .{});
    try root_tmp.dir.symLink(testing.io, outside, "linked", .{ .is_directory = true });

    try testing.expectError(
        error.InvalidPath,
        os.readFileConfined(testing.allocator, root, "final.lua", 1024),
    );
    try testing.expectError(
        error.InvalidPath,
        os.readFileConfined(testing.allocator, root, "linked/secret.lua", 1024),
    );
    try testing.expectError(error.InvalidPath, os.statFileConfined(root, "final.lua"));
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

test "a relative environment directory is unavailable rather than resolved from cwd" {
    var os = try testOs(&.{
        .{ .name = "HOME", .value = "relative-home" },
        .{ .name = "XDG_DATA_HOME", .value = "relative-xdg" },
        .{ .name = "APPDATA", .value = "relative-appdata" },
    });
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

// -- confined replacement ------------------------------------------------------------

/// Counts what is actually in a directory, which is how the replacement tests check that
/// no temporary file was left behind. A leftover would be invisible to a `readFile` of the
/// destination and is exactly the kind of mess the rename order exists to avoid.
fn countEntries(os: *Os, dir: []const u8) !usize {
    var listing = try os.listDir(testing.allocator, dir);
    defer listing.deinit();
    return listing.entries.len;
}

test "a confined replacement swaps a file's contents and leaves nothing behind" {
    var os = try testOs(&.{});
    defer os.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try tmpPath(&tmp, &buf);

    // The first write has no file to replace, which is the ordinary first-run case.
    _ = try os.replaceFileConfined(dir, "settings.fset", "first", 1024);
    const durability = try os.replaceFileConfined(dir, "settings.fset", "second", 1024);
    try testing.expect(durability == .durable or durability == .entry_unflushed);

    const read = try os.readFileConfined(testing.allocator, dir, "settings.fset", 1024);
    defer testing.allocator.free(read.bytes);
    try testing.expectEqualStrings("second", read.bytes);
    try testing.expectEqual(@as(usize, 1), try countEntries(os, dir));
}

test "a confined replacement writes through a subdirectory it is given" {
    var os = try testOs(&.{});
    defer os.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try tmpPath(&tmp, &buf);
    const logs = try joinPath(testing.allocator, &.{ dir, "logs" });
    defer testing.allocator.free(logs);
    try os.createDirPath(logs);

    _ = try os.replaceFileConfined(dir, "logs/session.log", "line", 1024);
    const read = try os.readFileConfined(testing.allocator, dir, "logs/session.log", 1024);
    defer testing.allocator.free(read.bytes);
    try testing.expectEqualStrings("line", read.bytes);
    try testing.expectEqual(@as(usize, 1), try countEntries(os, logs));
}

test "a replacement that cannot finish leaves the previous file and no temporary" {
    var os = try testOs(&.{});
    defer os.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try tmpPath(&tmp, &buf);
    _ = try os.replaceFileConfined(dir, "settings.fset", "original", 1024);

    // Too large: refused before anything is opened, which is the only way a bound on
    // untrusted size is worth having.
    try testing.expectError(
        error.FileTooLarge,
        os.replaceFileConfined(dir, "settings.fset", "much too long", 4),
    );
    // A directory component that does not exist: the walk fails before the temporary
    // file, so there is nothing to clean up and nothing to damage.
    try testing.expectError(
        error.FileNotFound,
        os.replaceFileConfined(dir, "absent/settings.fset", "x", 1024),
    );
    // Escaping the root is a path error, not a file that happens not to be there.
    try testing.expectError(
        error.InvalidPath,
        os.replaceFileConfined(dir, "../escaped.fset", "x", 1024),
    );
    try testing.expectError(
        error.InvalidPath,
        os.replaceFileConfined(dir, "", "x", 1024),
    );

    const read = try os.readFileConfined(testing.allocator, dir, "settings.fset", 1024);
    defer testing.allocator.free(read.bytes);
    try testing.expectEqualStrings("original", read.bytes);
    try testing.expectEqual(@as(usize, 1), try countEntries(os, dir));
}

test "a replacement overwrites a symlinked destination instead of what it points at" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var os = try testOs(&.{});
    defer os.deinit();

    var root_tmp = testing.tmpDir(.{});
    defer root_tmp.cleanup();
    var outside_tmp = testing.tmpDir(.{});
    defer outside_tmp.cleanup();
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var outside_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpPath(&root_tmp, &root_buf);
    const outside = try tmpPath(&outside_tmp, &outside_buf);

    const target = try joinPath(testing.allocator, &.{ outside, "elsewhere.fset" });
    defer testing.allocator.free(target);
    try os.writeFile(target, "not yours");

    try root_tmp.dir.symLink(testing.io, target, "settings.fset", .{});
    try root_tmp.dir.symLink(testing.io, outside, "linked", .{ .is_directory = true });

    // The destination is replaced as a name: the link is gone and the file it pointed at
    // is untouched. A writer that resolved the link first would have written through it.
    _ = try os.replaceFileConfined(root, "settings.fset", "ours", 1024);
    const elsewhere = try os.readFile(testing.allocator, target, 1024);
    defer testing.allocator.free(elsewhere);
    try testing.expectEqualStrings("not yours", elsewhere);

    const read = try os.readFileConfined(testing.allocator, root, "settings.fset", 1024);
    defer testing.allocator.free(read.bytes);
    try testing.expectEqualStrings("ours", read.bytes);

    // An intermediate link is refused outright: there is no version of following one that
    // stays inside the root the host handed over.
    try testing.expectError(
        error.InvalidPath,
        os.replaceFileConfined(root, "linked/elsewhere.fset", "x", 1024),
    );
}

test "a replacement refuses a name it cannot build a temporary beside" {
    var os = try testOs(&.{});
    defer os.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try tmpPath(&tmp, &buf);

    const long = try testing.allocator.alloc(u8, max_replaceable_name + 1);
    defer testing.allocator.free(long);
    @memset(long, 'n');

    try testing.expectError(error.InvalidPath, os.replaceFileConfined(dir, long, "x", 1024));
    try testing.expectEqual(@as(usize, 0), try countEntries(os, dir));
}

test "temporary names differ between replacements in one process" {
    var os = try testOs(&.{});
    defer os.deinit();

    var first: [temp_name_max]u8 = undefined;
    var second: [temp_name_max]u8 = undefined;
    const a = try os.tempName(&first, "settings.fset");
    const b = try os.tempName(&second, "settings.fset");

    try testing.expect(!std.mem.eql(u8, a, b));
    try testing.expect(std.mem.startsWith(u8, a, ".settings.fset.tmp-"));
    try testing.expect(a.len <= temp_name_max);
}

test "a replacement into a directory it may not write leaves the old file alone" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var os = try testOs(&.{});
    defer os.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const parent = try tmpPath(&tmp, &buf);
    const dir = try joinPath(testing.allocator, &.{ parent, "user-data" });
    defer testing.allocator.free(dir);
    try os.createDirPath(dir);
    _ = try os.replaceFileConfined(dir, "settings.fset", "original", 1024);

    const read_only: std.Io.File.Permissions = @enumFromInt(0o555);
    const writable: std.Io.File.Permissions = @enumFromInt(0o755);
    try tmp.dir.setFilePermissions(testing.io, "user-data", read_only, .{});
    defer tmp.dir.setFilePermissions(testing.io, "user-data", writable, .{}) catch {};

    // The temporary file cannot even be created, which is the earliest of the boundaries
    // a replacement can fail at and the one that must obviously not destroy anything.
    try testing.expectError(
        error.AccessDenied,
        os.replaceFileConfined(dir, "settings.fset", "replacement", 1024),
    );

    const read = try os.readFileConfined(testing.allocator, dir, "settings.fset", 1024);
    defer testing.allocator.free(read.bytes);
    try testing.expectEqualStrings("original", read.bytes);
    try testing.expectEqual(@as(usize, 1), try countEntries(os, dir));
}

test "an application directory name is one ordinary component" {
    try testing.expect(isValidAppName("foundry"));
    try testing.expect(isValidAppName("foundry-room"));
    try testing.expect(isValidAppName("foundry_sandbox.2"));

    try testing.expect(!isValidAppName(""));
    try testing.expect(!isValidAppName("."));
    try testing.expect(!isValidAppName(".."));
    try testing.expect(!isValidAppName("has/slash"));
    try testing.expect(!isValidAppName("has\\backslash"));
    try testing.expect(!isValidAppName("has space"));
    try testing.expect(!isValidAppName("caf\u{00e9}"));
    try testing.expect(!isValidAppName("n" ** 65));

    // Refused where it enters rather than where it becomes a path, so that no caller of
    // `userDataDirAlloc` has to wonder.
    try testing.expectError(
        error.InvalidAppName,
        Os.init(testing.allocator, .{ .app_name = "../escape" }),
    );
}
