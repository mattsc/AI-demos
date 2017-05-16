--[=[
Functions to support the retreat of injured units
]=]

local H = wesnoth.require "lua/helper.lua"
local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
local BC = wesnoth.require "~/add-ons/AI-demos/lua/battle_calcs.lua"
local LS = wesnoth.require "lua/location_set.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local retreat_functions = {}

function retreat_functions.get_healing_locations()
    local possible_healer_proxies = AH.get_live_units {
        { "filter_side", {{ "allied_with", {side = wesnoth.current.side } }} }
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
                    local old_values = healing_locs:get(x, y) or {0, 0}
                    local best_heal = math.max(old_values[1], heal_amount)
                    local best_cure = math.max(old_values[2], cure)
                    healing_locs:insert(x, y, {best_heal, best_cure})
                end
            end
        end
    end

    return healing_locs
end

function retreat_functions.find_best_retreat(retreaters, retreat_utilities, gamedata)
    -- Only retreat to safe locations
    local enemie_proxies = AH.get_live_units {
        { "filter_side", {{ "enemy_of", { side = wesnoth.current.side }} } }
    }
    local enemy_attack_map = BC.get_attack_map(enemie_proxies)

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
            local healer_values = healing_locs:get(x, y) or {0, 0}
            heal_amount = math.max(heal_amount, healer_values[1])

            if (x == loc[1]) and (y == loc[2]) and (not gamedata.unit_infos[id].status.poisoned) then
                heal_amount = heal_amount + 2
            end

            heal_amount = math.min(heal_amount, gamedata.unit_infos[id].max_hitpoints - gamedata.unit_infos[id].hitpoints)

            if (heal_amount > 0) then
                FU.set_fgumap_value(heal_maps[id], x, y, 'heal_amount', heal_amount)
            end
        end
    end
    --DBG.dbms(heal_maps)

    local max_rating, best_loc, best_id
    for id,heal_map in pairs(heal_maps) do
        local base_rating = retreat_utilities[id]
        base_rating = base_rating * 1000
        --print(id, 'base_rating: ' .. base_rating)

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

            -- Penalty based on (bad) terrain defense for unit
            rating = rating - wesnoth.unit_defense(gamedata.unit_copies[id], wesnoth.get_terrain(x, y))/100.

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

            -- For now, we only consider safe hexes (no enemy threat at all)
            local enemy_count = enemy_attack_map.units:get(x, y) or 0
            if (enemy_count == 0) then
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

    return best_id, best_loc
end

return retreat_functions
