# ADR-0046: Linux servers are proven before release; the Linux desktop still waits

**Status:** Accepted
**Date:** 2026-09-23
**Supersedes:** [ADR-0039](0039-linux-after-the-first-game.md) in one clause only: "No document
may describe Linux as supported at runtime until M18 proves it" now excludes Linux x64
headless use, which M16.5 proves

## Context

ADR-0039 moved every Linux runtime claim to M18, after the first game and before 3D, because
the first game ships on macOS and Windows and no Linux machine existed. It left Linux
compile-checked: the bar cross-compiles `x86_64-linux-gnu`, and nothing has ever run there.

M16 changed two facts.

**The first game needs servers, and servers are usually Linux.** The game is a 2D online game.
By ADR-0044/0045 its authority is an operator-hosted, headless process at a reachable address,
and M16 Step 8 proved that shape on a Windows cloud VM. For a real deployment the cheapest and
most common host is a Linux VM. The first game ships its *clients* on macOS and Windows, but it
will very likely run its *servers* on Linux. That part of Linux is not after the game; it is in
the game's path.

**A Linux machine is now cheap, and a headless one is enough for that part.** An hourly x86_64
cloud VM has no GPU and no display. It cannot test what M18 owes: X11, Wayland, a Vulkan
driver, windows, icons, input or pacing. It can run everything a server runs:
- `platform`'s null backend;
- the transport's POSIX socket path, compiled but never executed;
- the TLS provider;
- `net`'s sessions;
- the headless sandbox authority.

ADR-0039's own revisit clause names this case: "a Linux machine becomes available cheaply and
Linux work stops competing with the game."

The owner asked, on 2026-09-23, for Linux testing on AWS before M17.

## Decision

**Linux runtime is split in two.**

**Linux x64 headless is proven now, in its own milestone, M16.5, before M17.** It is "headless"
in the M16 sense: `-Dplatform=null -Drhi=null`, no window, no GPU. The claim it may earn is:
*Foundry's headless graph and its network authority run on Linux x64.* It owes:
- the native headless test graph on a Linux x64 machine, built there with the pinned Zig
  0.16.0 from `scripts/install-zig.sh`;
- the null samples, and the loopback network proof, run there;
- the headless sandbox authority running there, serving the relocated macOS and Windows
  clients over the public internet, with joins, refusals and a measured run as in M16 Step 8;
- the external consumer from `docs/modding/networking.md`, built and run there.

**The Linux desktop stays M18, exactly as ADR-0039 wrote it.** That covers SDL3 on X11 and
Wayland, a hardware Vulkan driver, validation, windowed samples, the icon, RenderDoc, input and
pacing. It stays trigger-started, after the first game and before 3D. No document may call
Linux a supported *desktop* platform until M18 proves it.

**The number is 16.5 so nothing is renumbered.** Records across the repository name M17 as
release certification and M18 as the Linux desktop; both keep those meanings.

**Infrastructure stays the owner's.** The VM is the owner's, created and deleted by them. As
in M16, every public listener and firewall change needs the owner's explicit yes at the time.
Only disposable test credentials are used, and no address, key or account detail is
committed.

## Consequences

* **The first game's server platform is proven before the game needs it**, and before M17
  freezes a release. A POSIX socket fault, a TLS entropy difference or a timing assumption
  that only Linux breaks is found now, in a small milestone, not during the game's launch.
* **M18 gets smaller and keeps its meaning.** Its remaining work is exactly the desktop, and a
  Linux fault that M18 finds is then a windowing, driver or input fault, not a networking one.
* **Documents need a precise sentence, not a looser one.** "Linux x64: headless and server
  runtime proven (M16.5); desktop build-checked until M18" is allowed. "Linux supported" is
  not.
* **Cost.** One small VM for a few hours, owner-operated. The Mac-side verification needs no
  new tools. The VM installs only the pinned Zig and fetches the repository's pinned
  dependencies. It gets no Vulkan SDK, no package-manager toolchain and no compiler beyond
  Zig's.
* **One more thing to keep working.** The Linux headless graph now has a runtime claim to
  lose. It is not added to every commit's bar, because the bar runs on the Mac. A Linux run is
  due when `platform`'s transport, `net` or the headless loop changes, and at each milestone
  close before M18.

## Alternatives considered

* **Wait for M18, as ADR-0039 has it.** Nothing forces it earlier except the owner's request.
  But the game's servers would then first run on Linux in production, or be forced onto
  Windows VMs, which cost more and are less common to operate. The request is in the game's
  path, so waiting was not chosen.
* **Do all of Linux now, on a GPU cloud instance with a virtual display.** It costs about
  twenty times as much per hour. A cloud GPU behind a virtual framebuffer is also not the
  desktop a player runs, so it would claim desktop coverage it has not earned. Rejected. M18
  keeps the real desktop.
* **Use the owner's PC with a second-drive Linux install.** This was ADR-0039's recorded
  route, and it remains M18's. It needs an installation the owner has not made, and it would
  not test a cloud host, which is what a server is.
* **Use an ARM (Graviton) VM.** It is cheaper, but it is not a Foundry target: ADR-0008 names
  x86_64 Linux. Rejected. An ARM Linux server target would need its own decision.
* **Fold it into M17.** M17 is the last, credential-gated release milestone. By the roadmap,
  a postponed item becomes its own milestone, not an addition to another.

## Revisit if

* The first game decides its servers run on something other than Linux x64.
* M18 begins, at which point M16.5's claim is re-run on the desktop machine, not assumed.
* A Linux headless fault appears that only a desktop install reproduces. That would mean the
  split drew its line in the wrong place.
* An ARM or other Linux server target is wanted.
