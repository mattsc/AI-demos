----- CA: Clear data table at end of turn (max_score: 1) -----
-- This will be blacklisted after first execution each turn, which happens at the very end of each turn

wesnoth.require "~/add-ons/AI-demos/lua/set_CA_args.lua"

local ca_clear_self_data = {}

function ca_clear_self_data:evaluation()
    return 1
end

function ca_clear_self_data:execution(arg1, arg2, arg3)
    local ai, cfg, data = set_CA_args(arg1, arg2, arg3)

    --print(' Clearing data table at end of Turn ' .. wesnoth.current.turn)

    -- This is mostly done so that there is no chance of corruption of savefiles
    data = { recruit = data.recruit }
end

return ca_clear_self_data
