/*
 * Input from outside, in C (input.md §10, M45 Step 7).
 *
 * A C99 consumer of foundry.h alone, loaded as a native mod and handed FoundryApi_v8. It calls
 * every input entry point and every refusal, and reports by its result: FOUNDRY_OK means every
 * check passed, and anything else names the first that did not in the host's log.
 *
 * Its host (engine/tests/abi_input.zig) runs it two ways:
 * - with no input source, where every call must answer FOUNDRY_ERR_UNAVAILABLE after a null
 *   out-pointer is refused as FOUNDRY_ERR_INVALID_ARGUMENT;
 * - with a scripted source, whose frame view has J pressed and whose tick view has J only
 *   held, its edge taken by an earlier step. Init reads the frame view. A system it registers
 *   reads the tick view, and creates one entity for each step whose answers were right, which
 *   the host counts.
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "foundry.h"

static const FoundryApi_v8 *api;
static FoundryMod owner;

static FoundryStr text(const char *s)
{
    FoundryStr out;
    out.ptr = (const uint8_t *)s;
    out.len = (uint64_t)strlen(s);
    return out;
}

static FoundryContentId id(const char *s) { return foundry_content_id(s, strlen(s)); }

static int same(FoundryStr a, const char *b)
{
    return a.len == strlen(b) && (a.len == 0 || memcmp(a.ptr, b, (size_t)a.len) == 0);
}

static int has(const uint64_t words[4], uint32_t key)
{
    return (words[key / 64u] >> (key % 64u)) & 1u;
}

#define CHECK(cond)                                                                       \
    do {                                                                                  \
        if (!(cond)) {                                                                    \
            (void)api->log_write(owner, FOUNDRY_LOG_WARN,                                 \
                                 text("input_client: check failed: " #cond));             \
            return FOUNDRY_ERR_INTERNAL;                                                  \
        }                                                                                 \
    } while (0)

/* Every call, with well-formed arguments, on a host with no input. */
static FoundryResult unavailable(void)
{
    FoundryKeyboardState keys;
    FoundryMouseState mouse;
    FoundryGamepadState pad;
    FoundryActionState state;
    FoundryBinding binding;
    FoundryStr name;
    uint32_t number = 0;
    FoundryBool on = 0;
    FoundryContentId jump = id("t:action.jump");

    CHECK(api->input_keyboard(NULL) == FOUNDRY_ERR_INVALID_ARGUMENT);
    CHECK(api->input_keyboard(&keys) == FOUNDRY_ERR_UNAVAILABLE);
    CHECK(api->input_key_from_name(text("a"), &number) == FOUNDRY_ERR_UNAVAILABLE);
    CHECK(api->input_key_name(FOUNDRY_KEY_A, &name) == FOUNDRY_ERR_UNAVAILABLE);
    CHECK(api->input_key_label(FOUNDRY_KEY_A, &name) == FOUNDRY_ERR_UNAVAILABLE);
    CHECK(api->input_mouse(&mouse) == FOUNDRY_ERR_UNAVAILABLE);
    CHECK(api->input_gamepad_slots(&number) == FOUNDRY_ERR_UNAVAILABLE);
    CHECK(api->input_gamepad(0, &pad) == FOUNDRY_ERR_UNAVAILABLE);
    CHECK(api->input_action(jump, &state) == FOUNDRY_ERR_UNAVAILABLE);
    CHECK(api->input_action_binding_count(jump, &number) == FOUNDRY_ERR_UNAVAILABLE);
    CHECK(api->input_action_binding(jump, 0, &binding) == FOUNDRY_ERR_UNAVAILABLE);
    CHECK(api->input_context_enabled(id("t:context.walk"), &on) == FOUNDRY_ERR_UNAVAILABLE);
    (void)api->log_write(owner, FOUNDRY_LOG_INFO, text("input_client: no input; every call unavailable"));
    return FOUNDRY_OK;
}

/* Every refusal a scripted host gives. */
static FoundryResult refusals(void)
{
    FoundryGamepadState pad;
    FoundryActionState state;
    FoundryBinding binding;
    FoundryStr name;
    uint32_t number = 77;
    FoundryBool on = 0;
    const uint8_t not_utf8[1] = {0xff};
    FoundryStr bad;
    FoundryContentId none;
    FoundryContentId jump = id("t:action.jump");
    bad.ptr = not_utf8;
    bad.len = 1;
    none.hash = 0;

    /* A bad pointer. */
    CHECK(api->input_keyboard(NULL) == FOUNDRY_ERR_INVALID_ARGUMENT);
    CHECK(api->input_key_from_name(text("a"), NULL) == FOUNDRY_ERR_INVALID_ARGUMENT);
    CHECK(api->input_key_name(FOUNDRY_KEY_A, NULL) == FOUNDRY_ERR_INVALID_ARGUMENT);
    CHECK(api->input_key_label(FOUNDRY_KEY_A, NULL) == FOUNDRY_ERR_INVALID_ARGUMENT);
    CHECK(api->input_mouse(NULL) == FOUNDRY_ERR_INVALID_ARGUMENT);
    CHECK(api->input_gamepad_slots(NULL) == FOUNDRY_ERR_INVALID_ARGUMENT);
    CHECK(api->input_gamepad(0, NULL) == FOUNDRY_ERR_INVALID_ARGUMENT);
    CHECK(api->input_action(jump, NULL) == FOUNDRY_ERR_INVALID_ARGUMENT);
    CHECK(api->input_action_binding_count(jump, NULL) == FOUNDRY_ERR_INVALID_ARGUMENT);
    CHECK(api->input_action_binding(jump, 0, NULL) == FOUNDRY_ERR_INVALID_ARGUMENT);
    CHECK(api->input_context_enabled(id("t:context.walk"), NULL) == FOUNDRY_ERR_INVALID_ARGUMENT);
    /* A bad slot. */
    CHECK(api->input_gamepad(4, &pad) == FOUNDRY_ERR_INVALID_ARGUMENT);
    CHECK(api->input_gamepad(UINT32_MAX, &pad) == FOUNDRY_ERR_INVALID_ARGUMENT);
    /* An unknown key number, and names that are not keys. */
    CHECK(api->input_key_name(FOUNDRY_KEY_MENU + 1, &name) == FOUNDRY_ERR_INVALID_ARGUMENT);
    CHECK(api->input_key_label(UINT32_MAX, &name) == FOUNDRY_ERR_INVALID_ARGUMENT);
    CHECK(api->input_key_from_name(bad, &number) == FOUNDRY_ERR_INVALID_ARGUMENT);
    CHECK(api->input_key_from_name(text("hyper"), &number) == FOUNDRY_ERR_NOT_FOUND);
    CHECK(number == 77);
    /* An unknown action, a missing id, an index past the bindings, an unknown context. */
    CHECK(api->input_action(none, &state) == FOUNDRY_ERR_INVALID_ARGUMENT);
    CHECK(api->input_action(id("t:action.fly"), &state) == FOUNDRY_ERR_NOT_FOUND);
    CHECK(api->input_action_binding_count(id("t:action.fly"), &number) == FOUNDRY_ERR_NOT_FOUND);
    CHECK(api->input_action_binding(id("t:action.fly"), 0, &binding) == FOUNDRY_ERR_NOT_FOUND);
    CHECK(api->input_action_binding(jump, 1, &binding) == FOUNDRY_ERR_INVALID_ARGUMENT);
    CHECK(api->input_context_enabled(id("t:context.swim"), &on) == FOUNDRY_ERR_NOT_FOUND);
    CHECK(api->input_context_enabled(none, &on) == FOUNDRY_ERR_INVALID_ARGUMENT);
    return FOUNDRY_OK;
}

/* The frame view, outside any system. */
static FoundryResult frame_view(void)
{
    FoundryKeyboardState keys;
    FoundryMouseState mouse;
    FoundryGamepadState pad;
    FoundryActionState state;
    FoundryBinding binding;
    FoundryStr name;
    uint32_t number = 0;
    uint32_t key;
    FoundryBool on = 0;
    FoundryContentId jump = id("t:action.jump");
    FoundryContentId move = id("t:action.move");

    CHECK(api->input_keyboard(&keys) == FOUNDRY_OK);
    CHECK(has(keys.held, FOUNDRY_KEY_J) && has(keys.pressed, FOUNDRY_KEY_J));
    CHECK(!has(keys.released, FOUNDRY_KEY_J) && !has(keys.held, FOUNDRY_KEY_K));
    CHECK(keys.focused == FOUNDRY_TRUE);

    /* Every key's name, both ways. */
    for (key = FOUNDRY_KEY_UNKNOWN; key <= FOUNDRY_KEY_MENU; ++key) {
        CHECK(api->input_key_name(key, &name) == FOUNDRY_OK && name.len > 0);
        CHECK(api->input_key_from_name(name, &number) == FOUNDRY_OK && number == key);
    }
    CHECK(api->input_key_from_name(text("left_shift"), &number) == FOUNDRY_OK);
    CHECK(number == FOUNDRY_KEY_LEFT_SHIFT);
    CHECK(api->input_key_label(FOUNDRY_KEY_Q, &name) == FOUNDRY_OK && name.len > 0);
    CHECK(api->input_key_label(FOUNDRY_KEY_UNKNOWN, &name) == FOUNDRY_OK && name.len == 0);

    CHECK(api->input_mouse(&mouse) == FOUNDRY_OK);
    CHECK(mouse.motion_x == 3.0f && mouse.motion_y == -1.0f);
    CHECK(mouse.motion_unit == FOUNDRY_MOTION_COUNTS);

    CHECK(api->input_gamepad_slots(&number) == FOUNDRY_OK && number == 4);
    CHECK(api->input_gamepad(0, &pad) == FOUNDRY_OK && pad.connected == FOUNDRY_FALSE);
    CHECK(api->input_gamepad(1, &pad) == FOUNDRY_OK && pad.connected == FOUNDRY_TRUE);
    CHECK(pad.kind == FOUNDRY_PAD_KIND_PLAYSTATION && pad.generation == 2);
    CHECK(pad.face[0] == FOUNDRY_PAD_LABEL_CROSS && pad.face[3] == FOUNDRY_PAD_LABEL_TRIANGLE);
    CHECK(pad.axes[FOUNDRY_PAD_AXIS_LEFT_Y] == 0.5f);

    CHECK(api->input_action(jump, &state) == FOUNDRY_OK);
    CHECK(state.kind == FOUNDRY_ACTION_BUTTON && state.held && state.pressed && !state.released);
    CHECK(api->input_action(move, &state) == FOUNDRY_OK && state.kind == FOUNDRY_ACTION_VECTOR);

    /* Jump is the player's J; pause's override is ignored, since it is not rebindable. */
    CHECK(api->input_action_binding_count(jump, &number) == FOUNDRY_OK && number == 1);
    CHECK(api->input_action_binding(jump, 0, &binding) == FOUNDRY_OK);
    CHECK(same(binding.source, "key.j") && binding.overridden == FOUNDRY_TRUE);
    CHECK(api->input_action_binding(id("t:action.pause"), 0, &binding) == FOUNDRY_OK);
    CHECK(same(binding.source, "key.escape") && binding.overridden == FOUNDRY_FALSE);
    CHECK(api->input_action_binding(move, 0, &binding) == FOUNDRY_OK);
    CHECK(same(binding.source, "key.w") && binding.axis == FOUNDRY_AXIS_Y && binding.scale == 1.0f);
    CHECK(api->input_action_binding(move, 1, &binding) == FOUNDRY_OK);
    CHECK(same(binding.source, "pad.left_stick") && binding.deadzone == 0.2f);

    CHECK(api->input_context_enabled(id("t:context.walk"), &on) == FOUNDRY_OK && on == FOUNDRY_TRUE);
    CHECK(api->input_context_enabled(id("t:context.menu"), &on) == FOUNDRY_OK && on == FOUNDRY_FALSE);
    return FOUNDRY_OK;
}

/* The tick view: J held, its press taken by an earlier step. */
static FoundryResult tick_view(void)
{
    FoundryKeyboardState keys;
    FoundryActionState state;
    FoundryMouseState mouse;
    CHECK(api->input_keyboard(&keys) == FOUNDRY_OK);
    CHECK(has(keys.held, FOUNDRY_KEY_J) && !has(keys.pressed, FOUNDRY_KEY_J));
    CHECK(api->input_action(id("t:action.jump"), &state) == FOUNDRY_OK);
    CHECK(state.held && !state.pressed);
    CHECK(api->input_mouse(&mouse) == FOUNDRY_OK && mouse.motion_x == 0.0f);
    return FOUNDRY_OK;
}

static void update(void *ctx, const FoundryStep *step)
{
    FoundryEntity marker;
    (void)ctx;
    (void)step;
    if (tick_view() == FOUNDRY_OK) (void)api->world_create_entity(&marker);
}

FOUNDRY_EXPORT FoundryResult foundry_mod_init(FoundryGetApi get_api, FoundryMod self)
{
    FoundrySystemDesc system;
    uint32_t slots = 0;
    FoundryResult result;

    owner = self;
    api = (const FoundryApi_v8 *)get_api(FOUNDRY_API_VERSION_8);
    if (api == NULL || api->version != 8 || api->size != sizeof(*api)) return FOUNDRY_ERR_UNSUPPORTED;
    /* Eleven calls past v7's 264, each a function pointer. */
    if (sizeof(FoundryApi_v8) != sizeof(FoundryApi_v7) + 11 * sizeof(void (*)(void))) return FOUNDRY_ERR_UNSUPPORTED;

    if (api->input_gamepad_slots(&slots) == FOUNDRY_ERR_UNAVAILABLE) return unavailable();

    result = refusals();
    if (result != FOUNDRY_OK) return result;
    result = frame_view();
    if (result != FOUNDRY_OK) return result;

    memset(&system, 0, sizeof system);
    system.id = id("t:systems.input_client");
    system.name = text("t:systems.input_client");
    system.update = update;
    result = api->world_register_system(owner, &system);
    if (result != FOUNDRY_OK) return result;
    (void)api->log_write(owner, FOUNDRY_LOG_INFO, text("input_client: every v8 call and refusal passed"));
    return FOUNDRY_OK;
}
