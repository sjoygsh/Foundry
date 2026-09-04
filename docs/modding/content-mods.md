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
# yours to declare — or it comes from the package you are modifying.
@schema sandbox:settings {
    sprites u32 (default 4000)
    grid    u32 (default 4)
    banner  string (default "")
    sheet   id
    font    id
}

# Overriding a record: name the same content id, and yours wins if your package is
# loaded after theirs.
sandbox:settings sandbox:settings.main {
    sprites 250
    grid    4
    banner  "modded"
    sheet   sandbox:textures.sprites
    font    foundry:fonts.debug
}
```

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

The sandbox loads `foundry:core`, then its own package, then yours. Two of the values it
draws with change, and nothing was rebuilt but your mod.

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

## 6. Hot reload

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

## 7. Types

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

## 8. When something is wrong

`fpack` prints the file, the line, the column and the line itself with a caret under the
problem. It reports every mistake it can rather than stopping at the first, and it exits
non-zero.

At runtime, a failure names the content ID and distinguishes between kinds that have
different fixes — an asset that is *missing* is a different sentence from one that is
*corrupt*, and a record that is not the type you asked for is a third. That distinction is
deliberate and tested.

## 9. What this does not cover yet

See [`README.md`](README.md) for the honest list. The short version: no mod manager, no
dependency resolution, no manifests, no partial edits, no scripting, no native mods.
