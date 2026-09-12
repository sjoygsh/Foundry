//! What `scripting.zig` is when the build has no Lua.
//!
//! Tier 2 is optional (ADR-0029): a host that never fetched the pinned Lua dependency still
//! builds, still loads every content package, and still runs. What it loses is the ability
//! to *activate* a package's script — so a package that carries one is reported once and
//! then treated as the content package it also is.
//!
//! The two files answer the same calls so `main.zig` never asks which one it got. That is
//! the same shape as the null platform and the null RHI backend: the absence is a build
//! choice with an implementation, not a branch scattered through the caller.

const std = @import("std");
const app = @import("app");
const core = @import("core");
const mod = @import("mod");
const scene = @import("scene");

const log = core.log.scoped(.sandbox);

pub const available = false;

pub const Host = struct {
    noticed: bool = false,

    pub fn note(self: *Host, entry: mod.Entry) void {
        if (entry.script == null) return;
        if (!self.noticed) {
            log.warn("'{s}' has a script; this build has no scripting runtime", .{entry.name});
            self.noticed = true;
        }
    }

    pub fn start(self: *Host, gpa: std.mem.Allocator, engine: *app.Engine, world: *scene.World) void {
        _ = .{ self, gpa, engine, world };
    }

    pub fn poll(self: *Host) void {
        _ = self;
    }

    pub fn worldReplaced(self: *Host) void {
        _ = self;
    }

    pub fn deinit(self: *Host) void {
        _ = self;
    }
};
