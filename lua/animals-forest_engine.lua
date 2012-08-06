return {
    init = function(ai)

        local forest_animals = {}

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        local LS = wesnoth.require "lua/location_set.lua"
        local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

        function forest_animals:new_rabbit_eval()
            -- If there are fewer than 4-6 rabbits out there, we get some more out of their holes
            -- I want this to happen only once, at the beginning of the turn, so 
            -- I'll let the CA blacklist itself
            return 310000
        end

        function forest_animals:new_rabbit_exec()
            -- Get the locations of all the rabbit holes
            W.store_items { variable = 'holes_wml' }
            local holes = H.get_variable_array('holes_wml')
            W.clear_variable { name = 'holes_wml' }
            --DBG.dbms(holes)

            -- Eliminate all holes that have an enemy within 3 hexes
            -- This is less than max_moves of rabbits, but real rabbits might do that too (they are dumb1)
            -- We also add a random number to it, for selection of the holes later
            --print('before:', #holes)
            for i = #holes,1,-1 do
                local enemies = wesnoth.get_units { 
                    { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} },
                    { "filter_location", { x = holes[i].x, y = holes[i].y, radius = 3 } }
                }
                if enemies[1] then 
                    table.remove(holes, i)
                else
                    holes[i].random = AH.random(100)
                end
            end
            --print('after:', #holes)
            table.sort(holes, function(a, b) return a.random > b.random end)
            --DBG.dbms(holes)

            -- Number of rabbits to put out there
            local rabbits = wesnoth.get_units { side = wesnoth.current.side, type = 'Rabbit' }
            local number = AH.random(4, 6)
            --print('total number:', number)
            number = number - #rabbits
            --print('to add number:', number)
            number = math.min(number, #holes)
            --print('to add number possible:', number)

            -- Now we just can take the first 'number' (randomized) holes
            local tmp_unit = wesnoth.get_units { side = wesnoth.current.side }[1]
            for i = 1,number do
                local x, y = -1, -1
                if tmp_unit then
                    x, y = wesnoth.find_vacant_tile(holes[i].x, holes[i].y, tmp_unit)
                else
                    x, y = wesnoth.find_vacant_tile(holes[i].x, holes[i].y)
                end
                wesnoth.scroll_to_tile(x, y)
                wesnoth.put_unit(x, y, { side = wesnoth.current.side, type = 'Rabbit' } )
            end
        end

        function forest_animals:tusker_attack_eval()
            -- Check whether there is an enemy next to a tusklet
            local tuskers = wesnoth.get_units { side = wesnoth.current.side, type = 'Tusker', formula = '$this_unit.moves > 0' }
            local adj_enemies = wesnoth.get_units { 
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} },
                { "filter_adjacent", { side = wesnoth.current.side, type = 'Tusklet' } }
            }
            --print('#tuskers, #adj_enemies', #tuskers, #adj_enemies)

            if tuskers[1] and adj_enemies[1] then
                return 300000
            else
                return 0
            end
        end

        function forest_animals:tusker_attack_exec()
            local tuskers = wesnoth.get_units { side = wesnoth.current.side, type = 'Tusker', formula = '$this_unit.moves > 0' }
            local adj_enemies = wesnoth.get_units { 
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} },
                { "filter_adjacent", { side = wesnoth.current.side, type = 'Tusklet' } }
            }

            -- Find the closest enemy to any tusker
            local min_dist, attacker, target = 9e99, {}, {}
            for i,t in ipairs(tuskers) do
                for j,e in ipairs(adj_enemies) do
                    local dist = H.distance_between(t.x, t.y, e.x, e.y)
                    if (dist < min_dist) then
                        min_dist = dist
                        attacker, target = t, e
                    end
                end
            end
            --print(attacker.id, target.id)

            -- The tusker moves as close to enemy as possible
            -- Closeness to tusklets is secondary criterion
            local adj_tusklets = wesnoth.get_units { side = wesnoth.current.side, type = 'Tusklet',
                { "filter_adjacent", { id = target.id } }
            }

            local best_hex = AH.find_best_move(attacker, function(x, y)
                local rating = - H.distance_between(x, y, target.x, target.y)
                for i,t in ipairs(adj_tusklets) do
                    if (H.distance_between(x, y, t.x, t.y) == 1) then rating = rating + 0.1 end
                end

                return rating
            end)
            --print('attacker', attacker.x, attacker.y, ' -> ', best_hex[1], best_hex[2])
            AH.movefull_stopunit(ai, attacker, best_hex)

            -- If adjacent, attack
            local dist = H.distance_between(attacker.x, attacker.y, target.x, target.y)
            if (dist == 1) then
                ai.attack(attacker, target)
            else
                ai.stopunit_attacks(attacker)
            end
        end

        function forest_animals:move_eval()
            local units = wesnoth.get_units { side = wesnoth.current.side, type = 'Deer,Rabbit,Tusker', formula = '$this_unit.moves > 0' }
            local tusklets = wesnoth.get_units { side = wesnoth.current.side, type = 'Tusklet', formula = '$this_unit.moves > 0' }
            local all_tuskers = wesnoth.get_units { side = wesnoth.current.side, type = 'Tusker' }

            -- If there are deer, rabbits or tuskers with moves left -> good
            if units[1] then return 290000 end
            -- Or, we move tusklets with this CA, if no tuskers are left (counting those without moves also)
            if (not all_tuskers[1]) and tusklets[1] then return 290000 end
            return 0
        end

        function forest_animals:move_exec()
            -- I want the deer/rabbits to move first, tuskers later
            local units = wesnoth.get_units { side = wesnoth.current.side, type = 'Deer,Rabbit', formula = '$this_unit.moves > 0' }
            local tuskers = wesnoth.get_units { side = wesnoth.current.side, type = 'Tusker', formula = '$this_unit.moves > 0' }
            for i,t in ipairs(tuskers) do table.insert(units, t) end

            -- Also add tusklets if there are no tuskers left
            local all_tuskers = wesnoth.get_units { side = wesnoth.current.side, type = 'Tusker' }
            if not all_tuskers[1] then
                local tusklets = wesnoth.get_units { side = wesnoth.current.side, type = 'Tusklet', formula = '$this_unit.moves > 0' }
                for i,t in ipairs(tusklets) do table.insert(units, t) end
            end

            -- These animals run from any enemy
            local enemies = wesnoth.get_units {  { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} } }
            --print('#units, enemies', #units, #enemies)

            -- Get the locations of all the rabbit holes
            W.store_items { variable = 'holes_wml' }
            local holes = H.get_variable_array('holes_wml')
            W.clear_variable { name = 'holes_wml' }
            --DBG.dbms(holes)
            local hole_map = LS.create()
            for i,h in ipairs(holes) do hole_map:insert(h.x, h.y, 1) end
            --AH.put_labels(hole_map)

            -- Each unit moves independently
            for i,unit in ipairs(units) do
                --print('Unit', i, unit.x, unit.y)
                -- Behavior is different depending on whether a predator is close or not
                local close_enemies = {}
                for j,e in ipairs(enemies) do
                    if (H.distance_between(unit.x, unit.y, e.x, e.y) <= unit.max_moves+1) then
                        table.insert(close_enemies, e)
                    end
                end
                --print('  #close_enemies', #close_enemies)

                -- If no close enemies, do a random move
                if (not close_enemies[1]) then
                    -- All hexes the unit can reach that are unoccupied
                    local reach = AH.get_reachable_unocc(unit)
                    --print('  #all reachable', reach:size())
                    -- Select only those that are forest
                    local reachable_forest = {}
                    reach:iter( function(x, y, v)
                        local terrain = wesnoth.get_terrain(x,y)
                        --print(x, y, terrain)
                        if string.find(terrain, 'F', 2) then  -- doesn't work with '^', so start search at char 2
                            table.insert(reachable_forest, {x, y})
                        end
                    end)
                    --print('  #reachable_forest', #reachable_forest)

                    -- Choose one of the possible locations  at random
                    if reachable_forest[1] then
                        local rand = AH.random(#reachable_forest)
                        -- This is not a full move, as running away might happen next
                        if (unit.x ~= reachable_forest[rand][1]) or (unit.y ~= reachable_forest[rand][2]) then
                            ai.move(unit, reachable_forest[rand][1], reachable_forest[rand][2])
                        end
                    else  -- or if no close forest was found, move toward the closest
                        locs = wesnoth.get_locations { terrain = '*^F*' }
                        local best_hex, min_dist = {}, 9e99
                        for j,l in ipairs(locs) do
                            local d = H.distance_between(l[1], l[2], unit.x, unit.y)
                            if d < min_dist then
                                best_hex, min_dist = l,d
                            end
                        end
                        local x, y = wesnoth.find_vacant_tile(best_hex[1], best_hex[2], unit)
                        local next_hop = AH.next_hop(unit, x, y)
                        --print(next_hop[1], next_hop[2])
                        if (unit.x ~= next_hop[1]) or (unit.y ~= next_hop[2]) then
                            ai.move(unit, next_hop[1], next_hop[2])
                        end
                    end
                end

                -- Now we check for close enemies again, as we might just have moved within reach of some
                local close_enemies = {}
                for j,e in ipairs(enemies) do
                    if (H.distance_between(unit.x, unit.y, e.x, e.y) <= unit.max_moves+1) then
                        table.insert(close_enemies, e)
                    end
                end
                --print('  #close_enemies after move', #close_enemies, #enemies, unit.id)

                -- If there are close enemies, run away (and rabbits disappear into holes)
                if close_enemies[1] then 
                    -- Calculate the hex that maximizes distance of unit from enemies
                    -- Returns nil if the only hex that can be reached is the one the unit is on
                    local farthest_hex = AH.find_best_move(unit, function(x, y)
                        local rating = 0
                        for i,e in ipairs(close_enemies) do
                            local d = H.distance_between(e.x, e.y, x, y)
                            rating = rating - 1 / d^2
                        end
                        -- If this is a rabbit, try to go for holes
                        if (unit.type == 'Rabbit') and hole_map:get(x, y) then 
                            rating = rating + 1000
                            -- but if possible, go to another hole
                            if (x == unit.x) and (y == unit.y) then rating = rating - 10 end
                        end

                        return rating
                    end)
                    --print('  farthest_hex: ', farthest_hex[1], farthest_hex[2])
        
                    -- This will always find at least the hex the unit is on
                    -- so no check is necessary
                    AH.movefull_stopunit(ai, unit, farthest_hex)
                    -- If this is a rabbit ending on a hole -> disappears
                    if (unit.type == 'Rabbit') and hole_map:get(farthest_hex[1], farthest_hex[2]) then 
                        wesnoth.put_unit(farthest_hex[1], farthest_hex[2])
                    end
                end

                -- Finally, take moves away, as only partial move might have been done
                -- Also attacks, as these units never attack
                if unit and unit.valid then ai.stopunit_all(unit) end
                -- Need this ^ test here because bunnies might have disappeared
            end
        end

        function forest_animals:tusklet_eval()
            local tusklets = wesnoth.get_units { side = wesnoth.current.side, type = 'Tusklet', formula = '$this_unit.moves > 0' }
            local tuskers = wesnoth.get_units { side = wesnoth.current.side, type = 'Tusker' }

            if tusklets[1] and tuskers[1] then
                return 280000
            else
                return 0
            end
        end

        function forest_animals:tusklet_exec()
            -- Tusklets will simply move toward the closest tusker, without regard for anything else
            -- Except if no tuskers are left, in which case the previous CA takes over for random move
            local tusklets = wesnoth.get_units { side = wesnoth.current.side, type = 'Tusklet', formula = '$this_unit.moves > 0' }
            local tuskers = wesnoth.get_units { side = wesnoth.current.side, type = 'Tusker' }
            --print('#tusklets, #tuskers', #tusklets, #tuskers)

            for i,tusklet in ipairs(tusklets) do
                -- find closest tusker
                local goto_tusker = {}
                local min_dist = 9999
                for i,t in ipairs(tuskers) do 
                    local dist = H.distance_between(t.x, t.y, tusklet.x, tusklet.y)
                    if (dist < min_dist) then
                        min_dist = dist
                        goto_tusker = t
                    end
                end
                --print('closets tusker:', goto_tusker.x, goto_tusker.y, goto_tusker.id)

                -- Move tusklet toward that tusker
                local best_hex = AH.find_best_move(tusklet, function(x, y)
                    return -H.distance_between(x, y, goto_tusker.x, goto_tusker.y)
                end)
                --print('tusklet', tusklet.x, tusklet.y, ' -> ', best_hex[1], best_hex[2])
                AH.movefull_stopunit(ai, tusklet, best_hex)

                -- Also make sure tusklets never attack
                ai.stopunit_all(tusklet)
            end
        end

        return forest_animals	
    end
}
