# ADR-0029: Scripts consume the public ABI and reload behind stable callbacks

**Status:** Accepted (public source boundary and bounded bindings implemented through M8 step 4)
**Date:** 2026-09-09

## Context

M7's `FoundryApi_v1` has 135 calls. It can register a system but cannot unregister it;
`abi.HostOf` and the world retain callback contexts. Its asset API can acquire an asset
but cannot read a script's source. An implementation that imports `scene` or peeks into
asset payloads from the scripting host would bypass I4 precisely where it first matters.

Native refusal neutralizes callbacks but leaves registration metadata reserved. Repeating
that lifecycle on every text edit would consume finite system slots and is not hot reload.
The code evidence is `engine/src/abi/host.zig`, `calls_scene.zig`, `api.zig`, and
`engine/src/asset/registry.zig` at M7 commit `7744353`.

## Decision

**1. `script` consumes the installed-header contract, not engine modules.** Its build
dependencies are `core` and a header-only C import of `foundry.h`, plus the pinned Lua
library. It sits at the consumer level, L6. It receives `FoundryGetApi`, issued mod handles
and resolved package descriptors from the application. No `app`, `scene`, `asset`, `data`,
`platform`, `abi` implementation module or `rhi` import. Header access grants declarations,
not implementation imports. Nothing below it depends on it.

**2. Source is an asset identified by content ID.** Add the runtime-registered
`foundry:script` asset schema and a bounded source loader, and publish one typed copy call
through a new `FoundryApi_v2`. V1 remains frozen and available. Native consumers and tools
can read exactly the same source through v2. The source loader does not execute code.
The manifest names one script entry ID and its binding version; it never names an OS path.

**3. Each script package owns one stable system registration for the world lifetime.**
The callback is compiled Foundry code with a stable slot as its context. The slot points to
the current VM, or to nothing after failure/shutdown. Reload swaps this pointer at a safe
boundary; it never registers another system or invalidates/reissues the package identity.
This is scripting bookkeeping permitted by ADR-0026, not a new scheduler or native unload.

**4. Reload prepares a new VM without mutating the world.** Copy explicit state through a
bounded, validated value representation; initialize or migrate it in the candidate; validate
the result; then swap at a boundary outside callbacks and world iteration. Failure destroys
only the candidate. No promise of rolling back arbitrary changes made by an active update.

**5. M8 publishes fixed-tick behavior, not all 135 calls as Lua functions.** Bind content
inspection, world inspection, individual template spawning and script-owned entity removal.
The exact allowlist and limits are in [scripting.md](../design/scripting.md). A wrapper is
syntax and validation over the shared table, never a second implementation of a capability.
Rendering, arbitrary component bytes, new component serializers and native reload are not
required to prove scripted gameplay and remain outside this milestone.

## Consequences

Reload neither moves callback contexts nor consumes new system/mod slots. Script errors
cannot leave a world callback pointing into a freed VM. The host must retain inert slots
until the world is gone, just as it retains ABI callback storage today.

The additive ABI version is a real cost, justified by a capability v1 cannot express.
There is no private asset read and no broad file-read API. The script source loader belongs
below `app`; Lua remains optional and absent from a content-only tool's dependencies.

The first script surface can create gameplay using host-registered content templates, but
cannot write arbitrary native component layouts. That limitation is visible and testable;
expanding it requires a public ABI design, not a script-only shortcut.

## Alternatives considered

* **Put Lua in `app` or `abi`.** Makes an optional runtime part of a lower layer and obscures
  whether bindings use the table. Rejected in favor of a consumer with no private imports.
* **Read source through host-injected payload pointers.** Avoids v2 but gives this consumer
  an asset-read route native consumers cannot use. Rejected by I4.
* **Reuse v1 reserved space or change its layout.** There is no reserved extension contract;
  v1 is frozen. V2 is what the original version-query design was built to support.
* **Unregister/re-register systems on every edit.** Requires world lifecycle changes and
  would perturb registration order. Stable dispatch achieves M8 without either change.
* **Patch functions in a live VM.** Retains obsolete closures/upvalues and makes a failed
  reload partly effective. Candidate replacement gives failure an unambiguous meaning.
* **Transactional engine command buffer.** Could roll back some mutations, but would need
  to cover all subsystems and their failure modes. Side-effect-free preparation is sufficient.

## Revisit if

Scripts need multiple independently scheduled systems, component definitions that survive
saves, resumable coroutines, rendering callbacks, or live package enable/disable. A real
consumer requiring any of these supplies the reason for the next ABI/lifecycle design.

## Implementation note — 2026-09-10

Step 2 implements decision 2 up to, but not including, its public ABI addition. The
`foundry:script` asset is copied, text-validated, bounded before read and revisioned; package
reads traverse opened directory handles without following package-selected symlinks. Fpack
derives the required `language "lua-5.5"`, and manifest v2 carries entry/binding metadata
through resolution while schema-v1 packages remain readable. The native loader refuses a
package carrying both code tiers before opening an image. `FoundryApi_v2`, bindings, stable
callbacks and reload remain later steps.

## Implementation note — 2026-09-10, step 3

`FoundryApi_v2` now exists beside the byte-for-byte unchanged v1 declaration. It is a separate
flat table with the same 135 common calls in the same relative order and one appended
`script_source_copy` call. The host supplies the exact registered source-loader identity;
schema agreement alone cannot authorize an opaque payload. A header-only C consumer exercises
query, asset acquisition, sizing, copy, revision and balanced release without engine types.

The agreement checks both table layouts, every common signature and the new signature on all
build targets. Deliberately narrowing the header's capacity parameter and independently
swapping two same-typed Zig table entries both failed the harness before being restored. V1-only
native code still negotiates and runs, while native range selection now offers both versions.
Lua gameplay bindings, stable callbacks and reload remain later steps.

## Implementation note — 2026-09-12, step 4

Decision 5 is implemented: the Lua module publishes 39 functions, every one a wrapper over a
single existing table entry, and the public ABI gained nothing. `script` still imports no
engine module — it takes a `FoundryGetApi`, asks for version 2, and checks the table's version
and size before using it, so a host offering only v1 is refused before a VM exists.

Decision 3's per-package bookkeeping arrived earlier than its slot: §11 places the entity
ownership ledger in the stable manager slot, which is step 5's. The ledger, and the memory
budget shared across VMs, are therefore caller-owned structs the VM is handed by pointer. That
keeps the property decision 4 depends on — a VM can be replaced without the package forgetting
what it owns — without building the slot before its step. Stable callbacks, activation and
candidate-VM reload remain steps 5 and 6.
