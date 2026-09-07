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
 * WHAT IS HERE YET: the type layer, which is step 2 of public-abi.md §19. The table itself —
 * `FoundryApi_v1`, the capabilities a mod calls — is step 3 and is not in this file. What is
 * here is already frozen: once a compiled mod exists, a type that crosses this boundary can
 * never change its layout.
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

/* The newest version this header describes. */
#define FOUNDRY_API_VERSION FOUNDRY_API_VERSION_1

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
