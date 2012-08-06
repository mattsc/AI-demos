return {
    init = function(ai)
        local big_animals = {}

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        local LS = wesnoth.require "lua/location_set.lua"
        local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

        function big_animals:yeti_terrain(set)
            -- Remove locations from LS that are not mountains or hills
            set:iter( function(x, y, v)
               local yeti_terr = wesnoth.match_location(x, y, { terrain = 'M*,M*^*,H*,H*^*' })
               if (not yeti_terr) then set:remove(x, y) end
            end)
            return set
        end

        function big_animals:big_eval(types)
            local units = wesnoth.get_units { side = wesnoth.current.side, type = types, formula = '$this_unit.moves > 0' }

            if units[1] then return 300000 end
            return 0
        end

        function big_animals:big_exec(types)
            -- Big animals just move toward goal that gets set occasionally
            -- Avoid the other big animals (bears, yetis, spiders) and the dogs, otherwise attack whatever is in their range
            -- The only difference in behavior is the area in which the units move

            local units = wesnoth.get_units { side = wesnoth.current.side, type = types, formula = '$this_unit.moves > 0' }
            local avoid = LS.of_pairs(wesnoth.get_locations { radius = 1,
                { "filter", { type = 'Yeti,Giant Spider,Tarantula,Bear,Dog', 
                    { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
                } }
            })
            --AH.put_labels(avoid)

            for i,unit in ipairs(units) do
                -- Unit gets a new goal if none exist or on any move with 10% random chance
                local r = AH.random(10)
                if (not unit.variables.x) or (r == 1) then
                    local locs = {}
                    if (types == 'Bear') then
                        locs = wesnoth.get_locations { x = '1-40', y = '1-18', 
                            { "not", { terrain = '*^X*,Wo' } },
                            { "not", { x = unit.x, y = unit.y, radius = 12 } }
                        }
                    end
                    if (types == 'Giant Spider,Tarantula') then
                        locs = wesnoth.get_locations { terrain = 'H*' }
                    end
                    if (types == 'Yeti') then
                        locs = wesnoth.get_locations { terrain = 'M*' }
                    end
                    local rand = AH.random(#locs)
                    --print(types, ': #locs', #locs, rand)
                    unit.variables.x, unit.variables.y = locs[rand][1], locs[rand][2]
                end
                --print('Big animal goto: ', types, unit.variables.x, unit.variables.y, r)

                -- hexes the unit can reach
                local reach_map = AH.get_reachable_unocc(unit)
                -- If this is a yeti, we only keep mountain and hill terrain
                if (types == 'Yeti') then self:yeti_terrain(reach_map) end

                -- Now find the one of these hexes that is closest to the goal
                local max_rating = -9e99
                local best_hex = {}
                reach_map:iter( function(x, y, v)
                    -- Distance from goal is first rating
                    local rating = - H.distance_between(x, y, unit.variables.x, unit.variables.y)

                    -- Proximity to an enemy unit is a plus
                    local enemy_hp = 500
                    for xa, ya in H.adjacent_tiles(x, y) do
                        local enemy = wesnoth.get_unit(xa, ya)
                        if enemy and (enemy.side ~= wesnoth.current.side) then
                            if (enemy.hitpoints < enemy_hp) then enemy_hp = enemy.hitpoints end
                        end
                    end
                    rating = rating + 500 - enemy_hp  -- prefer attack on weakest enemy

                    -- However, hexes that enemy bears, yetis and spiders can reach get a massive negative hit
                    -- meaning that they will only ever be chosen if there's no way around them
                    if avoid:get(x, y) then rating = rating - 1000 end

                    reach_map:insert(x, y, rating)
                    if (rating > max_rating) then
                        max_rating = rating
                        best_hex = { x, y }
                    end
                end)
                --print('  best_hex: ', best_hex[1], best_hex[2])
                --AH.put_labels(reach_map)

                if (best_hex[1] ~= unit.x) or (best_hex[2] ~= unit.y) then
                    ai.move(unit, best_hex[1], best_hex[2])  -- partial move only
                else  -- If animal did not move, we need to stop it (also delete the goal)
                    ai.stopunit_moves(unit)
                    unit.variables.x = nil
                    unit.variables.y = nil
                end

                -- Or if this gets the unit to the goal, we also delete the goal
                if (unit.x == unit.variables.x) and (unit.y == unit.variables.y) then
                    unit.variables.x = nil
                    unit.variables.y = nil
                end

                -- Finally, if the unit ended up next to enemies, attack the weakest of those
                local min_hp = 9e99
                local target = {}
                for x, y in H.adjacent_tiles(unit.x, unit.y) do
                    local enemy = wesnoth.get_unit(x, y)
                    if enemy and (enemy.side ~= wesnoth.current.side) then
                        if (enemy.hitpoints < min_hp) then 
                            min_hp = enemy.hitpoints
                            target = enemy
                        end
                    end
                end
                if target.id then
                    ai.attack(unit, target)
                end

            end
        end

        return big_animals
    end
}
