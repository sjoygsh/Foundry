#include "foundry.h"

#ifndef RESULT_CODE
#define RESULT_CODE FOUNDRY_OK
#endif

FOUNDRY_EXPORT FoundryResult foundry_mod_init(FoundryGetApi get_api, FoundryMod self)
{
    (void)get_api;
    (void)self;
    return (FoundryResult)RESULT_CODE;
}

#ifndef OMIT_SHUTDOWN
FOUNDRY_EXPORT void foundry_mod_shutdown(FoundryMod self)
{
    (void)self;
}
#endif
