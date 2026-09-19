# Design: M13 — Vulkan, and the second test of the RHI

**Status:** Design accepted 2026-09-14 (ADR-0037/0038), its windowed floor revised before
acceptance; **implemented in full, M13 complete 2026-09-19** on Windows x64. **Linux left M13
on 2026-09-18** ([ADR-0039](../adr/0039-linux-after-the-first-game.md), the scope Resolution):
M13 proves Windows x64, and Linux's runtime proof is M18, after the first game and before 3D.
**Date:** 2026-09-14
**Baseline:** `f14caac` / `m12`; M0–M12 complete, 1,370 declared / 1,360 headless tests.
**Decisions:** ADR-0033 selects Vulkan; accepted [ADR-0037](../adr/0037-vulkan-execution-and-presentation.md)
and [ADR-0038](../adr/0038-vulkan-shaders-and-toolchain.md) specify execution and tooling;
[ADR-0039](../adr/0039-linux-after-the-first-game.md) moves Linux's runtime proof to M18.

## 1. Purpose and boundary

The owner requested M13's design after M12, activating the recorded trigger of validating
Foundry's abstraction against a second API. The result is the existing samples on Windows x64,
through the existing renderer and ordinary packages. Linux x64 was part of this result until
ADR-0039 moved its runtime proof to M18; its code paths stay, build-checked. Metal remains macOS's
backend. There is no MoltenVK path, D3D12 backend, new renderer, material system or public ABI
version in this milestone. M12's workers never call the RHI; all graphics calls remain on
the caller thread.

The design was written before any implementation. ADR-0037/0038, including the hardware
floor, were accepted on 2026-09-14. Tool versions and target machines were Step 1 inputs,
recorded in its Resolution rather than guessed. No Vulkan backend code exists before Step 3.

## 2. What exists, and what the environment must provide

### 2.1 Inspected baseline

`rhi/interface.zig` checks 40 operations across `Device`, `CommandBuffer` and `RenderPass`.
Null and Metal implement them. `rhi/lifetime.zig` distinguishes recording identity from queue
submission order and reserves retirement storage before publishing handles. Vulkan reuses it.

`platform/window.zig` declares Windows/X11/Wayland kinds, but SDL refuses them. Only Metal
provides a real surface. `app.Engine` copies the native surface into device creation and
forwards resize events. Its event handler currently logs a failed resize; M13 must ensure
that a fatal resize remains observable by the rendering path, not a skipped frame forever.

`render2d` embeds one Metal library, uses its two entry points, and builds immutable texture
groups and pipelines. Its vertex uploads already support staging on non-unified hardware.
The sandbox also retains its M1 quad shader. Pipeline descriptors already allow separate
stage modules and entry names; no shader-container format is missing. `build.zig` only selects
null/Metal today. Existing cross-checks use null RHI and do not prove SDL/Vulkan linking.

### 2.2 Qualification and honest claims

| Environment | Evidence it can supply | Evidence it cannot replace |
| --- | --- | --- |
| This Apple Silicon Mac, Metal | Existing bar, pure mapping/ownership tests, host SPIR-V tools and Windows/Linux cross-builds once configured | Native Windows/Linux presentation, driver behavior, input or window-system support |
| Windows x64 with a qualified Vulkan driver | Win32 surface, real sample, native tests, validation and capture | Linux X11/Wayland evidence |
| Linux x64 with a qualified Vulkan driver and desktop session | Native tests, real sample, X11 and Wayland surface paths (separate runs) | Windows evidence |
| VM or software Vulkan implementation | Only the API/features/WSI actually exposed and exercised | An untested hardware driver, discrete-memory behavior or GPU performance |

The Mac holds only the pinned SDK's host tools, off PATH; the Windows target is reached
remotely (Step 1). Installing an SDK does not create a native Vulkan driver on macOS.
An ARM guest or x64 emulation on this Mac does not by itself establish the x64 target claim.
An ordinary desktop VM may expose no Vulkan device at all. Qualify with `vulkaninfo`, feature
reports and a windowed SDK sample instead of inferring support from an OS name. A remote
desktop must use the same adapter/window session being reported.

Before backend implementation, Step 1 must demonstrate at least one usable x64 target and
record an available, specific route to the other OS. Closing M13 required both, including
Linux X11 and Wayland, until ADR-0039 moved Linux to M18; it now requires Windows. Software
rendering is useful supplementary evidence; at least one windowed exit run must use a hardware
Vulkan driver. Record any untested discrete-memory path explicitly; no performance or universal
hardware-support claim follows from one GPU.

The proposed windowed floor is Vulkan 1.3 plus dynamic rendering, synchronization2, timeline
semaphores, a shared graphics/present queue family and unextended swapchain support. Swapchain
maintenance1 is neither required nor enabled; §8 has one presentation path for every driver
(see the floor-revision Resolution). Missing support is refusal, not a fallback to Metal/null.
Offscreen tests omit WSI requirements. Exact OS, GPU, driver, extensions, SDK/tool versions
and window system go in each implementation Resolution.

## 3. Module and build boundaries

| Owner | M13 work |
| --- | --- |
| `platform` L1 | Native OS window payloads, automatic active-window-system selection, generic safe system-library loading, application-supplied window icon |
| `rhi` L2 | Vulkan headers/dispatch, device/WSI, resource memory, synchronization, descriptors, pipelines and commands; no SDL imports |
| `render2d` L3 | Neutral stage-byte imports, existing RHI calls and sprite vertex contract; no Vulkan types |
| `app` L4 | Existing frame/resize flow, fatal resize propagation, neutral surface selection plumbing |
| build graph | Backend choice, pinned headers, host shader compilation, explicit validation/test configurations and cross-checks |
| samples | Exercise the existing capabilities and the application icon on each target; ordinary content/mod loading |

Backend-private files belong under `engine/src/rhi/backends/vulkan/`, split by responsibility
when needed: dispatch/device, resources, binding/pipeline, commands and presentation. Pure
selection and mapping helpers are separately testable without a driver. This is not a new
module layer or an alternate handle implementation.

Add `-Drhi=vulkan` for Windows/Linux and reject it on macOS with an actionable diagnostic.
Leave default backend selection unchanged during bring-up; explicit selection prevents a
new dependency from becoming an ambient prerequisite. Test/build graphs must analyze the
selected Vulkan backend and its GPU tests, not only executables. Keep cross-compiled test
artifacts buildable without trying to execute them on the host.

ADR-0038 governs SDK/tool pinning, lazy header dependency and license entries. Native and
cross builds use the same host shader pipeline. The existing SDL package's Linux dependency
bundle must supply its window-system build inputs; do not introduce pkg-config or unpinned
system headers as an accidental fix. No CI, installer, storefront or release automation.

## 4. Native windows and the loader

Keep `NativeSurfaceHandle`'s outer `kind`/`ptr` layout. Add platform-declared payload structs
for Windows (`hwnd`, `hinstance` opaque pointers), X11 (opaque display, pointer-width unsigned
window ID), and Wayland (opaque display and surface pointers). The OS-specific types are
interpreted only in the consuming backend. Metal's pointer still means the layer itself.

Payloads must have stable addresses: allocate them with the window, not inside a moving
handle-pool slot. `rhi` copies payload values during initialization; the OS objects remain
borrowed until device destruction, which precedes closing the window. Test window-pool growth,
missing properties, stale handles and complete partial-initialization cleanup.

Add a `native_window` request kind for automatic selection; returned handles always have the
concrete Win32/X11/Wayland kind. Explicit concrete requests reject a different active driver.
Use SDL's native window properties, not `SDL_Vulkan_CreateSurface` or a Vulkan include in
`platform`. Start with a native window without an OpenGL/Metal context; verify the pinned
SDL driver's creation/configure behavior on both Linux window systems in M18 (ADR-0039). If
SDL requires a creation flag internally, keep that SDL detail in `platform`; it conveys no
Vulkan object across the seam. Do not force X11 merely because it was the first successful desktop run.

`rhi` creates/destroys `VkSurfaceKHR`, enables only the matching WSI extensions, and owns
dispatch tables and the loader reference. `platform.Library` gains a generic system-only
open on Windows using the OS system-directory search, with an injected lookalike-DLL refusal
test. Ordinary explicit-path mod loading is unchanged. Linux resolves the system loader's
soname through its normal loader policy; no package-relative Vulkan driver is loaded.
Failure after any creation stage unwinds in reverse order and closes the loader last.

## 5. Device, resources and completion

### 5.1 Selection

Enumerate devices, reject missing floor requirements, and choose the first qualifying device
in a documented stable ranking (discrete, integrated, virtual, CPU, other; vendor/device IDs
then enumeration index as tie-break). Log the chosen adapter and reasons for refusals. This
selection is not simulation state and does not change I9's same-binary guarantee. Query actual
limits and format features; do not infer them from GPU names. No device preference UI.

The one queue handles graphics and transfers and, when windowed, presentation. Request no
unused optional device feature. Use dynamic rendering, one sample per pixel and existing
pipeline states; compute, MSAA and 3D texture features remain Phase 5 work.

### 5.2 Memory and handle lifetime

Use existing generational pools with backend-owned backing objects. Each successful create
reserves its future retirement storage. Destroy invalidates at once and retires after the
newest potentially referencing recording, including recorded-but-unsubmitted commands.
Reuse `Timeline`/`Retirement`; completed queue work does not resolve an open recording.

Start with one memory allocation per resource, obeying `memoryTypeBits`, requirements size
and alignment and dedicated-allocation requirements. Check `maxMemoryAllocationCount` and
report exhaustion as `OutOfDeviceMemory`. Add no allocator library. If sample/reload evidence
shows that this cannot meet the workload, record that finding before adding suballocation.

`device_local` never maps, regardless of heap flags. Upload/readback choose host-visible
memory; prefer coherent uploads and cached readback without requiring those flags. For
non-coherent allocations, invalidate before exposing completed readback bytes and flush upload
writes on unmap, rounded to `nonCoherentAtomSize` within the allocation. GPU visibility and
host cache operations are separate requirements. `unified_memory` is conservative unless the
chosen memory types justify the renderer's direct-upload-buffer branch; test both branches.

Resource usage flags map exactly. Query format support and refuse unsupported combinations.
Image allocation starts undefined: a descriptor requesting another initial state requires an
ordered initialization transition, accounted on the same submission timeline. All-mip views,
aspect masks and copy bounds must match the descriptor; no invented mip generation.

Each successful queue submission signals a strictly increasing timeline value, after all its
commands, and records that value in the existing timeline. Poll/wait updates completion before
reclaiming command buffers, allocations, descriptor sets and other retired backing. A command
pool cannot reset while one of its recordings is open or its submissions are unfinished.
Uploads outside a frame therefore progress and retire without waiting for a future frame.

### 5.3 Gaps the strict model must make explicit

Add neutral capabilities for uniform/storage buffer offset alignment and maximum binding
range. Populate Metal/null as well as Vulkan; null's strict test profile uses 256-byte offset
alignment and conservative ranges. Rule 10 checks alignment, overflow and resolved range
(`size == 0` means the remaining bytes), while rule 11 checks declared usage. Existing callers
use offset zero; fixtures must still prove the limits. This is an internal contract extension,
written before implementation, not a C ABI change.

Vulkan buffer-image copies require representable texel row lengths and aligned offsets.
Preserve valid RHI byte strides: repack through backend-owned staging when a legal source
layout cannot be represented, then retire that staging with its copy. A non-host-readable
source may require a buffer-to-buffer repack. Never silently narrow a size or treat row bytes
as texels. Cover nonzero origins, padded/odd rows and mip copies. If the existing contract
cannot be preserved, resolve that exact case architecturally before changing its rules.

## 6. Shaders, bindings and pipelines

ADR-0038 selects paired GLSL 450 sources compiled and validated to Vulkan 1.3 SPIR-V, with
`main` selected in the already-existing per-stage entry fields. `render2d` gets separate
neutral vertex/fragment byte imports and entry metadata; Metal can map both to its one
library. The sandbox's M1 pair follows the same producer. Do not add SPIR-V bytes to `.fdt`
or claim that M13 implemented a material/shader asset loader.

The shader-visible convention is normative in `rhi.md` §9: group index equals descriptor
set, binding number is unchanged, separate image and sampler descriptors, explicit vertex
locations, column-major matrices, and a push-constant block at offset zero. Persistent group
sets are allocated from growable, device-owned descriptor pools. Allocation and bookkeeping
are complete before publishing a handle; individual sets are freed only after retirement.
Pool fragmentation grows another pool or returns a resource error; it never resets live sets.

An unused group position uses an empty native set layout so later set indices do not move.
Layouts copy their descriptions. Pipelines retain the native pipeline-layout backing they
need even if the originating handle dies; shader modules may retire after pipeline creation.
Destroying an underlying resource still makes a new use through a group invalid (rule 9).
Bindings visible in both stages retain one descriptor and the declared stage mask.

Inline-constant size remains at most 128 bytes with whole-block copy semantics. Round native
push ranges up to four bytes, copy into a bounded private padded block, and never read beyond
the caller's slice. Rebind after a pipeline-layout change as the existing contract requires.
GLSL uniform blocks use `std140`, storage/push blocks `std430`; CPU producers use explicit
offsets/padding. Verify SPIR-V decorations against the known sprite/quad layouts at build time.

Preserve sRGB decode/encode, nearest sampling, premultiplied tint and texture alpha, clipping,
the signed layer/submission order and 4x4 column-major transforms. Map a viewport to
`(x, y + height, width, -height)` to implement Foundry's clip convention. Test front-face
culling and scissor origin together with this correction, not only an unculled quad.

## 7. Commands and synchronization

Record into one Vulkan command buffer per RHI recording. Multiple RHI recordings can be open,
but API calls remain on the owning thread. `submit` consumes on success or failure; `discard`
resolves an unsubmitted recording without pretending it ran. Backend allocation failure before
submit frees temporary objects and leaves the queue timeline unchanged.

Use synchronization2 barriers at the boundaries the RHI already declares. Translate texture
states to layout, stage and access; buffer `shader_read` includes vertex/index input as well
as uniform/storage access according to usage. Do not confuse queue execution order with
memory visibility. At each submission boundary conservatively establish the memory dependency
between prior queue writes and subsequent reads/writes; refine only on measured evidence.

| RHI texture state | Vulkan layout | Access/stage intent |
| --- | --- | --- |
| `undefined` | `UNDEFINED` | No preserved content; no source access |
| `render_target` | `COLOR_ATTACHMENT_OPTIMAL` | Color attachment read/write, color output |
| `depth_stencil` | `DEPTH_STENCIL_ATTACHMENT_OPTIMAL` | Depth/stencil read/write, early and late tests |
| `shader_read` | `SHADER_READ_ONLY_OPTIMAL` | Sampled read, declared graphics shader stages |
| `copy_src` / `copy_dst` | `TRANSFER_SRC_OPTIMAL` / `TRANSFER_DST_OPTIMAL` | Transfer read / write |
| `present` | `PRESENT_SRC_KHR` | WSI semaphore dependency; no shader access |

Transition incoming attachments before `vkCmdBeginRendering`, map load/store actions, end
rendering and transition to declared final states afterward. Undefined permits discarding
contents, not racing an earlier use: attachment/acquisition ordering still applies. Preserve
contents on subsequent atlas updates. Buffer barriers include host-write/upload and
transfer-to-consumer dependencies; readback tests wait for completion before mapping.

Only the selected backend translates enums. Malformed descriptors and shader byte bounds
return errors; null remains the executable reference for invalid command streams. Vulkan
validation tests inject driver results or intercept dispatch when testing failure cleanup;
they do not intentionally issue undefined GPU commands as an ordinary negative test.

## 8. Presentation, resize and failed frames

Use FIFO presentation for the first backend, with a bounded acquire wait so an unavailable
window does not freeze input handling. Choose the requested image count from surface bounds;
image count is independent of `frames_in_flight`. Negotiate an available sRGB format, preferring
BGRA8 then RGBA8 with the matching color space, and keep it for the device lifetime. If none
is usable, report unsupported surface rather than rendering with different color semantics.

There are three identities: CPU frame slot, acquired swapchain image, and submission serial.
Frame slots own acquire synchronization, which must be consumed before reuse and recycles
after its consuming submission completes. Swapchain images own their present-wait semaphores,
indexed by acquired image index, never by frame slot: acquiring an index again is unextended
Vulkan's only evidence that the presentation which waited on that semaphore has consumed it.
Presentation resources therefore never recycle on the frame-slot timeline.

`beginFrame` waits for the previous use of its slot, performs pending between-frame rebuilds,
then takes a held undrawn image (below) or acquires. Only a frame with an image opens and
advances frame identity. The
first submission using the image consumes its acquire semaphore once; later submissions may
use the same image. `endFrame` submits an ordered final marker/signals present synchronization
after all submitted image work, records the slot's last submission and presents only if
submitted work drew into the image.

If no draw reached the queue, consume any remaining acquire signal with a cleanup submission
recorded as the slot's marker, and hold the image, unpresented, for the next opened frame; that
frame has no acquire signal left to consume. Unextended Vulkan cannot return an acquired image,
and presenting undrawn contents is forbidden, so at most one image is held and repeated empty
frames reuse it. A rebuild or teardown discards it with its swapchain after its submitted uses
complete, which `vkDestroySwapchainKHR` permits. Reserve cleanup bookkeeping before acquiring
so an OOM does not make closing the frame impossible. If submission itself fails, latch device
failure and tear down without waiting on synchronization that was never signaled. Never mark a
discarded draw as having rendered the image.

| Driver result | Foundry outcome / required state |
| --- | --- |
| Acquire timeout/not-ready or zero extent | `SurfaceUnavailable`; no opened frame/index advance |
| Acquire out-of-date | Queue explicit between-frame rebuild; `SurfaceUnavailable` for this attempt |
| Suboptimal with an acquired image | Finish that frame, queue rebuild; do not drop a signaled acquire semaphore |
| Present out-of-date/suboptimal | Close the frame, preserve submission marker, queue rebuild; return routine unavailability if reporting a skipped presentation |
| Surface lost | `SurfaceLost`, sticky and fatal; no automatic window/device reconstruction |
| Device lost | `DeviceLost`, sticky and fatal; no wait on promises the lost device cannot fulfill |
| Host/device allocation failure | Existing error set's representable allocation failure plus precise backend diagnostic; no success-shaped skip |

`resizeSurface` accepts zero extent as suspension and rebuilds at a nonzero extent between
frames. Wait for old image submissions on the timeline and then for queue idleness before
releasing views, present-wait semaphores, a held image and the swapchain. Unextended
presentation has no completion signal, so that idle wait is the practical boundary Khronos
documents, not proof that presentation finished; record the gap rather than claiming more.
On a failed rebuild, retain valid old backing where Vulkan permits it, otherwise remain
suspended or fatal with correct ownership; passing `oldSwapchain` can retire it even when the
new creation fails. Do not advertise transactional rollback that Vulkan does not guarantee.
The renderer cannot reuse old surface handles across rebuilds. Keep format unchanged or fail
with `SurfaceLost`; no silent pipeline mismatch. Fatal resize errors remain latched for the
next render call despite the existing event handler logging them.

Teardown on a healthy device waits for submission completion, then idleness, under the same
recorded gap. A lost device follows the
API's lost-device destruction rules and releases host ownership without unbounded waits;
`waitIdle`'s void signature logs/latches a failure rather than inventing an error return.
Real recoverable device loss and multi-window support remain deferred.

## 9. Sample integration and M10's window icon

Both samples request the selected backend's appropriate surface, with automatic native
selection on Linux. Existing package resolution, script/native mod lifecycle, preferences,
diagnostics, UI and input remain in use. Keep frame-budgeted/headless persistence rules.
The renderer continues to accept `engine.jobs()`; changing the backend does not reschedule
simulation or move command recording onto workers.

Finish the window-icon capability M10 assigned to M13: a platform operation takes a bounded
RGBA8 image supplied by the application, validates dimensions/stride/length and borrows bytes
only for the call. The SDL backend copies/sets it; null validates without a window manager.
Use sample-owned content to supply Foundry's sample mark. The engine supplies no default mark,
reads no icon file and imports no image decoder into `platform`. The operation is host window
configuration, so it adds nothing to the C mod API in M13. Verify it visibly on Windows. X11
and Wayland are M18's (ADR-0039). Wayland may let the compositor choose the app icon, and M18
must document that limitation honestly.

Run outside the source tree using compiled packages and explicit asset roots. This is a
development runtime proof, not an extension of macOS `dist` to new release formats. Test an
ordinary user content override and packaged sandbox scripting; no special Vulkan mod path.

## 10. Verification and completion

Follow AGENTS.md's bounded sequence. Preserve M12's accepted evidence. Each implementation
step runs focused checks and the required bar once, reusing successful results over unchanged
work. A test protecting a new invariant must be made to fail once through a local mutation,
then restored. Documentation gets one end-of-step consistency pass.

Distinct evidence required during M13:

* Pure tests: requirement/queue/format selection, binding/vertex mappings, range/alignment and
  row layout arithmetic, barriers, byte padding, ownership and frame-result transitions.
* Offscreen Vulkan tests: upload/copy/readback bytes, rendered pixel probes, color/depth and
  load/store behavior, descriptors across layouts, multiple recordings, outside-frame uploads,
  discard and in-flight retirement. Pixel readback may use a private backend test helper;
  do not expand the public RHI solely to expose test inspection.
* Null reference tests: every tightened portability rule, both renderer memory paths, all
  existing eleven rules and the unchanged M12 determinism/job tests. No test-count regression
  disguised as GPU tests being silently skipped.
* The native Windows Vulkan-selected full test graph with validation and synchronization
  validation explicitly required; known environment failure is reported, never a passing skip.
  Driver diagnostics pass through `core.log`; callbacks retain no temporary message pointer.
* Bounded windowed sandbox and room runs on Windows, with resize, minimize/restore, input/UI,
  pacing, texture reload while frames are in flight and clean exit. Use at least 600 frames
  for stable rendering and 20 texture replacements with two frames in flight. Window controls
  are manual where automation is unavailable; process completion is not proof the window was
  visually correct.
* One RenderDoc capture opened and inspected on Windows: inspect a real sprite draw, stage
  bindings, constants, vertex data and resulting target. Record capture-tool compatibility
  limitations. No cross-backend bit-exact pixel guarantee: compare exact simple probes where
  defined, tolerances for filtering/raster edges.
* Relocated runtime tree on Windows with Zig/SDK/compiler absent from PATH, ordinary user
  package override and script lifecycle, no backend-aware game code, no validation errors.

Linux owed the same list, with X11 and Wayland as separate runs, until ADR-0039 moved it to
M18. The list is the starting point for that milestone's design.

At final closure run the existing Mac bar, Vulkan cross-checks for both targets, and the
remaining distinct native evidence above. Report actual skips, failures and environment
limits. A windowed hardware sample on a second API is essential. ADR-0033 also promised Linux
runtime proof, and ADR-0039 moved that promise to M18. Missing Windows evidence leaves M13
incomplete.
M13 ends only when its rules survived or their necessary changes were recorded by ADR.

## 11. Implementation order — ten bounded steps

All ten steps are complete. Each stopped with its Resolution, PROJECT_STATE update,
verification and commit; there was no automatic chaining. Before Step 3
the owner directed a repair of the native Windows test suite; its Resolution follows Step 2's.

### Step 1 — Qualify the targets and pin the Vulkan tools

Confirm an actual x64 runtime target and the route to the other OS (§2); exercise the SDK's
windowed sample and collect required features/extensions. Select exact SDK, header and tool
versions/hashes, license entries and setup instructions. Prove host GLSL compilation and
`spirv-val` on a scratch stage plus the header imports for both targets. Do not select a
half-implemented Foundry backend yet. **Exit:** reproducible tools and at least one real
usable target; missing environment/floor support is an explicit stop before Step 2.

### Step 2 — Carry native window data and load the system library

Implement §4's payloads and automatic request in null/SDL, complete conformance, and add the
generic safe system-library open. Exercise native window creation/properties/resize/close
on the available target and cross-build the other. No Vulkan instance yet. **Exit:** no SDL
or graphics type crosses the seam, stable payload lifetime, missing/wrong-kind/library refusal.

### Step 3 — Create a Vulkan device and track submissions

Implement dispatch, instance/device selection, offscreen device ownership and the queue
timeline behind backend-private tests. Establish the WSI-compatible queue when a surface is
provided. Fault-test each initialization stage and missing requirements. Do not expose
`-Drhi=vulkan` as a working sample configuration until Step 7 completes conformance.
**Exit:** a native device submits/waits for empty work, tears down under validation, and
shared lifetime tests cover its submission bookkeeping without presentation.

### Step 4 — Allocate, copy and retire resources

Implement buffers, images, views, samplers, memory intent/cache handling, copies and barriers,
initial image transitions and retirement (§5/§7). Add range/alignment capabilities to every
backend and rule-10 tests. Cover all allocation failures, odd copy layouts, upload/readback
bytes, frame-independent completion and destroyed-but-recorded resources. **Exit:** offscreen
copies and retirement pass with Vulkan synchronization validation and the null contract agrees.

### Step 5 — Compile the shaders and build persistent bindings

Implement the pinned stage producer, source variants, SPIR-V validation and layout checks;
shader modules, persistent descriptor pools, pipeline layouts and monolithic pipelines.
Add neutral renderer stage imports, keeping the working Metal producer. Validate malformed
shader envelopes/entry selection and GPU pipeline creation, layout holes, aligned buffer
ranges and retirement (§6). **Exit:** both shader pairs compile, their reflected decorations
match the documented ABI, and creating/destroying native pipelines stays validation-clean.

### Step 6 — Draw correctly offscreen

Complete pass/command operations, load/store and attachment transitions, bind state, inline
constants, viewport/scissor, indexed/non-indexed draws and failure discard. Draw the existing
sprite contract offscreen; inspect pixel probes including orientation, sRGB/alpha, depth,
clipping and culling. Inject submission failure and pending recording lifetime cases.
**Exit:** all command operations work under validation with bounded executable evidence.

### Step 7 — Present, resize and close failed frames

Implement §8's frame/image/submission identities, FIFO, acquisition/presentation synchronization,
per-image present semaphores, held undrawn images, idle-bounded teardown, offscreen frame
targets, resize and sticky errors. Complete
`interface.check` and enable the full `-Drhi=vulkan` build/test graph. Keep missing-feature
refusal explicit. **Exit:** a real window clears/presents, repeatedly resizes/minimizes/restores,
and every injected acquisition/recording/submit/present failure preserves ownership and markers.

### Step 8 — Run both samples and finish the window icon

Wire the sample surface choice and shader variants, finish the application-supplied icon,
and exercise real sprites/text/tilemaps/UI, room play, sandbox scripts and texture reload
with frames in flight. Preserve M12 jobs and deterministic saves. **Exit:** both samples
work on the first qualified platform, outside the source tree, with no runtime SDK/compiler.

### Step 9 — Prove Windows

Complete what Step 8 left on Windows:
- inspect one RenderDoc capture;
- measure frame pacing, including the unpaced frames of a minimised window that Step 8 recorded;
- prove whatever user-package, input and icon evidence is still missing.

Fix concrete failures. Record the actual driver, OS and tool versions tested, and whether each
result came from hardware or software. Extend AGENTS.md's bar with reproducible Vulkan compile
and native test commands as they now exist. **Exit:** Windows is a runtime claim with its limits
recorded. This step was also to prove Linux X11 and Wayland; that is M18's now (ADR-0039).

### Step 10 — Close the RHI proof and M13

Run §10's remaining integration gate, accepting unchanged successful evidence. Resolve every
M13 contract discrepancy in its originating design/ADR; do not silently weaken validation.
Update `CLAUDE.md` §§4/9, AGENTS.md, PROJECT_STATE, ROADMAP, README, design index, `rhi.md`,
`platform-interface.md`, relevant renderer/frame-loop sections and ADR statuses. Remove only
the deferred items actually proven. Commit, tag `m13`, push and stop before M14. **Exit:**
the Windows sample evidence and RHI contract agree, with explicit tested limitations, and
Linux is recorded as M18's.

## 12. What stays open

The floor and toolchain are accepted and pinned (Step 1). Linux runtime is M18's (ADR-0039).
Step 1's Resolution keeps its route on record, and no Linux driver or window-system behaviour is
assumed.
If the floor excludes the intended hardware, revise the unimplemented ADR with evidence, as
the floor-revision Resolution did. Adopting maintenance1 later is ADR-0037's revisit, never
a silent fallback.

Device recovery, transient bind-group API, adaptive frame counts, memory suballocation beyond
measured need, shader cross-compilation at material scale, content shader compilation,
multiple windows, multiple queues, render graphs, compute, MSAA, 3D features, new-platform
installers and driver distribution are not implemented here. M12's unsplit-caller slowdown
remains its existing measured debt. M14–M17 retain their own scope and gates.

## 13. Planning references

Primary technical references were checked on 2026-09-14; they explain API requirements, not
dependency pins or evidence that Foundry implements this design:

* [Vulkan 1.3 dynamic rendering sample](https://docs.vulkan.org/samples/latest/samples/api/hello_triangle_1_3/README.html)
* [Vulkan synchronization guide](https://docs.vulkan.org/guide/latest/synchronization.html)
* [Swapchain semaphore lifetime](https://docs.vulkan.org/guide/latest/swapchain_semaphore_reuse.html)
* [Destroying a swapchain with acquired images](https://docs.vulkan.org/refpages/latest/refpages/source/vkDestroySwapchainKHR.html)
  and [retiring `oldSwapchain`](https://docs.vulkan.org/refpages/latest/refpages/source/VkSwapchainCreateInfoKHR.html)
* [SDL native window properties](https://wiki.libsdl.org/SDL3/SDL_GetWindowProperties)

## Resolution — 2026-09-14, planning only

The owner requested architecture and steps, stopping before Step 1. This document records
that boundary and the unavailable runtime evidence rather than treating Mac cross-compilation
as support. The existing pipeline entry fields avoid a new shader container/API. The native
surface payload and presentation-completion proposals preserve the engine's layering and
retirement contract. ADR-0037/0038 remain proposed; no implementation step is complete.

The existing AGENTS.md bar passed for this documentation-only change: format, tests, native
and Metal checks, Windows/Linux null cross-checks and both 30-frame null sample runs. Local
documentation links and the consistency pass were clean. M12's performance evidence remains
accepted; no Vulkan runtime evidence is claimed.

## Resolution — 2026-09-14, floor revision before Step 1

The owner's candidate Windows target is an Intel Arc A750 on Windows 11 x64, driver
32.0.101.8991. Its `vulkaninfo` report shows Vulkan 1.4.356, dynamic rendering,
synchronization2, timeline semaphores, a graphics queue family with present support, and Win32
surfaces offering sRGB BGRA8/RGBA8 with FIFO. It reports no KHR or EXT swapchain maintenance1
and no surface maintenance1, so the proposed floor refused it: ADR-0037's revisit condition.
Offered keeping the floor and qualifying Linux first, making maintenance1 optional with two
presentation paths, requiring other Windows hardware, or removing the requirement, the owner
chose removal. §8 now uses one unextended path on every driver: per-image present-wait
semaphores, an undrawn acquired image held for the next frame instead of released, and
presentation teardown after submission completion and queue idleness, with Khronos's
documented gap recorded rather than hidden. The specification permits destroying a swapchain
whose acquired images have no outstanding operations, which is what discarding a held image
relies on.

This was a capability check before Step 1, not Step 1: the SDK's windowed sample, exact pins,
host shader tooling and the recorded route to Linux remain its work. No code, dependency or
tool changed, and ADR-0037/0038 remain proposed pending the owner's acceptance.

## Resolution — 2026-09-14, Step 1: targets qualified and tools pinned

**Qualified target: Windows x64.** An Intel Arc A750 (discrete, device `0x56a1`) on Windows 11
Pro build 26200 with Intel driver 32.0.101.8991 (Vulkan 1.4.356, conformance 1.4.0.0), on a
desktop PC reached from the Mac over SSH. Windowed runs start in the logged-in desktop session,
never a remote-desktop session or VM. It meets the accepted floor (the floor-revision Resolution
above). The SDK's `vkcube` selected the A750, opened its window on the Win32 WSI path, presented
600 FIFO frames in 10 s and exited 0 with `VK_LAYER_KHRONOS_validation` enabled through its
layer settings: core, synchronization, stateless, object-lifetime and thread-safety checks,
logged to a file with zero errors and zero warnings, and the layer's own startup information
message showing the log was live. A capture of the window showed the textured cube. Implicit
layers installed by RTSS and Steam were disabled for these runs; the capture stays out of the
tree. The SDK installer also updated the system Vulkan loader from 1.4.350 to 1.4.357, so later
Resolutions state the loader they ran against.

**Route to Linux x64.** The same PC and GPU, with a Linux installation on a second drive using
Mesa's ANV driver and a desktop offering both X11 and Wayland sessions, driven the same way.
It requires the owner to install it and is owed before Step 9; until then Linux evidence is
cross-compilation only, and no Linux driver behaviour is claimed.

**Pins.** LunarG Vulkan SDK 1.4.357.0 on every host, with archive SHA-256s and the headless
core-only installs in AGENTS.md §3. Both hosts used report `glslangValidator` 16.4.0 and
SPIRV-Tools v2026.3. Vulkan-Headers v1.4.357 (commit `e3b1eec08173d6b825cd3ac88c885a63b621504a`)
is a lazy `build.zig.zon` dependency; with it absent from the global cache, an ordinary
`zig build check` neither downloaded nor extracted it. Windows Zig 0.16.0 comes from the
official archive at the pinned hash. License entries landed with the pins: `vulkan-headers.md`
(distributed, `Apache-2.0` elected), `glslang.md` and `spirv-tools.md` (build-time only;
glslang's license file carries the Bison-exception GPL text and NVIDIA preprocessor terms, and
the entry records why neither reaches Foundry). The validation layers and RenderDoc receive
entries when a Foundry configuration first requires them.

**Shader and header proofs, scratch only.** A GLSL 450 vertex stage with a push-constant block
and a fragment stage with separate texture and sampler descriptors compiled with
`--target-env vulkan1.3` and passed `spirv-val`; a copy with a corrupted word count failed it.
The Windows and Mac tools produced byte-identical SPIR-V for both stages. The pinned headers
imported with `VK_NO_PROTOTYPES` for `x86_64-windows-gnu` (core and Win32 through `vulkan.h`)
and `x86_64-linux-gnu` (core, Wayland, and Xlib through opaque `Display`, `Window` and
`VisualID` declarations instead of system X11 headers), including `PFN_vkCreateInstance`. No
backend, build option or Foundry Vulkan code exists yet.

The AGENTS.md bar passed once with the new dependency pin. The three license entries passed the
release packager's own parser in a scratch harness that also confirmed a drifted entry is
refused, and local links and wrapping were checked.

## Resolution — 2026-09-14, Step 2: native window payloads and the system library

**What landed.** `platform.window` gains `extern` payloads `Win32Window` (`hinstance`, `hwnd`),
`XlibWindow` (`display` and a pointer-width `window`) and `WaylandSurface` (`display`,
`surface`), read through `NativeSurfaceHandle.win32()`, `xlib()` and `wayland()`. The outer
`kind`/`ptr` layout and Metal's meaning are unchanged, and `native_window` is appended as value 5:
a request that no handle carries. The SDL3 backend maps the running video driver to a kind
(`windows`, `x11`, `wayland`; `cocoa`, `offscreen` and `dummy` provide none), refuses an explicit
request for another window system before creating a window, reads SDL's Win32, X11 or Wayland
window properties once, refuses an incomplete set, and keeps the copy in its own allocation,
freed after `SDL_DestroyWindow`, because handle-pool slots move as the pool grows. No
`SDL_WINDOW_VULKAN` flag is set, so SDL never loads the loader. The null backend refuses every
native kind, and Metal reports `native_window` as unsupported. `Library.openSystem`, reached as
`Os.openSystemLibrary`, accepts a bare file name only: Windows calls `LoadLibraryExW` with
`LOAD_LIBRARY_SEARCH_SYSTEM32` and reports a missing module as `LibraryNotFound`; Linux and macOS
use the C runtime's `dlopen`, and a Linux build without libc refuses. `zig build
native-window-test`, defined for SDL3 builds and compiled by `check`, holds the real-window
tests. New refusals log at warning level, because Zig's test runner fails a test that logs an
error.

**Evidence.** On the Mac: the bar; `zig build test` with 1,371 of 1,372 tests passing and the
Windows-only lookalike test skipped; `native-window-test`'s macOS refusal; SDL3 `check` for
`x86_64-windows-gnu` and `x86_64-linux-gnu`; and `check -Drhi=metal`. Two guards were broken on
purpose — dropping `:` from the name check, and letting an explicit request ignore the window
system — and exactly their two tests failed. On the Windows x64 target, with byte-identical
sources, the platform tests compiled alone with `zig test` passed 13 of 13. They include the
lookalike test, which plants a non-image DLL on the ordinary search path through
`SetDllDirectoryW`, shows the ordinary loader reaching it (Windows error 193), and shows
`openSystem` reporting `LibraryNotFound`; with the `System32`-only flag cleared, that test failed,
and the file was restored byte for byte. `native-window-test` passed in the logged-in desktop
session: `win32_hwnd` from the automatic request, refusal of explicit X11 and Wayland requests, a
payload unchanged through pool growth and a resize, a stale handle after close, out-of-memory
cleanup including the payload allocation, and `vulkan-1.dll` from `System32` exporting
`vkGetInstanceProcAddr`. Linux ran nothing natively: X11 and Wayland stay cross-compiled until
Step 9.

**Found: the native Windows test suite was never green.** The first native `zig build test` on
the target (SDL3 platform, null RHI) passed 1,245 of 1,372 tests, skipped 5, failed 50 and
crashed 72 with `reached unreachable code`. The failures are in pre-existing modules: content
packing and staging, registries, script bindings, the ABI's asset calls, diagnostics, the asset,
sound and tilemap pipelines, settings, the engine, and four M9 confined-file tests in `os`. None
is Step 2 code, and cross-compilation had never exercised them. Every later step needs Windows
test runs, so the owner directed that the suite be repaired as its own bounded unit, with its own
Resolution, before Step 3. Native builds on that target use at most two jobs.

## Resolution — 2026-09-14, the native Windows test suite

**What was wrong.** The first native run's 72 crashes shared one site and its 50 failures one
cause, and none involved graphics: the run used the null RHI.

* **A mislabelled file handle in Zig 0.16.0's `std`.** On Windows, opening a file with
  `follow_symlinks = false` asks `NtCreateFile` for asynchronous I/O, yet the `File` returned
  says `nonblocking = false`. `std` chooses how to wait for a read from that label, so
  `NtReadFile`'s `STATUS_PENDING` reached `unreachable` in `readFilePositionalWindows`. Every
  crash came through `Os.readFileConfined`, the M9 no-follow read that packing, staging, scripts,
  settings, diagnostics and mods share; directories opened the same way are synchronous. On
  Windows `openFileConfined` now sets the label to what `File.Flags` documents for such a handle,
  with a note to delete the line once a toolchain upgrade labels the handle itself.
* **Fixtures that leaned on POSIX's `/tmp` fallback.** Seven test fixtures handed `Os` no
  environment and asked `tempDirAlloc` for scratch space. That answers `/tmp` on macOS and Linux,
  but Windows names a temporary directory only through `TEMP` or `TMP`, so it correctly said
  `PathUnavailable`. The fixtures in `asset.registry`, `app.engine`, the ABI's test engine and
  the asset, sound, tilemap and ABI render pipelines now use `std.testing.tmpDir`, as the `os`,
  diagnostics and settings tests already did; each fixture also gets its own directory, removed
  afterwards.

Two more were hidden behind those. `stage`'s test helper compared paths from `Dir.walk`, which
joins with `\` on Windows, against expectations written with `/`; the helper now normalises the
separator, and the staging code, whose inventory test passed, is unchanged. The
`foundry-diagnostics-stress` program, a run step of `zig build test`, gave its parent `Os` no
environment and then looked for the child's logs in the macOS and default XDG layouts only —
wrong on Windows, and on Linux too, where the child's `XDG_DATA_HOME` wins. The parent now hands
its `Os` the process environment through `app.environment`, as the samples do, and asks an `Os`
holding the child's environment where the child writes.

Only the Windows handle label changes engine behaviour. `tempDirAlloc` keeps its contract: an
`Os` given no environment still has no temporary directory on Windows.

**Evidence.** On the Mac, the bar passed. On the Windows target, with byte-identical sources
reset onto `4bc3707`, every step of `zig build test` at two jobs and below-normal priority
succeeded: 1,367 of 1,372 tests passed and 5 skipped, the last run answering unchanged binaries
from the build cache of the one before. Four of the skips create symlinks and one relies on POSIX
directory permissions, all by design. The four crashed `os` confined-file tests,
compiled alone, passed; with the label left as `std` sets it, the first of them crashed again in
`readFilePositionalWindows`, and `os.zig` was restored byte for byte.

**Consequence.** Native Windows `zig build test` is now a usable signal for Steps 3–10.

## Resolution — 2026-09-14, Step 3: a Vulkan device and its submission timeline

**What landed.** `engine/src/rhi/backends/vulkan/` holds the backend's first files. `vk.zig`
imports the pinned headers with `VK_NO_PROTOTYPES` — `vulkan.h` on Windows; the core, Wayland and
Xlib headers on Linux, with Xlib's three types declared opaquely in `xlib_opaque.h` — and checks
`VK_HEADER_VERSION` is 357. `dispatch.zig` fills global, instance, debug-utils, surface and device
tables by field name through `vkGetInstanceProcAddr` and `vkGetDeviceProcAddr`, from
`vulkan-1.dll` or `libvulkan.so.1` opened with `Library.openSystem`; a function the loader lacks
is an initialization failure naming it. `selection.zig` holds §5.1's floor and ranking as plain
data with no header, so its tests run in the ordinary suite on every host. `backend.zig`'s
`Device` opens the loader, requires Vulkan 1.3 of it, creates the instance, the messenger and —
when given a Win32, Xlib or Wayland payload — the surface, chooses the device, creates it with
exactly `dynamicRendering`, `synchronization2` and `timelineSemaphore` (plus `VK_KHR_swapchain`
when presenting) and one queue, then a timeline semaphore and a resettable command pool. One
`teardown` releases whatever exists, newest first, and closes the loader last, so a failed
initialization and `deinit` unwind through the same code. Each submission signals the timeline
semaphore with its `lifetime.Timeline` serial: `waitIdle` waits for that value,
`beginCommandBuffer` polls the counter first, and a native command buffer begins again only after
its submission finished, or at once when it was discarded or refused. Device loss is sticky and
waits for nothing.

**Validation mode.** `Validation.required` enables `VK_LAYER_KHRONOS_validation` with
synchronization validation through `VK_EXT_layer_settings`, and a messenger covering instance
creation and destruction as well as everything between. Errors reach `core.log` at error level, so
Zig's test runner fails a test that provokes one; warnings at warning level. A missing layer or
extension refuses the device rather than running unvalidated. The layer receives its license entry
now (`vulkan-validation-layers.md`, build-time only), because this is the first Foundry
configuration that requires it.

**Build.** `-Drhi=vulkan` is accepted for Windows and Linux targets and refused elsewhere with the
alternatives named. Until Step 7 it defines two working steps, `vulkan-test` and the compile-only
`vulkan-check`, rooted at the ordinary `rhi` module with the Vulkan backend selected; installing,
`test` and `check` fail with the reason. Only that branch fetches Vulkan-Headers and attaches
their include path, to `rhi` alone. `rhi/root.zig` exempts Vulkan from `interface.check` until
Step 7, and `render2d`'s shader switch gains a Vulkan arm that is a compile error naming Step 5;
no ordinary graph reaches either.

**Found.** A surface payload's `HWND` is a handle, not the address of an aligned structure, so the
first native run's alignment-checked cast into the header's pointer type panicked. The backend now
copies handle bits into those fields.

**Evidence.** On the Mac: the bar, with 1,377 of 1,378 ordinary tests passing and the Windows-only
lookalike test skipped; `vulkan-check` for `x86_64-windows-gnu` and `x86_64-linux-gnu`; and
`-Drhi=vulkan` refused on macOS with its message. Two mutations of a scratch copy of
`selection.zig` — ranking inverted, and presentation ignored when choosing the queue — each failed
exactly one test. On the Windows target (Intel Arc A750, driver 32.0.101.8991, loader and
validation layer 1.4.357, implicit layers disabled), with byte-identical sources,
`zig build vulkan-test -Drhi=vulkan` at two jobs and below-normal priority passed 144 of 144: the
`rhi` module's tests, the fourteen device tests among them. Those cover an offscreen device with
the messenger heard and no error; empty work submitted, waited for and its command buffer begun
again; recordings finishing in the order they began, whatever order they reached the queue;
reclamation by poll without a wait; discard; a recording left open at teardown; a refused
submission; sticky device loss; failure injected at each of the fifteen initialization stages;
every host allocation of initialization, and of beginning a recording, failing in turn; an absent
validation layer refused; unusable surface kinds refused; and a real SDL window whose surface the
chosen queue presents to, with failures injected at and after the surface stage. The messenger
reported no validation warning or error in any of them. With teardown mutated to forget the
command pool, validation reported the leak at error level and the run failed; the file was
restored byte for byte. The window test ran from the target's SSH session, so it proves surface
creation and present support, not a visible window. The new license entry, with the five
already recorded, passed the release packager's own parser in a scratch harness. Linux ran
nothing natively.

**Not yet.** Resources, bindings, pipelines, passes, frames, presentation and `capabilities` are
Steps 4–7; the backend implements only what the tests above use.

## Resolution — 2026-09-14, before Step 4: three contract clarifications

Step 4 reached three places where the RHI contract was silent, or narrower than Vulkan needs.
Each is written into `rhi.md` §4 and §11 before any code, as ADR-0037 decision 7 requires, and
none changes a public C table, asset format or mod capability.

1. **Every buffer and texture declares a usage.** Vulkan and D3D12 cannot create either with an
   empty usage set, and under rule 11 such a resource permits no operation. Every backend now
   refuses the descriptor with `InvalidDescriptor`. No engine code creates one; two
   validation-backend test helpers did, and they now declare a copy flag the case under test
   does not rely on.
2. **Copy sources are bounded too.** Rule 10 already put a copy's region inside the resource it
   addresses, but the validation backend checked only destinations. It now checks each buffer
   copy's source and destination ranges, a buffer-to-texture copy's source rows, and that a
   nonzero `src_bytes_per_row` holds a row of texels; without them a Vulkan copy may read past
   its buffer. A zero-sized copy stays legal and copies nothing.
3. **Binding offset alignment and range are capabilities.** §5.3's limits join `Capabilities` as
   `uniform_buffer_offset_alignment`, `storage_buffer_offset_alignment`,
   `max_uniform_buffer_binding_size` and `max_storage_buffer_binding_size`. Vulkan reports its
   device's limits. Metal reports 256-byte uniform and 16-byte storage offset alignment — Apple's
   documented macOS requirements for constant- and device-address-space buffer offsets — and
   `MTLDevice.maxBufferLength` for both ranges. The validation backend's strict profile reports
   256-byte alignment for both and Vulkan's guaranteed minimum ranges, 16,384 bytes uniform and
   2^27 bytes storage. Rule 10 checks a bind group against the device's own values.

## Resolution — 2026-09-14, Step 4: resources, copies and retirement

**What landed.** Vulkan buffers, images, image views and samplers now use the RHI's existing
generational pools. One resource gets one `VkDeviceMemory` allocation selected only from its
`memoryTypeBits`: device-local prefers private memory and never maps; uploads require host-visible
memory and prefer coherent; readbacks require host-visible memory and prefer cached. Required or
preferred dedicated allocations are honoured, and `maxMemoryAllocationCount` is checked before a
Vulkan allocation. Upload and readback buffers stay mapped; non-coherent memory flushes or
invalidates the complete allocation, which is atom-aligned without running past it. Format
features, extents, mip counts and declared usage are checked before an image is published. Images
begin undefined and a requested initial state is reached by an ordered submission. Copy-only
images have no view; sampled and attachment images get a view over every declared mip and their
format's aspects.

Destroying a handle removes it immediately and places its native backing in the existing
`lifetime.Retirement`, whose capacity was reserved before publication. Collection follows the
submission timeline's resolved recording number, so submitted, open and later-discarded
recordings all preserve the backing they could have named. Backend-owned repack buffers use the
same retirement path. Allocation and handle-publication failures unwind in reverse order, and
teardown releases live and retired backing before destroying the device.

**Copies and synchronization.** Texture states map to synchronization2 layout, stage and access
barriers; buffer barriers now express the copy-to-vertex/index/uniform/storage dependency the
renderer already records. Every command recording begins with the conservative prior-submission
write-to-next-use dependency §7 requires. Within one recording, a later transfer read or write is
separated from an earlier transfer write, including the private staging buffer and successive
image updates. A buffer-to-texture source whose offset and row stride are whole texels maps
directly to `VkBufferImageCopy`; every other legal byte layout is copied row-by-row on the GPU to
a tightly packed device-local buffer first. Nonzero texture origins and mip levels remain native
Vulkan fields rather than being narrowed.

The RHI contract gained the three clarifications above before their code. Null, Metal and Vulkan
now report uniform/storage binding alignment and maximum range capabilities. Null rule 10 checks
both ends of buffer copies, the complete byte span of buffer-to-texture source rows without
overflow, and buffer-binding alignment/range. All three backends refuse a buffer or texture with
no declared usage. This changes no public ABI or asset format.

**Recovery and evidence.** Claude's recovered tree had already implemented most of the unit and
had run it once on the qualified Windows target. That run passed 160 of 163 tests and exposed the
unfinished boundary precisely: synchronization validation reported transfer read-after-write and
write-after-write hazards, and Vulkan rejected views made for copy-only images. The copy-only view
condition had already been corrected locally; completing the transfer and submission barriers
made the same validation-required target run pass **163/163** on the Intel Arc A750, with zero
validation warnings or errors. It covers upload → device-local → readback bytes across independent
submissions, forced flush/invalidate paths, tight and odd-row texture copies into two mip levels,
initial transitions, submitted and discarded retirement, every Vulkan resource-creation failure,
every host allocation made by resource creation/repacking, device allocation-count refusal and
reported device limits. Removing the null source-bound predicate failed exactly the two new copy
limit tests, then restoration passed them.

On the Mac, the required bar passed at **1,399 declared / 1,389 headless tests**, ten Metal-only
and one Windows-only test skipped there. `vulkan-check` compiled the selected backend for both
`x86_64-windows-gnu` and `x86_64-linux-gnu`. Linux still ran nothing natively. Shaders, persistent
bindings and pipelines remain entirely Step 5.

## Resolution — 2026-09-15, Step 5: checked shaders, persistent bindings and pipelines

**The producer is part of the selected build graph.** The render2d sprite and sandbox quad each
gain one GLSL 450 vertex stage and one fragment stage. For every stage `build.zig` runs the pinned
host `glslangValidator -V --target-env vulkan1.3`, then `spirv-val --target-env vulkan1.3`, then
the host `fshadercheck`; only the last tool's copied output enters an anonymous module import.
That small checker is deliberately not material reflection. It recognizes exactly these four
profiles and checks the `main` stage, vertex and varying locations, fragment output, descriptor
sets and bindings, distinct image/sampler types, uniform/push storage, member offsets,
column-major matrix decoration and matrix stride. The sandbox stages remain demonstration
sources, not content assets, and no `.fdt`/`.fpk` format or public ABI changes.

`render2d` now presents neutral vertex and fragment bytes plus entry names to the RHI. Metal keeps
the existing metallib and `vertexMain`/`fragmentMain`; Vulkan embeds separate checked SPIR-V
modules and selects `main`. Runtime Vulkan shader creation bounds the envelope, copies it into
four-byte-aligned retained storage and creates `VkShaderModule`; the retained bytes let pipeline
creation refuse a missing or wrong-stage entry before the driver. Runtime source compilation is
`RuntimeCompilationUnsupported`, as ADR-0038 requires.

**Bindings and pipelines preserve public-handle semantics.** Immutable descriptor sets come from
growable device-owned pools with `FREE_DESCRIPTOR_SET`; a pool is never reset under live sets,
and an individual set is freed only through completion-backed retirement. Bind-group creation
requires exactly one correctly typed resource for each copied layout entry and checks live
handles, usage, buffer alignment and resolved range before updating the set. Pipeline layouts use
one immutable device-lifetime empty set layout for holes so later group indices do not move.
Ref-counted native set-layout and pipeline-layout backings outlive their public handles while sets,
pipeline layouts or pipelines retain them; retirement cascades only after the recording timeline
allows it. Per-set, aggregate pipeline and per-stage descriptor limits are checked before Vulkan.

Graphics pipelines are monolithic dynamic-rendering pipelines over the existing RHI descriptor:
separate stages and entries, explicit vertex locations/bindings, topology, raster/culling,
multisampling, depth/stencil format, color formats, blend/write masks and dynamic viewport/scissor.
The front-face translation anticipates §6's negative viewport so Foundry's declared winding does
not change. This step creates and destroys these objects; it deliberately records no pass and
draws no pixels. Pass state, commands and offscreen probes remain Step 6.

**Evidence.** On the qualified Windows Arc A750, `vulkan-test` required the Khronos validation
layer and synchronization validation and passed **171/171**. The six Step 5 backend tests cover
four ABI-checked modules and native pipelines, malformed envelopes and wrong-stage entries,
persistent sets and pool growth, layout holes, aligned resolved buffer ranges, dependency
retirement, every added Vulkan-call failure and every host allocation failing in turn. The
messenger reported no validation warning or error. Moving the sprite sampler from binding 1 to 3
made the producer fail specifically with `DecorationMismatch`; restoring it passed. Windows and
Linux `vulkan-check` each compiled the backend and ran all four producer chains. The Mac bar passed
at **1,401 declared / 1,391 headless tests**, ten Metal-only and one Windows-only test skipped on
macOS, plus 28 Vulkan backend tests in their own graph. Linux still ran nothing natively.

## Resolution — 2026-09-16, Step 6: drawing correctly offscreen

**What landed.** `CommandBuffer.beginRenderPass` opens a dynamic-rendering pass. Each colour and
depth attachment is barriered from its declared initial state into its attachment layout before
`vkCmdBeginRendering`; the render area is the attachments' common extent; load and store actions
map to Vulkan's, `discard` to `DONT_CARE`; clear values carry over; and a stencil-bearing depth
format is the stencil attachment too. Viewport and scissor start covering the render area, as
Metal's do, so a draw that sets neither is valid. `RenderPass.end` ends rendering and barriers each
live attachment to its declared final state; passes are pooled like command buffers, so ending one
cannot fail. `setPipeline` binds the monolithic pipeline, and a change of pipeline layout marks
every group for rebinding and drops the inline constants, as `rhi.md` §9 states. Bind groups and
constants are remembered and flushed at the draw against the bound layout: sets only for the
groups the layout declares, so holes stay empty, and constants copied at the call, padded privately
to four bytes and pushed no larger than the layout declares. Vertex and index buffers bind at once.
`setViewport` implements Foundry's y-up clip space with a viewport of negative height anchored at
the rectangle's bottom edge, and `setScissor` stays in top-left framebuffer coordinates. `draw`
and `drawIndexed` map directly. A pass begun on a recording that is no longer open records nothing.

**Found: Step 5's front-face inversion was wrong.** Step 5 translated a pipeline's declared front
face inverted, anticipating the flipped viewport. Vulkan judges facing in framebuffer coordinates,
after the viewport transform, and the negative-height viewport already makes Foundry's
counter-clockwise triangles counter-clockwise there. The inversion therefore culled front faces:
the first native run's culling probe read black where a front-facing triangle belonged, and passed
178 of 179. The descriptor's front face now maps directly, with the reason beside it.

**Evidence.** On the Windows target (Intel Arc A750, validation and synchronization validation
required, implicit layers disabled), with byte-identical sources, `zig build vulkan-test
-Drhi=vulkan` at two jobs and below-normal priority passed **179/179** with no validation warning
or error. The eight Step 6 tests draw render2d's produced sprite stages into offscreen targets and
read the pixels back through the backend-private copy §10 permits. A quad in clip space's top-left
quadrant lands in the top-left pixels. An indexed draw takes its push-constant transform, and a
scissor clips it. A straight-alpha sRGB texel decodes when sampled, blends premultiplied in linear
light over black and encodes within two levels of the computed value, with opaque alpha. A depth
clear of 1 lets the sprite's depth of 0 draw and a clear of 0 rejects it. With culling off, a
counter-clockwise and a clockwise triangle both draw; with back faces culled, only the
counter-clockwise one does. A cleared target survives a later pass that loads it and is then
sampled by a third. A drawing recording refused at submission, or discarded, keeps its destroyed
pipeline, group, buffer and target retired until a wait, then releases all of them. A pass whose
allocation fails leaves its recording discardable. With the viewport's flip removed, the
orientation and culling probes both failed; the file was restored byte for byte. The pass and draw
code compiled for `x86_64-windows-gnu` and `x86_64-linux-gnu`. Linux ran nothing natively. The
Mac bar, run on 2026-09-18 once the Xcode licence let the macOS SDK link, passed with 1,390 of
1,391 headless tests and one Windows-only test skipped — Step 5's figures, since nothing macOS
builds changed.

**Not yet.** Frames, the swapchain, presentation, resize and `interface.check` are Step 7.

## Resolution — 2026-09-16, Step 7: presentation, resize and failed frames

**What landed.** The frame ring is the other backends': `beginFrame` waits through the marker its
slot's previous frame left, reserves room for its own marker before anything is acquired, and only
then opens a frame and spends an index; `endFrame` leaves a marker, an empty submission signalling
the next timeline value. A headless device draws into an offscreen target behind a stable surface
handle, which `resizeSurface` rebuilds behind the same handle while the old target is retired after
the frames that drew into it. A window's device negotiates BGRA8 then RGBA8 sRGB in the sRGB colour
space for its lifetime, or refuses the surface as unsupported; creates one acquire semaphore per
frame slot; and gives its stable surface handle the view of whichever swapchain image the frame
holds. The swapchain is FIFO with one image more than the surface's minimum, the surface's current
transform, opaque composition where offered, and transfer-source usage where the surface allows it.

Acquisition waits at most 100 ms and maps §8's table: timeout and not-ready are routine
unavailability; out-of-date queues a rebuild and is unavailability; suboptimal keeps the acquired
image and its signalled semaphore, finishes the frame and rebuilds after it; surface loss and device
loss are sticky. The first submission to use the frame's new image waits on its acquire semaphore,
and only a drawing submission that reached the queue marks the image drawn — a discarded or refused
one never does. `endFrame`'s marker consumes whatever acquire signal is left. If the image was
drawn, the marker also signals that image's present-wait semaphore and the image is presented;
out-of-date or suboptimal presentation closes the frame with its marker preserved and queues a
rebuild, out-of-date reporting unavailability. If it was not drawn, the image is held, unpresented,
and taken by the next frame without acquiring; repeated empty frames reuse it, and a rebuild or
teardown discards it with its swapchain. A marker that cannot be queued in a window's frame latches
the device as failed, since synchronization that frame promised may never be signalled.

A rebuild runs only between frames, after every submission has finished and then the queue is idle —
the documented practical boundary, not proof that presentation finished, which unextended Vulkan
cannot give. A zero surface extent keeps the current swapchain and reports unavailability, which is
how a minimised window's frames are skipped. Creation passes the old swapchain, which Vulkan retires
whether or not creation succeeds, so a failed creation leaves none: out of memory is reported with
the rebuild still pending, and any other failure is sticky surface loss. `resizeSurface` treats a
zero extent as suspension; any other extent marks a rebuild the next frame performs, so a drag's
resizes coalesce into one rebuild and a fatal rebuild error is returned by the next render call
rather than only logged. Teardown releases image views, present-wait semaphores, the swapchain and
the slots' acquire semaphores before the device; swapchain images are never destroyed as textures.

`interface.check` now holds for Vulkan and `rhi/root.zig` exempts nothing. `-Drhi=vulkan` builds the
ordinary graph — `test`, `check` and every test step — and adds `vulkan-test`, `vulkan-check` and
the desktop-session `vulkan-window-test`. Installing or running the samples still refuses with the
reason, because they ask for no surface outside macOS until Step 8.

**Found.** Step 7's first native run failed seven earlier leak tests: the headless device's own
surface texture counted as a caller-owned live resource. The count of what a caller owns now
excludes it; retirement capacity is unaffected, since `reserve` counts existing entries too.

**Evidence.** On the Windows target (Intel Arc A750, validation and synchronization validation
required, implicit layers disabled), at two jobs and below-normal priority: `zig build vulkan-test
-Drhi=vulkan` passed **185/185**, including six headless frame-ring tests and the real-window test
now building its first swapchain over SSH. In the owner's desktop session, started by a scheduled
task with an interactive logon, `zig build vulkan-window-test -Drhi=vulkan` passed **10/10** with no
validation error. A real window presented one clear colour for more than four seconds; its 480×320
client area, captured from the screen and separately through `PrintWindow`, read **244, 89, 218** at
its centre and corner — linear (0.9, 0.1, 0.7) encoded to sRGB. Five resizes, a zero-extent
suspension and three minimise/restore cycles rebuilt the swapchain between frames, with minimised
frames skipped as unavailability. Empty frames held one image, a discarded draw left it held, a
barrier-only submission consumed the acquire signal without earning a present, and the next drawing
frame presented the held image. Injected acquisition timeout, out-of-date, out of memory and
suboptimal; presentation suboptimal, out-of-date and out of memory; a refused drawing submission; a
failed swapchain creation; surface and device loss at acquisition, presentation and creation; a
failed marker; and teardown with a frame open or an image held each kept frame identity, markers and
ownership as §8 states, with teardown leak-checked. The whole test graph with Vulkan selected, `zig
build test -Drhi=vulkan`, succeeded at every step: **1,423 of 1,433** tests passed and ten skipped —
the five POSIX-only tests, and five that reach every step of an upload only through the validation
backend's CPU-side buffers. With every frame presenting whether or not anything drew into its image,
three window tests failed — the held image, the refused draw and teardown while holding — and
validation reported an undrawn image presented in the undefined layout; the file was restored byte
for byte and the suite passed again. The frame and presentation code compiled for
`x86_64-windows-gnu` and `x86_64-linux-gnu` under `zig build check -Drhi=vulkan`. Linux ran nothing
natively. The Mac bar, run on 2026-09-18 once the Xcode licence let the macOS SDK link, passed with
1,390 of 1,391 headless tests and one Windows-only test skipped — Step 6's figures, since the macOS
graph gained no tests — and the headless `zig build test -Dplatform=null -Drhi=null` passed 1,378 of
1,379.

**Not yet.** The samples' Vulkan surface and shaders, the window icon and frames in flight under
real content are Step 8; Linux X11 and Wayland, pacing and RenderDoc captures are Step 9.

## Resolution — 2026-09-18, Step 8: both samples on Vulkan, and the window icon

**What landed.** A window asks for the surface the selected backend presents to. `rhi.window_surface`
is `metal_layer` for Metal, the request-only `native_window` for Vulkan and `none` for the
validation backend, and `app.window_surface` passes it on. Both samples open their window with it,
so neither names a graphics API, and `-Drhi=vulkan` no longer refuses to install or run them. Their
shader variants needed no sample change: the samples draw only through `render2d`, whose
engine-owned sprite shader has carried a SPIR-V variant, chosen by the build, since Step 5.

The window icon is §9's platform operation, `setWindowIcon(window, WindowIcon)`, specified in
`platform-interface.md`: straight-alpha RGBA8 rows with a stride, borrowed for the call alone, and
`InvalidWindowIcon` unless the sides are 1–256, the stride covers a row and fits a signed pitch,
and the bytes cover every row. SDL3 wraps the bytes in a surface it copies before returning; a
window system that will not take an icon is `WindowIconRefused`, and the window keeps its default.
The null backend validates and records the size it accepted, and `app.Engine.setWindowIcon` only
validates when headless. The engine supplies no mark, reads no file and decodes nothing for it.
Each sample declares an `icon` asset kind with a `source`, ships a 64×64 PNG generated from
Foundry's mark in its own package, and names it in an optional `window_icon` field of its `config`
record, the schema's version 2. After applying preferences it registers a loader for its own kind,
decodes the image bounded to the platform's limit, hands it to the window and releases it; any
failure is a warning, and the window keeps its default. A later package overriding the config
record chooses another icon, as it chooses the window size. The C mod API gains nothing.

**Found.** `fpack`'s derivation decided which files authored records already spoke for by asking
whether each record's schema was an engine asset kind. A package's own kind was not, so each
sample's `icon.png` was compiled twice — once as its icon and once as a derived texture with an id
of its own — against `assets.md` §3's rule that explicit beats implicit and never duplicates it.
Any record with a string `source` now speaks for its file, which is what the registry takes an
asset kind to be.

`-Drhi=vulkan` still requires the SDL3 platform, as Step 3 decided, so there is no headless Vulkan
run. M12's deterministic saves were compared headless on the validation backend, where they have
always been compared; the renderer takes no part in simulation.

A minimised window's surface has zero extent, so each frame reports unavailability at once and is
skipped, as §8 states — but the sample loop then runs unpaced, at about 1.7 ms a frame against
FIFO's 16.7 ms: 1,571 frames in roughly three seconds minimised. The contract holds. A minimised
game spinning a core is a pacing question, and pacing is Step 9's, so it is recorded rather than
fixed here. How a minimised Metal window paces was not measured.

**Evidence.** On the Mac, the bar passed with **1,394 of 1,395** headless tests, the Windows-only
test skipped — four new — and `zig build test -Dplatform=null -Drhi=null` passed **1,382 of
1,383**. A windowed Metal sandbox asked for `metal_layer` and wore its 64×64 icon. Headless, both
samples decoded and validated theirs, and a user package overriding the sandbox's config set
960×540, volume 0.50 and a 16×16 icon, loading after `sandbox:content`. Restoring the old schema
check failed the new `fpack` test, and dropping the stride check failed the icon validation test;
each file was restored byte for byte.

On the Windows target (Intel Arc A750, Windows 11 build 26200, SDL 3.4.14's `windows` video
driver), at two jobs and below-normal priority, over SSH: `native-window-test` passed **8 of 9**,
one skipped, and the icon read back from the window with `WM_GETICON` at both sizes was red where
red was supplied and blue where blue was; handing SDL the bytes as BGRA failed that test, and the
file was restored. The whole `zig build test -Drhi=vulkan` passed **1,427 of 1,437**, the same ten
skipped as Step 7. `zig build install -Drhi=vulkan` built both samples and compiled their content;
the prefix was copied to a new directory whose name holds a space and the original deleted, and
the copy's own `fpack` compiled the user package into a scratch `APPDATA`. Headless saves after 600
frames were byte-identical with no workers and with four, and identical to the Mac's.

Then, in the owner's desktop session from a scheduled task with an interactive logon, each run
started from the moved copy with `PATH` holding only the system directories — no Zig, SDK or
compiler — and `APPDATA` at the scratch root. Four enabled validation and synchronization
validation through the loader; the fifth disabled every layer. Each window was found by its
process and title, and its client area and title bar were captured from the screen:

* the sandbox for 900 frames with its scripted walk, a pick every 90 frames and its installed
  texture touched every 200 ms: **29** reloads of `sandbox:textures.sprites` with two frames in
  flight, nine picks, its script lighting and dousing beacons, a 16.6 ms p95 and a clean exit;
* the sandbox resizing itself every 120 frames, minimised and restored twice from outside, then
  closed with `WM_CLOSE`: presentation resumed after each restore and seven requested sizes
  arrived as resizes, requests made while minimised raised none, and the close exited cleanly;
* the room on autopilot with the overlay open for 600 frames: four of six lamps lit, 114
  contacts and 43 sounds, and the character card opened, typed into and clicked out of with none
  of that input reaching the hall;
* the sandbox with the user package: 960×540, volume 0.50 and the package's 16×16 icon;
* the sandbox with every layer disabled: 600 frames at a 16.62 ms median and p95, clean exit.

Every validation log held only the layer's start-up notice: **no error and no warning**. The
captures show sprites, text, the tilemap, the overlay and the room's card drawn correctly, and
every title bar wears the sample's mark, or in the user package's run its green square;
`WM_GETICON` returned both icon sizes for every window. The validation layer was found through
the SDK's registry entry, not `PATH`, so the run with every layer disabled is the one showing that
nothing from the SDK is needed. A first desktop pass had taken the process's first visible window,
which was not always the sample's, and bounded the minimise run by a frame count that unpaced
minimised frames used up before the restore; both were harness faults, fixed before the runs above.

**Not yet.** Linux X11 and Wayland, the icon there, frame pacing — a minimised window's included —
RenderDoc captures and the second OS's native tests are Step 9. The Windows claims are this
machine's.

## Resolution — 2026-09-18, scope: Linux leaves M13

**Decision.** After Step 8 the owner removed Linux from the current milestones. The first game
built on Foundry targets macOS and Windows, and Linux is added once that game is complete,
immediately before any 3D work. [ADR-0039](../adr/0039-linux-after-the-first-game.md) records
it, superseding ADR-0033's and ADR-0037's M13 Linux obligation and nothing else. Linux x64
runtime support is now M18, the first milestone of the roadmap's Phase 5.

**What changed here.** §1, §2.2, §4, §9, §10, Steps 9 and 10, and §12 now close M13 on Windows
x64, each saying where Linux went. Step 9 proves Windows alone. §10 keeps the Linux evidence
list as the starting point for M18's own design, and Step 1's recorded route stays on record.
Earlier Resolutions stand as written; where they say Linux is Step 9's, read M18.

**What did not change.** No code changed. These Linux paths stay implemented:
- the X11 and Wayland payloads;
- the automatic choice of window system;
- the loader opened through `dlopen`;
- Xlib and Wayland surface creation;
- the Linux shader and header imports.

`zig build check -Drhi=vulkan` and `vulkan-check` for `x86_64-linux-gnu` stay part of Vulkan
work, and the bar keeps its null Linux cross-check. A Linux compile failure is still a bug. Nothing has run them natively, and no document may call
Linux supported at runtime until M18 proves it. Vulkan remains Linux's backend.

## Resolution — 2026-09-19, Step 9: Windows proven, with its limits

**Tested on.** Every Windows result below came from hardware, and no software rasterizer ran
anything:
- an Intel Arc A750 (discrete, Vulkan 1.4) with driver 32.0.101.8991, and an Intel Core i3-10105F;
- Windows 11 build 26200, one 1920×1080 display at 60 Hz, scale 1.00;
- the Vulkan loader 1.4.357.0 and the validation layer from LunarG SDK 1.4.357.0;
- SDL 3.4.14's `windows` video driver, Zig 0.16.0 and RenderDoc 1.46.

**Found: the SSH evidence carried an overlay's layer.** The owner's SSH session belongs to an
administrator and runs at high integrity. There the Vulkan loader ignores
`VK_LOADER_LAYERS_DISABLE` and every layer-path variable, and says so only under
`VK_LOADER_DEBUG=all`. So RivaTuner Statistics Server's implicit layer was inserted into every
Vulkan process started over SSH since Step 3, while the Resolutions said implicit layers were
filtered out. Desktop-session runs, the source of Step 8's validation evidence, run at normal
integrity. A probe there with the filter set inserted no layer and printed no elevation notice.
Over SSH, the layer's own `DISABLE_RTSS_LAYER=1` removes it, confirmed with
`VK_LOADER_DEBUG=layer`. With it set, the whole `zig build test -Drhi=vulkan` ran again with
nothing from cache and passed 69 of 69 steps and **1,427 of 1,437** tests, the same ten skipped. No
earlier conclusion changes. AGENTS.md now says how to run clean over SSH.

**Found: Step 8 broke both releases.** `zig build dist` refused both samples. Each package's
`icon.png` is an asset of the sample's own kind, which the stager cannot resolve and requires by
name (`distribution.md` §8), and Step 8 named neither. The bar stages no release, so nothing
noticed. Each release description now lists its icon under `extra_files`. Both apps stage, and
the staged room wears its icon. AGENTS.md now stages both releases whenever sample content, asset
kinds or release descriptions change.

**Found: a minimised window spun a core.** Step 8 recorded unpaced skipped frames; measured, the
Step 8 build used **102%** of a core while minimised, by the process's CPU time, skipping 1,932
frames in about 3.7 seconds. Pacing is the samples' policy, not `Engine`'s, as the null-backend
yield beside the fix already says. So both samples now sleep one simulation step after a frame
whose rendering was skipped. The same sequence on this build used **35.8%** minimised against
38.0% presenting, with 161 frames skipped. Cycle counters place the main thread's minimised cost
at 952 million cycles a second against the 3.7 GHz reference: a quarter of a core, doing real work
rather than spinning.

Closing the window while it was still minimised made the sample's last-240-frame summary cover
skipped frames alone. There were about 43 a second, each with a 6.3 ms median of work before its
sleep: the tick, the UI description and the submission of 3,712 sprites. Each span took about 2.3
times as long as when presenting: simulate 2.08 ms against 0.76, submit 3.33 against 1.42. That
fits the processor clocking down under a load that sleeps most of each frame, but it was not
measured.

**RenderDoc.** In the desktop session, RenderDoc 1.46 launched the relocated sandbox through
`ExecuteAndInject`, with its layer named by `VK_ADD_LAYER_PATH` and nothing registered. It
captured frame 244 (1.9 MB) through target control and replayed it locally on the Arc: supported,
not degraded. The frame is one command buffer: a buffer copy, dynamic rendering that clears, eleven
indexed draws, a store and a present. The sprite draw, event 20 with 22,272 indices (3,712 quads),
was inspected in detail:
* **stages and bindings:** the engine's SPIR-V vertex and fragment modules, entry `main`. The
  fragment stage reads the 64×64 `R8G8B8A8_SRGB` sprite sheet at set 0, binding 0, through a
  point-filtered, clamp-to-edge sampler. The bound image read back as the sandbox's sixteen
  sprites.
* **constants:** the 64-byte push-constant block `view_projection`, holding
  diag(2/1152, 2/648, 1, 1): the camera at the origin, at zoom 1, for the 1152×648 window.
* **vertex data:** 20-byte vertices. Position and UV are two floats at offsets 0 and 8, and colour
  is normalised RGBA8 at 16. The indices are 32-bit, and the first quad's are 0, 1, 2, 0, 2, 3.
  Its first vertex, (−96, −80) with UV (0.25, 0.25), left the vertex stage at (−0.1667, −0.2469):
  exactly the constants applied.
* **viewport:** anchored at y = 648 with height −648, the flip Step 6 implemented.
* **resulting target:** the `B8G8R8A8_SRGB` swapchain image holds the sprite field after event 20,
  and the overlay's panels and text over it after the last draw.

The capture tool has two limits here, neither of them Foundry's:
- Its layer loads only where the loader honours `VK_ADD_LAYER_PATH`, so a capture needs a
  normal-integrity process: the desktop session, not SSH.
- A fresh qrenderdoc waits on a first-run question before it runs a script.

**Pacing.** Presenting, FIFO held the display's rate:
- the sandbox's last 240 frames after a restore: 16.49 ms median, 16.62 ms p95, 16.63 ms maximum;
- the same during the input run: 16.62 ms, 16.63 ms and 21.47 ms;
- the room's present span: a 15.71 ms median.

On the Mac, a windowed Metal sandbox on a 120 Hz display ran at an 8.04 ms median.

**Real input.** Step 8's input came from the samples' own scripts. These runs sent keys and the
mouse through Windows' input queue to the foreground sample, in the desktop session:
`keybd_event` with scan codes, and `mouse_event`.
* **The sandbox:** held W and D walked the player from the origin to (74, 58), with 17 contacts,
  and each key also arrived as text. A click at the window's centre picked entity 4000. Three
  wheel notches zoomed about the cursor from 1.00 to 1.57. F5 saved 4,002 entities, and Escape quit
  cleanly.
* **The room:** D walked, and a click sent the walker, one walk command. Tab opened the card,
  Escape closed it, and a second Escape quit.
* **The room's card, typed into:** a click focused the name field. The keys w, a, s, d, space and
  w, four of them walking keys, typed "wasd w" into it, and the walker stayed where it stood. The
  card took the click, the hall took no walk command, and the audit counted **no capture
  failures**. A screenshot shows the renamed walker unmoved. The text went in before the default
  name, because a click focuses a field without moving its caret; `ui.md` never offered that, and
  it is not a platform matter.

User-package and icon evidence was already complete after Step 8. It covered:
- a user package's size, volume and icon, from the relocated install;
- `WM_GETICON` from every window.

Nothing was added there.

**The bar.** AGENTS.md's bar section now carries the conditional checks this milestone needs:
- `vulkan-check` and `check -Drhi=vulkan` for both targets, when Vulkan, shader or native-window
  code changes;
- both releases staged, when sample content, asset kinds or release descriptions change.

Its Vulkan section now records:
- the high-integrity loader rule;
- RenderDoc's pinned archive and folder, and how to run it unattended.

The native target commands were already there. `THIRD_PARTY_LICENSES/renderdoc.md` records
RenderDoc as a build-time tool, never distributed: its archive's hash, its signed binaries, its MIT
licence and the libraries its package bundles.

**Evidence.** On the Mac, the bar passed with **1,394 of 1,395** headless tests, the Windows-only
test skipped. `vulkan-check` and `check -Drhi=vulkan` passed for both targets, and both releases
staged. On the Arc, over SSH with the overlay's layer disabled, the whole Vulkan graph passed as
above. In the desktop session, from the relocated install with only system directories on `PATH`,
the probe, the capture, the pacing runs and the input runs above all exited cleanly.

**Limits of the claim.** Windows x64 is now a runtime claim, for this machine only:
- one Intel GPU and one driver; no AMD or NVIDIA part, and no other Windows build;
- one 60 Hz display at scale 1.00; no high or variable refresh rate, HDR, second monitor or
  display scaling;
- text typed with Latin keys; no IME composition. Synthetic keys carry no auto-repeat, so a held
  key repeating into a field never ran.

A minimised sample still costs about a quarter of this processor's core. A minimised Metal
window's pacing is still unmeasured, because scripting the Mac's minimise needs an Accessibility
permission this terminal lacks. The samples' sleep follows a skipped frame, whichever backend
skipped it; whether Metal skips there at all is the open question.

## Resolution — 2026-09-19, Step 10: the RHI proof closed, and M13 with it

**The gate.** §10's distinct evidence, and where each item was met:
- **Pure tests:** Steps 3–7, in the ordinary graph on every host.
- **Offscreen Vulkan tests:** Step 4's bytes and Step 6's pixel probes, read back through the
  backend-private copy.
- **Null reference tests:** the bar below. M12's determinism and job tests are unchanged.
- **The native Windows graph:** 1,427 of 1,437 tests, with validation and synchronization
  validation required.
  - Ten skipped, all named: five POSIX-only, and five that reach every step of an upload only
    through the validation backend's CPU-side buffers.
  - Last run in Step 9 with the overlay's layer removed, on a tree whose code differs from this
    commit only in comment wording and the macOS-only release descriptions.
  - Driver diagnostics reach `core.log` (Step 3). The messenger's callback formats each message
    into its log line before returning and keeps no pointer to it.
- **Windowed sandbox and room runs:**
  - Step 8: resize, minimise and restore, 29 texture reloads over 900 frames with two in flight,
    a clean exit and no validation error.
  - Step 9: pacing and real input.
- **The RenderDoc capture:** Step 9.
- **The relocated runtime tree, with a user package:** Steps 8 and 9.

That evidence is unchanged, so no native run was repeated. At closure on the Mac:
- the bar passed with **1,394 of 1,395** tests, the Windows-only test skipped;
- `zig build test -Dplatform=null -Drhi=null` passed 1,382 of 1,383;
- the Metal-selected graph passed 1,399 of 1,405, skipping the Windows-only test and the same
  five validation-backend tests;
- `vulkan-check` and `check -Drhi=vulkan` compiled for both targets;
- both releases staged, their notices naming only distributed dependencies.

M13 closes at **1,405 declared / 1,395 headless tests**, ten Metal-only. The Vulkan-selected
graph declares 1,437.

**The RHI's rules survived.** None was relaxed. Three were tightened before Step 4, each written
into `rhi.md` under ADR-0037's decision 7 before its code:
- every resource declares a usage;
- copy sources are bounded;
- binding alignment and range are capabilities.

The one extension is ADR-0037's: an out-of-date swapchain is rebuilt between frames without a
resize event (`rhi.md` §7). The faults M13 found were the backend's own or older than it:
- Step 3's alignment-checked handle cast;
- Step 5's inverted front face;
- Step 7's leak count;
- `std`'s mislabelled Windows file handle and POSIX-only test fixtures;
- the elevated loader;
- Step 8's release regression;
- the unpaced minimised loop.

None changed the contract. Validation was not weakened: the backend's tests still require the
Khronos layer with synchronization validation, and fail rather than skip without it.

**Discrepancies, resolved in their originating records:**
- **Device and surface recovery, and backend replacement.** ADR-0035 and `hardening.md` handed
  them to M13, but §8 and §12 here left them unimplemented. Each record now has a dated note:
  loss stays sticky on every backend. `rhi.md`'s open question 6 is annotated and stays open, by
  standing instruction.
- **Pacing.** It was written down only in the samples' comments. `app-and-frame-loop.md` §2 now
  records that it is the game's, and `rhi.md` §7 points there.
- **The backends.** `rhi.md` still called Vulkan unbuilt, and `platform-interface.md`'s status
  predated M13's additions; both are corrected.
- **ADR-0008.** Its revisit condition had arrived, so it gains a note. `CLAUDE.md`'s platform row
  had called Windows build-checked only.
- **Multi-threaded recording.** `jobs-and-threading.md` §9 named M13's backend as a possible
  trigger for it. Recording was measured at a 0.04 ms median in the sandbox and 0.04–0.06 ms in
  the room, so the trigger did not fire. ADR-0036's matching revisit condition likewise did not
  arrive.
- **Statuses.** ADR-0033, ADR-0037 and ADR-0038 now say they were implemented.

**Deferred items.** Removed only what M13 proved:
- the second backend, in `CLAUDE.md` §9;
- M10's window icon, marked built at Step 8.

Still deferred, each where it was already recorded:
- Linux x64, as M18;
- device recovery;
- IME composition, gamepads and OS file watching;
- multiple windows and queues;
- the rest of §12.

The limits of the Windows claim are Step 9's.

**Updated:**
- `CLAUDE.md` §§4.1, 4.3, 4.4, 4.5 and 9;
- AGENTS.md, PROJECT_STATE, the roadmap, README and the design index;
- `rhi.md`, `platform-interface.md`, `app-and-frame-loop.md`, `jobs-and-threading.md` and
  `hardening.md`;
- ADRs 0008, 0033, 0035, 0037 and 0038.

M13 is complete and tagged `m13`. M14 has not been started.

> **M14 Step 9, 2026-09-19: the first optimized Windows build.** M13 built Debug on Windows only.
> With any other `-Doptimize`, Zig defines `_FORTIFY_SOURCE`, and Zig 0.16.0 cannot translate
> the fortified string wrappers MinGW's headers then declare. `vk.zig` and the SDL3 backend
> therefore `@cUndef("_FORTIFY_SOURCE")` before their includes. A ReleaseSafe room then ran
> M14's exit proof on this backend. `zig build check -Drhi=vulkan -Dtarget=x86_64-windows-gnu
> -Doptimize=ReleaseSafe` keeps it building (AGENTS.md). See `mod-management.md`, Step 9's
> Windows Resolution.
