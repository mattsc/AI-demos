local H = wesnoth.require "helper"
local AH = wesnoth.require "ai/lua/ai_helper.lua"
local FAU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack_utils.lua"
local FBU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_benefits_utilities.lua"
local FGM = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_map.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local FS = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_status.lua"
local FCFG = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_config.lua"
local FVS = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_virtual_state.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local fred_hold_utils = {}

function fred_hold_utils.convolve_rating_maps(rating_maps, key, between_map, ops_data)
    local count = 0
    for id,_ in pairs(rating_maps) do
        count = count + 1
    end

    if (count == 1) then
        for id,rating_map in pairs(rating_maps) do
            for _,_,data in FGM.iter(rating_map) do
                data.conv = 1
                data[key] = data[key .. '_org']
            end
        end

        return
    end

    for id,rating_map in pairs(rating_maps) do
        for x,y,_ in FGM.iter(rating_map) do
            local dist, perp_dist
            if between_map then
                dist = FGM.get_value(between_map, x, y, 'blurred_distance') or -999
                perp_dist = FGM.get_value(between_map, x, y, 'blurred_perp_distance') or 0
            else
                -- In this case we do not have the perpendicular distance
                dist = FGM.get_value(ops_data.leader_distance_map, x, y, 'distance')
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
                                dist2 = FGM.get_value(between_map, x2, y2, 'blurred_distance') or -999
                                perp_dist2 = FGM.get_value(between_map, x2, y2, 'blurred_perp_distance') or 0
                            else
                                dist2 = FGM.get_value(ops_data.leader_distance_map, x2, y2, 'distance') or -999
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
                                    local pr = FGM.get_value(rating_map2, x2, y2, key ..'_org')
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

            FGM.set_value(rating_map, x, y, 'conv', conv)
        end

        FGM.normalize(rating_map, 'conv')
        for _,_,data in FGM.iter(rating_map) do
            -- It is possible for this value to be zero if no other units
            -- can get to surrounding hexes. While it is okay to derate this
            -- hex then, it should not be set to zero
            local conv = data.conv
            if (conv < 0.5) then conv = 0.5 end
            data[key] = data[key .. '_org'] * conv
        end
    end
end


function fred_hold_utils.check_hold_protection(combo, protection, cfg, fred_data)
    local move_data = fred_data.move_data
    local leader_id = move_data.leaders[wesnoth.current.side].id
    local leader_value = FU.unit_value(move_data.unit_infos[leader_id])

    local leader_protected, leader_protect_mult = false, 1

    -- The leader is never part of the holding, so we can just add him
    local old_locs = { { move_data.leader_x, move_data.leader_y } }
    local new_locs = { protection.overall.leader_goal }
    for src,dst in pairs(combo) do
        local dst_x, dst_y =  math.floor(dst / 1000), dst % 1000
        local src_x, src_y =  math.floor(src / 1000), src % 1000
        table.insert(old_locs, { src_x, src_y })
        table.insert(new_locs, { dst_x, dst_y })
    end

    FVS.set_virtual_state(old_locs, new_locs, fred_data.ops_data.place_holders, false, move_data)
    local status = FS.check_exposures(fred_data.ops_data.objectives, combo, nil, { zone_id = cfg.zone_id }, fred_data)
    FVS.reset_state(old_locs, new_locs, false, move_data)
    --DBG.dbms(status, false, 'status')


    if cfg.protect_objectives.protect_leader and (not protection.overall.leader_already_protected) then
        -- For the leader, we check whether it is sufficiently protected by the combo
        --std_print('leader eposure before - after: ', protection.overall.org_status.leader.exposure .. ' - ' .. status.leader.exposure)

        if (status.leader.exposure < protection.overall.leader_min_exposure) then
            leader_min_exposure = status.leader.exposure
            leader_min_enemy_power = status.leader.enemy_power
        end

        leader_protect_mult = (leader_value - status.leader.exposure) / leader_value
        -- It's possible for the number above to be slightly below zero, and
        -- we probably don't want quite as strong an effect anyway, so:
        leader_protect_mult = 0.5 + leader_protect_mult / 2

        protection.combo.protected_value = protection.combo.protected_value + 1.5 * (protection.overall.org_status.leader.exposure - status.leader.exposure)

        leader_protected = not status.leader.is_significant_threat
        --std_print('  --> leader_protect_mult, leader_protected: ' .. leader_protect_mult, leader_protected)

        protection.combo.protect_loc_str = (protection.combo.protect_loc_str or '') .. '    leader: ' .. tostring(leader_protected)
    end


    local n_castles_threatened = protection.overall.org_status.castles.n_threatened
    local n_castles_protected = 0
    if (n_castles_threatened > 0) then
        n_castles_protected = n_castles_threatened - status.castles.n_threatened
        --std_print('n_castles_protected: ', n_castles_protected, status.castles.n_threatened, n_castles_threatened)
        protection.combo.protect_loc_str = (protection.combo.protect_loc_str or '') .. '    castles: ' .. tostring(n_castles_protected) .. '/' .. tostring(n_castles_threatened)
    end


    local protected_villages = {}
    if cfg.protect_objectives.villages then
        --DBG.dbms(cfg.protect_objectives.villages, false, 'cfg.protect_objectives.villages')
        -- For non-leader protect_locs, they must be unreachable by enemies
        -- to count as protected.

        for _,village in ipairs(cfg.protect_objectives.villages) do
            --std_print('  check protection of village: ' .. village.x .. ',' .. village.y)
            local xy = 1000 * village.x + village.y
            if status.villages[xy].is_protected then
                table.insert(protected_villages, {
                    x = village.x, y = village.y,
                    raw_benefit = village.raw_benefit
                })
            end

            protection.combo.protect_loc_str = (protection.combo.protect_loc_str or '') .. '    vill ' .. village.x .. ',' .. village.y .. ': ' .. tostring(status.villages[xy].is_protected)
        end
    end
    --DBG.dbms(protected_villages, false, 'protected_villages')


    local protected_units = {}
    if cfg.protect_objectives.units then
        --DBG.dbms(cfg.protect_objectives.villages, false, 'cfg.protect_objectives.villages')
        -- For non-leader protect_locs, they must be unreachable by enemies
        -- to count as protected.

        for _,unit in ipairs(cfg.protect_objectives.units) do
            local unit_rating  = status.units[unit.id].exposure
            --std_print(unit.id, unit_rating, org_status.units[unit.id].exposure)

            protected_units[unit.id] = protection.overall.org_status.units[unit.id].exposure - unit_rating
            protection.combo.protect_loc_str = (protection.combo.protect_loc_str or '') .. string.format('    unit %d,%d: %.2f', unit.x, unit.y, protected_units[unit.id] or 0)
        end
    end
    --DBG.dbms(protected_units, false, 'protected_units')


    -- Now combine all the contributions
    -- Note that everything is divided by the leader value, in order to make things comparable
    -- TODO: is this the right thing to do?
    local village_protect_mult = 1
    for _,village in ipairs(protected_villages) do
        -- Benefit here is always 6, as it is difference between Fred and enemy holding the village
        village_protect_mult = village_protect_mult + 6 / leader_value / 4
        -- TODO: Add in enemy healing benefit here?
        protection.combo.protected_value = protection.combo.protected_value + 6
    end
    local unit_protect_mult = 1
    for _,unit in pairs(protected_units) do
        unit_protect_mult = unit_protect_mult + unit / leader_value / 4
        protection.combo.protected_value = protection.combo.protected_value + unit
    end
    local castle_protect_mult = 1 + math.sqrt(n_castles_protected) * 3 / leader_value / 4
    protection.combo.protected_value = protection.combo.protected_value + math.sqrt(n_castles_protected) * 3

    protection.combo.protect_mult = leader_protect_mult * village_protect_mult * unit_protect_mult * castle_protect_mult
    --std_print('protect_mult ( = l * v * u * c)', protection.combo.protect_mult, leader_protect_mult, village_protect_mult, unit_protect_mult, castle_protect_mult)
    --std_print('protected_value: ' .. protection.combo.protected_value)

    if cfg.protect_objectives.protect_leader and (not protection.overall.leader_already_protected) then
        protection.combo.does_protect = leader_protected
    elseif (n_castles_threatened > 0) then
        protection.combo.does_protect = (n_castles_protected > 0)
    else
        -- Currently we count this as a protecting hold if any of the villages is protected ...
        if (#cfg.protect_objectives.villages > 0) then
            if (#protected_villages > 0) then
                protection.combo.does_protect = true
            end
        end

        -- ... or if any of the units is protected with a rating of 3 or higher (equivalent to basic village protection)
        -- TODO: should this be a variable value?
        if (#cfg.protect_objectives.units > 0) then
            for _,unit_protection in pairs(protected_units) do
                if (unit_protection >= 3) then
                    protection.combo.does_protect = true
                    break
                end
            end
        end
    end

    protection.combo.terrain = status.terrain
end


function fred_hold_utils.unit_rating_maps_to_dstsrc(unit_rating_maps, key, move_data, cfg)
    -- It's assumed that all individual unit_rating maps contain at least one rating

    local max_units = (cfg and cfg.max_units) or 3 -- number of units to be used per combo
    local max_hexes = (cfg and cfg.max_hexes) or 6 -- number of hexes per unit for placement combos


    -- First, set up sorted arrays for each unit
    local sorted_ratings = {}
    for id,unit_rating_map in pairs(unit_rating_maps) do
        sorted_ratings[id] = {}
        for _,_,data in FGM.iter(unit_rating_map) do
            table.insert(sorted_ratings[id], data)
        end
        table.sort(sorted_ratings[id], function(a, b) return a[key] > b[key] end)
    end
    --DBG.dbms(sorted_ratings, false, 'sorted_ratings')


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
    --DBG.dbms(best_units, false, 'best_units')


    -- Units to be used
    local n_units = math.min(max_units, #best_units)
    local use_units = {}
    for i = 1,n_units do use_units[i] = best_units[i] end
    --DBG.dbms(use_units, false, 'use_units')


    -- Show the units and hexes to be used
    if DBG.show_debug('hold_best_units_hexes') then
        for _,unit in ipairs(use_units) do
            local tmp_map = {}
            local count = math.min(max_hexes, #sorted_ratings[unit.id])
            for i = 1,count do
                FGM.set_value(tmp_map, sorted_ratings[unit.id][i].x, sorted_ratings[unit.id][i].y, 'rating', sorted_ratings[unit.id][i].protect_rating or sorted_ratings[unit.id][i].vuln_rating)
            end
            DBG.show_fgumap_with_message(tmp_map, 'rating', 'Best rating', move_data.unit_copies[unit.id])
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
    --DBG.dbms(ratings, false, 'ratings')

    local dst_src = {}
    for dst,srcs in pairs(ratings) do
        local tmp = { dst = dst }
        for src,_ in pairs(srcs) do
            table.insert(tmp, { src = src })
        end
        table.insert(dst_src, tmp)
    end
    --DBG.dbms(dst_src, false, 'dst_src')

    return dst_src, ratings
end


function fred_hold_utils.get_base_rating(combo, ratings, weights, key, penalty_infos, adjacent_village_map, fred_data)
    local move_data = fred_data.move_data
    local leader_id = move_data.leaders[wesnoth.current.side].id
    local leader_info = move_data.unit_infos[leader_id]
    local leader_value = FU.unit_value(move_data.unit_infos[leader_id])
    local interactions = fred_data.ops_data.interaction_matrix.penalties['hold']
    local reserved_actions = fred_data.ops_data.reserved_actions

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
        local adj_vill_xy = FGM.get_value(adjacent_village_map, x, y, 'village_xy')
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

    local valid_combo
    if (not is_dqed) then
        -- Penalty for units and/or hexes planned to be used otherwise
        local actions = {}
        for src,dst in pairs(combo) do
            if (not penalty_infos.src[src]) then
                local x, y = math.floor(src / 1000), src % 1000
                penalty_infos.src[src] = FGM.get_value(move_data.unit_map, x, y, 'id')
            end
            if (not penalty_infos.dst[dst]) then
                penalty_infos.dst[dst] = { math.floor(dst / 1000), dst % 1000 }
            end
            local action = { id = penalty_infos.src[src], loc = penalty_infos.dst[dst] }
            table.insert(actions, action)
        end
        --DBG.dbms(actions, false, 'actions')
        --DBG.dbms(penalty_infos, false, 'penalty_infos')

        -- TODO: does this work? does it work for both hold and protect?
        local penalty_rating, penalty_str = FBU.action_penalty(actions, reserved_actions, interactions, move_data)
        penalty_rating = (leader_value + penalty_rating) / leader_value
        penalty_rating = 0.5 + penalty_rating / 2
        --std_print('penalty combo #' .. i_c, penalty_rating, penalty_str)

        base_rating = base_rating / cum_weight * count * penalty_rating
        valid_combo = {
            combo = combo,
            base_rating = base_rating,
            penalty_rating = penalty_rating,
            penalty_str = penalty_str,
            count = count
        }
    end

    return valid_combo, is_dqed
end


function fred_hold_utils.find_best_combo(combos, ratings, key, adjacent_village_map, between_map, fred_data, cfg)
    local move_data = fred_data.move_data
    local leader_id = move_data.leaders[wesnoth.current.side].id
    local leader_info = move_data.unit_infos[leader_id]
    local leader_value = FU.unit_value(move_data.unit_infos[leader_id])

    local value_ratio = cfg.value_ratio
    local hold_counter_weight = FCFG.get_cfg_parm('hold_counter_weight')
    local cfg_attack = { value_ratio = value_ratio }

    local penalty_infos = { src = {}, dst = {} }

    -- The first loop simply does a weighted sum of the individual unit ratings.
    -- It is done no matter which type of holding we're evaluation.
    -- Combos that leave adjacent villages exposed are disqualified.
    local valid_combos, weights = {}, {}
    for i_c,combo in ipairs(combos) do
        --std_print('combo ' .. i_c)

        local valid_combo, is_dqed = fred_hold_utils.get_base_rating(combo, ratings, weights, key, penalty_infos, adjacent_village_map, fred_data)

        if (not is_dqed) then
            table.insert(valid_combos, valid_combo)

            if DBG.show_debug('hold_combo_base_rating') then
                local leader_goal = fred_data.ops_data.objectives.leader.final
                local x, y
                for _,unit in ipairs(fred_data.ops_data.place_holders) do
                    wesnoth.wml_actions.label { x = unit[1], y = unit[2], text = 'recruit\n' .. unit.type, color = '160,160,160' }
                end
                wesnoth.wml_actions.label { x = leader_goal[1], y = leader_goal[2], text = 'leader goal', color = '200,0,0' }
                for src,dst in pairs(combo) do
                    x, y =  math.floor(dst / 1000), dst % 1000
                    wesnoth.wml_actions.label { x = x, y = y, text = ratings[dst][src].id }
                end

                wesnoth.scroll_to_tile(x, y)
                local rating_str =  string.format("%.4f\npenalty_rating: %.4f    %s",
                    valid_combo.base_rating, valid_combo.penalty_rating, valid_combo.penalty_str
                )
                wesnoth.wml_actions.message {
                    speaker = 'narrator', caption = 'Valid combo ' .. i_c .. '/' .. #combos .. ': base_rating [' .. cfg.zone_id .. ']',
                    message = rating_str
                }
                for src,dst in pairs(combo) do
                    x, y =  math.floor(dst / 1000), dst % 1000
                    wesnoth.wml_actions.label { x = x, y = y, text = "" }
                end
                wesnoth.wml_actions.label { x = leader_goal[1], y = leader_goal[2], text = "" }
                for _,unit in ipairs(fred_data.ops_data.place_holders) do
                    wesnoth.wml_actions.label { x = unit[1], y = unit[2], text = "" }
                end
            end
        end
    end
    --std_print('#valid_combos: ' .. #valid_combos .. '/' .. #combos)

    table.sort(valid_combos, function(a, b) return a.base_rating > b.base_rating end)
    --DBG.dbms(valid_combos, false, 'valid_combos')


    -- This loop does two things:
    -- 1. Check whether a combo protects the locations it is supposed to protect.
    -- 2. Rate the combos based on the shape of the formation and its orientation
    --    with respect to the direction in which the enemies are approaching.
    local protection = { overall = {
        leader_min_exposure = math.huge,
        leader_min_enemy_power = 0,
        org_status = fred_data.ops_data.status,
        leader_already_protected = fred_data.ops_data.status.leader.is_protected,
        leader_goal = fred_data.ops_data.objectives.leader.final
    } }

    if cfg and cfg.protect_objectives then
        if cfg.protect_objectives.protect_leader and (not protection.overall.leader_already_protected) then
            protection.overall.protect_obj_str = 'leader'
        elseif (protection.overall.org_status.castles.n_threatened > 0) then
            protection.overall.protect_obj_str = 'castle'
        else
            if (#cfg.protect_objectives.villages > 0) then
                protection.overall.protect_obj_str = 'village'
            end
            if (#cfg.protect_objectives.units > 0) then
                if protection.overall.protect_obj_str then
                    protection.overall.protect_obj_str = protection.overall.protect_obj_str .. '+unit'
                else
                    protection.overall.protect_obj_str = 'unit'
                end
            end
        end
    else
        protection.overall.protect_obj_str = 'no protect objectives'
    end
    --std_print('leader_already_protected', protection.overall.leader_already_protected)
    --DBG.dbms(protection.overall.org_status, false, 'protection.overall.org_status')


    local good_combos = {}
    local analyze_all_combos = false
    local tmp_max_rating, tmp_all_max_rating -- just for debug display purposes
    for i_c,combo in ipairs(valid_combos) do
        -- 1. Check whether a combo protects the locations it is supposed to protect.
        protection.combo = {
            does_protect = false,
            comment = '',
            protect_mult = 1,
            protected_value = 0,
        }

        if cfg and cfg.protect_objectives then
            --DBG.dbms(protection, false, 'protection')
            fred_hold_utils.check_hold_protection(combo.combo, protection, cfg, fred_data)
            --DBG.dbms(protection.combo, false, 'protection.combo')
            --DBG.dbms(protection, false, 'protection')

            -- Check whether same protection can be achieved with fewer units
            if protection.combo.does_protect and (combo.count > 1) then
                local reduced_protection = { overall = {
                    protect_obj_str = protection.overall.protect_obj_str,
                    leader_min_exposure = math.huge,
                    leader_min_enemy_power = 0,
                    org_status = fred_data.ops_data.status,
                    leader_already_protected = fred_data.ops_data.status.leader.is_protected,
                    leader_goal = fred_data.ops_data.objectives.leader.final
                } }

                for src,dst in pairs(combo.combo) do
                    local reduced_combo = {}
                    for src2,dst2 in pairs(combo.combo) do
                        if (src ~= src2) then
                            reduced_combo[src2] = dst2
                        end
                    end
                    --DBG.dbms(combo, false, 'combo')
                    --DBG.dbms(reduced_combo, false, 'reduced_combo')

                    reduced_protection.combo = {
                        does_protect = false,
                        protect_mult = 1,
                        protected_value = 0,
                    }
                    fred_hold_utils.check_hold_protection(reduced_combo, reduced_protection, cfg, fred_data)
                    --DBG.dbms(protection.combo, false, 'protection.combo')
                    --DBG.dbms(reduced_protection.combo, false, 'reduced_protection.combo')

                    -- If there is no additional protected value and there is no terrain advantage
                    if ((reduced_protection.combo.protected_value / protection.combo.protected_value) > 0.999)
                        and ((reduced_protection.combo.terrain - protection.combo.terrain) > - 0.001)
                    then
                        --std_print('****** reduced combo just as good *****')
                        -- Rate this combo as useless:
                        protection.combo.protect_mult = 0
                        protection.combo.comment = ' -- uses unnecessary units'
                        analyze_all_combos = true

                        -- Now make sure that the reduced combo exists in the list of valid combos
                        local i_reduced_combo = -1
                        for i_c2,combo2 in ipairs(valid_combos) do
                            local is_same_combo = false
                            if (combo.count - 1 == combo2.count) then
                                is_same_combo = true
                                for red_src,red_dst in pairs(reduced_combo) do
                                    if (not combo2.combo[red_src]) or (combo2.combo[red_src] ~= red_dst) then
                                        is_same_combo = false
                                        break
                                    end
                                end
                                --std_print(i_c, i_c2, is_same_combo)
                                if is_same_combo then
                                    --DBG.dbms(combo2, false, 'combo2')
                                    i_reduced_combo = i_c2
                                    break
                                end
                            end
                        end
                        if (i_reduced_combo > -1) then
                            --std_print('i_reduced_combo : ' .. i_reduced_combo)
                        else
                            -- By passing {} for adjacent_villages_map, the combo will not get DQed
                            local valid_combo, is_dqed = fred_hold_utils.get_base_rating(reduced_combo, ratings, weights, key, penalty_infos, {}, fred_data)

                            if (not valid_combo) then
                                DBG.dbms(combo, false, 'combo')
                                DBG.dbms(reduced_combo, false, 'reduced_combo')
                                error('reduced combo does not exist and could not be created')
                            end

                            -- This appends the combo to the array that we are currently looping over
                            table.insert(valid_combos, valid_combo)
                        end
                    end
                end
            end
        else
            -- If there are no locations to be protected, count hold as not protecting by default
            -- does_protect = false, but
            -- protect_mult = 1
        end
        --std_print('does_protect', protection.combo.does_protect, protection.combo.protect_mult, protection.overall.protect_obj_str, protection.combo.protected_value, protection.combo.comment)


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
                    dist = FGM.get_value(between_map, x, y, 'blurred_distance') or -999
                    perp_dist = FGM.get_value(between_map, x, y, 'blurred_perp_distance') or 0
                else
                    -- In this case we do not have the perpendicular distance
                    dist = FGM.get_value(fred_data.ops_data.leader_distance_map, x, y, 'distance')
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
            --DBG.dbms(dists, false, 'dists')

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
            if cfg.protect_objectives and cfg.protect_objectives.protect_leader then thresh_dist = 2 end
            if (max_min_dist > thresh_dist) then
                dist_fac = 1 / ( 1 + (max_min_dist - thresh_dist) / 10)
                formation_rating = formation_rating * dist_fac
            end
        end
        --std_print('  formation_rating 2:', formation_rating)

        formation_rating = formation_rating * protection.combo.protect_mult
        --std_print(i_c, formation_rating, protection.combo.protect_mult, formation_rating / protection.combo.protect_mult)

        local protected_str = 'does_protect = no (' .. protection.overall.protect_obj_str .. ')' .. protection.combo.comment
        if protection.combo.does_protect then
            protected_str = 'does_protect = yes (' .. protection.overall.protect_obj_str .. ')' .. protection.combo.comment end
        if protection.combo.protect_loc_str then
            protected_str = protected_str .. '\n    protecting:' .. protection.combo.protect_loc_str
        end

        table.insert(good_combos, {
            formation_rating = formation_rating,
            combo = combo.combo,
            does_protect = protection.combo.does_protect,
            protected_str = protected_str,
            protected_value = protection.combo.protected_value,
            penalty_rating = combo.penalty_rating,
            penalty_str = combo.penalty_str
        })

        if DBG.show_debug('hold_combo_formation_rating') then
            if (not tmp_all_max_rating) or (formation_rating > tmp_all_max_rating) then
                tmp_all_max_rating = formation_rating
            end
            if protection.combo.does_protect then
                if (not tmp_max_rating) or (formation_rating > tmp_max_rating) then
                    tmp_max_rating = formation_rating
                end
            end

            local leader_goal = protection.overall.leader_goal
            local x, y
            for _,unit in ipairs(fred_data.ops_data.place_holders) do
                wesnoth.wml_actions.label { x = unit[1], y = unit[2], text = 'recruit\n' .. unit.type, color = '160,160,160' }
            end
            wesnoth.wml_actions.label { x = leader_goal[1], y = leader_goal[2], text = 'leader goal', color = '200,0,0' }
            for src,dst in pairs(combo.combo) do
                x, y =  math.floor(dst / 1000), dst % 1000
                wesnoth.wml_actions.label { x = x, y = y, text = ratings[dst][src].id }
            end

            wesnoth.scroll_to_tile(x, y)
            local rating_str =  string.format("%.4f = %.3f x %.3f x %.3f x %.3f    (protect x angle x dist x base)\npenalty_rating: %.4f    %s",
                formation_rating, protection.combo.protect_mult, angle_fac or 1, dist_fac or 1, combo.base_rating or -9999,
                combo.penalty_rating, combo.penalty_str
            )
            local max_str = string.format("max:  protected: %.4f,  all: %.4f", tmp_max_rating or -9999, tmp_all_max_rating or -9999)
            wesnoth.wml_actions.message {
                speaker = 'narrator', caption = 'Combo ' .. i_c .. '/' .. #valid_combos .. ': formation_rating [' .. cfg.zone_id .. ']',
                message = rating_str .. '\n' .. protected_str
                    .. '\n' .. max_str
            }
            for src,dst in pairs(combo.combo) do
                x, y =  math.floor(dst / 1000), dst % 1000
                wesnoth.wml_actions.label { x = x, y = y, text = "" }
            end
            wesnoth.wml_actions.label { x = leader_goal[1], y = leader_goal[2], text = "" }
            for _,unit in ipairs(fred_data.ops_data.place_holders) do
                wesnoth.wml_actions.label { x = unit[1], y = unit[2], text = "" }
            end
        end
    end
    --std_print('#good_combos: ' .. #good_combos .. '/' .. #valid_combos .. '/' .. #combos)

    if cfg.find_best_protect_only then
        if (not protection.overall.org_status.leader.best_protection) then
            protection.overall.org_status.leader.best_protection = {}
        end
        if (protection.overall.leader_min_enemy_power == 0) then -- otherwise it could still be at 9e99
            protection.overall.leader_min_exposure = 0
        end
        protection.overall.org_status.leader.best_protection[cfg.zone_id] = {
            exposure = protection.overall.leader_min_exposure,
            zone_enemy_power = protection.overall.leader_min_enemy_power
        }
    end

    table.sort(good_combos, function(a, b) return a.formation_rating > b.formation_rating end)
    --DBG.dbms(good_combos, false, 'good_combos')

    -- Full counter attack analysis for the best combos, except when reduced combos were
    -- found to protect just as well.  In that case we need to check all combos, otherwise
    -- we could miss the best reduced combo.
    -- TODO: if this turns out to take too long, use a smarter way of dealing with this.
    local max_n_combos, reduced_max_n_combos = 20, 50
    if analyze_all_combos then
        max_n_combos, reduced_max_n_combos = math.huge, math.huge
    end

    -- Acceptable chance-to-die for non-protect forward holds
    local acceptable_ctd = 0.25
    if (value_ratio < 1) then
        acceptable_ctd = 0.25 + 0.75 * (1 / value_ratio - 1)
    end
    --std_print(cfg.forward_ratio, value_ratio, acceptable_ctd)

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
            table.insert(ids, FGM.get_value(move_data.my_unit_map, src[1], src[2], 'id'))
        end

        local counter_rating, rel_rating, count, full_count = 0, 0, 0, 0
        local remove_src = {}
        for i_l,loc in pairs(old_locs) do
            local target = {}
            target[ids[i_l]] = { new_locs[i_l][1], new_locs[i_l][2] }

            -- TODO: Use FVS here also?
            local counter_outcomes = FAU.calc_counter_attack(
                target, old_locs, new_locs, fred_data.ops_data.place_holders, nil, cfg_attack, move_data, fred_data.move_cache
            )
            if counter_outcomes then
                --DBG.dbms(counter_outcomes.rating_table, false, 'counter_outcomes.rating_table')
                -- If this does not protect the asset, we do not do it if the
                -- chance to die is too high.
                -- Only do this if position is in front of protect_loc

                -- If we are trying to protect something, check whether it is worth it
                if cfg and cfg.protect_objectives then
                    -- TODO: exclude extra_rating?
                    -- This already includes the value_ratio derating
                    -- Note that it is the counter rating, meaning that positive values are bad for Fred
                    local rating = counter_outcomes.rating_table.rating
                    local protected_value = combo.protected_value
                    local is_worth_it = (protected_value > rating)
                    --std_print(ids[i_l] .. ' protected_value: ' .. combo.protected_value .. ' > ' .. rating .. ' = ' .. tostring(is_worth_it))
                    --std_print('does_protect, is_worth_it: ' .. tostring(combo.does_protect) .. ', ' .. tostring(is_worth_it))

                    if (not is_worth_it) then
                        -- We cannot just remove this dst from this hold, as this would
                        -- change the threats to the other dsts. The entire combo needs
                        -- to be discarded.
                        --std_print('Not worth the protect value')
                        count = 0
                        break
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
                if combo.does_protect then
                    if (not max_rating) or (counter_rating > max_rating) then
                        max_rating = counter_rating
                        best_combo = combo
                        --DBG.dbms(best_combo, false, 'best_combo')
                    end
                end

                if (not all_max_rating) or (counter_rating > all_max_rating) then
                    all_max_rating = counter_rating
                    all_best_combo = combo
                    --DBG.dbms(all_best_combo, false, 'all_best_combo')
                end
            else
                local reduced_combo = {
                    combo = {},
                    formation_rating = combo.formation_rating,
                    does_protect = combo.does_protect,
                    protected_str = combo.protected_str
                }
                for src,dst in pairs(combo.combo) do
                    if (not remove_src[src]) then
                        reduced_combo.combo[src] = dst
                    end
                end

                if combo.does_protect then
                    if (not reduced_max_rating) or (counter_rating > reduced_max_rating) then
                        reduced_max_rating = counter_rating
                        reduced_best_combo = reduced_combo
                        --DBG.dbms(reduced_best_combo, false, 'reduced_best_combo')
                    end
                end
                if (not reduced_all_max_rating) or (counter_rating > reduced_all_max_rating) then
                    reduced_all_max_rating = counter_rating
                    reduced_all_best_combo = reduced_combo
                    --DBG.dbms(reduced_all_best_combo, false, 'reduced_all_best_combo')
                end
            end
        end

        if DBG.show_debug('hold_combo_counter_rating') then
            local leader_goal = protection.overall.leader_goal
            for _,unit in ipairs(fred_data.ops_data.place_holders) do
                wesnoth.wml_actions.label { x = unit[1], y = unit[2], text = 'recruit\n' .. unit.type, color = '160,160,160' }
            end
            wesnoth.wml_actions.label { x = leader_goal[1], y = leader_goal[2], text = 'leader goal', color = '200,0,0' }
            for i_l,loc in pairs(new_locs) do
                wesnoth.wml_actions.label { x = loc[1], y = loc[2], text = ids[i_l] }
            end
            wesnoth.scroll_to_tile(new_locs[1][1], new_locs[1][2])

            local rating_str =  string.format("%.4f = %.4f x %.4f\npenalty_rating: %.4f    %s",
                counter_rating, rel_rating, combo.formation_rating, combo.penalty_rating, combo.penalty_str
            )
            local max_str = string.format("max:  protected: %.4f,  all: %.4f", max_rating or -9999, all_max_rating or -9999)
            wesnoth.wml_actions.message {
                speaker = 'narrator', caption = 'Combo ' .. i_c .. '/' .. #valid_combos .. ': counter_rating [' .. cfg.zone_id .. ']',
                message = rating_str .. '\n' .. combo.protected_str
                    .. '\n' .. max_str
            }
            for i_l,loc in pairs(new_locs) do
                wesnoth.wml_actions.label { x = loc[1], y = loc[2], text = "" }
            end
            wesnoth.wml_actions.label { x = leader_goal[1], y = leader_goal[2], text = "" }
            for _,unit in ipairs(fred_data.ops_data.place_holders) do
                wesnoth.wml_actions.label { x = unit[1], y = unit[2], text = "" }
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

    local combo_strs = {
        protect_obj_str = protection.overall.protect_obj_str,
        protected_str = best_combo and best_combo.protected_str,
        all_protected_str = all_best_combo and all_best_combo.protected_str
    }
    --DBG.dbms(combo_strs, false, 'combo_strs')

    return best_combo and best_combo.combo, all_best_combo and all_best_combo.combo, combo_strs
end


return fred_hold_utils
