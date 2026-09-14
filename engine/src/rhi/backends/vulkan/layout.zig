//! How a buffer-to-texture copy's source rows reach Vulkan (`docs/design/vulkan.md` §5.3).
//!
//! The RHI describes a source in bytes: an offset, and a stride between rows. Vulkan's
//! `VkBufferImageCopy` describes it in texels: `bufferRowLength` counts texels, and the offset
//! must be a whole number of texels. A layout the RHI allows that Vulkan cannot express is
//! repacked on the GPU, row by row into a tightly packed staging buffer — never narrowed, and
//! never read on the CPU, because the source may be device-local and its bytes are the ones the
//! queue holds when the copy executes.
//!
//! Plain arithmetic with no Vulkan header, so it is tested on every host.

const std = @import("std");

/// Vulkan can read the source where it is.
pub const Direct = struct {
    offset: u64,
    /// `bufferRowLength`: the stride in texels.
    row_texels: u32,
};

/// The source must be repacked first: `rows` copies of `row_bytes`, one every `stride` bytes
/// from the source offset, into a staging buffer of `packed_size` bytes.
pub const Repack = struct {
    row_bytes: u64,
    stride: u64,
    rows: u32,
    packed_size: u64,
};

pub const Plan = union(enum) { direct: Direct, repack: Repack };

/// Rule 10 has already put every row inside the buffer and a nonzero stride at a row or more.
pub fn plan(src_offset: u64, src_bytes_per_row: u32, width: u32, height: u32, bytes_per_texel: u32) Plan {
    const row_bytes = @as(u64, width) * bytes_per_texel;
    const stride: u64 = if (src_bytes_per_row == 0) row_bytes else src_bytes_per_row;
    if (src_offset % bytes_per_texel == 0 and stride % bytes_per_texel == 0) {
        return .{ .direct = .{ .offset = src_offset, .row_texels = @intCast(stride / bytes_per_texel) } };
    }
    return .{ .repack = .{ .row_bytes = row_bytes, .stride = stride, .rows = height, .packed_size = row_bytes * height } };
}

/// Where row `row` starts in the source.
pub fn rowOffset(src_offset: u64, stride: u64, row: u32) u64 {
    return src_offset + stride * row;
}

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

test "a tightly packed or texel-aligned source is read where it is" {
    try testing.expectEqual(Plan{ .direct = .{ .offset = 0, .row_texels = 5 } }, plan(0, 0, 5, 3, 4));
    // Padding that is a whole number of texels is still expressible.
    try testing.expectEqual(Plan{ .direct = .{ .offset = 8, .row_texels = 6 } }, plan(8, 24, 5, 3, 4));
    // One byte per texel can express any layout at all.
    try testing.expectEqual(Plan{ .direct = .{ .offset = 3, .row_texels = 7 } }, plan(3, 7, 5, 3, 1));
}

test "an odd stride or offset is repacked, never narrowed" {
    // 22 bytes between rows of 20: two bytes of padding, which no texel count describes.
    try testing.expectEqual(
        Plan{ .repack = .{ .row_bytes = 20, .stride = 22, .rows = 3, .packed_size = 60 } },
        plan(0, 22, 5, 3, 4),
    );
    try testing.expectEqual(
        Plan{ .repack = .{ .row_bytes = 20, .stride = 20, .rows = 3, .packed_size = 60 } },
        plan(3, 0, 5, 3, 4),
    );
    // Eight bytes per texel: a 20-byte stride is two and a half texels.
    try testing.expect(plan(0, 20, 2, 2, 8) == .repack);
    try testing.expectEqual(Plan{ .direct = .{ .offset = 0, .row_texels = 3 } }, plan(0, 24, 2, 2, 8));
}

test "a repacked row is read at its own stride from the source offset" {
    try testing.expectEqual(@as(u64, 3), rowOffset(3, 22, 0));
    try testing.expectEqual(@as(u64, 47), rowOffset(3, 22, 2));
}
