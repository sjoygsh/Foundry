Foundry Editor — preview
========================

The Foundry content editor, for authoring a content package: its manifest, records and
fields, and the compiled .fpk a game or a mod loads. It is an unsigned preview.

Start it
--------

  macOS:    double-click bin/foundry-editor (it opens in Terminal). The first time,
            macOS refuses an unsigned download: go to System Settings > Privacy &
            Security and choose Open Anyway, then double-click it again.
  Windows:  double-click bin\foundry-editor.exe. When "Windows protected your PC"
            appears, choose More info > Run anyway. It needs a Vulkan 1.3 GPU driver.

With no arguments it opens a workspace beside itself and creates what it needs:

  workspace/my-package/          your package's source (.fdt files)
  workspace/work/                private build output
  workspace/export/my-package.fpk   what Export writes

To edit another package, name every folder yourself:

  bin/foundry-editor --source <package-dir> --output <work-dir> \
      --dependency content/core.fpk [--export <file.fpk>]

  bin/foundry-editor --help      lists every option

What else is here
-----------------

  content/core.fpk      Foundry's base package, which every package depends on
  include/foundry.h     the public C ABI, for native mods and outside tools
  LICENSE, NOTICE, THIRD_PARTY_NOTICES.txt  what you may do with it

Guides: https://github.com/sjoygsh/Foundry/tree/main/docs
  docs/modding/editor.md          using this editor
  docs/modding/content-mods.md    writing .fdt by hand
  docs/GETTING_STARTED.md         making a game with Foundry
