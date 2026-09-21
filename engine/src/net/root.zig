//! Foundry `net` — layer L2.
//!
//! M16 Step 1 contains no transport or session lifecycle. It freezes the
//! checked host limits, runtime channel description and FNET wire-v1 codec
//! which later authenticated streams carry (`docs/design/networking.md`).

pub const channel = @import("channel.zig");
pub const limits = @import("limits.zig");
pub const wire = @import("wire.zig");

test {
    _ = channel;
    _ = limits;
    _ = wire;
}
