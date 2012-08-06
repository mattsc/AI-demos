return {
    init = function(ai)

        local swarm = {}

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        local LS = wesnoth.require "lua/location_set.lua"
        local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

        function swarm:scatter_swarm_eval()
            -- Any enemy within 1 hex of a unit will cause swarm to scatter
            local enemies = wesnoth.get_units { 
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} },
                { "filter_location", 
                    { radius = 1, { "filter", { side = wesnoth.current.side } } }
                }
            }
            -- Could do this with filter_adjacent, but want radius to be adjustable

            if enemies[1] then  -- don't use 'formula=' for moves, it's slow
                local units = wesnoth.get_units { side = wesnoth.current.side }
                for i,u in ipairs(units) do
                    if (u.moves > 0) then return 300000 end
                end
            end

            return 0
        end

        function swarm:scatter_swarm_exec()
            -- Any enemy within 3 hexes of a unit will cause swarm to scatter
            local units = wesnoth.get_units { side = wesnoth.current.side }
            for i = #units,1,-1 do
                if (units[i].moves == 0) then table.remove(units, i) end
            end

            local enemies = wesnoth.get_units { 
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} },
                { "filter_location", 
                    { radius = 3, { "filter", { side = wesnoth.current.side } } }
                }
            }

            -- In this case we simply maximize the distance from all these close enemies
            -- but only for units that are within 'vision_radius' of one of those enemies
            local vision_radius = 8
            for i,unit in ipairs(units) do
                local unit_enemies = {}
                for i,e in ipairs(enemies) do
                    if (H.distance_between(unit.x, unit.y, e.x, e.y) <= vision_radius) then
                        table.insert(unit_enemies, e)
                    end
                end

                if unit_enemies[1] then
                    local best_hex = AH.find_best_move(unit, function(x, y)
                        local rating = 0
                        for i,e in ipairs(unit_enemies) do
                            rating = rating + H.distance_between(x, y, e.x, e.y)
                        end
                        return rating
                    end)

                    AH.movefull_stopunit(ai, unit, best_hex)
                end
            end
        end

        function swarm:move_swarm_eval()
            local units = wesnoth.get_units { side = wesnoth.current.side }
            for i,u in ipairs(units) do
                if (u.moves > 0) then return 290000 end
            end

            return 0
        end

        function swarm:move_swarm_exec()
            -- If no close enemies, swarm will move semi-randomly, staying close together, but away from enemies
            local all_units = wesnoth.get_units { side = wesnoth.current.side }
            local units, units_no_moves = {}, {}
            for i,u in ipairs(all_units) do
                if (u.moves > 0) then
                    table.insert(units, u)
                else
                    table.insert(units_no_moves, u)
                end
            end

            local enemies = wesnoth.get_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }
            --print('#units, #units_no_moves, #enemies', #units, #units_no_moves, #enemies)

            -- pick a random unit and remove it from 'units'
            local rand = AH.random(#units)
            local unit = units[rand]
            table.remove(units, rand)

            -- Find best place for that unit to move to
            local vision_radius = unit.moves + 1 -- otherwise swamrs may split up
            local best_hex = AH.find_best_move(unit, function(x, y)
                local rating = 0

                -- Only units within 'vision_radius' count for rejoining
                local close_units_no_moves = {}
                for i,u in ipairs(units_no_moves) do
                    if (H.distance_between(unit.x, unit.y, u.x, u.y) <= vision_radius) then
                        table.insert(close_units_no_moves, u)
                    end
                end

                -- If all units on the side have moves left, simply go to a hex far away
                if (not close_units_no_moves[1]) then
                    rating = rating + H.distance_between(x, y, unit.x, unit.y)
                else  -- otherwise, minimize distance from units that have already moved
                    for i,u in ipairs(close_units_no_moves) do
                        rating = rating - H.distance_between(x, y, u.x, u.y)
                    end
                end

                -- We also try to stay out of attack range of any enemy
                local min_dist = 5
                for i,e in ipairs(enemies) do
                    local dist = H.distance_between(x, y, e.x, e.y)
                    -- If enemy is within attack range, avoid those hexes
                    if (dist < min_dist) then
                        rating = rating - (min_dist - dist) * 10.
                    end
                end

                return rating
            end)

            AH.movefull_stopunit(ai, unit, best_hex)
        end        

        return swarm	
    end
}
