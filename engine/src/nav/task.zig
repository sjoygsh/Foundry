//! A build on the background pool (`navigation.md` §7, ADR-0061).
//!
//! **The sources are copied at `start`,** on the calling thread, into one buffer the task owns,
//! so the caller may free or change its own geometry the moment `start` returns. The build runs
//! on whatever thread the executor chooses; `take` on the caller's thread answers the mesh, the
//! build's error, or nothing yet, and never blocks.
//!
//! **Arrival is presentation** (ADR-0061): when a mesh arrives may decide what is drawn and which
//! mesh a game uses from then on, never what a tick computed before it.

const std = @import("std");
const core = @import("core");

const config_mod = @import("config.zig");
const input = @import("input.zig");
const poly = @import("poly.zig");

const Allocator = std.mem.Allocator;
const Vec3 = core.math.Vec3;

pub const StartError = Allocator.Error || core.tasks.StartError;

pub const Build = struct {
    state: *State,

    const State = struct {
        gpa: Allocator,
        config: config_mod.Config,
        positions: []Vec3,
        indices: []u32,
        sources: []input.Source,
        result: poly.BuildError!poly.Mesh = error.OutOfMemory,
        done: core.tasks.Done = .{},
        taken: bool = false,

        fn run(context: *anyopaque) void {
            const self: *State = @ptrCast(@alignCast(context));
            self.result = poly.build(self.gpa, self.config, self.sources);
        }

        fn destroy(self: *State) void {
            const gpa = self.gpa;
            gpa.free(self.positions);
            gpa.free(self.indices);
            gpa.free(self.sources);
            gpa.destroy(self);
        }
    };

    /// Copies `sources` and starts their build on `tasks`. `gpa` must be safe to use from the
    /// executor's threads.
    pub fn start(tasks: core.Tasks, gpa: Allocator, config: config_mod.Config, sources: []const input.Source) StartError!Build {
        var positions: usize = 0;
        var indices: usize = 0;
        for (sources) |s| {
            positions += s.positions.len;
            indices += s.indices.len;
        }
        const state = try gpa.create(State);
        errdefer gpa.destroy(state);
        const p = try gpa.alloc(Vec3, positions);
        errdefer gpa.free(p);
        const ix = try gpa.alloc(u32, indices);
        errdefer gpa.free(ix);
        const copied = try gpa.alloc(input.Source, sources.len);
        errdefer gpa.free(copied);
        var pn: usize = 0;
        var in: usize = 0;
        for (sources, copied) |s, *c| {
            @memcpy(p[pn..][0..s.positions.len], s.positions);
            @memcpy(ix[in..][0..s.indices.len], s.indices);
            c.* = .{ .positions = p[pn..][0..s.positions.len], .indices = ix[in..][0..s.indices.len], .pose = s.pose };
            pn += s.positions.len;
            in += s.indices.len;
        }
        state.* = .{ .gpa = gpa, .config = config, .positions = p, .indices = ix, .sources = copied };
        try tasks.start(.{ .context = state, .call = State.run }, &state.done);
        return .{ .state = state };
    }

    /// Whether the build has finished, so `take` will answer.
    pub fn ready(self: *const Build) bool {
        return self.state.done.isSet();
    }

    /// The mesh or the build's error once it has finished, and null before. Answers once: the
    /// mesh is the caller's from then on.
    pub fn take(self: *Build) ?(poly.BuildError!poly.Mesh) {
        if (!self.state.done.isSet() or self.state.taken) return null;
        self.state.taken = true;
        return self.state.result;
    }

    /// Frees the build. It must have finished; a mesh never taken is freed with it, which is how
    /// a stale build's result is discarded.
    pub fn deinit(self: *Build) void {
        std.debug.assert(self.state.done.isSet());
        if (!self.state.taken) {
            if (self.state.result) |*mesh| mesh.deinit(self.state.gpa) else |_| {}
        }
        self.state.destroy();
        self.* = undefined;
    }
};
