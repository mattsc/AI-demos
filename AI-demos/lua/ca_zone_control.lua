local H = wesnoth.require "helper"
local AH = wesnoth.require "ai/lua/ai_helper.lua"
local AHL = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper_local.lua"
local FGM = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_map.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local FS = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_status.lua"
local FVS = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_virtual_state.lua"
local FBU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_benefits_utilities.lua"
local FDI = wesnoth.require "~/add-ons/AI-demos/lua/fred_data_incremental.lua"
local FDM = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_data_move.lua"
local FDT = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_data_turn.lua"
local FOU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_ops_utils.lua"
local FA = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack.lua"
local FAU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack_utils.lua"
local FMU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_map_utils.lua"
local LS = wesnoth.require "location_set"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"
local FRU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_retreat_utils.lua"
local FHU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_hold_utils.lua"
local FMLU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_move_leader_utils.lua"
local FCFG = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_config.lua"
local FMC = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_map_config.lua"
local COMP = wesnoth.require "~/add-ons/AI-demos/lua/compatibility.lua"


----- Hold: -----
local function get_hold_action(zone_cfg, fred_data)
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


----- Advance: -----
local function get_advance_action(zone_cfg, fred_data)
    -- Advancing is now only moving onto unthreatened hexes; everything
    -- else should be covered by holding, village grabbing, protecting, etc.

    DBG.print_debug_time('eval', fred_data.turn_start_time, '  - advance evaluation: ' .. zone_cfg.zone_id .. ' (' .. string.format('%.2f', zone_cfg.rating) .. ')')

    --DBG.dbms(zone_cfg, false, 'zone_cfg')
    local raw_cfg = FMC.get_raw_cfgs(zone_cfg.zone_id)
    --DBG.dbms(raw_cfg, false, 'raw_cfg')

    local move_data = fred_data.move_data

    -- Advancers are those specified in zone_units, or all units except the leader otherwise
    local advancers = {}
    if zone_cfg.zone_units then
        advancers = zone_cfg.zone_units
    else
        for id,_ in pairs(move_data.my_units_MP) do
            if (not move_data.unit_infos[id].canrecruit) then
                advancers[id] = { move_data.my_units[id][1], move_data.my_units[id][2] }
            end
        end
    end
    if (not next(advancers)) then return end

    -- Maps of hexes to be avoided for each unit
    -- Currently this is only the final leader position
    local avoid_maps = {}
    local leader_goal = fred_data.ops_data.objectives.leader.final
    for id,_ in pairs(advancers) do
        avoid_maps[id] = {}
        if (id ~= move_data.my_leader.id) then
            FGM.set_value(avoid_maps[id], leader_goal[1], leader_goal[2], 'avoid', true)
        end
    end

    local value_ratio = zone_cfg.value_ratio or fred_data.ops_data.behavior.orders.value_ratio
    --std_print('value_ratio: ' .. zone_cfg.zone_id, value_ratio)
    -- Push factors are only set for zones with assigned enemies.
    --local push_factor = fred_data.ops_data.behavior.zone_push_factors[zone_cfg.zone_id] or 1
    local push_factor = fred_data.ops_data.behavior.orders.push_factor
    --std_print('push_factor: ' .. zone_cfg.zone_id, push_factor)


    -- If we got here and nobody is holding already, that means a hold was attempted (with the same units
    -- now used for advancing) and either not possible or not deemed worth it.
    -- Either way, we should be careful with advancing into enemy threats.
    local already_holding = true
    if (not next(fred_data.ops_data.objectives.protect.zones[zone_cfg.zone_id].holders)) then
        already_holding = false
    end
    --std_print(zone_cfg.zone_id .. ': already_holding: ', already_holding)


    -- Map of adjacent villages that can be reached by the enemy
    -- TODO: this currently ignores that the advancing unit itself might block the village from the enemy
    local adjacent_village_map = {}
    for x,y,_ in FGM.iter(move_data.village_map) do
        for enemy_id,_ in pairs(move_data.enemies) do
            local moves_left = FGM.get_value(move_data.reach_maps[enemy_id], x, y, 'moves_left')
            if moves_left then
                for xa,ya in H.adjacent_tiles(x,y) do
                    FGM.set_value(adjacent_village_map, xa, ya, 'village_xy', 1000 * x + y)
                end
            end
        end
    end
    if false then
        DBG.show_fgm_with_message(adjacent_village_map, 'village_xy', 'Adjacent vulnerable villages')
    end


    local safe_loc = false
    local unit_rating_maps = {}
    local max_rating, best_id, best_hex = - math.huge
    for id,xy in pairs(advancers) do
        local unit_loc = { math.floor(xy / 1000), xy % 1000 }
        -- Don't use ops_slf here, but pre-calculated zone_maps. The zone_map used can be
        -- different from that in the SLF, e.g. for the leader zone or if parts of a zone are
        -- to be avoided (the latter is not implemented yet).
        local is_unit_in_zone = FGM.get_value(fred_data.ops_data.zone_maps[zone_cfg.zone_id], unit_loc[1], unit_loc[2], 'in_zone')
        --std_print('is_unit_in_zone: ' .. id, zone_cfg.zone_id, is_unit_in_zone)

        unit_rating_maps[id] = {}

        local unit_value = move_data.unit_infos[id].unit_value

        -- Fastest unit first, after that strongest unit first
        -- These are small, mostly just tie breakers
        local max_moves = move_data.unit_infos[id].max_moves
        local rating_moves = move_data.unit_infos[id].moves / 10
        local rating_power = move_data.unit_infos[id].current_power / 1000

        -- Injured units are treated much more carefully by the AI.
        -- This part sets up a number of parameters for that.
        local fraction_hp_missing = (move_data.unit_infos[id].max_hitpoints - move_data.unit_infos[id].hitpoints) / move_data.unit_infos[id].max_hitpoints
        local hp_rating = FU.weight_s(fraction_hp_missing, 0.5)
        local hp_forward_factor = 1 - hp_rating
        -- The more injured the unit, the closer to 1 a value_ratio we use
        local unit_value_ratio = value_ratio + (1 - value_ratio) * hp_rating
        --std_print('unit_value_ratio', unit_value_ratio, value_ratio)
        local cfg_attack = { value_ratio = unit_value_ratio }

        local goal = fred_data.ops_data.advance_goals[zone_cfg.zone_id]
        local cost_map = {}
        if is_unit_in_zone then
            -- If the unit is in the zone, use the ops advance_distance_maps
            local ADmap = fred_data.ops_data.advance_distance_maps[zone_cfg.zone_id]
            local goal_forward = FGM.get_value(ADmap, goal[1], goal[2], 'forward')
            local goal_perp = FGM.get_value(ADmap, goal[1], goal[2], 'perp')
            goal_perp = goal_perp * FGM.get_value(ADmap, goal[1], goal[2], 'sign')
            --std_print('goal forward, perp: ' .. goal_forward .. ', ' .. goal_perp)
            for x,y,_ in FGM.iter(move_data.effective_reach_maps[id]) do
                if (not FGM.get_value(avoid_maps[id], x, y, 'avoid')) then
                    local forward = FGM.get_value(ADmap, x, y, 'forward')
                    local perp = FGM.get_value(ADmap, x, y, 'perp')

                    -- TODO: this is not good, should really expand the map in the first place
                    if (not forward) then
                        forward = wesnoth.map.distance_between(x, y, goal[1], goal[2]) + goal_forward
                        perp = 10
                    end

                    perp = perp * (FGM.get_value(ADmap, x, y, 'sign') or 1)

                    local df = math.abs(forward - goal_forward)
                    local dp = math.abs(perp - goal_perp)

                    -- We want to emphasize that small offsets are ok, but then have it increase quickly
                    --[[ TODO: probably don't want to do this, but leave code for now until sure
                    for xa,ya in H.adjacent_tiles(x, y) do
                        local adj_forward = FGM.get_value(ADmap, xa, ya, 'forward')
                        local apj_perp = FGM.get_value(ADmap, xa, ya, 'perp')
                        if adj_forward then
                            apj_perp = apj_perp * FGM.get_value(ADmap, xa, ya, 'sign')

                            adj_df = math.abs(adj_forward - goal_forward)
                            adj_dp = math.abs(apj_perp - goal_perp)
                            if (adj_df < df) then df = adj_df end
                            if (adj_dp < dp) then dp = adj_dp end
                        end
                    end
                    --]]

                    local cost = (df / max_moves)^ 1.5 + (dp / max_moves) ^ 2
                    cost = cost * max_moves

                    FGM.set_value(cost_map, x, y, 'cost', cost)
                    --cost_map[x][y].forward = forward
                    --cost_map[x][y].perp = perp
                    cost_map[x][y].df = df
                    cost_map[x][y].dp = dp
                end
            end
        else
            -- If the unit is not in the zone, move toward the goal hex via a path
            -- that has a penalty rating for hexes with overall negative full-move
            -- influence. This is done so that units take a somewhat longer router around
            -- the back of a zone rather than taking the shorter route straight
            -- into the middle of the enemies.
            -- TODO: this might have to be done differently for maps other than Freelands

            local unit_copy = move_data.unit_copies[id]
            local unit_infl = move_data.unit_infos[id].current_power
            -- We're doing this out here, so that it has not be done for each hex in the custom cost function
            local influence_mult = 1 / unit_infl
            --std_print('unit out of zone: ' .. id, unit_infl, influence_mult)
            --local path, cost = wesnoth.find_path(unit_copy, goal[1], goal[2], { ignore_units = true })
            local path, cost = COMP.find_path_custom_cost(unit_copy, goal[1], goal[2], function(x, y, current_cost)
                return FMU.influence_custom_cost(x, y, unit_copy, influence_mult, move_data.influence_maps, fred_data)
            end)

            -- Debug code for showing the path
            if false then
                local path_map = {}
                for _,loc in ipairs(path) do
                    FGM.set_value(path_map, loc[1], loc[2], 'cost', loc[3])
                end
                DBG.show_fgm_with_message(path_map, 'cost', 'path_map', unit_copy[id])
            end

            -- Find the hex one past the last the unit can reach
            -- This ignores enemies etc. but that should be fine
            local total_cost, path_goal_hex = 0
            for i = 2,#path do
                local x, y = path[i][1], path[i][2]
                local movecost = FDI.get_unit_movecost(unit_copy, x, y, fred_data.caches.movecost_maps)
                total_cost = total_cost + movecost
                --std_print(i, x, y, movecost, total_cost)
                path_goal_hex = path[i] -- This also works when the path is shorter than the unit's moves
                if (total_cost > move_data.unit_infos[id].moves) then
                    break
                end
            end
            --std_print('path goal hex: ', path_goal_hex[1], path_goal_hex[2])

            local cm = wesnoth.find_cost_map(
                { type = "xyz" }, -- SUF not matching any unit
                { { path_goal_hex[1], path_goal_hex[2], wesnoth.current.side, fred_data.move_data.unit_infos[id].type } },
                { ignore_units = true }
            )

            for _,cost in pairs(cm) do
                if (cost[3] > -1) then
                    FGM.add(cost_map, cost[1], cost[2], 'cost', cost[3])
                end
            end
        end

        if DBG.show_debug('advance_cost_maps') then
            --DBG.show_fgm_with_message(cost_map, 'forward', zone_cfg.zone_id ..': advance cost map forward', move_data.unit_copies[id])
            --DBG.show_fgm_with_message(cost_map, 'perp', zone_cfg.zone_id ..': advance cost map perp', move_data.unit_copies[id])
            DBG.show_fgm_with_message(cost_map, 'df', zone_cfg.zone_id ..': advance cost map delta forward', move_data.unit_copies[id])
            DBG.show_fgm_with_message(cost_map, 'dp', zone_cfg.zone_id ..': advance cost map delta perp', move_data.unit_copies[id])
            DBG.show_fgm_with_message(cost_map, 'cost', zone_cfg.zone_id ..': advance cost map', move_data.unit_copies[id])
        end

        -- Use a more defensive rating for units that have been isolated in enemy territory.
        -- However, we do not know whether that is a case until the end of the analysis,
        -- so we carry both ratings throughout that and use a flag that gets set along the way.
        local unit_df = FGM.get_value(cost_map, unit_loc[1], unit_loc[2], 'df')
        local use_defensive_rating = false
        -- TODO: the condition excludes units outside the zone; should they be included?
        if unit_df and (unit_df > 2) then
            use_defensive_rating = true
        end
        --std_print(id .. ' unit_df: ', unit_df, use_defensive_rating)

        local max_unit_rating, best_unit_hex = - math.huge
        local max_unit_def_rating, best_unit_def_hex = - math.huge
        for x,y,_ in FGM.iter(move_data.effective_reach_maps[id]) do
            if (not FGM.get_value(avoid_maps[id], x, y, 'avoid')) then
                local rating = rating_moves + rating_power
                FGM.set_value(unit_rating_maps[id], x, y, 'unit_rating', rating)

                -- Counter attack outcome
                local unit_moved = {}
                unit_moved[id] = { x, y }
                local old_locs = { { unit_loc[1], unit_loc[2] } }
                local new_locs = { { x, y } }
                -- TODO: Use FVS here also?
                local counter_outcomes = FAU.calc_counter_attack(
                    unit_moved, old_locs, new_locs, fred_data.ops_data.place_holders, nil, cfg_attack, fred_data
                )

                if counter_outcomes then
                    --DBG.dbms(counter_outcomes, false, 'counter_outcomes')
                    --std_print('  die_chance', counter_outcomes.def_outcome.hp_chance[0], id .. ': ' .. x .. ',' .. y)

                    -- This is the standard attack rating (roughly) in units of cost (gold)
                    local counter_rating = 0

--                    if already_holding then
--                        counter_rating = - counter_outcomes.rating_table.max_weighted_rating
                        --std_print(x .. ',' .. y .. ': counter' , counter_rating, unit_value_ratio)
--                    else
                        -- If nobody is holding, that means that the hold with these units was
                        -- considered not worth it, which means we should be much more careful
                        -- advancing them as well -> use mostly own damage rating
                        local _, damage_rating, heal_rating = FAU.damage_rating_unit(counter_outcomes.defender_damage)
                        local enemy_rating = 0
                        for _,attacker_damage in ipairs(counter_outcomes.attacker_damages) do
                            local _, er, ehr = FAU.damage_rating_unit(attacker_damage)
                            enemy_rating = enemy_rating + er + ehr
                        end
                        --std_print(x .. ',' .. y .. ': damage: ', counter_outcomes.defender_damage.damage, damage_rating, heal_rating)
                        --std_print('  enemy rating:', enemy_rating)

                        -- Note that damage ratings are negative
                        counter_rating = damage_rating + heal_rating
                        counter_rating = counter_rating - enemy_rating / 10
--                    end

                    -- The die chance is already included in the rating, but we
                    -- want it to be even more important here (and very non-linear)
                    -- It's set to be quadratic and take unity value at the desperate attack
                    -- hp_chance[0]=0.85; but then it is the difference between die chances that
                    -- really matters, so we multiply by another factor 2.
                    -- This makes this a huge contribution to the rating.
                    local die_rating = - unit_value_ratio * unit_value * counter_outcomes.def_outcome.hp_chance[0] ^ 2 / 0.85^2 * 2
                    counter_rating = counter_rating + die_rating

                    rating = rating + counter_rating
                    FGM.set_value(unit_rating_maps[id], x, y, 'counter_rating', counter_rating)
                end

                if (not counter_outcomes) or (counter_outcomes.def_outcome.hp_chance[0] < 0.85) then
                    safe_loc = true
                end

                -- Everything is balanced against the value loss rating from the counter attack
                -- For now, let's set being one full move away equal to half the value of the unit,
                -- multiplied by push_factor
                -- Note: unit_value_ratio is already taken care of in both the location of the goal hex
                -- and the counter attack rating.  Is including the push factor overdoing it?


                -- Small preference for villages we don't own (although this
                -- should mostly be covered by the village grabbing action already)
                -- Equal to gold difference between grabbing and not grabbing (not counting support)
                local village_bonus = 0
                local owner = FGM.get_value(move_data.village_map, x, y, 'owner')
                if owner and (owner ~= wesnoth.current.side) then
                    if (owner == 0) then
                        village_bonus = village_bonus + 3
                    else
                        village_bonus = village_bonus + 6
                    end
                end

                if FGM.get_value(adjacent_village_map, x, y, 'village_xy') then
                    village_bonus = village_bonus - 6
                end

                -- Somewhat larger preference for villages for injured units
                -- Also add a half-hex bonus for villages in general; no need not to go there
                -- all else being equal
                if owner and (not move_data.unit_infos[id].abilities.regenerate) then
                    village_bonus = village_bonus + unit_value * (1 / hp_forward_factor - 1) -- zero for uninjured unit
                end

                local bonus_rating = village_bonus

                -- Small bonus for the terrain; this does not really matter for
                -- unthreatened hexes and is already taken into account in the
                -- counter attack calculation for others. Just a tie breaker.
                local my_defense = FDI.get_unit_defense(move_data.unit_copies[id], x, y, fred_data.caches.defense_maps)
                bonus_rating = bonus_rating + my_defense / 10
                rating = rating + bonus_rating
                FGM.set_value(unit_rating_maps[id], x, y, 'bonus_rating', bonus_rating)

                local dist = FGM.get_value(cost_map, x, y, 'cost')
                local dist_rating = - dist * unit_value / 2 * push_factor * hp_forward_factor
                FGM.set_value(unit_rating_maps[id], x, y, 'dist_rating', dist_rating)

                local defensive_rating = rating - dist
                rating = rating + dist_rating

                FGM.set_value(unit_rating_maps[id], x, y, 'rating', rating)
                FGM.set_value(unit_rating_maps[id], x, y, 'defensive_rating', defensive_rating)

                local fm_infl = FGM.get_value(move_data.influence_maps, x, y, 'full_move_influence')
                FGM.set_value(unit_rating_maps[id], x, y, 'fm_infl', fm_infl)

                if (fm_infl >= 0) then use_defensive_rating = false end

                if (rating > max_unit_rating) then
                    max_unit_rating = rating
                    best_unit_hex = { x, y }
                end
                if (defensive_rating > max_unit_def_rating) then
                    max_unit_def_rating = defensive_rating
                    best_unit_def_hex = { x, y }
                end
            end
        end
        --std_print(id .. ' after use_defensive_rating: ' .. tostring(use_defensive_rating))

        if use_defensive_rating then
            if (max_unit_def_rating > max_rating) then
                max_rating = max_unit_def_rating
                best_id = id
                best_hex = best_unit_def_hex
            end
        else
            if (max_unit_rating > max_rating) then
                max_rating = max_unit_rating
                best_id = id
                best_hex = best_unit_hex
            end
        end
    end
    --std_print('best unit: ' .. best_id, best_hex[1], best_hex[2])

    if DBG.show_debug('advance_unit_rating') then
        for id,unit_rating_map in pairs(unit_rating_maps) do
            DBG.show_fgm_with_message(unit_rating_map, 'rating', zone_cfg.zone_id ..': advance unit rating (unit value = ' .. move_data.unit_infos[id].unit_value .. ')', move_data.unit_copies[id])
        end
    end
    if DBG.show_debug('advance_unit_rating_details') then
        for id,unit_rating_map in pairs(unit_rating_maps) do
            DBG.show_fgm_with_message(unit_rating_map, 'unit_rating', zone_cfg.zone_id ..': advance unit_rating (unit value = ' .. move_data.unit_infos[id].unit_value .. ')', move_data.unit_copies[id])
            DBG.show_fgm_with_message(unit_rating_map, 'dist_rating', zone_cfg.zone_id ..': advance dist_rating (unit value = ' .. move_data.unit_infos[id].unit_value .. ')', move_data.unit_copies[id])
            DBG.show_fgm_with_message(unit_rating_map, 'counter_rating', zone_cfg.zone_id ..': advance counter_rating (unit value = ' .. move_data.unit_infos[id].unit_value .. ')', move_data.unit_copies[id])
            DBG.show_fgm_with_message(unit_rating_map, 'bonus_rating', zone_cfg.zone_id ..': advance bonus_rating (unit value = ' .. move_data.unit_infos[id].unit_value .. ')', move_data.unit_copies[id])
            DBG.show_fgm_with_message(unit_rating_map, 'fm_infl', zone_cfg.zone_id ..': full move influence' .. move_data.unit_infos[id].unit_value .. ')', move_data.unit_copies[id])
            DBG.show_fgm_with_message(unit_rating_map, 'rating', zone_cfg.zone_id ..': advance total rating (unit value = ' .. move_data.unit_infos[id].unit_value .. ')', move_data.unit_copies[id])
            DBG.show_fgm_with_message(unit_rating_map, 'defensive_rating', zone_cfg.zone_id ..': advance total defensive_rating (unit value = ' .. move_data.unit_infos[id].unit_value .. ')', move_data.unit_copies[id])
        end
    end


    -- If no safe location is found, check for desperate attack
    local best_target, best_weapons
    local action_str = zone_cfg.action_str
    if (not safe_loc) then
        --std_print('----- no safe advance location found -----')

        local cfg_attack_desp = { value_ratio = 0.2 } -- mostly based on damage done to enemy

        local max_attack_rating, best_attacker_id, best_attack_hex = - math.huge
        for id,xy in pairs(advancers) do
            --std_print('checking desperate attacks for ' .. id)

            local attacker = {}
            attacker[id] = move_data.units[id]
            for enemy_id,enemy_loc in pairs(move_data.enemies) do
                if FGM.get_value(move_data.unit_attack_maps[1][id], enemy_loc[1], enemy_loc[2], 'current_power') then
                    --std_print('    potential target:' .. enemy_id)

                    local target = {}
                    target[enemy_id] = enemy_loc
                    local attack_combos = FAU.get_attack_combos(
                        attacker, target, cfg_attack_desp, move_data.effective_reach_maps, false, fred_data
                    )

                    for _,combo in ipairs(attack_combos) do
                        local combo_outcome = FAU.attack_combo_eval(combo, target, cfg_attack_desp, fred_data)
                        --std_print(next(combo))
                        --DBG.dbms(combo_outcome.rating_table, false, 'combo_outcome.rating_table')

                        local do_attack = true

                        -- Don't attack if chance of leveling up the enemy is higher than the kill chance
                        if (combo_outcome.def_outcome.levelup_chance > combo_outcome.def_outcome.hp_chance[0]) then
                            do_attack = false
                        end

                        -- If there's no chance to kill the enemy, don't do the attack if it ...
                        if do_attack and (combo_outcome.def_outcome.hp_chance[0] == 0) then
                            local unit_level = move_data.unit_infos[id].level
                            local enemy_dxp = move_data.unit_infos[enemy_id].max_experience - move_data.unit_infos[enemy_id].experience

                            -- .. will get the enemy a certain level-up on the counter
                            if (enemy_dxp <= 2 * unit_level) then
                                do_attack = false
                            end

                            -- .. will give the enemy a level-up with a kill on the counter,
                            -- unless that would be the case even without the attack
                            if do_attack then
                                if (unit_level == 0) then unit_level = 0.5 end  -- L0 units
                                if (enemy_dxp > unit_level * 8) and (enemy_dxp <= unit_level * 9) then
                                    do_attack = false
                                end
                            end
                        end

                        if do_attack and (combo_outcome.rating_table.rating > max_attack_rating) then
                            max_attack_rating = combo_outcome.rating_table.rating
                            best_attacker_id = id
                            local _, dst = next(combo)
                            best_attack_hex = { math.floor(dst / 1000), dst % 1000 }
                            best_target = {}
                            best_target[enemy_id] = enemy_loc
                            best_weapons = combo_outcome.att_weapons_i
                            action_str = action_str .. ' (desperate attack)'
                        end
                    end
                end
            end
        end
        if best_attacker_id then
            --std_print('best desperate attack: ' .. best_attacker_id, best_attack_hex[1], best_attack_hex[2], next(best_target))
            best_id = best_attacker_id
            best_hex = best_attack_hex
        end
    end


    if best_id then
        DBG.print_debug('advance_output', zone_cfg.zone_id .. ': best advance: ' .. best_id .. ' -> ' .. best_hex[1] .. ',' .. best_hex[2])

        local best_unit = move_data.my_units[best_id]
        best_unit.id = best_id

        local action = {
            units = { best_unit },
            dsts = { best_hex },
            enemy = best_target,
            weapons = best_weapons,
            action_str = action_str
        }
        return action
    end
end


----- Retreat: -----
local function get_retreat_action(zone_cfg, fred_data)
    DBG.print_debug_time('eval', fred_data.turn_start_time, '  - retreat evaluation: ' .. zone_cfg.zone_id .. ' (' .. string.format('%.2f', zone_cfg.rating) .. ')')

    -- Combines moving leader to village or keep, and retreating other units.
    -- These are put in here together because we might want to weigh which one
    -- gets done first in the end.

    local move_data = fred_data.move_data
    local leader_objectives = fred_data.ops_data.objectives.leader
    --DBG.dbms(leader_objectives, false, 'leader_objectives')

    if move_data.my_units_MP[move_data.my_leader.id] then
        if leader_objectives.village then
            local action = {
                units = { move_data.my_leader },
                dsts = { { leader_objectives.village[1], leader_objectives.village[2] } },
                action_str = zone_cfg.action_str .. ' (move leader to village)'
            }
            --DBG.dbms(action, false, 'action')

            return action
        end

        -- This is only for moving leader back toward keep. Moving to a keep for
        -- recruiting is done as part of the recruitment action
        if leader_objectives.keep then
            local action = {
                units = { move_data.my_leader },
                dsts = { { leader_objectives.keep[1], leader_objectives.keep[2] } },
                action_str = zone_cfg.action_str .. ' (move leader to keep)'
            }
            --DBG.dbms(action, false, 'action')

            leader_objectives.keep = nil

            return action
        end

        if leader_objectives.other then
            local action = {
                units = { move_data.my_leader },
                dsts = { { leader_objectives.other[1], leader_objectives.other[2] } },
                action_str = zone_cfg.action_str .. ' (move leader toward keep or safety)'
            }
            --DBG.dbms(action, false, 'action')

            leader_objectives.other = nil

            return action
        end
    end

    --DBG.dbms(fred_data.ops_data.reserved_actions)
    local retreaters = {}
    for _,action in pairs(fred_data.ops_data.reserved_actions) do
        if (action.action_id == 'ret') then
            retreaters[action.id] = move_data.units[action.id]
        end
    end
    --DBG.dbms(retreaters, false, 'retreaters')

    if next(retreaters) then
        local retreat_utilities = FBU.retreat_utilities(move_data, fred_data.ops_data.behavior.orders.value_ratio)
        local retreat_combo = FRU.find_best_retreat(retreaters, retreat_utilities, fred_data)
        --DBG.dbms(retreat_combo, false, 'retreat_combo')

        if retreat_combo then
            local action = {
                units = {},
                dsts = {},
                action_str = zone_cfg.action_str
            }

            for src,dst in pairs(retreat_combo) do
                local src_x, src_y = math.floor(src / 1000), src % 1000
                local dst_x, dst_y = math.floor(dst / 1000), dst % 1000
                local unit = { src_x, src_y, id = move_data.my_unit_map[src_x][src_y].id }
                table.insert(action.units, unit)
                table.insert(action.dsts, { dst_x, dst_y })
            end
            --DBG.dbms(action, false, 'action')

            return action
        end
    end
end


------- Candidate Actions -------



----- CA: Zone control (max_score: 350000) -----
-- TODO: rename?
function get_zone_action(cfg, fred_data)
    -- Find the best action to do in the zone described in 'cfg'
    -- This is all done together in one function, rather than in separate CAs so that
    --  1. Zones get done one at a time (rather than one CA at a time)
    --  2. Relative scoring of different types of moves is possible

    -- **** Retreat severely injured units evaluation ****
    if (cfg.action_type == 'retreat') then
        --DBG.print_ts_delta(fred_data.turn_start_time, '  ' .. cfg.zone_id .. ': retreat_injured eval')
        -- TODO: heal_loc and safe_loc are not used at this time
        -- keep for now and see later if needed
        local action = get_retreat_action(cfg, fred_data)
        if action then
            --std_print(action.action_str)
            return action
        end
    end

    -- **** Attack evaluation ****
    if (cfg.action_type == 'attack') then
        --DBG.print_ts_delta(fred_data.turn_start_time, '  ' .. cfg.zone_id .. ': attack eval')
        local action = FA.get_attack_action(cfg, fred_data)
        if action then
            --DBG.dbms(action, false, 'action')

            local milk_xp_die_chance_limit = FCFG.get_cfg_parm('milk_xp_die_chance_limit')
            if (milk_xp_die_chance_limit < 0) then milk_xp_die_chance_limit = 0 end

            if (action.enemy_leader_die_chance > milk_xp_die_chance_limit) then
                --std_print('*** checking if we can get some more XP before killing enemy leader: ' .. action.enemy_leader_die_chance .. ' > ' .. milk_xp_die_chance_limit)
                local move_data = fred_data.move_data

                -- Attackers are all units that cannot attack the enemy leader
                local attackers = {}
                for id,loc in pairs(move_data.my_units) do
                    if (move_data.unit_copies[id].attacks_left > 0) then
                        attackers[id] = loc[1] * 1000 + loc[2]
                    end
                end
                local ids = FGM.get_value(move_data.my_attack_map[1], move_data.my_leader[1], move_data.my_leader[2], 'ids') or {}
                for _,id in ipairs(ids) do
                    attackers[id] = nil
                end

                -- Targets are all enemies except for the leader
                local targets = {}
                for enemy_id,enemy_loc in pairs(move_data.enemies) do
                    if (not move_data.unit_infos[enemy_id].canrecruit) then
                        targets[enemy_id] = enemy_loc[1] * 1000 + enemy_loc[2]
                    end
                end

                if next(attackers) and next(targets) then
                    local xp_attack_cfg = {
                        zone_id = 'all_map',
                        action_type = 'attack',
                        action_str = 'XP milking attack',
                        zone_units = attackers,
                        targets = targets,
                        rating = 999999,
                        value_ratio = (2 - action.enemy_leader_die_chance) * fred_data.ops_data.behavior.orders.value_ratio
                    }
                    --DBG.dbms(xp_attack_cfg, false, 'xp_attack_cfg')

                    local xp_attack_action = FA.get_attack_action(xp_attack_cfg, fred_data)
                    --DBG.dbms(xp_attack_action, false, 'xp_attack_action')

                    if xp_attack_action then
                        action = xp_attack_action
                    end
                end
            end

            --std_print(action.action_str)
            return action
        end
    end

    -- **** Hold position evaluation ****
    if (cfg.action_type == 'hold') then
        --DBG.print_ts_delta(fred_data.turn_start_time, '  ' .. cfg.zone_id .. ': hold eval')
        local action
        if cfg.use_stored_leader_protection then
            if fred_data.ops_data.stored_leader_protection[cfg.zone_id] then
                DBG.print_debug_time('eval', fred_data.turn_start_time, '  - hold evaluation (' .. cfg.action_str .. '): ' .. cfg.zone_id .. ' (' .. string.format('%.2f', cfg.rating) .. ')')
                action = AH.table_copy(fred_data.ops_data.stored_leader_protection[cfg.zone_id])
                fred_data.ops_data.stored_leader_protection[cfg.zone_id] = nil
            end
        else
            action = get_hold_action(cfg, fred_data)
        end

        if action then
            --DBG.print_ts_delta(fred_data.turn_start_time, action.action_str)
            if cfg.evaluate_only then
                --std_print('eval only: ' .. str)
                --local str = cfg.action_str .. ':' .. cfg.zone_id
                local leader_status = fred_data.ops_data.status.leader
                --DBG.dbms(leader_status, false, 'leader_status')
                --DBG.dbms(action, false, 'action')

                -- The 0.1 is there to protect against rounding errors and minor protection
                -- improvements that might not be worth it.
                if (leader_status.best_protection[cfg.zone_id].exposure < leader_status.exposure - 0.1) then
                    fred_data.ops_data.stored_leader_protection[cfg.zone_id] = action
                end
            else
                return action
            end
        end
        --DBG.dbms(fred_data.ops_data.stored_leader_protection, false, 'fred_data.ops_data.stored_leader_protection')
    end

    -- **** Advance in zone evaluation ****
    if (cfg.action_type == 'advance') then
        --DBG.print_ts_delta(fred_data.turn_start_time, '  ' .. cfg.zone_id .. ': advance eval')
        local action = get_advance_action(cfg, fred_data)
        if action then
            --DBG.print_ts_delta(fred_data.turn_start_time, action.action_str)
            return action
        end
    end

    -- **** Recruit evaluation ****
    if (cfg.action_type == 'recruit') then
        --DBG.print_ts_delta(fred_data.turn_start_time, '  ' .. cfg.zone_id .. ': recruit eval')
        -- Important: we cannot check recruiting here, as the units
        -- are taken off the map at this time, so it needs to be checked
        -- by the function setting up the cfg
        DBG.print_debug_time('eval', fred_data.turn_start_time, '  - recruit evaluation: ' .. cfg.zone_id .. ' (' .. string.format('%.2f', cfg.rating) .. ')')
        local action = {
            action_str = cfg.action_str,
            type = 'recruit',
        }
        return action
    end

    return nil  -- This is technically unnecessary, just for clarity
end


local function do_recruit(fred_data, ai, action)
    local move_data = fred_data.move_data
    local leader_objectives = fred_data.ops_data.objectives.leader
    --DBG.dbms(leader_objectives, false, 'leader_objectives')
    --DBG.dbms(action, false, 'action')

    local prerecruit = leader_objectives.prerecruit

    -- This is just a safeguard for now, to make sure nothing goes wrong
    if (not prerecruit) or (not prerecruit.units) or (not prerecruit.units[1]) then
        DBG.dbms(prerecruit, false, 'prerecruit')
        error("Leader was instructed to recruit, but no units to be recruited are set.")
    end

    -- If @action is set, this means that recruiting is done because the leader is needed
    -- in an action. In this case, we need to re-evaluate recruiting, because the leader
    -- might not be able to reach its hex from the pre-evaluated keep, and because some
    -- of the pre-evaluated recruit hexes might be used in the action.
    if action then
        local leader_id, leader_dst = move_data.my_leader.id
        for i_u,unit in ipairs(action.units) do
            if (unit.id == leader_id) then
                leader_dst = action.dsts[i_u]
            end
        end
        local from_keep = FGM.get_value(move_data.effective_reach_maps[leader_id], leader_dst[1], leader_dst[2], 'from_keep')
        --std_print(leader_id, leader_dst[1] .. ',' .. leader_dst[2] .. '  <--  ' .. from_keep[1] .. ',' .. from_keep[2])

        -- TODO: eventually we might switch this to Fred's own gamestate maps
        local avoid_map = LS.create()
        for _,dst in ipairs(action.dsts) do
            avoid_map:insert(dst[1], dst[2], true)
        end
        --DBG.dbms(avoid_map, false, 'avoid_map')

        local cfg = { outofway_penalty = -0.1 }
        prerecruit = fred_data.recruit:prerecruit_units(from_keep, avoid_map, move_data.my_units_can_move_away, cfg)
        --DBG.dbms(prerecruit, false, 'prerecruit')
    end

    -- Move leader to keep, if needed
    local leader = move_data.my_leader
    local recruit_loc = prerecruit.loc
    if (leader[1] ~= recruit_loc[1]) or (leader[2] ~= recruit_loc[2]) then
        --std_print('Need to move leader to keep first')
        local unit_proxy = COMP.get_unit(leader[1], leader[2])
        AHL.movepartial_outofway_stopunit(ai, unit_proxy, recruit_loc[1], recruit_loc[2])
    end

    for _,recruit_unit in ipairs(prerecruit.units) do
       --std_print('  ' .. recruit_unit.recruit_type .. ' at ' .. recruit_unit.recruit_hex[1] .. ',' .. recruit_unit.recruit_hex[2])
       local unit_in_way_proxy = COMP.get_unit(recruit_unit.recruit_hex[1], recruit_unit.recruit_hex[2])
       if unit_in_way_proxy then
           -- Generally, move out of way in direction of own leader
           -- TODO: change this
           local dx, dy  = leader[1] - recruit_unit.recruit_hex[1], leader[2] - recruit_unit.recruit_hex[2]
           local r = math.sqrt(dx * dx + dy * dy)
           if (r ~= 0) then dx, dy = dx / r, dy / r end

           --std_print('    unit_in_way: ' .. unit_in_way_proxy.id)
           AH.move_unit_out_of_way(ai, unit_in_way_proxy, { dx = dx, dy = dy })

           -- Make sure the unit really is gone now
           unit_in_way_proxy = COMP.get_unit(recruit_unit.recruit_hex[1], recruit_unit.recruit_hex[2])
           if unit_in_way_proxy then
               error('Unit was supposed to move out of the way for recruiting : ' .. unit_in_way_proxy.id .. ' at ' .. unit_in_way_proxy.x .. ',' .. unit_in_way_proxy.y)
           end
       end

       if (not unit_in_way_proxy) then
           AH.checked_recruit(ai, recruit_unit.recruit_type, recruit_unit.recruit_hex[1], recruit_unit.recruit_hex[2])
       end
   end

   fred_data.ops_data.objectives.leader.prerecruit = nil
end


local ca_zone_control = {}

function ca_zone_control:evaluation(cfg, fred_data, ai_debug)
    local function clear_fred_data()
        for k,_ in pairs(fred_data) do
            if (k ~= 'data') then -- the 'data' field needs to be preserved for the engine
                fred_data[k] = nil
            end
        end
    end

    turn_start_time = wesnoth.get_time_stamp() / 1000.

    -- This forces the turn data to be reset each call (use with care!)
    if DBG.show_debug('reset_turn') then
        clear_fred_data()
    end

    fred_data.turn_start_time = turn_start_time
    fred_data.previous_time = turn_start_time -- This is only used for timing debug output
    DBG.print_debug_time('eval', - fred_data.turn_start_time, 'start evaluating zone_control CA:')
    DBG.print_timing(fred_data, 0, '-- start evaluating zone_control CA:')

    local score_zone_control = 350000

    if (not fred_data.turn_data)
        or (fred_data.turn_data.turn_number ~= wesnoth.current.turn)
        or (fred_data.turn_data.side_number ~= wesnoth.current.side)
    then
        clear_fred_data() -- in principle this should not be necessary, but it's cheap, so keeping it as an insurance policy

        local ai = ai_debug or ai
        fred_data.recruit = {}
        local params = {
            high_level_fraction = 0,
            score_function = function () return 181000 end
        }
        wesnoth.require("~add-ons/AI-demos/lua/generic_recruit_engine.lua").init(ai, fred_data.recruit, params)

        -- These are the incremental data
        fred_data.caches = {
            defense_maps = {},
            movecost_maps = {},
            unit_types = {}
        }

        FDM.get_move_data(fred_data)
        FDT.set_turn_data(fred_data)

    else
        FDM.get_move_data(fred_data)
        FDT.update_turn_data(fred_data)
    end

    DBG.print_timing(fred_data, 0, '   call set_ops_data()')
    FOU.set_ops_data(fred_data)

    DBG.print_timing(fred_data, 0, '   call get_action_cfgs()')
    FOU.get_action_cfgs(fred_data)
    --DBG.dbms(fred_data.action_cfgs, false, 'fred_data.action_cfgs')

    local previous_action

    for i_c,cfg in ipairs(fred_data.action_cfgs) do
        --DBG.dbms(cfg, false, 'cfg')

        if previous_action then
            DBG.print_debug_time('eval', fred_data.turn_start_time, '  + previous action found (' .. string.format('%.2f', previous_action.score) .. ')')
            if (previous_action.score < cfg.rating) then
                DBG.print_debug_time('eval', fred_data.turn_start_time, '      current action has higher score (' .. string.format('%.2f', cfg.rating) .. ') -> evaluating current action')
            else
                fred_data.zone_action = previous_action
                DBG.print_debug_time('eval', fred_data.turn_start_time, '      current action has lower score (' .. string.format('%.2f', cfg.rating) .. ') -> executing previous action')
                DBG.print_debug_time('eval', fred_data.turn_start_time, '--> returning action ' .. previous_action.action_str .. ' (' .. previous_action.score .. ')')
                DBG.print_timing(fred_data, 0, '-- end evaluation zone_control CA [1]')
                return score_zone_control, previous_action
            end
        end

        -- Reserved actions have already been evaluated and checked for validity.
        -- We can skip changing units on the map, calling evaluation functions etc.
        if (cfg.action_type == 'reserved_action') then
            local action = {
                action_str = fred_data.ops_data.interaction_matrix.abbrevs[cfg.reserved_id],
                zone_id = cfg.zone_id,
                units = {},
                dsts = {}
            }

            DBG.print_debug_time('eval', fred_data.turn_start_time, '  - reserved action (' .. action.action_str .. ') evaluation: ' .. cfg.zone_id .. ' (' .. string.format('%.2f', cfg.rating) .. ')')

            for _,reserved_action in pairs(fred_data.ops_data.reserved_actions) do
                if (reserved_action.action_id == cfg.reserved_id) then
                    local tmp_unit = AH.table_copy(fred_data.move_data.units[reserved_action.id])
                    tmp_unit.id = reserved_action.id
                    table.insert(action.units, tmp_unit)
                    table.insert(action.dsts, { reserved_action.x, reserved_action.y })
                end
            end
            --DBG.dbms(action, false, 'action')

            if action.units[1] then
                fred_data.zone_action = action

                DBG.print_debug_time('eval', fred_data.turn_start_time, '--> returning action ' .. action.action_str .. ' (' .. string.format('%.2f', cfg.rating) .. ')')
                DBG.print_timing(fred_data, 0, '-- end evaluation zone_control CA [2]')
                return score_zone_control, action
            end
        else
            -- Extract all AI units with MP left (for enemy path finding, counter attack placement etc.)
            local extracted_units = {}
            for id,loc in pairs(fred_data.move_data.my_units_MP) do
                local unit_proxy = COMP.get_unit(loc[1], loc[2])
                COMP.extract_unit(unit_proxy)
                table.insert(extracted_units, unit_proxy)  -- Not a proxy unit any more at this point
            end

            local zone_action = get_zone_action(cfg, fred_data)

            for _,extracted_unit in ipairs(extracted_units) do COMP.put_unit(extracted_unit) end

            if zone_action then
                DBG.print_debug_time('eval', fred_data.turn_start_time, '      --> action found')

                zone_action.zone_id = cfg.zone_id
                --DBG.dbms(zone_action, false, 'zone_action')

                -- If a score is returned as part of the action table, that means that it is lower than the
                -- max possible score, and it should be checked whether another action should be done first.
                -- Currently this only applies to holds vs. village grabbing, but it is set up
                -- so that it can be used more generally.
                if zone_action.score
                    and (zone_action.score < cfg.rating) and (zone_action.score > 0)
                then
                    DBG.print_debug_time('eval', fred_data.turn_start_time,
                        string.format('          score (%.2f) < config rating (%.2f) --> checking next action first', zone_action.score, cfg.rating)
                    )
                    if (not previous_action) or (previous_action.score < zone_action.score) then
                        previous_action = zone_action
                    end
                else
                    fred_data.zone_action = zone_action

                    DBG.print_debug_time('eval', fred_data.turn_start_time, '  --> returning action ' .. zone_action.action_str .. ' (' .. cfg.rating .. ')')
                    DBG.print_timing(fred_data, 0, '-- end evaluation zone_control CA [3]')
                    return score_zone_control, zone_action
                end
            end
        end
    end

    if previous_action then
        DBG.print_debug_time('eval', fred_data.turn_start_time, '  + previous action left at end of loop (' .. string.format('%.2f', previous_action.score) .. ')')
        fred_data.zone_action = previous_action
        DBG.print_debug_time('eval', fred_data.turn_start_time, '  --> returning action ' .. previous_action.action_str .. ' (' .. previous_action.score .. ')')
        DBG.print_timing(fred_data, 0, '-- end evaluation zone_control CA [4]')
        return score_zone_control, previous_action
    end

    DBG.print_debug_time('eval', fred_data.turn_start_time, '  --> done with all cfgs: no action found')
    DBG.print_timing(fred_data, 0, '-- end evaluation zone_control CA [5]')

    -- This is mostly done so that there is no chance of corruption of savefiles
    clear_fred_data()
    return 0
end

function ca_zone_control:execution(cfg, fred_data, ai_debug)
    local ai = ai_debug or ai

    local action = fred_data.zone_action.zone_id .. ': ' .. fred_data.zone_action.action_str
    --DBG.dbms(fred_data.zone_action, false, 'fred_data.zone_action')


    -- If recruiting is set, we just do that, nothing else needs to be checked
    if (fred_data.zone_action.type == 'recruit') then
        DBG.print_debug_time('exec', fred_data.turn_start_time, 'exec: ' .. action)
        do_recruit(fred_data, ai)
        return
    end


    local enemy_proxy
    if fred_data.zone_action.enemy then
        enemy_proxy = COMP.get_units { id = next(fred_data.zone_action.enemy) }[1]
    end

    local gamestate_changed = false

    while fred_data.zone_action.units and (#fred_data.zone_action.units > 0) do
        local next_unit_ind = 1

        -- If this is an attack combo, reorder units to
        --   - Use unit with best rating
        --   - Maximize chance of leveling up
        --   - Give maximum XP to unit closest to advancing
        if enemy_proxy and fred_data.zone_action.units[2] then
            local attacker_copies, attacker_infos = {}, {}
            local combo = {}
            for i,unit in ipairs(fred_data.zone_action.units) do
                table.insert(attacker_copies, fred_data.move_data.unit_copies[unit.id])
                table.insert(attacker_infos, fred_data.move_data.unit_infos[unit.id])

                combo[unit[1] * 1000 + unit[2]] = fred_data.zone_action.dsts[i][1] * 1000 + fred_data.zone_action.dsts[i][2]
            end

            local defender_info = fred_data.move_data.unit_infos[enemy_proxy.id]

            local cfg_attack = { value_ratio = fred_data.ops_data.behavior.orders.value_ratio }
            local combo_outcome = FAU.attack_combo_eval(combo, fred_data.zone_action.enemy, cfg_attack, fred_data)
            --std_print('\noverall kill chance: ', combo_outcome.defender_damage.die_chance)

            local enemy_level = defender_info.level
            if (enemy_level == 0) then enemy_level = 0.5 end
            --std_print('enemy level', enemy_level)

            -- Check if any unit has a chance to level up
            local levelups = { anybody = false }
            for ind,unit in ipairs(fred_data.zone_action.units) do
                local unit_info = fred_data.move_data.unit_infos[unit.id]
                local XP_diff = unit_info.max_experience - unit_info.experience

                local levelup_possible, levelup_certain = false, false
                if (XP_diff <= enemy_level) then
                    levelup_certain = true
                    levelups.anybody = true
                elseif (XP_diff <= enemy_level * 8) then
                    levelup_possible = true
                    levelups.anybody = true
                end
                --std_print('  ' .. unit_info.id, XP_diff, levelup_possible, levelup_certain)

                levelups[ind] = { certain = levelup_certain, possible = levelup_possible}
            end
            --DBG.dbms(levelups, false, 'levelups')


            --DBG.print_ts_delta(fred_data.turn_start_time, 'Reordering units for attack')
            local max_rating = - math.huge
            for ind,unit in ipairs(fred_data.zone_action.units) do
                local unit_info = fred_data.move_data.unit_infos[unit.id]

                local att_outcome, def_outcome = FAU.attack_outcome(
                    attacker_copies[ind], enemy_proxy,
                    fred_data.zone_action.dsts[ind],
                    attacker_infos[ind], defender_info,
                    fred_data
                )
                local rating_table, att_damage, def_damage =
                    FAU.attack_rating({ unit_info }, defender_info, { fred_data.zone_action.dsts[ind] }, { att_outcome }, def_outcome, cfg_attack, fred_data)

                -- The base rating is the individual attack rating
                local rating = rating_table.rating
                --std_print('  base_rating ' .. unit_info.id, rating)

                -- If the target can die, we might want to reorder, in order
                -- to maximize the chance to level up and give the most XP
                -- to the most appropriate unit
                if (combo_outcome.def_outcome.hp_chance[0] > 0) then
                    local XP_diff = unit_info.max_experience - unit_info.experience

                    local extra_rating
                    if levelups.anybody then
                        -- If any of the units has a chance to level up, the
                        -- main rating is maximizing this chance
                        if levelups[ind].possible then
                            local utility = def_outcome.hp_chance[0] * (1 - att_outcome.hp_chance[0])
                            -- Want least advanced and most valuable unit to go first
                            extra_rating = 100 * utility + XP_diff / 10
                            extra_rating = extra_rating + att_damage[1].unit_value / 100
                        elseif levelups[ind].certain then
                            -- use square on CTD, to be really careful with these units
                            local utility = (1 - att_outcome.hp_chance[0])^2
                            -- Want least advanced and most valuable unit to go first
                            extra_rating = 100 * utility + XP_diff / 10
                            extra_rating = extra_rating + att_damage[1].unit_value / 100
                        else
                            local utility = (1 - def_outcome.hp_chance[0]) * (1 - att_outcome.hp_chance[0])
                            -- Want most advanced and least valuable unit to go last
                            extra_rating = 90 * utility + XP_diff / 10
                            extra_rating = extra_rating - att_damage[1].unit_value / 100
                        end
                        --std_print('    levelup utility', utility)
                    else
                        -- If no unit has a chance to level up, giving the
                        -- most XP to the most advanced unit is desirable, but
                        -- should not entirely dominate the attack rating
                        local xp_fraction = unit_info.experience / (unit_info.max_experience - 8)
                        if (xp_fraction > 1) then xp_fraction = 1 end
                        local x = 2 * (xp_fraction - 0.5)
                        local y = 2 * (def_outcome.hp_chance[0] - 0.5)

                        -- The following prefers units with low XP and no chance to kill
                        -- as well as units with high XP and high chance to kill
                        -- It is normalized to [0..1]
                        local utility = (x * y + 1) / 2
                        --std_print('      ' .. xp_fraction, def_outcome.hp_chance[0])
                        --std_print('      ' .. x, y, utility)

                        extra_rating = 10 * utility * (1 - att_outcome.hp_chance[0])^2

                        -- Also want most valuable unit to go first
                        extra_rating = extra_rating + att_damage[1].unit_value / 1000
                        --std_print('    XP gain utility', utility)
                    end

                    rating = rating + extra_rating
                    --std_print('    rating', rating)
                end

                if (rating > max_rating) then
                    max_rating, next_unit_ind = rating, ind
                end
            end
            --DBG.print_ts_delta(fred_data.turn_start_time, 'Best unit to go next:', fred_data.zone_action.units[next_unit_ind].id, max_rating, next_unit_ind)
        end
        --DBG.print_ts_delta(fred_data.turn_start_time, 'next_unit_ind', next_unit_ind)

        local unit_proxy = COMP.get_units { id = fred_data.zone_action.units[next_unit_ind].id }[1]
        if (not unit_proxy) then
            fred_data.zone_action = nil
            return
        end


        local dst = fred_data.zone_action.dsts[next_unit_ind]

        -- If this is the leader (and has MP left), recruit first
        local leader_objectives = fred_data.ops_data.objectives.leader
        if unit_proxy.canrecruit and fred_data.move_data.my_units_MP[unit_proxy.id]
            and leader_objectives.prerecruit and leader_objectives.prerecruit.units and leader_objectives.prerecruit.units[1]
        then
            DBG.print_debug_time('exec', fred_data.turn_start_time, 'exec: ' .. action .. ' (leader used -> recruit first)')
            do_recruit(fred_data, ai, fred_data.zone_action)
            gamestate_changed = true

            -- We also check here separately whether the leader can still get to dst.
            -- This is also caught below, but the ops analysis should never let this
            -- happen, so we want to know about it.
            local _,cost = wesnoth.find_path(unit_proxy, dst[1], dst[2])
            if (cost > unit_proxy.moves) then
                error('Leader was supposed to move to ' .. dst[1] .. ',' .. dst[2] .. ' after recruiting, but this is not possible. Check operations analysis.')
            end
        end

        DBG.print_debug_time('exec', fred_data.turn_start_time, 'exec: ' .. action .. ' ' .. unit_proxy.id)

        -- The following are some tests to make sure the intended move is actually
        -- possible, as there might have been some interference with units moving
        -- out of the way. It is also possible that units that are supposed to
        -- move out of the way cannot actually do so in practice. Abandon the move
        -- and reevaluate in that case. However, we can only do this if the gamestate
        -- has actually be changed already, or the CA will be blacklisted
        if gamestate_changed then
            -- It's possible that one of the units got moved out of the way
            -- by a move of a previous unit and that it cannot reach the dst
            -- hex any more. In that case we stop and reevaluate.
            -- TODO: make sure up front that move combination is possible
            local _,cost = wesnoth.find_path(unit_proxy, dst[1], dst[2])
            if (cost > unit_proxy.moves) then
                fred_data.zone_action = nil
                return
            end

            -- It is also possible that a unit moving out of the way for a previous
            -- move of this combination is now in the way again and cannot move any more.
            -- We also need to stop execution in that case.
            -- Just checking for moves > 0 is not always sufficient.
            local unit_in_way_proxy
            if (unit_proxy.x ~= dst[1]) or (unit_proxy.y ~= dst[2]) then
                unit_in_way_proxy = COMP.get_unit(dst[1], dst[2])
            end
            if unit_in_way_proxy then
                uiw_reach = wesnoth.find_reach(unit_in_way_proxy)

                -- Check whether the unit to move out of the way has an unoccupied hex to move to.
                local unit_blocked = true
                for _,uiw_loc in ipairs(uiw_reach) do
                    -- Unit in the way of the unit in the way
                    if (not COMP.get_unit(uiw_loc[1], uiw_loc[2])) then
                        unit_blocked = false
                        break
                    end
                end

                if unit_blocked then
                    fred_data.zone_action = nil
                    return
                end
            end
        end


        -- Generally, move out of way in direction of own leader
        local leader_loc = fred_data.move_data.my_leader
        local dx, dy  = leader_loc[1] - dst[1], leader_loc[2] - dst[2]
        local r = math.sqrt(dx * dx + dy * dy)
        if (r ~= 0) then dx, dy = dx / r, dy / r end

        -- However, if the unit in the way is part of the move combo, it needs to move in the
        -- direction of its own goal, otherwise it might not be able to reach it later
        local unit_in_way_proxy
        if (unit_proxy.x ~= dst[1]) or (unit_proxy.y ~= dst[2]) then
            unit_in_way_proxy = COMP.get_unit(dst[1], dst[2])
        end

        if unit_in_way_proxy then
            if unit_in_way_proxy.canrecruit then
                local leader_objectives = fred_data.ops_data.objectives.leader
                dx = leader_objectives.final[1] - unit_in_way_proxy.x
                dy = leader_objectives.final[2] - unit_in_way_proxy.y
                if (dx == 0) and (dy == 0) then -- this can happen if leader is on leader goal hex
                    -- In this case, as a last resort, move away from the enemy leader
                    dx = unit_in_way_proxy.x - leader_loc[1]
                    dy = unit_in_way_proxy.y - leader_loc[2]
                end
                local r = math.sqrt(dx * dx + dy * dy)
                if (r ~= 0) then dx, dy = dx / r, dy / r end
            else
                for i_u,u in ipairs(fred_data.zone_action.units) do
                    if (u.id == unit_in_way_proxy.id) then
                        --std_print('  unit is part of the combo', unit_in_way_proxy.id, unit_in_way_proxy.x, unit_in_way_proxy.y)

                        local uiw_dst = fred_data.zone_action.dsts[i_u]
                        local path, _ = wesnoth.find_path(unit_in_way_proxy, uiw_dst[1], uiw_dst[2])

                        -- If we can find an unoccupied hex along the path, move the
                        -- unit_in_way_proxy there, in order to maximize the chances of it
                        -- making it to its goal. However, do not move all the way and
                        -- do partial move only, in case something changes as result of
                        -- the original unit's action.
                        local moveto
                        for i = 2,#path do
                            if (not COMP.get_unit(path[i][1], path[i][2])) then
                                moveto = { path[i][1], path[i][2] }
                                break
                            end
                        end

                        if moveto then
                            --std_print('    ' .. unit_in_way_proxy.id .. ': moving out of way to:', moveto[1], moveto[2])
                            AH.checked_move(ai, unit_in_way_proxy, moveto[1], moveto[2])

                            -- If this got to its final destination, attack with this unit first, otherwise it might be stranded
                            -- TODO: only if other units have chance to kill?
                            if (moveto[1] == uiw_dst[1]) and (moveto[2] == uiw_dst[2]) then
                                --std_print('      going to final destination')
                                dst = uiw_dst
                                next_unit_ind = i_u
                                unit_proxy = unit_in_way_proxy
                            end
                        else
                            if (not path) or (not path[1]) or (not path[2]) then
                                std_print('Trying to identify path table error !!!!!!!!')
                                std_print(i_u, u.id, unit_in_way_proxy.id)
                                std_print(unit_proxy.id, unit_proxy.x, unit_proxy.y)
                                DBG.dbms(fred_data.zone_action, -1)
                                DBG.dbms(dst, -1)
                                DBG.dbms(path, -1)
                            end
                            dx, dy = path[2][1] - path[1][1], path[2][2] - path[1][2]
                            local r = math.sqrt(dx * dx + dy * dy)
                            if (r ~= 0) then dx, dy = dx / r, dy / r end
                        end

                        break
                    end
                end
            end
        end

        if unit_in_way_proxy and (dx == 0) and (dy == 0) then
            error(unit_in_way_proxy.id .. " to move out of way with dx = dy = 0")
        end

        if fred_data.zone_action.partial_move then
            AHL.movepartial_outofway_stopunit(ai, unit_proxy, dst[1], dst[2], { dx = dx, dy = dy })
            if (unit_proxy.moves == 0) then
                fred_data.ops_data.used_units[unit_proxy.id] = fred_data.zone_action.zone_id
            end
        else
            AH.movefull_outofway_stopunit(ai, unit_proxy, dst[1], dst[2], { dx = dx, dy = dy })
            fred_data.ops_data.used_units[unit_proxy.id] = fred_data.zone_action.zone_id
        end
        gamestate_changed = true


        -- Remove these from the table
        table.remove(fred_data.zone_action.units, next_unit_ind)
        table.remove(fred_data.zone_action.dsts, next_unit_ind)

        -- Then do the attack, if there is one to do
        if enemy_proxy and (wesnoth.map.distance_between(unit_proxy.x, unit_proxy.y, enemy_proxy.x, enemy_proxy.y) == 1) then
            local weapon = fred_data.zone_action.weapons[next_unit_ind]
            table.remove(fred_data.zone_action.weapons, next_unit_ind)

            AH.checked_attack(ai, unit_proxy, enemy_proxy, weapon)

            -- If enemy got killed, we need to stop here
            if (not enemy_proxy.valid) then
                fred_data.zone_action.units = nil
            end

            -- Need to reset the enemy information if there are more attacks in this combo
            if fred_data.zone_action.units and fred_data.zone_action.units[1] then
                fred_data.move_data.unit_copies[enemy_proxy.id] = COMP.copy_unit(enemy_proxy)
                fred_data.move_data.unit_infos[enemy_proxy.id] = FU.single_unit_info(enemy_proxy, fred_data.caches.unit_types)
            end
        end

        if (not unit_proxy) or (not unit_proxy.valid) then
            fred_data.zone_action.units = nil
        end
    end

    fred_data.zone_action = nil
end

return ca_zone_control
