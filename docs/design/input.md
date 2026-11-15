# Design: M45 — Input: action maps, rebinding, gamepads, captured motion in counts, and audio outputs

**Status:** Accepted 2026-11-15, when the owner asked for Step 1 (with M41's, ADR-0082), with §16 as written. Steps 1 and 2 are done (2026-11-15); Step 3 is next.
**Date:** 2026-11-15
**Baseline:** `225fbb9`, tag `m40`. M0–M40 are complete. M41 (Environment), this milestone's
lead under ADR-0082, is being designed at the same time and has no step yet.
**Decisions:**
- ADR-0002 (SDL3 behind Foundry's own platform interface), ADR-0013 (deterministic-friendly),
  ADR-0023 (Foundry's mixer; `platform` owns the device), ADR-0026 (the host hands `abi` its
  subsystems), ADR-0031 (defaults are content, preferences are a bounded file), ADR-0007 (layering
  by the build graph) and ADR-0082 (milestones in pairs) constrain it.
- [ADR-0087](../adr/0087-actions-are-content-evaluated-from-the-snapshot.md) (proposed): actions
  are content records, `foundry:input_action` and `foundry:input_context`, read by a new L2
  module `input` on `core`, `data` and `platform`, and evaluated as a pure function of the frame's
  input snapshot.
- [ADR-0088](../adr/0088-rebinding-is-a-preference-keyed-by-action.md) (proposed): a player's
  rebinding is a preference, `bindings.fset` under `foundry:input_bindings`, which replaces an
  action's bindings whole, keyed by the action's content ID; it is never content.
- [ADR-0089](../adr/0089-gamepads-are-positional-devices-in-fixed-slots.md) (proposed): gamepads
  are positional devices in four fixed slots of the snapshot, unfiltered, and captured mouse
  motion is the device's own counts on every platform.
- [ADR-0090](../adr/0090-the-table-publishes-input-as-the-tick-sees-it.md) (proposed): an
  additive `FoundryApi_v8` publishes keyboard, mouse, gamepad and action state read-only, as the
  tick sees it; M48's table becomes v9.

`platform-interface.md` §11 held gamepads open from M0 "so the snapshot is not shaped around
SDL's gamepad model". `audio.md` §11 question 4 sent device change and enumeration here, "beside
input's device handling" (M30's close). `playable3d.md` §13 sent raw-input selection, normalised
motion units and gamepads here, with a Linux run. `editor.md` §13 and `public-abi.md` left
"publishing keyboard state" as an open question since M15. This milestone answers all four.

## 1. Purpose and boundary

The roadmap's row is the contract:

> **M45 — Input.** Action maps, rebinding and gamepads; also raw input and normalised mouse
> motion, keyboard state published to the table, and audio device change and enumeration.

**The runnable result.** The court is played with a gamepad or with the keyboard and mouse,
through actions its content declares, not keys its code names:
- the left stick walks, the right stick looks, the south button jumps, the west button uses a
  beacon; the menus are driven by the d-pad, south and east;
- an Options → Controls screen lists every action with its keyboard and gamepad binding. A player
  picks one, presses the new key or button, sees and resolves a conflict, and the choice survives a
  restart; "Reset" returns the defaults;
- the "Light the beacon" prompt names the binding the player has, on the layout they have
  (`E` on QWERTY, the key in the same place on AZERTY, `X` or `Square` on a pad);
- the pad rumbles when the warden catches the player;
- Options → Audio lists the machine's outputs. Choosing headphones moves the sound there, and
  unplugging them mid-music moves it to the system default without a gap longer than a buffer
  or two, and without the game noticing anything but an event;
- a content mod, `southpaw`, changes the court's default bindings with no code, and a player's
  own rebinding still wins over it.

`sandbox3d` walks through its own actions, and its consented native mod, `orbiter`, declares an
action of its own in its package and reads it, and the keyboard, through `FoundryApi_v8`.

**The exit condition:**
- Action evaluation, contexts, deadzones, capture, conflicts and overrides agree with a hand-
  written oracle over scripted snapshots, and a pinned digest of a scripted sequence holds on
  every platform.
- Replaying the same snapshots and the same step schedule gives the same actions, byte for byte.
  A press is seen by exactly one tick, whatever the frame rate.
- `court-test`'s four digests are M40's, with the walk read through actions.
- A virtual gamepad created through SDL drives the same snapshot on macOS, Windows and Linux, and
  a person plays the court with a physical pad on each.
- Captured motion is reported in counts, and its unit is named in the snapshot, on all three.
- A changed or lost audio output keeps the mixer's handle and its music's scheduled starts, on all
  three.
- A C99 consumer that sees only `foundry.h` reads keys, the mouse, pads and actions through v8;
  every refusal of its input is tested.

**In M45:**
- captured motion in counts, the motion mode, and key labels from the layout (§3);
- gamepads: the snapshot's slots, events, focus, rumble, and the SDL3 and null backends (§4);
- audio outputs: enumeration, choice, change and loss, in `platform` and the mixer (§5);
- the `input` module, its records and their validation (§6);
- evaluating actions: kinds, contexts, consumption, devices and the tick view (§7);
- rebinding: overrides, capture, conflicts and the bindings file (§8);
- the frame: where `app` evaluates, and what a step carries (§9);
- `FoundryApi_v8` (§10);
- the court, `sandbox3d`, `orbiter` and `southpaw` (§11).

**Not in M45, each owned elsewhere:**
- Lua bindings for input: M49 (its row already says so).
- Rebinding and enabling contexts *through the table*, and what a mod may learn about a host's
  audio outputs: M48, by host grant (§10).
- Hold-or-toggle per action, chords, remapping unknown joysticks, wheels and flight sticks with
  mapping strings, gyro aiming, touchpads and light bars: M146, whose row already holds "full
  remapping" (§15).
- Touch input: M139. IME preedit: M145. Audio capture devices: M132.
- Keyboard navigation and tab order in the widget set: M44, which will read actions (§15).

### Paired with M41

ADR-0082 pairs each lead with the earliest later milestone in a different field that neither needs
nor is needed by it and changes none of its modules. M41 (Environment: sky, cubemaps, image-based
lighting, an engine light record, glTF light import, tangent generation, cubemaps and texture
arrays in the RHI) changes `rhi`, `render3d`, `asset` and `author`. The milestones between were
passed over:
- **M42, Tone and exposure:** the same field, and it builds on M41's `render3d`.
- **M43, Text I:** font atlases may want M41's RHI texture arrays, and its fonts are `asset`
  content.
- **M44, Game UI:** it needs M43's text, and it changes `asset`'s theme records.

**M45 lives in `platform`, a new `input` module, `app`, `audio` and `abi`**, none of which M41
changes.

**One overlap, stated plainly as a dependency risk (ADR-0082's drop rule).** Engine record types
must be registered in `author`'s compiler, or `fpack` cannot compile a package that uses them
(`engine/src/author/compiler.zig:405–477` registers `mod`'s, `asset`'s and `scene`'s). So Step 4
adds **one line** there, `input.schemas.registerAll`, and grants `author` the `input` module in
`build.zig`. That is a change to an M41 module. It is textual: no M41 code is read, called or
changed in meaning, and M41's own registration of its light record will sit beside it. The
alternatives were worse:
- **putting the records in `asset`**, the house home for engine schemas, which is M41's module
  outright;
- **declaring them as `@schema` in package zero**, which would leave the engine reading untyped
  records and make every game's package depend on `foundry:core` at compile time;
- **hiding them in `scene.schemas` or `mod.schemas`**, which would pass layering by convention, not
  by meaning.

`app/engine.zig`'s list of registrations (line 661 on) and `build.zig` are shared in the same way,
and are resolved at merge. If the owner prefers no author change while M41 has author work open,
Step 4's one line can land after M41's last `author` step: nothing before Step 8 compiles a
package with an action in it (§16, item 3).

## 2. What exists

This milestone is designed against code M41 is about to change. M41 changes none of the files
below except `author/compiler.zig` and `build.zig`.

**`engine/src/platform/`:**
- `key.zig`: `Key`, 106 physical-position names including `unknown`, whose `name`/`fromName` are
  the persistence round-trip and whose order is already append-only. `MouseButton` (left, right,
  middle, back, forward), `KeySet`, `ButtonSet`, and `Modifiers` as a packed `u8`.
- `event.zig`: the `Event` union (quit, window closed/resized/focus, key down/up, text, mouse
  moved/button/wheel), no device events.
- `input.zig`: `MouseState` (position in points and pixels, `motion` summed in points, `wheel` in
  notches, `captured`, button sets) and `InputSnapshot` (keys held/pressed/released, modifiers,
  mouse, focus), built by `Accumulator.apply`/`capture`, the one place snapshot semantics live.
  Focus loss releases everything held.
- `audio.zig`: `AudioDeviceHandle`, `AudioConfig`, `AudioInfo`. No output identity.
- `interface.zig`: the comptime `check` over sixteen calls. `InitOptions` is an empty struct.
- `backends/sdl3.zig`:
  - `SDL_Init(SDL_INIT_VIDEO)` only;
  - joystick, gamepad and audio-device events are dropped, under a stale comment that defers them
    "to M5";
  - `setPointerCapture` is `SDL_SetWindowRelativeMouseMode`, released on focus loss;
  - `openAudio` asks the default playback device's rate, opens one stream with
    `SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, …)` in Foundry's `f32` format,
    and lets SDL convert.
  - SDL is 3.4.14 through the castholm port v0.5.3.
- `backends/null.zig`: a scriptable `pushEvent`, `setFocus`, `stepAudio`; one fake audio device.

**`engine/src/app/engine.zig`:**
- The `input` span pumps events and freezes `self.input = platform.captureInput()`.
- `nextStep` hands every step in a frame the same `Step.input`.
- The engine registers `asset`'s, `mod`'s and `scene`'s schemas before any package loads.
- `profiles.zig` and `settings.zig` are the settings envelope (`FSET`) and the engine's own
  `foundry:profile` schema: the precedent for an engine-owned preference file.

**`engine/src/audio/mixer.zig`:** `Mixer.init` opens the device, believes `audioInfo` and
computes against its rate. The sample clock counts frames the callback rendered.

**`engine/src/abi/`:**
- `FoundryApi_v7`, 264 calls, frozen.
- The table has `ui_wants_keyboard` and `ui_wants_pointer` and no input state.
- `FoundryStep` is tick and delta; `public-abi.md` says a system gets "no input snapshot … all
  three would make a mod's simulation depend on its host's frame rate".
- The native loader offers 1–7.

**The samples:**
- **The court:**
  - `walk.zig`'s `inputIntent` reads WASD, arrows, space, E and captured motion by key name;
  - `Pending` carries edges and look motion across a frame with no tick, so each is consumed once;
  - `main.zig:256` drives the menus from arrows, Enter and Escape;
  - `prefs.zig` holds sensitivity, invert and three volumes;
  - the beacon's prompt is content text, `use_key "E"`.
- **`sandbox3d`:** `walk.zig` reads the same keys. `orbiter` is a C99 native mod built by
  `build.zig`.

## 3. Captured motion in counts (`platform`)

**The problem.** Under capture, `MouseState.motion` is whatever SDL's relative mode delivers.
`playable3d.md` §4.2 recorded that this is unaccelerated on some systems and accelerated on others,
and made sensitivity the game's. The consequence is that the same sensitivity is a different feel
on each machine, and no player can carry a number between them.

**Now:**
- **A motion mode, the host's choice:** `platform.MotionMode = enum { raw, system }`, set by
  `Platform.setCapturedMotion(mode)` and defaulted to `raw` by `app.Config.captured_motion`.
  - `raw`: the device's counts, unscaled by the OS pointer speed and without acceleration.
  - `system`: the OS's own ballistics, as a desktop pointer moves.
- **`MouseState.motion_unit = enum { points, counts }`** names what `motion` holds in this
  snapshot:
  - uncaptured, it is `points`, as today;
  - captured with `raw`, it is `counts` where the backend can deliver them;
  - captured with `system`, or where a platform cannot deliver raw counts, it is `points`.
  - **What is true, never what was asked for**, which is `captured`'s rule.
- **The SDL3 backend** sets `SDL_HINT_MOUSE_RELATIVE_SYSTEM_SCALE` to `0` for `raw` and `1` for
  `system`. Step 1 confirms against the pinned 3.4.14 sources what each platform's driver then
  delivers, and records it:
  - Windows' raw input;
  - macOS's relative deltas;
  - X11's XInput2 raw events;
  - Wayland's relative-pointer protocol, which carries an unaccelerated delta.
  A platform that cannot honour `raw` reports `points`, and Step 1's Resolution names it as a
  limit.
- **"Normalised" means one unit on every platform**: counts are the device's, so the same mouse
  moved the same distance gives the same number on macOS, Windows and Linux. Counts per inch is
  the mouse's own and no OS reports it, so the engine does not pretend to convert to a physical
  unit. Sensitivity stays a game preference, but one number now means one feel.
- **Key labels from the layout:** `Platform.keyLabel(key, buf: *[16]u8) []const u8`. It gives the
  character the current layout engraves on a physical key (`SDL_GetKeyFromScancode`, then
  `SDL_GetKeyName`), bounded and validated UTF-8, and an empty slice for `unknown`. The null
  backend answers the key's own name. A prompt says `A` for `Key.q` on AZERTY. **It is
  presentation**: bindings keep the physical name.

**Designed for:** a per-window mode. One mode for the platform is enough while the engine has one
game window.

## 4. Gamepads (`platform`, ADR-0089)

### 4.1 Identity: positions and slots

**Buttons are named by position, as keys are** (`key.zig`'s rule): `south`, `east`, `west`,
`north`, so a binding means the same place on an Xbox, a PlayStation and a Nintendo pad. SDL3's
gamepad API already names buttons this way, which is the reason it can be adopted without shaping
the snapshot around it. `platform.GamepadButton` (stable names, append-only, a compatibility
surface):
- `south east west north`;
- `back guide start`;
- `left_stick_press right_stick_press left_shoulder right_shoulder`;
- `dpad_up dpad_down dpad_left dpad_right`;
- `misc1 left_paddle1 left_paddle2 right_paddle1 right_paddle2 touchpad_press`.

`platform.GamepadAxis`: `left_x left_y right_x right_y left_trigger right_trigger`.

**What is printed on a button is presentation**, reported separately:
- `GamepadState.kind`: `standard`, `xbox`, `playstation`, `nintendo` or `other`, from
  `SDL_GetGamepadType`;
- `labelOf(button)`, an enum (`a b x y cross circle square triangle none`) from
  `SDL_GetGamepadButtonLabel`.

A Nintendo pad's `east` is labelled `a`. The game's text maps labels to words or glyphs.

**Four slots, fixed in the snapshot:** `InputSnapshot.gamepads: [max_gamepads]GamepadState`,
`max_gamepads = 4`:
- A pad that connects takes the lowest free slot and keeps it until it disconnects.
- A fifth waits, in order of connection, and takes the next slot to free.
- `GamepadHandle = core.Handle(Gamepad)`: the slot is its index and its generation counts
  connections (I1). A game holding player two's handle learns that a different pad now sits in
  slot 1 because the handle no longer matches.
- Slot assignment is `platform.gamepad.Slots`, shared by both backends, so the same connection
  sequence gives the same slots everywhere. That is the accumulator's argument, applied to
  devices.

### 4.2 State and events

**Each slot holds:**
- `connected` and `handle`;
- `kind`;
- `buttons_held`, `buttons_pressed`, `buttons_released`, as for keys;
- `axes: [6]f32`.

**Axes are normalised and unfiltered:**
- sticks are in [-1, 1] with **+y up, away from the player**, so SDL's down-positive `left_y` is
  negated in the backend;
- triggers are in [0, 1];
- the raw `i16` divides by 32,767 and clamps at -1.

No deadzone is applied here: what is near zero is a property of a binding, and §7 owns it. The
platform reporting raw values is what lets one stick be read with two deadzones by two actions.
Mouse motion keeps its screen convention (+y down), as today. The two differ on purpose, and §6's
`scale` turns either.

**Events:**
- `gamepad_added { pad }` and `gamepad_removed { pad }`;
- `gamepad_button_down/up { pad, button }`;
- `gamepad_axis { pad, axis, value }`.

The accumulator applies them as it applies keys: buttons give state and edges, and an axis is the
latest value. **Focus loss releases held pad buttons and zeroes the axes**, for the reason it
releases keys: SDL stops delivering pad events to a background window by default, so the last
value would otherwise stick. A removed pad reports its held buttons released in the snapshot it
leaves.

### 4.3 Rumble, and backends

**Rumble:** `Platform.setGamepadRumble(pad, low: f32, high: f32, duration_ms: u32)`.
- It gives `error{InvalidGamepad, Unsupported}`.
- Strengths in [0, 1], a duration up to 10 s, and zeros stop it.
- It is output and presentation: nothing in simulation reads it.

**The SDL3 backend:**
- `SDL_INIT_GAMEPAD` at `init` when `InitOptions.gamepads` (default true; a server host turns it
  off);
- `SDL_OpenGamepad` on `SDL_EVENT_GAMEPAD_ADDED`, closed on removal;
- SDL's built-in mapping database and no external file. A joystick SDL cannot map as a gamepad is
  ignored and counted (M146, §15).

Step 2 confirms that the port builds the gamepad subsystem on each target:
- macOS: GameController and IOKit, which the port must link;
- Windows: XInput, raw input and WGI;
- Linux: evdev, with or without `libudev` in the port's build.
A missing piece is a port build option, not a new dependency.

**The null backend** scripts connection, buttons and axes through `pushEvent`, and records rumble.

**Testing without hardware:** `zig build gamepad-test`, a desktop test like `native-window-test`.
It attaches SDL's virtual joystick (`SDL_AttachVirtualJoystick`, described as a gamepad), drives
its buttons and axes, and checks the snapshot, the slots, removal and a second pad. It proves the
backend's translation on every platform, and a person with a real pad proves the rest (§12).

## 5. Audio outputs: enumeration, choice, change and loss (`platform`, `audio`)

**Today** the mixer opens the default device, and SDL3 already moves a stream on the default
device to a new default when the system's default changes. That covers "unplug the headphones"
when the player never chose an output. What is missing:
- a list of outputs;
- choosing one;
- what happens when a chosen one disappears;
- any event telling a game that the list changed.

**Now, in `platform.audio`:**
- `OutputId`, a `u32` valid for this session only. SDL's device IDs are not stable across runs,
  so nothing persists one.
- `OutputInfo { id, name: [128]u8 + len, is_default }`. The name is validated UTF-8, truncated on
  a codepoint.
- `Platform.audioOutputs(out: []OutputInfo) usize`, in the OS's order.
- `AudioConfig.output: ?OutputId = null`. Null **follows the system default**, as today.
- `Platform.setAudioOutput(device, output: ?OutputId) AudioError!void` moves a running device to
  another output, or back to following the default.
- **Events:**
  - `audio_outputs_changed`: one variant for added, removed and default changed; a consumer
    enumerates again;
  - `audio_output_lost { device }`: a chosen output disappeared.

**The handle survives a change of output.** A Foundry audio device is the stream the mixer's
callback fills. Moving it means binding that stream to another SDL logical device, not reopening
it:
- `openAudio` becomes `SDL_OpenAudioDevice`, `SDL_CreateAudioStream` in Foundry's format,
  `SDL_SetAudioStreamGetCallback` and `SDL_BindAudioStream`;
- a move opens the new logical device, rebinds, and closes the old one.

The source format, the callback, `AudioInfo` and the sample clock do not change, and SDL converts
to the new hardware's rate and channels. The handle comment in `audio.zig` stays true: a handle is
refused after `closeAudio`, and a move is not a close. Step 3 confirms each call against the pinned
sources.

**When a chosen output is lost**, the backend rebinds to the default itself and emits
`audio_output_lost`. The sound continues and the game learns it. A gap is the time SDL takes to
notice, not Foundry's. The mixer's clock counts rendered frames, so scheduled music starts stay on
their frames, although the audible latency changes with the hardware.

**In `audio`:** `Mixer.selectOutput(?OutputId)` and `Mixer.output() ?OutputId` forward to the
platform. Nothing in mixing changes.

**Names are host information.** An output's name often carries a person's name, as with
"<name>'s headphones". So:
- **the log never prints one**: it logs the count and the chosen index;
- the table does not publish them (M48's "what a mod may learn about its host");
- a game shows them in its own menu and keeps the chosen name in its own preference file, the
  player's own data.

**The null backend** scripts a list of outputs, a default change and a loss, and steps the device
across a move, so the rules above are tested with no hardware.

## 6. The `input` module and its records (ADR-0087)

### 6.1 Where it lives

**A new module at L2: `input -> core, data, platform`**, beside `mod`, `asset` and `net`.
- It needs `platform` for the snapshot it reads, and `data` for the records it reads.
- It owns the meaning of its records, as `mod` owns `foundry:mod`.
- It holds no device and no thread, so every rule in it is unit-tested with no window.
- `app` (L4) evaluates it in the frame, and `abi` (L5) is granted it to publish actions.
- `author` is granted it for one call, the registration (§1).

It is not `platform`, which has no `data` and must stay the thin OS layer. It is not `app`,
because `author` cannot see `app`. It is not `asset`, because no asset is loaded and `asset` is
M41's.

### 6.2 `foundry:input_action`

One record per action, so a mod overrides one action's defaults by overriding one record, and
adds an action without touching the game's records:

```fdt
foundry:input_action court:action.move {
    kind      vector                       # button | axis | vector | delta
    contexts  [ court:context.walk ]       # foundry:input_context records, 1 to 4
    bindings  [
        { source "key.w"  axis y  scale  1 }
        { source "key.s"  axis y  scale -1 }
        { source "key.a"  axis x  scale -1 }
        { source "key.d"  axis x  scale  1 }
        { source "pad.left_stick"  deadzone 0.2 }
    ]
}
```

**Fields (version 1).** Every name is on authors' disks (CLAUDE.md §7):
- `kind string`: `button`, `axis`, `vector` or `delta`.
- `contexts [id]`: one to four contexts this action belongs to. **The action names its
  contexts**, not the reverse, so a mod adds an action to the game's walking context without
  overriding the context record. That is M35's "named by the figure" argument.
- `bindings [ { … } ]`: up to eight defaults. Each has:
  - `source string`;
  - `axis string (default "x")`: which component a vector binding feeds;
  - `scale f32 (default 1)`;
  - `threshold f32 (default 0.5)`: where an axis becomes a button;
  - `deadzone f32 (default 0.15)`, in [0, 0.95].
- `rebindable bool (default true)`: the court's pause action is not.

**No label.** What a player reads is text, and text becomes string tables in M46. A game names its
actions in its own text records, as the court already does for prompts. An engine `label` field
would be a migration in M46.

### 6.3 Source names

**Source names are a compatibility surface**, spelled from the names `platform` already freezes:
- `key.<Key name>`: `key.w`, `key.space`, `key.left_shift`.
- `mouse.<button>`: `mouse.left`. `mouse.motion` (2D delta) and `mouse.wheel` (2D delta).
  `mouse.wheel_up`, `mouse.wheel_down`, `mouse.wheel_left` and `mouse.wheel_right` are buttons
  pressed and released in the frame the wheel turned.
- `pad.<GamepadButton>`, `pad.<GamepadAxis>`, and `pad.left_stick` and `pad.right_stick`
  (2D, radial).

### 6.4 `foundry:input_context`

```fdt
foundry:input_context court:context.menu {
    priority  20        # i32; higher is read first, ties by content ID
    blocks    true      # sources bound here are hidden from lower contexts
}
```

### 6.5 Validation

Validation is at `input.Map.build(gpa, store)`, from the merged store, as warnings. Content is
untrusted.
- **A record wrong in a way this engine understands is refused whole, naming the field**, and the
  map is built without it. Examples: a kind unknown, a source that cannot feed this kind, a
  deadzone of 2, a context that is not a `foundry:input_context`, too many bindings. This is
  `ui_theme`'s rule: a half-understood action is a control nobody designed.
- **An unknown source name is skipped with a warning**, the rest kept. That way content written for
  a later engine, which knows a source this one does not, still runs. This is `ui_theme`'s rule
  for unknown parts.
- **Bounds:**
  - 256 actions and 64 contexts in a map;
  - 8 bindings per action and 4 contexts per action;
  - 32-byte source names.

**Which sources may feed which kind:**

| Kind | Value | May be fed by |
| --- | --- | --- |
| `button` | held, pressed, released | any button source; a pad axis past `threshold` in the direction of `scale`'s sign; the wheel's four buttons |
| `axis` | `f32` in [-1, 1] | buttons (`scale` × 1); axes (`scale` × value after the deadzone) |
| `vector` | `Vec2`, length ≤ 1 | buttons and axes into `axis`'s component; sticks into both, radially |
| `delta` | `Vec2`, unbounded | `mouse.motion` and `mouse.wheel`, times `scale` |

A stick looked with on a pad is a `vector` action the game scales by time. A mouse looked with is a
`delta` action. The court reads both, which also gives the arrow keys a home (§11).

**Hot reload:** a content reload rebuilds the map. An action that survives keeps its held state,
so a reload does not invent a press.

## 7. Evaluating actions

**`input.Actions`** holds a `Map`, the enabled contexts, the device selection and the previous
frame's held states. `evaluate(snapshot, options) -> *const Frame` is a pure function of those and
the snapshot. A `Frame` is a fixed array, one `ActionState { held, pressed, released, value: Vec2 }`
per action in **content-ID order** (I9's documented order), found by ID with a sorted search.

**Per action:**
- **Buttons:** held if any binding's source is held, or an axis is past its threshold.
  - **Pressed if any button source was pressed in the snapshot**, or an axis crossed its
    threshold since the previous frame.
  - A press and release inside one frame is therefore a press and a release, never lost. That is
    the snapshot's own rule, kept.
- **Axes and vectors:**
  - Each binding's contribution is its deadzoned value times `scale`.
  - The deadzone is rescaled, `(|v| − d) / (1 − d)`, radial for a stick.
  - Contributions are summed and clamped: [-1, 1], or length 1 for a vector, so a diagonal on the
    keys is no faster than a stick.
  - `held` is a nonzero value, and its edges follow it.
- **Deltas:** the sum of motion and wheel times `scale`, unclamped, held when nonzero.

**Contexts and consumption:**
- The game enables contexts with `Actions.enable(id)` and `disable(id)`, at most eight at once.
  Which are enabled is game state, the game's to save.
- Evaluation walks the enabled contexts from the highest priority down, ties by content ID.
- An action is evaluated in the first enabled context it belongs to. An action in no enabled
  context reads as rest, with a release edge if it was held.
- A context with `blocks` hides every source it binds from lower contexts, whether pressed or not.
  The court's menu therefore owns the arrow keys while it is open, without the walk reading them.
  "Bound" rather than "active" is the simpler rule to predict.

**Devices:**
- `options.devices` selects the keyboard and mouse and a mask over pad slots. The default is all.
- Two `Actions` over one snapshot with different devices are two local players, and nothing more is
  needed for that.
- `options.blocked = .{ .keyboard, .pointer }` hides keys or the mouse from every action. It is the
  `ui_wants_keyboard` case the court now handles with `typing`.

**The tick view.** A frame's snapshot is seen by every step in that frame, and by none when a frame
runs no step. Edges and deltas read per step are therefore counted by the frame rate. This is
exactly what the court's `Pending` exists to fix (`walk.zig`), and what `public-abi.md` gave as the
reason a mod's system gets no input.

`input.TickView` generalises `Pending`:
- edges and deltas accumulate across frames until a step takes them;
- **the first step after they happened sees them, and later steps in that frame see held state
  only**;
- the same is done for the raw snapshot (`TickView.snapshot`), for the table.

A press is seen by exactly one tick, whatever the frame rate. Which tick sees it still depends on
when it happened. That is inherent to live input, and a replay records what each tick saw.

**Determinism.** The same map, enabled contexts, devices and snapshot sequence give the same frames
and tick views. A test folds them into a digest that is pinned on every platform (§13). The only
float operations are adds, multiplies, a clamp and one square root, with no fast-math (I9).
Networked simulation still reads commands, not local input (ADR-0044). Nothing here changes who
the authority is.

## 8. Rebinding (ADR-0088)

**An override replaces an action's bindings whole**:
- `input.Overrides` maps an action's content ID to up to eight bindings in the record's own shape;
- `Map.apply(overrides)` gives the effective map.

Whole replacement keeps one rule a player can understand: "my bindings for Jump are these". It
avoids merging a player's change with a mod's later change to the same action's defaults.

**The order of authority:**
1. The player's override.
2. The last package's record, a mod over the game.
3. The game's record.

A `rebindable false` action ignores an override and says so once.

**Capture:** `input.Capture` listens for the next source.
- `start(.{ .keyboard_mouse, .pads, .ignore })` arms it.
- Each snapshot fed returns `null` or the first source that became active: a key or button
  pressed, or an axis leaving rest past 0.5. Its sign gives the binding's `scale`.
- Mouse motion never captures, and neither does a source in `ignore`. The game puts its cancel
  binding there, so Escape cancels rather than binds.
- Ties in one snapshot go by source order: keys, mouse, pads by slot, each in enum order.

**Conflicts:** `Map.conflicts(source, action, out)` lists the other actions that bind that source
in any context that can be enabled with one of this action's.

The engine decides nothing more, because what a conflict should do is a game's call:
- the court swaps;
- another game might refuse;
- a third might allow it.

**The bindings file, in `app`:**
- `app.input_bindings` keeps the overrides in `<user data>/bindings.fset`, in the settings
  envelope, under the engine's own settings schema `foundry:input_bindings` v1:
  `actions [ { id string  bindings [ { source axis scale threshold deadzone } ] } ]`.
- It is `profiles.zig`'s pattern:
  - untrusted;
  - bounded (256 actions);
  - written atomically;
  - **merged by action** with the file as it is just before the write, so two instances rebinding
    different actions keep both.
- An override for an action this build's content does not have is **kept** in the file, not
  dropped. A player who disables a mod and enables it again keeps their bindings for its actions.
- An override invalid for its action's kind is refused for that action alone, with a warning, and
  the defaults stand.
- It is not content and not a package (ADR-0031): no mod can write a player's preferences.

## 9. The frame (`app`)

`app.Engine` gains, behind `Config.input = .{ .enabled = true }`:
- **`engine.actions`**, an `input.Actions`:
  - built after content loads, with the bindings file applied;
  - rebuilt on reload;
  - evaluated in the `input` span right after `captureInput`, from the snapshot and the blocking
    the game set last frame (`engine.setInputBlocked`).
- **`Step.actions` and `Step.tick_input`**, the tick views of §7, borrowed for the step. `Step.input`
  stays the frame's snapshot, unchanged, so nothing existing reads differently.
- **`engine.actionFrame()`**, the frame view, for presentation and UI.
- **`engine.saveBindings(overrides)`** writes the file and applies it. The next frame's evaluation
  uses it.
- **`Config.captured_motion: platform.MotionMode = .raw`**, forwarded at start.
- **Audio outputs:** the frame's events carry §5's two, which a game reads through `nextEvent` as
  it reads resizes.

A headless engine evaluates the same way from the null backend's snapshots, which is how every
test in §13 runs. An engine with no `foundry:input_action` in its content has an empty map, and
`Step.actions` is an empty frame.

## 10. The public table: `FoundryApi_v8` (ADR-0090)

**Additive, eleven calls, 275 in all**, v1–v7 byte-identical. The native loader offers 1–8 in the
same commit, per M15's lesson. All of it is read-only:

| Call | Answers |
| --- | --- |
| `input_keyboard(FoundryKeyboardState *out)` | held, pressed and released as `uint64_t[4]` bitsets by key number; modifiers; focus |
| `input_key_from_name(FoundryStr, uint32_t *out)` / `input_key_name(uint32_t, FoundryStr *out)` | the stable names, both ways |
| `input_key_label(uint32_t, FoundryStr *out)` | §3's layout label, borrowed |
| `input_mouse(FoundryMouseState *out)` | positions, motion and its unit, wheel, buttons, captured |
| `input_gamepad_slots(uint32_t *out)` | 4 today, asked rather than assumed |
| `input_gamepad(uint32_t slot, FoundryGamepadState *out)` | connected, kind, buttons as three `uint32_t` masks, six axes |
| `input_action(FoundryContentId, FoundryActionState *out)` | held, pressed, released, value, kind; `NOT_FOUND` for an unknown action |
| `input_action_binding_count` / `input_action_binding(id, index, FoundryBinding *out)` | the effective bindings, source borrowed, and whether the player overrode them |
| `input_context_enabled(FoundryContentId, FoundryBool *out)` | whether a context is enabled |

**Key and button numbers are written out in the header**, `FOUNDRY_KEY_*` equal to `Key`'s values,
which freezes an order that `key.zig` already keeps append-only. Every enumeration is an `int32_t`
or `uint32_t` with its numbers written out, as the table's rule is.

**As the tick sees it:**
- inside a system's callback, every input call answers that step's tick view (§7);
- anywhere else, it answers the frame's view.

A mod's simulation therefore reads input exactly as the game's does, and is no more frame-rate
dependent. This corrects `public-abi.md`'s "no input snapshot" at the close, and `FoundryStep`'s
comment with it. The reason that sentence gave is answered, not ignored.

**The host supplies it** (ADR-0026). `abi.Sources` gains `input: ?*const app.InputSources`, the
engine's frame and tick views, and without it every call answers `FOUNDRY_ERR_UNAVAILABLE`.

**What v8 does not publish, each M48's:**
- enabling contexts;
- writing bindings or the bindings file;
- capture;
- rumble;
- audio outputs.

Each changes what the player experiences or reveals the host, so each needs a grant, and M48
already holds "per-mod tables and policy" and "what a mod may learn about its host". Step 11 writes
them into M48's row. Its title becomes "Public API v9" and M49's "v6 to v9": the renumbering M27
already did once (v7 then, M48 moving to v8).

**The proof** is in Step 7:
- `engine/tests/abi_input.zig`, with a C99 fixture that sees only `foundry.h` and is checked for
  every refusal (bad pointer, bad slot, unknown key number, unknown action, no input source);
- `orbiter` declares `orbiter:action.spin` in its own package, in `sandbox3d`'s context, and spins
  faster while it is held;
- `docs/modding/input.md`, written from an external consumer, as the 3D and networking guides
  were.

## 11. The samples

**The court** (Step 8):
- **Content.** `court:context.menu` (priority 20, blocking) and `court:context.walk` (10), with
  these actions:
  - `menu.up`, `menu.down`, `menu.left`, `menu.right`, `menu.accept` and `menu.back`;
  - `walk.move` and `walk.jump`;
  - `walk.use`;
  - `walk.look` (delta: captured mouse);
  - `walk.look_stick` (vector: the right stick and the arrows, which were `turn` and `pitch`);
  - `walk.pause` (not rebindable);
  - `panels` (F1).
- **`walk.zig`'s `inputIntent` reads `Step.actions`**, and `Pending` goes, because the tick view
  is what it did. `court-test`'s four digests must stay M40's. The scripts drive the same
  snapshots, so the same ticks see the same presses.
- **Options → Controls:** every rebindable action with its keyboard and pad binding. Accept
  captures, `menu.back` cancels, a conflict asks and swaps, and "Reset" clears the override. The
  text is court content.
- **Prompts:** `use_key "E"` becomes the binding's label, from §3's key label or the pad's button
  label through court text.
- **Rumble** when the warden catches the player.
- **Options → Audio → Output:**
  - "System default" and each output's name;
  - the choice is kept by name in the court's `prefs.zig` as `audio_output`, and found again by
    name at start or on `audio_outputs_changed`;
  - a lost output shows "System default" while the preference is kept, so the headphones return
    when they do.
- **Sensitivity defaults are retuned for counts** in content, and the change is recorded.
- **`southpaw`**, a content mod in `samples/court/testdata/mods/`, overrides `walk.move` and
  `walk.look_stick` to put walking on the right-hand cluster and the right stick. It needs no code
  and no recompiled game. A test shows that a player's override of `walk.jump` still wins with it
  enabled.
- The owner plays it on the Mac with a pad, rebinds, and unplugs headphones mid-music.

**`sandbox3d`** (Step 7):
- its walk reads `sandbox3d:action.*` in `sandbox3d:context.play`;
- its debug F-keys stay raw keys, because they are the host's shortcuts and not controls;
- every tour pin holds;
- it hands `abi.Sources.input` to the native host, so `orbiter` reads it.

## 12. Platform assessment

**macOS (Apple M5), Metal:**
- **Gamepads:** SDL3 uses the GameController framework, with IOKit for HID. Step 2 checks that the
  port compiles and links them. Bluetooth pads need no entitlement and no Input Monitoring
  permission. Reading raw keyboard state would need that permission, and Foundry does not do it.
- **Raw motion:** Step 1 records what relative mode delivers with the hint off.
- **Audio:** CoreAudio's default follows the system, through SDL's migration.
- **A physical pad is needed.** The owner's controllers decide which kinds are proved. One Xbox-
  or PlayStation-style pad is the minimum; a second kind proves the labels (§16, item 17).

**Windows (Arc A750, i3-10105F), Vulkan:**
- XInput, raw input and WGI for pads;
- raw input for captured motion;
- WASAPI's default migration;
- a pad plugged into the PC.

**The PC is needed for Step 9**: the platform backend changes in ways only Windows exercises, and a
person must play with a pad. It is the owner's gaming PC, driven as before: idle first, `-j2`,
below-normal priority. **Only one milestone uses the PC at a time.** M41 needs it for its Vulkan
cubemaps and texture arrays, so M45's Step 9 is movable: it waits at its place for the PC without
blocking Step 10 or the close's documents.

**Linux:**
- **A Linux run is needed** (`3d.md` §10.2's trigger fires: the platform backend's input and audio
  paths are Linux-specific, and `playable3d.md` §13 named a Linux run for gamepads).
- It uses the PC's throwaway Ubuntu, rebuilt from the kit as in M26 and M18.
- It checks:
  - evdev pads with hotplug, with or without `libudev` in the port's build, which is Step 2's
    question;
  - XInput2 raw motion under Xorg;
  - relative-pointer under GNOME's Wayland;
  - PipeWire's default migration.
- Step 10 is movable with Step 9 and may share its PC session.

**No graphics backend changes.** Nothing here touches `rhi` or `render3d`, so no readback moves.

## 13. Verification

**Headless, in `zig build test`, null backend:**
- **Motion:**
  - `motion_unit` is `points` uncaptured and `counts` captured in `raw`, and `points` captured in
    `system`;
  - a backend that cannot honour `raw` reports `points`;
  - key labels are bounded valid UTF-8 and empty for `unknown`.
- **Pads:**
  - slots by lowest free and kept;
  - a fifth waits and takes the first freed slot;
  - generations change on reconnect;
  - edges, a press and release in one frame;
  - axes normalised, +y up, clamped;
  - focus loss releases and zeroes;
  - removal releases;
  - rumble refused for a stale handle or out-of-range strength;
  - the same events give the same snapshot.
- **Outputs:**
  - enumeration bounded and names truncated on a codepoint;
  - a move keeps the handle, `AudioInfo` and the clock;
  - a loss falls back and emits the event;
  - a stale handle is refused;
  - no name reaches the log (a test captures the log).
- **Records:**
  - every field's refusal, by name;
  - an unknown source skipped and the rest kept;
  - every kind/source mismatch refused;
  - the bounds;
  - a mod's record overriding the game's;
  - an action added to another package's context.
- **Evaluation**, against a hand-written oracle over scripted snapshots:
  - each kind;
  - deadzone rescaling, 1D and radial;
  - the clamp, so a keyboard diagonal is length 1;
  - axis thresholds and their edges;
  - contexts by priority and ID;
  - blocking;
  - an action in no enabled context releasing;
  - devices and blocking flags;
  - a rebuild keeping held state.
- **Tick view:**
  - zero, one and three steps in a frame see a press exactly once;
  - motion summed across a frame with no step arrives whole at the next.
- **Rebinding:**
  - override order;
  - `rebindable false`;
  - capture of each source class, `ignore`, axis sign and tie order;
  - conflicts across contexts.
- **The bindings file:**
  - round trip;
  - refusal of past-bound and damaged files, which are left untouched;
  - unknown actions kept;
  - merge by action across two writers.
- **A digest of a 600-frame scripted sequence** (snapshots, contexts toggled, an override applied
  mid-way), folded from every frame and tick view, pinned. It is compared on all three platforms.
- **Each guard is broken once** and must fail its test:
  - the deadzone's rescale removed;
  - the vector clamp removed;
  - the tick view handing edges to every step;
  - blocking ignored;
  - focus loss not zeroing axes;
  - the y negation dropped;
  - the merge replacing the file.

**Desktop tests, run by hand on each platform:**
- `zig build gamepad-test` (§4.3);
- `zig build audio-output-test`, which enumerates, moves a running silent device to each output and
  back to the default, and checks the handle and the clock.

**The table:** `abi_input.zig` and its C99 fixture:
- every call;
- every refusal;
- `UNAVAILABLE` with no source;
- the tick view inside a system against the frame view outside;
- the loader offering 1–8;
- v1–v7's declarations unchanged byte for byte.

**The samples:**
- `court-test`'s four digests;
- `sandbox3d`'s tour pins;
- `southpaw`'s test;
- relocated, read-only ReleaseSafe installs of the court, windowed:
  - played with a pad and with keys;
  - rebound and restarted;
  - an output chosen and unplugged mid-music, with no music start late.

**Budgets:** the `input` span's p95 with the court's map, at most 0.05 ms on the M5 and the i3.
Evaluation is a few hundred table lookups. Frame pacing is unchanged against M40's.

## 14. Implementation order — eleven steps

Each step ends with a Resolution here, an updated `PROJECT_STATE.md`, the bar and a commit. There is
no automatic chaining.

### Step 1 — `platform`: captured motion in counts, and key labels

§3: `MotionMode`, `setCapturedMotion`, `motion_unit` and `keyLabel` on the interface and both
backends; the SDL hint; the stale "M5" comment. Tests: §13's motion tests. On the Mac, a windowed
check records what relative mode delivers in each mode.
**Exit:** both backends conform, the motion tests pass, and the Resolution names each platform's
expected unit, with macOS's measured.

### Step 2 — `platform`: gamepads

§4: `GamepadButton`, `GamepadAxis`, `GamepadState`, `Slots`, the events, the accumulator's rules,
`setGamepadRumble`, `InitOptions.gamepads`, the null backend's scripting, the SDL3 backend and
`gamepad-test`. The port's gamepad subsystem confirmed on each target's build.
**Exit:** the pad tests pass headless, `gamepad-test` passes on the Mac, and Windows and Linux
cross-compile with gamepads in.

### Step 3 — `platform` and `audio`: outputs

§5: `OutputId`, `OutputInfo`, `audioOutputs`, `AudioConfig.output`, `setAudioOutput`, the two
events, the SDL3 backend's open, bind, move and loss, the null backend's script, and
`Mixer.selectOutput`. `audio-output-test`.
**Exit:** the output tests pass headless, `audio-output-test` passes on the Mac, and the music
tests' scheduled starts hold across a scripted move.

### Step 4 — `input`: the module and its records

§6: the module in `build.zig` (granted to `app`, `abi` and `author`); `foundry:input_action` and
`foundry:input_context`; `Map.build` and its validation; registration in `app/engine.zig` and the
one line in `author/compiler.zig` (§1's overlap); `Source` parsing.
**Exit:** every record test passes, `fpack` compiles a package with actions, and a malformed record
is refused by name.

### Step 5 — `input`: evaluation, the tick view and rebinding

§7 and §8's `Overrides`, `Capture` and `conflicts`: the oracle tests, the pinned digest and the
guards.
**Exit:** every evaluation, tick-view and rebinding test passes, the digest is pinned, and each
guard fails when broken.

### Step 6 — `app`: actions in the frame, and the bindings file

§9 and §8's file: `engine.actions`, `Step.actions`, `Step.tick_input`, `actionFrame`,
`setInputBlocked`, `saveBindings`, reload, `Config.captured_motion`, and `app.input_bindings`.
**Exit:** a headless engine's steps see the tick view, a reload keeps held state, and the bindings
file's tests pass.

### Step 7 — `abi`: `FoundryApi_v8`, and `sandbox3d`

§10: the eleven calls, the header, the loader's 1–8, `abi.Sources.input`, `abi_input.zig` and its
fixture, `orbiter`'s action, `sandbox3d`'s walk on actions, and `docs/modding/input.md` from an
external consumer.
**Exit:** the fixture's every call and refusal pass, v1–v7 are byte-identical, `orbiter` spins on
its action in a windowed run, and every tour pin holds.

### Step 8 — the court, played on the Mac

§11's court: content, `walk.zig` on actions, Controls, prompts, rumble, Output, sensitivity, and
`southpaw`. Relocated ReleaseSafe runs, the budget, and the owner plays with a pad, rebinds,
restarts and unplugs headphones.
**Exit:** the four digests hold, `southpaw`'s test passes, the budget holds, and the owner has
played it.

### Step 9 — Windows (movable, for the PC)

`scripts/m45/`, from M40's. On the PC, idle first, from a clone, `-j2` at below-normal priority:
- the null suite and the Vulkan checks;
- the digest pin;
- `gamepad-test` and `audio-output-test`;
- §3's motion recorded;
- the court, relocated and windowed, played with a pad by a person, with an output moved and lost.

**Exit:** the pin equals the Mac's, both desktop tests pass, and the court has been played there
with a pad.

### Step 10 — Linux (movable, with Step 9's PC session)

The PC's throwaway Ubuntu, from the kit:
- the headless suite and the pin;
- `gamepad-test` with hotplug;
- §3's motion under Xorg and GNOME's Wayland;
- `audio-output-test` under PipeWire;
- the court played with a pad by a person.

**Exit:** the pin equals the Mac's, both desktop tests pass under both sessions, and the court has
been played there with a pad.

### Step 11 — Close M45 (joint with M41's close, ADR-0082)

Resolve the contract discrepancies in their documents:
- `platform-interface.md` §11 question 1 and "Deferred, deliberately"'s gamepads;
- `audio.md` §11 question 4;
- `playable3d.md` §4.2's "the engine does not normalise it" and §13's two rows;
- `public-abi.md`'s "no input snapshot" and its keyboard-state open question, and `editor.md` §13's;
- `FoundryStep`'s comment.

Then:
- move ADR-0087–0090 to Accepted and into `CLAUDE.md` §4.1;
- add `input` to §4.3, with `app`'s, `abi`'s and `author`'s grants;
- update §9's rows;
- add `gamepad-test`, `audio-output-test` and M45's runs to `AGENTS.md`;
- update the roadmap:
  - M45 done;
  - M48 becomes "Public API v9", gaining §10's list;
  - M49's "v6 to v9";
  - M146 gains §15's items;
- update the design index, the README and `PROJECT_STATE.md`;
- clean scratch and the PC;
- tag `m45` with M41's close, push when asked, and stop.

**Exit:** every document names M45 complete, and nothing names a contract the code does not have.

## 15. What stays open, deliberately

Each item names the milestone that owns it (CLAUDE.md §2, rule 17).
- **Lua bindings for input:** M49.
- **Through the table, by host grant:** enabling contexts, writing bindings, capture, rumble, and
  audio outputs and their names. All are M48's.
- **Hold-or-toggle per action, chords, remapping unknown joysticks with mapping strings, wheels and
  flight sticks, gyro aiming, touchpads and light bars:** M146, beside "full remapping". The
  trigger that shapes them is a player who cannot use the defaults.
- **Keyboard navigation and tab order in the widget set:** M44, which will read `menu.*`-style
  actions rather than keys.
- **Touch:** M139. **IME preedit:** M145. **Audio capture devices:** M132.
- **A per-window motion mode:** not built, because one game window is all the engine has. If the
  editor's multi-window work (M104) needs it, it is a field change inside that milestone.

## 16. Decisions acceptance fixes

Each is recommended as written.

| # | Choice | Where |
| --- | --- | --- |
| 1 | M45 is M41's partner, M42–M44 passed over for the reasons in §1 | §1 |
| 2 | Actions live in a new L2 module `input -> core, data, platform`, not in `platform`, `app` or `asset` (ADR-0087) | §6.1 |
| 3 | **The one overlap with M41**: Step 4 adds one registration line to `author/compiler.zig` and grants `author` the `input` module; it may be ordered after M41's last `author` step if the owner prefers | §1, Step 4 |
| 4 | `foundry:input_action`, one record per action, naming its contexts; `foundry:input_context` with `priority` and `blocks`; no label field, so text stays M46's | §6 |
| 5 | Four kinds, `button`, `axis`, `vector` and `delta`; source names `key.*`, `mouse.*` and `pad.*` from names `platform` already freezes | §6 |
| 6 | A malformed record is refused whole by name; an unknown source name is skipped with a warning | §6 |
| 7 | Deadzones are per binding and rescaled, radial for sticks; vectors are clamped to length 1 | §7 |
| 8 | Contexts by priority then ID; a blocking context hides every source it binds, pressed or not | §7 |
| 9 | The tick view: edges and deltas reach exactly one step, the first after they happened; the court's `Pending` goes | §7, §11 |
| 10 | A player's override replaces an action's bindings whole; player over the last package over the game; `rebindable false` ignores it (ADR-0088) | §8 |
| 11 | Capture ignores motion and the caller's cancel sources; conflicts are reported and the game decides | §8 |
| 12 | `bindings.fset` under `foundry:input_bindings`, merged by action, unknown actions kept, never content (ADR-0088) | §8 |
| 13 | Pad buttons by position, labels and kind reported separately; four fixed slots with generational handles; a fifth waits (ADR-0089) | §4 |
| 14 | Pad axes unfiltered, sticks +y up, triggers [0, 1]; focus loss releases and zeroes; rumble is output only | §4 |
| 15 | Captured motion in the device's counts by default (`raw`), `system` selectable; `motion_unit` reports what is true; correcting `playable3d.md` §4.2 at the close (ADR-0089) | §3 |
| 16 | A Foundry audio device survives a change of output by rebinding its stream; a lost chosen output falls back to the default and emits an event; names are never logged or published | §5 |
| 17 | The owner provides at least one physical pad (two kinds preferred) for Steps 2, 8, 9 and 10; which pads they have is the one question this design asks, and it does not block Step 1 | §12 |
| 18 | `FoundryApi_v8`: eleven read-only calls, 275 in all, as the tick sees it inside a system; M48 becomes v9 and M49 "v6 to v9"; correcting `public-abi.md`'s "no input snapshot" at the close (ADR-0090) | §10 |
| 19 | Enabling contexts, bindings writes, capture, rumble and audio outputs through the table go to M48 | §10, §15 |
| 20 | The court on actions with Controls, prompts from bindings, rumble and Output; `southpaw`; `sandbox3d`'s walk on actions; `orbiter`'s own action | §11 |
| 21 | The PC runs Steps 9 and 10, both movable around M41's use of it; Linux is a run, not compile only | §12 |
| 22 | Eleven steps, as §14; the close is joint with M41's | §14 |
| 23 | §15's items go to M44, M48, M49, M132, M139, M145 and M146; Step 11 writes each into its row | §15 |

Once these are accepted, nothing blocks Step 1. It is one platform call, one snapshot field and one
hint, on the code as it is.

## Resolution — Step 1: captured motion in counts, and key labels (2026-11-15)

The design was accepted when the owner asked for Step 1. Its status line records that. The four
ADRs stay Proposed until the close, as §14's Step 11 says.

**What the step pinned:**
- `input.zig` gains `MotionMode { raw, system }`, `MotionUnit { points, counts }` and
  `capturedUnit(mode, raw_available)`. `MouseState.motion_unit` names what `motion` holds.
  `platform` re-exports both enums.
- The interface gains two calls, eighteen in all:
  - `setCapturedMotion(*P, MotionMode) void`. It cannot fail. `motion_unit` reports the result.
  - `keyLabel(*P, Key, *[key.label_capacity]u8) []const u8`, with a capacity of 16.
- **`key.boundedLabel`** is the one bounded copy. It returns valid UTF-8 with no NUL, cut on a
  codepoint boundary. Text that is invalid or holds a NUL gives an empty label. Every `Key`
  name fits whole.
- **Null:**
  - `raw` by default;
  - a key's label is its own name, and `unknown`'s is empty;
  - `setRawMotionAvailable` is the test affordance that plays a platform which cannot deliver
    counts.
- **SDL3:**
  - `MOUSE_RELATIVE_SYSTEM_SCALE` is set to `0` for `raw` and `1` for `system`. It is applied at
    `init`, not assumed.
  - `keyLabel` calls `SDL_GetKeyFromScancode` with no modifiers, then `SDL_GetKeyName`. A key the
    layout gives no name falls back to its physical name.
  - Its scancode table is `keyFromScancode` inverted at compile time, so the two cannot disagree.
  - The two stale "M5" comments now name what is actually deferred: gamepads (Step 2), audio
    device changes (Step 3) and touch (M139).

**Where the code sharpened the design:**
- **A frame's sum never mixes units.** A snapshot names one unit, but a capture can begin or end
  inside a frame. Motion that arrives in a different unit from the running sum replaces the sum
  instead of being added to it. A sum keeps the unit it was made in, so counts summed before a
  focus loss still say `counts`. An idle frame reports the unit capture would deliver now. The
  cost is the motion of one frame at the moment of a change.
- **The hints are set at `SDL_HINT_OVERRIDE`.** At normal priority, an `SDL_MOUSE_RELATIVE_*`
  environment variable would win, and `motion_unit` would describe a mode SDL is not using. For
  the same reason `MOUSE_RELATIVE_SPEED_SCALE` is cleared: SDL applies it after either mode, and
  sensitivity belongs to the game.
- **A mode change flushes SDL's queued motion events.** Those events were measured in the old
  mode. SDL does the same when relative mode itself changes. If a hint cannot be set, the old
  mode stays, and so does its unit.

**What each platform delivers, from SDL 3.4.14's sources** (`events/SDL_mouse.c`, where
`ApplySystemScale` runs only when the hint is on):

| Window system | `raw` | `system` |
| --- | --- | --- |
| `windows` | raw input's `lLastX`/`lLastY`: **counts** | SDL's model of Windows' ballistics (`WIN_ApplySystemScale`): points |
| `x11` | XInput2 `raw_values`: **counts** | XInput2 `valuators`, accelerated: points |
| `wayland` | relative-pointer `dx_unaccel`: **counts** | `dx` times the pointer scale: points |
| `cocoa` | `-[NSEvent deltaX]`: **points** | the same: points |

- **macOS cannot honour `raw`, and reports `points` in both modes.** Cocoa installs no system-scale
  model. SDL reads `NSEvent`'s deltas, which macOS has already put through its pointer
  acceleration, so the hint changes nothing there.
- X11 and Wayland can capture only through XInput2 or the relative-pointer protocol. Without them
  capture answers `Unsupported`, so a held capture on those systems always delivers counts.
- `rawMotionOfDriver` is the table above. Any other driver (`offscreen`, `dummy`, `kmsdrm`, an
  unknown one) is assumed to deliver points, because calling points counts is the one wrong
  answer.
- **A known limit on Windows:** a device that reports absolute positions, such as a remote desktop
  session, a pen tablet or some virtual machines, gives SDL differences of screen positions.
  Those are labelled `counts` and are not.

**The macOS limit needs an owner (rule 17), which is the owner's decision.**
- The fix would be the GameController framework's `GCMouse`, which delivers unaccelerated HID
  deltas. SDL uses it only on iOS. On macOS it would mean Foundry's own Objective-C in
  `platform`, beside the framework Step 2 links for pads.
- It is not built here. The choice is to add it to Step 2 (recommended, since it is the same
  framework), or to name M146.
- Until then, a sensitivity tuned on a Mac does not carry to the other platforms. That is
  exactly the problem §3 set out to remove.

**The check on the Mac:**
- `zig build native-window-test` gains "this window system's captured-motion unit, and its
  layout's key labels". It opens no window and takes no pointer. It asserts three things:
  - Cocoa does not offer counts, while Windows and Linux do;
  - the unit each mode reports;
  - every key's label is bounded valid UTF-8, empty only for `unknown`, and `Space`, `Escape` and
    `Left Shift` are SDL's names.
- It passed on the M5.
- **Not measured: what a moving mouse delivers under capture in each mode.** That needs a person
  moving the mouse. It awaits the owner, who would run `zig build sandbox3d -Drhi=metal`, capture
  the pointer, move the same distance in each mode and compare. No mode switch is exposed to a
  sample until Step 6's `Config.captured_motion`. From the sources, both modes are expected to
  give equal, accelerated points.

**Each guard was broken once, and each failed its test:**
- `capturedUnit` answering `counts` for a backend without raw failed the input, null and SDL3
  unit tests;
- the sum's restart removed failed "a frame's motion sum never mixes points and counts" and the
  null focus-loss test;
- the label's codepoint step-back removed failed the label test;
- `cocoa` added to `rawMotionOfDriver` failed the SDL3 driver test.

**Bar:** every line of `AGENTS.md` §3 passes, plus four extras: `zig build test -Drhi=metal`,
`native-window-test`, and SDL3 (not null) `check` for Windows and Linux, the Windows one also at
ReleaseSafe, because the backend's C calls changed. The counts:
- null 3,033/3,043 (ten skips), nine more than M40 for the new tests;
- Metal 3,044/3,065 (21 skips);
- `native-window-test` 3/10 (seven skips: the other tests are for Windows and Linux);
- every check, the four thirty-frame samples and `fdt-check`.

No Vulkan check applies: no shader, RHI or native-window code changed. Outside
`engine/src/platform`, only `engine/tests/native_window.zig` changed.

## Resolution — Step 2: gamepads (2026-11-15)

Done by an Opus agent in its own worktree, as ADR-0082's partner half, beside M41 Step 2. The primary session ran the bar and committed it after the agent hit its usage limit.

**What the step pinned:**
- **`platform/gamepad.zig`**, new, holds everything §4 names:
  - `GamepadButton` (21 positional names, §4.1's list in its order, `south` = 0) and
    `GamepadAxis` (6), each with `name`/`fromName`, append-only;
  - `GamepadKind`, `ButtonLabel`, and `FaceLabels`, the four face labels in `south east west
    north` order;
  - `GamepadState` and `GamepadHandle = core.Handle(Gamepad)`, with `max_gamepads = 4`;
  - `normalizeAxis(axis, raw: i16)`, the one place §4.2's rule lives (divide by 32,767, clamp at
    -1, negate a stick's y, clamp a trigger at 0). Both backends call it;
  - `rumbleValid`, `rumbleLevel` and `max_rumble_ms = 10_000`;
  - `Slots`, the shared seating rule.
- **Five events:** `gamepad_added`, `gamepad_removed`, `gamepad_button_down`/`up` and
  `gamepad_axis`. An axis event carries the value already normalised.
- **The snapshot:** `InputSnapshot.gamepads: [4]GamepadState`, by slot.
  `gamepadState(handle)` answers null for a stale handle. That null is how a game learns its pad
  left or was replaced. `isIdle` counts pad buttons. It does not count axes, which are positions
  like the mouse's.
- **The interface:** `setGamepadRumble(*P, GamepadHandle, f32, f32, u32)`, nineteen calls in all.
  `InitOptions.gamepads` defaults to true.
- **Null:** `connectGamepad(device, PadDescription)`, `disconnectGamepad`, `setGamepadButton`,
  `setGamepadAxis` (a raw `i16`, normalised as SDL's are) and `lastRumble`. With gamepads off it
  seats nothing.
- **SDL3:**
  - `SDL_InitSubSystem(SDL_INIT_GAMEPAD)` after video, when `InitOptions.gamepads` is set. If SDL
    refuses, the platform warns and carries on with no pads. It is quit in `releaseSdl`.
  - A pad is opened when it is seated. A waiting pad is opened only when it takes a slot. If SDL
    then refuses to open it, it is unseated and the next waiter is offered the slot.
  - Kind comes from `SDL_GetGamepadType`. The face labels come from
    `SDL_GetGamepadButtonLabel`, read once when the pad is seated.
  - SDL's `MISC2`–`MISC6` are dropped.
  - A joystick SDL cannot map is counted (`unmapped_joysticks`) and logged at info.
  - `sdl_button_of` is `buttonFromSdl` inverted at compile time, so the two cannot disagree.
  - `SDL_EVENT_GAMEPAD_REMAPPED` is dropped. A remap that changes a pad's type mid-session keeps
    the kind and labels it was seated with until it reconnects.
- **`zig build gamepad-test`** (`engine/tests/gamepad.zig`), beside `native-window-test`, is
  compiled by `check`. It attaches SDL virtual joysticks, described as gamepads, with real
  vendor and product IDs (an Xbox One pad, a DualSense). It checks:
  - kind and labels (`a`/`y`, and `cross` on the second pad);
  - buttons, including `left_paddle1` against SDL's right-first paddle order;
  - axes: SDL's -32768 on `left_y` arrives as +1, and 16384 on `right_x` as 0.5;
  - rumble reaching the driver as 16-bit levels, while a refused request reaches no driver;
  - four slots in order, a fifth whose buttons go nowhere while it waits, and the fifth taking
    slot 1 under a new handle when player two unplugs, after which the old handle's rumble is
    refused;
  - with `gamepads = false`, no virtual pad can be attached.

  It opens no window. SDL delivers pad events to a process that has none. It skips, with a
  message, if a physical pad is attached, because that pad would take slot 0.

**Where the code sharpened the design:**
- **`gamepad_added` carries the pad's kind and face labels.** §4.2 gave it `{ pad }` alone. But the
  snapshot is built from events only, which is the accumulator's rule, so what a pad is has to
  arrive in its event. The accumulator never asks a device.
- **Labels are per pad, not derived from its kind.** SDL reads a face style from each pad's
  mapping. A GameCube pad and a Switch pad are both `nintendo` yet print different letters in
  the same places (`AXBY` and `BAYX`). So the slot stores the four labels SDL reports, and
  `GamepadState.labelOf(button)` returns them, or `none` for any button that is not a face
  button.
- **`setGamepadRumble` gains `InvalidRumble`.** §4.3's error set had only `InvalidGamepad` and
  `Unsupported`, but §13 asks for an out-of-range strength to be refused. A strength outside
  [0, 1], NaN, or a duration over 10 s now answers `InvalidRumble`. A stale handle is checked
  first.
- **The waiting queue is bounded at twelve.** A pad beyond the four seated and twelve waiting is
  ignored and counted (`Slots.overflowed`), so the queue never allocates.
- **A slot's edges belong to the pad its handle names.** When a waiting pad takes a slot in the
  same frame the old pad left it, the new pad starts clean. The old pad's release edges are not
  shown, and the game sees the handle change instead. When nothing is waiting, the frame a pad
  leaves reports its held buttons released, as §4.2 says.
- **Events for a stale handle are dropped** by the accumulator rather than applied to whatever
  pad now holds the slot.
- **The null backend scripts in device terms, not raw `pushEvent`s.** A pushed `gamepad_added`
  with an invented handle would bypass `Slots`. The affordances run the shared rule and then
  queue the events, so the null backend seats pads exactly as SDL's does.
- **No initial state is synthesised when a pad is seated.** SDL's drivers send a pad's first
  report as ordinary events. Reading it again at open time could deliver a second press edge on
  the next frame.

**The port's gamepad subsystem, read from castholm's `build.zig` (v0.5.3, SDL 3.4.14).** No port
option is needed on any target, and no dependency changes:
- **macOS:** joysticks through IOKit, MFi (the GameController framework) and HIDAPI, with
  IOKit haptics. The port already links `GameController`, `IOKit`, `ForceFeedback` and, weakly,
  `CoreHaptics`, for SDL's own MFi driver, in every macOS SDL3 build. So Foundry's own
  `GCMouse` path for raw counts on macOS (Step 1's open decision, the owner's) would add no
  framework to the link. That is all this step says about it; nothing of `GCMouse` is built.
- **Windows:** XInput, raw input, DirectInput and HIDAPI, with DirectInput haptics.
  **Correction to §4.3 and §12: WGI is not built.** The port hard-codes `SDL_JOYSTICK_WGI =
  false`, and GameInput is built only for MSVC targets. Xbox pads arrive through XInput and raw
  input, and other pads through HIDAPI. Only trigger rumble is lost, which Foundry does not use.
  Step 9 proves it on the PC.
- **Linux:** evdev and HIDAPI, with Linux haptics. `libudev` is compiled in and loaded at run time
  by its soname, from `sdl_linux_deps`. Without it, SDL enumerates `/dev/input` through inotify,
  so hotplug still works. Step 10 checks it on the throwaway Ubuntu.

**Each guard was broken once, and each failed its test:**
- the y negation dropped failed the normalisation test, the null scripted-pad test and the SDL3
  translation test;
- focus loss not releasing pads failed the accumulator's and the null backend's focus tests;
- a release that kept axes failed both focus tests and both removal tests;
- seating in a slot other than the lowest free one failed two slot tests and two null tests;
- the waiting pad never promoted failed both queue tests and the null fifth-pad test;
- stale-handle events applied to the slot failed the removal test;
- rumble accepting NaN failed the rumble tests in `gamepad.zig` and in null.

**Bar:** the agent hit its usage limit during the bar, so the primary session reran the whole of
it in the agent's worktree. `zig fmt --check`, every `check` (native, Metal, Linux and Windows
null, and SDL3 Linux, Windows and Windows ReleaseSafe), the four thirty-frame samples and
`fdt-check` pass. Tests: null 3,063/3,073 (ten skips), Metal 3,078/3,099 (21 skips),
`gamepad-test` 3/3, `native-window-test` 3/10 (seven skips, as at Step 1).

Nothing outside `platform` changed except `samples/sandbox/main.zig`, whose `report` gains the
five pad events in its exhaustive switch, `build.zig`, for `gamepad-test`, and the new test file.
No Vulkan check applies: no shader, RHI or native-window code changed.
