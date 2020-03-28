local H = wesnoth.require "helper"
local AH = wesnoth.require "ai/lua/ai_helper.lua"
local FDI = wesnoth.require "~/add-ons/AI-demos/lua/fred_data_incremental.lua"
local FGM = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_map.lua"
local FCFG = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_config.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"
local COMP = wesnoth.require "~/add-ons/AI-demos/lua/compatibility.lua"

local fred_map_utils = {}

function fred_map_utils.moved_toward_zone(unit_copy, raw_cfgs, side_cfgs)
    --std_print('moved_toward_zone: ' .. unit_copy.id, unit_copy.x, unit_copy.y)
    local start_hex = side_cfgs[unit_copy.side].start_hex

    -- Want "smooth" movement cost
    local old_moves = unit_copy.moves
    local old_max_moves = unit_copy.max_moves
    unit_copy.moves = 98
    COMP.change_max_moves(unit_copy, 98)

    local max_rating, to_zone_id = - math.huge
    for zone_id,raw_cfg in pairs(raw_cfgs) do
        -- Note: in a previous version, 'fronts' was used for reference, but that turned out to
        --  be too unstable, as front positions change during a turn
        local x, y = 0, 0
        for _,hex in ipairs(raw_cfg.center_hexes) do
            x, y = x + hex[1], y + hex[2]
        end
        x, y = x / #raw_cfg.center_hexes, y / #raw_cfg.center_hexes

        local _,cost_new = wesnoth.find_path(unit_copy, x, y, { ignore_units = true })

        local old_hex = { unit_copy.x, unit_copy.y }
        unit_copy.x, unit_copy.y = start_hex[1], start_hex[2]
        local _,cost_start = wesnoth.find_path(unit_copy, x, y, { ignore_units = true })
        unit_copy.x, unit_copy.y = old_hex[1], old_hex[2]

        local rating = cost_start - cost_new
        -- As a tie breaker, prefer zone that is originally farther away
        rating = rating + cost_start / 1000
        --std_print('  ' .. zone_id, x .. ',' .. y, cost_start .. ' - ' .. cost_new .. ' ~= ' .. rating)

        if (rating > max_rating) then
           to_zone_id, max_rating = zone_id, rating
        end
    end

    unit_copy.moves = old_moves
    COMP.change_max_moves(unit_copy, old_max_moves)

    return to_zone_id
end

function fred_map_utils.influence_custom_cost(x, y, unit_copy, influence_mult, influence_map, fred_data)
    -- Custom cost function for finding path with penalty for negative full-move influence.
    -- This is a "smooth" cost function, meaning it does not take potential loss of MP
    -- at the end of a move into account.
    local cost = FDI.get_unit_movecost(unit_copy, x, y, fred_data.caches.movecost_maps)
    if (cost >= 99) then return cost end

    if FGM.get_value(fred_data.move_data.enemy_map, x, y, 'id') then
        return 99
    end

    local infl = FGM.get_value(influence_map, x, y, 'full_move_influence') or -99
    if (infl < 0) then
        return cost - infl * influence_mult
    end
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
    -- @loc: needs to contain a field 'exposure' that is the weight of the location
    --
    -- Note: this function ignores enemies and distance of the units
    -- from the hexes. Whether it makes sense to use all these units needs
    -- to be checked in the calling function
    --
    -- Some of this is similar to unit_advance_distance_maps, but with important differences:
    --   - between_map peaks in the middle between units and goals
    --   - There is only one between_map, as a weighted average over units
    --   - It is blurred

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
    local map_cache = {}
    for id,unit_loc in pairs(units) do
        --std_print(id, unit_loc[1], unit_loc[2])
        local unit_proxy = COMP.get_unit(unit_loc[1], unit_loc[2])
        local max_moves = move_data.unit_copies[id].max_moves

        local cost_map = fred_map_utils.smooth_cost_map(unit_proxy, nil, false, fred_data.caches.movecost_maps)

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

            local cache_index = move_data.unit_infos[id].movement_type .. xy
            local inv_cost_map
            if map_cache[cache_index] then
                --std_print('reusing inv_cost_map: ' .. id, goal[1] .. ',' .. goal[2], cache_index)
                inv_cost_map = map_cache[cache_index]
            else
                --std_print('calculating new inv_cost_map: ' .. id, goal[1] .. ',' .. goal[2], cache_index)
                inv_cost_map = fred_map_utils.smooth_cost_map(unit_proxy, goal, true, fred_data.caches.movecost_maps)
                map_cache[cache_index] = inv_cost_map
            end
            local cost_full = FGM.get_value(cost_map, goal[1], goal[2], 'cost')
            local inv_cost_full = FGM.get_value(inv_cost_map, unit_loc[1], unit_loc[2], 'cost')

            if false then
                DBG.show_fgm_with_message(inv_cost_map, 'cost', 'inv_cost_map to ' .. goal[1] .. ',' .. goal[2], move_data.unit_copies[id])
            end

            local unit_map = {}
            local min_perp = math.huge
            for x,y,data in FGM.iter(cost_map) do
                local inv_cost = FGM.get_value(inv_cost_map, x, y, 'cost')

                -- This gives a rating that is a slanted plane, from the unit to goal
                local rating = (inv_cost - data.cost) / 2
                if (data.cost > cost_full) then
                    rating = rating + (cost_full - data.cost)
                end
                if (inv_cost > inv_cost_full) then
                    rating = rating + (inv_cost - inv_cost_full)
                end

                FGM.set_value(unit_map, x, y, 'rating', rating)
                FGM.add(between_map, x, y, 'inv_cost', inv_cost * unit_weights[id] * loc_weight)

                local total_cost = data.cost + inv_cost - cost_on_goal
                if (total_cost <= max_moves) and (data.cost <= cost_to_goal) and (inv_cost <= cost_to_goal) then
                    FGM.set_value(unit_map, x, y, 'total_cost', total_cost)
                    unit_map[x][y].within_one_move = true
                end

                local perp = data.cost + inv_cost + FDI.get_unit_movecost(unit_proxy, x, y, fred_data.caches.movecost_maps)
                unit_map[x][y].perp = perp

                if (perp < min_perp) then
                    min_perp = perp
                end
            end

            for x,y,data in FGM.iter(unit_map) do
                data.perp = data.perp - min_perp
            end

            -- Count within_one_move hexes as between; also add adjacent hexes to this
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
                DBG.show_fgm_with_message(unit_map, 'perp', 'unit_map perp to ' .. goal[1] .. ',' .. goal[2], move_data.unit_copies[id])
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
                rating = rating - math.abs((data.perp / max_moves)^2)

                FGM.set_value(unit_map, x, y, 'rating', rating)
                FGM.add(between_map, x, y, 'distance', rating * unit_weights[id] * loc_weight)
                FGM.add(between_map, x, y, 'perp', data.perp * unit_weights[id] * loc_weight)
            end

            if false then
                DBG.show_fgm_with_message(unit_map, 'rating', 'unit_map full rating to ' .. goal[1] .. ',' .. goal[2], move_data.unit_copies[id])
                DBG.show_fgm_with_message(unit_map, 'perp', 'unit_map perp ' .. id, move_data.unit_copies[id])
                DBG.show_fgm_with_message(unit_map, 'total_cost', 'unit_map total_cost ' .. id, move_data.unit_copies[id])
            end
        end

        if false then
            DBG.show_fgm_with_message(between_map, 'distance', 'between_map distance after adding ' .. id, move_data.unit_copies[id])
            DBG.show_fgm_with_message(between_map, 'perp', 'between_map perp after adding ' .. id, move_data.unit_copies[id])
            DBG.show_fgm_with_message(between_map, 'inv_cost', 'between_map inv_cost after adding ' .. id, move_data.unit_copies[id])
            DBG.show_fgm_with_message(between_map, 'is_between', 'between_map is_between after adding ' .. id, move_data.unit_copies[id])
        end
    end

    map_cache = nil

    FGM.blur(between_map, 'distance')
    FGM.blur(between_map, 'perp')

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

    -- This is horrendously complicated, but I don't think there's anything that can be done
    -- about this due to the zone structure of the map. The steps involved are:
    --   1.  Get cost_maps in the zones by blocking out hexes outside the zone
    --   2.  Combine the maps from the zones so that each zone maps covers the entire map,
    --       while taking the different total lengths of the paths through the zones into account.
    --   3a. Fill in missing hexes (behind leaders) for 'forward', 'my_cost', 'enemy_cost'
    --   3b. Do the same for 'perp', but this covers all hexes outside the zone and needs to be done differently.

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

    local overall_new_types = {} -- Rebuilding the full map needs to be done for all zones, even if units is new only in subset
    local total_distances_between_leaders = {}
    local tmp_zone_maps = {}
    for zone_id,cfg in pairs(zone_cfgs) do
        local new_types = {}
        for id,_ in pairs(move_data.my_units) do
            local typ = move_data.unit_infos[id].movement_type -- can't use type, that's reserved
            if (not unit_advance_distance_maps[zone_id]) or (not unit_advance_distance_maps[zone_id][typ]) then
                -- Note that due to the use of smooth_cost_maps below, things like the fast trait don't matter here
                new_types[typ] = id
                overall_new_types[typ] = id
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
            if (not tmp_zone_maps[zone_id]) then
                tmp_zone_maps[zone_id] = {}
            end
            tmp_zone_maps[zone_id][typ] = {}

            local unit_proxy = COMP.get_units({ id = id })[1]
            -- This is not quite symmetric, due to using normal and inverse cost maps, but it
            -- means both maps are toward the enemy leader loc and can be added or subtracted directly
            -- Cost map to move toward enemy leader loc:
            local eldm = fred_map_utils.smooth_cost_map(unit_proxy, enemy_leader_loc, true, fred_data.caches.movecost_maps)
            -- Cost map to move away from own leader loc:
            local ldm = fred_map_utils.smooth_cost_map(unit_proxy, my_leader_loc, false, fred_data.caches.movecost_maps)

            local total_distance_between_leaders = ldm[enemy_leader_loc[1]][enemy_leader_loc[2]].cost
            total_distances_between_leaders[zone_id] = total_distance_between_leaders

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

                    FGM.set_value(tmp_zone_maps[zone_id][typ], x, y, 'forward', forward)
                    tmp_zone_maps[zone_id][typ][x][y].perp = perp
                    tmp_zone_maps[zone_id][typ][x][y].my_cost = my_cost
                    tmp_zone_maps[zone_id][typ][x][y].enemy_cost = enemy_cost
                end
            end
            for x,y,data in FGM.iter(tmp_zone_maps[zone_id][typ]) do
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
    --DBG.dbms(overall_new_types, false, 'overall_new_types')

    -- Stitching the maps together for 'forward', 'my_cost', 'enemy_cost'.
    -- This causes some discontinuities at the borders between zones, but is good enough (and the best we can do)
    local combined_maps = {}
    for typ,id in pairs(overall_new_types) do
        combined_maps[typ] = {}
        for zone_id,cfg in pairs(zone_cfgs) do
            local tdbl = total_distances_between_leaders[zone_id]
            for x,y,data in FGM.iter(tmp_zone_maps[zone_id][typ]) do
                local new_forward = data.forward / tdbl
                local old_forward = FGM.get_value(combined_maps[typ], x, y, 'forward')
                if (not old_forward) or (math.abs(new_forward) < math.abs(old_forward)) then
                    FGM.set_value(combined_maps[typ], x, y, 'forward', new_forward)
                end

                local new_my_cost = data.my_cost / tdbl
                local old_my_cost = FGM.get_value(combined_maps[typ], x, y, 'my_cost')
                if (not old_my_cost) or (new_my_cost < old_my_cost) then
                    FGM.set_value(combined_maps[typ], x, y, 'my_cost', new_my_cost)
                end

                local new_enemy_cost = data.enemy_cost / tdbl
                local old_enemy_cost = FGM.get_value(combined_maps[typ], x, y, 'enemy_cost')
                if (not old_enemy_cost) or (new_enemy_cost < old_enemy_cost) then
                    FGM.set_value(combined_maps[typ], x, y, 'enemy_cost', new_enemy_cost)
                end
            end
        end

        --DBG.show_fgm_with_message(combined_maps[typ], 'forward', 'combined_map: ' .. typ)
    end

    for zone_id,cfg in pairs(zone_cfgs) do
        if (not unit_advance_distance_maps[zone_id]) then
            unit_advance_distance_maps[zone_id] = {}
        end

        local tdbl = total_distances_between_leaders[zone_id]
        for typ,id in pairs(overall_new_types) do
            unit_advance_distance_maps[zone_id][typ] = {}
            for x,y,data in FGM.iter(combined_maps[typ]) do
                FGM.set_value(unit_advance_distance_maps[zone_id][typ], x, y, 'forward', data.forward * tdbl)
                unit_advance_distance_maps[zone_id][typ][x][y].my_cost = data.my_cost * tdbl
                unit_advance_distance_maps[zone_id][typ][x][y].enemy_cost = data.enemy_cost * tdbl
            end

            --DBG.show_fgm_with_message(unit_advance_distance_maps[zone_id][typ], 'forward', 'unit_advance_distance_maps forward: ' .. zone_id .. ' ' .. typ)
            --DBG.show_fgm_with_message(unit_advance_distance_maps[zone_id][typ], 'my_cost', 'unit_advance_distance_maps my_cost: ' .. zone_id .. ' ' .. typ)
            --DBG.show_fgm_with_message(unit_advance_distance_maps[zone_id][typ], 'enemy_cost', 'unit_advance_distance_maps enemy_cost: ' .. zone_id .. ' ' .. typ)
        end
    end

    -- Filling in the missing parts for 'forward', 'my_cost', 'enemy_cost'.
    -- On Freelands, these are just the two little sections behind each leader.
    for zone_id,cfg in pairs(zone_cfgs) do
        for typ,id in pairs(overall_new_types) do
            local unit_copy = move_data.unit_copies[id]
            local new_hexes_map = {}
            for x,y,data in FGM.iter(unit_advance_distance_maps[zone_id][typ]) do
                for xa,ya in H.adjacent_tiles(x, y) do
                    if (not FGM.get_value(unit_advance_distance_maps[zone_id][typ], xa, ya, 'forward'))
                        and (FDI.get_unit_movecost(unit_copy, xa, ya, fred_data.caches.movecost_maps) < 99)
                    then
                        FGM.set_value(new_hexes_map, xa, ya, 'new', true)
                    end
                end
            end
            --DBG.dbms(new_hexes_map)

            while next(new_hexes_map) do
                for x,y in FGM.iter(new_hexes_map) do
                    local min_new_forward, min_new_my_cost, min_new_enemy_cost = math.huge, math.huge, math.huge
                    for xa,ya in H.adjacent_tiles(x, y) do
                        local forward = FGM.get_value(unit_advance_distance_maps[zone_id][typ], xa, ya, 'forward')
                        if forward then
                            local movecost = FDI.get_unit_movecost(unit_copy, xa, ya, fred_data.caches.movecost_maps)
                            local new_forward
                            if (forward > 0) then
                                new_forward = forward + movecost
                            else
                                new_forward = forward - movecost
                            end
                            if (math.abs(new_forward) < math.abs(min_new_forward)) then
                                min_new_forward = new_forward
                            end

                            local new_my_cost = unit_advance_distance_maps[zone_id][typ][xa][ya].my_cost + movecost
                            if (new_my_cost < min_new_my_cost) then
                                min_new_my_cost = new_my_cost
                            end

                            local new_enemy_cost = unit_advance_distance_maps[zone_id][typ][xa][ya].enemy_cost + movecost
                            if (new_enemy_cost < min_new_enemy_cost) then
                                min_new_enemy_cost = new_enemy_cost
                            end
                        end
                    end
                    FGM.set_value(unit_advance_distance_maps[zone_id][typ], x, y, 'forward', min_new_forward)
                    FGM.set_value(unit_advance_distance_maps[zone_id][typ], x, y, 'my_cost', min_new_my_cost)
                    FGM.set_value(unit_advance_distance_maps[zone_id][typ], x, y, 'enemy_cost', min_new_enemy_cost)
                end

                local old_hexes_map = AH.table_copy(new_hexes_map)
                new_hexes_map = {}
                for x,y,data in FGM.iter(old_hexes_map) do
                    for xa,ya in H.adjacent_tiles(x, y) do
                        if (not FGM.get_value(unit_advance_distance_maps[zone_id][typ], xa, ya, 'forward'))
                            and (FDI.get_unit_movecost(unit_copy, xa, ya, fred_data.caches.movecost_maps) < 99)
                        then
                            FGM.set_value(new_hexes_map, xa, ya, 'new', true)
                        end
                    end
                end
                --DBG.dbms(new_hexes_map)
            end

            --DBG.show_fgm_with_message(unit_advance_distance_maps[zone_id][typ], 'forward', 'unit_advance_distance_maps forward: ' .. zone_id .. ' ' .. typ)
            --DBG.show_fgm_with_message(unit_advance_distance_maps[zone_id][typ], 'my_cost', 'unit_advance_distance_maps my_cost: ' .. zone_id .. ' ' .. typ)
            --DBG.show_fgm_with_message(unit_advance_distance_maps[zone_id][typ], 'enemy_cost', 'unit_advance_distance_maps enemy_cost: ' .. zone_id .. ' ' .. typ)
        end
    end

    -- Extending 'perp' to the full map needs to be done differently. We cannot use the values
    -- from other zones, as it is supposed to increase continuously as we move away from the own zone.
    -- Also, as a much larger part of the map needs to be covered, we need to make sure that
    -- values coming together via different paths do not cause large discontinuities.
    --  --> only build up the lowest new 'perp' values during each iteration.
    for zone_id,cfg in pairs(zone_cfgs) do
        for typ,id in pairs(overall_new_types) do
            local unit_copy = move_data.unit_copies[id]

            local new_hexes_map = {}
            for x,y,data in FGM.iter(tmp_zone_maps[zone_id][typ]) do
                for xa,ya in H.adjacent_tiles(x, y) do
                    if (not FGM.get_value(tmp_zone_maps[zone_id][typ], xa, ya, 'perp'))
                        and (FDI.get_unit_movecost(unit_copy, xa, ya, fred_data.caches.movecost_maps) < 99)
                    then
                        FGM.set_value(new_hexes_map, xa, ya, 'perp', true)
                    end
                end
            end

            while next(new_hexes_map) do
                local iteration_min_perp = math.huge
                local old_hexes_map = AH.table_copy(new_hexes_map)
                local perp_hexes_map = {}
                -- Need to iterate over the full map, since not all new hexes are added each iteration
                -- Iterate over tmp_zone_maps because unit_advance_distance_maps already has values
                -- for the entire map (even if not for 'perp', but it still cuts down on eval time).
                for x,y,data in FGM.iter(old_hexes_map) do
                    for xa,ya in H.adjacent_tiles(x, y) do
                        local perp = FGM.get_value(tmp_zone_maps[zone_id][typ], xa, ya, 'perp')
                        if perp then
                            local movecost = FDI.get_unit_movecost(unit_copy, xa, ya, fred_data.caches.movecost_maps)
                            -- Use twice the movecost here because:
                            --  1. That's similar to what happens in the zone as well (because of the sum of move costs)
                            --  2. We want to discourage moving to hexes outside the zone
                            local new_perp = perp + 2 * movecost
                            if (new_perp < (FGM.get_value(perp_hexes_map, x, y, 'perp') or math.huge)) then
                                FGM.set_value(perp_hexes_map, x, y, 'perp', new_perp)
                                if (new_perp < iteration_min_perp) then
                                    iteration_min_perp = new_perp
                                end
                            end
                        end
                    end
                end

                -- Only add those that have the minimum new 'perp' value.
                -- The rest gets added to new_hexes_map again.
                new_hexes_map = {}
                local added_hexes_map = {}
                for x,y,data in FGM.iter(perp_hexes_map) do
                    if (data.perp == iteration_min_perp) then
                        FGM.set_value(tmp_zone_maps[zone_id][typ], x, y, 'perp', data.perp)
                        FGM.set_value(added_hexes_map, x, y, 'perp', true)
                    else
                        FGM.set_value(new_hexes_map, x, y, 'perp', true)
                    end
                end

                -- Finally add those adjacent to hexes in added_hexes_map.
                -- This needs to be done after the loop above is finished.
                for x,y,data in FGM.iter(added_hexes_map) do
                    for xa,ya in H.adjacent_tiles(x, y) do
                        if (not FGM.get_value(tmp_zone_maps[zone_id][typ], xa, ya, 'perp'))
                            and (FDI.get_unit_movecost(unit_copy, xa, ya, fred_data.caches.movecost_maps) < 99)
                        then
                            FGM.set_value(new_hexes_map, xa, ya, 'perp', true)
                        end
                    end
                end

                --DBG.show_fgm_with_message(tmp_zone_maps[zone_id][typ], 'perp', 'tmp_zone_maps perp: ' .. zone_id .. ' ' .. typ)
            end
        end
    end

    for zone_id,cfg in pairs(zone_cfgs) do
        for typ,id in pairs(overall_new_types) do
            for x,y,data in FGM.iter(tmp_zone_maps[zone_id][typ]) do
                unit_advance_distance_maps[zone_id][typ][x][y].perp = data.perp
            end
            --DBG.show_fgm_with_message(unit_advance_distance_maps[zone_id][typ], 'perp', 'unit_advance_distance_maps perp: ' .. zone_id .. ' ' .. typ)
        end
    end

    combined_maps = nil
    tmp_zone_maps = nil
end

function fred_map_utils.get_influence_maps(fred_data)
    -- Note: two_turn_influence is currently not used anywhere, but it might be useful
    --   at some point, so I'm commenting out the code, but keeping it for now.
    local leader_derating = FCFG.get_cfg_parm('leader_derating')
    local influence_falloff_floor = FCFG.get_cfg_parm('influence_falloff_floor')
    local influence_falloff_exp = FCFG.get_cfg_parm('influence_falloff_exp')
    local move_data = fred_data.move_data

    -- The evals for own and enemy units are almost identical. The only difference
    -- is that enemy units attack maps are calculated using full MP, while current
    -- MP are used for own units. The loops are separated nevertheless, as they can
    -- be done only over part of the map and save some evaluation time.

    local influence_map, unit_influence_maps = {}, {}
    for int_turns = 1,2 do
        for x,y,data in FGM.iter(move_data.my_attack_map[int_turns]) do
            for _,id in pairs(data.ids) do
                local unit_influence = move_data.unit_infos[id].current_power
                if move_data.unit_infos[id].canrecruit then
                    unit_influence = unit_influence * leader_derating
                end

                local moves_left = FGM.get_value(move_data.attack_maps[int_turns][id], x, y, 'moves_left_this_turn')
                local inf_falloff = 1 - (1 - influence_falloff_floor) * (1 - moves_left / move_data.unit_infos[id].max_moves) ^ influence_falloff_exp
                local my_influence = unit_influence * inf_falloff

                -- TODO: this is not 100% correct as a unit could have 0<moves<max_moves, but it's close enough for now.
                if (int_turns == 1) then
                    FGM.add(influence_map, x, y, 'my_influence', my_influence)
                    FGM.add(influence_map, x, y, 'my_number', 1)
                    FGM.add(influence_map, x, y, 'my_full_move_influence', unit_influence)

                    if (not unit_influence_maps[id]) then unit_influence_maps[id] = {} end
                    FGM.add(unit_influence_maps[id], x, y, 'influence', my_influence)
                end

                if (int_turns == 2) and (move_data.unit_infos[id].moves == 0) then
                    FGM.add(influence_map, x, y, 'my_full_move_influence', unit_influence)
                end

                --FGM.add(influence_map, x, y, 'my_two_turn_influence', unit_influence)
            end
        end
    end

    -- Note: unlike for the own units, the outer loop only covers int_turns = 1.
    -- For enemy units, int_turns = 2 is only need for enemy_two_turn_influence
    -- which is currently commented out.
    for int_turns = 1,1 do
        for x,y,data in FGM.iter(move_data.enemy_attack_map[int_turns]) do
            for _,enemy_id in pairs(data.ids) do
                local unit_influence = move_data.unit_infos[enemy_id].current_power
                if move_data.unit_infos[enemy_id].canrecruit then
                    unit_influence = unit_influence * leader_derating
                end

                local moves_left = FGM.get_value(move_data.attack_maps[int_turns][enemy_id], x, y, 'moves_left_this_turn')
                local inf_falloff = 1 - (1 - influence_falloff_floor) * (1 - moves_left / move_data.unit_infos[enemy_id].max_moves) ^ influence_falloff_exp
                local enemy_influence = unit_influence * inf_falloff

                -- This is exact for enemies, as they are always considered to have full moves
                if (int_turns == 1) then
                    FGM.add(influence_map, x, y, 'enemy_influence', enemy_influence)
                    FGM.add(influence_map, x, y, 'enemy_number', 1)
                    FGM.add(influence_map, x, y, 'enemy_full_move_influence', unit_influence)

                    if (not unit_influence_maps[enemy_id]) then unit_influence_maps[enemy_id] = {} end
                    FGM.add(unit_influence_maps[enemy_id], x, y, 'influence', enemy_influence)
                end

                --FGM.add(influence_map, x, y, 'enemy_two_turn_influence', unit_influence)
            end
        end
    end

    for x,y,data in FGM.iter(influence_map) do
        data.influence = (data.my_influence or 0) - (data.enemy_influence or 0)
        data.full_move_influence = (data.my_full_move_influence or 0) - (data.enemy_full_move_influence or 0)
        --data.two_turn_influence = (data.my_two_turn_influence or 0) - (data.enemy_two_turn_influence or 0)
        data.tension = (data.my_influence or 0) + (data.enemy_influence or 0)
        data.vulnerability = data.tension - math.abs(data.influence)
    end

    if DBG.show_debug('ops_influence_maps') then
        DBG.show_fgm_with_message(influence_map, 'my_influence', 'My influence map')
        DBG.show_fgm_with_message(influence_map, 'my_full_move_influence', 'My full-move influence map')
        --DBG.show_fgm_with_message(influence_map, 'my_two_turn_influence', 'My two-turn influence map')
        DBG.show_fgm_with_message(influence_map, 'my_number', 'My number')
        DBG.show_fgm_with_message(influence_map, 'enemy_influence', 'Enemy influence map')
        DBG.show_fgm_with_message(influence_map, 'enemy_full_move_influence', 'Enemy full-move influence map')
        --DBG.show_fgm_with_message(influence_map, 'enemy_two_turn_influence', 'Enemy two-turn influence map')
        DBG.show_fgm_with_message(influence_map, 'enemy_number', 'Enemy number')
        DBG.show_fgm_with_message(influence_map, 'influence', 'Influence map')
        DBG.show_fgm_with_message(influence_map, 'full_move_influence', 'Full-move influence map')
        --DBG.show_fgm_with_message(influence_map, 'two_turn_influence', 'two_turn influence map')
        DBG.show_fgm_with_message(influence_map, 'tension', 'Tension map')
        DBG.show_fgm_with_message(influence_map, 'vulnerability', 'Vulnerability map')
    end

    if DBG.show_debug('ops_unit_influence_maps') then
        for id,unit_influence_map in pairs(unit_influence_maps) do
            DBG.show_fgm_with_message(unit_influence_map, 'influence', 'Unit influence map ' .. id, move_data.unit_copies[id])
        end
    end

    return influence_map, unit_influence_maps
end

return fred_map_utils
