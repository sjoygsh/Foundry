//! The scripted play-throughs' waypoints (playable3d.md §10.2): test data, not game rules.
//! Each step is something a player does: a move that `scripted.zig` turns into an `Intent`,
//! or a menu key.
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
    /// Stand still until the game stops playing: the ending is expected to arrive by itself.
    stand,
    /// Press one menu key, as a person does: the arrows, Enter or Escape.
    press: Key,
    /// Wait for a phase. An ending other than the one named here fails the script.
    expect: Phase,
};

pub const Key = enum { up, down, left, right, accept, back };
pub const Phase = enum { title, playing, paused, won, caught, fell };

pub const Script = struct {
    steps: []const Step,
    /// A script that has not finished by this many frames has failed.
    tick_limit: u32,
    /// The script's last press is Quit, and the run must end by it.
    quits: bool = false,
};

const start = [_]Step{ .{ .press = .accept }, .{ .expect = .playing } };

/// To the open beacon and light it.
const route_open = [_]Step{
    .{ .walk = .{ .to = .{ 2.5, 0, 4.5 }, .face = .{ 3.5, 0.5, 4.5 }, .within = 0.25 } },
    .{ .use = "court:beacon.open" },
};

/// Around the warden's patrol by the south, over the low wall, across the gap, to the gate
/// and through it.
const route_rest = [_]Step{
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
    .{ .expect = .won },
};

/// From the title: Play, light a beacon, pause and resume, light the rest, pass the gate
/// and win; Restart from the end screen and win again; then to the title and Quit. Every
/// phase change is a menu press a person would make.
pub const win: Script = .{ .tick_limit = 3000, .quits = true, .steps = &(start ++ route_open ++ [_]Step{
    .{ .press = .back },
    .{ .expect = .paused },
    .{ .press = .accept },
    .{ .expect = .playing },
} ++ route_rest ++ [_]Step{
    .{ .press = .accept },
    .{ .expect = .playing },
} ++ route_open ++ route_rest ++ [_]Step{
    .{ .press = .down },
    .{ .press = .accept },
    .{ .expect = .title },
    .{ .press = .down },
    .{ .press = .down },
    .{ .press = .accept },
}) };

/// Stands in the patrol and is caught, then restarts from the end screen.
pub const caught: Script = .{ .tick_limit = 1000, .steps = &(start ++ [_]Step{
    .{ .walk = .{ .to = .{ 0, 0, 2.5 }, .face = .{ 0, 1.65, 0 }, .within = 0.2 } },
    .stand,
    .{ .expect = .caught },
    .{ .press = .accept },
    .{ .expect = .playing },
}) };

/// Jumps short into the gap, then restarts from the end screen. The jump is needed: the
/// character controller stops a walk at the court floor's edge (recorded in playable3d.md,
/// Step 3's correction).
pub const fell: Script = .{ .tick_limit = 500, .steps = &(start ++ [_]Step{
    .{ .walk = .{ .to = .{ 0, 0, -1.7 }, .face = .{ 0, 1.65, -5 }, .within = 0.1 } },
    .{ .jump = .{ .to = .{ 0, 0, -2.6 }, .face = .{ 0, 1.65, -5 }, .land_z = -100 } },
    .{ .expect = .fell },
    .{ .press = .accept },
    .{ .expect = .playing },
}) };
