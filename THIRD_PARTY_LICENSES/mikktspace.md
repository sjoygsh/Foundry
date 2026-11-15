# MikkTSpace

- **Version:** 3e895b49d05ea07e4c2133156cfa94369e19e409
- **Upstream:** https://github.com/mmikk/MikkTSpace
- **License:** Zlib
- **Distribution:** distributed
- **Location in tree:** engine/src/asset/tangents.zig
- **Why we depend on it:** ADR-0086 generates tangents as normal-map bakers and glTF 2.0 do,
  which means MikkTSpace bit for bit.
- **Modifications:** A port of mikktspace.c to Zig, plainly marked as altered in its header,
  limited to triangle lists and the default 180-degree threshold, with allocation failure
  returned as an error instead of the reference's slow fallbacks. No C is compiled into Foundry;
  the unmodified reference is built only by scripts/m41/reference.py to write the test corpus.
  Copyright (C) 2011 by Morten S. Mikkelsen.

## License text

Copyright (C) 2011 by Morten S. Mikkelsen

This software is provided 'as-is', without any express or implied
warranty.  In no event will the authors be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
   claim that you wrote the original software. If you use this software
   in a product, an acknowledgment in the product documentation would be
   appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.
