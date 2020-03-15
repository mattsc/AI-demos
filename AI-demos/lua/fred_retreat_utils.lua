--[=[
Functions to support the retreat of injured units
]=]

local H = wesnoth.require "helper"
local AH = wesnoth.require "ai/lua/ai_helper.lua"
local FGM = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_map.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local FCFG = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_config.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"
local COMP = wesnoth.require "~/add-ons/AI-demos/lua/compatibility.lua"

local retreat_functions = {}

function retreat_functions.get_healing_map()
    local possible_healer_proxies = AH.get_live_units {
        { "filter_side", {{ "allied_with", { side = wesnoth.current.side } }} }
    }

    local healing_map = {}
    for _,u in ipairs(possible_healer_proxies) do
        -- Only consider healers that cannot move this turn
        if u.moves == 0 or u.side ~= wesnoth.current.side then
            local heal_amount = 0
            local cure = 0
            local abilities = wml.get_child(u.__cfg, "abilities") or {}
            for ability in wml.child_range(abilities, "heals") do
                heal_amount = ability.value or 1
                if ability.poison == "slowed" then
                    if (cure < 1) then cure = 1 end
                elseif ability.poison == "cured" then
                    if (cure < 2) then cure = 2 end
                end
            end
            if heal_amount + cure > 0 then
                for x, y in H.adjacent_tiles(u.x, u.y) do
                    local old_values = FGM.get_value(healing_map, x, y, 'heal') or { 0, 0 }
                    local best_heal = math.max(old_values[1], heal_amount)
                    local best_cure = math.max(old_values[2], cure)
                    FGM.set_value(healing_map, x, y, 'heal', { best_heal, best_cure })
                end
            end
        end
    end
    --DBG.dbms(healing_map, false, 'healing_map')

    return healing_map
end

function retreat_functions.find_best_retreat(retreaters, retreat_utilities, fred_data)
    local move_data = fred_data.move_data

    ----- Begin retreat_damages() -----
    local function retreat_damages(id, x, y, hitchance, unit_attacks, move_data)
        -- For now, we add up the maximum damage from all enemies that can reach the
        -- hex, and if it is less than the unit's HP, consider this a valid retreat location
        -- Potential TODO: do actual counter attack evaluation

        local enemy_ids = FGM.get_value(move_data.enemy_attack_map[1], x, y, 'ids')
        local max_damage, av_damage = 0, 0
        if enemy_ids then
            for _,enemy_id in ipairs(enemy_ids) do
                local damage = unit_attacks[id][enemy_id].damage_counter.max_taken_any_weapon
                --std_print('  ' .. x, y, enemy_id, damage, hitchance)
                max_damage = max_damage + damage
                av_damage = av_damage + damage * hitchance
            end
        end
        --std_print('    ' .. max_damage, av_damage)

        return max_damage, av_damage
    end
    ----- End retreat_damages() -----

    ----- Begin retreat_rating() -----
    local function retreat_rating(id, x, y, heal_amount, no_damage_limit)
        local hitchance = COMP.unit_defense(move_data.unit_copies[id], wesnoth.get_terrain(x, y)) / 100.
        local max_damage, av_damage = retreat_damages(id, x, y, hitchance, fred_data.ops_data.unit_attacks, move_data)

        if no_damage_limit or (max_damage < move_data.unit_infos[id].hitpoints) then
            local rating = (heal_amount - av_damage) * 100

            -- Give small bonus for poison, but that should already be covered in
            -- retreat_utilities, so this is really just a tie breaker
            -- Potential TODO: also check that the location actually cures
            if move_data.unit_infos[id].status.poisoned then
                rating = rating + 1
            end

            -- Small bonus for terrain defense
            rating = rating + (1 - hitchance)

            -- Potential TODO: it's not a priori clear whether the av_damage contribution should be
            -- multiplied by 1/retreat_utility instead. Depending on the point of view,
            -- both make some sense. Reconsider more carefully later.
            rating = rating * retreat_utilities[id]

            -- Penalty if a unit has to move out of the way
            -- Small base penalty plus damage of moving unit
            -- Both of these are small though, really just meant as tie breakers
            -- Units with MP are taken off the map at this point, so cannot just check the map
            local uiw_id = FGM.get_value(move_data.my_unit_map_MP, x, y, 'id')
            --std_print(id, x, y, uiw_id)
            if uiw_id and (uiw_id ~= id) then
                rating = rating - 0.01
                rating = rating + (move_data.unit_infos[uiw_id].hitpoints - move_data.unit_infos[uiw_id].max_hitpoints) / 100.
            end

            -- Finally, all else being equal, retreat toward the leader when there is
            -- a threat, or away from the leader when there is not
            local retreat_direction = 1
            if (av_damage > 0) then retreat_direction = -1 end
            local ld = FGM.get_value(fred_data.ops_data.leader_distance_map, x, y, 'distance')
            rating = rating + retreat_direction * ld / 1000

            return rating
        end
    end
    ----- End retreat_rating() -----


    local healing_map = retreat_functions.get_healing_map()

    local heal_maps_regen, heal_maps_no_regen = {}, {}
    for id,loc in pairs(retreaters) do
        if move_data.unit_infos[id].abilities.regenerate then
            heal_maps_regen[id] = {}
        else
            heal_maps_no_regen[id] = {}
        end

        for x,y,_ in FGM.iter(move_data.effective_reach_maps[id]) do
            local heal_amount = 0

            if move_data.unit_infos[id].abilities.regenerate then
                heal_amount = 8
            else
                heal_amount = wesnoth.get_terrain_info(wesnoth.get_terrain(x, y)).healing or 0
            end

            -- Potential TODO: curing is currently not evaluated (even though it is added for healers)
            local healer_values = FGM.get_value(healing_map, x, y, 'heal') or { 0, 0 }
            heal_amount = math.max(heal_amount, healer_values[1])

            -- Note: cannot use 'resting' parameter in unit_proxy to assess rest healing.
            -- At least in 1.12 it does not seem to get unset when the unit moves
            if (x == loc[1]) and (y == loc[2])
                and (move_data.unit_infos[id].moves == move_data.unit_infos[id].max_moves)
                and (not move_data.unit_infos[id].status.poisoned)
            then
                heal_amount = heal_amount + 2
            end

            heal_amount = math.min(heal_amount, move_data.unit_infos[id].max_hitpoints - move_data.unit_infos[id].hitpoints)

            if (heal_amount > 0) then
                if move_data.unit_infos[id].abilities.regenerate then
                    FGM.set_value(heal_maps_regen[id], x, y, 'heal_amount', heal_amount)
                else
                    FGM.set_value(heal_maps_no_regen[id], x, y, 'heal_amount', heal_amount)
                end
            end
        end
    end

    if DBG.show_debug('retreat_heal_maps') then
        for id,heal_map in pairs(heal_maps_no_regen) do
            DBG.show_fgm_with_message(heal_map, 'heal_amount', 'Heal map (no-regen unit)', move_data.unit_copies[id])
        end
        for id,heal_map in pairs(heal_maps_regen) do
            DBG.show_fgm_with_message(heal_map, 'heal_amount', 'Heal map (regen unit)', move_data.unit_copies[id])
        end
    end


    -- No-regenerating units are dealt with first, and need to be considered
    -- together, as there are generally only a few healing locations available.
    -- Potential TODO: For now we always consider all units in one calculation. This might
    -- take too long on larger maps. Reconsider later if this becomes a problem.
    local tmp_dst_src, rating_map = {}, {}
    for id,heal_map in pairs(heal_maps_no_regen) do
        local unit_loc = move_data.units[id]
        local src = unit_loc[1] * 1000 + unit_loc[2]

        for x,y,data in FGM.iter(heal_map) do
            local dst = x * 1000 + y
            --std_print(id, x, y, src, dst)

            local rating = retreat_rating(id, x, y, data.heal_amount)

            if rating then
                FGM.set_value(rating_map, x, y, 'rating', rating)

                if (not tmp_dst_src[dst]) then tmp_dst_src[dst] = { dst = dst } end
                table.insert(tmp_dst_src[dst], { src = src, rating = rating })
            end
        end

        if DBG.show_debug('retreat_unit_rating') then
            DBG.show_fgm_with_message(rating_map, 'rating', 'Retreat rating map (no-regen unit)', move_data.unit_copies[id])
        end
    end
    --DBG.dbms(tmp_dst_src, false, 'tmp_dst_src')

    if next(tmp_dst_src) then
        local dst_src = {}
        for _,data in pairs(tmp_dst_src) do
            table.insert(dst_src, data)
        end
        --DBG.dbms(dst_src, false, 'dst_src')

        local tmp_combos = FU.get_unit_hex_combos(dst_src, true)
        --DBG.dbms(tmp_combos, false, 'tmp_combos')

        local combos, rest_heal_combos, rest_heal_amounts
        -- It seems like there should be an easier way to do the following ...
        for src,dst in pairs(tmp_combos) do
            local src_x,src_y = math.floor(src / 1000), src % 1000
            local dst_x,dst_y = math.floor(dst / 1000), dst % 1000
            local id = move_data.my_unit_map[src_x][src_y].id
            local heal_amount = heal_maps_no_regen[id][dst_x][dst_y].heal_amount
            --std_print(src, src_x, src_y, id, heal_amount)

            -- Just rest healign is not necessarily worth it
            if (heal_amount > 2) then
                if (not combos) then combos = {} end
                combos[src] = dst
            else
                if (not rest_heal_combos) then
                    rest_heal_combos = {}
                    rest_heal_amounts = {}
                end
                rest_heal_combos[src] = dst
                rest_heal_amounts[id] = heal_amount
            end
        end

        if combos then return combos end
    end


    -- Now deal with regenerating units. As these each have many locations to
    -- choose from, they can be dealt with one at a time, prioritized by
    -- their retreat_utility
    local max_utility, best_id = - math.huge
    for id,_ in pairs(heal_maps_regen) do
        if (retreat_utilities[id] > max_utility) then
            best_id = id
            max_utility = retreat_utilities[id]
        end
    end

    if best_id then
        local max_rating, best_loc = - math.huge
        local rating_map = {}
        for x,y,data in FGM.iter(heal_maps_regen[best_id]) do
            local rating = retreat_rating(best_id, x, y, data.heal_amount)
            --std_print(best_id, x, y, rating)

            if rating then
                FGM.set_value(rating_map, x, y, 'rating', rating)

                if (rating > max_rating) then
                    max_rating = rating
                    best_loc = { x, y }
                end
            end
        end

        if DBG.show_debug('retreat_unit_rating') then
            DBG.show_fgm_with_message(rating_map, 'rating', 'Retreat rating map (regen unit)', move_data.unit_copies[best_id])
        end

        if best_loc then
            local unit_loc = move_data.units[best_id]
            local src = unit_loc[1] * 1000 + unit_loc[2]
            local combo = {}
            combo[src] = best_loc[1] * 1000 + best_loc[2]

            return combo
        end
    end


    -- If we got here, then no direct retreat locations were found.
    -- Try to find some farther away
    -- This only makes sense for non-regenerating units.

    local retreaters_regen, retreaters_no_regen = {}, {}
    for id,loc in pairs(retreaters) do
        if move_data.unit_infos[id].abilities.regenerate then
            retreaters_regen[id] = loc
        else
            retreaters_no_regen[id] = loc
        end
    end
    --DBG.dbms(retreaters_no_regen, false, 'retreaters_no_regen')

    if next(retreaters_no_regen) then
        local max_rating, best_loc, best_id = - math.huge
        for id,loc in pairs(retreaters_no_regen) do
            -- First find all goal villages.  These are:
            --  - low threat
            --  - more than 1 turn away
            --  - no more than 3 turns away
            --  - worth moving that far (based on retreat_utility)

            local villages, min_turns = {}, math.huge
            for x,y,_ in FGM.iter(move_data.village_map) do
                local hitchance = COMP.unit_defense(move_data.unit_copies[id], wesnoth.get_terrain(x, y)) / 100.
                local max_damage, av_damage = retreat_damages(id, x, y, hitchance, fred_data.ops_data.unit_attacks, move_data)

                if (av_damage < move_data.unit_infos[id].hitpoints) then
                    local _,cost = wesnoth.find_path(move_data.unit_copies[id], x, y)
                    local int_turns = math.ceil(cost / move_data.unit_infos[id].max_moves)

                    -- Exclude 1-turn hexes as these might be occupied by a friendly unit
                    if (int_turns > 1) and (int_turns <= 3) then
                        -- This is really the required utility to make it worth it, rather than the utility of the village
                        local distance_utility = 1 - 1 / int_turns
                        if (retreat_utilities[id] >= distance_utility) then
                            --std_print(id, x, y, int_turns, distance_utility, retreat_utilities[id])
                            if (int_turns < min_turns) then
                                min_turns = int_turns
                            end

                            table.insert(villages, {
                                loc = { x, y },
                                int_turns = int_turns,
                                cost = cost,
                                av_damage = av_damage
                            })
                        end
                    end
                end
            end
            --DBG.dbms(villages, false, 'villages')

            if (not min_turns) then break end

            -- Only keep those that are no more than the closest of those away (in integer turns)
            -- That is, a region with 2 villages 2 turns away is better than one with one village
            -- But a region with 1 village at 2 turns and 1 at 3 turns is no better than that
            local goal_villages = {}
            for _,v in ipairs(villages) do
                if (v.int_turns == min_turns) then
                    FGM.set_value(goal_villages, v.loc[1], v.loc[2], 'int_turns', v.int_turns)
                    goal_villages[v.loc[1]][v.loc[2]].cost = v.cost
                end
            end
            --DBG.dbms(goal_villages, false, 'goal_villages')

            local rating_map = {}
            for x,y,_ in FGM.iter(move_data.effective_reach_maps[id]) do
                -- Consider only hexes with acceptable threats
                -- and only those that reduce the number of turns needed to get to the goal villages.
                -- Acceptable threats in this case are based on av_damage, not max_damage as above
                local hitchance = COMP.unit_defense(move_data.unit_copies[id], wesnoth.get_terrain(x, y)) / 100.
                local max_damage, av_damage = retreat_damages(id, x, y, hitchance, fred_data.ops_data.unit_attacks, move_data)

                if (av_damage < move_data.unit_infos[id].hitpoints) then
                    local rating = 0

                    -- TODO: possibly find a more efficient way to do the following?
                    for xv,yv,vilage_data in FGM.iter(goal_villages) do
                        local old_x, old_y = move_data.unit_copies[id].x, move_data.unit_copies[id].y
                        local old_moves = move_data.unit_copies[id].moves
                        move_data.unit_copies[id].x, move_data.unit_copies[id].y = x, y
                        move_data.unit_copies[id].moves = move_data.unit_infos[id].max_moves
                        local _,cost = wesnoth.find_path(move_data.unit_copies[id], xv, yv)
                        local int_turns = math.ceil(cost / move_data.unit_infos[id].max_moves)
                        move_data.unit_copies[id].x, move_data.unit_copies[id].y = old_x, old_y
                        move_data.unit_copies[id].moves = old_moves
                        --std_print('  ' .. id, x, y, xv, yv, int_turns, vilage_data.int_turns)

                        -- Distance rating is the reduction of cost needed to get there
                        -- This is additive for all villages for this is true
                        if (cost < vilage_data.cost) then
                            rating = rating + vilage_data.cost - cost
                        end
                    end

                    local heal_amount = FGM.get_value(heal_maps_no_regen[id], x, y, 'heal_amount') or 0

                    -- We allow hexes that either pass the previous criterion, or that
                    -- are healing locations within one move that were previously
                    -- excluded because max_damage was too large.
                    -- The latter has a lower rating all else being equal (rating=0 so far),
                    -- as the former has other villages in close reach.
                    if (rating > 0) or (heal_amount > 0) then
                        -- Main rating, as above, is the damage rating, except when the heal_amount
                        -- is only rest healing, in which case it becomes a minor contribution
                        local heal_rating = retreat_rating(id, x, y, heal_amount, true)
                        if (heal_amount <= 2) then heal_rating = heal_rating / 1000 end
                        rating = rating + heal_rating

                        -- However, if there is a chance to die, we give a huge penalty,
                        -- larger than any healing benefit could be. In other words, we
                        -- prefer no healing but no chance to die over the opposite.
                        if (max_damage > move_data.unit_infos[id].hitpoints) then
                            rating = rating - 1000
                        end

                        FGM.set_value(rating_map, x, y, 'rating', rating)

                        if (rating > max_rating) then
                            max_rating = rating
                            best_loc = { x, y }
                            best_id = id
                        end
                    end
                end
            end

            if DBG.show_debug('retreat_unit_rating') then
                DBG.show_fgm_with_message(rating_map, 'rating', 'Retreat rating map (far villages)', move_data.unit_copies[id])
            end
        end

        if best_id then
            local unit_loc = move_data.units[best_id]
            local src = unit_loc[1] * 1000 + unit_loc[2]
            local combo = {}
            combo[src] = best_loc[1] * 1000 + best_loc[2]

            return combo
        end
    end
end

return retreat_functions
