local H = wesnoth.require "helper"
local AH = wesnoth.require "ai/lua/ai_helper.lua"
local FAU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack_utils.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local FCFG = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_config.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local fred_hold_utils = {}

function fred_hold_utils.get_between_map(locs, toward_loc, units, move_data)
    -- Calculate the "between-ness" of map hexes between @locs and @units
    -- @toward_loc: the direction of the main gradient of the map. Usually
    --   this is toward the AI leader, but any hex can be passed.
    --
    -- Note: this function ignores enemies and distance of the units
    -- from the hexes. Whether this makes sense to use all these units needs
    -- to be checked in the calling function

    local weights, cum_weight = {}, 0
    for id,_ in pairs(units) do
        local weight = FU.unit_current_power(move_data.unit_infos[id])
        weights[id] = weight
        cum_weight = cum_weight + weight
    end
    for id,weight in pairs(weights) do
        weights[id] = weight / cum_weight / #locs
    end
    --DBG.dbms(weights)

    local between_map = {}
    for id,unit_loc in pairs(units) do
        --std_print(id, unit_loc[1], unit_loc[2])
        local unit = {}
        unit[id] = unit_loc
        local unit_proxy = wesnoth.get_unit(unit_loc[1], unit_loc[2])

        -- For the perpendicular distance, we need a map denoting which
        -- hexes are on the "left" and "right" of the path of the unit
        -- to toward_loc. 'path_map' is set to be zero on the path, +1
        -- on one side (nominally the right) and -1 on the other side.
        local path = wesnoth.find_path(unit_proxy, toward_loc[1], toward_loc[2], { ignore_units = true })

        local path_map = {}
        for _,loc in ipairs(path) do
            FU.set_fgumap_value(path_map, loc[1], loc[2], 'sign', 0)
        end

        local new_hexes = {}
        for i_p=1,#path-1 do
            p1, p2 = path[i_p], path[i_p+1]
            local rad_path = AH.get_angle(p1, p2)
            --std_print(p1[1] .. ',' .. p1[2], p2[1] .. ',' .. p2[2], rad_path)

            for xa,ya in H.adjacent_tiles(p1[1], p1[2]) do
                local rad = AH.get_angle(p1, { xa, ya })
                local drad = rad - rad_path
                --std_print('  ' .. xa .. ',' .. ya .. ':', rad, drad)

                if (not FU.get_fgumap_value(path_map, xa, ya, 'sign')) then
                    if (drad > 0) and (drad < 3.14) or (drad < -3.14) then
                        table.insert(new_hexes, { xa, ya, 1 })
                        FU.set_fgumap_value(path_map, xa, ya, 'sign', 1)
                    else
                        table.insert(new_hexes, { xa, ya, -1 })
                        FU.set_fgumap_value(path_map, xa, ya, 'sign', -1)
                    end
                end
            end
        end

        while (#new_hexes > 0) do
            local old_hexes = AH.table_copy(new_hexes)
            new_hexes = {}

            for _,hex in ipairs(old_hexes) do
                for xa,ya in H.adjacent_tiles(hex[1], hex[2]) do
                    if (not FU.get_fgumap_value(path_map, xa, ya, 'sign')) then
                        table.insert(new_hexes, { xa, ya, hex[3] })
                        FU.set_fgumap_value(path_map, xa, ya, 'sign', hex[3])
                    end
                end
            end
        end

        if false then
            DBG.show_fgumap_with_message(path_map, 'sign', 'path_map: sign')
        end


        local cost_map = FU.smooth_cost_map(unit_proxy)
        local inv_cost_map = FU.smooth_cost_map(unit_proxy, toward_loc, true)

        if false then
            DBG.show_fgumap_with_message(cost_map, 'cost', 'cost_map', move_data.unit_copies[id])
            DBG.show_fgumap_with_message(inv_cost_map, 'cost', 'inv_cost_map', move_data.unit_copies[id])
        end

        local cost_full = FU.get_fgumap_value(cost_map, toward_loc[1], toward_loc[2], 'cost')
        local inv_cost_full = FU.get_fgumap_value(inv_cost_map, unit_loc[1], unit_loc[2], 'cost')

        for _,loc in ipairs(locs) do
            local unit_map = {}
            for x,y,data in FU.fgumap_iter(cost_map) do
                local cost = data.cost or 99
                local inv_cost = FU.get_fgumap_value(inv_cost_map, x, y, 'cost')

                -- This gives a rating that is a slanted plane, from the unit to toward_loc
                local rating = (inv_cost - cost) / 2
                if (cost > cost_full) then
                    rating = rating + (cost_full - cost)
                end
                if (inv_cost > inv_cost_full) then
                    rating = rating + (inv_cost - inv_cost_full)
                end

                rating = rating * weights[id]

                local perp_distance = cost + inv_cost - (cost_full + inv_cost_full) / 2
                perp_distance = perp_distance * FU.get_fgumap_value(path_map, x, y, 'sign')

                FU.set_fgumap_value(unit_map, x, y, 'rating', rating)
                FU.set_fgumap_value(unit_map, x, y, 'perp_distance', perp_distance * weights[id])
                FU.fgumap_add(between_map, x, y, 'inv_cost', inv_cost * weights[id])
            end

            local loc_value = FU.get_fgumap_value(unit_map, loc[1], loc[2], 'rating')
            local unit_value = FU.get_fgumap_value(unit_map, unit_loc[1], unit_loc[2], 'rating')
            local max_value = (loc_value + unit_value) / 2
            --std_print(loc[1], loc[2], loc_value, unit_value, max_value)

            for x,y,data in FU.fgumap_iter(unit_map) do
                local rating = data.rating

                -- Set rating to maximum at midpoint between unit and loc
                -- Decrease values in excess of that by that excess
                if (rating > max_value) then
                    rating = rating - 2 * (rating - max_value)
                end

                -- Set rating to zero at loc (and therefore also at unit)
                rating = rating - loc_value

                -- Rating falls off in perpendicular direction
                rating = rating - math.abs((data.perp_distance / move_data.unit_infos[id].max_moves)^2)

                FU.fgumap_add(between_map, x, y, 'distance', rating)
                FU.fgumap_add(between_map, x, y, 'perp_distance', data.perp_distance)
            end
        end
    end

    FU.fgumap_blur(between_map, 'distance')
    FU.fgumap_blur(between_map, 'perp_distance')

    return between_map
end


function fred_hold_utils.convolve_rating_maps(rating_maps, key, between_map, turn_data)
    local count = 0
    for id,_ in pairs(rating_maps) do
        count = count + 1
    end

    if (count == 1) then
        for id,rating_map in pairs(rating_maps) do
            for _,_,data in FU.fgumap_iter(rating_map) do
                data.conv = 1
                data[key] = data[key .. '_org']
            end
        end

        return
    end

    for id,rating_map in pairs(rating_maps) do
        for x,y,_ in FU.fgumap_iter(rating_map) do
            local dist, perp_dist
            if between_map then
                dist = FU.get_fgumap_value(between_map, x, y, 'blurred_distance') or -999
                perp_dist = FU.get_fgumap_value(between_map, x, y, 'blurred_perp_distance') or 0
            else
                -- In this case we do not have the perpendicular distance
                dist = FU.get_fgumap_value(turn_data.leader_distance_map, x, y, 'distance')
            end
            --std_print(id, x .. ',' .. y, dist, perp_dist)

            local convs = {}
            for x2=x-3,x+3 do
                for y2=y-3,y+3 do
                    if ((x2 ~= x) or (y2 ~= y)) then
                        -- This is faster than filtering by radius
                        local dr = wesnoth.map.distance_between(x, y, x2, y2)
                        if (dr <= 3) then
                            local dist2, perp_dist2
                            if between_map then
                                dist2 = FU.get_fgumap_value(between_map, x2, y2, 'blurred_distance') or -999
                                perp_dist2 = FU.get_fgumap_value(between_map, x2, y2, 'blurred_perp_distance') or 0
                            else
                                dist2 = FU.get_fgumap_value(turn_data.leader_distance_map, x2, y2, 'distance') or -999
                            end

                            local dy = math.abs(dist - dist2)
                            local angle
                            if between_map then
                                local dx = math.abs(perp_dist - perp_dist2)
                                -- Note, this must be x/y, not y/x!  We want the angle from the toward-leader direction
                                angle = math.atan(dx, dy) / 1.5708
                            else
                                -- Note, this must be y/r, not x/r!  We want the angle from the toward-leader direction
                                if (dy > dr) then
                                    angle = 0
                                else
                                    angle = math.acos(dy / dr) / 1.5708
                                end
                            end

                            local angle_fac = FU.weight_s(angle, 0.67)
                            --std_print('  ' .. id, x .. ',' .. y, x2 .. ',' .. y2, dr, angle, angle_fac)

                            -- We want to know how strong the other hexes are for the other units
                            local conv_sum_units, count = 0, 0
                            for id2,rating_map2 in pairs(rating_maps) do
                                if (id ~= id2) then
                                    local pr = FU.get_fgumap_value(rating_map2, x2, y2, key ..'_org')
                                    if pr then
                                        conv_sum_units = conv_sum_units + pr * angle_fac
                                        count = count + 1
                                    end
                                end
                            end
                            if (count > 0) then
                                conv_sum_units = conv_sum_units / count
                                table.insert(convs, { rating = conv_sum_units })
                            end
                        end
                    end
                end
            end

            table.sort(convs, function(a, b) return a.rating > b.rating end)
            local conv = 0
            -- If we do the sum (or average) over all of the hexes, locations at
            -- the edges are penalized too much.
            for i=1,math.min(5, #convs) do
                conv = conv + convs[i].rating
            end

            FU.set_fgumap_value(rating_map, x, y, 'conv', conv)
        end

        FU.fgumap_normalize(rating_map, 'conv')
        for _,_,data in FU.fgumap_iter(rating_map) do
            -- It is possible for this value to be zero if no other units
            -- can get to surrounding hexes. While it is okay to derate this
            -- hex then, it should not be set to zero
            local conv = data.conv
            if (conv < 0.5) then conv = 0.5 end
            data[key] = data[key .. '_org'] * conv
        end
    end
end


function fred_hold_utils.unit_rating_maps_to_dstsrc(unit_rating_maps, key, move_data, cfg)
    -- It's assumed that all individual unit_rating maps contain at least one rating

    local max_units = (cfg and cfg.max_units) or 3 -- number of units to be used per combo
    local max_hexes = (cfg and cfg.max_hexes) or 6 -- number of hexes per unit for placement combos


    -- First, set up sorted arrays for each unit
    local sorted_ratings = {}
    for id,unit_rating_map in pairs(unit_rating_maps) do
        sorted_ratings[id] = {}
        for _,_,data in FU.fgumap_iter(unit_rating_map) do
            table.insert(sorted_ratings[id], data)
        end
        table.sort(sorted_ratings[id], function(a, b) return a[key] > b[key] end)
    end
    --DBG.dbms(sorted_ratings)


    -- The best units are those with the highest total rating
    local best_units = {}
    for id,sorted_rating in pairs(sorted_ratings) do
        local count = math.min(max_hexes, #sorted_rating)

        local top_ratings = 0
        for i = 1,count do
            top_ratings = top_ratings + sorted_rating[i][key]
        end
        top_ratings = top_ratings / count

        -- Prefer tanks, i.e. the highest-HP units,
        -- but be more careful with high-XP units
        -- Use the same weight as in the combo eval below
        local unit_weight = move_data.unit_infos[id].hitpoints
        if (move_data.unit_infos[id].experience < move_data.unit_infos[id].max_experience - 1) then
            local xp_penalty = move_data.unit_infos[id].experience / move_data.unit_infos[id].max_experience
            xp_penalty = FU.weight_s(xp_penalty, 0.5)
            unit_weight = unit_weight - xp_penalty * 10
            if (unit_weight < 1) then unit_weight = 1 end
        end

        top_ratings = top_ratings * unit_weight

        table.insert(best_units, { id = id, top_ratings = top_ratings })
    end
    table.sort(best_units, function(a, b) return a.top_ratings > b.top_ratings end)
    --DBG.dbms(best_units)


    -- Units to be used
    local n_units = math.min(max_units, #best_units)
    local use_units = {}
    for i = 1,n_units do use_units[i] = best_units[i] end
    --DBG.dbms(use_units)


    -- Show the units and hexes to be used
    if DBG.show_debug('hold_best_units_hexes') then
        for _,unit in ipairs(use_units) do
            local tmp_map = {}
            local count = math.min(max_hexes, #sorted_ratings[unit.id])
            for i = 1,count do
                FU.set_fgumap_value(tmp_map, sorted_ratings[unit.id][i].x, sorted_ratings[unit.id][i].y, 'protect_rating', sorted_ratings[unit.id][i].protect_rating)
            end
            DBG.show_fgumap_with_message(tmp_map, 'protect_rating', 'Best protect_rating', move_data.unit_copies[unit.id])
        end
    end


    -- Finally, we need to set up the dst_src array in a way that can be used by get_unit_hex_combos()
    local ratings = {}
    for _,unit in ipairs(use_units) do
        local src = move_data.unit_copies[unit.id].x * 1000 + move_data.unit_copies[unit.id].y
        --std_print(unit.id, src)
        local count = math.min(max_hexes, #sorted_ratings[unit.id])
        for i = 1,count do
            local dst = sorted_ratings[unit.id][i].x * 1000 + sorted_ratings[unit.id][i].y
            --std_print('  ' .. dst, sorted_ratings[unit.id][i].rating)

            if (not ratings[dst]) then
                ratings[dst] = {}
            end

            ratings[dst][src] = sorted_ratings[unit.id][i]
        end
    end
    --DBG.dbms(ratings)

    local dst_src = {}
    for dst,srcs in pairs(ratings) do
        local tmp = { dst = dst }
        for src,_ in pairs(srcs) do
            table.insert(tmp, { src = src })
        end
        table.insert(dst_src, tmp)
    end
    --DBG.dbms(dst_src)

    return dst_src, ratings
end


function fred_hold_utils.find_best_combo(combos, ratings, key, adjacent_village_map, between_map, fred_data, cfg)
    local move_data = fred_data.move_data
    local leader_id = move_data.leaders[wesnoth.current.side].id
    local leader_protect_base_rating

    local value_ratio = fred_data.turn_data.behavior.orders.value_ratio
    local hold_counter_weight = FCFG.get_cfg_parm('hold_counter_weight')
    local cfg_attack = { value_ratio = value_ratio }

    if cfg.protect_leader then
        local leader_target = {}
        leader_target[leader_id] = { move_data.leader_x, move_data.leader_y }
        local old_locs = { { move_data.leader_x, move_data.leader_y } }
        local new_locs = { { move_data.leader_x, move_data.leader_y } }

        local counter_outcomes = FAU.calc_counter_attack(
            leader_target, old_locs, new_locs, cfg_attack, move_data, fred_data.move_cache
        )

        local remainging_hp = move_data.unit_infos[leader_id].hitpoints
        -- TODO: add healthy, regenerate.  Use fred_attack_utils functions?
        if counter_outcomes then
            remainging_hp = counter_outcomes.def_outcome.average_hp
            remainging_hp = remainging_hp - counter_outcomes.def_outcome.poisoned * 8
            remainging_hp = remainging_hp - counter_outcomes.def_outcome.slowed * 4
            if (remainging_hp < 0) then remainging_hp = 0 end
        end

        leader_protect_base_rating = remainging_hp / move_data.unit_infos[leader_id].max_hitpoints

        -- Plus chance of survival
        leader_protect_base_rating = leader_protect_base_rating + 1
        if counter_outcomes then
            leader_protect_base_rating = leader_protect_base_rating - counter_outcomes.def_outcome.hp_chance[0]
            --std_print('  ' .. counter_outcomes.def_outcome.hp_chance[0])
        end

        leader_protect_base_rating = 1 + leader_protect_base_rating / 2
        --std_print('base', remainging_hp, leader_protect_base_rating)
    end


    -- The first loop simply does a weighted sum of the individual unit ratings.
    -- It is done no matter which type of holding we're evaluation.
    -- Combos that leave adjacent villages exposed are disqualified.
    local valid_combos, weights = {}, {}
    for i_c,combo in ipairs(combos) do
        --std_print('combo ' .. i_c)
        local base_rating = 0
        local is_dqed = false

        local cum_weight, count = 0, 0
        for src,dst in pairs(combo) do
            local id = ratings[dst][src].id

            -- Prefer tanks, i.e. the highest-HP units,
            -- but be more careful with high-XP units
            local weight
            if (not weights[id]) then
                weight = move_data.unit_infos[id].hitpoints

                if (move_data.unit_infos[id].experience < move_data.unit_infos[id].max_experience - 1) then
                    local xp_penalty = move_data.unit_infos[id].experience / move_data.unit_infos[id].max_experience
                    xp_penalty = FU.weight_s(xp_penalty, 0.5)
                    weight = weight - xp_penalty * 10
                    if (weight < 1) then weight = 1 end
                end

                weights[id] = weight
            else
                weight = weights[id]
            end

            base_rating = base_rating + ratings[dst][src][key] * weight
            cum_weight = cum_weight + weight
            count = count + 1

            -- If this is adjacent to a village that is not part of the combo, DQ this combo
            -- TODO: this might be overly retrictive
            local x, y =  math.floor(dst / 1000), dst % 1000
            local adj_vill_xy = FU.get_fgumap_value(adjacent_village_map, x, y, 'village_xy')
            --std_print(x, y, adj_vill_xy)
            if adj_vill_xy then
                is_dqed = true
                for _,tmp_dst in pairs(combo) do
                    if (adj_vill_xy == tmp_dst) then
                        is_dqed = false
                        break
                    end
                end
                --std_print('  is_dqed', x, y, is_dqed)

                if is_dqed then break end
            end
        end

        if (not is_dqed) then
            base_rating = base_rating / cum_weight * count
            table.insert(valid_combos, {
                combo = combo,
                base_rating = base_rating,
                count = count
            })
        end
    end
    --std_print('#valid_combos: ' .. #valid_combos .. '/' .. #combos)

    table.sort(valid_combos, function(a, b) return a.base_rating > b.base_rating end)
    --DBG.dbms(valid_combos)


    -- This loop does two things:
    -- 1. Check whether a combo protects the locations it is supposed to protect.
    -- 2. Rate the combos based on the shape of the formation and its orientation
    --    with respect to the direction in which the enemies are approaching.
    local good_combos = {}
    local protect_loc, protect_loc_str
    local tmp_max_rating, tmp_all_max_rating -- just for debug display purposes
    for i_c,combo in ipairs(valid_combos) do
        -- 1. Check whether a combo protects the locations it is supposed to protect.
        local is_protected = true
        local leader_protect_mult = 0
        if cfg and cfg.protect_locs then
            if cfg.protect_leader then
                -- For the leader, we check whether it is better protected by the combo
                local leader_target = {}
                leader_target[leader_id] = { move_data.leader_x, move_data.leader_y }
                local old_locs = { { move_data.leader_x, move_data.leader_y } }
                local new_locs = { { move_data.leader_x, move_data.leader_y } }
                for src,dst in pairs(combo.combo) do
                    local dst_x, dst_y =  math.floor(dst / 1000), dst % 1000
                    local src_x, src_y =  math.floor(src / 1000), src % 1000
                    table.insert(old_locs, { src_x, src_y })
                    table.insert(new_locs, { dst_x, dst_y })
                end

                protect_loc = { move_data.leader_x, move_data.leader_y }

                local counter_outcomes = FAU.calc_counter_attack(
                    leader_target, old_locs, new_locs, cfg_attack, move_data, fred_data.move_cache
                )

                local remainging_hp = move_data.unit_infos[leader_id].hitpoints
                if counter_outcomes then
                    remainging_hp = counter_outcomes.def_outcome.average_hp
                    remainging_hp = remainging_hp - counter_outcomes.def_outcome.poisoned * 8
                    remainging_hp = remainging_hp - counter_outcomes.def_outcome.slowed * 4
                    if (remainging_hp < 0) then remainging_hp = 0 end
                end

                local leader_protect_rating = remainging_hp / move_data.unit_infos[leader_id].max_hitpoints

                -- Plus chance of survival
                leader_protect_rating = leader_protect_rating + 1
                if counter_outcomes then
                    leader_protect_rating = leader_protect_rating - counter_outcomes.def_outcome.hp_chance[0]
                    --std_print('  ' .. counter_outcomes.def_outcome.hp_chance[0])
                end

                leader_protect_rating = 1 + leader_protect_rating / 2
                leader_protect_mult = leader_protect_rating / leader_protect_base_rating
                --std_print(i_c, remainging_hp, leader_protect_rating, leader_protect_mult)

                if (leader_protect_mult < 1.001) then
                    is_protected = false
                end
            else
                -- For non-leader protect_locs, they must be unreachable by enemies
                -- to count as protected.

                -- For now, simply use the protect_loc with the largest forward distance
                -- TODO: think about how to deal with several simultaneously
                local max_ld, loc
                for _,pl in ipairs(cfg.protect_locs) do
                    local ld = FU.get_fgumap_value(fred_data.turn_data.leader_distance_map, pl[1], pl[2], 'distance')
                    if (not max_ld) or (ld > max_ld) then
                        max_ld = ld
                        protect_loc = pl
                    end
                end
                protect_loc_str = tostring(protect_loc[1]) .. ',' .. tostring(protect_loc[2])
                --std_print('*** need to check protection of ' .. protect_loc[1] .. ',' .. protect_loc[2])

                -- First check (because it's quick): if there is a unit on the hex to be protected
                is_protected = false
                for src,dst in pairs(combo.combo) do
                    local x, y =  math.floor(dst / 1000), dst % 1000
                    --std_print('  ' .. x , y)

                    if (x == protect_loc[1]) and (y == protect_loc[2]) then
                        --std_print('    --> protected by having unit on hex')
                        is_protected = true
                        break
                    end
                end

                -- If that did not find anything, do path finding
                if (not is_protected) then
                    --std_print('combo ' .. i_c, protect_loc[1], protect_loc[2])
                    for src,dst in pairs(combo.combo) do
                        local id = ratings[dst][src].id
                        local x, y =  math.floor(dst / 1000), dst % 1000
                        --std_print(id, src, x,y, move_data.unit_copies[id].x, move_data.unit_copies[id].y)
                        wesnoth.put_unit(move_data.unit_copies[id], x, y)
                    end

                    local can_reach = false
                    for enemy_id,_ in pairs(move_data.enemies) do
                        local moves_left = FU.get_fgumap_value(move_data.reach_maps[enemy_id], protect_loc[1], protect_loc[2], 'moves_left')
                        if moves_left then
                            --std_print('  ' .. enemy_id, moves_left)
                            local _, cost = wesnoth.find_path(move_data.unit_copies[enemy_id], protect_loc[1], protect_loc[2])
                            --std_print('  cost: ', cost)

                            if (cost <= move_data.unit_infos[enemy_id].max_moves) then
                                --std_print('    can reach this!')
                                can_reach = true
                                break
                            end
                        end
                    end

                    for src,dst in pairs(combo.combo) do
                        local id = ratings[dst][src].id
                        wesnoth.extract_unit(move_data.unit_copies[id])
                        move_data.unit_copies[id].x, move_data.unit_copies[id].y = move_data.units[id][1], move_data.units[id][2]
                        --std_print('  ' .. id, src, move_data.unit_copies[id].x, move_data.unit_copies[id].y)
                    end

                    if (not can_reach) then
                        is_protected = true
                    end
                end
            end
        else
            -- If there are no locations to be protected, count hold as protecting by default
        end
        --std_print('is_protected', is_protected)


        -- 2. Rate the combos based on the shape of the formation and its orientation
        --    with respect to the direction in which the enemies are approaching.
        local formation_rating = combo.base_rating
        local angle_fac, dist_fac
        if (combo.count > 1) then
            local max_min_dist, max_dist, extremes
            local dists = {}
            for src,dst in pairs(combo.combo) do
                local x, y =  math.floor(dst / 1000), dst % 1000

                -- Find the maximum distance between any two closest hexes
                -- We also want the overall maximum distance
                local min_dist
                for src2,dst2 in pairs(combo.combo) do
                    if (src2 ~= src) or (dst2 ~= dst) then
                        x2, y2 =  math.floor(dst2 / 1000), dst2 % 1000
                        local d = wesnoth.map.distance_between(x2, y2, x, y)
                        if (not min_dist) or (d < min_dist) then
                            min_dist = d
                        end
                        if (not max_dist) or (d > max_dist) then
                            max_dist = d
                            extremes = { x = x, y = y, x2 = x2, y2 = y2 }
                        end
                    end
                end
                if (not max_min_dist) or (min_dist > max_min_dist) then
                    max_min_dist = min_dist
                end

                -- Set up an array of the between_map distances for all hexes
                local dist, perp_dist
                if between_map then
                    dist = FU.get_fgumap_value(between_map, x, y, 'blurred_distance') or -999
                    perp_dist = FU.get_fgumap_value(between_map, x, y, 'blurred_perp_distance') or 0
                else
                    -- In this case we do not have the perpendicular distance
                    dist = FU.get_fgumap_value(fred_data.turn_data.leader_distance_map, x, y, 'distance')
                end

                table.insert(dists, {
                    x = x, y = y,
                    dist = dist,
                    perp_dist = perp_dist
                })
            end

            if between_map then
                -- TODO: there might be cases when this sort does not work, e.g. when there
                -- are more than 3 hexes across with the same perp_dist value (before blurring)
                table.sort(dists, function(a, b) return a.perp_dist < b.perp_dist end)
            else
                for _,dist in ipairs(dists) do
                    local d1 = wesnoth.map.distance_between(dist.x, dist.y, extremes.x, extremes.y)
                    local d2 = wesnoth.map.distance_between(dist.x, dist.y, extremes.x2, extremes.y2)
                    --std_print(dist.x, dist.y, d1, d2, d1 - d2)
                    dist.perp_rank = d1 - d2
                end
                table.sort(dists, function(a, b) return a.perp_rank < b.perp_rank end)
            end
            --DBG.dbms(dists)

            local min_angle  -- This is the worst angle as far as blocking the enemy is concerned
            for i_h=1,#dists-1 do
                local dy = math.abs(dists[i_h + 1].dist - dists[i_h].dist)
                local angle
                if between_map then
                    local dx = math.abs(dists[i_h + 1].perp_dist - dists[i_h].perp_dist)
                    -- Note, this must be x/y, not y/x!  We want the angle from the toward-leader direction
                    angle = math.atan(dx, dy) / 1.5708
                else
                    local dr = wesnoth.map.distance_between(dists[i_h + 1].x, dists[i_h + 1].y, dists[i_h].x, dists[i_h].y)
                    -- Note, this must be y/r, not x/r!  We want the angle from the toward-leader direction
                    if (dy > dr) then
                        angle = 0
                    else
                        angle = math.acos(dy / dr) / 1.5708
                    end
                end
                --std_print(i_h, angle)

                if (not min_angle) or (angle < min_angle) then
                    min_angle = angle
                end
            end

            -- Potential TODO: this might undervalue combinations incl. adjacent hexes
            local scaled_angle = FU.weight_s(min_angle, 0.67)
            -- Make this a 20% maximum range effect
            angle_fac = (1 + scaled_angle / 5)
            --std_print('  -> min_angle: ' .. min_angle, scaled_angle, angle_fac)

            formation_rating = formation_rating * angle_fac

            -- Penalty for too far apart
            local thresh_dist = 3
            if cfg.protect_leader then thresh_dist = 2 end
            if (max_min_dist > thresh_dist) then
                dist_fac = 1 / ( 1 + (max_min_dist - thresh_dist) / 10)
                formation_rating = formation_rating * dist_fac
            end
        end
        --std_print('  formation_rating 2:', formation_rating)

        if cfg.protect_leader then
            formation_rating = formation_rating * leader_protect_mult
            --std_print(i_c, formation_rating, leader_protect_mult, formation_rating / leader_protect_mult)
        end

        table.insert(good_combos, {
            formation_rating = formation_rating,
            combo = combo.combo,
            is_protected = is_protected
        })

        if DBG.show_debug('hold_combo_formation_rating') then
            if (not tmp_all_max_rating) or (formation_rating > tmp_all_max_rating) then
                tmp_all_max_rating = formation_rating
            end
            if is_protected then
                if (not tmp_max_rating) or (formation_rating > tmp_max_rating) then
                    tmp_max_rating = formation_rating
                end
            end

            local protected_str = 'no'
            if is_protected then protected_str = 'yes' end
            if protect_loc_str then
                protected_str = protected_str .. ' ' .. protect_loc_str
            else
                protected_str = 'n/a'
            end
            local x, y
            for src,dst in pairs(combo.combo) do
                x, y =  math.floor(dst / 1000), dst % 1000
                wesnoth.wml_actions.label { x = x, y = y, text = ratings[dst][src].id }
            end
            wesnoth.scroll_to_tile(x, y)
            local rating_str =  string.format("%.4f = %.4f x %.4f x %.4f", formation_rating, angle_fac or -1111, dist_fac or -2222, combo.base_rating or -9999)
            local max_str = string.format("max:  protected: %.4f,  all: %.4f", tmp_max_rating or -9999, tmp_all_max_rating or -9999)
            wesnoth.wml_actions.message {
                speaker = 'narrator', caption = 'Combo ' .. i_c .. '/' .. #valid_combos .. ': formation_rating',
                message = rating_str .. '   is_protected = ' .. protected_str
                    .. '\n' .. max_str
            }
            for src,dst in pairs(combo.combo) do
                x, y =  math.floor(dst / 1000), dst % 1000
                wesnoth.wml_actions.label { x = x, y = y, text = "" }
            end
        end
    end
    --std_print('#good_combos: ' .. #good_combos .. '/' .. #valid_combos .. '/' .. #combos)

    table.sort(good_combos, function(a, b) return a.formation_rating > b.formation_rating end)
    --DBG.dbms(good_combos)


    -- Full counter attack analysis for the best combos
    local max_n_combos, reduced_max_n_combos = 20, 50

    -- Acceptable chance-to-die for non-protect forward holds
    local acceptable_ctd = 0.25
    if (value_ratio < 1) then
        acceptable_ctd = 0.25 + 0.75 * (1 / value_ratio - 1)
    end
    --std_print(cfg.forward_ratio, acceptable_ctd)

    local max_rating, best_combo, all_max_rating, all_best_combo
    local reduced_max_rating, reduced_best_combo, reduced_all_max_rating, reduced_all_best_combo
    for i_c,combo in pairs(good_combos) do
        --std_print('combo ' .. i_c)

        local old_locs, new_locs, ids = {}, {}, {}
        for s,d in pairs(combo.combo) do
            local src =  { math.floor(s / 1000), s % 1000 }
            local dst =  { math.floor(d / 1000), d % 1000 }
            --std_print('  ' .. src[1] .. ',' .. src[2] .. '  -->  ' .. dst[1] .. ',' .. dst[2])

            table.insert(old_locs, src)
            table.insert(new_locs, dst)
            table.insert(ids, FU.get_fgumap_value(move_data.my_unit_map, src[1], src[2], 'id'))
        end

        local counter_rating, rel_rating, count, full_count = 0, 0, 0, 0
        local remove_src = {}
        for i_l,loc in pairs(old_locs) do
            local target = {}
            target[ids[i_l]] = { new_locs[i_l][1], new_locs[i_l][2] }

            local counter_outcomes = FAU.calc_counter_attack(
                target, old_locs, new_locs, cfg_attack, move_data, fred_data.move_cache
            )
            if counter_outcomes then
                --DBG.dbms(counter_outcomes.rating_table)
                -- If this does not protect the asset, we do not do it if the
                -- chance to die is too high.
                -- Only do this if position is in front of protect_loc

                if (not combo.is_protected) then
                    if (counter_outcomes.def_outcome.hp_chance[0] > acceptable_ctd) then
                        local ld_protect = FU.get_fgumap_value(fred_data.turn_data.leader_distance_map, protect_loc[1], protect_loc[2], 'distance')
                        local ld = FU.get_fgumap_value(fred_data.turn_data.leader_distance_map, new_locs[i_l][1], new_locs[i_l][2], 'distance')
                        if (ld > ld_protect) then
                            -- We cannot just remove this dst from this hold, as this would
                            -- change the threats to the other dsts. The entire combo needs
                            -- to be discarded.
                            --std_print('Too dangerous for a non-protecting hold', counter_outcomes.def_outcome.hp_chance[0])
                            count = 0
                            break
                        end
                    end
                end


                local unit_rating = - counter_outcomes.rating_table.rating

                local unit_value = FU.unit_value(move_data.unit_infos[ids[i_l]])
                local unit_rel_rating = unit_rating / unit_value
                if (unit_rel_rating < 0) then
                    unit_rel_rating = - unit_rel_rating^2
                else
                    unit_rel_rating = unit_rel_rating^2
                end
                unit_rel_rating = 1 + unit_rel_rating * hold_counter_weight

                --std_print('  ' .. ids[i_l], unit_rating)
                --std_print('    ' .. unit_rel_rating, unit_value)
                rel_rating = rel_rating + unit_rel_rating
                count = count + 1
            else
                remove_src[old_locs[i_l][1] * 1000 + old_locs[i_l][2]] = true
            end

            full_count = full_count + 1
        end
        --std_print(i_c, count, full_count)

        if (count > 0) then
            rel_rating = rel_rating / count
            counter_rating = combo.formation_rating * rel_rating
            --std_print('  ---> ' .. combo.formation_rating, rel_rating, combo.formation_rating * rel_rating)

            if (count == full_count) then
                if combo.is_protected then
                    if (not max_rating) or (counter_rating > max_rating) then
                        max_rating = counter_rating
                        best_combo = combo
                        --DBG.dbms(best_combo)
                    end
                end

                if (not all_max_rating) or (counter_rating > all_max_rating) then
                    all_max_rating = counter_rating
                    all_best_combo = combo
                    --DBG.dbms(all_best_combo)
                end
            else
                local reduced_combo = {
                    combo = {},
                    formation_rating = combo.formation_rating,
                    is_protected = combo.is_protected
                }
                for src,dst in pairs(combo.combo) do
                    if (not remove_src[src]) then
                        reduced_combo.combo[src] = dst
                    end
                end

                if combo.is_protected then
                    if (not reduced_max_rating) or (counter_rating > reduced_max_rating) then
                        reduced_max_rating = counter_rating
                        reduced_best_combo = reduced_combo
                        --DBG.dbms(reduced_best_combo)
                    end
                end
                if (not reduced_all_max_rating) or (counter_rating > reduced_all_max_rating) then
                    reduced_all_max_rating = counter_rating
                    reduced_all_best_combo = reduced_combo
                    --DBG.dbms(reduced_all_best_combo)
                end
            end
        end

        if DBG.show_debug('hold_combo_counter_rating') then
            local protected_str = 'no'
            if combo.is_protected then protected_str = 'yes' end
            if protect_loc_str then
                protected_str = protected_str .. ' ' .. protect_loc_str
            else
                protected_str = 'n/a'
            end
            for i_l,loc in pairs(new_locs) do
                wesnoth.wml_actions.label { x = loc[1], y = loc[2], text = ids[i_l] }
            end
            wesnoth.scroll_to_tile(new_locs[1][1], new_locs[1][2])

            local rating_str =  string.format("%.4f = %.4f x %.4f", counter_rating, rel_rating, combo.formation_rating)
            local max_str = string.format("max:  protected: %.4f,  all: %.4f", max_rating or -9999, all_max_rating or -9999)
            wesnoth.wml_actions.message {
                speaker = 'narrator', caption = 'Combo ' .. i_c .. '/' .. #valid_combos .. ': counter_rating',
                message = rating_str .. '   is_protected = ' .. protected_str
                    .. '\n' .. max_str
            }
            for i_l,loc in pairs(new_locs) do
                wesnoth.wml_actions.label { x = loc[1], y = loc[2], text = "" }
            end
        end

        if ((i_c >= max_n_combos) and best_combo) or (i_c >= reduced_max_n_combos) then
            break
        end
    end

    if (not best_combo) then
       best_combo = reduced_best_combo
    end
    if (not all_best_combo) then
       all_best_combo = reduced_all_best_combo
    end

    --std_print(' ===> max rating:             ' .. (max_rating or 'none'))
    --std_print(' ===> max rating all: ' .. (all_max_rating or 'none'))

    return best_combo and best_combo.combo, all_best_combo and all_best_combo.combo, protect_loc_str
end


return fred_hold_utils
