----- CA: Clear self.data table at end of turn (max_score: 1) -----
-- This will be blacklisted after first execution each turn, which happens at the very end of each turn

local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
local FMLU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_move_leader_utils.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local ca_move_leader_to_keep = {}

function ca_move_leader_to_keep:evaluation(ai, cfg, self)
    local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'move_leader_to_keep'
    DBG.print_debug_time('eval', self.data.turn_start_time, '     - Evaluating move_leader_to_keep CA:')

    return FMLU.move_eval(move_unit_away, self.data)
end

function ca_move_leader_to_keep:execution(ai, cfg, self)
    DBG.print_debug_time('exec', self.data.turn_start_time, '=> exec: move_leader_to_keep CA')

    -- If leader can get to the keep, make this a partial move, otherwise a full move
    if (self.data.MLK_dst[1] == self.data.MLK_keep[1])
        and (self.data.MLK_dst[2] == self.data.MLK_keep[2])
    then
        AH.checked_move(ai, self.data.MLK_leader, self.data.MLK_dst[1], self.data.MLK_dst[2])
    else
        AH.checked_move_full(ai, self.data.MLK_leader, self.data.MLK_dst[1], self.data.MLK_dst[2])
    end

    self.data.MLK_leader, self.data.MLK_dst = nil, nil
end

return ca_move_leader_to_keep
