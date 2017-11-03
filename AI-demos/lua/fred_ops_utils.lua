local H = wesnoth.require "lua/helper.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local FGUI = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_gamestate_utils_incremental.lua"
local FAU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack_utils.lua"
local FSC = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_scenario_cfg.lua"
local FVU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_village_utils.lua"
local FHU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_hold_utils.lua"
local FMLU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_move_leader_utils.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local fred_ops_utils = {}

function fred_ops_utils.replace_zones(assigned_units, assigned_enemies, protect_locs, actions)
    -- Combine several zones into one, if the conditions for it are met.
    -- For example, on Freelands the 'east' and 'center' zones are combined
    -- into the 'top' zone if enemies are close enough to the leader.
    --
    -- TODO: not sure whether it is better to do this earlier
    -- TODO: set this up to be configurable by the cfgs
    local replace_zone_ids = FSC.replace_zone_ids()
    local raw_cfgs_main = FSC.get_raw_cfgs()
    local raw_cfg_new = FSC.get_raw_cfgs(replace_zone_ids.new)
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
    --print('replace_zones', replace_zones)

    if replace_zones then
        actions.hold_zones[raw_cfg_new.zone_id] = true

        for _,zone_id in ipairs(replace_zone_ids.old) do
            actions.hold_zones[zone_id] = nil
        end

        -- Also combine assigned_units, assigned_enemies, protect_locs
        -- from the zones to be replaced. We don't actually replace the
        -- respective tables for those zones, just add those for the super zone,
        -- because advancing still uses the original zones
        assigned_units[raw_cfg_new.zone_id] = {}
        assigned_enemies[raw_cfg_new.zone_id] = {}
        protect_locs[raw_cfg_new.zone_id] = {}

        local hld_min, hld_max
        for _,zone_id in ipairs(replace_zone_ids.old) do
            for id,loc in pairs(assigned_units[zone_id] or {}) do
                assigned_units[raw_cfg_new.zone_id][id] = loc
            end
            for id,loc in pairs(assigned_enemies[zone_id] or {}) do
                assigned_enemies[raw_cfg_new.zone_id][id] = loc
            end

            if protect_locs[zone_id].locs then
                for _,loc in ipairs(protect_locs[zone_id].locs) do
                    if (not protect_locs[raw_cfg_new.zone_id].locs) then
                        protect_locs[raw_cfg_new.zone_id].locs = {}
                    end
                    table.insert(protect_locs[raw_cfg_new.zone_id].locs, loc)
                end
                if (not hld_min) or (protect_locs[zone_id].leader_distance.min < hld_min) then
                    hld_min = protect_locs[zone_id].leader_distance.min
                end
                if (not hld_max) or (protect_locs[zone_id].leader_distance.max > hld_max) then
                    hld_max = protect_locs[zone_id].leader_distance.max
                end
            end
        end
        if hld_min then
            protect_locs[raw_cfg_new.zone_id].leader_distance = {
                min = hld_min, max = hld_max
            }
        end
    end
end


function fred_ops_utils.calc_power_stats(zones, assigned_units, assigned_enemies, assigned_recruits, gamedata)
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


function fred_ops_utils.assess_leader_threats(leader_threats, protect_locs, leader_proxy, raw_cfgs_main, side_cfgs, gamedata, move_cache)
    -- Threat are all enemies that can attack the castle or any of the protect_locations
    leader_threats.enemies = {}
    for x,y,_ in FU.fgumap_iter(gamedata.reachable_castles_map[wesnoth.current.side]) do
        local ids = FU.get_fgumap_value(gamedata.enemy_attack_map[1], x, y, 'ids') or {}
        for _,id in ipairs(ids) do
            leader_threats.enemies[id] = gamedata.units[id]
        end
    end
    for _,loc in ipairs(leader_threats.protect_locs) do
        local ids = FU.get_fgumap_value(gamedata.enemy_attack_map[1], loc[1], loc[2], 'ids') or {}
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
        if protect_locs[zone_id].leader_distance then
            hold_ld = protect_locs[zone_id].leader_distance.max
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
            gamedata, move_cache
        )
        --DBG.dbms(att_outcome)
        --DBG.dbms(def_outcome)

        local max_loss = leader_proxy.hitpoints - def_outcome.min_hp
        local av_loss = leader_proxy.hitpoints - def_outcome.average_hp
        --print('    ', id, av_loss, max_loss)

        max_total_loss = max_total_loss + max_loss
        av_total_loss = av_total_loss + av_loss
    end
    DBG.print_debug('analysis', '\nleader: max_total_loss, av_total_loss', max_total_loss, av_total_loss)

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
    DBG.print_debug('analysis', '  significant_threat', leader_threats.significant_threat)

    -- Only count leader threats if they are significant
    if (not leader_threats.significant_threat) then
        leader_threats.enemies = nil
    end

    local power_stats = fred_ops_utils.calc_power_stats({}, {}, {}, {}, gamedata)
    --DBG.dbms(power_stats)

    leader_threats.power_ratio = power_stats.total.ratio

    --DBG.dbms(leader_threats)
end


function fred_ops_utils.set_turn_data(gamedata)
    DBG.print_debug('analysis', '\n------------- Setting the turn_data table:')

    -- Get the needed cfgs
    local side_cfgs = FSC.get_side_cfgs()

    if false then
        --DBG.show_fgumap_with_message(gamedata.leader_distance_map, 'my_leader_distance', 'my_leader_distance')
        DBG.show_fgumap_with_message(gamedata.leader_distance_map, 'enemy_leader_distance', 'enemy_leader_distance')
        DBG.show_fgumap_with_message(gamedata.leader_distance_map, 'distance', 'leader_distance_map')
        --DBG.show_fgumap_with_message(gamedata.enemy_leader_distance_maps['Orcish Grunt'], 'cost', 'cost Grunt')
        --DBG.show_fgumap_with_message(gamedata.enemy_leader_distance_maps['Wolf Rider'], 'cost', 'cost Wolf Rider')
    end


    local leader_derating = FU.cfg_default('leader_derating')

    local influence_maps = {}
    for x,y,data in FU.fgumap_iter(gamedata.my_attack_map[1]) do
        local my_influence, my_number = 0, 0
        for _,id in pairs(data.ids) do
            local unit_influence = FU.unit_terrain_power(gamedata.unit_infos[id], x, y, gamedata)
            if gamedata.unit_infos[id].canrecruit then
                unit_influence = unit_influence * leader_derating
            end
            my_influence = my_influence + unit_influence
            my_number = my_number + 1
        end
        FU.set_fgumap_value(influence_maps, x, y, 'my_influence', my_influence)
        influence_maps[x][y].my_number = my_number
    end

    for x,y,data in FU.fgumap_iter(gamedata.enemy_attack_map[1]) do
        local enemy_influence, enemy_number = 0, 0
        for _,enemy_id in pairs(data.ids) do
            local unit_influence = FU.unit_terrain_power(gamedata.unit_infos[enemy_id], x, y, gamedata)
            if gamedata.unit_infos[enemy_id].canrecruit then
                unit_influence = unit_influence * leader_derating
            end
            enemy_influence = enemy_influence + unit_influence
            enemy_number = enemy_number + 1
        end
        FU.set_fgumap_value(influence_maps, x, y, 'enemy_influence', enemy_influence)
        influence_maps[x][y].enemy_number = enemy_number
    end

    for x,y,data in FU.fgumap_iter(influence_maps) do
        data.influence = (data.my_influence or 0) - (data.enemy_influence or 0)
        data.tension = (data.my_influence or 0) + (data.enemy_influence or 0)
        data.vulnerability = data.tension - math.abs(data.influence)
    end

    if false then
        --DBG.show_fgumap_with_message(influence_maps, 'my_influence', 'My integer influence map')
        --DBG.show_fgumap_with_message(influence_maps, 'my_number', 'My number')
        --DBG.show_fgumap_with_message(influence_maps, 'enemy_influence', 'Enemy integer influence map')
        --DBG.show_fgumap_with_message(influence_maps, 'enemy_number', 'Enemy number')
        DBG.show_fgumap_with_message(influence_maps, 'influence', 'Influence map')
        DBG.show_fgumap_with_message(influence_maps, 'tension', 'Tension map')
        DBG.show_fgumap_with_message(influence_maps, 'vulnerability', 'Vulnerability map')
    end


    local my_total_influence, enemy_total_influence = 0, 0
    for id,_ in pairs(gamedata.units) do
        local unit_influence = FU.unit_current_power(gamedata.unit_infos[id])
        if gamedata.unit_infos[id].canrecruit then
            unit_influence = unit_influence * leader_derating
        end
        --print(id, unit_influence)

        if (gamedata.unit_infos[id].side == wesnoth.current.side) then
            my_total_influence = my_total_influence + unit_influence
        else
            enemy_total_influence = enemy_total_influence + unit_influence
        end
    end

    local value_ratio = FU.cfg_default('value_ratio')
    local ratio = enemy_total_influence / my_total_influence
    if (ratio < 1) then
        value_ratio = ratio * value_ratio
    end

    local behavior = {
        influence = {
            my = my_total_influence,
            enemy = enemy_total_influence,
            value_ratio = value_ratio
        }
    }


    local n_vill_my, n_vill_enemy, n_vill_unowned, n_vill_total = 0, 0, 0, 0
    for x,y,data in FU.fgumap_iter(gamedata.village_map) do
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
        n_total = n_vill_total,
        ratio = n_vill_my / n_vill_total
    }


    local raw_cfgs_main = FSC.get_raw_cfgs()
    behavior.fronts = { zones = {} }

    -- Calculate where the fronts are in the zones (in leader_distance values)
    -- based on a vulnerability-weighted sum over the zones
    for zone_id,raw_cfg in pairs(raw_cfgs_main) do
        local zone = wesnoth.get_locations(raw_cfg.ops_slf)
        local num, denom = 0, 0
        for _,loc in ipairs(zone) do
            local vulnerability = FU.get_fgumap_value(influence_maps, loc[1], loc[2], 'vulnerability')
            if vulnerability then
                local ld = FU.get_fgumap_value(gamedata.leader_distance_map, loc[1], loc[2], 'distance')
                num = num + vulnerability^2 * ld
                denom = denom + vulnerability^2
            end
        end
        local ld_max = num / denom
        --print(zone_id, ld_max)
        behavior.fronts.zones[zone_id] = ld_max
    end

    --DBG.dbms(behavior)


    -- Find the unit-vs-unit ratings
    -- TODO: can functions in attack_utils be used for this?
    -- Extract all AI units
    --   - because no two units on the map can have the same underlying_id
    --   - so that we do not accidentally overwrite a unit
    --   - so that we don't accidentally apply leadership, backstab or the like
    local extracted_units = {}
    for id,loc in pairs(gamedata.units) do
        local unit_proxy = wesnoth.get_unit(loc[1], loc[2])
        wesnoth.extract_unit(unit_proxy)
        table.insert(extracted_units, unit_proxy)  -- Not a proxy unit any more at this point
    end

    -- Find the effectiveness of each AI unit vs. each enemy unit
    local attack_locs = FSC.get_attack_test_locs()

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

    local turn_data = {
        turn_number = wesnoth.current.turn,
        influence_maps = influence_maps,
        unit_attacks = unit_attacks,
        behavior = behavior
    }

    return turn_data
end


function fred_ops_utils.set_ops_data(fred_data, fred_recruit)
    DBG.print_debug('analysis', '\n------------- Setting the turn_data table:')

    -- Get the needed cfgs
    local gamedata = fred_data.gamedata
    local raw_cfgs_main = FSC.get_raw_cfgs()
    local side_cfgs = FSC.get_side_cfgs()


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
    for x,y,_ in FU.fgumap_iter(gamedata.reachable_keeps_map[wesnoth.current.side]) do
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
        DBG.print_debug('analysis', 'closest keep: ' .. closest_keep[1] .. ',' .. closest_keep[2])
    else
        local _, _, next_hop, best_keep_for_hop = FMLU.move_eval(true, fred_data)
        leader_threats.leader_locs.next_hop = next_hop
        leader_threats.leader_locs.best_keep_for_hop = best_keep_for_hop
        table.insert(leader_threats.protect_locs, next_hop)
        table.insert(leader_threats.protect_locs, best_keep_for_hop)
        if next_hop then
            DBG.print_debug('analysis', 'next_hop to keep: ' .. next_hop[1] .. ',' .. next_hop[2])
        end
    end
    if closest_village then
        leader_threats.leader_locs.closest_village = closest_village
        table.insert(leader_threats.protect_locs, closest_village)
        DBG.print_debug('analysis', 'reachable village after keep: ' .. closest_village[1] .. ',' .. closest_village[2])
    end
    -- It is possible that no protect location was found (e.g. if the leader cannot move)
    if (not leader_threats.protect_locs[1]) then
        leader_threats.protect_locs = { { leader_proxy.x, leader_proxy.y } }
    end
    --DBG.dbms(leader_threats)

    fred_ops_utils.assess_leader_threats(leader_threats, protect_locs, leader_proxy, raw_cfgs_main, side_cfgs, gamedata, fred_data.move_cache)


    -- Attributing enemy units to zones
    -- Use base_power for this as it is not only for the current turn
    local assigned_enemies = {}
    for id,loc in pairs(gamedata.enemies) do
        if (not gamedata.unit_infos[id].canrecruit)
            and (not FU.get_fgumap_value(gamedata.reachable_castles_map[gamedata.unit_infos[id].side], loc[1], loc[2], 'castle') or false)
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
            and (not FU.get_fgumap_value(gamedata.reachable_castles_map[unit_copy.side], unit_copy.x, unit_copy.y, 'castle') or false)
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
        fred_data.turn_data.unit_attacks,
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
        for id,_ in pairs(gamedata.my_units_MP) do
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

        prerecruit = fred_recruit:prerecruit_units(closest_keep, outofway_units)
        -- Need to do this, or the recruit CA will try to recruit the same units again later
        fred_recruit:clear_prerecruit()
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
        for x,y,village_data in FU.fgumap_iter(villages_to_protect_maps[zone_id]) do
            if village_data.protect then
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

    local value_ratio = fred_data.turn_data.behavior.influence.value_ratio
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
                    --print('    ' .. value_ratio, av_damage_done, av_hp_left)

                    local attacker_rating = av_damage_done / value_ratio + av_hp_left
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

    local power_stats = fred_ops_utils.calc_power_stats(raw_cfgs_main, assigned_units, assigned_enemies, assigned_recruits, gamedata)
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
            local frac_needed = 0
            if (data.power_needed > 0) then
                frac_needed = data.power_missing / data.power_needed
            end
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
            power_stats = fred_ops_utils.calc_power_stats(raw_cfgs_main, assigned_units, assigned_enemies, assigned_recruits, gamedata)

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

    power_stats = fred_ops_utils.calc_power_stats(raw_cfgs_main, assigned_units, assigned_enemies, assigned_recruits, gamedata)
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

        power_stats = fred_ops_utils.calc_power_stats(raw_cfgs_main, assigned_units, assigned_enemies, assigned_recruits, gamedata)
        --DBG.dbms(power_stats)
    end
    --DBG.dbms(power_stats)


    fred_ops_utils.replace_zones(assigned_units, assigned_enemies, protect_locs, actions)


    local ops_data = {
        leader_threats = leader_threats,
        assigned_enemies = assigned_enemies,
        assigned_units = assigned_units,
        retreaters = retreaters,
        assigned_recruits = assigned_recruits,
        protect_locs = protect_locs,
        actions = actions,
        prerecruit = prerecruit
    }
    --DBG.dbms(ops_data)
    --DBG.dbms(ops_data.protect_locs)
    --DBG.dbms(ops_data.assigned_enemies)
    --DBG.dbms(ops_data.assigned_units)

    DBG.print_debug('analysis', '--- Done determining turn_data ---\n')

    return ops_data
end


function fred_ops_utils.update_ops_data(fred_data)
    local ops_data = fred_data.ops_data
    local gamedata = fred_data.gamedata
    local raw_cfgs_main = FSC.get_raw_cfgs()
    local side_cfgs = FSC.get_side_cfgs()

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
    --     - this includes the possibility of the unit having died when attacking
    -- 2. the reserved unit cannot get to the goal any more
    -- This can happen if the units were used in other actions, moves
    -- to get out of the way for another unit or possibly due to a WML event
    for i_a=#ops_data.actions.villages,1,-1 do
        local valid_action = true
        local action = ops_data.actions.villages[i_a].action
        for i_u,unit in ipairs(action.units) do
            if (not gamedata.units[unit.id])
                or (gamedata.units[unit.id][1] ~= unit[1]) or (gamedata.units[unit.id][2] ~= unit[2])
            then
                --print(unit.id .. ' has moved or died')
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
        fred_data.turn_data.unit_attacks,
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
    fred_ops_utils.replace_zones(ops_data.assigned_units, ops_data.assigned_enemies, ops_data.protect_locs, ops_data.actions)


    -- Once the leader has no MP left, we reconsider the leader threats
    -- TODO: we might want to handle reassessing leader locs and threats differently
    local leader_proxy = wesnoth.get_unit(gamedata.leader_x, gamedata.leader_y)
    if (leader_proxy.moves == 0) then
        ops_data.leader_threats.leader_locs = {}
        ops_data.leader_threats.protect_locs = { { leader_proxy.x, leader_proxy.y } }

        fred_ops_utils.assess_leader_threats(ops_data.leader_threats, ops_data.protect_locs, leader_proxy, raw_cfgs_main, side_cfgs, gamedata, fred_data.move_cache)
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


function fred_ops_utils.get_action_cfgs(fred_data)
    local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'zone_control'
    DBG.print_debug_time('analysis', fred_data.turn_start_time, '     - Evaluating defend zones map analysis:')

    local gamedata = fred_data.gamedata
    local ops_data = fred_data.ops_data
    --DBG.dbms(ops_data)

    -- These are only the raw_cfgs of the 3 main zones
    --local raw_cfgs = FSC.get_raw_cfgs('all')
    --local raw_cfgs_main = FSC.get_raw_cfgs()
    --DBG.dbms(raw_cfgs_main)
    --DBG.dbms(fred_data.analysis)


    fred_data.zone_cfgs = {}

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

    local power_stats = fred_ops_utils.calc_power_stats(ops_data.actions.hold_zones, ops_data.assigned_units, ops_data.assigned_enemies, ops_data.assigned_recruits, gamedata)
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
                table.insert(fred_data.zone_cfgs, {
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
            table.insert(fred_data.zone_cfgs, {
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
            table.insert(fred_data.zone_cfgs, {
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
                table.insert(fred_data.zone_cfgs, {
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
    local value_ratio = fred_data.turn_data.behavior.influence.value_ratio

    for zone_id,zone_units in pairs(holders_by_zone) do
        local power_rating = power_stats.zones[zone_id].power_needed - power_stats.zones[zone_id].my_power / 1000

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
            if gamedata.my_units_MP[id] then
                if (not retreaters) then retreaters = {} end
                retreaters[id] = gamedata.units[id]
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
    local raw_cfgs_main = FSC.get_raw_cfgs()
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