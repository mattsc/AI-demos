local H = wesnoth.require "lua/helper.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local fred_hold_utils = {}

function fred_hold_utils.is_acceptable_location(unit_info, x, y, hit_chance, counter_stats, counter_attack, value_ratio, raw_cfg, gamedata, cfg)
    -- Check whether are holding/advancing location has acceptable expected losses
    --
    -- Optional parameters:
    --  @cfg: override the default settings/calculations for these parameters:
    --    - defend_hard
    --    - acceptable_rating
    -- TODO: simplify the function call, fewer parameters

    -- If enemy cannot attack here, it's an acceptable location by default
    if (not next(counter_attack)) then return true end

    local show_debug = false
    if (x == 18) and (y == 9) and (unit_info.type == 'Orcish Assassin') then
        show_debug = true
        --DBG.dbms(counter_stats)
    end

    FU.print_debug(show_debug, x, y, unit_info.id, unit_info.tod_mod)
    --DBG.dbms(raw_cfg.hold_core_slf)
    local is_core_hex = false
    if raw_cfg.hold_core_slf then
        is_core_hex = wesnoth.match_location(x, y, raw_cfg.hold_core_slf)
    end
    FU.print_debug(show_debug, '  is_core_hex:', is_core_hex)

    local is_good_terrain = (hit_chance <= unit_info.good_terrain_hit_chance)
    FU.print_debug(show_debug, '  is_good_terrain:', is_good_terrain)

    local defend_hard = is_core_hex and is_good_terrain

    -- TODO: this is inefficient, clean up later
    -- Note, need to check vs. 'nil' as 'false' is a possible value
    if cfg and (cfg.defend_hard ~= nil) then
        FU.print_debug(show_debug, '  overriding defend_hard fron cfg:', cfg.defend_hard)
        defend_hard = cfg.defend_hard
    end

    FU.print_debug(show_debug, '  --> defend_hard:', defend_hard)

    -- When defend_hard=false, make the acceptable limits dependable on value_ratio
    -- TODO: these are pretty arbitrary values at this time; refine
    value_ratio = value_ratio or FU.cfg_default('value_ratio')
    FU.print_debug(show_debug, '  value_ratio:', value_ratio)

    local acceptable_die_chance, acceptable_rating = 0, 0
    FU.print_debug(show_debug, '  default acceptable_die_chance, acceptable_rating:', acceptable_die_chance, acceptable_rating)


    if (value_ratio < 1) then
        -- acceptable_die_chance: 0 at vr = 1, 0.25 at vr = 0.5
        acceptable_die_chance = (1 - value_ratio) / 2.

        -- acceptable_rating: 0 at vr = 1, 4 at vr = 0.5
        acceptable_rating = (1 - value_ratio) * 8.

        -- Just in case (should not be necessary under most circumstances)
        if (acceptable_die_chance < 0) then acceptable_die_chance = 0 end
        if (acceptable_die_chance > 0.25) then acceptable_die_chance = 0.25 end
        if (acceptable_rating < 0) then acceptable_rating = 0 end
        if (acceptable_rating > 4) then acceptable_rating = 4 end
    end

    -- We raise the limit at good time of day
    if (unit_info.tod_mod == 1) then
        acceptable_rating = acceptable_rating + 1
    elseif (unit_info.tod_mod > 1) then
        acceptable_rating = acceptable_rating + 2
    end

    -- TODO: this is inefficient, clean up later
    if cfg and cfg.acceptable_rating then
        FU.print_debug(show_debug, '  overriding acceptable_rating fron cfg:', cfg.acceptable_rating)
        acceptable_rating = cfg.acceptable_rating
    end


    FU.print_debug(show_debug, '  -> acceptable_die_chance, acceptable_rating:', acceptable_die_chance, acceptable_rating)

    if defend_hard then
        local acceptable_die_chance = 0.25
        if gamedata.village_map[x] and gamedata.village_map[x][y] then
           acceptable_die_chance = 0.5
        end

        FU.print_debug(show_debug, '    defend hard', counter_stats.def_stat.hp_chance[0], counter_stats.rating_table.rating)
        if (counter_stats.def_stat.hp_chance[0] > acceptable_die_chance) then
            FU.print_debug(show_debug, '      not acceptable because chance to die too high:', counter_stats.def_stat.hp_chance[0] .. ' > ' .. acceptable_die_chance)
            return false
        end
    else
        FU.print_debug(show_debug, '    do not defend hard', counter_stats.def_stat.hp_chance[0], counter_stats.rating_table.rating)
        if (counter_stats.def_stat.hp_chance[0] > acceptable_die_chance) then
            FU.print_debug(show_debug, '      not acceptable because chance to die too high:', counter_stats.def_stat.hp_chance[0])
            return false
        end
        -- TODO: not sure yet if this should be used
        -- TODO: might have to depend on enemy faction
        -- Also if the relative loss is more than X HP (X/12 the
        -- value of a grunt) for any single attack
        if (counter_stats.rating_table.rating >= acceptable_rating) then
            FU.print_debug(show_debug, '      not acceptable because rating too bad:', counter_stats.rating_table.rating)
            return false
        end
    end

    return true
end

function fred_hold_utils.is_acceptable_hold(combo_stats, raw_cfg, zone_cfg, gamedata)
    --DBG.dbms(combo_stats)
    --DBG.dbms(zone_cfg)

    local show_debug = false
    if (x == 18) and (y == 12) and (unit_info.type == 'Orcish Grunt') then
        show_debug = false
    end

    FU.print_debug(show_debug, '\nfred_hold_utils.is_acceptable_hold')

    local n_core, n_forward = 0, 0
    local power_forward = 0
    local n_total = #combo_stats

    for _,cs in ipairs(combo_stats) do
        FU.print_debug(show_debug, '  ' .. cs.id, cs.x, cs.y)
        --DBG.dbms(raw_cfg.hold_core_slf)

        local is_good_terrain = (cs.hit_chance <= gamedata.unit_infos[cs.id].good_terrain_hit_chance)
        FU.print_debug(show_debug, '    is_good_terrain:', is_good_terrain, cs.hit_chance)

        local is_core_hex = false
        if raw_cfg.hold_core_slf then
            is_core_hex = wesnoth.match_location(cs.x, cs.y, raw_cfg.hold_core_slf)
        end

        -- Only good terrain hexes count into the core hex count here
        -- TODO: this is preliminary for testing right now
        if is_core_hex then
            if is_good_terrain then
                n_core = n_core + 1
            else
                n_forward = n_forward + 1
                power_forward = power_forward + gamedata.unit_infos[cs.id].power
            end
        end
        FU.print_debug(show_debug, '    is_core_hex:', is_core_hex)

        local is_forward_hex = false
        if raw_cfg.hold_forward_slf then
            is_forward_hex = wesnoth.match_location(cs.x, cs.y, raw_cfg.hold_forward_slf)
        end
        if is_forward_hex then
            n_forward = n_forward + 1
            power_forward = power_forward + gamedata.unit_infos[cs.id].power
        end
        FU.print_debug(show_debug, '    is_forward_hex:', is_forward_hex)
    end

    FU.print_debug(show_debug, '    n_total, n_core, n_forward:', n_total, n_core, n_forward)
    --FU.print_debug(show_debug, '    power_forward, power_threats:', power_forward, zone_cfg.power_threats)

    --if (n_forward > 0) and (power_forward < zone_cfg.power_threats) then
    --    return false
    --end

    -- Forward hexes are only accepted if:
    --  - there are no core hexes being held
    --  - or: the rating is positive
    if (n_forward < n_total) or (n_forward == 1) then -- This is a place_holder for now
        if (n_forward > 0) then
            for _,cs in ipairs(combo_stats) do
                FU.print_debug(show_debug, '  ' .. cs.id, cs.counter_rating)
                -- Note: this is the counter attack rating -> negative is good
                if (cs.counter_rating > 0) then
                    FU.print_debug(show_debug, '    forward hex not acceptable:', cs.id, cs.counter_rating)
                    return false
                end
            end
        end
    end

    return true
end

return fred_hold_utils
