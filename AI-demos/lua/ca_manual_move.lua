----- CA: Manual move (max_score: 999980) -----

local ca_manual_move = {}

function ca_manual_move:evaluation()
    local start_time = wesnoth.get_time_stamp()
    local timeout_ms = 10000 -- milli-seconds
    --std_print('Start time:', start_time)

    local old_id = wml.variables.manual_ai_id
    local old_x = wml.variables.manual_ai_x
    local old_y = wml.variables.manual_ai_y
    local id, x, y = wesnoth.dofile("~/add-ons/AI-demos/lua/manual_input.lua")

    while (id == old_id) and (x == old_x) and (y == old_y) and (wesnoth.get_time_stamp() < start_time + timeout_ms) do
        id, x, y = wesnoth.dofile("~/add-ons/AI-demos/lua/manual_input.lua")
    end

    if (id == old_id) and (x == old_x) and (y == old_y) then
        std_print('manual move CA has timed out')
        return 0
    else
        return 999980
    end
end

function ca_manual_move:execution(cfg, data)
    local id, x, y = wesnoth.dofile("~/add-ons/AI-demos/lua/manual_input.lua")
    std_print('move ' .. id .. ' --> ' .. x .. ',' .. y)

    local unit = wesnoth.get_unit(id)
    ai.move(unit, x, y)

    wml.variables.manual_ai_id = id
    wml.variables.manual_ai_x = x
    wml.variables.manual_ai_y = y
end

return ca_manual_move
