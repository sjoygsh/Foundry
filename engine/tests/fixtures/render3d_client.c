#include "foundry.h"
#include <string.h>

/* C99 runtime conformance: only the installed public vocabulary crosses here. */
static uint32_t failure_line;
static uint32_t calls;
static const FoundryApi_v6 *api;
static FoundryEntity pending_entity;
#define CHECK(expr) do { if (!(expr)) { failure_line = __LINE__; return FOUNDRY_ERR_REFUSED; } } while (0)
#define OK(expr) do { CHECK((expr) == FOUNDRY_OK); ++calls; } while (0)
FOUNDRY_EXPORT uint32_t foundry_test_failure(void) { return failure_line; }
FOUNDRY_EXPORT uint32_t foundry_test_calls(void) { return calls; }

static void after_propagation(void *ctx, const FoundryStep *step)
{
    FoundryMat4 derived;
    const FoundryMat4 identity={{1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}};
    (void)ctx; (void)step;
    if(pending_entity.bits==0) return;
    if(api->world_world_transform(pending_entity,&derived)!=FOUNDRY_OK ||
       memcmp(&derived,&identity,sizeof(identity))!=0 ||
       api->world_destroy_entity(pending_entity)!=FOUNDRY_OK) failure_line=__LINE__;
    else ++calls;
    pending_entity.bits=0;
}

FoundryResult foundry_render3d_client(const FoundryApi_v6 *a, FoundryMod self)
{
    FoundryMat4 world = {{1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1}};
    FoundryTransform local = {{0,0,0}, {0,0,0,1}, {1,1,1}}, read;
    FoundryPose3D pose = {{0,0,0}, {0,0,0,1}};
    FoundryShape3D shape = {0,1,0,{0,0,0}};
    FoundryLight3D lamp;
    FoundryBody3DDesc desc, body_read;
    FoundryCharacterConfig config = {0.3f,1.8f,0.7f,0.2f,0.1f,1,2,1};
    FoundryFilter3D filter = {UINT32_MAX,0,{0}};
    FoundryInstance instance = {0};
    FoundryLight light = {0};
    FoundryBody3D body = {0}, backing = {0};
    FoundryCharacter character = {0};
    FoundryEntity entity = {0}, parent = {0};
    FoundryCamera3D camera;
    FoundryRayHit3D ray;
    FoundryHit3D cast;
    FoundryOverlap3D overlap[1];
    FoundryCharacterMove move;
    FoundryVec3 feet;
    FoundryBool hit = 0;
    uint32_t count = 0, total = 0;
    FoundrySystemDesc system;
    const FoundryContentId model = foundry_content_id("demo:models.pair",16);
    const FoundryContentId material = foundry_content_id("demo:materials.crate",20);
    api = a;
    memset(&lamp,0,sizeof(lamp)); memset(&desc,0,sizeof(desc)); memset(&system,0,sizeof(system));
    lamp.kind = 1; lamp.color = (FoundryVec3){1,1,1}; lamp.intensity = 10;
    lamp.range = 4; lamp.outer_cone = 0.7f; lamp.rotation.w = 1;
    desc.shape = shape; desc.pose = pose; desc.kind = 1;
    desc.layer = 1; desc.mask = UINT32_MAX; desc.user = UINT64_C(0x123456789abcdef0);
    OK(api->render3d_instance_create(self,model,&world,&instance));
    world.elements[12] = 2;
    OK(api->render3d_instance_set_world(instance,&world));
    OK(api->render3d_instance_set_material(instance,0,material));
    OK(api->render3d_instance_set_visible(instance,1));
    OK(api->render3d_light_create(self,&lamp,&light));
    lamp.intensity = 20;
    OK(api->render3d_light_set(light,&lamp));
    OK(api->render3d_camera_get(&camera));
    CHECK(camera.width == 32 && camera.height == 32 && camera.rotation.w == 1);
    CHECK(api->world_create_entity(&entity) == FOUNDRY_OK);
    OK(api->world_transform_set(entity,&local));
    OK(api->world_transform_get(entity,&read));
    CHECK(memcmp(&read,&local,sizeof(read)) == 0);
    OK(api->world_parent_set(entity,(FoundryEntity){0},0));
    OK(api->world_parent_get(entity,&parent)); CHECK(parent.bits == 0);
    /* Derived state is absent until the host propagates, not synthesized by a read. */
    CHECK(api->world_world_transform(entity,&world) == FOUNDRY_ERR_NOT_FOUND); ++calls;
    OK(api->physics3d_body_create(self,&desc,&body));
    OK(api->physics3d_body_get(body,&body_read));
    CHECK(body_read.user == desc.user && body_read.shape.radius == 1);
    pose.position.x = 3;
    OK(api->physics3d_body_set_pose(body,&pose));
    OK(api->physics3d_body_set_filter(body,1,UINT32_MAX));
    OK(api->physics3d_raycast((FoundryVec3){3,5,0},(FoundryVec3){0,-1,0},10,&filter,&ray,&hit));
    CHECK(hit == 1 && ray.body.bits == body.bits && ray.user == desc.user);
    pose.position.y = 5;
    OK(api->physics3d_shape_cast(&shape,&pose,(FoundryVec3){0,-8,0},&filter,&cast,&hit));
    CHECK(hit == 1 && cast.body.bits == body.bits);
    pose.position.y = 0;
    OK(api->physics3d_overlap(&shape,&pose,&filter,overlap,1,&count,&total));
    CHECK(count == 1 && total == 1 && overlap[0].body.bits == body.bits);
    OK(api->physics3d_character_create(self,&config,(FoundryVec3){10,0,0},345,&character));
    OK(api->physics3d_character_feet(character,&feet)); CHECK(feet.x == 10);
    OK(api->physics3d_character_body(character,&backing)); CHECK(backing.bits != 0);
    OK(api->physics3d_character_set_feet(character,(FoundryVec3){11,0,0}));
    OK(api->physics3d_character_move(character,(FoundryVec3){0.2f,0,0},&move));
    CHECK(move.feet.x > 11 && move.feet.x < 12);
    OK(api->physics3d_character_destroy(character));
    OK(api->physics3d_body_destroy(body));
    OK(api->render3d_light_destroy(light));
    OK(api->render3d_instance_destroy(instance));
    pending_entity=entity;
    system.id=foundry_content_id("native:conformance",18);
    system.name=(FoundryStr){(const uint8_t *)"native:conformance",18};
    system.update=after_propagation;
    CHECK(api->world_register_system(self,&system)==FOUNDRY_OK);
    CHECK(calls == 28);
    return FOUNDRY_OK;
}

FOUNDRY_EXPORT FoundryResult foundry_mod_init(FoundryGetApi get_api, FoundryMod self)
{
    const FoundryApi_v6 *a = (const FoundryApi_v6 *)get_api(FOUNDRY_API_VERSION_6);
    failure_line = 0; calls = 0;
    if (a == NULL || a->version != 6 || a->size != sizeof(*a)) return FOUNDRY_ERR_UNSUPPORTED;
    return foundry_render3d_client(a,self);
}
