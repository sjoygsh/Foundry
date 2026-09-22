//! Foundry `net` — layer L2.
//!
//! Step 1 froze the checked host limits, runtime channel description and FNET wire-v1
//! codec. The authenticated streams that carry them are `platform.Transport` (Step 2).
//! Step 3 added the `Service`: grants, sessions and peers, compatibility negotiation,
//! the allowlist, pre-authentication limits, deadlines and budgets. Step 4 added the
//! baseline and its acknowledgement, activation, commands admitted in tick batches and
//! replaceable complete state (`docs/design/networking.md`). The public ABI is Step 5's.

pub const channel = @import("channel.zig");
pub const compatibility = @import("compatibility.zig");
pub const limiter = @import("limiter.zig");
pub const limits = @import("limits.zig");
pub const service = @import("service.zig");
pub const wire = @import("wire.zig");

pub const Service = service.Service;

test {
    _ = channel;
    _ = compatibility;
    _ = limiter;
    _ = limits;
    _ = service;
    _ = wire;
}
