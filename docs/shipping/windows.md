# Shipping on Windows

**Status:** M17, 2026-09-23. Windows releases are **unsigned previews**
([ADR-0047](../adr/0047-unsigned-github-preview-release.md)). Code signing waits, with macOS
notarization, for a fully playable 3D game.

## Building a release

On a Windows x64 machine with the pinned Zig and Vulkan SDK (AGENTS.md §3):

```powershell
zig build dist -Dapp=room    -Dplatform=sdl3 -Drhi=vulkan -Doptimize=ReleaseSafe -Drevision=<commit>
zig build dist -Dapp=sandbox -Dplatform=sdl3 -Drhi=vulkan -Doptimize=ReleaseSafe -Drevision=<commit>
```

Each writes the staged folder and `<Product>-windows-x64.zip` under `zig-out/dist/<app>/`.
Staging is native: it runs the content compiler, so it cannot be cross-built from a Mac
(`distribution.md` §8). The archive is written by Windows' own `tar.exe`, as macOS uses
`ditto`, so no archiver is added to the build.

## What is in it

```text
Foundry Room/
  bin/room.exe                 the program, statically linked apart from Windows' own DLLs
  content/core.fpk, room.fpk   the packages, and the files their records name
  LICENSE  NOTICE  THIRD_PARTY_NOTICES.txt
  inventory.txt                every path, size and SHA-256, with version and revision
```

It is relocatable: run it from anywhere, including a read-only folder. User data and logs go
under `%APPDATA%\foundry-<app>`. No installer is needed and none is provided.

## What a player needs, and sees

* **A Vulkan 1.3 driver,** which current Intel, AMD and NVIDIA drivers provide. It is tested
  on one Intel Arc A750 so far.
* **The SmartScreen warning.** The file is unsigned, so the first launch shows "Windows
  protected your PC". Choose **More info → Run anyway**. Unsigned files do not build
  SmartScreen reputation, so every new version warns.
* **Check the download** against the SHA-256 listed on the release page:
  `Get-FileHash "Foundry Room-windows-x64.zip"`.

## Clean-machine check

Before each release, the archive is extracted and run on a Windows machine with no Foundry,
Zig or Vulkan SDK present. Such a machine has only the GPU driver's Vulkan loader, and any
overlays (Steam, RivaTuner) a player would have. The published file is then downloaded through
a browser, so it carries the Mark of the Web, and opened by the documented steps.
