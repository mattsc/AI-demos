-- AI configuration parameters

local fred_config = {}

function fred_config.get_cfg_parm(parm)
    local cfg = {
        value_ratio = 0.8,  -- how valuable are own units compared to enemies

        leader_weight = 1.5,

        xp_weight = 1.0,

        terrain_defense_weight = 0.1,
        distance_leader_weight = 0.002,
        occupied_hex_penalty = 0.001,

        villages_per_unit = 2,

        leader_derating = 0.5,

        use_max_damage_weapons = false
    }

    return cfg[parm]
end

return fred_config
