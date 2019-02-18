-- Set up (and reset) hypothetical situations on the map that can be used for
-- analyses of ZoC, counter attacks etc.

local H = wesnoth.require "helper"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"


-- Two arrays to be made available below via closure
local FVS_stored_units, FVS_ids, FVS_add_units, FVS_extracted_units


----- Begin adjust_move_data_tables() -----
local function adjust_move_data_tables(old_locs, new_locs, store_units_in_way, move_data, stored_data)
    -- Adjust all the move_data tables to the new position, and reset them again later.
    -- This is a local function as only the virtual state calculations should have to move units.
    --
    -- INPUTS:
    -- @old_locs, @new_locs as above
    -- @store_units_in_way (boolean): whether to store the locations of the units in the way. Needs to
    -- be set to 'true' when moving the units into their new locations, needs to be set to
    -- 'false' when moving them back, in which case the stored information will be used.
    --
    -- OPTIONAL INPUTS:
    -- @stored_data: table for temporary storage of units and ids. This is usually done automatically
    --   in the FVS_* variables via closure, but that does not work with nested uses of these functions.
    --
    -- Output:
    -- Returns nil if no counter attacks were found, otherwise a table with a
    -- variety of attack outcomes and ratings

    -- If any of the hexes marked in @new_locs is occupied, we
    -- need to store that information as it otherwise will be overwritten.
    -- This needs to be done for all locations before any unit is moved
    -- in order to avoid conflicts of the units to be moved among themselves
    if store_units_in_way then
        for i_l,old_loc in ipairs(old_locs) do
            local x1, y1 = old_loc[1], old_loc[2]
            local x2, y2 = new_locs[i_l][1], new_locs[i_l][2]

            -- Store the ids of the units to be put onto the map.
            -- This includes units with MP that attack from their current position,
            -- but not units without MP (as the latter are already on the map)
            -- Note: this array might have missing elements -> needs to be iterated using pairs()
            if move_data.my_unit_map_MP[x1] and move_data.my_unit_map_MP[x1][y1] then
                if stored_data then
                    stored_data.FVS_ids[i_l] = move_data.my_unit_map_MP[x1][y1].id
                else
                    FVS_ids[i_l] = move_data.my_unit_map_MP[x1][y1].id
                end
            end

            -- By contrast, we only need to store the information about units in the way,
            -- if a unit  actually gets moved to the hex (independent of whether it has MP left or not)
            if (x1 ~= x2) or (y1 ~= y2) then
                -- If there is another unit at the new location, store it
                -- It does not matter for this whether this is a unit involved in the move or not
                if move_data.my_unit_map[x2] and move_data.my_unit_map[x2][y2] then
                    if stored_data then
                        stored_data.FVS_stored_units[move_data.my_unit_map[x2][y2].id] = { x2, y2 }
                    else
                        FVS_stored_units[move_data.my_unit_map[x2][y2].id] = { x2, y2 }
                    end
                end
            end
        end
    end

    -- Now adjust all the move_data tables
    for i_l,old_loc in ipairs(old_locs) do
        local x1, y1 = old_loc[1], old_loc[2]
        local x2, y2 = new_locs[i_l][1], new_locs[i_l][2]
        --std_print('Moving unit:', x1, y1, '-->', x2, y2)

        -- We only need to do this if the unit actually gets moved
        if (x1 ~= x2) or (y1 ~= y2) then
            local id = stored_data and stored_data.FVS_ids[i_l] or FVS_ids[i_l]

            -- Likely, not all of these tables have to be changed, but it takes
            -- very little time, so better safe than sorry
            move_data.unit_copies[id].x, move_data.unit_copies[id].y = x2, y2

            move_data.units[id] = { x2, y2 }
            move_data.my_units[id] = { x2, y2 }
            move_data.my_units_MP[id] = { x2, y2 }

            if move_data.unit_infos[id].canrecruit then
                move_data.leaders[wesnoth.current.side] = { x2, y2, id = id }
            end

            -- Note that the following might leave empty orphan table elements, but that doesn't matter
            move_data.my_unit_map[x1][y1] = nil
            if (not move_data.my_unit_map[x2]) then move_data.my_unit_map[x2] = {} end
            move_data.my_unit_map[x2][y2] = { id = id }

            move_data.my_unit_map_MP[x1][y1] = nil
            if (not move_data.my_unit_map_MP[x2]) then move_data.my_unit_map_MP[x2] = {} end
            move_data.my_unit_map_MP[x2][y2] = { id = id }
        end
    end

    -- Finally, if 'store_units_in_way' is not set (this is, when moving units back
    -- into place), restore the stored units into the maps again
    if (not store_units_in_way) then
        for id,loc in pairs(stored_data and stored_data.FVS_stored_units or FVS_stored_units) do
            move_data.my_unit_map[loc[1]][loc[2]] = { id = id }
            move_data.my_unit_map_MP[loc[1]][loc[2]] = { id = id }
        end
    end
end
----- End adjust_move_data_tables() -----


local fred_virtual_state = {}

function fred_virtual_state.set_virtual_state(old_locs, new_locs, additional_units, do_extract_units, move_data, stored_data)

    if stored_data then
        stored_data.FVS_stored_units, stored_data.FVS_ids, stored_data.FVS_add_units, stored_data.extracted_units = {}, {}, {}, {}
    else
        FVS_stored_units, FVS_ids, FVS_add_units, FVS_extracted_units = {}, {}, {}, {}
    end

    if do_extract_units then
        for id,loc in pairs(move_data.my_units_MP) do
            local unit_proxy = wesnoth.get_unit(loc[1], loc[2])
            wesnoth.extract_unit(unit_proxy)
            table.insert(stored_data and stored_data.extracted_units or FVS_extracted_units, unit_proxy)  -- Not a proxy unit any more at this point
        end
    end

    -- Mark the new positions of the units in the move_data tables
    adjust_move_data_tables(old_locs, new_locs, true, move_data, stored_data)

    -- Put all units in old_locs with MP onto the map (those without are already there)
    -- They need to be proxy units for the counter attack calculation.
    for _,id in pairs(stored_data and stored_data.FVS_ids or FVS_ids) do
        wesnoth.put_unit(move_data.unit_copies[id])
    end

    -- Also put the additonal units out there
    if additional_units then
        for _,add_unit in ipairs(additional_units) do
            local place_unit = true
            for _,new_loc in ipairs(new_locs) do
                if (add_unit[1] == new_loc[1]) and (add_unit[2] == new_loc[2]) then
                    place_unit = false
                    break
                end
            end
            if place_unit then
                if stored_data then
                    table.insert(stored_data.FVS_add_units, add_unit)
                else
                    table.insert(FVS_add_units, add_unit)
                end

                wesnoth.put_unit({
                    type = add_unit.type,
                    random_traits = false,
                    name = "X",
                    random_gender = false,
                    moves = 0
                },
                    add_unit[1], add_unit[2]
                )
            end
        end
    end
end

function fred_virtual_state.reset_state(old_locs, new_locs, do_extract_units, move_data, stored_data)
    -- Extract the units from the map
    for _,add_unit in ipairs(stored_data and stored_data.FVS_add_units or FVS_add_units) do
        wesnoth.erase_unit(add_unit[1], add_unit[2])
    end
    for _,id in pairs(stored_data and stored_data.FVS_ids or FVS_ids) do
        wesnoth.extract_unit(move_data.unit_copies[id])
    end

    -- And put them back into their original locations
    adjust_move_data_tables(new_locs, old_locs, false, move_data, stored_data)

    -- Put the extracted units back on the map
    if do_extract_units then
        for _,extracted_unit in ipairs(stored_data and stored_data.extracted_units or FVS_extracted_units) do
            wesnoth.put_unit(extracted_unit)
        end
    end

    if stored_data then
        stored_data.FVS_stored_units, stored_data.FVS_ids, stored_data.FVS_add_units, stored_data.extracted_units = nil, nil, nil, nil
    else
        FVS_stored_units, FVS_ids, FVS_add_units, FVS_extracted_units = nil, nil, nil, nil
    end
end

function fred_virtual_state.virtual_reach_maps(units, to_enemy_locs, to_locs, move_data)
    -- Find new reach_maps of @units  in a (virtual) situation that has been set up on the map
    -- This is only done for units which could previously attack @to_enemies or move onto @to_hexes.
    -- The point of this is to test if placing AI units in certain positions changes where
    -- enemies can attack or reach.
    -- Note that this means that either @to_enemy_locs or @to_locs must be given,
    -- otherwise this function will always return empty reachmaps.
    --
    -- TODO: this could (should?) eventually also include placing the units in the new positions

    reach_maps = {}
    for unit_id,_ in pairs(units) do
        reach_maps[unit_id] = {}

        -- Only calculate reach if the unit could get there using its
        -- original reach. It cannot have gotten any better than this.
        local can_reach = false
        if to_enemy_locs then
            for _,enemy_loc in ipairs(to_enemy_locs) do
                for xa,ya in H.adjacent_tiles(enemy_loc[1], enemy_loc[2]) do
                    if move_data.reach_maps[unit_id][xa] and move_data.reach_maps[unit_id][xa][ya] then
                        can_reach = true
                        break
                    end
                end
                if can_reach then break end
            end
        end
        if (not can_reach) and to_locs then
            for _,loc in ipairs(to_locs) do
                if move_data.reach_maps[unit_id][loc[1]] and move_data.reach_maps[unit_id][loc[1]][loc[2]] then
                    can_reach = true
                    break
                end
            end
        end

        if can_reach then
            -- For sides other than the current, we always use max_moves.
            -- For the current side, we always use current moves.
            local old_moves
            if (move_data.unit_infos[unit_id].side ~= wesnoth.current.side) then
                old_moves = move_data.unit_copies[unit_id].moves
                move_data.unit_copies[unit_id].moves = move_data.unit_copies[unit_id].max_moves
            end

            local reach = wesnoth.find_reach(move_data.unit_copies[unit_id])

            for _,r in ipairs(reach) do
                FU.set_fgumap_value(reach_maps[unit_id], r[1], r[2], 'moves_left', r[3])
            end

            if (move_data.unit_infos[unit_id].side ~= wesnoth.current.side) then
                move_data.unit_copies[unit_id].moves = old_moves
            end
        end
    end

    -- Eliminate hexes with other units that cannot move out of the way
    for id,reach_map in pairs(reach_maps) do
        for id_noMP,loc in pairs(move_data.my_units_noMP) do
            if (id ~= id_noMP) then
                if reach_map[loc[1]] then reach_map[loc[1]][loc[2]] = nil end
            end
        end
    end

    return reach_maps
end

return fred_virtual_state
