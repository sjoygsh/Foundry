# ADR-0028: Restricted Lua for Tier 2 scripting

**Status:** Accepted (runtime boundary implemented in M8 step 1)
**Date:** 2026-09-09

## Context

M8 owes editable gameplay scripts, resource limits, hot reload and useful errors. M7 already
provides the public C ABI; choosing a language must not create a second engine interface.
The intended author edits text, rather than building a native library. Zig 0.16.0 and the
Zig-only build remain fixed. The user commissioned M8's architecture and plan, not its code.

License checks came first: [Lua](https://www.lua.org/license.html) and
[Luau](https://github.com/luau-lang/luau/blob/master/LICENSE.txt) are MIT;
[Wasmtime](https://github.com/bytecodealliance/wasmtime/blob/main/LICENSE) uses Apache-2.0
with the LLVM exception. These checks remove licensing as the deciding factor; they do not
add any dependency to Foundry.

## Decision

Use **PUC Lua 5.5.1**, interpreted, with one isolated state per enabled script package.
Foundry defines a restricted standard environment and versioned language binding. It does
not expose an FFI, arbitrary bytecode, operating-system facilities or engine pointers.
The complete contract is [scripting.md](../design/scripting.md).

The [official release index](https://www.lua.org/ftp/) lists `lua-5.5.1.tar.gz`, SHA256
`1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce`.
The [upstream bug record](https://www.lua.org/bugs.html#5.4.9) identifies 5.4.9 as the last
5.4 release. Select 5.5.1 rather than starting a new host on that closed release series.
Step 1 must verify the archive, record Zig's package hash, build the library directly with
Zig, and commit its full license entry with the dependency. No system Lua or extra build tool.

Lua supplies allocator callbacks, instruction hooks and protected calls. Those are mechanisms,
not a finished sandbox: Foundry must bound native binding work, prevent scripts catching a
resource-limit abort, and contain Lua's nonlocal error exits inside C frames. The
[Lua 5.5 manual](https://www.lua.org/manual/5.5/manual.html) specifies these embedding facilities.
Step 1 is an explicit feasibility gate for their safe use with Zig, not a declaration that
they have already been tested here.

The operational requirement “cannot crash the host” means malformed source, script errors,
recursion, allocation failure and runaway execution are handled as script failures. It is
not a proof that a C runtime, compiler or engine has no undiscovered memory-safety defects.
Native mods retain their separate, explicitly unsandboxed trust tier.

## Consequences

Authors can edit ordinary text without a compiler installation. Each package pays for its
own VM and its own quota; a replacement temporarily needs a second VM. The restricted
environment is smaller than desktop Lua, and its omissions must be documented prominently.

Lua headers and error handling stay inside the scripting implementation. The C bridge is
real maintenance work, but it keeps a longjmp from bypassing Zig cleanup. There is no JIT,
Lua plugin ecosystem, native module loader or third-party Zig binding to audit alongside it.

Simulation runs only at fixed ticks. Reload replaces code and explicitly migrated state;
it does not preserve stacks, closures or arbitrary globals. This is a cost to authors and
a lifetime rule that can be tested.

## Alternatives considered

* **Luau.** A serious alternative with an explicit sandbox design and interrupt support
  ([upstream architecture](https://luau.org/sandbox/)). It would still require Foundry's
  quotas, marshalling and reload lifecycle. For this first host, choose the smaller C
  embedding/build boundary and Lua's integer model over a C++ compiler/VM integration and
  dialect-specific tooling. Reopen if the restricted Lua runtime fails the step-1 gate;
  do not claim Lua is intrinsically safer than Luau.
* **WebAssembly.** A useful future language-neutral execution target, but M8's author would
  need a compilation workflow and Foundry would need a runtime plus memory/import bindings.
  The current requirement is editable scripts, not multiple compiled languages. This is a
  workflow/scope decision, not a claim that WASM cannot reload or sandbox.
* **LuaJIT.** Native code generation and a different runtime/language baseline add work
  without a measured performance need. No JIT or FFI is needed for the exit criterion.
* **Own language/VM.** A compiler and security boundary would become the milestone. Rejected.
* **One shared VM with separate environments.** Lower memory use, weaker allocation and
  failure isolation. Per-package memory accounting is worth separate states.

## Revisit if

The pinned runtime cannot contain errors and enforce the documented limits on the supported
targets; maintained upstream fixes require a deliberate pin update; measured gameplay cannot
meet its budget without another runtime; or real authors need compiled multi-language mods.
Do not substitute a runtime during implementation without recording the revised decision.

## Implementation note — 2026-09-10

Step 1 passed its feasibility gate with Lua 5.5.1 unchanged: host, Linux and Windows builds;
protected syntax/runtime/recursion/instruction failures; exhaustive early allocation refusal;
a real heap-quota exhaustion and recovery; and stable diagnostics for non-string errors. The
bridge uses Lua's public API only. Script assets and manifest metadata arrived in step 2
without importing this runtime; public ABI bindings and package/reload lifecycle remain
unimplemented, so this evidence accepts the runtime boundary rather than claiming M8's full
sandbox contract is complete.
