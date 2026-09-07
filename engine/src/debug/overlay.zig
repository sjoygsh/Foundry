//! The overlay: a list of panels, a bar that toggles them, and the one call a game makes.
//!
//! Design: `docs/design/debug-overlay.md` §10.

const std = @import("std");
const Allocator = std.mem.Allocator;

const app = @import("app");
const asset = @import("asset");
const audio = @import("audio");
const core = @import("core");
const data = @import("data");
const render2d = @import("render2d");
const scene = @import("scene");
const ui = @import("ui");

const console_panel = @import("console_panel.zig");
const content_panel = @import("content_panel.zig");
const entity_panel = @import("entity_panel.zig");
const memory_panel = @import("memory_panel.zig");
const profiler_panel = @import("profiler_panel.zig");

const Rect = core.math.Rect;
const log = core.log.scoped(.overlay);

/// The names the overlay gives its own timing spans.
///
/// **The overlay's own cost is on the overlay** (§10.3). Describing the panels happens
/// inside the frame the profiler panel is drawing, so it is measured there rather than
/// beside it — an overlay whose cost is invisible in its own profile is a tool that lies
/// about the thing it exists to measure.
pub const span = struct {
    pub const overlay = "debug.overlay";
};

/// Seeds every built-in panel's id. Namespaced, because a game's panel ids share the
/// kernel's id space and a collision is a widget that does not respond.
pub const root_id: ui.Id = ui.Id.root.child("foundry.debug");

pub const Options = struct {
    /// Inset from the viewport to the overlay's own area.
    margin: f32 = 8,
    /// How wide the column of open panels is.
    panel_width: f32 = 420,
    /// Whether the five built-in panels are registered at `init`.
    ///
    /// On by default and off for a test that wants to assert about one panel, which is the
    /// only reason it exists.
    builtins: bool = true,
};

pub const Panels = opaque {};
pub const PanelHandle = core.Handle(Panels);

/// A panel is a registration, not a case in a `switch`.
///
/// The five built-in panels register through the same call a game's panel uses, and a mod's
/// will at M7. That is I3's discipline in a small place: the built-in panels are not
/// special, so the path a third party takes is the path we are already on. A `switch` over
/// an enum would have to be replaced by exactly this the first time somebody outside the
/// engine wanted a panel.
pub const Panel = struct {
    /// Identity, and the seed for every widget the panel describes. Distinct per panel.
    id: ui.Id,
    /// What the toggle in the bar says, and what the panel's first line says.
    title: []const u8,
    /// Handed back to `describe` untouched. A panel's state lives with whoever registered
    /// it, exactly as a component type's does (ADR-0010).
    ctx: ?*anyopaque = null,
    describe: *const fn (ctx: ?*anyopaque, view: *View) anyerror!void,
    open: bool = false,
};

/// A bound `Engine.reloadContent`.
///
/// The one mutation in the whole overlay, and it is not introspection: it is the call a game
/// already makes on a key press, put where a person looks for it (§8.2). It is a pointer
/// pair rather than a method because `View` is not generic — see `Frame`.
pub const Reload = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque) void,

    pub fn invoke(self: Reload) void {
        self.call(self.ctx);
    }
};

/// What the engine knows, as a value.
///
/// **Panels are handed this rather than the engine**, and the reason is worth stating: at
/// M7 a panel will be handed an API table and not an `*Engine`, so a panel written against
/// a snapshot of public answers is a panel that ports by changing where the snapshot comes
/// from. It also makes every panel non-generic and every panel test hermetic — a test
/// builds a `Frame` by hand and needs no engine, no platform and no device at all.
///
/// Everything here is borrowed for the frame, which is the lifetime rule the frame arena
/// already gives everything else (§3).
pub const Frame = struct {
    /// The engine's frame counter, which is what a log line's `frame` stamp lines up with.
    index: u64 = 0,
    delta: core.time.Duration = .zero,
    /// Null when the profiler is off, which is an answer rather than an absence.
    profiler: ?*const core.profile.Recorder = null,
    /// One entry per registered counter, in registration order. Empty is the honest answer
    /// for a game that registered none: there is no global allocator to enumerate (§5).
    memory: []const app.MemoryReport = &.{},
    /// The engine frame arena's high-water mark, in bytes.
    arena_peak: usize = 0,
    store: ?*const data.Store = null,
    /// Mutable only because `data.Registry.lookup` takes a mutable pointer — the browser
    /// reads it and writes nothing. Widening that call is a `data` change and not this
    /// panel's to make.
    schemas: ?*data.Registry = null,
    assets: ?*const asset.Registry = null,
    content_generation: u64 = 0,
    reload: ?Reload = null,

    /// Reads the engine into a `Frame`.
    ///
    /// Every call here is public, and every one of them is on ADR-0025's list of calls a
    /// mod could be given at M7. Nothing reaches into a field the engine does not offer.
    pub fn capture(engine: anytype, arena: Allocator) Allocator.Error!Frame {
        var memory: std.ArrayList(app.MemoryReport) = .empty;
        var counters = engine.memory();
        while (counters.next()) |report| try memory.append(arena, report);

        const Engine = @TypeOf(engine);
        const bind = struct {
            fn call(ctx: *anyopaque) void {
                const e: Engine = @ptrCast(@alignCast(ctx));
                e.reloadContent();
            }
        };

        return .{
            .index = engine.frame_index,
            .delta = engine.frameDelta(),
            .profiler = engine.profiler(),
            .memory = memory.items,
            .arena_peak = engine.frameArenaHighWater(),
            .store = &engine.store,
            .schemas = &engine.schemas,
            .assets = &engine.assets,
            .content_generation = engine.contentGeneration(),
            .reload = .{ .ctx = engine, .call = bind.call },
        };
    }
};

/// What the engine does **not** own, and therefore what the game has to hand over.
///
/// The line is exactly that: `app.Engine` has a store and an asset registry, so listing
/// those here would have created two answers to "which store". It has no field for a world,
/// a renderer or a mixer — the frame is the engine's and what it simulates, draws and plays
/// is the game's — so those three are the ones a caller supplies.
///
/// All optional. A game with no world passes no world and the entity panel says so, because
/// a panel that vanishes is indistinguishable from a panel nobody wrote.
pub const Sources = struct {
    world: ?*const scene.World = null,
    renderer: ?*const render2d.Renderer = null,
    mixer: ?*const audio.Mixer = null,
};

/// What a panel is handed.
///
/// A panel that wants something this does not carry is a panel asking for a call that does
/// not exist yet, which is the conversation ADR-0025 exists to force.
pub const View = struct {
    /// The context to describe into. Already inside the panel's region: the overlay opened
    /// the panel, drew its title and will close it, so a panel describes contents only.
    ui: *ui.Context,
    /// The frame arena, and the only allocator a panel may use during a frame (§12).
    arena: Allocator,
    frame: Frame,
    sources: Sources,

    /// A formatted line of text.
    ///
    /// Allocation failure renders a marker rather than propagating: a tool that dies while
    /// diagnosing an out-of-memory problem is a bad tool (§12).
    pub fn line(self: *View, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try ui.label(self.ui, self.text(fmt, args));
    }

    /// A formatted string in the frame arena, for a caller that wants to measure it or put
    /// it on a button rather than in a label.
    pub fn text(self: *View, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.arena, fmt, args) catch "...";
    }

    /// The height of one row of a list: what `Window` and `beginScroll` both count in.
    pub fn row(self: *const View) f32 {
        return self.ui.style.line_height + self.ui.style.spacing;
    }
};

/// §11's windowing convention, as a value.
///
/// `ui.md` §14 left culling open and the answer turned out not to be in the kernel: **the
/// caller emits only the visible rows**, because the caller is the only one that knows a row
/// is a row. The kernel would have to guess a row's height, and could only skip commands
/// after they were built — which saves the draw and not the formatting, and for a list of
/// ten thousand log lines the formatting is the cost.
pub const Window = struct {
    /// Index of the first row to describe.
    first: usize,
    /// How many to describe.
    count: usize,
    total: usize,
    row: f32,

    /// What `beginScroll` is told the contents are worth.
    pub fn contentHeight(self: Window) f32 {
        return @as(f32, @floatFromInt(self.total)) * self.row;
    }

    /// The rows above the window, as one gap.
    pub fn before(self: Window) f32 {
        return @as(f32, @floatFromInt(self.first)) * self.row;
    }

    /// The rows below it, likewise. Ten thousand rows cost two `spacer`s.
    pub fn after(self: Window) f32 {
        return @as(f32, @floatFromInt(self.total -| (self.first + self.count))) * self.row;
    }
};

/// Which rows of `total` a scroll region will actually show.
///
/// Read **before** `beginScroll`, which is what makes the window computable at all: the
/// offset in `stateOf(id)` is last frame's, which is this frame's, and the kernel clamped it
/// when it drew. `capacity` is how many rows the caller has room to format.
pub fn windowOf(ctx: *ui.Context, list_id: ui.Id, total: usize, capacity: usize, row: f32) Window {
    if (row <= 0 or total == 0) return .{ .first = 0, .count = 0, .total = total, .row = @max(row, 1) };
    const scroll = @max(0, ctx.stateOf(list_id).scroll);
    const first: usize = @min(total, @as(usize, @intFromFloat(@floor(scroll / row))));
    return .{
        .first = first,
        .count = @min(capacity, total - first),
        .total = total,
        .row = row,
    };
}

/// How many rows of height `row` fit in `height`, plus the one a half-scrolled view needs.
pub fn rowsIn(height: f32, row: f32) usize {
    if (row <= 0 or height <= 0) return 1;
    return @as(usize, @intFromFloat(@floor(height / row))) + 1;
}

pub const Overlay = struct {
    gpa: Allocator,
    options: Options,
    panels: std.ArrayList(Panel) = .empty,

    /// The built-in panels' state. Fixed, allocated once, and never grown during a frame:
    /// the overlay allocates from the frame arena and from nowhere else while describing
    /// (§12).
    profiler: profiler_panel.State = .{},
    memory: memory_panel.State = .{},
    console: console_panel.State = .{},
    entities: entity_panel.State = .{},
    content: content_panel.State = .{},

    /// Heap-allocated because the built-in panels are registered with pointers into it, the
    /// same reason `app.Engine.init` returns a pointer.
    pub fn init(gpa: Allocator, options: Options) Allocator.Error!*Overlay {
        const self = try gpa.create(Overlay);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .options = options };

        if (options.builtins) {
            _ = try self.addPanel(.{
                .id = root_id.child("profiler"),
                .title = "profiler",
                .ctx = &self.profiler,
                .describe = profiler_panel.State.describe,
                .open = true,
            });
            _ = try self.addPanel(.{
                .id = root_id.child("memory"),
                .title = "memory",
                .ctx = &self.memory,
                .describe = memory_panel.State.describe,
            });
            _ = try self.addPanel(.{
                .id = root_id.child("log"),
                .title = "log",
                .ctx = &self.console,
                .describe = console_panel.State.describe,
            });
            _ = try self.addPanel(.{
                .id = root_id.child("entities"),
                .title = "entities",
                .ctx = &self.entities,
                .describe = entity_panel.State.describe,
            });
            _ = try self.addPanel(.{
                .id = root_id.child("content"),
                .title = "content",
                .ctx = &self.content,
                .describe = content_panel.State.describe,
            });
        }
        return self;
    }

    pub fn deinit(self: *Overlay) void {
        const gpa = self.gpa;
        self.panels.deinit(gpa);
        self.* = undefined;
        gpa.destroy(self);
    }

    /// Registers a panel. The call a game's own panel uses, and a mod's at M7.
    pub fn addPanel(self: *Overlay, entry: Panel) Allocator.Error!PanelHandle {
        const index: u32 = @intCast(self.panels.items.len);
        try self.panels.append(self.gpa, entry);
        // Not a `HandlePool`: panels are registered at start-up and never removed, so a
        // generation would be a field nothing could ever invalidate. The handle stays a
        // handle so that removal can be added without changing what a caller holds (I1).
        return .{ .index = index, .generation = 1 };
    }

    /// The registered panel, for a caller that wants to open, close or retitle one.
    /// Null for a handle that names nothing, which is an answer and not a fault.
    pub fn panel(self: *Overlay, handle: PanelHandle) ?*Panel {
        if (handle.index >= self.panels.items.len) return null;
        return &self.panels.items[handle.index];
    }

    /// Opens or closes a panel by title. What a game binds a key to.
    pub fn toggle(self: *Overlay, title: []const u8) void {
        for (self.panels.items) |*p| {
            if (std.mem.eql(u8, p.title, title)) p.open = !p.open;
        }
    }

    /// Describe the overlay: one call per frame, from the game, **before it reads its own
    /// input**.
    ///
    /// That order is the point rather than a convenience. The kernel resolves what the user
    /// is pointing at while there is still time for the game to keep its hands off it, and
    /// capture is advisory (`ui.md` step 6), so the game can only hold an input back if the
    /// overlay has already been described when the game looks.
    ///
    /// `engine` is `anytype` for the reason `Engine.renderFrame`'s recorder is: the engine
    /// is generic over its platform and its device, and a test drives a headless one. What
    /// it must provide is what `Frame.capture` reads, and nothing else.
    pub fn describe(
        self: *Overlay,
        ctx: *ui.Context,
        engine: anytype,
        sources: Sources,
    ) Allocator.Error!void {
        const scope = engine.beginScope(span.overlay);
        defer scope.end();

        const arena = engine.frameAllocator();
        try self.describeIn(ctx, try Frame.capture(engine, arena), arena, sources);
    }

    /// `describe`, from a frame somebody else assembled. What the tests drive, and what a
    /// future host that is not an `app.Engine` — the editor, at M6+ — would call.
    pub fn describeIn(
        self: *Overlay,
        ctx: *ui.Context,
        frame: Frame,
        arena: Allocator,
        sources: Sources,
    ) Allocator.Error!void {
        const style = ctx.style;
        // The viewport, as the region `Context.begin` opened. Reading it here is why the
        // overlay must be described at the top level rather than inside somebody's panel.
        const area = inset(ctx.region().bounds, self.options.margin);
        if (area.isEmpty()) return;

        var view: View = .{ .ui = ctx, .arena = arena, .frame = frame, .sources = sources };

        const bar_height = style.line_height + style.padding.y * 2;
        try self.describeBar(ctx, .init(area.x, area.y, area.w, bar_height));

        var open: usize = 0;
        for (self.panels.items) |p| {
            if (p.open) open += 1;
        }
        if (open == 0) return;

        // Open panels share one column, evenly. A panel that wants more room is a panel
        // whose neighbours can be closed; the alternative — sizing each to its contents —
        // needs a height nobody can know before describing, which is the cursor layout's
        // one real limitation (`ui.md` §5).
        const top = area.y + bar_height + style.spacing;
        const height = @max(0, area.y + area.h - top);
        const each = (height - style.spacing * @as(f32, @floatFromInt(open -| 1))) /
            @as(f32, @floatFromInt(open));
        var y = top;

        for (self.panels.items) |*p| {
            if (!p.open) continue;
            defer y += each + style.spacing;

            try ui.beginPanel(ctx, p.id, .init(area.x, y, self.options.panel_width, each));
            try ui.label(ctx, p.title);
            try ui.separator(ctx);

            // **A panel that fails is a line of text, not a dead overlay.** A panel may be a
            // mod's from M7, and the one moment a tool must not disappear is the moment the
            // thing it is inspecting is broken. An unbalanced region left behind by a failed
            // panel is reported by `Context.end` rather than crashing, which is the same
            // bargain the kernel already makes with a miscounting caller.
            p.describe(p.ctx, &view) catch |err| {
                ui.label(ctx, view.text("panel failed: {t}", .{err})) catch {};
            };
            try ui.endPanel(ctx);
        }
    }

    /// The row of toggles. Sized to its buttons rather than to the viewport, so the pointer
    /// is taken from the game over the bar and nowhere else.
    fn describeBar(self: *Overlay, ctx: *ui.Context, bounds: Rect) Allocator.Error!void {
        const style = ctx.style;
        var width = style.padding.x * 2;
        for (self.panels.items, 0..) |p, i| {
            width += style.font.measure(p.title, style.text_scale).x + style.padding.x * 2;
            if (i != 0) width += style.spacing;
        }

        try ui.beginPanel(ctx, root_id.child("bar"), .init(bounds.x, bounds.y, width, bounds.h));
        try ui.beginRow(ctx, root_id.child("bar.row"), style.line_height);
        for (self.panels.items) |*p| {
            // Seeded by the panel's own id, so two panels with the same title still have
            // two toggles — identity is never derived from display text (`ui.md` id.zig).
            if (try ui.button(ctx, p.id.child("toggle"), p.title)) p.open = !p.open;
        }
        ui.endRow(ctx);
        try ui.endPanel(ctx);
    }
};

/// A content id, named if anything loaded knows its spelling.
///
/// **A hash can be shown as a name** (§8), and that is not an accident: `.fpk` interns the
/// source spelling of every package, schema and record id because a package that can only
/// state its own id is a package no diagnostic can name. An id nothing defines prints as its
/// hash — which is itself the answer to the most common content bug.
pub fn idText(arena: Allocator, store: ?*const data.Store, id: core.ContentId) []const u8 {
    if (id.hash == 0) return "none";
    if (store) |s| {
        if (s.lookup(id)) |record| return record.name;
    }
    return std.fmt.allocPrint(arena, "{x}", .{id.hash}) catch "...";
}

/// One field's value, as text.
///
/// Depth-bounded rather than trusting the input: this walks a structure that came out of a
/// file or out of a mod's serializer, and unbounded recursion on untrusted input is a stack
/// overflow with extra steps — the same reason `Value.clone` counts depth.
pub fn valueText(arena: Allocator, store: ?*const data.Store, value: data.Value) []const u8 {
    return valueTextDepth(arena, store, value, 0);
}

const max_value_depth = 4;
const max_listed_elements = 8;

fn valueTextDepth(
    arena: Allocator,
    store: ?*const data.Store,
    value: data.Value,
    depth: u32,
) []const u8 {
    if (depth >= max_value_depth) return "...";
    return switch (value) {
        .bool => |b| if (b) "true" else "false",
        .int => |i| std.fmt.allocPrint(arena, "{d}", .{i}) catch "...",
        .float => |f| std.fmt.allocPrint(arena, "{d}", .{f}) catch "...",
        .string => |t| std.fmt.allocPrint(arena, "\"{s}\"", .{t}) catch "...",
        .id => |i| idText(arena, store, i),
        .list => |items| listText(arena, store, items, depth),
        .nested => |fields| nestedText(arena, store, fields, depth),
    };
}

fn listText(
    arena: Allocator,
    store: ?*const data.Store,
    items: []const data.Value,
    depth: u32,
) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.append(arena, '[') catch return "...";
    for (items, 0..) |item, i| {
        if (i == max_listed_elements) {
            out.appendSlice(arena, std.fmt.allocPrint(arena, "... {d} more", .{items.len - i}) catch "...") catch return "...";
            break;
        }
        if (i != 0) out.appendSlice(arena, ", ") catch return "...";
        out.appendSlice(arena, valueTextDepth(arena, store, item, depth + 1)) catch return "...";
    }
    out.append(arena, ']') catch return "...";
    return out.items;
}

fn nestedText(
    arena: Allocator,
    store: ?*const data.Store,
    fields: []const data.NamedValue,
    depth: u32,
) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.append(arena, '{') catch return "...";
    for (fields, 0..) |field, i| {
        if (i != 0) out.appendSlice(arena, ", ") catch return "...";
        out.appendSlice(arena, field.name) catch return "...";
        out.append(arena, '=') catch return "...";
        out.appendSlice(arena, valueTextDepth(arena, store, field.value, depth + 1)) catch return "...";
    }
    out.append(arena, '}') catch return "...";
    return out.items;
}

fn inset(bounds: Rect, by: f32) Rect {
    return .init(
        bounds.x + by,
        bounds.y + by,
        @max(0, bounds.w - by * 2),
        @max(0, bounds.h - by * 2),
    );
}

// -- reading a described frame ---------------------------------------------------------
//
// The overlay describes and does not draw, so what it produced is a list of commands rather
// than pixels. These two are how anything checks it: a test here, a game's test, and — at
// M7 — a mod's.

/// Whether any text command in the frame contains `needle`.
pub fn findText(ctx: *const ui.Context, needle: []const u8) bool {
    for (ctx.list.commands.items) |command| {
        const t = switch (command) {
            .text => |t| t,
            else => continue,
        };
        const text = ctx.list.text_bytes.items[t.text.offset..][0..t.text.len];
        if (std.mem.indexOf(u8, text, needle) != null) return true;
    }
    return false;
}

/// How many text commands the frame emitted. §11's claim, as a number a test can assert on.
pub fn countText(ctx: *const ui.Context) usize {
    var n: usize = 0;
    for (ctx.list.commands.items) |command| {
        if (command == .text) n += 1;
    }
    return n;
}

// -- tests -----------------------------------------------------------------------------

const testing = std.testing;

test "an overlay registers the five built-in panels" {
    const o = try Overlay.init(testing.allocator, .{});
    defer o.deinit();
    try testing.expectEqual(@as(usize, 5), o.panels.items.len);
    // The profiler is the one that is open to begin with: it is the panel that answers the
    // question the overlay exists for.
    try testing.expect(o.panels.items[0].open);
}

test "a game registers its own panel through the same call" {
    const o = try Overlay.init(testing.allocator, .{ .builtins = false });
    defer o.deinit();

    const Counter = struct {
        calls: u32 = 0,
        fn describe(ctx: ?*anyopaque, view: *View) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            try view.line("called {d}", .{self.calls});
        }
    };
    var counter: Counter = .{};

    const handle = try o.addPanel(.{
        .id = ui.Id.root.child("game"),
        .title = "game",
        .ctx = &counter,
        .describe = Counter.describe,
        .open = true,
    });
    try testing.expect(o.panel(handle) != null);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var ctx = ui.Context.init(testing.allocator, testStyle());
    defer ctx.deinit();
    ctx.begin(.{}, .init(0, 0, 800, 600));
    try o.describeIn(&ctx, .{}, arena.allocator(), .{});
    ctx.end();

    try testing.expectEqual(@as(u32, 1), counter.calls);
    try testing.expect(findText(&ctx, "called 1"));
}

test "a panel that fails is a line of text and the rest of the frame survives" {
    const o = try Overlay.init(testing.allocator, .{ .builtins = false });
    defer o.deinit();

    const Broken = struct {
        fn describe(_: ?*anyopaque, _: *View) anyerror!void {
            return error.Refused;
        }
    };
    const Fine = struct {
        fn describe(_: ?*anyopaque, view: *View) anyerror!void {
            try view.line("still here", .{});
        }
    };
    _ = try o.addPanel(.{
        .id = ui.Id.root.child("broken"),
        .title = "broken",
        .describe = Broken.describe,
        .open = true,
    });
    _ = try o.addPanel(.{
        .id = ui.Id.root.child("fine"),
        .title = "fine",
        .describe = Fine.describe,
        .open = true,
    });

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var ctx = ui.Context.init(testing.allocator, testStyle());
    defer ctx.deinit();
    ctx.begin(.{}, .init(0, 0, 800, 600));
    try o.describeIn(&ctx, .{}, arena.allocator(), .{});
    ctx.end();

    try testing.expect(findText(&ctx, "panel failed: Refused"));
    try testing.expect(findText(&ctx, "still here"));
}

test "a closed panel is not described and its toggle still is" {
    const o = try Overlay.init(testing.allocator, .{ .builtins = false });
    defer o.deinit();

    const Never = struct {
        fn describe(ctx: ?*anyopaque, _: *View) anyerror!void {
            const seen: *bool = @ptrCast(@alignCast(ctx.?));
            seen.* = true;
        }
    };
    var seen = false;
    _ = try o.addPanel(.{
        .id = ui.Id.root.child("shut"),
        .title = "shut",
        .ctx = &seen,
        .describe = Never.describe,
    });

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var ctx = ui.Context.init(testing.allocator, testStyle());
    defer ctx.deinit();
    ctx.begin(.{}, .init(0, 0, 800, 600));
    try o.describeIn(&ctx, .{}, arena.allocator(), .{});
    ctx.end();

    try testing.expect(!seen);
    try testing.expect(findText(&ctx, "shut"));
}

test "the window skips the rows a scrolled list will not show" {
    var ctx = ui.Context.init(testing.allocator, testStyle());
    defer ctx.deinit();
    ctx.begin(.{}, .init(0, 0, 800, 600));
    defer ctx.end();

    const list = ui.Id.root.child("list");
    const row: f32 = 10;
    ctx.stateOf(list).scroll = 95;

    const w = windowOf(&ctx, list, 10_000, 6, row);
    try testing.expectEqual(@as(usize, 9), w.first);
    try testing.expectEqual(@as(usize, 6), w.count);
    try testing.expectEqual(@as(f32, 90), w.before());
    try testing.expectEqual(@as(f32, 99_850), w.after());
    try testing.expectEqual(@as(f32, 100_000), w.contentHeight());
}

test "a window past the end of a shrinking list describes nothing" {
    var ctx = ui.Context.init(testing.allocator, testStyle());
    defer ctx.deinit();
    ctx.begin(.{}, .init(0, 0, 800, 600));
    defer ctx.end();

    const list = ui.Id.root.child("list");
    ctx.stateOf(list).scroll = 500;
    const w = windowOf(&ctx, list, 3, 6, 10);
    try testing.expectEqual(@as(usize, 3), w.first);
    try testing.expectEqual(@as(usize, 0), w.count);
    try testing.expectEqual(@as(f32, 0), w.after());
}

/// A style with a fixed 8x8 cell, so a test can predict every measurement.
pub fn testStyle() ui.Style {
    return .{
        .font = .{ .cell = .init(8, 8) },
        .line_height = 12,
        .padding = .init(4, 2),
        .spacing = 2,
        .text = .white,
        .text_dim = .{ .r = 0.5, .g = 0.5, .b = 0.5 },
        .surface = .{ .r = 0.06, .g = 0.06, .b = 0.06, .a = 0.9 },
        .control = .{ .r = 0.2, .g = 0.2, .b = 0.2 },
        .control_hot = .{ .r = 0.3, .g = 0.3, .b = 0.3 },
        .control_active = .{ .r = 0.4, .g = 0.4, .b = 0.4 },
        .accent = .{ .r = 0.35, .g = 0.62, .b = 1 },
    };
}
