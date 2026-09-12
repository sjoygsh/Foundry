# Foundry Roadmap

Staged milestones from a minimal engine toward 2D, then 3D.

**Milestones are units of work, not units of time.** No dates. Sessions are bounded by
available context, so each milestone is sized to be resumable from `PROJECT_STATE.md` alone,
and each leaves behind something that runs.

**Rules for every milestone:**

* It produces a runnable result — `samples/sandbox` must still start and do something on
  macOS.
* `zig build test` passes.
* Non-rendering modules still **cross-compile** for `x86_64-windows` and `x86_64-linux`
  (ADR-0008). No obligation to *run* them there until a backend for those platforms exists.
* Any new dependency arrived with its `THIRD_PARTY_LICENSES/` entry in the same commit.
* `PROJECT_STATE.md` is updated. A milestone is not done until it is.
* Design docs for anything non-trivial are written **before** implementation, in
  `docs/design/` (see that directory's README for what is owed and when).

---

## Phase 1 — Foundation

### M0 — Skeleton: "it runs" — **complete (2026-09-03)**

The smallest useful version of Foundry. Deliberately excludes the GPU.

*Exit criteria met: `zig build run` opens a window on macOS that responds to input, and
both platform backends cross-compile for Windows and Linux. 222 tests.*

**Setup, before code:**

* Install the pinned stable Zig release from the official tarball at a versioned path; record
  version and SHA256 in `.zigversion` and `build.zig.zon` (ADR-0001, ADR-0014).
* **Verify the SDL3 Zig package builds against that release, for macOS first.** This is the
  main risk in M0; fallbacks are documented in ADR-0002. Record SDL3's zlib license entry in
  `THIRD_PARTY_LICENSES/` in the same commit.
* Confirm cross-compilation to `x86_64-windows` and `x86_64-linux` actually works before
  relying on it.

**Then:**

* `build.zig` with the module graph from ADR-0007, so layering is enforced from the first line
  of code.
* `core`: allocators (general, arena, pool), generational handle table, string IDs and hashing,
  logging with subsystem scopes, assertions, math basics, time, explicit RNG.
* `platform`: window creation, event pump, keyboard/mouse input, high-resolution clock,
  filesystem basics, opaque `NativeSurfaceHandle`. SDL3 confined here.
* `app`: fixed-timestep loop with interpolated render step (I9), subsystem lifecycle
  ordering, clean exit.
* `rhi`: interface definition plus the **null backend** only.
* `samples/sandbox`: opens a window, logs input, runs the loop, exits cleanly.
* Test harness running; a script that builds all three targets.

**Exit criteria:** a window opens and responds to input on macOS; Windows and Linux
cross-compiles succeed for the non-rendering modules.

**Not in this milestone:** anything drawn.

### M1 — First pixels: "it draws" — **complete (2026-09-04)**

*Exit criteria met: `zig build run -Drhi=metal` draws a rotating, nearest-filtered textured
quad that survives being resized, with Metal API and shader validation clean and the null
validation backend raising no complaints about the same command stream. 227 tests under
`-Drhi=null`, 235 under `-Drhi=metal`. Xcode GPU frame capture is confirmed by its
prerequisites — the sandbox runs clean under `MTL_CAPTURE_ENABLED=1` and shaders carry
`-frecord-sources` — but no trace has been opened in Xcode yet.*

Preceded by `docs/design/rhi.md` — **the highest-leverage document in the project.** It must
include the concept mapping table across Metal, Vulkan and D3D12 (ADR-0003). Designing the RHI
against Metal alone is the single most likely way to force a renderer rewrite later.

* Metal backend via the Objective-C shim (ADR-0012): device, command queue, `CAMetalLayer`
  from SDL3, pipeline state objects, buffers, textures, draw submission, resize handling.
* Metal shader build step: `xcrun metal` → `.air` → `xcrun metallib`, wired into `build.zig`
  (ADR-0015).
* Runtime MSL compilation path for development builds, giving shader hot reload.
* Null backend upgraded to a **validation backend** — enforcing the strict, Vulkan-shaped rules
  Metal silently forgives. This is what partially substitutes for not having a second backend.
* Metal API validation enabled in debug builds; Xcode GPU frame capture confirmed working.

**Exit criteria:** a textured quad on screen, surviving window resize, with Metal validation
clean and the null backend raising no complaints about the same command stream.

**Not in this milestone:** batching, materials, anything 3D-specific.

---

## Phase 2 — A real 2D engine

### M2 — Sprites: "it draws a lot" — **complete (2026-09-04)**

* Sprite batching; texture atlas support; texture loading from disk (PNG decode).
* 2D camera with pan/zoom; screen and world coordinate spaces.
* Bitmap text rendering.
* Frame statistics: frame time, draw calls, batch count.

**Exit criteria:** thousands of sprites at a stable frame rate, with a camera and on-screen text.

*Exit criteria met: `zig build run -Drhi=metal` draws 4,185 sprites at vsync under a camera
driven by keyboard and mouse, with the batcher's own statistics on screen in a screen-space
view that does not move when the camera does — 4 batches and 4 draw calls, because the sheet,
the font and the selection outline share one atlas. Metal API and GPU validation clean over
2,400 frames; the null validation backend raises no complaints about the same command
stream. 346 tests under `-Drhi=null`, 354 under `-Drhi=metal`, all eight target/backend
combinations compiling.*

*Read the batch count as M2's. At M3 step 9 the sample's images became assets, which arrive
as standalone textures, so it draws 5 batches now. `render2d`'s atlas is unchanged and still
covered by its own tests; the sample stopped using it, and making it an atlas again is a
decision about what an asset is (`docs/design/assets.md` §9).*

*Two things arrived that the entry does not name. `render2d` gained **views** — a per-frame
table of spaces rather than a screen/world flag — because the statistics readout needed a
second space and a boolean would have answered M2 and nothing after it. `rhi` gained
`dst_origin` on a buffer-to-texture copy, without which packing one sprite into an atlas
means re-uploading the whole thing; rule 10 in `rhi.md` §11 grew to match, before the code.*

### M3 — Content: "it has data" — **complete (2026-09-05)** — *first modding-relevant milestone*

* ~~Schema system: record types with typed fields, versioned.~~
* ~~Content packages, ordered load, override-by-ID (replace semantics first).~~
* ~~Authoring text format~~ — **syntax decided here** (`CLAUDE.md` §9). *Decided 2026-09-04:
  Foundry's own `.fdt` (ADR-0020), specified in `docs/design/content-schemas.md` §4.*
* ~~Runtime binary format and `tools/fpack` to compile one to the other.~~
* ~~`asset`: registry, loading by content ID, reference counting.~~ *Asset identity decided
  2026-09-04: assets are content records, and a path derives an ID but never defines it
  (ADR-0021), specified in `docs/design/assets.md`.*
  * **Shaders did not become assets, deliberately.** Engine-owned shaders stay embedded
    (ADR-0019) and the sprite shader is one; the only remaining case is a *content-owned*
    shader, which needs something to reference it. Building an asset kind with per-backend
    variant selection (ADR-0015) for no consumer would be exactly the hypothetical
    requirement rule 7 warns about. **Due with the material system**, which is Phase 5 or
    whenever a sample needs its own shader — and the asset kind is a schema and a loader
    registered at runtime, so nothing has to be reshaped to add it.
* ~~Hot reload of content and assets in development builds.~~
* ~~Base game content moved into `content/core` as package zero (I3).~~
* ~~`docs/modding/` begins.~~

**Exit criteria — all three met and seen, not inferred:**

1. *The sandbox's content lives entirely in data.* Its sprite sheet, its font, its sheet
   grid, its banner and its sprite count are records in packages; it embeds nothing and
   names no path. What remains in Zig is the sample's own behaviour — camera speeds, zoom
   limits, HUD margins — which is code, not content.
2. *A second package placed after it overrides a value and the change is visible.* A package
   compiled with `fpack` into `zig-out/content/` and named in `FOUNDRY_SANDBOX_PACKAGES`
   changed the sprite count from 4000 to 250 and replaced `foundry:fonts.debug` with an
   image at `whatever/i/like/glyphs.png` — a path mirroring nothing.
3. *Editing a content file live-updates the running program.* Under Metal, windowed: editing
   `sandbox.fdt` and recompiling the package changed the field from 4000 sprites to 300 and
   changed the banner text, mid-run, with a clean exit. Replacing a `.png` alone reloads the
   texture behind its handle with no package recompile at all.

**At this point Tier 1 content modding effectively works**, long before the mod system
exists — and `docs/modding/content-mods.md` is written by doing it, then verified by
following it verbatim.

### M4 — World: "it has entities" — **complete (2026-09-05)**

* Entity storage: generational handles, sparse set with dense per-component arrays.
* Type-erased component storage with runtime-registered `ComponentTypeInfo` (ADR-0010).
* `comptime` wrapper for ergonomic native component registration.
* Queries and iteration that do not leak storage layout, with **stable documented iteration
  order** (I9).
* System registration and ordered update.
* Save/load of world state in its own versioned format, sharing the field-block layout and
  schema encoding with the package format. **Not** through the record system: giving every
  entity a content ID would derive identity from position, which is what I2 forbids
  (`docs/design/entity-storage.md` §9).

**Exit criteria:** a scene of entities defined in content data, updated by systems, saved and
reloaded correctly across a restart. A fixed scenario run twice produces identical state.

### M5 — Playable: "it's a game" — **complete (2026-09-06)**

*Exit criteria met: `samples/room` was played and judged, and the mixer was listened to. Both
were things no amount of building could establish — the first is whether a hall reads as a
place rather than as a demonstration, the second is whether an envelope clicks — and both were
answered by a person, which is the only way either of them can be. 796 tests under `-Drhi=null`,
804 under `-Drhi=metal`.*

*The engine gained nothing for the playable sample. Not one line under `engine/`, and
`tools/fpack` did not change either, which is the strongest form this milestone's evidence can
take: the claim is that Foundry can carry a game, and a second consumer that needed no engine
change is the proof of it.*

*Both `CLAUDE.md` §9 decisions that came due here were made before any code: physics is
Foundry's own, scoped to collision rather than dynamics (ADR-0022), and audio is Foundry's own
mixer and WAV decoding over the device `platform` was already chartered to provide
(ADR-0023). The sample is **top-down tile movement**, which is what decides that gravity and
slopes are out of M5's collision scope.*

* ~~Tilemaps with efficient rendering and collision~~ — `docs/design/tilemaps-and-collision.md`.
  *Done 2026-09-06.*
* ~~2D collision detection and response; spatial partitioning~~ — the new **`physics2d`**
  module, L1 on `core` alone. *Done 2026-09-06.*
* ~~Sprite animation: clips, state, timing~~ — `docs/design/sprite-animation.md`.
  *Done 2026-09-06.*
* ~~Audio: device output, sound loading, mixing, playback by content ID~~ — the new **`audio`**
  module at L3, plus an audio device in `platform` and WAV decoding in `asset`;
  `docs/design/audio.md`. *Done 2026-09-06.*
* ~~A small but genuinely playable sample~~ — the new **`samples/room`**, a second sample
  that *is* a small game rather than a demonstration of one. *Done 2026-09-06.*

*All three design documents are written (2026-09-05). Each carries its own implementation
order — §15, §13 and §10 respectively — and the three are independent sequences that share
only the frame that calls them. **The collision sequence is complete** (steps 1-7, finished
2026-09-06): `physics2d` is complete as a module — shapes, tile grids, the broadphase,
`moveAndSlide`, `resolveOverlaps` and the four queries — a map is content, from a hand-written
text grid through `fpack` to a body that cannot walk through a wall; the sandbox draws the
room it ships, culled to the camera; and a player walks that room and is stopped by it. The
last step added nothing to the engine: a collision world, a `sandbox:collider` and the wiring,
all of it in the sample, which is what §11 said would happen. **The sprite-animation sequence
is complete too** (steps 1-3, finished 2026-09-06): `frameAt`, `frameAtVarying` and
`Region.cell` are the engine's whole contribution, the clip schema and the animation component
are the sample's, and an animated sprite saved mid-clip reloads onto the frame it was drawing
— compared as the UVs a draw call would carry, because an epsilon there would pass for the
float accumulator §4 refuses. A package placed after the sample retimed and reskinned the
player's walk with no rebuild, which is §7's Tier 1 claim paid. **The audio sequence is
complete** as well (steps 1-6, finished 2026-09-06), and it is the one that brought a second
thread into the project: the device calls Foundry on a thread it owns and under a deadline, so
the mixer's state is split by which thread owns it, two single-producer/single-consumer rings
carry commands out and retirements back, and no lock appears anywhere. A `.wav` in a package
becomes a `foundry:sound` from its path with no code at all; the sandbox walks, and the
footsteps, the thud against a wall and the ambience panned by where the player stands all come
from the package it ships. A mod replaced a sound the sample never wrote a record for, from a
file under its own directory layout, with nothing rebuilt but the mod.*

**Exit criteria:** something a person can play for five minutes without knowing it is a tech
demo.

*A note on the number, because it was not met literally and should not be quietly rounded up.*
The autopilot finishes the hall in 1,542 ticks — about twenty-six seconds of simulated time —
and it knows where every lamp is. A person exploring takes longer, but not five minutes, and
`samples/room` was deliberately not grown until it did: a sample that keeps adding rooms to hit
a number has started wanting features rather than being the smallest thing that is a game, and
ADR-0017 says what happens next to a sample like that. **The half of the criterion that was
actually load-bearing is "without knowing it is a tech demo"**, and that half was met.

*On that last bullet and ADR-0017.* This entry used to ask for a playable
`samples/sandbox` in one line and insist a paragraph later that the sandbox stay a
demonstration, which is two requirements that cannot both be met by one artifact — by M5 the
sandbox carried four thousand orbiting sprites, a frame-statistics readout, entity picking,
world save and load and a resize key, every one of them evidence for an earlier milestone and
all of them exactly what "without knowing it is a tech demo" rules out. **The answer is that
`samples/` was always plural.** `CLAUDE.md` §4.5 says a sample is the smallest thing that
exercises a capability; being playable is a capability like any other, and it gets its own
smallest thing. `samples/sandbox` keeps demonstrating M0–M5 and `samples/room` is the game.

The line ADR-0017 draws is unmoved and is what keeps `samples/room` honest: it is the
smallest thing that can be called a game — a hall, a walker, six lamps, a door and a way out
— and the moment it starts wanting features rather than being one, it has outgrown this
repository and the answer is a game in its own repository, not a bigger sample. The exit
criterion is evidence that **Foundry can carry a game**, and the strongest form that evidence
takes is what the engine had to gain for the room to run, which is **nothing**: not one line
under `engine/` changed, and `tools/fpack` did not either.

### M6 — Tools: "it's inspectable" — **complete (2026-09-06 to 2026-09-07)**

* ~~In-process immediate-mode debug overlay — UI toolkit decision made here.~~ **Decision made,
  [ADR-0024](adr/0024-ui-own-immediate-mode.md): Foundry writes its own immediate-mode UI, one
  kernel with two widget sets. Designed in [`design/ui.md`](design/ui.md); §16 is the step list.
  **Implemented in full, steps 1-6, 2026-09-06/07** — the kernel, the debug widget set, the
  walker in `app`, the overlay in `samples/sandbox` and the card `samples/room` opens over its
  live hall, which is where §4's capture rules are proven by a game rather than by a test.**
* ~~Entity inspector, content browser, log console.~~ **Done** — three of `debug`'s five panels.
* ~~Frame profiler with per-subsystem timing; memory reporting per allocator.~~ **Done** —
  `core.profile` and `Engine.beginScope` with seven engine spans; `core.mem.Counted` and the
  engine's counter registry. The clock stays above the subsystems, which is what keeps I9's
  ADR-0007 property intact.
* ~~Introspection APIs designed with the future public ABI in mind (ADR-0004, ADR-0011).~~
  **Done** — `World.liveEntities`, `World.componentTypes`, `World.describeComponent`,
  `data.Registry.all`, `Store.definitions`, `asset.Registry.assets`, and the rule
  ([ADR-0025](adr/0025-debug-overlay-module.md)) that the overlay may use no call the ABI could
  not expose.

**Exit criteria:** a performance problem can be diagnosed from inside the running game. **Met,
and on the overlay itself.** `ui.md` had recorded the overlay's batch count three times — six,
ten, fifteen — with a suspected cause and no measurement; with five panels open it is 32. The
overlay reported the number, toggling its own panels moved it, and
`engine/tests/overlay_batches.zig` attributed every break: **29 of 31 involve a texture change**
(the blank patch and the font atlas are two textures, and the batcher preserves submission order
rather than sorting by texture), and 2 are a clip change alone — a second cause nobody had
written down. One texture behind both would leave **12**. The model is asserted to reproduce
`frameStats().batches` exactly, so the split is arithmetic rather than inference, and the fix is
left to `render2d` with its value measured first (rule 2).

The last three bullets have their **own** design document, [`design/debug-overlay.md`](design/debug-overlay.md),
**written 2026-09-07** after `ui.md` was implemented rather than beside it — which is what let §11
answer `ui.md`'s open culling question with a convention the finished widget set already supports.
§17 is the step list. [ADR-0025](adr/0025-debug-overlay-module.md) carries the structural decision
it rests on: the overlay is a module above `app`, and it may use **no call the public ABI could
not expose**, so that the editor at M15 is a re-host rather than a rewrite and a mod gets tooling
at M7 through the same calls. The fourth bullet is where this milestone's lasting value is — the
widgets are replaceable, the introspection APIs reach the ABI at M7.

---

## Phase 3 — Modding and shipping

### M7 — Moddable: "others can extend it" — **complete (2026-09-07 to 2026-09-09)**

* The public C ABI: `FoundryApi_v1` table, opaque handles, versioning (ADR-0004).
* Mod manifests: ID, version, dependencies, compatibility range, **license field** (ADR-0016).
* Mod discovery, dependency resolution, deterministic load order.
* Native mod loading through dynamic libraries (Tier 3).
* Untrusted-input validation across the whole boundary.
* Mod-facing API documentation in `docs/modding/`.

**Exit criterion met:** a C99 mod built outside the engine tree against only the installed
`foundry.h` was discovered as a package, loaded its own content, registered a component type
and system, and changed its content-supplied value from 41 to 42 on the first update — without
an engine source change. The author guide in `docs/modding/native-mods.md` was followed
verbatim to build the package and library, then the result was run through an external host.

**At opening, it followed the last five milestones: it began at the decisions, before the design
document.** The two ADRs were both `Proposed`; the first is a correction rather than a new
question.

[**ADR-0026**](adr/0026-abi-module-and-host.md) — **`abi -> app` is wrong and the build graph
says so.** ADR-0007 wrote that line on the project's second day and ADR-0025 copied it forward;
`app` depends on `core`, `data`, `platform`, `ui`, `rhi`, `asset` and `render2d`, and **not** on
`scene`, `audio` or `physics2d`, each absence deliberate and each with a comment saying why. Six
design documents have meanwhile committed, in the "what this exposes to mods" sections
`CLAUDE.md` §5 requires, to publishing entities, systems, queries, voices, bodies and contacts —
three of those modules. `app` does not *own* the subsystems either: no world, no renderer, no
mixer, no collision world, because the game owns them. So `abi` becomes a peer of `debug` at L5
and the **host supplies its subsystems**, which is `debug.Sources` one milestone later and for
the same reason. A capability whose subsystem is absent answers `Unavailable`; the table's shape
never changes, because that is most of what a version means.

[**ADR-0027**](adr/0027-mods-are-content-packages.md) — **a mod is a content package**, and its
manifest is a `foundry:mod` record inside it, using an engine-declared schema; `content/core`
carries its own record like every other package. Every tier is a package with something optional
attached, so identity, version, dependencies and the license field ADR-0016 asks for are a
record like any other — no second format, no sidecar to keep in sync, no identity derived from a
folder name. `fpack` reads the name and version from the manifest instead of the command line.
Discovery, resolution and load order become a new L2 module `mod`, **below `app`**, because a
Tier 1 mod list has to be computable by a game that loads no code at all, and because its output
is exactly the ordered list `app.Config.content` already takes — so `data` still consumes an
order and does not compute one.

**Both accepted 2026-09-07, and [`design/public-abi.md`](design/public-abi.md) is written
against them the same day** — the table and the mod lifecycle together, because a manifest naming
a library the table could not receive would be two designs that only look like one. §19 is the
implementation order, seven steps. At that point nothing was implemented against it yet.

The document settles three things worth knowing without reading it. **The only signature frozen
forever is `foundry_mod_init(get_api, self)`** — a *query function* rather than the table itself,
which is what makes ADR-0004's "added alongside, never replacing" implementable at all rather
than a matrix of entry points. **Every pointer the API hands out is borrowed until the mod returns
control**, so no call in `_v1` transfers ownership in either direction and there is nothing to
explain per call. And **the one engine change the boundary forces** is `scene`'s mutation guard,
which asserts on a premise `entity-storage.md` §5 stated explicitly — "a programmer error in
engine or game code, not untrusted input" — that the ABI falsifies. That is the instance ADR-0025
predicted and named as its own falsification test, and the reasoning being written down is what
made checking it one paragraph instead of an audit.

**Step 1 of §19 is done (2026-09-07): the `mod` module.** `engine/src/mod/` is a new L2 module —
manifests, discovery, dependency resolution, a stable topological sort — and every package in the
repository, the engine's own included, now carries a `foundry:mod` record naming itself. `fpack`
reads a package's name and version from that record and lost `--name` and `--version`;
`build.zig`'s content table lost its `id` column, so a package's identity is stated in exactly one
place. **Both samples compute their load order rather than writing it**, naming only the package
they cannot run without and the package they are, and `FOUNDRY_SANDBOX_PACKAGES` now takes
**content ids** instead of filenames — which is the visible half of ADR-0027. `docs/modding/content-mods.md`
was updated and then followed verbatim. **1005 tests**, up from 981. Tier 1 modding, which has
worked since M3, stopped needing a hand-written list.

**All seven steps are done (2026-09-09).** The installed hand-written header and its
cross-language agreement freeze the boundary; `FoundryApi_v1` publishes 135 validated calls
over a host-supplied engine, world, renderer, UI, mixer and collision world; and native images
load from their package-local directories, initialise in resolved order and shut down once in
reverse order. Refused native code is neutralised without discarding its content, and images
that have run remain mapped for process lifetime. The full in-tree pipeline and every refusal
path are covered by `engine/tests/mod_pipeline.zig`; the final outside-tree proof exercises
the same lifecycle as an independent consumer. **1117 headless tests.** M8's current
implementation status is recorded below.

### M8 — Scriptable: "modders can extend it" — **complete (2026-09-12)**

**All eight implementation steps.**
[ADR-0028](adr/0028-scripting-lua.md) selects restricted Lua 5.5.1;
[ADR-0029](adr/0029-script-host-and-reload.md) fixes the public boundary and reload lifetime.
[`design/scripting.md`](design/scripting.md) specifies the architecture; §16 is the order:
runtime containment, script assets/manifests, ABI v2 source access, bounded bindings,
package lifecycle, hot reload, adversarial/determinism proof, and the outside-tree author guide.
Step 1, completed 2026-09-10, pins/builds Lua and proves its private protected boundary,
quotas and minimal allowlisted fixture on every supported build target. Step 2, completed the
same day, makes bounded/revisioned script source an ordinary confined package asset, derives
`.lua` records through fpack, and carries manifest-v2 metadata through resolution. Step 3,
completed 2026-09-10, publishes typed source copying through a separate additive
`FoundryApi_v2` while retaining v1 unchanged. Step 4, completed 2026-09-12, binds the
bounded content and gameplay surface a script may call, with per-invocation budgets and
script-owned entities. Step 5, completed the same day, wires the package lifecycle: one stable
manager slot and one registered system per package, activation, fault, teardown and structured
diagnostics — and the sandbox's own package now ships a script the world's fixed tick drives.
Step 6, completed the same day, replaces a package's code without replacing the world: a
candidate VM is built beside the running one, the old state crosses as a bounded value tree
or through the module's own `migrate`, and the commit allocates nothing and runs no script
code — so editing a `.lua` beside the executable changes what a package does on the next tick
while its world, its state and the entities it owns stay. Step 7, completed the same day,
proves isolation, bounded failure and reproducibility end to end, including exhaustive
snapshot/migration allocation refusal, child-process stress deadlines, two-package isolation,
fresh-run determinism, confined-source recovery and a live windowed bad-edit/recovery run.
Step 8, completed the same day, executes the author exit criterion: a script package built in a
directory outside this repository, compiled by the installed `fpack`, loaded by the shipped
sandbox beside the sandbox's own script package, then edited, migrated, broken and repaired
while it ran — and [`modding/script-mods.md`](modding/script-mods.md), written from that and
then rebuilt from its own listings in a fresh directory, which reproduced the run line for line.
**1199 headless tests.** M9's design is recorded below.

* Scripting language decision — **made in ADR-0028; runtime boundary implemented**.
* Scripting host over the same public ABI; no separate surface.
* Sandboxing, resource limits, script hot reload.
* Error reporting good enough for a non-programmer mod author.

**Exit criteria: met.** Gameplay written in script, hot-reloaded, and unable to crash the
host — a runaway loop, an exhausted heap, a bad handle or a script error is contained, named
and survived.

`scripting.md` §1 makes the runnable proof concrete: script-controlled encounter timing and
entity spawning through ordinary content templates. Its §§8 and 14 define operational fault
containment and the required failure tests; this is not a proof against unknown native defects.

### M9 — Shippable: "it distributes" — **complete (2026-09-13)**

[ADR-0030](adr/0030-distribution-artifacts.md) fixes release artifacts and the macOS tooling
boundary; [ADR-0031](adr/0031-application-configuration-and-user-data.md) separates bootstrap,
ordinary content defaults and user state. [`design/distribution.md`](design/distribution.md)
is the specification; §14 orders eight steps: bounded preferences, sample configuration,
user package roots, release staging, generated attribution, diagnostics, macOS application,
and the recipient guide/exit proof. Step 1, completed 2026-09-12, adds bounded versioned
preferences: a `settings.fset` envelope over `data`'s existing field-block layout, and a
confined replacement in `platform` that writes an exclusively created temporary sibling, syncs
it and renames it over the destination as a leaf — so nothing is ever truncated, a symlinked
destination is overwritten rather than followed, and a file from a newer build or a different
schema version is preserved instead of replaced. Step 2, completed the same day, applies §4's
startup order in both samples: a `config` record in each sample's own package supplies the
window size and master volume as ordinary content, a saved preference overrides it, only what
the player chose is written back, and a content reload moves a default without moving a choice.
Step 3, completed the same day, combines installed and user package discovery without losing
host-assigned roots: content, assets, scripts, native libraries and reload all use the resolved
package's own confined base, while neither ABI gains a path. An outside-tree user script package
runs from Application Support beside a read-only installation. Step 4, completed the same day,
adds `zig build dist` and `tools/distribution`: a release is staged from explicit inputs into a
build-owned directory, holding the program, the packages an application named, and exactly the
files those packages' records refer to. Nothing is excluded by name — a file is present because
a record asked for it — so authoring text, uncompiled grids, the public header and the content
compiler are all absent, and an asset for a loader the engine does not define must be declared
rather than guessed at. Every staged path, size and SHA-256 is inventoried in path order, and
two stages of one release compare byte-for-byte. The staged room runs from outside the
checkout. Step 5, completed the same day, generates the attribution: `THIRD_PARTY_NOTICES.txt`
is built from the entries in `THIRD_PARTY_LICENSES/` in filename order, each distributed entry
reproduced whole — SDL's license election included, since it is part of the attribution and not
commentary on it — with the application's own `LICENSE` and `NOTICE` staged separately beside
it. The aggregate is a documented superset rather than a claim of linkage. A malformed entry,
an unreadable directory or a staged package whose declared license needs a notice it did not
supply all refuse the release. Step 6, completed the same day, adds `app.diagnostics`: an
opt-in session opened before settings, discovery and the engine, draining a bounded capture of
its own — separate from the overlay's ring, so a closed console cannot empty a release log —
into one of five slots under the application's `logs/`, with a marker recording the stage
reached and whether the session closed. A slot is claimed by exclusive creation, which is both
the concurrency mechanism and the symlink refusal; a slot written in the last minute is never
retired. Nothing about the filesystem is fatal: no directory, no free slot, a read-only
`logs/` or a failing write each leave a working session and an unaffected terminal. There is
no crash recovery and no signal handler — an abandoned marker means a session never said it
finished, never that a crash was proven. Step 7, completed 2026-09-13, maps the same validated
release plan into a generated and `plutil`-checked macOS application, keeps its dSYM outside
the player zip and requires the executable/symbol UUIDs to agree, rejects Mach-O load paths
outside system libraries or explicitly declared bundle-relative dependencies, signs the local
profile ad hoc and archives it with `ditto`. The room bundle was moved outside the checkout,
made read-only, run with SDL3/Metal/audio, and opened through LaunchServices; the sandbox
bundle separately carries and runs its script. A second, explicit `dist-developer-id` target
contains the hardened-runtime/timestamp/notary/staple/Gatekeeper sequence and refuses missing
operator inputs, but no credential was supplied or authorized, so no public signing or
notarization is claimed. Step 8, completed 2026-09-13, consumed Foundry's exported release
helpers from an outside build and reproduced the credential-independent recipient path: an
HTTP-transferred zip matched its published SHA-256; the app ran with no Zig or Xcode on
`PATH`; preferences survived a fresh process; a relocated read-only app loaded a precompiled
user mod; and a failed startup plus the next healthy launch left the intended diagnostic
markers. Ad-hoc signature integrity passed and Gatekeeper rejection was expected. ADR-0032
defers actual Developer ID signing, Apple notarization and a quarantined stranger-download
launch on a genuinely clean Mac to the first public release, without weakening that release
gate. **1278 headless tests.** All eight steps are complete.

* Asset and content bundling; release build configuration.
* Game configuration and user settings.
* Generated `THIRD_PARTY_NOTICES.txt` from `THIRD_PARTY_LICENSES/` (ADR-0016).
* Distributable macOS build. Crash handling and diagnostics.

**Exit criteria met:** the reusable release/distribution path is implemented and proved through
an external consumer as far as possible without private Apple release credentials.

The reference artifact is the existing room sample, ReleaseSafe/SDL3/Metal on Apple Silicon
macOS, with the sandbox proving packaged scripting separately. Ordinary packages remain the
runtime format. A local ad-hoc zip proves staging and integrity, not notarization. A real public
macOS release still requires Developer ID signing, Apple notarization and verification of the
exact quarantined stranger download on a genuinely clean recipient Mac. ADR-0032 carries that
credential-dependent proof into deferred release work; no current artifact claims it.

---

## Phase 4 — Hardening and reach

**This phase gathers what the project already deferred; it does not invent work.** Every
milestone below is drawn from `CLAUDE.md` §9's postponed table, `distribution.md` §13,
ADR-0032, the carried items and the known-bugs section of `PROJECT_STATE.md`, or a capability
`CLAUDE.md` §5 records as unbuilt — with one addition, M10, which is new work the engine has
never had.

**The order is a proposal, not a commitment.** Milestones are units of work, and three of
these are started by a *trigger* rather than by the roadmap reaching them: M13 needs a reason
to want a second API, M16 needs a decision that a game is networked, and M17 needs operator
credentials and a machine. The rest can be reordered freely. What is not negotiable is that
each still owes a design document before implementation, an ADR for anything that constrains
the future, and a runnable result.

### M10 — Identity: "it knows its own name" — **complete (2026-09-13)**

Foundry had no face. There was no logo, no wordmark, no icon; a staged `.app` carried no
`CFBundleIconFile` and therefore wore the generic Finder document icon, and nothing anywhere
stated what a third party may do with the name. This milestone gave the engine a visual
identity and, more importantly, drew the line between the engine's identity and the game's.

**No design document was written and none was owed.** What M10 decided is a boundary, not a
subsystem: [ADR-0034](adr/0034-brand-and-trademark.md) is the whole of it, and
[`brand/README.md`](../brand/README.md) says the same thing where the files are.

* The marks live in `brand/`: the glyph and the wordmark as masters, with `foundry.icns` and
  the 1280×640 social card generated from them and reproducible — `sips`/`iconutil` for the
  icon, [`scripts/brand_card.py`](../scripts/brand_card.py) for the card, which composites
  through stdlib `zlib` because this machine has neither ImageMagick nor Pillow and `sips`
  cannot put a transparent mark on an opaque ground.
* The icon reaches the bundle through the ordinary paths: `release.Description.icon` is staged
  as `Contents/Resources/AppIcon.icns`, hashed into the inventory like every other file, and
  named by `CFBundleIconFile` in the generated plist. **The application supplies it**, exactly
  as it supplies its product name and bundle ID, and the helpers supply no default.
* A release whose plist names an icon that nothing stages is **refused**. That mistake survives
  every build step and appears as a generic icon on someone else's machine.
* The engine's own mark on the engine's own artifacts: the README, and both samples' bundles.
* A usage and trademark note, because Apache-2.0 §6 deliberately grants no trademark rights
  (ADR-0016), so mod and game authors had nothing to read. Reference is permitted; identity is
  not. `NOTICE` carries the same sentence for anyone redistributing.
* **The GitHub repository brought up to date with M9** — description, topics and the social
  preview the mark makes possible. Presentation only: no CI, no release automation, no
  contribution infrastructure; those stay deferred (ADR-0032).

**The boundary is the point.** A game that shipped wearing Foundry's icon would be a defect,
not a feature (I5, ADR-0017). Branding is a consumer-supplied input with an engine default
used by engine artifacts, never an engine assumption baked into a product.

**One thing was deliberately not done.** A window icon through `platform` was in the plan and
is not here: on macOS the Dock and the title bar read the bundle's icon, and `SDL_SetWindowIcon`
changes nothing a person can see. Writing it now would be code whose only proof is that it
compiles. It belongs to M13, where a second platform makes it visible.

**Exit criteria — met.** `Foundry Room.app` and `Foundry Sandbox.app` carry the mark in Finder
and the Dock; the README shows the wordmark; and [`brand/README.md`](../brand/README.md) tells a
stranger what they may call their own work, with [ADR-0034](adr/0034-brand-and-trademark.md)
behind it.

### M11 — Solid: "its known faults are fixed" — **not started**

The known-bugs section of `PROJECT_STATE.md` has entries that have been carried for several
milestones. Individually each is small. Together they are the reason a future session cannot
tell the list's deliberate limitations from its unfinished work, which is the real cost.

* The `render2d` texture staging buffer destroyed while frames are still in flight.
* `zig build check -Drhi=metal` failing to compile `app`'s *test* binary — the executables
  build, so the gap is in what the bar can prove, which is the worse half.
* The `render2d` blank-patch/font-atlas batching fix, and the overlay's fifteen batches where
  the hand-drawn HUD cost six.
* The smaller recorded ones: log-sink timestamps, a directory read as a file reporting
  `IoFailed` rather than `WrongFileKind`, `FrameError` unable to separate transient from fatal,
  usage-flag conformance declared but unenforced, and the deferred destroy `interface.zig`
  describes but no backend performs.

**Exit criteria:** no entry in that section is a correctness defect; everything left is a
deliberate limitation with its reason written next to it; and the bar compiles what it
previously could not.

### M12 — Parallel: "it uses more than one core" — **not started**

`CLAUDE.md` §9 dates the job system and threading model to post-M5. Four milestones have
passed. The decision is overdue and has never been made, which is the only reason it is still
cheap.

**I9 constrains this harder than anything else in the phase.** A job system that lets
iteration order float changes results, and determinism is not a property that can be restored
afterwards. Design document and ADR first; the model itself — what may run concurrently, where
a frame splits, what a system may assume — stays open until that document decides it.

**Exit criteria:** a measured improvement on a real workload in a sample, with every existing
determinism test unchanged and still passing.

### M13 — Portable: "the RHI was real" — **not started; trigger-started**

**The backend is Vulkan** ([ADR-0033](adr/0033-vulkan-second-backend.md)), which covers Windows
and Linux with one backend. D3D12 is not planned, and Metal stays macOS's — nothing is routed
through MoltenVK. *When* remains trigger-started: a decision to ship either platform, or a
decision to validate the RHI against a second API, not the roadmap reaching this line.

Expect this milestone to surface RHI design errors. That is its second purpose, and budgeting
for it is more honest than being surprised by it — and Vulkan is where they will surface,
because the RHI's strict rules were copied from Vulkan's guaranteed minimums in the first
place. It also brings: real hardware or VM testing for both platforms, the Vulkan SDK and
RenderDoc, Vulkan's own shader-visible binding convention written into `rhi.md` §9 the way
Metal's was, and the shader cross-compiler decision (ADR-0015), which comes due here because
Vulkan consumes SPIR-V only. With it come the platform surfaces that are declared and
unimplemented — `win32_hwnd` and the X11/Wayland kinds — and frame pacing, which today exists
only on Metal.

**It is the largest milestone in this phase.** ADR-0003 recorded that a Vulkan-first plan would
have made M1 a months-long wall; that wall was moved here, not removed.

**Exit criteria:** a sample runs on Vulkan on a second platform, and the RHI's written rules
either survived the encounter or changed by ADR.

### M14 — Managed: "players choose their mods" — **not started**

`CLAUDE.md` §5 records it plainly: a mod manager UI is still unbuilt. Every mechanism under it
exists — discovery, dependency resolution, deterministic order, user package roots — and
nothing exposes them to the person actually playing.

* Enabling, disabling, ordering and conflict reporting, through the same public API a mod
  could use (I4) and with the order still deterministic (I2, I9).
* The content-driven game widget set ADR-0024 deferred, which is what such a screen is made of.
* The deferred preference work that belongs with it: profiles and concurrent merging, and
  settings migrations once a second schema version exists.

**The engine owes the capability, not the screen.** A game's mod UI is the game's, and its skin
is not Foundry's business.

**Exit criteria:** a packaged sample where a player — not an environment variable — turns a mod
on, and preferences survive a schema change without losing what the player chose.

### M15 — Editor: "content is authored in Foundry" — **not started**

`CLAUDE.md` §9's oldest deferred item, dated M6+. Its shape is already decided: tools are
Foundry applications (ADR-0011), and the editor is a **re-host of the debug overlay's
introspection, not a rewrite of it** (ADR-0025). The overlay was built as package zero for that
API precisely so this milestone would not need a private path.

**Exit criteria:** a content package authored, saved and reloaded without hand-editing `.fdt`,
using only calls the public ABI already exposes — an editor with a back door has failed I4
regardless of what it can do.

### M16 — Connected: "it plays with others" — **not started; trigger-started**

Networking is recorded as indefinite, and I1, I2, I8 and I9 have kept it possible without
paying for it. It becomes a milestone when a game needs it.

It brings ADR-0013's deferred question with it, but only conditionally: bit-exact determinism
for a subset is owed to *lockstep*, and an authoritative-server model does not need it. Which
model is chosen is an ADR before any code, because it decides how much of I9 has to become
literal.

**Exit criteria:** two processes share a world convincingly, and the model was decided in
writing first.

### M17 — Released: "a stranger can download it" — **not started; credential-gated**

M9 built and proved the release path; ADR-0032 deferred exactly the part that needs an
identity, Apple's service and a machine that has never run the code. This milestone executes
it, once.

**It is last deliberately: strangers come last.** Certification is what you perform on
something you are ready to hand over, and every milestone above it is what makes that true —
the faults fixed, the identity real, the mods manageable. Nothing prevents it being pulled
forward the day credentials exist; but a signed, notarized download of an engine that still
carries known defects buys trust it has not earned.

**Its entry gate is a full review and polish pass over `main`, and that pass is the last
theoretical checkpoint this project gets.** Not a diff of one branch — the whole engine as it
then stands, read for what a milestone-by-milestone eye stops seeing, ending with the bar and
a staged artifact run. Everything it finds is fixed before M17 begins rather than recorded as
debt; a review that produces a list instead of a repair has only moved the problem, and M11
exists so that list is already empty.

**After it, every remaining checkpoint is real.** Gatekeeper, the recipient's Mac, and then
people. A notarized archive cannot be quietly amended — it is the exact bytes, checksum
published, in someone else's hands — so this is the boundary between problems found by
reading and problems found by strangers.

* Developer ID signing, notarization, stapling and Gatekeeper assessment of the exact public
  archive, through the `dist-developer-id` path that already performs the sequence.
* The quarantine-preserving launch on a genuinely clean recipient Mac, and the remaining steps
  of `docs/shipping/macos.md` §4, recorded with identity, ticket, checksum and OS version.
* The deferred release questions that come due with it: how far back macOS support reaches
  — the release description asserts `LSMinimumSystemVersion` 26.0 and nothing tests an older
  system, so the supported floor is the newest one, not a range — and crash collection beyond
  what the OS already reports.

**Not this milestone:** release automation, CI or a storefront. ADR-0032 keeps all three
deferred, and storefront-specific signing stays open until a storefront is actually chosen.

**Exit criteria:** a download nobody has to be told how to open, and a record of why it can be
trusted. Until then no artifact is a verified release, and the ad-hoc zip never becomes one.

---

## Phase 5 — 3D

Deliberately unplanned in detail. Reuses `core`, `platform`, `rhi`, `data`, `asset` and `scene`
unchanged; that reuse is the entire point of the earlier architecture.

Expected shape, in rough order:

* `rhi` 3D capability: depth buffers, MSAA, cubemaps, mipmapping, compute.
* Transform hierarchy and scene graph on top of the existing entity model.
* Mesh and material systems; the material system must not assume all shaders are known at build
  time (ADR-0003, ADR-0015).
* 3D camera, frustum culling, sorting.
* Model import (glTF) through the asset pipeline.
* Lighting and shadows.
* 3D physics — likely the largest single item in this phase, and constrained by I9.
* Skeletal animation.

**This phase is not designed yet, and must not be designed until Phase 2 is complete.**
Recording it here is a commitment to compatibility, not a plan.
