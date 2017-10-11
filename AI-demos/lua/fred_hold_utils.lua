local H = wesnoth.require "lua/helper.lua"
local AH = wesnoth.require "ai/lua/ai_helper.lua"
local FAU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack_utils.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local W = H.set_wml_action_metatable {}
--local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local fred_hold_utils = {}

function fred_hold_utils.convolve_rating_maps(rating_maps, key, between_map, gamedata)
    for id,rating_map in pairs(rating_maps) do
        for x,y,map in FU.fgumap_iter(rating_map) do
            local dist, perp_dist
            if between_map then
                dist = FU.get_fgumap_value(between_map, x, y, 'blurred_distance')
                perp_dist = FU.get_fgumap_value(between_map, x, y, 'blurred_perp_distance')
            else
                -- In this case we do not have the perpendicular distance
                dist = FU.get_fgumap_value(gamedata.leader_distance_map, x, y, 'distance')
            end
            --print(id, x .. ',' .. y, dist, perp_dist)

            local convs = {}
            for x2=x-3,x+3 do
                for y2=y-3,y+3 do
                    if ((x2 ~= x) or (y2 ~= y)) then
                        -- This is faster than filtering by radius
                        local dr = H.distance_between(x, y, x2, y2)
                        if (dr <= 3) then
                            local dist2, perp_dist2
                            if between_map then
                                dist2 = FU.get_fgumap_value(between_map, x2, y2, 'blurred_distance', -999)
                                perp_dist2 = FU.get_fgumap_value(between_map, x2, y2, 'blurred_perp_distance', 0)
                            else
                                dist2 = FU.get_fgumap_value(gamedata.leader_distance_map, x, y, 'distance', -999)
                            end

                            local dy = math.abs(dist - dist2)
                            local angle
                            if between_map then
                                local dx = math.abs(perp_dist - perp_dist2)
                                -- Note, this must be x/y, not y/x!  We want the angle from the toward-leader direction
                                local angle = math.atan2(dx, dy) / 1.5708
                            else
                                -- Note, this must be y/r, not x/r!  We want the angle from the toward-leader direction
                                if (dy > dr) then
                                    angle = 0
                                else
                                    angle = math.acos(dy / dr) / 1.5708
                                end
                            end

                            local angle_fac = FU.weight_s(angle, 0.5)
                            --print('  ' .. x2 .. ',' .. y2, angle, angle_fac)

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
            for i=1,math.min(5,#convs) do
                conv = conv + convs[i].rating
            end

            FU.set_fgumap_value(rating_map, x, y, 'conv', conv)
        end

        FU.fgumap_normalize(rating_map, 'conv')
        for x,y,data in FU.fgumap_iter(rating_map) do
            -- It is possible for this value to be zero if no other units
            -- can get to surrounding hexes. While it is okay to derate this
            -- hex then, it should not be set to zero
            local conv = data.conv
            if (conv < 0.5) then conv = 0.5 end
            data[key] = data[key .. '_org'] * conv
        end
    end
end


function fred_hold_utils.unit_rating_maps_to_dstsrc(unit_rating_maps, key, gamedata, cfg)
    -- It's assumed that all individual unit_rating maps contain at least one rating

    local max_units = (cfg and cfg.max_units) or 3 -- number of units to be used per combo
    local max_hexes = (cfg and cfg.max_hexes) or 6 -- number of hexes per unit for placement combos


    -- First, set up sorted arrays for each unit
    local sorted_ratings = {}
    for id,unit_rating_map in pairs(unit_rating_maps) do
        sorted_ratings[id] = {}
        for x,y,data in FU.fgumap_iter(unit_rating_map) do
            table.insert(sorted_ratings[id], data)
        end
        table.sort(sorted_ratings[id], function(a, b) return a[key] > b[key] end)
    end
    --DBG.dbms(sorted_ratings)


    -- The best units are those with the highest total rating
    -- TODO: this does not make sense if everything is normalized
    -- TODO: use unit weights here already?

    local best_units = {}
    for id,sorted_rating in pairs(sorted_ratings) do
        local count = math.min(max_hexes, #sorted_rating)

        local top_ratings = 0
        for i = 1,count do
            top_ratings = top_ratings + sorted_rating[i][key]
        end
        top_ratings = top_ratings / count

        -- Want highest HP units to be most important
        local unit_weight = 1 + gamedata.unit_infos[id].hitpoints / 100
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
    if false then
        for _,unit in ipairs(use_units) do
            local tmp_map = {}
            local count = math.min(max_hexes, #sorted_ratings[unit.id])
            for i = 1,count do
                FU.set_fgumap_value(tmp_map, sorted_ratings[unit.id][i].x, sorted_ratings[unit.id][i].y, 'protect_rating', sorted_ratings[unit.id][i].protect_rating)
            end
            FU.show_fgumap_with_message(tmp_map, 'protect_rating', 'Best protect_rating', gamedata.unit_copies[unit.id])
        end
    end


    -- Finally, we need to set up the dst_src array in a way that can be used by get_unit_hex_combos()
    local ratings = {}
    for _,unit in ipairs(use_units) do
        local src = gamedata.unit_copies[unit.id].x * 1000 + gamedata.unit_copies[unit.id].y
        --print(unit.id, src)
        local count = math.min(max_hexes, #sorted_ratings[unit.id])
        for i = 1,count do
            local dst = sorted_ratings[unit.id][i].x * 1000 + sorted_ratings[unit.id][i].y
            --print('  ' .. dst, sorted_ratings[unit.id][i].rating)

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


function fred_hold_utils.find_best_combo(combos, ratings, key, adjacent_village_map, between_map, gamedata, move_cache, cfg)
    local leader_id = gamedata.leaders[wesnoth.current.side].id
    local leader_protect_base_rating

    if cfg.protect_leader then
        local leader_target = {}
        leader_target[leader_id] = { gamedata.leader_x, gamedata.leader_y }
        local old_locs = { { gamedata.leader_x, gamedata.leader_y } }
        local new_locs = { { gamedata.leader_x, gamedata.leader_y } }

        local counter_outcomes = FAU.calc_counter_attack(
            leader_target, old_locs, new_locs, gamedata, move_cache, cfg_attack
        )

        local remainging_hp = gamedata.unit_infos[leader_id].hitpoints
        -- TODO: add healthy, regenerate.  Use fred_attack_utils functions?
        if counter_outcomes then
            remainging_hp = counter_outcomes.def_outcome.average_hp
            remainging_hp = remainging_hp - counter_outcomes.def_outcome.poisoned * 8
            remainging_hp = remainging_hp - counter_outcomes.def_outcome.slowed * 4
            if (remainging_hp < 0) then remainging_hp = 0 end
        end

        leader_protect_base_rating = remainging_hp / gamedata.unit_infos[leader_id].max_hitpoints

        -- Plus chance of survival
        leader_protect_base_rating = leader_protect_base_rating + 1
        if counter_outcomes then
            leader_protect_base_rating = leader_protect_base_rating - counter_outcomes.def_outcome.hp_chance[0]
            --print('  ' .. counter_outcomes.def_outcome.hp_chance[0])
        end

        leader_protect_base_rating = 1 + leader_protect_base_rating / 2
        --print('base', remainging_hp, leader_protect_base_rating)
    end


    -- The first loop simply does a weighted sum of the individual unit ratings.
    -- It is done no matter which type of holding we're evaluation.
    -- Combos that leave adjacent villages exposed are disqualified.
    local valid_combos, weights = {}, {}
    for i_c,combo in ipairs(combos) do
        --print('combo ' .. i_c)
        local base_rating = 0
        local is_dqed = false

        local cum_weight, count = 0, 0
        for src,dst in pairs(combo) do
            local id = ratings[dst][src].id

            -- Prefer tanks, i.e. the highest-HP units
            local weight
            if (not weights[id]) then
                weight = gamedata.unit_infos[id].hitpoints
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
            --print(x, y, adj_vill_xy)
            if adj_vill_xy then
                is_dqed = true
                for _,tmp_dst in pairs(combo) do
                    if (adj_vill_xy == tmp_dst) then
                        is_dqed = false
                        break
                    end
                end
                --print('  is_dqed', x, y, is_dqed)

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
    --print('#valid_combos: ' .. #valid_combos .. '/' .. #combos)

    table.sort(valid_combos, function(a, b) return a.base_rating > b.base_rating end)
    --DBG.dbms(valid_combos)


    -- This loop does two things:
    -- 1. Check whether a combo protects the locations it is supposed to protect.
    -- 2. Rate the combos based on the shape of the formation and its orientation
    --    with respect to the direction in which the enemies are approaching.
    local good_combos = {}
    local tmp_max_rating, tmp_all_max_rating -- just for debug display purposes
    for i_c,combo in ipairs(valid_combos) do
        -- 1. Check whether a combo protects the locations it is supposed to protect.
        local is_protected = true
        local leader_protect_mult = 0
        if cfg and cfg.protect_locs then
            if cfg.protect_leader then
                -- For the leader, we check whether it is better protected by the combo
                local leader_target = {}
                leader_target[leader_id] = { gamedata.leader_x, gamedata.leader_y }
                local old_locs = { { gamedata.leader_x, gamedata.leader_y } }
                local new_locs = { { gamedata.leader_x, gamedata.leader_y } }

                for src,dst in pairs(combo) do
                    local dst_x, dst_y =  math.floor(dst / 1000), dst % 1000
                    local src_x, src_y =  math.floor(src / 1000), src % 1000
                    table.insert(old_locs, { src_x, src_y })
                    table.insert(new_locs, { dst_x, dst_y })
                end

                local counter_outcomes = FAU.calc_counter_attack(
                    leader_target, old_locs, new_locs, gamedata, move_cache, cfg_attack
                )

                local remainging_hp = gamedata.unit_infos[leader_id].hitpoints
                if counter_outcomes then
                    remainging_hp = counter_outcomes.def_outcome.average_hp
                    remainging_hp = remainging_hp - counter_outcomes.def_outcome.poisoned * 8
                    remainging_hp = remainging_hp - counter_outcomes.def_outcome.slowed * 4
                    if (remainging_hp < 0) then remainging_hp = 0 end
                end

                local leader_protect_rating = remainging_hp / gamedata.unit_infos[leader_id].max_hitpoints

                -- Plus chance of survival
                leader_protect_rating = leader_protect_rating + 1
                if counter_outcomes then
                    leader_protect_rating = leader_protect_rating - counter_outcomes.def_outcome.hp_chance[0]
                    --print('  ' .. counter_outcomes.def_outcome.hp_chance[0])
                end

                leader_protect_rating = 1 + leader_protect_rating / 2
                leader_protect_mult = leader_protect_rating / leader_protect_base_rating
                --print(i_c, remainging_hp, leader_protect_rating, leader_protect_mult)

                if (leader_protect_mult < 1.001) then
                    is_protected = false
                end
            else
                -- For non-leader protect_locs, they must be unreachable by enemies
                -- to count as protected.

                -- For now, simply use the protect_loc with the largest forward distance
                -- TODO: think about how to deal with several simultaneously
                local max_ld, loc
                for _,protect_loc in ipairs(cfg.protect_locs) do
                    local ld = FU.get_fgumap_value(gamedata.leader_distance_map, protect_loc[1], protect_loc[2], 'distance')
                    if (not max_ld) or (ld > max_ld) then
                        max_ld = ld
                        loc = protect_loc
                    end
                end
                --print('*** need to check protection of ' .. loc[1] .. ',' .. loc[2])

                -- First check (because it's quick): if there is a unit on the hex to be protected
                is_protected = false
                for src,dst in pairs(combo.combo) do
                    local x, y =  math.floor(dst / 1000), dst % 1000
                    --print('  ' .. x , y)

                    if (x == loc[1]) and (y == loc[2]) then
                        --print('    --> protected by having unit on hex')
                        is_protected = true
                        break
                    end
                end

                -- If that did not find anything, do path finding
                if (not is_protected) then
                    --print('combo ' .. i_c, loc[1], loc[2])
                    for src,dst in pairs(combo.combo) do
                        local id = ratings[dst][src].id
                        local x, y =  math.floor(dst / 1000), dst % 1000
                        --print(id, src, x,y, gamedata.unit_copies[id].x, gamedata.unit_copies[id].y)

                        wesnoth.put_unit(x, y, gamedata.unit_copies[id])
                    end

                    local can_reach = false
                    for enemy_id,_ in pairs(gamedata.enemies) do
                        local moves_left = FU.get_fgumap_value(gamedata.reach_maps[enemy_id], loc[1], loc[2], 'moves_left')
                        if moves_left then
                            --print('  ' .. enemy_id, moves_left)
                            local _, cost = wesnoth.find_path(gamedata.unit_copies[enemy_id], loc[1], loc[2])
                            --print('  cost: ', cost)

                            if (cost <= gamedata.unit_infos[enemy_id].max_moves) then
                                --print('    can reach this!')
                                can_reach = true
                                break
                            end
                        end
                    end

                    for src,dst in pairs(combo.combo) do
                        local id = ratings[dst][src].id
                        local x, y =  math.floor(dst / 1000), dst % 1000

                        wesnoth.extract_unit(gamedata.unit_copies[id])

                        local src_x, src_y =  math.floor(src / 1000), src % 1000
                        gamedata.unit_copies[id].x, gamedata.unit_copies[id].y = src_x, src_y


                        --print('  ' .. id, src, x,y, gamedata.unit_copies[id].x, gamedata.unit_copies[id].y)
                    end

                    if (not can_reach) then
                        is_protected = true
                    end
                end
            end
        else
            -- If there are no locations to be protected, count hold as protecting by default
        end
        --print('is_protected', is_protected)


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
                        local d = H.distance_between(x2, y2, x, y)
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
                    dist = FU.get_fgumap_value(between_map, x, y, 'blurred_distance')
                    perp_dist = FU.get_fgumap_value(between_map, x, y, 'blurred_perp_distance')
                else
                    -- In this case we do not have the perpendicular distance
                    dist = FU.get_fgumap_value(gamedata.leader_distance_map, x, y, 'distance')
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
                    local d1 = H.distance_between(dist.x, dist.y, extremes.x, extremes.y)
                    local d2 = H.distance_between(dist.x, dist.y, extremes.x2, extremes.y2)
                    --print(dist.x, dist.y, d1, d2, d1 - d2)
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
                    angle = math.atan2(dx, dy) / 1.5708
                else
                    local dr = H.distance_between(dists[i_h + 1].x, dists[i_h + 1].y, dists[i_h].x, dists[i_h].y)
                    -- Note, this must be y/r, not x/r!  We want the angle from the toward-leader direction
                    if (dy > dr) then
                        angle = 0
                    else
                        angle = math.acos(dy / dr) / 1.5708
                    end
                end
                --print(i_h, angle)

                if (not min_angle) or (angle < min_angle) then
                    min_angle = angle
                end
            end

            -- TODO: this might undervalue combinations incl. adjacent hexes
            local scaled_angle = FU.weight_s(min_angle, 0.5)
            -- Make this a 20% maximum range effect
            angle_fac = (1 + scaled_angle / 5)
            --print('  -> min_angle: ' .. min_angle, scaled_angle, angle_fac)

            formation_rating = formation_rating * angle_fac

            -- Penalty for too far apart
            local thresh_dist = 3
            if cfg.protect_leader then thresh_dist = 2 end
            if (max_min_dist > thresh_dist) then
                dist_fac = 1 / ( 1 + (max_min_dist - thresh_dist) / 10)
                formation_rating = formation_rating * dist_fac
            end
        end
        --print('  formation_rating 2:', formation_rating)

        if cfg.protect_leader then
            formation_rating = formation_rating * leader_protect_mult
            --print(i_c, formation_rating, leader_protect_mult, formation_rating / leader_protect_mult)
        end

        table.insert(good_combos, {
            formation_rating = formation_rating,
            combo = combo.combo,
            is_protected = is_protected
        })

        if false then
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
            local x, y
            for src,dst in pairs(combo.combo) do
                x, y =  math.floor(dst / 1000), dst % 1000
                W.label { x = x, y = y, text = ratings[dst][src].id }
            end
            wesnoth.scroll_to_tile(x, y)
            local rating_str =  string.format("%.4f = %.4f x %.4f x %.4f", formation_rating, angle_fac or -1111, dist_fac or -2222, combo.base_rating or -9999)
            local max_str = string.format("max:  protected: %.4f,  all: %.4f", tmp_max_rating, tmp_all_max_rating)
            W.message {
                speaker = 'narrator', caption = 'Combo ' .. i_c .. '/' .. #valid_combos .. ': formation_rating',
                message = rating_str .. '   is_protected = ' .. protected_str
                    .. '\n' .. max_str
            }
            for src,dst in pairs(combo.combo) do
                x, y =  math.floor(dst / 1000), dst % 1000
                W.label { x = x, y = y, text = "" }
            end
        end
    end
    --print('#good_combos: ' .. #good_combos .. '/' .. #valid_combos .. '/' .. #combos)

    table.sort(good_combos, function(a, b) return a.formation_rating > b.formation_rating end)
    --DBG.dbms(good_combos)


    -- Full counter attack analysis for the best combos
    local cfg_attack = {
        value_ratio = 1,
        use_max_damage_weapons = true
    }
    local max_n_combos, reduced_max_n_combos = 20, 50

    local max_rating, best_combo, all_max_rating, all_best_combo
    local reduced_max_rating, reduced_best_combo, reduced_all_max_rating, reduced_all_best_combo
    for i_c,combo in pairs(good_combos) do
        --print('combo ' .. i_c)

        local old_locs, new_locs, ids = {}, {}, {}
        for s,d in pairs(combo.combo) do
            local src =  { math.floor(s / 1000), s % 1000 }
            local dst =  { math.floor(d / 1000), d % 1000 }
            --print('  ' .. src[1] .. ',' .. src[2] .. '  -->  ' .. dst[1] .. ',' .. dst[2])

            table.insert(old_locs, src)
            table.insert(new_locs, dst)
            table.insert(ids, FU.get_fgumap_value(gamedata.my_unit_map, src[1], src[2], 'id'))
        end

        local counter_rating, rel_rating, count, full_count = 0, 0, 0, 0
        local remove_src = {}
        for i_l,loc in pairs(old_locs) do
            local target = {}
            target[ids[i_l]] = { new_locs[i_l][1], new_locs[i_l][2] }

            local counter_outcomes = FAU.calc_counter_attack(
                target, old_locs, new_locs, gamedata, move_cache, cfg_attack
            )
            if counter_outcomes then
                --DBG.dbms(counter_outcomes.rating_table)
                local unit_rating = - counter_outcomes.rating_table.rating

                local unit_value = FU.unit_value(gamedata.unit_infos[ids[i_l]])
                local unit_rel_rating = unit_rating / unit_value
                if (unit_rel_rating < 0) then
                    unit_rel_rating = - unit_rel_rating^2
                else
                    unit_rel_rating = unit_rel_rating^2
                end
                unit_rel_rating = 1 + unit_rel_rating / 5

                --print('  ' .. ids[i_l], unit_rating)
                --print('    ' .. unit_rel_rating, unit_value)
                rel_rating = rel_rating + unit_rel_rating
                count = count + 1
            else
                remove_src[old_locs[i_l][1] * 1000 + old_locs[i_l][2]] = true
            end

            full_count = full_count + 1
        end
        --print(i_c, count, full_count)

        if (count > 0) then
            rel_rating = rel_rating / count
            counter_rating = combo.formation_rating * rel_rating
            --print('  ---> ' .. combo.formation_rating, rel_rating, combo.formation_rating * rel_rating)

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
                    formation_rating = formation_rating,
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

        if false then
            local protected_str = 'no'
            if combo.is_protected then protected_str = 'yes' end
            for i_l,loc in pairs(new_locs) do
                W.label { x = loc[1], y = loc[2], text = ids[i_l] }
            end
            wesnoth.scroll_to_tile(new_locs[1][1], new_locs[1][2])

            local rating_str =  string.format("%.4f = %.4f x %.4f", counter_rating, rel_rating, combo.formation_rating)
            local max_str = string.format("max:  protected: %.4f,  all: %.4f", max_rating or -9999, all_max_rating or -9999)
            W.message {
                speaker = 'narrator', caption = 'Combo ' .. i_c .. '/' .. #valid_combos .. ': counter_rating',
                message = rating_str .. '   is_protected = ' .. protected_str
                    .. '\n' .. max_str
            }
            for i_l,loc in pairs(new_locs) do
                W.label { x = loc[1], y = loc[2], text = "" }
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

    --print(' ===> max rating:             ' .. (max_rating or 'none'))
    --print(' ===> max rating all: ' .. (all_max_rating or 'none'))

    return best_combo and best_combo.combo, all_best_combo and all_best_combo.combo
end


return fred_hold_utils
