//! Dynamic library loading.
//!
//! This is how native mods (Tier 3, M7) will be loaded, and it may later serve backend
//! selection. Everything about it is untrusted: the library may be missing, may fail
//! to load, or may lack the expected symbol. Every one of those is a reported error.
//! **Loading a native mod is a consenting-adults operation** (`CLAUDE.md` §5) — but
//! consenting to run someone's code is not consenting to crash on a typo in a filename.
//!
//! Foundry declares the Windows loader imports itself rather than using `std.DynLib`,
//! because `std.DynLib` in Zig 0.16 is a compile error on Windows: its backing type
//! resolves to a stub whose `open` is `@compileError("unsupported platform")`.
//! Verified against the pinned compiler, not assumed. Since Windows is a supported
//! target (ADR-0008) and native mods are a fundamental feature rather than a later
//! addition (`CLAUDE.md` §5), waiting for `std` to fill the gap is not an option, and
//! three `extern` declarations are a small price for not being hostage to it.
//!
//! Design: `docs/design/platform-interface.md` §6.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");

const log = core.log.scoped(.platform);

pub const LibraryError = error{
    /// No file at that path.
    LibraryNotFound,
    /// The file exists but the OS refused to load it: wrong architecture, missing
    /// transitive dependency, corrupt image, or a signature the OS did not accept.
    LibraryLoadFailed,
    /// The path was malformed — not valid UTF-8, or too long for the OS.
    InvalidPath,
    OutOfMemory,
};

const is_windows = builtin.os.tag == .windows;

const win = if (is_windows) struct {
    const windows = std.os.windows;

    extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const u16) callconv(.winapi) ?windows.HMODULE;
    extern "kernel32" fn LoadLibraryExW(lpLibFileName: [*:0]const u16, hFile: ?*anyopaque, dwFlags: u32) callconv(.winapi) ?windows.HMODULE;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "kernel32" fn SetDllDirectoryW(lpPathName: ?[*:0]const u16) callconv(.winapi) c_int;
    extern "kernel32" fn GetProcAddress(hModule: windows.HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?windows.FARPROC;
    extern "kernel32" fn FreeLibrary(hLibModule: windows.HMODULE) callconv(.winapi) windows.BOOL;

    /// Search `System32` only, for the library and for everything it imports.
    const LOAD_LIBRARY_SEARCH_SYSTEM32: u32 = 0x00000800;
    const ERROR_MOD_NOT_FOUND: u32 = 126;
    const ERROR_BAD_EXE_FORMAT: u32 = 193;
} else struct {};

/// An open dynamic library.
///
/// Symbols resolved from it are only valid while it is open; closing it invalidates
/// every pointer obtained from it, including any the loaded code handed back. That is
/// inherent to dynamic loading rather than something this wrapper could fix, so mod
/// unloading (M7) has to treat it as a lifecycle problem, not a memory-safety one.
pub const Library = struct {
    handle: Handle,

    const Handle = if (is_windows) std.os.windows.HMODULE else std.DynLib;

    /// Opens a library by filesystem path.
    ///
    /// `gpa` is used only for the transient path conversion on Windows and holds
    /// nothing after this returns.
    pub fn open(gpa: std.mem.Allocator, path: []const u8) LibraryError!Library {
        if (is_windows) {
            const wide = std.unicode.utf8ToUtf16LeAllocZ(gpa, path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidUtf8 => return error.InvalidPath,
            };
            defer gpa.free(wide);

            const module = win.LoadLibraryW(wide.ptr) orelse {
                log.warn("failed to load library '{s}'", .{path});
                return error.LibraryLoadFailed;
            };
            return .{ .handle = module };
        }

        const lib = std.DynLib.open(path) catch |err| switch (err) {
            error.FileNotFound => return error.LibraryNotFound,
            error.OutOfMemory => return error.OutOfMemory,
            error.NameTooLong => return error.InvalidPath,
            else => {
                log.warn("failed to load library '{s}': {t}", .{ path, err });
                return error.LibraryLoadFailed;
            },
        };
        return .{ .handle = lib };
    }

    /// Opens a library the operating system provides, **by name, from the system's own
    /// location only**: never by path, and never from beside the executable or the working
    /// directory.
    ///
    /// The difference from `open` is the search. The ordinary Windows loader looks for a bare
    /// name beside the executable first, so a same-named DLL planted there is loaded instead of
    /// the system's. Here Windows searches only `System32`, for the library and for what it
    /// imports; a library that is not there, or one whose import is missing, is
    /// `LibraryNotFound`. On Linux and macOS the name goes to the C runtime's `dlopen`, which
    /// applies the system loader's own policy to a name without a slash. A Linux build that
    /// links no libc has no such loader, so it refuses rather than guessing directories.
    /// Explicit-path loading — native mods — stays with `open`.
    ///
    /// `name` must be a bare file name, such as `kernel32.dll` or `libc.so.6`. Anything that
    /// could name a location — a separator, a drive, `.` or `..` — is `InvalidPath`.
    pub fn openSystem(gpa: std.mem.Allocator, name: []const u8) LibraryError!Library {
        if (!isSystemLibraryName(name)) return error.InvalidPath;

        if (is_windows) {
            const wide = std.unicode.utf8ToUtf16LeAllocZ(gpa, name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidUtf8 => return error.InvalidPath,
            };
            defer gpa.free(wide);

            const module = win.LoadLibraryExW(wide.ptr, null, win.LOAD_LIBRARY_SEARCH_SYSTEM32) orelse {
                const code = win.GetLastError();
                if (code == win.ERROR_MOD_NOT_FOUND) return error.LibraryNotFound;
                log.warn("failed to load system library '{s}' (Windows error {d})", .{ name, code });
                return error.LibraryLoadFailed;
            };
            return .{ .handle = module };
        }

        if (builtin.os.tag == .linux and !builtin.link_libc) {
            log.warn("system library '{s}' needs the C runtime's loader, and this build links no libc", .{name});
            return error.LibraryLoadFailed;
        }

        const lib = std.DynLib.open(name) catch |err| switch (err) {
            error.FileNotFound => return error.LibraryNotFound,
            error.OutOfMemory => return error.OutOfMemory,
            error.NameTooLong => return error.InvalidPath,
            else => {
                log.warn("failed to load system library '{s}': {t}", .{ name, err });
                return error.LibraryLoadFailed;
            },
        };
        return .{ .handle = lib };
    }

    pub fn close(self: *Library) void {
        if (is_windows) {
            _ = win.FreeLibrary(self.handle);
        } else {
            self.handle.close();
        }
        self.* = undefined;
    }

    /// Resolves a symbol, or null if the library does not export it.
    ///
    /// Null rather than an error because a missing symbol is usually a *question* —
    /// "does this mod provide an optional hook?" — and the caller that genuinely
    /// requires the symbol is better placed to say what its absence means.
    ///
    /// The caller asserts `T` matches what the library actually exports. Nothing can
    /// check that, which is precisely why native mods are the consenting-adults tier
    /// and why the ABI they call through is versioned (I8).
    pub fn symbol(self: *Library, comptime T: type, name: [:0]const u8) ?T {
        if (is_windows) {
            const proc = win.GetProcAddress(self.handle, name.ptr) orelse return null;
            return @ptrCast(@alignCast(proc));
        }
        return self.handle.lookup(T, name);
    }
};

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

test "opening a library that is not there is an error, not a crash" {
    // Untrusted input, all the way down: a mod manifest naming a missing file must
    // produce a diagnosable error.
    const result = Library.open(testing.allocator, "foundry-no-such-library.dylib");
    try testing.expect(std.meta.isError(result));
}

test "opening a path that is not a library is an error, not a crash" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "not-a-library.so", .data = "this is not an object file" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(testing.io, "not-a-library.so", &buf);
    const path = buf[0..n];

    const result = Library.open(testing.allocator, path);
    try testing.expect(std.meta.isError(result));
}

test "the loader compiles for every supported target" {
    // The point of this test is that its body is analysed at all: `std.DynLib` is a
    // compile error on Windows in Zig 0.16, which is why the Windows path is written
    // here rather than delegated. `zig build check -Dtarget=x86_64-windows-gnu` is
    // what actually exercises it.
    var never = false;
    _ = &never;
    if (never) {
        var lib = try Library.open(testing.allocator, "x");
        defer lib.close();
        _ = lib.symbol(*const fn () callconv(.c) void, "y");
        var system = try Library.openSystem(testing.allocator, "x");
        defer system.close();
    }
}

/// Whether `name` is a bare file name that cannot name a location on any supported OS.
fn isSystemLibraryName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    // Windows silently drops a trailing dot or space, which would make `x.dll.` a second
    // spelling of `x.dll`; it also rules out `.` and `..`.
    const last = name[name.len - 1];
    if (last == '.' or last == ' ') return false;
    for (name) |ch| switch (ch) {
        0, '/', '\\', ':' => return false,
        else => {},
    };
    return true;
}

test "a system library is named, never located" {
    const located = [_][]const u8{
        "",                                    ".",                  "..",
        "sub/libx.so",                         "..\\x.dll",          "C:x.dll",
        "C:\\Windows\\System32\\kernel32.dll", "/usr/lib/libc.so.6", "x.dll.",
        "x.dll ",                              "lib\x00c.so",
    };
    for (located) |name| {
        try testing.expectError(error.InvalidPath, Library.openSystem(testing.allocator, name));
    }
}

test "a system library that is not installed is not found" {
    const name = if (is_windows) "foundry-no-such-system-library.dll" else "libfoundry-no-such-system-library.so.0";
    const result = Library.openSystem(testing.allocator, name);
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        try testing.expectError(error.LibraryLoadFailed, result);
    } else {
        try testing.expectError(error.LibraryNotFound, result);
    }
}

test "a system library opens from the system's own location" {
    const name, const symbol_name = switch (builtin.os.tag) {
        .windows => .{ "kernel32.dll", "GetTickCount64" },
        .macos => .{ "libSystem.B.dylib", "getpid" },
        .linux => if (builtin.link_libc) .{ "libc.so.6", "getpid" } else return error.SkipZigTest,
        else => return error.SkipZigTest,
    };
    var lib = try Library.openSystem(testing.allocator, name);
    defer lib.close();
    try testing.expect(lib.symbol(*const fn () callconv(.c) void, symbol_name) != null);
}

test "a lookalike planted beside the process is not a system library" {
    // Windows only: the preloading attack this search order exists to stop is a Windows
    // loader behaviour. `SetDllDirectoryW` injects a directory straight after the
    // executable's own in the ordinary search order, which is where a planted DLL sits.
    if (!is_windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const name = "foundry-lookalike-system-library.dll";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = "this is not an image" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(testing.io, name, &buf);
    const dir = std.fs.path.dirname(buf[0..n]) orelse return error.TestUnexpectedResult;
    const wide_dir = try std.unicode.utf8ToUtf16LeAllocZ(testing.allocator, dir);
    defer testing.allocator.free(wide_dir);
    try testing.expect(win.SetDllDirectoryW(wide_dir.ptr) != 0);
    defer _ = win.SetDllDirectoryW(null);

    // The ordinary search reaches the plant: it is not an image, and the OS says so.
    const wide_name = try std.unicode.utf8ToUtf16LeAllocZ(testing.allocator, name);
    defer testing.allocator.free(wide_name);
    try testing.expect(win.LoadLibraryW(wide_name.ptr) == null);
    try testing.expectEqual(win.ERROR_BAD_EXE_FORMAT, win.GetLastError());

    // The system search never sees it.
    try testing.expectError(error.LibraryNotFound, Library.openSystem(testing.allocator, name));
}
