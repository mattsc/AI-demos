return {
    init = function(ai)

        local grunt_rush_FLS1 = {}
        -- Specialized grunt rush for Freelands map, Side 1 only

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        local LS = wesnoth.require "lua/location_set.lua"
        local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"
        local RFH = wesnoth.require "~/add-ons/AI-demos/lua/recruit_filter_helper.lua"

        --------------------------------------------------------------------
        -- This is customized for Northerners on Freelands, playing Side 1
        --------------------------------------------------------------------

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
            return my_hp / (enemy_hp + 1e-6)
        end

        function grunt_rush_FLS1:hp_ratio_y(my_units, enemies, x_min, x_max, y_min, y_max)
            -- HP ratio as function of y coordinate
            -- This is the maximum of total HP of all units that can get to any hex with the given y

            --print('#my_units, #enemies', #my_units, #enemies)
            local attack_map = AH.attack_map(my_units, { return_value = 'hitpoints' })
            local enemy_attack_map = AH.attack_map(enemies, { moves = "max", return_value = 'hitpoints' })
            --AH.put_labels(enemy_attack_map)

            local hp_y, enemy_hp_y, hp_ratio = {}, {}, {}
            for y = y_min,y_max do
                hp_y[y], enemy_hp_y[y] = 0, 0
                for x = x_min,x_max do
                    local hp = attack_map:get(x,y) or 0
                    if (hp > hp_y[y]) then hp_y[y] = hp end
                    local enemy_hp = enemy_attack_map:get(x,y) or 0
                    if (enemy_hp > enemy_hp_y[y]) then enemy_hp_y[y] = enemy_hp end
                end
                hp_ratio[y] = hp_y[y] / (enemy_hp_y[y] + 1e-6)
            end

            return hp_ratio
        end

        function grunt_rush_FLS1:full_offensive()
            -- Returns true if the conditions to go on all-out offensive are met
            -- 1. If Turn >= 16 and HP ratio > 1.5
            -- 2. IF HP ratio > 2 under all circumstance (well, starting from Turn 3, to avoid problems at beginning)

            if (self:hp_ratio() > 1.5) and (wesnoth.current.turn >= 16) then return true end
            if (self:hp_ratio() > 2.0) and (wesnoth.current.turn >= 3) then return true end
            return false
        end

        function grunt_rush_FLS1:best_trapping_attack_opposite(units_org, enemies_org)
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
                if (units[i].__cfg.level == 0) then
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
            for i,e in ipairs(enemies) do
                --print('\n', i, e.id)
                local attack_combos, attacks_dst_src = AH.get_attack_combos_no_order(units, e)
                --DBG.dbms(attack_combos)
                --DBG.dbms(attacks_dst_src)
                --print('#attack_combos', #attack_combos)

                local enemy_on_village = wesnoth.get_terrain_info(wesnoth.get_terrain(e.x, e.y)).village
                local enemy_cost = e.__cfg.cost

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
                        if opp_unit and (opp_unit.moves == 0) and (opp_unit.side == wesnoth.current.side) and (opp_unit.__cfg.level > 0) then
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
                    if trapping_attack then
                        for dst,src in pairs(combo) do
                            local att = wesnoth.get_unit(math.floor(src / 1000), src % 1000)
                            table.insert(attackers, att)
                            table.insert(dsts, { math.floor(dst / 1000), dst % 1000 })
                        end
                        attackers, dsts, combo_def_stats, combo_att_stats = AH.attack_combo_stats(attackers, dsts, e)
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
                    for i_a,a in ipairs(attackers) do
                        local counter_table = self:calc_counter_attack(a, dsts[i_a])
                        --DBG.dbms(counter_table)
                        --print(a.id, dsts[i_a][1], dsts[i_a][2], counter_table.average_def_stats.hp_chance[0],  counter_table.average_def_stats.average_hp)
                        -- Use a condition when damage is too much to be worthwhile
                        if (counter_table.average_def_stats.hp_chance[0] > 0.30) or (counter_table.average_def_stats.average_hp < 10) then
                            --print('Trapping attack too dangerous')
                            trapping_attack = false
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
                            rating = rating - attackers[i_a].__cfg.cost
                            -- Own unit on village gets bonus too
                            local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(dsts[i_a][1], dsts[i_a][2])).village
                            if is_village then rating = rating + 20 end

                            -- Minor penalty if a unit needs to be moved (that is not the attacker itself)
                            local unit_in_way = wesnoth.get_unit(dsts[i_a][1], dsts[i_a][2])
                            if unit_in_way and ((unit_in_way.x ~= attackers[i_a].x) or (unit_in_way.y ~= attackers[i_a].y)) then
                                rating = rating - 0.01
                            end
                        end

                        --print(' -----------------------> zoc attack rating', rating)
                        if (rating > max_rating) then
                            max_rating, best_attackers, best_dsts, best_enemy = rating, attackers, dsts, e
                        end
                    end
                end
            end
            --print('max_rating ', max_rating)

            if (max_rating > -9e99) then
                return best_attackers, best_dsts, best_enemy
            end
            return nil
        end

        function grunt_rush_FLS1:hold_position(units, goal, cfg)
            -- Set up a defensive position at (goal.x, goal.y) using 'units'
            -- goal should be a village or an otherwise strong position, or this doesn't make sense
            -- cfg: table with additional parameters:
            --   ignore_terrain_at_night: if true, terrain has (almost) no influence on choosing positions for 
            --     close units

            cfg = cfg or {}

            -- If this is a village, we try to hold the position itself,
            -- otherwise just set up position around it
            local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(goal.x, goal.y)).village

            -- If a unit is there already, simply hold the position
            -- Later we can add something for switching it for a better unit, if desired
            if is_village then
                local unit_at_goal = wesnoth.get_unit(goal.x, goal.y)
                if unit_at_goal and (unit_at_goal.side == wesnoth.current.side) and (unit_at_goal.moves > 0) then
                    ai.stopunit_moves(unit_at_goal)
                    return
                end

                -- If we got here, we'll check if one of our units can get to the goal
                -- If so, we take the strongest and farthest away
                local max_rating, best_unit = -9e99, {}
                if (not unit_at_goal) then
                    for i,u in ipairs(units) do
                        local path, cost = wesnoth.find_path(u, goal.x, goal.y)
                        if (cost <= u.moves) then
                            local rating = u.hitpoints + H.distance_between(u.x, u.y, goal.x, goal.y) / 100.
                            if (rating > max_rating) then
                                max_rating, best_unit = rating, u
                            end
                        end
                    end
                end
                if max_rating > -9e99 then
                    AH.movefull_outofway_stopunit(ai, best_unit, goal)
                    return
                end
           end

            -- At this point, if it were possible to get a unit to the goal, it would have happened
            -- (or the goal is not a village)
            -- Split up units into those that can get within one move of goal, and those that cannot
            local far_units, close_units = {}, {}
            for i,u in ipairs(units) do
                local path, cost = wesnoth.find_path(u, goal.x, goal.y, { ignore_units = true } )
                if (cost < u.moves * 2) then
                    table.insert(close_units, u)
                else                    
                    table.insert(far_units, u)
                end
            end
            --print('#far_units, #close_units', #far_units, #close_units)

            -- At this point, if there's an enemy at the goal hex, need to find a different goal
            if unit_at_goal and (unit_at_goal.side ~= wesnoth.current.side) then
                goal.x, goal.y = wesnoth.find_vacant_tile(goal.x, goal.y)
            end

            -- The close units are moved first
            if close_units[1] then
                local max_rating, best_hex, best_unit = -9e99, {}, {}
                for i,u in ipairs(close_units) do
                    local reach_map = AH.get_reachable_unocc(u)
                    reach_map:iter( function(x, y, v)
                        local rating = 0
                        local dist = H.distance_between(x, y, goal.x, goal.y)
                        if (dist <= -1) or (y > goal.y + 1) then rating = rating - 1000 end
                        rating = rating - dist

                        local x1, y1 = u.x, u.y
                        wesnoth.extract_unit(u)
                        u.x, u.y = x, y
                        local path, cost = wesnoth.find_path(u, goal.x, goal.y, { ignore_units = true } )
                        wesnoth.put_unit(x1, y1, u)
                        if cost > u.moves then rating = rating - 1000 end

                        -- Small bonus if this is on a village
                        local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(x, y)).village
                        if is_village then rating = rating + 2.1 end

                        -- Take southern and eastern units first
                        rating = rating + u.y + u.x / 2.

                        local terrain_weighting = 0.333
                        if cfg.ignore_terrain_at_night then
                            local tod = wesnoth.get_time_of_day()
                            if (tod.id == 'dusk') or (tod.id == 'first_watch') or (tod.id == 'second_watch') then
                                terrain_weighting = 0.01
                            end
                        end

                        local defense = 100 - wesnoth.unit_defense(u, wesnoth.get_terrain(x, y))
                        rating = rating + defense * terrain_weighting

                        -- Finally, in general, the farther south the better (map specific, of course)
                        rating = rating + y

                        if (rating > max_rating) then
                            max_rating, best_hex, best_unit = rating, { x, y }, u
                        end
                    end)
                end

                if AH.show_messages() then W.message { speaker = best_unit.id, message = 'Hold position: Moving close unit' } end
                AH.movefull_outofway_stopunit(ai, best_unit, best_hex)
                return
            end

            -- Then the far units

            local enemies = AH.get_live_units {
                { "filter_side", { { "enemy_of", {side = wesnoth.current.side} } } }
            }
            local enemy_attack_map = AH.attack_map(enemies, { moves = 'max' })

            if far_units[1] then
                local max_rating, best_hex, best_unit = -9e99, {}, {}
                for i,u in ipairs(far_units) do

                    local next_hop = AH.next_hop(u, goal.x, goal.y)
                    if (not next_hop) then next_hop = { goal.x, goal.y } end

                    -- Is there a threat on the next_hop position?
                    -- If so, take terrain into account (for all hexes for that unit)
                    local enemy_threat = enemy_attack_map:get(next_hop[1], next_hop[2])
                    if (not enemy_threat) then enemy_threat = 0 end

                    local reach_map = AH.get_reachable_unocc(u)
                    reach_map:iter( function(x, y, v)
                        local rating = - H.distance_between(x, y, next_hop[1], next_hop[2])

                        if enemy_threat > 1 then
                            -- Small bonus if this is on a village
                            local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(x, y)).village
                            if is_village then rating = rating + 1.1 end

                            local terrain_weighting = 0.111
                            if cfg.ignore_terrain_at_night then
                                local tod = wesnoth.get_time_of_day()
                                if (tod.id == 'dusk') or (tod.id == 'first_watch') or (tod.id == 'second_watch') then
                                    terrain_weighting = 0.01
                                end
                            end

                            local defense = 100 - wesnoth.unit_defense(u, wesnoth.get_terrain(x, y))
                            rating = rating + defense * terrain_weighting
                        end

                        -- However, if 3 or more enemies can get there, strongly disfavor this
                        if enemy_threat > 2 then
                            rating = rating - 1000 * enemy_threat
                        end

                        -- Take southern and eastern units first
                        rating = rating + u.y + u.x / 2.

                        if (rating > max_rating) then
                            max_rating, best_hex, best_unit = rating, { x, y }, u
                        end
                    end)
                end

                if (max_rating > -9e99) then
                    if AH.show_messages() then W.message { speaker = best_unit.id, message = 'Hold position: Moving far unit ' .. goal.x .. ',' .. goal.y } end
                    AH.movefull_outofway_stopunit(ai, best_unit, best_hex)
                    return
                end
            end
        end

        function grunt_rush_FLS1:calc_counter_attack(unit, hex)
            -- Get counter attack results a 'unit' might experience next turn if it moved to 'hex'
            -- Return table contains fields:
            --   max_counter_damage: the maximum counter attack damage that could potentially be done
            --   enemy_attackers: a table containing the coordinates of all enemy units that could attack
            --   average_def_stats: the defender stats (in some average sense) after all those attacks

            -- All enemy units
            local enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", { side = unit.side } }} }
            }
            --print('#enemies', #enemies)

            -- Need to take units with MP off the map for this
            local units_MP = wesnoth.get_units { side = unit.side, formula = '$this_unit.moves > 0' }
            for iu,uMP in ipairs(units_MP) do wesnoth.extract_unit(uMP) end

            -- Now find the enemies that can attack 'hex'
            local enemy_attackers = {}
            for i,e in ipairs(enemies) do
                local attack_map = AH.get_reachable_attack_map(e, {moves = "max"})
                if attack_map:get(hex[1], hex[2]) then
                    --print('Can attack this hex:', e.id)
                    table.insert(enemy_attackers, e)
                end
            end
            --print('#enemy_attackers', #enemy_attackers)

            -- Put the units back out there
            for iu,uMP in ipairs(units_MP) do wesnoth.put_unit(uMP.x, uMP.y, uMP) end

            -- Set up the return array
            local counter_table = {}
            counter_table.enemy_attackers = {}
            for i,e in ipairs(enemy_attackers) do table.insert(counter_table.enemy_attackers, { e.x, e.y }) end

            -- Now we calculate the maximum counter attack damage for each of those attackers
            -- We first need to put our unit into the position of interest
            -- (and remove any unit that might be there)
            local org_hex = { unit.x, unit.y }
            local unit_in_way = {}
            if (org_hex[1] ~= hex[1]) or (org_hex[2] ~= hex[2]) then
                unit_in_way = wesnoth.get_unit(hex[1], hex[2])
                if unit_in_way then wesnoth.extract_unit(unit_in_way) end

                wesnoth.put_unit(hex[1], hex[2], unit)
            end

            -- Now simulate all the attacks on 'unit' on 'hex'
            local max_counter_damage = 0
            for i,e in ipairs(enemy_attackers) do
                --print('Evaluating counter attack attack by: ', e.id)

                local n_weapon = 0
                local min_hp = unit.hitpoints
                for weapon in H.child_range(e.__cfg, "attack") do
                    --print('  weapon #', n_weapon)
                    n_weapon = n_weapon + 1

                    -- Terrain enemy is on does not matter for this, we're only interested in the damage done to 'unit'
                    local att_stats, def_stats = wesnoth.simulate_combat(e, n_weapon, unit)

                    -- Find minimum HP of our unit
                    -- find the minimum hp outcome
                    -- Note: cannot use ipairs() because count starts at 0
                    local min_hp_weapon = unit.hitpoints
                    for hp,chance in pairs(def_stats.hp_chance) do
                        if ((chance > 0) and (hp < min_hp_weapon)) then
                            min_hp_weapon = hp
                        end
                    end
                    if (min_hp_weapon < min_hp) then min_hp = min_hp_weapon end
                end
                --print('    min_hp:',min_hp, ' max damage:',unit.hitpoints-min_hp)
                max_counter_damage = max_counter_damage + unit.hitpoints - min_hp
            end
            --print('  max counter attack damage:', max_counter_damage)

            -- Put units back to where they were
            if (org_hex[1] ~= hex[1]) or (org_hex[2] ~= hex[2]) then
                wesnoth.put_unit(org_hex[1], org_hex[2], unit)
                if unit_in_way then wesnoth.put_unit(hex[1], hex[2], unit_in_way) end
            end
            counter_table.max_counter_damage = max_counter_damage

            -- Also calculate median counter attack results
            -- using the ai_helper function (might not be most efficient, but good for now)
            local dsts = {}
            for i,e in ipairs(enemy_attackers) do table.insert(dsts, { e.x, e.y }) end
            -- only need the defender stats
            local tmp1, tmp2, def_stats = AH.attack_combo_stats(enemy_attackers, dsts, unit)

            counter_table.average_def_stats = def_stats

            return counter_table
        end

        function grunt_rush_FLS1:get_attack_with_counter_attack(unit)
            -- Return best attack for 'unit', if counter attack on next enemy turn will definitely not kill it
            -- Returns the best attack, or otherwise nil
            -- For now, this is separate from the previous function for speed and efficiency reasons

            local attacks = AH.get_attacks_occupied({unit})

            if (not attacks[1]) then return end
            --print('#attacks',#attacks,ids)
            --DBG.dbms(attacks)

            -- All enemy units
            local enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", { side = unit.side } }} }
            }

            -- For counter attack damage calculation:
            -- Find all hexes enemies can attack on their next turn

            -- Need to take units with MP off the map for this
            local units_MP = wesnoth.get_units { side = unit.side, canrecruit = 'no', 
                formula = '$this_unit.moves > 0'
            }
            for iu,uMP in ipairs(units_MP) do wesnoth.extract_unit(uMP) end

            local enemy_attacks = {}
            for i,e in ipairs(enemies) do
                local attack_map = AH.get_reachable_attack_map(e, {moves = "max"})
                table.insert(enemy_attacks, { enemy = e, attack_map = attack_map })
            end

            for iu,uMP in ipairs(units_MP) do wesnoth.put_unit(uMP.x, uMP.y, uMP) end

            -- Set up a counter attack table, as many pairs of attacks will be the same (for speed reasons)
            local counter_table = {}

            -- Now evaluate every attack
            local max_rating, best_attack = -9e99, {}
            for i,a in pairs(attacks) do
                --print('  chance to die:',a.att_stats.hp_chance[0])

                -- Only consider if there is no chance to die or to be poisoned or slowed
                if ((a.att_stats.hp_chance[0] == 0) and (a.att_stats.poisoned == 0) and (a.att_stats.slowed == 0)) then

                    -- Get maximum possible counter attack damage possible by enemies on next turn
                    local max_counter_damage = 0

                    for j,ea in ipairs(enemy_attacks) do
                        local can_attack = ea.attack_map:get(a.x, a.y)
                        if can_attack then

                            -- Check first if this attack combination has already been calculated
                            local str = (a.att_loc.x + a.att_loc.y * 1000) .. '-' .. (a.def_loc.x + a.def_loc.y * 1000)
                            --print(str)
                            if counter_table[str] then  -- If so, use saved value
                                --print('    counter attack already calculated: ',str,counter_table[str])
                                max_counter_damage = max_counter_damage + counter_table[str]
                            else  -- if not, calculate it and save value
                                -- Go thru all weapons, as "best weapon" might be different later on
                                local n_weapon = 0
                                local min_hp = unit.hitpoints
                                for weapon in H.child_range(ea.enemy.__cfg, "attack") do
                                    n_weapon = n_weapon + 1

                                    -- Terrain does not matter for this, we're only interested in the maximum damage
                                    local att_stats, def_stats = wesnoth.simulate_combat(ea.enemy, n_weapon, unit)

                                    -- Find minimum HP of our unit
                                    -- find the minimum hp outcome
                                    -- Note: cannot use ipairs() because count starts at 0
                                    local min_hp_weapon = unit.hitpoints
                                    for hp,chance in pairs(def_stats.hp_chance) do
                                        if ((chance > 0) and (hp < min_hp_weapon)) then
                                            min_hp_weapon = hp
                                        end
                                    end
                                    if (min_hp_weapon < min_hp) then min_hp = min_hp_weapon end
                                end
                                --print('    min_hp:',min_hp, ' max damage:',unit.hitpoints-min_hp)
                                max_counter_damage = max_counter_damage + unit.hitpoints - min_hp
                                counter_table[str] = unit.hitpoints - min_hp
                            end
                        end
                    end
                    --print('  max counter attack damage:', max_counter_damage)

                    -- and add this to damage possible on this attack
                    -- Note: cannot use ipairs() because count starts at 0
                    local min_hp = 1000
                    for hp,chance in pairs(a.att_stats.hp_chance) do
                        --print(hp,chance)
                        if ((chance > 0) and (hp < min_hp)) then
                            min_hp = hp
                        end
                    end
                    local min_outcome = min_hp - max_counter_damage
                    --print('  min hp this attack:',min_hp)
                    --print('  ave hp defender:   ',a.def_stats.average_hp)
                    --print('  min_outcome',min_outcome)

                    -- If this is >0, consider the attack
                    if (min_outcome > 0) then
                        local rating = min_outcome + a.att_stats.average_hp - a.def_stats.average_hp

                        local attack_defense = 100 - wesnoth.unit_defense(unit, wesnoth.get_terrain(a.x, a.y))
                        rating = rating + attack_defense / 10.

                        if unit.canrecruit then
                            if wesnoth.get_terrain_info(wesnoth.get_terrain(a.x, a.y)).keep then
                                rating = rating + 5
                            end
                        end

                        -- Minor penalty if the attack hex is occupied
                        if a. attack_hex_occupied then rating = rating - 0.01 end

                        --print('  rating:',rating,'  min_outcome',min_outcome)
                        if (rating > max_rating) then
                            max_rating, best_attack = rating, a
                        end
                    end

                end
            end
            --print('Max_rating:', max_rating)

            if (max_rating > -9e99) then return best_attack end
        end

        ------ Stats at beginning of turn -----------

        -- This will be blacklisted after first execution each turn
        function grunt_rush_FLS1:stats_eval()
            local score = 999999
            return score
        end

        function grunt_rush_FLS1:stats_exec()
            local tod = wesnoth.get_time_of_day()
            print(' Beginning of Turn ' .. wesnoth.current.turn .. ' (' .. tod.name ..') stats:')

            for i,s in ipairs(wesnoth.sides) do
                local total_hp = 0
                local units = AH.get_live_units { side = s.side }
                for i,u in ipairs(units) do total_hp = total_hp + u.hitpoints end
                print('   Player ' .. s.side .. ': ' .. #units .. ' Units with total HP: ' .. total_hp)
            end
            if self:full_offensive() then print(' Full offensive mode (mostly done by RCA AI)') end
        end

        ------ Reset variables at beginning of turn -----------

        -- This will be blacklisted after first execution each turn
        function grunt_rush_FLS1:reset_vars_eval()
            -- Probably not necessary, just a safety measure
            local score = 999998
            return score
        end

        function grunt_rush_FLS1: reset_vars_exec()
            --print(' Resetting variables at beginning of Turn ' .. wesnoth.current.turn)

            -- Reset self.data at beginning of turn, but need to keep 'complained_about_luck' variable
            local complained_about_luck = self.data.SP_complained_about_luck
            self.data = {}
            self.data.SP_complained_about_luck = complained_about_luck
        end

        ------ Hard coded -----------

        function grunt_rush_FLS1:hardcoded_eval()
            local score = 500000
            if AH.print_eval() then print('     - Evaluating hardcoded CA:', os.clock()) end

            -- To make sure we have a wolf rider and a grunt in the right positions on Turn 1

            if (wesnoth.current.turn == 1) then
                local unit = wesnoth.get_unit(17,5)
                if (not unit) then
                    if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                    return score
                end
            end

            -- Move 2 units to the left
            if (wesnoth.current.turn == 2) then
                local unit = wesnoth.get_unit(17,5)
                if unit and (unit.moves >=5) then
                    if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                    return score
                end
            end

            -- Move 3 move the orc
            if (wesnoth.current.turn == 3) then
                local unit = wesnoth.get_unit(12,5)
                if unit and (unit.moves >=5) then
                    if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                    return score
                end
            end
            if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
            return 0
        end

        function grunt_rush_FLS1:hardcoded_exec()
            if AH.print_exec() then print('     - Executing hardcoded CA') end
            if AH.show_messages() then W.message { speaker = 'narrator', message = 'Executing hardcoded move(s)' } end
            if (wesnoth.current.turn == 1) then
                ai.recruit('Orcish Grunt', 17, 5)
                ai.recruit('Wolf Rider', 18, 4)
                ai.recruit('Orcish Archer', 20, 3)
                ai.recruit('Orcish Assassin', 20, 4)
            end
            if (wesnoth.current.turn == 2) then
                ai.move_full(17, 5, 12, 5)
                ai.move_full(18, 4, 12, 2)
                ai.move_full(20, 4, 24, 7)
            end
            if (wesnoth.current.turn == 3) then
                ai.move_full(12, 5, 11, 9)
            end
        end

        ------ Move leader to keep -----------

        function grunt_rush_FLS1:move_leader_to_keep_eval()
            local score = 480000
            if AH.print_eval() then print('     - Evaluating move_leader_to_keep CA:', os.clock()) end

            -- Move of leader to keep is done by hand here
            -- as we want him to go preferentially to (18,4) not (19.4)

            local leader = wesnoth.get_units{ side = wesnoth.current.side, canrecruit = 'yes',
                formula = '$this_unit.attacks_left > 0'
            }[1]
            if (not leader) then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end

            local keeps = { { 18, 4 }, { 19, 4 } }  -- keep hexes in order of preference

            -- We move the leader to the keep if
            -- 1. It's available
            -- 2. The leader can get there in one move
            for i,k in ipairs(keeps) do
                if (leader.x ~= k[1]) or (leader.y ~= k[2]) then
                    local unit_in_way = wesnoth.get_unit(k[1], k[2])
                    if (not unit_in_way) then
                        local next_hop = AH.next_hop(leader, k[1], k[2])
                        if next_hop and (next_hop[1] == k[1]) and (next_hop[2] == k[2]) then
                            self.data.MLK_leader = leader
                            self.data.MLK_leader_move = { k[1], k[2] }
                            if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                            return score
                        end
                    end
                else -- If the leader already is on the keep, don't consider lesser priority ones
                    if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                    return 0
                end
            end

            if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
            return 0
        end

        function grunt_rush_FLS1:move_leader_to_keep_exec()
            if AH.print_exec() then print('     - Executing move_leader_to_keep CA') end
            if AH.show_messages() then W.message { speaker = self.data.MLK_leader.id, message = 'Moving back to keep' } end
            -- This has to be a partial move !!
            ai.move(self.data.MLK_leader, self.data.MLK_leader_move[1], self.data.MLK_leader_move[2])
            self.data.MLK_leader, self.data.MLK_leader_move = nil, nil
        end

        ------ Retreat injured units -----------

        function grunt_rush_FLS1:retreat_injured_units_eval()
            local score = 470000
            if AH.print_eval() then print('     - Evaluating retreat_injured_units CA:', os.clock()) end

            -- Find very injured units and move them to a village, if possible
	    local units = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'no',
	        formula = '$this_unit.moves > 0'
	    }

            -- Pick units that have less than 12 HP
            -- with poisoning counting as -8 HP and slowed as -4
            local min_hp = 12  -- minimum HP before sending unit to village
            local healees = {}
            for i,u in ipairs(units) do
                local hp_eff = u.hitpoints
                if (hp_eff < min_hp + 8) then
                    if H.get_child(u.__cfg, "status").poisoned then hp_eff = hp_eff - 8 end
                end
                if (hp_eff < min_hp + 4) then
                    if H.get_child(u.__cfg, "status").slowed then hp_eff = hp_eff - 4 end
                end
                if (hp_eff < min_hp) then
                    table.insert(healees, u)
                end
            end
            --print('#healees', #healees)
            if (not healees[1]) then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end

	    local villages = wesnoth.get_locations { terrain = "*^V*" }
            --print('#villages', #villages)

            -- Only retreat to safe villages
            local enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }
            local enemy_attack_map = AH.attack_map(enemies, { moves = 'max' })

            local max_rating, best_village, best_unit = -9e99, {}, {}

            for i,v in ipairs(villages) do
                local unit_in_way = wesnoth.get_unit(v[1], v[2])
                if (not unit_in_way) then
                    --print('Village available:', v[1], v[2])
                    for i,u in ipairs(healees) do
                        local next_hop = AH.next_hop(u, v[1], v[2])
                        if next_hop and (next_hop[1] == v[1]) and (next_hop[2] == v[2]) then
                            --print('  can be reached by', u.id, u.x, u.y)
                            local rating = - u.hitpoints + u.max_hitpoints / 2.

                            if H.get_child(u.__cfg, "status").poisoned then rating = rating + 8 end
                            if H.get_child(u.__cfg, "status").slowed then rating = rating + 4 end

                            -- villages in the north are preferable (since they are supposedly away from the enemy)
                            rating = rating - v[2]

                            if (rating > max_rating) and ((enemy_attack_map:get(v[1], v[2]) or 0) <= 1 ) then
                                max_rating, best_village, best_unit = rating, v, u
                            end
                        end
                    end
                end
            end

            if (max_rating > -9e99) then
                self.data.RIU_retreat_unit, self.data.RIU_retreat_village = best_unit, best_village
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return score
            end

            if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
            return 0
        end

        function grunt_rush_FLS1:retreat_injured_units_exec()
            if AH.print_exec() then print('     - Executing retreat_injured_units CA') end
            if AH.show_messages() then W.message { speaker = self.data.RIU_retreat_unit.id, message = 'Retreating to village' } end
            AH.movefull_outofway_stopunit(ai, self.data.RIU_retreat_unit, self.data.RIU_retreat_village)
            self.data.RIU_retreat_unit, self.data.RIU_retreat_village = nil, nil
        end

        ------ Attack with high CTK -----------

        function grunt_rush_FLS1:attack_weak_enemy_eval()
            local score = 462000
            if AH.print_eval() then print('     - Evaluating attack_weak_enemy CA:', os.clock()) end

            -- Attack any enemy where the chance to kill is > 40%
            -- or if it's the enemy leader under all circumstances

            -- Check if there are units with attacks left
            local units = AH.get_live_units { side = wesnoth.current.side, canrecruit = 'no', 
                formula = '$this_unit.attacks_left > 0'
            }
            if (not units[1]) then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end

            local enemy_leader = AH.get_live_units { canrecruit = 'yes',
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }[1]

            -- First check if attacks with >= 40% CTK are possible for any unit
            -- and that AI unit cannot die
            local attacks = AH.get_attacks_occupied(units)
            if (not attacks[1]) then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end

            -- For counter attack damage calculation:
            local enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }
            local enemy_attack_map = AH.attack_map(enemies, {moves = "max"})
            --AH.put_labels(enemy_attack_map)

            local max_rating, best_attack = -9e99, {}
            for i,a in ipairs(attacks) do
                -- Check whether attack can result in kill with single hit
                local one_strike_kill, hp_levels = true, 0
                for i,c in pairs(a.def_stats.hp_chance) do
                    if (c > 0) and (i > 0) then 
                        hp_levels = hp_levels + 1
                        if (hp_levels > 1) then
                            one_strike_kill = false
                            break
                        end
                    end
                end

                if ( one_strike_kill
                    or (a.def_loc.x == enemy_leader.x) and (a.def_loc.y == enemy_leader.y) and (a.def_stats.hp_chance[0] > 0) )
                    or ( (a.def_stats.hp_chance[0] >= 0.40) and (a.att_stats.hp_chance[0] == 0) )
                then
                    local attacker = wesnoth.get_unit(a.att_loc.x, a.att_loc.y)

                    local rating = a.att_stats.average_hp - 2 * a.def_stats.average_hp
                    rating = rating + a.def_stats.hp_chance[0] * 50

                    rating = rating - (attacker.max_experience - attacker.experience) / 3.  -- the closer to leveling the unit is, the better

                    local attack_defense = 100 - wesnoth.unit_defense(attacker, wesnoth.get_terrain(a.x, a.y))
                    rating = rating + attack_defense / 100.
                    --print('    rating:', rating, a.x, a.y)

                    if (a.def_loc.x == enemy_leader.x) and (a.def_loc.y == enemy_leader.y) and (a.def_stats.hp_chance[0] > 0)
                    then rating = rating + 1000 end

                    -- Minor penalty if unit needs to be moved out of the way
                    -- This is essentially just to differentiate between otherwise equal attacks
                    if a.attack_hex_occupied then rating = rating - 0.1 end

                    -- From dawn to afternoon, only attack if not more than 2 other enemy units are close
                    -- (but only if this is not the enemy leader; we attack him unconditionally)
                    local enemies_in_reach = enemy_attack_map:get(a.x, a.y)
                    --print('  enemies_in_reach', enemies_in_reach)

                    -- Need '>3' here, because the weak enemy himself is counted also
                    if (enemies_in_reach > 3) and ((a.def_loc.x ~= enemy_leader.x) or (a.def_loc.y ~= enemy_leader.y)) then 
                        local tod = wesnoth.get_time_of_day()
                        if (tod.id == 'dawn') or (tod.id == 'morning') or (tod.id == 'afternoon') then
                            rating = -9e99
                        end
                    end

                    if (rating > max_rating) then
                        max_rating, best_attack = rating, a
                    end
                end
            end

            if (max_rating > -9e99) then
                self.data.AWE_attack = best_attack
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return score
            end

            if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
            return 0
        end

        function grunt_rush_FLS1:attack_weak_enemy_exec()
            if AH.print_exec() then print('     - Executing attack_weak_enemy CA') end

            local attacker = wesnoth.get_unit(self.data.AWE_attack.att_loc.x, self.data.AWE_attack.att_loc.y)
            local defender = wesnoth.get_unit(self.data.AWE_attack.def_loc.x, self.data.AWE_attack.def_loc.y)
            if AH.show_messages() then W.message { speaker = attacker.id, message = "Attacking weak enemy" } end
            AH.movefull_outofway_stopunit(ai, attacker, self.data.AWE_attack, { dx = 0.5, dy = -0.1 })
            ai.attack(attacker, defender)
        end

        ------ Attack by leader flag -----------

        function grunt_rush_FLS1:set_attack_by_leader_flag_eval()
            -- Sets a variable when attack by leader is imminent.
            -- In that case, recruiting needs to be done first
            local score = 460010
            if AH.print_eval() then print('     - Evaluating set_attack_by_leader_flag CA:', os.clock()) end

            -- We also add here (and, in fact, evaluate first) possible attacks by the leader
            -- Rate them very conservatively
            -- If leader can die this turn on or next enemy turn, it is not done, even if _really_ unlikely

            local leader = wesnoth.get_units{ side = wesnoth.current.side, canrecruit = 'yes',
                formula = '$this_unit.attacks_left > 0'
            }[1]

            -- Only consider attack by leader if he is on the keep, so that he doesn't wander off
            if leader and wesnoth.get_terrain_info(wesnoth.get_terrain(leader.x, leader.y)).keep then
                local best_attack = self:get_attack_with_counter_attack(leader)
                if best_attack and
                    (not wesnoth.get_terrain_info(wesnoth.get_terrain(best_attack.x, best_attack.y)).keep)
                then
                    if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                    return score
                end
            end

            if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
            return 0
        end

        function grunt_rush_FLS1:set_attack_by_leader_flag_exec()
            if AH.print_exec() then print('     - Setting leader attack in attack_by_leader_flag_exec()') end
            self.data.attack_by_leader_flag = true
        end

        ------ Attack leader threats -----------

        function grunt_rush_FLS1:attack_leader_threat_eval()
            local score = 460000
            if AH.print_eval() then print('     - Evaluating attack_leader_threat CA:', os.clock()) end

            -- Attack enemies that have made it too far north
            -- They don't have to be within reach of leader yet, but those get specific priority

            -- We also add here (and, in fact, evaluate first) possible attacks by the leader
            -- Rate them very conservatively
            -- If leader can die this turn on or next enemy turn, it is not done, even if _really_ unlikely

            local leader = wesnoth.get_units{ side = wesnoth.current.side, canrecruit = 'yes',
                formula = '$this_unit.attacks_left > 0'
            }[1]

            -- Only consider attack by leader if he is on the keep, so that he doesn't wander off
            if leader and wesnoth.get_terrain_info(wesnoth.get_terrain(leader.x, leader.y)).keep then
                local best_attack = self:get_attack_with_counter_attack(leader)
                if best_attack then
                    self.data.ALT_best_attack = best_attack
                    if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                    return score
                end
            end

            -- If we got here, that means no suitable attack was found for the leader
            -- So we look into attacks by the other units
            local enemies = AH.get_live_units { x = '1-16,17-37', y = '1-7,1-10',
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }
            if (not enemies[1]) then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end

            local units = AH.get_live_units { side = wesnoth.current.side, canrecruit = 'no', 
                formula = '$this_unit.attacks_left > 0'
            }
            if (not units[1]) then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end

            local units_MP = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'no', 
                formula = '$this_unit.moves > 0'
            }
            --print('#enemies, #units, #units_MP', #enemies, #units, #units_MP)

            -- Check first if a trapping attack is possible
            local attackers, dsts, enemy = self:best_trapping_attack_opposite(units, enemies)
            if attackers then
                self.data.ALT_trapping_attackers = attackers
                self.data.ALT_trapping_dsts = dsts
                self.data.ALT_trapping_enemy = enemy
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return score
            end

            -- Now check if attacks on any of these units is possible
            local attacks = AH.get_attacks_occupied(units)
            if (not attacks[1]) then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end
            --print('#attacks', #attacks)

            local leader = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]

            local max_rating, best_attack = -9e99, {}
            for i,a in ipairs(attacks) do
                for j,e in ipairs(enemies) do
                    if (a.def_loc.x == e.x) and (a.def_loc.y == e.y) then
                        local attacker = wesnoth.get_unit(a.att_loc.x, a.att_loc.y)

                        local damage = attacker.hitpoints - a.att_stats.average_hp
                        local enemy_damage = e.hitpoints - a.def_stats.average_hp

                        local rating = enemy_damage * 4 - damage * 2 
                        rating = rating + a.att_stats.average_hp - 2 * a.def_stats.average_hp
                        rating = rating + a.def_stats.hp_chance[0] * 50
                        rating = rating - a.att_stats.hp_chance[0] * 50
                        --print(attacker.id, e.id, rating, damage, enemy_damage)

                        -- The farther north and west the unit is, the better
                        local pos_north = - (a.att_loc.x + a.att_loc.y) * 3
                        rating = rating + pos_north

                        -- Minor penalty if unit needs to be moved out of the way
                        -- This is essentially just to differentiate between otherwise equal attacks
                        if a.attack_hex_occupied then rating = rating - 0.1 end

                        -- Also position ourselves in between enemy and leader
                        rating = rating - H.distance_between(a.x, a.y, leader.x, leader.y)

                        local attack_defense = 100 - wesnoth.unit_defense(attacker, wesnoth.get_terrain(a.x, a.y))
                        rating = rating + attack_defense / 9.

                        -- Large bonus if this is on a village
                        local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(a.x, a.y)).village
                        if is_village then rating = rating + 100 end

                        -- Also somewhat of a bonus if the enemy is on a village
                        local enemy_on_village = wesnoth.get_terrain_info(wesnoth.get_terrain(a.def_loc.x, a.def_loc.y)).village
                        if enemy_on_village then rating = rating + 10 end

                        -- Closeness of enemy to leader is most important
                        -- Need to set enemy moves to max_moves for this
                        -- and only consider own units without moves as blockers
                        local moves = e.moves
                        e.moves = e.max_moves

                        wesnoth.extract_unit(leader)
                        for iu,uMP in ipairs(units_MP) do wesnoth.extract_unit(uMP) end
                        local path, cost = wesnoth.find_path(e, leader.x, leader.y)
                        for iu,uMP in ipairs(units_MP) do wesnoth.put_unit(uMP.x, uMP.y, uMP) end
                        wesnoth.put_unit(leader)

                        e.moves = moves
                        local steps = math.ceil(cost / e.max_moves)

                        -- We only attack each enemy with 2 units max
                        -- (High CTK targets are taken care of by separate CA right before this one)
                        local already_attacked_twice = false
                        local xy_turn = e.x * 1000. + e.y + wesnoth.current.turn / 1000.
                        if self.data[xy_turn] and (self.data[xy_turn] >= 2) then
                            already_attacked_twice = true
                        end
                        --print('  already_attacked_twice', already_attacked_twice, e.x, e.y, xy_turn, self.data[xy_turn])

                        -- Not a very clean way of doing this, clean up later !!!!
                        if already_attacked_twice then rating = -9.9e99 end  -- the 9.9 here is intentional !!!!

                        -- Distance from AI leader rating
                        if (steps == 1) then
                            -- If the enemy is within reach of leader, attack with high preference and unconditionally
                            rating = rating + 1000
                        else
                            -- Otherwise only attack if you can do more damage than the enemy
                            -- and only if our unit has more than 20 HP
                            -- and only if the unit is not too far east
                            -- except at night

                            local tod = wesnoth.get_time_of_day()
                            if (tod.id ~= 'first_watch') and (tod.id ~= 'second_watch') then
                                if ((attacker.hitpoints - a.att_stats.average_hp) >= (e.hitpoints - a.def_stats.average_hp))
                                    or (attacker.hitpoints < 20) or ((attacker.x >= 24) and (attacker.y >= 10))
                                then
                                    rating = -9e99
                                end
                            end
                        end

                        --print('    rating:', rating, attacker.id, e.id)
                        if (rating > max_rating) then
                            max_rating, best_attack = rating, a
                        end
                    end
                end
            end

            if (max_rating > -9e99) then
                self.data.ALT_best_attack = best_attack
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return score
            end

            if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
            return 0
        end

        function grunt_rush_FLS1:attack_leader_threat_exec()
            if AH.print_exec() then print('     - Executing attack_leader_threat CA') end
            -- If a trapping attack was found, we do that first
            -- All of this should be made more consistent later
            if self.data.ALT_trapping_attackers then
                if AH.show_messages() then W.message { speaker = 'narrator', message = 'Trapping attack possible (in attack_leader_threats)' } end

                -- Reorder the trapping attacks so that those that do not need to move a unit out of the way happen first
                -- This is in case the unit_in_way is one of the trappers (which might be moved in the wrong direction)
                for i = #self.data.ALT_trapping_attackers,1,-1 do
                    local unit_in_way = wesnoth.get_unit(self.data.ALT_trapping_dsts[i][1], self.data.ALT_trapping_dsts[i][2])
                    if unit_in_way and ((unit_in_way.x ~= self.data.ALT_trapping_attackers[i].x) or (unit_in_way.y ~= self.data.ALT_trapping_attackers[i].y)) then
                        table.insert(self.data.ALT_trapping_attackers, self.data.ALT_trapping_attackers[i])
                        table.insert(self.data.ALT_trapping_dsts, self.data.ALT_trapping_dsts[i])
                        table.remove(self.data.ALT_trapping_attackers, i)
                        table.remove(self.data.ALT_trapping_dsts, i)
                    end
                end

                for i,attacker in ipairs(self.data.ALT_trapping_attackers) do
                    -- Need to check that enemy was not killed by previous attack
                    if self.data.ALT_trapping_enemy and self.data.ALT_trapping_enemy.valid then
                        AH.movefull_outofway_stopunit(ai, attacker, self.data.ALT_trapping_dsts[i])
                        ai.attack(attacker, self.data.ALT_trapping_enemy)

                        -- Counter for how often this unit was attacked this turn
                        if self.data.ALT_trapping_enemy.valid then
                            local xy_turn = self.data.ALT_trapping_enemy.x * 1000. + self.data.ALT_trapping_enemy.y + wesnoth.current.turn / 1000.
                            if (not self.data[xy_turn]) then
                                self.data[xy_turn] = 1
                            else
                                self.data[xy_turn] = self.data[xy_turn] + 1
                            end
                            --print('Attack number on this unit this turn:', xy_turn, self.data[xy_turn])
                        end
                    end
                end
                self.data.ALT_trapping_attackers, self.data.ALT_trapping_dsts, self.data.ALT_trapping_enemy = nil, nil, nil

                -- Need to return here, as other attacks are not valid in this case
                return
            end

            local attacker = wesnoth.get_unit(self.data.ALT_best_attack.att_loc.x, self.data.ALT_best_attack.att_loc.y)
            local defender = wesnoth.get_unit(self.data.ALT_best_attack.def_loc.x, self.data.ALT_best_attack.def_loc.y)

            -- Counter for how often this unit was attacked this turn
            if defender.valid then
                local xy_turn = defender.x * 1000. + defender.y + wesnoth.current.turn / 1000.
                if (not self.data[xy_turn]) then
                    self.data[xy_turn] = 1
                else
                    self.data[xy_turn] = self.data[xy_turn] + 1
                end
                --print('Attack number on this unit this turn:', xy_turn, self.data[xy_turn])
            end

            if AH.show_messages() then W.message { speaker = attacker.id, message = 'Attacking leader threat' } end
            AH.movefull_outofway_stopunit(ai, attacker, self.data.ALT_best_attack, { dx = 0.5, dy = -0.1 })
            ai.attack(attacker, defender)
            self.data.ALT_best_attack = nil

            -- Reset variable indicating that this was an attack by the leader
            -- Can be done whether it was the leader who attacked or not:
            self.data.attack_by_leader_flag = nil
        end

        --------- ZOC enemy ------------
        -- Currently, this is for the left side only
        -- To be extended later, or to be combined with other CAs

        function grunt_rush_FLS1:ZOC_enemy_eval()
            local score = 390000
            if AH.print_eval() then print('     - Evaluating ZOC_enemy CA:', os.clock()) end

            -- Decide whether to attack units on the left, and trap them if possible

            -- Skip this if AI is much stronger than enemy
            if self:full_offensive() then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end

            -- Get units on left and on keep, with and without movement left
            local units = AH.get_live_units { side = wesnoth.current.side, x = '1-15,16-20', y = '1-15,1-6',
                canrecruit = 'no'
            }
            --print('#units', #units)
            local units_MP = {}
            for i,u in ipairs(units) do
                if (u.moves > 0) then table.insert(units_MP, u) end
            end
            -- If no unit in this part of the map can move, we're done (> Level 0 only)
            --print('#units_MP', #units_MP)
            if (not units_MP[1]) then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end

            -- Check how many enemies are in the same area
            local enemies = AH.get_live_units { x = '1-15,16-20', y = '1-15,1-6',
                { "filter_side", { { "enemy_of", {side = wesnoth.current.side} } } }
            }
            --print('#enemies', #enemies)
            -- If there are no enemies in this part of the map, we're also done
            if (not enemies[1]) then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end

            -- If units without moves on left are outnumbered (by HP, depending on time of day), don't do anything 
            local hp_ratio = self:hp_ratio(units, enemies)
            --print('ZOC enemy: HP ratio:', hp_ratio)

            local tod = wesnoth.get_time_of_day()
            if (tod.id == 'morning') or (tod.id == 'afternoon') then
                if (hp_ratio < 1.5) then
                    if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                    return 0
                end
            end
            if (tod.id == 'dusk') or (tod.id == 'dawn') then
                if (hp_ratio < 1.25) then
                    if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                    return 0
                end
            end
            if (tod.id == 'first_watch') or (tod.id == 'second_watch') then
                if (hp_ratio < 1) then
                    if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                    return 0
                end
            end

            -- Check whether we can find a trapping attack using two units on opposite sides of an enemy
            local attackers, dsts, enemy = self:best_trapping_attack_opposite(units_MP, enemies)
            if attackers then
                self.data.ZOC_attackers = attackers
                self.data.ZOC_dsts = dsts
                self.data.ZOC_enemy = enemy
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return score
            end

            -- Otherwise don't do anything
            if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
            return 0
        end

        function grunt_rush_FLS1:ZOC_enemy_exec()
            if AH.print_exec() then print('     - Executing ZOC_enemy CA') end
            if AH.show_messages() then W.message { speaker = 'narrator', message = 'Starting trapping attack (in ZOC_enemy)' } end

            -- Reorder the trapping attacks so that those that do not need to move a unit out of the way happen first
            -- This is in case the unit_in_way is one of the trappers (which might be moved in the wrong direction)
            for i = #self.data.ZOC_attackers,1,-1 do
                local unit_in_way = wesnoth.get_unit(self.data.ZOC_dsts[i][1], self.data.ZOC_dsts[i][2])
                if unit_in_way and ((unit_in_way.x ~= self.data.ZOC_attackers[i].x) or (unit_in_way.y ~= self.data.ZOC_attackers[i].y)) then
                    table.insert(self.data.ZOC_attackers, self.data.ZOC_attackers[i])
                    table.insert(self.data.ZOC_dsts, self.data.ZOC_dsts[i])
                    table.remove(self.data.ZOC_attackers, i)
                    table.remove(self.data.ZOC_dsts, i)
                end
            end

            for i,attacker in ipairs(self.data.ZOC_attackers) do
                -- Need to check that enemy was not killed by previous attack
                if self.data.ZOC_enemy and self.data.ZOC_enemy.valid then
                    AH.movefull_outofway_stopunit(ai, attacker, self.data.ZOC_dsts[i])
                    ai.attack(attacker, self.data.ZOC_enemy)
                end
            end
            self.data.ZOC_attackers, self.data.ZOC_dsts, self.data.ZOC_enemy = nil, nil, nil
        end


        ----------Grab villages -----------

        function grunt_rush_FLS1:grab_villages_eval()
            local score_high, score_low = 450000, 360000
            if AH.print_eval() then print('     - Evaluating grab_villages CA:', os.clock()) end

            local leave_own_villages = wesnoth.get_variable "leave_own_villages"
            if leave_own_villages then
                --print('Lowering village holding priority')
                score_low = 250000
            end

            -- Check if there are units with moves left
            -- New: include the leader in this
            local units = wesnoth.get_units { side = wesnoth.current.side, 
                formula = '$this_unit.moves > 0'
            }
            if (not units[1]) then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end

            local enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }

            local villages = wesnoth.get_locations { terrain = '*^V*' }
            -- Just in case:
            if (not villages[1]) then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end

            --print('#units, #enemies', #units, #enemies)

            -- Now we check if a unit can get to a village
            local max_rating, best_village, best_unit = 0, {}, {}  -- yes, want '0' here
            for i,u in ipairs(units) do
                for j,v in ipairs(villages) do
                    local path, cost = wesnoth.find_path(u, v[1], v[2])

                    local unit_in_way = wesnoth.get_unit(v[1], v[2])
                    if unit_in_way then
                        if (unit_in_way.id == u.id) then unit_in_way = nil end
                    end

                    -- Rate all villages that can be reached and are unoccupied by other units
                    if (cost <= u.moves) and (not unit_in_way) then
                        --print('Can reach:', u.id, v[1], v[2], cost)
                        local rating = 0

                        -- !!!!! Only positive ratings are allowed for this one !!!!!
                        -- If an enemy can get onto the village, we want to hold it
                        -- Need to take the unit itself off the map, as it might be sitting on the village itself (which then is not reachable by enemies)
                        wesnoth.extract_unit(u)
                        for k,e in ipairs(enemies) do
                            local path_e, cost_e = wesnoth.find_path(e, v[1], v[2])
                            if (cost_e <= e.max_moves) then 
                                --print('  within enemy reach', e.id)
                                rating = rating + 10
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

                        -- Grunts are needed elsewhere, so use other units first
                        if (u.type ~= 'Orcish Grunt') then rating = rating + 1 end

                        -- Finally, since these can be reached by the enemy, want the strongest unit to go first
                        rating = rating + u.hitpoints / 100.

                        -- If this is the leader, calculate counter attack damage
                        -- Make him the preferred village taker unless he's likely to die
                        -- but only if he's on the keep
                        if u.canrecruit then
                            local counter_table = self:calc_counter_attack(u, { v[1], v[2] })
                            local max_counter_damage = counter_table.max_counter_damage
                            --print('    max_counter_damage:', u.id, max_counter_damage)
                            if (max_counter_damage < u.hitpoints) and wesnoth.get_terrain_info(wesnoth.get_terrain(u.x, u.y)).keep then
                                --print('      -> take village with leader')
                                rating = rating + 2
                            else
                                rating = -1000
                            end
                        end

                        -- A rating of 0 here means that a village can be reached, but is not interesting
                        -- Thus, max_rating start value is 0, which means don't go there
                        -- Rating needs to be at least 10 to be interesting
                        if (rating >=10) and (rating > max_rating) then
                            max_rating, best_village, best_unit = rating, v, u
                        end

                        --print('  rating:', rating, u.id, u.canrecruit)
                    end
                end
            end

            --print('max_rating', max_rating)

            if (max_rating >= 10) then
                self.data.GV_unit, self.data.GV_village = best_unit, best_village
                if (max_rating >= 1000) then
                    if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                    return score_high
                else
                    if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                    return score_low
                end
            end
            if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
            return 0
        end

        function grunt_rush_FLS1:grab_villages_exec()
            if AH.print_exec() then print('     - Executing grab_villages CA') end
            if self.data.GV_unit.canrecruit then 
                if AH.show_messages() then W.message { speaker = self.data.GV_unit.id, message = 'The leader, me, is about to grab a village.  Need to recruit first.' } end
                -- Recruiting first; we're doing that differently here than in attack_leader_threat,
                -- by running a mini CA eval/exec loop
                local recruit_loop = true
                while recruit_loop do
                    local eval = self:recruit_orcs_eval()
                    if (eval > 0) then
                        self:recruit_orcs_exec()
                    else
                        recruit_loop = false
                    end
                end
            end

            if AH.show_messages() then W.message { speaker = self.data.GV_unit.id, message = 'Grabbing/holding village' } end
            AH.movefull_outofway_stopunit(ai, self.data.GV_unit, self.data.GV_village)
            self.data.GV_unit, self.data.GV_village = nil, nil
        end

        --------- Protect Center ------------

        function grunt_rush_FLS1:protect_center_eval()
            local score = 352000
            if AH.print_eval() then print('     - Evaluating protect_center CA:', os.clock()) end

            -- Move units to protect the center villages
            local units_MP = wesnoth.get_units { side = wesnoth.current.side, x = '1-24', canrecruit = 'no',
                formula = '$this_unit.moves > 0'
            }
            if (not units_MP[1]) then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end

            -- Skip this if AI is much stronger than enemy
            if self:full_offensive() then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end

            local protect_loc = { x = 18, y = 9 }

            --print('Considering center village')

            -- Figure out how many enemies can get there, and count their total HP
            local enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }

            -- If there's one of AI's units on the village, take it off (for enemy path finding)
            -- whether it has MP left or not
            local unit_on_village = wesnoth.get_unit(protect_loc.x, protect_loc.y)
            if unit_on_village and (unit_on_village.moves == 0) and (unit_on_village.side == wesnoth.current.side) then
                wesnoth.extract_unit(unit_on_village)
            end

            -- Take all our own units with MP left off the map
            for i,u in ipairs(units_MP) do wesnoth.extract_unit(u) end

            local enemy_hp = 0
            for i,e in ipairs(enemies) do
                -- Add up hitpoints of enemy units that can get there
                if AH.can_reach(e, protect_loc.x, protect_loc.y, { moves = 'max' }) then
                    --print('Enemy can get there:', e.id, e.x, e.y)
                    enemy_hp = enemy_hp + e.hitpoints
                end
            end
            --print('Total enemy hitpoints:', enemy_hp)

            -- Put our units back out there
            for i,u in ipairs(units_MP) do wesnoth.put_unit(u.x, u.y, u) end
            if unit_on_village and (unit_on_village.moves == 0) and (unit_on_village.side == wesnoth.current.side) then
                wesnoth.put_unit(unit_on_village.x, unit_on_village.y, unit_on_village)
            end

            -- If no enemies can reach the village, return 0
            if (enemy_hp == 0) then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end
            --print('Enemies that can reach center village found.  Total HP:', enemy_hp)

            -- Now check whether we have enough defenders there already
            local defenders = AH.get_live_units { side = wesnoth.current.side, x = '17-22', y = '7-11',
                formula = '$this_unit.moves = 0'
            }
            --print('#defenders', #defenders)
            local defender_hp = 0
            for i,d in ipairs(defenders) do defender_hp = defender_hp + d.hitpoints end
            --print('Total defender hitpoints:', defender_hp)

            -- Want at least half enemy_hp in the area
            if (defender_hp <= 0.67 * enemy_hp) then 
                --print('Moving units to protect center village')
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return score
            end

            if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
            return 0
        end

        function grunt_rush_FLS1:protect_center_exec()
            if AH.print_exec() then print('     - Executing protect_center CA') end
            local units_MP = wesnoth.get_units { side = wesnoth.current.side, x = '1-24', canrecruit = 'no',
                formula = '$this_unit.moves > 0'
            }
            local protect_loc = { x = 18, y = 9 }

            if AH.show_messages() then W.message { speaker = 'narrator', message = 'Protecting map center' } end
            self:hold_position(units_MP, protect_loc)
        end

        --------- Hold left ------------

        function grunt_rush_FLS1:hold_left_eval()
            local score = 351000
            if AH.print_eval() then print('     - Evaluating hold_left CA:', os.clock()) end

            -- Move units to hold position on the left, depending on number of enemies there
            -- Also move a goblin to the far-west village

            -- Skip this if AI is much stronger than enemy
            if self:full_offensive() then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end

            -- Get units on left and on keep, with and without movement left
            local units_left = AH.get_live_units { side = wesnoth.current.side, x = '1-15,16-20', y = '1-15,1-6',
                canrecruit = 'no'
            }
            local units_MP, units_noMP, pillagers = {}, {}, {}
            for i,u in ipairs(units_left) do
                if (u.moves > 0) then
                    table.insert(units_MP, u)
                    if (u.x <= 15) then table.insert(pillagers, u) end
                else
                    -- Only those not on/around the keep count here
                    -- And need to exclude the goblin (so that orc on village remains)
                    if (u.x <= 15) and (u.__cfg.race ~= 'goblin') then 
                        table.insert(units_noMP, u)
                    end
                end
            end
            -- If no unit in this part of the map can move, we're done
            if (not units_MP[1]) then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end

            -- Check whether units on left can go pillaging
            local enemies = AH.get_live_units {
                { "filter_side", { { "enemy_of", {side = wesnoth.current.side} } } }
            }
            local enemy_attack_map = AH.attack_map(enemies, { moves = 'max' })

            -- If no more than 1 enemy can attack the village at 11,9, go pillaging
            local enemy_threat = enemy_attack_map:get(11, 9)
            if enemy_threat and (enemy_threat == 1) then enemy_threat = nil end
            if (not enemy_threat) and pillagers[1] then
                --print('Eval says: go pillaging in west')
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return score
            end

            -- If there's a goblin, we send him out left first
            local gobo = AH.get_live_units { side = wesnoth.current.side, x = '1-20', y = '1-8',
                race = 'goblin', formula = '$this_unit.moves > 0'
            }
            if gobo[1] then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return score
            end

            -- Otherwise check whether reinforcements are needed
            local enemy_units_left = AH.get_live_units { x = '1-15', y = '1-15',
                { "filter_side", { { "enemy_of", {side = wesnoth.current.side} } } }
            }
            --print('#units_left, #units_MP, #units_noMP, #enemy_units_left', #units_left, #units_MP, #units_noMP, #enemy_units_left)

            -- If units without moves on left are outnumbered (by HP), send some more over there
            local hp_ratio_left = self:hp_ratio(units_noMP, enemy_units_left)
            --print('Left HP ratio:', hp_ratio_left)

            if (hp_ratio_left < 0.67) then
                 if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                 return score
            end

            if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
            return 0
        end

        function grunt_rush_FLS1:hold_left_exec()
            if AH.print_exec() then print('     - Executing hold_left CA') end
            -- Move goblin first, if there is one
            -- There shouldn't be more than 1, so we just take the first we find

            -- Check whether units on left can go pillaging
            -- Get units on left and on keep, with and without movement left
            local units_left = AH.get_live_units { side = wesnoth.current.side, x = '1-15,16-20', y = '1-15,1-6',
                canrecruit = 'no'
            }
            local pillagers = {}
            for i,u in ipairs(units_left) do
                if (u.moves > 0) then
                    if (u.x <= 15) then table.insert(pillagers, u) end
                end
            end

            local enemies = AH.get_live_units {
                { "filter_side", { { "enemy_of", {side = wesnoth.current.side} } } }
            }
            local enemy_attack_map = AH.attack_map(enemies, { moves = 'max' })

            -- If no enemy can attack the village at 11,9, go pillaging
            local enemy_threat = enemy_attack_map:get(11, 9)
            if enemy_threat and (enemy_threat == 1) then enemy_threat = nil end
            if (not enemy_threat) and pillagers[1] then
                --print('  --> Exec: go pillaging in west')

                local max_rating, best_hex, best_unit = -9e99, {}, {}
                for i,u in ipairs(pillagers) do
                    local reach_map = AH.get_reachable_unocc(u)
                    reach_map:iter( function(x, y, v)
                        local rating = y -- the farther south the better

                        -- Take southern-most units first
                        rating = rating + u.y

                        -- If no enemy can get there -> no terrain rating
                        -- This also favors terrain in direction of enemy
                        local enemy_threat = enemy_attack_map:get(x, y)
                        if (not enemy_threat) then enemy_threat = 0 end

                        if enemy_threat > 0 then
                            -- Small bonus if this is on a village
                            local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(x, y)).village
                            if is_village then rating = rating + 1.1 end

                            local defense = 100 - wesnoth.unit_defense(u, wesnoth.get_terrain(x, y))
                            rating = rating + defense / 9.
                        end

                        -- However, if 2 or more enemies can get there, strongly disfavor this
                        if enemy_threat > 2 then
                            rating = rating - 1000 * enemy_threat
                        end

                        if (rating > max_rating) then
                            max_rating, best_hex, best_unit = rating, { x, y }, u
                        end
                    end)
                end
                if AH.show_messages() then W.message { speaker = best_unit.id, message = 'Going pillaging in west' } end
                AH.movefull_outofway_stopunit(ai, best_unit, best_hex)
                return  -- There might not be other units, need to go through eval again first
            end

            local gobo = AH.get_live_units { side = wesnoth.current.side, x = '1-20', y = '1-8',
                race = 'goblin', formula = '$this_unit.moves > 0'
            }[1]

            local goal = { x = 8, y = 5 }  -- far west village
            if gobo then
                -- First, if there's one of our units on the village, move it out of the way
                local unit_in_way = wesnoth.get_unit(goal.x, goal.y)
                if unit_in_way and (unit_in_way.moves > 0) and (unit_in_way.side == wesnoth.current.side) and (unit_in_way.__cfg.race ~= 'goblin') then
                    local best_hex = AH.find_best_move(unit_in_way, function(x, y)
                        local rating = -H.distance_between(x, y, goal.x, goal.y) + x/10.
                        if (x == goal.x) and (y == goal.y) then rating = rating - 1000 end
                        return rating
                    end)
                    if AH.show_messages() then W.message { speaker = unit_in_way.id, message = 'Moving off the village' } end
                    ai.move(unit_in_way, best_hex[1], best_hex[2])
                end

                local best_hex = AH.find_best_move(gobo, function(x, y)
                    return -H.distance_between(x, y, goal.x, goal.y) - y/10.
                end)
                if AH.show_messages() then W.message { speaker = gobo.id, message = 'Moving gobo toward village; or keeping him there' } end
                AH.movefull_stopunit(ai, gobo, best_hex)
                return  -- There might not be other units, need to go through eval again first
            end

            -- If we got here, we need to hold the position
            --print('Sending unit left')
            -- Get units on left and on keep, with and without movement left
            local units_left = wesnoth.get_units { side = wesnoth.current.side, x = '1-15,16-20', y = '1-15,1-6',
                canrecruit = 'no', formula = '$this_unit.moves > 0'
            }
            local goal = { x = 11, y = 9 }  -- southern-most of western villages

            if AH.show_messages() then W.message { speaker = 'narrator', message = 'Holding left (west)' } end
            self:hold_position(units_left, goal)
        end

        --------- Grunt rush right ------------

        function grunt_rush_FLS1:rush_right_eval()
            local score = 350000
            if AH.print_eval() then print('     - Evaluating rush_right CA:', os.clock()) end

            -- All remaining units (after 'hold_left' and previous events), head toward the village at 27,16

            -- Skip this if AI is much stronger than enemy
            if self:full_offensive() then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end

            local units = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'no',
                { "not", { x = '1-21', y = '12-25' } },
                formula = '$this_unit.moves > 0'
            }

            if units[1] then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return score
            end

            if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
            return 0
        end

        function grunt_rush_FLS1:rush_right_exec()
            if AH.print_exec() then print('     - Executing rush_right CA') end

            local units = AH.get_live_units { side = wesnoth.current.side, canrecruit = 'no',
                { "not", { x = '1-21', y = '12-25' } },
                formula = '$this_unit.attacks_left > 0'
            }
            local enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }

            -- Get HP ratio of units that can reach right part of map as function of y coordinate
            local width, height = wesnoth.get_map_size()
            local hp_ratio_y = self:hp_ratio_y(units, enemies, 25, width, 11, height)


            -- We'll do this step by step for easier experimenting
            -- To be streamlined later
            local tod = wesnoth.get_time_of_day()

            local attack_y, attack_flag = 11, false
            for y = attack_y,height do
                --print(y, hp_ratio_y[y])

                if (tod.id == 'dawn') or (tod.id == 'morning') or (tod.id == 'afternoon') then
                    attack_flag = false
                    if (hp_ratio_y[y] >= 2.0) then attack_y = y end
                end
                if (tod.id == 'dusk') or (tod.id == 'first_watch') or (tod.id == 'second_watch') then
                    attack_flag = true
                    if (hp_ratio_y[y] > 0.1) then attack_y = y end
                end
            end
            --print('attack_y before', attack_y)

            if (type(self.data.RR_attack_y) ~= 'table') then self.data.RR_attack_y = {} end
            if self.data.RR_attack_y[wesnoth.current.turn] and (self.data.RR_attack_y[wesnoth.current.turn] > attack_y) then
                attack_y = self.data.RR_attack_y[wesnoth.current.turn]
            else
                self.data.RR_attack_y[wesnoth.current.turn] = attack_y
            end
            --print('attack_y after', attack_y)

            -- If a suitable attack_y was found, figure out what targets there might be
            if attack_flag and (attack_y > 0) then
                attack_y = attack_y + 1  -- Targets can be one hex farther south
                --print('Looking for targets on right down to y = ' .. attack_y)

                local enemies = AH.get_live_units { x = '24-37,23-37,20-37', y='10-13,14-18,19-24',
                    { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
                }
                --print('#enemies all', #enemies)

                -- Take out those too far south
                for i=#enemies,1,-1 do
                    if (enemies[i].y > attack_y) then table.remove(enemies, i) end
                end
                --print('#enemies filtered', #enemies)

                -- Also want an 'attackers' array, indexed by position
                local attackers = {}
                for i,u in ipairs(units) do attackers[u.x * 1000 + u.y] = u end

                local max_rating, best_attackers, best_dsts, best_enemy = -9e99, {}, {}, {}
                for i,e in ipairs(enemies) do
                    --print('\n', i, e.id)
                    local attack_combos, attacks_dst_src = AH.get_attack_combos_no_order(units, e)
                    --DBG.dbms(attack_combos)
                    --DBG.dbms(attacks_dst_src)
                    --print('#attack_combos', #attack_combos)

                    local enemy_on_village = wesnoth.get_terrain_info(wesnoth.get_terrain(e.x, e.y)).village
                    local enemy_cost = e.__cfg.cost

                    for j,combo in ipairs(attack_combos) do
                        -- attackers and dsts arrays for stats calculation
                        local atts, dsts = {}, {}
                        for dst,src in pairs(combo) do
                            table.insert(atts, attackers[src])
                            table.insert(dsts, { math.floor(dst / 1000), dst % 1000 } )
                        end
                        local sorted_atts, sorted_dsts, combo_def_stats, combo_att_stats = AH.attack_combo_stats(atts, dsts, e)
                        --DBG.dbms(combo_def_stats)

                        -- Don't attack under certain circumstances
                        local dont_attack = false

                        local rating = 0
                        local damage = 0
                        for k,att_stats in ipairs(combo_att_stats) do
                            if (att_stats.hp_chance[0] >= 0.5) then dont_attack = true end
                            damage = damage + sorted_atts[k].hitpoints - att_stats.average_hp
                        end
                        local damage_enemy = e.hitpoints - combo_def_stats.average_hp
                        --print(' - #attacks, damage, damage_enemy', #sorted_atts, damage, damage_enemy, dont_attack)

                        rating = rating + damage_enemy - damage / 2.

                        -- Chance to kill is very important (for both sides)
                        rating = rating + combo_def_stats.hp_chance[0] * 50.
                        for k,a in ipairs(sorted_atts) do
                            rating = rating - combo_att_stats[k].hp_chance[0] * 25.
                        end

                        -- Cost of enemy is another factor
                        rating = rating + enemy_cost

                        -- If this is on the village, then the expected enemy HP matter:
                        -- The fewer, the better (choose 25 as about neutral for now)
                        if enemy_on_village then
                            rating = rating + (25 - combo_def_stats.average_hp)
                        end

                        --print(' -----------------------> rating', rating)
                        if (not dont_attack) and (rating > max_rating) then
                            max_rating, best_attackers, best_dsts, best_enemy = rating, sorted_atts, sorted_dsts, e
                        end
                    end
                end
                --print('max_rating ', max_rating)
                --DBG.dbms(best_combo)

                -- Now we know which attacks to do
                if (max_rating > -9e99) then
                    while best_attackers and (table.maxn(best_attackers) > 0) do
                        if AH.show_messages() then W.message { speaker = best_attackers[1].id, message = 'Rush right: Combo attack' } end
                        AH.movefull_outofway_stopunit(ai, best_attackers[1], best_dsts[1])
                        ai.attack(best_attackers[1], best_enemy)

                        -- Delete this attack from the combo
                        table.remove(best_attackers, 1)
                        table.remove(best_dsts, 1)

                        -- If enemy got killed, we need to stop here
                        if (not best_enemy.valid) then best_attackers, best_dsts = nil, nil end
                    end 

                    return -- to force re-evaluation
                end
            end

            -- If we got here, we should hold position on the right instead
            --print('Holding position on right down to y = ' .. attack_y)
            --if AH.show_messages() then W.message { speaker = 'narrator', message = 'Holding position on right down to y = ' .. attack_y } end

            -- Get all units with moves left (before was for those with attacks left)
            local units = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'no',
                { "not", { x = '1-21', y = '12-25' } },
                formula = '$this_unit.moves > 0'
            }

            -- If there's a village in the two rows around attack_y, make that the goal
            -- Otherwise it's just { 27, attack_y }

            if (attack_y > 22) then attack_y = 22 end
            local goal = { x = 27, y = attack_y }
            for y = attack_y - 1, attack_y + 1 do
                for x = 23,34 do
                    --print(x,y)
                    local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(x, y)).village
                    if is_village then
                        goal = { x = x, y = y }
                        break
                    end
                end
            end
            --print('goal:', goal.x, goal.y)
            self:hold_position(units, goal, { ignore_terrain_at_night = true } )
        end

        -----------Spread poison ----------------

        function grunt_rush_FLS1:spread_poison_eval()
            local score = 380000

            -- As an experiment: reduce importance of spreading poison during night
            -- This is supposed to help with the rush on the right, freeing up units for that
            -- Don't know how well this is going to work...
            local tod = wesnoth.get_time_of_day()
            if (tod.id == 'dusk') or (tod.id == 'first_watch') or (tod.id == 'second_watch') then
                score = 300000
            end

            if AH.print_eval() then print('     - Evaluating spread_posion CA:', os.clock()) end

            -- If a unit with a poisoned weapon can make an attack, we'll do that preferentially
            -- (with some exceptions)

            -- Keep this for reference how it's done, but don't use now
            -- local poisoners = AH.get_live_units { side = wesnoth.current.side, 
            --    formula = '$this_unit.attacks_left > 0', canrecruit = 'no',
            --    { "filter_wml", {
            --        { "attack", {
            --            { "specials", {
            --                { "poison", { } }
            --            } }
            --        } }
            --    } }
            --}

            local attackers = AH.get_live_units { side = wesnoth.current.side, 
                formula = '$this_unit.attacks_left > 0', canrecruit = 'no' }

            local poisoners, others = {}, {}
            for i,a in ipairs(attackers) do
                local is_poisoner = false
                local weapon_number = 0
                for att in H.child_range(a.__cfg, 'attack') do
                    weapon_number = weapon_number + 1
                    for sp in H.child_range(att, 'specials') do
                        if H.get_child(sp, 'poison') then
                            --print('is_poinsoner:', a.id, ' weapon number: ', weapon_number)
                            is_poisoner = true
                        end
                    end
                end

                if is_poisoner then
                    table.insert(poisoners, a)
                else
                    table.insert(others, a)
                end
            end

            --print('#poisoners, #others', #poisoners, #others)
            if (not poisoners[1]) then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end

            local attacks = AH.get_attacks_occupied(poisoners)
            --print('#attacks', #attacks)
            if (not attacks[1]) then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end

            local units_no_attacks = AH.get_live_units { side = wesnoth.current.side, 
                formula = '$this_unit.attacks_left <= 0'
            }

            local other_attacks = AH.get_attacks_occupied(others)
            --print('#other_attacks', #other_attacks)

            -- For counter attack damage calculation:
            local enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }
            local enemy_attack_map = AH.attack_map(enemies, {moves = "max"})
            --AH.put_labels(enemy_attack_map)

            -- Go through all possible attacks with poisoners
            local max_rating, best_attack = -9e99, {}
            for i,a in ipairs(attacks) do
                local attacker = wesnoth.get_unit(a.att_loc.x, a.att_loc.y)
                local defender = wesnoth.get_unit(a.def_loc.x, a.def_loc.y)

                -- Don't try to poison a unit that cannot be poisoned
                local status = H.get_child(defender.__cfg, "status")
                local cant_poison = status.poisoned or status.not_living

                -- Also, poisoning units that would level up through the attack is very bad
                local about_to_level = defender.max_experience - defender.experience <= attacker.__cfg.level

                if (not cant_poison) and (not about_to_level) then
                    -- Strongest enemy gets poisoned first
                    local rating = defender.hitpoints

                    -- Always attack enemy leader, if possible 
                    if defender.canrecruit then rating = rating + 1000 end

                    -- Enemies on villages are not good targets
                    local enemy_on_village = wesnoth.get_terrain_info(wesnoth.get_terrain(defender.x, defender.y)).village
                    if enemy_on_village then rating = rating - 500 end

                    -- Enemies that can regenerate are not good targets
                    if wesnoth.unit_ability(defender, 'regenerate') then rating = rating - 1000 end

                    -- More priority to enemies on strong terrain
                    local defender_defense = 100 - wesnoth.unit_defense(defender, wesnoth.get_terrain(defender.x, defender.y))
                    rating = rating + defender_defense / 4.

                    -- Also want to attack from the strongest possible terrain
                    local attack_defense = 100 - wesnoth.unit_defense(attacker, wesnoth.get_terrain(a.x, a.y))
                    rating = rating + attack_defense / 2.
                    --print('rating', rating, attacker.id, a.x, a.y)

                    -- And from village everything else being equal
                    local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(a.x, a.y)).village
                    if is_village then rating = rating + 0.5 end

                    -- Minor penalty if unit needs to be moved out of the way
                    if a.attack_hex_occupied then rating = rating - 0.1 end

                    -- From dawn to afternoon, only attack if not more than 2 enemy units are close
                    local enemies_in_reach = enemy_attack_map:get(a.x, a.y)
                    --print('  enemies_in_reach', enemies_in_reach)

                    if (enemies_in_reach > 2) then
                        local tod = wesnoth.get_time_of_day()
                        if (tod.id == 'dawn') or (tod.id == 'morning') or (tod.id == 'afternoon') then
                            rating = -9e99
                        end
                    end

                    -- Otherwise, only go through with the attack, if we can back it up with another unit
                    -- Or if only one enemy is in reach
                    -- Or if the attack hex is already next to an AI unit with noMP left

                    local max_support_rating, support_attack, support_also_attack = -9e99, {}, false
                    if (enemies_in_reach > 1) and (rating > -9e99) then
                        -- First check whether there's already one of our own units with no 
                        -- attacks left next to the attack hex (then we don't need the support unit)
                        local support_no_attacks = false
                        for j,una in ipairs(units_no_attacks) do
                            --print('unit no attacks left: ', una.id)
                            if (H.distance_between(una.x, una.y, a.def_loc.x, a.def_loc.y) == 1)
                                and (H.distance_between(una.x, una.y, a.x, a.y) == 1)
                            then
                                --print('  can be support unit for this (no attacks left)')
                                support_no_attacks = true
                            end
                        end
                        --print('    support_no_attacks:', support_no_attacks)

                        if support_no_attacks then
                            rating = rating + 0.01 -- very slightly prefer this version, everything else being equal
                        else
                            -- Check whether one of the other units can attack that same enemy, but from a different hex
                            -- adjacent to poisoner
                            for j,oa in ipairs(other_attacks) do
                                if (oa.def_loc.x == a.def_loc.x) and (oa.def_loc.y == a.def_loc.y)
                                    and (H.distance_between(oa.x, oa.y, a.x, a.y) == 1)
                                then
                                    -- Now rate those hexes
                                    local supporter = wesnoth.get_unit(oa.att_loc.x, oa.att_loc.y)
                                    local support_rating = 100 - wesnoth.unit_defense(supporter, wesnoth.get_terrain(oa.att_loc.x, oa.att_loc.y))
                                    support_rating = support_rating + oa.att_stats.average_hp - oa.def_stats.average_hp
                                    --print('  Supporting attack', oa.x, oa.y, support_rating)

                                    -- Minor penalty if unit needs to be moved out of the way
                                    if oa.attack_hex_occupied then support_rating = support_rating - 0.1 end

                                    if (support_rating > max_support_rating) then
                                        max_support_rating, support_attack = support_rating, oa

                                        -- If we can do more damage than enemy, also attack, otherwise just move
                                        if (supporter.hitpoints - oa.att_stats.average_hp) < (defender.hitpoints - oa.def_stats.average_hp) then
                                            support_also_attack = true
                                        end
                                    end
                                end
                            end

                            -- If no acceptable support was found, mark this attack as invalid
                            if (max_support_rating == -9e99) then
                                rating = -9e99
                            else  -- otherwise small penalty as it ties up another unit
                                rating = rating - 0.99
                            end
                        end
                    end

                    -- On a village, only attack if the support will also attack
                    -- or the defender is hurt already
                    if enemy_on_village and (not support_also_attack) and (defender.max_hitpoints - defender.hitpoints < 8) then rating = -9e99 end

                    --print('  -> final rating', rating, attacker.id, a.x, a.y)

                    if rating > max_rating then
                        max_rating, best_attack = rating, a
                        if (max_support_rating > -9e99) then
                            best_support_attack, best_support_also_attack = support_attack, support_also_attack
                        else
                            best_support_attack, best_support_also_attack = nil, false
                        end
                    end
                end
            end
            if (max_rating > -9e99) then
                self.data.SP_attack, self.data.SP_support_attack, self.data.SP_also_attack = best_attack, best_support_attack, best_support_also_attack
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return score
            end

            if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
            return 0
        end

        function grunt_rush_FLS1:spread_poison_exec()
            if AH.print_exec() then print('     - Executing spread_poison CA') end
            local attacker = wesnoth.get_unit(self.data.SP_attack.att_loc.x, self.data.SP_attack.att_loc.y)
            local defender = wesnoth.get_unit(self.data.SP_attack.def_loc.x, self.data.SP_attack.def_loc.y)

            -- Also need to get the supporter at this time, since it might be the unit that's move out of the way
            local suporter = {}
            if self.data.SP_support_attack then
                supporter = wesnoth.get_unit(self.data.SP_support_attack.att_loc.x, self.data.SP_support_attack.att_loc.y)
            end

            if AH.show_messages() then W.message { speaker = attacker.id, message = "Poison attack" } end
            AH.movefull_outofway_stopunit(ai, attacker, self.data.SP_attack, { dx = 0., dy = 0. })
            local def_hp = defender.hitpoints

            -- Find the poison weapon
            -- If several attacks have poison, this will always find the last one
            local poison_weapon, weapon_number = -1, 0
            for att in H.child_range(attacker.__cfg, 'attack') do
                weapon_number = weapon_number + 1
                for sp in H.child_range(att, 'specials') do
                    if H.get_child(sp, 'poison') then
                        --print('is_poinsoner:', attacker.id, ' weapon number: ', weapon_number)
                        poison_weapon = weapon_number
                    end
                end
            end

            local dw = -1
            if AH.got_1_11() then dw = 0 end
            ai.attack(attacker, defender, poison_weapon + dw)
            self.data.SP_attack = nil

            -- In case either attacker or defender died, don't do anything
            if (not attacker.valid) then return end
            if (not defender.valid) then return end

            -- A little joke: if the assassin misses all 3 poison attacks, complain
            if (not self.data.SP_complained_about_luck) and (defender.hitpoints == def_hp) then
                self.data.SP_complained_about_luck = true
                W.delay { time = 1000 }
                W.message { speaker = attacker.id, message = "Oh, come on !" }
            end

            if self.data.SP_support_attack then
                if AH.show_messages() then W.message { speaker = supporter.id, message = 'Supporting poisoner attack' } end
                AH.movefull_outofway_stopunit(ai, supporter, self.data.SP_support_attack)
                if self.data.SP_also_attack then ai.attack(supporter, defender) end
            end
            self.data.SP_support_attack, self.data.SP_also_attack = nil, nil
        end

        ----------Recruitment -----------------

        function grunt_rush_FLS1:recruit_orcs_eval()
            local score = 181000
            if AH.print_eval() then print('     - Evaluating recruit_orcs CA:', os.clock()) end

            if self.data.attack_by_leader_flag then
                if AH.show_messages() then W.message { speaker = 'narrator', message = 'Leader attack imminent.  Recruiting first.' } end
                score = 461000
            end

            -- Check if there is enough gold to recruit at least a grunt
            if (wesnoth.sides[wesnoth.current.side].gold < 12) then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end

            -- Check if leader is on keep
            local leader = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]
            if (not wesnoth.get_terrain_info(wesnoth.get_terrain(leader.x, leader.y)).keep) then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end
            
            -- Check if we're banking gold for next turn
            if (self.data.recruit_bank_gold) then
                return 0
            end

            -- If there's at least one free castle hex, go to recruiting
            local castle = wesnoth.get_locations {
                x = leader.x, y = leader.y, radius = 5,
                { "filter_radius", { terrain = 'C*,K*' } }
            }
            for i,c in ipairs(castle) do
                local unit_in_way = wesnoth.get_unit(c[1], c[2])
                if (not unit_in_way) then -- If no unit in way, we're good
                    if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                    return score
                else
                    -- Otherwise check whether the unit can move away (non-leaders only)
                    -- Under most circumstances, this is unnecessary, but it can be required
                    -- when the leader is about to move off the keep for attacking or village grabbing
                    if (not unit_in_way.canrecruit) then
                        local move_away = AH.get_reachable_unocc(unit_in_way)
                        if (move_away:size() > 1) then
                            if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                            return score
                        end
                    end
                end
            end

            -- Otherwise: no recruiting
            if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
            return 0
        end

        function grunt_rush_FLS1:recruit_orcs_exec()
            if AH.print_exec() then print('     - Executing recruit_orcs CA') end
            -- Recruiting logic (in that order):
            -- ... under revision ...
            -- All of this is contingent on having enough gold (eval checked for gold > 12)
            -- -> if not enough gold for something else, recruit a grunt at the end

            local goal = { x = 27, y = 16 }

            -- First, find open castle hex closest to goal
            -- If there's at least one free castle hex, go to recruiting
            local leader = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]
            local castle = wesnoth.get_locations {
                x = leader.x, y = leader.y, radius = 5,
                { "filter_radius", { terrain = 'C*,K*' } }
            }

            -- Recruit on the castle hex that is closest to the above-defined 'goal'
            local max_rating, best_hex, best_hex_left = -9e99, {}, {}
            for i,c in ipairs(castle) do
                local unit_in_way = wesnoth.get_unit(c[1], c[2])
                local rating = -9e99
                if (not unit_in_way) then 
                    rating = - H.distance_between(c[1], c[2], goal.x, goal.y)
                else  -- hexes with units that can move away are possible, but unfavorable
                    if (not unit_in_way.canrecruit) then
                    local move_away = AH.get_reachable_unocc(unit_in_way)
                        if (move_away:size() > 1) then 
                            rating = - H.distance_between(c[1], c[2], goal.x, goal.y)
                            -- The more hexes the unit can move to, the better
                            -- but it's still worse than if there's no unit in the way
                            rating = rating - 10000 + move_away:size()
                        end
                    end                    
                end
                if (rating > max_rating) then 
                    max_rating, best_hex = rating, { c[1], c[2] }
                end
            end

            -- First move unit out of the way, if there is one
            local unit_in_way = wesnoth.get_unit(best_hex[1], best_hex[2])
            if unit_in_way then
                if AH.show_messages() then W.message { speaker = unit_in_way.id, message = 'Moving out of way for recruiting' } end
                AH.move_unit_out_of_way(ai, unit_in_way, { dx = 0.1, dy = 0.5 })
            end

            if AH.show_messages() then W.message { speaker = leader.id, message = 'Recruiting' } end

            -- Recruit an assassin, if there is none
            local assassins = AH.get_live_units { side = wesnoth.current.side, type = 'Orcish Assassin,Orcish Slayer', canrecruit = 'no' }
            local not_living_enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }}},
                lua_function = "not_living"
            }
            local assassin = assassins[1]
            if (not assassin) and (wesnoth.sides[wesnoth.current.side].gold >= 17) and (#not_living_enemies < 5) then
                --print('recruiting assassin')
                ai.recruit('Orcish Assassin', best_hex[1], best_hex[2])
                return
            end

            -- Recruit an archer, if there is none
            local archer = AH.get_live_units { side = wesnoth.current.side, type = 'Orcish Archer' }[1]
            if (not archer) and (wesnoth.sides[wesnoth.current.side].gold >= 14) then
                --print('recruiting archer')
                ai.recruit('Orcish Archer', best_hex[1], best_hex[2])
                return
            end
            
            local archer_targets = AH.get_live_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }}},
                lua_function = "archer_target"
            }
            local archers = AH.get_live_units { side = wesnoth.current.side, type = 'Orcish Archer,Orcish Crossbowman', canrecruit = 'no' }
            if (#archer_targets > #archers*2) then
                if (wesnoth.sides[wesnoth.current.side].gold >= 14) then
                    --print('recruiting archer based on counter-recruit')
                    ai.recruit('Orcish Archer', best_hex[1], best_hex[2])
                    return
                else
                    self.data.recruit_bank_gold = grunt_rush_FLS1:should_have_gold_next_turn(14)
                end
            end
            
            local troll_targets = AH.get_live_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }}},
                lua_function = "troll_target"
            }
            local trolls = AH.get_live_units { side = wesnoth.current.side, type = 'Troll Whelp,Troll,Troll Rocklobber', canrecruit = 'no' }
            if (#troll_targets-1 > #trolls*2) then
                if (wesnoth.sides[wesnoth.current.side].gold >= 13) then
                    --print('recruiting whelp based on counter-recruit')
                    ai.recruit('Troll Whelp', best_hex[1], best_hex[2])
                    return
                else
                    self.data.recruit_bank_gold = grunt_rush_FLS1:should_have_gold_next_turn(13)
                end
            end
            
            if (self.data.recruit_bank_gold) then
                --print('Banking gold to recruit unit next turn')
                return
            end
            
            -- Recruit a goblin, if there is none, starting Turn 5
            -- But only if way over to western-most village is clear
            if (wesnoth.current.turn >= 5) then
                local gobo = AH.get_live_units { side = wesnoth.current.side, type = 'Goblin Spearman' }[1]
                if (not gobo) and (wesnoth.sides[wesnoth.current.side].gold >= 9) then
                    -- Make sure that there aren't enemies in the way
                    local enemy_units_left = AH.get_live_units { x = '1-17', y = '1-8',
                        { "filter_side", { { "enemy_of", {side = wesnoth.current.side} } } }
                    }
                    if (not enemy_units_left[1]) then
                        -- Goblin should be recruited on the left though
                        --print('recruiting goblin based on numbers')
                        ai.recruit('Goblin Spearman', best_hex_left[1], best_hex_left[2])
                        return
                    end
                end
            end

            -- Recruit an orc if we have fewer than 60% grunts (not counting the leader)
            local grunts = AH.get_live_units { side = wesnoth.current.side, type = 'Orcish Grunt' }
            local all_units_nl = AH.get_live_units { side = wesnoth.current.side, canrecruit = 'no' }
            if (#grunts / (#all_units_nl + 0.0001) < 0.6) then  -- +0.0001 to avoid div-by-zero
                --print('recruiting grunt based on numbers')
                ai.recruit('Orcish Grunt', best_hex[1], best_hex[2])
                return
            end

            -- Recruit an orc if their average HP is <25
            local av_hp_grunts = 0
            for i,g in ipairs(grunts) do av_hp_grunts = av_hp_grunts + g.hitpoints / #grunts end
            if (av_hp_grunts < 25) then
                --print('recruiting grunt based on average hitpoints:', av_hp_grunts)
                ai.recruit('Orcish Grunt', best_hex[1], best_hex[2])
                return
            end
            
            -- Recruit a troll whelp, if there is none, starting Turn 5
            if (wesnoth.current.turn >= 5) then
                local whelp = trolls[1]
                if (not whelp) and (wesnoth.sides[wesnoth.current.side].gold >= 13) then
                    --print('recruiting assassin based on numbers')
                    ai.recruit('Troll Whelp', best_hex[1], best_hex[2])
                    return
                end
            end

            -- Recruit an assassin, if there are fewer than 3 (in addition to previous assassin recruit)
            if (#assassins < 3) and (wesnoth.sides[wesnoth.current.side].gold >= 17) and (#not_living_enemies < 5) then
                --print('recruiting assassin based on numbers')
                ai.recruit('Orcish Assassin', best_hex[1], best_hex[2])
                return
            end

            -- Recruit a wolf rider, if there is none
            local wolfrider = AH.get_live_units { side = wesnoth.current.side, type = 'Wolf Rider' }[1]
            if (not wolfrider) and (wesnoth.sides[wesnoth.current.side].gold >= 17) then
                --print('recruiting wolfrider')
                ai.recruit('Wolf Rider', best_hex[1], best_hex[2])
                return
            end

            -- Recruit an archer, if there are fewer than 2 (in addition to previous assassin recruit)
            if (#archers < 2) and (wesnoth.sides[wesnoth.current.side].gold >= 14) then
                --print('recruiting archer based on numbers')
                ai.recruit('Orcish Archer', best_hex[1], best_hex[2])
                return
            end

            -- Recruit a troll whelp, if there are fewer than 2 (in addition to previous whelp recruit), starting Turn 6
            if (wesnoth.current.turn >= 6) then
                if (#trolls < 2) and (wesnoth.sides[wesnoth.current.side].gold >= 13) then
                    --print('recruiting whelp based on numbers')
                    ai.recruit('Troll Whelp', best_hex[1], best_hex[2])
                    return
                end
            end

            
            -- If we got here, none of the previous conditions kicked in -> random recruit
            -- (if gold >= 17, for simplicity)
            if (wesnoth.sides[wesnoth.current.side].gold >= 17) then
                W.set_variable { name = "LUA_random", rand = 'Orcish Archer,Orcish Assassin,Wolf Rider' }
                local type = wesnoth.get_variable "LUA_random"
                wesnoth.set_variable "LUA_random"
                --print('random recruit: ', type)

                ai.recruit(type, best_hex[1], best_hex[2])
                return
            end

            -- If we got here, there wasn't enough money to recruit something other than a grunt
            --print('recruiting grunt based on gold')
            ai.recruit('Orcish Grunt', best_hex[1], best_hex[2])
        end

        function grunt_rush_FLS1:should_have_gold_next_turn(amount)
            -- This should really calculate income and current gold and see if it exceeds
            -- the amount to ensure that the AI still recruits something if income is negative
             
            return true
        end
        
        return grunt_rush_FLS1        
    end
}
