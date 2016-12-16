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
        local LS = wesnoth.require "lua/location_set.lua"
        local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"
        local R = wesnoth.require "~/add-ons/AI-demos/lua/retreat.lua"


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


        function fred:zone_advance_rating(zone_id, x, y, unit_type, straight_line)
            local gamedata = fred.data.gamedata
            local rating

            if (wesnoth.current.side == 1) then
                if (zone_id == 'all_map') then
                    -- all_map advancing is toward the enemy leader
                    rating = - FU.get_fgumap_value(gamedata.enemy_leader_distance_maps[unit_type], x, y, 'cost')

                    -- Discourage advancing through center or in west
                    -- TODO: refine this a little
                    if (not straight_line) then
                        if (x >= 17) and (x <= 24) and (y >= 10) and (y <= 15) then
                            rating = rating - 5
                        elseif (x >= 18) and (x <= 23) and (y >= 8) and (y <= 9) then
                            rating = rating - 5
                        elseif (x >= 17) and (x <= 20) and (y <= 15) then
                            rating = rating - 5
                        elseif (x <= 16) and (y <= 9) then
                            rating = rating - 5
                        end
                    end
                end

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
                    if (x < 15) or (x > 24) then return end

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

                if (zone_id == 'leader') then
                    -- Rating is minimum distance from leader, but excluding the leader hex itself.
                    -- Add a very minor rating to minimize distance to enemy leader also,
                    -- to select hexes in between the two leaders all else being equal.
                    -- This rating needs to be this small, as some of the secondary ratings
                    -- of advancing are of order 1/1000 to 1/100.
                    if (x == gamedata.leader_x) and (y == gamedata.leader_y) then
                        rating = -1000
                    else
                        rating = - FU.get_fgumap_value(gamedata.leader_distance_maps[unit_type], x, y, 'cost')
                            - FU.get_fgumap_value(gamedata.enemy_leader_distance_maps[unit_type], x, y, 'cost') / 100000
                    end
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

            return rating -- return nil if we got here
        end


        ------ Map analysis at beginning of turn -----------

        function fred:go_here_map()
            local show_debug = true

            fred.data.analysis.go_here_map = {}

            local go_here_slf = {
                x = '1-15,11,16-24,17,21-23,25-34,25,   27,29',
                y = '1-8, 9, 1-9,  10,10,   1-10, 11-12,11,11'
            }

            local influence_maps = FU.get_influence_maps(fred.data.gamedata.my_attack_map[1], fred.data.gamedata.enemy_attack_map[1])

            fred.data.analysis.go_here_map = {}

            for x,arr in pairs(influence_maps) do
                for y,data in pairs(arr) do
                    local influence = data['influence']

                    if (influence > -10)
                       or wesnoth.match_location(x, y, go_here_slf)
                    then
                        FU.set_fgumap_value(fred.data.analysis.go_here_map, x, y, 'go_here', true)
                    end
                end
            end

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
                FU.put_fgumap_labels(fred.data.analysis.go_here_map, 'go_here')
                W.message{ speaker = 'narrator', message = 'go here' }
                FU.clear_labels()
            end

            --[[
            local blurred_vulnerability = {}
            for x,arr in pairs(fred.data.gamedata.influence_map) do
                for y,data in pairs(arr) do
                    local v = data.vulnerability
                    local count = 1
                    for xa,ya in H.adjacent_tiles(x, y) do
                        local va = FU.get_fgumap_value(fred.data.gamedata.influence_map, xa, ya, 'vulnerability')
                        if va then
                            v = v + va
                            count = count + 1
                        end
                    end
                    v = v / count

                    FU.set_fgumap_value(blurred_vulnerability, x, y, 'value', v)
                end
            end
            --]]

            -- Need a map with the distances to the enemy and own leaders
            local leader_cx, leader_cy = AH.cartesian_coords(fred.data.gamedata.leader_x, fred.data.gamedata.leader_y)
            local enemy_leader_cx, enemy_leader_cy = AH.cartesian_coords(fred.data.gamedata.enemy_leader_x, fred.data.gamedata.enemy_leader_y)

            local dist_btw_leaders = math.sqrt( (enemy_leader_cx - leader_cx)^2 + (enemy_leader_cy - leader_cy)^2 )

            local leader_distance_map, hold_here_map = {}, {}
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
            fred.data.gamedata.leader_distance_map = leader_distance_map

            local show_debug = false
            if show_debug then
                FU.put_fgumap_labels(fred.data.gamedata.influence_map, 'my')
                W.message{ speaker = 'narrator', message = 'my_influence' }
                FU.put_fgumap_labels(fred.data.gamedata.influence_map, 'enemy')
                W.message{ speaker = 'narrator', message = 'enemy_influence' }
                FU.put_fgumap_labels(fred.data.gamedata.influence_map, 'influence')
                W.message{ speaker = 'narrator', message = 'influence' }
                FU.put_fgumap_labels(fred.data.gamedata.influence_map, 'tension')
                W.message{ speaker = 'narrator', message = 'tension' }
                FU.put_fgumap_labels(fred.data.gamedata.influence_map, 'vulnerability')
                W.message{ speaker = 'narrator', message = 'vulnerability' }
                --FU.put_fgumap_labels(blurred_vulnerability, 'value')
                --W.message{ speaker = 'narrator', message = 'blurred vulnerability' }
                FU.put_fgumap_labels(leader_distance_map, 'distance')
                W.message{ speaker = 'narrator', message = 'leader_distance_map' }
                FU.put_fgumap_labels(hold_here_map, 'hold_here')
                W.message{ speaker = 'narrator', message = 'hold_here_map' }
                FU.clear_labels()
            end
        end

        function fred:get_raw_cfgs(zone_id)
            local cfg_leader = {
                zone_id = 'leader',
                threat_slf = { x = '1-15,16-24,25-34', y = '1-6,1-8,1-9' },
                threat_factor = 1,
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
                key_hexes = { { 8,8 }, { 11,9 }, { 14,8 } },
                target_zone = { x = '1-15,1-13', y = '7-11,12-19' },
                threat_slf = { x = '1-15,1-13', y = '7-11,12-15' },
                threat_factor = 1,
                zone_filter = { x = '4-14,4-13', y = '7-11,12-15' },
                unit_filter_advance = { x = '1-20,1-14', y = '1-6,7-13' },
                hold_slf = { x = '1-15,1-13', y = '6-11,12-14' },
                hold_core_slf = { x = '12-17,1-15,11', y = '4-5,6-8,9' },
                hold_desperate_slf = { x = '10-19,12', y = '3-6,2' },
                hold_forward_slf = { x = '1-10,12-15,1-15,1-13', y = '9,9,10-11,12-14' },
                villages = {
                    slf = { x = '1-14', y = '1-10' },
                    villages_per_unit = 2
                }
            }

            local cfg_center = {
                zone_id = 'center',
                key_hexes = { { 17,10 }, { 18,9 }, { 20,9 }, { 22,10 }, { 21,9 }, { 23,10 } },
                target_zone = { x = '15-24,13-23', y = '8-13,14-19' },
                threat_slf = { x = '16-24,15-23', y = '9-10,11-15' },
                threat_factor = 2,
                zone_filter = { x = '16-26,15-24', y = '4-10,11-16' },
                unit_filter_advance = { x = '15-23,', y = '1-13' },
                hold_slf = { x = '16-24,16-23', y = '4-10,11-14' },
                hold_core_slf = { x = '16-24', y = '4-10' },
                hold_desperate_slf = { x = '17-21,22', y = '3-5,2-5' },
                hold_forward_slf = { x = '16-23', y = '11-14' },
                villages = {
                    slf = { x = '16-21', y = '7-10' },
                    villages_per_unit = 2
                }
            }

            local cfg_east = {
                zone_id = 'east',
                key_hexes = { { 27,11 }, { 29,11 } },
                target_zone = { x = '24-34,22-34', y = '9-17,18-23' },
                threat_slf = { x = '25-34,24-34', y = '10-13,14-23' },
                threat_factor = 1.2,
                zone_filter = { x = '24-34', y = '9-17' },
                unit_filter_advance = { x = '17-34,24-34', y = '1-8,9-16' },
                hold_slf = { x = '24-34', y = '9-18' },
                hold_core_slf = { x = '24-29,24-34', y = '4-8,9-12' },
                hold_desperate_slf = { x = '19-21,22-29', y = '3-5,2-7' },
                hold_forward_slf = { x = '24-34', y = '13-18' },
                villages = {
                    slf = { x = '22-34', y = '1-10' },
                    villages_per_unit = 2
                }
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

        function fred:is_acceptable_resource_use(units, zone_id, behavior)
            -- @units: array that only needs to contain the id= key
            --print(zone_id, #units)
            --DBG.dbms(behavior)

            for z_id,other_units in pairs(behavior.other_units) do
                if (z_id ~= zone_id) then
                    local add_power_needed = other_units.add_power_needed
                    --print('  checking', z_id,add_power_needed)
                    if behavior.assigned_units[z_id] then
                        add_power_needed = add_power_needed - behavior.assigned_units[z_id].power
                    end
                    --print('  checking', z_id,add_power_needed)

                    local power_left_for_other_zone = other_units.power
                    --print('    power_left_for_other_zone', power_left_for_other_zone)

                    for _,unit in ipairs(units) do
                        local id = unit.id
                        --print('      id:', id)

                        if other_units.units[id] then
                            power_left_for_other_zone = power_left_for_other_zone - other_units.units[id]
                            --print('        power_left_for_other_zone', power_left_for_other_zone)
                        end
                    end

                    if (power_left_for_other_zone < add_power_needed) then
                        return false
                    end

                end
            end

            return true
        end

        function fred:analyze_map_update_tables()
            FU.print_debug(show_debug_analysis, '\n\n\n\n-------------\nUpdating the map analysis tables:')

            -- At beginning of turn, reset fred.data.analysis and add new fields:
            --   turn
            --   stage_counter
            --   stages
            --   status
            --   threats
            --   my_units_by_zone

            if (not fred.data.analysis) or (fred.data.analysis.turn ~= wesnoth.current.turn) then
                fred.data.analysis = {
                    turn = wesnoth.current.turn,
                    stage_counter = 1,
                    stage_ids = { 'leader_threat', 'defend_zones', 'all_map' },
                    --stage_ids = { 'defend_zones' },
                    status = {
                        units_used = {}
                    }
                }
            end

            fred:go_here_map()

            local gamedata = fred.data.gamedata
            local raw_cfgs_all = fred:get_raw_cfgs('all')
            -- for k,v in pairs(gamedata) do print k end
            --DBG.dbms(raw_cfgs_all)

            -- These are only the raw_cfgs of the 3 main zones
            local raw_cfgs_main = fred:get_raw_cfgs()

            local threats = {}
            local tmp_threats = {}

            -- The following are just for convenience to avoid having to
            -- loop over the existing tables too much
            local all_threats = {}
            local key_hexes = {}

            -- Find enemy units that can reach key hexes
            for zone_id,cfg in pairs(raw_cfgs_all) do
                threats[zone_id] = {}
                key_hexes[zone_id] = cfg.key_hexes

                for _,hex in pairs(cfg.key_hexes) do
                    -- Enemies that can attack a key hex
                    local ids = FU.get_fgumap_value(gamedata.enemy_attack_map[1], hex[1], hex[2], 'ids', {})

                    for _,id in pairs(ids) do
                        --print('---- can reach ' .. cfg.zone_id, id)

                        -- If unit also is in cfg.threat_slf, add to analysis.threats[zone_id]
                        if wesnoth.match_unit(gamedata.unit_copies[id], cfg.threat_slf) then
                            --print('------ and is in target zone')
                            threats[zone_id][id] = gamedata.unit_infos[id].power
                            all_threats[id] = true

                        -- If not, add to tmp_threats[id] = { zone_id = true }
                        else
                            if (not tmp_threats[id]) then
                                tmp_threats[id] = {}
                            end

                            tmp_threats[id][zone_id] = true
                        end
                    end
                end
            end
            --DBG.dbms(threats)
            --DBG.dbms(all_threats)
            --DBG.dbms(tmp_threats)

            -- Now go through tmp_threats
            -- Remove all units that are already confirmed in one of the zones
            for id,_ in pairs(tmp_threats) do
                if all_threats[id] then
                    tmp_threats[id] = nil
                end
            end
            --DBG.dbms(tmp_threats)

            -- Go through tmp_threats again
            -- Assign unit to zone that has closest key hex
            for id,zones in pairs(tmp_threats) do
                local loc = gamedata.units[id]
                --print('  ' .. id, loc[1], loc[2])

                local min_dist, closest_zone = 9e99
                for zone_id,_ in pairs(zones) do
                    --print('    ' .. zone_id)

                    for _,hex in pairs(key_hexes[zone_id]) do
                        local dist = H.distance_between(loc[1], loc[2], hex[1], hex[2])
                        --print('      ', hex[1], hex[2], dist)

                        if (dist < min_dist) then
                            min_dist = dist
                            closest_zone = zone_id
                        end
                    end
                end
                --print('      --> closest zone: ' .. closest_zone, min_dist)
                threats[closest_zone][id] = gamedata.unit_infos[id].power
            end

            -- Sanity check: go through all threats again:
            -- Throw error if a unit is in several zones
            -- This should not happen, it is only for the case that the
            -- zone filters are not set up correctly
            local all_threats = {}  -- Use this table again

            for zone_id,units in pairs(threats) do
                for id,_ in pairs(units) do
                    if all_threats[id] then
                        print('!!!!!! Problem with unit ' .. id .. ' being threat in several zones !!!!!!')
                    else
                        all_threats[id] = true
                    end
                end
            end
            --DBG.dbms(threats)
            --DBG.dbms(all_threats)

            fred.data.analysis.threats = threats


            -- Secondary threats
            local threats2 = {}
            for zone_id,cfg in pairs(raw_cfgs_all) do
                threats2[zone_id] = {}
            end

            -- First, we add units that are in a threat zone, but cannot reach a
            -- key hex
            for id,loc in pairs(gamedata.enemies) do
                if (not all_threats[id]) and (not gamedata.unit_infos[id].canrecruit) then
                   --print(id, loc[1], loc[2])

                    for zone_id,cfg in pairs(raw_cfgs_all) do
                        if wesnoth.match_location(loc[1], loc[2], cfg.threat_slf) then
                            threats2[zone_id][id] = gamedata.unit_infos[id].power
                            all_threats[id] = true
                       end
                    end
                end
            end
            --DBG.dbms(threats2)

            -- Second, distribute the rest of the units, as long as they are
            -- within 2 turns of a key hex
            for id,loc in pairs(gamedata.enemies) do
                -- Is the unit still on the castle hex where it was recruited?
                -- If so, exclude it.
                -- TODO: this might not work on all maps
                if (not all_threats[id])
                    and (not gamedata.unit_infos[id].canrecruit)
                    and (not FU.get_fgumap_value(gamedata.reachable_castles_map[gamedata.unit_copies[id].side], loc[1], loc[2], 'castle', false))
                then
                    --print(id, loc[1], loc[2])

                    local best_rating, best_zone_id = -9e99
                    for zone_id,hexes in pairs(key_hexes) do
                        --print('  ' .. zone_id)
                        for _,hex in ipairs(hexes) do
                            local _, cost = wesnoth.find_path(gamedata.unit_copies[id], hex[1], hex[2], { ignore_units = true })
                            local turns_needed = cost / gamedata.unit_infos[id].max_moves
                            --print('    ' .. cost, turns_needed, hex[1], hex[2])
                            local rating = - cost * raw_cfgs_all[zone_id].threat_factor
                            --print('      rating:', rating)

                            if (turns_needed <= 2) and (rating > best_rating) then
                                best_rating = rating
                                best_zone_id = zone_id
                            end
                        end
                    end
                    --print(' best:', best_rating, best_zone_id)

                    if best_zone_id then
                        threats2[best_zone_id][id] = gamedata.unit_infos[id].power
                        all_threats[id] = true
                    end
                end
            end
            --DBG.dbms(threats2)
            fred.data.analysis.threats2 = threats2

            --DBG.dbms(all_threats)
            all_threats = nil  -- not used in the following

            -- Do the same for the AI units, with some difference
            --   1. Use units that can get to the hexes, not attack them
            --   2. We double count here if they can reach several zones, to be sorted out later

            -- Find AI units that can reach key hexes
            local my_units_by_zone = {}
            for zone_id,cfg in pairs(raw_cfgs_all) do
                my_units_by_zone[zone_id] = {}

                for _,hex in pairs(cfg.key_hexes) do
                    -- AI units which can move to a key hex (excl. the leader)
                    local ids = FU.get_fgumap_value(gamedata.my_move_map[1], hex[1], hex[2], 'ids', {})

                    for _,id in pairs(ids) do
                        if (not gamedata.unit_infos[id].canrecruit) then
                            -- Units with MP=0 count into the movemaps on the hex they are on
                            if (gamedata.unit_infos[id].moves > 0) then
                                my_units_by_zone[zone_id][id] = gamedata.unit_infos[id].power
                            end
                        end
                    end
                end
            end
            fred.data.analysis.my_units_by_zone = my_units_by_zone
            --DBG.dbms(my_units_by_zone)


            -- Assign power_used
            local power_used = { move1 = {}, move2 = {} }
            for zone_id,cfg in pairs(raw_cfgs_main) do
                power_used.move1[zone_id] = { units = {}, power = 0, n_units = 0 }
                power_used.move2[zone_id] = { units = {}, power = 0, n_units = 0 }
            end

            local FDAS_units_used = fred.data.analysis.status.units_used

            for id,loc in pairs(gamedata.my_units_noMP) do
                --print(id)

                -- If the status table shows this unit as having been used in one
                -- of the main zones, we use this assignment, otherwise we find
                -- the closest key hexes. In the latter case, we only assign units
                -- that are within 2 turns, in the former it is done no matter what
                local unit_used = FDAS_units_used[id]

                local best_turns, best_zone_id = 9e99

                if unit_used and raw_cfgs_main[unit_used.zone_id] then
                    --print('  in_main_zone: ', unit_used.zone_id)
                    for _,hex in ipairs(raw_cfgs_main[unit_used.zone_id].key_hexes) do
                        local _, cost = wesnoth.find_path(gamedata.unit_copies[id], hex[1], hex[2], { ignore_units = true })
                        local turns_needed = cost / gamedata.unit_infos[id].max_moves
                        --print('    ' .. cost, turns_needed, hex[1], hex[2])

                        if (turns_needed < best_turns) then -- do not check for turns_needed < 2 here!
                            best_turns = turns_needed
                            best_zone_id = unit_used.zone_id
                        end
                    end
                else
                    for zone_id,cfg in pairs(raw_cfgs_main) do
                        --print('  ' .. zone_id)
                        for _,hex in ipairs(cfg.key_hexes) do
                            local _, cost = wesnoth.find_path(gamedata.unit_copies[id], hex[1], hex[2], { ignore_units = true })
                            local turns_needed = cost / gamedata.unit_infos[id].max_moves
                            --print('    ' .. cost, turns_needed, hex[1], hex[2])

                            if (turns_needed <= 2) and (turns_needed < best_turns) then
                                best_turns = turns_needed
                                best_zone_id = zone_id
                            end
                        end
                    end
                end
                --print(' best:', best_turns, best_zone_id)

                if best_zone_id then
                    if (best_turns <= 1) then
                        power_used.move1[best_zone_id].units[id] = gamedata.unit_infos[id].power
                        power_used.move1[best_zone_id].power = power_used.move1[best_zone_id].power + gamedata.unit_infos[id].power
                        power_used.move1[best_zone_id].n_units = power_used.move1[best_zone_id].n_units + 1
                    else -- note that move2 also include >2 turns for units in status.units_used
                        power_used.move2[best_zone_id].units[id] = gamedata.unit_infos[id].power
                        power_used.move2[best_zone_id].power = power_used.move2[best_zone_id].power + gamedata.unit_infos[id].power
                        power_used.move2[best_zone_id].n_units = power_used.move2[best_zone_id].n_units + 1
                    end
                end
            end
            --DBG.dbms(power_used)


            -- Make some behavior strategic decision
            local my_total_power = 0
            for id,loc in pairs(gamedata.my_units) do
                if (not gamedata.unit_infos[id].canrecruit) then
                    my_total_power = my_total_power + gamedata.unit_infos[id].power
                end
            end

            local enemy_total_power = 0
            for id,loc in pairs(gamedata.enemies) do
                if (not gamedata.unit_infos[id].canrecruit) then
                    enemy_total_power = enemy_total_power + gamedata.unit_infos[id].power
                end
            end

            FU.print_debug(show_debug_analysis, '  Total power: (my, enemy, ratio)', my_total_power, enemy_total_power)

            fred.data.analysis.behavior = {}
            local behavior = fred.data.analysis.behavior
            behavior.total = {
                my_total_power = my_total_power,
                enemy_total_power = enemy_total_power
            }

            behavior.total.value_ratio = FU.get_value_ratio(gamedata)
            FU.print_debug(show_debug_analysis, '    -> value_ratio:', behavior.total.value_ratio)

            local enemy_power = {
                threats_total = 0,
                threats2_total = 0,
                threats = {},
                threats2 = {}
            }
            local my_power = {}
            local units_for_zones = {}

            for zone_id,cfg in pairs(raw_cfgs_main) do
                enemy_power.threats[zone_id] = 0
                for id,power in pairs(threats[zone_id]) do
                    enemy_power.threats[zone_id] = enemy_power.threats[zone_id] + power
                    enemy_power.threats_total = enemy_power.threats_total + power
                end

                enemy_power.threats2[zone_id] = 0
                for id,power in pairs(threats2[zone_id]) do
                    enemy_power.threats2[zone_id] = enemy_power.threats2[zone_id] + power
                    enemy_power.threats2_total = enemy_power.threats2_total + power
                end

                my_power[zone_id] = 0
                for id,power in pairs(my_units_by_zone[zone_id]) do
                    my_power[zone_id] = my_power[zone_id] + power
                    -- Total does not make sense as units may be double-counted
                    -- Also show what each unit can do
                    if (not units_for_zones[id]) then
                        units_for_zones[id] = {
                            power = power
                        }
                    end
                    table.insert(units_for_zones[id], zone_id)
                end
            end
            --DBG.dbms(my_power)
            --DBG.dbms(enemy_power)
            --DBG.dbms(my_units_by_zone)
            --DBG.dbms(units_for_zones)

            FU.print_debug(show_debug_analysis, '\n  my power:')
            FU.print_debug(show_debug_analysis, '    total:   ', behavior.total.my_total_power)

            FU.print_debug(show_debug_analysis, '  enemy power:')
            FU.print_debug(show_debug_analysis, '    threats: ', enemy_power.threats_total)
            FU.print_debug(show_debug_analysis, '    threats2:', enemy_power.threats2_total)
            FU.print_debug(show_debug_analysis, '  by zone (my, enemy, diff):')
            for zone_id,cfg in pairs(raw_cfgs_main) do
                FU.print_debug(show_debug_analysis, '    ', zone_id, my_power[zone_id], enemy_power.threats[zone_id], my_power[zone_id] - enemy_power.threats[zone_id])
            end

            local spare_power_threats = behavior.total.my_total_power - enemy_power.threats_total
            local spare_power_threats2 = spare_power_threats - enemy_power.threats2_total

            FU.print_debug(show_debug_analysis, '  spare power:')
            FU.print_debug(show_debug_analysis, '    threats: ', spare_power_threats)
            FU.print_debug(show_debug_analysis, '    threats2:', spare_power_threats2)

            -- For attacking/holding, it's the power in the direct threats
            -- only that matters
            behavior.hold = { zones = {} }
            local hold_ratio = behavior.total.my_total_power / enemy_power.threats_total
            behavior.hold.factor = math.min(1, hold_ratio)
            for zone_id,cfg in pairs(raw_cfgs_main) do
                behavior.hold.zones[zone_id] = {
                    raw_power_needed = enemy_power.threats[zone_id],
                    power_needed = enemy_power.threats[zone_id] * behavior.hold.factor,
                    power_used = power_used.move1[zone_id].power,
                    fraction = enemy_power.threats[zone_id] / enemy_power.threats_total
                }
            end

            -- For advancing, we just use the same as for holding for the moment
            -- TODO: need to add other considerations, e.g.:
            --   - threats farther away
            --   - pulling in units from other zones if needed
            behavior.advance = { zones = {} }
            local advance_ratio = behavior.total.my_total_power / enemy_power.threats_total
            behavior.advance.factor = math.min(1, advance_ratio)
            for zone_id,cfg in pairs(raw_cfgs_main) do
                behavior.advance.zones[zone_id] = {
                    power_needed = enemy_power.threats[zone_id] * behavior.advance.factor,
                    power_used = power_used.move1[zone_id].power
                }
            end

            FU.print_debug(show_debug_analysis, '\n--- Determining behavior ---')

            FU.print_debug(show_debug_analysis, '  Assigning units to zones:')
            behavior.assigned_units = {}
            behavior.other_units = {}

            -- Considerations for holding:
            --  - Do we have enough units overall
            --  - Do we, in principle, have enough in each zone
            --  - Are there units that must be used in a specific zone
            --  - Which is the highest priority zone?

            for id,tbl in pairs(units_for_zones) do
                if (#tbl == 1) then
                    local zone_id = tbl[1]
                    if (not behavior.assigned_units[zone_id]) then
                        behavior.assigned_units[zone_id] = { units = {}, power = 0 }
                    end

                    behavior.assigned_units[zone_id].units[id] = tbl.power
                    behavior.assigned_units[zone_id].power = behavior.assigned_units[zone_id].power + tbl.power

                    --units_for_zones[id] = nil
                else
                    for _,zone_id in ipairs(tbl) do
                        if (not behavior.other_units[zone_id]) then
                            behavior.other_units[zone_id] = {
                                units = {},
                                power = 0,
                                add_power_needed = behavior.hold.zones[zone_id].power_needed - behavior.hold.zones[zone_id].power_used }
                        end

                        behavior.other_units[zone_id].units[id] = tbl.power
                        behavior.other_units[zone_id].power = behavior.other_units[zone_id].power + tbl.power
                    end
                end
            end

            --DBG.dbms(units_for_zones)
            --DBG.dbms(my_units_by_zone)
            --DBG.dbms(behavior.assigned_units)
            --DBG.dbms(behavior.other_units)
            --DBG.dbms(behavior.hold)
            --DBG.dbms(behavior.advance)

            -- Extract all AI units with MP left (for enemy path finding, counter attack placement etc.)
            local extracted_units = {}
            for id,loc in pairs(fred.data.gamedata.my_units_MP) do
                local unit_proxy = wesnoth.get_unit(loc[1], loc[2])
                wesnoth.extract_unit(unit_proxy)
                table.insert(extracted_units, unit_proxy)  -- Not a proxy unit any more at this point
            end

            local ratings, ratings_by_zone = {}, {}
            for zone_id,cfg in pairs(raw_cfgs_main) do
                --print(zone_id)
                local holders = behavior.other_units[zone_id] and behavior.other_units[zone_id].units or {}
                local zone_ratings = FHU.get_hold_units(zone_id, holders, raw_cfgs_main[zone_id], gamedata, fred.data.move_cache, show_debug_hold)

                --[[if zone_ratings then
                    for id,rating in pairs(zone_ratings) do
                        if (not ratings[id]) then ratings[id] = {} end
                        ratings[id][zone_id] = rating
                    end
                end--]]

                ratings_by_zone[zone_id] = zone_ratings or {}

            end
            --DBG.dbms(ratings)
            --DBG.dbms(ratings_by_zone)

            for _,extracted_unit in ipairs(extracted_units) do wesnoth.put_unit(extracted_unit) end

            print('Distributing other units')

            local others = {}
            for zone_id,cfg in pairs(raw_cfgs_main) do
                others[zone_id] = { units = {}, power = 0 }
            end

            local keep_searching = true
            while keep_searching do
                keep_searching = false

                local max_needed, best_zone = nil, nil
                for zone_id,cfg in pairs(raw_cfgs_main) do
                    if next(ratings_by_zone[zone_id]) then
                        local fraction = behavior.hold.zones[zone_id].fraction
                        --print('  ' .. zone_id .. '   fraction = ' .. fraction)

                        local assigned_power = behavior.assigned_units[zone_id] and behavior.assigned_units[zone_id].ppower or 0

                        local other_power_needed =
                            behavior.hold.zones[zone_id].power_needed
                            - behavior.hold.zones[zone_id].power_used
                            - assigned_power
                            - others[zone_id].power
                        other_power_needed = math.max(other_power_needed, 0)
                        --print('    other power needed', other_power_needed)

                        local needed = other_power_needed * fraction
                        --print('    needed next:', needed, max_needed, zone_id)

                        if (needed > 0) and ((not max_needed) or (needed > max_needed)) then
                            max_needed, best_zone = needed, zone_id
                        end
                    end
                end
                --print('  most in need:', best_zone, max_needed)

                if best_zone then
                    local max_rating, best_id
                    for id,rating in pairs(ratings_by_zone[best_zone]) do
                        if (not max_rating) or (rating > max_rating) then
                            max_rating, best_id = rating,id
                        end
                    end
                    --print('    best_unit:', best_id)

                    if best_id then
                        local power = behavior.other_units[best_zone].units[best_id]
                        others[best_zone].power = others[best_zone].power + power
                        others[best_zone].units[best_id] = power

                        -- Remove this unit from the ratings table
                        for zone_id,cfg in pairs(raw_cfgs_main) do
                            ratings_by_zone[zone_id][best_id] = nil
                        end

                        keep_searching = true
                    end
                end
            end
            --DBG.dbms(others)

            -- Now add these to assigned_units and remove them from other_units
            -- Todo: consider doing this inside the loop above, but for now we
            -- keep it separate as more analysis on this might need to be done

            for zone_id,tbl in pairs(others) do
                for id,power in pairs(tbl.units) do
                    if (not behavior.assigned_units[zone_id]) then
                        behavior.assigned_units[zone_id] = { units = {}, power = 0 }
                    end

                    behavior.assigned_units[zone_id].units[id] = power
                    behavior.assigned_units[zone_id].power = behavior.assigned_units[zone_id].power + power

                    for zone_id2,tbl2 in pairs(behavior.other_units) do
                        for id2,power2 in pairs(tbl2.units) do
                            if (id == id2) then
                                tbl2.units[id] = nil
                                tbl2.power = tbl2.power - power2

                                -- If there's no unit left, remove the entire table
                                if (not next(tbl2.units)) then
                                    behavior.other_units[zone_id2] = nil
                                end
                            end
                        end
                    end


                end
            end
            --DBG.dbms(behavior.assigned_units)
            --DBG.dbms(behavior.other_units)


            FU.print_debug(show_debug_analysis, '\nDetermining how far to advance: (leader_distance, hex)')
            for zone_id,cfg in pairs(raw_cfgs_main) do
                local zone = wesnoth.get_locations(cfg.hold_slf)

                local max_vulnerability, best_leader_distance, best_hex = -9e99, -9e99
                for _,loc in ipairs(zone) do
                    local vulnerability = FU.get_fgumap_value(fred.data.gamedata.influence_map, loc[1], loc[2], 'vulnerability', -999)
                    local leader_distance = FU.get_fgumap_value(fred.data.gamedata.leader_distance_map, loc[1], loc[2], 'distance', -999)
                    --print(loc[1], loc[2], vulnerability)

                    if (vulnerability > max_vulnerability)
                       or ((vulnerability == max_vulnerability)) and (leader_distance > best_leader_distance)
                    then
                        max_vulnerability = vulnerability
                        best_leader_distance = leader_distance
                        best_hex = loc
                    end
                end
                --print('    ' .. zone_id .. ': ', max_vulnerability, best_leader_distance, best_hex[1] .. ',' .. best_hex[2])

                -- Except if this is behind the key hexes
                for _,loc in ipairs(cfg.key_hexes) do
                    local leader_distance = FU.get_fgumap_value(fred.data.gamedata.leader_distance_map, loc[1], loc[2], 'distance', -999)

                    if (leader_distance > best_leader_distance) then
                        best_leader_distance = leader_distance
                        best_hex = loc
                        --print('      Using key hex instead: ', best_leader_distance, best_hex[1] .. ',' .. best_hex[2])
                    end
                end

                behavior.hold.zones[zone_id].max_forward_distance = best_leader_distance
                FU.print_debug(show_debug_analysis, '  ' .. zone_id .. ': ', best_leader_distance, best_hex[1] .. ',' .. best_hex[2])
            end
            --DBG.dbms(behavior.hold)

            -- How many units are needed in each zone for village grabbing
            behavior.villages = { zones = {} }
            FU.print_debug(show_debug_analysis, '\n  #villages, units needed, units already used:')
            for zone_id,cfg in pairs(raw_cfgs_main) do
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

                behavior.villages.zones[zone_id] = {
                    n_units_needed = math.ceil(village_count / cfg.villages.villages_per_unit),
                    n_units_used
                        = power_used.move1[zone_id].n_units
                        + power_used.move2[zone_id].n_units
                }

                FU.print_debug(show_debug_analysis, '    ' .. zone_id, village_count, behavior.villages.zones[zone_id].n_units_needed, behavior.villages.zones[zone_id].n_units_used)
            end
            --DBG.dbms(behavior.villages)


            fred.data.behavior = behavior

            FU.print_debug(show_debug_analysis, '--- Done determining behavior ---\n')
            --DBG.dbms(behavior)
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
            local stage_id = fred.data.analysis.stage_ids[fred.data.analysis.stage_counter]
            local status = fred.data.analysis.status
            local behavior = fred.data.behavior
            local threats = fred.data.analysis.threats
            local my_units_by_zone = fred.data.analysis.my_units_by_zone
            FU.print_debug(show_debug_analysis, '\nAnalysis of stage ' .. stage_id)

            -- These are only the raw_cfgs of the 3 main zones
            local raw_cfgs_main = fred:get_raw_cfgs()
            --DBG.dbms(raw_cfgs_main)
            --DBG.dbms(fred.data.analysis)


            fred.data.zone_cfgs = {}


            -- Base ratings and other general parameters needed for
            -- setting up the action cfgs

            local base_ratings = {
                village_grab = 9000,
                attack = 8000,
                hold = 8000 - 0.01,
                advance = 1000
            }

            local power_missing_margin = 2

            ----- begin TODO: check which of these are actually needed
            local straight_line = false
            if (behavior.total.my_total_power > behavior.total.my_total_power * 2) then
                straight_line = true
            end

            --local hold_core_only = (enemy_total_power > my_total_power)
            --FU.print_debug(show_debug_analysis, '  hold_core_only', hold_core_only)
            ----- end TODO: check which of these are actually needed

            -- TODO: do not duplicate information between zone_cfg and raw_cfg

            -- Action: Advancing toward villages
            for zone_id,villages in pairs(behavior.villages.zones) do
                if (villages.n_units_needed > villages.n_units_used) then
                    local zone_cfg = {
                        zone_id = zone_id,
                        stage_id = stage_id,
                        actions = { advance = true },
                        value_ratio = behavior.total.value_ratio,
                        villages_only = true,
                        rating = base_ratings.village_grab + villages.n_units_needed
                    }
                    --DBG.dbms(zone_cfg)
                    table.insert(fred.data.zone_cfgs, zone_cfg)
                end
            end

            -- Action: attack direct threats and hold against them
            -- Both of these are done based on the power in direct threats
            for zone_id,hold in pairs(behavior.hold.zones) do
                local power_missing = hold.power_needed - hold.power_used
                if (power_missing > power_missing_margin) then
                    local raw_cfg = raw_cfgs_main[zone_id]

                    -- Attack --
                    local zone_cfg = {
                        zone_id = zone_id,
                        actions = { attack = true },
                        target_zone = raw_cfg.target_zone,
                        stage_id = stage_id,
                        targets = {},
                        value_ratio = behavior.total.value_ratio,
                        rating = base_ratings.attack + hold.power_needed,
                        power_missing = power_missing
                    }

                    -- Also add in the targets: use only those that are inside cfg.target_zone
                    for id,_ in pairs(threats[zone_id]) do
                        if wesnoth.match_unit(gamedata.unit_copies[id], raw_cfg.target_zone) then
                            local target = {}
                            target[id] = gamedata.enemies[id]
                            table.insert(zone_cfg.targets, target)
                        end
                    end

                    table.insert(fred.data.zone_cfgs, zone_cfg)

                    local holders = {}
                    if behavior.assigned_units[zone_id] then
                        for id,power in pairs(behavior.assigned_units[zone_id].units) do
                            holders[id] = power
                        end
                    end
                    if behavior.other_units[zone_id] then
                        for id,power in pairs(behavior.other_units[zone_id].units) do
                            holders[id] = power
                        end
                    end
                    DBG.dbms(holders)

                    -- Hold --
                    local zone_cfg = {
                        zone_id = zone_id,
                        stage_id = stage_id,
                        actions = { hold = true },
                        value_ratio = behavior.total.value_ratio,
                        rating = base_ratings.hold + hold.power_needed,
                        power_missing = power_missing,
                        holders = holders
                    }


                    table.insert(fred.data.zone_cfgs, zone_cfg)
                end
            end


            -- Action: advance in a zone
            -- This takes both direct and indirect threats into account
            for zone_id,advance in pairs(behavior.advance.zones) do
                local power_missing = advance.power_needed - advance.power_used
                if (power_missing > power_missing_margin) then
                    local zone_cfg = {
                        zone_id = zone_id,
                        stage_id = stage_id,
                        actions = { advance = true },
                        value_ratio = behavior.total.value_ratio,
                        from_other_zones = true,
                        use_secondary_rating = true,
                        rating = base_ratings.advance + advance.power_needed,
                        power_missing = power_missing
                    }

                    table.insert(fred.data.zone_cfgs, zone_cfg)
                end
            end


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
            local status = fred.data.analysis.status
            local stage_id = fred.data.analysis.stage_ids[fred.data.analysis.stage_counter]

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

            -- Eliminate targets in the no-go zone
-- Disable this for now
-- Todo: decide what to do with this
--            for i = #targets,1,-1 do
--                local id, loc = next(targets[i])
--
--                local go_here = FU.get_fgumap_value(fred.data.analysis.go_here_map, loc[1], loc[2], 'go_here')
--                print(i, id, loc[1], loc[2], go_here)
--
--                if (not go_here) then
--                    --print('  removing target ' .. i, id)
--                    table.remove(targets, i)
--                end
--            end
--            FU.print_debug(show_debug_attack, '  #targets inside go_here zone', #targets)


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

                    local is_good = fred:is_acceptable_resource_use(tmp_attackers, zonedata.cfg.zone_id, fred.data.analysis.behavior)

                    -- TODO: table.remove() can be slow
                    if (not is_good) or (n_attackers > (zonedata.cfg.max_attackers or 99)) then
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
            --DBG.dbms(zonedata.cfg)

            local gamedata = fred.data.gamedata
            local move_cache = fred.data.move_cache

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
            -- *might* be the best positions. The rating is the same as the
            -- more detailed analysis below, but it is done using the assumed
            -- counter attack positions on the enemy on the map, while the
            -- more detailed analysis actually does a full counter attack
            -- calculation

            -- TODO: do this overall, rather than for this action?
            local hold_slf = raw_cfg.hold_slf
            if zonedata.cfg.hold_core_only then
                --print('holding core only', zonedata.cfg.zone_id)
                hold_slf = raw_cfg.hold_core_slf
            end


            local zone = wesnoth.get_locations(hold_slf)
            local full_zone_map = {}
            for _,loc in ipairs(zone) do
                FU.set_fgumap_value(full_zone_map, loc[1], loc[2], 'flag', true)
            end
            --DBG.dbms(zone_map)
            --FU.put_fgumap_labels(full_zone_map, 'flag')

            local zone_map = {}
            for x,tmp in pairs(full_zone_map) do
                for y,_ in pairs(tmp) do
                    for enemy_id,etm in pairs(gamedata.enemy_turn_maps) do
                        local turns = etm[x] and etm[x][y] and etm[x][y].turns

                        if turns and (turns <= 1) then
                            FU.set_fgumap_value(zone_map, x, y, 'flag', true)
                        end
                    end
                end
            end
            --FU.put_fgumap_labels(zone_map, 'flag')

            -- For the enemy rating, we need to put a 1-hex buffer around this
            local buffered_zone_map = {}
            for x,tmp in pairs(zone_map) do
                for y,_ in pairs(tmp) do
                    if (not buffered_zone_map[x]) then
                        buffered_zone_map[x] = {}
                    end
                    buffered_zone_map[x][y] = true

                    for xa,ya in H.adjacent_tiles(x, y) do
                        if (not buffered_zone_map[xa]) then
                            buffered_zone_map[xa] = {}
                        end
                        buffered_zone_map[xa][ya] = true
                    end
                end
            end
            --DBG.dbms(buffered_zone_map)

            -- Enemy rating map: get the sum of the squares of the (modified)
            -- defense ratings of all enemies that can reach a hex
            local enemy_rating_map = {}
            for x,tmp in pairs(buffered_zone_map) do
                for y,_ in pairs(tmp) do
                    local enemy_rating, count = 0, 0
                    for enemy_id,etm in pairs(gamedata.enemy_turn_maps) do
                        local turns = etm[x] and etm[x][y] and etm[x][y].turns

                        if turns and (turns <= 1) then
                            local enemy_hc = FGUI.get_unit_defense(gamedata.unit_copies[enemy_id], x, y, gamedata.defense_maps)
                            enemy_hc = 1 - enemy_hc

                            -- If this is a village, give a bonus
                            -- TODO: do this more quantitatively
                            if gamedata.village_map[x] and gamedata.village_map[x][y] then
                                enemy_hc = enemy_hc - 0.15
                                if (enemy_hc < 0) then enemy_hc = 0 end
                            end

                            -- Note that this number is large if it is bad for
                            -- the enemy, good for the AI, so it needs to be
                            -- added, not subtracted
                            enemy_rating = enemy_rating + enemy_hc^2
                            count = count + 1
                        end
                    end

                    if (count > 0) then
                        enemy_rating = enemy_rating / count
                        if (not enemy_rating_map[x]) then enemy_rating_map[x] = {} end
                        enemy_rating_map[x][y] = {
                            rating = enemy_rating,
                            count = count
                        }
                    end
                end
            end

            local show_debug_local = false
            if show_debug_local then
                FU.put_fgumap_labels(enemy_rating_map, 'rating')
                W.message{ speaker = 'narrator', message = zonedata.cfg.zone_id .. ': enemy_rating_map' }
            end

            -- Need a map with the distances to the enemy and own leaders
            local leader_cx, leader_cy = AH.cartesian_coords(gamedata.leader_x, gamedata.leader_y)
            local enemy_leader_cx, enemy_leader_cy = AH.cartesian_coords(gamedata.enemy_leader_x, gamedata.enemy_leader_y)

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

            local show_debug_local = false
            if show_debug_local then
                FU.put_fgumap_labels(leader_distance_map, 'distance')
                W.message{ speaker = 'narrator', message = zonedata.cfg.zone_id .. ': leader_distance_map' }
            end

            -- First calculate a unit independent rating map
            -- For the time being, this is the just the enemy rating averaged over all
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
                        end
                    end

                    if (adj_count > 0) then
                        rating = rating / adj_count

                        if (not indep_rating_map[x]) then indep_rating_map[x] = {} end
                        indep_rating_map[x][y] = {
                            rating = rating,
                            adj_count = adj_count
                        }
                    end
                end
            end

            if show_debug_hold then
                FU.put_fgumap_labels(indep_rating_map, 'rating')
                W.message { speaker = 'narrator', message = 'Hold zone ' .. zonedata.cfg.zone_id .. ': unit-independent rating map: rating' }
                --FU.put_fgumap_labels(indep_rating_map, 'adj_count')
                --W.message { speaker = 'narrator', message = 'Hold zone ' .. zonedata.cfg.zone_id .. ': unit-independent rating map: adjacent count' }
            end


            -- Now we go on to the unit-dependent rating part
            -- This is the same type of rating as for enemies, but done individually
            -- for each AI unit, rather than averaged over all units for each hex

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
                            local hit_chance = FU.get_hit_chance(id, x, y, gamedata)

                            local unit_rating = indep_rating_map[x][y].rating - hit_chance^2

                            if (not unit_rating_maps[id][x]) then unit_rating_maps[id][x] = {} end
                            unit_rating_maps[id][x][y] = { rating = unit_rating }
                        end
                    end
                end

                if show_debug_hold then
                    wesnoth.scroll_to_tile(gamedata.units[id][1], gamedata.units[id][2])
                    FU.put_fgumap_labels(unit_rating_maps[id], 'rating')
                    wesnoth.add_tile_overlay(gamedata.units[id][1], gamedata.units[id][2], { image = "items/orcish-flag.png" })
                    W.redraw()
                    W.message { speaker = 'narrator', message = 'Hold zone: unit-specific rating map: ' .. id }
                    wesnoth.remove_tile_overlay(gamedata.units[id][1], gamedata.units[id][2], { image = "items/orcish-flag.png" })
                    FU.clear_labels()
                    W.redraw()
                end
            end

            -- Next, we find the units that have the highest-rated hexes, and
            -- sort the hexes for each unit by rating

            local unit_ratings, rated_units = {}, {}
            local max_hexes = 5 -- number of hexes per unit for placement combos

            for id,unit_rating_map in pairs(unit_rating_maps) do
                -- Need to extract the map into a sortable format first
                -- TODO: this is additional overhead that can be removed later
                -- when the maps are not needed any more
                unit_ratings[id] = {}
                for x,tmp in pairs(unit_rating_map) do
                    for y,r in pairs(tmp) do
                        table.insert(unit_ratings[id], {
                            rating = r.rating,
                            x = x, y = y
                        })
                    end
                end

                table.sort(unit_ratings[id], function(a, b) return a.rating > b.rating end)

                -- We also identify the best units; which are those with the highest
                -- average of the best ratings (only those to be used for the next step)
                -- The previous rating is only used to identify the best hexes though.
                -- The units are rated based on counter attack stats (single unit on that
                -- hex only), otherwise a 1HP assassin will be chosen over a full HP whelp.
                local av_best_ratings = 0
                n_hexes = math.min(max_hexes, #unit_ratings[id])
                for i = 1,n_hexes do
                    local old_locs = { { gamedata.unit_copies[id].x, gamedata.unit_copies[id].y } }
                    local new_locs = { { unit_ratings[id][i].x, unit_ratings[id][i].y } }
                    local target = {}
                    target[id] = { unit_ratings[id][i].x, unit_ratings[id][i].y }

                    local cfg_counter_attack = { use_max_damage_weapons = true }
                    local counter_stats, counter_attack = FAU.calc_counter_attack(target, old_locs, new_locs, gamedata, move_cache, cfg_counter_attack)
                    ---DBG.dbms(counter_stats)

                    av_best_ratings = av_best_ratings - counter_stats.rating_table.rating
                    --print(id, unit_ratings[id][i].rating, - counter_stats.rating_table.rating, unit_ratings[id][i].x, unit_ratings[id][i].y)
                end
                av_best_ratings = av_best_ratings / n_hexes
                --print('  total rating: ', av_best_ratings, id)

                table.insert(rated_units, { id = id, rating = av_best_ratings })
            end

            -- Exclude units that have no reachable qualified hexes
            for i_ru = #rated_units,1,-1 do
                local id = rated_units[i_ru].id
                if (#unit_ratings[id] == 0) then
                    table.remove(rated_units, i_ru)
                end
            end

            if (#rated_units == 0) then
                return
            end

            -- Sorting this will now give us the order of units to be considered
            table.sort(rated_units, function(a, b) return a.rating > b.rating end)
            --DBG.dbms(unit_ratings)
            --DBG.dbms(rated_units)

            i_ru = 1
            while (i_ru <= #rated_units) do
                local tmp_holders = {}
                for i=1,i_ru do tmp_holders[i] = rated_units[i] end
                local is_good = fred:is_acceptable_resource_use(tmp_holders, zonedata.cfg.zone_id, fred.data.analysis.behavior)

                if is_good then
                    i_ru = i_ru + 1
                else
                    table.remove(rated_units, i_ru)
                end
            end

            if (#rated_units == 0) then
                return
            end


            -- For holding, we are allowed to add units until we are above
            -- the limit given by power_missing
            local power_missing = zonedata.cfg.power_missing or 9e99
            --print('  power_missing', power_missing)

            local n_units = math.min(3, #rated_units)
            --print('n_units', n_units)

            -- TODO: limit power after calculating combos, rather than before?
            local ids, n_hexes = {}, {}
            local total_power = 0
            for i = 1,n_units do
                local id = rated_units[i].id
                table.insert(ids, id)

                table.insert(n_hexes, math.min(max_hexes, #unit_ratings[id]))

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

            ----------- Start recursive function hex_combos() ----------
            -- Uses variables by closure
            local function hex_combos()
                for i = 0,n_hexes[layer] do
                    local id = ids[layer]
                    local xy
                    if (i ~= 0) then
                        local x = unit_ratings[id][i].x
                        local y = unit_ratings[id][i].y
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
            ----------- End recursive function hex_combos() ----------

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

            -- Need to make sure that the same weapons are used for all counter attack calculations
            local cfg_counter_attack = { use_max_damage_weapons = true }

            for i_c,combo in ipairs(combos) do
                local old_locs, new_locs = {}, {}
                --print('Combo ' .. i_c)
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
                local combo_stats = {}
                for xy,id in pairs(combo) do
                    n_holders = n_holders + 1
                    local target = {}
                    local x, y =  math.floor(xy / 1000), xy % 1000

                    target[id] = { x, y }
                    local counter_stats, counter_attack = FAU.calc_counter_attack(target, old_locs, new_locs, gamedata, move_cache, cfg_counter_attack)
                    --DBG.dbms(counter_stats)
                    --DBG.dbms(counter_attack)

                    -- If this is a shielded position, don't use this combo
                    -- We want to exclude combinations where one unit is out of attack range
                    -- as this is for holding a zone, not protecting units.
                    if (not (next(counter_attack))) then
                        --print('  not acceptable because unit cannot be reached by enemy')
                        is_acceptable = false
                        break
                    end

                    local hit_chance = FU.get_hit_chance(id, x, y, gamedata)
                    --print('  ' .. id, x, y, hit_chance)

                    local is_village = false
                    if gamedata.village_map[x] and gamedata.village_map[x][y] then
                        hit_chance = hit_chance - 0.15
                        if (hit_chance < 0) then hit_chance = 0 end
                        is_village=true
                    end

                    if is_acceptable and (not FHU.is_acceptable_location(gamedata.unit_infos[id], x, y, hit_chance, counter_stats, counter_attack, zonedata.cfg.value_ratio, raw_cfg, gamedata)) then
                        is_acceptable = false
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
                        if is_village then
                            enemy_hc = enemy_hc + 0.15
                        end

                        --print('    enemy_hc:', enemy_hc)

                        enemy_rating = enemy_rating + enemy_hc^2 - hit_chance^2
                        count = count + 1
                    end
                    enemy_rating = enemy_rating / count
                    --print('      --> enemy_rating', enemy_rating)

                    -- We also add a very small contribution from the counter
                    -- attack rating, as lots of option can otherwise be equal
                    -- This needs to be multiplied be a small number. enemy_rating
                    -- often varies by .01 or so
                    -- Important: the counter_stats rating is the rating of the
                    -- counter attack. We want this to be as *bad* as possible
                    counter_attack_rating = - counter_stats.rating_table.rating / 1000.
                    --print('      --> counter_attack_rating', counter_attack_rating)

                    local new_rating = enemy_rating + counter_attack_rating
                    new_rating = new_rating * FU.get_fgumap_value(gamedata.influence_map, x, y, 'vulnerability', 0)

                    rating = rating + new_rating

                    local combo_stat = {
                        x = x, y = y,
                        id = id,
                        counter_rating = counter_stats.rating_table.rating,
                        hit_chance = hit_chance
                    }
                    table.insert(combo_stats, combo_stat)
                end
                --print('  --> rating:', rating)

                -- Now check whether the hold combination is acceptable
                if is_acceptable then
                    is_acceptable = FHU.is_acceptable_hold(combo_stats, raw_cfg, zonedata.cfg, gamedata)
                end

                -- If this has negative rating, check whether it is acceptable after all
                -- For now we always consider these unacceptable
                -- Note: only the enemy_rating contributions count here, not
                -- the part in counter_attack_rating
                if (rating < counter_attack_rating - 1e-8) then
                    --print('  Hold has negative rating; checking for acceptability')
                    is_acceptable = false
                end

                --print('      is_acceptable', is_acceptable)

                if is_acceptable and (rating > best_combos[n_holders].max_rating) then
                    best_combos[n_holders].max_rating = rating
                    best_combos[n_holders].best_hexes = new_locs

                    best_combos[n_holders].best_units = {}
                    for xy,id in pairs(combo) do
                        table.insert(best_combos[n_holders].best_units, gamedata.unit_infos[id])
                    end
                end

                if show_debug_hold then
                    local x, y
                    for xy,id in pairs(combo) do
                        x, y =  math.floor(xy / 1000), xy % 1000
                        W.label { x = x, y = y, text = id }
                    end
                    wesnoth.scroll_to_tile(x, y)
                    W.message { speaker = 'narrator', message = 'Hold combo ' .. i_c .. '/' .. #combos .. '  is_acceptable: ' .. tostring(is_acceptable) .. ' ' .. rating}
                    for xy,id in pairs(combo) do
                        x, y =  math.floor(xy / 1000), xy % 1000
                        W.label { x = x, y = y, text = "" }
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
                    -- displayed. We could also simply use combo.attackers
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
        function fred:get_advance_action(zonedata)
            if debug_eval then
                local txt = '  --> advance evaluation: '
                if zonedata.cfg.villages_only then
                    txt = '  --> advance evaluation (villages_only): '
                end
                print_time(txt .. zonedata.cfg.zone_id)
            end

            local gamedata = fred.data.gamedata
            local move_cache = fred.data.move_cache

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
                if zonedata.cfg.from_other_zones or wesnoth.match_unit(gamedata.unit_copies[id], raw_cfg.unit_filter_advance) then
                    --print('  matches unit_filter_advance in zone ' .. zonedata.cfg.zone_id, id)
                    advance_units[id] = loc
                end
            end

            -- Make sure that we use the value ratio from the cfg
            -- Don't need to set use_max_damage_weapons here, as it is not used for comparison
            local cfg_counter_attack = { value_ratio = zonedata.cfg.value_ratio }

            -- Don't need to enforce a resource limit here, as this is one
            -- unit at a time. It will be checked before the action is called.

            local max_rating, best_unit, best_hex = -9e99
            local max_rating2, best_unit2, best_hex2 = -9e99
            local reachable_villages = {}
            for id,loc in pairs(advance_units) do
                reachable_villages[id] = {}

                -- The leader only participates in village grabbing, and
                -- that only if he is on the keep
                local is_leader = gamedata.unit_infos[id].canrecruit
                local not_leader_or_leader_on_keep =
                    (not is_leader)
                    or wesnoth.get_terrain_info(wesnoth.get_terrain(gamedata.units[id][1], gamedata.units[id][2])).keep
                FU.print_debug(show_debug_advance, id, is_leader, not_leader_or_leader_on_keep)

                -- TODO: change retreat.lua so that it uses the gamedata tables
                local min_hp = R.min_hp(gamedata.unit_copies[id])
                local must_retreat = gamedata.unit_copies[id].hitpoints < min_hp
                FU.print_debug(show_debug_advance, id, min_hp, must_retreat)

                local unit_rating_map, unit_rating_map2 = {}, {}
                for x,tmp in pairs(gamedata.reach_maps[id]) do
                    for y,_ in pairs(tmp) do
                        local threat
                        if zonedata.cfg.unthreatened_only then
                            threat = FU.get_fgumap_value(gamedata.enemy_attack_map[1], x, y, 'power')
                        end

                        -- Threat will be nil if:
                        --   - zonedata.cfg.unthreatened_only = nil
                        --   - or no threat exists on the hex
                        -- -> zone_rating will only be set in these two cases
                        --    Specifically that means that it will NOT be set if
                        --    there is a threat and unthreatened_only is set

                        -- Also exclude hexes in the no-go zone
                       local go_here = FU.get_fgumap_value(fred.data.analysis.go_here_map, x, y, 'go_here')

                        local zone_rating
                        if (not threat) and go_here then
                            zone_rating = fred:zone_advance_rating(zonedata.cfg.zone_id, x, y, gamedata.unit_infos[id].type, zonedata.cfg.straight_line)
                        end

                        if zone_rating then
                            local rating, rating2

                            local hit_chance = FU.get_hit_chance(id, x, y, gamedata)

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

                                    -- Still give a very minor preference to these if ignore_villages is set
                                    if zonedata.cfg.ignore_villages then
                                        rating = rating + 0.1 * enemies_in_reach
                                    else
                                        rating = rating + 10 * enemies_in_reach
                                    end

                                    -- In addition, if the unit is injured, we give a bonus for
                                    -- villages as well
                                    -- It is the bigger the more injured the unit is.
                                    -- TODO: finetune this
                                    local injured_fraction = (gamedata.unit_infos[id].max_hitpoints - gamedata.unit_infos[id].hitpoints) / gamedata.unit_infos[id].max_hitpoints
                                    rating = rating + injured_fraction * 10
                                end

                                -- Penalty for hexes adjacent to villages the enemy can reach
                                -- TODO: do we want a adjacent_to_villages_map?
                                -- Potential TODO: in principle this should be calculated
                                -- for the situation _after_ the unit moves, but that
                                -- might be too costly
                                -- We keep this penalty even if zonedata.cfg.ignore_villages is set.
                                -- It is always a bad thing
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
                            if zonedata.cfg.ignore_villages then
                                is_priority_village = false
                            end

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
                            if (not zonedata.cfg.ignore_counter) and rating and ((rating > max_rating) or is_priority_village) then
                                --print('    Checking if location is acceptable', x, y)

                                local old_locs = { { loc[1], loc[2] } }
                                local new_locs = { { x, y } }
                                --DBG.dbms(old_locs)
                                --DBG.dbms(new_locs)

                                local target = {}
                                target[id] = { x, y }
                                local counter_stats, counter_attack = FAU.calc_counter_attack(target, old_locs, new_locs, gamedata, move_cache, cfg_counter_attack)
                                --DBG.dbms(counter_stats)
                                rating2 = -counter_stats.rating_table.rating

--                                local cfg_acc = {
--                                    defend_hard = false,
--                                    acceptable_rating = 0
--                                }

                                if (not FHU.is_acceptable_location(gamedata.unit_infos[id], x, y, hit_chance, counter_stats, counter_attack, zonedata.cfg.value_ratio, raw_cfg, gamedata, cfg_acc)) then
                                    is_acceptable = false
                                end
                                --print('      --> is_acceptable', is_acceptable)
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

                            if rating2 and (rating2 > max_rating2) then
                                max_rating2 = rating2
                                best_unit2 = gamedata.my_units[id]
                                best_unit2.id = id
                                best_hex2 = { x, y }
                            end

                            if rating then
                                FU.set_fgumap_value(unit_rating_map, x, y, 'rating', rating)
                            end
                            if rating2 then
                                FU.set_fgumap_value(unit_rating_map2, x, y, 'rating', rating2)
                            end
                        end
                    end
                end

                if show_debug_advance then
                    wesnoth.scroll_to_tile(gamedata.units[id][1], gamedata.units[id][2])
                    FU.put_fgumap_labels(unit_rating_map, 'rating')
                    wesnoth.add_tile_overlay(gamedata.units[id][1], gamedata.units[id][2], { image = "items/orcish-flag.png" })
                    W.redraw()
                    W.message { speaker = 'narrator', message = 'Advance ' .. zonedata.cfg.zone_id .. ': unit-specific rating map: ' .. id }

                    FU.put_fgumap_labels(unit_rating_map2, 'rating')
                    W.message { speaker = 'narrator', message = 'Advance ' .. zonedata.cfg.zone_id .. ': unit-specific rating map (backup rating): ' .. id }

                    wesnoth.remove_tile_overlay(gamedata.units[id][1], gamedata.units[id][2], { image = "items/orcish-flag.png" })
                    FU.clear_labels()
                    W.redraw()
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
                FU.print_debug(show_debug_advance, '  best advance rating 1:', best_unit.id, best_hex[1], best_hex[2])
            end
            if best_unit2 then
                FU.print_debug(show_debug_advance, '  best advance rating 2:', best_unit2.id, best_hex2[1], best_hex2[2])
            end

            if zonedata.cfg.use_secondary_rating and (not best_unit) and best_unit2 then
                best_unit = best_unit2
                best_hex = best_hex2
            end

            if best_unit then
                --print('****** Found advance action:')
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

            fred:analyze_map_update_tables()
--if 1 then return 0 end
            local FDA = fred.data.analysis -- just for convenience
            --DBG.dbms(FDA)

--FDA.stage_counter = 1

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
                FDA.stage_counter = FDA.stage_counter + 1

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
                        fred.data.analysis.status.units_used[recruit_proxy.id] = {
                            zone_id = fred.data.zone_action.zone_id or 'other',
                            action = fred.data.zone_action.action or 'other'
                        }
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

                -- Move out of way in direction of own leader
                local leader_loc = fred.data.gamedata.leaders[wesnoth.current.side]
                local dx, dy  = leader_loc[1] - dst[1], leader_loc[2] - dst[2]
                local r = math.sqrt(dx * dx + dy * dy)
                if (r ~= 0) then dx, dy = dx / r, dy / r end

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
                    fred.data.analysis.status.units_used[unit.id] = {
                        zone_id = fred.data.zone_action.zone_id or 'other',
                        action = fred.data.zone_action.action or 'other'
                    }
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
