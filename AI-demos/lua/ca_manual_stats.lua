----- CA: Stats at beginning of turn (max_score: 999990) -----
-- This will be blacklisted after first execution each turn

local ca_manual_stats = {}

function ca_manual_stats:evaluation()
    return 999990
end

function ca_manual_stats:execution(cfg, data)
    local tod = wesnoth.get_time_of_day()
    std_print('\n**** Manual AI *********************************************************')
    std_print('Beginning of Turn ' .. wesnoth.current.turn .. ' (' .. tod.name ..') stats')

    local units = wesnoth.get_units()
    for _,unit in ipairs(units) do
        std_print(string.format('%-25s %2d,%2d  %1d', unit.id, unit.x, unit.y, unit.side))
    end

    std_print('************************************************************************')

    local id, x, y = wesnoth.dofile("~/add-ons/AI-demos/lua/manual_input.lua")
    wml.variables.manual_ai_id = id
    wml.variables.manual_ai_x = x
    wml.variables.manual_ai_y = y
end

return ca_manual_stats
