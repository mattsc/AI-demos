-- Setting up the functions so that Fred works in Wesnoth 1.12 and 1.13

local fred_compatibility = {}

function fred_compatibility.set_CA_args(arg1, arg2, arg3, use_1_12_syntax)
    -- @use_1_12_syntax: in CA debugging mode, use 1.12 syntax even in 1.13
    local ai_local, cfg, data
    if wesnoth.compare_versions(wesnoth.game_config.version, '<', '1.13.5') or use_1_12_syntax then
        ai_local, cfg, data = arg1, arg2, arg3.data
    else
        ai_local, cfg, data = ai, arg1, arg2
    end

    return ai_local, cfg, data
end

function fred_compatibility.put_unit(x, y, unit)
    if wesnoth.compare_versions(wesnoth.game_config.version, '>=', '1.13.2') then
        wesnoth.put_unit(unit, x, y)
    else
        wesnoth.put_unit(x, y, unit)
    end
end

function fred_compatibility.erase_unit(x, y)
    if wesnoth.compare_versions(wesnoth.game_config.version, '>=', '1.13.2') then
        wesnoth.erase_unit(x, y)
    else
        wesnoth.put_unit(x, y)
    end
end

return fred_compatibility
