//! Foundry `core` — layer L0.
//!
//! Imports `std` and nothing else. Provides mechanism, never policy: no content
//! knowledge, no I/O, no graphics types. This is also where `std` churn is absorbed —
//! every other module imports `core`, not `std`, for anything `core` covers (ADR-0001).
//!
//! Design: `docs/design/core-memory-and-handles.md`

pub const assert = @import("assert.zig");
pub const handle = @import("handle.zig");
pub const id = @import("id.zig");
pub const log = @import("log.zig");
pub const math = @import("math.zig");
pub const mem = @import("mem.zig");
pub const rng = @import("rng.zig");
pub const time = @import("time.zig");

// The names reached for most often, re-exported so callers write `core.Handle(T)`
// rather than `core.handle.Handle(T)`.
pub const Handle = handle.Handle;
pub const HandlePool = handle.HandlePool;
pub const ContentId = id.ContentId;
pub const Arena = mem.Arena;
pub const Pcg32 = rng.Pcg32;

test {
    _ = assert;
    _ = handle;
    _ = id;
    _ = log;
    _ = math;
    _ = mem;
    _ = rng;
    _ = time;
}
