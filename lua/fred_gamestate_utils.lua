local AH = wesnoth.dofile "~/add-ons/AI-demos/lua/ai_helper.lua"
local H = wesnoth.require "lua/helper.lua"

-- Collection of functions to get information about units and the gamestate and
-- collect them in tables for easy access.  They are expensive, so this should
-- be done as infrequently as possible, but it needs to be redone after each move.
--
-- Unlike fred_gamestate_utils_incremental.lua, these functions are called once
-- and assemble information about all units/villages at once, as likely most of
-- this information will be needed during the move evaluation

local fred_gamestate_utils = {}

function fred_gamestate_utils.single_unit_info(unit)
    -- Collects unit information from proxy unit table @unit into a Lua table
    -- so that it is accessible faster.
    -- Note: Even accessing the directly readable fields of a unit proxy table
    -- is slower than reading from a Lua table; not even talking about unit.__cfg.
    --
    -- Important: this is slow, so it should only be called once at the
    --   beginning of each move, but it does need to be redone after each move
    --
    -- The following fields are added to the table:
    --
    -- Sample output:
    -- {
    --     canrecruit = false,
    --     tod_bonus = 1,
    --     id = "Great Troll-11",
    --     max_hitpoints = 87,
    --     max_experience = 150,
    --     regenerate = true,
    --     hitpoints = 87,
    --     attacks = {
    --                       [1] = {
    --                                     number = 3,
    --                                     type = "impact",
    --                                     name = "hammer",
    --                                     icon = "attacks/hammer-troll.png",
    --                                     range = "melee",
    --                                     damage = 18
    --                                 }
    --                   },
    --     experience = 0,
    --     resistances = {
    --                           blade = 0.8,
    --                           arcane = 1.1,
    --                           pierce = 0.8,
    --                           fire = 1,
    --                           impact = 1,
    --                           cold = 1
    --                       },
    --     cost = 48,
    --     level = 3,
    --     alignment = "chaotic",
    --     side = 1
    -- }

    local unit_cfg = unit.__cfg

    local single_unit_info = {
        id = unit.id,
        canrecruit = unit.canrecruit,
        side = unit.side,

        hitpoints = unit.hitpoints,
        max_hitpoints = unit.max_hitpoints,
        experience = unit.experience,
        max_experience = unit.max_experience,

        alignment = unit_cfg.alignment,
        tod_bonus = AH.get_unit_time_of_day_bonus(unit_cfg.alignment, wesnoth.get_time_of_day().lawful_bonus),
        cost = unit_cfg.cost,
        level = unit_cfg.level
    }

    local abilities = H.get_child(unit.__cfg, "abilities")

    if abilities then
        for _,ability in ipairs(abilities) do
            single_unit_info[ability[1]] = true
        end
    end

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

    local attack_types = { "arcane", "blade", "cold", "fire", "impact", "pierce" }
    single_unit_info.resistances = {}
    for _,attack_type in ipairs(attack_types) do
        single_unit_info.resistances[attack_type] = wesnoth.unit_resistance(unit, attack_type) / 100.
    end

    return single_unit_info
end

function fred_gamestate_utils.unit_infos()
    -- Wrapper function to fred_gamestate_utils.single_unit_info()
    -- Assembles information for all units on the map, indexed by unit id

    local units = wesnoth.get_units()

    local unit_infos = {}
    for _,unit in ipairs(units) do
        unit_infos[unit.id] = fred_gamestate_utils.single_unit_info(unit)
    end

    return unit_infos
end

function fred_gamestate_utils.get_gamestate()
    -- Returns:
    --   - State of villages and units on the map
    --   - Reach maps for all the AI's units
    --   - Copies of all the unit proxy tables (needed for attack calculations)
    --
    -- These are done together (to save calculation time) because we need to
    -- calculate the unit reaches anyway in order to determine whether they can move away.
    -- There is some redundant information here, in order to increase speed when
    -- different types of information are needed
    --
    -- Sample content of mapstate:
    --   village_map[12][2].owner = 1                 -- map of all villages, returning owner side (nil for unowned)
    --   enemy_map[19][21].id = "Bad Orc"             -- map of all enemy units, returning id
    --   my_unit_map_MP[19][4].id = "Vanak"              -- map of all own units that can move away (not just have MP left)
    --   my_unit_map_noMP[24][7].id = "Orcish Grunt-27"  -- map of all own units that cannot move away any more
    --   leaders[1] = { 19, 4 }                   -- locations of leaders of all sides indexed by side number
    --   units['Orcish Grunt-30'] = { 21, 9 }     -- locations of all units indexed by unit id
    --
    -- Sample content of reach_maps:
    --   reach_maps['Vanak'][23][2] = { moves_left = 2 }               -- map of hexes reachable by unit, returning MP left after getting there
    --
    -- Sample content of unit_tables:
    --   unit_copies['Vanak'] = proxy_table

    local mapstate, reach_maps = {}, {}

    -- Villages
    local village_map = {}
    for _,village in ipairs(wesnoth.get_villages()) do
        if (not village_map[village[1]]) then village_map[village[1]] = {} end
        village_map[village[1]][village[2]] = { owner = wesnoth.get_village_owner(village[1], village[2]) }
    end
    mapstate.village_map = village_map

    -- Unit locations and copies
    local units, leaders = {}, {}
    local my_unit_map, my_unit_map_MP, my_unit_map_noMP, enemy_map = {}, {}, {}, {}
    local my_units, my_units_MP, my_units_noMP, enemies = {}, {}, {}, {}
    local unit_copies = {}

    for _,unit in ipairs(wesnoth.get_units()) do
        units[unit.id] = { unit.x, unit.y }

        if unit.canrecruit then
            leaders[unit.side] = { unit.x, unit.y, id = unit.id }
        end

        if (unit.side == wesnoth.current.side) then
            if (not my_unit_map[unit.x]) then my_unit_map[unit.x] = {} end
            my_unit_map[unit.x][unit.y] = { id = unit.id }
            my_units[unit.id] = { unit.x, unit.y }

            local reach = wesnoth.find_reach(unit)

            reach_maps[unit.id] = {}
            for _,r in ipairs(reach) do
                if (not reach_maps[unit.id][r[1]]) then reach_maps[unit.id][r[1]] = {} end
                reach_maps[unit.id][r[1]][r[2]] = { moves_left = r[3] }
            end

            if (#reach > 1) then
                if (not my_unit_map_MP[unit.x]) then my_unit_map_MP[unit.x] = {} end
                my_unit_map_MP[unit.x][unit.y] = { id = unit.id }
                my_units_MP[unit.id] = { unit.x, unit.y }
            else
                if (not my_unit_map_noMP[unit.x]) then my_unit_map_noMP[unit.x] = {} end
                my_unit_map_noMP[unit.x][unit.y] = { id = unit.id }
                my_units_noMP[unit.id] = { unit.x, unit.y }
            end
        else
            if wesnoth.is_enemy(unit.side, wesnoth.current.side) then
                if (not enemy_map[unit.x]) then enemy_map[unit.x] = {} end
                enemy_map[unit.x][unit.y] = { id = unit.id }
                enemies[unit.id] = { unit.x, unit.y }
            end
        end

        unit_copies[unit.id] = wesnoth.copy_unit(unit)
    end

    -- reach_maps: eliminate hexes with other units that cannot move out of the way
    for id,reach_map in pairs(reach_maps) do
        for id_noMP,loc in pairs(my_units_noMP) do
            if (id ~= id_noMP) then
                if reach_map[loc[1]] then reach_map[loc[1]][loc[2]] = nil end
            end
        end
    end

    mapstate.units = units
    mapstate.my_unit_map = my_unit_map
    mapstate.my_unit_map_MP = my_unit_map_MP
    mapstate.my_unit_map_noMP = my_unit_map_noMP
    mapstate.enemy_map = enemy_map
    mapstate.my_units = my_units
    mapstate.my_units_MP = my_units_MP
    mapstate.my_units_noMP = my_units_noMP
    mapstate.enemies = enemies
    mapstate.leaders = leaders

    -- Get enemy attack and reach maps
    -- These are for max MP of enemy units, and with taking all AI units with MP off the map
    local enemy_attack_map = {}

    -- Take all own units with MP left off the map (for enemy pathfinding)
    local extracted_units = {}
    for id,loc in pairs(mapstate.my_units_MP) do
        local unit = wesnoth.get_unit(loc[1], loc[2])
        wesnoth.extract_unit(unit)
        table.insert(extracted_units, unit)
    end

    for enemy_id,loc in pairs(mapstate.enemies) do
        local attack_range = {}

        local old_moves = unit_copies[enemy_id].moves
        unit_copies[enemy_id].moves = unit_copies[enemy_id].max_moves
        local reach = wesnoth.find_reach(unit_copies[enemy_id])
        unit_copies[enemy_id].moves = old_moves

        reach_maps[enemy_id] = {}

        for _,loc in ipairs(reach) do
            if (not reach_maps[enemy_id][loc[1]]) then reach_maps[enemy_id][loc[1]] = {} end
            reach_maps[enemy_id][loc[1]][loc[2]] = { moves_left = loc[3] }

            if (not attack_range[loc[1]]) then attack_range[loc[1]] = {} end
            attack_range[loc[1]][loc[2]] = unit_copies[enemy_id].hitpoints

            for xa,ya in H.adjacent_tiles(loc[1], loc[2]) do
                if (not attack_range[xa]) then attack_range[xa] = {} end
                attack_range[xa][ya] = unit_copies[enemy_id].hitpoints
            end
        end

        for x,arr in pairs(attack_range) do
            for y,hitpoints in pairs(arr) do
                if (not enemy_attack_map[x]) then enemy_attack_map[x] = {} end
                if (not enemy_attack_map[x][y]) then enemy_attack_map[x][y] = {} end

                enemy_attack_map[x][y].units = (enemy_attack_map[x][y].units or 0) + 1
                enemy_attack_map[x][y].hitpoints = (enemy_attack_map[x][y].hitpoints or 0) + hitpoints
                enemy_attack_map[x][y][enemy_id] = true
            end
        end

    end

    -- Put the own units with MP back out there
    for _,unit in ipairs(extracted_units) do wesnoth.put_unit(unit) end

    mapstate.enemy_attack_map = enemy_attack_map

    return mapstate, reach_maps, unit_copies
end

function fred_gamestate_utils.get_gamedata()

    local mapstate, reach_maps, unit_copies = fred_gamestate_utils.get_gamestate()
    local gamedata = {
        unit_infos = fred_gamestate_utils.unit_infos(),
        mapstate = mapstate,
        reach_maps = reach_maps,
        unit_copies = unit_copies,
        defense_maps = {}
    }

    return gamedata
end

return fred_gamestate_utils
