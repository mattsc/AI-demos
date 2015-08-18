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
        local LS = wesnoth.require "lua/location_set.lua"
        local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"
        local R = wesnoth.require "~/add-ons/AI-demos/lua/retreat.lua"


        ----- Debug output flags -----
        local debug_eval = false    -- top-level evaluation information
        local debug_exec = true     -- top-level executiuon information


        ------- Utility functions -------
        local function print_time(...)
            if fred.data.turn_start_time then
                AH.print_ts_delta(fred.data.turn_start_time, ...)
            else
                AH.print_ts(...)
            end
        end


        function fred:zone_advance_rating(zone_id, x, y, gamedata)
            local rating

            if (wesnoth.current.side == 1) then
                if (zone_id == 'west') then
                    -- Return nil for being outside certain areas
                    if (x > 19) then return end
                    if (x > 14) and (y > 6) and (y < 15) then return end

                    rating = y

                    local x0 = 11
                    local goal_x, goal_y = 12, 18
                    if (y < 7)  then
                        x0 = -1.0 * (y - 2) + 18
                        goal_x, goal_y = 8, 8
                    elseif (y > 15) then
                        x0 = 2.0 * (y - 15) + 13
                        goal_x, goal_y = 22, 22
                    end

                    local dx = math.abs(x - x0)
                    if (dx > 2) then
                        rating = rating - dx
                    end

                    rating = rating - H.distance_between(x, y, goal_x, goal_y) / 1000.
                end

                if (zone_id == 'center') then
                    -- Return nil for being outside certain areas
                    if (x < 15) or (x > 23) then return end

                    rating = y

                    local x0 = 19
                    local dx = math.abs(x - x0)

                    if (dx > 2) then
                        rating = rating - dx
                    end

                    if (x < 15) and (y < 14) then
                        rating = rating - H.distance_between(x, y, 19, 4) - 100.
                    else
                        rating = rating - H.distance_between(x, y, 19, 21) / 1000.
                    end
                end

                if (zone_id == 'east') then
                    -- Return nil for being outside certain areas
                    if (x < 17) then return end
                    if (x < 24) and (y > 8) and (y < 18) then return end

                    rating = y

                    local x0 = 27
                    local goal_x, goal_y = 25, 19
                    if (y < 11)  then
                        x0 = 1.0 * (y - 2) + 18
                        goal_x, goal_y = 31, 10
                    elseif (y > 16) then
                        x0 =  -2.0 * (y - 17) + 27
                        goal_x, goal_y = 16, 22
                    end

                    local dx = math.abs(x - x0)
                    if (dx > 2) then
                        rating = rating - dx
                    end

                    rating = rating - H.distance_between(x, y, goal_x, goal_y) / 1000.
                end

                if (zone_id == 'all_map') then
                    rating = - H.distance_between(x, y, 20, 19)
                end
            end

            -- TODO: not set up for new method
            if (wesnoth.current.side == '222xxx') then
                if (zone_id == 'left') or (zone_id == 'rush_left') then
                    rating = rating - y / 10.

                    local x0 = 27
                    local goal_x, goal_y = 26, 6
                    if (y > 17)  then
                        x0 = -1.0 * (23 - y) + 20
                        goal_x, goal_y = 30, 16
                    elseif (y < 10) then
                        x0 = 2.0 * (10 - y) + 25
                        goal_x, goal_y = 16, 2
                    end

                    local dx = math.abs(x - x0)
                    if (dx > 2) then
                        rating = rating - dx
                    end

                    rating = rating - H.distance_between(x, y, goal_x, goal_y) / 1000.
                end

                if (zone_id == 'center') or (zone_id == 'rush_center') then
                    rating = rating - y / 10.

                    local x0 = 19
                    local dx = math.abs(x - x0)

                    if (dx > 2) then
                        rating = rating - dx
                    end

                    if (x > 23) and (y > 11) then
                        rating = rating - H.distance_between(x, y, 19, 21) - 100.
                    else
                        rating = rating - H.distance_between(x, y, 19, 4) / 1000.
                    end
                end

                if (zone_id == 'right') or (zone_id == 'rush_right') then
                    rating = rating - y / 10.

                    local x0 = 11
                    local goal_x, goal_y = 13, 6
                    if (y > 14)  then
                        x0 = 1.0 * (23 - y) + 20
                        goal_x, goal_y = 7, 15
                    elseif (y < 9) then
                        x0 =  -2.0 * (8 - y) + 11
                        goal_x, goal_y = 22, 2
                    end

                    local dx = math.abs(x - x0)
                    if (dx > 2) then
                        rating = rating - dx
                    end

                    rating = rating - H.distance_between(x, y, goal_x, goal_y) / 1000.
                end
            end

            -- For these zones, advancing is toward the enemy leader
            if (zone_id == 'enemy_leader') or (zone_id == 'full_map') then
                for side,loc in ipairs(gamedata.leaders) do
                    if wesnoth.is_enemy(side, wesnoth.current.side) then
                        rating = - H.distance_between(x, y, loc[1], loc[2])
                        break
                    end
                end
            end

            return rating -- return nil if we got here
        end


        ------ Map analysis at beginning of turn -----------

        function fred:get_leader_zone_raw_cfg()
            local cfg_leader = {
                zone_id = 'leader',
                key_hexes = { { 18,4 },  { 19,4 } },
                zone_filter = { x = '1-15,16-23,24-34', y = '1-6,1-7,1-8' },
            }

            return cfg_leader
        end

        function fred:get_raw_cfgs(zone_id)
            if (zone_id == 'all_map') then
                local cfg_all_map = {
                    zone_id = 'all_map',
                    --key_hexes = { { 25,12 },  { 27,11 }, { 29,11 }, { 32,10 } },
                    target_zone = { x = '1-34', y = '1-23' },
                    zone_filter = { x = '1-34', y = '1-23' },
                    unit_filter_advance = { x = '1-34', y = '1-23' },
                    hold_slf = { x = '1-34', y = '1-23' },
                    villages = {
                        slf = { x = '1-34', y = '1-23' },
                        villages_per_unit = 2
                    }
                }

                return cfg_all_map
            end

            local cfg_west = {
                zone_id = 'west',
                key_hexes = { { 8,8 },  { 11,9 }, { 14,8 } },
                target_zone = { x = '1-15', y = '7-19' },
                zone_filter = { x = '4-14', y = '7-15' },
                unit_filter_advance = { x = '1-20,1-14', y = '1-6,7-13' },
                hold_slf = { x = '1-15', y = '6-14' },
                villages = {
                    slf = { x = '1-14', y = '1-10' },
                    villages_per_unit = 2
                }
            }

            local cfg_center = {
                zone_id = 'center',
                key_hexes = { { 17,10 },  { 18,9 }, { 20,9 }, { 22,10 } },
                target_zone = { x = '15-23,13-23', y = '8-13,14-19' },
                zone_filter = { x = '15-24', y = '8-16' },
                unit_filter_advance = { x = '15-23,', y = '1-13' },
                hold_slf = { x = '16-24,16-23', y = '7-10,11-14' },
                villages = {
                    slf = { x = '16-21', y = '7-10' },
                    villages_per_unit = 2
                }
            }

            local cfg_east = {
                zone_id = 'east',
                key_hexes = { { 25,12 },  { 27,11 }, { 29,11 }, { 32,10 } },
                target_zone = { x = '24-34,22-34', y = '9-17,18-23' },
                zone_filter = { x = '24-34', y = '9-17' },
                unit_filter_advance = { x = '17-34,24-34', y = '1-8,9-16' },
                hold_slf = { x = '24-34', y = '9-18' },
                villages = {
                    slf = { x = '22-34', y = '1-10' },
                    villages_per_unit = 2
                }
            }

            local cfgs = {
                cfg_west,
                cfg_center,
                cfg_east
            }

            if (not zone_id) then
               return cfgs
            else
                for _,cfg in pairs(cfgs) do
                    if (cfg.zone_id == zone_id) then
                        return cfg
                    end
                end
            end
        end

        function fred:analyze_leader_threat(gamedata)
            local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'zone_control'
            if debug_eval then print_time('     - Evaluating leader threat map analysis:') end

            -- Some pointers just for convenience
            local stage_id = fred.data.analysis.stage_ids[fred.data.analysis.stage_counter]
            local stage_status = fred.data.analysis.status[stage_id]


            --print('\n--------------- ' .. stage_id .. ' ------------------------')

            -- Start with an analysis of the threat to the AI leader
            local leader_x = gamedata.leaders[wesnoth.current.side][1]
            local leader_y = gamedata.leaders[wesnoth.current.side][2]
            --print(leader_x, leader_y)

            local leader_proxy = wesnoth.get_unit(leader_x, leader_y)

            local enemy_leader_loc = {}
            for side,loc in ipairs(gamedata.leaders) do
                if wesnoth.is_enemy(side, wesnoth.current.side) then
                    enemy_leader_loc = loc
                    break
                end
            end

            local raw_cfg = fred:get_leader_zone_raw_cfg()
            --DBG.dbms(raw_cfg)

            stage_status[raw_cfg.zone_id] = {
                power_used = 0,
                power_needed = 0,
                power_missing = 0,
                n_units_needed = 0,
                n_units_used = 0,
                units_used = {}
            }
            stage_status.contingency = 0

            for id,zone_id in pairs(fred.data.analysis.status.units_used) do
                -- Check whether unit still exists and has no MP left
                -- This is a safeguard against "unusual stuff"
                if (zone_id == raw_cfg.zone_id) and gamedata.my_units_noMP[id] then
                    if (not gamedata.unit_infos[id].canrecruit) then
                        local power = gamedata.unit_infos[id].power
                        stage_status[zone_id].power_used = stage_status[zone_id].power_used + power
                        stage_status[zone_id].n_units_used = stage_status[zone_id].n_units_used + 1
                        stage_status[zone_id].units_used[id] = power
                    end
                else
                    fred.data.analysis.status.units_used[id] = nil
                end
            end
            --DBG.dbms(stage_status)


            -- T1 threats: those enemies that can attack the leader directly.
            -- And enemies who can reach the key hexes (if leader is not there)

            local threats1 = {}
            local my_power1 = {}
            local ids = FU.get_fgumap_value(gamedata.enemy_attack_map[1], leader_x, leader_y, 'ids', {})


            for _,id in pairs(ids) do
                threats1[id] = gamedata.unit_infos[id].power
            end

            for _,hex in pairs(raw_cfg.key_hexes) do
                local x, y = hex[1], hex[2]

                -- Enemies that can attack a key hex
                local ids = FU.get_fgumap_value(gamedata.enemy_attack_map[1], x, y, 'ids', {})
                for _,id in pairs(ids) do
                    threats1[id] = gamedata.unit_infos[id].power
                end
            end
            --DBG.dbms(threats1)

            local my_power = {}
            -- Count units that have already moved in the zone
            for id,power in pairs(stage_status[raw_cfg.zone_id].units_used) do
                --print('  already used:', id, power)
                my_power[id] = power
            end

            -- Add up the power of all T1 threats on this zone
            local enemy_power1 = 0
            for id,power in pairs(threats1) do
                enemy_power1 = enemy_power1 + power
            end
            --print('  enemy_power1:', enemy_power1)


            -- We also get all units that are in the zone but not T1 threats
            local threats2 = {}
            for id,loc in pairs(gamedata.enemies) do
                if (not threats1[id]) and wesnoth.match_unit(gamedata.unit_copies[id], raw_cfg.zone_filter) then
                    threats2[id] = gamedata.unit_infos[id].power
                end
            end
            --DBG.dbms(threats2)

            -- Add up the power of all T1 threats on this zone
            local enemy_power2 = 0
            for id,power in pairs(threats2) do
                enemy_power2 = enemy_power2 + power
            end
            --print('  enemy_power2:', enemy_power2)


            -- Attacks on T1 threats is with unlimited resources
            local attack1_cfg = {
                zone_id = raw_cfg.zone_id,
                stage_id = stage_id,
                targets = {},
                actions = { attack = true },
                value_ratio = 0.5,  -- more aggressive for direct leader threats
                ignore_resource_limit = true
            }

            for id,_ in pairs(threats1) do
                local target = {}
                target[id] = gamedata.enemies[id]
                table.insert(attack1_cfg.targets, target)
            end
            --DBG.dbms(attack1_cfg)

            local attack2_cfg = {
                zone_id = raw_cfg.zone_id,
                stage_id = stage_id,
                targets = {},
                actions = { attack = true },
                ignore_resource_limit = true
            }

            for id,_ in pairs(threats2) do
                local target = {}
                target[id] = gamedata.enemies[id]
                table.insert(attack2_cfg.targets, target)
            end
            --DBG.dbms(attack2_cfg)

            -- Favorable attacks can be done at any time after threats to
            -- the AI leader are dealt with
            local zone_id = 'favorable_attacks'
            stage_status.contingency = 0
            stage_status[zone_id] = {
                power_missing = 0,
                power_needed = 0,
                power_used = 0,
                n_units_needed = 0,
                n_units_used = 0,
                units_used = {}
            }

            local favorable_attacks_cfg = {
                zone_id = zone_id,
                stage_id = stage_id,
                actions = { attack = true },
                value_ratio = 2.0,  -- only very favorable attacks will pass this
                ignore_resource_limit = true
            }

            fred.data.zone_cfgs = {}
            table.insert(fred.data.zone_cfgs, attack1_cfg)
            table.insert(fred.data.zone_cfgs, attack2_cfg)
            table.insert(fred.data.zone_cfgs, favorable_attacks_cfg)
            --DBG.dbms(fred.data.zone_cfgs)
        end

        function fred:analyze_defend_zones(gamedata)
            local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'zone_control'
            if debug_eval then print_time('     - Evaluating defend zones map analysis:') end

            -- Some pointers just for convenience
            local stage_id = fred.data.analysis.stage_ids[fred.data.analysis.stage_counter]
            local stage_status = fred.data.analysis.status[stage_id]

            local raw_cfgs = fred:get_raw_cfgs()
            --DBG.dbms(raw_cfgs)

            zone_cfgs = {}

            local cfg_attack = { use_max_damage_weapons = true }

            local influence_maps = FU.get_influence_maps(gamedata.my_attack_map[1], gamedata.enemy_attack_map[1])
            --DBG.dbms(gamedata.my_attack_map[1])

            local show_debug = false
            if show_debug then
                FU.put_fgumap_labels(influence_maps, 'my_influence')
                W.message{ speaker = 'narrator', message = 'my_influence' }
                FU.put_fgumap_labels(influence_maps, 'enemy_influence')
                W.message{ speaker = 'narrator', message = 'enemy_influence' }
                FU.put_fgumap_labels(influence_maps, 'influence')
                W.message{ speaker = 'narrator', message = 'influence' }
                FU.put_fgumap_labels(influence_maps, 'tension')
                W.message{ speaker = 'narrator', message = 'tension' }
                FU.put_fgumap_labels(influence_maps, 'vulnerability')
                W.message{ speaker = 'narrator', message = 'vulnerability' }
            end


            local map_analysis = { zones = {} }
            local MA = map_analysis -- just for convenience
            local MAZ = map_analysis.zones -- just for convenience

            -- First calculate power that has been used for the zone already
            --DBG.dbms(gamedata.my_move_map[2])
            --print('power_used:')

            for _,cfg in ipairs(raw_cfgs) do
                local village_count = 0  -- unowned and enemy-owned villages
                for x,tmp in pairs(gamedata.village_map) do
                    for y,village in pairs(tmp) do

                        if wesnoth.match_location(x, y, cfg.villages.slf) then
                            if (village.owner ~= wesnoth.current.side) then
                                village_count = village_count + 1
                            end
                        end
                    end
                end

                local n_units_needed = math.ceil(village_count / cfg.villages.villages_per_unit)
                --print('  units needed for villages: ' .. cfg.zone_id, village_count, n_units_needed)


                stage_status[cfg.zone_id] = {
                    power_used = 0,
                    n_units_needed = n_units_needed,
                    n_units_used = 0,
                    units_used = {}
                }
            end

            for id,zone_id in pairs(fred.data.analysis.status.units_used) do
                -- Check whether unit still exists and has no MP left
                -- This is a safeguard against "unusual stuff"
                if gamedata.my_units_noMP[id] then
                    if stage_status[zone_id] and (not gamedata.unit_infos[id].canrecruit) then
                        local power = gamedata.unit_infos[id].power
                        stage_status[zone_id].power_used = stage_status[zone_id].power_used + power
                        stage_status[zone_id].n_units_used = stage_status[zone_id].n_units_used + 1
                        stage_status[zone_id].units_used[id] = power
                    end
                else
                    fred.data.analysis.status.units_used[id] = nil
                end
            end

            -- TODO: disable this for now; may or may not be reactivated later
            -- For example, we might want to include units that were used for
            -- what does not count into one of the zones
            while false do
            for id,loc in pairs(gamedata.my_units_noMP) do
                local in_zone
                for _,cfg in ipairs(raw_cfgs) do
                    if (not in_any_zone) then
                        if wesnoth.match_unit(gamedata.unit_copies[id], cfg.zone_filter) then
                            in_zone = cfg.zone_id
                        end
                    end
                end

                if in_zone then
                    --print('  is in: ', in_zone)
                    local power = gamedata.unit_infos[id].power
                    stage_status[in_zone].power_used = stage_status[in_zone].power_used + power
                    stage_status[in_zone].n_units_used = stage_status[in_zone].n_units_used + 1
                    stage_status[in_zone].units_used[id] = power
                else
                    local can_reach = {}
                    for _,cfg in ipairs(raw_cfgs) do
                        --print(cfg.zone_id)
                        for _,hex in pairs(cfg.key_hexes) do
                            local ids = gamedata.my_move_map[2][hex[1]]
                               and gamedata.my_move_map[2][hex[1]][hex[2]]
                               and gamedata.my_move_map[2][hex[1]][hex[2]].ids
                               or {}
                            --DBG.dbms(ids)

                            for _,tmp_id in ipairs(ids) do
                                if (tmp_id == id) then
                                    --print(  'can reach:' .. cfg.zone_id)
                                    can_reach[cfg.zone_id] = true
                                    -- Cannot add up the count here, as same unit might be able to reach several key hexes
                                end
                            end
                        end
                    end

                    local power = gamedata.unit_infos[id].power
                    local count = 0
                    for zid,_ in pairs(can_reach) do count = count + 1 end
                    --print(power,count)
                    for zid,_ in pairs(can_reach) do
                        stage_status[zid].power_used = stage_status[zid].power_used + power / count
                        stage_status[zid].n_units_used = stage_status[zid].n_units_used + 1 / count
                        stage_status[zid].units_used[id] = power / count
                    end
                end
            end
            end  -- end disabling this part


            -- T1 threats: those enemies that can attack a key hex in one move
            -- Enemy units that are T1 threats in several zones are counted
            -- multiple times by this. That is intentional.

            local threats1_all_zones = {}
            local my_power1_all_zones = {}
            for _,cfg in ipairs(raw_cfgs) do
                --print(cfg.zone_id)
                local threats1_zone = {}  -- This is just for this zone
                local my_power_zone = {}  -- This is just for this zone
                for _,hex in pairs(cfg.key_hexes) do
                    local x, y = hex[1], hex[2]

                    -- Enemies that can attack a key hex
                    local ids = FU.get_fgumap_value(gamedata.enemy_attack_map[1], x, y, 'ids', {})
                    for _,id in pairs(ids) do
                        threats1_zone[id] = gamedata.unit_infos[id].power
                        threats1_all_zones[id] = true
                    end

                    -- AI units which can move to a key hex
                    local ids = FU.get_fgumap_value(gamedata.my_move_map[1], x, y, 'ids', {})
                    for _,id in pairs(ids) do
                        if (not gamedata.unit_infos[id].canrecruit) then
                            my_power_zone[id] = gamedata.unit_infos[id].power
                            my_power1_all_zones[id] = gamedata.unit_infos[id].power
                        end
                    end
                end

                -- In addition, this must count units that have moved in the zone
                -- already (which might or might not be included in the above
                -- metric, depending on whether they moved onto a key hex
                for id,power in pairs(stage_status[cfg.zone_id].units_used) do
                    --print('  already used:', id, power)
                    my_power_zone[id] = power
                    my_power1_all_zones[id] = power
                end

                -- Now add up the power of all T1 threats on this zone
                local enemy_power1 = 0
                for id,power in pairs(threats1_zone) do
                    enemy_power1 = enemy_power1 + power
                end
                --print('  enemy_power1:', enemy_power1)

                local my_power1 = 0
                for id,power in pairs(my_power_zone) do
                    my_power1 = my_power1 + power
                end
                --print('  my_power1:', my_power1)

                -- And finally, save it all in the threats table
                MAZ[cfg.zone_id] = {
                    enemy_power1 = enemy_power1,
                    my_power1 = my_power1,
                    my_units1 = my_power_zone,
                    raw_cfg = cfg,
                    raw_targets = threats1_zone
                }
            end
            --DBG.dbms(threats1_all_zones)
            --DBG.dbms(my_power1_all_zones)
            --DBG.dbms(MAZ['west'])


            -- T2 threats: those enemies that can get to a key hex in two moves
            -- Enemy units that are T1 threats in a different zone need to be
            -- excluded from this.
            -- The power of enemy units that are T2 threats in several zones is
            -- divided evenly between those zones
            -- Own units that have moves but can get to the zone next turn are
            -- included in my_move_map[2] automatically

            local threats2_by_zone = {} -- This is to collect T2 threats for all zones first
            for _,cfg in ipairs(raw_cfgs) do
                threats2_by_zone[cfg.zone_id] = {}

                for _,hex in pairs(cfg.key_hexes) do
                    local x, y = hex[1], hex[2]

                    local ids = FU.get_fgumap_value(gamedata.enemy_attack_map[2], x, y, 'ids', {})
                    for _,id in pairs(ids) do
                        -- Only units that are note T1 threats can be T2 threats
                        if (not threats1_all_zones[id]) then
                            threats2_by_zone[cfg.zone_id][id] = gamedata.unit_infos[id].power
                        end
                    end
                end
            end
            --DBG.dbms(threats2_by_zone)

            -- Count how many times each of the T2 threats appears across all zones
            local threats2_all_zones = {}
            for _,ids in pairs(threats2_by_zone) do
                for id,_ in pairs(ids) do
                    threats2_all_zones[id] = (threats2_all_zones[id] or 0) + 1
                end
            end
            --DBG.dbms(threats2_all_zones)

            -- Then divide the power for each zone by that count
            for zone_id,ids in pairs(threats2_by_zone) do
                local enemy_power2 = 0
                for id,power in pairs(ids) do
                    enemy_power2 = enemy_power2 + power / threats2_all_zones[id]
                end

                MAZ[zone_id].enemy_power2 = enemy_power2
            end

            -- For the own units, we do T2 the same way as T1, that is, we do
            -- double count here at this stage
            -- However, we need to exclude units that are on the T1 list (they might
            -- have been included through having been used already)
            local my_power2_all_zones = {}
            for _,cfg in ipairs(raw_cfgs) do
                --print(cfg.zone_id)
                local my_power_zone = {}  -- This is just for this zone
                for _,hex in pairs(cfg.key_hexes) do
                    local x, y = hex[1], hex[2]

                    local ids = FU.get_fgumap_value(gamedata.my_move_map[2], x, y, 'ids', {})
                    for _,id in pairs(ids) do

                        if (not MAZ[cfg.zone_id].my_units1[id])
                            and (not gamedata.unit_infos[id].canrecruit)
                        then
                            my_power_zone[id] = gamedata.unit_infos[id].power
                            my_power2_all_zones[id] = gamedata.unit_infos[id].power
                        end
                    end
                end

                -- Now add up the power of all T2 units for this zone
                local my_power2 = 0
                for id,power in pairs(my_power_zone) do
                    my_power2 = my_power2 + power
                end
                --print('  my_power2:', my_power2)

                -- And finally, save it all in the threats table
                MAZ[cfg.zone_id].my_power2 = my_power2
                MAZ[cfg.zone_id].my_units2 = my_power_zone
            end
            --DBG.dbms(my_power1_all_zones)
            --DBG.dbms(my_power2_all_zones)

            -- Calculate vulnerability for the zones
            -- TODO: currently this is not used; either use or remove
            for _,cfg in ipairs(raw_cfgs) do
                local max_vul = 0
                for _,hex in pairs(cfg.key_hexes) do
                    local x, y = hex[1], hex[2]
                    local vulnerability = FU.get_fgumap_value(influence_maps, x, y, 'vulnerability', 0)

                    if (vulnerability > max_vul) then
                        max_vul = vulnerability
                    end
                end

                MAZ[cfg.zone_id].vulnerability = max_vul
            end

            MA.enemy_power1, MA.enemy_power2 = 0, 0
            for zone_id,power in pairs(MAZ) do
                MA.enemy_power1 = MA.enemy_power1 + power.enemy_power1
                MA.enemy_power2 = MA.enemy_power2 + power.enemy_power2
            end
            --print('enemy_power:', MA.enemy_power1, MA.enemy_power2, MA.enemy_power1 + MA.enemy_power2)


            -- What does AI have:
            -- First, count overall power of AI units (excluding leader)
            -- This only counts units once, even if they appear in several zones
            MA.my_power1, MA.my_power2 = 0, 0
            for id,power in pairs(my_power1_all_zones) do
                MA.my_power1 = MA.my_power1 + power
            end
            for id,power in pairs(my_power2_all_zones) do
                if (not my_power1_all_zones[id]) then
                    MA.my_power2 = MA.my_power2 + power
                end
            end
            --print('my_power:', MA.my_power1, MA.my_power2, MA.my_power1 + MA.my_power2)

            MA.value_ratio = FU.cfg_default('value_ratio')
            MA.power_needed = (MA.enemy_power1 + MA.enemy_power2) * MA.value_ratio
            MA.contingency = (MA.my_power1 + MA.my_power2) - MA.power_needed
            if (MA.contingency < 0) then MA.contingency = 0 end
            --print('power_needed, contingency', MA.power_needed, MA.contingency)



            ----- Start the zone analysis comparison -----
            -- TODO: should be possible to combine some of these steps
            -- Leave them separate for now for clarity
            --print('---- Zone evaluation ----')

            for zone_id,data in pairs(MAZ) do
                --print(zone_id .. ':')

                local dpower1 = data.my_power1 - data.enemy_power1
                local dpower2 = data.my_power2 - data.enemy_power2
                --print('  T1:', data.my_power1, -data.enemy_power1, dpower1)
                --print('  T2:', data.my_power2, -data.enemy_power2, dpower2)
                --print('  All:', data.my_power1+data.my_power2, -data.enemy_power1-data.enemy_power2, data.my_power1 + data.my_power2 - data.enemy_power1 - data.enemy_power2)

                local vul1 = data.my_power1 + data.enemy_power1 - math.abs(data.my_power1 - data.enemy_power1)
                local vul2 = data.my_power2 + data.enemy_power2 - math.abs(data.my_power2 - data.enemy_power2)
                --print('  Vul:', data.vulnerability, vul1, vul2, vul1 + vul2)

                data.rating1 = -dpower1 -- + vul1 TODO: reconsider this rating
                data.rating2 = -dpower2 -- + vul2
                --print('rating 1 & 2', data.rating1, data.rating2)

                stage_status[zone_id].rating = data.rating1
                stage_status.contingency = MA.contingency
            end

--DBG.dbms(MAZ)
            -- Get action config for T1
            local attack_cfgs = {}
            for zone_id,data in pairs(MAZ) do
                local zone_cfg = { zone_id = zone_id }
                zone_cfg.target_zone = data.raw_cfg.target_zone
                zone_cfg.rating = data.rating1
                zone_cfg.stage_id = stage_id
                zone_cfg.targets = {}

                -- Also add in the targets, but now use only those that are inside cfg.target_zone
                for id,_ in pairs(data.raw_targets) do
                    if wesnoth.match_unit(gamedata.unit_copies[id], data.raw_cfg.target_zone) then
                        local target = {}
                        target[id] = gamedata.enemies[id]
                        table.insert(zone_cfg.targets, target)
                    end
                end

                -- This is the sum of both T1 and T2!!
                local power_needed = (data.enemy_power1 + data.enemy_power2) * MA.value_ratio
                stage_status[zone_id].power_needed = power_needed

                if (data.my_power1 > 0) then
                    zone_cfg.actions = { attack = true }
                else
                    -- TODO: Could exclude table entry in the first place, but leave for now for clarity
                    zone_cfg.actions = {}
                end


                table.insert(attack_cfgs, zone_cfg)
            end
            table.sort(attack_cfgs, function(a, b) return a.rating > b.rating end)
            --DBG.dbms(attack_cfgs)

            fred.data.zone_cfgs = {}
            for _,cfg in pairs(attack_cfgs) do
                table.insert(fred.data.zone_cfgs, cfg)
            end


            --DBG.dbms(fred.data.zone_cfgs)


            --print('\nSend units to:')

            local tmp_cfgs_hold = {}
            local tmp_cfgs_advance = {}
            local hold = {
                total_needed = MA.power_needed,
                total_available = MA.my_power1 + MA.my_power2
            }

            local power_fac = 1
            if (hold.total_available < hold.total_needed) then
                power_fac = hold.total_available / hold.total_needed
            end
            stage_status.power_fac = power_fac


            for zone_id,data in pairs(MAZ) do
                --print(zone_id)

--DBG.dbms(stage_status[zone_id])
                local power_needed = stage_status[zone_id].power_needed
                local power_used = stage_status[zone_id].power_used
                local power_missing = (power_needed - power_used) * power_fac
                stage_status[zone_id].power_missing = power_missing

                hold[zone_id] = {
                    units = {}
                }

                --print('  power needed, used, missing:')
                --print(power_needed, power_used, power_missing)
                for id,power in pairs(data.my_units1) do
                    if (not stage_status[zone_id].units_used[id]) then
                        --print('  1: ' .. id, power)

                        if gamedata.my_units_MP[id] then
                            hold[zone_id].units[id] = power
                        end
                    end
                end
                for id,power in pairs(data.my_units2) do
                    if (not stage_status[zone_id].units_used[id]) then
                        --print('  2: ' .. id, power)

                        if gamedata.my_units_MP[id] then
--xxxxx                            hold[zone_id].units[id] = power
                        end
                    end
                end

                -- Now add up the power of all those units
                local power_available = 0
                for id,power in pairs(hold[zone_id].units) do
                    power_available = power_available + power
                end
                hold[zone_id].power_available = power_available
                hold[zone_id].rating = power_missing - power_available

                local cfg = {
                    zone_id = zone_id,
                    stage_id = stage_id,
                    actions = { advance = true },
                    rating = hold[zone_id].rating + 0.001, -- as there's a sorting later
                    ignore_resource_limit = true,
                    villages_only = true
                }
                table.insert(tmp_cfgs_hold, cfg)

                local cfg = {
                    zone_id = zone_id,
                    stage_id = stage_id,
                    actions = { hold = true },
                    rating = hold[zone_id].rating,
                    holders = hold[zone_id].units
                }
                table.insert(tmp_cfgs_hold, cfg)

                -- And for advancing, it's very similar, but number of units
                -- needed plays the most important role here
                rating = hold[zone_id].rating / 1000
                    + stage_status[zone_id].n_units_needed - stage_status[zone_id].n_units_used

                local cfg = {
                    zone_id = zone_id,
                    stage_id = stage_id,
                    actions = { advance = true },
                    rating = rating
                }
                table.insert(tmp_cfgs_advance, cfg)
            end

            table.sort(tmp_cfgs_hold, function(a, b) return a.rating > b.rating end)
            --DBG.dbms(tmp_cfgs_hold)
            for _,cfg in pairs(tmp_cfgs_hold) do
                table.insert(fred.data.zone_cfgs, cfg)
            end

            table.sort(tmp_cfgs_advance, function(a, b) return a.rating > b.rating end)
            --DBG.dbms(tmp_cfgs_advance)
            for _,cfg in pairs(tmp_cfgs_advance) do
                table.insert(fred.data.zone_cfgs, cfg)
            end

            -- At the end, we add all the attack cfgs again, but with

            --DBG.dbms(fred.data.zone_cfgs)
        end

        function fred:analyze_all_map(gamedata)
            local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'all_map'
            if debug_eval then print_time('     - Evaluating all_map CA:') end

            -- Some pointers just for convenience
            local stage_id = fred.data.analysis.stage_ids[fred.data.analysis.stage_counter]
            local stage_status = fred.data.analysis.status[stage_id]

            fred.data.zone_cfgs = {}

            --print(' --- my units all_map')
            local my_power = 0
            for id,loc in pairs(gamedata.my_units) do
                --print(id, gamedata.unit_infos[id].power)
                my_power = my_power + gamedata.unit_infos[id].power
            end
            --print(' --- enemy units all_map')
            local enemy_power = 0
            for id,loc in pairs(gamedata.enemies) do
                --print(id, gamedata.unit_infos[id].power)
                enemy_power = enemy_power + gamedata.unit_infos[id].power
            end
            local power_ratio = enemy_power / my_power
            --print(' -----> my_power, enemy_power, power_ratio', my_power, enemy_power, power_ratio)

            local value_ratio = FU.cfg_default('value_ratio')
            --print('value_ratio', value_ratio)

            if (power_ratio < 0.75) then value_ratio = power_ratio end
            --print('value_ratio', value_ratio)

            if (value_ratio < 0.5) then value_ratio = 0.5 end
            --print('value_ratio', value_ratio)


            ----- Attack all remaining valid targets -----

            local zone_id = 'attack_all'

            -- This is needed throughout the code, just needs to be set to
            -- give unlimited resources here
            stage_status.contingency = 0
            stage_status[zone_id] = {
                power_missing = 0,
                power_needed = 0,
                power_used = 0,
                n_units_needed = 0,
                n_units_used = 0,
                units_used = {}
            }

            local attack_all_cfg = {
                zone_id = zone_id,
                stage_id = stage_id,
                actions = { attack = true },
                ignore_resource_limit = true,
                value_ratio = value_ratio
            }

            table.insert(fred.data.zone_cfgs, attack_all_cfg)



            ----- Retreat remaining injured units -----

            local zone_id = 'retreat'

            -- This is needed throughout the code, just needs to be set to
            -- give unlimited resources here
            stage_status.contingency = 0
            stage_status[zone_id] = {
                power_missing = 0,
                power_needed = 0,
                power_used = 0,
                n_units_needed = 0,
                n_units_used = 0,
                units_used = {}
            }

            local retreat_cfg = {
                zone_id = zone_id,
                stage_id = stage_id,
                actions = { retreat = true },
                ignore_resource_limit = true,
            }

            table.insert(fred.data.zone_cfgs, retreat_cfg)


            ----- Rush in east (hold and advance) -----
            local zone_id = 'all_map'

            -- This is needed throughout the code, just needs to be set to
            -- give unlimited resources here
            stage_status.contingency = 0
            stage_status[zone_id] = {
                power_missing = 0,
                power_needed = 0,
                power_used = 0,
                n_units_needed = 0,
                n_units_used = 0,
                units_used = {}
            }

            local retreat_cfg = {
                zone_id = zone_id,
                stage_id = stage_id,
                actions = {
--                    hold = true,
                    advance = true
                },
                ignore_resource_limit = true,
                value_ratio = value_ratio
            }

            table.insert(fred.data.zone_cfgs, retreat_cfg)

        end


        function fred:analyze_map(gamedata)
            -- Some pointers just for convenience
            local status = fred.data.analysis.status
            local stage_id = fred.data.analysis.stage_ids[fred.data.analysis.stage_counter]

            --print('Doing map analysis for stage: ' .. stage_id)

            if (not status[stage_id]) then
                status[stage_id] = {}
            end

            if (stage_id == 'leader_threat') then
                fred:analyze_leader_threat(gamedata)
                return
            end

            if (stage_id == 'defend_zones') then
                fred:analyze_defend_zones(gamedata)
                return
            end

            if (stage_id == 'all_map') then
                fred:analyze_all_map(gamedata)
                return
            end
        end


        ----- Functions for getting the best actions -----

        ----- Attack: -----
        function fred:get_attack_action(zonedata, gamedata, move_cache)
            if debug_eval then print_time('  --> attack evaluation: ' .. zonedata.cfg.zone_id) end
            --DBG.dbms(zonedata.cfg)

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
            --print('  #targets', #targets)
            --DBG.dbms(targets)

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
                if gamedata.unit_infos[target_id].skirmisher then
                    is_trappable_enemy = false
                end
                --print(target_id, '  trappable:', is_trappable_enemy, target_loc[1], target_loc[2])

                local attack_combos = FAU.get_attack_combos(
                    zonedata.zone_units_attacks, target, gamedata.reach_maps, false, move_cache, cfg_attack
                )
                --print_time('#attack_combos', #attack_combos)

                -- Check if this exceeds allowable resources
                -- For attacks, we allow use of power up to power_missing + contingency

                -- TODO: check: table.remove might be slow


                local allowable_power = 9e99
                if (not zonedata.cfg.ignore_resource_limit) then
                    local stage_status = fred.data.analysis.status[zonedata.cfg.stage_id] -- just for convenience for now
                    local power_missing = stage_status[zonedata.cfg.zone_id].power_missing
                    local contingency = stage_status.contingency

                    allowable_power = power_missing + contingency
                    --print('  Allowable power (power_missing + contingency ): ' .. power_missing .. ' + ' .. contingency .. ' = ' .. allowable_power)
                end

                for j = #attack_combos,1,-1 do
                    local combo = attack_combos[j]
                    local total_power = 0
                    for src,dst in pairs(combo) do
                        --print('    attacker power:', gamedata.unit_infos[attacker_map[src]].id, gamedata.unit_infos[attacker_map[src]].power)
                        total_power = total_power + gamedata.unit_infos[attacker_map[src]].power
                    end
                    --print('      total_power: ', j, total_power)

                    -- TODO: table.remove() can be slow
                    if (total_power > allowable_power) then
                        --print('      ----> eliminating this attack')
                        table.remove(attack_combos, j)
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


                    local combo_att_stats, combo_def_stat, sorted_atts, sorted_dsts,
                        combo_rating, combo_att_rating, combo_def_rating =
                        FAU.attack_combo_eval(
                            attacker_copies, target_proxy, dsts,
                            attacker_infos, gamedata.unit_infos[target_id],
                            gamedata, move_cache, cfg_attack
                    )
                    --DBG.dbms(combo_def_stat)
                    --print('   combo ratings:  ', combo_rating, combo_att_rating, combo_def_rating)

                    -- Don't attack if the leader is involved and has chance to die > 0
                    local do_attack = true

                    --print('     damage taken, done, value_ratio:', combo_att_rating, combo_def_rating, value_ratio)
                    -- Note: att_rating is the negative of the damage taken
                    if (not FAU.is_acceptable_attack(-combo_att_rating, combo_def_rating, value_ratio)) then
                        do_attack = false
                    end

                    -- Don't do this attack if the leader has a chance to get killed, poisoned or slowed
                    if do_attack then
                        for k,att_stat in ipairs(combo_att_stats) do
                            if (sorted_atts[k].canrecruit) then
                                if (att_stat.hp_chance[0] > 0.0) or (att_stat.slowed > 0.0) then
                                    do_attack = false
                                    break
                                end

                                if (att_stat.poisoned > 0.0) and (not sorted_atts[k].regenerate) then
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
                            local unit_value = FU.unit_value(gamedata.unit_infos[target_id])
                            local penalty = 10. / gamedata.unit_infos[target_id].max_hitpoints * unit_value
                            penalty = penalty * adj_unocc_village
                            --print('Applying village penalty', combo_rating, penalty)
                            combo_rating = combo_rating - penalty

                            -- In that case, also don't give the trapping bonus
                            attempt_trapping = false
                        end

                        -- Do not attempt trapping if the unit is on good terrain,
                        -- except if the target is down to less than half of its hitpoints
                        if (gamedata.unit_infos[target_id].hitpoints >= gamedata.unit_infos[target_id].max_hitpoints/2) then
                            local defense = FGUI.get_unit_defense(gamedata.unit_copies[target_id], target_loc[1], target_loc[2], gamedata.defense_maps)
                            if (defense >= 0.5) then
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
                                            if (defense >= 0.5) then
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
                                --print('Applying trapping bonus', combo_rating, bonus)
                                combo_rating = combo_rating + bonus
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
                                --print('Applying poisoner penalty', combo_rating, penalty)
                                combo_rating = combo_rating - penalty
                            end
                        end

                        --print_time(' -----------------------> rating', combo_rating)

                        table.insert(combo_ratings, {
                            rating = combo_rating,
                            attackers = sorted_atts,
                            dsts = sorted_dsts,
                            target = target,
                            att_stats = combo_att_stats,
                            def_stat = combo_def_stat,
                            att_rating = combo_att_rating,
                            def_rating = combo_def_rating,
                            value_ratio = value_ratio
                        })
                    end
                end
            end

            table.sort(combo_ratings, function(a, b) return a.rating > b.rating end)
            --DBG.dbms(combo_ratings)
            --print_time('#combo_ratings', #combo_ratings)

            -- Now check whether counter attacks are acceptable
            local max_total_rating, action = -9e99
            for count,combo in ipairs(combo_ratings) do
                if (count > 50) and action then break end

                --print_time('\nChecking counter attack for attack on', count, next(combo.target), combo.value_ratio, combo.rating)

                -- TODO: the following is slightly inefficient, as it places units and
                -- takes them off again several times for the same attack combo.
                -- This could be streamlined if it becomes an issue, but at the expense
                -- of either duplicating code or adding parameters to FAU.calc_counter_attack()
                -- I don't think that it is the bottleneck, so we leave it as it is for now.

                local old_locs, old_HP_attackers = {}, {}
                for i_a,attacker_info in ipairs(combo.attackers) do
                    table.insert(old_locs, gamedata.my_units[attacker_info.id])

                    -- Apply average hitpoints from the forward attack as starting point
                    -- for the counter attack.  This isn't entirely accurate, but
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
                local hp = combo.def_stat.average_hp
                if (hp < 0) then hp = 0 end

                gamedata.unit_infos[target_id].hitpoints = hp
                gamedata.unit_copies[target_id].hitpoints = hp
                target_proxy.hitpoints = hp

                local acceptable_counter = true

                local max_counter_rating = -9e99
                for i_a,attacker in ipairs(combo.attackers) do
                    --print_time('  by', attacker.id, combo.dsts[i_a][1], combo.dsts[i_a][2])

                    -- Now calculate the counter attack outcome
                    local attacker_moved = {}
                    attacker_moved[attacker.id] = { combo.dsts[i_a][1], combo.dsts[i_a][2] }

                    local counter_stats = FAU.calc_counter_attack(
                        attacker_moved, old_locs, combo.dsts, gamedata, move_cache, cfg_attack
                    )
                    --DBG.dbms(counter_stats)

                    local counter_rating = counter_stats.rating
                    local counter_att_rating = counter_stats.att_rating
                    local counter_def_rating = counter_stats.def_rating
                    local counter_chance_to_die = counter_stats.hp_chance[0]
                    --print_time('   counter ratings:', counter_rating, counter_att_rating, counter_def_rating, counter_chance_to_die)

                    if (counter_rating > max_counter_rating) then
                        max_counter_rating = counter_rating
                    end

                    local counter_min_hp = counter_stats.min_hp

                    -- We next check whether the counter attack is acceptable
                    -- This is different for the side leader and other units
                    -- Also, it is different for attacks by individual units without MP;
                    -- for those it simply matters whether the attack makes things
                    -- better or worse, since there isn't a coice of moving someplace else

                    if (#combo.attackers > 1) or (attacker.moves > 0) then
                        -- If there's a chance of the leader getting poisoned, slowed or killed, don't do it
                        if attacker.canrecruit then
                            --print('Leader: slowed, poisoned %', counter_stats.slowed, counter_stats.poisoned)
                            if (counter_stats.slowed > 0.0) then
                                acceptable_counter = false
                                break
                            end

                            if (counter_stats.poisoned > 0.0) and (not attacker.regenerate) then
                                acceptable_counter = false
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
                                acceptable_counter = false
                                break
                            end
                        else  -- Or for normal units, evaluate whether the attack is worth it
                            local damage_taken = - combo.att_rating + counter_def_rating
                            local damage_done = combo.def_rating - counter_att_rating
                            --print('     damage taken, done, value_ratio:', damage_taken, damage_done, combo.value_ratio)

    --                        if (counter_chance_to_die >= 0.5) then
    --                            acceptable_counter = false
    --                            break
    --                        end

                            if (not FAU.is_acceptable_attack(damage_taken, damage_done, combo.value_ratio)) then
                                acceptable_counter = false
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
                if (#combo.attackers == 1) then
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

                        local counter_rating = counter_stats.rating
                        local counter_att_rating = counter_stats.att_rating
                        local counter_def_rating = counter_stats.def_rating
                        local counter_chance_to_die = counter_stats.hp_chance[0]
                        --print_time('   counter ratings no attack:', counter_rating, counter_att_rating, counter_def_rating, counter_chance_to_die)

                        -- Rating if no forward attack is done is done is only the counter attack rating
                        local no_attack_rating = 0 - counter_rating
                        -- If an attack is done, it's the combined forward and counter attack rating
                        local with_attack_rating = combo.rating - max_counter_rating

                        --print('    V1: no attack rating :  ', no_attack_rating, '<---', 0, -counter_rating)
                        --print('    V2: with attack rating :', with_attack_rating, '<---', combo.rating, -max_counter_rating)

                        if (with_attack_rating < no_attack_rating) then
                            acceptable_counter = false
                        end
                        --print('acceptable_counter', acceptable_counter)
                    end
                end

                --print_time('  acceptable_counter', acceptable_counter)
                if acceptable_counter then
                    local total_rating = combo.rating - max_counter_rating
                    --print('    Acceptable counter attack for attack on', count, next(combo.target), combo.value_ratio, combo.rating)
                    --print('    rating, counter_rating, total_rating', combo.rating, max_counter_rating, total_rating)

                    if (total_rating > max_total_rating) then
                        max_total_rating = total_rating

                        action = { units = {}, dsts = {}, enemy = combo.target }

                        -- This is done simply so that the table is shorter when
                        -- displayed.  We could also simply use combo.attackers
                        for _,attacker in ipairs(combo.attackers) do
                            local tmp_unit = gamedata.my_units[attacker.id]
                            tmp_unit.id = attacker.id
                            table.insert(action.units, tmp_unit)
                        end

                        action.dsts = combo.dsts
                        action.action = 'attack'
                    end
                end
            end

            return action  -- returns nil is no acceptable attack was found
        end


        ----- Hold: -----
        function fred:get_hold_action(zonedata, gamedata, move_cache)
            if debug_eval then print_time('  --> hold evaluation: ' .. zonedata.cfg.zone_id) end
            --DBG.dbms(zonedata.cfg)

            --DBG.dbms(fred.data.analysis.status)

            local raw_cfg = fred:get_raw_cfgs(zonedata.cfg.zone_id)
            --DBG.dbms(raw_cfg)

            local holders = {}

            if zonedata.cfg.holders then
                holders = zonedata.cfg.holders
            else
                for id,_ in pairs(gamedata.my_units_MP) do
                    if (not gamedata.unit_infos[id].canrecruit) then
                        holders[id] = gamedata.unit_infos[id].power
                    end
                end
            end

            if (not next(holders)) then return end

            -- This part starts with a quick and dirt zone analysis for what
            -- *might* be the best positions.  This is calculated by assuming
            -- the same damage and strikes for all units, and calculating the
            -- damage for own and enemy units there based on terrain defense.
            -- In addition, values for the enemies are averaged over all units
            -- that can reach a hex.
            -- The assumption is that this will give us a good pre-selection of
            -- hexes, for which a more detailed analysis can then be done.

            local default_damage, default_strikes = 8, 2

            -- TODO: do this overall, rather than for this action?
            local zone = wesnoth.get_locations(raw_cfg.hold_slf)
            local zone_map = {}
            for _,loc in ipairs(zone) do
                if (not zone_map[loc[1]]) then
                    zone_map[loc[1]] = {}
                end
                zone_map[loc[1]][loc[2]] = true
            end
            --DBG.dbms(zone_map)


            -- Enemy rating map: average (over all enemy units) of damage received here
            -- Only use hexes the enemies can reach on this turn
            local enemy_rating_map = {}
            for x,tmp in pairs(zone_map) do
                for y,_ in pairs(tmp) do
                    local hex_rating, count = 0, 0
                    for enemy_id,etm in pairs(gamedata.enemy_turn_maps) do
                        local turns = etm[x] and etm[x][y] and etm[x][y].turns

                        if turns and (turns <= 1) then
                            local rating = FGUI.get_unit_defense(gamedata.unit_copies[enemy_id], x, y, gamedata.defense_maps)
                            rating = (1 - rating)  -- Probability of being hit

                            hex_rating = hex_rating + rating
                            count = count + 1.
                        end
                    end

                    if (count > 0) then
                        -- Average chance of being hit here
                        hex_rating = hex_rating / count

                        -- Average damage received:
                        hex_rating = hex_rating * default_damage * default_strikes

                        -- If this is a village, add 8 HP bonus
                        if gamedata.village_map[x] and gamedata.village_map[x][y] then
                            hex_rating = hex_rating - 8
                        end

                        if (not enemy_rating_map[x]) then enemy_rating_map[x] = {} end
                        enemy_rating_map[x][y] = { rating = hex_rating }
                    end
                end
            end

            local show_debug = false
            if show_debug then
                FU.put_fgumap_labels(enemy_rating_map, 'rating')
                W.message{ speaker = 'narrator', message = zonedata.cfg.zone_id .. ': enemy_rating_map' }
            end

            -- Need a map with the distances to the enemy and own leaders
            local leader_cx, leader_cy = AH.cartesian_coords(gamedata.leaders[wesnoth.current.side][1], gamedata.leaders[wesnoth.current.side][2])

            local enemy_leader_loc = {}
            for side,loc in ipairs(gamedata.leaders) do
                if wesnoth.is_enemy(side, wesnoth.current.side) then
                    enemy_leader_loc = loc
                    break
                end
            end
            local enemy_leader_cx, enemy_leader_cy = AH.cartesian_coords(enemy_leader_loc[1], enemy_leader_loc[2])

            local dist_btw_leaders = math.sqrt( (enemy_leader_cx - leader_cx)^2 + (enemy_leader_cy - leader_cy)^2 )

            local leader_distance_map = {}
            local width, height = wesnoth.get_map_size()
            for x = 1,width do
                for y = 1,width do
                    local cx, cy = AH.cartesian_coords(x, y)

                    local leader_dist = math.sqrt( (leader_cx - cx)^2 + (leader_cy - cy)^2 )
                    local enemy_leader_dist = math.sqrt( (enemy_leader_cx - cx)^2 + (enemy_leader_cy - cy)^2 )

                    if (not leader_distance_map[x]) then leader_distance_map[x] = {} end
                    leader_distance_map[x][y] = { distance = leader_dist - enemy_leader_dist }
                end
            end

            local show_debug = false
            if show_debug then
                FU.put_fgumap_labels(leader_distance_map, 'distance')
                W.message{ speaker = 'narrator', message = zonedata.cfg.zone_id .. ': leader_distance_map' }
            end

            -- First calculate a unit independent rating map
            -- For the time being, this is the just the enemy rating over all
            -- adjacent hexes that are closer to the enemy leader than the hex
            -- being evaluated.
            -- The assumption is that the enemies will be coming from there.
            -- TODO: evaluate when this might break down

            indep_rating_map = {}
            for x,tmp in pairs(zone_map) do
                for y,_ in pairs(tmp) do
                    local rating, adj_count = 0, 0

                    for xa,ya in H.adjacent_tiles(x, y) do
                        if leader_distance_map[xa][ya].distance >= leader_distance_map[x][y].distance then
                            local def_rating = enemy_rating_map[xa]
                                and enemy_rating_map[xa][ya]
                                and enemy_rating_map[xa][ya].rating

                            if def_rating then
                                rating = rating + def_rating
                                adj_count = adj_count + 1
                            end

                            if (not indep_rating_map[x]) then indep_rating_map[x] = {} end
                            indep_rating_map[x][y] = {
                                rating = rating,
                                adj_count = adj_count
                            }
                        end
                    end
                end
            end

            local show_debug = false
            if show_debug then
                FU.put_fgumap_labels(indep_rating_map, 'rating')
                W.message { speaker = 'narrator', message = 'Hold zone ' .. zonedata.cfg.zone_id .. ': unit-independent rating map: rating' }
                FU.put_fgumap_labels(indep_rating_map, 'adj_count')
                W.message { speaker = 'narrator', message = 'Hold zone ' .. zonedata.cfg.zone_id .. ': unit-independent rating map: adjacent count' }
            end

            -- Now we go on to the unit-dependent rating part
            -- This is the same type of rating as for enemies, but done individually
            -- for each AI unit, rather than averaged of all units for each hex

            -- This will hold the rating maps for all units
            local unit_rating_maps = {}

            for id,loc in pairs(holders) do
                local max_rating_unit, best_hex_unit = -9e99, {}

                unit_rating_maps[id] = {}

                for x,tmp in pairs(gamedata.reach_maps[id]) do
                    for y,_ in pairs(tmp) do
                        -- Only count hexes that enemies can attack
                        local adj_count = (indep_rating_map[x]
                            and indep_rating_map[x][y]
                            and indep_rating_map[x][y].adj_count
                        )

                        if adj_count and (adj_count > 0) then
                            -- Chance of being hit here
                            local defense = FGUI.get_unit_defense(gamedata.unit_copies[id], x, y, gamedata.defense_maps)
                            defense = 1 - defense

                            -- Base rating is negative of damage received:
                            local unit_damage = defense * default_damage * default_strikes

                            -- This needs to be multiplied by the number of enemies
                            -- which can attack here
                            unit_damage = unit_damage * adj_count

                            local unit_rating = - unit_damage + indep_rating_map[x][y].rating

                            -- If this is a village, add 8 HP bonus
                            if gamedata.village_map[x] and gamedata.village_map[x][y] then
                                 unit_rating = unit_rating + 8
                            end

                            if (not unit_rating_maps[id][x]) then unit_rating_maps[id][x] = {} end
                            unit_rating_maps[id][x][y] = { rating = unit_rating }
                        end
                    end
                end

                show_debug = false
                if show_debug then
                    FU.put_fgumap_labels(unit_rating_maps[id], 'rating')
                    wesnoth.add_tile_overlay(gamedata.units[id][1], gamedata.units[id][2], { image = "items/orcish-flag.png" })
                    W.message { speaker = 'narrator', message = 'Hold zone: unit-specific rating map: ' .. id }
                    wesnoth.remove_tile_overlay(gamedata.units[id][1], gamedata.units[id][2], { image = "items/orcish-flag.png" })
                end
            end

            -- Next, we do a more detailed single-unit analysis for the best
            -- hexes found in the preselection for each unit

            local new_unit_ratings, rated_units = {}, {}
            local max_hexes_pre = 20 -- number of hexes to analyze for units individually
            local max_hexes = 6 -- number of hexes per unit for placement combos

            -- Need to make sure that the same weapons are used for all counter attack calculations
            local cfg_counter_attack = { use_max_damage_weapons = true }

            for id,unit_rating_map in pairs(unit_rating_maps) do
                -- Need to extract the map into a sortable format first
                -- TODO: this is additional overhead that can be removed later
                -- when the maps are not needed any more

                local unit_ratings = {}
                for x,tmp in pairs(unit_rating_map) do
                    for y,r in pairs(tmp) do
                        table.insert(unit_ratings, {
                            rating = r.rating,
                            x = x, y = y
                        })
                    end
                end

                table.sort(unit_ratings, function(a, b) return a.rating > b.rating end)

                -- Calculate counter attack ratings for the best hexes previously
                -- found and use those as the new rating
                n_hexes = math.min(max_hexes_pre, #unit_ratings)
                new_unit_ratings[id] = {}
                for i = 1,n_hexes do
                    local old_locs = {
                        { gamedata.unit_copies[id].x, gamedata.unit_copies[id].y }
                    }

                    local new_locs = {
                        { unit_ratings[i].x, unit_ratings[i].y }
                    }

                    local target = {}
                    target[id] = { unit_ratings[i].x, unit_ratings[i].y }
                    local counter_stats, counter_attack = FAU.calc_counter_attack(target, old_locs, new_locs, gamedata, move_cache, cfg_counter_attack)
                    --print(id, unit_ratings[i].rating, -counter_stats.rating, unit_ratings[i].x, unit_ratings[i].y)
                    --DBG.dbms(counter_stats)
                    --DBG.dbms(counter_attack)
                    --W.message { speaker = 'narrator', message = 'counter stats' }

                    -- Important: the counter_stats rating is the rating of the
                    -- counter attack. We want this to be as *bad* as possible
                    table.insert(new_unit_ratings[id], {
                        rating = - counter_stats.rating,
                        x = unit_ratings[i].x,
                        y = unit_ratings[i].y
                    })
                end

                unit_ratings = nil -- so that we don't accidentally use it any more

                table.sort(new_unit_ratings[id], function(a, b) return a.rating > b.rating end)
                --DBG.dbms(new_unit_ratings)

                -- We also identify the best units; which are those with the highest
                -- sum of the best ratings (only those to be used for the next step)
                -- TODO: possibly refine this?

                local sum_best_ratings = 0
                n_hexes = math.min(max_hexes, #new_unit_ratings[id])
                for i = 1,n_hexes do
                    --print(id, new_unit_ratings[id][i].rating, new_unit_ratings[id][i].x, new_unit_ratings[id][i].y)
                    sum_best_ratings = sum_best_ratings + new_unit_ratings[id][i].rating
                end
                --print('  total rating: ', sum_best_ratings, id)

                table.insert(rated_units, { id = id, rating = sum_best_ratings })
            end

            -- Exclude units that have no reachable qualified hexes
            for i_ru = #rated_units,1,-1 do
                local id = rated_units[i_ru].id
                if (#new_unit_ratings[id] == 0) then
                    table.remove(rated_units, i_ru)
                end
            end

            if (#rated_units == 0) then
                return
            end

            -- Sorting this will now give us the order of units to be considered
            table.sort(rated_units, function(a, b) return a.rating > b.rating end)

            -- For holding, we are allowed to add units until we are above
            -- the limit given by power_missing (without taking contingency into account)
            local power_missing = 9e99
            if (not zonedata.cfg.ignore_resource_limit) then
                local stage_status = fred.data.analysis.status[zonedata.cfg.stage_id] -- just for convenience for now
                power_missing = stage_status[zonedata.cfg.zone_id].power_missing
            end
            --print('  power_missing', power_missing)

            local n_units = math.min(3, #rated_units)
            --print('n_units', n_units)

            -- TODO: limit power after calculating combos, rather than before?
            local ids, n_hexes = {}, {}
            local total_power = 0
            for i = 1,n_units do
                local id = rated_units[i].id
                table.insert(ids, id)

                table.insert(n_hexes, math.min(max_hexes, #new_unit_ratings[id]))

                total_power = total_power + gamedata.unit_infos[id].power
                --print('  ' .. id, gamedata.unit_infos[id].power, total_power)

                if (total_power > power_missing) then
                    break
                end
            end

            local n_units = #ids
            --print('n_units', n_units)
            --DBG.dbms(ids)
            --DBG.dbms(n_hexes)


            -- Use recursive function to get all the combinations
            local layer = 1
            local combo, combos = {}, {}

            -- This is the recursive function
            -- Uses variables by closure
            local function hex_combos()
                for i = 0,n_hexes[layer] do
                    local id = ids[layer]
                    local xy
                    if (i ~= 0) then
                        local x = new_unit_ratings[id][i].x
                        local y = new_unit_ratings[id][i].y
                        xy = x * 1000 + y
                    else
                        xy = 0
                    end

                    if (not combo[xy]) then
                        if (xy ~= 0) then
                            combo[xy] = id
                        end

                        if (layer < n_units) then
                            layer = layer + 1
                            hex_combos()
                        else
                            if next(combo) then  -- To eliminate the empty combination
                                local tmp = AH.table_copy(combo)
                                table.insert(combos, tmp)
                            end
                        end

                        combo[xy] = nil  -- This can be done even if xy == 0
                    end
                end
                layer = layer - 1
            end

            -- And here is where we call the recursive functions
            hex_combos()
            --DBG.dbms(combos)

            -- Count the number of holders in the largest combo.
            -- We prefer combos using the maximum number, even if the overall
            -- rating is lower than for fewer units. Only when none of the
            -- max. number combos are acceptable do we use fewer units.
            local max_holders = 0
            for _,combo in pairs(combos) do
                local n_holders = 0
                for xy,id in pairs(combo) do
                    n_holders = n_holders + 1
                end

                if (n_holders > max_holders) then
                    max_holders = n_holders
                end
            end
            --print('max_holders', max_holders)

            -- Finally, rate all the combos
            local best_combos = {}
            for i = 1,max_holders do
                best_combos[i] = { max_rating = -9e99 }
            end

            for _,combo in ipairs(combos) do
                local old_locs, new_locs = {}, {}
                --print('Combo ' .. _)
                for xy,id in pairs(combo) do
                    local x, y =  math.floor(xy / 1000), xy % 1000
                    --print('  ', id, x, y)

                    table.insert(old_locs, { gamedata.unit_copies[id].x, gamedata.unit_copies[id].y })
                    table.insert(new_locs, { x, y })
                end
                --DBG.dbms(old_locs)
                --DBG.dbms(new_locs)

                local n_holders = 0
                local is_acceptable = true
                local rating, counter_attack_rating = 0, 0
                for xy,id in pairs(combo) do
                    n_holders = n_holders + 1
                    local target = {}
                    local x, y =  math.floor(xy / 1000), xy % 1000

                    target[id] = { x, y }
                    local counter_stats, counter_attack = FAU.calc_counter_attack(target, old_locs, new_locs, gamedata, move_cache, cfg_counter_attack)
                    --DBG.dbms(counter_stats)
                    --DBG.dbms(counter_attack)

                    -- If this is a shielded position, don't use this combo
                    if (not (next(counter_attack))) then
                        --print('  not acceptable because unit cannot be reached by enemy')
                        is_acceptable = false
                        break
                    end

                    local hit_chance = FGUI.get_unit_defense(gamedata.unit_copies[id], x, y, gamedata.defense_maps)
                    hit_chance = 1 - hit_chance

                    -- If this is a village, give a bonus
                    -- TODO: do this more quantitatively
                    if gamedata.village_map[x] and gamedata.village_map[x][y] then
                        hit_chance = hit_chance - 0.15
                        if (hit_chance < 0) then hit_chance = 0 end
                    end

                    --print('  ' .. id, x, y, hit_chance)

                    -- If chance to die is too large, also do not use this position
                    -- This is dependent on how good the terrain is
                    -- For better terrain we allow a higher hit_chance than for bad terrain
                    -- The argument is that we want to be on the good terrain, whereas
                    -- taking a stance on bad terrain might not be worth it
                    -- TODO: what value is good here?
                    if (hit_chance > 0.5) then -- bad terrain
                        if (counter_stats.hp_chance[0] > 0) then
                            --print('  not acceptable because chance to die too high:', counter_stats.hp_chance[0])
                            is_acceptable = false
                            break
                        end
                        -- TODO: not sure yet if this should be used
                        -- Also if the relative loss is more than X HP (X/12 the
                        -- value of a grunt) for any single attack
                        if (counter_stats.rating >= 9) then
                            --print('  not acceptable because chance to die too high:', counter_stats.hp_chance[0])
                            is_acceptable = false
                            break
                        end
                    else -- at least 50% defense
                        if (counter_stats.hp_chance[0] >= 0.25) then
                            --print('  not acceptable because chance to die too high:', counter_stats.hp_chance[0])
                            is_acceptable = false
                            break
                        end
                    end

                    local enemy_rating, count = 0, 0
                    for src,dst in pairs(counter_attack) do
                        local old = { math.floor(src / 1000), src % 1000 }
                        local new = { math.floor(dst / 1000), dst % 1000 }
                        local enemy_id = gamedata.enemy_map[old[1]][old[2]].id
                        --print('  enemy:', enemy_id, old[1], old[2], new[1], new[2])

                        local enemy_hc = FGUI.get_unit_defense(gamedata.unit_copies[enemy_id], new[1], new[2], gamedata.defense_maps)
                        enemy_hc = 1 - enemy_hc

                        -- If this is a village, give a bonus
                        -- TODO: do this more quantitatively
                        if gamedata.village_map[new[1]] and gamedata.village_map[new[1]][new[2]] then
                            enemy_hc = enemy_hc - 0.15
                            if (enemy_hc < 0) then enemy_hc = 0 end
                        end

                        --print('    enemy_hc:', enemy_hc)

                        enemy_rating = enemy_rating + enemy_hc^2 - hit_chance^2
                        count = count + 1
                    end
                    enemy_rating = enemy_rating / count
                    --print('      --> enemy_rating', enemy_rating)

                    -- We also add a very small contribution from the counter
                    -- attack rating, as lots of option can otherwise be equal
                    -- This needs to be multiplied be a small number.  enemy_rating
                    -- often varies by .01 or so
                    -- Important: the counter_stats rating is the rating of the
                    -- counter attack. We want this to be as *bad* as possible
                    counter_attack_rating = - counter_stats.rating / 1000.
                    --print('      --> counter_attack_rating', counter_attack_rating)

                    rating = rating + enemy_rating + counter_attack_rating
                end
                --print('  --> rating:', rating)

                -- If this has negative rating, check whether it is acceptable after all
                -- For now we always consider these unacceptable
                -- Note: only the enemy_rating contributions count here, not
                -- the part in counter_attack_rating
                if (rating < counter_attack_rating - 1e-8) then
                    --print('  Hold has negative rating; checking for acceptability')
                    is_acceptable = false
                end

                --print('      is_acceptable', is_acceptable)

                -- We want to exclude combinations where one unit is out of attack range
                -- as this is for holding a zone, not protecting units.
                if is_acceptable and (rating > best_combos[n_holders].max_rating) then
                    best_combos[n_holders].max_rating = rating
                    best_combos[n_holders].best_hexes = new_locs

                    best_combos[n_holders].best_units = {}
                    for xy,id in pairs(combo) do
                        table.insert(best_combos[n_holders].best_units, gamedata.unit_infos[id])
                    end
                end
            end
            --DBG.dbms(best_combos)

            for i=max_holders,1,-1 do
                if best_combos[i].best_units then
                    --print('****** Found hold action:')
                    local action = {
                        units = {},
                        dsts = best_combos[i].best_hexes
                    }

                    -- This is done simply so that the table is shorter when
                    -- displayed.  We could also simply use combo.attackers
                    for _,unit in ipairs(best_combos[i].best_units) do
                    local tmp_unit = gamedata.my_units[unit.id]
                        tmp_unit.id = unit.id
                        table.insert(action.units, tmp_unit)
                    end

                    action.action = zonedata.cfg.zone_id .. ': ' .. 'hold position'
                    return action
                end
            end
        end


        ----- Advance: -----
        function fred:get_advance_action(zonedata, gamedata, move_cache)
            if debug_eval then print_time('  --> advance evaluation: ' .. zonedata.cfg.zone_id) end
            --DBG.dbms(zonedata.cfg)
            local raw_cfg = fred:get_raw_cfgs(zonedata.cfg.zone_id)
            --DBG.dbms(raw_cfg)
            --DBG.dbms(gamedata.village_map)

            --DBG.dbms(gamedata.my_units_MP)
            --DBG.dbms(gamedata.enemy_attack_map[1])

            -- Select only the units specified in raw_cfg.unit_filter_advance
            -- If that table is missing, it matches all units
            local advance_units = {}
            for id,loc in pairs(gamedata.my_units_MP) do
                if wesnoth.match_unit(gamedata.unit_copies[id], raw_cfg.unit_filter_advance) then
                    --print('  matches unit_filter_advance in zone ' .. zonedata.cfg.zone_id, id)
                    advance_units[id] = loc
                end
            end

            -- Don't need to enforce a resource limit here, as this is one
            -- unit at a time.  It will be checked before the action is called.

            local max_rating, best_unit, best_hex = -9e99
            local reachable_villages = {}
            for id,loc in pairs(advance_units) do
                reachable_villages[id] = {}

                -- The leader only participates in village grabbing, and
                -- that only if he is on the keep
                local is_leader = gamedata.unit_infos[id].canrecruit
                local not_leader_or_leader_on_keep =
                    (not is_leader)
                    or wesnoth.get_terrain_info(wesnoth.get_terrain(gamedata.units[id][1], gamedata.units[id][2])).keep
                --print(id, is_leader, not_leader_or_leader_on_keep)

                -- TODO: change retreat.lua so that it uses the gamedata tables
                local min_hp = R.min_hp(gamedata.unit_copies[id])
                local must_retreat = gamedata.unit_copies[id].hitpoints < min_hp
                --print(id, min_hp, must_retreat)

                local unit_rating_map = {}
                for x,tmp in pairs(gamedata.reach_maps[id]) do
                    for y,_ in pairs(tmp) do
                        -- TODO: remove this once we know that it is really not needed any more
                        -- only consider unthreatened hexes
                        --local threat = FU.get_fgumap_value(gamedata.enemy_attack_map[1], x, y, 'power')

                        local zone_rating = fred:zone_advance_rating(zonedata.cfg.zone_id, x, y, gamedata)
                        if zone_rating then
                            local rating

                            local hit_chance = FGUI.get_unit_defense(gamedata.unit_copies[id], x, y, gamedata.defense_maps)
                            hit_chance = 1 - hit_chance
                            --print('  ' .. id, x, y, hit_chance)

                            -- If this is a village, give a bonus
                            -- TODO: do this more quantitatively
                            if gamedata.village_map[x] and gamedata.village_map[x][y] then
                                hit_chance = hit_chance - 0.15
                                if (hit_chance < 0) then hit_chance = 0 end
                            end

                            -- Village owner; set to 0 for unowned villages
                            local owner = FU.get_fgumap_value(gamedata.village_map, x, y, 'owner')

                            if (not is_leader) and (not must_retreat) and (not zonedata.cfg.villages_only) then
                                -- Want to use faster units preferentially
                                rating = zone_rating + gamedata.unit_infos[id].max_moves

                                -- All else being equal, use the more powerful unit
                                rating = rating + gamedata.unit_infos[id].power / 100.

                                -- Add very minor penalty for the terrain
                                rating = rating - hit_chance / 1000

                                -- Own villages that can be reached by an enemy get a big bonus
                                if owner and (owner == wesnoth.current.side) then
                                    local enemies_in_reach = 0

                                    -- TODO: might want to set up an enemy_move_map
                                    for id,_ in pairs(gamedata.enemies) do
                                        if FU.get_fgumap_value(gamedata.reach_maps[id], x, y, 'moves_left') then
                                            enemies_in_reach = enemies_in_reach + 1
                                        end
                                    end
                                    --print(x,y,enemies_in_reach)

                                    rating = rating + 10 * enemies_in_reach
                                end

                                -- Penalty for hexes adjacent to villages the enemy can reach
                                -- TODO: do we want a adjacent_to_villages_map?
                                -- Potential TODO: in principle this should be calculated
                                -- for the situation _after_ the unit moves, but that
                                -- might be too costly
                                for xa,ya in H.adjacent_tiles(x,y) do
                                    if FU.get_fgumap_value(gamedata.village_map, xa, ya, 'owner') then
                                        local enemies_in_reach = 0

                                        -- TODO: might want to set up an enemy_move_map
                                        for id,_ in pairs(gamedata.enemies) do
                                            if FU.get_fgumap_value(gamedata.reach_maps[id], xa, ya, 'moves_left') then
                                                enemies_in_reach = enemies_in_reach + 1
                                            end
                                        end

                                        if (enemies_in_reach > 0) then
                                            rating = rating - 100
                                        end
                                    end
                                end
                            end

                            -- Unowned and enemy_owned villages are much preferred
                            -- and get a very different rating
                            -- This part is also done for the leader
                            -- and for severely injured units
                            -- Retreating injured units to AI owned and other safe
                            -- locations is done separately (TODO: reconsider that)

                            local is_priority_village = not_leader_or_leader_on_keep and owner and (owner ~= wesnoth.current.side)

                            if is_priority_village then
                                if (owner == 0) then
                                    rating = 1000
                                else
                                    rating = 2000
                                end

                                -- In this case, farther back in the zone is better
                                rating = rating - zone_rating

                                -- Want the most seriously injured units
                                local dhp = gamedata.unit_infos[id].max_hitpoints - gamedata.unit_infos[id].hitpoints

                                if is_leader then
                                    dhp = dhp * 2  -- damage to leader counts double
                                    dhp = dhp + 1  -- prefer leader, all else being equal
                                end

                                rating = rating + dhp

                                -- And more urgency to poisoned units
                                -- This is intentionally set to 12 = 8 * 1.5
                                if gamedata.unit_copies[id].status.poisoned then
                                    rating = rating + 12
                                end

                                -- Finally, the faster unit is again preferred,
                                -- but in this case that's a minor rating
                                rating = rating + gamedata.unit_infos[id].max_moves / 100
                            end

                            -- Now check whether the counter attack is acceptable
                            -- This is expensive, so only done if rating is largest
                            -- to date, but:
                            -- All priority villages need to be considered, as they
                            -- are re-evaluated later
                            local is_acceptable = true
                            if rating and ((rating > max_rating) or is_priority_village) then
                                --print('Checking if location is acceptable', x, y)

                                local old_locs = { { loc[1], loc[2] } }
                                local new_locs = { { x, y } }
                                --DBG.dbms(old_locs)
                                --DBG.dbms(new_locs)

                                local target = {}
                                target[id] = { x, y }
                                local counter_stats, counter_attack = FAU.calc_counter_attack(target, old_locs, new_locs, gamedata, move_cache, cfg_counter_attack)
                                --DBG.dbms(counter_stats)

                                -- If chance to die is too large, do not use this position
                                -- This is dependent on how good the terrain is
                                -- For better terrain we allow a higher chance to die than for bad terrain
                                -- The rationale is that we want to be on the good terrain, whereas
                                -- taking a stance on bad terrain might not be worth it
                                -- TODO: what value is good here?
                                if (hit_chance > 0.5) then -- bad terrain
                                    if (counter_stats.hp_chance[0] > 0) then
                                        --print('  not acceptable because chance to die too high (bad terrain):', counter_stats.hp_chance[0])
                                        is_acceptable = false
                                    end
                                    -- TODO: not sure yet if this should be used
                                    -- Also if the relative loss is more than X HP (X/12 the
                                    -- value of a grunt) for any single attack
                                    if (counter_stats.rating >= 9) then
                                        --print('  not acceptable because counter attack rating too bad:', counter_stats.rating)
                                        is_acceptable = false
                                    end
                                else -- at least 50% defense
                                    if (counter_stats.hp_chance[0] >= 0.25) then
                                        --print('  not acceptable because chance to die too high (good terrain):', counter_stats.hp_chance[0])
                                        is_acceptable = false
                                    end
                                end
                            end

                            -- If this is an enemy owned or unowned village, we need to
                            -- store all of those hexes for re-evaluation
                            if is_priority_village and rating and is_acceptable then
                                table.insert(reachable_villages[id], { x, y, rating = rating })
                            end

                            -- This is just for displaying purposes (unit_rating_map)
                            -- Has no effect on evaluation
                            if rating and (not is_acceptable) then
                                rating = -1000
                            end

                            if is_acceptable and rating and (rating > max_rating) then
                                max_rating = rating
                                best_unit = gamedata.my_units[id]
                                best_unit.id = id
                                best_hex = { x, y }
                            end

                            if rating then
                                FU.set_fgumap_value(unit_rating_map, x, y, 'rating', rating)
                            end
                        end
                    end
                end

                show_debug = false
                if show_debug then
                    FU.put_fgumap_labels(unit_rating_map, 'rating')
                    wesnoth.add_tile_overlay(gamedata.units[id][1], gamedata.units[id][2], { image = "items/orcish-flag.png" })
                    W.message { speaker = 'narrator', message = 'Advance zone: unit-specific rating map: ' .. id }
                    wesnoth.remove_tile_overlay(gamedata.units[id][1], gamedata.units[id][2], { image = "items/orcish-flag.png" })
                end
            end

            -- All enemy-owned and unowned villages are reconsidered now.
            -- The goal is to make sure that the units capture as many villages
            -- as possible -- a unit that can take two villages should not
            -- take priority over another unit that can only get to one village.
            -- This is done by adding a dummy bonus to the rating that is the
            -- larger the fewer villages a unit can get to.
            -- There are probably situations in which this is not the best way
            -- to do this, but for a map like Freelands it should work well enough.
            local max_rating_vill, best_unit_vill, best_hex_vill = -9e99
            for id,locs in pairs(reachable_villages) do
                local dummy_bonus = 10000 / #locs

                for _,loc in ipairs(locs) do
                    local rating = loc.rating + dummy_bonus

                    if (rating > max_rating_vill) then
                        max_rating_vill = rating
                        best_unit_vill = gamedata.my_units[id]
                        best_unit_vill.id = id
                        best_hex_vill = { loc[1], loc[2] }
                    end
                end
            end

            if best_unit_vill then
                best_unit = best_unit_vill
                best_hex = best_hex_vill
            end

            if best_unit then
                --print('****** Found advance action:')
                local action = { units = { best_unit }, dsts = { best_hex } }
                action.action = zonedata.cfg.zone_id .. ': ' .. 'advance'
                return action
            end
        end


        ----- Retreat: -----
        function fred:get_retreat_action(zonedata, gamedata)
            if debug_eval then print_time('  --> retreat evaluation: ' .. zonedata.cfg.zone_id) end

            -- This is a placeholder for when (if) retreat.lua gets adapted to the new
            -- tables also.  It might not be necessary, it's fast enough the way it is
            local retreat_units = {}
            for id,_ in pairs(zonedata.zone_units_MP) do
                table.insert(retreat_units, gamedata.unit_copies[id])
            end

            local unit, dest, enemy_threat = R.retreat_injured_units(retreat_units)
            if unit then
                local allowable_retreat_threat = zonedata.cfg.allowable_retreat_threat or 0
                --print_time('Found unit to retreat:', unit.id, enemy_threat, allowable_retreat_threat)
                -- Is this a healing location?
                local healloc = false
                if (dest[3] > 2) then healloc = true end
                local action = { units = { unit }, dsts = { dest }, type = 'village' }
                action.action = zonedata.cfg.zone_id .. ': ' .. 'retreat severely injured units'
                return action, healloc, (enemy_threat <= allowable_retreat_threat)
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
            print('\n***********************************************************')
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
            print('***********************************************************')
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
        function fred:move_leader_to_keep_eval()
            local score = 480000
            local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'move_leader_to_keep'
            if debug_eval then print_time('     - Evaluating move_leader_to_keep CA:') end

            local leader = fred.data.gamedata.leaders[wesnoth.current.side]

            -- If the leader cannot move, don't do anything
            if fred.data.gamedata.my_units_noMP[leader.id] then
                AH.done_eval_messages(start_time, ca_name)
                return 0
            end

            -- If the leader already is on a keep, don't do anything
            if (wesnoth.get_terrain_info(wesnoth.get_terrain(leader[1], leader[2])).keep) then
                AH.done_eval_messages(start_time, ca_name)
                return 0
            end

            local leader_copy = fred.data.gamedata.unit_copies[leader.id]

            local enemy_leader_loc = {}
            for side,loc in ipairs(fred.data.gamedata.leaders) do
                if wesnoth.is_enemy(side, wesnoth.current.side) then
                    enemy_leader_loc = loc
                    break
                end
            end
            local enemy_leader_cx, enemy_leader_cy = AH.cartesian_coords(enemy_leader_loc[1], enemy_leader_loc[2])

            local width,height,border = wesnoth.get_map_size()
            local keeps = wesnoth.get_locations {
                terrain = 'K*,K*^*,*^K*', -- Keeps
                x = '1-'..width,
                y = '1-'..height
            }

            local max_rating, best_keep = -10  -- Intentionally not set to less than this !!
                                               -- so that the leader does not try to get to unreachable locations
            for _,keep in ipairs(keeps) do
                local unit_in_way = fred.data.gamedata.my_unit_map_noMP[keep[1]]
                    and fred.data.gamedata.my_unit_map_noMP[keep[1]][keep[2]]

                if (not unit_in_way) then
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

            -- If the leader can reach the keep, but there's a unit on it: wait
            if fred.data.gamedata.reach_maps[leader.id][best_keep[1]]
                and fred.data.gamedata.reach_maps[leader.id][best_keep[1]][best_keep[2]]
                and fred.data.gamedata.my_unit_map_MP[best_keep[1]]
                and fred.data.gamedata.my_unit_map_MP[best_keep[1]][best_keep[2]]
            then
                return 0
            end

            if best_keep then
                local next_hop = AH.next_hop(leader_copy, best_keep[1], best_keep[2])

                -- Only move the leader if he'd actually move
                if (next_hop[1] ~= leader_copy.x) or (next_hop[2] ~= leader_copy.y) then
                    fred.data.MLK_leader = leader_copy
                    fred.data.MLK_keep = best_keep
                    fred.data.MLK_dst = next_hop

                    AH.done_eval_messages(start_time, ca_name)
                    return score
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
        function fred:get_zone_action(cfg, gamedata, move_cache)
            -- Find the best action to do in the zone described in 'cfg'
            -- This is all done together in one function, rather than in separate CAs so that
            --  1. Zones get done one at a time (rather than one CA at a time)
            --  2. Relative scoring of different types of moves is possible

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
                local action, healloc, safeloc = fred:get_retreat_action(zonedata, gamedata)
                if action then
                    --print(action.action)
                    return action
                end
            end

            -- **** Attack evaluation ****
            if (cfg.actions.attack) then
                --print_time('  ' .. cfg.zone_id .. ': attack eval')
                local action = fred:get_attack_action(zonedata, gamedata, move_cache)
                if action then
                    --print(action.action)
                    return action
                end
            end

            -- **** Hold position evaluation ****
            if (cfg.actions.hold) then
                --print_time('  ' .. cfg.zone_id .. ': hold eval')
                local action = fred:get_hold_action(zonedata, gamedata, move_cache)
                if action then
                    --print_time(action.action)
                    return action
                end
            end

            -- **** Advance in zone evaluation ****
            if (cfg.actions.advance) then
                --print_time('  ' .. cfg.zone_id .. ': advance eval')
                local action = fred:get_advance_action(zonedata, gamedata, move_cache)
                if action then
                    --print_time(action.action)
                    return action
                end
            end

            return nil  -- This is technically unnecessary, just for clarity
        end


        function fred:zone_control_eval()
            local score_zone_control = 350000
            local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'zone_control'

            if debug_eval then print_time('     - Evaluating zone_control CA:') end

            if (not fred.data.analysis) or (fred.data.analysis.turn ~= wesnoth.current.turn) then
                fred.data.analysis = {
                    turn = wesnoth.current.turn,
                    stage_counter = 1,
                    --stage_ids = { 'leader_threat', 'defend_zones' },
                    stage_ids = { 'leader_threat', 'defend_zones', 'all_map' },
                    --stage_ids = { 'defend_zones' },
                    status = { units_used = {} }
                }
            end
            local FDA = fred.data.analysis -- just for convenience

            while 1 do
                if (FDA.stage_counter > #FDA.stage_ids) then
                    --print(FDA.stage_counter, #FDA.stage_ids)
                    if debug_eval then print('--> done with all stages') end

                    -- Reset stage counter for each evaluation
                    -- This makes the stage system somewhat pointless
                    -- TODO: reconsider if this should be done or not
                    FDA.stage_counter = 1

                    return 0
                end

                local stage_id = FDA.stage_ids[FDA.stage_counter]
                if debug_eval then print('\nStage: ' .. stage_id) end


                fred:analyze_map(fred.data.gamedata)
                --DBG.dbms(FDA.status)

                --DBG.dbms(fred.data.zone_cfgs)

                for i_c,cfg in ipairs(fred.data.zone_cfgs) do
                    --print()
                    --print('-----------------------------------')
                    --print_time('zone_control: ', cfg.zone_id, cfg.stage_id)
                    --for action,_ in pairs(cfg.actions) do print('  --> ' .. action) end
                    --DBG.dbms(cfg)

                    local power_used = FDA.status[stage_id][cfg.zone_id].power_used
                    local power_needed = FDA.status[stage_id][cfg.zone_id].power_needed
                    local power_missing = FDA.status[stage_id][cfg.zone_id].power_missing
                    local n_units_needed = FDA.status[stage_id][cfg.zone_id].n_units_needed
                    local n_units_used = FDA.status[stage_id][cfg.zone_id].n_units_used

                    -- !!! Note that power_missing is not necessarily power_needed - power_used !!!
                    --print('  power used, needed, missing:', power_used, power_needed, power_missing)
                    --print('  n_units_used, needed:', n_units_used, n_units_needed)

                    -- Also need to check whether we have enough units for
                    -- village grabbing
                    if cfg.ignore_resource_limit
                        or ((power_missing > 0) or (n_units_needed > n_units_used))
                    then
                        -- Extract all AI units with MP left (for enemy path finding, counter attack placement etc.)
                        local extracted_units = {}
                        for id,loc in pairs(fred.data.gamedata.my_units_MP) do
                            local unit_proxy = wesnoth.get_unit(loc[1], loc[2])
                            wesnoth.extract_unit(unit_proxy)
                            table.insert(extracted_units, unit_proxy)  -- Not a proxy unit any more at this point
                        end

                        local zone_action = fred:get_zone_action(cfg, fred.data.gamedata, fred.data.move_cache)

                        for _,extracted_unit in ipairs(extracted_units) do wesnoth.put_unit(extracted_unit) end

                        if zone_action then
                            zone_action.zone_id = cfg.zone_id
                            zone_action.stage_id = cfg.stage_id
                            --DBG.dbms(zone_action)
                            fred.data.zone_action = zone_action
                            AH.done_eval_messages(start_time, ca_name)
                            return score_zone_control
                        end
                    else
                        --print('  --> power used already greater than power needed:', power_used, power_needed, power_missing)
                    end
                end

                -- If we get here, this means no action was found for this stage
                -- --> reset the zone_cfgs, so that they will be recalculate
                --     and up the counter
                fred.data.zone_cfgs = nil
                FDA.stage_counter = FDA.stage_counter + 1

                if debug_eval then print('--> done with all cfgs of this stage') end
            end

            AH.done_eval_messages(start_time, ca_name)
            return 0
        end

        function fred:zone_control_exec()
            local action = fred.data.zone_action.zone_id .. ': ' .. fred.data.zone_action.action
            --DBG.dbms(fred.data.zone_action)

            -- Same for the enemy in an attack, which is returned in { id = { x, y } } format.
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
                -- out of the way.  It is also possible that units that are supposed to
                -- move out of the way cannot actually do so in practice.  Abandon the move
                -- and reevaluate in that case. However, we can only do this if the gamestate
                -- has actually be changed already, or the CA will be blacklisted
                if gamestate_changed then
                    -- It's possible that one of the units got moved out of the way
                    -- by a move of a previous unit and that it cannot reach the dst
                    -- hex any more.  In that case we stop and reevaluate.
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
                    local unit_in_way = wesnoth.get_unit(dst[1], dst[2])
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

                -- Move out of way in direction of own leader
                local leader_loc = fred.data.gamedata.leaders[wesnoth.current.side]
                local dx, dy  = leader_loc[1] - dst[1], leader_loc[2] - dst[2]
                local r = math.sqrt(dx * dx + dy * dy)
                if (r ~= 0) then dx, dy = dx / r, dy / r end

                AH.movefull_outofway_stopunit(ai, unit, dst[1], dst[2], { dx = dx, dy = dy })
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
                    fred.data.analysis.status.units_used[unit.id] = fred.data.zone_action.zone_id or 'other'
                end
            end

            fred.data.zone_action = nil
        end


        return fred
    end
}
