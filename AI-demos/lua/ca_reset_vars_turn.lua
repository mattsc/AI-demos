----- CA: Reset variables at beginning of turn (max_score: 999998) -----
-- This will be blacklisted after first execution each turn

local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

local ca_reset_vars_turn = {}

function ca_reset_vars_turn:evaluation()
    return 999998
end

function ca_reset_vars_turn:execution(cfg, data, ai_debug)
    data.turn_start_time = wesnoth.get_time_stamp() / 1000.
    data.previous_time = nil -- This is only used for timing debug output
    DBG.print_timing(data, 0, '-- start reset_vars_turn CA')

    local ai = ai_debug or ai

    data.recruit = {}
    local params = {
        high_level_fraction = 0,
        score_function = function () return 181000 end
    }
    wesnoth.require("~add-ons/AI-demos/lua/generic_recruit_engine.lua").init(ai, data.recruit, params)

    DBG.print_timing(data, 0, '-- end reset_vars_turn CA')
end

return ca_reset_vars_turn
