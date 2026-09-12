-- The sandbox's scripted encounter.
--
-- This file is a mod. Nothing about it is special-cased: the manifest names it as this
-- package's entry, the compiler turns it into a `foundry:script` asset from its path, and
-- the engine hands it exactly the `foundry` module a Tier 2 mod from anywhere else gets.
--
-- What it may do is binding 1 (`docs/design/scripting.md` §7): read content, look at the
-- world, spawn a template, and remove what it spawned. It cannot move an entity, draw
-- anything, read a clock or touch a file -- so *where* the beacons are and what they look
-- like is content, and this decides only when they appear and when they go.

-- Top-level evaluation is preparation: it may read content and may not change the world.
local config = foundry.content_find("sandbox:encounter.main")
local interval = foundry.record_get_i64(config, foundry.record_field_index(config, "interval"))

local beacons = foundry.record_field_index(config, "beacons")
local templates = {}
local count = foundry.record_list_len(config, beacons)
for i = 0, count - 1 do
    -- Field and list indices are the ABI's, and the ABI counts from zero. Lua arrays count
    -- from one. Neither is converted behind your back.
    templates[i + 1] = foundry.record_list_get_id(config, beacons, i)
end

return {
    state_version = 1,

    -- Everything that must survive a reload lives in the table this returns. An upvalue is
    -- rebuilt when the code is replaced; state is carried across.
    init = function()
        return { next_tick = interval, lit = 0, owned = {} }
    end,

    update = function(state, step)
        if step.tick < state.next_tick then return end
        state.next_tick = step.tick + interval

        if state.lit < #templates then
            local made = foundry.world_spawn(templates[state.lit + 1])
            -- Absence is a value: a template a later package removed is `nil`, not a crash.
            if made == nil then return end
            state.lit = state.lit + 1
            state.owned[state.lit] = made
            foundry.log_write("info", "beacon " .. tostring(state.lit) .. " lit")
        else
            -- Only what this package spawned, because that is all it is allowed to remove.
            for i = 1, state.lit do
                foundry.world_destroy_entity(state.owned[i])
                state.owned[i] = nil
            end
            state.lit = 0
            foundry.log_write("info", "beacons out")
        end
    end,
}
