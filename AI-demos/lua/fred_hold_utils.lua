local H = wesnoth.require "lua/helper.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local fred_hold_utils = {}

function fred_hold_utils.is_acceptable_location(id, x, y, hit_chance, counter_stats, raw_cfg)
    -- Check whether are holding/advancing location has acceptable expected losses

    local show_debug = false

    FU.print_debug(show_debug, x, y)

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
        if (counter_stats.def_stat.hp_chance[0] > 0) then
            FU.print_debug(show_debug, '      not acceptable because chance to die too high:', counter_stats.def_stat.hp_chance[0])
            return false
        end
        -- TODO: not sure yet if this should be used
        -- TODO: might have to depend on enemy faction
        -- Also if the relative loss is more than X HP (X/12 the
        -- value of a grunt) for any single attack
        if (counter_stats.rating_table.rating >= 2) then
            FU.print_debug(show_debug, '      not acceptable because chance to die too high:', counter_stats.def_stat.hp_chance[0])
            return false
        end
    end

    return true
end

return fred_hold_utils
