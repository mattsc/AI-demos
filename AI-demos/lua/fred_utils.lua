local H = wesnoth.require "helper"
local AH = wesnoth.require "ai/lua/ai_helper.lua"
local FGM = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_map.lua"
local FGUI = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_utils_incremental.lua"
local FCFG = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_config.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"
local COMP = wesnoth.require "~/add-ons/AI-demos/lua/compatibility.lua"

local fred_utils = {}

function fred_utils.weight_s(x, exp)
    -- S curve weighting of a variable that is meant as a fraction of a total.
    -- Thus, @x for the most part varies from 0 to 1, but does continues smoothly
    -- outside those ranges
    --
    -- Properties independent of @exp:
    --   f(0) = 0
    --   f(0.5) = 0.5
    --   f(1) = 1

    -- Examples for different exponents:
    -- exp:   0.000  0.100  0.200  0.300  0.400  0.500  0.600  0.700  0.800  0.900  1.000
    -- 0.50:  0.000  0.053  0.113  0.184  0.276  0.500  0.724  0.816  0.887  0.947  1.000
    -- 0.67:  0.000  0.069  0.145  0.229  0.330  0.500  0.670  0.771  0.855  0.931  1.000
    -- 1.00:  0.000  0.100  0.200  0.300  0.400  0.500  0.600  0.700  0.800  0.900  1.000
    -- 1.50:  0.000  0.142  0.268  0.374  0.455  0.500  0.545  0.626  0.732  0.858  1.000
    -- 2.00:  0.000  0.180  0.320  0.420  0.480  0.500  0.520  0.580  0.680  0.820  1.000

    local weight
    if (x >= 0.5) then
        weight = 0.5 + ((x - 0.5) * 2)^exp / 2
    else
        weight = 0.5 - ((0.5 - x) * 2)^exp / 2
    end

    return weight
end

function fred_utils.print_weight_s(exp)
    local s1, s2 = '', ''
    for i=-5,15 do
        local x = 0.1 * i
        y = fred_utils.weight_s(x, exp)
        s1 = s1 .. string.format("%5.3f", x) .. '  '
        s2 = s2 .. string.format("%5.3f", y) .. '  '
    end
    std_print(s1)
    std_print(s2)
end

function fred_utils.linear_regression(data)
    -- @data key-value pairs: key is x, value is y
    local x_m, y_m, count = 0, 0, 0
    for x,y in pairs(data) do
        x_m, y_m = x_m + x, y_m + y
        count = count + 1
    end
    x_m, y_m = x_m / count, y_m / count

    local num, denom = 0, 0
    for x,y in pairs(data) do
        num = num + (x - x_m) * (y - y_m)
        denom = denom + (x - x_m)^2
    end

    local slope = num / denom
    local y0 = y_m - slope * x_m

    return slope, y0
end

function fred_utils.get_unit_time_of_day_bonus(alignment, is_fearless, lawful_bonus)
    local multiplier = 1
    if (lawful_bonus ~= 0) then
        if (alignment == 'lawful') then
            multiplier = (1 + lawful_bonus / 100.)
        elseif (alignment == 'chaotic') then
            multiplier = (1 - lawful_bonus / 100.)
        elseif (alignment == 'liminal') then
            multipler = (1 - math.abs(lawful_bonus) / 100.)
        end
    end

    if is_fearless and (multiplier < 1) then
        multiplier = 1
    end

    return multiplier
end

function fred_utils.unit_value(unit_info)
    -- Get a gold-equivalent value for the unit
    -- Also returns (as a factor) the increase of value compared to cost,
    -- with a contribution for the level of the unit

    local xp_weight = FCFG.get_cfg_parm('xp_weight')

    local unit_value = unit_info.cost

    -- If this is the side leader, make damage to it much more important
    if unit_info.canrecruit and (unit_info.side == wesnoth.current.side) then
        local leader_weight = FCFG.get_cfg_parm('leader_weight')
        unit_value = unit_value * leader_weight
    end

    -- Being closer to leveling makes the unit more valuable, proportional to
    -- the difference between the unit and the leveled unit
    local cost_factor = 1.5
    if unit_info.advances_to then
        local advanced_cost = wesnoth.unit_types[unit_info.advances_to].cost
        cost_factor = advanced_cost / unit_info.cost
    end

    local xp_diff = unit_info.max_experience - unit_info.experience

    -- Square so that a few XP don't matter, but being close to leveling is important
    -- Units very close to leveling are considered even more valuable than leveled unit
    local xp_bonus
    if (xp_diff <= 1) then
        xp_bonus = 1.33
    elseif (xp_diff <= 8) then
        xp_bonus = 1.2
    else
        xp_bonus = (unit_info.experience / (unit_info.max_experience - 6))^2
    end

    unit_value = unit_value * (1. + xp_bonus * (cost_factor - 1) * xp_weight)

    --std_print('fred_utils.unit_value:', unit_info.id, unit_value, xp_bonus, xp_diff)

    -- TODO: probably want to make the unit level contribution configurable
    local value_factor = unit_value / unit_info.cost * math.sqrt(unit_info.level)

    return unit_value, value_factor
end

function fred_utils.approx_value_loss(unit_info, av_damage, max_damage)
    -- This is similar to FAU.damage_rating_unit (but simplified)
    -- TODO: maybe base the two on the same core function at some point

    -- Returns loss of value (as a negative number)

    -- In principle, damage is a fraction of max_hitpoints. However, it should be
    -- more important for units already injured. Making it a fraction of hitpoints
    -- would overemphasize units close to dying, as that is also factored in. Thus,
    -- we use an effective HP value that's a weighted average of the two.
    -- TODO: splitting it 50/50 seems okay for now, but might have to be fine-tuned.
    local injured_fraction = 0.5
    local hp = unit_info.hitpoints
    local hp_eff = injured_fraction * hp + (1 - injured_fraction) * unit_info.max_hitpoints

    -- Cap the damage at the hitpoints of the unit; larger damage is taken into
    -- account in the chance to die
    local real_damage = av_damage
    if (av_damage > hp) then
        real_damage = hp
    end
    local fractional_damage = real_damage / hp_eff
    local fractional_rating = - fred_utils.weight_s(fractional_damage, 0.67)
    --std_print('  fractional_damage, fractional_rating:', fractional_damage, fractional_rating)

    -- Additionally, add the chance to die, in order to emphasize units that might die
    -- This might result in fractional_damage > 1 in some cases
    -- Very approximate estimate of the CTD
    local approx_ctd = 0
    if (av_damage > hp) then
        approx_ctd = 0.5 + 0.5 * (1 - hp / av_damage)
    elseif (max_damage > hp) then
        approx_ctd = 0.5 * (max_damage - hp) / (max_damage - av_damage)
    end
    local ctd_rating = - 1.5 * approx_ctd^1.5
    fractional_rating = fractional_rating + ctd_rating
    --std_print('  ctd, ctd_rating, fractional_rating:', approx_ctd, ctd_rating, fractional_rating)

    -- Convert all the fractional ratings before to one in "gold units"
    -- We cap this at 1.5 times the unit value
    -- TODO: what's the best value here?
    if (fractional_rating < -1.5) then
        fractional_rating = -1.5
    end
    local unit_value = fred_utils.unit_value(unit_info)
    local value_loss = fractional_rating * unit_value
    --std_print('  unit_value, value_loss:', fred_utils.unit_value(unit_info), value_loss)

    return value_loss, approx_ctd, unit_value
end

function fred_utils.unit_base_power(unit_info)
    local hp_mod = fred_utils.weight_s(unit_info.hitpoints / unit_info.max_hitpoints, 0.67)

    local power = unit_info.max_damage
    power = power * hp_mod

    return power
end

function fred_utils.unit_current_power(unit_info)
    local power = fred_utils.unit_base_power(unit_info)
    power = power * unit_info.tod_mod

    return power
end

function fred_utils.unit_terrain_power(unit_info, x, y, move_data)
    local power = fred_utils.unit_current_power(unit_info)

    local defense = FGUI.get_unit_defense(move_data.unit_copies[unit_info.id], x, y, move_data.defense_maps)
    power = power * defense

    return power
end

function fred_utils.unittype_base_power(unit_type)
    local unittype_info = fred_utils.single_unit_info(wesnoth.unit_types[unit_type])
    -- Need to set hitpoints manually
    unittype_info.hitpoints = unittype_info.max_hitpoints

    return fred_utils.unit_base_power(unittype_info)
end


function fred_utils.urgency(power_fraction_there, n_units_there)
    -- How urgently do we need more units for a certain task
    -- This is used to compare against, for example, retreat utilities
    --
    -- Making this a function to:
    --   1. standardize it
    --   2. because it will likely become more complex

    -- For no units already there, this depends quadratically on power_fraction_there
    -- For large number of units already there, it is linear with power_fraction_there
    local urgency = 1 - power_fraction_there ^ (1 + 1 / (1 + n_units_there))

    if (urgency < 0) then urgency = 0 end

    return urgency
end


function fred_utils.moved_toward_zone(unit_copy, fronts, raw_cfgs, side_cfgs)
    --std_print(unit_copy.id, unit_copy.x, unit_copy.y)
    local start_hex = side_cfgs[unit_copy.side].start_hex

    -- Want "smooth" movement cost
    local old_moves = unit_copy.moves
    local old_max_moves = unit_copy.max_moves
    unit_copy.moves = 98

    local to_zone_id, score
    for zone_id,raw_cfg in pairs(raw_cfgs) do
        local front = fronts.zones[zone_id]
        local x,y = 0, 0
        -- If front hex does not exist or is not passable for a unit, use center hex instead
        -- TODO: not clear whether using a passable hex close to the front is better in this case
        -- TODO: check whether this is too expensive
        -- Disable using fronts for now, it's too volatile, but leave the code in place
        -- TODO: reenable or remove later
        if false and front and (COMP.unit_movement_cost(unit_copy, wesnoth.get_terrain(front.x, front.y)) < 99) then
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

    return to_zone_id
end


function fred_utils.influence_custom_cost(x, y, unit_copy, influence_mult, influence_map, move_data)
    -- Custom cost function for finding path with penalty for negative full-move influence.
    -- This does not take potential loss of MP at the end of a move into account.
    local cost = COMP.unit_movement_cost(unit_copy, wesnoth.get_terrain(x, y))
    if (cost >= 99) then return cost end

    if FGM.get_value(move_data.enemy_map, x, y, 'id') then
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


function fred_utils.smooth_cost_map(unit_proxy, loc, is_inverse_map)
    -- Smooth means that it does not add discontinuities for not having enough
    -- MP left to enter certain terrain at the end of a turn. This is done by setting
    -- moves and max_moves to 98 (99 being the move cost for impassable terrain).
    -- Thus, there could still be some such effect for very long paths, but this is
    -- good enough for all practical purposes.
    --
    -- Returns an FGU_map with the cost (key: 'cost')
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
        movecost_0 = COMP.unit_movement_cost(unit_proxy, wesnoth.get_terrain(loc[1], loc[2]))
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
                movecost = COMP.unit_movement_cost(unit_proxy, wesnoth.get_terrain(x, y))
                c = c + movecost_0 - movecost
            end

            FGM.set_value(cost_map, cost[1], cost[2], 'cost', c)
        end
    end

    if false then
        DBG.show_fgumap_with_message(cost_map, 'cost', 'cost_map', unit_proxy.id)
    end

    return cost_map
end

function fred_utils.get_between_map(locs, units, move_data)
    -- Calculate the "between-ness" of map hexes between @locs and @units
    --
    -- Note: this function ignores enemies and distance of the units
    -- from the hexes. Whether this makes sense to use all these units needs
    -- to be checked in the calling function

    local unit_weights, cum_unit_weight = {}, 0
    for id,_ in pairs(units) do
        local unit_weight = fred_utils.unit_current_power(move_data.unit_infos[id])
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


        local cost_map = fred_utils.smooth_cost_map(unit_proxy)
        local max_moves = move_data.unit_copies[id].max_moves

        if false then
            DBG.show_fgumap_with_message(cost_map, 'cost', 'cost_map', move_data.unit_copies[id])
        end

        local cum_loc_weight = 0
        local reachable_locs = {}
        for _,loc in pairs(locs) do
            local xy = loc[1] * 1000 + loc[2]

            -- Find the hexes which the unit can reach and still get next to the goal locs
            --std_print('checking within_one_move: ' .. loc[1] .. ',' .. loc[2], id)
            local cost_on_goal = COMP.unit_movement_cost(unit_proxy, wesnoth.get_terrain(loc[1], loc[2]))
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
                    local adj_cost_on_goal = COMP.unit_movement_cost(unit_proxy, wesnoth.get_terrain(xa, ya))
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
            local inv_cost_map = fred_utils.smooth_cost_map(unit_proxy, goal, true)
            local cost_full = FGM.get_value(cost_map, goal[1], goal[2], 'cost')
            local inv_cost_full = FGM.get_value(inv_cost_map, unit_loc[1], unit_loc[2], 'cost')

            if false then
                DBG.show_fgumap_with_message(inv_cost_map, 'cost', 'inv_cost_map to ' .. goal[1] .. ',' .. goal[2], move_data.unit_copies[id])
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

                local perp_distance = cost + inv_cost + COMP.unit_movement_cost(unit_proxy, wesnoth.get_terrain(x, y))
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
                DBG.show_fgumap_with_message(unit_map, 'rating', 'unit_map intermediate rating to ' .. goal[1] .. ',' .. goal[2], move_data.unit_copies[id])
                DBG.show_fgumap_with_message(unit_map, 'perp_distance', 'unit_map perp_distance to ' .. goal[1] .. ',' .. goal[2], move_data.unit_copies[id])
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
                DBG.show_fgumap_with_message(unit_map, 'rating', 'unit_map full rating to ' .. goal[1] .. ',' .. goal[2], move_data.unit_copies[id])
                DBG.show_fgumap_with_message(unit_map, 'perp_distance', 'unit_map perp_distance ' .. id, move_data.unit_copies[id])
                --DBG.show_fgumap_with_message(unit_map, 'total_cost', 'unit_map total_cost ' .. id, move_data.unit_copies[id])
            end
        end

        if false then
            DBG.show_fgumap_with_message(between_map, 'distance', 'between_map distance after adding ' .. id, move_data.unit_copies[id])
            DBG.show_fgumap_with_message(between_map, 'perp_distance', 'between_map perp_distance after adding ' .. id, move_data.unit_copies[id])
            DBG.show_fgumap_with_message(between_map, 'inv_cost', 'between_map inv_cost after adding ' .. id, move_data.unit_copies[id])
            DBG.show_fgumap_with_message(between_map, 'is_between', 'between_map is_between after adding ' .. id, move_data.unit_copies[id])
        end
    end

    FGM.blur(between_map, 'distance')
    FGM.blur(between_map, 'perp_distance')

    return between_map
end

function fred_utils.get_leader_distance_map(leader_loc, side_cfgs)
    local enemy_leader_loc
    for side,cfg in ipairs(side_cfgs) do
        if (side == wesnoth.current.side) then
            leader_loc = leader_loc or cfg.start_hex
        else
            enemy_leader_loc = cfg.start_hex
        end
    end

    -- Need a map with the distances to the enemy and own leaders
    -- TODO: Leave like this for now, potentially switch to using smooth_cost_map() later
    local leader_cx, leader_cy = AH.cartesian_coords(leader_loc[1], leader_loc[2])
    local enemy_leader_cx, enemy_leader_cy = AH.cartesian_coords(enemy_leader_loc[1], enemy_leader_loc[2])

    local leader_distance_map = {}
    local width, height = wesnoth.get_map_size()
    for x = 1,width do
        for y = 1,height do
            local cx, cy = AH.cartesian_coords(x, y)

            local leader_dist = math.sqrt( (leader_cx - cx)^2 + (leader_cy - cy)^2 )
            local enemy_leader_dist = math.sqrt( (enemy_leader_cx - cx)^2 + (enemy_leader_cy - cy)^2 )

            if (not leader_distance_map[x]) then leader_distance_map[x] = {} end
            FGM.set_value(leader_distance_map, x, y, 'my_leader_distance', leader_dist)
            leader_distance_map[x][y].enemy_leader_distance = enemy_leader_dist
            leader_distance_map[x][y].distance = (leader_dist - 0.5 * enemy_leader_dist) / 1.5
        end
    end

    return leader_distance_map
end

function fred_utils.get_unit_advance_distance_maps(unit_advance_distance_maps, zone_cfgs, side_cfgs, cfg, move_data)
    -- This is expensive, so only do it per unit type (not for each unit) and only add the
    -- maps that do not already exist.
    -- This function has no return value. @unit_advance_distance_maps is modified in place.
    -- TODO: Doing this by unit type may cause problems once Fred can play factions
    -- with unit types that have different variations (i.e. Walking Corpses). Fix later.
    --
    -- @cfg: optional map with config parameters:
    --   @my_leader_loc: own leader location to use as reference; if not given use the start hex

    cfg = cfg or {}

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
            local typ = move_data.unit_infos[id].type -- can't use type, that's reserved
            if (not unit_advance_distance_maps[zone_id][typ]) then
                -- Note that due to the use of smooth_cost_maps below, things like the fast trait don't matter here
                new_types[typ] = id
           end
        end
        --DBG.dbms(new_types, false, 'new_types')

        local old_terrain = {}
        if next(new_types) then
            local slf = AH.table_copy(cfg.ops_slf)
            table.insert(slf, { "or", { x = my_leader_loc[1], y = my_leader_loc[2], radius = 3 } } )
            local zone_locs = wesnoth.get_locations(slf)

            local avoid_locs = wesnoth.get_locations { { "not", slf  } }
            for _,avoid_loc in ipairs(avoid_locs) do
                table.insert(old_terrain, {avoid_loc[1], avoid_loc[2], wesnoth.get_terrain(avoid_loc[1], avoid_loc[2])})
                wesnoth.set_terrain(avoid_loc[1], avoid_loc[2], "Xv")
            end
        end

        for typ,id in pairs(new_types) do
            unit_advance_distance_maps[zone_id][typ] = {}

            local unit_proxy = COMP.get_units({ id = id })[1]
            local eldm = fred_utils.smooth_cost_map(unit_proxy, enemy_leader_loc, true)
            local ldm = fred_utils.smooth_cost_map(unit_proxy, my_leader_loc, true)

            local min_sum = math.huge
            for x,y,data in FGM.iter(ldm) do
                local my_cost = data.cost
                local enemy_cost = eldm[x][y].cost
                local sum = my_cost + enemy_cost + COMP.unit_movement_cost(unit_proxy, wesnoth.get_terrain(x, y))
                local diff = (my_cost - enemy_cost) / 2

                if (sum < min_sum) then
                    min_sum = sum
                end

                FGM.set_value(unit_advance_distance_maps[zone_id][typ], x, y, 'forward', diff)
                unit_advance_distance_maps[zone_id][typ][x][y].perp = sum
                unit_advance_distance_maps[zone_id][typ][x][y].my_cost = my_cost
                unit_advance_distance_maps[zone_id][typ][x][y].enemy_cost = enemy_cost
            end
            for x,y,data in FGM.iter(unit_advance_distance_maps[zone_id][typ]) do
                data.perp = data.perp - min_sum
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

function fred_utils.get_influence_maps(move_data)
    local leader_derating = FCFG.get_cfg_parm('leader_derating')
    local influence_falloff_floor = FCFG.get_cfg_parm('influence_falloff_floor')
    local influence_falloff_exp = FCFG.get_cfg_parm('influence_falloff_exp')

    local influence_maps, unit_influence_maps = {}, {}
    for int_turns = 1,2 do
        for x,y,data in FGM.iter(move_data.my_attack_map[int_turns]) do
            for _,id in pairs(data.ids) do
                local unit_influence = fred_utils.unit_current_power(move_data.unit_infos[id])
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
            local unit_influence = fred_utils.unit_current_power(move_data.unit_infos[enemy_id])
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
            local unit_influence = fred_utils.unit_current_power(move_data.unit_infos[enemy_id])
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
        DBG.show_fgumap_with_message(influence_maps, 'my_influence', 'My influence map')
        DBG.show_fgumap_with_message(influence_maps, 'my_full_move_influence', 'My full-move influence map')
        DBG.show_fgumap_with_message(influence_maps, 'my_two_turn_influence', 'My two-turn influence map')
        --DBG.show_fgumap_with_message(influence_maps, 'my_number', 'My number')
        DBG.show_fgumap_with_message(influence_maps, 'enemy_influence', 'Enemy influence map')
        DBG.show_fgumap_with_message(influence_maps, 'enemy_full_move_influence', 'Enemy full-move influence map')
        DBG.show_fgumap_with_message(influence_maps, 'enemy_two_turn_influence', 'Enemy two-turn influence map')
        --DBG.show_fgumap_with_message(influence_maps, 'enemy_number', 'Enemy number')
        DBG.show_fgumap_with_message(influence_maps, 'influence', 'Influence map')
        DBG.show_fgumap_with_message(influence_maps, 'full_move_influence', 'Full-move influence map')
        DBG.show_fgumap_with_message(influence_maps, 'two_turn_influence', 'two_turn influence map')
        DBG.show_fgumap_with_message(influence_maps, 'tension', 'Tension map')
        DBG.show_fgumap_with_message(influence_maps, 'vulnerability', 'Vulnerability map')
    end

    if DBG.show_debug('ops_unit_influence_maps') then
        for id,unit_influence_map in pairs(unit_influence_maps) do
            DBG.show_fgumap_with_message(unit_influence_map, 'influence', 'Unit influence map ' .. id, move_data.unit_copies[id])
        end
    end

    return influence_maps, unit_influence_maps
end

function fred_utils.support_maps(move_data)
    local width, height = wesnoth.get_map_size()
    local support_maps = { total = {}, units = {} }
    for id,unit_loc in pairs(move_data.my_units) do
        local current_power = fred_utils.unit_current_power(move_data.unit_infos[id])
        if move_data.unit_infos[id].canrecruit then
            current_power = current_power * FCFG.get_cfg_parm('leader_derating')
        end

        local cm = wesnoth.find_cost_map(unit_loc[1], unit_loc[2], {}, { ignore_units = false })
        local cost_map = {}
        for _,cost in pairs(cm) do
            local x, y, c = cost[1], cost[2], cost[3]
            if (c > -1) then
                FGM.set_value(cost_map, cost[1], cost[2], 'cost', c)
            end
        end

        support_maps.units[id] = {}
        for x = 1,width do
            for y = 1,height do
                local min_cost = FGM.get_value(cost_map, x, y, 'cost') or 99
                for xa,ya in H.adjacent_tiles(x, y) do
                    local adj_cost = FGM.get_value(cost_map, xa, ya, 'cost') or 99
                    if (adj_cost < min_cost) then
                        min_cost = adj_cost
                    end
                end

                local turns = min_cost / move_data.unit_infos[id].max_moves
                local int_turns, frac_turns = math.ceil(turns), turns % 1
                if (int_turns == 0) then
                    int_turns = 1
                else
                    if (frac_turns == 0) then
                        frac_turns = 1
                    end
                end

                local support = (1 - 0.5 * frac_turns^2) / (4 ^ (int_turns - 1)) * current_power

                if (min_cost < 99) and (int_turns <= 2) then
                    FGM.set_value(support_maps.units[id], x, y, 'support', support)
                    FGM.add(support_maps.total, x, y, 'support', support)
                end
            end
        end

    end

    return support_maps
end

function fred_utils.behind_enemy_map(fred_data)
    local function is_new_behind_hex(x, y, enemy_id, unit_behind_map, ld_ref)
        local move_cost = COMP.unit_movement_cost(fred_data.move_data.unit_copies[enemy_id], wesnoth.get_terrain(x, y))
        if (move_cost >= 99) then
            return false, false, false
        end

        if FGM.get_value(unit_behind_map, x, y, 'enemy_power') then
            return false, false, true
        end

        local ld = FGM.get_value(fred_data.ops_data.leader_distance_map, x, y, 'my_leader_distance')
        if (ld < ld_ref) then
            return false, true, true
        end

        if (not FGM.get_value(fred_data.move_data.unit_attack_maps[1][enemy_id], x, y, 'current_power'))
            and (not FGM.get_value(fred_data.move_data.unit_attack_maps[2][enemy_id], x, y, 'current_power'))
        then
            return false, true, true
        end

        return true, true, true
    end

    local behind_enemy_map = {}
    for enemy_id,enemy_loc in pairs(fred_data.move_data.enemies) do
        local current_power = fred_utils.unit_current_power(fred_data.move_data.unit_infos[enemy_id])

        local unit_behind_map = {}
        FGM.set_value(unit_behind_map, enemy_loc[1], enemy_loc[2], 'enemy_power', current_power)
        local new_hexes = { enemy_loc }

        local keep_trying = true
        while keep_trying do
            keep_trying = false

            local hexes = AH.table_copy(new_hexes)
            new_hexes = {}
            for _,loc in ipairs(hexes) do
                local ld_ref = FGM.get_value(fred_data.ops_data.leader_distance_map, loc[1], loc[2], 'my_leader_distance')
                for xa,ya in H.adjacent_tiles(loc[1], loc[2]) do
                    local is_valid, is_new, is_passable = is_new_behind_hex(xa, ya, enemy_id, unit_behind_map, ld_ref)
                    if is_passable then
                        if is_valid then
                            FGM.set_value(unit_behind_map, xa, ya, 'enemy_power', current_power)
                            table.insert(new_hexes, { xa, ya })
                            keep_trying = true
                        elseif is_new then
                            -- This gives 2 rows of zeros around the edges, but not for
                            -- impassable terrain; needed for blurring
                            FGM.set_value(unit_behind_map, xa, ya, 'enemy_power', 0)
                        end

                        -- Because of the hex geometry, we also need to do a second row
                        for xa2,ya2 in H.adjacent_tiles(xa, ya) do
                            local is_valid2, is_new2, is_passable2 = is_new_behind_hex(xa2, ya2, enemy_id, unit_behind_map, ld_ref)
                            if is_passable2 then
                                if is_valid2 then
                                    FGM.set_value(unit_behind_map, xa2, ya2, 'enemy_power', current_power)
                                    table.insert(new_hexes, { xa2, ya2 })
                                    keep_trying = true
                                elseif is_new2 then
                                    -- This gives 2 rows of zeros around the edges, but not for
                                    -- impassable terrain; needed for blurring
                                    FGM.set_value(unit_behind_map, xa2, ya2, 'enemy_power', 0)
                                end
                            end
                        end
                    end
                end
            end
        end

        FGM.blur(unit_behind_map, 'enemy_power')
        FGM.blur(unit_behind_map, 'blurred_enemy_power')

        if false then
            DBG.show_fgumap_with_message(unit_behind_map, 'blurred_blurred_enemy_power', 'behind map', fred_data.move_data.unit_copies[enemy_id])
        end

        for x,y,data in FGM.iter(unit_behind_map) do
            FGM.add(behind_enemy_map, x, y, 'enemy_power', data.blurred_blurred_enemy_power)
        end

    end

    return behind_enemy_map
end

function fred_utils.single_unit_info(unit_proxy)
    -- Collects unit information from proxy unit table @unit_proxy into a Lua table
    -- so that it is accessible faster.
    -- Note: Even accessing the directly readable fields of a unit proxy table
    -- is slower than reading from a Lua table; not even talking about unit_proxy.__cfg.
    --
    -- This can also be used on a unit type entry from wesnoth.unit_types, but in that
    -- case not all fields will be populated, of course, and anything depending on
    -- traits and the like will not necessarily be correct for the individual unit
    --
    -- Important: this is slow, so it should only be called once at the beginning
    -- of each move, but it does need to be redone after each move, as it contains
    -- information like HP and XP (or the unit might have leveled up or been changed
    -- in an event).
    --
    -- Note: unit location information is NOT included

    -- This is by far the most expensive step in this function, but it cannot be skipped yet
    local unit_cfg = unit_proxy.__cfg

    local single_unit_info = {
        id = unit_proxy.id,
        canrecruit = unit_proxy.canrecruit,
        side = unit_proxy.side,

        moves = unit_proxy.moves,
        max_moves = unit_proxy.max_moves,
        hitpoints = unit_proxy.hitpoints,
        max_hitpoints = unit_proxy.max_hitpoints,
        experience = unit_proxy.experience,
        max_experience = unit_proxy.max_experience,

        type = unit_proxy.type,
        alignment = unit_proxy.alignment,
        cost = unit_proxy.cost,
        level = unit_proxy.level
    }

    -- Pick the first of the advances_to types, nil when there is none
    single_unit_info.advances_to = unit_proxy.advances_to[1]

    -- Include the ability type, such as: hides, heals, regenerate, skirmisher (set up as 'hides = true')
    -- Note that unit_proxy.abilities gives the id of the ability. This is different from
    -- the value below, which is the name of the tag (e.g. 'heals' vs. 'healing' and/or 'curing')
    single_unit_info.abilities = {}
    local abilities = wml.get_child(unit_cfg, "abilities")
    if abilities then
        for _,ability in ipairs(abilities) do
            single_unit_info.abilities[ability[1]] = true
        end
    end

    -- Information about the attacks indexed by weapon number,
    -- including specials (e.g. 'poison = true')
    single_unit_info.attacks = {}
    local max_damage = 0
    for i,attack in ipairs(unit_proxy.attacks) do
        -- Extract information for specials; we do this first because some
        -- custom special might have the same name as one of the default scalar fields
        local a = {}
        for _,sp in ipairs(attack.specials) do
            if (sp[1] == 'damage') then  -- this is 'backstab'
                if (sp[2].id == 'backstab') then
                    a.backstab = true
                else
                    if (sp[2].id == 'charge') then a.charge = true end
                end
            else
                -- magical, marksman
                if (sp[1] == 'chance_to_hit') then
                    a[sp[2].id] = true
                else
                    a[sp[1]] = true
                end
            end
        end
        a.damage = attack.damage
        a.number = attack.number
        a.range = attack.range
        a.type = attack.type

        table.insert(single_unit_info.attacks, a)

        -- TODO: potentially use FAU.get_total_damage_attack for this later, but for
        -- the time being these are too different, and have too different a purpose.
        total_damage = a.damage * a.number

        -- Just use blanket damage for poison and slow for now; might be refined later
        if a.poison then total_damage = total_damage + 8 end
        if a.slow then total_damage = total_damage + 4 end

        -- Also give some bonus for drain and backstab, but not to the full extent
        -- of what they can achieve
        if a.drains then total_damage = total_damage * 1.25 end
        if a.backstab then total_damage = total_damage * 1.33 end

        if (total_damage > max_damage) then
            max_damage = total_damage
        end
    end
    single_unit_info.max_damage = max_damage

    -- Time of day modifier: done here once so that it works on unit types also.
    -- It is repeated below if a unit is passed, to take the fearless trait into account.
    single_unit_info.tod_mod = fred_utils.get_unit_time_of_day_bonus(single_unit_info.alignment, false, wesnoth.get_time_of_day().lawful_bonus)


    -- The following can only be done on a real unit, not on a unit type
    if (unit_proxy.x) then
        single_unit_info.status = {}
        local status = wml.get_child(unit_cfg, "status")
        for k,_ in pairs(status) do
            single_unit_info.status[k] = true
        end

        single_unit_info.traits = {}
        local mods = wml.get_child(unit_cfg, "modifications")
        for trait in wml.child_range(mods, 'trait') do
            single_unit_info.traits[trait.id] = true
        end

        -- Now we do this again, using the correct value for the fearless trait
        single_unit_info.tod_mod = fred_utils.get_unit_time_of_day_bonus(single_unit_info.alignment, single_unit_info.traits.fearless, wesnoth.get_time_of_day().lawful_bonus)

        -- Define what "good terrain" means for a unit
        local defense = wml.get_child(unit_cfg, "defense")
        -- Get the hit chances for all terrains and sort (best = lowest hit chance first)
        local hit_chances = {}
        for _,hit_chance in pairs(defense) do
            table.insert(hit_chances, { hit_chance = math.abs(hit_chance) })
        end
        table.sort(hit_chances, function(a, b) return a.hit_chance < b.hit_chance end)

        -- As "normal" we use the hit chance on "flat equivalent" terrain.
        -- That means on flat for most units, on cave for dwarves etc.
        -- and on shallow water for mermen, nagas etc.
        -- Use the best of those
        local flat_hc = math.min(defense.flat, defense.cave, defense.shallow_water)
        --std_print('best hit chance on flat, cave, shallow water:', flat_hc)
        --std_print(defense.flat, defense.cave, defense.shallow_water)

        -- Good terrain is now defined as 10% lesser hit chance than that, except
        -- when this is better than the third best terrain for the unit. An example
        -- are ghosts, which have 50% on all terrains.
        -- I have tested this for most mainline level 1 units and it seems to work pretty well.
        local good_terrain_hit_chance = flat_hc - 10
        if (good_terrain_hit_chance < hit_chances[3].hit_chance) then
            good_terrain_hit_chance = flat_hc
        end
        --std_print('good_terrain_hit_chance', good_terrain_hit_chance)

        single_unit_info.good_terrain_hit_chance = good_terrain_hit_chance / 100.
    end

    return single_unit_info
end

function fred_utils.get_unit_hex_combos(dst_src, get_best_combo, add_rating)
    -- Recursively find all combinations of distributing
    -- units on hexes. The number of units and hexes does not have to be the same.
    -- @dst_src lists all units which can reach each hex in format:
    --  [1] = {
    --      [1] = { src = 17028 },
    --      [2] = { src = 16027 },
    --      [3] = { src = 15027 },
    --      dst = 18025
    --  },
    --  [2] = {
    --      [1] = { src = 17028 },
    --      [2] = { src = 16027 },
    --      dst = 20026
    --  },
    --
    -- OPTIONAL INPUTS:
    --  @get_best_combo: find the highest rated combo; in this case, @dst_src needs to
    --    contain a rating key:
    --  [2] = {
    --      [1] = { src = 17028, rating = 0.91 },
    --      [2] = { src = 16027, rating = 0.87 },
    --      dst = 20026
    --  }
    --    The combo rating is then the sum of all the individual ratings entering a combo.
    --  @add_rating: add the sum of the individual ratings to each combo, using rating= field.
    --    Note that this means that this field needs to be separated out from the actual dst-src
    --    info when reading the table. Input needs to be of same format as for @get_best_combo.

    local all_combos, combo = {}, {}
    local num_hexes = #dst_src
    local hex = 0

    -- If get_best_combo is set, we cap this at 1,000 combos, assuming
    -- that we will have found something close to the strongest by then,
    -- esp. given that the method is only approximate anyway.
    -- Also, if get_best_combo is set, we only take combos that have
    -- the maximum number of attackers. Otherwise the comparison is not fair
    local max_count = 1 -- Note: must be 1, not 0
    local count = 0
    local max_rating, best_combo = - math.huge
    local rating = 0

    -- This is the recursive function adding units to each hex
    -- It is defined here so that we can use the variables above by closure
    local function add_combos()
        hex = hex + 1

        for _,ds in ipairs(dst_src[hex]) do
            if (not combo[ds.src]) then  -- If that unit has not been used yet, add it
                count = count + 1

                combo[ds.src] = dst_src[hex].dst

                if get_best_combo or add_rating then
                    if (count > 1000) then
                        combo[ds.src] = nil
                        break
                    end
                    rating = rating + ds.rating  -- Rating is simply the sum of the individual ratings
                end

                if (hex < num_hexes) then
                    add_combos()
                else
                    if get_best_combo then
                        -- Only keep combos with the maximum number of units
                        local tmp_count = 0
                        for _,_ in pairs(combo) do tmp_count = tmp_count + 1 end
                        -- If this is more than current max_count, reset the max_rating (forcing this combo to be taken)
                        if (tmp_count > max_count) then max_rating = - math.huge end

                        -- If this is less than current max_count, don't use this combo
                        if (rating > max_rating) and (tmp_count >= max_count) then
                            max_rating = rating
                            max_count = tmp_count
                            best_combo = {}
                            for k,v in pairs(combo) do best_combo[k] = v end
                        end
                    else
                        local new_combo = {}
                        for k,v in pairs(combo) do new_combo[k] = v end
                        if add_rating then new_combo.rating = rating end
                        table.insert(all_combos, new_combo)
                    end
                end

                -- Remove this element from the table again
                if get_best_combo or add_rating then
                    rating = rating - ds.rating
                end

                combo[ds.src] = nil
            end
        end

        -- We need to call this once more, to account for the "no unit on this hex" case
        -- Yes, this is a code duplication (done so for simplicity and speed reasons)
        if (hex < num_hexes) then
            add_combos()
        else
            if get_best_combo then
                -- Only keep attacks with the maximum number of units
                -- This also automatically excludes the empty combo
                local tmp_count = 0
                for _,_ in pairs(combo) do tmp_count = tmp_count + 1 end
                -- If this is more than current max_count, reset the max_rating (forcing this combo to be taken)
                if (tmp_count > max_count) then max_rating = - math.huge end

                -- If this is less than current max_count, don't use this attack
                if (rating > max_rating) and (tmp_count >= max_count)then
                    max_rating = rating
                    max_count = tmp_count
                    best_combo = {}
                    for k,v in pairs(combo) do best_combo[k] = v end
                end
            else
                local new_combo = {}
                for k,v in pairs(combo) do new_combo[k] = v end
                if add_rating then new_combo.rating = rating end
                table.insert(all_combos, new_combo)
            end
        end

        hex = hex - 1
    end

    add_combos()


    if get_best_combo then
        return best_combo
    end

    -- The last combo is always the empty combo -> remove it
    all_combos[#all_combos] = nil

    return all_combos
end

return fred_utils
