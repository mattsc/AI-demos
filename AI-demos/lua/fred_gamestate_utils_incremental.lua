-- Collection of functions to get information about units and the gamestate and
-- collect them in tables for easy access. They are expensive, so this should
-- be done as infrequently as possible, but it needs to be redone after each move.
--
-- Unlike fred_gamestate_utils.lua, these functions only acquire the information
-- needed at the time and add it to a cache table as only a subset of all possible
-- information is needed for any move evaluation.

local FGM = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_map.lua"
local COMP = wesnoth.require "~/add-ons/AI-demos/lua/compatibility.lua"

local fred_gamestate_utils_incremental = {}

function fred_gamestate_utils_incremental.get_unit_defense(unit_copy, x, y, defense_maps)
    -- Get the terrain defense of a unit as a factor (that is, e.g. 0.40 rather than 40)
    -- The result is stored (or accessed, if it exists) in @defense_maps
    --
    -- Inputs:
    -- @unit_copy: private copy of the unit (proxy table works too, but is slower)
    -- @x, @y: the location for which to calculate the unit's terrain defense
    -- @defense_maps: table in which to cache the results. Note: this is NOT an optional input
    --
    -- Sample structure of defense_maps:
    --   defense_maps['Vanak'][19][4] = 0.6

    if (not defense_maps[unit_copy.id]) then defense_maps[unit_copy.id] = {} end
    local defense = FGM.get_value(defense_maps[unit_copy.id], x, y, 'defense')
    if (not defense) then
        defense = (100. - COMP.unit_defense(unit_copy, wesnoth.get_terrain(x, y))) / 100.
        FGM.set_value(defense_maps[unit_copy.id], x, y, 'defense', defense)
    end

    return defense
end

return fred_gamestate_utils_incremental
