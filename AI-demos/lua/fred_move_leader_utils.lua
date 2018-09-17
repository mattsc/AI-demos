local H = wesnoth.require "helper"
local AH = wesnoth.require "ai/lua/ai_helper.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local FAU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack_utils.lua"
local FGUI = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_gamestate_utils_incremental.lua"
local FCFG = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_config.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local function get_best_village(leader, recruit_first, move_data)
    -- If we're trying to retreat to a village, check whether we do so directly,
    -- or go to a keep first.

    local village_map = {}

    if recruit_first then
        -- Go to (any) keep, then to a village
        -- Need list of all those villages
        for x,y,_ in FU.fgumap_iter(move_data.reachable_keeps_map[wesnoth.current.side]) do
            --std_print('keep:', x .. ',' .. y)
            -- Note that reachable_keeps_map contains moves_left assuming max_mp for the leader
            -- This should generally be the same at this stage as the real situation, but
            -- might not work depending on how this is used in the future.
            local ml = FU.get_fgumap_value(move_data.reach_maps[leader.id], x, y, 'moves_left')
            if ml then
                -- Can the leader get to any villages from here?
                local old_loc = { leader[1], leader[2] }
                local old_moves = move_data.unit_infos[leader.id].moves
                local leader_copy = move_data.unit_copies[leader.id]
                leader_copy.x, leader_copy.y = x, y
                leader_copy.moves = ml
                local reach_from_keep = wesnoth.find_reach(leader_copy)
                leader_copy.x, leader_copy.y = old_loc[1], old_loc[2]
                leader_copy.moves = old_moves

                for _,loc in ipairs(reach_from_keep) do
                    local owner = FU.get_fgumap_value(move_data.village_map, loc[1], loc[2], 'owner')

                    if owner then
                        local max_ml = (FU.get_fgumap_value(village_map, loc[1], loc[2], 'info') or {}).moves_left
                        --std_print('  village:', loc[1] .. ',' .. loc[2], loc[3], max_ml)
                        -- TODO: this does not necessarily gives the closest
                        -- village to any keep, but the closest village to get
                        -- to via a keep from current leader position. Might want
                        -- to simply add the closest village to reachable_keeps (in gamestate_utils)
                        if (not max_ml) or (max_ml < loc[3]) then
                            local info = {
                                keep = { x, y },
                                moves_left = loc[3]
                            }
                            FU.set_fgumap_value(village_map, loc[1], loc[2], 'info', info)
                        end
                    end
                end
            end
        end
    else
        -- Go directly to a village (but must be within one move of keep)
        -- Need list of all those villages
        for x,y,_ in FU.fgumap_iter(move_data.reach_maps[leader.id]) do
            local owner = FU.get_fgumap_value(move_data.village_map, x, y, 'owner')
            if owner then
                --std_print('village:', x .. ',' .. y)

                -- Can the leader get to any villages from here?
                local old_loc = { leader[1], leader[2] }
                local old_moves = move_data.unit_infos[leader.id].moves
                local leader_copy = move_data.unit_copies[leader.id]
                leader_copy.x, leader_copy.y = x, y
                leader_copy.moves = leader_copy.max_moves
                local reach_from_village = wesnoth.find_reach(leader_copy)
                leader_copy.x, leader_copy.y = old_loc[1], old_loc[2]
                leader_copy.moves = old_moves
                --std_print('#reach_from_village', #reach_from_village)

                for _,loc in ipairs(reach_from_village) do
                    if FU.get_fgumap_value(move_data.reachable_keeps_map[wesnoth.current.side], loc[1], loc[2], 'moves_left') then
                        -- Moves left after moving from village to keep
                        --std_print('  keep:', loc[1] .. ',' .. loc[2], loc[3])
                        local max_ml = (FU.get_fgumap_value(village_map, x, y, 'info') or {}).moves_left
                        if (not max_ml) or (max_ml < loc[3]) then
                            FU.set_fgumap_value(village_map, x, y, 'info', { moves_left = loc[3] })
                        end
                    end
                end
            end
        end
    end
    --DBG.dbms(village_map, false, 'village_map')

    -- Now select best village
    local leader_unthreatened_hex_bonus = FCFG.get_cfg_parm('leader_unthreatened_hex_bonus')
    local leader_moves_left_factor = FCFG.get_cfg_parm('leader_moves_left_factor')


    local max_rating, best_village = - math.huge
    for x,y,village in FU.fgumap_iter(village_map) do
        local influence = FU.get_fgumap_value(move_data.influence_maps, x, y, 'influence')
        local enemy_influence = FU.get_fgumap_value(move_data.influence_maps, x, y, 'enemy_influence') or 0
        local moves_left = village.info.moves_left

        local rating = moves_left * leader_moves_left_factor

        if (enemy_influence == 0) then
            rating = rating + leader_unthreatened_hex_bonus
        else
            rating = rating + influence
        end
        --std_print('rating for village: ', x .. ',' .. y, rating, influence, enemy_influence, moves_left)

        if (rating > max_rating) then
            max_rating = rating
            best_village = { x, y }
        end
    end
    --DBG.dbms(best_village, false, 'best_village')

    local keep_on_way
    if best_village then
        local info = FU.get_fgumap_value(village_map, best_village[1], best_village[2], 'info')
        if info.keep then
            keep_on_way = info.keep
        end
    end
    --DBG.dbms(keep_on_way, false, 'keep_on_way')

    return best_village, keep_on_way
end


local function get_best_keep(leader, fred_data)
    local move_data = fred_data.move_data
    local leader_info = move_data.unit_infos[leader.id]

    local leader_turns_rating = FCFG.get_cfg_parm('leader_turns_rating')
    local leader_unit_in_way_penalty = FCFG.get_cfg_parm('leader_unit_in_way_penalty')
    local leader_unthreatened_hex_bonus = FCFG.get_cfg_parm('leader_unthreatened_hex_bonus')
    local leader_eld_factor = FCFG.get_cfg_parm('leader_eld_factor')

    local max_rating, best_keep, best_turns = - math.huge
    for x,y,_ in FU.fgumap_iter(move_data.reachable_keeps_map[wesnoth.current.side]) do
        -- Note that reachable_keeps ignores other units, both own units and enemies
        -- So we need to check that the leader can get there first.
        local path, cost = wesnoth.find_path(move_data.unit_copies[leader.id], x, y)
        cost = cost + leader_info.max_moves - leader_info.moves
        local turns = math.ceil(cost / leader_info.max_moves)
        if (turns == 0) then turns = 1 end
        --std_print('  cost, turns:', cost, turns)

        local turn_rating = (turns - 1) * leader_turns_rating
        --std_print('  turn_rating:', turn_rating)

        -- If we can get there this turn, check whether there's a unit in the way,
        -- and whether it can move away. If it takes us more than a move, we don't
        -- care. And hexes with enemies have a huge cost (42424242) anyway.
        local unit_in_way_rating = 0
        if (turns == 1) then
            if (x ~= leader[1]) or (y ~= leader[2]) then
                if FU.get_fgumap_value(move_data.unit_map, x, y, 'id') then
                    --std_print('  in way: ' .. FU.get_fgumap_value(move_data.unit_map, x, y, 'id'))
                    if FU.get_fgumap_value(move_data.my_unit_map_MP, x, y, 'can_move_away') then
                        unit_in_way_rating = leader_unit_in_way_penalty
                    else
                        unit_in_way_rating = leader_turns_rating + leader_unit_in_way_penalty
                    end
                end
            end
        end
        --std_print('  unit_in_way_rating:', unit_in_way_rating)

        local influence = FU.get_fgumap_value(move_data.influence_maps, x, y, 'influence')
        local enemy_influence = FU.get_fgumap_value(move_data.influence_maps, x, y, 'enemy_influence') or 0
        --std_print('  influence, enemy_influence: ', influence, enemy_influence)

        local rating = turn_rating + unit_in_way_rating

        if (enemy_influence == 0) then
            rating = rating + leader_unthreatened_hex_bonus
        else
            rating = rating + influence
        end

        -- Minor rating is distance from enemy leader (the closer the better)
        local eld = FU.get_fgumap_value(fred_data.turn_data.leader_distance_map, x, y, 'enemy_leader_distance')
        --std_print('  eld', eld)

        rating = rating + eld * leader_eld_factor
        --std_print('rating for keep: ', x .. ',' .. y, rating)

        if (rating > max_rating) then
            max_rating = rating
            best_keep = { x, y }
            best_turns = turns
        end
    end

    -- If the leader cannot get to the keep this turn, find the best location to go to instead
    if (best_turns > 1) then
        -- TODO
    end

    return best_keep
end


local fred_move_leader_utils = {}

function fred_move_leader_utils.leader_objectives(fred_data)
    local move_data = fred_data.move_data
    local leader = move_data.leaders[wesnoth.current.side]

    local prerecruit = { units = {} }
    -- TODO: for now we only check if recruiting will be done for any one keep hex.
    --   Might have to be extended when taking this to other maps.
    for x,y,_ in FU.fgumap_iter(move_data.reachable_keeps_map[wesnoth.current.side]) do
        local outofway_units = {}
        -- Note that the leader is included in the following, as he might
        -- be on a castle hex other than a keep. His recruit location is
        -- automatically excluded by the prerecruit code
        for _,_,data in FU.fgumap_iter(move_data.my_unit_map_MP) do
            if data.can_move_away then
                outofway_units[data.id] = true
            end
        end

        prerecruit = fred_data.recruit:prerecruit_units({ x, y }, outofway_units)
        -- Need to do this, or the recruit CA will try to recruit the same units again later
        fred_data.recruit:clear_prerecruit()

        break
    end
    --DBG.dbms(prerecruit, false, 'prerecruit')

    -- If the eventual goal is a village, we do not need to rate the keep that we might
    -- stop by for recruiting. The village function will also return whatever keep
    -- works for getting to that village
    local village, keep
    if (not move_data.unit_infos[leader.id].abilities.regenerate)
        and (move_data.unit_infos[leader.id].hitpoints < move_data.unit_infos[leader.id].max_hitpoints)
    then
        village, keep = get_best_village(leader, prerecruit.units[1], move_data)
    end
    --DBG.dbms(village, false, 'village')
    --DBG.dbms(keep, false, 'keep')

    -- If no village was found, we go for the best keep, no matter what the reason
    if (not village) and prerecruit.units[1] then
        keep = get_best_keep(leader, fred_data)
    end
    --DBG.dbms(keep, false, 'keep')

    -- Don't need to go to keep if the leader is already there
    if keep and (keep[1] == leader[1]) and (keep[2] == leader[2]) then
        keep = nil
    end

    -- TODO: if the leader cannot recruit, no need to go back to keep, as long as we stay within one move?

    local leader_objectives = {
        village = village,
        keep = keep
    }

    if prerecruit.units[1] then
        leader_objectives.prerecruit = prerecruit
    end

    return leader_objectives
end

function fred_move_leader_utils.assess_leader_threats(leader_objectives, assigned_enemies, raw_cfgs_main, side_cfgs, fred_data)
    local move_data = fred_data.move_data

    local leader = move_data.leaders[wesnoth.current.side]
    local leader_info = move_data.unit_infos[leader.id]
    local leader_proxy = wesnoth.get_unit(leader[1], leader[2])

    -- Threat are all enemies that can attack the castle (whether or not we go there)
    -- and the village (if we go there)
    local leader_threats = { enemies = {} }
    for x,y,_ in FU.fgumap_iter(move_data.reachable_castles_map[wesnoth.current.side]) do
        local ids = FU.get_fgumap_value(move_data.enemy_attack_map[1], x, y, 'ids') or {}
        for _,id in ipairs(ids) do
            leader_threats.enemies[id] = move_data.units[id][1] * 1000 + move_data.units[id][2]
        end
    end
    if leader_objectives.village then
        local ids = FU.get_fgumap_value(move_data.enemy_attack_map[1], leader_objectives.village[1], leader_objectives.village[2], 'ids') or {}
        for _,id in ipairs(ids) do
            leader_threats.enemies[id] = move_data.units[id][1] * 1000 + move_data.units[id][2]
        end
    end

    for id,threat in pairs(leader_threats.enemies) do
        local zone_id = 'none'
        for zid,enemies in pairs(assigned_enemies) do
            if enemies[id] then
                zone_id = zid
                break
            end
        end
        leader_threats.enemies[id] = threat .. ':' .. zone_id
    end
    --DBG.dbms(leader_threats, false, 'leader_threats')


    -- Check out how much of a threat these units pose in combination
    local max_total_loss, av_total_loss = 0, 0
    --std_print('    possible damage by enemies in reach (average, max):')
    for id,_ in pairs(leader_threats.enemies) do
        local dst
        local max_defense = 0
        for xa,ya in H.adjacent_tiles(move_data.leader_x, move_data.leader_y) do
            local defense = FGUI.get_unit_defense(move_data.unit_copies[id], xa, ya, move_data.defense_maps)

            if (defense > max_defense) then
                max_defense = defense
                dst = { xa, ya }
            end
        end

        local att_outcome, def_outcome = FAU.attack_outcome(
            move_data.unit_copies[id], leader_proxy,
            dst,
            move_data.unit_infos[id], move_data.unit_infos[leader_proxy.id],
            move_data, fred_data.move_cache
        )
        --DBG.dbms(att_outcome, false, 'att_outcome')
        --DBG.dbms(def_outcome, false, 'def_outcome')

        local max_loss = leader_proxy.hitpoints - def_outcome.min_hp
        local av_loss = leader_proxy.hitpoints - def_outcome.average_hp
        --std_print('    ', id, av_loss, max_loss)

        max_total_loss = max_total_loss + max_loss
        av_total_loss = av_total_loss + av_loss
    end
    DBG.print_debug('analysis', 'leader: max_total_loss, av_total_loss', max_total_loss, av_total_loss)

    -- We only consider these leader threats, if they either
    --   - maximum damage reduces current HP by more than 50%
    --   - average damage is more than 25% of max HP
    -- Otherwise we assume the leader can deal with them alone
    leader_threats.significant_threat = false
    if (max_total_loss >= leader_proxy.hitpoints * 0.75) or (av_total_loss >= leader_proxy.max_hitpoints * 0.6) then
        leader_threats.significant_threat = true
    end
    DBG.print_debug('analysis', '  significant_threat', leader_threats.significant_threat)

    -- Only count leader threats if they are significant
    --if (not leader_threats.significant_threat) then
    --    leader_threats.enemies = nil
    --end
    --DBG.dbms(leader_threats, false, 'leader_threats')

    leader_objectives.leader_threats = leader_threats
end


return fred_move_leader_utils
