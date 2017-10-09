local H = wesnoth.require "lua/helper.lua"
local AH = wesnoth.require "ai/lua/ai_helper.lua"
local FAU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack_utils.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local W = H.set_wml_action_metatable {}
--local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local fred_hold_utils = {}

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

local function reachable_by_enemy(combo, ratings, gamedata)
    -- If one or several of the units are now not reachable by the enemy any more, remove them
    --print('--- Checking if reachable by enemy')

    for src,dst in pairs(combo) do
        local id = ratings[dst][src].id
        local x, y =  math.floor(dst / 1000), dst % 1000
        --print(id, src, x,y, gamedata.unit_copies[id].x, gamedata.unit_copies[id].y)

        wesnoth.put_unit(x, y, gamedata.unit_copies[id])
    end

    local out_of_reach = {}
    for src,dst in pairs(combo) do
        local id = ratings[dst][src].id
        local x, y =  math.floor(dst / 1000), dst % 1000
        --print(x,y)

        local can_reach = false
        for enemy_id,loc in pairs(gamedata.enemies) do
            local dist = H.distance_between(x, y, loc[1], loc[2])
            --print('  ' .. enemy_id, dist)

            if (dist <= gamedata.unit_infos[enemy_id].max_moves + 1) then
                --print('    ' .. enemy_id .. ' is close enough')

                local enemy_copy = gamedata.unit_copies[enemy_id]
                local old_moves = enemy_copy.moves
                enemy_copy.moves = enemy_copy.max_moves
                local reach = wesnoth.find_reach(enemy_copy)
                enemy_copy.moves = old_moves

                for _,r in ipairs(reach) do
                    local dist = H.distance_between(x, y, r[1], r[2])
                    if (dist == 1) then
                        can_reach = true
                        --print('      can still reach')
                        break
                    end
                end
            end

            -- No reason to keep trying if one enemy can get there
            if can_reach then break end
        end
        --print('  can_reach', can_reach)

        if (not can_reach) then
            table.insert(out_of_reach, src)
        end
    end

    for src,dst in pairs(combo) do
        local id = ratings[dst][src].id
        local x, y =  math.floor(dst / 1000), dst % 1000

        wesnoth.extract_unit(gamedata.unit_copies[id])

        local src_x, src_y =  math.floor(src / 1000), src % 1000
        gamedata.unit_copies[id].x, gamedata.unit_copies[id].y = src_x, src_y

        --print('  ' .. id, src, x,y, gamedata.unit_copies[id].x, gamedata.unit_copies[id].y)
    end

    for _,src in ipairs(out_of_reach) do
        combo[src] = nil
    end

    return combo
end


function fred_hold_utils.find_best_combo(combos, ratings, key, adjacent_village_map, between_map, gamedata, move_cache, cfg)
    -- This currently only returns a combo with the max number of units
    -- TODO: does this need to be ammended?

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


    local unprotected_max_rating, unprotected_best_combo
    local max_rating, best_combo
    local valid_combos = {}
    for i_c,combo in ipairs(combos) do
        --print('combo ' .. i_c)
        local rating = 0
        local is_dqed = false

        local cum_weight, count = 0, 0
        for src,dst in pairs(combo) do
            local id = ratings[dst][src].id

            -- We want the unit with the lowest HP to have the highest weight
            -- Also, additional weight for injured units
            local weight = 2 - gamedata.unit_infos[id].hitpoints / 100
            weight = weight + gamedata.unit_infos[id].max_hitpoints - gamedata.unit_infos[id].hitpoints
            if (weight < 0.5) then weight = 0.5 end


            rating = rating + ratings[dst][src][key] * weight
            cum_weight = cum_weight + weight
            count = count + 1

            local x, y =  math.floor(dst / 1000), dst % 1000


            -- If this is adjacent to a village that is not part of the combo, DQ this combo
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

        rating = rating / cum_weight * count

        --print(i_c, rating, is_dqed)

        if (not is_dqed) then
            table.insert(valid_combos, {
                combo = combo,
                rating = rating,
                count = count
            })
        end
    end

    table.sort(valid_combos, function(a, b) return a.rating > b.rating end)
    --DBG.dbms(valid_combos)


    for i_c,combo in ipairs(valid_combos) do
        local is_protected = true
        local leader_protect_mult = 0
        if cfg and cfg.protect_locs then
            if cfg.protect_leader then
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


                -- If that did not find anything, we do path_finding
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
        end
        --print('is_protected', is_protected)

        local rating = combo.rating
        --print('  weighted:', rating)

        if (combo.count > 1) then
            local min_min_dist, max_min_dist = 999, 0
            local min_ld, max_ld

            for src,dst in pairs(combo.combo) do
                local x, y =  math.floor(dst / 1000), dst % 1000

                local min_dist = 999
                for src2,dst2 in pairs(combo.combo) do
                    if (src2 ~= src) or (dst2 ~= dst) then
                        x2, y2 =  math.floor(dst2 / 1000), dst2 % 1000
                        local d = H.distance_between(x2, y2, x, y)
                        if (d < min_dist) then min_dist = d end
                    end
                end

                if (min_dist < min_min_dist) then min_min_dist = min_dist end
                if (min_dist > max_min_dist) then max_min_dist = min_dist end


                local ld
                if between_map then
                    ld = FU.get_fgumap_value(between_map, x, y, 'inv_cost')
                else
                    ld = FU.get_fgumap_value(gamedata.leader_distance_map, x, y, 'distance')
                end
                if (not min_ld) or (ld < min_ld) then min_ld = ld end
                if (not max_ld) or (ld > max_ld) then max_ld = ld end
            end


            -- Bonus for distance of 2 or 3
            if (not cfg.protect_leader) then
                if (min_min_dist >= 2) and (max_min_dist <= 3) then
                    rating = rating * 1.10

                    if (max_min_dist == 2) then
                        rating = rating + 0.0001
                    end
                end
            end

            local thresh_dist = 3
            if cfg.protect_leader then thresh_dist = 2 end

            -- Penalty for too far apart
            if (max_min_dist > thresh_dist) then
                rating = rating / ( 1 + (max_min_dist - 3) / 10)
            end


            -- and we reduce lining them up "vertically" too far apart, but only
            -- if the config parameter 'hold_perpendicular' is set
            -- This is usually set for protects, not for "normal" holding
            if cfg and cfg.hold_perpendicular then
                local dld = max_ld - min_ld
                if (dld > 2) then
                    rating = rating * math.sqrt( 1 - dld / 20)
                end
            end
        end

        if cfg.protect_leader then
            rating = rating * leader_protect_mult
            --print(i_c, rating, leader_protect_mult, rating / leader_protect_mult)
        end

       if (not unprotected_max_rating) or (rating > unprotected_max_rating) then
           unprotected_max_rating = rating
           unprotected_best_combo = combo
       end

       if is_protected then
           if (not max_rating) or (rating > max_rating) then
               max_rating = rating
               best_combo = combo
           end
       end


        if true then
            local protected_str = 'no'
            if is_protected then protected_str = 'yes' end
            local x, y
            for src,dst in pairs(combo.combo) do
                x, y =  math.floor(dst / 1000), dst % 1000
                W.label { x = x, y = y, text = ratings[dst][src].id }
            end
            wesnoth.scroll_to_tile(x, y)
            local rating_str = string.format("%.4f / %.4f (%.4f)", rating, max_rating, combo.rating or -9999)
            W.message {
                speaker = 'narrator',
                message = 'Hold combo ' .. i_c .. '/' .. #valid_combos .. ' rating = ' .. rating_str .. '   is_protected = ' .. protected_str
            }
            for src,dst in pairs(combo.combo) do
                x, y =  math.floor(dst / 1000), dst % 1000
                W.label { x = x, y = y, text = "" }
            end
        end
    end


            -- Display combo and rating, if desired
            if false then
                local protected_str = 'no'
                if is_protected then protected_str = 'yes' end
                local x, y
                for src,dst in pairs(combo) do
                    x, y =  math.floor(dst / 1000), dst % 1000
                    local id = ratings[dst][src].id
                    W.label { x = x, y = y, text = id }
                end
                wesnoth.scroll_to_tile(x, y)
                W.message {
                    speaker = 'narrator',
                    message = 'Hold combo ' .. i_c .. '/' .. #combos .. ' rating = ' .. rating .. ' is_protected = ' .. protected_str
                }
                for src,dst in pairs(combo) do
                    x, y =  math.floor(dst / 1000), dst % 1000
                    W.label { x = x, y = y, text = "" }
                end
            end
        end
    end

    if (best_combo) then
        local count = 0
        for src,dst in pairs(best_combo) do count = count + 1 end

        if (count > 1) then
            local best_combo = reachable_by_enemy(best_combo.combo, ratings, gamedata)
        end
    end
    if (unprotected_best_combo) then
        local count = 0
        for src,dst in pairs(unprotected_best_combo) do count = count + 1 end

        if (count > 1) then
            local unprotected_best_combo = reachable_by_enemy(unprotected_best_combo.combo, ratings, gamedata)
        end
    end

    --print(' ===> max rating:             ' .. (max_rating or 'none'))
    --print(' ===> max rating unprotected: ' .. (unprotected_max_rating or 'none'))

    return best_combo.combo, unprotected_best_combo.combo
end


return fred_hold_utils
