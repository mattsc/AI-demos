local AH = wesnoth.require "ai/lua/ai_helper.lua"

local fred_move_leader_utils = {}

function fred_move_leader_utils.move_eval(move_unit_away, fred_data)
    -- @move_unit_away: if set, try to move own unit out of way
    --   Default is not to do this.

    local score = 480000
    local low_score = 1000

    local move_data = fred_data.move_data
    local leader = move_data.leaders[wesnoth.current.side]

    -- If the leader cannot move, don't do anything
    if move_data.my_units_noMP[leader.id] then
        return 0
    end

    -- If the leader already is on a keep, don't do anything
    if (wesnoth.get_terrain_info(wesnoth.get_terrain(leader[1], leader[2])).keep) then
        return 0
    end

    local leader_copy = move_data.unit_copies[leader.id]

    local enemy_leader_cx, enemy_leader_cy = AH.cartesian_coords(move_data.enemy_leader_x, move_data.enemy_leader_y)

    local width, height, border = wesnoth.get_map_size()
    local keeps = wesnoth.get_locations {
        terrain = 'K*,K*^*,*^K*', -- Keeps
        x = '1-'..width,
        y = '1-'..height
    }

    local max_rating, best_keep = -10  -- Intentionally not set to less than this!!
                                       -- so that the leader does not try to get to unreachable locations
    for _,keep in ipairs(keeps) do
        -- Count keep closer to the enemy leader as belonging to the enemy
        local dist_leader = wesnoth.map.distance_between(keep[1], keep[2], leader[1], leader[2])
        local dist_enemy_leader = wesnoth.map.distance_between(keep[1], keep[2], move_data.enemy_leader_x, move_data.enemy_leader_y)
        local is_enemy_keep = dist_enemy_leader < dist_leader
        --std_print(keep[1], keep[2], dist_leader, dist_enemy_leader, is_enemy_keep)

        -- Is there a unit on the keep that cannot move any more?
        local unit_in_way = move_data.my_unit_map_noMP[keep[1]]
            and move_data.my_unit_map_noMP[keep[1]][keep[2]]

        if (not is_enemy_keep) and (not unit_in_way) then
            local path, cost = wesnoth.find_path(leader_copy, keep[1], keep[2])

            cost = cost + leader_copy.max_moves - leader_copy.moves
            local turns = math.ceil(cost / leader_copy.max_moves)

            -- Main rating is how long it will take the leader to get there
            local rating = - turns

            -- Minor rating is distance from enemy leader (the closer the better)
            local keep_cx, keep_cy = AH.cartesian_coords(keep[1], keep[2])
            local dist_enemy_leader = math.sqrt((keep_cx - enemy_leader_cx)^2 + (keep_cy - enemy_leader_cx)^2)
            rating = rating - dist_enemy_leader / 100.

            if (rating > max_rating) then
                max_rating = rating
                best_keep = keep
            end
        end
    end

    if best_keep then
        -- If the leader can reach the keep, but there's a unit on it: wait
        -- Except when move_unit_away is set
        if (not move_unit_away)
            and move_data.reach_maps[leader.id][best_keep[1]]
            and move_data.reach_maps[leader.id][best_keep[1]][best_keep[2]]
            and move_data.my_unit_map_MP[best_keep[1]]
            and move_data.my_unit_map_MP[best_keep[1]][best_keep[2]]
        then
            return 0
        end

        -- We can always use 'ignore_own_units = true', as the if block
        -- above catches the case when that should not be done.
        local next_hop = AH.next_hop(leader_copy, best_keep[1], best_keep[2], { ignore_own_units = true })

        -- Only move the leader if he'd actually move
        if (next_hop[1] ~= leader_copy.x) or (next_hop[2] ~= leader_copy.y) then
            fred_data.MLK_leader = leader_copy
            fred_data.MLK_keep = best_keep
            fred_data.MLK_dst = next_hop

            -- This is done with high priority if the leader can get to the keep,
            -- otherwise with very low priority
            if (next_hop[1] == best_keep[1]) and (next_hop[2] == best_keep[2]) then
                local action = {
                    units = { { id = leader.id } },
                    dsts = { { next_hop[1], next_hop[2] } },
                    action_str = 'move leader to keep',
                    partial_move = true
                }

                return score, action, next_hop, best_keep
            else
                return low_score, nil, next_hop, best_keep
            end
        end
    end

    return 0
end


return fred_move_leader_utils
