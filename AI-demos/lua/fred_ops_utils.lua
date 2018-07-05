local H = wesnoth.require "helper"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local FGUI = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_gamestate_utils_incremental.lua"
local FAU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack_utils.lua"
local FHU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_hold_utils.lua"
local FRU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_retreat_utils.lua"
local FVU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_village_utils.lua"
local FMLU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_move_leader_utils.lua"
local FCFG = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_config.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

-- Trying to set things up so that FMC is _only_ used in ops_utils
local FMC = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_map_config.lua"

local fred_ops_utils = {}

function fred_ops_utils.replace_zones(assigned_units, assigned_enemies, protect_objectives, actions)
    -- Combine several zones into one, if the conditions for it are met.
    -- For example, on Freelands the 'east' and 'center' zones are combined
    -- into the 'top' zone if enemies are close enough to the leader.
    --
    -- TODO: not sure whether it is better to do this earlier
    -- TODO: set this up to be configurable by the cfgs
    local replace_zone_ids = FMC.replace_zone_ids()
    local raw_cfgs_main = FMC.get_raw_cfgs()
    local raw_cfg_new = FMC.get_raw_cfgs(replace_zone_ids.new)
    --DBG.dbms(replace_zone_ids)
    --DBG.dbms(raw_cfg_new)

    actions.hold_zones = {}
    for zone_id,_ in pairs(raw_cfgs_main) do
        if assigned_units[zone_id] then
            actions.hold_zones[zone_id] = true
        end
    end

    local replace_zones = false
    for _,zone_id in ipairs(replace_zone_ids.old) do
        if assigned_enemies[zone_id] then
            for enemy_id,loc in pairs(assigned_enemies[zone_id]) do
                if wesnoth.match_location(loc[1], loc[2], raw_cfg_new.ops_slf) then
                    replace_zones = true
                    break
                end
            end
        end

        if replace_zones then break end
    end
    --std_print('replace_zones', replace_zones)

    if replace_zones then
        actions.hold_zones[raw_cfg_new.zone_id] = true

        for _,zone_id in ipairs(replace_zone_ids.old) do
            actions.hold_zones[zone_id] = nil
        end

        -- Also combine assigned_units, assigned_enemies, protect_objectives
        -- from the zones to be replaced. We don't actually replace the
        -- respective tables for those zones, just add those for the super zone,
        -- because advancing and some other functions still use the original zones
        assigned_units[raw_cfg_new.zone_id] = {}
        assigned_enemies[raw_cfg_new.zone_id] = {}
        protect_objectives.zones[raw_cfg_new.zone_id] = {
            protect_leader = false,
            units = {},
            villages = {}
        }
        local new_objectives = protect_objectives.zones[raw_cfg_new.zone_id]

        for _,zone_id in ipairs(replace_zone_ids.old) do
            for id,loc in pairs(assigned_units[zone_id] or {}) do
                assigned_units[raw_cfg_new.zone_id][id] = loc
            end
            for id,loc in pairs(assigned_enemies[zone_id] or {}) do
                assigned_enemies[raw_cfg_new.zone_id][id] = loc
            end

            local old_objectives = protect_objectives.zones[zone_id]
            new_objectives.protect_leader = new_objectives.protect_leader or old_objectives.protect_leader
            for _,loc in ipairs(old_objectives.villages) do
                table.insert(new_objectives.villages, loc)
            end
            for _,unit in ipairs(old_objectives.units) do
                table.insert(new_objectives.units, unit)
            end
        end

        table.sort(new_objectives.villages, function(a, b) return a.eld < b.eld end)
        table.sort(new_objectives.units, function(a, b) return a.rating < b.rating end)
    end
end


function fred_ops_utils.zone_power_stats(zones, assigned_units, assigned_enemies, fred_data)
    local zone_power_stats = {}

    for zone_id,_ in pairs(zones) do
        zone_power_stats[zone_id] = {
            my_power = 0,
            enemy_power = 0
        }
    end

    for zone_id,_ in pairs(zones) do
        for id,_ in pairs(assigned_units[zone_id] or {}) do
            local power = FU.unit_base_power(fred_data.move_data.unit_infos[id])
            zone_power_stats[zone_id].my_power = zone_power_stats[zone_id].my_power + power
        end
    end

    for zone_id,enemies in pairs(zones) do
        for id,_ in pairs(assigned_enemies[zone_id] or {}) do
            local power = FU.unit_base_power(fred_data.move_data.unit_infos[id])
            zone_power_stats[zone_id].enemy_power = zone_power_stats[zone_id].enemy_power + power
        end
    end


    local total_ratio_factor = fred_data.turn_data.behavior.orders.base_power_ratio
    if (total_ratio_factor > 1) then
        total_ratio_factor = math.sqrt(total_ratio_factor)
    end
    for zone_id,_ in pairs(zones) do
        -- Note: both power_needed and power_missing take ratio into account, the other values do not
        -- For large ratios in Fred's favor, we also take the square root of it
        local power_needed = zone_power_stats[zone_id].enemy_power * total_ratio_factor
        local power_missing = power_needed - zone_power_stats[zone_id].my_power
        if (power_missing < 0) then power_missing = 0 end
        zone_power_stats[zone_id].power_needed = power_needed
        zone_power_stats[zone_id].power_missing = power_missing
    end

    return zone_power_stats
end


function fred_ops_utils.update_protect_goals(objectives, assigned_units, assigned_enemies, fred_data)
    -- 1. Weigh village vs. leader protecting
    -- 2. Check if you should protect any of the units protecting the protect location.
    -- Generally this will not find anything if a protect action has already taken
    -- place, as the best units will have been chosen for that. This does, however,
    -- trigger in cases such as an attack resulting in the location to be protected
    -- but leaving one of the attackers vulnerable

    -- Get all villages in each zone that are in between all enemies and the
    -- goal location of the leader
    local goal_loc = objectives.leader.village or objectives.leader.keep or fred_data.move_data.leaders[wesnoth.current.side]
    for zone_id,protect_onjective in pairs(objectives.protect.zones) do
        --std_print(zone_id)

        protect_onjective.protect_leader = false
        for enemy_id,enemy_loc in pairs(objectives.leader.leader_threats.enemies) do
            if assigned_enemies[zone_id][enemy_id] then
                protect_onjective.protect_leader = true

                local enemy = {}
                enemy[enemy_id] = enemy_loc
                local between_map = FHU.get_between_map({ goal_loc }, goal_loc, enemy, fred_data.move_data)
                if false then
                    DBG.show_fgumap_with_message(between_map, 'distance', zone_id .. ' between_map: distance', fred_data.move_data.unit_copies[enemy_id])
                end

                for _,village in ipairs(protect_onjective.villages) do
                    local btw_dist = FU.get_fgumap_value(between_map, village.x, village.y, 'distance')
                    local btw_perp_dist = FU.get_fgumap_value(between_map, village.x, village.y, 'perp_distance')

                    local is_between = (btw_dist >= math.abs(btw_perp_dist))
                    --std_print('  ' .. zone_id, enemy_id, village.x .. ',' .. village.y, btw_dist, btw_perp_dist, is_between)

                    if (not is_between) then
                        village.do_not_protect = true
                    end
                end

                -- Now remove those villages
                -- TODO: is there a reason to keep them and check for the flag instead?
                for i = #protect_onjective.villages,1,-1 do
                    if protect_onjective.villages[i].do_not_protect then
                        table.remove(protect_onjective.villages, i)
                    end
                end
            end
        end
    end
    --DBG.dbms(objectives.protect)


    -- Now check whether there are also units that should be protected
    local protect_others_ratio = FCFG.get_cfg_parm('protect_others_ratio')
    for zone_id,protect_onjective in pairs(objectives.protect.zones) do
        --std_print(zone_id)

        protect_onjective.units = {}
        -- TODO: do this also in some cases when the leader needs to be protected?
        if (not protect_onjective.protect_leader)
            and ((#protect_onjective.villages == 0) or (protect_onjective.villages[1].is_protected))
        then
            --std_print('  checking whether units should be protected')
            -- TODO: does this take appreciable time? If so, can be skipped when no no_MP units exist
            local units_to_protect, protectors = {}, {}
            for id,loc in pairs(assigned_units[zone_id]) do

                -- We don't need to consider units that have no MP left and cannot
                -- be attacked by the enemy
                local skip_unit = false
                if (fred_data.move_data.unit_infos[id].moves == 0)
                   and (not FU.get_fgumap_value(fred_data.move_data.enemy_attack_map[1], loc[1], loc[2], 'ids'))
                then
                    skip_unit = true
                end
                --std_print('    ' .. id, skip_unit)

                if (not skip_unit) then
                    local unit_value = FU.unit_value(fred_data.move_data.unit_infos[id])
                    --std_print(string.format('      %-25s    %2d,%2d  %5.2f', id, loc[1], loc[2], unit_value))

                    local tmp_damages = {}
                    for enemy_id,enemy_loc in pairs(assigned_enemies[zone_id]) do
                        local counter = fred_data.turn_data.unit_attacks[id][enemy_id].damage_counter

                        -- For units that have moved, we can use the actual hit_chance
                        -- TODO: we just use the defense here for now, not taking weapon specials into account
                        local enemy_hc
                        if (fred_data.move_data.unit_infos[id].moves == 0) then
                            enemy_hc = 1 - FGUI.get_unit_defense(fred_data.move_data.unit_copies[id], loc[1], loc[2], fred_data.move_data.defense_maps)
                        else
                            enemy_hc = counter.enemy_gen_hc
                        end

                        local dam = (counter.base_taken + counter.extra_taken) * enemy_hc
                        --std_print('    ' .. enemy_id, dam, enemy_hc)
                        table.insert(tmp_damages, { damage = dam })
                    end
                    table.sort(tmp_damages, function(a, b) return a.damage > b.damage end)

                    local sum_damage = 0
                    for i=1,math.min(3, #tmp_damages) do
                        sum_damage = sum_damage + tmp_damages[i].damage
                    end

                    -- Don't let block_utility drop below 0.5, or go above 1,
                    -- otherwise weak units are overrated.
                    -- TODO: this needs to be refined.
                    local block_utility = 0.5 + sum_damage / fred_data.move_data.unit_infos[id].hitpoints / 2
                    if (block_utility > 1) then block_utility = 1 end

                    local protect_rating = unit_value * block_utility
                    --std_print('      ' .. sum_damage, block_utility, protect_rating)

                    if (fred_data.move_data.unit_infos[id].moves == 0) then
                        units_to_protect[id] = protect_rating
                    else
                        protectors[id] = protect_rating
                    end
                end
            end
            --DBG.dbms(units_to_protect, false, zone_id .. ':' .. 'units_to_protect')
            --DBG.dbms(protectors, false, zone_id .. ':' .. 'protectors')

            -- TODO: currently still working with only one protect unit/location
            --   Keeping the option open to use several, otherwise the following could be put into the loop above

            local max_protect_value, protect_id = 0



            for id_protectee,rating_protectee in pairs(units_to_protect) do
                local try_protect = false
                for id_protector,rating_protector in pairs(protectors) do
                    --std_print('    ', id_protectee, rating_protectee, id_protector, rating_protector, protect_others_ratio)
                    if (rating_protector * protect_others_ratio < rating_protectee) then
                        try_protect = true
                        break
                    end
                end

                --std_print(zone_id ..': protect unit: ' .. (id_protectee or 'none'), rating_protectee, try_protect)

                if try_protect then
                    loc = fred_data.move_data.my_units[id_protectee]
                    table.insert(protect_onjective.units, {
                        x = loc[1], y = loc[2],
                        id = id_protectee,
                        is_protected = false,
                        rating = rating_protectee,
                        type = 'unit'
                    })
                end
            end

            table.sort(protect_onjective.units, function(a, b) return a.rating < b.rating end)
        end
    end
    --DBG.dbms(objectives.protect)
end


function fred_ops_utils.behavior_output(is_turn_start, ops_data, fred_data)
    local behavior = fred_data.turn_data.behavior
    local fred_behavior_str = '--- Behavior instructions ---'

    local fred_show_behavior = wml.variables.fred_show_behavior or 1
--fred_show_behavior = 3
    if ((fred_show_behavior > 1) and is_turn_start)
        or (fred_show_behavior > 2)
    then
        local overall_str = 'roughly equal'
        if (behavior.orders.base_power_ratio > FCFG.get_cfg_parm('winning_ratio')) then
            overall_str = 'winning'
        elseif (behavior.orders.base_power_ratio < FCFG.get_cfg_parm('losing_ratio')) then
            overall_str = 'losing'
        end

        fred_behavior_str = fred_behavior_str
            .. string.format('\nBase power ratio : %.3f (%s)', behavior.orders.base_power_ratio, overall_str)
            .. string.format('\n \nvalue_ratio : %.3f', behavior.orders.value_ratio)
        wml.variables.fred_behavior_str = fred_behavior_str

        fred_behavior_str = fred_behavior_str
          .. '\n\n-- Zones --\n  try to protect:'

        for zone_id,zone_data in pairs(ops_data.fronts.zones) do
            local protect_type = zone_data.protect and zone_data.protect.type or '--'
            local x = zone_data.protect and zone_data.protect.x or 0
            local y = zone_data.protect and zone_data.protect.y or 0
            local is_protected = zone_data.protect and zone_data.protect.is_protected

            local comment = ''
            if is_protected then
                comment = '--> try to reinforce'
            end

            fred_behavior_str = fred_behavior_str
              .. string.format('\n    %-8s \t%-8s \t%2d,%2d \tis_protected = %s \t%s',  zone_id, protect_type, x, y, is_protected, comment)
        end

        wesnoth.message('Fred', fred_behavior_str)
        std_print(fred_behavior_str)

        if (fred_show_behavior == 4) then
            for zone_id,front in pairs(ops_data.fronts.zones) do
                local raw_cfg = FMC.get_raw_cfgs(zone_id)
                local zone = wesnoth.get_locations(raw_cfg.ops_slf)

                local front_map = {}
                local mean_x, mean_y, count = 0, 0, 0
                for _,loc in ipairs(zone) do
                    local ld = FU.get_fgumap_value(fred_data.turn_data.leader_distance_map, loc[1], loc[2], 'distance')
                    if (math.abs(ld - front.ld) <= 0.5) then
                        FU.set_fgumap_value(front_map, loc[1], loc[2], 'distance', ld)
                        mean_x, mean_y, count = mean_x + loc[1], mean_y + loc[2], count + 1
                    end
                end
                mean_x, mean_y = math.abs(mean_x / count), math.abs(mean_y / count)
                local str = string.format('Front in zone %s:  forward distance = %.3f, peak vulnerability = %.3f', zone_id, front.ld, front.peak_vuln)

                local tmp_protect = ops_data.fronts.zones[zone_id].protect
                if tmp_protect then
                    wesnoth.wml_actions.item { x = tmp_protect.x, y = tmp_protect.y, halo = "halo/teleport-8.png" }
                end
                    DBG.show_fgumap_with_message(front_map, 'distance', str, { x = mean_x, y = mean_y, no_halo = true })
                if tmp_protect then
                    wesnoth.wml_actions.remove_item { x = tmp_protect.x, y = tmp_protect.y, halo = "halo/teleport-8.png" }
                end
            end
        end
    end
end


function fred_ops_utils.set_turn_data(move_data)
    -- Get the needed cfgs
    local raw_cfgs_main = FMC.get_raw_cfgs()
    local side_cfgs = FMC.get_side_cfgs()

    local leader_distance_map, enemy_leader_distance_maps = FU.get_leader_distance_map(raw_cfgs_main, side_cfgs, move_data)

    if DBG.show_debug('analysis_leader_distance_map') then
        --DBG.show_fgumap_with_message(leader_distance_map, 'my_leader_distance', 'my_leader_distance')
        --DBG.show_fgumap_with_message(leader_distance_map, 'enemy_leader_distance', 'enemy_leader_distance')
        DBG.show_fgumap_with_message(leader_distance_map, 'distance', 'leader_distance_map')
        --DBG.show_fgumap_with_message(enemy_leader_distance_maps['west']['Wolf Rider'], 'cost', 'cost Grunt')
        --DBG.show_fgumap_with_message(enemy_leader_distance_maps['Wolf Rider'], 'cost', 'cost Wolf Rider')
    end


    -- The if statement below is so that debugging works when starting the evaluation in the
    -- middle of the turn.  In normal gameplay, we can just use the existing enemy reach maps,
    -- so that we do not have to double-calculate them.
    local enemy_initial_reach_maps = {}
    if (not next(move_data.my_units_noMP)) then
        --std_print('Using existing enemy move map')
        for enemy_id,_ in pairs(move_data.enemies) do
            enemy_initial_reach_maps[enemy_id] = {}
            for x,y,data in FU.fgumap_iter(move_data.reach_maps[enemy_id]) do
                FU.set_fgumap_value(enemy_initial_reach_maps[enemy_id], x, y, 'moves_left', data.moves_left)
            end
        end
    else
        --std_print('Need to create new enemy move map')
        for enemy_id,_ in pairs(move_data.enemies) do
            enemy_initial_reach_maps[enemy_id] = {}

            local old_moves = move_data.unit_copies[enemy_id].moves
            move_data.unit_copies[enemy_id].moves = move_data.unit_copies[enemy_id].max_moves
            local reach = wesnoth.find_reach(move_data.unit_copies[enemy_id], { ignore_units = true })
            move_data.unit_copies[enemy_id].moves = old_moves

            for _,loc in ipairs(reach) do
                FU.set_fgumap_value(enemy_initial_reach_maps[enemy_id], loc[1], loc[2], 'moves_left', loc[3])
            end
        end
    end

    if DBG.show_debug('analysis_enemy_initial_reach_maps') then
        for enemy_id,_ in pairs(move_data.enemies) do
            DBG.show_fgumap_with_message(enemy_initial_reach_maps[enemy_id], 'moves_left', 'enemy_initial_reach_maps', move_data.unit_copies[enemy_id])
        end
    end


    local leader_derating = FCFG.get_cfg_parm('leader_derating')

    local my_base_power, enemy_base_power = 0, 0
    local my_power, enemy_power = {}, {}
    -- Consider 6 turns total. That covers the full default schedule, but even
    -- for other schedules it probably does not make sense to look farther ahead.
    local n_turns = 6
    for id,_ in pairs(move_data.units) do
        local unit_base_power = FU.unit_base_power(move_data.unit_infos[id])
        local unit_influence = FU.unit_current_power(move_data.unit_infos[id])
        if move_data.unit_infos[id].canrecruit then
            unit_influence = unit_influence * leader_derating
            unit_base_power = unit_base_power * leader_derating
        end

        if (not my_power[0]) then
            my_power[0], enemy_power[0] = 0, 0
        end

        if (move_data.unit_infos[id].side == wesnoth.current.side) then
            my_base_power = my_base_power + unit_base_power
            my_power[0] = my_power[0] + unit_influence
        else
            enemy_base_power = enemy_base_power + unit_base_power
            enemy_power[0] = enemy_power[0] + unit_influence
        end

        local alignment = move_data.unit_infos[id].alignment
        local is_fearless = move_data.unit_infos[id].traits.fearless

        for d_turn = 1,n_turns-1 do
            if (not my_power[d_turn]) then
                my_power[d_turn], enemy_power[d_turn] = 0, 0
            end

            local tod_bonus = FU.get_unit_time_of_day_bonus(alignment, is_fearless, wesnoth.get_time_of_day(wesnoth.current.turn + d_turn).lawful_bonus)
            local tod_mod_ratio = tod_bonus / move_data.unit_infos[id].tod_mod
            --std_print(id, unit_influence, alignment, move_data.unit_infos[id].tod_mod, tod_bonus, tod_mod_ratio)

            if (move_data.unit_infos[id].side == wesnoth.current.side) then
                my_power[d_turn] = my_power[d_turn] + unit_influence * tod_mod_ratio
            else
                enemy_power[d_turn] = enemy_power[d_turn] + unit_influence * tod_mod_ratio
            end
        end
    end
    --DBG.dbms(my_power)
    --DBG.dbms(enemy_power)

    local base_power_ratio = my_base_power / enemy_base_power
    --std_print('base: ', base_power_ratio)

    local power_ratio = {}
    local min_power_ratio, max_power_ratio = math.huge, - math.huge
    for t = 0,n_turns-1 do
        power_ratio[t] = my_power[t] / enemy_power[t]
        --std_print(t, power_ratio[t])

        min_power_ratio = math.min(power_ratio[t], min_power_ratio)
        max_power_ratio = math.max(power_ratio[t], max_power_ratio)
    end
    --DBG.dbms(power_ratio)
    --std_print('min, max:', min_power_ratio, max_power_ratio)

    local power_mult_next_turn = my_power[1] / my_power[0] / (enemy_power[1] / enemy_power[0])

    -- Take fraction of influence ratio change on next turn into account for calculating value_ratio
    local weight = FCFG.get_cfg_parm('next_turn_influence_weight')
    local factor = 1 / (1 + (power_mult_next_turn - 1) * weight)
    --std_print(power_mult_next_turn, weight, factor)

    local base_value_ratio = 1 / FCFG.get_cfg_parm('aggression')
    local max_value_ratio = 1 / FCFG.get_cfg_parm('min_aggression')
    local ratio = factor * enemy_power[0] / my_power[0]
    local value_ratio = ratio * base_value_ratio
    if (value_ratio > max_value_ratio) then
        value_ratio = max_value_ratio
    end

    local behavior = {
        power = {
            base_ratio = base_power_ratio,
            current_ratio = power_ratio[0],
            next_turn_ratio = power_ratio[1],
            min_ratio = min_power_ratio,
            max_ratio = max_power_ratio
        },
        orders = {
            base_value_ratio = base_value_ratio,
            max_value_ratio = max_value_ratio,
            value_ratio = value_ratio,
            base_power_ratio = base_power_ratio
        }
    }


    local n_vill_my, n_vill_enemy, n_vill_unowned, n_vill_total = 0, 0, 0, 0
    for x,y,data in FU.fgumap_iter(move_data.village_map) do
        if (data.owner == 0) then
            n_vill_unowned = n_vill_unowned + 1
        elseif (data.owner == wesnoth.current.side) then
            n_vill_my = n_vill_my + 1
        else
            n_vill_enemy = n_vill_enemy + 1
        end
        n_vill_total = n_vill_total + 1
    end

    behavior.villages = {
        n_my = n_vill_my,
        n_enemy = n_vill_enemy,
        n_unowned = n_vill_unowned,
        n_total = n_vill_total
    }

    --behavior.ratios.assets = n_vill_my / (n_vill_total - n_vill_my + 1e-6)
    --behavior.orders.expansion = behavior.ratios.influence / behavior.ratios.assets

    --DBG.dbms(behavior)

    -- Find the unit-vs-unit ratings
    -- TODO: can functions in attack_utils be used for this?
    -- Extract all AI units
    --   - because no two units on the map can have the same underlying_id
    --   - so that we do not accidentally overwrite a unit
    --   - so that we don't accidentally apply leadership, backstab or the like
    local extracted_units = {}
    for id,loc in pairs(move_data.units) do
        local unit_proxy = wesnoth.get_unit(loc[1], loc[2])
        wesnoth.extract_unit(unit_proxy)
        table.insert(extracted_units, unit_proxy)  -- Not a proxy unit any more at this point
    end

    -- Find the effectiveness of each AI unit vs. each enemy unit
    local attack_locs = FMC.get_attack_test_locs()

    local unit_attacks = {}
    for my_id,_ in pairs(move_data.my_units) do
        --std_print(my_id)
        local tmp_attacks = {}

        local old_x = move_data.unit_copies[my_id].x
        local old_y = move_data.unit_copies[my_id].y
        local my_x, my_y = attack_locs.attacker_loc[1], attack_locs.attacker_loc[2]

        wesnoth.put_unit(move_data.unit_copies[my_id], my_x, my_y)
        local my_proxy = wesnoth.get_unit(my_x, my_y)

        for enemy_id,_ in pairs(move_data.enemies) do
            --std_print('    ' .. enemy_id)

            local old_x_enemy = move_data.unit_copies[enemy_id].x
            local old_y_enemy = move_data.unit_copies[enemy_id].y
            local enemy_x, enemy_y = attack_locs.defender_loc[1], attack_locs.defender_loc[2]

            wesnoth.put_unit(move_data.unit_copies[enemy_id], enemy_x, enemy_y)
            local enemy_proxy = wesnoth.get_unit(enemy_x, enemy_y)

            local bonus_poison = 8
            local bonus_slow = 4
            local bonus_regen = 8

            local max_diff_forward
            for i_w,attack in ipairs(move_data.unit_infos[my_id].attacks) do
                --std_print('attack weapon: ' .. i_w)

                local _, _, my_weapon, enemy_weapon = wesnoth.simulate_combat(my_proxy, i_w, enemy_proxy)
                local _, my_base_damage, my_extra_damage, my_regen_damage
                    = FAU.get_total_damage_attack(my_weapon, attack, true, move_data.unit_infos[enemy_id])

                -- If the enemy has no weapon at this range, attack_num=-1 and enemy_attack
                -- will be nil; this is handled just fine by FAU.get_total_damage_attack
                -- Note: attack_num starts at 0, not 1 !!!!
                --std_print('  enemy weapon: ' .. enemy_weapon.attack_num + 1)
                local enemy_attack = move_data.unit_infos[enemy_id].attacks[enemy_weapon.attack_num + 1]
                local _, enemy_base_damage, enemy_extra_damage, enemy_regen_damage
                    = FAU.get_total_damage_attack(enemy_weapon, enemy_attack, false, move_data.unit_infos[my_id])

                -- TODO: the factor of 2 is somewhat arbitrary and serves to emphasize
                -- the strongest attack weapon. Might be changed later. Use 1/value_ratio?
                local diff = 2 * (my_base_damage + my_extra_damage) - enemy_base_damage - enemy_extra_damage
                --std_print('  ' .. my_base_damage, enemy_base_damage, my_extra_damage, enemy_extra_damage, '-->', diff)

                if (not max_diff_forward) or (diff > max_diff_forward) then
                    max_diff_forward = diff
                    tmp_attacks[enemy_id] = {
                        my_regen = - enemy_regen_damage, -- not that this is (must be) backwards as this is
                        enemy_regen = - my_regen_damage, -- regeneration "damage" to the _opponent_
                        damage_forward = {
                            base_done = my_base_damage,
                            base_taken = enemy_base_damage,
                            extra_done = my_extra_damage,
                            extra_taken = enemy_extra_damage,
                            my_gen_hc = my_weapon.chance_to_hit / 100,
                            enemy_gen_hc = enemy_weapon.chance_to_hit / 100
                        }
                    }
                end
            end
            --DBG.dbms(tmp_attacks[enemy_id])

            local max_diff_counter, max_damage_counter
            for i_w,attack in ipairs(move_data.unit_infos[enemy_id].attacks) do
                --std_print('counter weapon: ' .. i_w)

                local _, _, enemy_weapon, my_weapon = wesnoth.simulate_combat(enemy_proxy, i_w, my_proxy)
                local _, enemy_base_damage, enemy_extra_damage, _
                    = FAU.get_total_damage_attack(enemy_weapon, attack, true, move_data.unit_infos[my_id])

                -- If the AI unit has no weapon at this range, attack_num=-1 and my_attack
                -- will be nil; this is handled just fine by FAU.get_total_damage_attack
                -- Note: attack_num starts at 0, not 1 !!!!
                --std_print('  my weapon: ' .. my_weapon.attack_num + 1)
                local my_attack = move_data.unit_infos[my_id].attacks[my_weapon.attack_num + 1]
                local _, my_base_damage, my_extra_damage, _
                    = FAU.get_total_damage_attack(my_weapon, my_attack, false, move_data.unit_infos[enemy_id])

                -- TODO: the factor of 2 is somewhat arbitrary and serves to emphasize
                -- the strongest attack weapon. Might be changed later. Use 1/value_ratio?
                local diff = 2 * (enemy_base_damage + enemy_extra_damage) - my_base_damage - my_extra_damage
                --std_print('  ' .. enemy_base_damage, my_base_damage, enemy_extra_damage, my_extra_damage, '-->', diff)

                if (not max_diff_counter) or (diff > max_diff_counter) then
                    max_diff_counter = diff
                    tmp_attacks[enemy_id].damage_counter = {
                        base_done = my_base_damage,
                        base_taken = enemy_base_damage,
                        extra_done = my_extra_damage,
                        extra_taken = enemy_extra_damage,
                        my_gen_hc = my_weapon.chance_to_hit / 100,
                        enemy_gen_hc = enemy_weapon.chance_to_hit / 100
                    }
                end

                -- Also add the maximum damage either from any of the enemies weapons
                -- in the counter attack. This is needed, for example, in the retreat
                -- evaluation
                if (not max_damage_counter) or (enemy_base_damage > max_damage_counter) then
                    max_damage_counter = enemy_base_damage
                end

            end
            tmp_attacks[enemy_id].damage_counter.max_taken_any_weapon = max_damage_counter


            move_data.unit_copies[enemy_id] = wesnoth.copy_unit(enemy_proxy)
            wesnoth.erase_unit(enemy_x, enemy_y)
            move_data.unit_copies[enemy_id].x = old_x_enemy
            move_data.unit_copies[enemy_id].y = old_y_enemy
        end

        move_data.unit_copies[my_id] = wesnoth.copy_unit(my_proxy)
        wesnoth.erase_unit(my_x, my_y)
        move_data.unit_copies[my_id].x = old_x
        move_data.unit_copies[my_id].y = old_y

        unit_attacks[my_id] = tmp_attacks
    end

    for _,extracted_unit in ipairs(extracted_units) do wesnoth.put_unit(extracted_unit) end

    --DBG.dbms(unit_attacks)

    local turn_data = {
        turn_number = wesnoth.current.turn,
        leader_distance_map = leader_distance_map,
        enemy_leader_distance_maps = enemy_leader_distance_maps,
        enemy_initial_reach_maps = enemy_initial_reach_maps,
        unit_attacks = unit_attacks,
        behavior = behavior,
        raw_cfgs = FMC.get_raw_cfgs('all'),
        raw_cfgs_main = raw_cfgs_main
    }

    return turn_data
end


function fred_ops_utils.set_ops_data(fred_data)
    -- Get the needed cfgs
    local move_data = fred_data.move_data
    local raw_cfgs_main = FMC.get_raw_cfgs()
    local raw_cfgs_all = FMC.get_raw_cfgs('all')
    local side_cfgs = FMC.get_side_cfgs()


    local villages_to_protect_maps = FVU.villages_to_protect(raw_cfgs_main, side_cfgs, move_data)
    local zone_village_goals = FVU.village_goals(villages_to_protect_maps, move_data)
    --DBG.dbms(zone_village_goals)
    --DBG.dbms(villages_to_protect_maps)

    ----- Get situation on the map first -----

    -- Attributing enemy units to zones
    -- Use base_power for this as it is not only for the current turn
    local assigned_enemies, unassigned_enemies = {}, {}
    for id,loc in pairs(move_data.enemies) do
        if (not move_data.unit_infos[id].canrecruit)
            and (not FU.get_fgumap_value(move_data.reachable_castles_map[move_data.unit_infos[id].side], loc[1], loc[2], 'castle') or false)
        then
            local unit_copy = move_data.unit_copies[id]
            local zone_id = FU.moved_toward_zone(unit_copy, raw_cfgs_main, side_cfgs)

            if (not assigned_enemies[zone_id]) then
                assigned_enemies[zone_id] = {}
            end
            assigned_enemies[zone_id][id] = move_data.units[id]
        else
            unassigned_enemies[id] = move_data.units[id]
        end
    end
    --DBG.dbms(assigned_enemies)
    --DBG.dbms(unassigned_enemies)



    -- TODO: is there a need to keep the following two functions separate?
    local objectives = { leader = FMLU.leader_objectives(fred_data) }
    --DBG.dbms(objectives)
    FMLU.assess_leader_threats(objectives.leader, assigned_enemies, raw_cfgs_main, side_cfgs, fred_data)
    --DBG.dbms(objectives)

    local delayed_actions = {}
    local leader = move_data.leaders[wesnoth.current.side]
    if objectives.leader.village then
        local action = {
            id = leader.id,
            x = objectives.leader.village[1],
            y = objectives.leader.village[2],
            type = 'full_move',
            action_str = 'move_leader_to_village',
            score = FCFG.get_cfg_parm('score_leader_to_village')
        }
        table.insert(delayed_actions, action)
    end

    if objectives.leader.keep then
        local action = {
            id = leader.id,
            x = objectives.leader.keep[1],
            y = objectives.leader.keep[2],
            type = 'partial_move',
            action_str = 'move_leader_to_keep',
            score = FCFG.get_cfg_parm('score_leader_to_keep')
        }
        table.insert(delayed_actions, action)
    end

    if objectives.leader.prerecruit then
        for _,unit in ipairs(objectives.leader.prerecruit.units) do
            local action = {
                recruit_type = unit.recruit_type,
                x = unit.recruit_hex[1],
                y = unit.recruit_hex[2],
                type = 'recruit',
                action_str = 'recruit',
                score = FCFG.get_cfg_parm('score_recruit')
            }
            table.insert(delayed_actions, action)
        end
    end
    table.sort(delayed_actions, function(a, b) return a.score > b.score end)
    --DBG.dbms(delayed_actions)




    local pre_assigned_units = {}
    for id,_ in pairs(move_data.my_units) do
        local unit_copy = move_data.unit_copies[id]
        if (not unit_copy.canrecruit)
            and (not FU.get_fgumap_value(move_data.reachable_castles_map[unit_copy.side], unit_copy.x, unit_copy.y, 'castle') or false)
        then
            local zone_id = FU.moved_toward_zone(unit_copy, raw_cfgs_main, side_cfgs)
            pre_assigned_units[id] =  zone_id
        end
    end
    --DBG.dbms(pre_assigned_units)


    local retreat_utilities = FRU.retreat_utilities(move_data, fred_data.turn_data.behavior.orders.value_ratio)
    --DBG.dbms(retreat_utilities)


    ----- Village goals -----

    local village_actions = {}
    local assigned_units = {}

    FVU.assign_grabbers( zone_village_goals, villages_to_protect_maps, assigned_units, village_actions, fred_data)

    --DBG.dbms(assigned_units)
    FVU.assign_scouts(zone_village_goals, assigned_units, retreat_utilities, move_data)
    --DBG.dbms(village_actions)
    --DBG.dbms(assigned_enemies)

    for _,action in ipairs(village_actions) do
        table.insert(delayed_actions, action)
    end
    table.sort(delayed_actions, function(a, b) return a.score > b.score end)
    --DBG.dbms(delayed_actions)


    -- Finding areas and units for attacking/defending in each zone
    --std_print('Move toward (highest blurred vulnerability):')
    local goal_hexes = {}
    for zone_id,cfg in pairs(raw_cfgs_main) do
        local max_ld, loc
        for x,y,village_data in FU.fgumap_iter(villages_to_protect_maps[zone_id]) do
            if village_data.protect then
                for enemy_id,_ in pairs(move_data.enemies) do
                    if FU.get_fgumap_value(move_data.reach_maps[enemy_id], x, y, 'moves_left') then
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
            --std_print('max protect ld:', zone_id, max_ld, loc[1], loc[2])
            goal_hexes[zone_id] = { loc }
        else
            goal_hexes[zone_id] = cfg.center_hexes
        end
    end
    --DBG.dbms(goal_hexes)

-- TODO: what's this?
    local distance_from_front = {}
    for id,l in pairs(move_data.my_units) do
        --std_print(id, l[1], l[2])
        if (not move_data.unit_infos[id].canrecruit) then
            distance_from_front[id] = {}
            for zone_id,locs in pairs(goal_hexes) do
                --std_print('  ' .. zone_id)
                local min_dist
                for _,loc in ipairs(locs) do
                    local _, cost = wesnoth.find_path(move_data.unit_copies[id], loc[1], loc[2], { ignore_units = true })
                    cost = cost + move_data.unit_infos[id].max_moves - move_data.unit_infos[id].moves
                    --std_print('    ' .. loc[1] .. ',' .. loc[2], cost)

                    if (not min_dist) or (min_dist > cost) then
                        min_dist = cost
                    end
                end
                --std_print('    -> ' .. min_dist, move_data.unit_infos[id].max_moves)
                distance_from_front[id][zone_id] = min_dist / move_data.unit_infos[id].max_moves
            end
        end
    end
    goal_hexes = nil
    --DBG.dbms(distance_from_front)


    local used_ids = {}
    for zone_id,units in pairs(assigned_units) do
        for id,_ in pairs(units) do
            used_ids[id] = true
        end
    end

    local value_ratio = fred_data.turn_data.behavior.orders.value_ratio
    local attacker_ratings = {}
    local max_rating
    for id,_ in pairs(move_data.my_units) do
        if (not move_data.unit_infos[id].canrecruit)
            and (not used_ids[id])
        then
            --std_print(id)
            attacker_ratings[id] = {}
            for zone_id,data in pairs(assigned_enemies) do
                --std_print('  ' .. zone_id)

                local tmp_enemies = {}
                for enemy_id,_ in pairs(data) do
                    --std_print('    ' .. enemy_id)
                    local att = fred_data.turn_data.unit_attacks[id][enemy_id]

                    local damage_taken = att.damage_counter.enemy_gen_hc * att.damage_counter.base_taken + att.damage_counter.extra_taken
                    damage_taken = damage_taken + att.damage_forward.enemy_gen_hc * att.damage_forward.base_taken + att.damage_forward.extra_taken
                    damage_taken = damage_taken / 2

                    local damage_done = att.damage_counter.my_gen_hc * att.damage_counter.base_done + att.damage_counter.extra_done
                    damage_done = damage_done + att.damage_forward.my_gen_hc * att.damage_forward.base_done + att.damage_forward.extra_done
                    damage_done = damage_done / 2

                    local enemy_rating = damage_done / value_ratio - damage_taken
                    table.insert(tmp_enemies, {
                        damage_taken = damage_taken,
                        damage_done = damage_done,
                        enemy_rating = enemy_rating,
                        enemy_id = enemy_id,
                        my_regen = att.my_regen,
                        enemy_regen = att.enemy_regen
                    })
                end

                -- Only keep the 3 strongest enemies (or fewer, if there are not 3)
                -- which means we keep the 3 with the _worst_ rating
                table.sort(tmp_enemies, function(a, b) return a.enemy_rating < b.enemy_rating end)
                local n = math.min(3, #tmp_enemies)
                for i = #tmp_enemies,n+1,-1 do
                    table.remove(tmp_enemies, i)
                end

                if (#tmp_enemies > 0) then
                    local av_damage_taken, av_damage_done = 0, 0
                    local cum_weight, n_enemies = 0, 0
                    for _,enemy in pairs(tmp_enemies) do
                        --std_print('    ' .. enemy.enemy_id)
                        local enemy_weight = FU.unit_base_power(move_data.unit_infos[id])
                        cum_weight = cum_weight + enemy_weight
                        n_enemies = n_enemies + 1

                        --std_print('      taken, done:', enemy.damage_taken, enemy.damage_done)

                        -- For this purpose, we use individual damage, rather than combined
                        local frac_taken = enemy.damage_taken - enemy.my_regen
                        frac_taken = frac_taken / move_data.unit_infos[id].hitpoints
                        --std_print('      frac_taken 1', frac_taken)
                        frac_taken = FU.weight_s(frac_taken, 0.5)
                        --std_print('      frac_taken 2', frac_taken)
                        --if (frac_taken > 1) then frac_taken = 1 end
                        --if (frac_taken < 0) then frac_taken = 0 end
                        av_damage_taken = av_damage_taken + enemy_weight * frac_taken * move_data.unit_infos[id].hitpoints

                        local frac_done = enemy.damage_done - enemy.enemy_regen
                        frac_done = frac_done / move_data.unit_infos[enemy.enemy_id].hitpoints
                        --std_print('      frac_done 1', frac_done)
                        frac_done = FU.weight_s(frac_done, 0.5)
                        --std_print('      frac_done 2', frac_done)
                        --if (frac_done > 1) then frac_done = 1 end
                        --if (frac_done < 0) then frac_done = 0 end
                        av_damage_done = av_damage_done + enemy_weight * frac_done * move_data.unit_infos[enemy.enemy_id].hitpoints

                        --std_print('  ', av_damage_taken, av_damage_done, cum_weight)
                    end

                    --std_print('  cum: ', av_damage_taken, av_damage_done, cum_weight)
                    av_damage_taken = av_damage_taken / cum_weight
                    av_damage_done = av_damage_done / cum_weight
                    --std_print('  av:  ', av_damage_taken, av_damage_done)

                    -- We want the ToD-independent rating here.
                    -- The rounding is going to be off for ToD modifier, but good enough for now
                    --av_damage_taken = av_damage_taken / move_data.unit_infos[id].tod_mod
                    --av_damage_done = av_damage_done / move_data.unit_infos[id].tod_mod
                    --std_print('  av:  ', av_damage_taken, av_damage_done)

                    -- The rating must be positive for the analysis below to work
                    local av_hp_left = move_data.unit_infos[id].hitpoints - av_damage_taken
                    if (av_hp_left < 0) then av_hp_left = 0 end
                    --std_print('    ' .. value_ratio, av_damage_done, av_hp_left)

                    local attacker_rating = av_damage_done / value_ratio + av_hp_left
                    attacker_ratings[id][zone_id] = attacker_rating

                    if (not max_rating) or (attacker_rating > max_rating) then
                        max_rating = attacker_rating
                    end
                    --std_print('  -->', attacker_rating)
                end
            end
        end
    end
    --DBG.dbms(attacker_ratings)


    -- Normalize the ratings
    for id,zone_ratings in pairs(attacker_ratings) do
        for zone_id,rating in pairs(zone_ratings) do
            zone_ratings[zone_id] = zone_ratings[zone_id] / max_rating
        end
    end
    --DBG.dbms(attacker_ratings)

    local unit_ratings = {}
    for id,zone_ratings in pairs(attacker_ratings) do
        --std_print(id)
        unit_ratings[id] = {}

        for zone_id,rating in pairs(zone_ratings) do
            local distance = distance_from_front[id][zone_id]
            if (distance < 1) then distance = 1 end
            local distance_rating = 1 / distance
            --std_print('  ' .. zone_id, distance, distance_rating, rating)

            local unit_rating = rating * distance_rating
            unit_ratings[id][zone_id] = { this_zone = unit_rating }
        end
    end
    --DBG.dbms(unit_ratings)

    for id,zone_ratings in pairs(unit_ratings) do
        for zone_id,ratings in pairs(zone_ratings) do
            local max_other_zone
            for zid2,ratings2 in pairs(zone_ratings) do
                if (zid2 ~= zone_id) then
                    if (not max_other_zone) or (ratings2.this_zone > max_other_zone) then
                        max_other_zone = ratings2.this_zone
                    end
                end
            end

            local total_rating = ratings.this_zone
            if max_other_zone and (total_rating > max_other_zone) then
                total_rating = total_rating / math.sqrt(max_other_zone / total_rating)
            end
            -- TODO: might or might not want to normalize this again
            -- currently don't think it's needed

            unit_ratings[id][zone_id].max_other_zone = max_other_zone
            unit_ratings[id][zone_id].rating = total_rating
        end
    end
    --DBG.dbms(unit_ratings)


    local n_enemies = {}
    for zone_id,enemies in pairs(assigned_enemies) do
        local n = 0
        for _,_ in pairs(enemies) do
            n = n + 1
        end
        n_enemies[zone_id] = n
    end
    --DBG.dbms(n_enemies)

    local zone_power_stats = fred_ops_utils.zone_power_stats(raw_cfgs_main, assigned_units, assigned_enemies, fred_data)
    --DBG.dbms(zone_power_stats)

    local keep_trying = true
    while keep_trying do
        keep_trying = false
        --std_print()

        local n_units = {}
        for zone_id,units in pairs(assigned_units) do
            local n = 0
            for _,_ in pairs(units) do
                n = n + 1
            end
            n_units[zone_id] = n
        end
        --DBG.dbms(n_units)

        local hold_utility = {}
        for zone_id,data in pairs(zone_power_stats) do
            local frac_needed = 0
            if (data.power_needed > 0) then
                frac_needed = data.power_missing / data.power_needed
            end
            --std_print(zone_id, frac_needed, data.power_missing, data.power_needed)
            local utility = math.sqrt(frac_needed)
            hold_utility[zone_id] = utility
        end
        --DBG.dbms(hold_utility)

        local max_rating, best_zone, best_unit
        for zone_id,data in pairs(zone_power_stats) do
            -- Base rating for the zone is the power missing times the ratio of
            -- power missing to power needed
            local ratio = 1
            if (data.power_needed > 0) then
                ratio = data.power_missing / data.power_needed
            end

            local zone_rating = data.power_missing
            --if ((n_units[zone_id] or 0) + 1 >= (n_enemies[zone_id] or 0)) then
            --    zone_rating = zone_rating * math.sqrt(ratio)
            --    std_print('    -- decreasing zone_rating by factor ' .. math.sqrt(ratio), zone_rating)
            --end
            --std_print(zone_id, data.power_missing .. '/' .. data.power_needed .. ' = ' .. ratio, zone_rating)
            --std_print('  zone_rating', zone_rating)

            for id,unit_zone_ratings in pairs(unit_ratings) do
                local unit_rating = 0
                local unit_zone_rating = 1
                if unit_zone_ratings[zone_id] and unit_zone_ratings[zone_id].rating then
                    unit_zone_rating = unit_zone_ratings[zone_id].rating
                    unit_rating = unit_zone_rating * zone_rating
                    --std_print('  ' .. id, unit_zone_rating, zone_rating, unit_rating)
                end

                local inertia = 0
                if pre_assigned_units[id] and (pre_assigned_units[id] == zone_id) then
                    inertia = 0.1 * FU.unit_base_power(move_data.unit_infos[id]) * unit_zone_rating
                end

                unit_rating = unit_rating + inertia

                --std_print('    ' .. zone_id .. ' ' .. id, retreat_utilities[id], hold_utility[zone_id])
                -- TODO: the factor 0.8 is just a placeholder for now, so that
                -- very injured units are not used for holding. This should be
                -- replaced by a more accurate method
                if (retreat_utilities[id] > hold_utility[zone_id] * 0.8) then
                    unit_rating = -1
                end

                if (unit_rating > 0) and ((not max_rating) or (unit_rating > max_rating)) then
                    max_rating = unit_rating
                    best_zone = zone_id
                    best_unit = id
                end
                --std_print('  ' .. id .. '  ' .. move_data.unit_infos[id].hitpoints .. '/' .. move_data.unit_infos[id].max_hitpoints, unit_rating, inertia)
            end
        end

        if best_unit then
            --std_print('--> ' .. best_zone, best_unit, move_data.unit_copies[best_unit].x .. ',' .. move_data.unit_copies[best_unit].y)
            if (not assigned_units[best_zone]) then
                assigned_units[best_zone] = {}
            end
            assigned_units[best_zone][best_unit] = move_data.units[best_unit]

            unit_ratings[best_unit] = nil
            zone_power_stats = fred_ops_utils.zone_power_stats(raw_cfgs_main, assigned_units, assigned_enemies, fred_data)

            --DBG.dbms(assigned_units)
            --DBG.dbms(unit_ratings)
            --DBG.dbms(zone_power_stats)

            if (next(unit_ratings)) then
                keep_trying = true
            end
        end
    end
    pre_assigned_units = nil
    --DBG.dbms(assigned_units)
    --DBG.dbms(zone_power_stats)


    -- All units with non-zero retreat utility are put on the list of possible retreaters
    local retreaters = {}
    for id,_ in pairs(unit_ratings) do
        if (retreat_utilities[id] > 0) then
            retreaters[id] = move_data.units[id]
            unit_ratings[id] = nil
        end
    end
    --DBG.dbms(retreaters)


    -- Everybody left at this time goes on the reserve list
    --DBG.dbms(unit_ratings)
    local reserve_units = {}
    for id,_ in pairs(unit_ratings) do
        reserve_units[id] = true
    end
    attacker_ratings = nil
    unit_ratings = nil

    zone_power_stats = fred_ops_utils.zone_power_stats(raw_cfgs_main, assigned_units, assigned_enemies, fred_data)
    --DBG.dbms(zone_power_stats)
    --DBG.dbms(reserve_units)


    -- There will likely only be units on the reserve list at the very beginning
    -- or maybe when the AI is winning.  So for now, we'll just distribute
    -- them between the zones.
    -- TODO: reconsider later whether this is the best thing to do.
    local total_weight = 0
    for zone_id,cfg in pairs(raw_cfgs_main) do
        --std_print(zone_id, cfg.zone_weight)
        total_weight = total_weight + cfg.zone_weight
    end
    --std_print('total_weight', total_weight)

    local total_ratio_factor = fred_data.turn_data.behavior.orders.base_power_ratio
    if (total_ratio_factor > 1) then
        total_ratio_factor = math.sqrt(total_ratio_factor)
    end

    while next(reserve_units) do
        --std_print('power: assigned / desired --> deficit')
        local max_deficit, best_zone_id
        for zone_id,cfg in pairs(raw_cfgs_main) do
            local desired_power = total_ratio_factor * cfg.zone_weight / total_weight
            local assigned_power = zone_power_stats[zone_id].my_power
            local deficit = desired_power - assigned_power
            --std_print(zone_id, assigned_power .. ' / ' .. desired_power, deficit)

            if (not max_deficit) or (deficit > max_deficit) then
                max_deficit, best_zone_id = deficit, zone_id
            end
        end
        --std_print('most in need: ' .. best_zone_id)

        -- Find the best unit for this zone
        local max_rating, best_id
        for id,_ in pairs(reserve_units) do
            for _,center_hex in ipairs(raw_cfgs_main[best_zone_id].center_hexes) do
                local _, cost = wesnoth.find_path(move_data.unit_copies[id], center_hex[1], center_hex[2], { ignore_units = true })
                local turns = math.ceil(cost / move_data.unit_infos[id].max_moves)

                -- Significant difference in power can override difference in turns to get there
                local power_rating = FU.unit_base_power(move_data.unit_infos[id])
                power_rating = power_rating / 10

                local rating = - turns + power_rating
                --std_print(id, cost, turns, power_rating)
                --std_print('  --> rating: ' .. rating)

                if (not max_rating) or (rating > max_rating) then
                    max_rating, best_id = rating, id
                end
            end
        end
        --std_print('best:', best_zone_id, best_id)
        if (not assigned_units[best_zone_id]) then
            assigned_units[best_zone_id] = {}
        end
        assigned_units[best_zone_id][best_id] = move_data.units[best_id]
        reserve_units[best_id] = nil

        zone_power_stats = fred_ops_utils.zone_power_stats(raw_cfgs_main, assigned_units, assigned_enemies, fred_data)
        --DBG.dbms(zone_power_stats)
    end
    --DBG.dbms(zone_power_stats)

    local zone_maps = {}
    for zone_id,_ in pairs(assigned_units) do
        zone_maps[zone_id] = {}
        local zone = wesnoth.get_locations(raw_cfgs_all[zone_id].ops_slf)
        for _,loc in ipairs(zone) do
            FU.set_fgumap_value(zone_maps[zone_id], loc[1], loc[2], 'flag', true)
        end
    end

    local zone_influence_maps = {}
    for zone_id,zone_map in pairs(zone_maps) do
        local zone_influence_map = {}
        for id,_ in pairs(assigned_units[zone_id]) do
            for x,y,data in FU.fgumap_iter(move_data.unit_influence_maps[id]) do
                if FU.get_fgumap_value(zone_map, x, y, 'flag') then
                    FU.fgumap_add(zone_influence_map, x, y, 'my_influence', data.influence)
                end
            end
        end

        for enemy_id,_ in pairs(assigned_enemies[zone_id] or {}) do
            for x,y,data in FU.fgumap_iter(move_data.unit_influence_maps[enemy_id]) do
                if FU.get_fgumap_value(zone_map, x, y, 'flag') then
                    FU.fgumap_add(zone_influence_map, x, y, 'enemy_influence', data.influence)
                end
            end
        end

        for x,y,data in FU.fgumap_iter(zone_influence_map) do
            data.influence = (data.my_influence or 0) - (data.enemy_influence or 0)
            data.tension = (data.my_influence or 0) + (data.enemy_influence or 0)
            data.vulnerability = data.tension - math.abs(data.influence)
        end

        zone_influence_maps[zone_id] = zone_influence_map

        if DBG.show_debug('analysis_zone_influence_maps') then
            --DBG.show_fgumap_with_message(zone_influence_map, 'my_influence', 'Zone my influence map ' .. zone_id)
            --DBG.show_fgumap_with_message(zone_influence_map, 'enemy_influence', 'Zone enemy influence map ' .. zone_id)
            DBG.show_fgumap_with_message(zone_influence_map, 'influence', 'Zone influence map ' .. zone_id)
            --DBG.show_fgumap_with_message(zone_influence_map, 'tension', 'Zone tension map ' .. zone_id)
            DBG.show_fgumap_with_message(zone_influence_map, 'vulnerability', 'Zone vulnerability map ' .. zone_id)
        end
    end

    ---- Calculate what to protect / where to hold ----
    local protect_obj = { zones = {} }
    for zone_id,village_map in pairs(villages_to_protect_maps) do
        protect_obj.zones[zone_id] = { villages = {} }
        --std_print(zone_id, fronts.zones[zone_id].power_ratio)
        for x,y,_ in FU.fgumap_iter(village_map) do
            local eld_vill = FU.get_fgumap_value(fred_data.turn_data.leader_distance_map, x, y, 'enemy_leader_distance')

            local my_infl = FU.get_fgumap_value(zone_influence_maps[zone_id], x, y, 'my_influence') or 0
            local enemy_infl = FU.get_fgumap_value(zone_influence_maps[zone_id], x, y, 'enemy_influence') or 0
            local infl_ratio = my_infl / (enemy_infl + 1e-6)

            local is_threatened, is_protected = false, true
            for enemy_id,_ in pairs(move_data.enemies) do
                if FU.get_fgumap_value(fred_data.turn_data.enemy_initial_reach_maps[enemy_id], x, y, 'moves_left') then
                    is_threatened = true
                    if FU.get_fgumap_value(move_data.reach_maps[enemy_id], x, y, 'moves_left') then
                        is_protected = false
                    end
                end
            end

            if is_threatened and (infl_ratio >= fred_data.turn_data.behavior.orders.value_ratio) then
                local v = {
                    x = x, y = y,
                    is_protected = is_protected,
                    type = 'village',
                    eld = eld_vill
                }
                table.insert(protect_obj.zones[zone_id].villages, v)
            end
            --std_print(string.format("  %2i,%2i %15.3f %6s %6s", x, y, infl_ratio, is_threatened, is_protected))
        end

        table.sort(protect_obj.zones[zone_id].villages, function(a, b) return a.eld < b.eld end)
    end
    objectives.protect = protect_obj

    fred_ops_utils.update_protect_goals(objectives, assigned_units, assigned_enemies, fred_data)
    --DBG.dbms(objectives)


    fred_ops_utils.replace_zones(assigned_units, assigned_enemies, objectives.protect, delayed_actions)


    -- Calculate where the fronts are in the zones (in leader_distance values)
    -- based on a vulnerability-weighted sum over the zones
    -- Note: assigned_units includes both the old and new zones from replace_zones()
    --   This is intentional, as some actions use the individual, some the combined zones

    local side_cfgs = FMC.get_side_cfgs()
    local my_start_hex, enemy_start_hex
    for side,cfgs in ipairs(side_cfgs) do
        if (side == wesnoth.current.side) then
            my_start_hex = cfgs.start_hex
        else
            enemy_start_hex = cfgs.start_hex
        end
    end
    local my_ld0 = FU.get_fgumap_value(fred_data.turn_data.leader_distance_map, my_start_hex[1], my_start_hex[2], 'distance')
    local enemy_ld0 = FU.get_fgumap_value(fred_data.turn_data.leader_distance_map, enemy_start_hex[1], enemy_start_hex[2], 'distance')

    local fronts = { zones = {} }
    local max_push_utility = 0
    for zone_id,zone_map in pairs(zone_maps) do
        local num, denom = 0, 0
        for x,y,data in FU.fgumap_iter(zone_influence_maps[zone_id]) do
            local ld = FU.get_fgumap_value(fred_data.turn_data.leader_distance_map, x, y, 'distance')
            num = num + data.vulnerability^2 * ld
            denom = denom + data.vulnerability^2
        end
        local ld_front = num / denom
        --std_print(zone_id, ld_max)

        local front_hexes = {}
        for x,y,data in FU.fgumap_iter(zone_influence_maps[zone_id]) do
            local ld = FU.get_fgumap_value(fred_data.turn_data.leader_distance_map, x, y, 'distance')
            if (math.abs(ld - ld_front) <= 0.5) then
                table.insert(front_hexes, { x, y, data.vulnerability })
            end
        end
        table.sort(front_hexes, function(a, b) return a[3] > b[3] end)

        local n_hexes = math.min(5, #front_hexes)
        local peak_vuln = 0
        for i_h=1,n_hexes do
            peak_vuln = peak_vuln + front_hexes[i_h][3]
        end
        peak_vuln = peak_vuln / n_hexes

        local push_utility = peak_vuln * math.sqrt((enemy_ld0 - ld_front) / (enemy_ld0 - my_ld0))

        if (push_utility > max_push_utility) then
            max_push_utility = push_utility
        end

        fronts.zones[zone_id] = {
            ld = ld_front,
            peak_vuln = peak_vuln,
            push_utility = push_utility,
            power_ratio = zone_power_stats[zone_id].my_power / (zone_power_stats[zone_id].enemy_power + 1e-6)
        }
    end
    --std_print('max_push_utility', max_push_utility)

    for _,front in pairs(fronts.zones) do
        front.push_utility = front.push_utility / max_push_utility
    end
    --DBG.dbms(fronts)


    local ops_data = {
        objectives = objectives,
        assigned_enemies = assigned_enemies,
        unassigned_enemies = unassigned_enemies,
        assigned_units = assigned_units,
        retreaters = retreaters,
        fronts = fronts,
        delayed_actions = delayed_actions
    }
    --DBG.dbms(ops_data)
    --DBG.dbms(ops_data.assigned_enemies)
    --DBG.dbms(ops_data.assigned_units)
    --DBG.dbms(ops_data.objectives)


    fred_ops_utils.behavior_output(true, ops_data, fred_data)

    if DBG.show_debug('analysis') then
        local behavior = fred_data.turn_data.behavior
        --std_print('value_ratio: ', behavior.orders.value_ratio)
        --DBG.dbms(behavior.ratios)
        --DBG.dbms(behavior.orders)
        DBG.dbms(fronts)
        --DBG.dbms(behavior)
    end

    return ops_data
end


function fred_ops_utils.update_ops_data(fred_data)
    local ops_data = fred_data.ops_data
    local move_data = fred_data.move_data
    local raw_cfgs_main = FMC.get_raw_cfgs()
    local side_cfgs = FMC.get_side_cfgs()

    -- After each move, we update:
    --  - village grabbers (as a village might have opened, or units be used for attacks)
    --
    -- TODO:
    --  - leader_locs
    --  - prerecruits

    -- Reset the ops_data unit tables. All this does is remove a unit
    -- from the respective lists in case it was killed ina previous action.
    for zone_id,units in pairs(ops_data.assigned_units) do
        for id,_ in pairs(units) do
            ops_data.assigned_units[zone_id][id] = move_data.units[id]
        end
    end
    for zone_id,units in pairs(ops_data.assigned_units) do
        if (not next(units)) then
            ops_data.assigned_units[zone_id] = nil
        end
    end

    for zone_id,enemies in pairs(ops_data.assigned_enemies) do
        for id,_ in pairs(enemies) do
            ops_data.assigned_enemies[zone_id][id] = move_data.units[id]
        end
    end
    for zone_id,enemies in pairs(ops_data.assigned_enemies) do
        if (not next(enemies)) then
            ops_data.assigned_enemies[zone_id] = nil
        end
    end

    if ops_data.leader_threats.enemies then
        for id,_ in pairs(ops_data.leader_threats.enemies) do
            ops_data.leader_threats.enemies[id] = move_data.units[id]
        end
        if (not next(ops_data.leader_threats.enemies)) then
            ops_data.leader_threats.enemies = nil
            ops_data.leader_threats.significant_threat = false
        end
    end


    local villages_to_protect_maps = FVU.villages_to_protect(raw_cfgs_main, side_cfgs, move_data)
    local zone_village_goals = FVU.village_goals(villages_to_protect_maps, move_data)
    --DBG.dbms(zone_village_goals)
    --DBG.dbms(villages_to_protect_maps)

    -- Remove existing village actions that are not possible any more because
    -- 1. the reserved unit has moved
    --     - this includes the possibility of the unit having died when attacking
    -- 2. the reserved unit cannot get to the goal any more
    -- This can happen if the units were used in other actions, moves
    -- to get out of the way for another unit or possibly due to a WML event
    for i_a=#ops_data.actions.villages,1,-1 do
        local valid_action = true
        local action = ops_data.actions.villages[i_a].action
        for i_u,unit in ipairs(action.units) do
            if (not move_data.units[unit.id])
                or (move_data.units[unit.id][1] ~= unit[1]) or (move_data.units[unit.id][2] ~= unit[2])
            then
                --std_print(unit.id .. ' has moved or died')
                valid_action = false
                break
            else
                if (not FU.get_fgumap_value(move_data.reach_maps[unit.id], action.dsts[i_u][1],  action.dsts[i_u][2], 'moves_left')) then
                    --std_print(unit.id .. ' cannot get to village goal any more')
                    valid_action = false
                    break
                end
            end
        end

        if (not valid_action) then
            --std_print('deleting village action:', i_a)
            table.remove(ops_data.actions.villages, i_a)
        end
    end

    local retreat_utilities = FRU.retreat_utilities(move_data, fred_data.turn_data.behavior.orders.value_ratio)
    --DBG.dbms(retreat_utilities)


    local actions = { villages = {} }
    local assigned_units = {}

    FVU.assign_grabbers( zone_village_goals, villages_to_protect_maps, assigned_units, actions.villages, fred_data)
    FVU.assign_scouts(zone_village_goals, assigned_units, retreat_utilities, move_data)
    --DBG.dbms(assigned_units)
    --DBG.dbms(ops_data.assigned_units)
    --DBG.dbms(actions.villages)
    --DBG.dbms(ops_data.actions.villages)

    -- For now, we simply take the new actions and (re)assign the units
    -- accordingly.
    -- TODO: possibly re-run the overall unit assignment evaluation.

    local new_village_action = false
    for _,village_action in ipairs(actions.villages) do
        local action = village_action.action
        local exists_already = false
        for _,ops_village_action in ipairs(ops_data.actions.villages) do
            local ops_action = ops_village_action.action
            if ops_action.dsts[1] and
                (action.dsts[1][1] == ops_action.dsts[1][1]) and (action.dsts[1][2] == ops_action.dsts[1][2])
            then
                exists_already = true
                break
            end
        end

        if (not exists_already) then
            new_village_action = true
        end
    end
    --std_print('new_village_action', new_village_action)

    -- If we found a village action that previously was not there, we
    -- simply use the new village actions, but without reassigning all
    -- the units. This is not ideal, but it does not happen all that
    -- often, so we'll do this for now.
    -- TODO: refine?
    if new_village_action then
        ops_data.actions.villages = actions.villages
    end


    -- Also update the protect locations, as a location might not be threatened
    -- any more
    fred_ops_utils.replace_zones(ops_data.assigned_units, ops_data.assigned_enemies, ops_data.objectives.protect, ops_data.delayed_actions)


    -- Once the leader has no MP left, we reconsider the leader threats
    -- TODO: we might want to handle reassessing leader locs and threats differently
    local leader_proxy = wesnoth.get_unit(move_data.leader_x, move_data.leader_y)
    if (leader_proxy.moves == 0) then
        ops_data.leader_threats.leader_locs = {}
        ops_data.leader_threats.protect_locs = { { leader_proxy.x, leader_proxy.y } }

        FMLU.assess_leader_threats(ops_data.objectives.leader, ops_data.assigned_enemies, raw_cfgs_main, side_cfgs, fred_data)
    end


    fred_ops_utils.update_protect_goals(ops_data.objectives, ops_data.assigned_units, ops_data.assigned_enemies, fred_data, fred_data)
    --DBG.dbms(ops_data.fronts)


    -- Remove prerecruit actions, if the hexes are not available any more
--[[
    for i = #ops_data.prerecruit.units,1,-1 do
        local x, y = ops_data.prerecruit.units[i].recruit_hex[1], ops_data.prerecruit.units[i].recruit_hex[2]
        local id = FU.get_fgumap_value(move_data.my_unit_map, x, y, 'id')
        if id and move_data.my_units_noMP[id] then
            table.remove(ops_data.prerecruit.units, i)
        end
    end
--]]

    fred_ops_utils.behavior_output(false, ops_data, fred_data)
end


function fred_ops_utils.get_action_cfgs(fred_data)
    local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'zone_control'

    local move_data = fred_data.move_data
    local ops_data = fred_data.ops_data
    --DBG.dbms(ops_data)

    -- These are only the raw_cfgs of the 3 main zones
    --local raw_cfgs = FMC.get_raw_cfgs('all')
    --local raw_cfgs_main = FMC.get_raw_cfgs()
    --DBG.dbms(raw_cfgs_main)
    --DBG.dbms(fred_data.analysis)


    fred_data.zone_cfgs = {}

    -- For all of the main zones, find assigned units that have moves left

    -- TODO: this is a place_holder for now, needs to be updated to work with delayed_actions
    ops_data.actions = { hold_zones = {}, villages = {} }

    local holders_by_zone, attackers_by_zone = {}, {}
    for zone_id,_ in pairs(ops_data.actions.hold_zones) do
        if ops_data.assigned_units[zone_id] then
            for id,_ in pairs(ops_data.assigned_units[zone_id]) do
                if move_data.my_units_MP[id] then
                    if (not holders_by_zone[zone_id]) then holders_by_zone[zone_id] = {} end
                    holders_by_zone[zone_id][id] = move_data.units[id]
                end
                if (move_data.unit_copies[id].attacks_left > 0) then
                    local is_attacker = true
                    if move_data.my_units_noMP[id] then
                        is_attacker = false
                        for xa,ya in H.adjacent_tiles(move_data.my_units_noMP[id][1], move_data.my_units_noMP[id][2]) do
                            if FU.get_fgumap_value(move_data.enemy_map, xa, ya, 'id') then
                                is_attacker = true
                                break
                            end
                        end
                    end

                    if is_attacker then
                        if (not attackers_by_zone[zone_id]) then attackers_by_zone[zone_id] = {} end
                        attackers_by_zone[zone_id][id] = move_data.units[id]
                    end
                end
            end
        end
    end

    -- We add the leader as a potential attacker to all zones but only if he's on the keep
    local leader = move_data.leaders[wesnoth.current.side]
    --std_print('leader.id', leader.id)
    if (move_data.unit_copies[leader.id].attacks_left > 0)
       and wesnoth.get_terrain_info(wesnoth.get_terrain(leader[1], leader[2])).keep
    then
        local is_attacker = true
        if move_data.my_units_noMP[leader.id] then
            is_attacker = false
            for xa,ya in H.adjacent_tiles(move_data.my_units_noMP[leader.id][1], move_data.my_units_noMP[leader.id][2]) do
                if FU.get_fgumap_value(move_data.enemy_map, xa, ya, 'id') then
                    is_attacker = true
                    break
                end
            end
        end

        if is_attacker then
            for zone_id,_ in pairs(ops_data.actions.hold_zones) do
                if (not attackers_by_zone[zone_id]) then attackers_by_zone[zone_id] = {} end
                attackers_by_zone[zone_id][leader.id] = move_data.units[leader.id]
            end
        end
    end
    --DBG.dbms(attackers_by_zone)

    -- The following is done to simplify the cfg creation below, because
    -- ops_data.assigned_enemies might contain empty tables for zones
    -- Killed enemies should, in principle be already removed, but since
    -- it's quick and easy, we just do it again.
    local threats_by_zone = {}
    local tmp_enemies = {}
    for zone_id,_ in pairs(ops_data.actions.hold_zones) do
        if ops_data.assigned_enemies[zone_id] then
            for enemy_id,_ in pairs(ops_data.assigned_enemies[zone_id]) do
                if move_data.enemies[enemy_id] then
                    if (not threats_by_zone[zone_id]) then threats_by_zone[zone_id] = {} end
                    threats_by_zone[zone_id][enemy_id] = move_data.units[enemy_id]
                    tmp_enemies[enemy_id] = true
                end
            end
        end
    end

    -- Also add all other enemies to the three main zones
    -- Mostly this will just be the leader and enemies on the keep, so
    -- for the most part, they will be out of reach, but this is important
    -- for late in the game
    local other_enemies = {}
    for enemy_id,loc in pairs(move_data.enemies) do
        if (not tmp_enemies[enemy_id]) then
            other_enemies[enemy_id] = loc
        end
    end
    tmp_enemies = nil
    --DBG.dbms(other_enemies)

    for enemy_id,loc in pairs(other_enemies) do
        for zone_id,_ in pairs(ops_data.actions.hold_zones) do
            if (not threats_by_zone[zone_id]) then threats_by_zone[zone_id] = {} end
            threats_by_zone[zone_id][enemy_id] = loc
        end
    end

    --DBG.dbms(holders_by_zone)
    --DBG.dbms(attackers_by_zone)
    --DBG.dbms(threats_by_zone)

    local leader_threats_by_zone = {}
    for zone_id,threats in pairs(threats_by_zone) do
        for id,loc in pairs(threats) do
            --std_print(zone_id,id)
            if ops_data.objectives.leader.leader_threats.enemies and ops_data.objectives.leader.leader_threats.enemies[id] then
                if (not leader_threats_by_zone[zone_id]) then
                    leader_threats_by_zone[zone_id] = {}
                end
                leader_threats_by_zone[zone_id][id] = loc
            end
        end
    end
    --DBG.dbms(leader_threats_by_zone)

    local zone_power_stats = fred_ops_utils.zone_power_stats(ops_data.actions.hold_zones, ops_data.assigned_units, ops_data.assigned_enemies, fred_data)
    --DBG.dbms(zone_power_stats)


    ----- Leader threat actions -----

    if ops_data.objectives.leader.leader_threats.significant_threat then
        local leader_base_ratings = {
            attack = 35000,
            move_to_keep = 34000,
            recruit = 33000,
            move_to_village = 32000
        }

        local zone_id = 'leader_threat'
        --DBG.dbms(leader)

        -- Attacks -- for the time being, this is always done, and always first
        for zone_id,threats in pairs(leader_threats_by_zone) do
            if attackers_by_zone[zone_id] then
                table.insert(fred_data.zone_cfgs, {
                    zone_id = zone_id,
                    action_type = 'attack',
                    zone_units = attackers_by_zone[zone_id],
                    targets = threats,
                    value_ratio = 0.6, -- more aggressive for direct leader threats, but not too much
                    rating = leader_base_ratings.attack + zone_power_stats[zone_id].power_needed
                })
            end
        end

        -- Full move to next_hop
        --[[
        if ops_data.objectives.leader.leader_threats.leader_locs.next_hop
            and move_data.my_units_MP[leader.id]
            and ((ops_data.objectives.leader.leader_threats.leader_locs.next_hop[1] ~= leader[1]) or (ops_data.objectives.leader.leader_threats.leader_locs.next_hop[2] ~= leader[2]))
        then
            table.insert(fred_data.zone_cfgs, {
                action = {
                    zone_id = zone_id,
                    action_str = zone_id .. ': move leader toward keep',
                    units = { leader },
                    dsts = { ops_data.objectives.leader.leader_threats.leader_locs.next_hop }
                },
                rating = leader_base_ratings.move_to_keep
            })
        end

        -- Partial move to keep
        if ops_data.objectives.leader.leader_threats.leader_locs.closest_keep
            and move_data.my_units_MP[leader.id]
            and ((ops_data.objectives.leader.leader_threats.leader_locs.closest_keep[1] ~= leader[1]) or (ops_data.objectives.leader.leader_threats.leader_locs.closest_keep[2] ~= leader[2]))
        then
            table.insert(fred_data.zone_cfgs, {
                action = {
                    zone_id = zone_id,
                    action_str = zone_id .. ': move leader to keep',
                    units = { leader },
                    dsts = { ops_data.objectives.leader.leader_threats.leader_locs.closest_keep },
                    partial_move = true
                },
                rating = leader_base_ratings.move_to_keep
            })
        end
        --]]

        -- Recruiting
        if ops_data.objectives.leader.prerecruit and ops_data.objectives.leader.prerecruit.units[1] then
            -- TODO: This check should not be necessary, but something can
            -- go wrong occasionally. Will eventually have to check why, for
            -- now I just put in this workaround.
            local current_gold = wesnoth.sides[wesnoth.current.side].gold
            local cost = wesnoth.unit_types[ops_data.objectives.leader.prerecruit.units[1].recruit_type].cost
            if (current_gold >= cost) then
                table.insert(fred_data.zone_cfgs, {
                    action = {
                        zone_id = zone_id,
                        action_str = zone_id .. ': recruit for leader protection',
                        type = 'recruit',
                        recruit_units = ops_data.objectives.leader.prerecruit.units
                    },
                    rating = leader_base_ratings.recruit
                })
            end
        end

        -- If leader injured, full move to village
        -- (this will automatically force more recruiting, if gold/castle hexes left)
        --[[
        if ops_data.leader_threats.leader_locs.closest_village
            and move_data.my_units_MP[leader.id]
            and ((ops_data.leader_threats.leader_locs.closest_village[1] ~= leader[1]) or (ops_data.leader_threats.leader_locs.closest_village[2] ~= leader[2]))
        then
            table.insert(fred_data.zone_cfgs, {
                action = {
                    zone_id = zone_id,
                    action_str = zone_id .. ': move leader to village',
                    units = { leader },
                    dsts = { ops_data.leader_threats.leader_locs.closest_village }
                },
                rating = leader_base_ratings.move_to_village
            })
        end
        --]]
    end

    ----- Village actions -----

    for i,action in ipairs(ops_data.actions.villages) do
        action.rating = 20000 - i
        table.insert(fred_data.zone_cfgs, action)
    end


    ----- Zone actions -----

    local base_ratings = {
        attack = 8000,
        fav_attack = 7000,
        hold = 4000,
        retreat = 2100,
        advance = 2000,
        advance_all = 1000
    }

    -- TODO: might want to do something more complex (e.g using local info) in ops layer
    local value_ratio = fred_data.turn_data.behavior.orders.value_ratio

    for zone_id,zone_units in pairs(holders_by_zone) do
        local power_rating = zone_power_stats[zone_id].power_needed - zone_power_stats[zone_id].my_power / 1000

        if threats_by_zone[zone_id] and attackers_by_zone[zone_id] then
            -- Attack --
            table.insert(fred_data.zone_cfgs,  {
                zone_id = zone_id,
                action_type = 'attack',
                zone_units = attackers_by_zone[zone_id],
                targets = threats_by_zone[zone_id],
                rating = base_ratings.attack + power_rating,
                value_ratio = value_ratio
            })
        end

        if holders_by_zone[zone_id] then
            local protect_leader = false
            if leader_threats_by_zone[zone_id] and next(leader_threats_by_zone[zone_id]) then
                protect_leader = true
            end

            -- Hold --
            table.insert(fred_data.zone_cfgs, {
                zone_id = zone_id,
                action_type = 'hold',
                zone_units = holders_by_zone[zone_id],
                rating = base_ratings.hold + power_rating,
                protect_leader = protect_leader
            })
        end
    end


    -- Retreating is done zone independently
    local retreaters
    if ops_data.retreaters then
        for id,_ in pairs(ops_data.retreaters) do
            if move_data.my_units_MP[id] then
                if (not retreaters) then retreaters = {} end
                retreaters[id] = move_data.units[id]
            end
        end
    end
    --DBG.dbms(retreaters)


    if retreaters then
        table.insert(fred_data.zone_cfgs, {
            zone_id = 'all_map',
            action_type = 'retreat',
            retreaters = retreaters,
            rating = base_ratings.retreat
        })
    end


    -- Advancing is still done in the old zones
    local raw_cfgs_main = FMC.get_raw_cfgs()
    local advancers_by_zone = {}
    for zone_id,_ in pairs(raw_cfgs_main) do
        if ops_data.assigned_units[zone_id] then
            for id,_ in pairs(ops_data.assigned_units[zone_id]) do
                if move_data.my_units_MP[id] then
                    if (not advancers_by_zone[zone_id]) then advancers_by_zone[zone_id] = {} end
                    advancers_by_zone[zone_id][id] = move_data.units[id]
                end
            end
        end
    end
    --DBG.dbms(advancers_by_zone)

    for zone_id,zone_units in pairs(advancers_by_zone) do
        local power_rating = 0
        for id,_ in pairs(zone_units) do
            power_rating = power_rating - FU.unit_base_power(move_data.unit_infos[id])
        end
        power_rating = power_rating / 1000

        -- Advance --
        table.insert(fred_data.zone_cfgs, {
            zone_id = zone_id,
            action_type = 'advance',
            zone_units = advancers_by_zone[zone_id],
            rating = base_ratings.advance + power_rating
        })
    end


    -- Favorable attacks. These are cross-zone
    table.insert(fred_data.zone_cfgs, {
        zone_id = 'all_map',
        action_type = 'attack',
        rating = base_ratings.fav_attack,
        value_ratio = 2.0 * value_ratio -- only very favorable attacks will pass this
    })


    -- TODO: this is a catch all action, that moves all units that were
    -- missed. Ideally, there will be no need for this in the end.
    table.insert(fred_data.zone_cfgs, {
        zone_id = 'all_map',
        action_type = 'advance',
        rating = base_ratings.advance_all
    })

    --DBG.dbms(fred_data.zone_cfgs)

    -- Now sort by the ratings embedded in the cfgs
    table.sort(fred_data.zone_cfgs, function(a, b) return a.rating > b.rating end)

    --DBG.dbms(fred_data.zone_cfgs)
end

return fred_ops_utils
