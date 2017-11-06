----- CA: Reset variables at beginning of turn (max_score: 999998) -----
-- This will be blacklisted after first execution each turn

local FC = wesnoth.require "~/add-ons/AI-demos/lua/fred_compatibility.lua"

local ca_reset_vars_turn = {}

function ca_reset_vars_turn:evaluation()
    return 999998
end

function ca_reset_vars_turn:execution(arg1, arg2, arg3)
    local ai, cfg, data = FC.set_CA_args(arg1, arg2, arg3)

    --print(' Resetting variables at beginning of Turn ' .. wesnoth.current.turn)

    data.turn_start_time = wesnoth.get_time_stamp() / 1000.

    data.recruit = {}
    local params = { score_function = function () return 181000 end }
    wesnoth.require("~add-ons/AI-demos/lua/generic_recruit_engine.lua").init(ai, data.recruit, params)
end

return ca_reset_vars_turn
