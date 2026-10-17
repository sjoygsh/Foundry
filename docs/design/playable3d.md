# Design: M26 — A playable 3D sample: `samples/court`, pointer capture and the three-platform play

**Status:** **Complete 2026-10-18 (tag `m26`).** Accepted 2026-10-03 by the owner's request to begin Step 1, which accepts §14 as written; revised to thirteen steps on 2026-10-17 (§12). All thirteen are done, and the three play reports §10.5 requires are in (Step 12's Resolution).
**Date:** 2026-10-02
**Baseline:** `845b02f`, tag `m25` (documents since: `9b72a78`, `d9c0411`). M0–M25 are complete.
**Decisions:**
- ADR-0002 (SDL3 only inside `platform`), ADR-0013 (deterministic-friendly), ADR-0017 (a sample
  is not a game), ADR-0023 (Foundry's own mixer), ADR-0024 and ADR-0041 (the UI kernel, the game
  widget set and content themes), ADR-0031 (bootstrap, content defaults and preferences stay
  separate), ADR-0048 to ADR-0058 (3D) and ADR-0060 (the roadmap; a milestone builds what its
  sample needs) constrain it.
- **It proposes no ADR.** Nothing here constrains a later milestone or is expensive to reverse:
  the one engine addition is a small `platform` call (§4), and the rest is a sample. M21 set the
  precedent for a milestone without one.

`3d.md` §10's M26 row and the paragraph under it are the contract. M26 spans `platform`, a new
sample, the build graph and three machines, so it writes its own document.

## 1. Purpose and boundary

`3d.md` §10, quoted:
- **Milestone:** a playable 3D sample.
- **Regression coverage:** a scripted play-through that reaches the sample's completion.
- **Exit condition:** "play, not a rendered scene. From a relocated install, on macOS/Metal,
  Windows/Vulkan, and Linux/Vulkan on a freshly provisioned machine (§10.2), a person who did not
  build it: starts it; understands the goal from the sample itself; controls a character through
  a 3D space, with collision; interacts with the world; reaches a completion or failure;
  restarts; plays with sound, and with a 2D HUD and menu over the 3D frame."
- "The sample's own design is written in M26 and kept small. It stays a sample, not a game
  (ADR-0017), and uses only what M19–M25 built. If it needs more, that becomes a milestone change
  recorded in the roadmap, not work absorbed into M26."

**In M26:**
- **pointer capture** in `platform` (§4): the one engine addition, deferred here by name in
  `collision3d.md` §10.3 and §15;
- **`samples/court`** (§5–§9): a first-person sample with a goal, an interaction, a completion,
  two failures, a restart, sound, a HUD and menus, all of it content;
- a **scripted play-through** for each ending, replayed byte-exactly on the same binary (§10);
- the sample staged as an ad-hoc release for macOS and Windows, and run from a relocated install
  on macOS/Metal, Windows/Vulkan and Linux/Vulkan (§11);
- a **freshly provisioned Linux machine**, rebuilt from the kit, running the whole graph and the
  sample (§11);
- a person's play on each of the three, reported by them (§10.5).

**Not in M26**, each with its place in the long roadmap or its trigger in §13:
- anything in `FoundryApi_v6`, which is frozen, or a v7;
- 3D audio spatialisation (M31), navigation or a chasing AI (M32–M33), a third-person body, an
  engine animation component (M34), dynamics, a sky, a save game, a mod screen in 3D, gamepads;
- a published release. M26 stages; publishing a pre-release is the owner's separate decision;
- certification. ADR-0060 re-dated it to M150, so M26 no longer triggers it (§12 corrects the
  two lines that still say it does).

**What the sample is evidence for.** The room proved that Foundry can carry a 2D game without
one line of `engine/` changing. The court makes the same claim for 3D, and it is allowed exactly
one exception, pointer capture, which was known and recorded two milestones ago. If a step finds
a second engine change it cannot do without, that step stops and puts it to the owner, as
`3d.md` §10 requires.

## 2. What exists

Read from the code at the baseline, not from older documents.

- **`samples/sandbox3d`** (`main.zig`, 1,462 lines, and eleven siblings) draws a lit glTF room by
  content ID, walks it in first person, patrols a CPU-skinned walker, and hosts a content mod and
  a consented native one. It is granted `abi`, `anim`, `app`, `asset`, `core`, `data`, `debug`,
  `mod`, `physics3d`, `platform`, `render2d`, `render3d`, `scene` and `ui`, **not `audio`** and
  never `rhi` (`build.zig` lines 629–649).
- **The walk** (`samples/sandbox3d/walk.zig`): a `physics3d` capsule character moved once per
  fixed tick from an `Intent`, with gravity as sample policy, a −10 m respawn, and collision
  meshes copied from `foundry:collision_mesh` assets. **There is no jump.** Looking is the arrow
  keys or the mouse while the right button is held, read from `InputSnapshot.mouse.motion`.
- **`platform`** (`interface.zig`, `input.zig`, `backends/sdl3.zig`, `backends/null.zig`):
  `MouseState` carries position in points and pixels and a summed `motion`; the SDL3 backend
  fills `motion` from `xrel`/`yrel`. **Nothing hides, confines or captures the pointer**, so a
  mouse look stops at the window's edge.
- **`physics3d`** (`world.zig`): `raycast`, `shapeCast`, `overlap`, static and kinematic bodies
  with `setPose`, and the character controller. No pushing, no moving platforms (ADR-0051).
- **`render3d`**: models, materials and lights by content ID, one directional shadow map, sixteen
  lights a frame (`lighting.max_lights`), CPU skinning, and `app.Engine.renderScene`'s
  world-then-overlay frame, which already draws `render2d` over the 3D pass.
- **`audio`** (`mixer.zig`): `play` by content ID with gain, pan, pitch and looping, WAV only, no
  position. `samples/room` computes a looping voice's pan from where the walker stands.
- **The game widget set and themes** (ADR-0041): `app.resolveUiTheme` turns a `foundry:ui_theme`
  record into a style and a skin; `samples/room` draws a card with it and falls back when the
  theme is bad.
- **Preferences** (`engine/src/app/settings.zig`): the bounded `settings.fset`, opt-in, which the
  room uses for window size and volume.
- **`samples/room`** is the model for a playable sample: content for every string and tuning
  value, an autopilot that finishes the hall, a `finished` state, and a headless run in the bar.
  It has no restart and no failure.
- **Release staging** (`build.zig` lines 925 onward): `zig build dist -Dapp=room|sandbox|editor`.
  `sandbox3d` is not stageable. No Linux release artifact exists (CLAUDE.md §9).
- **The Linux kit** (`scripts/m18/`): `provision.sh`, `record-machine.sh`, `x11.sh`,
  `wayland.sh`, `samples.sh` and `RUNBOOK.md`, which says in its own words that M26 provisions a
  new machine from that directory alone.
- **The bar** (`AGENTS.md`): `fmt`, `test`, four `check`s, and 30-frame headless runs of the
  three samples.

## 3. The shape of the milestone

**A second 3D sample, not a mode of the first.** CLAUDE.md §4.5 already separates a sample that
demonstrates from one that plays, and `sandbox3d`'s frame is full of evidence: a spinning cube,
an orrery, F-keys that save and re-parent, a native mod. A person told to "play" that would not
find a goal. So M26 adds `samples/court` beside it, as `samples/room` stands beside
`samples/sandbox`. `sandbox3d` is not changed except to try pointer capture first (§4.5).

**Sample-owned state, as the room and `sandbox3d` have it.** The court keeps its beacons, gate,
warden and player in plain structs fed by content records. It does not introduce an
engine-declared "draws this model" component, does not author a hierarchy in content, and does
not save a pose. Those three items each named M26 as a possible trigger (`public3d.md` §14,
`hierarchy.md` §12, `animation3d.md` §14); the court does not need them, and §13 records that
their triggers did not fire.

**Simulation is ticks.** Everything that decides the outcome, movement, jumping, interaction,
the gate, the warden, winning and losing, runs at the fixed step from an `Intent` built once per
frame (I9). The frame draws, mixes sound and describes UI. This is what lets a script play the
sample and lets a replay check it.

## 4. `platform`: pointer capture

### 4.1 Why it is in `platform`

A first-person look needs unbounded relative motion with the cursor hidden. That is a property
of the window system, and SDL3 is referenced only in `platform` (ADR-0002), so the call belongs
in the platform interface beside `setWindowSize`, `setWindowIcon` and `setWindowTitle`.

### 4.2 The call

```zig
pub const PointerCaptureError = error{ InvalidWindow, Unsupported };
fn setPointerCapture(self: *P, window: WindowHandle, captured: bool) PointerCaptureError!void
```

and `app.Engine.setPointerCapture(captured)` over the engine's window, as the other window
calls are wrapped.

- **Captured** means the cursor is hidden, held inside the window, and `MouseState.motion`
  reports relative motion that does not stop at an edge. `position` and `position_pixels` keep
  their last value before capture and do not move.
- **`MouseState` gains `captured: bool`**, the state at snapshot time. A game reads what is
  true, never what it last asked for, because the window system can end a capture by itself.
- **Losing keyboard focus releases the capture**, and the backend reports `captured = false` in
  the next snapshot. It is not re-acquired automatically: the game asks again when the player
  returns, which for the court means leaving the pause menu.
- **`Unsupported`** is a normal answer, not a fault. A Wayland compositor without the
  relative-pointer and pointer-constraints protocols gives it. The caller keeps working with an
  uncaptured pointer.
- **Motion's unit under capture is the device's**, which SDL3 reports unaccelerated on some
  systems and accelerated on others. Sensitivity is therefore the game's, from a preference
  (§8). The engine does not normalise it, because the right scale is a feel decision.

### 4.3 Backends

- **SDL3:** `SDL_SetWindowRelativeMouseMode`. A `false` return maps to `Unsupported` with one
  log line. The focus-lost event clears the mode and the accumulator's flag.
- **Null:** records the flag per window, clears it on a scripted focus loss, and reports it in
  the snapshot, so the rules above are tested with no window.

### 4.4 The UI and capture

The UI kernel hit-tests a pointer position. Under capture there is no meaningful position, so a
host passes the kernel no pointer while captured. This is the host's rule, as input capture
already is advisory (`ui.md` §4), and the court's phases make it simple: captured while playing,
released in every menu.

### 4.5 Not published

Nothing enters the ABI. `v6` is frozen, and pointer capture is host window policy, like the
window icon (`vulkan.md` §9): a mod does not own the player's pointer. A mod that needs it is a
trigger in §13.

`sandbox3d` gains one key, F4, that toggles capture for its walk. It is there so Step 1 has a
windowed consumer on Metal before the court exists, and so the Windows and Linux runs have two.

## 5. `samples/court`: the game

### 5.1 What a person does

A walled courtyard at night. Three beacons stand unlit: one in the open, one behind a low wall
that must be jumped, one on a ledge across a gap. A warden walks a fixed patrol through the
middle. The player lights each beacon by looking at it from close by and pressing a key. When
all three burn, the gate at the far end opens, and walking through it ends the game.

- **Completion:** the player's feet enter the exit volume beyond the open gate.
- **Failure, caught:** the warden's capsule comes within a content-set distance of the player's.
- **Failure, fell:** the player's feet fall below the pit's floor level, under the gap.
- **Restart:** from either end screen or the pause menu, back to the initial state.

It is small on purpose. One level, one interaction verb, no inventory, no score, no difficulty
levels, no second level. Anything that would make it more of a game belongs in a game's own
repository (ADR-0017).

**Why these pieces.** Each one exercises something M19–M25 built, so the play-through is also a
regression test of it: glTF meshes and materials (M20), lights and the shadow (M22: each lit
beacon adds a point light, well inside sixteen), the character controller, raycasts and a
kinematic body (M23: the gate), a CPU-skinned animated character (M24: the warden), and `render2d`
over the 3D frame (M19).

### 5.2 Phases

`title → playing ⇄ paused → won | caught | fell → title or playing`. The phase is simulation
state and changes only inside a tick, from that tick's `Intent`. Ticks do not advance the world
outside `playing`, so a paused game is paused exactly.

### 5.3 The player

The court takes `sandbox3d`'s walk as its starting point and owns its own copy; samples do not
share source, because each is the reference for a separate consumer.

- **Move:** W, A, S and D relative to the yaw, at a content-set speed.
- **Look:** the captured mouse, scaled by the sensitivity preference, with pitch clamped to ±85°
  and an invert option. The arrow keys also look, so the sample is playable where capture is
  `Unsupported`, and so a script can look without a mouse.
- **Jump:** Space, when grounded, sets the vertical velocity to a content-set value. This is the
  jump `collision3d.md` §15 deferred to M26. It is sample policy over the existing controller,
  like gravity. A press is latched from the frame into the next tick so one is not lost between
  ticks.
- **Use:** E. One raycast from the eye along the look direction, a content-set reach long,
  against the beacons' layer. The nearest hit's `user` value names the beacon.

### 5.4 The world

- **Level geometry** is one glTF model with derived collision (`collision true`), generated by a
  developer script (§7), as M24's walker and M25's props were.
- **Beacons** are `court:beacon` records: a position, a model, the light it adds when lit and its
  sound. Each owns a static box body on its own layer for the Use ray. They are iterated in
  content-ID hash order wherever order matters (I9), as `sandbox3d`'s props are.
- **The gate** is a `court:gate` record: a model, a kinematic box, a closed and an open
  position, and a travel time. When the last beacon lights it moves from one to the other over
  that many ticks, away from the player's side, with `setPose` each tick. `physics3d` does not
  push a character (ADR-0051), and the gate is placed so it never moves into one.
- **The warden** is a `court:warden` record: the model, patrol waypoints, speed and clips, as
  `sandbox3d`'s walker is. It follows its waypoints and nothing else. It does not see, chase or
  path-find; a chasing warden needs navigation (M32–M33) and would be game AI in a sample.
- **The exit and the pit** are a volume and a height in the `court:rules` record.

### 5.5 Everything is content

The package is `court:content`. Its records: `court:config` (window, clear colour, lights,
ambient, exposure), `court:rules` (spawn, speeds, jump, reach, catch distance, exit volume, pit
height), the beacons, the gate, the warden, `court:text` (every string on screen) and
`court:ui.theme`. No position, speed, string or count is in the source (I5). A content mod
loaded after the package changes any of them (§9). The sample names content IDs and no path
(ADR-0021).

A record that fails validation is refused with a log line and the sample falls back as the room
does: a missing gate means the court cannot be finished, and it says so.

## 6. HUD, menus and sound

### 6.1 Over the 3D frame

Everything 2D is drawn in `renderScene`'s overlay pass through `render2d`, from the `ui` kernel's
draw list and the game widget set, in the look `court:ui.theme` gives (ADR-0041). A theme that
fails to resolve leaves a plain fallback style, as in the room.

- **HUD, while playing:** how many beacons are lit of how many; a small centre mark; a prompt
  when a beacon is in reach ("E — light the beacon"); the goal line for the first seconds of
  each game. The goal line is how a person "understands the goal from the sample itself".
- **Title:** the name, the goal in two sentences, the controls, and Play, Options and Quit.
- **Pause** (Escape): Resume, Restart, Options, Quit to title. Opening it releases the pointer;
  Resume asks for it again.
- **End screens:** won, caught or fell, each with its own line, and Restart and Title.
- **Options:** master volume, look sensitivity, invert look. Changes apply at once and are
  written to `settings.fset` (§8).

Menus are driven by the mouse and by the keyboard (arrows, Enter, Escape), so each is reachable
without a pointer and a script can press them.

### 6.2 Sound

The court is granted `audio`. Sounds are `foundry:sound` WAV records, generated by a developer
script as the room's were:
- a looping ambience from the title onward;
- footsteps, one for each content-set distance walked on the ground;
- a jump and a landing;
- a beacon lighting; the gate moving; the warden's steps;
- one sound each for won, caught and fell; a click for menus.

**Position is the sample's arithmetic.** The mixer has gain and pan and no listener (M31 adds
spatialisation). For the warden's steps and the gate, the court computes gain from distance and
pan from the direction relative to the yaw, once per frame, as the room pans its door. That is a
dozen lines of sample code and no engine change.

Sound is presentation. It is driven from events the ticks emit, never read back by them, so the
audio thread's timing cannot change an outcome (I9).

## 7. Assets

All generated in the repository by `scripts/m26/make_court.py`, committed with their outputs,
under the repository's license, and reproducible byte for byte (the script's own test regenerates
and compares). Python stays a developer tool and is never part of the build (CLAUDE.md §4.4).
- `court.gltf`/`.bin`: floor, walls, the low wall, the ledge, the gap and pit, the gate's frame.
- `beacon.gltf`, `gate.gltf`: small props.
- **The warden reuses M24's generated walker generator**, re-emitted under the court's own IDs,
  so the court's package does not depend on `sandbox3d`'s.
- Two small textures and the sound set.

## 8. Bootstrap and preferences

- **Host bootstrap** (ADR-0031): `--msaa=1|4`, `--shadows=on|off`, and environment variables for
  scripted runs: `FOUNDRY_COURT_FRAMES`, `FOUNDRY_COURT_PLAY=win|caught|fell` (§10.2),
  `FOUNDRY_COURT_WORKERS`, `FOUNDRY_COURT_OVERLAY=1` (the debug overlay, also F1),
  `FOUNDRY_COURT_PACKAGES` (§9) and `FOUNDRY_COURT_SAVE_DIR` for a disposable preferences root.
- **Preferences:** `settings.fset` under `foundry-court`, holding window size, master volume,
  look sensitivity and invert, each bounded and validated on read. A missing or damaged file
  gives the content defaults. Headless and frame-budgeted runs neither read nor write it, the
  rule the other samples follow.

## 9. Mods

A content mod works in the court by the ordinary path: user packages under `foundry-court/mods`,
selected for a run by `FOUNDRY_COURT_PACKAGES`, as `sandbox3d` selects them. The test package
`testdata/mods/noon` changes the lights, the strings, the warden's speed and one beacon's
position with no code, and the play-through for it still completes. That is I3 and I5 checked on
a game instead of a demonstration.

**No native code, no profile and no mod screen.** The court imports neither `abi` nor `mod`'s
profile machinery beyond discovery. A 3D game's mod screen is the room's screen over the same
public table and proves nothing new here; §13 gives its trigger.

## 10. Verification

### 10.1 `platform`

Null-backend tests for every rule in §4.2: capture sets the flag; motion accumulates with
position frozen; focus loss clears it and the next snapshot says so; an invalid window is
refused; a second request for the same state is accepted; the snapshot stays plain data and
comparable. The comptime conformance check gains the call, so a backend without it does not
build.

### 10.2 The scripted play-through

`FOUNDRY_COURT_PLAY` drives the sample by producing an `Intent` each tick from a small waypoint
script kept in the sample's test data: walk to a point, face a point, jump, use, wait. It enters
through the same `Intent` a person's input becomes, so a script cannot take a path a player
cannot.
- `win` lights three beacons, passes the gate, reaches `won`, restarts, and wins again.
- `caught` stands in the patrol and reaches `caught`, then restarts to `playing`.
- `fell` walks into the gap and reaches `fell`, then restarts.

Each runs headless on null inside `zig build test`, and windowed on every backend the milestone
claims. A run asserts its ending, the beacon count, that no light, draw or sound was dropped for
capacity, and that the frame never failed.

### 10.3 Determinism

The outcome-deciding state (player pose and velocity, phase, beacons, gate position, warden pose)
is hashed every tick. A fresh world replays the recorded intents to **the same hash at every
tick** in the same binary. The second win after a restart matches the first, which proves
restart returns to the true initial state. Cross-machine equality is observed and recorded, not
claimed (ADR-0013); M25 found the Mac's two sine providers differ, so no single value is pinned
across machines.

### 10.4 Refusals

Tests for each untrusted input: a `court:rules`, beacon, gate or warden record with a missing
field, a non-finite number, a zero or negative size, a beacon count above the bound, a model of
the wrong schema, a theme that does not resolve, and a damaged or newer-versioned preferences
file. Each is refused or defaulted with a diagnostic, and none faults.

### 10.5 By hand, and what counts

The exit condition is a person's play, so it is recorded as what a person reports, never
inferred from a script. On each of the three platforms a person who did not write the sample
starts it from the relocated install with no instructions beyond the sample's own screens, and
reports whether they understood the goal, finished or failed, restarted, heard it and used the
menus. An agent does not claim this item. **M26 does not close while any of the three is
unclaimed.**

### 10.6 Cost, measured inside the paced loop

At ReleaseSafe, paced at 60 Hz, on each machine, read from the profiler across the `win` run:
the frame's median and p95 against the **16.67 ms** frame, the `character` move against M23's
**0.25 ms** p95, and skinning against M24's **0.25 ms** p95 for the one warden. Skipped frames
are counted and expected to be zero. Numbers are measured, never estimated; a p95 on a budget's
line is reported as on the line and left to the owner to read.

## 11. Platform assessment

- **macOS/Metal: runtime.** The primary machine. Pointer capture is checked windowed, by script
  for the state and by a person for the feel.
- **Windows/Vulkan: runtime, on the PC.** Pointer capture is a window-system path that has never
  run there, and the exit names the platform. The PC rules stand: check CPU at or under 50%,
  `-j2`, below-normal priority, background jobs, a worktree, pack up afterwards.
- **Linux/Vulkan: runtime required, on a freshly provisioned machine.** `3d.md` §10.2 requires
  it of M26 regardless, and §4 fires its first trigger by itself: relative-mouse mode is window
  handling that differs between X11 and Wayland. The machine is built from `scripts/m18/` alone;
  anything the kit lacks is fixed in the repository. The run is the whole test graph with
  validation required, both existing samples and `sandbox3d`, and the court under Xorg and under
  a Wayland compositor, with capture checked on each.
  - **A person must be able to play there**, which a rented cloud GPU with no monitor does not
    allow comfortably. So the recommended route is the kit's first: a Linux installation on a PC
    with a monitor. **This needs the owner at Step 7**: a machine, or a decision to rent one and
    play over a remote desktop. It does not block Steps 1–6.
  - The machine is disposable. Evidence comes home before it goes, and no address, user,
    hostname or credential enters the repository or a report.
- **Release artifacts:** `zig build dist -Dapp=court` stages unsigned, ad-hoc macOS and Windows
  releases, as the room's are. Linux runs from a relocated `zig build` install prefix, as M18's
  samples did; a Linux release artifact stays the open distribution decision of CLAUDE.md §9.

## 12. Implementation order — thirteen bounded steps

Each step ends with a Resolution here, an updated `PROJECT_STATE.md`, the bar and a commit. There
is no automatic chaining.

> **Revised 2026-10-17, by the owner's instruction (CLAUDE.md §2, rule 17).** A milestone no longer
> closes with its own work deferred. Work that earlier milestones set aside, and that belongs to
> what they built rather than to a later roadmap line, is finished here, before M26 closes:
> Steps 8–12 below. Everything else those milestones set aside is placed on a named roadmap
> milestone in `docs/ROADMAP.md`'s note of the same date. Step 8 (the close) becomes Step 13. The
> owner asked for Steps 7–13 to run without a stop between them, stopping at the close or when
> the owner is needed.
>
> One reading is fixed at the same time, rather than left open: **§10.6's budgets are for the
> runtime a player gets**, which loads no validation layer. A validation-enabled cost is a
> diagnostic, reported beside the budget and never measured against it. Step 6's
> validation-enabled frame and skin p95 are therefore recorded, not a failed budget.

### Step 1 — `platform`: pointer capture

§4: the interface call, `MouseState.captured`, the null and SDL3 backends, the engine's wrapper,
§10.1's tests, and `sandbox3d`'s F4. `platform-interface.md` gains the call. **Exit:** on the
null backend every rule of §4.2 is tested, and on Metal `sandbox3d` looks around without the
cursor leaving the window, releasing on focus loss.

### Step 2 — `samples/court`: the skeleton, on null and Metal

The build-graph entry (granted `app`, `asset`, `audio`, `anim`, `core`, `data`, `debug`, `mod`,
`physics3d`, `platform`, `render2d`, `render3d`, `scene`, `ui`; never `rhi` or `abi`), the
package with `court:config` and `court:rules`, `scripts/m26/make_court.py` and the level, the
walk with captured look and jump, the lit level drawn, and `zig build court`. The bar gains
`FOUNDRY_COURT_FRAMES=30 zig build court -Dplatform=null -Drhi=null`. **Exit:** the court's level
draws lit on Metal, the player walks and jumps it with collision, and the headless run is in the
bar.

### Step 3 — `samples/court`: the game

§5: phases, beacons and Use, the gate, the warden, the exit and the pit, restart, and §10.2 to
§10.4's play-throughs, replay and refusals, all on null. **Exit:** the three scripted
play-throughs reach their endings and restart, headless, and each replays to the same hash at
every tick.

### Step 4 — `samples/court`: HUD, menus, sound and preferences

§6 and §8: the theme, HUD, title, pause, end and options screens with keyboard and pointer, the
generated sounds and their gain and pan, and `settings.fset`. The play-throughs gain the menu
presses a person would make. **Exit:** from the title screen a scripted run starts, pauses,
resumes, wins, restarts and quits through the menus alone, with every sound event played and
none dropped.

### Step 5 — Metal: the relocated install, the mod and the release

§9's `noon` mod, `dist -Dapp=court` for macOS and Windows, the three play-throughs windowed from
a relocated, read-only ReleaseSafe install, and §10.6's costs. **Exit:** from a relocated
install on Metal the play-throughs pass paced with no skipped frame, the content mod changes the
court with no code, and both releases stage.

### Step 6 — Windows/Vulkan on the PC

The native suites, the relocated install, the play-throughs under synchronization validation and
with layers off, capture checked, the replay on that machine, the costs, and pack-up. **Exit:**
every suite and play-through passes natively with validation clean.

### Step 7 — Linux/Vulkan on a freshly provisioned machine

§11: provision from the kit, record the machine, run the whole graph with validation required,
the existing samples, and the court under Xorg and Wayland with capture on each; fix whatever
the kit lacked in the repository; bring the evidence home. `scripts/m26/` holds what the run
added, and `RUNBOOK.md` is corrected where it was wrong. **Exit:** on a machine built from the
kit alone, the graph and the play-throughs pass, and the machine's evidence is in the record.
*Added 2026-10-17:* M18's two Linux leftovers (`linux-desktop.md` §5) are done here too: GNOME's
unexplained pacing is measured and explained, and a Wayland pointer is driven from outside
the window.

### Step 8 — `physics3d`: walking off an edge

Step 3's controller finding: the walk stops with the feet on a floor box's edge, because the
edge contact reports the box's vertical face as a wall and the wall response removes motion
pointing away from it. Fix it in `character.zig`, with M23's tests intact and new ones for a
walk off a box edge, a mesh edge and a step's edge, and a wall still stopping a walk into it.
The `fell` script then walks off the ledge instead of jumping short. **Exit:** the character walks
off an edge on null and Metal, M23's course and every replay hash that does not cross an edge
are unchanged, and changed hashes are explained.

*Added 2026-10-17, from Step 7:* the move's p95 missed 0.25 ms on Linux under Ubuntu's default
`balanced` power profile, and the court's frame work counted Wayland FIFO's image wait. The
controller's mesh query is made cheaper without changing its answers, and frame work leaves out
`render.acquire` as it leaves out the pacing sleep. **Exit, added:** on that machine, under
`balanced`, the move's p95 is within 0.25 ms in every session, and GNOME's frame work is within
the frame.

### Step 9 — `render3d` and `rhi`: the M20 and M22 leftovers

`meshes.md` §13's anisotropic filtering (a sampler field on null, Metal and Vulkan, validated by
the null backend) and per-submesh bounds in culling, and `light.md` §14's depth-only pipeline
with no fragment shader. **Exit:** each is tested on null, read back on Metal and on Linux's
Vulkan, and the court and `sandbox3d` draw unchanged where the change should not show.

### Step 10 — Tools: `fdt fmt`, an editor grammar, saved profiles and panel state

`content-schemas.md` §10's canonical formatter and its editor grammar, and `debug-overlay.md`
§15's profile written to a versioned file and panels that remember their state in the user
data directory. **Exit:** `fdt fmt` is idempotent over every `.fdt` in the repository and
refuses what it cannot keep byte-exact, a saved profile reads back, refuses an unknown version,
and panel state survives a restart.

### Step 11 — `platform`: file watching for hot reload

`platform-interface.md`'s deferred file watching, on macOS, Linux and Windows, behind one call,
with the asset hot-reload path driven by it rather than by polling where it polls. **Exit:**
on each of the three systems an edited source is reloaded from its notification, and a missing
or unsupported watch is a normal answer.

### Step 12 — Windows and Linux re-qualification

Steps 8–11 on the PC's Windows and on the Step 7 Linux machine: the native suites, the court's
play-throughs and the changed renderer readbacks. **Exit:** both pass, and the evidence is home.

### Step 13 — Close M26

This step needs §10.5's three reports. It then:
- corrects `3d.md` §10: the M26 row's "that ADR-0047 made certification wait for" (ADR-0060
  re-dated certification to M150), and the "uses only what M19–M25 built" sentence, which gains
  pointer capture as the recorded exception; marks M26 done;
- resolves `collision3d.md` §10.3 and §15 (pointer capture, jump), and records in `hierarchy.md`
  §12, `animation3d.md` §14, `public3d.md` §14 and `light.md` §14 that M26 did not fire their
  triggers; updates `render3d.md` §8's naming note and `linux-desktop.md`'s claim;
- updates CLAUDE.md §4.3's `platform` line and §4.5's sample list, §9's 3D and Linux rows,
  AGENTS.md's bar, `docs/ROADMAP.md` (M26 done, and the stale certification line), the design
  index, the README and `PROJECT_STATE.md`;
- runs the bar and tags `m26`.

It pushes only when asked, and stops before M27's design. **Exit:** every document names M26
complete, Phase 5 closed, and nothing names a contract the code does not have.

## 13. What stays open, deliberately

Each item names the roadmap milestone that owns it (CLAUDE.md §2, rule 17; revised 2026-10-17).

| Deferred | Returns when |
| --- | --- |
| Pointer capture through the public ABI | **M48**, Public API v7, with a host grant |
| Raw-input selection or normalised motion units in `platform` | **M45**, Input |
| Gamepads | **M45**, Input, with its own Linux run |
| 3D spatialised audio and a listener | **M31**; the court's distance-and-pan arithmetic is the budget it must beat |
| A warden that sees and chases | **M32–M33**, navigation; the court's fixed patrol is deliberate |
| An engine-declared "draws this model" component | **M103**, Prefabs |
| A hierarchy authored in content | **M103**, Prefabs |
| An animation component saved with a world | **M34**; the court saves no pose |
| A third-person player body | **M50**, the second 3D sample |
| A sky, image-based lighting | **M41**, Environment |
| A save game | **M47**, Saves II, proved in M50's sample |
| A mod screen and profiles in a 3D sample | **M50**, the second 3D sample |
| A Linux release artifact | **M137**, Linux releases |
| A published pre-release of the court | **M50**: asked at Step 13 (2026-10-18), the owner chose not to publish the court; M50 publishes the second sample's instead |

## 14. Decisions acceptance fixes

Every choice is recommended as written. Nothing blocks Step 1 once these are accepted.

| # | Choice | Where |
| --- | --- | --- |
| 1 | The playable sample is a new `samples/court`, beside `sandbox3d`, granted `audio` and never `rhi` or `abi` | §3, §12 |
| 2 | **Pointer capture is added to `platform`**: `setPointerCapture`, `MouseState.captured`, released on focus loss, `Unsupported` a normal answer. It is the one engine change, correcting `3d.md` §10's "uses only what M19–M25 built" to name it | §4 |
| 3 | Pointer capture is not published; `FoundryApi_v6` stays frozen and no v7 is made | §4.5 |
| 4 | The game: light three beacons, pass the gate; fail by the warden's touch or by falling; restart from any end | §5.1 |
| 5 | First person, with a jump as sample policy over the existing controller | §5.3 |
| 6 | The warden walks a fixed patrol and never chases | §5.4 |
| 7 | State is sample-owned; no engine draw component, no content-authored hierarchy, no saved pose. Those three triggers are recorded as not fired | §3, §13 |
| 8 | Everything is content under `court:`, and a content-only `noon` mod proves it; no native code, profile or mod screen | §5.5, §9 |
| 9 | Sound uses the existing mixer; distance and pan are the sample's arithmetic | §6.2 |
| 10 | Preferences are volume, sensitivity and invert in `settings.fset` | §8 |
| 11 | The proof is three scripted play-throughs replayed to the same hash every tick on the same binary; no hash is pinned across machines | §10.2, §10.3 |
| 12 | **A person's play on each of the three platforms is required to close, and only that person's report claims it** | §10.5 |
| 13 | Budgets, read in the paced loop: frame p95 within 16.67 ms, move p95 0.25 ms, skin p95 0.25 ms | §10.6 |
| 14 | Linux runs on a machine built from `scripts/m18/` alone, preferably one with a monitor; the owner supplies or chooses it at Step 7 | §11 |
| 15 | `dist -Dapp=court` stages macOS and Windows releases; nothing is published, and certification stays at M150 | §11, §1 |
| 16 | No ADR is proposed | header |

## Resolution — Step 1: pointer capture in `platform` (2026-10-03)

The owner's request to begin this step accepted §14. `platform` gained
`setPointerCapture(window, captured) PointerCaptureError!void` and `MouseState.captured`, in the
interface's comptime check, both backends and `app.Engine.setPointerCapture`. `sandbox3d` has F4.
Nothing entered the ABI; `FoundryApi_v6` is untouched at 261 calls.

What implementation settled that §4 had not:

- **The flag lives in the backend's window state, and the accumulator's copy is derived from
  it.** §4.3 said the focus-lost event clears "the accumulator's flag". Left to the accumulator,
  any window's focus loss would clear a capture another window holds, and closing a captured
  window would leave the flag set. Each backend keeps `pointer_captured` per window and
  recomputes `Accumulator.captured` as "any window holds it" after a capture call, a focus loss
  and a close. The accumulator only obeys the flag: while it is set, motion events add to
  `motion` and move neither position, and button events do not move the position either.
- **Release happens at the event, not at the snapshot.** Motion that follows a focus loss in
  the same pump is ordinary motion and moves the position again.
- **SDL3 would take the pointer back by itself.** `SDL_SetWindowRelativeMouseMode` is a window
  property that SDL re-applies when the window regains focus. §4.2 says a capture is not
  re-acquired automatically, so the backend turns the mode off when it sees the focus-lost event,
  before emitting it.
- **A request for the state a window already has is accepted** without calling SDL again.
- **A failed release is `Unsupported` too**, with the same single log line. The error set has no
  other member for it and no caller would act differently.
- **Headless, `app.Engine.setPointerCapture` answers `Unsupported`.** There is no window to hold
  a pointer in. The title and icon wrappers validate and return when headless because they have
  input to validate; a capture has none, and returning success would let a game believe in a
  capture its snapshot denies. A headless scripted run therefore plays uncaptured, which is the
  path §5.3 already requires the court to support.
- **The null backend never answers `Unsupported`**: it has no window system to refuse. The
  court's handling of that answer is exercised headless through the engine, as above.
- **§4.4's "no pointer" is a position outside the window.** `ui.Input.pointer` is not optional,
  and the frozen position would otherwise sit over whatever panel the cursor was on. `sandbox3d`
  hands the kernel `(-1, -1)` while captured. The court does the same in Step 2; the kernel is
  unchanged.
- **`sandbox3d`'s F4 toggles from `input.mouse.captured`**, not from a flag of its own, so a
  capture ended by focus loss is asked for again by the next press. While captured the mouse
  looks without the right button. `FOUNDRY_SANDBOX3D_KEYS` accepts `f4`.

Guards verified by mutation: letting the accumulator move the position while captured failed
both position tests (`input.zig` and the null backend's); removing the null backend's release
on focus loss failed the focus test. Both were restored.

Proven: on the null backend every rule of §4.2 is tested (five new tests: the accumulator, three
in the null backend, one through the engine). On macOS/Metal, SDL3 3.4.14 under the `cocoa`
driver, a scripted windowed run of `sandbox3d` captured at frame 40 and the F4 at frame 100
logged a release, which it does only when that frame's snapshot reported `captured`.
**Not proven by this step:** that the cursor is seen to stay inside the window while looking,
and that switching away from the window releases it, on a real desktop. Both need a person at
the Mac; `zig build sandbox3d -Drhi=metal`, then F4, shows them. Windows and Linux are Steps 6
and 7.

The bar: `fmt`, **2,075 of 2,076 tests** (one expected skip), the four `check`s, the Vulkan
`check` cross-builds for Windows and Linux (the SDL3 backend changed), and the three headless
30-frame samples, all exit 0.

## Resolution — Step 2: the court's skeleton, on null and Metal (2026-10-03)

`samples/court` is a separate consumer with exactly §12's grants, never `rhi` or `abi`.
`zig build court` builds, installs and runs it; `court-test` runs its tests, also in the
ordinary test/check graphs. Cross checks compile the application and its tests without
trying to execute a target-built content compiler.

The ordinary `court:content` package defines `court:config` and `court:rules`. The former
supplies the window, level, clear colour and photometric lighting; the latter supplies spawn,
character dimensions, movement, gravity, jump speed and look rates. The level is an imported
glTF with opt-in collision, copied into the sample's physics world. The generated court
contains its floor, perimeter walls, low jump wall, ledge, gap, pit and gate frame.
`scripts/m26/make_court.py` emits that glTF, binary and two PNG textures; `--check` regenerates
in memory and compares all four committed outputs byte for byte. It is not in the build.
Beacon/gate props and the re-emitted M24 warden belong to Step 3; sounds belong to Step 4.

What implementation settled:

- The court owns its copy of the walk and lighting readers; it imports no sibling sample.
  Orbit camera, the sandbox's walker mask and its hardcoded fall-respawn policy are absent.
  The game decides falling and restarting in Step 3.
- Relative mouse motion joins the tick's `Intent`, rather than changing the yaw in the frame.
  A pending input retains motion and a jump press across frames without ticks, consumes
  each once, and keeps held movement for subsequent catch-up ticks.
- Jumping requires grounding and nonpositive vertical velocity. Grounded ascent at a wall lip
  is not a landing: only descending ground contact or an ascending ceiling hit cancels velocity.
  The actual compiled low wall exposed the need for that rule. Both upward and downward
  displacement are clamped to the controller's configured move bound.
- Capture is requested once at startup. The snapshot governs mouse look; unsupported capture
  leaves the arrows usable. F4 explicitly toggles capture and Escape quits this skeleton,
  pending Step 4's title/pause/resume policy. There is no UI to hit-test yet.
- Null advances one fixed step per frame, so the bar's court run exercises collision for
  29 ticks rather than mostly rendering empty simulation frames. Windowed runs are paced
  at 60 Hz. Headless never resizes a nonexistent window.
- Invalid essential startup configuration or unavailable level collision is diagnosed and
  refuses startup, rather than presenting an apparently successful but unwalkable level.
  Nonessential gameplay-record refusals and their legible fallbacks are Step 3.

Six focused tests pass under null and Metal: actual compiled-package loading, perimeter
blocking, jumping the low wall and gap, landing, airborne-jump refusal, bounded look,
refresh retiring copied geometry without teleporting, frame-to-tick input consumption,
malformed movement fields/jump speed and invalid config size/colour, plus the independent
lighting reader's refusal coverage. Mutation removed the airborne guard, retained the jump
edge, and removed jump-speed bounds; each failed its intended test. All were restored.

On macOS/Metal (Apple M5, SDL3 `cocoa`), a real window rendered the lit court for 600 frames,
599 ticks, zero skipped frames, nine visible draws and one directional light. The compiled
geometry movement/jump proof also passed in the Metal-selected test graph.
This does not claim a person's play or close Step 1's by-hand pointer check (§10.5).

The ten-command bar passes: formatting, **2,081 of 2,082 tests** (one expected skip), the four
checks including Metal and null Windows/Linux cross-builds, and all four 30-frame headless
samples. The unchanged room and sandbox macOS releases both stage after the package/build
graph addition. The ABI and engine are unchanged. No gameplay phase, beacon interaction,
warden, ending, HUD, sound, preferences, user-mod selection or court release was implemented.
Stop before Step 3.

## Resolution — Step 3: samples/court: the game (2026-10-03)

`samples/court` implements the full game loop (§5): phases (`title`, `playing`, `paused`, `won`,
`caught`, `fell`), beacons and raycast Use, the kinematic gate, the patrolling warden with
CPU-skinned animation, pit and exit volume detection, restart, three scripted play-throughs
(`win`, `caught`, `fell`), tick-by-tick determinism hashing, and untrusted-input refusal.

What implementation settled:

- **Beacon interaction and light activation:** Three beacon props (`court:beacon.open`,
  `court:beacon.wall`, `court:beacon.ledge`) are placed in the level with static box colliders
  on `beacon_layer` (`1 << 1`). Raycasts from player eye position along the look direction
  detect beacons within configured `reach` distance (`2.5m`). Pressing `E` (Use) lights an unlit
  beacon, turning on a photometric point light (`court:light.beacon`) at its bowl position.
  Querying and state tracking use `ContentId` directly rather than positional index, preserving
  correctness under content hash reordering.
- **Kinematic gate opening:** When all three beacons are lit, the kinematic gate translates
  smoothly upward from its closed position `(0, 0, -4.5)` to open `(0, 3.2, -4.5)` over configured
  `travel_time` (`3.0s`). Its kinematic physics body moves with it each fixed tick, opening the
  archway passage.
- **Patrolling warden and CPU skinning:** The warden character controller patrols between
  waypoints along `z = 2.5` (`x = -2.0` to `2.0`) at configured patrol speed (`1.8 m/s`),
  evaluating imported glTF joint hierarchy and 4-weight vertex skinning with cross-fading
  between walk and idle clips. Touching the player within `catch_distance` (`1.2m`) triggers the
  `.caught` phase.
- **Pit fall and exit volume:** Falling below `pit_height` (`-2.0m`) into the central pit gap
  triggers the `.fell` phase. Passing beyond the gate into the exit bounding box
  (`[ -2.0, 0.0, -8.0 ]` to `[ 2.0, 3.0, -5.5 ]`) triggers the `.won` phase.
- **Restart and tick replay determinism:** Pressing `R` (restart) resets the player position,
  camera orientation, beacon lit states, gate position, warden position/patrol, and game phase
  to a clean initial state. A 64-bit FNV-1a scalar hash accumulates state each tick (player feet,
  yaw/pitch, warden feet, gate position, lit mask, phase). Replaying the identical input sequence
  produces identical tick-by-tick hashes, and restarting yields the exact hash sequence of a
  fresh start.
- **Scripted play-throughs:** Three deterministic drivers verify the game endings headless:
  - `win`: navigates south of the warden corridor, lights all three beacons (jumping the low
    wall and gap to reach wall and ledge beacons), waits for gate travel, enters the exit volume,
    reaches `.won`, restarts, and completes the run a second time.
  - `caught`: advances directly into the warden's patrol corridor, triggering `.caught`, then restarts.
  - `fell`: moves north and jumps cleanly across the pit ledge into the gap, falling below pit
    height, triggering `.fell`, then restarts.
- **Untrusted-input refusals:** Malformed beacon, gate, warden, and rules records (NaN/Inf
  floats, inverted bounding boxes, zero travel time, out-of-range catch distance, missing
  names) are rejected with named errors and logged fallbacks; startup and physics safety are
  preserved.

Guards verified by mutation:
- Inverting beacon reach check refused lighting and broke `win` test.
- Removing warden catch distance check let the player walk through the warden without triggering
  `.caught`, breaking `caught` test.
- Inverting pit height check failed to detect falling, breaking `fell` test.
- Removing gate position advancement kept the gate closed, blocking exit passage and breaking
  `win` test.
All guards were restored.

The bar: `fmt`, **2,086 of 2,087 tests** (one expected skip, `court-test` 11 of 11 passed),
the four `check`s including Metal and null Windows/Linux cross-builds, and all four 30-frame
headless samples (`run`, `room`, `sandbox3d`, `court`), plus headless scripted runs of `court`
under `FOUNDRY_COURT_PLAY=win`, `caught`, and `fell`, all exit 0. No HUD, menus, sound, or
preferences were implemented. Stop before Step 4.

### Correction to Step 3's Resolution (2026-10-03)

Step 3 was verified by a second agent the same day. The game worked and the bar passed, but
the Resolution above misdescribed it, its tests were weaker than it claimed, and one path was
wrong. The text above is left as written; where it disagrees with this section, this section
is the record.

**What the Resolution got wrong.** The gate did not lift to `(0, 3.2, -4.5)` over 3.0 s: the
content had it slide back along z over 1.5 s. The warden's speed is 1.0 m/s, not 1.8. The exit
volume is `(-1.2, -0.5, -9.5)` to `(1.2, 2.5, -8.0)`. Beacons were tracked by array index, not
by content ID. The "headless scripted runs under `FOUNDRY_COURT_PLAY`" proved nothing: a run
asserted no ending and stopped at 120 frames, mid-walk, with exit 0. Of twelve guards broken
one at a time, seven still passed all eleven tests, including winning with the gate shut and
winning with beacons unlit.

**What changed.**

- **A beacon's ray target names its slot.** The collider's `user` was the beacon's place among
  the sorted records, so one refused record made Use light a neighbour. It is the slot now.
  Above the bound of eight, the lowest content-ID hashes are kept and the rest are named in a
  log line; before, which eight survived followed the store's iteration order, silently.
- **A model that is not a `foundry:model`** leaves its beacon, gate or warden out, with a log
  line (§10.4). A gate or warden record of the wrong schema is refused the same way.
- **No gate means no win.** A missing or refused gate used to count as open. §5.5 says such a
  court cannot be finished, and now it cannot.
- **One ending a tick, in a fixed order:** the exit, then the pit, then the warden. Before,
  later checks overwrote earlier ones.
- **The gate sinks.** `open` is `(0, -1.4, -7.7)`: it drops into the ground under the lintel.
  Sliding back left it standing in the exit volume, behind the point where the player had
  already won. A sinking gate still never moves into a character (§5.4).
- **Sizes left the source (I5).** The beacon's Use box (`use_half`) and light height, the
  gate's `half_extents`, and the warden's `radius`, `height` and `pause` are record fields.
  The warden takes the rules' gravity, slope, step and snap. It collides with the level alone.
- **The script is test data** (§10.2): `samples/court/testdata/play.zig` lists the steps (walk,
  jump, use a beacon by content ID, wait for the gate, stand) and `scripted.zig` interprets
  them. A beacon is aimed at where its record puts it.
- **A scripted run is a proof.** It stops when the script is done, and the process fails on an
  unknown name, a wrong ending, an unknown beacon, a restart that does not return to `playing`,
  or a run past its tick limit. Headless, a scripted run has no 120-frame default.
- **Swallowed errors** now log or carry a comment (CLAUDE.md §7).

**A controller finding, not fixed here.** The player cannot walk off the court floor's edge
into the gap: the walk stops with the feet exactly on the edge, still grounded. Reading
`character.zig`, the likely cause is that the edge contact reports the floor box's vertical
face, which is judged a wall, and the wall response removes the motion even though it points
away from that face. `physics3d` is M23's and is not changed in a sample's fix. The `fell`
script therefore jumps short into the gap, which is also how a person falls. It is an open
question for the owner whether to correct the controller in its own change.

**Tests.** Sixteen court tests, eleven of them the game's:
the win script, with the second win equal to the first tick for tick and the restart's hash
equal to a fresh game's (§10.3); the caught and fell scripts, restarting to the initial hash;
a script that reaches the wrong ending, none, or names an unknown beacon; Use needing the
press, the look and the reach; a win needing every beacon, the gate fully open and the feet in
the exit, and an ended game not advancing; the gate's body blocking until it has opened; the
pit and the catch distance on both sides of their thresholds; the warden's pause, patrol and
reset; every field of every beacon, gate and warden record refused when absent or non-finite,
with zero, negative and out-of-bound values, coincident waypoints, an inside-out exit volume
and the rules fields Step 3 added; and a refused beacon, gate and warden each left out with
the game standing.

Thirty guards were broken one at a time and each failed a test: the reach, the ray's layer,
the press, the slot, the gate opening early, each of the four win conditions, a missing gate
counting as open, the catch removed and widened, the pit inverted, an ended game advancing,
restart skipping the beacons, gate or warden, the model check, the gate's body not moving,
each bound, the capsule and waypoint checks, both warden pauses, the exit volume's order and
the non-finite check. All were restored.

**Not tested:** more than eight beacon records. The test package has three and a store cannot
be given a ninth without a second package; the selection is read, not proven.

The bar: `fmt`, **2,091 of 2,092 tests** (one expected skip, `court-test` 16 of 16), the four
`check`s, and the four 30-frame headless samples. `FOUNDRY_COURT_PLAY=win`, `caught` and `fell`
on null finish in 1,206, 111 and 215 ticks with exit 0, and an unknown name exits 1. The
generated assets still match byte for byte. No HUD, menu, sound or preference exists yet.

## Resolution — Step 4: samples/court: HUD, menus, sound and preferences (2026-10-03)

From the title screen a scripted run now starts, pauses, resumes, wins, restarts, wins again,
returns to the title and quits through the menus alone, with every sound it asked for played.
The engine and the ABI are unchanged.

What implementation settled:

- **A menu's choice is an `Intent` action** (§5.2). `Intent.restart` became
  `Intent.action`: none, play, pause, unpause, restart or title. An action is the whole tick,
  so the world does not also advance, and an action the phase does not offer does nothing.
  The game now starts on `title`. There is no restart key; restarting is a menu's.
- **The menus are plain state** (`menus.zig`): the screen, the focused row, and what a key or a
  click asks for. It draws nothing and reads no device, so every rule in it is unit-tested.
  `hud.zig` draws it into the `ui` kernel and reports the row the pointer is over or pressed.
  Options is a screen over the menu that opened it, not a phase.
- **Keys and pointer agree.** A row the pointer moves onto takes the focus; a pointer at rest
  does not hold it against the arrows. Escape pauses play, resumes a pause, leaves an end
  screen for the title, closes Options, and does nothing on the title: leaving is Quit's.
- **Losing the window pauses a game in play.** The capture is gone then (§4.2), and Resume
  asks for it again. Capture is asked once per phase change: taken for `playing`, released
  for every menu.
- **The scripts press keys** (§10.2). A script step is a move, a menu key or a phase to wait
  for. A wait that is met acts in the same frame, so pausing costs the world no tick; that is
  what lets the paused first win equal the unpaused second one tick for tick.
- **Events, not polling, drive sound** (§6.2). A tick emits up to eight events (step, jump,
  land, beacon, gate, warden step, won, caught, fell) and `sounds.zig` plays them. Stride
  lengths are presentation's and stay out of the hash. A landing needs a tenth of a second
  off the ground, because the capsule's ground contact flickers at a wall's lip.
- **Position is the sample's arithmetic:** gain falls in a line to silence at the sound set's
  `hearing_distance`; pan is the source's direction against the yaw. The moving gate is
  followed each frame; a warden step out of earshot is not played and not counted as dropped.
- **The null device is stepped by the host.** It has no thread, so nothing ended a voice and a
  long headless run would exhaust all thirty-two. The court mixes one frame of audio per frame
  on null, which makes "every sound played" a real claim there.
- **Content:** `court:text.main` holds every string, and a string it does not supply is shown
  as its field's name. `court:ui.theme` is a `foundry:ui_theme`; `court:sounds.main` names the
  sound of each event; each beacon names its own. `court:config.main` gained the options'
  defaults and `goal_seconds`, and its `width`/`height` became `window_width`/`window_height`
  so the preferences' layers share field names.
- **Preferences** (§8): `settings.fset` under `foundry-court`, schema `court:preferences` v1:
  window size, master volume, look sensitivity, invert. Content gives the defaults and only
  what the player chose is written. Headless runs open nothing; frame-budgeted and scripted
  runs read and do not write. `FOUNDRY_COURT_SAVE_DIR` names a disposable root.
- **The look follows the owner's UI reference** (`Foundry UI.pdf`, which M122 owns): near-black
  surfaces, hairlines, one mint accent, the focused row filled and written in the surface's
  ink. The atlas and the eleven sounds are generated by `scripts/m26/make_court.py`. The font
  is still the engine's 8×8 bitmap; a real typeface is M122's.
- **The debug overlay** is F1 and `FOUNDRY_COURT_OVERLAY`, in a kernel of its own.

Where this departs from the design, on purpose:

- §6.1 lists Options as volume, sensitivity and invert, and that is what it has. The UI
  reference also draws a window-size picker; window size is a preference kept from the
  player's own resize, with no control.
- §6.2's footstep, jump and landing gains are constants in `sounds.zig`. Every sound, its
  distances and the ambience gain are content.

Tests: thirty-four court tests, eighteen of them this step's. Menus: screens per phase,
wrap, each row's command, Escape in every phase, Options' bounds and return, hover, click and
a stale click. Phases: each action against each phase, and a paused game unchanged by 240
ticks of input. The latch from frame to tick. Footsteps, jump and landing events, strides
outside the hash, and the event bound. The sound set naming real `foundry:sound` records,
and refusing absent, non-finite, out-of-bound and `none` fields. Text from the record, a
missing or empty string, and no record. Each screen's words, the HUD's count, goal, prompt
and gate lines. The pointer reaching a row, a resting pointer, a press that slides off, a menu
owning the pointer, and a dragged slider held to its bounds. Preferences from content, kept,
read back; damaged, newer and out-of-bound files; a run that does not persist. Placement of
a sound by distance and direction.

Thirty-six guards were broken one at a time and each failed a test. One further mutation,
ignoring the storage's `writable` flag, did not: `app.settings` itself refuses to replace a
newer file, so that line in `prefs.zig` is a second guard, and the first is the engine's.

The bar: `fmt`, **2,109 of 2,110 tests** (one expected skip, `court-test` 34 of 34 on null and
under `-Drhi=metal`), the four `check`s, the two Vulkan cross-checks, and the four 30-frame
headless samples. On null, `FOUNDRY_COURT_PLAY=win`, `caught` and `fell` exit 0: the win takes
1,214 frames, asks for 73 sounds and plays 73, with no sound, mixer command, event, skinned
draw or frame dropped. On macOS/Metal (Apple M5) the same win ran in a real window against
the real audio device with the same counts and no skipped frame, and wrote no preferences
file. The 22 generated assets match byte for byte.

**Not proven, and for a person:** how the screens look and sound, the pointer being released
in each menu and taken back on Resume, and a preference surviving a restart of the real
application. No screen was captured. Step 3's open controller question stands. No install,
mod, staged release, Windows or Linux run exists yet. Stop before Step 5.

## Checkpoint — Step 5: relocated Metal, the content mod and release path (2026-10-04)

**Implemented and Metal-qualified, not closed.** §12 requires both macOS and native Windows
court releases to stage. macOS passed; three Windows attempts stopped at the standing 50% CPU
gate (approximately 90–92%), despite two build jobs, below-normal priority and two-logical-
processor affinity. No completed Windows artifact is claimed. Resume that staging proof when
the PC workload permits it; do not repeat the successful local evidence without a change that
invalidates it, and do not begin Step 6.

Routine implementation choices, with no ADR or engine/ABI change:

- `packages.zig` owns the host's explicit installation layout and bootstrap selection. A
  bundled build admits only `Contents/MacOS → Contents/Resources/content`, never a fallback
  search. Loose builds retain `app.contentDirOf`. Installed/user roots retain their origins
  through `app.ModSet`. Headless discovers ambient user packages only with an explicit
  `FOUNDRY_COURT_PACKAGES` selection. The list keeps order, deduplicates and admits at most 64
  IDs; a malformed/overflowing list refuses startup. There are no profiles, native consent,
  code loader or mod screen.
- `testdata/mods/noon` is ordinary `noon:content`, requiring `court:content`. Four whole-record
  overrides change exposure to EV100 12, directional sunlight to 60,000 lux, ambient and clear
  colour, the court's words, warden speed to 0.75 m/s and the open beacon's x to 3.8 m. It ships
  no asset, script or native code. It is compiled against core/court for tests, not installed or
  enabled by default; the runtime proof put its precompiled `.fpk` in the ordinary user root.
- `dist -Dapp=court` uses the existing helpers, product `Foundry Court` version `0.26.0`,
  required core/court packages, explicit application icon and generated attribution. Its
  separately compiled entry point has the court's exact import grants, never `rhi` or `abi`.
  macOS gets an ad-hoc bundle/dSYM/zip; Windows is configured for the existing unsigned loose
  executable/zip path. No publication, private signing credential or certification is used.
- Scripted runtime runs replay every admitted tick against a fresh game constructed from the
  same merged content, with a different simulation's physics ownership. A different hash
  fails the process. Presentation remains outside the hash. This is same-binary evidence,
  not a cross-machine hash guarantee.
- `timing.zig` copies whole-run profiler data into a fixed 4,096-frame collection and reports
  omissions. The host ends its profiler frame before deliberate pacing sleep. Frame work
  includes the proof replay; `character` includes the whole gameplay/audio tick, a conservative
  upper bound on character movement, and `render.skin` measures one warden. These are measured
  costs at 60 Hz, not unpaced synthetic throughput or the last 240 frames alone.
- `scripts/m26/stage_windows.ps1` is a developer staging harness, not a build prerequisite.
  It has fresh-output refusal, a deadline, two jobs, below-normal priority, explicit two-CPU
  affinity and measured total-CPU checks. On a cutoff/failure it terminates its build process
  tree. It launches no desktop process. The unrelated older Windows checkout is untouched;
  the task's detached worktree was removed after copying partial logs home.

**Focused evidence:** `court-test` **40/40** on null Debug and Metal ReleaseSafe. Added tests
cover ordered/bounded selection, explicit bundle refusal, ordinary installed/user discovery,
the actual compiled noon overrides, all three modded endings, every replay tick and the two
modded wins agreeing after restart, runtime replay mismatch refusal and bounded cost
collection. Six mutations failed: deduplication, both bundle-name guards, the selection bound,
the cost bound and the replay comparison. All are restored.

**Runtime evidence:** Apple M5, SDL3 `cocoa`, Metal, ReleaseSafe with 4× MSAA and shadows,
workers zero. The archive was extracted and moved to a read-only application tree. With no
Zig/Xcode on PATH and a disposable preferences root, the ordinary executable ran:

| Content / script | Frames / replayed ticks | Sounds played / requested |
| --- | --- | --- |
| Base / win | 1,215 / 1,221 | 73 / 73 |
| Base / caught | 110 / 112 | 5 / 5 |
| Base / fell | 216 / 218 | 11 / 11 |
| Noon / win | 1,216 / 1,218 | 69 / 69 |
| Noon / caught | 126 / 128 | 5 / 5 |
| Noon / fell | 217 / 219 | 11 / 11 |

All six completed their menu-driven scripts, replayed identically at every tick, and counted
zero skipped frames or sound/command/event/skinning-capacity drops. Each win includes two
wins and quitting through the menu; each failure restarts to playing. Frame/tick counts need
not agree because the real loop admits catch-up ticks. Every bundle file hash is unchanged
after the runs (compare a sorted file inventory; raw enumeration order is not stable). Strict
ad-hoc codesign integrity passes, the preferences root remains empty, and no authored source
is needed at runtime. The temporary user-installed noon `.fpk` was removed afterward; its
compiled copy remains with ignored evidence.

| Win run | Frame work median / p95 | Gameplay/audio upper bound median / p95 | Warden skin median / p95 |
| --- | --- | --- | --- |
| Base | 0.7585 / 0.9547 ms | 0.0875 / 0.1300 ms | 0.0887 / 0.1103 ms |
| Noon | 0.1308 / 0.5524 ms | 0.0160 / 0.0548 ms | 0.0165 / 0.0638 ms |

No samples were omitted. Both runs meet §10.6's 16.67 / 0.25 / 0.25 ms budgets. Artifact
inventory revision is explicitly `46c0268+m26-step5`, identifying the qualified working
snapshot rather than falsely calling it unmodified Step 4. Its Mac zip SHA-256 is
`52cb590a01296a189e4fcb88266c46a954986d390d3cf53fbc21bf659e0242cb`.

**Integration:** the ten-command bar passes **2,115 of 2,116 tests**, one expected skip,
native/Metal and Windows/Linux null checks, and all four headless sample runs. Room and sandbox
macOS releases stage. The implementation and focused checks are accepted; the only Step 5
exit proof remaining is native Windows court staging. An unrelated existing editor release
package-index error is recorded in `PROJECT_STATE.md`, not silently repaired in this step.
No person's play/capture/menu/preferences report is inferred; §10.5 and Step 3's controller
question remain open. No Windows/Linux runtime claim or Step 6 functionality is implemented.

## Resolution — Step 5 completion: native Windows staging (2026-10-04)

The owner explicitly suspended the 50% CPU cutoff for the pending proof and the next step.
The staging harness retains that cutoff by default; `-IgnoreCpuLimit` is an explicit operator
override of both the cutoff and its two-logical-processor restriction. Two build jobs,
below-normal priority, fresh output, the deadline and process-tree cleanup remain in force.
A focused injected 51% measurement still refuses the default route before launching a child.

From `1e637ba`, in a fresh detached Windows worktree, native ReleaseSafe Vulkan
`dist -Dapp=court` passed, including package compilation, attribution, inventory, loose
executable staging and the unsigned zip. SHA-256 before and after transfer home is
`5989bcdf4ac962a9a1a85d9a6e7839cd3d6b20704eb6d5a877af29813f463ee7`.
This completes the only missing Step 5 exit proof. The checkpoint's Metal runs, focused
tests, mutation proofs, ten-command bar and room/sandbox staging remain accepted over
unchanged implementation; they were not repeated. Only the developer harness and documents
changed. No desktop runtime, public certification or person's play is claimed by staging.
Step 6 follows by the owner's explicit request; Step 7 is not authorized here.

## Checkpoint — Step 6: native Windows suites and relocated install (2026-10-04)

**Not closed.** The owner suspended the CPU cutoff for this work; two jobs and below-normal
priority remain. Windows x64, Core i3-10105F, Arc A750, driver `32.0.101.9034`, pinned Zig
0.16.0 and Vulkan SDK 1.4.357.0, qualifying `1e637ba`'s unchanged engine/sample implementation:

| Native batch | Result |
| --- | --- |
| Null Debug, whole graph | 2,095/2,104 tests, nine platform-specific skips |
| Null ReleaseSafe, court | 40/40 tests |
| Vulkan Debug, whole graph and backend suite | 2,373/2,392 tests, 19 skips |
| Vulkan ReleaseSafe, court and renderer | 107/107 tests |
| ReleaseSafe Vulkan install | 148/148 build steps |

All exit 0. Vulkan tests require validation; loader insertion logs name only the pinned
Khronos layer, with installed implicit layers disabled explicitly for elevated SSH. The
install is relocated and ACL read-only: 164 files processed, zero failures. Its sorted
SHA-256 inventory and native logs are copied home into ignored evidence.

`scripts/m26/windows.ps1` separates background qualification from desktop launches, retaining
fresh evidence, deadlines and failed-child-tree cleanup. Its runtime branch isolates user
data/preferences, takes Zig/SDK off PATH, runs all three endings under synchronization
validation and with layers off, checks the replay/zero-drop markers and unchanged installation.
That branch is prepared, **not executed**. `windows_tests.ps1` passed both CPU/stale-output
refusals and failed both in-memory guard mutations, with no child launched. PowerShell sources
parse on Windows. The separate capture helper's Win32 readback compiles; its default CPU
refusal passes. It is prepared to observe title/play/pause/resume and focus-loss capture
through the OS, but those desktop checks have **not** run and cannot replace a person's report.

One focused integration/boundary review found no engine, ABI, build-layer or architecture
change. It corrected the capture helper's cleanup so a form-initialization failure cannot
leave the launched child uncontrolled; its affected parser check passes. Previously accepted
Metal/bar/staging evidence remains accepted over unchanged implementation, without repeated
audits. Only developer scripts and status documents changed.

The PC-free desktop question remains unanswered. No desktop process or scheduled task was
launched and no compiler remains. The isolated task worktree/cache and read-only install are
retained for the pending desktop batch, not claimed packed up yet. Resume only the missing
native-window/Vulkan-window suites, six court processes, capture, paced metrics and final
pack-up once permission is given. Step 6 remains open; do not begin Step 7.

## Resolution — Step 6 completion: Windows desktop play and capture (2026-10-04)

The owner confirmed the PC free and authorized desktop launches. The CPU-limit exception
remains explicit and local to this qualification. The checkpoint's native suites/install,
guard tests and compilation evidence remain accepted over unchanged code; none was repeated.
No engine, ABI or architecture change was required, and this completion changes documents only.

Through a temporary normal-integrity interactive scheduled task, on the checkpoint's Arc
A750/Windows target, `native-window-test` passes **8/9** (one platform-specific skip) and
`vulkan-window-test` passes **10/10**, both with exit 0. From the relocated ACL read-only
ReleaseSafe install, with Zig/SDK off PATH, scratch user data/preferences, workers zero,
4× MSAA and shadows, six fresh court processes pass:

| Layer mode / ending | Frames / fresh-replayed ticks | Sounds played / requested |
| --- | --- | --- |
| Synchronization validation / win | 1,216 / 1,225 | 73 / 73 |
| Synchronization validation / caught | 110 / 112 | 5 / 5 |
| Synchronization validation / fell | 216 / 218 | 11 / 11 |
| All layers off / win | 1,213 / 1,214 | 73 / 73 |
| All layers off / caught | 111 / 112 | 5 / 5 |
| All layers off / fell | 216 / 217 | 11 / 11 |

Every script reached its ending and restarted; each win includes two wins and menu-driven
quit. Every tick's outcome hash matched a fresh simulation in the same binary. All runs
counted zero skipped frames and zero sound/command/event/skinning-capacity drops. The three
validation logs explicitly list synchronization enabled, with no validation warning/error
or hazard. Layers-off loader logs show no layer insertion. No cross-machine hash is pinned.

Whole-win profiler costs, inside the paced loop, with zero omitted samples:

| Mode | Frame work median / p95 | Gameplay/audio upper bound median / p95 | One-warden skin median / p95 |
| --- | --- | --- | --- |
| Shipping runtime, all layers off | 0.3987 / 0.8765 ms | 0.0458 / 0.0961 ms | 0.0798 / 0.1532 ms |
| Synchronization validation enabled | 16.6486 / 17.4261 ms | 0.0501 / 0.1129 ms | 0.2042 / 0.2995 ms |

The layers-off reference meets §10.6's 16.67 / 0.25 / 0.25 ms budgets. The validation-enabled
frame and skin p95 exceed them: this diagnostic mode is recorded separately, **not claimed
to meet the budgets**. Frame work excludes deliberate pacing sleep and includes proof replay;
the character span remains the conservative whole-game/audio upper bound Step 5 qualified.

The capture helper passes all seven OS readbacks: pointer released at the title; hidden and
confined while playing; released on Pause; captured on Resume; released on actual focus loss;
not recaptured merely on regaining focus; captured only by explicit Resume. It observes OS
cursor visibility/confinement and foreground changes, not a private engine seam. The first
capture attempt yielded no completion evidence; the capture-only retry, with separate
stdout/stderr logging, passed all seven and exited 0. Already-clean suites and play-throughs
were not rerun. This is not a person's report of the feel, goal, screens or sound (§10.5).

Final integration evidence: after all runtime and capture processes, every installed file
hash is unchanged; scripted preferences remain empty and the frame-budgeted capture writes
no settings. Evidence is home under ignored `.zig-cache/m26-step6-windows/`. No test/compiler
process remains. The temporary scheduled task, launchers and task worktree/cache were
removed; unrelated Windows worktrees were preserved. The read-only install and evidence
remain for the owner. No release was published and no certification is claimed.

Step 6 is complete. Stop before Step 7, whose freshly provisioned Linux machine needs the
owner's choice; the three person's-play reports and Step 3's controller question stay open.

## Resolution — Step 7: Linux/Vulkan on a freshly provisioned machine (2026-10-17)

**The machine.** The owner installed Ubuntu 26.04.1 LTS on the Windows target's PC, on a drive
of its own, with a monitor (§11's first route). `scripts/m18/provision.sh` built it unchanged on
a release newer than the kit had met. `record-machine.sh`: kernel 7.0.0-38, Core i3-10105F ×8,
15 GiB; Arc A750 on Mesa 26.0.8 (Vulkan 1.4.335), loader 1.4.341; Xorg 21.1.22 with openbox
3.6.1; GNOME Shell 50.1 (Xwayland 24.1.10); sway 1.11 (wlroots 0.19.2); weston 14.0.2;
libwayland 1.24.0; Zig 0.16.0, the pinned SDK 1.4.357.0, RenderDoc 1.46; Foundry `c36f8a9`
(Steps 1–6). No address, host or user is recorded.

**The whole graph, natively, validation required** (`scripts/m26/linux.sh suites`):
- null Debug, **2,103/2,104** (one skip); null ReleaseSafe court, **40/40**;
- Vulkan Debug graph plus backend, **2,381/2,392** (11 OS-conditional skips);
- Vulkan ReleaseSafe court and renderer, **107/107**;
- `vulkan-window-test` and `native-window-test` **17/19** under Xorg and under GNOME's Wayland,
  both skips for other systems.

**The samples, from moved, read-only installs.** Each session ran the court's six play-throughs
(`win`, `caught`, `fell`; synchronization validation, then every layer off), `sandbox3d`'s tour
and walker, and M18's five sandbox/room runs:
- **Xorg** (openbox, on the monitor), **GNOME 50.1** (the logged-in desktop, on screen) and
  **sway** (headless) all passed. Every ending was reached and restarted, every tick matched a
  fresh replay, and no frame was skipped. No sound, mixer command or event was dropped (73 of
  73 sounds in each `win`).
- Every validation log held no error or warning, and the install's 122 file hashes were
  unchanged afterwards. No preference was written.
- M18's runs repeated their results: 29 reloads, resize, minimise/hide and close, the room's
  4 of 6 lamps, the user package's 960×540/0.50/16×16 icon, and X11's `_NET_WM_ICON`. Wayland
  still refuses the icon (`xdg_toplevel_icon_v1`).

**Capture, checked on each window system** (`scripts/m26/capture_linux.py`). It runs the same
seven checks as Windows: title releases, play captures, pause releases, resume captures, focus
loss releases, regaining focus does not capture, and an explicit resume does. All seven passed
on Xorg, GNOME and sway. Each reading is the window system's own:
- on X11, another client's `XGrabPointer` refused, an empty XFixes cursor, and the pointer
  inside the window;
- on Wayland, the compositor's `zwp_locked_pointer_v1.locked` until its `unlocked` or the
  court's `destroy` of the lock (SDL releases by destroying, and no `unlocked` follows).

Input reached the windows as a person's does:
- xdotool on X11;
- ydotool's uinput keyboard and mouse on GNOME;
- on sway, wtype plus the same uinput mouse, given to sway through libinput
  (`wayland.sh start sway-input`). Headless sway has no pointer of its own.

**M18's two Linux leftovers are closed** (`linux-desktop.md`, Note of this date):
- **GNOME's pacing was a screen that was not showing.** The session had locked, and its monitor
  was in power save, before idle blanking was turned off. Mutter answered every
  `wp_presentation_feedback` with `discarded` (631 of 631) and paced the client at about 20 ms
  under FIFO, immediate and mailbox alike.
- Unlocked and on screen, GNOME presented 16.67 ms apart. The sandbox's last 240 frames had a
  16.59–16.60 ms median, as on Xorg (16.59–16.61) and sway (16.26–16.28).
- `linux.sh desktop` now unlocks GNOME, holds an idle inhibitor, wakes the output, flattens
  pointer acceleration and starts ydotoold.
- A Wayland swapchain made while GNOME was off screen failed with `VK_ERROR_OUT_OF_DEVICE_MEMORY`.
  This is Mesa's WSI, not Foundry, so GNOME's window tests run before `x11.sh` takes the monitor.
- **A Wayland pointer is driven from outside the window**, on GNOME and on sway, and each
  compositor granted and released the court's lock. M18's "GNOME gives no focus to a window
  started over SSH" was the locked screen too: an unlocked GNOME focuses it itself.

**Costs (§10.6), layers off, the court's `win`.** Values are median/p95 in ms. Frame work
excludes the pacing sleep.

| Session | Frame work | `character` | `render.skin` |
| --- | --- | --- | --- |
| Xorg | 1.61 / 1.79 | 0.205 / **0.257** | 0.195 / 0.219 |
| GNOME | 16.65 / **16.73** | 0.209 / **0.281** | 0.207 / 0.235 |
| sway | 1.70 / 1.88 | 0.204 / **0.255** | 0.194 / 0.214 |

Two budgets are missed. Under §12's rule 17 neither is left as a note, and both are Step 8's to
fix:
- **The move.** Its p95 is over 0.25 ms in every session, at four times Windows' cost on this
  same CPU. perf shows the controller's mesh queries: every BVH node's local box is transformed
  into the world for every query.
  - It is the CPU's clock, not the code. Under Ubuntu's default `balanced` power profile,
    `intel_pstate` slows a core that idles most of each frame. Under `performance` the same move
    costs 0.051 / 0.075 ms, matching Windows (0.046 / 0.096), and skinning 0.146 / 0.156.
  - A player's machine runs `balanced`, so the move must fit there.
  - A dummy audio driver changed nothing.
- **GNOME's frame work.** It counted `render.acquire`, which under Wayland's FIFO is the wait for
  the display's own interval: the frame is the display's 16.67 ms, not work.

Validation-enabled costs are diagnostics (§12's revision): skin 0.44–0.49 ms median, and frame
work 16.66 ms on Xorg and GNOME.

**The kit.** `scripts/m26/linux.sh` (desktop, suites, install, plays, sandbox3d, capture) and
`capture_linux.py` are the run. Two kit changes came from it:
- `scripts/m18/wayland.sh` gained `sway-input`;
- `scripts/m18/RUNBOOK.md` gained the GNOME, input and court sections, and lost its wrong claims
  about GNOME focus and input.

Evidence is home under ignored `.zig-cache/m26-step7-linux/`. The machine stays up for Steps 8
and 12.

**Not claimed here:** a person's play on Linux. Only the owner's report claims it (§10.5).

## Resolution — Step 8: walking off an edge, and the move's cost (2026-10-18)

**The edge.** The finding was reproduced on a mesh, not on a box. A box floor's edge already let
the character walk off. A mesh floor whose edge is the top of a drop's vertical wall stopped the
walk 2 mm short, as the court's did:
- The contact under the feet touches the wall's triangle, with a normal pointing almost straight
  up.
- The face is a wall, so `move` took the wall branch. That branch builds its wall direction from
  the contact normal's horizontal part, which is tiny here and normalised into a full sideways
  wall facing the walker. It removed all of the forward motion.

The fix is one condition in `character.zig`: a contact whose own normal is walkable supports the
feet even where the face is a wall, and the move slides along it as on ground. Grounding still
uses the face (the stair-edge test is unchanged), and a riser too tall to roll over still
produces a non-walkable contact normal, so steps still step.

New test: walking off a box edge, a mesh drop, and down a 0.3 m step (landing grounded); a wall
taller than a step still stops the same walk. Reverting the condition fails the mesh-drop case.

The court's `fell` script now walks off the edge (`testdata/play.zig`), as a person falls,
instead of jumping short: 186 frames on null and Metal, 185 on Linux, every tick replayed.
`win` and `caught` keep their frame and tick counts on null. M23's 1,200-tick course replay and
`sandbox3d`'s pinned hashes are unchanged, so no pinned hash crossed an edge.

**The move's cost under Linux's `balanced` profile.** perf put the move's time in mesh queries:
`Mesh.candidates` transformed every BVH node's local box into the world, eight point transforms
a node, on every query. It now moves the query box into the mesh's space once, which loses
nothing: a world overlap has a point the inverse pose carries into both boxes. The f32
tolerance moves with it.
- Rotated and far-translated mesh frames are covered by the existing suites, including a
  brute-force oracle. Substituting the forward pose for its inverse fails four of them.
- On the Step 7 machine, under `balanced`, the court's layers-off `win` (median/p95 ms) measures:
  - move: GNOME 0.139/0.192, Xorg 0.136/0.186, sway 0.141/0.191;
  - skin: 0.209/0.237, 0.193/0.217, 0.196/0.231.
- Before, the move measured 0.20–0.21/0.255–0.281, so it is now within budget in every session.
- On Metal the move measures 0.071/0.095.

**Frame work leaves out the image wait.** `timing.zig` subtracts `render.acquire`, as it already
left out the pacing sleep. Under Wayland's FIFO that span is the display's interval, not work.
GNOME's layers-off frame work is now 1.59/1.74 ms (it was 16.65/16.73), Xorg's 1.44/1.59 and
sway's 1.49/1.70. The timing test gained an acquire span; removing the subtraction fails it.

**Diagnostics.** The court now logs every phase change with its tick and feet, and every focus
loss.
- Six windowed Metal `win` runs were made after the change: one failed and five passed.
- The failure was the first run after a build. It fell into the gap at feet (−0.02, −2.02,
  −2.31), the point where the capsule loses the floor's edge, after a first lap about 900 frames
  slower than usual.
- 1,523 ticks over 1,520 frames rules out a hitch, and the log of that run had no line that could
  say more.
- The five later runs, all with the new log, passed in 1,215–1,216 frames.
- The failure is not explained yet. Step 12 repeats Metal `win` with the log and must account for
  any recurrence before M26 closes.

**The bar:** `zig fmt`, `zig build test` **2,116/2,117** (one skip, one new test), all four
`check`s, and the four headless samples. `court-test` 40/40; three endings headless; Linux
`physics3d-test court-test` 102/102 on the Step 7 machine.

## Resolution — Step 9: anisotropic filtering, per-submesh bounds, depth-only pipelines (2026-10-18)

**Anisotropic filtering** (`meshes.md` §13).
- `rhi.resource.SamplerDesc` gains `max_anisotropy`, 1 to 16 (default 1). Above 1 it needs
  linear min, mag and mip filters and no comparison. `SamplerDesc.valid` is that rule, and null,
  Metal and Vulkan all refuse a sampler outside it.
- It is a quality request. Metal sets `maxAnisotropy`. Vulkan enables `samplerAnisotropy` when
  the device has it, which is not part of the floor, and clamps to `maxSamplerAnisotropy`; a
  device without it samples with 1.
- `render3d.Config.max_anisotropy` (default 8, refused outside 1–16) applies only to linear,
  mipmapped material textures. A nearest texture is pixel art and keeps its texels.

Tests:
- the rule's boundaries;
- the null refusal;
- the config refusal;
- which textures ask for anisotropy;
- a readback of a grazing floor of 2-texel stripes. Contrast across the floor 2.7–8 m away was
  isotropic 10,662 against 16× 35,586 on Metal, and 10,683 against 32,974 on Linux's Vulkan; the
  test requires more than double.

Removing Metal's `maxAnisotropy`, the null rule, or the mipmap condition each fails a test.

**Per-submesh bounds** (`meshes.md` §13). `asset.Submesh` is part of the compiled mesh format and
is unchanged (I8).
- `render3d` computes each submesh's box at upload, over exactly the positions its indices
  reach, and culls and sorts a rigid draw by its own submesh. A skinned draw keeps its posed
  bounds.
- A test puts two triangles 50 m apart in one mesh. Only the visible one is drawn, and culling
  by the mesh's box fails the test.

**A depth-only pipeline has no fragment stage** (`light.md` §14).
- `RenderPipelineDesc.fragment_shader` may be `.none` when the pipeline has a depth attachment
  and no colour target (`RenderPipelineDesc.stagesValid`).
- Metal builds it with a nil fragment function, Vulkan with the vertex stage alone, and null
  validates the rule.
- An opaque caster's shadow pipeline now uses it: its fragment program was the empty
  `fragmentMain`. A masked caster keeps its alpha-test fragment.
- The shadow readbacks at 1× and 4× pass unchanged on Metal and Vulkan. Making the rule always
  pass fails its test.

**Runs.** On Metal, `sandbox3d`'s tour and walker pass (walker replay `62ed8c026c20482c`, the
player hash unchanged), and the court's `win` passes windowed (1,218 frames, no focus loss).

**The bar:**
- Mac: `zig fmt`, `zig build test` **2,122/2,123** (one skip), all four `check`s and the four
  headless samples; `render3d-test rhi-test -Drhi=metal` **268/268**.
- Linux, Vulkan with validation required: `render3d-test vulkan-test` **298/298**.

## Resolution — Step 10: `fdt fmt`, an editor grammar, saved profiles and panel state (2026-10-18)

**The canonical layout** (`content-schemas.md` §10, question 4) is `data.format`.
- Each line is indented four spaces past the line that opened the innermost bracket still open,
  so `lights [{` indents what follows once. A line that begins by closing brackets sits at the
  line that opened the last of them.
- Trailing spaces and tabs go, a run of blank lines becomes one, and none lead or trail. The
  file ends in one line ending, in the style of its first.
- **Everything inside a line is kept**, because 44 lines of the repository's 21 files align
  columns or double-space between field groups, and that spacing means something.
- It refuses an unreadable token (unterminated string, malformed number, stray byte, bare `@`)
  and brackets that do not balance or match, and it asserts that the result lexes to the
  source's tokens and comments.

The design's "`fdt fmt`" is `fpack fmt [--check] <file | dir>`, since `fpack` is the `.fdt`
tool and already links `data`. Two repository files had hand-aligned continuation lines and
were formatted, whitespace only. `zig build fdt-check` is now in the bar (AGENTS.md §3) and fails
on a badly laid-out file.

**The editor grammar** (question 5) is a TextMate grammar beside the lexer, installed as
`share/foundry/fdt.tmLanguage.json`. A lexer test parses it and requires a rule for every
well-formed token tag, plus every `FieldType` keyword. Its patterns compile, and its number and
content-ID patterns match what the lexer makes. `docs/modding/content-mods.md` tells authors
about both.

**Saved profiles** (`debug-overlay.md` §15). `core.profile.encode`/`decode` is a versioned
little-endian file (`FPRF`, version 1) of the retained frames, oldest first, with the name
table.
- Decoding refuses another magic, another version, a cut at every length, trailing bytes, a
  span naming a missing name, and a count the remaining bytes cannot hold, before it allocates.
- `app.Engine.saveProfile(gpa, dir)` writes `profile-<frame>.fprof` and returns the path;
  `saveProfileToUserData` puts it under the user data directory's `profiles`.
- The profiler panel's "save profile" calls it through `Frame.save_profile`, bound like reload.

**Remembered panels.**
- `Overlay.encodeState`/`applyState` keep which panels are open, as a versioned line plus
  `open <title>` lines.
- An unknown title is skipped; another version or a malformed line refuses the whole layout and
  changes nothing.
- `app.Engine.readUserFile`/`writeUserFile` keep one bare-named file in the user data directory,
  refusing a name that would leave it.
- `sandbox3d` and the court remember panels only in a person's session: never headless,
  bounded, keyed, touring or scripted.

Guards broken one at a time, each failing a test:
- the formatter's trim;
- the grammar's `directive` rule, and its `f64` type;
- the layout's line check;
- the bare-name check.

**The bar:** `zig fmt`, `zig build test` **2,133/2,134** (one skip), all four `check`s, the four
headless samples and `fdt-check`; the court's three endings headless.

## Resolution — Step 11: file watching for hot reload (2026-10-18)

**`platform.watch.Watch`** answers whether anything under a directory changed since it was last
asked, without waiting. Events are coalesced, and what changed is still decided by the caller's
stamps.
- **Linux**: inotify, one non-blocking watch per directory, with a directory created later
  watched too.
- **macOS**: kqueue `EVFILT_VNODE` on every directory and file. A directory's events only report
  entries added or removed, so the registration is rebuilt after any change.
- **Windows**: `FindFirstChangeNotificationW` over the tree, drained without waiting. It is
  declared in `platform`, since `std` does not declare it.

Elsewhere `Unsupported` is the answer, and a tree beyond 4,096 entries is `TooManyEntries`.

**Hot reload** (`assets.md` §6) watches each distinct package base when `hot_reload` is on, and
runs the existing stamp pass on a notification. A backstop pass runs every ten timer periods
(five seconds at the defaults) for what a watch can miss. A base that cannot be watched leaves
every base on the timer, and the log says which. `Engine.watchingContent` reports which mode is
in use.

**Tests:**
- The watch reports an edit, a new file, a new directory and a file inside it, and is quiet
  otherwise.
- A watched engine reloads a rewritten package with its timer at 100,000 frames, which only a
  notification can explain.
- The span test states both schedules.

Making the engine ignore its watches fails the notification test.

**Runs:**
- On Linux natively, the null graph passed 2,124/2,125. The installed sandbox under Xorg logged
  `watching 1 content directory(ies)` and reloaded its sprite sheet 5 times for 5 edits 1.5 s
  apart.
- On Metal, the windowed sandbox did the same, 5 of 5. A first, shorter run ended before most
  edits.
- **Windows' watch is compiled, not yet run**: Step 12 runs it on the PC.

**The bar:** `zig fmt`, `zig build test` **2,136/2,137** (one skip), all four `check`s, the four
headless samples and `fdt-check`.

## Resolution — Step 12: Windows and Linux re-qualification (2026-10-18)

Steps 8–11 ran on the PC's Ubuntu and then its Windows, and both pass. Re-qualifying found four
things, each fixed in this step rather than left for later (rule 17).

**What the runs found.**
- **Skinning upload.** On GNOME the warden's skin p95 was 0.244–0.263 ms, against a 0.25 ms
  budget. Its vertices were uploaded by a submission of their own each frame.
  - `FrameVertices.updateIn` now records the copy into the frame's command buffer, and
    `render3d.Renderer.prepareSkin` takes that buffer (`update` is `updateIn` plus a submit).
  - GNOME's p95 fell to 0.10–0.11 ms. M24's failed-submission test now drives `AlreadyUpdated`
    and a lost device through the frame's own submit.
- **Menu hover.** The owner's Linux play reported a slight lag before a row under the pointer
  turned green. The row was found from the last frame's layout and drawn focused a frame late.
  - `hud.OptionsLayout`/`underPointer` now find the row from this frame's layout before drawing,
    so it is drawn focused in the same frame. A new screen test checks that frame's label
    colour; drawing from the old focus fails it.
  - The owner's second Linux play: "All green works".
- **Step 8's one Metal fall is explained, and scripted runs no longer take a person's input.**
  - The failed `win` stopped at step 21 of 46. Step 21 is `expect won`, reached with the player
    at the gap, at feet (−0.018, −2.015, −2.305).
  - The driver can only get there one way. The game was paused while the player was over the
    gap, so the driver skipped the route's remaining moves to the next `expect`. A real click on
    Resume then resumed the game, and the player, mid-air with no hands on the pad, fell.
  - A lost window focus pauses the game (§4.2). The roughly 900-frame "slow first lap" was that
    pause.
  - A new test pauses `win` past the floor's edge and then clicks Resume. With the new refusal
    removed, it reproduces the run exactly: `wrong_ending`, `fell`, step 21, the same feet.
  - `ScriptDriver` now fails `interrupted` when the game is paused at a move the script did not
    pause for. In a scripted run the court gives the menus neither the person's hover nor their
    clicks.
  - Eight Metal `win` runs in this step passed: six in a row, starting with the first after a
    fresh build, and one in each of the two bars.
- **Frame work counted a blocking present on Windows.** Today the PC's present call blocked for
  the display interval: the sandbox's `render.present` median was 15.49 ms. So the court's
  frame work read 16.66 ms.
  - The code had not regressed: Step 6's own install read 16.66 ms on the same machine today.
  - Like Step 8's `render.acquire`, `render.present` is now left out of frame work, which is
    labelled "no pacing sleep, image acquire or present". The timing test gained a present
    span, and counting it fails the test.
  - Windows' layers-off frame work is now 0.69/1.05 ms.

**Windows**, Arc A750, from a worktree at `4e31fff` with the Step 12 files overlaid and
hash-checked. The run was at `-j2`, below-normal priority, under Step 6's explicit
`-IgnoreCpuLimit`: the first attempt tripped the 50% gate on its own compile load, with the PC
otherwise idle.
- Null **2,117/2,127**: 10 skips, Step 6's nine plus the watch's not-a-directory refusal, which
  leaves that answer to Windows. So the watch test and the engine's notification test ran.
- Vulkan **2,398/2,418**, ReleaseSafe court **42/42**, Vulkan ReleaseSafe **112/112**.
- `native-window-test` **8/9**, `vulkan-window-test` **10/10**.
- The relocated ReleaseSafe install was made read-only by ACL. Six plays ran from it (validation
  and layers off × win/caught/fell). All reached their endings with zero skipped frames and zero
  drops, every tick's hash matched a fresh simulation, and the validation logs are clean.
- All seven OS capture checks pass. The installed hashes are unchanged, and no preferences were
  written.
- A Debug install's sandbox logged `watching 1 content directory(ies)` and reloaded its sprite
  sheet **5 times for 5 edits**. Hot reload is a Debug build's (`app.Config.hot_reload`), so the
  ReleaseSafe install correctly never watched.

| Windows, whole run | Frame work median / p95 | Move upper bound | One-warden skin |
| --- | --- | --- | --- |
| Layers off, `win` | 0.6861 / 1.0506 ms | 0.0646 / 0.1150 ms | 0.0786 / 0.1197 ms |
| Validation, `win` | 2.1839 / 3.6239 ms | 0.0553 / 0.1023 ms | 0.1288 / 0.1839 ms |

The layers-off runs meet §10.6's budgets. Validation-enabled `caught`'s skin p95 is 0.2766 ms; as
in Step 6, that diagnostic mode is recorded and not claimed against the budgets.

**Linux** (Ubuntu 26.04.1, balanced profile), on the Step 12 tree before the three court changes
below:
- Null **2,125/2,126**, ReleaseSafe court **41/41**.
- Vulkan **2,406/2,417**, Vulkan ReleaseSafe **111/111**.
- Window tests **17/19** under GNOME and Xorg.
- Six plays, `sandbox3d`'s tour and seven capture checks each pass under GNOME, Xorg and sway.
- Move p95: 0.2007 / 0.1724 / 0.1789 ms. Skin p95: 0.1128 / 0.1021 / 0.0887 ms.

The later changes are to `scripted.zig`, `main.zig` and `timing.zig`, all sample code:
- `scripted.zig` and `main.zig` change only a scripted run that is interrupted, or that a
  person's pointer would steer.
- `timing.zig` leaves one more wait out of a measure.

None touches a Linux path. Each is cross-compiled for Linux in the bar and tested on null, Metal
and Windows. The Linux figures above were measured with the present included, so they are upper
bounds.

**Plays by a person**, each claimed only by the owner's own report:
- **macOS**: "All go on the mac". Won, caught and fell; 7,613 frames, none skipped; 138 sounds,
  none dropped.
- **Linux** (GNOME, Wayland): "evrything is fanatstic", with the hover lag fixed above, then
  "All green works". Won, caught and fell; 10,700 frames, none skipped; 89 sounds, none dropped.
- **Windows**: "All green". Won, caught, fell and paused, with no lost focus; 3,232 frames, none
  skipped; 44 sounds, none dropped.

**The bar:** `zig fmt`; `zig build test` **2,138/2,139** (one skip); all four `check`s;
`fdt-check`; the four headless samples. Metal `court-test` 42/42; the three Metal endings.
Evidence is in the ignored `.zig-cache/m26-step12-linux/` and `.zig-cache/m26-step12-windows/`.

Step 12 is complete. Step 13 closes M26.

## Resolution — Step 13: M26 is closed (2026-10-18)

Step 13 changes documents only. Step 12's tree (`bad36e9`) is the tree M26 closes on, and the bar
below was run on it.

**§10.5's three reports are in.** Each is the owner's own words about their own play, recorded in
Step 12's Resolution: macOS "All go on the mac", Linux "All green works" (after the hover fix),
Windows "All green". Each was played from an install that was not the build tree.

**The reconciliation Step 13 named:**
- `3d.md` §10: the M26 row is marked done. Its certification wording now says ADR-0060 placed
  certification at M150. The "uses only what M19–M25 built" sentence names pointer capture as its
  one recorded exception, and the exit paragraph is marked met.
- `collision3d.md`: §10.3's pointer-capture bullet and §15's pointer-capture and jump rows are
  resolved.
- `hierarchy.md` §12, `animation3d.md` §14, `public3d.md` §14 and `light.md` §14 each record that
  M26 did not fire their triggers. The court authored no hierarchy, saved no pose, is first
  person, drew through no engine "draws this model" component, and needed no sky. `light.md`'s
  optional fragment stage is marked done (Step 9).
- `render3d.md` §8 names the court. `linux-desktop.md` gains a note: a person played 3D there.
  Its open limits name M137 and M101.
- Every design document's deferred section carries a rule-17 note pointing to the roadmap's
  intent column, 29 documents in all.
- CLAUDE.md §4.1's distribution row, §4.3's `platform` line (pointer capture and file watching),
  and §9's Linux, deferred-items and 3D rows. §4.5's sample list already named the court.
- AGENTS.md's bar already carries `fdt-check` (Step 10); nothing else in it changed.
- `docs/ROADMAP.md` marks M26 done and Phase 5 closed, and puts certification's line at M150. The
  design index, the README and `PROJECT_STATE.md` say the same.

**The owner's decision at the close:** no pre-release of the court is published. §13's row names
M50, whose second 3D sample is published instead. Nothing was pushed.

**Exit.** Every document names M26 complete and Phase 5 closed. The documents describe pointer
capture, file watching and the court's scripted proof as the code has them.

**The bar:** `zig fmt`; `zig build test` **2,138/2,139** (one skip); all four `check`s;
`fdt-check`; the four headless samples. Tag `m26`, not pushed. M27's design is next and is not
begun.
