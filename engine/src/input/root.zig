//! Foundry `input` — layer L2. Depends on `core`, `data` and `platform`.
//!
//! **Actions, not keys** (ADR-0087, `docs/design/input.md` §6). A game declares what a player
//! can do as content, `foundry:input_action` and `foundry:input_context` records, and this module
//! owns their meaning, as `mod` owns `foundry:mod`. It holds no device and no thread, so every
//! rule here is unit-tested with no window.
//!
//! - `platform` for the snapshot actions are read from and the names a binding spells;
//! - `data` for the records.
//!
//! It is not `platform`, which has no `data` and stays the thin OS layer; not `app`, because
//! `author` must register these records and cannot see `app`; and not `asset`, because nothing
//! here is loaded.
//!
//! - `Map` (Step 4): the records, validated, in content-ID order;
//! - `Actions` (Step 5): what each action reads from a frame's snapshot, through the enabled
//!   contexts, and `TickView`, what a fixed step reads, so an edge reaches exactly one step;
//! - `Overrides`, `Map.apply`, `Capture` and `Map.conflicts` (Step 5): rebinding as values. The
//!   bindings file that keeps a player's overrides is `app`'s (Step 6).

pub const actions = @import("actions.zig");
pub const map = @import("map.zig");
pub const rebind = @import("rebind.zig");
pub const schemas = @import("schemas.zig");
pub const source = @import("source.zig");
pub const tick = @import("tick.zig");

pub const Action = map.Action;
pub const Actions = actions.Actions;
pub const ActionState = actions.ActionState;
pub const Blocked = actions.Blocked;
pub const Capture = rebind.Capture;
pub const CaptureOptions = rebind.CaptureOptions;
pub const Captured = rebind.Captured;
pub const Devices = actions.Devices;
pub const Frame = actions.Frame;
pub const Options = actions.Options;
pub const Override = rebind.Override;
pub const Overrides = rebind.Overrides;
pub const Tick = tick.Tick;
pub const TickView = tick.TickView;
pub const Binding = schemas.Binding;
pub const Component = schemas.Component;
pub const Context = map.Context;
pub const Kind = schemas.Kind;
pub const Map = map.Map;
pub const Problem = map.Problem;
pub const Source = source.Source;
pub const SourceClass = source.Class;
pub const Warning = map.Warning;

test {
    _ = actions;
    _ = map;
    _ = rebind;
    _ = tick;
    _ = @import("tests.zig");
    _ = schemas;
    _ = source;
}
