local H = wesnoth.require "lua/helper.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"

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
---------- Part of both mapstate and gamedata ----------
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
---------- Separate from mapstate, but part of gamedata ----------
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

function fred_gamestate_utils.single_unit_info(unit_proxy)
    -- Collects unit information from proxy unit table @unit_proxy into a Lua table
    -- so that it is accessible faster.
    -- Note: Even accessing the directly readable fields of a unit proxy table
    -- is slower than reading from a Lua table; not even talking about unit_proxy.__cfg.
    --
    -- Important: this is slow, so it should only be called once at the  beginning
    -- of each move, but it does need to be redone after each move, as it contains
    -- information like HP and XP (or the unit might have level up or been changed
    -- in an event).
    --
    -- Note: unit location information is NOT included
    -- See above for the format and type of information included.

    local unit_cfg = unit_proxy.__cfg

    local single_unit_info = {
        id = unit_proxy.id,
        canrecruit = unit_proxy.canrecruit,
        side = unit_proxy.side,

        moves = unit_proxy.moves,
        max_moves = unit_proxy.max_moves,
        hitpoints = unit_proxy.hitpoints,
        max_hitpoints = unit_proxy.max_hitpoints,
        experience = unit_proxy.experience,
        max_experience = unit_proxy.max_experience,

        type = unit_proxy.type,
        alignment = unit_cfg.alignment,
        cost = unit_cfg.cost,
        level = unit_cfg.level
    }

    -- Include the ability type, such as: hides, heals, regenerate, skirmisher (set up as 'hides = true')
    single_unit_info.abilities = {}
    local abilities = H.get_child(unit_proxy.__cfg, "abilities")
    if abilities then
        for _,ability in ipairs(abilities) do
            single_unit_info.abilities[ability[1]] = true
        end
    end

    -- Add all the statuses
    single_unit_info.status = {}
    local status = H.get_child(unit_cfg, "status")
    for k,_ in pairs(status) do
        single_unit_info.status[k] = true
    end

    -- Traits
    single_unit_info.traits = {}
    local mods = H.get_child(unit_cfg, "modifications")
    for trait in H.child_range(mods, 'trait') do
        single_unit_info.traits[trait.id] = true
    end

    -- Information about the attacks indexed by weapon number,
    -- including specials (e.g. 'poison = true')
    single_unit_info.attacks = {}
    for attack in H.child_range(unit_cfg, 'attack') do
        -- Extract information for specials; we do this first because some
        -- custom special might have the same name as one of the default scalar fields
        local a = {}
        for special in H.child_range(attack, 'specials') do
            for _,sp in ipairs(special) do
                if (sp[1] == 'damage') then  -- this is 'backstab'
                    if (sp[2].id == 'backstab') then
                        a.backstab = true
                    else
                        if (sp[2].id == 'charge') then a.charge = true end
                    end
                else
                    -- magical, marksman
                    if (sp[1] == 'chance_to_hit') then
                        a[sp[2].id] = true
                    else
                        a[sp[1]] = true
                    end
                end
            end
        end

        -- Now extract the scalar (string and number) values from attack
        for k,v in pairs(attack) do
            if (type(v) == 'number') or (type(v) == 'string') then
                a[k] = v
            end
        end

        table.insert(single_unit_info.attacks, a)
    end

    -- Resistances to the 6 default attack types
    local attack_types = { "arcane", "blade", "cold", "fire", "impact", "pierce" }
    single_unit_info.resistances = {}
    for _,attack_type in ipairs(attack_types) do
        single_unit_info.resistances[attack_type] = wesnoth.unit_resistance(unit_proxy, attack_type) / 100.
    end

    -- Time of day modifier (need to be done after traits are extracted)
    if (not single_unit_info.traits.fearless) then
        single_unit_info.tod_mod = FU.get_unit_time_of_day_bonus(unit_cfg.alignment, wesnoth.get_time_of_day().lawful_bonus)
    else
        single_unit_info.tod_mod = 1
    end

    -- Define what "good terrain" means for a unit
    local defense = H.get_child(unit_proxy.__cfg, "defense")

    -- Get the hit chances for all terrains and sort (best = lowest hit chance first)
    local hit_chances = {}
    for _,hit_chance in pairs(defense) do
        table.insert(hit_chances, { hit_chance = math.abs(hit_chance) })
    end
    table.sort(hit_chances, function(a, b) return a.hit_chance < b.hit_chance end)

    -- As "normal" we use the hit chance on "flat equivalent" terrain.
    -- That means on flat for most units, on cave for dwarves etc.
    -- and on shallow water for mermen, nagas etc.
    -- Use the best of those
    local flat_hc = math.min(defense.flat, defense.cave, defense.shallow_water)
    --print('best hit chance on flat, cave, shallow water:', flat_hc)
    --print(defense.flat, defense.cave, defense.shallow_water)

    -- Good terrain is now defined as 10% lesser hit chance than that, except
    -- when this is better than the third best terrain for the unit. An example
    -- are ghosts, which have 50% on all terrains.
    -- I have tested this for most mainline level 1 units and it seems to work pretty well.
    local good_terrain_hit_chance = flat_hc - 10
    if (good_terrain_hit_chance < hit_chances[3].hit_chance) then
        good_terrain_hit_chance = flat_hc
    end
    --print('good_terrain_hit_chance', good_terrain_hit_chance)

    single_unit_info.good_terrain_hit_chance = good_terrain_hit_chance / 100.

    -- This needs to be at the very end, as it needs some of the other
    -- information in single_unit_info as input
    local power = FU.unit_power(single_unit_info)
    single_unit_info.power = power

    return single_unit_info
end

function fred_gamestate_utils.unit_infos()
    -- Wrapper function to fred_gamestate_utils.single_unit_info()
    -- Assembles information for all units on the map, indexed by unit id

    local unit_proxies = wesnoth.get_units()

    local unit_infos = {}
    for _,unit_proxy in ipairs(unit_proxies) do
        unit_infos[unit_proxy.id] = fred_gamestate_utils.single_unit_info(unit_proxy)
    end

    return unit_infos
end

function fred_gamestate_utils.get_gamestate(unit_infos)
    -- Returns:
    --   - State of villages and units on the map (all in one variable: gamestate)
    --   - Reach maps for all the AI's units (in separate variable: reach_maps)
    --   - Private unit copies (in separate variable: unit_copies)
    -- These are returned separately in case only part of it is needed.
    -- They can also be retrieved all in one table using get_gamedata()
    --
    -- See above for the information returned

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
    local my_unit_map, my_unit_map_MP, my_unit_map_noMP, enemy_map = {}, {}, {}, {}
    local my_attack_map, my_move_map = {}, {}
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

        units[unit_copy.id] = { unit_copy.x, unit_copy.y }

        if unit_copy.canrecruit then
            leaders[unit_copy.side] = { unit_copy.x, unit_copy.y, id = unit_copy.id }
        end

        if (unit_copy.side == wesnoth.current.side) then
            if (not my_unit_map[unit_copy.x]) then my_unit_map[unit_copy.x] = {} end
            my_unit_map[unit_copy.x][unit_copy.y] = { id = unit_copy.id }

            my_units[unit_copy.id] = { unit_copy.x, unit_copy.y }

            -- Hexes the unit can reach in additional_turns+1 turns
            local reach = wesnoth.find_reach(unit_copy, { additional_turns = additional_turns })

            reach_maps[unit_copy.id] = {}
            local attack_range = {}
            for _,loc in ipairs(reach) do
                -- reach_map:
                -- Only first-turn moves counts toward reach_maps
                local max_moves = unit_copy.max_moves
                if (loc[3] >= (max_moves * additional_turns)) then
                    if (not reach_maps[id][loc[1]]) then reach_maps[id][loc[1]] = {} end
                    reach_maps[id][loc[1]][loc[2]] = { moves_left = loc[3] - (max_moves * additional_turns) }
                end

                local turns = (additional_turns + 1) - loc[3] / max_moves

                -- attack_range: for attack_map
                local int_turns = math.ceil(turns)

                if (int_turns == 0) then int_turns = 1 end

                if (not my_move_map[int_turns][loc[1]]) then my_move_map[int_turns][loc[1]] = {} end
                if (not my_move_map[int_turns][loc[1]][loc[2]]) then my_move_map[int_turns][loc[1]][loc[2]] = {} end
                if (not my_move_map[int_turns][loc[1]][loc[2]].ids) then my_move_map[int_turns][loc[1]][loc[2]].ids = {} end
                my_move_map[int_turns][loc[1]][loc[2]].units = (my_move_map[int_turns][loc[1]][loc[2]].units or 0) + 1

                local power = unit_infos[id].power
                my_move_map[int_turns][loc[1]][loc[2]].power = (my_move_map[int_turns][loc[1]][loc[2]].power or 0) + power

                table.insert(my_move_map[int_turns][loc[1]][loc[2]].ids, id)


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

            for x,arr in pairs(attack_range) do
                for y,int_turns in pairs(arr) do
                    if (not my_attack_map[int_turns][x]) then my_attack_map[int_turns][x] = {} end
                    if (not my_attack_map[int_turns][x][y]) then my_attack_map[int_turns][x][y] = {} end
                    if (not my_attack_map[int_turns][x][y].ids) then my_attack_map[int_turns][x][y].ids = {} end

                    my_attack_map[int_turns][x][y].units = (my_attack_map[int_turns][x][y].units or 0) + 1

                    local power = unit_infos[id].power
                    my_attack_map[int_turns][x][y].power = (my_attack_map[int_turns][x][y].power or 0) + power

                    if (not my_attack_map[int_turns][x][y].power_no_leader) then
                        my_attack_map[int_turns][x][y].power_no_leader = 0
                    end
                    if (not unit_copy.canrecruit) then
                        my_attack_map[int_turns][x][y].power_no_leader = my_attack_map[int_turns][x][y].power_no_leader + power
                    end

                    table.insert(my_attack_map[int_turns][x][y].ids, id)
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
    for side,leader in ipairs(leaders) do
        if (side == wesnoth.current.side) then
            mapstate.leader_x, mapstate.leader_y = leader[1], leader[2]
        else
            mapstate.enemy_leader_x, mapstate.enemy_leader_y = leader[1], leader[2]
        end
    end

    -- Leader distance maps. These are calculated using wesnoth.find_cost_map() for
    -- each unit type from the position of the leader. This is not ideal, as it is
    -- in the wrong direction (and terrain changes are not symmetric), but it
    -- is good enough for the purpose of finding the best way to the leader
    -- TODO: do this correctly, if needed
    local leader_distance_maps, enemy_leader_distance_maps = {}, {}
    for id,_ in pairs(my_units) do
        local typ = unit_infos[id].type -- can't use type, that's reserved

        -- Do this only once for each unit type; not needed for the leader
        if (not leader_distance_maps[typ]) then
            leader_distance_maps[typ] = {}

            local cost_map = wesnoth.find_cost_map(
                { x = -1 }, -- SUF not matching any unit
                { { mapstate.leader_x, mapstate.leader_y, wesnoth.current.side, typ } },
                { ignore_units = true } -- this is the default, I think, but just in case
            )

            for _,cost in pairs(cost_map) do
                if (cost[3] > -1) then
                    FU.set_fgumap_value(leader_distance_maps[typ], cost[1], cost[2], 'cost', cost[3])
                end
            end

            enemy_leader_distance_maps[typ] = {}

            local cost_map = wesnoth.find_cost_map(
                { x = -1 }, -- SUF not matching any unit
                { { mapstate.enemy_leader_x, mapstate.enemy_leader_y, wesnoth.current.side, typ } },
                { ignore_units = true } -- this is the default, I think, but just in case
            )

            for _,cost in pairs(cost_map) do
                local x, y, c = cost[1], cost[2], cost[3]
                if (cost[3] > -1) then
                    FU.set_fgumap_value(enemy_leader_distance_maps[typ], cost[1], cost[2], 'cost', cost[3])
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
    mapstate.leader_distance_maps = leader_distance_maps
    mapstate.enemy_leader_distance_maps = enemy_leader_distance_maps

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

                local power = unit_infos[enemy_id].power
                enemy_attack_map[int_turns][x][y].power = (enemy_attack_map[int_turns][x][y].power or 0) + power

                table.insert(enemy_attack_map[int_turns][x][y].ids, enemy_id)
            end
        end
    end

    -- Put the own units with MP back out there
    for _,extracted_unit in ipairs(extracted_units) do wesnoth.put_unit(extracted_unit) end

    mapstate.enemy_attack_map = enemy_attack_map
    mapstate.enemy_turn_maps = enemy_turn_maps
    mapstate.trapped_enemies = trapped_enemies

    return mapstate, reach_maps, unit_copies
end

function fred_gamestate_utils.get_gamedata()
    -- Combine all the game data tables into one wrapper table
    -- See above for the information included

    local unit_infos = fred_gamestate_utils.unit_infos()

    local gamedata, reach_maps, unit_copies = fred_gamestate_utils.get_gamestate(unit_infos)

    gamedata.reach_maps = reach_maps
    gamedata.unit_copies = unit_copies
    gamedata.unit_infos = unit_infos
    gamedata.defense_maps = {}

    return gamedata
end

return fred_gamestate_utils
