//! `TickView`: input as a fixed step sees it (`docs/design/input.md` §7).
//!
//! A frame's snapshot is seen by every step in that frame and by none when a frame runs no
//! step, so edges and deltas read per step would be counted by the frame rate. The tick view
//! generalises the court's `Pending`:
//! - edges and deltas accumulate across frames until a step takes them;
//! - **the first step after they happened sees them, and later steps in that frame see held
//!   state only**;
//! - the same is done for the raw snapshot, for the table.
//!
//! A press is therefore seen by exactly one tick, whatever the frame rate. Which tick still
//! depends on when it happened; a replay records what each tick saw.
//!
//! **What accumulates.** A button's pressed and released are kept until taken, so a press and a
//! release in two frames with no step between reach the next step together, with `held` false.
//! A level (a button's held, an axis, a vector) is the latest frame's. A delta's value is summed
//! across the frames and is held when any of them was; once taken it is zero and not held. In
//! the snapshot, key and button edges are kept the same way, motion and wheel summed, and every
//! position, held set and pad axis is the latest. Motion in one unit is dropped when motion in
//! another arrives, the snapshot's own rule. A pad slot whose handle changes starts its edges
//! again from the new pad: an edge belongs to the pad that made it.
//!
//! A frame whose map changed (a reload, a rebinding) is matched by content ID: an action that
//! survives keeps what it had pending, and one that went loses it.

const std = @import("std");
const core = @import("core");
const platform = @import("platform");
const actions_mod = @import("actions.zig");

const InputSnapshot = platform.InputSnapshot;
const Frame = actions_mod.Frame;
const ActionState = actions_mod.ActionState;

/// What one step sees, borrowed until the next `take`.
pub const Tick = struct {
    actions: *const Frame,
    input: *const InputSnapshot,
};

pub const TickView = struct {
    pending: Frame = .empty,
    pending_input: InputSnapshot = .{},
    taken: Frame = .empty,
    taken_input: InputSnapshot = .{},

    pub const empty: TickView = .{};

    /// Adds one frame's evaluation and its snapshot. Called once a frame, whether or not the
    /// frame runs a step.
    pub fn feed(self: *TickView, frame: *const Frame, snapshot: *const InputSnapshot) void {
        self.feedActions(frame);
        self.feedInput(snapshot);
    }

    fn feedActions(self: *TickView, frame: *const Frame) void {
        const old = &self.pending;
        var merged: Frame = .{ .count = frame.count };
        // Both are in content-ID order: one walk matches them.
        var j: usize = 0;
        for (0..frame.count) |i| {
            const id = frame.ids[i];
            merged.ids[i] = id;
            merged.kinds[i] = frame.kinds[i];
            const now = frame.states[i];
            while (j < old.count and old.ids[j].hash < id.hash) j += 1;
            const before: ?ActionState = if (j < old.count and old.ids[j].eql(id) and old.kinds[j] == frame.kinds[i]) old.states[j] else null;
            merged.states[i] = if (before) |b| combine(b, now, frame.kinds[i]) else now;
        }
        self.pending = merged;
    }

    fn feedInput(self: *TickView, s: *const InputSnapshot) void {
        const p = &self.pending_input;
        var next = s.*;
        next.keys_pressed.setUnion(p.keys_pressed);
        next.keys_released.setUnion(p.keys_released);
        next.mouse.buttons_pressed.setUnion(p.mouse.buttons_pressed);
        next.mouse.buttons_released.setUnion(p.mouse.buttons_released);
        if (p.mouse.motion_unit == s.mouse.motion_unit) next.mouse.motion = p.mouse.motion.add(s.mouse.motion);
        next.mouse.wheel = p.mouse.wheel.add(s.mouse.wheel);
        for (&next.gamepads, p.gamepads) |*pad, before| {
            if (!pad.handle.eql(before.handle)) continue;
            pad.buttons_pressed.setUnion(before.buttons_pressed);
            pad.buttons_released.setUnion(before.buttons_released);
        }
        p.* = next;
    }

    /// What the next step sees. Edges and deltas are handed over once; a second step in the same
    /// frame sees held state only.
    pub fn take(self: *TickView) Tick {
        self.taken = self.pending;
        self.taken_input = self.pending_input;
        for (self.pending.states[0..self.pending.count], self.pending.kinds[0..self.pending.count]) |*s, kind| {
            s.pressed = false;
            s.released = false;
            if (kind == .delta) s.* = .rest;
        }
        const p = &self.pending_input;
        p.keys_pressed = platform.key.empty_keys;
        p.keys_released = platform.key.empty_keys;
        p.mouse.buttons_pressed = platform.key.empty_buttons;
        p.mouse.buttons_released = platform.key.empty_buttons;
        p.mouse.motion = .zero;
        p.mouse.wheel = .zero;
        for (&p.gamepads) |*pad| {
            pad.buttons_pressed = platform.gamepad.empty_buttons;
            pad.buttons_released = platform.gamepad.empty_buttons;
        }
        return .{ .actions = &self.taken, .input = &self.taken_input };
    }
};

fn combine(before: ActionState, now: ActionState, kind: @import("schemas.zig").Kind) ActionState {
    var out = now;
    out.pressed = before.pressed or now.pressed;
    out.released = before.released or now.released;
    if (kind == .delta) {
        out.value = before.value.add(now.value);
        out.held = before.held or now.held;
    }
    return out;
}
