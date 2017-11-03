----- CA: Clear self.data table at end of turn (max_score: 1) -----
-- This will be blacklisted after first execution each turn, which happens at the very end of each turn

local ca_clear_self_data = {}

function ca_clear_self_data:evaluation(ai, cfg, self)
    return 1
end

function ca_clear_self_data:execution(ai, cfg, self)
    --print(' Clearing self.data table at end of Turn ' .. wesnoth.current.turn)

    -- This is mostly done so that there is no chance of corruption of savefiles
    self.data = {}
end

return ca_clear_self_data
