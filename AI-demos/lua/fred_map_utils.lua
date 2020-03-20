local H = wesnoth.require "helper"
local AH = wesnoth.require "ai/lua/ai_helper.lua"
local FDI = wesnoth.require "~/add-ons/AI-demos/lua/fred_data_incremental.lua"
local FGM = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_map.lua"
local FCFG = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_config.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"
local COMP = wesnoth.require "~/add-ons/AI-demos/lua/compatibility.lua"

local fred_map_utils = {}

function fred_map_utils.moved_toward_zone(unit_copy, fronts, raw_cfgs, side_cfgs)
    --std_print('moved_toward_zone: ' .. unit_copy.id, unit_copy.x, unit_copy.y)
    local start_hex = side_cfgs[unit_copy.side].start_hex

    -- Want "smooth" movement cost
    local old_moves = unit_copy.moves
    local old_max_moves = unit_copy.max_moves
    unit_copy.moves = 98
    COMP.change_max_moves(unit_copy, 98)

    local to_zone_id, score
    for zone_id,raw_cfg in pairs(raw_cfgs) do
        local front = fronts.zones[zone_id]
        local x,y = 0, 0
        -- If front hex does not exist or is not passable for a unit, use center hex instead
        -- TODO: not clear whether using a passable hex close to the front is better in this case
        -- TODO: check whether this is too expensive
        -- Disable using fronts for now, it's too volatile, but leave the code in place
        -- TODO: reenable or remove later
        if false and front and (FDI.get_unit_movecost(unit_copy, front.x, front.y, fred_data.caches.movecost_maps) < 99) then
            x, y = front.x, front.y
        else
            for _,hex in ipairs(raw_cfg.center_hexes) do
                x, y = x + hex[1], y + hex[2]
            end
            x, y = x / #raw_cfg.center_hexes, y / #raw_cfg.center_hexes
        end

        local _,cost_new = wesnoth.find_path(unit_copy, x, y, { ignore_units = true })

        local old_hex = { unit_copy.x, unit_copy.y }
        unit_copy.x, unit_copy.y = start_hex[1], start_hex[2]

        local _,cost_start = wesnoth.find_path(unit_copy, x, y, { ignore_units = true })

        unit_copy.x, unit_copy.y = old_hex[1], old_hex[2]

        local rating = cost_start - cost_new
        -- As a tie breaker, prefer zone that is originally farther away
        rating = rating + cost_start / 1000

        --std_print('  ' .. zone_id, x .. ',' .. y, cost_start .. ' - ' .. cost_new .. ' ~= ' .. rating)

        if (not score) or (rating > score) then
           to_zone_id, score = zone_id, rating
        end
    end

    unit_copy.moves = old_moves
    COMP.change_max_moves(unit_copy, old_max_moves)

    return to_zone_id
end

function fred_map_utils.influence_custom_cost(x, y, unit_copy, influence_mult, influence_map, fred_data)
    -- Custom cost function for finding path with penalty for negative full-move influence.
    -- This does not take potential loss of MP at the end of a move into account.
    local cost = FDI.get_unit_movecost(unit_copy, x, y, fred_data.caches.movecost_maps)
    if (cost >= 99) then return cost end

    if FGM.get_value(fred_data.move_data.enemy_map, x, y, 'id') then
        --std_print(x, y, 'enemy')
        cost = cost + 99
    end

    local infl = FGM.get_value(influence_map, x, y, 'full_move_influence') or -99

    if (infl < 0) then
        --std_print(x, y, infl, infl * influence_mult)
        cost = cost - infl * influence_mult
    end

    return cost
end

function fred_map_utils.smooth_cost_map(unit_proxy, loc, is_inverse_map, movecost_maps_cache)
    -- Smooth means that it does not add discontinuities for not having enough
    -- MP left to enter certain terrain at the end of a turn. This is done by setting
    -- moves and max_moves to 98 (99 being the move cost for impassable terrain).
    -- Thus, there could still be some such effect for very long paths, but this is
    -- good enough for all practical purposes.
    --
    -- Returns an FG_map with the cost (key: 'cost')
    --
    -- INPUTS:
    --  @unit_proxy: use the proxy here, because it might have already been extracted
    --     in the calling function (to save time)
    --  @loc (optional): the hex from where to calculate the cost map. If omitted, use
    --     the current location of the unit
    --  @is_inverse_map (optional): if true, calculate the inverse map, that is, the
    --     move cost for moving toward @loc, rather than away from it. These two are
    --     almost the same, except for the asymmetry of entering the two extreme hexes
    --     of any path.

    local old_loc, unit_in_way_proxy
    if loc and ((loc[1] ~= unit_proxy.x) or (loc[2] ~= unit_proxy.y)) then
        unit_in_way_proxy = COMP.get_unit(loc[1], loc[2])
        if unit_in_way_proxy then COMP.extract_unit(unit_in_way_proxy) end
        old_loc = { unit_proxy.x, unit_proxy.y }
        unit_proxy.loc = loc
    end
    local old_moves, old_max_moves = unit_proxy.moves, unit_proxy.max_moves
    unit_proxy.moves = 98
    COMP.change_max_moves(unit_proxy, 98)

    local cm = wesnoth.find_cost_map(unit_proxy.x, unit_proxy.y, { ignore_units = true })

    COMP.change_max_moves(unit_proxy, old_max_moves)
    unit_proxy.moves = old_moves
    if old_loc then
        unit_proxy.loc = old_loc
        if unit_in_way_proxy then COMP.put_unit(unit_in_way_proxy) end
    end

    local movecost_0
    if is_inverse_map then
        movecost_0 = FDI.get_unit_movecost(unit_proxy, loc[1], loc[2], movecost_maps_cache)
    end
    -- Just a safeguard against potential future problems:
    if movecost_0 and (movecost_0 > 90) then
        error('Goal hex is unreachable :' .. unit_proxy.id .. ' --> ' .. loc[1] .. ',' .. loc[2])
    end

    local cost_map = {}
    for _,cost in pairs(cm) do
        local x, y, c = cost[1], cost[2], cost[3]
        if (c > -1) then
            if is_inverse_map then
                movecost = FDI.get_unit_movecost(unit_proxy, x, y, movecost_maps_cache)
                c = c + movecost_0 - movecost
            end
            FGM.set_value(cost_map, cost[1], cost[2], 'cost', c)
        end
    end

    if false then
        DBG.show_fgm_with_message(cost_map, 'cost', 'smooth_cost_map', unit_proxy.id)
    end

    return cost_map
end

function fred_map_utils.get_between_map(locs, units, fred_data)
    -- Calculate the "between-ness" of map hexes between @locs and @units
    --
    -- Note: this function ignores enemies and distance of the units
    -- from the hexes. Whether this makes sense to use all these units needs
    -- to be checked in the calling function

    local move_data = fred_data.move_data

    local unit_weights, cum_unit_weight = {}, 0
    for id,_ in pairs(units) do
        local unit_weight = move_data.unit_infos[id].current_power
        unit_weights[id] = unit_weight
        cum_unit_weight = cum_unit_weight + unit_weight
    end
    for id,unit_weight in pairs(unit_weights) do
        unit_weights[id] = unit_weight / cum_unit_weight
    end
    --DBG.dbms(unit_weights, false, 'unit_weights')
    --DBG.dbms(locs, false, 'locs')

    local between_map = {}
    for id,unit_loc in pairs(units) do
        --std_print(id, unit_loc[1], unit_loc[2])
        local unit = {}
        unit[id] = unit_loc
        local unit_proxy = COMP.get_unit(unit_loc[1], unit_loc[2])

        local cost_map = fred_map_utils.smooth_cost_map(unit_proxy, nil, false, fred_data.caches.movecost_maps)
        local max_moves = move_data.unit_copies[id].max_moves

        if false then
            DBG.show_fgm_with_message(cost_map, 'cost', 'cost_map', move_data.unit_copies[id])
        end

        local cum_loc_weight = 0
        local reachable_locs = {}
        for _,loc in pairs(locs) do
            local xy = loc[1] * 1000 + loc[2]

            -- Find the hexes which the unit can reach and still get next to the goal locs
            --std_print('checking within_one_move: ' .. loc[1] .. ',' .. loc[2], id)
            local cost_on_goal = FDI.get_unit_movecost(unit_proxy, loc[1], loc[2], fred_data.caches.movecost_maps)
            local goal = AH.table_copy(loc)
            --DBG.dbms(goal, false, 'goal before')

            -- If the hex is unreachable, we use a reachable adjacent hex instead, as we're checking for attacks
            -- TODO: eventually we might want to use all adjacent hexes, as it is possible that
            --   a unit might get to the goal from behind. In the other direction, this now checks for being
            --   adjacent to the adjacent hex, which adds some more hexes.
            if (cost_on_goal == 99) then
                --std_print('  goal hex ' .. loc[1] .. ',' .. loc[2] .. ' is unreachable for ' .. id)
                local min_cost = math.huge
                for xa,ya in H.adjacent_tiles(loc[1], loc[2]) do
                    local adj_cost_on_goal = FDI.get_unit_movecost(unit_proxy, xa, ya, fred_data.caches.movecost_maps)
                    local adj_cost_to_goal = FGM.get_value(cost_map, xa, ya, 'cost')
                    if (adj_cost_on_goal < 99) and (adj_cost_to_goal < min_cost) then
                        min_cost = adj_cost_to_goal
                        cost_on_goal = adj_cost_on_goal
                        goal = { xa, ya }
                    end
                end
            end
            --DBG.dbms(goal, false, 'goal after')

            -- This returns nil if goal is unreachable, so it works even if no reachable goal was found above
            local cost_to_goal = FGM.get_value(cost_map, goal[1], goal[2], 'cost')
            --std_print(id, max_moves, cost_to_goal, cost_on_goal)

            -- Only need to do this for units that can actually get to the goal
            if cost_to_goal and (cost_to_goal - cost_on_goal <= max_moves) then
                cum_loc_weight = cum_loc_weight + loc.exposure
                reachable_locs[xy] = {
                    loc = loc,
                    goal = goal,
                    cost_on_goal = cost_on_goal,
                    cost_to_goal = cost_to_goal
                }
            end
        end

        for xy,reachable_loc in pairs(reachable_locs) do
            reachable_loc.weight = reachable_loc.loc.exposure / cum_loc_weight

            if (reachable_loc.loc.exposure == 0) then
                -- This can happen, for example, when a village is going to be taken by
                -- the leader; or blocked by the units to be recruited
                reachable_locs[xy] = nil
            end
        end
        --DBG.dbms(reachable_locs, false, 'reachable_locs')

        for xy,reachable_loc in pairs(reachable_locs) do
            local goal = reachable_loc.goal
            local cost_on_goal = reachable_loc.cost_on_goal
            local cost_to_goal = reachable_loc.cost_to_goal
            local loc_weight = reachable_loc.weight

            -- TODO: is inverse cost map really what I want here, or forward cost from that location?
            local inv_cost_map = fred_map_utils.smooth_cost_map(unit_proxy, goal, true, fred_data.caches.movecost_maps)
            local cost_full = FGM.get_value(cost_map, goal[1], goal[2], 'cost')
            local inv_cost_full = FGM.get_value(inv_cost_map, unit_loc[1], unit_loc[2], 'cost')

            if false then
                DBG.show_fgm_with_message(inv_cost_map, 'cost', 'inv_cost_map to ' .. goal[1] .. ',' .. goal[2], move_data.unit_copies[id])
            end

            local unit_map = {}
            for x,y,data in FGM.iter(cost_map) do
                local cost = data.cost or 99
                local inv_cost = FGM.get_value(inv_cost_map, x, y, 'cost')

                -- This gives a rating that is a slanted plane, from the unit to goal
                local rating = (inv_cost - cost) / 2
                if (cost > cost_full) then
                    rating = rating + (cost_full - cost)
                end
                if (inv_cost > inv_cost_full) then
                    rating = rating + (inv_cost - inv_cost_full)
                end

                rating = rating

                FGM.set_value(unit_map, x, y, 'rating', rating)
                FGM.add(between_map, x, y, 'inv_cost', inv_cost * unit_weights[id] * loc_weight)
            end

            --std_print(id, ' cost_on_goal : ' .. cost_on_goal)
            for x,y,data in FGM.iter(cost_map) do
                local cost = data.cost or 99
                local inv_cost = FGM.get_value(inv_cost_map, x, y, 'cost')

                local total_cost = cost + inv_cost - cost_on_goal
                if (total_cost <= max_moves) and (cost <= cost_to_goal) and (inv_cost <= cost_to_goal) then
                    --FGM.set_value(unit_map, x, y, 'total_cost', total_cost)
                    unit_map[x][y].within_one_move = true
                end

                local perp_distance = cost + inv_cost + FDI.get_unit_movecost(unit_proxy, x, y, fred_data.caches.movecost_maps)
                FGM.set_value(unit_map, x, y, 'perp_distance', perp_distance)
            end

            local min_perp_distance = math.huge
            for x,y,data in FGM.iter(unit_map) do
                if (data.perp_distance < min_perp_distance) then
                    min_perp_distance = data.perp_distance
                end
            end
            for x,y,data in FGM.iter(unit_map) do
                data.perp_distance = data.perp_distance - min_perp_distance
            end

            -- Count within_one_move hexes as between; also include adjacent hexes to this
            for x,y,data in FGM.iter(unit_map) do
                if data.within_one_move then
                    FGM.set_value(between_map, x, y, 'is_between', true)
                    for xa,ya in H.adjacent_tiles(x,y) do
                        local cost = FGM.get_value(cost_map, xa, ya, 'cost')
                        local inv_cost = FGM.get_value(inv_cost_map, xa, ya, 'cost')
                        if cost and inv_cost and (cost <= cost_to_goal) and (inv_cost <= cost_to_goal) then
                            FGM.set_value(between_map, xa, ya, 'is_between', true)
                        end
                    end
                end
            end

            if false then
                DBG.show_fgm_with_message(unit_map, 'rating', 'unit_map intermediate rating to ' .. goal[1] .. ',' .. goal[2], move_data.unit_copies[id])
                DBG.show_fgm_with_message(unit_map, 'perp_distance', 'unit_map perp_distance to ' .. goal[1] .. ',' .. goal[2], move_data.unit_copies[id])
            end


            local loc_value = FGM.get_value(unit_map, goal[1], goal[2], 'rating')
            local unit_value = FGM.get_value(unit_map, unit_loc[1], unit_loc[2], 'rating')
            local max_value = (loc_value + unit_value) / 2
            --std_print(goal[1], goal[2], loc_value, unit_value, max_value)

            for x,y,data in FGM.iter(unit_map) do
                local rating = data.rating

                -- Set rating to maximum at midpoint between unit and goal
                -- Decrease values in excess of that by that excess
                if (rating > max_value) then
                    rating = rating - 2 * (rating - max_value)
                end

                -- Set rating to zero at goal (and therefore also at unit)
                rating = rating - loc_value

                -- Rating falls off in perpendicular direction
                rating = rating - math.abs((data.perp_distance / max_moves)^2)

                FGM.set_value(unit_map, x, y, 'rating', rating)
                FGM.add(between_map, x, y, 'distance', rating * unit_weights[id] * loc_weight)
                FGM.add(between_map, x, y, 'perp_distance', data.perp_distance * unit_weights[id] * loc_weight)
            end

            if false then
                DBG.show_fgm_with_message(unit_map, 'rating', 'unit_map full rating to ' .. goal[1] .. ',' .. goal[2], move_data.unit_copies[id])
                DBG.show_fgm_with_message(unit_map, 'perp_distance', 'unit_map perp_distance ' .. id, move_data.unit_copies[id])
                --DBG.show_fgm_with_message(unit_map, 'total_cost', 'unit_map total_cost ' .. id, move_data.unit_copies[id])
            end
        end

        if false then
            DBG.show_fgm_with_message(between_map, 'distance', 'between_map distance after adding ' .. id, move_data.unit_copies[id])
            DBG.show_fgm_with_message(between_map, 'perp_distance', 'between_map perp_distance after adding ' .. id, move_data.unit_copies[id])
            DBG.show_fgm_with_message(between_map, 'inv_cost', 'between_map inv_cost after adding ' .. id, move_data.unit_copies[id])
            DBG.show_fgm_with_message(between_map, 'is_between', 'between_map is_between after adding ' .. id, move_data.unit_copies[id])
        end
    end

    FGM.blur(between_map, 'distance')
    FGM.blur(between_map, 'perp_distance')

    return between_map
end

function fred_map_utils.get_leader_distance_map(leader_loc, side_cfgs)
    local enemy_leader_loc
    for side,cfg in ipairs(side_cfgs) do
        if (side == wesnoth.current.side) then
            leader_loc = leader_loc or cfg.start_hex
        else
            enemy_leader_loc = cfg.start_hex
        end
    end

    -- Need a map with the distances to the enemy and own leaders
    local leader_cx, leader_cy = AH.cartesian_coords(leader_loc[1], leader_loc[2])
    local enemy_leader_cx, enemy_leader_cy = AH.cartesian_coords(enemy_leader_loc[1], enemy_leader_loc[2])

    local leader_distance_map = {}
    local width, height = wesnoth.get_map_size()
    for x = 1,width do
        for y = 1,height do
            local cx, cy = AH.cartesian_coords(x, y)
            local leader_dist = math.sqrt( (leader_cx - cx)^2 + (leader_cy - cy)^2 )
            local enemy_leader_dist = math.sqrt( (enemy_leader_cx - cx)^2 + (enemy_leader_cy - cy)^2 )

            FGM.set_value(leader_distance_map, x, y, 'my_leader_distance', leader_dist)
            leader_distance_map[x][y].enemy_leader_distance = enemy_leader_dist
            -- TODO: do we really want this asymmetric?
            leader_distance_map[x][y].distance = (leader_dist - 0.5 * enemy_leader_dist) / 1.5
        end
    end

    return leader_distance_map
end

function fred_map_utils.get_unit_advance_distance_maps(unit_advance_distance_maps, zone_cfgs, side_cfgs, cfg, fred_data)
    -- This is expensive, so only do it per movement_type (not for each unit) and only add the
    -- maps that do not already exist.
    -- This function has no return value. @unit_advance_distance_maps is modified in place.
    --
    -- @cfg: optional map with config parameters:
    --   @my_leader_loc: own leader location to use as reference; if not given use the start hex

    cfg = cfg or {}
    local leader_radius = 4 -- This might have to be different for other maps. TODO: add to map config
    local move_data = fred_data.move_data

    local my_leader_loc, enemy_leader_loc
    for side,cfg in ipairs(side_cfgs) do
        if (side ~= wesnoth.current.side) then
            enemy_leader_loc = cfg.start_hex
        else
            my_leader_loc = cfg.start_hex
        end
    end
    if cfg.my_leader_loc then
        my_leader_loc = cfg.my_leader_loc
    end

    for zone_id,cfg in pairs(zone_cfgs) do
        if (not unit_advance_distance_maps[zone_id]) then
            unit_advance_distance_maps[zone_id] = {}
        end

        local new_types = {}
        for id,_ in pairs(move_data.my_units) do
            local typ = move_data.unit_infos[id].movement_type -- can't use type, that's reserved
            if (not unit_advance_distance_maps[zone_id][typ]) then
                -- Note that due to the use of smooth_cost_maps below, things like the fast trait don't matter here
                new_types[typ] = id
           end
        end
        --DBG.dbms(new_types, false, 'new_types ' .. zone_id)

        local old_terrain = {}
        if next(new_types) then
            local slf = AH.table_copy(cfg.ops_slf)
            table.insert(slf, { "or", { x = my_leader_loc[1], y = my_leader_loc[2], radius = leader_radius } } )
            local avoid_locs = wesnoth.get_locations { { "not", slf  } }
            for _,avoid_loc in ipairs(avoid_locs) do
                table.insert(old_terrain, {avoid_loc[1], avoid_loc[2], wesnoth.get_terrain(avoid_loc[1], avoid_loc[2])})
                wesnoth.set_terrain(avoid_loc[1], avoid_loc[2], "Xv")
            end
        end

        for typ,id in pairs(new_types) do
            unit_advance_distance_maps[zone_id][typ] = {}

            local unit_proxy = COMP.get_units({ id = id })[1]
            -- This is not quite symmetric, due to using normal and inverse cost maps, but it
            -- means both maps are toward the enemy leader loc and can be added or subtracted directly
            -- Cost map to move toward enemy leader loc:
            local eldm = fred_map_utils.smooth_cost_map(unit_proxy, enemy_leader_loc, true, fred_data.caches.movecost_maps)
            -- Cost map to move away from own leader loc:
            local ldm = fred_map_utils.smooth_cost_map(unit_proxy, my_leader_loc, false, fred_data.caches.movecost_maps)

            local total_distance_between_leaders = ldm[enemy_leader_loc[1]][enemy_leader_loc[2]].cost

            local min_perp = math.huge
            for x,y,data in FGM.iter(ldm) do
                local my_cost = data.cost
                local enemy_cost = eldm[x][y].cost

                -- This conditional leaves out some parts of the zone, which will be added later.
                -- Also, it is not quite accurate on hexes close to either leader and "off to the side",
                -- but it's good for what we need here.
                if (my_cost <= total_distance_between_leaders) and (enemy_cost <= total_distance_between_leaders)
                    or ((wesnoth.map.distance_between(x, y, my_leader_loc[1], my_leader_loc[2]) > leader_radius)
                       and (wesnoth.map.distance_between(x, y, enemy_leader_loc[1], enemy_leader_loc[2]) > leader_radius)
                    )
                then
                    local perp = my_cost + enemy_cost
                    -- We do not just want to use enemy_cost here, as we want more symmetric "equi-forward" lines
                    local forward = (my_cost - enemy_cost) / 2

                    if (perp < min_perp) then min_perp = perp end

                    FGM.set_value(unit_advance_distance_maps[zone_id][typ], x, y, 'forward', forward)
                    unit_advance_distance_maps[zone_id][typ][x][y].perp = perp
                    unit_advance_distance_maps[zone_id][typ][x][y].my_cost = my_cost
                    unit_advance_distance_maps[zone_id][typ][x][y].enemy_cost = enemy_cost
                end
            end
            for x,y,data in FGM.iter(unit_advance_distance_maps[zone_id][typ]) do
                data.perp = data.perp - min_perp
            end
        end

        if next(new_types) then
            for _,terrain in ipairs(old_terrain) do
                wesnoth.set_terrain(terrain[1], terrain[2], terrain[3])
            end
            -- The above procedure unsets village ownership
            for x,y,data in FGM.iter(move_data.village_map) do
                if (data.owner > 0) then
                    wesnoth.set_village_owner(x, y, data.owner)
                end
            end
        end
    end
end

function fred_map_utils.get_influence_maps(fred_data)
    local leader_derating = FCFG.get_cfg_parm('leader_derating')
    local influence_falloff_floor = FCFG.get_cfg_parm('influence_falloff_floor')
    local influence_falloff_exp = FCFG.get_cfg_parm('influence_falloff_exp')

    local move_data = fred_data.move_data

    local influence_maps, unit_influence_maps = {}, {}
    for int_turns = 1,2 do
        for x,y,data in FGM.iter(move_data.my_attack_map[int_turns]) do
            for _,id in pairs(data.ids) do
                local unit_influence = move_data.unit_infos[id].current_power
                if move_data.unit_infos[id].canrecruit then
                    unit_influence = unit_influence * leader_derating
                end

                local moves_left = FGM.get_value(move_data.unit_attack_maps[int_turns][id], x, y, 'moves_left_this_turn')
                local inf_falloff = 1 - (1 - influence_falloff_floor) * (1 - moves_left / move_data.unit_infos[id].max_moves) ^ influence_falloff_exp
                local my_influence = unit_influence * inf_falloff

                -- TODO: this is not 100% correct as a unit could have 0<moves<max_moves, but it's close enough for now.
                if (int_turns == 1) then
                    FGM.add(influence_maps, x, y, 'my_influence', my_influence)
                    FGM.add(influence_maps, x, y, 'my_number', 1)

                    FGM.add(influence_maps, x, y, 'my_full_move_influence', unit_influence)

                    if (not unit_influence_maps[id]) then
                        unit_influence_maps[id] = {}
                    end
                    FGM.add(unit_influence_maps[id], x, y, 'influence', my_influence)
                end
                if (int_turns == 2) and (move_data.unit_infos[id].moves == 0) then
                    FGM.add(influence_maps, x, y, 'my_full_move_influence', unit_influence)
                end

                FGM.add(influence_maps, x, y, 'my_two_turn_influence', unit_influence)
            end
        end
    end

    for x,y,data in FGM.iter(move_data.enemy_attack_map[1]) do
        for _,enemy_id in pairs(data.ids) do
            local unit_influence = move_data.unit_infos[enemy_id].current_power
            if move_data.unit_infos[enemy_id].canrecruit then
                unit_influence = unit_influence * leader_derating
            end

            local moves_left = FGM.get_value(move_data.reach_maps[enemy_id], x, y, 'moves_left') or -1
            if (moves_left < move_data.unit_infos[enemy_id].max_moves) then
                moves_left = moves_left + 1
            end
            local inf_falloff = 1 - (1 - influence_falloff_floor) * (1 - moves_left / move_data.unit_infos[enemy_id].max_moves) ^ influence_falloff_exp

            enemy_influence = unit_influence * inf_falloff
            FGM.add(influence_maps, x, y, 'enemy_influence', enemy_influence)
            FGM.add(influence_maps, x, y, 'enemy_number', 1)
            FGM.add(influence_maps, x, y, 'enemy_full_move_influence', unit_influence) -- same as 'enemy_influence' for now

            if (not unit_influence_maps[enemy_id]) then
                unit_influence_maps[enemy_id] = {}
            end
            FGM.add(unit_influence_maps[enemy_id], x, y, 'influence', enemy_influence)
            FGM.add(influence_maps, x, y, 'enemy_two_turn_influence', unit_influence)
        end
    end
    for x,y,data in FGM.iter(move_data.enemy_attack_map[2]) do
        for _,enemy_id in pairs(data.ids) do
            local unit_influence = move_data.unit_infos[enemy_id].current_power
            if move_data.unit_infos[enemy_id].canrecruit then
                unit_influence = unit_influence * leader_derating
            end
            FGM.add(influence_maps, x, y, 'enemy_two_turn_influence', unit_influence)
        end
    end

    for x,y,data in FGM.iter(influence_maps) do
        data.influence = (data.my_influence or 0) - (data.enemy_influence or 0)
        data.full_move_influence = (data.my_full_move_influence or 0) - (data.enemy_full_move_influence or 0)
        data.two_turn_influence = (data.my_two_turn_influence or 0) - (data.enemy_two_turn_influence or 0)
        data.tension = (data.my_influence or 0) + (data.enemy_influence or 0)
        data.vulnerability = data.tension - math.abs(data.influence)
    end

    if DBG.show_debug('ops_influence_maps') then
        DBG.show_fgm_with_message(influence_maps, 'my_influence', 'My influence map')
        DBG.show_fgm_with_message(influence_maps, 'my_full_move_influence', 'My full-move influence map')
        DBG.show_fgm_with_message(influence_maps, 'my_two_turn_influence', 'My two-turn influence map')
        --DBG.show_fgm_with_message(influence_maps, 'my_number', 'My number')
        DBG.show_fgm_with_message(influence_maps, 'enemy_influence', 'Enemy influence map')
        DBG.show_fgm_with_message(influence_maps, 'enemy_full_move_influence', 'Enemy full-move influence map')
        DBG.show_fgm_with_message(influence_maps, 'enemy_two_turn_influence', 'Enemy two-turn influence map')
        --DBG.show_fgm_with_message(influence_maps, 'enemy_number', 'Enemy number')
        DBG.show_fgm_with_message(influence_maps, 'influence', 'Influence map')
        DBG.show_fgm_with_message(influence_maps, 'full_move_influence', 'Full-move influence map')
        DBG.show_fgm_with_message(influence_maps, 'two_turn_influence', 'two_turn influence map')
        DBG.show_fgm_with_message(influence_maps, 'tension', 'Tension map')
        DBG.show_fgm_with_message(influence_maps, 'vulnerability', 'Vulnerability map')
    end

    if DBG.show_debug('ops_unit_influence_maps') then
        for id,unit_influence_map in pairs(unit_influence_maps) do
            DBG.show_fgm_with_message(unit_influence_map, 'influence', 'Unit influence map ' .. id, move_data.unit_copies[id])
        end
    end

    return influence_maps, unit_influence_maps
end


return fred_map_utils
