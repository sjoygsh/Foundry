# AGENTS.md — working on Foundry

For any coding agent working in this repository. It is an **entry point and an operating
manual**, not a second rulebook.

`CLAUDE.md` is the source of truth for what Foundry is, what it may never do, and how it is
architected. Everything in it binds you. This file exists because it does not tell you how to
build the thing, what breaks in this environment, or where the work currently stands — and an
agent that starts cold needs all three.

**If this file and `CLAUDE.md` ever disagree, `CLAUDE.md` wins, and the disagreement is a bug in
this file.** Fix it rather than following it.

---

## 1. Read these first, in this order

1. **`CLAUDE.md`** — the philosophy, the nine invariants (§3), the architecture (§4), the 16
   development rules (§2) and the non-negotiables (§10). Read all of it. It is not long and it
   is the whole point.
2. **`PROJECT_STATE.md`** — where the work actually stands. It changes every session; the top
   of the file is current. This is the only place that says what is done.
3. **`docs/ROADMAP.md`** — the milestones, if the current one is unclear.
4. **The design document for whatever you are about to build**, in `docs/design/`. Every
   subsystem has one and it was written *before* the code. If you are implementing something,
   its design doc is your specification, and its §-numbered sections are what commit messages
   and comments refer to.
5. **`docs/adr/`** — numbered decision records. Read the ones your work touches. §4.1 of
   `CLAUDE.md` is the index.

**Then inspect the actual code before assuming anything about it**, and summarize your
understanding back to the user before you start. That sequence is `CLAUDE.md` §0 and it is
there because agents reliably skip it.

## 2. Where the work stands

Read `PROJECT_STATE.md` for the real answer — this section goes stale and that one does not.

As of 2026-09-10: **M7 (modding) is complete, all seven steps.** `mod` discovers and
dependency-orders content packages; the installed C99/C++ header specifies the 135-call
`FoundryApi_v1`; `abi` validates and publishes the host's subsystems; and the native loader
runs package-local libraries through a refusal-safe lifecycle. `docs/modding/native-mods.md`
was written by building its C mod outside this repository and running its content, registered
component and system through an external proof host.

**M8 is complete, all eight steps (2026-09-12).** Read ADR-0028, ADR-0029 and
`docs/design/scripting.md`; §16 is the eight-step implementation order and every step is
marked done. Restricted Lua 5.5.1, ordinary package script assets, additive ABI v2 source
copying, binding 1's bounded content/world surface, the package lifecycle, candidate-VM
reload, the complete adversarial/determinism proof and the author guide are all in.
**A script package runs and can be edited while it runs**:
`samples/sandbox/content/scripts/encounter.lua` is registered as one system, driven by the
world's own fixed tick, and replaced in place when the file changes — its state and the
entities it owns carry across. `docs/modding/script-mods.md` was written by building a script
package outside this repository and was then rebuilt from its own listings to check it.

**M9 is complete, all eight steps (2026-09-13).** Read ADR-0031, ADR-0032 (which supersedes
ADR-0030) and `docs/design/distribution.md`; §14 is the implementation order and all eight
Resolutions record what implementation settled. Step 1: `engine/src/app/settings.zig` holds
the `settings.fset` envelope over `data`'s field-block layout, and `Os.replaceFileConfined` is
the confined temporary-then-rename write every later step goes through — a file this build does
not understand is preserved rather than replaced. Step 2: both samples resolve a window size
and a master volume from a built-in fallback, a `config` record in their own package, and the
player's file, in that order. **Two rules about when preferences are live, and both matter when
running the bar**: a headless run neither reads nor applies them, and a frame-budgeted run never
writes them — so `FOUNDRY_*_FRAMES` runs touch no settings file. Step 3: installed and user
package discoveries are combined before resolution, and the host-assigned base for each package
survives content/native/script loading and reload without entering either ABI. A headless sample
discovers ambient user mods only when an explicit `FOUNDRY_*_PACKAGES` selection asks for them.
Step 4: `zig build dist` stages a release of a sample from explicit inputs, through
`tools/distribution` — `release.zig` is the build-time description a game outside this
repository uses too, and `fstage` is the packager. **`dist` requires its configuration and will
not invent one**; the command is below. Step 5: a release carries `LICENSE`, `NOTICE` and a
`THIRD_PARTY_NOTICES.txt` generated from `THIRD_PARTY_LICENSES/`. **That directory's entries
are now parsed**, so their shape is load-bearing: a malformed one refuses the release rather
than shipping a gap. Step 6: `app.diagnostics` keeps a bounded session log under the
application's user-data `logs/`, with a marker saying whether the session closed. **A
frame-budgeted or headless run keeps nothing** — the same rule preferences follow — so
`FOUNDRY_*_DIAGNOSTICS=1` is how a scripted run exercises it at all. `zig build
diagnostics-stress` runs the unclean-exit cases in child processes. Step 7: `zig build dist`
now produces an ad-hoc-signed `.app`, matching dSYM and permission-preserving zip; the
separate `dist-developer-id` target is the only route that touches a private signing identity,
notarytool Keychain profile or network. Step 8: `docs/shipping/macos.md` and an outside build
prove exported-helper consumption, checksum-matched HTTP transfer, no-toolchain runtime,
cross-process preferences, relocated read-only user mods and failed-then-clean diagnostics.
Strict ad-hoc integrity passed and Gatekeeper rejection is expected. Actual Developer ID
signing, Apple notarization and a quarantine-preserving launch on a genuinely clean Mac remain
mandatory deferred work for the first public release; the current artifact does not claim it.

**M10 and M11 are complete (2026-09-13).** M10 added Foundry's marks and an
application-supplied release icon (ADR-0034). M11 fixed the carried correctness defects and
made the remaining entries explicit limitations; read ADR-0035 and
`docs/design/hardening.md`, whose nine steps and Resolutions are complete. The Metal-selected
test graph is part of the bar below. Both RHI backends now use completion-backed retirement;
rule 9 rejects use through dead handles and rule 11 enforces declared usage. `render2d`
replaces textures safely with frames in flight and shares the font texture for UI fills.
Only `SurfaceUnavailable` is skippable, and every opened frame is closed on failure. Captured
logs carry the engine's observed elapsed time, and ordinary file reads report the kind of the
same object they read. M11's final gate passed at **1,344 declared / 1,334 headless tests**,
ten Metal-only. **M12 is complete (2026-09-14).** Parallel work goes through an explicit
`core.Jobs` (ADR-0036, `docs/design/jobs-and-threading.md`): a chunk writes only its own data and
never allocates or calls the RHI, and every call site that splits work is tested under `serial`,
`reversed` and a real pool. `FOUNDRY_SANDBOX_WORKERS` and `FOUNDRY_ROOM_WORKERS` set a sample's
pool, `0` for none. M12 closed at **1,370 declared / 1,360 headless tests**.
**M13 is complete (2026-09-19), tagged `m13`.** ADR-0037/0038 are accepted; read
`docs/design/vulkan.md`. A Windows x64 Vulkan target is qualified and reached over SSH. Linux
x64 left M13 by ADR-0039. Its desktop runtime proof is M18, after the first game and before 3D.
Its headless and server use was proven in M16.5 (ADR-0046): on an x86_64 Ubuntu VM,
`./scripts/install-zig.sh` then `zig build test -Dplatform=null -Drhi=null` gives the Mac's
exact headless result. Rerun that there when `platform`'s transport, `net` or the headless loop
changes, and at each milestone close before M18. A 2 GB VM needs about 4 GB of swap to build. The Vulkan tools are pinned in §3 below, and `platform`
hands out native window payloads and opens system libraries safely. `rhi/backends/vulkan/`
creates a validated device, tracks submissions and allocates, copies and retires resources. It
creates checked SPIR-V shader modules, persistent descriptor sets, layouts and graphics
pipelines. It draws offscreen and presents to a real window through a FIFO swapchain, under
validation. Both samples run on it on Windows, each wearing a window icon it supplies, and
Windows is a runtime claim for the tested machine, with its limits in `vulkan.md`. The four
GLSL stages pass `glslangValidator`, `spirv-val` and Foundry's layout agreement tool before their
bytes can enter a target. The backend implements the whole RHI interface, so `-Drhi=vulkan`
builds the ordinary test and check graph and installs and runs the samples (§3). The native
Windows `zig build test` passes on the target, and native builds there use at most two jobs.
Mac cross-compilation never substitutes for runtime proof. **M14 is complete**: read
`docs/design/mod-management.md` and ADR-0040/0041. All nine steps are done. `app.ModSet` owns
discovery, resolution and record-level conflicts for both samples, and a player's duplicate
package is skipped rather than fatal. `app.profiles` keeps ordered profiles on disk, which the
mod set starts from, edits and applies. Step 3 added settings migrations and merged writes, and
both samples are on settings version 2 and profiles; their M9-era files, in `samples/*/testdata`,
convert. The samples have tests of their own now. Step 4 gave the UI kernel `image` and
`nine_slice` commands, naming images by opaque numbers the walker resolves, and a disabled
scope. Step 5 made themes content: `foundry:ui_theme`, resolved by `app.resolveUiTheme`, and
the room's card drawn from `room:ui.theme`. Step 6 made existing widgets skin-aware and added
tabs, selectable rows, reorder controls, icons and placed images without moving `ui` above L1.
Step 7 published it all as `FoundryApi_v3`: 28 calls after v2's, with changes refused unless
the host grants writes, and v1 and v2 unchanged. Step 8 built the room's mod screen (M) from
that table alone, in `samples/room/mods_screen.zig`. Step 9's exit proof passed in ReleaseSafe
builds driven by real input, on macOS and on Windows through Vulkan, and **M14 is complete**,
tagged `m14`. **M15 is complete**, tagged `m15`: read `docs/design/editor.md` and
ADR-0042/0043. Its nine steps cover public authoring and a standalone content-record editor
whose UI follows Unreal Engine 5's. Step 1 gave the parser opt-in source spans, with
`data/emit.zig` and `data/splice.zig` to write values back in place. Step 2 added
`engine/src/author/` — the one compiler `fpack` and the editor share, the dependency packages a
host grants, and bounded workspaces — and moved `fpack` onto it. Step 3 added revisioned typed
record commands, exact dependency overrides, incomplete drafts and bounded Undo/Redo. Step 4
added confined conflict-safe saves and explicit discard/refresh, stable bounded snapshots, and
fresh private build candidates retained behind generational handles; no ABI or preview was added.
Step 5 published the additive 47-call `FoundryApi_v4` authoring tail and moved `fpack` onto the
same service. Step 6 added `tools/editor`: an explicit-root host, ordinary editor content and
icon, a separately built header-only client that browses workspace/dependency/preview/schema/
asset/diagnostic state only through the public table, plus real-window, null-smoke and negative
import proofs. Step 7 turned that inspector into the editor: manifest and typed record forms,
list controls, the override action, commands with undo and redo, save reporting, in-window
confirmation and a revision indicator — over Step 5's calls, **adding none**. Step 8 authored a
content mod outside the repository through the window, consumed it in a relocated room, ran a
real C99 authoring client, and added Export to the editor over the call v4 already had; it
found four defects doing so, including a native loader that still offered only v1–v3. Its
Windows/Vulkan run followed on 2026-09-21: the same twenty workflow tests, the same
twenty-five-action null smoke frame for frame, and the same 489-action authoring plan on an
Intel Arc A750 through Vulkan 1.4, with the two saved `.fdt` files and the exported `.fpk`
byte-identical to the macOS/Metal run's. Step 9 closed the milestone. **M16 is complete
(2026-09-23, tag `m16`).** Read `docs/design/networking.md` and accepted ADR-0044/0045.
The owner requires public-internet multiplayer; the LAN-only proposal is withdrawn. The
accepted first architecture is one operator-hosted authority over TLS 1.3 mutual certificates,
up to four reference peers and no prediction. Step 1 pins and qualifies Mbed TLS 3.6.7 LTS,
adds L2 `net`, validates its limits and runtime channels, and freezes the pure bounded FNET
wire-v1 codec. `zig build tls-qualification` is its focused native provider proof; the ordinary
`test` and `check` graphs also carry it, including both cross targets. Step 2 adds
`platform.Transport` (`engine/src/platform/transport.zig`): nonblocking listeners and
connections carrying mutually authenticated TLS 1.3, over the OS's sockets — called from
`transport/socket.c`, because Zig 0.16's `std.Io.net` blocks — or a deterministic `.memory`
carrier that fragments, stalls, resets and corrupts on command. A peer certificate must name its
role in extendedKeyUsage and a client pins the server's key. `zig build transport-test` is its
focused proof, real loopback included, and is part of `zig build test`. Step 3 adds
`net.Service` (`engine/src/net/service.zig`): sessions only by host grant, an allowlist mapping
client keys to principals, compatibility refused by category and first difference, bounded
pre-authentication work, four deadlines, per-peer pump budgets and reserved events. A live
stream now fails when its peer's certificate expires. `zig build net-session-test` is its
focused proof and is part of `zig build test`. Step 4 adds delivery to the same service: one
baseline per peer, activation only by acknowledging it, commands admitted by `admitBatch` in
participant and command-number order, and complete state that replaces unsent state; its proofs
are in the same file and step. Step 5 publishes all of it as `FoundryApi_v5`, 22 additive calls
in `engine/src/abi/calls_net.zig` over a service and a list of published grants the host binds to
its `abi.Host`. `zig build abi-net-test` drives a real service through the table alone. Step 6
connects the sandbox: `samples/sandbox/connected.zig` is the host (launch modes, the operator's
credential file, the service, pumping, pacing), and `samples/sandbox/markers/` is the consumer,
granted only the header like the editor's client. `zig build markers-boundary` is in `test`.
`zig build sandbox-net-proof -Dplatform=null -Drhi=null` runs separate headless processes over
loopback. It is not in `test`: run it when networking, the sandbox or its content changes.
`-- --provision <dir>` writes disposable test credentials for a windowed run by hand. Step 7 adds
`zig build sandbox-net-matrix` (in `test`): the consumer against hostile, broken and slow peers,
and a byte-exact replay of a session's admitted inputs. `zig build sandbox-net-proof
-Dplatform=null -Drhi=null -- --envelope 600` runs §10's controlled envelope for ten minutes
through a shaping relay. Run it when networking's timing could have changed, not every commit.
Step 8 ran it over the public internet from a cloud VM. `docs/modding/networking.md` is how an
operator provisions credentials and deploys a server, and holds an external C99 consumer's
whole source. A public listener, a firewall change, real credentials and any infrastructure
still need the owner's explicit yes at the time. The Vulkan checks need the SDK's `bin` on
`PATH`. The bar below is current. M13's Step 9 added the checks Vulkan and release work need,
and M14 added an optimized Windows check to them.

## 3. Building and verifying

The pinned toolchain is **Zig 0.16.0**, and it is not on `PATH`:

```sh
export PATH="$HOME/.local/zig/0.16.0:$PATH"
```

`.toolchain/bin/zig` is a repo-local convenience copy of the same thing. It is gitignored and
must stay that way — it is about 400 MB. The canonical install is the versioned path above
(ADR-0014).

**Never track Zig master or nightly, and never upgrade the pinned toolchain during a
milestone.** (`CLAUDE.md` §10.)

### The bar, before anything is committed

Every one of these, every time. Not a subset.

```sh
zig fmt --check engine tools samples build.zig
zig build test
zig build check
zig build check -Drhi=metal
zig build check -Dtarget=x86_64-linux-gnu   -Dplatform=null -Drhi=null
zig build check -Dtarget=x86_64-windows-gnu -Dplatform=null -Drhi=null
FOUNDRY_SANDBOX_FRAMES=30 zig build run  -Dplatform=null -Drhi=null
FOUNDRY_ROOM_FRAMES=30    zig build room -Dplatform=null -Drhi=null
```

`check` compiles everything without running it, including the cross-compiled targets where
padding and ABI assumptions differ from macOS. `-Drhi=metal` is the macOS configuration's whole
graph, test binaries included — the Metal executables building is not the same evidence: a test
binary under that flag stayed uncompilable for several milestones while every executable built
(`hardening.md` §4). The two samples are the milestone's runnable
result (`CLAUDE.md` §2) — a change that builds and leaves the sandbox broken is not done.

When the ABI surface changed, also compile a C mod against the *installed* header, because the
Zig tests cannot see what a C author cannot express. `engine/tests/fixtures/author_client.c`
is one such consumer, kept for this: it calls every v4 authoring entry point and nothing else.
`engine/tests/fixtures/net_client.c` does the same for the 22 v5 networking entry points.

```sh
zig build                                    # installs zig-out/include/foundry.h
C=engine/tests/fixtures/author_client.c      # or your own mod.c
zig cc  -std=c99 -pedantic -Wall -Wextra -Werror -Izig-out/include -c $C -o /dev/null
zig cc  --target=x86_64-linux-gnu   -std=c99 -pedantic -Werror -Izig-out/include -c $C -o /dev/null
zig cc  --target=x86_64-windows-gnu -std=c99 -pedantic -Werror -Izig-out/include -c $C -o /dev/null
zig c++ -x c++ -std=c++17 -Wall -Wextra -Werror -Izig-out/include -c $C -o /dev/null
```

This is not ceremony. M7's step 4 found three defects this way and none of them by any other
route: a type a C mod had no way to construct, a header that did not compile as C++ at all,
and an agreement that stopped firing.

When the editor's client, host or content changed, also drive it. The workflow tests are in
`zig build test`; the other two are application proofs and are not, and the windowed one is
the only thing that shows text entry, DPI and clipping actually working (`editor.md` §12):

```sh
zig build editor-workflow                              # deterministic input, no window
zig build editor-smoke -Dplatform=null -Drhi=null      # the scripted walk, headless
zig build editor -Drhi=metal -- --source <pkg> --output <work> --script --frames 240
```

**Point `--source` at a throwaway package outside the repository.** The walk writes nothing,
but the editor is granted edit, save and build authority over whatever it is given.

`--script` replays the generic walk, which names no schema, record or field. `--plan <file>`
replays an action list instead, which is how an *authoring* run is driven — one action a line,
`click`/`enter`/`write`/`key`/`idle`, described in `docs/modding/editor.md`. Keep a plan beside
the package it edits: the names in it are that package's, and the editor knows none of them.
`--export <file.fpk>` is what hands the build to a directory; without it the Export button has
no destination and stays disabled.

When a sample's content, a package's asset kinds or a release description changed, also stage
both releases (*Staging a release*, below). M13 Step 8 gave the samples an asset kind of their
own, and `dist` refused it until the release declared the file; nothing in the bar noticed.

When Vulkan code, shaders or the platform's native window changed, also run the Vulkan checks
on a host with the SDK tools on `PATH`, and the native commands on the Windows target
(*Vulkan work*, below):

```sh
zig build vulkan-check -Drhi=vulkan -Dtarget=x86_64-windows-gnu
zig build vulkan-check -Drhi=vulkan -Dtarget=x86_64-linux-gnu
zig build check        -Drhi=vulkan -Dtarget=x86_64-windows-gnu
zig build check        -Drhi=vulkan -Dtarget=x86_64-linux-gnu
zig build check        -Drhi=vulkan -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe
```

The last line is there because a Windows release is optimized, and until M14 no optimized
Windows build had been compiled. The first one failed in translated MinGW headers, which a Debug
check cannot see (`vulkan.md`, the M14 note at its end). Run it also when an `@cImport` changes.

### Vulkan work (M13)

Null and Metal builds need none of this; install it only on a host doing Vulkan work
(ADR-0038). **LunarG Vulkan SDK 1.4.357.0**, core component only, at a versioned root, from
`https://sdk.lunarg.com/sdk/download/1.4.357.0/<windows|mac|linux>/<archive>`. Verify the
archive against its recorded SHA-256 before installing:

| Host | Archive | SHA-256 |
| --- | --- | --- |
| Windows x64 | `vulkansdk-windows-X64-1.4.357.0.exe` | `81f474711e9042f4cd22b31b2f7a8870db2e428b21586fb43dd80150be97310d` |
| macOS, host tools only | `vulkansdk-macos-1.4.357.0.zip` | `539433589c83522e6f31b1c7b418a4167e21597a4a361ab119e1dc0760cf3865` |
| Linux x64, unused until M18 | `vulkansdk-linux-x86_64-1.4.357.0.tar.xz` | `0f09bf6a0625e346bf004be70b92907e934a4c76606b323441b2baf3a5a0e66d` |

```sh
# macOS, from the unzipped archive; nothing is placed in /usr/local
vulkansdk-macOS-1.4.357.0.app/Contents/MacOS/vulkansdk-macOS-1.4.357.0 \
  --root "$HOME/VulkanSDK/1.4.357.0" --accept-licenses --default-answer \
  --confirm-command install com.lunarg.vulkan.core
export PATH="$HOME/VulkanSDK/1.4.357.0/macOS/bin:$PATH"
```

```powershell
# Windows, elevated. It also registers the SDK's explicit layers, adds its Bin to the system
# PATH and updates the system Vulkan runtime.
.\vulkansdk-windows-X64-1.4.357.0.exe --root C:\VulkanSDK\1.4.357.0 --accept-licenses `
  --default-answer --confirm-command install com.lunarg.vulkan.core
```

Both hosts then have `glslangValidator` 16.4.0 and `spirv-val` from SPIRV-Tools v2026.3, and
they produce byte-identical SPIR-V from the same source. Always name the target environment:

```sh
glslangValidator -V --target-env vulkan1.3 -S frag -o stage.frag.spv stage.frag
spirv-val --target-env vulkan1.3 stage.frag.spv
```

On Windows the SDK's `vulkaninfo` is `vulkaninfoSDK.exe`. Implicit layers other software
installs — overlays, capture hooks — are not part of the evidence: set
`VK_LOADER_LAYERS_DISABLE=~implicit~` for a qualifying run. **An elevated process ignores it.**
An administrator's SSH session on Windows runs at high integrity. There the loader ignores
`VK_LOADER_LAYERS_DISABLE` and every layer-path variable (`VK_ADD_LAYER_PATH` among them), and
says so only under `VK_LOADER_DEBUG=all`. So over SSH, also set each installed implicit layer's
own `disable_environment` variable from its manifest, and confirm with `VK_LOADER_DEBUG=layer`
that no implicit layer is inserted. A desktop-session run started by a scheduled task runs at
normal integrity and honours the filter. Vulkan-Headers come only from the
lazy `build.zig.zon` pin, never from a system or SDK include directory.

**Zig on Windows** has no install script; `install-zig.sh` is POSIX-only. Use the official
archive with the same versioned layout, never a package manager (ADR-0014):
`https://ziglang.org/download/0.16.0/zig-x86_64-windows-0.16.0.zip`, SHA-256
`68659eb5f1e4eb1437a722f1dd889c5a322c9954607f5edcf337bc3684a75a7e`, extracted to
`%USERPROFILE%\.local\zig\0.16.0`.

**RenderDoc 1.46** inspects a captured frame. Use the portable
`https://renderdoc.org/stable/1.46/RenderDoc_1.46_64.zip`, SHA-256
`9ca4d09ecaba2cc791168660d6fc2a7e3d70fe67146e87ec05c5f8dea70772f7`, unpacked to
`%USERPROFILE%\tools\RenderDoc_1.46_64`. Do not register its layer. For a normal-integrity process,
name the folder with `VK_ADD_LAYER_PATH` and enable `VK_LAYER_RENDERDOC_Capture` with
`VK_INSTANCE_LAYERS`; elevated, neither variable is honoured. For an unattended capture,
`qrenderdoc.exe --python <script>` runs the script before the UI opens. The script can launch the
sample with `ExecuteAndInject`, capture through target control, replay, and exit with
`os._exit`. With a fresh configuration, qrenderdoc first opens an "Analytics" question and waits
on it, invisibly over SSH, so close that window when it appears.

`zig build native-window-test` opens real native windows through SDL3 and is not part of the
bar, because it needs a desktop session. On a Windows target reached over SSH, start it inside
the logged-in session — a scheduled task with an interactive logon — never an RDP session.

**The Vulkan backend's tests** need a Vulkan driver and the SDK's validation layer, so they run on
the target and not in the bar. `-Drhi=vulkan` builds the ordinary test and check graph against the
Vulkan backend, plus three steps of its own, and since M13 Step 8 it installs and runs both
samples. It needs the SDL3 platform; `-Dplatform=null` is refused at configure time:

```sh
zig build vulkan-test        -Drhi=vulkan                             # on Windows (Linux: M18)
zig build vulkan-window-test -Drhi=vulkan                             # in a desktop session
zig build test               -Drhi=vulkan                             # the whole graph, on the target
zig build install            -Drhi=vulkan --prefix <dir>              # the samples, on the target
zig build vulkan-check       -Drhi=vulkan -Dtarget=x86_64-windows-gnu # any host; compile only
zig build check              -Drhi=vulkan -Dtarget=x86_64-linux-gnu   # any host; compile only
```

Content compiles only for a native install, so build the samples on the target itself. A sample
run is evidence when it starts from a copy of that prefix moved elsewhere, with Zig and the SDK off
`PATH` and `APPDATA` (or `HOME`) pointed at a scratch root. Enable validation for it through the
loader (`VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation`, with the layer's `LOG_FILENAME`,
`REPORT_FLAGS=error,warn,info` and `VALIDATE_SYNC=true` settings), because the samples do not
require it themselves; and once with `VK_LOADER_LAYERS_DISABLE=~all~`, to show nothing from the
SDK is needed. On Windows, run them in the desktop session like `vulkan-window-test`. Find a
sample's window by its title as well as its process, since the process can own other visible
windows. A minimised window's frames are skipped, paced only by the samples' one-step sleep, so
bound a run that minimises by closing the window, not by a frame count.

The backend tests require validation and fail, never skip, without it. Set
`VK_LOADER_LAYERS_DISABLE=~implicit~` for them as for any qualifying run. Their surface test opens
an SDL window; started over SSH on Windows, that window stays in the SSH session and never reaches
the desktop. `vulkan-window-test` presents to real windows, minimises and restores them, so on a
Windows target start it like `native-window-test`: a scheduled task with an interactive logon.

### Staging a release

`dist` builds exactly one configuration and refuses every other, naming each wrong thing at
once. There is no shorter form; `-Dtarget` is deliberately absent, because stating it produces
a target Zig no longer calls native and the content compiler has to run here:

```sh
zig build dist -Dapp=room -Dplatform=sdl3 -Drhi=metal -Doptimize=ReleaseSafe \
  -Drevision=<commit>
```

`zig build diagnostics-stress` is part of `zig build test` and also runs on its own. It spawns
children that die without closing their session, so **expect stderr noise from a passing
run** — a child that exits 3 on purpose is the test working.

`-Dapp` is `room` (default) or `sandbox`; `-Drevision=<sha>` is recorded in the release's
inventory and is `local` when unstated — the build runs no `git`. The staged tree is
build-owned and fresh. Local output lands in `zig-out/dist/<app>/` as `<Product>.app`, its
separate `<Product>.app.dSYM`, and `<Product>-local.zip`. The application is ad-hoc signed
without a timestamp; this proves the local bundle and relocation, not public notarization.
It is a real artifact, so it takes a real SDL and Metal build: expect minutes on a cold cache,
and expect it to be the slowest thing here. `zig build distribution-test` runs the focused
staging/plist/dependency/symbol policy tests without building the windowed artifacts.

Public signing is an explicit operator action. First store credentials in the operator's
Keychain profile, following `notarytool`'s prompts; do not put passwords, API keys or private
key material in a command, environment variable or repository file. Then state all three
public-release inputs:

```sh
xcrun notarytool store-credentials "<profile>"
zig build dist-developer-id -Dapp=room -Dplatform=sdl3 -Drhi=metal \
  -Doptimize=ReleaseSafe -Drevision=<commit> \
  -Dsigning-identity="Developer ID Application: … (TEAMID)" \
  -Dnotary-profile="<profile>"
```

`dist-developer-id` signs with hardened runtime and Apple's timestamp, submits and waits,
staples and validates the accepted ticket, verifies codesign and Gatekeeper assessment, and
then creates the final zip under `zig-out/dist/<app>-developer-id/`. Never run it without the
owner's authorization to use that identity, Keychain profile and network service.

### Counting tests

`PROJECT_STATE.md` quotes the bar's `zig build test` summary line: the headless graph,
passed of declared. The grep below counts every test declaration, including the ones only the
Metal, Vulkan and desktop-window graphs run, so it is larger. It is useful for the size of a
change, not as the quoted number. Since M14 the samples carry tests too:

```sh
{ grep -rhc '^test "' --include='*.zig' engine/src engine/tests tools samples;
  grep -rhc '^test {' --include='*.zig' engine/src engine/tests tools samples; } | paste -sd+ - | bc
```

## 4. Environment gotchas

Each of these cost real time to discover.

* **`failed command:` lines appear in a *passing* build.** They are noise from cached steps.
  Read the exit code, not the output.
* **`zig build test` prints nothing when everything is cached.** `--summary all` shows the
  steps. A silent run is a passing run.
* **`zig build run` and `zig build room` block forever** without `-Dplatform=null -Drhi=null`
  and a frame budget (`FOUNDRY_SANDBOX_FRAMES` / `FOUNDRY_ROOM_FRAMES`).
* **`/tmp` is not writable.** Use the agent scratchpad, and do not assume it survives between
  sessions — it does not.
* **`timeout` is not installed.** `grep` is `ugrep`.
* **Never `rm -rf .zig-cache/o` on its own** — it deletes the build runner and you get
  *"failed to spawn build runner … FileNotFound"*. Remove the whole `.zig-cache`.
* **Zig's test runner fails any test that logs at `err` level.** That rule is correct and is
  not worth opting out of; split the logging from the pure part and test the pure part.
* **In a test binary the root is the test runner**, so `std.log` never reaches `app.log_sink`.
  Seed the ring by calling `app.log_sink.logFn(...)` directly.
* **An `Os` handed no environment has no temporary directory on Windows.** `tempDirAlloc`
  falls back to `/tmp` only on POSIX. A test needing scratch space uses `std.testing.tmpDir`;
  a program's `main` hands its environment on through `app.environment`.
* **Zig 0.16.0 labels a no-follow file handle on Windows as blocking when it is not**, and its
  first read reaches `unreachable`. `Os.openFileConfined` corrects the label; after a toolchain
  upgrade, delete that line if the confined-file tests pass on Windows without it.
* **`zig build test` opens loopback sockets.** The transport proofs listen on `127.0.0.1`
  with an OS-chosen port and connect to it; they never bind a public address. On Windows a
  refused loopback connect takes a second or two to report, so that proof waits on a deadline
  rather than a pump count.
* **Mbed TLS's allocation and clock hooks are process-wide.** `Transport` installs them and
  counts every provider allocation against its cap. Test code that calls the provider directly
  (`engine/tests/fixtures/tls_identities.c`) must free everything before it returns, or the
  accounting goes wrong for the next `Transport`.
* **A TLS refusal may reach the refused side as `protocol`.** Under TLS 1.3 an early client
  alert is unprotected and a server's late one uses keys the client has left, so only the side
  that refused names the certificate problem (`networking.md`, Step 2 Resolution).
* **A `net.Service` that nobody reads events from stops admitting.** Every authorized connection
  reserves its admission, activation and ending events up front, so the queue can never overflow; the price
  is that a host or proof that never calls `nextEvent` reaches `queued_events` and new peers are
  refused `capacity`. Its pump reads no clock either: it is handed monotonic nanoseconds, so a
  proof reaches a deadline by advancing the time it passes, not by sleeping.
* **A C file's object is cached against the C file, not its headers.** Editing a `.h` alone can
  leave the build green. `engine/src/abi/agreement.zig` `@embedFile`s `foundry.h` specifically
  to defeat this; if you add another C translation unit that a header must keep honest, it
  needs the same treatment.

## 5. How to work here

**Design before implementation.** (`CLAUDE.md` §2 rule 1.) A subsystem gets a document in
`docs/design/` before it gets code, and that document is what the code is checked against. If
implementation contradicts the design, the design was wrong and says so in a dated Resolution
section appended to it — that is how every step of M7 has been recorded.

**Never commit code you have not compiled.** Step 4 arrived in this tree with three compile
errors and five more behind them, a resolution section describing behaviour that did not exist,
and three tests where eleven were needed. Run the bar in §3.

**Verify a guard by breaking it.** A test that has never failed is a test you do not know
works. Every agreement check in `engine/src/abi/` has been confirmed by making the mistake it
exists to catch and watching it fail — narrow a struct member, reorder a table entry in each
direction, change a hash constant, use a C++ keyword. Do the same for anything new that claims
to protect something.

**Never `git checkout <file>` on a file with uncommitted work.** It discards it silently.
This ate work three times in one session. Copy first, or use `git stash push -- <paths>`.

**Untrusted input is validated, never asserted.** Anything from a mod, a content package, a
save or a tool. `core.assert` is for programmer error only. When you add an entry point that a
mod can reach, walk the call chain under it and confirm no assertion is reachable with input
the caller controls.

**Finish a unit, persist it, hand back.** Do not chain into the next step because the current
one went well. A step ends with the bar in §3 green, `PROJECT_STATE.md` updated, and a commit.

**When something is genuinely undecided, say so and stop.** Do not resolve a recorded open
question opportunistically while implementing something else. If implementation forces a
decision, document it architecturally — an ADR, or a Resolution section — *before* proceeding.

## 6. Agent execution and bounded verification

The primary agent performs implementation, reasoning, testing, debugging, documentation
updates and review itself by default. Delegation is exceptional, not routine. Use a subagent
only for a concrete technical reason that materially benefits the task, such as genuinely
independent parallel work or a clearly separable investigation.

Do not spawn agents merely to repeat completed work, review work the primary agent can
reasonably review itself, reconfirm successful tests, duplicate architecture or documentation
audits, or provide reassurance after adequate verification has succeeded. Never spawn several
agents that substantially inspect the same work or answer the same verification question.

Foundry still requires rigorous verification. This policy eliminates redundant verification;
it does not lower correctness, security, portability, testing or architectural standards. For
a normal implementation step:

1. Implement the planned work.
2. Run the tests and checks directly relevant to the changed systems.
3. If a check exposes a concrete problem, fix it and rerun the affected checks.
4. Once targeted verification is clean, perform one appropriate final integration/regression
   verification.
5. Perform one documentation consistency pass and make all required documentation updates.
6. Stop when these are clean.

A successful verification remains accepted unless subsequent changes could reasonably have
invalidated what it established. Do not:

* re-audit already-clean work without new evidence;
* verify a verification pass merely for additional reassurance;
* repeatedly perform whole-repository audits answering substantially the same question;
* repeatedly reread or revalidate documentation after it has been confirmed;
* perform chains of "final check", "last check", "sanity check", "one more pass", or
  equivalent checks over unchanged work;
* spawn reviewers simply to reconfirm successful verification; or
* restart the entire verification sequence after a localized fix unless that fix materially
  affects the wider system.

When verification exposes a problem, use the bounded sequence
`problem -> fix -> rerun affected verification -> continue`; do not restart every previous
audit unless the fix materially affects the wider system. Focused executable evidence is
preferable to repeated speculative inspection.

Repository-wide tests, cross-compilation, security tests, integration tests, sample runs,
architecture checks, documentation checks and other expensive verification remain appropriate
when the affected subsystem or established Foundry process requires them. Run them when they
provide distinct evidence, but do not rerun them over unchanged work merely for reassurance.
Additional verification is justified when new changes could invalidate an earlier result; a
failure reveals possible wider consequences; an applicable ADR or design requires it; an
affected security, ABI, determinism, portability, memory-safety or similar boundary requires
distinct evidence; or the final integration check discovers a new concrete concern. Otherwise,
once sufficient evidence is clean, stop.

Treat this repository as authoritative. Follow this file, `CLAUDE.md`, the ADRs, design
documents, `PROJECT_STATE.md`, the roadmap, build-layer rules, tests and established
conventions. Do not redesign established architecture merely because another design appears
preferable. If a milestone exposes a contradiction that prevents correct implementation,
resolve it through Foundry's ADR/design process. Stay strictly within the current milestone
step and do not implement future-step functionality merely because it is convenient.

## 7. Commits

Small, focused, present tense (`CLAUDE.md` §7). The subject line says what the change lets
somebody do, or what it stops being possible; the body says what the design had not settled and
why the answer is what it is. Look at `git log` — the existing messages are the standard.

Commit as the repository's owner:

```sh
git -c user.name="Shrunjoy Ghosh" -c user.email="sjoy.gsh@gmail.com" commit -F <message-file>
```

Do not add a `Co-Authored-By` trailer naming a model you are not. A milestone ends with a
tagged commit and an updated `PROJECT_STATE.md`.

## 8. Standing constraints from the user

These are in force regardless of what any task appears to ask for.

* **No game-specific code, assets or assumptions in this repository.** The game being built on
  Foundry lives in its own repository and always will (ADR-0017). `samples/` demonstrates
  capabilities; when a sample starts wanting features rather than demonstrating them, it has
  outgrown this repo.
* **No secrets, credentials, API keys, personal files or machine-specific configuration**, in
  the tree or in a commit.
* **No CI, release automation, contribution infrastructure or elaborate GitHub configuration**
  unless the current milestone actually requires it.
* **Keep recorded open questions open.** `CLAUDE.md` §9 and each design doc's "open questions"
  section are deliberate. Closing one is a decision that gets discussed and written down, not a
  side effect.
* **Never make a major architectural decision silently.** If a change would violate an
  invariant in `CLAUDE.md` §3, or make modding harder, stop and raise it.
