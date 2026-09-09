#include "foundry.h"

static const FoundryApi_v1 *api_v1;
static FoundryMod mod_self;
static FoundryComponentType counter_type;
static FoundryBool ran;

static void update(void *ctx, const FoundryStep *step)
{
    FoundryEntity entity = {0};
    uint32_t initial = 40;
    void *bytes = NULL;
    uint32_t size = 0;

    (void)ctx;
    (void)step;
    if (ran != 0) return;
    ran = 1;
    if (api_v1->world_create_entity(&entity) != FOUNDRY_OK) return;
    if (api_v1->world_add_component(entity, counter_type, &initial,
                                    (uint32_t)sizeof(initial)) != FOUNDRY_OK) return;
    if (api_v1->world_component_bytes(mod_self, entity, counter_type, &bytes, &size) != FOUNDRY_OK) return;
    if (bytes != NULL && size == sizeof(uint32_t)) (*(uint32_t *)bytes) += 2;
}

FOUNDRY_EXPORT FoundryResult foundry_mod_init(FoundryGetApi get_api, FoundryMod self)
{
    FoundryComponentDesc component = {0};
    FoundrySystemDesc system = {0};

    api_v1 = (const FoundryApi_v1 *)get_api(FOUNDRY_API_VERSION_1);
    if (api_v1 == NULL) return FOUNDRY_ERR_UNSUPPORTED;
    mod_self = self;

    component.schema = foundry_schema_id("pipeline:counter", 16);
    component.name = (FoundryStr){(const uint8_t *)"pipeline:counter", 16};
    component.size = (uint32_t)sizeof(uint32_t);
    component.alignment = 4;
    if (api_v1->world_register_component(self, &component, &counter_type) != FOUNDRY_OK)
        return FOUNDRY_ERR_REFUSED;

    system.id = foundry_content_id("pipeline:advance", 16);
    system.name = (FoundryStr){(const uint8_t *)"pipeline:advance", 16};
    system.update = update;
    return api_v1->world_register_system(self, &system);
}

FOUNDRY_EXPORT void foundry_mod_shutdown(FoundryMod self)
{
    FoundryEntity entity = {0};
    uint32_t initial = 99;
    (void)self;
    if (api_v1 == NULL) return;
    if (api_v1->world_create_entity(&entity) != FOUNDRY_OK) return;
    (void)api_v1->world_add_component(entity, counter_type, &initial,
                                      (uint32_t)sizeof(initial));
}
