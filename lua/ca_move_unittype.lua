local H = wesnoth.require "lua/helper.lua"

local ca_move_unittype = {}

function ca_move_unittype:evaluation(ai, cfg)
    local units = wesnoth.get_units {
        side = wesnoth.current.side,
        type = cfg.type,
        formula = '$this_unit.moves > 0'
    }

    if units[1] then return cfg.score end
    return 0
end

function ca_move_unittype:execution(ai, cfg)
    local unit = wesnoth.get_units {
        side = wesnoth.current.side,
        type = cfg.type,
        formula = '$this_unit.moves > 0'
    }[1]

    -- Find path toward the goal
    local path, cost = wesnoth.find_path(unit, cfg.goal_x, cfg.goal_y)

    -- If there's no path to goal, or all path hexes are occupied,
    -- use current position as default
    local next_hop = { unit.x, unit.y }

    -- Go through path to find farthest reachable, unoccupied hex
    -- Start at second index, as the first is just the unit position itself
    for i = 2,#path do
        local sub_path, sub_cost = wesnoth.find_path( unit, path[i][1], path[i][2])

        -- If we can get to that hex, check whether it is occupied
        -- (can only be own or allied units as enemy unit hexes are not reachable)
        if sub_cost <= unit.moves then
            local unit_in_way = wesnoth.get_unit(path[i][1], path[i][2])
            if not unit_in_way then
                next_hop = path[i]
            end
        else  -- otherwise stop here; rest of path is outside movement range
            break
        end
    end

    --print('Moving:', unit.id, '-->', next_hop[1], next_hop[2])
    ai.move_full(unit, next_hop[1], next_hop[2])
end

return ca_move_unittype
