--[=[
Functions to support the retreat of injured units
]=]

local H = wesnoth.require "lua/helper.lua"
local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
local LS = wesnoth.require "lua/location_set.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local retreat_functions = {}

function retreat_functions.damages(id, x, y, hitchance, unit_attacks, gamedata)
    -- For now, we add up the maximum damage from all enemies that can reach the
    -- hex, and if it is less than the unit's HP, consider this a valid retreat location
    -- TODO: possible improvements:
    --   - Don't use max_damage, or a better evaluation thereof
    --   - Only consider the number of units that can attack on the same turn

    local enemy_ids = FU.get_fgumap_value(gamedata.enemy_attack_map[1], x, y, 'ids')
    local max_damage, av_damage = 0, 0
    if enemy_ids then
        for _,enemy_id in ipairs(enemy_ids) do
            local damage = unit_attacks[id][enemy_id].damage_counter.base_taken
            --print('  ' .. x, y, enemy_id, damage, hitchance)
            max_damage = max_damage + damage
            av_damage = av_damage + damage * hitchance
        end
    end
    --print('    ' .. max_damage, av_damage)

    return max_damage, av_damage
end

function retreat_functions.get_healing_locations()
    local possible_healer_proxies = AH.get_live_units {
        { "filter_side", {{ "allied_with", { side = wesnoth.current.side } }} }
    }

    local healing_locs = LS.create()
    for _,u in ipairs(possible_healer_proxies) do
        -- Only consider healers that cannot move this turn
        if u.moves == 0 or u.side ~= wesnoth.current.side then
            local heal_amount = 0
            local cure = 0
            local abilities = H.get_child(u.__cfg, "abilities") or {}
            for ability in H.child_range(abilities, "heals") do
                heal_amount = ability.value
                if ability.poison == "slowed" then
                    if (cure < 1) then cure = 1 end
                elseif ability.poison == "cured" then
                    if (cure < 2) then cure = 2 end
                end
            end
            if heal_amount + cure > 0 then
                for x, y in H.adjacent_tiles(u.x, u.y) do
                    local old_values = healing_locs:get(x, y) or { 0, 0 }
                    local best_heal = math.max(old_values[1], heal_amount)
                    local best_cure = math.max(old_values[2], cure)
                    healing_locs:insert(x, y, { best_heal, best_cure })
                end
            end
        end
    end

    return healing_locs
end

function retreat_functions.find_best_retreat(retreaters, retreat_utilities, unit_attacks, gamedata)
    -- Only retreat to safe locations
    local healing_locs = retreat_functions.get_healing_locations()

    local heal_maps = {}
    for id,loc in pairs(retreaters) do
        heal_maps[id] = {}
        for x,y,_ in FU.fgumap_iter(gamedata.reach_maps[id]) do
            local heal_amount = 0

            if gamedata.unit_infos[id].abilities.regenerate then
                heal_amount = 8
            else
                heal_amount = wesnoth.get_terrain_info(wesnoth.get_terrain(x, y)).healing or 0
            end

            -- TODO: curing is currently not evaluated (even though it is added for healers)
            local healer_values = healing_locs:get(x, y) or { 0, 0 }
            heal_amount = math.max(heal_amount, healer_values[1])

            -- Note: cannot use 'resting' parameter in unit_proxy to assess rest healing.
            -- At least in 1.12 it does not seem to get unset when the unit moves
            if (x == loc[1]) and (y == loc[2])
                and (gamedata.unit_infos[id].moves == gamedata.unit_infos[id].max_moves)
                and (not gamedata.unit_infos[id].status.poisoned)
            then
                heal_amount = heal_amount + 2
            end

            heal_amount = math.min(heal_amount, gamedata.unit_infos[id].max_hitpoints - gamedata.unit_infos[id].hitpoints)

            if (heal_amount > 0) then
                FU.set_fgumap_value(heal_maps[id], x, y, 'heal_amount', heal_amount)
            end
        end
    end
    --DBG.dbms(heal_maps)

    -- TODO: There is a built-in inefficiency here, in that we always assess all
    -- units before returnning the result, while the score is mostly based on the
    -- retreat_utilities. However, the plan is to add assessment of all units in
    -- combination, so that they do not take retreat hexes away from each other.
    -- So for the time being, we leave this as is unless computing time will turn
    -- out to be a problem.
    -- However, we should likely at least be able to separate regenerating from
    -- non-regenerating units again.

    local max_rating, best_loc, best_id
    for id,heal_map in pairs(heal_maps) do
        local base_factor = 1000
        local base_rating = retreat_utilities[id]
        base_rating = base_rating * base_factor
        --print(id, 'base_rating: ' .. base_rating)

        -- We want non-regenerating units to retreat before regenerating units
        if (not gamedata.unit_infos[id].abilities.regenerate) then
            base_rating = base_rating + base_factor
        end

        local rating_map = {}
        for x,y,data in FU.fgumap_iter(heal_map) do
            --print(id, x, y)
            local rating = base_rating

            rating = rating + data.heal_amount

            -- TODO: should also check that the location actually cures
            -- Give small bonus for poison, but that should already be covered in
            -- retreat_utilities, so this is really just a tie breaker
            if gamedata.unit_infos[id].status.poisoned then
                rating = rating + 1
            end

            -- Small bonus for terrain defense
            local hitchance = wesnoth.unit_defense(gamedata.unit_copies[id], wesnoth.get_terrain(x, y)) / 100.
            rating = rating + (1 - hitchance)

            -- Penalty if a unit has to move out of the way
            -- Small base penalty plus damage of moving unit
            -- Both of these are small though, really just meant as tie breakers
            -- Units with MP are taken off the map at this point, so cannot just check the map
            local uiw_id = FU.get_fgumap_value(gamedata.my_unit_map_MP, x, y, 'id')
            --print(id, x, y, uiw_id)
            if uiw_id and (uiw_id ~= id) then
                rating = rating - 0.01
                rating = rating + (gamedata.unit_infos[uiw_id].hitpoints - gamedata.unit_infos[uiw_id].max_hitpoints) / 100.
            end

            local max_damage, av_damage = retreat_functions.damages(id, x, y, hitchance, unit_attacks, gamedata)
            if (max_damage < gamedata.unit_infos[id].hitpoints) then
                rating = rating - av_damage

                FU.set_fgumap_value(rating_map, x, y, 'rating', rating)

                if (not max_rating) or (rating > max_rating) then
                    max_rating = rating
                    best_loc = { x, y }
                    best_id = id
                end
            end
        end

        if false then
            FU.show_fgumap_with_message(rating_map, 'rating', 'Retreat rating map', gamedata.unit_copies[id])
        end
    end

    if best_id then
        return best_id, best_loc
    end


    -- If we got here, then no direct retreat locations were found.
    -- Try to find some farther away
    -- This only makes sense for non-regenerating units.

    local retreaters_regen, retreaters_no_regen = {}, {}
    for id,loc in pairs(retreaters) do
        if gamedata.unit_infos[id].abilities.regenerate then
            retreaters_regen[id] = loc
        else
            retreaters_no_regen[id] = loc
        end
    end
    --DBG.dbms(retreaters_no_regen)

    if next(retreaters_no_regen) then
        local unthreatened_villages_map = {}
        for x,y,_ in FU.fgumap_iter(gamedata.village_map) do
            if (not FU.get_fgumap_value(gamedata.enemy_attack_map[1], x, y, 'ids')) then
                FU.set_fgumap_value(unthreatened_villages_map, x, y, 'flag', true)
            end
        end
        --DBG.dbms(unthreatened_villages_map)

        local max_rating, best_loc, best_id
        for id,loc in pairs(retreaters_no_regen) do
            -- First find all goal villages.  These are:
            --  - unthreatened
            --  - more than 1 turn away
            --  - no more than 3 turns away
            --  - worth moving that far (based on retreat_utility)
            local villages, min_turns = {}
            for x,y,_ in FU.fgumap_iter(unthreatened_villages_map) do
                local _,cost = wesnoth.find_path(gamedata.unit_copies[id], x, y)
                local int_turns = math.ceil(cost / gamedata.unit_infos[id].max_moves)

                -- Exclude 1-turn hexes as these might be occupied by a friendly unit ot something
                if (int_turns > 1) and (int_turns <= 3) then
                    -- This is really the required utility to make it worth it, rather than the utility of the village
                    local distance_utility = 1 - 1 / int_turns
                    if (retreat_utilities[id] >= distance_utility) then
                        --print(id, x, y, int_turns, distance_utility, retreat_utilities[id])
                        if (not min_turns) or (int_turns < min_turns) then
                            min_turns = int_turns
                        end

                        table.insert(villages, {
                            loc = { x, y },
                            int_turns = int_turns,
                            cost = cost
                        })
                    end
                end
            end
            --DBG.dbms(villages)

            if (not min_turns) then break end

            -- Only keep those that are no more than the closest of those away (in integer turns)
            -- That is, a region with 2 villages 2 turns away is better than one with one village
            -- But a region with 1 village at 2 turns and 1 at 3 turns is no better than that
            local goal_villages = {}
            for _,v in ipairs(villages) do
                if (v.int_turns == min_turns) then
                    FU.set_fgumap_value(goal_villages, v.loc[1], v.loc[2], 'int_turns', v.int_turns)
                    goal_villages[v.loc[1]][v.loc[2]].cost = v.cost
                end
            end
            --DBG.dbms(goal_villages)

            local rating_map = {}
            for x,y,_ in FU.fgumap_iter(gamedata.reach_maps[id]) do
                -- Consider only hexes with acceptable threats
                -- and only those that reduce the number of turns needed to get to the goal villages.
                -- Acceptable threats in this case are based on av_damage, not max_damage as above
                local hitchance = wesnoth.unit_defense(gamedata.unit_copies[id], wesnoth.get_terrain(x, y)) / 100.
                local max_damage, av_damage = retreat_functions.damages(id, x, y, hitchance, unit_attacks, gamedata)

                if (av_damage < gamedata.unit_infos[id].hitpoints) then
                    local rating = 0

                    -- TODO: possibly find a more efficient way to do the following?
                    for xv,yv,v in FU.fgumap_iter(goal_villages) do
                        local old_x, old_y = gamedata.unit_copies[id].x, gamedata.unit_copies[id].y
                        local old_moves = gamedata.unit_copies[id].moves
                        gamedata.unit_copies[id].x, gamedata.unit_copies[id].y = x, y
                        gamedata.unit_copies[id].moves = gamedata.unit_infos[id].max_moves
                        local _,cost = wesnoth.find_path(gamedata.unit_copies[id], xv, yv)
                        local int_turns = math.ceil(cost / gamedata.unit_infos[id].max_moves)
                        gamedata.unit_copies[id].x, gamedata.unit_copies[id].y = old_x, old_y
                        gamedata.unit_copies[id].moves = old_moves
                        --print('  ' .. id, x, y, xv, yv, int_turns, v.int_turns)

                        -- Base rating is the reduction of moves needed to get there
                        -- This is additive for all villages for this is true
                        if (int_turns < v.int_turns) then
                            rating = rating + v.cost - cost
                        end
                    end

                    if (rating > 0) then
                        -- Small bonus for terrain defense
                        rating = rating + (1 - hitchance)

                        -- Penalty if a unit has to move out of the way
                        -- Small base penalty plus damage of moving unit
                        -- Both of these are small though, really just meant as tie breakers
                        -- Units with MP are taken off the map at this point, so cannot just check the map
                        local uiw_id = FU.get_fgumap_value(gamedata.my_unit_map_MP, x, y, 'id')
                        --print(id, x, y, uiw_id)
                        if uiw_id and (uiw_id ~= id) then
                            rating = rating - 0.01
                            rating = rating + (gamedata.unit_infos[uiw_id].hitpoints - gamedata.unit_infos[uiw_id].max_hitpoints) / 100.
                        end

                        -- We also add in the retreat_utility, but in this case it's only the tie breaker
                        rating = rating + retreat_utilities[id]

                        FU.set_fgumap_value(rating_map, x, y, 'rating', rating)

                        if (not max_rating) or (rating > max_rating) then
                            max_rating = rating
                            best_loc = { x, y }
                            best_id = id
                        end
                    end
                end
            end

            if false then
                FU.show_fgumap_with_message(rating_map, 'rating', 'Retreat rating map (far villages)', gamedata.unit_copies[id])
            end
        end

        if best_id then
            return best_id, best_loc
        end
    end
end

return retreat_functions
