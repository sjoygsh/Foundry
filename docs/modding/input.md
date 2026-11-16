# Input mods

**Status:** works as of M45 Step 7. A content mod can declare an action and add it to a game's
context. A native mod can then read that action, the keyboard, the mouse and gamepads through the
eleven read-only calls `FoundryApi_v8` adds (275 in all). Script mods have no input calls yet
(M49). Enabling contexts, writing bindings, capture, rumble and audio outputs are not published:
each changes what a player experiences, and each waits for a host grant (M48).

This page was written from a mod built **outside** the Foundry checkout, against an installed
`foundry.h` and nothing else. Every command below was run, and every listing is the file that
ran. The header is the contract; the design is [`design/input.md`](../design/input.md) and
ADR-0087 to ADR-0090. Read [`native-mods.md`](native-mods.md) first: this page only adds what is
specific to input.

## What you build

One package, `pulse`, with two halves:

* **content:** one button action, `pulse:action.pulse`, in the sandbox's own context;
* **native, with the player's consent:** a system that says on which tick the action was pressed
  and released, and where the player has it bound.

```
pulse/
  package/
    mod.fdt
    pulse.fdt
  pulse.c
  install/               # written by the commands below
```

## Before you start

You need an installed Foundry and the pinned Zig 0.16.0, which is also the C compiler.

```sh
cd /absolute/path/to/Foundry
zig build install -Drhi=metal --prefix /absolute/path/to/runtime
FOUNDRY=/absolute/path/to/runtime
```

This page's run used `-Dplatform=null -Drhi=null` instead, so it could press a pad's button
from a script with no window (step 3). The commands are otherwise the same.

## 1. The content half

`package/mod.fdt`:

```fdt
foundry:mod pulse:content {
    name     "Pulse"
    version  1
    license  "MIT"
    summary  "An action of its own, read from C through FoundryApi_v8."
    requires [ { id sandbox3d:content } ]
    native   "pulse"
    abi      { min 8 max 8 }
}
```

`package/pulse.fdt`:

```fdt
# One button, in the sandbox's own context: U on the keyboard, north on a pad.
foundry:input_action pulse:action.pulse {
    kind     "button"
    contexts [ sandbox3d:context.play ]
    bindings [ { source "key.u" } { source "pad.north" } ]
}
```

**An action names its contexts**, so a mod adds one to a game's context without overriding the
game's record. What you may write:

* `kind`: `"button"`, `"axis"`, `"vector"` or `"delta"`. String fields are quoted.
* `contexts`: one to four `foundry:input_context` records. Which are enabled is the game's
  choice; an action in no enabled context reads as rest.
* `bindings`: up to eight. Each has a `source` and optionally `axis` (`"x"` or `"y"`, for a
  vector), `scale` (default 1), `threshold` (0.5, where an axis becomes a button) and `deadzone`
  (0.15, in [0, 0.95]).
* `rebindable`: default true.

Sources are named by **physical position**, as on a US QWERTY keyboard and an Xbox-style pad:
`key.w`, `key.left_shift`, `mouse.left`, `mouse.motion`, `mouse.wheel`, `mouse.wheel_up`,
`pad.south`, `pad.left_x`, `pad.left_stick`. A source this engine does not know is skipped with a
warning and the rest kept; a record wrong in a way it does understand is refused whole, by name,
when `fpack` compiles it. A button may be fed by buttons or by an axis past its threshold; a delta
only by `mouse.motion` and `mouse.wheel`.

Compile it against the packages it names:

```sh
mkdir -p install/pulse
"$FOUNDRY/bin/fpack" --out install/pulse.fpk --assets-out install/pulse \
    --dependency "$FOUNDRY/content/core.fpk" \
    --dependency "$FOUNDRY/content/sandbox3d.fpk" \
    package
```

```
fpack: pulse:content version 1 -> install/pulse.fpk (1156 bytes)
```

## 2. The native half

`pulse.c`:

```c
#include "foundry.h"
#include <stdio.h>
#include <string.h>

static const FoundryApi_v8 *api;
static FoundryMod self_mod;
static FoundryContentId pulse;
static uint64_t presses, held_ticks;

static FoundryContentId id(const char *s) { return foundry_content_id(s, strlen(s)); }
static FoundryStr str(const char *s)
{
    FoundryStr out;
    out.ptr = (const uint8_t *)s;
    out.len = strlen(s);
    return out;
}
static void say(const char *text) { (void)api->log_write(self_mod, FOUNDRY_LOG_INFO, str(text)); }

/* Once a fixed tick. Inside a system every input call answers this tick's view, so a press
 * is seen here exactly once, whatever the frame rate. */
static void watch(void *ctx, const FoundryStep *step)
{
    FoundryActionState state;
    FoundryKeyboardState keys;
    char line[128];
    (void)ctx;
    if (api->input_action(pulse, &state) != FOUNDRY_OK) return;
    if (state.pressed) {
        ++presses;
        held_ticks = 0;
        (void)snprintf(line, sizeof line, "pulse: pressed on tick %llu (press %llu)",
                       (unsigned long long)step->tick, (unsigned long long)presses);
        say(line);
    }
    if (state.held) ++held_ticks;
    if (state.released) {
        /* The keyboard as this tick saw it: was a shift key down at the release? */
        int shift = api->input_keyboard(&keys) == FOUNDRY_OK && (keys.modifiers & FOUNDRY_MODIFIER_SHIFT);
        (void)snprintf(line, sizeof line, "pulse: released on tick %llu after %llu ticks held%s",
                       (unsigned long long)step->tick, (unsigned long long)held_ticks,
                       shift ? ", shift down" : "");
        say(line);
    }
}

/* Where the player has the action, in words they can read on their own keyboard. */
static void describe(void)
{
    FoundryBinding binding;
    FoundryStr label;
    uint32_t count = 0, i, key;
    char line[128];
    if (api->input_action_binding_count(pulse, &count) != FOUNDRY_OK) return;
    for (i = 0; i < count; ++i) {
        FoundryStr rest;
        if (api->input_action_binding(pulse, i, &binding) != FOUNDRY_OK) continue;
        /* A binding's source is borrowed until the next input_action_binding: use it now. */
        if (binding.source.len > 4 && memcmp(binding.source.ptr, "key.", 4) == 0) {
            rest.ptr = binding.source.ptr + 4;
            rest.len = binding.source.len - 4;
            if (api->input_key_from_name(rest, &key) == FOUNDRY_OK &&
                api->input_key_label(key, &label) == FOUNDRY_OK) {
                (void)snprintf(line, sizeof line, "pulse: binding %u is the key labelled '%.*s'%s",
                               i, (int)label.len, (const char *)label.ptr,
                               binding.overridden ? " (the player's)" : "");
                say(line);
                continue;
            }
        }
        (void)snprintf(line, sizeof line, "pulse: binding %u is %.*s", i, (int)binding.source.len,
                       (const char *)binding.source.ptr);
        say(line);
    }
}

FOUNDRY_EXPORT FoundryResult foundry_mod_init(FoundryGetApi get_api, FoundryMod self)
{
    FoundrySystemDesc system;
    FoundryBool on = FOUNDRY_FALSE;
    uint32_t slots = 0;
    FoundryResult result;

    self_mod = self;
    presses = held_ticks = 0;
    api = (const FoundryApi_v8 *)get_api(FOUNDRY_API_VERSION_8);
    if (api == NULL || api->version != 8 || api->size != sizeof(*api)) return FOUNDRY_ERR_UNSUPPORTED;
    pulse = id("pulse:action.pulse");

    /* A host may run mods without lending them input: every input call then answers
     * FOUNDRY_ERR_UNAVAILABLE, and this mod has nothing to do. */
    result = api->input_gamepad_slots(&slots);
    if (result == FOUNDRY_ERR_UNAVAILABLE) {
        say("pulse: this host publishes no input");
        return FOUNDRY_OK;
    }
    if (result != FOUNDRY_OK) return result;

    describe();
    /* Which contexts are enabled is the game's choice; a mod can only ask. */
    if (api->input_context_enabled(id("sandbox3d:context.play"), &on) == FOUNDRY_OK && !on)
        say("pulse: the sandbox's context is off; the action will read as rest");

    memset(&system, 0, sizeof(system));
    system.id = id("pulse:systems.watch");
    system.name = str("pulse:systems.watch");
    system.update = watch;
    result = api->world_register_system(self, &system);
    if (result != FOUNDRY_OK) return result;
    say("pulse: watching");
    return FOUNDRY_OK;
}
```

Build it into the package's own directory:

```sh
# macOS
zig cc -std=c99 -pedantic -Wall -Wextra -Werror -fPIC -dynamiclib \
    -I"$FOUNDRY/include" -o install/pulse/libpulse.dylib pulse.c
# Windows, from any host
zig cc --target=x86_64-windows-gnu -std=c99 -pedantic -Wall -Wextra -Werror -shared \
    -I"$FOUNDRY/include" -o install/pulse/pulse.dll pulse.c
# Linux, from any host
zig cc --target=x86_64-linux-gnu -std=c99 -pedantic -Wall -Wextra -Werror -fPIC -shared \
    -I"$FOUNDRY/include" -o install/pulse/libpulse.so pulse.c
```

All three compile, and the file compiles unchanged as C++17.

## 3. Run it

Put the package where the sandbox finds it: a player's `mods` directory, as
[`3d.md`](3d.md) describes, or the install's own `content/`, which is what this run used. Then
select it and consent to its code:

```sh
cp -R install/. "$FOUNDRY/content/"
cd "$FOUNDRY"
FOUNDRY_SANDBOX3D_PACKAGES=pulse:content FOUNDRY_SANDBOX3D_NATIVE=pulse:content ./bin/sandbox3d
```

Press U. This page's headless run pressed a pad's north button instead, from a script, with
`FOUNDRY_SANDBOX3D_FRAMES=240 FOUNDRY_SANDBOX3D_SPIN=40-160` added. The press came through the
platform's own pad path, the snapshot, the action and the tick view, like a real pad's:

```
info(mod): [pulse:content] pulse: binding 0 is the key labelled 'u'
info(mod): [pulse:content] pulse: binding 1 is pad.north
info(mod): [pulse:content] pulse: watching
info(sandbox3d): spin: north down at frame 40 (window not focused, pad seated)
info(mod): [pulse:content] pulse: pressed on tick 3 (press 1)
info(sandbox3d): spin: north up at frame 160 (window not focused, pad seated)
info(mod): [pulse:content] pulse: released on tick 10 after 7 ticks held
```

The headless platform has no layout, so a label is the key's own name. A windowed run asks the
layout instead: on the Mac this was written on, the sandbox's own `orbiter` mod reported its key
`key.o` as `O`. On a French keyboard the key in an AZERTY place gives the letter printed there.

## 4. How the input calls work

**As the tick sees it.** A frame's input is seen by every fixed step in that frame, and by none
when a frame runs no step. So inside a system's callback every input call answers the step's own
view: a press, a release or a mouse delta reaches exactly one step, the first after it happened,
and later steps in the frame see only what is held. Anywhere else, such as in
`foundry_mod_init`, a call answers the frame's view. Counting presses in a system therefore gives
the same count at 30 and at 240 frames a second.

**Read-only.** You can read the keyboard, the mouse, each gamepad slot, an action's state, its
effective bindings and whether a context is enabled. You cannot enable a context, rebind, capture
the next key, rumble a pad or learn the audio outputs. Those are M48's, by a grant the host
gives.

**Local input is still local.** A networked game carries input as commands (ADR-0044). The table
cannot enforce that, so a mod that steers a shared simulation from a key is wrong in a way only
its author can see.

The calls:

| Call | Answers |
| --- | --- |
| `input_keyboard` | `held`, `pressed`, `released` as four 64-bit words each, by `FoundryKey` number; `FOUNDRY_MODIFIER_*` bits; `focused` |
| `input_key_from_name`, `input_key_name` | the stable names both ways (`"left_shift"`); `NOT_FOUND` for an unknown name |
| `input_key_label` | what the player's layout prints on that key; empty for `FOUNDRY_KEY_UNKNOWN`; borrowed until the next call |
| `input_mouse` | position in points and pixels, motion and its `FoundryMotionUnit`, the wheel in notches, buttons as `FoundryMouseButton` bits, `captured` |
| `input_gamepad_slots` | how many slots there are, 4 today |
| `input_gamepad` | one slot: `connected`, `FoundryPadKind`, a `generation` that changes when another pad sits there, buttons as `FoundryPadButton` bits, six axes (sticks +y up), and the four face labels |
| `input_action` | `held`, `pressed`, `released`, `kind` and the value; `NOT_FOUND` for an action no content declares |
| `input_action_binding_count`, `input_action_binding` | the bindings in force, the player's where they rebound it, and whether that override applies; the source name is borrowed until the next call |
| `input_context_enabled` | whether the game has a context enabled; `NOT_FOUND` for one no content declares |

**Every refusal is a result code.** A null out-pointer is `FOUNDRY_ERR_INVALID_ARGUMENT` on any
host, a key number past `FOUNDRY_KEY_MENU`, a slot past the count or a binding index past the
count is the same, and a host that lent no input answers `FOUNDRY_ERR_UNAVAILABLE` to every
call. A key number is a key's place, and the numbers never change: the header writes each one
out. Bit `n % 64` of word `n / 64` is key `n`.

**Bind by action, not by key.** Reading a key directly ignores what the player chose. Declare an
action, read the action, and show its binding's label: then a player who rebinds it, and a player
on another layout, see a prompt that is true for them.
