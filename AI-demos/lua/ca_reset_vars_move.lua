----- CA: Reset variables at beginning of each move (max_score: 999997) -----
-- This always returns 0 -> will never be executed, but evaluated before each move

local FGU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_gamestate_utils.lua"
local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

local ca_reset_vars_move = {}

function ca_reset_vars_move:evaluation(cfg, data)
    DBG.print_timing(data, 0, '-- start reset_vars_move CA')

    FGU.get_move_data(data)
    data.move_cache = {}

    DBG.print_timing(data, 0, '-- end reset_vars_move CA')

    return 0
end

function ca_reset_vars_move:execution()
end

return ca_reset_vars_move
