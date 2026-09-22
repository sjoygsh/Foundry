/*
 * foundry.h — Foundry's public C ABI. There is no second one.
 *
 * Invariant I4: there is exactly one public API surface. Native mods, the scripting host at
 * M8, external tools and any future language binding all arrive through this file. Engine
 * code does not use it, and nothing — including the editor — gets a private path around it.
 *
 * **This header is the specification**, not a description of the implementation. It is
 * hand-written on purpose (public-abi.md §16): a generated header describes whatever the
 * engine currently does, where this one states what the engine owes. It is kept honest by
 * compilation rather than by care — `agreement.c` beside it includes this file and
 * static-asserts every size and every offset, `agreement.zig` asserts the same numbers from
 * the engine's side, and `zig build test` builds both for every supported target. A header
 * that disagrees with the engine fails the build on the machine that changed it.
 *
 * C99, and nothing but <stddef.h> and <stdint.h>. The agreement translation unit is compiled
 * `-std=c99 -pedantic -Werror`, which is what makes that a checked claim rather than an
 * intention.
 *
 * Design: docs/design/public-abi.md. Decisions: ADR-0004 (one versioned C ABI), ADR-0026
 * (where `abi` sits and who supplies its subsystems), ADR-0027 (a mod is a content package).
 *
 * The type layer, ABI skeleton, `scene` group and the remaining capability groups are here —
 * steps 2 through 5 of public-abi.md §19. What is here is already frozen: once a compiled mod
 * exists, a type that crosses this boundary can never change its layout.
 */

#ifndef FOUNDRY_H
#define FOUNDRY_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* == Targets =========================================================================== */

/*
 * Every layout below assumes a 64-bit pointer. Foundry's targets are macOS/arm64, Windows
 * x64 and Linux x64 (ADR-0008), and a 32-bit port would change `FoundryStr`'s padding — so
 * this is stated as a hard failure rather than discovered as a silent disagreement.
 */
#if defined(UINTPTR_MAX) && UINTPTR_MAX != UINT64_MAX
#error "foundry.h describes a 64-bit ABI; this target has a different pointer width."
#endif

/* == Symbol visibility ================================================================= */

/*
 * What a mod's entry points are declared with. Only a mod needs it: the host exports
 * nothing to a mod, because everything a mod calls arrives as a pointer in a table rather
 * than as a symbol to link against. That is what makes a mod loadable without the host
 * having to be a shared library.
 */
#if defined(_WIN32)
#define FOUNDRY_EXPORT __declspec(dllexport)
#elif defined(__GNUC__)
#define FOUNDRY_EXPORT __attribute__((visibility("default")))
#else
#define FOUNDRY_EXPORT
#endif

/* == Versions ========================================================================== */

/*
 * A version numbers *the table*, not the engine. `FoundryApi_v1` is frozen forever; a v2 is
 * a different struct added alongside it (ADR-0004), and a host offers every version it still
 * supports. So a mod names the version it was built against, never an engine release.
 */
#define FOUNDRY_API_VERSION_1 1u
#define FOUNDRY_API_VERSION_2 2u
#define FOUNDRY_API_VERSION_3 3u
#define FOUNDRY_API_VERSION_4 4u
#define FOUNDRY_API_VERSION_5 5u

/* The newest version this header describes. */
#define FOUNDRY_API_VERSION FOUNDRY_API_VERSION_5

/* == Booleans ========================================================================== */

/*
 * `uint8_t`, because a C `bool` has a size the platform decides and a type whose width is a
 * question is not a type that crosses. On input **any** nonzero is true; on output it is
 * always exactly 0 or 1.
 */
typedef uint8_t FoundryBool;

#define FOUNDRY_FALSE ((FoundryBool)0)
#define FOUNDRY_TRUE ((FoundryBool)1)

/* == Results =========================================================================== */

/*
 * Zero is success, positive is a terminal condition that is not an error, negative is an
 * error. That split is the whole reason `while (next(...) == FOUNDRY_OK)` is correct and
 * `FOUNDRY_END` does not have to be special-cased as one.
 *
 * `int32_t` rather than a C `enum`, whose size is implementation-defined. The values are
 * assigned explicitly and are part of the contract: they are never renumbered, and a code
 * added later takes the next unused number rather than being inserted in a tidy place.
 */
typedef int32_t FoundryResult;

#define FOUNDRY_OK ((FoundryResult)0)

/* Iteration is finished. Not an error. */
#define FOUNDRY_END ((FoundryResult)1)

/* A pointer, length, range or enum value the API refuses. */
#define FOUNDRY_ERR_INVALID_ARGUMENT ((FoundryResult)-1)
/* Well-formed and stale, or never issued. */
#define FOUNDRY_ERR_INVALID_HANDLE ((FoundryResult)-2)
/* The thing asked for does not exist. Distinct from a bad handle. */
#define FOUNDRY_ERR_NOT_FOUND ((FoundryResult)-3)
/* The host supplied no subsystem for this capability (ADR-0026). */
#define FOUNDRY_ERR_UNAVAILABLE ((FoundryResult)-4)
/* A version, format or feature this build does not have. */
#define FOUNDRY_ERR_UNSUPPORTED ((FoundryResult)-5)
/* Registering a name or id twice, incompatibly. */
#define FOUNDRY_ERR_ALREADY_EXISTS ((FoundryResult)-6)
/* A bound was hit: a buffer, a pool, a configured maximum. */
#define FOUNDRY_ERR_LIMIT ((FoundryResult)-7)
/* Well-formed, permitted in general, not permitted *now*. */
#define FOUNDRY_ERR_REFUSED ((FoundryResult)-8)
#define FOUNDRY_ERR_OUT_OF_MEMORY ((FoundryResult)-9)
/* An engine error with no mapping. Always logged with the underlying error's name. */
#define FOUNDRY_ERR_INTERNAL ((FoundryResult)-10)

/* == Strings =========================================================================== */

/*
 * A pointer and a length, byte-identical to the engine's own string type, so crossing is a
 * cast rather than a conversion.
 *
 * **Not NUL-terminated.** Content strings are spans into a mapped package and always have
 * been; terminating them would mean copying every one of them at the boundary. UTF-8, and
 * validated on the way in rather than assumed.
 *
 * **Borrowed.** Like every pointer this API hands out, it is valid only until the mod
 * returns control to the engine. A mod that wants to keep a string copies it.
 */
typedef struct FoundryStr {
    const uint8_t *ptr;
    uint64_t len;
} FoundryStr;

/* == Content identity ================================================================== */

/*
 * A hashed `namespace:name` — `foundry:item.torch` — and the only way content is ever
 * named across this boundary. Never a path, never an index, never a load-order position
 * (Invariant I2, ADR-0005, ADR-0021).
 *
 * Zero is the absence of an id. The content compiler refuses any string that hashes to it,
 * so a zeroed struct is safely nothing rather than accidentally something.
 */
typedef struct FoundryContentId {
    uint64_t hash;
} FoundryContentId;

/*
 * FNV-1a, 64-bit, over the exact UTF-8 bytes including the colon. No case folding, no
 * trimming, no Unicode normalisation — normalisation would be a second specification every
 * modding tool would have to reimplement identically, and any divergence would produce ids
 * that differ invisibly.
 *
 * Written out here, rather than left to a call into the table, because external tooling has
 * to be able to compute one without linking Foundry — a packer, a validator, a spreadsheet.
 * `agreement.zig` calls this function through the C boundary and compares it against the
 * engine's own hash, so the two cannot drift.
 */
static inline FoundryContentId foundry_content_id(const void *bytes, size_t len)
{
    const uint8_t *p = (const uint8_t *)bytes;
    uint64_t hash = UINT64_C(0xcbf29ce484222325);
    FoundryContentId id;
    size_t i;

    for (i = 0; i < len; ++i) {
        hash ^= (uint64_t)p[i];
        hash *= UINT64_C(0x00000100000001b3);
    }

    id.hash = hash;
    return id;
}

/*
 * A hashed schema identifier — and **a different type from a content id on purpose**.
 *
 * Schemas and content occupy separate identifier spaces, so the schema `foundry:item` and a
 * record named `foundry:item` coexist without either shadowing the other. Same algorithm,
 * same bytes hashed, different C type: the two most confusable values in the content system
 * cannot be passed to each other's calls by mistake.
 *
 * A schema keeps no spelling at runtime, so there is no `schema_name`. That is the format
 * working as designed rather than an omission: what a compiled package carries is the hash.
 */
typedef struct FoundrySchemaId {
    uint64_t hash;
} FoundrySchemaId;

/*
 * The same hash as `foundry_content_id`, over the same bytes, into the other space.
 *
 * Here rather than in the table because a mod that registers a component type has to name
 * its own schema before any record of it exists to be asked — every call that *returns* a
 * schema id needs something that already has one, so without this there is no way in. The
 * spelling is still checked: `world_register_component` parses the name beside it and
 * refuses a hash that does not belong to it.
 */
static inline FoundrySchemaId foundry_schema_id(const void *bytes, size_t len)
{
    FoundrySchemaId id;
    id.hash = foundry_content_id(bytes, len).hash;
    return id;
}

/* == Handles =========================================================================== */

/*
 * Everything addressable is a handle, never a pointer (Invariant I1). Sixty-four opaque bits
 * carrying a generation beside an index, so a handle to something that has been destroyed
 * fails to resolve instead of reading whatever now occupies the slot. The packing is not
 * published and may change; the width and the opacity are the contract.
 *
 * One struct per kind rather than one `uint64_t` typedef, so that C's type system keeps the
 * distinctions the engine's type system keeps. Passing a `FoundryTexture` where a
 * `FoundryVoice` belongs is a compile error on both sides of the boundary, which is the
 * cheapest place for it to be one.
 *
 * **Zero is always the null handle**, for every kind: `FoundryEntity e = {0};`.
 */

/* The loaded mod itself, handed to `foundry_mod_init`. Scopes anything that is per-mod:
 * which package it came from, what name its log lines carry. */
typedef struct FoundryMod { uint64_t bits; } FoundryMod;

/* `data` — content, as loaded and merged. */
typedef struct FoundryPackage { uint64_t bits; } FoundryPackage;
typedef struct FoundrySchema { uint64_t bits; } FoundrySchema;
typedef struct FoundryRecord { uint64_t bits; } FoundryRecord;

/* `asset` — a loaded asset, and the one refcount a mod owns. */
typedef struct FoundryAsset { uint64_t bits; } FoundryAsset;

/* `scene` — entities and the component types they carry. */
typedef struct FoundryEntity { uint64_t bits; } FoundryEntity;
typedef struct FoundryComponentType { uint64_t bits; } FoundryComponentType;

/* `render2d` — the game-facing renderer. The RHI beneath it is never exposed (§4.2). */
typedef struct FoundryTexture { uint64_t bits; } FoundryTexture;
typedef struct FoundryView { uint64_t bits; } FoundryView;

/* `audio` — a playing voice. */
typedef struct FoundryVoice { uint64_t bits; } FoundryVoice;

/* `physics2d` — a collision body. */
typedef struct FoundryBody { uint64_t bits; } FoundryBody;
typedef struct FoundryGrid { uint64_t bits; } FoundryGrid;

/* Two handles that are the boundary's own rather than a subsystem's: an open profiler span
 * and a memory counter a mod reports its own numbers into. Both exist because a mod has no
 * value to hold between two calls that a C ABI could hand it any other way. */
typedef struct FoundryMemoryCounter { uint64_t bits; } FoundryMemoryCounter;

/* A content-derived UI theme, valid only for the content generation that issued it. */
typedef struct FoundryTheme { uint64_t bits; } FoundryTheme;

/*
 * `author` — the v4 authoring handles (ADR-0042). Five kinds, five types, for the reason
 * every other handle here is its own type: a document passed where a build belongs is a
 * diagnostic on both sides rather than a number that happens to resolve.
 *
 * **None of them is ever a FoundryRecord or a FoundrySchema.** A draft is source text that
 * has not been compiled; a handle naming one cannot be a handle into loaded content.
 *
 * Lifetimes, which differ and are worth reading once:
 *   - a workspace handle lives until the workspace is closed;
 *   - a document or build handle lives as long as its workspace;
 *   - a **node** handle — value or schema — dies at the next accepted command, even one
 *     that did not touch it, and after enough further nodes have been opened.
 */
typedef struct FoundryWorkspace { uint64_t bits; } FoundryWorkspace;
typedef struct FoundryDocument { uint64_t bits; } FoundryDocument;
typedef struct FoundrySourceNode { uint64_t bits; } FoundrySourceNode;
typedef struct FoundrySchemaNode { uint64_t bits; } FoundrySchemaNode;
typedef struct FoundryBuild { uint64_t bits; } FoundryBuild;

/* `net` — the v5 networking handles (networking.md §8). A session exists only by a grant the
 * host published; a peer is one connection in one session. Neither ever names a key, a
 * principal or an address, and both go stale when what they name ends. */
typedef struct FoundryNetSession { uint64_t bits; } FoundryNetSession;
typedef struct FoundryNetPeer { uint64_t bits; } FoundryNetPeer;

/* == Cursors =========================================================================== */

/*
 * Nothing in this API hands out a container. What crosses is one element at a time:
 *
 *     FoundryCursor c = FOUNDRY_CURSOR_BEGIN;
 *     FoundryEntity e;
 *     while (api->world_next_entity(&c, &e) == FOUNDRY_OK) { ... }
 *
 * **A cursor, not an index.** An index invites being stored and reused as an identity, which
 * is exactly what content ids exist to stop one level up. A cursor carries a generation
 * beside its position, so a walk whose container has been structurally mutated underneath it
 * is *detected* — the next call returns FOUNDRY_ERR_INVALID_ARGUMENT — rather than silently
 * resynchronising onto whatever now sits at that position.
 *
 * A cursor is meaningful only to the enumeration that issued it, is not a handle, and is
 * never worth storing past the walk.
 */
typedef struct FoundryCursor {
    uint64_t bits;
} FoundryCursor;

/* Where every walk starts. An initialiser, so: `FoundryCursor c = FOUNDRY_CURSOR_BEGIN;` */
#define FOUNDRY_CURSOR_BEGIN \
    {                        \
        0                    \
    }

/* == Enumerations ====================================================================== */

/*
 * `int32_t` with values written down, never a C `enum` and never declaration order. A number
 * here is as permanent as a struct's layout: it is what a compiled mod holds.
 */

/* How severe a log line is. Ordered most severe to least, which is also the order a filter
 * reads: passing `FOUNDRY_LOG_INFO` to a reader means "info and anything worse". */
typedef int32_t FoundryLogLevel;
#define FOUNDRY_LOG_ERROR ((FoundryLogLevel)0)
#define FOUNDRY_LOG_WARN ((FoundryLogLevel)1)
#define FOUNDRY_LOG_INFO ((FoundryLogLevel)2)
#define FOUNDRY_LOG_DEBUG ((FoundryLogLevel)3)
#define FOUNDRY_LOG_TRACE ((FoundryLogLevel)4)

/*
 * What a schema says a field is. A record is read by asking its schema what each field is
 * and then calling the matching reader — which is how a mod reads a record type it has never
 * heard of, and how the debug overlay's inspector already works.
 *
 * `LIST` and `NESTED` are read through `record_list_*` and `record_nested` rather than by a
 * value reader; a nested block answers the same field calls one level down, which composes
 * to any depth and needs no path language invented for the boundary.
 */
typedef int32_t FoundryFieldType;
#define FOUNDRY_FIELD_BOOL ((FoundryFieldType)0)
#define FOUNDRY_FIELD_I32 ((FoundryFieldType)1)
#define FOUNDRY_FIELD_I64 ((FoundryFieldType)2)
#define FOUNDRY_FIELD_U32 ((FoundryFieldType)3)
#define FOUNDRY_FIELD_U64 ((FoundryFieldType)4)
#define FOUNDRY_FIELD_F32 ((FoundryFieldType)5)
#define FOUNDRY_FIELD_F64 ((FoundryFieldType)6)
#define FOUNDRY_FIELD_STRING ((FoundryFieldType)7)
#define FOUNDRY_FIELD_ID ((FoundryFieldType)8)
#define FOUNDRY_FIELD_LIST ((FoundryFieldType)9)
#define FOUNDRY_FIELD_NESTED ((FoundryFieldType)10)

/* Where a package was discovered: the game's own installation, or the player's `mods/`
 * folder. The host assigns this to each folder it searches; nothing inside a package can
 * claim it. (v3) */
typedef int32_t FoundryModOrigin;
#define FOUNDRY_MOD_ORIGIN_INSTALLED ((FoundryModOrigin)0)
#define FOUNDRY_MOD_ORIGIN_USER ((FoundryModOrigin)1)

/* Why a copy of a package would not load at the next start. `NONE` for one that loads, and
 * for one nobody enabled. (v3) */
typedef int32_t FoundryModSkipReason;
#define FOUNDRY_MOD_SKIP_NONE ((FoundryModSkipReason)0)
/* Enabled, and no installed package has this id. */
#define FOUNDRY_MOD_SKIP_NOT_INSTALLED ((FoundryModSkipReason)1)
/* A package it requires is not installed or not enabled. `skip_other` names it. */
#define FOUNDRY_MOD_SKIP_MISSING_DEPENDENCY ((FoundryModSkipReason)2)
/* A package it requires is installed at a version outside its range. */
#define FOUNDRY_MOD_SKIP_DEPENDENCY_VERSION ((FoundryModSkipReason)3)
/* A package it requires was itself skipped. */
#define FOUNDRY_MOD_SKIP_DEPENDENCY_SKIPPED ((FoundryModSkipReason)4)
/* It requires itself, through others. */
#define FOUNDRY_MOD_SKIP_CYCLE ((FoundryModSkipReason)5)
/* Two or more copies in the player's folder share its id, and none of them loads. */
#define FOUNDRY_MOD_SKIP_DUPLICATE ((FoundryModSkipReason)6)
/* A copy in the player's folder claims an installed package's id; the installed one loads. */
#define FOUNDRY_MOD_SKIP_SHADOWS_INSTALLED ((FoundryModSkipReason)7)

/* Why a profile cannot be used. Its file is kept as it is, whatever the reason. (v3) */
typedef int32_t FoundryModProfileProblem;
#define FOUNDRY_MOD_PROFILE_OK ((FoundryModProfileProblem)0)
#define FOUNDRY_MOD_PROFILE_DAMAGED ((FoundryModProfileProblem)1)
/* Written by a build this one does not understand, usually a newer one. */
#define FOUNDRY_MOD_PROFILE_OTHER_BUILD ((FoundryModProfileProblem)2)
/* Readable, but past a bound or disagreeing with itself. */
#define FOUNDRY_MOD_PROFILE_REFUSED ((FoundryModProfileProblem)3)
/* The file could not be read at all. */
#define FOUNDRY_MOD_PROFILE_UNAVAILABLE ((FoundryModProfileProblem)4)

/* `FoundryModInfo.flags`. (v3) */
/* A package the game cannot run without. Always loads, is never in a profile, and is shown
 * locked: `mods_set_enabled` refuses it. */
#define FOUNDRY_MOD_REQUIRED UINT32_C(1)
/* Its manifest names a native library. Whether that code runs is the host's decision and the
 * player's consent, neither of which this API exposes. */
#define FOUNDRY_MOD_NATIVE UINT32_C(2)
/* Its manifest names a script entry. */
#define FOUNDRY_MOD_SCRIPT UINT32_C(4)
/* This copy is skipped as a duplicate: FOUNDRY_MOD_SKIP_DUPLICATE or _SHADOWS_INSTALLED. */
#define FOUNDRY_MOD_DUPLICATE UINT32_C(8)
/* Enabled for this session by the host's developer override rather than by the player.
 * Never saved into a profile. */
#define FOUNDRY_MOD_ENVIRONMENT UINT32_C(16)
/* Its record table could not be read, so it counts as providing nothing. The host's log
 * says why. */
#define FOUNDRY_MOD_UNREADABLE UINT32_C(32)

/* A position in a list something is not in. */
#define FOUNDRY_MOD_NO_POSITION UINT32_MAX

/* Which way `ui_reorder_button` moves a row. (v3) */
typedef int32_t FoundryUiReorderDirection;
#define FOUNDRY_UI_REORDER_UP ((FoundryUiReorderDirection)0)
#define FOUNDRY_UI_REORDER_DOWN ((FoundryUiReorderDirection)1)
#define FOUNDRY_UI_REORDER_TOP ((FoundryUiReorderDirection)2)
#define FOUNDRY_UI_REORDER_BOTTOM ((FoundryUiReorderDirection)3)

/* == Structs that cross ================================================================ */

/*
 * One line from the engine's in-memory log ring, as `log_next` reports it.
 *
 * `scope` and `text` are borrowed like every other string here: valid until the mod returns
 * control. The ring is a ring, so a walk that pauses can miss lines that were overwritten —
 * `sequence` is monotonic from 1 and is how a reader tells.
 */
typedef struct FoundryLogRecord {
    FoundryLogLevel level;
    /* Explicit, so the padding is part of the specification rather than the compiler's
     * opinion. Zero on output; ignored on input. */
    uint32_t reserved;
    /* The engine frame the line was logged in. What lines a log line up against a span. */
    uint64_t frame;
    /* Monotonic from 1, so a reader can tell whether it has seen a line before. */
    uint64_t sequence;
    FoundryStr scope;
    FoundryStr text;
} FoundryLogRecord;

/*
 * What a mod reports about its own allocations.
 *
 * The engine does not wrap a mod's allocator and could not: a native mod allocates however
 * its language does. So a mod that wants to appear in the memory panel opens a counter and
 * writes its own numbers into it, which is the same bargain the engine already makes with a
 * game (`app.Engine.registerMemory` counts what the caller chose to count).
 */
typedef struct FoundryMemoryStats {
    uint64_t live_bytes;
    uint64_t peak_bytes;
    uint64_t allocations;
    uint64_t frees;
    /* Allocations that were refused. Worth its own number: a mod quietly failing to allocate
     * looks identical to one that is not trying. */
    uint64_t failures;
} FoundryMemoryStats;

/* One deterministic simulation update. A native system gets no clock, input snapshot or
 * interpolation alpha: all three would make the simulation depend on its host. */
typedef struct FoundryStep {
    uint64_t tick;
    uint64_t delta_ns;
} FoundryStep;

/* The in-memory half of a component type. The schema lives in the mod's content package;
 * this names its raw storage and optional construction/destruction hooks. */
typedef struct FoundryComponentDesc {
    FoundrySchemaId schema;
    FoundryStr name;
    uint32_t size;
    uint32_t alignment;
    void *ctx;
    void (*construct)(void *ctx, void *out);
    void (*destruct)(void *ctx, void *component);
} FoundryComponentDesc;

/* A system is an identity, a context and a callback. It reaches the world through the API
 * table it retained from init; the step is the only per-update value it is handed. */
typedef struct FoundrySystemDesc {
    FoundryContentId id;
    FoundryStr name;
    void *ctx;
    void (*update)(void *ctx, const FoundryStep *step);
} FoundrySystemDesc;

/* == Render2d values ================================================================== */

/* A point or extent in logical screen points or world units, as the call specifies. */
typedef struct FoundryRenderVec2 {
    float x;
    float y;
} FoundryRenderVec2;

/* A rectangle in logical points, except UV rectangles, which are normalised coordinates. */
typedef struct FoundryRenderRect {
    float x;
    float y;
    float w;
    float h;
} FoundryRenderRect;

/* A linear-light colour multiplier. */
typedef struct FoundryRenderColor {
    float r;
    float g;
    float b;
    float a;
} FoundryRenderColor;

/* A camera in world units and logical screen points. */
typedef struct FoundryRenderCamera {
    FoundryRenderVec2 center;
    float zoom;
    float rotation;
    FoundryRenderRect viewport;
} FoundryRenderCamera;

/* A sprite descriptor. `blend` is alpha=0, additive=1, none=2. */
typedef struct FoundryRenderSprite {
    FoundryTexture texture;
    FoundryRenderVec2 position;
    FoundryRenderVec2 size;
    FoundryRenderRect uv;
    FoundryRenderVec2 origin;
    float rotation;
    FoundryRenderColor tint;
    int16_t layer;
    uint16_t reserved_layer;
    int32_t blend;
    FoundryBool flip_x;
    FoundryBool flip_y;
    uint8_t reserved_flags[2];
} FoundryRenderSprite;

/* Fixed-grid bitmap font metadata. */
typedef struct FoundryRenderFont {
    FoundryTexture texture;
    FoundryRenderRect uv;
    uint32_t width;
    uint32_t height;
    uint32_t cell_width;
    uint32_t cell_height;
    uint32_t columns;
    uint32_t first_codepoint;
    uint32_t glyph_count;
    uint32_t substitute;
    uint8_t reserved[4];
} FoundryRenderFont;

/* Text drawing parameters. */
typedef struct FoundryRenderTextOptions {
    FoundryRenderVec2 position;
    float scale;
    FoundryRenderColor tint;
    int16_t layer;
    uint16_t reserved_layer;
    int32_t blend;
    float letter_spacing;
    float line_spacing;
} FoundryRenderTextOptions;

/* A view descriptor. Both payloads are present; `kind` selects the meaningful one. */
typedef struct FoundryRenderViewDesc {
    int32_t kind;
    uint32_t reserved;
    FoundryRenderCamera camera;
    FoundryRenderRect screen;
} FoundryRenderViewDesc;

/* Per-frame renderer output counters. */
typedef struct FoundryRenderStats {
    uint32_t sprites;
    uint32_t glyphs;
    uint32_t tiles;
    uint32_t batches;
    uint32_t draw_calls;
    uint32_t vertices;
    uint32_t vertex_bytes;
    uint32_t buffers_used;
    uint32_t textures_resident;
    uint32_t views;
} FoundryRenderStats;

/* == UI values ======================================================================== */

/* Runtime-only widget identity, distinct from content ids. */
typedef struct FoundryUiId {
    uint64_t bits;
} FoundryUiId;

typedef struct FoundryUiVec2 {
    float x;
    float y;
} FoundryUiVec2;

typedef struct FoundryUiRect {
    float x;
    float y;
    float w;
    float h;
} FoundryUiRect;

typedef struct FoundryUiColor {
    float r;
    float g;
    float b;
    float a;
} FoundryUiColor;

typedef struct FoundryUiFontMetrics {
    FoundryUiVec2 cell;
    float letter_spacing;
    float line_spacing;
} FoundryUiFontMetrics;

/* Complete style read by the UI kernel. */
typedef struct FoundryUiStyle {
    FoundryUiFontMetrics font;
    float text_scale;
    float line_height;
    FoundryUiVec2 padding;
    float spacing;
    float separator_thickness;
    float scrollbar;
    uint32_t caret_blink_frames;
    FoundryUiColor text;
    FoundryUiColor text_dim;
    FoundryUiColor surface;
    FoundryUiColor control;
    FoundryUiColor control_hot;
    FoundryUiColor control_active;
    FoundryUiColor accent;
} FoundryUiStyle;

/* One-line plot options. The named padding is part of the wire layout. */
typedef struct FoundryUiPlotOptions {
    float height;
    uint8_t _padding0[4];
    uint64_t first;
    float min;
    float max;
    FoundryBool has_min;
    FoundryBool has_max;
    uint8_t _padding1[2];
} FoundryUiPlotOptions;

/*
 * One discovered copy of a package, and what the pending selection makes of it (v3).
 *
 * **No path, ever.** Where a package lives is the host's business; a mod may learn what is
 * installed, not where. Two copies of one id are told apart by `origin` and `skip_reason`.
 *
 * Every string is borrowed from the host's mod set and stays valid until the next successful
 * `mods_*` change. `pending_*`, `skip_*`, `provides`, `wins` and `loses` describe the order
 * the **next** start would load; `loaded` describes the one this session did.
 */
typedef struct FoundryModInfo {
    FoundryContentId id;
    /* The id's spelling. `id_to_string` cannot spell a package that is not loaded. */
    FoundryStr id_name;
    FoundryStr name;
    FoundryStr license;
    uint32_t version;
    FoundryModOrigin origin;
    /* FOUNDRY_MOD_REQUIRED and the rest. */
    uint32_t flags;
    /* Its index in the player's list, which is what `mods_move` takes, or
     * FOUNDRY_MOD_NO_POSITION when the player has not enabled it. */
    uint32_t pending_index;
    /* Its index in the order the next start would load, required packages included, or
     * FOUNDRY_MOD_NO_POSITION when this copy would not load. */
    uint32_t pending_position;
    FoundryModSkipReason skip_reason;
    /* The package a dependency skip is about, and its spelling when anything installed has
     * one. Zero and empty otherwise. */
    FoundryContentId skip_other;
    FoundryStr skip_other_name;
    /* Records it provides, how many of them override an earlier package's, and how many a
     * later package overrides. Zero when this copy would not load. */
    uint32_t provides;
    uint32_t wins;
    uint32_t loses;
    FoundryBool loaded;
    /* The player enabled it, or it is required. */
    FoundryBool pending_enabled;
    uint8_t _padding[2];
} FoundryModInfo;

/* One entry of the player's list, in the player's order (v3). An entry can name a package
 * that is no longer installed: a profile outlives the files it mentions. */
typedef struct FoundryModPending {
    FoundryContentId id;
    /* Borrowed, like FoundryModInfo's strings. Empty when nothing ever spelled the id. */
    FoundryStr name;
    FoundryBool installed;
    uint8_t _padding[7];
} FoundryModPending;

/* One dependency of a package, as its manifest states it (v3). */
typedef struct FoundryModRequirement {
    FoundryContentId id;
    /* Borrowed. Empty when no installed package has this id: a hash cannot be spelled. */
    FoundryStr name;
    uint32_t min_version;
    /* UINT32_MAX when the range has no upper bound. */
    uint32_t max_version;
    /* The next start would load a version inside the range. */
    FoundryBool satisfied;
    uint8_t _padding[7];
} FoundryModRequirement;

/* One record two or more packages in the pending order provide (v3). The last provider in
 * load order is the one the game sees. */
typedef struct FoundryModConflict {
    FoundryContentId record;
    /* The record's spelling, borrowed. */
    FoundryStr name;
    FoundryContentId winner;
    uint32_t provider_count;
    uint32_t _padding;
} FoundryModConflict;

/* One package providing a record (v3). */
typedef struct FoundryModProvider {
    FoundryContentId package;
    /* Its index in the order the next start would load. */
    uint32_t position;
    /* The last provider, whose record the game sees. */
    FoundryBool winner;
    uint8_t _padding[3];
} FoundryModProvider;

/* One profile: an ordered selection the player named (v3). */
typedef struct FoundryModProfile {
    /* Stable for the profile's life, and never reused while it exists. */
    uint32_t key;
    FoundryModProfileProblem problem;
    /* The player's name for it, borrowed. */
    FoundryStr name;
    /* The profile the next start uses. */
    FoundryBool saved;
    /* The profile being edited, which `mods_apply` saves. */
    FoundryBool pending;
    uint8_t _padding[6];
} FoundryModProfile;

/* Which profiles are saved and pending, and whether anything waits for `mods_apply` (v3).
 * A host that keeps no profiles answers with both `has_` members false. */
typedef struct FoundryModProfileState {
    uint32_t saved;
    uint32_t pending;
    FoundryBool has_saved;
    FoundryBool has_pending;
    FoundryBool changed;
    uint8_t _padding;
} FoundryModProfileState;

/* A rectangle of the atlas of the theme pushed around the current UI frame, in the atlas's
 * pixels, top-left origin. It must lie inside the atlas (v3). */
typedef struct FoundryUiImageSource {
    uint32_t x;
    uint32_t y;
    uint32_t w;
    uint32_t h;
} FoundryUiImageSource;

/* What a reorder widget returns (v3). `moved` is false on every frame but the one that
 * completes a move. `to` is the row's final index once it has left `from`, which is the
 * index `mods_move` takes; both are below the row count the widget was given. */
typedef struct FoundryUiReorderMove {
    uint32_t from;
    uint32_t to;
    FoundryBool moved;
    uint8_t _padding[3];
} FoundryUiReorderMove;

/* == Physics2d values ================================================================= */

typedef struct FoundryPhysicsVec2 {
    float x;
    float y;
} FoundryPhysicsVec2;

/* kind is 0 for a box and 1 for a circle; both payload members are always present. */
typedef struct FoundryPhysicsShape {
    int32_t kind;
    uint32_t reserved;
    float x;
    float y;
} FoundryPhysicsShape;

/* Body kind is 0 static, 1 movable and 2 trigger. */
typedef struct FoundryPhysicsBodyDesc {
    FoundryPhysicsShape shape;
    FoundryPhysicsVec2 position;
    int32_t kind;
    uint32_t reserved;
    uint32_t layer;
    uint32_t mask;
    uint64_t user;
} FoundryPhysicsBodyDesc;

/* A swept contact; body is zero for a grid hit and grid/cell identify that cell. */
typedef struct FoundryPhysicsHit {
    FoundryBody body;
    FoundryGrid grid;
    uint32_t cell_x;
    uint32_t cell_y;
    FoundryPhysicsVec2 normal;
    float fraction;
    uint8_t reserved[4];
    uint64_t user;
} FoundryPhysicsHit;

/* An overlap result; body and grid retain both possible kinds of identity. */
typedef struct FoundryPhysicsQueryHit {
    FoundryBody body;
    FoundryGrid grid;
    uint32_t cell_x;
    uint32_t cell_y;
    uint64_t user;
} FoundryPhysicsQueryHit;

/* The result of moving a body, including written and total hit counts. */
typedef struct FoundryPhysicsMoveResult {
    FoundryPhysicsVec2 position;
    uint32_t hit_count;
    uint32_t total_hits;
    FoundryBool started_inside;
    uint8_t reserved[3];
} FoundryPhysicsMoveResult;

/* == The table ========================================================================= */

/*
 * Everything a mod may call, as a flat struct of function pointers.
 *
 * **Flat rather than grouped into substructs.** Nesting reads better at a call site and is
 * what the eye wants for a table this size. It is refused because a nested substruct is a
 * second thing frozen forever, and growing the table additively would then mean either a new
 * outer version for a change inside one group, or nested pointers — which reintroduces the
 * null check the whole design spent a decision removing. The prefix in each name carries the
 * grouping at no cost.
 *
 * **No function pointer here is ever NULL.** A capability whose subsystem the host did not
 * supply is present and answers FOUNDRY_ERR_UNAVAILABLE. The table for a version is one
 * shape, always, so a mod may call anything it can name.
 *
 * **Every out-parameter is written only on FOUNDRY_OK.** A call that fails leaves what the
 * caller passed exactly as it was, so a mod may initialise once and check the result.
 *
 * **Every pointer handed out is borrowed until the mod returns control to the engine** — the
 * end of the current callback, or of `foundry_mod_init`. Nothing here transfers ownership in
 * either direction; a mod that wants to keep a string copies it, and the two calls whose
 * names end in `copy_string` are there for exactly that.
 *
 * The table contains the skeleton, `scene` and all remaining capability groups (public-abi.md
 * §19 steps 3 through 5). They are appended in implementation order, never inserted: a
 * field's position in this struct is what a compiled mod holds.
 */
typedef struct FoundryApi_v1 {
    /* Always 1, and `sizeof(FoundryApi_v1)` as the host built it. Both are redundant with
     * `get_api`, and both are here for the case the query cannot reach: a crash dump on a
     * player's machine, where the one thing worth knowing is whether the mod was built
     * against this header. Eight bytes, and every other answer involves asking the player to
     * reproduce something. */
    uint32_t version;
    uint32_t size;

    /* -- Results and logging ----------------------------------------------------------- */

    /* The name of a result code — "FOUNDRY_ERR_NOT_FOUND" — so a mod can log legibly without
     * shipping its own copy of the table and letting it go stale. Empty for a code this host
     * has never issued, which is the honest answer rather than an invented one. Always
     * available: it needs no subsystem. */
    FoundryStr (*result_name)(FoundryResult result);

    /* Writes one line to the engine's log, tagged with the mod's own scope. Available on a
     * host with no subsystems at all, deliberately: a mod refusing itself has to be able to
     * say why. */
    FoundryResult (*log_write)(FoundryMod self, FoundryLogLevel level, FoundryStr message);

    /* Walks the in-memory log ring, oldest first, from a cursor starting at
     * FOUNDRY_CURSOR_BEGIN. Returns FOUNDRY_END when there is nothing more. */
    FoundryResult (*log_next)(FoundryCursor *cursor, FoundryLogRecord *out);

    /* -- Content identity -------------------------------------------------------------- */

    /* Hashes a `namespace:name` string, validating its shape first — the same validation the
     * content compiler applies, so a string this refuses would never have compiled either.
     * `foundry_content_id` in this header hashes without validating; this is the checked
     * form, and needs no subsystem. */
    FoundryResult (*id_from_string)(FoundryStr text, FoundryContentId *out);

    /* The spelling of an id, borrowed from the package that supplied it. FOUNDRY_ERR_NOT_FOUND
     * when nothing loaded carries that id: a hash cannot be reversed, so an id nobody spells
     * has no name to give. */
    FoundryResult (*id_to_string)(FoundryContentId id, FoundryStr *out);

    /* The same spelling, copied into the caller's buffer, for a mod that needs the bytes past
     * the call. Writes `*needed` with the length whether or not it fitted and returns
     * FOUNDRY_ERR_LIMIT rather than truncating — silent truncation of a name is how a mod
     * ships with a bug nobody can see. `buffer` may be NULL when `capacity` is 0, which is
     * how a caller asks for the length alone. */
    FoundryResult (*id_copy_string)(FoundryContentId id, uint8_t *buffer, uint64_t capacity,
                                    uint64_t *needed);

    /* -- The frame --------------------------------------------------------------------- */

    /* The engine's frame counter, which is what a log line's `frame` stamp lines up with. */
    FoundryResult (*frame_index)(uint64_t *out);

    /* Wall-clock length of the previous frame. **Presentation only.** Simulation time is the
     * tick, never this: a mod that integrates motion against a wall clock has made its own
     * behaviour depend on how fast the machine is. */
    FoundryResult (*frame_delta_ns)(uint64_t *out);

    /* Total simulated time, which is an exact multiple of the tick and is therefore the same
     * number on every machine that ran the same ticks. */
    FoundryResult (*elapsed_ns)(uint64_t *out);

    /* The exact length of one simulation step. Nanoseconds rather than a rate in hertz,
     * because the engine's timestep is an exact rational and a rounded rate would not
     * reproduce it. */
    FoundryResult (*tick_delta_ns)(uint64_t *out);

    /* -- The profiler ------------------------------------------------------------------ */

    /* Opens a named timing span, so a mod's own work appears in the profiler beside the
     * engine's. Strictly nested, and every span a mod opens it must close. */
    FoundryResult (*scope_begin)(FoundryStr name);

    /* Closes the innermost span this mod opened. FOUNDRY_ERR_REFUSED when none is open,
     * rather than closing one the engine or the game opened. */
    FoundryResult (*scope_end)(void);

    /* -- Memory ------------------------------------------------------------------------ */

    /* Opens a named counter in the engine's memory report. The name is copied. */
    FoundryResult (*memory_counter_open)(FoundryMod self, FoundryStr name,
                                         FoundryMemoryCounter *out);

    /* Publishes a mod's own numbers into a counter it opened. */
    FoundryResult (*memory_counter_set)(FoundryMemoryCounter counter,
                                        const FoundryMemoryStats *stats);

    /* -- Content ----------------------------------------------------------------------- */

    /* Bumped whenever content changes under the program — a hot reload, a package added.
     * **The one signal a mod needs**: anything derived from content, including every record
     * handle and every borrowed string, is derived again when this moves. */
    FoundryResult (*content_generation)(uint64_t *out);

    /* The record a content id names, after every package has been merged and every override
     * applied. What a mod gets is the definition that *won*, which is the same one the game
     * sees — there is no privileged view. */
    FoundryResult (*content_find)(FoundryContentId id, FoundryRecord *out);

    /* Every record, in merge order. */
    FoundryResult (*content_next)(FoundryCursor *cursor, FoundryRecord *out);

    /* Every record of one schema, in merge order. How a mod finds "all the items" without
     * knowing what any package called them. */
    FoundryResult (*content_next_of_schema)(FoundrySchemaId schema, FoundryCursor *cursor,
                                            FoundryRecord *out);

    /* -- Reading a record -------------------------------------------------------------- */

    /*
     * A record is read by asking its schema what each field is and then calling the matching
     * reader. That is how a mod reads a record type it has never heard of — including one
     * another mod declared — and it is what the debug overlay's inspector already does.
     *
     * A field a record does not carry answers FOUNDRY_ERR_NOT_FOUND, which is different from
     * a field that is not in the schema at all (FOUNDRY_ERR_INVALID_ARGUMENT) and different
     * again from asking for it with the wrong reader (also INVALID_ARGUMENT). A record
     * written against an older version of its schema answers newer fields with their
     * declared defaults, which is what makes a schema able to grow.
     */

    /* A nested block has no identity of its own — that is what nested means — so `record_id`,
     * `record_name` and `record_package` answer FOUNDRY_ERR_NOT_FOUND for one. */
    FoundryResult (*record_id)(FoundryRecord record, FoundryContentId *out);
    FoundryResult (*record_name)(FoundryRecord record, FoundryStr *out);
    FoundryResult (*record_schema)(FoundryRecord record, FoundrySchemaId *out);
    FoundryResult (*record_package)(FoundryRecord record, FoundryPackage *out);

    FoundryResult (*record_field_count)(FoundryRecord record, uint32_t *out);
    FoundryResult (*record_field_index)(FoundryRecord record, FoundryStr name, uint32_t *out);
    FoundryResult (*record_field_name)(FoundryRecord record, uint32_t field, FoundryStr *out);
    FoundryResult (*record_field_type)(FoundryRecord record, uint32_t field,
                                       FoundryFieldType *out);
    /* Whether the record actually carries a value for the field, as opposed to the field
     * being absent. A missing optional field and a field set to its default are different
     * things, and collapsing them would make "this item drops nothing" and "this item's drop
     * was never specified" indistinguishable. */
    FoundryResult (*record_field_present)(FoundryRecord record, uint32_t field,
                                          FoundryBool *out);

    FoundryResult (*record_get_bool)(FoundryRecord record, uint32_t field, FoundryBool *out);
    /* Every signed integer field, widened. What the file stores is what the schema declared;
     * this is what covers all of them. */
    FoundryResult (*record_get_i64)(FoundryRecord record, uint32_t field, int64_t *out);
    FoundryResult (*record_get_u64)(FoundryRecord record, uint32_t field, uint64_t *out);
    FoundryResult (*record_get_f32)(FoundryRecord record, uint32_t field, float *out);
    /* Borrowed from the package's own bytes, and not NUL-terminated. */
    FoundryResult (*record_get_string)(FoundryRecord record, uint32_t field, FoundryStr *out);
    /* The second of the two calls in `_v1` that copy rather than borrow. Same rules as
     * `id_copy_string`: `needed` is always written, and too small is a refusal. */
    FoundryResult (*record_copy_string)(FoundryRecord record, uint32_t field, uint8_t *buffer,
                                        uint64_t capacity, uint64_t *needed);
    FoundryResult (*record_get_id)(FoundryRecord record, uint32_t field, FoundryContentId *out);

    /* An inline struct, as something that answers the same field calls one level down. This
     * composes to any depth and needs no path language invented for the boundary.
     *
     * The view it hands back is borrowed like everything else here, and it is borrowed from a
     * ring: it stays valid until enough further views have been opened to recycle its slot,
     * and a recycled one answers FOUNDRY_ERR_INVALID_HANDLE rather than reading whatever now
     * sits there. Reading a record never needs more than a few at once. */
    FoundryResult (*record_nested)(FoundryRecord record, uint32_t field, FoundryRecord *out);

    FoundryResult (*record_list_len)(FoundryRecord record, uint32_t field, uint32_t *out);
    FoundryResult (*record_list_get_i64)(FoundryRecord record, uint32_t field, uint32_t index,
                                         int64_t *out);
    FoundryResult (*record_list_get_f32)(FoundryRecord record, uint32_t field, uint32_t index,
                                         float *out);
    FoundryResult (*record_list_get_string)(FoundryRecord record, uint32_t field,
                                            uint32_t index, FoundryStr *out);
    FoundryResult (*record_list_get_id)(FoundryRecord record, uint32_t field, uint32_t index,
                                        FoundryContentId *out);
    FoundryResult (*record_list_nested)(FoundryRecord record, uint32_t field, uint32_t index,
                                        FoundryRecord *out);

    /* -- Packages ---------------------------------------------------------------------- */

    FoundryResult (*package_count)(uint32_t *out);
    /* Every loaded package, **in load order**, which is the order overrides were applied in
     * and therefore the only order worth walking them in. */
    FoundryResult (*package_next)(FoundryCursor *cursor, FoundryPackage *out);
    FoundryResult (*package_find)(FoundryContentId id, FoundryPackage *out);
    FoundryResult (*package_id)(FoundryPackage package, FoundryContentId *out);
    FoundryResult (*package_name)(FoundryPackage package, FoundryStr *out);
    FoundryResult (*package_version)(FoundryPackage package, uint32_t *out);
    /* Position in the load order. Zero is package zero — the engine's own content, loaded
     * through the same path a mod's is. */
    FoundryResult (*package_order)(FoundryPackage package, uint32_t *out);

    /* -- Schemas ----------------------------------------------------------------------- */

    FoundryResult (*schema_count)(uint32_t *out);
    FoundryResult (*schema_next)(FoundryCursor *cursor, FoundrySchema *out);
    FoundryResult (*schema_find)(FoundrySchemaId id, FoundrySchema *out);
    FoundryResult (*schema_id)(FoundrySchema schema, FoundrySchemaId *out);
    FoundryResult (*schema_version)(FoundrySchema schema, uint32_t *out);
    FoundryResult (*schema_field_count)(FoundrySchema schema, uint32_t *out);
    FoundryResult (*schema_field_name)(FoundrySchema schema, uint32_t field, FoundryStr *out);
    FoundryResult (*schema_field_type)(FoundrySchema schema, uint32_t field,
                                       FoundryFieldType *out);

    /* -- Assets ------------------------------------------------------------------------ */

    /* Loads an asset if it is not loaded, and adds a reference either way. **This is the one
     * reference count a mod owns**, and the one thing in `_v1` a mod must balance: an asset
     * acquired and never released stays in memory for the life of the process. */
    FoundryResult (*asset_acquire)(FoundryContentId id, FoundryAsset *out);
    FoundryResult (*asset_release)(FoundryAsset asset);
    /* Finds one already loaded, without acquiring it. */
    FoundryResult (*asset_find)(FoundryContentId id, FoundryAsset *out);
    FoundryResult (*asset_next)(FoundryCursor *cursor, FoundryAsset *out);
    FoundryResult (*asset_content_id)(FoundryAsset asset, FoundryContentId *out);
    FoundryResult (*asset_schema)(FoundryAsset asset, FoundrySchemaId *out);
    /* Zero means evictable, not freed — a real answer to "why is this still in memory". */
    FoundryResult (*asset_refcount)(FoundryAsset asset, uint32_t *out);

    /* -- Scene ------------------------------------------------------------------------- */

    /* Registers the in-memory half of a component whose schema the mod's content package
     * already declared. Registration is startup-only, like the engine's own component types. */
    FoundryResult (*world_register_component)(FoundryMod self,
                                              const FoundryComponentDesc *desc,
                                              FoundryComponentType *out);
    FoundryResult (*world_find_component_type)(FoundrySchemaId schema,
                                               FoundryComponentType *out);
    /* Registered types, in registration order. A changed registry invalidates the cursor. */
    FoundryResult (*world_component_type_next)(FoundryCursor *cursor,
                                                FoundryComponentType *out);
    FoundryResult (*world_component_type_schema)(FoundryComponentType type,
                                                  FoundrySchemaId *out);
    FoundryResult (*world_component_type_name)(FoundryComponentType type, FoundryStr *out);
    FoundryResult (*world_component_type_size)(FoundryComponentType type, uint32_t *out);
    FoundryResult (*world_component_type_alignment)(FoundryComponentType type, uint32_t *out);
    /* How many entities have one — the number a query over this type would visit, not a
     * count of registered types. */
    FoundryResult (*world_component_type_count)(FoundryComponentType type, uint32_t *out);
    /* Whether a save carries it, which is also whether `world_read_component` can show it.
     * False for a type registered through `world_register_component`: raw C storage has no
     * serialized form the engine could invent for it. */
    FoundryResult (*world_component_type_savable)(FoundryComponentType type,
                                                   FoundryBool *out);

    FoundryResult (*world_create_entity)(FoundryEntity *out);
    FoundryResult (*world_destroy_entity)(FoundryEntity entity);
    FoundryResult (*world_contains)(FoundryEntity entity, FoundryBool *out);
    FoundryResult (*world_entity_count)(uint32_t *out);
    /* Live entities, in slot-index order. A structural change invalidates the cursor. */
    FoundryResult (*world_next_entity)(FoundryCursor *cursor, FoundryEntity *out);

    /* `initial` is either NULL with zero size (construct or zero initialize), or exactly
     * the registered component size. Its bytes are copied before this call returns. */
    FoundryResult (*world_add_component)(FoundryEntity entity, FoundryComponentType type,
                                         const void *initial, uint32_t initial_size);
    FoundryResult (*world_remove_component)(FoundryEntity entity, FoundryComponentType type);
    FoundryResult (*world_has_component)(FoundryEntity entity, FoundryComponentType type,
                                         FoundryBool *out);

    FoundryResult (*world_register_system)(FoundryMod self, const FoundrySystemDesc *desc);
    /* Opens a query over one or more component types. The returned cursor names the query
     * until it ends, is recycled, or the world changes shape. A type the world does not
     * know is FOUNDRY_ERR_INVALID_HANDLE rather than a walk that quietly matches nothing.
     *
     * Iteration is driven by the FIRST named type, so name the most selective one first. */
    FoundryResult (*world_query_begin)(const FoundryComponentType *types, uint32_t count,
                                       FoundryCursor *out);
    FoundryResult (*world_query_next)(FoundryCursor *cursor, FoundryEntity *out);

    /* `entity_template` rather than `template`, which is a C++ keyword: this header has to
     * compile as C++ too, and a parameter name is documentation rather than ABI. */
    FoundryResult (*world_spawn)(FoundryContentId entity_template, FoundryEntity *out);
    FoundryResult (*world_spawn_scene)(FoundryContentId scene, uint32_t *out);
    /* Schema-described data for any savable component, read through the type's own
     * serializer rather than by casting its bytes — so it works for a type this build was
     * never compiled against. FOUNDRY_ERR_UNSUPPORTED for a type with no serializer, which
     * today means every type registered through `world_register_component`.
     *
     * The record is borrowed FOR THE CURRENT FRAME ONLY, and is the one borrow at this
     * boundary with that lifetime: it is serialized into the frame arena rather than read
     * out of a loaded package. Using it on a later frame is FOUNDRY_ERR_INVALID_HANDLE. */
    FoundryResult (*world_read_component)(FoundryEntity entity, FoundryComponentType type,
                                          FoundryRecord *out);
    /* The one raw-storage fast path: only the mod that registered `type` receives it, and
     * the pointer is invalid after the next structural world mutation. A marker type — one
     * registered with size zero — yields NULL and a size of zero, which is FOUNDRY_OK. */
    FoundryResult (*world_component_bytes)(FoundryMod self, FoundryEntity entity,
                                           FoundryComponentType type, void **out,
                                           uint32_t *size);

    /* -- Render2d --------------------------------------------------------------------- */

    FoundryResult (*render_texture_of_asset)(FoundryAsset asset, FoundryTexture *out);
    FoundryResult (*render_destroy_texture)(FoundryTexture texture);
    FoundryResult (*render_draw_sprite)(const FoundryRenderSprite *sprite);
    FoundryResult (*render_draw_text)(const FoundryRenderFont *font, FoundryStr text,
                                      const FoundryRenderTextOptions *options);
    FoundryResult (*render_add_view)(const FoundryRenderViewDesc *desc, FoundryView *out);
    FoundryResult (*render_select_view)(FoundryView view);
    FoundryResult (*render_camera_get)(FoundryRenderCamera *out);
    FoundryResult (*render_camera_set)(const FoundryRenderCamera *camera);
    FoundryResult (*render_world_to_screen)(FoundryRenderVec2 world, FoundryRenderVec2 *out);
    FoundryResult (*render_screen_to_world)(FoundryRenderVec2 screen, FoundryRenderVec2 *out);
    FoundryResult (*render_stats)(FoundryRenderStats *out);

    /* -- UI --------------------------------------------------------------------------- */

    FoundryResult (*ui_begin)(const FoundryUiRect *viewport);
    FoundryResult (*ui_end)(void);
    FoundryResult (*ui_push_id)(FoundryUiId id);
    FoundryResult (*ui_pop_id)(void);
    FoundryResult (*ui_begin_panel)(FoundryUiId id, const FoundryUiRect *bounds);
    FoundryResult (*ui_end_panel)(void);
    FoundryResult (*ui_begin_row)(FoundryUiId id, float height);
    FoundryResult (*ui_end_row)(void);
    FoundryResult (*ui_begin_scroll)(FoundryUiId id, const FoundryUiRect *bounds, float content);
    FoundryResult (*ui_end_scroll)(void);
    FoundryResult (*ui_label)(FoundryStr text);
    FoundryResult (*ui_button)(FoundryUiId id, FoundryStr text, FoundryBool *out);
    FoundryResult (*ui_checkbox)(FoundryUiId id, FoundryStr text, FoundryBool *checked,
                                 FoundryBool *changed);
    FoundryResult (*ui_slider)(FoundryUiId id, FoundryStr text, float *value, float min, float max,
                               FoundryBool *changed);
    FoundryResult (*ui_slider_int)(FoundryUiId id, FoundryStr text, int32_t *value, int32_t min,
                                   int32_t max, FoundryBool *changed);
    FoundryResult (*ui_separator)(void);
    FoundryResult (*ui_spacer)(float size);
    FoundryResult (*ui_collapsing_header)(FoundryUiId id, FoundryStr text, FoundryBool *open);
    FoundryResult (*ui_text_field)(FoundryUiId id, uint8_t *buffer, uint64_t capacity,
                                   uint64_t *length, FoundryBool *changed);
    FoundryResult (*ui_plot)(const float *samples, uint64_t count,
                             const FoundryUiPlotOptions *options);
    FoundryResult (*ui_style_get)(FoundryUiStyle *out);
    FoundryResult (*ui_style_set)(const FoundryUiStyle *style);
    FoundryResult (*ui_wants_keyboard)(FoundryBool *out);
    FoundryResult (*ui_wants_pointer)(FoundryBool *out);

    /* -- Audio ------------------------------------------------------------------------ */

    FoundryResult (*audio_play)(FoundryContentId id, float gain, float pan, float pitch,
                                FoundryBool looping, FoundryVoice *out);
    FoundryResult (*audio_stop)(FoundryVoice voice);
    FoundryResult (*audio_set_gain)(FoundryVoice voice, float gain);
    FoundryResult (*audio_set_pan)(FoundryVoice voice, float pan);
    FoundryResult (*audio_set_pitch)(FoundryVoice voice, float pitch);
    FoundryResult (*audio_set_master_gain)(float gain);

    /* -- Physics2d -------------------------------------------------------------------- */

    FoundryResult (*physics_create_body)(const FoundryPhysicsBodyDesc *desc, FoundryBody *out);
    FoundryResult (*physics_destroy_body)(FoundryBody body);
    FoundryResult (*physics_move_body)(FoundryBody body, FoundryPhysicsVec2 motion,
                                       FoundryPhysicsHit *hits, uint32_t capacity,
                                       FoundryPhysicsMoveResult *out);
    FoundryResult (*physics_query_point)(FoundryPhysicsVec2 point, uint32_t mask,
                                         FoundryPhysicsQueryHit *hits, uint32_t capacity,
                                         uint32_t *count, uint32_t *total);
    FoundryResult (*physics_query_aabb)(FoundryPhysicsVec2 min, FoundryPhysicsVec2 max,
                                        uint32_t mask, FoundryPhysicsQueryHit *hits,
                                        uint32_t capacity, uint32_t *count, uint32_t *total);
    FoundryResult (*physics_query_ray)(FoundryPhysicsVec2 from, FoundryPhysicsVec2 to,
                                       uint32_t mask, FoundryPhysicsHit *hits, uint32_t capacity,
                                       uint32_t *count, uint32_t *total);
    FoundryResult (*physics_body_contacts)(FoundryBody body, FoundryPhysicsQueryHit *hits,
                                           uint32_t capacity, uint32_t *count, uint32_t *total);
} FoundryApi_v1;

/*
 * ABI v2 is a separate flat table. Its common entries deliberately repeat v1 in the same
 * relative order; it is queried as version 2 and is never obtained by casting a v1 table.
 * The v1 declaration above remains frozen.
 */
typedef struct FoundryApi_v2 {
    /* Always 2, and `sizeof(FoundryApi_v2)` as the host built it. Both are redundant with
     * `get_api`, and both are here for the case the query cannot reach: a crash dump on a
     * player's machine, where the one thing worth knowing is whether the mod was built
     * against this header. Eight bytes, and every other answer involves asking the player to
     * reproduce something. */
    uint32_t version;
    uint32_t size;

    /* -- Results and logging ----------------------------------------------------------- */

    /* The name of a result code — "FOUNDRY_ERR_NOT_FOUND" — so a mod can log legibly without
     * shipping its own copy of the table and letting it go stale. Empty for a code this host
     * has never issued, which is the honest answer rather than an invented one. Always
     * available: it needs no subsystem. */
    FoundryStr (*result_name)(FoundryResult result);

    /* Writes one line to the engine's log, tagged with the mod's own scope. Available on a
     * host with no subsystems at all, deliberately: a mod refusing itself has to be able to
     * say why. */
    FoundryResult (*log_write)(FoundryMod self, FoundryLogLevel level, FoundryStr message);

    /* Walks the in-memory log ring, oldest first, from a cursor starting at
     * FOUNDRY_CURSOR_BEGIN. Returns FOUNDRY_END when there is nothing more. */
    FoundryResult (*log_next)(FoundryCursor *cursor, FoundryLogRecord *out);

    /* -- Content identity -------------------------------------------------------------- */

    /* Hashes a `namespace:name` string, validating its shape first — the same validation the
     * content compiler applies, so a string this refuses would never have compiled either.
     * `foundry_content_id` in this header hashes without validating; this is the checked
     * form, and needs no subsystem. */
    FoundryResult (*id_from_string)(FoundryStr text, FoundryContentId *out);

    /* The spelling of an id, borrowed from the package that supplied it. FOUNDRY_ERR_NOT_FOUND
     * when nothing loaded carries that id: a hash cannot be reversed, so an id nobody spells
     * has no name to give. */
    FoundryResult (*id_to_string)(FoundryContentId id, FoundryStr *out);

    /* The same spelling, copied into the caller's buffer, for a mod that needs the bytes past
     * the call. Writes `*needed` with the length whether or not it fitted and returns
     * FOUNDRY_ERR_LIMIT rather than truncating — silent truncation of a name is how a mod
     * ships with a bug nobody can see. `buffer` may be NULL when `capacity` is 0, which is
     * how a caller asks for the length alone. */
    FoundryResult (*id_copy_string)(FoundryContentId id, uint8_t *buffer, uint64_t capacity,
                                    uint64_t *needed);

    /* -- The frame --------------------------------------------------------------------- */

    /* The engine's frame counter, which is what a log line's `frame` stamp lines up with. */
    FoundryResult (*frame_index)(uint64_t *out);

    /* Wall-clock length of the previous frame. **Presentation only.** Simulation time is the
     * tick, never this: a mod that integrates motion against a wall clock has made its own
     * behaviour depend on how fast the machine is. */
    FoundryResult (*frame_delta_ns)(uint64_t *out);

    /* Total simulated time, which is an exact multiple of the tick and is therefore the same
     * number on every machine that ran the same ticks. */
    FoundryResult (*elapsed_ns)(uint64_t *out);

    /* The exact length of one simulation step. Nanoseconds rather than a rate in hertz,
     * because the engine's timestep is an exact rational and a rounded rate would not
     * reproduce it. */
    FoundryResult (*tick_delta_ns)(uint64_t *out);

    /* -- The profiler ------------------------------------------------------------------ */

    /* Opens a named timing span, so a mod's own work appears in the profiler beside the
     * engine's. Strictly nested, and every span a mod opens it must close. */
    FoundryResult (*scope_begin)(FoundryStr name);

    /* Closes the innermost span this mod opened. FOUNDRY_ERR_REFUSED when none is open,
     * rather than closing one the engine or the game opened. */
    FoundryResult (*scope_end)(void);

    /* -- Memory ------------------------------------------------------------------------ */

    /* Opens a named counter in the engine's memory report. The name is copied. */
    FoundryResult (*memory_counter_open)(FoundryMod self, FoundryStr name,
                                         FoundryMemoryCounter *out);

    /* Publishes a mod's own numbers into a counter it opened. */
    FoundryResult (*memory_counter_set)(FoundryMemoryCounter counter,
                                        const FoundryMemoryStats *stats);

    /* -- Content ----------------------------------------------------------------------- */

    /* Bumped whenever content changes under the program — a hot reload, a package added.
     * **The one signal a mod needs**: anything derived from content, including every record
     * handle and every borrowed string, is derived again when this moves. */
    FoundryResult (*content_generation)(uint64_t *out);

    /* The record a content id names, after every package has been merged and every override
     * applied. What a mod gets is the definition that *won*, which is the same one the game
     * sees — there is no privileged view. */
    FoundryResult (*content_find)(FoundryContentId id, FoundryRecord *out);

    /* Every record, in merge order. */
    FoundryResult (*content_next)(FoundryCursor *cursor, FoundryRecord *out);

    /* Every record of one schema, in merge order. How a mod finds "all the items" without
     * knowing what any package called them. */
    FoundryResult (*content_next_of_schema)(FoundrySchemaId schema, FoundryCursor *cursor,
                                            FoundryRecord *out);

    /* -- Reading a record -------------------------------------------------------------- */

    /*
     * A record is read by asking its schema what each field is and then calling the matching
     * reader. That is how a mod reads a record type it has never heard of — including one
     * another mod declared — and it is what the debug overlay's inspector already does.
     *
     * A field a record does not carry answers FOUNDRY_ERR_NOT_FOUND, which is different from
     * a field that is not in the schema at all (FOUNDRY_ERR_INVALID_ARGUMENT) and different
     * again from asking for it with the wrong reader (also INVALID_ARGUMENT). A record
     * written against an older version of its schema answers newer fields with their
     * declared defaults, which is what makes a schema able to grow.
     */

    /* A nested block has no identity of its own — that is what nested means — so `record_id`,
     * `record_name` and `record_package` answer FOUNDRY_ERR_NOT_FOUND for one. */
    FoundryResult (*record_id)(FoundryRecord record, FoundryContentId *out);
    FoundryResult (*record_name)(FoundryRecord record, FoundryStr *out);
    FoundryResult (*record_schema)(FoundryRecord record, FoundrySchemaId *out);
    FoundryResult (*record_package)(FoundryRecord record, FoundryPackage *out);

    FoundryResult (*record_field_count)(FoundryRecord record, uint32_t *out);
    FoundryResult (*record_field_index)(FoundryRecord record, FoundryStr name, uint32_t *out);
    FoundryResult (*record_field_name)(FoundryRecord record, uint32_t field, FoundryStr *out);
    FoundryResult (*record_field_type)(FoundryRecord record, uint32_t field,
                                       FoundryFieldType *out);
    /* Whether the record actually carries a value for the field, as opposed to the field
     * being absent. A missing optional field and a field set to its default are different
     * things, and collapsing them would make "this item drops nothing" and "this item's drop
     * was never specified" indistinguishable. */
    FoundryResult (*record_field_present)(FoundryRecord record, uint32_t field,
                                          FoundryBool *out);

    FoundryResult (*record_get_bool)(FoundryRecord record, uint32_t field, FoundryBool *out);
    /* Every signed integer field, widened. What the file stores is what the schema declared;
     * this is what covers all of them. */
    FoundryResult (*record_get_i64)(FoundryRecord record, uint32_t field, int64_t *out);
    FoundryResult (*record_get_u64)(FoundryRecord record, uint32_t field, uint64_t *out);
    FoundryResult (*record_get_f32)(FoundryRecord record, uint32_t field, float *out);
    /* Borrowed from the package's own bytes, and not NUL-terminated. */
    FoundryResult (*record_get_string)(FoundryRecord record, uint32_t field, FoundryStr *out);
    /* The second of the two calls in `_v1` that copy rather than borrow. Same rules as
     * `id_copy_string`: `needed` is always written, and too small is a refusal. */
    FoundryResult (*record_copy_string)(FoundryRecord record, uint32_t field, uint8_t *buffer,
                                        uint64_t capacity, uint64_t *needed);
    FoundryResult (*record_get_id)(FoundryRecord record, uint32_t field, FoundryContentId *out);

    /* An inline struct, as something that answers the same field calls one level down. This
     * composes to any depth and needs no path language invented for the boundary.
     *
     * The view it hands back is borrowed like everything else here, and it is borrowed from a
     * ring: it stays valid until enough further views have been opened to recycle its slot,
     * and a recycled one answers FOUNDRY_ERR_INVALID_HANDLE rather than reading whatever now
     * sits there. Reading a record never needs more than a few at once. */
    FoundryResult (*record_nested)(FoundryRecord record, uint32_t field, FoundryRecord *out);

    FoundryResult (*record_list_len)(FoundryRecord record, uint32_t field, uint32_t *out);
    FoundryResult (*record_list_get_i64)(FoundryRecord record, uint32_t field, uint32_t index,
                                         int64_t *out);
    FoundryResult (*record_list_get_f32)(FoundryRecord record, uint32_t field, uint32_t index,
                                         float *out);
    FoundryResult (*record_list_get_string)(FoundryRecord record, uint32_t field,
                                            uint32_t index, FoundryStr *out);
    FoundryResult (*record_list_get_id)(FoundryRecord record, uint32_t field, uint32_t index,
                                        FoundryContentId *out);
    FoundryResult (*record_list_nested)(FoundryRecord record, uint32_t field, uint32_t index,
                                        FoundryRecord *out);

    /* -- Packages ---------------------------------------------------------------------- */

    FoundryResult (*package_count)(uint32_t *out);
    /* Every loaded package, **in load order**, which is the order overrides were applied in
     * and therefore the only order worth walking them in. */
    FoundryResult (*package_next)(FoundryCursor *cursor, FoundryPackage *out);
    FoundryResult (*package_find)(FoundryContentId id, FoundryPackage *out);
    FoundryResult (*package_id)(FoundryPackage package, FoundryContentId *out);
    FoundryResult (*package_name)(FoundryPackage package, FoundryStr *out);
    FoundryResult (*package_version)(FoundryPackage package, uint32_t *out);
    /* Position in the load order. Zero is package zero — the engine's own content, loaded
     * through the same path a mod's is. */
    FoundryResult (*package_order)(FoundryPackage package, uint32_t *out);

    /* -- Schemas ----------------------------------------------------------------------- */

    FoundryResult (*schema_count)(uint32_t *out);
    FoundryResult (*schema_next)(FoundryCursor *cursor, FoundrySchema *out);
    FoundryResult (*schema_find)(FoundrySchemaId id, FoundrySchema *out);
    FoundryResult (*schema_id)(FoundrySchema schema, FoundrySchemaId *out);
    FoundryResult (*schema_version)(FoundrySchema schema, uint32_t *out);
    FoundryResult (*schema_field_count)(FoundrySchema schema, uint32_t *out);
    FoundryResult (*schema_field_name)(FoundrySchema schema, uint32_t field, FoundryStr *out);
    FoundryResult (*schema_field_type)(FoundrySchema schema, uint32_t field,
                                       FoundryFieldType *out);

    /* -- Assets ------------------------------------------------------------------------ */

    /* Loads an asset if it is not loaded, and adds a reference either way. **This is the one
     * reference count a mod owns**, and the one thing in `_v1` a mod must balance: an asset
     * acquired and never released stays in memory for the life of the process. */
    FoundryResult (*asset_acquire)(FoundryContentId id, FoundryAsset *out);
    FoundryResult (*asset_release)(FoundryAsset asset);
    /* Finds one already loaded, without acquiring it. */
    FoundryResult (*asset_find)(FoundryContentId id, FoundryAsset *out);
    FoundryResult (*asset_next)(FoundryCursor *cursor, FoundryAsset *out);
    FoundryResult (*asset_content_id)(FoundryAsset asset, FoundryContentId *out);
    FoundryResult (*asset_schema)(FoundryAsset asset, FoundrySchemaId *out);
    /* Zero means evictable, not freed — a real answer to "why is this still in memory". */
    FoundryResult (*asset_refcount)(FoundryAsset asset, uint32_t *out);

    /* -- Scene ------------------------------------------------------------------------- */

    /* Registers the in-memory half of a component whose schema the mod's content package
     * already declared. Registration is startup-only, like the engine's own component types. */
    FoundryResult (*world_register_component)(FoundryMod self,
                                              const FoundryComponentDesc *desc,
                                              FoundryComponentType *out);
    FoundryResult (*world_find_component_type)(FoundrySchemaId schema,
                                               FoundryComponentType *out);
    /* Registered types, in registration order. A changed registry invalidates the cursor. */
    FoundryResult (*world_component_type_next)(FoundryCursor *cursor,
                                                FoundryComponentType *out);
    FoundryResult (*world_component_type_schema)(FoundryComponentType type,
                                                  FoundrySchemaId *out);
    FoundryResult (*world_component_type_name)(FoundryComponentType type, FoundryStr *out);
    FoundryResult (*world_component_type_size)(FoundryComponentType type, uint32_t *out);
    FoundryResult (*world_component_type_alignment)(FoundryComponentType type, uint32_t *out);
    /* How many entities have one — the number a query over this type would visit, not a
     * count of registered types. */
    FoundryResult (*world_component_type_count)(FoundryComponentType type, uint32_t *out);
    /* Whether a save carries it, which is also whether `world_read_component` can show it.
     * False for a type registered through `world_register_component`: raw C storage has no
     * serialized form the engine could invent for it. */
    FoundryResult (*world_component_type_savable)(FoundryComponentType type,
                                                   FoundryBool *out);

    FoundryResult (*world_create_entity)(FoundryEntity *out);
    FoundryResult (*world_destroy_entity)(FoundryEntity entity);
    FoundryResult (*world_contains)(FoundryEntity entity, FoundryBool *out);
    FoundryResult (*world_entity_count)(uint32_t *out);
    /* Live entities, in slot-index order. A structural change invalidates the cursor. */
    FoundryResult (*world_next_entity)(FoundryCursor *cursor, FoundryEntity *out);

    /* `initial` is either NULL with zero size (construct or zero initialize), or exactly
     * the registered component size. Its bytes are copied before this call returns. */
    FoundryResult (*world_add_component)(FoundryEntity entity, FoundryComponentType type,
                                         const void *initial, uint32_t initial_size);
    FoundryResult (*world_remove_component)(FoundryEntity entity, FoundryComponentType type);
    FoundryResult (*world_has_component)(FoundryEntity entity, FoundryComponentType type,
                                         FoundryBool *out);

    FoundryResult (*world_register_system)(FoundryMod self, const FoundrySystemDesc *desc);
    /* Opens a query over one or more component types. The returned cursor names the query
     * until it ends, is recycled, or the world changes shape. A type the world does not
     * know is FOUNDRY_ERR_INVALID_HANDLE rather than a walk that quietly matches nothing.
     *
     * Iteration is driven by the FIRST named type, so name the most selective one first. */
    FoundryResult (*world_query_begin)(const FoundryComponentType *types, uint32_t count,
                                       FoundryCursor *out);
    FoundryResult (*world_query_next)(FoundryCursor *cursor, FoundryEntity *out);

    /* `entity_template` rather than `template`, which is a C++ keyword: this header has to
     * compile as C++ too, and a parameter name is documentation rather than ABI. */
    FoundryResult (*world_spawn)(FoundryContentId entity_template, FoundryEntity *out);
    FoundryResult (*world_spawn_scene)(FoundryContentId scene, uint32_t *out);
    /* Schema-described data for any savable component, read through the type's own
     * serializer rather than by casting its bytes — so it works for a type this build was
     * never compiled against. FOUNDRY_ERR_UNSUPPORTED for a type with no serializer, which
     * today means every type registered through `world_register_component`.
     *
     * The record is borrowed FOR THE CURRENT FRAME ONLY, and is the one borrow at this
     * boundary with that lifetime: it is serialized into the frame arena rather than read
     * out of a loaded package. Using it on a later frame is FOUNDRY_ERR_INVALID_HANDLE. */
    FoundryResult (*world_read_component)(FoundryEntity entity, FoundryComponentType type,
                                          FoundryRecord *out);
    /* The one raw-storage fast path: only the mod that registered `type` receives it, and
     * the pointer is invalid after the next structural world mutation. A marker type — one
     * registered with size zero — yields NULL and a size of zero, which is FOUNDRY_OK. */
    FoundryResult (*world_component_bytes)(FoundryMod self, FoundryEntity entity,
                                           FoundryComponentType type, void **out,
                                           uint32_t *size);

    /* -- Render2d --------------------------------------------------------------------- */

    FoundryResult (*render_texture_of_asset)(FoundryAsset asset, FoundryTexture *out);
    FoundryResult (*render_destroy_texture)(FoundryTexture texture);
    FoundryResult (*render_draw_sprite)(const FoundryRenderSprite *sprite);
    FoundryResult (*render_draw_text)(const FoundryRenderFont *font, FoundryStr text,
                                      const FoundryRenderTextOptions *options);
    FoundryResult (*render_add_view)(const FoundryRenderViewDesc *desc, FoundryView *out);
    FoundryResult (*render_select_view)(FoundryView view);
    FoundryResult (*render_camera_get)(FoundryRenderCamera *out);
    FoundryResult (*render_camera_set)(const FoundryRenderCamera *camera);
    FoundryResult (*render_world_to_screen)(FoundryRenderVec2 world, FoundryRenderVec2 *out);
    FoundryResult (*render_screen_to_world)(FoundryRenderVec2 screen, FoundryRenderVec2 *out);
    FoundryResult (*render_stats)(FoundryRenderStats *out);

    /* -- UI --------------------------------------------------------------------------- */

    FoundryResult (*ui_begin)(const FoundryUiRect *viewport);
    FoundryResult (*ui_end)(void);
    FoundryResult (*ui_push_id)(FoundryUiId id);
    FoundryResult (*ui_pop_id)(void);
    FoundryResult (*ui_begin_panel)(FoundryUiId id, const FoundryUiRect *bounds);
    FoundryResult (*ui_end_panel)(void);
    FoundryResult (*ui_begin_row)(FoundryUiId id, float height);
    FoundryResult (*ui_end_row)(void);
    FoundryResult (*ui_begin_scroll)(FoundryUiId id, const FoundryUiRect *bounds, float content);
    FoundryResult (*ui_end_scroll)(void);
    FoundryResult (*ui_label)(FoundryStr text);
    FoundryResult (*ui_button)(FoundryUiId id, FoundryStr text, FoundryBool *out);
    FoundryResult (*ui_checkbox)(FoundryUiId id, FoundryStr text, FoundryBool *checked,
                                 FoundryBool *changed);
    FoundryResult (*ui_slider)(FoundryUiId id, FoundryStr text, float *value, float min, float max,
                               FoundryBool *changed);
    FoundryResult (*ui_slider_int)(FoundryUiId id, FoundryStr text, int32_t *value, int32_t min,
                                   int32_t max, FoundryBool *changed);
    FoundryResult (*ui_separator)(void);
    FoundryResult (*ui_spacer)(float size);
    FoundryResult (*ui_collapsing_header)(FoundryUiId id, FoundryStr text, FoundryBool *open);
    FoundryResult (*ui_text_field)(FoundryUiId id, uint8_t *buffer, uint64_t capacity,
                                   uint64_t *length, FoundryBool *changed);
    FoundryResult (*ui_plot)(const float *samples, uint64_t count,
                             const FoundryUiPlotOptions *options);
    FoundryResult (*ui_style_get)(FoundryUiStyle *out);
    FoundryResult (*ui_style_set)(const FoundryUiStyle *style);
    FoundryResult (*ui_wants_keyboard)(FoundryBool *out);
    FoundryResult (*ui_wants_pointer)(FoundryBool *out);

    /* -- Audio ------------------------------------------------------------------------ */

    FoundryResult (*audio_play)(FoundryContentId id, float gain, float pan, float pitch,
                                FoundryBool looping, FoundryVoice *out);
    FoundryResult (*audio_stop)(FoundryVoice voice);
    FoundryResult (*audio_set_gain)(FoundryVoice voice, float gain);
    FoundryResult (*audio_set_pan)(FoundryVoice voice, float pan);
    FoundryResult (*audio_set_pitch)(FoundryVoice voice, float pitch);
    FoundryResult (*audio_set_master_gain)(float gain);

    /* -- Physics2d -------------------------------------------------------------------- */

    FoundryResult (*physics_create_body)(const FoundryPhysicsBodyDesc *desc, FoundryBody *out);
    FoundryResult (*physics_destroy_body)(FoundryBody body);
    FoundryResult (*physics_move_body)(FoundryBody body, FoundryPhysicsVec2 motion,
                                       FoundryPhysicsHit *hits, uint32_t capacity,
                                       FoundryPhysicsMoveResult *out);
    FoundryResult (*physics_query_point)(FoundryPhysicsVec2 point, uint32_t mask,
                                         FoundryPhysicsQueryHit *hits, uint32_t capacity,
                                         uint32_t *count, uint32_t *total);
    FoundryResult (*physics_query_aabb)(FoundryPhysicsVec2 min, FoundryPhysicsVec2 max,
                                        uint32_t mask, FoundryPhysicsQueryHit *hits,
                                        uint32_t capacity, uint32_t *count, uint32_t *total);
    FoundryResult (*physics_query_ray)(FoundryPhysicsVec2 from, FoundryPhysicsVec2 to,
                                       uint32_t mask, FoundryPhysicsHit *hits, uint32_t capacity,
                                       uint32_t *count, uint32_t *total);
    FoundryResult (*physics_body_contacts)(FoundryBody body, FoundryPhysicsQueryHit *hits,
                                           uint32_t capacity, uint32_t *count, uint32_t *total);
    /* Copies one `foundry:script` payload made by the host's exact built-in source
     * loader. `needed` and `revision` are required and are written for a valid asset
     * even when capacity is too small; that case returns FOUNDRY_ERR_LIMIT and copies
     * nothing. `(NULL, 0)` is the sizing probe. A successful copy has exactly `needed`
     * bytes and no terminator. Balance the asset reference with `asset_release`.
     *
     * A stale handle is FOUNDRY_ERR_INVALID_HANDLE. Another asset kind or loader is
     * FOUNDRY_ERR_UNSUPPORTED. An absent engine or source loader is
     * FOUNDRY_ERR_UNAVAILABLE. */
    FoundryResult (*script_source_copy)(FoundryAsset asset, uint8_t *buffer,
                                        uint64_t capacity, uint64_t *needed,
                                        uint64_t *revision);
} FoundryApi_v2;


/* == Authoring (v4) ==================================================================== */

/*
 * The values the authoring surface crosses with (ADR-0042, `editor.md` §9).
 *
 * **Numbers cross as text here, and that is deliberate.** The simulation side of this API
 * reads an `f32` because that is what a sprite's position is. An *author* typing
 * 9007199254740993 into a `u64` field is not describing a sprite, and a boundary that sent
 * it through a float would silently change it. So an authoring scalar carries its canonical
 * decimal spelling plus the field type the schema declares, and the exact value survives in
 * both directions. No v1-v3 call changes; this is a second representation for a second job.
 *
 * **Unset, default and present are three states.** FoundryAuthorNodeInfo carries `authored`
 * and `presence` separately for that reason: a field the source does not write, whose schema
 * has a default, is neither missing nor set, and a form that could not tell them apart would
 * write defaults into files nobody asked it to.
 */

/* Whether a field must be written, may be, or reads as something when it is not.
 * FOUNDRY_AUTHOR_ELEMENT is the fourth because a list element has no declaration of its own,
 * so asking whether it is optional is a question with no answer. */
typedef enum FoundryAuthorPresence {
    FOUNDRY_AUTHOR_REQUIRED = 0,
    FOUNDRY_AUTHOR_OPTIONAL = 1,
    FOUNDRY_AUTHOR_DEFAULT = 2,
    FOUNDRY_AUTHOR_ELEMENT = 3
} FoundryAuthorPresence;

typedef enum FoundryAuthorSeverity {
    FOUNDRY_AUTHOR_ERROR = 0,
    FOUNDRY_AUTHOR_WARNING = 1,
    FOUNDRY_AUTHOR_NOTE = 2
} FoundryAuthorSeverity;

/* Which tree a node came from. A client shows a dependency definition differently from its
 * own draft, and the same calls read both. */
typedef enum FoundryAuthorNodeRoot {
    /* A record in one of this workspace's source documents. Editable. */
    FOUNDRY_AUTHOR_ROOT_SOURCE = 0,
    /* A definition in a host-granted dependency package. Read-only. */
    FOUNDRY_AUTHOR_ROOT_DEPENDENCY = 1,
    /* A record in the runtime snapshot the last preview activation published. Read-only. */
    FOUNDRY_AUTHOR_ROOT_PREVIEW = 2,
    /* A schema's declared default, walked as a value. Read-only. */
    FOUNDRY_AUTHOR_ROOT_DEFAULT = 3
} FoundryAuthorNodeRoot;

typedef enum FoundryAuthorPreviewOutcome {
    FOUNDRY_AUTHOR_PREVIEW_NONE = 0,
    FOUNDRY_AUTHOR_PREVIEW_ACTIVE = 1,
    FOUNDRY_AUTHOR_PREVIEW_FAILED = 2
} FoundryAuthorPreviewOutcome;

typedef enum FoundryAuthorSaveOutcome {
    /* The draft already matched the file; nothing was written. */
    FOUNDRY_AUTHOR_SAVE_UNCHANGED = 0,
    FOUNDRY_AUTHOR_SAVE_PUBLISHED = 1,
    FOUNDRY_AUTHOR_SAVE_FAILED = 2
} FoundryAuthorSaveOutcome;

typedef enum FoundryAuthorSaveFailure {
    FOUNDRY_AUTHOR_SAVE_OK = 0,
    FOUNDRY_AUTHOR_SAVE_EXTERNAL_CHANGE = 1,
    FOUNDRY_AUTHOR_SAVE_DOCUMENT_BUDGET = 2,
    FOUNDRY_AUTHOR_SAVE_IO_FAILED = 3,
    FOUNDRY_AUTHOR_SAVE_OUT_OF_MEMORY = 4
} FoundryAuthorSaveFailure;

typedef enum FoundryAuthorExportKind {
    /* The compiled package and the assets the compiler produced. */
    FOUNDRY_AUTHOR_EXPORT_COMPILED = 0,
    /* The complete runtime tree, ordinary assets included. */
    FOUNDRY_AUTHOR_EXPORT_RUNTIME = 1
} FoundryAuthorExportKind;

/* What a workspace is, and what may be done with it right now. */
typedef struct FoundryAuthorWorkspaceInfo {
    uint64_t revision;
    /* The package's `namespace:name` from its manifest. Empty when there is no readable
     * manifest, which is a state rather than a failure: it is where a new package starts. */
    FoundryStr package_name;
    uint32_t package_version;
    uint32_t document_count;
    uint32_t dependency_count;
    uint32_t build_count;
    /* Entries in the last operation's diagnostic snapshot, and how many that operation did
     * not record because its cap was reached. */
    uint32_t diagnostic_count;
    uint32_t suppressed_diagnostics;
    uint32_t export_count;
    FoundryBool can_edit;
    FoundryBool can_save;
    FoundryBool can_build;
    FoundryBool can_preview;
    FoundryBool dirty;
    FoundryBool externally_changed;
    FoundryBool can_undo;
    FoundryBool can_redo;
    FoundryBool history_truncated;
    FoundryBool has_manifest;
    uint8_t reserved[10];
} FoundryAuthorWorkspaceInfo;

/* The bounds this workspace was configured with, so a client can say why something was
 * refused instead of guessing. */
typedef struct FoundryAuthorLimits {
    uint64_t max_source_bytes;
    uint64_t max_total_source_bytes;
    uint64_t max_document_bytes;
    uint64_t max_history_bytes;
    uint64_t max_snapshot_bytes;
    uint32_t max_history_commands;
    uint32_t max_live_builds;
    uint32_t max_sources;
    uint32_t max_diagnostics;
    uint32_t max_nesting_depth;
    uint32_t max_list_elements;
} FoundryAuthorLimits;

typedef struct FoundryAuthorDocumentInfo {
    /* The document's package-relative name, which is also its identity to the compiler. */
    FoundryStr path;
    uint64_t source_bytes;
    uint32_t index;
    uint32_t reserved0;
    FoundryBool dirty;
    /* False for a document created in memory whose create-if-absent save has not run. */
    FoundryBool on_disk;
    FoundryBool externally_changed;
    FoundryBool parseable;
    /* Typed commands may touch it. An incomplete draft is still editable; an unknown schema
     * or an unsupported directive is not. */
    FoundryBool editable;
    uint8_t reserved[3];
} FoundryAuthorDocumentInfo;

/* One node of a record, in whichever tree it came from. */
typedef struct FoundryAuthorNodeInfo {
    /* The field's declared name, or the record's spelling at a root. Empty for a list
     * element. */
    FoundryStr name;
    /* The record's content id at a root; zero below one. */
    FoundryContentId id;
    /* The record's schema at a root; zero below one. */
    FoundrySchemaId schema;
    /* FoundryFieldType. */
    int32_t field_type;
    /* FoundryAuthorPresence. */
    int32_t presence;
    /* Fields of a nested block, elements of a list, zero for a scalar. A nested block's
     * count is its schema's even when nothing has been written into it. */
    uint32_t child_count;
    /* The field index or list position this node has in its parent; zero at a root. */
    uint32_t index;
    /* FoundryAuthorNodeRoot. */
    int32_t root;
    /* Which document a source node belongs to, or which dependency package a dependency
     * node came from. Zero for the other roots. */
    uint32_t container;
    /* Whether the source or the stored record actually carries this node, as distinct from
     * the schema having a default for it. */
    FoundryBool authored;
    FoundryBool is_root;
    FoundryBool is_list;
    /* False for every read-only root: a command naming such a node is refused. */
    FoundryBool writable;
    /* How many selectors were followed to reach this node. Zero at a root. */
    uint8_t depth;
    uint8_t reserved[3];
} FoundryAuthorNodeInfo;

/* One node of a schema declaration: a schema, one of its fields, a nested field, or a
 * list's element type. */
typedef struct FoundryAuthorSchemaNodeInfo {
    /* The schema's `namespace:name` at a root, the field's name below one, empty for a
     * list's element type. */
    FoundryStr name;
    FoundrySchemaId schema;
    /* FoundryFieldType. At a root this is FOUNDRY_FIELD_NESTED, because a record is laid
     * out exactly like one. */
    int32_t field_type;
    /* FoundryAuthorPresence. */
    int32_t presence;
    uint32_t child_count;
    /* The schema version that introduced this field. Zero at a root. */
    uint32_t since;
    /* The schema's own version at a root. Zero below one. */
    uint32_t version;
    uint32_t index;
    FoundryBool is_root;
    /* Whether author_schema_node_default has a value to hand back. */
    FoundryBool has_default;
    FoundryBool is_list_element;
    uint8_t reserved[5];
} FoundryAuthorSchemaNodeInfo;

/*
 * A scalar crossing in either direction.
 *
 * In: `field_type` is what the caller believes the schema declares and is checked against
 * it; `text` carries the spelling and `boolean` the value of a boolean. An empty container
 * is FOUNDRY_FIELD_NESTED or FOUNDRY_FIELD_LIST with empty text, which is how "add the
 * optional block" and "start a list" are said.
 *
 * Out: `text` is **borrowed**, and a formatted number lives only until the next scalar read.
 * `id` carries the hash even when no spelling could be recovered for it.
 */
typedef struct FoundryAuthorValue {
    /* FoundryFieldType. */
    int32_t field_type;
    FoundryBool boolean;
    uint8_t reserved[3];
    /* The content id of an `id` value. Ignored on the way in, where the spelling is what a
     * source file has to contain. */
    FoundryContentId id;
    /* Canonical decimal for a number, the bytes themselves for a string, the
     * `namespace:name` spelling for an id, empty for a boolean and an empty container. */
    FoundryStr text;
} FoundryAuthorValue;

/* One host-granted dependency package. */
typedef struct FoundryAuthorPackageInfo {
    FoundryStr name;
    /* The path the host named it by. Diagnostics only: a path never means identity. */
    FoundryStr path;
    FoundryContentId id;
    uint32_t version;
    uint32_t record_count;
    uint32_t index;
    uint32_t reserved;
} FoundryAuthorPackageInfo;

/* What one accepted command did. */
typedef struct FoundryAuthorEdit {
    uint64_t revision;
    FoundryDocument document;
    /* Where a client should put the selection afterwards, already re-resolved against the
     * new revision. Null when the command removed what it was pointing at. */
    FoundrySourceNode selection;
    FoundryContentId record;
    FoundryBool has_record;
    uint8_t reserved[7];
} FoundryAuthorEdit;

typedef struct FoundryAuthorSaveResult {
    uint64_t revision;
    FoundryDocument document;
    /* FoundryAuthorSaveOutcome. */
    int32_t outcome;
    /* FoundryAuthorSaveFailure. */
    int32_t failure;
    /* True when the bytes and the entry naming them were both flushed. False means the bytes
     * are in place and readable with weaker crash durability — not "failed, retry". */
    FoundryBool durable;
    /* False means the cooperating-writer token could not safely be removed, and a later save
     * will be refused until its owner recovers it. */
    FoundryBool lock_released;
    uint8_t reserved[6];
} FoundryAuthorSaveResult;

typedef struct FoundryAuthorSaveAll {
    uint64_t revision;
    uint32_t entry_count;
    uint32_t published_count;
    FoundryBool lock_released;
    /* False when the run stopped at a failure. Files already published stay published and
     * the rest stay dirty: Save All is a prefix, never a transaction. */
    FoundryBool complete;
    uint8_t reserved[6];
} FoundryAuthorSaveAll;

typedef struct FoundryAuthorSaveEntry {
    FoundryStr path;
    FoundryDocument document;
    int32_t outcome;
    int32_t failure;
    FoundryBool durable;
    uint8_t reserved[7];
} FoundryAuthorSaveEntry;

/* One entry of the last operation's diagnostic snapshot. */
typedef struct FoundryAuthorDiagnostic {
    /* The workspace revision the operation ran at, so a client can tell a fresh diagnostic
     * from one it has already shown. */
    uint64_t revision;
    /* The package-relative source name, or the name of whatever else was being read. */
    FoundryStr file;
    FoundryStr message;
    /* The offending line, captured when the diagnostic was made. */
    FoundryStr source_line;
    /* The secondary message that explains the first. */
    FoundryStr note;
    FoundryStr note_file;
    uint32_t line;
    uint32_t column;
    /* How many bytes the caret run covers. At least one. */
    uint32_t length;
    /* FoundryAuthorSeverity. */
    int32_t severity;
    uint32_t note_line;
    uint32_t note_column;
    /* How many diagnostics this operation did not record because its cap was reached. The
     * same number on every entry: it describes the snapshot, not the entry. */
    uint32_t suppressed;
    FoundryBool has_note;
    uint8_t reserved[3];
} FoundryAuthorDiagnostic;

typedef struct FoundryAuthorBuildInfo {
    /* The workspace revision the build was made at. */
    uint64_t revision;
    FoundryStr package_name;
    uint64_t package_bytes;
    uint32_t package_version;
    uint32_t reserved;
} FoundryAuthorBuildInfo;

typedef struct FoundryAuthorPreviewInfo {
    /* The content generation the host published. */
    uint64_t content_generation;
    /* The workspace revision the previewed build was made at. */
    uint64_t build_revision;
    FoundryBuild build;
    /* FoundryAuthorPreviewOutcome. */
    int32_t outcome;
    /* Whether this host granted preview at all. Editing, saving and building work without
     * it. */
    FoundryBool available;
    uint8_t reserved[3];
} FoundryAuthorPreviewInfo;

/* One destination a host will let a build be written to. A client names a destination by
 * number and never by path. */
typedef struct FoundryAuthorExportInfo {
    FoundryStr name;
    uint32_t index;
    /* FoundryAuthorExportKind. */
    int32_t kind;
    FoundryBool has_assets;
    uint8_t reserved[7];
} FoundryAuthorExportInfo;

/* ABI v3 repeats v2 byte-for-byte and appends M14 mod management and game UI. */
typedef struct FoundryApi_v3 {
    /* Always 3, and `sizeof(FoundryApi_v3)` as the host built it. Both are redundant with
     * `get_api`, and both are here for the case the query cannot reach: a crash dump on a
     * player's machine, where the one thing worth knowing is whether the mod was built
     * against this header. Eight bytes, and every other answer involves asking the player to
     * reproduce something. */
    uint32_t version;
    uint32_t size;

    /* -- Results and logging ----------------------------------------------------------- */

    /* The name of a result code — "FOUNDRY_ERR_NOT_FOUND" — so a mod can log legibly without
     * shipping its own copy of the table and letting it go stale. Empty for a code this host
     * has never issued, which is the honest answer rather than an invented one. Always
     * available: it needs no subsystem. */
    FoundryStr (*result_name)(FoundryResult result);

    /* Writes one line to the engine's log, tagged with the mod's own scope. Available on a
     * host with no subsystems at all, deliberately: a mod refusing itself has to be able to
     * say why. */
    FoundryResult (*log_write)(FoundryMod self, FoundryLogLevel level, FoundryStr message);

    /* Walks the in-memory log ring, oldest first, from a cursor starting at
     * FOUNDRY_CURSOR_BEGIN. Returns FOUNDRY_END when there is nothing more. */
    FoundryResult (*log_next)(FoundryCursor *cursor, FoundryLogRecord *out);

    /* -- Content identity -------------------------------------------------------------- */

    /* Hashes a `namespace:name` string, validating its shape first — the same validation the
     * content compiler applies, so a string this refuses would never have compiled either.
     * `foundry_content_id` in this header hashes without validating; this is the checked
     * form, and needs no subsystem. */
    FoundryResult (*id_from_string)(FoundryStr text, FoundryContentId *out);

    /* The spelling of an id, borrowed from the package that supplied it. FOUNDRY_ERR_NOT_FOUND
     * when nothing loaded carries that id: a hash cannot be reversed, so an id nobody spells
     * has no name to give. */
    FoundryResult (*id_to_string)(FoundryContentId id, FoundryStr *out);

    /* The same spelling, copied into the caller's buffer, for a mod that needs the bytes past
     * the call. Writes `*needed` with the length whether or not it fitted and returns
     * FOUNDRY_ERR_LIMIT rather than truncating — silent truncation of a name is how a mod
     * ships with a bug nobody can see. `buffer` may be NULL when `capacity` is 0, which is
     * how a caller asks for the length alone. */
    FoundryResult (*id_copy_string)(FoundryContentId id, uint8_t *buffer, uint64_t capacity,
                                    uint64_t *needed);

    /* -- The frame --------------------------------------------------------------------- */

    /* The engine's frame counter, which is what a log line's `frame` stamp lines up with. */
    FoundryResult (*frame_index)(uint64_t *out);

    /* Wall-clock length of the previous frame. **Presentation only.** Simulation time is the
     * tick, never this: a mod that integrates motion against a wall clock has made its own
     * behaviour depend on how fast the machine is. */
    FoundryResult (*frame_delta_ns)(uint64_t *out);

    /* Total simulated time, which is an exact multiple of the tick and is therefore the same
     * number on every machine that ran the same ticks. */
    FoundryResult (*elapsed_ns)(uint64_t *out);

    /* The exact length of one simulation step. Nanoseconds rather than a rate in hertz,
     * because the engine's timestep is an exact rational and a rounded rate would not
     * reproduce it. */
    FoundryResult (*tick_delta_ns)(uint64_t *out);

    /* -- The profiler ------------------------------------------------------------------ */

    /* Opens a named timing span, so a mod's own work appears in the profiler beside the
     * engine's. Strictly nested, and every span a mod opens it must close. */
    FoundryResult (*scope_begin)(FoundryStr name);

    /* Closes the innermost span this mod opened. FOUNDRY_ERR_REFUSED when none is open,
     * rather than closing one the engine or the game opened. */
    FoundryResult (*scope_end)(void);

    /* -- Memory ------------------------------------------------------------------------ */

    /* Opens a named counter in the engine's memory report. The name is copied. */
    FoundryResult (*memory_counter_open)(FoundryMod self, FoundryStr name,
                                         FoundryMemoryCounter *out);

    /* Publishes a mod's own numbers into a counter it opened. */
    FoundryResult (*memory_counter_set)(FoundryMemoryCounter counter,
                                        const FoundryMemoryStats *stats);

    /* -- Content ----------------------------------------------------------------------- */

    /* Bumped whenever content changes under the program — a hot reload, a package added.
     * **The one signal a mod needs**: anything derived from content, including every record
     * handle and every borrowed string, is derived again when this moves. */
    FoundryResult (*content_generation)(uint64_t *out);

    /* The record a content id names, after every package has been merged and every override
     * applied. What a mod gets is the definition that *won*, which is the same one the game
     * sees — there is no privileged view. */
    FoundryResult (*content_find)(FoundryContentId id, FoundryRecord *out);

    /* Every record, in merge order. */
    FoundryResult (*content_next)(FoundryCursor *cursor, FoundryRecord *out);

    /* Every record of one schema, in merge order. How a mod finds "all the items" without
     * knowing what any package called them. */
    FoundryResult (*content_next_of_schema)(FoundrySchemaId schema, FoundryCursor *cursor,
                                            FoundryRecord *out);

    /* -- Reading a record -------------------------------------------------------------- */

    /*
     * A record is read by asking its schema what each field is and then calling the matching
     * reader. That is how a mod reads a record type it has never heard of — including one
     * another mod declared — and it is what the debug overlay's inspector already does.
     *
     * A field a record does not carry answers FOUNDRY_ERR_NOT_FOUND, which is different from
     * a field that is not in the schema at all (FOUNDRY_ERR_INVALID_ARGUMENT) and different
     * again from asking for it with the wrong reader (also INVALID_ARGUMENT). A record
     * written against an older version of its schema answers newer fields with their
     * declared defaults, which is what makes a schema able to grow.
     */

    /* A nested block has no identity of its own — that is what nested means — so `record_id`,
     * `record_name` and `record_package` answer FOUNDRY_ERR_NOT_FOUND for one. */
    FoundryResult (*record_id)(FoundryRecord record, FoundryContentId *out);
    FoundryResult (*record_name)(FoundryRecord record, FoundryStr *out);
    FoundryResult (*record_schema)(FoundryRecord record, FoundrySchemaId *out);
    FoundryResult (*record_package)(FoundryRecord record, FoundryPackage *out);

    FoundryResult (*record_field_count)(FoundryRecord record, uint32_t *out);
    FoundryResult (*record_field_index)(FoundryRecord record, FoundryStr name, uint32_t *out);
    FoundryResult (*record_field_name)(FoundryRecord record, uint32_t field, FoundryStr *out);
    FoundryResult (*record_field_type)(FoundryRecord record, uint32_t field,
                                       FoundryFieldType *out);
    /* Whether the record actually carries a value for the field, as opposed to the field
     * being absent. A missing optional field and a field set to its default are different
     * things, and collapsing them would make "this item drops nothing" and "this item's drop
     * was never specified" indistinguishable. */
    FoundryResult (*record_field_present)(FoundryRecord record, uint32_t field,
                                          FoundryBool *out);

    FoundryResult (*record_get_bool)(FoundryRecord record, uint32_t field, FoundryBool *out);
    /* Every signed integer field, widened. What the file stores is what the schema declared;
     * this is what covers all of them. */
    FoundryResult (*record_get_i64)(FoundryRecord record, uint32_t field, int64_t *out);
    FoundryResult (*record_get_u64)(FoundryRecord record, uint32_t field, uint64_t *out);
    FoundryResult (*record_get_f32)(FoundryRecord record, uint32_t field, float *out);
    /* Borrowed from the package's own bytes, and not NUL-terminated. */
    FoundryResult (*record_get_string)(FoundryRecord record, uint32_t field, FoundryStr *out);
    /* The second of the two calls in `_v1` that copy rather than borrow. Same rules as
     * `id_copy_string`: `needed` is always written, and too small is a refusal. */
    FoundryResult (*record_copy_string)(FoundryRecord record, uint32_t field, uint8_t *buffer,
                                        uint64_t capacity, uint64_t *needed);
    FoundryResult (*record_get_id)(FoundryRecord record, uint32_t field, FoundryContentId *out);

    /* An inline struct, as something that answers the same field calls one level down. This
     * composes to any depth and needs no path language invented for the boundary.
     *
     * The view it hands back is borrowed like everything else here, and it is borrowed from a
     * ring: it stays valid until enough further views have been opened to recycle its slot,
     * and a recycled one answers FOUNDRY_ERR_INVALID_HANDLE rather than reading whatever now
     * sits there. Reading a record never needs more than a few at once. */
    FoundryResult (*record_nested)(FoundryRecord record, uint32_t field, FoundryRecord *out);

    FoundryResult (*record_list_len)(FoundryRecord record, uint32_t field, uint32_t *out);
    FoundryResult (*record_list_get_i64)(FoundryRecord record, uint32_t field, uint32_t index,
                                         int64_t *out);
    FoundryResult (*record_list_get_f32)(FoundryRecord record, uint32_t field, uint32_t index,
                                         float *out);
    FoundryResult (*record_list_get_string)(FoundryRecord record, uint32_t field,
                                            uint32_t index, FoundryStr *out);
    FoundryResult (*record_list_get_id)(FoundryRecord record, uint32_t field, uint32_t index,
                                        FoundryContentId *out);
    FoundryResult (*record_list_nested)(FoundryRecord record, uint32_t field, uint32_t index,
                                        FoundryRecord *out);

    /* -- Packages ---------------------------------------------------------------------- */

    FoundryResult (*package_count)(uint32_t *out);
    /* Every loaded package, **in load order**, which is the order overrides were applied in
     * and therefore the only order worth walking them in. */
    FoundryResult (*package_next)(FoundryCursor *cursor, FoundryPackage *out);
    FoundryResult (*package_find)(FoundryContentId id, FoundryPackage *out);
    FoundryResult (*package_id)(FoundryPackage package, FoundryContentId *out);
    FoundryResult (*package_name)(FoundryPackage package, FoundryStr *out);
    FoundryResult (*package_version)(FoundryPackage package, uint32_t *out);
    /* Position in the load order. Zero is package zero — the engine's own content, loaded
     * through the same path a mod's is. */
    FoundryResult (*package_order)(FoundryPackage package, uint32_t *out);

    /* -- Schemas ----------------------------------------------------------------------- */

    FoundryResult (*schema_count)(uint32_t *out);
    FoundryResult (*schema_next)(FoundryCursor *cursor, FoundrySchema *out);
    FoundryResult (*schema_find)(FoundrySchemaId id, FoundrySchema *out);
    FoundryResult (*schema_id)(FoundrySchema schema, FoundrySchemaId *out);
    FoundryResult (*schema_version)(FoundrySchema schema, uint32_t *out);
    FoundryResult (*schema_field_count)(FoundrySchema schema, uint32_t *out);
    FoundryResult (*schema_field_name)(FoundrySchema schema, uint32_t field, FoundryStr *out);
    FoundryResult (*schema_field_type)(FoundrySchema schema, uint32_t field,
                                       FoundryFieldType *out);

    /* -- Assets ------------------------------------------------------------------------ */

    /* Loads an asset if it is not loaded, and adds a reference either way. **This is the one
     * reference count a mod owns**, and the one thing in `_v1` a mod must balance: an asset
     * acquired and never released stays in memory for the life of the process. */
    FoundryResult (*asset_acquire)(FoundryContentId id, FoundryAsset *out);
    FoundryResult (*asset_release)(FoundryAsset asset);
    /* Finds one already loaded, without acquiring it. */
    FoundryResult (*asset_find)(FoundryContentId id, FoundryAsset *out);
    FoundryResult (*asset_next)(FoundryCursor *cursor, FoundryAsset *out);
    FoundryResult (*asset_content_id)(FoundryAsset asset, FoundryContentId *out);
    FoundryResult (*asset_schema)(FoundryAsset asset, FoundrySchemaId *out);
    /* Zero means evictable, not freed — a real answer to "why is this still in memory". */
    FoundryResult (*asset_refcount)(FoundryAsset asset, uint32_t *out);

    /* -- Scene ------------------------------------------------------------------------- */

    /* Registers the in-memory half of a component whose schema the mod's content package
     * already declared. Registration is startup-only, like the engine's own component types. */
    FoundryResult (*world_register_component)(FoundryMod self,
                                              const FoundryComponentDesc *desc,
                                              FoundryComponentType *out);
    FoundryResult (*world_find_component_type)(FoundrySchemaId schema,
                                               FoundryComponentType *out);
    /* Registered types, in registration order. A changed registry invalidates the cursor. */
    FoundryResult (*world_component_type_next)(FoundryCursor *cursor,
                                                FoundryComponentType *out);
    FoundryResult (*world_component_type_schema)(FoundryComponentType type,
                                                  FoundrySchemaId *out);
    FoundryResult (*world_component_type_name)(FoundryComponentType type, FoundryStr *out);
    FoundryResult (*world_component_type_size)(FoundryComponentType type, uint32_t *out);
    FoundryResult (*world_component_type_alignment)(FoundryComponentType type, uint32_t *out);
    /* How many entities have one — the number a query over this type would visit, not a
     * count of registered types. */
    FoundryResult (*world_component_type_count)(FoundryComponentType type, uint32_t *out);
    /* Whether a save carries it, which is also whether `world_read_component` can show it.
     * False for a type registered through `world_register_component`: raw C storage has no
     * serialized form the engine could invent for it. */
    FoundryResult (*world_component_type_savable)(FoundryComponentType type,
                                                   FoundryBool *out);

    FoundryResult (*world_create_entity)(FoundryEntity *out);
    FoundryResult (*world_destroy_entity)(FoundryEntity entity);
    FoundryResult (*world_contains)(FoundryEntity entity, FoundryBool *out);
    FoundryResult (*world_entity_count)(uint32_t *out);
    /* Live entities, in slot-index order. A structural change invalidates the cursor. */
    FoundryResult (*world_next_entity)(FoundryCursor *cursor, FoundryEntity *out);

    /* `initial` is either NULL with zero size (construct or zero initialize), or exactly
     * the registered component size. Its bytes are copied before this call returns. */
    FoundryResult (*world_add_component)(FoundryEntity entity, FoundryComponentType type,
                                         const void *initial, uint32_t initial_size);
    FoundryResult (*world_remove_component)(FoundryEntity entity, FoundryComponentType type);
    FoundryResult (*world_has_component)(FoundryEntity entity, FoundryComponentType type,
                                         FoundryBool *out);

    FoundryResult (*world_register_system)(FoundryMod self, const FoundrySystemDesc *desc);
    /* Opens a query over one or more component types. The returned cursor names the query
     * until it ends, is recycled, or the world changes shape. A type the world does not
     * know is FOUNDRY_ERR_INVALID_HANDLE rather than a walk that quietly matches nothing.
     *
     * Iteration is driven by the FIRST named type, so name the most selective one first. */
    FoundryResult (*world_query_begin)(const FoundryComponentType *types, uint32_t count,
                                       FoundryCursor *out);
    FoundryResult (*world_query_next)(FoundryCursor *cursor, FoundryEntity *out);

    /* `entity_template` rather than `template`, which is a C++ keyword: this header has to
     * compile as C++ too, and a parameter name is documentation rather than ABI. */
    FoundryResult (*world_spawn)(FoundryContentId entity_template, FoundryEntity *out);
    FoundryResult (*world_spawn_scene)(FoundryContentId scene, uint32_t *out);
    /* Schema-described data for any savable component, read through the type's own
     * serializer rather than by casting its bytes — so it works for a type this build was
     * never compiled against. FOUNDRY_ERR_UNSUPPORTED for a type with no serializer, which
     * today means every type registered through `world_register_component`.
     *
     * The record is borrowed FOR THE CURRENT FRAME ONLY, and is the one borrow at this
     * boundary with that lifetime: it is serialized into the frame arena rather than read
     * out of a loaded package. Using it on a later frame is FOUNDRY_ERR_INVALID_HANDLE. */
    FoundryResult (*world_read_component)(FoundryEntity entity, FoundryComponentType type,
                                          FoundryRecord *out);
    /* The one raw-storage fast path: only the mod that registered `type` receives it, and
     * the pointer is invalid after the next structural world mutation. A marker type — one
     * registered with size zero — yields NULL and a size of zero, which is FOUNDRY_OK. */
    FoundryResult (*world_component_bytes)(FoundryMod self, FoundryEntity entity,
                                           FoundryComponentType type, void **out,
                                           uint32_t *size);

    /* -- Render2d --------------------------------------------------------------------- */

    FoundryResult (*render_texture_of_asset)(FoundryAsset asset, FoundryTexture *out);
    FoundryResult (*render_destroy_texture)(FoundryTexture texture);
    FoundryResult (*render_draw_sprite)(const FoundryRenderSprite *sprite);
    FoundryResult (*render_draw_text)(const FoundryRenderFont *font, FoundryStr text,
                                      const FoundryRenderTextOptions *options);
    FoundryResult (*render_add_view)(const FoundryRenderViewDesc *desc, FoundryView *out);
    FoundryResult (*render_select_view)(FoundryView view);
    FoundryResult (*render_camera_get)(FoundryRenderCamera *out);
    FoundryResult (*render_camera_set)(const FoundryRenderCamera *camera);
    FoundryResult (*render_world_to_screen)(FoundryRenderVec2 world, FoundryRenderVec2 *out);
    FoundryResult (*render_screen_to_world)(FoundryRenderVec2 screen, FoundryRenderVec2 *out);
    FoundryResult (*render_stats)(FoundryRenderStats *out);

    /* -- UI --------------------------------------------------------------------------- */

    FoundryResult (*ui_begin)(const FoundryUiRect *viewport);
    FoundryResult (*ui_end)(void);
    FoundryResult (*ui_push_id)(FoundryUiId id);
    FoundryResult (*ui_pop_id)(void);
    FoundryResult (*ui_begin_panel)(FoundryUiId id, const FoundryUiRect *bounds);
    FoundryResult (*ui_end_panel)(void);
    FoundryResult (*ui_begin_row)(FoundryUiId id, float height);
    FoundryResult (*ui_end_row)(void);
    FoundryResult (*ui_begin_scroll)(FoundryUiId id, const FoundryUiRect *bounds, float content);
    FoundryResult (*ui_end_scroll)(void);
    FoundryResult (*ui_label)(FoundryStr text);
    FoundryResult (*ui_button)(FoundryUiId id, FoundryStr text, FoundryBool *out);
    FoundryResult (*ui_checkbox)(FoundryUiId id, FoundryStr text, FoundryBool *checked,
                                 FoundryBool *changed);
    FoundryResult (*ui_slider)(FoundryUiId id, FoundryStr text, float *value, float min, float max,
                               FoundryBool *changed);
    FoundryResult (*ui_slider_int)(FoundryUiId id, FoundryStr text, int32_t *value, int32_t min,
                                   int32_t max, FoundryBool *changed);
    FoundryResult (*ui_separator)(void);
    FoundryResult (*ui_spacer)(float size);
    FoundryResult (*ui_collapsing_header)(FoundryUiId id, FoundryStr text, FoundryBool *open);
    FoundryResult (*ui_text_field)(FoundryUiId id, uint8_t *buffer, uint64_t capacity,
                                   uint64_t *length, FoundryBool *changed);
    FoundryResult (*ui_plot)(const float *samples, uint64_t count,
                             const FoundryUiPlotOptions *options);
    FoundryResult (*ui_style_get)(FoundryUiStyle *out);
    FoundryResult (*ui_style_set)(const FoundryUiStyle *style);
    FoundryResult (*ui_wants_keyboard)(FoundryBool *out);
    FoundryResult (*ui_wants_pointer)(FoundryBool *out);

    /* -- Audio ------------------------------------------------------------------------ */

    FoundryResult (*audio_play)(FoundryContentId id, float gain, float pan, float pitch,
                                FoundryBool looping, FoundryVoice *out);
    FoundryResult (*audio_stop)(FoundryVoice voice);
    FoundryResult (*audio_set_gain)(FoundryVoice voice, float gain);
    FoundryResult (*audio_set_pan)(FoundryVoice voice, float pan);
    FoundryResult (*audio_set_pitch)(FoundryVoice voice, float pitch);
    FoundryResult (*audio_set_master_gain)(float gain);

    /* -- Physics2d -------------------------------------------------------------------- */

    FoundryResult (*physics_create_body)(const FoundryPhysicsBodyDesc *desc, FoundryBody *out);
    FoundryResult (*physics_destroy_body)(FoundryBody body);
    FoundryResult (*physics_move_body)(FoundryBody body, FoundryPhysicsVec2 motion,
                                       FoundryPhysicsHit *hits, uint32_t capacity,
                                       FoundryPhysicsMoveResult *out);
    FoundryResult (*physics_query_point)(FoundryPhysicsVec2 point, uint32_t mask,
                                         FoundryPhysicsQueryHit *hits, uint32_t capacity,
                                         uint32_t *count, uint32_t *total);
    FoundryResult (*physics_query_aabb)(FoundryPhysicsVec2 min, FoundryPhysicsVec2 max,
                                        uint32_t mask, FoundryPhysicsQueryHit *hits,
                                        uint32_t capacity, uint32_t *count, uint32_t *total);
    FoundryResult (*physics_query_ray)(FoundryPhysicsVec2 from, FoundryPhysicsVec2 to,
                                       uint32_t mask, FoundryPhysicsHit *hits, uint32_t capacity,
                                       uint32_t *count, uint32_t *total);
    FoundryResult (*physics_body_contacts)(FoundryBody body, FoundryPhysicsQueryHit *hits,
                                           uint32_t capacity, uint32_t *count, uint32_t *total);
    /* Copies one `foundry:script` payload made by the host's exact built-in source
     * loader. `needed` and `revision` are required and are written for a valid asset
     * even when capacity is too small; that case returns FOUNDRY_ERR_LIMIT and copies
     * nothing. `(NULL, 0)` is the sizing probe. A successful copy has exactly `needed`
     * bytes and no terminator. Balance the asset reference with `asset_release`.
     *
     * A stale handle is FOUNDRY_ERR_INVALID_HANDLE. Another asset kind or loader is
     * FOUNDRY_ERR_UNSUPPORTED. An absent engine or source loader is
     * FOUNDRY_ERR_UNAVAILABLE. */
    FoundryResult (*script_source_copy)(FoundryAsset asset, uint8_t *buffer,
                                        uint64_t capacity, uint64_t *needed,
                                        uint64_t *revision);

    /* -- Mod management (v3) ---------------------------------------------------------- */

    /*
     * What a player has installed and chosen, answered when the host supplied its mod set.
     * A host that did not answers FOUNDRY_ERR_UNAVAILABLE to every call here.
     *
     * **Nothing here changes the running game.** A selection applies at the next start
     * (ADR-0040): this session keeps the packages it started with, which is what `loaded`
     * reports, while everything named `pending` describes the next start.
     *
     * Every walk's cursor is refused with FOUNDRY_ERR_INVALID_ARGUMENT after a successful
     * change, and every borrowed string lasts until one. Start the walk again.
     */

    /* Every copy of every package found, duplicates included: each folder the host searches,
     * in the host's order, and each folder's packages sorted by file name. */
    FoundryResult (*mods_installed_next)(FoundryCursor *cursor, FoundryModInfo *out);
    /* The player's list, in the player's order, which is the order `mods_move` edits. The
     * next start loads it in this order wherever dependencies allow. */
    FoundryResult (*mods_pending_next)(FoundryCursor *cursor, FoundryModPending *out);
    /* The dependencies of `package`, in its manifest's order. Asked of the copy the next start
     * would load, or of the first copy found when none would. FOUNDRY_ERR_NOT_FOUND when no
     * copy is installed. */
    FoundryResult (*mods_requirement_next)(FoundryContentId package, FoundryCursor *cursor,
                                           FoundryModRequirement *out);
    /* Every record `package` provides that another package in the pending order provides
     * too, sorted by the record's spelling. `package` won when it is `winner`. Nothing, not
     * an error, for a package that would not load. */
    FoundryResult (*mods_conflict_next)(FoundryContentId package, FoundryCursor *cursor,
                                        FoundryModConflict *out);
    /* Every package in the pending order that provides `record`, in load order; the last is
     * the winner. Nothing for a record no package provides. */
    FoundryResult (*mods_provider_next)(FoundryContentId record, FoundryCursor *cursor,
                                        FoundryModProvider *out);
    /* Every profile, by key, including ones whose files cannot be used. */
    FoundryResult (*mods_profile_next)(FoundryCursor *cursor, FoundryModProfile *out);
    FoundryResult (*mods_profile_active)(FoundryModProfileState *out);

    /*
     * Changes. **Each one answers FOUNDRY_ERR_REFUSED unless the host granted writes** when
     * it supplied the set. A host that shows its own mod screen grants them; one without a
     * screen has no reason to. The grant is the host's, made once, and not per mod.
     *
     * Consent to run a package's native code is not here and never will be: it is the
     * player's, given on the host's own screen, and no code can grant it to itself.
     */

    /* Enables a package at the end of the player's list, or removes it from the list. Either
     * is a no-op when already so. A required package is FOUNDRY_ERR_REFUSED, and enabling an
     * id that no installed package or profile has ever named is FOUNDRY_ERR_NOT_FOUND. */
    FoundryResult (*mods_set_enabled)(FoundryContentId id, FoundryBool enabled);
    /* Moves an enabled package to index `to` of the player's list, clamped to its end. Any
     * index is accepted: `pending_position` shows where dependencies let it land.
     * FOUNDRY_ERR_NOT_FOUND when the player has not enabled it. */
    FoundryResult (*mods_move)(FoundryContentId id, uint32_t to);
    /* Discards every pending change, the pending profile included. */
    FoundryResult (*mods_revert)(void);
    /* Writes the pending selection into the pending profile and makes it the one the next
     * start uses. FOUNDRY_ERR_UNAVAILABLE when the host keeps no profiles.
     * FOUNDRY_ERR_INTERNAL when the profile was written but the host could not record that
     * the next start should use it. */
    FoundryResult (*mods_apply)(void);
    /* Profiles. A name is 1 to 64 bytes of UTF-8 without control characters, or
     * FOUNDRY_ERR_INVALID_ARGUMENT. Create and copy write at once, under the smallest
     * unused key, select nothing, and answer FOUNDRY_ERR_LIMIT past 64 profiles. A copy of
     * the pending profile includes its unapplied changes. */
    FoundryResult (*mods_profile_create)(FoundryStr name, uint32_t *out);
    FoundryResult (*mods_profile_copy)(uint32_t source, FoundryStr name, uint32_t *out);
    /* Written at once. */
    FoundryResult (*mods_profile_rename)(uint32_t key, FoundryStr name);
    /* FOUNDRY_ERR_REFUSED for the saved or the pending profile, so the last one never goes. */
    FoundryResult (*mods_profile_delete)(uint32_t key);
    /* Makes `key` the pending profile and its list the pending list, dropping unapplied
     * changes. FOUNDRY_ERR_REFUSED for a profile whose file cannot be used. */
    FoundryResult (*mods_profile_select)(uint32_t key);

    /* -- Content themes and the game widget set (v3) ------------------------------------ */

    /*
     * A theme is content: a `foundry:ui_theme` record naming an atlas, a font, sizes,
     * colours, nine-slice patches and named icons. Any package may override it.
     *
     * Resolving one returns a handle the host owns, with the theme's textures held. There is
     * no release: the host keeps up to 16 at once and lets them all go when
     * `content_generation` moves, after which each handle is FOUNDRY_ERR_INVALID_HANDLE and
     * the theme stack is emptied. Resolve again then; the same id returns the same handle
     * until it does.
     *
     * FOUNDRY_ERR_NOT_FOUND for an id no package provides, and FOUNDRY_ERR_REFUSED for a
     * record of another schema or a theme whose fields fail validation, which the host's log
     * names. FOUNDRY_ERR_REFUSED inside a frame.
     */
    FoundryResult (*ui_theme_resolve)(FoundryContentId id, FoundryTheme *out);
    /* Makes a theme's style and skin the context's for the frames that follow, up to 8
     * deep; `ui_theme_pop` restores what was there. **Only between frames**: one frame is
     * drawn with one font and one atlas, so both answer FOUNDRY_ERR_REFUSED inside one. */
    FoundryResult (*ui_theme_push)(FoundryTheme theme);
    FoundryResult (*ui_theme_pop)(void);
    /* Everything described inside is drawn faded and takes no hover, press or focus, while
     * still keeping the pointer from reaching the game. Nests. `ui_end` closes any left
     * open and answers FOUNDRY_ERR_REFUSED. */
    FoundryResult (*ui_begin_disabled)(void);
    FoundryResult (*ui_end_disabled)(void);
    /* The part of the current region not yet used: `x` and `y` are where the next widget
     * goes. How a caller finds where the rows of a reorder list begin. */
    FoundryResult (*ui_region_remaining)(FoundryUiRect *out);
    /* A row of tabs. `*selected` is the tab drawn selected on the way in, below `count`, and
     * the one to draw next frame on the way out. At most 256. A tab's identity is `id` and
     * its index, never its label. */
    FoundryResult (*ui_tabs)(FoundryUiId id, const FoundryStr *labels, uint32_t count,
                             uint32_t *selected);
    /* A full-width row that knows whether it is selected. `*clicked` on a completed click. */
    FoundryResult (*ui_selectable)(FoundryUiId id, FoundryStr text, FoundryBool selected,
                                   FoundryBool *clicked);
    /* Reorder grips over `count` rows the caller has already described in a vertical
     * region, each one line high and separated by the style's spacing. `bounds` covers them
     * all, from where the first began. Dragging a grip draws an insertion line, may leave the
     * list, and completes a move on release. */
    FoundryResult (*ui_reorder_list)(FoundryUiId id, const FoundryUiRect *bounds,
                                     uint32_t count, FoundryUiReorderMove *out);
    /* A button that moves row `index` of `count` one way. It draws disabled, and never
     * completes a move, when that move is impossible. */
    FoundryResult (*ui_reorder_button)(FoundryUiId id, FoundryStr text, uint32_t index,
                                       uint32_t count, FoundryUiReorderDirection direction,
                                       FoundryUiReorderMove *out);
    /* The pushed theme's icon called `name`, drawn at `size`. `*found` is false for a name
     * the theme lacks, and the space is kept anyway, so an absent optional icon moves no
     * column after it. Both icon and image answer FOUNDRY_ERR_REFUSED in a frame with no
     * theme pushed around it: an atlas is only ever the pushed theme's. */
    FoundryResult (*ui_icon)(FoundryStr name, FoundryUiVec2 size, FoundryUiColor tint,
                             FoundryBool *found);
    /* A region of the pushed theme's atlas, drawn at `size`. */
    FoundryResult (*ui_image)(const FoundryUiImageSource *source, FoundryUiVec2 size,
                              FoundryUiColor tint);
} FoundryApi_v3;

/* ABI v4 repeats v3 byte-for-byte and appends M15 authoring (ADR-0042). */
typedef struct FoundryApi_v4 {
    /* Always 4, and `sizeof(FoundryApi_v4)` as the host built it. Both are redundant with
     * `get_api`, and both are here for the case the query cannot reach: a crash dump on a
     * player's machine, where the one thing worth knowing is whether the mod was built
     * against this header. Eight bytes, and every other answer involves asking the player to
     * reproduce something. */
    uint32_t version;
    uint32_t size;

    /* -- Results and logging ----------------------------------------------------------- */

    /* The name of a result code — "FOUNDRY_ERR_NOT_FOUND" — so a mod can log legibly without
     * shipping its own copy of the table and letting it go stale. Empty for a code this host
     * has never issued, which is the honest answer rather than an invented one. Always
     * available: it needs no subsystem. */
    FoundryStr (*result_name)(FoundryResult result);

    /* Writes one line to the engine's log, tagged with the mod's own scope. Available on a
     * host with no subsystems at all, deliberately: a mod refusing itself has to be able to
     * say why. */
    FoundryResult (*log_write)(FoundryMod self, FoundryLogLevel level, FoundryStr message);

    /* Walks the in-memory log ring, oldest first, from a cursor starting at
     * FOUNDRY_CURSOR_BEGIN. Returns FOUNDRY_END when there is nothing more. */
    FoundryResult (*log_next)(FoundryCursor *cursor, FoundryLogRecord *out);

    /* -- Content identity -------------------------------------------------------------- */

    /* Hashes a `namespace:name` string, validating its shape first — the same validation the
     * content compiler applies, so a string this refuses would never have compiled either.
     * `foundry_content_id` in this header hashes without validating; this is the checked
     * form, and needs no subsystem. */
    FoundryResult (*id_from_string)(FoundryStr text, FoundryContentId *out);

    /* The spelling of an id, borrowed from the package that supplied it. FOUNDRY_ERR_NOT_FOUND
     * when nothing loaded carries that id: a hash cannot be reversed, so an id nobody spells
     * has no name to give. */
    FoundryResult (*id_to_string)(FoundryContentId id, FoundryStr *out);

    /* The same spelling, copied into the caller's buffer, for a mod that needs the bytes past
     * the call. Writes `*needed` with the length whether or not it fitted and returns
     * FOUNDRY_ERR_LIMIT rather than truncating — silent truncation of a name is how a mod
     * ships with a bug nobody can see. `buffer` may be NULL when `capacity` is 0, which is
     * how a caller asks for the length alone. */
    FoundryResult (*id_copy_string)(FoundryContentId id, uint8_t *buffer, uint64_t capacity,
                                    uint64_t *needed);

    /* -- The frame --------------------------------------------------------------------- */

    /* The engine's frame counter, which is what a log line's `frame` stamp lines up with. */
    FoundryResult (*frame_index)(uint64_t *out);

    /* Wall-clock length of the previous frame. **Presentation only.** Simulation time is the
     * tick, never this: a mod that integrates motion against a wall clock has made its own
     * behaviour depend on how fast the machine is. */
    FoundryResult (*frame_delta_ns)(uint64_t *out);

    /* Total simulated time, which is an exact multiple of the tick and is therefore the same
     * number on every machine that ran the same ticks. */
    FoundryResult (*elapsed_ns)(uint64_t *out);

    /* The exact length of one simulation step. Nanoseconds rather than a rate in hertz,
     * because the engine's timestep is an exact rational and a rounded rate would not
     * reproduce it. */
    FoundryResult (*tick_delta_ns)(uint64_t *out);

    /* -- The profiler ------------------------------------------------------------------ */

    /* Opens a named timing span, so a mod's own work appears in the profiler beside the
     * engine's. Strictly nested, and every span a mod opens it must close. */
    FoundryResult (*scope_begin)(FoundryStr name);

    /* Closes the innermost span this mod opened. FOUNDRY_ERR_REFUSED when none is open,
     * rather than closing one the engine or the game opened. */
    FoundryResult (*scope_end)(void);

    /* -- Memory ------------------------------------------------------------------------ */

    /* Opens a named counter in the engine's memory report. The name is copied. */
    FoundryResult (*memory_counter_open)(FoundryMod self, FoundryStr name,
                                         FoundryMemoryCounter *out);

    /* Publishes a mod's own numbers into a counter it opened. */
    FoundryResult (*memory_counter_set)(FoundryMemoryCounter counter,
                                        const FoundryMemoryStats *stats);

    /* -- Content ----------------------------------------------------------------------- */

    /* Bumped whenever content changes under the program — a hot reload, a package added.
     * **The one signal a mod needs**: anything derived from content, including every record
     * handle and every borrowed string, is derived again when this moves. */
    FoundryResult (*content_generation)(uint64_t *out);

    /* The record a content id names, after every package has been merged and every override
     * applied. What a mod gets is the definition that *won*, which is the same one the game
     * sees — there is no privileged view. */
    FoundryResult (*content_find)(FoundryContentId id, FoundryRecord *out);

    /* Every record, in merge order. */
    FoundryResult (*content_next)(FoundryCursor *cursor, FoundryRecord *out);

    /* Every record of one schema, in merge order. How a mod finds "all the items" without
     * knowing what any package called them. */
    FoundryResult (*content_next_of_schema)(FoundrySchemaId schema, FoundryCursor *cursor,
                                            FoundryRecord *out);

    /* -- Reading a record -------------------------------------------------------------- */

    /*
     * A record is read by asking its schema what each field is and then calling the matching
     * reader. That is how a mod reads a record type it has never heard of — including one
     * another mod declared — and it is what the debug overlay's inspector already does.
     *
     * A field a record does not carry answers FOUNDRY_ERR_NOT_FOUND, which is different from
     * a field that is not in the schema at all (FOUNDRY_ERR_INVALID_ARGUMENT) and different
     * again from asking for it with the wrong reader (also INVALID_ARGUMENT). A record
     * written against an older version of its schema answers newer fields with their
     * declared defaults, which is what makes a schema able to grow.
     */

    /* A nested block has no identity of its own — that is what nested means — so `record_id`,
     * `record_name` and `record_package` answer FOUNDRY_ERR_NOT_FOUND for one. */
    FoundryResult (*record_id)(FoundryRecord record, FoundryContentId *out);
    FoundryResult (*record_name)(FoundryRecord record, FoundryStr *out);
    FoundryResult (*record_schema)(FoundryRecord record, FoundrySchemaId *out);
    FoundryResult (*record_package)(FoundryRecord record, FoundryPackage *out);

    FoundryResult (*record_field_count)(FoundryRecord record, uint32_t *out);
    FoundryResult (*record_field_index)(FoundryRecord record, FoundryStr name, uint32_t *out);
    FoundryResult (*record_field_name)(FoundryRecord record, uint32_t field, FoundryStr *out);
    FoundryResult (*record_field_type)(FoundryRecord record, uint32_t field,
                                       FoundryFieldType *out);
    /* Whether the record actually carries a value for the field, as opposed to the field
     * being absent. A missing optional field and a field set to its default are different
     * things, and collapsing them would make "this item drops nothing" and "this item's drop
     * was never specified" indistinguishable. */
    FoundryResult (*record_field_present)(FoundryRecord record, uint32_t field,
                                          FoundryBool *out);

    FoundryResult (*record_get_bool)(FoundryRecord record, uint32_t field, FoundryBool *out);
    /* Every signed integer field, widened. What the file stores is what the schema declared;
     * this is what covers all of them. */
    FoundryResult (*record_get_i64)(FoundryRecord record, uint32_t field, int64_t *out);
    FoundryResult (*record_get_u64)(FoundryRecord record, uint32_t field, uint64_t *out);
    FoundryResult (*record_get_f32)(FoundryRecord record, uint32_t field, float *out);
    /* Borrowed from the package's own bytes, and not NUL-terminated. */
    FoundryResult (*record_get_string)(FoundryRecord record, uint32_t field, FoundryStr *out);
    /* The second of the two calls in `_v1` that copy rather than borrow. Same rules as
     * `id_copy_string`: `needed` is always written, and too small is a refusal. */
    FoundryResult (*record_copy_string)(FoundryRecord record, uint32_t field, uint8_t *buffer,
                                        uint64_t capacity, uint64_t *needed);
    FoundryResult (*record_get_id)(FoundryRecord record, uint32_t field, FoundryContentId *out);

    /* An inline struct, as something that answers the same field calls one level down. This
     * composes to any depth and needs no path language invented for the boundary.
     *
     * The view it hands back is borrowed like everything else here, and it is borrowed from a
     * ring: it stays valid until enough further views have been opened to recycle its slot,
     * and a recycled one answers FOUNDRY_ERR_INVALID_HANDLE rather than reading whatever now
     * sits there. Reading a record never needs more than a few at once. */
    FoundryResult (*record_nested)(FoundryRecord record, uint32_t field, FoundryRecord *out);

    FoundryResult (*record_list_len)(FoundryRecord record, uint32_t field, uint32_t *out);
    FoundryResult (*record_list_get_i64)(FoundryRecord record, uint32_t field, uint32_t index,
                                         int64_t *out);
    FoundryResult (*record_list_get_f32)(FoundryRecord record, uint32_t field, uint32_t index,
                                         float *out);
    FoundryResult (*record_list_get_string)(FoundryRecord record, uint32_t field,
                                            uint32_t index, FoundryStr *out);
    FoundryResult (*record_list_get_id)(FoundryRecord record, uint32_t field, uint32_t index,
                                        FoundryContentId *out);
    FoundryResult (*record_list_nested)(FoundryRecord record, uint32_t field, uint32_t index,
                                        FoundryRecord *out);

    /* -- Packages ---------------------------------------------------------------------- */

    FoundryResult (*package_count)(uint32_t *out);
    /* Every loaded package, **in load order**, which is the order overrides were applied in
     * and therefore the only order worth walking them in. */
    FoundryResult (*package_next)(FoundryCursor *cursor, FoundryPackage *out);
    FoundryResult (*package_find)(FoundryContentId id, FoundryPackage *out);
    FoundryResult (*package_id)(FoundryPackage package, FoundryContentId *out);
    FoundryResult (*package_name)(FoundryPackage package, FoundryStr *out);
    FoundryResult (*package_version)(FoundryPackage package, uint32_t *out);
    /* Position in the load order. Zero is package zero — the engine's own content, loaded
     * through the same path a mod's is. */
    FoundryResult (*package_order)(FoundryPackage package, uint32_t *out);

    /* -- Schemas ----------------------------------------------------------------------- */

    FoundryResult (*schema_count)(uint32_t *out);
    FoundryResult (*schema_next)(FoundryCursor *cursor, FoundrySchema *out);
    FoundryResult (*schema_find)(FoundrySchemaId id, FoundrySchema *out);
    FoundryResult (*schema_id)(FoundrySchema schema, FoundrySchemaId *out);
    FoundryResult (*schema_version)(FoundrySchema schema, uint32_t *out);
    FoundryResult (*schema_field_count)(FoundrySchema schema, uint32_t *out);
    FoundryResult (*schema_field_name)(FoundrySchema schema, uint32_t field, FoundryStr *out);
    FoundryResult (*schema_field_type)(FoundrySchema schema, uint32_t field,
                                       FoundryFieldType *out);

    /* -- Assets ------------------------------------------------------------------------ */

    /* Loads an asset if it is not loaded, and adds a reference either way. **This is the one
     * reference count a mod owns**, and the one thing in `_v1` a mod must balance: an asset
     * acquired and never released stays in memory for the life of the process. */
    FoundryResult (*asset_acquire)(FoundryContentId id, FoundryAsset *out);
    FoundryResult (*asset_release)(FoundryAsset asset);
    /* Finds one already loaded, without acquiring it. */
    FoundryResult (*asset_find)(FoundryContentId id, FoundryAsset *out);
    FoundryResult (*asset_next)(FoundryCursor *cursor, FoundryAsset *out);
    FoundryResult (*asset_content_id)(FoundryAsset asset, FoundryContentId *out);
    FoundryResult (*asset_schema)(FoundryAsset asset, FoundrySchemaId *out);
    /* Zero means evictable, not freed — a real answer to "why is this still in memory". */
    FoundryResult (*asset_refcount)(FoundryAsset asset, uint32_t *out);

    /* -- Scene ------------------------------------------------------------------------- */

    /* Registers the in-memory half of a component whose schema the mod's content package
     * already declared. Registration is startup-only, like the engine's own component types. */
    FoundryResult (*world_register_component)(FoundryMod self,
                                              const FoundryComponentDesc *desc,
                                              FoundryComponentType *out);
    FoundryResult (*world_find_component_type)(FoundrySchemaId schema,
                                               FoundryComponentType *out);
    /* Registered types, in registration order. A changed registry invalidates the cursor. */
    FoundryResult (*world_component_type_next)(FoundryCursor *cursor,
                                                FoundryComponentType *out);
    FoundryResult (*world_component_type_schema)(FoundryComponentType type,
                                                  FoundrySchemaId *out);
    FoundryResult (*world_component_type_name)(FoundryComponentType type, FoundryStr *out);
    FoundryResult (*world_component_type_size)(FoundryComponentType type, uint32_t *out);
    FoundryResult (*world_component_type_alignment)(FoundryComponentType type, uint32_t *out);
    /* How many entities have one — the number a query over this type would visit, not a
     * count of registered types. */
    FoundryResult (*world_component_type_count)(FoundryComponentType type, uint32_t *out);
    /* Whether a save carries it, which is also whether `world_read_component` can show it.
     * False for a type registered through `world_register_component`: raw C storage has no
     * serialized form the engine could invent for it. */
    FoundryResult (*world_component_type_savable)(FoundryComponentType type,
                                                   FoundryBool *out);

    FoundryResult (*world_create_entity)(FoundryEntity *out);
    FoundryResult (*world_destroy_entity)(FoundryEntity entity);
    FoundryResult (*world_contains)(FoundryEntity entity, FoundryBool *out);
    FoundryResult (*world_entity_count)(uint32_t *out);
    /* Live entities, in slot-index order. A structural change invalidates the cursor. */
    FoundryResult (*world_next_entity)(FoundryCursor *cursor, FoundryEntity *out);

    /* `initial` is either NULL with zero size (construct or zero initialize), or exactly
     * the registered component size. Its bytes are copied before this call returns. */
    FoundryResult (*world_add_component)(FoundryEntity entity, FoundryComponentType type,
                                         const void *initial, uint32_t initial_size);
    FoundryResult (*world_remove_component)(FoundryEntity entity, FoundryComponentType type);
    FoundryResult (*world_has_component)(FoundryEntity entity, FoundryComponentType type,
                                         FoundryBool *out);

    FoundryResult (*world_register_system)(FoundryMod self, const FoundrySystemDesc *desc);
    /* Opens a query over one or more component types. The returned cursor names the query
     * until it ends, is recycled, or the world changes shape. A type the world does not
     * know is FOUNDRY_ERR_INVALID_HANDLE rather than a walk that quietly matches nothing.
     *
     * Iteration is driven by the FIRST named type, so name the most selective one first. */
    FoundryResult (*world_query_begin)(const FoundryComponentType *types, uint32_t count,
                                       FoundryCursor *out);
    FoundryResult (*world_query_next)(FoundryCursor *cursor, FoundryEntity *out);

    /* `entity_template` rather than `template`, which is a C++ keyword: this header has to
     * compile as C++ too, and a parameter name is documentation rather than ABI. */
    FoundryResult (*world_spawn)(FoundryContentId entity_template, FoundryEntity *out);
    FoundryResult (*world_spawn_scene)(FoundryContentId scene, uint32_t *out);
    /* Schema-described data for any savable component, read through the type's own
     * serializer rather than by casting its bytes — so it works for a type this build was
     * never compiled against. FOUNDRY_ERR_UNSUPPORTED for a type with no serializer, which
     * today means every type registered through `world_register_component`.
     *
     * The record is borrowed FOR THE CURRENT FRAME ONLY, and is the one borrow at this
     * boundary with that lifetime: it is serialized into the frame arena rather than read
     * out of a loaded package. Using it on a later frame is FOUNDRY_ERR_INVALID_HANDLE. */
    FoundryResult (*world_read_component)(FoundryEntity entity, FoundryComponentType type,
                                          FoundryRecord *out);
    /* The one raw-storage fast path: only the mod that registered `type` receives it, and
     * the pointer is invalid after the next structural world mutation. A marker type — one
     * registered with size zero — yields NULL and a size of zero, which is FOUNDRY_OK. */
    FoundryResult (*world_component_bytes)(FoundryMod self, FoundryEntity entity,
                                           FoundryComponentType type, void **out,
                                           uint32_t *size);

    /* -- Render2d --------------------------------------------------------------------- */

    FoundryResult (*render_texture_of_asset)(FoundryAsset asset, FoundryTexture *out);
    FoundryResult (*render_destroy_texture)(FoundryTexture texture);
    FoundryResult (*render_draw_sprite)(const FoundryRenderSprite *sprite);
    FoundryResult (*render_draw_text)(const FoundryRenderFont *font, FoundryStr text,
                                      const FoundryRenderTextOptions *options);
    FoundryResult (*render_add_view)(const FoundryRenderViewDesc *desc, FoundryView *out);
    FoundryResult (*render_select_view)(FoundryView view);
    FoundryResult (*render_camera_get)(FoundryRenderCamera *out);
    FoundryResult (*render_camera_set)(const FoundryRenderCamera *camera);
    FoundryResult (*render_world_to_screen)(FoundryRenderVec2 world, FoundryRenderVec2 *out);
    FoundryResult (*render_screen_to_world)(FoundryRenderVec2 screen, FoundryRenderVec2 *out);
    FoundryResult (*render_stats)(FoundryRenderStats *out);

    /* -- UI --------------------------------------------------------------------------- */

    FoundryResult (*ui_begin)(const FoundryUiRect *viewport);
    FoundryResult (*ui_end)(void);
    FoundryResult (*ui_push_id)(FoundryUiId id);
    FoundryResult (*ui_pop_id)(void);
    FoundryResult (*ui_begin_panel)(FoundryUiId id, const FoundryUiRect *bounds);
    FoundryResult (*ui_end_panel)(void);
    FoundryResult (*ui_begin_row)(FoundryUiId id, float height);
    FoundryResult (*ui_end_row)(void);
    FoundryResult (*ui_begin_scroll)(FoundryUiId id, const FoundryUiRect *bounds, float content);
    FoundryResult (*ui_end_scroll)(void);
    FoundryResult (*ui_label)(FoundryStr text);
    FoundryResult (*ui_button)(FoundryUiId id, FoundryStr text, FoundryBool *out);
    FoundryResult (*ui_checkbox)(FoundryUiId id, FoundryStr text, FoundryBool *checked,
                                 FoundryBool *changed);
    FoundryResult (*ui_slider)(FoundryUiId id, FoundryStr text, float *value, float min, float max,
                               FoundryBool *changed);
    FoundryResult (*ui_slider_int)(FoundryUiId id, FoundryStr text, int32_t *value, int32_t min,
                                   int32_t max, FoundryBool *changed);
    FoundryResult (*ui_separator)(void);
    FoundryResult (*ui_spacer)(float size);
    FoundryResult (*ui_collapsing_header)(FoundryUiId id, FoundryStr text, FoundryBool *open);
    FoundryResult (*ui_text_field)(FoundryUiId id, uint8_t *buffer, uint64_t capacity,
                                   uint64_t *length, FoundryBool *changed);
    FoundryResult (*ui_plot)(const float *samples, uint64_t count,
                             const FoundryUiPlotOptions *options);
    FoundryResult (*ui_style_get)(FoundryUiStyle *out);
    FoundryResult (*ui_style_set)(const FoundryUiStyle *style);
    FoundryResult (*ui_wants_keyboard)(FoundryBool *out);
    FoundryResult (*ui_wants_pointer)(FoundryBool *out);

    /* -- Audio ------------------------------------------------------------------------ */

    FoundryResult (*audio_play)(FoundryContentId id, float gain, float pan, float pitch,
                                FoundryBool looping, FoundryVoice *out);
    FoundryResult (*audio_stop)(FoundryVoice voice);
    FoundryResult (*audio_set_gain)(FoundryVoice voice, float gain);
    FoundryResult (*audio_set_pan)(FoundryVoice voice, float pan);
    FoundryResult (*audio_set_pitch)(FoundryVoice voice, float pitch);
    FoundryResult (*audio_set_master_gain)(float gain);

    /* -- Physics2d -------------------------------------------------------------------- */

    FoundryResult (*physics_create_body)(const FoundryPhysicsBodyDesc *desc, FoundryBody *out);
    FoundryResult (*physics_destroy_body)(FoundryBody body);
    FoundryResult (*physics_move_body)(FoundryBody body, FoundryPhysicsVec2 motion,
                                       FoundryPhysicsHit *hits, uint32_t capacity,
                                       FoundryPhysicsMoveResult *out);
    FoundryResult (*physics_query_point)(FoundryPhysicsVec2 point, uint32_t mask,
                                         FoundryPhysicsQueryHit *hits, uint32_t capacity,
                                         uint32_t *count, uint32_t *total);
    FoundryResult (*physics_query_aabb)(FoundryPhysicsVec2 min, FoundryPhysicsVec2 max,
                                        uint32_t mask, FoundryPhysicsQueryHit *hits,
                                        uint32_t capacity, uint32_t *count, uint32_t *total);
    FoundryResult (*physics_query_ray)(FoundryPhysicsVec2 from, FoundryPhysicsVec2 to,
                                       uint32_t mask, FoundryPhysicsHit *hits, uint32_t capacity,
                                       uint32_t *count, uint32_t *total);
    FoundryResult (*physics_body_contacts)(FoundryBody body, FoundryPhysicsQueryHit *hits,
                                           uint32_t capacity, uint32_t *count, uint32_t *total);
    /* Copies one `foundry:script` payload made by the host's exact built-in source
     * loader. `needed` and `revision` are required and are written for a valid asset
     * even when capacity is too small; that case returns FOUNDRY_ERR_LIMIT and copies
     * nothing. `(NULL, 0)` is the sizing probe. A successful copy has exactly `needed`
     * bytes and no terminator. Balance the asset reference with `asset_release`.
     *
     * A stale handle is FOUNDRY_ERR_INVALID_HANDLE. Another asset kind or loader is
     * FOUNDRY_ERR_UNSUPPORTED. An absent engine or source loader is
     * FOUNDRY_ERR_UNAVAILABLE. */
    FoundryResult (*script_source_copy)(FoundryAsset asset, uint8_t *buffer,
                                        uint64_t capacity, uint64_t *needed,
                                        uint64_t *revision);

    /* -- Mod management (v3) ---------------------------------------------------------- */

    /*
     * What a player has installed and chosen, answered when the host supplied its mod set.
     * A host that did not answers FOUNDRY_ERR_UNAVAILABLE to every call here.
     *
     * **Nothing here changes the running game.** A selection applies at the next start
     * (ADR-0040): this session keeps the packages it started with, which is what `loaded`
     * reports, while everything named `pending` describes the next start.
     *
     * Every walk's cursor is refused with FOUNDRY_ERR_INVALID_ARGUMENT after a successful
     * change, and every borrowed string lasts until one. Start the walk again.
     */

    /* Every copy of every package found, duplicates included: each folder the host searches,
     * in the host's order, and each folder's packages sorted by file name. */
    FoundryResult (*mods_installed_next)(FoundryCursor *cursor, FoundryModInfo *out);
    /* The player's list, in the player's order, which is the order `mods_move` edits. The
     * next start loads it in this order wherever dependencies allow. */
    FoundryResult (*mods_pending_next)(FoundryCursor *cursor, FoundryModPending *out);
    /* The dependencies of `package`, in its manifest's order. Asked of the copy the next start
     * would load, or of the first copy found when none would. FOUNDRY_ERR_NOT_FOUND when no
     * copy is installed. */
    FoundryResult (*mods_requirement_next)(FoundryContentId package, FoundryCursor *cursor,
                                           FoundryModRequirement *out);
    /* Every record `package` provides that another package in the pending order provides
     * too, sorted by the record's spelling. `package` won when it is `winner`. Nothing, not
     * an error, for a package that would not load. */
    FoundryResult (*mods_conflict_next)(FoundryContentId package, FoundryCursor *cursor,
                                        FoundryModConflict *out);
    /* Every package in the pending order that provides `record`, in load order; the last is
     * the winner. Nothing for a record no package provides. */
    FoundryResult (*mods_provider_next)(FoundryContentId record, FoundryCursor *cursor,
                                        FoundryModProvider *out);
    /* Every profile, by key, including ones whose files cannot be used. */
    FoundryResult (*mods_profile_next)(FoundryCursor *cursor, FoundryModProfile *out);
    FoundryResult (*mods_profile_active)(FoundryModProfileState *out);

    /*
     * Changes. **Each one answers FOUNDRY_ERR_REFUSED unless the host granted writes** when
     * it supplied the set. A host that shows its own mod screen grants them; one without a
     * screen has no reason to. The grant is the host's, made once, and not per mod.
     *
     * Consent to run a package's native code is not here and never will be: it is the
     * player's, given on the host's own screen, and no code can grant it to itself.
     */

    /* Enables a package at the end of the player's list, or removes it from the list. Either
     * is a no-op when already so. A required package is FOUNDRY_ERR_REFUSED, and enabling an
     * id that no installed package or profile has ever named is FOUNDRY_ERR_NOT_FOUND. */
    FoundryResult (*mods_set_enabled)(FoundryContentId id, FoundryBool enabled);
    /* Moves an enabled package to index `to` of the player's list, clamped to its end. Any
     * index is accepted: `pending_position` shows where dependencies let it land.
     * FOUNDRY_ERR_NOT_FOUND when the player has not enabled it. */
    FoundryResult (*mods_move)(FoundryContentId id, uint32_t to);
    /* Discards every pending change, the pending profile included. */
    FoundryResult (*mods_revert)(void);
    /* Writes the pending selection into the pending profile and makes it the one the next
     * start uses. FOUNDRY_ERR_UNAVAILABLE when the host keeps no profiles.
     * FOUNDRY_ERR_INTERNAL when the profile was written but the host could not record that
     * the next start should use it. */
    FoundryResult (*mods_apply)(void);
    /* Profiles. A name is 1 to 64 bytes of UTF-8 without control characters, or
     * FOUNDRY_ERR_INVALID_ARGUMENT. Create and copy write at once, under the smallest
     * unused key, select nothing, and answer FOUNDRY_ERR_LIMIT past 64 profiles. A copy of
     * the pending profile includes its unapplied changes. */
    FoundryResult (*mods_profile_create)(FoundryStr name, uint32_t *out);
    FoundryResult (*mods_profile_copy)(uint32_t source, FoundryStr name, uint32_t *out);
    /* Written at once. */
    FoundryResult (*mods_profile_rename)(uint32_t key, FoundryStr name);
    /* FOUNDRY_ERR_REFUSED for the saved or the pending profile, so the last one never goes. */
    FoundryResult (*mods_profile_delete)(uint32_t key);
    /* Makes `key` the pending profile and its list the pending list, dropping unapplied
     * changes. FOUNDRY_ERR_REFUSED for a profile whose file cannot be used. */
    FoundryResult (*mods_profile_select)(uint32_t key);

    /* -- Content themes and the game widget set (v3) ------------------------------------ */

    /*
     * A theme is content: a `foundry:ui_theme` record naming an atlas, a font, sizes,
     * colours, nine-slice patches and named icons. Any package may override it.
     *
     * Resolving one returns a handle the host owns, with the theme's textures held. There is
     * no release: the host keeps up to 16 at once and lets them all go when
     * `content_generation` moves, after which each handle is FOUNDRY_ERR_INVALID_HANDLE and
     * the theme stack is emptied. Resolve again then; the same id returns the same handle
     * until it does.
     *
     * FOUNDRY_ERR_NOT_FOUND for an id no package provides, and FOUNDRY_ERR_REFUSED for a
     * record of another schema or a theme whose fields fail validation, which the host's log
     * names. FOUNDRY_ERR_REFUSED inside a frame.
     */
    FoundryResult (*ui_theme_resolve)(FoundryContentId id, FoundryTheme *out);
    /* Makes a theme's style and skin the context's for the frames that follow, up to 8
     * deep; `ui_theme_pop` restores what was there. **Only between frames**: one frame is
     * drawn with one font and one atlas, so both answer FOUNDRY_ERR_REFUSED inside one. */
    FoundryResult (*ui_theme_push)(FoundryTheme theme);
    FoundryResult (*ui_theme_pop)(void);
    /* Everything described inside is drawn faded and takes no hover, press or focus, while
     * still keeping the pointer from reaching the game. Nests. `ui_end` closes any left
     * open and answers FOUNDRY_ERR_REFUSED. */
    FoundryResult (*ui_begin_disabled)(void);
    FoundryResult (*ui_end_disabled)(void);
    /* The part of the current region not yet used: `x` and `y` are where the next widget
     * goes. How a caller finds where the rows of a reorder list begin. */
    FoundryResult (*ui_region_remaining)(FoundryUiRect *out);
    /* A row of tabs. `*selected` is the tab drawn selected on the way in, below `count`, and
     * the one to draw next frame on the way out. At most 256. A tab's identity is `id` and
     * its index, never its label. */
    FoundryResult (*ui_tabs)(FoundryUiId id, const FoundryStr *labels, uint32_t count,
                             uint32_t *selected);
    /* A full-width row that knows whether it is selected. `*clicked` on a completed click. */
    FoundryResult (*ui_selectable)(FoundryUiId id, FoundryStr text, FoundryBool selected,
                                   FoundryBool *clicked);
    /* Reorder grips over `count` rows the caller has already described in a vertical
     * region, each one line high and separated by the style's spacing. `bounds` covers them
     * all, from where the first began. Dragging a grip draws an insertion line, may leave the
     * list, and completes a move on release. */
    FoundryResult (*ui_reorder_list)(FoundryUiId id, const FoundryUiRect *bounds,
                                     uint32_t count, FoundryUiReorderMove *out);
    /* A button that moves row `index` of `count` one way. It draws disabled, and never
     * completes a move, when that move is impossible. */
    FoundryResult (*ui_reorder_button)(FoundryUiId id, FoundryStr text, uint32_t index,
                                       uint32_t count, FoundryUiReorderDirection direction,
                                       FoundryUiReorderMove *out);
    /* The pushed theme's icon called `name`, drawn at `size`. `*found` is false for a name
     * the theme lacks, and the space is kept anyway, so an absent optional icon moves no
     * column after it. Both icon and image answer FOUNDRY_ERR_REFUSED in a frame with no
     * theme pushed around it: an atlas is only ever the pushed theme's. */
    FoundryResult (*ui_icon)(FoundryStr name, FoundryUiVec2 size, FoundryUiColor tint,
                             FoundryBool *found);
    /* A region of the pushed theme's atlas, drawn at `size`. */
    FoundryResult (*ui_image)(const FoundryUiImageSource *source, FoundryUiVec2 size,
                              FoundryUiColor tint);

    /* -- Authoring: workspaces (v4, ADR-0042) ------------------------------------------ */

    /* The workspaces this host granted, in a stable order. Nothing here opens one: a
     * workspace is a directory the application decided to grant, and a client that could
     * name a path would be a client with a private path into the filesystem. */
    FoundryResult (*author_workspace_next)(FoundryCursor *cursor, FoundryWorkspace *out);
    FoundryResult (*author_workspace_info)(FoundryWorkspace workspace,
                                           FoundryAuthorWorkspaceInfo *out);
    FoundryResult (*author_workspace_revision)(FoundryWorkspace workspace, uint64_t *out);
    /* The bounds this workspace was configured with, so a FOUNDRY_ERR_LIMIT can be
     * explained rather than guessed at. */
    FoundryResult (*author_workspace_limits)(FoundryWorkspace workspace,
                                             FoundryAuthorLimits *out);

    /* -- Authoring: documents ---------------------------------------------------------- */

    FoundryResult (*author_document_next)(FoundryWorkspace workspace, FoundryCursor *cursor,
                                          FoundryDocument *out);
    FoundryResult (*author_document_info)(FoundryDocument document,
                                          FoundryAuthorDocumentInfo *out);
    /* A new `.fdt` file, named relative to the package root, in a directory that already
     * exists. It lives in memory until a save publishes it. */
    FoundryResult (*author_document_create)(FoundryWorkspace workspace,
                                            uint64_t expected_revision, FoundryStr path,
                                            FoundryDocument *out);
    /* Adopt the bytes on disk. Refused while the draft is dirty: discard first, which is a
     * separate deliberate action. Both answer FOUNDRY_OK with the unchanged revision when
     * there was nothing to do. */
    FoundryResult (*author_document_refresh)(FoundryDocument document,
                                             uint64_t expected_revision, uint64_t *revision);
    /* Restore the last saved baseline and clear the history, as one revisioned action. */
    FoundryResult (*author_document_discard)(FoundryDocument document,
                                             uint64_t expected_revision, uint64_t *revision);
    FoundryResult (*author_document_copy_source)(FoundryDocument document, uint8_t *buffer,
                                                 uint64_t capacity, uint64_t *needed);

    /* -- Authoring: the schema tree ---------------------------------------------------- */

    /* Every schema an author may write in this package, by the spelling that goes in the
     * file: the engine's own, every dependency's, and every one this package declares. */
    FoundryResult (*author_schema_next)(FoundryWorkspace workspace, FoundryCursor *cursor,
                                        FoundrySchemaNode *out);
    FoundryResult (*author_schema_find)(FoundryWorkspace workspace, FoundryStr name,
                                        FoundrySchemaNode *out);
    FoundryResult (*author_schema_node_info)(FoundrySchemaNode node,
                                             FoundryAuthorSchemaNodeInfo *out);
    /* One field of a schema or of a nested block, or — for a list — its element type,
     * which is its one child. */
    FoundryResult (*author_schema_node_child)(FoundrySchemaNode node, uint32_t index,
                                              FoundrySchemaNode *out);
    /* The declared default as a traversable value, or FOUNDRY_ERR_NOT_FOUND. */
    FoundryResult (*author_schema_node_default)(FoundrySchemaNode node,
                                                FoundrySourceNode *out);

    /* -- Authoring: the source, dependency and preview trees --------------------------- */

    /* The record definitions written in this document. An imported record belongs to the
     * file it was written in and is walked there. */
    FoundryResult (*author_record_next)(FoundryDocument document, FoundryCursor *cursor,
                                        FoundrySourceNode *out);
    FoundryResult (*author_dependency_next)(FoundryWorkspace workspace, FoundryCursor *cursor,
                                            FoundryAuthorPackageInfo *out);
    FoundryResult (*author_dependency_record_next)(FoundryWorkspace workspace,
                                                   uint32_t package, FoundryCursor *cursor,
                                                   FoundrySourceNode *out);
    /* The records the last preview activation published, read through the same node calls
     * as a draft. FOUNDRY_ERR_UNAVAILABLE without a preview grant, FOUNDRY_ERR_NOT_FOUND
     * before anything has been activated. */
    FoundryResult (*author_preview_record_next)(FoundryWorkspace workspace,
                                                FoundryCursor *cursor,
                                                FoundrySourceNode *out);
    FoundryResult (*author_node_info)(FoundrySourceNode node, FoundryAuthorNodeInfo *out);
    FoundryResult (*author_node_child)(FoundrySourceNode node, uint32_t index,
                                       FoundrySourceNode *out);
    FoundryResult (*author_node_field)(FoundrySourceNode node, FoundryStr name,
                                       FoundrySourceNode *out);
    /* The exact value, as text plus its declared type. FOUNDRY_ERR_UNSUPPORTED for a
     * container, which `author_node_info` already describes. */
    FoundryResult (*author_node_scalar)(FoundrySourceNode node, FoundryAuthorValue *out);
    /* The same text, into the caller's buffer: what to use rather than keeping a borrow. */
    FoundryResult (*author_node_copy_text)(FoundrySourceNode node, uint8_t *buffer,
                                           uint64_t capacity, uint64_t *needed);

    /* -- Authoring: commands ----------------------------------------------------------- */

    /*
     * Every command carries the revision the caller believes it is editing, and a stale one
     * is FOUNDRY_ERR_REFUSED with nothing changed. Each is atomic in memory: a failure
     * leaves the old bytes, the old revision and the whole history intact.
     *
     * Each also invalidates **every** outstanding node handle, including ones it did not
     * touch, because a node is a position in a parse and the command replaced the parse.
     */
    FoundryResult (*author_record_create)(FoundryDocument document, uint64_t expected_revision,
                                          FoundryStr schema, FoundryStr id,
                                          FoundryAuthorEdit *out);
    FoundryResult (*author_record_duplicate)(FoundrySourceNode record,
                                             FoundryDocument destination,
                                             uint64_t expected_revision, FoundryStr id,
                                             FoundryAuthorEdit *out);
    /* A whole-record override of a read-only dependency definition, copied exactly. A
     * future upstream field is not merged into it later; the client says so. */
    FoundryResult (*author_record_override)(FoundrySourceNode dependency_record,
                                            FoundryDocument destination,
                                            uint64_t expected_revision,
                                            FoundryAuthorEdit *out);
    FoundryResult (*author_record_delete)(FoundrySourceNode record, uint64_t expected_revision,
                                          FoundryAuthorEdit *out);
    FoundryResult (*author_value_set)(FoundrySourceNode node, uint64_t expected_revision,
                                      const FoundryAuthorValue *value, FoundryAuthorEdit *out);
    FoundryResult (*author_value_unset)(FoundrySourceNode node, uint64_t expected_revision,
                                        FoundryAuthorEdit *out);
    FoundryResult (*author_list_insert)(FoundrySourceNode list, uint64_t expected_revision,
                                        uint32_t index, const FoundryAuthorValue *value,
                                        FoundryAuthorEdit *out);
    FoundryResult (*author_list_remove)(FoundrySourceNode list, uint64_t expected_revision,
                                        uint32_t index, FoundryAuthorEdit *out);
    FoundryResult (*author_list_move)(FoundrySourceNode list, uint64_t expected_revision,
                                      uint32_t from, uint32_t to, FoundryAuthorEdit *out);
    FoundryResult (*author_undo)(FoundryWorkspace workspace, uint64_t expected_revision,
                                 FoundryAuthorEdit *out);
    FoundryResult (*author_redo)(FoundryWorkspace workspace, uint64_t expected_revision,
                                 FoundryAuthorEdit *out);

    /* -- Authoring: persistence -------------------------------------------------------- */

    /* One file, published atomically. `durable` and `outcome` are separate answers: a
     * publication that succeeded with weaker crash durability is not a failure. */
    FoundryResult (*author_save_document)(FoundryDocument document, uint64_t expected_revision,
                                          FoundryAuthorSaveResult *out);
    /* Every dirty file, in stable relative-name order, stopping at the first failure. */
    FoundryResult (*author_save_all)(FoundryWorkspace workspace, uint64_t expected_revision,
                                     FoundryAuthorSaveAll *out);
    /* What the last save-all did, file by file. */
    FoundryResult (*author_save_entry_next)(FoundryWorkspace workspace, FoundryCursor *cursor,
                                            FoundryAuthorSaveEntry *out);

    /* -- Authoring: diagnostics -------------------------------------------------------- */

    /* Compile the current drafts without keeping anything. The diagnostics are the answer;
     * the result code says only whether the attempt could be made. */
    FoundryResult (*author_validate)(FoundryWorkspace workspace, uint64_t expected_revision);
    /* The last operation's diagnostic snapshot, readable until the next operation replaces
     * it. Nothing here requires scraping a log. */
    FoundryResult (*author_diagnostic_next)(FoundryWorkspace workspace, FoundryCursor *cursor,
                                            FoundryAuthorDiagnostic *out);

    /* -- Authoring: products ----------------------------------------------------------- */

    /* Compile the **saved** bytes into a private candidate. Refused while any document is
     * dirty or has changed on disk. A successful build is kept until it is released. */
    FoundryResult (*author_build)(FoundryWorkspace workspace, uint64_t expected_revision,
                                  FoundryBuild *out);
    FoundryResult (*author_build_info)(FoundryBuild build, FoundryAuthorBuildInfo *out);
    /* Refused while a preview is holding this build: releasing deletes the files the
     * loaded content is reading. */
    FoundryResult (*author_build_release)(FoundryBuild build);
    FoundryResult (*author_export_next)(FoundryWorkspace workspace, FoundryCursor *cursor,
                                        FoundryAuthorExportInfo *out);
    /* Write a build to one of the destinations the host configured, by its number. Files
     * are replaced one at a time and `*written` says how many were, so a partial
     * publication is reported rather than implied. */
    FoundryResult (*author_build_export)(FoundryBuild build, uint32_t destination,
                                         uint32_t *written);
    /* Ask the host to make this build the loaded content. FOUNDRY_ERR_UNAVAILABLE where the
     * host granted no preview; FOUNDRY_ERR_REFUSED when it declined, in which case whatever
     * was loaded before still is. */
    FoundryResult (*author_preview_activate)(FoundryBuild build);
    FoundryResult (*author_preview_info)(FoundryWorkspace workspace,
                                         FoundryAuthorPreviewInfo *out);
} FoundryApi_v4;


/* == Networking (v5) =================================================================== */

/*
 * The values the networking surface crosses with (networking.md §8 and its Step 5
 * Resolution). The host builds the service, its grants and credentials, and pumps it; a
 * consumer of this table creates sessions only by a grant the host published, and never
 * names an address, a file or a key.
 *
 * Enumerations are `int32_t` with these values. Two arrive from the caller — a channel's
 * direction and delivery, and a disconnect reason — and are validated as numbers.
 */

#define FOUNDRY_NET_SERVER 1
#define FOUNDRY_NET_CLIENT 2

#define FOUNDRY_NET_CLIENT_TO_SERVER 1
#define FOUNDRY_NET_SERVER_TO_CLIENT 2
#define FOUNDRY_NET_BIDIRECTIONAL 3

/* A reliable channel carries every message, in order. A latest-state channel is the one
 * that carries baselines and complete state, server to client; a newer state replaces one
 * not yet sent. */
#define FOUNDRY_NET_RELIABLE 1
#define FOUNDRY_NET_LATEST_STATE 2

#define FOUNDRY_NET_SESSION_CONFIGURING 1
#define FOUNDRY_NET_SESSION_RUNNING 2

#define FOUNDRY_NET_PEER_CONNECTING 1
#define FOUNDRY_NET_PEER_AUTHENTICATING 2
#define FOUNDRY_NET_PEER_NEGOTIATING 3
#define FOUNDRY_NET_PEER_SYNCHRONIZING 4
#define FOUNDRY_NET_PEER_ACTIVE 5
#define FOUNDRY_NET_PEER_CLOSING 6

#define FOUNDRY_NET_EVENT_ADMITTED 1
#define FOUNDRY_NET_EVENT_ACTIVATED 2
#define FOUNDRY_NET_EVENT_ENDED 3

#define FOUNDRY_NET_DELIVERY_BASELINE 1
#define FOUNDRY_NET_DELIVERY_STATE 2
#define FOUNDRY_NET_DELIVERY_MESSAGE 3

/* Why a connection ended. The ending's `code` is, by kind: LOCAL and PEER_DISCONNECTED, a
 * disconnect reason; REFUSED and REFUSED_BY_PEER, a refusal reason with `index` naming the
 * first entry that differed; TIMED_OUT, a deadline; PROTOCOL, a fault; TRANSPORT, a
 * transport failure. The others carry no code. */
#define FOUNDRY_NET_ENDING_LOCAL 1
#define FOUNDRY_NET_ENDING_PEER_DISCONNECTED 2
#define FOUNDRY_NET_ENDING_PEER_CLOSED 3
#define FOUNDRY_NET_ENDING_REFUSED 4
#define FOUNDRY_NET_ENDING_REFUSED_BY_PEER 5
#define FOUNDRY_NET_ENDING_REVOKED 6
#define FOUNDRY_NET_ENDING_ROTATED 7
#define FOUNDRY_NET_ENDING_TIMED_OUT 8
#define FOUNDRY_NET_ENDING_PROTOCOL 9
#define FOUNDRY_NET_ENDING_TRANSPORT 10
#define FOUNDRY_NET_ENDING_OVERLOADED 11

/* Disconnect reasons: what `net_peer_disconnect` takes, and what a peer said. */
#define FOUNDRY_NET_DISCONNECT_CLOSED 1
#define FOUNDRY_NET_DISCONNECT_PROTOCOL 2
#define FOUNDRY_NET_DISCONNECT_POLICY 3
#define FOUNDRY_NET_DISCONNECT_TIMEOUT 4
#define FOUNDRY_NET_DISCONNECT_CAPACITY 5
#define FOUNDRY_NET_DISCONNECT_APPLICATION 6

#define FOUNDRY_NET_REFUSAL_GENERIC 1
#define FOUNDRY_NET_REFUSAL_VERSION 2
#define FOUNDRY_NET_REFUSAL_APPLICATION 3
#define FOUNDRY_NET_REFUSAL_COMPATIBILITY 4
#define FOUNDRY_NET_REFUSAL_CATALOGUE 5
#define FOUNDRY_NET_REFUSAL_CHANNEL 6
#define FOUNDRY_NET_REFUSAL_CAPACITY 7
#define FOUNDRY_NET_REFUSAL_POLICY 8
#define FOUNDRY_NET_REFUSAL_TIMEOUT 9
/* A refusal that names no entry. */
#define FOUNDRY_NET_NO_INDEX 0xFFFFu

#define FOUNDRY_NET_DEADLINE_ADMISSION 1
#define FOUNDRY_NET_DEADLINE_INITIAL_SYNC 2
#define FOUNDRY_NET_DEADLINE_NO_PROGRESS 3
#define FOUNDRY_NET_DEADLINE_WRITE_STALL 4

#define FOUNDRY_NET_FAULT_MALFORMED 1
#define FOUNDRY_NET_FAULT_UNEXPECTED 2
#define FOUNDRY_NET_FAULT_SEQUENCE 3
#define FOUNDRY_NET_FAULT_TRUNCATED 4
#define FOUNDRY_NET_FAULT_MISMATCH 5

/* Transport failures: a category, never a certificate's contents. */
#define FOUNDRY_NET_FAILURE_REFUSED 1
#define FOUNDRY_NET_FAILURE_UNREACHABLE_ADDRESS 2
#define FOUNDRY_NET_FAILURE_TIMED_OUT 3
#define FOUNDRY_NET_FAILURE_RESET 4
#define FOUNDRY_NET_FAILURE_CLOSED_EARLY 5
#define FOUNDRY_NET_FAILURE_TRUNCATED 6
#define FOUNDRY_NET_FAILURE_NETWORK_DOWN 7
#define FOUNDRY_NET_FAILURE_CARRIER 8
#define FOUNDRY_NET_FAILURE_CERTIFICATE_MISSING 9
#define FOUNDRY_NET_FAILURE_CERTIFICATE_UNTRUSTED 10
#define FOUNDRY_NET_FAILURE_CERTIFICATE_EXPIRED 11
#define FOUNDRY_NET_FAILURE_CERTIFICATE_NOT_YET_VALID 12
#define FOUNDRY_NET_FAILURE_CERTIFICATE_WRONG_USAGE 13
#define FOUNDRY_NET_FAILURE_CERTIFICATE_WRONG_NAME 14
#define FOUNDRY_NET_FAILURE_CERTIFICATE_REJECTED 15
#define FOUNDRY_NET_FAILURE_CERTIFICATE_CHAIN_TOO_LONG 16
#define FOUNDRY_NET_FAILURE_SERVER_KEY_MISMATCH 17
#define FOUNDRY_NET_FAILURE_PEER_REFUSED 18
#define FOUNDRY_NET_FAILURE_PROTOCOL 19
#define FOUNDRY_NET_FAILURE_HANDSHAKE_BUDGET 20
#define FOUNDRY_NET_FAILURE_TLS_MEMORY 21
#define FOUNDRY_NET_FAILURE_CLOCK_UNAVAILABLE 22
#define FOUNDRY_NET_FAILURE_INTERNAL 23

/* A numeric IPv4 endpoint, as a grant names it. */
typedef struct FoundryNetEndpoint {
    uint8_t address[4];
    uint16_t port;
    uint16_t reserved;
} FoundryNetEndpoint;

/* A grant as a consumer may see it: never its credentials. */
typedef struct FoundryNetGrantInfo {
    FoundryContentId id;
    /* FOUNDRY_NET_SERVER or FOUNDRY_NET_CLIENT. */
    int32_t role;
    uint32_t reserved;
    FoundryNetEndpoint endpoint;
} FoundryNetGrantInfo;

/* A runtime-registered channel: a namespaced id, a payload revision, a size limit, which
 * way it runs and how it delivers. The engine gives its bytes no meaning. */
typedef struct FoundryNetChannelDesc {
    FoundryContentId id;
    uint32_t revision;
    uint32_t max_payload_bytes;
    int32_t direction;
    int32_t delivery;
} FoundryNetChannelDesc;

typedef struct FoundryNetSessionInfo {
    FoundryContentId grant;
    int32_t role;
    int32_t state;
    /* The session epoch; 0 until a server listens or a client is admitted. */
    uint64_t epoch;
    uint16_t channels;
    /* Connections still authenticating, which are not yet peers. */
    uint16_t pending;
    uint16_t peers;
    FoundryBool listening;
    uint8_t reserved;
    /* Where a listening server is bound, the port the system chose included. */
    FoundryNetEndpoint listen_endpoint;
} FoundryNetSessionInfo;

/* A peer as a consumer may see it: its participant number within its session's epoch, and
 * nothing that identifies the player behind it. */
typedef struct FoundryNetPeerInfo {
    FoundryNetSession session;
    int32_t state;
    /* 0 until admitted. Never reused within a session. */
    uint32_t participant;
    uint64_t epoch;
} FoundryNetPeerInfo;

typedef struct FoundryNetEnding {
    int32_t kind;
    int32_t code;
    /* A refusal's first differing entry, or FOUNDRY_NET_NO_INDEX. */
    uint32_t index;
    uint32_t reserved;
} FoundryNetEnding;

/* A peer was admitted, activated or ended. Admission and activation carry the epoch; an
 * ending carries why. The peer handle is stale once its ending has been read and the
 * connection has closed. */
typedef struct FoundryNetEvent {
    FoundryNetSession session;
    FoundryNetPeer peer;
    int32_t kind;
    uint32_t participant;
    uint64_t epoch;
    FoundryNetEnding ending;
} FoundryNetEvent;

/* What a client receives: its baseline, then reliable messages in arrival order and the
 * newest untaken state. A baseline is acknowledged by its `sequence` and `tick`. */
typedef struct FoundryNetDelivery {
    int32_t kind;
    uint32_t bytes;
    FoundryContentId channel;
    /* The server tick a baseline or state was stamped with; 0 for a message. */
    uint64_t tick;
    uint64_t sequence;
} FoundryNetDelivery;

/* One command of a server tick's admitted batch. A batch is ordered by participant, then
 * by number — never by arrival — so batches recorded in order replay. */
typedef struct FoundryNetCommand {
    FoundryNetPeer peer;
    uint32_t participant;
    uint32_t bytes;
    /* Counted from 1 on its connection: the number `net_command_send` returned. */
    uint64_t number;
    FoundryContentId channel;
} FoundryNetCommand;

/* The whole service's counters. They name no session and no peer. */
typedef struct FoundryNetStats {
    uint32_t sessions;
    uint32_t peers;
    uint32_t pending;
    uint32_t queued_events;
    uint32_t reserved_events;
    uint32_t reserved;
    uint64_t accepted;
    uint64_t shed;
    uint64_t handshake_failures;
    uint64_t pending_timeouts;
    uint64_t denied;
    uint64_t duplicates;
    uint64_t capacity_refusals;
    uint64_t refused;
    uint64_t admitted;
    uint64_t activations;
    uint64_t baselines_sent;
    uint64_t commands_sent;
    uint64_t commands_received;
    uint64_t commands_admitted;
    uint64_t states_sent;
    uint64_t states_replaced;
    uint64_t frames_received;
    uint64_t frames_sent;
    uint64_t bytes_received;
    uint64_t bytes_sent;
} FoundryNetStats;

/* ABI v5 repeats v4 byte-for-byte and appends M16 networking (networking.md §8). */
typedef struct FoundryApi_v5 {
    /* Always 5, and `sizeof(FoundryApi_v5)` as the host built it. Both are redundant with
     * `get_api`, and both are here for the case the query cannot reach: a crash dump on a
     * player's machine, where the one thing worth knowing is whether the mod was built
     * against this header. Eight bytes, and every other answer involves asking the player to
     * reproduce something. */
    uint32_t version;
    uint32_t size;

    /* -- Results and logging ----------------------------------------------------------- */

    /* The name of a result code — "FOUNDRY_ERR_NOT_FOUND" — so a mod can log legibly without
     * shipping its own copy of the table and letting it go stale. Empty for a code this host
     * has never issued, which is the honest answer rather than an invented one. Always
     * available: it needs no subsystem. */
    FoundryStr (*result_name)(FoundryResult result);

    /* Writes one line to the engine's log, tagged with the mod's own scope. Available on a
     * host with no subsystems at all, deliberately: a mod refusing itself has to be able to
     * say why. */
    FoundryResult (*log_write)(FoundryMod self, FoundryLogLevel level, FoundryStr message);

    /* Walks the in-memory log ring, oldest first, from a cursor starting at
     * FOUNDRY_CURSOR_BEGIN. Returns FOUNDRY_END when there is nothing more. */
    FoundryResult (*log_next)(FoundryCursor *cursor, FoundryLogRecord *out);

    /* -- Content identity -------------------------------------------------------------- */

    /* Hashes a `namespace:name` string, validating its shape first — the same validation the
     * content compiler applies, so a string this refuses would never have compiled either.
     * `foundry_content_id` in this header hashes without validating; this is the checked
     * form, and needs no subsystem. */
    FoundryResult (*id_from_string)(FoundryStr text, FoundryContentId *out);

    /* The spelling of an id, borrowed from the package that supplied it. FOUNDRY_ERR_NOT_FOUND
     * when nothing loaded carries that id: a hash cannot be reversed, so an id nobody spells
     * has no name to give. */
    FoundryResult (*id_to_string)(FoundryContentId id, FoundryStr *out);

    /* The same spelling, copied into the caller's buffer, for a mod that needs the bytes past
     * the call. Writes `*needed` with the length whether or not it fitted and returns
     * FOUNDRY_ERR_LIMIT rather than truncating — silent truncation of a name is how a mod
     * ships with a bug nobody can see. `buffer` may be NULL when `capacity` is 0, which is
     * how a caller asks for the length alone. */
    FoundryResult (*id_copy_string)(FoundryContentId id, uint8_t *buffer, uint64_t capacity,
                                    uint64_t *needed);

    /* -- The frame --------------------------------------------------------------------- */

    /* The engine's frame counter, which is what a log line's `frame` stamp lines up with. */
    FoundryResult (*frame_index)(uint64_t *out);

    /* Wall-clock length of the previous frame. **Presentation only.** Simulation time is the
     * tick, never this: a mod that integrates motion against a wall clock has made its own
     * behaviour depend on how fast the machine is. */
    FoundryResult (*frame_delta_ns)(uint64_t *out);

    /* Total simulated time, which is an exact multiple of the tick and is therefore the same
     * number on every machine that ran the same ticks. */
    FoundryResult (*elapsed_ns)(uint64_t *out);

    /* The exact length of one simulation step. Nanoseconds rather than a rate in hertz,
     * because the engine's timestep is an exact rational and a rounded rate would not
     * reproduce it. */
    FoundryResult (*tick_delta_ns)(uint64_t *out);

    /* -- The profiler ------------------------------------------------------------------ */

    /* Opens a named timing span, so a mod's own work appears in the profiler beside the
     * engine's. Strictly nested, and every span a mod opens it must close. */
    FoundryResult (*scope_begin)(FoundryStr name);

    /* Closes the innermost span this mod opened. FOUNDRY_ERR_REFUSED when none is open,
     * rather than closing one the engine or the game opened. */
    FoundryResult (*scope_end)(void);

    /* -- Memory ------------------------------------------------------------------------ */

    /* Opens a named counter in the engine's memory report. The name is copied. */
    FoundryResult (*memory_counter_open)(FoundryMod self, FoundryStr name,
                                         FoundryMemoryCounter *out);

    /* Publishes a mod's own numbers into a counter it opened. */
    FoundryResult (*memory_counter_set)(FoundryMemoryCounter counter,
                                        const FoundryMemoryStats *stats);

    /* -- Content ----------------------------------------------------------------------- */

    /* Bumped whenever content changes under the program — a hot reload, a package added.
     * **The one signal a mod needs**: anything derived from content, including every record
     * handle and every borrowed string, is derived again when this moves. */
    FoundryResult (*content_generation)(uint64_t *out);

    /* The record a content id names, after every package has been merged and every override
     * applied. What a mod gets is the definition that *won*, which is the same one the game
     * sees — there is no privileged view. */
    FoundryResult (*content_find)(FoundryContentId id, FoundryRecord *out);

    /* Every record, in merge order. */
    FoundryResult (*content_next)(FoundryCursor *cursor, FoundryRecord *out);

    /* Every record of one schema, in merge order. How a mod finds "all the items" without
     * knowing what any package called them. */
    FoundryResult (*content_next_of_schema)(FoundrySchemaId schema, FoundryCursor *cursor,
                                            FoundryRecord *out);

    /* -- Reading a record -------------------------------------------------------------- */

    /*
     * A record is read by asking its schema what each field is and then calling the matching
     * reader. That is how a mod reads a record type it has never heard of — including one
     * another mod declared — and it is what the debug overlay's inspector already does.
     *
     * A field a record does not carry answers FOUNDRY_ERR_NOT_FOUND, which is different from
     * a field that is not in the schema at all (FOUNDRY_ERR_INVALID_ARGUMENT) and different
     * again from asking for it with the wrong reader (also INVALID_ARGUMENT). A record
     * written against an older version of its schema answers newer fields with their
     * declared defaults, which is what makes a schema able to grow.
     */

    /* A nested block has no identity of its own — that is what nested means — so `record_id`,
     * `record_name` and `record_package` answer FOUNDRY_ERR_NOT_FOUND for one. */
    FoundryResult (*record_id)(FoundryRecord record, FoundryContentId *out);
    FoundryResult (*record_name)(FoundryRecord record, FoundryStr *out);
    FoundryResult (*record_schema)(FoundryRecord record, FoundrySchemaId *out);
    FoundryResult (*record_package)(FoundryRecord record, FoundryPackage *out);

    FoundryResult (*record_field_count)(FoundryRecord record, uint32_t *out);
    FoundryResult (*record_field_index)(FoundryRecord record, FoundryStr name, uint32_t *out);
    FoundryResult (*record_field_name)(FoundryRecord record, uint32_t field, FoundryStr *out);
    FoundryResult (*record_field_type)(FoundryRecord record, uint32_t field,
                                       FoundryFieldType *out);
    /* Whether the record actually carries a value for the field, as opposed to the field
     * being absent. A missing optional field and a field set to its default are different
     * things, and collapsing them would make "this item drops nothing" and "this item's drop
     * was never specified" indistinguishable. */
    FoundryResult (*record_field_present)(FoundryRecord record, uint32_t field,
                                          FoundryBool *out);

    FoundryResult (*record_get_bool)(FoundryRecord record, uint32_t field, FoundryBool *out);
    /* Every signed integer field, widened. What the file stores is what the schema declared;
     * this is what covers all of them. */
    FoundryResult (*record_get_i64)(FoundryRecord record, uint32_t field, int64_t *out);
    FoundryResult (*record_get_u64)(FoundryRecord record, uint32_t field, uint64_t *out);
    FoundryResult (*record_get_f32)(FoundryRecord record, uint32_t field, float *out);
    /* Borrowed from the package's own bytes, and not NUL-terminated. */
    FoundryResult (*record_get_string)(FoundryRecord record, uint32_t field, FoundryStr *out);
    /* The second of the two calls in `_v1` that copy rather than borrow. Same rules as
     * `id_copy_string`: `needed` is always written, and too small is a refusal. */
    FoundryResult (*record_copy_string)(FoundryRecord record, uint32_t field, uint8_t *buffer,
                                        uint64_t capacity, uint64_t *needed);
    FoundryResult (*record_get_id)(FoundryRecord record, uint32_t field, FoundryContentId *out);

    /* An inline struct, as something that answers the same field calls one level down. This
     * composes to any depth and needs no path language invented for the boundary.
     *
     * The view it hands back is borrowed like everything else here, and it is borrowed from a
     * ring: it stays valid until enough further views have been opened to recycle its slot,
     * and a recycled one answers FOUNDRY_ERR_INVALID_HANDLE rather than reading whatever now
     * sits there. Reading a record never needs more than a few at once. */
    FoundryResult (*record_nested)(FoundryRecord record, uint32_t field, FoundryRecord *out);

    FoundryResult (*record_list_len)(FoundryRecord record, uint32_t field, uint32_t *out);
    FoundryResult (*record_list_get_i64)(FoundryRecord record, uint32_t field, uint32_t index,
                                         int64_t *out);
    FoundryResult (*record_list_get_f32)(FoundryRecord record, uint32_t field, uint32_t index,
                                         float *out);
    FoundryResult (*record_list_get_string)(FoundryRecord record, uint32_t field,
                                            uint32_t index, FoundryStr *out);
    FoundryResult (*record_list_get_id)(FoundryRecord record, uint32_t field, uint32_t index,
                                        FoundryContentId *out);
    FoundryResult (*record_list_nested)(FoundryRecord record, uint32_t field, uint32_t index,
                                        FoundryRecord *out);

    /* -- Packages ---------------------------------------------------------------------- */

    FoundryResult (*package_count)(uint32_t *out);
    /* Every loaded package, **in load order**, which is the order overrides were applied in
     * and therefore the only order worth walking them in. */
    FoundryResult (*package_next)(FoundryCursor *cursor, FoundryPackage *out);
    FoundryResult (*package_find)(FoundryContentId id, FoundryPackage *out);
    FoundryResult (*package_id)(FoundryPackage package, FoundryContentId *out);
    FoundryResult (*package_name)(FoundryPackage package, FoundryStr *out);
    FoundryResult (*package_version)(FoundryPackage package, uint32_t *out);
    /* Position in the load order. Zero is package zero — the engine's own content, loaded
     * through the same path a mod's is. */
    FoundryResult (*package_order)(FoundryPackage package, uint32_t *out);

    /* -- Schemas ----------------------------------------------------------------------- */

    FoundryResult (*schema_count)(uint32_t *out);
    FoundryResult (*schema_next)(FoundryCursor *cursor, FoundrySchema *out);
    FoundryResult (*schema_find)(FoundrySchemaId id, FoundrySchema *out);
    FoundryResult (*schema_id)(FoundrySchema schema, FoundrySchemaId *out);
    FoundryResult (*schema_version)(FoundrySchema schema, uint32_t *out);
    FoundryResult (*schema_field_count)(FoundrySchema schema, uint32_t *out);
    FoundryResult (*schema_field_name)(FoundrySchema schema, uint32_t field, FoundryStr *out);
    FoundryResult (*schema_field_type)(FoundrySchema schema, uint32_t field,
                                       FoundryFieldType *out);

    /* -- Assets ------------------------------------------------------------------------ */

    /* Loads an asset if it is not loaded, and adds a reference either way. **This is the one
     * reference count a mod owns**, and the one thing in `_v1` a mod must balance: an asset
     * acquired and never released stays in memory for the life of the process. */
    FoundryResult (*asset_acquire)(FoundryContentId id, FoundryAsset *out);
    FoundryResult (*asset_release)(FoundryAsset asset);
    /* Finds one already loaded, without acquiring it. */
    FoundryResult (*asset_find)(FoundryContentId id, FoundryAsset *out);
    FoundryResult (*asset_next)(FoundryCursor *cursor, FoundryAsset *out);
    FoundryResult (*asset_content_id)(FoundryAsset asset, FoundryContentId *out);
    FoundryResult (*asset_schema)(FoundryAsset asset, FoundrySchemaId *out);
    /* Zero means evictable, not freed — a real answer to "why is this still in memory". */
    FoundryResult (*asset_refcount)(FoundryAsset asset, uint32_t *out);

    /* -- Scene ------------------------------------------------------------------------- */

    /* Registers the in-memory half of a component whose schema the mod's content package
     * already declared. Registration is startup-only, like the engine's own component types. */
    FoundryResult (*world_register_component)(FoundryMod self,
                                              const FoundryComponentDesc *desc,
                                              FoundryComponentType *out);
    FoundryResult (*world_find_component_type)(FoundrySchemaId schema,
                                               FoundryComponentType *out);
    /* Registered types, in registration order. A changed registry invalidates the cursor. */
    FoundryResult (*world_component_type_next)(FoundryCursor *cursor,
                                                FoundryComponentType *out);
    FoundryResult (*world_component_type_schema)(FoundryComponentType type,
                                                  FoundrySchemaId *out);
    FoundryResult (*world_component_type_name)(FoundryComponentType type, FoundryStr *out);
    FoundryResult (*world_component_type_size)(FoundryComponentType type, uint32_t *out);
    FoundryResult (*world_component_type_alignment)(FoundryComponentType type, uint32_t *out);
    /* How many entities have one — the number a query over this type would visit, not a
     * count of registered types. */
    FoundryResult (*world_component_type_count)(FoundryComponentType type, uint32_t *out);
    /* Whether a save carries it, which is also whether `world_read_component` can show it.
     * False for a type registered through `world_register_component`: raw C storage has no
     * serialized form the engine could invent for it. */
    FoundryResult (*world_component_type_savable)(FoundryComponentType type,
                                                   FoundryBool *out);

    FoundryResult (*world_create_entity)(FoundryEntity *out);
    FoundryResult (*world_destroy_entity)(FoundryEntity entity);
    FoundryResult (*world_contains)(FoundryEntity entity, FoundryBool *out);
    FoundryResult (*world_entity_count)(uint32_t *out);
    /* Live entities, in slot-index order. A structural change invalidates the cursor. */
    FoundryResult (*world_next_entity)(FoundryCursor *cursor, FoundryEntity *out);

    /* `initial` is either NULL with zero size (construct or zero initialize), or exactly
     * the registered component size. Its bytes are copied before this call returns. */
    FoundryResult (*world_add_component)(FoundryEntity entity, FoundryComponentType type,
                                         const void *initial, uint32_t initial_size);
    FoundryResult (*world_remove_component)(FoundryEntity entity, FoundryComponentType type);
    FoundryResult (*world_has_component)(FoundryEntity entity, FoundryComponentType type,
                                         FoundryBool *out);

    FoundryResult (*world_register_system)(FoundryMod self, const FoundrySystemDesc *desc);
    /* Opens a query over one or more component types. The returned cursor names the query
     * until it ends, is recycled, or the world changes shape. A type the world does not
     * know is FOUNDRY_ERR_INVALID_HANDLE rather than a walk that quietly matches nothing.
     *
     * Iteration is driven by the FIRST named type, so name the most selective one first. */
    FoundryResult (*world_query_begin)(const FoundryComponentType *types, uint32_t count,
                                       FoundryCursor *out);
    FoundryResult (*world_query_next)(FoundryCursor *cursor, FoundryEntity *out);

    /* `entity_template` rather than `template`, which is a C++ keyword: this header has to
     * compile as C++ too, and a parameter name is documentation rather than ABI. */
    FoundryResult (*world_spawn)(FoundryContentId entity_template, FoundryEntity *out);
    FoundryResult (*world_spawn_scene)(FoundryContentId scene, uint32_t *out);
    /* Schema-described data for any savable component, read through the type's own
     * serializer rather than by casting its bytes — so it works for a type this build was
     * never compiled against. FOUNDRY_ERR_UNSUPPORTED for a type with no serializer, which
     * today means every type registered through `world_register_component`.
     *
     * The record is borrowed FOR THE CURRENT FRAME ONLY, and is the one borrow at this
     * boundary with that lifetime: it is serialized into the frame arena rather than read
     * out of a loaded package. Using it on a later frame is FOUNDRY_ERR_INVALID_HANDLE. */
    FoundryResult (*world_read_component)(FoundryEntity entity, FoundryComponentType type,
                                          FoundryRecord *out);
    /* The one raw-storage fast path: only the mod that registered `type` receives it, and
     * the pointer is invalid after the next structural world mutation. A marker type — one
     * registered with size zero — yields NULL and a size of zero, which is FOUNDRY_OK. */
    FoundryResult (*world_component_bytes)(FoundryMod self, FoundryEntity entity,
                                           FoundryComponentType type, void **out,
                                           uint32_t *size);

    /* -- Render2d --------------------------------------------------------------------- */

    FoundryResult (*render_texture_of_asset)(FoundryAsset asset, FoundryTexture *out);
    FoundryResult (*render_destroy_texture)(FoundryTexture texture);
    FoundryResult (*render_draw_sprite)(const FoundryRenderSprite *sprite);
    FoundryResult (*render_draw_text)(const FoundryRenderFont *font, FoundryStr text,
                                      const FoundryRenderTextOptions *options);
    FoundryResult (*render_add_view)(const FoundryRenderViewDesc *desc, FoundryView *out);
    FoundryResult (*render_select_view)(FoundryView view);
    FoundryResult (*render_camera_get)(FoundryRenderCamera *out);
    FoundryResult (*render_camera_set)(const FoundryRenderCamera *camera);
    FoundryResult (*render_world_to_screen)(FoundryRenderVec2 world, FoundryRenderVec2 *out);
    FoundryResult (*render_screen_to_world)(FoundryRenderVec2 screen, FoundryRenderVec2 *out);
    FoundryResult (*render_stats)(FoundryRenderStats *out);

    /* -- UI --------------------------------------------------------------------------- */

    FoundryResult (*ui_begin)(const FoundryUiRect *viewport);
    FoundryResult (*ui_end)(void);
    FoundryResult (*ui_push_id)(FoundryUiId id);
    FoundryResult (*ui_pop_id)(void);
    FoundryResult (*ui_begin_panel)(FoundryUiId id, const FoundryUiRect *bounds);
    FoundryResult (*ui_end_panel)(void);
    FoundryResult (*ui_begin_row)(FoundryUiId id, float height);
    FoundryResult (*ui_end_row)(void);
    FoundryResult (*ui_begin_scroll)(FoundryUiId id, const FoundryUiRect *bounds, float content);
    FoundryResult (*ui_end_scroll)(void);
    FoundryResult (*ui_label)(FoundryStr text);
    FoundryResult (*ui_button)(FoundryUiId id, FoundryStr text, FoundryBool *out);
    FoundryResult (*ui_checkbox)(FoundryUiId id, FoundryStr text, FoundryBool *checked,
                                 FoundryBool *changed);
    FoundryResult (*ui_slider)(FoundryUiId id, FoundryStr text, float *value, float min, float max,
                               FoundryBool *changed);
    FoundryResult (*ui_slider_int)(FoundryUiId id, FoundryStr text, int32_t *value, int32_t min,
                                   int32_t max, FoundryBool *changed);
    FoundryResult (*ui_separator)(void);
    FoundryResult (*ui_spacer)(float size);
    FoundryResult (*ui_collapsing_header)(FoundryUiId id, FoundryStr text, FoundryBool *open);
    FoundryResult (*ui_text_field)(FoundryUiId id, uint8_t *buffer, uint64_t capacity,
                                   uint64_t *length, FoundryBool *changed);
    FoundryResult (*ui_plot)(const float *samples, uint64_t count,
                             const FoundryUiPlotOptions *options);
    FoundryResult (*ui_style_get)(FoundryUiStyle *out);
    FoundryResult (*ui_style_set)(const FoundryUiStyle *style);
    FoundryResult (*ui_wants_keyboard)(FoundryBool *out);
    FoundryResult (*ui_wants_pointer)(FoundryBool *out);

    /* -- Audio ------------------------------------------------------------------------ */

    FoundryResult (*audio_play)(FoundryContentId id, float gain, float pan, float pitch,
                                FoundryBool looping, FoundryVoice *out);
    FoundryResult (*audio_stop)(FoundryVoice voice);
    FoundryResult (*audio_set_gain)(FoundryVoice voice, float gain);
    FoundryResult (*audio_set_pan)(FoundryVoice voice, float pan);
    FoundryResult (*audio_set_pitch)(FoundryVoice voice, float pitch);
    FoundryResult (*audio_set_master_gain)(float gain);

    /* -- Physics2d -------------------------------------------------------------------- */

    FoundryResult (*physics_create_body)(const FoundryPhysicsBodyDesc *desc, FoundryBody *out);
    FoundryResult (*physics_destroy_body)(FoundryBody body);
    FoundryResult (*physics_move_body)(FoundryBody body, FoundryPhysicsVec2 motion,
                                       FoundryPhysicsHit *hits, uint32_t capacity,
                                       FoundryPhysicsMoveResult *out);
    FoundryResult (*physics_query_point)(FoundryPhysicsVec2 point, uint32_t mask,
                                         FoundryPhysicsQueryHit *hits, uint32_t capacity,
                                         uint32_t *count, uint32_t *total);
    FoundryResult (*physics_query_aabb)(FoundryPhysicsVec2 min, FoundryPhysicsVec2 max,
                                        uint32_t mask, FoundryPhysicsQueryHit *hits,
                                        uint32_t capacity, uint32_t *count, uint32_t *total);
    FoundryResult (*physics_query_ray)(FoundryPhysicsVec2 from, FoundryPhysicsVec2 to,
                                       uint32_t mask, FoundryPhysicsHit *hits, uint32_t capacity,
                                       uint32_t *count, uint32_t *total);
    FoundryResult (*physics_body_contacts)(FoundryBody body, FoundryPhysicsQueryHit *hits,
                                           uint32_t capacity, uint32_t *count, uint32_t *total);
    /* Copies one `foundry:script` payload made by the host's exact built-in source
     * loader. `needed` and `revision` are required and are written for a valid asset
     * even when capacity is too small; that case returns FOUNDRY_ERR_LIMIT and copies
     * nothing. `(NULL, 0)` is the sizing probe. A successful copy has exactly `needed`
     * bytes and no terminator. Balance the asset reference with `asset_release`.
     *
     * A stale handle is FOUNDRY_ERR_INVALID_HANDLE. Another asset kind or loader is
     * FOUNDRY_ERR_UNSUPPORTED. An absent engine or source loader is
     * FOUNDRY_ERR_UNAVAILABLE. */
    FoundryResult (*script_source_copy)(FoundryAsset asset, uint8_t *buffer,
                                        uint64_t capacity, uint64_t *needed,
                                        uint64_t *revision);

    /* -- Mod management (v3) ---------------------------------------------------------- */

    /*
     * What a player has installed and chosen, answered when the host supplied its mod set.
     * A host that did not answers FOUNDRY_ERR_UNAVAILABLE to every call here.
     *
     * **Nothing here changes the running game.** A selection applies at the next start
     * (ADR-0040): this session keeps the packages it started with, which is what `loaded`
     * reports, while everything named `pending` describes the next start.
     *
     * Every walk's cursor is refused with FOUNDRY_ERR_INVALID_ARGUMENT after a successful
     * change, and every borrowed string lasts until one. Start the walk again.
     */

    /* Every copy of every package found, duplicates included: each folder the host searches,
     * in the host's order, and each folder's packages sorted by file name. */
    FoundryResult (*mods_installed_next)(FoundryCursor *cursor, FoundryModInfo *out);
    /* The player's list, in the player's order, which is the order `mods_move` edits. The
     * next start loads it in this order wherever dependencies allow. */
    FoundryResult (*mods_pending_next)(FoundryCursor *cursor, FoundryModPending *out);
    /* The dependencies of `package`, in its manifest's order. Asked of the copy the next start
     * would load, or of the first copy found when none would. FOUNDRY_ERR_NOT_FOUND when no
     * copy is installed. */
    FoundryResult (*mods_requirement_next)(FoundryContentId package, FoundryCursor *cursor,
                                           FoundryModRequirement *out);
    /* Every record `package` provides that another package in the pending order provides
     * too, sorted by the record's spelling. `package` won when it is `winner`. Nothing, not
     * an error, for a package that would not load. */
    FoundryResult (*mods_conflict_next)(FoundryContentId package, FoundryCursor *cursor,
                                        FoundryModConflict *out);
    /* Every package in the pending order that provides `record`, in load order; the last is
     * the winner. Nothing for a record no package provides. */
    FoundryResult (*mods_provider_next)(FoundryContentId record, FoundryCursor *cursor,
                                        FoundryModProvider *out);
    /* Every profile, by key, including ones whose files cannot be used. */
    FoundryResult (*mods_profile_next)(FoundryCursor *cursor, FoundryModProfile *out);
    FoundryResult (*mods_profile_active)(FoundryModProfileState *out);

    /*
     * Changes. **Each one answers FOUNDRY_ERR_REFUSED unless the host granted writes** when
     * it supplied the set. A host that shows its own mod screen grants them; one without a
     * screen has no reason to. The grant is the host's, made once, and not per mod.
     *
     * Consent to run a package's native code is not here and never will be: it is the
     * player's, given on the host's own screen, and no code can grant it to itself.
     */

    /* Enables a package at the end of the player's list, or removes it from the list. Either
     * is a no-op when already so. A required package is FOUNDRY_ERR_REFUSED, and enabling an
     * id that no installed package or profile has ever named is FOUNDRY_ERR_NOT_FOUND. */
    FoundryResult (*mods_set_enabled)(FoundryContentId id, FoundryBool enabled);
    /* Moves an enabled package to index `to` of the player's list, clamped to its end. Any
     * index is accepted: `pending_position` shows where dependencies let it land.
     * FOUNDRY_ERR_NOT_FOUND when the player has not enabled it. */
    FoundryResult (*mods_move)(FoundryContentId id, uint32_t to);
    /* Discards every pending change, the pending profile included. */
    FoundryResult (*mods_revert)(void);
    /* Writes the pending selection into the pending profile and makes it the one the next
     * start uses. FOUNDRY_ERR_UNAVAILABLE when the host keeps no profiles.
     * FOUNDRY_ERR_INTERNAL when the profile was written but the host could not record that
     * the next start should use it. */
    FoundryResult (*mods_apply)(void);
    /* Profiles. A name is 1 to 64 bytes of UTF-8 without control characters, or
     * FOUNDRY_ERR_INVALID_ARGUMENT. Create and copy write at once, under the smallest
     * unused key, select nothing, and answer FOUNDRY_ERR_LIMIT past 64 profiles. A copy of
     * the pending profile includes its unapplied changes. */
    FoundryResult (*mods_profile_create)(FoundryStr name, uint32_t *out);
    FoundryResult (*mods_profile_copy)(uint32_t source, FoundryStr name, uint32_t *out);
    /* Written at once. */
    FoundryResult (*mods_profile_rename)(uint32_t key, FoundryStr name);
    /* FOUNDRY_ERR_REFUSED for the saved or the pending profile, so the last one never goes. */
    FoundryResult (*mods_profile_delete)(uint32_t key);
    /* Makes `key` the pending profile and its list the pending list, dropping unapplied
     * changes. FOUNDRY_ERR_REFUSED for a profile whose file cannot be used. */
    FoundryResult (*mods_profile_select)(uint32_t key);

    /* -- Content themes and the game widget set (v3) ------------------------------------ */

    /*
     * A theme is content: a `foundry:ui_theme` record naming an atlas, a font, sizes,
     * colours, nine-slice patches and named icons. Any package may override it.
     *
     * Resolving one returns a handle the host owns, with the theme's textures held. There is
     * no release: the host keeps up to 16 at once and lets them all go when
     * `content_generation` moves, after which each handle is FOUNDRY_ERR_INVALID_HANDLE and
     * the theme stack is emptied. Resolve again then; the same id returns the same handle
     * until it does.
     *
     * FOUNDRY_ERR_NOT_FOUND for an id no package provides, and FOUNDRY_ERR_REFUSED for a
     * record of another schema or a theme whose fields fail validation, which the host's log
     * names. FOUNDRY_ERR_REFUSED inside a frame.
     */
    FoundryResult (*ui_theme_resolve)(FoundryContentId id, FoundryTheme *out);
    /* Makes a theme's style and skin the context's for the frames that follow, up to 8
     * deep; `ui_theme_pop` restores what was there. **Only between frames**: one frame is
     * drawn with one font and one atlas, so both answer FOUNDRY_ERR_REFUSED inside one. */
    FoundryResult (*ui_theme_push)(FoundryTheme theme);
    FoundryResult (*ui_theme_pop)(void);
    /* Everything described inside is drawn faded and takes no hover, press or focus, while
     * still keeping the pointer from reaching the game. Nests. `ui_end` closes any left
     * open and answers FOUNDRY_ERR_REFUSED. */
    FoundryResult (*ui_begin_disabled)(void);
    FoundryResult (*ui_end_disabled)(void);
    /* The part of the current region not yet used: `x` and `y` are where the next widget
     * goes. How a caller finds where the rows of a reorder list begin. */
    FoundryResult (*ui_region_remaining)(FoundryUiRect *out);
    /* A row of tabs. `*selected` is the tab drawn selected on the way in, below `count`, and
     * the one to draw next frame on the way out. At most 256. A tab's identity is `id` and
     * its index, never its label. */
    FoundryResult (*ui_tabs)(FoundryUiId id, const FoundryStr *labels, uint32_t count,
                             uint32_t *selected);
    /* A full-width row that knows whether it is selected. `*clicked` on a completed click. */
    FoundryResult (*ui_selectable)(FoundryUiId id, FoundryStr text, FoundryBool selected,
                                   FoundryBool *clicked);
    /* Reorder grips over `count` rows the caller has already described in a vertical
     * region, each one line high and separated by the style's spacing. `bounds` covers them
     * all, from where the first began. Dragging a grip draws an insertion line, may leave the
     * list, and completes a move on release. */
    FoundryResult (*ui_reorder_list)(FoundryUiId id, const FoundryUiRect *bounds,
                                     uint32_t count, FoundryUiReorderMove *out);
    /* A button that moves row `index` of `count` one way. It draws disabled, and never
     * completes a move, when that move is impossible. */
    FoundryResult (*ui_reorder_button)(FoundryUiId id, FoundryStr text, uint32_t index,
                                       uint32_t count, FoundryUiReorderDirection direction,
                                       FoundryUiReorderMove *out);
    /* The pushed theme's icon called `name`, drawn at `size`. `*found` is false for a name
     * the theme lacks, and the space is kept anyway, so an absent optional icon moves no
     * column after it. Both icon and image answer FOUNDRY_ERR_REFUSED in a frame with no
     * theme pushed around it: an atlas is only ever the pushed theme's. */
    FoundryResult (*ui_icon)(FoundryStr name, FoundryUiVec2 size, FoundryUiColor tint,
                             FoundryBool *found);
    /* A region of the pushed theme's atlas, drawn at `size`. */
    FoundryResult (*ui_image)(const FoundryUiImageSource *source, FoundryUiVec2 size,
                              FoundryUiColor tint);

    /* -- Authoring: workspaces (v4, ADR-0042) ------------------------------------------ */

    /* The workspaces this host granted, in a stable order. Nothing here opens one: a
     * workspace is a directory the application decided to grant, and a client that could
     * name a path would be a client with a private path into the filesystem. */
    FoundryResult (*author_workspace_next)(FoundryCursor *cursor, FoundryWorkspace *out);
    FoundryResult (*author_workspace_info)(FoundryWorkspace workspace,
                                           FoundryAuthorWorkspaceInfo *out);
    FoundryResult (*author_workspace_revision)(FoundryWorkspace workspace, uint64_t *out);
    /* The bounds this workspace was configured with, so a FOUNDRY_ERR_LIMIT can be
     * explained rather than guessed at. */
    FoundryResult (*author_workspace_limits)(FoundryWorkspace workspace,
                                             FoundryAuthorLimits *out);

    /* -- Authoring: documents ---------------------------------------------------------- */

    FoundryResult (*author_document_next)(FoundryWorkspace workspace, FoundryCursor *cursor,
                                          FoundryDocument *out);
    FoundryResult (*author_document_info)(FoundryDocument document,
                                          FoundryAuthorDocumentInfo *out);
    /* A new `.fdt` file, named relative to the package root, in a directory that already
     * exists. It lives in memory until a save publishes it. */
    FoundryResult (*author_document_create)(FoundryWorkspace workspace,
                                            uint64_t expected_revision, FoundryStr path,
                                            FoundryDocument *out);
    /* Adopt the bytes on disk. Refused while the draft is dirty: discard first, which is a
     * separate deliberate action. Both answer FOUNDRY_OK with the unchanged revision when
     * there was nothing to do. */
    FoundryResult (*author_document_refresh)(FoundryDocument document,
                                             uint64_t expected_revision, uint64_t *revision);
    /* Restore the last saved baseline and clear the history, as one revisioned action. */
    FoundryResult (*author_document_discard)(FoundryDocument document,
                                             uint64_t expected_revision, uint64_t *revision);
    FoundryResult (*author_document_copy_source)(FoundryDocument document, uint8_t *buffer,
                                                 uint64_t capacity, uint64_t *needed);

    /* -- Authoring: the schema tree ---------------------------------------------------- */

    /* Every schema an author may write in this package, by the spelling that goes in the
     * file: the engine's own, every dependency's, and every one this package declares. */
    FoundryResult (*author_schema_next)(FoundryWorkspace workspace, FoundryCursor *cursor,
                                        FoundrySchemaNode *out);
    FoundryResult (*author_schema_find)(FoundryWorkspace workspace, FoundryStr name,
                                        FoundrySchemaNode *out);
    FoundryResult (*author_schema_node_info)(FoundrySchemaNode node,
                                             FoundryAuthorSchemaNodeInfo *out);
    /* One field of a schema or of a nested block, or — for a list — its element type,
     * which is its one child. */
    FoundryResult (*author_schema_node_child)(FoundrySchemaNode node, uint32_t index,
                                              FoundrySchemaNode *out);
    /* The declared default as a traversable value, or FOUNDRY_ERR_NOT_FOUND. */
    FoundryResult (*author_schema_node_default)(FoundrySchemaNode node,
                                                FoundrySourceNode *out);

    /* -- Authoring: the source, dependency and preview trees --------------------------- */

    /* The record definitions written in this document. An imported record belongs to the
     * file it was written in and is walked there. */
    FoundryResult (*author_record_next)(FoundryDocument document, FoundryCursor *cursor,
                                        FoundrySourceNode *out);
    FoundryResult (*author_dependency_next)(FoundryWorkspace workspace, FoundryCursor *cursor,
                                            FoundryAuthorPackageInfo *out);
    FoundryResult (*author_dependency_record_next)(FoundryWorkspace workspace,
                                                   uint32_t package, FoundryCursor *cursor,
                                                   FoundrySourceNode *out);
    /* The records the last preview activation published, read through the same node calls
     * as a draft. FOUNDRY_ERR_UNAVAILABLE without a preview grant, FOUNDRY_ERR_NOT_FOUND
     * before anything has been activated. */
    FoundryResult (*author_preview_record_next)(FoundryWorkspace workspace,
                                                FoundryCursor *cursor,
                                                FoundrySourceNode *out);
    FoundryResult (*author_node_info)(FoundrySourceNode node, FoundryAuthorNodeInfo *out);
    FoundryResult (*author_node_child)(FoundrySourceNode node, uint32_t index,
                                       FoundrySourceNode *out);
    FoundryResult (*author_node_field)(FoundrySourceNode node, FoundryStr name,
                                       FoundrySourceNode *out);
    /* The exact value, as text plus its declared type. FOUNDRY_ERR_UNSUPPORTED for a
     * container, which `author_node_info` already describes. */
    FoundryResult (*author_node_scalar)(FoundrySourceNode node, FoundryAuthorValue *out);
    /* The same text, into the caller's buffer: what to use rather than keeping a borrow. */
    FoundryResult (*author_node_copy_text)(FoundrySourceNode node, uint8_t *buffer,
                                           uint64_t capacity, uint64_t *needed);

    /* -- Authoring: commands ----------------------------------------------------------- */

    /*
     * Every command carries the revision the caller believes it is editing, and a stale one
     * is FOUNDRY_ERR_REFUSED with nothing changed. Each is atomic in memory: a failure
     * leaves the old bytes, the old revision and the whole history intact.
     *
     * Each also invalidates **every** outstanding node handle, including ones it did not
     * touch, because a node is a position in a parse and the command replaced the parse.
     */
    FoundryResult (*author_record_create)(FoundryDocument document, uint64_t expected_revision,
                                          FoundryStr schema, FoundryStr id,
                                          FoundryAuthorEdit *out);
    FoundryResult (*author_record_duplicate)(FoundrySourceNode record,
                                             FoundryDocument destination,
                                             uint64_t expected_revision, FoundryStr id,
                                             FoundryAuthorEdit *out);
    /* A whole-record override of a read-only dependency definition, copied exactly. A
     * future upstream field is not merged into it later; the client says so. */
    FoundryResult (*author_record_override)(FoundrySourceNode dependency_record,
                                            FoundryDocument destination,
                                            uint64_t expected_revision,
                                            FoundryAuthorEdit *out);
    FoundryResult (*author_record_delete)(FoundrySourceNode record, uint64_t expected_revision,
                                          FoundryAuthorEdit *out);
    FoundryResult (*author_value_set)(FoundrySourceNode node, uint64_t expected_revision,
                                      const FoundryAuthorValue *value, FoundryAuthorEdit *out);
    FoundryResult (*author_value_unset)(FoundrySourceNode node, uint64_t expected_revision,
                                        FoundryAuthorEdit *out);
    FoundryResult (*author_list_insert)(FoundrySourceNode list, uint64_t expected_revision,
                                        uint32_t index, const FoundryAuthorValue *value,
                                        FoundryAuthorEdit *out);
    FoundryResult (*author_list_remove)(FoundrySourceNode list, uint64_t expected_revision,
                                        uint32_t index, FoundryAuthorEdit *out);
    FoundryResult (*author_list_move)(FoundrySourceNode list, uint64_t expected_revision,
                                      uint32_t from, uint32_t to, FoundryAuthorEdit *out);
    FoundryResult (*author_undo)(FoundryWorkspace workspace, uint64_t expected_revision,
                                 FoundryAuthorEdit *out);
    FoundryResult (*author_redo)(FoundryWorkspace workspace, uint64_t expected_revision,
                                 FoundryAuthorEdit *out);

    /* -- Authoring: persistence -------------------------------------------------------- */

    /* One file, published atomically. `durable` and `outcome` are separate answers: a
     * publication that succeeded with weaker crash durability is not a failure. */
    FoundryResult (*author_save_document)(FoundryDocument document, uint64_t expected_revision,
                                          FoundryAuthorSaveResult *out);
    /* Every dirty file, in stable relative-name order, stopping at the first failure. */
    FoundryResult (*author_save_all)(FoundryWorkspace workspace, uint64_t expected_revision,
                                     FoundryAuthorSaveAll *out);
    /* What the last save-all did, file by file. */
    FoundryResult (*author_save_entry_next)(FoundryWorkspace workspace, FoundryCursor *cursor,
                                            FoundryAuthorSaveEntry *out);

    /* -- Authoring: diagnostics -------------------------------------------------------- */

    /* Compile the current drafts without keeping anything. The diagnostics are the answer;
     * the result code says only whether the attempt could be made. */
    FoundryResult (*author_validate)(FoundryWorkspace workspace, uint64_t expected_revision);
    /* The last operation's diagnostic snapshot, readable until the next operation replaces
     * it. Nothing here requires scraping a log. */
    FoundryResult (*author_diagnostic_next)(FoundryWorkspace workspace, FoundryCursor *cursor,
                                            FoundryAuthorDiagnostic *out);

    /* -- Authoring: products ----------------------------------------------------------- */

    /* Compile the **saved** bytes into a private candidate. Refused while any document is
     * dirty or has changed on disk. A successful build is kept until it is released. */
    FoundryResult (*author_build)(FoundryWorkspace workspace, uint64_t expected_revision,
                                  FoundryBuild *out);
    FoundryResult (*author_build_info)(FoundryBuild build, FoundryAuthorBuildInfo *out);
    /* Refused while a preview is holding this build: releasing deletes the files the
     * loaded content is reading. */
    FoundryResult (*author_build_release)(FoundryBuild build);
    FoundryResult (*author_export_next)(FoundryWorkspace workspace, FoundryCursor *cursor,
                                        FoundryAuthorExportInfo *out);
    /* Write a build to one of the destinations the host configured, by its number. Files
     * are replaced one at a time and `*written` says how many were, so a partial
     * publication is reported rather than implied. */
    FoundryResult (*author_build_export)(FoundryBuild build, uint32_t destination,
                                         uint32_t *written);
    /* Ask the host to make this build the loaded content. FOUNDRY_ERR_UNAVAILABLE where the
     * host granted no preview; FOUNDRY_ERR_REFUSED when it declined, in which case whatever
     * was loaded before still is. */
    FoundryResult (*author_preview_activate)(FoundryBuild build);
    FoundryResult (*author_preview_info)(FoundryWorkspace workspace,
                                         FoundryAuthorPreviewInfo *out);

    /* -- Networking: grants (v5) ------------------------------------------------------- */

    /*
     * Every call answers FOUNDRY_ERR_UNAVAILABLE where the host supplied no network service,
     * and FOUNDRY_ERR_REFUSED for a grant the host did not publish, or any handle into a
     * session on one. Pumping is the host's: nothing here waits or does network work.
     */

    /* The grants this host published, in the order it gave them. */
    FoundryResult (*net_grant_next)(FoundryCursor *cursor, FoundryNetGrantInfo *out);

    /* -- Networking: sessions ---------------------------------------------------------- */

    /* A session by grant, at most one per grant. FOUNDRY_ERR_NOT_FOUND for a grant the
     * service does not hold. */
    FoundryResult (*net_session_create)(FoundryContentId grant, FoundryNetSession *out);
    /* Ends it now: its listener, every peer and every event still queued for it. */
    FoundryResult (*net_session_close)(FoundryNetSession session);
    FoundryResult (*net_session_info)(FoundryNetSession session, FoundryNetSessionInfo *out);

    /* -- Networking: channels ---------------------------------------------------------- */

    /* While the session is configuring. Unique, bounded, and at most one latest-state
     * channel, which must run server to client. */
    FoundryResult (*net_channel_register)(FoundryNetSession session,
                                          const FoundryNetChannelDesc *desc);
    /* In registration order while configuring; in id order once frozen. */
    FoundryResult (*net_channel_next)(FoundryNetSession session, FoundryCursor *cursor,
                                      FoundryNetChannelDesc *out);

    /* -- Networking: starting ---------------------------------------------------------- */

    /* A server session listens at its grant's endpoint, freezing its channels. */
    FoundryResult (*net_session_listen)(FoundryNetSession session);
    /* A client session connects to its grant's server. It may connect again once its last
     * connection has ended, as a fresh participant. */
    FoundryResult (*net_session_connect)(FoundryNetSession session, FoundryNetPeer *out);

    /* -- Networking: peers ------------------------------------------------------------- */

    /* A session's peers in slot order. A connection added or removed during the walk makes
     * the cursor FOUNDRY_ERR_INVALID_ARGUMENT; begin again. */
    FoundryResult (*net_peer_next)(FoundryNetSession session, FoundryCursor *cursor,
                                   FoundryNetPeer *out);
    FoundryResult (*net_peer_info)(FoundryNetPeer peer, FoundryNetPeerInfo *out);
    /* `reason` is a FOUNDRY_NET_DISCONNECT_ value, told to the peer if it can still be. */
    FoundryResult (*net_peer_disconnect)(FoundryNetPeer peer, int32_t reason);

    /* -- Networking: events and statistics --------------------------------------------- */

    /* The oldest event of a published session; FOUNDRY_END when there is none. Every
     * connection's events were reserved when it could first produce them, so none is
     * dropped — and a consumer that stops reading them stops new peers being admitted. */
    FoundryResult (*net_event_next)(FoundryNetEvent *out);
    FoundryResult (*net_stats)(FoundryNetStats *out);

    /* -- Networking: initial state ----------------------------------------------------- */

    /* A server sends a synchronizing peer its one complete baseline, stamped with the tick
     * it describes, on the session's latest-state channel. Never replaced. */
    FoundryResult (*net_baseline_send)(FoundryNetPeer peer, uint64_t tick, const void *bytes,
                                       uint32_t size);
    /* A client acknowledges the baseline it took and applied, by the sequence and tick its
     * delivery named. Only this activates the peer. */
    FoundryResult (*net_baseline_acknowledge)(FoundryNetPeer peer, uint64_t sequence,
                                              uint64_t tick);

    /* -- Networking: sending ----------------------------------------------------------- */

    /* A server publishes a peer's newest complete state, copied. It replaces one not yet
     * sent, waits behind the baseline until activation, and may not go back in ticks. */
    FoundryResult (*net_state_publish)(FoundryNetPeer peer, uint64_t tick, const void *bytes,
                                       uint32_t size);
    /* A reliable message to an active peer, copied: from a client, a command. `*number`
     * counts from 1 on this connection. FOUNDRY_ERR_LIMIT when the queue is full; an
     * accepted message is never dropped, and is not proof the other side applied it. */
    FoundryResult (*net_command_send)(FoundryNetPeer peer, FoundryContentId channel,
                                      const void *bytes, uint32_t size, uint64_t *number);

    /* -- Networking: receiving --------------------------------------------------------- */

    /* What a client would take next, or FOUNDRY_END. FOUNDRY_ERR_REFUSED on a server,
     * whose commands arrive only as admitted batches. */
    FoundryResult (*net_delivery_next)(FoundryNetPeer peer, FoundryNetDelivery *out);
    /* Takes it, copying its payload. `*needed` is always set; a short buffer is
     * FOUNDRY_ERR_LIMIT and takes nothing. */
    FoundryResult (*net_delivery_take)(FoundryNetPeer peer, uint8_t *buffer, uint64_t capacity,
                                       uint64_t *needed, FoundryNetDelivery *out);

    /* -- Networking: admission --------------------------------------------------------- */

    /* Freezes a server session's commands for `tick`, which strictly increases, replacing
     * the previous batch: at most the per-peer budget from each active peer, ordered by
     * participant and then number. What is left waits for a later tick. */
    FoundryResult (*net_batch_admit)(FoundryNetSession session, uint64_t tick, uint32_t *count);
    FoundryResult (*net_batch_command)(FoundryNetSession session, uint32_t index,
                                       FoundryNetCommand *out);
    FoundryResult (*net_batch_copy)(FoundryNetSession session, uint32_t index, uint8_t *buffer,
                                    uint64_t capacity, uint64_t *needed);
} FoundryApi_v5;



/* == The entry point =================================================================== */

/*
 * A native mod exports one required symbol and one optional one. **These signatures can
 * never change**, because every mod ever compiled is baked against them, so the whole of the
 * versioning problem has to be solvable without touching them.
 *
 * It is, and the indirection is why: `get_api` lets one host offer every version it still
 * supports while one mod asks for the newest it understands.
 *
 *     FOUNDRY_EXPORT FoundryResult foundry_mod_init(FoundryGetApi get_api, FoundryMod self)
 *     {
 *         const FoundryApi_v1 *api = (const FoundryApi_v1 *)get_api(FOUNDRY_API_VERSION_1);
 *         if (api == NULL) return FOUNDRY_ERR_UNSUPPORTED;
 *         ...
 *         return FOUNDRY_OK;
 *     }
 *
 * A mod that spans two engine generations asks for 2, falls back to 1, and ships one binary.
 * A host that has dropped v1 returns NULL and the mod refuses itself with a message naming
 * the version it wanted, which is the failure this costs one indirection to buy.
 */

/* Returns a `const FoundryApi_vN *`, or NULL if this host does not offer version N. */
typedef const void *(*FoundryGetApi)(uint32_t version);

/*
 * Called once, after the mod's content is merged and before the first frame. A result other
 * than FOUNDRY_OK means the mod declined to load: it is logged with the code's name, the mod
 * is skipped, and the engine carries on. Nothing else is called on a mod that refused.
 */
FOUNDRY_EXPORT FoundryResult foundry_mod_init(FoundryGetApi get_api, FoundryMod self);

/*
 * Optional. Resolved if present and called in reverse load order at teardown; a mod that
 * allocates nothing owes nothing and need not define it.
 */
FOUNDRY_EXPORT void foundry_mod_shutdown(FoundryMod self);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* FOUNDRY_H */
