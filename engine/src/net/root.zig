//! Foundry `net` — layer L2.
//!
//! Step 1 froze the checked host limits, runtime channel description and FNET wire-v1
//! codec. The authenticated streams that carry them are `platform.Transport` (Step 2).
//! Step 3 added the `Service`: grants, sessions and peers, compatibility negotiation,
//! the allowlist, pre-authentication limits, deadlines and budgets
//! (`docs/design/networking.md`). Commands, state and activation are Step 4's.

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
