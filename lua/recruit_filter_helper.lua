helper = wesnoth.require "lua/helper.lua"

function archer_target(unit)
    if wesnoth.unit_resistance(unit, "fire") <= 100 and wesnoth.unit_resistance(unit, "pierce") <= 100 then
        return false
    end
    for att in helper.child_range(unit.__cfg, "attack") do
        if att.range == 'ranged' then
            return false
        end
    end
    return true
end

function troll_target(unit)
    if wesnoth.unit_resistance(unit, "impact") <= 100 then
        return false
    end
    return true
end

function not_living(unit)
    return not (not helper.get_child(unit.__cfg, "status").not_living)
end
