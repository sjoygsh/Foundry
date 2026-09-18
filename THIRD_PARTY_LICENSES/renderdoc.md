# RenderDoc

- **Version:** 1.46, the portable `RenderDoc_1.46_64.zip` (SHA-256
  `9ca4d09ecaba2cc791168660d6fc2a7e3d70fe67146e87ec05c5f8dea70772f7`), built from commit
  `e4bd23b671d3d5a747ff5221dbe08a63eb6ca200`; its binaries carry a valid Authenticode signature
  from Baldur Scott Karlsson
- **Upstream:** https://renderdoc.org (source: https://github.com/baldurk/renderdoc)
- **License:** `MIT` for RenderDoc itself; its Windows archive also bundles third-party
  libraries under their own licenses, see the note below.
- **Distribution:** build-time only — a frame-capture tool run by hand on the developer's Vulkan
  target; nothing is fetched by the build, linked, loaded by an ordinary run or shipped.
- **Location in tree:** not in tree; unpacked from the archive on the target (see `AGENTS.md`).
- **Why we depend on it:** M13 verifies the Vulkan backend by capturing a real frame and
  inspecting a sprite draw's bindings, constants, vertices and target (`vulkan.md` §10,
  ADR-0038).
- **Modifications:** none.

## Note on the bundled libraries

RenderDoc's own code is MIT. Its Windows archive also carries what its UI and replay need,
among them Qt 5 and PySide2 (LGPL-3.0), an embedded Python 3.8 (PSF), OpenSSL 1.1, Microsoft's
`d3dcompiler_47`, `dbghelp` and `symsrv`, and AMD's GPU libraries, each under its own terms and
credited upstream. None of it reaches Foundry. The tool runs as its own process, or as a
Vulkan layer loaded only into a process a developer starts under it; Foundry's build never
fetches or links it and no artifact contains it. ADR-0016's rule against LGPL governs what
Foundry links or distributes; a separate development tool is recorded here for provenance, as
glslang's GPL-licensed parser skeleton is.

## License text

# The MIT License (MIT)

Copyright (c) 2015-2026 Baldur Karlsson

Copyright (c) 2014 Crytek

Copyright (c) 1998-2018 [Third party code and tools](docs/credits_acknowledgements.rst)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
