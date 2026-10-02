#include "foundry.h"
#include <math.h>
#include <string.h>

/* This library knows only the installed header. No host symbols or Zig imports. */
static const FoundryApi_v6 *api;
static FoundryMod owner;
static FoundryEntity parent, child;
static FoundryInstance instance;
static FoundryLight light;
static FoundryBody3D body;
static uint64_t ticks;
static int failed;

static FoundryContentId id(const char *s) { return foundry_content_id(s, strlen(s)); }
static FoundryStr str(const char *s) { return (FoundryStr){(const uint8_t *)s, strlen(s)}; }
static FoundryMat4 translated(float x, float y, float z)
{
    FoundryMat4 m = {{1,0,0,0, 0,1,0,0, 0,0,1,0, x,y,z,1}};
    return m;
}

static void update(void *ctx, const FoundryStep *step)
{
    FoundryMat4 world;
    FoundryTransform local;
    FoundryPose3D pose;
    FoundryLight3D lamp;
    float angle;
    (void)ctx;
    if (failed) return;
    /* The host already propagated this tick. Consume it, then write next tick's parent. */
    if (api->world_world_transform(child, &world) != FOUNDRY_OK ||
        api->world_transform_get(parent, &local) != FOUNDRY_OK) goto fault;
    pose.position = (FoundryVec3){world.elements[12], world.elements[13], world.elements[14]};
    pose.rotation = local.rotation;
    memset(&lamp, 0, sizeof(lamp));
    lamp.kind = 1; lamp.color = (FoundryVec3){0.5f,0.7f,1}; lamp.intensity = 80;
    lamp.range = 3; lamp.outer_cone = 0.7f; lamp.rotation.w = 1;
    lamp.position = pose.position; lamp.position.y += 1.2f;
    if (api->render3d_instance_set_world(instance, &world) != FOUNDRY_OK ||
        api->physics3d_body_set_pose(body, &pose) != FOUNDRY_OK ||
        api->render3d_light_set(light, &lamp) != FOUNDRY_OK) goto fault;
    ++ticks;
    angle = (float)(ticks % 720) * (float)step->delta_ns * 1e-9f * 0.5f;
    local.rotation = (FoundryQuat){0,sinf(angle * 0.5f),0,cosf(angle * 0.5f)};
    if (api->world_transform_set(parent, &local) != FOUNDRY_OK) goto fault;
    return;
fault:
    failed = 1;
    (void)api->log_write(owner, FOUNDRY_LOG_WARN, str("orbiter: update refused; motion stopped"));
}

FOUNDRY_EXPORT FoundryResult foundry_mod_init(FoundryGetApi get_api, FoundryMod self)
{
    FoundryRayHit3D floor;
    FoundryBool hit = 0;
    FoundryFilter3D filter = {1,0,{0}};
    FoundryTransform root = {{0,0.5f,2.0f},{0,0,0,1},{1,1,1}};
    FoundryTransform offset = {{0.15f,0,0},{0,0,0,1},{1,1,1}};
    FoundryBody3DDesc solid;
    FoundryLight3D lamp;
    FoundryMat4 world;
    FoundrySystemDesc system;
    /* No state survives a process: initialization is reproducible from content and floor. */
    parent.bits=child.bits=instance.bits=light.bits=body.bits=0; ticks=0; failed=0;
    owner = self;
    api = (const FoundryApi_v6 *)get_api(FOUNDRY_API_VERSION_6);
    if (!api || api->version != 6 || api->size != sizeof(*api)) return FOUNDRY_ERR_UNSUPPORTED;
#define OK(expr) do { FoundryResult r = (expr); if (r != FOUNDRY_OK) { \
    (void)api->log_write(owner,FOUNDRY_LOG_WARN,str("orbiter: initialization refused: " #expr)); \
    if (parent.bits) (void)api->world_destroy_entity(parent); \
    if (child.bits) (void)api->world_destroy_entity(child); return r; } } while (0)
    OK(api->physics3d_raycast((FoundryVec3){0,3,2},(FoundryVec3){0,-1,0},5,&filter,&floor,&hit));
    if (!hit) return FOUNDRY_ERR_NOT_FOUND;
    root.translation.y = floor.point.y + 0.5f;
    OK(api->world_create_entity(&parent));
    OK(api->world_transform_set(parent,&root));
    OK(api->world_create_entity(&child));
    OK(api->world_transform_set(child,&offset));
    OK(api->world_parent_set(child,parent,0));
    world = translated(root.translation.x + offset.translation.x,root.translation.y,root.translation.z);
    OK(api->render3d_instance_create(owner,id("orbiter:models.orbiter"),&world,&instance));
    OK(api->render3d_instance_set_material(instance,0,id("orbiter:materials.blue")));
    memset(&lamp,0,sizeof(lamp)); lamp.kind=1; lamp.color=(FoundryVec3){0.5f,0.7f,1};
    lamp.intensity=80; lamp.range=3; lamp.outer_cone=0.7f; lamp.rotation.w=1;
    lamp.position=(FoundryVec3){world.elements[12],world.elements[13]+1.2f,world.elements[14]};
    OK(api->render3d_light_create(owner,&lamp,&light));
    memset(&solid,0,sizeof(solid)); solid.shape.kind=2;
    solid.shape.half_extents=(FoundryVec3){0.4f,0.5f,0.25f}; solid.kind=1;
    solid.pose.position=(FoundryVec3){world.elements[12],world.elements[13],world.elements[14]};
    solid.pose.rotation.w=1; solid.layer=1; solid.mask=UINT32_MAX; solid.user=id("orbiter:solid").hash;
    OK(api->physics3d_body_create(owner,&solid,&body));
    memset(&system,0,sizeof(system)); system.id=id("orbiter:systems.turn");
    system.name=str("orbiter:systems.turn"); system.update=update;
    OK(api->world_register_system(owner,&system));
    (void)api->log_write(owner,FOUNDRY_LOG_INFO,str("orbiter: v6 initialized (instance, override, light, hierarchy, solid)"));
    return FOUNDRY_OK;
#undef OK
}

FOUNDRY_EXPORT void foundry_mod_shutdown(FoundryMod self)
{
    /* Best effort for handles another native mod may already have retired. The host's
     * unbind sweep releases any owned retained/physics objects still live afterwards. */
    (void)self;
    failed=1;
    if (body.bits) (void)api->physics3d_body_destroy(body);
    if (light.bits) (void)api->render3d_light_destroy(light);
    if (instance.bits) (void)api->render3d_instance_destroy(instance);
    if (parent.bits) (void)api->world_destroy_entity(parent);
    parent.bits=child.bits=instance.bits=light.bits=body.bits=0;
}
