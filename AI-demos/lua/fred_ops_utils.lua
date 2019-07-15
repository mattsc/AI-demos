local H = wesnoth.require "helper"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local FS = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_status.lua"
local FBU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_benefits_utilities.lua"
local FGM = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_map.lua"
local FGUI = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_gamestate_utils_incremental.lua"
local FAU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack_utils.lua"
local FHU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_hold_utils.lua"
local FRU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_retreat_utils.lua"
local FVS = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_virtual_state.lua"
local FVU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_village_utils.lua"
local FMLU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_move_leader_utils.lua"
local FCFG = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_config.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

-- Trying to set things up so that FMC is _only_ used in ops_utils
-- TODO: this is currently not the case any more. Decide later what to do about that
local FMC = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_map_config.lua"


local function assignments_to_assigned_units(assignments, move_data)
    local assigned_units = {}
    for id,action in pairs(assignments) do
        local i = string.find(action, ':')
        local zone_id = string.sub(action, i + 1)
        --std_print(action, i, zone_id)

        if (not move_data.unit_infos[id].canrecruit) then
            if (not assigned_units[zone_id]) then assigned_units[zone_id] = {} end
            assigned_units[zone_id][id] = move_data.my_units[id][1] * 1000 + move_data.my_units[id][2]
        end
    end

    return assigned_units
end


local fred_ops_utils = {}

function fred_ops_utils.zone_power_stats(zones, assigned_units, assigned_enemies, power_ratio, fred_data)
    local zone_power_stats = {}

    for zone_id,_ in pairs(zones) do
        zone_power_stats[zone_id] = {
            my_power = 0,
            enemy_power = 0,
            n_units = 0
        }
    end

    for zone_id,_ in pairs(zones) do
        for id,_ in pairs(assigned_units[zone_id] or {}) do
            local power = FU.unit_base_power(fred_data.move_data.unit_infos[id])
            zone_power_stats[zone_id].my_power = zone_power_stats[zone_id].my_power + power
            zone_power_stats[zone_id].n_units = zone_power_stats[zone_id].n_units + 1
        end
    end

    for zone_id,_ in pairs(zones) do
        for id,_ in pairs(assigned_enemies[zone_id] or {}) do
            local power = FU.unit_base_power(fred_data.move_data.unit_infos[id])
            zone_power_stats[zone_id].enemy_power = zone_power_stats[zone_id].enemy_power + power
        end
    end

    for zone_id,_ in pairs(zones) do
        -- Note: both power_needed and power_missing take ratio into account, the other values do not
        -- For large ratios in Fred's favor, we also take the square root of it
        local power_needed = zone_power_stats[zone_id].enemy_power * power_ratio
        local power_missing = power_needed - zone_power_stats[zone_id].my_power
        if (power_missing < 0) then power_missing = 0 end
        zone_power_stats[zone_id].power_needed = power_needed
        zone_power_stats[zone_id].power_missing = power_missing

        local fraction_there = zone_power_stats[zone_id].my_power / power_needed
        if (power_needed == 0) then fraction_there = 1 end
        zone_power_stats[zone_id].urgency = FU.urgency(fraction_there, zone_power_stats[zone_id].n_units)
    end

    return zone_power_stats
end


function fred_ops_utils.update_protect_goals(objectives, assigned_units, assigned_enemies, fred_data)
    -- Check whether there are also units that should be protected
    local protect_others_ratio = FCFG.get_cfg_parm('protect_others_ratio')
    for zone_id,protect_objective in pairs(objectives.protect.zones) do
        --std_print(zone_id)

        protect_objective.units = {}
        -- TODO: comment out the conditional for now. It should be determined in the
        -- analysis part of the code whether a unit should be protected, here we just want
        -- to find all the possibilities. Reevaluate later if this should be changed.
        --if (not protect_objective.protect_leader)
        --    and ((#protect_objective.villages == 0) or (protect_objective.villages[1].is_protectedxxx))
        --then
            --std_print('  checking whether units should be protected: ' .. zone_id)
            -- TODO: does this take appreciable time? If so, can be skipped when no no_MP units exist
            local units_to_protect, protectors = {}, {}
            for id,_ in pairs(assigned_units[zone_id] or {}) do
                local loc = fred_data.move_data.units[id]

                -- We don't need to consider units that have no MP left and cannot
                -- be attacked by the enemy
                local skip_unit = false
                if (fred_data.move_data.unit_infos[id].moves == 0)
                   and (not FGM.get_value(fred_data.move_data.enemy_attack_map[1], loc[1], loc[2], 'ids'))
                then
                    skip_unit = true
                end
                --std_print('    ' .. id, skip_unit)

                if (not skip_unit) then
                    local unit_value = FU.unit_value(fred_data.move_data.unit_infos[id])
                    --std_print(string.format('      %-25s    %2d,%2d  %5.2f', id, loc[1], loc[2], unit_value))

                    local tmp_damages = {}
                    for enemy_id,enemy_loc in pairs(assigned_enemies[zone_id] or {}) do
                        local counter = fred_data.ops_data.unit_attacks[id][enemy_id].damage_counter

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
                    table.insert(protect_objective.units, {
                        x = loc[1], y = loc[2],
                        id = id_protectee,
                        rating = rating_protectee,
                        type = 'unit'
                    })
                end
            end

            table.sort(protect_objective.units, function(a, b) return a.rating < b.rating end)
        --end
    end
    --DBG.dbms(objectives.protect, false, 'objectives.protect')
end


function fred_ops_utils.behavior_output(is_turn_start, zone_maps, ops_data)
    local behavior = ops_data.behavior
    local objectives = ops_data.objectives
    local fred_show_behavior = wml.variables.fred_show_behavior or DBG.show_debug('show_behavior')

    local str = 'Mid'
    if is_turn_start then
        str = 'Beginning/Reload'
    end
    local fred_behavior_str = '--- Behavior Instructions ' .. str .. ' Turn ' .. wesnoth.current.turn .. '---'

    local zone_strs = {}
    local overall_str = 'roughly equal'
    if (behavior.orders.base_power_ratio > FCFG.get_cfg_parm('winning_ratio')) then
        overall_str = 'winning'
    elseif (behavior.orders.base_power_ratio < FCFG.get_cfg_parm('losing_ratio')) then
        overall_str = 'losing'
    end

    fred_behavior_str = fred_behavior_str
        .. string.format('\nbase power ratio : %.3f (%s)', behavior.orders.base_power_ratio, overall_str)
        .. string.format('\nvalue_ratio : %.3f   (inverse: %.3f)', behavior.orders.value_ratio, 1/behavior.orders.value_ratio)
        .. string.format('\npush factors :  overall:  %.3f', behavior.orders.push_factor)

    for zone_id,push_factor in pairs(behavior.zone_push_factors) do
        fred_behavior_str = fred_behavior_str .. string.format('\n    %s : %.3f', zone_id, push_factor)
    end

    fred_behavior_str = fred_behavior_str .. '\nleader:'
    fred_behavior_str = fred_behavior_str .. '\n    dorecruit:    ' .. tostring(objectives.leader.do_recruit)
    fred_behavior_str = fred_behavior_str .. '\n    significant threat:    ' .. tostring(objectives.leader.leader_threats.significant_threat)
    if objectives.leader.keep then
        fred_behavior_str = fred_behavior_str .. '\n    go to keep:    ' .. objectives.leader.keep[1] .. ',' .. objectives.leader.keep[2]
    end
    if objectives.leader.village then
        fred_behavior_str = fred_behavior_str .. '\n    go to village:    ' .. objectives.leader.village[1] .. ',' .. objectives.leader.village[2]
    end

    for zone_id,_ in pairs(zone_maps) do
        local zone_data = objectives.protect.zones[zone_id] or { villages = {}, units = {} }
        local zone_str = ''
        if zone_data.protect_leader or (#zone_data.villages > 0) or (#zone_data.units > 0) then
            fred_behavior_str = fred_behavior_str .. '\n' .. zone_id .. ':'
        end
        if zone_data.protect_leader then
            zone_str = zone_str .. '\n    protect leader:    true'
        end
        if (#zone_data.villages > 0) then
            zone_str = zone_str .. '\n    protect villages:  '
        end
        for _,village in ipairs(zone_data.villages) do
            zone_str = zone_str .. '  ' .. village.x .. ',' .. village.y
        end
        if (#zone_data.units > 0) then
            zone_str = zone_str .. '\n    protect units:  '
        end
        for _,unit in ipairs(zone_data.units) do
            zone_str = zone_str .. '  ' .. unit.x .. ',' .. unit.y
        end
        fred_behavior_str = fred_behavior_str ..  zone_str
        zone_strs[zone_id] = zone_str
    end


    if (is_turn_start and (fred_show_behavior == 2)) then
        wesnoth.message('Fred', fred_behavior_str)
        std_print(fred_behavior_str)
    end

    if (fred_show_behavior == 3) or (fred_show_behavior == 5) then
        wesnoth.message('Fred', fred_behavior_str)
        std_print(fred_behavior_str)
    end

    if (fred_show_behavior >= 4) then
       for zone_id,zone_map in pairs(zone_maps) do
           local front = ops_data.fronts.zones[zone_id]
           local front_map = {}
           local str = 'No active front in zone ' .. zone_id
           if front then
               for x,y,_ in FGM.iter(zone_map) do
                   local ld = FGM.get_value(ops_data.leader_distance_map, x, y, 'distance')
                   if (math.abs(ld - front.ld) <= 0.5) then
                       FGM.set_value(front_map, x, y, 'distance', ld)
                   end
               end

               local zone_str = zone_strs[zone_id] or ''
               str = string.format('front in zone %s: %d,%d   (white marker)'
                   .. '\nprotect:    (red halo: units,  blue halo: villages)%s',
                   zone_id, front.x, front.y, zone_str
               )
            end

            local tmp_protect = front and front.protect
            if tmp_protect then
                wesnoth.wml_actions.item { x = tmp_protect.x, y = tmp_protect.y, halo = "halo/teleport-8.png" }
            end

            local zone_data = objectives.protect.zones[zone_id] or { villages = {}, units = {} }
            for _,village in ipairs(zone_data.villages) do
                wesnoth.wml_actions.item { x = village.x, y = village.y, halo = "halo/illuminates-aura.png~CS(-255,-255,0)" }
            end
            for _,unit in ipairs(zone_data.units) do
                wesnoth.wml_actions.item { x = unit.x, y = unit.y, halo = "halo/illuminates-aura.png~CS(0,-255,-255)" }
            end
            DBG.show_fgumap_with_message(front_map, 'distance', str,
                { x = (front and front.x), y = (front and front.y) }
            )
            for _,unit in ipairs(zone_data.units) do
                wesnoth.wml_actions.remove_item { x = unit.x, y = unit.y, halo = "halo/illuminates-aura.png~CS(0,-255,-255)" }
            end
            for _,village in ipairs(zone_data.villages) do
                wesnoth.wml_actions.remove_item { x = village.x, y = village.y, halo = "halo/illuminates-aura.png~CS(-255,-255,0)" }
            end
            if tmp_protect then
                wesnoth.wml_actions.remove_item { x = tmp_protect.x, y = tmp_protect.y, halo = "halo/teleport-8.png" }
            end
        end
    end

    if is_turn_start then
        wml.variables.fred_behavior_str = fred_behavior_str
    end

    return fred_behavior_str
end


function fred_ops_utils.find_fronts(zone_maps, zone_influence_maps, fred_data)
    -- Calculate where the fronts are in the zones (in leader_distance values)
    -- based on a vulnerability-weighted sum over the zones
    --
    -- @zone_influence_maps: if given, use the previously calculated zone_influence_maps,
    --   otherwise use the overall influence map. This is done because (approximate) fronts
    --   are also needed before zone_influence_maps are known.

    local side_cfgs = FMC.get_side_cfgs()
    local my_start_hex, enemy_start_hex
    for side,cfgs in ipairs(side_cfgs) do
        if (side == wesnoth.current.side) then
            my_start_hex = cfgs.start_hex
        else
            enemy_start_hex = cfgs.start_hex
        end
    end

    -- leader_distance_map should be set with respect to the final leader location.
    -- However, fronts are needed at times when this information does not exist yet.
    -- Use the AI side's start_hex in that case.
    local leader_distance_map = fred_data.ops_data.leader_distance_map
    if (not leader_distance_map) then
        leader_distance_map = FU.get_leader_distance_map(my_start_hex, side_cfgs)
    end

    local my_ld0 = FGM.get_value(leader_distance_map, my_start_hex[1], my_start_hex[2], 'distance')
    local enemy_ld0 = FGM.get_value(leader_distance_map, enemy_start_hex[1], enemy_start_hex[2], 'distance')

    local fronts = { zones = {} }
    for zone_id,zone_map in pairs(zone_maps) do
        local num, denom = 0, 0
        local influence_map = zone_influence_maps and zone_influence_maps[zone_id] or fred_data.move_data.influence_maps
        for x,y,data in FGM.iter(zone_map) do
            local ld = FGM.get_value(leader_distance_map, x, y, 'distance')
            local vulnerability = FGM.get_value(influence_map, x, y, 'vulnerability') or 0
            num = num + vulnerability^2 * ld
            denom = denom + vulnerability^2
        end

        if (denom > 0) then
            local ld_front = num / denom
            --std_print(zone_id, ld_front)

            local front_hexes = {}
            for x,y,data in FGM.iter(zone_map) do
                local ld = FGM.get_value(leader_distance_map, x, y, 'distance')
                if (math.abs(ld - ld_front) <= 0.5) then
                    local vulnerability = FGM.get_value(influence_map, x, y, 'vulnerability') or 0
                    table.insert(front_hexes, { x, y, vulnerability })
                end
            end
            table.sort(front_hexes, function(a, b) return a[3] > b[3] end)

            local x_front, y_front, weight = 0, 0, 0
            for _,hex in ipairs(front_hexes) do
                x_front = x_front + hex[1] * hex[3]^2
                y_front = y_front + hex[2] * hex[3]^2
                weight = weight + hex[3]^2
            end
            x_front, y_front = H.round(x_front / weight), H.round(y_front / weight)

            local n_hexes = math.min(5, #front_hexes)

            fronts.zones[zone_id] = {
                ld = ld_front,
                x = x_front,
                y = y_front
            }
        end
    end

    return fronts
end


function fred_ops_utils.set_turn_data(fred_data)
    -- The if statement below is so that debugging works when starting the evaluation in the
    -- middle of the turn.  In normal gameplay, we can just use the existing enemy reach maps,
    -- so that we do not have to double-calculate them.
    local move_data = fred_data.move_data
    local enemy_initial_reach_maps = {}
    if (not next(move_data.my_units_noMP)) then
        --std_print('Using existing enemy move map')
        for enemy_id,_ in pairs(move_data.enemies) do
            enemy_initial_reach_maps[enemy_id] = {}
            for x,y,data in FGM.iter(move_data.reach_maps[enemy_id]) do
                FGM.set_value(enemy_initial_reach_maps[enemy_id], x, y, 'moves_left', data.moves_left)
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
                FGM.set_value(enemy_initial_reach_maps[enemy_id], loc[1], loc[2], 'moves_left', loc[3])
            end
        end
    end

    if DBG.show_debug('ops_enemy_initial_reach_maps') then
        for enemy_id,_ in pairs(move_data.enemies) do
            DBG.show_fgumap_with_message(enemy_initial_reach_maps[enemy_id], 'moves_left', 'enemy_initial_reach_maps', move_data.unit_copies[enemy_id])
        end
    end

    fred_data.turn_data = {
        turn_number = wesnoth.current.turn,
        enemy_initial_reach_maps = enemy_initial_reach_maps
    }
end


function fred_ops_utils.set_ops_data(fred_data)
    local move_data = fred_data.move_data
    local raw_cfgs = FMC.get_raw_cfgs()
    local side_cfgs = FMC.get_side_cfgs()
    --DBG.dbms(raw_cfgs, false, 'raw_cfgs')

    for enemy_id,eirm in pairs(fred_data.turn_data.enemy_initial_reach_maps) do
        if (not move_data.enemies[enemy_id]) then
            fred_data.turn_data.enemy_initial_reach_maps[enemy_id] = nil
        end
    end

    -- Combine several zones into one, if the conditions for it are met.
    -- For example, on Freelands the 'east' and 'center' zones are combined
    -- into the 'top' zone if enemies are close enough to the leader.
    -- TODO: set this up to be configurable by the cfgs
    local replace_zone_ids = FMC.replace_zone_ids()
    --DBG.dbms(replace_zone_ids, false, 'replace_zone_ids')
    for _,zone_ids in ipairs(replace_zone_ids) do
        local raw_cfg_new = FMC.get_raw_cfgs(zone_ids.new)
        local replace_zones = false
        for enemy_id,enemy_loc in pairs(move_data.enemies) do
            if wesnoth.match_location(enemy_loc[1], enemy_loc[2], raw_cfg_new.enemy_slf) then
                replace_zones = true
                break
            end
        end
        if replace_zones then
            --std_print('replace zone: ' .. raw_cfg_new.zone_id)
            raw_cfgs[raw_cfg_new.zone_id] = raw_cfg_new
            for _,old_zone_id in ipairs(zone_ids.old) do
                raw_cfgs[old_zone_id] = nil
            end
        end

        -- If the zones are different from what they were before on the same turn,
        -- we need to do a full ops re-analysis -> delete ops_data
        if fred_data.ops_data.raw_cfgs then
            --std_print('checking whether raw_cfgs have changed')
            local reset_ops_data = false
            for new_zone_id,_ in pairs(raw_cfgs) do
                local id_exists = false
                for old_zone_id,_ in pairs(fred_data.ops_data.raw_cfgs) do
                    if (new_zone_id == old_zone_id) then
                        id_exists = true
                        break
                    end
                end
                if (not id_exists) then
                    reset_ops_data = true
                    break
                end
            end
            if (not reset_ops_data) then
                for old_zone_id,_ in pairs(fred_data.ops_data.raw_cfgs) do
                    local id_exists = false
                    for new_zone_id,_ in pairs(raw_cfgs) do
                        if (old_zone_id == new_zone_id) then
                            id_exists = true
                            break
                        end
                    end
                    if (not id_exists) then
                        reset_ops_data = true
                        break
                    end
                end
            end
            --std_print('reset_ops_data', reset_ops_data)

            if reset_ops_data then
                fred_data.ops_data = {}
            end
        end
    end
    --DBG.dbms(raw_cfgs, false, 'raw_cfgs')


    local leader_objectives, leader_effective_reach_map = FMLU.leader_objectives(fred_data)
    local objectives = { leader = leader_objectives }
    --DBG.dbms(objectives, false, 'objectives')
    --DBG.show_fgumap_with_message(leader_effective_reach_map, 'moves_left', 'leader_effective_reach_map')
    local leader_zone_map, leader_perp_map = FMLU.assess_leader_threats(objectives.leader, side_cfgs, fred_data)
    --DBG.dbms(objectives, false, 'objectives')


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
    --DBG.dbms(my_power, false, 'my_power')
    --DBG.dbms(enemy_power, false, 'enemy_power')

    local base_power_ratio = my_base_power / enemy_base_power
    --std_print('base:  ' .. base_power_ratio .. ' = ' .. my_base_power .. ' / ' .. enemy_base_power)

    local power_ratio = {}
    local min_power_ratio, max_power_ratio = math.huge, - math.huge
    for t = 0,n_turns-1 do
        power_ratio[t] = my_power[t] / enemy_power[t]
        --std_print(t, power_ratio[t])

        min_power_ratio = math.min(power_ratio[t], min_power_ratio)
        max_power_ratio = math.max(power_ratio[t], max_power_ratio)
    end
    --DBG.dbms(power_ratio, false, 'power_ratio')
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
        --[[
        power = {
            base_ratio = base_power_ratio,
            current_ratio = power_ratio[0],
            next_turn_ratio = power_ratio[1],
            min_ratio = min_power_ratio,
            max_ratio = max_power_ratio
        },
        --]]
        orders = {
            base_value_ratio = base_value_ratio,
            --max_value_ratio = max_value_ratio,
            value_ratio = value_ratio,
            base_power_ratio = base_power_ratio,
            current_power_ratio = power_ratio[0]
        }
    }


    --[[
    local n_vill_my, n_vill_enemy, n_vill_unowned, n_vill_total = 0, 0, 0, 0
    for x,y,data in FGM.iter(move_data.village_map) do
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
    --]]

    --behavior.ratios.assets = n_vill_my / (n_vill_total - n_vill_my + 1e-6)
    --behavior.orders.expansion = behavior.ratios.influence / behavior.ratios.assets

    local midpoint = math.sqrt(max_power_ratio / min_power_ratio) * min_power_ratio
    --std_print('midpoint: ' .. midpoint)
    local cycle_ratio, push_factor = {}, {}
    for i = 0,n_turns-1 do
        cycle_ratio[i] = power_ratio[i] / midpoint
        push_factor[i] = cycle_ratio[i] * power_ratio[i]
    end
    --DBG.dbms(cycle_ratio, false, 'cycle_ratio')
    --DBG.dbms(push_factor, false, 'push_factor')
    behavior.orders.push_factor = push_factor[0]

    --DBG.dbms(behavior, false, 'behavior')

    -- Store parameters relevant to attack effectiveness (independent of terrain)
    -- for each unit. This is used to determine whether unit_attacks has to be
    -- recalculated for a unit.
    local unit_attack_status = {}
    for id,_ in pairs(move_data.units) do
        local unit_info = move_data.unit_infos[id]
        unit_attack_status[id] = string.format('%d-%d-%d', unit_info.hitpoints, unit_info.experience, unit_info.level)
        if unit_info.status.poisoned then unit_attack_status[id] = unit_attack_status[id] .. 'p' end
        if unit_info.status.slowed then unit_attack_status[id] = unit_attack_status[id] .. 's' end
    end
    --DBG.dbms(unit_attack_status, false, 'unit_attack_status')


    -- Find the unit-vs-unit ratings: effectiveness of each AI unit vs. each enemy unit.
    -- This is expensive, so only do it for units which have changed since the last move.
    -- TODO: can functions in attack_utils be used for this?
    -- Extract all units
    --   - because no two units on the map can have the same underlying_id
    --   - so that we do not accidentally overwrite a unit
    --   - so that we don't accidentally apply leadership, backstab or the like
    local extracted_units = {}
    for id,loc in pairs(move_data.units) do
        local unit_proxy = wesnoth.get_unit(loc[1], loc[2])
        wesnoth.extract_unit(unit_proxy)
        table.insert(extracted_units, unit_proxy)  -- Not a proxy unit any more at this point
    end

    local attack_locs = FMC.get_attack_test_locs()
    local cfg_attack = { value_ratio = value_ratio }

    -- This loop flags units which have changed since the previous move, or were
    -- not previously included (either because it's the first move of the turn, or
    -- because a unit was created (plague, event, ...)
    -- It also automatically excludes units that have been killed.
    local my_units_changed, enemy_units_changed = {}, {}
    local previous_unit_attack_status = fred_data.ops_data.unit_attack_status or {}
    for id,loc in pairs(move_data.units) do
        if (not previous_unit_attack_status[id]) or (unit_attack_status[id] ~= previous_unit_attack_status[id]) then
            if move_data.my_units[id] then
                my_units_changed[id] = loc
            else
                enemy_units_changed[id] = loc
            end
        end
    end
    --DBG.dbms(my_units_changed, false, 'my_units_changed')
    --DBG.dbms(enemy_units_changed, false, 'enemy_units_changed')

    local changed_units_matrix = {}
    for enemy_id,enemy_loc in pairs(enemy_units_changed) do
        for id,loc in pairs(move_data.my_units) do
            if (not changed_units_matrix[id]) then changed_units_matrix[id] = {} end
            changed_units_matrix[id][enemy_id] = true
        end
    end
    for id,loc in pairs(my_units_changed) do
        for enemy_id,enemy_loc in pairs(move_data.enemies) do
            if (not changed_units_matrix[id]) then changed_units_matrix[id] = {} end
            changed_units_matrix[id][enemy_id] = true
        end
    end
    --DBG.dbms(changed_units_matrix, false, 'changed_units_matrix')

    -- Reuse the previous entries for units that have not changed
    local unit_attacks = {}
    for id,_ in pairs(move_data.my_units) do
        for enemy_id,_ in pairs(move_data.enemies) do
            if (not changed_units_matrix[id]) or (not changed_units_matrix[id][enemy_id]) then
                if (not unit_attacks[id]) then unit_attacks[id] = {} end
                unit_attacks[id][enemy_id] = fred_data.ops_data.unit_attacks[id][enemy_id]
            end
        end
    end
    --DBG.dbms(unit_attacks, false, 'unit_attacks')

    -- Only calculate new unit_attacks for units that have changed
    for my_id,enemy_array in pairs(changed_units_matrix) do
        --std_print(my_id)
        if (not unit_attacks[my_id]) then unit_attacks[my_id] = {} end

        local old_x = move_data.unit_copies[my_id].x
        local old_y = move_data.unit_copies[my_id].y
        local my_x, my_y = attack_locs.attacker_loc[1], attack_locs.attacker_loc[2]

        wesnoth.put_unit(move_data.unit_copies[my_id], my_x, my_y)
        local my_proxy = wesnoth.get_unit(my_x, my_y)

        for enemy_id,_ in pairs(enemy_array) do
            --std_print('    ' .. enemy_id)
            local tmp_attacks = {}

            local old_x_enemy = move_data.unit_copies[enemy_id].x
            local old_y_enemy = move_data.unit_copies[enemy_id].y
            local enemy_x, enemy_y = attack_locs.defender_loc[1], attack_locs.defender_loc[2]

            wesnoth.put_unit(move_data.unit_copies[enemy_id], enemy_x, enemy_y)
            local enemy_proxy = wesnoth.get_unit(enemy_x, enemy_y)

            local bonus_poison = 8
            local bonus_slow = 4
            local bonus_regen = 8

            local max_rating = - math.huge
            for i_w,attack in ipairs(move_data.unit_infos[my_id].attacks) do
                --std_print('attack weapon: ' .. i_w)

                local att_stat, def_stat, my_weapon, enemy_weapon = wesnoth.simulate_combat(my_proxy, i_w, enemy_proxy)
                local att_outcome = FAU.attstat_to_outcome(move_data.unit_infos[my_id], att_stat, def_stat.hp_chance[0], move_data.unit_infos[enemy_id].level)
                local def_outcome = FAU.attstat_to_outcome(move_data.unit_infos[enemy_id], def_stat, att_stat.hp_chance[0], move_data.unit_infos[my_id].level)
-- TODO: this also returns damages
                local rating_table = FAU.attack_rating({ move_data.unit_infos[my_id] }, move_data.unit_infos[enemy_id], { attack_locs.attacker_loc }, { att_outcome }, def_outcome, cfg_attack, move_data)

                local _, my_base_damage, my_extra_damage, my_regen_damage
                    = FAU.get_total_damage_attack(my_weapon, attack, true, move_data.unit_infos[enemy_id])

                -- If the enemy has no weapon at this range, attack_num=-1 and enemy_attack
                -- will be nil; this is handled just fine by FAU.get_total_damage_attack
                -- Note: attack_num starts at 0, not 1 !!!!
                --std_print('  enemy weapon: ' .. enemy_weapon.attack_num + 1)
                local enemy_attack = move_data.unit_infos[enemy_id].attacks[enemy_weapon.attack_num + 1]
                local _, enemy_base_damage, enemy_extra_damage, enemy_regen_damage
                    = FAU.get_total_damage_attack(enemy_weapon, enemy_attack, false, move_data.unit_infos[my_id])

                if (rating_table.rating > max_rating) then
                    max_rating = rating_table.rating
                    tmp_attacks = {
                        my_regen = - enemy_regen_damage, -- not that this is (must be) backwards as this is
                        enemy_regen = - my_regen_damage, -- regeneration "damage" to the _opponent_
                        rating_forward = rating_table.rating,
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
            --DBG.dbms(tmp_attacks, false, 'tmp_attacks')

            local max_rating_counter, max_damage_counter = - math.huge
            for i_w,attack in ipairs(move_data.unit_infos[enemy_id].attacks) do
                --std_print('counter weapon: ' .. i_w)

                local att_stat_counter, def_stat_counter, enemy_weapon, my_weapon = wesnoth.simulate_combat(enemy_proxy, i_w, my_proxy)
                local att_outcome_counter = FAU.attstat_to_outcome(move_data.unit_infos[enemy_id], att_stat_counter, def_stat_counter.hp_chance[0], move_data.unit_infos[my_id].level)
                local def_outcome_counter = FAU.attstat_to_outcome(move_data.unit_infos[my_id], def_stat_counter, att_stat_counter.hp_chance[0], move_data.unit_infos[enemy_id].level)
-- TODO: this also returns damages
                local rating_table_counter = FAU.attack_rating({ move_data.unit_infos[enemy_id] }, move_data.unit_infos[my_id], { attack_locs.defender_loc }, { att_outcome_counter }, def_outcome_counter, cfg_attack, move_data)

                local _, enemy_base_damage, enemy_extra_damage, _
                    = FAU.get_total_damage_attack(enemy_weapon, attack, true, move_data.unit_infos[my_id])

                -- If the AI unit has no weapon at this range, attack_num=-1 and my_attack
                -- will be nil; this is handled just fine by FAU.get_total_damage_attack
                -- Note: attack_num starts at 0, not 1 !!!!
                --std_print('  my weapon: ' .. my_weapon.attack_num + 1)
                local my_attack = move_data.unit_infos[my_id].attacks[my_weapon.attack_num + 1]
                local _, my_base_damage, my_extra_damage, _
                    = FAU.get_total_damage_attack(my_weapon, my_attack, false, move_data.unit_infos[enemy_id])

                if (rating_table_counter.rating > max_rating_counter) then
                    max_rating_counter = rating_table_counter.rating
                    tmp_attacks.rating_counter = rating_table_counter.rating
                    tmp_attacks.damage_counter = {
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
            tmp_attacks.damage_counter.max_taken_any_weapon = max_damage_counter


            move_data.unit_copies[enemy_id] = wesnoth.copy_unit(enemy_proxy)
            wesnoth.erase_unit(enemy_x, enemy_y)
            move_data.unit_copies[enemy_id].x = old_x_enemy
            move_data.unit_copies[enemy_id].y = old_y_enemy

            unit_attacks[my_id][enemy_id] = tmp_attacks
        end

        move_data.unit_copies[my_id] = wesnoth.copy_unit(my_proxy)
        wesnoth.erase_unit(my_x, my_y)
        move_data.unit_copies[my_id].x = old_x
        move_data.unit_copies[my_id].y = old_y
    end

    for _,extracted_unit in ipairs(extracted_units) do wesnoth.put_unit(extracted_unit) end

    --DBG.dbms(unit_attacks, false, 'unit_attacks')


    local ops_data = fred_data.ops_data
    ops_data.unit_attacks = unit_attacks
    ops_data.behavior = behavior
    ops_data.unit_attack_status = unit_attack_status


    ----- Get situation on the map first -----

    local used_units = fred_data.ops_data.used_units or {}
    --DBG.dbms(used_units, false, 'used_units')


    local zone_maps = {}
    for zone_id,raw_cfg in pairs(raw_cfgs) do
        zone_maps[zone_id] = {}
        local zone = wesnoth.get_locations(raw_cfg.ops_slf)
        for _,loc in ipairs(zone) do
            FGM.set_value(zone_maps[zone_id], loc[1], loc[2], 'in_zone', true)
        end
    end
    if objectives.leader.leader_threats.significant_threat then
        zone_maps['leader'] = leader_zone_map
    end

    if DBG.show_debug('ops_zone_maps') then
        for zone_id,zone_map in pairs(zone_maps) do
            DBG.show_fgumap_with_message(zone_map, 'in_zone', 'zone_map ' .. zone_id)
        end
    end

    -- Need the fronts for assigning units to zones. These will not be the exact fronts
    -- needed later (which in turn are based on the assigned units). They will either be
    -- based on the fronts from the previous move, or on overall influence maps (at the
    -- beginning of the turn), but those should be close enough for this purpose.
    -- If necessary, we could do this iteratively, but I don't think this is needed.
    local fronts
    if fred_data.ops_data.fronts then
        fronts = fred_data.ops_data.fronts
    else
        fronts = fred_ops_utils.find_fronts(zone_maps, nil, fred_data)
    end
    --DBG.dbms(fronts, false, 'fronts')


    -- Attributing enemy units to zones
    local assigned_enemies, unassigned_enemies = {}, {}
    local enemy_zones = {}
    for id,loc in pairs(move_data.enemies) do
        if objectives.leader.leader_threats.enemies[id] then
            if (not assigned_enemies['leader']) then
                assigned_enemies['leader'] = {}
            end
            assigned_enemies['leader'][id] = move_data.units[id][1] * 1000 + move_data.units[id][2]
            enemy_zones[id] = 'leader'
        elseif (not move_data.unit_infos[id].canrecruit)
            and (not FGM.get_value(move_data.close_castles_map[move_data.unit_infos[id].side], loc[1], loc[2], 'castle') or false)
        then
            local unit_copy = move_data.unit_copies[id]
            local zone_id = FU.moved_toward_zone(unit_copy, fronts, raw_cfgs, side_cfgs)

            if (not assigned_enemies[zone_id]) then
                assigned_enemies[zone_id] = {}
            end
            assigned_enemies[zone_id][id] = move_data.units[id][1] * 1000 + move_data.units[id][2]
            enemy_zones[id] = zone_id
        else
            unassigned_enemies[id] = move_data.units[id][1] * 1000 + move_data.units[id][2]
            enemy_zones[id] = 'none'
        end
    end
    --DBG.dbms(assigned_enemies, false, 'assigned_enemies')
    --DBG.dbms(unassigned_enemies, false, 'unassigned_enemies')
    --DBG.dbms(enemy_zones, false, 'enemy_zones')


    -- Pre-assign units to the zones into/toward which they have moved.
    -- They will preferably, but not strictly be used in those zones.
    -- Units without moves are put into a separate table, either based on where
    -- they were used previously (if that corresponds to an existing zone, meaning
    -- for example that units used in the 'all_map' zone are automatically
    -- reconsidered) otherwise according to the same criteria as units with moves.
    -- The latter also works for mid-turn situations or when moves are taken away in events etc.
    local pre_assigned_units, units_noMP_zones = {}, {}
    for id,_ in pairs(move_data.my_units) do
        local unit_copy = move_data.unit_copies[id]
        if (not unit_copy.canrecruit)
            and (not FGM.get_value(move_data.reachable_castles_map[unit_copy.side], unit_copy.x, unit_copy.y, 'castle') or false)
        then
            if used_units[id] and raw_cfgs[used_units[id]] then
                --std_print(id, used_units[id])
                units_noMP_zones[id] = used_units[id]
            else
                local zone_id = FU.moved_toward_zone(unit_copy, fronts, raw_cfgs, side_cfgs)
                if move_data.my_units_MP[id] then
                    pre_assigned_units[id] = zone_id
                else
                    units_noMP_zones[id] = zone_id
                end
            end
        end
    end
    --DBG.dbms(pre_assigned_units, false, 'pre_assigned_units')
    --DBG.dbms(units_noMP_zones, false, 'units_noMP_zones')


    local leader = move_data.leaders[wesnoth.current.side]

    -- Add effective reach of leader to:
    --   - reach_maps (via effective_reach_maps)
    --   - my_move_map[1]
    --   - TODO: others?
    -- Not currently adjusted because not needed (but might have to be added later):
    --   - unit_attack_maps
    --   - my_attack_map
    -- Currently, the leader is the only unit for which an effective reach_map is needed.
    -- This might change later.

    local effective_reach_maps = {}
    effective_reach_maps[leader.id] = leader_effective_reach_map

    for id,reach_map in pairs(move_data.reach_maps) do
        -- Do this only for AI units, not enemies
        if move_data.my_units[id] and (not effective_reach_maps[id]) then
            effective_reach_maps[id] = reach_map
        end
    end
    move_data.effective_reach_maps = effective_reach_maps

    for x,y,data in FGM.iter(move_data.my_move_map[1]) do
        if FGM.get_value(effective_reach_maps[leader.id], x, y, 'moves_left') then
            data.eff_reach_ids = data.ids
        else
            local eff_reach_ids
            for _,id in ipairs(data.ids) do
                if (id ~= leader.id) then
                    if (not eff_reach_ids) then eff_reach_ids = {} end
                    table.insert(eff_reach_ids, id)
                end
            end
            data.eff_reach_ids = eff_reach_ids
        end
    end


    local reserved_actions = {}

    if objectives.leader.village then
        local leader_heal_benefit = math.min(8, move_data.unit_infos[leader.id].max_hitpoints - move_data.unit_infos[leader.id].hitpoints)
        -- Multiply benefit * 1.5 for this being the leader
        -- Not putting the leader into too much danger is taken care of elsewhere
        leader_heal_benefit = 1.5 * leader_heal_benefit / move_data.unit_infos[leader.id].max_hitpoints * FU.unit_value(move_data.unit_infos[leader.id])
        local x, y = objectives.leader.village[1], objectives.leader.village[2]
        local action = {
            id = leader.id,
            x = x, y = y,
            action_id = 'MLV',
            benefit = leader_heal_benefit
        }
        local action_id = 'leader_village:' .. (x * 1000 + y)
        reserved_actions[action_id] = action
    end

    if objectives.leader.keep then
        -- If prerecruit is not set, then the leader just tries to move to the keep
        -- In that case, we give a small token benefit, otherwise, use half the
        -- value of the remaining gold as the benefit
        -- TODO: this has to be refined
        local leader_recruit_benefit = 1
        if objectives.leader.do_recruit then
            leader_recruit_benefit = 0.5 * wesnoth.sides[wesnoth.current.side].gold
        end

        local x, y = objectives.leader.keep[1], objectives.leader.keep[2]
        local action = {
            -- Important: we reserve the hex, so that the leader can recruit, but not the
            -- unit, as the leader should be able to do something else after recruiting.
            -- The reduced range is taken care of by effective_reach_maps.
            id = leader.id,
            x = x, y = y,
            action_id = 'MLK',
            benefit = leader_recruit_benefit
        }
        local action_id = 'leader_keep:' .. (x * 1000 + y)
        reserved_actions[action_id] = action
    end

    -- place_holders currently only includes the prerecruits. Other reserved actions
    -- could be added, such as village grabs, but then we also need to check in the
    -- counter attack calculation that those units are not used in the attack.
    local place_holders = {}
    if objectives.leader.prerecruit then
        -- Units to recruit do have preferred hexes, but those do not need to be reserved.
        -- Also, there is no benefit/penalty as long as enough castle hexes are available.
        local recruit_benefit = {}

        local available_keeps = 0
        for _,_,_ in FGM.iter(move_data.reachable_keeps_map[wesnoth.current.side]) do
            available_keeps = available_keeps + 1
        end
        local available_castles = -1 -- need to exclude one of the keeps
        for _,_,_ in FGM.iter(move_data.reachable_castles_map[wesnoth.current.side]) do
            available_castles = available_castles + 1
        end

        for _,unit in ipairs(objectives.leader.prerecruit.units) do
            local n_rb = #recruit_benefit
            local rb = recruit_benefit[n_rb] or 0
            rb = rb + wesnoth.unit_types[unit.recruit_type].cost
            recruit_benefit[n_rb + 1] = rb

            local x, y = unit.recruit_hex[1], unit.recruit_hex[2]
            table.insert(place_holders, {
                x, y,
                type = unit.recruit_type
            })
        end

        local action = {
            id = '',
            x = -1, y = -1,
            action_id = 'rec',
            benefit = recruit_benefit,
            available_keeps = available_keeps,
            available_castles = available_castles
        }
        local action_id = 'recruit'
        reserved_actions[action_id] = action
    end
    --DBG.dbms(reserved_actions, false, 'reserved_actions')


    local interaction_matrix = FCFG.interaction_matrix()
    --DBG.dbms(interaction_matrix, false, 'interaction_matrix')

    local village_objectives, villages_to_grab = FVU.village_objectives(raw_cfgs, side_cfgs, zone_maps, fred_data)
    objectives.protect = village_objectives
    --DBG.dbms(objectives.protect, false, 'objectives.protect')
    --DBG.dbms(villages_to_grab, false, 'villages_to_grab')

    -- Exclude villages already taken (i.e. at this point only the retreat village for the leader)
    -- and units marked in reserved_actions (also only the leader)
    -- TODO: we do not exclude them previously, as we might add a utility function later
    -- if there are several villages the leader might go to
    local possible_village_grabs = FVU.village_grabs(villages_to_grab, reserved_actions, interaction_matrix.penalties['GV'], fred_data)
    --DBG.dbms(possible_village_grabs, false, 'possible_village_grabs')

    -- Add villages to protect between leader and enemies, and remove them from the other zones
    if objectives.leader.leader_threats.significant_threat then
        local leader_villages = {}
        for zone_id,protect_objective in pairs(objectives.protect.zones) do
            for i_v=#protect_objective.villages,1,-1 do
                local village = protect_objective.villages[i_v]
                local in_zone = FGM.get_value(leader_zone_map, village.x, village.y, 'in_zone')
                --std_print('  ' .. zone_id, village.x .. ',' .. village.y, in_zone)

                if in_zone then
                    table.insert(leader_villages, village)
                    table.remove(protect_objective.villages, i_v)
                end
            end
        end
        objectives.protect.zones['leader'] = {
            protect_leader = true,
            villages = leader_villages
        }

        -- Potential TODO: do we want to add enemies_between back in?
    end
    --DBG.dbms(objectives.protect, false, 'objectives.protect')
    --DBG.dbms(objectives, false, 'objectives')


    local village_benefits = FBU.village_benefits(possible_village_grabs, fred_data)
    --DBG.dbms(village_benefits, false, 'village_benefits')

    -- Assess village grabbing by itself; this is for testing only
    --local village_assignments = FBU.assign_units(village_benefits, utilities.retreat, move_data)
    --DBG.dbms(village_assignments, false, 'village_assignments')


    -- Find goal hexes for leader protection
    -- Currently we use the middle between the closest enemy and the leader
    -- and all villages needing protection
    local leader_goal = objectives.leader.final
    --DBG.dbms(leader_goal, false, 'leader_goal')

    local leader_distance_map = FU.get_leader_distance_map(leader_goal, side_cfgs)
    fred_data.ops_data.leader_distance_map = leader_distance_map

    fred_data.ops_data.unit_advance_distance_maps = fred_data.ops_data.unit_advance_distance_maps or {}
    local unit_advance_distance_maps = fred_data.ops_data.unit_advance_distance_maps
    FU.get_unit_advance_distance_maps(fred_data.ops_data.unit_advance_distance_maps, raw_cfgs, side_cfgs, nil, move_data)


    -- The leader zone is different in several respects:
    --  - The maps need to be recalculated each move (in case the leader gets a new goal etc.)
    --  - Forward distance is simply distance from leader
    --  - perp comes from between maps and is calculated for enemies rather than own units
    --  - The unit maps cover the whole map (but the zone map later is only done for the zone)

    if objectives.leader.leader_threats.significant_threat then
        unit_advance_distance_maps['leader'] = {}
        local zone_cfg = { all_map = FMC.get_raw_cfgs('all_map') }
        local AADM_cfg = { my_leader_loc = leader_goal }
        local all_advance_distance_maps = {}
        FU.get_unit_advance_distance_maps(all_advance_distance_maps, zone_cfg, side_cfgs, AADM_cfg, move_data)

        for id,map in pairs(all_advance_distance_maps['all_map']) do
            unit_advance_distance_maps['leader'][id] = {}
            for x,y,data in FGM.iter(map) do
                FGM.set_value(unit_advance_distance_maps['leader'][id], x, y, 'forward', data.my_cost)
                unit_advance_distance_maps['leader'][id][x][y].perp = FGM.get_value(leader_perp_map, x, y, 'perp')
            end
        end
    end

    if DBG.show_debug('ops_distance_map') then
        --DBG.show_fgumap_with_message(leader_distance_map, 'my_leader_distance', 'leader_distance_map: my_leader_distance')
        --DBG.show_fgumap_with_message(leader_distance_map, 'enemy_leader_distance', 'leader_distance_map: enemy_leader_distance')
        DBG.show_fgumap_with_message(leader_distance_map, 'distance', 'leader_distance_map: distance')
        --DBG.show_fgumap_with_message(unit_advance_distance_maps['west']['Troll Whelp'], 'my_cost', 'my_cost')
        --DBG.show_fgumap_with_message(unit_advance_distance_maps['west']['Troll Whelp'], 'enemy_cost', 'enemy_cost')

        for zone_id,uadm in pairs(unit_advance_distance_maps) do
            local typ
            for t,_ in pairs(uadm) do
                typ = t
                break
            end
            DBG.show_fgumap_with_message(unit_advance_distance_maps[zone_id][typ], 'forward', 'unit_advance_distance_maps[' .. zone_id .. '][' .. typ .. ']: forward')
            DBG.show_fgumap_with_message(unit_advance_distance_maps[zone_id][typ], 'perp', 'unit_advance_distance_maps[' .. zone_id .. '][' .. typ .. ']: perp')
        end
    end


    local goal_hexes_leader, leader_enemies = {}, {}
    for enemy_id,_ in pairs(objectives.leader.leader_threats.enemies) do
        -- TODO: simply using the middle point here might not be the best thing to do
        local enemy_loc = fred_data.move_data.units[enemy_id]
        local goal_loc = {
            math.floor((enemy_loc[1] + leader_goal[1]) / 2 + 0.5),
            math.floor((enemy_loc[2] + leader_goal[2]) / 2 + 0.5)
        }
        --DBG.dbms(goal_loc, false, 'goal_loc')
        local ld = FGM.get_value(fred_data.ops_data.leader_distance_map, goal_loc[1], goal_loc[2], 'my_leader_distance')

        if (not goal_hexes_leader['leader']) then
            goal_hexes_leader['leader'] = { goal_loc }
            goal_hexes_leader['leader'][1].ld = ld
        elseif (ld < goal_hexes_leader['leader'][1].ld) then
            goal_hexes_leader['leader'] = { goal_loc }
            goal_hexes_leader['leader'][1].ld = ld
        end
        if (not leader_enemies['leader']) then leader_enemies['leader'] = {} end
        leader_enemies['leader'][enemy_id] = enemy_loc[1] * 1000 + enemy_loc[2]
    end

    for zone_id,goal_hexes in pairs(goal_hexes_leader) do
        if objectives.protect.zones[zone_id] then
            for _,village in ipairs(objectives.protect.zones[zone_id].villages) do
                table.insert(goal_hexes, { village.x, village.y })
            end
        end
    end
    --DBG.dbms(goal_hexes_leader, false, 'goal_hexes_leader')
    --DBG.dbms(leader_enemies, false, 'leader_enemies')


    local utilities = {}
    utilities.retreat = FBU.retreat_utilities(move_data, fred_data.ops_data.behavior.orders.value_ratio)
    --DBG.dbms(utilities, false, 'utilities')


    local attack_benefits = FBU.attack_benefits(leader_enemies, goal_hexes_leader, false, fred_data)
    --DBG.dbms(attack_benefits, false, 'attack_benefits')


    local lthreat_power = {
        enemy = { power = 0, n_units = 0 },
        previous = { power = 0, n_units = 0 },
        assigned = { power = 0, n_units = 0 }
    }
    for enemy_id,_ in pairs(objectives.leader.leader_threats.enemies) do
        local unit_power = FU.unit_base_power(fred_data.move_data.unit_infos[enemy_id])
        lthreat_power.enemy.power = lthreat_power.enemy.power + unit_power
        lthreat_power.enemy.n_units = lthreat_power.enemy.n_units + 1
    end
    --DBG.dbms(lthreat_power, false, 'lthreat_power')

    local already_protecting = {}
    for zone_id,benefits in pairs(attack_benefits) do
        local action = 'protect_leader:' .. zone_id
        for id,data in pairs(benefits) do
            if (not move_data.unit_infos[id].canrecruit)
                and (data.turns <= 2) and move_data.my_units_noMP[id]
                and (not used_units[id])
            then
                local unit_power = FU.unit_base_power(fred_data.move_data.unit_infos[id])
                already_protecting[id] = unit_power
            end
        end
    end
    --DBG.dbms(already_protecting, false, 'already_protecting')

    for id,unit_power in pairs(already_protecting) do
        lthreat_power.previous.power = lthreat_power.previous.power + unit_power
        lthreat_power.previous.n_units = lthreat_power.previous.n_units + 1
    end
    --DBG.dbms(lthreat_power, false, 'lthreat_power')

    local fraction_previous = 1
    if (lthreat_power.enemy.power > 0) then
        fraction_previous = lthreat_power.previous.power / lthreat_power.enemy.power
    end
    local urgency = FU.urgency(fraction_previous, lthreat_power.previous.n_units)

    local leader_threat_benefits, leader_advance_benefits = {}, {}
    local lthreat_assigned_power = 0
    -- TODO: there's only one zone left, so this could be reduced, but keeping for now in case I want to revert this
    for zone_id,benefits in pairs(attack_benefits) do
        local action_protect = 'protect_leader:leader' -- .. zone_id
        local action_advance = 'advance_leader:leader' -- .. zone_id

        for id,data in pairs(benefits) do
            -- Need to check for moves here also, as a noMP unit might happen to be
            -- at one of the leader goal hexes

            if (not move_data.unit_infos[id].canrecruit) and move_data.my_units_MP[id] then
                if (data.turns <= 1)  then
                    --std_print('  use this unit')
                    if (not leader_threat_benefits[action_protect]) then
                        leader_threat_benefits[action_protect] = {
                            units = {},
                            power = {
                                missing = lthreat_power.enemy.power - lthreat_power.previous.power,
                                previous = lthreat_power.previous.power,
                                n_previous = lthreat_power.previous.n_units
                            }
                        }
                    end
                    leader_threat_benefits[action_protect].units[id] = { benefit = data.benefit, penalty = 0 }
                    local unit_power = FU.unit_base_power(fred_data.move_data.unit_infos[id])
                    lthreat_assigned_power = lthreat_assigned_power + unit_power

                    -- Don't need inertia here, as these are only the units who can get there this turn
                else
                    local unit_value = FU.unit_value(fred_data.move_data.unit_infos[id])
                    local turn_penalty = unit_value / 1 * data.turns
                    --std_print(zone_id, id, data.turns, turn_penalty)

                    -- No inertia here either, as it is all the same zone

                    if (not leader_advance_benefits[action_advance]) then
                        leader_advance_benefits[action_advance] = {
                            units = {}
                        }
                    end
                    leader_advance_benefits[action_advance].units[id] = {
                        benefit = data.benefit,
                        penalty = turn_penalty
                    }
                    local unit_power = FU.unit_base_power(fred_data.move_data.unit_infos[id])
                end
            end
        end
    end
    --DBG.dbms(leader_threat_benefits, false, 'leader_threat_benefits')
    --DBG.dbms(leader_advance_benefits, false, 'leader_advance_benefits')


    -- Assess leader protecting by itself; this is for testing only
    --local assignments = FBU.assign_units(leader_threat_benefits, utilities.retreat, move_data)
    --DBG.dbms(assignments, false, 'assignments')

    local combined_benefits = {}
    for action,data in pairs(village_benefits) do
        combined_benefits[action] = data
    end
    for action,data in pairs(leader_threat_benefits) do
        combined_benefits[action] = data
    end
    --DBG.dbms(combined_benefits, false, 'combined_benefits')

    local protect_leader_assignments = FBU.assign_units(combined_benefits, utilities.retreat, move_data)
    --DBG.dbms(protect_leader_assignments, false, 'protect_leader_assignments')
    local assigned_units = assignments_to_assigned_units(protect_leader_assignments, move_data)
    --DBG.dbms(assigned_units, false, 'assigned_units')

    for id,assignment in pairs(protect_leader_assignments) do
        -- There are village grabbers mixed in here, thus the somewhat complicated way of doing this
        if string.find(assignment, 'protect_leader') then
            local unit_power = FU.unit_base_power(fred_data.move_data.unit_infos[id])
            lthreat_power.assigned.power = lthreat_power.assigned.power + unit_power
            lthreat_power.assigned.n_units = lthreat_power.assigned.n_units + 1
        end
    end
    --DBG.dbms(lthreat_power, false, 'lthreat_power')


    local lp_protect_power = lthreat_power.previous.power + lthreat_power.assigned.power
    local advance_power_ratio = (1 + ops_data.behavior.orders.base_power_ratio) / 2
    if (advance_power_ratio > 1) then advance_power_ratio = 1 end
    local advance_power_missing = advance_power_ratio * lthreat_power.enemy.power - lp_protect_power
    --DBG.dbms(leader_advance_benefits, false, 'leader_advance_benefits')

    local leader_advance_assignments = {}
    if leader_advance_benefits['advance_leader:leader'] then
        leader_advance_benefits['advance_leader:leader'].power = {
            missing = advance_power_missing,
            previous = lp_protect_power,
            n_previous = lthreat_power.previous.n_units + lthreat_power.assigned.n_units
        }
        --DBG.dbms(leader_advance_benefits, false, 'leader_advance_benefits')
        leader_advance_assignments = FBU.assign_units(leader_advance_benefits, utilities.retreat, move_data)
    end
    --DBG.dbms(leader_advance_assignments, false, 'leader_advance_assignments')


    if DBG.show_debug('ops_leader_threats') then
        local my_total_power = lthreat_power.previous.power + lthreat_assigned_power
        local lp_power_ratio = 1
        if (lthreat_power.enemy.power > 0) then
            lp_power_ratio = my_total_power / lthreat_power.enemy.power
        end
        local fraction_missing = math.max(0, 1 - fraction_previous)
        local new_fraction_there = 1
        if (lthreat_power.enemy.power > 0) then
            new_fraction_there = lp_protect_power / lthreat_power.enemy.power
        end
        local new_urgency = FU.urgency(new_fraction_there, lthreat_power.previous.n_units + lthreat_power.assigned.n_units)

        std_print('\nleader threats:')
        std_print('  enemy power:', lthreat_power.enemy.power)
        std_print('  power_there, n_there', lthreat_power.previous.power, lthreat_power.previous.n_units)
        std_print('  fraction there, missing', fraction_previous, fraction_missing)
        std_print('  urgency', urgency)
        std_print('  leader_threat power (my / enemy = ratio):  ' .. my_total_power .. ' / ' .. lthreat_power.enemy.power .. ' = ' .. lp_power_ratio)
        std_print('  new assigned power, n:', lthreat_power.assigned.power, lthreat_power.assigned.n_units)
        std_print('  protect power: ', lp_protect_power .. ' = ' .. lthreat_power.previous.power .. ' + ' .. lthreat_power.assigned.power)
        std_print('  new fraction_there, urgency:', new_fraction_there, new_urgency)
        std_print('  advance_power_ratio, advance_power_missing:', advance_power_ratio, advance_power_missing)
        std_print('')
    end


    local assigned_units = assignments_to_assigned_units(protect_leader_assignments, move_data)
    --DBG.dbms(assigned_units, false, 'assigned_units')
    --DBG.dbms(units_noMP_zones, false, 'units_noMP_zones')


    -- Now we add units to the zones based on the total power of enemies in the
    -- zones, not just those that are threats to the leader
    local goal_hexes_zones = {}
    for zone_id,cfg in pairs(raw_cfgs) do
        local max_ld, loc
        if objectives.protect.zones[zone_id] and objectives.protect.zones[zone_id].villages then
            for _,village in ipairs(objectives.protect.zones[zone_id].villages) do
                for enemy_id,_ in pairs(move_data.enemies) do
                    if FGM.get_value(move_data.reach_maps[enemy_id], village.x, village.y, 'moves_left') then
                        local ld = FGM.get_value(fred_data.ops_data.leader_distance_map, village.x, village.y, 'distance')
                        if (not max_ld) or (ld > max_ld) then
                            max_ld = ld
                            loc = { village.x, village.y }
                        end
                    end
                end
            end
        end

        if max_ld then
            --std_print('max protect ld:', zone_id, max_ld, loc[1], loc[2])
            goal_hexes_zones[zone_id] = { loc }
        else
            -- TODO: adapt for several goal hexes
            goal_hexes_zones[zone_id] = { cfg.center_hexes[1] }
        end
    end

    if goal_hexes_leader.leader and goal_hexes_leader.leader[1] then
        goal_hexes_zones['leader'] = goal_hexes_leader.leader
    end
    --DBG.dbms(goal_hexes_zones, false, 'goal_hexes_zones')


    for id,_ in pairs(already_protecting) do
        units_noMP_zones[id] = 'leader'
    end
    --DBG.dbms(units_noMP_zones)

    -- Also add the noMP units to protect_leader_assignments
    -- TODO: not sure if we want to keep them spearate instead (then additional work is needed later)
    for id,zone_id in pairs(units_noMP_zones) do
        if (not assigned_units[zone_id]) then assigned_units[zone_id] = {} end
        assigned_units[zone_id][id] = move_data.my_units[id][1] * 1000 + move_data.my_units[id][2]

        protect_leader_assignments[id] = 'has_moved:' .. zone_id
    end

    -- And the same for the advancers
    -- Potential TODO: maybe we want to set these up as reserved actions at some point
    for id,assignment in pairs(leader_advance_assignments) do
        if (not assigned_units['leader']) then assigned_units['leader'] = {} end
        assigned_units['leader'][id] = move_data.my_units[id][1] * 1000 + move_data.my_units[id][2]
        protect_leader_assignments[id] = assignment
    end

    --DBG.dbms(assigned_units, false, 'assigned_units')
    --DBG.dbms(protect_leader_assignments, false, 'protect_leader_assignments')


    -- Use the total power ratio of all units for this
    local power_ratio = fred_data.ops_data.behavior.orders.base_power_ratio
    if (power_ratio > 1) then power_ratio = 1 end
    --std_print('power_ratio: ' .. power_ratio)


    -- This is only needed for zones with enemies -> passing assigned_enemies as first argument
    local zone_power_stats = fred_ops_utils.zone_power_stats(assigned_enemies, assigned_units, assigned_enemies, power_ratio, fred_data)
    --DBG.dbms(zone_power_stats, false, 'zone_power_stats')

    local zone_attack_benefits = FBU.attack_benefits(assigned_enemies, goal_hexes_zones, false, fred_data)
    --DBG.dbms(zone_attack_benefits, false, 'zone_attack_benefits')

    local zone_benefits = {}
    for zone_id,benefits in pairs(zone_attack_benefits) do
        local power_missing = zone_power_stats[zone_id].power_missing
        if (power_missing > 0) then
            local action = 'zone:' .. zone_id

            for id,data in pairs(benefits) do
                if (not move_data.unit_infos[id].canrecruit)
                    and (not protect_leader_assignments[id])
                then
                    --std_print('  use this unit')
                    -- TODO: these will have to be tweaked
                    local unit_value = FU.unit_value(fred_data.move_data.unit_infos[id])

                    local turn_penalty = 0
                    if (data.turns > 1) then
                        turn_penalty = unit_value / 2 * data.turns
                    end

                    local inertia = 0
                    if pre_assigned_units[id] and (pre_assigned_units[id] == zone_id) then
                        inertia = 0.25 * unit_value
                    end
                    --std_print(zone_id, id, data.turns, turn_penalty, inertia)

                    if (not zone_benefits[action]) then
                        zone_benefits[action] = {
                            units = {},
                            power = {
                                missing = power_missing,
                                previous = zone_power_stats[zone_id].my_power,
                                n_previous = zone_power_stats[zone_id].n_units
                            }
                        }
                    end

                    zone_benefits[action].units[id] = {
                        benefit = data.benefit,
                        -- TODO: this can result in negative penalty
                        penalty = turn_penalty - inertia
                    }
                end
            end
        end
    end
    --DBG.dbms(zone_benefits, false, 'zone_benefits')

    local zone_assignments = FBU.assign_units(zone_benefits, utilities.retreat, move_data)
    --DBG.dbms(protect_leader_assignments, false, 'protect_leader_assignments')
    --DBG.dbms(zone_assignments, false, 'zone_assignments')

    local assignments = {}
    for id,action in pairs(protect_leader_assignments) do
        assignments[id] = action
    end
    for id,action in pairs(zone_assignments) do
        assignments[id] = action
    end
    --DBG.dbms(assignments, false, 'assignments')

    local unused_units = {}
    for id,_ in pairs(move_data.my_units) do
        if (not assignments[id]) and (not move_data.unit_infos[id].canrecruit) then
            unused_units[id] = 'none'
        end
    end
    --DBG.dbms(unused_units, false, 'unused_units')


    -- All remaining units with non-zero retreat utility are added to reserved_actions
    -- as retreaters, but are not deleted from the unused_units table. They get
    -- assigned to zones for potential use just as other units.
    for id,_ in pairs(unused_units) do
        if (utilities.retreat[id] > 0) then
            -- Use half of missing HP
            -- TODO: refine
            local heal_benefit = 0.5 * (move_data.unit_infos[id].max_hitpoints - move_data.unit_infos[id].hitpoints)
            heal_benefit = heal_benefit / move_data.unit_infos[id].max_hitpoints * FU.unit_value(move_data.unit_infos[id])
            local action = {
                id = id,
                x = -1, y = -1, -- Don't have reserved location
                action_id = 'ret',
                benefit = heal_benefit
            }
            local action_id = 'retreat:' .. id
            reserved_actions[action_id] = action
        end
    end
    --DBG.dbms(reserved_actions, false, 'reserved_actions')

    -- Pre-assigned units left at this time get assigned to their zones
    -- As mentioned above, this includes the retreaters
    for id,_ in pairs(unused_units) do
        if pre_assigned_units[id] then
            local zone_id = pre_assigned_units[id]
            --std_print('assigning ' .. id .. ' -> ' .. zone_id)
            assignments[id] = 'zone:' .. zone_id
            unused_units[id] = nil
        end
    end
    --DBG.dbms(assignments, false, 'assignments')
    --DBG.dbms(unused_units, false, 'unused_units')

    local assigned_units = assignments_to_assigned_units(assignments, move_data)
    --DBG.dbms(assigned_units, false, 'assigned_units')

    --DBG.dbms(villages_to_grab, false, 'villages_to_grab')
    local scout_assignments = FVU.assign_scouts(villages_to_grab, unused_units, assigned_units, move_data)
    --DBG.dbms(scout_assignments, false, 'scout_assignments')

    for id,action in pairs(scout_assignments) do
        assignments[id] = action
        unused_units[id] = nil
    end
    --DBG.dbms(assignments, false, 'assignments')
    --DBG.dbms(unused_units, false, 'unused_units')

    -- If there are unused unit left now, we simply assign them to the zones
    -- with the largest difference between needed and assigned power
    if next(unused_units) then
        -- Do this for the standard zones only (not needed for leader zone) -> passing @raw_cfgs as first argument
        -- TODO: do we want to include the leader zone also? If so, need different treatment for those units?
        local zone_power_stats = fred_ops_utils.zone_power_stats(raw_cfgs, assigned_units, assigned_enemies, power_ratio, fred_data)
        --DBG.dbms(zone_power_stats, false, 'zone_power_stats')
        local power_diffs = {}
        for zone_id,power in pairs(zone_power_stats) do
            power_diffs[zone_id] = power.power_needed - power.my_power
        end
        --DBG.dbms(power_diffs, false, 'power_diffs')

        for id,_ in pairs(unused_units) do
            local max_diff, best_zone_id = - math.huge
            for zone_id, diff in pairs(power_diffs) do
                if (diff > max_diff) then
                    max_diff, best_zone_id = diff, zone_id
                end
            end
            --std_print(id, best_zone_id, max_diff)

            assignments[id] = 'zone:' .. best_zone_id
            power_diffs[best_zone_id] = power_diffs[best_zone_id] - FU.unit_base_power(move_data.unit_infos[id])
            --DBG.dbms(power_diffs, false, 'power_diffs')
        end
    end
    unused_units = nil
    --DBG.dbms(assignments, false, 'assignments')

    local assigned_units = assignments_to_assigned_units(assignments, move_data)
    --DBG.dbms(assigned_units, false, 'assigned_units')


    for id,action_id in pairs(assignments) do
        if string.find(action_id, 'grab_village') then
            local i1 = string.find(action_id, '-')
            local i2 = string.find(action_id, ':')
            local xy = tonumber(string.sub(action_id, i1 + 1, i2 - 1))
            local x, y = math.floor(xy / 1000), xy % 1000
            --std_print(id,action,xy,x,y)

            local alternate_units = {}
            for id2,benefit in pairs(village_benefits[action_id].units) do
                if (id ~= id2) then
                    table.insert(alternate_units, {
                        id = id2,
                        benefit = benefit.benefit
                    })
                end
            end
            table.sort(alternate_units, function(a, b) return a.benefit > b.benefit end)

            local action = {
                id = id,
                x = x, y = y,
                action_id = 'GV',
                benefit = combined_benefits[action_id].units[id].benefit,
                alternate_units = alternate_units
            }
            local action_id_nozone = 'grab_village:' .. (x * 1000 + y)
            reserved_actions[action_id_nozone] = action

        end
    end
    --DBG.dbms(village_benefits, false, 'village_benefits')
    --DBG.dbms(reserved_actions, false, 'reserved_actions')


    local zone_influence_maps = {}
    for zone_id,zone_map in pairs(zone_maps) do
        local zone_influence_map = {}
        for id,_ in pairs(assigned_units[zone_id] or {}) do
            for x,y,data in FGM.iter(move_data.unit_influence_maps[id]) do
                if FGM.get_value(zone_map, x, y, 'in_zone') then
                    FGM.add(zone_influence_map, x, y, 'my_influence', data.influence)
                end
            end
        end

        for enemy_id,_ in pairs(assigned_enemies[zone_id] or {}) do
            for x,y,data in FGM.iter(move_data.unit_influence_maps[enemy_id]) do
                if FGM.get_value(zone_map, x, y, 'in_zone') then
                    FGM.add(zone_influence_map, x, y, 'enemy_influence', data.influence)
                end
            end
        end

        for x,y,data in FGM.iter(zone_influence_map) do
            data.influence = (data.my_influence or 0) - (data.enemy_influence or 0)
            data.tension = (data.my_influence or 0) + (data.enemy_influence or 0)
            data.vulnerability = data.tension - math.abs(data.influence)
        end

        zone_influence_maps[zone_id] = zone_influence_map

        if DBG.show_debug('ops_zone_influence_maps') then
            --DBG.show_fgumap_with_message(zone_influence_map, 'my_influence', 'Zone my influence map ' .. zone_id)
            --DBG.show_fgumap_with_message(zone_influence_map, 'enemy_influence', 'Zone enemy influence map ' .. zone_id)
            DBG.show_fgumap_with_message(zone_influence_map, 'influence', 'Zone influence map ' .. zone_id)
            --DBG.show_fgumap_with_message(zone_influence_map, 'tension', 'Zone tension map ' .. zone_id)
            DBG.show_fgumap_with_message(zone_influence_map, 'vulnerability', 'Zone vulnerability map ' .. zone_id)
        end
    end

    -- This includes both leader and "normal" zones
    fred_ops_utils.update_protect_goals(objectives, assigned_units, assigned_enemies, fred_data)
    --DBG.dbms(objectives.protect, false, 'objectives.protect')

    -- Set original threat status
    local old_locs = { { move_data.leader_x, move_data.leader_y } }
    local new_locs = { objectives.leader.final }
    FVS.set_virtual_state(old_locs, new_locs, place_holders, true, move_data)
    local status = FS.check_exposures(objectives, nil, nil, fred_data)
    FVS.reset_state(old_locs, new_locs, true, move_data)
    --DBG.dbms(status, false, 'status')


    local fronts = fred_ops_utils.find_fronts(zone_maps, zone_influence_maps, fred_data)
    --DBG.dbms(fronts, false, 'fronts')


    -- Push factors are only needed for holding, that is, in zones with enemies.
    --   -> passing @assigned_enemies as first argument
    local zone_power_stats = fred_ops_utils.zone_power_stats(assigned_enemies, assigned_units, assigned_enemies, power_ratio, fred_data)
    --DBG.dbms(zone_power_stats, false, 'zone_power_stats')

    local f_zone_power_ratios, zone_push_factors = {}, {}, {}
    for zone_id,power_stat in pairs(zone_power_stats) do
        local f_power_ratio = power_stat.my_power / (power_stat.enemy_power + 1e-6) / behavior.orders.current_power_ratio
        f_zone_power_ratios[zone_id] = f_power_ratio
        -- TODO: use sqrt here?
        zone_push_factors[zone_id] = f_power_ratio * behavior.orders.push_factor
    end
    --DBG.dbms(f_zone_power_ratios, false, 'f_zone_power_ratios')
    --DBG.dbms(zone_push_factors, false, 'zone_push_factors')
    behavior.zone_push_factors = zone_push_factors


    -- Note: the advance_distance_maps cover more hexes than just the zones,
    -- but the goal_hexes below are calculated for zone hexes only
    local advance_distance_maps = {}
    for zone_id,units in pairs(assigned_units) do
        advance_distance_maps[zone_id] = {}
        local n_units = 0
        for id,_ in pairs(units) do
            n_units = n_units + 1
        end

        for id,_ in pairs(units) do
            local typ = move_data.unit_infos[id].type
            for x,y,data in FGM.iter(unit_advance_distance_maps[zone_id][typ]) do
                FGM.add(advance_distance_maps[zone_id], x, y, 'forward', data.forward / n_units)
                FGM.add(advance_distance_maps[zone_id], x, y, 'perp', data.perp / n_units)
            end
        end
    end

    local advance_goals = {}
    for zone_id,ADmap in pairs(advance_distance_maps) do
        local line_infl, weights = {}, {}
        -- Note: loops needs to be over zone hexes only, while advance_distance_maps
        -- also contains hexes outside the zone, in particular for the leader zone
        for x,y,_ in FGM.iter(zone_maps[zone_id]) do
            local data = ADmap[x] and ADmap[x][y]
            if data then
                local my_infl = FGM.get_value(move_data.influence_maps, x, y, 'my_full_move_influence') or 0
                local enemy_infl = FGM.get_value(move_data.influence_maps, x, y, 'enemy_full_move_influence') or 0
                -- TODO: use zone-dependent value_ratio here?
                local infl = my_infl - value_ratio * enemy_infl
                local int_forward = H.round(2 * data.forward) / 2
                local weight = 1 / (1 + data.perp / 5)
                line_infl[int_forward] = (line_infl[int_forward] or 0) + infl * weight
                weights[int_forward] = (weights[int_forward] or 0) + weight
            end
        end

        for forward,data in pairs(line_infl) do
            line_infl[forward] = line_infl[forward] / weights[forward]
        end
        --DBG.dbms(line_infl, false, zone_id .. ' line_infl')

        local max_forward, min_forward = -9e99, 9e99
        for forward,data in pairs(line_infl) do
            if (data >= 0) and (forward > max_forward) then
                max_forward = forward
            end
            if (forward < min_forward) then
                min_forward = forward
            end
        end
        --std_print(zone_id .. ': max, min forward = ', max_forward, min_forward)
        if (max_forward == -9e99) then
            max_forward = min_forward
        end

        local min_perp, goal_hex = 9e99, {}
        for x,y,_ in FGM.iter(zone_maps[zone_id]) do
            local data = ADmap[x] and ADmap[x][y]
            if data and (data.forward >= max_forward - 0.25) and (data.forward <= max_forward + 0.25) and (data.perp < min_perp) then
                min_perp = data.perp
                goal_hex = { x, y }
            end
        end
        --std_print('goal_hex: ' .. goal_hex [1] .. ',' .. goal_hex[2], min_perp)

        if DBG.show_debug('ops_advance_distance_map') then
            local display_map, front_map = {}, {}
            for x,y,_ in FGM.iter(zone_maps[zone_id]) do
                local data = ADmap[x] and ADmap[x][y]
                if data and (data.perp <= 2) then
                    local int_forward = H.round(2 * data.forward) / 2
                    FGM.set_value(display_map, x, y, 'influence', line_infl[int_forward])
                end

                if data and (data.forward >= max_forward - 0.5) and (data.forward <= max_forward + 0.5) then
                    FGM.set_value(front_map, x, y, 'front', true)
                end
            end

            DBG.show_fgumap_with_message(ADmap, 'forward', 'advance_distance_map ' .. zone_id .. ': forward')
            DBG.show_fgumap_with_message(ADmap, 'perp', 'advance_distance_map ' .. zone_id .. ': perp')
            for x,y,_ in FGM.iter(front_map) do
                wesnoth.wml_actions.item { x = x, y = y, halo = "halo/teleport-8.png" }
            end
            wesnoth.wml_actions.item { x = goal_hex[1], y = goal_hex[2], halo = "halo/illuminates-aura.png~CS(-255,-255,0)" }
            DBG.show_fgumap_with_message(display_map, 'influence', 'advance route influence: ' .. zone_id)
            wesnoth.wml_actions.remove_item { x = goal_hex[1], y = goal_hex[2], halo = "halo/illuminates-aura.png~CS(-255,-255,0)" }
            for x,y,_ in FGM.iter(front_map) do
                wesnoth.wml_actions.remove_item { x = x, y = y, halo = "halo/teleport-8.png" }
            end
        end

        advance_goals[zone_id] = goal_hex
    end
    --DBG.dbms(advance_goals, false, 'advance_goals')


    -- The following is currently unused, but could be useful to determine, for example,
    -- if we are over-extended (over-expanded) etc.
    --[[
    local full_influence_map = FU.get_full_influence_map(move_data)

    -- Probably could just use full_influence_map for everything, but doing it separately just in
    -- case I want the separate information
    local n_total, n_my_inf = 0, 0
    for x,y,data in FGM.iter(full_influence_map) do
        n_total = n_total + 1
        if (data.influence > 0) then
            n_my_inf = n_my_inf + 1
        end
    end
    local f_my_inf = n_my_inf / n_total
    --std_print(string.format('my inf: %4.3f = %d / %d', f_my_inf, n_my_inf, n_total))
    --]]


    ops_data.raw_cfgs = raw_cfgs
    ops_data.objectives = objectives
    ops_data.status = status
    ops_data.assigned_enemies = assigned_enemies
    ops_data.unassigned_enemies = unassigned_enemies
    ops_data.assigned_units = assigned_units
    ops_data.used_units = used_units
    ops_data.zone_maps = zone_maps
    ops_data.fronts = fronts
    ops_data.advance_goals = advance_goals
    ops_data.advance_distance_maps = advance_distance_maps
    ops_data.reserved_actions = reserved_actions
    ops_data.place_holders = place_holders
    ops_data.interaction_matrix = interaction_matrix

    -- Also need to reset the stored actions
    ops_data.stored_leader_protection = {}

    --DBG.dbms(ops_data, false, 'ops_data')
    --DBG.dbms(ops_data.objectives, false, 'ops_data.objectives')
    --DBG.dbms(ops_data.assigned_enemies, false, 'ops_data.assigned_enemies')
    --DBG.dbms(ops_data.assigned_units, false, 'ops_data.assigned_units')
    --DBG.dbms(ops_data.status, false, 'ops_data.status')
    --DBG.dbms(ops_data.behavior, false, 'ops_data.behavior')
    --DBG.dbms(ops_data.fronts, false, 'ops_data.fronts')
    --DBG.dbms(ops_data.reserved_actions, false, 'ops_data.reserved_actions')


    if (not ops_data.fred_behavior_str) then
        ops_data.fred_behavior_str = fred_ops_utils.behavior_output(true, zone_maps, ops_data)
    else
        fred_ops_utils.behavior_output(false, zone_maps, ops_data)
    end
end


function fred_ops_utils.get_action_cfgs(fred_data)
    local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'zone_control'

    local move_data = fred_data.move_data
    local ops_data = fred_data.ops_data
    --DBG.dbms(ops_data, false, 'ops_data')

    -- These are only the raw_cfgs of the 3 main zones
    --local raw_cfgs = FMC.get_raw_cfgs('all')
    --local raw_cfgs_main = FMC.get_raw_cfgs()
    --DBG.dbms(raw_cfgs_main, false, 'raw_cfgs_main')


    fred_data.zone_cfgs = {}

    -- For all of the main zones with enemies, find assigned units that have moves and attacks left
    local holders_by_zone, attackers_by_zone = {}, {}
    for zone_id,_ in pairs(ops_data.assigned_enemies) do
        if ops_data.assigned_units[zone_id] then
            for id,_ in pairs(ops_data.assigned_units[zone_id]) do
                if move_data.my_units_MP[id] then
                    if (not holders_by_zone[zone_id]) then holders_by_zone[zone_id] = {} end
                    holders_by_zone[zone_id][id] = move_data.units[id][1] * 1000 + move_data.units[id][2]
                end
                if (move_data.unit_copies[id].attacks_left > 0) then
                    local is_attacker = true
                    if move_data.my_units_noMP[id] then
                        is_attacker = false
                        for xa,ya in H.adjacent_tiles(move_data.my_units_noMP[id][1], move_data.my_units_noMP[id][2]) do
                            if FGM.get_value(move_data.enemy_map, xa, ya, 'id') then
                                is_attacker = true
                                break
                            end
                        end
                    end

                    if is_attacker then
                        if (not attackers_by_zone[zone_id]) then attackers_by_zone[zone_id] = {} end
                        attackers_by_zone[zone_id][id] = move_data.units[id][1] * 1000 + move_data.units[id][2]
                    end
                end
            end
        end
    end
    --DBG.dbms(holders_by_zone, false, 'holders_by_zone')
    --DBG.dbms(attackers_by_zone, false, 'attackers_by_zone')

    -- We add the leader as a potential attacker to all zones
    -- effective_reach_maps will be used to assess what he can do
    local leader = move_data.leaders[wesnoth.current.side]
    --std_print('leader.id', leader.id)
    if (move_data.unit_copies[leader.id].attacks_left > 0)
    then
        local is_attacker = true
        if move_data.my_units_noMP[leader.id] then
            is_attacker = false
            for xa,ya in H.adjacent_tiles(move_data.my_units_noMP[leader.id][1], move_data.my_units_noMP[leader.id][2]) do
                if FGM.get_value(move_data.enemy_map, xa, ya, 'id') then
                    is_attacker = true
                    break
                end
            end
        end

        if is_attacker then
            for zone_id,_ in pairs(ops_data.assigned_enemies) do
                if (not attackers_by_zone[zone_id]) then attackers_by_zone[zone_id] = {} end
                attackers_by_zone[zone_id][leader.id] = move_data.units[leader.id][1] * 1000 + move_data.units[leader.id][2]
            end
        end
    end
    --DBG.dbms(attackers_by_zone, false, 'attackers_by_zone')

    -- Advancers are essentially the same as holders, except that they are found independent of
    -- whether there are enemies in the zone, and they are only done for the main zones (not leader zone)
    -- TODO: should we go back to using the original, instead of the combined zones for advancers?
    local advancers_by_zone = {}
    for zone_id,_ in pairs(ops_data.raw_cfgs) do
        if ops_data.assigned_units[zone_id] then
            for id,_ in pairs(ops_data.assigned_units[zone_id]) do
                if move_data.my_units_MP[id] then
                    if (not advancers_by_zone[zone_id]) then advancers_by_zone[zone_id] = {} end
                    advancers_by_zone[zone_id][id] = move_data.units[id][1] * 1000 + move_data.units[id][2]
                end
            end
        end
    end
    --DBG.dbms(advancers_by_zone, false, 'advancers_by_zone')

    -- The following is done to simplify the cfg creation below, because
    -- ops_data.assigned_enemies might contain empty tables for zones
    -- Killed enemies should, in principle be already removed, but since
    -- it's quick and easy, we just check for it again.
    local threats_by_zone = {}
    local tmp_enemies = {}
    for zone_id,_ in pairs(ops_data.assigned_enemies) do
        if ops_data.assigned_enemies[zone_id] then
            for enemy_id,_ in pairs(ops_data.assigned_enemies[zone_id]) do
                if move_data.enemies[enemy_id] then
                    if (not threats_by_zone[zone_id]) then threats_by_zone[zone_id] = {} end
                    threats_by_zone[zone_id][enemy_id] = move_data.units[enemy_id][1] * 1000 + move_data.units[enemy_id][2]
                    tmp_enemies[enemy_id] = true
                end
            end
        end
    end
    --DBG.dbms(tmp_enemies, false, 'tmp_enemies')

    -- Also add all other enemies to the three main zones
    -- Mostly this will just be the leader and enemies on the keep, so
    -- for the most part, they will be out of reach, but this is important
    -- for late in the game
    local other_enemies = {}
    for enemy_id,loc in pairs(move_data.enemies) do
        if (not tmp_enemies[enemy_id]) then
            other_enemies[enemy_id] = loc[1] * 1000 + loc[2]
        end
    end
    tmp_enemies = nil
    --DBG.dbms(other_enemies, false, 'other_enemies')

    for enemy_id,xy in pairs(other_enemies) do
        for zone_id,_ in pairs(ops_data.assigned_enemies) do
            if (not threats_by_zone[zone_id]) then threats_by_zone[zone_id] = {} end
            threats_by_zone[zone_id][enemy_id] = xy
        end
    end

    --DBG.dbms(holders_by_zone, false, 'holders_by_zone')
    --DBG.dbms(attackers_by_zone, false, 'attackers_by_zone')
    --DBG.dbms(advancers_by_zone, false, 'advancers_by_zone')
    --DBG.dbms(threats_by_zone, false, 'threats_by_zone')


    local base_ratings = {
        protect_leader_eval = 32000, -- eval only
        attack_leader_threat = 31000,
        protect_leader_exec = 30000,

        fav_attack = 27000,
        advance_toward_leader = 26000,
        attack = 25000,

        protect = 22000,
        grab_villages = 21000,
        hold = 20000,

        recruit = 12000,
        retreat = 11000,
        advance = 10000,
        advance_all_map = 1000
    }


    ----- Leader threat actions -----

    local leader_threats = ops_data.objectives.leader.leader_threats
    --DBG.dbms(leader_threats, false, 'leader_threats')
    if leader_threats.significant_threat then
        local value_ratio = fred_data.ops_data.behavior.orders.value_ratio
        -- Use higher aggression (lower value_ratio) of overall and leader_threat vr
        local vr = math.min(value_ratio, leader_threats.leader_protect_value_ratio)
        --std_print('value_ratios:', vr, value_ratio, leader_threats.leader_protect_value_ratio)

        -- Note: even though we have units assigned to the leader zone, we do not specify
        -- these for holding and attacking leader threats, as the assignment is approximate.
        -- By contrast, we do use them for advancing toward the leader

        table.insert(fred_data.zone_cfgs, {
            zone_id = 'leader',
            action_type = 'hold',
            action_str = 'protect leader (eval only)',
            evaluate_only = true,
            find_best_protect_only = true,
            value_ratio = vr,
            rating = base_ratings.protect_leader_eval
        })

        table.insert(fred_data.zone_cfgs, {
            zone_id = 'leader',
            action_type = 'attack',
            action_str = 'attack leader threats',
            --zone_units = attackers_by_zone[zone_id],
            targets = leader_threats.enemies,
            value_ratio = vr,
            rating = base_ratings.attack_leader_threat
        })

        table.insert(fred_data.zone_cfgs, {
            zone_id = 'leader',
            action_type = 'hold',
            action_str = 'protect leader (exec)',
            rating = base_ratings.protect_leader_exec,
            use_stored_leader_protection = true
        })

        if holders_by_zone['leader'] then
            table.insert(fred_data.zone_cfgs, {
                zone_id = 'leader',
                action_type = 'advance',
                action_str = 'advance toward leader',
                zone_units = holders_by_zone['leader'],
                value_ratio = vr,
                rating = base_ratings.advance_toward_leader
            })
        end
        --DBG.dbms(fred_data.zone_cfgs, false, 'fred_data.zone_cfgs')
    end


    -- TODO: might want to do something more complex (e.g using local info) in ops layer
    local value_ratio = fred_data.ops_data.behavior.orders.value_ratio

    -- Favorable attacks. These are cross-zone
    table.insert(fred_data.zone_cfgs, {
        zone_id = 'all_map',
        action_type = 'attack',
        action_str = 'favorable attack',
        rating = base_ratings.fav_attack,
        value_ratio = 2.0 * value_ratio -- only very favorable attacks will pass this
    })


    -- Do this for the standard zones only (not needed for leader zone) -> passing @raw_cfgs as first argument
    local zone_power_stats = fred_ops_utils.zone_power_stats(ops_data.raw_cfgs, ops_data.assigned_units, ops_data.assigned_enemies, fred_data.ops_data.behavior.orders.base_power_ratio, fred_data)
    --DBG.dbms(zone_power_stats, false, 'zone_power_stats')


    for zone_id,zone_units in pairs(holders_by_zone) do
        if (zone_id ~= 'leader') then
			local power_rating = zone_power_stats[zone_id].power_needed - zone_power_stats[zone_id].my_power / 1000

			if threats_by_zone[zone_id] and attackers_by_zone[zone_id] then
				-- Attack --
				table.insert(fred_data.zone_cfgs,  {
					zone_id = zone_id,
					action_type = 'attack',
					action_str = 'zone attack',
					zone_units = attackers_by_zone[zone_id],
					targets = threats_by_zone[zone_id],
					rating = base_ratings.attack + power_rating,
					value_ratio = value_ratio
				})
			end

			if holders_by_zone[zone_id] then
				-- Hold --
				local rating = power_rating
				local action_str = 'zone hold'
				local protect_obj = ops_data.objectives.protect.zones[zone_id]
				if protect_obj and (
					(protect_obj.villages and protect_obj.villages[1])
					or (protect_obj.units and protect_obj.units[1])
					-- TODO: check whether this is already taken care of by the separate protect_leader action
					--   It probably is not, as that only checks for the leader, not castles
					or protect_obj.protect_leader
				) then
					rating = rating + base_ratings.protect
					action_str = 'zone protect'
				else
					rating = rating + base_ratings.hold
				end

				table.insert(fred_data.zone_cfgs, {
					zone_id = zone_id,
					action_type = 'hold',
					action_str = action_str,
					zone_units = holders_by_zone[zone_id],
					rating = rating
				})
			end
        end
    end


    -- Village grabs are stored in reserved_actions. This cfg can always be added.
    table.insert(fred_data.zone_cfgs, {
        zone_id = 'all_map',
        action_type = 'reserved_action',
        action_str = 'grab villages',
        reserved_id = 'GV',
        rating = base_ratings.grab_villages
    })


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
            action_str = 'zone advance',
            zone_units = advancers_by_zone[zone_id],
            rating = base_ratings.advance + power_rating
        })
    end


   -- Recruiting
   if ops_data.objectives.leader.prerecruit and ops_data.objectives.leader.prerecruit.units[1] then
       -- TODO: This check should not be necessary, but something can
       -- go wrong occasionally. Will eventually have to check why, for
       -- now I just put in this workaround.
       local current_gold = wesnoth.sides[wesnoth.current.side].gold
       local cost = wesnoth.unit_types[ops_data.objectives.leader.prerecruit.units[1].recruit_type].cost
       if (current_gold >= cost) then
           table.insert(fred_data.zone_cfgs, {
               zone_id = 'leader',
               action_type = 'recruit',
               action_str = 'recruit',
               rating = base_ratings.recruit
           })
       end
   end
   --DBG.dbms(fred_data.zone_cfgs, false, 'fred_data.zone_cfgs')


    -- Retreating is done zone independently. It handles (in this order):
    --   1. Moving the leader to a village
    --   3. Retreating injured units
    --   2. Moving leader to or toward keep
    -- It is the last action to be done and can simply always be called.
    -- There is no advantage in doing the sorting here.
    table.insert(fred_data.zone_cfgs, {
        zone_id = 'all_map',
        action_type = 'retreat',
        action_str = 'retreat',
        rating = base_ratings.retreat
    })


    -- TODO: this is a catch all action, that moves all units that were
    -- missed. Ideally, there will be no need for this in the end.
    table.insert(fred_data.zone_cfgs, {
        zone_id = 'all_map',
        action_type = 'advance',
        action_str = 'all_map advance',
        rating = base_ratings.advance_all_map
    })
    --DBG.dbms(fred_data.zone_cfgs, false, 'fred_data.zone_cfgs')


    -- Now sort by the ratings embedded in the cfgs
    table.sort(fred_data.zone_cfgs, function(a, b) return a.rating > b.rating end)

    --DBG.dbms(fred_data.zone_cfgs, false, 'fred_data.zone_cfgs')
end

return fred_ops_utils
