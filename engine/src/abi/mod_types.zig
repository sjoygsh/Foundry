//! Plain values published by the v3 mod-management calls.
//!
//! Paths and native-code consent are deliberately absent. The former are host authority and
//! the latter is a player decision which code running under that consent may never grant.
//!
//! Design: `docs/design/mod-management.md` §9.

const std = @import("std");
const types = @import("types.zig");

pub const Origin = enum(i32) {
    installed = 0,
    user = 1,
};

pub const SkipReason = enum(i32) {
    none = 0,
    not_installed = 1,
    missing_dependency = 2,
    dependency_version = 3,
    dependency_skipped = 4,
    cycle = 5,
    duplicate = 6,
    shadows_installed = 7,
};

pub const ProfileProblem = enum(i32) {
    none = 0,
    damaged = 1,
    other_build = 2,
    refused = 3,
    unavailable = 4,
};

pub const flag_required: u32 = 1 << 0;
pub const flag_native: u32 = 1 << 1;
pub const flag_script: u32 = 1 << 2;
pub const flag_duplicate: u32 = 1 << 3;
pub const flag_environment: u32 = 1 << 4;
pub const flag_unreadable: u32 = 1 << 5;

/// Where a package sits in a list it is not in.
pub const no_position = std.math.maxInt(u32);

/// One discovered copy of a package, and what the pending selection makes of it.
pub const Info = extern struct {
    id: types.ContentId = .none,
    id_name: types.Str = .empty,
    name: types.Str = .empty,
    license: types.Str = .empty,
    version: u32 = 0,
    origin: Origin = .installed,
    flags: u32 = 0,
    /// Its place in the player's list, which is what `mods_move` takes.
    pending_index: u32 = no_position,
    /// Its place in the order the next start would load.
    pending_position: u32 = no_position,
    skip_reason: SkipReason = .none,
    /// The dependency a skip is about, for the three reasons that have one.
    skip_other: types.ContentId = .none,
    skip_other_name: types.Str = .empty,
    provides: u32 = 0,
    wins: u32 = 0,
    loses: u32 = 0,
    loaded: types.Bool = 0,
    pending_enabled: types.Bool = 0,
    _padding: [2]u8 = .{ 0, 0 },
};

/// One entry of the player's list, installed or not.
pub const Pending = extern struct {
    id: types.ContentId = .none,
    name: types.Str = .empty,
    installed: types.Bool = 0,
    _padding: [7]u8 = @splat(0),
};

/// One package another one requires, and whether the pending order satisfies it.
pub const Requirement = extern struct {
    id: types.ContentId = .none,
    name: types.Str = .empty,
    min_version: u32 = 0,
    /// `no_position`'s value, UINT32_MAX, when the range has no upper bound.
    max_version: u32 = no_position,
    satisfied: types.Bool = 0,
    _padding: [7]u8 = @splat(0),
};

pub const Conflict = extern struct {
    record: types.ContentId = .none,
    name: types.Str = .empty,
    winner: types.ContentId = .none,
    provider_count: u32 = 0,
    _padding: u32 = 0,
};

pub const Provider = extern struct {
    package: types.ContentId = .none,
    position: u32 = 0,
    winner: types.Bool = 0,
    _padding: [3]u8 = .{ 0, 0, 0 },
};

pub const Profile = extern struct {
    key: u32 = 0,
    problem: ProfileProblem = .none,
    name: types.Str = .empty,
    saved: types.Bool = 0,
    pending: types.Bool = 0,
    _padding: [6]u8 = @splat(0),
};

pub const ProfileState = extern struct {
    saved: u32 = 0,
    pending: u32 = 0,
    has_saved: types.Bool = 0,
    has_pending: types.Bool = 0,
    changed: types.Bool = 0,
    _padding: u8 = 0,
};

comptime {
    if (@sizeOf(Info) != 120 or @offsetOf(Info, "id_name") != 8 or @offsetOf(Info, "version") != 56 or
        @offsetOf(Info, "skip_other") != 80 or @offsetOf(Info, "provides") != 104 or
        @offsetOf(Info, "loaded") != 116)
        @compileError("FoundryModInfo layout changed");
    if (@sizeOf(Pending) != 32 or @offsetOf(Pending, "installed") != 24)
        @compileError("FoundryModPending layout changed");
    if (@sizeOf(Requirement) != 40 or @offsetOf(Requirement, "min_version") != 24 or
        @offsetOf(Requirement, "satisfied") != 32)
        @compileError("FoundryModRequirement layout changed");
    if (@sizeOf(Conflict) != 40 or @offsetOf(Conflict, "winner") != 24)
        @compileError("FoundryModConflict layout changed");
    if (@sizeOf(Provider) != 16 or @offsetOf(Provider, "winner") != 12)
        @compileError("FoundryModProvider layout changed");
    if (@sizeOf(Profile) != 32 or @offsetOf(Profile, "name") != 8)
        @compileError("FoundryModProfile layout changed");
    if (@sizeOf(ProfileState) != 12 or @offsetOf(ProfileState, "changed") != 10)
        @compileError("FoundryModProfileState layout changed");
}
