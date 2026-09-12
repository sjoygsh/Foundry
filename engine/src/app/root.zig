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

/// The user's own preferences, on disk, and the resolution that decides which of a
/// built-in fallback, a content default and a saved preference wins (`distribution.md`
/// §§4-6, ADR-0031). **Opt-in**: an application that keeps no preferences constructs none
/// of this, and the engine owns no `Storage`, because the engine does not own an
/// application's configuration.
/// Local evidence a session leaves behind: a bounded log, and whether the last one closed
/// cleanly. Opt-in, and not crash recovery (`distribution.md` §10).
pub const diagnostics = @import("diagnostics.zig");
pub const settings = @import("settings.zig");
pub const ui_draw = @import("ui_draw.zig");

pub const Engine = engine.Engine;
pub const EngineOf = engine.EngineOf;
pub const Config = engine.Config;
pub const ContentPackage = engine.ContentPackage;
pub const InitError = engine.InitError;
pub const Step = engine.Step;
pub const MemoryHandle = engine.MemoryHandle;
pub const MemoryReport = engine.MemoryReport;
/// The names the engine gives its own timing spans (`debug-overlay.md` §4.3).
pub const span = engine.span;
pub const environment = engine.environment;
/// Where content lives, answerable before an `Engine` exists — which is when a host that
/// discovers its packages needs it (`public-abi.md` §13).
pub const contentDirOf = engine.contentDirOf;

/// The UI walker (ADR-0024, `docs/design/ui.md` §8). `ui` describes a frame and cannot see
/// a renderer; this is the only thing that sees both, and `UiFont` is the only sanctioned
/// way to build the `ui.FontMetrics` the kernel measures with.
pub const drawUi = ui_draw.draw;
pub const UiFont = ui_draw.Font;
pub const UiDrawOptions = ui_draw.Options;

/// One line from the in-memory log ring (`debug-overlay.md` §6), and what a reader asks
/// for. The ring itself is `log_sink`, which is ambient because `std.log` reaches it from
/// code that has no engine pointer to ask.
pub const LogRecord = log_sink.Record;
pub const LogFilter = log_sink.Filter;
pub const LogView = log_sink.View;

/// Drop this into a game's root source file to route Foundry's logging:
///
///     pub const std_options = app.std_options;
pub const std_options = log_sink.std_options;

test {
    _ = engine;
    _ = log_sink;
    _ = diagnostics;
    _ = settings;
    _ = ui_draw;
}
