#include "foundry.h"

static const FoundryApi_v1 *api_v1;
static FoundryComponentType marker_type;

FOUNDRY_EXPORT FoundryResult foundry_mod_init(FoundryGetApi get_api, FoundryMod self)
{
    FoundryComponentDesc component = {0};
    api_v1 = (const FoundryApi_v1 *)get_api(FOUNDRY_API_VERSION_1);
    if (api_v1 == NULL) return FOUNDRY_ERR_UNSUPPORTED;
    component.schema = foundry_schema_id("tail:marker", 11);
    component.name = (FoundryStr){(const uint8_t *)"tail:marker", 11};
    component.alignment = 1;
    return api_v1->world_register_component(self, &component, &marker_type);
}

FOUNDRY_EXPORT void foundry_mod_shutdown(FoundryMod self)
{
    FoundryEntity entity = {0};
    (void)self;
    if (api_v1 == NULL) return;
    if (api_v1->world_create_entity(&entity) != FOUNDRY_OK) return;
    (void)api_v1->world_add_component(entity, marker_type, NULL, 0);
}
