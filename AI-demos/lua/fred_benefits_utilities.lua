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

return utility_functions
