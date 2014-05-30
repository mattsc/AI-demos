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
    --    canrecruit = false,
    --    cost = 12,
    --    id = "Orcish Grunt-30",
    --    max_hitpoints = 44,
    --    max_experience = 42,
    --    hitpoints = 44,
    --    experience = 0,
    --    resistances = {
    --                          blade = 1,
    --                          arcane = 1,
    --                          pierce = 1,
    --                          fire = 1,
    --                          impact = 1,
    --                          cold = 1
    --                      },
    --    attacks = {
    --                      [1] = {
    --                                    number = 2,
    --                                    type = "blade",
    --                                    name = "sword",
    --                                    icon = "attacks/sword-orcish.png",
    --                                    range = "melee",
    --                                    damage = 10
    --                                }
    --                  },
    --    level = 1,
    --    alignment = "chaotic",
    --    tod_bonus = 0.75,
    --    side = 2
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

    if wesnoth.unit_ability(unit, 'regenerate') then
        single_unit_info.regenerate = true
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

function fred_gamestate_utils.unit_info()
    -- Wrapper function to fred_gamestate_utils.single_unit_info()
    -- Assembles information for all units on the map, indexed by unit id

    local units = wesnoth.get_units()

    local unit_info = {}
    for _,unit in ipairs(units) do
        unit_info[unit.id] = fred_gamestate_utils.single_unit_info(unit)
    end

    return unit_info
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
    --   unit_map_MP[19][4].id = "Vanak"              -- map of all own units that can move away (not just have MP left)
    --   unit_map_noMP[24][7].id = "Orcish Grunt-27"  -- map of all own units that cannot move away any more
    --   leader_locs[1] = { 19, 4 }                   -- locations of leaders of all sides indexed by side number
    --   unit_locs['Orcish Grunt-30'] = { 21, 9 }     -- locations of all units indexed by unit id
    --
    -- Sample content of reachmaps:
    --   reachmaps['Vanak'][23][2] = 2                -- map of hexes reachable by unit, returning MP left after getting there
    --
    -- Sample content of unit_tables:
    --   unit_copies['Vanak'] = proxy_table

    local mapstate, reachmaps = {}, {}

    -- Villages
    local village_map = {}
    for _,village in ipairs(wesnoth.get_villages()) do
        if (not village_map[village[1]]) then village_map[village[1]] = {} end
        village_map[village[1]][village[2]] = { owner = wesnoth.get_village_owner(village[1], village[2]) }
    end
    mapstate.village_map = village_map

    -- Unit locations and copies
    local unit_locs, leader_locs = {}, {}
    local unit_map_MP, unit_map_noMP, enemy_map = {}, {}, {}
    local unit_copies = {}

    for _,unit in ipairs(wesnoth.get_units()) do
        unit_locs[unit.id] = { unit.x, unit.y }

        if unit.canrecruit then
            leader_locs[unit.side] = { unit.x, unit.y }
        end

        if (unit.side == wesnoth.current.side) then
            local reach = wesnoth.find_reach(unit)

            reachmaps[unit.id] = {}
            for _,r in ipairs(reach) do
                if (not reachmaps[unit.id][r[1]]) then reachmaps[unit.id][r[1]] = {} end
                reachmaps[unit.id][r[1]][r[2]] = r[3]
            end

            if (#reach > 1) then
                if (not unit_map_MP[unit.x]) then unit_map_MP[unit.x] = {} end
                unit_map_MP[unit.x][unit.y] = { id = unit.id }
            else
                if (not unit_map_noMP[unit.x]) then unit_map_noMP[unit.x] = {} end
                unit_map_noMP[unit.x][unit.y] = { id = unit.id }
            end
        else
            if (not enemy_map[unit.x]) then enemy_map[unit.x] = {} end
            enemy_map[unit.x][unit.y] = { id = unit.id }
        end

        unit_copies[unit.id] = wesnoth.copy_unit(unit)
    end

    mapstate.unit_locs = unit_locs
    mapstate.unit_map_MP = unit_map_MP
    mapstate.unit_map_noMP = unit_map_noMP
    mapstate.enemy_map = enemy_map
    mapstate.leader_locs = leader_locs

    return mapstate, reachmaps, unit_copies
end

return fred_gamestate_utils
