//! The scripted play-throughs' waypoints (playable3d.md §10.2): test data, not game rules.
//! Each step is something a player does, and `scripted.zig` turns it into an `Intent`.
//! Points are metres in the court's level; a beacon is named by its content ID and found
//! where its record puts it.

pub const Point = [3]f32;

pub const Step = union(enum) {
    /// Walk to `to` while looking at `face`, until within `within` metres of it.
    walk: struct { to: Point, face: Point, within: f32 },
    /// Hold Space and walk toward `to` until standing on ground north of `land_z`.
    jump: struct { to: Point, face: Point, land_z: f32 },
    /// Look at a beacon and press Use until it is lit.
    use: []const u8,
    /// Stand still until the gate has finished opening.
    wait_gate,
    /// Stand still; the script's ending is expected to arrive by itself.
    stand,
};

pub const Ending = enum { won, caught, fell };

pub const Script = struct {
    steps: []const Step,
    ending: Ending,
    /// How many times the ending is reached, with a restart between.
    runs: u8,
    /// A run that has not finished by this many ticks has failed.
    tick_limit: u32,
};

/// Lights the three beacons, keeping south of the warden's patrol, passes the gate, wins,
/// restarts and wins again.
pub const win: Script = .{ .ending = .won, .runs = 2, .tick_limit = 3000, .steps = &.{
    .{ .walk = .{ .to = .{ 2.5, 0, 4.5 }, .face = .{ 3.5, 0.5, 4.5 }, .within = 0.25 } },
    .{ .use = "court:beacon.open" },
    .{ .walk = .{ .to = .{ -3.5, 0, 4.5 }, .face = .{ -3.5, 0.5, 1.4 }, .within = 0.3 } },
    .{ .walk = .{ .to = .{ -3.5, 0, 1.4 }, .face = .{ -3.5, 0.5, 0 }, .within = 0.25 } },
    .{ .jump = .{ .to = .{ -3.5, 0, 0.3 }, .face = .{ -3.5, 0.5, 0 }, .land_z = 0.8 } },
    .{ .walk = .{ .to = .{ -2.2, 0, -0.5 }, .face = .{ -3, 0.5, -0.5 }, .within = 0.25 } },
    .{ .use = "court:beacon.wall" },
    .{ .walk = .{ .to = .{ 0, 0, -0.5 }, .face = .{ 0, 0.5, -1.8 }, .within = 0.3 } },
    .{ .walk = .{ .to = .{ 0, 0, -1.6 }, .face = .{ 0, 0.5, -3.5 }, .within = 0.2 } },
    .{ .jump = .{ .to = .{ 0, 0, -3.5 }, .face = .{ 0, 0.5, -3.5 }, .land_z = -3.3 } },
    .{ .walk = .{ .to = .{ 1.2, 0, -5.5 }, .face = .{ 2, 0.5, -5.5 }, .within = 0.25 } },
    .{ .use = "court:beacon.ledge" },
    .{ .walk = .{ .to = .{ 0, 0, -7 }, .face = .{ 0, 1.25, -9 }, .within = 0.25 } },
    .wait_gate,
    .{ .walk = .{ .to = .{ 0, 0, -8.6 }, .face = .{ 0, 1.25, -9 }, .within = 0.05 } },
} };

/// Stands in the patrol and is caught, then restarts.
pub const caught: Script = .{ .ending = .caught, .runs = 1, .tick_limit = 1000, .steps = &.{
    .{ .walk = .{ .to = .{ 0, 0, 2.5 }, .face = .{ 0, 1.65, 0 }, .within = 0.2 } },
    .stand,
} };

/// Jumps short into the gap, then restarts. The jump is needed: the character controller
/// stops a walk at the court floor's edge (recorded in playable3d.md, Step 3's correction).
pub const fell: Script = .{ .ending = .fell, .runs = 1, .tick_limit = 500, .steps = &.{
    .{ .walk = .{ .to = .{ 0, 0, -1.7 }, .face = .{ 0, 1.65, -5 }, .within = 0.1 } },
    .{ .jump = .{ .to = .{ 0, 0, -2.6 }, .face = .{ 0, 1.65, -5 }, .land_z = -100 } },
} };
