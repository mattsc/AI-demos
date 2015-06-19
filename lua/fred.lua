return {
    init = function(ai)

        local fred = {}

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        local FGU = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_utils.lua"
        local FGUI = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_utils_incremental.lua"
        local FAU = wesnoth.require "~/add-ons/AI-demos/lua/fred_attack_utils.lua"
        local LS = wesnoth.require "lua/location_set.lua"
        local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"
        local R = wesnoth.require "~/add-ons/AI-demos/lua/retreat.lua"

        ----------Recruitment -----------------

        local params = {score_function = function () return 181000 end}

        wesnoth.require("~add-ons/AI-demos/lua/generic_recruit_engine.lua").init(ai, fred, params)

        local function print_time(...)
            if fred.data.turn_start_time then
                AH.print_ts_delta(fred.data.turn_start_time, ...)
            else
                AH.print_ts(...)
            end
        end

        function fred:zone_advance_rating(zone_id, x, y, gamedata)
            local rating = 0

            if (wesnoth.current.side == 1) then
                if (zone_id == 'left') or (zone_id == 'rush_left') then
                    rating = rating + y / 10.

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

                if (zone_id == 'center') or (zone_id == 'rush_center') then
                    rating = rating + y / 10.

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

                if (zone_id == 'right') or (zone_id == 'rush_right') then
                    rating = rating + y / 10.

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
            end

            if (wesnoth.current.side == 2) then
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

            return rating
        end

        function fred:zone_loc_rating(zone_id, x, y)
            local rating = 0

            if (wesnoth.current.side == 1) then
                if (zone_id == 'left') or (zone_id == 'rush_left') then
                    if (y < 13) then
                        rating = (y - 13) * 200
                    end
                end

                if (zone_id == 'center') or (zone_id == 'rush_center') then
                    if (y < 8) then
                        rating = (y - 8) * 200 - 2000
                    end
                    if (y > 10) then
                        rating = (10 - y) * 200 - 2000
                    end
                end

                if (zone_id == 'right') or (zone_id == 'rush_right') then
                    if (y < 9) then
                        rating = (y - 9) * 200 - 2000
                    end
                end
            end

            if (wesnoth.current.side == 2) then
                if (zone_id == 'left') or (zone_id == 'rush_left') then
                    if (y > 12) then
                        rating = (12 - y) * 200
                    end
                end

                if (zone_id == 'center') or (zone_id == 'rush_center') then
                    if (y > 16) then
                        rating = (16 - y) * 200 - 2000
                    end
                    if (y < 14) then
                        rating = (y - 14) * 200 - 2000
                    end
                end

                if (zone_id == 'right') or (zone_id == 'rush_right') then
                    if (y > 15) then
                        rating = (15 - y) * 200 - 2000
                    end
                end
            end

            return rating
        end

        function fred:get_zone_cfgs(gamedata)
            -- Set up the config table for the different map zones
            -- zone_id: ID for the zone; only needed for debug messages
            -- zone_filter: SLF describing the zone
            -- unit_filter: SUF of the units considered for moves for this zone
            -- do_action: if given, evaluate only the listed actions for the zone
            --   if not given, evaluate all actions (that should be the default)
            -- skip_action: actions listed here will be skipped when evaluating, all
            --   other actions will be evaluated.
            --   !!! Obviously, only do_action _or_ skip_action should be given, not both !!!
            -- attack: table describing the type of zone attack to be done
            --   - use_enemies_in_reach: if set, use enemies that can reach zone, otherwise use units inside the zone
            --       Note: only use with very small zones, otherwise it can be very slow
            -- hold: table describing where to hold a position
            --   - x: the central x coordinate of the position to hold
            --   - max_y: the maximum y coordinate where to hold
            --   - hp_ratio: the minimum HP ratio required to hold at this position

            local width, height = wesnoth.get_map_size()
            local cfg_full_map = {
                zone_id = 'full_map',
                zone_filter = { x = '1-' .. width , y = '1-' .. height },
                unit_filter = { x = '1-' .. width , y = '1-' .. height },
                do_action = { retreat_injured_safe = true, villages = true },
            }

            local cfg_leader_threat = {
                zone_id = 'leader_threat',
                zone_filter = { { 'filter', { canrecruit = 'yes', side = wesnoth.current.side } } },
                unit_filter = { x = '1-' .. width , y = '1-' .. height },
                do_action = { attack = true },
                attack = { use_enemies_in_reach = true, enemy_worth = 2.0 }
            }

            local cfg_center, cfg_rush_center, cfg_left, cfg_rush_left, cfg_right, cfg_rush_right
            if (wesnoth.current.side == 1) then
                cfg_center = {
                    zone_id = 'center',
                    priority = 1.0,
                    key_hexes = { { 18, 9 }, { 22, 10 } },
                    zone_filter = { x = '15-24', y = '1-16' },
                    unit_filter = { x = '16-25,15-22', y = '1-13,14-19' },
                    skip_action = { retreat_injured_unsafe = true },
                    hold = { hp_ratio = 1.0 },
                    villages = { units_per_village = 0 }
                }

                --cfg_rush_center = {
                --    zone_id = 'rush_center',
                --    zone_filter = { x = '15-24', y = '1-16' },
                --    unit_filter = { x = '16-25,15-22', y = '1-13,14-19' },
                --    skip_action = { retreat_injured_unsafe = true }
                --}

                cfg_left = {
                    zone_id = 'left',
                    key_hexes = { { 11, 9 } },
                    zone_filter = { x = '4-14', y = '1-15' },
                    unit_filter = { x = '1-15,16-20', y = '1-15,1-6' },
                    skip_action = { retreat_injured_unsafe = true },
                    hold = { hp_ratio = 1.0, unit_ratio = 1.1 }
                }

                --cfg_rush_left = {
                --    zone_id = 'rush_left',
                --    zone_filter = { x = '4-14', y = '1-15' },
                --    unit_filter = { x = '1-15,16-20', y = '1-15,1-6' },
                --    skip_action = { retreat_injured_unsafe = true }
                --}

                cfg_right = {
                    zone_id = 'right',
                    key_hexes = { { 27, 11 } },
                    zone_filter = { x = '24-34', y = '1-17' },
                    unit_filter = { x = '16-99,22-99', y = '1-11,12-25' },
                    skip_action = { retreat_injured_unsafe = true },
                    hold = { hp_ratio = 1.0, unit_ratio = 1.1 }
                }

                cfg_rush_right = {
                    zone_id = 'rush_right',
                    zone_filter = { x = '24-34', y = '1-17' },
                    only_zone_units = true,
                    unit_filter = { x = '16-99,22-99', y = '1-11,12-16' },
                    skip_action = { retreat_injured_unsafe = true }
                }
            end

            if (wesnoth.current.side == 2) then
                cfg_center = {
                    zone_id = 'center',
                    priority = 1.0,
                    key_hexes = { { 20, 15 }, { 16,14 } },
                    zone_filter = { x = '14-23', y = '9-23' },
                    unit_filter = { x = '13-22,16-23', y = '11-23,5-10' },
                    skip_action = { retreat_injured_unsafe = true },
                    hold = { hp_ratio = 1.0 },
                    villages = { units_per_village = 0 }
                }

                cfg_left = {
                    zone_id = 'left',
                    key_hexes = { { 27,16 } },
                    zone_filter = { x = '24-34', y = '10-23' },
                    unit_filter = { x = '23-34,18-22', y = '10-23,19-23' },
                    skip_action = { retreat_injured_unsafe = true },
                    hold = { hp_ratio = 1.0, unit_ratio = 1.1 }
                }

                cfg_right = {
                    zone_id = 'right',
                    key_hexes = { { 27, 11 } },
                    zone_filter = { x = '4-14', y = '7-23' },
                    unit_filter = { x = '1-22,1-16', y = '14-23,1-13' },
                    skip_action = { retreat_injured_unsafe = true },
                    hold = { hp_ratio = 1.0, unit_ratio = 1.1 }
                }

                cfg_rush_right = {
                    zone_id = 'rush_right',
                    zone_filter = { x = '4-14', y = '7-23' },
                    only_zone_units = true,
                    unit_filter = { x = '1-22,1-16', y = '14-23,8-13' },
                    skip_action = { retreat_injured_unsafe = true }
                }
            end

            local cfg_enemy_leader = {
                zone_id = 'enemy_leader',
                zone_filter = { x = '1-' .. width , y = '1-' .. height },
                unit_filter = { x = '1-' .. width , y = '1-' .. height }
            }

            local sorted_cfgs = {}
            table.insert(sorted_cfgs, cfg_center)
            table.insert(sorted_cfgs, cfg_left)
            table.insert(sorted_cfgs, cfg_right)

            for _,cfg in ipairs(sorted_cfgs) do
                --print('Checking priority of zone: ', cfg.zone_id)

                local hp_enemies, num_enemies = 0, 0
                for enemy_id,enemy_loc in pairs(gamedata.enemies) do
                    local min_turns = 9e99
                    for _,hex in ipairs(cfg.key_hexes) do

                        -- Cannot use gamedata.enemy_turn_maps here, as we need movecost ignoring enemies
                        -- Since this is only to individual hexes, we do the path finding here
                        local old_moves = gamedata.unit_copies[enemy_id].moves
                        gamedata.unit_copies[enemy_id].moves = gamedata.unit_copies[enemy_id].max_moves
                        local path, cost = wesnoth.find_path(
                            gamedata.unit_copies[enemy_id],
                            hex[1], hex[2],
                            { ignore_units = true }
                        )
                        gamedata.unit_copies[enemy_id].moves = old_moves

                        local turns = math.ceil(cost / gamedata.unit_copies[enemy_id].max_moves)

                        if (turns < min_turns) then min_turns = turns end
                    end

                    if (min_turns < 1) then min_turns = 1 end
                    --print('      ', enemy_id, enemy_loc[1], enemy_loc[2], min_turns)

                    if (min_turns <= 2) then
                        hp_enemies = hp_enemies + gamedata.unit_infos[enemy_id].hitpoints / min_turns
                        num_enemies = num_enemies + 1. / min_turns
                    end
                end
                --print('    hp_enemies, num_enemies:', hp_enemies, num_enemies)
                cfg.hp_enemies, cfg.num_enemies = hp_enemies, num_enemies

                -- Any unit that can attack this hex directly counts extra
                local direct_attack = 0
                for _,hex in ipairs(cfg.key_hexes) do
                    local hp = gamedata.enemy_attack_map[hex[1]]
                        and gamedata.enemy_attack_map[hex[1]][hex[2]]
                        and gamedata.enemy_attack_map[hex[1]][hex[2]].hitpoints

                    if hp and (hp > direct_attack) then direct_attack = hp end
                end
                --print('    direct attack:', direct_attack)

                local total_threat = hp_enemies + direct_attack
                --print('    total_threat:', total_threat)

                cfg.score = total_threat * (cfg.priority or 1.)
            end

            table.sort(sorted_cfgs, function(a, b) return a.score > b.score end)

            local cfgs = {}
            table.insert(cfgs, cfg_full_map)
            table.insert(cfgs, cfg_leader_threat)

            for _,cfg in ipairs(sorted_cfgs) do
                --print('Inserting zone: ', cfg.zone_id, cfg.score)
                table.insert(cfgs, cfg)
            end

            if (not fred:full_offensive()) then
                table.insert(cfgs, cfg_rush_right)
                --table.insert(cfgs, cfg_rush_left)
                --table.insert(cfgs, cfg_rush_center)
            end

            table.insert(cfgs, cfg_enemy_leader)

            --print()
            --print('Zone order:')
            --for _,cfg in ipairs(cfgs) do print('  ', cfg.zone_id, cfg.score) end

            return cfgs
        end

        function fred:full_offensive()
            -- Returns true if the conditions to go on all-out offensive are met
            -- Full offensive mode is done mostly by the RCA AI
            -- This is a placeholder for now until Fred is better at the endgame

            local my_hp, enemy_hp = 0, 0
            for id,_ in pairs(fred.data.gamedata.units) do
                local unit_side = fred.data.gamedata.unit_infos[id].side
                if (unit_side == wesnoth.current.side) then
                    my_hp = my_hp + fred.data.gamedata.unit_infos[id].hitpoints
                elseif wesnoth.is_enemy(unit_side, wesnoth.current.side) then
                    enemy_hp = enemy_hp + fred.data.gamedata.unit_infos[id].hitpoints
                end
            end

            local hp_ratio = my_hp / (enemy_hp + 1e-6)

            if (hp_ratio > 1.5) and (wesnoth.current.turn >= 5) then return true end
            return false
        end

        function fred:hold_zone(holders, zonedata, gamedata, move_cache)

print(zonedata.cfg.zone_id)
if (zonedata.cfg.zone_id ~= 'center') then
    return
end

            -- This part starts with a quick and dirt zone analysis for what
            -- *might* be the best positions.  This is calculated by assuming
            -- the same damage and strikes for all units, and calculating the
            -- damage for own and enemy units there based on terrain defense.
            -- In addition, values for the enemies are averaged over all units
            -- that can reach a hex.
            -- The assumption is that this will give us a good pre-selection of
            -- hexes, for which a more detailed analysis can then be done.

            local default_damage, default_strikes = 8, 2


            -- Enemy rating map: average (over all enemy units) of damage received here
            -- Only use hexes the enemies can reach on this turn
            local enemy_rating_map = {}
            for x,tmp in pairs(zonedata.zone_map) do
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
                AH.put_fgumap_labels(enemy_rating_map, 'rating')
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
                AH.put_fgumap_labels(leader_distance_map, 'distance')
                W.message{ speaker = 'narrator', message = zonedata.cfg.zone_id .. ': leader_distance_map' }
            end

            -- First calculate a unit independent rating map
            -- For the time being, this is the just the enemy rating over all
            -- adjacent hexes that are closer to the enemy leader than the hex
            -- being evaluated.
            -- The assumption is that the enemies will be coming from there.
            -- TODO: evaluate when this might break down

            indep_rating_map = {}
            for x,tmp in pairs(zonedata.zone_map) do
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
                AH.put_fgumap_labels(indep_rating_map, 'rating')
                W.message { speaker = 'narrator', message = 'Hold zone ' .. zonedata.cfg.zone_id .. ': unit-independent rating map: rating' }
                AH.put_fgumap_labels(indep_rating_map, 'adj_count')
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
                    AH.put_fgumap_labels(unit_rating_maps[id], 'rating')
                    wesnoth.add_tile_overlay(gamedata.units[id][1], gamedata.units[id][2], { image = "items/orcish-flag.png" })
                    W.message { speaker = 'narrator', message = 'Hold zone: unit-specific rating map: ' .. id }
                    wesnoth.remove_tile_overlay(gamedata.units[id][1], gamedata.units[id][2], { image = "items/orcish-flag.png" })
                end
            end

            -- Next, we do a more detailed single-unit analysis for the best
            -- hexes found in the preselection for each unit

            local new_unit_ratings, rated_units = {}, {}
            local max_hexes_pre = 20 -- number of hexes to analyze for units individually
            local max_hexes = 5 -- number of hexes per unit for placement combos

            -- Need to make sure that the same weapons are used for all counter attack calculations
            local cfg_counter_attack = { cache_weapons = true }

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
                    local counter_stats = FAU.calc_counter_attack(target, old_locs, new_locs, gamedata, move_cache, cfg_counter_attack)
                    --print(id, unit_ratings[i].rating, -counter_stats.rating, unit_ratings[i].x, unit_ratings[i].y)

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

            -- Sorting this will now give us the order of units to be considered
            table.sort(rated_units, function(a, b) return a.rating > b.rating end)

            -- If there's only one unit, we're done and simply use the best hex found
            if (#rated_units == 1) then
                local id1 = rated_units[1].id

                best_hexes = { { new_unit_ratings[id1][1].x, new_unit_ratings[id1][1].y } }
                best_units = { gamedata.unit_infos[id1] }

                return best_units, best_hexes
            end

            -- Otherwise, we choose the best 2 or 3 units and do a combo
            -- placements analysis
            -- TODO: this is currently hard-coded to use 3 units if they are
            -- available, 2 otherwise.  Make this configurable later (and it's
            -- also quite inelegant this way!)

            local id1 = rated_units[1].id
            local max_hexes_1 = math.min(max_hexes, #new_unit_ratings[id1])
            --print(id1, max_hexes_1, #new_unit_ratings[id1])

            local id2 = rated_units[2].id
            local max_hexes_2 = math.min(max_hexes, #new_unit_ratings[id2])
            --print(id2, max_hexes_2, #new_unit_ratings[id2])

            local id3, max_hexes_3
            if (#rated_units > 2) then
                id3 = rated_units[3].id
                max_hexes_3 = math.min(max_hexes, #new_unit_ratings[id3])
                --print(id3, max_hexes_3, #new_unit_ratings[id3])
            end

            max_hexes = nil -- just so that it is not accidentally used


            local max_rating, best_combo = -9e99, {}

            for i1 = 1, max_hexes_1 do
                x1 = new_unit_ratings[id1][i1].x
                y1 = new_unit_ratings[id1][i1].y
                --print(x1 .. ',' .. y1)

                for i2 = 1, max_hexes_2 do
                    x2 = new_unit_ratings[id1][i2].x
                    y2 = new_unit_ratings[id1][i2].y

                    if (x2 == x1) and (y2 == y1) then
                        -- If this hex is already used by first unit
                        --print('  ' .. x2 .. ',' .. y2 .. ' -- skipping')
                    else
                        --print('  ' .. x2 .. ',' .. y2)

                        -- Different code for whether there are 3 or 2 units available
                        -- TODO: put this in a recursive functions, because it is
                        -- very inelegant this way and in order to make it configurable
                        -- for different numbers of units

                        if id3 then
                            for i3 = 1, max_hexes_3 do
                                x3 = new_unit_ratings[id1][i3].x
                                y3 = new_unit_ratings[id1][i3].y

                                if ((x3 == x1) and (y3 == y1)) or ((x3 == x2) and (y3 == y2)) then
                                    -- If this hex is already used by first or second unit
                                    --print('    ' .. x3 .. ',' .. y3 .. ' -- skipping')
                                else
                                    --print('    ' .. x3 .. ',' .. y3)

                                    local old_locs = {
                                        { gamedata.unit_copies[id1].x, gamedata.unit_copies[id1].y },
                                        { gamedata.unit_copies[id2].x, gamedata.unit_copies[id2].y },
                                        { gamedata.unit_copies[id3].x, gamedata.unit_copies[id3].y }
                                    }
                                    local new_locs = {
                                        { x1, y1 },
                                        { x2, y2 },
                                        { x3, y3 }
                                    }

                                    local target1 = {}
                                    target1[id1] = { x1, y1 }
                                    local counter_stats1 = FAU.calc_counter_attack(target1, old_locs, new_locs, gamedata, move_cache, cfg_counter_attack)

                                    local target2 = {}
                                    target2[id2] = { x2, y2 }
                                    local counter_stats2 = FAU.calc_counter_attack(target2, old_locs, new_locs, gamedata, move_cache, cfg_counter_attack)

                                    local target3 = {}
                                    target3[id3] = { x3, y3 }
                                    local counter_stats3 = FAU.calc_counter_attack(target3, old_locs, new_locs, gamedata, move_cache, cfg_counter_attack)

                                    -- Important: the counter_stats rating is the rating of the
                                    -- counter attack. We want this to be as *bad* as possible
                                    local rating = - counter_stats1.rating - counter_stats2.rating - counter_stats3.rating
                                    --print('      ', rating, counter_stats1.rating, counter_stats2.rating, counter_stats3.rating)

                                    -- We want to exclude combinations where one unit is out of attack range
                                    -- as this is for holding a zone, not protecting units.
                                    -- TODO: The latter might be added as an option later.
                                    if (rating > max_rating)
                                        and ((counter_stats1.att_rating ~= 0) or (counter_stats1.def_rating ~= 0))
                                        and ((counter_stats2.att_rating ~= 0) or (counter_stats2.def_rating ~= 0))
                                        and ((counter_stats3.att_rating ~= 0) or (counter_stats3.def_rating ~= 0))
                                    then
                                        max_rating = rating
                                        best_hexes = { { x1, y1 }, { x2, y2 }, { x3, y3 } }
                                        best_units = { gamedata.unit_infos[id1], gamedata.unit_infos[id2], gamedata.unit_infos[id3] }
                                    end
                                end
                            end
                        else
                            local old_locs = {
                                { gamedata.unit_copies[id1].x, gamedata.unit_copies[id1].y },
                                { gamedata.unit_copies[id2].x, gamedata.unit_copies[id2].y }
                            }
                            local new_locs = {
                                { x1, y1 },
                                { x2, y2 }
                            }

                            local target1 = {}
                            target1[id1] = { x1, y1 }
                            local counter_stats1 = FAU.calc_counter_attack(target1, old_locs, new_locs, gamedata, move_cache, cfg_counter_attack)

                            local target2 = {}
                            target2[id2] = { x2, y2 }
                            local counter_stats2 = FAU.calc_counter_attack(target2, old_locs, new_locs, gamedata, move_cache, cfg_counter_attack)

                            -- Important: the counter_stats rating is the rating of the
                            -- counter attack. We want this to be as *bad* as possible
                            local rating = - counter_stats1.rating - counter_stats2.rating
                            --print('      ', rating, counter_stats1.rating, counter_stats2.rating)

                            -- We want to exclude combinations where one unit is out of attack range
                            -- as this is for holding a zone, not protecting units.
                            -- TODO: The latter might be added as an option later.
                            if (rating > max_rating)
                                and ((counter_stats1.att_rating ~= 0) or (counter_stats1.def_rating ~= 0))
                                and ((counter_stats2.att_rating ~= 0) or (counter_stats2.def_rating ~= 0))
                            then
                                max_rating = rating
                                best_hexes = { { x1, y1 }, { x2, y2 } }
                                best_units = { gamedata.unit_infos[id1], gamedata.unit_infos[id2] }
                            end
                        end
                    end
                end
            end

            -- TODO: For now, we only consider holding of threatened hexes here.
            -- Advancing on unthreatened hexes will be dealt with separately in
            -- the future, but we keep the code below for reference until then
            if 1 then return best_units, best_hexes end

            if (max_rating > -9e99) then
                -- If the best hex is unthreatened,
                -- check whether another mostly unthreatened hex farther
                -- advanced in the zone can be gotten to.
                -- This needs to be separate from and in addition to the step above (if unit cannot get into zone)

                local hp_factor = 1.1

                local enemy_hp =
                    gamedata.enemy_attack_map[best_hex[1]]
                    and gamedata.enemy_attack_map[best_hex[1]][best_hex[2]]
                    and gamedata.enemy_attack_map[best_hex[1]][best_hex[2]].hitpoints
                enemy_hp = enemy_hp or 0

                if (enemy_hp == 0) then
                    --print(zonedata.cfg.zone_id, ': reconsidering best hex', best_unit.id, '->', best_hex[1], best_hex[2])

                    local new_rating_map = {}
                    max_rating = -9e99
                    for x,tmp in pairs(gamedata.reach_maps[best_unit.id]) do
                        for y,_ in pairs(tmp) do
                            -- ... or if it is threatened by less HP than the unit moving there has itself
                            -- This is only approximate, of course, potentially to be changed later
                            local enemy_hp =
                                gamedata.enemy_attack_map[x]
                                and gamedata.enemy_attack_map[x][y]
                                and gamedata.enemy_attack_map[x][y].hitpoints
                            enemy_hp = enemy_hp or 0

                            local best_unit_rating =
                                best_unit_rating_map[x]
                                and best_unit_rating_map[x][y]
                                and best_unit_rating_map[x][y].rating
                            best_unit_rating = best_unit_rating or 1

                            if (enemy_hp == 0) or
                                ((enemy_hp < best_unit.hitpoints * hp_factor) and (best_unit_rating > 0))
                            then
                                local rating = fred:zone_advance_rating(zonedata.cfg.zone_id, x, y, gamedata)

                                -- If the unit is injured and does not regenerate,
                                -- then we very strongly prefer villages

                                if (best_unit.hitpoints < R.min_hp(gamedata.unit_copies[best_unit.id]))
                                    and (not gamedata.unit_infos[best_unit.id].regenerate)
                                then
                                    if gamedata.village_map[x] and gamedata.village_map[x][y] then
                                        rating = rating + 1000
                                    end
                                end

                                if (not new_rating_map[x]) then new_rating_map[x] = {} end
                                new_rating_map[x][y] = { rating = rating }

                                if (rating > max_rating) then
                                    max_rating = rating
                                    best_hex = { x, y }
                                end
                            end
                        end
                    end

                    if show_debug then
                        AH.put_fgumap_labels(new_rating_map, 'rating')
                        W.message { speaker = 'narrator', message = 'new_rating_map' }
                    end
                end

                if show_debug then
                    local loc = gamedata.units[best_unit.id]
                    wesnoth.message('Best unit: ' .. best_unit.id .. ' at ' .. loc[1] .. ',' .. loc[2] .. ' --> ' .. best_hex[1] .. ',' .. best_hex[2] .. '  (rating=' .. max_rating .. ')')
                    wesnoth.select_hex(best_hex[1], best_hex[2])
                end
                return best_unit, best_hex
            end
        end

        ------ Reset variables at beginning of turn -----------

        -- This will be blacklisted after first execution each turn
        function fred:reset_vars_turn_eval()
            return 999998
        end

        function fred:reset_vars_turn_exec()
            --print(' Resetting variables at beginning of Turn ' .. wesnoth.current.turn)

            fred.data.turn_start_time = wesnoth.get_time_stamp() / 1000.
        end

        ------ Reset variables at beginning of each move -----------

        -- This always returns 0 -> will never be executed, but evaluated before each move
        function fred:reset_vars_move_eval()
            --print(' Resetting gamedata tables (etc.) before move')

            fred.data.gamedata = FGU.get_gamedata()
            fred.data.move_cache = {}

            return 0
        end

        function fred:reset_vars_move_exec()
        end

        ------ Stats at beginning of turn -----------

        -- This will be blacklisted after first execution each turn
        function fred:stats_eval()
            return 999990
        end

        function fred:stats_exec()
            local tod = wesnoth.get_time_of_day()
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
                    if owner then
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

            if fred:full_offensive() then print(' Full offensive mode') end
        end

        ------ Clear self.data table at end of turn -----------

        -- This will be blacklisted after first execution each turn, which happens at the very end of each turn
        function fred:clear_self_data_eval()
            return 1
        end

        function fred:clear_self_data_exec()
            --print(' Clearing self.data table at end of Turn ' .. wesnoth.current.turn)

            -- This is mostly done so that there is no chance of corruption of savefiles
            fred.data = {}
        end

        ------ Move leader to keep -----------

        function fred:move_leader_to_keep_eval()
            local score = 480000
            local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'move_leader_to_keep'
            if AH.print_eval() then print_time('     - Evaluating move_leader_to_keep CA:') end

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
            if AH.print_exec() then print_time('   Executing move_leader_to_keep CA') end
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

        --------- zone_control CA ------------

        function fred:zone_action_retreat_injured(zonedata, gamedata)
            -- **** Retreat seriously injured units
            --print_time('retreat')

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

        function fred:zone_action_villages(zonedata, gamedata, move_cache)
            -- Otherwise we go for unowned and enemy-owned villages
            -- This needs to happen for all units, not just not-injured ones
            -- Also includes the leader, if he's on his keep
            -- The rating>100 part is to exclude threatened but already owned villages

            local villages = {}
            for x,arr in pairs(gamedata.village_map) do
                for y,village in pairs(arr) do
                    if zonedata.zone_map[x] and zonedata.zone_map[x][y] then
                        table.insert(villages, { x, y, owner = village.owner })
                    end
                end
            end

            -- Check if a zone unit can get to any of the zone villages
            local max_rating, best_village, best_unit = -9e99, {}, {}
            for _,village in ipairs(villages) do
                for id,unit_loc in pairs(zonedata.zone_units_MP) do
                    --print(id, village[1], village[2])

                    if gamedata.reach_maps[id][village[1]] and gamedata.reach_maps[id][village[1]][village[2]] then
                        -- Calculate counter attack outcome
                        local target = {}
                        target[id] = { village[1], village[2] }

                        local old_locs = { { gamedata.unit_copies[id].x, gamedata.unit_copies[id].y } }
                        local new_locs = { { village[1], village[2] } }

                        local counter_stats = FAU.calc_counter_attack(target, old_locs, new_locs, gamedata, move_cache)
                        --DBG.dbms(counter_stats)

                        -- Maximum allowable chance to die
                        local max_hp_chance_zero = 0.33
                        if gamedata.unit_infos[id].canrecruit then max_hp_chance_zero = 0 end

                        if (counter_stats.hp_chance[0] <= max_hp_chance_zero) then
                            local rating = 0

                            -- Unowned and enemy-owned villages get a large bonus
                            -- but we do not seek them out specifically, as the standard CA does that
                            -- That means, we only do the rest for villages that can be reached by an enemy
                            if (not village.owner) then
                                rating = rating + 1000
                            else
                                if wesnoth.is_enemy(village.owner, wesnoth.current.side) then rating = rating + 2000 end
                            end
                            --print(' owner rating', rating)

                            -- It is impossible for these numbers to add up to zero, so we do the
                            -- detail rating only for those
                            if (rating ~= 0) then
                                -- Take the most injured unit preferentially
                                -- It was checked above that chance to die is acceptable
                                rating = rating + (gamedata.unit_infos[id].max_hitpoints - gamedata.unit_infos[id].hitpoints) / 100.
                                --print(' HP rating', rating)

                                -- We also want to move the "farthest back" unit first
                                -- and take villages from the back first
                                local unit_advance_rating = fred:zone_advance_rating(
                                    zonedata.cfg.zone_id, unit_loc[1], unit_loc[2], gamedata
                                )
                                local village_advance_rating = fred:zone_advance_rating(
                                    zonedata.cfg.zone_id, village[1], village[2], gamedata
                                )
                                --print(' unit_advance_rating, village_advance_rating', unit_advance_rating, village_advance_rating)

                                rating = rating - unit_advance_rating / 10. - village_advance_rating / 1000.

                                -- If this is the leader, make him the preferred village taker
                                if gamedata.unit_infos[id].canrecruit then
                                    rating = rating + 2
                                end

                                if (rating > max_rating) then
                                    max_rating, best_village, best_unit = rating, village, gamedata.unit_infos[id]
                                end
                            end
                        end
                    end
                end
            end
            --print('max_rating', max_rating, best_village[1], best_village[2])

            if (max_rating > -9e99) then
                local action = { units = {}, dsts = {} }
                action.units[1], action.dsts[1] = best_unit, best_village
                action.rating = max_rating
                action.action = zonedata.cfg.zone_id .. ': ' .. 'grab villages'
                return action
            end
        end

        function fred:zone_action_attack(zonedata, gamedata, move_cache)
            --print_time(zonedata.cfg.zone_id, 'attack')

            local targets = {}
            -- If cfg.attack.use_enemies_in_reach is set, we use all enemies that
            -- can get to the zone (Note: this should only be used for small zones,
            -- such as that consisting only of the AI leader position, otherwise it
            -- might be very slow!!!)
            if zonedata.cfg.attack and zonedata.cfg.attack.use_enemies_in_reach then
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
            -- Otherwise use all units inside the zone
            else
                for id,loc in pairs(gamedata.enemies) do
                    if wesnoth.match_unit(gamedata.unit_copies[id], zonedata.cfg.unit_filter) then
                        local target = {}
                        target[id] = loc
                        table.insert(targets, target)
                    end
                end
            end

            local attacker_map = {}
            for id,loc in pairs(zonedata.zone_units_attacks) do
                attacker_map[loc[1] * 1000 + loc[2]] = id
            end

            local combo_ratings = {}
            for _,target in pairs(targets) do
                local target_id, target_loc = next(target)
                local target_proxy = wesnoth.get_unit(target_loc[1], target_loc[2])

                local is_trappable_enemy = true
                if gamedata.unit_infos[target_id].skirmisher then
                    is_trappable_enemy = false
                end
                --print(target_id, '  trappable:', is_trappable_enemy)

                -- How much more valuable do we consider the enemy units than our own
                local enemy_worth = 1.1
                if zonedata.cfg.attack and zonedata.cfg.attack.enemy_worth then
                    enemy_worth = zonedata.cfg.attack.enemy_worth
                end
                --print_time('\n', target_id, enemy_worth)

                local attack_combos = FAU.get_attack_combos(
                    zonedata.zone_units_attacks, target, gamedata.reach_maps
                )
                --print_time('#attack_combos', #attack_combos)

                local enemy_on_village = gamedata.village_map[target_loc[1]]
                    and gamedata.village_map[target_loc[1]][target_loc[2]]
                local enemy_cost = gamedata.unit_infos[target_id].cost
                --print('enemy_cost, enemy_on_village', enemy_cost, enemy_on_village)

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
                            gamedata, move_cache
                    )
                    --DBG.dbms(combo_def_stat)
                    --print('   combo ratings:  ', combo_rating, combo_att_rating, combo_def_rating)

                    -- Don't attack if the leader is involved and has chance to die > 0
                    local do_attack = true

                    --print('     damage taken, done, enemy_worth:', combo_att_rating, combo_def_rating, enemy_worth)
                    -- Note: att_rating is the negative of the damage taken
                    if (not FAU.is_acceptable_attack(-combo_att_rating, combo_def_rating, enemy_worth)) then
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
                            local penalty = 10. / gamedata.unit_infos[target_id].max_hitpoints
                            penalty = penalty * gamedata.unit_infos[target_id].cost * adj_unocc_village
                            --print('Applying village penalty', combo_rating, penalty)
                            combo_rating = combo_rating - penalty

                            -- In that case, also don't give the trapping bonus
                            attempt_trapping = false
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

                            -- Now check if any of this would result in trapping
                            local trapping_bonus = false
                            if (count > 1) then
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

                            -- For each such village found, we give a bonus eqivalent to 8 HP of the target
                            if trapping_bonus then
                                local bonus = 8. / gamedata.unit_infos[target_id].max_hitpoints
                                bonus = bonus * gamedata.unit_infos[target_id].cost
                                --print('Applying trapping bonus', combo_rating, bonus)
                                combo_rating = combo_rating + bonus
                            end
                        end

                        -- Discourage use of poisoners in attacks that may result in kill
                        if (combo_def_stat.hp_chance[0] > 0) then
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
                                local penalty = 8. / gamedata.unit_infos[target_id].max_hitpoints
                                penalty = penalty * gamedata.unit_infos[target_id].cost * number_poisoners
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
                            enemy_worth = enemy_worth
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

                --print_time('Checking counter attack for attack on', count, next(combo.target), combo.enemy_worth, combo.rating)

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
                if (hp < 1) then hp = 1 end

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
                        attacker_moved, old_locs, combo.dsts, gamedata, move_cache
                    )

                    local counter_rating = counter_stats.rating
                    local counter_att_rating = counter_stats.att_rating
                    local counter_def_rating = counter_stats.def_rating
                    --print_time('   counter ratings:', counter_rating, counter_att_rating, counter_def_rating)

                    if (counter_rating > max_counter_rating) then
                        max_counter_rating = counter_rating
                    end

                    local counter_min_hp = counter_stats.min_hp

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
                        -- attacker.hitpoints is freduced to the average HP outcome of the attack
                        -- However, min_hp for the counter also contains this freduction, so
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
                        --print('     damage taken, done, enemy_worth:', damage_taken, damage_done, combo.enemy_worth)

                        if (not FAU.is_acceptable_attack(damage_taken, damage_done, combo.enemy_worth)) then
                            acceptable_counter = false
                            break
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

                --print_time('acceptable_counter', acceptable_counter)
                if acceptable_counter then
                    local total_rating = combo.rating - max_counter_rating
                    --print('rating, counter_rating, total_rating', combo.rating, max_counter_rating, total_rating)
                    -- Only execute the first of these attacks

                    if (total_rating > max_total_rating) then
                        max_total_rating = total_rating

                        action = { units = {}, dsts = {}, enemy = combo.target }
                        action.units, action.dsts = combo.attackers, combo.dsts
                        action.action = zonedata.cfg.zone_id .. ': ' .. 'attack'
                    end
                end
            end

            return action  -- returns nil is no acceptable attack was found
        end

        function fred:zone_action_hold(zonedata, gamedata, move_cache)
            --print_time('hold', zonedata.cfg.zone_id)

            -- The leader does not participate in position holding (for now, at least)
            -- We also exclude severely injured units
            local holders = {}
            for id,loc in pairs(zonedata.zone_units_MP) do
                if (not gamedata.unit_infos[id].canrecruit)
                    and (gamedata.unit_infos[id].hitpoints >= R.min_hp(gamedata.unit_copies[id]))
                then
                    holders[id] = loc
                end
            end

            if (not next(holders)) then return end

            -- Only check for possible position holding if hold.hp_ratio and hold.unit_ratio are met
            -- If hold.hp_ratio and hold.unit_ratio are not provided, holding is done by default
            local eval_hold = true

            if zonedata.cfg.hold and zonedata.cfg.hold.hp_ratio then
                --print('Checking for HP ratio', zonedata.cfg.zone_id, zonedata.cfg.hold.hp_ratio)

                local hp_units_noMP = 0
                for id,loc in pairs(zonedata.zone_units_noMP) do
                    hp_units_noMP = hp_units_noMP + gamedata.unit_infos[id].hitpoints
                end

                local hp_ratio = 1000
                if (zonedata.cfg.hp_enemies > 0) then
                    hp_ratio = hp_units_noMP / zonedata.cfg.hp_enemies
                end
                --print('  hp_ratio', hp_ratio)

                if (hp_ratio >= zonedata.cfg.hold.hp_ratio) then
                    eval_hold = false
                end
            end
            --print('eval_hold 1', eval_hold)

            if eval_hold and zonedata.cfg.hold and zonedata.cfg.hold.unit_ratio then
                --print('Checking for unit ratio', zonedata.cfg.zone_id, zonedata.cfg.hold.unit_ratio)

                local num_units_noMP = 0
                for id,loc in pairs(zonedata.zone_units_noMP) do
                    num_units_noMP = num_units_noMP + 1
                end

                local unit_ratio = 1000
                if (zonedata.cfg.num_enemies > 0) then
                    unit_ratio = num_units_noMP / zonedata.cfg.num_enemies
                end
                --print('  unit_ratio', unit_ratio)

                if (unit_ratio >= zonedata.cfg.hold.unit_ratio) then
                    eval_hold = false
                end
            end
            --print('eval_hold 2', eval_hold)

            -- If there are unoccupied or enemy-occupied villages in the hold zone, send units there,
            -- if we do not have enough units that have moved already in the zone
            if (not eval_hold) then
                local units_per_village = 0.5
                if zonedata.cfg.villages and zonedata.cfg.villages.units_per_village then
                    units_per_village = zonedata.cfg.villages.units_per_village
                end

                local count_units_noMP = 0
                for id,_ in pairs(zonedata.zone_units_noMP) do
                    if (not gamedata.unit_infos[id].canrecruit) then
                        count_units_noMP = count_units_noMP + 1
                    end
                end

                local count_not_own_villages = 0
                for x,arr in pairs(gamedata.village_map) do
                    for y,village in pairs(arr) do
                        if zonedata.zone_map[x] and zonedata.zone_map[x][y] then
                            if (not village.owner) or wesnoth.is_enemy(village.owner, wesnoth.current.side) then
                                count_not_own_villages = count_not_own_villages + 1
                            end
                        end
                    end
                end

                if (count_units_noMP < count_not_own_villages * units_per_village) then
                    eval_hold, get_villages = true, true
                end
            end
            --print('eval_hold 2', eval_hold)

            if eval_hold then
                local units, dsts = fred:hold_zone(holders, zonedata, gamedata, move_cache)

                local action
                if unit then
                    action = { units = { unit }, dsts = { dst } }
                    action.action = zonedata.cfg.zone_id .. ': ' .. 'hold position'
                end
                return action
            end
        end

        function fred:high_priority_attack(unit_info, zonedata, gamedata, move_cache)
            local attacker = {}
            attacker[unit_info.id] = gamedata.units[unit_info.id]

            local max_rating, best_target, best_hex = -9e99
            for enemy_id,enemy_loc in pairs(gamedata.enemies) do
                local target = {}
                target[enemy_id] = enemy_loc

                local attacks = FAU.get_attack_combos(attacker, target, gamedata.reach_maps)

                for _,attack in ipairs(attacks) do
                    local src, dst = next(attack)
                    local dst = { math.floor(dst / 1000), dst % 1000 }

                    if (gamedata.enemy_attack_map[dst[1]][dst[2]].units <= 1) then
                        local target_proxy = wesnoth.get_unit(enemy_loc[1], enemy_loc[2])

                        local att_stat, def_stat = FAU.battle_outcome(
                            gamedata.unit_copies[unit_info.id], target_proxy, dst,
                            unit_info, gamedata.unit_infos[enemy_id], gamedata, move_cache
                        )

                        local rating = FAU.attack_rating(
                            { unit_info }, gamedata.unit_infos[enemy_id], { dst },
                            { att_stat }, def_stat, gamedata
                        )
                        --print('high priority attack rating', rating)

                        -- Only if this has a high chance to kill and no chance to die do we consider it
                        if (rating > 0) and (rating > max_rating)
                            and (def_stat.hp_chance[0] > 0.59) and (att_stat.hp_chance[0] == 0)
                        then
                            max_rating = rating
                            best_target, best_hex = target, dst
                        end
                    end
                end
            end

            if best_target then
                local action = { units = { unit_info }, dsts = { best_hex }, enemy = best_target }
                action.action = zonedata.cfg.zone_id .. ': ' .. 'high priority attack'
                return action
            end
        end

        function fred:get_zone_action(cfg, gamedata, move_cache)
            -- Find the best action to do in the zone described in 'cfg'
            -- This is all done together in one function, rather than in separate CAs so that
            --  1. Zones get done one at a time (rather than one CA at a time)
            --  2. Relative scoring of different types of moves is possible

            local zonedata = {
                zone_units = {},
                zone_units_MP = {},
                zone_units_attacks = {},
                zone_units_noMP = {},
                cfg = cfg
            }

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

            local zone = wesnoth.get_locations(cfg.zone_filter)
            zonedata.zone_map = {}
            for _,loc in ipairs(zone) do
                if (not zonedata.zone_map[loc[1]]) then
                    zonedata.zone_map[loc[1]] = {}
                end
                zonedata.zone_map[loc[1]][loc[2]] = true
            end

            -- **** Retreat severely injured units evaluation ****
            --print_time('  ' .. cfg.zone_id .. ': retreat_injured eval')
            local retreat_action
            if (not cfg.do_action) or cfg.do_action.retreat_injured_safe then
                if (not cfg.skip_action) or (not cfg.skip_action.retreat_injured) then
                    local healloc, safeloc  -- boolean indicating whether the destination is a healing location
                    retreat_action, healloc, safeloc = fred:zone_action_retreat_injured(zonedata, gamedata)
                    -- Only retreat to healing locations at this time, other locations later
                    if retreat_action and healloc and safeloc then
                        --print(action.action)
                        return retreat_action
                    end
                end
            end

            -- **** Villages evaluation -- unowned and enemy-owned villages ****
            --print_time('  ' .. cfg.zone_id .. ': villages eval')
            local village_action = nil
            if (not cfg.do_action) or cfg.do_action.villages then
                if (not cfg.skip_action) or (not cfg.skip_action.villages) then
                    village_action = fred:zone_action_villages(zonedata, gamedata, move_cache)
                    if village_action and (village_action.rating > 100) then
                        --print_time(village_action.action)
                        local attack_action = fred:high_priority_attack(village_action.units[1], zonedata, gamedata, move_cache)
                        return attack_action or village_action
                    end
                end
            end

            -- **** Attack evaluation ****
            --print_time('  ' .. cfg.zone_id .. ': attack eval')
            if (not cfg.do_action) or cfg.do_action.attack then
                if (not cfg.skip_action) or (not cfg.skip_action.attack) then
                    local action = fred:zone_action_attack(zonedata, gamedata, move_cache)
                    if action then
                        --print(action.action)

                        -- Put the own units with MP back out there
                        -- !!!! This eventually needs to be done for all actions
                        return action
                    end
                end
            end

            -- **** Hold position evaluation ****
            --print_time('  ' .. cfg.zone_id .. ': hold eval')
            if (not cfg.do_action) or cfg.do_action.hold then
                if (not cfg.skip_action) or (not cfg.skip_action.hold) then
                    local action = fred:zone_action_hold(zonedata, gamedata, move_cache)
                    if action then
                        --print_time(action.action)
                        return action
                    end
                end
            end

            -- Now we retreat injured units to other (unsafe) locations
            if (not cfg.do_action) or cfg.do_action.retreat_injured_unsafe then
                if (not cfg.skip_action) or (not cfg.skip_action.retreat_injured_unsafe) then
                    if retreat_action then
                        --print(action.action)
                        return retreat_action
                    end
                end
            end

            return nil  -- This is technically unnecessary
        end

        function fred:zone_control_eval()
            local score_zone_control = 350000
            local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'zone_control'
            if AH.print_eval() then print_time('     - Evaluating zone_control CA:') end

            local cfgs = fred:get_zone_cfgs(fred.data.gamedata)
            for i_c,cfg in ipairs(cfgs) do
                --print_time('zone_control: ', cfg.zone_id)

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
                    fred.data.zone_action = zone_action
                    AH.done_eval_messages(start_time, ca_name)
                    return score_zone_control
                end
            end

            AH.done_eval_messages(start_time, ca_name)
            return 0
        end

        function fred:zone_control_exec()
            local action = fred.data.zone_action.action

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

                    local _, combo_def_stat = FAU.attack_combo_eval(
                        attacker_copies, enemy_proxy,
                        fred.data.zone_action.dsts,
                        attacker_infos, defender_info,
                        fred.data.gamedata, fred.data.move_cache
                    )

                    if (combo_def_stat.hp_chance[0] > 0) then
                        --print_time('Reordering units for attack to maximize XP gain')

                        local min_XP_diff, best_ind = 9e99
                        for ind,unit in ipairs(fred.data.zone_action.units) do
                            local XP_diff = unit.max_experience - unit.experience
                            -- Add HP as minor rating
                            XP_diff = XP_diff + unit.hitpoints / 100.

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

                -- If this is the leader, recruit first
                -- We're doing that by running a mini CA eval/exec loop
                if unit.canrecruit then
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

                if AH.print_exec() then print_time('   Executing zone_control CA ' .. action) end
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
            end

            fred.data.zone_action = nil
        end

        function fred:finish_turn_eval()
            local score_finish_turn = 170000
            local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'finish_turn'
            if AH.print_eval() then print_time('     - Evaluating finish_turn CA:') end

            local gamedata = fred.data.gamedata
            local move_cache = fred.data.move_cache

            -- Extract all AI units with MP left (for counter attack calculation)
            local extracted_units = {}
            for _,loc in pairs(gamedata.my_units_MP) do
                local unit_proxy = wesnoth.get_unit(loc[1], loc[2])
                wesnoth.extract_unit(unit_proxy)
                table.insert(extracted_units, unit_proxy)  -- Not a proxy unit any more at this point
            end

            -- Retreat any remaining injured units to villages if possible and
            -- if the village is safer than their current position
            local injured_units = {}
            for id,loc in pairs(gamedata.my_units_MP) do
                if (gamedata.unit_infos[id].hitpoints < gamedata.unit_infos[id].max_hitpoints)
                    or gamedata.unit_copies[id].status.poisoned
                then
                    injured_units[id] = loc
                end
            end

            local max_rating, best_unit, best_dst = -9e99
            for id,loc in pairs(injured_units) do
                -- Counter attack outcome at the unit's current location
                local injured_unit_current = {}
                injured_unit_current[id] = loc

                local counter_stats_current = FAU.calc_counter_attack(
                    injured_unit_current, { loc }, { loc }, gamedata, move_cache
                )

                for x,tmp in pairs(gamedata.village_map) do
                    for y,village in pairs(tmp) do
                        if gamedata.reach_maps[id][x]
                            and gamedata.reach_maps[id][x][y]
                        then
                            --print('Can reach:', id, x, y)

                             -- Counter attack outcome at the village
                            local injured_unit_village = {}
                            injured_unit_village[id] = { x, y }

                            local counter_stats_village = FAU.calc_counter_attack(
                                injured_unit_village, { loc }, { { x, y } }, gamedata, move_cache
                            )

                            -- Consider this move only if the outcome of the counter attack is better than
                            -- in the current position (note that that means that the attack rating must be
                            -- _smaller_, since this is the reating for the counter attack)
                            local chance_to_die_improvement = counter_stats_current.hp_chance[0] - counter_stats_village.hp_chance[0]
                            local counter_rating_improvement = counter_stats_current.rating - counter_stats_village.rating

                            if (chance_to_die_improvement >= 0) and (counter_rating_improvement >= 0) then
                                --print('  -> better counter_stats at new position', chance_to_die_improvement, counter_rating_improvement)

                                -- Counter rating improvement is the potential gain in gold, so we use that
                                local rating = counter_rating_improvement
                                --print('  rating:', rating)

                                if (rating > max_rating) then
                                    max_rating = rating
                                    best_unit = gamedata.unit_copies[id]
                                    best_dst = { x, y }
                                end
                            end
                        end
                    end
                end
            end

            for _,extracted_unit in ipairs(extracted_units) do wesnoth.put_unit(extracted_unit) end

            if best_unit then
                fred.data.finish_unit = best_unit
                fred.data.finish_dst = best_dst

                return score_finish_turn
            end

            -- Check all units with attacks but no MP left.
            -- Check whether attack + counter attack result on adjacent units
            -- is better than counter attack alone.
            local max_rating, best_attacker, best_target_proxy = -9e99
            for id,loc in pairs(gamedata.my_units_noMP) do
                if (gamedata.unit_copies[id].attacks_left > 0) then
                    local attacker = {}
                    attacker[id] = loc
                    local attacker_proxy = wesnoth.get_unit(loc[1], loc[2])
                    --print('\nattacks left:', id)

                    for xa,ya in H.adjacent_tiles(loc[1], loc[2]) do
                        local target_id = gamedata.enemy_map[xa]
                           and gamedata.enemy_map[xa][ya]
                           and gamedata.enemy_map[xa][ya].id

                        local counter_stats_before
                        if target_id then
                            local target_proxy = wesnoth.get_unit(xa, ya)
                            --print('  target:', target_id)

                            -- Counter attack rating if not attacking target first
                            if not counter_stats_before then
                                counter_stats_before = FAU.calc_counter_attack(
                                    attacker, { loc }, { loc }, gamedata, move_cache
                                )
                            end
                            --DBG.dbms(counter_stats_before)
                            --print('    counter rating before:', counter_stats_before.rating)

                            -- Rating of attack on target
                            local att_stat, def_stat = FAU.battle_outcome(
                                gamedata.unit_copies[id], target_proxy, loc,
                                gamedata.unit_infos[id], gamedata.unit_infos[target_id],
                                gamedata, move_cache
                            )

                            local attack_rating = FAU.attack_rating(
                                { gamedata.unit_infos[id] }, gamedata.unit_infos[target_id], { loc },
                                { att_stat }, def_stat, gamedata
                            )
                            --print('    attack rating:', attack_rating)

                            -- Counter attack rating after attacking target first
                            -- Use average outcome from forward attack as input
                            local old_HP_attacker = attacker_proxy.hitpoints
                            local hp = att_stat.average_hp
                            if (hp < 1) then hp = 1 end
                            gamedata.unit_infos[id].hitpoints = hp
                            gamedata.unit_copies[id].hitpoints = hp
                            attacker_proxy.hitpoints = hp

                            local old_HP_target = target_proxy.hitpoints
                            local hp = def_stat.average_hp
                            if (hp < 1) then hp = 1 end
                            gamedata.unit_infos[target_id].hitpoints = hp
                            gamedata.unit_copies[target_id].hitpoints = hp
                            target_proxy.hitpoints = hp

                            local counter_stats_after = FAU.calc_counter_attack(
                                attacker, { loc }, { loc }, gamedata, move_cache
                            )
                            --DBG.dbms(counter_stats_after)
                            --print('    counter rating after:', counter_stats_after.rating)

                            gamedata.unit_infos[id].hitpoints = old_HP_attacker
                            gamedata.unit_copies[id].hitpoints = old_HP_attacker
                            attacker_proxy.hitpoints = old_HP_attacker

                            gamedata.unit_infos[target_id].hitpoints = old_HP_target
                            gamedata.unit_copies[target_id].hitpoints = old_HP_target
                            target_proxy.hitpoints = old_HP_target

                            -- Rating before = - counter_stats_before.rating
                            -- Rating after  = attack_rating - counter_stats_after.rating
                            local rating = attack_rating - counter_stats_after.rating + counter_stats_before.rating
                            --print('    --> rating:', rating)

                            if (rating > 0) and (rating > max_rating) then
                                max_rating = rating
                                best_attacker, best_target_proxy = gamedata.unit_copies[id], target_proxy
                            end
                        end
                    end
                end
            end

            if best_attacker then
                fred.data.finish_attacker = best_attacker
                fred.data.finish_target_proxy = best_target_proxy

                return score_finish_turn
            end

            -- Otherwise, if any units have attacks or moves left, take them away
            if next(gamedata.my_units_MP) then
                return score_finish_turn
            end

            for id,_ in pairs(gamedata.my_units) do
                if (gamedata.unit_copies[id].attacks_left > 0) then
                    return score_finish_turn
                end
            end

            return 0
        end

        function fred:finish_turn_exec()
            if AH.print_exec() then print_time('   Executing finish_turn CA') end

            if fred.data.finish_attacker then
                AH.checked_attack(ai, fred.data.finish_attacker, fred.data.finish_target_proxy)

                fred.data.finish_attacker = nil
                fred.data.finish_target_proxy = nil

                return
            end

            if fred.data.finish_unit then
                AH.movefull_outofway_stopunit(ai, fred.data.finish_unit, fred.data.finish_dst)

                fred.data.finish_unit = nil
                fred.data.finish_dst = nil

                return
            end

            for id,loc in pairs(fred.data.gamedata.my_units_MP) do
                local unit_proxy = wesnoth.get_unit(loc[1], loc[2])
                --print('Taking moves away:', unit_proxy.id)
                AH.checked_stopunit_moves(ai, unit_proxy)
            end

            for id,loc in pairs(fred.data.gamedata.my_units) do
                if (fred.data.gamedata.unit_copies[id].attacks_left > 0) then
                    local unit_proxy = wesnoth.get_unit(loc[1], loc[2])
                    --print('Taking attacks away:', unit_proxy.id)
                    AH.checked_stopunit_attacks(ai, unit_proxy)
                end
            end
        end

        return fred
    end
}
