//! Foundry `net` — layer L2.
//!
//! It has no transport or session lifecycle yet. Step 1 froze the checked host
//! limits, runtime channel description and FNET wire-v1 codec; the
//! authenticated streams that carry them are `platform.Transport` (Step 2),
//! and sessions over those streams are Step 3 (`docs/design/networking.md`).

pub const channel = @import("channel.zig");
pub const limits = @import("limits.zig");
pub const wire = @import("wire.zig");

test {
    _ = channel;
    _ = limits;
    _ = wire;
}
