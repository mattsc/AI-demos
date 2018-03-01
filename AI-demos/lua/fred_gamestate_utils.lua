local H = wesnoth.require "lua/helper.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
--local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

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
--   Example: (note 'hides = true' and 'charge = true' for ability and weapon special)
--
--    Chocobone-17 = {
--        hides = true,
--        canrecruit = false,
--        tod_mod = 1.25,
--        id = "Chocobone-17",
--        max_hitpoints = 45,
--        max_experience = 100,
--        hitpoints = 45,
--        attacks = {
--            [1] = {
--                number = 2,
--                type = "pierce",
--                name = "spear",
--                charge = true,
--                range = "melee",
--                damage = 11
--            }
--        },
--        experience = 0,
--        resistances = {
--            blade = 0.8,
--            arcane = 1.5,
--            pierce = 0.7,
--            fire = 1.2,
--            impact = 1.1,
--            cold = 0.4
--        },
--        cost = 38,
--        level = 2,
--        alignment = "chaotic",
--        side = 1
--    },

local fred_gamestate_utils = {}

function fred_gamestate_utils.unit_infos()
    -- Wrapper function to fred_utils.single_unit_info()
    -- Assembles information for all units on the map, indexed by unit id

    local unit_proxies = wesnoth.get_units()

    local unit_infos = {}
    for _,unit_proxy in ipairs(unit_proxies) do
        unit_infos[unit_proxy.id] = FU.single_unit_info(unit_proxy)
    end

    return unit_infos
end

function fred_gamestate_utils.get_move_data()
    -- Returns:
    --   - State of villages and units on the map (all in one variable: gamestate)
    --   - Reach maps for all the AI's units (in separate variable: reach_maps)
    --   - Private unit copies (in separate variable: unit_copies)
    -- These are returned separately in case only part of it is needed.
    -- They can also be retrieved all in one table using get_move_data()
    --
    -- See above for the information returned

    local unit_infos = fred_gamestate_utils.unit_infos()

    local mapstate, reach_maps = {}, {}

    -- Villages
    local village_map = {}
    for _,village in ipairs(wesnoth.get_villages()) do
        if (not village_map[village[1]]) then village_map[village[1]] = {} end
        village_map[village[1]][village[2]] = {
            owner = wesnoth.get_village_owner(village[1], village[2]) or 0
        }
    end
    mapstate.village_map = village_map

    -- Unit locations and copies
    local units, leaders = {}, {}
    local my_units, my_units_MP, my_units_noMP, enemies = {}, {}, {}, {}
    local unit_map, my_unit_map, my_unit_map_MP, my_unit_map_noMP, enemy_map = {}, {}, {}, {}, {}
    local my_attack_map, my_move_map = {}, {}
    local unit_attack_maps = { {}, {} }
    local unit_copies = {}

    local additional_turns = 1
    for i = 1,additional_turns+1 do
        my_attack_map[i] = {}
        my_move_map[i] = {}
    end

    for _,unit_proxy in ipairs(wesnoth.get_units()) do
        local unit_copy = wesnoth.copy_unit(unit_proxy)
        local id = unit_proxy.id
        unit_copies[unit_copy.id] = unit_copy
        unit_attack_maps[1][id] = {}
        unit_attack_maps[2][id] = {}

        units[unit_copy.id] = { unit_copy.x, unit_copy.y }

        if unit_copy.canrecruit then
            leaders[unit_copy.side] = { unit_copy.x, unit_copy.y, id = unit_copy.id }
        end

        if (unit_copy.side == wesnoth.current.side) then
            if (not unit_map[unit_copy.x]) then unit_map[unit_copy.x] = {} end
            unit_map[unit_copy.x][unit_copy.y] = { id = unit_copy.id }

            if (not my_unit_map[unit_copy.x]) then my_unit_map[unit_copy.x] = {} end
            my_unit_map[unit_copy.x][unit_copy.y] = { id = unit_copy.id }

            my_units[unit_copy.id] = { unit_copy.x, unit_copy.y }

            -- Hexes the unit can reach in additional_turns+1 turns
            local reach = wesnoth.find_reach(unit_copy, { additional_turns = additional_turns })

            reach_maps[unit_copy.id] = {}
            local attack_range, moves_left = {}, {}

            for _,loc in ipairs(reach) do
                -- reach_map:
                -- Only first-turn moves counts toward reach_maps
                local max_moves = unit_copy.max_moves
                if (loc[3] >= (max_moves * additional_turns)) then
                    if (not reach_maps[id][loc[1]]) then reach_maps[id][loc[1]] = {} end
                    reach_maps[id][loc[1]][loc[2]] = { moves_left = loc[3] - (max_moves * additional_turns) }
                end

                -- attack_range: for attack_map
                local turns = (additional_turns + 1) - loc[3] / max_moves
                local int_turns = math.ceil(turns)
                if (int_turns == 0) then int_turns = 1 end

                local moves_left_this_turn = loc[3] % max_moves
                if (loc[1] == unit_copy.x) and (loc[2] == unit_copy.y) then
                    moves_left_this_turn = max_moves
                end

                if (not my_move_map[int_turns][loc[1]]) then my_move_map[int_turns][loc[1]] = {} end
                if (not my_move_map[int_turns][loc[1]][loc[2]]) then my_move_map[int_turns][loc[1]][loc[2]] = {} end
                if (not my_move_map[int_turns][loc[1]][loc[2]].ids) then my_move_map[int_turns][loc[1]][loc[2]].ids = {} end
                my_move_map[int_turns][loc[1]][loc[2]].units = (my_move_map[int_turns][loc[1]][loc[2]].units or 0) + 1

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

            for x,arr in pairs(attack_range) do
                for y,int_turns in pairs(arr) do
                    if (not my_attack_map[int_turns][x]) then my_attack_map[int_turns][x] = {} end
                    if (not my_attack_map[int_turns][x][y]) then my_attack_map[int_turns][x][y] = {} end
                    if (not my_attack_map[int_turns][x][y].ids) then my_attack_map[int_turns][x][y].ids = {} end

                    my_attack_map[int_turns][x][y].units = (my_attack_map[int_turns][x][y].units or 0) + 1

                    table.insert(my_attack_map[int_turns][x][y].ids, id)

                    if (int_turns <= 2) then
                        local current_power = FU.unit_current_power(unit_infos[id])
                        FU.set_fgumap_value(unit_attack_maps[int_turns][id], x, y, 'current_power', current_power)
                        unit_attack_maps[int_turns][id][x][y].moves_left_this_turn = moves_left[x][y]
                    end
                end
            end

            -- TODO: I'm getting reach again here without additional_turns,
            -- for convenience; this can be sped up
            local reach = wesnoth.find_reach(unit_copy)

            if (#reach > 1) then
                if (not my_unit_map_MP[unit_copy.x]) then my_unit_map_MP[unit_copy.x] = {} end
                my_unit_map_MP[unit_copy.x][unit_copy.y] = { id = unit_copy.id }

                my_units_MP[unit_copy.id] = { unit_copy.x, unit_copy.y }
            else
                if (not my_unit_map_noMP[unit_copy.x]) then my_unit_map_noMP[unit_copy.x] = {} end
                my_unit_map_noMP[unit_copy.x][unit_copy.y] = { id = unit_copy.id }

                my_units_noMP[unit_copy.id] = { unit_copy.x, unit_copy.y }
            end
        else
            if wesnoth.is_enemy(unit_copy.side, wesnoth.current.side) then
                if (not unit_map[unit_copy.x]) then unit_map[unit_copy.x] = {} end
                unit_map[unit_copy.x][unit_copy.y] = { id = unit_copy.id }

                if (not enemy_map[unit_copy.x]) then enemy_map[unit_copy.x] = {} end
                enemy_map[unit_copy.x][unit_copy.y] = { id = unit_copy.id }

                enemies[unit_copy.id] = { unit_copy.x, unit_copy.y }
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

        for id_enemy,loc in pairs(enemies) do
            if reach_map[loc[1]] then reach_map[loc[1]][loc[2]] = nil end
        end
    end

    -- Leader and enemy leader coordinates. These are needed often enough that
    -- it is worth not extracting them from the leaders table every time
    local reachable_keeps_map, reachable_castles_map = {}, {}
    local width,height,border = wesnoth.get_map_size()
    for side,leader in ipairs(leaders) do
        if (side == wesnoth.current.side) then
            mapstate.leader_x, mapstate.leader_y = leader[1], leader[2]
        else
            mapstate.enemy_leader_x, mapstate.enemy_leader_y = leader[1], leader[2]
        end

        -- Get closest keeps and connected castles
        -- This might not work on weird maps
        local leader_copy = unit_copies[leader.id]
        local old_moves = leader_copy.moves
        leader_copy.moves = leader_copy.max_moves
        -- Hexes the enemy can reach in additional_turns+1 turns
        local reach = wesnoth.find_reach(leader_copy, { ignore_units = true })
        leader_copy.moves = old_moves

        reachable_keeps_map[side], reachable_castles_map[side] = {}, {}
        for _,loc in ipairs(reach) do
            if wesnoth.get_terrain_info(wesnoth.get_terrain(loc[1], loc[2])).keep then
                FU.set_fgumap_value(reachable_keeps_map[side], loc[1], loc[2], 'moves_left', loc[3])
            end
        end

        -- Note that this is not strictly castle reachable by the leader, but
        -- castles connected to keeps reachable by the leader
        for x,arr in pairs(reachable_keeps_map[side]) do
            for y,data in pairs(arr) do
                local reachable_castles = wesnoth.get_locations {
                    x = "1-"..width, y = "1-"..height,
                    { "and", {
                        x = x, y = y, radius = 200,
                        { "filter_radius", { terrain = 'C*,K*,C*^*,K*^*,*^K*,*^C*' } }
                    } }
                }

                for _,loc in ipairs(reachable_castles) do
                    FU.set_fgumap_value(reachable_castles_map[side], loc[1], loc[2], 'castle', true)
                    if wesnoth.get_terrain_info(wesnoth.get_terrain(loc[1], loc[2])).keep then
                        reachable_castles_map[side][loc[1]][loc[2]].keep = true
                    end
                end
            end
        end
    end


    mapstate.units = units
    mapstate.my_units = my_units
    mapstate.my_units_MP = my_units_MP
    mapstate.my_units_noMP = my_units_noMP
    mapstate.enemies = enemies
    mapstate.leaders = leaders
    mapstate.reachable_keeps_map = reachable_keeps_map
    mapstate.reachable_castles_map = reachable_castles_map

    mapstate.unit_map = unit_map
    mapstate.my_unit_map = my_unit_map
    mapstate.my_unit_map_MP = my_unit_map_MP
    mapstate.my_unit_map_noMP = my_unit_map_noMP
    mapstate.my_move_map = my_move_map
    mapstate.my_attack_map = my_attack_map
    mapstate.enemy_map = enemy_map

    -- Get enemy attack and reach maps
    -- These are for max MP of enemy units, and after taking all AI units with MP off the map
    local enemy_attack_map, enemy_turn_maps, trapped_enemies = {}, {}, {}

    for i = 1,additional_turns+1 do
        enemy_attack_map[i] = {}
    end

    -- Take all own units with MP left off the map (for enemy pathfinding)
    local extracted_units = {}
    for id,loc in pairs(mapstate.my_units_MP) do
        local unit_proxy = wesnoth.get_unit(loc[1], loc[2])
        wesnoth.extract_unit(unit_proxy)
        table.insert(extracted_units, unit_proxy)
    end

    for enemy_id,_ in pairs(mapstate.enemies) do
        local unit_cost = unit_copies[enemy_id].__cfg.cost
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
                if (not reach_maps[enemy_id][loc[1]]) then reach_maps[enemy_id][loc[1]] = {} end
                reach_maps[enemy_id][loc[1]][loc[2]] = { moves_left = loc[3] - (max_moves * additional_turns) }
            end

            -- We count all enemies that can not move more than 1 hex from their
            -- current location (for whatever reason) as trapped

            -- turn_map:
            local turns = (additional_turns + 1) - loc[3] / max_moves
            if (not enemy_turn_maps[enemy_id][loc[1]]) then enemy_turn_maps[enemy_id][loc[1]] = {} end
            enemy_turn_maps[enemy_id][loc[1]][loc[2]] = { turns = turns }


            -- attack_range: for attack_map
            local int_turns = math.ceil(turns)
            if (int_turns == 0) then int_turns = 1 end

            if is_trapped and (int_turns == 1) then
                if (H.distance_between(loc[1], loc[2], unit_copies[enemy_id].x, unit_copies[enemy_id].y) > 1) then
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

        for x,arr in pairs(attack_range) do
            for y,int_turns in pairs(arr) do
                if (not enemy_attack_map[int_turns][x]) then enemy_attack_map[int_turns][x] = {} end
                if (not enemy_attack_map[int_turns][x][y]) then enemy_attack_map[int_turns][x][y] = {} end
                if (not enemy_attack_map[int_turns][x][y].ids) then enemy_attack_map[int_turns][x][y].ids = {} end

                enemy_attack_map[int_turns][x][y].units = (enemy_attack_map[int_turns][x][y].units or 0) + 1

                table.insert(enemy_attack_map[int_turns][x][y].ids, enemy_id)

                if (int_turns <= 2) then
                    local current_power = FU.unit_current_power(unit_infos[enemy_id])
                    FU.set_fgumap_value(unit_attack_maps[int_turns][enemy_id], x, y, 'current_power', current_power)
                end
            end
        end
    end

    -- Put the own units with MP back out there
    for _,extracted_unit in ipairs(extracted_units) do wesnoth.put_unit(extracted_unit) end

    mapstate.enemy_attack_map = enemy_attack_map
    mapstate.enemy_turn_maps = enemy_turn_maps
    mapstate.trapped_enemies = trapped_enemies

    mapstate.unit_attack_maps = unit_attack_maps

    local move_data = mapstate

    move_data.reach_maps = reach_maps
    move_data.unit_copies = unit_copies
    move_data.unit_infos = unit_infos
    move_data.defense_maps = {}

    -- TODO: there's a bunch of duplication here w.r.t. the above
    local support_maps = FU.support_maps(move_data)
    move_data.support_maps = support_maps

    return move_data
end

return fred_gamestate_utils
