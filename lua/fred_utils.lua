local fred_utils = {}

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
