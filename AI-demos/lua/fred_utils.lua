local H = wesnoth.require "lua/helper.lua"
local W = H.set_wml_action_metatable {}
local FGUI = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_utils_incremental.lua"

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
                out = tonumber(out) or 'nan'
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

function fred_utils.get_fgumap_value(map, x, y, key, alt_value)
    return (map[x] and map[x][y] and map[x][y][key]) or alt_value
end

function fred_utils.set_fgumap_value(map, x, y, key, value)
    if (not map[x]) then map[x] = {} end
    if (not map[x][y]) then map[x][y] = {} end
    map[x][y][key] = value
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
        value_ratio = 1.0,  -- how valuable are own units compared to enemies

        leader_weight = 1.5,

        -- On average, next level unit costs ~1.75 times more than current unit
        -- TODO: come up with a more exact measure of this
        xp_weight = 0.75,

        leveling_weight = 1.,

        terrain_defense_weight = 0.1,
        distance_leader_weight = 0.002,
        occupied_hex_penalty = 0.001,

        use_max_damage_weapons = false
    }

    return cfg[parm]
end

function fred_utils.unit_value(unit_info, cfg)
    -- Get a gold-equivalent value for the unit

    local leader_weight = (cfg and cfg.leader_weight) or fred_utils.cfg_default('leader_weight')
    local xp_weight = (cfg and cfg.xp_weight) or fred_utils.cfg_default('xp_weight')

    local unit_value = unit_info.cost

    -- If this is the side leader, make damage to it much more important
    if unit_info.canrecruit then
        unit_value = unit_value * leader_weight
    end

    -- Being closer to leveling makes the unit more valuable
    -- Square so that a few XP don't matter, but being close to leveling is important
    -- TODO: consider using a more precise measure here
    local xp_bonus = (unit_info.experience / unit_info.max_experience)^2
    unit_value = unit_value * (1. + xp_bonus * xp_weight)

    --print('FU.unit_value:', unit_info.id, unit_value)

    return unit_value
end

function fred_utils.unit_power(unit_info, cfg)
    -- Use sqrt() here so that just missing a few HP does not matter much
    local hp_mod = math.sqrt(unit_info.hitpoints / unit_info.max_hitpoints)

    local power = fred_utils.unit_value(unit_info, cfg)
    power = power * hp_mod * unit_info.tod_mod

    return power
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

function fred_utils.get_influence_maps(my_attack_map, enemy_attack_map)
    -- For now, we use combined unit_power as the influence

    local influence_map = {}

    for x,arr in pairs(my_attack_map) do
        for y,data in pairs(arr) do
            local my_influence = data.power

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
            local enemy_influence = data.power

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
