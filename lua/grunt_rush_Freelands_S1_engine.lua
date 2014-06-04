return {
    init = function(ai)

        local grunt_rush_FLS1 = {}

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        local BC = wesnoth.require "~/add-ons/AI-demos/lua/battle_calcs.lua"
        local FGU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_gamestate_utils.lua"
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

        function grunt_rush_FLS1:zone_advance_rating(zone_id, x, y, enemy_leader)
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

            if (zone_id == 'enemy_leader') then
                rating = - H.distance_between(x, y, enemy_leader.x, enemy_leader.y)
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

        function grunt_rush_FLS1:get_zone_cfgs(recalc)
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

            -- The 'cfgs' table is stored in 'grunt_rush_FLS1.data.zone_cfgs' and retrieved from there if it already exists
            -- This is automatically deleted at the beginning of each turn, so a recalculation is forced then

            -- Optional parameter:
            -- recalc: if set to 'true', force recalculation of cfgs even if 'grunt_rush_FLS1.data.zone_cfgs' exists

            -- Comment out for now, maybe reinstate later
            --if (not recalc) and grunt_rush_FLS1.data.zone_cfgs then
            --    return grunt_rush_FLS1.data.zone_cfgs
            --end

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
                hold = { x = 18, y = 9, dx = 0, dy = 1, hp_ratio = 1.0 },
                retreat_villages = { { 18, 9 }, { 24, 7 }, { 22, 2 } },
                villages = { units_per_village = 0 }
            }

            local cfg_rush_center = {
                zone_id = 'rush_center',
                zone_filter = { x = '15-24', y = '1-16' },
                unit_filter = { x = '16-25,15-22', y = '1-13,14-19' },
                skip_action = { retreat_injured_unsafe = true },
                hold = { x = 18, y = 9, dx = 0, dy = 1 },
                retreat_villages = { { 18, 9 }, { 24, 7 }, { 22, 2 } },
            }

            local cfg_left = {
                zone_id = 'left',
                key_hexes = { { 11, 9 } },
                zone_filter = { x = '4-14', y = '1-15' },
                unit_filter = { x = '1-15,16-20', y = '1-15,1-6' },
                skip_action = { retreat_injured_unsafe = true },
                hold = { x = 11, y = 9, dx = 0, dy = 1, hp_ratio = 1.0, unit_ratio = 1.1 },
                secure = { x = 11, y = 9, moves_away = 1, min_units = 1.1 },
                retreat_villages = { { 11, 9 }, { 8, 5 }, { 12, 5 }, { 12, 2 } },
                villages = { hold_threatened = true }
            }

            local cfg_rush_left = {
                zone_id = 'rush_left',
                zone_filter = { x = '4-14', y = '1-15' },
                unit_filter = { x = '1-15,16-20', y = '1-15,1-6' },
                skip_action = { retreat_injured_unsafe = true },
                hold = { x = 11, y = 9, dx = 0, dy = 1 },
                retreat_villages = { { 11, 9 }, { 8, 5 }, { 12, 5 }, { 12, 2 } },
            }

            local cfg_right = {
                zone_id = 'right',
                key_hexes = { { 27, 11 } },
                zone_filter = { x = '24-34', y = '1-17' },
                unit_filter = { x = '16-99,22-99', y = '1-11,12-25' },
                skip_action = { retreat_injured_unsafe = true },
                hold = { x = 27, y = 11, dx = 0, dy = 1, hp_ratio = 1.0, unit_ratio = 1.1 },
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
                hold = { x = 27, y = 11, dx = 0, dy = 1 },
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

            -- Now find how many enemies can get to each zone
            local my_units = AH.get_live_units { side = wesnoth.current.side }
            local leader = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' } [1]
            local enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }
            local attack_map = BC.get_attack_map(my_units)
            local attack_map_hp = BC.get_attack_map(my_units, { return_value = 'hitpoints' })
            local enemy_attack_map = BC.get_attack_map(enemies, { moves = "max" })
            local enemy_attack_map_hp = BC.get_attack_map(enemies, { moves = "max", return_value = 'hitpoints' })

            for _,cfg in ipairs(sorted_cfgs) do
                --print('Checking priority of zone: ', cfg.zone_id)

                local moves_away = 0
                for _,enemy in ipairs(enemies) do
                    local min_cost = 9e99
                    for _,hex in ipairs(cfg.key_hexes) do
                        local _,cost = wesnoth.find_path(enemy, hex[1], hex[2], { moves = 'max' })
                        cost = math.ceil(cost / enemy.max_moves)

                        if (cost < min_cost) then min_cost = cost end
                    end

                    if (min_cost < 1) then min_cost = 1 end
                    --print('      ', enemy.id, enemy.x, enemy.y, min_cost)

                    if (min_cost <= 2) then
                        moves_away = moves_away + enemy.hitpoints / min_cost
                    end
                end
                --print('    moves away:', moves_away)

                -- Any unit that can attack this hex directly counts extra
                local direct_attack = 0
                for _,hex in ipairs(cfg.key_hexes) do
                    local hp = enemy_attack_map_hp.hitpoints:get(hex[1], hex[2]) or 0
                    if (hp > direct_attack) then direct_attack = hp end
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

            -- Now set this up as global variable
            grunt_rush_FLS1.data.zone_cfgs = cfgs

            return grunt_rush_FLS1.data.zone_cfgs
        end

        function grunt_rush_FLS1:hp_ratio(my_units, enemies, weights)
            -- Hitpoint ratio of own units / enemy units
            -- If arguments are not given, use all units on the side
            if (not my_units) then
                my_units = AH.get_live_units { side = wesnoth.current.side }
            end
            if (not enemies) then
                enemies = AH.get_live_units {
                    { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
                }
            end

            local my_hp, enemy_hp = 0, 0
            for i,u in ipairs(my_units) do my_hp = my_hp + u.hitpoints end
            for i,u in ipairs(enemies) do
                local hp = u.hitpoints
                if weights then hp = hp * weights[i] end
                enemy_hp = enemy_hp + hp
            end

            --print('HP ratio:', my_hp / (enemy_hp + 1e-6)) -- to avoid div by 0
            return my_hp / (enemy_hp + 1e-6), my_hp, enemy_hp
        end

        function grunt_rush_FLS1:full_offensive()
            -- Returns true if the conditions to go on all-out offensive are met
            if (grunt_rush_FLS1:hp_ratio() > 2.0) and (wesnoth.current.turn >= 5) then return true end
            return false
        end

        function grunt_rush_FLS1:hold_zone(holders, enemy_defense_map, cfg)

            -- Find all enemies, the enemy leader, and the enemy attack map
            local enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", { side = wesnoth.current.side } }} }
            }
            --print(cfg.zone_id, '#enemies', #enemies)

            -- ***** This code is still a mess, WIP. Will be cleaned up eventually *****

            local enemy_leader
            local enemy_attack_maps = {}
            local enemy_attack_map = LS.create()
            for i,e in ipairs(enemies) do
                if e.canrecruit then enemy_leader = e end

                local attack_map = BC.get_attack_map_unit(e)
                table.insert(enemy_attack_maps, attack_map)
                enemy_attack_map:union_merge(attack_map.hitpoints, function(x, y, v1, v2) return (v1 or 0) + v2 end)
            end

            -- Now move units into holding positions
            local all_units = wesnoth.get_units { side = wesnoth.current.side }
            local units_MP, units_noMP = {}, {}
            for i,u in ipairs(all_units) do
                local unit_can_move_away = false
                if (u.moves > 0) then
                    local reach_map = AH.get_reachable_unocc(u)
                    if (reach_map:size() > 1) then unit_can_move_away = true end
                end
                if unit_can_move_away then
                    table.insert(units_MP, u)
                else
                    table.insert(units_noMP, u)
                end
            end

            local zone = wesnoth.get_locations(cfg.zone_filter)
            local leader = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]

            -- Take leader and units with MP off the map
            -- Leader needs to be taken off whether he has MP or not, so done spearately
            for i,u in ipairs(units_MP) do
                if (not u.canrecruit) then wesnoth.extract_unit(u) end
            end
            wesnoth.extract_unit(leader)

            local enemy_cost_maps, enemy_turn_maps, enemy_defense_maps = {}, {}, {}
            local enemy_alignments = {}
            for i,e in ipairs(enemies) do
                local cost_map, turn_map, def_map = LS.create(), LS.create(), LS.create()

                local moves = e.moves
                e.moves = e.max_moves
                local reach = wesnoth.find_reach(e, { additional_turns = 1 })
                e.moves = moves
                for _,r in ipairs(reach) do
                    cost_map:insert(r[1], r[2], e.max_moves * 2 - r[3])
                end

                cost_map:iter(function(x, y, v)
                    --local turns = math.ceil(v / e.max_moves)
                    local turns = v / e.max_moves
                    if (turns == 0) then turns = 1 end
                    turn_map:insert(x, y, turns)

                    def_map:insert(x, y, wesnoth.unit_defense(e, wesnoth.get_terrain(x, y)))
                end)

                --AH.put_labels(cost_map)
                --W.message{ speaker = e.id, message = cfg.zone_id .. ': enemy_cost_map' }
                --AH.put_labels(turn_map)
                --W.message{ speaker = e.id, message = cfg.zone_id .. ': enemy_turn_map' }
                --AH.put_labels(def_map)
                --W.message{ speaker = e.id, message = cfg.zone_id .. ': enemy_defense_map' }

                table.insert(enemy_cost_maps, cost_map)
                table.insert(enemy_turn_maps, turn_map)
                table.insert(enemy_defense_maps, def_map)

                table.insert(enemy_alignments, e.__cfg.alignment)
            end

            -- Create enemy defense rating map
            local enemy_def_rating_map = LS.create()
            local weighting_map = LS.create()

            for i_h,hex in ipairs(zone) do
                local x, y = hex[1], hex[2]

                local hex_rating, count = 0, 0

                for i_d,etm in ipairs(enemy_turn_maps) do
                    local turns = etm:get(x,y)
                    if turns then
                        local rating = enemy_defense_maps[i_d]:get(x,y)^2 / turns

                        -- Apply factor for ToD
                        local lawful_bonus = wesnoth.get_time_of_day({ x, y, true }).lawful_bonus
                        local tod_penalty = AH.get_unit_time_of_day_bonus(enemy_alignments[i_d], lawful_bonus)
                        --print(x,y,lawful_bonus, tod_penalty)

                        rating = rating / tod_penalty^2

                        hex_rating = hex_rating + rating
                        count = count + 1. / turns
                    end
                end

                if (count > 0) then
                    hex_rating = hex_rating / count
                    enemy_def_rating_map:insert(x, y, hex_rating)
                end

            end

            --AH.put_labels(enemy_def_rating_map)
            --W.message{ speaker = 'narrator', message = cfg.zone_id .. ': enemy_def_rating_map' }

            -- This isn't 100% right, but close enough
            local unit_count = LS.create()
            for i,e in ipairs(enemies) do
                local e_copy = wesnoth.copy_unit(e)

                local total_MP = 100
                e_copy.moves = total_MP

                local reach_enemy = wesnoth.find_reach(e_copy, { ignore_units = false } )
                local reach_enemy_map = LS.create()
                for i,r in ipairs(reach_enemy) do
                    reach_enemy_map:insert(r[1], r[2], total_MP - r[3])
                end

                --AH.put_labels(reach_enemy_map)
                --W.message{ speaker = 'narrator', message = cfg.zone_id .. ': reach_enemy_map' }

                e_copy.x, e_copy.y = leader.x, leader.y

                local reach = wesnoth.find_reach(e_copy, { ignore_units = true } )

                local path, cost = wesnoth.find_path(e, leader.x, leader.y, { ignore_units = false } )

                local reach_leader = wesnoth.find_reach(e_copy, { ignore_units = false } )
                local reach_leader_map = LS.create()
                for i,r in ipairs(reach) do
                    reach_leader_map:insert(r[1], r[2], total_MP - r[3])
                end

                --AH.put_labels(reach_leader_map)
                --W.message{ speaker = 'narrator', message = cfg.zone_id .. ': reach_leader_map' }

            end

            -- Put units back on the map
            wesnoth.put_unit(leader)
            for i,u in ipairs(units_MP) do
                if (not u.canrecruit) then wesnoth.put_unit(u) end
            end

            local leader_distance_map = LS.create()

            local leader_cx, leader_cy = AH.cartesian_coords(leader.x, leader.y)
            local enemy_leader_cx, enemy_leader_cy = AH.cartesian_coords(enemy_leader.x, enemy_leader.y)
            local dist_btw_leaders = math.sqrt( (enemy_leader_cx - leader_cx)^2 + (enemy_leader_cy - leader_cy)^2 )

            local width, height = wesnoth.get_map_size()
            for x = 1,width do
                for y = 1,width do
                    local cx, cy = AH.cartesian_coords(x, y)
                    local enemy_dist = math.sqrt( (enemy_leader_cx - cx)^2 + (enemy_leader_cy - cy)^2 )
                    --if (enemy_dist < dist_btw_leaders) then
                        local dist = math.sqrt( (leader_cx - cx)^2 + (leader_cy - cy)^2 )
                        leader_distance_map:insert(x,y, dist - enemy_dist)
                    --end
                end
            end

            local show_debug = false
            if show_debug then
                AH.put_labels(leader_distance_map)
                W.message{ speaker = 'narrator', message = cfg.zone_id .. ': leader_distance_map' }
            end

            -- First calculate a unit independent rating map
            rating_map, defense_rating_map = LS.create(), LS.create()
            for i,hex in ipairs(zone) do
                local x, y = hex[1], hex[2]

                local def_rating_center = enemy_def_rating_map:get(x, y)

                if def_rating_center then
                    local rating = 0
                    local count = 0

                    for xa,ya in H.adjacent_tiles(x, y) do
                        if leader_distance_map:get(xa, ya) >= leader_distance_map:get(x, y) then
                            local def_rating = enemy_def_rating_map:get(xa,ya)

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
                        rating = rating + grunt_rush_FLS1:zone_loc_rating(cfg.zone_id, x, y)

                        -- Bonus if this is on a village
                        --local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(x, y)).village
                        --if is_village then
                        --    rating = rating + 500
                        --end

                        -- Add stiff penalty if this is a location next to an unoccupied village
                        for xa, ya in H.adjacent_tiles(x, y) do
                            local is_adj_village = wesnoth.get_terrain_info(wesnoth.get_terrain(xa, ya)).village
                            -- If there is an adjacent village and the enemy can get to that village
                            if is_adj_village then
                                local unit_on_village = wesnoth.get_unit(xa, ya)
                                if (not unit_on_village) or (unit_on_village.moves > 0) then
                                    rating = rating - 2000
                                end
                            end
                        end

                        rating_map:insert(x, y, rating)
                    end
                end
            end

            local show_debug = false
            if show_debug then
                AH.put_labels(rating_map)
                W.message { speaker = 'narrator', message = 'Hold zone ' .. cfg.zone_id .. ': unit-independent rating map' }
            end

            -- Now we go on to the unit-dependent rating part
            local max_rating, best_hex, best_unit, best_unit_rating_map = -9e99, {}, {}

            for i,u in ipairs(holders) do
                local unit_alignment = u.__cfg.alignment

                local max_rating_unit, best_hex_unit = -9e99, {}

                local reach = wesnoth.find_reach(u)
                local unit_rating_map = LS.create()
                for i,r in ipairs(reach) do
                    if rating_map:get(r[1], r[2]) then
                        unit_rating_map:insert(r[1], r[2], rating_map:get(r[1], r[2]))
                    end
                end

                unit_rating_map:iter( function(x, y, indep_rating)

                    local unit_rating = 0

                    local defense = wesnoth.unit_defense(u, wesnoth.get_terrain(x, y))

                    -- Significant bonus if this is on a village
                    local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(x, y)).village
                    if is_village then
                        if wesnoth.unit_ability(u, 'regenerate') then
                            defense = defense - 10
                        else
                            defense = defense - 15
                        end
                        if (defense < 10) then defense = 10 end
                    end

                    unit_rating = unit_rating - defense ^ 2

                    -- Factor for ToD (for center hex only)
                    local lawful_bonus = wesnoth.get_time_of_day({ x, y, true }).lawful_bonus
                    local tod_penalty = AH.get_unit_time_of_day_bonus(unit_alignment, lawful_bonus)
                    --print(x,y,lawful_bonus, tod_penalty)

                    local adj_rating, count = 0, 0
                    for xa,ya in H.adjacent_tiles(x, y) do
                        if leader_distance_map:get(xa, ya) >= leader_distance_map:get(x, y) then

                            local defense = wesnoth.unit_defense(u, wesnoth.get_terrain(xa, ya))
                            local movecost = wesnoth.unit_movement_cost(u, wesnoth.get_terrain(xa, ya))
                            if (movecost <= u.max_moves) then
                                adj_rating = adj_rating + defense^2
                                count = count + 1
                            end
                        end
                    end

                    if (count > 0) then
                        unit_rating = unit_rating + adj_rating / count

                        unit_rating = unit_rating / tod_penalty^2
                    end

                    -- Make it more important to have enemy on bad terrain than being on good terrain
                    local total_rating = indep_rating + unit_rating

                    unit_rating_map:insert(x, y, total_rating)

                    if (total_rating > max_rating_unit) then
                        max_rating_unit = total_rating
                        best_hex_unit = { x, y }
                    end
                end)
                --print('max_rating_unit:', max_rating_unit)

                -- If we cannot get there, advance as far as possible
                -- This needs to be separate from and in addition to the step below (unthreatened hexes)
                if (max_rating_unit == -9e99) then
                    --print(cfg.zone_id, ': cannot get to zone -> move toward it', best_unit.id, best_unit.x, best_unit.y)

                    local reach = wesnoth.find_reach(u)

                    for i,r in ipairs(reach) do
                        local unit_in_way = wesnoth.get_unit(r[1], r[2])
                        if (not unit_in_way) or (unit_in_way == best_unit) then
                            local rating = -10000 + grunt_rush_FLS1:zone_advance_rating(cfg.zone_id, r[1], r[2], enemy_leader)

                            unit_rating_map:insert(r[1], r[2], rating)

                            if (rating > max_rating_unit) then
                                max_rating_unit = rating
                                best_hex_unit = { r[1], r[2] }
                            end
                        end
                    end
                end

                if (max_rating_unit > max_rating) then
                    max_rating, best_hex, best_unit, best_unit_rating_map = max_rating_unit, best_hex_unit, u, unit_rating_map
                end
                --print('max_rating:', max_rating, best_hex_unit[1], best_hex_unit[2])

                if show_debug then
                    AH.put_labels(unit_rating_map)
                    W.message { speaker = u.id, message = 'Hold zone: unit-specific rating map' }
                end
            end

            if (max_rating > -9e99) then
                -- If the best hex is unthreatened
                -- has by itself, check whether another hex mostly unthreatened hex farther
                -- advanced in the zone can be gotten to.
                -- This needs to be separate from and in addition to the step above (if unit cannot get into zone)

                -- For Northerners, to force some aggressiveness:
                local hp_factor = 1.2

                local enemy_hp = enemy_attack_map:get(best_hex[1], best_hex[2]) or 0

                if (enemy_hp == 0) then
                    --print(cfg.zone_id, ': reconsidering best hex', best_unit.id, best_unit.x, best_unit.y, '->', best_hex[1], best_hex[2])

                    local reach = wesnoth.find_reach(best_unit)

                    local new_rating_map = LS.create()
                    max_rating = -9e99
                    for i,r in ipairs(reach) do
                        -- ... or if it is threatened by less HP than the unit moving there has itself
                        -- This is only approximate, of course, potentially to be changed later
                        local enemy_hp = enemy_attack_map:get(r[1], r[2]) or 0

                        if (enemy_hp == 0) or
                            ( (enemy_hp < best_unit.hitpoints * hp_factor)
                                and ((best_unit_rating_map:get(r[1], r[2]) or 1) > 0)
                            )
                        then
                            local unit_in_way = wesnoth.get_unit(r[1], r[2])
                            if (not unit_in_way) or (unit_in_way == best_unit) then
                                local rating = grunt_rush_FLS1:zone_advance_rating(cfg.zone_id, r[1], r[2], enemy_leader)

                                -- If the unit is injured and does not regenerate,
                                -- then we very strongly prefer villages
                                if (best_unit.hitpoints < best_unit.max_hitpoints - 12.)
                                    and (not wesnoth.unit_ability(best_unit, 'regenerate'))
                                then
                                    local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(r[1], r[2])).village
                                    if is_village then rating = rating + 1000 end
                                end

                                new_rating_map:insert(r[1], r[2], rating)

                                if (rating > max_rating) then
                                    max_rating = rating
                                    best_hex = { r[1], r[2] }
                                end
                            end
                        end
                    end

                    if show_debug then
                        AH.put_labels(new_rating_map)
                        W.message { speaker = 'narrator', message = 'new_rating_map' }
                    end
                end

                if show_debug then
                    wesnoth.message('Best unit: ' .. best_unit.id .. ' at ' .. best_unit.x .. ',' .. best_unit.y .. ' --> ' .. best_hex[1] .. ',' .. best_hex[2] .. '  (rating=' .. max_rating .. ')')
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

            local combo_att_stats, combo_def_stats, sorted_atts, sorted_dsts, rating, att_rating, def_rating =
                FAU.attack_combo_eval(
                    attacker_copies, target_proxy, dsts,
                    attacker_infos, gamedata.unit_infos[target_id],
                    gamedata, gamedata.unit_copies, gamedata.defense_maps, move_cache
                )

            combo_def_stats.rating = rating
            combo_def_stats.def_rating = def_rating
            combo_def_stats.att_rating = att_rating

            -- Add min_hp field
            local min_hp = 0
            for hp = 0,target_proxy.hitpoints do
                if combo_def_stats.hp_chance[hp] and (combo_def_stats.hp_chance[hp] > 0) then
                    min_hp = hp
                    break
                end
            end
            combo_def_stats.min_hp = min_hp

            --DBG.dbms(combo_def_stats)
            --print('   combo ratings:  ', rating, att_rating, def_rating)

            --print_time('  End calc_counter_attack', next(target))

            return combo_def_stats
        end

        ------ Stats at beginning of turn -----------

        -- This will be blacklisted after first execution each turn
        function grunt_rush_FLS1:stats_eval()
            local score = 999999
            return score
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
        function grunt_rush_FLS1:reset_vars_eval()
            -- Probably not necessary, just a safety measure
            local score = 999998
            return score
        end

        function grunt_rush_FLS1:reset_vars_exec()
            --print(' Resetting variables at beginning of Turn ' .. wesnoth.current.turn)

            -- Reset grunt_rush_FLS1.data at beginning of turn, but need to keep 'complained_about_luck' variable
            local complained_about_luck = grunt_rush_FLS1.data.SP_complained_about_luck
            local enemy_is_undead = grunt_rush_FLS1.data.enemy_is_undead

            --if grunt_rush_FLS1.data.cache then
            --    local count = 0
            --    for k,v in pairs(grunt_rush_FLS1.data.cache) do
            --        print(k)
            --        count = count + 1
            --    end
            --    print('Number of cache entires:', count)
            --end

            grunt_rush_FLS1.data = {}
            grunt_rush_FLS1.data.cache = {}
            grunt_rush_FLS1.data.SP_complained_about_luck = complained_about_luck

            if (enemy_is_undead == nil) then
                local enemy_leader = wesnoth.get_units{
                        { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} },
                        canrecruit = 'yes'
                    }[1]
                enemy_is_undead = (enemy_leader.__cfg.race == "undead") or (enemy_leader.type == "Dark Sorcerer")
            end
            grunt_rush_FLS1.data.enemy_is_undead = enemy_is_undead

            grunt_rush_FLS1.data.turn_start_time = wesnoth.get_time_stamp() / 1000.
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

        ----------Grab villages -----------

        function grunt_rush_FLS1:eval_grab_villages(units, villages, enemies, cfg, gamedata, move_cache)
            --print('#units, #enemies', #units, #enemies)

            -- Get my and enemy keeps
            local my_leader = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]
            local enemy_leader = AH.get_live_units { canrecruit = 'yes',
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }[1]
            local keeps = wesnoth.get_locations { terrain = 'K*' }

            local min_dist, my_keep = 9e99
            for _,keep in ipairs(keeps) do
                local dist = H.distance_between(my_leader.x, my_leader.y, keep[1], keep[2])
                if (dist < min_dist) then
                    min_dist, my_keep = dist, keep
                end
            end

            local min_dist, enemy_keep = 9e99
            for _,keep in ipairs(keeps) do
                local dist = H.distance_between(enemy_leader.x, enemy_leader.y, keep[1], keep[2])
                if (dist < min_dist) then
                    min_dist, enemy_keep = dist, keep
                end
            end

            -- Check if a unit can get to a village
            local max_rating, best_village, best_unit = -9e99, {}, {}
            for j,v in ipairs(villages) do
                local close_village = true -- a "close" village is one that is closer to theAI keep than to the closest enemy keep

                local dist_my_keep = H.distance_between(v[1], v[2], my_keep[1], my_keep[2])
                local dist_enemy_keep = H.distance_between(v[1], v[2], enemy_keep[1], enemy_keep[2])
                if (dist_enemy_keep < dist_my_keep) then
                    close_village = false
                end
                --print_time('village is close village:', v[1], v[2], close_village)

                local dx, dy
                if cfg.hold then dx, dy = cfg.hold.dx, cfg.hold.dy end
                if (dx and dy) then
                    local r = math.sqrt(dx*dx + dy*dy)
                    dx, dy = dx / r, dy / r
                else
                    dx = nil  -- just in case dx exists and dy does not
                    -- existence of dx is used as criterion below
                end

                for i,u in ipairs(units) do
                    local path, cost = wesnoth.find_path(u, v[1], v[2])

                    local unit_in_way = wesnoth.get_unit(v[1], v[2])
                    if unit_in_way then
                        if (unit_in_way.id == u.id) then unit_in_way = nil end
                    end

                    -- Rate all villages that can be reached and are unoccupied by other units
                    if (cost <= u.moves) and (not unit_in_way) then
                        --print('Can reach:', u.id, v[1], v[2], cost)

                        local unit_loc = {}
                        unit_loc[u.id] = { u.x, u.y }

                        local max_hp_chance_zero = 0.5
                        local counter_stats = grunt_rush_FLS1:calc_counter_attack(unit_loc, gamedata, move_cache)
                        --DBG.dbms(counter_stats)

                        if (not counter_stats.hp_chance)
                            or (u.canrecruit and (counter_stats.hp_chance[0] == 0))
                            or ((not u.canrecruit) and (counter_stats.hp_chance[0] <= max_hp_chance_zero))
                        then

                            local rating = 0

                            -- If an enemy can get onto the village, we want to hold it
                            -- Need to take the unit itself off the map, as it might be sitting on the village itself (which then is not reachable by enemies)
                            -- This will also prefer close villages over far ones, everything else being equal
                            wesnoth.extract_unit(u)
                            for k,e in ipairs(enemies) do
                                local path_e, cost_e = wesnoth.find_path(e,v[1], v[2])
                                if (cost_e <= e.max_moves) then
                                    --print('  within enemy reach', e.id)
                                    -- Prefer close villages that are in reach of many enemies,
                                    -- The opposite for far villages
                                    if close_village then
                                        rating = rating + 10
                                    else
                                        rating = rating - 10
                                    end
                                end
                            end
                            wesnoth.put_unit(u)

                            -- Unowned and enemy-owned villages get a large bonus
                            -- but we do not seek them out specifically, as the standard CA does that
                            -- That means, we only do the rest for villages that can be reached by an enemy
                            local owner = wesnoth.get_village_owner(v[1], v[2])
                            if (not owner) then
                                rating = rating + 1000
                            else
                                if wesnoth.is_enemy(owner, wesnoth.current.side) then rating = rating + 2000 end
                            end

                            -- It is impossible for these numbers to add up to zero, so we do the
                            -- detail rating only for those
                            if (rating ~= 0) then
                                -- Take the most injured unit preferentially
                                -- It was checked above that chance to die is less than 50%
                                rating = rating + (u.max_hitpoints - u.hitpoints) / 100.

                                -- We also want to move the "farthest back" unit first
                                -- and take villages from the back first
                                local adv_dist, vill_dist
                                if dx then
                                     -- Distance in direction of (dx, dy) and perpendicular to it
                                    adv_dist = u.x * dx + u.y * dy
                                    vill_dist = v[1] * dx + v[2] * dy
                                else
                                    adv_dist = - H.distance_between(u.x, u.y, enemy_leader.x, enemy_leader.y)
                                    vill_dist = H.distance_between(v[1], v[2], enemy_leader.x, enemy_leader.y)
                                end
                                rating = rating - adv_dist / 10. + vill_dist / 1000.

                                -- If this is the leader, make him the preferred village taker
                                -- but only if he's on the keep
                                if u.canrecruit then
                                    if wesnoth.get_terrain_info(wesnoth.get_terrain(u.x, u.y)).keep then
                                        --print('      -> take village with leader')
                                        rating = rating + 2
                                    else
                                        rating = -9e99
                                    end
                                end
                                --print(u.id, v[1], v[2], ' ---> ', rating)

                                if (rating > max_rating) then
                                    max_rating, best_village, best_unit = rating, v, u
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
                return action
            end

            return nil
        end

        --------- zone_control CA ------------

        function grunt_rush_FLS1:zone_action_retreat_injured(units, cfg)
            -- **** Retreat seriously injured units
            --print_time('retreat')
            local unit, dest, enemy_threat = R.retreat_injured_units(units)
            if unit then
                local allowable_retreat_threat = cfg.allowable_retreat_threat or 0
                --print_time('Found unit to retreat:', unit.id, enemy_threat, allowable_retreat_threat)
                -- Is this a healing location?
                local healloc = false
                if (dest[3] > 2) then healloc = true end
                local action = { units = {unit}, dsts = {dest}, type = 'village', reserve = dest }
                action.action = cfg.zone_id .. ': ' .. 'retreat severely injured units'
                return action, healloc, (enemy_threat <= allowable_retreat_threat)
            end
        end

        function grunt_rush_FLS1:zone_action_villages(units, enemies, zone_map, cfg, gamedata, move_cache)
            -- Otherwise we go for unowned and enemy-owned villages
            -- This needs to happen for all units, not just not-injured ones
            -- Also includes the leader, if he's on his keep
            -- The rating>100 part is to exclude threatened but already owned villages

            local village_grabbers = {}
            for i,u in ipairs(units) do
                if u.canrecruit then
                    if wesnoth.get_terrain_info(wesnoth.get_terrain(u.x, u.y)).keep then
                        table.insert(village_grabbers, u)
                    end
                else
                    table.insert(village_grabbers, u)
                end
            end
            --print_time('#village_grabbers', #village_grabbers)

            if village_grabbers[1] then
                -- For this, we consider all villages, not just the retreat_villages,
                -- but restrict it to villages inside the zone
                local all_villages = wesnoth.get_locations { terrain = '*^V*' }

                local villages = {}
                for _,village in ipairs(all_villages) do
                    if zone_map:get(village[1], village[2]) then
                        table.insert(villages, village)
                    end
                end

                local action = grunt_rush_FLS1:eval_grab_villages(village_grabbers, villages, enemies, cfg, gamedata, move_cache)
                if action then
                    action.action = cfg.zone_id .. ': ' .. 'grab villages'
                    return action
                end
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
                    for j,hex in ipairs(zonedata.zone) do
                        if gamedata.enemy_attack_map[hex[1]]
                            and gamedata.enemy_attack_map[hex[1]][hex[2]]
                            and gamedata.enemy_attack_map[hex[1]][hex[2]][id]
                        then
                            local target = {}
                            target[id] = loc
                            table.insert(targets, target)
                            break
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


                    local combo_att_stats, combo_def_stats, sorted_atts, sorted_dsts,
                        combo_rating, combo_att_rating, combo_def_rating =
                        FAU.attack_combo_eval(
                            attacker_copies, target_proxy, dsts,
                            attacker_infos, gamedata.unit_infos[target_id],
                            gamedata, gamedata.unit_copies, gamedata.defense_maps, move_cache
                    )
                    --DBG.dbms(combo_def_stats)
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
                        for k,att_stats in ipairs(combo_att_stats) do
                            if (sorted_atts[k].canrecruit) then
                                if (att_stats.hp_chance[0] > 0.0) or (att_stats.slowed > 0.0) or (att_stats.poisoned > 0.0) then
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
                        if (combo_def_stats.hp_chance[0] > 0) then
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

        function grunt_rush_FLS1:zone_action_hold(units, units_noMP, enemies, zone_map, enemy_defense_map, cfg)
            --print_time('hold')

            -- The leader does not participate in position holding (for now, at least)
            -- We also exclude severely injured units
            local holders = {}
            for i,u in ipairs(units) do
                if (not u.canrecruit) and (u.hitpoints >= R.min_hp(u)) then
                    table.insert(holders, u)
                end
            end
            if (not holders[1]) then return end

            local zone_enemies, enemy_weights = {}, {}
            if cfg.hold and cfg.hold.x and cfg.hold.y then
                for i,e in ipairs(enemies) do
                    local moves = e.moves
                    e.moves = e.max_moves
                    local path, cost = wesnoth.find_path(e, cfg.hold.x, cfg.hold.y, { ignore_units = true })
                    --print(cfg.zone_id, e.id, e.x, e.y, cfg.hold.x, cfg.hold.y, cost)
                    e.moves = moves

                    if (cost <= e.max_moves * 2) then
                        --print(cfg.zone_id, 'inserting enemy:', e.id, e.x, e.y)
                        table.insert(zone_enemies, e)
                        local weight = 1. / math.ceil(cost / e.max_moves)
                        if (weight == 0) then weight = 1 end
                        table.insert(enemy_weights, weight)
                    end
                end
            end


            -- Only check for possible position holding if hold.hp_ratio is met
            -- or is conditions in cfg.secure are met
            -- If hold.hp_ratio does not exist, it's true by default

            local eval_hold = true
            if cfg.hold.hp_ratio then
                local hp_ratio = 1e99
                if (#zone_enemies > 0) then
                    hp_ratio = grunt_rush_FLS1:hp_ratio(units_noMP, zone_enemies, enemy_weights)
                end
                --print(cfg.zone_id, 'hp_ratio, #units_noMP, #zone_enemies', hp_ratio, #units_noMP, #zone_enemies)

                -- Don't evaluate for holding position if the hp_ratio in the zone is already high enough
                if (hp_ratio >= cfg.hold.hp_ratio) then
                    eval_hold = false
                end

                -- Also, if a unit ratio is set, check for this as well
                if cfg.hold.unit_ratio then
                    local sum_enemy_weights = 0
                    for _,weight in ipairs(enemy_weights) do
                        sum_enemy_weights = sum_enemy_weights + weight
                    end
                    local unit_ratio = #units_noMP / sum_enemy_weights
                    --print(cfg.zone_id, 'unit_ratio', unit_ratio)
                    if (unit_ratio >= cfg.hold.unit_ratio) then
                        eval_hold = false
                    end
                end
            end
            --print('eval_hold 1', eval_hold)

            -- If there are unoccupied or enemy-occupied villages in the hold zone, send units there,
            -- if we do not have enough units that have moved already in the zone
            local units_per_village = 0.5
            if cfg.villages and cfg.villages.units_per_village then
                units_per_village = cfg.villages.units_per_village
            end

            if (not eval_hold) then
                if (#units_noMP < #cfg.retreat_villages * units_per_village) then
                    for i,v in ipairs(cfg.retreat_villages) do
                        local owner = wesnoth.get_village_owner(v[1], v[2])
                        if (not owner) or wesnoth.is_enemy(owner, wesnoth.current.side) then
                            eval_hold, get_villages = true, true
                        end
                    end
                end
                --print('#units_noMP, #cfg.retreat_villages', #units_noMP, #cfg.retreat_villages)
            end
            --print('eval_hold 2', eval_hold)

            if eval_hold then
                local unit, dst = grunt_rush_FLS1:hold_zone(holders, enemy_defense_map, cfg)

                local action = nil
                if unit then
                    action = { units = { unit }, dsts = { dst } }
                    action.action = cfg.zone_id .. ': ' .. 'hold position'
                end
                return action
            end

            -- If we got here, check whether there are instructions to secure the zone
            -- That is, whether units are not in the zone, but are threatening a key location in it
            -- The parameters for this are set in cfg.secure
            if cfg.secure then
                -- Count units that are already in the zone (no MP left) that
                -- are not the side leader
                local number_units_noMP_noleader = 0
                for i,u in ipairs(units_noMP) do
                    if (not u.canrecruit) then number_units_noMP_noleader = number_units_noMP_noleader + 1 end
                end
                --print('Units already in zone:', number_units_noMP_noleader)

                -- If there are not enough units, move others there
                if (number_units_noMP_noleader < cfg.secure.min_units) then
                    -- Check whether (cfg.secure.x,cfg.secure.y) is threatened
                    local enemy_threats = false
                    for i,e in ipairs(enemies) do
                        local path, cost = wesnoth.find_path(e, cfg.secure.x, cfg.secure.y)
                        if (cost <= e.max_moves * cfg.secure.moves_away) then
                           enemy_threats = true
                           break
                        end
                    end
                    --print(cfg.zone_id, 'need to secure ' .. cfg.secure.x .. ',' .. cfg.secure.y, enemy_threats)

                    -- If we need to secure the zone
                    if enemy_threats then
                        -- The best unit is simply the one that can get there first
                        -- If several can make it in the same number of moves, use the one with the most HP
                        local max_rating, best_unit = -9e99, {}
                        for i,u in ipairs(holders) do
                            local path, cost = wesnoth.find_path(u, cfg.secure.x, cfg.secure.y)
                            local rating = - math.ceil(cost / u.max_moves)

                            rating = rating + u.hitpoints / 100.

                            if (rating > max_rating) then
                                max_rating, best_unit = rating, u
                            end
                        end

                        -- Find move for the unit found above
                        if (max_rating > -9e99) then
                            local dst = AH.next_hop(best_unit, cfg.secure.x, cfg.secure.y)
                            if dst then
                                local action = { units = { best_unit }, dsts = { dst } }
                                action.action = cfg.zone_id .. ': ' .. 'secure zone'
                                return action
                            end
                        end
                    end
                end
            end

            return nil
        end

        function grunt_rush_FLS1:high_priority_attack(unit, cfg, move_cache)
            local attacks = AH.get_attacks({unit})
            if (not attacks[1]) then return end

            local enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }
            local enemy_attack_map = BC.get_attack_map(enemies)

            local max_rating, best_target, best_hex = -9e99
            for _,attack in ipairs(attacks) do
                if ((enemy_attack_map.units:get(attack.dst.x, attack.dst.y) or 0) <= 1) then
                    local target = wesnoth.get_unit(attack.target.x, attack.target.y)
                    --print('Evaluating attack at: ', attack.dst.x, attack.dst.y, target.id)

                    local dst = { attack.dst.x, attack.dst.y }
                    local att_stats, def_stats = BC.battle_outcome(unit, target, dst, {}, grunt_rush_FLS1.data.cache, move_cache)
                    local rating = BC.attack_rating(unit, target, dst, att_stats, def_stats)
                    --print(rating)

                    if (rating > 0) and (rating > max_rating) and (def_stats.hp_chance[0] > 0.67) then
                        max_rating = rating
                        best_target, best_hex = target, { attack.dst.x, attack.dst.y }
                    end
                end
            end

            if best_target then
                local action = { units = { unit }, dsts = { best_hex }, enemy = best_target }
                action.action = cfg.zone_id .. ': ' .. 'high priority attack'
                return action
            end
        end

        function grunt_rush_FLS1:get_zone_action(cfg, gamedata, move_cache)
            -- Find the best action to do in the zone described in 'cfg'
            -- This is all done together in one function, rather than in separate CAs so that
            --  1. Zones get done one at a time (rather than one CA at a time)
            --  2. Relative scoring of different types of moves is possible

            cfg = cfg or {}

            -- First, set up the general filters and tables, to be used by all actions

            -- Unit filter:
            -- This includes the leader. Needs to be excluded specifically if he shouldn't take part in an action

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

                    if gamedata.my_units_MP[id] then
                        zonedata.zone_units_MP[id] = loc
                    else
                        zonedata.zone_units_noMP[id] = loc
                    end

                    if (gamedata.unit_copies[id].attacks_left > 0) then
                        -- The leader counts as one of the attackers, but only if he's on his keep
                        if gamedata.unit_copies[id].canrecruit then
                            if wesnoth.get_terrain_info(wesnoth.get_terrain(
                                gamedata.unit_copies[id].x, gamedata.unit_copies[id].y)
                            ).keep then
                                zonedata.zone_units_attacks[id] = loc
                            end
                        else
                            zonedata.zone_units_attacks[id] = loc
                        end
                    end
                end
            end

            -- xxxxxxxxxxxxxxxxxxxxxxxxxxxx
            local unit_filter = { side = wesnoth.current.side }
            if cfg.unit_filter then
                for k,v in pairs(cfg.unit_filter) do unit_filter[k] = v end
            end
            --DBG.dbms(unit_filter)
            local all_units
            if cfg.only_zone_units then
                all_units = AH.get_live_units(unit_filter)
            else
                all_units = AH.get_live_units { side = wesnoth.current.side }
            end

            local zone_units, zone_units_attacks = {}, {}
            for i,u in ipairs(all_units) do
                if (u.moves > 0) then
                    table.insert(zone_units, u)
                end
                if (u.attacks_left > 0) then
                    table.insert(zone_units_attacks, u)
                end
            end
            all_units = nil

            local all_zone_units = AH.get_live_units(unit_filter)
            local zone_units_noMP = {}
            for i,u in ipairs(all_zone_units) do
                if (u.moves <= 0) then
                    table.insert(zone_units_noMP, u)
                end
            end
            -- xxxxxxxxxxxxxxxxxxxxxxxxxxxx

            if (not next(zonedata.zone_units_MP)) and (not next(zonedata.zone_units_attacks)) then return end

            -- Then get all the enemies (this needs to be all of them, to get the HP ratio)
            local enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }
            --print_time('#zone_units, #enemies', #zone_units, #enemies)

            -- Get all the hexes in the zone
            local zone = wesnoth.get_locations(cfg.zone_filter)
            local zone_map = LS.of_pairs(zone)

            zonedata.zone = wesnoth.get_locations(cfg.zone_filter)
            zonedata.zone_map = LS.of_pairs(zone)

            -- Also get the defense map for the enemies
            local enemy_defense_map = BC.best_defense_map(enemies, { ignore_these_units = zone_units })

            -- **** This ends the common initialization for all zone actions ****

            -- **** Retreat severely injured units evaluation ****
            --print_time('  ' .. cfg.zone_id .. ': retreat_injured eval')
            local retreat_action
            if (not cfg.do_action) or cfg.do_action.retreat_injured_safe then
                if (not cfg.skip_action) or (not cfg.skip_action.retreat_injured) then
                    local healloc, safeloc  -- boolean indicating whether the destination is a healing location
                    retreat_action, healloc, safeloc = grunt_rush_FLS1:zone_action_retreat_injured(zone_units, cfg)
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
                    village_action = grunt_rush_FLS1:zone_action_villages(zone_units, enemies, zone_map, cfg, gamedata, move_cache)
                    if village_action and (village_action.rating > 100) then
                        --print_time(village_action.action)
                        local attack_action = grunt_rush_FLS1:high_priority_attack(village_action.units[1], cfg, move_cache)
                        return attack_action or village_action
                    end
                end
            end

            -- ***********************************
            -- Take all units with MP off the map.
            -- !!!! This eventually needs to be done for all actions

            local extracted_units = {}
            for id,loc in pairs(gamedata.my_units_MP) do
                local unit = wesnoth.get_unit(loc[1], loc[2])
                wesnoth.extract_unit(unit)
                table.insert(extracted_units, unit)
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
                        for _,unit in ipairs(extracted_units) do wesnoth.put_unit(unit) end
                        return action
                    end
                end
            end

            -- Put the own units with MP back out there
            -- !!!! This eventually needs to be done for all actions
            for _,unit in ipairs(extracted_units) do wesnoth.put_unit(unit) end



            -- **** Hold position evaluation ****
            --print_time('  ' .. cfg.zone_id .. ': hold eval')
            if (not cfg.do_action) or cfg.do_action.hold then
                if (not cfg.skip_action) or (not cfg.skip_action.hold) then
                    local action = grunt_rush_FLS1:zone_action_hold(zone_units, zone_units_noMP, enemies, zone_map, enemy_defense_map, cfg)
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

            -- Set up the different tables for the turn
            local gamedata = FGU.get_gamedata()
            local move_cache = {}

            local cfgs = grunt_rush_FLS1:get_zone_cfgs()
            for i_c,cfg in ipairs(cfgs) do
                --print_time('zone_control: ', cfg.zone_id)

                local zone_action = grunt_rush_FLS1:get_zone_action(cfg, gamedata, move_cache)

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
                    local _, combo_def_stats = BC.attack_combo_eval(
                        grunt_rush_FLS1.data.zone_action.units,
                        grunt_rush_FLS1.data.zone_action.dsts,
                        grunt_rush_FLS1.data.zone_action.enemy,
                        grunt_rush_FLS1.data.cache
                    )

                    if (combo_def_stats.hp_chance[0] > 0) then
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

                        local att_stats, def_stats = BC.battle_outcome(
                            unit,
                            grunt_rush_FLS1.data.zone_action.enemy,
                            grunt_rush_FLS1.data.zone_action.dsts[best_ind],
                            {},
                            grunt_rush_FLS1.data.cache
                        )

                        local kill_rating = def_stats.hp_chance[0] - att_stats.hp_chance[0]
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
                local leader = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]
                local dx, dy  = leader.x - dst[1], leader.y - dst[2]
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

        -----------Spread poison ----------------

        function grunt_rush_FLS1:spread_poison_eval(poisoners, enemies, cfg)
            local attacks = AH.get_attacks(poisoners, { simulate_combat = true, include_occupied = true })
            --print('#attacks', #attacks)
            if (not attacks[1]) then return end

            move_cache = {}

            -- Go through all possible attacks with poisoners
            local max_rating, best_attacker, best_dst, best_enemy = -9e99, {}
            for i,a in ipairs(attacks) do
                local attacker = wesnoth.get_unit(a.src.x, a.src.y)
                local defender = wesnoth.get_unit(a.target.x, a.target.y)

                -- Don't attack an enemy that's not in the zone
                local enemy_in_zone = false
                for j,e in ipairs(enemies) do
                    if (a.target.x == e.x) and (a.target.y == e.y) then
                        enemy_in_zone = true
                        break
                    end
                end

                -- Don't try to poison a unit that cannot be poisoned
                local cant_poison = defender.status.poisoned or defender.status.not_living

                -- Also, poisoning units that would level up through the attack or could level up immediately after is very bad
                local about_to_level = (defender.max_experience - defender.experience) <= (wesnoth.unit_types[attacker.type].level * 2)

                local poison_attack = true
                if (not enemy_in_zone) or cant_poison or about_to_level then
                    poison_attack = false
                end

                -- Before evaluating the poison attack, check whether it is too dangerous
                if poison_attack_xxxxxxxxxx then
                    local min_average_hp = 5
                    local max_hp_chance_zero = 0.3
                    local counter_stats = grunt_rush_FLS1:calc_counter_attack(attacker, { a.dst.x, a.dst.y },
                        {
                            stop_eval_average_hp = min_average_hp,
                            stop_eval_hp_chance_zero = max_hp_chance_zero
                        },
                        move_cache
                    )
                    --print('Poison counter-attack:', attacker.id, a.dst.x, a.dst.y, counter_stats.hp_chance[0], counter_stats.average_hp)
                    -- Use a condition when damage is too much to be worthwhile
                    if (counter_stats.hp_chance[0] >= max_hp_chance_zero)
                        or (counter_stats.average_hp <= min_average_hp)
                    then
                        --print('Poison attack too dangerous')
                        poison_attack = false
                    end
                end

                if poison_attack then
                    -- Strongest enemy gets poisoned first
                    local rating = defender.hitpoints

                    -- Always attack enemy leader, if possible
                    if defender.canrecruit then rating = rating + 1000 end

                    -- Enemies on villages are not good targets
                    local enemy_on_village = wesnoth.get_terrain_info(wesnoth.get_terrain(defender.x, defender.y)).village
                    if enemy_on_village then rating = rating - 500 end

                    -- Enemies that can regenerate are not good targets
                    if wesnoth.unit_ability(defender, 'regenerate') then rating = rating - 1000 end

                    -- Enemies with magical attacks in matching range categories are not good targets
                    local attack_range = 'none'
                    for att in H.child_range(attacker.__cfg, 'attack') do
                        for sp in H.child_range(att, 'specials') do
                            if H.get_child(sp, 'poison') then
                                attack_range = att.range
                            end
                        end
                    end
                    for att in H.child_range(defender.__cfg, 'attack') do
                        if att.range == attack_range then
                            for special in H.child_range(att, 'specials') do
                                local mod = H.get_child(special, 'chance_to_hit')
                                if mod and (mod.id == 'magical') then
                                   rating = rating - 500
                                end
                            end
                        end
                    end

                    -- More priority to enemies on strong terrain
                    local defender_defense = 100 - wesnoth.unit_defense(defender, wesnoth.get_terrain(defender.x, defender.y))
                    rating = rating + defender_defense / 4.
                    --print('rating 1', rating, attacker.id, a.dst.x, a.dst.y)

                    -- Also want to attack from the strongest possible terrain
                    local attack_defense = 100 - wesnoth.unit_defense(attacker, wesnoth.get_terrain(a.dst.x, a.dst.y))
                    rating = rating + attack_defense / 2.
                    --print('rating terrain', rating, attacker.id, a.dst.x, a.dst.y)

                    -- And from village everything else being equal
                    local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(a.dst.x, a.dst.y)).village
                    if is_village then rating = rating + 0.5 end
                    --print('rating village', rating, attacker.id, a.dst.x, a.dst.y)

                    -- Minor penalty if unit needs to be moved out of the way
                    if a.attack_hex_occupied then rating = rating - 0.1 end
                    --print('rating occupied', rating, attacker.id, a.dst.x, a.dst.y)

                    -- Enemy on village: only attack if the enemy is hurt already
                    if enemy_on_village and (defender.max_hitpoints - defender.hitpoints < 8) then rating = -9e99 end

                    --print('  -> final poisoner rating', rating, attacker.id, a.dst.x, a.dst.y)

                    if rating > max_rating then
                        max_rating, best_attacker, best_dst, best_enemy = rating, attacker, { a.dst.x, a.dst.y }, defender
                    end
                end
            end
            --print('max_rating', max_rating)

            if (max_rating > -9e99) then
                local action = {
                    units = { best_attacker },
                    dsts = { best_dst },
                    enemy = best_enemy
                }
                action.action = cfg.zone_id .. ': ' .. 'poison attack'
                return action
            end

            return
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
            local units_with_moves = AH.get_units_with_moves { side = wesnoth.current.side }

            local injured_units = {}
            for _,unit in ipairs(units_with_moves) do
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
            if units_with_moves[1] then return score_finish_turn end

            local units_with_attacks = AH.get_units_with_attacks { side = wesnoth.current.side }
            if units_with_attacks[1] then return score_finish_turn end

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

            local units_with_attacks = AH.get_units_with_attacks { side = wesnoth.current.side }
            for i,u in ipairs(units_with_attacks) do
                AH.checked_stopunit_all(ai, u)
                --print('Attacks left:', u.id)
            end

            local units_with_moves = AH.get_units_with_moves { side = wesnoth.current.side }
            for i,u in ipairs(units_with_moves) do
                --print('Moves left:', u.id)
                AH.checked_stopunit_all(ai, u)
            end
        end

        return grunt_rush_FLS1
    end
}
