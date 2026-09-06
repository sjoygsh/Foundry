//! The kernel: what persists between frames, and the interaction model built on it.
//!
//! An immediate-mode UI is three ideas and a loop. A widget is a function call, not an
//! object, so there is no second copy of the state being displayed that can drift from the
//! first. Two ids carry all the interaction state: `hot` is the widget under the pointer,
//! `active` is the one the pointer went down on and has not released. And layout is a
//! cursor rather than a solver.
//!
//! **This is the first subsystem in Foundry whose state is a memory of what the user was
//! doing a frame ago.** Everything else recomputes from state the game owns; a half-finished
//! drag exists nowhere but here, while the widget it belongs to is described afresh every
//! frame. Identity (`id.zig`) is how those two facts are reconciled.
//!
//! Design: `docs/design/ui.md` §2 and §4.

const std = @import("std");
const core = @import("core");

const Allocator = std.mem.Allocator;
const Rect = core.math.Rect;
const Vec2 = core.math.Vec2;
const Id = @import("id.zig").Id;
const Input = @import("input.zig").Input;
const draw = @import("draw.zig");
const layout = @import("layout.zig");
const state_mod = @import("state.zig");
const style_mod = @import("style.zig");
const Style = style_mod.Style;
const Region = layout.Region;

const log = core.log.scoped(.ui);

/// What a widget learns about itself from one call to `interact`.
pub const Interaction = struct {
    /// The pointer is over this widget and nothing above it. Stable for the whole frame:
    /// see `Context.hot` for why it is a frame behind.
    hot: bool = false,
    /// The pointer went down on this widget and has not come up.
    active: bool = false,
    /// The pointer went down on this widget **this frame**.
    pressed: bool = false,
    /// The pointer came up over this widget after going down on it. The event a button
    /// means by "clicked", and deliberately not "the pointer went down", so that a user who
    /// presses the wrong control can slide off it and let go without consequence.
    clicked: bool = false,
    /// The widget was refused because another widget already used its id this frame. Its
    /// caller should still draw it — an inert control is easier to find than a missing one.
    duplicate: bool = false,
};

pub const Context = struct {
    gpa: Allocator,
    style: Style,
    input: Input = .{},
    list: draw.DrawList = .{},
    /// The open regions, outermost first (`layout.zig`). Reset every frame to one region
    /// covering the viewport, so there is always somewhere to put a widget.
    regions: layout.Stack = .{},

    /// The widget under the pointer, **resolved at the end of the previous frame**.
    ///
    /// This is the one piece of an immediate-mode UI that surprises people, and the reason
    /// is overlap. Widgets are described back to front, so whether a given widget is the
    /// topmost one under the pointer is not known until every widget has been described.
    /// Resolving `hot` in `end` and reading it during the next frame buys two things at
    /// once: a widget's hot state is consistent for the whole frame it draws in, and the
    /// topmost widget wins regardless of description order.
    ///
    /// The cost is one frame of latency between the pointer arriving over a control and the
    /// control accepting a press. With a physical pointer that is invisible — a person
    /// cannot see a button and press it inside 16ms — and it is what every immediate-mode UI
    /// that handles overlap correctly pays. `ui.md` §14 records the case where it is not
    /// free: synthesised or touch input that arrives already inside the control.
    hot: Id = .none,
    active: Id = .none,
    focus: Id = .none,

    /// Accumulated during the frame; becomes `hot` in `end`. Last writer wins, which is the
    /// topmost widget because description order is paint order.
    next_hot: Id = .none,

    /// Every id used this frame, so a collision is reported rather than silently giving one
    /// widget's clicks to another. Cleared, not freed, each frame.
    ///
    /// This costs one hash insert per widget. If it ever appears in the profiler M6 is
    /// building, gating it behind `runtime_safety` is the fix; guessing that it will before
    /// there is a profiler would be optimising ahead of measuring (rule 2).
    seen: std.AutoHashMapUnmanaged(Id, void) = .empty,
    duplicates: u32 = 0,

    /// What the kernel remembers between frames for the few widgets that need anything
    /// remembered: a scroll offset, a header's open flag, a caret (`state.zig`). Swept in
    /// `begin`, so a panel nobody has described for ten seconds gives its bytes back.
    states: state_mod.Store = .{},

    /// The pointer is over a container that swallows it, whether or not it reached a
    /// control. Set by `blockPointer`, cleared every frame, and read by `wantsPointer`.
    ///
    /// Without this, clicking the empty part of a debug panel would walk the player: the
    /// panel is not a widget, so nothing would be hot, so capture would say the UI did not
    /// want the click. `ui.md` §4 describes capture in terms of hot and active only; a
    /// container blocking the pointer is the part implementation added, and `samples/room`
    /// at step 6 is where it stops being theoretical.
    pointer_blocked: bool = false,

    in_frame: bool = false,

    pub fn init(gpa: Allocator, style: Style) Context {
        return .{ .gpa = gpa, .style = style };
    }

    pub fn deinit(self: *Context) void {
        self.list.deinit(self.gpa);
        self.regions.deinit(self.gpa);
        self.seen.deinit(self.gpa);
        self.states.deinit(self.gpa);
        self.* = undefined;
    }

    /// Adopt this frame's input and clear last frame's description.
    ///
    /// `viewport` is the whole area the UI may use, in the same screen points the pointer
    /// is reported in. It becomes the outermost region, so a widget described without a
    /// panel around it still lands somewhere sensible and `begin` never has to allocate.
    pub fn begin(self: *Context, input: Input, viewport: Rect) void {
        if (self.in_frame) {
            // Reported, not asserted: a caller that lost track of its frames still gets a
            // working UI, and the message says which rule was broken.
            log.warn("begin called twice without end; the previous frame is discarded", .{});
        }
        self.in_frame = true;
        self.input = input;
        self.list.reset();
        self.regions.reset(.init(viewport, .vertical, self.style.spacing, .root));
        self.seen.clearRetainingCapacity();
        self.duplicates = 0;
        self.next_hot = .none;
        self.pointer_blocked = false;
        self.states.sweep(input.frame);
    }

    /// Resolve what the frame described. After this the draw list is complete and the
    /// capture queries below are answerable.
    pub fn end(self: *Context) void {
        if (!self.in_frame) {
            log.warn("end called without begin", .{});
            return;
        }
        self.in_frame = false;

        if (self.list.clipDepth() != 0) {
            log.warn("frame ended with {d} clip rectangle(s) unpopped", .{self.list.clipDepth()});
        }
        if (self.regions.depth() != 0) {
            log.warn("frame ended with {d} region(s) unclosed", .{self.regions.depth()});
        }
        if (self.duplicates != 0) {
            log.warn("{d} widget id(s) were used more than once this frame", .{self.duplicates});
        }

        // A release no widget consumed ends the drag anyway. This has to happen *after* the
        // widgets have run, not before: clearing `active` in `begin` would eat the release
        // the widget was waiting for and no button would ever report a click. Without it, a
        // pointer released outside the window leaves a widget active forever and the next
        // click anywhere goes to it.
        if (self.input.pointerReleased()) self.active = .none;

        // A press that reached no widget takes the keyboard away from whatever had it.
        // Without this a text field goes on consuming typing after the user has clicked
        // somewhere else, which is the one focus rule a mouse-driven overlay needs — the
        // rest of focus handling is tab order, and `ui.md` §14 leaves that out of M6.
        if (self.input.pointerPressed() and self.next_hot.isNone()) self.focus = .none;

        // An active widget keeps the pointer even when it wanders off — that is what makes
        // a slider drag. Otherwise the topmost widget the pointer reached becomes hot.
        self.hot = if (self.active.isNone()) self.next_hot else self.active;
    }

    /// The whole interaction model, in one call that every widget makes.
    ///
    /// A widget passes the rectangle it has decided to occupy and is told what the user did
    /// to it. Nothing is drawn here: describing and interacting are separate so a widget can
    /// choose its appearance from the answer.
    pub fn interact(self: *Context, id: Id, bounds: Rect) Interaction {
        if (id.isNone()) return .{};
        if (!self.claim(id)) return .{ .duplicate = true };

        const inside = bounds.contains(self.input.pointer);
        if (inside) self.next_hot = id;

        var result: Interaction = .{ .hot = self.hot == id };

        if (self.active == id) {
            result.active = true;
            if (self.input.pointerReleased()) {
                result.clicked = inside;
                self.active = .none;
                result.active = false;
            }
        } else if (self.hot == id and self.active.isNone() and self.input.pointerPressed()) {
            self.active = id;
            self.focus = id;
            result.active = true;
            result.pressed = true;
        }

        return result;
    }

    /// True when a widget is hot or active, meaning **the game should not act on the
    /// pointer this frame**.
    ///
    /// Deliberately advisory. The kernel cannot filter the game's input without sitting
    /// between the game and `platform`, which would invert the layering and make the UI a
    /// mandatory part of every frame — the same rule `app-and-frame-loop.md` already applies
    /// to events, and for the same reason: what is obviously the overlay's click today is a
    /// game's binding tomorrow.
    /// Answered from the rectangles described **this** frame, not last frame's: `hot` has
    /// already been resolved by the time a caller asks, so a pointer arriving over a
    /// control is captured on the frame it arrives even though the control itself will not
    /// accept a press until the next one. Erring that way round is deliberate — a frame
    /// where neither the UI nor the game acts is a missed click; a frame where both act is
    /// a player who walked into a wall because they closed a panel.
    pub fn wantsPointer(self: *const Context) bool {
        return self.pointer_blocked or !self.hot.isNone() or !self.active.isNone();
    }

    /// True when a widget has keyboard focus and will consume typing.
    pub fn wantsKeyboard(self: *const Context) bool {
        return !self.focus.isNone();
    }

    pub fn isHot(self: *const Context, id: Id) bool {
        return self.hot == id and !id.isNone();
    }
    pub fn isActive(self: *const Context, id: Id) bool {
        return self.active == id and !id.isNone();
    }
    pub fn isFocused(self: *const Context, id: Id) bool {
        return self.focus == id and !id.isNone();
    }

    /// What the kernel remembers about `id`, created at its default the first time.
    ///
    /// **Never fails**, and the pointer is valid only until the next widget asks for one —
    /// widgets read it and write it inside a single call and never keep it. Anything a
    /// caller owns belongs with the caller instead; see `state.zig` for where that line is.
    pub fn stateOf(self: *Context, id: Id) *state_mod.State {
        return self.states.entry(self.gpa, id, self.input.frame);
    }

    /// Give up focus and any drag in progress. What a caller does when the overlay closes,
    /// or when the window loses focus and the release event will never arrive.
    pub fn clearInteraction(self: *Context) void {
        self.hot = .none;
        self.active = .none;
        self.focus = .none;
        self.next_hot = .none;
        self.pointer_blocked = false;
    }

    // -- layout ----------------------------------------------------------------------

    /// The region widgets are currently placing themselves in. Never null: the outermost
    /// one covers the viewport `begin` was given.
    pub fn region(self: *Context) *Region {
        return self.regions.current();
    }

    /// Reserve the next rectangle for a widget that wants to be `desired` big. The region's
    /// axis decides which component of `desired` is honoured and which is stretched, so one
    /// widget stacks in a panel and sits side by side in a row without knowing which.
    pub fn take(self: *Context, desired: Vec2) Rect {
        return self.regions.current().takeSize(desired);
    }

    /// Place widgets inside `bounds` until the matching `endRegion`. `seed` names the
    /// region for id purposes; `.none` keeps the enclosing seed.
    pub fn beginRegion(
        self: *Context,
        bounds: Rect,
        axis: layout.Axis,
        spacing: f32,
        seed: Id,
    ) Allocator.Error!void {
        const inherited = if (seed.isNone()) self.regions.seed() else seed;
        try self.regions.push(self.gpa, .init(bounds, axis, spacing, inherited));
    }

    /// False when there was no nested region to close — reported rather than asserted, and
    /// the outermost region survives it, so a caller that miscounted still gets a frame.
    pub fn endRegion(self: *Context) bool {
        if (!self.regions.pop()) {
            log.warn("endRegion without a matching beginRegion", .{});
            return false;
        }
        return true;
    }

    /// Ids seeded by the current region, so the same call inside two panels names two
    /// widgets. Display text is never a source of identity — see `id.zig`.
    pub fn childId(self: *const Context, name: []const u8) Id {
        return self.regions.seed().child(name);
    }

    pub fn childIndex(self: *const Context, index: usize) Id {
        return self.regions.seed().childIndex(index);
    }

    // -- clipping --------------------------------------------------------------------

    pub fn pushClip(self: *Context, bounds: Rect) Allocator.Error!void {
        try self.list.pushClip(self.gpa, bounds);
    }

    pub fn popClip(self: *Context) Allocator.Error!void {
        if (!try self.list.popClip(self.gpa)) {
            log.warn("popClip without a matching pushClip", .{});
        }
    }

    /// Take the pointer away from the game while it is inside `bounds`, without competing
    /// for `hot`. What a container does: a panel is not a widget and must not be one — if
    /// it claimed `hot` it would take the press meant for the control the pointer moved
    /// onto — but a click on its empty half still must not reach the world behind it.
    pub fn blockPointer(self: *Context, bounds: Rect) void {
        if (bounds.contains(self.input.pointer)) self.pointer_blocked = true;
    }

    /// False when this id has already been used this frame. Allocation failure is treated
    /// as "not a duplicate": losing collision *detection* under memory pressure is better
    /// than losing the widget.
    fn claim(self: *Context, id: Id) bool {
        const entry = self.seen.getOrPut(self.gpa, id) catch return true;
        if (entry.found_existing) {
            self.duplicates += 1;
            log.warn("widget id 0x{x:0>16} used more than once this frame", .{id.bits()});
            return false;
        }
        return true;
    }
};

const testing = std.testing;

fn testStyle() Style {
    return .{
        .font = .{ .cell = .init(8, 8) },
        .line_height = 20,
        .padding = .init(4, 4),
        .spacing = 2,
        .text = .white,
        .text_dim = .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1 },
        .surface = .black,
        .control = .{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1 },
        .control_hot = .{ .r = 0.3, .g = 0.3, .b = 0.3, .a = 1 },
        .control_active = .{ .r = 0.4, .g = 0.4, .b = 0.4, .a = 1 },
        .accent = .{ .r = 0.2, .g = 0.5, .b = 0.9, .a = 1 },
    };
}

const screen: Rect = .init(0, 0, 800, 600);

/// One widget occupying `bounds`, described for one frame of `input`.
fn step(ctx: *Context, id: Id, bounds: Rect, input: Input) Interaction {
    ctx.begin(input, screen);
    const result = ctx.interact(id, bounds);
    ctx.end();
    return result;
}

const box: Rect = .init(0, 0, 100, 20);
const over_it: core.math.Vec2 = .init(50, 10);
const off_it: core.math.Vec2 = .init(500, 500);

test "press inside and release inside is exactly one click" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const id = Id.root.child("ok");

    // Hovering first is not politeness, it is the model: `hot` resolves at the end of a
    // frame, so the frame that presses must be at least the second frame over the widget.
    _ = step(&ctx, id, box, .at(over_it, .up));
    try testing.expect(ctx.isHot(id));

    const pressed = step(&ctx, id, box, .at(over_it, .pressed));
    try testing.expect(pressed.pressed);
    try testing.expect(!pressed.clicked);

    const released = step(&ctx, id, box, .at(over_it, .released));
    try testing.expect(released.clicked);

    // And not again on the frame after.
    const after = step(&ctx, id, box, .at(over_it, .up));
    try testing.expect(!after.clicked);
}

test "press inside and release outside is not a click, then or later" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const id = Id.root.child("ok");

    _ = step(&ctx, id, box, .at(over_it, .up));
    _ = step(&ctx, id, box, .at(over_it, .pressed));

    const released = step(&ctx, id, box, .at(off_it, .released));
    try testing.expect(!released.clicked);

    const after = step(&ctx, id, box, .at(over_it, .up));
    try testing.expect(!after.clicked);
}

test "a drag may leave the widget and come back" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const id = Id.root.child("slider");

    _ = step(&ctx, id, box, .at(over_it, .up));
    _ = step(&ctx, id, box, .at(over_it, .pressed));

    // Off the widget and still held: active, which is what makes a slider keep tracking.
    const away = step(&ctx, id, box, .at(off_it, .held));
    try testing.expect(away.active);
    try testing.expect(ctx.isActive(id));

    const back = step(&ctx, id, box, .at(over_it, .released));
    try testing.expect(back.clicked);
}

test "the topmost widget wins the pointer, whatever order it was described in" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const under = Id.root.child("under");
    const over = Id.root.child("over");

    // Both cover the pointer. `over` is described second, so it is painted on top.
    ctx.begin(.at(over_it, .up), screen);
    _ = ctx.interact(under, box);
    _ = ctx.interact(over, box);
    ctx.end();

    try testing.expect(ctx.isHot(over));
    try testing.expect(!ctx.isHot(under));

    // And the click goes to the one on top, not to the one described first.
    ctx.begin(.at(over_it, .pressed), screen);
    const under_result = ctx.interact(under, box);
    const over_result = ctx.interact(over, box);
    ctx.end();
    try testing.expect(!under_result.pressed);
    try testing.expect(over_result.pressed);
}

test "identity survives the label changing every frame" {
    // The localisation case from `ui.md` §3, asserted rather than hoped for: a widget's id
    // is not derived from what it displays, so translating the UI mid-drag changes nothing.
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const id = Id.root.child("confirm");

    _ = step(&ctx, id, box, .at(over_it, .up));
    _ = step(&ctx, id, box, .at(over_it, .pressed));
    try testing.expect(ctx.isActive(id));

    // The language changes. Nothing about identity does.
    for ([_][]const u8{ "Confirmer", "Bestatigen", "確認" }) |_| {
        const held = step(&ctx, id, box, .at(over_it, .held));
        try testing.expect(held.active);
    }

    const released = step(&ctx, id, box, .at(over_it, .released));
    try testing.expect(released.clicked);
}

test "a duplicate id is reported and inert, and the first widget still works" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const id = Id.root.child("twice");

    _ = step(&ctx, id, box, .at(over_it, .up));

    ctx.begin(.at(over_it, .pressed), screen);
    const first = ctx.interact(id, box);
    const second = ctx.interact(id, box);
    ctx.end();

    try testing.expect(first.pressed);
    try testing.expect(second.duplicate);
    try testing.expect(!second.pressed);
    try testing.expectEqual(@as(u32, 1), ctx.duplicates);
}

test "capture is true over a control and false over empty space" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const id = Id.root.child("ok");

    _ = step(&ctx, id, box, .at(off_it, .up));
    try testing.expect(!ctx.wantsPointer());

    _ = step(&ctx, id, box, .at(over_it, .up));
    try testing.expect(ctx.wantsPointer());

    // A drag keeps the pointer even once it has left the widget, because releasing there
    // must not be delivered to the game as a click on the world.
    _ = step(&ctx, id, box, .at(over_it, .pressed));
    _ = step(&ctx, id, box, .at(off_it, .held));
    try testing.expect(ctx.wantsPointer());
}

test "keyboard capture follows focus, and a press takes it" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const id = Id.root.child("field");

    try testing.expect(!ctx.wantsKeyboard());

    _ = step(&ctx, id, box, .at(over_it, .up));
    _ = step(&ctx, id, box, .at(over_it, .pressed));
    try testing.expect(ctx.isFocused(id));
    try testing.expect(ctx.wantsKeyboard());

    ctx.clearInteraction();
    try testing.expect(!ctx.wantsKeyboard());
}

test "a release the UI never saw does not strand an active widget" {
    // The window loses focus mid-drag and the release goes somewhere else. The next frame
    // that reports a release — anywhere — ends it.
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const id = Id.root.child("ok");

    _ = step(&ctx, id, box, .at(over_it, .up));
    _ = step(&ctx, id, box, .at(over_it, .pressed));
    try testing.expect(ctx.isActive(id));

    // Frames where the widget is not described at all.
    ctx.begin(.at(off_it, .held), screen);
    ctx.end();
    ctx.begin(.at(off_it, .released), screen);
    ctx.end();

    try testing.expect(!ctx.isActive(id));
    try testing.expect(ctx.active.isNone());
}

test "a widget with no id does nothing at all" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const result = step(&ctx, .none, box, .at(over_it, .pressed));
    try testing.expect(!result.pressed);
    try testing.expect(!result.duplicate);
    try testing.expect(ctx.hot.isNone());
}

test "a widget described with nothing open lands in the viewport" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();

    ctx.begin(.at(off_it, .up), screen);
    // No panel, no row: the outermost region is the viewport, so this is a full-width row
    // at the top of the screen. There is deliberately no way to have no region at all.
    try testing.expectEqual(Rect.init(0, 0, 800, 20), ctx.take(.init(0, 20)));
    ctx.end();
}

test "regions nest, unwind, and survive being closed too often" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();

    ctx.begin(.at(off_it, .up), screen);
    try ctx.beginRegion(.init(10, 10, 100, 100), .horizontal, 0, ctx.childId("inner"));
    try testing.expectEqual(@as(u32, 1), ctx.regions.depth());
    try testing.expectEqual(Rect.init(10, 10, 20, 100), ctx.take(.init(20, 20)));

    try testing.expect(ctx.endRegion());
    // One too many: reported, and the viewport region is still there to place widgets in.
    try testing.expect(!ctx.endRegion());
    try testing.expectEqual(Rect.init(0, 0, 800, 20), ctx.take(.init(0, 20)));
    ctx.end();
}

test "ids are seeded by the region they are asked for in" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();

    ctx.begin(.at(off_it, .up), screen);
    const outer = ctx.childId("save");

    try ctx.beginRegion(screen, .vertical, 0, Id.root.child("panel_a"));
    const in_a = ctx.childId("save");
    _ = ctx.endRegion();

    try ctx.beginRegion(screen, .vertical, 0, Id.root.child("panel_b"));
    const in_b = ctx.childId("save");
    _ = ctx.endRegion();
    ctx.end();

    // The same call in two panels names two widgets, which is what makes a panel reusable.
    try testing.expect(in_a != in_b);
    try testing.expect(in_a != outer);
    // And an empty seed inherits rather than resetting to the root.
    ctx.begin(.at(off_it, .up), screen);
    try ctx.beginRegion(screen, .vertical, 0, Id.root.child("panel_a"));
    try ctx.beginRegion(screen, .vertical, 0, .none);
    try testing.expectEqual(in_a, ctx.childId("save"));
    _ = ctx.endRegion();
    _ = ctx.endRegion();
    ctx.end();
}

test "capture is answered from this frame's rectangles, not last frame's" {
    // `ui.md` §11: capture must be right "on the frame it matters and not one frame late".
    // `hot` is resolved in `end`, which runs before a caller asks, so the very first frame
    // the pointer is over a control the game is already told to keep off it — even though
    // the control itself will not accept a press until the frame after.
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const id = Id.root.child("ok");

    _ = step(&ctx, id, box, .at(off_it, .up));
    try testing.expect(!ctx.wantsPointer());

    _ = step(&ctx, id, box, .at(over_it, .up));
    try testing.expect(ctx.wantsPointer());
}

test "clipping is a draw concern and leaves layout alone" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();

    ctx.begin(.at(off_it, .up), screen);
    try ctx.pushClip(.init(0, 0, 10, 10));
    // The clip does not shrink the region: the row is still the viewport's full width.
    try testing.expectEqual(Rect.init(0, 0, 800, 20), ctx.take(.init(0, 20)));
    try ctx.popClip();
    ctx.end();

    try testing.expectEqual(@as(u32, 0), ctx.list.clipDepth());
}
