local H = wesnoth.require "lua/helper.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local fred_hold_utils = {}

function fred_hold_utils.is_acceptable_location(unit_info, x, y, hit_chance, counter_stats, counter_attack, value_ratio, raw_cfg)
    -- Check whether are holding/advancing location has acceptable expected losses
    -- TODO: simplify the function call, fewer parameters

    -- If enemy cannot attack here, it's an acceptable location by default
    if (not next(counter_attack)) then return true end

    local show_debug = false
    if (x == 18) and (y == 11) and (unit_info.type == 'Troll Whelp') then
        show_debug = false
        --DBG.dbms(counter_stats)
    end

    FU.print_debug(show_debug, x, y, unit_info.id, unit_info.tod_mod)
    --DBG.dbms(raw_cfg.hold_core_slf)
    local is_core_hex = false
    if raw_cfg.hold_core_slf then
        is_core_hex = wesnoth.match_location(x, y, raw_cfg.hold_core_slf)
    end
    FU.print_debug(show_debug, '  is_core_hex:', is_core_hex)

    local is_good_terrain = (hit_chance <= 0.5)
    FU.print_debug(show_debug, '  is_good_terrain:', is_good_terrain)

    local defend_hard = is_core_hex and is_good_terrain
    FU.print_debug(show_debug, '  --> defend_hard:', defend_hard)

    -- When defend_hard=false, make the acceptable limits dependable on value_ratio
    -- TODO: these are pretty arbitrary values at this time; refine
    value_ratio = value_ratio or FU.cfg_default('value_ratio')
    FU.print_debug(show_debug, '  value_ratio:', value_ratio)

    local acceptable_hit_chance, acceptable_rating = 0, 0
    FU.print_debug(show_debug, '  default acceptable_hit_chance, acceptable_rating:', acceptable_hit_chance, acceptable_rating)


    if (value_ratio < 1) then
        -- acceptable_hit_chance: 0 at vr = 1, 0.25 at vr = 0.5
        acceptable_hit_chance = (1 - value_ratio) / 2.

        -- acceptable_rating: 0 at vr = 1, 4 at vr = 0.5
        acceptable_rating = (1 - value_ratio) * 8.

        -- Just in case (should not be necessary under most circumstances)
        if (acceptable_hit_chance < 0) then acceptable_hit_chance = 0 end
        if (acceptable_hit_chance > 0.25) then acceptable_hit_chance = 0.25 end
        if (acceptable_rating < 0) then acceptable_rating = 0 end
        if (acceptable_rating > 4) then acceptable_rating = 4 end
    end

    -- We raise the limit at good time of day
    if (unit_info.tod_mod == 1) then
        acceptable_rating = acceptable_rating + 1
    elseif (unit_info.tod_mod > 1) then
        acceptable_rating = acceptable_rating + 2
    end

    FU.print_debug(show_debug, '  -> acceptable_hit_chance, acceptable_rating:', acceptable_hit_chance, acceptable_rating)

    -- If chance to die is too large, do not use this position
    -- This is dependent on how good the terrain is
    -- For better terrain we allow a higher hit_chance than for bad terrain
    -- The argument is that we want to be on the good terrain, whereas
    -- taking a stance on bad terrain might not be worth it
    -- TODO: what value is good here?
    if defend_hard then -- bad terrain
        FU.print_debug(show_debug, '    defend hard', counter_stats.def_stat.hp_chance[0], counter_stats.rating_table.rating)
        if (counter_stats.def_stat.hp_chance[0] >= 0.25) then
            FU.print_debug(show_debug, '      not acceptable because chance to die too high:', counter_stats.def_stat.hp_chance[0])
            return false
        end
    else -- at least 50% defense
        FU.print_debug(show_debug, '    do not defend hard', counter_stats.def_stat.hp_chance[0], counter_stats.rating_table.rating)
        if (counter_stats.def_stat.hp_chance[0] > acceptable_hit_chance) then
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

return fred_hold_utils
