/*
 * An external authoring client that runs.
 *
 * `editor.md` §11 asks for a separate installed-header C consumer performing the same core
 * operations as the editor, so that authoring is a public capability and not a privilege of
 * one clever Zig host. This is that consumer: a C99 dynamic library that sees `foundry.h`
 * and the table it is handed, and nothing else. It creates a package where there was
 * nothing, fills the fields the manifest schema requires, saves, compiles and exports —
 * the editor's own sequence, written the way a C author has to write it.
 *
 * Every command invalidates every outstanding node handle, so the record is walked to
 * again before each field rather than kept. That is the rule the header states, and a C
 * client obeying it is the proof that it can be obeyed from C.
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "foundry.h"

static const FoundryApi_v4 *api;

static FoundryStr text(const char *s)
{
    FoundryStr out;
    out.ptr = (const uint8_t *)s;
    out.len = (uint64_t)strlen(s);
    return out;
}

/* The one record in the one document, found again after the last command replaced the
 * parse that the previous handle pointed into. */
static FoundryResult only_record(FoundryDocument document, FoundrySourceNode *out)
{
    FoundryCursor cursor = FOUNDRY_CURSOR_BEGIN;
    return api->author_record_next(document, &cursor, out);
}

static FoundryResult set_field(FoundryDocument document, uint64_t *revision,
                               const char *name, FoundryFieldType type, const char *value)
{
    FoundrySourceNode record;
    FoundrySourceNode field;
    FoundryAuthorValue wanted;
    FoundryAuthorEdit edit;
    FoundryResult result;

    result = only_record(document, &record);
    if (result != FOUNDRY_OK) return result;
    result = api->author_node_field(record, text(name), &field);
    if (result != FOUNDRY_OK) return result;

    memset(&wanted, 0, sizeof wanted);
    wanted.field_type = type;
    wanted.text = text(value);
    memset(&edit, 0, sizeof edit);
    result = api->author_value_set(field, *revision, &wanted, &edit);
    if (result != FOUNDRY_OK) return result;
    *revision = edit.revision;
    return FOUNDRY_OK;
}

FOUNDRY_EXPORT FoundryResult foundry_mod_init(FoundryGetApi get_api, FoundryMod self)
{
    FoundryCursor cursor = FOUNDRY_CURSOR_BEGIN;
    FoundryWorkspace workspace;
    FoundryDocument document;
    FoundryAuthorEdit edit;
    FoundryAuthorSaveAll saved;
    FoundryBuild build;
    FoundryResult result;
    uint64_t revision = 0;
    uint32_t written = 0;

    (void)self;
    api = (const FoundryApi_v4 *)get_api(FOUNDRY_API_VERSION_4);
    if (api == NULL) return FOUNDRY_ERR_UNSUPPORTED;
    if (api->version != FOUNDRY_API_VERSION_4) return FOUNDRY_ERR_UNSUPPORTED;

    result = api->author_workspace_next(&cursor, &workspace);
    if (result != FOUNDRY_OK) return result;
    result = api->author_workspace_revision(workspace, &revision);
    if (result != FOUNDRY_OK) return result;

    result = api->author_document_create(workspace, revision, text("mod.fdt"), &document);
    if (result != FOUNDRY_OK) return result;
    result = api->author_workspace_revision(workspace, &revision);
    if (result != FOUNDRY_OK) return result;

    memset(&edit, 0, sizeof edit);
    result = api->author_record_create(document, revision, text("foundry:mod"),
                                       text("cmod:pack"), &edit);
    if (result != FOUNDRY_OK) return result;
    revision = edit.revision;

    result = set_field(document, &revision, "name", FOUNDRY_FIELD_STRING, "C Consumer");
    if (result != FOUNDRY_OK) return result;
    result = set_field(document, &revision, "version", FOUNDRY_FIELD_U32, "2");
    if (result != FOUNDRY_OK) return result;
    result = set_field(document, &revision, "license", FOUNDRY_FIELD_STRING, "Apache-2.0");
    if (result != FOUNDRY_OK) return result;

    memset(&saved, 0, sizeof saved);
    result = api->author_save_all(workspace, revision, &saved);
    if (result != FOUNDRY_OK) return result;
    if (saved.complete == FOUNDRY_FALSE) return FOUNDRY_ERR_INTERNAL;
    revision = saved.revision;

    result = api->author_build(workspace, revision, &build);
    if (result != FOUNDRY_OK) return result;

    result = api->author_build_export(build, 0, &written);
    if (result != FOUNDRY_OK) return result;
    if (written != 1) return FOUNDRY_ERR_INTERNAL;

    return api->author_build_release(build);
}
