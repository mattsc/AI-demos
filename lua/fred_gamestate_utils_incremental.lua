-- Collection of functions to get information about units and the gamestate and
-- collect them in tables for easy access.  They are expensive, so this should
-- be done as infrequently as possible, but it needs to be redone after each move.
--
-- Unlike fred_gamestate_utils.lua, these functions only acquire the information
-- needed at the time and add it to a table as only a subset of all possible
-- information is needed for any move evaluation.


local fred_gamestate_utils_incremental = {}

function fred_gamestate_utils_incremental.get_unit_defense(unit_id, unit_loc, x, y, defense_map)
    -- Get the terrain defense of a unit as a factor (that is, e.g. 0.40 rather than 40)
    -- The result is stored (and accessed if it exists) in defense_map
    --
    -- Inputs:
    -- @unit_id: id of the unit
    -- @unit_loc: current location of the unit in format { x, y }. Even though the unit could be
    --    found using the id alone, we do it this way because wesnoth.get_unit(x, y) is
    --    much faster than wesnoth.get_units { id = }
    -- @x, @y: the location for which to calculate the unit's terrain defense
    -- @defense_map: table in which to cache the results.  Note: this is NOT an optional input
    --
    -- Sample structure of defense_map:
    --   defense_map['Vanak'][19][4] = 0.6

    if (not defense_map[unit_id]) then defense_map[unit_id] = {} end
    if (not defense_map[unit_id][x]) then defense_map[unit_id][x] = {} end

    if (not defense_map[unit_id][x][y]) then
        local unit = wesnoth.get_unit(unit_loc[1], unit_loc[2])
        local defense = (100. - wesnoth.unit_defense(unit, wesnoth.get_terrain(x, y))) / 100.

        defense_map[unit_id][x][y] = defense
        return defense
    else
        return defense_map[unit_id][x][y]
    end
end

return fred_gamestate_utils_incremental
