----- CA: Reset variables at beginning of each move (max_score: 999997) -----
-- This always returns 0 -> will never be executed, but evaluated before each move

local FGU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_gamestate_utils.lua"
local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

local ca_reset_vars_move = {}

function ca_reset_vars_move:evaluation(cfg, data)
    DBG.print_debug_time('timing', - data.turn_start_time, 'start reset_vars_move CA')

    data.move_data = FGU.get_move_data()
    data.move_cache = {}

    DBG.print_debug_time('timing', data.turn_start_time, 'end reset_vars_move CA')

    return 0
end

function ca_reset_vars_move:execution()
end

return ca_reset_vars_move
