----- CA: Reset variables at beginning of each move (max_score: 999997) -----
-- This always returns 0 -> will never be executed, but evaluated before each move

local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local FGU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_gamestate_utils.lua"
-- TODO: use only in ops_utils?
local FSC = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_scenario_cfg.lua"

local ca_reset_vars_move = {}

function ca_reset_vars_move:evaluation(ai, cfg, self)
    --print(' Resetting gamedata tables (etc.) before move')

    self.data.gamedata = FGU.get_gamedata()
    local side_cfgs = FSC.get_side_cfgs()
    self.data.gamedata.leader_distance_map, self.data.gamedata.enemy_leader_distance_maps = FU.get_leader_distance_map(side_cfgs, self.data.gamedata)
    self.data.move_cache = {}

    return 0
end

function ca_reset_vars_move:execution(ai, cfg, self)
end

return ca_reset_vars_move
