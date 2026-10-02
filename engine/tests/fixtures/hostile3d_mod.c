#include "foundry.h"
#include <string.h>

/* Real native adversary. Invalid addresses are deliberately not used: Tier 3 is
 * not a memory sandbox. Every pointer here is NULL or points at sized storage. */
static FoundryInstance foreign_instance;
static FoundryLight foreign_light;
static FoundryBody3D foreign_body, host_body;
static FoundryCharacter foreign_character;
static FoundryEntity entity;
static FoundryMod foreign_mod;
static FoundryEntity deep_parent, singular_parent, shear_parent;
static FoundryBody3D hull_body;
static uint32_t failure_line, checks;
FOUNDRY_EXPORT void foundry_test_targets(FoundryInstance i, FoundryLight l,
    FoundryBody3D b, FoundryCharacter c, FoundryBody3D h, FoundryEntity e, FoundryMod m)
{
    foreign_instance=i; foreign_light=l; foreign_body=b; foreign_character=c;
    host_body=h; entity=e; foreign_mod=m;
}
FOUNDRY_EXPORT uint32_t foundry_test_failure(void) { return failure_line; }
FOUNDRY_EXPORT uint32_t foundry_test_calls(void) { return checks; }
FOUNDRY_EXPORT void foundry_test_extra(FoundryEntity deep, FoundryEntity singular,
    FoundryEntity shear, FoundryBody3D hull)
{ deep_parent=deep; singular_parent=singular; shear_parent=shear; hull_body=hull; }
#define EXPECT(call,code) do { ++checks; if ((call)!=(code)) { failure_line=__LINE__; return FOUNDRY_ERR_REFUSED; } } while(0)
#define BAD(call) EXPECT(call,FOUNDRY_ERR_INVALID_ARGUMENT)
#define REFUSED(call) EXPECT(call,FOUNDRY_ERR_REFUSED)
#define OK(call) EXPECT(call,FOUNDRY_OK)
/* Poison every float in a contiguous float portion, including dormant fields.
 * memcpy avoids aliasing and alignment assumptions across this C boundary. */
#define POISON(value,first,last,call) do { \
    size_t off; unsigned p; \
    const uint32_t bits[3]={UINT32_C(0x7fc00001),UINT32_C(0x7f800000),UINT32_C(0xff800000)}; \
    unsigned char saved[sizeof(value)]; memcpy(saved,&(value),sizeof(value)); \
    for(off=(first);off<(last);off+=4) for(p=0;p<3;++p) { \
        memcpy(&(value),saved,sizeof(value)); memcpy((unsigned char *)&(value)+off,&bits[p],4); BAD(call); \
    } memcpy(&(value),saved,sizeof(value)); \
} while(0)

FOUNDRY_EXPORT FoundryResult foundry_mod_init(FoundryGetApi get_api, FoundryMod self)
{
    const FoundryApi_v6 *a=(const FoundryApi_v6 *)get_api(6);
    FoundryMat4 matrix={{1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}}, derived;
    FoundryTransform transform={{0,0,0},{0,0,0,1},{1,1,1}};
    FoundryPose3D pose={{20,0,0},{0,0,0,1}};
    FoundryShape3D shape={0,1,0,{0,0,0}};
    FoundryFilter3D filter={UINT32_MAX,0,{0}};
    FoundryBody3DDesc desc={0}, read;
    FoundryCharacterConfig config={0.3f,1.8f,0.7f,0.2f,0.1f,1,2,1};
    FoundryLight3D lamp={0};
    FoundryInstance instance={0}, out_instance={UINT64_C(0x5a5a5a5a5a5a5a5a)};
    FoundryLight light={0}, out_light={UINT64_C(0x5a5a5a5a5a5a5a5a)};
    FoundryBody3D body={0}, stale={0}, out_body={UINT64_C(0x5a5a5a5a5a5a5a5a)};
    FoundryCharacter character={0}, out_character={UINT64_C(0x5a5a5a5a5a5a5a5a)};
    FoundryCamera3D camera;
    FoundryVec3 v={0,0,0}, direction={0,-1,0};
    FoundryRayHit3D ray;
    FoundryHit3D hit;
    FoundryOverlap3D overlap[4096];
    FoundryCharacterMove moved;
    FoundryBool found=0;
    FoundryEntity parent={0};
    uint32_t count=0,total=0,n;
    float distance=10;
    const FoundryContentId model=foundry_content_id("demo:models.pair",16);
    failure_line=0; checks=0;
    if(a==NULL) return FOUNDRY_ERR_UNSUPPORTED;
    lamp.kind=1; lamp.color=(FoundryVec3){1,1,1}; lamp.intensity=10;
    lamp.range=4; lamp.outer_cone=0.7f; lamp.rotation.w=1;
    desc.shape=shape; desc.pose=pose; desc.kind=1; desc.layer=1; desc.mask=UINT32_MAX;
    OK(a->render3d_instance_create(self,model,&matrix,&instance));
    OK(a->render3d_light_create(self,&lamp,&light));
    OK(a->physics3d_body_create(self,&desc,&body));
    OK(a->physics3d_character_create(self,&config,(FoundryVec3){30,0,0},0,&character));

    /* Null parameters, including each independently nullable output/input. */
    BAD(a->render3d_instance_create(self,model,NULL,&out_instance));
    BAD(a->render3d_instance_create(self,model,&matrix,NULL));
    BAD(a->render3d_instance_set_world(instance,NULL));
    BAD(a->render3d_light_create(self,NULL,&out_light));
    BAD(a->render3d_light_create(self,&lamp,NULL)); BAD(a->render3d_light_set(light,NULL));
    BAD(a->render3d_camera_get(NULL)); BAD(a->world_transform_get(entity,NULL));
    BAD(a->world_transform_set(entity,NULL)); BAD(a->world_parent_get(entity,NULL));
    BAD(a->world_world_transform(entity,NULL));
    BAD(a->physics3d_raycast(v,direction,distance,NULL,&ray,&found));
    BAD(a->physics3d_raycast(v,direction,distance,&filter,NULL,&found));
    BAD(a->physics3d_raycast(v,direction,distance,&filter,&ray,NULL));
    BAD(a->physics3d_shape_cast(NULL,&pose,v,&filter,&hit,&found));
    BAD(a->physics3d_shape_cast(&shape,NULL,v,&filter,&hit,&found));
    BAD(a->physics3d_shape_cast(&shape,&pose,v,NULL,&hit,&found));
    BAD(a->physics3d_shape_cast(&shape,&pose,v,&filter,NULL,&found));
    BAD(a->physics3d_shape_cast(&shape,&pose,v,&filter,&hit,NULL));
    BAD(a->physics3d_overlap(NULL,&pose,&filter,overlap,1,&count,&total));
    BAD(a->physics3d_overlap(&shape,NULL,&filter,overlap,1,&count,&total));
    BAD(a->physics3d_overlap(&shape,&pose,NULL,overlap,1,&count,&total));
    BAD(a->physics3d_overlap(&shape,&pose,&filter,NULL,1,&count,&total));
    BAD(a->physics3d_overlap(&shape,&pose,&filter,overlap,1,NULL,&total));
    BAD(a->physics3d_overlap(&shape,&pose,&filter,overlap,1,&count,NULL));
    BAD(a->physics3d_body_create(self,NULL,&out_body)); BAD(a->physics3d_body_create(self,&desc,NULL));
    BAD(a->physics3d_body_set_pose(body,NULL)); BAD(a->physics3d_body_get(body,NULL));
    BAD(a->physics3d_character_create(self,NULL,v,0,&out_character));
    BAD(a->physics3d_character_create(self,&config,v,0,NULL));
    BAD(a->physics3d_character_move(character,v,NULL));
    BAD(a->physics3d_character_feet(character,NULL)); BAD(a->physics3d_character_body(character,NULL));

    POISON(matrix,0,sizeof(matrix),a->render3d_instance_set_world(instance,&matrix));
    POISON(matrix,0,sizeof(matrix),a->render3d_instance_create(self,model,&matrix,&out_instance));
    POISON(lamp,4,56,a->render3d_light_set(light,&lamp));
    POISON(lamp,4,56,a->render3d_light_create(self,&lamp,&out_light));
    POISON(transform,0,sizeof(transform),a->world_transform_set(entity,&transform));
    POISON(pose,0,sizeof(pose),a->physics3d_body_set_pose(body,&pose));
    POISON(desc,4,52,a->physics3d_body_create(self,&desc,&out_body));
    POISON(config,0,24,a->physics3d_character_create(self,&config,v,0,&out_character));
    POISON(v,0,sizeof(v),a->physics3d_character_create(self,&config,v,0,&out_character));
    POISON(v,0,sizeof(v),a->physics3d_character_set_feet(character,v));
    POISON(v,0,sizeof(v),a->physics3d_character_move(character,v,&moved));
    POISON(v,0,sizeof(v),a->physics3d_raycast(v,direction,distance,&filter,&ray,&found));
    POISON(direction,0,sizeof(direction),a->physics3d_raycast(v,direction,distance,&filter,&ray,&found));
    POISON(distance,0,4,a->physics3d_raycast(v,direction,distance,&filter,&ray,&found));
    POISON(shape,4,sizeof(shape),a->physics3d_shape_cast(&shape,&pose,v,&filter,&hit,&found));
    POISON(pose,0,sizeof(pose),a->physics3d_shape_cast(&shape,&pose,v,&filter,&hit,&found));
    POISON(v,0,sizeof(v),a->physics3d_shape_cast(&shape,&pose,v,&filter,&hit,&found));
    POISON(shape,4,sizeof(shape),a->physics3d_overlap(&shape,&pose,&filter,overlap,1,&count,&total));
    POISON(pose,0,sizeof(pose),a->physics3d_overlap(&shape,&pose,&filter,overlap,1,&count,&total));
    if(out_instance.bits!=UINT64_C(0x5a5a5a5a5a5a5a5a) || out_light.bits!=out_instance.bits ||
       out_body.bits!=out_instance.bits || out_character.bits!=out_instance.bits) { failure_line=__LINE__; return FOUNDRY_ERR_REFUSED; }

    REFUSED(a->render3d_instance_destroy(foreign_instance));
    REFUSED(a->render3d_instance_set_world(foreign_instance,&matrix));
    REFUSED(a->render3d_instance_set_material(foreign_instance,0,(FoundryContentId){0}));
    REFUSED(a->render3d_instance_set_visible(foreign_instance,0));
    REFUSED(a->render3d_light_destroy(foreign_light)); REFUSED(a->render3d_light_set(foreign_light,&lamp));
    REFUSED(a->physics3d_body_destroy(host_body)); REFUSED(a->physics3d_body_set_pose(host_body,&pose));
    REFUSED(a->physics3d_body_set_filter(host_body,0,0));
    REFUSED(a->physics3d_body_destroy(foreign_body)); REFUSED(a->physics3d_body_set_pose(foreign_body,&pose));
    REFUSED(a->physics3d_body_set_filter(foreign_body,0,0));
    REFUSED(a->physics3d_character_destroy(foreign_character));
    REFUSED(a->physics3d_character_move(foreign_character,v,&moved));
    REFUSED(a->physics3d_character_set_feet(foreign_character,v));
    REFUSED(a->render3d_instance_create(foreign_mod,model,&matrix,&out_instance));
    REFUSED(a->render3d_light_create(foreign_mod,&lamp,&out_light));
    REFUSED(a->physics3d_body_create(foreign_mod,&desc,&out_body));
    REFUSED(a->physics3d_character_create(foreign_mod,&config,v,0,&out_character));
    /* A controller's backing body is read-only even to its creator. */
    OK(a->physics3d_character_body(character,&stale)); REFUSED(a->physics3d_body_destroy(stale));
    REFUSED(a->physics3d_body_set_pose(stale,&pose)); REFUSED(a->physics3d_body_set_filter(stale,0,0));

    matrix.elements[3]=1; BAD(a->render3d_instance_set_world(instance,&matrix)); matrix.elements[3]=0;
    lamp.kind=3; BAD(a->render3d_light_set(light,&lamp)); lamp.kind=1;
    lamp.reserved[0]=1; BAD(a->render3d_light_set(light,&lamp)); lamp.reserved[0]=0;
    lamp.casts_shadow=1; BAD(a->render3d_light_set(light,&lamp)); lamp.casts_shadow=0;
    lamp.rotation.w=2; BAD(a->render3d_light_set(light,&lamp)); lamp.rotation.w=1;
    desc.kind=2; BAD(a->physics3d_body_create(self,&desc,&out_body)); desc.kind=1;
    desc.shape.kind=3; BAD(a->physics3d_body_create(self,&desc,&out_body)); desc.shape.kind=0;
    desc.shape.radius=0; BAD(a->physics3d_body_create(self,&desc,&out_body));
    desc.shape.radius=-1; BAD(a->physics3d_body_create(self,&desc,&out_body)); desc.shape.radius=1;
    desc.pose.rotation.w=2; BAD(a->physics3d_body_create(self,&desc,&out_body)); desc.pose.rotation.w=1;
    filter.reserved=1; BAD(a->physics3d_overlap(&shape,&pose,&filter,overlap,1,&count,&total)); filter.reserved=0;
    EXPECT(a->physics3d_overlap(&shape,&pose,&filter,overlap,4097,&count,&total),FOUNDRY_ERR_LIMIT);
    BAD(a->world_parent_set(entity,(FoundryEntity){0},2));
    REFUSED(a->world_parent_set(entity,entity,0));
    EXPECT(a->world_parent_set(entity,deep_parent,0),FOUNDRY_ERR_LIMIT);
    REFUSED(a->world_parent_set(entity,singular_parent,1));
    REFUSED(a->world_parent_set(entity,shear_parent,1));
    EXPECT(a->world_transform_get((FoundryEntity){UINT64_MAX},&transform),FOUNDRY_ERR_INVALID_HANDLE);
    EXPECT(a->physics3d_body_get(hull_body,&read),FOUNDRY_ERR_UNSUPPORTED);
    OK(a->world_parent_get(entity,&parent)); OK(a->world_world_transform(entity,&derived));
    OK(a->render3d_instance_destroy(instance));
    EXPECT(a->render3d_instance_create(self,foundry_content_id("demo:materials.red",18),&matrix,&out_instance),FOUNDRY_ERR_INVALID_ARGUMENT);
    EXPECT(a->render3d_instance_create(self,foundry_content_id("demo:skin.model",15),&matrix,&out_instance),FOUNDRY_ERR_UNSUPPORTED);
    OK(a->render3d_instance_create(self,model,&matrix,&instance));
    EXPECT(a->render3d_instance_destroy((FoundryInstance){UINT64_MAX}),FOUNDRY_ERR_INVALID_HANDLE);
    EXPECT(a->render3d_light_destroy((FoundryLight){UINT64_MAX}),FOUNDRY_ERR_INVALID_HANDLE);
    EXPECT(a->physics3d_character_destroy((FoundryCharacter){UINT64_MAX}),FOUNDRY_ERR_INVALID_HANDLE);
    EXPECT(a->render3d_instance_set_material(instance,99,(FoundryContentId){0}),FOUNDRY_ERR_INVALID_ARGUMENT);
    OK(a->physics3d_body_create(self,&desc,&stale)); OK(a->physics3d_body_destroy(stale));
    EXPECT(a->physics3d_body_get(stale,&read),FOUNDRY_ERR_INVALID_HANDLE);
    EXPECT(a->physics3d_body_set_pose(stale,&pose),FOUNDRY_ERR_INVALID_HANDLE);
    EXPECT(a->physics3d_body_destroy(stale),FOUNDRY_ERR_INVALID_HANDLE);
    EXPECT(a->physics3d_body_set_filter(stale,0,0),FOUNDRY_ERR_INVALID_HANDLE);
    filter.ignore=stale;
    EXPECT(a->physics3d_raycast(v,direction,distance,&filter,&ray,&found),FOUNDRY_ERR_INVALID_HANDLE);
    filter.ignore.bits=0;
    /* Fill the bounded ownership pools. The loader's refusal must clean them all. */
    for(n=0;n<254;++n) OK(a->physics3d_body_create(self,&desc,&stale));
    EXPECT(a->physics3d_body_create(self,&desc,&out_body),FOUNDRY_ERR_LIMIT);
    for(n=0;n<14;++n) OK(a->physics3d_character_create(self,&config,(FoundryVec3){30,0,0},0,&out_character));
    EXPECT(a->physics3d_character_create(self,&config,v,0,&out_character),FOUNDRY_ERR_LIMIT);
    EXPECT(a->render3d_instance_create(self,model,&matrix,&out_instance),FOUNDRY_ERR_LIMIT);
    EXPECT(a->render3d_light_create(self,&lamp,&out_light),FOUNDRY_ERR_LIMIT);
    OK(a->render3d_camera_get(&camera));
    /* Deliberate failed init, not a test failure; all newly owned objects are swept. */
    return FOUNDRY_ERR_REFUSED;
}
