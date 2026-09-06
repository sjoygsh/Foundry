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
const Id = @import("id.zig").Id;
const Input = @import("input.zig").Input;
const draw = @import("draw.zig");
const style_mod = @import("style.zig");
const Style = style_mod.Style;

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

    in_frame: bool = false,

    pub fn init(gpa: Allocator, style: Style) Context {
        return .{ .gpa = gpa, .style = style };
    }

    pub fn deinit(self: *Context) void {
        self.list.deinit(self.gpa);
        self.seen.deinit(self.gpa);
        self.* = undefined;
    }

    /// Adopt this frame's input and clear last frame's description.
    pub fn begin(self: *Context, input: Input) void {
        if (self.in_frame) {
            // Reported, not asserted: a caller that lost track of its frames still gets a
            // working UI, and the message says which rule was broken.
            log.warn("begin called twice without end; the previous frame is discarded", .{});
        }
        self.in_frame = true;
        self.input = input;
        self.list.reset();
        self.seen.clearRetainingCapacity();
        self.duplicates = 0;
        self.next_hot = .none;
    }

    /// Resolve what the frame described. After this the draw list is complete and the
    /// capture queries below are answerable.
    pub fn end(self: *Context) void {
        if (!self.in_frame) {
            log.warn("end called without begin", .{});
            return;
        }
        self.in_frame = false;

        if (self.list.clip_depth != 0) {
            log.warn("frame ended with {d} clip rectangle(s) unpopped", .{self.list.clip_depth});
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
    pub fn wantsPointer(self: *const Context) bool {
        return !self.hot.isNone() or !self.active.isNone();
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

    /// Give up focus and any drag in progress. What a caller does when the overlay closes,
    /// or when the window loses focus and the release event will never arrive.
    pub fn clearInteraction(self: *Context) void {
        self.hot = .none;
        self.active = .none;
        self.focus = .none;
        self.next_hot = .none;
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

/// One widget occupying `bounds`, described for one frame of `input`.
fn step(ctx: *Context, id: Id, bounds: Rect, input: Input) Interaction {
    ctx.begin(input);
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
    ctx.begin(.at(over_it, .up));
    _ = ctx.interact(under, box);
    _ = ctx.interact(over, box);
    ctx.end();

    try testing.expect(ctx.isHot(over));
    try testing.expect(!ctx.isHot(under));

    // And the click goes to the one on top, not to the one described first.
    ctx.begin(.at(over_it, .pressed));
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

    ctx.begin(.at(over_it, .pressed));
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
    ctx.begin(.at(off_it, .held));
    ctx.end();
    ctx.begin(.at(off_it, .released));
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
