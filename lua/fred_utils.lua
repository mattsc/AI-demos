local H = wesnoth.require "lua/helper.lua"
local W = H.set_wml_action_metatable {}

local fred_utils = {}

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

function fred_utils.cfg_default(parm)
    local cfg = {
        value_ratio = 0.8,  -- how valuable are own units compared to enemies

        leader_weight = 2.,

        -- On average, next level unit costs ~1.75 times more than current unit
        -- TODO: come up with a more exact measure of this
        xp_weight = 0.75,

        level_weight = 1.,

        defender_starting_damage_weight = 0.33,
        defense_weight = 0.1,
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
    -- TODO: consider using a more precise measure here
    local xp_bonus = unit_info.experience / unit_info.max_experience
    unit_value = unit_value * (1. + xp_bonus * xp_weight)

    --print('FU.unit_value:', unit_info.id, unit_value)

    return unit_value
end

return fred_utils
