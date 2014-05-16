return {
    init = function(ai)

        local grunt_rush_FLS1 = {}

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        local BC = wesnoth.require "~/add-ons/AI-demos/lua/battle_calcs.lua"
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
                --unit_filter = { x = '1-' .. width , y = '1-' .. height },
                unit_filter = { x = '16-25,15-22', y = '1-13,14-19' },
                skip_action = { retreat_injured_unsafe = true },
                hold = { x = 18, y = 9, dx = 0, dy = 1, hp_ratio = 0.75 },
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
                hold = { x = 11, y = 9, dx = 0, dy = 1, hp_ratio = 0.66, unit_ratio = 1.1 },
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
                hold = { x = 27, y = 11, dx = 0, dy = 1, hp_ratio = 0.66, unit_ratio = 1.1 },
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

            -- This way it will be easy to change the priorities on the fly later:

            local sorted_cfgs = {}
            table.insert(sorted_cfgs, cfg_center)
            table.insert(sorted_cfgs, cfg_left)
            table.insert(sorted_cfgs, cfg_right)


            -- The following is placeholder code for later, when we might want to
            -- set up the priority of the zones dynamically
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

        function grunt_rush_FLS1:best_trapping_attack_opposite(units_org, enemies_org, cfg, cache_this_move)
            -- Find best trapping attack on enemy by putting two units on opposite sides
            -- Inputs:
            -- - units: the units to be considered for doing the trapping
            --   - These units don't actually have to be able to attack the enemies, that is determined here
            -- - enemies: the enemies for which trapping is to be attempted
            -- Output: the attackers and dsts arrays and the enemy; or nil, if no suitable attack was found
            if (not units_org) then return end
            if (not enemies_org) then return end

            -- Need to make copies of the array, as they will be changed
            local units = AH.table_copy(units_org)
            local enemies = AH.table_copy(enemies_org)

            -- Need to eliminate units that are Level 0 (trappers) or skirmishers (enemies)
            for i = #units,1,-1 do
                if (wesnoth.unit_types[units[i].type].level == 0) then
                    --print('Eliminating ' .. units[i].id .. ' from trappers: Level 0 unit')
                    table.remove(units, i)
                end
            end
            if (not units[1]) then return nil end

            -- Eliminate skirmishers
            for i=#enemies,1,-1 do
                if wesnoth.unit_ability(enemies[i], 'skirmisher') then
                    --print('Eliminating ' .. enemies[i].id .. ' from enemies: skirmisher')
                    table.remove(enemies, i)
                end
            end
            if (not enemies[1]) then return nil end

            -- Also eliminate enemies that are already trapped
            for i=#enemies,1,-1 do
                for x,y in H.adjacent_tiles(enemies[i].x, enemies[i].y) do
                    local trapper = wesnoth.get_unit(x, y)
                    if trapper and (trapper.moves == 0) then
                        local opp_hex = AH.find_opposite_hex({ x, y }, { enemies[i].x, enemies[i].y })
                        local opp_trapper = wesnoth.get_unit(opp_hex[1], opp_hex[2])
                        if opp_trapper and (opp_trapper.moves == 0) then
                            --print('Eliminating ' .. enemies[i].id .. ' from enemies: already trapped')
                            table.remove(enemies, i)
                            break  -- need to exit 'for' loop here
                        end
                    end
                end
            end
            if (not enemies[1]) then return nil end

            local max_rating, best_attackers, best_dsts, best_enemy = -9e99, {}, {}, {}
            local counter_table = {}  -- Counter-attacks are very expensive, store to avoid duplication
            for i,e in ipairs(enemies) do
                --print_time(i, e.id)
                local attack_combos = AH.get_attack_combos(units, e, { include_occupied = true })
                --DBG.dbms(attack_combos)
                --print_time('    #attack_combos', #attack_combos)

                local enemy_on_village = wesnoth.get_terrain_info(wesnoth.get_terrain(e.x, e.y)).village
                local enemy_cost = wesnoth.unit_types[e.type].cost

                -- Villages adjacent to enemy
                local adjacent_villages = {}
                for x, y in H.adjacent_tiles(e.x, e.y) do
                    if wesnoth.get_terrain_info(wesnoth.get_terrain(x, y)).village then
                        table.insert(adjacent_villages, { x = x, y = y })
                    end
                end

                for j,combo in ipairs(attack_combos) do
                    -- Only keep combos that include exactly 2 attackers
                    -- Need to count them, as they are not in order
                    --DBG.dbms(combo)
                    local number, dst, src = 0, {}, {}
                    for kk,vv in pairs(combo) do
                        number = number + 1
                        dst[number], src[number] = kk, vv
                    end

                    -- Now check whether this attack can trap the enemy
                    local trapping_attack = false

                    -- First, if there's already a unit with no MP left on the other side
                    if (number == 1) then
                        --print('1-unit attack:', dst[1], dst[2])
                        local hex = { math.floor(dst[1] / 1000), dst[1] % 1000 }
                        local opp_hex = AH.find_opposite_hex(hex, { e.x, e.y })
                        local opp_unit = wesnoth.get_unit(opp_hex[1], opp_hex[2])
                        if opp_unit and (opp_unit.moves == 0) and (opp_unit.side == wesnoth.current.side) and (wesnoth.unit_types[opp_unit.type].level > 0) then
                            trapping_attack = true
                        end
                        --print('  trapping_attack: ', trapping_attack)
                    end

                    -- Second, by putting two units on opposite sides
                    if (number == 2) then
                        --print('2-unit attack:', dst[1], dst[2])
                        local hex1 = { math.floor(dst[1] / 1000), dst[1] % 1000 }
                        local hex2 = { math.floor(dst[2] / 1000), dst[2] % 1000 }
                        if AH.is_opposite_adjacent(hex1, hex2, { e.x, e.y }) then
                            trapping_attack = true
                        end
                        --print('  trapping_attack: ', trapping_attack)
                    end

                    -- Don't trap if it lets the enemy reach a village next turn anyway
                    if trapping_attack and adjacent_villages[1] then
                        for i_v,v in ipairs(adjacent_villages) do
                            if (not combo[v.x * 1000 + v.y]) then
                                trapping_attack = false
                                --print('Trapping attack leaves village open: ', v.x, v.y)
                            end
                        end
                    end

                    -- Now we need to calculate the attack combo stats
                    local combo_def_stats, combo_att_stats = {}, {}
                    local attackers, dsts = {}, {}
                    local rating = 0
                    if trapping_attack then
                        for dst,src in pairs(combo) do
                            local att = wesnoth.get_unit(math.floor(src / 1000), src % 1000)
                            table.insert(attackers, att)
                            table.insert(dsts, { math.floor(dst / 1000), dst % 1000 })
                        end
                        combo_att_stats, combo_def_stats, attackers, dsts, rating = BC.attack_combo_stats(attackers, dsts, e, grunt_rush_FLS1.data.cache, cache_this_move)
                    end

                    -- Don't attack under certain circumstances:
                    -- 1. If one of the attackers has a >50% chance to die
                    --    This is under the assumption of median outcome of previous attack, not reevaluated for each individual attack
                    -- This is done simply by resetting 'trapping_attack'
                    for i_a, a_stats in ipairs(combo_att_stats) do
                        --print(i_a, a_stats.hp_chance[0])
                        if (a_stats.hp_chance[0] >= 0.5) then trapping_attack = false end
                    end
                    --print('  trapping_attack after elim: ', trapping_attack)

                    -- 2. If the 'exposure' at the attack location is too high, don't do it either
                    if trapping_attack then

                        for i_a,a in ipairs(attackers) do
                            local x, y = dsts[i_a][1], dsts[i_a][2]
                            local att_ind = a.x * 1000 + a.y
                            local dst_ind = x * 1000 + y
                            if (not counter_table[att_ind]) then counter_table[att_ind] = {} end

                            local min_average_hp = 10
                            local max_hp_chance_zero = 0.3
                            if (not counter_table[att_ind][dst_ind]) then
                                --print('Calculating new counter-attack combination')
                                local counter_stats = grunt_rush_FLS1:calc_counter_attack(a, { x, y },
                                    {
                                        stop_eval_average_hp = min_average_hp,
                                        stop_eval_hp_chance_zero = max_hp_chance_zero
                                    }
                                )
                                counter_table[att_ind][dst_ind] =
                                    { min_hp = counter_stats.min_hp, counter_stats = counter_stats }
                            else
                                --print('Counter-attack combo already calculated. Re-using.')
                            end
                            local counter_min_hp = counter_table[att_ind][dst_ind].min_hp
                            local counter_stats = counter_table[att_ind][dst_ind].counter_stats

                            --print(a.id, dsts[i_a][1], dsts[i_a][2], counter_stats.hp_chance[0], counter_stats.average_hp)
                            -- Use a condition when damage is too much to be worthwhile
                            if (counter_stats.hp_chance[0] >= max_hp_chance_zero)
                                or (counter_stats.average_hp <= min_average_hp)
                            then
                                --print('Trapping attack too dangerous')
                                trapping_attack = false
                            end
                        end
                    end

                    -- If at this point 'trapping_attack' is still true, we'll actually evaluate it
                    if trapping_attack then

                        -- Damage to enemy is good
                        local rating = e.hitpoints - combo_def_stats.average_hp + combo_def_stats.hp_chance[0] * 50.
                        -- Attack enemies on villages preferentially
                        if enemy_on_village then rating = rating + 20 end
                        -- Cost of enemy is another factor
                        rating = rating + enemy_cost

                        -- Now go through all the attacker stats
                        for i_a, a_stats in ipairs(combo_att_stats) do
                            -- Damage to own units is bad
                            rating = rating - (attackers[i_a].hitpoints - a_stats.average_hp) - a_stats.hp_chance[0] * 50.
                            -- Also, the less a unit costs, the better
                            -- This will also favor attacks by single unit, if possible, unless
                            -- 2-unit attack has much larger chance of success/damage
                            rating = rating - wesnoth.unit_types[attackers[i_a].type].cost
                            -- Own unit on village gets bonus too
                            local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(dsts[i_a][1], dsts[i_a][2])).village
                            if is_village then rating = rating + 20 end

                            -- Minor penalty if a unit needs to be moved (that is not the attacker itself)
                            local unit_in_way = wesnoth.get_unit(dsts[i_a][1], dsts[i_a][2])
                            if unit_in_way and ((unit_in_way.x ~= attackers[i_a].x) or (unit_in_way.y ~= attackers[i_a].y)) then
                                rating = rating - 0.01
                            end
                        end

                        --print_time(' -----------------------> zoc attack rating', rating)
                        if (rating > max_rating) then
                            max_rating, best_attackers, best_dsts, best_enemy = rating, attackers, dsts, e
                        end
                    end
                end
            end
            --print_time('max_rating ', max_rating)

            if (max_rating > -9e99) then
                local action = {
                    units = best_attackers,
                    dsts = best_dsts,
                    enemy = best_enemy
                }
                action.action = cfg.zone_id .. ': ' .. 'trapping attack'
                return action
            end
            return nil
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
            local max_rating, best_hex, best_unit = -9e99, {}, {}

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
                        defense = defense - 15
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
                    max_rating, best_hex, best_unit = max_rating_unit, best_hex_unit, u
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
                local hp_factor = 1.25

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

                        if (enemy_hp < best_unit.hitpoints * hp_factor) then
                            local unit_in_way = wesnoth.get_unit(r[1], r[2])
                            if (not unit_in_way) or (unit_in_way == best_unit) then
                                local rating = grunt_rush_FLS1:zone_advance_rating(cfg.zone_id, r[1], r[2], enemy_leader)

                                -- If the unit is injured and does not regenerate,
                                -- then we very strongly prefer villages
                                if (best_unit.hitpoints < best_unit.max_hitpoints)
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

        function grunt_rush_FLS1:calc_counter_attack(unit, hex, cfg, cache_this_move)
            -- Get counter-attack results a unit might experience next turn if it moved to 'hex'
            -- Optional input cfg: config table with following optional fields:
            --   - approx (boolean): if set, use the approximate method instead of full calculation
            --   - enemies (unit table): use these enemies (instead of all enemies)
            --          to calculate counter attack damage
            --   - stop_eval_average_hp=0 (non-negative number): stop evaluating other attack combinations
            --       when average HP <= this value has been found. This is "bad enough".
            --   - stop_eval_min_hp=-1 (number): stop evaluating other attack combinations
            --       when minimum HP <= this value has been found. This is "bad enough".
            --       The default is -1 because not all min_hp == 0 cases are the same (the CTK can
            --       be different). So we don't want to stop checking other attack combos, but since
            --       min_hp >= 0, any negative number will do as default (doesn't have to be -inf)
            --   - stop_eval_hp_chance_zero=1 (number <= 1): stop evaluating other attack combinations
            --       when hp_chance[0] >= this value has been found. This is "bad enough".
            --
            -- Returns a table similar to def_stats from wesnoth.simulate_combat,
            -- but with added and/or missing fields, depending on the parameters
            --  - hp_chance, slowed and poisoned are not included for approximate method
            --  - min_hp field added
            --  - TODO: flags to be added in some situations

            --print_time('Start calc_counter_attack')
            cfg = cfg or {}

            -- The evaluation loop cutoff criteria
            -- Note: it's *not* a typo that one is 0 and the other -1
            cfg.stop_eval_average_hp = cfg.stop_eval_average_hp or 0
            cfg.stop_eval_min_hp = cfg.stop_eval_min_hp or -1
            cfg.stop_eval_hp_chance_zero = cfg.stop_eval_hp_chance_zero or 1

            -- Just in case a negative number gets passed for stop_eval_average_hp
            -- By contrast, stop_eval_min_hp may be negative (to allow for it to be 0 and continue)
            if (cfg.stop_eval_average_hp < 0) then cfg.stop_eval_average_hp = 0 end

            -- Also, the maximum sensible value against which to check stop_eval_hp_chance_zero is 1
            if (cfg.stop_eval_hp_chance_zero > 1) then cfg.stop_eval_hp_chance_zero = 1 end

            -- Get enemy units
            local enemies
            -- Use only transferred enemies, if cfg.enemies is set
            if cfg.enemies then
                enemies = cfg.enemies
                --print('using transferred enemies', #enemies)
            else  -- otherwise use all enemy units
                enemies = AH.get_live_units {
                    { "filter_side", {{"enemy_of", { side = unit.side } }} }
                }
                --print('finding all enemies', #enemies)
            end

            -- Need to take units with MP off the map for enemy path finding
            local units_MP = AH.get_units_with_moves { side = unit.side }

            -- Take all units with MP left off the map, except the unit under investigation itself
            for i,u in ipairs(units_MP) do
                if (u.x ~= unit.x) or (u.y ~= unit.y) then
                    wesnoth.extract_unit(u)
                end
            end

            -- Now we put our unit into the position of interest
            -- (and remove any unit that might already be there)
            local org_hex = { unit.x, unit.y }
            local unit_in_way = {}
            if (org_hex[1] ~= hex[1]) or (org_hex[2] ~= hex[2]) then
                unit_in_way = wesnoth.get_unit(hex[1], hex[2])
                if unit_in_way then wesnoth.extract_unit(unit_in_way) end
                wesnoth.put_unit(hex[1], hex[2], unit)
            end

            -- Get all possible attack combinations
            -- Restrict to a maximum of 1000 combos for now
            -- TODO: optimize this number, possibly make it variable depending on the situation
            --print_time('get_attack_combos')

            local counter_attack = BC.approx_best_attack_combo(enemies, unit, grunt_rush_FLS1.data.cache, cache_this_move)

            -- Put units back to where they were
            if (org_hex[1] ~= hex[1]) or (org_hex[2] ~= hex[2]) then
                wesnoth.put_unit(org_hex[1], org_hex[2], unit)
                if unit_in_way then wesnoth.put_unit(hex[1], hex[2], unit_in_way) end
            end
            for i,u in ipairs(units_MP) do
                if (u.x ~= unit.x) or (u.y ~= unit.y) then
                    wesnoth.put_unit(u)
                end
            end

            -- If no attacks are found, we're done; return stats of unit as is
            if (not next(counter_attack)) then
                local hp_chance = {}
                hp_chance[unit.hitpoints] = 1
                hp_chance[0] = 0  -- hp_chance[0] is always assumed to be included, even when 0
                return {
                    average_hp = unit.hitpoints,
                    min_hp = unit.hitpoints,
                    hp_chance = hp_chance,
                    slowed = 0,
                    poisoned = 0
                }
            end

            local old_x, old_y = unit.x, unit.y
            wesnoth.extract_unit(unit)
            unit.x, unit.y = hex[1], hex[2]

            local def_stats

            -- Get the attack combo outcome. We're really only interested in combo_def_stats
            if cfg.approx then  -- Approximate method for average HP
                local total_damage, max_damage = 0, 0
                for j,att in ipairs(combo) do
                    local dst = { math.floor(att.dst / 1000), att.dst % 1000 }
                    local att_stats, def_stats =
                        BC.battle_outcome(enemies_map[att.src], unit, { dst = dst }, grunt_rush_FLS1.data.cache, cache_this_move)

                    total_damage = total_damage + unit.hitpoints - def_stats.average_hp

                    -- Also get the maximum damage possible
                    local min_hp = unit.hitpoints
                    for hp, perc in pairs(def_stats.hp_chance) do
                        if (perc > 0) and (hp < min_hp) then min_hp = hp end
                    end
                    --print("min_hp", min_hp)
                    max_damage = max_damage + unit.hitpoints - min_hp
                end
                --print("total_damage", total_damage)
                --print("max_damage", max_damage)

                -- Rating is simply the (negative) average hitpoint outcome
                local av_hp = unit.hitpoints - total_damage
                if (av_hp < 0) then av_hp = 0 end

                local rating = - av_hp
                --print(i, av_hp, ' -->', rating)

                if (rating > max_rating) then
                    max_rating = rating
                    def_stats.average_hp = av_hp

                    -- Also add the minimum possible HP outcome to the table
                    local min_hp = unit.hitpoints - max_damage
                    if (min_hp < 0) then min_hp = 0 end
                    def_stats.min_hp = min_hp
                end
            else  -- Full calculation of combo counter attack stats
                local atts, dsts = {}, {}
                for src,dst in pairs(counter_attack) do
                    table.insert(atts, wesnoth.get_unit(math.floor(src / 1000), src % 1000))
                    table.insert(dsts, { math.floor(dst / 1000), dst % 1000 } )
                end

                local combo_att_stats, combo_def_stats, sorted_atts, sorted_dsts, rating, def_rating, att_rating =
                    BC.attack_combo_stats(atts, dsts, unit, grunt_rush_FLS1.data.cache, cache_this_move)
                def_stats = combo_def_stats
                combo_def_stats.rating = rating
                combo_def_stats.def_rating = def_rating
                combo_def_stats.att_rating = att_rating

                -- Add min_hp field to worst_def_stats
                local min_hp = 0
                for hp = 0,unit.hitpoints do
                    if combo_def_stats.hp_chance[hp] and (combo_def_stats.hp_chance[hp] > 0) then
                        min_hp = hp
                        break
                    end
                end

                def_stats.min_hp = min_hp
            end

            unit.x, unit.y = old_x, old_y
            wesnoth.put_unit(unit)

            --print_time('  End calc_counter_attack', unit.id, hex[1], hex[2])

            return def_stats
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

        function grunt_rush_FLS1:eval_grab_villages(units, villages, enemies, cfg, cache_this_move)
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

                        local max_hp_chance_zero = 0.5
                        local counter_stats = grunt_rush_FLS1:calc_counter_attack(u, { v[1], v[2] },
                            { stop_eval_hp_chance_zero = max_hp_chance_zero },
                            cache_this_move
                        )
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

        function grunt_rush_FLS1:zone_action_villages(units, enemies, zone_map, cfg, cache_this_move)
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

                local action = grunt_rush_FLS1:eval_grab_villages(village_grabbers, villages, enemies, cfg, cache_this_move)
                if action then
                    action.action = cfg.zone_id .. ': ' .. 'grab villages'
                    return action
                end
            end
        end

            --print_time(cfg.zone_id, 'attack')
        function grunt_rush_FLS1:zone_action_attack(units, enemies, zone, zone_map, cfg, cache_this_move)

            -- Attackers include the leader but only if he is on his
            -- keep, in order to prevent him from wandering off
            local attackers = {}
            local leader_map = {}
            for i,u in ipairs(units) do
                if u.canrecruit then
                    leader_map[u.x * 1000 + u.y] = true
                    if wesnoth.get_terrain_info(wesnoth.get_terrain(u.x, u.y)).keep then
                        table.insert(attackers, u)
                    end
                else
                    table.insert(attackers, u)
                end
            end
            --print(#attackers)

            local targets = {}
            -- If cfg.attack.use_enemies_in_reach is set, we use all enemies that
            -- can get to the zone (Note: this should only be used for small zones,
            -- such as that consisting only of the AI leader position, otherwise it
            -- might be very slow!!!)
            if cfg.attack and cfg.attack.use_enemies_in_reach then
                for i,e in ipairs(enemies) do
                    for j,hex in ipairs(zone) do
                        local path, cost = wesnoth.find_path(e, hex[1], hex[2], { ignore_units = true })
                        local movecost = wesnoth.unit_movement_cost(e, wesnoth.get_terrain(hex[1], hex[2]))
                        if (cost <= e.max_moves + movecost) then
                            table.insert(targets, e)
                            break  -- so that the same unit does not get added several times
                        end
                    end
                end
            -- Otherwise use all units inside the zone
            else
                for i,e in ipairs(enemies) do
                    if zone_map:get(e.x, e.y) then
                        table.insert(targets, e)
                    end
                end
            end
            --print_time('#enemies, #targets', #enemies, #targets)

            -- We first see if there's a trapping attack possible
            --print_time('    trapping attack eval')
            local action = grunt_rush_FLS1:best_trapping_attack_opposite(attackers, targets, cfg, cache_this_move)
            if action then return action end

            -- Then we check for poison attacks
            --print_time('    poison attack eval')
            local poisoners, poisoner_map = {}, LS.create()
            for i,a in ipairs(attackers) do
                local is_poisoner = AH.has_weapon_special(a, 'poison')
                if is_poisoner then
                    table.insert(poisoners, a)
                    poisoner_map:insert(a.x, a.y, true)
                end
            end
            --print_time('#poisoners', #poisoners)

            if (poisoners[1]) then
                --local action = grunt_rush_FLS1:spread_poison_eval(poisoners, targets, cfg)
                if action then return action end
            end

            -- Also want an 'attackers' map, indexed by position (for speed reasons)
            --print_time('    standard attack eval')
            local attacker_map = {}
            for i,u in ipairs(attackers) do attacker_map[u.x * 1000 + u.y] = u end

            local max_rating, best_attackers, best_dsts, best_enemy = -9e99, {}, {}, {}
            local counter_table = {}  -- Counter-attacks are very expensive, store to avoid duplication

            for i,e in ipairs(targets) do

                -- How much more valuable do we consider the enemy units than out own
                local enemy_worth = 1.33 -- we are Northerners, after all
                if cfg.attack and cfg.attack.enemy_worth then
                    enemy_worth = cfg.attack.enemy_worth
                end
                if e.canrecruit then enemy_worth = enemy_worth * 2 end

                --print_time('\n', i, e.id, enemy_worth)
                local tmp_attack_combos = AH.get_attack_combos(attackers, e, { include_occupied = true })
                --DBG.dbms(tmp_attack_combos)
                --print_time('#tmp_attack_combos', #tmp_attack_combos)

                -- Keep only attack combos with the maximum number of attacks
                -- of non-leader units (or more)
                local max_atts, counts = 0, {}
                for j,combo in ipairs(tmp_attack_combos) do
                    local count, uses_leader = 0, false
                    for dst,src in pairs(combo) do
                        if leader_map[src] then uses_leader = true end
                        count = count + 1
                    end
                    counts[j] = count
                    if (not uses_leader) and (count > max_atts) then max_atts = count end
                end
                local attack_combos = {}
                for j,count in ipairs(counts) do
                    --if (count >= max_atts) then
                        table.insert(attack_combos, tmp_attack_combos[j])
                    --end
                end
                --print_time('#attack_combos', #attack_combos)

                local enemy_on_village = wesnoth.get_terrain_info(wesnoth.get_terrain(e.x, e.y)).village
                local enemy_cost = wesnoth.unit_types[e.type].cost

                for j,combo in ipairs(attack_combos) do
                    --print_time('combo ' .. j)
                    -- attackers and dsts arrays for stats calculation
                    local atts, dsts = {}, {}
                    for dst,src in pairs(combo) do
                        table.insert(atts, attacker_map[src])
                        table.insert(dsts, { math.floor(dst / 1000), dst % 1000 } )
                    end

                    local combo_att_stats, combo_def_stats, sorted_atts, sorted_dsts, rating, def_rating, att_rating =
                        BC.attack_combo_stats(atts, dsts, e, grunt_rush_FLS1.data.cache, cache_this_move)
                    --DBG.dbms(combo_def_stats)
                    print_time('   ratings:', rating, def_rating, att_rating)

                    -- Here, def_rating is the "gold amount" of the combined damage done to enemy (positive number)
                    -- att_rating is the combined damage received in return (negative number)

                    -- Don't attack if CTD (chance to die) is too high for any of the attackers
                    -- which means 30% CTD for normal units and 0% for leader
                    local do_attack = true
                    local MP_left = false
                    for k,att_stats in ipairs(combo_att_stats) do
                        if (not sorted_atts[k].canrecruit) then
                            if (att_stats.hp_chance[0] > 0.3) then
                                do_attack = false
                                break
                            end
                        else
                            if (att_stats.hp_chance[0] > 0.0) or (att_stats.slowed > 0.0) or (att_stats.poisoned > 0.0) then
                                do_attack = false
                                break
                            end
                        end
                        -- Checking for counter attacks (below) only makes sense
                        -- if at least one of the units can move away
                        -- TODO: there are some exceptions from this rule - add that in later
                        if (sorted_atts[k].moves > 0) then MP_left = true end
                    end

                    -- Check potential counter attack outcome
                    if do_attack and MP_left then
                        --print_time('\nChecking counter attack on', i, e.id, enemy_worth)

                        -- We first need to move all units into place, as the counter attack threat
                        -- should be calculated for that formation as a whole
                        -- For this to work in all situations, it needs to be done in stages,
                        -- as there might be units in the way, which
                        -- could be the attackers themselves, but on different hexes
                        local tmp_data = {}

                        -- First, extract attacker units from the map
                        for k,a in ipairs(sorted_atts) do
                            -- Take MP away from unit, as the counter attack calculation
                            -- takes all units with MP left off the map
                            tmp_data[k] = { old_moves = a.moves }
                            a.moves = 0

                            -- Then save its current position and extract it from the map
                            tmp_data[k].org_hex = { a.x, a.y }
                            wesnoth.extract_unit(a)
                        end

                        -- Second, take any remaining units in the way off the map
                        -- and put the attacker units into the position
                        for k,a in ipairs(sorted_atts) do
                            -- Coordinates of hex from which unit #k would attack
                            local x, y = sorted_dsts[k][1], sorted_dsts[k][2]

                            tmp_data[k].unit_in_way = wesnoth.get_unit(x, y)
                            if tmp_data[k].unit_in_way then
                                wesnoth.extract_unit(tmp_data[k].unit_in_way)
                            end

                            wesnoth.put_unit(x, y, a)
                        end

                        for k,a in ipairs(sorted_atts) do
                            -- Add max damages from this turn and counter-attack
                            local min_hp = 0
                            for hp = 0,a.hitpoints do
                                if combo_att_stats[k].hp_chance[hp] and (combo_att_stats[k].hp_chance[hp] > 0) then
                                    min_hp = hp
                                    break
                                end
                            end

                            -- For normal units, we want a 50% chance to survive the counter attack
                            -- and an average HP outcome of >= 5
                            local average_damage = a.hitpoints - combo_att_stats[k].average_hp
                            local min_average_hp = average_damage
                            local min_min_hp = -1
                            local max_hp_chance_zero = 0.5

                            -- By contrast, for the side leader, the chance to die must be zero
                            -- meaning minimum outcome > 0
                            local max_damage = a.hitpoints - min_hp
                            if a.canrecruit then
                                min_min_hp = max_damage
                                max_hp_chance_zero = 0.0
                            end

                            -- Now calculate the counter attack outcome
                            local x, y = sorted_dsts[k][1], sorted_dsts[k][2]
                            local att_ind = tmp_data[k].org_hex[1], tmp_data[k].org_hex[2]
                            local dst_ind = x * 1000 + y
                            if (not counter_table[att_ind]) then counter_table[att_ind] = {} end
                            if (not counter_table[att_ind][dst_ind]) then
                                --print_time('Calculating new counter-attack combination')
                                -- We can cut off the counter attack calculation when its minimum HP
                                -- reach max_damage defined above, as the total possible damage will
                                -- then be able to kill the leader
                                local counter_stats = grunt_rush_FLS1:calc_counter_attack(a, { x, y },
                                    --{ stop_eval_average_hp = min_average_hp,
                                    --  stop_eval_min_hp = min_min_hp,
                                    --  stop_eval_hp_chance_zero = max_hp_chance_zero
                                    --},
                                    {},
                                    cache_this_move
                                )
                                counter_table[att_ind][dst_ind] = {
                                    min_hp = counter_stats.min_hp,
                                    counter_stats = counter_stats,
                                    rating = counter_stats.rating,
                                    def_rating = counter_stats.def_rating,
                                    att_rating = counter_stats.att_rating,
                                }
                            else
                                --print_time('Counter-attack combo already calculated. Re-using.')
                            end

                            --print('counter attack rating', counter_table[att_ind][dst_ind].rating, counter_table[att_ind][dst_ind].def_rating, counter_table[att_ind][dst_ind].att_rating)
                            --print_time('  done')
                            local counter_min_hp = counter_table[att_ind][dst_ind].min_hp
                            local counter_stats = counter_table[att_ind][dst_ind].counter_stats
                            local counter_average_hp = counter_stats.average_hp
                            --DBG.dbms(counter_table[att_ind][dst_ind])
                            --print_time('counter_average_hp, counter_min_hp, counter_CTD', counter_average_hp, counter_min_hp, counter_stats.hp_chance[0])

                            -- "Damage cost" for attacker
                            -- This should include the damage from the current attack
                            -- (only done approximately for speed reasons)
                            local damage = a.hitpoints - counter_stats.average_hp + average_damage
                            -- Count poisoned as additional 8 HP damage times probability of being poisoned
                            if (counter_stats.poisoned ~= 0) then
                                damage = damage + 8 * (counter_stats.poisoned - counter_stats.hp_chance[0])
                            end
                            -- Count slowed as additional 6 HP damage times probability of being slowed
                            if (counter_stats.slowed ~= 0) then
                                damage = damage + 6 * (counter_stats.slowed - counter_stats.hp_chance[0])
                            end

                            -- Fraction damage (= fractional value of the unit)
                            local value_fraction = damage / a.max_hitpoints
                            -- Additionally, add the chance to die and experience
                            --local ctd = counter_stats.hp_chance[0]
                            local ctd = 0
                            for hp,prob in pairs(counter_stats.hp_chance) do
                                if (hp <= average_damage) then ctd = ctd + prob end
                            end
                            value_fraction = value_fraction + ctd
                            value_fraction = value_fraction + a.experience / a.max_experience

                            -- Convert this into a cost in gold
                            --print('damage, ctd, value_fraction', damage, ctd, value_fraction)
                            local damage_cost_a = value_fraction * wesnoth.unit_types[a.type].cost

                            -- "Damage cost" for enemy

                            local damage = e.hitpoints - combo_def_stats.average_hp
                            -- Count poisoned as additional 8 HP damage times probability of being poisoned
                            if (combo_def_stats.poisoned ~= 0) then
                                damage = damage + 8 * (combo_def_stats.poisoned - combo_def_stats.hp_chance[0])
                            end
                            -- Count slowed as additional 6 HP damage times probability of being slowed
                            if (combo_def_stats.slowed ~= 0) then
                                damage = damage + 6 * (combo_def_stats.slowed - combo_def_stats.hp_chance[0])
                            end

                            -- Fraction damage (= fractional value of the unit)
                            local value_fraction = damage / e.max_hitpoints

                            -- Additionally, add the chance to die and experience
                            value_fraction = value_fraction + combo_def_stats.hp_chance[0]
                            value_fraction = value_fraction + e.experience / e.max_experience

                            -- Convert this into a cost in gold
                            local damage_cost_e = value_fraction * wesnoth.unit_types[e.type].cost
                            --print_time('  --> damage cost attacker vs. enemy', damage_cost_a, damage_cost_e)

                            -- If there's a chance of the leader getting poisoned or slowed, don't do it
                            -- Also, if the stats would go too low
                            if a.canrecruit then
                                if (counter_stats.slowed > 0.0) or (counter_stats.poisoned > 0.0) then
                                    --print('Leader slowed or poisoned', counter_stats.slowed, counter_stats.poisoned)
                                    do_attack = false
                                    break
                                end

                                -- Add damage from attack and counter attack
                                local min_outcome = counter_min_hp - max_damage
                                --print('Leader: min_outcome, counter_min_hp, max_damage', min_outcome, counter_min_hp, max_damage)

                                if (min_outcome <= 0) then
                                    do_attack = false
                                    break
                                end
                            -- Or for normal units, use the somewhat looser criteria
                            else  -- Or for normal units, use the somewhat looser criteria
                                -- Add damage from attack and counter attack
                                local av_outcome =  counter_average_hp - average_damage
                                --print('Non-leader: av_outcome, counter_average_hp, average_damage', av_outcome, counter_average_hp, average_damage)
                                --print('   damage_cost_a, damage_cost_e:', damage_cost_a, damage_cost_e, counter_stats.hp_chance[0])
                                --if (av_outcome <= 5) or (counter_stats.hp_chance[0] >= max_hp_chance_zero) then
                                    -- Use the "damage cost"
                                    -- This is still experimental for now, so I'll leave the rest of the code here, commented out
                                    if (damage_cost_a > damage_cost_e * enemy_worth ) then
                                        do_attack = false
                                        break
                                    end
                                --end
                            end
                        end

                        -- Now put the units back out there
                        -- We first need to extract the attacker units again, then
                        -- put both units in way and attackers back out there

                        --DBG.dbms(tmp_data)
                        for k,a in ipairs(sorted_atts) do
                            wesnoth.extract_unit(a)
                        end

                        for k,a in ipairs(sorted_atts) do
                            -- Coordinates of hex from which unit #k would attack
                            local x, y = sorted_dsts[k][1], sorted_dsts[k][2]

                            if tmp_data[k].unit_in_way then
                                wesnoth.put_unit(x, y, tmp_data[k].unit_in_way)
                            end

                            wesnoth.put_unit(tmp_data[k].org_hex[1], tmp_data[k].org_hex[2], a)

                            a.moves = tmp_data[k].old_moves
                        end
                    end

                    -- Discourage use of poisoners in attacks that may result in kill
                    if do_attack then
                        if (combo_def_stats.hp_chance[0] > 0) then
                            local number_poisoners = 0
                            for i,a in ipairs(sorted_atts) do
                                if poisoner_map:get(a.x, a.y) then
                                    number_poisoners = number_poisoners + 1
                                    rating = rating - 100
                                end
                            end
                            -- Really discourage the use of several poisoners
                            if (number_poisoners > 1) then rating = rating - 1000 end
                        end
                    end

                    if do_attack then
                        --print_time(' -----------------------> rating', rating)
                        if (rating > max_rating) then
                            max_rating, best_attackers, best_dsts, best_enemy = rating, sorted_atts, sorted_dsts, e
                        end
                    end
                end
            end
            --print_time('max_rating ', max_rating)

            if (max_rating > -9e99) then
                -- Only execute the first of these attacks
                local action = { units = {}, dsts = {}, enemy = best_enemy }
                --action.units[1], action.dsts[1] = best_attackers[1], best_dsts[1]
                action.units, action.dsts = best_attackers, best_dsts
                action.action = cfg.zone_id .. ': ' .. 'attack'
                return action
            end

            return nil
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

        function grunt_rush_FLS1:high_priority_attack(unit, cfg, cache_this_move)
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

                    local rating, _, _, att_stats, def_stats =
                        BC.attack_rating(unit, target, { attack.dst.x, attack.dst.y }, {}, grunt_rush_FLS1.data.cache, cache_this_move)
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

        function grunt_rush_FLS1:get_zone_action(cfg, cache_this_move)
            -- Find the best action to do in the zone described in 'cfg'
            -- This is all done together in one function, rather than in separate CAs so that
            --  1. Zones get done one at a time (rather than one CA at a time)
            --  2. Relative scoring of different types of moves is possible

            cfg = cfg or {}

            -- First, set up the general filters and tables, to be used by all actions

            -- Unit filter:
            -- This includes the leader. Needs to be excluded specifically if he shouldn't take part in an action
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



            if (not zone_units[1]) and (not zone_units_attacks[1]) then return end

            local all_zone_units = {}
            for i,u in ipairs(zone_units) do table.insert(all_zone_units, u) end
            for i,u in ipairs(zone_units_noMP) do table.insert(all_zone_units, u) end

            -- Then get all the enemies (this needs to be all of them, to get the HP ratio)
            local enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }
            --print_time('#zone_units, #enemies', #zone_units, #enemies)

            -- Get all the hexes in the zone
            local zone = wesnoth.get_locations(cfg.zone_filter)
            local zone_map = LS.of_pairs(zone)

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
                    village_action = grunt_rush_FLS1:zone_action_villages(zone_units, enemies, zone_map, cfg, cache_this_move)
                    if village_action and (village_action.rating > 100) then
                        --print_time(village_action.action)
                        local attack_action = grunt_rush_FLS1:high_priority_attack(village_action.units[1], cfg, cache_this_move)
                        return attack_action or village_action
                    end
                end
            end

            -- **** Attack evaluation ****
            --print_time('  ' .. cfg.zone_id .. ': attack eval')
            if (not cfg.do_action) or cfg.do_action.attack then
                if (not cfg.skip_action) or (not cfg.skip_action.attack) then
                    local action = grunt_rush_FLS1:zone_action_attack(zone_units_attacks, enemies, zone, zone_map, cfg, cache_this_move)
                    if action then
                        --print(action.action)
                        return action
                    end
                end
            end

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

            -- Unlike self.data.cache, this is a local variable that
            -- gets reset (and needs to be reset) after each move
            local cache_this_move = {}

            -- Skip this if AI is much stronger than enemy
            if grunt_rush_FLS1:full_offensive() then
                AH.done_eval_messages(start_time, ca_name)
                return 0
            end

            local cfgs = grunt_rush_FLS1:get_zone_cfgs()

            for i_c,cfg in ipairs(cfgs) do
                --print_time('zone_control: ', cfg.zone_id)
                local zone_action = grunt_rush_FLS1:get_zone_action(cfg, cache_this_move)

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
            while grunt_rush_FLS1.data.zone_action.units and (table.maxn(grunt_rush_FLS1.data.zone_action.units) > 0) do
                local next_unit_ind = 1

                -- If this is an attack combo, reorder units to give maximum XP to unit closest to advancing
                if grunt_rush_FLS1.data.zone_action.enemy and grunt_rush_FLS1.data.zone_action.units[2] then
                    -- Only do this if CTK for overall attack combo is > 0
                    local _, combo_def_stats = BC.attack_combo_stats(
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
                            { dst = grunt_rush_FLS1.data.zone_action.dsts[best_ind] },
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

            cache_this_move = {}

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
                if poison_attack then
                    local min_average_hp = 5
                    local max_hp_chance_zero = 0.3
                    local counter_stats = grunt_rush_FLS1:calc_counter_attack(attacker, { a.dst.x, a.dst.y },
                        {
                            stop_eval_average_hp = min_average_hp,
                            stop_eval_hp_chance_zero = max_hp_chance_zero
                        },
                        cache_this_move
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

            local cache_this_move = {}

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
                                cache_this_move
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
