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
    requirement rule 7 warns about. **Due with the material system**, which is Phase 4 or
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
not expose**, so that the editor at M6+ is a re-host rather than a rewrite and a mod gets tooling
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

### M9 — Shippable: "it distributes" — **designed (2026-09-12), 2/8 implemented**

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
**1233 headless tests.** No release artifact or recipient evidence exists.

* Asset and content bundling; release build configuration.
* Game configuration and user settings.
* Generated `THIRD_PARTY_NOTICES.txt` from `THIRD_PARTY_LICENSES/` (ADR-0016).
* Distributable macOS build. Crash handling and diagnostics.

**Exit criteria:** a zip a stranger can download and run.

The reference artifact is the existing room sample, ReleaseSafe/SDL3/Metal on Apple Silicon
macOS, with the sandbox proving packaged scripting separately. Ordinary packages remain the
runtime format. A local ad-hoc zip proves staging, not notarization; the final recipient gate
records actual download/quarantine launch, relocation, preferences and diagnostics without
the development toolchain. External signing/recipient prerequisites are recorded explicitly
if unavailable, rather than treating a local run as milestone completion.

---

## Unscheduled: backend #2

**Deliberately not placed on the timeline.** Started when there is a reason — a decision to
ship Windows or Linux, or a decision to validate the RHI against a second API — not when the
roadmap reaches it. Linux implies Vulkan; Windows could be either (ADR-0003).

Expect this milestone to surface RHI design errors. That is its second purpose, and budgeting
for it is more honest than being surprised by it. It also brings: real hardware or VM testing
for that platform, the Vulkan SDK and RenderDoc if applicable, and the shader cross-compiler
decision (ADR-0015).

---

## Phase 4 — 3D

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
