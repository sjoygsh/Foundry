//! Source-level half of the shared markers' boundary check.
//!
//! The module graph is the primary guard: `markers` receives only `foundry_api`. This test
//! closes the routes that need no named engine import — `std`'s filesystem, processes,
//! dynamic libraries and sockets — and the build also compiles a deliberate forbidden import
//! inside the same graph and expects it to fail.

const std = @import("std");

const consumer = @embedFile("root.zig");

test "the shared markers have no implementation, host or network escape route" {
    const forbidden = [_][]const u8{
        "@import(\"abi\")",
        "@import(\"app\")",
        "@import(\"asset\")",
        "@import(\"core\")",
        "@import(\"data\")",
        "@import(\"net\")",
        "@import(\"platform\")",
        "@import(\"render2d\")",
        "@import(\"scene\")",
        "@import(\"ui\")",
        "@cImport",
        "std.fs",
        "std.net",
        "std.posix",
        "std.process",
        "std.DynLib",
        "std.os",
        "std.Io.net",
        "dlopen",
        "socket(",
    };
    for (forbidden) |needle| {
        if (std.mem.indexOf(u8, consumer, needle) != null) {
            std.debug.print("the markers consumer names '{s}'\n", .{needle});
            return error.EscapeRoute;
        }
    }
}
