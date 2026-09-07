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
    "asset_refcount"
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
    (uint64_t)offsetof(FoundryApi_v1, asset_refcount)
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
