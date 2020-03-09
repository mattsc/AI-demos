local AH = wesnoth.dofile "ai/lua/ai_helper.lua"
local H = wesnoth.require "helper"
local FGM = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_map.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"
local COMP = wesnoth.require "~/add-ons/AI-demos/lua/compatibility.lua"

-- Collection of functions to get information about units and the gamestate and
-- collect them in tables for easy access. They are expensive, so this should
-- be done as infrequently as possible, but it needs to be redone after each move.
--
-- Unlike fred_gamestate_utils_incremental.lua, these functions are called once
-- and assemble information about all units/villages at once, as likely most of
-- this information will be needed during the move evaluation, or is needed to
-- collect some of the other information anyway.
--
-- Variable use and naming conventions:
--  - Singular vs. plural: here, a plural variable name means it is of the same form as
--    the singular variable, but one such variable exists for each unit. Indexed by id.
--    The exception are units, where even the single unit contains the id index.
--    Only the singular variable types are described here.
--    Note: in the main code, plural variables might also be indexed by number or other means
--
--  - Units:
--    - 'unit', 'enemy' etc.: identify units of form: unit = { id = { x, y } }
--    - 'unit_info': various information about a unit, for faster access than through wesnoth.*() functions
--        Note: this does NOT include the unit location
--    - 'unit_copy': private copy of a unit proxy table for when full unit information is needed.
--    - 'unit_proxy': Use of unit proxy tables should be avoided as much as possible, because they are slow to access.
--    Note: these functions cannot deal correctly with allied sides at this time
--
--  - Maps:
--  - *_map: location indexed map: map[x][y] = { key1 = value, ... }
--
---------- Part of both mapstate and move_data ----------
--
------ Unit tables ------
--
-- These are all of form { id = loc }, with loc = { x, y }, e.g:
-- units = { Orcish Assassin-785 = { [1] = 24, [2] = 7 }
--
-- units             -- all units on the map
-- my_units          -- all AI units
-- my_units_MP       -- all AI units that can move (with MP _and_ not blocked)
-- my_units_noMP     -- all AI units that cannot move (MP=0 or blocked)
-- enemies           -- all enemy units
--
--The leader table is slightly different in that it is indexed by side number and contains the id as an additional parameter
--
-- leaders = { [1] = { [1] = 19, [2] = 4, id = 'Fred' }
--
------ Unit maps ------
--
-- my_unit_map          -- all AI units
-- my_unit_map_MP       -- all AI units that can move (with MP _and_ not blocked)
-- my_unit_map_noMP     -- all AI units that cannot move (MP=0 or blocked)
-- enemy_map            -- all enemy units
--   Note: there is currently no map for all units, will be created is needed
--
------ Other maps ------
--
-- village_map[x][y] = { owner = 1 }            -- owner=0 if village is unowned
-- enemy_attack_map[x][y] = {
--              hitpoints = 88,                 -- combined hitpoints
--              Elvish Archer-11 = true,        -- ids of units that can get there
--              Elvish Avenger-13 = true,
--              units = 2                       -- number of units that can attack that hex
--          }
-- my_attack_map[x][y] = { ... }                 -- same for own units
-- enemy_turn_maps[id][x][y] = { turns = 1.2 }  -- How many turns (fraction, cost / max_moves) unit needs to get to hex
--                                              -- Out to max of additional_turns+1 turns (currently hard-coded to 2)
--                                              -- Note that this is 0 for hex the unit is on
--
---------- Separate from mapstate, but part of move_data ----------
--
-- defense_maps[id][x][y] = { defense = 0.4 }         -- defense (fraction) on the terrain; e.g. 0.4 for Grunt on flat
-- reach_maps[id][x][y] = { moves_left = 3 }          -- moves left after moving to this hex
--    - Note: unlike wesnoth.find_reach etc., this map does NOT include hexes occupied by
--      own units that cannot move out of the way
--
-- unit_copies[id] = { private copy of the proxy table  }
--
-- unit_infos[id] = { ...}   -- Easily accessible list of unit information

local function show_timing_info(fred_data, text)
    -- Set to true or false manually, to enable timing info specifically for this
    -- function. The debug_utils timing flag still needs to be set also.
    if true then
        DBG.print_timing(fred_data, 1, text)
    end
end

local function find_connected_castles(keeps_map)
    local castle_map, new_hexes = {}, {}
    for x,y in FGM.iter(keeps_map) do
        FGM.set_value(castle_map, x, y, 'castle', true)
        if wesnoth.get_terrain_info(wesnoth.get_terrain(x, y)).keep then
            castle_map[x][y].keep = true
        end
        table.insert(new_hexes, { x, y })
    end

    while (#new_hexes > 0) do
        local old_hexes = AH.table_copy(new_hexes)
        new_hexes = {}

        for _,hex in ipairs(old_hexes) do
            for xa,ya in H.adjacent_tiles(hex[1], hex[2]) do
                local terrain_info = wesnoth.get_terrain_info(wesnoth.get_terrain(xa, ya))
                if (not FGM.get_value(castle_map, xa, ya, 'castle'))
                    and terrain_info.castle
                then
                    table.insert(new_hexes, { xa, ya })
                    FGM.set_value(castle_map, xa, ya, 'castle', true)
                    if terrain_info.keep then
                        castle_map[xa][ya].keep = true
                    end
                end
            end
        end
    end

    return castle_map
end


local fred_gamestate_utils = {}

function fred_gamestate_utils.get_move_data(fred_data)
    -- Returns:
    --   - State of villages and units on the map (all in one variable: gamestate)
    --   - Reach maps for all the AI's units (in separate variable: reach_maps)
    --   - Private unit copies (in separate variable: unit_copies)
    -- These are returned separately in case only part of it is needed.
    -- They can also be retrieved all in one table using get_move_data()
    --
    -- See above for the information returned

    show_timing_info(fred_data, 'start fred_gamestate_utils.get_move_data()')

    local village_map = {}
    for _,village in ipairs(wesnoth.get_villages()) do
        FGM.set_value(village_map, village[1], village[2], 'owner',
            wesnoth.get_village_owner(village[1], village[2]) or 0
        )
    end

    local units = {}
    local my_units, my_units_MP, my_units_noMP, enemies = {}, {}, {}, {}
    local unit_map, my_unit_map, my_unit_map_MP, my_unit_map_noMP, enemy_map = {}, {}, {}, {}, {}
    local my_attack_map, my_move_map = {}, {}
    local unit_attack_maps = { {}, {} }
    local unit_infos = {}
    local unit_copies = {}
    local reach_maps = {}

    local additional_turns = 1
    for i = 1,additional_turns+1 do
        my_attack_map[i] = {}
        my_move_map[i] = {}
    end

    local unit_proxies = COMP.get_units()

    local leaders = {} -- this is not added to move_data
    for _,unit_proxy in ipairs(unit_proxies) do
        local unit_info = FU.single_unit_info(unit_proxy)
        local unit_copy = COMP.copy_unit(unit_proxy)
        local id, x, y = unit_info.id, unit_copy.x, unit_copy.y
        local current_power = FU.unit_current_power(unit_info)
        local max_moves = unit_info.max_moves

        unit_infos[id] = unit_info
        unit_copies[id] = unit_copy

        unit_attack_maps[1][id] = {}
        unit_attack_maps[2][id] = {}

        units[id] = { x, y }

        if unit_info.canrecruit then
            leaders[unit_info.side] = { x, y, id = id }
        end

        if (unit_info.side == wesnoth.current.side) then
            FGM.set_value(unit_map, x, y, 'id', id)
            FGM.set_value(my_unit_map, x, y, 'id', id)
            my_units[id] = { x, y }

            -- Hexes the unit can reach in additional_turns+1 turns
            local reach = wesnoth.find_reach(unit_copy, { additional_turns = additional_turns })

            local n_reach_this_turn = 0
            reach_maps[id] = {}
            local attack_range, moves_left = {}, {}

            for _,loc in ipairs(reach) do
                -- reach_map:
                -- Only first-turn moves counts toward reach_maps
                if (loc[3] >= (max_moves * additional_turns)) then
                    FGM.set_value(reach_maps[id], loc[1], loc[2], 'moves_left', loc[3] - (max_moves * additional_turns))
                    n_reach_this_turn = n_reach_this_turn + 1
                end

                -- attack_range: for attack_map
                local turns = (additional_turns + 1) - loc[3] / max_moves
                local int_turns = math.ceil(turns)
                if (int_turns == 0) then int_turns = 1 end

                local moves_left_this_turn = loc[3] % max_moves
                if (loc[1] == x) and (loc[2] == y) then
                    moves_left_this_turn = max_moves
                end

                if (not my_move_map[int_turns][loc[1]]) then my_move_map[int_turns][loc[1]] = {} end
                if (not my_move_map[int_turns][loc[1]][loc[2]]) then my_move_map[int_turns][loc[1]][loc[2]] = {} end
                if (not my_move_map[int_turns][loc[1]][loc[2]].ids) then my_move_map[int_turns][loc[1]][loc[2]].ids = {} end
                table.insert(my_move_map[int_turns][loc[1]][loc[2]].ids, id)

                if (not attack_range[loc[1]]) then
                    attack_range[loc[1]] = {}
                    moves_left[loc[1]] = {}
                end
                if (not attack_range[loc[1]][loc[2]]) or (attack_range[loc[1]][loc[2]] > int_turns) then
                    attack_range[loc[1]][loc[2]] = int_turns
                    moves_left[loc[1]][loc[2]] = moves_left_this_turn
                elseif (attack_range[loc[1]][loc[2]] == int_turns) and (moves_left[loc[1]][loc[2]] < moves_left_this_turn) then
                    moves_left[loc[1]][loc[2]] = moves_left_this_turn
                end

                for xa,ya in H.adjacent_tiles(loc[1], loc[2]) do
                    if (not attack_range[xa]) then
                        attack_range[xa] = {}
                        moves_left[xa] = {}
                    end

                    if (not attack_range[xa][ya]) or (attack_range[xa][ya] > int_turns) then
                        attack_range[xa][ya] = int_turns
                        moves_left[xa][ya] = moves_left_this_turn
                    elseif (attack_range[xa][ya] == int_turns) and (moves_left[xa][ya] < moves_left_this_turn) then
                        moves_left[xa][ya] = moves_left_this_turn
                    end
                end
            end

            -- This is not a standard fgsmap
            for x,arr in pairs(attack_range) do
                for y,int_turns in pairs(arr) do
                    if (not my_attack_map[int_turns][x]) then my_attack_map[int_turns][x] = {} end
                    if (not my_attack_map[int_turns][x][y]) then my_attack_map[int_turns][x][y] = {} end
                    if (not my_attack_map[int_turns][x][y].ids) then my_attack_map[int_turns][x][y].ids = {} end
                    table.insert(my_attack_map[int_turns][x][y].ids, id)

                    if (int_turns <= 2) then
                        FGM.set_value(unit_attack_maps[int_turns][id], x, y, 'current_power', current_power)
                        unit_attack_maps[int_turns][id][x][y].moves_left_this_turn = moves_left[x][y]
                    end
                end
            end

            if (n_reach_this_turn > 1) then
                FGM.set_value(my_unit_map_MP, x, y, 'id', id)
                my_units_MP[id] = { x, y }
            else
                FGM.set_value(my_unit_map_noMP, x, y, 'id', id)
                my_units_noMP[id] = { x, y }
            end
        else
            if COMP.is_enemy(unit_info.side, wesnoth.current.side) then
                FGM.set_value(unit_map, x, y, 'id', id)
                FGM.set_value(enemy_map, x, y, 'id', id)
                enemies[id] = { x, y }
            end
        end
    end

    -- reach_maps: eliminate hexes with other own units that cannot move out of the way
    -- Also, there might be hidden enemies on the hex
    for id,reach_map in pairs(reach_maps) do
        for id_noMP,loc in pairs(my_units_noMP) do
            if (id ~= id_noMP) then
                if reach_map[loc[1]] then reach_map[loc[1]][loc[2]] = nil end
            end
        end
    end

    -- Also mark units that can only get to hexes occupied by own units
    local my_units_can_move_away = {}
    for x,y,data in FGM.iter(my_unit_map_MP) do
        for x2,y2,_ in FGM.iter(reach_maps[data.id]) do
            if (not FGM.get_value(my_unit_map, x2, y2, 'id')) then
                my_units_can_move_away[data.id] = true
                break
            end
        end
    end

    -- Reachable keeps: those the leader can actually move onto (AI side only)
    -- Reachable castles: connected to reachable keeps, independent of whether the leader
    --   can get there or not, but must be available for recruiting (no enemy or noMP units on it)
    -- Close keeps: those within one full move, not taking other units into account (all sides)
    -- Close castles: connected to close keeps, not taking other units into account
    local reachable_keeps_map, reachable_castles_map = {}, {}
    local close_keeps_map, close_castles_map = {}, {}
    local my_leader, enemy_leader
    for side,leader in ipairs(leaders) do
        if (side == wesnoth.current.side) then
            my_leader = leader
        else
            enemy_leader = leader
        end

        -- TODO: This might not work on weird maps
        local leader_copy = unit_copies[leader.id]
        local old_moves = leader_copy.moves
        leader_copy.moves = leader_copy.max_moves
        local reach = wesnoth.find_reach(leader_copy, { ignore_units = true })
        leader_copy.moves = old_moves

        close_keeps_map[side], close_castles_map[side] = {}, {}
        if (side == wesnoth.current.side) then
            reachable_keeps_map[side], reachable_castles_map[side] = {}, {}
        end

        for _,loc in ipairs(reach) do
            if wesnoth.get_terrain_info(wesnoth.get_terrain(loc[1], loc[2])).keep then
                FGM.set_value(close_keeps_map[side], loc[1], loc[2], 'moves_left', loc[3])
                if (side == wesnoth.current.side) then
                    local ml = FGM.get_value(reach_maps[leader.id], loc[1], loc[2], 'moves_left')
                    if ml then -- this excludes hexes with units without MP
                        FGM.set_value(reachable_keeps_map[side], loc[1], loc[2], 'moves_left', ml)
                    end
                end
            end
        end

        close_castles_map[side] = find_connected_castles(close_keeps_map[side])
        if (side == wesnoth.current.side) then
            reachable_castles_map[side] = find_connected_castles(reachable_keeps_map[side])
            for x,y in FGM.iter(reachable_castles_map[side]) do
                if FGM.get_value(enemy_map, x, y, 'id') or FGM.get_value(my_unit_map_noMP, x, y, 'id') then
                    reachable_castles_map[side][x][y] = nil
                end
            end
        end

        if DBG.show_debug('ops_keep_maps') then
            DBG.show_fgumap_with_message(close_keeps_map[side], 'moves_left', 'close_keeps_map: Side ' .. side, { x = leader[1], y = leader[2] })
            DBG.show_fgumap_with_message(close_castles_map[side], 'castle', 'close_castles_map: Side ' .. side, { x = leader[1], y = leader[2] })
            if reachable_keeps_map[side] then
                DBG.show_fgumap_with_message(reachable_keeps_map[side], 'moves_left', 'reachable_keeps_map: Side ' .. side, { x = leader[1], y = leader[2] })
                DBG.show_fgumap_with_message(reachable_castles_map[side], 'castle', 'reachable_castles_map: Side ' .. side, { x = leader[1], y = leader[2] })
            end
        end
    end


    -- Get enemy attack and reach maps
    -- These are for max MP of enemy units, and after taking all AI units with MP off the map
    local enemy_attack_map, enemy_turn_maps, trapped_enemies = {}, {}, {}

    for i = 1,additional_turns+1 do
        enemy_attack_map[i] = {}
    end

    -- Take all own units with MP left off the map (for enemy pathfinding)
    local extracted_units = {}
    for id,loc in pairs(my_units_MP) do
        local unit_proxy = COMP.get_unit(loc[1], loc[2])
        COMP.extract_unit(unit_proxy)
        table.insert(extracted_units, unit_proxy)
    end

    for enemy_id,_ in pairs(enemies) do
        local unit_cost = unit_copies[enemy_id].cost
        local old_moves = unit_copies[enemy_id].moves
        unit_copies[enemy_id].moves = unit_copies[enemy_id].max_moves

        unit_attack_maps[1][enemy_id] = {}
        unit_attack_maps[2][enemy_id] = {}

        -- Hexes the enemy can reach in additional_turns+1 turns
        local reach = wesnoth.find_reach(unit_copies[enemy_id], { additional_turns = additional_turns })

        unit_copies[enemy_id].moves = old_moves

        reach_maps[enemy_id], enemy_turn_maps[enemy_id] = {}, {}
        local is_trapped = true
        local attack_range = {}
        for _,loc in ipairs(reach) do
            -- reach_map:
            -- Only first-turn moves counts toward reach_maps
            local max_moves = unit_copies[enemy_id].max_moves
            if (loc[3] >= (max_moves * additional_turns)) then
                FGM.set_value(reach_maps[enemy_id], loc[1], loc[2], 'moves_left', loc[3] - (max_moves * additional_turns))
            end

            -- We count all enemies that can not move more than 1 hex from their
            -- current location (for whatever reason) as trapped

            -- turn_map:
            local turns = (additional_turns + 1) - loc[3] / max_moves
            FGM.set_value(enemy_turn_maps[enemy_id], loc[1], loc[2], 'turns', turns)


            -- attack_range: for attack_map
            local int_turns = math.ceil(turns)
            if (int_turns == 0) then int_turns = 1 end

            if is_trapped and (int_turns == 1) then
                if (wesnoth.map.distance_between(loc[1], loc[2], unit_copies[enemy_id].x, unit_copies[enemy_id].y) > 1) then
                    is_trapped = nil
                end
            end

            if (not attack_range[loc[1]]) then attack_range[loc[1]] = {} end
            if (not attack_range[loc[1]][loc[2]]) or (attack_range[loc[1]][loc[2]] > int_turns) then
                attack_range[loc[1]][loc[2]] = int_turns
            end

            for xa,ya in H.adjacent_tiles(loc[1], loc[2]) do
                if (not attack_range[xa]) then attack_range[xa] = {} end

                if (not attack_range[xa][ya]) or (attack_range[xa][ya] > int_turns) then
                    attack_range[xa][ya] = int_turns
                end
            end
        end

        if is_trapped then
            trapped_enemies[enemy_id] = true
        end

        -- This is not a standard fgsmap
        for x,arr in pairs(attack_range) do
            for y,int_turns in pairs(arr) do
                if (not enemy_attack_map[int_turns][x]) then enemy_attack_map[int_turns][x] = {} end
                if (not enemy_attack_map[int_turns][x][y]) then enemy_attack_map[int_turns][x][y] = {} end
                if (not enemy_attack_map[int_turns][x][y].ids) then enemy_attack_map[int_turns][x][y].ids = {} end
                table.insert(enemy_attack_map[int_turns][x][y].ids, enemy_id)

                if (int_turns <= 2) then
                    local current_power = FU.unit_current_power(unit_infos[enemy_id])
                    FGM.set_value(unit_attack_maps[int_turns][enemy_id], x, y, 'current_power', current_power)
                end
            end
        end
    end

    -- Put the own units with MP back out there
    for _,extracted_unit in ipairs(extracted_units) do COMP.put_unit(extracted_unit) end


    -- Keeping all of this in one place, as a "table of contents"
    fred_data.move_data = {
        units = units,
        my_units = my_units,
        my_units_MP = my_units_MP,
        my_units_can_move_away = my_units_can_move_away,
        my_units_noMP = my_units_noMP,
        enemies = enemies,
        my_leader = my_leader,
        enemy_leader = enemy_leader,

        reachable_keeps_map = reachable_keeps_map,
        reachable_castles_map = reachable_castles_map,
        close_keeps_map = close_keeps_map,
        close_castles_map = close_castles_map,
        village_map = village_map,

        unit_map = unit_map,
        my_unit_map = my_unit_map,
        my_unit_map_MP = my_unit_map_MP,
        my_unit_map_noMP = my_unit_map_noMP,
        my_move_map = my_move_map,
        my_attack_map = my_attack_map,

        enemy_map = enemy_map,
        enemy_attack_map = enemy_attack_map,
        trapped_enemies = trapped_enemies,

        unit_attack_maps = unit_attack_maps,

        reach_maps = reach_maps,
        unit_copies = unit_copies,
        unit_infos = unit_infos,
        defense_maps = {}
    }


    local influence_maps, unit_influence_maps = FU.get_influence_maps(fred_data.move_data)

    fred_data.move_data.influence_maps = influence_maps
    fred_data.move_data.unit_influence_maps = unit_influence_maps

    show_timing_info(fred_data, 'end fred_gamestate_utils.get_move_data()')
end

return fred_gamestate_utils
