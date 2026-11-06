//! Playback as a value (`animation-logic.md` §3, ADR-0071).
//!
//! A player is a few fixed channels and reads no clock. A game ticks it, directly or through
//! `foundry:animator`, and asks for a pose. **A pose is never state:** it is a function of a player
//! and a rig, which is why a saved world holds no pose.
//!
//! **Time is `anchor + ticks × dt × rate`, in `f64`,** folded in `f64` and cast to `f32` only to
//! sample. It is never accumulated, and a saved value keeps tick resolution after days of running.
//!
//! **A speed may be negative** (`animation-states.md` §3): the clip plays backward, its events fire
//! on the mirrored span and its travel reverses. **Clips of one sync group are kept at one fraction**
//! (§4), the newest leading.
//!
//! **Everything a player holds is untrusted.** It may have come from a save or a raw component
//! write, and a clip it names may be gone after a reload. So neither `advance` nor `evaluate`
//! asserts on it: `advance` empties what it cannot use and counts it.

const std = @import("std");

const core = @import("core");

const motion_mod = @import("motion.zig");
const pose_mod = @import("pose.zig");
const rig_mod = @import("rig.zig");

const ContentId = core.ContentId;
const Motion = motion_mod.Motion;
const Pose = pose_mod.Pose;
const Rig = rig_mod.Rig;
const RigClip = rig_mod.RigClip;

/// A cross-fade can be interrupted, so two are not enough. More is a schema version of
/// `foundry:animator`.
pub const max_channels = 4;

/// The fastest a channel, or a clip's authored rate, may run, either way.
pub const max_speed: f32 = 16;

/// The most events a tick reports. More are counted in `Step.dropped`.
pub const max_step_events = 16;

/// The most laps of one clip a tick looks through for events. A tick is a sixtieth of a second, so
/// this is only reached by a clip a hostile package made very short.
const max_event_laps = 64;

/// `extern`, since `foundry:animator` lays its fields over this exactly (ADR-0071).
pub const Channel = extern struct {
    /// `rig.clipName` of the clip; zero is an empty channel.
    clip: u64 = 0,
    /// Seconds into the clip at `ticks == 0`, unfolded. Below zero for a loop played backward.
    anchor: f64 = 0,
    /// Ticks since the anchor.
    ticks: u64 = 0,
    /// Zero holds, and below zero plays backward; at most `max_speed` either way.
    speed: f32 = 0,
    /// 0 to 1. The live channels sum to 1.
    weight: f32 = 0,
};

pub const Phase = enum {
    /// From the clip's start, or from its end for a one-shot played backward.
    restart,
    /// Keeps the clip's own time if it is still playing, and otherwise takes the newest clip's: its
    /// fraction, when both clips are of one sync group, and its seconds otherwise.
    keep,
};

pub const PlayOptions = struct {
    /// Seconds to reach full weight; zero cuts.
    fade: f32 = 0,
    phase: Phase = .restart,
    speed: f32 = 1,
};

pub const PlayError = error{ UnknownClip, InvalidFade, InvalidSpeed };

/// What one tick did. A fixed value, reset by `advance` and `seek`.
pub const Step = struct {
    /// Channels emptied because they could not be used: a clip the rig no longer has, or values
    /// out of range.
    lost: u32 = 0,
    /// In time order, `event_count` of them.
    events: [max_step_events]ContentId = undefined,
    event_count: u32 = 0,
    /// Events that did not fit.
    dropped: u32 = 0,
    /// The body's move this tick, for the game to carry out (`motion.zig`).
    motion: Motion = .{},

    pub fn fired(step: *const Step) []const ContentId {
        return step.events[0..step.event_count];
    }

    fn emit(step: *Step, id: ContentId) void {
        if (step.event_count < max_step_events) {
            step.events[step.event_count] = id;
            step.event_count += 1;
        } else {
            step.dropped +|= 1;
        }
    }
};

pub const Player = extern struct {
    channels: [max_channels]Channel = @splat(.{}),
    /// Seconds a fade to the newest channel takes.
    fade: f32 = 0,
    /// Which channel the rest are fading away from.
    newest: u32 = 0,
    /// The step size `ticks` counts in, set by `advance`, so that `evaluate` needs no `dt`.
    dt: f32 = 0,

    /// Makes `name` the newest clip. A clip still playing is taken up where it is, so a walker
    /// that stops and starts mid-fade reverses smoothly. With every channel in use, the lightest
    /// is replaced. A refusal changes nothing.
    pub fn play(self: *Player, rig: Rig, name: u64, options: PlayOptions) PlayError!void {
        if (rig.find(name) == null) return error.UnknownClip;
        if (!std.math.isFinite(options.fade) or options.fade < 0) return error.InvalidFade;
        if (!validSpeed(options.speed)) return error.InvalidSpeed;

        const entry = rig.find(name).?;
        const kept = self.keptFor(rig, entry);
        const begin_at = beginning(entry, options.speed);
        var slot = self.slotOf(name);
        if (slot == null) {
            slot = self.freeSlot();
            const fresh = &self.channels[slot.?];
            fresh.* = .{ .clip = name, .speed = options.speed, .anchor = if (options.phase == .keep) kept else begin_at };
        } else if (options.phase == .restart) {
            const channel = &self.channels[slot.?];
            channel.anchor = begin_at;
            channel.ticks = 0;
            channel.speed = options.speed;
        }

        self.newest = @intCast(slot.?);
        self.fade = options.fade;
        if (options.fade == 0 or self.liveCount() == 1) self.cut();
    }

    /// The newest channel's speed. It re-anchors, so a change of speed never moves the pose.
    pub fn setSpeed(self: *Player, rig: Rig, speed: f32) PlayError!void {
        if (!validSpeed(speed)) return error.InvalidSpeed;
        if (self.newest >= max_channels) return;
        const channel = &self.channels[self.newest];
        if (channel.clip == 0 or channel.speed == speed) return;
        channel.anchor = self.time(rig, self.newest);
        channel.ticks = 0;
        channel.speed = speed;
    }

    /// One tick. `dt` is the caller's fixed step.
    pub fn advance(self: *Player, rig: Rig, dt: f32, step: *Step) void {
        const before = self.begin(rig, dt, step);
        for (&self.channels) |*channel| {
            if (channel.clip != 0) channel.ticks += 1;
        }
        self.finish(rig, dt, before, step, false);
    }

    /// One tick in which the newest channel goes to `fraction` of its clip rather than running
    /// there, as a link's crossing does. What it crosses going forward fires and travels as if
    /// played; going backward nothing fires, which is what a restart needs. The other channels
    /// run on, and a fade carries on.
    pub fn seek(self: *Player, rig: Rig, fraction: f32, dt: f32, step: *Step) void {
        self.seekLaps(rig, fraction, 1, dt, step);
    }

    /// `seek` across `laps` laps of a looping clip, as if they were one lap `laps` times as long:
    /// `fraction` 0.5 of three laps is halfway through the second (`animation-states.md` §5). What
    /// every lap crossed carries fires. A one-shot has one lap, and a count below 1 is 1.
    pub fn seekLaps(self: *Player, rig: Rig, fraction: f32, laps: u32, dt: f32, step: *Step) void {
        const before = self.begin(rig, dt, step);
        const newest = self.newest;
        for (&self.channels) |*channel| {
            if (channel.clip != 0) channel.ticks += 1;
        }
        // `begin` left the newest channel usable.
        const entry = rig.find(self.channels[newest].clip).?;
        const count: f64 = if (entry.loop) @floatFromInt(@max(laps, 1)) else 1;
        const span: f64 = @as(f64, entry.clip.duration) * count;
        // Written so a NaN is 0.
        const to: f64 = if (!(fraction > 0)) 0 else @min(fraction, 1);
        const lap = if (entry.loop) @floor(before[newest] / span) else 0;
        self.channels[newest].anchor = (lap + to) * span;
        self.channels[newest].ticks = 0;
        self.finish(rig, dt, before, step, true);
    }

    /// What a tick starts with: a player safe to use at this step, and each channel's time.
    fn begin(self: *Player, rig: Rig, dt: f32, step: *Step) [max_channels]f64 {
        step.* = .{};
        self.repair(rig, step);
        if (self.dt != dt) {
            // Ticks counted in the old step are worth what they were worth then.
            for (0..max_channels) |i| {
                const channel = &self.channels[i];
                if (channel.clip == 0 or channel.ticks == 0) continue;
                channel.anchor = self.time(rig, i);
                channel.ticks = 0;
            }
            self.dt = dt;
        }
        var before: [max_channels]f64 = undefined;
        for (0..max_channels) |i| before[i] = self.time(rig, i);
        return before;
    }

    /// `seeking` is a seek's rule: what the newest channel and its followers cross backward is a
    /// restart, so it neither fires nor travels.
    fn finish(self: *Player, rig: Rig, dt: f32, before: [max_channels]f64, step: *Step, seeking: bool) void {
        self.follow(rig, before);
        // Only the newest fires: a clip fading out is on its way to being gone.
        const entry = rig.find(self.channels[self.newest].clip).?;
        const newest_after = self.time(rig, self.newest);
        if (!seeking or newest_after > before[self.newest]) fire(step, entry, before[self.newest], newest_after);

        self.moveWeights(dt);

        var total: f32 = 0;
        for (self.channels) |channel| {
            if (channel.clip != 0) total += channel.weight;
        }
        if (total <= 0) return;
        for (self.channels, 0..) |channel, i| {
            if (channel.clip == 0) continue;
            const live = rig.find(channel.clip).?;
            if (!live.motion) continue;
            // A clip with no motion adds nothing but its weight, so a walk fading to idle slows.
            const share = channel.weight / total;
            const after = self.time(rig, i);
            if (seeking and after < before[i] and (i == self.newest or self.follows(live, entry))) continue;
            const travel = motion_mod.travel(rig, live, before[i], after);
            step.motion.translation = step.motion.translation.add(travel.translation.scale(share));
            step.motion.yaw += travel.yaw * share;
        }
    }

    /// The blended pose. With no channel it can use, the rig's start clip at its first frame.
    /// `scratch` is one pose the caller lends, and `out` may be followed by `skinMatrices`.
    pub fn evaluate(self: *const Player, rig: Rig, scratch: Pose, out: Pose) void {
        var total: f32 = 0;
        for (0..max_channels) |i| {
            const channel = self.channels[i];
            const entry = self.usable(rig, channel) orelse continue;
            if (channel.weight <= 0) continue;
            const at = fold(self.time(rig, i), entry);
            const into = if (total == 0) out else scratch;
            pose_mod.sample(rig.skeleton, entry.clip, at, into);
            if (entry.motion) motion_mod.hold(rig, entry, into);
            if (total != 0) pose_mod.blend(out, scratch, channel.weight / (total + channel.weight), out);
            total += channel.weight;
        }
        // `validate` guarantees the start clip.
        if (total == 0) pose_mod.sample(rig.skeleton, rig.find(rig.start).?.clip, 0, out);
    }

    /// Whether the newest clip is one-shot and at its end: its last frame going forward, its first
    /// going backward. A looping clip never is.
    pub fn finished(self: *const Player, rig: Rig) bool {
        if (self.newest >= max_channels) return false;
        const channel = self.channels[self.newest];
        const entry = self.usable(rig, channel) orelse return false;
        if (entry.loop) return false;
        const at = self.time(rig, self.newest);
        return if (channel.speed < 0) at <= 0 else at >= entry.clip.duration;
    }

    /// Whether `name` is the newest clip.
    pub fn playing(self: *const Player, name: u64) bool {
        return self.newest < max_channels and self.channels[self.newest].clip == name;
    }

    /// Whether every value is in range. What a deserializer refuses a save for, since `advance`
    /// would only repair it a tick later. It says nothing of clips, which belong to a rig.
    pub fn sane(self: *const Player) bool {
        if (!std.math.isFinite(self.fade) or self.fade < 0) return false;
        if (self.newest >= max_channels or !validStep(self.dt)) return false;
        for (self.channels) |channel| {
            if (channel.clip != 0 and !saneChannel(channel)) return false;
        }
        return true;
    }

    /// A channel's time within its clip, in seconds, as the pose shows it.
    pub fn seconds(self: *const Player, rig: Rig, index: usize) f32 {
        const entry = self.usable(rig, self.channels[index]) orelse return 0;
        return fold(self.time(rig, index), entry);
    }

    /// A channel's unfolded time, in seconds.
    fn time(self: *const Player, rig: Rig, index: usize) f64 {
        if (index >= max_channels) return 0;
        const channel = self.channels[index];
        const entry = self.usable(rig, channel) orelse return 0;
        const dt: f64 = if (validStep(self.dt)) self.dt else 0;
        const rate = @as(f64, channel.speed) * @as(f64, entry.speed);
        return channel.anchor + @as(f64, @floatFromInt(channel.ticks)) * dt * rate;
    }

    /// Where a clip asked for with `.keep` begins: the newest channel's fraction if both are of one
    /// sync group, and its seconds otherwise.
    fn keptFor(self: *const Player, rig: Rig, entry: *const RigClip) f64 {
        const kept = self.time(rig, self.newest);
        if (entry.sync == 0 or self.newest >= max_channels) return kept;
        const current = self.usable(rig, self.channels[self.newest]) orelse return kept;
        if (current.sync != entry.sync) return kept;
        return lapFraction(kept, current.clip.duration) * entry.clip.duration;
    }

    /// Whether `entry` follows the newest clip, `leader`: both are of one sync group.
    fn follows(self: *const Player, entry: *const RigClip, leader: *const RigClip) bool {
        _ = self;
        return leader.sync != 0 and entry != leader and entry.sync == leader.sync;
    }

    /// Puts every follower of the newest clip at its fraction (`animation-states.md` §4). A follower
    /// moves as many laps as the leader did, so its travel is its own, plus whatever it was out of
    /// step by, taken the short way round, so a follower that ran ahead steps back rather than
    /// lapping.
    fn follow(self: *Player, rig: Rig, before: [max_channels]f64) void {
        const leader = rig.find(self.channels[self.newest].clip).?;
        if (leader.sync == 0) return;
        const lead_length: f64 = leader.clip.duration;
        const lead_before = before[self.newest];
        const lead_after = self.time(rig, self.newest);
        const target = lapFraction(lead_after, lead_length);
        const moved = (lead_after - lead_before) / lead_length;
        for (&self.channels, 0..) |*channel, i| {
            if (i == self.newest or channel.clip == 0) continue;
            const entry = rig.find(channel.clip) orelse continue;
            if (!self.follows(entry, leader)) continue;
            const length: f64 = entry.clip.duration;
            // How far short of the leader's fraction moving as far as it did would leave this one.
            const short = target - lapFraction(before[i], length) - moved;
            const correction = short - @round(short);
            channel.anchor = before[i] + (moved + correction) * length;
            channel.ticks = 0;
        }
    }

    fn usable(self: *const Player, rig: Rig, channel: Channel) ?*const RigClip {
        _ = self;
        if (channel.clip == 0 or !saneChannel(channel)) return null;
        return rig.find(channel.clip);
    }

    fn slotOf(self: *const Player, name: u64) ?usize {
        for (self.channels, 0..) |channel, i| {
            if (channel.clip == name) return i;
        }
        return null;
    }

    fn freeSlot(self: *const Player) usize {
        var lightest: usize = 0;
        for (self.channels, 0..) |channel, i| {
            if (channel.clip == 0) return i;
            if (channel.weight < self.channels[lightest].weight) lightest = i;
        }
        return lightest;
    }

    fn liveCount(self: *const Player) usize {
        var count: usize = 0;
        for (self.channels) |channel| {
            if (channel.clip != 0) count += 1;
        }
        return count;
    }

    /// The newest channel alone, at full weight.
    fn cut(self: *Player) void {
        for (&self.channels, 0..) |*channel, i| {
            if (i == self.newest) channel.weight = 1 else channel.* = .{};
        }
    }

    /// Makes a player safe to tick: whatever a save or a raw write left it holding. Anything it
    /// cannot use is emptied and counted, and a player left with nothing begins the start clip.
    fn repair(self: *Player, rig: Rig, step: *Step) void {
        if (!std.math.isFinite(self.fade) or self.fade < 0) self.fade = 0;
        for (&self.channels) |*channel| {
            if (channel.clip == 0) continue;
            if (self.usable(rig, channel.*) == null) {
                channel.* = .{};
                step.lost += 1;
            }
        }
        if (self.newest < max_channels and self.channels[self.newest].clip != 0) return;
        var heaviest: ?usize = null;
        for (self.channels, 0..) |channel, i| {
            if (channel.clip == 0) continue;
            if (heaviest == null or channel.weight > self.channels[heaviest.?].weight) heaviest = i;
        }
        if (heaviest) |i| {
            self.newest = @intCast(i);
        } else {
            self.newest = 0;
            self.channels[0] = .{ .clip = rig.start, .speed = 1, .weight = 1 };
        }
    }

    /// Moves the newest toward 1, and shares what is left among the rest in proportion, so the
    /// weights keep summing to 1 even when a fade is interrupted.
    fn moveWeights(self: *Player, dt: f32) void {
        const newest = &self.channels[self.newest];
        const by: f32 = if (self.fade > 0) dt / self.fade else 1;
        newest.weight = @min(1, newest.weight + by);

        var others: f32 = 0;
        for (self.channels, 0..) |channel, i| {
            if (channel.clip != 0 and i != self.newest) others += channel.weight;
        }
        if (newest.weight >= 1 or others <= 0) {
            self.cut();
            return;
        }
        const scale = (1 - newest.weight) / others;
        for (&self.channels, 0..) |*channel, i| {
            if (channel.clip != 0 and i != self.newest) channel.weight *= scale;
        }
    }
};

/// Fires what lies on `[from, to)`, by unfolded time, so that one tick's end is exactly the next
/// one's start and nothing fires twice or not at all. A one-shot's end closes the span. Time running
/// backward fires the mirror, `(to, from]`, latest first (`animation-states.md` §3).
fn fire(step: *Step, entry: *const RigClip, from: f64, to: f64) void {
    if (entry.events.len == 0) return;
    if (to < from) return fireBackward(step, entry, from, to);
    if (!(to > from)) return;
    const duration: f64 = entry.clip.duration;
    if (!entry.loop) {
        if (from >= duration) return;
        for (entry.events) |event| {
            const at = @as(f64, event.at) * duration;
            if (at < from) continue;
            if (at < to or (event.at == 1 and to >= duration)) step.emit(event.id);
        }
        return;
    }
    var lap = @floor(from / duration);
    var laps: u32 = 0;
    while (lap * duration < to) : (laps += 1) {
        if (laps == max_event_laps or step.event_count == max_step_events) {
            countLeft(step, entry, (to - lap * duration) / duration);
            return;
        }
        for (entry.events) |event| {
            const at = (lap + event.at) * duration;
            if (at < from) continue;
            if (at >= to) return;
            step.emit(event.id);
        }
        lap += 1;
    }
}

/// `fire` for time running backward: `(to, from]`. A one-shot's start closes the span, as its end
/// does going forward, so a clip played back to its first frame fires what lies at 0.
fn fireBackward(step: *Step, entry: *const RigClip, from: f64, to: f64) void {
    const duration: f64 = entry.clip.duration;
    if (!entry.loop) {
        if (from <= 0) return;
        var i = entry.events.len;
        while (i > 0) {
            i -= 1;
            const event = entry.events[i];
            const at = @as(f64, event.at) * duration;
            if (at > from) continue;
            if (at > to or (event.at == 0 and to <= 0)) step.emit(event.id);
        }
        return;
    }
    // The lap `from` is in; an event on `from` itself is in the span.
    var lap = @floor(from / duration);
    var laps: u32 = 0;
    while ((lap + 1) * duration > to) : (laps += 1) {
        if (laps == max_event_laps or step.event_count == max_step_events) {
            countLeft(step, entry, ((lap + 1) * duration - to) / duration);
            return;
        }
        var i = entry.events.len;
        while (i > 0) {
            i -= 1;
            const at = (lap + entry.events[i].at) * duration;
            if (at > from) continue;
            if (at <= to) return;
            step.emit(entry.events[i].id);
        }
        lap -= 1;
    }
}

/// Nothing can come of looking further, so count what is left and stop. The count is of whole
/// laps, since it is a warning and not a measure.
fn countLeft(step: *Step, entry: *const RigClip, laps_left: f64) void {
    const left = @min(laps_left * @as(f64, @floatFromInt(entry.events.len)), std.math.maxInt(u32));
    step.dropped +|= @intFromFloat(left);
}

/// A channel's time within its clip: wrapped if it loops, held at either end if not.
fn fold(time: f64, entry: *const RigClip) f32 {
    const duration: f64 = entry.clip.duration;
    if (!entry.loop) return @floatCast(std.math.clamp(time, 0, duration));
    const folded: f32 = @floatCast(@mod(time, duration));
    // Rounding to `f32` can reach the duration itself, which is the start of the loop.
    return if (folded >= entry.clip.duration) 0 else folded;
}

/// How far into its lap `time` is, from 0 up to but not including 1, in `f64`.
fn lapFraction(time: f64, duration: f64) f64 {
    const fraction = @mod(time, duration) / duration;
    return if (fraction >= 1) 0 else fraction;
}

/// Where `.restart` puts a clip: its start, or the end of a one-shot played backward.
fn beginning(entry: *const RigClip, speed: f32) f64 {
    return if (!entry.loop and speed < 0) entry.clip.duration else 0;
}

fn validSpeed(speed: f32) bool {
    return std.math.isFinite(speed) and @abs(speed) <= max_speed;
}

fn validStep(dt: f32) bool {
    return std.math.isFinite(dt) and dt >= 0;
}

/// Written so a NaN fails every comparison.
fn saneChannel(channel: Channel) bool {
    return std.math.isFinite(channel.anchor) and
        validSpeed(channel.speed) and
        channel.weight >= 0 and channel.weight <= 1;
}
