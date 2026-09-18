# ADR-0038: Compile small GLSL variants to SPIR-V at build time

**Status:** Accepted 2026-09-14; implemented in M13, complete 2026-09-19
**Date:** 2026-09-14
**Builds on:** ADR-0014, ADR-0015, ADR-0016, ADR-0019 and ADR-0033

## Context

M13 calls ADR-0015's postponed shader decision due. The actual shader set consists of the
renderer sprite/text pair and the sandbox's original quad pair. Both are small MSL programs.
There is no content shader loader or material system to port. `RenderPipelineDesc` already
has independent vertex/fragment modules and entry-name fields; the old fixed-name paragraph
in `rhi.md` does not describe that implemented interface.

Vulkan accepts SPIR-V. The build currently knows only `xcrun metal`/`metallib`, and Foundry
requires an ADR before adding another build tool. The runtime should not need a shader
compiler or development SDK installed on the player's machine.

## Decision

**Hand-author GLSL 450 variants for the two existing shader pairs.** Keep MSL as the Metal
source and add separate vertex/fragment GLSL source files beside each pair. Compile each
stage to SPIR-V with a pinned host `glslangValidator` from the Vulkan SDK and validate it
with that SDK's `spirv-val`, targeting Vulkan 1.3 explicitly. GLSL uses `main`; the existing
pipeline entry fields select that name. Do not link stages into an invented shader envelope.

The Zig build owns declared source inputs and generated outputs and supplies neutral
vertex/fragment byte imports plus entry metadata to the consuming renderer. No runtime
shader compiler, cross-language compiler, reflection framework or new material format is
introduced. Vulkan's `createShaderModuleFromSource` returns `RuntimeCompilationUnsupported`.
Content-owned shaders still belong to future material assets with backend variants, and that
system must not assume all mod shaders are known when the engine binary is built (ADR-0015).

**The Vulkan SDK is a developer prerequisite, not a new build system.** Step 1 records an
exact SDK release and archive hashes for the hosts used, compiler/validator versions and
licensing, and selects a matching pinned Vulkan-Headers dependency. No `latest` selection is
allowed in the build. Host shader tools can produce Linux/Windows shader bytes from macOS;
target tools must never be executed during a cross-build. Explicit local tool paths are
allowed build inputs, not checked-in machine paths. Null and Metal builds need no Vulkan SDK.
No CMake, Ninja, Make or pkg-config is introduced. No tool is installed by this planning change.

**Use Khronos C headers directly within `rhi`, with `VK_NO_PROTOTYPES`.** Attach their include
path only to that module. Load the OS Vulkan loader at runtime through `platform.Library`,
then resolve global, instance and device dispatch tables at their proper scopes. Do not add
Volk or a generated Zig binding dependency for a function table the backend already needs.
Use `vulkan-1.dll` from the Windows system directory through a confined system-library loading
primitive, not the current-directory DLL search; use the system `libvulkan.so.1` loader on
Linux. Keep its library reference until after the instance and device are destroyed. A
missing loader or required symbol is a reported initialization failure.

`platform` may gain a generic system-library open operation; it contains no Vulkan name or
type. Existing explicit-path native-mod loading keeps its behavior. Vulkan headers and OS
surface declarations never become module imports above `rhi`.

**Validation layers and RenderDoc are development tools.** The explicit Vulkan test mode
requires `VK_LAYER_KHRONOS_validation`, debug-utils reporting and synchronization validation;
absence fails that requested mode. Ordinary runtime neither requires them nor quietly changes
backends. The SDK, compiler, validator, headers and capture tool receive exact provenance and
the applicable license entries when first adopted, following the existing parsed template.
Nothing here asserts that an entire SDK has one license or is shipped with Foundry.

## Consequences

Four small GLSL stage sources duplicate two small MSL pairs, and tests must prove binding,
matrix layout, color space and alpha behavior agree. Build-tool versioning becomes an explicit
maintenance obligation. The Vulkan runtime remains a consumer of precompiled shader bytes
and the platform's driver installation, with no SDK, Zig or Xcode requirement.

Windows/Linux native builds and macOS cross-builds all run a host shader compiler through
Zig. Packaging stays M9's macOS-only path; M13 proves a relocatable development runtime tree
on its new platforms without inventing installers or release automation.

## Alternatives considered

* Slang or HLSL/DXC plus SPIRV-Cross: useful for a growing material system, disproportionate
  for two simple shader pairs and changes the working Metal toolchain unnecessarily.
* Write a shader compiler, SPIR-V emitter or format: a separate compiler project with no
  current consumer justification.
* Commit opaque SPIR-V blobs alone: obscures the source/build agreement; declared generated
  outputs are inspectable and reproducible with the pinned compiler.
* Ship a compiler for runtime GLSL: unnecessary for engine-owned shaders and a larger runtime
  and licensing surface before the material system exists.
* Link the loader as a required application import: makes a missing driver/loader an OS
  launch failure rather than a Foundry diagnostic and adds cross-link inputs without benefit.

## Revisit if

Hand-maintained shader variants diverge repeatedly; shader permutations or material authoring
make duplication expensive; a content shader workflow needs runtime compilation; the pinned
SDK lacks a usable host tool; or direct header imports stop being manageable under pinned Zig.

## Technical references

* [Khronos glslang](https://github.com/KhronosGroup/glslang) documents GLSL-to-SPIR-V generation
  and the standalone tool.
* [SPIRV-Tools](https://github.com/KhronosGroup/SPIRV-Tools) provides `spirv-val`; its version
  and target environment must match the chosen build profile.
* [Vulkan-Headers](https://github.com/KhronosGroup/Vulkan-Headers) supplies the C declarations;
  implementation records the exact revision, hash and license, not this moving URL as a pin.
