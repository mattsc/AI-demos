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

            if (not recalc) and grunt_rush_FLS1.data.zone_cfgs then
                return grunt_rush_FLS1.data.zone_cfgs
            end

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
                attack = { use_enemies_in_reach = true, enemy_worth = 1.5 }
            }

            local cfg_center = {
                zone_id = 'center',
                zone_filter = { x = '15-24', y = '1-16' },
                unit_filter = { x = '16-25,15-22', y = '1-13,14-19' },
                skip_action = { retreat_injured_unsafe = true },
                hold = { x = 20, y = 9, dx = 0, dy = 1, hp_ratio = 0.67 },
                retreat_villages = { { 18, 9 }, { 24, 7 }, { 22, 2 } },
                villages = { units_per_village = 0 }
            }

            local cfg_left = {
                zone_id = 'left',
                zone_filter = { x = '4-14', y = '1-15' },
                unit_filter = { x = '1-15,16-20', y = '1-15,1-6' },
                skip_action = { retreat_injured_unsafe = true },
                hold = { x = 11, y = 9, dx = 0, dy = 1, hp_ratio = 1.0 },
                secure = { x = 11, y = 9, moves_away = 2, min_units = 1 },
                retreat_villages = { { 11, 9 }, { 8, 5 }, { 12, 5 }, { 12, 2 } },
                villages = { hold_threatened = true }
            }

            local cfg_right = {
                zone_id = 'right',
                zone_filter = { x = '24-34', y = '1-17' },
                unit_filter = { x = '16-99,22-99', y = '1-11,12-25' },
                enemy_filter = { x = '24-34', y = '1-23' },
                skip_action = { retreat_injured_unsafe = true },
                hold = { x = 27, y = 11, dx = 0, dy = 1, min_dist = -4 },
                retreat_villages = { { 24, 7 }, { 28, 5 } }
            }

            local cfg_enemy_leader = {
                zone_id = 'enemy_leader',
                zone_filter = { x = '1-' .. width , y = '1-' .. height },
                unit_filter = { x = '1-' .. width , y = '1-' .. height },
                hold = { },
            }

            -- This way it will be easy to change the priorities on the fly later:
            cfgs = {}
            table.insert(cfgs, cfg_full_map)
            table.insert(cfgs, cfg_leader_threat)
            table.insert(cfgs, cfg_left)
            table.insert(cfgs, cfg_center)
            table.insert(cfgs, cfg_right)
            table.insert(cfgs, cfg_enemy_leader)

            -- The following is placeholder code for later, when we might want to
            -- set up the priority of the zones dynamically
            -- Now find how many enemies can get to each zone
            --local my_units = AH.get_live_units { side = wesnoth.current.side }
            --local enemies = AH.get_live_units {
            --    { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            --}
            --local attack_map = AH.attack_map(my_units)
            --local attack_map_hp = AH.attack_map(my_units, { return_value = 'hitpoints' })
            --local enemy_attack_map = AH.attack_map(enemies, { moves = "max" })
            --local enemy_attack_map_hp = AH.attack_map(enemies, { moves = "max", return_value = 'hitpoints' })

            -- Find how many enemies threaten each of the hold zones
            --local enemy_num, enemy_hp = {}, {}
            --for i_c,c in ipairs(cfgs) do
            --    enemy_num[i_c], enemy_hp[i_c] = 0, 0
            --    for x = c.zone.x_min,c.zone.x_max do
            --        for y = c.zone.y_min,c.zone.y_max do
            --            local en = enemy_attack_map:get(x, y) or 0
            --            if (en > enemy_num[i_c]) then enemy_num[i_c] = en end
            --            local hp = enemy_attack_map_hp:get(x, y) or 0
            --            if (hp > enemy_hp[i_c]) then enemy_hp[i_c] = hp end
            --        end
            --    end
            --    --print('enemy threat:', i_c, enemy_num[i_c], enemy_hp[i_c])
            --end

            -- Also find how many enemies are already present in zone
            --local present_enemies = {}
            --for i_c,c in ipairs(cfgs) do
            --    present_enemies[i_c] = 0
            --    for j,e in ipairs(enemies) do
            --        if (e.x >= c.zone.x_min) and (e.x <= c.zone.x_max) and
            --            (e.y >= c.zone.y_min) and (e.y <= c.zone.y_max)
            --        then
            --            present_enemies[i_c] = present_enemies[i_c] + 1
            --        end
            --    end
            --    --print('present enemies:', i_c, present_enemies[i_c])
            --end

            -- Now set this up as global variable
            grunt_rush_FLS1.data.zone_cfgs = cfgs

            return grunt_rush_FLS1.data.zone_cfgs
        end

        function grunt_rush_FLS1:hp_ratio(my_units, enemies)
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
            for i,u in ipairs(enemies) do enemy_hp = enemy_hp + u.hitpoints end

            --print('HP ratio:', my_hp / (enemy_hp + 1e-6)) -- to avoid div by 0
            return my_hp / (enemy_hp + 1e-6), my_hp, enemy_hp
        end

        function grunt_rush_FLS1:full_offensive()
            -- Returns true if the conditions to go on all-out offensive are met
            if (grunt_rush_FLS1:hp_ratio() > 1.5) and (wesnoth.current.turn >= 16) then return true end
            if (grunt_rush_FLS1:hp_ratio() > 2.0) and (wesnoth.current.turn >= 3) then return true end
            return false
        end

        function grunt_rush_FLS1:best_trapping_attack_opposite(units_org, enemies_org, cfg)
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
            local cache_this_move = {}  -- same reason
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
                        rating, attackers, dsts, combo_att_stats, combo_def_stats = BC.attack_combo_stats(attackers, dsts, e, grunt_rush_FLS1.data.cache, cache_this_move)
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

            local corridor_enemies = enemies
            if cfg.enemy_filter then
                --print(cfg.zone_id, ' - getting only enemies in filter')
                corridor_enemies = AH.get_live_units { { "and", cfg.enemy_filter },
                    { "filter_side", {{"enemy_of", { side = wesnoth.current.side } }} }
                }
            end
            --print('#enemies, #corridor_enemies', #enemies, #corridor_enemies)

            local enemy_leader
            local enemy_attack_maps = {}
            local enemy_attack_map = LS.create()
            for i,e in ipairs(enemies) do
                if e.canrecruit then enemy_leader = e end

                local attack_map = BC.get_attack_map_unit(e)
                table.insert(enemy_attack_maps, attack_map)
                enemy_attack_map:union_merge(attack_map.units, function(x, y, v1, v2) return (v1 or 0) + v2 end)
            end

            local terrain_weight = 0.15

            -- Now move units into holding positions
            -- The while loop doesn't do anything for now, placeholder for later
            while holders[1] do
                -- First, find where the units that have already moved are
                -- This needs to be done after every move
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

                local units_noMP_map = LS.create()
                for i,u in ipairs(units_noMP) do
                    units_noMP_map:insert(u.x, u.y, true)
                end

                -- Normalized direction "vector"
                local dx, dy = cfg.hold.dx, cfg.hold.dy
                if (dx and dy) then
                    local r = math.sqrt(dx*dx + dy*dy)
                    dx, dy = dx / r, dy / r
                else
                    dx = nil  -- just in case dx exists and dy does not
                    -- existence of dx is used as criterion below
                end

                -- Minimum distance from reference hex for zone holding
                local min_dist = cfg.hold.min_dist or 0

                if (not dx) then
                    min_dist = -9e99
                end

                -- Determine where to set up the line for holding the zone
                local zone = wesnoth.get_locations(cfg.zone_filter)

                --rating_map = LS.create()
                --local hold_dist, max_rating = -9e99, -9e99
                --for i,hex in ipairs(zone) do
                --    local x, y = hex[1], hex[2]

                --    local adv_dist
                --    if dx then
                --         -- Distance in direction of (dx, dy) and perpendicular to it
                --        adv_dist = (x - cfg.hold.x) * dx + (y - cfg.hold.y) * dy
                --    else
                --        adv_dist = - H.distance_between(x, y, enemy_leader.x, enemy_leader.y)
                --    end

                --    if (adv_dist >= min_dist) then
                --        local perp_dist
                --        if dx then
                --            perp_dist = (x - cfg.hold.x) * dy + (y - cfg.hold.y) * dx
                --        else
                --            perp_dist = 0
                --        end

                --        local rating = adv_dist

                --        if (math.abs(perp_dist) <= max_perp_dist) then
                --            rating = rating - math.abs(perp_dist) / 10.

                --            local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(x, y)).village
                --            if is_village then
                --                rating = rating + 1.11
                --            end

                --            if (rating > max_rating) then
                --                max_rating, hold_dist = rating, adv_dist
                --            end

                --            rating_map:insert(x, y, rating)
                --        end
                --    end
                --end

                -- hold_dist can never get smaller during a turn
                --print('hold_dist orig :', cfg.zone_id, hold_dist)
                --if grunt_rush_FLS1.data[cfg.zone_id] and grunt_rush_FLS1.data[cfg.zone_id].hold_dist then
                --    if (hold_dist < grunt_rush_FLS1.data[cfg.zone_id].hold_dist) then
                --        hold_dist = grunt_rush_FLS1.data[cfg.zone_id].hold_dist
                --    else
                --        grunt_rush_FLS1.data[cfg.zone_id].hold_dist = hold_dist
                --    end
                --else
                --    if (not grunt_rush_FLS1.data[cfg.zone_id]) then
                --        grunt_rush_FLS1.data[cfg.zone_id] = {}
                --    end
                --    grunt_rush_FLS1.data[cfg.zone_id].hold_dist = hold_dist
                --end
                --print('hold_dist new  :', cfg.zone_id, hold_dist)
                --AH.put_labels(rating_map)
                --W.message { speaker = 'narrator', message = 'Hold zone ' .. cfg.zone_id .. ': hold_dist rating map' }

                -- If not valid hold position was found
                --if (hold_dist == -9e99) then return end

                -- Calculate enemy "corridors" toward AI leader
                local leader = wesnoth.get_units{ side = 1, canrecruit = 'yes' }[1]

                -- Take leader and units with MP off the map
                -- Leader needs to be taken off whether he has MP or not, so done spearately
                for i,u in ipairs(units_MP) do
                    if (not u.canrecruit) then wesnoth.extract_unit(u) end
                end
                wesnoth.extract_unit(leader)

                corridor_map = LS.create()
                path_map = LS.create()

                local factor_path = 0.

                for i,e in ipairs(corridor_enemies) do
                    local e_copy = wesnoth.copy_unit(e)

                    local path, cost = wesnoth.find_path(e_copy, leader.x, leader.y, { ignore_units = false } )
                    local movecost_current = wesnoth.unit_movement_cost(e_copy, wesnoth.get_terrain(e.x, e.y))
                    local multiplier = 1. / math.floor( cost / e.max_moves)

                    factor_path = factor_path + multiplier

                    for i,hex in ipairs(zone) do
                        local x, y = hex[1], hex[2]

                        local movecost = wesnoth.unit_movement_cost(e, wesnoth.get_terrain(x, y))
                        if (movecost <= e.max_moves) then
                            e_copy.x, e_copy.y = x, y

                            local p1nzoc, c1nzoc = wesnoth.find_path(e_copy, leader.x, leader.y, { ignore_units = true } )
                            --local p2nzoc, c2nzoc = wesnoth.find_path(e_copy, e.x, e.y, { ignore_units = true } )
                            local p1, c1 = wesnoth.find_path(e_copy, leader.x, leader.y, { ignore_units = false } )
                            local p2, c2 = wesnoth.find_path(e_copy, e.x, e.y, { ignore_units = false } )

                            local movecost = wesnoth.unit_movement_cost(e_copy, wesnoth.get_terrain(x,y))

                            local value = c1 + c2 - cost + movecost - 1 - (movecost_current - 1)

                            if (value <= 2) then
                                corridor_map:insert(x, y, (corridor_map:get(x,y) or 0) + 1 * multiplier)
                            else
                                corridor_map:insert(x, y, (corridor_map:get(x,y) or 0) + 1. / value^2 * multiplier)
                            end

                            path_map:insert(x, y, (path_map:get(x, y) or 0) + c1nzoc * multiplier)
                        else
                            corridor_map:insert(x, y, (corridor_map:get(x, y) or 0))
                            path_map:insert(x, y, (path_map:get(x, y) or 0))
                        end
                    end
                    e_copy = nil
                end

                wesnoth.put_unit(leader)
                for i,u in ipairs(units_MP) do
                    if (not u.canrecruit) then wesnoth.put_unit(u) end
                end

                -- Normalize the rating map so that maximum is 10  (arbitrary value)
                local max_rating = -9e99
                corridor_map:iter( function (x, y, v)
                    if (v > max_rating) then max_rating = v end
                end)
                local factor = 10. / max_rating
                --print("factor", factor, factor_path)
                corridor_map:iter( function (x, y, v)
                    corridor_map:insert(x, y, v * factor)
                end)

                -- Normalize so that "step size" along the main corridor is approximately 1
                factor_path = 1. / factor_path  -- just for consistency
                path_map:iter( function (x, y, v)
                    path_map:insert(x, y, v * factor_path)
                end)

                -- In case there are no enemies in the zone yet:
                if (#corridor_enemies == 0) then
                    for i,hex in ipairs(zone) do
                        local x, y = hex[1], hex[2]
                        corridor_map:insert(x, y, 10 - math.sqrt(math.abs(x - cfg.hold.x)))
                        path_map:insert(x, y, y)
                    end
                end

                local show_debug = false
                if show_debug then
                    AH.put_labels(corridor_map)
                    W.message{ speaker = 'narrator', message = cfg.zone_id .. ': corridor_map' }
                    AH.put_labels(path_map)
                    W.message{ speaker = 'narrator', message = cfg.zone_id .. ': path_map' }
                end

                -- First calculate a unit independent rating map
                rating_map, defense_rating_map = LS.create(), LS.create()
                for i,hex in ipairs(zone) do
                    local x, y = hex[1], hex[2]

                    -- Distance in direction of (dx, dy) and perpendicular to it
                    --local adv_dist, perp_dist
                    --if dx then
                    --    adv_dist = (x - cfg.hold.x) * dx + (y - cfg.hold.y) * dy
                    --    perp_dist = (x - cfg.hold.x) * dy + (y - cfg.hold.y) * dx
                    --else
                    --    adv_dist = - H.distance_between(x, y, enemy_leader.x, enemy_leader.y)
                    --    perp_dist = 0
                    --end

                    --if (adv_dist >= min_dist - 1) or (not dx) then
                        local rating = 0

                        -- A hex forward is worth one "point"
                        -- This is the base rating that everything else is compared with
                        --rating = rating - math.abs(adv_dist) / 2.
                        -- Also want to be close to center of zone, but much less importantly
                        --rating = rating - (math.abs(perp_dist) / 4.) ^ 2.

                        rating = rating + (corridor_map:get(x,y) or 0)
                        rating = rating + (path_map:get(x,y) or 0) / 2.

                        rating_map:insert(x, y, rating)

                        -- All the rest only matters if the enemy can attack the hex
                        if enemy_attack_map:get(x, y) then
                            local defense_rating = 0

                            -- Small bonus if this is on a village
                            -- Village will also get bonus from defense rating below
                            local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(x, y)).village
                            if is_village then
                                defense_rating = defense_rating + 1.9
                            end

                            -- Add penalty if this is a location next to an unoccupied village
                            for xa, ya in H.adjacent_tiles(x, y) do
                                local is_adj_village = wesnoth.get_terrain_info(wesnoth.get_terrain(xa, ya)).village
                                -- If there is an adjacent village and the enemy can get to that village
                                if is_adj_village then
                                    local unit_on_village = wesnoth.get_unit(xa, ya)
                                    if (not unit_on_village) or (unit_on_village.moves > 0) then
                                        defense_rating = defense_rating - 1.9
                                    end
                                end
                            end

                            -- We also, ideally, want to be 3 hexes from the closest unit that has
                            -- already moved, so as to ZOC the zone,
                            -- but only (approximately) perpendicular to the corridor direction
                            local min_dist = 9999
                            local zoc_rating = 0
                            for j,m in ipairs(units_noMP) do
                                --local ldx, ldy
                                --if dx then
                                --    ldx, ldy = dx, dy
                                --else
                                --    ldx, ldy = enemy_leader.x - x, enemy_leader.y - y
                                --    local r = math.sqrt(ldx*ldx + ldy*ldy)
                                --    ldx, ldy = ldx / r, ldy / r
                                --end
                                --local parl = math.abs((x - m.x) * ldx + (y - m.y) * ldy)
                                --local perp = math.abs((x - m.x) * ldy + (y - m.y) * ldx)
                                --if (parl < 2) then
                                --    local dist = H.distance_between(x, y, m.x, m.y)
                                --    if (dist < min_dist) then min_dist = dist end
                                --end
                                local dist = H.distance_between(x, y, m.x, m.y)
                                if (dist < min_dist) then
                                    min_dist = dist
                                    local forw_dist = math.abs((path_map:get(x, y) or 2000) - (path_map:get(m.x, m.y) or 1000))
                                    zoc_rating = -1 * math.abs(min_dist - 2.5) + 2.5
                                    if (zoc_rating < 0) then zoc_rating = 0 end
                                    zoc_rating = zoc_rating * (3 - forw_dist) / 3.
                                    if (zoc_rating < 0) then zoc_rating = 0 end
                                end
                            end
                            --if (min_dist == 3) then defense_rating = defense_rating + 1.9 end
                            --if (min_dist == 2) then defense_rating = defense_rating + 0.9 end
                            --defense_rating = defense_rating + 3. / min_dist
                            defense_rating = defense_rating + zoc_rating

                            -- Add penalty for being too far behind the goal hex
                            -- TODO: generalize from north-south dependence
                            if cfg.hold and cfg.hold.y and (y < cfg.hold.y - 2) then
                                defense_rating = defense_rating - (cfg.hold.y - y) / 2.
                            end

                            -- Take terrain defense for enemies into account
                            -- This also prefers hexes that cannot be reached by the enemy
                            local enemy_defense, count = 0, 0
                            for xa, ya in H.adjacent_tiles(x, y) do
                                if (path_map:get(x,y) < (path_map:get(xa, ya) or 0)) then
                                    enemy_defense = enemy_defense + (enemy_defense_map:get(xa, ya) or 0)
                                    count = count + 1
                                end
                            end
                            if (count > 0) then enemy_defense = enemy_defense / count end
                            defense_rating = defense_rating - enemy_defense * 0.05

                            defense_rating_map:insert(x, y, defense_rating)
                        end
                    --end
                end

                if show_debug then
                    AH.put_labels(rating_map)
                    W.message { speaker = 'narrator', message = 'Hold zone: unit-independent rating map' }
                    AH.put_labels(defense_rating_map)
                    W.message { speaker = 'narrator', message = 'Hold zone: unit-independent defense_rating map' }
                end

                -- Now we go on to the unit-dependent rating part
                local max_rating, best_hex, best_unit = -9e99, {}, {}
                local max_defense_rating, best_defense_hex, best_defense_unit = -9e99, {}, {}
                for i,u in ipairs(holders) do
                    local reach = wesnoth.find_reach(u)
                    local reach_map = LS.create()
                    for i,r in ipairs(reach) do
                        if (not units_noMP_map:get(r[1], r[2])) then
                            reach_map:insert(r[1], r[2])
                        end
                    end

                    local max_rating_unit, best_hex_unit = -9e99, {}
                    local max_defense_rating_unit, best_defense_hex_unit = -9e99, {}
                    local defense_reach_map = LS.create()

                    reach_map:iter( function(x, y, v)
                        -- If this is inside the zone
                        if rating_map:get(x, y) then
                            local rating = rating_map:get(x, y)

                            -- Take strongest units first
                            rating = rating + u.hitpoints / 5.

                            --local cost = wesnoth.unit_types[u.type].cost
                            --local worth = cost * u.hitpoints / u.max_hitpoints
                            --local damage = ---- TODO ? ----
                            --print("id, cost, worth, damage:", u.id, cost, worth, damage)
                            --if (damage > worth) then
                            --    rating = rating - 1000
                            --end
                            reach_map:insert(x, y, rating)

                            if (rating > max_rating_unit) then
                                max_rating_unit, best_hex_unit = rating, { x, y }
                            end
                        else
                            reach_map:remove(x, y)
                        end

                        if defense_rating_map:get(x, y) then
                            local defense_rating = reach_map:get(x,y) + defense_rating_map:get(x, y)

                            -- Rating for the terrain
                            local defense = 100 - wesnoth.unit_defense(u, wesnoth.get_terrain(x, y))
                            defense_rating = defense_rating + defense * 0.15

                            -- Only include enemies that can reach this hex
                            local tmp_enemies = {}
                            for i,m in ipairs(enemy_attack_maps) do
                                if m.units:get(x,y) then
                                    table.insert(tmp_enemies, enemies[i])
                                end
                            end
                            -- und calculate approximate counter attack outcome
                            local av_hp = u.hitpoints
                            if tmp_enemies[1] then
                                av_hp = grunt_rush_FLS1:calc_counter_attack(u,
                                    { x, y }, { approx = true, enemies = tmp_enemies, stop_eval_average_hp = 5 }
                                ).average_hp
                            end
                            --print_time(cfg.zone_id, u.id, x, y, av_hp)
                            --defense_rating = defense_rating + av_hp

                            local hp_left_fraction = av_hp / u.hitpoints
                            local hp_loss_rating = 1.2 / (hp_left_fraction + 0.2) - 0.999
                            --print(u.hitpoints, av_hp, 20. / ( av_hp + 0.01 ), hp_left_fraction, hp_loss_rating)
                            defense_rating = defense_rating - hp_loss_rating * 0.5

                            defense_reach_map:insert(x, y, defense_rating)

                            if (defense_rating > max_defense_rating_unit) then
                                max_defense_rating_unit, best_defense_hex_unit = defense_rating, { x, y }
                            end
                        end
                    end)

                    -- If we cannot get into the zone, or none of the hexes is threatened, take direct path to goal hex
                    if (max_rating_unit == -9e99) or (defense_reach_map:size() == 0) then
                        local x, y
                        if dx then
                            x = cfg.hold.x
                            y = cfg.hold.y
                        else
                            x, y = enemy_leader.x, enemy_leader.y
                        end

                        local goal = { x = H.round(x), y = H.round(y) }
                        --print("goal: ", goal.x, goal.y)

                        local moveto = AH.get_closest_location({ goal.x, goal.y }, {}, u)
                        if (not moveto) then moveto = { u.x, u.y } end

                        local vx, vy = wesnoth.find_vacant_tile(moveto[1], moveto[2], u)
                        local next_hop = AH.next_hop(u, vx, vy)
                        if (not next_hop) then next_hop = { u.x, u.y } end
                        local dist = H.distance_between(next_hop[1], next_hop[2], goal.x, goal.y)
                        --print('cannot get there: ', u.id, dist, goal.x, goal.y)
                        max_rating_unit = -1000 - dist
                        best_hex_unit = next_hop
                    end

                    if (max_rating_unit > max_rating) then
                        max_rating, best_hex, best_unit = max_rating_unit, best_hex_unit, u
                    end
                    --print('max_rating:', max_rating)

                    if (max_defense_rating_unit > max_defense_rating) then
                        max_defense_rating, best_defense_hex, best_defense_unit = max_defense_rating_unit, best_defense_hex_unit, u
                    end
                    --print('max_defense_rating:', max_defense_rating)

                    if show_debug then
                        AH.put_labels(reach_map)
                        W.message { speaker = u.id, message = 'Hold zone: unit-specific rating map' }
                        AH.put_labels(defense_reach_map)
                        W.message { speaker = u.id, message = 'Hold zone: unit-specific defense_rating map' }
                    end
                end

                if max_defense_rating > -9e99 then
                    if show_debug then
                        wesnoth.message('Best unit: ' .. best_defense_unit.id .. ' at ' .. best_defense_unit.x .. ',' .. best_defense_unit.y .. ' --> ' .. best_defense_hex[1] .. ',' .. best_defense_hex[2])
                        wesnoth.select_hex(best_defense_hex[1], best_defense_hex[2])
                    end
                    return best_defense_unit, best_defense_hex
                else
                    if show_debug then
                        wesnoth.message('Best unit: ' .. best_unit.id .. ' at ' .. best_unit.x .. ',' .. best_unit.y .. ' --> ' .. best_hex[1] .. ',' .. best_hex[2])
                        wesnoth.select_hex(best_hex[1], best_hex[2])
                    end
                    return best_unit, best_hex
                end
            end
        end

        function grunt_rush_FLS1:calc_counter_attack(unit, hex, cfg)
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
            local units_MP = wesnoth.get_units { side = unit.side, formula = '$this_unit.moves > 0' }

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
            local all_attack_combos = BC.get_attack_combos_subset(enemies, unit, { max_combos = 1000 })
            --DBG.dbms(all_attack_combos)
            --print_time('#all_attack_combos', #all_attack_combos)

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
            if (not all_attack_combos[1]) then
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

            -- Find the maximum number of attackers in a single combo
            -- and keep only those that have this number of attacks
            local max_attacks, attack_combos = 0, {}
            for i,combo in ipairs(all_attack_combos) do
                if (#combo > max_attacks) then
                    max_attacks = #combo
                    attack_combos = {}
                end
                if (#combo == max_attacks) then
                    table.insert(attack_combos, combo)
                end
            end
            all_attack_combos = nil
            --DBG.dbms(attack_combos)
            --print_time('#attack_combos with max. attackers', #attack_combos, '(' .. max_attacks ..' attackers)')

            -- For the counter-attack calculation, we keep only unique combinations of units
            -- This is because counter-attacks are, almost by definition, a very expensive calculation
            local unique_combos = {}
            for i,combo in ipairs(attack_combos) do
                -- To find unique combos, we mark all units involved in the combo by their
                -- positions (src), combined in a string. For that, the positions need to
                -- be sorted.
                table.sort(combo, function(a, b) return a.src > b.src end)

                -- Then construct the index string
                local str = ''
                for j,att in ipairs(combo) do str = str .. att.src end
                -- Now insert this combination, if it does not exist yet
                -- For now, we simply use the first attack of this unit combination
                -- Later, this will be replaced by the "best" attack
                if not unique_combos[str] then
                    unique_combos[str] = combo
                end
            end
            -- Then put the remaining combos back into an 'attack_combos' array
            attack_combos = {}
            for k,combo in pairs(unique_combos) do table.insert(attack_combos, combo) end
            unique_combos = nil
            --DBG.dbms(attack_combos)
            --print_time('#attack_combos unique combos', #attack_combos)

            -- Want an 'enemies' map, indexed by position (for speed reasons)
            local enemies_map = {}
            for i,u in ipairs(enemies) do enemies_map[u.x * 1000 + u.y] = u end

            -- Now find the worst-case counter-attack
            local unit_copy = wesnoth.copy_unit(unit)
            unit_copy.x, unit_copy.y = hex[1], hex[2]

            local max_rating, worst_def_stats = -9e99, {}
            local cache_this_move = {}  -- To avoid unnecessary duplication of calculations
            for i,combo in ipairs(attack_combos) do
                -- attackers and dsts arrays for stats calculation

                -- Get the attack combo outcome. We're really only interested in combo_def_stats
                if cfg.approx then  -- Approximate method for average HP

                    local total_damage, max_damage = 0, 0
                    for j,att in ipairs(combo) do
                        local dst = { math.floor(att.dst / 1000), att.dst % 1000 }
                        local att_stats, def_stats =
                            BC.battle_outcome(enemies_map[att.src], unit_copy, { dst = dst }, grunt_rush_FLS1.data.cache)

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
                        worst_def_stats.average_hp = av_hp

                        -- Also add the minimum possible HP outcome to the table
                        local min_hp = unit.hitpoints - max_damage
                        if (min_hp < 0) then min_hp = 0 end
                        worst_def_stats.min_hp = min_hp
                    end

                else  -- Full calculation of combo counter attack stats

                    local atts, dsts = {}, {}
                    for j,att in ipairs(combo) do
                        table.insert(atts, enemies_map[att.src])
                        table.insert(dsts, { math.floor(att.dst / 1000), att.dst % 1000 } )
                    end

                    local default_rating, sorted_atts, sorted_dsts, combo_att_stats, combo_def_stats =
                        BC.attack_combo_stats(atts, dsts, unit_copy, grunt_rush_FLS1.data.cache, cache_this_move)

                    -- Minimum hitpoints for the unit after this attack combo
                    local min_hp = 0
                    for hp = 0,unit.hitpoints do
                        if combo_def_stats.hp_chance[hp] and (combo_def_stats.hp_chance[hp] > 0) then
                            min_hp = hp
                            break
                        end
                    end

                    -- Rating, for the purpose of counter-attack evaluation, is simply
                    -- minimum hitpoints and chance to die combination
                    local rating = -min_hp + combo_def_stats.hp_chance[0] * 100
                    --print(i, #atts, min_hp, combo_def_stats.hp_chance[0], combo_def_stats.average_hp, ' -->', rating)

                    if (rating > max_rating) then
                        max_rating = rating
                        worst_def_stats = combo_def_stats
                        -- Add min_hp field to worst_def_stats
                        worst_def_stats.min_hp = min_hp
                    end
                end
                --print(i, worst_def_stats.average_hp, worst_def_stats.min_hp)

                -- Check whether we can stop evaluating other attack combos
                -- Lower limits:
                if (worst_def_stats.average_hp <= cfg.stop_eval_average_hp) then break end
                if (worst_def_stats.min_hp <= cfg.stop_eval_min_hp) then break end
                -- Upper limits:
                if worst_def_stats.hp_chance
                    and (worst_def_stats.hp_chance[0] >= cfg.stop_eval_hp_chance_zero)
                then break end
            end
            --print_time(max_rating, worst_def_stats.average_hp, worst_def_stats.min_hp)
            --DBG.dbms(worst_def_stats)

            unit_copy = nil

            return worst_def_stats
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

            for i,s in ipairs(wesnoth.sides) do
                local total_hp = 0
                local units = AH.get_live_units { side = s.side }
                for i,u in ipairs(units) do total_hp = total_hp + u.hitpoints end
                local leader = wesnoth.get_units { side = s.side, canrecruit = 'yes' }[1]
                print('   Player ' .. s.side .. ' (' .. leader.type .. '): ' .. #units .. ' Units with total HP: ' .. total_hp)
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

            local leader = wesnoth.get_units{ side = wesnoth.current.side, canrecruit = 'yes',
                formula = '$this_unit.attacks_left > 0'
            }[1]
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
            ai.move(grunt_rush_FLS1.data.MLK_leader, grunt_rush_FLS1.data.MLK_leader_move[1], grunt_rush_FLS1.data.MLK_leader_move[2])
            grunt_rush_FLS1.data.MLK_leader, grunt_rush_FLS1.data.MLK_leader_move = nil, nil
        end

        ----------Grab villages -----------

        function grunt_rush_FLS1:eval_grab_villages(units, villages, enemies, retreat_injured_units, cfg)
            --print('#units, #enemies', #units, #enemies)

            -- Check if a unit can get to a village
            local max_rating, best_village, best_unit = -9e99, {}, {}
            for j,v in ipairs(villages) do
                local close_village = true -- a "close" village is one that is closer to theAI keep than to the closest enemy keep

                local my_leader = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]
                local my_keep = AH.get_closest_location({my_leader.x, my_leader.y}, { terrain = 'K*' })

                local dist_my_keep = H.distance_between(v[1], v[2], my_keep[1], my_keep[2])

                local enemy_leaders = AH.get_live_units { canrecruit = 'yes',
                    { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
                }
                for i,e in ipairs(enemy_leaders) do
                    local enemy_keep = AH.get_closest_location({e.x, e.y}, { terrain = 'K*' })
                    local dist_enemy_keep = H.distance_between(v[1], v[2], enemy_keep[1], enemy_keep[2])
                    if (dist_enemy_keep < dist_my_keep) then
                        close_village = false
                        break
                    end
                end
                --print('village is close village:', v[1], v[2], close_village)

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
                            { stop_eval_hp_chance_zero = max_hp_chance_zero }
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
                            if (rating ~= 0) or retreat_injured_units then
                                -- Finally, since these can be reached by the enemy, want the strongest unit to go first
                                -- except when we're retreating injured units, then it's the most injured unit first
                                if retreat_injured_units then
                                    rating = rating + (u.max_hitpoints - u.hitpoints) / 100.
                                else
                                    rating = rating + u.hitpoints / 100.

                                    -- We also want to move the "farthest back" unit first
                                    local adv_dist
                                    if dx then
                                         -- Distance in direction of (dx, dy) and perpendicular to it
                                        adv_dist = u.x * dx + u.y * dy
                                    else
                                        adv_dist = - H.distance_between(u.x, u.y, enemy_leaders[1].x, enemy_leaders[1].y)
                                    end
                                    rating = rating - adv_dist / 10.
                                end

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

        function grunt_rush_FLS1:zone_action_villages(units, enemies, cfg)
            --print_time('villages')

            -- This should include both retreating injured units to villages and village grabbing
            -- The leader is only included if he is on the keep

            -- First check for villages to retreat to
            -- This means villages in cfg.retreat_villages that are on the safe side
            local retreat_villages = {}
            for i,v in ipairs(cfg.retreat_villages or {}) do
                table.insert(retreat_villages, v)
            end
            --print('#retreat_villages', #retreat_villages)

            -- If villages were found check for units to retreat to them
            -- Consider units missing at least 8 HP during their weak time of day
            -- Caveat: neutral units are not retreated by this action at the moment
            local injured_units = {}
            if retreat_villages[1] then
                local tod = wesnoth.get_time_of_day()
                for i,u in ipairs(units) do
                    if (u.hitpoints < u.max_hitpoints - 8) then
                        local alignment = BC.unit_attack_info(u, grunt_rush_FLS1.data.cache).alignment

                        local try_retreat = false
                        if (alignment == 'chaotic') then
                            if (tod.id == 'dawn') or (tod.id == 'morning') or (tod.id == 'afternoon') then
                                try_retreat = true
                            end
                        end
                        if (alignment == 'lawful') then
                            if (tod.id == 'dusk') or (tod.id == 'first_watch') or (tod.id == 'second_watch') then
                                try_retreat = true
                            end
                        end
                        --print('retreat:', u.id, alignment, try_retreat)

                        if try_rtreat then
                            if u.canrecruit then
                                if wesnoth.get_terrain_info(wesnoth.get_terrain(u.x, u.y)).keep then
                                    table.insert(injured_units, u)
                                end
                            else
                                table.insert(injured_units, u)
                            end
                        end
                    end
                end
            end
            --print('#injured_units', #injured_units)

            -- If both villages and units were found, check for retreating moves
            -- (Seriously injured units are already dealt with previously)
            if injured_units[1] then
                local action = grunt_rush_FLS1:eval_grab_villages(injured_units, retreat_villages, enemies, true, cfg)
                if action then
                    action.action = cfg.zone_id .. ': ' .. 'retreat injured units (daytime)'
                    return action
                end
            end

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
            --print('#village_grabbers', #village_grabbers)

            if village_grabbers[1] then
                -- For this, we consider all villages, not just the retreat_villages
                local villages = wesnoth.get_locations { terrain = '*^V*' }
                local action = grunt_rush_FLS1:eval_grab_villages(village_grabbers, villages, enemies, false, cfg)
                if action then
                    action.action = cfg.zone_id .. ': ' .. 'grab villages'
                    return action
                end
            end
        end

        function grunt_rush_FLS1:zone_action_attack(units, enemies, zone, zone_map, cfg)
            --print_time('attack')

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
            local action = grunt_rush_FLS1:best_trapping_attack_opposite(attackers, targets, cfg)
            if action then return action end

            -- Then we check for poison attacks
            --print_time('    poison attack eval')
            local poisoners = {}
            for i,a in ipairs(attackers) do
                local is_poisoner = AH.has_weapon_special(a, 'poison')
                if is_poisoner then
                    table.insert(poisoners, a)
                end
            end
            --print_time('#poisoners', #poisoners)

            if (poisoners[1]) then
                local action = grunt_rush_FLS1:spread_poison_eval(poisoners, targets, cfg)
                if action then return action end
            end

            -- Also want an 'attackers' map, indexed by position (for speed reasons)
            --print_time('    standard attack eval')
            local attacker_map = {}
            for i,u in ipairs(attackers) do attacker_map[u.x * 1000 + u.y] = u end

            local max_rating, best_attackers, best_dsts, best_enemy = -9e99, {}, {}, {}
            local counter_table = {}  -- Counter-attacks are very expensive, store to avoid duplication
            local cache_this_move = {}  -- same reason
            for i,e in ipairs(targets) do
                -- How much more valuable do we consider the enemy units than out own
                local enemy_worth = 1.0
                if cfg.attack and cfg.attack.enemy_worth then
                    enemy_worth = cfg.attack.enemy_worth
                end
                if e.canrecruit then enemy_worth = enemy_worth * 5 end

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
                    local rating, sorted_atts, sorted_dsts, combo_att_stats, combo_def_stats = BC.attack_combo_stats(atts, dsts, e, grunt_rush_FLS1.data.cache, cache_this_move)
                    --DBG.dbms(combo_att_stats)
                    --print_time('   ' .. #sorted_atts .. ' attackers')

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
                            local att_ind = sorted_atts[k].x * 1000 + sorted_atts[k].y
                            local dst_ind = x * 1000 + y
                            if (not counter_table[att_ind]) then counter_table[att_ind] = {} end
                            if (not counter_table[att_ind][dst_ind]) then
                                --print_time('Calculating new counter-attack combination')
                                -- We can cut off the counter attack calculation when its minimum HP
                                -- reach max_damage defined above, as the total possible damage will
                                -- then be able to kill the leader
                                local counter_stats = grunt_rush_FLS1:calc_counter_attack(a, { x, y },
                                    { stop_eval_average_hp = min_average_hp,
                                      stop_eval_min_hp = min_min_hp,
                                      stop_eval_hp_chance_zero = max_hp_chance_zero
                                    })
                                counter_table[att_ind][dst_ind] =
                                    { min_hp = counter_stats.min_hp, counter_stats = counter_stats }
                            else
                                --print_time('Counter-attack combo already calculated. Re-using.')
                            end
                            --print_time('  done')
                            local counter_min_hp = counter_table[att_ind][dst_ind].min_hp
                            local counter_stats = counter_table[att_ind][dst_ind].counter_stats
                            local counter_average_hp = counter_stats.average_hp
                            --DBG.dbms(counter_stats)
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

                                if (av_outcome <= 5) or (counter_stats.hp_chance[0] >= max_hp_chance_zero) then
                                    -- Use the "damage cost"
                                    -- This is still experimental for now, so I'll leave the rest of the code here, commented out
                                    if (damage_cost_a > damage_cost_e * enemy_worth ) then
                                        do_attack = false
                                        break
                                    end
                                end
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
                                local is_poisoner = AH.has_weapon_special(a, 'poison')
                                if is_poisoner then
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
                action.units[1], action.dsts[1] = best_attackers[1], best_dsts[1]
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

            local zone_enemies = {}
            for i,e in ipairs(enemies) do
                if zone_map:get(e.x, e.y) then
                    table.insert(zone_enemies, e)
                end
            end

            -- Only check for possible position holding if hold.hp_ratio is met
            -- or is conditions in cfg.secure are met
            -- If hold.hp_ratio does not exist, it's true by default

            local eval_hold = true
            if cfg.hold.hp_ratio then
                local hp_ratio = 1e99
                if (#zone_enemies > 0) then
                    hp_ratio = grunt_rush_FLS1:hp_ratio(units_noMP, zone_enemies)
                end
                --print('hp_ratio, #units_noMP, #zone_enemies', hp_ratio, #units_noMP, #zone_enemies)

                -- Don't evaluate for holding position if the hp_ratio in the zone is already high enough
                if (hp_ratio >= cfg.hold.hp_ratio) then
                    eval_hold = false
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

        function grunt_rush_FLS1:get_zone_action(cfg)
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
            local all_units = AH.get_live_units(unit_filter)
            local zone_units, zone_units_noMP, zone_units_attacks = {}, {}, {}
            for i,u in ipairs(all_units) do
                if (u.moves > 0) then
                    table.insert(zone_units, u)
                else
                    table.insert(zone_units_noMP, u)
                end
                if (u.attacks_left > 0) then
                    table.insert(zone_units_attacks, u)
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
                    village_action = grunt_rush_FLS1:zone_action_villages(zone_units, enemies, cfg)
                    if village_action and (village_action.rating > 100) then
                        --print(village_action.action)
                        return village_action
                    end
                end
            end

            -- **** Attack evaluation ****
            --print_time('  ' .. cfg.zone_id .. ': attack eval')
            if (not cfg.do_action) or cfg.do_action.attack then
                if (not cfg.skip_action) or (not cfg.skip_action.attack) then
                    local action = grunt_rush_FLS1:zone_action_attack(zone_units_attacks, enemies, zone, zone_map, cfg)
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
                        --print(action.action)
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

            local cfgs = grunt_rush_FLS1:get_zone_cfgs()

            for i_c,cfg in ipairs(cfgs) do
                --print_time('zone_control: ', cfg.zone_id)
                local zone_action = grunt_rush_FLS1:get_zone_action(cfg)

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

                local unit = grunt_rush_FLS1.data.zone_action.units[1]
                local dst = grunt_rush_FLS1.data.zone_action.dsts[1]

                -- If this is the leader, recruit first
                -- We're doing that by running a mini CA eval/exec loop
                if unit.canrecruit then
                    --print('-------------------->  This is the leader. Recruit first.')
                    if AH.show_messages() then W.message { speaker = unit.id, message = 'The leader is about to move. Need to recruit first.' } end

                    while grunt_rush_FLS1:recruit_rushers_eval() > 0 do
                        if not grunt_rush_FLS1:recruit_rushers_exec() then
                            break
                        end
                    end
                end

                if AH.print_exec() then print_time('   Executing zone_control CA ' .. action) end
                if AH.show_messages() then W.message { speaker = unit.id, message = 'Zone action ' .. action } end

                AH.movefull_outofway_stopunit(ai, unit, dst)

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
                table.remove(grunt_rush_FLS1.data.zone_action.units, 1)
                table.remove(grunt_rush_FLS1.data.zone_action.dsts, 1)

                -- Then do the attack, if there is one to do
                if grunt_rush_FLS1.data.zone_action.enemy then
                    ai.attack(unit, grunt_rush_FLS1.data.zone_action.enemy)

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
                        }
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

        function grunt_rush_FLS1:stop_unit_eval()
            local score_stop_unit = 170000
            local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'stop_unit'
            if AH.print_eval() then print_time('     - Evaluating stop_unit CA:') end

            -- Skip this if AI is much stronger than enemy
            if grunt_rush_FLS1:full_offensive() then
                AH.done_eval_messages(start_time, ca_name)
                return 0
            end

            -- Otherwise, if any units has attacks or moves left, take them away
            local units_with_attacks = wesnoth.get_units{ side = wesnoth.current.side,
                formula = '$this_unit.attacks_left > 0'
            }
            if units_with_attacks[1] then return score_stop_unit end

            local units_with_moves = wesnoth.get_units { side = wesnoth.current.side,
                formula = '$this_unit.moves > 0'
            }
            if units_with_moves[1] then return score_stop_unit end

            return 0
        end

        function grunt_rush_FLS1:stop_unit_exec()
            if AH.print_exec() then print_time('   Executing stop_unit CA') end

            local units_with_attacks = wesnoth.get_units{ side = wesnoth.current.side,
                formula = '$this_unit.attacks_left > 0'
            }
            for i,u in ipairs(units_with_attacks) do
                ai.stopunit_all(u)
                --print('Attacks left:', u.id)
            end

            local units_with_moves = wesnoth.get_units { side = wesnoth.current.side,
                formula = '$this_unit.moves > 0'
            }
            for i,u in ipairs(units_with_moves) do
                --print('Moves left:', u.id)
                ai.stopunit_all(u)
            end
        end

        return grunt_rush_FLS1
    end
}
