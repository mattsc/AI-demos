return {
    init = function(ai)

        local fred = {}

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        local FGU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_gamestate_utils.lua"
        local FGUI = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_gamestate_utils_incremental.lua"
        local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
        local FAU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack_utils.lua"
        local FHU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_hold_utils.lua"
        local FVU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_village_utils.lua"
        local LS = wesnoth.require "lua/location_set.lua"
        local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"
        local R = wesnoth.require "~/add-ons/AI-demos/lua/retreat.lua"
        local UHC = wesnoth.dofile "~/add-ons/AI-demos/lua/unit_hex_combos.lua"


        ----- Debug output flags -----
        local debug_eval = false    -- top-level evaluation information
        local debug_exec = true     -- top-level executiuon information
        local show_debug_analysis = false
        local show_debug_attack = false
        local show_debug_hold = false
        local show_debug_advance = false


        ------- Utility functions -------
        local function print_time(...)
            if fred.data.turn_start_time then
                AH.print_ts_delta(fred.data.turn_start_time, ...)
            else
                AH.print_ts(...)
            end
        end


        ------ Map analysis at beginning of turn -----------

        function fred:get_leader_distance_map()
            local show_debug = true

            local side_cfgs = fred:get_side_cfgs()
            local leader_loc, enemy_leader_loc
            for side,cfg in ipairs(side_cfgs) do
                if (side == wesnoth.current.side) then
                    leader_loc = cfg.start_hex
                else
                    enemy_leader_loc = cfg.start_hex
                end
            end

            -- Need a map with the distances to the enemy and own leaders
            local leader_cx, leader_cy = AH.cartesian_coords(leader_loc[1], leader_loc[2])
            local enemy_leader_cx, enemy_leader_cy = AH.cartesian_coords(enemy_leader_loc[1], enemy_leader_loc[2])

            local dist_btw_leaders = math.sqrt( (enemy_leader_cx - leader_cx)^2 + (enemy_leader_cy - leader_cy)^2 )

            local leader_distance_map, hold_here_map = {}, {}
            local width, height = wesnoth.get_map_size()
            for x = 1,width do
                for y = 1,height do
                    local cx, cy = AH.cartesian_coords(x, y)

                    local leader_dist = math.sqrt( (leader_cx - cx)^2 + (leader_cy - cy)^2 )
                    local enemy_leader_dist = math.sqrt( (enemy_leader_cx - cx)^2 + (enemy_leader_cy - cy)^2 )

                    if (not leader_distance_map[x]) then leader_distance_map[x] = {} end
                    leader_distance_map[x][y] = {
                        my_leader_distance = leader_dist,
                        enemy_leader_distance = enemy_leader_dist,
                        distance = leader_dist - enemy_leader_dist
                    }

                end
            end
            fred.data.gamedata.leader_distance_map = leader_distance_map


            -- Enemy leader distance maps. These are calculated using wesnoth.find_cost_map() for
            -- each unit type from the start hex of the enemy leader. This is not ideal, as it is
            -- in the wrong direction (and terrain changes are not symmetric), but it
            -- is good enough for the purpose of finding the best way to the enemy leader
            -- TODO: do this correctly, if needed
            local enemy_leader_distance_maps = {}
            for id,_ in pairs(fred.data.gamedata.my_units) do
                local typ = fred.data.gamedata.unit_infos[id].type -- can't use type, that's reserved

                if (not enemy_leader_distance_maps[typ]) then
                    enemy_leader_distance_maps[typ] = {}

                    local cost_map = wesnoth.find_cost_map(
                        { x = -1 }, -- SUF not matching any unit
                        { { enemy_leader_loc[1], enemy_leader_loc[2], wesnoth.current.side, typ } },
                        { ignore_units = true }
                    )

                    for _,cost in pairs(cost_map) do
                        local x, y, c = cost[1], cost[2], cost[3]
                        if (cost[3] > -1) then
                            FU.set_fgumap_value(enemy_leader_distance_maps[typ], cost[1], cost[2], 'cost', cost[3])
                        end
                    end
                end
            end
            fred.data.gamedata.enemy_leader_distance_maps = enemy_leader_distance_maps
        end

        function fred:get_side_cfgs()
            local cfgs = {
                { start_hex = { 18, 4 }
                },
                { start_hex = { 20, 20 }
                }
            }

            return cfgs
        end

        function fred:get_attack_test_locs()
            -- TODO: this is really just a placeholder for now until I know whether this works
            -- It's easy to have this found automatically
            local locs = {
                attacker_loc = { 28, 13 },
                defender_loc = { 28, 14 }
            }

            return locs
        end

        function fred:get_raw_cfgs(zone_id)
            local cfg_leader = {
                zone_id = 'leader',
                threat_slf = { x = '1-15,16-24,25-34', y = '1-6,1-8,1-9' },
                --threat2_distance_factor = 1,
                key_hexes = { { 18,4 }, { 19,4 } },
                zone_filter = { x = '1-15,16-23,24-34', y = '1-6,1-7,1-8' },
            }

            local cfg_all_map = {
                zone_id = 'all_map',
                --key_hexes = { { 25,12 }, { 27,11 }, { 29,11 }, { 32,10 } },
                target_zone = { x = '1-34', y = '1-23' },
                zone_filter = { x = '1-34', y = '1-23' },
                unit_filter_advance = { x = '1-34', y = '1-23' },
                hold_slf = { x = '1-34', y = '1-23' },
                villages = {
                    slf = { x = '1-34', y = '1-23' },
                    villages_per_unit = 2
                }
            }

            local cfg_west = {
                zone_id = 'west',
                ops_slf = { x = '1-15,1-14,1-21', y = '1-12,13-17,18-24' },
                center_hex = { 10, 12 },
                zone_weight = 1,
            }

            local cfg_center = {
                zone_id = 'center',
                center_hex = { 19, 12 },
                ops_slf = { x = '16-20,16-22,16-23,15-22,15-23', y = '6-7,8-9,10-12,13-17,18-24' },
                zone_weight = 0.5,
            }

            local cfg_east = {
                zone_id = 'east',
                center_hex = { 28, 12 },
                ops_slf = { x = '21-34,23-34,24-34,23-34,17-34', y = '1-7,8-9,10-12,13-17,18-24' },
                zone_weight = 1,
            }

            if (zone_id == 'leader') then
                return cfg_leader
            end

            if (zone_id == 'all_map') then
                return cfg_all_map
            end

            if (not zone_id) then
                local zone_cfgs = {
                    west = cfg_west,
                    center = cfg_center,
                    east = cfg_east
                }
               return zone_cfgs

            elseif (zone_id == 'all') then
                -- Note that 'all' includes the leader zone, but not the all_map zone
                local all_cfgs = {
                    leader = cfg_leader,
                    west = cfg_west,
                    center = cfg_center,
                    east = cfg_east
                }
               return all_cfgs

            else
                local cfgs = {
                    leader = cfg_leader,
                    west = cfg_west,
                    center = cfg_center,
                    east = cfg_east,
                    all_map = cfg_all_map
                }

                for _,cfg in pairs(cfgs) do
                    if (cfg.zone_id == zone_id) then
                        return cfg
                    end
                end
            end
        end

        function fred:calc_power_stats(assigned_units, assigned_enemies, gamedata)
            local power_stats = {
                total = { my_power = 0, enemy_power = 0 },
                zones = {}
            }

            for id,_ in pairs(gamedata.my_units) do
                if (not gamedata.unit_infos[id].canrecruit) then
                    power_stats.total.my_power = power_stats.total.my_power + FU.unit_base_power(gamedata.unit_infos[id])
                end
            end
            for id,_ in pairs(gamedata.enemies) do
                if (not gamedata.unit_infos[id].canrecruit) then
                    power_stats.total.enemy_power = power_stats.total.enemy_power + FU.unit_base_power(gamedata.unit_infos[id])
                end
            end

            local ratio = power_stats.total.my_power / power_stats.total.enemy_power
            if (ratio > 1) then ratio = 1 end
            power_stats.total.ratio = ratio


            local raw_cfgs_main = fred:get_raw_cfgs()
            for zone_id,_ in pairs(raw_cfgs_main) do
                power_stats.zones[zone_id] = {
                    my_power = 0,
                    enemy_power = 0
                }
            end

            for id,data in pairs(assigned_units) do
                local power = FU.unit_base_power(gamedata.unit_infos[id])

                if (data.zone_id ~= 'other') then
                    power_stats.zones[data.zone_id].my_power = power_stats.zones[data.zone_id].my_power + power
                end
            end
            for id,data in pairs(assigned_enemies) do
                local power = FU.unit_base_power(gamedata.unit_infos[id])
                power_stats.zones[data.zone_id].enemy_power = power_stats.zones[data.zone_id].enemy_power + power
            end

            for zone_id,_ in pairs(raw_cfgs_main) do
                -- Note: both power_needed and power_missing take ratio into account, the other values do not
                local power_needed = power_stats.zones[zone_id].enemy_power * power_stats.total.ratio
                local power_missing = power_needed - power_stats.zones[zone_id].my_power
                if (power_missing < 0) then power_missing = 0 end
                power_stats.zones[zone_id].power_needed = power_needed
                power_stats.zones[zone_id].power_missing = power_missing
            end

            return power_stats
        end

        function fred:get_behavior_this_turn()
            FU.print_debug(show_debug_analysis, '\n------------- Updating the behavior table:')

            -- At beginning of turn, reset fred.data.behavior

            if fred.data.behavior and fred.data.behavior.turn
                and (fred.data.behavior.turn.turn_number == wesnoth.current.turn)
            then
                print('****** Behavior table already exists for this turn --> skipping ******')
                return
            end

            fred.data.behavior = {
                turn = {
                    turn_number = wesnoth.current.turn,
                    stage_counter = 1,
                    --stage_ids = { 'leader_threat', 'defend_zones', 'all_map' },
                    stage_ids = { 'defend_zones' }
                }
            }
            fred.data.turn_data = {}

            -- Get the needed cfgs
            local gamedata = fred.data.gamedata
            local raw_cfgs_main = fred:get_raw_cfgs()
            local side_cfgs = fred:get_side_cfgs()


            -- Assemble the diverse influence maps


            local my_inf = {}
            for id,_ in pairs(gamedata.my_units) do
                --print(id)
                if false then
                    FU.show_fgumap_with_message(gamedata.unit_influence_maps[id], 'influence', 'Unit influence', gamedata.unit_copies[id])
                end

                if (not gamedata.unit_infos[id].canrecruit) then
                    local unit_influence = FU.unit_current_power(gamedata.unit_infos[id])

                    for x,tmp in pairs(gamedata.unit_influence_maps[id]) do
                        for y,inf in pairs(tmp) do
                            local influence = inf.influence * unit_influence
                            influence = influence + FU.get_fgumap_value(my_inf, x, y, 'my_influence', 0)
                            FU.set_fgumap_value(my_inf, x, y, 'my_influence', influence)
                        end
                    end
                end
            end

            local enemy_inf = {}
            for id,_ in pairs(gamedata.enemies) do
                --print(id)
                --FU.put_fgumap_labels(gamedata.unit_influence_maps[id], 'influence')
                if (not gamedata.unit_infos[id].canrecruit) then
                    local unit_influence = FU.unit_current_power(gamedata.unit_infos[id])

                    for x,tmp in pairs(gamedata.unit_influence_maps[id]) do
                        for y,inf in pairs(tmp) do
                            local influence = inf.influence * unit_influence
                            influence = influence + FU.get_fgumap_value(enemy_inf, x, y, 'enemy_influence', 0)
                            FU.set_fgumap_value(enemy_inf, x, y, 'enemy_influence', influence)
                        end
                    end
                end
            end

            local IM = {}
            local width, height = wesnoth.get_map_size()
            for x = 1,width do
                for y = 1,height do
                    local my_inf = FU.get_fgumap_value(my_inf, x, y, 'my_influence')
                    local enemy_inf = FU.get_fgumap_value(enemy_inf, x, y, 'enemy_influence')

                    if my_inf or enemy_inf then
                        my_inf = my_inf or 0
                        enemy_inf = enemy_inf or 0

                        local inf = my_inf - enemy_inf
                        FU.set_fgumap_value(IM, x, y, 'influence', inf)

                        local tension = my_inf + enemy_inf
                        FU.set_fgumap_value(IM, x, y, 'tension', tension)

                        local vulnerability = tension - math.abs(inf)
                        FU.set_fgumap_value(IM, x, y, 'vulnerability', vulnerability)
                    end
                end
            end

            local blurred_vulnerability = {}
            for x,arr in pairs(IM) do
                for y,data in pairs(arr) do
                    local v = data.vulnerability

                    for xa,ya in H.adjacent_tiles(x, y) do
                        local va = FU.get_fgumap_value(IM, xa, ya, 'vulnerability', 0)
                        v = v + va
                    end
                    -- We intentionally count hexes on the edges as zero (instead of omitting them)
                    v = v / 7

                    FU.set_fgumap_value(IM, x, y, 'blurred_vulnerability', v)
                end
            end


            if false then
                --FU.show_fgumap_with_message(my_inf, 'my_influence', 'My influence')
                --FU.show_fgumap_with_message(enemy_inf, 'enemy_influence', 'Enemy influence')
                FU.show_fgumap_with_message(IM, 'influence', 'Influence')
                --FU.show_fgumap_with_message(IM, 'tension', 'Tension')
                FU.show_fgumap_with_message(IM, 'vulnerability', 'Vulnerability')
                --FU.show_fgumap_with_message(IM, 'blurred_vulnerability', 'Blurred vulnerability')
            end

            if false then
                --FU.show_fgumap_with_message(gamedata.leader_distance_map, 'my_leader_distance', 'my_leader_distance')
                FU.show_fgumap_with_message(gamedata.leader_distance_map, 'enemy_leader_distance', 'enemy_leader_distance')
                FU.show_fgumap_with_message(gamedata.leader_distance_map, 'distance', 'leader_distance_map')

                --FU.show_fgumap_with_message(gamedata.enemy_leader_distance_maps['Orcish Grunt'], 'cost', 'cost Grunt')
                --FU.show_fgumap_with_message(gamedata.enemy_leader_distance_maps['Wolf Rider'], 'cost', 'cost Wolf Rider')
            end


            local enemy_leader_derating = FU.cfg_default('enemy_leader_derating')
            local enemy_int_influence_map = {}
            for x,y,data in FU.fgumap_iter(gamedata.enemy_attack_map[1]) do
                local enemy_influence, number = 0, 0
                for _,enemy_id in pairs(data.ids) do
                    local unit_influence = FU.unit_terrain_power(gamedata.unit_infos[enemy_id], x, y, gamedata)
                    if gamedata.unit_infos[enemy_id].canrecruit then
                        unit_influence = unit_influence * enemy_leader_derating
                    end
                    enemy_influence = enemy_influence + unit_influence
                    number = number + 1
                end
                FU.set_fgumap_value(enemy_int_influence_map, x, y, 'enemy_influence', enemy_influence)
                FU.set_fgumap_value(enemy_int_influence_map, x, y, 'number', number)
            end

            if false then
                FU.show_fgumap_with_message(enemy_int_influence_map, 'enemy_influence', 'Enemy integer infuence map')
                FU.show_fgumap_with_message(enemy_int_influence_map, 'number', 'Enemy number')
            end


            -- Attributing enemy and own units to zones
            -- Use base_power for this as it is not only for the current turn
            local assigned_enemies = {}
            local enemies_by_zone = {}
            for id,_ in pairs(gamedata.enemies) do
                local unit_copy = gamedata.unit_copies[id]
                if (not unit_copy.canrecruit)
                    and (not FU.get_fgumap_value(gamedata.reachable_castles_map[unit_copy.side], unit_copy.x, unit_copy.y, 'castle', false))
                then
                    local zone_id = FU.moved_toward_zone(unit_copy, raw_cfgs_main, side_cfgs)
                    assigned_enemies[id] = {
                        zone_id = zone_id
                    }

                    if (not enemies_by_zone[zone_id]) then
                        enemies_by_zone[zone_id] = {}
                    end
                    enemies_by_zone[zone_id][id] = true
                end
            end
            --DBG.dbms(assigned_enemies)
            --DBG.dbms(enemies_by_zone)

            local pre_assigned_units = {}
            for id,_ in pairs(gamedata.my_units) do
                local unit_copy = gamedata.unit_copies[id]
                if (not unit_copy.canrecruit)
                    and (not FU.get_fgumap_value(gamedata.reachable_castles_map[unit_copy.side], unit_copy.x, unit_copy.y, 'castle', false))
                then
                    local zone_id = FU.moved_toward_zone(unit_copy, raw_cfgs_main, side_cfgs)
                    pre_assigned_units[id] =  zone_id
                end
            end
            --DBG.dbms(pre_assigned_units)

            local assigned_units = {}



            -- Extract all AI units
            --   - because no two units on the map can have the same underlying_id
            --   - so that we do not accidentally overwrite a unit
            --   - so that we don't accidentally apply leadership, backstab or the like
            local extracted_units = {}
            for id,loc in pairs(fred.data.gamedata.units) do
                local unit_proxy = wesnoth.get_unit(loc[1], loc[2])
                wesnoth.extract_unit(unit_proxy)
                table.insert(extracted_units, unit_proxy)  -- Not a proxy unit any more at this point
            end

            -- Find the effectiveness of each AI unit vs. each enemy unit
            local attack_locs = fred:get_attack_test_locs()

            local unit_attacks = {}
            for my_id,_ in pairs(gamedata.my_units) do
                --print(my_id)
                local tmp_attacks = {}

                local old_x = gamedata.unit_copies[my_id].x
                local old_y = gamedata.unit_copies[my_id].y
                local my_x, my_y = attack_locs.attacker_loc[1], attack_locs.attacker_loc[2]

                wesnoth.put_unit(my_x, my_y, gamedata.unit_copies[my_id])
                local my_proxy = wesnoth.get_unit(my_x, my_y)

                for enemy_id,_ in pairs(gamedata.enemies) do
                    --print('    ' .. enemy_id)

                    local old_x_enemy = gamedata.unit_copies[enemy_id].x
                    local old_y_enemy = gamedata.unit_copies[enemy_id].y
                    local enemy_x, enemy_y = attack_locs.defender_loc[1], attack_locs.defender_loc[2]

                    wesnoth.put_unit(enemy_x, enemy_y, gamedata.unit_copies[enemy_id])
                    local enemy_proxy = wesnoth.get_unit(enemy_x, enemy_y)

                    local bonus_poison = 8
                    local bonus_slow = 4
                    local bonus_regen = 8

                    local max_diff_forward, forward
                    for i_w,_ in ipairs(gamedata.unit_infos[my_id].attacks) do
                        --print('attack weapon: ' .. i_w)

                        local _, _, my_weapon, enemy_weapon = wesnoth.simulate_combat(my_proxy, i_w, enemy_proxy)

                        local done = my_weapon.damage * my_weapon.num_blows
                        local taken = enemy_weapon.damage * enemy_weapon.num_blows

                        local my_extra, enemy_extra = 0, 0
                        if my_weapon.poisons then my_extra = my_extra + bonus_poison end
                        if my_weapon.slows then my_extra = my_extra + bonus_slow end
                        if enemy_weapon.poisons then enemy_extra = enemy_extra + bonus_poison end
                        if enemy_weapon.slows then enemy_extra = enemy_extra + bonus_slow end

                        local diff = done + my_extra - taken - enemy_extra
                        --print('  ' .. done, taken, my_extra, enemy_extra, '-->', diff)

                        if (not max_diff_forward) or (diff > max_diff_forward) then
                            max_diff_forward = diff
                            forward = {
                                done = done,
                                taken = taken,
                                my_extra = my_extra,
                                enemy_extra = enemy_extra,
                                my_gen_hc = my_weapon.chance_to_hit / 100,
                                enemy_gen_hc = enemy_weapon.chance_to_hit / 100
                            }
                        end
                    end
                    --DBG.dbms(forward)

                    local min_diff_counter, counter
                    for i_w,_ in ipairs(gamedata.unit_infos[enemy_id].attacks) do
                        --print('counter weapon: ' .. i_w)

                        local _, _, enemy_weapon, my_weapon = wesnoth.simulate_combat(enemy_proxy, i_w, my_proxy)

                        local done = my_weapon.damage * my_weapon.num_blows
                        local taken = enemy_weapon.damage * enemy_weapon.num_blows

                        local my_extra, enemy_extra = 0, 0
                        if my_weapon.poisons then my_extra = my_extra + bonus_poison end
                        if my_weapon.slows then my_extra = my_extra + bonus_slow end
                        if enemy_weapon.poisons then enemy_extra = enemy_extra + bonus_poison end
                        if enemy_weapon.slows then enemy_extra = enemy_extra + bonus_slow end

                        local diff = done + my_extra - taken - enemy_extra

                        -- We add this as a tie breaker (e.g. equal units against each other)
                        -- to choose the maximum damage weapon
                        diff = diff - taken / 100
                        --print('  ' .. done, taken, my_extra, enemy_extra, '-->', diff)

                        if (not min_diff_counter) or (diff < min_diff_counter) then
                            min_diff_counter = diff
                            counter = {
                                done = done,
                                taken = taken,
                                my_extra = my_extra,
                                enemy_extra = enemy_extra,
                                my_gen_hc = my_weapon.chance_to_hit / 100,
                                enemy_gen_hc = enemy_weapon.chance_to_hit / 100
                            }
                        end
                    end
                    --DBG.dbms(counter)

                    gamedata.unit_copies[enemy_id] = wesnoth.copy_unit(enemy_proxy)
                    wesnoth.put_unit(enemy_x, enemy_y)
                    gamedata.unit_copies[enemy_id].x = old_x_enemy
                    gamedata.unit_copies[enemy_id].y = old_y_enemy


                    -- For now, we just categorically count poison, slow damage as constant, independent of CTH
                    -- TODOs:
                    --   - might be refined later
                    --   - add drain
                    --   - add to max_damage in unit_infos also?
                    --   - should we cycle through all weapons?
                    --   - make attack more important than defense?

                    local my_regen, enemy_regen = 0, 0
                    if gamedata.unit_infos[my_id].abilities.regenerate then
                        my_regen = 8
                    end
                    if gamedata.unit_infos[enemy_id].abilities.regenerate then
                        enemy_regen = 8
                    end

                    tmp_attacks[enemy_id] = {
                        rating = rating,
                        my_regen = my_regen,
                        enemy_regen = enemy_regen,
                        forward = forward,
                        counter = counter
                    }
                end

                gamedata.unit_copies[my_id] = wesnoth.copy_unit(my_proxy)
                wesnoth.put_unit(my_x, my_y)
                gamedata.unit_copies[my_id].x = old_x
                gamedata.unit_copies[my_id].y = old_y

                unit_attacks[my_id] = tmp_attacks
            end

            for _,extracted_unit in ipairs(extracted_units) do wesnoth.put_unit(extracted_unit) end

            --DBG.dbms(unit_attacks)


            ----- Village goals -----
            local zone_village_goals, villages_to_protect_maps = FVU.village_goals(raw_cfgs_main, side_cfgs, gamedata)

            --DBG.dbms(zone_village_goals)
            --DBG.dbms(villages_to_protect_maps)

            -- Find how many units are needed in each zone for moving toward villages ('exploring')
            local units_needed_villages = {}
            local villages_per_unit = FU.cfg_default('villages_per_unit')
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
            --DBG.dbms(units_needed_villages)

            local immediate_actions = {}

            local best_captures = FVU.assign_grabbers(zone_village_goals, assigned_units, immediate_actions, unit_attacks, gamedata)
            --DBG.dbms(immediate_actions)
            --DBG.dbms(assigned_units)


            -- TODO: the following should be moved into fred_village_utils,
            -- and it can probably be simplified somewhat
            local units_assigned_villages = {}
            for id,data in pairs(assigned_units) do
                units_assigned_villages[data.zone_id] = (units_assigned_villages[data.zone_id] or 0) + 1
            end
            --DBG.dbms(units_needed_villages)
            --DBG.dbms(units_assigned_villages)



            for zone_id,n_needed in pairs(units_needed_villages) do
                if (n_needed <= (units_assigned_villages[zone_id] or 0)) then
                    zone_village_goals[zone_id] = nil
                end
            end
            --DBG.dbms(zone_village_goals)


            -- Also remove them as village goals (they are considered taken at this point)
            for _,village in ipairs(best_captures) do
                if zone_village_goals[village.zone_id] then
                    for i_v,v2 in ipairs(zone_village_goals[village.zone_id]) do
                        if (v2.x == village.x) and (v2.y == village.y) then
                            table.remove(zone_village_goals[village.zone_id], i_v)
                            break
                        end
                    end
                end

            end
            --DBG.dbms(zone_village_goals)


            -- Now check out what other units to send in this direction
            local scouts = {}


            for zone_id,villages in pairs(zone_village_goals) do
                --print(zone_id)
                scouts[zone_id] = {}
                for _,village in ipairs(villages) do
                    --print('  ' .. village.x, village.y)
                    for id,loc in pairs(gamedata.my_units) do
                        -- The leader is always excluded here, plus any unit that has already been assigned
                        -- TODO: set up an array of unassigned units?
                        if (not gamedata.unit_infos[id].canrecruit) and (not assigned_units[id]) then
                            local _, cost = wesnoth.find_path(gamedata.unit_copies[id], village.x, village.y)
                            cost = cost + gamedata.unit_infos[id].max_moves - gamedata.unit_infos[id].moves
                            --print('    ' .. id, cost)

                            local unit_rating = - cost / #villages / gamedata.unit_infos[id].max_moves

                            scouts[zone_id][id] = (scouts[zone_id][id] or 0) + unit_rating
                        end
                    end

                end
            end
            --DBG.dbms(scouts)

            local sorted_scouts = {}
            for zone_id,units in pairs(scouts) do
                sorted_scouts[zone_id] = {}
                for id,rating in pairs(units) do
                    table.insert(sorted_scouts[zone_id], {
                        id = id,
                        rating = rating,
                        org_rating = rating
                    })
                end
                table.sort(sorted_scouts[zone_id], function(a, b) return a.rating > b.rating end)
            end
            --DBG.dbms(sorted_scouts)

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
                --DBG.dbms(sorted_scouts)
                --print('best:', best_zone, best_id)

                for zone_id,units in pairs(sorted_scouts) do
                    for i_u,data in ipairs(units) do
                        if (data.id == best_id) then
                            table.remove(units, i_u)
                            break
                        end
                    end
                end
                --DBG.dbms(sorted_scouts)

                assigned_units[best_id] = {
                    zone_id = best_zone,
                    action = { action = 'explore' }
                }
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
            --DBG.dbms(units_needed_villages)
            --DBG.dbms(units_assigned_villages)
            --DBG.dbms(assigned_units)
            --DBG.dbms(assigned_enemies)

            local power_stats = fred:calc_power_stats(assigned_units, assigned_enemies, gamedata)
            --DBG.dbms(power_stats)



            -- Finding areas and units for attacking/defending in each zone
            local goal_hexes = {}
            --print('Move toward (highest blurred vulnerability):')
            for zone_id,cfg in pairs(raw_cfgs_main) do

                local max_ld, loc
                for x,y,_ in FU.fgumap_iter(villages_to_protect_maps[zone_id]) do
                    for enemy_id,_ in pairs(gamedata.enemies) do
                        if FU.get_fgumap_value(gamedata.reach_maps[enemy_id], x, y, 'moves_left') then
                            local ld = FU.get_fgumap_value(gamedata.leader_distance_map, x, y, 'distance')
                            if (not max_ld) or (ld > max_ld) then
                                max_ld = ld
                                loc = { x, y }
                            end
                        end
                    end
                end

                if max_ld then
                    --print('max protect ld:', zone_id, max_ld, loc[1], loc[2])
                    goal_hexes[zone_id] = { x = loc[1], y = loc[2] }
                else
                    goal_hexes[zone_id] = { x = cfg.center_hex[1], y = cfg.center_hex[2] }
                end
            end
            --DBG.dbms(goal_hexes)


            local distance_from_front = {}
            for id,_ in pairs(gamedata.my_units) do
                if (not gamedata.unit_infos[id].canrecruit) then
                    distance_from_front[id] = {}
                    for zone_id,data in pairs(goal_hexes) do
                        local _, cost = wesnoth.find_path(gamedata.unit_copies[id], data.x, data.y)
                        cost = cost + gamedata.unit_infos[id].max_moves - gamedata.unit_infos[id].moves
                        --print('    ' .. id, cost)

                        distance_from_front[id][zone_id] = cost / gamedata.unit_infos[id].max_moves
                    end
                end
            end
            --DBG.dbms(distance_from_front)


            local enemy_value_ratio = 1.25
            local attacker_ratings = {}
            local max_rating
            for id,_ in pairs(gamedata.my_units) do
                if (not gamedata.unit_infos[id].canrecruit)
                    and (not assigned_units[id])
                then
                    --print(id)
                    attacker_ratings[id] = {}
                    for zone_id,data in pairs(enemies_by_zone) do
                        --print('  ' .. zone_id)

                        local tmp_enemies = {}
                        for enemy_id,_ in pairs(data) do
                            --print('    ' .. enemy_id)
                            local att = unit_attacks[id][enemy_id]

                            local damage_taken = att.counter.enemy_gen_hc * att.counter.taken + att.counter.enemy_extra
                            damage_taken = damage_taken + att.forward.enemy_gen_hc * att.forward.taken + att.forward.enemy_extra

                            local damage_done = att.counter.my_gen_hc * att.counter.done + att.counter.my_extra
                            damage_done = damage_done + att.forward.my_gen_hc * att.forward.done + att.forward.my_extra

                            local enemy_rating = enemy_value_ratio * damage_done - damage_taken
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
                        table.sort(tmp_enemies, function(a, b) return a.enemy_rating < b.enemy_rating end)
                        local n = math.min(3, #tmp_enemies)
                        for i = #tmp_enemies,n+1,-1 do
                            table.remove(tmp_enemies, i)
                        end

                        if (#tmp_enemies > 0) then
                            local av_damage_taken, av_damage_done = 0, 0
                            local cum_weight, n_enemies = 0, 0
                            for _,enemy in pairs(tmp_enemies) do
                                --print('    ' .. enemy.enemy_id)
                                local enemy_weight = FU.unit_base_power(gamedata.unit_infos[id])
                                cum_weight = cum_weight + enemy_weight
                                n_enemies = n_enemies + 1

                                --print('      taken, done:', enemy.damage_taken, enemy.damage_done)

                                -- For this purpose, we use individual damage, rather than combined
                                local frac_taken = enemy.damage_taken - enemy.my_regen
                                frac_taken = frac_taken / gamedata.unit_infos[id].hitpoints
                                --print('      frac_taken 1', frac_taken)
                                frac_taken = FU.weight_s(frac_taken, 0.5)
                                --print('      frac_taken 2', frac_taken)
                                --if (frac_taken > 1) then frac_taken = 1 end
                                --if (frac_taken < 0) then frac_taken = 0 end
                                av_damage_taken = av_damage_taken + enemy_weight * frac_taken * gamedata.unit_infos[id].max_hitpoints

                                local frac_done = enemy.damage_done - enemy.enemy_regen
                                frac_done = frac_done / gamedata.unit_infos[enemy.enemy_id].hitpoints
                                --print('      frac_done 1', frac_done)
                                frac_done = FU.weight_s(frac_done, 0.5)
                                --print('      frac_done 2', frac_done)
                                --if (frac_done > 1) then frac_done = 1 end
                                --if (frac_done < 0) then frac_done = 0 end
                                av_damage_done = av_damage_done + enemy_weight * frac_done * gamedata.unit_infos[enemy.enemy_id].max_hitpoints

                                --print('  ', av_damage_taken, av_damage_done, cum_weight)
                            end

                            --print('  cum: ', av_damage_taken, av_damage_done, cum_weight)
                            av_damage_taken = av_damage_taken / cum_weight
                            av_damage_done = av_damage_done / cum_weight
                            --print('  av:  ', av_damage_taken, av_damage_done)

                            -- We want the ToD-independent rating here.
                            -- The rounding is going to be off for ToD modifier, but good enough for now
                            av_damage_taken = av_damage_taken / gamedata.unit_infos[id].tod_mod
                            av_damage_done = av_damage_done / gamedata.unit_infos[id].tod_mod

                            -- The rating must be positive for the analysis below to work
                            local av_hp_left = gamedata.unit_infos[id].max_hitpoints - av_damage_taken
                            if (av_hp_left < 0) then av_hp_left = 0 end

                            local attacker_rating = enemy_value_ratio * av_damage_done + av_hp_left
                            attacker_ratings[id][zone_id] = attacker_rating

                            if (not max_rating) or (attacker_rating > max_rating) then
                                max_rating = attacker_rating
                            end
                            --print('  -->', attacker_rating)
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
                unit_ratings[id] = {}

                for zone_id,rating in pairs(zone_ratings) do
                    local distance = distance_from_front[id][zone_id]
                    if (distance < 1) then distance = 1 end
                    local distance_rating = 1 / distance

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
                    if max_other_zone then
                        total_rating = total_rating / math.sqrt(max_other_zone / ratings.this_zone)
                    end
                    -- TODO: might or might not want to normalize this again
                    -- currently don't think it's needed

                    unit_ratings[id][zone_id].max_other_zone = max_other_zone

                    unit_ratings[id][zone_id].rating = total_rating
                end
            end
            --DBG.dbms(unit_ratings)


            local keep_trying = true
            while keep_trying do
                keep_trying = false
                --print()

                local max_rating, best_zone, best_unit
                for zone_id,data in pairs(power_stats.zones) do
                    -- Base rating for the zone is the power missing times the ratio of
                    -- power missing to power needed
                    local ratio = 1
                    if (data.power_needed > 0) then
                        ratio = data.power_missing / data.power_needed
                    end
                    local zone_rating = data.power_missing * math.sqrt(ratio)
                    --print(zone_id, data.power_missing .. '/' .. data.power_needed .. ' = ' .. ratio, zone_rating)

                    for id,unit_zone_ratings in pairs(unit_ratings) do
                        local unit_rating = 0
                        local unit_zone_rating = 1
                        if unit_zone_ratings[zone_id] and unit_zone_ratings[zone_id].rating then
                            unit_zone_rating = unit_zone_ratings[zone_id].rating
                            unit_rating = unit_zone_rating * zone_rating
                        end

                        local inertia = 0
                        if pre_assigned_units[id] and (pre_assigned_units[id] == zone_id) then
                            inertia = 0.5 * FU.unit_base_power(gamedata.unit_infos[id]) * unit_zone_rating
                        end

                        unit_rating = unit_rating + inertia

                        if (unit_rating > 0) and ((not max_rating) or (unit_rating > max_rating)) then
                            max_rating = unit_rating
                            best_zone = zone_id
                            best_unit = id
                        end
                        --print('  ' .. id, inertia, unit_rating)
                    end
                end

                if best_unit then
                    --print('--> ' .. best_zone, best_unit, gamedata.unit_copies[best_unit].x .. ',' .. gamedata.unit_copies[best_unit].y)
                    assigned_units[best_unit] = { zone_id = best_zone }
                    unit_ratings[best_unit] = nil
                    power_stats = fred:calc_power_stats(assigned_units, assigned_enemies, gamedata)

                    --DBG.dbms(assigned_units)
                    --DBG.dbms(unit_ratings)
                    --DBG.dbms(power_stats)

                    if (next(unit_ratings)) then
                        keep_trying = true
                    end
                end
            end
            --DBG.dbms(assigned_units)
            --DBG.dbms(power_stats)

            local units_by_zone = {}
            for id,tbl in pairs(assigned_units) do
                local zone_id = tbl.zone_id

                if (not units_by_zone[zone_id]) then
                    units_by_zone[zone_id] = {}
                end
                units_by_zone[zone_id][id] = zone_id
            end
            --DBG.dbms(units_by_zone)


            -- Everybody left at this time goes on the reserve list
            --DBG.dbms(unit_ratings)
            local reserve_units = {}
            for id,_ in pairs(unit_ratings) do
                reserve_units[id] = true
            end
            attacker_ratings = nil
            unit_ratings = nil

            power_stats = fred:calc_power_stats(assigned_units, assigned_enemies, gamedata)
            --DBG.dbms(power_stats)
            --DBG.dbms(reserve_units)


            -- There will likely only be units on the reserve list at the very beginning
            -- or maybe when the AI is winning.  So for now, we'll just distribute
            -- them between the zones.
            -- TODO: reconsider later whether this is the best thing to do.
            local total_weight = 0
            for zone_id,cfg in pairs(raw_cfgs_main) do
                --print(zone_id, cfg.zone_weight)
                total_weight = total_weight + cfg.zone_weight
            end
            --print('total_weight', total_weight)

            while next(reserve_units) do
                --print('power: assigned / desired --> deficit')
                local max_deficit, best_zone_id
                for zone_id,cfg in pairs(raw_cfgs_main) do
                    local desired_power = power_stats.total.my_power * cfg.zone_weight / total_weight
                    local assigned_power = power_stats.zones[zone_id].my_power
                    local deficit = desired_power - assigned_power
                    --print(zone_id, assigned_power .. ' / ' .. desired_power, deficit)

                    if (not max_deficit) or (deficit > max_deficit) then
                        max_deficit, best_zone_id = deficit, zone_id
                    end
                end
                --print('most in need: ' .. best_zone_id)

                -- Find the best unit for this zone
                local x, y = raw_cfgs_main[best_zone_id].center_hex[1], raw_cfgs_main[best_zone_id].center_hex[2]
                local max_rating, best_id
                for id,_ in pairs(reserve_units) do
                    local _, cost = wesnoth.find_path(gamedata.unit_copies[id], x, y, { ignore_units = true })
                    local turns = math.ceil(cost / gamedata.unit_infos[id].max_moves)

                    -- Significant difference in power can override difference in turns to get there
                    local power_rating = FU.unit_base_power(gamedata.unit_infos[id])
                    power_rating = power_rating / 10

                    local rating = - turns + power_rating
                    --print(id, cost, turns, power_rating)
                    --print('  --> rating: ' .. rating)

                    if (not max_rating) or (rating > max_rating) then
                        max_rating, best_id = rating, id
                    end
                end
                --print('best:', best_zone_id, best_id)
                assigned_units[best_id] = { zone_id = best_zone_id }
                reserve_units[best_id] = nil
                power_stats = fred:calc_power_stats(assigned_units, assigned_enemies, gamedata)
                --DBG.dbms(power_stats)
            end


            -- At this point we have (TODO: decide which of those are to be kept):
            -- IM: my_influence, enemy_influence, influence, tension, vulnerability, blurred_vulnerability
            -- leader_distance_map
            -- assigned_enemies, enemies_by_zone
            -- assigned_units (incl. action if known)
            -- zone_village_goals
            -- villages_to_protect_maps
            -- power_stats
            -- goal_hexes
            -- reserve_units (not used at the moment)
            -- unit_attacks
            -- enemy_int_influence_map

            --DBG.dbms(assigned_units)
            --DBG.dbms(reserve_units)
            --DBG.dbms(immediate_actions)
            --DBG.dbms(goal_hexes)

            fred.data.behavior.assigned_units = assigned_units
            fred.data.behavior.immediate_actions = immediate_actions
            --fred.data.behavior.power_stats = power_stats

            fred.data.turn_data.IM = IM
            fred.data.turn_data.unit_attacks = unit_attacks
            fred.data.villages_to_protect_maps = villages_to_protect_maps
            fred.data.enemy_int_influence_map = enemy_int_influence_map

            FU.print_debug(show_debug_analysis, '--- Done determining behavior ---\n')
            --DBG.dbms(fred.data.behavior)
        end


        function fred:update_orders()
            -- This gets called after each move (or set of moves)

            local gamedata = fred.data.gamedata
            local raw_cfgs_main = fred:get_raw_cfgs()
            local side_cfgs = fred:get_side_cfgs()

            -- What needs to be protected

            local orders = {}

            -- TODO: currently, the village grabber assignment is run twice at the
            -- beginning of the turn; I don't think that's a problem, but it should be
            -- cleaned up anyway
            -- It does need to be rerun after each move, as a village might have opened up for grabbing
            local zone_village_goals
            zone_village_goals, fred.data.villages_to_protect_maps = FVU.village_goals(raw_cfgs_main, side_cfgs, gamedata)
            --DBG.dbms(zone_village_goals)
            --DBG.dbms(villages_to_protect_maps)

            local best_captures = FVU.assign_grabbers(
                zone_village_goals,
                fred.data.behavior.assigned_units,
                fred.data.behavior.immediate_actions,
                fred.data.turn_data.unit_attacks,
                gamedata
            )
            --DBG.dbms(fred.data.behavior.immediate_actions)



            -- For now, every village on our side of the map that can be reached
            -- by an enemy needs to be protected
            --DBG.dbms(villages_to_protect_maps)
            for zone_id,map in pairs(fred.data.villages_to_protect_maps) do
                orders[zone_id] = { protect_villages = false }
                local max_ld, loc
                for x,y,_ in FU.fgumap_iter(map) do
                    for enemy_id,_ in pairs(gamedata.enemies) do
                        if FU.get_fgumap_value(gamedata.reach_maps[enemy_id], x, y, 'moves_left') then
                            orders[zone_id].protect_villages = true

                            local ld = FU.get_fgumap_value(gamedata.leader_distance_map, x, y, 'distance')
                            if (not max_ld) or (ld > max_ld) then
                                max_ld = ld
                                loc = { x, y }
                            end
                        end
                    end
                end

                if max_ld then
                    orders[zone_id].hold_leader_distance = max_ld
                    orders[zone_id].protect_loc = loc
                end
            end
            --DBG.dbms(orders)
            fred.data.behavior.orders = orders
        end


        function fred:analyze_leader_threat()
            local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'zone_control'
            if debug_eval then print_time('     - Evaluating leader threat map analysis:') end

            local gamedata = fred.data.gamedata
            local stage_id = fred.data.analysis.stage_ids[fred.data.analysis.stage_counter]

            FU.print_debug(show_debug_analysis, '\nAnalysis of stage ' .. stage_id)

            -- Start with an analysis of the threat to the AI leader
            local leader_proxy = wesnoth.get_unit(gamedata.leader_x, gamedata.leader_y)

            local raw_cfg = fred:get_raw_cfgs('leader')
            local zone_id = raw_cfg.zone_id
            --DBG.dbms(raw_cfg)

            local threats = fred.data.analysis.threats[zone_id]
            --DBG.dbms(fred.data.analysis.threats)
            --DBG.dbms(threats)

            -- Add up the power of all threats on this zone
            local enemy_power = 0
            for id,power in pairs(threats) do
                enemy_power = enemy_power + power
            end

            FU.print_debug(show_debug_analysis, '  enemy_power in direct threats: ', enemy_power)

            -- Power missing (which is not equal to power_needed - power_used!)
            -- TODO: check whether these hard-coded values are right

            local power_needed = enemy_power

            local power_used = 0
            for id,unit_used in pairs(fred.data.analysis.status.units_used) do
                if (unit_used.zone_id == zone_id) then
                    power_used = power_used + gamedata.unit_infos[id].power
                end
            end

            FU.print_debug(show_debug_analysis, '  power_needed, power_used: ', power_needed, power_used)

            -- We count a fraction of the leader's power as available in the leader zone
            -- This is done independently of whether the leader has moved or not
            local leader_power_fraction = 0.5
            local leader_power = gamedata.unit_infos[leader_proxy.id].power
            FU.print_debug(show_debug_analysis, '  leader_power: ', leader_power * leader_power_fraction .. ' = ' .. leader_power .. ' * ' .. leader_power_fraction)

            local power_missing = power_needed - power_used
            power_missing = power_missing - leader_power * leader_power_fraction
            FU.print_debug(show_debug_analysis, '  power_missing: ', power_missing)

            local power_missing_margin = 2


            -- If the threats are significant, leader should retreat (or have
            -- MP taken away) and recruit after no more attacks are advisable

            -- Find all units that can actually attack the leader
            -- Note: this is different from those stored in 'threats'
            --print('  leader at', gamedata.leader_x, gamedata.leader_y)
            local ids = FU.get_fgumap_value(gamedata.enemy_attack_map[1], gamedata.leader_x, gamedata.leader_y, 'ids', {})

            -- Check out how much of a threat these units pose in combination
            local max_total_loss, av_total_loss = 0, 0
            --print('    possible damage by enemies in reach (average, max):')
            for _,id in ipairs(ids) do
                -- TODO: for now, just use the hex adjacent to the leader with
                -- the highest defense rating for the attacker
                -- This might be good enough, or need to be refined later
                local dst
                local max_defense = 0
                for xa,ya in H.adjacent_tiles(gamedata.leader_x, gamedata.leader_y) do
                    local defense = FGUI.get_unit_defense(gamedata.unit_copies[id], xa, ya, gamedata.defense_maps)

                    if (defense > max_defense) then
                        max_defense = defense
                        dst = { xa, ya }
                    end
                end

                local att_stat, def_stat = FAU.battle_outcome(
                    gamedata.unit_copies[id], leader_proxy,
                    dst,
                    gamedata.unit_infos[id], gamedata.unit_infos[leader_proxy.id],
                    gamedata, fred.data.move_cache
                )
                --DBG.dbms(att_stat)
                --DBG.dbms(def_stat)

                local min_hp = 9e99
                for hp,hc in pairs(def_stat.hp_chance) do
                    if (hc > 0) and (hp < min_hp) then
                        min_hp = hp
                    end
                end

                local max_loss = leader_proxy.hitpoints - min_hp
                local av_loss = leader_proxy.hitpoints - def_stat.average_hp

                --print('    ', id, av_loss, max_loss)

                max_total_loss = max_total_loss + max_loss
                av_total_loss = av_total_loss + av_loss
            end
            FU.print_debug(show_debug_analysis, '\n  leader: max_total_loss, av_total_loss', max_total_loss, av_total_loss)

            -- We only consider these leader threats, if they either
            --   - reduce current HP by more than 50%
            --   - are more than 25% of max HP
            local significant_threat = false
            if (max_total_loss >= leader_proxy.hitpoints / 2.) or (av_total_loss >= leader_proxy.max_hitpoints / 4.) then
                significant_threat = true
            end
            FU.print_debug(show_debug_analysis, '    significant_threat', significant_threat)


            -- Attacks on threats is with unlimited resources
            local attack1_cfg = {
                zone_id = zone_id,
                stage_id = stage_id,
                targets = {},
                actions = { attack = true },
                value_ratio = 0.7 -- more aggressive for direct leader threats, but not too much
            }

            for id,_ in pairs(threats) do
                local target = {}
                target[id] = gamedata.enemies[id]
                table.insert(attack1_cfg.targets, target)
            end
            --DBG.dbms(attack1_cfg)

            fred.data.zone_cfgs = {}
            table.insert(fred.data.zone_cfgs, attack1_cfg)

            -- Retreat the leader if the threat is significant,
            -- or take his MP away
            if significant_threat then
                if (leader_proxy.moves > 0) then
                    local zone_id = 'leader'
                    local move_leader_to_keep_cfg = {
                        zone_id = zone_id,
                        stage_id = stage_id,
                        actions = { move_leader_to_keep = true }
                    }

                    table.insert(fred.data.zone_cfgs, move_leader_to_keep_cfg)
                end


                -- Check whether recruiting can be done; this needs to be done here
                -- as units are taken off the map during get_zone_action()
                -- It also cannot be left to the exec function or the whole CA
                -- might get blacklisted
                local outofway_units = {}
                for id,_ in pairs(fred.data.gamedata.my_units_MP) do
                    if (not fred.data.gamedata.unit_infos[id].canrecruit) then
                        -- Need to check whether units with MP actually have an
                        -- empty hex to move to, as two units with MP might be
                        -- blocking each other.
                        for x,arr in pairs(gamedata.reach_maps[id]) do
                            for y,_ in pairs(arr) do
                                if (not wesnoth.get_unit(x, y)) then
                                    outofway_units[id] = true
                                    break
                                end
                            end
                        end

                    end
                end

                if (fred:recruit_rushers_eval(outofway_units) > 0)
                    and fred:recruit_rushers_exec(nil, nil, outofway_units, true)
                then
                    local zone_id = 'leader'
                    local recruit_cfg = {
                        zone_id = zone_id,
                        stage_id = stage_id,
                        actions = { recruit = true },
                        outofway_units = outofway_units
                    }

                    table.insert(fred.data.zone_cfgs, recruit_cfg)
                end


                -- We also want to retreat or immobilize the leader at this time,
                -- so that we don't protect him first, and then he moves out of the cover
                if (leader_proxy.moves > 0) then
                    local zone_id = 'leader'
                    local retreat_cfg = {
                        zone_id = zone_id,
                        stage_id = stage_id,
                        actions = { retreat = true },
                        retreaters = {},
                        retreat_all = true,
                        enemy_count_weight = 5,
                        stop_unit = true
                    }

                    retreat_cfg.retreaters[leader_proxy.id] = true

                    table.insert(fred.data.zone_cfgs, retreat_cfg)
                end
            end


            -- Move unit toward leader if there's power missing
            if (power_missing > power_missing_margin) then
                local advance1_cfg = {
                    zone_id = raw_cfg.zone_id,
                    stage_id = stage_id,
                    actions = { advance = true },
                    ignore_villages = true, -- main goal is to get toward the leader
                    ignore_counter = true,  -- and need to do so very aggressively
                    value_ratio = 0.67,
                    power_missing = power_missing
                }
                table.insert(fred.data.zone_cfgs, advance1_cfg)
            end

            -- We also add in other units in the zone for attacks, but
            -- with a less aggressive value_ratio
            local attack2_cfg = {
                zone_id = raw_cfg.zone_id,
                stage_id = stage_id,
                targets = {},
                actions = { attack = true }
            }

            for id,loc in pairs(gamedata.enemies) do
                if (not threats[id])
                    and wesnoth.match_unit(gamedata.unit_copies[id], raw_cfg.threat_slf)
                then
                    local target = {}
                    target[id] = loc
                    table.insert(attack2_cfg.targets, target)
                end
            end
            --DBG.dbms(attack2_cfg)
            table.insert(fred.data.zone_cfgs, attack2_cfg)

            -- Favorable attacks can be done at any time after threats to
            -- the AI leader are dealt with
            local zone_id = 'favorable_attacks'
            -- Don't set a status for this "zone"

            local favorable_attacks_cfg = {
                zone_id = zone_id,
                stage_id = stage_id,
                actions = { attack = true },
                value_ratio = 2.0, -- only very favorable attacks will pass this
                max_attackers = 2
            }
            table.insert(fred.data.zone_cfgs, favorable_attacks_cfg)

            --DBG.dbms(fred.data.zone_cfgs)
        end


        function fred:analyze_defend_zones()
            local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'zone_control'
            if debug_eval then print_time('     - Evaluating defend zones map analysis:') end

            local gamedata = fred.data.gamedata
            local stage_id = fred.data.behavior.turn.stage_ids[fred.data.behavior.turn.stage_counter]
            local behavior = fred.data.behavior
            FU.print_debug(show_debug_analysis, '\nAnalysis of stage ' .. stage_id)

            -- These are only the raw_cfgs of the 3 main zones
            local raw_cfgs_main = fred:get_raw_cfgs()
            --DBG.dbms(raw_cfgs_main)
            --DBG.dbms(fred.data.analysis)

            fred.data.zone_cfgs = {}
            local units_for_zone = {}

            if behavior.assigned_units then
                for id,data in pairs(behavior.assigned_units) do
                    if gamedata.my_units_MP[id] then
                        local zone_id = data.zone_id
                        if (not units_for_zone[zone_id]) then units_for_zone[zone_id] = {} end

                        units_for_zone[zone_id][id] = true
                    end
                end
            end
            --DBG.dbms(units_for_zone)

            local base_ratings = {
                village_grab = 9000,
                attack = 8000,
                hold = 8000 - 0.01,
                advance = 1000
            }


            for zone_id,zone_units in pairs(units_for_zone) do
                    -- Attack --
                    local zone_cfg_attack = {
                        zone_id = zone_id,
                        stage_id = stage_id,
                        actions = { attack = true },
                        rating = base_ratings.attack
                    }
                    table.insert(fred.data.zone_cfgs, zone_cfg_attack)

                    -- Hold --
                    local zone_cfg_hold = {
                        zone_id = zone_id,
                        stage_id = stage_id,
                        actions = { hold = true },
                        zone_units = zone_units,
                        rating = base_ratings.hold
                    }
                    table.insert(fred.data.zone_cfgs, zone_cfg_hold)

                    -- Advance --
                    local zone_cfg_advance = {
                        zone_id = zone_id,
                        stage_id = stage_id,
                        actions = { advance = true },
                        zone_units = zone_units,
                        rating = base_ratings.advance
                    }
                    table.insert(fred.data.zone_cfgs, zone_cfg_advance)
            end
            --DBG.dbms(fred.data.zone_cfgs)

            -- Now sort by the ratings embedded in the cfgs
            table.sort(fred.data.zone_cfgs, function(a, b) return a.rating > b.rating end)

            --DBG.dbms(fred.data.zone_cfgs)
        end

        function fred:analyze_all_map()
            local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'all_map'
            if debug_eval then print_time('     - Evaluating all_map CA:') end

            local gamedata = fred.data.gamedata
            local stage_id = fred.data.analysis.stage_ids[fred.data.analysis.stage_counter]
            local stage_status = fred.data.analysis.status[stage_id]
            local behavior = fred.data.behavior

            fred.data.zone_cfgs = {}

            local straight_line = false
            if (behavior.total.my_total_power > behavior.total.my_total_power * 2) then
                straight_line = true
            end

            ----- Attack all remaining valid targets -----

            local zone_id = 'attack_all'
            local attack_all_cfg = {
                zone_id = zone_id,
                stage_id = stage_id,
                actions = { attack = true },
                value_ratio = behavior.total.value_ratio
            }

            table.insert(fred.data.zone_cfgs, attack_all_cfg)



            ----- Retreat remaining injured units -----

            local zone_id = 'retreat'
            local retreat_cfg = {
                zone_id = zone_id,
                stage_id = stage_id,
                actions = { retreat = true }
            }

            table.insert(fred.data.zone_cfgs, retreat_cfg)


            ----- Rush in east (hold and advance) -----
            local zone_id = 'all_map'
            local advance_cfg = {
                zone_id = zone_id,
                stage_id = stage_id,
                actions = {
--                    hold = true,
                    advance = true,
                    straight_line = true
                },
                value_ratio = behavior.total.value_ratio
            }

            table.insert(fred.data.zone_cfgs, advance_cfg)


            local zone_id = 'retreat_all'
            local retreat_cfg = {
                zone_id = zone_id,
                stage_id = stage_id,
                actions = { retreat = true },
                retreat_all = true,
                -- The value of 5 below means it take preference over rest
                -- healing (value of 2^2), but not over village or regeneration
                -- healing (8^2)
                enemy_count_weight = 5
            }

            table.insert(fred.data.zone_cfgs, retreat_cfg)
        end


        function fred:analyze_map()
            -- Some pointers just for convenience
            local stage_id = fred.data.behavior.turn.stage_ids[fred.data.behavior.turn.stage_counter]

            --print('Doing map analysis for stage: ' .. stage_id)

            if (stage_id == 'leader_threat') then
                fred:analyze_leader_threat()
                return
            end

            if (stage_id == 'defend_zones') then
                fred:analyze_defend_zones()
                return
            end

            if (stage_id == 'all_map') then
                fred:analyze_all_map()
                return
            end
        end


        ----- Functions for getting the best actions -----

        ----- Attack: -----
        function fred:get_attack_action(zonedata)
            if debug_eval then print_time('  --> attack evaluation: ' .. zonedata.cfg.zone_id) end
            --DBG.dbms(zonedata.cfg)

            local gamedata = fred.data.gamedata
            local move_cache = fred.data.move_cache

            local targets = {}
            -- If cfg.attack.use_enemies_in_reach is set, we use all enemies that
            -- can get to the zone (Note: this should only be used for small zones,
            -- such as that consisting only of the AI leader position, otherwise it
            -- might be very slow!!!)
            if zonedata.cfg.targets then
                targets = zonedata.cfg.targets
            elseif zonedata.cfg.use_enemies_in_reach then
                for id,loc in pairs(gamedata.enemies) do
                    for x,tmp in pairs(zonedata.zone_map) do
                        for y,_ in pairs(tmp) do
                            if gamedata.enemy_attack_map[x]
                                and gamedata.enemy_attack_map[x][y]
                                and gamedata.enemy_attack_map[x][y][id]
                            then
                                local target = {}
                                target[id] = loc
                                table.insert(targets, target)
                                break
                            end
                        end
                    end
                end
            -- Otherwise use all units inside the zone (or all units on the
            -- map if cfg.unit_filter is not set)
            else
                for id,loc in pairs(gamedata.enemies) do
                    if wesnoth.match_unit(gamedata.unit_copies[id], zonedata.cfg.unit_filter) then
                        local target = {}
                        target[id] = loc
                        table.insert(targets, target)
                    end
                end
            end
            FU.print_debug(show_debug_attack, '  #targets', #targets, zonedata.cfg.zone_id)
            --DBG.dbms(targets)


            -- Determine whether we need to keep a keep hex open for the leader
            local available_keeps = {}
            local leader = fred.data.gamedata.leaders[wesnoth.current.side]
            local leader_info = gamedata.unit_infos[leader.id]

            -- If the leader cannot move, don't do anything
            if (leader_info.moves > 0) then
                local width,height,border = wesnoth.get_map_size()
                local keeps = wesnoth.get_locations {
                    terrain = 'K*,K*^*,*^K*', -- Keeps
                    x = '1-'..width,
                    y = '1-'..height
                }

                for _,keep in ipairs(keeps) do
                    local leader_can_reach = FU.get_fgumap_value(gamedata.reach_maps[leader_info.id], keep[1], keep[2], 'moves_left')
                    if leader_can_reach then
                        table.insert(available_keeps, keep)
                    end
                end

            end
            --DBG.dbms(available_keeps)

            local attacker_map = {}
            for id,loc in pairs(zonedata.zone_units_attacks) do
                attacker_map[loc[1] * 1000 + loc[2]] = id
            end

            -- How much more valuable do we consider the enemy units than our own
            local value_ratio = FU.cfg_default('value_ratio')
            if zonedata.cfg.value_ratio then
                value_ratio = zonedata.cfg.value_ratio
            end
            --print_time('value_ratio', value_ratio)

            local cfg_attack = {
                value_ratio = value_ratio,
                use_max_damage_weapons = true
            }

            local combo_ratings = {}
            for _,target in pairs(targets) do
                local target_id, target_loc = next(target)
                local target_proxy = wesnoth.get_unit(target_loc[1], target_loc[2])

                local is_trappable_enemy = true
                if gamedata.unit_infos[target_id].abilities.skirmisher then
                    is_trappable_enemy = false
                end

                -- We also count unit that are already trapped as untrappable
                if gamedata.trapped_enemies[target_id] then
                    is_trappable_enemy = false
                end
                FU.print_debug(show_debug_attack, target_id, '  trappable:', is_trappable_enemy, target_loc[1], target_loc[2])

                local attack_combos = FAU.get_attack_combos(
                    zonedata.zone_units_attacks, target, gamedata.reach_maps, false, move_cache, cfg_attack
                )
                --print_time('#attack_combos', #attack_combos)

                -- Check if this exceeds allowable resources
                -- For attacks, we allow use of power up to power_missing
                -- TODO: might need to add some margin or contingency to this

                -- TODO: check: table.remove might be slow

                local allowable_power = zonedata.cfg.power_missing or 9e99
                --print('  allowable_power', allowable_power)

                for j = #attack_combos,1,-1 do
                    local combo = attack_combos[j]
                    --print('  combo #' .. j)
                    local n_attackers = 0
                    local tmp_attackers = {}
                    for src,dst in pairs(combo) do
                        --print('    attacker power:', gamedata.unit_infos[attacker_map[src]].id, gamedata.unit_infos[attacker_map[src]].power)
                        table.insert(tmp_attackers, { id = gamedata.unit_infos[attacker_map[src]].id })
                        n_attackers = n_attackers + 1
                    end
                end
                --print_time('#attack_combos', #attack_combos)
                --DBG.dbms(attack_combos)


                for j,combo in ipairs(attack_combos) do
                    --print_time('combo ' .. j)

                    -- Only check out the first 1000 attack combos to keep evaluation time reasonable
                    if (j > 1000) then break end

                    -- attackers and dsts arrays for stats calculation

                    local attempt_trapping = is_trappable_enemy

                    local attacker_copies, dsts, attacker_infos = {}, {}, {}
                    for src,dst in pairs(combo) do
                        table.insert(attacker_copies, gamedata.unit_copies[attacker_map[src]])
                        table.insert(attacker_infos, gamedata.unit_infos[attacker_map[src]])
                        table.insert(dsts, { math.floor(dst / 1000), dst % 1000 } )
                    end


                    local combo_att_stats, combo_def_stat, sorted_atts, sorted_dsts, combo_rt, combo_attacker_damages, combo_defender_damage =
                        FAU.attack_combo_eval(
                            attacker_copies, target_proxy, dsts,
                            attacker_infos, gamedata.unit_infos[target_id],
                            gamedata, move_cache, cfg_attack
                    )
                    local combo_rating = combo_rt.rating

                    local bonus_rating = 0

                    --DBG.dbms(combo_rt)
                    --print('   combo ratings: ', combo_rt.rating, combo_rt.attacker.rating, combo_rt.defender.rating)

                    -- Don't attack if the leader is involved and has chance to die > 0
                    local do_attack = true

                    -- Don't do if this would take all the keep hexes away from the leader
                    -- TODO: this is a double loop; do this for now, because both arrays
                    -- are small, but optimize later
                    if do_attack and (#available_keeps > 0) then
                        do_attack = false
                        for _,keep in ipairs(available_keeps) do
                            local keep_taken = false
                            for i_d,dst in ipairs(dsts) do
                                if (not attacker_copies[i_d].canrecruit)
                                    and (keep[1] == dst[1]) and (keep[2] == dst[2])
                                then
                                    keep_taken = true
                                    break
                                end
                            end
                            if (not keep_taken) then
                                do_attack = true
                                break
                            end
                        end
                    end
                    --print('  ******* do_attack after keep check:', do_attack)

                    -- Don't do this attack if the leader has a chance to get killed, poisoned or slowed
                    if do_attack then
                        for k,att_stat in ipairs(combo_att_stats) do
                            if (sorted_atts[k].canrecruit) then
                                if (att_stat.hp_chance[0] > 0.0) or (att_stat.slowed > 0.0) then
                                    do_attack = false
                                    break
                                end

                                if (att_stat.poisoned > 0.0) and (not sorted_atts[k].abilities.regenerate) then
                                    do_attack = false
                                    break
                                end
                            end
                        end
                    end

                    if do_attack then
                        -- Discourage attacks from hexes adjacent to villages that are
                        -- unoccupied by an AI unit without MP or one of the attackers,
                        -- except if it's the hex the target is on, of course

                        local adj_villages_map = {}
                        for _,dst in ipairs(sorted_dsts) do
                            for xa,ya in H.adjacent_tiles(dst[1], dst[2]) do
                                if gamedata.village_map[xa] and gamedata.village_map[xa][ya]
                                   and ((xa ~= target_loc[1]) or (ya ~= target_loc[2]))
                                then
                                    --print('next to village:')
                                    if (not adj_villages_map[xa]) then adj_villages_map[xa] = {} end
                                    adj_villages_map[xa][ya] = true
                                    adj_unocc_village = true
                                end
                            end
                        end

                        -- Now check how many of those villages are occupied or used in the attack
                        local adj_unocc_village = 0
                        for x,map in pairs(adj_villages_map) do
                            for y,_ in pairs(map) do
                                adj_unocc_village = adj_unocc_village + 1
                                if gamedata.my_unit_map_noMP[x] and gamedata.my_unit_map_noMP[x][y] then
                                    --print('Village is occupied')
                                    adj_unocc_village = adj_unocc_village - 1
                                else
                                    for _,dst in ipairs(sorted_dsts) do
                                        if (dst[1] == x) and (dst[2] == y) then
                                            --print('Village is used in attack')
                                            adj_unocc_village = adj_unocc_village - 1
                                        end
                                    end
                                end

                            end
                        end

                        -- For each such village found, we give a penalty eqivalent to 10 HP of the target
                        if (adj_unocc_village > 0) then
                            if (combo_def_stat.hp_chance[0] < 0.5) then
                                do_attack = false
                            else
                                local unit_value = FU.unit_value(gamedata.unit_infos[target_id])
                                local penalty = 10. / gamedata.unit_infos[target_id].max_hitpoints * unit_value
                                penalty = penalty * adj_unocc_village
                                --print('Applying village penalty', bonus_rating, penalty)
                                bonus_rating = bonus_rating - penalty

                                -- In that case, also don't give the trapping bonus
                                attempt_trapping = false
                            end
                        end
                    end

                    if do_attack then
                        -- Do not attempt trapping if the unit is on good terrain,
                        -- except if the target is down to less than half of its hitpoints
                        if (gamedata.unit_infos[target_id].hitpoints >= gamedata.unit_infos[target_id].max_hitpoints/2) then
                            local defense = FGUI.get_unit_defense(gamedata.unit_copies[target_id], target_loc[1], target_loc[2], gamedata.defense_maps)
                            if (defense >= (1 - gamedata.unit_infos[target_id].good_terrain_hit_chance)) then
                                attempt_trapping = false
                            end
                        end

                        -- Give a bonus to attacks that trap the enemy
                        -- TODO: Consider other cases than just two units on each side as well
                        if attempt_trapping then
                            -- Set up a map containing all adjacent hexes that are either occupied
                            -- or used in the attack
                            local adj_occ_hex_map = {}
                            local count = 0
                            for _,dst in ipairs(sorted_dsts) do
                                if (not adj_occ_hex_map[dst[1]]) then adj_occ_hex_map[dst[1]] = {} end
                                adj_occ_hex_map[dst[1]][dst[2]] = true
                                count = count + 1
                            end

                            for xa,ya in H.adjacent_tiles(target_loc[1], target_loc[2]) do
                                if (not adj_occ_hex_map[xa]) or (not adj_occ_hex_map[xa][ya]) then
                                    -- Only units without MP on the AI side are on the map here
                                    if gamedata.my_unit_map_noMP[xa] and gamedata.my_unit_map_noMP[xa][ya] then
                                        if (not adj_occ_hex_map[xa]) then adj_occ_hex_map[xa] = {} end
                                        adj_occ_hex_map[xa][ya] = true
                                        count = count + 1
                                    end
                                end
                            end

                            -- Check whether this is a valid trapping attack
                            local trapping_bonus = false
                            if (count > 1) then
                                trapping_bonus = true

                                -- If it gives the target access to good terrain, we don't do it,
                                -- except if the target is down to less than half of its hitpoints
                                if (gamedata.unit_infos[target_id].hitpoints >= gamedata.unit_infos[target_id].max_hitpoints/2) then
                                    for xa,ya in H.adjacent_tiles(target_loc[1], target_loc[2]) do
                                        if (not adj_occ_hex_map[xa]) or (not adj_occ_hex_map[xa][ya]) then
                                            local defense = FGUI.get_unit_defense(gamedata.unit_copies[target_id], xa, ya, gamedata.defense_maps)
                                            if (defense >= (1 - gamedata.unit_infos[target_id].good_terrain_hit_chance)) then
                                                trapping_bonus = false
                                                break
                                            end
                                        end
                                    end
                                end

                                -- If the previous check did not disqualify the attack,
                                -- check if this would result in trapping
                                if trapping_bonus then
                                    trapping_bonus = false
                                    for x,map in pairs(adj_occ_hex_map) do
                                        for y,_ in pairs(map) do
                                            local opp_hex = AH.find_opposite_hex_adjacent({ x, y }, target_loc)
                                            if opp_hex and adj_occ_hex_map[opp_hex[1]] and adj_occ_hex_map[opp_hex[1]][opp_hex[2]] then
                                                trapping_bonus = true
                                                break
                                            end
                                        end
                                        if trapping_bonus then break end
                                    end
                                end
                            end

                            -- If this is a valid trapping attack, we give a
                            -- bonus eqivalent to 8 HP of the target
                            if trapping_bonus then
                                local unit_value = FU.unit_value(gamedata.unit_infos[target_id])
                                local bonus = 8. / gamedata.unit_infos[target_id].max_hitpoints * unit_value
                                --print('Applying trapping bonus', bonus_rating, bonus)
                                bonus_rating = bonus_rating + bonus
                            end
                        end

                        -- Discourage use of poisoners in attacks that have a
                        -- high chance to result in kill
                        -- TODO: does the value of 0.33 make sense?
                        if (combo_def_stat.hp_chance[0] > 0.33) then
                            local number_poisoners = 0
                            for i_a,attacker in ipairs(sorted_atts) do
                                local is_poisoner = false
                                for _,weapon in ipairs(attacker.attacks) do
                                    if weapon.poison then
                                        number_poisoners = number_poisoners + 1
                                        break
                                    end
                                end
                            end

                            -- For each poisoner in such an attack, we give a penalty eqivalent to 8 HP of the target
                            if (number_poisoners > 0) then
                                local unit_value = FU.unit_value(gamedata.unit_infos[target_id])
                                local penalty = 8. / gamedata.unit_infos[target_id].max_hitpoints * unit_value
                                penalty = penalty * number_poisoners
                                --print('Applying poisoner penalty', bonus_rating, penalty)
                                bonus_rating = bonus_rating - penalty
                            end
                        end

                        --print_time(' -----------------------> rating', combo_rating, bonus_rating)

                        local full_rating = combo_rating + bonus_rating
                        local pre_rating = full_rating

                        if (full_rating > 0) and (#sorted_atts > 2) then
                            pre_rating = pre_rating / ( #sorted_atts / 2)
                        end

                        table.insert(combo_ratings, {
                            rating = full_rating,
                            pre_rating = pre_rating,
                            bonus_rating = bonus_rating,
                            attackers = sorted_atts,
                            dsts = sorted_dsts,
                            target = target,
                            att_stats = combo_att_stats,
                            def_stat = combo_def_stat,
                            rating_table = combo_rt,
                            attacker_damages = combo_attacker_damages,
                            defender_damage = combo_defender_damage
                        })

                        --DBG.dbms(combo_ratings)
                    end
                end
            end
            table.sort(combo_ratings, function(a, b) return a.pre_rating > b.pre_rating end)
            --DBG.dbms(combo_ratings)
            FU.print_debug(show_debug_attack, '#combo_ratings', #combo_ratings)

            -- Now check whether counter attacks are acceptable
            local max_total_rating, action = -9e99
            local disqualified_attacks = {}
            for count,combo in ipairs(combo_ratings) do
                if (count > 50) and action then break end
                FU.print_debug(show_debug_attack, '\nChecking counter attack for attack on', count, next(combo.target), combo.rating_table.value_ratio, combo.rating_table.rating, action)

                -- Check whether an position in this combo was previously disqualified
                -- Only do so for large numbers of combos though; there is a small
                -- chance of a later attack that uses the same hexes being qualified
                -- because the hexes the units are on work better for the forward attack.
                -- So if there are not too many combos, we calculated all of them.
                -- As forward attacks are rated by their attack score, this is
                -- pretty unlikely though.
                local is_disqualified = false
                if (#combo_ratings > 100) then
                    for i_a,attacker_info in ipairs(combo.attackers) do
                        local id, x, y = attacker_info.id, combo.dsts[i_a][1], combo.dsts[i_a][2]
                        local key = id .. (x * 1000 + y)

                        if disqualified_attacks[key] then
                            is_disqualified = FAU.is_disqualified_attack(combo, disqualified_attacks[key])
                            if is_disqualified then
                                break
                            end
                        end
                    end
                end
                --print('  is_disqualified', is_disqualified)

                if (not is_disqualified) then
                    -- TODO: the following is slightly inefficient, as it places units and
                    -- takes them off again several times for the same attack combo.
                    -- This could be streamlined if it becomes an issue, but at the expense
                    -- of either duplicating code or adding parameters to FAU.calc_counter_attack()
                    -- I don't think that it is the bottleneck, so we leave it as it is for now.

                    local old_locs, old_HP_attackers = {}, {}
                    for i_a,attacker_info in ipairs(combo.attackers) do
                        if show_debug_attack then
                            local id, x, y = attacker_info.id, combo.dsts[i_a][1], combo.dsts[i_a][2]
                            W.label { x = x, y = y, text = attacker_info.id }
                        end

                        table.insert(old_locs, gamedata.my_units[attacker_info.id])

                        -- Apply average hitpoints from the forward attack as starting point
                        -- for the counter attack. This isn't entirely accurate, but
                        -- doing it correctly is too expensive, and this is better than doing nothing.
                        -- TODO: It also sometimes overrates poisoned or slowed, as it might be
                        -- counted for both attack and counter attack. This could be done more
                        -- accurately by using a combined chance of getting poisoned/slowed, but
                        -- for now we use this as good enough.
                        table.insert(old_HP_attackers, gamedata.unit_infos[attacker_info.id].hitpoints)

                        local hp = combo.att_stats[i_a].average_hp
                        if (hp < 1) then hp = 1 end
                        gamedata.unit_infos[attacker_info.id].hitpoints = hp
                        gamedata.unit_copies[attacker_info.id].hitpoints = hp

                        -- If the unit is on the map, it also needs to be applied to the unit proxy
                        if gamedata.my_units_noMP[attacker_info.id] then
                            local unit_proxy = wesnoth.get_unit(old_locs[i_a][1], old_locs[i_a][2])
                            unit_proxy.hitpoints = hp
                        end
                    end

                    -- Also set the hitpoints for the defender
                    local target_id, target_loc = next(combo.target)
                    local target_proxy = wesnoth.get_unit(target_loc[1], target_loc[2])
                    local old_HP_target = target_proxy.hitpoints
                    local hp_org = old_HP_target - combo.defender_damage.damage

                    -- As the counter attack happens on the enemy's side next turn,
                    -- delayed damage also needs to be applied
                    hp = H.round(hp_org - combo.defender_damage.delayed_damage)

                    if (hp < 1) then hp = math.min(1, H.round(hp_org)) end
                    --print('hp before, after:', old_HP_target, hp_org, hp)

                    gamedata.unit_infos[target_id].hitpoints = hp
                    gamedata.unit_copies[target_id].hitpoints = hp
                    target_proxy.hitpoints = hp

                    local acceptable_counter = true

                    local min_total_damage_rating = 9e99
                    for i_a,attacker in ipairs(combo.attackers) do
                        FU.print_debug(show_debug_attack, '  by', attacker.id, combo.dsts[i_a][1], combo.dsts[i_a][2])

                        -- Now calculate the counter attack outcome
                        local attacker_moved = {}
                        attacker_moved[attacker.id] = { combo.dsts[i_a][1], combo.dsts[i_a][2] }

                        local counter_stats = FAU.calc_counter_attack(
                            attacker_moved, old_locs, combo.dsts, gamedata, move_cache, cfg_attack
                        )
                        --DBG.dbms(counter_stats)

                        -- The total damage through attack + counter attack should use for
                        -- forward attack: attacker damage rating and defender total rating
                        -- counter attack: attacker total rating and defender damage rating
                        -- as that is how the delayed damage is applied
                        -- In addition, the counter attack damage needs to be multiplied
                        -- by the chance of each unit to survive, otherwise units close
                        -- to dying are much overrated
                        -- That is then the damage that is used for the overall rating

                        -- Damages to AI units (needs to be done for each counter attack
                        -- as tables change upwards also)
                        -- Delayed damages do not apply for attackers

                        -- This is the damage on the AI attacker considered here
                        -- in the counter attack
                        local dam2 = counter_stats.defender_damage
                        --DBG.dbms(dam2)

                        local damages_my_units = {}
                        for i_d,dam1 in ipairs(combo.attacker_damages) do
                            local dam = {}

                            -- First, take all the values as are from the forward combo outcome
                            for k,v in pairs(dam1) do
                                dam[k] = v
                            end

                            -- For the unit considered here, combine the results
                            -- For all other units they remain unchanged
                            if dam2 and (dam1.id == dam2.id) then
                                --print('-- my units --', dam1.id)
                                -- Unchanged: unit_value, max_hitpoints, id

                                --  damage: just add up the two
                                dam.damage = dam1.damage + dam2.damage
                                --print('  damage:', dam1.damage, dam2.damage, dam.damage)

                                local normal_damage_chance1 = 1 - dam1.die_chance - dam1.levelup_chance
                                local normal_damage_chance2 = 1 - dam2.die_chance - dam2.levelup_chance
                                --print('  normal_damage_chance (1, 2)', normal_damage_chance1,normal_damage_chance2)

                                --  - delayed_damage: only take that from the counter attack
                                --  TODO: this might underestimate poison etc.
                                dam.delayed_damage = dam2.delayed_damage
                                --print('  delayed_damage:', dam1.delayed_damage, dam2.delayed_damage, dam.delayed_damage)

                                --  - die_chance
                                dam.die_chance = dam1.die_chance + dam2.die_chance * normal_damage_chance1
                                --print('  die_chance:', dam1.die_chance, dam2.die_chance, dam.die_chance)

                                --  - levelup_chance
                                dam.levelup_chance = dam1.levelup_chance + dam2.levelup_chance * normal_damage_chance1
                                --print('  levelup_chance:', dam1.levelup_chance, dam2.levelup_chance, dam.levelup_chance)
                            end

                            damages_my_units[i_d] = dam
                        end
                        --DBG.dbms(damages_my_units)


                        -- Same for all the enemy units in the counter attack
                        -- Delayed damages do not apply for same reason
                        local dam1 = combo.defender_damage
                        --DBG.dbms(dam1)

                        local damages_enemy_units = {}
                        local target_included = false
                        if counter_stats.attacker_damages then
                            for i_d,dam2 in ipairs(counter_stats.attacker_damages) do
                                local dam = {}

                                -- First, take all the values as are from the counter attack outcome
                                for k,v in pairs(dam2) do
                                    dam[k] = v
                                end

                                -- For the unit considered here, combine the results
                                -- For all other units they remain unchanged
                                if dam1 and (dam1.id == dam2.id) then
                                    target_included = true

                                    --print('-- enemy units --', dam2.id)
                                    -- Unchanged: unit_value, max_hitpoints, id

                                    --  damage: just add up the two
                                    dam.damage = dam1.damage + dam2.damage
                                    --print('  damage:', dam1.damage, dam2.damage, dam.damage)

                                    local normal_damage_chance1 = 1 - dam1.die_chance - dam1.levelup_chance
                                    local normal_damage_chance2 = 1 - dam2.die_chance - dam2.levelup_chance
                                    --print('  normal_damage_chance (1, 2)', normal_damage_chance1,normal_damage_chance2)

                                    --  - delayed_damage: only take that from the forward attack
                                    --  TODO: this might underestimate poison etc.
                                    dam.delayed_damage = dam1.delayed_damage
                                    --print('  delayed_damage:', dam1.delayed_damage, dam2.delayed_damage, dam.delayed_damage)

                                    --  - die_chance
                                    dam.die_chance = dam1.die_chance + dam2.die_chance * normal_damage_chance1
                                    --print('  die_chance:', dam1.die_chance, dam2.die_chance, dam.die_chance)

                                    --  - levelup_chance
                                    dam.levelup_chance = dam1.levelup_chance + dam2.levelup_chance * normal_damage_chance1
                                    --print('  levelup_chance:', dam1.levelup_chance, dam2.levelup_chance, dam.levelup_chance)
                                end

                                damages_enemy_units[i_d] = dam
                            end
                        end

                        -- The following covers both the case when there is no counter attack
                        -- and when the target unit is not included in the counter attack
                        if (not target_included) then
                            table.insert(damages_enemy_units, dam1)
                        end

                        --DBG.dbms(damages_enemy_units)
                        --DBG.dbms(combo)

                        --print('\nratings my units:')
                        local my_rating = 0
                        for _,damage in ipairs(damages_my_units) do
                            local unit_rating = FAU.damage_rating_unit(damage)
                            my_rating = my_rating + unit_rating
                            --print('  ' .. damage.id, unit_rating)
                        end
                        FU.print_debug(show_debug_attack, '  --> total my unit rating:', my_rating)


                        --print('ratings enemy units:')
                        local enemy_rating = 0
                        for _,damage in ipairs(damages_enemy_units) do
                            -- Enemy damage rating is negative!
                            local unit_rating = - FAU.damage_rating_unit(damage)
                            enemy_rating = enemy_rating + unit_rating
                            --print('  ' .. damage.id, unit_rating)
                        end
                        FU.print_debug(show_debug_attack, '  --> total enemy unit rating:', enemy_rating)

                        local extra_rating = combo.rating_table.extra_rating
                        FU.print_debug(show_debug_attack, '  --> extra rating:', extra_rating)
                        FU.print_debug(show_debug_attack, '  --> bonus rating:', combo.bonus_rating)

                        local value_ratio = combo.rating_table.value_ratio
                        FU.print_debug(show_debug_attack, '  --> value_ratio:', value_ratio)

                        local damage_rating = my_rating * value_ratio + enemy_rating + extra_rating

                        -- Also add in the bonus and extra ratings. They are
                        -- used to select the best attack, but not to determine
                        -- whether an attack is acceptable
                        local damage_rating = damage_rating + extra_rating + combo.bonus_rating

                        FU.print_debug(show_debug_attack, '     --> damage_rating:', damage_rating)


                        if (damage_rating < min_total_damage_rating) then
                            min_total_damage_rating = damage_rating
                        end

                        local counter_min_hp = counter_stats.def_stat.min_hp

                        -- We next check whether the counter attack is acceptable
                        -- This is different for the side leader and other units
                        -- Also, it is different for attacks by individual units without MP;
                        -- for those it simply matters whether the attack makes things
                        -- better or worse, since there isn't a coice of moving someplace else

                        if (#combo.attackers > 1) or (attacker.moves > 0) then
                            -- If there's a chance of the leader getting poisoned, slowed or killed, don't do it
                            if attacker.canrecruit then
                                --print('Leader: slowed, poisoned %', counter_stats.def_stat.slowed, counter_stats.def_stat.poisoned)
                                if (counter_stats.def_stat.slowed > 0.0) then
                                    FU.print_debug(show_debug_attack, '       leader: counter attack slow chance too high', counter_stats.def_stat.slowed)
                                    acceptable_counter = false
                                    FAU.add_disqualified_attack(combo, i_a, disqualified_attacks)
                                    break
                                end

                                if (counter_stats.def_stat.poisoned > 0.0) and (not attacker.abilities.regenerate) then
                                    FU.print_debug(show_debug_attack, '       leader: counter attack poison chance too high', counter_stats.def_stat.poisoned)
                                    acceptable_counter = false
                                    FAU.add_disqualified_attack(combo, i_a, disqualified_attacks)
                                    break
                                end

                                -- Add max damages from this turn and counter-attack
                                local min_hp = 0
                                for hp = 0,attacker.hitpoints do
                                    if combo.att_stats[i_a].hp_chance[hp] and (combo.att_stats[i_a].hp_chance[hp] > 0) then
                                        min_hp = hp
                                        break
                                    end
                                end

                                -- Note that this is not really the maximum damage from the attack, as
                                -- attacker.hitpoints is reduced to the average HP outcome of the attack
                                -- However, min_hp for the counter also contains this reduction, so
                                -- min_outcome below has the correct value (except for rounding errors,
                                -- that's why it is compared ot 0.5 instead of 0)
                                local max_damage_attack = attacker.hitpoints - min_hp
                                --print('max_damage_attack, attacker.hitpoints, min_hp', max_damage_attack, attacker.hitpoints, min_hp)

                                -- Add damage from attack and counter attack
                                local min_outcome = counter_min_hp - max_damage_attack
                                --print('Leader: min_outcome, counter_min_hp, max_damage_attack', min_outcome, counter_min_hp, max_damage_attack)

                                if (min_outcome < 0.5) then
                                    FU.print_debug(show_debug_attack, '       leader: counter attack min_outcome too low', min_outcome)
                                    acceptable_counter = false
                                    FAU.add_disqualified_attack(combo, i_a, disqualified_attacks)
                                    break
                                end
                            else  -- Or for normal units, evaluate whether the attack is worth it
                                -- is_acceptable_attack takes the damage to the side, so it needs
                                -- to be the negative of the rating for own units
                                if (not FAU.is_acceptable_attack(-my_rating, enemy_rating, value_ratio)) then
                                    FU.print_debug(show_debug_attack, '       non-leader: counter attack rating too low', my_rating, enemy_rating, value_ratio)
                                    acceptable_counter = false
                                    FAU.add_disqualified_attack(combo, i_a, disqualified_attacks)
                                    break
                                end
                            end
                        end
                    end

                    -- Now reset the hitpoints for attackers and defender
                    for i_a,attacker_info in ipairs(combo.attackers) do
                        gamedata.unit_infos[attacker_info.id].hitpoints = old_HP_attackers[i_a]
                        gamedata.unit_copies[attacker_info.id].hitpoints = old_HP_attackers[i_a]
                        if gamedata.my_units_noMP[attacker_info.id] then
                            local unit_proxy = wesnoth.get_unit(old_locs[i_a][1], old_locs[i_a][2])
                            unit_proxy.hitpoints = old_HP_attackers[i_a]
                        end
                    end

                    gamedata.unit_infos[target_id].hitpoints = old_HP_target
                    gamedata.unit_copies[target_id].hitpoints = old_HP_target
                    target_proxy.hitpoints = old_HP_target


                    -- Now we add the check for attacks by individual units with
                    -- no MP. Here we simply compare the rating of not attacking
                    -- vs. attacking. If attacking results in a better rating, we do it.
                    -- But only if the chance to die in the forward attack is not too
                    -- large; otherwise the enemy might as well waste the resources.
                    if (#combo.attackers == 1) then
                        if (combo.att_stats[1].hp_chance[0] < 0.25) then
                            local attacker = combo.attackers[1]

                            if (attacker.moves == 0) then
                                --print_time('  by', attacker.id, combo.dsts[1][1], combo.dsts[1][2])

                                -- Now calculate the counter attack outcome
                                local attacker_moved = {}
                                attacker_moved[attacker.id] = { combo.dsts[1][1], combo.dsts[1][2] }

                                local counter_stats = FAU.calc_counter_attack(
                                    attacker_moved, old_locs, combo.dsts, gamedata, move_cache, cfg_attack
                                )
                                --DBG.dbms(counter_stats)

                                --print_time('   counter ratings no attack:', counter_stats.rating_table.rating, counter_stats.def_stat.hp_chance[0])

                                -- Rating if no forward attack is done is done is only the counter attack rating
                                local no_attack_rating = 0 - counter_stats.rating_table.rating
                                -- If an attack is done, it's the combined forward and counter attack rating
                                local with_attack_rating = min_total_damage_rating

                                --print('    V1: no attack rating: ', no_attack_rating, '<---', 0, -counter_stats.rating_table.rating)
                                --print('    V2: with attack rating:', with_attack_rating, '<---', combo.rating_table.rating, min_total_damage_rating)

                                if (with_attack_rating < no_attack_rating) then
                                    acceptable_counter = false
                                    -- Note the '1': (since this is a single-unit attack)
                                    FAU.add_disqualified_attack(combo, 1, disqualified_attacks)
                                end
                                --print('acceptable_counter', acceptable_counter)
                            end
                        else
                            -- Otherwise this is only acceptable if the chance to die
                            -- for the AI unit is not greater than for the enemy
                            if (combo.att_stats[1].hp_chance[0] > combo.def_stat.hp_chance[0]) then
                                acceptable_counter = false
                            end
                        end
                    end

                    --print_time('  acceptable_counter', acceptable_counter)
                    if acceptable_counter then
                        local total_rating = min_total_damage_rating
                        FU.print_debug(show_debug_attack, '    Acceptable counter attack for attack on', count, next(combo.target), combo.value_ratio, combo.rating_table.rating)
                        FU.print_debug(show_debug_attack, '      --> total_rating', total_rating)

                        if (total_rating > 0) and (#combo.dsts > 2) then
                            total_rating = total_rating / ( #combo.dsts / 2)
                        end
                        FU.print_debug(show_debug_attack, '      --> total_rating adjusted', total_rating)

                        if (total_rating > max_total_rating) then
                            max_total_rating = total_rating

                            action = { units = {}, dsts = {}, enemy = combo.target }

                            -- This is done simply so that the table is shorter when
                            -- displayed. We could also simply use combo.attackers
                            for _,attacker in ipairs(combo.attackers) do
                                local tmp_unit = gamedata.my_units[attacker.id]
                                tmp_unit.id = attacker.id
                                table.insert(action.units, tmp_unit)
                            end

                            action.dsts = combo.dsts
                            action.action = 'attack'
                        end
                    end

                    if show_debug_attack then
                        wesnoth.scroll_to_tile(target_loc[1], target_loc[2])
                        W.message { speaker = 'narrator', message = 'Attack combo ' .. count .. ': ' .. combo.rating}
                        for i_a,attacker_info in ipairs(combo.attackers) do
                            local id, x, y = attacker_info.id, combo.dsts[i_a][1], combo.dsts[i_a][2]
                            W.label { x = x, y = y, text = "" }
                        end
                    end
                end
            end

            --DBG.dbms(disqualified_attacks)

            return action  -- returns nil is no acceptable attack was found
        end


        ----- Hold: -----
        function fred:get_hold_action(zonedata)
            if debug_eval then print_time('  --> hold evaluation: ' .. zonedata.cfg.zone_id) end


            local enemy_value_ratio = 1.25
            local max_units = 3
            local max_hexes = 6
            local enemy_leader_derating = FU.cfg_default('enemy_leader_derating')


            local raw_cfg = fred:get_raw_cfgs(zonedata.cfg.zone_id)
            --DBG.dbms(raw_cfg)
            --DBG.dbms(zonedata.cfg)

            local gamedata = fred.data.gamedata
            local move_cache = fred.data.move_cache

            -- Holders are those specified in zonedata, or all units except the leader otherwise
            local holders = {}
            if zonedata.cfg.zone_units then
                holders = zonedata.cfg.zone_units
            else
                for id,_ in pairs(gamedata.my_units_MP) do
                    if (not gamedata.unit_infos[id].canrecruit) then
                        holders[id] = gamedata.unit_infos[id].power
                    end
                end
            end
            if (not next(holders)) then return end
            --DBG.dbms(holders)

            local zone_map = {}
            local zone = wesnoth.get_locations(raw_cfg.ops_slf)
            for _,loc in ipairs(zone) do
                FU.set_fgumap_value(zone_map, loc[1], loc[2], 'flag', true)
            end
            if false then
                FU.show_fgumap_with_message(zone_map, 'flag', 'Zone map')
            end

            -- For the enemy rating, we need to put a 1-hex buffer around this
            local buffered_zone_map = {}
            for x,y,data in FU.fgumap_iter(zone_map) do
                FU.set_fgumap_value(buffered_zone_map, x, y, 'flag', true)
                for xa,ya in H.adjacent_tiles(x, y) do
                    FU.set_fgumap_value(buffered_zone_map, xa, ya, 'flag', true)
                end
            end
            if false then
                FU.show_fgumap_with_message(buffered_zone_map, 'flag', 'Buffered zone map')
            end


            local enemy_zone_maps = {}
            local holders_influence = {}
            for enemy_id,_ in pairs(gamedata.enemies) do
                enemy_zone_maps[enemy_id] = {}

                for x,y,_ in FU.fgumap_iter(buffered_zone_map) do
                    local enemy_defense = FGUI.get_unit_defense(gamedata.unit_copies[enemy_id], x, y, gamedata.defense_maps)
                    FU.set_fgumap_value(enemy_zone_maps[enemy_id], x, y, 'hit_chance', 1 - enemy_defense)

                    local moves_left = FU.get_fgumap_value(gamedata.reach_maps[enemy_id], x, y, 'moves_left')
                    if moves_left then
                        FU.set_fgumap_value(enemy_zone_maps[enemy_id], x, y, 'moves_left', moves_left)
                    end
                end
            end

            for enemy_id,_ in pairs(gamedata.enemies) do
                local xe, ye = gamedata.unit_copies[enemy_id].x, gamedata.unit_copies[enemy_id].y

                for x,y,_ in FU.fgumap_iter(buffered_zone_map) do
                    --print(x,y)

                    local enemy_hcs = {}
                    local min_dist, max_dist
                    for xa,ya in H.adjacent_tiles(x, y) do
                        -- Need the range of distance whether the enemy can get there or not
                        local dist = H.distance_between(xe, ye, xa, ya)
                        if (not max_dist) or (dist > max_dist) then
                            max_dist = dist
                        end
                        if (not min_dist) or (dist < min_dist) then
                            min_dist = dist
                        end

                        local moves_left = FU.get_fgumap_value(enemy_zone_maps[enemy_id], xa, ya, 'moves_left')
                        if moves_left then
                            local ehc = FU.get_fgumap_value(enemy_zone_maps[enemy_id], xa, ya, 'hit_chance')
                            table.insert(enemy_hcs, {
                                ehc = ehc, dist = dist
                            })
                        end
                    end

                    local adj_hc, cum_weight = 0, 0
                    local dd = max_dist - min_dist
                    for _,data in ipairs(enemy_hcs) do
                        local w = (max_dist - data.dist) / dd
                        adj_hc = adj_hc + data.ehc * w
                        cum_weight = cum_weight + w
                    end

                    -- Note that this will give a 'nil' on the hex the enemy is on,
                    -- but that's okay as the AI cannot reach that hex anyway
                    if (cum_weight > 0) then
                        adj_hc = adj_hc / cum_weight
                        FU.set_fgumap_value(enemy_zone_maps[enemy_id], x, y, 'adj_hit_chance', adj_hc)

                        local enemy_count = FU.get_fgumap_value(holders_influence, x, y, 'enemy_count', 0) + 1
                        FU.set_fgumap_value(holders_influence, x, y, 'enemy_count', enemy_count)
                    end
                end

                if false then
                    --FU.show_fgumap_with_message(enemy_zone_maps[enemy_id], 'hit_chance', 'Enemy hit chance', gamedata.unit_copies[enemy_id])
                    --FU.show_fgumap_with_message(enemy_zone_maps[enemy_id], 'moves_left', 'Enemy moves left', gamedata.unit_copies[enemy_id])
                    FU.show_fgumap_with_message(enemy_zone_maps[enemy_id], 'adj_hit_chance', 'Enemy adjacent hit_chance', gamedata.unit_copies[enemy_id])
                end
            end


            for id,_ in pairs(holders) do
                --print('\n' .. id, zonedata.cfg.zone_id)

                for x,y,_ in FU.fgumap_iter(gamedata.unit_attack_maps[id]) do
                    local unit_influence = FU.unit_terrain_power(gamedata.unit_infos[id], x, y, gamedata)
                    local inf = FU.get_fgumap_value(holders_influence, x, y, 'my_influence', 0)
                    FU.set_fgumap_value(holders_influence, x, y, 'my_influence', inf + unit_influence)

                    local my_count = FU.get_fgumap_value(holders_influence, x, y, 'my_count', 0) + 1
                    FU.set_fgumap_value(holders_influence, x, y, 'my_count', my_count)


                    local enemy_influence = FU.get_fgumap_value(fred.data.enemy_int_influence_map, x, y, 'enemy_influence', 0)

                    FU.set_fgumap_value(holders_influence, x, y, 'enemy_influence', enemy_influence)
                    FU.set_fgumap_value(holders_influence, x, y, 'influence', inf + unit_influence - enemy_influence)
                end
            end

            for x,y,influences in FU.fgumap_iter(holders_influence) do
                if influences.influence then
                    local influence = influences.influence
                    local tension = influences.my_influence + influences.enemy_influence
                    local vulnerability = tension - math.abs(influence)

                    local ld = FU.get_fgumap_value(gamedata.leader_distance_map, x, y, 'distance')
                    vulnerability = vulnerability + ld / 25

                    FU.set_fgumap_value(holders_influence, x, y, 'tension', tension)
                    FU.set_fgumap_value(holders_influence, x, y, 'vulnerability', vulnerability)
                end
            end

            for x,y,map in FU.fgumap_iter(holders_influence, x, y) do
                local my_inf = FU.get_fgumap_value(holders_influence, x, y, 'my_influence', 0)
                local enemy_inf = FU.get_fgumap_value(holders_influence, x, y, 'enemy_influence', 0)
                local inf_ratio = my_inf / (enemy_inf + 1)

                FU.set_fgumap_value(holders_influence, x, y, 'inf_ratio', inf_ratio)
            end


            if false then
                --FU.show_fgumap_with_message(holders_influence, 'my_influence', 'Holders influence')
                --FU.show_fgumap_with_message(holders_influence, 'enemy_influence', 'Enemy influence')
                FU.show_fgumap_with_message(holders_influence, 'influence', 'Influence')
                --FU.show_fgumap_with_message(holders_influence, 'tension', 'tension')
                FU.show_fgumap_with_message(holders_influence, 'vulnerability', 'vulnerability')
                --FU.show_fgumap_with_message(holders_influence, 'my_count', 'My count')
                --FU.show_fgumap_with_message(holders_influence, 'enemy_count', 'Enemy count')
                FU.show_fgumap_with_message(holders_influence, 'inf_ratio', 'inf_ratio')
            end


            local my_current_power, enemy_current_power = 0, 0
            for id,_ in pairs(gamedata.my_units) do
                my_current_power = my_current_power + FU.unit_current_power(gamedata.unit_infos[id])
            end
            for enemy_id,_ in pairs(gamedata.enemies) do
                enemy_current_power = enemy_current_power + FU.unit_current_power(gamedata.unit_infos[enemy_id])
            end
            local current_power_ratio = my_current_power / (enemy_current_power + 0.001)
            --print('current power:', my_current_power, enemy_current_power, current_power_ratio)


            local enemy_weights = {}
            for id,_ in pairs(holders) do
                enemy_weights[id] = {}
                for enemy_id,_ in pairs(gamedata.enemies) do
                    local att = fred.data.turn_data.unit_attacks[id][enemy_id]
                    --DBG.dbms(att)

                    local weight = att.counter.taken + att.counter.enemy_extra
                    -- TODO: there's no reason for the value of 0.5, other than that
                    -- we want to rate the enemy attack stronger than the AI unit attack
                    weight = weight - 0.5 * (att.counter.done + att.counter.my_extra)
                    if (weight < 1) then weight = 1 end

                    enemy_weights[id][enemy_id] = { weight = weight }
                end
            end
            --DBG.dbms(enemy_weights)


            local hold_leader_distance = fred.data.behavior.orders[zonedata.cfg.zone_id].hold_leader_distance
            local protect_loc = fred.data.behavior.orders[zonedata.cfg.zone_id].protect_loc

            local pre_rating_maps = {}
            for id,_ in pairs(holders) do
                --print('\n' .. id, zonedata.cfg.zone_id)

                local unit_type = gamedata.unit_infos[id].type

                local min_eleader_distance
                for x,y,_ in FU.fgumap_iter(gamedata.reach_maps[id]) do
                    --print(x,y)

                    local can_hit = false
                    for enemy_id,_ in pairs(gamedata.enemies) do
                        local enemy_adj_hc = FU.get_fgumap_value(enemy_zone_maps[enemy_id], x, y, 'adj_hit_chance')
                        if enemy_adj_hc then
                            can_hit = true
                            break
                        end
                    end

                    -- TODO: probably want to us an actual move-distance map, rather than cartesian distances
                    if (not can_hit) then

                        local eld1 = FU.get_fgumap_value(gamedata.leader_distance_map, x, y, 'enemy_leader_distance')
                        local eld2 = FU.get_fgumap_value(gamedata.enemy_leader_distance_maps[unit_type], x, y, 'cost')
                        local eld = (eld1 + eld2) / 2

                        if (not min_eleader_distance) or (eld < min_eleader_distance) then
                            min_eleader_distance = eld
                        end
                    end
                end
                --print('  min_eleader_distance: ' .. min_eleader_distance)

                for x,y,_ in FU.fgumap_iter(gamedata.reach_maps[id]) do
                    --print(x,y)

                    -- If there is nothing to protect, and we can move farther ahead
                    -- unthreatened than this hold position, don't hold here
                    local move_here = true
                    if (not hold_leader_distance) then
                        local threats = FU.get_fgumap_value(gamedata.enemy_attack_map[1], x, y, 'ids')

                        if (not threats) then
                            local eld1 = FU.get_fgumap_value(gamedata.leader_distance_map, x, y, 'enemy_leader_distance')
                            local eld2 = FU.get_fgumap_value(gamedata.enemy_leader_distance_maps[unit_type], x, y, 'cost')
                            local eld = (eld1 + eld2) / 2
                            if min_eleader_distance and (eld > min_eleader_distance) then
                                move_here = false
                            end
                        end
                    end

                    local my_defense = FGUI.get_unit_defense(gamedata.unit_copies[id], x, y, gamedata.defense_maps)

                    local tmp_enemies = {}
                    if move_here then
                        for enemy_id,_ in pairs(gamedata.enemies) do
                            local enemy_adj_hc = FU.get_fgumap_value(enemy_zone_maps[enemy_id], x, y, 'adj_hit_chance')

                            if enemy_adj_hc then
                                --print(x,y)
                                --print('  ', enemy_id, enemy_adj_hc)
                                local att = fred.data.turn_data.unit_attacks[id][enemy_id]

                                local my_hc = 1 - my_defense

                                -- This is not directly a contribution to damage, it's just meant as a tiebreaker
                                -- Taking away good terrain from the enemy
                                local enemy_defense = 1 - FU.get_fgumap_value(enemy_zone_maps[enemy_id], x, y, 'hit_chance')
                                my_hc = my_hc - enemy_defense /100


                                local ratio = FU.get_fgumap_value(holders_influence, x, y, 'inf_ratio', 1)
                                if (ratio > current_power_ratio) then
                                    ratio = (ratio + current_power_ratio) / 2
                                end
                                if (ratio < 1) then ratio = 1 end

                                local uncropped_ratio = ratio
                                if (ratio > 3) then ratio = 3 end

                                local factor_forward = 0.1 + (ratio - 1) * 0.4
                                local factor_counter = 1 - factor_forward
                                --print(x .. ',' .. y, ratio, factor_forward, factor_counter)

                                local damage_taken = factor_counter * (my_hc * att.counter.taken + att.counter.enemy_extra)
                                damage_taken = damage_taken + factor_forward * (my_hc * att.forward.taken + att.forward.enemy_extra)

                                local damage_done = factor_counter * (enemy_adj_hc * att.counter.done + att.counter.my_extra)
                                damage_done = damage_done + factor_forward * (enemy_adj_hc * att.forward.done + att.forward.my_extra)

                                -- Note: this is small (negative) for the strongest enemy
                                -- -> need to find minima the strongest enemies for this hex

                                if gamedata.unit_infos[enemy_id].canrecruit then
                                    damage_done = damage_done / enemy_leader_derating
                                    damage_taken = damage_taken * enemy_leader_derating
                                end

                                local counter_rating = enemy_value_ratio * damage_done - damage_taken
                                table.insert(tmp_enemies, {
                                    damage_taken = damage_taken,
                                    damage_done = damage_done,
                                    counter_rating = counter_rating,
                                    enemy_id = enemy_id,
                                    my_regen = att.my_regen,
                                    enemy_regen = att.enemy_regen,
                                    uncropped_ratio = uncropped_ratio
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
                        local weighted_damage_taken, weighted_damage_done = 0, 0
                        local cum_weight, n_enemies = 0, 0
                        for _,enemy in pairs(tmp_enemies) do
                            --print('    ' .. enemy.enemy_id)
                            local enemy_weight = enemy_weights[id][enemy.enemy_id].weight
                            cum_weight = cum_weight + enemy_weight
                            n_enemies = n_enemies + 1

                            damage_taken = damage_taken + enemy.damage_taken
                            weighted_damage_taken = weighted_damage_taken + enemy_weight * enemy.damage_taken

                            local frac_done = enemy.damage_done - enemy.enemy_regen
                            frac_done = frac_done / gamedata.unit_infos[enemy.enemy_id].hitpoints
                            frac_done = FU.weight_s(frac_done, 0.5)
                            --if (frac_done > 1) then frac_done = 1 end
                            --if (frac_done < 0) then frac_done = 0 end

                            damage_done = damage_done + frac_done * gamedata.unit_infos[enemy.enemy_id].max_hitpoints
                            weighted_damage_done = weighted_damage_done + enemy_weight * frac_done * gamedata.unit_infos[enemy.enemy_id].max_hitpoints

                            --print(x, y, damage_taken, damage_done)
                            --print('  ', weighted_damage_taken, weighted_damage_done, cum_weight)
                        end

                        weighted_damage_taken = weighted_damage_taken / cum_weight
                        weighted_damage_done = weighted_damage_done / cum_weight
                        --print('  cum: ', weighted_damage_taken, weighted_damage_done, cum_weight)

                        -- Healing bonus for villages
                        local village_bonus = 0
                        if FU.get_fgumap_value(gamedata.village_map, x, y, 'owner') then
                            if gamedata.unit_infos[id].abilities.regenerate then
                                -- Still give a bit of a bonus, to prefer villages if no other unit can get there
                                village_bonus = 2
                            else
                                village_bonus = 8
                            end
                        end

                        damage_taken = damage_taken - village_bonus
                        local frac_taken = damage_taken - tmp_enemies[1].my_regen

                        -- This is (intentionally) taken as fraction of current hitpoints,
                        -- and later multiplied with max_hitpoints, to emphasize the hit
                        -- on units with reduced HP. Not sure if we'll keep it that way.
                        frac_taken = frac_taken / gamedata.unit_infos[id].hitpoints
                        frac_taken = FU.weight_s(frac_taken, 0.5)
                        --if (frac_taken > 1) then frac_taken = 1 end
                        --if (frac_taken < 0) then frac_taken = 0 end
                        damage_taken = frac_taken * gamedata.unit_infos[id].max_hitpoints

                        -- TODO: that division by sqrt(n_enemies) is pretty adhoc; decide whether to change that
                        weighted_damage_taken = weighted_damage_taken * n_enemies - village_bonus - tmp_enemies[1].my_regen
                        local frac_taken = weighted_damage_taken / gamedata.unit_infos[id].hitpoints
                        frac_taken = FU.weight_s(frac_taken, 0.5)
                        --if (frac_taken > 1) then frac_taken = 1 end
                        --if (frac_taken < 0) then frac_taken = 0 end
                        weighted_damage_taken = frac_taken / n_enemies * gamedata.unit_infos[id].max_hitpoints


                        local net_outcome = enemy_value_ratio * damage_done - damage_taken
                        --print(x, y, damage_taken ,damage_done, village_bonus, net_outcome, enemy_value_ratio)

                        local av_outcome = enemy_value_ratio * weighted_damage_done - weighted_damage_taken

                        local influence = FU.get_fgumap_value(holders_influence, x, y, 'influence')
                        local exposure = influence + net_outcome

                        if (not pre_rating_maps[id]) then
                            pre_rating_maps[id] = {}
                        end
                        FU.set_fgumap_value(pre_rating_maps[id], x, y, 'net_outcome', net_outcome)
                        pre_rating_maps[id][x][y].x = x
                        pre_rating_maps[id][x][y].y = y
                        pre_rating_maps[id][x][y].id = id
                        pre_rating_maps[id][x][y].av_outcome = av_outcome
                        pre_rating_maps[id][x][y].influence = influence
                        pre_rating_maps[id][x][y].exposure = exposure
                        pre_rating_maps[id][x][y].uncropped_ratio = tmp_enemies[1].uncropped_ratio
                    end
                end
            end

            if false then
                for id,pre_rating_map in pairs(pre_rating_maps) do
                    FU.show_fgumap_with_message(pre_rating_map, 'net_outcome', 'Net outcome', gamedata.unit_copies[id])
                    FU.show_fgumap_with_message(pre_rating_map, 'av_outcome', 'Average outcome', gamedata.unit_copies[id])
                    --FU.show_fgumap_with_message(pre_rating_map, 'influence', 'Influence', gamedata.unit_copies[id])
                    FU.show_fgumap_with_message(pre_rating_map, 'exposure', 'Exposure', gamedata.unit_copies[id])
                end
            end


            local hold_maps = {}
            for id,_ in pairs(holders) do
                if pre_rating_maps[id] then
                    hold_maps[id] = {}

                    for x,y,data in FU.fgumap_iter(pre_rating_maps[id]) do
                        local hold_here = true
                        if hold_leader_distance then
                            local ld = FU.get_fgumap_value(gamedata.leader_distance_map, x, y, 'distance')
                            local dld = ld - hold_leader_distance

                            -- TODO: this is likely too simplistic
                            if (dld < -2) then
                                hold_here = false
                            end
                        end

                        if hold_here then
                            if (data.exposure >= 0) then
                                local my_count = FU.get_fgumap_value(holders_influence, x, y, 'my_count')
                                local enemy_count = FU.get_fgumap_value(holders_influence, x, y, 'enemy_count')

                                if (my_count >= 3) or (1.5 * my_count >= enemy_count) then
                                    FU.set_fgumap_value(hold_maps[id], x, y, 'exposure', data.exposure)
                                end
                            end

                            if hold_leader_distance then
                                FU.set_fgumap_value(hold_maps[id], x, y, 'protect_exposure', data.exposure)
                            end
                        end
                    end
                end
            end

            if (not next(hold_maps)) then return end

            if false then
                for id,hold_map in pairs(hold_maps) do
                    FU.show_fgumap_with_message(hold_map, 'exposure', 'Exposure', gamedata.unit_copies[id])
                    if hold_leader_distance then
                        FU.show_fgumap_with_message(hold_map, 'protect_exposure', 'Protect_exposure', gamedata.unit_copies[id])
                    end
                end
            end


            local unit_rating_maps = {}
            local hold_rating_maps, protect_rating_maps = {}, {}

            for id,hold_map in pairs(hold_maps) do
                --print('\n' .. id, zonedata.cfg.zone_id,hold_leader_distance)
                local min_rating, max_rating
                local min_vuln, max_vuln
                for x,y,_ in FU.fgumap_iter(hold_map) do
                    --print(x,y)

                    local rating2, cum_weight = 0, 0

                    local my_defense = FGUI.get_unit_defense(gamedata.unit_copies[id], x, y, gamedata.defense_maps)

                    for enemy_id,_ in pairs(gamedata.enemies) do
                        local enemy_adj_hc = FU.get_fgumap_value(enemy_zone_maps[enemy_id], x, y, 'adj_hit_chance')
                        if enemy_adj_hc then
                            local my_hc = 1 - my_defense
                            local enemy_hc = FU.get_fgumap_value(enemy_zone_maps[enemy_id], x, y, 'hit_chance')
                            local enemy_defense = 1 - enemy_hc

                            local enemy_weight = enemy_weights[id][enemy_id].weight


                            -- The scaled hit_chances here can be > 1 for hc > 0.8, but we ignored that for now
                            local scaled_my_hc = FU.scaled_hitchance(my_hc)
                            local scaled_my_defense = 1 - scaled_my_hc

                            local scaled_enemy_adj_hc = FU.scaled_hitchance(enemy_adj_hc)

                            local scaled_enemy_hc = FU.scaled_hitchance(enemy_hc)
                            local scaled_enemy_defense = 1 - scaled_enemy_hc



                            local r2 = (enemy_adj_hc + my_defense + enemy_defense / 100)
                            local scaled_r2 = (scaled_enemy_adj_hc + scaled_my_defense + scaled_enemy_defense / 100)
                            rating2 = rating2 + scaled_r2 * enemy_weight

                            cum_weight = cum_weight + enemy_weight

                            if false then
                                print(enemy_id, x, y)
                                print('  hc:  ' .. my_hc, enemy_hc, enemy_adj_hc)
                                print('  shc: ' .. scaled_my_hc, scaled_enemy_hc, scaled_enemy_adj_hc)
                                print('    r2:', r2, scaled_r2)
                            end
                        end
                    end

                    if (cum_weight > 0) then
                        local base_rating = FU.get_fgumap_value(pre_rating_maps[id], x, y, 'av_outcome')

                        if (not min_rating) or (base_rating < min_rating) then
                            min_rating = base_rating
                        end
                        if (not max_rating) or (base_rating > max_rating) then
                            max_rating = base_rating
                        end

                        local vuln = FU.get_fgumap_value(holders_influence, x, y, 'vulnerability')

                        if (not min_vuln) or (vuln < min_vuln) then
                            min_vuln = vuln
                        end
                        if (not max_vuln) or (vuln > max_vuln) then
                            max_vuln = vuln
                        end


                        local rating2 = rating2 / cum_weight
                        --print('    rating, rating2: ' .. rating, rating2, cum_weight)

                        if FU.get_fgumap_value(gamedata.village_map, x, y, 'owner') then
                            -- We give a general bonus here for a village, to protect it from the enemy
                            -- We also give an additional bonus for non-generating units (for healing)
                            -- TODO: these bonuses are huge, determine correct value?
                            rating2 = rating2 + 0.11

                            if (not gamedata.unit_infos[id].abilities.regenerate) then
                                -- TODO: this equation is entirely pulled out of thin air, need something better?
                                local heal_bonus = 8 / gamedata.unit_infos[id].max_hitpoints * my_defense
                                heal_bonus = 1 + heal_bonus / 2
                                rating2 = rating2 * heal_bonus
                            end
                        end

                        if (not unit_rating_maps[id]) then
                            unit_rating_maps[id] = {}
                        end
                        FU.set_fgumap_value(unit_rating_maps[id], x, y, 'base_rating', base_rating)
                        FU.set_fgumap_value(unit_rating_maps[id], x, y, 'rating2', rating2)
                    end
                end

                if max_rating then
                    if (min_rating == max_rating) then min_rating = max_rating - 1 end
                    local dr = max_rating - min_rating

                    if (min_vuln == max_vuln) then min_vuln = max_vuln - 1 end
                    local dv = max_vuln - min_vuln

                    for x,y,map in FU.fgumap_iter(unit_rating_maps[id]) do
                        local base_rating = FU.get_fgumap_value(unit_rating_maps[id], x, y, 'base_rating')
--                        base_rating = (base_rating - min_rating) / dr

                        local hp = gamedata.unit_infos[id].hitpoints
                        --base_rating = base_rating + hp
                        --if (base_rating < 0) then base_rating = 0 end
                        base_rating = base_rating / gamedata.unit_infos[id].max_hitpoints
                        base_rating = (base_rating + 1) / 2
                        base_rating = FU.weight_s(base_rating, 0.5)

                        FU.set_fgumap_value(unit_rating_maps[id], x, y, 'base_rating', base_rating)

                        local vuln = FU.get_fgumap_value(holders_influence, x, y, 'vulnerability')
                        --local v_fac = (vuln - min_vuln) / dv
                        --v_fac = 0.5 + v_fac / 2
                        --v_fac = math.sqrt(v_fac)

                        local v_fac = vuln / max_vuln / 10


                        local exposure = FU.get_fgumap_value(hold_maps[id], x, y, 'exposure')
                        if exposure then
                            local vuln_rating = base_rating + v_fac

                            local uncropped_ratio = FU.get_fgumap_value(pre_rating_maps[id], x, y, 'uncropped_ratio')
                            local eld = FU.get_fgumap_value(gamedata.leader_distance_map, x, y, 'enemy_leader_distance')
                            local forward_rating = (uncropped_ratio - 1) * 0.01 * (-eld)
                            vuln_rating = vuln_rating + forward_rating
                            --print('uncropped_ratio', x, y, uncropped_ratio, eld, forward_rating)


                            if (not hold_rating_maps[id]) then
                                hold_rating_maps[id] = {}
                            end

                            FU.set_fgumap_value(hold_rating_maps[id], x, y, 'vuln_rating', vuln_rating)
                            hold_rating_maps[id][x][y].x = x
                            hold_rating_maps[id][x][y].y = y
                            hold_rating_maps[id][x][y].id = id
                        end

                        local protect_exposure = FU.get_fgumap_value(hold_maps[id], x, y, 'protect_exposure')
                        if protect_exposure then
                            local rating2 = FU.get_fgumap_value(unit_rating_maps[id], x, y, 'rating2')
                            local protect_rating = rating2 + vuln / max_vuln / 20

                            local ld = FU.get_fgumap_value(gamedata.leader_distance_map, x, y, 'distance')
                            local dld = ld - hold_leader_distance

                            -- TODO: this is likely too simplistic
                            if (dld > 2) then
                                protect_rating = protect_rating - (dld - 2) / 20
                            end

                            if (not protect_rating_maps[id]) then
                                protect_rating_maps[id] = {}
                            end

                            FU.set_fgumap_value(protect_rating_maps[id], x, y, 'protect_rating', protect_rating)
                            protect_rating_maps[id][x][y].x = x
                            protect_rating_maps[id][x][y].y = y
                            protect_rating_maps[id][x][y].id = id
                        end
                    end
                end
            end
            --DBG.dbms(hold_rating_maps)

            -- TODO: check whether this needs to include number of enemies also
            -- TODO: this can probably be done earlier
            if hold_leader_distance then
                local n_units,n_holders = 0, 0
                for _,_ in pairs(hold_rating_maps) do n_units = n_units + 1 end
                for _,_ in pairs(holders) do n_holders = n_holders + 1 end
                --print(n_units, n_holders)

                if (n_units < 3) and (n_units < n_holders) then
                    hold_rating_maps = {}
                end
            end

            if false then
                for id,unit_rating_map in pairs(unit_rating_maps) do
                    FU.show_fgumap_with_message(unit_rating_map, 'base_rating', 'base_rating', gamedata.unit_copies[id])
                    FU.show_fgumap_with_message(unit_rating_map, 'rating2', 'rating2', gamedata.unit_copies[id])
                end
            end
            if false then
                for id,unit_rating_map in pairs(hold_rating_maps) do
                    FU.show_fgumap_with_message(hold_rating_maps[id], 'vuln_rating', 'vuln_rating', gamedata.unit_copies[id])
                end
                for id,unit_rating_map in pairs(protect_rating_maps) do
                    FU.show_fgumap_with_message(protect_rating_maps[id], 'protect_rating', 'protect_rating', gamedata.unit_copies[id])
                end
            end

            if (not next(hold_rating_maps)) and (not next(protect_rating_maps)) then
                return
            end


            -- Map of adjacent villages that can be reached by the enemy
            local adjacent_village_map = {}
            for x,y,_ in FU.fgumap_iter(gamedata.village_map) do
                if FU.get_fgumap_value(zone_map, x, y, 'flag') then

                    local can_reach = false
                    for enemy_id,_ in pairs(gamedata.enemies) do
                        if FU.get_fgumap_value(enemy_zone_maps[enemy_id], x, y, 'moves_left') then
                            can_reach = true
                            break
                        end
                    end

                    if can_reach then
                        for xa,ya in H.adjacent_tiles(x,y) do
                            -- TODO: this currently only works for one adjacent village
                            -- which is fine on the Freelands map, but might not be on oterhs
                            FU.set_fgumap_value(adjacent_village_map, xa, ya, 'village_xy', 1000 * x + y)
                        end
                    end
                end
            end
            --DBG.dbms(adjacent_village_map)

            if false then
                FU.show_fgumap_with_message(adjacent_village_map, 'village_xy', 'Adjacent vulnerable villages')
            end


            local cfg_combos = {
                max_units = max_units,
                max_hexes = max_hexes
            }
            local cfg_best_combo_hold = {}
            local cfg_best_combo_protect = {
                hold_perpendicular = true
            }

            -- protect_loc is only set if there is a location to protect
            cfg_best_combo_hold.protect_loc = protect_loc
            cfg_best_combo_protect.protect_loc = protect_loc


            local best_hold_combo, hold_dst_src, hold_ratings
            if (next(hold_rating_maps)) then
                --print('--> checking hold combos')
                hold_dst_src, hold_ratings = UHC.unit_rating_maps_to_dstsrc(hold_rating_maps, 'vuln_rating', gamedata, cfg_combos)
                local hold_combos = UHC.get_unit_hex_combos(hold_dst_src)
                --DBG.dbms(hold_combos)
                --print('#hold_combos', #hold_combos)

                best_hold_combo = UHC.find_best_combo(hold_combos, hold_ratings, 'vuln_rating', adjacent_village_map, gamedata, cfg_best_combo_hold)
            end

            local best_protect_combo, unprotected_best_protect_combo, protect_dst_src, protect_ratings
            if hold_leader_distance then
                --print('--> checking protect combos')
                protect_dst_src, protect_ratings = UHC.unit_rating_maps_to_dstsrc(protect_rating_maps, 'protect_rating', gamedata, cfg_combos)
                local protect_combos = UHC.get_unit_hex_combos(protect_dst_src)
                --DBG.dbms(protect_combos)
                --print('#protect_combos', #protect_combos)

                best_protect_combo, unprotected_best_protect_combo = UHC.find_best_combo(protect_combos, protect_ratings, 'protect_rating', adjacent_village_map, gamedata, cfg_best_combo_protect)

                -- If no combo that protects the location was found, use the best of the others
                if (not best_protect_combo) then
                    best_protect_combo = unprotected_best_protect_combo
                end
            end
            --DBG.dbms(best_hold_combo)
            --DBG.dbms(best_protect_combo)

            if (not best_hold_combo) and (not best_protect_combo) then
                return
            end


            local best_combo, ratings
            if (not best_hold_combo) then
                best_combo, ratings = best_protect_combo, protect_ratings
            elseif (not best_protect_combo) then
                best_combo, ratings = best_hold_combo, hold_ratings
            else
                local hold_distance, count = 0, 0
                for src,dst in pairs(best_hold_combo) do
                    local x, y =  math.floor(dst / 1000), dst % 1000
                    local ld = FU.get_fgumap_value(gamedata.leader_distance_map, x, y, 'distance')
                    hold_distance = hold_distance + ld
                    count = count + 1
                end
                hold_distance = hold_distance / count

                local protect_distance, count = 0, 0
                for src,dst in pairs(best_protect_combo) do
                    local x, y =  math.floor(dst / 1000), dst % 1000
                    local ld = FU.get_fgumap_value(gamedata.leader_distance_map, x, y, 'distance')
                    protect_distance = protect_distance + ld
                    count = count + 1
                end
                protect_distance = protect_distance / count

                --print(hold_distance, protect_distance)

                if (hold_distance > protect_distance) then
                    best_combo, ratings = best_hold_combo, hold_ratings
                else
                    best_combo, ratings = best_protect_combo, protect_ratings
                end
            end
            --DBG.dbms(best_combo)

            if false then
                local x, y
                for src,dst in pairs(best_combo) do
                    x, y =  math.floor(dst / 1000), dst % 1000
                    local id = ratings[dst][src].id
                    W.label { x = x, y = y, text = id }
                end
                wesnoth.scroll_to_tile(x, y)
                W.message { speaker = 'narrator', message = 'Best hold combo: '  .. max_rating}
                for src,dst in pairs(best_combo) do
                    x, y =  math.floor(dst / 1000), dst % 1000
                    W.label { x = x, y = y, text = "" }
                end
            end

            local action = {
                action = zonedata.cfg.zone_id .. ': ' .. 'hold position',
                units = {},
                dsts = {}
            }
            for src,dst in pairs(best_combo) do
                local dst_x, dst_y =  math.floor(dst / 1000), dst % 1000
                local id = ratings[dst][src].id

                local tmp_unit = gamedata.my_units[id]
                tmp_unit.id = id
                table.insert(action.units, tmp_unit)
                table.insert(action.dsts, { dst_x, dst_y })
            end
            --DBG.dbms(action)

            return action
        end


        ----- Advance: -----
        function fred:get_advance_action(zonedata)
            -- Advancing is now only moving onto unthreatened hexes; everything
            -- else should be covered by holding, village grabbing, protecting, etc.

            if debug_eval then print_time('  --> advance evaluation: ' .. zonedata.cfg.zone_id) end

            --DBG.dbms(zonedata.cfg)
            local raw_cfg = fred:get_raw_cfgs(zonedata.cfg.zone_id)
            --DBG.dbms(raw_cfg)

            local gamedata = fred.data.gamedata
            local move_cache = fred.data.move_cache


            -- Advancers are those specified in zonedata, or all units except the leader otherwise
            local advancers = {}
            if zonedata.cfg.zone_units then
                advancers = zonedata.cfg.zone_units
            else
                for id,_ in pairs(gamedata.my_units_MP) do
                    if (not gamedata.unit_infos[id].canrecruit) then
                        advancers[id] = gamedata.unit_infos[id].power
                    end
                end
            end
            if (not next(advancers)) then return end

            local advance_map = {}
            local zone = wesnoth.get_locations(raw_cfg.ops_slf)
            for _,loc in ipairs(zone) do
                if (not FU.get_fgumap_value(gamedata.enemy_attack_map[1], loc[1], loc[2], 'ids')) then
                    FU.set_fgumap_value(advance_map, loc[1], loc[2], 'flag', true)
                end
            end
            if false then
                FU.show_fgumap_with_message(advance_map, 'flag', 'Advance map: ' .. zonedata.cfg.zone_id)
            end

            local unit_rating_maps = {}
            local max_rating, best_id, best_hex
            for id,_ in pairs(advancers) do
                unit_rating_maps[id] = {}

                -- Fastest unit first, after that strongest unit first
                local rating_moves = gamedata.unit_infos[id].moves / 10
                local rating_power = FU.unit_current_power(gamedata.unit_infos[id]) / 1000

                local fraction_hp_missing = (gamedata.unit_infos[id].max_hitpoints - gamedata.unit_infos[id].hitpoints) / gamedata.unit_infos[id].max_hitpoints
                local hp_rating = FU.weight_s(fraction_hp_missing, 0.5)
                hp_rating = hp_rating * 10

                --print(id, rating_moves, rating_power, fraction_hp_missing, hp_rating)

                local unit_type = gamedata.unit_infos[id].type


                for x,y,_ in FU.fgumap_iter(gamedata.reach_maps[id]) do
                    if FU.get_fgumap_value(advance_map, x, y, 'flag') then

                        local ld1 = FU.get_fgumap_value(gamedata.leader_distance_map, x, y, 'enemy_leader_distance')
                        local ld2 = FU.get_fgumap_value(gamedata.enemy_leader_distance_maps[unit_type], x, y, 'cost')
                        local ld = (ld1 + ld2) / 2

                        local rating = - ld + rating_moves + rating_power


                        local owner = FU.get_fgumap_value(gamedata.village_map, x, y, 'owner')
                        if owner and (owner ~= wesnoth.current.side) then
                            if (owner == 0) then
                                rating = rating + 100
                            else
                                rating = rating + 200
                            end
                        end

                        if owner then
                            rating = rating + hp_rating
                        end

                        -- Small bonus for the terrain
                        local my_defense = FGUI.get_unit_defense(gamedata.unit_copies[id], x, y, gamedata.defense_maps)
                        rating = rating + my_defense / 10

                        FU.set_fgumap_value(unit_rating_maps[id], x, y, 'rating', rating)

                        if (not max_rating) or (rating > max_rating) then
                            max_rating = rating
                            best_id = id
                            best_hex = { x, y }
                        end
                    end
                end
            end

            if false then
                for id,unit_rating_map in pairs(unit_rating_maps) do
                    FU.show_fgumap_with_message(unit_rating_map, 'rating', 'Unit rating', gamedata.unit_copies[id])
                end
            end

            if best_id then
                FU.print_debug(show_debug_advance, '  best advance:', best_id, best_hex[1], best_hex[2])

                local best_unit = gamedata.my_units[best_id]
                best_unit.id = best_id

                local action = { units = { best_unit }, dsts = { best_hex } }
                action.action = zonedata.cfg.zone_id .. ': ' .. 'advance'
                return action
            end
        end


        ----- Retreat: -----
        function fred:get_retreat_action(zonedata)
            if debug_eval then print_time('  --> retreat evaluation: ' .. zonedata.cfg.zone_id) end

            local gamedata = fred.data.gamedata

            -- This is a placeholder for when (if) retreat.lua gets adapted to the new
            -- tables also. It might not be necessary, it's fast enough the way it is
            --print('consider retreat for:')

            local retreat_units = {}

            -- By default, use all units in the zone with MP
            -- but override if zondedata.cfg.retreaters is set
            local retreaters = zonedata.cfg.retreaters or zonedata.zone_units_MP

            for id in pairs(retreaters) do
                --print('  ' .. id)
                table.insert(retreat_units, gamedata.unit_copies[id])
            end

            local unit, dest, enemy_threat = R.retreat_injured_units(retreat_units, zonedata.cfg.retreat_all, zonedata.cfg.enemy_count_weight)
            if unit then
                local allowable_retreat_threat = zonedata.cfg.allowable_retreat_threat or 0
                --print_time('Found unit to retreat:', unit.id, enemy_threat, allowable_retreat_threat)
                local action = {
                    units = { unit },
                    dsts = { dest }
                }
                action.action = zonedata.cfg.zone_id .. ': ' .. 'retreat severely injured units'
                return action
            elseif zonedata.cfg.retreaters and zonedata.cfg.stop_unit then
                for id in pairs(zonedata.cfg.retreaters) do
                    if (gamedata.unit_infos[id].moves > 0) then
                        --print('Immobilizing unit: ' .. id)
                        local action = {
                            units = { { id = id } },
                            dsts = { { gamedata.my_units[id][1], gamedata.my_units[id][2] } }
                        }
                        action.action = zonedata.cfg.zone_id .. ': ' .. 'immobilize'
                        return action
                    end
                end
            end
        end


        ------- Candidate Actions -------

        ----- CA: Reset variables at beginning of turn (max_score: 999998) -----
        -- This will be blacklisted after first execution each turn
        function fred:reset_vars_turn_eval()
            return 999998
        end

        function fred:reset_vars_turn_exec()
            --print(' Resetting variables at beginning of Turn ' .. wesnoth.current.turn)

            fred.data.turn_start_time = wesnoth.get_time_stamp() / 1000.
        end


        ----- CA: Reset variables at beginning of each move (max_score: 999997) -----
        -- This always returns 0 -> will never be executed, but evaluated before each move
        function fred:reset_vars_move_eval()
            --print(' Resetting gamedata tables (etc.) before move')

            fred.data.gamedata = FGU.get_gamedata()
            fred:get_leader_distance_map()
            fred.data.move_cache = {}

            return 0
        end

        function fred:reset_vars_move_exec()
        end


        ----- CA: Stats at beginning of turn (max_score: 999990) -----
        -- This will be blacklisted after first execution each turn
        function fred:stats_eval()
            return 999990
        end

        function fred:stats_exec()
            local tod = wesnoth.get_time_of_day()
            print('\n**** Fred ' .. wesnoth.dofile('~/add-ons/AI-demos/version.lua') .. ' *******************************************************')
            AH.print_ts('Beginning of Turn ' .. wesnoth.current.turn .. ' (' .. tod.name ..') stats')

            local sides = {}
            for id,_ in pairs(fred.data.gamedata.units) do
                local unit_side = fred.data.gamedata.unit_infos[id].side
                if (not sides[unit_side]) then sides[unit_side] = {} end

                sides[unit_side].num_units = (sides[unit_side].num_units or 0) + 1
                sides[unit_side].hitpoints = (sides[unit_side].hitpoints or 0) + fred.data.gamedata.unit_infos[id].hitpoints

                if fred.data.gamedata.unit_infos[id].canrecruit then
                    sides[unit_side].leader_type = fred.data.gamedata.unit_copies[id].type
                end
            end

            local total_villages = 0
            for x,tmp in pairs(fred.data.gamedata.village_map) do
                for y,village in pairs(tmp) do
                    local owner = fred.data.gamedata.village_map[x][y].owner
                    if (owner > 0) then
                        sides[owner].num_villages = (sides[owner].num_villages or 0) + 1
                    end

                    total_villages = total_villages + 1
                end
            end

            for _,side_info in ipairs(wesnoth.sides) do
                local side = side_info.side
                local num_villages = sides[side].num_villages or 0
                print('  Side ' .. side .. ': '
                    .. sides[side].num_units .. ' Units (' .. sides[side].hitpoints .. ' HP), '
                    .. num_villages .. '/' .. total_villages .. ' villages  ('
                    .. sides[side].leader_type .. ', ' .. side_info.gold .. ' gold)'
                )
            end
            print('************************************************************************')
        end

        ----- CA: Clear self.data table at end of turn (max_score: 1) -----
        -- This will be blacklisted after first execution each turn, which happens at the very end of each turn
        function fred:clear_self_data_eval()
            return 1
        end

        function fred:clear_self_data_exec()
            --print(' Clearing self.data table at end of Turn ' .. wesnoth.current.turn)

            -- This is mostly done so that there is no chance of corruption of savefiles
            fred.data = {}
        end


        ----- CA: Move leader to keep (max_score: 4800000) -----
        function fred:move_leader_to_keep_eval(move_unit_away)
            -- @move_unit_away: if set, try to move own unit out of way
            --   Default is not to do this.

            local score = 480000
            local low_score = 1000

            local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'move_leader_to_keep'
            if debug_eval then print_time('     - Evaluating move_leader_to_keep CA:') end

            local gamedata = fred.data.gamedata
            local leader = gamedata.leaders[wesnoth.current.side]

            -- If the leader cannot move, don't do anything
            if gamedata.my_units_noMP[leader.id] then
                AH.done_eval_messages(start_time, ca_name)
                return 0
            end

            -- If the leader already is on a keep, don't do anything
            if (wesnoth.get_terrain_info(wesnoth.get_terrain(leader[1], leader[2])).keep) then
                AH.done_eval_messages(start_time, ca_name)
                return 0
            end

            local leader_copy = gamedata.unit_copies[leader.id]

            local enemy_leader_cx, enemy_leader_cy = AH.cartesian_coords(gamedata.enemy_leader_x, gamedata.enemy_leader_y)

            local width, height, border = wesnoth.get_map_size()
            local keeps = wesnoth.get_locations {
                terrain = 'K*,K*^*,*^K*', -- Keeps
                x = '1-'..width,
                y = '1-'..height
            }

            local max_rating, best_keep = -10  -- Intentionally not set to less than this!!
                                               -- so that the leader does not try to get to unreachable locations
            for _,keep in ipairs(keeps) do
                -- Count keep closer to the enemy leader as belonging to the enemy
                local dist_leader = H.distance_between(keep[1], keep[2], leader[1], leader[2])
                local dist_enemy_leader = H.distance_between(keep[1], keep[2], gamedata.enemy_leader_x, gamedata.enemy_leader_y)
                local is_enemy_keep = dist_enemy_leader < dist_leader
                --print(keep[1], keep[2], dist_leader, dist_enemy_leader, is_enemy_keep)

                -- Is there a unit on the keep that cannot move any more?
                local unit_in_way = gamedata.my_unit_map_noMP[keep[1]]
                    and gamedata.my_unit_map_noMP[keep[1]][keep[2]]

                if (not is_enemy_keep) and (not unit_in_way) then
                    local path, cost = wesnoth.find_path(leader_copy, keep[1], keep[2])

                    cost = cost + leader_copy.max_moves - leader_copy.moves
                    local turns = math.ceil(cost / leader_copy.max_moves)

                    -- Main rating is how long it will take the leader to get there
                    local rating = - turns

                    -- Minor rating is distance from enemy leader (the closer the better)
                    local keep_cx, keep_cy = AH.cartesian_coords(keep[1], keep[2])
                    local dist_enemy_leader = math.sqrt((keep_cx - enemy_leader_cx)^2 + (keep_cy - enemy_leader_cx)^2)
                    rating = rating - dist_enemy_leader / 100.

                    if (rating > max_rating) then
                        max_rating = rating
                        best_keep = keep
                    end
                end
            end

            if best_keep then
                -- If the leader can reach the keep, but there's a unit on it: wait
                -- Except when move_unit_away is set
                if (not move_unit_away)
                    and gamedata.reach_maps[leader.id][best_keep[1]]
                    and gamedata.reach_maps[leader.id][best_keep[1]][best_keep[2]]
                    and gamedata.my_unit_map_MP[best_keep[1]]
                    and gamedata.my_unit_map_MP[best_keep[1]][best_keep[2]]
                then
                    return 0
                end

                -- We can always use 'ignore_own_units = true', as the if block
                -- above catches the case when that should not be done.
                local next_hop = AH.next_hop(leader_copy, best_keep[1], best_keep[2], { ignore_own_units = true })

                -- Only move the leader if he'd actually move
                if (next_hop[1] ~= leader_copy.x) or (next_hop[2] ~= leader_copy.y) then
                    fred.data.MLK_leader = leader_copy
                    fred.data.MLK_keep = best_keep
                    fred.data.MLK_dst = next_hop

                    AH.done_eval_messages(start_time, ca_name)

                    -- This is done with high priority if the leader can get to the keep,
                    -- otherwise with very low priority
                    if (next_hop[1] == best_keep[1]) and (next_hop[2] == best_keep[2]) then
                        local action = {
                            units = { { id = leader.id } },
                            dsts = { { next_hop[1], next_hop[2] } },
                            action = 'move leader to keep',
                            partial_move = true
                        }

                        return score, action
                    else
                        return low_score  -- Do not return action in this case
                    end
                end
            end

            AH.done_eval_messages(start_time, ca_name)
            return 0
        end

        function fred:move_leader_to_keep_exec()
            if debug_exec then print_time('====> Executing move_leader_to_keep CA') end
            if AH.show_messages() then W.message { speaker = fred.data.MLK_leader.id, message = 'Moving back to keep' } end

            -- If leader can get to the keep, make this a partial move, otherwise a full move
            if (fred.data.MLK_dst[1] == fred.data.MLK_keep[1])
                and (fred.data.MLK_dst[2] == fred.data.MLK_keep[2])
            then
                AH.checked_move(ai, fred.data.MLK_leader, fred.data.MLK_dst[1], fred.data.MLK_dst[2])
            else
                AH.checked_move_full(ai, fred.data.MLK_leader, fred.data.MLK_dst[1], fred.data.MLK_dst[2])
            end

            fred.data.MLK_leader, fred.data.MLK_dst = nil, nil
        end


        ----- CA: Recruitment (max_score: 461000; default score: 181000) -----

        local params = {score_function = function () return 181000 end}
        wesnoth.require("~add-ons/AI-demos/lua/generic_recruit_engine.lua").init(ai, fred, params)


        ----- CA: Zone control (max_score: 350000) -----
        -- TODO: rename?
        function fred:get_zone_action(cfg)
            -- Find the best action to do in the zone described in 'cfg'
            -- This is all done together in one function, rather than in separate CAs so that
            --  1. Zones get done one at a time (rather than one CA at a time)
            --  2. Relative scoring of different types of moves is possible

            local gamedata = fred.data.gamedata

            if (not next(cfg.actions)) then return end

            local zonedata = {
                zone_units = {},
                zone_units_MP = {},
                zone_units_attacks = {},
                zone_units_noMP = {},
                cfg = cfg
            }

            -- TODO: currently cfg.unit_filter is not set -> this defaults to all units
            for id,loc in pairs(gamedata.my_units) do
                if wesnoth.match_unit(gamedata.unit_copies[id], cfg.unit_filter) then
                    zonedata.zone_units[id] = loc

                    -- The leader counts into the active zone_units if he's on his keep
                    -- This applies to zone_units_MP and zone_units_attacks only.
                    -- He always counts into zone_units_noMP (if he can't move) and zone_units.

                    -- Flag set to true only if the unit is the side leader AND is NOT on the keep
                    local is_leader_and_off_keep = false
                    if gamedata.unit_infos[id].canrecruit then
                        if (not wesnoth.get_terrain_info(wesnoth.get_terrain(loc[1], loc[2])).keep) then
                            is_leader_and_off_keep = true
                        end
                    end

                    if gamedata.my_units_MP[id] then
                        if (not is_leader_and_off_keep) then
                            zonedata.zone_units_MP[id] = loc
                        end
                    else
                        zonedata.zone_units_noMP[id] = loc
                    end

                    if (gamedata.unit_copies[id].attacks_left > 0) then
                        -- The leader counts as one of the attackers, but only if he's on his keep
                        if (not is_leader_and_off_keep) then
                            zonedata.zone_units_attacks[id] = loc
                        end
                    end
                end
            end

            if (not next(zonedata.zone_units_MP)) and (not next(zonedata.zone_units_attacks)) then return end
            --DBG.dbms(zonedata)

            --local zone
            --if (cfg.zone_filter == 'leader') then
            --    zone = { gamedata.leaders[wesnoth.current.side] }
            --else
            --    zone = wesnoth.get_locations(cfg.zone_filter)
            --end
            --zonedata.zone_map = {}
            --for _,loc in ipairs(zone) do
            --    if (not zonedata.zone_map[loc[1]]) then
            --        zonedata.zone_map[loc[1]] = {}
            --    end
            --    zonedata.zone_map[loc[1]][loc[2]] = true
            --end
            --DBG.dbms(zone)

            -- **** Retreat severely injured units evaluation ****
            if (cfg.actions.retreat) then
                --print_time('  ' .. cfg.zone_id .. ': retreat_injured eval')
                -- TODO: heal_loc and safe_loc are not used at this time
                -- keep for now and see later if needed
                local action = fred:get_retreat_action(zonedata)
                if action then
                    --print(action.action)
                    return action
                end
            end

            -- **** Attack evaluation ****
            if (cfg.actions.attack) then
                --print_time('  ' .. cfg.zone_id .. ': attack eval')
                local action = fred:get_attack_action(zonedata)
                if action then
                    --print(action.action)
                    return action
                end
            end

            -- **** Hold position evaluation ****
            if (cfg.actions.hold) then
                --print_time('  ' .. cfg.zone_id .. ': hold eval')
                local action = fred:get_hold_action(zonedata)
                if action then
                    --print_time(action.action)
                    return action
                end
            end

            -- **** Advance in zone evaluation ****
            if (cfg.actions.advance) then
                --print_time('  ' .. cfg.zone_id .. ': advance eval')
                local action = fred:get_advance_action(zonedata)
                if action then
                    --print_time(action.action)
                    return action
                end
            end

            -- **** Force leader to go to keep if needed ****
            -- TODO: This should be consolidated at some point into one
            -- CA, but for simplicity we keep it like this for now until
            -- we know whether it works as desired
            if (cfg.actions.move_leader_to_keep) then
                --print_time('  ' .. cfg.zone_id .. ': move_leader_to_keep eval')
                local score, action = fred:move_leader_to_keep_eval(true)
                if action then
                    --print_time(action.action)
                    return action
                end
            end

            -- **** Recruit evaluation ****
            -- TODO: does it make sense to keep this also as a separate CA?
            if (cfg.actions.recruit) then
                --print_time('  ' .. cfg.zone_id .. ': recruit eval')
                -- Important: we cannot check recruiting here, as the units
                -- are taken off the map at this time, so it needs to be checked
                -- by the function setting up the cfg
                local action = {
                    action = zonedata.cfg.zone_id .. ': ' .. 'recruit',
                    id = 'recruit',
                    outofway_units = cfg.outofway_units
                }
                return action
            end

            return nil  -- This is technically unnecessary, just for clarity
        end


        function fred:zone_control_eval()
            local score_zone_control = 350000
            local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'zone_control'

            if debug_eval then print_time('     - Evaluating zone_control CA:') end


-- !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
--fred.data.behavior = nil

            -- Only executes when fred.data.behavior does per turn (that is, once per turn)
            fred:get_behavior_this_turn()

            -- Executes once per zone_control_eval (that is, after each set of moves)
            fred:update_orders()

            local behavior = fred.data.behavior
            --DBG.dbms(behavior.turn)


            -- Execute any immediate actions coming out of this
            -- We first need to validate that the existing actions are still doable
            -- This is needed because individual actions might interfere with each other
            -- We also delete executed actions here; it cannot be done right after setting
            -- up the eval table, as not all action get executed right away by the
            -- execution code (e.g. if an action involves the leader and recruiting has not
            -- yet happened)
            --DBG.dbms(behavior.immediate_actions)

            for i = #behavior.immediate_actions,1,-1 do
                local action = behavior.immediate_actions[i]
                local is_good = true

                for _,u in ipairs(action.units) do
                    local unit = wesnoth.get_units { id = u.id }[1]
                    --print(unit.id, unit.x, unit.y)

                    if (not unit) or ((unit.x == action.dsts[1][1]) and (unit.y == action.dsts[1][2])) then
                        is_good = false
                        break
                    end

                    local _, cost = wesnoth.find_path(unit, action.dsts[1][1], action.dsts[1][2])
                    --print(cost)

                    if (cost > unit.moves) then
                        is_good = false
                        break
                    end
                end

                if (#action.units == 0) then
                    is_good = false
                end
                --print('is_good:', is_good)

                if (not is_good) then
                    table.remove(behavior.immediate_actions, i)
                end
            end
            --DBG.dbms(behavior.immediate_actions)

            if behavior.immediate_actions and behavior.immediate_actions[1] then
                print('Action to be executed immediately found: ' .. behavior.immediate_actions[1].action)

                fred.data.zone_action = AH.table_copy(behavior.immediate_actions[1])
                AH.done_eval_messages(start_time, ca_name)
                --DBG.dbms(fred.data.zone_action)

                return score_zone_control
            end


--if 1 then return 0 end




            while 1 do
                if (behavior.turn.stage_counter > #behavior.turn.stage_ids) then
                    if debug_eval then print('--> done with all stages') end

                    -- Reset stage counter for each evaluation
                    -- This makes the stage system somewhat pointless
                    -- TODO: reconsider if this should be done or not
                    behavior.turn.stage_counter = 1

                    return 0
                end

                local stage_id = behavior.turn.stage_ids[behavior.turn.stage_counter]
                if debug_eval then print('\nStage: ' .. stage_id) end

                fred:analyze_map()
                --DBG.dbms(FDA.status)

                --DBG.dbms(fred.data.zone_cfgs)

                for i_c,cfg in ipairs(fred.data.zone_cfgs) do
                    --print()
                    --print('-----------------------------------')
                    --print_time('zone_control: ', cfg.zone_id, cfg.stage_id)
                    --for action,_ in pairs(cfg.actions) do print('  --> ' .. action) end
                    --DBG.dbms(cfg)

                    -- Extract all AI units with MP left (for enemy path finding, counter attack placement etc.)
                    local extracted_units = {}
                    for id,loc in pairs(fred.data.gamedata.my_units_MP) do
                        local unit_proxy = wesnoth.get_unit(loc[1], loc[2])
                        wesnoth.extract_unit(unit_proxy)
                        table.insert(extracted_units, unit_proxy)  -- Not a proxy unit any more at this point
                    end

                    local zone_action = fred:get_zone_action(cfg)

                    for _,extracted_unit in ipairs(extracted_units) do wesnoth.put_unit(extracted_unit) end

                    if zone_action then
                        zone_action.zone_id = cfg.zone_id
                        zone_action.stage_id = cfg.stage_id
                        --DBG.dbms(zone_action)
                        fred.data.zone_action = zone_action
                        AH.done_eval_messages(start_time, ca_name)
                        return score_zone_control
                    end
                end

                -- If we get here, this means no action was found for this stage
                -- --> reset the zone_cfgs, so that they will be recalculate
                --     and up the counter
                fred.data.zone_cfgs = nil
                behavior.turn.stage_counter = behavior.turn.stage_counter + 1

                if debug_eval then print('--> done with all cfgs of this stage') end
            end

            AH.done_eval_messages(start_time, ca_name)
            return 0
        end

        function fred:zone_control_exec()
            local action = fred.data.zone_action.zone_id .. ': ' .. fred.data.zone_action.action
            --DBG.dbms(fred.data.zone_action)

            -- If recruiting is set, we just do that, nothing else needs to be checked:
            if (fred.data.zone_action.id == 'recruit') then
                if debug_exec then print_time('====> Executing zone_control CA ' .. action) end
                if AH.show_messages() then W.message { speaker = unit.id, message = 'Zone action ' .. action } end

                while (fred:recruit_rushers_eval(fred.data.zone_action.outofway_units) > 0) do
                    local _, recruit_proxy = fred:recruit_rushers_exec(nil, nil, fred.data.zone_action.outofway_units)
                    if (not recruit_proxy) then
                        break
                    else
                        -- Unlike for the recruit loop above, these units do
                        -- get counted into the current zone (which should
                        -- always be the leader zone)
                        --fred.data.analysis.status.units_used[recruit_proxy.id] = {
                        --    zone_id = fred.data.zone_action.zone_id or 'other',
                        --    action = fred.data.zone_action.action or 'other'
                        --}
                    end
                end

                return
            end


            local enemy_proxy
            if fred.data.zone_action.enemy then
                enemy_proxy = wesnoth.get_units { id = next(fred.data.zone_action.enemy) }[1]
            end

            local gamestate_changed = false

            while fred.data.zone_action.units and (table.maxn(fred.data.zone_action.units) > 0) do
                local next_unit_ind = 1
                -- If this is an attack combo, reorder units to give maximum XP to unit closest to advancing
                if enemy_proxy and fred.data.zone_action.units[2] then
                    -- Only do this if CTK for overall attack combo is > 0
                    local attacker_copies, attacker_infos = {}, {}
                    for i,unit in ipairs(fred.data.zone_action.units) do
                        table.insert(attacker_copies, fred.data.gamedata.unit_copies[unit.id])
                        table.insert(attacker_infos, fred.data.gamedata.unit_infos[unit.id])
                    end

                    local defender_info = fred.data.gamedata.unit_infos[enemy_proxy.id]

                    -- Don't use cfg_attack = { use_max_damage_weapons = true } here
                    local _, combo_def_stat = FAU.attack_combo_eval(
                        attacker_copies, enemy_proxy,
                        fred.data.zone_action.dsts,
                        attacker_infos, defender_info,
                        fred.data.gamedata, fred.data.move_cache
                    )

                    -- Disable reordering of attacks for the time being
                    -- TODO: this needs to be completely redone
                    if (combo_def_stat.hp_chance[0] > 100) then
                        --print_time('Reordering units for attack to maximize XP gain')

                        local min_XP_diff, best_ind = 9e99
                        for ind,unit in ipairs(fred.data.zone_action.units) do
                            local unit_info = fred.data.gamedata.unit_infos[unit.id]
                            local XP_diff = unit_info.max_experience - unit_info.experience
                            -- Add HP as minor rating
                            XP_diff = XP_diff + unit_info.hitpoints / 100.

                            if (XP_diff < min_XP_diff) then
                                min_XP_diff, best_ind = XP_diff, ind
                            end
                        end

                        local unit = fred.data.zone_action.units[best_ind]
                        --print_time('Most advanced unit:', unit.id, unit.experience, best_ind)

                        local att_stat, def_stat = FAU.battle_outcome(
                            attacker_copies[best_ind], enemy_proxy,
                            fred.data.zone_action.dsts[best_ind],
                            attacker_infos[best_ind], defender_info,
                            fred.data.gamedata, fred.data.move_cache
                        )

                        local kill_rating = def_stat.hp_chance[0] - att_stat.hp_chance[0]
                        --print_time('kill_rating:', kill_rating)

                        if (kill_rating >= 0.5) then
                            --print_time('Pulling unit to front')
                            next_unit_ind = best_ind
                        elseif (best_ind == 1) then
                            --print_time('Moving unit back')
                            next_unit_ind = 2
                        end
                    end
                end
                --print_time('next_unit_ind', next_unit_ind)

                local unit = wesnoth.get_units { id = fred.data.zone_action.units[next_unit_ind].id }[1]
                if (not unit) then
                    fred.data.zone_action = nil
                    return
                end


                local dst = fred.data.zone_action.dsts[next_unit_ind]

                -- If this is the leader (and he has MP left), recruit first
                -- We're doing that by running a mini CA eval/exec loop
                if unit.canrecruit and (unit.moves > 0) then
                    --print('-------------------->  This is the leader. Recruit first.')
                    local avoid_map = LS.create()
                    for _,loc in ipairs(fred.data.zone_action.dsts) do
                        avoid_map:insert(dst[1], dst[2])
                    end

                    if AH.show_messages() then W.message { speaker = unit.id, message = 'The leader is about to move. Need to recruit first.' } end

                    local have_recruited
                    while (fred:recruit_rushers_eval() > 0) do
                        if (not fred:recruit_rushers_exec(nil, avoid_map)) then
                            break
                        else
                            -- Note (TODO?): these units do not get counted as used in any zone
                            have_recruited = true
                            gamestate_changed = true
                        end
                    end

                    -- Then we stop the outside loop to reevaluate
                    if have_recruited then break end
                end

                if debug_exec then print_time('====> Executing zone_control CA ' .. action) end
                if AH.show_messages() then W.message { speaker = unit.id, message = 'Zone action ' .. action } end

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
                    local _,cost = wesnoth.find_path(unit, dst[1], dst[2])
                    if (cost > unit.moves) then
                        fred.data.zone_action = nil
                        return
                    end

                    -- It is also possible that a unit moving out of the way for a previous
                    -- move of this combination is now in the way again and cannot move any more.
                    -- We also need to stop execution in that case.
                    -- Just checking for moves > 0 is not always sufficient.
                    local unit_in_way
                    if (unit.x ~= dst[1]) or (unit.y ~= dst[2]) then
                        unit_in_way = wesnoth.get_unit(dst[1], dst[2])
                    end
                    if unit_in_way then
                        uiw_reach = wesnoth.find_reach(unit_in_way)

                        -- Check whether the unit to move out of the way has an unoccupied hex to move to.
                        local unit_blocked = true
                        for _,uiw_loc in ipairs(uiw_reach) do
                            -- Unit in the way of the unit in the way
                            local uiw_uiw = wesnoth.get_unit(uiw_loc[1], uiw_loc[2])
                            if (not uiw_uiw) then
                                unit_blocked = false
                                break
                            end
                        end

                        if unit_blocked then
                            fred.data.zone_action = nil
                            return
                        end
                    end
                end


                -- Generally, move out of way in direction of own leader
                local leader_loc = fred.data.gamedata.leaders[wesnoth.current.side]
                local dx, dy  = leader_loc[1] - dst[1], leader_loc[2] - dst[2]
                local r = math.sqrt(dx * dx + dy * dy)
                if (r ~= 0) then dx, dy = dx / r, dy / r end

                -- However, if the unit in the way is part of the move combo, it needs to move in the
                -- direction of its own goal, otherwise it might not be able to reach it later
                local unit_in_way
                if (unit.x ~= dst[1]) or (unit.y ~= dst[2]) then
                    unit_in_way = wesnoth.get_unit(dst[1], dst[2])
                end
                if unit_in_way then
                    for i_u,u in ipairs(fred.data.zone_action.units) do
                        if (u.id == unit_in_way.id) then
                            --print('  unit is part of the combo', unit_in_way.id, unit_in_way.x, , unit_in_way.y)
                            local path, _ = wesnoth.find_path(unit_in_way, fred.data.zone_action.dsts[i_u][1], fred.data.zone_action.dsts[i_u][2])
                            dx, dy = path[2][1] - path[1][1], path[2][2] - path[1][2]
                            local r = math.sqrt(dx * dx + dy * dy)
                            if (r ~= 0) then dx, dy = dx / r, dy / r end

                            break
                        end
                    end
                end


                if fred.data.zone_action.partial_move then
                    AH.movepartial_outofway_stopunit(ai, unit, dst[1], dst[2], { dx = dx, dy = dy })
                else
                    AH.movefull_outofway_stopunit(ai, unit, dst[1], dst[2], { dx = dx, dy = dy })
                end
                gamestate_changed = true


                -- Remove these from the table
                table.remove(fred.data.zone_action.units, next_unit_ind)
                table.remove(fred.data.zone_action.dsts, next_unit_ind)

                -- Then do the attack, if there is one to do
                if enemy_proxy and (H.distance_between(unit.x, unit.y, enemy_proxy.x, enemy_proxy.y) == 1) then
                    AH.checked_attack(ai, unit, enemy_proxy)

                    -- If enemy got killed, we need to stop here
                    if (not enemy_proxy.valid) then
                        fred.data.zone_action.units = nil
                    end

                    -- Need to reset the enemy information if there are more attacks in this combo
                    if fred.data.zone_action.units and fred.data.zone_action.units[1] then
                        fred.data.gamedata.unit_copies[enemy_proxy.id] = wesnoth.copy_unit(enemy_proxy)
                        fred.data.gamedata.unit_infos[enemy_proxy.id] = FGU.single_unit_info(enemy_proxy)
                    end
                end

                -- Add units_used to status table
                if unit and unit.valid then
                --    fred.data.analysis.status.units_used[unit.id] = {
                --        zone_id = fred.data.zone_action.zone_id or 'other',
                --        action = fred.data.zone_action.action or 'other'
                --    }
                else
                    -- If an AI unit died in the attack, we stop and reconsider
                    -- This is not so much because this is an unfavorable outcome,
                    -- but because that hex might be useful to another AI unit now.
                    fred.data.zone_action.units = nil
                end
            end

            fred.data.zone_action = nil
        end


        ----- CA: Remove MP from all units (max_score: 900) -----
        -- This serves the purpose that attacks are evaluated differently for
        -- units without MP. They might still attack in this case (such as
        -- unanswerable attacks), while they do not if they can still move
        function fred:remove_MP_eval()
            local score = 900

            local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'remove_MP'
            if debug_eval then print_time('     - Evaluating remove_MP CA:') end

            local id,_ = next(fred.data.gamedata.my_units_MP)

            if id then
                AH.done_eval_messages(start_time, ca_name)
                return score
            end

            AH.done_eval_messages(start_time, ca_name)
            return 0
        end

        function fred:remove_MP_exec()
            if debug_exec then print_time('====> Executing remove_MP CA') end

            local id,loc = next(fred.data.gamedata.my_units_MP)

            AH.checked_stopunit_moves(ai, fred.data.gamedata.unit_copies[id])
        end


        return fred
    end
}
