local H = wesnoth.require "lua/helper.lua"
local W = H.set_wml_action_metatable {}
local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local FAU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack_utils.lua"
local FGUI = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_gamestate_utils_incremental.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local fred_hold_utils = {}

function fred_hold_utils.is_acceptable_location(unit_info, x, y, hit_chance, counter_stats, counter_attack, value_ratio, raw_cfg, gamedata, cfg)
    -- Check whether are holding/advancing location has acceptable expected losses
    --
    -- Optional parameters:
    --  @cfg: override the default settings/calculations for these parameters:
    --    - defend_hard
    --    - acceptable_rating
    -- TODO: simplify the function call, fewer parameters

    -- If enemy cannot attack here, it's an acceptable location by default
    if (not next(counter_attack)) then return true end

    local show_debug = false
    if (x == 9918) and (y == 9) and (unit_info.type == 'Orcish Assassin') then
        show_debug = true
        --DBG.dbms(counter_stats)
    end

    FU.print_debug(show_debug, x, y, unit_info.id, unit_info.tod_mod)
    FU.print_debug(show_debug, '    rating, ctd:', counter_stats.rating_table.rating, counter_stats.def_stat.hp_chance[0])
    --DBG.dbms(raw_cfg.hold_core_slf)
    local is_core_hex = false
    if raw_cfg.hold_core_slf then
        is_core_hex = wesnoth.match_location(x, y, raw_cfg.hold_core_slf)
    end
    FU.print_debug(show_debug, '  is_core_hex:', is_core_hex)

    local is_desperate_hex = false
    if raw_cfg.hold_core_slf then
        is_desperate_hex = wesnoth.match_location(x, y, raw_cfg.hold_desperate_slf)
    end
    FU.print_debug(show_debug, '  is_desperate_hex:', is_desperate_hex)

    local is_good_terrain = (hit_chance <= unit_info.good_terrain_hit_chance)
    FU.print_debug(show_debug, '  is_good_terrain:', is_good_terrain)

    local defend_hard = is_core_hex and is_good_terrain

    -- TODO: this is inefficient, clean up later
    -- Note, need to check vs. 'nil' as 'false' is a possible value
    if cfg and (cfg.defend_hard ~= nil) then
        FU.print_debug(show_debug, '  overriding defend_hard fron cfg:', cfg.defend_hard)
        defend_hard = cfg.defend_hard
    end

    FU.print_debug(show_debug, '  --> defend_hard:', defend_hard)

    -- When defend_hard=false, make the acceptable limits dependable on value_ratio
    -- TODO: these are pretty arbitrary values at this time; refine
    value_ratio = value_ratio or FU.cfg_default('value_ratio')
    FU.print_debug(show_debug, '  value_ratio:', value_ratio)

    local acceptable_die_chance, acceptable_rating = 0, 0
    FU.print_debug(show_debug, '  default acceptable_die_chance, acceptable_rating:', acceptable_die_chance, acceptable_rating)


    if (value_ratio < 1) then
        -- acceptable_die_chance: 0 at vr = 1, 0.25 at vr = 0.5
        acceptable_die_chance = (1 - value_ratio) / 2.

        -- acceptable_rating: 0 at vr = 1, 4 at vr = 0.5
        acceptable_rating = (1 - value_ratio) * 8.

        -- Just in case (should not be necessary under most circumstances)
        if (acceptable_die_chance < 0) then acceptable_die_chance = 0 end
        if (acceptable_die_chance > 0.25) then acceptable_die_chance = 0.25 end
        if (acceptable_rating < 0) then acceptable_rating = 0 end
        if (acceptable_rating > 4) then acceptable_rating = 4 end
    end

    -- We raise the limit at good time of day
    if (unit_info.tod_mod == 1) then
        acceptable_rating = acceptable_rating + 1
    elseif (unit_info.tod_mod > 1) then
        acceptable_rating = acceptable_rating + 2
    end

    -- TODO: this is inefficient, clean up later
    if cfg and cfg.acceptable_rating then
        FU.print_debug(show_debug, '  overriding acceptable_rating fron cfg:', cfg.acceptable_rating)
        acceptable_rating = cfg.acceptable_rating
    end

    FU.print_debug(show_debug, '  -> acceptable_die_chance, acceptable_rating:', acceptable_die_chance, acceptable_rating)

    if defend_hard then
        local acceptable_die_chance = 0.25
        if gamedata.village_map[x] and gamedata.village_map[x][y] then
           acceptable_die_chance = 0.5
        end
        if is_desperate_hex then
           acceptable_die_chance = 0.8
        end

        FU.print_debug(show_debug, '    defend hard', counter_stats.def_stat.hp_chance[0], counter_stats.rating_table.rating)
        if (counter_stats.def_stat.hp_chance[0] > acceptable_die_chance) then
            FU.print_debug(show_debug, '      not acceptable because chance to die too high:', counter_stats.def_stat.hp_chance[0] .. ' > ' .. acceptable_die_chance)
            return false
        end
    else
        FU.print_debug(show_debug, '    do not defend hard', counter_stats.def_stat.hp_chance[0], counter_stats.rating_table.rating)
        if (counter_stats.def_stat.hp_chance[0] > acceptable_die_chance) then
            FU.print_debug(show_debug, '      not acceptable because chance to die too high:', counter_stats.def_stat.hp_chance[0])
            return false
        end
        -- TODO: not sure yet if this should be used
        -- TODO: might have to depend on enemy faction
        -- Also if the relative loss is more than X HP (X/12 the
        -- value of a grunt) for any single attack
        if (counter_stats.rating_table.rating >= acceptable_rating) then
            FU.print_debug(show_debug, '      not acceptable because rating too bad:', counter_stats.rating_table.rating)
            return false
        end
    end

    return true
end

function fred_hold_utils.is_acceptable_hold(combo_stats, raw_cfg, zone_cfg, hold_cfg, gamedata)
    --DBG.dbms(combo_stats)
    --DBG.dbms(zone_cfg)
    --DBG.dbms(hold_cfg)

    local show_debug = false
    if (x == 18) and (y == 12) and (unit_info.type == 'Orcish Grunt') then
        show_debug = false
    end

    FU.print_debug(show_debug, '\nfred_hold_utils.is_acceptable_hold')

    local n_core, n_forward = 0, 0
    local power_forward = 0
    local n_total = #combo_stats

    for _,cs in ipairs(combo_stats) do
        FU.print_debug(show_debug, '  ' .. cs.id, cs.x, cs.y)
        --DBG.dbms(raw_cfg.hold_core_slf)

        local is_good_terrain = (cs.hit_chance <= gamedata.unit_infos[cs.id].good_terrain_hit_chance)
        FU.print_debug(show_debug, '    is_good_terrain:', is_good_terrain, cs.hit_chance)

        local is_core_hex = false
        if raw_cfg.hold_core_slf then
            is_core_hex = wesnoth.match_location(cs.x, cs.y, raw_cfg.hold_core_slf)
        end

        -- Only good terrain hexes count into the core hex count here
        -- TODO: this is preliminary for testing right now
        if is_core_hex then
            if is_good_terrain then
                n_core = n_core + 1
            else
                n_forward = n_forward + 1
                power_forward = power_forward + gamedata.unit_infos[cs.id].power
            end
        end
        FU.print_debug(show_debug, '    is_core_hex:', is_core_hex)

        --[[
        local is_forward_hex = false
        if raw_cfg.hold_forward_slf then
            is_forward_hex = wesnoth.match_location(cs.x, cs.y, raw_cfg.hold_forward_slf)
        end
        if is_forward_hex then
            n_forward = n_forward + 1
            power_forward = power_forward + gamedata.unit_infos[cs.id].power
        end
        FU.print_debug(show_debug, '    is_forward_hex:', is_forward_hex)
        --]]

        local dist_margin = 1
        local dist = FU.get_fgumap_value(gamedata.leader_distance_map, cs.x, cs.y, 'distance')
        if (dist > hold_cfg.max_forward_distance + dist_margin) then
            FU.print_debug(show_debug, '    forward distance not acceptable:', cs.id, cs.x, cs.y, dist .. ' > ' .. hold_cfg.max_forward_distance .. ' + ' .. dist_margin)
            return false
        end
    end

    FU.print_debug(show_debug, '    n_total, n_core, n_forward:', n_total, n_core, n_forward)
    --FU.print_debug(show_debug, '    power_forward, power_threats:', power_forward, zone_cfg.power_threats)

    --if (n_forward > 0) and (power_forward < zone_cfg.power_threats) then
    --    return false
    --end

    -- Forward hexes are only accepted if:
    --  - there are no core hexes being held
    --  - or: the rating is positive
    --[[
    if (n_forward < n_total) or (n_forward == 1) then -- This is a place_holder for now
        if (n_forward > 0) then
            for _,cs in ipairs(combo_stats) do
                FU.print_debug(show_debug, '  ' .. cs.id, cs.counter_rating)
                -- Note: this is the counter attack rating -> negative is good
                if (cs.counter_rating > 0) then
                    FU.print_debug(show_debug, '    forward hex not acceptable:', cs.id, cs.counter_rating)
                    return false
                end
            end
        end
    end
    --]]

    return true
end

function fred_hold_utils.get_hold_units(zone_id, holders, raw_cfg, gamedata, move_cache, show_debug_hold)
    -- This part starts with a quick and dirt zone analysis for what
    -- *might* be the best positions. The rating is the same as the
    -- more detailed analysis below, but it is done using the assumed
    -- counter attack positions on the enemy on the map, while the
    -- more detailed analysis actually does a full counter attack
    -- calculation
    --
    -- TODO: this function still contains a lot of duplicate and unnecessary
    -- code from the hold evaluation code in fred.lua. Needs to be clean up.

    --DBG.dbms(raw_cfg)

    local zone = wesnoth.get_locations(raw_cfg.hold_slf)
    local full_zone_map = {}
    for _,loc in ipairs(zone) do
        FU.set_fgumap_value(full_zone_map, loc[1], loc[2], 'flag', true)
    end
    --DBG.dbms(zone_map)
    --FU.put_fgumap_labels(full_zone_map, 'flag')

    local zone_map = {}
    for x,tmp in pairs(full_zone_map) do
        for y,_ in pairs(tmp) do
            for enemy_id,etm in pairs(gamedata.enemy_turn_maps) do
                local turns = etm[x] and etm[x][y] and etm[x][y].turns

                if turns and (turns <= 1) then
                    FU.set_fgumap_value(zone_map, x, y, 'flag', true)
                end
            end
        end
    end
    --FU.put_fgumap_labels(zone_map, 'flag')

    -- For the enemy rating, we need to put a 1-hex buffer around this
    local buffered_zone_map = {}
    for x,tmp in pairs(zone_map) do
        for y,_ in pairs(tmp) do
            if (not buffered_zone_map[x]) then
                buffered_zone_map[x] = {}
            end
            buffered_zone_map[x][y] = true

            for xa,ya in H.adjacent_tiles(x, y) do
                if (not buffered_zone_map[xa]) then
                    buffered_zone_map[xa] = {}
                end
                buffered_zone_map[xa][ya] = true
            end
        end
    end
    --DBG.dbms(buffered_zone_map)

    -- Enemy rating map: get the sum of the squares of the (modified)
    -- defense ratings of all enemies that can reach a hex
    local threatened_villages_map, villages_first = {}, false
    local enemy_rating_map = {}
    for x,tmp in pairs(buffered_zone_map) do
        for y,_ in pairs(tmp) do
            local enemy_rating, count = 0, 0
            for enemy_id,etm in pairs(gamedata.enemy_turn_maps) do
                local turns = etm[x] and etm[x][y] and etm[x][y].turns

                if turns and (turns <= 1) then
                    local enemy_hc = FGUI.get_unit_defense(gamedata.unit_copies[enemy_id], x, y, gamedata.defense_maps)
                    enemy_hc = 1 - enemy_hc

                    -- If this is a village, give a bonus
                    -- TODO: do this more quantitatively
                    if gamedata.village_map[x] and gamedata.village_map[x][y] then
                        enemy_hc = enemy_hc - 0.15
                        if (enemy_hc < 0) then enemy_hc = 0 end
                    end

                    -- Note that this number is large if it is bad for
                    -- the enemy, good for the AI, so it needs to be
                    -- added, not subtracted
                    enemy_rating = enemy_rating + enemy_hc^2
                    count = count + 1
                end
            end

            if (count > 0) then
                enemy_rating = enemy_rating / count
                if (not enemy_rating_map[x]) then enemy_rating_map[x] = {} end
                enemy_rating_map[x][y] = {
                    rating = enemy_rating,
                    count = count
                }

                if gamedata.village_map[x] and gamedata.village_map[x][y]
                    and ((not gamedata.my_unit_map_noMP[x]) or (not gamedata.my_unit_map_noMP[x][y]))
                then
                    villages_first = true
                    if (not threatened_villages_map[x]) then threatened_villages_map[x] = {} end
                    threatened_villages_map[x][y] = {
                        rating = enemy_rating,
                        adj_count = count
                    }
                end
            end
        end
    end
    --DBG.dbms(threatened_villages_map)

    local show_debug_local = false
    if show_debug_local then
        FU.put_fgumap_labels(enemy_rating_map, 'rating')
        W.message{ speaker = 'narrator', message = zone_id .. ': enemy_rating_map' }
    end

    -- Need a map with the distances to the enemy and own leaders
    local leader_cx, leader_cy = AH.cartesian_coords(gamedata.leader_x, gamedata.leader_y)
    local enemy_leader_cx, enemy_leader_cy = AH.cartesian_coords(gamedata.enemy_leader_x, gamedata.enemy_leader_y)

    local dist_btw_leaders = math.sqrt( (enemy_leader_cx - leader_cx)^2 + (enemy_leader_cy - leader_cy)^2 )

    local leader_distance_map = {}
    local width, height = wesnoth.get_map_size()
    for x = 1,width do
        for y = 1,width do
            local cx, cy = AH.cartesian_coords(x, y)

            local leader_dist = math.sqrt( (leader_cx - cx)^2 + (leader_cy - cy)^2 )
            local enemy_leader_dist = math.sqrt( (enemy_leader_cx - cx)^2 + (enemy_leader_cy - cy)^2 )

            if (not leader_distance_map[x]) then leader_distance_map[x] = {} end
            leader_distance_map[x][y] = { distance = leader_dist - enemy_leader_dist }
        end
    end

    local show_debug_local = false
    if show_debug_local then
        FU.put_fgumap_labels(leader_distance_map, 'distance')
        W.message{ speaker = 'narrator', message = zone_id .. ': leader_distance_map' }
        AH.clear_labels()
    end

    -- First calculate a unit independent rating map
    -- For the time being, this is the just the enemy rating averaged over all
    -- adjacent hexes that are closer to the enemy leader than the hex
    -- being evaluated.
    -- The assumption is that the enemies will be coming from there.
    -- TODO: evaluate when this might break down

    indep_rating_map = {}
    for x,tmp in pairs(zone_map) do
        for y,_ in pairs(tmp) do
            local rating, adj_count = 0, 0

            for xa,ya in H.adjacent_tiles(x, y) do
                if leader_distance_map[xa][ya].distance >= leader_distance_map[x][y].distance then
                    local def_rating = enemy_rating_map[xa]
                        and enemy_rating_map[xa][ya]
                        and enemy_rating_map[xa][ya].rating

                    if def_rating then
                        rating = rating + def_rating
                        adj_count = adj_count + 1
                    end
                end
            end

            if (adj_count > 0) then
                rating = rating / adj_count

                if (not indep_rating_map[x]) then indep_rating_map[x] = {} end
                indep_rating_map[x][y] = {
                    rating = rating,
                    adj_count = adj_count
                }
            end
        end
    end

    if show_debug_hold then
        FU.put_fgumap_labels(indep_rating_map, 'rating')
        W.message { speaker = 'narrator', message = 'Hold zone ' .. zone_id .. ': unit-independent rating map: rating' }
        --FU.put_fgumap_labels(indep_rating_map, 'adj_count')
        --W.message { speaker = 'narrator', message = 'Hold zone ' .. zone_id .. ': unit-independent rating map: adjacent count' }
        AH.clear_labels()
    end

    -- Now we go on to the unit-dependent rating part
    -- This is the same type of rating as for enemies, but done individually
    -- for each AI unit, rather than averaged over all units for each hex

    -- This will hold the rating maps for all units
    local unit_rating_maps = {}

    for id,loc in pairs(holders) do
        local max_rating_unit, best_hex_unit = -9e99, {}

        unit_rating_maps[id] = {}

        for x,tmp in pairs(gamedata.reach_maps[id]) do
            for y,_ in pairs(tmp) do
                -- Only count hexes that enemies can attack
                local adj_count = (indep_rating_map[x]
                    and indep_rating_map[x][y]
                    and indep_rating_map[x][y].adj_count
                )

                if adj_count and (adj_count > 0) then
                    local hit_chance = FU.get_hit_chance(id, x, y, gamedata)

                    local unit_rating = indep_rating_map[x][y].rating - hit_chance^2

                    if (not unit_rating_maps[id][x]) then unit_rating_maps[id][x] = {} end
                    unit_rating_maps[id][x][y] = { rating = unit_rating }
                end
            end
        end

        if show_debug_hold then
            wesnoth.scroll_to_tile(gamedata.units[id][1], gamedata.units[id][2])
            FU.put_fgumap_labels(unit_rating_maps[id], 'rating')
            wesnoth.add_tile_overlay(gamedata.units[id][1], gamedata.units[id][2], { image = "items/orcish-flag.png" })
            W.redraw()
            W.message { speaker = 'narrator', message = 'Hold zone: unit-specific rating map: ' .. id }
            wesnoth.remove_tile_overlay(gamedata.units[id][1], gamedata.units[id][2], { image = "items/orcish-flag.png" })
            FU.clear_labels()
            W.redraw()
        end
    end

    -- Next, we find the units that have the highest-rated hexes, and
    -- sort the hexes for each unit by rating

    local unit_ratings, rated_units = {}, {}
    local max_hexes = 3 -- number of hexes per unit for placement combos
    local new_ratings = {}

    for id,unit_rating_map in pairs(unit_rating_maps) do
        -- Need to extract the map into a sortable format first
        -- TODO: this is additional overhead that can be removed later
        -- when the maps are not needed any more
        unit_ratings[id] = {}
        for x,tmp in pairs(unit_rating_map) do
            for y,r in pairs(tmp) do
                table.insert(unit_ratings[id], {
                    rating = r.rating,
                    x = x, y = y
                })
            end
        end

        table.sort(unit_ratings[id], function(a, b) return a.rating > b.rating end)

        -- We also identify the best units; which are those with the highest
        -- average of the best ratings (only those to be used for the next step)
        -- The previous rating is only used to identify the best hexes though.
        -- The units are rated based on counter attack stats (single unit on that
        -- hex only), otherwise a 1HP assassin will be chosen over a full HP whelp.
        local av_best_ratings = 0
        n_hexes = math.min(max_hexes, #unit_ratings[id])
        for i = 1,n_hexes do
            local old_locs = { { gamedata.unit_copies[id].x, gamedata.unit_copies[id].y } }
            local new_locs = { { unit_ratings[id][i].x, unit_ratings[id][i].y } }
            local target = {}
            target[id] = { unit_ratings[id][i].x, unit_ratings[id][i].y }

            local cfg_counter_attack = { use_max_damage_weapons = true }
            local counter_stats, counter_attack = FAU.calc_counter_attack(target, old_locs, new_locs, gamedata, move_cache, cfg_counter_attack)
            ---DBG.dbms(counter_stats)

            av_best_ratings = av_best_ratings - counter_stats.rating_table.rating
            --print(id, unit_ratings[id][i].rating, - counter_stats.rating_table.rating, unit_ratings[id][i].x, unit_ratings[id][i].y)
        end
        av_best_ratings = av_best_ratings / n_hexes
        --print('  total rating: ', av_best_ratings, id)

        table.insert(rated_units, { id = id, rating = av_best_ratings })

        --print('Attack rating for:', id)
        local total_rating, hex_count = 0, 0
        for i = 1,n_hexes do
            local x,y = unit_ratings[id][i].x, unit_ratings[id][i].y
            --print('  on:', x, y)

            local uiw = wesnoth.get_unit(x, y)
            if uiw then
                --print('    removing unit in way:', uiw.id)
                wesnoth.extract_unit(uiw)
            end

            local best_defense = {}
            for xa,ya in H.adjacent_tiles(x, y) do
                --print('    adjacent:', xa, ya)

                for enemy_id,etm in pairs(gamedata.enemy_turn_maps) do
                    local turns = etm[x] and etm[x][y] and etm[x][y].turns

                    if turns and (turns <= 1) then
                        local enemy_defense = FGUI.get_unit_defense(gamedata.unit_copies[enemy_id], xa, ya, gamedata.defense_maps)
                        --print('      ', enemy_id, enemy_defense)
                        if (not best_defense[enemy_id]) or (enemy_defense > best_defense[enemy_id].defense) then
                            best_defense[enemy_id] = {
                                defense = enemy_defense,
                                x = xa, y = ya
                            }
                        end

                    end
                end
            end
            --DBG.dbms(best_defense)

            local av_rating, enemy_count = 0, 0

            for enemy_id,enemy_loc in pairs(best_defense) do
                --print('    enemy', enemy_id, enemy_loc.x, enemy_loc.y)

                -- Now we put the units on the map and do the attack calculation
                local old_x = gamedata.unit_copies[id].x
                local old_y = gamedata.unit_copies[id].y
                local old_x_enemy = gamedata.unit_copies[enemy_id].x
                local old_y_enemy = gamedata.unit_copies[enemy_id].y

                local enemy_proxy = wesnoth.get_unit(old_x_enemy, old_y_enemy)
                wesnoth.extract_unit(enemy_proxy)

                -- Extract a potential other enemy in the way of the enemy to be checked here
                -- Needs to be done here in case the old and new locations are the same
                -- Todo: we could save the effort of moving the enemy in that case
                local uiw_enemy = wesnoth.get_unit(enemy_loc.x, enemy_loc.y)
                if uiw_enemy then
                    print('    removing enemy in way:', uiw_enemy.id)
                    wesnoth.extract_unit(uiw_enemy)
                end

                wesnoth.put_unit(enemy_loc.x, enemy_loc.y, enemy_proxy)

                wesnoth.put_unit(x, y, gamedata.unit_copies[id])
                local unit_proxy = wesnoth.get_unit(x, y)

                local att_stat, def_stat = wesnoth.simulate_combat(unit_proxy, enemy_proxy)
                local att_stat2, def_stat2 = wesnoth.simulate_combat(enemy_proxy, unit_proxy)

                local rt = FAU.attack_rating(
                    { gamedata.unit_infos[id] },
                    gamedata.unit_infos[enemy_id],
                    { { x, y }},
                    { att_stat }, def_stat, gamedata
                )
                local rt2 = FAU.attack_rating(
                    { gamedata.unit_infos[enemy_id] },
                    gamedata.unit_infos[id],
                    { { enemy_loc.x, enemy_loc.y }},
                    { att_stat2 }, def_stat2, gamedata
                )

                local rating = 0.5 * rt.rating - rt2.rating
                --print('      rating', rating .. ' = 0.5 * ' .. rt.rating .. ' - ' .. rt2.rating)

                av_rating = av_rating + rating
                enemy_count = enemy_count + 1

                gamedata.unit_copies[id] = wesnoth.copy_unit(unit_proxy)
                wesnoth.put_unit(x, y)
                gamedata.unit_copies[id].x = old_x
                gamedata.unit_copies[id].y = old_y

                wesnoth.extract_unit(enemy_proxy)
                wesnoth.put_unit(old_x_enemy, old_y_enemy, enemy_proxy)

                if uiw_enemy then
                    wesnoth.put_unit(uiw_enemy)
                end
            end

            av_rating = av_rating / enemy_count
            --print('    av_rating', av_rating)

            total_rating = total_rating + av_rating
            hex_count = hex_count + 1

            if uiw then
                wesnoth.put_unit(uiw)
            end
        end

        total_rating = total_rating / hex_count

        --print('  total_rating', total_rating)
        new_ratings[id] = total_rating
    end

    -- Exclude units that have no reachable qualified hexes
    for i_ru = #rated_units,1,-1 do
        local id = rated_units[i_ru].id
        if (#unit_ratings[id] == 0) then
            table.remove(rated_units, i_ru)
        end
    end

    if (#rated_units == 0) then
        return
    end

    -- Sorting this will now give us the order of units to be considered
    table.sort(rated_units, function(a, b) return a.rating > b.rating end)
    --DBG.dbms(unit_ratings)
    --DBG.dbms(rated_units)

    return new_ratings

end

return fred_hold_utils
