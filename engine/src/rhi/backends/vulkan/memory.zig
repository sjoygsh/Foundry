//! Choosing the memory a resource is allocated from (`docs/design/vulkan.md` §5.2).
//!
//! The backend reads each memory type's property flags into `TypeFlags`, and these functions
//! decide. Plain data with no Vulkan header, so the choice is tested on every host.
//!
//! One allocation per resource, from the best type the resource's own `memoryTypeBits` allows.
//! Vulkan lists types with the same properties in order of preference, so equal scores keep the
//! earlier type. No suballocation: §5.2 waits for measured need.

const std = @import("std");
const resource = @import("../../resource.zig");

pub const TypeFlags = struct {
    device_local: bool = false,
    host_visible: bool = false,
    host_coherent: bool = false,
    host_cached: bool = false,
};

/// The type to allocate from, or null when no allowed type can serve the intent.
///
/// `device_local` accepts any type and prefers memory the host cannot see: it is never mapped,
/// whatever the heap allows. `upload` and `readback` must be mappable; an upload prefers coherent
/// memory, which needs no flush, and a readback prefers cached memory, which is fast to read.
pub fn chooseType(types: []const TypeFlags, allowed: u32, intent: resource.MemoryIntent) ?u32 {
    var best: ?u32 = null;
    var best_score: u8 = 0;
    for (types, 0..) |flags, i| {
        if (i >= 32 or (allowed >> @intCast(i)) & 1 == 0) continue;
        const score: u8 = switch (intent) {
            .device_local => @as(u8, if (flags.device_local) 2 else 0) + @as(u8, if (flags.host_visible) 0 else 1),
            .upload => if (!flags.host_visible) continue else @as(u8, if (flags.host_coherent) 2 else 0) + 1,
            .readback => if (!flags.host_visible) continue else @as(u8, if (flags.host_cached) 2 else 0) +
                @as(u8, if (flags.host_coherent) 1 else 0) + 1,
        };
        if (best == null or score > best_score) {
            best = @intCast(i);
            best_score = score;
        }
    }
    return best;
}

/// Whether the device's memory justifies reporting `unified_memory`: it has device-local memory,
/// and all of it is visible to the host. Conservative, because the renderer takes a direct-upload
/// shortcut on that answer, and a discrete GPU with a host-visible window onto some of its memory
/// is still a discrete GPU.
pub fn unified(types: []const TypeFlags) bool {
    var any = false;
    for (types) |flags| {
        if (!flags.device_local) continue;
        if (!flags.host_visible) return false;
        any = true;
    }
    return any;
}

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

/// A discrete GPU's usual list: private memory, two host kinds, and a resizable-BAR window.
const discrete = [_]TypeFlags{
    .{ .device_local = true },
    .{ .host_visible = true, .host_coherent = true },
    .{ .host_visible = true, .host_coherent = true, .host_cached = true },
    .{ .device_local = true, .host_visible = true, .host_coherent = true },
};

const all: u32 = 0xffff_ffff;

test "device-local resources prefer memory the host cannot see" {
    try testing.expectEqual(@as(?u32, 0), chooseType(&discrete, all, .device_local));
    // Without it, device-local memory the host can see, then any memory at all.
    try testing.expectEqual(@as(?u32, 3), chooseType(&discrete, 0b1110, .device_local));
    try testing.expectEqual(@as(?u32, 1), chooseType(&discrete, 0b0010, .device_local));
}

test "uploads and readbacks need host-visible memory and prefer what serves them" {
    // Coherent for an upload; the first of equals wins.
    try testing.expectEqual(@as(?u32, 1), chooseType(&discrete, all, .upload));
    // Cached for a readback.
    try testing.expectEqual(@as(?u32, 2), chooseType(&discrete, all, .readback));
    // A resource whose own requirements allow only private memory cannot be mapped at all.
    try testing.expectEqual(@as(?u32, null), chooseType(&discrete, 0b0001, .upload));
    try testing.expectEqual(@as(?u32, null), chooseType(&discrete, 0b0001, .readback));
    // Non-coherent memory still serves; the backend flushes and invalidates it.
    const only_cached = [_]TypeFlags{.{ .host_visible = true, .host_cached = true }};
    try testing.expectEqual(@as(?u32, 0), chooseType(&only_cached, all, .readback));
    try testing.expectEqual(@as(?u32, 0), chooseType(&only_cached, all, .upload));
}

test "no allowed type is null" {
    try testing.expectEqual(@as(?u32, null), chooseType(&discrete, 0, .device_local));
    try testing.expectEqual(@as(?u32, null), chooseType(&.{}, all, .device_local));
}

test "unified memory is claimed only when all device-local memory is host-visible" {
    try testing.expect(!unified(&discrete));
    const integrated = [_]TypeFlags{
        .{ .device_local = true, .host_visible = true, .host_coherent = true },
        .{ .device_local = true, .host_visible = true, .host_coherent = true, .host_cached = true },
    };
    try testing.expect(unified(&integrated));
    try testing.expect(!unified(&.{.{ .host_visible = true }}));
    try testing.expect(!unified(&.{}));
}
