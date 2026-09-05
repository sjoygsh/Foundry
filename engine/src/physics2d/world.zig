//! The collision world: bodies, grids, and what may be asked of them.
//!
//! **The world holds no time and no velocity, and integrates nothing.** There is no `dt` in
//! any signature here, no stored velocity, and no step. A caller says *move this body by this
//! vector* and is told where it ended up and what it touched. Three things follow, all of them
//! wanted (`tilemaps-and-collision.md` §2):
//!
//! * Movement feel stays in the game, which is where acceleration curves and speed caps belong.
//! * I9 gets simpler: a module with no clock cannot read one, and a module that integrates
//!   nothing has no accumulated float state to diverge.
//! * Every test is "put these shapes here, move this one, assert where it stopped" — no
//!   stepping, no settling, no tolerance for a solver converging.
//!
//! **A body is read through a const pointer and changed through named calls.** Handing out a
//! `*Body` would let a caller move one by assignment, leaving the broadphase describing where
//! it used to be — and the symptom of that is "things sometimes do not collide", which is the
//! worst class of bug this module could ship. The setters exist so that every change which
//! affects the acceleration structure passes through something that can update it.

const std = @import("std");
const core = @import("core");

const body_mod = @import("body.zig");
const broadphase_mod = @import("broadphase.zig");
const grid_mod = @import("grid.zig");
const shape_mod = @import("shape.zig");

const Allocator = std.mem.Allocator;
const Bodies = body_mod.Bodies;
const Body = body_mod.Body;
const BodyHandle = body_mod.BodyHandle;
const BodyKind = body_mod.BodyKind;
const Bounds = shape_mod.Bounds;
const Broadphase = broadphase_mod.Broadphase;
const Candidates = broadphase_mod.Candidates;
const Grid = grid_mod.Grid;
const GridHandle = grid_mod.GridHandle;
const Grids = grid_mod.Grids;
const Rounded = shape_mod.Rounded;
const Shape = shape_mod.Shape;
const Vec2 = core.math.Vec2;

pub const AddBodyError = error{
    OutOfMemory,
    /// A degenerate shape: a zero or negative extent, or one that is not finite. Reported
    /// rather than asserted, because a shape reaches here from a game and from M7 from a mod.
    InvalidShape,
};

pub const AddGridError = error{ OutOfMemory, InvalidGrid };

pub const Options = struct {
    /// Broadphase cell size, or null to take it from the first body inserted.
    ///
    /// The default heuristic is right when bodies are of similar size, which is what a tile
    /// game has. This exists for when the first body is not representative — a world whose
    /// first insert is the one enormous boss — because a uniform hash degrades when sizes vary
    /// by orders of magnitude (ADR-0022).
    cell_size: ?f32 = null,
};

pub const World = struct {
    bodies: core.HandlePool(Bodies, Body) = .empty,
    grids: core.HandlePool(Grids, Grid) = .empty,
    broadphase: Broadphase = .empty,

    /// Scratch the walks reuse. Held by the world rather than allocated per call, so a game
    /// moving a hundred bodies a tick allocates once and then never again.
    candidates: Candidates = .empty,
    casts: std.ArrayList(Cast) = .empty,

    pub const empty: World = .{};

    pub fn init(options: Options) World {
        var world: World = .empty;
        if (options.cell_size) |size| {
            if (size > 0 and std.math.isFinite(size)) world.broadphase.setCellSize(size);
        }
        return world;
    }

    pub fn deinit(self: *World, gpa: Allocator) void {
        self.bodies.deinit(gpa);
        self.grids.deinit(gpa);
        self.broadphase.deinit(gpa);
        self.candidates.deinit(gpa);
        self.casts.deinit(gpa);
        self.* = .empty;
    }

    pub fn addBody(self: *World, gpa: Allocator, new: Body) AddBodyError!BodyHandle {
        if (!new.shape.isValid()) return error.InvalidShape;
        if (!std.math.isFinite(new.position.x) or !std.math.isFinite(new.position.y)) {
            return error.InvalidShape;
        }
        const handle = try self.bodies.add(gpa, new);
        errdefer _ = self.bodies.remove(handle);
        try self.broadphase.insert(gpa, handle, new.kind, new.bounds());
        return handle;
    }

    pub fn removeBody(self: *World, gpa: Allocator, handle: BodyHandle) bool {
        const existing = self.bodies.get(handle) orelse return false;
        self.broadphase.remove(gpa, handle, existing.kind);
        return self.bodies.remove(handle);
    }

    /// A body, for reading. See the note at the top of this file about why it is const.
    pub fn body(self: *World, handle: BodyHandle) ?*const Body {
        return self.bodies.get(handle);
    }

    /// Moves a body without testing anything — a teleport.
    ///
    /// Named for what it is. It is how a spawn, a warp or a cutscene places something, and it
    /// can leave a body overlapping geometry, which is exactly the state `resolveOverlaps`
    /// exists to detect rather than to hide.
    pub fn setPosition(self: *World, gpa: Allocator, handle: BodyHandle, position: Vec2) Allocator.Error!bool {
        const existing = self.bodies.get(handle) orelse return false;
        if (!std.math.isFinite(position.x) or !std.math.isFinite(position.y)) return false;
        existing.position = position;
        try self.broadphase.update(gpa, handle, existing.kind, existing.bounds());
        return true;
    }

    /// Replaces a body's shape. Refused if the new shape is degenerate.
    pub fn setShape(self: *World, gpa: Allocator, handle: BodyHandle, shape: Shape) Allocator.Error!bool {
        if (!shape.isValid()) return false;
        const existing = self.bodies.get(handle) orelse return false;
        existing.shape = shape;
        try self.broadphase.update(gpa, handle, existing.kind, existing.bounds());
        return true;
    }

    /// Moves a body between broadphase tiers.
    ///
    /// Its own call rather than a field write, because the tiers are the one piece of state
    /// that a plain assignment would silently desynchronise.
    pub fn setKind(self: *World, gpa: Allocator, handle: BodyHandle, kind: BodyKind) Allocator.Error!bool {
        const existing = self.bodies.get(handle) orelse return false;
        if (existing.kind == kind) return true;
        self.broadphase.remove(gpa, handle, existing.kind);
        existing.kind = kind;
        try self.broadphase.insert(gpa, handle, kind, existing.bounds());
        return true;
    }

    /// Neither of these reaches the broadphase, so they need no allocator and cannot fail.
    pub fn setFilter(self: *World, handle: BodyHandle, layer: u32, mask: u32) bool {
        const existing = self.bodies.get(handle) orelse return false;
        existing.layer = layer;
        existing.mask = mask;
        return true;
    }

    pub fn setUser(self: *World, handle: BodyHandle, user: u64) bool {
        const existing = self.bodies.get(handle) orelse return false;
        existing.user = user;
        return true;
    }

    /// Adds a tile grid.
    ///
    /// **`grid.tiles` and `grid.solid` are borrowed and must outlive the grid's presence in
    /// the world.** The world copies the descriptor and not the arrays; their lifetime and
    /// their reloading belong to whoever loaded them. This is what keeps `physics2d` at L1 —
    /// it never learns what an asset is.
    ///
    /// A grid does **not** enter the broadphase. It is a shape source and is walked directly,
    /// which is why it costs the same for a 2000x2000 map as for a 20x20 one (§4).
    pub fn addGrid(self: *World, gpa: Allocator, new: Grid) AddGridError!GridHandle {
        try new.validate();
        return self.grids.add(gpa, new);
    }

    pub fn removeGrid(self: *World, handle: GridHandle) bool {
        return self.grids.remove(handle);
    }

    pub fn grid(self: *World, handle: GridHandle) ?*const Grid {
        return self.grids.get(handle);
    }

    pub fn bodyCount(self: *const World) u32 {
        return self.bodies.count();
    }

    pub fn gridCount(self: *const World) u32 {
        return self.grids.count();
    }

    /// Live bodies in **ascending handle-index order** (I9; §8 rule 1).
    pub fn bodyIterator(self: *World) core.HandlePool(Bodies, Body).Iterator {
        return self.bodies.iterator();
    }

    /// Live grids in ascending handle-index order. **Grids are considered before bodies** in
    /// any operation that looks at both (§8 rule 3).
    pub fn gridIterator(self: *World) core.HandlePool(Grids, Grid).Iterator {
        return self.grids.iterator();
    }

    /// The bounds of a body, or null if the handle is stale.
    pub fn boundsOf(self: *World, handle: BodyHandle) ?Bounds {
        const existing = self.bodies.get(handle) orelse return null;
        return existing.bounds();
    }

    /// Bodies whose bounds actually meet `area` and whose layer the mask admits, in ascending
    /// handle-index order.
    ///
    /// The broadphase's answer narrowed twice: to bodies the mask wants, and to bodies the
    /// rectangle really touches rather than merely shares a cell with. `out` is cleared first
    /// and is the caller's to reuse, so a per-frame query loop allocates once.
    pub fn queryBounds(
        self: *World,
        gpa: Allocator,
        area: Bounds,
        mask: u32,
        out: *Candidates,
    ) Allocator.Error!void {
        try self.broadphase.query(gpa, area, out);

        var write: usize = 0;
        for (out.items.items) |handle| {
            const existing = self.bodies.get(handle) orelse continue;
            if (!body_mod.maskAdmits(mask, existing.*)) continue;
            if (!existing.bounds().overlaps(area)) continue;
            out.items.items[write] = handle;
            write += 1;
        }
        out.items.shrinkRetainingCapacity(write);
    }

    // -- movement --------------------------------------------------------------------

    /// Moves a body along `motion`, stopping at what it hits and sliding along it.
    ///
    /// Returns null if the handle is stale. Otherwise the body **is moved** — its position is
    /// committed and the broadphase updated — and the result says where it ended up, what it
    /// touched, and whether it started the move already overlapping something.
    ///
    /// `hits` is the caller's buffer and is filled in contact order. `MoveResult.total_hits`
    /// is how many contacts there were, so a caller whose buffer was too small learns that it
    /// truncated rather than believing it saw everything. That pattern repeats for every query
    /// in this module; it is the shape the C ABI needs at M7 (ADR-0004), and adopting it now
    /// costs nothing.
    ///
    /// **Triggers do not block and are not reported here.** A trigger is not something you
    /// stop against, and reporting a swept touch would be a second, weaker answer to a
    /// question `overlapShape` already answers exactly.
    ///
    /// The iteration budget is `max_slide_iterations`, and it is part of the interface because
    /// a caller can observe it: a body in a sufficiently awkward corner stops slightly short
    /// rather than looping.
    pub fn moveAndSlide(
        self: *World,
        gpa: Allocator,
        handle: BodyHandle,
        motion: Vec2,
        hits: []Hit,
    ) Allocator.Error!?MoveResult {
        const start = self.bodies.get(handle) orelse return null;
        const mover: Rounded = .of(start.shape);
        const filter: Filter = .{
            .ignore = handle,
            .mask = start.mask,
            .layer = start.layer,
            .include_triggers = false,
        };

        var position = start.position;
        var written: u32 = 0;
        var total: u32 = 0;
        var started_inside = false;

        if (!std.math.isFinite(motion.x) or !std.math.isFinite(motion.y)) {
            return MoveResult{
                .position = position,
                .hit_count = 0,
                .total_hits = 0,
                .started_inside = false,
            };
        }

        // `fraction` is reported against the requested motion, as a share of its length rather
        // than of any one iteration's leftover — the only reading that stays meaningful once
        // sliding has turned the direction. Projection never lengthens what is left, so the
        // path can never exceed the requested length and the value stays in 0..1 and rises.
        const requested = motion.length();
        var travelled: f32 = 0;

        var remaining = motion;
        var iteration: u32 = 0;
        while (iteration < max_slide_iterations) : (iteration += 1) {
            // The first pass runs even for zero motion, because `started_inside` is an answer
            // a caller wants whether or not it asked to move.
            if (iteration > 0 and remaining.x == 0 and remaining.y == 0) break;

            const found = try self.earliestHit(gpa, mover, position, remaining, filter);
            if (iteration == 0) started_inside = found.started_inside;

            const hit = found.hit orelse {
                position = position.add(remaining);
                break;
            };

            const travel = remaining.scale(hit.fraction);
            travelled += travel.length();
            // Held off the surface by a hair, so the next iteration does not begin already
            // touching what it just stopped against.
            position = position.add(travel).add(hit.normal.scale(contact_skin));

            total += 1;
            if (written < hits.len) {
                hits[written] = hit;
                hits[written].fraction = if (requested > 0) @min(travelled / requested, 1) else 0;
                written += 1;
            }

            // The projection that makes a stop into a slide: what is left keeps only the part
            // that runs along the surface.
            const left = remaining.sub(travel);
            remaining = left.sub(hit.normal.scale(left.dot(hit.normal)));
        }

        const moved = self.bodies.get(handle).?;
        moved.position = position;
        try self.broadphase.update(gpa, handle, moved.kind, moved.bounds());

        return MoveResult{
            .position = position,
            .hit_count = written,
            .total_hits = total,
            .started_inside = started_inside,
        };
    }

    /// Pushes a body out of anything it is already inside, along the shortest way out.
    ///
    /// **Deliberately not part of `moveAndSlide`.** A body that starts a move overlapping —
    /// teleported there, resized by a mod, or standing where a tile just turned solid — is
    /// not something a sweep can fix, because the time of impact is behind it. Keeping this
    /// separate means "I am stuck in a wall" is a state a game can detect and decide about,
    /// rather than a silent teleport it never sees.
    ///
    /// Up to `max_slide_iterations` pushes, because escaping one wall can press a body into
    /// another. A body still overlapping after that is reported by `started_inside` and left
    /// where it is.
    pub fn resolveOverlaps(
        self: *World,
        gpa: Allocator,
        handle: BodyHandle,
        hits: []Hit,
    ) Allocator.Error!?MoveResult {
        const start = self.bodies.get(handle) orelse return null;
        const mover: Rounded = .of(start.shape);
        const filter: Filter = .{
            .ignore = handle,
            .mask = start.mask,
            .layer = start.layer,
            .include_triggers = false,
        };

        var position = start.position;
        var written: u32 = 0;
        var total: u32 = 0;
        var started_inside = false;

        var iteration: u32 = 0;
        while (iteration < max_slide_iterations) : (iteration += 1) {
            const found = try self.deepestContact(gpa, mover, position, filter) orelse break;
            if (iteration == 0) started_inside = true;

            position = position.add(found.hit.normal.scale(found.depth + contact_skin));

            total += 1;
            if (written < hits.len) {
                hits[written] = found.hit;
                written += 1;
            }
        }

        const moved = self.bodies.get(handle).?;
        moved.position = position;
        try self.broadphase.update(gpa, handle, moved.kind, moved.bounds());

        return MoveResult{
            .position = position,
            .hit_count = written,
            .total_hits = total,
            .started_inside = started_inside,
        };
    }

    // -- queries ---------------------------------------------------------------------

    /// Everything containing `p`. Grid cells first, then bodies in handle order.
    pub fn overlapPoint(
        self: *World,
        gpa: Allocator,
        p: Vec2,
        mask: u32,
        out: []QueryHit,
    ) Allocator.Error!QueryResult {
        return self.collectOverlaps(gpa, .point, p, mask, out);
    }

    /// Everything `shape` standing at `at` overlaps. Grid cells first, then bodies in handle
    /// order. Triggers are included: a query asks where things are, it does not collide.
    pub fn overlapShape(
        self: *World,
        gpa: Allocator,
        shape: Shape,
        at: Vec2,
        mask: u32,
        out: []QueryHit,
    ) Allocator.Error!QueryResult {
        return self.collectOverlaps(gpa, .of(shape), at, mask, out);
    }

    /// Everything the segment `from`..`to` passes through, by increasing `fraction`.
    pub fn raycast(
        self: *World,
        gpa: Allocator,
        from: Vec2,
        to: Vec2,
        mask: u32,
        out: []Hit,
    ) Allocator.Error!QueryResult {
        return self.castAll(gpa, .point, from, to, mask, out);
    }

    /// Everything `shape` passes through on its way from `from` to `to`, by increasing
    /// `fraction`. Anything it started inside contributes nothing, for the reason
    /// `Grid.sweepShape` gives.
    pub fn shapeCast(
        self: *World,
        gpa: Allocator,
        shape: Shape,
        from: Vec2,
        to: Vec2,
        mask: u32,
        out: []Hit,
    ) Allocator.Error!QueryResult {
        return self.castAll(gpa, .of(shape), from, to, mask, out);
    }

    // -- the shared walks --------------------------------------------------------------

    /// The earliest contact along `motion`, and whether the shape began inside anything.
    ///
    /// **Grids before bodies**, and a later candidate replaces the incumbent only on a
    /// strictly smaller fraction, so a tie between a grid cell and a body resolves to the cell
    /// and a tie between two bodies to the lower handle index (§8 rules 1 and 3).
    fn earliestHit(
        self: *World,
        gpa: Allocator,
        mover: Rounded,
        from: Vec2,
        motion: Vec2,
        filter: Filter,
    ) Allocator.Error!Found {
        var found: Found = .{};

        var grids = self.grids.iterator();
        while (grids.next()) |entry| {
            const sweep = entry.value.sweepShape(mover, from, motion);
            if (sweep.started_inside) found.started_inside = true;
            const hit = sweep.hit orelse continue;
            if (found.hit == null or hit.fraction < found.hit.?.fraction) {
                found.hit = .{
                    .grid = entry.id,
                    .cell = hit.cell,
                    .normal = hit.normal,
                    .fraction = hit.fraction,
                };
            }
        }

        const area = Bounds.fromCenter(from, mover.halfExtents()).sweptBy(motion);
        try self.broadphase.query(gpa, area, &self.candidates);
        for (self.candidates.handles()) |candidate| {
            const other = self.bodies.get(candidate) orelse continue;
            if (!filter.admits(candidate, other.*)) continue;
            const sweep = shape_mod.sweepRounded(
                mover.sum(.of(other.shape)),
                from,
                motion,
                other.position,
                .all,
            ) orelse continue;
            if (sweep.startedInside()) {
                found.started_inside = true;
                continue;
            }
            if (found.hit == null or sweep.fraction < found.hit.?.fraction) {
                found.hit = .{
                    .body = candidate,
                    .normal = sweep.normal,
                    .fraction = sweep.fraction,
                    .user = other.user,
                };
            }
        }

        return found;
    }

    /// The deepest penetration at `at`, which is the one to escape first.
    fn deepestContact(
        self: *World,
        gpa: Allocator,
        mover: Rounded,
        at: Vec2,
        filter: Filter,
    ) Allocator.Error!?Penetration {
        var best: ?Penetration = null;

        var grids = self.grids.iterator();
        while (grids.next()) |entry| {
            const contact = entry.value.deepestOverlap(mover, at) orelse continue;
            if (best == null or contact.depth > best.?.depth) {
                best = .{
                    .hit = .{
                        .grid = entry.id,
                        .cell = contact.cell,
                        .normal = contact.normal,
                        .fraction = 0,
                    },
                    .depth = contact.depth,
                };
            }
        }

        const area = Bounds.fromCenter(at, mover.halfExtents());
        try self.broadphase.query(gpa, area, &self.candidates);
        for (self.candidates.handles()) |candidate| {
            const other = self.bodies.get(candidate) orelse continue;
            if (!filter.admits(candidate, other.*)) continue;
            const contact = shape_mod.overlapRounded(
                mover.sum(.of(other.shape)),
                at,
                other.position,
                .all,
            ) orelse continue;
            if (best == null or contact.depth > best.?.depth) {
                best = .{
                    .hit = .{
                        .body = candidate,
                        .normal = contact.normal,
                        .fraction = 0,
                        .user = other.user,
                    },
                    .depth = contact.depth,
                };
            }
        }

        return best;
    }

    fn collectOverlaps(
        self: *World,
        gpa: Allocator,
        mover: Rounded,
        at: Vec2,
        mask: u32,
        out: []QueryHit,
    ) Allocator.Error!QueryResult {
        var written: u32 = 0;
        var total: u32 = 0;

        var grids = self.grids.iterator();
        while (grids.next()) |entry| {
            const tiles = entry.value;
            const range = tiles.cellRange(Bounds.fromCenter(at, mover.halfExtents()));
            if (range.is_empty) continue;
            const obstacle = mover.sum(tiles.cellShape());
            var y = range.min_y;
            while (y <= range.max_y) : (y += 1) {
                var x = range.min_x;
                while (x <= range.max_x) : (x += 1) {
                    if (!tiles.isSolidAt(x, y)) continue;
                    if (shape_mod.overlapRounded(obstacle, at, tiles.cellCenter(x, y), .all) == null) {
                        continue;
                    }
                    total += 1;
                    if (written < out.len) {
                        out[written] = .{ .grid = entry.id, .cell = .{ x, y } };
                        written += 1;
                    }
                }
            }
        }

        const area = Bounds.fromCenter(at, mover.halfExtents());
        try self.broadphase.query(gpa, area, &self.candidates);
        for (self.candidates.handles()) |candidate| {
            const other = self.bodies.get(candidate) orelse continue;
            if (!body_mod.maskAdmits(mask, other.*)) continue;
            if (shape_mod.overlapRounded(mover.sum(.of(other.shape)), at, other.position, .all) == null) {
                continue;
            }
            total += 1;
            if (written < out.len) {
                out[written] = .{ .body = candidate, .user = other.user };
                written += 1;
            }
        }

        return .{ .count = written, .total = total };
    }

    /// Every contact along a cast, sorted by fraction.
    ///
    /// A cast reports *all* of its hits rather than the first, so this collects and sorts
    /// rather than keeping a running minimum. Ties are broken by the order the contacts were
    /// found in — grid cells row-major, then bodies by handle — which makes the comparison
    /// total and so makes an unstable sort deterministic anyway (§8).
    ///
    /// The cell walk is written out here rather than borrowed from `Grid.sweepShape`, because
    /// that answers for the earliest cell and this wants all of them. The internal-edge fix is
    /// not duplicated with it: `facesAt` is still the only place that knows what an interior
    /// face is.
    fn castAll(
        self: *World,
        gpa: Allocator,
        mover: Rounded,
        from: Vec2,
        to: Vec2,
        mask: u32,
        out: []Hit,
    ) Allocator.Error!QueryResult {
        self.casts.clearRetainingCapacity();
        const motion = to.sub(from);

        var grids = self.grids.iterator();
        while (grids.next()) |entry| {
            const tiles = entry.value;
            const swept = Bounds.fromCenter(from, mover.halfExtents()).sweptBy(motion);
            const range = tiles.cellRange(swept);
            if (range.is_empty) continue;
            const obstacle = mover.sum(tiles.cellShape());
            var y = range.min_y;
            while (y <= range.max_y) : (y += 1) {
                var x = range.min_x;
                while (x <= range.max_x) : (x += 1) {
                    if (!tiles.isSolidAt(x, y)) continue;
                    const sweep = shape_mod.sweepRounded(
                        obstacle,
                        from,
                        motion,
                        tiles.cellCenter(x, y),
                        tiles.facesAt(x, y),
                    ) orelse continue;
                    if (sweep.startedInside()) continue;
                    try self.casts.append(gpa, .{
                        .hit = .{
                            .grid = entry.id,
                            .cell = .{ x, y },
                            .normal = sweep.normal,
                            .fraction = sweep.fraction,
                        },
                        .order = @intCast(self.casts.items.len),
                    });
                }
            }
        }

        const area = Bounds.fromCenter(from, mover.halfExtents()).sweptBy(motion);
        try self.broadphase.query(gpa, area, &self.candidates);
        for (self.candidates.handles()) |candidate| {
            const other = self.bodies.get(candidate) orelse continue;
            if (!body_mod.maskAdmits(mask, other.*)) continue;
            const sweep = shape_mod.sweepRounded(
                mover.sum(.of(other.shape)),
                from,
                motion,
                other.position,
                .all,
            ) orelse continue;
            if (sweep.startedInside()) continue;
            try self.casts.append(gpa, .{
                .hit = .{
                    .body = candidate,
                    .normal = sweep.normal,
                    .fraction = sweep.fraction,
                    .user = other.user,
                },
                .order = @intCast(self.casts.items.len),
            });
        }

        std.sort.pdq(Cast, self.casts.items, {}, lessByFraction);

        const written: u32 = @intCast(@min(self.casts.items.len, out.len));
        for (self.casts.items[0..written], 0..) |cast, i| out[i] = cast.hit;
        return .{ .count = written, .total = @intCast(self.casts.items.len) };
    }
};

/// How far a body is held off what it stopped against.
///
/// A stated constant rather than a tuned one. It exists so that the next sweep does not begin
/// exactly on the surface it just found, where a rounding error decides whether the body is
/// touching or a hair inside. The assumption it carries is that worlds are within a few tens
/// of thousands of units of the origin, which is where `f32` positions are still finer than
/// this; a world larger than that has a bigger problem than this constant.
pub const contact_skin: f32 = 1.0 / 8192.0;

/// The sliding budget, and part of the interface because a caller can observe it.
///
/// Four, and the number is documented rather than tuned: a corner needs two, a corner between
/// a grid and a body needs three, and the fourth is there so that a degenerate arrangement
/// terminates in a slightly wrong position rather than looping.
pub const max_slide_iterations: u32 = 4;

/// One contact.
///
/// `body` and `grid` are the null handle when the contact was not of that kind, rather than
/// optionals: `Hit` is a plain struct that crosses the C ABI at M7 (I4), `?BodyHandle` is not
/// a C type, and the null handle is already the module's word for "no such thing" (I1).
/// `cell` is meaningful only when `grid` is set.
pub const Hit = struct {
    body: BodyHandle = .none,
    grid: GridHandle = .none,
    cell: [2]u32 = .{ 0, 0 },
    /// Unit length, pointing away from the surface that was struck.
    normal: Vec2,
    /// Where along the requested motion this happened, in 0..1.
    fraction: f32,
    /// The struck body's `user`. Zero for a grid.
    user: u64 = 0,

    pub fn isGrid(self: Hit) bool {
        return !self.grid.isNone();
    }
};

/// One thing a query found. No normal and no fraction, because an overlap has neither.
pub const QueryHit = struct {
    body: BodyHandle = .none,
    grid: GridHandle = .none,
    cell: [2]u32 = .{ 0, 0 },
    user: u64 = 0,

    pub fn isGrid(self: QueryHit) bool {
        return !self.grid.isNone();
    }
};

pub const MoveResult = struct {
    /// Where the body ended up. It has already been moved there.
    position: Vec2,
    /// Contacts written into the caller's buffer.
    hit_count: u32,
    /// Contacts there were. Greater than `hit_count` means the buffer was too small.
    total_hits: u32,
    /// The body was already overlapping something when the call began. A sweep cannot fix
    /// that, and `resolveOverlaps` is what can.
    started_inside: bool,

    pub fn truncated(self: MoveResult) bool {
        return self.total_hits > self.hit_count;
    }
};

pub const QueryResult = struct {
    count: u32,
    total: u32,

    pub fn truncated(self: QueryResult) bool {
        return self.total > self.count;
    }
};

/// Which bodies a walk considers.
const Filter = struct {
    /// The mover itself, which never collides with itself.
    ignore: BodyHandle = .none,
    mask: u32 = ~@as(u32, 0),
    /// The mover's own layer, or null for a query — which is not a body and so has no second
    /// side for the filter to agree with (`body.zig`).
    layer: ?u32 = null,
    include_triggers: bool,

    fn admits(self: Filter, handle: BodyHandle, other: Body) bool {
        if (handle.eql(self.ignore)) return false;
        if (other.kind == .trigger and !self.include_triggers) return false;
        if (self.layer) |layer| {
            return self.mask & other.layer != 0 and other.mask & layer != 0;
        }
        return body_mod.maskAdmits(self.mask, other);
    }
};

const Found = struct {
    hit: ?Hit = null,
    started_inside: bool = false,
};

const Penetration = struct {
    hit: Hit,
    depth: f32,
};

const Cast = struct {
    hit: Hit,
    order: u32,
};

fn lessByFraction(_: void, a: Cast, b: Cast) bool {
    if (a.hit.fraction != b.hit.fraction) return a.hit.fraction < b.hit.fraction;
    return a.order < b.order;
}

// -- tests -----------------------------------------------------------------------------

const testing = std.testing;

fn v(x: f32, y: f32) Vec2 {
    return .{ .x = x, .y = y };
}

/// Tile id 1 is solid, tile id 0 is not.
const solid_tile_one = [_]u32{0b10};

fn boxAt(x: f32, y: f32) Body {
    return .{
        .shape = .{ .box = .{ .x = 0.5, .y = 0.5 } },
        .position = .{ .x = x, .y = y },
        .kind = .movable,
    };
}

test "a world starts empty and cleans up after itself" {
    var world: World = .empty;
    defer world.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), world.bodyCount());
    try testing.expectEqual(@as(u32, 0), world.gridCount());

    _ = try world.addBody(testing.allocator, boxAt(0, 0));
    try testing.expectEqual(@as(u32, 1), world.bodyCount());
    try testing.expectEqual(@as(u32, 1), world.broadphase.count());
}

test "a degenerate body is refused at the boundary" {
    var world: World = .empty;
    defer world.deinit(testing.allocator);

    var bad = boxAt(0, 0);
    bad.shape = .{ .box = .{ .x = 0, .y = 1 } };
    try testing.expectError(error.InvalidShape, world.addBody(testing.allocator, bad));

    var not_finite = boxAt(0, 0);
    not_finite.position = .{ .x = std.math.nan(f32), .y = 0 };
    try testing.expectError(error.InvalidShape, world.addBody(testing.allocator, not_finite));

    // Nothing was added, so nothing below has to defend against one -- and the broadphase did
    // not gain an entry for a body the pool does not have.
    try testing.expectEqual(@as(u32, 0), world.bodyCount());
    try testing.expectEqual(@as(u32, 0), world.broadphase.count());
}

test "a stale handle names nothing, and does not name whatever took its slot" {
    var world: World = .empty;
    defer world.deinit(testing.allocator);

    const first = try world.addBody(testing.allocator, boxAt(1, 1));
    try testing.expect(world.removeBody(testing.allocator, first));
    try testing.expect(!world.removeBody(testing.allocator, first));

    const second = try world.addBody(testing.allocator, boxAt(2, 2));
    try testing.expectEqual(first.index, second.index);
    try testing.expect(first.generation != second.generation);

    try testing.expectEqual(@as(?*const Body, null), world.body(first));
    try testing.expectEqual(@as(f32, 2), world.body(second).?.position.x);
    try testing.expect(!try world.setPosition(testing.allocator, first, .{ .x = 9, .y = 9 }));
    try testing.expectEqual(@as(f32, 2), world.body(second).?.position.x);
}

test "a teleport does not pretend to be a move" {
    var world: World = .empty;
    defer world.deinit(testing.allocator);

    const handle = try world.addBody(testing.allocator, boxAt(0, 0));
    try testing.expect(try world.setPosition(testing.allocator, handle, .{ .x = 5, .y = -5 }));
    try testing.expectEqual(@as(f32, 5), world.body(handle).?.position.x);

    // A position that is not a number is refused rather than stored, because it would poison
    // every bound computed from it thereafter.
    try testing.expect(!try world.setPosition(testing.allocator, handle, .{ .x = std.math.inf(f32), .y = 0 }));
    try testing.expectEqual(@as(f32, 5), world.body(handle).?.position.x);
}

test "bodies iterate in handle-index order regardless of how they were added" {
    var world: World = .empty;
    defer world.deinit(testing.allocator);

    _ = try world.addBody(testing.allocator, boxAt(0, 0));
    const b = try world.addBody(testing.allocator, boxAt(1, 0));
    _ = try world.addBody(testing.allocator, boxAt(2, 0));

    // Free the middle slot and refill it. The pool's free list is LIFO, so the newcomer lands
    // back at index 1 -- later in insertion order, earlier in iteration order. Which of those
    // two an operation depends on is exactly what I9 requires be written down.
    try testing.expect(world.removeBody(testing.allocator, b));
    const d = try world.addBody(testing.allocator, boxAt(9, 9));
    try testing.expectEqual(b.index, d.index);

    var seen: [3]u32 = undefined;
    var count: usize = 0;
    var it = world.bodyIterator();
    while (it.next()) |entry| : (count += 1) seen[count] = entry.id.index;

    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, &seen);
}

test "a grid is validated on the way in and its slices are borrowed" {
    var world: World = .empty;
    defer world.deinit(testing.allocator);

    var tiles = [_]u16{ 0, 1, 1, 0 };
    const solid = [_]u32{0b10};
    const handle = try world.addGrid(testing.allocator, .{
        .origin = .zero,
        .cell = .one,
        .width = 2,
        .height = 2,
        .tiles = &tiles,
        .solid = &solid,
    });
    try testing.expectEqual(@as(u32, 1), world.gridCount());
    try testing.expect(world.grid(handle).?.isSolidAt(1, 0));

    // The world holds the descriptor, not a copy of the map: editing the caller's array is
    // visible immediately, which is what makes hot-reloading a tilemap a swap rather than a
    // rebuild. It is also why a grid never enters the broadphase.
    tiles[1] = 0;
    try testing.expect(!world.grid(handle).?.isSolidAt(1, 0));
    try testing.expectEqual(@as(u32, 0), world.broadphase.count());

    var bad_tiles = [_]u16{0};
    try testing.expectError(error.InvalidGrid, world.addGrid(testing.allocator, .{
        .origin = .zero,
        .cell = .one,
        .width = 4,
        .height = 4,
        .tiles = &bad_tiles,
        .solid = &solid,
    }));
}

test "a query returns only bodies the rectangle really touches" {
    var world: World = .init(.{ .cell_size = 4 });
    defer world.deinit(testing.allocator);

    var out: Candidates = .empty;
    defer out.deinit(testing.allocator);

    const near = try world.addBody(testing.allocator, boxAt(0, 0));
    // Same broadphase cell, but the rectangle misses it: the narrow phase of the query is what
    // turns a candidate into a result.
    _ = try world.addBody(testing.allocator, boxAt(3.5, 3.5));
    _ = try world.addBody(testing.allocator, boxAt(80, 80));

    try world.queryBounds(testing.allocator, .fromCenter(.zero, .{ .x = 1, .y = 1 }), ~@as(u32, 0), &out);
    try testing.expectEqual(@as(usize, 1), out.handles().len);
    try testing.expect(out.handles()[0].eql(near));
}

test "a query respects the mask, one-sidedly" {
    var world: World = .init(.{ .cell_size = 4 });
    defer world.deinit(testing.allocator);

    var out: Candidates = .empty;
    defer out.deinit(testing.allocator);

    var wall = boxAt(0, 0);
    wall.layer = 0b010;
    // Its own mask is empty, and a query still finds it: a query asks where things are, it
    // does not collide with them.
    wall.mask = 0;
    const handle = try world.addBody(testing.allocator, wall);

    try world.queryBounds(testing.allocator, .fromCenter(.zero, .one), 0b010, &out);
    try testing.expectEqual(@as(usize, 1), out.handles().len);
    try testing.expect(out.handles()[0].eql(handle));

    try world.queryBounds(testing.allocator, .fromCenter(.zero, .one), 0b100, &out);
    try testing.expectEqual(@as(usize, 0), out.handles().len);
}

test "a removed body stops being found, and a moved one is found where it went" {
    var world: World = .init(.{ .cell_size = 1 });
    defer world.deinit(testing.allocator);

    var out: Candidates = .empty;
    defer out.deinit(testing.allocator);

    const handle = try world.addBody(testing.allocator, boxAt(0, 0));
    const here: Bounds = .fromCenter(.zero, .one);
    const there: Bounds = .fromCenter(.{ .x = 30, .y = 30 }, .one);

    try world.queryBounds(testing.allocator, here, ~@as(u32, 0), &out);
    try testing.expectEqual(@as(usize, 1), out.handles().len);

    _ = try world.setPosition(testing.allocator, handle, .{ .x = 30, .y = 30 });
    try world.queryBounds(testing.allocator, here, ~@as(u32, 0), &out);
    try testing.expectEqual(@as(usize, 0), out.handles().len);
    try world.queryBounds(testing.allocator, there, ~@as(u32, 0), &out);
    try testing.expectEqual(@as(usize, 1), out.handles().len);

    try testing.expect(world.removeBody(testing.allocator, handle));
    try world.queryBounds(testing.allocator, there, ~@as(u32, 0), &out);
    try testing.expectEqual(@as(usize, 0), out.handles().len);
    try testing.expectEqual(@as(u32, 0), world.broadphase.count());
}

test "changing kind moves a body between tiers without losing it" {
    var world: World = .init(.{ .cell_size = 2 });
    defer world.deinit(testing.allocator);

    var out: Candidates = .empty;
    defer out.deinit(testing.allocator);

    const handle = try world.addBody(testing.allocator, boxAt(0, 0));
    try testing.expectEqual(@as(u32, 1), world.broadphase.movers.count());
    try testing.expectEqual(@as(u32, 0), world.broadphase.statics.count());

    try testing.expect(try world.setKind(testing.allocator, handle, .static));
    try testing.expectEqual(@as(u32, 0), world.broadphase.movers.count());
    try testing.expectEqual(@as(u32, 1), world.broadphase.statics.count());

    try world.queryBounds(testing.allocator, .fromCenter(.zero, .one), ~@as(u32, 0), &out);
    try testing.expectEqual(@as(usize, 1), out.handles().len);
    try testing.expectEqual(BodyKind.static, world.body(handle).?.kind);
}

test "growing a body's shape widens what finds it" {
    var world: World = .init(.{ .cell_size = 1 });
    defer world.deinit(testing.allocator);

    var out: Candidates = .empty;
    defer out.deinit(testing.allocator);

    const handle = try world.addBody(testing.allocator, boxAt(0, 0));
    const far: Bounds = .fromCenter(.{ .x = 3, .y = 0 }, .{ .x = 0.25, .y = 0.25 });

    try world.queryBounds(testing.allocator, far, ~@as(u32, 0), &out);
    try testing.expectEqual(@as(usize, 0), out.handles().len);

    try testing.expect(try world.setShape(testing.allocator, handle, .{ .box = .{ .x = 4, .y = 4 } }));
    try world.queryBounds(testing.allocator, far, ~@as(u32, 0), &out);
    try testing.expectEqual(@as(usize, 1), out.handles().len);

    // A degenerate replacement is refused and changes nothing.
    try testing.expect(!try world.setShape(testing.allocator, handle, .{ .circle = -1 }));
    try testing.expectEqual(@as(f32, 4), world.body(handle).?.shape.box.x);
}

test "the same world described two ways answers the same question the same way" {
    // I9, in the strongest form M5 can state at this step: two insertion orders describing the
    // same world must agree, because that is the property that catches an accidental
    // dependence on the hash. The bodies carry `user` values so the comparison is about the
    // world rather than about which slot each body happened to get.
    const places = [_][2]f32{ .{ 0, 0 }, .{ 1.5, 0.5 }, .{ -2, 1 }, .{ 40, 40 }, .{ 0.5, -1.2 } };
    const orders = [_][5]usize{
        .{ 0, 1, 2, 3, 4 },
        .{ 4, 3, 2, 1, 0 },
        .{ 2, 4, 0, 3, 1 },
    };
    const area: Bounds = .{ .min = .{ .x = -1, .y = -1 }, .max = .{ .x = 2, .y = 2 } };

    var expected: [8]u64 = undefined;
    var expected_len: usize = 0;

    for (orders, 0..) |order, run| {
        // A different cell size each run as well, so the test rejects both an order dependence
        // and a bucketing dependence at once.
        const sizes = [_]f32{ 0.5, 3, 17 };
        var world: World = .init(.{ .cell_size = sizes[run] });
        defer world.deinit(testing.allocator);

        var out: Candidates = .empty;
        defer out.deinit(testing.allocator);

        for (order) |index| {
            var b = boxAt(places[index][0], places[index][1]);
            b.user = index + 1;
            _ = try world.addBody(testing.allocator, b);
        }

        try world.queryBounds(testing.allocator, area, ~@as(u32, 0), &out);

        var users: [8]u64 = undefined;
        for (out.handles(), 0..) |handle, i| users[i] = world.body(handle).?.user;
        std.sort.pdq(u64, users[0..out.handles().len], {}, std.sort.asc(u64));

        if (run == 0) {
            expected_len = out.handles().len;
            @memcpy(expected[0..expected_len], users[0..expected_len]);
            // Two of the five are outside the rectangle, and one of those only just.
            try testing.expectEqual(@as(usize, 3), expected_len);
        } else {
            try testing.expectEqualSlices(u64, expected[0..expected_len], users[0..out.handles().len]);
        }
    }
}

// -- movement ---------------------------------------------------------------------------

fn staticBox(x: f32, y: f32, hx: f32, hy: f32) Body {
    return .{
        .shape = .{ .box = v(hx, hy) },
        .position = v(x, y),
        .kind = .static,
    };
}

test "a body stops against a wall and is left just clear of it" {
    const gpa = testing.allocator;
    var world: World = .empty;
    defer world.deinit(gpa);

    _ = try world.addBody(gpa, staticBox(5, 0, 1, 1));
    const mover = try world.addBody(gpa, boxAt(0, 0));

    var hits: [4]Hit = undefined;
    const result = (try world.moveAndSlide(gpa, mover, v(10, 0), &hits)).?;

    try testing.expectEqual(@as(u32, 1), result.total_hits);
    try testing.expectEqual(@as(u32, 1), result.hit_count);
    try testing.expect(!result.truncated());
    try testing.expect(!result.started_inside);
    // The wall's left face is at x = 4 and the mover is 0.5 wide, so 3.5 -- less the skin.
    try testing.expectApproxEqAbs(@as(f32, 3.5), result.position.x, 2 * contact_skin);
    try testing.expectEqual(@as(f32, 0), result.position.y);
    try testing.expectEqual(v(-1, 0), hits[0].normal);
    try testing.expectApproxEqAbs(@as(f32, 0.35), hits[0].fraction, 1e-3);
    try testing.expect(!hits[0].isGrid());

    // The body is where the result says it is: `moveAndSlide` commits, so a caller cannot
    // forget to, and the broadphase is updated with it.
    try testing.expectEqual(result.position, world.body(mover).?.position);
}

test "a body slides along what it hits instead of stopping dead" {
    const gpa = testing.allocator;
    var world: World = .empty;
    defer world.deinit(gpa);

    _ = try world.addBody(gpa, staticBox(5, 0, 1, 100));
    const mover = try world.addBody(gpa, boxAt(0, 0));

    var hits: [4]Hit = undefined;
    const result = (try world.moveAndSlide(gpa, mover, v(10, 4), &hits)).?;

    try testing.expectEqual(@as(u32, 1), result.total_hits);
    // Stopped in x...
    try testing.expectApproxEqAbs(@as(f32, 3.5), result.position.x, 2 * contact_skin);
    // ...and the whole of the y motion still delivered. Without the projection this would be
    // 1.4: the fraction of the way it got before the wall.
    try testing.expectApproxEqAbs(@as(f32, 4), result.position.y, 1e-5);
}

test "a corner costs two contacts and the body ends in it" {
    const gpa = testing.allocator;
    var world: World = .empty;
    defer world.deinit(gpa);

    _ = try world.addBody(gpa, staticBox(5, 0, 1, 100));
    _ = try world.addBody(gpa, staticBox(0, 6, 100, 1));
    const mover = try world.addBody(gpa, boxAt(0, 0));

    var hits: [4]Hit = undefined;
    const result = (try world.moveAndSlide(gpa, mover, v(10, 10), &hits)).?;

    try testing.expectEqual(@as(u32, 2), result.total_hits);
    try testing.expectApproxEqAbs(@as(f32, 3.5), result.position.x, 2 * contact_skin);
    try testing.expectApproxEqAbs(@as(f32, 4.5), result.position.y, 2 * contact_skin);
    try testing.expectEqual(v(-1, 0), hits[0].normal);
    try testing.expectEqual(v(0, -1), hits[1].normal);
    // Fractions are against the requested motion and rise, which is what makes them
    // comparable across an iteration that changed direction.
    try testing.expect(hits[0].fraction < hits[1].fraction);
}

test "a buffer too small keeps what fits and says how much it missed" {
    const gpa = testing.allocator;
    var world: World = .empty;
    defer world.deinit(gpa);

    _ = try world.addBody(gpa, staticBox(5, 0, 1, 100));
    _ = try world.addBody(gpa, staticBox(0, 6, 100, 1));
    const mover = try world.addBody(gpa, boxAt(0, 0));

    var one: [1]Hit = undefined;
    const result = (try world.moveAndSlide(gpa, mover, v(10, 10), &one)).?;
    try testing.expectEqual(@as(u32, 1), result.hit_count);
    try testing.expectEqual(@as(u32, 2), result.total_hits);
    try testing.expect(result.truncated());
    // Truncation loses contacts, never the movement: the body is still in the corner.
    try testing.expectApproxEqAbs(@as(f32, 4.5), result.position.y, 2 * contact_skin);
}

test "the sliding budget is finite, so no arrangement loops" {
    const gpa = testing.allocator;
    var world: World = .empty;
    defer world.deinit(gpa);

    // A funnel narrowing to nothing: every slide presses the body into the other side.
    _ = try world.addBody(gpa, staticBox(0, 4, 100, 1));
    _ = try world.addBody(gpa, staticBox(0, -4, 100, 1));
    _ = try world.addBody(gpa, staticBox(6, 0, 1, 100));
    const mover = try world.addBody(gpa, boxAt(0, 0));

    var hits: [16]Hit = undefined;
    const result = (try world.moveAndSlide(gpa, mover, v(10, 10), &hits)).?;
    try testing.expect(result.total_hits <= max_slide_iterations);
}

test "a grid stops a body and names the cell it stopped against" {
    const gpa = testing.allocator;
    var world: World = .empty;
    defer world.deinit(gpa);

    var tiles = [_]u16{
        0, 0, 0, 1,
        0, 0, 0, 1,
        0, 0, 0, 1,
        0, 0, 0, 1,
    };
    const tilemap = try world.addGrid(gpa, .{
        .origin = .zero,
        .cell = .one,
        .width = 4,
        .height = 4,
        .tiles = &tiles,
        .solid = &solid_tile_one,
    });
    const mover = try world.addBody(gpa, boxAt(0.5, 2.5));

    var hits: [4]Hit = undefined;
    const result = (try world.moveAndSlide(gpa, mover, v(5, 0), &hits)).?;

    try testing.expectEqual(@as(u32, 1), result.total_hits);
    try testing.expectApproxEqAbs(@as(f32, 2.5), result.position.x, 2 * contact_skin);
    try testing.expect(hits[0].isGrid());
    try testing.expect(hits[0].grid.eql(tilemap));
    try testing.expectEqual([2]u32{ 3, 2 }, hits[0].cell);
    try testing.expectEqual(v(-1, 0), hits[0].normal);
}

test "a body already in a wall says so, and getting out is a separate call" {
    const gpa = testing.allocator;
    var world: World = .empty;
    defer world.deinit(gpa);

    _ = try world.addBody(gpa, staticBox(0, 0, 1, 1));
    const mover = try world.addBody(gpa, boxAt(0.25, 0));

    var hits: [4]Hit = undefined;
    // Asking for no motion at all still answers the question, because it is one a caller
    // wants whether or not it asked to move.
    const still = (try world.moveAndSlide(gpa, mover, .zero, &hits)).?;
    try testing.expect(still.started_inside);
    try testing.expectEqual(@as(u32, 0), still.total_hits);
    try testing.expectEqual(v(0.25, 0), still.position);

    const freed = (try world.resolveOverlaps(gpa, mover, &hits)).?;
    try testing.expect(freed.started_inside);
    try testing.expectEqual(@as(u32, 1), freed.total_hits);
    // Out along the shortest axis: 1.25 to the right, plus the skin.
    try testing.expectApproxEqAbs(@as(f32, 1.5), freed.position.x, 2 * contact_skin);
    try testing.expectEqual(@as(f32, 0), freed.position.y);

    // And it is really out: a second call finds nothing to do.
    const again = (try world.resolveOverlaps(gpa, mover, &hits)).?;
    try testing.expect(!again.started_inside);
    try testing.expectEqual(@as(u32, 0), again.total_hits);
}

test "escaping a tile wall goes out through a face the wall has" {
    const gpa = testing.allocator;
    var world: World = .empty;
    defer world.deinit(gpa);

    var tiles = [_]u16{
        0, 0, 0,
        1, 1, 1,
        0, 0, 0,
    };
    _ = try world.addGrid(gpa, .{
        .origin = .zero,
        .cell = .one,
        .width = 3,
        .height = 3,
        .tiles = &tiles,
        .solid = &solid_tile_one,
    });
    const mover = try world.addBody(gpa, .{
        .shape = .{ .box = v(0.25, 0.25) },
        .position = v(1.5, 1.5),
        .kind = .movable,
    });

    var hits: [4]Hit = undefined;
    const freed = (try world.resolveOverlaps(gpa, mover, &hits)).?;
    try testing.expect(freed.started_inside);
    // Up, out of the wall -- not sideways into the next tile of it.
    try testing.expectEqual(@as(f32, 1.5), freed.position.x);
    try testing.expectApproxEqAbs(@as(f32, 2.25), freed.position.y, 2 * contact_skin);
    try testing.expect(hits[0].isGrid());
    try testing.expectEqual(v(0, 1), hits[0].normal);
}

test "a trigger blocks nothing, and a query still finds it" {
    const gpa = testing.allocator;
    var world: World = .empty;
    defer world.deinit(gpa);

    _ = try world.addBody(gpa, .{
        .shape = .{ .box = v(1, 1) },
        .position = v(5, 0),
        .kind = .trigger,
        .user = 77,
    });
    const mover = try world.addBody(gpa, boxAt(0, 0));

    var hits: [4]Hit = undefined;
    const result = (try world.moveAndSlide(gpa, mover, v(10, 0), &hits)).?;
    try testing.expectEqual(@as(u32, 0), result.total_hits);
    try testing.expectEqual(v(10, 0), result.position);

    var found: [4]QueryHit = undefined;
    const query = try world.overlapPoint(gpa, v(5, 0), ~@as(u32, 0), &found);
    try testing.expectEqual(@as(u32, 1), query.count);
    try testing.expectEqual(@as(u64, 77), found[0].user);
}

// -- queries ----------------------------------------------------------------------------

test "a point query reports grid cells before bodies" {
    const gpa = testing.allocator;
    var world: World = .empty;
    defer world.deinit(gpa);

    var tiles = [_]u16{ 1, 0, 0, 0 };
    _ = try world.addGrid(gpa, .{
        .origin = .zero,
        .cell = .one,
        .width = 2,
        .height = 2,
        .tiles = &tiles,
        .solid = &solid_tile_one,
    });
    var body = boxAt(0.5, 0.5);
    body.user = 9;
    _ = try world.addBody(gpa, body);

    var found: [4]QueryHit = undefined;
    const query = try world.overlapPoint(gpa, v(0.5, 0.5), ~@as(u32, 0), &found);
    try testing.expectEqual(@as(u32, 2), query.count);
    try testing.expectEqual(@as(u32, 2), query.total);
    try testing.expect(found[0].isGrid());
    try testing.expectEqual([2]u32{ 0, 0 }, found[0].cell);
    try testing.expect(!found[1].isGrid());
    try testing.expectEqual(@as(u64, 9), found[1].user);
}

test "an overlap query is filtered by layer" {
    const gpa = testing.allocator;
    var world: World = .empty;
    defer world.deinit(gpa);

    _ = try world.addBody(gpa, .{
        .shape = .{ .box = v(1, 1) },
        .position = .zero,
        .kind = .movable,
        .layer = 0b001,
        .user = 1,
    });
    _ = try world.addBody(gpa, .{
        .shape = .{ .box = v(1, 1) },
        .position = .zero,
        .kind = .movable,
        .layer = 0b010,
        .user = 2,
    });

    var found: [4]QueryHit = undefined;
    const query = try world.overlapShape(gpa, .{ .circle = 0.5 }, .zero, 0b010, &found);
    try testing.expectEqual(@as(u32, 1), query.count);
    try testing.expectEqual(@as(u64, 2), found[0].user);
}

test "a raycast returns its hits by increasing fraction, whatever order they were added in" {
    const gpa = testing.allocator;
    var world: World = .empty;
    defer world.deinit(gpa);

    // Added far to near, so handle order is the opposite of the answer.
    for ([_]f32{ 6, 4, 2 }) |x| {
        _ = try world.addBody(gpa, .{
            .shape = .{ .box = v(0.5, 0.5) },
            .position = v(x, 0),
            .kind = .static,
            .user = @intFromFloat(x),
        });
    }

    var hits: [8]Hit = undefined;
    const query = try world.raycast(gpa, v(0, 0), v(10, 0), ~@as(u32, 0), &hits);
    try testing.expectEqual(@as(u32, 3), query.count);
    try testing.expectEqual(@as(u64, 2), hits[0].user);
    try testing.expectEqual(@as(u64, 4), hits[1].user);
    try testing.expectEqual(@as(u64, 6), hits[2].user);
    try testing.expectApproxEqAbs(@as(f32, 0.15), hits[0].fraction, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.55), hits[2].fraction, 1e-6);

    // And a buffer that cannot hold them all keeps the earliest, which is the useful half.
    var two: [2]Hit = undefined;
    const short = try world.raycast(gpa, v(0, 0), v(10, 0), ~@as(u32, 0), &two);
    try testing.expectEqual(@as(u32, 2), short.count);
    try testing.expectEqual(@as(u32, 3), short.total);
    try testing.expect(short.truncated());
    try testing.expectEqual(@as(u64, 2), two[0].user);
    try testing.expectEqual(@as(u64, 4), two[1].user);
}

test "a shape cast sweeps a volume, so it finds what a ray between the same points misses" {
    const gpa = testing.allocator;
    var world: World = .empty;
    defer world.deinit(gpa);

    _ = try world.addBody(gpa, staticBox(5, 1.2, 0.5, 0.5));

    var hits: [4]Hit = undefined;
    const missed = try world.raycast(gpa, v(0, 0), v(10, 0), ~@as(u32, 0), &hits);
    try testing.expectEqual(@as(u32, 0), missed.count);

    const swept = try world.shapeCast(gpa, .{ .circle = 1 }, v(0, 0), v(10, 0), ~@as(u32, 0), &hits);
    try testing.expectEqual(@as(u32, 1), swept.count);
    try testing.expectApproxEqAbs(@as(f32, 0.37858), hits[0].fraction, 1e-4);
    // A rounded corner, so the normal is neither axis.
    try testing.expect(hits[0].normal.x < 0 and hits[0].normal.y < 0);
}

// -- determinism ------------------------------------------------------------------------

fn cornerRun(gpa: Allocator, options: Options, reversed: bool) !MoveResult {
    var world: World = .init(options);
    defer world.deinit(gpa);

    const first = staticBox(5, 0, 1, 100);
    const second = staticBox(0, 6, 100, 1);
    if (reversed) {
        _ = try world.addBody(gpa, second);
        _ = try world.addBody(gpa, first);
    } else {
        _ = try world.addBody(gpa, first);
        _ = try world.addBody(gpa, second);
    }
    const mover = try world.addBody(gpa, boxAt(0, 0));

    var hits: [4]Hit = undefined;
    return (try world.moveAndSlide(gpa, mover, v(10, 10), &hits)).?;
}

test "the same world described two ways moves a body to the same place" {
    // ADR-0013's fixed-scenario test, in the form that catches what matters here: the two
    // worlds are identical geometry reached by different insertion orders, so an answer that
    // depended on handle order or on a hash bucket would differ.
    const gpa = testing.allocator;
    const forward = try cornerRun(gpa, .{}, false);
    const reversed = try cornerRun(gpa, .{}, true);

    try testing.expectEqual(forward.position, reversed.position);
    try testing.expectEqual(forward.total_hits, reversed.total_hits);
}

test "the broadphase cell size does not change where a body stops" {
    const gpa = testing.allocator;
    const fine = try cornerRun(gpa, .{ .cell_size = 0.5 }, false);
    const coarse = try cornerRun(gpa, .{ .cell_size = 1000 }, false);

    try testing.expectEqual(fine.position, coarse.position);
    try testing.expectEqual(fine.total_hits, coarse.total_hits);
}

test "a stale handle is refused rather than moved" {
    const gpa = testing.allocator;
    var world: World = .empty;
    defer world.deinit(gpa);

    const mover = try world.addBody(gpa, boxAt(0, 0));
    try testing.expect(world.removeBody(gpa, mover));

    var hits: [4]Hit = undefined;
    try testing.expectEqual(@as(?MoveResult, null), try world.moveAndSlide(gpa, mover, v(1, 0), &hits));
    try testing.expectEqual(@as(?MoveResult, null), try world.resolveOverlaps(gpa, mover, &hits));
}

test "a body walked along a tiled floor never snags on a seam" {
    // The internal-edge fix as a game sees it, rather than as a sweep does. Twelve steps of
    // "right and slightly down", which is what a top-down character pressed against a wall or
    // a platformer character walking actually asks for, and every cell boundary crossed is a
    // chance to report a vertical normal pointing back the way it came.
    const gpa = testing.allocator;
    var world: World = .empty;
    defer world.deinit(gpa);

    var tiles = [_]u16{
        1, 1, 1, 1, 1, 1, 1, 1,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
    };
    _ = try world.addGrid(gpa, .{
        .origin = .zero,
        .cell = .one,
        .width = 8,
        .height = 4,
        .tiles = &tiles,
        .solid = &solid_tile_one,
    });
    const mover = try world.addBody(gpa, boxAt(0.5, 1.6));

    var hits: [8]Hit = undefined;
    var contacts: u32 = 0;
    var step: u32 = 0;
    while (step < 12) : (step += 1) {
        const result = (try world.moveAndSlide(gpa, mover, v(0.5, -0.1), &hits)).?;
        try testing.expect(!result.started_inside);
        contacts += result.total_hits;
        for (hits[0..result.hit_count]) |hit| {
            // The floor is horizontal. A horizontal normal here would be the seam artefact.
            try testing.expectEqual(v(0, 1), hit.normal);
        }
    }
    // The floor is doing something, so the loop above is not passing by finding nothing.
    try testing.expect(contacts >= 10);

    const at = world.body(mover).?.position;
    // Twelve full steps of horizontal progress: the downward part is absorbed by the floor
    // every tick and none of the horizontal part is ever lost to it.
    try testing.expectApproxEqAbs(@as(f32, 6.5), at.x, 0.01);
    // And it comes to rest a skin above the floor rather than sinking or climbing.
    try testing.expectApproxEqAbs(@as(f32, 1.5), at.y, 4 * contact_skin);
}
