-- AI configuration parameters

-- Note: Assigning this table is slow compared to accessing values in it. It is
-- thus done outside the functions below, so that it is not done over and over
-- for each function call.
local cfg = {
    ----- Parameters in this section are meant to be adjustable for faction, scenario, ... -----

    aggression = 1.5,                  -- To first order, base ratio of acceptable damage: own / enemy
    min_aggression = 1.25,
    leader_threat_mult = 1.33,
    next_turn_influence_weight = 1,  -- Fraction of ToD influence change of next turn to take into account


    ----- Do not change values below unless you know exactly what you are doing -----

    -- Unit value parameters
    xp_weight = 1.0,
    leader_weight = 1.5,
    leader_derating = 0.5,

    influence_falloff_floor = 0.5,
    influence_falloff_exp = 2,

    winning_ratio = 1.25,
    losing_ratio = 0.8,

    protect_others_ratio = 1.2,

    -- Leader rating parameters
    leader_unthreatened_hex_bonus = 500,
    leader_village_bonus = 3,
    leader_moves_left_factor = 0.1,
    leader_unit_in_way_penalty = - 0.01,
    leader_eld_factor = - 0.01,

    -- Village grabbing parameters
    villages_per_unit = 2,

    -- Attack rating parameters
    terrain_defense_weight = 0.1,
    distance_leader_weight = 0.002,
    occupied_hex_penalty = 0.001,
    leader_max_die_chance = 0.02,

    -- Hold rating parameters
    vuln_weight = 0.25,
    forward_weight = 0.02,
    hold_counter_weight = 0.1,
    protect_forward_weight = 1,

    -- Retreat rating parameters
    hp_inflection_base = 20,

    -- Delayed action scores
    score_grab_village = 20,
    score_leader_to_keep = 10,
    score_recruit = 9,
    score_leader_to_village = 8
}

local interaction_matrix = {
    abbrevs = {
		ALT = 'attack_leader_threat',
		PL  = 'protect_leader',
		FA  = 'favorable_attack',
		att = 'attack',
		pro = 'protect',
		GV  = 'grab_village',
		adv = 'advance',
		rec = 'recruit',
		MLV = 'move_leader_to_village',
		MLK = 'move_leader_to_keep',
		ret = 'retreat'
    },
    -- A penalty multiplier of 0 is equivalent to not setting it in the first place.
    -- If one is set to 0 here, that is done to emphasize that it should be ignored.
    penalties = {
        att = {
            units = { GV = 1, MLV = 1, MLK = 0, ret = 1 },
            hexes = { GV = 1, rec = 1, MLV = 1, MLK = 1, }
        },
        GV = {
            units = { MLV = 1000, Ret = 0 }, -- retreaters may be used
            hexes = { MLV = 1000 }
        }
    }
}


local fred_config = {}

function fred_config.get_cfg_parm(parm)
    return cfg[parm]
end

function fred_config.interaction_matrix()
    return interaction_matrix
end

return fred_config
