return {
    init = function(ai)

        local grunt_rush_FLS1 = {}

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        local BC = wesnoth.require "~/add-ons/AI-demos/lua/battle_calcs.lua"
        local FGU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_gamestate_utils.lua"
        local FGUI = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_gamestate_utils_incremental.lua"
        local FAU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack_utils.lua"
        local LS = wesnoth.require "lua/location_set.lua"
        local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"
        local R = wesnoth.require "~/add-ons/AI-demos/lua/retreat.lua"

        ----------Recruitment -----------------

        local params = {score_function = function () return 181000 end}

        wesnoth.require("~add-ons/AI-demos/lua/generic_recruit_engine.lua").init(ai, grunt_rush_FLS1, params)

        local function print_time(...)
            if grunt_rush_FLS1.data.turn_start_time then
                AH.print_ts_delta(grunt_rush_FLS1.data.turn_start_time, ...)
            else
                AH.print_ts(...)
            end
        end

        function grunt_rush_FLS1:zone_advance_rating(zone_id, x, y, gamedata)
            local rating = 0

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

        function grunt_rush_FLS1:zone_loc_rating(zone_id, x, y)
            local rating = 0

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

            return rating
        end

        function grunt_rush_FLS1:get_zone_cfgs(gamedata)
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
            -- retreat_villages: array of villages to which injured units should retreat

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

            local cfg_center = {
                zone_id = 'center',
                priority = 1.5,
                key_hexes = { { 18, 9 }, { 22, 10 } },
                zone_filter = { x = '15-24', y = '1-16' },
                unit_filter = { x = '16-25,15-22', y = '1-13,14-19' },
                skip_action = { retreat_injured_unsafe = true },
                hold = { x = 18, y = 9, hp_ratio = 1.0 },
                retreat_villages = { { 18, 9 }, { 24, 7 }, { 22, 2 } },
                villages = { units_per_village = 0 }
            }

            local cfg_rush_center = {
                zone_id = 'rush_center',
                zone_filter = { x = '15-24', y = '1-16' },
                unit_filter = { x = '16-25,15-22', y = '1-13,14-19' },
                skip_action = { retreat_injured_unsafe = true },
                hold = { x = 18, y = 9 },
                retreat_villages = { { 18, 9 }, { 24, 7 }, { 22, 2 } },
            }

            local cfg_left = {
                zone_id = 'left',
                key_hexes = { { 11, 9 } },
                zone_filter = { x = '4-14', y = '1-15' },
                unit_filter = { x = '1-15,16-20', y = '1-15,1-6' },
                skip_action = { retreat_injured_unsafe = true },
                hold = { x = 11, y = 9, hp_ratio = 1.0, unit_ratio = 1.1 },
                secure = { x = 11, y = 9, moves_away = 1, min_units = 1.1 },
                retreat_villages = { { 11, 9 }, { 8, 5 }, { 12, 5 }, { 12, 2 } },
                villages = { hold_threatened = true }
            }

            local cfg_rush_left = {
                zone_id = 'rush_left',
                zone_filter = { x = '4-14', y = '1-15' },
                unit_filter = { x = '1-15,16-20', y = '1-15,1-6' },
                skip_action = { retreat_injured_unsafe = true },
                hold = { x = 11, y = 9 },
                retreat_villages = { { 11, 9 }, { 8, 5 }, { 12, 5 }, { 12, 2 } },
            }

            local cfg_right = {
                zone_id = 'right',
                key_hexes = { { 27, 11 } },
                zone_filter = { x = '24-34', y = '1-17' },
                unit_filter = { x = '16-99,22-99', y = '1-11,12-25' },
                skip_action = { retreat_injured_unsafe = true },
                hold = { x = 27, y = 11, hp_ratio = 1.0, unit_ratio = 1.1 },
                secure = { x = 27, y = 11, moves_away = 1, min_units = 1.1 },
                retreat_villages = { { 24, 7 }, { 28, 5 } },
                villages = { hold_threatened = true }
            }

            local cfg_rush_right = {
                zone_id = 'rush_right',
                zone_filter = { x = '24-34', y = '1-17' },
                only_zone_units = true,
                unit_filter = { x = '16-99,22-99', y = '1-11,12-25' },
                skip_action = { retreat_injured_unsafe = true },
                hold = { x = 27, y = 11 },
                retreat_villages = { { 24, 7 }, { 28, 5 } }
            }

            local cfg_enemy_leader = {
                zone_id = 'enemy_leader',
                zone_filter = { x = '1-' .. width , y = '1-' .. height },
                unit_filter = { x = '1-' .. width , y = '1-' .. height },
                hold = { },
            }

            local sorted_cfgs = {}
            table.insert(sorted_cfgs, cfg_center)
            table.insert(sorted_cfgs, cfg_left)
            table.insert(sorted_cfgs, cfg_right)

            for _,cfg in ipairs(sorted_cfgs) do
                --print('Checking priority of zone: ', cfg.zone_id)

                local moves_away = 0
                for enemy_id,enemy_loc in pairs(gamedata.enemies) do
                    local min_turns = 9e99
                    for _,hex in ipairs(cfg.key_hexes) do
                        local turns = gamedata.enemy_turn_maps[enemy_id][hex[1]]
                            and gamedata.enemy_turn_maps[enemy_id][hex[1]][hex[2]]
                            and gamedata.enemy_turn_maps[enemy_id][hex[1]][hex[2]].turns

                        if turns then
                            turns = math.ceil(turns)
                            if (turns < min_turns) then min_turns = turns end
                        end
                    end

                    if (min_turns < 1) then min_turns = 1 end
                    --print('      ', enemy_id, enemy_loc[1], enemy_loc[2], min_turns)

                    if (min_turns <= 2) then
                        moves_away = moves_away + gamedata.unit_infos[enemy_id].hitpoints / min_turns
                    end
                end
                --print('    moves away:', moves_away)

                -- Any unit that can attack this hex directly counts extra
                local direct_attack = 0
                for _,hex in ipairs(cfg.key_hexes) do
                    local hp = gamedata.enemy_attack_map[hex[1]]
                        and gamedata.enemy_attack_map[hex[1]][hex[2]]
                        and gamedata.enemy_attack_map[hex[1]][hex[2]].hitpoints

                    if hp and (hp > direct_attack) then direct_attack = hp end
                end
                --print('    direct attack:', direct_attack)

                local total_threat = moves_away + direct_attack
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
            table.insert(cfgs, cfg_rush_right)
            --table.insert(cfgs, cfg_rush_left)
            --table.insert(cfgs, cfg_rush_center)

            table.insert(cfgs, cfg_enemy_leader)

            --print()
            --print('Zone order:')
            --for _,cfg in ipairs(cfgs) do print('  ', cfg.zone_id, cfg.score) end

            return cfgs
        end

        function grunt_rush_FLS1:full_offensive()
            -- Returns true if the conditions to go on all-out offensive are met
            -- Full offensive mode is done mostly by the RCA AI
            -- This is a placeholder for now until Fred is better at the endgame

            local my_units = AH.get_live_units { side = wesnoth.current.side }
            local enemies = AH.get_live_units {
                { "filter_side", { { "enemy_of", { side = wesnoth.current.side } } } }
            }

            local my_hp, enemy_hp = 0, 0
            for i,u in ipairs(my_units) do my_hp = my_hp + u.hitpoints end
            for i,u in ipairs(enemies) do enemy_hp = enemy_hp + u.hitpoints end

            local hp_ratio = my_hp / (enemy_hp + 1e-6)

            if (hp_ratio > 2.0) and (wesnoth.current.turn >= 5) then return true end
            return false
        end

        function grunt_rush_FLS1:hold_zone(holders, zonedata, gamedata)
            -- Create enemy defense rating map
            local enemy_def_rating_map = {}
            for x,tmp in pairs(zonedata.zone_map) do
                for y,_ in pairs(tmp) do
                    local hex_rating, count = 0, 0
                    for enemy_id,etm in pairs(gamedata.enemy_turn_maps) do
                        local turns = etm[x] and etm[x][y] and etm[x][y].turns

                        if turns then
                            local rating = FGUI.get_unit_defense(gamedata.unit_copies[enemy_id], x, y, gamedata.defense_maps)
                            rating = (100 - rating * 100) ^ 2 / turns
                            rating = rating / gamedata.unit_infos[enemy_id].tod_bonus^2

                            hex_rating = hex_rating + rating
                            count = count + 1. / turns
                        end
                    end

                    if (count > 0) then
                        if (not enemy_def_rating_map[x]) then enemy_def_rating_map[x] = {} end
                        enemy_def_rating_map[x][y] = { rating = hex_rating / count }
                    end
                end
            end

            --AH.put_fgumap_labels(enemy_def_rating_map, 'rating')
            --W.message{ speaker = 'narrator', message = zonedata.cfg.zone_id .. ': enemy_def_rating_map' }


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
            rating_map, defense_rating_map = {}, {}
            for x,tmp in pairs(zonedata.zone_map) do
                for y,_ in pairs(tmp) do

                    local def_rating_center = enemy_def_rating_map[x]
                        and enemy_def_rating_map[x][y]
                        and enemy_def_rating_map[x][y].rating

                    if def_rating_center then
                        local rating, count = 0, 0

                        for xa,ya in H.adjacent_tiles(x, y) do
                            if leader_distance_map[xa][ya].distance >= leader_distance_map[x][y].distance then
                                local def_rating = enemy_def_rating_map[xa]
                                    and enemy_def_rating_map[xa][ya]
                                    and enemy_def_rating_map[xa][ya].rating

                                if def_rating then
                                    rating = rating + def_rating
                                    count = count + 1
                                end
                            end
                        end

                        if (count > 0) then
                            rating = rating / count

                            rating = rating - def_rating_center

                            -- zone specific rating
                            rating = rating + grunt_rush_FLS1:zone_loc_rating(zonedata.cfg.zone_id, x, y)

                            -- Add stiff penalty if this is a location next to an unoccupied village
                            for xa, ya in H.adjacent_tiles(x, y) do
                                if gamedata.village_map[xa] and gamedata.village_map[xa][ya] then
                                    if (not gamedata.my_unit_map_noMP[xa]) or (not gamedata.my_unit_map_noMP[xa][ya]) then
                                        rating = rating - 2000
                                    end
                                end
                            end

                            if (not rating_map[x]) then rating_map[x] = {} end
                            rating_map[x][y] = { rating = rating }
                        end
                    end
                end
            end

            local show_debug = false
            if show_debug then
                AH.put_fgumap_labels(rating_map, 'rating')
                W.message { speaker = 'narrator', message = 'Hold zone ' .. zonedata.cfg.zone_id .. ': unit-independent rating map' }
            end

            -- Now we go on to the unit-dependent rating part
            local max_rating, best_hex, best_unit, best_unit_rating_map = -9e99, {}, {}

            for id,loc in pairs(holders) do
                local max_rating_unit, best_hex_unit = -9e99, {}

                local unit_rating_map = {}
                for x,tmp in pairs(gamedata.reach_maps[id]) do
                    for y,_ in pairs(tmp) do
                        local rating = rating_map[x] and rating_map[x][y] and rating_map[x][y].rating
                        if rating then
                            if (not unit_rating_map[x]) then unit_rating_map[x] = {} end
                            unit_rating_map[x][y] = { rating = rating }
                        end
                    end
                end

                for x,tmp in pairs(unit_rating_map) do
                    for y,_ in pairs(tmp) do
                        local indep_rating = unit_rating_map[x][y].rating

                        local unit_rating = 0

                        local defense = FGUI.get_unit_defense(gamedata.unit_copies[id], x, y, gamedata.defense_maps)
                        defense = 100 - defense * 100

                        if gamedata.village_map[x] and gamedata.village_map[x][y] then
                            if gamedata.unit_infos[id].regenerate then
                                defense = defense - 10
                            else
                                defense = defense - 15
                            end
                            if (defense < 10) then defense = 10 end
                        end

                        unit_rating = unit_rating - defense ^ 2

                        local adj_rating, count = 0, 0
                        for xa,ya in H.adjacent_tiles(x, y) do
                            if leader_distance_map[xa][ya].distance >= leader_distance_map[x][y].distance then

                                local defense = FGUI.get_unit_defense(gamedata.unit_copies[id], xa, ya, gamedata.defense_maps)
                                defense = 100 - defense * 100

                                local movecost = wesnoth.unit_movement_cost(gamedata.unit_copies[id], wesnoth.get_terrain(xa, ya))
                                if (movecost <= gamedata.unit_copies[id].max_moves) then
                                    adj_rating = adj_rating + defense^2
                                    count = count + 1
                                end
                            end
                        end

                        if (count > 0) then
                            unit_rating = unit_rating + adj_rating / count
                            unit_rating = unit_rating / gamedata.unit_infos[id].tod_bonus^2
                        end

                        -- Make it more important to have enemy on bad terrain than being on good terrain
                        local total_rating = indep_rating + unit_rating

                        unit_rating_map[x][y] = { rating = total_rating }

                        if (total_rating > max_rating_unit) then
                            max_rating_unit = total_rating
                            best_hex_unit = { x, y }
                        end
                    end
                end
                --print('max_rating_unit:', max_rating_unit)

                -- If we cannot get there, advance as far as possible
                -- This needs to be separate from and in addition to the step below (unthreatened hexes)
                if (max_rating_unit == -9e99) then
                    --print(cfg.zone_id, ': cannot get to zone -> move toward it', best_unit.id, best_unit.x, best_unit.y)

                    for x,tmp in pairs(gamedata.reach_maps[id]) do
                        for y,_ in pairs(tmp) do

                            local rating = -10000 + grunt_rush_FLS1:zone_advance_rating(zonedata.cfg.zone_id, x, y, gamedata)

                            if (not unit_rating_map[x]) then unit_rating_map[x] = {} end
                            unit_rating_map[x][y] = { rating = rating }

                            if (rating > max_rating_unit) then
                                max_rating_unit = rating
                                best_hex_unit = { x, y }
                            end
                        end
                    end
                end

                if (max_rating_unit > max_rating) then
                    max_rating, best_unit_rating_map = max_rating_unit, unit_rating_map
                    best_hex, best_unit = best_hex_unit, gamedata.unit_infos[id]
                end
                --print('max_rating:', max_rating, best_hex_unit[1], best_hex_unit[2])

                show_debug = false
                if show_debug then
                    AH.put_fgumap_labels(unit_rating_map, 'rating')
                    W.message { speaker = id, message = 'Hold zone: unit-specific rating map' }
                end
            end

            if (max_rating > -9e99) then
                -- If the best hex is unthreatened,
                -- check whether another mostly unthreatened hex farther
                -- advanced in the zone can be gotten to.
                -- This needs to be separate from and in addition to the step above (if unit cannot get into zone)

                -- For Northerners, to force some aggressiveness:
                local hp_factor = 1.2

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
                                local rating = grunt_rush_FLS1:zone_advance_rating(zonedata.cfg.zone_id, x, y, gamedata)

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

        function grunt_rush_FLS1:calc_counter_attack(target, gamedata, move_cache)
            -- Get counter-attack results a unit might experience next turn if it moved to 'hex'

            local target_id, target_loc = next(target)
            local target_proxy = wesnoth.get_unit(target_loc[1], target_loc[2])

            --print_time('Start calc_counter_attack on:', next(target))

            -- The target here is the AI unit.  It might not be in its original location,
            -- but it is on the map and the information passed in target is where to calculate the attack.
            -- The attackers are the enemies.  They have not been moved.


            local counter_attack = FAU.get_attack_combos(
                gamedata.enemies, target,
                nil, true, gamedata, move_cache
            )

            -- If no attacks are found, we're done; return stats of unit as is
            if (not next(counter_attack)) then
                local hp_chance = {}
                hp_chance[target_proxy.hitpoints] = 1
                hp_chance[0] = 0  -- hp_chance[0] is always assumed to be included, even when 0
                return {
                    average_hp = target_proxy.hitpoints,
                    min_hp = target_proxy.hitpoints,
                    hp_chance = hp_chance,
                    slowed = 0,
                    poisoned = 0,
                    rating = 0,
                    att_rating = 0,
                    def_rating = 0
                }
            end

            local enemy_map = {}
            for id,loc in pairs(gamedata.enemies) do
                enemy_map[loc[1] * 1000 + loc[2]] = id
            end


            local attacker_copies, dsts, attacker_infos = {}, {}, {}
            for src,dst in pairs(counter_attack) do
                table.insert(attacker_copies, gamedata.unit_copies[enemy_map[src]])
                table.insert(attacker_infos, gamedata.unit_infos[enemy_map[src]])
                table.insert(dsts, { math.floor(dst / 1000), dst % 1000 } )
            end

            local combo_att_stats, combo_def_stat, sorted_atts, sorted_dsts, rating, att_rating, def_rating =
                FAU.attack_combo_eval(
                    attacker_copies, target_proxy, dsts,
                    attacker_infos, gamedata.unit_infos[target_id],
                    gamedata, move_cache
                )

            combo_def_stat.rating = rating
            combo_def_stat.def_rating = def_rating
            combo_def_stat.att_rating = att_rating

            -- Add min_hp field
            local min_hp = 0
            for hp = 0,target_proxy.hitpoints do
                if combo_def_stat.hp_chance[hp] and (combo_def_stat.hp_chance[hp] > 0) then
                    min_hp = hp
                    break
                end
            end
            combo_def_stat.min_hp = min_hp

            --DBG.dbms(combo_def_stat)
            --print('   combo ratings:  ', rating, att_rating, def_rating)

            --print_time('  End calc_counter_attack', next(target))

            return combo_def_stat
        end

        ------ Stats at beginning of turn -----------

        -- This will be blacklisted after first execution each turn
        function grunt_rush_FLS1:stats_eval()
            return 999999
        end

        function grunt_rush_FLS1:stats_exec()
            local tod = wesnoth.get_time_of_day()
            AH.print_ts(' Beginning of Turn ' .. wesnoth.current.turn .. ' (' .. tod.name ..') stats')

            local villages = wesnoth.get_locations { terrain = '*^V*' }

            for i,s in ipairs(wesnoth.sides) do
                local total_hp = 0
                local units = AH.get_live_units { side = s.side }
                for i,u in ipairs(units) do total_hp = total_hp + u.hitpoints end
                local leader = wesnoth.get_units { side = s.side, canrecruit = 'yes' }[1]
                print('   Player ' .. s.side .. ' (' .. leader.type .. '): ' .. #units .. ' Units with total HP: ' .. total_hp)

                local owned_villages = 0
                for _,v in ipairs(villages) do
                    local owner = wesnoth.get_village_owner(v[1], v[2])
                    if (owner == s.side) then owned_villages = owned_villages + 1 end
                end
                print('     ' .. owned_villages .. '/' .. #villages .. ' villages')
            end
            if grunt_rush_FLS1:full_offensive() then print(' Full offensive mode (mostly done by RCA AI)') end
        end

        ------ Reset variables at beginning of turn -----------

        -- This will be blacklisted after first execution each turn
        function grunt_rush_FLS1:reset_vars_turn_eval()
            return 999998
        end

        function grunt_rush_FLS1:reset_vars_turn_exec()
            --print(' Resetting variables at beginning of Turn ' .. wesnoth.current.turn)

            grunt_rush_FLS1.data.turn_start_time = wesnoth.get_time_stamp() / 1000.
        end

        ------ Reset variables at beginning of each move -----------

        -- This always returns 0 -> will never be executed, but evaluated before each move
        function grunt_rush_FLS1:reset_vars_move_eval()
            --print(' Resetting gamedata tables (etc.) before move')

            grunt_rush_FLS1.data.gamedata = FGU.get_gamedata()
            grunt_rush_FLS1.data.move_cache = {}

            return 0
        end

        function grunt_rush_FLS1:reset_vars_move_exec()
        end

        ------ Clear self.data table at end of turn -----------

        -- This will be blacklisted after first execution each turn, which happens at the very end of each turn
        function grunt_rush_FLS1:clear_self_data_eval()
            return 1
        end

        function grunt_rush_FLS1:clear_self_data_exec()
            --print(' Clearing self.data table at end of Turn ' .. wesnoth.current.turn)

            -- This is mostly done so that there is no chance of corruption of savefiles
            grunt_rush_FLS1.data = {}
        end

        ------ Move leader to keep -----------

        function grunt_rush_FLS1:move_leader_to_keep_eval()
            local score = 480000
            local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'move_leader_to_keep'
            if AH.print_eval() then print_time('     - Evaluating move_leader_to_keep CA:') end

            -- Move of leader to keep is done by hand here
            -- as we want him to go preferentially to (18,4) not (19.4)

            local leader = AH.get_units_with_attacks { side = wesnoth.current.side, canrecruit = 'yes' }[1]
            if (not leader) then
                AH.done_eval_messages(start_time, ca_name)
                return 0
            end

            local keeps = { { 18, 4 }, { 19, 4 } }  -- keep hexes in order of preference

            for i,k in ipairs(keeps) do
                if (leader.x == k[1]) and (leader.y == k[2]) then
                    -- If the leader already is on a keep, don't consider lesser priority ones
                    AH.done_eval_messages(start_time, ca_name)
                    return 0
                end
            end

            -- We move the leader to the keep if
            -- 1. It's available
            -- 2. The leader can get there in one move
            for i,k in ipairs(keeps) do
                local unit_in_way = wesnoth.get_unit(k[1], k[2])
                if (not unit_in_way) then
                    local next_hop = AH.next_hop(leader, k[1], k[2])
                    if next_hop and (next_hop[1] == k[1]) and (next_hop[2] == k[2]) then
                        grunt_rush_FLS1.data.MLK_leader = leader
                        grunt_rush_FLS1.data.MLK_leader_move = { k[1], k[2] }
                        AH.done_eval_messages(start_time, ca_name)
                        return score
                    end
                end
            end

            AH.done_eval_messages(start_time, ca_name)
            return 0
        end

        function grunt_rush_FLS1:move_leader_to_keep_exec()
            if AH.print_exec() then print_time('   Executing move_leader_to_keep CA') end
            if AH.show_messages() then W.message { speaker = grunt_rush_FLS1.data.MLK_leader.id, message = 'Moving back to keep' } end
            -- This has to be a partial move !!
            AH.checked_move(ai, grunt_rush_FLS1.data.MLK_leader, grunt_rush_FLS1.data.MLK_leader_move[1], grunt_rush_FLS1.data.MLK_leader_move[2])
            grunt_rush_FLS1.data.MLK_leader, grunt_rush_FLS1.data.MLK_leader_move = nil, nil
        end

        --------- zone_control CA ------------

        function grunt_rush_FLS1:zone_action_retreat_injured(zonedata, gamedata)
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
                local action = { units = {unit}, dsts = {dest}, type = 'village', reserve = dest }
                action.action = zonedata.cfg.zone_id .. ': ' .. 'retreat severely injured units'
                return action, healloc, (enemy_threat <= allowable_retreat_threat)
            end
        end

        function grunt_rush_FLS1:zone_action_villages(zonedata, gamedata, move_cache)
            -- Otherwise we go for unowned and enemy-owned villages
            -- This needs to happen for all units, not just not-injured ones
            -- Also includes the leader, if he's on his keep
            -- The rating>100 part is to exclude threatened but already owned villages

            -- For this, we consider all villages, not just the retreat_villages,
            -- but restrict it to villages inside the zone

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
                        local target = {}
                        target[id] = { village[1], village[2] }

                        -- Actually need to put the unit in place for this
                        local old_loc = { gamedata.unit_copies[id].x, gamedata.unit_copies[id].y }
                        wesnoth.put_unit(village[1], village[2], gamedata.unit_copies[id])

                        local counter_stats = grunt_rush_FLS1:calc_counter_attack(target, gamedata, move_cache)
                        --DBG.dbms(counter_stats)

                        wesnoth.extract_unit(gamedata.unit_copies[id])
                        gamedata.unit_copies[id].x, gamedata.unit_copies[id].y = old_loc[1], old_loc[2]

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
                                local unit_advance_rating = grunt_rush_FLS1:zone_advance_rating(
                                    zonedata.cfg.zone_id, unit_loc[1], unit_loc[2], gamedata
                                )
                                local village_advance_rating = grunt_rush_FLS1:zone_advance_rating(
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

        function grunt_rush_FLS1:zone_action_attack(zonedata, gamedata, move_cache)
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

                -- How much more valuable do we consider the enemy units than out own
                local enemy_worth = 1.2 -- We are Northerners, after all
                if zonedata.cfg.attack and zonedata.cfg.attack.enemy_worth then
                    enemy_worth = zonedata.cfg.attack.enemy_worth
                end
                if gamedata.unit_infos[target_id].canrecruit then enemy_worth = enemy_worth * 3 end
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

                    -- Ratio of damage taken / done
                    local damage_ratio = combo_att_rating / combo_def_rating
                    --print('     damage done, taken, taken/done:', combo_def_rating, combo_att_rating, ' --->', damage_ratio)

                    if (damage_ratio > enemy_worth ) then
                        do_attack = false
                    end

                    -- Don't do this attack if the leader has a chance to get killed, poisoned or slowed
                    if do_attack then
                        for k,att_stat in ipairs(combo_att_stats) do
                            if (sorted_atts[k].canrecruit) then
                                if (att_stat.hp_chance[0] > 0.0) or (att_stat.slowed > 0.0) or (att_stat.poisoned > 0.0) then
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
                                        if adj_occ_hex_map[opp_hex[1]] and adj_occ_hex_map[opp_hex[1]][opp_hex[2]] then
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
                            att_rating = combo_att_rating,
                            def_rating = combo_def_rating,
                            enemy_worth = enemy_worth
                        })
                    end
                end
            end

            table.sort(combo_ratings, function(a, b) return a.rating > b.rating end)
            --DBG.dbms(combo_ratings)

            -- Now check whether counter attacks are acceptable
            for _,combo in ipairs(combo_ratings) do
                --print_time('Checking counter attack for attack on', target_id, enemy_worth)

                -- We first need to move all units into place, as the counter attack threat
                -- should be calculated for that formation as a whole
                -- All units with MP left have already been extracted, so we only need to
                -- put the attackers into the right position and don't have to worry about any other unit
                for i_a,attacker in pairs(combo.attackers) do
                    if gamedata.my_units_MP[attacker.id] then
                        --print('  has been extracted')
                        wesnoth.put_unit(combo.dsts[i_a][1], combo.dsts[i_a][2], gamedata.unit_copies[attacker.id])
                    end
                end

                local acceptable_counter = true

                for i_a,attacker in ipairs(combo.attackers) do
                    --print_time('  by', attacker.id, combo.dsts[i_a][1], combo.dsts[i_a][2])
                    -- Add max damages from this turn and counter-attack
                    local min_hp = 0
                    for hp = 0,attacker.hitpoints do
                        if combo.att_stats[i_a].hp_chance[hp] and (combo.att_stats[i_a].hp_chance[hp] > 0) then
                            min_hp = hp
                            break
                        end
                    end

                    local max_damage = attacker.hitpoints - min_hp
                    --print('max_damage, attacker.hitpoints, min_hp', max_damage, attacker.hitpoints, min_hp)

                    -- Now calculate the counter attack outcome
                    local x, y = combo.dsts[i_a][1], combo.dsts[i_a][2]

                    local attacker_moved = {}
                    attacker_moved[attacker.id] = { combo.dsts[i_a][1], combo.dsts[i_a][2] }

                    local counter_stats = grunt_rush_FLS1:calc_counter_attack(
                        attacker_moved, gamedata, move_cache
                    )

                    local counter_rating = counter_stats.rating
                    local counter_att_rating = counter_stats.att_rating
                    local counter_def_rating = counter_stats.def_rating
                    --print('   counter ratings:', counter_rating, counter_att_rating, counter_def_rating)

                    local damage_done = combo.def_rating + counter_att_rating
                    local damage_taken = combo.att_rating + counter_def_rating
                    local damage_ratio = damage_taken / damage_done
                    --print('     damage done, taken, taken/done:', damage_done, damage_taken, ' --->', damage_ratio)

                    local counter_min_hp = counter_stats.min_hp

                    -- If there's a chance of the leader getting poisoned, slowed or killed, don't do it
                    if attacker.canrecruit then
                        --print('Leader: slowed, poisoned %', counter_stats.slowed, counter_stats.poisoned)
                        if (counter_stats.slowed > 0.0) or (counter_stats.poisoned > 0.0) then
                            --print('Leader slowed or poisoned', counter_stats.slowed, counter_stats.poisoned)
                            acceptable_counter = false
                            break
                        end

                        -- Add damage from attack and counter attack
                        local min_outcome = counter_min_hp - max_damage
                        --print('Leader: min_outcome, counter_min_hp, max_damage', min_outcome, counter_min_hp, max_damage)

                        if (min_outcome <= 0) then
                            acceptable_counter = false
                            break
                        end
                    -- Or for normal units, use the somewhat looser criteria
                    else  -- Or for normal units, use the somewhat looser criteria
                        --print('Non-leader damage_ratio, enemy_worth', damage_ratio, combo.enemy_worth)
                        if (damage_ratio > combo.enemy_worth ) then
                            acceptable_counter = false
                            break
                        end
                    end
                end

                -- Now put the units back out there
                -- We first need to extract the attacker units again, then
                -- put both units in way and attackers back out there

                for i_a,attacker in ipairs(combo.attackers) do
                    --print(attacker.id)

                    if gamedata.my_units_MP[attacker.id] then
                        wesnoth.extract_unit(gamedata.unit_copies[attacker.id])
                    end
                end

                --print_time('acceptable_counter', acceptable_counter)
                if acceptable_counter then
                    -- Only execute the first of these attacks
                    local action = { units = {}, dsts = {}, enemy = combo.target }
                    action.units, action.dsts = combo.attackers, combo.dsts
                    action.action = zonedata.cfg.zone_id .. ': ' .. 'attack'
                    return action
                end
            end

            return nil  -- Unnecessary, just to point out what's going on if no acceptable attack was found
        end

        function grunt_rush_FLS1:zone_action_hold(zonedata, gamedata, cfg)
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

            local zone_enemies = {}
            local num_enemies, hp_enemies = 0, 0
            if zonedata.cfg.hold and zonedata.cfg.hold.x and zonedata.cfg.hold.y then
                for enemy_id,enemy_loc in pairs(gamedata.enemies) do

                    -- Cannot use gamedata.enemy_turn_maps here, as we need movecost ignoring enemies
                    -- Since this is only to individual hexes, we do the path finding here
                    local old_moves = gamedata.unit_copies[enemy_id].moves
                    gamedata.unit_copies[enemy_id].moves = gamedata.unit_copies[enemy_id].max_moves
                    local path, cost = wesnoth.find_path(
                        gamedata.unit_copies[enemy_id],
                        zonedata.cfg.hold.x, zonedata.cfg.hold.y,
                        { ignore_units = true }
                    )
                    gamedata.unit_copies[enemy_id].moves = old_moves
                    --print(zonedata.cfg.zone_id, enemy_id, zonedata.cfg.hold.x, zonedata.cfg.hold.y, cost)

                    if (cost <= gamedata.unit_copies[enemy_id].max_moves * 2) then
                        zone_enemies[enemy_id] = enemy_loc

                        local turns = math.ceil(cost / gamedata.unit_copies[enemy_id].max_moves)
                        if (turns == 0) then turns = 1 end
                        local weight = 1. / turns
                        --print('   ', zonedata.cfg.zone_id, 'inserting enemy (id, weight):', enemy_id, weight)

                        num_enemies = num_enemies + weight
                        hp_enemies = hp_enemies + gamedata.unit_infos[enemy_id].hitpoints * weight
                    end
                end
            end

            -- Only check for possible position holding if hold.hp_ratio and hold.unit_ratio are met
            -- If hold.hp_ratio and hold.unit_ratio are not provided, holding is done by default
            local eval_hold = true

            if zonedata.cfg.hold.hp_ratio then
                --print('Checking for HP ratio', zonedata.cfg.zone_id, zonedata.cfg.hold.hp_ratio)

                local hp_units_noMP = 0
                for id,loc in pairs(zonedata.zone_units_noMP) do
                    hp_units_noMP = hp_units_noMP + gamedata.unit_infos[id].hitpoints
                end

                local hp_ratio = 1000
                if (hp_enemies > 0) then
                    hp_ratio = hp_units_noMP / hp_enemies
                end
                --print('  hp_ratio', hp_ratio)

                if (hp_ratio >= zonedata.cfg.hold.hp_ratio) then
                    eval_hold = false
                end
            end
            --print('eval_hold 1', eval_hold)

            if eval_hold and zonedata.cfg.hold.unit_ratio then
                --print('Checking for unit ratio', zonedata.cfg.zone_id, zonedata.cfg.hold.unit_ratio)

                local num_units_noMP = 0
                for id,loc in pairs(zonedata.zone_units_noMP) do
                    num_units_noMP = num_units_noMP + 1
                end

                local unit_ratio = 1000
                if (num_enemies > 0) then
                    unit_ratio = num_units_noMP / num_enemies
                end
                --print('  unit_ratio', unit_ratio)

                if (unit_ratio >= zonedata.cfg.hold.unit_ratio) then
                    eval_hold = false
                end
            end
            --print('eval_hold 2', eval_hold)

            -- Not sure if this is still needed, but leave the code here for now
            -- If there are unoccupied or enemy-occupied villages in the hold zone, send units there,
            -- if we do not have enough units that have moved already in the zone
            --local units_per_village = 0.5
            --if cfg.villages and cfg.villages.units_per_village then
            --    units_per_village = cfg.villages.units_per_village
            --end
            --if (not eval_hold) then
            --    if (#units_noMP < #cfg.retreat_villages * units_per_village) then
            --        for i,v in ipairs(cfg.retreat_villages) do
            --            local owner = wesnoth.get_village_owner(v[1], v[2])
            --            if (not owner) or wesnoth.is_enemy(owner, wesnoth.current.side) then
            --                eval_hold, get_villages = true, true
            --            end
            --        end
            --    end
            --    --print('#units_noMP, #cfg.retreat_villages', #units_noMP, #cfg.retreat_villages)
            --end
            --print('eval_hold 2', eval_hold)

            if eval_hold then
                local unit, dst = grunt_rush_FLS1:hold_zone(holders, zonedata, gamedata)

                local action
                if unit then
                    action = { units = { unit }, dsts = { dst } }
                    action.action = zonedata.cfg.zone_id .. ': ' .. 'hold position'
                end
                return action
            end

            -- I don't think this part is useful any more - but keep the code until I'm sure
            -- If we got here, check whether there are instructions to secure the zone
            -- That is, whether units are not in the zone, but are threatening a key location in it
            -- The parameters for this are set in cfg.secure
            --if cfg.secure then
            --    -- Count units that are already in the zone (no MP left) that
            --    -- are not the side leader
            --    local number_units_noMP_noleader = 0
            --    for i,u in pairs(units_noMP) do
            --        if (not u.canrecruit) then number_units_noMP_noleader = number_units_noMP_noleader + 1 end
            --    end
            --    --print('Units already in zone:', number_units_noMP_noleader)

            --    -- If there are not enough units, move others there
            --    if (number_units_noMP_noleader < cfg.secure.min_units) then
            --        -- Check whether (cfg.secure.x,cfg.secure.y) is threatened
            --        local enemy_threats = false
            --        for i,e in ipairs(enemies) do
            --            local path, cost = wesnoth.find_path(e, cfg.secure.x, cfg.secure.y)
            --            if (cost <= e.max_moves * cfg.secure.moves_away) then
            --               enemy_threats = true
            --               break
            --            end
            --        end
            --        --print(cfg.zone_id, 'need to secure ' .. cfg.secure.x .. ',' .. cfg.secure.y, enemy_threats)

            --        -- If we need to secure the zone
            --        if enemy_threats then
            --            -- The best unit is simply the one that can get there first
            --            -- If several can make it in the same number of moves, use the one with the most HP
            --            local max_rating, best_unit = -9e99, {}
            --            for i,u in ipairs(holders) do
            --                local path, cost = wesnoth.find_path(u, cfg.secure.x, cfg.secure.y)
            --                local rating = - math.ceil(cost / u.max_moves)

            --                rating = rating + u.hitpoints / 100.

            --                if (rating > max_rating) then
            --                    max_rating, best_unit = rating, u
            --                end
            --            end

            --            -- Find move for the unit found above
            --            if (max_rating > -9e99) then
            --                local dst = AH.next_hop(best_unit, cfg.secure.x, cfg.secure.y)
            --                if dst then
            --                    local action = { units = { best_unit }, dsts = { dst } }
            --                    action.action = cfg.zone_id .. ': ' .. 'secure zone'
            --                    return action
            --                end
            --            end
            --        end
            --    end
            --end
        end

        function grunt_rush_FLS1:high_priority_attack(unit_info, zonedata, gamedata, move_cache)
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

        function grunt_rush_FLS1:get_zone_action(cfg, gamedata, move_cache)
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
                    retreat_action, healloc, safeloc = grunt_rush_FLS1:zone_action_retreat_injured(zonedata, gamedata)
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
                    village_action = grunt_rush_FLS1:zone_action_villages(zonedata, gamedata, move_cache)
                    if village_action and (village_action.rating > 100) then
                        --print_time(village_action.action)
                        local attack_action = grunt_rush_FLS1:high_priority_attack(village_action.units[1], zonedata, gamedata, move_cache)
                        return attack_action or village_action
                    end
                end
            end

            -- **** Attack evaluation ****
            --print_time('  ' .. cfg.zone_id .. ': attack eval')
            if (not cfg.do_action) or cfg.do_action.attack then
                if (not cfg.skip_action) or (not cfg.skip_action.attack) then
                    local action = grunt_rush_FLS1:zone_action_attack(zonedata, gamedata, move_cache)
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
                    local action = grunt_rush_FLS1:zone_action_hold(zonedata, gamedata, move_cache)
                    if action then
                        --print_time(action.action)
                        return action
                    end
                end
            end

            -- **** Grab threatened villages ****
            if village_action then
                if (not cfg.do_action) or cfg.do_action.hold_threatened then
                    if (not cfg.skip_action) or (not cfg.skip_action.hold_threatened) then
                        village_action.action = village_action.action .. ' (threatened village)'
                        --print(village_action.action)
                        return village_action
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

        function grunt_rush_FLS1:zone_control_eval()
            local score_zone_control = 350000
            local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'zone_control'
            if AH.print_eval() then print_time('     - Evaluating zone_control CA:') end

            -- Skip this if AI is much stronger than enemy
            if grunt_rush_FLS1:full_offensive() then
                AH.done_eval_messages(start_time, ca_name)
                return 0
            end

            local cfgs = grunt_rush_FLS1:get_zone_cfgs(grunt_rush_FLS1.data.gamedata)
            for i_c,cfg in ipairs(cfgs) do
                --print_time('zone_control: ', cfg.zone_id)

                -- Extract all AI units with MP left (for enemy path finding, counter attack placement etc.)
                local extracted_units = {}
                for id,loc in pairs(grunt_rush_FLS1.data.gamedata.my_units_MP) do
                    local unit_proxy = wesnoth.get_unit(loc[1], loc[2])
                    wesnoth.extract_unit(unit_proxy)
                    table.insert(extracted_units, unit_proxy)  -- Not a proxy unit any more at this point
                end

                local zone_action = grunt_rush_FLS1:get_zone_action(cfg, grunt_rush_FLS1.data.gamedata, grunt_rush_FLS1.data.move_cache)

                for _,extracted_unit in ipairs(extracted_units) do wesnoth.put_unit(extracted_unit) end

                if zone_action then
                    grunt_rush_FLS1.data.zone_action = zone_action
                    AH.done_eval_messages(start_time, ca_name)
                    return score_zone_control
                end
            end

            AH.done_eval_messages(start_time, ca_name)
            return 0
        end

        function grunt_rush_FLS1:zone_control_exec()
            local action = grunt_rush_FLS1.data.zone_action.action

            for i,unit in ipairs(grunt_rush_FLS1.data.zone_action.units) do
                local unit_proxy = wesnoth.get_units { id = unit.id }[1]
                grunt_rush_FLS1.data.zone_action.units[i] = unit_proxy
            end

            if grunt_rush_FLS1.data.zone_action.enemy then
                local enemy_proxy = wesnoth.get_units { id = next(grunt_rush_FLS1.data.zone_action.enemy) }[1]
                grunt_rush_FLS1.data.zone_action.enemy = enemy_proxy
            end

            while grunt_rush_FLS1.data.zone_action.units and (table.maxn(grunt_rush_FLS1.data.zone_action.units) > 0) do
                local next_unit_ind = 1

                -- If this is an attack combo, reorder units to give maximum XP to unit closest to advancing
                if grunt_rush_FLS1.data.zone_action.enemy and grunt_rush_FLS1.data.zone_action.units[2] then
                    -- Only do this if CTK for overall attack combo is > 0
                    -- Cannot use move_cache here !!!  (because HP change)
                    local _, combo_def_stat = BC.attack_combo_eval(
                        grunt_rush_FLS1.data.zone_action.units,
                        grunt_rush_FLS1.data.zone_action.dsts,
                        grunt_rush_FLS1.data.zone_action.enemy,
                        grunt_rush_FLS1.data.cache
                    )

                    if (combo_def_stat.hp_chance[0] > 0) then
                        --print_time('Reordering units for attack to maximize XP gain')

                        local min_XP_diff, best_ind = 9e99
                        for ind,unit in ipairs(grunt_rush_FLS1.data.zone_action.units) do
                            local XP_diff = unit.max_experience - unit.experience
                            -- Add HP as minor rating
                            XP_diff = XP_diff + unit.hitpoints / 100.

                            if (XP_diff < min_XP_diff) then
                                min_XP_diff, best_ind = XP_diff, ind
                            end
                        end

                        local unit = grunt_rush_FLS1.data.zone_action.units[best_ind]
                        --print_time('Most advanced unit:', unit.id, unit.experience, best_ind)

                        local att_stat, def_stat = BC.battle_outcome(
                            unit,
                            grunt_rush_FLS1.data.zone_action.enemy,
                            grunt_rush_FLS1.data.zone_action.dsts[best_ind],
                            {},
                            grunt_rush_FLS1.data.cache
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

                local unit = grunt_rush_FLS1.data.zone_action.units[next_unit_ind]
                local dst = grunt_rush_FLS1.data.zone_action.dsts[next_unit_ind]

                -- If this is the leader, recruit first
                -- We're doing that by running a mini CA eval/exec loop
                if unit.canrecruit then
                    --print('-------------------->  This is the leader. Recruit first.')
                    local avoid_map = LS.create()
                    for _,loc in ipairs(grunt_rush_FLS1.data.zone_action.dsts) do
                        avoid_map:insert(dst[1], dst[2])
                    end

                    if AH.show_messages() then W.message { speaker = unit.id, message = 'The leader is about to move. Need to recruit first.' } end

                    local have_recruited
                    while grunt_rush_FLS1:recruit_rushers_eval() > 0 do
                        if not grunt_rush_FLS1:recruit_rushers_exec(nil, avoid_map) then
                            break
                        else
                            have_recruited = true
                        end
                    end

                    -- Then we stop the outside loop to reevaluate
                    if have_recruited then break end
                end

                if AH.print_exec() then print_time('   Executing zone_control CA ' .. action) end
                if AH.show_messages() then W.message { speaker = unit.id, message = 'Zone action ' .. action } end

                -- It's possible that one of the units got moved out of the way
                -- by a move of a previous unit and that it cannot reach the dst
                -- hex any more.  In that case we stop and reevaluate.
                -- TODO: make sure up front that move combination is possible
                local _,cost = wesnoth.find_path(unit, dst[1], dst[2])
                if (cost > unit.moves) then
                    grunt_rush_FLS1.data.zone_action = nil
                    return
                end

                -- Move out of way in direction of own leader
                local leader_proxy = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]
                local dx, dy  = leader_proxy.x - dst[1], leader_proxy.y - dst[2]
                local r = math.sqrt(dx * dx + dy * dy)
                if (r ~= 0) then dx, dy = dx / r, dy / r end

                AH.movefull_outofway_stopunit(ai, unit, dst[1], dst[2], { dx = dx, dy = dy })

                -- Also set parameters that need to last for the turn
                -- If this is a retreat toward village, add it to the "reserved villages" list
                if grunt_rush_FLS1.data.zone_action.type and (grunt_rush_FLS1.data.zone_action.type == 'village') then
                    if (not grunt_rush_FLS1.data.reserved_villages) then
                        grunt_rush_FLS1.data.reserved_villages = {}
                    end
                    local v_ind = grunt_rush_FLS1.data.zone_action.reserve[1] * 1000 + grunt_rush_FLS1.data.zone_action.reserve[2]
                    --print('Putting village on reserved_villages list', v_ind)
                    grunt_rush_FLS1.data.reserved_villages[v_ind] = true
                end

                -- Remove these from the table
                table.remove(grunt_rush_FLS1.data.zone_action.units, next_unit_ind)
                table.remove(grunt_rush_FLS1.data.zone_action.dsts, next_unit_ind)

                -- Then do the attack, if there is one to do
                if grunt_rush_FLS1.data.zone_action.enemy then
                    AH.checked_attack(ai, unit, grunt_rush_FLS1.data.zone_action.enemy)

                    -- If enemy got killed, we need to stop here
                    if (not grunt_rush_FLS1.data.zone_action.enemy.valid) then
                        grunt_rush_FLS1.data.zone_action.units = nil
                    end
                end
            end

            grunt_rush_FLS1.data.zone_action = nil
        end

        function grunt_rush_FLS1:finish_turn_eval()
            local score_finish_turn = 170000
            local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'finish_turn'
            if AH.print_eval() then print_time('     - Evaluating finish_turn CA:') end

            -- Skip this if AI is much stronger than enemy
            if grunt_rush_FLS1:full_offensive() then
                AH.done_eval_messages(start_time, ca_name)
                return 0
            end

            local move_cache = {}

            -- Retreat any injured units to villages, if possible
            local unit_proxies_MP = AH.get_units_with_moves { side = wesnoth.current.side }

            local injured_units = {}
            for _,unit in ipairs(unit_proxies_MP) do
                if (unit.hitpoints < unit.max_hitpoints) or unit.status.poisoned then
                    table.insert(injured_units, unit)
                end
            end

            local max_rating, best_unit, best_hex = -9e99
            for _,unit in ipairs(injured_units) do
                local reach = wesnoth.find_reach(unit)

                for i,r in ipairs(reach) do
                    local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(r[1], r[2])).village

                    if is_village then
                        local unit_in_way = wesnoth.get_unit(r[1], r[2])

                        if (unit_in_way == unit) then unit_in_way = nil end

                        if unit_in_way and (unit_in_way.moves > 0) then
                            local reach_map = AH.get_reachable_unocc(unit_in_way)
                            if (reach_map:size() > 1) then unit_in_way = nil end
                        end

                        if (not unit_in_way) then
                            local max_hp_chance_zero = 0.5
                            local counter_stats = grunt_rush_FLS1:calc_counter_attack(unit, { r[1], r[2] },
                                { stop_eval_hp_chance_zero = max_hp_chance_zero },
                                move_cache
                            )

                            if (not counter_stats.hp_chance)
                                or (unit.canrecruit and (counter_stats.hp_chance[0] == 0))
                                or ((not unit.canrecruit) and (counter_stats.hp_chance[0] <= max_hp_chance_zero))
                            then
                                -- Most injured unit first
                                local rating = unit.max_hitpoints - unit.hitpoints

                                if unit.status.poisoned then
                                    rating = rating + 12  -- yes, intentionally more than 8
                                end

                                -- Chance to die is bad
                                if counter_stats.hp_chance then
                                    rating = rating - counter_stats.hp_chance[0] * 100
                                end

                                -- Retreat leader first, unless other unit is much more injured
                                if unit.canrecruit then
                                    rating = rating + 12
                                end

                                if (rating > max_rating) then
                                    max_rating = rating
                                    best_unit, best_hex = unit, { r[1], r[2] }
                                end
                            end
                        end
                    end
                end
            end

            if best_unit then
                grunt_rush_FLS1.data.finish_unit = best_unit
                grunt_rush_FLS1.data.finish_hex = best_hex

                return score_finish_turn
            end

            -- Otherwise, if any units have attacks or moves left, take them away
            if unit_proxies_MP[1] then return score_finish_turn end

            local unit_proxies_attacks = AH.get_units_with_attacks { side = wesnoth.current.side }
            if unit_proxies_attacks[1] then return score_finish_turn end

            return 0
        end

        function grunt_rush_FLS1:finish_turn_exec()
            if AH.print_exec() then print_time('   Executing finish_turn CA') end

            if grunt_rush_FLS1.data.finish_unit then
                AH.movefull_outofway_stopunit(ai, grunt_rush_FLS1.data.finish_unit, grunt_rush_FLS1.data.finish_hex)

                grunt_rush_FLS1.data.finish_unit = nil
                grunt_rush_FLS1.data.finish_hex = nil

                return
            end

            local unit_proxies_attacks = AH.get_units_with_attacks { side = wesnoth.current.side }
            for i,u in ipairs(unit_proxies_attacks) do
                AH.checked_stopunit_all(ai, u)
                --print('Attacks left:', u.id)
            end

            local unit_proxies_MP = AH.get_units_with_moves { side = wesnoth.current.side }
            for i,u in ipairs(unit_proxies_MP) do
                --print('Moves left:', u.id)
                AH.checked_stopunit_all(ai, u)
            end
        end

        return grunt_rush_FLS1
    end
}
