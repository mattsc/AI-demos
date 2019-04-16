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
    for x,y,_ in FGM.iter(move_data.reachable_keeps_map[wesnoth.current.side]) do
        -- Note that reachable_keeps_map contains moves_left assuming max_mp for the leader.
        -- That's why we check reach_maps as well.
        local ml = FGM.get_value(move_data.reach_maps[leader.id], x, y, 'moves_left')
        if ml then
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
    if next(move_data.reachable_keeps_map[wesnoth.current.side]) then
        keeps_map = move_data.reachable_keeps_map[wesnoth.current.side]
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
        -- Note that reachable_keeps_map contains moves_left assuming max_mp for the leader.
        -- That's why we check reach_maps as well.
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

    if (move_data.unit_infos[leader.id].moves == 0) then
        return
    end

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
        for x,y,_ in FGM.iter(move_data.reachable_keeps_map[wesnoth.current.side]) do
            --std_print('keep: ' .. x .. ',' .. y)
            -- Note that reachable_keeps ignores other units, both own units and enemies
            -- So we need to check that the leader can get there first.
            -- This is the real reach_map
            local moves_left = FGM.get_value(move_data.reach_maps[leader.id], x, y, 'moves_left')
            if moves_left then
                --std_print('  in reach: ' .. x .. ',' .. y)
                local info = {
                    moves_left = moves_left
                }
                if (not keep_map) then keep_map = {} end
                FGM.set_value(keep_map, x, y, 'info', info)
            end
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
    --DBG.show_fgumap_with_message(hex_rating_map, 'rating', 'hex_rating_map', move_data.unit_copies[move_data.leaders[wesnoth.current.side].id])

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

    -- These are used for other purposes also, so they are not linked to whether we
    -- can reach the desired villages and keeps
    local effective_reach_map
    if prerecruit and prerecruit.units[1] then
        do_recruit = true
        effective_reach_map = get_reach_map_via_keep(leader, move_data)
    end
    -- Even if we want to recruit, we need the other effective_reach_map if no
    -- keep can be reached
    if (not effective_reach_map) or (not next(effective_reach_map)) then
        effective_reach_map = get_reach_map_to_keep(leader, move_data)
    end
    --DBG.show_fgumap_with_message(effective_reach_map, 'moves_left', 'effective_reach_map')

    -- If the eventual goal is a village, we do not need to rate the keep that we might
    -- stop by for recruiting. The village function will also return whatever keep
    -- works for getting to that village
    local village, keep
    village, keep, other = get_best_village_keep(leader, do_recruit, effective_reach_map, fred_data)
    --DBG.dbms(village, false, 'village')
    --DBG.dbms(keep, false, 'keep')
    --DBG.dbms(other, false, 'other')

    local leader_objectives = {
        village = village,
        keep = keep,
        other = other,
        final = village or keep or other or leader,
        do_recruit = do_recruit
    }

    return leader_objectives, effective_reach_map
end

function fred_move_leader_utils.assess_leader_threats(leader_objectives, assigned_enemies, side_cfgs, fred_data)
    local move_data = fred_data.move_data

    local leader = move_data.leaders[wesnoth.current.side]
    local leader_info = move_data.unit_infos[leader.id]
    local leader_proxy = wesnoth.get_unit(leader[1], leader[2])

    -- Threats are all enemies that can attack the castle (whether or not we go there)
    -- and the village (if we go there)
    local leader_threats = { enemies = {}, zones = {} }
    for x,y,_ in FGM.iter(move_data.reachable_castles_map[wesnoth.current.side]) do
        local ids = FGM.get_value(move_data.enemy_attack_map[1], x, y, 'ids') or {}
        for _,id in ipairs(ids) do
            leader_threats.enemies[id] = move_data.units[id][1] * 1000 + move_data.units[id][2]
        end
    end
    if leader_objectives.village then
        local ids = FGM.get_value(move_data.enemy_attack_map[1], leader_objectives.village[1], leader_objectives.village[2], 'ids') or {}
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
        leader_threats.zones[zone_id] = true
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
    leader_threats.significant_threat = FS.is_significant_threat(leader_proxy, av_total_loss, max_total_loss)
    DBG.print_debug('analysis', '  significant_threat', leader_threats.significant_threat)

    -- Only count leader threats if they are significant
    if (not leader_threats.significant_threat) then
        leader_threats.enemies = {}
        leader_threats.zones = {}
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
end


return fred_move_leader_utils
