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
FOUNDRY_AGREE(sizeof(FoundryGrid) == 8);

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
