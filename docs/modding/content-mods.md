# Content mods

Everything here works today, against the sandbox. It was written by doing it.

A content mod is a directory. You compile it into one file, put that file where the game
looks, and name it in the load order. There is no manifest, no registration, and no code.

---

## 1. What a package is

A directory containing:

* **`.fdt` files** — records, in Foundry's authoring text format.
* **assets** — `.png` files today; more kinds later. Any layout you like.

Anything else in the directory is ignored, and names beginning with `.` are skipped, so
`.git` and your editor's swap files cost you nothing.

## 2. Your first mod

```
mymod/
  changes.fdt
```

```fdt
# changes.fdt — everything after '#' is a comment.

# The record type. A package carries every schema its records use, so this one is
# yours to declare — copy it from the package you are modifying.
@schema sandbox:clip {
    sheet   id
    columns u32
    rows    u32
    first   u32 (default 0)
    count   u32
    hold    u32 (default 6)
    loops   bool (default true)
}

# Overriding a record: name the same content id, and yours wins if your package is
# loaded after theirs. This one is the sandbox player's walk animation, moved to a
# different row of the sheet and run three times faster.
sandbox:clip sandbox:clip.walk {
    sheet   sandbox:textures.sprites
    columns 4
    rows    4
    first   12
    count   4
    hold    2
}
```

**Note the schema name is spelled in full.** A bare `clip` would mean `mymod:clip` — a
schema written without a namespace belongs to the package it is written in — and that is a
different record type from the one you are trying to override.

Compile it:

```sh
zig build fpack -- --name mymod:changes --out zig-out/content/mymod.fpk mymod
```

`--name` is your package's own content ID. Pick a namespace nobody else will use — it is
what keeps your record types from colliding with someone else's.

Then load it. The sandbox reads a list from the environment; a real game will have a mod
manager, and does not yet:

```sh
FOUNDRY_SANDBOX_PACKAGES=mymod zig build run -Drhi=metal
```

The sandbox loads `foundry:core`, then its own package, then yours. Walk the player around
with WASD: the animation is a different colour and three times faster, and nothing was
rebuilt but your mod.

**Overriding replaces the whole record**, so every field you want has to be in yours — a
field you leave out takes its schema default, it does not keep the original's value. §4 says
what that means in general.

## 3. Names

A content ID is `namespace:name`:

```
foundry:item.torch
sandbox:textures.sprites
mymod:changes
```

Both halves are lowercase ASCII: `[a-z][a-z0-9_]*`, with `.` separating segments in the
name. Nothing is normalised — not case, not whitespace, not Unicode. `Torch` is not
`torch`; it is an error. That is deliberate: normalisation would be a second specification
every external mod tool would have to reimplement identically, and any divergence would
produce IDs that differ invisibly.

Inside a file, an ID with no namespace takes the document's own. Writing the namespace out
always works and is clearer when you mean somebody else's:

```fdt
sandbox:settings sandbox:settings.main { ... }   # explicit, and always correct
```

## 4. Overriding

**Name the same content ID.** That is the whole mechanism.

* A record you define replaces one from an earlier package, completely.
* Later in the load order wins.
* Your record must use the same record type as the one it replaces. Changing a record's
  type is refused rather than merged, because everything reading it expects a shape.
* Partial edits — change one field, leave the rest — are `@patch`, whose syntax exists and
  whose behaviour does not. Today, write the whole record.

You do not need to know where the original lives, what package it came from, or how its
directory is laid out.

## 5. Assets

An asset is a record like any other, and its identity is its content ID. The file is named
by an ordinary field:

```fdt
foundry:texture foundry:fonts.debug {
    source "whatever/i/like/glyphs.png"
    filter "nearest"
    wrap   "clamp"
}
```

`source` is **relative to your package**, and a path that tries to leave it is refused.
Nothing at runtime can look an asset up by path, so where you keep your files is your
business alone.

**Your files have to travel with your package.** The engine reads an asset's bytes at load,
from a directory named for your package beside the `.fpk` — so a mod with files is two steps
rather than one:

```sh
zig build fpack -- --name mymod:changes --out zig-out/content/mymod.fpk mymod
cp -R mymod zig-out/content/mymod
```

§2's mod needed only the first line because it had no files at all. An ordinary file — a
`.png`, a `.wav` — is read exactly as you wrote it, which is what the copy is for. The one
kind `fpack` *compiles* is a tile grid (§6), and that needs `--assets-out` pointed at the same
directory, so the `.fgrid` lands over the top of the sources:

```sh
zig build fpack -- --name mymod:changes --out zig-out/content/mymod.fpk \
    --assets-out zig-out/content/mymod mymod
```

### Derived IDs

Authoring five thousand sprites must not mean writing five thousand records, so a file with
a known extension becomes a record automatically. Drop the extension, replace each `/` with
`.`, and prefix your namespace:

```
package mymod,  textures/ui/panel.png   ->   mymod:textures.ui.panel
```

Three things to know about it:

* **It transforms nothing.** Every path segment must already be a valid ID segment. A file
  called `Panel-01.png` is an error telling you to rename it or write the ID out — not a
  silent `panel_01`.
* **An authored record wins.** If one of your records already names a file in its `source`,
  no record is derived for it. Explicit beats implicit, and never duplicates it.
* **A derived ID lasts as long as its path.** Moving the file changes the ID. If you want
  one to be permanent, write it out in a record; that is the fix, and it is one line.

`filter` is `nearest` or `linear`; `wrap` is `clamp` or `repeat`. Both are optional and
default to `nearest` and `clamp`. A spelling neither of them recognises is a warning naming
what is legal, and the default is used — a typo should not make your texture disappear.

## 6. Maps

A tilemap is three records over one asset, and the split is what makes it moddable in pieces.

```fdt
foundry:tileset mymod:tiles.cave {
    texture mymod:textures.cave      # a foundry:texture, by ID
    tile    [ 16 16 ]                # pixels per tile in that image
    columns 16                       # tiles per row in it
    solid   [ 1 2 3 ]                # which tile IDs block. Everything else is floor.
}

foundry:tilemap.layer mymod:map.cave.walls {
    tileset  mymod:tiles.cave
    grid     mymod:grids.cave        # the numbers, as an asset
    order    0                       # draw order: lower is further back
    collides true
    empty    0                       # optional: this ID draws nothing at all
}

foundry:tilemap mymod:map.cave {
    size   [ 40 30 ]                 # cells
    cell   [ 16 16 ]                 # world units per cell
    layers [ mymod:map.cave.walls ]
}
```

**The numbers live in a `.grid` file, not in your `.fdt`.** A map is thousands of integers,
and a thousand integers in a content file is a binary payload wearing a disguise. Write it
the way it looks:

```
# grids/cave.grid
1 1 1 1
1 0 0 1
1 1 1 1
```

Whitespace separates, `#` runs to the end of the line, and every row needs the same number of
columns as the first. **The top row here is the top row on screen** — the compiler flips it,
because in world space Y points up.

`fpack` compiles it to `grids/cave.fgrid` and derives `mymod:grids.cave` from the path, by the
same rule §5 gives. You never name either filename anywhere else.

**Layers stack, and `empty` is how they see through each other.** A map's `layers` list is in
draw order and each layer carries its own `order`, so a floor at `-10` and the props on it at
`0` need no code to decide which is on top. A layer drawn over another one wants `empty` — the
tile ID meaning *nothing here* — or it paints an opaque rectangle over everything below. Leave
it out on the bottom layer: absent means every ID draws, and tile 0 is usually your ground.

**`collides` is a per-layer answer, and it is separate from what a layer looks like.** A layer
that says `collides true` becomes solid geometry, using its tileset's `solid` list to decide
which of its tiles block; a layer that leaves it out is drawn and walked straight through. So a
decoration pass over the same grid is a second layer that simply does not claim to collide, and
a collision-only layer — solid tiles that draw nothing, using `empty` — is the same trick the
other way round. Neither needs code to exist.

**Where a map sits is the game's, not yours.** `foundry:tilemap` says how big a map is and how
big a cell is. It does not say where in the world it goes, because a world holds many maps in
many places and placing them is what the game does with them.

**Three things you can change without owning the map.** Making water solid is one line in
somebody else's `foundry:tileset`, overridden by ID. Replacing the art is overriding a
`foundry:texture`. Adding a layer to one map is overriding one `foundry:tilemap`. None of them
means restating the map, and that is why these are three records and not one.

## 7. Animations

A sprite that animates is a **clip**: a run of cells from a sheet, and how long each is held.
The sandbox's looks like this, and yours will look like whatever the game you are modding
declared — there is no engine-wide clip type yet, deliberately.

```fdt
@schema sandbox:clip {
    sheet   id
    columns u32
    rows    u32
    first   u32 (default 0)
    count   u32
    hold    u32 (default 6)
    loops   bool (default true)
}

sandbox:clip sandbox:clip.walk {
    sheet   sandbox:textures.sprites
    # The sheet read as a grid of cells, and the run this clip plays, row-major from
    # `first`. Cell 4 of a four-column sheet is the start of the second row.
    columns 4
    rows    4
    first   4
    count   4
    # Ticks each frame is held. The simulation runs at 60 Hz, so 6 is ten frames a second
    # and 2 is thirty.
    hold    6
    loops   true
}
```

**Retiming and reskinning are both one override.** Change `hold` and the animation runs
faster or slower; change `sheet` and `first` and it plays from somewhere else entirely.
Neither needs code, and neither changes anything but what is on screen — an override that
made the character move differently would be a bug in the game, not a feature of the format.

**Timing is in ticks, not seconds, and that is on purpose.** The frame showing at any moment
is `elapsed / hold`, computed in whole numbers, so it is the same on a fast machine and a slow
one, the same in a replay, and the same after a save is reloaded. A `hold` of zero is a
mistake rather than an instant animation: the clip shows its first frame and stays there.

**A run that leaves the sheet shows nothing.** If `first + count` reaches past the last cell,
the frames past the end draw as empty rather than as whatever is next to them — in a packed
atlas, "next to them" is somebody else's sprite. An animation that disappears partway through
is this, and the fix is in `first`, `count`, `columns` or `rows`.

**Which clip plays is the game's**, the same way where a map sits is the game's. The sandbox
names its walk and idle clips in `sandbox:settings.main`, so pointing the player at a
different clip is an override of that record; a game with a proper character sheet will have
somewhere better to say it. What you can always do without owning any of that is change the
clip the game already names.

## 8. Sounds

**A `.wav` is an asset like any other**, so the shortest sound mod is a file:

```
mymod/
  drone.wav
```

That derives `mymod:drone` by §5's rule, and a game that lets you name a sound in content
can be pointed at it with no `.fdt` at all. Replacing a sound the game already has is one
record:

```fdt
foundry:sound sandbox:sounds.hum {
    source "drone.wav"
}
```

`foundry:sound` is the engine's record type, so you do not declare it — the same as
`foundry:texture` and `foundry:tileset`. `source` is relative to your package, and the file
can be called and filed however you like: nothing at runtime looks a sound up by path.

**Overriding works even when the original had no record.** The sandbox's `sounds/hum.wav`
was never written down anywhere; its id was derived from its path. Yours names the same id
and wins, and the file it points at is yours.

### What the engine will play

| Accepted |
| --- |
| PCM, 8-bit unsigned or 16-, 24- or 32-bit signed |
| IEEE float, 32-bit |
| `WAVE_FORMAT_EXTENSIBLE` wrapping either of those |
| Mono or stereo |

**Anything else is refused with a sentence naming what your file actually is** — ADPCM,
mu-law and A-law included. That is deliberate: a mod author gets told to transcode rather
than left with silence. So is the distinction between a file that is *corrupt* and one that
is merely *unsupported*: the second one is fine and just needs converting.

Two more refusals worth knowing:

* **A NaN or an infinity in a float WAV refuses the whole file.** This is stricter than the
  image path, which prefers a wrong-looking sprite to a missing one, and the asymmetry is
  on purpose: one non-finite sample silences *everything* for the rest of the session,
  which is the least diagnosable failure audio has.
* **Any sample rate is fine**, and it does not have to match the device's. A voice
  resamples as it plays, which is the same machinery that plays a sound at a different
  pitch, so a 22 kHz file and a 48 kHz one both work and neither is converted at load.

### Loops

Whether a sound loops is the *game's* decision, not the file's — there is no loop flag in a
`foundry:sound`. What is yours is making a loop that does not click: end the file at the
same point in the waveform it started at. A tone whose frequency completes a whole number
of cycles inside the file wraps silently; one that does not puts a click on every pass, and
no amount of engine is going to hide it.

## 9. Hot reload

In a development build the engine watches what it loaded. Recompile your package, or just
save an image, and the running program picks it up at the start of the next frame:

```sh
zig build fpack -- --name mymod:changes --out zig-out/content/mymod.fpk mymod
```

Two rules worth relying on:

* **A failed reload changes nothing.** A package caught mid-save, or a `.fdt` with a typo,
  leaves the running program with the last thing that worked and tells you what was wrong.
  You never get a hole.
* **Never mid-frame.** Changes are applied at the start of a frame, before anything draws.

One limit: **changing a schema in place is refused** unless you bump its version. Two
packages declaring the same record type at the same version must agree about it, or nothing
could read either one's records. Add a field, raise the version, give the field a default —
content written against the old version keeps working, which is what versioning is for.

## 10. Types

The list is closed. There are no others, on purpose: every type costs three implementations
that have to agree, and a type that reaches a compiled package can never be removed.

| Type | Written as |
| --- | --- |
| `bool` | `true` / `false` |
| `i32` `i64` `u32` `u64` | `42`, `-7`, `0xFF` |
| `f32` `f64` | `1.5`, `-0.25` |
| `string` | `"text"`, with `\"` `\\` `\n` `\r` `\t` `\u{...}` |
| `id` | a bare `namespace:name` token |
| `[T]` | `[1 2 3]` |
| `{ ... }` | `{ r 1.0  g 0.5  b 0.0 }` — named fields with no identity of their own |

An inline struct composes, which is why there is no colour type and no vector type. Anything
a mod might want to override *on its own* should be a record with a content ID instead;
that choice is the most consequential one a schema author makes.

## 11. When something is wrong

`fpack` prints the file, the line, the column and the line itself with a caret under the
problem. It reports every mistake it can rather than stopping at the first, and it exits
non-zero.

At runtime, a failure names the content ID and distinguishes between kinds that have
different fixes — an asset that is *missing* is a different sentence from one that is
*corrupt*, and a record that is not the type you asked for is a third. That distinction is
deliberate and tested.

## 12. What this does not cover yet

See [`README.md`](README.md) for the honest list. The short version: no mod manager, no
dependency resolution, no manifests, no partial edits, no scripting, no native mods.
