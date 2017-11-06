function set_CA_args(arg1, arg2, arg3)
    local ai, cfg, data = ai, arg1, arg2
    if wesnoth.compare_versions(wesnoth.game_config.version, '<', '1.13.5') then
        ai, cfg, data = arg1, arg2, arg3.data
    end

    return ai, cfg, data
end
