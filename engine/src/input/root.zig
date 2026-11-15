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
//! Step 4 is the records, their validation and the map. Evaluation, the tick view and rebinding
//! are §7 and §8's, Step 5.

pub const map = @import("map.zig");
pub const schemas = @import("schemas.zig");
pub const source = @import("source.zig");

pub const Action = map.Action;
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
    _ = map;
    _ = schemas;
    _ = source;
}
