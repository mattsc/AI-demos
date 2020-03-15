local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local fred_retreat = {}

function fred_retreat.get_retreat_action(zone_cfg, fred_data)
    DBG.print_debug_time('eval', fred_data.turn_start_time, '  - retreat evaluation: ' .. zone_cfg.zone_id .. ' (' .. string.format('%.2f', zone_cfg.rating) .. ')')

    -- Combines moving leader to village or keep, and retreating other units.
    -- These are put in here together because we might want to weigh which one
    -- gets done first in the end.

    local move_data = fred_data.move_data
    local leader_objectives = fred_data.ops_data.objectives.leader
    --DBG.dbms(leader_objectives, false, 'leader_objectives')

    if move_data.my_units_MP[move_data.my_leader.id] then
        if leader_objectives.village then
            local action = {
                units = { move_data.my_leader },
                dsts = { { leader_objectives.village[1], leader_objectives.village[2] } },
                action_str = zone_cfg.action_str .. ' (move leader to village)'
            }
            --DBG.dbms(action, false, 'action')

            return action
        end

        -- This is only for moving leader back toward keep. Moving to a keep for
        -- recruiting is done as part of the recruitment action
        if leader_objectives.keep then
            local action = {
                units = { move_data.my_leader },
                dsts = { { leader_objectives.keep[1], leader_objectives.keep[2] } },
                action_str = zone_cfg.action_str .. ' (move leader to keep)'
            }
            --DBG.dbms(action, false, 'action')

            leader_objectives.keep = nil

            return action
        end

        if leader_objectives.other then
            local action = {
                units = { move_data.my_leader },
                dsts = { { leader_objectives.other[1], leader_objectives.other[2] } },
                action_str = zone_cfg.action_str .. ' (move leader toward keep or safety)'
            }
            --DBG.dbms(action, false, 'action')

            leader_objectives.other = nil

            return action
        end
    end

    --DBG.dbms(fred_data.ops_data.reserved_actions)
    local retreaters = {}
    for _,action in pairs(fred_data.ops_data.reserved_actions) do
        if (action.action_id == 'ret') then
            retreaters[action.id] = move_data.units[action.id]
        end
    end
    --DBG.dbms(retreaters, false, 'retreaters')

    if next(retreaters) then
        local retreat_utilities = FBU.retreat_utilities(move_data, fred_data.ops_data.behavior.orders.value_ratio)
        local retreat_combo = FRU.find_best_retreat(retreaters, retreat_utilities, fred_data)
        --DBG.dbms(retreat_combo, false, 'retreat_combo')

        if retreat_combo then
            local action = {
                units = {},
                dsts = {},
                action_str = zone_cfg.action_str
            }

            for src,dst in pairs(retreat_combo) do
                local src_x, src_y = math.floor(src / 1000), src % 1000
                local dst_x, dst_y = math.floor(dst / 1000), dst % 1000
                local unit = { src_x, src_y, id = move_data.my_unit_map[src_x][src_y].id }
                table.insert(action.units, unit)
                table.insert(action.dsts, { dst_x, dst_y })
            end
            --DBG.dbms(action, false, 'action')

            return action
        end
    end
end

return fred_retreat
