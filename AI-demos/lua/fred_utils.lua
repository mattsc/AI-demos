local H = wesnoth.require "lua/helper.lua"
local W = H.set_wml_action_metatable {}
local FGUI = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_utils_incremental.lua"
local items = wesnoth.require "lua/wml/items.lua"

-- TODO: Some functions are currently repeats of those in ai_helper
-- Trying not to use ai_helper for now.

local fred_utils = {}

function fred_utils.print_debug(show_debug, ...)
    if show_debug then print(...) end
end

function fred_utils.clear_labels()
    -- Clear all labels on a map
    local width, height = wesnoth.get_map_size()
    for x = 1,width do
        for y = 1,height do
            W.label { x = x, y = y, text = "" }
        end
    end
end

function fred_utils.put_fgumap_labels(map, key, cfg)
    -- Take @map (in the format as defined in fred_gamestate_utils (fgu) and put
    -- labels containing the values of @key onto the map.
    -- Print 'nan' if element exists but is not a number.
    -- @cfg: table with optional parameters:
    --   - show_coords: (boolean) use hex coordinates as labels instead of value
    --   - factor=1: (number) if value is a number, multiply by this factor

    local factor = (cfg and cfg.factor) or 1

    fred_utils.clear_labels()

    local min, max = 9e99, -9e99
    for x,arr in pairs(map) do
        for y,data in pairs(arr) do
            local out = data[key]

            if (type(out) == 'number') then
                if (out > max) then max = out end
                if (out < min) then min = out end
            end
        end
    end

    if (min > max) then
        min, max = 0, 1
    end

    if (min == max) then
        min = max - 1
    end

    min = min - (max - min) * 0.2

    for x,arr in pairs(map) do
        for y,data in pairs(arr) do
            local out = data[key]

            if cfg and cfg.show_coords then
                out = x .. ',' .. y
            end

            if (type(out) ~= 'string') then
                if out then
                    out = tonumber(out) or 'nan'
                else
                    out = 'nil'
                end
            end

            local red_fac, green_fac, blue_fac = 1, 1, 1
            if (type(out) == 'number') then
                color_fac = (out - min) / (max - min)
                if (color_fac < 0.5) then
                    red_fac = color_fac + 0.5
                    green_fac = 0
                    blue_fac = 0
                elseif (color_fac < 0.75) then
                    red_fac = 1
                    green_fac = (color_fac - 0.5) * 4
                    blue_fac = green_fac / 2
                else
                    red_fac = 1
                    green_fac = 1
                    blue_fac = (color_fac - 0.75) * 4
                end

                out = out * factor
            end

            W.label {
                x = x, y = y,
                text = out,
                color = 255 * red_fac .. ',' .. 255 * green_fac .. ',' .. 255 * blue_fac
            }
        end
    end
end

function fred_utils.show_fgumap_with_message(map, key, text, cfg)
    -- @cfg: optional table to contain x/y keys as coordinates and 'id' for the speaker
    --   This can thus be a unit table

    fred_utils.put_fgumap_labels(map, key)
    if cfg and cfg.x and cfg.y then
        wesnoth.scroll_to_tile(cfg.x,cfg.y)
        items.place_halo(cfg.x, cfg.y, "halo/teleport-8.png")
    end
    W.redraw()
    local id = cfg and cfg.id
    if id then
        W.message { speaker = 'narrator', message = text .. ': ' .. id }
    else
        W.message { speaker = 'narrator', message = text }
    end
    if cfg and cfg.x and cfg.y then
        items.remove(cfg.x, cfg.y, "halo/teleport-8.png")
    end
    fred_utils.clear_labels()
    W.redraw()
end

function fred_utils.get_fgumap_value(map, x, y, key, alt_value)
    return (map[x] and map[x][y] and map[x][y][key]) or alt_value
end

function fred_utils.set_fgumap_value(map, x, y, key, value)
    if (not map[x]) then map[x] = {} end
    if (not map[x][y]) then map[x][y] = {} end
    map[x][y][key] = value
end

function fred_utils.fgumap_iter(map)
    function each_hex(state)
        while state.x ~= nil do
            local child = map[state.x]
            state.y = next(child, state.y)
            if state.y == nil then
                state.x = next(map, state.x)
            else
                return state.x, state.y, child[state.y]
            end
        end
    end

    return each_hex, { x = next(map) }
end

function fred_utils.weight_s(x, exp)
    -- S curve weighting of a variable that is meant as a fraction of a total,
    -- that is, that for the most part varies from 0 to 1, but it continues smoothly
    -- outside those ranges
    --
    -- Properties independent of @exp:
    --   f(0) = 0
    --   f(0.5) = 0.5
    --   f(1) = 1

    -- Examples for different exponents:
    -- exp:   0.000  0.100  0.200  0.300  0.400  0.500  0.600  0.700  0.800  0.900  1.000
    -- 0.50:  0.000  0.053  0.113  0.184  0.276  0.500  0.724  0.816  0.887  0.947  1.000
    -- 0.67:  0.000  0.069  0.145  0.229  0.330  0.500  0.670  0.771  0.855  0.931  1.000
    -- 1.00:  0.000  0.100  0.200  0.300  0.400  0.500  0.600  0.700  0.800  0.900  1.000
    -- 1.50:  0.000  0.142  0.268  0.374  0.455  0.500  0.545  0.626  0.732  0.858  1.000
    -- 2.00:  0.000  0.180  0.320  0.420  0.480  0.500  0.520  0.580  0.680  0.820  1.000

    local weight
    if (x >= 0.5) then
        weight = 0.5 + ((x - 0.5) * 2)^exp / 2
    else
        weight = 0.5 - ((0.5 - x) * 2)^exp / 2
    end

    return weight
end

function fred_utils.print_weight_s(exp)
    local s1, s2 = '', ''
    for i=-5,15 do
        local x = 0.1 * i
        y = fred_utils.weight_s(x, exp)
        s1 = s1 .. string.format("%5.3f", x) .. '  '
        s2 = s2 .. string.format("%5.3f", y) .. '  '
    end
    print(s1)
    print(s2)
end

function fred_utils.scaled_hitchance(hc)
    local fac = 0.6
    local x = hc * fac
    local x0 = 0.5 * fac
    local scaled_hc = fred_utils.weight_s(x, 0.75)
    scaled_hc = scaled_hc / fred_utils.weight_s(x0, 0.75) * 0.5
    return scaled_hc
end

function fred_utils.get_unit_time_of_day_bonus(alignment, lawful_bonus)
    local multiplier = 1
    if (lawful_bonus ~= 0) then
        if (alignment == 'lawful') then
            multiplier = (1 + lawful_bonus / 100.)
        elseif (alignment == 'chaotic') then
            multiplier = (1 - lawful_bonus / 100.)
        elseif (alignment == 'liminal') then
            multipler = (1 - math.abs(lawful_bonus) / 100.)
        end
    end
    return multiplier
end


function fred_utils.cfg_default(parm)
    local cfg = {
        value_ratio = 0.8,  -- how valuable are own units compared to enemies

        leader_weight = 1.5,

        -- On average, next level unit costs ~1.75 times more than current unit
        -- TODO: come up with a more exact measure of this
        xp_weight = 0.75,

        terrain_defense_weight = 0.1,
        distance_leader_weight = 0.002,
        occupied_hex_penalty = 0.001,

        villages_per_unit = 2,

        enemy_leader_derating = 0.5,

        use_max_damage_weapons = false,

        ctd_limit = 0.5 -- TODO: is this a good value?
    }

    return cfg[parm]
end

function fred_utils.unit_value(unit_info, cfg)
    -- Get a gold-equivalent value for the unit

    local xp_weight = (cfg and cfg.xp_weight) or fred_utils.cfg_default('xp_weight')

    local unit_value = unit_info.cost

    -- If this is the side leader, make damage to it much more important
    if unit_info.canrecruit and (unit_info.side == wesnoth.current.side) then
        local leader_weight = (cfg and cfg.leader_weight) or fred_utils.cfg_default('leader_weight')
        unit_value = unit_value * leader_weight
    end

    -- Being closer to leveling makes the unit more valuable
    -- Square so that a few XP don't matter, but being close to leveling is important
    -- TODO: consider using a more precise measure here

    local xp_diff = unit_info.max_experience - unit_info.experience

    local xp_bonus
    if (xp_diff <= 1) then
        xp_bonus = 1.33
    elseif (xp_diff <= 8) then
        xp_bonus = 1.2
    else
        xp_bonus = (unit_info.experience / (unit_info.max_experience - 4))^2
    end

    unit_value = unit_value * (1. + xp_bonus * xp_weight)

    --print('FU.unit_value:', unit_info.id, unit_value, xp_bonus, xp_diff)

    return unit_value
end

function fred_utils.unit_power(unit_info, cfg)
    -- Use sqrt() here so that just missing a few HP does not matter much
    local hp_mod = math.sqrt(unit_info.hitpoints / unit_info.max_hitpoints)

    local power = fred_utils.unit_value(unit_info, cfg)
    power = power * hp_mod * unit_info.tod_mod

    return power
end

function fred_utils.unit_base_power(unit_info)
    -- Use sqrt() here so that just missing a few HP does not matter much
    local hp_mod = math.sqrt(unit_info.hitpoints / unit_info.max_hitpoints)

    local power = unit_info.max_damage
    power = power * hp_mod

    return power
end

function fred_utils.unit_current_power(unit_info)
    local power = fred_utils.unit_base_power(unit_info)
    power = power * unit_info.tod_mod

    return power
end

function fred_utils.unit_terrain_power(unit_info, x, y, gamedata)
    local power = fred_utils.unit_current_power(unit_info)

    local defense = FGUI.get_unit_defense(gamedata.unit_copies[unit_info.id], x, y, gamedata.defense_maps)
    power = power * defense

    --if fred_utils.get_fgumap_value(gamedata.village_map, x, y, 'owner') then
    --    power = power * 1.5
    --end

    return power
end

function fred_utils.get_value_ratio(gamedata)
    -- TODO: not sure what the best values are yet
    -- TODO: also not sure if leaders should be included here

    --print(' --- my units all_map')
    local my_power = 0
    for id,loc in pairs(gamedata.my_units) do
        if (not gamedata.unit_infos[id].canrecruit) then
            --print(id, gamedata.unit_infos[id].power)
            my_power = my_power + gamedata.unit_infos[id].power
        end
    end

    --print(' --- enemy units all_map')
    local enemy_power = 0
    for id,loc in pairs(gamedata.enemies) do
        if (not gamedata.unit_infos[id].canrecruit) then
            --print(id, gamedata.unit_infos[id].power)
            enemy_power = enemy_power + gamedata.unit_infos[id].power
        end
    end

    --print(' -----> enemy_power, my_power, enemy_power / my_power', enemy_power, my_power, enemy_power / my_power)

    local value_ratio = fred_utils.cfg_default('value_ratio')
    --print('default value_ratio', value_ratio)

    -- If power_ratio is smaller than 0.8 (= 1/1.25), we can use a smaller than
    -- unity, but we do want it to be larger than the power ratio
    -- TODO: this equation is experimental so far, needs to be tested

    --local tmp_value_ratio = my_power / (enemy_power + 1e-6) -- this is inverse of value_ratio
    --tmp_value_ratio = tmp_value_ratio - 0.25
    --if (tmp_value_ratio <= 0) then tmp_value_ratio = 0.01 end
    --tmp_value_ratio = 1. / tmp_value_ratio
    --print('tmp_value_ratio', tmp_value_ratio)

    local tmp_value_ratio = enemy_power / my_power

    if (tmp_value_ratio < value_ratio) then
        value_ratio = tmp_value_ratio
    end

    if (value_ratio < 0.6) then
        value_ratio = 0.6
    end

    --print('value_ratio', value_ratio)

    return value_ratio, my_power, enemy_power
end

function fred_utils.is_sufficient_power(my_power, enemy_power, value_ratio)
    -- Not sure yet how useful this is, just want a consistent way of doing this for now

    value_ratio = value_ratio or 1
    local threshold_absolute = 6
    local threshold_ratio = 0.1

    local eff_enemy_power = enemy_power * value_ratio
    local power_missing = eff_enemy_power - my_power

    -- True if either of the criteria is met
    if (power_missing <= threshold_absolute) or (power_missing / eff_enemy_power <= threshold_ratio) then
        return true, power_missing
    end

    return false, power_missing
end

function fred_utils.get_hit_chance(id, x, y, gamedata)
    -- TODO: This ignores steadfast and marksman, might be added later

    local hit_chance = FGUI.get_unit_defense(gamedata.unit_copies[id], x, y, gamedata.defense_maps)
    hit_chance = 1 - hit_chance

    -- If this is a village, give a bonus
    -- TODO: do this more quantitatively
    if gamedata.village_map[x] and gamedata.village_map[x][y] then
        hit_chance = hit_chance - 0.15
        if (hit_chance < 0) then hit_chance = 0 end
    end

    return hit_chance
end

function fred_utils.piecewise_influence(turns)
    -- Piecewise function for unit infuence function
    -- TODO: clean up the math, once we're done experimenting
    local int_turns = math.ceil(turns)
    local influence = 1  -- hex the unit is on needs special consideration

    if (int_turns ~= 0) then
        y0 = 1. / int_turns
        y1 = (y0 + 1. / (int_turns + 1)) / 2.
        -- Need to do it this way because ...
        neg_dx = (int_turns - turns) % 1
        influence = y1 + (y0 - y1) * neg_dx
    end
    influence = influence^2

    return influence
end

function fred_utils.moved_toward_zone(unit_copy, zone_cfgs, side_cfgs)
    --print(unit_copy.id, unit_copy.x, unit_copy.y)

    local start_hex = side_cfgs[unit_copy.side].start_hex

    local to_zone_id, score
    for zone_id,cfg in pairs(zone_cfgs) do
        local _,cost_new = wesnoth.find_path(unit_copy, cfg.center_hex[1], cfg.center_hex[2], { ignore_units = true })

        local old_hex = { unit_copy.x, unit_copy.y }
        unit_copy.x, unit_copy.y = start_hex[1], start_hex[2]

        local _,cost_start = wesnoth.find_path(unit_copy, cfg.center_hex[1], cfg.center_hex[2], { ignore_units = true })

        unit_copy.x, unit_copy.y = old_hex[1], old_hex[2]

        local rating = cost_start - cost_new

        --print('  ' .. zone_id, cost_start, cost_new, rating)

        if (not score) or (rating > score) then
            to_zone_id, score = zone_id, rating
        end
    end

    return to_zone_id
end

function fred_utils.get_influence_maps(my_attack_map, enemy_attack_map)
    -- For now, we use combined unit_power as the influence
    -- Note, these are somewhat different influence maps from those added in gamedata
    -- TODO: decide if we need both and reconcile

    local influence_map = {}

    -- Exclude the leader for the AI side, but not for the enemy side
    for x,arr in pairs(my_attack_map) do
        for y,data in pairs(arr) do
            local my_influence = data.power_no_leader

            if (not influence_map[x]) then influence_map[x] = {} end
            influence_map[x][y] = {
                my_influence = my_influence,
                enemy_influence = 0,
                influence = my_influence,
                tension = my_influence
            }
        end
    end

    for x,arr in pairs(enemy_attack_map) do
        for y,data in pairs(arr) do
            local enemy_influence = data.power_no_leader

            if (not influence_map[x]) then influence_map[x] = {} end
            if (not influence_map[x][y]) then
                influence_map[x][y] = {
                    my_influence = 0,
                    influence = 0,
                    tension = 0
                }
            end

            influence_map[x][y].enemy_influence = enemy_influence
            influence_map[x][y].influence = influence_map[x][y].influence - enemy_influence
            influence_map[x][y].tension = influence_map[x][y].tension + enemy_influence
        end
    end

    for x,arr in pairs(influence_map) do
        for y,data in pairs(arr) do
            local vulnerability = data.tension - math.abs(data.influence)
            influence_map[x][y].vulnerability = vulnerability
        end
    end

    return influence_map
end

return fred_utils
