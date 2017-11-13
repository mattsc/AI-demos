-- AI configuration parameters

local fred_config = {}

function fred_config.get_cfg_parm(parm)
    -- Note: accessing these parameters is comparatively slow and should not be done over and over

    local cfg = {
        value_ratio = 0.8,  -- value of own units compared to enemies


        ----- Do not change values below unless you know exactly what you are doing -----

        xp_weight = 1.0,
        leader_weight = 1.5,
        leader_derating = 0.5,

        villages_per_unit = 2,

        terrain_defense_weight = 0.1,
        distance_leader_weight = 0.002,
        occupied_hex_penalty = 0.001,
        use_max_damage_weapons = false
    }

    return cfg[parm]
end

return fred_config
