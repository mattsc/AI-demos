----- CA: Remove MP from all units (max_score: 900) -----
-- This serves the purpose that attacks are evaluated differently for
-- units without MP. They might still attack in this case (such as
-- unanswerable attacks), while they do not if they can still move

local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"
local FC = wesnoth.require "~/add-ons/AI-demos/lua/fred_compatibility.lua"

local ca_remove_mp = {}

function ca_remove_mp:evaluation(arg1, arg2, arg3)
    local ai, cfg, data = FC.set_CA_args(arg1, arg2, arg3)

    local score = 900

    local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'remove_MP'
    DBG.print_debug_time('eval', data.turn_start_time, '     - Evaluating remove_MP CA:')

    local id,_ = next(data.move_data.my_units_MP)

    if id then
        return score
    end

    return 0
end

function ca_remove_mp:execution(arg1, arg2, arg3)
    local ai, cfg, data = FC.set_CA_args(arg1, arg2, arg3)

    DBG.print_debug_time('exec', data.turn_start_time, '=> exec: remove_MP CA')

    local id,loc = next(data.move_data.my_units_MP)

    AH.checked_stopunit_moves(ai, data.move_data.unit_copies[id])
end

return ca_remove_mp
