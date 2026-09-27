# The Linux desktop — M18

**Status: complete, 2026-09-27 (tag `m18`).** The record of how M18 made ADR-0008's Linux x64
build-check a runtime claim: what ran, where, what broke, and what the claim does not cover.

M18 had no design of its own to write. The Linux paths were designed in M13
([`vulkan.md`](vulkan.md), ADR-0037 and ADR-0038) and build-checked by every milestone since,
and ADR-0039 moved their proof here. This document is the evidence, laid out against the
roadmap's list of what M18 owed.

## 1. The machine

The route M13 recorded, in the end: a Linux installation on a second drive of the Windows
target's PC. A rented cloud GPU was prepared first (`scripts/m18/`) and was not needed.

| | |
| --- | --- |
| Distribution | Ubuntu 26.04.1 LTS, kernel 7.0.0-34-generic |
| CPU, memory | Intel Core i3-10105F, 8 threads; 15 GiB |
| GPU and driver | Intel Arc A750 (DG2), Mesa 26.0.8 (ANV), Vulkan 1.4.335 |
| Display | one 1920×1080 monitor on DisplayPort, 60 Hz |
| Loader | the distribution's `libvulkan1` 1.4.341 |
| X11 | Xorg 21.1.22 with the modesetting driver and glamor, on its own console; openbox 3.6.1, tint2 |
| Wayland | GNOME Shell 50.1 (the logged-in desktop, mutter); sway 1.11 (wlroots 0.19.2), headless on the Arc |
| Tools | Zig 0.16.0; LunarG SDK 1.4.357.0 (glslang 16.4.0, SPIRV-Tools v2026.3); RenderDoc 1.46 |
| Foundry | `m17.1` plus this milestone's two engine changes (§3) |

**The SDK pin was re-qualified, not upgraded.** Its Linux archive matched the SHA-256 in
AGENTS.md, and its tools are the versions the macOS and Windows pins carry. The first runs used
Ubuntu's own validation layer (1.4.341) while LunarG's server sent the archive at a few
kilobytes a second. Every result below was repeated with the pinned layer, and Ubuntu's was
uninstalled first, so the loader could find no other.

## 2. What ran

Every Vulkan process ran with implicit layers filtered (`VK_LOADER_LAYERS_DISABLE=~implicit~`).
Every validated run enabled the pinned Khronos layer with synchronization validation.

**The whole test graph, natively.** `zig build test -Drhi=vulkan` passed **104/104 steps and
1,721 of 1,727 tests**, with six OS-conditional skips. `vulkan-window-test` and
`native-window-test` passed 10/10 and 7/9 under X11, and again under GNOME's Wayland; both
skips are for other operating systems.

**Both samples, from a relocated install.** `zig build install -Drhi=vulkan` built them and
compiled their content on the machine. The prefix was copied to a directory whose name holds a
space. Each run started from the copy with only `/usr/bin:/bin` on `PATH`, a scratch `HOME` per
session, and the environment a login of that kind has. `scripts/m18/samples.sh` holds the runs.

| Run | X11 (Xorg, openbox) | Wayland (sway) | Wayland (GNOME) |
| --- | --- | --- | --- |
| Sandbox, 900 frames, walking, picking, sprite sheet touched every 200 ms | 29 reloads, 9 picks | 29 reloads, 9 picks | 30 reloads |
| Sandbox resizing itself, minimised and restored twice, closed by the window system | resizes; iconified ×2; closed, clean exit | resizes; hidden in the scratchpad ×2; closed, clean exit | resizes; closed |
| Room on autopilot with the overlay, 600 frames | 4 of 6 lamps; card took 4 clicks; 0 capture failures | same | — |
| Sandbox with a user package in the scratch `HOME`'s mods | 960×540, volume 0.50, its 16×16 icon | 960×540, volume 0.50, icon refused | — |
| Sandbox with every layer disabled, 600 frames | clean, 16.58 ms median | clean, 16.26 ms median | — |
| Real input in the room | click, type, click out, click the hall, walk, quit | keys: open the card, walk, quit | — |

**Every validation log held no error and no warning** — 12 validated runs, each with the layer's
start-up notice showing it was live.

**Real input.** On X11 the room took xdotool's pointer and keys:
`card: opened 1 time(s), took 3 click(s), name 'the lamplighter x11'; hall took 1 walk
command(s), 0 capture failure(s)`. On Wayland, sway's virtual keyboard opened the card and
walked the character. No pointer reached the window there: headless sway has no pointer device,
and a transient virtual pointer disappears before a client binds it. GNOME lets no client drive
another. So Wayland's pointer evidence is the autopilot, which presses through the same UI path.

**The icon, visibly on X11.** Each sample's 64×64 mark is in the title bar and in tint2's
taskbar, including while the window is iconified. `_NET_WM_ICON` read back as the package's
16×16 image in the user-package run. **Wayland leaves the icon to the compositor:** neither
GNOME 50 nor sway 1.11 implements `xdg_toplevel_icon_v1`, so SDL refuses the icon, the sample
logs `WindowIconRefused` as a warning, and the window keeps its default. That is recorded, not
worked around.

**One RenderDoc capture, opened and inspected** (`scripts/m18/capture.sh`, on X11). RenderDoc
1.46 launched the relocated sandbox with its layer named by path and nothing registered. It
captured frame 343 (1.9 MB) and replayed it here: `Supported`. The sprite draw, event 20 with
22,272 indices, was inspected as on Windows (`vulkan.md`, Step 9). The values match it exactly:
- SPIR-V stages, entry `main`;
- the 64×64 `R8G8B8A8_SRGB` sheet at set 0, binding 0, and its sampler at binding 1;
- the 64-byte `view_projection` push constants diag(2/1152, 2/648, 1, 1);
- 20-byte vertices with position and UV at offsets 0 and 8 and RGBA8 colour at 16;
- first indices 0, 1, 2, 0, 2, 3;
- the first vertex (−96, −80) with UV (0.25, 0.25), leaving the vertex stage at
  (−0.1667, −0.2469);
- the viewport at y = 648 with height −648;
- the `B8G8R8A8_SRGB` 1152×648 target, holding the sprite field.

**Pacing.** FIFO held the display's rate on X11 and on sway. The last 240 frames had medians of
16.58–16.61 ms on X11 (p95 16.9–17.8 ms) and 16.26–16.28 ms on sway (p95 ≤ 16.35 ms).
- **GNOME** ran the same sandbox at a 20.2 ms median and 21.0 ms p95, while reporting its mode
  as 1920×1080 at 60.000 Hz. This is measured, not explained, and it stays an open observation
  (§5).
- **Minimising means three different things.** On Windows a minimised window has zero extent,
  so frames are skipped (M13). An iconified X11 window keeps its extent, and Mesa's X11
  presentation kept pace at 60 Hz: no frame was skipped. A window hidden in sway's scratchpad
  kept presenting too. The contract holds in all three: a frame is skipped only when no image
  is available.

## 3. What broke, and what changed

**A second platform's shutdown closed the first's Wayland connection.** A test that opens two
`Platform`s crashed under Wayland only: the second's `deinit` called `SDL_Quit`, which ignores
SDL's init count and shut video down under the first. That platform's swapchain destruction
then segfaulted inside `libwayland-client`. On X11 and Windows the same misuse happened to
survive. Each `Platform` now releases its own reference to SDL video, and the last one quits
SDL (`platform/backends/sdl3.zig`). Restoring `SDL_Quit` brings the crash back.

**The icon test assumed every window system takes an icon.** Under Wayland it failed on
`WindowIconRefused`, and leaked its pixels on that path. It now frees them on every path, and it
accepts a refusal only under Wayland. X11 and Windows still fail on one.

No RHI rule changed, so no ADR was needed. What the harness learned is in AGENTS.md:
- **SDL chooses Wayland unless told otherwise.** It tries `wayland-0` unless
  `XDG_SESSION_TYPE` names another kind of session. A stripped environment on a machine whose
  desktop is Wayland therefore reaches that desktop, even with `DISPLAY` set.
- **A Wayland compositor that is not on screen sends no frame callbacks.** A swapchain
  presenting to it waits. Run Wayland evidence on the compositor that has the display, or on
  one of your own.

## 4. The exit criterion

*Both samples run on Vulkan on Linux, under X11 and under Wayland, with a hardware driver and no
validation error.* Met on the machine in §1, part by part in §2. ADR-0008's Linux build-check is
now a runtime claim. The RHI's rules survived unchanged.

## 5. What the claim does not cover

- **One machine.** One Intel Arc on Mesa ANV and one 60 Hz monitor at scale 1.00. No NVIDIA,
  no AMD, no HiDPI, no multi-monitor. The rented-GPU kit in `scripts/m18/` is ready for
  NVIDIA, and has not run.
- **Two compositors,** GNOME 50 and sway 1.11, plus Xorg with openbox. KDE's KWin implements
  `xdg_toplevel_icon_v1` and would take the icon; it was not tried.
- **GNOME's pacing** (§2) is unexplained. Its trigger is a player reporting it, or a frame-time
  budget that fails there.
- **No Wayland pointer was driven from outside** (§2).
- **No Linux release artifact.** `dist` stages macOS and Windows only. A Linux desktop release
  is a distribution decision with its own questions (ADR-0030's shape, AppImage or tarball,
  what a player's system must supply), and nothing has asked for one.
- **Device and surface loss** are still sticky (`rhi.md`, open question 6).
