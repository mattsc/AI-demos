local H = wesnoth.require "helper"
local FCFG = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_config.lua"
local FDI = wesnoth.require "~/add-ons/AI-demos/lua/fred_data_incremental.lua"
local FGM = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_map.lua"
local FHU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_hold_utils.lua"
local FMC = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_map_config.lua"
local FMU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_map_utils.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

----- Hold: -----
local fred_hold = {}

function fred_hold.get_hold_action(zone_cfg, fred_data)
    DBG.print_debug_time('eval', fred_data.turn_start_time, '  - hold evaluation (' .. zone_cfg.action_str .. '): ' .. zone_cfg.zone_id .. ' (' .. string.format('%.2f', zone_cfg.rating) .. ')')

    local value_ratio = zone_cfg.value_ratio or fred_data.ops_data.behavior.orders.value_ratio
    local max_units = 3
    local max_hexes = 6
    local leader_derating = FCFG.get_cfg_parm('leader_derating')

    -- Ratio of forward to counter attack to consider for holding evaluation
    -- Set up so that:
    --   factor_counter + factor_forward = 1
    --   factor_counter / factor_forward = value_ratio
    local factor_counter = 1 / (1 + 1 / value_ratio)
    local factor_forward = 1 - factor_counter
    --std_print('factor_counter, factor_forward', factor_counter, factor_forward)

    local front_ld = 0
    if fred_data.ops_data.fronts.zones[zone_cfg.zone_id] then
        front_ld = fred_data.ops_data.fronts.zones[zone_cfg.zone_id].ld
    end
    --local push_factor = fred_data.ops_data.behavior.zone_push_factors[zone_cfg.zone_id] or fred_data.ops_data.behavior.orders.push_factor
    local push_factor = fred_data.ops_data.behavior.orders.hold_push_factor
    local rel_push_factor = push_factor / value_ratio
    --std_print('push_factor, rel_push_factor: ' .. zone_cfg.zone_id, push_factor, rel_push_factor)

    local acceptable_ctd = rel_push_factor - 1
    if (acceptable_ctd < 0) then acceptable_ctd = 0 end
    --std_print('acceptable_ctd: ' .. acceptable_ctd)

    local acceptable_max_damage_ratio = rel_push_factor / 2
    --std_print('acceptable_max_damage_ratio: ' .. acceptable_max_damage_ratio)

    -- This uses the absolute push factor, not the relative one;
    -- Do not hold for push_factors < 1, unless there is very little damage to be expected
    -- TODO: there's a discontinuity here that might not be good
    local acceptable_actual_damage_ratio = push_factor
    if (push_factor < 1) then
        acceptable_actual_damage_ratio = push_factor^2 / 10.
    end
    --std_print(zone_cfg.zone_id .. ': acceptable_actual_damage_ratio: ' .. acceptable_actual_damage_ratio)


    local vuln_weight = FCFG.get_cfg_parm('vuln_weight')
    local vuln_rating_weight = vuln_weight * (1 / value_ratio - 1)
    if (vuln_rating_weight < 0) then
        vuln_rating_weight = 0
    end
    --std_print('vuln_weight, vuln_rating_weight', vuln_weight, vuln_rating_weight)

    local forward_weight = FCFG.get_cfg_parm('forward_weight')
    local forward_rating_weight = forward_weight * (1 / value_ratio)
    --std_print('forward_weight, forward_rating_weight', forward_weight, forward_rating_weight)

    local influence_ratio = fred_data.ops_data.behavior.orders.current_power_ratio
    local base_value_ratio = fred_data.ops_data.behavior.orders.base_value_ratio / fred_data.ops_data.behavior.orders.value_ratio * value_ratio
    local protect_forward_rating_weight = (influence_ratio / base_value_ratio) - 1
    protect_forward_rating_weight = protect_forward_rating_weight * FCFG.get_cfg_parm('protect_forward_weight')
    --std_print('protect_forward_rating_weight', protect_forward_rating_weight)


    local raw_cfg = FMC.get_raw_cfgs(zone_cfg.zone_id)
    --DBG.dbms(raw_cfg, false, 'raw_cfg')
    --DBG.dbms(zone_cfg, false, 'zone_cfg')

    local move_data = fred_data.move_data

    local protect_objectives = fred_data.ops_data.objectives.protect.zones[zone_cfg.zone_id] or {}
    --DBG.dbms(protect_objectives, false, 'protect_objectives')
    --std_print('protect_leader ' .. zone_cfg.zone_id, protect_objectives.protect_leader)

    -- Holders are those specified in zone_units, or all units except the leader otherwise
    -- Except when we are only trying to protect units (not other protect goals), in that
    -- case it has been pre-determined who can protect
    -- TODO: does it make sense to do this in the setup of the zone_cfg instead?
    local holders = {}

    if protect_objectives.units and (#protect_objectives.units > 0)
        and (not protect_objectives.protect_leader)
        and ((not protect_objectives.villages) or (#protect_objectives.villages == 0))
    then
        --std_print(zone_cfg.zone_id .. ': units to protect (and only units)')
        holders = {}
        for id,_ in pairs(protect_objectives.protect_pairings) do
            holders[id] = move_data.units[id][1] * 1000 + move_data.units[id][2]
        end
    elseif zone_cfg.zone_units then
        holders = zone_cfg.zone_units
    else
        for id,_ in pairs(move_data.my_units_MP) do
            if (not move_data.unit_infos[id].canrecruit) then
                holders[id] = move_data.unit_infos[id].base_power
            end
        end
    end
    if (not next(holders)) then return end
    --DBG.dbms(holders, false, 'holders')


    local leader_goal = fred_data.ops_data.objectives.leader.final
    --DBG.dbms(leader_goal, false, 'leader_goal')

    local zone = wesnoth.get_locations(raw_cfg.ops_slf)
    if protect_objectives.protect_leader then
        -- When leader is threatened, we add area around goal position and all castle hexes
        -- TODO: this kind of works on Freelands, but probably not on all maps
        local add_hexes = wesnoth.get_locations {
            x = leader_goal[1], y = leader_goal[2], radius = 3
        }
        for _,hex in ipairs(add_hexes) do
            table.insert(zone, hex)
        end
        -- Castles are only added if the leader can get to a keep
        -- TODO: reevaluate later if this should be changed
        for x,y,_ in FGM.iter(move_data.reachable_castles_map) do
            table.insert(zone, { x, y })
            for xa,ya in H.adjacent_tiles(x, y) do
                table.insert(zone, { xa, ya })
            end
        end
    end

    -- avoid_map is currently only used to exclude the leader's goal position from holding
    -- This is needed because otherwise the hold counter attack analysis of leader threats
    -- does not work.
    -- TODO: find a better way of dealing with this, using backup leader goals instead.
    -- avoid_map also opens up the option of including [avoid] tags or similar functionality later.
    local avoid_map = {}
    FGM.set_value(avoid_map, leader_goal[1], leader_goal[2], 'is_avoided', true)

    local zone_map = {}
    for _,loc in ipairs(zone) do
        if (not FGM.get_value(avoid_map, loc[1], loc[2], 'is_avoided')) then
            FGM.set_value(zone_map, loc[1], loc[2], 'in_zone', true)
        end
    end
    if DBG.show_debug('hold_zone_map') then
        DBG.show_fgm_with_message(zone_map, 'in_zone', 'Zone map')
    end

    -- For the enemy rating, we need to put a 1-hex buffer around this
    -- So this includes the leader position (and at least part of avoid_map).
    -- TODO: I think this is okay, reconsider later
    local buffered_zone_map = {}
    for x,y,_ in FGM.iter(zone_map) do
        FGM.set_value(buffered_zone_map, x, y, 'in_zone', true)
        for xa,ya in H.adjacent_tiles(x, y) do
            FGM.set_value(buffered_zone_map, xa, ya, 'in_zone', true)
        end
    end
    if false then
        DBG.show_fgm_with_message(buffered_zone_map, 'in_zone', 'Buffered zone map')
    end


    local enemy_zone_maps = {}
    local holders_influence = {}
    for enemy_id,_ in pairs(move_data.enemies) do
        enemy_zone_maps[enemy_id] = {}

        for x,y,_ in FGM.iter(buffered_zone_map) do
            local enemy_defense = FDI.get_unit_defense(move_data.unit_copies[enemy_id], x, y, fred_data.caches.defense_maps)
            FGM.set_value(enemy_zone_maps[enemy_id], x, y, 'hit_chance', 1 - enemy_defense)

            local moves_left = FGM.get_value(move_data.reach_maps[enemy_id], x, y, 'moves_left')
            if moves_left then
                FGM.set_value(enemy_zone_maps[enemy_id], x, y, 'moves_left', moves_left)
            end
        end
    end

    for enemy_id,enemy_loc in pairs(move_data.enemies) do
        for x,y,_ in FGM.iter(zone_map) do
            --std_print(x,y)

            local enemy_hcs = {}
            local min_dist, max_dist = math.huge, - math.huge
            for xa,ya in H.adjacent_tiles(x, y) do
                -- Need the range of distance whether the enemy can get there or not
                local dist = wesnoth.map.distance_between(enemy_loc[1], enemy_loc[2], xa, ya)
                if (dist > max_dist) then
                    max_dist = dist
                end
                if (dist < min_dist) then
                    min_dist = dist
                end

                local moves_left = FGM.get_value(enemy_zone_maps[enemy_id], xa, ya, 'moves_left')
                if moves_left then
                    local ehc = FGM.get_value(enemy_zone_maps[enemy_id], xa, ya, 'hit_chance')
                    table.insert(enemy_hcs, {
                        ehc = ehc, dist = dist
                    })
                end
            end

            local adj_hc, cum_weight = 0, 0
            if max_dist then
                local dd = max_dist - min_dist
                for _,data in ipairs(enemy_hcs) do
                    local w = (max_dist - data.dist) / dd
                    adj_hc = adj_hc + data.ehc * w
                    cum_weight = cum_weight + w
                end
            end

            -- Note that this will give a 'nil' on the hex the enemy is on,
            -- but that's okay as the AI cannot reach that hex anyway
            if (cum_weight > 0) then
                adj_hc = adj_hc / cum_weight
                FGM.set_value(enemy_zone_maps[enemy_id], x, y, 'adj_hit_chance', adj_hc)

                local enemy_count = (FGM.get_value(holders_influence, x, y, 'enemy_count') or 0) + 1
                FGM.set_value(holders_influence, x, y, 'enemy_count', enemy_count)
            end
        end

        if false then
            --DBG.show_fgm_with_message(enemy_zone_maps[enemy_id], 'hit_chance', 'Enemy hit chance', move_data.unit_copies[enemy_id])
            --DBG.show_fgm_with_message(enemy_zone_maps[enemy_id], 'moves_left', 'Enemy moves left', move_data.unit_copies[enemy_id])
            DBG.show_fgm_with_message(enemy_zone_maps[enemy_id], 'adj_hit_chance', 'Enemy adjacent hit_chance', move_data.unit_copies[enemy_id])
        end
    end


    for id,_ in pairs(holders) do
        --std_print('\n' .. id, zone_cfg.zone_id)
        for x,y,_ in FGM.iter(move_data.unit_attack_maps[1][id]) do
            local unit_influence = move_data.unit_infos[id].current_power
            unit_influence = unit_influence * FDI.get_unit_defense(move_data.unit_copies[id], x, y, fred_data.caches.defense_maps)

            local inf = FGM.get_value(holders_influence, x, y, 'my_influence') or 0
            FGM.set_value(holders_influence, x, y, 'my_influence', inf + unit_influence)

            local my_count = (FGM.get_value(holders_influence, x, y, 'my_count') or 0) + 1
            FGM.set_value(holders_influence, x, y, 'my_count', my_count)


            local enemy_influence = FGM.get_value(move_data.influence_maps, x, y, 'enemy_influence') or 0

            FGM.set_value(holders_influence, x, y, 'enemy_influence', enemy_influence)
            holders_influence[x][y].influence = inf + unit_influence - enemy_influence
        end
    end

    for x,y,data in FGM.iter(holders_influence) do
        if data.influence then
            local influence = data.influence
            local tension = data.my_influence + data.enemy_influence
            local vulnerability = tension - math.abs(influence)

            local ld = FGM.get_value(fred_data.ops_data.leader_distance_map, x, y, 'distance')
            vulnerability = vulnerability + ld / 10

            data.tension = tension
            data.vulnerability = vulnerability
        end
    end


    if DBG.show_debug('hold_influence_map') then
        --DBG.show_fgm_with_message(holders_influence, 'my_influence', 'Holders influence')
        --DBG.show_fgm_with_message(holders_influence, 'enemy_influence', 'Enemy influence')
        DBG.show_fgm_with_message(holders_influence, 'influence', 'Influence')
        --DBG.show_fgm_with_message(holders_influence, 'tension', 'tension')
        DBG.show_fgm_with_message(holders_influence, 'vulnerability', 'vulnerability')
        --DBG.show_fgm_with_message(holders_influence, 'my_count', 'My count')
        --DBG.show_fgm_with_message(holders_influence, 'enemy_count', 'Enemy count')
    end


    local enemy_weights = {}
    for id,_ in pairs(holders) do
        enemy_weights[id] = {}
        for enemy_id,_ in pairs(move_data.enemies) do
            local att = fred_data.ops_data.unit_attacks[id][enemy_id]
            --DBG.dbms(att, false, 'att')

            -- It's probably okay to keep the hard-coded weight of 0.5 here, as the
            -- damage taken is most important for which units the enemy will select
            local weight = att.damage_counter.base_taken + att.damage_counter.extra_taken
            weight = weight - 0.5 * (att.damage_counter.base_done + att.damage_counter.extra_done)
            if (weight < 1) then weight = 1 end

            enemy_weights[id][enemy_id] = { weight = weight }
        end
    end
    --DBG.dbms(enemy_weights, false, 'enemy_weights')

    -- protect_locs and assigned_enemies are only used to calculate between_map
    -- protect_locs being set also serves as flag whether a protect hold is desired
    -- If leader is to be protected we use leader_goal and castle hexes for between_map
    -- Otherwise, all the other hexes/units to be protected are used
    -- TODO: maybe always use all, but with different weights?
    -- Castles are only added if the leader can get to a keep
    -- TODO: reevaluate later if this should be changed
    local protect_locs, assigned_enemies
    if protect_objectives.protect_leader then
        local exposure = fred_data.ops_data.status.leader.exposure
        if (exposure > 0) then
            protect_locs = { {
                leader_goal[1], leader_goal[2],
                exposure = exposure
            } }
        end
        for _,loc in ipairs(fred_data.ops_data.status.castles.locs) do
            if (not protect_locs) then protect_locs = {} end
            table.insert(protect_locs, {
                loc[1], loc[2],
                exposure = 3
            })
        end
        assigned_enemies = fred_data.ops_data.objectives.leader.leader_threats.enemies
    else
        -- TODO: change format of protect_locs, so that simply objectives.protect can be taken
        local locs, exposures = {}, {}
        if protect_objectives.units then
            for _,unit in ipairs(protect_objectives.units) do
                -- It's possible for exposure to be zero, if the counter attack is much in favor of the AI unit
                local exposure = fred_data.ops_data.status.units[unit.id].exposure
                if (exposure > 0) then
                    table.insert(locs, unit)
                    table.insert(exposures, exposure)
                end
            end
        end
        if protect_objectives.villages then
            for _,village in ipairs(protect_objectives.villages) do
                table.insert(locs, village)

                local xy = village.x * 1000 + village.y
                table.insert(exposures, fred_data.ops_data.status.villages[xy].exposure)
            end
        end

        for i_l,loc in ipairs(locs) do
            if (not protect_locs) then
                protect_locs = {}
            end
            local protect_loc = { loc.x, loc.y, exposure = exposures[i_l] }
            table.insert(protect_locs, protect_loc)
        end

        assigned_enemies = fred_data.ops_data.assigned_enemies[zone_cfg.zone_id]
    end

    -- Just a safeguard
    if protect_locs and (not protect_locs[1]) then
        wesnoth.message('!!!!!!!!!! This should never happen: protect_locs table is empty !!!!!!!!!!')
        protect_locs = nil
    end

    if protect_locs then
        local min_ld, max_ld = math.huge, - math.huge
        for _,loc in ipairs(protect_locs) do
            local ld = FGM.get_value(fred_data.ops_data.leader_distance_map, loc[1], loc[2], 'distance')
            if (ld < min_ld) then min_ld = ld end
            if (ld > max_ld) then max_ld = ld end
        end
    end

    --DBG.dbms(fred_data.ops_data.status, false, 'fred_data.ops_data.status')
    --DBG.dbms(protect_objectives, false, 'protect_objectives')
    --DBG.dbms(protect_locs, false, 'protect_locs')
    --DBG.dbms(assigned_enemies, false, 'assigned_enemies')

    local between_map
    if protect_locs then
        local locs = {}
        for _,ploc in ipairs(protect_locs) do
            table.insert(locs, ploc)
        end
        local tmp_enemies = {}
        -- TODO: maybe we should always add both types of enemies, with different weights
        if assigned_enemies and next(assigned_enemies) then
            for id,_ in pairs(assigned_enemies) do
                tmp_enemies[id] = move_data.enemies[id]
            end
        elseif protect_objectives.enemies and next(protect_objectives.enemies) then
            for id,_ in pairs(protect_objectives.enemies) do
                tmp_enemies[id] = move_data.enemies[id]
            end
        else
            DBG.dbms(assigned_enemies, false, 'assigned_enemies')
            DBG.dbms(protect_objectives.enemies, false, 'protect_objectives.enemies')
            error(zone_cfg.zone_id .. ': either assigned_enemies or protect_objectives.enemies must contain enemies if protect_locs is given')
        end
        --DBG.dbms(tmp_enemies, false, 'tmp_enemies')

        between_map = FMU.get_between_map(locs, tmp_enemies, fred_data)

        if DBG.show_debug('hold_between_map') then
            DBG.show_fgm_with_message(between_map, 'is_between', zone_cfg.zone_id .. ': between map: is_between')
            DBG.show_fgm_with_message(between_map, 'distance', zone_cfg.zone_id .. ': between map: distance')
            --DBG.show_fgm_with_message(between_map, 'blurred_distance', zone_cfg.zone_id .. ': between map: blurred distance')
            DBG.show_fgm_with_message(between_map, 'perp_distance', zone_cfg.zone_id .. ': between map: perp_distance')
            --DBG.show_fgm_with_message(between_map, 'blurred_perp_distance', zone_cfg.zone_id .. ': between map: blurred blurred_perp_distance')
            --DBG.show_fgm_with_message(between_map, 'inv_cost', zone_cfg.zone_id .. ': between map: inv_cost')
            --DBG.show_fgm_with_message(fred_data.ops_data.leader_distance_map, 'distance', 'leader distance')
            --DBG.show_fgm_with_message(fred_data.ops_data.leader_distance_map, 'enemy_leader_distance', 'enemy_leader_distance')
        end
    end

    local pre_rating_maps = {}
    for id,_ in pairs(holders) do
        --std_print('\n' .. id, zone_cfg.zone_id)
        local min_eleader_distance = math.huge
        for x,y,_ in FGM.iter(move_data.effective_reach_maps[id]) do
            if FGM.get_value(zone_map, x, y, 'in_zone') then
                --std_print(x,y)
                local can_hit = false
                for enemy_id,enemy_zone_map in pairs(enemy_zone_maps) do
                    if FGM.get_value(enemy_zone_map, x, y, 'adj_hit_chance') then
                        can_hit = true
                        break
                    end
                end

                if (not can_hit) then
                    local eld = FGM.get_value(fred_data.ops_data.advance_distance_maps[zone_cfg.zone_id], x, y, 'forward')

                    if (eld < min_eleader_distance) then
                        min_eleader_distance = eld
                    end
                end
            end
        end
        --std_print('  min_eleader_distance: ' .. min_eleader_distance)

        for x,y,_ in FGM.iter(move_data.effective_reach_maps[id]) do
            --std_print(x,y)

            -- If there is nothing to protect, and we can move farther ahead
            -- unthreatened than this hold position, don't hold here
            local move_here = false
            if FGM.get_value(zone_map, x, y, 'in_zone') then
                move_here = true
                if (not protect_locs) then
                    local threats = FGM.get_value(move_data.enemy_attack_map[1], x, y, 'ids')

                    if (not threats) then
                        local eld = FGM.get_value(fred_data.ops_data.advance_distance_maps[zone_cfg.zone_id], x, y, 'forward')

                        if min_eleader_distance and (eld > min_eleader_distance) then
                            move_here = false
                        end
                    end
                end
            end

            local tmp_enemies = {}
            if move_here then
                for enemy_id,_ in pairs(move_data.enemies) do
                    local enemy_adj_hc = FGM.get_value(enemy_zone_maps[enemy_id], x, y, 'adj_hit_chance')

                    if enemy_adj_hc then
                        --std_print(x,y)
                        --std_print('  ', enemy_id, enemy_adj_hc)

                        local my_hc = 1 - FDI.get_unit_defense(move_data.unit_copies[id], x, y, fred_data.caches.defense_maps)
                        -- This is not directly a contribution to damage, it's just meant as a tiebreaker
                        -- Taking away good terrain from the enemy
                        local enemy_defense = 1 - FGM.get_value(enemy_zone_maps[enemy_id], x, y, 'hit_chance')
                        my_hc = my_hc - enemy_defense / 100

                        local att = fred_data.ops_data.unit_attacks[id][enemy_id]
                        local counter_max_taken = att.damage_counter.base_taken + att.damage_counter.extra_taken
                        local counter_actual_taken = my_hc * att.damage_counter.base_taken + att.damage_counter.extra_taken
                        local damage_taken = factor_counter * counter_actual_taken
                        damage_taken = damage_taken + factor_forward * (my_hc * att.damage_forward.base_taken + att.damage_forward.extra_taken)

                        local counter_max_done = att.damage_counter.base_done + att.damage_counter.extra_done
                        local counter_actual_done = enemy_adj_hc * att.damage_counter.base_done + att.damage_counter.extra_done
                        local damage_done = factor_counter * counter_actual_done
                        damage_done = damage_done + factor_forward * (enemy_adj_hc * att.damage_forward.base_done + att.damage_forward.extra_done)


                        -- Note: this is small (negative) for the strongest enemy
                        -- -> need to find minima the strongest enemies for this hex

                        if move_data.unit_infos[enemy_id].canrecruit then
                            damage_done = damage_done / leader_derating
                            damage_taken = damage_taken * leader_derating
                        end

                        local counter_rating = damage_done - damage_taken * value_ratio
                        table.insert(tmp_enemies, {
                            counter_max_taken = counter_max_taken,
                            counter_max_done = counter_max_done,
                            counter_actual_taken = counter_actual_taken,
                            counter_actual_done = counter_actual_done,
                            damage_taken = damage_taken,
                            damage_done = damage_done,
                            counter_rating = counter_rating,
                            enemy_id = enemy_id,
                            my_regen = att.my_regen,
                            enemy_regen = att.enemy_regen
                        })
                    end
                end

                -- Only keep the 3 strongest enemies (or fewer, if there are not 3)
                table.sort(tmp_enemies, function(a, b) return a.counter_rating < b.counter_rating end)
                local n = math.min(3, #tmp_enemies)
                for i = #tmp_enemies,n+1,-1 do
                    table.remove(tmp_enemies, i)
                end
            end

            if (#tmp_enemies > 0) then
                local damage_taken, damage_done = 0, 0
                local counter_actual_taken, counter_max_taken, counter_actual_damage = 0, 0, 0
                local enemy_value_loss = 0
                local cum_weight, n_enemies = 0, 0
                for _,enemy in pairs(tmp_enemies) do
                    local enemy_weight = enemy_weights[id][enemy.enemy_id].weight
                    --std_print('    ' .. id .. ' <-> ' .. enemy.enemy_id, enemy_weight, x .. ',' .. y, enemy.damage_taken, enemy.damage_done, enemy.counter_actual_taken, enemy.counter_actual_done, enemy.counter_max_taken)
                    cum_weight = cum_weight + enemy_weight
                    n_enemies = n_enemies + 1

                    damage_taken = damage_taken + enemy_weight * enemy.damage_taken

                    local frac_done = enemy.damage_done - enemy.enemy_regen
                    frac_done = frac_done / move_data.unit_infos[enemy.enemy_id].hitpoints
                    frac_done = FU.weight_s(frac_done, 0.5)
                    damage_done = damage_done + enemy_weight * frac_done * move_data.unit_infos[enemy.enemy_id].hitpoints

                    counter_actual_taken = counter_actual_taken + enemy.counter_actual_taken
                    counter_actual_damage = counter_actual_damage + enemy.counter_actual_taken - enemy.counter_actual_done
                    counter_max_taken = counter_max_taken + enemy.counter_max_taken

                    -- Enemy value loss is calculated per enemy whereas for the own unit, it
                    -- needs to be done on the sum (because of the non-linear weighting)
                    enemy_value_loss = enemy_value_loss
                        + FU.approx_value_loss(move_data.unit_infos[enemy.enemy_id], enemy.counter_actual_done, enemy.counter_max_done)

                    --std_print('  ', damage_taken, damage_done, cum_weight)
                end

                damage_taken = damage_taken / cum_weight * n_enemies
                damage_done = damage_done / cum_weight * n_enemies
                --std_print('  cum: ', damage_taken, damage_done, cum_weight)

                local my_value_loss, approx_ctd, unit_value = FU.approx_value_loss(move_data.unit_infos[id], counter_actual_taken, counter_max_taken)

                -- Yes, we are dividing the enemy value loss by our unit's value
                local value_loss = (my_value_loss - enemy_value_loss) / unit_value

                -- Healing bonus for villages
                local village_bonus = 0
                if FGM.get_value(move_data.village_map, x, y, 'owner') then
                    if move_data.unit_infos[id].abilities.regenerate then
                        -- Still give a bit of a bonus, to prefer villages if no other unit can get there
                        village_bonus = 2
                    else
                        village_bonus = 8
                    end
                end

                damage_taken = damage_taken - village_bonus - tmp_enemies[1].my_regen
                local frac_taken = damage_taken / move_data.unit_infos[id].hitpoints
                if (frac_taken) <= 1 then
                    frac_taken = FU.weight_s(frac_taken, 0.5)
                else
                    -- If this damage is higher than the unit's hitpoints, it needs
                    -- to be emphasized, not dampened. Note that this is not done
                    -- for the enemy, as enemy units for which this applies are
                    -- unlikely to attack.
                    frac_taken = frac_taken^2
                end
                damage_taken = frac_taken * move_data.unit_infos[id].hitpoints

                local av_outcome = damage_done - damage_taken * value_ratio
                --std_print(x .. ',' .. y, damage_taken, damage_done, village_bonus, av_outcome, value_ratio)

                if (not pre_rating_maps[id]) then
                    pre_rating_maps[id] = {}
                end
                FGM.set_value(pre_rating_maps[id], x, y, 'av_outcome', av_outcome)
                pre_rating_maps[id][x][y].counter_actual_taken = counter_actual_taken
                pre_rating_maps[id][x][y].counter_actual_damage = counter_actual_damage
                pre_rating_maps[id][x][y].counter_max_taken = counter_max_taken
                pre_rating_maps[id][x][y].my_value_loss = my_value_loss
                pre_rating_maps[id][x][y].enemy_value_loss = enemy_value_loss
                pre_rating_maps[id][x][y].value_loss = value_loss
                pre_rating_maps[id][x][y].approx_ctd = approx_ctd
                pre_rating_maps[id][x][y].x = x
                pre_rating_maps[id][x][y].y = y
                pre_rating_maps[id][x][y].id = id
            end
        end
    end

    if DBG.show_debug('hold_prerating_maps') then
        for id,pre_rating_map in pairs(pre_rating_maps) do
            DBG.show_fgm_with_message(pre_rating_map, 'av_outcome', 'Average outcome', move_data.unit_copies[id])
            --DBG.show_fgm_with_message(pre_rating_map, 'counter_actual_taken', 'Actual damage (taken) from counter attack', move_data.unit_copies[id])
            --DBG.show_fgm_with_message(pre_rating_map, 'counter_actual_damage', 'Actual damage (taken - done) from counter attack', move_data.unit_copies[id])
            --DBG.show_fgm_with_message(pre_rating_map, 'counter_max_taken', 'Max damage from counter attack', move_data.unit_copies[id])
            --DBG.show_fgm_with_message(pre_rating_map, 'approx_ctd', 'Approximate chance to die', move_data.unit_copies[id])
            --DBG.show_fgm_with_message(pre_rating_map, 'my_value_loss', 'My value loss', move_data.unit_copies[id])
            --DBG.show_fgm_with_message(pre_rating_map, 'enemy_value_loss', 'Enemy value loss', move_data.unit_copies[id])
            DBG.show_fgm_with_message(pre_rating_map, 'value_loss', 'Value loss', move_data.unit_copies[id])
            --DBG.show_fgm_with_message(pre_rating_map, 'influence', 'Influence', move_data.unit_copies[id])
        end
    end


    local hold_here_maps = {}
    for id,pre_rating_map in pairs(pre_rating_maps) do
        --std_print('----- ' .. id .. ' -----')
        hold_here_maps[id] = {}

        local hold_here_map = {}
        for x,y,data in FGM.iter(pre_rating_map) do
            FGM.set_value(hold_here_map, x, y, 'av_outcome', data.av_outcome)
        end

        local adj_hex_map = {}
        for x,y,data in FGM.iter(hold_here_map) do
            for xa,ya in H.adjacent_tiles(x,y) do
                if (not FGM.get_value(hold_here_map, xa, ya, 'av_outcome'))
                    and FGM.get_value(pre_rating_map, xa, ya, 'av_outcome')
                then
                    --std_print('adjacent :' .. x .. ',' .. y, xa .. ',' .. ya)
                    FGM.set_value(adj_hex_map, xa, ya, 'av_outcome', data.av_outcome)
                end
            end
        end
        for x,y,data in FGM.iter(adj_hex_map) do
            FGM.set_value(hold_here_map, x, y, 'av_outcome', data.av_outcome)
        end
        --DBG.show_fgm_with_message(hold_here_map, 'av_outcome', 'hold_here', move_data.unit_copies[id])

        local fraction_hp_missing = (move_data.unit_infos[id].max_hitpoints - move_data.unit_infos[id].hitpoints) / move_data.unit_infos[id].max_hitpoints
        local hp_rating = FU.weight_s(fraction_hp_missing, 0.5)
        local hp_damage_factor = 1 - hp_rating

        local acceptable_max_damage = acceptable_max_damage_ratio * move_data.unit_infos[id].hitpoints * hp_damage_factor
        local acceptable_actual_damage = acceptable_actual_damage_ratio * move_data.unit_infos[id].hitpoints * hp_damage_factor

        for x,y,data in FGM.iter(hold_here_map) do
            -- TODO: comment this out for now, but might need a condition like that again later
            --if (data.av_outcome >= 0) then
                local my_count = FGM.get_value(holders_influence, x, y, 'my_count')
                local enemy_count = FGM.get_value(holders_influence, x, y, 'enemy_count')

                -- TODO: comment this out for now, but might need a condition like that again later
                --if (my_count >= 3) then
                --    FGM.set_value(hold_here_maps[id], x, y, 'hold_here', true)
                --else
                    local value_loss = FGM.get_value(pre_rating_map, x, y, 'value_loss')
                    --std_print(string.format('  %d,%d: %5.3f  %5.3f', x, y, value_loss, rel_push_factor))

                    local approx_ctd = FGM.get_value(pre_rating_map, x, y, 'approx_ctd')
                    local is_acceptable_ctd = (approx_ctd <= acceptable_ctd)
                    --std_print(string.format('  %d,%d:  CtD   %5.3f  %6s   (%5.3f)', x, y, approx_ctd, tostring(is_acceptable_ctd), acceptable_ctd))

                    local max_damage = FGM.get_value(pre_rating_map, x, y, 'counter_max_taken')
                    local is_acceptable_max_damage = (max_damage <= acceptable_max_damage)
                    --std_print(string.format('  %d,%d:  MaxD  %5.3f  %6s   (%5.3f)', x, y, max_damage, tostring(is_acceptable_max_damage),  acceptable_max_damage))

                    -- counter_actual_damage does not include regeneration
                    -- Note that it is not included for the enemies either, but this is good enough for now.
                    -- This is the situation at the beginning of Fred's next turn, before enemies regenerate.
                    local actual_damage = FGM.get_value(pre_rating_map, x, y, 'counter_actual_damage')
                    if move_data.unit_infos[id].abilities.regenerate then
                        actual_damage = actual_damage - 8
                    end
                    local is_acceptable_actual_damage = (actual_damage <= acceptable_actual_damage)
                    --std_print(string.format('  %d,%d:  ActD  %5.3f  %6s   (%5.3f)', x, y, actual_damage, tostring(is_acceptable_actual_damage),  acceptable_actual_damage))

                    -- The overall push forward must be worth it
                    -- AND it should not be too far ahead of the front
                    -- TODO: currently these are done individually; not sure if
                    --   these two conditions should be combined (multiplied)
                    if is_acceptable_ctd and is_acceptable_max_damage and is_acceptable_actual_damage then
                        FGM.set_value(hold_here_maps[id], x, y, 'hold_here', true)

                        local ld = FGM.get_value(fred_data.ops_data.leader_distance_map, x, y, 'distance')
                        if (ld > front_ld + 1) then
                            local advance_factor = 1 / (ld - front_ld)

                            advance_factor = advance_factor
                            --FGM.set_value(hold_here_maps[id], x, y, 'hold_here', value_loss)
                            --std_print(x, y, ld, front_ld, f)

                            if (value_loss < - advance_factor) then
                                FGM.set_value(hold_here_maps[id], x, y, 'hold_here', false)
                            end
                        end
                    end
                --end
            --end
        end
    end

    local protect_here_maps = {}
    if protect_locs then
        for id,pre_rating_map in pairs(pre_rating_maps) do
            protect_here_maps[id] = {}
            for x,y,data in FGM.iter(pre_rating_map) do
                -- TODO: do we even need protect_here_maps any more? Just use between_map.is_between directly?
                if FGM.get_value(between_map, x, y, 'is_between') then
                    FGM.set_value(protect_here_maps[id], x, y, 'protect_here', true)
                end
            end
        end
    end

    if (not next(hold_here_maps)) and (not next(protect_here_maps)) then return end

    if DBG.show_debug('hold_here_map') then
        for id,hold_here_map in pairs(hold_here_maps) do
            DBG.show_fgm_with_message(hold_here_map, 'hold_here', 'hold_here', move_data.unit_copies[id])
        end
        for id,protect_here_map in pairs(protect_here_maps) do
            DBG.show_fgm_with_message(protect_here_map, 'protect_here', 'protect_here', move_data.unit_copies[id])
        end
    end

    local goal = fred_data.ops_data.hold_goals[zone_cfg.zone_id]
    --DBG.dbms(goal, false, 'goal')
    local ADmap = fred_data.ops_data.advance_distance_maps[zone_cfg.zone_id]
    local goal_forward = FGM.get_value(ADmap, goal[1], goal[2], 'forward')
    --std_print(zone_cfg.zone_id .. ' hold_goal: ' .. (goal[1] or -1) .. ',' .. (goal[2] or -1), goal_forward)

    local hold_rating_maps = {}
    for id,hold_here_map in pairs(hold_here_maps) do
        local max_moves = move_data.unit_infos[id].max_moves
        --std_print('\n' .. id, zone_cfg.zone_id)
        local max_vuln = - math.huge
        for x,y,hold_here_data in FGM.iter(hold_here_map) do
            if hold_here_data.hold_here then
                local vuln = FGM.get_value(move_data.influence_maps, x, y, 'vulnerability') or 0

                if (vuln > max_vuln) then
                    max_vuln = vuln
                end

                if (not hold_rating_maps[id]) then
                    hold_rating_maps[id] = {}
                end
                FGM.set_value(hold_rating_maps[id], x, y, 'vuln', vuln)
            end
        end

        if hold_rating_maps[id] then
            for x,y,hold_rating_data in FGM.iter(hold_rating_maps[id]) do
                local base_rating = FGM.get_value(pre_rating_maps[id], x, y, 'av_outcome')

                base_rating = base_rating / move_data.unit_infos[id].max_hitpoints
                base_rating = (base_rating + 1) / 2
                base_rating = FU.weight_s(base_rating, 0.75)

                local vuln_rating = base_rating + hold_rating_data.vuln / max_vuln * vuln_rating_weight

                local forward = FGM.get_value(ADmap, x, y, 'forward')
                local perp = FGM.get_value(ADmap, x, y, 'perp') -- don't need sign here, as no difference is calculated

                -- TODO: this is not good, should really expand the map in the first place
                if (not forward) then
                    forward = wesnoth.map.distance_between(x, y, goal[1], goal[2]) + goal_forward
                    perp = 10
                end

                local df = math.abs(forward - goal_forward) / max_moves
                local dp = math.abs(perp) / max_moves
                local cost = df ^ 1.5 + dp ^ 2
                cost = cost * max_moves

                vuln_rating = vuln_rating - forward_rating_weight * cost

                hold_rating_data.base_rating = base_rating
                hold_rating_data.vuln_rating = vuln_rating
                hold_rating_data.x = x
                hold_rating_data.y = y
                hold_rating_data.id = id
            end
        end
    end
    --DBG.dbms(hold_rating_maps, false, 'hold_rating_maps')

    -- If protecting is needed, do not do a no-protect hold with fewer
    -- than 3 units, unless that's all the holders available
    if protect_locs then
        local n_units,n_holders = 0, 0
        for _,_ in pairs(hold_rating_maps) do n_units = n_units + 1 end
        for _,_ in pairs(holders) do n_holders = n_holders + 1 end
        --std_print(n_units, n_holders)

        if (n_units < 3) and (n_units < n_holders) then
            hold_rating_maps = {}
        end
    end

    -- Add bonus for other strong hexes aligned *across* the direction
    -- of advancement of the enemies
    --FHU.convolve_rating_maps(hold_rating_maps, 'vuln_rating', between_map, fred_data.ops_data)

    if DBG.show_debug('hold_rating_maps') then
        for id,hold_rating_map in pairs(hold_rating_maps) do
            DBG.show_fgm_with_message(hold_rating_map, 'base_rating', 'base_rating', move_data.unit_copies[id])
            DBG.show_fgm_with_message(hold_rating_map, 'vuln_rating', 'vuln_rating_org', move_data.unit_copies[id])
            --DBG.show_fgm_with_message(hold_rating_map, 'conv', 'conv', move_data.unit_copies[id])
            --DBG.show_fgm_with_message(hold_rating_map, 'vuln_rating', 'vuln_rating', move_data.unit_copies[id])
        end
    end


    local max_inv_cost = - math.huge
    if between_map then
        for _,protect_loc in ipairs(protect_locs) do
            local inv_cost = FGM.get_value(between_map, protect_loc[1], protect_loc[2], 'inv_cost') or 0
            if (inv_cost > max_inv_cost) then
                max_inv_cost = inv_cost
            end
        end
    end

    local protect_rating_maps = {}
    for id,protect_here_map in pairs(protect_here_maps) do
        local max_vuln = - math.huge
        for x,y,protect_here_data in FGM.iter(protect_here_map) do
            if protect_here_data.protect_here then
                local vuln = FGM.get_value(holders_influence, x, y, 'vulnerability')

                if (vuln > max_vuln) then
                    max_vuln = vuln
                end

                if (not protect_rating_maps[id]) then
                    protect_rating_maps[id] = {}
                end
                FGM.set_value(protect_rating_maps[id], x, y, 'vuln', vuln)
            end
        end

        if protect_rating_maps[id] then
            for x,y,protect_rating_data in FGM.iter(protect_rating_maps[id]) do
                local protect_base_rating, cum_weight = 0, 0

                local my_defense = FDI.get_unit_defense(move_data.unit_copies[id], x, y, fred_data.caches.defense_maps)
                local scaled_my_defense = FU.weight_s(my_defense, 0.67)

                for enemy_id,enemy_zone_map in pairs(enemy_zone_maps) do
                    local enemy_adj_hc = FGM.get_value(enemy_zone_map, x, y, 'adj_hit_chance')
                    if enemy_adj_hc then
                        local enemy_defense = 1 - FGM.get_value(enemy_zone_map, x, y, 'hit_chance')
                        local scaled_enemy_defense = FU.weight_s(enemy_defense, 0.67)
                        local scaled_enemy_adj_hc = FU.weight_s(enemy_adj_hc, 0.67)

                        local enemy_weight = enemy_weights[id][enemy_id].weight

                        local rating = scaled_enemy_adj_hc
                        -- TODO: shift more toward weak enemy terrain at small value_ratio?
                        rating = rating + (scaled_enemy_adj_hc + scaled_my_defense + scaled_enemy_defense / 100) * value_ratio
                        protect_base_rating = protect_base_rating + rating * enemy_weight

                        cum_weight = cum_weight + enemy_weight
                    end
                end

                local protect_base_rating = protect_base_rating / cum_weight
                --std_print('  ' .. x .. ',' .. y .. ': ' .. protect_base_rating, cum_weight)

                if FGM.get_value(move_data.village_map, x, y, 'owner') then
                    -- Prefer strongest unit on village (for protection)
                    -- Potential TODO: we might want this conditional on the threat to the village
                    protect_base_rating = protect_base_rating + 0.1 * move_data.unit_infos[id].hitpoints / 25 * value_ratio

                    -- For non-regenerating units, we also give a heal bonus
                    if (not move_data.unit_infos[id].abilities.regenerate) then
                        protect_base_rating = protect_base_rating + 0.25 * 8 / 25 * value_ratio
                    end
                end

                -- TODO: check if this is the right metric when between map does not exist
                local inv_cost = 0
                if between_map then
                    inv_cost = FGM.get_value(between_map, x, y, 'inv_cost') or 0
                end
                local d_dist = inv_cost - (max_inv_cost or 0)
                local protect_rating = protect_base_rating
                if (protect_forward_rating_weight > 0) then
                    local vuln = protect_rating_data.vuln
                    local terrain_mult = FDI.get_unit_defense(move_data.unit_copies[id], x, y, fred_data.caches.defense_maps)
                    protect_rating = protect_rating + vuln / max_vuln * protect_forward_rating_weight * terrain_mult
                else
                    protect_rating = protect_rating + (d_dist - 2) / 10 * protect_forward_rating_weight
                end

                -- TODO: this might be too simplistic
                if protect_objectives.protect_leader then
                    local mult = 0
                    local power_ratio = fred_data.ops_data.behavior.orders.base_power_ratio
                    if (power_ratio < 1) then
                        mult = (1 / power_ratio - 1)
                    end

                    protect_rating = protect_rating * (1 - mult * (d_dist / 100))
                end

                protect_rating_data.protect_base_rating = protect_base_rating
                protect_rating_data.protect_rating = protect_rating
                protect_rating_data.x = x
                protect_rating_data.y = y
                protect_rating_data.id = id
            end
        end
    end

    -- Add bonus for other strong hexes aligned *across* the direction
    -- of advancement of the enemies
    --FHU.convolve_rating_maps(protect_rating_maps, 'protect_rating', between_map, fred_data.ops_data)

    if DBG.show_debug('hold_protect_rating_maps') then
        for id,protect_rating_map in pairs(protect_rating_maps) do
            DBG.show_fgm_with_message(protect_rating_map, 'protect_base_rating', 'protect_base_rating', move_data.unit_copies[id])
            DBG.show_fgm_with_message(protect_rating_map, 'protect_rating', 'protect_rating_org', move_data.unit_copies[id])
            --DBG.show_fgm_with_message(protect_rating_map, 'vuln', 'vuln', move_data.unit_copies[id])
            --DBG.show_fgm_with_message(protect_rating_map, 'conv', 'conv', move_data.unit_copies[id])
            --DBG.show_fgm_with_message(protect_rating_map, 'protect_rating', 'protect_rating', move_data.unit_copies[id])
        end
    end

    if (not next(hold_rating_maps)) and (not next(protect_rating_maps)) then
        return
    end


    -- Map of adjacent villages that can be reached by the enemy
    local adjacent_village_map = {}
    for x,y,_ in FGM.iter(move_data.village_map) do
        if FGM.get_value(zone_map, x, y, 'in_zone') then

            local can_reach = false
            for enemy_id,enemy_zone_map in pairs(enemy_zone_maps) do
                if FGM.get_value(enemy_zone_map, x, y, 'moves_left') then
                    can_reach = true
                    break
                end
            end

            if can_reach then
                for xa,ya in H.adjacent_tiles(x,y) do
                    -- Eventual TODO: this currently only works for one adjacent village
                    -- which is fine on the Freelands map, but might not be on others
                    FGM.set_value(adjacent_village_map, xa, ya, 'village_xy', 1000 * x + y)
                end
            end
        end
    end
    --DBG.dbms(adjacent_village_map, false, 'adjacent_village_map')

    if false then
        DBG.show_fgm_with_message(adjacent_village_map, 'village_xy', 'Adjacent vulnerable villages')
    end


    local cfg_combos = {
        max_units = max_units,
        max_hexes = max_hexes
    }
    local cfg_best_combo_hold = { zone_id = zone_cfg.zone_id, value_ratio = value_ratio }
    local cfg_best_combo_protect = {
        zone_id = zone_cfg.zone_id,
        protect_objectives = protect_objectives, -- TODO: can we not just get this from ops_data?
        find_best_protect_only = zone_cfg.find_best_protect_only,
        value_ratio = value_ratio
    }

    local combo_table = { hold = {}, all_hold = {}, protect = {}, all_protect = {} }

    -- TODO: also don't need some of the previous steps if find_best_protect_only == true
    if (not zone_cfg.find_best_protect_only) and (next(hold_rating_maps)) then
        --std_print('--> checking hold combos ' .. zone_cfg.zone_id)
        local hold_dst_src, hold_ratings = FHU.unit_rating_maps_to_dstsrc(hold_rating_maps, 'vuln_rating', move_data, cfg_combos)
        local hold_combos = FU.get_unit_hex_combos(hold_dst_src)
        --DBG.dbms(hold_combos, false, 'hold_combos')
        --std_print('#hold_combos ' .. zone_cfg.zone_id, #hold_combos)

        local best_hold_combo, all_best_hold_combo, combo_strs = FHU.find_best_combo(hold_combos, hold_ratings, 'vuln_rating', adjacent_village_map, between_map, fred_data, cfg_best_combo_hold)
        --DBG.dbms(combo_strs, false, 'combo_strs')

        -- There's some duplication in this table, that's just to make it easier later.
        combo_table.hold = {
            combo = best_hold_combo,
            protected_str = combo_strs.protected_str,
            protect_obj_str = combo_strs.protect_obj_str
        }
        combo_table.all_hold = {
            combo = all_best_hold_combo,
            protected_str = combo_strs.all_protected_str,
            protect_obj_str = combo_strs.protect_obj_str
        }

    end

    if protect_locs and next(protect_rating_maps) then
        --std_print('--> checking protect combos ' .. zone_cfg.zone_id)
        local protect_dst_src, protect_ratings = FHU.unit_rating_maps_to_dstsrc(protect_rating_maps, 'protect_rating', move_data, cfg_combos)
        local protect_combos = FU.get_unit_hex_combos(protect_dst_src)
        --DBG.dbms(protect_combos, false, 'protect_combos')
        --std_print('#protect_combos ' .. zone_cfg.zone_id, #protect_combos)

        local best_protect_combo, all_best_protect_combo, protect_combo_strs = FHU.find_best_combo(protect_combos, protect_ratings, 'protect_rating', adjacent_village_map, between_map, fred_data, cfg_best_combo_protect)
        --DBG.dbms(protect_combo_strs, false, 'protect_combo_strs')

        -- If no combo that protects the location was found, use the best of the others
        -- TODO: check whether it is better to use a normal hold in this case; may depend on
        --   how desperately we want to protect
--        if (not best_protect_combo) then
--            best_protect_combo = all_best_protect_combo
--        end

        -- There's some duplication in this table, that's just to make it easier later.
        combo_table.protect = {
            combo = best_protect_combo,
            protected_str = protect_combo_strs.protected_str,
            protect_obj_str = protect_combo_strs.protect_obj_str
        }
        combo_table.all_protect = {
            combo = all_best_protect_combo,
            protected_str = protect_combo_strs.all_protected_str,
            protect_obj_str = protect_combo_strs.protect_obj_str
        }
    end
    --DBG.dbms(combo_table, false, 'combo_table')

    if (not combo_table.hold.combo) and (not combo_table.all_hold.combo)
        and (not combo_table.protect.combo) and (not combo_table.all_protect.combo)
    then
        return
    end


    local action_str = zone_cfg.action_str
    local best_combo_type
    if (not combo_table.hold.combo) and (not combo_table.protect.combo) and (not combo_table.all_protect.combo) then
        -- Only as a last resort do we use all_best_hold_combo
        best_combo_type = 'all_hold'
    elseif (not combo_table.hold.combo) then
        if combo_table.protect.combo then
            best_combo_type = 'protect'
        else
            best_combo_type = 'all_protect'
        end
    elseif (not combo_table.protect.combo) then
        best_combo_type = 'hold'
    else
        -- TODO: if there is a best_protect_combo, should we always use it over best_hold_combo?
        --   This would also mean that we do not need to evaluate best_hold_combo if best_protect_combo is found
        local hold_distance, count = 0, 0
        for src,dst in pairs(combo_table.hold.combo) do
            local x, y =  math.floor(dst / 1000), dst % 1000
            local ld = FGM.get_value(fred_data.ops_data.leader_distance_map, x, y, 'distance')
            hold_distance = hold_distance + ld
            count = count + 1
        end
        hold_distance = hold_distance / count

        local protect_distance, count = 0, 0
        for src,dst in pairs(combo_table.protect.combo) do
            local x, y =  math.floor(dst / 1000), dst % 1000
            local ld = FGM.get_value(fred_data.ops_data.leader_distance_map, x, y, 'distance')
            protect_distance = protect_distance + ld
            count = count + 1
        end
        protect_distance = protect_distance / count

        --std_print(hold_distance, protect_distance)

        -- Potential TODO: this criterion might be too simple
        if (hold_distance > protect_distance + 1) then
            best_combo_type = 'hold'
        else
            best_combo_type = 'protect'
        end
    end
    --std_print('best_combo_type: ' .. best_combo_type)

    if DBG.show_debug('hold_best_combo') then
        local function show_hold_units(combo_type, combo_str, no_protect_locs_str)
            if combo_table[combo_type].combo then
                local av_x, av_y, count = 0, 0, 0
                for src,dst in pairs(combo_table[combo_type].combo) do
                    local src_x, src_y =  math.floor(src / 1000), src % 1000
                    local dst_x, dst_y =  math.floor(dst / 1000), dst % 1000
                    local id = move_data.my_unit_map[src_x][src_y].id
                    wesnoth.label { x = dst_x, y = dst_y, text = id }
                    av_x, av_y, count = av_x + dst_x, av_y + dst_y, count + 1
                end
                av_x, av_y = av_x / count, av_y / count
                wesnoth.scroll_to_tile(av_x, av_y + 2)
                wesnoth.wml_actions.message {
                    speaker = 'narrator',
                    caption = combo_str .. ' [' .. zone_cfg.zone_id .. ']',
                    message = 'Protect objectives: ' .. combo_table[combo_type].protect_obj_str .. '\nAction: ' .. action_str .. '\n    ' .. (combo_table[combo_type].protected_str or '')
                }
                for src,dst in pairs(combo_table[combo_type].combo) do
                    local dst_x, dst_y =  math.floor(dst / 1000), dst % 1000
                    wesnoth.label { x = dst_x, y = dst_y, text = "" }
                end
            else
                wesnoth.wml_actions.message {
                    speaker = 'narrator',
                    caption = combo_str .. ' [' .. zone_cfg.zone_id .. ']',
                    message = 'Protect objectives: ' .. (combo_table[combo_type].protect_obj_str or no_protect_locs_str or 'None') .. '\nAction: ' .. (no_protect_locs_str or 'None found')
                }
            end
        end

        for _,unit in ipairs(fred_data.ops_data.place_holders) do
            wesnoth.label { x = unit[1], y = unit[2], text = 'recruit\n' .. unit.type, color = '160,160,160' }
        end
        wesnoth.label { x = leader_goal[1], y = leader_goal[2], text = 'leader goal', color = '200,0,0' }

        local no_protect_locs_str
        if (not protect_locs) then no_protect_locs_str = 'no protect locs' end
        show_hold_units('protect', 'Best protect combo', no_protect_locs_str)
        show_hold_units('all_protect', 'All best protect combo', no_protect_locs_str)
        show_hold_units('hold', 'Best hold combo')
        show_hold_units('all_hold', 'All best hold combo')
        show_hold_units(best_combo_type, 'Overall best combo')

        wesnoth.label { x = leader_goal[1], y = leader_goal[2], text = "" }
        for _,unit in ipairs(fred_data.ops_data.place_holders) do
            wesnoth.label { x = unit[1], y = unit[2], text = "" }
        end
    end


    if protect_locs then
        action_str = action_str  .. '\n    ' .. combo_table[best_combo_type].protected_str
    end
    local action = {
        action_str = action_str,
        units = {},
        dsts = {}
    }
    for src,dst in pairs(combo_table[best_combo_type].combo) do
        src_x, src_y =  math.floor(src / 1000), src % 1000
        dst_x, dst_y =  math.floor(dst / 1000), dst % 1000
        local id = move_data.my_unit_map[src_x][src_y].id

        local tmp_unit = move_data.my_units[id]
        tmp_unit.id = id
        table.insert(action.units, tmp_unit)
        table.insert(action.dsts, { dst_x, dst_y })
    end
    --DBG.dbms(action, false, 'action')

    local score = zone_cfg.rating
    if (best_combo_type == 'hold') then
        if zone_cfg.second_rating and (zone_cfg.second_rating > 0) then
            score = zone_cfg.second_rating
        end
    end
    --std_print('score: ' .. score)
    action.score = score

    return action
end

return fred_hold
