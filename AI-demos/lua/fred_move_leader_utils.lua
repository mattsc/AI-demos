local H = wesnoth.require "helper"
local AH = wesnoth.require "ai/lua/ai_helper.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local FS = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_status.lua"
local FAU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack_utils.lua"
local FGM = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_map.lua"
local FGUI = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_gamestate_utils_incremental.lua"
local FCFG = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_config.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local function get_reach_map_via_keep(leader, move_data)
    -- Map of hexes the leader can reach after going to a keep.
    -- Hexes with own units with MP=0 are excluded.
    -- x,y in the output map denote the keep by which this is done
    -- This can be used to find the range the leader has after recruiting.

    local old_loc = { leader[1], leader[2] }
    local old_moves = move_data.unit_infos[leader.id].moves
    local leader_copy = move_data.unit_copies[leader.id]

    local effective_reach_map = {}
    for x,y,data in FGM.iter(move_data.reachable_keeps_map[wesnoth.current.side]) do
        local ml = data.moves_left
        leader_copy.x, leader_copy.y = x, y
        leader_copy.moves = ml
        local reach_from_keep = wesnoth.find_reach(leader_copy)

        for _,loc in ipairs(reach_from_keep) do
            if (not FGM.get_value(move_data.my_unit_map_noMP, loc[1], loc[2], 'id')) then
                local ml_old = FGM.get_value(effective_reach_map, loc[1], loc[2], 'moves_left') or -1
                if (loc[3] > ml_old) then
                    FGM.set_value(effective_reach_map, loc[1], loc[2], 'moves_left', loc[3])
                    effective_reach_map[loc[1]][loc[2]].from_keep = { x, y }
                end
            end
        end
    end

    leader_copy.x, leader_copy.y = old_loc[1], old_loc[2]
    leader_copy.moves = old_moves

    return effective_reach_map
end

local function get_reach_map_to_keep(leader, move_data)
    -- Map of hexes from which the leader can reach a keep with full MP on the next
    -- turn. In this case, 'moves_left' denotes MP left after moving to the keep.
    -- x,y in the output map denote the keep to which this is calculated
    -- Hexes with own units with MP=0 are excluded.
    -- This can be used to find how far the leader can wander and still get to a keep next turn.

    local leader_proxy = wesnoth.get_unit(leader[1], leader[2])
    local max_moves = move_data.unit_infos[leader.id].max_moves

    -- This is additional turns in the sense that it measures what the leader can do
    -- after this turn's move. Thus, even the default is 1, rather than 0.
    local add_turns = 1
    local keeps_map = {}
    if next(move_data.close_keeps_map[wesnoth.current.side]) then
        keeps_map = move_data.close_keeps_map[wesnoth.current.side]
    else
        -- This only happens if the leader is out of reach of any keep, or when all the
        -- close keeps are occupied by enemies
        -- This should rarely be needed, so we only do this when required, rather than in gamestate_utils
        local width, height = wesnoth.get_map_size()
        local keeps = wesnoth.get_locations {
            x = "1-"..width, y = "1-"..height,
            terrain = 'K*,K*^*,*^K*'
        }

        for _,keep in pairs(keeps) do
            local _, cost = wesnoth.find_path(move_data.unit_copies[leader.id], keep[1], keep[2], { ignore_units = true })

            keep.add_turns = math.ceil((cost - move_data.unit_infos[leader.id].moves) / move_data.unit_infos[leader.id].max_moves)
            -- The following happens when a keep is within reach, but occupied by enemies
            if (keep.add_turns < 1) then keep.add_turns = 1 end
            --std_print('  ' .. keep[1] .. ',' .. keep[2] .. ': ' .. cost, keep.add_turns)
        end
        table.sort(keeps, function(a, b) return a.add_turns < b.add_turns end)
        --DBG.dbms(keeps, false, 'keeps')

        add_turns = keeps[1].add_turns
        for _,keep in ipairs(keeps) do
            if (keep.add_turns == keeps[1].add_turns) then
                FGM.set_value(keeps_map, keep[1], keep[2], 'add_turns', keep.add_turns)
            end
        end
        --DBG.dbms(keeps)
    end
    --DBG.dbms(keeps_map, false, 'keeps_map')

    local effective_reach_map = {}
    for x_k,y_k,_ in FGM.iter(keeps_map) do
        local cost_from_keep = FU.smooth_cost_map(leader_proxy, { x_k, y_k }, true)
        --DBG.show_fgumap_with_message(cost_from_keep, 'cost', 'cost_from_keep')

        for x,y,data in FGM.iter(cost_from_keep) do
            if (not FGM.get_value(move_data.my_unit_map_noMP, x, y, 'id'))
                and FGM.get_value(move_data.reach_maps[leader.id], x, y, 'moves_left')
            then
                local moves_left = max_moves * add_turns - data.cost
                if (moves_left >= 0) then
                    local ml_old = FGM.get_value(effective_reach_map, x, y, 'moves_left') or -1
                    if (moves_left > ml_old) then
                        FGM.set_value(effective_reach_map, x, y, 'moves_left', moves_left)
                        effective_reach_map[x][y].to_keep = { x_k, y_k }
                    end
                end
            end
        end
    end

    return effective_reach_map
end

local function get_best_village_keep(leader, recruit_first, effective_reach_map, fred_data)
    -- Find village to retreat to. This is done via effective_reach_map, which
    -- automatically takes stopping by a keep, and not wandering off too far
    -- into account, depending on what other moves the leader is supposed to make.
    --
    -- TODO: currently if no village can be reached via a keep, we always prefer
    -- to move to a keep over a village. Might want to add a trade-off eval here.

    local move_data = fred_data.move_data

    local from_keep_found
    local village_map
    if (not move_data.unit_infos[leader.id].abilities.regenerate)
        and (move_data.unit_infos[leader.id].hitpoints < move_data.unit_infos[leader.id].max_hitpoints)
    then
        for x,y,village in FGM.iter(move_data.village_map) do
            --std_print('village: ' .. x .. ',' .. y, village.owner)
            -- This is the effective reach_map
            local moves_left = FGM.get_value(effective_reach_map, x, y, 'moves_left')
            if moves_left then
                --std_print('  in reach: ' .. x .. ',' .. y)
                local info = {
                    moves_left = moves_left,
                    is_village = true,
                    from_keep = effective_reach_map[x][y].from_keep,
                }
                if (not village_map) then village_map = {} end
                FGM.set_value(village_map, x, y, 'info', info)

                -- Also flag if this is done via a keep
                from_keep_found = info.from_keep
            end
        end
    end
    --std_print('from_keep_found: ', from_keep_found)
    --DBG.dbms(village_map, false, 'village_map')

    -- No keep found could mean that either it is not possible to go for a village via
    -- a keep, or that we don't need to go for a village (and did not search)
    -- We always search for a keep to go to, except when we do not need to recruit and
    -- want to go for a village.
    -- TODO: this should be refined at some point for the case that we cannot recruit
    -- (no gold) and do not go for a village either, but want to find the safest/best hex
    -- that is not necessarily a keep
    -- TODO: also need to include case when leader cannot reach a keep
    local keep_map
    if (not from_keep_found) and (recruit_first or (not village_map)) then
        for x,y,data in FGM.iter(move_data.reachable_keeps_map[wesnoth.current.side]) do
            --std_print('keep: ' .. x .. ',' .. y)
            local moves_left = data.moves_left
            --std_print('  in reach: ' .. x .. ',' .. y)
            local info = {
                moves_left = moves_left
            }
            if (not keep_map) then keep_map = {} end
            FGM.set_value(keep_map, x, y, 'info', info)
        end
    end
    --DBG.dbms(keep_map, false, 'keep_map')

    -- keep_map is taken over village_map (but is only calculated if a keep is needed
    -- but none found in the village_map step)
    -- TODO: might not always take keep over village
    local hex_map = keep_map or village_map
    --DBG.dbms(hex_map, false, 'hex_map')

    -- If no hex_map was found, that means that the leader cannot get to a keep and
    -- does not need to go to a village. In that case, we use the effective reach map
    -- to get closer to a keep.
    -- TODO: refine the rating if leader cannot get to a keep
    if (not hex_map) then
        hex_map = {}
        for x,y,erm in FGM.iter(effective_reach_map) do
            local info = { moves_left = erm.moves_left }
            if FGM.get_value(move_data.village_map, x, y, 'owner') then
                info.is_village = true
            end
            FGM.set_value(hex_map, x, y, 'info', info)
        end
    end
    --DBG.dbms(effective_reach_map, false, 'effective_reach_map')
    --DBG.dbms(hex_map, false, 'hex_map')

    -- Now select best village or keep
    local leader_unthreatened_hex_bonus = FCFG.get_cfg_parm('leader_unthreatened_hex_bonus')
    local leader_village_bonus = FCFG.get_cfg_parm('leader_village_bonus')
    local leader_village_grab_bonus = FCFG.get_cfg_parm('leader_village_grab_bonus')
    local leader_moves_left_factor = FCFG.get_cfg_parm('leader_moves_left_factor')
    local leader_unit_in_way_penalty = FCFG.get_cfg_parm('leader_unit_in_way_penalty')
    local leader_unit_in_way_no_moves_penalty = FCFG.get_cfg_parm('leader_unit_in_way_no_moves_penalty')
    local leader_eld_factor = FCFG.get_cfg_parm('leader_eld_factor')

    local max_rating, best_hex = - math.huge
    local hex_rating_map = {}
    for x,y,hex in FGM.iter(hex_map) do
        local influence = FGM.get_value(move_data.influence_maps, x, y, 'influence')
        local enemy_influence = FGM.get_value(move_data.influence_maps, x, y, 'enemy_influence') or 0
        local moves_left = hex.info.moves_left

        local rating = moves_left * leader_moves_left_factor

        if (enemy_influence == 0) then
            rating = rating + leader_unthreatened_hex_bonus
        else
            rating = rating + influence
        end
        --std_print('rating for hex: ', x .. ',' .. y, rating, influence, enemy_influence, moves_left)

        local owner = FGM.get_value(move_data.village_map, x, y, 'owner')
        if owner then
            if (enemy_influence > 0) then
                rating = rating + leader_village_bonus
            end

            if (owner == 0) then
                rating = rating + leader_village_grab_bonus
            elseif (owner ~= wesnoth.current.side) then
                rating = rating + 2 * leader_village_grab_bonus
            end
        end
        --std_print('rating after village bonus: ', x .. ',' .. y, rating, owner)

        -- Check whether there's a unit in the way, and whether it can move away.
        local unit_in_way_rating = 0
        if (x ~= leader[1]) or (y ~= leader[2]) then
            local uiw_id = FGM.get_value(move_data.unit_map, x, y, 'id')
            if uiw_id then
                --std_print('  in way: ' .. uiw_id)
                if move_data.my_units_can_move_away[uiw_id] then
                    unit_in_way_rating = leader_unit_in_way_penalty
                else
                    unit_in_way_rating = leader_unit_in_way_no_moves_penalty + leader_unit_in_way_penalty
                end
            end
        end
        --std_print('  unit_in_way_rating:', unit_in_way_rating)
        local rating = rating + unit_in_way_rating

        -- Minor rating is distance from enemy leader (the closer the better)
        local eld = wesnoth.map.distance_between(x, y, fred_data.move_data.enemy_leader_x, fred_data.move_data.enemy_leader_y)
        --std_print('  eld', eld)
        rating = rating + eld * leader_eld_factor

        --std_print('rating for keep: ', x .. ',' .. y, rating)
        FGM.set_value(hex_rating_map, x, y, 'rating', rating)

        if (rating > max_rating) then
            max_rating = rating
            best_hex = hex
            best_hex.loc = { x, y }
        end
    end
    --DBG.dbms(best_hex, false, 'best_hex')
    --DBG.show_fgumap_with_message(hex_rating_map, 'rating', 'hex_rating_map', move_data.unit_copies[leader.id])

    local village, keep, other
    if best_hex.info.is_village then
        village = best_hex.loc
        keep = best_hex.info.from_keep
    elseif wesnoth.get_terrain_info(wesnoth.get_terrain(best_hex.loc[1], best_hex.loc[2])).keep then
        keep = best_hex.loc
    else
        other = best_hex.loc
    end
    --DBG.dbms(village, false, 'village')
    --DBG.dbms(keep, false, 'keep')
    --DBG.dbms(other, false, 'other')

    return village, keep, other
end


local fred_move_leader_utils = {}

function fred_move_leader_utils.leader_objectives(fred_data)
    local move_data = fred_data.move_data
    local leader = move_data.leaders[wesnoth.current.side]

    local do_recruit, prerecruit = false
    -- TODO: for now we only check if recruiting will be done for any one keep hex.
    --   Might have to be extended when taking this to other maps.
    for x,y,_ in FGM.iter(move_data.reachable_keeps_map[wesnoth.current.side]) do
        local outofway_units = {}
        -- Note that the leader is included in the following, as he might
        -- be on a castle hex other than a keep. His recruit location is
        -- automatically excluded by the prerecruit code
        for id,_ in pairs(move_data.my_units_can_move_away) do
            outofway_units[id] = true
        end

        prerecruit = fred_data.recruit:prerecruit_units({ x, y }, nil, outofway_units)
        -- Need to do this, or the recruit CA will try to recruit the same units again later
        fred_data.recruit:clear_prerecruit()

        break
    end
    --DBG.dbms(prerecruit, false, 'prerecruit')

    if prerecruit and prerecruit.units[1] then
        do_recruit = true
    end

    local effective_reach_map, village, keep, other
    if (move_data.unit_infos[leader.id].moves > 0) then
        -- These are used for other purposes also, so they are not linked to whether we
        -- can reach the desired villages and keeps
        if prerecruit and prerecruit.units[1] then
            effective_reach_map = get_reach_map_via_keep(leader, move_data)
        end
        -- Even if we want to recruit, we need the other effective_reach_map if no
        -- keep can be reached
        if (not effective_reach_map) or (not next(effective_reach_map)) then
            effective_reach_map = get_reach_map_to_keep(leader, move_data)
        end
        --DBG.show_fgumap_with_message(effective_reach_map, 'moves_left', 'effective_reach_map', move_data.unit_copies[leader.id])

        -- If the eventual goal is a village, we do not need to rate the keep that we might
        -- stop by for recruiting. The village function will also return whatever keep
        -- works for getting to that village
        village, keep, other = get_best_village_keep(leader, do_recruit, effective_reach_map, fred_data)
        --DBG.dbms(village, false, 'village')
        --DBG.dbms(keep, false, 'keep')
        --DBG.dbms(other, false, 'other')
    end

    local leader_objectives = {
        village = village,
        keep = keep,
        other = other,
        final = village or keep or other or leader,
        do_recruit = do_recruit
    }

    return leader_objectives, effective_reach_map
end

function fred_move_leader_utils.assess_leader_threats(leader_objectives, side_cfgs, fred_data)
    local move_data = fred_data.move_data

    local leader = move_data.leaders[wesnoth.current.side]
    local leader_info = move_data.unit_infos[leader.id]
    local leader_pos = leader_objectives.final

    -- Threats are all enemies which can attack the final leader position
    -- (ignoring AI units, this using enemy_initial_reach_maps)
    local leader_threats = { enemies = {} }

    local best_defenses = {}
    for enemy_id,eirm in pairs(fred_data.turn_data.enemy_initial_reach_maps) do
        for xa,ya in H.adjacent_tiles(leader_pos[1], leader_pos[2]) do
            if FGM.get_value(eirm, xa, ya, 'moves_left') then
                leader_threats.enemies[enemy_id] = move_data.units[enemy_id][1] * 1000 + move_data.units[enemy_id][2]

                -- The following ignores that the hex might not be reachable for the enemy
                -- once the leader is on its final hex
                if (not best_defenses[enemy_id]) then best_defenses[enemy_id] = { defense = -9e99 } end
                local current_defense = best_defenses[enemy_id].defense
                local defense = FGUI.get_unit_defense(move_data.unit_copies[enemy_id], xa, ya, move_data.defense_maps)
                if (defense > current_defense) then
                    best_defenses[enemy_id] = {
                        x = xa, y = ya, defense = defense
                    }
                end
            end
        end
    end

    -- TODO: do we want to add the castles back in here?
    --   If so, do we use initial or current enemy reach maps?
    --for x,y,_ in FGM.iter(move_data.reachable_castles_map[wesnoth.current.side]) do
    --    local ids = FGM.get_value(move_data.enemy_attack_map[1], x, y, 'ids') or {}
    --    for _,id in ipairs(ids) do
    --        leader_threats.enemies[id] = move_data.units[id][1] * 1000 + move_data.units[id][2]
    --    end
    --end

    --DBG.dbms(leader_threats, false, 'leader_threats')
    --DBG.dbms(best_defenses, false, 'best_defenses')


    local leader_proxy = wesnoth.get_unit(leader[1], leader[2])
    local unit_in_way
    if (leader[1] ~= leader_pos[1]) or (leader[2] ~= leader_pos[2]) then
        unit_in_way = wesnoth.get_unit(leader_pos[1], leader_pos[2])
        if unit_in_way then
            wesnoth.extract_unit(unit_in_way)
        end
        wesnoth.put_unit(leader_proxy, leader_pos[1], leader_pos[2])
    end

    -- Check out how much of a threat these units pose in combination
    local max_total_loss, av_total_loss = 0, 0
    --std_print('    possible damage by enemies in reach (average, max):')
    for enemy_id,_ in pairs(leader_threats.enemies) do
        local dst = { best_defenses[enemy_id].x, best_defenses[enemy_id].y }

        local att_outcome, def_outcome = FAU.attack_outcome(
            move_data.unit_copies[enemy_id], leader_proxy,
            dst,
            move_data.unit_infos[enemy_id], leader_info,
            move_data, fred_data.move_cache
        )
        --DBG.dbms(att_outcome, false, 'att_outcome')
        --DBG.dbms(def_outcome, false, 'def_outcome')

        local max_loss = leader_info.hitpoints - def_outcome.min_hp
        local av_loss = leader_info.hitpoints - def_outcome.average_hp
        --std_print('    ', enemy_id, av_loss, max_loss)

        max_total_loss = max_total_loss + max_loss
        av_total_loss = av_total_loss + av_loss
    end
    DBG.print_debug('ops_output', 'leader: max_total_loss, av_total_loss', max_total_loss, av_total_loss)

    if (leader[1] ~= leader_pos[1]) or (leader[2] ~= leader_pos[2]) then
        wesnoth.put_unit(leader_proxy, leader[1], leader[2])
        if unit_in_way then
            wesnoth.put_unit(unit_in_way)
        end
    end


    -- We only consider these leader threats, if they either
    --   - maximum damage reduces current HP by more than 50%
    --   - average damage is more than 25% of max HP
    -- Otherwise we assume the leader can deal with them alone
    leader_threats.significant_threat = FS.is_significant_threat(leader_proxy, av_total_loss, max_total_loss)
    DBG.print_debug('ops_output', '  significant_threat', leader_threats.significant_threat)

    -- Only count leader threats if they are significant
    if (not leader_threats.significant_threat) then
        leader_threats.enemies = {}
    end

    leader_threats.leader_protect_value_ratio = 1
    if leader_threats.significant_threat then
        -- TODO: This is likely too simple. Should also depend on whether we can
        --   protect the leader, and how much of our own units are close
        -- Want essentially infinite aggression when there are so many enemies
        -- that the average attack by all of them would kill the leader (even if
        -- not all of them can reach the leader simultaneously)
        local vr = 1 - av_total_loss / leader_info.hitpoints
        if (vr < 0.01) then vr = 0.01 end
        leader_threats.leader_protect_value_ratio  = vr
    end
    DBG.print_debug('ops_output', '  leader_protect_value_ratio', leader_threats.leader_protect_value_ratio)


    -- Note that 'perp_map' covers the entire map, while 'leader_zone_map' is only the zone
    local leader_zone_map, perp_map = {}, {}
    if leader_threats.significant_threat then
        local goal_loc = leader_objectives.final

        local enemies = {}
        for enemy_id,_ in pairs(leader_threats.enemies) do
            local enemy_loc = fred_data.move_data.units[enemy_id]
            enemies[enemy_id] = enemy_loc
        end
        --DBG.dbms(enemies, false, 'enemies')

        local between_map = FU.get_between_map({ goal_loc }, goal_loc, enemies, fred_data.move_data)

        for x,y,between in FGM.iter(between_map) do
            if between.is_between then
                FGM.set_value(leader_zone_map, x, y, 'in_zone', true)
                FGM.set_value(perp_map, x, y, 'perp', between.perp_distance)
            end
        end

        if false then
            DBG.show_fgumap_with_message(between_map, 'distance', 'assess_leader_threats between_map: distance')
            DBG.show_fgumap_with_message(between_map, 'perp_distance', 'assess_leader_threats between_map: perp_distance')
            DBG.show_fgumap_with_message(between_map, 'is_between', 'assess_leader_threats between_map: is_between')
        end
        --DBG.show_fgumap_with_message(leader_zone_map, 'in_zone', 'assess_leader_threats leader_zone_map')
        --DBG.show_fgumap_with_message(perp_map, 'perp', 'assess_leader_threats perp_map')
    end


    if leader_objectives.do_recruit then
        -- Now find prerecruits so that they are in between leader and threats
        -- TODO: is there a way of doing this without duplicating the prerecruit eval from before?
        local castle_rating_map = {}
        for x,y,_ in FGM.iter(move_data.reachable_castles_map[wesnoth.current.side]) do
            for enemy_id,_ in pairs(leader_threats.enemies) do
                local max_moves_left = 0
                for xa,ya in H.adjacent_tiles(x, y) do
                    local moves_left = FGM.get_value(fred_data.turn_data.enemy_initial_reach_maps[enemy_id], xa, ya, 'moves_left')
                    if moves_left then
                        -- to distinguish moves_left = 0 from unreachable hexes
                        moves_left = moves_left + 1
                        if (moves_left > max_moves_left) then
                            max_moves_left = moves_left
                        end
                    end
                end

                -- We also simply add, rather than taking an average, in order
                -- to emphasize hexes that can be reach by several units
                FGM.add(castle_rating_map, x, y, 'rating', max_moves_left)
            end
        end
        --DBG.show_fgumap_with_message(castle_rating_map, 'rating', 'castle_rating_map')

        local outofway_units = {}
        -- Note that the leader is included in the following, as he might
        -- be on a castle hex other than a keep. His recruit location is
        -- automatically excluded by the prerecruit code
        for id,_ in pairs(move_data.my_units_can_move_away) do
            outofway_units[id] = true
        end

        local x, y = leader[1], leader[2]
        if leader_objectives.keep then
            x, y = leader_objectives.keep[1], leader_objectives.keep[2]
        end
        local cfg = { castle_rating_map = castle_rating_map, outofway_penalty = -0.1 }
        prerecruit = fred_data.recruit:prerecruit_units({ x, y }, nil, outofway_units, cfg)
        --DBG.dbms(prerecruit, false, 'prerecruit')

        if prerecruit.units[1] then
            leader_objectives.prerecruit = prerecruit
        end
    end
    --DBG.dbms(leader_threats, false, 'leader_threats')

    leader_objectives.leader_threats = leader_threats

    return leader_zone_map, perp_map
end


return fred_move_leader_utils
