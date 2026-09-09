#include "foundry.h"

static uint32_t update_calls;

static void update(void *ctx, const FoundryStep *step)
{
    (void)ctx;
    (void)step;
    update_calls += 1;
}

FOUNDRY_EXPORT FoundryResult foundry_mod_init(FoundryGetApi get_api, FoundryMod self)
{
    const FoundryApi_v1 *api_v1;
    FoundrySystemDesc system = {0};

    api_v1 = (const FoundryApi_v1 *)get_api(FOUNDRY_API_VERSION_1);
    if (api_v1 == NULL) return FOUNDRY_ERR_UNSUPPORTED;
    system.id = foundry_content_id("refused:system", 14);
    system.name = (FoundryStr){(const uint8_t *)"refused:system", 14};
    system.update = update;
    if (api_v1->world_register_system(self, &system) != FOUNDRY_OK)
        return FOUNDRY_ERR_INTERNAL;
    return FOUNDRY_ERR_REFUSED;
}

FOUNDRY_EXPORT uint32_t foundry_test_update_calls(void)
{
    return update_calls;
}

FOUNDRY_EXPORT void foundry_mod_shutdown(FoundryMod self)
{
    (void)self;
}
