//! Foundry `app` — layer L4.
//!
//! Depends on every module below it; nothing depends on it except games, samples, tools,
//! and eventually `abi` (L5).
//!
//! Short by design. `app` owns the **shape of a frame** and the **order subsystems come
//! up and go down**, and almost nothing else. Both are decisions every future subsystem
//! has to fit into, which is why they live in one place rather than being rediscovered
//! per subsystem.
//!
//! Design: `docs/design/app-and-frame-loop.md`

const engine = @import("engine.zig");

pub const log_sink = @import("log_sink.zig");

pub const Engine = engine.Engine;
pub const EngineOf = engine.EngineOf;
pub const Config = engine.Config;
pub const InitError = engine.InitError;
pub const Step = engine.Step;
pub const environment = engine.environment;

/// Drop this into a game's root source file to route Foundry's logging:
///
///     pub const std_options = app.std_options;
pub const std_options = log_sink.std_options;

test {
    _ = engine;
    _ = log_sink;
}
