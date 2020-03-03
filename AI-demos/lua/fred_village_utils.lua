local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local FGM = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_map.lua"
local FGUI = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_gamestate_utils_incremental.lua"
local FCFG = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_config.lua"
local FAU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack_utils.lua"
local FBU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_benefits_utilities.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"
local COMP = wesnoth.require "~/add-ons/AI-demos/lua/compatibility.lua"

local fred_village_utils = {}

function fred_village_utils.village_objectives(zone_cfgs, side_cfgs, zone_maps, fred_data)
    local move_data = fred_data.move_data

    local village_objectives, villages_to_grab = { zones = {} }, {}
    for x,y,_ in FGM.iter(move_data.village_map) do
        local village_zone
        -- Note that we iterate over @zone_cfgs here, as @zone_maps can also contain maps for other zones
        for zone_id,_ in pairs(zone_cfgs) do
            if FGM.get_value(zone_maps[zone_id], x, y, 'in_zone') then
                village_zone = zone_id
                break
            end
        end
        if (not village_zone) then village_zone = 'other' end

        local eld_vill = wesnoth.map.distance_between(x, y, fred_data.move_data.enemy_leader_x, fred_data.move_data.enemy_leader_y)

        local my_infl = FGM.get_value(move_data.influence_maps, x, y, 'my_influence') or 0
        local enemy_infl = FGM.get_value(move_data.influence_maps, x, y, 'enemy_influence') or 0
        local infl_ratio = my_infl / (enemy_infl + 1e-6)

        local owner = FGM.get_value(move_data.village_map, x, y, 'owner')

        -- Only add village protect objective if AI units can actually protect it.
        -- Even if the influence is positive there might be an enemy unit on the village.
        if (not FGM.get_value(fred_data.move_data.enemy_map, x, y, 'id'))
            and (infl_ratio >= fred_data.ops_data.behavior.orders.value_ratio)
        then
            local is_threatened = false
            for enemy_id,enemy_loc in pairs(move_data.enemies) do
                if FGM.get_value(move_data.reach_maps[enemy_id], x, y, 'moves_left') then
                    is_threatened = true

                    if (not village_objectives.zones[village_zone]) then
                        village_objectives.zones[village_zone] = { villages = {}, enemies = {} }
                    end

                    village_objectives.zones[village_zone].enemies[enemy_id] = enemy_loc[1] * 1000 + enemy_loc[2]
                end
            end

            if is_threatened then
                -- TODO: this is currently duplicated in the benefits functions
                local raw_benefit = 3
                if (owner ~= wesnoth.current.side) and (owner ~= 0) then
                    raw_benefit = raw_benefit * 2
                end
                local v = {
                    x = x, y = y,
                    type = 'village',
                    eld = eld_vill,
                    raw_benefit = raw_benefit
                }
                table.insert(village_objectives.zones[village_zone].villages, v)
            end
        end

        if (owner ~= wesnoth.current.side) then
            table.insert(villages_to_grab, {
                x = x, y = y,
                owner = owner,
                zone_id = village_zone
            })
        end
    end

    for _,objectives in pairs(village_objectives.zones) do
        table.sort(objectives.villages, function(a, b) return a.eld < b.eld end)
    end

    return village_objectives, villages_to_grab
end


function fred_village_utils.village_grabs(villages_to_grab, reserved_actions, interactions, fred_data)
    local move_data = fred_data.move_data
    local value_ratio = fred_data.ops_data.behavior.orders.value_ratio
    local cfg_attack = { value_ratio = value_ratio }

    -- Units with MP need to be taken off the map, for counter attack calculation
    local extracted_units = {}
    for id,loc in pairs(move_data.my_units_MP) do
        local unit_proxy = COMP.get_unit(loc[1], loc[2])
        COMP.extract_unit(unit_proxy)
        table.insert(extracted_units, unit_proxy)  -- Not a proxy unit any more at this point
    end

    local village_grabs = {}
    for _,village in pairs(villages_to_grab) do
        local x, y = village.x, village.y
        --std_print('village at ' .. x .. ',' .. y)

        -- Exclude reserved locations here (and units below) without checking for
        -- combined unit/hex availability, as we do not want to enter those units
        -- and villages into the pool for grabbable villages
        local penalty_loc = FBU.action_penalty({ { loc = { x, y } } }, reserved_actions, interactions, move_data)
        local ids = {}
        if (penalty_loc == 0) then
            ids = FGM.get_value(move_data.my_move_map[1], x, y, 'eff_reach_ids') or {}
        end

        local influence = FGM.get_value(move_data.influence_maps, x, y, 'full_move_influence') or 0
        local my_number = FGM.get_value(move_data.influence_maps, x, y, 'my_number') or 0
        local enemy_number = FGM.get_value(move_data.influence_maps, x, y, 'enemy_number') or 0
        --std_print('  influence, numbers: ' .. influence, my_number, enemy_number)

        for _,id in pairs(ids) do
            local loc = move_data.my_units[id]

            local penalty_unit = FBU.action_penalty({ { id = id } }, reserved_actions, interactions, move_data)
            if (penalty_unit == 0) then
                local target = {}
                target[id] = { x, y }

                -- TODO: do we take prerecruits into account here already?
                local counter_outcomes = FAU.calc_counter_attack(
                    target, { loc }, { { x, y } }, nil, nil, cfg_attack, move_data, fred_data.move_cache
                )
                --if counter_outcomes then DBG.dbms(counter_outcomes.def_outcome, false, 'counter_outcomes.def_outcome') end

                local allow_grab = true
                local die_chance = 0
                local counter_rating
                if counter_outcomes then
                    die_chance = counter_outcomes.def_outcome.hp_chance[0]
                    counter_rating = counter_outcomes.rating_table.rating
                    local value_loss = counter_outcomes.rating_table.pos_rating + counter_outcomes.rating_table.neg_rating
                    --std_print('  ' .. id, die_chance, value_loss)

                    if move_data.unit_infos[id].canrecruit then
                        local min_hp = move_data.unit_infos[id].max_hitpoints
                        for hp,chance in pairs(counter_outcomes.def_outcome.hp_chance) do
                            --std_print(hp,chance)
                            if (chance > 0) and (hp < min_hp) then
                                min_hp = hp
                            end
                        end
                        if (min_hp < move_data.unit_infos[id].max_hitpoints / 2) then
                            allow_grab = false
                        end
                        --std_print(id, min_hp, move_data.unit_infos[id].max_hitpoints, allow_grab)
                    else
                        local xp_mult = FU.weight_s(move_data.unit_infos[id].experience / move_data.unit_infos[id].max_experience, 0.5)
                        local level = move_data.unit_infos[id].level
                        -- TODO: this equation needs to be tweaked
                        local die_chance_threshold = (0.5 + 0.5 * (1 - value_ratio)) * (1 - xp_mult) / level^2

                        local value_loss_threshold = math.huge

                        if (my_number < 3) and (my_number < enemy_number) and (influence < 0) then
                            --std_print('    *** dangerous village')
                            die_chance_threshold = 0
                            value_loss_threshold = 6
                        end

                        if (die_chance > die_chance_threshold) or (value_loss > value_loss_threshold) then
                            allow_grab = false
                        end
                        --std_print('  ' .. id, value_ratio, xp_mult, level, die_chance_threshold, allow_grab)
                    end
                end

                if allow_grab then
                    local grabber = {
                        x = x, y = y,
                        id = id,
                        die_chance = die_chance,
                        counter_rating = counter_rating,
                        zone_id = village.zone_id
                    }
                    table.insert(village_grabs, grabber)
                end
            end
        end
    end

    -- Put the units back on the map
    for _,extracted_unit in ipairs(extracted_units) do COMP.put_unit(extracted_unit) end

    return village_grabs
end


function fred_village_utils.assign_scouts(villages_to_grab, unused_units, assigned_units, move_data)
    -- Potential TODOs:
    --  - Add threat assessment for scout routes; it might in fact make sense to use
    --    injured units to scout in unthreatened areas
    --  - Actually assigning scouting actions
    -- Find how many units are needed in each zone for moving toward villages ('exploring')
    local units_needed_villages, zone_villages = {}, {}
    local villages_per_unit = FCFG.get_cfg_parm('villages_per_unit')
    for _,village in pairs(villages_to_grab) do
        if (not units_needed_villages[village.zone_id]) then
            units_needed_villages[village.zone_id] = 0
            zone_villages[village.zone_id] = {}
        end
        units_needed_villages[village.zone_id] = units_needed_villages[village.zone_id] + 1 / villages_per_unit
        table.insert(zone_villages[village.zone_id], { x = village.x, y = village.y })
    end
    --DBG.dbms(units_needed_villages, false, 'units_needed_villages')
    --DBG.dbms(zone_villages, false, 'zone_villages')

    local units_assigned_villages = {}
    local used_ids = {}
    for zone_id,units in pairs(assigned_units) do
        for id,_ in pairs(units) do
            units_assigned_villages[zone_id] = (units_assigned_villages[zone_id] or 0) + 1
            used_ids[id] = true
        end
    end
    --DBG.dbms(units_assigned_villages, false, 'units_assigned_villages')


    -- Check out what other units to send in this direction
    local scouts = {}
    for zone_id,units_needed in pairs(units_needed_villages) do
        if (units_needed > (units_assigned_villages[zone_id] or 0)) then
            --std_print(zone_id, units_needed)
            scouts[zone_id] = {}
            for _,village in ipairs(zone_villages[zone_id]) do
                -- TODO: 'grab_only' is currently not set and the 'if' below is always true.
                --   Keep for now anyway, as we might want to reactivate this
                if (not village.grab_only) then
                    --std_print('  ' .. village.x, village.y)
                    for id,_ in pairs(unused_units) do
                        --std_print('  ' .. id)
                        -- The leader is always excluded here, plus any unit that has already been assigned
                        -- TODO: set up an array of unassigned units?
                        if (not move_data.unit_infos[id].canrecruit) and (not used_ids[id]) then
                            local _, cost = wesnoth.find_path(move_data.unit_copies[id], village.x, village.y)
                            cost = cost + move_data.unit_infos[id].max_moves - move_data.unit_infos[id].moves
                            --std_print('    ' .. id, cost)
                            local _, cost_ign = wesnoth.find_path(move_data.unit_copies[id], village.x, village.y, { ignore_units = true })
                            cost_ign = cost_ign + move_data.unit_infos[id].max_moves - move_data.unit_infos[id].moves

                            local unit_rating = - cost / #zone_villages[zone_id] / move_data.unit_infos[id].max_moves

                            --TODO: retreaters are assigned earlier now, but keep code for the time being, just in case
                            --[[
                            -- Scout utility to compare to retreat utility
                            local int_turns = math.ceil(cost / move_data.unit_infos[id].max_moves)
                            local int_turns_ign = math.ceil(cost_ign / move_data.unit_infos[id].max_moves)
                            local scout_utility = math.sqrt(1 / math.max(1, int_turns - 1))
                            scout_utility = scout_utility * int_turns_ign / int_turns
                            --]]

                            if scouts[zone_id][id] then
                                unit_rating = unit_rating + scouts[zone_id][id].rating
                            end
                            scouts[zone_id][id] = { rating = unit_rating }

                            --if (not scouts[zone_id][id].utility) or (scout_utiltiy > scouts[zone_id][id].utility) then
                            --    scouts[zone_id][id].utility = scout_utility
                            --end
                        end
                    end
                end
            end
        end
    end
    --DBG.dbms(scouts, false, 'scouts')

    local sorted_scouts = {}
    for zone_id,units in pairs(scouts) do
        for id,data in pairs(units) do
            --if (data.utility > retreat_utilities[id]) then
                if (not sorted_scouts[zone_id]) then
                    sorted_scouts[zone_id] = {}
                end

                table.insert(sorted_scouts[zone_id], {
                    id = id,
                    rating = data.rating,
                    org_rating = data.rating
                })
            --else
                --std_print('needs to retreat instead:', id)
            --end
        end
        if sorted_scouts[zone_id] then
            table.sort(sorted_scouts[zone_id], function(a, b) return a.rating > b.rating end)
        end
    end
    --DBG.dbms(sorted_scouts, false, 'sorted_scouts')

    local keep_trying = true
    local zone_id,units = next(sorted_scouts)
    if (not zone_id) or (#units == 0) then
        keep_trying = false
    end

    local scout_assignments = {}
    while keep_trying do
        keep_trying = false

        -- Set rating relative to the second highest rating in each zone
        -- This is
        --
        -- Notes:
        --  - If only one units is left, we use the original rating
        --  - This is unnecessary when only one zone is left, but it works then too,
        --    so we'll just keep it rather than adding yet another conditional
        for zone_id,units in pairs(sorted_scouts) do
            if (#units > 1) then
                local second_rating = units[2].rating
                for _,scout in pairs(units) do
                    scout.rating = scout.rating - second_rating
                end
            else
                units[1].rating = units[1].org_rating
            end
        end

        local max_rating, best_id, best_zone = - math.huge
        for zone_id,units in pairs(sorted_scouts) do
            local rating = sorted_scouts[zone_id][1].rating

            if (rating > max_rating) then
                max_rating = rating
                best_id = sorted_scouts[zone_id][1].id
                best_zone = zone_id
            end
        end
        --std_print('best:', best_zone, best_id)

        for zone_id,units in pairs(sorted_scouts) do
            for i_u,data in ipairs(units) do
                if (data.id == best_id) then
                    table.remove(units, i_u)
                    break
                end
            end
        end
        for zone_id,units in pairs(sorted_scouts) do
            if (#units == 0) then
                sorted_scouts[zone_id] = nil
            end
        end

        scout_assignments[best_id] = 'scout:' .. best_zone

        units_assigned_villages[best_zone] = (units_assigned_villages[best_zone] or 0) + 1

        for zone_id,n_needed in pairs(units_needed_villages) do
            if (n_needed <= (units_assigned_villages[zone_id] or 0)) then
                sorted_scouts[zone_id] = nil
            end
        end

        -- Check whether we are done
        local zone_id,units = next(sorted_scouts)
        if zone_id and (#units > 0) then
            keep_trying = true
        end
    end

    return scout_assignments
end


return fred_village_utils
