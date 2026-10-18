//! A texture's CPU work, off the main thread: the decode both renderers' split texture loaders
//! share (`docs/design/background.md` §7, ADR-0062).
//!
//! A `foundry:texture` record's bytes become an image, and, if the record asks for mipmaps,
//! the image's whole chain. Only the upload is left for the renderer's finish, so the part of a
//! load that grows with the texture's size happens wherever the registry ran the decode.
//!
//! **Pure**: it reads the record, the bytes and the limit it is handed, and logs nothing. A
//! sampler or colour-space spelling it does not know falls back to the schema's default here
//! and is reported by the renderer's finish, which reads the same field on the main thread.

const std = @import("std");
const data = @import("data");

const image_mod = @import("image.zig");
const mips = @import("mips.zig");
const png = @import("png.zig");
const registry = @import("registry.zig");
const schemas = @import("schemas.zig");

const Allocator = std.mem.Allocator;
const Record = data.store.Record;

/// What a renderer's texture loader hands its decode as `decode_ctx`: a device limit, copied
/// once, never the device.
pub const Limits = struct {
    max_dimension: u32,
};

/// A decoded texture: the image, or its chain when the record asked for mipmaps. A chain's
/// level 0 is a copy of the image, so the image is freed once the chain exists.
pub const Decoded = struct {
    width: u32,
    height: u32,
    /// Present without mipmaps.
    image: ?image_mod.Image,
    /// Present with them.
    chain: ?mips.Chain,
    /// The upload memory a renderer's `Stage.prepare` reserved, which `fill` copies into. A
    /// renderer that does not stage leaves it null.
    staged: ?Staged = null,

    /// The bytes the finish uploads, every level included.
    pub fn byteSize(self: *const Decoded) usize {
        if (self.chain) |chain| return chain.bytes.len;
        return self.image.?.pixels.len;
    }

    /// The bytes the finish uploads, every level included, in upload order.
    pub fn bytes(self: *const Decoded) []const u8 {
        if (self.chain) |chain| return chain.bytes;
        return self.image.?.pixels;
    }

    pub fn deinit(self: *Decoded, gpa: Allocator) void {
        // A reservation belongs to the renderer, and is consumed or released before this.
        std.debug.assert(self.staged == null);
        if (self.image) |*image| image.deinit(gpa);
        if (self.chain) |*chain| chain.deinit(gpa);
        self.* = undefined;
    }
};

/// The `Split.decode` both renderers name: PNG decode bounded by `limits`, then the mip chain
/// if the record asks for one.
pub fn decode(decode_ctx: ?*const anyopaque, gpa: Allocator, record: Record, bytes: []const u8) registry.LoadError!registry.Decoded {
    const limits: *const Limits = @ptrCast(@alignCast(decode_ctx orelse return error.LoadFailed));
    var image = png.decode(gpa, bytes, .{ .max_dimension = limits.max_dimension }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // A valid PNG this decoder does not handle: the file is fine, and the answer for the
        // author is different, which is the distinction `UnsupportedVersion` carries.
        error.UnsupportedImage => error.UnsupportedVersion,
        // Not the content's fault and not a version: this device cannot hold it.
        error.ImageTooLarge => error.LoadFailed,
        error.InvalidImage => error.InvalidAsset,
    };
    errdefer image.deinit(gpa);

    const decoded = try gpa.create(Decoded);
    errdefer gpa.destroy(decoded);
    decoded.* = .{ .width = image.width, .height = image.height, .image = image, .chain = null };
    if (wantsMipmaps(record)) {
        decoded.chain = try mips.generate(gpa, image, colorSpaceOf(record));
        image.deinit(gpa);
        decoded.image = null;
    }
    return .fromPointer(decoded);
}

/// Mapped upload memory, reserved on the main thread by whichever renderer stages, and
/// written by `fill` on any thread. `token` is the renderer's own name for it.
pub const Staged = struct {
    bytes: []u8,
    token: u64,
};

/// The `Stage.fill` a staging renderer names: the upload's bytes into its reservation. Pure
/// memory work, on whichever thread the registry runs it.
pub fn fill(decoded: registry.Decoded) void {
    const value = of(decoded);
    const source = value.bytes();
    @memcpy(value.staged.?.bytes[0..source.len], source);
}

/// The `Split.discard` both renderers name.
pub fn discard(gpa: Allocator, decoded: registry.Decoded) void {
    const value = of(decoded);
    value.deinit(gpa);
    gpa.destroy(value);
}

/// The decoded texture behind a `registry.Decoded`.
pub fn of(decoded: registry.Decoded) *Decoded {
    return @ptrCast(@alignCast(decoded.pointer().?));
}

pub fn wantsMipmaps(record: Record) bool {
    return schemas.boolField(record, schemas.texture, schemas.mipmaps_field) orelse false;
}

/// The record's colour space, or the schema's default for a spelling this build does not know.
pub fn colorSpaceOf(record: Record) mips.ColorSpace {
    const text = schemas.stringField(record, schemas.texture, schemas.color_space_field) orelse return .srgb;
    return std.meta.stringToEnum(mips.ColorSpace, text) orelse .srgb;
}
