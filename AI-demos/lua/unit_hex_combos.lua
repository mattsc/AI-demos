local H = wesnoth.require "lua/helper.lua"
local AH = wesnoth.require "ai/lua/ai_helper.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local W = H.set_wml_action_metatable {}

local UHC = {}

function UHC.get_unit_hex_combos(dst_src)
    -- This is a function which recursively finds all combinations of distributing
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

    local all_combos, combo = {}, {}
    local num_hexes = #dst_src
    local hex = 0

    -- This is the recursive function adding units to each hex
    -- It is defined here so that we can use the variables above by closure
    local function add_combos()
        hex = hex + 1

        for _,ds in ipairs(dst_src[hex]) do
            if (not combo[ds.src]) then  -- If that unit has not been used yet, add it
                combo[ds.src] = dst_src[hex].dst

                if (hex < num_hexes) then
                    add_combos()
                else
                    local new_combo = {}
                    for k,v in pairs(combo) do new_combo[k] = v end
                    table.insert(all_combos, new_combo)
                end

                -- Remove this element from the table again
                combo[ds.src] = nil
            end
        end

        -- We need to call this once more, to account for the "no unit on this hex" case
        -- Yes, this is a code duplication (done so for simplicity and speed reasons)
        if (hex < num_hexes) then
            add_combos()
        else
            local new_combo = {}
            for k,v in pairs(combo) do new_combo[k] = v end
            table.insert(all_combos, new_combo)
        end

        hex = hex - 1
    end

    add_combos()

    -- The last combo is always the empty combo -> remove it
    all_combos[#all_combos] = nil

    return all_combos
end

local function make_dst_src(units, hexes)
    -- This functions determines which @units can reach which @hexes. It returns
    -- an array of the form usable by get_unit_hex_combos(dst_src) [see above]
    --
    -- We could be using location sets here also, but I prefer the 1000-based
    -- indices because they are easily human-readable. I don't think that the
    -- performance hit is noticeable.

    local dst_src_map = {}
    for _,unit in ipairs(units) do
        -- If the AI turns out to be slow, this could be pulled out to a higher
        -- level, to avoid calling it for each combination of hexes:
        local reach = wesnoth.find_reach(unit)

        for _,hex in ipairs(hexes) do
            for _,r in ipairs(reach) do
                if (r[1] == hex[1]) and (r[2] == hex[2]) then
                    --print(unit.id .. ' can reach ' .. r[1] .. ',' .. r[2])

                    dst = hex[1] * 1000 + hex[2]

                    if (not dst_src_map[dst]) then
                        dst_src_map[dst] = {
                            dst = dst,
                            { src = unit.x * 1000 + unit.y }
                        }
                    else
                        table.insert(dst_src_map[dst], { src = unit.x * 1000 + unit.y })
                    end

                    break
                end
            end
        end
    end

    -- Because of the way how the recursive function above works, we want this
    -- to be an array, not a map with dsts as keys
    local dst_src = {}
    for _,dst in pairs(dst_src_map) do
        table.insert(dst_src, dst)
    end

    return dst_src
end

local function get_best_combo(combos, min_units, cfg)
    -- TODO: This currently uses a specific rating function written for the
    -- Ashen Hearts campaign. Generalize to take rating function as an argument.
    --
    -- Rate a combination of units on goal hexes (for one row only)
    -- @min_units: minimum number of units needed to count as valid combo

    local hp_map = {}  -- Setting up hitpoint map for speed reasons
    local max_rating, best_combo
    for _,combo in ipairs(combos) do
        local n_hexes = 0
        for dst,src in pairs(combo) do
            n_hexes = n_hexes + 1
        end

        if (n_hexes >= min_units) then
            local rating = 0

            -- Find the hexes at the ends of the line; these get an additional
            -- bonus for units with high HP
            local end_hexes = {}
            local max_dst, min_dst = -1, 9e99
            for src,dst in pairs(combo) do
                -- Since dst is 1000*x+y, and we want to sort by x, we can simply
                -- compare the dst values directly. It will even work for vertical
                -- lines. Only requirement is that the line is straight then.
                if (dst > max_dst) then max_dst = dst end
                if (dst < min_dst) then min_dst = dst end
            end

            for src,dst in pairs(combo) do
                local dst_x, dst_y = math.floor(dst / 1000), dst % 1000

                -- Need to ensure a positive rating for each unit, so that combo
                -- with most units is chosen, even if min_units < #hexes
                rating = rating + 1000

                -- Rating is distance from goal hex
                -- and distance from x=goal_x line
                rating = rating - H.distance_between(dst_x, dst_y, goal_hex[1], goal_hex[2])
                rating = rating - math.abs(dst_x - cfg.goal_x)

                -- Also use HP rating; use strongest available units
                if (not hp_map[src]) then
                    local src_x, src_y = math.floor(src / 1000), src % 1000
                    local unit = wesnoth.get_unit(src_x, src_y)
                    hp_map[src] = unit.hitpoints
                end

                rating = rating + hp_map[src] / 100.

                -- Additional hp bonus for the edge hexes
                if (dst == min_dst) or (dst == max_dst) then
                    rating = rating + hp_map[src] / 100.
                end
            end
            --print('Combo #' .. _ .. ': ', rating)

            if (not max_rating) or (rating > max_rating) then
                max_rating = rating
                best_combo = combo
            end
        end
    end

    if best_combo then
        return best_combo, max_rating
    end
end


function UHC.unit_rating_maps_to_dstsrc(unit_rating_maps, key, gamedata, cfg)
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



function UHC.find_best_combo(combos, ratings, key, adjacent_village_map, gamedata, cfg)
    -- This currently only returns a combo with the max number of units
    -- TODO: does this need to be ammended?

    local unprotected_max_rating, unprotected_best_combo
    local max_rating, best_combo
    for i_c,combo in ipairs(combos) do
        --print('combo ' .. i_c)
        local rating = 0
        local count = 0
        local min_min_dist, max_min_dist = 999, 0
        local min_ld, max_ld
        local is_dqed = false

        local cum_weight = 0
        for src,dst in pairs(combo) do
            local id = ratings[dst][src].id

            -- We want the unit with the lowest HP to have the highest weight
            -- Also, additional weight for injured units
            local weight = 2 - gamedata.unit_infos[id].hitpoints / 100
            weight = weight + gamedata.unit_infos[id].max_hitpoints - gamedata.unit_infos[id].hitpoints
            if (weight < 0.5) then weight = 0.5 end


            rating = rating + ratings[dst][src][key] * weight
            count = count + 1
            cum_weight = cum_weight + weight

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

            local min_dist = 999
            for src2,dst2 in pairs(combo) do
                if (src2 ~= src) or (dst2 ~= dst) then
                    x2, y2 =  math.floor(dst2 / 1000), dst2 % 1000
                    local d = H.distance_between(x2, y2, x, y)
                    if (d < min_dist) then min_dist = d end
                end
            end

            if (min_dist < min_min_dist) then min_min_dist = min_dist end
            if (min_dist > max_min_dist) then max_min_dist = min_dist end

            local ld = FU.get_fgumap_value(gamedata.leader_distance_map, x, y, 'distance')
            if (not min_ld) or (ld < min_ld) then min_ld = ld end
            if (not max_ld) or (ld > max_ld) then max_ld = ld end
        end
        --print(i_c, is_dqed, count)

        local is_protected = true

        if (not is_dqed) and cfg and cfg.protect_locs then
            local loc = cfg.protect_locs[1]
            --print('*** need to check protection of ' .. loc[1] .. ',' .. loc[2])

            -- First check (because it's quick): if there is a unit on the hex to be protected
            is_protected = false
            for src,dst in pairs(combo) do
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
                for src,dst in pairs(combo) do
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

                for src,dst in pairs(combo) do
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


        if (not is_dqed) then
            rating = rating / cum_weight * count

            if (count > 1) then
                -- Bonus for distance of 2 or 3
                if (min_min_dist >= 2) and (max_min_dist <= 3) then
                    rating = rating * 1.10

                    if (max_min_dist == 2) then
                        rating = rating + 0.0001
                    end
                end

                -- Penalty for too far apart
                if (max_min_dist > 3) then
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


            -- Display combo and rating, if desired
            if false then
                local x, y
                for src,dst in pairs(combo) do
                    x, y =  math.floor(dst / 1000), dst % 1000
                    local id = ratings[dst][src].id
                    W.label { x = x, y = y, text = id }
                end
                wesnoth.scroll_to_tile(x, y)
                W.message { speaker = 'narrator',
                    message = 'Hold combo ' .. i_c .. '/' .. #combos .. ' rating = ' .. rating }
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
            local best_combo = reachable_by_enemy(best_combo, ratings, gamedata)
        end
    end
    if (unprotected_best_combo) then
        local count = 0
        for src,dst in pairs(unprotected_best_combo) do count = count + 1 end

        if (count > 1) then
            local unprotected_best_combo = reachable_by_enemy(unprotected_best_combo, ratings, gamedata)
        end
    end

    --print(' ===> max rating:             ' .. (max_rating or 'none'))
    --print(' ===> max rating unprotected: ' .. (unprotected_max_rating or 'none'))

    return best_combo, unprotected_best_combo
end


return UHC
