# Native mods

**Status:** the native ABI and library lifecycle are implemented in M7. A native mod is a
content package with one optional dynamic library. It is loaded after the package's content
has been merged, receives one `FoundryApi_v1` table, and can register component types and
systems. This is Tier 3: the library is not sandboxed and a faulty mod can crash the host.

This page is an author guide, not a second ABI specification. The installed
[`foundry.h`](../../engine/src/abi/foundry.h) is the contract a C compiler sees; the design
behind it is [`design/public-abi.md`](../design/public-abi.md). The complete example below was
built as C99 against that installed header. It adds content, a component type and a system
whose first update creates and changes an entity.

## Before you start

You need:

* a checkout of Foundry and its pinned Zig 0.16.0 toolchain;
* a C99 compiler. The commands below use the `zig cc` wrapper, so no separate compiler is
  needed; and
* a game host that has opted into native loading. The host discovers and resolves packages,
  builds its engine, binds the subsystems it owns to `abi.Host`, then calls the native loader.
  A content-only host can still load the package's data while skipping its library.

The sandbox is the content-mod reference host. At this point it does not bind a native loader,
so `FOUNDRY_SANDBOX_PACKAGES` alone cannot run the C part of this example. Use a host that
implements the lifecycle in [`design/public-abi.md` §13](../design/public-abi.md#13-the-mod-lifecycle),
or the host's native-mod option when it provides one. This is a host integration choice, not
a different mod format.

## 1. Make the package

The package can live anywhere outside the Foundry checkout. The following layout keeps the
source and the install directory separate:

```
lanterns/
  package/
    mod.fdt
    content.fdt
  install/
    lanterns.fpk
    lanterns/
      liblanterns.dylib       # macOS; liblanterns.so on Linux; lanterns.dll on Windows
  lanterns.c
```

Create `package/mod.fdt`:

```fdt
foundry:mod lanterns:mod {
    name     "Lanterns"
    version  1
    license  "MIT"
    requires [ { id foundry:core } ]
    abi      { min 1 max 1 }
    native   "lanterns"
}
```

`native` is a base name. Do not write `liblanterns.dylib`, a path, or a dot: the host applies
the platform's decoration and opens the resulting file only from the package's own directory.
The manifest's `abi` range is the API-table version, not the Foundry release number.

Create `package/content.fdt`:

```fdt
# The schema is the serialized/content half of the component type.
@schema lanterns:counter {
    value u32
}

# This record is content that controls the native system below.
@schema lanterns:tuning {
    amount u32
}

lanterns:tuning lanterns:config {
    amount 41
}
```

The schema name and every ID are fully qualified. A component registered by native code still
needs a schema in content; the C descriptor supplies only its in-memory size, alignment and
optional construction hooks. A type registered through this ABI is transient in M7: it has no
serializer, `world_component_type_savable` reports false, and `world_read_component` returns
`FOUNDRY_ERR_UNSUPPORTED` for it.

## 2. Write the C library

Create `lanterns.c`:

```c
#include "foundry.h"

static const FoundryApi_v1 *api_v1;
static FoundryMod mod_self;
static FoundryComponentType counter_type;
static uint32_t amount;
static FoundryBool ran;

static void update(void *ctx, const FoundryStep *step)
{
    FoundryEntity entity = {0};
    uint32_t initial;
    void *bytes = NULL;
    uint32_t size = 0;

    (void)ctx;
    (void)step;
    if (ran != FOUNDRY_FALSE) return;
    ran = FOUNDRY_TRUE;

    initial = amount;
    if (api_v1->world_create_entity(&entity) != FOUNDRY_OK) return;
    if (api_v1->world_add_component(entity, counter_type, &initial,
                                    (uint32_t)sizeof(initial)) != FOUNDRY_OK) return;
    if (api_v1->world_component_bytes(mod_self, entity, counter_type,
                                       &bytes, &size) != FOUNDRY_OK) return;
    if (bytes != NULL && size == (uint32_t)sizeof(uint32_t)) {
        /* The content says 41; the system's behaviour makes the component 42. */
        *(uint32_t *)bytes += 1;
    }
}

FOUNDRY_EXPORT FoundryResult foundry_mod_init(FoundryGetApi get_api, FoundryMod self)
{
    const FoundryContentId tuning_id = foundry_content_id("lanterns:config", 15);
    const FoundrySchemaId counter_schema = foundry_schema_id("lanterns:counter", 16);
    const FoundryStr amount_name = {(const uint8_t *)"amount", 6};
    const FoundryStr counter_name = {(const uint8_t *)"lanterns:counter", 16};
    const FoundryContentId system_id = foundry_content_id("lanterns:advance", 16);
    const FoundryStr system_name = {(const uint8_t *)"lanterns:advance", 16};
    FoundryRecord tuning = {0};
    FoundryComponentDesc component = {{0}, {NULL, 0}, 0, 0, NULL, NULL, NULL};
    FoundrySystemDesc system = {{0}, {NULL, 0}, NULL, NULL};
    uint32_t field = 0;
    uint64_t value = 0;
    FoundryResult result;

    api_v1 = (const FoundryApi_v1 *)get_api(FOUNDRY_API_VERSION_1);
    if (api_v1 == NULL) return FOUNDRY_ERR_UNSUPPORTED;
    mod_self = self;

    result = api_v1->content_find(tuning_id, &tuning);
    if (result != FOUNDRY_OK) return result;
    result = api_v1->record_field_index(tuning, amount_name, &field);
    if (result != FOUNDRY_OK) return result;
    result = api_v1->record_get_u64(tuning, field, &value);
    if (result != FOUNDRY_OK || value > UINT32_MAX) return FOUNDRY_ERR_REFUSED;
    amount = (uint32_t)value;

    component.schema = counter_schema;
    component.name = counter_name;
    component.size = (uint32_t)sizeof(uint32_t);
    component.alignment = 4;
    result = api_v1->world_register_component(self, &component, &counter_type);
    if (result != FOUNDRY_OK) return result;

    system.id = system_id;
    system.name = system_name;
    system.update = update;
    result = api_v1->world_register_system(self, &system);
    if (result != FOUNDRY_OK) return result;

    return api_v1->log_write(self, FOUNDRY_LOG_INFO,
                             (FoundryStr){(const uint8_t *)"lanterns loaded", 15});
}

FOUNDRY_EXPORT void foundry_mod_shutdown(FoundryMod self)
{
    (void)self;
    /* M7 keeps the library mapped. Release mod-owned resources here if you add any. */
}
```

The numeric lengths are intentional: `FoundryStr` is a byte span, not a NUL-terminated
string. For a less error-prone call site, use `sizeof("text") - 1` for literals. Every pointer
the API returns is borrowed until the callback returns. Copy a string you need later; do not
free anything returned by the table. No pointer ownership is transferred. The one refcounted
resource a v1 mod must balance is an asset it acquires, with `asset_release`.

The example follows the required lifecycle rules:

1. It asks for the newest table version it understands and refuses cleanly when that version
   is unavailable.
2. It reads its own content record through the record/schema API rather than assuming the
   engine knows the record's Zig layout.
3. It registers its component and system during `foundry_mod_init`, after content is merged.
4. Its system uses the `FoundryStep` tick, never a wall clock, and receives the component's raw
   bytes only because this mod registered that component type.
5. It checks every result it uses. A failed init is diagnosed and no shutdown callback is run.

## 3. Build the package and library

From the Foundry checkout, install the exact header and build the content compiler:

```sh
FOUNDRY_ROOT="/absolute/path/to/Foundry"
cd "$FOUNDRY_ROOT"
zig build
```

The header is now at `zig-out/include/foundry.h`. Compile the package from the external mod
directory; `fpack` reads the package ID and version from `mod.fdt`:

```sh
MOD_ROOT="/absolute/path/to/lanterns"
mkdir -p "$MOD_ROOT/install/lanterns"
cd "$FOUNDRY_ROOT"
zig build fpack -- --out "$MOD_ROOT/install/lanterns.fpk" "$MOD_ROOT/package"
```

Compile the same C source on each supported host. The output name must match the manifest's
base name after the host decoration:

```sh
cd "$MOD_ROOT"

case "$(uname -s)" in
  Darwin)
    zig cc -std=c99 -pedantic -Wall -Wextra -Werror -fPIC -dynamiclib \
      -I"$FOUNDRY_ROOT/zig-out/include" -o install/lanterns/liblanterns.dylib lanterns.c
    ;;
  Linux)
    zig cc -std=c99 -pedantic -Wall -Wextra -Werror -fPIC -shared \
      -I"$FOUNDRY_ROOT/zig-out/include" -o install/lanterns/liblanterns.so lanterns.c
    ;;
  MINGW*|MSYS*|CYGWIN*)
    zig cc -std=c99 -pedantic -Wall -Wextra -Werror -shared \
      -I"$FOUNDRY_ROOT/zig-out/include" -o install/lanterns/lanterns.dll lanterns.c
    ;;
  *)
    echo "unsupported host: $(uname -s)" >&2
    exit 1
    ;;
esac
```

The four strict warning flags are the same flags used to compile Foundry's C ABI fixtures.
The library links against no Foundry library: all calls arrive through the function-pointer
table, which is why a mod only needs the header and remains outside the engine build graph.

Before handing the package to a host, verify the C side independently:

```sh
cd "$MOD_ROOT"
zig cc -std=c99 -pedantic -Wall -Wextra -Werror \
  -I"$FOUNDRY_ROOT/zig-out/include" -c lanterns.c -o /dev/null
```

## 4. Install and load it

The install directory is the host's content directory:

```
install/
  lanterns.fpk
  lanterns/
    liblanterns.dylib   # or liblanterns.so / lanterns.dll
```

The `.fpk` and the same-stem directory are a pair. The loader derives the package root from
`lanterns.fpk`, then opens exactly one decorated library beneath that root. It does not search
`PATH`, accept an absolute path, or accept `../` in the manifest.

A native-capable host performs these operations in this order:

1. discover `install/lanterns.fpk` and read its manifest;
2. resolve `foundry:core` and `lanterns:mod` into a deterministic load order;
3. pass that order to `app.Engine.init`, so the package's records and schemas are live;
4. bind the host's world and any other subsystems to an `abi.Host` and obtain its v1 table;
5. open `install/lanterns/liblanterns.dylib` (or the platform equivalent), resolve
   `foundry_mod_init`, and call it with `get_api` and this mod's `FoundryMod` handle;
6. run frames. The `lanterns:advance` system creates one entity with value 41 and changes it
   to 42 on its first update; and
7. call `foundry_mod_shutdown` once, in reverse native load order, during teardown.

If the host has no world, `world_register_component` and `world_register_system` return
`FOUNDRY_ERR_UNAVAILABLE`; the function pointers are still present. If the library is missing,
has no `foundry_mod_init`, declares an unsupported ABI range, or returns any result other than
`FOUNDRY_OK`, the host reports and skips its native half while retaining the package's content.

## 5. Verify the result

The host should provide these observable checks (or equivalent inspection through the v1 table):

* the package appears as `lanterns:mod`, and its `lanterns:config` record has `amount = 41`;
* `world_find_component_type(foundry_schema_id("lanterns:counter", 16), ...)` succeeds;
* after one world update, the component type has one entity and
  `world_component_bytes` returns a `uint32_t` containing `42`;
* the log contains `lanterns loaded` under the mod's scope; and
* teardown calls the optional shutdown once.

The `FoundryMod` and component handles are opaque and generational. Do not fabricate them,
reuse a stale one after destruction, or pass a component type registered by another mod to
`world_component_bytes`: the latter returns `FOUNDRY_ERR_REFUSED` by design.

## 6. M7 verification record

This guide's final proof ran on 2026-09-09 from a temporary sibling directory outside the
Foundry checkout. The durable commands were the external package build from §3:

```sh
cd "$FOUNDRY_ROOT"
zig build
zig build fpack -- --out "$MOD_ROOT/install/lanterns.fpk" "$MOD_ROOT/package"
cd "$MOD_ROOT"
zig cc -std=c99 -pedantic -Wall -Wextra -Werror -fPIC -dynamiclib \
  -I"$FOUNDRY_ROOT/zig-out/include" \
  -o install/lanterns/liblanterns.dylib lanterns.c
```

The temporary sibling host then discovered the package directory, resolved `foundry:core`
before `lanterns:mod`, merged the package content, bound a null world host, opened the
package-local library, called `foundry_mod_init`, ran one update, and called shutdown during
teardown. It observed `lanterns:config.amount = 41`, a registered `lanterns:counter` component
and `lanterns:advance` system, and the component value changing to `42`. The C source included
only the installed header; no engine source or private header changed.

That sibling host was a temporary verification harness and is not shipped. The durable automated
equivalent is [`engine/tests/mod_pipeline.zig`](../../engine/tests/mod_pipeline.zig), which
executes the same package-to-loader lifecycle against null platform/RHI backends and also covers
reverse shutdown and native refusal paths.

## Rules worth keeping visible

* `FoundryApi_v1` is frozen. A future table is `FoundryApi_v2`, added alongside it; do not
  depend on struct layout beyond the installed header or call an unrequested version.
* All API input is untrusted. Check pointers, capacities, result codes, handle validity and
  enum values in the same way the example checks its own calls. The host validates at the
  boundary but cannot make a native crash recoverable.
* No pointer or borrowed string survives the callback that returned it, and no pointer
  ownership transfers to or from the mod.
* Simulation uses `FoundryStep.tick` and `delta_ns`; `frame_delta_ns` is presentation timing,
  not simulation time.
* Component types registered by a native mod are not serialized in M7. Keep persistent state in
  content until the later serializer extension exists.
* Native libraries stay mapped for the process lifetime. M7 does not unload or hot-reload
  native code; rebuild the library and restart the host.
* Native mods are not sandboxed or signed. Only load code you trust.
