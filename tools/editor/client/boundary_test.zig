//! Source-level half of the editor-client boundary check.
//!
//! The module graph is the primary guard: `editor_client` receives only `foundry_api`.
//! This test closes escape routes that do not need a named engine import, especially direct
//! filesystem/process/dynamic-library use from `std`.  The build also compiles a deliberate
//! forbidden import and expects it to fail.

const std = @import("std");

const client = @embedFile("root.zig");

test "the editor client has no implementation or host escape route" {
    const forbidden = [_][]const u8{
        "@import(\"abi\")",
        "@import(\"author\")",
        "@import(\"app\")",
        "@import(\"asset\")",
        "@import(\"core\")",
        "@import(\"data\")",
        "@import(\"mod\")",
        "@import(\"platform\")",
        "@import(\"render2d\")",
        "@import(\"rhi\")",
        "@import(\"ui\")",
        "@cImport",
        "std.fs",
        "std.process",
        "std.DynLib",
        "std.os",
        "dlopen",
        "CreateProcess",
    };
    for (forbidden) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, client, needle) == null);
    }
}
