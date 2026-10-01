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
FOUNDRY_AGREE(FOUNDRY_API_VERSION_2 == 2);
FOUNDRY_AGREE(FOUNDRY_API_VERSION_3 == 3);
FOUNDRY_AGREE(FOUNDRY_API_VERSION_4 == 4);
FOUNDRY_AGREE(FOUNDRY_API_VERSION_5 == 5);
FOUNDRY_AGREE(FOUNDRY_API_VERSION_6 == 6);
FOUNDRY_AGREE(FOUNDRY_API_VERSION == FOUNDRY_API_VERSION_6);

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
FOUNDRY_AGREE(sizeof(FoundryGrid) == 8);
FOUNDRY_AGREE(sizeof(FoundryTheme) == 8);

FOUNDRY_AGREE(offsetof(FoundryMod, bits) == 0);
FOUNDRY_AGREE(offsetof(FoundryEntity, bits) == 0);
FOUNDRY_AGREE(offsetof(FoundryVoice, bits) == 0);
FOUNDRY_AGREE(offsetof(FoundryGrid, bits) == 0);
FOUNDRY_AGREE(sizeof(((FoundryEntity *)0)->bits) == 8);
FOUNDRY_AGREE(sizeof(((FoundryGrid *)0)->bits) == 8);

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

/* -- Enumerations -------------------------------------------------------------------- */

FOUNDRY_AGREE(sizeof(FoundryLogLevel) == 4);
FOUNDRY_AGREE(FOUNDRY_LOG_ERROR == 0);
FOUNDRY_AGREE(FOUNDRY_LOG_WARN == 1);
FOUNDRY_AGREE(FOUNDRY_LOG_INFO == 2);
FOUNDRY_AGREE(FOUNDRY_LOG_DEBUG == 3);
FOUNDRY_AGREE(FOUNDRY_LOG_TRACE == 4);

FOUNDRY_AGREE(sizeof(FoundryFieldType) == 4);
FOUNDRY_AGREE(FOUNDRY_FIELD_BOOL == 0);
FOUNDRY_AGREE(FOUNDRY_FIELD_I32 == 1);
FOUNDRY_AGREE(FOUNDRY_FIELD_I64 == 2);
FOUNDRY_AGREE(FOUNDRY_FIELD_U32 == 3);
FOUNDRY_AGREE(FOUNDRY_FIELD_U64 == 4);
FOUNDRY_AGREE(FOUNDRY_FIELD_F32 == 5);
FOUNDRY_AGREE(FOUNDRY_FIELD_F64 == 6);
FOUNDRY_AGREE(FOUNDRY_FIELD_STRING == 7);
FOUNDRY_AGREE(FOUNDRY_FIELD_ID == 8);
FOUNDRY_AGREE(FOUNDRY_FIELD_LIST == 9);
FOUNDRY_AGREE(FOUNDRY_FIELD_NESTED == 10);
FOUNDRY_AGREE(sizeof(FoundryModOrigin) == 4);
FOUNDRY_AGREE(FOUNDRY_MOD_ORIGIN_INSTALLED == 0);
FOUNDRY_AGREE(FOUNDRY_MOD_ORIGIN_USER == 1);
FOUNDRY_AGREE(sizeof(FoundryModSkipReason) == 4);
FOUNDRY_AGREE(FOUNDRY_MOD_SKIP_NONE == 0);
FOUNDRY_AGREE(FOUNDRY_MOD_SKIP_NOT_INSTALLED == 1);
FOUNDRY_AGREE(FOUNDRY_MOD_SKIP_MISSING_DEPENDENCY == 2);
FOUNDRY_AGREE(FOUNDRY_MOD_SKIP_DEPENDENCY_VERSION == 3);
FOUNDRY_AGREE(FOUNDRY_MOD_SKIP_DEPENDENCY_SKIPPED == 4);
FOUNDRY_AGREE(FOUNDRY_MOD_SKIP_CYCLE == 5);
FOUNDRY_AGREE(FOUNDRY_MOD_SKIP_DUPLICATE == 6);
FOUNDRY_AGREE(FOUNDRY_MOD_SKIP_SHADOWS_INSTALLED == 7);
FOUNDRY_AGREE(sizeof(FoundryModProfileProblem) == 4);
FOUNDRY_AGREE(FOUNDRY_MOD_PROFILE_OK == 0);
FOUNDRY_AGREE(FOUNDRY_MOD_PROFILE_DAMAGED == 1);
FOUNDRY_AGREE(FOUNDRY_MOD_PROFILE_OTHER_BUILD == 2);
FOUNDRY_AGREE(FOUNDRY_MOD_PROFILE_REFUSED == 3);
FOUNDRY_AGREE(FOUNDRY_MOD_PROFILE_UNAVAILABLE == 4);
FOUNDRY_AGREE(FOUNDRY_MOD_REQUIRED == 1u);
FOUNDRY_AGREE(FOUNDRY_MOD_NATIVE == 2u);
FOUNDRY_AGREE(FOUNDRY_MOD_SCRIPT == 4u);
FOUNDRY_AGREE(FOUNDRY_MOD_DUPLICATE == 8u);
FOUNDRY_AGREE(FOUNDRY_MOD_ENVIRONMENT == 16u);
FOUNDRY_AGREE(FOUNDRY_MOD_UNREADABLE == 32u);
FOUNDRY_AGREE(FOUNDRY_MOD_NO_POSITION == 0xffffffffu);
FOUNDRY_AGREE(sizeof(FoundryUiReorderDirection) == 4);
FOUNDRY_AGREE(FOUNDRY_UI_REORDER_UP == 0);
FOUNDRY_AGREE(FOUNDRY_UI_REORDER_DOWN == 1);
FOUNDRY_AGREE(FOUNDRY_UI_REORDER_TOP == 2);
FOUNDRY_AGREE(FOUNDRY_UI_REORDER_BOTTOM == 3);

/* -- Structs that cross -------------------------------------------------------------- */

FOUNDRY_AGREE(sizeof(FoundryMemoryCounter) == 8);
FOUNDRY_AGREE(offsetof(FoundryMemoryCounter, bits) == 0);

FOUNDRY_AGREE(sizeof(FoundryLogRecord) == 56);
FOUNDRY_AGREE(offsetof(FoundryLogRecord, level) == 0);
FOUNDRY_AGREE(offsetof(FoundryLogRecord, reserved) == 4);
FOUNDRY_AGREE(offsetof(FoundryLogRecord, frame) == 8);
FOUNDRY_AGREE(offsetof(FoundryLogRecord, sequence) == 16);
FOUNDRY_AGREE(offsetof(FoundryLogRecord, scope) == 24);
FOUNDRY_AGREE(offsetof(FoundryLogRecord, text) == 40);

FOUNDRY_AGREE(sizeof(FoundryMemoryStats) == 40);
FOUNDRY_AGREE(offsetof(FoundryMemoryStats, live_bytes) == 0);
FOUNDRY_AGREE(offsetof(FoundryMemoryStats, peak_bytes) == 8);
FOUNDRY_AGREE(offsetof(FoundryMemoryStats, allocations) == 16);
FOUNDRY_AGREE(offsetof(FoundryMemoryStats, frees) == 24);
FOUNDRY_AGREE(offsetof(FoundryMemoryStats, failures) == 32);

/* Widths as well as offsets, for the reason step 2 found the hard way: padding hides a
 * narrowed member from every offset around it. `alignment` is the live example — narrow it
 * and nothing after it moves, because `ctx` is eight-aligned and the padding absorbs it. */
FOUNDRY_AGREE(sizeof(FoundryStep) == 16);
FOUNDRY_AGREE(offsetof(FoundryStep, tick) == 0);
FOUNDRY_AGREE(offsetof(FoundryStep, delta_ns) == 8);
FOUNDRY_AGREE(sizeof(((FoundryStep *)0)->tick) == 8);
FOUNDRY_AGREE(sizeof(((FoundryStep *)0)->delta_ns) == 8);

FOUNDRY_AGREE(sizeof(FoundryComponentDesc) == 56);
FOUNDRY_AGREE(offsetof(FoundryComponentDesc, schema) == 0);
FOUNDRY_AGREE(offsetof(FoundryComponentDesc, name) == 8);
FOUNDRY_AGREE(offsetof(FoundryComponentDesc, size) == 24);
FOUNDRY_AGREE(offsetof(FoundryComponentDesc, alignment) == 28);
FOUNDRY_AGREE(offsetof(FoundryComponentDesc, ctx) == 32);
FOUNDRY_AGREE(offsetof(FoundryComponentDesc, construct) == 40);
FOUNDRY_AGREE(offsetof(FoundryComponentDesc, destruct) == 48);
FOUNDRY_AGREE(sizeof(((FoundryComponentDesc *)0)->schema) == 8);
FOUNDRY_AGREE(sizeof(((FoundryComponentDesc *)0)->name) == 16);
FOUNDRY_AGREE(sizeof(((FoundryComponentDesc *)0)->size) == 4);
FOUNDRY_AGREE(sizeof(((FoundryComponentDesc *)0)->alignment) == 4);
FOUNDRY_AGREE(sizeof(((FoundryComponentDesc *)0)->ctx) == 8);
FOUNDRY_AGREE(sizeof(((FoundryComponentDesc *)0)->construct) == 8);
FOUNDRY_AGREE(sizeof(((FoundryComponentDesc *)0)->destruct) == 8);

FOUNDRY_AGREE(sizeof(FoundrySystemDesc) == 40);
FOUNDRY_AGREE(offsetof(FoundrySystemDesc, id) == 0);
FOUNDRY_AGREE(offsetof(FoundrySystemDesc, name) == 8);
FOUNDRY_AGREE(offsetof(FoundrySystemDesc, ctx) == 24);
FOUNDRY_AGREE(offsetof(FoundrySystemDesc, update) == 32);
FOUNDRY_AGREE(sizeof(((FoundrySystemDesc *)0)->id) == 8);
FOUNDRY_AGREE(sizeof(((FoundrySystemDesc *)0)->name) == 16);
FOUNDRY_AGREE(sizeof(((FoundrySystemDesc *)0)->ctx) == 8);
FOUNDRY_AGREE(sizeof(((FoundrySystemDesc *)0)->update) == 8);

/* -- Render2d values ----------------------------------------------------------------- */

FOUNDRY_AGREE(sizeof(FoundryRenderVec2) == 8);
FOUNDRY_AGREE(offsetof(FoundryRenderVec2, x) == 0);
FOUNDRY_AGREE(offsetof(FoundryRenderVec2, y) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderVec2 *)0)->x) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderVec2 *)0)->y) == 4);

FOUNDRY_AGREE(sizeof(FoundryRenderRect) == 16);
FOUNDRY_AGREE(offsetof(FoundryRenderRect, x) == 0);
FOUNDRY_AGREE(offsetof(FoundryRenderRect, y) == 4);
FOUNDRY_AGREE(offsetof(FoundryRenderRect, w) == 8);
FOUNDRY_AGREE(offsetof(FoundryRenderRect, h) == 12);
FOUNDRY_AGREE(sizeof(((FoundryRenderRect *)0)->x) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderRect *)0)->y) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderRect *)0)->w) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderRect *)0)->h) == 4);

FOUNDRY_AGREE(sizeof(FoundryRenderColor) == 16);
FOUNDRY_AGREE(offsetof(FoundryRenderColor, r) == 0);
FOUNDRY_AGREE(offsetof(FoundryRenderColor, g) == 4);
FOUNDRY_AGREE(offsetof(FoundryRenderColor, b) == 8);
FOUNDRY_AGREE(offsetof(FoundryRenderColor, a) == 12);
FOUNDRY_AGREE(sizeof(((FoundryRenderColor *)0)->r) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderColor *)0)->g) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderColor *)0)->b) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderColor *)0)->a) == 4);

FOUNDRY_AGREE(sizeof(FoundryRenderCamera) == 32);
FOUNDRY_AGREE(offsetof(FoundryRenderCamera, center) == 0);
FOUNDRY_AGREE(offsetof(FoundryRenderCamera, zoom) == 8);
FOUNDRY_AGREE(offsetof(FoundryRenderCamera, rotation) == 12);
FOUNDRY_AGREE(offsetof(FoundryRenderCamera, viewport) == 16);
FOUNDRY_AGREE(sizeof(((FoundryRenderCamera *)0)->center) == 8);
FOUNDRY_AGREE(sizeof(((FoundryRenderCamera *)0)->zoom) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderCamera *)0)->rotation) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderCamera *)0)->viewport) == 16);

FOUNDRY_AGREE(sizeof(FoundryRenderSprite) == 80);
FOUNDRY_AGREE(offsetof(FoundryRenderSprite, texture) == 0);
FOUNDRY_AGREE(offsetof(FoundryRenderSprite, position) == 8);
FOUNDRY_AGREE(offsetof(FoundryRenderSprite, size) == 16);
FOUNDRY_AGREE(offsetof(FoundryRenderSprite, uv) == 24);
FOUNDRY_AGREE(offsetof(FoundryRenderSprite, origin) == 40);
FOUNDRY_AGREE(offsetof(FoundryRenderSprite, rotation) == 48);
FOUNDRY_AGREE(offsetof(FoundryRenderSprite, tint) == 52);
FOUNDRY_AGREE(offsetof(FoundryRenderSprite, layer) == 68);
FOUNDRY_AGREE(offsetof(FoundryRenderSprite, reserved_layer) == 70);
FOUNDRY_AGREE(offsetof(FoundryRenderSprite, blend) == 72);
FOUNDRY_AGREE(offsetof(FoundryRenderSprite, flip_x) == 76);
FOUNDRY_AGREE(offsetof(FoundryRenderSprite, flip_y) == 77);
FOUNDRY_AGREE(offsetof(FoundryRenderSprite, reserved_flags) == 78);
FOUNDRY_AGREE(sizeof(((FoundryRenderSprite *)0)->texture) == 8);
FOUNDRY_AGREE(sizeof(((FoundryRenderSprite *)0)->position) == 8);
FOUNDRY_AGREE(sizeof(((FoundryRenderSprite *)0)->size) == 8);
FOUNDRY_AGREE(sizeof(((FoundryRenderSprite *)0)->uv) == 16);
FOUNDRY_AGREE(sizeof(((FoundryRenderSprite *)0)->origin) == 8);
FOUNDRY_AGREE(sizeof(((FoundryRenderSprite *)0)->rotation) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderSprite *)0)->tint) == 16);
FOUNDRY_AGREE(sizeof(((FoundryRenderSprite *)0)->layer) == 2);
FOUNDRY_AGREE(sizeof(((FoundryRenderSprite *)0)->reserved_layer) == 2);
FOUNDRY_AGREE(sizeof(((FoundryRenderSprite *)0)->blend) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderSprite *)0)->flip_x) == 1);
FOUNDRY_AGREE(sizeof(((FoundryRenderSprite *)0)->flip_y) == 1);
FOUNDRY_AGREE(sizeof(((FoundryRenderSprite *)0)->reserved_flags) == 2);

FOUNDRY_AGREE(sizeof(FoundryRenderFont) == 64);
FOUNDRY_AGREE(offsetof(FoundryRenderFont, texture) == 0);
FOUNDRY_AGREE(offsetof(FoundryRenderFont, uv) == 8);
FOUNDRY_AGREE(offsetof(FoundryRenderFont, width) == 24);
FOUNDRY_AGREE(offsetof(FoundryRenderFont, height) == 28);
FOUNDRY_AGREE(offsetof(FoundryRenderFont, cell_width) == 32);
FOUNDRY_AGREE(offsetof(FoundryRenderFont, cell_height) == 36);
FOUNDRY_AGREE(offsetof(FoundryRenderFont, columns) == 40);
FOUNDRY_AGREE(offsetof(FoundryRenderFont, first_codepoint) == 44);
FOUNDRY_AGREE(offsetof(FoundryRenderFont, glyph_count) == 48);
FOUNDRY_AGREE(offsetof(FoundryRenderFont, substitute) == 52);
FOUNDRY_AGREE(offsetof(FoundryRenderFont, reserved) == 56);
FOUNDRY_AGREE(sizeof(((FoundryRenderFont *)0)->texture) == 8);
FOUNDRY_AGREE(sizeof(((FoundryRenderFont *)0)->uv) == 16);
FOUNDRY_AGREE(sizeof(((FoundryRenderFont *)0)->width) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderFont *)0)->height) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderFont *)0)->cell_width) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderFont *)0)->cell_height) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderFont *)0)->columns) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderFont *)0)->first_codepoint) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderFont *)0)->glyph_count) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderFont *)0)->substitute) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderFont *)0)->reserved) == 4);

FOUNDRY_AGREE(sizeof(FoundryRenderTextOptions) == 44);
FOUNDRY_AGREE(offsetof(FoundryRenderTextOptions, position) == 0);
FOUNDRY_AGREE(offsetof(FoundryRenderTextOptions, scale) == 8);
FOUNDRY_AGREE(offsetof(FoundryRenderTextOptions, tint) == 12);
FOUNDRY_AGREE(offsetof(FoundryRenderTextOptions, layer) == 28);
FOUNDRY_AGREE(offsetof(FoundryRenderTextOptions, reserved_layer) == 30);
FOUNDRY_AGREE(offsetof(FoundryRenderTextOptions, blend) == 32);
FOUNDRY_AGREE(offsetof(FoundryRenderTextOptions, letter_spacing) == 36);
FOUNDRY_AGREE(offsetof(FoundryRenderTextOptions, line_spacing) == 40);
FOUNDRY_AGREE(sizeof(((FoundryRenderTextOptions *)0)->position) == 8);
FOUNDRY_AGREE(sizeof(((FoundryRenderTextOptions *)0)->scale) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderTextOptions *)0)->tint) == 16);
FOUNDRY_AGREE(sizeof(((FoundryRenderTextOptions *)0)->layer) == 2);
FOUNDRY_AGREE(sizeof(((FoundryRenderTextOptions *)0)->reserved_layer) == 2);
FOUNDRY_AGREE(sizeof(((FoundryRenderTextOptions *)0)->blend) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderTextOptions *)0)->letter_spacing) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderTextOptions *)0)->line_spacing) == 4);

FOUNDRY_AGREE(sizeof(FoundryRenderViewDesc) == 56);
FOUNDRY_AGREE(offsetof(FoundryRenderViewDesc, kind) == 0);
FOUNDRY_AGREE(offsetof(FoundryRenderViewDesc, reserved) == 4);
FOUNDRY_AGREE(offsetof(FoundryRenderViewDesc, camera) == 8);
FOUNDRY_AGREE(offsetof(FoundryRenderViewDesc, screen) == 40);
FOUNDRY_AGREE(sizeof(((FoundryRenderViewDesc *)0)->kind) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderViewDesc *)0)->reserved) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderViewDesc *)0)->camera) == 32);
FOUNDRY_AGREE(sizeof(((FoundryRenderViewDesc *)0)->screen) == 16);

FOUNDRY_AGREE(sizeof(FoundryRenderStats) == 40);
FOUNDRY_AGREE(offsetof(FoundryRenderStats, sprites) == 0);
FOUNDRY_AGREE(offsetof(FoundryRenderStats, glyphs) == 4);
FOUNDRY_AGREE(offsetof(FoundryRenderStats, tiles) == 8);
FOUNDRY_AGREE(offsetof(FoundryRenderStats, batches) == 12);
FOUNDRY_AGREE(offsetof(FoundryRenderStats, draw_calls) == 16);
FOUNDRY_AGREE(offsetof(FoundryRenderStats, vertices) == 20);
FOUNDRY_AGREE(offsetof(FoundryRenderStats, vertex_bytes) == 24);
FOUNDRY_AGREE(offsetof(FoundryRenderStats, buffers_used) == 28);
FOUNDRY_AGREE(offsetof(FoundryRenderStats, textures_resident) == 32);
FOUNDRY_AGREE(offsetof(FoundryRenderStats, views) == 36);
FOUNDRY_AGREE(sizeof(((FoundryRenderStats *)0)->sprites) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderStats *)0)->glyphs) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderStats *)0)->tiles) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderStats *)0)->batches) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderStats *)0)->draw_calls) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderStats *)0)->vertices) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderStats *)0)->vertex_bytes) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderStats *)0)->buffers_used) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderStats *)0)->textures_resident) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRenderStats *)0)->views) == 4);

/* -- UI values ----------------------------------------------------------------------- */

FOUNDRY_AGREE(sizeof(FoundryUiId) == 8);
FOUNDRY_AGREE(offsetof(FoundryUiId, bits) == 0);
FOUNDRY_AGREE(sizeof(((FoundryUiId *)0)->bits) == 8);

FOUNDRY_AGREE(sizeof(FoundryUiVec2) == 8);
FOUNDRY_AGREE(offsetof(FoundryUiVec2, x) == 0);
FOUNDRY_AGREE(offsetof(FoundryUiVec2, y) == 4);
FOUNDRY_AGREE(sizeof(((FoundryUiVec2 *)0)->x) == 4);
FOUNDRY_AGREE(sizeof(((FoundryUiVec2 *)0)->y) == 4);

FOUNDRY_AGREE(sizeof(FoundryUiRect) == 16);
FOUNDRY_AGREE(offsetof(FoundryUiRect, x) == 0);
FOUNDRY_AGREE(offsetof(FoundryUiRect, y) == 4);
FOUNDRY_AGREE(offsetof(FoundryUiRect, w) == 8);
FOUNDRY_AGREE(offsetof(FoundryUiRect, h) == 12);
FOUNDRY_AGREE(sizeof(((FoundryUiRect *)0)->x) == 4);
FOUNDRY_AGREE(sizeof(((FoundryUiRect *)0)->y) == 4);
FOUNDRY_AGREE(sizeof(((FoundryUiRect *)0)->w) == 4);
FOUNDRY_AGREE(sizeof(((FoundryUiRect *)0)->h) == 4);

FOUNDRY_AGREE(sizeof(FoundryUiColor) == 16);
FOUNDRY_AGREE(offsetof(FoundryUiColor, r) == 0);
FOUNDRY_AGREE(offsetof(FoundryUiColor, g) == 4);
FOUNDRY_AGREE(offsetof(FoundryUiColor, b) == 8);
FOUNDRY_AGREE(offsetof(FoundryUiColor, a) == 12);
FOUNDRY_AGREE(sizeof(((FoundryUiColor *)0)->r) == 4);
FOUNDRY_AGREE(sizeof(((FoundryUiColor *)0)->g) == 4);
FOUNDRY_AGREE(sizeof(((FoundryUiColor *)0)->b) == 4);
FOUNDRY_AGREE(sizeof(((FoundryUiColor *)0)->a) == 4);

FOUNDRY_AGREE(sizeof(FoundryUiFontMetrics) == 16);
FOUNDRY_AGREE(offsetof(FoundryUiFontMetrics, cell) == 0);
FOUNDRY_AGREE(offsetof(FoundryUiFontMetrics, letter_spacing) == 8);
FOUNDRY_AGREE(offsetof(FoundryUiFontMetrics, line_spacing) == 12);
FOUNDRY_AGREE(sizeof(((FoundryUiFontMetrics *)0)->cell) == 8);
FOUNDRY_AGREE(sizeof(((FoundryUiFontMetrics *)0)->letter_spacing) == 4);
FOUNDRY_AGREE(sizeof(((FoundryUiFontMetrics *)0)->line_spacing) == 4);

FOUNDRY_AGREE(sizeof(FoundryUiStyle) == 160);
FOUNDRY_AGREE(offsetof(FoundryUiStyle, font) == 0);
FOUNDRY_AGREE(offsetof(FoundryUiStyle, text_scale) == 16);
FOUNDRY_AGREE(offsetof(FoundryUiStyle, line_height) == 20);
FOUNDRY_AGREE(offsetof(FoundryUiStyle, padding) == 24);
FOUNDRY_AGREE(offsetof(FoundryUiStyle, spacing) == 32);
FOUNDRY_AGREE(offsetof(FoundryUiStyle, separator_thickness) == 36);
FOUNDRY_AGREE(offsetof(FoundryUiStyle, scrollbar) == 40);
FOUNDRY_AGREE(offsetof(FoundryUiStyle, caret_blink_frames) == 44);
FOUNDRY_AGREE(offsetof(FoundryUiStyle, text) == 48);
FOUNDRY_AGREE(offsetof(FoundryUiStyle, text_dim) == 64);
FOUNDRY_AGREE(offsetof(FoundryUiStyle, surface) == 80);
FOUNDRY_AGREE(offsetof(FoundryUiStyle, control) == 96);
FOUNDRY_AGREE(offsetof(FoundryUiStyle, control_hot) == 112);
FOUNDRY_AGREE(offsetof(FoundryUiStyle, control_active) == 128);
FOUNDRY_AGREE(offsetof(FoundryUiStyle, accent) == 144);
FOUNDRY_AGREE(sizeof(((FoundryUiStyle *)0)->font) == 16);
FOUNDRY_AGREE(sizeof(((FoundryUiStyle *)0)->text_scale) == 4);
FOUNDRY_AGREE(sizeof(((FoundryUiStyle *)0)->line_height) == 4);
FOUNDRY_AGREE(sizeof(((FoundryUiStyle *)0)->padding) == 8);
FOUNDRY_AGREE(sizeof(((FoundryUiStyle *)0)->spacing) == 4);
FOUNDRY_AGREE(sizeof(((FoundryUiStyle *)0)->separator_thickness) == 4);
FOUNDRY_AGREE(sizeof(((FoundryUiStyle *)0)->scrollbar) == 4);
FOUNDRY_AGREE(sizeof(((FoundryUiStyle *)0)->caret_blink_frames) == 4);
FOUNDRY_AGREE(sizeof(((FoundryUiStyle *)0)->text) == 16);
FOUNDRY_AGREE(sizeof(((FoundryUiStyle *)0)->text_dim) == 16);
FOUNDRY_AGREE(sizeof(((FoundryUiStyle *)0)->surface) == 16);
FOUNDRY_AGREE(sizeof(((FoundryUiStyle *)0)->control) == 16);
FOUNDRY_AGREE(sizeof(((FoundryUiStyle *)0)->control_hot) == 16);
FOUNDRY_AGREE(sizeof(((FoundryUiStyle *)0)->control_active) == 16);
FOUNDRY_AGREE(sizeof(((FoundryUiStyle *)0)->accent) == 16);

FOUNDRY_AGREE(sizeof(FoundryUiPlotOptions) == 32);
FOUNDRY_AGREE(offsetof(FoundryUiPlotOptions, height) == 0);
FOUNDRY_AGREE(offsetof(FoundryUiPlotOptions, _padding0) == 4);
FOUNDRY_AGREE(offsetof(FoundryUiPlotOptions, first) == 8);
FOUNDRY_AGREE(offsetof(FoundryUiPlotOptions, min) == 16);
FOUNDRY_AGREE(offsetof(FoundryUiPlotOptions, max) == 20);
FOUNDRY_AGREE(offsetof(FoundryUiPlotOptions, has_min) == 24);
FOUNDRY_AGREE(offsetof(FoundryUiPlotOptions, has_max) == 25);
FOUNDRY_AGREE(offsetof(FoundryUiPlotOptions, _padding1) == 26);
FOUNDRY_AGREE(sizeof(((FoundryUiPlotOptions *)0)->height) == 4);
FOUNDRY_AGREE(sizeof(((FoundryUiPlotOptions *)0)->_padding0) == 4);
FOUNDRY_AGREE(sizeof(((FoundryUiPlotOptions *)0)->first) == 8);
FOUNDRY_AGREE(sizeof(((FoundryUiPlotOptions *)0)->min) == 4);
FOUNDRY_AGREE(sizeof(((FoundryUiPlotOptions *)0)->max) == 4);
FOUNDRY_AGREE(sizeof(((FoundryUiPlotOptions *)0)->has_min) == 1);
FOUNDRY_AGREE(sizeof(((FoundryUiPlotOptions *)0)->has_max) == 1);
FOUNDRY_AGREE(sizeof(((FoundryUiPlotOptions *)0)->_padding1) == 2);

FOUNDRY_AGREE(sizeof(FoundryModInfo) == 120);
FOUNDRY_AGREE(offsetof(FoundryModInfo, id) == 0);
FOUNDRY_AGREE(offsetof(FoundryModInfo, id_name) == 8);
FOUNDRY_AGREE(offsetof(FoundryModInfo, name) == 24);
FOUNDRY_AGREE(offsetof(FoundryModInfo, license) == 40);
FOUNDRY_AGREE(offsetof(FoundryModInfo, version) == 56);
FOUNDRY_AGREE(offsetof(FoundryModInfo, origin) == 60);
FOUNDRY_AGREE(offsetof(FoundryModInfo, flags) == 64);
FOUNDRY_AGREE(offsetof(FoundryModInfo, pending_index) == 68);
FOUNDRY_AGREE(offsetof(FoundryModInfo, pending_position) == 72);
FOUNDRY_AGREE(offsetof(FoundryModInfo, skip_reason) == 76);
FOUNDRY_AGREE(offsetof(FoundryModInfo, skip_other) == 80);
FOUNDRY_AGREE(offsetof(FoundryModInfo, skip_other_name) == 88);
FOUNDRY_AGREE(offsetof(FoundryModInfo, provides) == 104);
FOUNDRY_AGREE(offsetof(FoundryModInfo, wins) == 108);
FOUNDRY_AGREE(offsetof(FoundryModInfo, loses) == 112);
FOUNDRY_AGREE(offsetof(FoundryModInfo, loaded) == 116);
FOUNDRY_AGREE(offsetof(FoundryModInfo, pending_enabled) == 117);
FOUNDRY_AGREE(offsetof(FoundryModInfo, _padding) == 118);

FOUNDRY_AGREE(sizeof(FoundryModPending) == 32);
FOUNDRY_AGREE(offsetof(FoundryModPending, id) == 0);
FOUNDRY_AGREE(offsetof(FoundryModPending, name) == 8);
FOUNDRY_AGREE(offsetof(FoundryModPending, installed) == 24);
FOUNDRY_AGREE(offsetof(FoundryModPending, _padding) == 25);

FOUNDRY_AGREE(sizeof(FoundryModRequirement) == 40);
FOUNDRY_AGREE(offsetof(FoundryModRequirement, id) == 0);
FOUNDRY_AGREE(offsetof(FoundryModRequirement, name) == 8);
FOUNDRY_AGREE(offsetof(FoundryModRequirement, min_version) == 24);
FOUNDRY_AGREE(offsetof(FoundryModRequirement, max_version) == 28);
FOUNDRY_AGREE(offsetof(FoundryModRequirement, satisfied) == 32);
FOUNDRY_AGREE(offsetof(FoundryModRequirement, _padding) == 33);

FOUNDRY_AGREE(sizeof(FoundryModConflict) == 40);
FOUNDRY_AGREE(offsetof(FoundryModConflict, record) == 0);
FOUNDRY_AGREE(offsetof(FoundryModConflict, name) == 8);
FOUNDRY_AGREE(offsetof(FoundryModConflict, winner) == 24);
FOUNDRY_AGREE(offsetof(FoundryModConflict, provider_count) == 32);

FOUNDRY_AGREE(sizeof(FoundryModProvider) == 16);
FOUNDRY_AGREE(offsetof(FoundryModProvider, package) == 0);
FOUNDRY_AGREE(offsetof(FoundryModProvider, position) == 8);
FOUNDRY_AGREE(offsetof(FoundryModProvider, winner) == 12);

FOUNDRY_AGREE(sizeof(FoundryModProfile) == 32);
FOUNDRY_AGREE(offsetof(FoundryModProfile, key) == 0);
FOUNDRY_AGREE(offsetof(FoundryModProfile, problem) == 4);
FOUNDRY_AGREE(offsetof(FoundryModProfile, name) == 8);
FOUNDRY_AGREE(offsetof(FoundryModProfile, saved) == 24);
FOUNDRY_AGREE(offsetof(FoundryModProfile, pending) == 25);

FOUNDRY_AGREE(sizeof(FoundryModProfileState) == 12);
FOUNDRY_AGREE(offsetof(FoundryModProfileState, saved) == 0);
FOUNDRY_AGREE(offsetof(FoundryModProfileState, pending) == 4);
FOUNDRY_AGREE(offsetof(FoundryModProfileState, has_saved) == 8);
FOUNDRY_AGREE(offsetof(FoundryModProfileState, has_pending) == 9);
FOUNDRY_AGREE(offsetof(FoundryModProfileState, changed) == 10);

FOUNDRY_AGREE(sizeof(FoundryUiImageSource) == 16);
FOUNDRY_AGREE(offsetof(FoundryUiImageSource, x) == 0);
FOUNDRY_AGREE(offsetof(FoundryUiImageSource, y) == 4);
FOUNDRY_AGREE(offsetof(FoundryUiImageSource, w) == 8);
FOUNDRY_AGREE(offsetof(FoundryUiImageSource, h) == 12);

FOUNDRY_AGREE(sizeof(FoundryUiReorderMove) == 12);
FOUNDRY_AGREE(offsetof(FoundryUiReorderMove, from) == 0);
FOUNDRY_AGREE(offsetof(FoundryUiReorderMove, to) == 4);
FOUNDRY_AGREE(offsetof(FoundryUiReorderMove, moved) == 8);

/* -- Physics2d values ---------------------------------------------------------------- */

FOUNDRY_AGREE(sizeof(FoundryPhysicsVec2) == 8);
FOUNDRY_AGREE(offsetof(FoundryPhysicsVec2, x) == 0);
FOUNDRY_AGREE(offsetof(FoundryPhysicsVec2, y) == 4);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsVec2 *)0)->x) == 4);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsVec2 *)0)->y) == 4);

FOUNDRY_AGREE(sizeof(FoundryPhysicsShape) == 16);
FOUNDRY_AGREE(offsetof(FoundryPhysicsShape, kind) == 0);
FOUNDRY_AGREE(offsetof(FoundryPhysicsShape, reserved) == 4);
FOUNDRY_AGREE(offsetof(FoundryPhysicsShape, x) == 8);
FOUNDRY_AGREE(offsetof(FoundryPhysicsShape, y) == 12);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsShape *)0)->kind) == 4);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsShape *)0)->reserved) == 4);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsShape *)0)->x) == 4);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsShape *)0)->y) == 4);

FOUNDRY_AGREE(sizeof(FoundryPhysicsBodyDesc) == 48);
FOUNDRY_AGREE(offsetof(FoundryPhysicsBodyDesc, shape) == 0);
FOUNDRY_AGREE(offsetof(FoundryPhysicsBodyDesc, position) == 16);
FOUNDRY_AGREE(offsetof(FoundryPhysicsBodyDesc, kind) == 24);
FOUNDRY_AGREE(offsetof(FoundryPhysicsBodyDesc, reserved) == 28);
FOUNDRY_AGREE(offsetof(FoundryPhysicsBodyDesc, layer) == 32);
FOUNDRY_AGREE(offsetof(FoundryPhysicsBodyDesc, mask) == 36);
FOUNDRY_AGREE(offsetof(FoundryPhysicsBodyDesc, user) == 40);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsBodyDesc *)0)->shape) == 16);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsBodyDesc *)0)->position) == 8);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsBodyDesc *)0)->kind) == 4);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsBodyDesc *)0)->reserved) == 4);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsBodyDesc *)0)->layer) == 4);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsBodyDesc *)0)->mask) == 4);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsBodyDesc *)0)->user) == 8);

FOUNDRY_AGREE(sizeof(FoundryPhysicsHit) == 48);
FOUNDRY_AGREE(offsetof(FoundryPhysicsHit, body) == 0);
FOUNDRY_AGREE(offsetof(FoundryPhysicsHit, grid) == 8);
FOUNDRY_AGREE(offsetof(FoundryPhysicsHit, cell_x) == 16);
FOUNDRY_AGREE(offsetof(FoundryPhysicsHit, cell_y) == 20);
FOUNDRY_AGREE(offsetof(FoundryPhysicsHit, normal) == 24);
FOUNDRY_AGREE(offsetof(FoundryPhysicsHit, fraction) == 32);
FOUNDRY_AGREE(offsetof(FoundryPhysicsHit, reserved) == 36);
FOUNDRY_AGREE(offsetof(FoundryPhysicsHit, user) == 40);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsHit *)0)->body) == 8);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsHit *)0)->grid) == 8);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsHit *)0)->cell_x) == 4);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsHit *)0)->cell_y) == 4);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsHit *)0)->normal) == 8);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsHit *)0)->fraction) == 4);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsHit *)0)->reserved) == 4);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsHit *)0)->user) == 8);

FOUNDRY_AGREE(sizeof(FoundryPhysicsQueryHit) == 32);
FOUNDRY_AGREE(offsetof(FoundryPhysicsQueryHit, body) == 0);
FOUNDRY_AGREE(offsetof(FoundryPhysicsQueryHit, grid) == 8);
FOUNDRY_AGREE(offsetof(FoundryPhysicsQueryHit, cell_x) == 16);
FOUNDRY_AGREE(offsetof(FoundryPhysicsQueryHit, cell_y) == 20);
FOUNDRY_AGREE(offsetof(FoundryPhysicsQueryHit, user) == 24);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsQueryHit *)0)->body) == 8);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsQueryHit *)0)->grid) == 8);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsQueryHit *)0)->cell_x) == 4);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsQueryHit *)0)->cell_y) == 4);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsQueryHit *)0)->user) == 8);

FOUNDRY_AGREE(sizeof(FoundryPhysicsMoveResult) == 20);
FOUNDRY_AGREE(offsetof(FoundryPhysicsMoveResult, position) == 0);
FOUNDRY_AGREE(offsetof(FoundryPhysicsMoveResult, hit_count) == 8);
FOUNDRY_AGREE(offsetof(FoundryPhysicsMoveResult, total_hits) == 12);
FOUNDRY_AGREE(offsetof(FoundryPhysicsMoveResult, started_inside) == 16);
FOUNDRY_AGREE(offsetof(FoundryPhysicsMoveResult, reserved) == 17);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsMoveResult *)0)->position) == 8);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsMoveResult *)0)->hit_count) == 4);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsMoveResult *)0)->total_hits) == 4);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsMoveResult *)0)->started_inside) == 1);
FOUNDRY_AGREE(sizeof(((FoundryPhysicsMoveResult *)0)->reserved) == 3);

/* Both spaces, one algorithm — and the Zig side compares each against the engine's own. */
uint64_t foundry_agreement_schema_id(const void *bytes, size_t len);
uint64_t foundry_agreement_schema_id(const void *bytes, size_t len)
{
    return foundry_schema_id(bytes, len).hash;
}

/* -- Step 5 function signatures ------------------------------------------------------ */

/*
 * The table assertion below proves that every entry is pointer-sized, but a changed
 * parameter type can keep that size and still be a different C ABI. These typedefs are the
 * signatures the public table promises; assigning each table member to its corresponding
 * type makes C99's incompatible-pointer diagnostic (and C++'s type system) check the full
 * parameter and return shape. There is intentionally no cast here: a cast would hide the
 * drift this harness exists to catch.
 */
typedef FoundryResult (*foundry_agree_render_texture_of_asset_fn)(FoundryAsset, FoundryTexture *);
typedef FoundryResult (*foundry_agree_render_destroy_texture_fn)(FoundryTexture);
typedef FoundryResult (*foundry_agree_render_draw_sprite_fn)(const FoundryRenderSprite *);
typedef FoundryResult (*foundry_agree_render_draw_text_fn)(const FoundryRenderFont *, FoundryStr,
                                                            const FoundryRenderTextOptions *);
typedef FoundryResult (*foundry_agree_render_add_view_fn)(const FoundryRenderViewDesc *, FoundryView *);
typedef FoundryResult (*foundry_agree_render_select_view_fn)(FoundryView);
typedef FoundryResult (*foundry_agree_render_camera_get_fn)(FoundryRenderCamera *);
typedef FoundryResult (*foundry_agree_render_camera_set_fn)(const FoundryRenderCamera *);
typedef FoundryResult (*foundry_agree_render_world_to_screen_fn)(FoundryRenderVec2, FoundryRenderVec2 *);
typedef FoundryResult (*foundry_agree_render_screen_to_world_fn)(FoundryRenderVec2, FoundryRenderVec2 *);
typedef FoundryResult (*foundry_agree_render_stats_fn)(FoundryRenderStats *);

typedef FoundryResult (*foundry_agree_ui_begin_fn)(const FoundryUiRect *);
typedef FoundryResult (*foundry_agree_ui_end_fn)(void);
typedef FoundryResult (*foundry_agree_ui_push_id_fn)(FoundryUiId);
typedef FoundryResult (*foundry_agree_ui_pop_id_fn)(void);
typedef FoundryResult (*foundry_agree_ui_begin_panel_fn)(FoundryUiId, const FoundryUiRect *);
typedef FoundryResult (*foundry_agree_ui_end_panel_fn)(void);
typedef FoundryResult (*foundry_agree_ui_begin_row_fn)(FoundryUiId, float);
typedef FoundryResult (*foundry_agree_ui_end_row_fn)(void);
typedef FoundryResult (*foundry_agree_ui_begin_scroll_fn)(FoundryUiId, const FoundryUiRect *, float);
typedef FoundryResult (*foundry_agree_ui_end_scroll_fn)(void);
typedef FoundryResult (*foundry_agree_ui_label_fn)(FoundryStr);
typedef FoundryResult (*foundry_agree_ui_button_fn)(FoundryUiId, FoundryStr, FoundryBool *);
typedef FoundryResult (*foundry_agree_ui_checkbox_fn)(FoundryUiId, FoundryStr, FoundryBool *,
                                                      FoundryBool *);
typedef FoundryResult (*foundry_agree_ui_slider_fn)(FoundryUiId, FoundryStr, float *, float, float,
                                                    FoundryBool *);
typedef FoundryResult (*foundry_agree_ui_slider_int_fn)(FoundryUiId, FoundryStr, int32_t *, int32_t,
                                                        int32_t, FoundryBool *);
typedef FoundryResult (*foundry_agree_ui_separator_fn)(void);
typedef FoundryResult (*foundry_agree_ui_spacer_fn)(float);
typedef FoundryResult (*foundry_agree_ui_collapsing_header_fn)(FoundryUiId, FoundryStr, FoundryBool *);
typedef FoundryResult (*foundry_agree_ui_text_field_fn)(FoundryUiId, uint8_t *, uint64_t, uint64_t *,
                                                        FoundryBool *);
typedef FoundryResult (*foundry_agree_ui_plot_fn)(const float *, uint64_t,
                                                  const FoundryUiPlotOptions *);
typedef FoundryResult (*foundry_agree_ui_style_get_fn)(FoundryUiStyle *);
typedef FoundryResult (*foundry_agree_ui_style_set_fn)(const FoundryUiStyle *);
typedef FoundryResult (*foundry_agree_ui_wants_keyboard_fn)(FoundryBool *);
typedef FoundryResult (*foundry_agree_ui_wants_pointer_fn)(FoundryBool *);

typedef FoundryResult (*foundry_agree_audio_play_fn)(FoundryContentId, float, float, float,
                                                      FoundryBool, FoundryVoice *);
typedef FoundryResult (*foundry_agree_audio_stop_fn)(FoundryVoice);
typedef FoundryResult (*foundry_agree_audio_set_gain_fn)(FoundryVoice, float);
typedef FoundryResult (*foundry_agree_audio_set_pan_fn)(FoundryVoice, float);
typedef FoundryResult (*foundry_agree_audio_set_pitch_fn)(FoundryVoice, float);
typedef FoundryResult (*foundry_agree_audio_set_master_gain_fn)(float);

typedef FoundryResult (*foundry_agree_physics_create_body_fn)(const FoundryPhysicsBodyDesc *, FoundryBody *);
typedef FoundryResult (*foundry_agree_physics_destroy_body_fn)(FoundryBody);
typedef FoundryResult (*foundry_agree_physics_move_body_fn)(FoundryBody, FoundryPhysicsVec2,
                                                            FoundryPhysicsHit *, uint32_t,
                                                            FoundryPhysicsMoveResult *);
typedef FoundryResult (*foundry_agree_physics_query_point_fn)(FoundryPhysicsVec2, uint32_t,
                                                              FoundryPhysicsQueryHit *, uint32_t,
                                                              uint32_t *, uint32_t *);
typedef FoundryResult (*foundry_agree_physics_query_aabb_fn)(FoundryPhysicsVec2, FoundryPhysicsVec2,
                                                             uint32_t, FoundryPhysicsQueryHit *, uint32_t,
                                                             uint32_t *, uint32_t *);
typedef FoundryResult (*foundry_agree_physics_query_ray_fn)(FoundryPhysicsVec2, FoundryPhysicsVec2,
                                                             uint32_t, FoundryPhysicsHit *, uint32_t,
                                                             uint32_t *, uint32_t *);
typedef FoundryResult (*foundry_agree_physics_body_contacts_fn)(FoundryBody, FoundryPhysicsQueryHit *,
                                                                uint32_t, uint32_t *, uint32_t *);

#define FOUNDRY_AGREE_API_FN(api, member, fn_type) \
    do {                                               \
        fn_type foundry_agree_fn = (api)->member;      \
        (void)foundry_agree_fn;                        \
    } while (0)

/* An externally visible test helper avoids an unused-function diagnostic while ensuring
 * the compiler type-checks every assignment in both C99 and C++ modes. */
void foundry_agreement_api_v1_step5_signatures(const FoundryApi_v1 *api)
{
    FOUNDRY_AGREE_API_FN(api, render_texture_of_asset, foundry_agree_render_texture_of_asset_fn);
    FOUNDRY_AGREE_API_FN(api, render_destroy_texture, foundry_agree_render_destroy_texture_fn);
    FOUNDRY_AGREE_API_FN(api, render_draw_sprite, foundry_agree_render_draw_sprite_fn);
    FOUNDRY_AGREE_API_FN(api, render_draw_text, foundry_agree_render_draw_text_fn);
    FOUNDRY_AGREE_API_FN(api, render_add_view, foundry_agree_render_add_view_fn);
    FOUNDRY_AGREE_API_FN(api, render_select_view, foundry_agree_render_select_view_fn);
    FOUNDRY_AGREE_API_FN(api, render_camera_get, foundry_agree_render_camera_get_fn);
    FOUNDRY_AGREE_API_FN(api, render_camera_set, foundry_agree_render_camera_set_fn);
    FOUNDRY_AGREE_API_FN(api, render_world_to_screen, foundry_agree_render_world_to_screen_fn);
    FOUNDRY_AGREE_API_FN(api, render_screen_to_world, foundry_agree_render_screen_to_world_fn);
    FOUNDRY_AGREE_API_FN(api, render_stats, foundry_agree_render_stats_fn);

    FOUNDRY_AGREE_API_FN(api, ui_begin, foundry_agree_ui_begin_fn);
    FOUNDRY_AGREE_API_FN(api, ui_end, foundry_agree_ui_end_fn);
    FOUNDRY_AGREE_API_FN(api, ui_push_id, foundry_agree_ui_push_id_fn);
    FOUNDRY_AGREE_API_FN(api, ui_pop_id, foundry_agree_ui_pop_id_fn);
    FOUNDRY_AGREE_API_FN(api, ui_begin_panel, foundry_agree_ui_begin_panel_fn);
    FOUNDRY_AGREE_API_FN(api, ui_end_panel, foundry_agree_ui_end_panel_fn);
    FOUNDRY_AGREE_API_FN(api, ui_begin_row, foundry_agree_ui_begin_row_fn);
    FOUNDRY_AGREE_API_FN(api, ui_end_row, foundry_agree_ui_end_row_fn);
    FOUNDRY_AGREE_API_FN(api, ui_begin_scroll, foundry_agree_ui_begin_scroll_fn);
    FOUNDRY_AGREE_API_FN(api, ui_end_scroll, foundry_agree_ui_end_scroll_fn);
    FOUNDRY_AGREE_API_FN(api, ui_label, foundry_agree_ui_label_fn);
    FOUNDRY_AGREE_API_FN(api, ui_button, foundry_agree_ui_button_fn);
    FOUNDRY_AGREE_API_FN(api, ui_checkbox, foundry_agree_ui_checkbox_fn);
    FOUNDRY_AGREE_API_FN(api, ui_slider, foundry_agree_ui_slider_fn);
    FOUNDRY_AGREE_API_FN(api, ui_slider_int, foundry_agree_ui_slider_int_fn);
    FOUNDRY_AGREE_API_FN(api, ui_separator, foundry_agree_ui_separator_fn);
    FOUNDRY_AGREE_API_FN(api, ui_spacer, foundry_agree_ui_spacer_fn);
    FOUNDRY_AGREE_API_FN(api, ui_collapsing_header, foundry_agree_ui_collapsing_header_fn);
    FOUNDRY_AGREE_API_FN(api, ui_text_field, foundry_agree_ui_text_field_fn);
    FOUNDRY_AGREE_API_FN(api, ui_plot, foundry_agree_ui_plot_fn);
    FOUNDRY_AGREE_API_FN(api, ui_style_get, foundry_agree_ui_style_get_fn);
    FOUNDRY_AGREE_API_FN(api, ui_style_set, foundry_agree_ui_style_set_fn);
    FOUNDRY_AGREE_API_FN(api, ui_wants_keyboard, foundry_agree_ui_wants_keyboard_fn);
    FOUNDRY_AGREE_API_FN(api, ui_wants_pointer, foundry_agree_ui_wants_pointer_fn);

    FOUNDRY_AGREE_API_FN(api, audio_play, foundry_agree_audio_play_fn);
    FOUNDRY_AGREE_API_FN(api, audio_stop, foundry_agree_audio_stop_fn);
    FOUNDRY_AGREE_API_FN(api, audio_set_gain, foundry_agree_audio_set_gain_fn);
    FOUNDRY_AGREE_API_FN(api, audio_set_pan, foundry_agree_audio_set_pan_fn);
    FOUNDRY_AGREE_API_FN(api, audio_set_pitch, foundry_agree_audio_set_pitch_fn);
    FOUNDRY_AGREE_API_FN(api, audio_set_master_gain, foundry_agree_audio_set_master_gain_fn);

    FOUNDRY_AGREE_API_FN(api, physics_create_body, foundry_agree_physics_create_body_fn);
    FOUNDRY_AGREE_API_FN(api, physics_destroy_body, foundry_agree_physics_destroy_body_fn);
    FOUNDRY_AGREE_API_FN(api, physics_move_body, foundry_agree_physics_move_body_fn);
    FOUNDRY_AGREE_API_FN(api, physics_query_point, foundry_agree_physics_query_point_fn);
    FOUNDRY_AGREE_API_FN(api, physics_query_aabb, foundry_agree_physics_query_aabb_fn);
    FOUNDRY_AGREE_API_FN(api, physics_query_ray, foundry_agree_physics_query_ray_fn);
    FOUNDRY_AGREE_API_FN(api, physics_body_contacts, foundry_agree_physics_body_contacts_fn);
}

#undef FOUNDRY_AGREE_API_FN

/* -- The table ----------------------------------------------------------------------- */

/*
 * Every member of `FoundryApi_v1`, in the order the header declares them, and where each one
 * actually is. A member that does not exist is a compile error rather than a stale entry.
 *
 * `agreement.zig` walks the offsets against the Zig struct's own fields, positionally — which
 * is what makes the check sensitive to a **reordering** and not only to an addition. Every
 * entry in the table is eight bytes wide, so two members swapped in the header keep the same
 * *set* of offsets; what changes is which member reports which, and comparing position by
 * position is exactly what catches that. The names carry no check of their own: they are
 * there so a failure says which capability moved instead of only which index.
 *
 * Appending a capability is therefore three edits, and missing any one of them fails: the
 * header, this list, and the Zig struct.
 */
static const char *const api_v1_names[] = {
    "version",
    "size",
    "result_name",
    "log_write",
    "log_next",
    "id_from_string",
    "id_to_string",
    "id_copy_string",
    "frame_index",
    "frame_delta_ns",
    "elapsed_ns",
    "tick_delta_ns",
    "scope_begin",
    "scope_end",
    "memory_counter_open",
    "memory_counter_set",
    "content_generation",
    "content_find",
    "content_next",
    "content_next_of_schema",
    "record_id",
    "record_name",
    "record_schema",
    "record_package",
    "record_field_count",
    "record_field_index",
    "record_field_name",
    "record_field_type",
    "record_field_present",
    "record_get_bool",
    "record_get_i64",
    "record_get_u64",
    "record_get_f32",
    "record_get_string",
    "record_copy_string",
    "record_get_id",
    "record_nested",
    "record_list_len",
    "record_list_get_i64",
    "record_list_get_f32",
    "record_list_get_string",
    "record_list_get_id",
    "record_list_nested",
    "package_count",
    "package_next",
    "package_find",
    "package_id",
    "package_name",
    "package_version",
    "package_order",
    "schema_count",
    "schema_next",
    "schema_find",
    "schema_id",
    "schema_version",
    "schema_field_count",
    "schema_field_name",
    "schema_field_type",
    "asset_acquire",
    "asset_release",
    "asset_find",
    "asset_next",
    "asset_content_id",
    "asset_schema",
    "asset_refcount",
    "world_register_component",
    "world_find_component_type",
    "world_component_type_next",
    "world_component_type_schema",
    "world_component_type_name",
    "world_component_type_size",
    "world_component_type_alignment",
    "world_component_type_count",
    "world_component_type_savable",
    "world_create_entity",
    "world_destroy_entity",
    "world_contains",
    "world_entity_count",
    "world_next_entity",
    "world_add_component",
    "world_remove_component",
    "world_has_component",
    "world_register_system",
    "world_query_begin",
    "world_query_next",
    "world_spawn",
    "world_spawn_scene",
    "world_read_component",
    "world_component_bytes",
    "render_texture_of_asset",
    "render_destroy_texture",
    "render_draw_sprite",
    "render_draw_text",
    "render_add_view",
    "render_select_view",
    "render_camera_get",
    "render_camera_set",
    "render_world_to_screen",
    "render_screen_to_world",
    "render_stats",
    "ui_begin",
    "ui_end",
    "ui_push_id",
    "ui_pop_id",
    "ui_begin_panel",
    "ui_end_panel",
    "ui_begin_row",
    "ui_end_row",
    "ui_begin_scroll",
    "ui_end_scroll",
    "ui_label",
    "ui_button",
    "ui_checkbox",
    "ui_slider",
    "ui_slider_int",
    "ui_separator",
    "ui_spacer",
    "ui_collapsing_header",
    "ui_text_field",
    "ui_plot",
    "ui_style_get",
    "ui_style_set",
    "ui_wants_keyboard",
    "ui_wants_pointer",
    "audio_play",
    "audio_stop",
    "audio_set_gain",
    "audio_set_pan",
    "audio_set_pitch",
    "audio_set_master_gain",
    "physics_create_body",
    "physics_destroy_body",
    "physics_move_body",
    "physics_query_point",
    "physics_query_aabb",
    "physics_query_ray",
    "physics_body_contacts"
};

static const uint64_t api_v1_offsets[] = {
    (uint64_t)offsetof(FoundryApi_v1, version),
    (uint64_t)offsetof(FoundryApi_v1, size),
    (uint64_t)offsetof(FoundryApi_v1, result_name),
    (uint64_t)offsetof(FoundryApi_v1, log_write),
    (uint64_t)offsetof(FoundryApi_v1, log_next),
    (uint64_t)offsetof(FoundryApi_v1, id_from_string),
    (uint64_t)offsetof(FoundryApi_v1, id_to_string),
    (uint64_t)offsetof(FoundryApi_v1, id_copy_string),
    (uint64_t)offsetof(FoundryApi_v1, frame_index),
    (uint64_t)offsetof(FoundryApi_v1, frame_delta_ns),
    (uint64_t)offsetof(FoundryApi_v1, elapsed_ns),
    (uint64_t)offsetof(FoundryApi_v1, tick_delta_ns),
    (uint64_t)offsetof(FoundryApi_v1, scope_begin),
    (uint64_t)offsetof(FoundryApi_v1, scope_end),
    (uint64_t)offsetof(FoundryApi_v1, memory_counter_open),
    (uint64_t)offsetof(FoundryApi_v1, memory_counter_set),
    (uint64_t)offsetof(FoundryApi_v1, content_generation),
    (uint64_t)offsetof(FoundryApi_v1, content_find),
    (uint64_t)offsetof(FoundryApi_v1, content_next),
    (uint64_t)offsetof(FoundryApi_v1, content_next_of_schema),
    (uint64_t)offsetof(FoundryApi_v1, record_id),
    (uint64_t)offsetof(FoundryApi_v1, record_name),
    (uint64_t)offsetof(FoundryApi_v1, record_schema),
    (uint64_t)offsetof(FoundryApi_v1, record_package),
    (uint64_t)offsetof(FoundryApi_v1, record_field_count),
    (uint64_t)offsetof(FoundryApi_v1, record_field_index),
    (uint64_t)offsetof(FoundryApi_v1, record_field_name),
    (uint64_t)offsetof(FoundryApi_v1, record_field_type),
    (uint64_t)offsetof(FoundryApi_v1, record_field_present),
    (uint64_t)offsetof(FoundryApi_v1, record_get_bool),
    (uint64_t)offsetof(FoundryApi_v1, record_get_i64),
    (uint64_t)offsetof(FoundryApi_v1, record_get_u64),
    (uint64_t)offsetof(FoundryApi_v1, record_get_f32),
    (uint64_t)offsetof(FoundryApi_v1, record_get_string),
    (uint64_t)offsetof(FoundryApi_v1, record_copy_string),
    (uint64_t)offsetof(FoundryApi_v1, record_get_id),
    (uint64_t)offsetof(FoundryApi_v1, record_nested),
    (uint64_t)offsetof(FoundryApi_v1, record_list_len),
    (uint64_t)offsetof(FoundryApi_v1, record_list_get_i64),
    (uint64_t)offsetof(FoundryApi_v1, record_list_get_f32),
    (uint64_t)offsetof(FoundryApi_v1, record_list_get_string),
    (uint64_t)offsetof(FoundryApi_v1, record_list_get_id),
    (uint64_t)offsetof(FoundryApi_v1, record_list_nested),
    (uint64_t)offsetof(FoundryApi_v1, package_count),
    (uint64_t)offsetof(FoundryApi_v1, package_next),
    (uint64_t)offsetof(FoundryApi_v1, package_find),
    (uint64_t)offsetof(FoundryApi_v1, package_id),
    (uint64_t)offsetof(FoundryApi_v1, package_name),
    (uint64_t)offsetof(FoundryApi_v1, package_version),
    (uint64_t)offsetof(FoundryApi_v1, package_order),
    (uint64_t)offsetof(FoundryApi_v1, schema_count),
    (uint64_t)offsetof(FoundryApi_v1, schema_next),
    (uint64_t)offsetof(FoundryApi_v1, schema_find),
    (uint64_t)offsetof(FoundryApi_v1, schema_id),
    (uint64_t)offsetof(FoundryApi_v1, schema_version),
    (uint64_t)offsetof(FoundryApi_v1, schema_field_count),
    (uint64_t)offsetof(FoundryApi_v1, schema_field_name),
    (uint64_t)offsetof(FoundryApi_v1, schema_field_type),
    (uint64_t)offsetof(FoundryApi_v1, asset_acquire),
    (uint64_t)offsetof(FoundryApi_v1, asset_release),
    (uint64_t)offsetof(FoundryApi_v1, asset_find),
    (uint64_t)offsetof(FoundryApi_v1, asset_next),
    (uint64_t)offsetof(FoundryApi_v1, asset_content_id),
    (uint64_t)offsetof(FoundryApi_v1, asset_schema),
    (uint64_t)offsetof(FoundryApi_v1, asset_refcount),
    (uint64_t)offsetof(FoundryApi_v1, world_register_component),
    (uint64_t)offsetof(FoundryApi_v1, world_find_component_type),
    (uint64_t)offsetof(FoundryApi_v1, world_component_type_next),
    (uint64_t)offsetof(FoundryApi_v1, world_component_type_schema),
    (uint64_t)offsetof(FoundryApi_v1, world_component_type_name),
    (uint64_t)offsetof(FoundryApi_v1, world_component_type_size),
    (uint64_t)offsetof(FoundryApi_v1, world_component_type_alignment),
    (uint64_t)offsetof(FoundryApi_v1, world_component_type_count),
    (uint64_t)offsetof(FoundryApi_v1, world_component_type_savable),
    (uint64_t)offsetof(FoundryApi_v1, world_create_entity),
    (uint64_t)offsetof(FoundryApi_v1, world_destroy_entity),
    (uint64_t)offsetof(FoundryApi_v1, world_contains),
    (uint64_t)offsetof(FoundryApi_v1, world_entity_count),
    (uint64_t)offsetof(FoundryApi_v1, world_next_entity),
    (uint64_t)offsetof(FoundryApi_v1, world_add_component),
    (uint64_t)offsetof(FoundryApi_v1, world_remove_component),
    (uint64_t)offsetof(FoundryApi_v1, world_has_component),
    (uint64_t)offsetof(FoundryApi_v1, world_register_system),
    (uint64_t)offsetof(FoundryApi_v1, world_query_begin),
    (uint64_t)offsetof(FoundryApi_v1, world_query_next),
    (uint64_t)offsetof(FoundryApi_v1, world_spawn),
    (uint64_t)offsetof(FoundryApi_v1, world_spawn_scene),
    (uint64_t)offsetof(FoundryApi_v1, world_read_component),
    (uint64_t)offsetof(FoundryApi_v1, world_component_bytes),
    (uint64_t)offsetof(FoundryApi_v1, render_texture_of_asset),
    (uint64_t)offsetof(FoundryApi_v1, render_destroy_texture),
    (uint64_t)offsetof(FoundryApi_v1, render_draw_sprite),
    (uint64_t)offsetof(FoundryApi_v1, render_draw_text),
    (uint64_t)offsetof(FoundryApi_v1, render_add_view),
    (uint64_t)offsetof(FoundryApi_v1, render_select_view),
    (uint64_t)offsetof(FoundryApi_v1, render_camera_get),
    (uint64_t)offsetof(FoundryApi_v1, render_camera_set),
    (uint64_t)offsetof(FoundryApi_v1, render_world_to_screen),
    (uint64_t)offsetof(FoundryApi_v1, render_screen_to_world),
    (uint64_t)offsetof(FoundryApi_v1, render_stats),
    (uint64_t)offsetof(FoundryApi_v1, ui_begin),
    (uint64_t)offsetof(FoundryApi_v1, ui_end),
    (uint64_t)offsetof(FoundryApi_v1, ui_push_id),
    (uint64_t)offsetof(FoundryApi_v1, ui_pop_id),
    (uint64_t)offsetof(FoundryApi_v1, ui_begin_panel),
    (uint64_t)offsetof(FoundryApi_v1, ui_end_panel),
    (uint64_t)offsetof(FoundryApi_v1, ui_begin_row),
    (uint64_t)offsetof(FoundryApi_v1, ui_end_row),
    (uint64_t)offsetof(FoundryApi_v1, ui_begin_scroll),
    (uint64_t)offsetof(FoundryApi_v1, ui_end_scroll),
    (uint64_t)offsetof(FoundryApi_v1, ui_label),
    (uint64_t)offsetof(FoundryApi_v1, ui_button),
    (uint64_t)offsetof(FoundryApi_v1, ui_checkbox),
    (uint64_t)offsetof(FoundryApi_v1, ui_slider),
    (uint64_t)offsetof(FoundryApi_v1, ui_slider_int),
    (uint64_t)offsetof(FoundryApi_v1, ui_separator),
    (uint64_t)offsetof(FoundryApi_v1, ui_spacer),
    (uint64_t)offsetof(FoundryApi_v1, ui_collapsing_header),
    (uint64_t)offsetof(FoundryApi_v1, ui_text_field),
    (uint64_t)offsetof(FoundryApi_v1, ui_plot),
    (uint64_t)offsetof(FoundryApi_v1, ui_style_get),
    (uint64_t)offsetof(FoundryApi_v1, ui_style_set),
    (uint64_t)offsetof(FoundryApi_v1, ui_wants_keyboard),
    (uint64_t)offsetof(FoundryApi_v1, ui_wants_pointer),
    (uint64_t)offsetof(FoundryApi_v1, audio_play),
    (uint64_t)offsetof(FoundryApi_v1, audio_stop),
    (uint64_t)offsetof(FoundryApi_v1, audio_set_gain),
    (uint64_t)offsetof(FoundryApi_v1, audio_set_pan),
    (uint64_t)offsetof(FoundryApi_v1, audio_set_pitch),
    (uint64_t)offsetof(FoundryApi_v1, audio_set_master_gain),
    (uint64_t)offsetof(FoundryApi_v1, physics_create_body),
    (uint64_t)offsetof(FoundryApi_v1, physics_destroy_body),
    (uint64_t)offsetof(FoundryApi_v1, physics_move_body),
    (uint64_t)offsetof(FoundryApi_v1, physics_query_point),
    (uint64_t)offsetof(FoundryApi_v1, physics_query_aabb),
    (uint64_t)offsetof(FoundryApi_v1, physics_query_ray),
    (uint64_t)offsetof(FoundryApi_v1, physics_body_contacts)
};

/* The two lists are one list, and this is what says so. */
FOUNDRY_AGREE(sizeof(api_v1_names) / sizeof(api_v1_names[0]) ==
              sizeof(api_v1_offsets) / sizeof(api_v1_offsets[0]));

/* A table of nothing but `version`, `size` and eight-byte pointers. If this fails, something
 * in the table is not a function pointer, which is a change the whole design forbids. */
FOUNDRY_AGREE(sizeof(FoundryApi_v1) ==
              8 + 8 * (sizeof(api_v1_offsets) / sizeof(api_v1_offsets[0]) - 2));

uint64_t foundry_agreement_api_v1_size(void);
uint64_t foundry_agreement_api_v1_size(void)
{
    return (uint64_t)sizeof(FoundryApi_v1);
}

uint64_t foundry_agreement_api_v1_count(void);
uint64_t foundry_agreement_api_v1_count(void)
{
    return (uint64_t)(sizeof(api_v1_offsets) / sizeof(api_v1_offsets[0]));
}

uint64_t foundry_agreement_api_v1_offset(uint64_t index);
uint64_t foundry_agreement_api_v1_offset(uint64_t index)
{
    if (index >= foundry_agreement_api_v1_count()) return UINT64_MAX;
    return api_v1_offsets[index];
}

const char *foundry_agreement_api_v1_name(uint64_t index);
const char *foundry_agreement_api_v1_name(uint64_t index)
{
    if (index >= foundry_agreement_api_v1_count()) return NULL;
    return api_v1_names[index];
}

/* -- ABI v2 -------------------------------------------------------------------------- */

typedef FoundryResult (*foundry_agree_script_source_copy_fn)(
    FoundryAsset, uint8_t *, uint64_t, uint64_t *, uint64_t *);

void foundry_agreement_api_v2_signature(const FoundryApi_v2 *api);
void foundry_agreement_api_v2_signature(const FoundryApi_v2 *api)
{
    foundry_agree_script_source_copy_fn fn = api->script_source_copy;
    (void)fn;
}

/* Positional initialization type-checks every common v2 member against v1 without
 * `typeof`, casts, or a non-C99 extension. A signature drift in either table is an
 * incompatible-pointer diagnostic under the build's `-Werror`. */
void foundry_agreement_api_v2_common_signatures(const FoundryApi_v2 *api);
void foundry_agreement_api_v2_common_signatures(const FoundryApi_v2 *api)
{
    FoundryApi_v1 common = {
        api->version,
        api->size,
        api->result_name,
        api->log_write,
        api->log_next,
        api->id_from_string,
        api->id_to_string,
        api->id_copy_string,
        api->frame_index,
        api->frame_delta_ns,
        api->elapsed_ns,
        api->tick_delta_ns,
        api->scope_begin,
        api->scope_end,
        api->memory_counter_open,
        api->memory_counter_set,
        api->content_generation,
        api->content_find,
        api->content_next,
        api->content_next_of_schema,
        api->record_id,
        api->record_name,
        api->record_schema,
        api->record_package,
        api->record_field_count,
        api->record_field_index,
        api->record_field_name,
        api->record_field_type,
        api->record_field_present,
        api->record_get_bool,
        api->record_get_i64,
        api->record_get_u64,
        api->record_get_f32,
        api->record_get_string,
        api->record_copy_string,
        api->record_get_id,
        api->record_nested,
        api->record_list_len,
        api->record_list_get_i64,
        api->record_list_get_f32,
        api->record_list_get_string,
        api->record_list_get_id,
        api->record_list_nested,
        api->package_count,
        api->package_next,
        api->package_find,
        api->package_id,
        api->package_name,
        api->package_version,
        api->package_order,
        api->schema_count,
        api->schema_next,
        api->schema_find,
        api->schema_id,
        api->schema_version,
        api->schema_field_count,
        api->schema_field_name,
        api->schema_field_type,
        api->asset_acquire,
        api->asset_release,
        api->asset_find,
        api->asset_next,
        api->asset_content_id,
        api->asset_schema,
        api->asset_refcount,
        api->world_register_component,
        api->world_find_component_type,
        api->world_component_type_next,
        api->world_component_type_schema,
        api->world_component_type_name,
        api->world_component_type_size,
        api->world_component_type_alignment,
        api->world_component_type_count,
        api->world_component_type_savable,
        api->world_create_entity,
        api->world_destroy_entity,
        api->world_contains,
        api->world_entity_count,
        api->world_next_entity,
        api->world_add_component,
        api->world_remove_component,
        api->world_has_component,
        api->world_register_system,
        api->world_query_begin,
        api->world_query_next,
        api->world_spawn,
        api->world_spawn_scene,
        api->world_read_component,
        api->world_component_bytes,
        api->render_texture_of_asset,
        api->render_destroy_texture,
        api->render_draw_sprite,
        api->render_draw_text,
        api->render_add_view,
        api->render_select_view,
        api->render_camera_get,
        api->render_camera_set,
        api->render_world_to_screen,
        api->render_screen_to_world,
        api->render_stats,
        api->ui_begin,
        api->ui_end,
        api->ui_push_id,
        api->ui_pop_id,
        api->ui_begin_panel,
        api->ui_end_panel,
        api->ui_begin_row,
        api->ui_end_row,
        api->ui_begin_scroll,
        api->ui_end_scroll,
        api->ui_label,
        api->ui_button,
        api->ui_checkbox,
        api->ui_slider,
        api->ui_slider_int,
        api->ui_separator,
        api->ui_spacer,
        api->ui_collapsing_header,
        api->ui_text_field,
        api->ui_plot,
        api->ui_style_get,
        api->ui_style_set,
        api->ui_wants_keyboard,
        api->ui_wants_pointer,
        api->audio_play,
        api->audio_stop,
        api->audio_set_gain,
        api->audio_set_pan,
        api->audio_set_pitch,
        api->audio_set_master_gain,
        api->physics_create_body,
        api->physics_destroy_body,
        api->physics_move_body,
        api->physics_query_point,
        api->physics_query_aabb,
        api->physics_query_ray,
        api->physics_body_contacts
    };
    (void)common;
}

/* A header-only C consumer of the complete public path: query v2, acquire by content id,
 * copy the typed source, and balance the reference before returning. */
FoundryResult foundry_agreement_copy_script_source(
    FoundryGetApi get_api, FoundryContentId id, uint8_t *buffer, uint64_t capacity,
    uint64_t *needed, uint64_t *revision);
FoundryResult foundry_agreement_copy_script_source(
    FoundryGetApi get_api, FoundryContentId id, uint8_t *buffer, uint64_t capacity,
    uint64_t *needed, uint64_t *revision)
{
    const FoundryApi_v2 *api;
    FoundryAsset asset = {0};
    FoundryResult result;
    FoundryResult release_result;

    if (get_api == NULL) return FOUNDRY_ERR_INVALID_ARGUMENT;
    api = (const FoundryApi_v2 *)get_api(FOUNDRY_API_VERSION_2);
    if (api == NULL) return FOUNDRY_ERR_UNSUPPORTED;

    result = api->asset_acquire(id, &asset);
    if (result != FOUNDRY_OK) return result;
    result = api->script_source_copy(asset, buffer, capacity, needed, revision);
    release_result = api->asset_release(asset);
    return result != FOUNDRY_OK ? result : release_result;
}

static const char *const api_v2_names[] = {
    "version",
    "size",
    "result_name",
    "log_write",
    "log_next",
    "id_from_string",
    "id_to_string",
    "id_copy_string",
    "frame_index",
    "frame_delta_ns",
    "elapsed_ns",
    "tick_delta_ns",
    "scope_begin",
    "scope_end",
    "memory_counter_open",
    "memory_counter_set",
    "content_generation",
    "content_find",
    "content_next",
    "content_next_of_schema",
    "record_id",
    "record_name",
    "record_schema",
    "record_package",
    "record_field_count",
    "record_field_index",
    "record_field_name",
    "record_field_type",
    "record_field_present",
    "record_get_bool",
    "record_get_i64",
    "record_get_u64",
    "record_get_f32",
    "record_get_string",
    "record_copy_string",
    "record_get_id",
    "record_nested",
    "record_list_len",
    "record_list_get_i64",
    "record_list_get_f32",
    "record_list_get_string",
    "record_list_get_id",
    "record_list_nested",
    "package_count",
    "package_next",
    "package_find",
    "package_id",
    "package_name",
    "package_version",
    "package_order",
    "schema_count",
    "schema_next",
    "schema_find",
    "schema_id",
    "schema_version",
    "schema_field_count",
    "schema_field_name",
    "schema_field_type",
    "asset_acquire",
    "asset_release",
    "asset_find",
    "asset_next",
    "asset_content_id",
    "asset_schema",
    "asset_refcount",
    "world_register_component",
    "world_find_component_type",
    "world_component_type_next",
    "world_component_type_schema",
    "world_component_type_name",
    "world_component_type_size",
    "world_component_type_alignment",
    "world_component_type_count",
    "world_component_type_savable",
    "world_create_entity",
    "world_destroy_entity",
    "world_contains",
    "world_entity_count",
    "world_next_entity",
    "world_add_component",
    "world_remove_component",
    "world_has_component",
    "world_register_system",
    "world_query_begin",
    "world_query_next",
    "world_spawn",
    "world_spawn_scene",
    "world_read_component",
    "world_component_bytes",
    "render_texture_of_asset",
    "render_destroy_texture",
    "render_draw_sprite",
    "render_draw_text",
    "render_add_view",
    "render_select_view",
    "render_camera_get",
    "render_camera_set",
    "render_world_to_screen",
    "render_screen_to_world",
    "render_stats",
    "ui_begin",
    "ui_end",
    "ui_push_id",
    "ui_pop_id",
    "ui_begin_panel",
    "ui_end_panel",
    "ui_begin_row",
    "ui_end_row",
    "ui_begin_scroll",
    "ui_end_scroll",
    "ui_label",
    "ui_button",
    "ui_checkbox",
    "ui_slider",
    "ui_slider_int",
    "ui_separator",
    "ui_spacer",
    "ui_collapsing_header",
    "ui_text_field",
    "ui_plot",
    "ui_style_get",
    "ui_style_set",
    "ui_wants_keyboard",
    "ui_wants_pointer",
    "audio_play",
    "audio_stop",
    "audio_set_gain",
    "audio_set_pan",
    "audio_set_pitch",
    "audio_set_master_gain",
    "physics_create_body",
    "physics_destroy_body",
    "physics_move_body",
    "physics_query_point",
    "physics_query_aabb",
    "physics_query_ray",
    "physics_body_contacts",
    "script_source_copy"
};

static const uint64_t api_v2_offsets[] = {
    (uint64_t)offsetof(FoundryApi_v2, version),
    (uint64_t)offsetof(FoundryApi_v2, size),
    (uint64_t)offsetof(FoundryApi_v2, result_name),
    (uint64_t)offsetof(FoundryApi_v2, log_write),
    (uint64_t)offsetof(FoundryApi_v2, log_next),
    (uint64_t)offsetof(FoundryApi_v2, id_from_string),
    (uint64_t)offsetof(FoundryApi_v2, id_to_string),
    (uint64_t)offsetof(FoundryApi_v2, id_copy_string),
    (uint64_t)offsetof(FoundryApi_v2, frame_index),
    (uint64_t)offsetof(FoundryApi_v2, frame_delta_ns),
    (uint64_t)offsetof(FoundryApi_v2, elapsed_ns),
    (uint64_t)offsetof(FoundryApi_v2, tick_delta_ns),
    (uint64_t)offsetof(FoundryApi_v2, scope_begin),
    (uint64_t)offsetof(FoundryApi_v2, scope_end),
    (uint64_t)offsetof(FoundryApi_v2, memory_counter_open),
    (uint64_t)offsetof(FoundryApi_v2, memory_counter_set),
    (uint64_t)offsetof(FoundryApi_v2, content_generation),
    (uint64_t)offsetof(FoundryApi_v2, content_find),
    (uint64_t)offsetof(FoundryApi_v2, content_next),
    (uint64_t)offsetof(FoundryApi_v2, content_next_of_schema),
    (uint64_t)offsetof(FoundryApi_v2, record_id),
    (uint64_t)offsetof(FoundryApi_v2, record_name),
    (uint64_t)offsetof(FoundryApi_v2, record_schema),
    (uint64_t)offsetof(FoundryApi_v2, record_package),
    (uint64_t)offsetof(FoundryApi_v2, record_field_count),
    (uint64_t)offsetof(FoundryApi_v2, record_field_index),
    (uint64_t)offsetof(FoundryApi_v2, record_field_name),
    (uint64_t)offsetof(FoundryApi_v2, record_field_type),
    (uint64_t)offsetof(FoundryApi_v2, record_field_present),
    (uint64_t)offsetof(FoundryApi_v2, record_get_bool),
    (uint64_t)offsetof(FoundryApi_v2, record_get_i64),
    (uint64_t)offsetof(FoundryApi_v2, record_get_u64),
    (uint64_t)offsetof(FoundryApi_v2, record_get_f32),
    (uint64_t)offsetof(FoundryApi_v2, record_get_string),
    (uint64_t)offsetof(FoundryApi_v2, record_copy_string),
    (uint64_t)offsetof(FoundryApi_v2, record_get_id),
    (uint64_t)offsetof(FoundryApi_v2, record_nested),
    (uint64_t)offsetof(FoundryApi_v2, record_list_len),
    (uint64_t)offsetof(FoundryApi_v2, record_list_get_i64),
    (uint64_t)offsetof(FoundryApi_v2, record_list_get_f32),
    (uint64_t)offsetof(FoundryApi_v2, record_list_get_string),
    (uint64_t)offsetof(FoundryApi_v2, record_list_get_id),
    (uint64_t)offsetof(FoundryApi_v2, record_list_nested),
    (uint64_t)offsetof(FoundryApi_v2, package_count),
    (uint64_t)offsetof(FoundryApi_v2, package_next),
    (uint64_t)offsetof(FoundryApi_v2, package_find),
    (uint64_t)offsetof(FoundryApi_v2, package_id),
    (uint64_t)offsetof(FoundryApi_v2, package_name),
    (uint64_t)offsetof(FoundryApi_v2, package_version),
    (uint64_t)offsetof(FoundryApi_v2, package_order),
    (uint64_t)offsetof(FoundryApi_v2, schema_count),
    (uint64_t)offsetof(FoundryApi_v2, schema_next),
    (uint64_t)offsetof(FoundryApi_v2, schema_find),
    (uint64_t)offsetof(FoundryApi_v2, schema_id),
    (uint64_t)offsetof(FoundryApi_v2, schema_version),
    (uint64_t)offsetof(FoundryApi_v2, schema_field_count),
    (uint64_t)offsetof(FoundryApi_v2, schema_field_name),
    (uint64_t)offsetof(FoundryApi_v2, schema_field_type),
    (uint64_t)offsetof(FoundryApi_v2, asset_acquire),
    (uint64_t)offsetof(FoundryApi_v2, asset_release),
    (uint64_t)offsetof(FoundryApi_v2, asset_find),
    (uint64_t)offsetof(FoundryApi_v2, asset_next),
    (uint64_t)offsetof(FoundryApi_v2, asset_content_id),
    (uint64_t)offsetof(FoundryApi_v2, asset_schema),
    (uint64_t)offsetof(FoundryApi_v2, asset_refcount),
    (uint64_t)offsetof(FoundryApi_v2, world_register_component),
    (uint64_t)offsetof(FoundryApi_v2, world_find_component_type),
    (uint64_t)offsetof(FoundryApi_v2, world_component_type_next),
    (uint64_t)offsetof(FoundryApi_v2, world_component_type_schema),
    (uint64_t)offsetof(FoundryApi_v2, world_component_type_name),
    (uint64_t)offsetof(FoundryApi_v2, world_component_type_size),
    (uint64_t)offsetof(FoundryApi_v2, world_component_type_alignment),
    (uint64_t)offsetof(FoundryApi_v2, world_component_type_count),
    (uint64_t)offsetof(FoundryApi_v2, world_component_type_savable),
    (uint64_t)offsetof(FoundryApi_v2, world_create_entity),
    (uint64_t)offsetof(FoundryApi_v2, world_destroy_entity),
    (uint64_t)offsetof(FoundryApi_v2, world_contains),
    (uint64_t)offsetof(FoundryApi_v2, world_entity_count),
    (uint64_t)offsetof(FoundryApi_v2, world_next_entity),
    (uint64_t)offsetof(FoundryApi_v2, world_add_component),
    (uint64_t)offsetof(FoundryApi_v2, world_remove_component),
    (uint64_t)offsetof(FoundryApi_v2, world_has_component),
    (uint64_t)offsetof(FoundryApi_v2, world_register_system),
    (uint64_t)offsetof(FoundryApi_v2, world_query_begin),
    (uint64_t)offsetof(FoundryApi_v2, world_query_next),
    (uint64_t)offsetof(FoundryApi_v2, world_spawn),
    (uint64_t)offsetof(FoundryApi_v2, world_spawn_scene),
    (uint64_t)offsetof(FoundryApi_v2, world_read_component),
    (uint64_t)offsetof(FoundryApi_v2, world_component_bytes),
    (uint64_t)offsetof(FoundryApi_v2, render_texture_of_asset),
    (uint64_t)offsetof(FoundryApi_v2, render_destroy_texture),
    (uint64_t)offsetof(FoundryApi_v2, render_draw_sprite),
    (uint64_t)offsetof(FoundryApi_v2, render_draw_text),
    (uint64_t)offsetof(FoundryApi_v2, render_add_view),
    (uint64_t)offsetof(FoundryApi_v2, render_select_view),
    (uint64_t)offsetof(FoundryApi_v2, render_camera_get),
    (uint64_t)offsetof(FoundryApi_v2, render_camera_set),
    (uint64_t)offsetof(FoundryApi_v2, render_world_to_screen),
    (uint64_t)offsetof(FoundryApi_v2, render_screen_to_world),
    (uint64_t)offsetof(FoundryApi_v2, render_stats),
    (uint64_t)offsetof(FoundryApi_v2, ui_begin),
    (uint64_t)offsetof(FoundryApi_v2, ui_end),
    (uint64_t)offsetof(FoundryApi_v2, ui_push_id),
    (uint64_t)offsetof(FoundryApi_v2, ui_pop_id),
    (uint64_t)offsetof(FoundryApi_v2, ui_begin_panel),
    (uint64_t)offsetof(FoundryApi_v2, ui_end_panel),
    (uint64_t)offsetof(FoundryApi_v2, ui_begin_row),
    (uint64_t)offsetof(FoundryApi_v2, ui_end_row),
    (uint64_t)offsetof(FoundryApi_v2, ui_begin_scroll),
    (uint64_t)offsetof(FoundryApi_v2, ui_end_scroll),
    (uint64_t)offsetof(FoundryApi_v2, ui_label),
    (uint64_t)offsetof(FoundryApi_v2, ui_button),
    (uint64_t)offsetof(FoundryApi_v2, ui_checkbox),
    (uint64_t)offsetof(FoundryApi_v2, ui_slider),
    (uint64_t)offsetof(FoundryApi_v2, ui_slider_int),
    (uint64_t)offsetof(FoundryApi_v2, ui_separator),
    (uint64_t)offsetof(FoundryApi_v2, ui_spacer),
    (uint64_t)offsetof(FoundryApi_v2, ui_collapsing_header),
    (uint64_t)offsetof(FoundryApi_v2, ui_text_field),
    (uint64_t)offsetof(FoundryApi_v2, ui_plot),
    (uint64_t)offsetof(FoundryApi_v2, ui_style_get),
    (uint64_t)offsetof(FoundryApi_v2, ui_style_set),
    (uint64_t)offsetof(FoundryApi_v2, ui_wants_keyboard),
    (uint64_t)offsetof(FoundryApi_v2, ui_wants_pointer),
    (uint64_t)offsetof(FoundryApi_v2, audio_play),
    (uint64_t)offsetof(FoundryApi_v2, audio_stop),
    (uint64_t)offsetof(FoundryApi_v2, audio_set_gain),
    (uint64_t)offsetof(FoundryApi_v2, audio_set_pan),
    (uint64_t)offsetof(FoundryApi_v2, audio_set_pitch),
    (uint64_t)offsetof(FoundryApi_v2, audio_set_master_gain),
    (uint64_t)offsetof(FoundryApi_v2, physics_create_body),
    (uint64_t)offsetof(FoundryApi_v2, physics_destroy_body),
    (uint64_t)offsetof(FoundryApi_v2, physics_move_body),
    (uint64_t)offsetof(FoundryApi_v2, physics_query_point),
    (uint64_t)offsetof(FoundryApi_v2, physics_query_aabb),
    (uint64_t)offsetof(FoundryApi_v2, physics_query_ray),
    (uint64_t)offsetof(FoundryApi_v2, physics_body_contacts),
    (uint64_t)offsetof(FoundryApi_v2, script_source_copy)
};

FOUNDRY_AGREE(sizeof(api_v2_names) / sizeof(api_v2_names[0]) ==
              sizeof(api_v2_offsets) / sizeof(api_v2_offsets[0]));
FOUNDRY_AGREE(sizeof(FoundryApi_v2) ==
              8 + 8 * (sizeof(api_v2_offsets) / sizeof(api_v2_offsets[0]) - 2));

uint64_t foundry_agreement_api_v2_size(void);
uint64_t foundry_agreement_api_v2_size(void)
{
    return (uint64_t)sizeof(FoundryApi_v2);
}

uint64_t foundry_agreement_api_v2_count(void);
uint64_t foundry_agreement_api_v2_count(void)
{
    return (uint64_t)(sizeof(api_v2_offsets) / sizeof(api_v2_offsets[0]));
}

uint64_t foundry_agreement_api_v2_offset(uint64_t index);
uint64_t foundry_agreement_api_v2_offset(uint64_t index)
{
    if (index >= foundry_agreement_api_v2_count()) return UINT64_MAX;
    return api_v2_offsets[index];
}

const char *foundry_agreement_api_v2_name(uint64_t index);
const char *foundry_agreement_api_v2_name(uint64_t index)
{
    if (index >= foundry_agreement_api_v2_count()) return NULL;
    return api_v2_names[index];
}


/* -- ABI v3 -------------------------------------------------------------------------- */

/* Assigning every addition to its independent C spelling makes a changed parameter a
 * compile error under `-Werror`, not merely a same-sized pointer in the layout checks. */
void foundry_agreement_api_v3_signatures(const FoundryApi_v3 *api);
void foundry_agreement_api_v3_signatures(const FoundryApi_v3 *api)
{
    FoundryResult (*installed_next)(FoundryCursor *, FoundryModInfo *) = api->mods_installed_next;
    FoundryResult (*pending_next)(FoundryCursor *, FoundryModPending *) = api->mods_pending_next;
    FoundryResult (*requirement_next)(FoundryContentId, FoundryCursor *, FoundryModRequirement *) =
        api->mods_requirement_next;
    FoundryResult (*conflict_next)(FoundryContentId, FoundryCursor *, FoundryModConflict *) = api->mods_conflict_next;
    FoundryResult (*provider_next)(FoundryContentId, FoundryCursor *, FoundryModProvider *) = api->mods_provider_next;
    FoundryResult (*profile_next)(FoundryCursor *, FoundryModProfile *) = api->mods_profile_next;
    FoundryResult (*profile_active)(FoundryModProfileState *) = api->mods_profile_active;
    FoundryResult (*set_enabled)(FoundryContentId, FoundryBool) = api->mods_set_enabled;
    FoundryResult (*move)(FoundryContentId, uint32_t) = api->mods_move;
    FoundryResult (*revert)(void) = api->mods_revert;
    FoundryResult (*apply)(void) = api->mods_apply;
    FoundryResult (*profile_create)(FoundryStr, uint32_t *) = api->mods_profile_create;
    FoundryResult (*profile_copy)(uint32_t, FoundryStr, uint32_t *) = api->mods_profile_copy;
    FoundryResult (*profile_rename)(uint32_t, FoundryStr) = api->mods_profile_rename;
    FoundryResult (*profile_delete)(uint32_t) = api->mods_profile_delete;
    FoundryResult (*profile_select)(uint32_t) = api->mods_profile_select;
    FoundryResult (*theme_resolve)(FoundryContentId, FoundryTheme *) = api->ui_theme_resolve;
    FoundryResult (*theme_push)(FoundryTheme) = api->ui_theme_push;
    FoundryResult (*theme_pop)(void) = api->ui_theme_pop;
    FoundryResult (*begin_disabled)(void) = api->ui_begin_disabled;
    FoundryResult (*end_disabled)(void) = api->ui_end_disabled;
    FoundryResult (*region_remaining)(FoundryUiRect *) = api->ui_region_remaining;
    FoundryResult (*tabs)(FoundryUiId, const FoundryStr *, uint32_t, uint32_t *) = api->ui_tabs;
    FoundryResult (*selectable)(FoundryUiId, FoundryStr, FoundryBool, FoundryBool *) = api->ui_selectable;
    FoundryResult (*reorder_list)(FoundryUiId, const FoundryUiRect *, uint32_t, FoundryUiReorderMove *) = api->ui_reorder_list;
    FoundryResult (*reorder_button)(FoundryUiId, FoundryStr, uint32_t, uint32_t,
                                    FoundryUiReorderDirection, FoundryUiReorderMove *) =
        api->ui_reorder_button;
    FoundryResult (*icon)(FoundryStr, FoundryUiVec2, FoundryUiColor, FoundryBool *) = api->ui_icon;
    FoundryResult (*image)(const FoundryUiImageSource *, FoundryUiVec2, FoundryUiColor) = api->ui_image;

    (void)installed_next;
    (void)pending_next;
    (void)requirement_next;
    (void)conflict_next;
    (void)provider_next;
    (void)profile_next;
    (void)profile_active;
    (void)set_enabled;
    (void)move;
    (void)revert;
    (void)apply;
    (void)profile_create;
    (void)profile_copy;
    (void)profile_rename;
    (void)profile_delete;
    (void)profile_select;
    (void)theme_resolve;
    (void)theme_push;
    (void)theme_pop;
    (void)begin_disabled;
    (void)end_disabled;
    (void)region_remaining;
    (void)tabs;
    (void)selectable;
    (void)reorder_list;
    (void)reorder_button;
    (void)icon;
    (void)image;
}

void foundry_agreement_api_v3_common_signatures(const FoundryApi_v3 *api);
void foundry_agreement_api_v3_common_signatures(const FoundryApi_v3 *api)
{
    FoundryApi_v2 common = {
        api->version,
        api->size,
        api->result_name,
        api->log_write,
        api->log_next,
        api->id_from_string,
        api->id_to_string,
        api->id_copy_string,
        api->frame_index,
        api->frame_delta_ns,
        api->elapsed_ns,
        api->tick_delta_ns,
        api->scope_begin,
        api->scope_end,
        api->memory_counter_open,
        api->memory_counter_set,
        api->content_generation,
        api->content_find,
        api->content_next,
        api->content_next_of_schema,
        api->record_id,
        api->record_name,
        api->record_schema,
        api->record_package,
        api->record_field_count,
        api->record_field_index,
        api->record_field_name,
        api->record_field_type,
        api->record_field_present,
        api->record_get_bool,
        api->record_get_i64,
        api->record_get_u64,
        api->record_get_f32,
        api->record_get_string,
        api->record_copy_string,
        api->record_get_id,
        api->record_nested,
        api->record_list_len,
        api->record_list_get_i64,
        api->record_list_get_f32,
        api->record_list_get_string,
        api->record_list_get_id,
        api->record_list_nested,
        api->package_count,
        api->package_next,
        api->package_find,
        api->package_id,
        api->package_name,
        api->package_version,
        api->package_order,
        api->schema_count,
        api->schema_next,
        api->schema_find,
        api->schema_id,
        api->schema_version,
        api->schema_field_count,
        api->schema_field_name,
        api->schema_field_type,
        api->asset_acquire,
        api->asset_release,
        api->asset_find,
        api->asset_next,
        api->asset_content_id,
        api->asset_schema,
        api->asset_refcount,
        api->world_register_component,
        api->world_find_component_type,
        api->world_component_type_next,
        api->world_component_type_schema,
        api->world_component_type_name,
        api->world_component_type_size,
        api->world_component_type_alignment,
        api->world_component_type_count,
        api->world_component_type_savable,
        api->world_create_entity,
        api->world_destroy_entity,
        api->world_contains,
        api->world_entity_count,
        api->world_next_entity,
        api->world_add_component,
        api->world_remove_component,
        api->world_has_component,
        api->world_register_system,
        api->world_query_begin,
        api->world_query_next,
        api->world_spawn,
        api->world_spawn_scene,
        api->world_read_component,
        api->world_component_bytes,
        api->render_texture_of_asset,
        api->render_destroy_texture,
        api->render_draw_sprite,
        api->render_draw_text,
        api->render_add_view,
        api->render_select_view,
        api->render_camera_get,
        api->render_camera_set,
        api->render_world_to_screen,
        api->render_screen_to_world,
        api->render_stats,
        api->ui_begin,
        api->ui_end,
        api->ui_push_id,
        api->ui_pop_id,
        api->ui_begin_panel,
        api->ui_end_panel,
        api->ui_begin_row,
        api->ui_end_row,
        api->ui_begin_scroll,
        api->ui_end_scroll,
        api->ui_label,
        api->ui_button,
        api->ui_checkbox,
        api->ui_slider,
        api->ui_slider_int,
        api->ui_separator,
        api->ui_spacer,
        api->ui_collapsing_header,
        api->ui_text_field,
        api->ui_plot,
        api->ui_style_get,
        api->ui_style_set,
        api->ui_wants_keyboard,
        api->ui_wants_pointer,
        api->audio_play,
        api->audio_stop,
        api->audio_set_gain,
        api->audio_set_pan,
        api->audio_set_pitch,
        api->audio_set_master_gain,
        api->physics_create_body,
        api->physics_destroy_body,
        api->physics_move_body,
        api->physics_query_point,
        api->physics_query_aabb,
        api->physics_query_ray,
        api->physics_body_contacts,
        api->script_source_copy
    };
    (void)common;
}

static const char *const api_v3_names[] = {
    "version",
    "size",
    "result_name",
    "log_write",
    "log_next",
    "id_from_string",
    "id_to_string",
    "id_copy_string",
    "frame_index",
    "frame_delta_ns",
    "elapsed_ns",
    "tick_delta_ns",
    "scope_begin",
    "scope_end",
    "memory_counter_open",
    "memory_counter_set",
    "content_generation",
    "content_find",
    "content_next",
    "content_next_of_schema",
    "record_id",
    "record_name",
    "record_schema",
    "record_package",
    "record_field_count",
    "record_field_index",
    "record_field_name",
    "record_field_type",
    "record_field_present",
    "record_get_bool",
    "record_get_i64",
    "record_get_u64",
    "record_get_f32",
    "record_get_string",
    "record_copy_string",
    "record_get_id",
    "record_nested",
    "record_list_len",
    "record_list_get_i64",
    "record_list_get_f32",
    "record_list_get_string",
    "record_list_get_id",
    "record_list_nested",
    "package_count",
    "package_next",
    "package_find",
    "package_id",
    "package_name",
    "package_version",
    "package_order",
    "schema_count",
    "schema_next",
    "schema_find",
    "schema_id",
    "schema_version",
    "schema_field_count",
    "schema_field_name",
    "schema_field_type",
    "asset_acquire",
    "asset_release",
    "asset_find",
    "asset_next",
    "asset_content_id",
    "asset_schema",
    "asset_refcount",
    "world_register_component",
    "world_find_component_type",
    "world_component_type_next",
    "world_component_type_schema",
    "world_component_type_name",
    "world_component_type_size",
    "world_component_type_alignment",
    "world_component_type_count",
    "world_component_type_savable",
    "world_create_entity",
    "world_destroy_entity",
    "world_contains",
    "world_entity_count",
    "world_next_entity",
    "world_add_component",
    "world_remove_component",
    "world_has_component",
    "world_register_system",
    "world_query_begin",
    "world_query_next",
    "world_spawn",
    "world_spawn_scene",
    "world_read_component",
    "world_component_bytes",
    "render_texture_of_asset",
    "render_destroy_texture",
    "render_draw_sprite",
    "render_draw_text",
    "render_add_view",
    "render_select_view",
    "render_camera_get",
    "render_camera_set",
    "render_world_to_screen",
    "render_screen_to_world",
    "render_stats",
    "ui_begin",
    "ui_end",
    "ui_push_id",
    "ui_pop_id",
    "ui_begin_panel",
    "ui_end_panel",
    "ui_begin_row",
    "ui_end_row",
    "ui_begin_scroll",
    "ui_end_scroll",
    "ui_label",
    "ui_button",
    "ui_checkbox",
    "ui_slider",
    "ui_slider_int",
    "ui_separator",
    "ui_spacer",
    "ui_collapsing_header",
    "ui_text_field",
    "ui_plot",
    "ui_style_get",
    "ui_style_set",
    "ui_wants_keyboard",
    "ui_wants_pointer",
    "audio_play",
    "audio_stop",
    "audio_set_gain",
    "audio_set_pan",
    "audio_set_pitch",
    "audio_set_master_gain",
    "physics_create_body",
    "physics_destroy_body",
    "physics_move_body",
    "physics_query_point",
    "physics_query_aabb",
    "physics_query_ray",
    "physics_body_contacts",
    "script_source_copy",
    "mods_installed_next",
    "mods_pending_next",
    "mods_requirement_next",
    "mods_conflict_next",
    "mods_provider_next",
    "mods_profile_next",
    "mods_profile_active",
    "mods_set_enabled",
    "mods_move",
    "mods_revert",
    "mods_apply",
    "mods_profile_create",
    "mods_profile_copy",
    "mods_profile_rename",
    "mods_profile_delete",
    "mods_profile_select",
    "ui_theme_resolve",
    "ui_theme_push",
    "ui_theme_pop",
    "ui_begin_disabled",
    "ui_end_disabled",
    "ui_region_remaining",
    "ui_tabs",
    "ui_selectable",
    "ui_reorder_list",
    "ui_reorder_button",
    "ui_icon",
    "ui_image"
};

static const uint64_t api_v3_offsets[] = {
    (uint64_t)offsetof(FoundryApi_v3, version),
    (uint64_t)offsetof(FoundryApi_v3, size),
    (uint64_t)offsetof(FoundryApi_v3, result_name),
    (uint64_t)offsetof(FoundryApi_v3, log_write),
    (uint64_t)offsetof(FoundryApi_v3, log_next),
    (uint64_t)offsetof(FoundryApi_v3, id_from_string),
    (uint64_t)offsetof(FoundryApi_v3, id_to_string),
    (uint64_t)offsetof(FoundryApi_v3, id_copy_string),
    (uint64_t)offsetof(FoundryApi_v3, frame_index),
    (uint64_t)offsetof(FoundryApi_v3, frame_delta_ns),
    (uint64_t)offsetof(FoundryApi_v3, elapsed_ns),
    (uint64_t)offsetof(FoundryApi_v3, tick_delta_ns),
    (uint64_t)offsetof(FoundryApi_v3, scope_begin),
    (uint64_t)offsetof(FoundryApi_v3, scope_end),
    (uint64_t)offsetof(FoundryApi_v3, memory_counter_open),
    (uint64_t)offsetof(FoundryApi_v3, memory_counter_set),
    (uint64_t)offsetof(FoundryApi_v3, content_generation),
    (uint64_t)offsetof(FoundryApi_v3, content_find),
    (uint64_t)offsetof(FoundryApi_v3, content_next),
    (uint64_t)offsetof(FoundryApi_v3, content_next_of_schema),
    (uint64_t)offsetof(FoundryApi_v3, record_id),
    (uint64_t)offsetof(FoundryApi_v3, record_name),
    (uint64_t)offsetof(FoundryApi_v3, record_schema),
    (uint64_t)offsetof(FoundryApi_v3, record_package),
    (uint64_t)offsetof(FoundryApi_v3, record_field_count),
    (uint64_t)offsetof(FoundryApi_v3, record_field_index),
    (uint64_t)offsetof(FoundryApi_v3, record_field_name),
    (uint64_t)offsetof(FoundryApi_v3, record_field_type),
    (uint64_t)offsetof(FoundryApi_v3, record_field_present),
    (uint64_t)offsetof(FoundryApi_v3, record_get_bool),
    (uint64_t)offsetof(FoundryApi_v3, record_get_i64),
    (uint64_t)offsetof(FoundryApi_v3, record_get_u64),
    (uint64_t)offsetof(FoundryApi_v3, record_get_f32),
    (uint64_t)offsetof(FoundryApi_v3, record_get_string),
    (uint64_t)offsetof(FoundryApi_v3, record_copy_string),
    (uint64_t)offsetof(FoundryApi_v3, record_get_id),
    (uint64_t)offsetof(FoundryApi_v3, record_nested),
    (uint64_t)offsetof(FoundryApi_v3, record_list_len),
    (uint64_t)offsetof(FoundryApi_v3, record_list_get_i64),
    (uint64_t)offsetof(FoundryApi_v3, record_list_get_f32),
    (uint64_t)offsetof(FoundryApi_v3, record_list_get_string),
    (uint64_t)offsetof(FoundryApi_v3, record_list_get_id),
    (uint64_t)offsetof(FoundryApi_v3, record_list_nested),
    (uint64_t)offsetof(FoundryApi_v3, package_count),
    (uint64_t)offsetof(FoundryApi_v3, package_next),
    (uint64_t)offsetof(FoundryApi_v3, package_find),
    (uint64_t)offsetof(FoundryApi_v3, package_id),
    (uint64_t)offsetof(FoundryApi_v3, package_name),
    (uint64_t)offsetof(FoundryApi_v3, package_version),
    (uint64_t)offsetof(FoundryApi_v3, package_order),
    (uint64_t)offsetof(FoundryApi_v3, schema_count),
    (uint64_t)offsetof(FoundryApi_v3, schema_next),
    (uint64_t)offsetof(FoundryApi_v3, schema_find),
    (uint64_t)offsetof(FoundryApi_v3, schema_id),
    (uint64_t)offsetof(FoundryApi_v3, schema_version),
    (uint64_t)offsetof(FoundryApi_v3, schema_field_count),
    (uint64_t)offsetof(FoundryApi_v3, schema_field_name),
    (uint64_t)offsetof(FoundryApi_v3, schema_field_type),
    (uint64_t)offsetof(FoundryApi_v3, asset_acquire),
    (uint64_t)offsetof(FoundryApi_v3, asset_release),
    (uint64_t)offsetof(FoundryApi_v3, asset_find),
    (uint64_t)offsetof(FoundryApi_v3, asset_next),
    (uint64_t)offsetof(FoundryApi_v3, asset_content_id),
    (uint64_t)offsetof(FoundryApi_v3, asset_schema),
    (uint64_t)offsetof(FoundryApi_v3, asset_refcount),
    (uint64_t)offsetof(FoundryApi_v3, world_register_component),
    (uint64_t)offsetof(FoundryApi_v3, world_find_component_type),
    (uint64_t)offsetof(FoundryApi_v3, world_component_type_next),
    (uint64_t)offsetof(FoundryApi_v3, world_component_type_schema),
    (uint64_t)offsetof(FoundryApi_v3, world_component_type_name),
    (uint64_t)offsetof(FoundryApi_v3, world_component_type_size),
    (uint64_t)offsetof(FoundryApi_v3, world_component_type_alignment),
    (uint64_t)offsetof(FoundryApi_v3, world_component_type_count),
    (uint64_t)offsetof(FoundryApi_v3, world_component_type_savable),
    (uint64_t)offsetof(FoundryApi_v3, world_create_entity),
    (uint64_t)offsetof(FoundryApi_v3, world_destroy_entity),
    (uint64_t)offsetof(FoundryApi_v3, world_contains),
    (uint64_t)offsetof(FoundryApi_v3, world_entity_count),
    (uint64_t)offsetof(FoundryApi_v3, world_next_entity),
    (uint64_t)offsetof(FoundryApi_v3, world_add_component),
    (uint64_t)offsetof(FoundryApi_v3, world_remove_component),
    (uint64_t)offsetof(FoundryApi_v3, world_has_component),
    (uint64_t)offsetof(FoundryApi_v3, world_register_system),
    (uint64_t)offsetof(FoundryApi_v3, world_query_begin),
    (uint64_t)offsetof(FoundryApi_v3, world_query_next),
    (uint64_t)offsetof(FoundryApi_v3, world_spawn),
    (uint64_t)offsetof(FoundryApi_v3, world_spawn_scene),
    (uint64_t)offsetof(FoundryApi_v3, world_read_component),
    (uint64_t)offsetof(FoundryApi_v3, world_component_bytes),
    (uint64_t)offsetof(FoundryApi_v3, render_texture_of_asset),
    (uint64_t)offsetof(FoundryApi_v3, render_destroy_texture),
    (uint64_t)offsetof(FoundryApi_v3, render_draw_sprite),
    (uint64_t)offsetof(FoundryApi_v3, render_draw_text),
    (uint64_t)offsetof(FoundryApi_v3, render_add_view),
    (uint64_t)offsetof(FoundryApi_v3, render_select_view),
    (uint64_t)offsetof(FoundryApi_v3, render_camera_get),
    (uint64_t)offsetof(FoundryApi_v3, render_camera_set),
    (uint64_t)offsetof(FoundryApi_v3, render_world_to_screen),
    (uint64_t)offsetof(FoundryApi_v3, render_screen_to_world),
    (uint64_t)offsetof(FoundryApi_v3, render_stats),
    (uint64_t)offsetof(FoundryApi_v3, ui_begin),
    (uint64_t)offsetof(FoundryApi_v3, ui_end),
    (uint64_t)offsetof(FoundryApi_v3, ui_push_id),
    (uint64_t)offsetof(FoundryApi_v3, ui_pop_id),
    (uint64_t)offsetof(FoundryApi_v3, ui_begin_panel),
    (uint64_t)offsetof(FoundryApi_v3, ui_end_panel),
    (uint64_t)offsetof(FoundryApi_v3, ui_begin_row),
    (uint64_t)offsetof(FoundryApi_v3, ui_end_row),
    (uint64_t)offsetof(FoundryApi_v3, ui_begin_scroll),
    (uint64_t)offsetof(FoundryApi_v3, ui_end_scroll),
    (uint64_t)offsetof(FoundryApi_v3, ui_label),
    (uint64_t)offsetof(FoundryApi_v3, ui_button),
    (uint64_t)offsetof(FoundryApi_v3, ui_checkbox),
    (uint64_t)offsetof(FoundryApi_v3, ui_slider),
    (uint64_t)offsetof(FoundryApi_v3, ui_slider_int),
    (uint64_t)offsetof(FoundryApi_v3, ui_separator),
    (uint64_t)offsetof(FoundryApi_v3, ui_spacer),
    (uint64_t)offsetof(FoundryApi_v3, ui_collapsing_header),
    (uint64_t)offsetof(FoundryApi_v3, ui_text_field),
    (uint64_t)offsetof(FoundryApi_v3, ui_plot),
    (uint64_t)offsetof(FoundryApi_v3, ui_style_get),
    (uint64_t)offsetof(FoundryApi_v3, ui_style_set),
    (uint64_t)offsetof(FoundryApi_v3, ui_wants_keyboard),
    (uint64_t)offsetof(FoundryApi_v3, ui_wants_pointer),
    (uint64_t)offsetof(FoundryApi_v3, audio_play),
    (uint64_t)offsetof(FoundryApi_v3, audio_stop),
    (uint64_t)offsetof(FoundryApi_v3, audio_set_gain),
    (uint64_t)offsetof(FoundryApi_v3, audio_set_pan),
    (uint64_t)offsetof(FoundryApi_v3, audio_set_pitch),
    (uint64_t)offsetof(FoundryApi_v3, audio_set_master_gain),
    (uint64_t)offsetof(FoundryApi_v3, physics_create_body),
    (uint64_t)offsetof(FoundryApi_v3, physics_destroy_body),
    (uint64_t)offsetof(FoundryApi_v3, physics_move_body),
    (uint64_t)offsetof(FoundryApi_v3, physics_query_point),
    (uint64_t)offsetof(FoundryApi_v3, physics_query_aabb),
    (uint64_t)offsetof(FoundryApi_v3, physics_query_ray),
    (uint64_t)offsetof(FoundryApi_v3, physics_body_contacts),
    (uint64_t)offsetof(FoundryApi_v3, script_source_copy),
    (uint64_t)offsetof(FoundryApi_v3, mods_installed_next),
    (uint64_t)offsetof(FoundryApi_v3, mods_pending_next),
    (uint64_t)offsetof(FoundryApi_v3, mods_requirement_next),
    (uint64_t)offsetof(FoundryApi_v3, mods_conflict_next),
    (uint64_t)offsetof(FoundryApi_v3, mods_provider_next),
    (uint64_t)offsetof(FoundryApi_v3, mods_profile_next),
    (uint64_t)offsetof(FoundryApi_v3, mods_profile_active),
    (uint64_t)offsetof(FoundryApi_v3, mods_set_enabled),
    (uint64_t)offsetof(FoundryApi_v3, mods_move),
    (uint64_t)offsetof(FoundryApi_v3, mods_revert),
    (uint64_t)offsetof(FoundryApi_v3, mods_apply),
    (uint64_t)offsetof(FoundryApi_v3, mods_profile_create),
    (uint64_t)offsetof(FoundryApi_v3, mods_profile_copy),
    (uint64_t)offsetof(FoundryApi_v3, mods_profile_rename),
    (uint64_t)offsetof(FoundryApi_v3, mods_profile_delete),
    (uint64_t)offsetof(FoundryApi_v3, mods_profile_select),
    (uint64_t)offsetof(FoundryApi_v3, ui_theme_resolve),
    (uint64_t)offsetof(FoundryApi_v3, ui_theme_push),
    (uint64_t)offsetof(FoundryApi_v3, ui_theme_pop),
    (uint64_t)offsetof(FoundryApi_v3, ui_begin_disabled),
    (uint64_t)offsetof(FoundryApi_v3, ui_end_disabled),
    (uint64_t)offsetof(FoundryApi_v3, ui_region_remaining),
    (uint64_t)offsetof(FoundryApi_v3, ui_tabs),
    (uint64_t)offsetof(FoundryApi_v3, ui_selectable),
    (uint64_t)offsetof(FoundryApi_v3, ui_reorder_list),
    (uint64_t)offsetof(FoundryApi_v3, ui_reorder_button),
    (uint64_t)offsetof(FoundryApi_v3, ui_icon),
    (uint64_t)offsetof(FoundryApi_v3, ui_image)
};

FOUNDRY_AGREE(sizeof(api_v3_names) / sizeof(api_v3_names[0]) ==
              sizeof(api_v3_offsets) / sizeof(api_v3_offsets[0]));
FOUNDRY_AGREE(sizeof(FoundryApi_v3) ==
              8 + 8 * (sizeof(api_v3_offsets) / sizeof(api_v3_offsets[0]) - 2));

uint64_t foundry_agreement_api_v3_size(void);
uint64_t foundry_agreement_api_v3_size(void)
{
    return (uint64_t)sizeof(FoundryApi_v3);
}

uint64_t foundry_agreement_api_v3_count(void);
uint64_t foundry_agreement_api_v3_count(void)
{
    return (uint64_t)(sizeof(api_v3_offsets) / sizeof(api_v3_offsets[0]));
}

uint64_t foundry_agreement_api_v3_offset(uint64_t index);
uint64_t foundry_agreement_api_v3_offset(uint64_t index)
{
    if (index >= foundry_agreement_api_v3_count()) return UINT64_MAX;
    return api_v3_offsets[index];
}

const char *foundry_agreement_api_v3_name(uint64_t index);
const char *foundry_agreement_api_v3_name(uint64_t index)
{
    if (index >= foundry_agreement_api_v3_count()) return NULL;
    return api_v3_names[index];
}

/* -- ABI v4 -------------------------------------------------------------------------- */
/* Positional initialization type-checks every common v4 member against v3 without
 * `typeof`, casts, or a non-C99 extension. A signature drift in either table is an
 * incompatible-pointer diagnostic under the build's `-Werror`. */
void foundry_agreement_api_v4_common_signatures(const FoundryApi_v4 *api);
void foundry_agreement_api_v4_common_signatures(const FoundryApi_v4 *api)
{
    FoundryApi_v3 common = {
        api->version,
        api->size,
        api->result_name,
        api->log_write,
        api->log_next,
        api->id_from_string,
        api->id_to_string,
        api->id_copy_string,
        api->frame_index,
        api->frame_delta_ns,
        api->elapsed_ns,
        api->tick_delta_ns,
        api->scope_begin,
        api->scope_end,
        api->memory_counter_open,
        api->memory_counter_set,
        api->content_generation,
        api->content_find,
        api->content_next,
        api->content_next_of_schema,
        api->record_id,
        api->record_name,
        api->record_schema,
        api->record_package,
        api->record_field_count,
        api->record_field_index,
        api->record_field_name,
        api->record_field_type,
        api->record_field_present,
        api->record_get_bool,
        api->record_get_i64,
        api->record_get_u64,
        api->record_get_f32,
        api->record_get_string,
        api->record_copy_string,
        api->record_get_id,
        api->record_nested,
        api->record_list_len,
        api->record_list_get_i64,
        api->record_list_get_f32,
        api->record_list_get_string,
        api->record_list_get_id,
        api->record_list_nested,
        api->package_count,
        api->package_next,
        api->package_find,
        api->package_id,
        api->package_name,
        api->package_version,
        api->package_order,
        api->schema_count,
        api->schema_next,
        api->schema_find,
        api->schema_id,
        api->schema_version,
        api->schema_field_count,
        api->schema_field_name,
        api->schema_field_type,
        api->asset_acquire,
        api->asset_release,
        api->asset_find,
        api->asset_next,
        api->asset_content_id,
        api->asset_schema,
        api->asset_refcount,
        api->world_register_component,
        api->world_find_component_type,
        api->world_component_type_next,
        api->world_component_type_schema,
        api->world_component_type_name,
        api->world_component_type_size,
        api->world_component_type_alignment,
        api->world_component_type_count,
        api->world_component_type_savable,
        api->world_create_entity,
        api->world_destroy_entity,
        api->world_contains,
        api->world_entity_count,
        api->world_next_entity,
        api->world_add_component,
        api->world_remove_component,
        api->world_has_component,
        api->world_register_system,
        api->world_query_begin,
        api->world_query_next,
        api->world_spawn,
        api->world_spawn_scene,
        api->world_read_component,
        api->world_component_bytes,
        api->render_texture_of_asset,
        api->render_destroy_texture,
        api->render_draw_sprite,
        api->render_draw_text,
        api->render_add_view,
        api->render_select_view,
        api->render_camera_get,
        api->render_camera_set,
        api->render_world_to_screen,
        api->render_screen_to_world,
        api->render_stats,
        api->ui_begin,
        api->ui_end,
        api->ui_push_id,
        api->ui_pop_id,
        api->ui_begin_panel,
        api->ui_end_panel,
        api->ui_begin_row,
        api->ui_end_row,
        api->ui_begin_scroll,
        api->ui_end_scroll,
        api->ui_label,
        api->ui_button,
        api->ui_checkbox,
        api->ui_slider,
        api->ui_slider_int,
        api->ui_separator,
        api->ui_spacer,
        api->ui_collapsing_header,
        api->ui_text_field,
        api->ui_plot,
        api->ui_style_get,
        api->ui_style_set,
        api->ui_wants_keyboard,
        api->ui_wants_pointer,
        api->audio_play,
        api->audio_stop,
        api->audio_set_gain,
        api->audio_set_pan,
        api->audio_set_pitch,
        api->audio_set_master_gain,
        api->physics_create_body,
        api->physics_destroy_body,
        api->physics_move_body,
        api->physics_query_point,
        api->physics_query_aabb,
        api->physics_query_ray,
        api->physics_body_contacts,
        api->script_source_copy,
        api->mods_installed_next,
        api->mods_pending_next,
        api->mods_requirement_next,
        api->mods_conflict_next,
        api->mods_provider_next,
        api->mods_profile_next,
        api->mods_profile_active,
        api->mods_set_enabled,
        api->mods_move,
        api->mods_revert,
        api->mods_apply,
        api->mods_profile_create,
        api->mods_profile_copy,
        api->mods_profile_rename,
        api->mods_profile_delete,
        api->mods_profile_select,
        api->ui_theme_resolve,
        api->ui_theme_push,
        api->ui_theme_pop,
        api->ui_begin_disabled,
        api->ui_end_disabled,
        api->ui_region_remaining,
        api->ui_tabs,
        api->ui_selectable,
        api->ui_reorder_list,
        api->ui_reorder_button,
        api->ui_icon,
        api->ui_image
    };
    (void)common;
}

/* The authoring tail's shapes, stated once each, the way v2 states `script_source_copy`.
 * Five of the forty-seven: the ones whose parameter lists are long enough that a drift
 * between this header and the engine's Zig declarations would otherwise be found by a
 * client. Assigning to a typedef makes it an incompatible-pointer diagnostic under the
 * build's `-Werror`. */
typedef FoundryResult (*foundry_agree_author_duplicate_fn)(
    FoundrySourceNode, FoundryDocument, uint64_t, FoundryStr, FoundryAuthorEdit *);
typedef FoundryResult (*foundry_agree_author_list_insert_fn)(
    FoundrySourceNode, uint64_t, uint32_t, const FoundryAuthorValue *, FoundryAuthorEdit *);
typedef FoundryResult (*foundry_agree_author_copy_text_fn)(
    FoundrySourceNode, uint8_t *, uint64_t, uint64_t *);
typedef FoundryResult (*foundry_agree_author_export_fn)(FoundryBuild, uint32_t, uint32_t *);
typedef FoundryResult (*foundry_agree_author_dependency_record_fn)(
    FoundryWorkspace, uint32_t, FoundryCursor *, FoundrySourceNode *);

void foundry_agreement_api_v4_author_signatures(const FoundryApi_v4 *api);
void foundry_agreement_api_v4_author_signatures(const FoundryApi_v4 *api)
{
    foundry_agree_author_duplicate_fn duplicate = api->author_record_duplicate;
    foundry_agree_author_list_insert_fn insert = api->author_list_insert;
    foundry_agree_author_copy_text_fn copy_text = api->author_node_copy_text;
    foundry_agree_author_export_fn export_build = api->author_build_export;
    foundry_agree_author_dependency_record_fn dependency = api->author_dependency_record_next;
    (void)duplicate;
    (void)insert;
    (void)copy_text;
    (void)export_build;
    (void)dependency;
}

static const char *const api_v4_names[] = {
    "version",
    "size",
    "result_name",
    "log_write",
    "log_next",
    "id_from_string",
    "id_to_string",
    "id_copy_string",
    "frame_index",
    "frame_delta_ns",
    "elapsed_ns",
    "tick_delta_ns",
    "scope_begin",
    "scope_end",
    "memory_counter_open",
    "memory_counter_set",
    "content_generation",
    "content_find",
    "content_next",
    "content_next_of_schema",
    "record_id",
    "record_name",
    "record_schema",
    "record_package",
    "record_field_count",
    "record_field_index",
    "record_field_name",
    "record_field_type",
    "record_field_present",
    "record_get_bool",
    "record_get_i64",
    "record_get_u64",
    "record_get_f32",
    "record_get_string",
    "record_copy_string",
    "record_get_id",
    "record_nested",
    "record_list_len",
    "record_list_get_i64",
    "record_list_get_f32",
    "record_list_get_string",
    "record_list_get_id",
    "record_list_nested",
    "package_count",
    "package_next",
    "package_find",
    "package_id",
    "package_name",
    "package_version",
    "package_order",
    "schema_count",
    "schema_next",
    "schema_find",
    "schema_id",
    "schema_version",
    "schema_field_count",
    "schema_field_name",
    "schema_field_type",
    "asset_acquire",
    "asset_release",
    "asset_find",
    "asset_next",
    "asset_content_id",
    "asset_schema",
    "asset_refcount",
    "world_register_component",
    "world_find_component_type",
    "world_component_type_next",
    "world_component_type_schema",
    "world_component_type_name",
    "world_component_type_size",
    "world_component_type_alignment",
    "world_component_type_count",
    "world_component_type_savable",
    "world_create_entity",
    "world_destroy_entity",
    "world_contains",
    "world_entity_count",
    "world_next_entity",
    "world_add_component",
    "world_remove_component",
    "world_has_component",
    "world_register_system",
    "world_query_begin",
    "world_query_next",
    "world_spawn",
    "world_spawn_scene",
    "world_read_component",
    "world_component_bytes",
    "render_texture_of_asset",
    "render_destroy_texture",
    "render_draw_sprite",
    "render_draw_text",
    "render_add_view",
    "render_select_view",
    "render_camera_get",
    "render_camera_set",
    "render_world_to_screen",
    "render_screen_to_world",
    "render_stats",
    "ui_begin",
    "ui_end",
    "ui_push_id",
    "ui_pop_id",
    "ui_begin_panel",
    "ui_end_panel",
    "ui_begin_row",
    "ui_end_row",
    "ui_begin_scroll",
    "ui_end_scroll",
    "ui_label",
    "ui_button",
    "ui_checkbox",
    "ui_slider",
    "ui_slider_int",
    "ui_separator",
    "ui_spacer",
    "ui_collapsing_header",
    "ui_text_field",
    "ui_plot",
    "ui_style_get",
    "ui_style_set",
    "ui_wants_keyboard",
    "ui_wants_pointer",
    "audio_play",
    "audio_stop",
    "audio_set_gain",
    "audio_set_pan",
    "audio_set_pitch",
    "audio_set_master_gain",
    "physics_create_body",
    "physics_destroy_body",
    "physics_move_body",
    "physics_query_point",
    "physics_query_aabb",
    "physics_query_ray",
    "physics_body_contacts",
    "script_source_copy",
    "mods_installed_next",
    "mods_pending_next",
    "mods_requirement_next",
    "mods_conflict_next",
    "mods_provider_next",
    "mods_profile_next",
    "mods_profile_active",
    "mods_set_enabled",
    "mods_move",
    "mods_revert",
    "mods_apply",
    "mods_profile_create",
    "mods_profile_copy",
    "mods_profile_rename",
    "mods_profile_delete",
    "mods_profile_select",
    "ui_theme_resolve",
    "ui_theme_push",
    "ui_theme_pop",
    "ui_begin_disabled",
    "ui_end_disabled",
    "ui_region_remaining",
    "ui_tabs",
    "ui_selectable",
    "ui_reorder_list",
    "ui_reorder_button",
    "ui_icon",
    "ui_image",
    "author_workspace_next",
    "author_workspace_info",
    "author_workspace_revision",
    "author_workspace_limits",
    "author_document_next",
    "author_document_info",
    "author_document_create",
    "author_document_refresh",
    "author_document_discard",
    "author_document_copy_source",
    "author_schema_next",
    "author_schema_find",
    "author_schema_node_info",
    "author_schema_node_child",
    "author_schema_node_default",
    "author_record_next",
    "author_dependency_next",
    "author_dependency_record_next",
    "author_preview_record_next",
    "author_node_info",
    "author_node_child",
    "author_node_field",
    "author_node_scalar",
    "author_node_copy_text",
    "author_record_create",
    "author_record_duplicate",
    "author_record_override",
    "author_record_delete",
    "author_value_set",
    "author_value_unset",
    "author_list_insert",
    "author_list_remove",
    "author_list_move",
    "author_undo",
    "author_redo",
    "author_save_document",
    "author_save_all",
    "author_save_entry_next",
    "author_validate",
    "author_diagnostic_next",
    "author_build",
    "author_build_info",
    "author_build_release",
    "author_export_next",
    "author_build_export",
    "author_preview_activate",
    "author_preview_info"
};

static const uint64_t api_v4_offsets[] = {
    (uint64_t)offsetof(FoundryApi_v4, version),
    (uint64_t)offsetof(FoundryApi_v4, size),
    (uint64_t)offsetof(FoundryApi_v4, result_name),
    (uint64_t)offsetof(FoundryApi_v4, log_write),
    (uint64_t)offsetof(FoundryApi_v4, log_next),
    (uint64_t)offsetof(FoundryApi_v4, id_from_string),
    (uint64_t)offsetof(FoundryApi_v4, id_to_string),
    (uint64_t)offsetof(FoundryApi_v4, id_copy_string),
    (uint64_t)offsetof(FoundryApi_v4, frame_index),
    (uint64_t)offsetof(FoundryApi_v4, frame_delta_ns),
    (uint64_t)offsetof(FoundryApi_v4, elapsed_ns),
    (uint64_t)offsetof(FoundryApi_v4, tick_delta_ns),
    (uint64_t)offsetof(FoundryApi_v4, scope_begin),
    (uint64_t)offsetof(FoundryApi_v4, scope_end),
    (uint64_t)offsetof(FoundryApi_v4, memory_counter_open),
    (uint64_t)offsetof(FoundryApi_v4, memory_counter_set),
    (uint64_t)offsetof(FoundryApi_v4, content_generation),
    (uint64_t)offsetof(FoundryApi_v4, content_find),
    (uint64_t)offsetof(FoundryApi_v4, content_next),
    (uint64_t)offsetof(FoundryApi_v4, content_next_of_schema),
    (uint64_t)offsetof(FoundryApi_v4, record_id),
    (uint64_t)offsetof(FoundryApi_v4, record_name),
    (uint64_t)offsetof(FoundryApi_v4, record_schema),
    (uint64_t)offsetof(FoundryApi_v4, record_package),
    (uint64_t)offsetof(FoundryApi_v4, record_field_count),
    (uint64_t)offsetof(FoundryApi_v4, record_field_index),
    (uint64_t)offsetof(FoundryApi_v4, record_field_name),
    (uint64_t)offsetof(FoundryApi_v4, record_field_type),
    (uint64_t)offsetof(FoundryApi_v4, record_field_present),
    (uint64_t)offsetof(FoundryApi_v4, record_get_bool),
    (uint64_t)offsetof(FoundryApi_v4, record_get_i64),
    (uint64_t)offsetof(FoundryApi_v4, record_get_u64),
    (uint64_t)offsetof(FoundryApi_v4, record_get_f32),
    (uint64_t)offsetof(FoundryApi_v4, record_get_string),
    (uint64_t)offsetof(FoundryApi_v4, record_copy_string),
    (uint64_t)offsetof(FoundryApi_v4, record_get_id),
    (uint64_t)offsetof(FoundryApi_v4, record_nested),
    (uint64_t)offsetof(FoundryApi_v4, record_list_len),
    (uint64_t)offsetof(FoundryApi_v4, record_list_get_i64),
    (uint64_t)offsetof(FoundryApi_v4, record_list_get_f32),
    (uint64_t)offsetof(FoundryApi_v4, record_list_get_string),
    (uint64_t)offsetof(FoundryApi_v4, record_list_get_id),
    (uint64_t)offsetof(FoundryApi_v4, record_list_nested),
    (uint64_t)offsetof(FoundryApi_v4, package_count),
    (uint64_t)offsetof(FoundryApi_v4, package_next),
    (uint64_t)offsetof(FoundryApi_v4, package_find),
    (uint64_t)offsetof(FoundryApi_v4, package_id),
    (uint64_t)offsetof(FoundryApi_v4, package_name),
    (uint64_t)offsetof(FoundryApi_v4, package_version),
    (uint64_t)offsetof(FoundryApi_v4, package_order),
    (uint64_t)offsetof(FoundryApi_v4, schema_count),
    (uint64_t)offsetof(FoundryApi_v4, schema_next),
    (uint64_t)offsetof(FoundryApi_v4, schema_find),
    (uint64_t)offsetof(FoundryApi_v4, schema_id),
    (uint64_t)offsetof(FoundryApi_v4, schema_version),
    (uint64_t)offsetof(FoundryApi_v4, schema_field_count),
    (uint64_t)offsetof(FoundryApi_v4, schema_field_name),
    (uint64_t)offsetof(FoundryApi_v4, schema_field_type),
    (uint64_t)offsetof(FoundryApi_v4, asset_acquire),
    (uint64_t)offsetof(FoundryApi_v4, asset_release),
    (uint64_t)offsetof(FoundryApi_v4, asset_find),
    (uint64_t)offsetof(FoundryApi_v4, asset_next),
    (uint64_t)offsetof(FoundryApi_v4, asset_content_id),
    (uint64_t)offsetof(FoundryApi_v4, asset_schema),
    (uint64_t)offsetof(FoundryApi_v4, asset_refcount),
    (uint64_t)offsetof(FoundryApi_v4, world_register_component),
    (uint64_t)offsetof(FoundryApi_v4, world_find_component_type),
    (uint64_t)offsetof(FoundryApi_v4, world_component_type_next),
    (uint64_t)offsetof(FoundryApi_v4, world_component_type_schema),
    (uint64_t)offsetof(FoundryApi_v4, world_component_type_name),
    (uint64_t)offsetof(FoundryApi_v4, world_component_type_size),
    (uint64_t)offsetof(FoundryApi_v4, world_component_type_alignment),
    (uint64_t)offsetof(FoundryApi_v4, world_component_type_count),
    (uint64_t)offsetof(FoundryApi_v4, world_component_type_savable),
    (uint64_t)offsetof(FoundryApi_v4, world_create_entity),
    (uint64_t)offsetof(FoundryApi_v4, world_destroy_entity),
    (uint64_t)offsetof(FoundryApi_v4, world_contains),
    (uint64_t)offsetof(FoundryApi_v4, world_entity_count),
    (uint64_t)offsetof(FoundryApi_v4, world_next_entity),
    (uint64_t)offsetof(FoundryApi_v4, world_add_component),
    (uint64_t)offsetof(FoundryApi_v4, world_remove_component),
    (uint64_t)offsetof(FoundryApi_v4, world_has_component),
    (uint64_t)offsetof(FoundryApi_v4, world_register_system),
    (uint64_t)offsetof(FoundryApi_v4, world_query_begin),
    (uint64_t)offsetof(FoundryApi_v4, world_query_next),
    (uint64_t)offsetof(FoundryApi_v4, world_spawn),
    (uint64_t)offsetof(FoundryApi_v4, world_spawn_scene),
    (uint64_t)offsetof(FoundryApi_v4, world_read_component),
    (uint64_t)offsetof(FoundryApi_v4, world_component_bytes),
    (uint64_t)offsetof(FoundryApi_v4, render_texture_of_asset),
    (uint64_t)offsetof(FoundryApi_v4, render_destroy_texture),
    (uint64_t)offsetof(FoundryApi_v4, render_draw_sprite),
    (uint64_t)offsetof(FoundryApi_v4, render_draw_text),
    (uint64_t)offsetof(FoundryApi_v4, render_add_view),
    (uint64_t)offsetof(FoundryApi_v4, render_select_view),
    (uint64_t)offsetof(FoundryApi_v4, render_camera_get),
    (uint64_t)offsetof(FoundryApi_v4, render_camera_set),
    (uint64_t)offsetof(FoundryApi_v4, render_world_to_screen),
    (uint64_t)offsetof(FoundryApi_v4, render_screen_to_world),
    (uint64_t)offsetof(FoundryApi_v4, render_stats),
    (uint64_t)offsetof(FoundryApi_v4, ui_begin),
    (uint64_t)offsetof(FoundryApi_v4, ui_end),
    (uint64_t)offsetof(FoundryApi_v4, ui_push_id),
    (uint64_t)offsetof(FoundryApi_v4, ui_pop_id),
    (uint64_t)offsetof(FoundryApi_v4, ui_begin_panel),
    (uint64_t)offsetof(FoundryApi_v4, ui_end_panel),
    (uint64_t)offsetof(FoundryApi_v4, ui_begin_row),
    (uint64_t)offsetof(FoundryApi_v4, ui_end_row),
    (uint64_t)offsetof(FoundryApi_v4, ui_begin_scroll),
    (uint64_t)offsetof(FoundryApi_v4, ui_end_scroll),
    (uint64_t)offsetof(FoundryApi_v4, ui_label),
    (uint64_t)offsetof(FoundryApi_v4, ui_button),
    (uint64_t)offsetof(FoundryApi_v4, ui_checkbox),
    (uint64_t)offsetof(FoundryApi_v4, ui_slider),
    (uint64_t)offsetof(FoundryApi_v4, ui_slider_int),
    (uint64_t)offsetof(FoundryApi_v4, ui_separator),
    (uint64_t)offsetof(FoundryApi_v4, ui_spacer),
    (uint64_t)offsetof(FoundryApi_v4, ui_collapsing_header),
    (uint64_t)offsetof(FoundryApi_v4, ui_text_field),
    (uint64_t)offsetof(FoundryApi_v4, ui_plot),
    (uint64_t)offsetof(FoundryApi_v4, ui_style_get),
    (uint64_t)offsetof(FoundryApi_v4, ui_style_set),
    (uint64_t)offsetof(FoundryApi_v4, ui_wants_keyboard),
    (uint64_t)offsetof(FoundryApi_v4, ui_wants_pointer),
    (uint64_t)offsetof(FoundryApi_v4, audio_play),
    (uint64_t)offsetof(FoundryApi_v4, audio_stop),
    (uint64_t)offsetof(FoundryApi_v4, audio_set_gain),
    (uint64_t)offsetof(FoundryApi_v4, audio_set_pan),
    (uint64_t)offsetof(FoundryApi_v4, audio_set_pitch),
    (uint64_t)offsetof(FoundryApi_v4, audio_set_master_gain),
    (uint64_t)offsetof(FoundryApi_v4, physics_create_body),
    (uint64_t)offsetof(FoundryApi_v4, physics_destroy_body),
    (uint64_t)offsetof(FoundryApi_v4, physics_move_body),
    (uint64_t)offsetof(FoundryApi_v4, physics_query_point),
    (uint64_t)offsetof(FoundryApi_v4, physics_query_aabb),
    (uint64_t)offsetof(FoundryApi_v4, physics_query_ray),
    (uint64_t)offsetof(FoundryApi_v4, physics_body_contacts),
    (uint64_t)offsetof(FoundryApi_v4, script_source_copy),
    (uint64_t)offsetof(FoundryApi_v4, mods_installed_next),
    (uint64_t)offsetof(FoundryApi_v4, mods_pending_next),
    (uint64_t)offsetof(FoundryApi_v4, mods_requirement_next),
    (uint64_t)offsetof(FoundryApi_v4, mods_conflict_next),
    (uint64_t)offsetof(FoundryApi_v4, mods_provider_next),
    (uint64_t)offsetof(FoundryApi_v4, mods_profile_next),
    (uint64_t)offsetof(FoundryApi_v4, mods_profile_active),
    (uint64_t)offsetof(FoundryApi_v4, mods_set_enabled),
    (uint64_t)offsetof(FoundryApi_v4, mods_move),
    (uint64_t)offsetof(FoundryApi_v4, mods_revert),
    (uint64_t)offsetof(FoundryApi_v4, mods_apply),
    (uint64_t)offsetof(FoundryApi_v4, mods_profile_create),
    (uint64_t)offsetof(FoundryApi_v4, mods_profile_copy),
    (uint64_t)offsetof(FoundryApi_v4, mods_profile_rename),
    (uint64_t)offsetof(FoundryApi_v4, mods_profile_delete),
    (uint64_t)offsetof(FoundryApi_v4, mods_profile_select),
    (uint64_t)offsetof(FoundryApi_v4, ui_theme_resolve),
    (uint64_t)offsetof(FoundryApi_v4, ui_theme_push),
    (uint64_t)offsetof(FoundryApi_v4, ui_theme_pop),
    (uint64_t)offsetof(FoundryApi_v4, ui_begin_disabled),
    (uint64_t)offsetof(FoundryApi_v4, ui_end_disabled),
    (uint64_t)offsetof(FoundryApi_v4, ui_region_remaining),
    (uint64_t)offsetof(FoundryApi_v4, ui_tabs),
    (uint64_t)offsetof(FoundryApi_v4, ui_selectable),
    (uint64_t)offsetof(FoundryApi_v4, ui_reorder_list),
    (uint64_t)offsetof(FoundryApi_v4, ui_reorder_button),
    (uint64_t)offsetof(FoundryApi_v4, ui_icon),
    (uint64_t)offsetof(FoundryApi_v4, ui_image),
    (uint64_t)offsetof(FoundryApi_v4, author_workspace_next),
    (uint64_t)offsetof(FoundryApi_v4, author_workspace_info),
    (uint64_t)offsetof(FoundryApi_v4, author_workspace_revision),
    (uint64_t)offsetof(FoundryApi_v4, author_workspace_limits),
    (uint64_t)offsetof(FoundryApi_v4, author_document_next),
    (uint64_t)offsetof(FoundryApi_v4, author_document_info),
    (uint64_t)offsetof(FoundryApi_v4, author_document_create),
    (uint64_t)offsetof(FoundryApi_v4, author_document_refresh),
    (uint64_t)offsetof(FoundryApi_v4, author_document_discard),
    (uint64_t)offsetof(FoundryApi_v4, author_document_copy_source),
    (uint64_t)offsetof(FoundryApi_v4, author_schema_next),
    (uint64_t)offsetof(FoundryApi_v4, author_schema_find),
    (uint64_t)offsetof(FoundryApi_v4, author_schema_node_info),
    (uint64_t)offsetof(FoundryApi_v4, author_schema_node_child),
    (uint64_t)offsetof(FoundryApi_v4, author_schema_node_default),
    (uint64_t)offsetof(FoundryApi_v4, author_record_next),
    (uint64_t)offsetof(FoundryApi_v4, author_dependency_next),
    (uint64_t)offsetof(FoundryApi_v4, author_dependency_record_next),
    (uint64_t)offsetof(FoundryApi_v4, author_preview_record_next),
    (uint64_t)offsetof(FoundryApi_v4, author_node_info),
    (uint64_t)offsetof(FoundryApi_v4, author_node_child),
    (uint64_t)offsetof(FoundryApi_v4, author_node_field),
    (uint64_t)offsetof(FoundryApi_v4, author_node_scalar),
    (uint64_t)offsetof(FoundryApi_v4, author_node_copy_text),
    (uint64_t)offsetof(FoundryApi_v4, author_record_create),
    (uint64_t)offsetof(FoundryApi_v4, author_record_duplicate),
    (uint64_t)offsetof(FoundryApi_v4, author_record_override),
    (uint64_t)offsetof(FoundryApi_v4, author_record_delete),
    (uint64_t)offsetof(FoundryApi_v4, author_value_set),
    (uint64_t)offsetof(FoundryApi_v4, author_value_unset),
    (uint64_t)offsetof(FoundryApi_v4, author_list_insert),
    (uint64_t)offsetof(FoundryApi_v4, author_list_remove),
    (uint64_t)offsetof(FoundryApi_v4, author_list_move),
    (uint64_t)offsetof(FoundryApi_v4, author_undo),
    (uint64_t)offsetof(FoundryApi_v4, author_redo),
    (uint64_t)offsetof(FoundryApi_v4, author_save_document),
    (uint64_t)offsetof(FoundryApi_v4, author_save_all),
    (uint64_t)offsetof(FoundryApi_v4, author_save_entry_next),
    (uint64_t)offsetof(FoundryApi_v4, author_validate),
    (uint64_t)offsetof(FoundryApi_v4, author_diagnostic_next),
    (uint64_t)offsetof(FoundryApi_v4, author_build),
    (uint64_t)offsetof(FoundryApi_v4, author_build_info),
    (uint64_t)offsetof(FoundryApi_v4, author_build_release),
    (uint64_t)offsetof(FoundryApi_v4, author_export_next),
    (uint64_t)offsetof(FoundryApi_v4, author_build_export),
    (uint64_t)offsetof(FoundryApi_v4, author_preview_activate),
    (uint64_t)offsetof(FoundryApi_v4, author_preview_info)
};

FOUNDRY_AGREE(sizeof(api_v4_names) / sizeof(api_v4_names[0]) ==
              sizeof(api_v4_offsets) / sizeof(api_v4_offsets[0]));
FOUNDRY_AGREE(sizeof(FoundryApi_v4) ==
              8 + 8 * (sizeof(api_v4_offsets) / sizeof(api_v4_offsets[0]) - 2));

uint64_t foundry_agreement_api_v4_size(void);
uint64_t foundry_agreement_api_v4_size(void)
{
    return (uint64_t)sizeof(FoundryApi_v4);
}

uint64_t foundry_agreement_api_v4_count(void);
uint64_t foundry_agreement_api_v4_count(void)
{
    return (uint64_t)(sizeof(api_v4_offsets) / sizeof(api_v4_offsets[0]));
}

uint64_t foundry_agreement_api_v4_offset(uint64_t index);
uint64_t foundry_agreement_api_v4_offset(uint64_t index)
{
    if (index >= foundry_agreement_api_v4_count()) return UINT64_MAX;
    return api_v4_offsets[index];
}

const char *foundry_agreement_api_v4_name(uint64_t index);
const char *foundry_agreement_api_v4_name(uint64_t index)
{
    if (index >= foundry_agreement_api_v4_count()) return NULL;
    return api_v4_names[index];
}

/* -- The authoring values ------------------------------------------------------------ */

FOUNDRY_AGREE(sizeof(FoundryAuthorWorkspaceInfo) == 72);
FOUNDRY_AGREE(offsetof(FoundryAuthorWorkspaceInfo, package_name) == 8);
FOUNDRY_AGREE(offsetof(FoundryAuthorWorkspaceInfo, package_version) == 24);
FOUNDRY_AGREE(offsetof(FoundryAuthorWorkspaceInfo, export_count) == 48);
FOUNDRY_AGREE(offsetof(FoundryAuthorWorkspaceInfo, can_edit) == 52);
FOUNDRY_AGREE(offsetof(FoundryAuthorWorkspaceInfo, has_manifest) == 61);

FOUNDRY_AGREE(sizeof(FoundryAuthorLimits) == 64);
FOUNDRY_AGREE(offsetof(FoundryAuthorLimits, max_history_commands) == 40);
FOUNDRY_AGREE(offsetof(FoundryAuthorLimits, max_list_elements) == 60);

FOUNDRY_AGREE(sizeof(FoundryAuthorDocumentInfo) == 40);
FOUNDRY_AGREE(offsetof(FoundryAuthorDocumentInfo, source_bytes) == 16);
FOUNDRY_AGREE(offsetof(FoundryAuthorDocumentInfo, dirty) == 32);
FOUNDRY_AGREE(offsetof(FoundryAuthorDocumentInfo, editable) == 36);

FOUNDRY_AGREE(sizeof(FoundryAuthorNodeInfo) == 64);
FOUNDRY_AGREE(offsetof(FoundryAuthorNodeInfo, id) == 16);
FOUNDRY_AGREE(offsetof(FoundryAuthorNodeInfo, schema) == 24);
FOUNDRY_AGREE(offsetof(FoundryAuthorNodeInfo, field_type) == 32);
FOUNDRY_AGREE(offsetof(FoundryAuthorNodeInfo, container) == 52);
FOUNDRY_AGREE(offsetof(FoundryAuthorNodeInfo, authored) == 56);
FOUNDRY_AGREE(offsetof(FoundryAuthorNodeInfo, depth) == 60);

FOUNDRY_AGREE(sizeof(FoundryAuthorSchemaNodeInfo) == 56);
FOUNDRY_AGREE(offsetof(FoundryAuthorSchemaNodeInfo, schema) == 16);
FOUNDRY_AGREE(offsetof(FoundryAuthorSchemaNodeInfo, field_type) == 24);
FOUNDRY_AGREE(offsetof(FoundryAuthorSchemaNodeInfo, is_root) == 48);

FOUNDRY_AGREE(sizeof(FoundryAuthorValue) == 32);
FOUNDRY_AGREE(offsetof(FoundryAuthorValue, boolean) == 4);
FOUNDRY_AGREE(offsetof(FoundryAuthorValue, id) == 8);
FOUNDRY_AGREE(offsetof(FoundryAuthorValue, text) == 16);

FOUNDRY_AGREE(sizeof(FoundryAuthorPackageInfo) == 56);
FOUNDRY_AGREE(offsetof(FoundryAuthorPackageInfo, id) == 32);
FOUNDRY_AGREE(offsetof(FoundryAuthorPackageInfo, version) == 40);

FOUNDRY_AGREE(sizeof(FoundryAuthorEdit) == 40);
FOUNDRY_AGREE(offsetof(FoundryAuthorEdit, document) == 8);
FOUNDRY_AGREE(offsetof(FoundryAuthorEdit, selection) == 16);
FOUNDRY_AGREE(offsetof(FoundryAuthorEdit, record) == 24);
FOUNDRY_AGREE(offsetof(FoundryAuthorEdit, has_record) == 32);

FOUNDRY_AGREE(sizeof(FoundryAuthorSaveResult) == 32);
FOUNDRY_AGREE(offsetof(FoundryAuthorSaveResult, outcome) == 16);
FOUNDRY_AGREE(offsetof(FoundryAuthorSaveResult, durable) == 24);

FOUNDRY_AGREE(sizeof(FoundryAuthorSaveAll) == 24);
FOUNDRY_AGREE(offsetof(FoundryAuthorSaveAll, entry_count) == 8);
FOUNDRY_AGREE(offsetof(FoundryAuthorSaveAll, lock_released) == 16);

FOUNDRY_AGREE(sizeof(FoundryAuthorSaveEntry) == 40);
FOUNDRY_AGREE(offsetof(FoundryAuthorSaveEntry, document) == 16);
FOUNDRY_AGREE(offsetof(FoundryAuthorSaveEntry, outcome) == 24);
FOUNDRY_AGREE(offsetof(FoundryAuthorSaveEntry, durable) == 32);

FOUNDRY_AGREE(sizeof(FoundryAuthorDiagnostic) == 120);
FOUNDRY_AGREE(offsetof(FoundryAuthorDiagnostic, file) == 8);
FOUNDRY_AGREE(offsetof(FoundryAuthorDiagnostic, note_file) == 72);
FOUNDRY_AGREE(offsetof(FoundryAuthorDiagnostic, line) == 88);
FOUNDRY_AGREE(offsetof(FoundryAuthorDiagnostic, suppressed) == 112);
FOUNDRY_AGREE(offsetof(FoundryAuthorDiagnostic, has_note) == 116);

FOUNDRY_AGREE(sizeof(FoundryAuthorBuildInfo) == 40);
FOUNDRY_AGREE(offsetof(FoundryAuthorBuildInfo, package_bytes) == 24);
FOUNDRY_AGREE(offsetof(FoundryAuthorBuildInfo, package_version) == 32);

FOUNDRY_AGREE(sizeof(FoundryAuthorPreviewInfo) == 32);
FOUNDRY_AGREE(offsetof(FoundryAuthorPreviewInfo, build) == 16);
FOUNDRY_AGREE(offsetof(FoundryAuthorPreviewInfo, outcome) == 24);
FOUNDRY_AGREE(offsetof(FoundryAuthorPreviewInfo, available) == 28);

FOUNDRY_AGREE(sizeof(FoundryAuthorExportInfo) == 32);
FOUNDRY_AGREE(offsetof(FoundryAuthorExportInfo, index) == 16);
FOUNDRY_AGREE(offsetof(FoundryAuthorExportInfo, kind) == 20);
FOUNDRY_AGREE(offsetof(FoundryAuthorExportInfo, has_assets) == 24);

FOUNDRY_AGREE(sizeof(FoundryWorkspace) == 8);
FOUNDRY_AGREE(sizeof(FoundryDocument) == 8);
FOUNDRY_AGREE(sizeof(FoundrySourceNode) == 8);
FOUNDRY_AGREE(sizeof(FoundrySchemaNode) == 8);
FOUNDRY_AGREE(sizeof(FoundryBuild) == 8);

/* -- ABI v5 -------------------------------------------------------------------------- */
/* Positional initialization type-checks every common v5 member against v4, as v4 does
 * against v3. */
void foundry_agreement_api_v5_common_signatures(const FoundryApi_v5 *api);
void foundry_agreement_api_v5_common_signatures(const FoundryApi_v5 *api)
{
    FoundryApi_v4 common = {
        api->version,
        api->size,
        api->result_name,
        api->log_write,
        api->log_next,
        api->id_from_string,
        api->id_to_string,
        api->id_copy_string,
        api->frame_index,
        api->frame_delta_ns,
        api->elapsed_ns,
        api->tick_delta_ns,
        api->scope_begin,
        api->scope_end,
        api->memory_counter_open,
        api->memory_counter_set,
        api->content_generation,
        api->content_find,
        api->content_next,
        api->content_next_of_schema,
        api->record_id,
        api->record_name,
        api->record_schema,
        api->record_package,
        api->record_field_count,
        api->record_field_index,
        api->record_field_name,
        api->record_field_type,
        api->record_field_present,
        api->record_get_bool,
        api->record_get_i64,
        api->record_get_u64,
        api->record_get_f32,
        api->record_get_string,
        api->record_copy_string,
        api->record_get_id,
        api->record_nested,
        api->record_list_len,
        api->record_list_get_i64,
        api->record_list_get_f32,
        api->record_list_get_string,
        api->record_list_get_id,
        api->record_list_nested,
        api->package_count,
        api->package_next,
        api->package_find,
        api->package_id,
        api->package_name,
        api->package_version,
        api->package_order,
        api->schema_count,
        api->schema_next,
        api->schema_find,
        api->schema_id,
        api->schema_version,
        api->schema_field_count,
        api->schema_field_name,
        api->schema_field_type,
        api->asset_acquire,
        api->asset_release,
        api->asset_find,
        api->asset_next,
        api->asset_content_id,
        api->asset_schema,
        api->asset_refcount,
        api->world_register_component,
        api->world_find_component_type,
        api->world_component_type_next,
        api->world_component_type_schema,
        api->world_component_type_name,
        api->world_component_type_size,
        api->world_component_type_alignment,
        api->world_component_type_count,
        api->world_component_type_savable,
        api->world_create_entity,
        api->world_destroy_entity,
        api->world_contains,
        api->world_entity_count,
        api->world_next_entity,
        api->world_add_component,
        api->world_remove_component,
        api->world_has_component,
        api->world_register_system,
        api->world_query_begin,
        api->world_query_next,
        api->world_spawn,
        api->world_spawn_scene,
        api->world_read_component,
        api->world_component_bytes,
        api->render_texture_of_asset,
        api->render_destroy_texture,
        api->render_draw_sprite,
        api->render_draw_text,
        api->render_add_view,
        api->render_select_view,
        api->render_camera_get,
        api->render_camera_set,
        api->render_world_to_screen,
        api->render_screen_to_world,
        api->render_stats,
        api->ui_begin,
        api->ui_end,
        api->ui_push_id,
        api->ui_pop_id,
        api->ui_begin_panel,
        api->ui_end_panel,
        api->ui_begin_row,
        api->ui_end_row,
        api->ui_begin_scroll,
        api->ui_end_scroll,
        api->ui_label,
        api->ui_button,
        api->ui_checkbox,
        api->ui_slider,
        api->ui_slider_int,
        api->ui_separator,
        api->ui_spacer,
        api->ui_collapsing_header,
        api->ui_text_field,
        api->ui_plot,
        api->ui_style_get,
        api->ui_style_set,
        api->ui_wants_keyboard,
        api->ui_wants_pointer,
        api->audio_play,
        api->audio_stop,
        api->audio_set_gain,
        api->audio_set_pan,
        api->audio_set_pitch,
        api->audio_set_master_gain,
        api->physics_create_body,
        api->physics_destroy_body,
        api->physics_move_body,
        api->physics_query_point,
        api->physics_query_aabb,
        api->physics_query_ray,
        api->physics_body_contacts,
        api->script_source_copy,
        api->mods_installed_next,
        api->mods_pending_next,
        api->mods_requirement_next,
        api->mods_conflict_next,
        api->mods_provider_next,
        api->mods_profile_next,
        api->mods_profile_active,
        api->mods_set_enabled,
        api->mods_move,
        api->mods_revert,
        api->mods_apply,
        api->mods_profile_create,
        api->mods_profile_copy,
        api->mods_profile_rename,
        api->mods_profile_delete,
        api->mods_profile_select,
        api->ui_theme_resolve,
        api->ui_theme_push,
        api->ui_theme_pop,
        api->ui_begin_disabled,
        api->ui_end_disabled,
        api->ui_region_remaining,
        api->ui_tabs,
        api->ui_selectable,
        api->ui_reorder_list,
        api->ui_reorder_button,
        api->ui_icon,
        api->ui_image,
        api->author_workspace_next,
        api->author_workspace_info,
        api->author_workspace_revision,
        api->author_workspace_limits,
        api->author_document_next,
        api->author_document_info,
        api->author_document_create,
        api->author_document_refresh,
        api->author_document_discard,
        api->author_document_copy_source,
        api->author_schema_next,
        api->author_schema_find,
        api->author_schema_node_info,
        api->author_schema_node_child,
        api->author_schema_node_default,
        api->author_record_next,
        api->author_dependency_next,
        api->author_dependency_record_next,
        api->author_preview_record_next,
        api->author_node_info,
        api->author_node_child,
        api->author_node_field,
        api->author_node_scalar,
        api->author_node_copy_text,
        api->author_record_create,
        api->author_record_duplicate,
        api->author_record_override,
        api->author_record_delete,
        api->author_value_set,
        api->author_value_unset,
        api->author_list_insert,
        api->author_list_remove,
        api->author_list_move,
        api->author_undo,
        api->author_redo,
        api->author_save_document,
        api->author_save_all,
        api->author_save_entry_next,
        api->author_validate,
        api->author_diagnostic_next,
        api->author_build,
        api->author_build_info,
        api->author_build_release,
        api->author_export_next,
        api->author_build_export,
        api->author_preview_activate,
        api->author_preview_info
    };
    (void)common;
}

/* The networking tail's longer shapes, stated once each: a drift between this header and
 * the engine's Zig declarations is an incompatible-pointer diagnostic under `-Werror`. */
typedef FoundryResult (*foundry_agree_net_command_send_fn)(
    FoundryNetPeer, FoundryContentId, const void *, uint32_t, uint64_t *);
typedef FoundryResult (*foundry_agree_net_delivery_take_fn)(
    FoundryNetPeer, uint8_t *, uint64_t, uint64_t *, FoundryNetDelivery *);
typedef FoundryResult (*foundry_agree_net_batch_copy_fn)(
    FoundryNetSession, uint32_t, uint8_t *, uint64_t, uint64_t *);
typedef FoundryResult (*foundry_agree_net_baseline_fn)(
    FoundryNetPeer, uint64_t, const void *, uint32_t);
typedef FoundryResult (*foundry_agree_net_acknowledge_fn)(FoundryNetPeer, uint64_t, uint64_t);
typedef FoundryResult (*foundry_agree_net_register_fn)(
    FoundryNetSession, const FoundryNetChannelDesc *);

void foundry_agreement_api_v5_net_signatures(const FoundryApi_v5 *api);
void foundry_agreement_api_v5_net_signatures(const FoundryApi_v5 *api)
{
    foundry_agree_net_command_send_fn send = api->net_command_send;
    foundry_agree_net_delivery_take_fn take = api->net_delivery_take;
    foundry_agree_net_batch_copy_fn copy = api->net_batch_copy;
    foundry_agree_net_baseline_fn baseline = api->net_baseline_send;
    foundry_agree_net_baseline_fn publish = api->net_state_publish;
    foundry_agree_net_acknowledge_fn acknowledge = api->net_baseline_acknowledge;
    foundry_agree_net_register_fn reg = api->net_channel_register;
    (void)send;
    (void)take;
    (void)copy;
    (void)baseline;
    (void)publish;
    (void)acknowledge;
    (void)reg;
}

static const char *const api_v5_names[] = {
    "version",
    "size",
    "result_name",
    "log_write",
    "log_next",
    "id_from_string",
    "id_to_string",
    "id_copy_string",
    "frame_index",
    "frame_delta_ns",
    "elapsed_ns",
    "tick_delta_ns",
    "scope_begin",
    "scope_end",
    "memory_counter_open",
    "memory_counter_set",
    "content_generation",
    "content_find",
    "content_next",
    "content_next_of_schema",
    "record_id",
    "record_name",
    "record_schema",
    "record_package",
    "record_field_count",
    "record_field_index",
    "record_field_name",
    "record_field_type",
    "record_field_present",
    "record_get_bool",
    "record_get_i64",
    "record_get_u64",
    "record_get_f32",
    "record_get_string",
    "record_copy_string",
    "record_get_id",
    "record_nested",
    "record_list_len",
    "record_list_get_i64",
    "record_list_get_f32",
    "record_list_get_string",
    "record_list_get_id",
    "record_list_nested",
    "package_count",
    "package_next",
    "package_find",
    "package_id",
    "package_name",
    "package_version",
    "package_order",
    "schema_count",
    "schema_next",
    "schema_find",
    "schema_id",
    "schema_version",
    "schema_field_count",
    "schema_field_name",
    "schema_field_type",
    "asset_acquire",
    "asset_release",
    "asset_find",
    "asset_next",
    "asset_content_id",
    "asset_schema",
    "asset_refcount",
    "world_register_component",
    "world_find_component_type",
    "world_component_type_next",
    "world_component_type_schema",
    "world_component_type_name",
    "world_component_type_size",
    "world_component_type_alignment",
    "world_component_type_count",
    "world_component_type_savable",
    "world_create_entity",
    "world_destroy_entity",
    "world_contains",
    "world_entity_count",
    "world_next_entity",
    "world_add_component",
    "world_remove_component",
    "world_has_component",
    "world_register_system",
    "world_query_begin",
    "world_query_next",
    "world_spawn",
    "world_spawn_scene",
    "world_read_component",
    "world_component_bytes",
    "render_texture_of_asset",
    "render_destroy_texture",
    "render_draw_sprite",
    "render_draw_text",
    "render_add_view",
    "render_select_view",
    "render_camera_get",
    "render_camera_set",
    "render_world_to_screen",
    "render_screen_to_world",
    "render_stats",
    "ui_begin",
    "ui_end",
    "ui_push_id",
    "ui_pop_id",
    "ui_begin_panel",
    "ui_end_panel",
    "ui_begin_row",
    "ui_end_row",
    "ui_begin_scroll",
    "ui_end_scroll",
    "ui_label",
    "ui_button",
    "ui_checkbox",
    "ui_slider",
    "ui_slider_int",
    "ui_separator",
    "ui_spacer",
    "ui_collapsing_header",
    "ui_text_field",
    "ui_plot",
    "ui_style_get",
    "ui_style_set",
    "ui_wants_keyboard",
    "ui_wants_pointer",
    "audio_play",
    "audio_stop",
    "audio_set_gain",
    "audio_set_pan",
    "audio_set_pitch",
    "audio_set_master_gain",
    "physics_create_body",
    "physics_destroy_body",
    "physics_move_body",
    "physics_query_point",
    "physics_query_aabb",
    "physics_query_ray",
    "physics_body_contacts",
    "script_source_copy",
    "mods_installed_next",
    "mods_pending_next",
    "mods_requirement_next",
    "mods_conflict_next",
    "mods_provider_next",
    "mods_profile_next",
    "mods_profile_active",
    "mods_set_enabled",
    "mods_move",
    "mods_revert",
    "mods_apply",
    "mods_profile_create",
    "mods_profile_copy",
    "mods_profile_rename",
    "mods_profile_delete",
    "mods_profile_select",
    "ui_theme_resolve",
    "ui_theme_push",
    "ui_theme_pop",
    "ui_begin_disabled",
    "ui_end_disabled",
    "ui_region_remaining",
    "ui_tabs",
    "ui_selectable",
    "ui_reorder_list",
    "ui_reorder_button",
    "ui_icon",
    "ui_image",
    "author_workspace_next",
    "author_workspace_info",
    "author_workspace_revision",
    "author_workspace_limits",
    "author_document_next",
    "author_document_info",
    "author_document_create",
    "author_document_refresh",
    "author_document_discard",
    "author_document_copy_source",
    "author_schema_next",
    "author_schema_find",
    "author_schema_node_info",
    "author_schema_node_child",
    "author_schema_node_default",
    "author_record_next",
    "author_dependency_next",
    "author_dependency_record_next",
    "author_preview_record_next",
    "author_node_info",
    "author_node_child",
    "author_node_field",
    "author_node_scalar",
    "author_node_copy_text",
    "author_record_create",
    "author_record_duplicate",
    "author_record_override",
    "author_record_delete",
    "author_value_set",
    "author_value_unset",
    "author_list_insert",
    "author_list_remove",
    "author_list_move",
    "author_undo",
    "author_redo",
    "author_save_document",
    "author_save_all",
    "author_save_entry_next",
    "author_validate",
    "author_diagnostic_next",
    "author_build",
    "author_build_info",
    "author_build_release",
    "author_export_next",
    "author_build_export",
    "author_preview_activate",
    "author_preview_info",
    "net_grant_next",
    "net_session_create",
    "net_session_close",
    "net_session_info",
    "net_channel_register",
    "net_channel_next",
    "net_session_listen",
    "net_session_connect",
    "net_peer_next",
    "net_peer_info",
    "net_peer_disconnect",
    "net_event_next",
    "net_stats",
    "net_baseline_send",
    "net_baseline_acknowledge",
    "net_state_publish",
    "net_command_send",
    "net_delivery_next",
    "net_delivery_take",
    "net_batch_admit",
    "net_batch_command",
    "net_batch_copy"
};

static const uint64_t api_v5_offsets[] = {
    (uint64_t)offsetof(FoundryApi_v5, version),
    (uint64_t)offsetof(FoundryApi_v5, size),
    (uint64_t)offsetof(FoundryApi_v5, result_name),
    (uint64_t)offsetof(FoundryApi_v5, log_write),
    (uint64_t)offsetof(FoundryApi_v5, log_next),
    (uint64_t)offsetof(FoundryApi_v5, id_from_string),
    (uint64_t)offsetof(FoundryApi_v5, id_to_string),
    (uint64_t)offsetof(FoundryApi_v5, id_copy_string),
    (uint64_t)offsetof(FoundryApi_v5, frame_index),
    (uint64_t)offsetof(FoundryApi_v5, frame_delta_ns),
    (uint64_t)offsetof(FoundryApi_v5, elapsed_ns),
    (uint64_t)offsetof(FoundryApi_v5, tick_delta_ns),
    (uint64_t)offsetof(FoundryApi_v5, scope_begin),
    (uint64_t)offsetof(FoundryApi_v5, scope_end),
    (uint64_t)offsetof(FoundryApi_v5, memory_counter_open),
    (uint64_t)offsetof(FoundryApi_v5, memory_counter_set),
    (uint64_t)offsetof(FoundryApi_v5, content_generation),
    (uint64_t)offsetof(FoundryApi_v5, content_find),
    (uint64_t)offsetof(FoundryApi_v5, content_next),
    (uint64_t)offsetof(FoundryApi_v5, content_next_of_schema),
    (uint64_t)offsetof(FoundryApi_v5, record_id),
    (uint64_t)offsetof(FoundryApi_v5, record_name),
    (uint64_t)offsetof(FoundryApi_v5, record_schema),
    (uint64_t)offsetof(FoundryApi_v5, record_package),
    (uint64_t)offsetof(FoundryApi_v5, record_field_count),
    (uint64_t)offsetof(FoundryApi_v5, record_field_index),
    (uint64_t)offsetof(FoundryApi_v5, record_field_name),
    (uint64_t)offsetof(FoundryApi_v5, record_field_type),
    (uint64_t)offsetof(FoundryApi_v5, record_field_present),
    (uint64_t)offsetof(FoundryApi_v5, record_get_bool),
    (uint64_t)offsetof(FoundryApi_v5, record_get_i64),
    (uint64_t)offsetof(FoundryApi_v5, record_get_u64),
    (uint64_t)offsetof(FoundryApi_v5, record_get_f32),
    (uint64_t)offsetof(FoundryApi_v5, record_get_string),
    (uint64_t)offsetof(FoundryApi_v5, record_copy_string),
    (uint64_t)offsetof(FoundryApi_v5, record_get_id),
    (uint64_t)offsetof(FoundryApi_v5, record_nested),
    (uint64_t)offsetof(FoundryApi_v5, record_list_len),
    (uint64_t)offsetof(FoundryApi_v5, record_list_get_i64),
    (uint64_t)offsetof(FoundryApi_v5, record_list_get_f32),
    (uint64_t)offsetof(FoundryApi_v5, record_list_get_string),
    (uint64_t)offsetof(FoundryApi_v5, record_list_get_id),
    (uint64_t)offsetof(FoundryApi_v5, record_list_nested),
    (uint64_t)offsetof(FoundryApi_v5, package_count),
    (uint64_t)offsetof(FoundryApi_v5, package_next),
    (uint64_t)offsetof(FoundryApi_v5, package_find),
    (uint64_t)offsetof(FoundryApi_v5, package_id),
    (uint64_t)offsetof(FoundryApi_v5, package_name),
    (uint64_t)offsetof(FoundryApi_v5, package_version),
    (uint64_t)offsetof(FoundryApi_v5, package_order),
    (uint64_t)offsetof(FoundryApi_v5, schema_count),
    (uint64_t)offsetof(FoundryApi_v5, schema_next),
    (uint64_t)offsetof(FoundryApi_v5, schema_find),
    (uint64_t)offsetof(FoundryApi_v5, schema_id),
    (uint64_t)offsetof(FoundryApi_v5, schema_version),
    (uint64_t)offsetof(FoundryApi_v5, schema_field_count),
    (uint64_t)offsetof(FoundryApi_v5, schema_field_name),
    (uint64_t)offsetof(FoundryApi_v5, schema_field_type),
    (uint64_t)offsetof(FoundryApi_v5, asset_acquire),
    (uint64_t)offsetof(FoundryApi_v5, asset_release),
    (uint64_t)offsetof(FoundryApi_v5, asset_find),
    (uint64_t)offsetof(FoundryApi_v5, asset_next),
    (uint64_t)offsetof(FoundryApi_v5, asset_content_id),
    (uint64_t)offsetof(FoundryApi_v5, asset_schema),
    (uint64_t)offsetof(FoundryApi_v5, asset_refcount),
    (uint64_t)offsetof(FoundryApi_v5, world_register_component),
    (uint64_t)offsetof(FoundryApi_v5, world_find_component_type),
    (uint64_t)offsetof(FoundryApi_v5, world_component_type_next),
    (uint64_t)offsetof(FoundryApi_v5, world_component_type_schema),
    (uint64_t)offsetof(FoundryApi_v5, world_component_type_name),
    (uint64_t)offsetof(FoundryApi_v5, world_component_type_size),
    (uint64_t)offsetof(FoundryApi_v5, world_component_type_alignment),
    (uint64_t)offsetof(FoundryApi_v5, world_component_type_count),
    (uint64_t)offsetof(FoundryApi_v5, world_component_type_savable),
    (uint64_t)offsetof(FoundryApi_v5, world_create_entity),
    (uint64_t)offsetof(FoundryApi_v5, world_destroy_entity),
    (uint64_t)offsetof(FoundryApi_v5, world_contains),
    (uint64_t)offsetof(FoundryApi_v5, world_entity_count),
    (uint64_t)offsetof(FoundryApi_v5, world_next_entity),
    (uint64_t)offsetof(FoundryApi_v5, world_add_component),
    (uint64_t)offsetof(FoundryApi_v5, world_remove_component),
    (uint64_t)offsetof(FoundryApi_v5, world_has_component),
    (uint64_t)offsetof(FoundryApi_v5, world_register_system),
    (uint64_t)offsetof(FoundryApi_v5, world_query_begin),
    (uint64_t)offsetof(FoundryApi_v5, world_query_next),
    (uint64_t)offsetof(FoundryApi_v5, world_spawn),
    (uint64_t)offsetof(FoundryApi_v5, world_spawn_scene),
    (uint64_t)offsetof(FoundryApi_v5, world_read_component),
    (uint64_t)offsetof(FoundryApi_v5, world_component_bytes),
    (uint64_t)offsetof(FoundryApi_v5, render_texture_of_asset),
    (uint64_t)offsetof(FoundryApi_v5, render_destroy_texture),
    (uint64_t)offsetof(FoundryApi_v5, render_draw_sprite),
    (uint64_t)offsetof(FoundryApi_v5, render_draw_text),
    (uint64_t)offsetof(FoundryApi_v5, render_add_view),
    (uint64_t)offsetof(FoundryApi_v5, render_select_view),
    (uint64_t)offsetof(FoundryApi_v5, render_camera_get),
    (uint64_t)offsetof(FoundryApi_v5, render_camera_set),
    (uint64_t)offsetof(FoundryApi_v5, render_world_to_screen),
    (uint64_t)offsetof(FoundryApi_v5, render_screen_to_world),
    (uint64_t)offsetof(FoundryApi_v5, render_stats),
    (uint64_t)offsetof(FoundryApi_v5, ui_begin),
    (uint64_t)offsetof(FoundryApi_v5, ui_end),
    (uint64_t)offsetof(FoundryApi_v5, ui_push_id),
    (uint64_t)offsetof(FoundryApi_v5, ui_pop_id),
    (uint64_t)offsetof(FoundryApi_v5, ui_begin_panel),
    (uint64_t)offsetof(FoundryApi_v5, ui_end_panel),
    (uint64_t)offsetof(FoundryApi_v5, ui_begin_row),
    (uint64_t)offsetof(FoundryApi_v5, ui_end_row),
    (uint64_t)offsetof(FoundryApi_v5, ui_begin_scroll),
    (uint64_t)offsetof(FoundryApi_v5, ui_end_scroll),
    (uint64_t)offsetof(FoundryApi_v5, ui_label),
    (uint64_t)offsetof(FoundryApi_v5, ui_button),
    (uint64_t)offsetof(FoundryApi_v5, ui_checkbox),
    (uint64_t)offsetof(FoundryApi_v5, ui_slider),
    (uint64_t)offsetof(FoundryApi_v5, ui_slider_int),
    (uint64_t)offsetof(FoundryApi_v5, ui_separator),
    (uint64_t)offsetof(FoundryApi_v5, ui_spacer),
    (uint64_t)offsetof(FoundryApi_v5, ui_collapsing_header),
    (uint64_t)offsetof(FoundryApi_v5, ui_text_field),
    (uint64_t)offsetof(FoundryApi_v5, ui_plot),
    (uint64_t)offsetof(FoundryApi_v5, ui_style_get),
    (uint64_t)offsetof(FoundryApi_v5, ui_style_set),
    (uint64_t)offsetof(FoundryApi_v5, ui_wants_keyboard),
    (uint64_t)offsetof(FoundryApi_v5, ui_wants_pointer),
    (uint64_t)offsetof(FoundryApi_v5, audio_play),
    (uint64_t)offsetof(FoundryApi_v5, audio_stop),
    (uint64_t)offsetof(FoundryApi_v5, audio_set_gain),
    (uint64_t)offsetof(FoundryApi_v5, audio_set_pan),
    (uint64_t)offsetof(FoundryApi_v5, audio_set_pitch),
    (uint64_t)offsetof(FoundryApi_v5, audio_set_master_gain),
    (uint64_t)offsetof(FoundryApi_v5, physics_create_body),
    (uint64_t)offsetof(FoundryApi_v5, physics_destroy_body),
    (uint64_t)offsetof(FoundryApi_v5, physics_move_body),
    (uint64_t)offsetof(FoundryApi_v5, physics_query_point),
    (uint64_t)offsetof(FoundryApi_v5, physics_query_aabb),
    (uint64_t)offsetof(FoundryApi_v5, physics_query_ray),
    (uint64_t)offsetof(FoundryApi_v5, physics_body_contacts),
    (uint64_t)offsetof(FoundryApi_v5, script_source_copy),
    (uint64_t)offsetof(FoundryApi_v5, mods_installed_next),
    (uint64_t)offsetof(FoundryApi_v5, mods_pending_next),
    (uint64_t)offsetof(FoundryApi_v5, mods_requirement_next),
    (uint64_t)offsetof(FoundryApi_v5, mods_conflict_next),
    (uint64_t)offsetof(FoundryApi_v5, mods_provider_next),
    (uint64_t)offsetof(FoundryApi_v5, mods_profile_next),
    (uint64_t)offsetof(FoundryApi_v5, mods_profile_active),
    (uint64_t)offsetof(FoundryApi_v5, mods_set_enabled),
    (uint64_t)offsetof(FoundryApi_v5, mods_move),
    (uint64_t)offsetof(FoundryApi_v5, mods_revert),
    (uint64_t)offsetof(FoundryApi_v5, mods_apply),
    (uint64_t)offsetof(FoundryApi_v5, mods_profile_create),
    (uint64_t)offsetof(FoundryApi_v5, mods_profile_copy),
    (uint64_t)offsetof(FoundryApi_v5, mods_profile_rename),
    (uint64_t)offsetof(FoundryApi_v5, mods_profile_delete),
    (uint64_t)offsetof(FoundryApi_v5, mods_profile_select),
    (uint64_t)offsetof(FoundryApi_v5, ui_theme_resolve),
    (uint64_t)offsetof(FoundryApi_v5, ui_theme_push),
    (uint64_t)offsetof(FoundryApi_v5, ui_theme_pop),
    (uint64_t)offsetof(FoundryApi_v5, ui_begin_disabled),
    (uint64_t)offsetof(FoundryApi_v5, ui_end_disabled),
    (uint64_t)offsetof(FoundryApi_v5, ui_region_remaining),
    (uint64_t)offsetof(FoundryApi_v5, ui_tabs),
    (uint64_t)offsetof(FoundryApi_v5, ui_selectable),
    (uint64_t)offsetof(FoundryApi_v5, ui_reorder_list),
    (uint64_t)offsetof(FoundryApi_v5, ui_reorder_button),
    (uint64_t)offsetof(FoundryApi_v5, ui_icon),
    (uint64_t)offsetof(FoundryApi_v5, ui_image),
    (uint64_t)offsetof(FoundryApi_v5, author_workspace_next),
    (uint64_t)offsetof(FoundryApi_v5, author_workspace_info),
    (uint64_t)offsetof(FoundryApi_v5, author_workspace_revision),
    (uint64_t)offsetof(FoundryApi_v5, author_workspace_limits),
    (uint64_t)offsetof(FoundryApi_v5, author_document_next),
    (uint64_t)offsetof(FoundryApi_v5, author_document_info),
    (uint64_t)offsetof(FoundryApi_v5, author_document_create),
    (uint64_t)offsetof(FoundryApi_v5, author_document_refresh),
    (uint64_t)offsetof(FoundryApi_v5, author_document_discard),
    (uint64_t)offsetof(FoundryApi_v5, author_document_copy_source),
    (uint64_t)offsetof(FoundryApi_v5, author_schema_next),
    (uint64_t)offsetof(FoundryApi_v5, author_schema_find),
    (uint64_t)offsetof(FoundryApi_v5, author_schema_node_info),
    (uint64_t)offsetof(FoundryApi_v5, author_schema_node_child),
    (uint64_t)offsetof(FoundryApi_v5, author_schema_node_default),
    (uint64_t)offsetof(FoundryApi_v5, author_record_next),
    (uint64_t)offsetof(FoundryApi_v5, author_dependency_next),
    (uint64_t)offsetof(FoundryApi_v5, author_dependency_record_next),
    (uint64_t)offsetof(FoundryApi_v5, author_preview_record_next),
    (uint64_t)offsetof(FoundryApi_v5, author_node_info),
    (uint64_t)offsetof(FoundryApi_v5, author_node_child),
    (uint64_t)offsetof(FoundryApi_v5, author_node_field),
    (uint64_t)offsetof(FoundryApi_v5, author_node_scalar),
    (uint64_t)offsetof(FoundryApi_v5, author_node_copy_text),
    (uint64_t)offsetof(FoundryApi_v5, author_record_create),
    (uint64_t)offsetof(FoundryApi_v5, author_record_duplicate),
    (uint64_t)offsetof(FoundryApi_v5, author_record_override),
    (uint64_t)offsetof(FoundryApi_v5, author_record_delete),
    (uint64_t)offsetof(FoundryApi_v5, author_value_set),
    (uint64_t)offsetof(FoundryApi_v5, author_value_unset),
    (uint64_t)offsetof(FoundryApi_v5, author_list_insert),
    (uint64_t)offsetof(FoundryApi_v5, author_list_remove),
    (uint64_t)offsetof(FoundryApi_v5, author_list_move),
    (uint64_t)offsetof(FoundryApi_v5, author_undo),
    (uint64_t)offsetof(FoundryApi_v5, author_redo),
    (uint64_t)offsetof(FoundryApi_v5, author_save_document),
    (uint64_t)offsetof(FoundryApi_v5, author_save_all),
    (uint64_t)offsetof(FoundryApi_v5, author_save_entry_next),
    (uint64_t)offsetof(FoundryApi_v5, author_validate),
    (uint64_t)offsetof(FoundryApi_v5, author_diagnostic_next),
    (uint64_t)offsetof(FoundryApi_v5, author_build),
    (uint64_t)offsetof(FoundryApi_v5, author_build_info),
    (uint64_t)offsetof(FoundryApi_v5, author_build_release),
    (uint64_t)offsetof(FoundryApi_v5, author_export_next),
    (uint64_t)offsetof(FoundryApi_v5, author_build_export),
    (uint64_t)offsetof(FoundryApi_v5, author_preview_activate),
    (uint64_t)offsetof(FoundryApi_v5, author_preview_info),
    (uint64_t)offsetof(FoundryApi_v5, net_grant_next),
    (uint64_t)offsetof(FoundryApi_v5, net_session_create),
    (uint64_t)offsetof(FoundryApi_v5, net_session_close),
    (uint64_t)offsetof(FoundryApi_v5, net_session_info),
    (uint64_t)offsetof(FoundryApi_v5, net_channel_register),
    (uint64_t)offsetof(FoundryApi_v5, net_channel_next),
    (uint64_t)offsetof(FoundryApi_v5, net_session_listen),
    (uint64_t)offsetof(FoundryApi_v5, net_session_connect),
    (uint64_t)offsetof(FoundryApi_v5, net_peer_next),
    (uint64_t)offsetof(FoundryApi_v5, net_peer_info),
    (uint64_t)offsetof(FoundryApi_v5, net_peer_disconnect),
    (uint64_t)offsetof(FoundryApi_v5, net_event_next),
    (uint64_t)offsetof(FoundryApi_v5, net_stats),
    (uint64_t)offsetof(FoundryApi_v5, net_baseline_send),
    (uint64_t)offsetof(FoundryApi_v5, net_baseline_acknowledge),
    (uint64_t)offsetof(FoundryApi_v5, net_state_publish),
    (uint64_t)offsetof(FoundryApi_v5, net_command_send),
    (uint64_t)offsetof(FoundryApi_v5, net_delivery_next),
    (uint64_t)offsetof(FoundryApi_v5, net_delivery_take),
    (uint64_t)offsetof(FoundryApi_v5, net_batch_admit),
    (uint64_t)offsetof(FoundryApi_v5, net_batch_command),
    (uint64_t)offsetof(FoundryApi_v5, net_batch_copy)
};

FOUNDRY_AGREE(sizeof(api_v5_names) / sizeof(api_v5_names[0]) ==
              sizeof(api_v5_offsets) / sizeof(api_v5_offsets[0]));
FOUNDRY_AGREE(sizeof(FoundryApi_v5) ==
              8 + 8 * (sizeof(api_v5_offsets) / sizeof(api_v5_offsets[0]) - 2));

uint64_t foundry_agreement_api_v5_size(void);
uint64_t foundry_agreement_api_v5_size(void)
{
    return (uint64_t)sizeof(FoundryApi_v5);
}

uint64_t foundry_agreement_api_v5_count(void);
uint64_t foundry_agreement_api_v5_count(void)
{
    return (uint64_t)(sizeof(api_v5_offsets) / sizeof(api_v5_offsets[0]));
}

uint64_t foundry_agreement_api_v5_offset(uint64_t index);
uint64_t foundry_agreement_api_v5_offset(uint64_t index)
{
    if (index >= foundry_agreement_api_v5_count()) return UINT64_MAX;
    return api_v5_offsets[index];
}

const char *foundry_agreement_api_v5_name(uint64_t index);
const char *foundry_agreement_api_v5_name(uint64_t index)
{
    if (index >= foundry_agreement_api_v5_count()) return NULL;
    return api_v5_names[index];
}

/* -- The networking values ----------------------------------------------------------- */

FOUNDRY_AGREE(sizeof(FoundryNetSession) == 8);
FOUNDRY_AGREE(sizeof(FoundryNetPeer) == 8);

FOUNDRY_AGREE(sizeof(FoundryNetEndpoint) == 8);
FOUNDRY_AGREE(offsetof(FoundryNetEndpoint, port) == 4);

FOUNDRY_AGREE(sizeof(FoundryNetGrantInfo) == 24);
FOUNDRY_AGREE(offsetof(FoundryNetGrantInfo, role) == 8);
FOUNDRY_AGREE(offsetof(FoundryNetGrantInfo, endpoint) == 16);

FOUNDRY_AGREE(sizeof(FoundryNetChannelDesc) == 24);
FOUNDRY_AGREE(offsetof(FoundryNetChannelDesc, max_payload_bytes) == 12);
FOUNDRY_AGREE(offsetof(FoundryNetChannelDesc, direction) == 16);
FOUNDRY_AGREE(offsetof(FoundryNetChannelDesc, delivery) == 20);

FOUNDRY_AGREE(sizeof(FoundryNetSessionInfo) == 40);
FOUNDRY_AGREE(offsetof(FoundryNetSessionInfo, state) == 12);
FOUNDRY_AGREE(offsetof(FoundryNetSessionInfo, epoch) == 16);
FOUNDRY_AGREE(offsetof(FoundryNetSessionInfo, peers) == 28);
FOUNDRY_AGREE(offsetof(FoundryNetSessionInfo, listening) == 30);
FOUNDRY_AGREE(offsetof(FoundryNetSessionInfo, listen_endpoint) == 32);

FOUNDRY_AGREE(sizeof(FoundryNetPeerInfo) == 24);
FOUNDRY_AGREE(offsetof(FoundryNetPeerInfo, participant) == 12);
FOUNDRY_AGREE(offsetof(FoundryNetPeerInfo, epoch) == 16);

FOUNDRY_AGREE(sizeof(FoundryNetEnding) == 16);
FOUNDRY_AGREE(offsetof(FoundryNetEnding, index) == 8);

FOUNDRY_AGREE(sizeof(FoundryNetEvent) == 48);
FOUNDRY_AGREE(offsetof(FoundryNetEvent, kind) == 16);
FOUNDRY_AGREE(offsetof(FoundryNetEvent, epoch) == 24);
FOUNDRY_AGREE(offsetof(FoundryNetEvent, ending) == 32);

FOUNDRY_AGREE(sizeof(FoundryNetDelivery) == 32);
FOUNDRY_AGREE(offsetof(FoundryNetDelivery, channel) == 8);
FOUNDRY_AGREE(offsetof(FoundryNetDelivery, sequence) == 24);

FOUNDRY_AGREE(sizeof(FoundryNetCommand) == 32);
FOUNDRY_AGREE(offsetof(FoundryNetCommand, bytes) == 12);
FOUNDRY_AGREE(offsetof(FoundryNetCommand, number) == 16);
FOUNDRY_AGREE(offsetof(FoundryNetCommand, channel) == 24);

FOUNDRY_AGREE(sizeof(FoundryNetStats) == 184);
FOUNDRY_AGREE(offsetof(FoundryNetStats, accepted) == 24);
FOUNDRY_AGREE(offsetof(FoundryNetStats, bytes_sent) == 176);

FOUNDRY_AGREE(sizeof(FoundryVec3) == 12);
FOUNDRY_AGREE(offsetof(FoundryVec3, x) == 0);
FOUNDRY_AGREE(sizeof(((FoundryVec3 *)0)->x) == 4);
FOUNDRY_AGREE(offsetof(FoundryVec3, y) == 4);
FOUNDRY_AGREE(sizeof(((FoundryVec3 *)0)->y) == 4);
FOUNDRY_AGREE(offsetof(FoundryVec3, z) == 8);
FOUNDRY_AGREE(sizeof(((FoundryVec3 *)0)->z) == 4);
FOUNDRY_AGREE(sizeof(FoundryQuat) == 16);
FOUNDRY_AGREE(offsetof(FoundryQuat, x) == 0);
FOUNDRY_AGREE(sizeof(((FoundryQuat *)0)->x) == 4);
FOUNDRY_AGREE(offsetof(FoundryQuat, y) == 4);
FOUNDRY_AGREE(sizeof(((FoundryQuat *)0)->y) == 4);
FOUNDRY_AGREE(offsetof(FoundryQuat, z) == 8);
FOUNDRY_AGREE(sizeof(((FoundryQuat *)0)->z) == 4);
FOUNDRY_AGREE(offsetof(FoundryQuat, w) == 12);
FOUNDRY_AGREE(sizeof(((FoundryQuat *)0)->w) == 4);
FOUNDRY_AGREE(sizeof(FoundryMat4) == 64);
FOUNDRY_AGREE(offsetof(FoundryMat4, elements) == 0);
FOUNDRY_AGREE(sizeof(((FoundryMat4 *)0)->elements) == 64);
FOUNDRY_AGREE(sizeof(FoundryTransform) == 40);
FOUNDRY_AGREE(offsetof(FoundryTransform, translation) == 0);
FOUNDRY_AGREE(sizeof(((FoundryTransform *)0)->translation) == 12);
FOUNDRY_AGREE(offsetof(FoundryTransform, rotation) == 12);
FOUNDRY_AGREE(sizeof(((FoundryTransform *)0)->rotation) == 16);
FOUNDRY_AGREE(offsetof(FoundryTransform, scale) == 28);
FOUNDRY_AGREE(sizeof(((FoundryTransform *)0)->scale) == 12);
FOUNDRY_AGREE(sizeof(FoundryPose3D) == 28);
FOUNDRY_AGREE(offsetof(FoundryPose3D, position) == 0);
FOUNDRY_AGREE(sizeof(((FoundryPose3D *)0)->position) == 12);
FOUNDRY_AGREE(offsetof(FoundryPose3D, rotation) == 12);
FOUNDRY_AGREE(sizeof(((FoundryPose3D *)0)->rotation) == 16);
FOUNDRY_AGREE(sizeof(FoundryCamera3D) == 48);
FOUNDRY_AGREE(offsetof(FoundryCamera3D, position) == 0);
FOUNDRY_AGREE(sizeof(((FoundryCamera3D *)0)->position) == 12);
FOUNDRY_AGREE(offsetof(FoundryCamera3D, rotation) == 12);
FOUNDRY_AGREE(sizeof(((FoundryCamera3D *)0)->rotation) == 16);
FOUNDRY_AGREE(offsetof(FoundryCamera3D, fov_y) == 28);
FOUNDRY_AGREE(sizeof(((FoundryCamera3D *)0)->fov_y) == 4);
FOUNDRY_AGREE(offsetof(FoundryCamera3D, near) == 32);
FOUNDRY_AGREE(sizeof(((FoundryCamera3D *)0)->near) == 4);
FOUNDRY_AGREE(offsetof(FoundryCamera3D, far) == 36);
FOUNDRY_AGREE(sizeof(((FoundryCamera3D *)0)->far) == 4);
FOUNDRY_AGREE(offsetof(FoundryCamera3D, width) == 40);
FOUNDRY_AGREE(sizeof(((FoundryCamera3D *)0)->width) == 4);
FOUNDRY_AGREE(offsetof(FoundryCamera3D, height) == 44);
FOUNDRY_AGREE(sizeof(((FoundryCamera3D *)0)->height) == 4);
FOUNDRY_AGREE(sizeof(FoundryLight3D) == 64);
FOUNDRY_AGREE(offsetof(FoundryLight3D, kind) == 0);
FOUNDRY_AGREE(sizeof(((FoundryLight3D *)0)->kind) == 4);
FOUNDRY_AGREE(offsetof(FoundryLight3D, color) == 4);
FOUNDRY_AGREE(sizeof(((FoundryLight3D *)0)->color) == 12);
FOUNDRY_AGREE(offsetof(FoundryLight3D, intensity) == 16);
FOUNDRY_AGREE(sizeof(((FoundryLight3D *)0)->intensity) == 4);
FOUNDRY_AGREE(offsetof(FoundryLight3D, range) == 20);
FOUNDRY_AGREE(sizeof(((FoundryLight3D *)0)->range) == 4);
FOUNDRY_AGREE(offsetof(FoundryLight3D, inner_cone) == 24);
FOUNDRY_AGREE(sizeof(((FoundryLight3D *)0)->inner_cone) == 4);
FOUNDRY_AGREE(offsetof(FoundryLight3D, outer_cone) == 28);
FOUNDRY_AGREE(sizeof(((FoundryLight3D *)0)->outer_cone) == 4);
FOUNDRY_AGREE(offsetof(FoundryLight3D, position) == 32);
FOUNDRY_AGREE(sizeof(((FoundryLight3D *)0)->position) == 12);
FOUNDRY_AGREE(offsetof(FoundryLight3D, rotation) == 44);
FOUNDRY_AGREE(sizeof(((FoundryLight3D *)0)->rotation) == 16);
FOUNDRY_AGREE(offsetof(FoundryLight3D, casts_shadow) == 60);
FOUNDRY_AGREE(sizeof(((FoundryLight3D *)0)->casts_shadow) == 1);
FOUNDRY_AGREE(offsetof(FoundryLight3D, reserved) == 61);
FOUNDRY_AGREE(sizeof(((FoundryLight3D *)0)->reserved) == 3);
FOUNDRY_AGREE(sizeof(FoundryShape3D) == 24);
FOUNDRY_AGREE(offsetof(FoundryShape3D, kind) == 0);
FOUNDRY_AGREE(sizeof(((FoundryShape3D *)0)->kind) == 4);
FOUNDRY_AGREE(offsetof(FoundryShape3D, radius) == 4);
FOUNDRY_AGREE(sizeof(((FoundryShape3D *)0)->radius) == 4);
FOUNDRY_AGREE(offsetof(FoundryShape3D, half_height) == 8);
FOUNDRY_AGREE(sizeof(((FoundryShape3D *)0)->half_height) == 4);
FOUNDRY_AGREE(offsetof(FoundryShape3D, half_extents) == 12);
FOUNDRY_AGREE(sizeof(((FoundryShape3D *)0)->half_extents) == 12);
FOUNDRY_AGREE(sizeof(FoundryFilter3D) == 16);
FOUNDRY_AGREE(offsetof(FoundryFilter3D, mask) == 0);
FOUNDRY_AGREE(sizeof(((FoundryFilter3D *)0)->mask) == 4);
FOUNDRY_AGREE(offsetof(FoundryFilter3D, reserved) == 4);
FOUNDRY_AGREE(sizeof(((FoundryFilter3D *)0)->reserved) == 4);
FOUNDRY_AGREE(offsetof(FoundryFilter3D, ignore) == 8);
FOUNDRY_AGREE(sizeof(((FoundryFilter3D *)0)->ignore) == 8);
FOUNDRY_AGREE(sizeof(FoundryBody3DDesc) == 72);
FOUNDRY_AGREE(offsetof(FoundryBody3DDesc, shape) == 0);
FOUNDRY_AGREE(sizeof(((FoundryBody3DDesc *)0)->shape) == 24);
FOUNDRY_AGREE(offsetof(FoundryBody3DDesc, pose) == 24);
FOUNDRY_AGREE(sizeof(((FoundryBody3DDesc *)0)->pose) == 28);
FOUNDRY_AGREE(offsetof(FoundryBody3DDesc, kind) == 52);
FOUNDRY_AGREE(sizeof(((FoundryBody3DDesc *)0)->kind) == 4);
FOUNDRY_AGREE(offsetof(FoundryBody3DDesc, layer) == 56);
FOUNDRY_AGREE(sizeof(((FoundryBody3DDesc *)0)->layer) == 4);
FOUNDRY_AGREE(offsetof(FoundryBody3DDesc, mask) == 60);
FOUNDRY_AGREE(sizeof(((FoundryBody3DDesc *)0)->mask) == 4);
FOUNDRY_AGREE(offsetof(FoundryBody3DDesc, user) == 64);
FOUNDRY_AGREE(sizeof(((FoundryBody3DDesc *)0)->user) == 8);
FOUNDRY_AGREE(sizeof(FoundryRayHit3D) == 64);
FOUNDRY_AGREE(offsetof(FoundryRayHit3D, distance) == 0);
FOUNDRY_AGREE(sizeof(((FoundryRayHit3D *)0)->distance) == 4);
FOUNDRY_AGREE(offsetof(FoundryRayHit3D, point) == 4);
FOUNDRY_AGREE(sizeof(((FoundryRayHit3D *)0)->point) == 12);
FOUNDRY_AGREE(offsetof(FoundryRayHit3D, normal) == 16);
FOUNDRY_AGREE(sizeof(((FoundryRayHit3D *)0)->normal) == 12);
FOUNDRY_AGREE(offsetof(FoundryRayHit3D, surface_normal) == 28);
FOUNDRY_AGREE(sizeof(((FoundryRayHit3D *)0)->surface_normal) == 12);
FOUNDRY_AGREE(offsetof(FoundryRayHit3D, body) == 40);
FOUNDRY_AGREE(sizeof(((FoundryRayHit3D *)0)->body) == 8);
FOUNDRY_AGREE(offsetof(FoundryRayHit3D, user) == 48);
FOUNDRY_AGREE(sizeof(((FoundryRayHit3D *)0)->user) == 8);
FOUNDRY_AGREE(offsetof(FoundryRayHit3D, triangle) == 56);
FOUNDRY_AGREE(sizeof(((FoundryRayHit3D *)0)->triangle) == 4);
FOUNDRY_AGREE(offsetof(FoundryRayHit3D, started_inside) == 60);
FOUNDRY_AGREE(sizeof(((FoundryRayHit3D *)0)->started_inside) == 1);
FOUNDRY_AGREE(offsetof(FoundryRayHit3D, reserved) == 61);
FOUNDRY_AGREE(sizeof(((FoundryRayHit3D *)0)->reserved) == 3);
FOUNDRY_AGREE(sizeof(FoundryHit3D) == 64);
FOUNDRY_AGREE(offsetof(FoundryHit3D, fraction) == 0);
FOUNDRY_AGREE(sizeof(((FoundryHit3D *)0)->fraction) == 4);
FOUNDRY_AGREE(offsetof(FoundryHit3D, point) == 4);
FOUNDRY_AGREE(sizeof(((FoundryHit3D *)0)->point) == 12);
FOUNDRY_AGREE(offsetof(FoundryHit3D, normal) == 16);
FOUNDRY_AGREE(sizeof(((FoundryHit3D *)0)->normal) == 12);
FOUNDRY_AGREE(offsetof(FoundryHit3D, surface_normal) == 28);
FOUNDRY_AGREE(sizeof(((FoundryHit3D *)0)->surface_normal) == 12);
FOUNDRY_AGREE(offsetof(FoundryHit3D, body) == 40);
FOUNDRY_AGREE(sizeof(((FoundryHit3D *)0)->body) == 8);
FOUNDRY_AGREE(offsetof(FoundryHit3D, user) == 48);
FOUNDRY_AGREE(sizeof(((FoundryHit3D *)0)->user) == 8);
FOUNDRY_AGREE(offsetof(FoundryHit3D, triangle) == 56);
FOUNDRY_AGREE(sizeof(((FoundryHit3D *)0)->triangle) == 4);
FOUNDRY_AGREE(offsetof(FoundryHit3D, started_inside) == 60);
FOUNDRY_AGREE(sizeof(((FoundryHit3D *)0)->started_inside) == 1);
FOUNDRY_AGREE(offsetof(FoundryHit3D, reserved) == 61);
FOUNDRY_AGREE(sizeof(((FoundryHit3D *)0)->reserved) == 3);
FOUNDRY_AGREE(sizeof(FoundryOverlap3D) == 24);
FOUNDRY_AGREE(offsetof(FoundryOverlap3D, body) == 0);
FOUNDRY_AGREE(sizeof(((FoundryOverlap3D *)0)->body) == 8);
FOUNDRY_AGREE(offsetof(FoundryOverlap3D, user) == 8);
FOUNDRY_AGREE(sizeof(((FoundryOverlap3D *)0)->user) == 8);
FOUNDRY_AGREE(offsetof(FoundryOverlap3D, triangle) == 16);
FOUNDRY_AGREE(sizeof(((FoundryOverlap3D *)0)->triangle) == 4);
FOUNDRY_AGREE(offsetof(FoundryOverlap3D, reserved) == 20);
FOUNDRY_AGREE(sizeof(((FoundryOverlap3D *)0)->reserved) == 4);
FOUNDRY_AGREE(sizeof(FoundryCharacterConfig) == 32);
FOUNDRY_AGREE(offsetof(FoundryCharacterConfig, radius) == 0);
FOUNDRY_AGREE(sizeof(((FoundryCharacterConfig *)0)->radius) == 4);
FOUNDRY_AGREE(offsetof(FoundryCharacterConfig, height) == 4);
FOUNDRY_AGREE(sizeof(((FoundryCharacterConfig *)0)->height) == 4);
FOUNDRY_AGREE(offsetof(FoundryCharacterConfig, max_slope) == 8);
FOUNDRY_AGREE(sizeof(((FoundryCharacterConfig *)0)->max_slope) == 4);
FOUNDRY_AGREE(offsetof(FoundryCharacterConfig, step_height) == 12);
FOUNDRY_AGREE(sizeof(((FoundryCharacterConfig *)0)->step_height) == 4);
FOUNDRY_AGREE(offsetof(FoundryCharacterConfig, snap_distance) == 16);
FOUNDRY_AGREE(sizeof(((FoundryCharacterConfig *)0)->snap_distance) == 4);
FOUNDRY_AGREE(offsetof(FoundryCharacterConfig, max_move) == 20);
FOUNDRY_AGREE(sizeof(((FoundryCharacterConfig *)0)->max_move) == 4);
FOUNDRY_AGREE(offsetof(FoundryCharacterConfig, layer) == 24);
FOUNDRY_AGREE(sizeof(((FoundryCharacterConfig *)0)->layer) == 4);
FOUNDRY_AGREE(offsetof(FoundryCharacterConfig, mask) == 28);
FOUNDRY_AGREE(sizeof(((FoundryCharacterConfig *)0)->mask) == 4);
FOUNDRY_AGREE(sizeof(FoundryCharacterMove) == 64);
FOUNDRY_AGREE(offsetof(FoundryCharacterMove, feet) == 0);
FOUNDRY_AGREE(sizeof(((FoundryCharacterMove *)0)->feet) == 12);
FOUNDRY_AGREE(offsetof(FoundryCharacterMove, ground_normal) == 12);
FOUNDRY_AGREE(sizeof(((FoundryCharacterMove *)0)->ground_normal) == 12);
FOUNDRY_AGREE(offsetof(FoundryCharacterMove, ground_body) == 24);
FOUNDRY_AGREE(sizeof(((FoundryCharacterMove *)0)->ground_body) == 8);
FOUNDRY_AGREE(offsetof(FoundryCharacterMove, ground_user) == 32);
FOUNDRY_AGREE(sizeof(((FoundryCharacterMove *)0)->ground_user) == 8);
FOUNDRY_AGREE(offsetof(FoundryCharacterMove, ground_triangle) == 40);
FOUNDRY_AGREE(sizeof(((FoundryCharacterMove *)0)->ground_triangle) == 4);
FOUNDRY_AGREE(offsetof(FoundryCharacterMove, walls) == 44);
FOUNDRY_AGREE(sizeof(((FoundryCharacterMove *)0)->walls) == 4);
FOUNDRY_AGREE(offsetof(FoundryCharacterMove, stepped) == 48);
FOUNDRY_AGREE(sizeof(((FoundryCharacterMove *)0)->stepped) == 4);
FOUNDRY_AGREE(offsetof(FoundryCharacterMove, grounded) == 52);
FOUNDRY_AGREE(sizeof(((FoundryCharacterMove *)0)->grounded) == 1);
FOUNDRY_AGREE(offsetof(FoundryCharacterMove, ceiling) == 53);
FOUNDRY_AGREE(sizeof(((FoundryCharacterMove *)0)->ceiling) == 1);
FOUNDRY_AGREE(offsetof(FoundryCharacterMove, snapped) == 54);
FOUNDRY_AGREE(sizeof(((FoundryCharacterMove *)0)->snapped) == 1);
FOUNDRY_AGREE(offsetof(FoundryCharacterMove, depenetrated) == 55);
FOUNDRY_AGREE(sizeof(((FoundryCharacterMove *)0)->depenetrated) == 1);
FOUNDRY_AGREE(offsetof(FoundryCharacterMove, stuck) == 56);
FOUNDRY_AGREE(sizeof(((FoundryCharacterMove *)0)->stuck) == 1);
FOUNDRY_AGREE(offsetof(FoundryCharacterMove, reserved) == 57);
FOUNDRY_AGREE(sizeof(((FoundryCharacterMove *)0)->reserved) == 7);
FOUNDRY_AGREE(sizeof(FoundryInstance) == 8);
FOUNDRY_AGREE(offsetof(FoundryInstance, bits) == 0);
FOUNDRY_AGREE(sizeof(FoundryLight) == 8);
FOUNDRY_AGREE(offsetof(FoundryLight, bits) == 0);
FOUNDRY_AGREE(sizeof(FoundryBody3D) == 8);
FOUNDRY_AGREE(offsetof(FoundryBody3D, bits) == 0);
FOUNDRY_AGREE(sizeof(FoundryCharacter) == 8);
FOUNDRY_AGREE(offsetof(FoundryCharacter, bits) == 0);
FOUNDRY_AGREE(sizeof(FoundryApi_v6) == sizeof(FoundryApi_v5) + 28 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, version) == offsetof(FoundryApi_v5, version));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, size) == offsetof(FoundryApi_v5, size));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, result_name) == offsetof(FoundryApi_v5, result_name));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, log_write) == offsetof(FoundryApi_v5, log_write));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, log_next) == offsetof(FoundryApi_v5, log_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, id_from_string) == offsetof(FoundryApi_v5, id_from_string));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, id_to_string) == offsetof(FoundryApi_v5, id_to_string));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, id_copy_string) == offsetof(FoundryApi_v5, id_copy_string));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, frame_index) == offsetof(FoundryApi_v5, frame_index));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, frame_delta_ns) == offsetof(FoundryApi_v5, frame_delta_ns));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, elapsed_ns) == offsetof(FoundryApi_v5, elapsed_ns));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, tick_delta_ns) == offsetof(FoundryApi_v5, tick_delta_ns));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, scope_begin) == offsetof(FoundryApi_v5, scope_begin));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, scope_end) == offsetof(FoundryApi_v5, scope_end));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, memory_counter_open) == offsetof(FoundryApi_v5, memory_counter_open));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, memory_counter_set) == offsetof(FoundryApi_v5, memory_counter_set));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, content_generation) == offsetof(FoundryApi_v5, content_generation));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, content_find) == offsetof(FoundryApi_v5, content_find));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, content_next) == offsetof(FoundryApi_v5, content_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, content_next_of_schema) == offsetof(FoundryApi_v5, content_next_of_schema));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, record_id) == offsetof(FoundryApi_v5, record_id));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, record_name) == offsetof(FoundryApi_v5, record_name));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, record_schema) == offsetof(FoundryApi_v5, record_schema));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, record_package) == offsetof(FoundryApi_v5, record_package));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, record_field_count) == offsetof(FoundryApi_v5, record_field_count));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, record_field_index) == offsetof(FoundryApi_v5, record_field_index));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, record_field_name) == offsetof(FoundryApi_v5, record_field_name));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, record_field_type) == offsetof(FoundryApi_v5, record_field_type));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, record_field_present) == offsetof(FoundryApi_v5, record_field_present));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, record_get_bool) == offsetof(FoundryApi_v5, record_get_bool));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, record_get_i64) == offsetof(FoundryApi_v5, record_get_i64));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, record_get_u64) == offsetof(FoundryApi_v5, record_get_u64));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, record_get_f32) == offsetof(FoundryApi_v5, record_get_f32));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, record_get_string) == offsetof(FoundryApi_v5, record_get_string));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, record_copy_string) == offsetof(FoundryApi_v5, record_copy_string));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, record_get_id) == offsetof(FoundryApi_v5, record_get_id));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, record_nested) == offsetof(FoundryApi_v5, record_nested));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, record_list_len) == offsetof(FoundryApi_v5, record_list_len));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, record_list_get_i64) == offsetof(FoundryApi_v5, record_list_get_i64));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, record_list_get_f32) == offsetof(FoundryApi_v5, record_list_get_f32));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, record_list_get_string) == offsetof(FoundryApi_v5, record_list_get_string));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, record_list_get_id) == offsetof(FoundryApi_v5, record_list_get_id));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, record_list_nested) == offsetof(FoundryApi_v5, record_list_nested));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, package_count) == offsetof(FoundryApi_v5, package_count));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, package_next) == offsetof(FoundryApi_v5, package_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, package_find) == offsetof(FoundryApi_v5, package_find));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, package_id) == offsetof(FoundryApi_v5, package_id));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, package_name) == offsetof(FoundryApi_v5, package_name));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, package_version) == offsetof(FoundryApi_v5, package_version));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, package_order) == offsetof(FoundryApi_v5, package_order));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, schema_count) == offsetof(FoundryApi_v5, schema_count));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, schema_next) == offsetof(FoundryApi_v5, schema_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, schema_find) == offsetof(FoundryApi_v5, schema_find));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, schema_id) == offsetof(FoundryApi_v5, schema_id));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, schema_version) == offsetof(FoundryApi_v5, schema_version));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, schema_field_count) == offsetof(FoundryApi_v5, schema_field_count));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, schema_field_name) == offsetof(FoundryApi_v5, schema_field_name));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, schema_field_type) == offsetof(FoundryApi_v5, schema_field_type));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, asset_acquire) == offsetof(FoundryApi_v5, asset_acquire));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, asset_release) == offsetof(FoundryApi_v5, asset_release));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, asset_find) == offsetof(FoundryApi_v5, asset_find));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, asset_next) == offsetof(FoundryApi_v5, asset_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, asset_content_id) == offsetof(FoundryApi_v5, asset_content_id));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, asset_schema) == offsetof(FoundryApi_v5, asset_schema));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, asset_refcount) == offsetof(FoundryApi_v5, asset_refcount));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_register_component) == offsetof(FoundryApi_v5, world_register_component));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_find_component_type) == offsetof(FoundryApi_v5, world_find_component_type));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_component_type_next) == offsetof(FoundryApi_v5, world_component_type_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_component_type_schema) == offsetof(FoundryApi_v5, world_component_type_schema));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_component_type_name) == offsetof(FoundryApi_v5, world_component_type_name));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_component_type_size) == offsetof(FoundryApi_v5, world_component_type_size));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_component_type_alignment) == offsetof(FoundryApi_v5, world_component_type_alignment));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_component_type_count) == offsetof(FoundryApi_v5, world_component_type_count));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_component_type_savable) == offsetof(FoundryApi_v5, world_component_type_savable));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_create_entity) == offsetof(FoundryApi_v5, world_create_entity));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_destroy_entity) == offsetof(FoundryApi_v5, world_destroy_entity));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_contains) == offsetof(FoundryApi_v5, world_contains));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_entity_count) == offsetof(FoundryApi_v5, world_entity_count));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_next_entity) == offsetof(FoundryApi_v5, world_next_entity));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_add_component) == offsetof(FoundryApi_v5, world_add_component));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_remove_component) == offsetof(FoundryApi_v5, world_remove_component));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_has_component) == offsetof(FoundryApi_v5, world_has_component));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_register_system) == offsetof(FoundryApi_v5, world_register_system));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_query_begin) == offsetof(FoundryApi_v5, world_query_begin));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_query_next) == offsetof(FoundryApi_v5, world_query_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_spawn) == offsetof(FoundryApi_v5, world_spawn));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_spawn_scene) == offsetof(FoundryApi_v5, world_spawn_scene));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_read_component) == offsetof(FoundryApi_v5, world_read_component));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_component_bytes) == offsetof(FoundryApi_v5, world_component_bytes));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, render_texture_of_asset) == offsetof(FoundryApi_v5, render_texture_of_asset));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, render_destroy_texture) == offsetof(FoundryApi_v5, render_destroy_texture));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, render_draw_sprite) == offsetof(FoundryApi_v5, render_draw_sprite));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, render_draw_text) == offsetof(FoundryApi_v5, render_draw_text));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, render_add_view) == offsetof(FoundryApi_v5, render_add_view));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, render_select_view) == offsetof(FoundryApi_v5, render_select_view));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, render_camera_get) == offsetof(FoundryApi_v5, render_camera_get));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, render_camera_set) == offsetof(FoundryApi_v5, render_camera_set));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, render_world_to_screen) == offsetof(FoundryApi_v5, render_world_to_screen));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, render_screen_to_world) == offsetof(FoundryApi_v5, render_screen_to_world));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, render_stats) == offsetof(FoundryApi_v5, render_stats));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_begin) == offsetof(FoundryApi_v5, ui_begin));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_end) == offsetof(FoundryApi_v5, ui_end));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_push_id) == offsetof(FoundryApi_v5, ui_push_id));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_pop_id) == offsetof(FoundryApi_v5, ui_pop_id));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_begin_panel) == offsetof(FoundryApi_v5, ui_begin_panel));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_end_panel) == offsetof(FoundryApi_v5, ui_end_panel));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_begin_row) == offsetof(FoundryApi_v5, ui_begin_row));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_end_row) == offsetof(FoundryApi_v5, ui_end_row));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_begin_scroll) == offsetof(FoundryApi_v5, ui_begin_scroll));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_end_scroll) == offsetof(FoundryApi_v5, ui_end_scroll));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_label) == offsetof(FoundryApi_v5, ui_label));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_button) == offsetof(FoundryApi_v5, ui_button));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_checkbox) == offsetof(FoundryApi_v5, ui_checkbox));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_slider) == offsetof(FoundryApi_v5, ui_slider));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_slider_int) == offsetof(FoundryApi_v5, ui_slider_int));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_separator) == offsetof(FoundryApi_v5, ui_separator));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_spacer) == offsetof(FoundryApi_v5, ui_spacer));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_collapsing_header) == offsetof(FoundryApi_v5, ui_collapsing_header));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_text_field) == offsetof(FoundryApi_v5, ui_text_field));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_plot) == offsetof(FoundryApi_v5, ui_plot));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_style_get) == offsetof(FoundryApi_v5, ui_style_get));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_style_set) == offsetof(FoundryApi_v5, ui_style_set));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_wants_keyboard) == offsetof(FoundryApi_v5, ui_wants_keyboard));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_wants_pointer) == offsetof(FoundryApi_v5, ui_wants_pointer));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, audio_play) == offsetof(FoundryApi_v5, audio_play));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, audio_stop) == offsetof(FoundryApi_v5, audio_stop));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, audio_set_gain) == offsetof(FoundryApi_v5, audio_set_gain));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, audio_set_pan) == offsetof(FoundryApi_v5, audio_set_pan));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, audio_set_pitch) == offsetof(FoundryApi_v5, audio_set_pitch));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, audio_set_master_gain) == offsetof(FoundryApi_v5, audio_set_master_gain));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, physics_create_body) == offsetof(FoundryApi_v5, physics_create_body));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, physics_destroy_body) == offsetof(FoundryApi_v5, physics_destroy_body));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, physics_move_body) == offsetof(FoundryApi_v5, physics_move_body));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, physics_query_point) == offsetof(FoundryApi_v5, physics_query_point));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, physics_query_aabb) == offsetof(FoundryApi_v5, physics_query_aabb));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, physics_query_ray) == offsetof(FoundryApi_v5, physics_query_ray));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, physics_body_contacts) == offsetof(FoundryApi_v5, physics_body_contacts));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, script_source_copy) == offsetof(FoundryApi_v5, script_source_copy));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, mods_installed_next) == offsetof(FoundryApi_v5, mods_installed_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, mods_pending_next) == offsetof(FoundryApi_v5, mods_pending_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, mods_requirement_next) == offsetof(FoundryApi_v5, mods_requirement_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, mods_conflict_next) == offsetof(FoundryApi_v5, mods_conflict_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, mods_provider_next) == offsetof(FoundryApi_v5, mods_provider_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, mods_profile_next) == offsetof(FoundryApi_v5, mods_profile_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, mods_profile_active) == offsetof(FoundryApi_v5, mods_profile_active));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, mods_set_enabled) == offsetof(FoundryApi_v5, mods_set_enabled));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, mods_move) == offsetof(FoundryApi_v5, mods_move));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, mods_revert) == offsetof(FoundryApi_v5, mods_revert));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, mods_apply) == offsetof(FoundryApi_v5, mods_apply));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, mods_profile_create) == offsetof(FoundryApi_v5, mods_profile_create));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, mods_profile_copy) == offsetof(FoundryApi_v5, mods_profile_copy));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, mods_profile_rename) == offsetof(FoundryApi_v5, mods_profile_rename));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, mods_profile_delete) == offsetof(FoundryApi_v5, mods_profile_delete));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, mods_profile_select) == offsetof(FoundryApi_v5, mods_profile_select));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_theme_resolve) == offsetof(FoundryApi_v5, ui_theme_resolve));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_theme_push) == offsetof(FoundryApi_v5, ui_theme_push));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_theme_pop) == offsetof(FoundryApi_v5, ui_theme_pop));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_begin_disabled) == offsetof(FoundryApi_v5, ui_begin_disabled));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_end_disabled) == offsetof(FoundryApi_v5, ui_end_disabled));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_region_remaining) == offsetof(FoundryApi_v5, ui_region_remaining));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_tabs) == offsetof(FoundryApi_v5, ui_tabs));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_selectable) == offsetof(FoundryApi_v5, ui_selectable));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_reorder_list) == offsetof(FoundryApi_v5, ui_reorder_list));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_reorder_button) == offsetof(FoundryApi_v5, ui_reorder_button));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_icon) == offsetof(FoundryApi_v5, ui_icon));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, ui_image) == offsetof(FoundryApi_v5, ui_image));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_workspace_next) == offsetof(FoundryApi_v5, author_workspace_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_workspace_info) == offsetof(FoundryApi_v5, author_workspace_info));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_workspace_revision) == offsetof(FoundryApi_v5, author_workspace_revision));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_workspace_limits) == offsetof(FoundryApi_v5, author_workspace_limits));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_document_next) == offsetof(FoundryApi_v5, author_document_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_document_info) == offsetof(FoundryApi_v5, author_document_info));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_document_create) == offsetof(FoundryApi_v5, author_document_create));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_document_refresh) == offsetof(FoundryApi_v5, author_document_refresh));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_document_discard) == offsetof(FoundryApi_v5, author_document_discard));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_document_copy_source) == offsetof(FoundryApi_v5, author_document_copy_source));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_schema_next) == offsetof(FoundryApi_v5, author_schema_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_schema_find) == offsetof(FoundryApi_v5, author_schema_find));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_schema_node_info) == offsetof(FoundryApi_v5, author_schema_node_info));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_schema_node_child) == offsetof(FoundryApi_v5, author_schema_node_child));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_schema_node_default) == offsetof(FoundryApi_v5, author_schema_node_default));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_record_next) == offsetof(FoundryApi_v5, author_record_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_dependency_next) == offsetof(FoundryApi_v5, author_dependency_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_dependency_record_next) == offsetof(FoundryApi_v5, author_dependency_record_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_preview_record_next) == offsetof(FoundryApi_v5, author_preview_record_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_node_info) == offsetof(FoundryApi_v5, author_node_info));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_node_child) == offsetof(FoundryApi_v5, author_node_child));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_node_field) == offsetof(FoundryApi_v5, author_node_field));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_node_scalar) == offsetof(FoundryApi_v5, author_node_scalar));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_node_copy_text) == offsetof(FoundryApi_v5, author_node_copy_text));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_record_create) == offsetof(FoundryApi_v5, author_record_create));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_record_duplicate) == offsetof(FoundryApi_v5, author_record_duplicate));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_record_override) == offsetof(FoundryApi_v5, author_record_override));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_record_delete) == offsetof(FoundryApi_v5, author_record_delete));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_value_set) == offsetof(FoundryApi_v5, author_value_set));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_value_unset) == offsetof(FoundryApi_v5, author_value_unset));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_list_insert) == offsetof(FoundryApi_v5, author_list_insert));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_list_remove) == offsetof(FoundryApi_v5, author_list_remove));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_list_move) == offsetof(FoundryApi_v5, author_list_move));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_undo) == offsetof(FoundryApi_v5, author_undo));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_redo) == offsetof(FoundryApi_v5, author_redo));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_save_document) == offsetof(FoundryApi_v5, author_save_document));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_save_all) == offsetof(FoundryApi_v5, author_save_all));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_save_entry_next) == offsetof(FoundryApi_v5, author_save_entry_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_validate) == offsetof(FoundryApi_v5, author_validate));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_diagnostic_next) == offsetof(FoundryApi_v5, author_diagnostic_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_build) == offsetof(FoundryApi_v5, author_build));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_build_info) == offsetof(FoundryApi_v5, author_build_info));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_build_release) == offsetof(FoundryApi_v5, author_build_release));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_export_next) == offsetof(FoundryApi_v5, author_export_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_build_export) == offsetof(FoundryApi_v5, author_build_export));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_preview_activate) == offsetof(FoundryApi_v5, author_preview_activate));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, author_preview_info) == offsetof(FoundryApi_v5, author_preview_info));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, net_grant_next) == offsetof(FoundryApi_v5, net_grant_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, net_session_create) == offsetof(FoundryApi_v5, net_session_create));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, net_session_close) == offsetof(FoundryApi_v5, net_session_close));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, net_session_info) == offsetof(FoundryApi_v5, net_session_info));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, net_channel_register) == offsetof(FoundryApi_v5, net_channel_register));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, net_channel_next) == offsetof(FoundryApi_v5, net_channel_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, net_session_listen) == offsetof(FoundryApi_v5, net_session_listen));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, net_session_connect) == offsetof(FoundryApi_v5, net_session_connect));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, net_peer_next) == offsetof(FoundryApi_v5, net_peer_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, net_peer_info) == offsetof(FoundryApi_v5, net_peer_info));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, net_peer_disconnect) == offsetof(FoundryApi_v5, net_peer_disconnect));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, net_event_next) == offsetof(FoundryApi_v5, net_event_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, net_stats) == offsetof(FoundryApi_v5, net_stats));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, net_baseline_send) == offsetof(FoundryApi_v5, net_baseline_send));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, net_baseline_acknowledge) == offsetof(FoundryApi_v5, net_baseline_acknowledge));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, net_state_publish) == offsetof(FoundryApi_v5, net_state_publish));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, net_command_send) == offsetof(FoundryApi_v5, net_command_send));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, net_delivery_next) == offsetof(FoundryApi_v5, net_delivery_next));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, net_delivery_take) == offsetof(FoundryApi_v5, net_delivery_take));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, net_batch_admit) == offsetof(FoundryApi_v5, net_batch_admit));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, net_batch_command) == offsetof(FoundryApi_v5, net_batch_command));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, net_batch_copy) == offsetof(FoundryApi_v5, net_batch_copy));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, render3d_instance_create) == sizeof(FoundryApi_v5) + 0 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, render3d_instance_destroy) == sizeof(FoundryApi_v5) + 1 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, render3d_instance_set_world) == sizeof(FoundryApi_v5) + 2 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, render3d_instance_set_material) == sizeof(FoundryApi_v5) + 3 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, render3d_instance_set_visible) == sizeof(FoundryApi_v5) + 4 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, render3d_light_create) == sizeof(FoundryApi_v5) + 5 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, render3d_light_set) == sizeof(FoundryApi_v5) + 6 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, render3d_light_destroy) == sizeof(FoundryApi_v5) + 7 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, render3d_camera_get) == sizeof(FoundryApi_v5) + 8 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_transform_get) == sizeof(FoundryApi_v5) + 9 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_transform_set) == sizeof(FoundryApi_v5) + 10 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_parent_get) == sizeof(FoundryApi_v5) + 11 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_parent_set) == sizeof(FoundryApi_v5) + 12 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, world_world_transform) == sizeof(FoundryApi_v5) + 13 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, physics3d_raycast) == sizeof(FoundryApi_v5) + 14 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, physics3d_shape_cast) == sizeof(FoundryApi_v5) + 15 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, physics3d_overlap) == sizeof(FoundryApi_v5) + 16 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, physics3d_body_create) == sizeof(FoundryApi_v5) + 17 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, physics3d_body_destroy) == sizeof(FoundryApi_v5) + 18 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, physics3d_body_set_pose) == sizeof(FoundryApi_v5) + 19 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, physics3d_body_set_filter) == sizeof(FoundryApi_v5) + 20 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, physics3d_body_get) == sizeof(FoundryApi_v5) + 21 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, physics3d_character_create) == sizeof(FoundryApi_v5) + 22 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, physics3d_character_destroy) == sizeof(FoundryApi_v5) + 23 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, physics3d_character_move) == sizeof(FoundryApi_v5) + 24 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, physics3d_character_set_feet) == sizeof(FoundryApi_v5) + 25 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, physics3d_character_feet) == sizeof(FoundryApi_v5) + 26 * sizeof(void (*)(void)));
FOUNDRY_AGREE(offsetof(FoundryApi_v6, physics3d_character_body) == sizeof(FoundryApi_v5) + 27 * sizeof(void (*)(void)));
uint64_t foundry_agreement_api_v6_size(void) { return sizeof(FoundryApi_v6); }
uint64_t foundry_agreement_api_v6_offset(uint64_t i) {
    static const uint64_t offsets[] = { offsetof(FoundryApi_v6, render3d_instance_create), offsetof(FoundryApi_v6, render3d_instance_destroy), offsetof(FoundryApi_v6, render3d_instance_set_world), offsetof(FoundryApi_v6, render3d_instance_set_material), offsetof(FoundryApi_v6, render3d_instance_set_visible), offsetof(FoundryApi_v6, render3d_light_create), offsetof(FoundryApi_v6, render3d_light_set), offsetof(FoundryApi_v6, render3d_light_destroy), offsetof(FoundryApi_v6, render3d_camera_get), offsetof(FoundryApi_v6, world_transform_get), offsetof(FoundryApi_v6, world_transform_set), offsetof(FoundryApi_v6, world_parent_get), offsetof(FoundryApi_v6, world_parent_set), offsetof(FoundryApi_v6, world_world_transform), offsetof(FoundryApi_v6, physics3d_raycast), offsetof(FoundryApi_v6, physics3d_shape_cast), offsetof(FoundryApi_v6, physics3d_overlap), offsetof(FoundryApi_v6, physics3d_body_create), offsetof(FoundryApi_v6, physics3d_body_destroy), offsetof(FoundryApi_v6, physics3d_body_set_pose), offsetof(FoundryApi_v6, physics3d_body_set_filter), offsetof(FoundryApi_v6, physics3d_body_get), offsetof(FoundryApi_v6, physics3d_character_create), offsetof(FoundryApi_v6, physics3d_character_destroy), offsetof(FoundryApi_v6, physics3d_character_move), offsetof(FoundryApi_v6, physics3d_character_set_feet), offsetof(FoundryApi_v6, physics3d_character_feet), offsetof(FoundryApi_v6, physics3d_character_body) };
    return i < 28 ? offsets[i] : UINT64_MAX;
}
