# Design: M13 — Vulkan, and the second test of the RHI

**Status:** Design proposal complete; **0 of 10 steps implemented**. Stop before Step 1.
**Date:** 2026-09-14
**Baseline:** `f14caac` / `m12`; M0–M12 complete, 1,370 declared / 1,360 headless tests.
**Decisions:** ADR-0033 selects Vulkan; proposed [ADR-0037](../adr/0037-vulkan-execution-and-presentation.md)
and [ADR-0038](../adr/0038-vulkan-shaders-and-toolchain.md) specify execution and tooling.

## 1. Purpose and boundary

The owner requested M13's design after M12, activating the recorded trigger of validating
Foundry's abstraction against a second API. The result is the existing samples on Windows x64
and Linux x64, through the existing renderer and ordinary packages. Metal remains macOS's
backend. There is no MoltenVK path, D3D12 backend, new renderer, material system or public ABI
version in this milestone. M12's workers never call the RHI; all graphics calls remain on
the caller thread.

This is a design-only handoff. The two proposed ADRs, especially their hardware floor, need
acceptance before Step 1. Tool versions and target-machine availability are explicit Step 1
inputs, not guessed facts. No dependency, tool installation or backend code lands here.

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

The Mac's Vulkan tools are not currently on PATH; no remote Vulkan environment was supplied
or accessed for this plan. Installing an SDK does not create a native Vulkan driver on macOS.
An ARM guest or x64 emulation on this Mac does not by itself establish the x64 target claim.
An ordinary desktop VM may expose no Vulkan device at all. Qualify with `vulkaninfo`, feature
reports and a windowed SDK sample instead of inferring support from an OS name. A remote
desktop must use the same adapter/window session being reported.

Before backend implementation, Step 1 must demonstrate at least one usable x64 target and
record an available, specific route to the other OS. Closing M13 requires both, including
Linux X11 and Wayland. Software rendering is useful supplementary evidence; at least one
windowed exit run must use a hardware Vulkan driver. Record any untested discrete-memory
path explicitly; no performance or universal hardware-support claim follows from one GPU.

The proposed windowed floor is Vulkan 1.3 plus dynamic rendering, synchronization2, timeline
semaphores, a shared graphics/present queue family, swapchain support and maintenance1
(KHR preferred, EXT accepted with its matching dependencies). Missing support is refusal,
not a fallback to Metal/null. Offscreen tests omit WSI requirements. Exact OS, GPU, driver,
extensions, SDK/tool versions and window system go in each implementation Resolution.

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
SDL driver's creation/configure behavior on both Linux window systems. If SDL requires a
creation flag internally, keep that SDL detail in `platform`; it conveys no Vulkan object
across the seam. Do not force X11 merely because it was the first successful desktop run.

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
Frame slots own acquire synchronization; swapchain images own present-wait semaphores and
maintenance1 presentation fences. Acquire synchronization must be consumed before reuse.
Presentation resources wait for presentation completion, not merely the frame-slot timeline.

`beginFrame` waits for the previous use of its slot, performs pending between-frame rebuilds,
and acquires. Only a successful acquisition opens a frame and advances frame identity. The
first submission using the image consumes its acquire semaphore once; later submissions may
use the same image. `endFrame` submits an ordered final marker/signals present synchronization
after all submitted image work, records the slot's last submission and presents only if
submitted work drew into the image.

If no draw reached the queue, consume any remaining acquire signal with a cleanup submission,
wait for all actual uses to finish, and release the image through maintenance1 without
presenting uninitialized contents. Reserve cleanup bookkeeping before acquiring so an OOM
does not make closing the frame impossible. If submission itself fails, latch device failure
and tear down without waiting on synchronization that was never signaled. Never mark a
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
frames. Wait for old image submissions and maintenance1 presentation fences, then release
views, semaphores and swapchain. Never infer presentation completion from `waitIdle` alone.
On a failed rebuild, retain valid old backing where Vulkan permits it, otherwise remain
suspended or fatal with correct ownership; passing `oldSwapchain` can retire it even when the
new creation fails. Do not advertise transactional rollback that Vulkan does not guarantee.
The renderer cannot reuse old surface handles across rebuilds. Keep format unchanged or fail
with `SurfaceLost`; no silent pipeline mismatch. Fatal resize errors remain latched for the
next render call despite the existing event handler logging them.

Teardown waits for both kinds of completion on a healthy device. A lost device follows the
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
configuration, so it adds nothing to the C mod API in M13. Verify it visibly on Windows/X11;
Wayland may let the compositor choose the app icon and must document that limitation honestly.

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
* Native Windows/Linux Vulkan-selected full test graphs with validation and synchronization
  validation explicitly required; known environment failure is reported, never a passing skip.
  Driver diagnostics pass through `core.log`; callbacks retain no temporary message pointer.
* Each target's bounded windowed sandbox and room runs, resize, minimize/restore, input/UI,
  pacing, texture reload while frames are in flight and clean exit. Use at least 600 frames
  for stable rendering and 20 texture replacements with two frames in flight. Linux exercises
  X11 and Wayland separately. Window controls are manual where automation is unavailable;
  process completion is not proof the window was visually correct.
* One RenderDoc capture opened and inspected on each OS: inspect a real sprite draw, stage
  bindings, constants, vertex data and resulting target. Record capture-tool compatibility
  limitations separately from a passing native Wayland run. No cross-backend bit-exact pixel
  guarantee: compare exact simple probes where defined, tolerances for filtering/raster edges.
* Relocated runtime tree on both OSes with Zig/SDK/compiler absent from PATH, ordinary user
  package override and script lifecycle, no backend-aware game code, no validation errors.

At final closure run the existing Mac bar, Vulkan cross-checks for both targets, and the
remaining distinct native evidence above. Report actual skips, failures and environment
limits. A windowed hardware sample on a second API is essential; ADR-0033 additionally owes
runtime proof for both Windows and Linux. Missing machine evidence leaves M13 incomplete.
M13 ends only when its rules survived or their necessary changes were recorded by ADR.

## 11. Implementation order — ten bounded steps

Every step is **not started**. Stop after each with its Resolution, PROJECT_STATE update,
verification and commit; no automatic chaining. Step 1 begins only after design acceptance.

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
maintenance1 release/fences, offscreen frame targets, resize and sticky errors. Complete
`interface.check` and enable the full `-Drhi=vulkan` build/test graph. Keep missing-feature
refusal explicit. **Exit:** a real window clears/presents, repeatedly resizes/minimizes/restores,
and every injected acquisition/recording/submit/present failure preserves ownership and markers.

### Step 8 — Run both samples and finish the window icon

Wire the sample surface choice and shader variants, finish the application-supplied icon,
and exercise real sprites/text/tilemaps/UI, room play, sandbox scripts and texture reload
with frames in flight. Preserve M12 jobs and deterministic saves. **Exit:** both samples
work on the first qualified platform, outside the source tree, with no runtime SDK/compiler.

### Step 9 — Prove Windows and both Linux window systems

Complete the second OS's native tests and both Linux WSI runs, fix concrete portability
failures, inspect both RenderDoc captures, and prove user packages, input, icons and pacing.
Record actual tested driver/OS/tool versions and software-versus-hardware evidence. Extend
AGENTS.md's bar with reproducible Vulkan compile and native test commands as they now exist.
**Exit:** both target claims are runtime claims; no missing machine is waved through.

### Step 10 — Close the RHI proof and M13

Run §10's remaining integration gate, accepting unchanged successful evidence. Resolve every
M13 contract discrepancy in its originating design/ADR; do not silently weaken validation.
Update `CLAUDE.md` §§4/9, AGENTS.md, PROJECT_STATE, ROADMAP, README, design index, `rhi.md`,
`platform-interface.md`, relevant renderer/frame-loop sections and ADR statuses. Remove only
the deferred items actually proven. Commit, tag `m13`, push and stop before M14. **Exit:**
the two-platform sample evidence and RHI contract agree, with explicit tested limitations.

## 12. What stays open

The proposed Vulkan floor and toolchain need acceptance; actual machine availability and
exact pins are Step 1's entry work. No machine, installed SDK or API compatibility is assumed.
If the floor excludes the intended hardware, revise the unimplemented ADR with evidence.

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
* [Swapchain maintenance1 and its dependencies](https://docs.vulkan.org/refpages/latest/refpages/source/VK_KHR_swapchain_maintenance1.html)
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
