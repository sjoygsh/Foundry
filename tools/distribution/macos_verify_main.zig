//! Verifies the text produced by the macOS platform inspection tools.
//!
//! `otool` and `dwarfdump` remain the authorities for Mach-O details. The build captures their
//! output and hands it here so a forbidden dependency or mismatched dSYM is a failing gate,
//! not merely text an operator was expected to notice (`distribution.md` §11).

const std = @import("std");
const macos = @import("macos.zig");

const usage =
    \\fmacos-verify --dependencies <otool-output> --binary-uuid <dwarfdump-output>
    \\                --symbols-uuid <dwarfdump-output> [--bundled <load-path>] ...
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    var it = try init.minimal.args.iterateAllocator(gpa);
    defer it.deinit();
    _ = it.skip();

    var dependencies: ?[]const u8 = null;
    var binary_uuid: ?[]const u8 = null;
    var symbols_uuid: ?[]const u8 = null;
    var bundled: std.ArrayList([]const u8) = .empty;
    defer bundled.deinit(gpa);

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--dependencies")) {
            dependencies = it.next() orelse return badUsage(init, "--dependencies needs a file");
        } else if (std.mem.eql(u8, arg, "--binary-uuid")) {
            binary_uuid = it.next() orelse return badUsage(init, "--binary-uuid needs a file");
        } else if (std.mem.eql(u8, arg, "--symbols-uuid")) {
            symbols_uuid = it.next() orelse return badUsage(init, "--symbols-uuid needs a file");
        } else if (std.mem.eql(u8, arg, "--bundled")) {
            try bundled.append(gpa, it.next() orelse return badUsage(init, "--bundled needs a load path"));
        } else return badUsage(init, "unexpected argument");
    }

    const dependency_path = dependencies orelse return badUsage(init, "--dependencies is required");
    const binary_path = binary_uuid orelse return badUsage(init, "--binary-uuid is required");
    const symbols_path = symbols_uuid orelse return badUsage(init, "--symbols-uuid is required");

    const dependency_text = try read(init, gpa, dependency_path);
    defer gpa.free(dependency_text);
    const binary_text = try read(init, gpa, binary_path);
    defer gpa.free(binary_text);
    const symbols_text = try read(init, gpa, symbols_path);
    defer gpa.free(symbols_text);

    macos.verifyDependencies(dependency_text, bundled.items) catch |err| {
        return fail(init, "Mach-O dependencies", err);
    };
    macos.verifySymbolUuids(gpa, binary_text, symbols_text) catch |err| {
        return fail(init, "retained symbols", err);
    };
    return 0;
}

fn read(init: std.process.Init, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(1 << 20));
}

fn badUsage(init: std.process.Init, message: []const u8) u8 {
    var buf: [2048]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &buf);
    stderr.interface.print("fmacos-verify: {s}\n{s}", .{ message, usage }) catch {};
    stderr.interface.flush() catch {};
    return 2;
}

fn fail(init: std.process.Init, what: []const u8, err: anyerror) u8 {
    var buf: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &buf);
    stderr.interface.print("fmacos-verify: {s} failed: {t}\n", .{ what, err }) catch {};
    stderr.interface.flush() catch {};
    return 1;
}
