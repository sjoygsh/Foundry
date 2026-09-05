//! Foundry `scene` — layer L3. Entities, components, systems and world state.
//!
//! ADR-0007 grants this module `core`, `data` and `asset`. It takes **`core` and `data`**,
//! and will take `asset` when something here needs to acquire one — which is not yet, and
//! may never be: a `sprite` component holds a texture's content ID and stays a content ID,
//! and turning that into a handle belongs to the rendering system above (`entity-storage.md`
//! §8). A dependency a module does not use is a claim about the architecture the build
//! cannot check.
//!
//! Two consequences of the layering shape the interfaces here rather than merely
//! constraining them:
//!
//! * **`scene` cannot read input and cannot read a clock.** `platform` is not below it. A
//!   system is *given* the tick it runs at, and anything from a device reaches it as
//!   ordinary data the game wrote down — which is also what makes replay possible later.
//! * **`scene` cannot open a file**, the same rule `data` lives under. A world is saved
//!   into a byte slice and loaded from one; whoever has a filesystem does the writing.
//!   Every test here is hermetic as a result.
//!
//! Component data, entity templates and save files all come from outside the engine, so
//! all three are **untrusted input**: validated and refused, never asserted.
//!
//! Design: `docs/design/entity-storage.md`

pub const component = @import("component.zig");
pub const derive = @import("derive.zig");
pub const entity = @import("entity.zig");
pub const limits = @import("limits.zig");
pub const query = @import("query.zig");
pub const schemas = @import("schemas.zig");
pub const store = @import("store.zig");
pub const system = @import("system.zig");
pub const world = @import("world.zig");

// The names reached for most often. These are seen by people we do not control — a game
// today, compiled mods from M7 — and component type names reach save files, so renaming
// one is a compatibility decision rather than a tidy-up (ADR-0010, CLAUDE.md §7).
pub const ComponentStore = store.ComponentStore;
pub const ComponentType = component.ComponentType;
pub const ComponentTypeInfo = component.ComponentTypeInfo;
pub const DeserializeError = component.DeserializeError;
pub const Entity = entity.Entity;
pub const Limits = limits.Limits;
pub const Query = query.Query;
pub const Registration = component.Registration;
pub const System = system.System;
pub const SystemHandle = system.SystemHandle;
pub const Tick = system.Tick;
pub const World = world.World;

pub const ComponentError = world.ComponentError;

/// Produces registration data for a component type from a Zig struct (ADR-0010).
pub const componentType = derive.componentType;
pub const CreateError = world.CreateError;
pub const SpawnError = world.SpawnError;
pub const SystemError = world.SystemError;
pub const RegisterError = world.RegisterError;

test {
    _ = component;
    _ = derive;
    _ = entity;
    _ = limits;
    _ = query;
    _ = schemas;
    _ = store;
    _ = system;
    _ = world;
}
