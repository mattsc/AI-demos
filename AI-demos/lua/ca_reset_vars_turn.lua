----- CA: Reset variables at beginning of turn (max_score: 999998) -----
-- This will be blacklisted after first execution each turn

local ca_reset_vars_turn = {}

function ca_reset_vars_turn:evaluation()
    return 999998
end

function ca_reset_vars_turn:execution(cfg, data, ai_debug)
    local ai = ai_debug or ai

    --std_print(' Resetting variables at beginning of Turn ' .. wesnoth.current.turn)

    data.turn_start_time = wesnoth.get_time_stamp() / 1000.

    data.recruit = {}
    wesnoth.require("~add-ons/AI-demos/lua/generic_recruit_engine.lua").init(ai, data.recruit, params)
    local params = {
        high_level_fraction = 0,
        score_function = function () return 181000 end
    }
end

return ca_reset_vars_turn
