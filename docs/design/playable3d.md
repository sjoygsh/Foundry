# Design: M26 — A playable 3D sample: `samples/court`, pointer capture and the three-platform play

**Status:** Accepted 2026-10-03 by the owner's request to begin Step 1, which accepts §14 as written. Steps 1–2 are done; Steps 3–8 are not begun.
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

## 12. Implementation order — eight bounded steps

Each step ends with a Resolution here, an updated `PROJECT_STATE.md`, the bar and a commit. There
is no automatic chaining.

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

### Step 8 — Close M26

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

Each item is on the long roadmap or keeps a trigger; ADR-0060 decides when, and the trigger
still decides the shape.

| Deferred | Returns when |
| --- | --- |
| Pointer capture through the public ABI | A mod needs to take the pointer, such as a mod-made minigame; it would need a host grant |
| Raw-input selection or normalised motion units in `platform` | Players report the look differing between machines beyond what a sensitivity setting corrects |
| Gamepads | A sample or game needs one; it is an input-device addition with its own Linux run |
| 3D spatialised audio and a listener | M31; the court's distance-and-pan arithmetic is the budget it must beat |
| A warden that sees and chases | M32–M33, navigation; the court's fixed patrol is deliberate |
| An engine-declared "draws this model" component | A second host needs entity-driven drawing a mod can join (`public3d.md` §14); the court did not |
| A hierarchy authored in content | The first content that needs a parented object (`hierarchy.md` §12); the court's are flat |
| An animation component saved with a world | M34; the court saves no pose |
| A third-person player body | A sample that is third-person; the court is first-person |
| A sky, image-based lighting | A scene whose constant ambient is measurably wrong (`light.md` §14); the court is a night scene and does not ask |
| A save game | A sample long enough that losing progress matters; the court takes minutes |
| A mod screen and profiles in a 3D sample | The second 3D sample (M50), or a player needing to choose mods without an environment variable |
| A Linux release artifact | The owner decides to distribute on Linux (CLAUDE.md §9) |
| A published pre-release of the court | The owner asks for one; it follows ADR-0047's unsigned, labelled path |

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
