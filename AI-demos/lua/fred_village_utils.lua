local H = wesnoth.require "lua/helper.lua"
local W = H.set_wml_action_metatable {}
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local FGUI = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_gamestate_utils_incremental.lua"
local FCFG = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_config.lua"
--local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local fred_village_utils = {}

function fred_village_utils.villages_to_protect(zone_cfgs, side_cfgs, move_data)
    local my_start_hex, enemy_start_hex
    for side,cfgs in ipairs(side_cfgs) do
        if (side == wesnoth.current.side) then
            my_start_hex = cfgs.start_hex
        else
            enemy_start_hex = cfgs.start_hex
        end
    end

    -- TODO: this is needed in several places, could be pulled into move_data or something
    local zone_maps = {}
    for zone_id,cfg in pairs(zone_cfgs) do
        zone_maps[zone_id] = {}
        local zone = wesnoth.get_locations(cfg.ops_slf)
        for _,loc in ipairs(zone) do
            FU.set_fgumap_value(zone_maps[zone_id], loc[1], loc[2], 'in_zone', true)
        end
    end

    local villages_to_protect_maps = {}
    for x,y,_ in FU.fgumap_iter(move_data.village_map) do
        local my_distance = H.distance_between(x, y, my_start_hex[1], my_start_hex[2])
        local enemy_distance = H.distance_between(x, y, enemy_start_hex[1], enemy_start_hex[2])

        local village_zone
        for zone_id,_ in pairs(zone_maps) do
            if FU.get_fgumap_value(zone_maps[zone_id], x, y, 'in_zone') then
                village_zone = zone_id
                break
            end
        end
        if (not village_zone) then village_zone = 'other' end

        if (not villages_to_protect_maps[village_zone]) then
            villages_to_protect_maps[village_zone] = {}
        end
        if (my_distance <= enemy_distance) then
            FU.set_fgumap_value(villages_to_protect_maps[village_zone], x, y, 'protect', true)
        else
            FU.set_fgumap_value(villages_to_protect_maps[village_zone], x, y, 'protect', false)
        end
    end

    return villages_to_protect_maps
end


function fred_village_utils.village_goals(villages_to_protect_maps, move_data)
    -- Village goals are those that are:
    --  - on my side of the map
    --  - not owned by me
    -- We set those up as arrays, one for each zone
    --  - if a village is found that is not in a zone, assign it zone 'other'

    local zone_village_goals = {}
    for zone_id, villages in pairs(villages_to_protect_maps) do
        for x,y,village_data in FU.fgumap_iter(villages) do
            local owner = FU.get_fgumap_value(move_data.village_map, x, y, 'owner')

            if (owner ~= wesnoth.current.side) then
                if (not zone_village_goals[zone_id]) then
                    zone_village_goals[zone_id] = {}
                end

                local grab_only = true
                if village_data.protect then
                    grab_only = false
                end

                local threats = FU.get_fgumap_value(move_data.enemy_attack_map[1], x, y, 'ids')

                table.insert(zone_village_goals[zone_id], {
                    x = x, y = y,
                    owner = owner,
                    grab_only = grab_only,
                    threats = threats
                })
            end
        end
    end

    return zone_village_goals
end


function fred_village_utils.protect_locs(villages_to_protect_maps, fred_data)
    -- For now, every village on our side of the map that can be reached
    -- by an enemy needs to be protected

    local protect_locs = {}
    for zone_id,villages in pairs(villages_to_protect_maps) do
        protect_locs[zone_id] = {}
        local max_ld, loc
        for x,y,village_data in FU.fgumap_iter(villages) do
            if village_data.protect then
                for enemy_id,_ in pairs(fred_data.move_data.enemies) do
                    if FU.get_fgumap_value(fred_data.move_data.reach_maps[enemy_id], x, y, 'moves_left') then
                        local ld = FU.get_fgumap_value(fred_data.turn_data.leader_distance_map, x, y, 'distance')
                        if (not max_ld) or (ld > max_ld) then
                            max_ld = ld
                            loc = { x, y }
                        end
                    end
                end
            end
        end

        if max_ld then
            -- In this case, we want both min and max to be the same
            protect_locs[zone_id].leader_distance = {
                min = max_ld,
                max = max_ld
            }
            protect_locs[zone_id].locs = { loc }
        end
    end

    return protect_locs
end


function fred_village_utils.assign_grabbers(zone_village_goals, villages_to_protect_maps, assigned_units, village_actions, fred_data)
    -- assigned_units and village_actions are modified directly in place

    local move_data = fred_data.move_data
    -- Villages that can be reached are dealt with separately from others
    -- Only go over those found above
    local villages_in_reach = { by_village = {}, by_unit = {} }

    for zone_id,villages in pairs(zone_village_goals) do
        for _,village in ipairs(villages) do
            local x, y = village.x, village.y

            local tmp_in_reach = {
                x = x, y = y,
                owner = village.owner, zone_id = zone_id,
                units = {}
            }
            --print(x, y)

            local ids = FU.get_fgumap_value(move_data.my_move_map[1], x, y, 'ids') or {}

            for _,id in pairs(ids) do
                local loc = move_data.my_units[id]
                -- Only include the leader if he's on the keep
                if (not move_data.unit_infos[id].canrecruit)
                    or wesnoth.get_terrain_info(wesnoth.get_terrain(loc[1], loc[2])).keep
                then
                    --print('  ' .. id, loc[1], loc[2])

                    local max_damage, av_damage = 0, 0
                    if village.threats then
                        for _,enemy_id in ipairs(village.threats) do
                            local att = fred_data.turn_data.unit_attacks[id][enemy_id]
                            local damage_taken = att.damage_counter.base_taken

                            -- TODO: this does not take chance_to_hit specials into account
                            local my_hc = 1 - FGUI.get_unit_defense(move_data.unit_copies[id], x, y, move_data.defense_maps)
                            --print('    ' .. enemy_id, damage_taken, my_hc)

                            max_damage = max_damage + damage_taken
                            av_damage = av_damage + damage_taken * my_hc
                        end
                    end
                    --print('  -> ' .. av_damage, max_damage)

                    -- applicable_damage: if this is smaller than the unit's hitpoints, the grabbing is acceptable
                    -- For villages to be protected, we always grab them (i.e. applicable_damage = 0)
                    -- Otherwise, use the mean between average and maximum damage,
                    -- Except for the leader, for which we are much more conservative in both cases.
                    local applicable_damage = 0
                    if (not FU.get_fgumap_value(villages_to_protect_maps, x, y, 'protect')) then
                        applicable_damage = (max_damage + av_damage) / 2
                    end
                    if move_data.unit_infos[id].canrecruit then
                        applicable_damage = max_damage * 2
                    end
                    --print('     ' .. applicable_damage, move_data.unit_infos[id].hitpoints)

                    if (applicable_damage < move_data.unit_infos[id].hitpoints) then
                        table.insert(tmp_in_reach.units, id)

                        -- For this is sufficient to just count how many villages a unit can get to
                        if (not villages_in_reach.by_unit[id]) then
                            villages_in_reach.by_unit[id] = 1
                        else
                            villages_in_reach.by_unit[id] = villages_in_reach.by_unit[id] + 1
                        end
                    end
                end
            end

            if (#tmp_in_reach.units > 0) then
                table.insert(villages_in_reach.by_village, tmp_in_reach)
            end
        end
    end


    -- Now find best villages for those units
    -- This is one where we need to do the full analysis at this layer,
    -- as it determines which units goes into which zone
    local best_captures = {}
    local keep_trying = true
    while keep_trying do
        keep_trying = false

        local max_rating, best_id, best_index
        for i_v,village in ipairs(villages_in_reach.by_village) do
            local base_rating = 1000
            if (village.owner ~= 0) then
                base_rating = base_rating + 1200
            end
            base_rating = base_rating / #village.units

            -- Prefer villages farther back
            local add_rating_village = -2 * FU.get_fgumap_value(fred_data.turn_data.leader_distance_map, village.x, village.y, 'distance')

            for _,id in ipairs(village.units) do
                local unit_rating = base_rating / (villages_in_reach.by_unit[id]^2)

                local ui = move_data.unit_infos[id]

                -- Use most injured unit first (but less important than choice of village)
                -- Don't give an injured bonus for regenerating units
                local add_rating_unit = 0
                if (not ui.abilities.regenerate) then
                    add_rating_unit = add_rating_unit + (ui.max_hitpoints - ui.hitpoints) / ui.max_hitpoints

                    if ui.status.poisoned then
                        local poison_damage = 8
                        if ui.traits.healthy then
                            poison_damage = poison_damage * 0.75
                        end
                        add_rating_unit = add_rating_unit + poison_damage / ui.max_hitpoints
                    end
                end

                if ui.traits.healthy then
                    add_rating_unit = add_rating_unit - 2 / ui.max_hitpoints
                end

                -- And finally, prefer the fastest unit, but at an even lesser level
                add_rating_unit = add_rating_unit + ui.max_moves / 100.

                -- Finally, prefer the leader, if possible, but only in the minor ratings
                if ui.canrecruit then
                    -- Note that add_rating_unit can be negative, but that's okay here
                    add_rating_unit = add_rating_unit * 2
                end

                local total_rating = unit_rating + add_rating_village + add_rating_unit
                --print(id, add_rating_unit, total_rating, ui.canrecruit)

                if (not max_rating) or (total_rating > max_rating) then
                    max_rating = total_rating
                    best_id, best_index = id, i_v
                end
            end
        end

        if best_id then
            table.insert(best_captures, {
                id = best_id ,
                x = villages_in_reach.by_village[best_index].x,
                y = villages_in_reach.by_village[best_index].y,
                zone_id = villages_in_reach.by_village[best_index].zone_id
            })

            -- We also need to delete both this village and unit from the list
            -- before considering the next village/unit
            -- 1. Each unit that could reach this village can reach one village less overall
            for _,id in ipairs(villages_in_reach.by_village[best_index].units) do
                villages_in_reach.by_unit[id] = villages_in_reach.by_unit[id] - 1
            end

            -- 2. Remove theis village
            table.remove(villages_in_reach.by_village, best_index)

            -- 3. Remove this unit
            villages_in_reach.by_unit[best_id] = nil

            -- 4. Remove this unit from all other villages
            for _,village in ipairs(villages_in_reach.by_village) do
                for i = #village.units,1,-1 do
                    if (village.units[i] == best_id) then
                        table.remove(village.units, i)
                    end
                end
            end

            keep_trying = true
        end
    end

    for _,capture in ipairs(best_captures) do
        if (not assigned_units[capture.zone_id]) then
            assigned_units[capture.zone_id] = {}
        end
        assigned_units[capture.zone_id][capture.id] = move_data.units[capture.id]

        -- This currently only works for single-unit actions; can be expanded as needed
        local unit = move_data.my_units[capture.id]
        unit.id = capture.id
        table.insert(village_actions, {
            action = {
                zone_id = capture.zone_id,
                action_str = 'grab_village',
                units = { unit },
                dsts = { { capture.x, capture.y } }
            }
        })
    end
end


function fred_village_utils.assign_scouts(zone_village_goals, assigned_units, retreat_utilities, move_data)
    -- Potential TODOs:
    --  - Add threat assessment for scout routes; it might in fact make sense to use
    --    injured units to scout in unthreatened areas
    --  - Actually assigning scouting actions
    -- Find how many units are needed in each zone for moving toward villages ('exploring')
    local units_needed_villages = {}
    local villages_per_unit = FCFG.get_cfg_parm('villages_per_unit')
    for zone_id,villages in pairs(zone_village_goals) do
        local n_villages = 0
        for _,village in pairs(villages) do
            if (not village.grab_only) then
                n_villages = n_villages + 1
            end
        end

        local n_units = math.ceil(n_villages / villages_per_unit)
        units_needed_villages[zone_id] = n_units
    end

    local units_assigned_villages = {}
    local used_ids = {}
    for zone_id,units in pairs(assigned_units) do
        for id,_ in pairs(units) do
            units_assigned_villages[zone_id] = (units_assigned_villages[zone_id] or 0) + 1
            used_ids[id] = true
        end
    end

    -- Check out what other units to send in this direction
    local scouts = {}
    for zone_id,villages in pairs(zone_village_goals) do
        if (units_needed_villages[zone_id] > (units_assigned_villages[zone_id] or 0)) then
            --print(zone_id)
            scouts[zone_id] = {}
            for _,village in ipairs(villages) do
                if (not village.grab_only) then
                    --print('  ' .. village.x, village.y)
                    for id,loc in pairs(move_data.my_units) do
                        -- The leader is always excluded here, plus any unit that has already been assigned
                        -- TODO: set up an array of unassigned units?
                        if (not move_data.unit_infos[id].canrecruit) and (not used_ids[id]) then
                            local _, cost = wesnoth.find_path(move_data.unit_copies[id], village.x, village.y)
                            cost = cost + move_data.unit_infos[id].max_moves - move_data.unit_infos[id].moves
                            --print('    ' .. id, cost)
                            local _, cost_ign = wesnoth.find_path(move_data.unit_copies[id], village.x, village.y, { ignore_units = true })
                            cost_ign = cost_ign + move_data.unit_infos[id].max_moves - move_data.unit_infos[id].moves

                            local unit_rating = - cost / #villages / move_data.unit_infos[id].max_moves

                            -- Scout utility to compare to retreat utility
                            local int_turns = math.ceil(cost / move_data.unit_infos[id].max_moves)
                            local int_turns_ign = math.ceil(cost_ign / move_data.unit_infos[id].max_moves)
                            local scout_utility = math.sqrt(1 / math.max(1, int_turns - 1))
                            scout_utility = scout_utility * int_turns_ign / int_turns

                            if scouts[zone_id][id] then
                                unit_rating = unit_rating + scouts[zone_id][id].rating
                            end
                            scouts[zone_id][id] = { rating = unit_rating }

                            if (not scouts[zone_id][id].utility) or (scout_utiltiy > scouts[zone_id][id].utility) then
                                scouts[zone_id][id].utility = scout_utility
                            end
                        end
                    end
                end
            end
        end
    end

    local sorted_scouts = {}
    for zone_id,units in pairs(scouts) do
        for id,data in pairs(units) do
            if (data.utility > retreat_utilities[id]) then
                if (not sorted_scouts[zone_id]) then
                    sorted_scouts[zone_id] = {}
                end

                table.insert(sorted_scouts[zone_id], {
                    id = id,
                    rating = data.rating,
                    org_rating = data.rating
                })
            else
                --print('needs to retreat instead:', id)
            end
        end
        if sorted_scouts[zone_id] then
            table.sort(sorted_scouts[zone_id], function(a, b) return a.rating > b.rating end)
        end
    end

    local keep_trying = true
    local zone_id,units = next(sorted_scouts)
    if (not zone_id) or (#units == 0) then
        keep_trying = false
    end

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

        local max_rating, best_id, best_zone
        for zone_id,units in pairs(sorted_scouts) do
            local rating = sorted_scouts[zone_id][1].rating

            if (not max_rating) or (rating > max_rating) then
                max_rating = rating
                best_id = sorted_scouts[zone_id][1].id
                best_zone = zone_id
            end
        end
        --print('best:', best_zone, best_id)

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

        if (not assigned_units[best_zone]) then
            assigned_units[best_zone] = {}
        end
        assigned_units[best_zone][best_id] = move_data.units[best_id]

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
end


return fred_village_utils
