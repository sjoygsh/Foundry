# Design: `rhi` — the render hardware interface

**Status:** Implemented as `engine/src/rhi/`. Interface and validation backend
2026-09-03; **Metal backend 2026-09-04**, which added §9's binding index convention. 85
tests, 55 of them in the validation backend, plus 8 more against a real GPU when Metal is
the selected backend.
**Date:** 2026-09-03, revised 2026-09-04
**Implements:** I1, I7, I8 · **Informed by:** ADR-0003, ADR-0012, ADR-0015, ADR-0007

`rhi` is layer L2. It depends on `core` and `platform`. **Graphics API symbols appear
nowhere outside it** (I7, enforced by the build graph).

This is the document ADR-0003 demands before any Metal code exists, and it is written
under an explicit warning from that ADR:

> **An abstraction validated against a single API is not validated.** Metal is the most
> forgiving of the three, so an RHI shaped by Metal alone will be one that Vulkan and
> D3D12 cannot implement efficiently.

Every decision below is therefore made by asking **what the strictest API requires**, not
what the first backend needs. Where Metal is more permissive, the interface keeps the
stricter contract and the Metal backend ignores it. Where Metal is *stricter* — and it is,
in one important place — the strictness is kept, because designing to the loosest of three
constraints is how you discover the other two at the worst possible moment.

---

## 1. What this is, and what it is not

`rhi` is **engine-internal**. Games and mods never see it (ADR-0003). There are two
boundaries and conflating them is the most likely way to get this wrong:

| Boundary | Audience | Exposed to games and mods |
| --- | --- | --- |
| Renderer API (`render2d`, later `render3d`) — sprites, cameras, materials, text | Games, tools, eventually mods | **Yes** |
| RHI (`rhi`) — devices, command buffers, pipelines, GPU resources | Engine internals only | **No** |

So `rhi` has no opinion about sprites, materials, cameras, scenes or content. It does not
load anything, does not know what a content ID is, and does not decide when to draw. It
knows how to make GPU objects and record commands, and nothing else.

Consequence worth stating because it constrains M7: **since the RHI is not public, no mod
can issue draw calls directly.** Mod-authored rendering goes through the renderer API, and
mod-authored *shaders* (ADR-0015) go through the material system. That is a deliberate
narrowing — the RHI is the wrong stability contract to offer anyone.

## 2. Concept mapping

The table ADR-0003 requires, filled in. Its purpose is not documentation: it is the
evidence that each concept in the interface has a real, efficient implementation in all
three APIs, rather than being a Metal idea with a hopeful name.

| Foundry RHI | Metal | Vulkan | D3D12 |
| --- | --- | --- | --- |
| `Device` | `MTLDevice` | `VkPhysicalDevice` + `VkDevice` | `ID3D12Device` |
| Queue (one, graphics) | `MTLCommandQueue` | `VkQueue` from the graphics family | `ID3D12CommandQueue` |
| `Surface` / swapchain | `CAMetalLayer` + `CAMetalDrawable` | `VkSurfaceKHR` + `VkSwapchainKHR` | `IDXGISwapChain3` |
| `CommandBuffer` | `MTLCommandBuffer` | `VkCommandBuffer` + pool | `ID3D12GraphicsCommandList` + allocator |
| `RenderPass` (scope) | `MTLRenderCommandEncoder` | dynamic rendering scope | `OMSetRenderTargets` region |
| `Buffer` | `MTLBuffer` | `VkBuffer` + bound memory | `ID3D12Resource` (buffer) |
| `Texture` | `MTLTexture` | `VkImage` + `VkImageView` + memory | `ID3D12Resource` + descriptors |
| `Sampler` | `MTLSamplerState` | `VkSampler` | sampler descriptor |
| `ShaderModule` | `MTLLibrary` → `MTLFunction` | `VkShaderModule` (SPIR-V) | DXIL blob |
| `PipelineLayout` | *implicit* | `VkPipelineLayout` + set layouts | `ID3D12RootSignature` |
| `RenderPipeline` | `MTLRenderPipelineState` + `MTLDepthStencilState` | `VkPipeline` | `ID3D12PipelineState` |
| `BindGroup` | argument buffer, or direct binds | `VkDescriptorSet` | descriptor table range |
| Inline constants | `setVertexBytes:` | push constants | root constants |
| Frame completion | `addCompletedHandler:` / `MTLSharedEvent` | `VkFence` / timeline semaphore | `ID3D12Fence` |
| Resource state | *tracked automatically* | image layout + barriers | resource states + barriers |
| Memory intent | `MTLStorageMode` | memory property flags | heap type |
| Load / store actions | `MTLLoadAction` / `MTLStoreAction` | `loadOp` / `storeOp` | render pass access flags |

Two rows deserve emphasis, because they are where the three APIs genuinely disagree rather
than merely spelling things differently:

* **Resource state** is *automatic* in Metal and *mandatory and explicit* everywhere else.
  This is the single largest trap in Metal-first, and §6 is entirely about it.
* **`PipelineLayout` is implicit in Metal.** Metal will happily let a shader bind whatever
  it likes at whatever index. Vulkan and D3D12 require the layout to be declared up front
  and to match exactly. §9 keeps the explicit version.

## 3. Objects are handles

Every RHI object is a generational handle (I1): `Handle(Buffer)`, `Handle(Texture)`,
`Handle(RenderPipeline)` and so on. No raw GPU pointer crosses out of `rhi`, nothing above
it stores a backend object, and a destroyed resource's handle resolves to nothing rather
than to whatever took its slot.

This is not ceremony. Resource lifetime against a GPU is genuinely hard — the CPU is
typically two frames ahead of the GPU — and a stale handle that reports itself stale is the
difference between a diagnosable error and a corrupted command buffer.

**Destruction is deferred.** `destroy(handle)` marks the resource dead immediately for
callers, and the backend releases it only once every frame that could reference it has
completed (§7). Destroying a resource the GPU is still reading is undefined behaviour in
all three APIs and is *unobservable* in testing right up until it is a crash on someone
else's machine.

## 4. Device, surface, and what is discoverable

`Device.init` takes an allocator and a `platform.NativeSurfaceHandle` — the opaque tagged
pointer `platform` produces (`platform-interface.md` §3). The backend interprets the tag;
`platform` never learns what Metal is, and `rhi` never learns what SDL is.

A backend that meets a surface `kind` it cannot use returns an error rather than asserting.
Asking a Metal backend for an Xlib window is a configuration mistake, not a programmer
error.

**Capabilities are queried, never assumed.** `Device.capabilities()` reports the limits the
engine actually branches on — maximum texture dimension, maximum bind groups, inline
constant size, whether the memory is unified. Foundry targets the *guaranteed minimums*
(§9); capabilities exist so a backend can report something better, not so callers can
discover something worse than they designed for.

`capabilities().unified_memory` is deliberately **not** a licence to skip staging (§5). It
exists so that a backend can take a shortcut internally, and so profiling can explain a
difference between machines.

## 5. Memory: intent, not mechanism

Resources declare **what they are for**, not where they live:

| Intent | Meaning | Metal | Vulkan | D3D12 |
| --- | --- | --- | --- | --- |
| `device_local` | GPU reads and writes it constantly. **Never CPU-mappable.** | `.private` | `DEVICE_LOCAL` | `DEFAULT` heap |
| `upload` | CPU writes, GPU reads once, usually a staging source. | `.shared` | `HOST_VISIBLE \| HOST_COHERENT` | `UPLOAD` heap |
| `readback` | GPU writes, CPU reads. Rare; screenshots and queries. | `.shared` | `HOST_VISIBLE \| HOST_CACHED` | `READBACK` heap |

**The rule that matters: a `device_local` resource cannot be mapped.** Getting data into
one means writing an `upload` buffer and recording an explicit copy. On Apple Silicon the
Metal backend *could* skip that — the memory really is unified — and it deliberately does
not offer callers the option.

This is the "never assume writes are free" line in ADR-0003 turned into an enforceable
rule. An engine tuned only on unified memory quietly develops a habit of writing straight
into vertex buffers every frame, and then runs at a fraction of its speed on a discrete GPU
where that write crosses PCIe. The cost of the discipline is one copy on a machine that did
not need it; the cost of skipping it is discovered on hardware you do not own.

## 6. Resource state, and the trap Metal sets

Metal tracks hazards automatically. Vulkan and D3D12 require every transition to be stated,
and get it catastrophically wrong — garbage pixels, or a hang — when it is missed.

**The RHI declares state transitions explicitly. The Metal backend discards them. The
validation backend checks them.** That combination is what keeps the interface honest while
only one real backend exists.

States are the small set the engine actually uses:

`undefined` · `render_target` · `depth_stencil` · `shader_read` · `copy_src` · `copy_dst` ·
`present`

**Transitions are declared at pass boundaries, never per draw.** A render pass says what
state each attachment arrives in and what state it leaves in; a standalone `barrier`
command covers the gaps between passes — the usual case being a texture a pass rendered
into that the next pass samples. Per-draw transitions were rejected: they are the shape
that makes Vulkan slow, because each one is a pipeline barrier that breaks overlap, and
batching them at boundaries is what every real renderer ends up doing anyway.

`undefined` is a real state and means *the contents are not worth preserving*. Transitioning
**from** `undefined` is free everywhere and is the correct way to begin a frame with a
render target you are about to clear. Transitioning **to** `undefined` is not a thing.

## 7. The frame, and frames in flight

The CPU runs ahead of the GPU. How far ahead is a decision, and leaving it implicit is how
an engine ends up either stuttering or writing over memory the GPU is reading.

**The RHI owns a ring of `frames_in_flight` frames, default 2.**

```
device.beginFrame()   // blocks until the frame N-2 slot has completed on the GPU
  ...record...
device.endFrame()     // submits, presents
```

`beginFrame` returns a `FrameContext` carrying the swapchain texture for this frame and the
frame slot index. Anything written per-frame — upload buffers, bind groups — is indexed by
that slot, so writing to slot `i` is safe precisely because `beginFrame` waited for the
previous use of slot `i` to finish.

This is the piece Metal's conveniences hide most thoroughly: `MTLCommandBuffer` completion
handlers make it easy to never think about it, and Vulkan makes it impossible not to. The
RHI takes Vulkan's shape.

**Swapchain resize is explicit.** `platform` reports a `window_resized` event carrying the
new pixel size; the caller calls `device.resizeSurface(pixel_size)`, which recreates what
must be recreated. It is not detected implicitly inside `beginFrame`, because a resize
invalidates textures the caller may be holding handles to, and that is a fact the caller
must be told rather than have happen underneath it.

## 8. Recording commands

Metal is the **strictest** of the three here, and the RHI keeps its shape.

In Metal you cannot record a draw outside a `MTLRenderCommandEncoder`, and you cannot have
two encoders open at once. Vulkan and D3D12 both permit sloppier structures. Designing to
Metal's model costs the other backends nothing and buys a structure that is trivially valid
everywhere:

```zig
var cmd = try device.beginCommandBuffer();

var pass = try cmd.beginRenderPass(.{
    .color = &.{ .{
        .texture = frame.surface_texture,
        .load = .{ .clear = .{ 0, 0, 0, 1 } },
        .store = .store,
        .initial_state = .undefined,
        .final_state = .present,
    } },
    .depth = null,
});
pass.setPipeline(sprite_pipeline);
pass.setBindGroup(0, per_frame_group);
pass.setVertexBuffer(0, quad_vertices, 0);
pass.setInlineConstants(std.mem.asBytes(&transform));
pass.draw(.{ .vertex_count = 6, .instance_count = batch_len });
pass.end();

try cmd.submit();
```

Load actions are `load`, `clear` or `discard`; store actions are `store` or `discard`.
**`discard` is not a micro-optimisation on a tiler** — on Apple Silicon, and on every mobile
GPU, discarding a depth buffer you do not need to keep saves the entire cost of writing it
back to memory. It is free to express and expensive to retrofit, so it is in the interface
from the first pass.

`resolve` (for MSAA) is a store action that does not exist yet. The enum is shaped to gain
it without changing anything that already uses it.

## 9. Pipelines, layouts, and the binding model

This is the granularity question `PROJECT_STATE.md` recorded as unresolved. The answer is
taken entirely from Vulkan's **guaranteed minimums**, because they are the binding
constraint and the other two APIs are more generous.

**Four bind groups, ordered by update frequency:**

| Group | Frequency | Typical contents |
| --- | --- | --- |
| 0 | per frame | camera, time, global lighting |
| 1 | per pass | pass-specific targets and parameters |
| 2 | per material | textures, samplers, material constants |
| 3 | per draw batch | instance data |

Four, and not more, because **Vulkan only guarantees `maxBoundDescriptorSets >= 4`**. A
five-group design would work on every desktop GPU and fail on hardware we have not tested,
which is precisely the class of mistake Metal-first invites. D3D12 maps groups to descriptor
tables in the root signature; Metal maps them to argument buffers, or to direct binds while
the shader set is small.

Frequency ordering is not decoration either: Vulkan invalidates all descriptor sets from the
first one whose layout changes, so putting the least-frequently-changed data in group 0 is
what makes rebinding cheap. Getting this backwards is invisible in Metal.

**Eight vertex buffers, guaranteed.** The third number in this interface, and the only one
taken from Metal rather than from Vulkan. Metal exposes **31 buffer argument slots per
stage**, shared between vertex buffers, uniform buffers and inline constants; Vulkan
guarantees 16 vertex input bindings and D3D12 offers 32 input slots, so here Metal's shared
table is the binding constraint rather than the most generous case. Reserving eight for
vertex buffers leaves twenty-two for bind group buffers once inline constants have taken
one — more than any renderer Foundry has planned needs. A backend may report more in
`Capabilities`; none may require fewer.

### Inline constants

**128 bytes, guaranteed.** Vulkan guarantees at least 128 bytes of push constants; D3D12's
root signature is 64 DWORDs total and must also hold the descriptor tables; Metal's
`setVertexBytes:` is far more generous. 128 is the number all three can honour, so it is
the number the interface promises.

This facility is **push-constant-style and nothing more**. Its semantics are stated here in
full, because a small untyped byte block is exactly the kind of thing that accretes into an
accidental general-purpose parameter system if its limits are left implicit:

* **It is part of the command stream, not a resource.** There is no handle, no allocation,
  no lifetime to manage, and nothing to destroy.
* **The bytes are copied at the call.** `setInlineConstants` takes a slice and copies it
  immediately; the caller's buffer may be reused or freed the instant the call returns.
* **Update scope is one render pass.** The value is encoder state. It persists until the
  next `setInlineConstants` in the same pass, or until the pass ends — whichever comes
  first. **It does not survive across passes or command buffers**, and there is no way to
  ask what the current value is.
* **Writes are whole-block.** There is no offset, no partial update, no merging with a
  previous value. Each call replaces the block. Vulkan permits ranged updates and D3D12
  permits single-DWORD writes; the RHI offers neither, because a partial-update model is
  the first step towards treating this as storage.
* **Binding a pipeline whose layout differs invalidates the block.** This is Vulkan's real
  behaviour — push constants are pipeline-layout-scoped — and pretending otherwise would
  produce an engine that works on Metal and renders garbage elsewhere. After such a bind,
  the constants must be set again before the next draw.
* **Size is declared by the pipeline layout.** A pipeline layout states how many bytes it
  uses, at most 128. Writing more than the layout declares is an error; writing fewer
  leaves the remainder undefined, and a shader that reads it gets undefined values.

**What it is deliberately not.** It is not a parameter system. It has no names, no types,
no reflection, and no persistence. Anything that wants structure, wants to outlive a pass,
wants to be shared between draws, or exceeds 128 bytes belongs in a uniform buffer reached
through a bind group — which is the mechanism designed for exactly that, and the one that
maps efficiently to all three APIs at any size.

The intended use is a per-draw transform and a couple of scalars: a 4x4 matrix is 64 bytes,
leaving room for a colour and an index or two. If a call site is packing a struct that
approaches 128 bytes, that is the signal it wanted a buffer.

**`PipelineLayout` is an explicit object**, declaring the group layouts and the inline
constant size. Metal does not need it and the Metal backend mostly ignores it; Vulkan and
D3D12 cannot function without it, and creating it up front is what makes a bind group's
compatibility checkable rather than discovered as corruption.

A `RenderPipeline` is monolithic — shaders, vertex layout, blend, depth-stencil, rasterizer
state, attachment formats, and its layout — because all three APIs are monolithic here.
Pipelines are created ahead of time and never mutated.

### Binding indices, and why they are part of the contract

An abstract bind group has to land somewhere concrete. Metal has no descriptor sets: it has
three flat argument tables per shader stage — buffers, textures and samplers — and a shader
names a slot in one of them as `[[buffer(n)]]`, `[[texture(n)]]` or `[[sampler(n)]]`.
Something has to decide which `n`.

That decision is **shader-visible**, which makes it a contract rather than an implementation
detail. A shader is compiled against these indices, and getting them wrong does not fail —
it silently reads the wrong resource. Because shaders are assets with per-backend variants
(ADR-0015) this contract is *per backend*, but it must be written down for each, since
mod-authored shaders will eventually be compiled against it (`CLAUDE.md` §5).

**The Metal backend flattens a pipeline layout deterministically**, in one documented walk
order: bind groups 0 through 3 in ascending order, and within each group its entries in
ascending `binding` value — never the order entries happen to appear in the descriptor. Two
identical layouts therefore always produce identical indices, whoever built them and in
whatever order. That is I9's stable-iteration-order requirement applied somewhere it is easy
to overlook, and it is what lets a shader be compiled once and used with any layout that
matches.

| Metal table | Index | Holds |
| --- | --- | --- |
| buffer | `0 .. 7` | RHI vertex buffer slots 0–7. Vertex stage only. |
| buffer | `8` | Inline constants. Both stages. |
| buffer | `9 +` | Uniform and storage buffer bindings, in walk order. |
| texture | `0 +` | Sampled texture bindings, in walk order. |
| sampler | `0 +` | Sampler bindings, in walk order. |

**An index is allocated per binding, not per stage.** A binding visible to both stages gets
one index and is bound at that index in each stage that declares it, so the same binding is
never `[[buffer(9)]]` in the vertex shader and `[[buffer(3)]]` in the fragment shader. This
wastes a slot in a stage that cannot see the binding, and the waste is worth it: the
alternative makes an index depend on which stages a binding is visible to, which is the kind
of rule an author gets wrong once and then debugs for an afternoon.

The vertex-buffer block is reserved at a fixed eight rather than sized per pipeline for the
same reason. A vertex buffer's index does not move when some bind group gains a binding, so
`[[buffer(0)]]` in a vertex shader means RHI vertex slot 0 in every pipeline in the engine.

Vulkan and D3D12 will each need their own written convention when they arrive. Neither is
obliged to match this one — they have descriptor sets and root signatures and can express
groups directly — but each owes the same explicitness, and §2's mapping table is where that
belongs.

## 10. Shaders

Per ADR-0015, shaders are **assets with per-backend variants**. That decision lands here as
a deliberately narrow interface: `createShaderModule(bytes)`, where `bytes` are whatever the
selected backend understands — a `.metallib`, or SPIR-V, or DXIL.

`rhi` does not know what a content ID is, does not read files, and does not compile
anything. Selecting the right variant for the running backend is `render2d`'s job (L3),
which depends on both `rhi` and `asset` and is the correct place for the two to meet.

Runtime compilation for hot reload (ADR-0015) is a backend capability, exposed as
`createShaderModuleFromSource(source)` that a backend may report as unsupported. The Metal
backend supports it; the null backend accepts anything; a future SPIR-V backend would not
without a compiler. It is on the interface now because it is the same mechanism
mod-authored shaders will need at M7, and finding out then that the interface cannot express
it would be expensive.

## 11. The validation backend

The null backend is **not throwaway scaffolding**. It is the substitute for the second
backend Foundry does not have, and it earns its place by enforcing every rule Metal
forgives:

1. **Resource state.** Every texture's state is tracked. Sampling a texture that is in
   `render_target` state, or beginning a pass whose declared `initial_state` does not match
   reality, is an error.
2. **`device_local` is never mapped.** Attempting it is an error, not a slow path.
3. **Frame ring discipline.** Writing to a per-frame resource whose slot has not completed
   is an error.
4. **Bind group compatibility.** A bind group must have been created with the layout the
   bound pipeline declares.
5. **Complete bindings.** A draw with a group the pipeline's layout requires but nothing
   bound to it is an error, and so is a draw whose layout declares inline constants that
   have not been set — including the case where binding a pipeline with a different layout
   invalidated them (§9). Metal frequently renders all of these correctly by accident.
6. **Vertex layout match.** Bound vertex buffers must match the pipeline's declared layout.
7. **Attachment format match.** A pass's attachment formats must match the pipeline's.
8. **Encoder discipline.** One pass open at a time; every pass ended; every command buffer
   ended before submission.
9. **Lifetime.** No resource destroyed while a frame that references it is in flight.
10. **Limits.** At most 4 bind groups and at most 8 vertex buffers. Inline constants at
    most 128 bytes, and never more than the bound pipeline's layout declares.

Rules 1, 3, 5 and 9 are the ones that would otherwise be discovered by a second backend
producing garbage, months later, with no obvious cause. Rules 2 and 6 are the ones that
would be discovered as *performance* problems on hardware nobody here owns.

**The list is exhaustive, and deliberately so.** The validation backend enforces the RHI's
documented contract and nothing beyond it. It is not a style checker and it does not hold
opinions the abstraction does not state: a call that this document permits must not be
rejected, however unwise it looks. Tightening a rule means changing the contract here
first, because a validation backend that enforces more than the interface promises makes
the interface a fiction and turns the Metal backend into the real specification — which is
the exact failure ADR-0003 is trying to avoid.

The validation backend also draws nothing, which makes rendering-adjacent code testable
headlessly — the same reason the null *platform* backend exists.

## 12. Deliberately not here

* **Compute.** Arrives with 3D (ROADMAP Phase 4). `ComputePass` is a natural sibling of
  `RenderPass` and nothing above forecloses it; designing it now would be guessing.
* **Multiple queues.** One graphics queue. Async compute and transfer queues are a real
  Vulkan/D3D12 win and a genuine complication; they arrive with a reason, not before.
* **MSAA.** Store actions are shaped to gain `resolve`.
* **Mipmap generation, texture arrays, cubemaps, 3D textures.** 3D-phase concerns.
* **Bindless.** All three APIs support it now, and it is the likely future of the binding
  model. It is not the model to *start* with while the strict version is what teaches the
  correct habits.
* **A render graph.** Automatic pass ordering and barrier inference sits *above* the RHI,
  not inside it, and is worth building only when there are enough passes to justify it.

## 13. Open questions

1. **Whether bind groups should be transient or persistent.** Vulkan descriptor sets are
   usually pooled per frame and thrown away; Metal argument buffers are cheap to keep. The
   interface currently creates them as persistent objects, which is the shape that works in
   both. Revisit when the material system exists and the actual churn is measurable.
2. **How much the validation backend should model timing.** It can catch ordering and
   lifetime errors exactly, but not "this is slow on discrete hardware". A cost model that
   counted staging copies would catch the memory habits §5 warns about — worth considering
   once there is real traffic to measure.
3. **Whether `frames_in_flight` should adapt.** Fixed at 2 is right for latency; 3 tolerates
   frame-time spikes better. This becomes answerable when there is a frame long enough to
   spike.
4. **Whether usage-flag conformance should be enforced.** Surfaced by implementation, and
   deliberately left open. Buffers and textures declare a usage set at creation because
   Vulkan and D3D12 require it, and both treat using a resource outside its declared usage
   as undefined behaviour — so it is a genuine invariant of the abstraction. It is *not*
   one of the ten rules in §11, and the validation backend therefore does not check it.
   Enforcing it would be an eleventh rule, which is a contract change and belongs here
   before it appears in code. Recorded rather than resolved, because implementation did
   not force the decision: everything else works without it.
5. **What happens on device loss.** Real on Windows, rare on macOS, and untestable until
   there is a second backend. Recorded so that it is a known gap rather than an oversight —
   the handle model at least makes recovery expressible, since every resource is already
   addressed indirectly.
