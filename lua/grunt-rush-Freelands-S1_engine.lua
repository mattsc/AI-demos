return {
    init = function(ai)

        local grunt_rush_FLS1 = {}
        -- Specialized grunt rush for Freelands map, Side 1 only

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        local BC = wesnoth.dofile "~/add-ons/AI-demos/lua/battle_calcs.lua"
        local LS = wesnoth.require "lua/location_set.lua"
        local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

        ----------Recruitment -----------------

        local score_function = function ()
            return 181000
        end

        wesnoth.require("~add-ons/AI-demos/lua/generic-recruit_engine.lua").init(ai, grunt_rush_FLS1, score_function)

        --------------------------------------------------------------------
        -- This is customized for Northerners on Freelands, playing Side 1
        --------------------------------------------------------------------

        function grunt_rush_FLS1:get_zone_cfgs(recalc)
            -- Set up the config table for the different map zones
            -- zone_id: ID for the zone; only needed for debug messages
            -- zone_filter: SLF describing the zone
            -- unit_filter: SUF of the units considered for moves for this zone
            -- do_action: if given, evaluate only the listed actions for the zone
            --   if not given, evaluate all actions (that should be the default)
            -- skip_action: actions listed here will be skipped from evaluation, all
            --   others will be evaluation.
            --   !!! Obviously, only do_action _or_ skip_action should be given, not both !!!
            -- min_relative_damage: the minimum acceptable relative damage for attacking/advancing
            -- attack: table describing the type of zone attack to be done
            --   - use_enemies_in_reach: if set, use enemies that can reach zone, otherwise use units inside the zone
            --       Note: only use with very small zones, otherwise it can be very slow
            -- hold: table describing where to hold a position
            --   - x: the central x coordinate of the hold
            --   - max_y: the maximum y coordinate where to hold
            --   - hp_ratio: the minimum HP ratio required to hold at this position
            -- retreat_villages: array of villages to which to retreat injured units

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
                do_action = { retreat_injured = true, villages = true },
            }

            local cfg_leader_threat = {
                zone_id = 'leader_threat',
                zone_filter = { { 'filter', { canrecruit = 'yes', side = wesnoth.current.side } } },
                unit_filter = { x = '1-' .. width , y = '1-' .. height },
                do_action = { attack = true },
                min_relative_damage = -5.,
                attack = { use_enemies_in_reach = true }
            }

            local cfg_center = {
                zone_id = 'center',
                zone_filter = { x = '15-24', y = '1-16' },
                unit_filter = { x = '16-25,15-22', y = '1-13,14-19' },
                hold = { x = 20, min_y = 9, max_y = 15, hp_ratio = 0.67 },
                retreat_villages = { { 18, 9 }, { 24, 7 }, { 22, 2 } }
            }

            local cfg_left = {
                zone_id = 'left',
                zone_filter = { x = '4-14', y = '1-15' },
                unit_filter = { x = '1-15,16-20', y = '1-15,1-6' },
                min_relative_damage = -3.,
                hold = { x = 11, min_y = 5, max_y = 15, hp_ratio = 1.0 },
                secure = { x = 11, y = 9, moves_away = 2, min_units = 1 },
                retreat_villages = { { 11, 9 }, { 8, 5 }, { 12, 5 }, { 12, 2 } },
                villages = { hold_threatened = true }
            }

            local cfg_right = {
                zone_id = 'right',
                zone_filter = { x = '25-34', y = '1-24' },
                unit_filter = { x = '16-99,22-99', y = '1-11,12-25' },
                hold = { x = 27, min_y = 11, max_y = 22 },
                retreat_villages = { { 24, 7 }, { 28, 5 } }
            }

            -- This way it will be easy to change the priorities on the fly later:
            cfgs = {}
            table.insert(cfgs, cfg_full_map)
            table.insert(cfgs, cfg_leader_threat)
            table.insert(cfgs, cfg_left)
            table.insert(cfgs, cfg_center)
            table.insert(cfgs, cfg_right)

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

            -- We also need an zone_parms global variable
            -- This might be set/reset independently of zone_cfgs -> separate variable
            grunt_rush_FLS1.data.zone_parms = {}
            for i_c,c in ipairs(cfgs) do
                grunt_rush_FLS1.data.zone_parms[i_c] = {}
            end

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

        function grunt_rush_FLS1:relative_damage_y(my_units, enemies, zone)
            -- Relative damage as function of y coordinate

            --print('#my_units, #enemies', #my_units, #enemies)
            local rel_damage_map = BC.relative_damage_map(my_units, enemies, grunt_rush_FLS1.data.cache)
            --AH.put_labels(rel_damage_map)

            local rel_damage_y = {}
            for i,hex in ipairs(zone) do
                local x, y = hex[1], hex[2]  -- simply for ease of reading
                if (not rel_damage_y[y]) then rel_damage_y[y] = -9e99 end
                local rd = rel_damage_map:get(x, y) or -9e99
                if (rd > rel_damage_y[y]) then rel_damage_y[y] = rd end
            end
            --wesnoth.clear_messages()
            --DBG.dbms(rel_damage_y)
            --W.message{ speaker = 'narrator', message = 'Relative damage map' }

            return rel_damage_y
        end

        function grunt_rush_FLS1:full_offensive()
            -- Returns true if the conditions to go on all-out offensive are met
            -- 1. If Turn >= 16 and HP ratio > 1.5
            -- 2. IF HP ratio > 2 under all circumstance (well, starting from Turn 3, to avoid problems at beginning)

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
            local counter_table = {}  -- Counter attacks are very expensive, store to avoid duplication
            local cache_this_move = {}  -- same reason
            for i,e in ipairs(enemies) do
                --print(i, e.id, os.clock())
                local attack_combos = AH.get_attack_combos(units, e, { include_occupied = true })
                --DBG.dbms(attack_combos)
                --print('#attack_combos', #attack_combos, os.clock())

                local enemy_on_village = wesnoth.get_terrain_info(wesnoth.get_terrain(e.x, e.y)).village
                local enemy_cost = wesnoth.unit_types[e.type].cost

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
                            if (not counter_table[att_ind][dst_ind]) then
                                --print('Calculating new counter attack combination')
                                local counter_min_hp, counter_def_stats = grunt_rush_FLS1:calc_counter_attack(a, { x, y })
                                counter_table[att_ind][dst_ind] = { min_hp = counter_min_hp, counter_def_stats = counter_def_stats }
                            else
                                --print('Counter attack combo already calculated.  Re-using.')
                            end
                            local counter_min_hp = counter_table[att_ind][dst_ind].min_hp
                            local counter_def_stats = counter_table[att_ind][dst_ind].counter_def_stats

                            --print(a.id, dsts[i_a][1], dsts[i_a][2], counter_def_stats.hp_chance[0], counter_def_stats.average_hp)
                            -- Use a condition when damage is too much to be worthwhile
                            if (counter_def_stats.hp_chance[0] > 0.30) or (counter_def_stats.average_hp < 10) then
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

                        --print(' -----------------------> zoc attack rating', rating, os.clock())
                        if (rating > max_rating) then
                            max_rating, best_attackers, best_dsts, best_enemy = rating, attackers, dsts, e
                        end
                    end
                end
            end
            --print('max_rating ', max_rating, os.clock())

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

        function grunt_rush_FLS1:hold_zone(holders, goal, cfg)
            local enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", { side = wesnoth.current.side } }} }
            }

            local injured_locs = injured_locs or {}
            for i,l in ipairs(injured_locs) do
                if (goal.y < l[2] + 1) then goal.y = l[2] + 1 end
            end

            -- Now move units into holding positions
            while holders[1] do
                -- First, find where the enemy can attack
                -- This needs to be done after every move
                -- And units with MP left need to be taken off the map
                local units_MP = wesnoth.get_units { side = wesnoth.current.side, formula = '$this_unit.moves > 0' }
                local units_noMP = wesnoth.get_units { side = wesnoth.current.side, formula = '$this_unit.moves = 0' }
                for iu,uMP in ipairs(units_MP) do wesnoth.extract_unit(uMP) end

                -- Put the units back out there
                for iu,uMP in ipairs(units_MP) do wesnoth.put_unit(uMP.x, uMP.y, uMP) end

                -- First calculate a unit independent rating map
                local zone = wesnoth.get_locations(cfg.zone_filter)
                rating_map = LS.create()
                for i,hex in ipairs(zone) do
                    local x, y = hex[1], hex[2]

                    if (y >= goal.y-2) and (y <= goal.y+1) then
                        local rating = 0

                        local y_dist = math.abs(y - goal.y)
                        --y_dist = math.floor(y_dist / 2) * 2.
                        rating = rating - y_dist

                        rating = rating - math.abs(x - goal.x) / 2.

                        -- In particular, do not like positions too far south -> additional penalty
                        if (y > goal.y + 1) then rating = rating - (y - goal.y) * 10 end

                        -- Small bonus if this is on a village
                        -- Village will also get bonus from defense rating below
                        local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(x, y)).village
                        if is_village then
                            rating = rating + 5
                        end

                        -- We also, ideally, want to be 3 hexes from the closest unit that has
                        -- already moved, so as to ZOC the zone
                        local min_dist = 9999
                        for j,m in ipairs(units_noMP) do
                            local dist = H.distance_between(x, y, m.x, m.y)
                            if (dist < min_dist) then min_dist = dist end
                        end
                        if (min_dist == 3) then rating = rating + 6 end
                        if (min_dist == 2) then rating = rating + 4 end

                       rating_map:insert(x, y, rating)
                    end
                end
                --AH.put_labels(rating_map)
                --W.message { speaker = 'narrator', message = 'Hold zone: unit-independent rating map' }

                -- Now we go on to the unit-dependent rating part
                local max_rating, best_hex, best_unit = -9e99, {}, {}
                for i,u in ipairs(holders) do
                    local reach_map = AH.get_reachable_unocc(u)
                    local max_rating_unit, best_hex_unit = -9e99, {}
                    reach_map:iter( function(x, y, v)
                        -- If this is inside the zone
                        if rating_map:get(x, y) then
                            rating = rating_map:get(x, y)

                            -- Take southern and eastern units first
                            -- We might want to change this later to using strong units first,
                            -- then retreating weaker units behind them
                            rating = rating + u.y + u.x / 2.

                            -- Rating for the terrain
                            local terrain_weight = 0.51
                            local defense = 100 - wesnoth.unit_defense(u, wesnoth.get_terrain(x, y))
                            rating = rating + defense * terrain_weight

                            reach_map:insert(x, y, rating)

                            if (rating > max_rating_unit) then
                                max_rating_unit, best_hex_unit = rating, { x, y }
                            end
                        else
                            reach_map:remove(x, y)
                        end
                    end)

                    -- If we cannot get into the zone, take direct path to goal hex
                    if (max_rating_unit == -9e99) then
                        local next_hop = AH.next_hop(u, goal.x, goal.y)
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

                    --AH.put_labels(reach_map)
                    --W.message { speaker = u.id, message = 'Hold zone: unit-specific rating map' }
                end

                return best_unit, best_hex
            end
        end

        function grunt_rush_FLS1:calc_counter_attack(unit, hex)
            -- Get counter attack results a unit might experience next turn if it moved to 'hex'
            -- Return worst case scenario HP and def_stats
            -- This uses real counter_attack combinations

            -- All enemy units
            local enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", { side = unit.side } }} }
            }
            --print('#enemies', #enemies)

            -- Need to take units with MP off the map for enemy path finding
            local units_MP = wesnoth.get_units { side = unit.side, formula = '$this_unit.moves > 0' }

            -- Take all units with MP left off the map, except the unit under investigation itself
            for i,u in ipairs(units_MP) do
                if (u.x ~= unit.x) or (u.y ~= unit.y) then
                    wesnoth.extract_unit(u)
                end
            end

            -- Now we put our unit into the position of interest
            -- (and remove any unit that might be there)
            local org_hex = { unit.x, unit.y }
            local unit_in_way = {}
            if (org_hex[1] ~= hex[1]) or (org_hex[2] ~= hex[2]) then
                unit_in_way = wesnoth.get_unit(hex[1], hex[2])
                if unit_in_way then wesnoth.extract_unit(unit_in_way) end
                wesnoth.put_unit(hex[1], hex[2], unit)
            end

            -- Get all possible attack combination
            local all_attack_combos = AH.get_attack_combos(enemies, unit, { include_occupied = true })  -- Don't need moves='max'
            --DBG.dbms(all_attack_combos)
            --print('#all_attack_combos', #all_attack_combos, os.clock())

            -- Put units back to where they were
            if (org_hex[1] ~= hex[1]) or (org_hex[2] ~= hex[2]) then
                wesnoth.put_unit(org_hex[1], org_hex[2], unit)
                if unit_in_way then wesnoth.put_unit(hex[1], hex[2], unit_in_way) end
            end
            for i,u in ipairs(units_MP) do
                if (u.x ~= unit.x) or (u.y ~= unit.y) then
                    wesnoth.put_unit(u.x, u.y, u)
                end
            end

            -- If no attacks are found, we're done; return full HP and empty table
            if (not all_attack_combos[1]) then return unit.hitpoints, {} end

            -- Find the maximum number of attackers in a single combo
            -- and keep only those that have this number of attacks
            local max_attacks, attack_combos = 0, {}
            for i,combo in ipairs(all_attack_combos) do
                local number = 0
                for dst,src in pairs(combo) do number = number + 1 end
                if (number > max_attacks) then
                    max_attacks = number
                    attack_combos = {}
                end
                if (number == max_attacks) then
                    table.insert(attack_combos, combo)
                end
            end
            all_attack_combos = nil
            --print('#attack_combos', #attack_combos, os.clock())

            -- For the counter attack calculation, we keep only unique combinations of units
            -- This is because counter attacks are, almost by definition, a very expensive calculation
            local unique_combos = {}
            for i,combo in ipairs(attack_combos) do
                -- To find unique combos, we mark all units involved in the combo by their
                -- positions (src), combined in a string.  For that, the positions need to
                -- be sorted.  Unfortunately, sorting only works on arrays, not general table
                local tmp_arr, ind, str = {}, {}, ''
                -- Set up the array, and sort
                for dst,src in pairs(combo) do table.insert(tmp_arr, src) end
                table.sort(tmp_arr, function(a, b) return a > b end)

                -- Then construct the index string
                for j,src in ipairs(tmp_arr) do str = str .. src end

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
            --print('#attack_combos', #attack_combos, os.clock())

            -- Want an 'enemies' map, indexed by position (for speed reasons)
            local enemies_map = {}
            for i,u in ipairs(enemies) do enemies_map[u.x * 1000 + u.y] = u end

            -- Now find the worst-case counter attack
            local max_rating, worst_hp, worst_def_stats = -9e99, 0, {}
            local cache_this_move = {}  -- To avoid unnecessary duplication of calculations
            for i,combo in ipairs(attack_combos) do
                -- attackers and dsts arrays for stats calculation
                local atts, dsts = {}, {}
                for dst,src in pairs(combo) do
                    table.insert(atts, enemies_map[src])
                    table.insert(dsts, { math.floor(dst / 1000), dst % 1000 } )
                end

                -- Get the attack combo outcome.  We're really only interested in combo_def_stats
                local default_rating, sorted_atts, sorted_dsts, combo_att_stats, combo_def_stats = BC.attack_combo_stats(atts, dsts, unit, grunt_rush_FLS1.data.cache, cache_this_move)

                -- Minimum hitpoints for the unit after this attack combo
                local min_hp = 0
                for hp = 0,unit.hitpoints do
                    if combo_def_stats.hp_chance[hp] and (combo_def_stats.hp_chance[hp] > 0) then
                        min_hp = hp
                        break
                    end
                end

                -- Rating, for the purpose of counter attack evaluation, is simply
                -- minimum hitpoints and chance to die combination
                local rating = -min_hp + combo_def_stats.hp_chance[0] * 100
                --print(i, #atts, min_hp, combo_def_stats.hp_chance[0], ' -->', rating)

                if (rating > max_rating) then
                    max_rating = rating
                    worst_hp, worst_def_stats = min_hp, combo_def_stats
                end
            end
            --print(max_rating, worst_hp)
            --DBG.dbms(worst_def_stats)

            return worst_hp, worst_def_stats
        end

        ------ Stats at beginning of turn -----------

        -- This will be blacklisted after first execution each turn
        function grunt_rush_FLS1:stats_eval()
            local score = 999999
            return score
        end

        function grunt_rush_FLS1:stats_exec()
            local tod = wesnoth.get_time_of_day()
            print(' Beginning of Turn ' .. wesnoth.current.turn .. ' (' .. tod.name ..') stats (CPU time ' .. os.clock() .. ')')

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
        end

        ------ Move leader to keep -----------

        function grunt_rush_FLS1:move_leader_to_keep_eval()
            local score = 480000
            local start_time, ca_name = os.clock(), 'move_leader_to_keep'
            if AH.print_eval() then print('     - Evaluating move_leader_to_keep CA:', os.clock()) end

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
                if (leader.x == k[1]) or (leader.y == k[2]) then
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
            if AH.print_exec() then print('   ' .. os.clock() .. ' Executing move_leader_to_keep CA') end
            if AH.show_messages() then W.message { speaker = grunt_rush_FLS1.data.MLK_leader.id, message = 'Moving back to keep' } end
            -- This has to be a partial move !!
            ai.move(grunt_rush_FLS1.data.MLK_leader, grunt_rush_FLS1.data.MLK_leader_move[1], grunt_rush_FLS1.data.MLK_leader_move[2])
            grunt_rush_FLS1.data.MLK_leader, grunt_rush_FLS1.data.MLK_leader_move = nil, nil
        end

        ------ Retreat injured units (not a separate CA any more) -----------

        function grunt_rush_FLS1:get_retreat_injured_units(units, terrain_filter, min_hp)
            -- Pick units that have less than min_hp HP
            -- with poisoning counting as -8 HP and slowed as -4
            local healees = {}
            for i,u in ipairs(units) do
                local hp_eff = u.hitpoints
                if u.status.poisoned then hp_eff = hp_eff - 8 end
                if u.status.slowed then hp_eff = hp_eff - 4 end

                -- Also reduce effective HP of leader some more
                -- to have AI leader retreat earlier
                if u.canrecruit then hp_eff = hp_eff - 8 end

                if (hp_eff < min_hp(u)) then
                    table.insert(healees, u)
                end
            end
            --print('#healees', #healees)
            if (not healees[1]) then
                return nil
            end

            local villages = wesnoth.get_locations { terrain = terrain_filter }
            --print('#villages', #villages)

            -- Only retreat to safe villages
            local enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }
            local enemy_attack_map = BC.get_attack_map(enemies)

            local max_rating, best_village, best_unit = -9e99, {}, {}
            for i,v in ipairs(villages) do
                local unit_in_way = wesnoth.get_unit(v[1], v[2])
                if (not unit_in_way) or (unit_in_way.moves > 0) then
                    --print('Village available:', v[1], v[2])
                    for i,u in ipairs(healees) do
                        local next_hop = AH.next_hop(u, v[1], v[2], { ignore_own_units = true })
                        if next_hop and (next_hop[1] == v[1]) and (next_hop[2] == v[2]) then
                            --print('  can be reached by', u.id, u.x, u.y)
                            local rating = - u.hitpoints + u.max_hitpoints / 2.

                            if u.status.poisoned then rating = rating + 8 end
                            if u.status.slowed then rating = rating + 4 end

                            -- Minor penalty if a unit has to move out of the way
                            if unit_in_way then rating = rating - 0.1 end

                            -- villages in the north are preferable (since they are supposedly away from the enemy)
                            rating = rating - v[2]

                            if (rating > max_rating) and ((enemy_attack_map.units:get(v[1], v[2]) or 0) <= 1 ) then
                                max_rating, best_village, best_unit = rating, v, u
                            end
                        end
                    end
                end
            end

            if (max_rating > -9e99) then
                local action = { units = {}, dsts = {}, type = 'village', reserve = best_village }
                action.units[1], action.dsts[1] = best_unit, best_village
                return action
            end

            -- No safe villages within 1 turn - try to move to closest village within 4 turns
            -- That can be either unoccupied or occupied by a unit on the same side

            local max_rating, best_hop, best_village, best_unit = -9e99, {}, {}
            for i,v in ipairs(villages) do
                -- Check whether this villages is "reserved" for another unit already
                local v_ind = v[1] * 1000 + v[2]
                local reserved_village = false
                if grunt_rush_FLS1.data.reserved_villages and grunt_rush_FLS1.data.reserved_villages[v_ind] then
                    reserved_village = true
                end

                local unit_in_way = wesnoth.get_unit(v[1], v[2])
                if (not reserved_village) and ((not unit_in_way) or (unit_in_way.side == wesnoth.current.side)) then
                    --print('Village available:', v[1], v[2])
                    for i,u in ipairs(healees) do
                        local path, cost = wesnoth.find_path(u, v[1], v[2])

                        if cost <= u.max_moves * 4 then
                            local rating = - u.hitpoints + u.max_hitpoints / 2.

                            rating = rating - cost

                            if u.status.poisoned then rating = rating + 8 end
                            if u.status.slowed then rating = rating + 4 end

                            -- villages in the north are preferable (since they are supposedly away from the enemy)
                            rating = rating - (v[2] * 1.5)

                            if (rating > max_rating) and ((enemy_attack_map.units:get(v[1], v[2]) or 0) <= 1 ) then
                                local next_hop = AH.next_hop(u, v[1], v[2])
                                max_rating, best_hop, best_village, best_unit = rating, next_hop, v, u
                            end
                        end
                    end
                end
            end

            if (max_rating > -9e99) then
                local action = { units = {}, dsts = {}, type = 'village', reserve = best_village }
                action.units[1], action.dsts[1] = best_unit, best_hop
                return action
            end

            return nil
        end

        ----------Grab villages -----------

        function grunt_rush_FLS1:eval_grab_villages(units, villages, enemies, retreat_injured_units)
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

                for i,u in ipairs(units) do
                    local path, cost = wesnoth.find_path(u, v[1], v[2])

                    local unit_in_way = wesnoth.get_unit(v[1], v[2])
                    if unit_in_way then
                        if (unit_in_way.id == u.id) then unit_in_way = nil end
                    end

                    -- Rate all villages that can be reached and are unoccupied by other units
                    if (cost <= u.moves) and (not unit_in_way) then
                        --print('Can reach:', u.id, v[1], v[2], cost)
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
                        wesnoth.put_unit(u.x, u.y, u)

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
                            end

                            -- If this is the leader, calculate counter attack damage
                            -- Make him the preferred village taker unless he's likely to die
                            -- but only if he's on the keep
                            if u.canrecruit then
                                -- These are usually individual calls, so while expensive, this is fine
                                local min_hp, counter_def_stats = grunt_rush_FLS1:calc_counter_attack(u, { v[1], v[2] })
                                --print('    min_hp:', u.id, min_hp)
                                if (min_hp > 0) and wesnoth.get_terrain_info(wesnoth.get_terrain(u.x, u.y)).keep then
                                    --print('      -> take village with leader')
                                    rating = rating + 2
                                else
                                    rating = -9e99
                                end
                            end

                            if (rating > max_rating) then
                                max_rating, best_village, best_unit = rating, v, u
                            end
                        end
                    end
                end
            end
            --print('max_rating', max_rating)

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
            --print('retreat', os.clock())

            -- Note: while severely injured units are dealt with on a zone-by-zone basis,
            -- they can retreat to hexes outside the zones
            -- This includes the leader even if he is not on his keep
            local trolls, non_trolls = {}, {}
            for i,u in ipairs(units) do
                if (u.__cfg.race == 'troll') then
                    table.insert(trolls, u)
                else
                    table.insert(non_trolls, u)
                end
            end
            --print('#trolls, #non_trolls', #trolls, #non_trolls)

            -- First we retreat non-troll units w/ <8+4/level HP to villages.
            local min_hp = function(unit)
                return 8 + 4*wesnoth.unit_types[unit.type].level
            end
            if non_trolls[1] then
                local action = grunt_rush_FLS1:get_retreat_injured_units(non_trolls, "*^V*", min_hp)
                if action then
                    action.action = cfg.zone_id .. ': ' .. 'retreat severely injured units (non-trolls)'
                    return action
                end
            end

            -- Then we retreat troll units with <10+6/level HP to mountains
            -- We use a slightly higher min_hp b/c trolls generally have low defense.
            -- Also since trolls regen at start of turn, they only have <12 HP if poisoned
            -- or reduced to <4 HP on enemy's turn.
            -- We exclude impassable terrain to speed up evaluation.
            -- We do NOT exclude mountain villages! Maybe we should?
            if trolls[1] then
                min_hp = function(unit)
                    return 10 + 6*wesnoth.unit_types[unit.type].level
                end
                local action = grunt_rush_FLS1:get_retreat_injured_units(trolls, "!,*^X*,!,M*^*", min_hp)
                if action then
                    action.action = cfg.zone_id .. ': ' .. 'retreat severely injured units (trolls)'
                    return action
                end
            end
        end

        function grunt_rush_FLS1:zone_action_villages(units, enemies, cfg)
            --print('villages', os.clock())

            -- This should include both retreating to villages of injured units and village grabbing
            -- The leader is only included if he is on the keep

            local injured_units = {}
            for i,u in ipairs(units) do
                if (u.hitpoints < u.max_hitpoints - 8) then
                    if u.canrecruit then
                        if wesnoth.get_terrain_info(wesnoth.get_terrain(u.x, u.y)).keep then
                            table.insert(injured_units, u)
                        end
                    else
                        table.insert(injured_units, u)
                    end
                end
            end
            --print('#injured_units', #injured_units)

            -- During daytime, we retreat injured units toward villages
            -- (Seriously injured units are already dealt with previously)
            if injured_units[1] and cfg.retreat_villages then
                local tod = wesnoth.get_time_of_day()
                if (tod.id == 'dawn') or (tod.id == 'morning') or (tod.id == 'afternoon') then
                    local action = grunt_rush_FLS1:eval_grab_villages(injured_units, cfg.retreat_villages, enemies, true)
                    if action then
                        action.action = cfg.zone_id .. ': ' .. 'retreat injured units (daytime)'
                        return action
                    end
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
                local action = grunt_rush_FLS1:eval_grab_villages(village_grabbers, villages, enemies, false)
                if action then
                    action.action = cfg.zone_id .. ': ' .. 'grab villages'
                    return action
                end
            end
        end

        function grunt_rush_FLS1:zone_action_attack(units, enemies, zone, zone_map, advance_y, cfg)
            --print('attack', os.clock())

            -- Attackers include the leader but only if he is on his
            -- keep, in order to prevent him from wandering off
            local attackers = {}
            for i,u in ipairs(units) do
                if u.canrecruit then
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
            -- such as that consisting only of the AI leader position) otherwise it
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
                    if zone_map:get(e.x, e.y) and (e.y <= advance_y + 1) then
                        table.insert(targets, e)
                    end
                end
            end

            -- We first see if there's a trapping attack possible
            local action = grunt_rush_FLS1:best_trapping_attack_opposite(attackers, targets, cfg)
            if action then return action end

            -- Then we check for poison attacks
            local poisoners = {}
            for i,a in ipairs(attackers) do
                local is_poisoner = AH.has_weapon_special(a, 'poison')
                if is_poisoner then
                    table.insert(poisoners, a)
                end
            end
            --print('#poisoners', #poisoners)

            if (poisoners[1]) then
                local action = grunt_rush_FLS1:spread_poison_eval(poisoners, enemies, cfg)
                if action then return action end
            end

            -- Also want an 'attackers' map, indexed by position (for speed reasons)
            local attacker_map = {}
            for i,u in ipairs(attackers) do attacker_map[u.x * 1000 + u.y] = u end

            local max_rating, best_attackers, best_dsts, best_enemy = -9e99, {}, {}, {}
            local counter_table = {}  -- Counter attacks are very expensive, store to avoid duplication
            local cache_this_move = {}  -- same reason
            for i,e in ipairs(targets) do
                --print('\n', i, e.id, os.clock())
                local attack_combos = AH.get_attack_combos(attackers, e, { include_occupied = true })
                --DBG.dbms(attack_combos)
                --print('#attack_combos', #attack_combos)

                local enemy_on_village = wesnoth.get_terrain_info(wesnoth.get_terrain(e.x, e.y)).village
                local enemy_cost = wesnoth.unit_types[e.type].cost

                for j,combo in ipairs(attack_combos) do
                    --print('combo ' .. j, os.clock())
                    -- attackers and dsts arrays for stats calculation
                    local atts, dsts = {}, {}
                    for dst,src in pairs(combo) do
                        table.insert(atts, attacker_map[src])
                        table.insert(dsts, { math.floor(dst / 1000), dst % 1000 } )
                    end
                    local rating, sorted_atts, sorted_dsts, combo_att_stats, combo_def_stats = BC.attack_combo_stats(atts, dsts, e, grunt_rush_FLS1.data.cache, cache_this_move)
                    --DBG.dbms(combo_def_stats)

                    -- Don't attack if CTD is too high for any of the attackers
                    -- which means 50% CDT for normal units and 0% for leader
                    local do_attack = true
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
                    end

                    -- If the leader is involved, make sure it leaves him in a save spot
                    if do_attack then
                        for k,a in ipairs(sorted_atts) do
                            if a.canrecruit then
                                local x, y = sorted_dsts[k][1], sorted_dsts[k][2]
                                local att_ind = sorted_atts[k].x * 1000 + sorted_atts[k].y
                                local dst_ind = x * 1000 + y
                                if (not counter_table[att_ind]) then counter_table[att_ind] = {} end
                                if (not counter_table[att_ind][dst_ind]) then
                                    --print('Calculating new counter attack combination')
                                    local counter_min_hp, counter_def_stats = grunt_rush_FLS1:calc_counter_attack(a, { x, y })
                                    counter_table[att_ind][dst_ind] = { min_hp = counter_min_hp, counter_def_stats = counter_def_stats }
                                else
                                    --print('Counter attack combo already calculated.  Re-using.')
                                end
                                local counter_min_hp = counter_table[att_ind][dst_ind].min_hp
                                local counter_def_stats = counter_table[att_ind][dst_ind].counter_def_stats

                                -- If there's a chance to be poisoned or slowed, don't do it
                                if (counter_def_stats.slowed > 0.0) or (counter_def_stats.poisoned > 0.0) then
                                    do_attack = false
                                    break
                                end

                                -- Add max damages from this turn and counter attack
                                local min_hp = 0
                                for hp = 0,a.hitpoints do
                                    if combo_att_stats[k].hp_chance[hp] and (combo_att_stats[k].hp_chance[hp] > 0) then
                                        min_hp = hp
                                        break
                                    end
                                end

                                local max_damage = a.hitpoints - min_hp
                                local min_outcome = counter_min_hp - max_damage
                                --print('min_outcome, counter_min_hp, max_damage', min_outcome, counter_min_hp, max_damage)

                                if (min_outcome <= 0) then
                                    do_attack = false
                                    break
                                end
                            end
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
                        --print(' -----------------------> rating', rating, os.clock())
                        if (rating > max_rating) then
                            max_rating, best_attackers, best_dsts, best_enemy = rating, sorted_atts, sorted_dsts, e
                        end
                    end
                end
            end
            --print('max_rating ', max_rating, os.clock())

            if (max_rating > -9e99) then
                -- Only execute the first of these attacks
                local action = { units = {}, dsts = {}, enemy = best_enemy }
                action.units[1], action.dsts[1] = best_attackers[1], best_dsts[1]
                action.action = cfg.zone_id .. ': ' .. 'attack'
                return action
            end

            return nil
        end

        function grunt_rush_FLS1:zone_action_hold(units, units_noMP, enemies, zone_map, hold_y, cfg)
            --print('hold', os.clock())

            -- The leader does not participate in position holding (for now, at least)
            local holders = {}
            for i,u in ipairs(units) do
                if (not u.canrecruit) then
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
                local hp_ratio = grunt_rush_FLS1:hp_ratio(holders, zone_enemies)
                --print('hp_ratio, #holders, #zone_enemies', hp_ratio, #holders, #zone_enemies)

                -- Don't evaluate for holding position if the hp_ratio in the zone is already high enough
                if (hp_ratio >= cfg.hold.hp_ratio) then
                    eval_hold = false
                end
            end

            -- If there are unoccupied or enemy-occupied villages in the hold zone, send units there
            -- if we do not have enough units that have moved already are in the zone
            if (not eval_hold) then
                if (#units_noMP < #cfg.retreat_villages/2) then
                    for i,v in ipairs(cfg.retreat_villages) do
                        local owner = wesnoth.get_village_owner(v[1], v[2])
                        if (not owner) or wesnoth.is_enemy(owner, wesnoth.current.side) then
                            eval_hold, get_villages = true, true
                        end
                    end
                end
                --print('#units_noMP, #cfg.retreat_villages', #units_noMP, #cfg.retreat_villages)
            end

            if eval_hold then
                local hold_x = cfg.hold.x
                local hold_max_y = cfg.hold.max_y

                if (hold_y > hold_max_y) then hold_y = hold_max_y end
                local goal = { x = hold_x, y = hold_y }
                local zone = wesnoth.get_locations(cfg.zone_filter)
                for i,hex in ipairs(zone) do
                    local x, y = hex[1], hex[2]
                    if (y >= hold_y - 1) and (y <= hold_y + 1) then
                        --print(x,y)
                        local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(x, y)).village
                        if is_village then
                            goal = { x = x, y = y }
                            break
                        end
                    end
                end
                --print('goal:', goal.x, goal.y)

                local action = { units = {}, dsts = {} }
                action.units[1], action.dsts[1] = grunt_rush_FLS1:hold_zone(holders, goal, cfg)
                action.action = cfg.zone_id .. ': ' .. 'hold position'
                return action
            end

            -- If we got here, check whether there are instruction to secure the zone
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

        function grunt_rush_FLS1:get_zone_action(cfg, i_c)
            -- Find the best action to do in the zone described in 'cfg'
            -- This is all done together in one function, rather than in separate CAs so that
            --  1. Zones get done one at a time (rather than one CA at a time)
            --  2. Relative scoring of different types of moves is possible
            -- i_c: the index for the global 'parms' array, so that parameters can be set for the correct zone

            cfg = cfg or {}

            -- First, set up the general filters and tables, to be used by all actions

            -- Unit filter:
            -- This includes the leader.  Needs to be excluded specifically if he shouldn't take part in an action
            local unit_filter = { side = wesnoth.current.side }
            if cfg.unit_filter then
                for k,v in pairs(cfg.unit_filter) do unit_filter[k] = v end
            end
            --DBG.dbms(unit_filter)
            local all_units = AH.get_live_units(unit_filter)
            local zone_units, zone_units_noMP = {}, {}
            for i,u in ipairs(all_units) do
                if (u.moves > 0) then
                    table.insert(zone_units, u)
                else
                    table.insert(zone_units_noMP, u)
                end
            end

            if (not zone_units[1]) then return end

            -- Then get all the enemies (this needs to be all of them, to get the HP ratio)
            local enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }
            --print('#zone_units, #enemies', #zone_units, #enemies)

            -- Get all the hexes in the zone
            local zone = wesnoth.get_locations(cfg.zone_filter)
            local zone_map = LS.of_pairs(zone)

            -- Get HP ratio and number of units that can reach the zone as function of y coordinate
            local rel_damage_y = grunt_rush_FLS1:relative_damage_y(zone_units, enemies, zone)

            -- Start with the minimum for the zone
            local y_min = 9e99
            if cfg.hold and cfg.hold.min_y then
                y_min = cfg.hold.min_y
            else
                for y,rd_y in pairs(rel_damage_y) do
                    if (y < y_min) then y_min = y end
                end
            end

            local advance_y = y_min
            local min_relative_damage = cfg.min_relative_damage or 0.
            for y,rd_y in pairs(rel_damage_y) do
                if (y > advance_y) then
                    if (rd_y >= min_relative_damage) then advance_y = y end
                end
            end
            --print('advance_y zone #' .. i_c, advance_y)

            -- advance_y can never be less than what has been used during this move already
            if grunt_rush_FLS1.data.zone_parms[i_c].advance_y then
                if (grunt_rush_FLS1.data.zone_parms[i_c].advance_y > advance_y) then
                    advance_y = grunt_rush_FLS1.data.zone_parms[i_c].advance_y
                else
                    grunt_rush_FLS1.data.zone_parms[i_c].advance_y = advance_y
                end
            else
                grunt_rush_FLS1.data.zone_parms[i_c].advance_y = advance_y
            end
            --print('advance_y zone ' .. cfg.zone_id, advance_y)

            -- **** This ends the common initialization for all zone actions ****

            -- **** Retreat severely injured units evaluation ****
            if (not cfg.do_action) or cfg.do_action.retreat_injured then
                if (not cfg.skip_action) or (not cfg.skip_action.retreat_injured)  then
                    local action = grunt_rush_FLS1:zone_action_retreat_injured(zone_units, cfg)
                    if action then
                        --print(action.action)
                        return action
                    end
                end
            end

            -- **** Villages evaluation -- unowned and enemy-owned villages ****
            local village_action = nil
            if (not cfg.do_action) or cfg.do_action.villages then
                if (not cfg.skip_action) or (not cfg.skip_action.villages)  then
                    village_action = grunt_rush_FLS1:zone_action_villages(zone_units, enemies, cfg)
                    if village_action and (village_action.rating > 100) then
                        --print(village_action.action)
                        return village_action
                    end
                end
            end

            -- **** Attack evaluation ****
            if (not cfg.do_action) or cfg.do_action.attack then
                if (not cfg.skip_action) or (not cfg.skip_action.attack)  then
                    local action = grunt_rush_FLS1:zone_action_attack(zone_units, enemies, zone, zone_map, advance_y, cfg)
                    if action then
                        --print(action.action)
                        return action
                    end
                end
            end

            -- **** Grab threatened villages ****
            if village_action then
                if cfg.villages and cfg.villages.hold_threatened then
                    village_action.action = village_action.action .. ' (threatened village)'
                    --print(village_action.action)
                    return village_action
                end
            end

            -- **** Hold position evaluation ****
            if (not cfg.do_action) or cfg.do_action.hold then
                if (not cfg.skip_action) or (not cfg.skip_action.hold)  then
                    local action = grunt_rush_FLS1:zone_action_hold(zone_units, zone_units_noMP, enemies, zone_map, advance_y, cfg)
                    if action then
                        --print(action.action)
                        return action
                    end
                end
            end

            return nil  -- This is technically unnecessary
        end

        function grunt_rush_FLS1:zone_control_eval()
            local score_zone_control = 350000
            local start_time, ca_name = os.clock(), 'zone_control'
            if AH.print_eval() then print('     - Evaluating zone_control CA:', os.clock()) end

            -- Skip this if AI is much stronger than enemy
            if grunt_rush_FLS1:full_offensive() then
                AH.done_eval_messages(start_time, ca_name)
                return 0
            end

            local cfgs = grunt_rush_FLS1:get_zone_cfgs()

            for i_c,cfg in ipairs(cfgs) do
                --print('zone_control: ', cfg.zone_id, os.clock())
                local zone_action = grunt_rush_FLS1:get_zone_action(cfg, i_c)

                if zone_action then
                    grunt_rush_FLS1.data.zone_action = zone_action
                    AH.done_eval_messages(start_time, ca_name)
                    if (os.clock() - start_time > 10) then
                        W.message{ speaker = 'narrator', message = 'This took a really long time (which it should not).  If you can, would you mind sending us a screen grab of this situation?  Thanks!' }
                    end
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
                    --print('-------------------->  This is the leader.  Recruit first.')
                    if AH.show_messages() then W.message { speaker = unit.id, message = 'The leader is about to move.  Need to recruit first.' } end

                    while grunt_rush_FLS1:recruit_rushers_eval() > 0 do
                        if not grunt_rush_FLS1:recruit_rushers_exec() then
                            break
                        end
                    end
                end

                if AH.print_exec() then print('   ' .. os.clock() .. ' Executing zone_control CA ' .. action) end
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
                    local counter_min_hp, counter_def_stats = grunt_rush_FLS1:calc_counter_attack(attacker, { a.dst.x, a.dst.y })
                    --print('Poison counter attack:', attacker.id, a.dst.x, a.dst.y, counter_def_stats.hp_chance[0], counter_def_stats.average_hp)
                    -- Use a condition when damage is too much to be worthwhile
                    if (counter_def_stats.hp_chance[0] > 0.30) or (counter_def_stats.average_hp < 10) then
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

                    -- Also want to attack from the strongest possible terrain
                    local attack_defense = 100 - wesnoth.unit_defense(attacker, wesnoth.get_terrain(a.dst.x, a.dst.y))
                    rating = rating + attack_defense / 2.
                    --print('rating', rating, attacker.id, a.dst.x, a.dst.y)

                    -- And from village everything else being equal
                    local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(a.dst.x, a.dst.y)).village
                    if is_village then rating = rating + 0.5 end

                    -- Minor penalty if unit needs to be moved out of the way
                    if a.attack_hex_occupied then rating = rating - 0.1 end

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

        return grunt_rush_FLS1
    end
}
