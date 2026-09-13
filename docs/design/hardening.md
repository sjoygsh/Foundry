# Hardening: close the known faults without changing Foundry's shape

**Status:** designed 2026-09-13; **2/9 implementation steps complete**.
**Baseline:** `180ef4f`, M0–M10 complete; M10's verification remains accepted.
**Stop point:** immediately before Step 3. Resolutions at the end record what each step settled.

Specification for M11, **Solid: "its known faults are fixed"**, in
[`ROADMAP.md`](../ROADMAP.md). Rests on [ADR-0035](../adr/0035-rhi-lifetime-and-validation.md),
ADR-0003/0007/0012/0013/0019/0024/0025/0026/0031/0033 and the existing
[RHI](rhi.md), [renderer](render2d.md), [platform](platform-interface.md),
[UI](ui.md), [overlay](debug-overlay.md) and [distribution](distribution.md) designs.
Where this plan corrects a prior contract, the correction is explicit below and in ADR-0035.

## 1. Scope and exit

Repair the correctness defects named by the roadmap and PROJECT_STATE's known-bugs section,
complete the measured UI batching improvement, and state the remaining limitations honestly.
Completion requires the Metal configuration to compile its tests, safe resource replacement
with work in flight, enforceable usage declarations, actionable frame/file errors and useful
log timing. Both samples remain runnable and their rendering order and simulation results
remain unchanged.

M11 does not implement M12 threading, M13 Vulkan/platform expansion, M14 mod management or
profiles, M15 editor, M16 networking, M17 review/public-release certification, or Phase 5 3D.
It does not add a general render graph, material system, variable-width font system, telemetry,
dependency, build tool or inventory document. The existing PROJECT_STATE debt section remains
the record. No correctness defect may be relabeled a limitation just to meet the exit.

## 2. Evidence at the planning baseline

These are source observations and already-recorded evidence, not new test results:

| Debt | Concrete implementation or existing proof |
| --- | --- |
| Metal test compilation | `app/engine.zig`: `TestEngine` uses `NullDevice`, but `NothingRecorder` names selected `rhi.CommandBuffer`/`RenderPass`. |
| Upload lifetime | `render2d/renderer.zig`: `uploadRegion`, `clearTexture` and index initialization destroy staging after `submit`; Metal submission returns before completion. |
| Retirement disagreement | `rhi/interface.zig` promises deferral; null `destroyBuffer`/`destroyTexture` report rule 9 then release; Metal destroys immediately. Null completion is based on frame index, and Metal `waitIdle` waits frame-slot markers only. |
| Renderer retirement | `render2d/texture.zig` invalidates its own handle and allocates a retired entry; allocation failure intentionally leaks. It assumes frame progress for collection. |
| Surface ambiguity | Metal `beginFrame` reports missing drawable as `SurfaceLost`; sample render loops treat it as skippable. |
| Usage hole | `rhi/resource.zig` declares usage sets; the null backend's exhaustive ten-rule contract does not enforce them. |
| UI batches | `engine/tests/overlay_batches.zig` already proves texture and clip attribution; M6 recorded 32 batches, with a computed single-texture floor of 12 for its fixture. |
| Timing | `app/log_sink.zig` stores frame and sequence; session text prefixes `f<frame>`. `Engine.beginFrame` already reads the platform clock for frame delta. |
| File kind | `platform/os.zig` confined reads already stat the opened handle; ordinary `readFile` uses allocating read helpers and its directory test accepts any error. |

The fifteen-versus-six UI count in the old debt entry is historical. Use the existing
attribution fixture and record current before/after counts at Step 6; do not claim the old
measurement has not happened, or impose its exact total on a changed fixture.

## 3. Boundaries and compatibility

Keep the module graph. `rhi` owns completion and GPU objects; `render2d` owns renderer
handles, ordered sprites and texture loading; `ui` still describes a draw list; `app` walks
it, owns diagnostics and supplies observed timing. `platform` owns file handles and clocks.
No clock enters `scene`, `physics2d`, a Lua VM or simulation state (I9).

The frozen `FoundryApi_v1` and additive v2 retain their layouts, values and signatures.
RHI errors and retirement bookkeeping remain internal. Any C consumer of a changed internal
record must translate to the existing external record rather than copy its new layout.
The UI optimization must be expressible with existing public sprite/region operations;
`debug` gains no privileged call. No engine code hardcodes a sample's font ID or atlas cells.

Record implementation corrections in dated Resolutions here and update the affected
subsystem document at that step. A plan is not evidence: status remains incomplete until
the runnable result and focused tests exist.

## 4. Restore the Metal test boundary

Give null-engine test recorders the command/pass types of their explicit device, using
`NullDevice`'s backend declarations or a recorder generic over that backend. Inspect other
test-only recorders reached by the same Metal compilation for the same mismatch. Production
`EngineOf` and its recorder seam stay generic; do not force production modules onto null,
disable lazy-analysis coverage, skip the failing test, or weaken `rhi.interface.check`.

The additional compilation obligation is `zig build check -Drhi=metal` on macOS. Compiling
the selected configuration's entire graph is the proof; compiling only the production app
repeats the gap. The eight existing Metal tests are separate GPU runtime evidence, to be run
at the rendering integration gate rather than mistaken for cross-platform evidence.

## 5. Resource completion and texture replacement

### 5.1 One completion timeline, all submissions

Keep one graphics queue. Track monotonically ordered submission/completion identities inside
each backend, independently of successful presentation-frame count. Frame-slot reuse waits
its submitted completion marker; ordinary upload submissions participate in the same order.
`waitIdle` waits a queue-tail marker covering everything submitted before the call, including
uploads after the most recent `endFrame`. A failed submission or failed marker allocation must
never advance the completed watermark. It is acceptable to retain safely until teardown after
device failure; it is not acceptable to claim failed work completed successfully.

The null backend models that order deterministically without a clock. It must not mark an
out-of-frame copy complete merely because frame index is zero or because `endFrame` ran.
Test a copy before frame 1, between two frames, after the last frame, and multiple submissions
within one frame. Metal synchronization policy stays in Zig; extend the Objective-C shim only
with narrow one-to-one bridge operations if the existing operations are insufficient.

### 5.2 Logical death and physical release

Every destroy operation invalidates its handle immediately. Keep its backing object in
device-owned retirement storage until recorded uses have been submitted and completed, or
have been explicitly discarded. Calling destroy twice is harmless; recording a new use through
the old handle is invalid. Retiring a resource used by already-recorded work is legal.

Cover buffers, textures, samplers, shaders, bind groups and both layout/pipeline types, not
only the staging buffer that exposed the issue. Already-recorded commands must retain any
metadata/object state needed for their execution. A live bind group is not permission to
record new uses of a texture destroyed since that group was created; validate dependent
handles too. A successful pipeline owns/copies what it needs from its creation descriptors.

Reserve retirement capacity when creating resources, or retain dead entries in owned slots
until collection. Either representation must ensure destroy performs no fallible allocation
and leaks nothing on allocator failure. Reserve before publishing a handle; roll back a failed
creation fully. Retired slots may not be reused in a way that lets an old handle name a new
object. Collection and deinit release each backing allocation exactly once.

Pending recordings need explicit ownership: track their referenced resources and their
submission/completion status, or conservatively retain all potentially referenced retired
objects until those recordings resolve. Do not use a guessed `N + frames_in_flight` as proof
for work not represented in that ring. Unsubmitted command buffers must be discarded during
teardown; `waitIdle` cannot complete commands that were never submitted. If implementation
needs an internal discard operation, specify it and extend both backends/conformance together
before callers use it. It does not become a public mod API.

Rule 9 will check early physical reclamation and new stale-handle use. Existing tests that
expect an in-flight destroy request itself to fail become tests of immediate invalidation,
retained storage and eventual reclamation. Include a narrow deliberate early-release mutation
to prove the new tests still catch the original safety violation.

### 5.3 Integrate the renderer and hot reload

Route upload, atlas-clear and index staging cleanup through the implemented backend contract.
Remove the false claim that "outside a frame" implies GPU idle. Keep copies asynchronous in
normal operation; do not insert a device-wide wait into every texture load to mask the issue.
The existing renderer retirement layer may remain conservative, but eliminate its fallible
free/leak path by delegating backing retirement to the RHI or reserving its own bookkeeping at
creation. Choose the smallest change retaining renderer handle semantics; do not add a second
completion timeline above `rhi`.

Failed decode/allocation/upload must leave the old asset usable. The asset registry already
swaps only after successful candidate loading; preserve that transaction. Atlas insertion
failure must not publish a region whose upload failed. Preserve existing texels when adding
to an atlas: the upload currently declares the whole texture `undefined` even for a partial
copy; track its actual previous state instead of treating undefined contents as preserved.

Tests must use the ordinary asset registry and registered texture loader with frames in
flight, repeat replacement, and exercise failure plus recovery and teardown. Include
`createAtlas`/`atlasAdd` and failed staging allocation, not just `createTexture` at startup.

## 6. Usage validation

Add rule 11 before enforcing it in code. Usage describes allowed operations; state describes
the current transition. A correct state does not compensate for a missing usage flag.

| Existing operation | Required usage |
| --- | --- |
| Vertex/index binding | Buffer `vertex` / `index`, respectively. |
| Uniform/storage buffer binding | Buffer `uniform` / `storage`, matching the binding kind. |
| Sampled texture binding | Texture `sampled`. |
| Buffer copy | Source `copy_src`, destination `copy_dst`. |
| Buffer-to-texture copy | Source buffer `copy_src`, destination texture `copy_dst`. |
| Color attachment | Texture `render_target`. |
| Depth/stencil attachment | Texture `depth_stencil`. |

Validate the declared target state against the corresponding usage where the state describes
an operation. `present` is reserved for the device's surface; `undefined` grants no usage.
Do not infer unsupported storage-texture or compute operations from an unused flag. Preserve
existing descriptor error conventions and report command-time failures through violations,
including the void setter paths whose failure is surfaced when the command is submitted.

For each row, test the missing bit and the corresponding legal case with otherwise identical
resources. Fix consumers with an omitted flag, not the test by enabling every flag. Include
the renderer's unified-memory and staging-copy paths, surface descriptors and the ABI renderer
integration. Null tests must be able to force the discrete-memory branch deterministically.

## 7. Frame outcomes and failure cleanup

`SurfaceUnavailable` means the drawable is temporarily absent; a normal render skip is safe.
`SurfaceLost` means the surface cannot be used without recovery the current host does not
implement. `DeviceLost` means the device is unusable. OOM stays a separate failure. Only the
first permits the sample loop to continue without reporting a fatal rendering failure.

On failed acquisition, no frame opens and no successful frame index advances. Completion of
older work may still advance if a slot was actually waited. Do not overwrite a live completion
marker or leave a retained drawable. On errors after acquisition, close/abandon the recording
scope and release per-frame ownership safely; ensure any submitted work still has retirement
evidence even if the trailing present/marker step fails. `app` must preserve a primary error
while doing cleanup and propagate it into existing session diagnostics.

Use a deterministic fake device/recorder to inject each outcome at acquisition, preparation,
submission and finalization, including transient failure followed by success. A single real
Metal minimize/restore/resize run supplies distinct platform evidence. Full device recovery,
Vulkan swapchain recreation and automatic backend replacement remain M13 decisions.

## 8. Share the UI's texture without changing paint order

Keep `(view, layer, submission_index)` sorting and the current clip semantics. Pack the
reference font's white rectangle patch into its existing image, using unused cell space
without changing the 95 ASCII glyphs, grid dimensions or glyph UVs. Generate it through
`scripts/gen-debug-font.py` and load it through the ordinary core package/texture loader.
This is content atlas authoring, already allowed by `render2d.md` §§8/10, not a font loader.

Extend `app.ui_draw.Options` with an optional solid `Region`; default null uses the existing
renderer-owned `blankRegion`. Validate supplied handle/region bounds and fall back to that
blank on invalid input with a bounded diagnostic. The application provides the region, so
neither `ui` nor the walker assumes a particular font or cell number. Native callers can
express the same draws through existing sprite/region operations without an ABI extension.

The samples declare optional solid-patch coordinates with their application-owned content
configuration, explicitly versioning any extended schema. Coordinates are texels relative to
the selected font texture. This extends presentation content only; the persisted user-settings
schema and `settings.fset` remain unchanged, with migrations still M14's responsibility.
Omission means fallback; validate finite/integer bounds, nonzero
extent and that the patch lies within the current texture. The sample's authored default
points inside the padded unused cell; mod authors replacing that sheet must preserve its
declared layout or override/omit that metadata as they already do for glyph layout.

Resolve the patch from the currently loaded font handle whenever content/asset reload changes
it. Hold no old handle or pointer across replacement. A font mod stays an ordinary package
override; the built-in white texture remains available for fonts without a patch. No change
to text metrics, glyph count, fallback codepoint or filtering is permitted as a batch fix.

Extend `overlay_batches.zig` to run the same draw list with separate and shared textures.
The shared case must match its computed clip-only floor and preserve glyph/sprite counts,
vertex order, tint and clipping; retain the separate-texture case as a legal baseline.
Run the text-metric corpus unchanged and visually inspect both sample UIs and a font override.
Record measured batch counts and CPU cost separately; reduced batches need not imply a
measurable frame-time improvement on the current GPU.

## 9. Log timestamps without changing simulation

Add a host-supplied, optional monotonic elapsed-time stamp to the internal log capture. Use
nanoseconds in storage and an explicit unit in persisted text. It is a sampled host timestamp,
not a per-line clock read: lines emitted between observations can share a timestamp. Before a
host publishes one it is absent, never an invented wall-clock date or a stale prior session.

Reuse clock values the engine already reads for frame delta/profiling. Before the first
current-frame clock observation, the most recent observation is permitted and must be
documented. Startup/shutdown diagnostics may publish explicit host observations. `logFn`
must not obtain an OS clock, allocate, perform file I/O under the capture lock or add a
callback with an unbounded host lifetime. Reset the stamp with session ownership and copy
frame/time coherently under existing synchronization. The audio callback still never logs.

Keep text messages and filter behavior intact. Session text gains a versioned timestamped
line format/header; keep the existing v1 C log record translation byte-for-byte and omit
the internal timestamp there. If the overlay displays it, use that same sampled value.
Tests supply known timestamps, exercise unset/reset/truncation/cap/independent filters, and
prove identical tick counts and deterministic state with capture enabled versus disabled.
M12 owns any future worker-clock or concurrent multi-engine policy.

## 10. Ordinary file reads report the object opened

Refactor ordinary `Os.readFile` to open once, inspect that handle's file kind, and read it
through the existing bounded allocator path. A directory must return `WrongFileKind` for
relative and absolute paths. Do not `stat(path)` and reopen, which inspects a potentially
different object. Missing paths, denied access, oversized/growing files and OOM preserve
their distinct existing errors and cleanup. Regular-file reads remain capped during the read,
not only by a prior size value.

Ordinary reads retain their documented symlink behavior; confined reads retain stricter
component-by-component symlink refusal. Do not turn this diagnostic fix into a new filesystem
authority or silently broaden accepted file kinds. Assert exact directory errors in tests;
macOS supplies runtime evidence and Linux/Windows remain compile evidence unless separately
available. No new platform dependency or write path is introduced.

## 11. Disposition of the existing debt section

At Step 9, update that section once using the evidence accumulated above. Keep closed entries
as dated history or remove stale descriptions in favor of their completion record. The table
below scopes that pass; it does not create a second backlog.

| Existing entry or group | M11 disposition required |
| --- | --- |
| Staging lifetime, deferred destroy, Metal app tests | Repaired and backed by Steps 1–3 evidence. |
| Blank/font batches | Step 6 improvement measured; remaining clip breaks are deliberate. |
| Log timestamps, file kind, frame outcomes, usage flags | Implemented and tested in Steps 4–8. |
| Frame pacing and unimplemented native surface kinds | Explicit limitation until M13 supplies another platform; no Windows/Linux runtime claim. |
| Single real RHI backend and shader variants | M13/ADR-0033; do not reopen which API. |
| Explicit subsystem fields, sparse handle iteration and sparse-set entity storage | Existing simple implementations; change only on measured need, with stable identity/iteration retained. |
| Gamepads, OS file watching and IME preedit/control | Existing unsupported capabilities; distinguish OS watching from the implemented polling hot reload. No capability claim should imply they work. |
| Mixer listening and device removal | Inspect prior listening evidence once. If still absent, perform the bounded listening check; audio initialization alone is insufficient. Device-reopen policy remains an explicit unsupported feature unless the check finds an actual safety defect. |
| Xcode GPU capture | Inspect prior evidence once; take/open one capture if still unproved and tooling permits. If unavailable, say capture usability remains unverified; do not report a prerequisite as a completed capture. |
| SDL3 build-script compatibility and Zig upgrades | Maintenance obligation at a deliberate toolchain upgrade, not a current defect. Keep Zig 0.16.0. |
| Authoring-format scalability | Existing revisit condition when measured content scale justifies change. |
| Already-closed resize and shader-ownership questions | Preserve their closure; do not rerun their original milestones. |

The exit is **no remaining known correctness defect in that section**, not zero limitations.
If a relevant targeted check discovers another concrete correctness problem, repair it in its
own bounded unit and record the scope change; do not hide it as deferred polish. Unrelated
new features remain outside M11. M17's full review of `main` is not pulled into this milestone.

## 12. Implementation order

**Nine steps. Stop after each completed step.** Each implementation step gets focused tests,
one applicable integration bar, one documentation update/Resolution, and a commit. No step
below is started by this planning commit.

1. **Compile the Metal-selected test graph.** Implement §4's backend-correct test recorders.
   Verify the failing compilation and affected app tests, then the normal bar plus Metal
   check. Runnable result: both sample graphs and the previously broken test graph compile.
2. **Honor deferred destruction in both RHI backends.** Implement §§5.1–5.2: completion of
   all submissions, allocation-safe retirement and rule-9 semantics. Test all resource kinds,
   pending recordings, idle/teardown and early-release mutation. Runnable result: a null
   submission/retirement fixture and Metal offscreen resource use complete without early free.
3. **Replace textures safely through the ordinary loader.** Implement §5.3 and renderer
   cleanup integration. Test hot reload, atlas content preservation and failure recovery with
   work in flight. Runnable result: repeated sample texture replacement and normal teardown
   with no lifetime violation. Do not start the UI batching change yet.
4. **Enforce declared resource usage.** Implement §6's rule 11 and correct real descriptors.
   Test each matrix row positively/negatively and both renderer memory paths. Runnable result:
   both samples submit a usage-valid command stream and deliberately invalid copies fail.
5. **Handle transient and fatal frames distinctly.** Implement §7 across both backends,
   engine cleanup and sample loops. Inject each outcome; verify recovery from a transient
   acquisition and propagation of fatal failure. Runnable result: minimize/restore/resize on
   Metal, plus readable fatal session evidence from a deterministic injected failure.
6. **Share the UI font texture for solid rectangles.** Implement §8's authored patch,
   optional walker region and sample content metadata/reload integration. Compare actual
   batches for the same list, run text/ABI renderer tests and inspect both UIs. Runnable
   result: fewer batches with the same rendering and working font overrides.
7. **Stamp captured logs from observed host time.** Implement §9 and version the session
   text format. Verify unset/reset/bounds/filter behavior and unchanged deterministic state.
   Runnable result: a session log correlates elapsed time and frames through startup/exit.
8. **Return exact file-kind errors.** Implement §10 without changing confinement. Test
   relative/absolute directory reads, bounds, allocation cleanup and existing confined paths.
   Runnable result: a directory supplied as a file yields `WrongFileKind` consistently.
9. **Close the recorded debt with evidence.** Perform §11's single disposition pass and any
   still-owed bounded listening/capture evidence. Run the final M11 integration gate below,
   update PROJECT_STATE/roadmap/design indices with actual counts and limits, commit/tag
   `m11` only when the exit is met, then hand back. Do not begin M12.

## 13. Bounded verification and handoff

For implementation, the normal AGENTS.md §3 bar remains required. Its host/null tests,
Linux/Windows compile checks and two frame-budgeted null samples provide distinct evidence.
Add `zig build check -Drhi=metal` after Step 1; keep that repaired configuration in later
affected steps. Run the Metal-selected tests when lifetime/frame changes require device
evidence, and once at the final milestone integration gate. Reuse successful results until
changes could invalidate them; do not run a whole audit after a localized fix.

Final gate: the normal bar, Metal compilation/test configuration, repeated loader reload with
frames in flight, the real sample UI/frame exercise, and the relevant persisted diagnostics
checks. A local ad-hoc `dist` build verifies the changed core font/config in the shipped layout
once after Step 6 or at closure; it needs no Apple credential. Retain M10's icon behavior.
Use deterministic fixtures and bounded runs. Close GUI tests by their frame budget or window
close control; avoid synthetic Escape input that can reach the agent UI after focus changes.

Break each new safety guard once at its implementing step and observe its focused test fail;
restore it and rerun that affected check. Test allocation failure at retirement reservation
and candidate creation. Broad ABI/header recompilation is required only if an actual ABI
surface change occurs; this design requires none. Existing ABI rendering/log translations
still receive focused regression coverage where their implementation dependencies change.

**Planning verification is documentation-only.** Inspect the authoritative sources and the
named implementation seams, check local links/whitespace and scope consistency once. M10's
1,280 headless / 1,288 declared tests and passed integration bar remain its accepted baseline;
do not rerun them to prove prose. No compile failure is fixed, no new guard is implemented,
and no milestone implementation count advances during planning.

**Next action, only when implementation is requested: Step 3 above.**

## Resolution — Step 1, 2026-09-13

**The Metal-selected graph had two mismatches, not one.** §2 names `app/engine.zig`'s
`NothingRecorder`. Compiling the whole graph found the same class of error in
`engine/tests/abi_render_pipeline.zig`, whose fixture built its engine on
`rhi.null_backend.Device` and handed that device to `render2d.Renderer.init`, which takes the
selected `rhi.Device`. That test arrived in `eb92181` during M7, after M6 had recorded the first
failure, which is why only one was on record. Searching for `rhi.CommandBuffer`, `rhi.RenderPass`
and `rhi.Device` outside `rhi` found no third: every other consumer either uses the selected
device throughout or never hands a null engine's device to the renderer.

**The two repairs differ because the two consumers do.** `NothingRecorder` is a test double for
`renderFrame`'s `anytype` seam, on an engine that is deliberately null whatever the build
selected, so it now names `rhi.null_backend.CommandBuffer` and `RenderPass`. The render pipeline
test exercises the real renderer, which is not generic over its device and should not become so
for a test's sake (§4); its engine is now built on `rhi.Device`, as `asset_pipeline.zig` and
`overlay_batches.zig` already were. On a null build that is the identical type and nothing
changes; under `-Drhi=metal` the test runs headless on the real device. `renderFrame`'s
documentation now names the backend's types rather than the selected ones.

**Evidence.** `zig build check -Drhi=metal` failed with both errors before the change and exits 0
after it. `zig build test -Drhi=metal` exits 0 — the first run of the integration binary under
Metal since `eb92181`, including `abi_render_pipeline` on the device. The seven-command bar
passed. `zig build check -Drhi=metal` joins `AGENTS.md` §3's bar, since a Metal graph that only
the executables prove is how this stayed broken. No test was added or removed: 1,288 declared /
1,280 headless.

## Resolution — Step 2, 2026-09-13

**One completion model, in one file both backends run.** `engine/src/rhi/lifetime.zig` holds a
`Timeline`, which numbers recordings as they begin and submissions as they reach the queue, and
a `Retirement` list of backings whose handles are dead. Keeping it backend-neutral is what §5.1
is after: the validation backend and Metal cannot drift apart about when work has finished, and
Vulkan inherits the same answer. It is internal to `rhi`. No public or C surface changed, and
the interface still names 40 functions.

**Two numberings, because one queue has two orders.** Retirement is decided by recordings. A
resource destroyed while recording R was the newest begun may be used by R and by nothing begun
later — a command recorded through a dead handle is now itself a rule 9 violation — so its
backing is released once every recording up to R has finished or been discarded. Completion is
decided by submissions, which a queue executes in order, so a wait through submission S
finishes everything up to S. §5.2 allowed either tracking each recording's resources or
retaining conservatively; this is the conservative choice, and it allocates nothing per command.

**Only a wait finishes work.** Each slot keeps a marker: the newest submission when that slot's
frame ended, which on Metal is the frame-end command buffer it commits. `beginFrame` waits
through the slot's marker and `waitIdle` through the newest submission. Ending a frame finishes
nothing, and neither does a frame index of zero, so an upload before frame 1, between frames or
after the last one stays retained until a wait covers it. Metal now keeps each submitted
command buffer's reference until then, since those are what it waits on, and no longer relies
on Metal retaining what a command buffer references. If `endFrame` cannot allocate its marker,
the slot records the newest submission instead, so the next wait still covers that frame's
work; the rest of §7's failure cleanup remains Step 5.

**Nothing on the destroy path can fail.** Creating any resource reserves its retirement entry
before the handle is published, and beginning a recording reserves its submission. The null
backend's recycled command-buffer and render-pass lists now reserve their room when a new one is
allocated too: a failed append at submit had been swallowed, which the allocation sweep below
reported until it was fixed.

**Rule 9 in its corrected form.** Destroying what unfinished recordings use produces no
violation. Recording through a dead handle does — copies, barriers, attachments, pipelines,
vertex and index buffers, bind groups, and a live group whose texture, buffer or sampler has
since died, checked when bound and again at the draw that uses it. A pipeline copies what it
needs from its layout (group layouts and constant size on the null backend, binding slots on
Metal), so destroying the layout afterwards changes nothing the pipeline requires or binds.
Rule 3 moved to the same numbering: a buffer is unwritable while the last recording that used
it is unfinished. That closes a gap the frame-index model had, where a staging buffer mapped
again after an upload made before any frame was never reported.

**Found and repaired on the way.** Metal's `Device.init` released the device, the queue and the
device struct by hand on two failure paths, then returned an error with `errdefer`s for the
same objects still armed, releasing each twice. Both paths now rely on the `errdefer`s alone.
The headless resize builds its replacement target before retiring the old one, so a failure
leaves the surface as it was instead of pointing at a destroyed texture.

**Not done here.** `render2d` still keeps its own frame-index retirement layer and destroys
staging after an asynchronous submit; the RHI now makes that destroy safe, and routing the
renderer through the contract is Step 3. A recording left open by an error path — `renderFrame`
failing between beginning a command buffer and submitting it — now holds later retirements
until teardown. That costs memory rather than safety, and closing the recording scope on error
is Step 5.

**Evidence.** Nineteen headless tests were added, seven in `lifetime.zig` and twelve in the null
backend, and one Metal test. The two rule-9 tests that expected a violation on destroy now
assert immediate invalidation, retained storage and release at the slot's wait.
`std.testing.checkAllAllocationFailures` runs a device through every resource kind, a frame and
nine destroys, failing each allocation in turn: nothing leaks and no destroy allocates. Breaking
the guards — releasing retired backings regardless of completion, and treating a destroyed
buffer as alive — failed ten of 1,299 tests, nine to the first and one to the second; both files
were restored byte-for-byte. `zig build test -Drhi=metal` passed under `MTL_DEBUG_LAYER=1`, with
Metal API Validation enabled in each test process and no validation error, including the new
test's upload, frames and retirement on the device. The bar passed. 1,308 declared / 1,299
headless, nine of them Metal-only.
