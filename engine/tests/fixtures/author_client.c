/*
 * What an external authoring client looks like: nothing but `foundry.h` and the table it
 * asks for. It calls every v4 authoring entry point, so a parameter a C author cannot
 * express, or a type only Zig can construct, is a compile error here rather than a
 * discovery in somebody's editor.
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "foundry.h"

/* The header's cursor initialiser is a braced initialiser, so C99 can only use it where
 * one belongs. This is the ordinary way to reach for it again mid-function. */
static FoundryCursor cursor_begin(void)
{
    FoundryCursor c = FOUNDRY_CURSOR_BEGIN;
    return c;
}

static FoundryStr text(const char *s)
{
    FoundryStr out;
    out.ptr = (const uint8_t *)s;
    out.len = (uint64_t)strlen(s);
    return out;
}

FOUNDRY_EXPORT FoundryResult foundry_mod_init(FoundryGetApi get_api, FoundryMod self)
{
    const FoundryApi_v4 *api = (const FoundryApi_v4 *)get_api(FOUNDRY_API_VERSION_4);
    FoundryCursor cursor = cursor_begin();
    FoundryWorkspace workspace;
    FoundryAuthorWorkspaceInfo workspace_info;
    FoundryAuthorLimits limits;
    FoundryDocument document;
    FoundryAuthorDocumentInfo document_info;
    FoundrySchemaNode schema, child;
    FoundryAuthorSchemaNodeInfo schema_info;
    FoundrySourceNode node, field, other;
    FoundryAuthorNodeInfo node_info;
    FoundryAuthorPackageInfo package_info;
    FoundryAuthorValue value;
    FoundryAuthorEdit edit;
    FoundryAuthorSaveResult saved;
    FoundryAuthorSaveAll save_all;
    FoundryAuthorSaveEntry save_entry;
    FoundryAuthorDiagnostic diagnostic;
    FoundryBuild build;
    FoundryAuthorBuildInfo build_info;
    FoundryAuthorExportInfo export_info;
    FoundryAuthorPreviewInfo preview;
    uint8_t buffer[256];
    uint64_t revision = 0;
    uint64_t needed = 0;
    uint32_t written = 0;

    (void)self;
    if (api == NULL) return FOUNDRY_ERR_UNSUPPORTED;
    if (api->version != FOUNDRY_API_VERSION_4) return FOUNDRY_ERR_UNSUPPORTED;
    if (api->size != (uint32_t)sizeof(FoundryApi_v4)) return FOUNDRY_ERR_UNSUPPORTED;

    /* Every value this client hands over starts zeroed, which is the one construction a C
     * author always has. A reserved byte it does not know about is therefore zero. */
    memset(&value, 0, sizeof value);

    if (api->author_workspace_next(&cursor, &workspace) != FOUNDRY_OK) return FOUNDRY_OK;
    api->author_workspace_info(workspace, &workspace_info);
    api->author_workspace_revision(workspace, &revision);
    api->author_workspace_limits(workspace, &limits);

    /* Documents. */
    cursor = cursor_begin();
    if (api->author_document_next(workspace, &cursor, &document) != FOUNDRY_OK) return FOUNDRY_OK;
    api->author_document_info(document, &document_info);
    api->author_document_copy_source(document, buffer, (uint64_t)sizeof buffer, &needed);
    api->author_document_create(workspace, revision, text("extra.fdt"), &document);
    api->author_document_refresh(document, revision, &revision);
    api->author_document_discard(document, revision, &revision);

    /* The schema tree. */
    cursor = cursor_begin();
    api->author_schema_next(workspace, &cursor, &schema);
    api->author_schema_find(workspace, text("foundry:mod"), &schema);
    api->author_schema_node_info(schema, &schema_info);
    api->author_schema_node_child(schema, 0, &child);
    api->author_schema_node_default(child, &node);

    /* The source, dependency and preview trees. */
    cursor = cursor_begin();
    api->author_record_next(document, &cursor, &node);
    cursor = cursor_begin();
    api->author_dependency_next(workspace, &cursor, &package_info);
    cursor = cursor_begin();
    api->author_dependency_record_next(workspace, 0, &cursor, &other);
    cursor = cursor_begin();
    api->author_preview_record_next(workspace, &cursor, &other);
    api->author_node_info(node, &node_info);
    api->author_node_child(node, 0, &field);
    api->author_node_field(node, text("name"), &field);
    api->author_node_scalar(field, &value);
    api->author_node_copy_text(field, buffer, (uint64_t)sizeof buffer, &needed);

    /* Commands. A value the client builds itself: the declared kind plus the spelling. */
    value.field_type = FOUNDRY_FIELD_STRING;
    value.text = text("a name an author typed");
    api->author_record_create(document, revision, text("foundry:mod"), text("demo:new"), &edit);
    api->author_record_duplicate(node, document, revision, text("demo:copy"), &edit);
    api->author_record_override(other, document, revision, &edit);
    api->author_value_set(field, revision, &value, &edit);
    api->author_value_unset(field, revision, &edit);
    api->author_list_insert(field, revision, 0, &value, &edit);
    api->author_list_remove(field, revision, 0, &edit);
    api->author_list_move(field, revision, 0, 1, &edit);
    api->author_record_delete(node, revision, &edit);
    api->author_undo(workspace, revision, &edit);
    api->author_redo(workspace, revision, &edit);

    /* Persistence. */
    api->author_save_document(document, revision, &saved);
    api->author_save_all(workspace, revision, &save_all);
    cursor = cursor_begin();
    api->author_save_entry_next(workspace, &cursor, &save_entry);

    /* Diagnostics, which is how a client learns what went wrong above. */
    api->author_validate(workspace, revision);
    cursor = cursor_begin();
    while (api->author_diagnostic_next(workspace, &cursor, &diagnostic) == FOUNDRY_OK) {
        if (diagnostic.severity == FOUNDRY_AUTHOR_ERROR) break;
    }

    /* Products. */
    if (api->author_build(workspace, revision, &build) == FOUNDRY_OK) {
        api->author_build_info(build, &build_info);
        cursor = cursor_begin();
        while (api->author_export_next(workspace, &cursor, &export_info) == FOUNDRY_OK) {
            if (export_info.kind == FOUNDRY_AUTHOR_EXPORT_COMPILED) {
                api->author_build_export(build, export_info.index, &written);
            }
        }
        if (api->author_preview_activate(build) == FOUNDRY_ERR_UNAVAILABLE) {
            /* Editing, saving and building all work without a preview grant. */
        }
        api->author_preview_info(workspace, &preview);
        api->author_build_release(build);
    }

    return FOUNDRY_OK;
}
