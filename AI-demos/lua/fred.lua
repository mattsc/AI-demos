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
        local FVU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_village_utils.lua"
        local LS = wesnoth.require "lua/location_set.lua"
        local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"
        local R = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_retreat_utils.lua"
        local FHU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_hold_utils.lua"


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

            local leader_distance_map = {}
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


        function fred:get_between_map(locs, units, gamedata, perp_dist_weight)
            -- Note: this function ignores enemies and distance of the units
            -- from the locs. Whether this makes sense to use all these units needs
            -- to be checked in the calling function

            perp_dist_weight = perp_dist_weight or 0.5

            local weights, cum_weight = {}, 0
            for id,_ in pairs(units) do
                local weight = FU.unit_current_power(gamedata.unit_infos[id])
                weights[id] = weight
                cum_weight = cum_weight + weight
            end
            for id,weight in pairs(weights) do
                weights[id] = weight / cum_weight / #locs
            end
            --DBG.dbms(weights)

            local between_map = {}
            for id,unit_loc in pairs(units) do
                --print(id, unit_loc[1], unit_loc[2])
                local unit = {}
                unit[id] = unit_loc

                -- wesnoth.find_cost_map() requires the unit to be on the map, and it needs to
                -- have full moves. We cannot use the unit_type version of wesnoth.find_cost_map()
                -- here as some specific units (e.g walking corpses or customized units) might have
                -- movecosts different from their generic unit type.
                local unit_proxy = wesnoth.get_unit(unit_loc[1], unit_loc[2])
                local old_moves = unit_proxy.moves
                unit_proxy.moves = unit_proxy.max_moves
                local cm = wesnoth.find_cost_map(unit_loc[1], unit_loc[2], { ignore_units = true })
                unit_proxy.moves = old_moves

                local cost_map = {}
                for _,cost in pairs(cm) do
                    if (cost[3] > -1) then
                       FU.set_fgumap_value(cost_map, cost[1], cost[2], 'cost', cost[3])
                    end
                end

                if false then
                    FU.show_fgumap_with_message(cost_map, 'cost', 'cost_map', gamedata.unit_copies[id])
                end

                for _,loc in ipairs(locs) do
                    --print('  loc:', loc[1], loc[2])
                    local inv_cost_map = FU.inverse_cost_map(unit, loc, gamedata)

                    if false then
                        FU.show_fgumap_with_message(inv_cost_map, 'cost', 'inv_cost_map', gamedata.unit_copies[id])
                    end

                    local cost_full = FU.get_fgumap_value(cost_map, loc[1], loc[2], 'cost')

                    for x,y,data in FU.fgumap_iter(cost_map) do
                        local cost = data.cost
                        local inv_cost = FU.get_fgumap_value(inv_cost_map, x, y, 'cost')

                        local rating = (cost + inv_cost) / 2
                        rating = cost_full - math.max(cost, inv_cost)
                        rating = rating - perp_dist_weight * (cost + inv_cost - cost_full)
                        rating = rating * weights[id]
                        FU.fgumap_add(between_map, x, y, 'distance', rating)
                        FU.fgumap_add(between_map, x, y, 'inv_cost', inv_cost * weights[id])
                    end
                end
            end

            return between_map
        end


        function fred:get_side_cfgs()
            local cfgs = {
                { start_hex = { 18, 4 } },
                { start_hex = { 20, 20 } }
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
            local cfg_leader_threat = {
                zone_id = 'leader_threat',
                ops_slf = {},
            }

            local cfg_west = {
                zone_id = 'west',
                ops_slf = { x = '1-15,1-14,1-21', y = '1-12,13-17,18-24' },
                center_hexes = { { 10, 13 } },
                zone_weight = 1,
            }

            local cfg_center = {
                zone_id = 'center',
                center_hexes = { { 18, 12 }, { 20, 12 } },
                ops_slf = { x = '16-20,16-22,16-23,15-22,15-23', y = '6-7,8-9,10-12,13-17,18-24' },
                zone_weight = 0.5,
            }

            local cfg_east = {
                zone_id = 'east',
                center_hexes = { { 28, 13 } },
                ops_slf = { x = '21-34,23-34,24-34,23-34,17-34', y = '1-7,8-9,10-12,13-17,18-24' },
                zone_weight = 1,
            }

            local cfg_top = {
                zone_id = 'top',
                ops_slf = { x = '17-20,21-34', y = '1-9,1-10' },
                replace_zones = { 'center', 'east' }
            }

            local cfg_all_map = {
                zone_id = 'all_map',
                ops_slf = {},
                center_hexes = { { 20, 20 } }
            }


            if (zone_id == 'leader_threat') then
                return cfg_leader_threat
            end

            if (not zone_id) then
                local zone_cfgs = {
                    west = cfg_west,
                    center = cfg_center,
                    east = cfg_east
                }
               return zone_cfgs

            elseif (zone_id == 'all') then
                local all_cfgs = {
                    leader_threat = cfg_leader_threat,
                    west = cfg_west,
                    center = cfg_center,
                    east = cfg_east
                }
               return all_cfgs

            else
                local cfgs = {
                    leader_threat = cfg_leader_threat,
                    west = cfg_west,
                    center = cfg_center,
                    east = cfg_east,
                    top = cfg_top,
                    all_map = cfg_all_map
                }

                for _,cfg in pairs(cfgs) do
                    if (cfg.zone_id == zone_id) then
                        return cfg
                    end
                end
            end
        end


        function fred:replace_zones(assigned_units, assigned_enemies, protect_locs, actions)
            -- Combine 'east' and 'center' zones, if needed
            -- TODO: not sure whether it is better to do this earlier
            -- TODO: set this up to be configurable by the cfgs
            local raw_cfgs_main = fred:get_raw_cfgs()
            local raw_cfg_top = fred:get_raw_cfgs('top')
            --DBG.dbms(raw_cfg_top)

            actions.hold_zones = {}
            for zone_id,_ in pairs(raw_cfgs_main) do
                if assigned_units[zone_id] then
                    actions.hold_zones[zone_id] = true
                end
            end

            local replace_zones = false
            for _,zone_id in ipairs(raw_cfg_top.replace_zones) do
                if assigned_enemies[zone_id] then
                    for enemy_id,loc in pairs(assigned_enemies[zone_id]) do
                        if wesnoth.match_location(loc[1], loc[2], raw_cfg_top.ops_slf) then
                            replace_zones = true
                            break
                        end
                    end
                end

                if replace_zones then break end
            end
            --print('replace_zones', replace_zones)

            if replace_zones then
                actions.hold_zones[raw_cfg_top.zone_id] = true

                for _,zone_id in ipairs(raw_cfg_top.replace_zones) do
                    actions.hold_zones[zone_id] = nil
                end

                -- Also combine assigned_units, assigned_enemies, protect_locs
                -- from the zones to be replaced. We don't actually replace the
                -- respective tables for those zones, just add those for the super zone,
                -- because advancing still uses the original zones
                assigned_units[raw_cfg_top.zone_id] = {}
                assigned_enemies[raw_cfg_top.zone_id] = {}
                protect_locs[raw_cfg_top.zone_id] = {}

                local hld_min, hld_max
                for _,zone_id in ipairs(raw_cfg_top.replace_zones) do
                    for id,loc in pairs(assigned_units[zone_id] or {}) do
                        assigned_units[raw_cfg_top.zone_id][id] = loc
                    end
                    for id,loc in pairs(assigned_enemies[zone_id] or {}) do
                        assigned_enemies[raw_cfg_top.zone_id][id] = loc
                    end

                    if protect_locs[zone_id].locs then
                        for _,loc in ipairs(protect_locs[zone_id].locs) do
                            if (not protect_locs[raw_cfg_top.zone_id].locs) then
                                protect_locs[raw_cfg_top.zone_id].locs = {}
                            end
                            table.insert(protect_locs[raw_cfg_top.zone_id].locs, loc)
                        end
                        if (not hld_min) or (protect_locs[zone_id].hold_leader_distance.min < hld_min) then
                            hld_min = protect_locs[zone_id].hold_leader_distance.min
                        end
                        if (not hld_max) or (protect_locs[zone_id].hold_leader_distance.max > hld_max) then
                            hld_max = protect_locs[zone_id].hold_leader_distance.max
                        end
                    end
                end
                if hld_min then
                    protect_locs[raw_cfg_top.zone_id].hold_leader_distance = {
                        min = hld_min, max = hld_max
                    }
                end
            end
        end


        function fred:calc_power_stats(zones, assigned_units, assigned_enemies, assigned_recruits, gamedata)
            local power_stats = {
                total = { my_power = 0, enemy_power = 0 },
                zones = {}
            }

            local recruit_weight = 0.5

            for id,_ in pairs(gamedata.my_units) do
                if (not gamedata.unit_infos[id].canrecruit) then
                    power_stats.total.my_power = power_stats.total.my_power + FU.unit_base_power(gamedata.unit_infos[id])
                end
            end
            --for _,unit in ipairs(assigned_recruits) do
            --    local power = FU.unittype_base_power(unit.recruit_type)
            --    power_stats.total.my_power = power_stats.total.my_power + recruit_weight * power
            --end

            for id,_ in pairs(gamedata.enemies) do
                if (not gamedata.unit_infos[id].canrecruit) then
                    power_stats.total.enemy_power = power_stats.total.enemy_power + FU.unit_base_power(gamedata.unit_infos[id])
                end
            end

            local ratio = power_stats.total.my_power / power_stats.total.enemy_power
            if (ratio > 1) then ratio = 1 end
            power_stats.total.ratio = ratio


            for zone_id,_ in pairs(zones) do
                power_stats.zones[zone_id] = {
                    my_power = 0,
                    enemy_power = 0
                }
            end

            for zone_id,_ in pairs(zones) do
                for id,_ in pairs(assigned_units[zone_id] or {}) do
                    local power = FU.unit_base_power(gamedata.unit_infos[id])
                    power_stats.zones[zone_id].my_power = power_stats.zones[zone_id].my_power + power
                end
            end
            --for _,unit in ipairs(assigned_recruits) do
            --    local power = FU.unittype_base_power(unit.recruit_type)
            --    power_stats.zones['leader_threat'].my_power = power_stats.zones['leader_threat'].my_power + recruit_weight * power
            --end

            for zone_id,enemies in pairs(zones) do
                for id,_ in pairs(assigned_enemies[zone_id] or {}) do
                    local power = FU.unit_base_power(gamedata.unit_infos[id])
                    power_stats.zones[zone_id].enemy_power = power_stats.zones[zone_id].enemy_power + power
                end
            end


            for zone_id,_ in pairs(zones) do
                -- Note: both power_needed and power_missing take ratio into account, the other values do not
                local power_needed = power_stats.zones[zone_id].enemy_power * power_stats.total.ratio
                local power_missing = power_needed - power_stats.zones[zone_id].my_power
                if (power_missing < 0) then power_missing = 0 end
                power_stats.zones[zone_id].power_needed = power_needed
                power_stats.zones[zone_id].power_missing = power_missing
            end

            return power_stats
        end


        function fred:assess_leader_threats(leader_threats, protect_locs, leader_proxy, raw_cfgs_main, side_cfgs, gamedata)
            -- Threat are all enemies that can attack the castle or any of the protect_locations
            leader_threats.enemies = {}
            for x,y,_ in FU.fgumap_iter(gamedata.reachable_castles_map[wesnoth.current.side]) do
                local ids = FU.get_fgumap_value(gamedata.enemy_attack_map[1], x, y, 'ids', {})
                for _,id in ipairs(ids) do
                    leader_threats.enemies[id] = gamedata.units[id]
                end
            end
            for _,loc in ipairs(leader_threats.protect_locs) do
                local ids = FU.get_fgumap_value(gamedata.enemy_attack_map[1], loc[1], loc[2], 'ids', {})
                for _,id in ipairs(ids) do
                    leader_threats.enemies[id] = gamedata.units[id]
                end
            end
            --DBG.dbms(leader_threats)

            -- Only enemies closer than the farther hex to be protected in each zone
            -- count as leader threats. This is in order to prevent a disproportionate
            -- response to individual scouts etc.
            local threats_by_zone = {}
            for id,_ in pairs(leader_threats.enemies) do
                local unit_copy = gamedata.unit_copies[id]
                local zone_id = FU.moved_toward_zone(unit_copy, raw_cfgs_main, side_cfgs)

                if (not threats_by_zone[zone_id]) then
                    threats_by_zone[zone_id] = {}
                end

                local loc = gamedata.enemies[id]
                threats_by_zone[zone_id][id] = FU.get_fgumap_value(gamedata.leader_distance_map, loc[1], loc[2], 'distance')
            end
            --DBG.dbms(threats_by_zone)

            for zone_id,threats in pairs(threats_by_zone) do
                local hold_ld = 9999
                if protect_locs[zone_id].hold_leader_distance then
                    hold_ld = protect_locs[zone_id].hold_leader_distance.max
                end
                --print(zone_id, hold_ld)

                local is_threat = false
                for id,ld in pairs(threats) do
                    --print('  ' .. id, ld)
                    if (ld < hold_ld + 1) then
                        is_threat = true
                        break
                    end
                end
                --print('    is_threat: ', is_threat)

                if (not is_threat) then
                    for id,_ in pairs(threats) do
                        leader_threats.enemies[id] = nil
                    end
                end
            end
            threats_by_zone = nil
            --DBG.dbms(leader_threats)


            -- Check out how much of a threat these units pose in combination
            local max_total_loss, av_total_loss = 0, 0
            --print('    possible damage by enemies in reach (average, max):')
            for id,_ in pairs(leader_threats.enemies) do
                local dst
                local max_defense = 0
                for xa,ya in H.adjacent_tiles(gamedata.leader_x, gamedata.leader_y) do
                    local defense = FGUI.get_unit_defense(gamedata.unit_copies[id], xa, ya, gamedata.defense_maps)

                    if (defense > max_defense) then
                        max_defense = defense
                        dst = { xa, ya }
                    end
                end

                local att_outcome, def_outcome = FAU.attack_outcome(
                    gamedata.unit_copies[id], leader_proxy,
                    dst,
                    gamedata.unit_infos[id], gamedata.unit_infos[leader_proxy.id],
                    gamedata, fred.data.move_cache
                )
                --DBG.dbms(att_outcome)
                --DBG.dbms(def_outcome)

                local max_loss = leader_proxy.hitpoints - def_outcome.min_hp
                local av_loss = leader_proxy.hitpoints - def_outcome.average_hp
                --print('    ', id, av_loss, max_loss)

                max_total_loss = max_total_loss + max_loss
                av_total_loss = av_total_loss + av_loss
            end
            FU.print_debug(show_debug_analysis, '\nleader: max_total_loss, av_total_loss', max_total_loss, av_total_loss)

            -- We only consider these leader threats, if they either
            --   - maximum damage reduces current HP by more than 50%
            --   - average damage is more than 25% of max HP
            -- Otherwise we assume the leader can deal with them alone
            leader_threats.significant_threat = false
            if (max_total_loss >= leader_proxy.hitpoints / 2.) or (av_total_loss >= leader_proxy.max_hitpoints / 4.) then
                leader_threats.significant_threat = true
            else
                leader_threats.significant_threat = false
            end
            FU.print_debug(show_debug_analysis, '  significant_threat', leader_threats.significant_threat)

            -- Only count leader threats if they are significant
            if (not leader_threats.significant_threat) then
                leader_threats.enemies = nil
            end

            local power_stats = fred:calc_power_stats({}, {}, {}, {}, gamedata)
            --DBG.dbms(power_stats)

            leader_threats.power_ratio = power_stats.total.ratio

            --DBG.dbms(leader_threats)
        end


        function fred:set_turn_data()
            FU.print_debug(show_debug_analysis, '\n------------- Setting the turn_data table:')

            -- Get the needed cfgs
            local gamedata = fred.data.gamedata
            local side_cfgs = fred:get_side_cfgs()

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


            -- Find the unit-vs-unit ratings
            -- TODO: can functions in attack_utils be used for this?
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

                    local max_diff_forward
                    for i_w,attack in ipairs(gamedata.unit_infos[my_id].attacks) do
                        --print('attack weapon: ' .. i_w)

                        local _, _, my_weapon, enemy_weapon = wesnoth.simulate_combat(my_proxy, i_w, enemy_proxy)
                        local _, my_base_damage, my_extra_damage, my_regen_damage
                            = FAU.get_total_damage_attack(my_weapon, attack, true, gamedata.unit_infos[enemy_id])

                        -- If the enemy has no weapon at this range, attack_num=-1 and enemy_attack
                        -- will be nil; this is handled just fine by FAU.get_total_damage_attack
                        -- Note: attack_num starts at 0, not 1 !!!!
                        --print('  enemy weapon: ' .. enemy_weapon.attack_num + 1)
                        local enemy_attack = gamedata.unit_infos[enemy_id].attacks[enemy_weapon.attack_num + 1]
                        local _, enemy_base_damage, enemy_extra_damage, enemy_regen_damage
                            = FAU.get_total_damage_attack(enemy_weapon, enemy_attack, false, gamedata.unit_infos[my_id])

                        -- TODO: the factor of 2 is somewhat arbitrary and serves to emphasize
                        -- the strongest attack weapon. Might be changed later. Use 1/value_ratio?
                        local diff = 2 * (my_base_damage + my_extra_damage) - enemy_base_damage - enemy_extra_damage
                        --print('  ' .. my_base_damage, enemy_base_damage, my_extra_damage, enemy_extra_damage, '-->', diff)

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
                    for i_w,attack in ipairs(gamedata.unit_infos[enemy_id].attacks) do
                        --print('counter weapon: ' .. i_w)

                        local _, _, enemy_weapon, my_weapon = wesnoth.simulate_combat(enemy_proxy, i_w, my_proxy)
                        local _, enemy_base_damage, enemy_extra_damage, _
                            = FAU.get_total_damage_attack(enemy_weapon, attack, true, gamedata.unit_infos[my_id])

                        -- If the AI unit has no weapon at this range, attack_num=-1 and my_attack
                        -- will be nil; this is handled just fine by FAU.get_total_damage_attack
                        -- Note: attack_num starts at 0, not 1 !!!!
                        --print('  my weapon: ' .. my_weapon.attack_num + 1)
                        local my_attack = gamedata.unit_infos[my_id].attacks[my_weapon.attack_num + 1]
                        local _, my_base_damage, my_extra_damage, _
                            = FAU.get_total_damage_attack(my_weapon, my_attack, false, gamedata.unit_infos[enemy_id])

                        -- TODO: the factor of 2 is somewhat arbitrary and serves to emphasize
                        -- the strongest attack weapon. Might be changed later. Use 1/value_ratio?
                        local diff = 2 * (enemy_base_damage + enemy_extra_damage) - my_base_damage - my_extra_damage
                        --print('  ' .. enemy_base_damage, my_base_damage, enemy_extra_damage, my_extra_damage, '-->', diff)

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


                    gamedata.unit_copies[enemy_id] = wesnoth.copy_unit(enemy_proxy)
                    wesnoth.put_unit(enemy_x, enemy_y)
                    gamedata.unit_copies[enemy_id].x = old_x_enemy
                    gamedata.unit_copies[enemy_id].y = old_y_enemy
                end

                gamedata.unit_copies[my_id] = wesnoth.copy_unit(my_proxy)
                wesnoth.put_unit(my_x, my_y)
                gamedata.unit_copies[my_id].x = old_x
                gamedata.unit_copies[my_id].y = old_y

                unit_attacks[my_id] = tmp_attacks
            end

            for _,extracted_unit in ipairs(extracted_units) do wesnoth.put_unit(extracted_unit) end

            --DBG.dbms(unit_attacks)

            fred.data.turn_data = {
                turn_number = wesnoth.current.turn,
                enemy_int_influence_map = enemy_int_influence_map,
                unit_attacks = unit_attacks
            }
        end


        function fred:set_ops_data()
            FU.print_debug(show_debug_analysis, '\n------------- Setting the turn_data table:')

            -- Get the needed cfgs
            local gamedata = fred.data.gamedata
            local raw_cfgs_main = fred:get_raw_cfgs()
            local side_cfgs = fred:get_side_cfgs()


            local villages_to_protect_maps = FVU.villages_to_protect(raw_cfgs_main, side_cfgs, gamedata)
            local zone_village_goals = FVU.village_goals(villages_to_protect_maps, gamedata)
            local protect_locs = FVU.protect_locs(villages_to_protect_maps, gamedata)
            --DBG.dbms(zone_village_goals)
            --DBG.dbms(villages_to_protect_maps)
            --DBG.dbms(protect_locs)


            -- First: leader threats
            local leader_proxy = wesnoth.get_unit(gamedata.leader_x, gamedata.leader_y)

            -- Locations to protect, and move goals for the leader
            local max_ml, closest_keep, closest_village
            for x,y,keep in FU.fgumap_iter(gamedata.reachable_keeps_map[wesnoth.current.side]) do
                --print('keep:', x, y)
                -- Note that reachable_keeps_map contains moves_left assuming max_mp for the leader
                -- This should generally be the same at this stage as the real situation, but
                -- might not work depending on how this is used in the future.
                local ml = FU.get_fgumap_value(gamedata.reach_maps[leader_proxy.id], x, y, 'moves_left')
                if ml then
                    -- Can the leader get to any villages from here?
                    local old_loc = { leader_proxy.x, leader_proxy.y }
                    local old_moves = leader_proxy.moves
                    local leader_copy = gamedata.unit_copies[leader_proxy.id]
                    leader_copy.x, leader_copy.y = x, y
                    leader_copy.moves = ml
                    local reach_from_keep = wesnoth.find_reach(leader_copy)
                    leader_copy.x, leader_copy.y = old_loc[1], old_loc[2]
                    leader_copy.moves = old_moves
                    --DBG.dbms(reach_from_keep)

                    local max_ml_village = ml - 1000 -- penalty if no reachable village
                    local closest_village_this_keep

                    if (not gamedata.unit_infos[leader_proxy.id].abilities.regenerate)
                        and (gamedata.unit_infos[leader_proxy.id].hitpoints < gamedata.unit_infos[leader_proxy.id].max_hitpoints)
                    then
                        for _,loc in ipairs(reach_from_keep) do
                            local owner = FU.get_fgumap_value(gamedata.village_map, loc[1], loc[2], 'owner')

                            if owner and (loc[3] > max_ml_village) then
                                max_ml_village = loc[3]
                                closest_village_this_keep = { loc[1], loc[2] }
                            end
                        end
                    end
                    --print('    ' .. x, y, max_ml_village)

                    if (not max_ml) or (max_ml_village > max_ml) then
                        max_ml = max_ml_village
                        closest_keep = { x, y }
                        closest_village = closest_village_this_keep
                    end
                end
            end

            local leader_threats = {
                leader_locs = {},
                protect_locs = {}
            }
            if closest_keep then
                leader_threats.leader_locs.closest_keep = closest_keep
                table.insert(leader_threats.protect_locs, closest_keep)
                FU.print_debug(show_debug_analysis, 'closest keep: ' .. closest_keep[1] .. ',' .. closest_keep[2])
            else
                local _, _, next_hop, best_keep_for_hop = fred:move_leader_to_keep_eval(true)
                leader_threats.leader_locs.next_hop = next_hop
                leader_threats.leader_locs.best_keep_for_hop = best_keep_for_hop
                table.insert(leader_threats.protect_locs, next_hop)
                table.insert(leader_threats.protect_locs, best_keep_for_hop)
                if next_hop then
                    FU.print_debug(show_debug_analysis, 'next_hop to keep: ' .. next_hop[1] .. ',' .. next_hop[2])
                end
            end
            if closest_village then
                leader_threats.leader_locs.closest_village = closest_village
                table.insert(leader_threats.protect_locs, closest_village)
                FU.print_debug(show_debug_analysis, 'reachable village after keep: ' .. closest_village[1] .. ',' .. closest_village[2])
            end
            -- It is possible that no protect location was found (e.g. if the leader cannot move)
            if (not leader_threats.protect_locs[1]) then
                leader_threats.protect_locs = { { leader_proxy.x, leader_proxy.y } }
            end
            --DBG.dbms(leader_threats)

            fred:assess_leader_threats(leader_threats, protect_locs, leader_proxy, raw_cfgs_main, side_cfgs, gamedata)


            -- Attributing enemy units to zones
            -- Use base_power for this as it is not only for the current turn
            local assigned_enemies = {}
            for id,loc in pairs(gamedata.enemies) do
                if (not gamedata.unit_infos[id].canrecruit)
                    and (not FU.get_fgumap_value(gamedata.reachable_castles_map[gamedata.unit_infos[id].side], loc[1], loc[2], 'castle', false))
                then
                    local unit_copy = gamedata.unit_copies[id]
                    local zone_id = FU.moved_toward_zone(unit_copy, raw_cfgs_main, side_cfgs)

                    if (not assigned_enemies[zone_id]) then
                        assigned_enemies[zone_id] = {}
                    end
                    assigned_enemies[zone_id][id] = gamedata.units[id]
                end
            end
            --DBG.dbms(assigned_enemies)


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


            local retreat_utilities = FU.retreat_utilities(gamedata)
            --DBG.dbms(retreat_utilities)


            ----- Village goals -----

            local actions = { villages = {} }
            local assigned_units = {}

            FVU.assign_grabbers(
                zone_village_goals,
                villages_to_protect_maps,
                assigned_units,
                actions.villages,
                fred.data.turn_data.unit_attacks,
                gamedata
            )

            --DBG.dbms(assigned_units)
            FVU.assign_scouts(zone_village_goals, assigned_units, retreat_utilities, gamedata)
            --DBG.dbms(actions.villages)
            --DBG.dbms(assigned_enemies)


            -- In case of a leader threat, check whether recruiting can be done,
            -- and how many units are available/needed.  These count with a
            -- certain fraction of their power into the available power in the
            -- leader_threat zone.
            local prerecruit = { units = {} }
            if leader_threats.significant_threat and closest_keep then
                local outofway_units = {}
                -- Note that the leader is included in the following, as he might
                -- be on a castle hex other than a keep. His recruit location is
                -- automatically excluded by the prerecruit code
                for id,_ in pairs(fred.data.gamedata.my_units_MP) do
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

                prerecruit = fred:prerecruit_units(closest_keep, outofway_units)
                -- Need to do this, or the recruit CA will try to recruit the same units again later
                fred:clear_prerecruit()
            end
            --DBG.dbms(prerecruit)

            -- This needs to be kept separately for power_stats calculations,
            -- because prerecruit gets deleted after the recruiting is done
            local assigned_recruits = {}
            for _,unit in ipairs(prerecruit.units) do
                table.insert(assigned_recruits, { recruit_type = unit.recruit_type })
            end
            --DBG.dbms(assigned_recruits)

            -- Finding areas and units for attacking/defending in each zone
            --print('Move toward (highest blurred vulnerability):')
            local goal_hexes = {}
            for zone_id,cfg in pairs(raw_cfgs_main) do
                local max_ld, loc
                for x,y,village in FU.fgumap_iter(villages_to_protect_maps[zone_id]) do
                    if village.protect then
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
                end

                if max_ld then
                    --print('max protect ld:', zone_id, max_ld, loc[1], loc[2])
                    goal_hexes[zone_id] = { loc }
                else
                    goal_hexes[zone_id] = cfg.center_hexes
                end
            end
            --DBG.dbms(goal_hexes)


            local distance_from_front = {}
            for id,l in pairs(gamedata.my_units) do
                --print(id, l[1], l[2])
                if (not gamedata.unit_infos[id].canrecruit) then
                    distance_from_front[id] = {}
                    for zone_id,locs in pairs(goal_hexes) do
                        --print('  ' .. zone_id)
                        local min_dist
                        for _,loc in ipairs(locs) do
                            local _, cost = wesnoth.find_path(gamedata.unit_copies[id], loc[1], loc[2], { ignore_units = true })
                            cost = cost + gamedata.unit_infos[id].max_moves - gamedata.unit_infos[id].moves
                            --print('    ' .. loc[1] .. ',' .. loc[2], cost)

                            if (not min_dist) or (min_dist > cost) then
                                min_dist = cost
                            end
                        end
                        --print('    -> ' .. min_dist, gamedata.unit_infos[id].max_moves)
                        distance_from_front[id][zone_id] = min_dist / gamedata.unit_infos[id].max_moves
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

            local enemy_value_ratio = 1.25
            local attacker_ratings = {}
            local max_rating
            for id,_ in pairs(gamedata.my_units) do
                if (not gamedata.unit_infos[id].canrecruit)
                    and (not used_ids[id])
                then
                    --print(id)
                    attacker_ratings[id] = {}
                    for zone_id,data in pairs(assigned_enemies) do
                        --print('  ' .. zone_id)

                        local tmp_enemies = {}
                        for enemy_id,_ in pairs(data) do
                            --print('    ' .. enemy_id)
                            local att = fred.data.turn_data.unit_attacks[id][enemy_id]

                            local damage_taken = att.damage_counter.enemy_gen_hc * att.damage_counter.base_taken + att.damage_counter.extra_taken
                            damage_taken = damage_taken + att.damage_forward.enemy_gen_hc * att.damage_forward.base_taken + att.damage_forward.extra_taken
                            damage_taken = damage_taken / 2

                            local damage_done = att.damage_counter.my_gen_hc * att.damage_counter.base_done + att.damage_counter.extra_done
                            damage_done = damage_done + att.damage_forward.my_gen_hc * att.damage_forward.base_done + att.damage_forward.extra_done
                            damage_done = damage_done / 2

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
                                av_damage_taken = av_damage_taken + enemy_weight * frac_taken * gamedata.unit_infos[id].hitpoints

                                local frac_done = enemy.damage_done - enemy.enemy_regen
                                frac_done = frac_done / gamedata.unit_infos[enemy.enemy_id].hitpoints
                                --print('      frac_done 1', frac_done)
                                frac_done = FU.weight_s(frac_done, 0.5)
                                --print('      frac_done 2', frac_done)
                                --if (frac_done > 1) then frac_done = 1 end
                                --if (frac_done < 0) then frac_done = 0 end
                                av_damage_done = av_damage_done + enemy_weight * frac_done * gamedata.unit_infos[enemy.enemy_id].hitpoints

                                --print('  ', av_damage_taken, av_damage_done, cum_weight)
                            end

                            --print('  cum: ', av_damage_taken, av_damage_done, cum_weight)
                            av_damage_taken = av_damage_taken / cum_weight
                            av_damage_done = av_damage_done / cum_weight
                            --print('  av:  ', av_damage_taken, av_damage_done)

                            -- We want the ToD-independent rating here.
                            -- The rounding is going to be off for ToD modifier, but good enough for now
                            --av_damage_taken = av_damage_taken / gamedata.unit_infos[id].tod_mod
                            --av_damage_done = av_damage_done / gamedata.unit_infos[id].tod_mod
                            --print('  av:  ', av_damage_taken, av_damage_done)

                            -- The rating must be positive for the analysis below to work
                            local av_hp_left = gamedata.unit_infos[id].hitpoints - av_damage_taken
                            if (av_hp_left < 0) then av_hp_left = 0 end
                            --print('    ' .. enemy_value_ratio, av_damage_done, av_hp_left)

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
                --print(id)
                unit_ratings[id] = {}

                for zone_id,rating in pairs(zone_ratings) do
                    local distance = distance_from_front[id][zone_id]
                    if (distance < 1) then distance = 1 end
                    local distance_rating = 1 / distance
                    --print('  ' .. zone_id, distance, distance_rating, rating)

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

            local power_stats = fred:calc_power_stats(raw_cfgs_main, assigned_units, assigned_enemies, assigned_recruits, gamedata)
            --DBG.dbms(power_stats)

            local keep_trying = true
            while keep_trying do
                keep_trying = false
                --print()

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
                for zone_id,data in pairs(power_stats.zones) do
                    local frac_needed = data.power_missing / data.power_needed
                    --print(zone_id, frac_needed, data.power_missing, data.power_needed)
                    local utility = math.sqrt(frac_needed)
                    hold_utility[zone_id] = utility
                end
                --DBG.dbms(hold_utility)

                local max_rating, best_zone, best_unit
                for zone_id,data in pairs(power_stats.zones) do
                    -- Base rating for the zone is the power missing times the ratio of
                    -- power missing to power needed
                    local ratio = 1
                    if (data.power_needed > 0) then
                        ratio = data.power_missing / data.power_needed
                    end

                    local zone_rating = data.power_missing
                    --if ((n_units[zone_id] or 0) + 1 >= (n_enemies[zone_id] or 0)) then
                    --    zone_rating = zone_rating * math.sqrt(ratio)
                    --    print('    -- decreasing zone_rating by factor ' .. math.sqrt(ratio), zone_rating)
                    --end
                    --print(zone_id, data.power_missing .. '/' .. data.power_needed .. ' = ' .. ratio, zone_rating)
                    --print('  zone_rating', zone_rating)

                    for id,unit_zone_ratings in pairs(unit_ratings) do
                        local unit_rating = 0
                        local unit_zone_rating = 1
                        if unit_zone_ratings[zone_id] and unit_zone_ratings[zone_id].rating then
                            unit_zone_rating = unit_zone_ratings[zone_id].rating
                            unit_rating = unit_zone_rating * zone_rating
                            --print('  ' .. id, unit_zone_rating, zone_rating, unit_rating)
                        end

                        local inertia = 0
                        if pre_assigned_units[id] and (pre_assigned_units[id] == zone_id) then
                            inertia = 0.1 * FU.unit_base_power(gamedata.unit_infos[id]) * unit_zone_rating
                        end

                        unit_rating = unit_rating + inertia

                        --print('    ' .. zone_id .. ' ' .. id, retreat_utilities[id], hold_utility[zone_id])
                        if (retreat_utilities[id] > hold_utility[zone_id]) then
                            unit_rating = -1
                        end

                        if (unit_rating > 0) and ((not max_rating) or (unit_rating > max_rating)) then
                            max_rating = unit_rating
                            best_zone = zone_id
                            best_unit = id
                        end
                        --print('  ' .. id .. '  ' .. gamedata.unit_infos[id].hitpoints .. '/' .. gamedata.unit_infos[id].max_hitpoints, unit_rating, inertia)
                    end
                end

                if best_unit then
                    --print('--> ' .. best_zone, best_unit, gamedata.unit_copies[best_unit].x .. ',' .. gamedata.unit_copies[best_unit].y)
                    if (not assigned_units[best_zone]) then
                        assigned_units[best_zone] = {}
                    end
                    assigned_units[best_zone][best_unit] = gamedata.units[best_unit]

                    unit_ratings[best_unit] = nil
                    power_stats = fred:calc_power_stats(raw_cfgs_main, assigned_units, assigned_enemies, assigned_recruits, gamedata)

                    --DBG.dbms(assigned_units)
                    --DBG.dbms(unit_ratings)
                    --DBG.dbms(power_stats)

                    if (next(unit_ratings)) then
                        keep_trying = true
                    end
                end
            end
            pre_assigned_units = nil
            --DBG.dbms(assigned_units)
            --DBG.dbms(power_stats)


            -- All units with non-zero retreat utility are put on the list of possible retreaters
            local retreaters = {}
            for id,_ in pairs(unit_ratings) do
                if (retreat_utilities[id] > 0) then
                    retreaters[id] = gamedata.units[id]
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

            power_stats = fred:calc_power_stats(raw_cfgs_main, assigned_units, assigned_enemies, assigned_recruits, gamedata)
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
                local max_rating, best_id
                for id,_ in pairs(reserve_units) do
                    for _,center_hex in ipairs(raw_cfgs_main[best_zone_id].center_hexes) do
                        local _, cost = wesnoth.find_path(gamedata.unit_copies[id], center_hex[1], center_hex[2], { ignore_units = true })
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
                end
                --print('best:', best_zone_id, best_id)
                if (not assigned_units[best_zone_id]) then
                    assigned_units[best_zone_id] = {}
                end
                assigned_units[best_zone_id][best_id] = gamedata.units[best_id]
                reserve_units[best_id] = nil

                power_stats = fred:calc_power_stats(raw_cfgs_main, assigned_units, assigned_enemies, assigned_recruits, gamedata)
                --DBG.dbms(power_stats)
            end
            --DBG.dbms(power_stats)


            fred:replace_zones(assigned_units, assigned_enemies, protect_locs, actions)


            fred.data.ops_data = {
                leader_threats = leader_threats,
                assigned_enemies = assigned_enemies,
                assigned_units = assigned_units,
                retreaters = retreaters,
                assigned_recruits = assigned_recruits,
                protect_locs = protect_locs,
                actions = actions,
                prerecruit = prerecruit
            }
            --DBG.dbms(fred.data.ops_data)
            --DBG.dbms(fred.data.ops_data.protect_locs)
            --DBG.dbms(fred.data.ops_data.assigned_enemies)
            --DBG.dbms(fred.data.ops_data.assigned_units)

            FU.print_debug(show_debug_analysis, '--- Done determining turn_data ---\n')
        end


        function fred:update_ops_data()
            local gamedata = fred.data.gamedata
            local ops_data = fred.data.ops_data
            local raw_cfgs_main = fred:get_raw_cfgs()
            local side_cfgs = fred:get_side_cfgs()

            -- After each move, we update:
            --  - village grabbers (as a village might have opened, or units be used for attacks)
            --  - protect_locs
            --
            -- TODO:
            --  - leader_locs
            --  - prerecruits

            -- Reset the ops_data unit tables. All this does is remove a unit
            -- from the respective lists in case it was killed ina previous action.
            for zone_id,units in pairs(ops_data.assigned_units) do
                for id,_ in pairs(units) do
                    ops_data.assigned_units[zone_id][id] = gamedata.units[id]
                end
            end
            for zone_id,units in pairs(ops_data.assigned_units) do
                if (not next(units)) then
                    ops_data.assigned_units[zone_id] = nil
                end
            end

            for zone_id,enemies in pairs(ops_data.assigned_enemies) do
                for id,_ in pairs(enemies) do
                    ops_data.assigned_enemies[zone_id][id] = gamedata.units[id]
                end
            end
            for zone_id,enemies in pairs(ops_data.assigned_enemies) do
                if (not next(enemies)) then
                    ops_data.assigned_enemies[zone_id] = nil
                end
            end

            if ops_data.leader_threats.enemies then
                for id,_ in pairs(ops_data.leader_threats.enemies) do
                    ops_data.leader_threats.enemies[id] = gamedata.units[id]
                end
                if (not next(ops_data.leader_threats.enemies)) then
                    ops_data.leader_threats.enemies = nil
                    ops_data.leader_threats.significant_threat = false
                end
            end


            local villages_to_protect_maps = FVU.villages_to_protect(raw_cfgs_main, side_cfgs, gamedata)
            local zone_village_goals = FVU.village_goals(villages_to_protect_maps, gamedata)
            --DBG.dbms(zone_village_goals)
            --DBG.dbms(villages_to_protect_maps)

            -- Remove existing village actions that are not possible any more because
            -- 1. the reserved unit has moved
            -- 2. the reserved unit cannot get to the goal any more
            -- This can happen if the units were used in other actions, moves
            -- to get out of the way for another unit or possibly due to a WML event
            for i_a=#ops_data.actions.villages,1,-1 do
                local valid_action = true
                local action = ops_data.actions.villages[i_a].action
                for i_u,unit in ipairs(action.units) do
                    if (not unit) then
                        print('Trying to identify error !!!!!!!!')
                        print(i_a, i_u)
                        DBG.dbms(ops_data.actions.villages, -1)
                        DBG.dbms(action)
                    end
                    if (gamedata.units[unit.id][1] ~= unit[1]) or (gamedata.units[unit.id][2] ~= unit[2]) then
                        --print(unit.id .. ' has moved')
                        valid_action = false
                        break
                    else
                        if (not FU.get_fgumap_value(gamedata.reach_maps[unit.id], action.dsts[i_u][1],  action.dsts[i_u][2], 'moves_left')) then
                            --print(unit.id .. ' cannot get to village goal any more')
                            valid_action = false
                            break
                        end
                    end
                end

                if (not valid_action) then
                    --print('deleting village action:', i_a)
                    table.remove(ops_data.actions.villages, i_a)
                end
            end

            local retreat_utilities = FU.retreat_utilities(gamedata)
            --DBG.dbms(retreat_utilities)


            local actions = { villages = {} }
            local assigned_units = {}

            FVU.assign_grabbers(
                zone_village_goals,
                villages_to_protect_maps,
                assigned_units,
                actions.villages,
                fred.data.turn_data.unit_attacks,
                gamedata
            )
            FVU.assign_scouts(zone_village_goals, assigned_units, retreat_utilities, gamedata)
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
            --print('new_village_action', new_village_action)

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
            ops_data.protect_locs = FVU.protect_locs(villages_to_protect_maps, gamedata)
            fred:replace_zones(ops_data.assigned_units, ops_data.assigned_enemies, ops_data.protect_locs, ops_data.actions)


            -- Once the leader has no MP left, we reconsider the leader threats
            -- TODO: we might want to handle reassessing leader locs and threats differently
            local leader_proxy = wesnoth.get_unit(gamedata.leader_x, gamedata.leader_y)
            if (leader_proxy.moves == 0) then
                ops_data.leader_threats.leader_locs = {}
                ops_data.leader_threats.protect_locs = { { leader_proxy.x, leader_proxy.y } }

                fred:assess_leader_threats(ops_data.leader_threats, ops_data.protect_locs, leader_proxy, raw_cfgs_main, side_cfgs, gamedata)
            end


            -- Remove prerecruit actions, if the hexes are not available any more
            for i = #ops_data.prerecruit.units,1,-1 do
                local x, y = ops_data.prerecruit.units[i].recruit_hex[1], ops_data.prerecruit.units[i].recruit_hex[2]
                local id = FU.get_fgumap_value(gamedata.my_unit_map, x, y, 'id')
                if id and gamedata.my_units_noMP[id] then
                    table.remove(ops_data.prerecruit.units, i)
                end
            end
        end


        function fred:get_action_cfgs()
            local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'zone_control'
            if debug_eval then print_time('     - Evaluating defend zones map analysis:') end

            local gamedata = fred.data.gamedata
            local ops_data = fred.data.ops_data
            --DBG.dbms(ops_data)

            -- These are only the raw_cfgs of the 3 main zones
            --local raw_cfgs = fred:get_raw_cfgs('all')
            --local raw_cfgs_main = fred:get_raw_cfgs()
            --DBG.dbms(raw_cfgs_main)
            --DBG.dbms(fred.data.analysis)


            fred.data.zone_cfgs = {}

            -- For all of the main zones, find assigned units that have moves left
            local holders_by_zone, attackers_by_zone = {}, {}
            for zone_id,_ in pairs(ops_data.actions.hold_zones) do
                if ops_data.assigned_units[zone_id] then
                    for id,_ in pairs(ops_data.assigned_units[zone_id]) do
                        if gamedata.my_units_MP[id] then
                            if (not holders_by_zone[zone_id]) then holders_by_zone[zone_id] = {} end
                            holders_by_zone[zone_id][id] = gamedata.units[id]
                        end
                        if (gamedata.unit_copies[id].attacks_left > 0) then
                            local is_attacker = true
                            if gamedata.my_units_noMP[id] then
                                is_attacker = false
                                for xa,ya in H.adjacent_tiles(gamedata.my_units_noMP[id][1], gamedata.my_units_noMP[id][2]) do
                                    if FU.get_fgumap_value(gamedata.enemy_map, xa, ya, 'id') then
                                        is_attacker = true
                                        break
                                    end
                                end
                            end

                            if is_attacker then
                                if (not attackers_by_zone[zone_id]) then attackers_by_zone[zone_id] = {} end
                                attackers_by_zone[zone_id][id] = gamedata.units[id]
                            end
                        end
                    end
                end
            end

            -- We add the leader as a potential attacker to all zones but only if he's on the keep
            local leader = gamedata.leaders[wesnoth.current.side]
            --print('leader.id', leader.id)
            if (gamedata.unit_copies[leader.id].attacks_left > 0)
               and wesnoth.get_terrain_info(wesnoth.get_terrain(leader[1], leader[2])).keep
            then
                local is_attacker = true
                if gamedata.my_units_noMP[leader.id] then
                    is_attacker = false
                    for xa,ya in H.adjacent_tiles(gamedata.my_units_noMP[leader.id][1], gamedata.my_units_noMP[leader.id][2]) do
                        if FU.get_fgumap_value(gamedata.enemy_map, xa, ya, 'id') then
                            is_attacker = true
                            break
                        end
                    end
                end

                if is_attacker then
                    for zone_id,_ in pairs(ops_data.actions.hold_zones) do
                        if (not attackers_by_zone[zone_id]) then attackers_by_zone[zone_id] = {} end
                        attackers_by_zone[zone_id][leader.id] = gamedata.units[leader.id]
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
                        if gamedata.enemies[enemy_id] then
                            if (not threats_by_zone[zone_id]) then threats_by_zone[zone_id] = {} end
                            threats_by_zone[zone_id][enemy_id] = gamedata.units[enemy_id]
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
            for enemy_id,loc in pairs(gamedata.enemies) do
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
                    --print(zone_id,id)
                    if ops_data.leader_threats.enemies and ops_data.leader_threats.enemies[id] then
                        if (not leader_threats_by_zone[zone_id]) then
                            leader_threats_by_zone[zone_id] = {}
                        end
                        leader_threats_by_zone[zone_id][id] = loc
                    end
                end
            end
            --DBG.dbms(leader_threats_by_zone)

            local power_stats = fred:calc_power_stats(ops_data.actions.hold_zones, ops_data.assigned_units, ops_data.assigned_enemies, ops_data.assigned_recruits, gamedata)
            --DBG.dbms(power_stats)


            ----- Leader threat actions -----

            if ops_data.leader_threats.significant_threat then
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
                        table.insert(fred.data.zone_cfgs, {
                            zone_id = zone_id,
                            action_type = 'attack',
                            zone_units = attackers_by_zone[zone_id],
                            targets = threats,
                            value_ratio = 0.6, -- more aggressive for direct leader threats, but not too much
                            rating = leader_base_ratings.attack + power_stats.zones[zone_id].power_needed
                        })
                    end
                end

                -- Full move to next_hop
                if ops_data.leader_threats.leader_locs.next_hop
                    and gamedata.my_units_MP[leader.id]
                    and ((ops_data.leader_threats.leader_locs.next_hop[1] ~= leader[1]) or (ops_data.leader_threats.leader_locs.next_hop[2] ~= leader[2]))
                then
                    table.insert(fred.data.zone_cfgs, {
                        action = {
                            zone_id = zone_id,
                            action_str = zone_id .. ': move leader toward keep',
                            units = { leader },
                            dsts = { ops_data.leader_threats.leader_locs.next_hop }
                        },
                        rating = leader_base_ratings.move_to_keep
                    })
                end

                -- Partial move to keep
                if ops_data.leader_threats.leader_locs.closest_keep
                    and gamedata.my_units_MP[leader.id]
                    and ((ops_data.leader_threats.leader_locs.closest_keep[1] ~= leader[1]) or (ops_data.leader_threats.leader_locs.closest_keep[2] ~= leader[2]))
                then
                    table.insert(fred.data.zone_cfgs, {
                        action = {
                            zone_id = zone_id,
                            action_str = zone_id .. ': move leader to keep',
                            units = { leader },
                            dsts = { ops_data.leader_threats.leader_locs.closest_keep },
                            partial_move = true
                        },
                        rating = leader_base_ratings.move_to_keep
                    })
                end

                -- Recruiting
                if ops_data.prerecruit.units[1] then
                    -- TODO: This check should not be necessary, but something can
                    -- go wrong occasionally. Will eventually have to check why, for
                    -- now I just put in this workaround.
                    local current_gold = wesnoth.sides[wesnoth.current.side].gold
                    local cost = wesnoth.unit_types[ops_data.prerecruit.units[1].recruit_type].cost
                    if (current_gold >= cost) then
                        table.insert(fred.data.zone_cfgs, {
                            action = {
                                zone_id = zone_id,
                                action_str = zone_id .. ': recruit for leader protection',
                                type = 'recruit',
                                recruit_units = ops_data.prerecruit.units
                            },
                            rating = leader_base_ratings.recruit
                        })
                    end
                end

                -- If leader injured, full move to village
                -- (this will automatically force more recruiting, if gold/castle hexes left)
                if ops_data.leader_threats.leader_locs.closest_village
                    and gamedata.my_units_MP[leader.id]
                    and ((ops_data.leader_threats.leader_locs.closest_village[1] ~= leader[1]) or (ops_data.leader_threats.leader_locs.closest_village[2] ~= leader[2]))
                then
                    table.insert(fred.data.zone_cfgs, {
                        action = {
                            zone_id = zone_id,
                            action_str = zone_id .. ': move leader to village',
                            units = { leader },
                            dsts = { ops_data.leader_threats.leader_locs.closest_village }
                        },
                        rating = leader_base_ratings.move_to_village
                    })
                end
            end

            ----- Village actions -----

            for i,action in ipairs(ops_data.actions.villages) do
                action.rating = 20000 - i
                table.insert(fred.data.zone_cfgs, action)
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
            local value_ratio = FU.get_value_ratio(gamedata)

            for zone_id,zone_units in pairs(holders_by_zone) do
                local power_rating = power_stats.zones[zone_id].power_needed - power_stats.zones[zone_id].my_power / 1000

                if threats_by_zone[zone_id] and attackers_by_zone[zone_id] then
                    -- Attack --
                    table.insert(fred.data.zone_cfgs,  {
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
                    table.insert(fred.data.zone_cfgs, {
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
                    if gamedata.my_units_MP[id] then
                        if (not retreaters) then retreaters = {} end
                        retreaters[id] = gamedata.units[id]
                    end
                end
            end
            --DBG.dbms(retreaters)


            if retreaters then
                table.insert(fred.data.zone_cfgs, {
                    zone_id = 'all_map',
                    action_type = 'retreat',
                    retreaters = retreaters,
                    rating = base_ratings.retreat
                })
            end


            -- Advancing is still done in the old zones
            local raw_cfgs_main = fred:get_raw_cfgs()
            local advancers_by_zone = {}
            for zone_id,_ in pairs(raw_cfgs_main) do
                if ops_data.assigned_units[zone_id] then
                    for id,_ in pairs(ops_data.assigned_units[zone_id]) do
                        if gamedata.my_units_MP[id] then
                            if (not advancers_by_zone[zone_id]) then advancers_by_zone[zone_id] = {} end
                            advancers_by_zone[zone_id][id] = gamedata.units[id]
                        end
                    end
                end
            end
            --DBG.dbms(advancers_by_zone)

            for zone_id,zone_units in pairs(advancers_by_zone) do
                local power_rating = 0
                for id,_ in pairs(zone_units) do
                    power_rating = power_rating - FU.unit_base_power(gamedata.unit_infos[id])
                end
                power_rating = power_rating / 1000

                -- Advance --
                table.insert(fred.data.zone_cfgs, {
                    zone_id = zone_id,
                    action_type = 'advance',
                    zone_units = advancers_by_zone[zone_id],
                    rating = base_ratings.advance + power_rating
                })
            end


            -- Favorable attacks. These are cross-zone
            table.insert(fred.data.zone_cfgs, {
                zone_id = 'all_map',
                action_type = 'attack',
                rating = base_ratings.fav_attack,
                value_ratio = 2.0 -- only very favorable attacks will pass this
            })


            -- TODO: this is a catch all action, that moves all units that were
            -- missed. Ideally, there will be no need for this in the end.
            table.insert(fred.data.zone_cfgs, {
                zone_id = 'all_map',
                action_type = 'advance',
                rating = base_ratings.advance_all
            })

            --DBG.dbms(fred.data.zone_cfgs)

            -- Now sort by the ratings embedded in the cfgs
            table.sort(fred.data.zone_cfgs, function(a, b) return a.rating > b.rating end)

            --DBG.dbms(fred.data.zone_cfgs)
        end


        ----- Functions for getting the best actions -----

        ----- Attack: -----
        function fred:get_attack_action(zone_cfg)
            if debug_eval then print_time('  --> attack evaluation: ' .. zone_cfg.zone_id) end
            --DBG.dbms(zone_cfg)

            local gamedata = fred.data.gamedata
            local move_cache = fred.data.move_cache

            local targets = {}
            if zone_cfg.targets then
                targets = zone_cfg.targets
            else
                targets = gamedata.enemies
            end
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

            -- Attackers is everybody in zone_cfg.zone_units is set,
            -- or all units with attacks left otherwise
            local zone_units_attacks = {}
            if zone_cfg.zone_units then
                zone_units_attacks = zone_cfg.zone_units
            else
                for id,loc in pairs(gamedata.my_units) do
                    local is_leader_and_off_keep = false
                    if gamedata.unit_infos[id].canrecruit and (gamedata.unit_infos[id].moves > 0) then
                        if (not wesnoth.get_terrain_info(wesnoth.get_terrain(loc[1], loc[2])).keep) then
                            is_leader_and_off_keep = true
                        end
                    end

                    if (gamedata.unit_copies[id].attacks_left > 0) then
                        -- The leader counts as one of the attackers, but only if he's on his keep
                        if (not is_leader_and_off_keep) then
                            zone_units_attacks[id] = loc
                        end
                    end
                end
            end
            --DBG.dbms(zone_units_attacks)

            local attacker_map = {}
            for id,loc in pairs(zone_units_attacks) do
                attacker_map[loc[1] * 1000 + loc[2]] = id
            end

            -- How much more valuable do we consider the enemy units than our own
            local value_ratio = zone_cfg.value_ratio or FU.cfg_default('value_ratio')
            --print_time('value_ratio', value_ratio)

            -- We need to make sure the units always use the same weapon below, otherwise
            -- the comparison is not fair.
            local cfg_attack = {
                value_ratio = value_ratio,
                use_max_damage_weapons = true
            }

            local combo_ratings = {}
            for target_id, target_loc in pairs(targets) do
                local target = {}
                target[target_id]= target_loc

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
                    zone_units_attacks, target, gamedata.reach_maps, false, move_cache, cfg_attack
                )
                --print_time('#attack_combos', #attack_combos)


                for j,combo in ipairs(attack_combos) do
                    --print_time('combo ' .. j)

                    -- Only check out the first 1000 attack combos to keep evaluation time reasonable
                    -- TODO: can we have these ordered with likely good rating first?
                    if (j > 1000) then break end

                    local attempt_trapping = is_trappable_enemy

                    local combo_outcome = FAU.attack_combo_eval(combo, target, gamedata, move_cache, cfg_attack)

                    -- For this first assessment, we use the full rating, that is, including
                    -- all types of damage, extra rating, etc. While this is not accurate for
                    -- the state at the end of the attack, it gives a good overall rating
                    -- for the attacker/defender pairings involved.
                    local combo_rating = combo_outcome.rating_table.rating

                    local bonus_rating = 0

                    --DBG.dbms(combo_outcome.rating_table)
                    --print('   combo ratings: ', combo_outcome.rating_table.rating, combo_outcome.rating_table.attacker.rating, combo_outcome.rating_table.defender.rating)

                    -- Don't attack if the leader is involved and has chance to die > 0
                    local do_attack = true

                    -- Don't do if this would take all the keep hexes away from the leader
                    -- TODO: this is a double loop; do this for now, because both arrays
                    -- are small, but optimize later
                    if do_attack and (#available_keeps > 0) then
                        do_attack = false
                        for _,keep in ipairs(available_keeps) do
                            local keep_taken = false
                            for i_d,dst in ipairs(combo_outcome.dsts) do
                                if (not combo_outcome.attacker_infos[i_d].canrecruit)
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
                    -- This is only the chance of poison/slow in this attack, if he is already
                    -- poisoned/slowed, this is handled by the retreat code.
                    -- Also don't do the attack if the leader ends up having low stats, unless he
                    -- cannot move in the first place.
                    if do_attack then
                        for k,att_outcome in ipairs(combo_outcome.att_outcomes) do
                            if (combo_outcome.attacker_infos[k].canrecruit) then
                                if (att_outcome.hp_chance[0] > 0.0) then
                                    do_attack = false
                                    break
                                end

                                if (att_outcome.slowed > 0.0)
                                    and (not combo_outcome.attacker_infos[k].status.slowed)
                                then
                                    do_attack = false
                                    break
                                end

                                if (att_outcome.poisoned > 0.0)
                                    and (not combo_outcome.attacker_infos[k].status.poisoned)
                                    and (not combo_outcome.attacker_infos[k].abilities.regenerate)
                                then
                                    do_attack = false
                                    break
                                end

                                if (combo_outcome.attacker_infos[k].moves > 0) then
                                    if (att_outcome.average_hp < combo_outcome.attacker_infos[k].max_hitpoints / 2) then
                                        do_attack = false
                                        break
                                    end
                                end

                            end
                        end
                    end

                    if do_attack then
                        -- Discourage attacks from hexes adjacent to villages that are
                        -- unoccupied by an AI unit without MP or one of the attackers,
                        -- except if it's the hex the target is on, of course

                        local adj_villages_map = {}
                        for _,dst in ipairs(combo_outcome.dsts) do
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
                                    for _,dst in ipairs(combo_outcome.dsts) do
                                        if (dst[1] == x) and (dst[2] == y) then
                                            --print('Village is used in attack')
                                            adj_unocc_village = adj_unocc_village - 1
                                        end
                                    end
                                end

                            end
                        end

                        -- For each such village found, we give a penalty eqivalent to 10 HP of the target
                        -- and we do not do the attack at all if the CTD of the defender is low
                        if (adj_unocc_village > 0) then
                            if (combo_outcome.def_outcome.hp_chance[0] < 0.5) then
                                -- TODO: this condition should maybe only apply when the target
                                -- can reach the village after the attack?
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
                            for _,dst in ipairs(combo_outcome.dsts) do
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
                            -- bonus eqivalent to 8 HP * (1 - CTD) of the target
                            if trapping_bonus then
                                local unit_value = FU.unit_value(gamedata.unit_infos[target_id])
                                local bonus = 8. / gamedata.unit_infos[target_id].max_hitpoints * unit_value

                                -- Trapping is pointless if the target dies
                                bonus = bonus * (1 - combo_outcome.def_outcome.hp_chance[0])
                                -- Potential TODO: the same is true if one of the attackers needed for
                                -- trapping dies, but that already has a large penalty, and we'd have
                                -- to check that the unit is not trapped any more in combos with more
                                -- than 2 attackers. This is likely not worth the effort.

                                --print('Applying trapping bonus', bonus_rating, bonus)
                                bonus_rating = bonus_rating + bonus
                            end
                        end

                        -- Discourage use of poisoners:
                        --  - In attacks that have a high chance to result in kill
                        --  - Against unpoisonable units and units which are already poisoned
                        --  - Against regenerating units
                        --  - More than one poisoner
                        -- These are independent of whether the poison attack is actually used in
                        -- this attack combo, the motivation being that it takes away poison use
                        -- from other attack where it may be more useful, rather than the use of
                        -- it in this attack, as that is already taken care of in the attack outcome
                        local number_poisoners = 0
                        for i_a,attacker in ipairs(combo_outcome.attacker_infos) do
                            local is_poisoner = false
                            for _,weapon in ipairs(attacker.attacks) do
                                if weapon.poison then
                                    number_poisoners = number_poisoners + 1
                                    break
                                end
                            end
                        end

                        if (number_poisoners > 0) then
                            local poison_penalty = 0
                            local target_info = gamedata.unit_infos[target_id]

                            -- Attack with chance to kill, penalty equivalent to 8 HP of the target times CTK
                            if (combo_outcome.def_outcome.hp_chance[0] > 0) then
                                poison_penalty = poison_penalty + 8. * combo_outcome.def_outcome.hp_chance[0] * number_poisoners
                            end

                            -- Already poisoned or unpoisonable unit
                            if target_info.status.poisoned or target_info.status.unpoisonable then
                                poison_penalty = poison_penalty + 8. * number_poisoners
                            end

                            -- Regenerating unit, but to a lesser degree, as poison is still useful here
                            if target_info.abilities.regenerate then
                                poison_penalty = poison_penalty + 4. * number_poisoners
                            end

                            -- More than one poisoner: don't quite use full amount as there's
                            -- a higher chance to poison target when several poisoners are used
                            -- In principle, one could could calculate the progressive chance
                            -- to poison here, but that seems overkill given the approximate nature
                            -- of the whole calculation in the first place
                            if (number_poisoners > 1) then
                                poison_penalty = poison_penalty + 6. * (number_poisoners - 1)
                            end

                            poison_penalty = poison_penalty / target_info.max_hitpoints * FU.unit_value(target_info)
                            bonus_rating = bonus_rating - poison_penalty
                        end

                        -- Discourage use of slow:
                        --  - In attacks that have a high chance to result in kill
                        --  - Against units which are already slowed
                        --  - More than one slower
                        local number_slowers = 0
                        for i_a,attacker in ipairs(combo_outcome.attacker_infos) do
                            local is_slower = false
                            for _,weapon in ipairs(attacker.attacks) do
                                if weapon.slow then
                                    number_slowers = number_slowers + 1
                                    break
                                end
                            end
                        end

                        if (number_slowers > 0) then
                            local slow_penalty = 0
                            local target_info = gamedata.unit_infos[target_id]

                            -- Attack with chance to kill, penalty equivalent to 4 HP of the target times CTK
                            if (combo_outcome.def_outcome.hp_chance[0] > 0) then
                                slow_penalty = slow_penalty + 4. * combo_outcome.def_outcome.hp_chance[0] * number_slowers
                            end

                            -- Already slowed unit
                            if target_info.status.slowed then
                                slow_penalty = slow_penalty + 4. * number_slowers
                            end

                            -- More than one slower
                            if (number_slowers > 1) then
                                slow_penalty = slow_penalty + 3. * (number_slowers - 1)
                            end

                            slow_penalty = slow_penalty / target_info.max_hitpoints * FU.unit_value(target_info)
                            bonus_rating = bonus_rating - slow_penalty
                        end

                        -- Discourage use of plaguers:
                        --  - Against unplagueable units
                        --  - More than one plaguer
                        local number_plaguers = 0
                        for i_a,attacker in ipairs(combo_outcome.attacker_infos) do
                            local is_plaguer = false
                            for _,weapon in ipairs(attacker.attacks) do
                                if weapon.plague then
                                    number_plaguers = number_plaguers + 1
                                    break
                                end
                            end
                        end

                        if (number_plaguers > 0) then
                            local plague_penalty = 0
                            local target_info = gamedata.unit_infos[target_id]

                            -- This is a large penalty, as it is the equivalent of the gold value
                            -- of a walking corpse (that is, unlike other contributions, this
                            -- is not multiplied by unit_value / max_hitpoints).  However, as it
                            -- is not guaranteed that another attack would result in a new WC, we
                            -- only use half that value

                            -- Unplagueable unit
                            if target_info.status.unplagueable then
                                plague_penalty = plague_penalty + 0.5 * 8. * number_plaguers
                            end

                            -- More than one plaguer: don't quite use full amount as there's
                            -- a higher chance to plague target when several plaguers are used
                            if (number_plaguers > 1) then
                                plague_penalty = plague_penalty + 0.5 * 6. * (number_plaguers - 1)
                            end

                            print('Applying plague penalty', bonus_rating, plague_penalty)

                            bonus_rating = bonus_rating - plague_penalty
                        end
                        --print_time(' -----------------------> rating', combo_rating, bonus_rating)


                        local pre_rating = combo_rating + bonus_rating

                        -- Derate combo if it uses too many units for diminishing return
                        local derating = 1
                        local n_att = #combo_outcome.attacker_infos
                        if (pre_rating > 0) and (n_att > 2) then
                            local progression = combo_outcome.rating_table.progression
                            -- dim_return is 1 if the last units adds exactly 1/n_att to the overall rating
                            -- It is s<1 if less value is added, >1 if more is added
                            local dim_return = (progression[n_att] - progression[n_att - 1]) / progression[n_att] * n_att
                            if (dim_return < 1) then
                                derating = math.sqrt(dim_return)
                            end
                            --print('derating', n_att, dim_return, derating)

                            pre_rating = pre_rating * derating
                        end

                        table.insert(combo_ratings, {
                            pre_rating = pre_rating,
                            bonus_rating = bonus_rating,
                            derating = derating,
                            attackers = combo_outcome.attacker_infos,
                            dsts = combo_outcome.dsts,
                            weapons = combo_outcome.att_weapons_i,
                            target = target,
                            att_outcomes = combo_outcome.att_outcomes,
                            def_outcome = combo_outcome.def_outcome,
                            rating_table = combo_outcome.rating_table,
                            attacker_damages = combo_outcome.attacker_damages,
                            defender_damage = combo_outcome.defender_damage
                        })

                        --DBG.dbms(combo_ratings)
                    end
                end
            end
            table.sort(combo_ratings, function(a, b) return a.pre_rating > b.pre_rating end)
            --DBG.dbms(combo_ratings)
            FU.print_debug(show_debug_attack, '#combo_ratings', #combo_ratings)

            -- Now check whether counter attacks are acceptable
            local max_total_rating, action
            local disqualified_attacks = {}
            for count,combo in ipairs(combo_ratings) do
                if (count > 50) and action then break end
                FU.print_debug(show_debug_attack, '\nChecking counter attack for attack on', count, next(combo.target), combo.rating_table.value_ratio, combo.rating_table.rating, action)

                -- Check whether an position in this combo was previously disqualified
                -- Only do so for large numbers of combos though; there is a small
                -- chance of a later attack that uses the same hexes being qualified
                -- because the hexes the units are on work better for the forward attack.
                -- So if there are not too many combos, we calculate all of them.
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

                    -- TODO: Need to apply correctly:
                    --   - attack locs
                    --   - new HP - use average
                    --   - just apply level of opponent?
                    --   - potential level-up
                    --   - delayed damage
                    --   - slow for defender (wear of for attacker at the end of the side turn)
                    --   - plague

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

                        local hp = combo.att_outcomes[i_a].average_hp
                        if (hp < 1) then hp = 1 end
                        --print('attacker hp before, after:', old_HP_attackers[i_a], hp)

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
                    --print('target hp before, after:', old_HP_target, hp_org, hp)

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

                        local counter_outcomes = FAU.calc_counter_attack(
                            attacker_moved, old_locs, combo.dsts, gamedata, move_cache, cfg_attack
                        )
                        --DBG.dbms(counter_outcomes)


                        -- forward attack: attacker damage rating and defender total rating
                        -- counter attack: attacker total rating and defender damage rating
                        -- as that is how the delayed damage is applied in game
                        -- In addition, the counter attack damage needs to be multiplied
                        -- by the chance of each unit to survive, otherwise units close
                        -- to dying are much overrated
                        -- That is then the damage that is used for the overall rating

                        -- Damages to AI units (needs to be done for each counter attack
                        -- as tables change upwards also)
                        -- Delayed damages do not apply for attackers

                        -- This is the damage on the AI attacker considered here
                        -- in the counter attack
                        local dam2 = counter_outcomes and counter_outcomes.defender_damage
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
                        if counter_outcomes then
                            for i_d,dam2 in ipairs(counter_outcomes.attacker_damages) do
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

                        local damage_rating = my_rating * value_ratio + enemy_rating

                        -- Also add in the bonus and extra ratings. They are
                        -- used to select the best attack, but not to determine
                        -- whether an attack is acceptable
                        damage_rating = damage_rating + extra_rating + combo.bonus_rating

                        FU.print_debug(show_debug_attack, '     --> damage_rating:', damage_rating)


                        if (damage_rating < min_total_damage_rating) then
                            min_total_damage_rating = damage_rating
                        end


                        -- We next check whether the counter attack is acceptable
                        -- This is different for the side leader and other units
                        -- Also, it is different for attacks by individual units without MP;
                        -- for those it simply matters whether the attack makes things
                        -- better or worse, since there isn't a coice of moving someplace else
                        if counter_outcomes and ((#combo.attackers > 1) or (attacker.moves > 0)) then
                            local counter_min_hp = counter_outcomes.def_outcome.min_hp
                            -- If there's a chance of the leader getting poisoned, slowed or killed, don't do it
                            -- unless he is poisoned/slowed already
                            if attacker.canrecruit then
                                --print('Leader: slowed, poisoned %', counter_outcomes.def_outcome.slowed, counter_outcomes.def_outcome.poisoned)
                                if (counter_outcomes.def_outcome.slowed > 0.0) and (not attacker.status.slowed) then
                                    FU.print_debug(show_debug_attack, '       leader: counter attack slow chance too high', counter_outcomes.def_outcome.slowed)
                                    acceptable_counter = false
                                    FAU.add_disqualified_attack(combo, i_a, disqualified_attacks)
                                    break
                                end

                                if (counter_outcomes.def_outcome.poisoned > 0.0) and (not attacker.status.poisoned) and (not attacker.abilities.regenerate) then
                                    FU.print_debug(show_debug_attack, '       leader: counter attack poison chance too high', counter_outcomes.def_outcome.poisoned)
                                    acceptable_counter = false
                                    FAU.add_disqualified_attack(combo, i_a, disqualified_attacks)
                                    break
                                end

                                -- Add max damages from this turn and counter-attack
                                -- Note that this is not really the maximum damage from the attack, as
                                -- attacker.hitpoints is reduced to the average HP outcome of the attack
                                -- However, min_hp for the counter also contains this reduction, so
                                -- min_outcome below has the correct value (except for rounding errors,
                                -- that's why it is compared ot 0.5 instead of 0)
                                local max_damage_attack = attacker.hitpoints - combo.att_outcomes[i_a].min_hp
                                --print('max_damage_attack, attacker.hitpoints, min_hp', max_damage_attack, attacker.hitpoints, combo.att_outcomes[i_a].min_hp)

                                -- Add damage from attack and counter attack
                                local min_outcome = counter_min_hp - max_damage_attack
                                --print('Leader: min_outcome, counter_min_hp, max_damage_attack', min_outcome, counter_min_hp, max_damage_attack)

                                local av_outcome = counter_outcomes.def_outcome.average_hp
                                --print('Leader: av_outcome', av_outcome)

                                if (min_outcome < 0.5) or (av_outcome < attacker.max_hitpoints / 2) then
                                    FU.print_debug(show_debug_attack, '       leader: counter attack outcome too low', min_outcome)
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


                        -- Also don't expose one or two units too much, unless it is safe or
                        -- there is a significant change to kill and value of kill is much
                        -- larger than chance to die.
                        -- Again single unit attacks of MP=0 units are dealt with separately
                        local check_exposure = true
                        local is_leader_threat = false

                        -- If this is a leader threat, we do not check for exposure
                        if fred.data.ops_data.leader_threats
                            and fred.data.ops_data.leader_threats.enemies
                            and fred.data.ops_data.leader_threats.enemies[target_id]
                        then
                            check_exposure = false
                            is_leader_threat = true
                        end
                        --print('check_exposure', check_exposure)


                        -- Check whether die chance for units with high XP values is too high.
                        -- This might not be sufficiently taken into account in the rating,
                        -- especially if value_ratio is low.
                        -- TODO: the equations used are pretty ad hoc at the moment. Refine?
                        if (not is_leader_threat) and (damages_my_units[i_a].die_chance > 0) then
                            local id = damages_my_units[i_a].id
                            local xp = gamedata.unit_infos[id].experience
                            local max_xp = gamedata.unit_infos[id].max_experience
                            local min_xp = math.min(max_xp - 16, max_xp / 2)
                            if (min_xp < 0) then min_xp = 0 end

                            local xp_thresh = 0
                            if (xp > max_xp - 8) then
                                xp_thresh = 0.8 + 0.2 * (1 - (max_xp - xp) / 8)
                            elseif (xp > min_xp) then
                                xp_thresh = 0.8 * (xp - min_xp) / (max_xp - 8 - min_xp)
                            end

                            local survival_chance = 1 - damages_my_units[i_a].die_chance
                            --print(id, xp, min_xp, max_xp)
                            --print('  ' .. xp_thresh, survival_chance)

                            if (survival_chance < xp_thresh) then
                                FU.print_debug(show_debug_attack, '       non-leader: counter attack too dangerous for high-XP unit', survival_chance, xp_thresh, xp)
                                acceptable_counter = false
                                FAU.add_disqualified_attack(combo, i_a, disqualified_attacks)
                                break
                            end
                        end


                        -- If one of the attack hexes is adjacent to a unit with no MP
                        -- left, we count this as not exposed
                        if check_exposure then
                            for _,dst in pairs(combo.dsts) do
                                for xa,ya in H.adjacent_tiles(dst[1], dst[2]) do
                                    if gamedata.my_unit_map_noMP[xa] and gamedata.my_unit_map_noMP[xa][ya] then
                                        check_exposure = false
                                        break
                                    end
                                end

                                if (not check_exposure) then break end
                            end
                        end
                        --print('check_exposure', check_exposure)

                        if check_exposure and counter_outcomes
                            and (#combo.attackers < 3) and (1.5 * #combo.attackers < #damages_enemy_units)
                            and ((#combo.attackers > 1) or (combo.attackers[1].moves > 0))
                        then
                            --print('       outnumbered in counter attack: ' .. #combo.attackers .. ' vs. ' .. #damages_enemy_units)
                            local die_value = damages_my_units[i_a].die_chance * damages_my_units[i_a].unit_value
                            --print('           die value ' .. damages_my_units[i_a].id .. ': ', die_value, damages_my_units[i_a].unit_value)

                            if (die_value > 0) then
                                local kill_chance = combo.def_outcome.hp_chance[0]
                                local kill_value = kill_chance * FU.unit_value(gamedata.unit_infos[target_id])
                                --print('         kill chance, kill_value: ', kill_chance, kill_value)

                                if (kill_chance < 0.33) or (kill_value < die_value * 2) then
                                    FU.print_debug(show_debug_attack, '       non-leader: counter attack too exposed', die_value, kill_value, kill_chance)
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
                    if acceptable_counter and (#combo.attackers == 1) then
                        if (combo.att_outcomes[1].hp_chance[0] < 0.25) then
                            local attacker = combo.attackers[1]

                            if (attacker.moves == 0) then
                                --print_time('  by', attacker.id, combo.dsts[1][1], combo.dsts[1][2])

                                -- Now calculate the counter attack outcome
                                local attacker_moved = {}
                                attacker_moved[attacker.id] = { combo.dsts[1][1], combo.dsts[1][2] }

                                local counter_outcomes = FAU.calc_counter_attack(
                                    attacker_moved, old_locs, combo.dsts, gamedata, move_cache, cfg_attack
                                )
                                --DBG.dbms(counter_outcomes)

                                --print_time('   counter ratings no attack:', counter_outcomes.rating_table.rating, counter_outcomes.def_outcome.hp_chance[0])

                                -- Rating if no forward attack is done is done is only the counter attack rating
                                local no_attack_rating = 0
                                if counter_outcomes then
                                    no_attack_rating = no_attack_rating - counter_outcomes.rating_table.rating
                                end
                                -- If an attack is done, it's the combined forward and counter attack rating
                                local with_attack_rating = min_total_damage_rating

                                --print('    V1: no attack rating: ', no_attack_rating, '<---', 0, -counter_outcomes.rating_table.rating)
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
                            if (combo.att_outcomes[1].hp_chance[0] > combo.def_outcome.hp_chance[0]) then
                                acceptable_counter = false
                            end
                        end
                    end

                    --print_time('  acceptable_counter', acceptable_counter)
                    local total_rating = -9999
                    if acceptable_counter then
                        total_rating = min_total_damage_rating
                        FU.print_debug(show_debug_attack, '    Acceptable counter attack for attack on', count, next(combo.target), combo.value_ratio, combo.rating_table.rating)
                        FU.print_debug(show_debug_attack, '      --> total_rating', total_rating)

                        if (total_rating > 0) then
                            total_rating = total_rating * combo.derating
                        end
                        FU.print_debug(show_debug_attack, '      --> total_rating adjusted', total_rating)

                        if (not max_total_rating) or (total_rating > max_total_rating) then
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
                            action.weapons = combo.weapons
                            action.action_str = 'attack'
                        end
                    end

                    if show_debug_attack then
                        wesnoth.scroll_to_tile(target_loc[1], target_loc[2])
                        W.message { speaker = 'narrator', message = 'Attack combo ' .. count .. ': ' .. total_rating .. ' / ' .. (max_total_rating or 0) .. '    (pre-rating: ' .. combo.pre_rating .. ')' }
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
        function fred:get_hold_action(zone_cfg)
            if debug_eval then print_time('  --> hold evaluation: ' .. zone_cfg.zone_id) end

            local enemy_value_ratio = 1.25
            local max_units = 3
            local max_hexes = 6
            local enemy_leader_derating = FU.cfg_default('enemy_leader_derating')

            local raw_cfg = fred:get_raw_cfgs(zone_cfg.zone_id)
            --DBG.dbms(raw_cfg)
            --DBG.dbms(zone_cfg)

            local gamedata = fred.data.gamedata
            local move_cache = fred.data.move_cache

            -- Holders are those specified in zone_units, or all units except the leader otherwise
            local holders = {}
            if zone_cfg.zone_units then
                holders = zone_cfg.zone_units
            else
                for id,_ in pairs(gamedata.my_units_MP) do
                    if (not gamedata.unit_infos[id].canrecruit) then
                        holders[id] = FU.unit_base_power(gamedata.unit_infos[id])
                    end
                end
            end
            if (not next(holders)) then return end
            --DBG.dbms(holders)

            local protect_leader = zone_cfg.protect_leader
            --print('protect_leader', protect_leader)

            local zone
            if protect_leader then
                zone = wesnoth.get_locations {
                    { "and", raw_cfg.ops_slf },
                    { "or", { x = gamedata.leader_x, y = gamedata.leader_y, radius = 3 } }
                }
            else
                zone = wesnoth.get_locations(raw_cfg.ops_slf)
            end

            -- For what it is right now, the following could simply be included in the
            -- filter above. However, this opens up the option of including [avoid] tags
            -- or similar functionality later.
            local avoid_map = {}
            -- If the leader is to be protected, the leader location needs to be excluded
            -- from the hexes to consider, otherwise the check whether the leader is better
            -- protected by a hold doesn't work and causes the AI to crash.
            if protect_leader then
                FU.set_fgumap_value(avoid_map, gamedata.leader_x, gamedata.leader_y, 'flag', true)
            end

            local zone_map = {}
            for _,loc in ipairs(zone) do
                if (not FU.get_fgumap_value(avoid_map, loc[1], loc[2], 'flag')) then
                    FU.set_fgumap_value(zone_map, loc[1], loc[2], 'flag', true)
                end
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

                for x,y,_ in FU.fgumap_iter(zone_map) do
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
                --print('\n' .. id, zone_cfg.zone_id)

                for x,y,_ in FU.fgumap_iter(gamedata.unit_attack_maps[id]) do
                    local unit_influence = FU.unit_terrain_power(gamedata.unit_infos[id], x, y, gamedata)
                    local inf = FU.get_fgumap_value(holders_influence, x, y, 'my_influence', 0)
                    FU.set_fgumap_value(holders_influence, x, y, 'my_influence', inf + unit_influence)

                    local my_count = FU.get_fgumap_value(holders_influence, x, y, 'my_count', 0) + 1
                    FU.set_fgumap_value(holders_influence, x, y, 'my_count', my_count)


                    local enemy_influence = FU.get_fgumap_value(fred.data.turn_data.enemy_int_influence_map, x, y, 'enemy_influence', 0)

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

                    local weight = att.damage_counter.base_taken + att.damage_counter.extra_taken
                    -- TODO: there's no reason for the value of 0.5, other than that
                    -- we want to rate the enemy attack stronger than the AI unit attack
                    weight = weight - 0.5 * (att.damage_counter.base_done + att.damage_counter.extra_done)
                    if (weight < 1) then weight = 1 end

                    enemy_weights[id][enemy_id] = { weight = weight }
                end
            end
            --DBG.dbms(enemy_weights)


            -- TODO: in the end, this might be combined so that it can be dealt with
            -- in the same way. For now, it is intentionally kept separate.
            local min_btw_dist, perp_dist_weight
            local hold_leader_distance, protect_locs, assigned_enemies
            if protect_leader then
                local lx, ly = gamedata.leader_x, gamedata.leader_y
                local ld = FU.get_fgumap_value(gamedata.leader_distance_map, lx, ly, 'distance')
                hold_leader_distance = { min = ld, max = ld }
                protect_locs = { { lx, ly } }
                assigned_enemies = fred.data.ops_data.leader_threats.enemies
                min_btw_dist, perp_dist_weight = -1.001, 0.2
            else
                hold_leader_distance = fred.data.ops_data.protect_locs[zone_cfg.zone_id].hold_leader_distance
                protect_locs = fred.data.ops_data.protect_locs[zone_cfg.zone_id].locs
                min_btw_dist, perp_dist_weight = -2, 0.05
                assigned_enemies = fred.data.ops_data.assigned_enemies[zone_cfg.zone_id]
            end

            --DBG.dbms(assigned_enemies)

            local between_map
            if protect_locs and assigned_enemies then
                between_map = fred:get_between_map(protect_locs, assigned_enemies, gamedata, perp_dist_weight)

                if false then
                    FU.show_fgumap_with_message(between_map, 'distance', 'Between map: distance')
                    FU.show_fgumap_with_message(between_map, 'inv_cost', 'Between map: inv_cost')
                    --FU.show_fgumap_with_message(fred.data.gamedata.leader_distance_map, 'distance', 'leader distance')
                    --FU.show_fgumap_with_message(fred.data.gamedata.leader_distance_map, 'enemy_leader_distance', 'enemy_leader_distance')
                end
            end

            local leader = gamedata.leaders[wesnoth.current.side]
            local leader_on_keep = false
            if (wesnoth.get_terrain_info(wesnoth.get_terrain(leader[1], leader[2])).keep) then
                leader_on_keep = true
            end

            local pre_rating_maps = {}
            for id,_ in pairs(holders) do
                --print('\n' .. id, zone_cfg.zone_id)

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

                    -- Do not move the leader out of the way, if he's on a keep
                    -- TODO: this is duplicated below; better way of doing this?
                    local moves_leader_off_keep = false
                    if leader_on_keep and (id ~= leader.id) and (x == leader[1]) and (y == leader[2]) then
                        moves_leader_off_keep = true
                    end

                    -- TODO: probably want to us an actual move-distance map, rather than cartesian distances
                    if (not can_hit) and (not moves_leader_off_keep) then
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

                    -- Do not move the leader out of the way, if he's on a keep
                    -- TODO: this is duplicated above; better way of doing this?
                    if leader_on_keep and (id ~= leader.id) and (x == leader[1]) and (y == leader[2]) then
                        move_here = false
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

                                local damage_taken = factor_counter * (my_hc * att.damage_counter.base_taken + att.damage_counter.extra_taken)
                                damage_taken = damage_taken + factor_forward * (my_hc * att.damage_forward.base_taken + att.damage_forward.extra_taken)

                                local damage_done = factor_counter * (enemy_adj_hc * att.damage_counter.base_done + att.damage_counter.extra_taken)
                                damage_done = damage_done + factor_forward * (enemy_adj_hc * att.damage_forward.base_done + att.damage_forward.extra_taken)

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

                        frac_taken = frac_taken / gamedata.unit_infos[id].hitpoints
                        frac_taken = FU.weight_s(frac_taken, 0.5)
                        --if (frac_taken > 1) then frac_taken = 1 end
                        --if (frac_taken < 0) then frac_taken = 0 end
                        damage_taken = frac_taken * gamedata.unit_infos[id].hitpoints

                        -- TODO: that division by sqrt(n_enemies) is pretty adhoc; decide whether to change that
                        weighted_damage_taken = weighted_damage_taken * n_enemies - village_bonus - tmp_enemies[1].my_regen
                        local frac_taken = weighted_damage_taken / gamedata.unit_infos[id].hitpoints
                        frac_taken = FU.weight_s(frac_taken, 0.5)
                        --if (frac_taken > 1) then frac_taken = 1 end
                        --if (frac_taken < 0) then frac_taken = 0 end
                        weighted_damage_taken = frac_taken / n_enemies * gamedata.unit_infos[id].hitpoints


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

                            if between_map then
                                local btw_dist = FU.get_fgumap_value(between_map, x, y, 'distance', -99)
                                if (btw_dist < min_btw_dist) then
                                    hold_here = false
                                end
                            else
                                local ld = FU.get_fgumap_value(gamedata.leader_distance_map, x, y, 'distance')
                                local dld = ld - hold_leader_distance.min

                                -- TODO: this is likely too simplistic
                                if (dld < min_btw_dist) then
                                    hold_here = false
                                end
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
                --print('\n' .. id, zone_cfg.zone_id,hold_leader_distance.min .. ' -- ' .. hold_leader_distance.max)
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
                                print(id, enemy_id, x, y)
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
                        --print('    base_rating, rating2: ' .. base_rating, rating2, cum_weight)

                        -- TODO: the village bonuses are huge, check for better values?
                        if FU.get_fgumap_value(gamedata.village_map, x, y, 'owner') then
                            -- Prefer strongest unit on village (for protection)
                            -- TODO: we might want this condition on the threat to the village
                            rating2 = rating2 + 0.1 * gamedata.unit_infos[id].hitpoints / 25

                            -- For non-regenerating units, we also give a heal bonus
                            if (not gamedata.unit_infos[id].abilities.regenerate) then
                                rating2 = rating2 + 0.1 * 8 / 25
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

                            local dist
                            if between_map then
                                dist = FU.get_fgumap_value(between_map, x, y, 'inv_cost')
                            else
                                dist = - FU.get_fgumap_value(gamedata.leader_distance_map, x, y, 'enemy_leader_distance')
                            end

                            local forward_rating = (uncropped_ratio - 1) * 0.01 * dist
                            vuln_rating = vuln_rating + forward_rating
                            --print('uncropped_ratio', x, y, uncropped_ratio, dist, forward_rating)

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

                            local d_dist
                            if between_map then
                                d_dist = FU.get_fgumap_value(between_map, x, y, 'inv_cost')
                            else
                                local ld = FU.get_fgumap_value(gamedata.leader_distance_map, x, y, 'distance')
                                d_dist = ld - hold_leader_distance.max
                            end

                            -- TODO: this is likely too simplistic
                            if (d_dist > 2) then
                                protect_rating = protect_rating - (d_dist - 2) / 20
                            end

                            if (not protect_rating_maps[id]) then
                                protect_rating_maps[id] = {}
                            end

                            if protect_leader then
                                local mult = 0
                                local power_ratio = fred.data.ops_data.leader_threats.power_ratio
                                if (power_ratio < 1) then
                                    mult = (1 / power_ratio - 1)
                                end

                                protect_rating = protect_rating * (1 - mult * (d_dist / 100))
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
                hold_perpendicular = true,
                protect_leader = protect_leader
            }

            -- protect_locs is only set if there is a location to protect
            cfg_best_combo_hold.protect_locs = protect_locs
            cfg_best_combo_protect.protect_locs = protect_locs


            local best_hold_combo, hold_dst_src, hold_ratings
            if (next(hold_rating_maps)) then
                --print('--> checking hold combos')
                hold_dst_src, hold_ratings = FHU.unit_rating_maps_to_dstsrc(hold_rating_maps, 'vuln_rating', gamedata, cfg_combos)
                local hold_combos = FU.get_unit_hex_combos(hold_dst_src)
                --DBG.dbms(hold_combos)
                --print('#hold_combos', #hold_combos)

                best_hold_combo = FHU.find_best_combo(hold_combos, hold_ratings, 'vuln_rating', adjacent_village_map, between_map, gamedata, move_cache, cfg_best_combo_hold)
            end

            local best_protect_combo, unprotected_best_protect_combo, protect_dst_src, protect_ratings
            if hold_leader_distance then
                --print('--> checking protect combos')
                protect_dst_src, protect_ratings = FHU.unit_rating_maps_to_dstsrc(protect_rating_maps, 'protect_rating', gamedata, cfg_combos)
                local protect_combos = FU.get_unit_hex_combos(protect_dst_src)
                --DBG.dbms(protect_combos)
                --print('#protect_combos', #protect_combos)

                best_protect_combo, unprotected_best_protect_combo = FHU.find_best_combo(protect_combos, protect_ratings, 'protect_rating', adjacent_village_map, between_map, gamedata, move_cache, cfg_best_combo_protect)

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
                W.message { speaker = 'narrator', message = 'Best hold combo: '  .. max_rating }
                for src,dst in pairs(best_combo) do
                    x, y =  math.floor(dst / 1000), dst % 1000
                    W.label { x = x, y = y, text = "" }
                end
            end

            local action = {
                action_str = 'hold',
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
        function fred:get_advance_action(zone_cfg)
            -- Advancing is now only moving onto unthreatened hexes; everything
            -- else should be covered by holding, village grabbing, protecting, etc.

            if debug_eval then print_time('  --> advance evaluation: ' .. zone_cfg.zone_id) end

            --DBG.dbms(zone_cfg)
            local raw_cfg = fred:get_raw_cfgs(zone_cfg.zone_id)
            --DBG.dbms(raw_cfg)

            local gamedata = fred.data.gamedata
            local move_cache = fred.data.move_cache


            -- Advancers are those specified in zone_units, or all units except the leader otherwise
            local advancers = {}
            if zone_cfg.zone_units then
                advancers = zone_cfg.zone_units
            else
                for id,_ in pairs(gamedata.my_units_MP) do
                    if (not gamedata.unit_infos[id].canrecruit) then
                        advancers[id] = { gamedata.my_units[id][1], gamedata.my_units[id][2] }
                    end
                end
            end
            if (not next(advancers)) then return end

            -- advance_map covers all hexes in the zone which are not threatened by enemies
            local advance_map, zone_map = {}, {}
            local zone = wesnoth.get_locations(raw_cfg.ops_slf)
            for _,loc in ipairs(zone) do
                if (not FU.get_fgumap_value(gamedata.enemy_attack_map[1], loc[1], loc[2], 'ids')) then
                    FU.set_fgumap_value(advance_map, loc[1], loc[2], 'flag', true)
                end
                FU.set_fgumap_value(zone_map, loc[1], loc[2], 'flag', true)
            end
            if false then
                FU.show_fgumap_with_message(advance_map, 'flag', 'Advance map: ' .. zone_cfg.zone_id)
            end

            local safe_loc = false
            local unit_rating_maps = {}
            local max_rating, best_id, best_hex
            for id,unit_loc in pairs(advancers) do
                unit_rating_maps[id] = {}

                -- Fastest unit first, after that strongest unit first
                local rating_moves = gamedata.unit_infos[id].moves / 10
                local rating_power = FU.unit_current_power(gamedata.unit_infos[id]) / 1000

                -- If a village is involved, we prefer injured units
                local fraction_hp_missing = (gamedata.unit_infos[id].max_hitpoints - gamedata.unit_infos[id].hitpoints) / gamedata.unit_infos[id].max_hitpoints
                local hp_rating = FU.weight_s(fraction_hp_missing, 0.5)
                hp_rating = hp_rating * 10

                --print(id, rating_moves, rating_power, fraction_hp_missing, hp_rating)

                local cost_map
                for x,y,_ in FU.fgumap_iter(gamedata.reach_maps[id]) do
                    local rating = rating_moves + rating_power

                    local dist
                    if FU.get_fgumap_value(advance_map, x, y, 'flag') then
                        -- For unthreatened hexes in the zone, the main criterion is the "forward distance"
                        local ld1 = FU.get_fgumap_value(gamedata.leader_distance_map, x, y, 'enemy_leader_distance')
                        local ld2 = FU.get_fgumap_value(gamedata.enemy_leader_distance_maps[gamedata.unit_infos[id].type], x, y, 'cost')
                        dist = (ld1 + ld2) / 2
                    else
                        -- When no unthreatened hexes inside the zone can be found,
                        -- the enemy threat needs to be taken into account
                        if not cost_map then
                            cost_map = {}

                            local hexes = {}
                            -- Cannot just assign here, as we do not want to change the input tables later
                            if fred.data.ops_data.protect_locs[zone_cfg.zone_id]
                                and fred.data.ops_data.protect_locs[zone_cfg.zone_id].locs
                                and fred.data.ops_data.protect_locs[zone_cfg.zone_id].locs[1]
                            then
                                for _,loc in ipairs(fred.data.ops_data.protect_locs[zone_cfg.zone_id].locs) do
                                    table.insert(hexes, loc)
                                end
                            else
                                for _,loc in ipairs(raw_cfg.center_hexes) do
                                    table.insert(hexes, loc)
                                end
                            end

                            local include_leader_locs = false
                            if fred.data.ops_data.assigned_enemies[zone_cfg.zone_id] and fred.data.ops_data.leader_threats.enemies then
                                for enemy_id,_ in pairs(fred.data.ops_data.assigned_enemies[zone_cfg.zone_id]) do
                                    if fred.data.ops_data.leader_threats.enemies[enemy_id] then
                                        include_leader_locs = true
                                        break
                                    end
                                end
                            end
                            if include_leader_locs then
                                for _,loc in ipairs(fred.data.ops_data.leader_threats.protect_locs) do
                                    table.insert(hexes, loc)
                                end
                            end

                            for _,hex in ipairs(hexes) do
                                local cm = wesnoth.find_cost_map(
                                    { x = -1 }, -- SUF not matching any unit
                                    { { hex[1], hex[2], wesnoth.current.side, fred.data.gamedata.unit_infos[id].type } },
                                    { ignore_units = true }
                                )

                                for _,cost in pairs(cm) do
                                    if (cost[3] > -1) then
                                       local c = FU.get_fgumap_value(cost_map, cost[1], cost[2], 'cost', 0)
                                       FU.set_fgumap_value(cost_map, cost[1], cost[2], 'cost', c + cost[3])
                                    end
                                end
                            end
                            if false then
                                FU.show_fgumap_with_message(cost_map, 'cost', 'cost_map')
                            end
                        end

                        dist = FU.get_fgumap_value(cost_map, x, y, 'cost')

                        -- Counter attack outcome
                        local unit_moved = {}
                        unit_moved[id] = { x, y }
                        local old_locs = { { unit_loc[1], unit_loc[2] } }
                        local new_locs = { { x, y } }
                        local counter_outcomes = FAU.calc_counter_attack(
                            unit_moved, old_locs, new_locs, gamedata, move_cache
                        )
                        --DBG.dbms(counter_outcomes.def_outcome.ctd_progression)
                        --print('  die_chance', counter_outcomes.def_outcome.hp_chance[0])

                        if counter_outcomes then
                            local counter_rating = - counter_outcomes.rating_table.rating
                            counter_rating = counter_rating / FU.unit_value(gamedata.unit_infos[id])
                            counter_rating = 2 * counter_rating * gamedata.unit_infos[id].max_moves

                            -- The die chance is already included in the rating, but we
                            -- want it to have even more importance here
                            local die_rating = - counter_outcomes.def_outcome.hp_chance[0]
                            die_rating = 2 * die_rating * gamedata.unit_infos[id].max_moves

                            rating = rating + counter_rating + die_rating
                        end

                        if (not counter_outcomes) or (counter_outcomes.def_outcome.hp_chance[0] < 0.85) then
                            safe_loc = true
                        end

                        -- Do not do this unless there is no unthreatened hex in the zone
                        rating = rating - 1000
                    end

                    local rating = rating - dist

                    -- Small preference for villages we don't own (although this
                    -- should mostly be covered by the village grabbing action already)
                    local owner = FU.get_fgumap_value(gamedata.village_map, x, y, 'owner')
                    if owner and (owner ~= wesnoth.current.side) then
                        if (owner == 0) then
                            rating = rating + 1
                        else
                            rating = rating + 2
                        end
                    end

                    -- Somewhat larger preference for villages for injured units
                    if owner and (not gamedata.unit_infos[id].abilities.regenerate) then
                        rating = rating + hp_rating
                    end

                    -- Small bonus for the terrain; this does not really matter for
                    -- unthreatened hexes and is already taken into account in the
                    -- counter attack calculation for others. Just a tie breaker.
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
            --print('best unit: ' .. best_id, best_hex[1], best_hex[2])

            if false then
                for id,unit_rating_map in pairs(unit_rating_maps) do
                    FU.show_fgumap_with_message(unit_rating_map, 'rating', 'Unit rating', gamedata.unit_copies[id])
                end
            end


            -- If no safe location is found, check for desparate attack
            local best_target, best_weapons, action_str
            if (not safe_loc) then
                --print('----- no safe advance location found -----')

                local cfg_attack = {
                    value_ratio = 0.2, -- mostly based on damage done to enemy
                    use_max_damage_weapons = true
                }

                local max_attack_rating, best_attacker_id, best_attack_hex
                for id,unit_loc in pairs(advancers) do
                    --print('checking desparate attacks for ' .. id)

                    local attacker = {}
                    attacker[id] = unit_loc
                    for enemy_id,enemy_loc in pairs(gamedata.enemies) do
                        if FU.get_fgumap_value(gamedata.unit_attack_maps[id], enemy_loc[1], enemy_loc[2], 'current_power') then
                            --print('    potential target:' .. enemy_id)

                            local target = {}
                            target[enemy_id] = enemy_loc
                            local attack_combos = FAU.get_attack_combos(
                                attacker, target, gamedata.reach_maps, false, move_cache, cfg_attack
                            )

                            for _,combo in ipairs(attack_combos) do
                                local combo_outcome = FAU.attack_combo_eval(combo, target, gamedata, move_cache, cfg_attack)
                                --print(next(combo))
                                --DBG.dbms(combo_outcome.rating_table)

                                local do_attack = true

                                -- Don't attack if chance of leveling up the enemy is higher than the kill chance
                                if (combo_outcome.def_outcome.levelup_chance > combo_outcome.def_outcome.hp_chance[0]) then
                                    do_attack = false
                                end

                                -- If there's no chance to kill the enemy, don't do the attack if it ...
                                if do_attack and (combo_outcome.def_outcome.hp_chance[0] == 0) then
                                    local unit_level = gamedata.unit_infos[id].level
                                    local enemy_dxp = gamedata.unit_infos[enemy_id].max_experience - gamedata.unit_infos[enemy_id].experience

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

                                if do_attack and ((not max_attack_rating) or (combo_outcome.rating_table.rating > max_attack_rating)) then
                                    max_attack_rating = combo_outcome.rating_table.rating
                                    best_attacker_id = id
                                    local _, dst = next(combo)
                                    best_attack_hex = { math.floor(dst / 1000), dst % 1000 }
                                    best_target = {}
                                    best_target[enemy_id] = enemy_loc
                                    best_weapons = combo_outcome.att_weapons_i
                                    action_str = 'desperate attack'
                                end
                            end
                        end
                    end
                end
                if best_attacker_id then
                    --print('best desparate attack: ' .. best_attacker_id, best_attack_hex[1], best_attack_hex[2], next(best_target))
                    best_id = best_attacker_id
                    best_hex = best_attack_hex
                end
            end


            if best_id then
                FU.print_debug(show_debug_advance, '  best advance:', best_id, best_hex[1], best_hex[2])

                local best_unit = gamedata.my_units[best_id]
                best_unit.id = best_id

                local action = {
                    units = { best_unit },
                    dsts = { best_hex },
                    enemy = best_target,
                    weapons = best_weapons,
                    action_str = action_str or 'advance'
                }
                return action
            end
        end


        ----- Retreat: -----
        function fred:get_retreat_action(zone_cfg)
            if debug_eval then print_time('  --> retreat evaluation: ' .. zone_cfg.zone_id) end

            local gamedata = fred.data.gamedata
            local retreat_utilities = FU.retreat_utilities(gamedata)
            local retreat_combo = R.find_best_retreat(zone_cfg.retreaters, retreat_utilities, fred.data.turn_data.unit_attacks, gamedata)

            if retreat_combo then
                local action = {
                    units = {},
                    dsts = {},
                    action_str = 'retreat'
                }

                for src,dst in pairs(retreat_combo) do
                    local src_x, src_y = math.floor(src / 1000), src % 1000
                    local dst_x, dst_y = math.floor(dst / 1000), dst % 1000
                    local unit = { src_x, src_y, id = gamedata.my_unit_map[src_x][src_y].id }
                    table.insert(action.units, unit)
                    table.insert(action.dsts, { dst_x, dst_y })
                end

                return action
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
            local leveled_units
            for id,_ in pairs(fred.data.gamedata.units) do
                local unit_side = fred.data.gamedata.unit_infos[id].side
                if (not sides[unit_side]) then sides[unit_side] = {} end

                sides[unit_side].num_units = (sides[unit_side].num_units or 0) + 1
                sides[unit_side].hitpoints = (sides[unit_side].hitpoints or 0) + fred.data.gamedata.unit_infos[id].hitpoints

                if fred.data.gamedata.unit_infos[id].canrecruit then
                    sides[unit_side].leader_type = fred.data.gamedata.unit_copies[id].type
                else
                    if (unit_side == wesnoth.current.side) and (fred.data.gamedata.unit_infos[id].level > 1) then
                        if (not leveled_units) then leveled_units = '' end
                        leveled_units = leveled_units
                            .. fred.data.gamedata.unit_infos[id].type .. ' ('
                            .. fred.data.gamedata.unit_infos[id].hitpoints .. '/' .. fred.data.gamedata.unit_infos[id].max_hitpoints .. ')  '
                    end
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

            if leveled_units then print('    Leveled units: ' .. leveled_units) end

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
                            action_str = 'move leader to keep',
                            partial_move = true
                        }

                        return score, action, next_hop, best_keep
                    else
                        return low_score, nil, next_hop, best_keep
                    end
                end
            end

            AH.done_eval_messages(start_time, ca_name)
            return 0
        end

        function fred:move_leader_to_keep_exec()
            if debug_exec then print_time('=> exec: move_leader_to_keep CA') end
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

        local params = { score_function = function () return 181000 end }
        wesnoth.require("~add-ons/AI-demos/lua/generic_recruit_engine.lua").init(ai, fred, params)


        ----- CA: Zone control (max_score: 350000) -----
        -- TODO: rename?
        function fred:get_zone_action(cfg)
            -- Find the best action to do in the zone described in 'cfg'
            -- This is all done together in one function, rather than in separate CAs so that
            --  1. Zones get done one at a time (rather than one CA at a time)
            --  2. Relative scoring of different types of moves is possible

            -- **** Retreat severely injured units evaluation ****
            if (cfg.action_type == 'retreat') then
                --print_time('  ' .. cfg.zone_id .. ': retreat_injured eval')
                -- TODO: heal_loc and safe_loc are not used at this time
                -- keep for now and see later if needed
                local action = fred:get_retreat_action(cfg)
                if action then
                    --print(action.action_str)
                    return action
                end
            end

            -- **** Attack evaluation ****
            if (cfg.action_type == 'attack') then
                --print_time('  ' .. cfg.zone_id .. ': attack eval')
                local action = fred:get_attack_action(cfg)
                if action then
                    --print(action.action_str)
                    return action
                end
            end

            -- **** Hold position evaluation ****
            if (cfg.action_type == 'hold') then
                --print_time('  ' .. cfg.zone_id .. ': hold eval')
                local action = fred:get_hold_action(cfg)
                if action then
                    --print_time(action.action_str)
                    return action
                end
            end

            -- **** Advance in zone evaluation ****
            if (cfg.action_type == 'advance') then
                --print_time('  ' .. cfg.zone_id .. ': advance eval')
                local action = fred:get_advance_action(cfg)
                if action then
                    --print_time(action.action_str)
                    return action
                end
            end

            -- **** Force leader to go to keep if needed ****
            -- TODO: This should be consolidated at some point into one
            -- CA, but for simplicity we keep it like this for now until
            -- we know whether it works as desired
            if (cfg.action_type == 'move_leader_to_keep') then
                --print_time('  ' .. cfg.zone_id .. ': move_leader_to_keep eval')
                local score, action = fred:move_leader_to_keep_eval(true)
                if action then
                    --print_time(action.action_str)
                    return action
                end
            end

            -- **** Recruit evaluation ****
            -- TODO: does it make sense to keep this also as a separate CA?
            if (cfg.action_type == 'recruit') then
                --print_time('  ' .. cfg.zone_id .. ': recruit eval')
                -- Important: we cannot check recruiting here, as the units
                -- are taken off the map at this time, so it needs to be checked
                -- by the function setting up the cfg
                local action = {
                    action_str = 'recruit',
                    type = 'recruit',
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
--fred.data.turn_data = nil

            if (not fred.data.turn_data)
                or (fred.data.turn_data.turn_number ~= wesnoth.current.turn)
            then
                fred:set_turn_data()
                fred:set_ops_data()
            else
                fred:update_ops_data()
            end



            fred:get_action_cfgs()
            --DBG.dbms(fred.data.zone_cfgs)

            for i_c,cfg in ipairs(fred.data.zone_cfgs) do
                --DBG.dbms(cfg)


                -- Execute any actions with an 'action' table already set right away.
                -- We first need to validate that the existing actions are still doable
                -- This is needed because individual actions might interfere with each other
                -- We also delete executed actions here; it cannot be done right after setting
                -- up the eval table, as not all action get executed right away by the
                -- execution code (e.g. if an action involves the leader and recruiting has not
                -- yet happened)
                if cfg.action then
                    if (not cfg.invalid) then
                        local is_good = true

                        if (cfg.action.type == 'recruit') then
                            is_good = false
                            -- All the recruiting is done in one call to exec, so
                            -- we simply check here if any one of the recruiting is possible

                            local leader = fred.data.gamedata.leaders[wesnoth.current.side]
                            if (wesnoth.get_terrain_info(wesnoth.get_terrain(leader[1], leader[2])).keep) then
                                for _,recruit_unit in ipairs(cfg.action.recruit_units) do
                                    --print('  ' .. recruit_unit.recruit_type .. ' at ' .. recruit_unit.recruit_hex[1] .. ',' .. recruit_unit.recruit_hex[2])
                                    local uiw = wesnoth.get_unit(recruit_unit.recruit_hex[1], recruit_unit.recruit_hex[2])
                                    if (not uiw) then
                                        -- If there is no unit in the way, we're good
                                        is_good = true
                                        break
                                    else
                                        -- Otherwise we check whether it has an empty hex to move to
                                        for x,y,_ in FU.fgumap_iter(fred.data.gamedata.reach_maps[uiw.id]) do
                                            if (not FU.get_fgumap_value(fred.data.gamedata.my_unit_map, x, y, 'id')) then
                                               is_good = true
                                               break
                                            end
                                        end
                                        if is_good then break end
                                    end
                                end
                            end
                        else
                            for _,u in ipairs(cfg.action.units) do
                                local unit = wesnoth.get_units { id = u.id }[1]
                                --print(unit.id, unit.x, unit.y)

                                if (not unit) or ((unit.x == cfg.action.dsts[1][1]) and (unit.y == cfg.action.dsts[1][2])) then
                                    is_good = false
                                    break
                                end

                                local _, cost = wesnoth.find_path(unit, cfg.action.dsts[1][1], cfg.action.dsts[1][2])
                                --print(cost)

                                if (cost > unit.moves) then
                                    is_good = false
                                    break
                                end
                            end

                            if (#cfg.action.units == 0) then
                                is_good = false
                            end
                            --print('is_good:', is_good)
                        end

                        if is_good then
                            --print('  Pre-evaluated action found: ' .. cfg.action.action_str)
                            fred.data.zone_action = AH.table_copy(cfg.action)
                            AH.done_eval_messages(start_time, ca_name)
                            return score_zone_control
                        else
                            cfg.invalid = true
                        end
                    end
                else
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
                        --DBG.dbms(zone_action)
                        fred.data.zone_action = zone_action
                        AH.done_eval_messages(start_time, ca_name)
                        return score_zone_control
                    end
                end
            end

            if debug_eval then print('--> done with all cfgs') end

            AH.done_eval_messages(start_time, ca_name)
            return 0
        end

        function fred:zone_control_exec()
            local action = fred.data.zone_action.zone_id .. ': ' .. fred.data.zone_action.action_str
            --DBG.dbms(fred.data.zone_action)


            -- If recruiting is set, we just do that, nothing else needs to be checked:
            if (fred.data.zone_action.type == 'recruit') then
                if debug_exec then print_time('=> exec: ' .. action) end
                if AH.show_messages() then W.message { speaker = unit.id, message = 'Zone action ' .. action } end

                if fred.data.zone_action.recruit_units then
                    --print('Recruiting pre-evaluated units')
                    for _,recruit_unit in ipairs(fred.data.zone_action.recruit_units) do
                        --print('  ' .. recruit_unit.recruit_type .. ' at ' .. recruit_unit.recruit_hex[1] .. ',' .. recruit_unit.recruit_hex[2])
                        local uiw = wesnoth.get_unit(recruit_unit.recruit_hex[1], recruit_unit.recruit_hex[2])
                        if uiw then
                            -- Generally, move out of way in direction of own leader
                            local leader_loc = fred.data.gamedata.leaders[wesnoth.current.side]
                            local dx, dy  = leader_loc[1] - recruit_unit.recruit_hex[1], leader_loc[2] - recruit_unit.recruit_hex[2]
                            local r = math.sqrt(dx * dx + dy * dy)
                            if (r ~= 0) then dx, dy = dx / r, dy / r end

                            --print('    uiw: ' .. uiw.id)
                            AH.move_unit_out_of_way(ai, uiw, { dx = dx, dy = dy })

                            -- Make sure the unit really is gone now
                            uiw = wesnoth.get_unit(recruit_unit.recruit_hex[1], recruit_unit.recruit_hex[2])
                        end

                        if (not uiw) then
                            AH.checked_recruit(ai, recruit_unit.recruit_type, recruit_unit.recruit_hex[1], recruit_unit.recruit_hex[2])
                        end
                    end
                else
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
                            --    action = fred.data.zone_action.action_str or 'other'
                            --}
                        end
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

                -- If this is an attack combo, reorder units to
                --   - Use unit with best rating
                --   - Maximize chance of leveling up
                --   - Give maximum XP to unit closest to advancing
                if enemy_proxy and fred.data.zone_action.units[2] then
                    local attacker_copies, attacker_infos = {}, {}
                    local combo = {}
                    for i,unit in ipairs(fred.data.zone_action.units) do
                        table.insert(attacker_copies, fred.data.gamedata.unit_copies[unit.id])
                        table.insert(attacker_infos, fred.data.gamedata.unit_infos[unit.id])

                        combo[unit[1] * 1000 + unit[2]] = fred.data.zone_action.dsts[i][1] * 1000 + fred.data.zone_action.dsts[i][2]
                    end

                    local defender_info = fred.data.gamedata.unit_infos[enemy_proxy.id]

                    local cfg_attack = { use_max_damage_weapons = true }
                    local combo_outcome = FAU.attack_combo_eval(combo, fred.data.zone_action.enemy, fred.data.gamedata, fred.data.move_cache, cfg_attack)
                    --print('\noverall kill chance: ', combo_outcome.defender_damage.die_chance)

                    local enemy_level = defender_info.level
                    if (enemy_level == 0) then enemy_level = 0.5 end
                    --print('enemy level', enemy_level)

                    -- Check if any unit has a chance to level up
                    local levelups = { anybody = false }
                    for ind,unit in ipairs(fred.data.zone_action.units) do
                        local unit_info = fred.data.gamedata.unit_infos[unit.id]
                        local XP_diff = unit_info.max_experience - unit_info.experience

                        local levelup_possible, levelup_certain = false, false
                        if (XP_diff <= enemy_level) then
                            levelup_certain = true
                            levelups.anybody = true
                        elseif (XP_diff <= enemy_level * 8) then
                            levelup_possible = true
                            levelups.anybody = true
                        end
                        --print('  ' .. unit_info.id, XP_diff, levelup_possible, levelup_certain)

                        levelups[ind] = { certain = levelup_certain, possible = levelup_possible}
                    end
                    --DBG.dbms(levelups)


                    --print_time('Reordering units for attack')
                    local max_rating
                    for ind,unit in ipairs(fred.data.zone_action.units) do
                        local unit_info = fred.data.gamedata.unit_infos[unit.id]

                        local att_outcome, def_outcome = FAU.attack_outcome(
                            attacker_copies[ind], enemy_proxy,
                            fred.data.zone_action.dsts[ind],
                            attacker_infos[ind], defender_info,
                            fred.data.gamedata, fred.data.move_cache, cfg_attack
                        )
                        local rating_table, att_damage, def_damage =
                            FAU.attack_rating({ unit_info }, defender_info, { fred.data.zone_action.dsts[ind] }, { att_outcome }, def_outcome, fred.data.gamedata)

                        -- The base rating is the individual attack rating
                        local rating = rating_table.rating
                        --print('  base_rating ' .. unit_info.id, rating)

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
                                    -- Want most advanced and least valuable  unit to go last
                                    extra_rating = 90 * utility + XP_diff / 10
                                    extra_rating = extra_rating - att_damage[1].unit_value / 100
                                end
                                --print('    levelup utility', utility)
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
                                --print('      ' .. xp_fraction, def_outcome.hp_chance[0])
                                --print('      ' .. x, y, utility)

                                extra_rating = 10 * utility * (1 - att_outcome.hp_chance[0])^2

                                -- Also want most valuable unit to go first
                                extra_rating = extra_rating + att_damage[1].unit_value / 1000
                                --print('    XP gain utility', utility)
                            end

                            rating = rating + extra_rating
                            --print('    rating', rating)
                        end

                        if (not max_rating) or (rating > max_rating) then
                            max_rating, next_unit_ind = rating, ind
                        end
                    end
                    --print_time('Best unit to go next:', fred.data.zone_action.units[next_unit_ind].id, max_rating, next_unit_ind)
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

                if debug_exec then print_time('=> exec: ' .. action) end
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
                            --print('  unit is part of the combo', unit_in_way.id, unit_in_way.x, unit_in_way.y)
                            local path, _ = wesnoth.find_path(unit_in_way, fred.data.zone_action.dsts[i_u][1], fred.data.zone_action.dsts[i_u][2])

                            -- If we can find an unoccupied hex along the path, move the
                            -- unit_in_way there, in order to maximize the chances of it
                            -- making it to its goal. However, do not move all the way and
                            -- do partial move only, in case something changes as result of
                            -- the original unit's action.
                            local moveto
                            for i = 2,#path do
                                local uiw_uiw = wesnoth.get_unit(path[i][1], path[i][2])
                                if (not uiw_uiw) then
                                    moveto = { path[i][1], path[i][2] }
                                    break
                                end
                            end

                            if moveto then
                                --print('    ' .. unit_in_way.id .. ': moving out of way to:', moveto[1], moveto[2])
                                AH.checked_move(ai, unit_in_way, moveto[1], moveto[2])
                            else
                                dx, dy = path[2][1] - path[1][1], path[2][2] - path[1][2]
                                local r = math.sqrt(dx * dx + dy * dy)
                                if (r ~= 0) then dx, dy = dx / r, dy / r end
                            end

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
                    local weapon = fred.data.zone_action.weapons[next_unit_ind]
                    table.remove(fred.data.zone_action.weapons, next_unit_ind)

                    AH.checked_attack(ai, unit, enemy_proxy, weapon)

                    -- If enemy got killed, we need to stop here
                    if (not enemy_proxy.valid) then
                        fred.data.zone_action.units = nil
                    end

                    -- Need to reset the enemy information if there are more attacks in this combo
                    if fred.data.zone_action.units and fred.data.zone_action.units[1] then
                        fred.data.gamedata.unit_copies[enemy_proxy.id] = wesnoth.copy_unit(enemy_proxy)
                        fred.data.gamedata.unit_infos[enemy_proxy.id] = FU.single_unit_info(enemy_proxy)
                    end
                end

                -- Add units_used to status table
                if unit and unit.valid then
                --    fred.data.analysis.status.units_used[unit.id] = {
                --        zone_id = fred.data.zone_action.zone_id or 'other',
                --        action = fred.data.zone_action.action_str or 'other'
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
            if debug_exec then print_time('=> exec: remove_MP CA') end

            local id,loc = next(fred.data.gamedata.my_units_MP)

            AH.checked_stopunit_moves(ai, fred.data.gamedata.unit_copies[id])
        end


        return fred
    end
}
