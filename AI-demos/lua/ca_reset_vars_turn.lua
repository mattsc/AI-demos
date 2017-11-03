----- CA: Reset variables at beginning of turn (max_score: 999998) -----
-- This will be blacklisted after first execution each turn

local ca_reset_vars_turn = {}

function ca_reset_vars_turn:evaluation(ai, cfg, self)
    return 999998
end

function ca_reset_vars_turn:execution(ai, cfg, self)
    --print(' Resetting variables at beginning of Turn ' .. wesnoth.current.turn)

    self.data.turn_start_time = wesnoth.get_time_stamp() / 1000.

    self.recruit = {}
    local params = { score_function = function () return 181000 end }
    wesnoth.require("~add-ons/AI-demos/lua/generic_recruit_engine.lua").init(ai, self.recruit, params)
end

return ca_reset_vars_turn
