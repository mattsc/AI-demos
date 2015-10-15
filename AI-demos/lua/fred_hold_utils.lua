local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"

local fred_hold_utils = {}

function fred_hold_utils.is_acceptable_location(hit_chance, counter_stats)
    -- Check whether are holding/advancing location has acceptable expected losses

    local show_debug = true

    -- If chance to die is too large, do not use this position
    -- This is dependent on how good the terrain is
    -- For better terrain we allow a higher hit_chance than for bad terrain
    -- The argument is that we want to be on the good terrain, whereas
    -- taking a stance on bad terrain might not be worth it
    -- TODO: what value is good here?
    if (hit_chance > 0.5) then -- bad terrain
        FU.print_debug(show_debug, '    bad terrain', counter_stats.def_stat.hp_chance[0], counter_stats.rating_table.rating)
        if (counter_stats.def_stat.hp_chance[0] > 0) then
            FU.print_debug(show_debug, '      not acceptable because chance to die too high:', counter_stats.def_stat.hp_chance[0])
            return false
        end
        -- TODO: not sure yet if this should be used
        -- TODO: might have to depend on enemy faction
        -- Also if the relative loss is more than X HP (X/12 the
        -- value of a grunt) for any single attack
        if (counter_stats.rating_table.rating >= 6) then
            FU.print_debug(show_debug, '      not acceptable because chance to die too high:', counter_stats.def_stat.hp_chance[0])
            return false
        end
    else -- at least 50% defense
        FU.print_debug(show_debug, '    good terrain', counter_stats.def_stat.hp_chance[0], counter_stats.rating_table.rating)
        if (counter_stats.def_stat.hp_chance[0] >= 0.25) then
            FU.print_debug(show_debug, '      not acceptable because chance to die too high:', counter_stats.def_stat.hp_chance[0])
            return false
        end
    end

    return true
end

return fred_hold_utils
