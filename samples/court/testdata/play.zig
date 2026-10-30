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
    /// Do nothing for this many frames, in any phase: a player listening (M30 Step 7).
    wait: u32,
    /// Stand watching until the warden has passed `x`, walking east or west: what a person does
    /// before crossing its view.
    watch: struct { east: bool, past: f32 },
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

/// To the open beacon and light it, once the warden has walked past the angle it could see it
/// from. M33: the warden sees 0.6 rad either side of the way it faces, and nothing behind it.
const route_open = [_]Step{
    .{ .watch = .{ .east = true, .past = 0.3 } },
    .{ .walk = .{ .to = .{ 2.5, 0, 4.5 }, .face = .{ 3.5, 0.5, 4.5 }, .within = 0.25 } },
    .{ .use = "court:beacon.open" },
};

/// Around the warden's patrol by the south, over the low wall, across the gap, to the gate
/// and through it.
const route_rest = route_ledge ++ route_gate;

/// Back out of its sight along the south wall, to wait in the corner it cannot see from anywhere
/// on its line; then, as soon as it is walking away, over the low wall and across the gap,
/// lighting the other two beacons.
const route_ledge = [_]Step{
    .{ .walk = .{ .to = .{ 2.5, 0, 7.2 }, .face = .{ -4, 0.5, 7.2 }, .within = 0.3 } },
    .{ .walk = .{ .to = .{ -4, 0, 7.2 }, .face = .{ -3.5, 0.5, 1.4 }, .within = 0.3 } },
    .{ .watch = .{ .east = true, .past = -1 } },
    .{ .walk = .{ .to = .{ -3.5, 0, 1.4 }, .face = .{ -3.5, 0.5, 0 }, .within = 0.25 } },
    .{ .jump = .{ .to = .{ -3.5, 0, 0.3 }, .face = .{ -3.5, 0.5, 0 }, .land_z = 0.8 } },
    .{ .walk = .{ .to = .{ -2.2, 0, -0.5 }, .face = .{ -3, 0.5, -0.5 }, .within = 0.25 } },
    .{ .use = "court:beacon.wall" },
    .{ .walk = .{ .to = .{ 0, 0, -0.5 }, .face = .{ 0, 0.5, -1.8 }, .within = 0.3 } },
    .{ .walk = .{ .to = .{ 0, 0, -1.6 }, .face = .{ 0, 0.5, -3.5 }, .within = 0.2 } },
    .{ .jump = .{ .to = .{ 0, 0, -3.5 }, .face = .{ 0, 0.5, -3.5 }, .land_z = -3.3 } },
    .{ .walk = .{ .to = .{ 1.2, 0, -5.5 }, .face = .{ 2, 0.5, -5.5 }, .within = 0.25 } },
    .{ .use = "court:beacon.ledge" },
};

/// From the ledge beacon to the gate, and through it.
const route_gate = [_]Step{
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

/// One pass of the soundtrack's run (music.md §9, M30 Step 7), from the title back to it:
/// the title's music past its loop; play, standing where the warden passes, so the music
/// turns to the chase and back; a beacon's stinger; a pause; the other beacons, then a minute
/// far from the warden, long enough for the calm playlist to cross from one track to the
/// next; the gate's stinger and a win; caught, and fell, each restarted; back to the title.
const soundtrack_pass = [_]Step{
    .{ .wait = 1800 },
    .{ .press = .accept },
    .{ .expect = .playing },
    .{ .wait = 900 },
} ++ route_open ++ [_]Step{
    .{ .press = .back },
    .{ .expect = .paused },
    .{ .wait = 300 },
    .{ .press = .accept },
    .{ .expect = .playing },
} ++ route_ledge ++ [_]Step{
    .{ .wait = 3600 },
} ++ route_gate ++ [_]Step{
    .{ .wait = 300 },
    .{ .press = .accept },
    .{ .expect = .playing },
    .{ .walk = .{ .to = .{ 0, 0, 2.5 }, .face = .{ 0, 1.65, 0 }, .within = 0.2 } },
    .stand,
    .{ .expect = .caught },
    .{ .wait = 180 },
    .{ .press = .accept },
    .{ .expect = .playing },
    .{ .walk = .{ .to = .{ 0, 0, -2.6 }, .face = .{ 0, 1.65, -5 }, .within = 0.1 } },
    .{ .expect = .fell },
    .{ .wait = 180 },
    .{ .press = .down },
    .{ .press = .accept },
    .{ .expect = .title },
};

/// Five passes, a little over ten minutes at 60 Hz, then Quit from the title: the
/// soundtrack's run. Criteria 2 and 3 read its music log.
pub const soundtrack: Script = .{ .tick_limit = 60_000, .quits = true, .steps = &(soundtrack_pass ** 5 ++ [_]Step{
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

/// Walks off the court floor's edge into the gap, as a person falls, then restarts from the
/// end screen. (Until M26 Step 8 the controller stopped a walk at that edge, and this script
/// jumped short instead.)
pub const fell: Script = .{ .tick_limit = 500, .steps = &(start ++ [_]Step{
    .{ .walk = .{ .to = .{ 0, 0, -2.6 }, .face = .{ 0, 1.65, -5 }, .within = 0.1 } },
    .{ .expect = .fell },
    .{ .press = .accept },
    .{ .expect = .playing },
}) };
