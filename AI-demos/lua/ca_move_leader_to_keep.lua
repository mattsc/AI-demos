----- CA: Move leader to keep (max_score: 480,000) -----

local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
local FMLU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_move_leader_utils.lua"
local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"
local FC = wesnoth.require "~/add-ons/AI-demos/lua/fred_compatibility.lua"

local ca_move_leader_to_keep = {}

function ca_move_leader_to_keep:evaluation(arg1, arg2, arg3)
    local ai, cfg, data = FC.set_CA_args(arg1, arg2, arg3)

    local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'move_leader_to_keep'
    DBG.print_debug_time('eval', data.turn_start_time, '     - Evaluating move_leader_to_keep CA:')

    return FMLU.move_eval(false, data)
end

function ca_move_leader_to_keep:execution(arg1, arg2, arg3)
    local ai, cfg, data = FC.set_CA_args(arg1, arg2, arg3)

    DBG.print_debug_time('exec', data.turn_start_time, '=> exec: move_leader_to_keep CA')

    -- If leader can get to the keep, make this a partial move, otherwise a full move
    if (data.MLK_dst[1] == data.MLK_keep[1])
        and (data.MLK_dst[2] == data.MLK_keep[2])
    then
        AH.checked_move(ai, data.MLK_leader, data.MLK_dst[1], data.MLK_dst[2])
    else
        AH.checked_move_full(ai, data.MLK_leader, data.MLK_dst[1], data.MLK_dst[2])
    end

    data.MLK_leader, data.MLK_dst = nil, nil
end

return ca_move_leader_to_keep
