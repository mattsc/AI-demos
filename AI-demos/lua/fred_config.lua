-- AI configuration parameters

-- Note: Assigning this table is slow compared to accessing values in it. It is
-- thus done outside the functions below, so that it is not done over and over
-- for each function call.
local cfg = {
    ----- Parameters in this section are meant to be adjustable for faction, scenario, ... -----

    aggression = 2,                  -- To first order, base ratio of acceptable damage: own / enemy
    min_aggression = 1.25,
    next_turn_influence_weight = 1,    -- Fraction of ToD influence change of next turn to take into account
    pushfactor_min_midpoint = 1.4,
    milk_xp_die_chance_limit = 0,      -- Enemy_leader die chance has to be greater than this to check for XP milking attack.
                                       -- Set to >=1 to disable. Engine uses 0 if this is set to negative values.

    action_base_ratings = {          -- setting a rating to <= 0 disables the action
        protect_leader_eval = 32000, -- eval only
        attack_leader_threat = 31000,
        protect_leader_exec = 30000,

        fav_attack = 27000,
        advance_toward_leader = 26000,
        attack = 25000,

        protect = 22000,
        grab_villages = 21000,
        hold = 20000,

        recruit = 12000,
        retreat = 11000,
        advance = 10000,
        advance_all_map = 1000
    },


    ----- Do not change values below unless you know exactly what you are doing -----

    -- Unit value parameters
    xp_weight = 1.0,
    leader_weight = 1.5,
    leader_derating = 0.5,

    influence_falloff_floor = 0.5,
    influence_falloff_exp = 2,

    winning_ratio = 1.25,
    losing_ratio = 0.8,

    protect_others_ratio = 1.1,
    protect_min_value = 2,

    -- Leader rating parameters
    leader_unthreatened_hex_bonus = 500,
    leader_village_bonus = 10,
    leader_village_grab_bonus = 3,
    leader_moves_left_factor = 0.1,
    leader_unit_in_way_penalty = - 0.01,
    leader_unit_in_way_no_moves_penalty = - 1000,
    leader_eld_factor = - 0.01,

    -- Village grabbing parameters
    villages_per_unit = 2,

    -- Attack rating parameters
    terrain_defense_weight = 0.1,
    distance_leader_weight = 0.002,
    occupied_hex_penalty = 0.001,
    leader_max_die_chance = 0.02,
    leader_protect_weight = 1.0,
    unit_protect_weight = 0.5,
    village_protect_weight = 0.5,
    castle_protect_weight = 0.5,

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
        -- 'ALT' and 'PL': use 'att'
        att = {
            units = { GV = 1, MLV = 1, MLK = 0, ret = 1 },
            hexes = { GV = 1, rec = 1, MLV = 1, MLK = 1, }
        },
        hold = {
            units = { GV = 1, MLV = 0, MLK = 0, ret = 1 },
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
