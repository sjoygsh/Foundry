/*
 * The header, checked.
 *
 * `foundry.h` is hand-written, which makes it a specification rather than a description
 * (public-abi.md §16) — and makes "the engine still matches it" a claim somebody has to
 * check. This file is what checks it, on every target `zig build test` and `zig build check`
 * build for, so a header edited on one machine fails on that machine rather than on a mod
 * author's.
 *
 * Three things happen here, and only the first is obvious:
 *
 *   1. Every size and every offset is asserted against the number the specification states.
 *      `agreement.zig` asserts the same numbers from the engine's side, so the two languages
 *      agree by each agreeing with the contract rather than by describing each other.
 *
 *   2. The header is compiled `-std=c99 -pedantic -Werror` with nothing else in the
 *      translation unit, which is what turns "C99, no dependencies" from an intention into
 *      a checked claim. It is also included twice, which checks the include guard.
 *
 *   3. A handful of tiny functions let `agreement.zig` push a value *through* the boundary
 *      and read it back. Matching numbers prove the layouts are the same shape; these prove
 *      a `FoundryStr` built in Zig arrives in C as the bytes it was, which is the claim that
 *      actually matters and the one no static assertion can make.
 *
 * Nothing here is called outside the test suite, so a linked game drops all of it.
 */

#include "foundry.h"
#include "foundry.h"

#include <stddef.h>

/*
 * C99 has no `_Static_assert` — that is C11 — and the header claims C99, so the check has to
 * live in the language the header claims. A negative array bound is the oldest trick there
 * is, and it fails at compile time with the line number, which is all that is wanted.
 */
#define FOUNDRY_CAT_(a, b) a##b
#define FOUNDRY_CAT(a, b) FOUNDRY_CAT_(a, b)
#define FOUNDRY_AGREE(cond) \
    typedef char FOUNDRY_CAT(foundry_agreement_line_, __LINE__)[(cond) ? 1 : -1]

/* -- Scalars ------------------------------------------------------------------------- */

FOUNDRY_AGREE(sizeof(FoundryResult) == 4);
FOUNDRY_AGREE(sizeof(FoundryBool) == 1);
FOUNDRY_AGREE((FoundryResult)-1 < (FoundryResult)0); /* signed, or the split in §6 fails */

FOUNDRY_AGREE(FOUNDRY_OK == 0);
FOUNDRY_AGREE(FOUNDRY_END == 1);
FOUNDRY_AGREE(FOUNDRY_ERR_INVALID_ARGUMENT == -1);
FOUNDRY_AGREE(FOUNDRY_ERR_INVALID_HANDLE == -2);
FOUNDRY_AGREE(FOUNDRY_ERR_NOT_FOUND == -3);
FOUNDRY_AGREE(FOUNDRY_ERR_UNAVAILABLE == -4);
FOUNDRY_AGREE(FOUNDRY_ERR_UNSUPPORTED == -5);
FOUNDRY_AGREE(FOUNDRY_ERR_ALREADY_EXISTS == -6);
FOUNDRY_AGREE(FOUNDRY_ERR_LIMIT == -7);
FOUNDRY_AGREE(FOUNDRY_ERR_REFUSED == -8);
FOUNDRY_AGREE(FOUNDRY_ERR_OUT_OF_MEMORY == -9);
FOUNDRY_AGREE(FOUNDRY_ERR_INTERNAL == -10);

FOUNDRY_AGREE(FOUNDRY_API_VERSION_1 == 1);
FOUNDRY_AGREE(FOUNDRY_API_VERSION == FOUNDRY_API_VERSION_1);

/* -- Strings ------------------------------------------------------------------------- */

FOUNDRY_AGREE(sizeof(FoundryStr) == 16);
FOUNDRY_AGREE(offsetof(FoundryStr, ptr) == 0);
FOUNDRY_AGREE(offsetof(FoundryStr, len) == 8);

/* And the width of each member, which a size and an offset do not pin down: a `uint32_t len`
 * in a struct that pads back out to sixteen bytes satisfies both of the lines above and is
 * still a different ABI. Found by breaking the header on purpose to check that breaking it
 * fails the build. */
FOUNDRY_AGREE(sizeof(((FoundryStr *)0)->ptr) == 8);
FOUNDRY_AGREE(sizeof(((FoundryStr *)0)->len) == 8);

/* The only type here with padding to get wrong, so its alignment is stated too. C99 has no
 * `_Alignof` either; where the member lands after a `char` is the same question. */
struct foundry_agreement_str_align {
    char c;
    FoundryStr s;
};
FOUNDRY_AGREE(offsetof(struct foundry_agreement_str_align, s) == 8);

/* -- Content identity ---------------------------------------------------------------- */

FOUNDRY_AGREE(sizeof(FoundryContentId) == 8);
FOUNDRY_AGREE(offsetof(FoundryContentId, hash) == 0);
FOUNDRY_AGREE(sizeof(((FoundryContentId *)0)->hash) == 8);

/* -- Handles ------------------------------------------------------------------------- */

/* Every kind, individually, because "they are all the same shape" is exactly the claim. */
FOUNDRY_AGREE(sizeof(FoundryMod) == 8);
FOUNDRY_AGREE(sizeof(FoundryPackage) == 8);
FOUNDRY_AGREE(sizeof(FoundrySchema) == 8);
FOUNDRY_AGREE(sizeof(FoundryRecord) == 8);
FOUNDRY_AGREE(sizeof(FoundryAsset) == 8);
FOUNDRY_AGREE(sizeof(FoundryEntity) == 8);
FOUNDRY_AGREE(sizeof(FoundryComponentType) == 8);
FOUNDRY_AGREE(sizeof(FoundryTexture) == 8);
FOUNDRY_AGREE(sizeof(FoundryView) == 8);
FOUNDRY_AGREE(sizeof(FoundryVoice) == 8);
FOUNDRY_AGREE(sizeof(FoundryBody) == 8);

FOUNDRY_AGREE(offsetof(FoundryMod, bits) == 0);
FOUNDRY_AGREE(offsetof(FoundryEntity, bits) == 0);
FOUNDRY_AGREE(offsetof(FoundryVoice, bits) == 0);
FOUNDRY_AGREE(sizeof(((FoundryEntity *)0)->bits) == 8);

/* -- Cursors ------------------------------------------------------------------------- */

FOUNDRY_AGREE(sizeof(FoundryCursor) == 8);
FOUNDRY_AGREE(offsetof(FoundryCursor, bits) == 0);
FOUNDRY_AGREE(sizeof(((FoundryCursor *)0)->bits) == 8);

/* -- Values pushed through the boundary ---------------------------------------------- */

/*
 * The header's own hash, called from Zig and compared against the engine's. These are two
 * separate implementations of FNV-1a — one written for a mod author to copy, one the content
 * compiler actually hashes with — and nothing but this stops them drifting.
 */
uint64_t foundry_agreement_content_id(const void *bytes, size_t len);
uint64_t foundry_agreement_content_id(const void *bytes, size_t len)
{
    return foundry_content_id(bytes, len).hash;
}

/* A `FoundryStr` built in Zig, read in C. */
uint64_t foundry_agreement_str_len(FoundryStr s);
uint64_t foundry_agreement_str_len(FoundryStr s)
{
    return s.len;
}

uint8_t foundry_agreement_str_byte(FoundryStr s, uint64_t index);
uint8_t foundry_agreement_str_byte(FoundryStr s, uint64_t index)
{
    return s.ptr[index];
}

/* A handle, both ways, by value — which is also a check of the calling convention for an
 * eight-byte struct, since that is how every handle in the table is passed. */
uint64_t foundry_agreement_entity_bits(FoundryEntity entity);
uint64_t foundry_agreement_entity_bits(FoundryEntity entity)
{
    return entity.bits;
}

FoundryEntity foundry_agreement_entity_from_bits(uint64_t bits);
FoundryEntity foundry_agreement_entity_from_bits(uint64_t bits)
{
    FoundryEntity entity;
    entity.bits = bits;
    return entity;
}

/* What the initialiser in the header actually produces, rather than what it looks like. */
FoundryCursor foundry_agreement_cursor_begin(void);
FoundryCursor foundry_agreement_cursor_begin(void)
{
    FoundryCursor cursor = FOUNDRY_CURSOR_BEGIN;
    return cursor;
}
