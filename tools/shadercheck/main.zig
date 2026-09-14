//! Build-time agreement check for Foundry's four Vulkan shader stages.
//!
//! `glslangValidator` produces the input and `spirv-val` validates its semantics. This
//! small tool checks the decorations Foundry's CPU producers and pipeline descriptors rely
//! on, then copies the accepted bytes to the build output consumed by the runtime.

const std = @import("std");
const spirv = @import("spirv");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    var it = try init.minimal.args.iterateAllocator(gpa);
    defer it.deinit();
    _ = it.skip();

    const input = it.next() orelse return usage(init);
    const profile_name = it.next() orelse return usage(init);
    const output = it.next() orelse return usage(init);
    if (it.next() != null) return usage(init);

    const profile = std.meta.stringToEnum(spirv.Profile, profile_name) orelse return usage(init);
    const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, input, gpa, .limited(1 << 20)) catch |err| {
        return fail(init, "read input", err);
    };
    defer gpa.free(bytes);

    spirv.validateProfile(bytes, profile) catch |err| return fail(init, "shader ABI", err);
    std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output, .data = bytes }) catch |err| {
        return fail(init, "write output", err);
    };
    return 0;
}

fn usage(init: std.process.Init) u8 {
    var buf: [512]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &buf);
    stderr.interface.writeAll("usage: fshadercheck <input.spv> <profile> <output.spv>\n") catch {};
    stderr.interface.flush() catch {};
    return 2;
}

fn fail(init: std.process.Init, what: []const u8, err: anyerror) u8 {
    var buf: [512]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &buf);
    stderr.interface.print("fshadercheck: {s}: {t}\n", .{ what, err }) catch {};
    stderr.interface.flush() catch {};
    return 1;
}
