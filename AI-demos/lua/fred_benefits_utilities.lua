--[=[
Collect all the utility evaluation functions in one place.
The goal is to make them as consistent as possible.
]=]

local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local FCFG = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_config.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local utility_functions = {}

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
    --DBG.dbms(attack_utilities)

    -- Normalize the utilities
    for id,zone_ratings in pairs(attack_utilities) do
        for zone_id,rating in pairs(zone_ratings) do
            zone_ratings[zone_id] = zone_ratings[zone_id] / max_rating
        end
    end
    --DBG.dbms(attack_utilities)

    return attack_utilities
end

return utility_functions
