/*
 * A background build from outside, in C (background.md §9.3, M27 Step 7).
 *
 * The same package author_mod.c writes, compiled twice: once by the synchronous v4
 * author_build, exported to destination 0, and once by a v7 job, started, polled until it
 * finishes and exported to destination 1. The host compares the two files byte for byte. A
 * validate job runs too, and a released job's handle is refused afterwards.
 *
 * It polls in a loop because a mod's init has no frame to poll from. An editor polls once a
 * frame instead, and draws in between.
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "foundry.h"

static const FoundryApi_v7 *api;

static FoundryStr text(const char *s)
{
    FoundryStr out;
    out.ptr = (const uint8_t *)s;
    out.len = (uint64_t)strlen(s);
    return out;
}

static FoundryResult set_field(FoundryDocument document, uint64_t *revision,
                               const char *name, FoundryFieldType type, const char *value)
{
    FoundryCursor cursor = FOUNDRY_CURSOR_BEGIN;
    FoundrySourceNode record;
    FoundrySourceNode field;
    FoundryAuthorValue wanted;
    FoundryAuthorEdit edit;
    FoundryResult result;

    result = api->author_record_next(document, &cursor, &record);
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

/* Starts a job and polls it until it is no longer pending. */
static FoundryResult run_job(FoundryWorkspace workspace, uint32_t kind, uint64_t revision,
                             FoundryAuthorJob *job, FoundryAuthorJobStatus *status)
{
    FoundryResult result = api->author_job_start(workspace, kind, revision, job);
    if (result != FOUNDRY_OK) return result;
    do {
        memset(status, 0, sizeof *status);
        result = api->author_job_poll(*job, status);
        if (result != FOUNDRY_OK) return result;
    } while (status->state == FOUNDRY_AUTHOR_JOB_PENDING);
    if (status->revision != revision) return FOUNDRY_ERR_INTERNAL;
    if (status->kind != (int32_t)kind) return FOUNDRY_ERR_INTERNAL;
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
    FoundryAuthorJob job;
    FoundryAuthorJobStatus status;
    FoundryAuthorJobStatus again;
    FoundryResult result;
    uint64_t revision = 0;
    uint32_t written = 0;

    (void)self;
    api = (const FoundryApi_v7 *)get_api(FOUNDRY_API_VERSION_7);
    if (api == NULL) return FOUNDRY_ERR_UNSUPPORTED;
    if (api->version != FOUNDRY_API_VERSION_7 || api->size != sizeof(FoundryApi_v7)) return FOUNDRY_ERR_UNSUPPORTED;

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
                                       text("cjob:pack"), &edit);
    if (result != FOUNDRY_OK) return result;
    revision = edit.revision;
    result = set_field(document, &revision, "name", FOUNDRY_FIELD_STRING, "C Job Consumer");
    if (result != FOUNDRY_OK) return result;
    result = set_field(document, &revision, "version", FOUNDRY_FIELD_U32, "3");
    if (result != FOUNDRY_OK) return result;
    result = set_field(document, &revision, "license", FOUNDRY_FIELD_STRING, "Apache-2.0");
    if (result != FOUNDRY_OK) return result;

    /* A validate job compiles the drafts, before anything is saved. */
    result = run_job(workspace, FOUNDRY_AUTHOR_JOB_VALIDATE, revision, &job, &status);
    if (result != FOUNDRY_OK) return result;
    if (status.state != FOUNDRY_AUTHOR_JOB_SUCCEEDED || status.build.bits != 0) return FOUNDRY_ERR_INTERNAL;
    result = api->author_job_release(job);
    if (result != FOUNDRY_OK) return result;
    if (api->author_job_poll(job, &status) != FOUNDRY_ERR_INVALID_HANDLE) return FOUNDRY_ERR_INTERNAL;

    memset(&saved, 0, sizeof saved);
    result = api->author_save_all(workspace, revision, &saved);
    if (result != FOUNDRY_OK) return result;
    if (saved.complete == FOUNDRY_FALSE) return FOUNDRY_ERR_INTERNAL;
    revision = saved.revision;

    /* The synchronous build, to destination 0. */
    result = api->author_build(workspace, revision, &build);
    if (result != FOUNDRY_OK) return result;
    result = api->author_build_export(build, 0, &written);
    if (result != FOUNDRY_OK) return result;
    if (written != 1) return FOUNDRY_ERR_INTERNAL;
    result = api->author_build_release(build);
    if (result != FOUNDRY_OK) return result;

    /* The same saved bytes through a job, to destination 1. */
    result = run_job(workspace, FOUNDRY_AUTHOR_JOB_BUILD, revision, &job, &status);
    if (result != FOUNDRY_OK) return result;
    if (status.state != FOUNDRY_AUTHOR_JOB_SUCCEEDED || status.result != FOUNDRY_OK) return FOUNDRY_ERR_INTERNAL;
    /* Answered again, with the same build. */
    result = api->author_job_poll(job, &again);
    if (result != FOUNDRY_OK) return result;
    if (again.build.bits != status.build.bits || again.state != status.state) return FOUNDRY_ERR_INTERNAL;
    result = api->author_build_export(status.build, 1, &written);
    if (result != FOUNDRY_OK) return result;
    if (written != 1) return FOUNDRY_ERR_INTERNAL;
    result = api->author_job_release(job);
    if (result != FOUNDRY_OK) return result;
    if (api->author_job_release(job) != FOUNDRY_ERR_INVALID_HANDLE) return FOUNDRY_ERR_INTERNAL;

    /* A stale revision is refused at the start, as author_build refuses it. */
    if (api->author_job_start(workspace, FOUNDRY_AUTHOR_JOB_BUILD, revision + 1, &job) != FOUNDRY_ERR_REFUSED)
        return FOUNDRY_ERR_INTERNAL;
    return api->author_build_release(status.build);
}
