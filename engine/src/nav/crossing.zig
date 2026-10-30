//! The three motions of an off-mesh link (`agents.md` §6.3): plain arithmetic, no trig, so a pin
//! does not depend on a linked libm. Mods place links and add no kind, since the curves are here.

const std = @import("std");
const core = @import("core");

const features = @import("features.zig");

const LinkKind = features.LinkKind;
const Vec3 = core.math.Vec3;

/// Shapes a drop's curve. Not a simulation constant: nothing but the look of a fall reads it.
const fall_gravity: f32 = 9.81;

fn flat(a: Vec3, b: Vec3) f32 {
    const dx = b.x - a.x;
    const dz = b.z - a.z;
    return @sqrt(dx * dx + dz * dz);
}

/// How long crossing from `from` to `to` takes at `speed`, seconds.
pub fn duration(kind: LinkKind, from: Vec3, to: Vec3, speed: f32) f32 {
    const rise = @abs(to.y - from.y);
    return switch (kind) {
        .jump => to.sub(from).length() / speed,
        .drop => flat(from, to) * 0.5 / speed + @sqrt(2 * rise / fall_gravity),
        .ladder => rise / (speed * 0.5) + flat(from, to) / speed,
    };
}

/// Where a crossing is at `t`, 0 to 1. `arc` is a jump's height above the higher end.
pub fn at(kind: LinkKind, from: Vec3, to: Vec3, arc: f32, speed: f32, t: f32) Vec3 {
    const s = std.math.clamp(t, 0, 1);
    const dy = to.y - from.y;
    switch (kind) {
        .jump => {
            // y = y0 + b s + a s², through both ends with its top `arc` above the higher one.
            const top = @max(from.y, to.y) + arc - from.y;
            const b = 2 * (top + @sqrt(top * @max(top - dy, 0)));
            const a = dy - b;
            return .init(from.x + (to.x - from.x) * s, from.y + (b + a * s) * s, from.z + (to.z - from.z) * s);
        },
        .drop => {
            const walk = flat(from, to) * 0.5 / speed;
            const whole = walk + @sqrt(2 * @abs(dy) / fall_gravity);
            const out = if (whole > 0) walk / whole else 1;
            if (s <= out and out > 0) {
                const u = s / out;
                return .init(from.x + (to.x - from.x) * u, from.y, from.z + (to.z - from.z) * u);
            }
            const u = (s - out) / (1 - out);
            return .init(to.x, from.y + dy * u * u, to.z);
        },
        .ladder => {
            // The climb stands over the lower end, so going down steps off the top first.
            const climb = @abs(dy) / (speed * 0.5);
            const whole = climb + flat(from, to) / speed;
            const share = if (whole > 0) climb / whole else 1;
            if (dy >= 0) {
                if (s <= share and share > 0) return .init(from.x, from.y + dy * (s / share), from.z);
                const u = (s - share) / (1 - share);
                return .init(from.x + (to.x - from.x) * u, to.y, from.z + (to.z - from.z) * u);
            }
            const step = 1 - share;
            if (s <= step and step > 0) {
                const u = s / step;
                return .init(from.x + (to.x - from.x) * u, from.y, from.z + (to.z - from.z) * u);
            }
            return .init(to.x, from.y + dy * ((s - step) / share), to.z);
        },
    }
}
