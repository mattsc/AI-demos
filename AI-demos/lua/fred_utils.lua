local H = wesnoth.require "helper"
local AH = wesnoth.require "ai/lua/ai_helper.lua"
local FGUI = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_utils_incremental.lua"
local FCFG = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_config.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local fred_utils = {}

function fred_utils.get_fgumap_value(map, x, y, key)
    return (map[x] and map[x][y] and map[x][y][key])
end

function fred_utils.set_fgumap_value(map, x, y, key, value)
    if (not map[x]) then map[x] = {} end
    if (not map[x][y]) then map[x][y] = {} end
    map[x][y][key] = value
end

function fred_utils.fgumap_add(map, x, y, key, value)
    local old_value = fred_utils.get_fgumap_value(map, x, y, key) or 0
    fred_utils.set_fgumap_value(map, x, y, key, old_value + value)
end

function fred_utils.fgumap_iter(map)
    function each_hex(state)
        while state.x ~= nil do
            local child = map[state.x]
            state.y = next(child, state.y)
            if state.y == nil then
                state.x = next(map, state.x)
            else
                return state.x, state.y, child[state.y]
            end
        end
    end

    return each_hex, { x = next(map) }
end

function fred_utils.fgumap_normalize(map, key)
    local mx
    for _,_,data in fred_utils.fgumap_iter(map) do
        if (not mx) or (data[key] > mx) then
            mx = data[key]
        end
    end
    for _,_,data in fred_utils.fgumap_iter(map) do
        data[key] = data[key] / mx
    end
end

function fred_utils.fgumap_blur(map, key)
    for x,y,data in fred_utils.fgumap_iter(map) do
        local blurred_data = data[key]
        if blurred_data then
            local count = 1
            local adj_weight = 0.5
            for xa,ya in H.adjacent_tiles(x, y) do
                local value = fred_utils.get_fgumap_value(map, xa, ya, key)
                if value then
                    blurred_data = blurred_data + value * adj_weight
                   count = count + adj_weight
                end
            end
            fred_utils.set_fgumap_value(map, x, y, 'blurred_' .. key, blurred_data / count)
        end
    end
end

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

    return unit_value
end

function fred_utils.is_significant_threat(unit_info, av_total_loss, max_total_loss)
    -- Currently this is only set up for the leader.
    -- TODO: generalize?
    --
    -- We only consider these leader threats, if they either
    --   - maximum damage reduces current HP by more than 75%
    --   - average damage is more than 50% of max HP
    -- Otherwise we assume the leader can deal with them alone

    local significant_threat = false
    if (max_total_loss >= unit_info.hitpoints * 0.75)
        or (av_total_loss >= unit_info.max_hitpoints * 0.5)
    then
        significant_threat = true
    end

    return significant_threat
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

function fred_utils.action_penalty(actions, reserved_actions, interactions, move_data)
    -- Find the penalty for a set of @actions due to @reserved_actions.
    -- @actions is an array of action tables, with fields .id and .loc,
    -- both of which are optional. If only one or the other is given, the
    -- unit/hex counts as available (no penalty) if there is no reserved action
    -- associated with it. If both are given, they also count as available if
    -- this is the hex for which the unit is reserved.
    --
    -- Return values:
    --  - penalty: sum of all penalties for the actions
    --  - penalty_str: string describing the applied penalties

    local penalty, penalty_str = 0, ''

    for _,reserved_action in pairs(reserved_actions) do
        local unit_penalty_mult = interactions.units[reserved_action.action_id] or 0
        local hex_penalty_mult = interactions.hexes[reserved_action.action_id] or 0

        -- Recruiting is different from other reserved actions, as it only
        -- matters whether enough keeps/castles are available
        if (reserved_action.action_id == 'rec') then
            --std_print('recruiting penalty:')
            if (hex_penalty_mult > 0) then
                local available_castles = reserved_action.available_castles
                local available_keeps = reserved_action.available_keeps
                for _,action in ipairs(actions) do
                    local x, y = action.loc and action.loc[1], action.loc and action.loc[2]

                    -- If this is the side leader and it's on a keep, it does not
                    -- count toward keep or castle count
                    if (action.id ~= move_data.leaders[wesnoth.current.side].id)
                        or (not fred_utils.get_fgumap_value(move_data.reachable_castles_map[wesnoth.current.side], x, y, 'keep'))
                    then
                        if x and (fred_utils.get_fgumap_value(move_data.reachable_castles_map[wesnoth.current.side], x, y, 'castle')) then
                            --std_print('    castle: ', x, y)
                            available_castles = available_castles - 1
                        end
                        if x and (fred_utils.get_fgumap_value(move_data.reachable_castles_map[wesnoth.current.side], x, y, 'keep')) then
                            --std_print('    keep: ', x, y)
                            available_keeps = available_keeps - 1
                        end
                    end
                end
                --std_print('  avail cas, keep: ', available_castles, available_keeps)

                local recruit_penalty = 0
                local castles_needed = #reserved_action.benefit
                -- If no keeps are available, then the penalty is the entire recruiting benefit
                if (available_keeps < 1) then
                    recruit_penalty = - reserved_action.benefit[castles_needed]
                -- Otherwise, if there are not enough castles, it's the missed-out-on benefit
                elseif (available_castles < castles_needed) then
                    --std_print('not enough castles')
                    recruit_penalty = reserved_action.benefit[available_castles] - reserved_action.benefit[castles_needed]
                end

                --std_print('--> recruit_penalty: ' .. recruit_penalty)
                if (recruit_penalty ~= 0) then
                    penalty = penalty + recruit_penalty
                    penalty_str = penalty_str .. string.format("recruit: %6.3f    ", recruit_penalty)
                end
            end

        else
            for _,action in ipairs(actions) do
                --std_print(action.id, action.loc and action.loc[1], action.loc and action.loc[2], reserved_action.action_id, unit_penalty_mult, hex_penalty_mult)

                local same_hex = false
                if action.loc and (hex_penalty_mult > 0)
                    and (action.loc[1] == reserved_action.x) and (action.loc[2] == reserved_action.y)
                 then
                    same_hex = true
                end
                local same_unit = false
                if action.id and (unit_penalty_mult > 0) and (action.id == reserved_action.id) then
                    same_unit = true
                end
                --std_print(same_hex,same_unit)

                if same_hex and same_unit then
                    -- In this case, the unit+hex counts as available even if there
                    -- are other actions using the same hex or unit
                    -- TODO: are there exceptions from this?
                elseif same_hex or same_unit then
                    local penalty_mult = math.max(unit_penalty_mult, hex_penalty_mult)
                    penalty = penalty - penalty_mult * reserved_action.benefit
                    --std_print('  penalty_mult, penalty: ' .. penalty_mult, penalty)

                    if reserved_action.id then
                        penalty_str = penalty_str .. reserved_action.id
                    end
                    if reserved_action.x then
                        penalty_str = penalty_str .. '(' .. reserved_action.x .. ',' .. reserved_action.y .. ')'
                    end
                    penalty_str = penalty_str .. string.format(": %6.3f    ", - penalty_mult * reserved_action.benefit)
                end
            end
        end
    end
    --std_print('--> total penalty: ' .. penalty)

    return penalty, penalty_str
end

function fred_utils.moved_toward_zone(unit_copy, zone_cfgs, side_cfgs)
    --std_print(unit_copy.id, unit_copy.x, unit_copy.y)

    local start_hex = side_cfgs[unit_copy.side].start_hex

    local to_zone_id, score
    for zone_id,cfg in pairs(zone_cfgs) do
        for _,center_hex in ipairs(cfg.center_hexes) do
            local _,cost_new = wesnoth.find_path(unit_copy, center_hex[1], center_hex[2], { ignore_units = true })

            local old_hex = { unit_copy.x, unit_copy.y }
            unit_copy.x, unit_copy.y = start_hex[1], start_hex[2]

            local _,cost_start = wesnoth.find_path(unit_copy, center_hex[1], center_hex[2], { ignore_units = true })

            unit_copy.x, unit_copy.y = old_hex[1], old_hex[2]

            local rating = cost_start - cost_new
            -- As a tie breaker, prefer zone that is originally farther away
            rating = rating + cost_start / 1000

            --std_print('  ' .. zone_id, cost_start, cost_new, rating)

            if (not score) or (rating > score) then
               to_zone_id, score = zone_id, rating
            end
        end
    end

    return to_zone_id
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

    local old_loc, uiw
    if loc and ((loc[1] ~= unit_proxy.x) or (loc[2] ~= unit_proxy.y)) then
        uiw = wesnoth.get_unit(loc[1], loc[2])
        if uiw then wesnoth.extract_unit(uiw) end
        old_loc = { unit_proxy.x, unit_proxy.y }
        H.modify_unit(
            { id = unit_proxy.id} ,
            { x = loc[1], y = loc[2] }
        )
    end
    local old_moves, old_max_moves = unit_proxy.moves, unit_proxy.max_moves
    H.modify_unit(
        { id = unit_proxy.id} ,
        { moves = 98, max_moves = 98 }
    )

    local cm = wesnoth.find_cost_map(unit_proxy.x, unit_proxy.y, { ignore_units = true })

    H.modify_unit(
        { id = unit_proxy.id},
        { moves = old_moves, max_moves = old_max_moves }
    )
    if old_loc then
        H.modify_unit(
            { id = unit_proxy.id} ,
            { x = old_loc[1], y = old_loc[2] }
        )
        if uiw then wesnoth.put_unit(uiw) end
    end

    local movecost_0
    if is_inverse_map then
        movecost_0 = wesnoth.unit_movement_cost(unit_proxy, wesnoth.get_terrain(loc[1], loc[2]))
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
                movecost = wesnoth.unit_movement_cost(unit_proxy, wesnoth.get_terrain(x, y))
                c = c + movecost_0 - movecost
            end

            fred_utils.set_fgumap_value(cost_map, cost[1], cost[2], 'cost', c)
        end
    end

    if false then
        DBG.show_fgumap_with_message(cost_map, 'cost', 'cost_map', unit_proxy.id)
    end

    return cost_map
end

function fred_utils.get_leader_distance_map(zone_cfgs, side_cfgs, move_data)
    local leader_loc, enemy_leader_loc
    for side,cfg in ipairs(side_cfgs) do
        if (side == wesnoth.current.side) then
            leader_loc = cfg.start_hex
        else
            enemy_leader_loc = cfg.start_hex
        end
    end

    -- Need a map with the distances to the enemy and own leaders
    -- TODO: Leave like this for now, potentially switch to using smooth_cost_map() later
    local leader_cx, leader_cy = AH.cartesian_coords(leader_loc[1], leader_loc[2])
    local enemy_leader_cx, enemy_leader_cy = AH.cartesian_coords(enemy_leader_loc[1], enemy_leader_loc[2])

    local dist_btw_leaders = math.sqrt( (enemy_leader_cx - leader_cx)^2 + (enemy_leader_cy - leader_cy)^2 )

    local leader_distance_map = {}
    local width, height = wesnoth.get_map_size()
    for x = 1,width do
        for y = 1,height do
            local cx, cy = AH.cartesian_coords(x, y)

            local leader_dist = math.sqrt( (leader_cx - cx)^2 + (leader_cy - cy)^2 )
            local enemy_leader_dist = math.sqrt( (enemy_leader_cx - cx)^2 + (enemy_leader_cy - cy)^2 )

            if (not leader_distance_map[x]) then leader_distance_map[x] = {} end
            leader_distance_map[x][y] = {
                my_leader_distance = leader_dist,
                enemy_leader_distance = enemy_leader_dist,
                distance = (leader_dist - 0.5 * enemy_leader_dist) / 1.5
            }

        end
    end

    -- Enemy leader distance maps. These are calculated using wesnoth.find_cost_map() for
    -- each unit type from the start hex of the enemy leader.
    -- TODO: Doing this by unit type may cause problems once Fred can play factions
    -- with unit types that have different variations (i.e. Walking Corpses). Fix later.
    local enemy_leader_distance_maps = {}
    for zone_id,cfg in pairs(zone_cfgs) do
        enemy_leader_distance_maps[zone_id] = {}

        local old_terrain = {}
        local avoid_locs = wesnoth.get_locations { { "not", cfg.ops_slf  } }
        for _,avoid_loc in ipairs(avoid_locs) do
            table.insert(old_terrain, {avoid_loc[1], avoid_loc[2], wesnoth.get_terrain(avoid_loc[1], avoid_loc[2])})
            wesnoth.set_terrain(avoid_loc[1], avoid_loc[2], "Xv")
        end

        for id,unit_loc in pairs(move_data.my_units) do
            local typ = move_data.unit_infos[id].type -- can't use type, that's reserved

            if (not enemy_leader_distance_maps[zone_id][typ]) then
                local unit_proxy = wesnoth.get_unit(unit_loc[1], unit_loc[2])
                enemy_leader_distance_maps[zone_id][typ] = fred_utils.smooth_cost_map(unit_proxy, enemy_leader_loc, true)
            end
        end

        for _,terrain in ipairs(old_terrain) do
            wesnoth.set_terrain(terrain[1], terrain[2], terrain[3])
        end
        -- The above procedure unsets village ownership
        for x,y,data in fred_utils.fgumap_iter(move_data.village_map) do
            if (data.owner > 0) then
                wesnoth.set_village_owner(x, y, data.owner)
            end
        end
    end

    -- Also need this for the full map
    enemy_leader_distance_maps['all_map'] = {}
    for id,unit_loc in pairs(move_data.my_units) do
        local typ = move_data.unit_infos[id].type -- can't use type, that's reserved

        if (not enemy_leader_distance_maps['all_map'][typ]) then
            local unit_proxy = wesnoth.get_unit(unit_loc[1], unit_loc[2])
            enemy_leader_distance_maps['all_map'][typ] = fred_utils.smooth_cost_map(unit_proxy, enemy_leader_loc, true)
        end
    end

    return leader_distance_map, enemy_leader_distance_maps
end

function fred_utils.get_influence_maps(move_data)
    local leader_derating = FCFG.get_cfg_parm('leader_derating')
    local influence_falloff_floor = FCFG.get_cfg_parm('influence_falloff_floor')
    local influence_falloff_exp = FCFG.get_cfg_parm('influence_falloff_exp')

    local influence_maps, unit_influence_maps = {}, {}
    for int_turns = 1,2 do
        for x,y,data in fred_utils.fgumap_iter(move_data.my_attack_map[int_turns]) do
            for _,id in pairs(data.ids) do
                local unit_influence = fred_utils.unit_current_power(move_data.unit_infos[id], x, y, move_data)
                if move_data.unit_infos[id].canrecruit then
                    unit_influence = unit_influence * leader_derating
                end

                local moves_left = fred_utils.get_fgumap_value(move_data.unit_attack_maps[int_turns][id], x, y, 'moves_left_this_turn')
                local inf_falloff = 1 - (1 - influence_falloff_floor) * (1 - moves_left / move_data.unit_infos[id].max_moves) ^ influence_falloff_exp
                local my_influence = unit_influence * inf_falloff

                -- TODO: this is not 100% correct as a unit could have 0<moves<max_moves, but it's close enough for now.
                if (int_turns == 1) then
                    fred_utils.fgumap_add(influence_maps, x, y, 'my_influence', my_influence)
                    fred_utils.fgumap_add(influence_maps, x, y, 'my_number', 1)

                    fred_utils.fgumap_add(influence_maps, x, y, 'my_full_move_influence', unit_influence)

                    if (not unit_influence_maps[id]) then
                        unit_influence_maps[id] = {}
                    end
                    fred_utils.fgumap_add(unit_influence_maps[id], x, y, 'influence', my_influence)
                end
                if (int_turns == 2) and (move_data.unit_infos[id].moves == 0) then
                    fred_utils.fgumap_add(influence_maps, x, y, 'my_full_move_influence', unit_influence)
                end
            end
        end
    end

    for x,y,data in fred_utils.fgumap_iter(move_data.enemy_attack_map[1]) do
        for _,enemy_id in pairs(data.ids) do
            local unit_influence = fred_utils.unit_current_power(move_data.unit_infos[enemy_id], x, y, move_data)
            if move_data.unit_infos[enemy_id].canrecruit then
                unit_influence = unit_influence * leader_derating
            end

            local moves_left = fred_utils.get_fgumap_value(move_data.reach_maps[enemy_id], x, y, 'moves_left') or -1
            if (moves_left < move_data.unit_infos[enemy_id].max_moves) then
                moves_left = moves_left + 1
            end
            local inf_falloff = 1 - (1 - influence_falloff_floor) * (1 - moves_left / move_data.unit_infos[enemy_id].max_moves) ^ influence_falloff_exp

            enemy_influence = unit_influence * inf_falloff
            fred_utils.fgumap_add(influence_maps, x, y, 'enemy_influence', enemy_influence)
            fred_utils.fgumap_add(influence_maps, x, y, 'enemy_number', 1)
            fred_utils.fgumap_add(influence_maps, x, y, 'enemy_full_move_influence', unit_influence) -- same as 'enemy_influence' for now

            if (not unit_influence_maps[enemy_id]) then
                unit_influence_maps[enemy_id] = {}
            end
            fred_utils.fgumap_add(unit_influence_maps[enemy_id], x, y, 'influence', enemy_influence)
        end
    end

    for x,y,data in fred_utils.fgumap_iter(influence_maps) do
        data.influence = (data.my_influence or 0) - (data.enemy_influence or 0)
        data.full_move_influence = (data.my_full_move_influence or 0) - (data.enemy_full_move_influence or 0)
        data.tension = (data.my_influence or 0) + (data.enemy_influence or 0)
        data.vulnerability = data.tension - math.abs(data.influence)
    end

    if DBG.show_debug('analysis_influence_maps') then
        DBG.show_fgumap_with_message(influence_maps, 'my_influence', 'My influence map')
        DBG.show_fgumap_with_message(influence_maps, 'my_full_move_influence', 'My full-move influence map')
        --DBG.show_fgumap_with_message(influence_maps, 'my_number', 'My number')
        DBG.show_fgumap_with_message(influence_maps, 'enemy_influence', 'Enemy influence map')
        --DBG.show_fgumap_with_message(influence_maps, 'enemy_number', 'Enemy number')
        DBG.show_fgumap_with_message(influence_maps, 'enemy_full_move_influence', 'Enemy full-move influence map')
        DBG.show_fgumap_with_message(influence_maps, 'influence', 'Influence map')
        DBG.show_fgumap_with_message(influence_maps, 'full_move_influence', 'Full-move influence map')
        DBG.show_fgumap_with_message(influence_maps, 'tension', 'Tension map')
        DBG.show_fgumap_with_message(influence_maps, 'vulnerability', 'Vulnerability map')
    end

    if DBG.show_debug('analysis_unit_influence_maps') then
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
                fred_utils.set_fgumap_value(cost_map, cost[1], cost[2], 'cost', c)
            end
        end

        support_maps.units[id] = {}
        for x = 1,width do
            for y = 1,height do
                local min_cost = fred_utils.get_fgumap_value(cost_map, x, y, 'cost') or 99
                for xa,ya in H.adjacent_tiles(x, y) do
                    local adj_cost = fred_utils.get_fgumap_value(cost_map, xa, ya, 'cost') or 99
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
                    fred_utils.set_fgumap_value(support_maps.units[id], x, y, 'support', support)
                    fred_utils.fgumap_add(support_maps.total, x, y, 'support', support)
                end
            end
        end

    end

    return support_maps
end

function fred_utils.behind_enemy_map(fred_data)
    local function is_new_behind_hex(x, y, enemy_id, unit_behind_map, ld_ref)
        local move_cost = wesnoth.unit_movement_cost(fred_data.move_data.unit_copies[enemy_id], wesnoth.get_terrain(x, y))
        if (move_cost >= 99) then
            return false, false, false
        end

        if fred_utils.get_fgumap_value(unit_behind_map, x, y, 'enemy_power') then
            return false, false, true
        end

        local ld = fred_utils.get_fgumap_value(fred_data.turn_data.leader_distance_map, x, y, 'my_leader_distance')
        if (ld < ld_ref) then
            return false, true, true
        end

        if (not fred_utils.get_fgumap_value(fred_data.move_data.unit_attack_maps[1][enemy_id], x, y, 'current_power'))
            and (not fred_utils.get_fgumap_value(fred_data.move_data.unit_attack_maps[2][enemy_id], x, y, 'current_power'))
        then
            return false, true, true
        end

        return true, true, true
    end

    local behind_enemy_map = {}
    for enemy_id,enemy_loc in pairs(fred_data.move_data.enemies) do
        local current_power = fred_utils.unit_current_power(fred_data.move_data.unit_infos[enemy_id])

        local unit_behind_map = {}
        fred_utils.set_fgumap_value(unit_behind_map, enemy_loc[1], enemy_loc[2], 'enemy_power', current_power)
        local new_hexes = { enemy_loc }

        local keep_trying = true
        while keep_trying do
            keep_trying = false

            local hexes = AH.table_copy(new_hexes)
            new_hexes = {}
            for _,loc in ipairs(hexes) do
                local ld_ref = fred_utils.get_fgumap_value(fred_data.turn_data.leader_distance_map, loc[1], loc[2], 'my_leader_distance')
                for xa,ya in H.adjacent_tiles(loc[1], loc[2]) do
                    local is_valid, is_new, is_passable = is_new_behind_hex(xa, ya, enemy_id, unit_behind_map, ld_ref)
                    if is_passable then
                        if is_valid then
                            fred_utils.set_fgumap_value(unit_behind_map, xa, ya, 'enemy_power', current_power)
                            table.insert(new_hexes, { xa, ya })
                            keep_trying = true
                        elseif is_new then
                            -- This gives 2 rows of zeros around the edges, but not for
                            -- impassable terrain; needed for blurring
                            fred_utils.set_fgumap_value(unit_behind_map, xa, ya, 'enemy_power', 0)
                        end

                        -- Because of the hex geometry, we also need to do a second row
                        for xa2,ya2 in H.adjacent_tiles(xa, ya) do
                            local is_valid2, is_new2, is_passable2 = is_new_behind_hex(xa2, ya2, enemy_id, unit_behind_map, ld_ref)
                            if is_passable2 then
                                if is_valid2 then
                                    fred_utils.set_fgumap_value(unit_behind_map, xa2, ya2, 'enemy_power', current_power)
                                    table.insert(new_hexes, { xa2, ya2 })
                                    keep_trying = true
                                elseif is_new2 then
                                    -- This gives 2 rows of zeros around the edges, but not for
                                    -- impassable terrain; needed for blurring
                                    fred_utils.set_fgumap_value(unit_behind_map, xa2, ya2, 'enemy_power', 0)
                                end
                            end
                        end
                    end
                end
            end
        end

        fred_utils.fgumap_blur(unit_behind_map, 'enemy_power')
        fred_utils.fgumap_blur(unit_behind_map, 'blurred_enemy_power')

        if false then
            DBG.show_fgumap_with_message(unit_behind_map, 'blurred_blurred_enemy_power', 'behind map', fred_data.move_data.unit_copies[enemy_id])
        end

        for x,y,data in fred_utils.fgumap_iter(unit_behind_map) do
            fred_utils.fgumap_add(behind_enemy_map, x, y, 'enemy_power', data.blurred_blurred_enemy_power)
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
    -- Important: this is slow, so it should only be called once at the  beginning
    -- of each move, but it does need to be redone after each move, as it contains
    -- information like HP and XP (or the unit might have level up or been changed
    -- in an event).
    --
    -- Note: unit location information is NOT included
    -- See above for the format and type of information included.

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
        alignment = unit_cfg.alignment,
        cost = unit_cfg.cost,
        level = unit_cfg.level
    }

    -- Pick the first of the advances_to types, nil when there is none
    single_unit_info.advances_to = unit_proxy.advances_to[1]

    -- Include the ability type, such as: hides, heals, regenerate, skirmisher (set up as 'hides = true')
    single_unit_info.abilities = {}
    local abilities = wml.get_child(unit_proxy.__cfg, "abilities")
    if abilities then
        for _,ability in ipairs(abilities) do
            single_unit_info.abilities[ability[1]] = true
        end
    end

    -- Information about the attacks indexed by weapon number,
    -- including specials (e.g. 'poison = true')
    single_unit_info.attacks = {}
    local max_damage = 0
    for attack in wml.child_range(unit_cfg, 'attack') do
        -- Extract information for specials; we do this first because some
        -- custom special might have the same name as one of the default scalar fields
        local a = {}
        for special in wml.child_range(attack, 'specials') do
            for _,sp in ipairs(special) do
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
        end

        -- Now extract the scalar (string and number) values from attack
        for k,v in pairs(attack) do
            if (type(v) == 'number') or (type(v) == 'string') then
                a[k] = v
            end
        end

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
        local defense = wml.get_child(unit_proxy.__cfg, "defense")

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


        -- Resistances to the 6 default attack types
        local attack_types = { "arcane", "blade", "cold", "fire", "impact", "pierce" }
        single_unit_info.resistances = {}
        for _,attack_type in ipairs(attack_types) do
            single_unit_info.resistances[attack_type] = wesnoth.unit_resistance(unit_proxy, attack_type) / 100.
        end
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
    local max_rating, best_combo
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
                    if (count > 1000) then break end
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
                        if (tmp_count > max_count) then max_rating = nil end

                        -- If this is less than current max_count, don't use this combo
                        if ((not max_rating) or (rating > max_rating)) and (tmp_count >= max_count) then
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
                if (tmp_count > max_count) then max_rating = nil end

                -- If this is less than current max_count, don't use this attack
                if ((not max_rating) or (rating > max_rating)) and (tmp_count >= max_count)then
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
