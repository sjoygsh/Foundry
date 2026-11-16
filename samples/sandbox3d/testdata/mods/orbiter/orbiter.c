#include "foundry.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

/* This library knows only the installed header. No host symbols or Zig imports. */
static const FoundryApi_v8 *api;
static FoundryMod owner;
static FoundryEntity parent, child;
static FoundryInstance instance;
static FoundryLight light;
static FoundryBody3D body;
static uint64_t ticks;
/* Where the turn is, in ticks of the ordinary rate: equal to `ticks` until spin is first held,
 * so a run that never spins makes M25's poses bit for bit. */
static int64_t turns;
static uint64_t spun;
static int failed;

static FoundryContentId id(const char *s) { return foundry_content_id(s, strlen(s)); }
static FoundryStr str(const char *s) { return (FoundryStr){(const uint8_t *)s, strlen(s)}; }
static FoundryMat4 translated(float x, float y, float z)
{
    FoundryMat4 m = {{1,0,0,0, 0,1,0,0, 0,0,1,0, x,y,z,1}};
    return m;
}

/* v8, inside the system: this step's view of the action and the keyboard (ADR-0090). Held,
 * four ticks of turn a tick; with a shift held too, four back. A host with no input, or content
 * without the action, turns at the ordinary rate. */
static int64_t spin_rate(void)
{
    FoundryActionState spin;
    FoundryKeyboardState keys;
    int64_t rate = 4;
    if (api->input_action(id("orbiter:action.spin"), &spin) != FOUNDRY_OK) return 1;
    if (spin.pressed) (void)api->log_write(owner, FOUNDRY_LOG_INFO, str("orbiter: spin held"));
    if (spin.released) {
        char line[96];
        (void)snprintf(line, sizeof line, "orbiter: spin released after %llu ticks at four times the turn",
                       (unsigned long long)spun);
        (void)api->log_write(owner, FOUNDRY_LOG_INFO, str(line));
        spun = 0;
    }
    if (!spin.held) return 1;
    ++spun;
    if (api->input_keyboard(&keys) == FOUNDRY_OK && (keys.modifiers & FOUNDRY_MODIFIER_SHIFT)) rate = -4;
    return rate;
}

/* Says once where spin is bound, with the player's layout's label for a key (v8). */
static void announce(void)
{
    FoundryBinding binding;
    FoundryStr label;
    uint32_t count = 0, i, key;
    char line[96];
    size_t len;
    if (api->input_action_binding_count(id("orbiter:action.spin"), &count) != FOUNDRY_OK) {
        (void)api->log_write(owner, FOUNDRY_LOG_INFO, str("orbiter: no spin action; turning at one rate"));
        return;
    }
    for (i = 0; i < count; ++i) {
        if (api->input_action_binding(id("orbiter:action.spin"), i, &binding) != FOUNDRY_OK) continue;
        if (binding.source.len < 5 || memcmp(binding.source.ptr, "key.", 4) != 0) continue;
        if (api->input_key_from_name((FoundryStr){binding.source.ptr + 4, binding.source.len - 4}, &key) != FOUNDRY_OK) continue;
        if (api->input_key_label(key, &label) != FOUNDRY_OK || label.len == 0 || label.len > 16) continue;
        len = strlen("orbiter: spin is held on ");
        memcpy(line, "orbiter: spin is held on ", len);
        memcpy(line + len, label.ptr, (size_t)label.len);
        len += (size_t)label.len;
        memcpy(line + len, " or a pad's north", strlen(" or a pad's north") + 1);
        (void)api->log_write(owner, FOUNDRY_LOG_INFO, str(line));
        return;
    }
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
    turns += spin_rate();
    angle = (float)(((turns % 720) + 720) % 720) * (float)step->delta_ns * 1e-9f * 0.5f;
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
    parent.bits=child.bits=instance.bits=light.bits=body.bits=0; ticks=0; turns=0; spun=0; failed=0;
    owner = self;
    api = (const FoundryApi_v8 *)get_api(FOUNDRY_API_VERSION_8);
    if (!api || api->version != 8 || api->size != sizeof(*api)) return FOUNDRY_ERR_UNSUPPORTED;
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
    announce();
    (void)api->log_write(owner,FOUNDRY_LOG_INFO,str("orbiter: v8 initialized (instance, override, light, hierarchy, solid, spin)"));
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
