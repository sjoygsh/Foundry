# Third-party licenses

Every third-party component Foundry uses is recorded here, one file per dependency.

**Rule: a dependency and its license entry land in the same commit.** No exceptions. A
dependency added "temporarily" without an entry is how a project ends up unable to answer
what it is actually shipping.

This exists from the beginning deliberately. Foundry will eventually depend on a platform
library, a graphics loader, image codecs, audio codecs, a font rasterizer, a physics
library and a scripting runtime. Reconstructing that provenance afterwards is genuinely
painful; maintaining it as you go costs a few minutes per dependency.

## Current dependencies

None yet. SDL3 will be the first.

## What to record

Create `THIRD_PARTY_LICENSES/<name>.md` using this template:

```markdown
# <Name>

- **Version:** <exact version or commit hash>
- **Upstream:** <URL>
- **License:** <SPDX identifier>
- **Distribution:** distributed | build-time only
- **Location in tree:** <path, or "fetched via build.zig.zon">
- **Why we depend on it:** <one or two sentences>
- **Modifications:** none | <description, and where the patch lives>

## License text

<full verbatim license text>
```

**Distributed vs. build-time only matters.** A library linked into the shipped binary must
appear in the attribution file we distribute. A build-time tool (a code generator, a build
script package) must still be recorded here, but does not need to appear in shipped notices.
Mark it correctly; the distinction is what the generated notice file keys off.

## License compatibility

Foundry is **Apache-2.0**. That constrains what we may depend on.

**Acceptable** — permissive, compatible, no distribution burden beyond attribution:

`Apache-2.0` · `MIT` · `BSD-2-Clause` · `BSD-3-Clause` · `ISC` · `Zlib` · `0BSD` ·
`Unlicense` · `CC0-1.0` · public domain

**Not acceptable without an explicit, discussed decision:**

* **`GPL-2.0` / `GPL-3.0` / `AGPL`** — would force Foundry itself to be relicensed. Never
  link these. This is the one that ends projects.
* **`LGPL`** — permits dynamic linking only, which conflicts with static linking and with
  most console and storefront distribution models. Avoid.
* **Anything with a field-of-use, non-commercial or "no military use" restriction** — these
  are not open source and create obligations we cannot pass on to game and mod authors.
* **Unlicensed / no license file** — legally means nobody may use it, including us.

**Known traps, recorded before we hit them.** These come up specifically in game engines:

| Area | Safe | Trap |
| --- | --- | --- |
| Audio codecs | Ogg/Vorbis/Opus (BSD), `dr_libs`, `stb_vorbis` | **FFmpeg** (LGPL or GPL depending on build), **libmp3lame** (LGPL) |
| Fonts | `stb_truetype` (public domain) | **FreeType** — dual FTL/GPLv2; the FTL is usable but carries mandatory attribution |
| Images | `stb_image`, libpng, zlib, libjpeg-turbo | Some newer codec reference implementations carry patent grants worth reading |
| Physics | Box2D (MIT), Jolt (MIT), Bullet (Zlib) | ODE is dual BSD/LGPL — pick the right one deliberately |
| Scripting | Lua (MIT), wasmtime (Apache-2.0 w/ LLVM exception), wasm3 (MIT) | Some JS engines are LGPL |

When a dependency is proposed, check its license **before** evaluating it technically.
Discovering the license after falling in love with the library is how bad decisions happen.

## Content and asset licenses

Fonts, textures and sounds shipped in `content/` have licenses too, and they are frequently
*more* restrictive than code licenses. Record them here the same way.

This connects forward to modding: content package manifests (M7) should carry a license
field, so that mod authors can state their terms and so that redistributing a mod pack is a
tractable question rather than a guess.

## Shipped attribution

At packaging (M9), an aggregated `THIRD_PARTY_NOTICES.txt` is generated from the entries in
this directory marked `distributed` and included in every build. It is generated, never
hand-maintained — a hand-maintained notice file drifts within two releases.
