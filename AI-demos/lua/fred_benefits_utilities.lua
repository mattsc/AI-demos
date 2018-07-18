--[=[
Collect all the utility evaluation functions in one place.
The goal is to make them as consistent as possible.
]=]

local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local FCFG = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_config.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local utility_functions = {}

function utility_functions.village_benefits(village_grabs, fred_data)
    -- Contributions (all of these are compared to not grabbing the village, instead
    --   of in absolute terms; for example, a village we already own does not count
    --   toward the income beneift):
    --  - Income from the villages (and loss of income for the enemy)
    --  - Healing to the unit
    --  - Damage taken/dealt on the village in counter attack
    --  - Very small tie-breaker contributions that are not actual benefits

    local move_data = fred_data.move_data
    local village_benefits = {}

    for _,grab in ipairs(village_grabs) do
        --std_print(grab.x .. ',' .. grab.y .. ' by ' .. grab.id)

        local unit_info = move_data.unit_infos[grab.id]

        local owner = FU.get_fgumap_value(move_data.village_map, grab.x, grab.y, 'owner')
        --std_print('    owner: ' .. owner)

        if (not owner) then
            std_print('!!!!!!!!!! This should never happen: village_benefits called for non-village location !!!!!!!!!!')
            wesnoth.message('!!!!!!!!!! This should never happen: village_benefits called for non-village location !!!!!!!!!!')
            return
        end

        local income_benefit = 0
        if (owner ~= wesnoth.current.side) then
            -- For now we assume that each village also provides support
            local base_benefit = 3
            -- Only get income on next turn if unit survives
            local my_benefit = base_benefit * (1 - grab.die_chance)
            -- Definitely take income from enemy on next turn, and on following turn if unit survives
            local enemy_benefit = 0
            if (owner ~= 0) then
                enemy_benefit = base_benefit * (1 + 1 - grab.die_chance)
            end
            income_benefit = my_benefit + enemy_benefit
            --std_print('      income: ' .. base_benefit, my_benefit, enemy_benefit, grab.die_chance)
        end
        --std_print('    income_benefit: ' .. income_benefit)

        -- If a counter attack was calculated, the healing benefit from the village
        -- is included in the counter attack rating. If not, we need to do so separately.
        local unit_benefit = 0
        if grab.counter_rating then
            -- This is the rating for the counter attack, this need the negative value
            unit_benefit = - grab.counter_rating
            --std_print('    unit_benefit (counter rating): ' .. unit_benefit)
        else
            local unit_benefit = 0
            if (not unit_info.abilities.regenerate) then
                local hp_eff = unit_info.hitpoints
                if unit_info.traits.healthy then
                    hp_eff = hp_eff + 2
                end
                if unit_info.status.poisoned then
                    hp_eff = hp_eff - 8
                end
                local heal_amount = math.min(unit_info.max_hitpoints - hp_eff, 8)
                unit_benefit = heal_amount / unit_info.max_hitpoints * FU.unit_value(unit_info)
                --std_print('    healing: ' .. hp_eff, heal_amount, FU.unit_value(unit_info), grab.die_chance)
            end
            --std_print('    unit_benefit (healing): ' .. unit_benefit)
        end

        -- Finally, we add a couple tie breaker ratings that are not actual benefits
        -- Their contributions are so small, that they should not make a difference
        -- unless everything else is equal

        -- Prefer villages farther back
        local extras = -0.1 * FU.get_fgumap_value(fred_data.turn_data.leader_distance_map, grab.x, grab.y, 'distance')
        -- Prefer the fastest unit
        extras = extras + unit_info.max_moves / 100.

        -- Prefer the leader, if possible; this is larger than the other extra ratings
        -- but as the damage rating is more conservative for the leader, this should be ok
        if unit_info.canrecruit then
            extras = extras + 1
        end
        --std_print('    extras: ' .. extras)

        local benefit = income_benefit + unit_benefit + extras
        --std_print('  -> benefit: ' .. benefit)

        local xy = 'grab_village_' .. (grab.x * 1000 + grab.y) .. ':' .. grab.zone_id
        if (not village_benefits[xy]) then
            village_benefits[xy] = { units = {} }
        end
        village_benefits[xy].units[grab.id] = { benefit = benefit, penalty = 0 }
    end
    --DBG.dbms(village_benefits, false, 'village_benefits')

--[[
    local vb_dst_src = {}
    for x,y,data in FU.fgumap_iter(village_benefits) do
        local tmp = { dst = x * 1000 + y }
        for id,rating in pairs(data) do
            local loc = move_data.my_units[id]
            table.insert(tmp, { src = loc[1] * 1000 + loc[2], rating = rating } )
        end
        table.insert(vb_dst_src, tmp)
    end
    --DBG.dbms(vb_dst_src, false, 'vb_dst_src')

    local grab_combos = FU.get_unit_hex_combos(vb_dst_src, false, true)
    table.sort(grab_combos, function(a, b) return a.rating > b.rating end)
    --DBG.dbms(grab_combos, false, 'grab_combos')
--]]

    return village_benefits
end


function utility_functions.retreat_utilities(move_data, value_ratio)
    local hp_inflection_base = FCFG.get_cfg_parm('hp_inflection_base')

    local retreat_utility = {}
    for id,loc in pairs(move_data.my_units) do
        local xp_mult = FU.weight_s(move_data.unit_infos[id].experience / move_data.unit_infos[id].max_experience, 0.75)
        local level = move_data.unit_infos[id].level

        local dhp_in = hp_inflection_base * (1 - value_ratio) * (1 - xp_mult) / level^2
        local hp_inflection_init = hp_inflection_base - dhp_in

        local dhp_nr = (move_data.unit_infos[id].max_hitpoints - hp_inflection_init) * (1 - value_ratio) * (1 - xp_mult) / level^2
        local hp_no_retreat = move_data.unit_infos[id].max_hitpoints - dhp_nr

        --std_print(id, move_data.unit_infos[id].hitpoints .. '/' .. move_data.unit_infos[id].max_hitpoints .. '   ' .. move_data.unit_infos[id].experience .. '/' .. move_data.unit_infos[id].max_experience .. '   ' .. hp_no_retreat)
        --std_print('  ' .. hp_inflection_base, hp_inflection_init, hp_no_retreat)

        local hp_eff = move_data.unit_infos[id].hitpoints
        if move_data.unit_infos[id].abilities.regenerate then
            hp_eff = hp_eff + 8
        end
        if move_data.unit_infos[id].status.poisoned then
            local poison_damage = 8
            if move_data.unit_infos[id].traits.healthy then
                poison_damage = poison_damage * 0.75
            end
            hp_eff = hp_eff - poison_damage
        end
        if move_data.unit_infos[id].traits.healthy then
            hp_eff = hp_eff + 2
        end

        local w_retreat = 0
        if (hp_eff < hp_no_retreat) then
            if (hp_eff < 1) then hp_eff = 1 end

            local max_hp_mult = math.sqrt(hp_no_retreat / (hp_inflection_init * 2))
            local hp_inflection = hp_inflection_init * max_hp_mult

            local hp_inflection_max_xp = (hp_inflection + hp_no_retreat) / 2
            if (hp_inflection_max_xp > hp_inflection) then
                hp_inflection = hp_inflection + (hp_inflection_max_xp - hp_inflection) * xp_mult
            end

            if (hp_eff <= hp_inflection) then
                w_retreat = FU.weight_s((hp_inflection - hp_eff) / (hp_inflection * 2) + 0.5, 0.75)
            else
                w_retreat = FU.weight_s((hp_no_retreat - hp_eff) / ((hp_no_retreat - hp_inflection) * 2), 0.75)
            end
            --std_print('  ' .. id, move_data.unit_infos[id].experience, hp_inflection, hp_inflection, w_retreat)
        end

        retreat_utility[id] = w_retreat
    end

    return retreat_utility
end


function utility_functions.attack_benefits(assigned_enemies, goal_hexes, use_average, fred_data)
    local move_data = fred_data.move_data
    local attack_benefits = {}
    local max_rating

    for zone_id,data in pairs(assigned_enemies) do
        --std_print(zone_id)

        attack_benefits[zone_id] = {}

        for id,_ in pairs(move_data.my_units) do
            --std_print('  ' .. id)

            local can_reach_1, can_reach_2 = false, false
            local max_rating_forward, max_rating_counter = - math.huge, - math.huge
            local av_rating_forward, av_rating_counter, count = 0, 0, 0
            for enemy_id,enemy_loc in pairs(data) do
                local rating_forward = fred_data.turn_data.unit_attacks[id][enemy_id].rating_forward
                local rating_counter = fred_data.turn_data.unit_attacks[id][enemy_id].rating_counter
                --std_print('    ' .. enemy_id, rating_forward, rating_counter)

                av_rating_forward = av_rating_forward + rating_forward
                av_rating_counter = av_rating_counter + rating_counter
                count = count + 1

                if (rating_forward > max_rating_forward) then
                    max_rating_forward = rating_forward
                end
                if (rating_counter > max_rating_counter) then
                    max_rating_counter = rating_counter
                end

                if (not can_reach_1) then
                    local ids1 = FU.get_fgumap_value(move_data.my_attack_map[1], enemy_loc[1], enemy_loc[2], 'ids') or {}
                    for _,attack_id in ipairs(ids1) do
                        if (id == attack_id) then
                            can_reach_1 = true
                            break
                        end
                    end
                end
                if (not can_reach_1) and (not can_reach_2) then
                    local ids2 = FU.get_fgumap_value(move_data.my_attack_map[2], enemy_loc[1], enemy_loc[2], 'ids') or {}
                    for _,attack_id in ipairs(ids2) do
                        if (id == attack_id) then
                            can_reach_2 = true
                            break
                        end
                    end
                end
                --std_print('    ' .. enemy_id, rating_forward, rating_counter, can_reach_1, can_reach_2)
            end

            --std_print('      ' .. av_rating_forward, av_rating_counter, count)
            if (count > 0) then
                av_rating_forward = av_rating_forward / count
                av_rating_counter = av_rating_counter / count
            end
            --std_print('        ' .. av_rating_forward, av_rating_counter)

            -- Also check if we are close enough to the goal hex instead
            -- TODO: check whether we need to be able to reach those hexes, rather than
            -- attack them. Might have to be different depending on whether there's an enemy there
            -- TODO: do we need to consider enemies and goal hexes serially?
            if (not can_reach_1) then
                for _,goal_hex in ipairs(goal_hexes[zone_id]) do
                    local ids1 = FU.get_fgumap_value(move_data.my_attack_map[1], goal_hex[1], goal_hex[2], 'ids') or {}
                    for _,attack_id in ipairs(ids1) do
                        if (id == attack_id) then
                            can_reach_1 = true
                            break
                        end
                    end
                end
                if (not can_reach_1) and (not can_reach_2) then
                  for _,goal_hex in ipairs(goal_hexes[zone_id]) do
                        local ids2 = FU.get_fgumap_value(move_data.my_attack_map[2], goal_hex[1], goal_hex[2], 'ids') or {}
                        for _,attack_id in ipairs(ids2) do
                            if (id == attack_id) then
                                can_reach_2 = true
                                break
                            end
                        end
                    end
                end
                --std_print('    goal hex: ' .. goal_hexes[zone_id][1] .. ',' .. goal_hexes[zone_id][2], can_reach_1, can_reach_2)

            end

            local turns = 3
            if can_reach_1 then
                turns = 1
            elseif can_reach_2 then
                turns = 2
            end

            local rating = max_rating_forward - max_rating_counter
            if use_average then
                rating = av_rating_forward - av_rating_counter
            end
            --std_print('    max: ' .. rating .. ' = ' .. max_rating_forward .. ' - ' .. max_rating_counter, can_reach_1, can_reach_2)

            attack_benefits[zone_id][id] = {
                benefit = rating,
                turns = turns
            }
        end
    end

    --DBG.dbms(attack_benefits, false, 'attack_benefits')

    return attack_benefits
end


function utility_functions.attack_utilities(assigned_enemies, value_ratio, fred_data)
    local move_data = fred_data.move_data
    local attack_utilities = {}
    local max_rating
    for id,_ in pairs(move_data.my_units) do
        -- TODO: eventually put some conditional here so that we do not have
        -- to do this for all units all the time
        if true then
            --std_print(id)
            attack_utilities[id] = {}
            for zone_id,data in pairs(assigned_enemies) do
                --std_print('  ' .. zone_id)

                local tmp_enemies = {}
                for enemy_id,_ in pairs(data) do
                    --std_print('    ' .. enemy_id)
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
                        --std_print('    ' .. enemy.enemy_id)
                        local enemy_weight = FU.unit_base_power(move_data.unit_infos[id])
                        cum_weight = cum_weight + enemy_weight
                        n_enemies = n_enemies + 1

                        --std_print('      taken, done:', enemy.damage_taken, enemy.damage_done)

                        -- For this purpose, we use individual damage, rather than combined
                        local frac_taken = enemy.damage_taken - enemy.my_regen
                        frac_taken = frac_taken / move_data.unit_infos[id].hitpoints
                        --std_print('      frac_taken 1', frac_taken)
                        frac_taken = FU.weight_s(frac_taken, 0.5)
                        --std_print('      frac_taken 2', frac_taken)
                        --if (frac_taken > 1) then frac_taken = 1 end
                        --if (frac_taken < 0) then frac_taken = 0 end
                        av_damage_taken = av_damage_taken + enemy_weight * frac_taken * move_data.unit_infos[id].hitpoints

                        local frac_done = enemy.damage_done - enemy.enemy_regen
                        frac_done = frac_done / move_data.unit_infos[enemy.enemy_id].hitpoints
                        --std_print('      frac_done 1', frac_done)
                        frac_done = FU.weight_s(frac_done, 0.5)
                        --std_print('      frac_done 2', frac_done)
                        --if (frac_done > 1) then frac_done = 1 end
                        --if (frac_done < 0) then frac_done = 0 end
                        av_damage_done = av_damage_done + enemy_weight * frac_done * move_data.unit_infos[enemy.enemy_id].hitpoints

                        --std_print('  ', av_damage_taken, av_damage_done, cum_weight)
                    end

                    --std_print('  cum: ', av_damage_taken, av_damage_done, cum_weight)
                    av_damage_taken = av_damage_taken / cum_weight
                    av_damage_done = av_damage_done / cum_weight
                    --std_print('  av:  ', av_damage_taken, av_damage_done)

                    -- We want the ToD-independent rating here.
                    -- The rounding is going to be off for ToD modifier, but good enough for now
                    --av_damage_taken = av_damage_taken / move_data.unit_infos[id].tod_mod
                    --av_damage_done = av_damage_done / move_data.unit_infos[id].tod_mod
                    --std_print('  av:  ', av_damage_taken, av_damage_done)

                    -- The rating must be positive for the analysis below to work
                    local av_hp_left = move_data.unit_infos[id].hitpoints - av_damage_taken
                    if (av_hp_left < 0) then av_hp_left = 0 end
                    --std_print('    ' .. value_ratio, av_damage_done, av_hp_left)

                    local attacker_rating = av_damage_done / value_ratio + av_hp_left
                    attack_utilities[id][zone_id] = attacker_rating

                    if (not max_rating) or (attacker_rating > max_rating) then
                        max_rating = attacker_rating
                    end
                    --std_print('  -->', attacker_rating)
                end
            end
        end
    end
    --DBG.dbms(attack_utilities, false, 'attack_utilities')

    -- Normalize the utilities
    for id,zone_ratings in pairs(attack_utilities) do
        for zone_id,rating in pairs(zone_ratings) do
            zone_ratings[zone_id] = zone_ratings[zone_id] / max_rating
        end
    end
    --DBG.dbms(attack_utilities, false, 'attack_utilities')

    return attack_utilities
end


function utility_functions.assign_units(benefits, move_data)
    -- Find unit-task combinations that maximize the benefit received
    -- Input table must be of format:
    --   ...

    ----- Begin find_best_assignment -----
    local function find_best_assignment(base_ratings, power_used)
        -- Do not modify @base_ratings!

        local tmp_ratings = {}
        for i_t,task in ipairs(base_ratings) do
            tmp_ratings[i_t] = { units = {}, action = task.action, required = task.required }
            for i_u,unit in ipairs(task.units) do
                local penalty = unit.base_rating - (task.units[i_u + 1] and task.units[i_u + 1].base_rating or 0)
                --[[ TODO: maybe do something like this later?  Note: that code is no complete yet
                if task.required and task.required.power then
                    local power_missing = task.required.power - (power_used[task.action] or 0)
                    std_print('  ' .. task.action .. ': calculating power penalty', power_missing)
                    local j_u = i_u + 1
                    -- TODO: there's a disconnect here with the < 25% of last unit power requirement below
                    while (j_u <= #task.units) and (power_missing > 0) do
                        local unit_power = FU.unit_base_power(move_data.unit_infos[task.units[j_u].id])

                        power_missing = power_missing - unit_power
                        j_u = j_u + 1

                        std_print('    ' .. i_u, j_u, task.units[j_u].id, unit_power, power_missing)

                    end
                end
                --]]

                local penalty_required_power = 0
                if task.required and task.required.power then
                    penalty_required_power = 1000
                end

                local tmp_unit = {
                    id = unit.id,
                    base_rating = unit.base_rating,
                    own_penalty = unit.own_penalty,
                    penalty = penalty,
                    penalty_required_power = penalty_required_power
                }
                table.insert(tmp_ratings[i_t].units, tmp_unit)
            end
        end
        --DBG.dbms(tmp_ratings, false, 'tmp_ratings-1')

        for i,task1 in ipairs(tmp_ratings) do
            for _,unit1 in ipairs(task1.units) do
                local max_penalty_other, max_penalty_required_power_other = 0, 0
                for j,task2 in ipairs(tmp_ratings) do
                    --std_print(i .. ' ' .. j)
                    if (i ~= j) then
                        for _,unit2 in ipairs(task2.units) do
                            if (unit2.id == unit1.id) then
                                --std_print('  ' .. unit1.id, unit2.id)
                                if (unit2.penalty > max_penalty_other) then
                                    max_penalty_other = unit2.penalty
                                end
                                if (not task1.required) or (not task1.required.power) then
                                    if (unit2.penalty_required_power > max_penalty_required_power_other) then
                                        max_penalty_required_power_other = unit2.penalty_required_power
                                    end
                                end
                                break
                            end
                        end
                    end
                end
                --std_print('    ' .. max_penalty_other, max_penalty_required_power_other)
                unit1.max_penalty_other = max_penalty_other
                unit1.max_penalty_required_power_other = max_penalty_required_power_other
                unit1.rating = unit1.base_rating - unit1.own_penalty - max_penalty_other - max_penalty_required_power_other
            end

            table.sort(task1.units, function(a, b) return a.rating > b.rating end)
        end
        --DBG.dbms(tmp_ratings, false, 'tmp_ratings-2')

        local max_rating, best_id, best_action = - math.huge

        for _,task in ipairs(tmp_ratings) do
            --std_print(task.action, task.units[1].id, task.units[1].rating, max_rating)
            if (task.units[1].rating > max_rating) then
                max_rating = task.units[1].rating
                best_id = task.units[1].id
                best_action = task.action
            end
        end

        return best_id, best_action
    end
    ----- End find_best_assignment -----

    -- Convert the benefits table to a ratings table that can be used above.
    -- Also, we need a local copy as we're going to modify it and don't want to change the input table.
    local task_ratings = {}
    for action,data in pairs(benefits) do
        local tmp = { action = action, units = {}, required = data.required }
        for id,ratings in pairs(data.units) do
            local u = { id = id, base_rating = ratings.benefit, own_penalty = ratings.penalty }
            table.insert(tmp.units, u)
        end
        table.sort(tmp.units, function(a, b) return a.base_rating > b.base_rating end)

        table.insert(task_ratings, tmp)
    end
    --DBG.dbms(task_ratings, false, 'task_ratings')


    local assignments, power_used = {}, {}
    local keep_trying = true
    while keep_trying do
        keep_trying = false

        local id, action = find_best_assignment(task_ratings, power_used)
        assignments[id] = action
        --std_print('assigned: ' .. id .. ' -> ' .. action)
        --DBG.dbms(assignments, false, assignments)

        local unit_power = FU.unit_base_power(move_data.unit_infos[id])
        power_used[action] = (power_used[action] or 0) + unit_power
        --DBG.dbms(power_used, false, 'power_used')

        for i,task in ipairs(task_ratings) do
            if (task.action == action) then
                -- If there's a power requirement, stop if the remaining power
                -- missing is less than 25% of the power of the last unit assigned
                if task.required and task.required.power then
                    local power_missing = task.required.power - power_used[action]
                    local fraction = power_missing / unit_power
                    --std_print('checking power: ' .. task.action .. '  ' .. id, power_missing, fraction)
                    if (fraction < 0.25) then
                        table.remove(task_ratings, i)
                    end
                else
                    table.remove(task_ratings, i)
                end
                break
            end
        end
        --DBG.dbms(task_ratings, false, 'task_ratings')

        for i_v=#task_ratings,1,-1 do
            for i_u,unit in ipairs(task_ratings[i_v].units) do
                if (unit.id == id) then
                    table.remove(task_ratings[i_v].units, i_u)
                    break
                end
            end
            if (#task_ratings[i_v].units == 0) then
                table.remove(task_ratings, i_v)
            end
        end
        --DBG.dbms(task_ratings, false, 'task_ratings')

        if (#task_ratings > 0) then
            keep_trying = true
        end
    end
    --DBG.dbms(assignments, false, 'assignments')

    return assignments
end


return utility_functions
