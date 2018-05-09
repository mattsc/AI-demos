----- CA: Reset variables at beginning of each move (max_score: 999997) -----
-- This always returns 0 -> will never be executed, but evaluated before each move

local FGU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_gamestate_utils.lua"

local ca_reset_vars_move = {}

function ca_reset_vars_move:evaluation(cfg, data)
    --print(' Resetting move_data tables (etc.) before move')

    data.move_data = FGU.get_move_data()
    data.move_cache = {}

    return 0
end

function ca_reset_vars_move:execution()
end

return ca_reset_vars_move
