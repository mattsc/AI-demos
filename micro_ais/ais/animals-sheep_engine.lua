return {
    init = function(ai)

        local sheep = {}

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        local LS = wesnoth.require "lua/location_set.lua"
        local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

        function sheep:herding_area(center_x, center_y)
            -- Find the area that the sheep can occupy
            -- First, find all contiguous grass hexes around center hex
            local herding_area = LS.of_pairs(wesnoth.get_locations {
                x = center_x, y = center_y, radius = 8,
                { "filter_radius", { terrain = 'G*' } }
            } )
            -- Then, exclude those next to the path made by the dogs
            herding_area:iter( function(x, y, v)
                for xa, ya in H.adjacent_tiles(x, y) do
                    if (wesnoth.get_terrain(xa, ya) == 'Rb') then herding_area:remove(x, y) end
                end
            end)
            --AH.put_labels(herding_area)

            return herding_area
        end

        function sheep:close_enemy_eval()
            -- Any enemy within 8 hexes of a sheep will get attention by the dogs
            local enemies = wesnoth.get_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} },
                { "filter_location",
                    { radius = 8, { "filter", { side = wesnoth.current.side, type = 'Ram,Sheep' } } }
                }
            }
            local dogs = wesnoth.get_units { side = wesnoth.current.side, type = 'Dog',
                formula = '$this_unit.moves > 0'
            }
            local sheep = wesnoth.get_units { side = wesnoth.current.side, type = 'Ram,Sheep' }

            if enemies[1] and dogs[1] and sheep[1] then return 300000 end
            return 0
        end

        function sheep:close_enemy_exec()
            local dogs = wesnoth.get_units { side = wesnoth.current.side, type = 'Dog',
                formula = '$this_unit.moves > 0' }
            local sheep = wesnoth.get_units { side = wesnoth.current.side, type = 'Ram,Sheep' }

            -- We start with enemies within 4 hexes, which will be attacked
            local enemies = wesnoth.get_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} },
                { "filter_location",
                    { radius = 4, { "filter", { side = wesnoth.current.side, type = 'Ram,Sheep' } } }
                }
            }

            max_rating, best_dog, best_enemy, best_hex = -9e99, {}, {}, {}
            for i,e in ipairs(enemies) do
                for j,d in ipairs(dogs) do
                    local reach_map = AH.get_reachable_unocc(d)
                    reach_map:iter( function(x, y, v)
                        -- most important: distance to enemy
                        local rating = - H.distance_between(x, y, e.x, e.y) * 100.
                        -- 2nd: distance from any sheep
                        for k,s in ipairs(sheep) do
                            rating = rating - H.distance_between(x, y, s.x, s.y)
                        end
                        -- 3rd: most distant dog goes first
                        rating = rating + H.distance_between(e.x, e.y, d.x, d.y) / 100.
                        reach_map:insert(x, y, rating)

                        if (rating > max_rating) then
                            max_rating = rating
                            best_hex = { x, y }
                            best_dog, best_enemy = d, e
                        end
                    end)
                    --AH.put_labels(reach_map)
                    --W.message { speaker = d.id, message = 'My turn' }
                end
            end

            -- If we found a move, we do it, and attack if possible
            if max_rating > -9e99 then
                    --print('Dog moving in to attack')
                    AH.movefull_stopunit(ai, best_dog, best_hex)
                    if H.distance_between(best_dog.x, best_dog.y, best_enemy.x, best_enemy.y) == 1 then
                        ai.attack(best_dog, best_enemy)
                    end
                return
            end

            -- If we got here, no enemies to attack where found, so we go on to block other enemies
            --print('Dogs: No enemies close enough to warrant attack')
            -- Now we get all enemies within 8 hexes
            local enemies = wesnoth.get_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} },
                { "filter_location",
                    { radius = 8, { "filter", { side = wesnoth.current.side, type = 'Ram,Sheep' } } }
                }
            }

            -- Find closest sheep/enemy pair first
            local min_dist, closest_sheep, closest_enemy = 9e99, {}, {}
            for i,e in ipairs(enemies) do
                for j,s in ipairs(sheep) do
                    local d = H.distance_between(e.x, e.y, s.x, s.y)
                    if d < min_dist then
                        min_dist = d
                        closest_sheep, closest_enemy = s, e
                    end
                end
            end
            --print('Closest enemy, sheep:', closest_enemy.id, closest_sheep.id)

            max_rating, best_dog, best_hex = -9e99, {}, {}
            for i,d in ipairs(dogs) do
                local reach_map = AH.get_reachable_unocc(d)
                reach_map:iter( function(x, y, v)
                    -- We want equal distance between enemy and closest sheep
                    local rating = - math.abs(H.distance_between(x, y, closest_sheep.x, closest_sheep.y) - H.distance_between(x, y, closest_enemy.x, closest_enemy.y)) * 100
                    -- 2nd: closeness to sheep
                    rating = rating - H.distance_between(x, y, closest_sheep.x, closest_sheep.y)
                    reach_map:insert(x, y, rating)
                    -- 3rd: most distant dog goes first
                    rating = rating + H.distance_between(closest_enemy.x, closest_enemy.y, d.x, d.y) / 100.
                    reach_map:insert(x, y, rating)

                    if (rating > max_rating) then
                        max_rating = rating
                        best_hex = { x, y }
                        best_dog = d
                    end
                end)
                --AH.put_labels(reach_map)
                --W.message { speaker = d.id, message = 'My turn' }
            end

            -- Move dog to intercept
            --print('Dog moving in to intercept')
            AH.movefull_stopunit(ai, best_dog, best_hex)
        end

        function sheep:sheep_runs_enemy_eval()
            -- Sheep runs from any enemy within 8 hexes (after the dogs have moved in)
            local sheep = wesnoth.get_units { side = wesnoth.current.side, type = 'Ram,Sheep',
                formula = '$this_unit.moves > 0',
                { "filter_location",
                    {
                        { "filter", { { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} } }
                        },
                        radius = 8
                    }
                }
            }

            if sheep[1] then return 295000 end
            return 0
        end

        function sheep:sheep_runs_enemy_exec()
            local sheep = wesnoth.get_units { side = wesnoth.current.side, type = 'Ram,Sheep',
                formula = '$this_unit.moves > 0',
                { "filter_location",
                    {
                        { "filter", { { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} } }
                        },
                        radius = 8
                    }
                }
            }

            -- Simply start with the first of these sheep
            sheep = sheep[1]
            -- And find the close enemies
            local enemies = wesnoth.get_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} },
                { "filter_location", { x = sheep.x, y = sheep.y , radius = 8 } }
            }
            --print('#enemies', #enemies)

            local best_hex = AH.find_best_move(sheep, function(x, y)
                local rating = 0
                for i,e in ipairs(enemies) do rating = rating + H.distance_between(x, y, e.x, e.y) end
                return rating
            end)

            AH.movefull_stopunit(ai, sheep, best_hex)
        end

        function sheep:sheep_runs_dog_eval()
            -- Any sheep with moves left next to a dog runs aways
            local sheep = wesnoth.get_units { side = wesnoth.current.side, type = 'Ram,Sheep',
                formula = '$this_unit.moves > 0',
                { "filter_adjacent", { side = wesnoth.current.side, type = 'Dog' } }
            }
            if sheep[1] then return 290000 end
            return 0
        end

        function sheep:sheep_runs_dog_exec()
            -- simply get the first sheep
            local sheep = wesnoth.get_units { side = wesnoth.current.side, type = 'Ram,Sheep',
                formula = '$this_unit.moves > 0',
                { "filter_adjacent", { side = wesnoth.current.side, type = 'Dog' } }
            }[1]
            -- and the first dog it is adjacent to
            local dog = wesnoth.get_units { side = wesnoth.current.side, type = 'Dog',
                { "filter_adjacent", { x = sheep.x, y = sheep.y } }
            }[1]

            local c_x, c_y = 32, 28
            -- If dog is farther from center, sheep moves in, otherwise it moves out
            local sign = 1
            if (H.distance_between(dog.x, dog.y, c_x, c_y) >= H.distance_between(sheep.x, sheep.y, c_x, c_y)) then
                sign = -1
            end
            local best_hex = AH.find_best_move(sheep, function(x, y)
                return H.distance_between(x, y, c_x, c_y) * sign
            end)
            AH.movefull_stopunit(ai, sheep, best_hex)
        end

        function sheep:herd_sheep_eval()
            -- If dogs have moves left, and there is a sheep with moves left outside the
            -- herding area, chase it back
            -- We'll do a bunch of nested if's, to speed things up
            local dogs = wesnoth.get_units { side = wesnoth.current.side, type = 'Dog', formula = '$this_unit.moves > 0' }
            if dogs[1] then
                local sheep = wesnoth.get_units { side = wesnoth.current.side, type = 'Ram,Sheep',
                    { "not", { { "filter_adjacent", { side = wesnoth.current.side, type = 'Dog' } } } }
                }
                if sheep[1] then
                    local herding_area = self:herding_area(32, 28)
                    for i,s in ipairs(sheep) do
                        -- If a sheep is found outside the herding area, we want to chase it back
                        if (not herding_area:get(s.x, s.y)) then return 280000 end
                    end
                end
            end

            -- If we got here, no valid dog/sheep combos were found
            return 0
        end

        function sheep:herd_sheep_exec()
            local dogs = wesnoth.get_units { side = wesnoth.current.side, type = 'Dog', formula = '$this_unit.moves > 0' }
            local sheep = wesnoth.get_units { side = wesnoth.current.side, type = 'Ram,Sheep',
                { "not", { { "filter_adjacent", { side = wesnoth.current.side, type = 'Dog' } } } }
            }
            local herding_area = self:herding_area(32, 28)
            local sheep_to_herd = {}
            for i,s in ipairs(sheep) do
                -- If a sheep is found outside the herding area, we want to chase it back
                if (not herding_area:get(s.x, s.y)) then table.insert(sheep_to_herd, s) end
            end

            -- Find the farthest out sheep that the dogs can get to (and that has moves left)

            -- Find all sheep that have stepped out of bound
            local sheep = wesnoth.get_units { side = wesnoth.current.side, type = 'Ram,Sheep' }
            local max_rating, best_dog, best_hex = -9e99, {}, {}
            local c_x, c_y = 32, 28
            for i,s in ipairs(sheep_to_herd) do
                -- This is the rating that depends only on the sheep's position
                -- Farthest sheep goes first
                local sheep_rating = H.distance_between(c_x, c_y, s.x, s.y) / 10.
                -- Sheep with no movement left gets big hit
                if (s.moves == 0) then sheep_rating = sheep_rating - 100. end

                for i,d in ipairs(dogs) do
                    local reach_map = AH.get_reachable_unocc(d)
                    reach_map:iter( function(x, y, v)
                        local dist = H.distance_between(x, y, s.x, s.y)
                        local rating = sheep_rating - dist
                        -- Needs to be on "far side" of sheep, wrt center for adjacent hexes
                        if (H.distance_between(x, y, c_x, c_y) <= H.distance_between(s.x, s.y, c_x, c_y))
                            and (dist == 1)
                        then rating = rating - 1000 end
                        -- And the closer dog goes first (so that it might be able to chase another sheep afterward)
                        rating = rating - H.distance_between(x, y, d.x, d.y) / 100.
                        -- Finally, prefer to stay on path, if possible
                        if (wesnoth.get_terrain(x, y) == 'Rb') then rating = rating + 0.001 end

                        reach_map:insert(x, y, rating)

                        if (rating > max_rating) then
                            max_rating = rating
                            best_dog = d
                            best_hex = { x, y }
                        end
                    end)
                    --AH.put_labels(reach_map)
                    --W.message{ speaker = d.id, message = 'My turn' }
                 end
            end

            -- Now we move the best dog
            -- If it's already in the best position, we just take moves away from it
            -- (to avoid black-listing of CA, in the worst case)
            if (best_hex[1] == best_dog.x) and (best_hex[2] == best_dog.y) then
                ai.stopunit_moves(best_dog)
            else
                --print('Dog moving to herd sheep')
                ai.move(best_dog, best_hex[1], best_hex[2])  -- partial move only
            end
        end

        function sheep:sheep_move_eval()
            -- If nothing else is to be done, the sheep do a random move
            local sheep = wesnoth.get_units { side = wesnoth.current.side, type = 'Ram,Sheep', formula = '$this_unit.moves > 0' }
            if sheep[1] then return 270000 end
            return 0
        end

        function sheep:sheep_move_exec()
            -- We simply move the first sheep first
            local sheep = wesnoth.get_units { side = wesnoth.current.side, type = 'Ram,Sheep', formula = '$this_unit.moves > 0' }[1]

            local reach_map = AH.get_reachable_unocc(sheep)
            -- Exclude those that are next to a dog, or more than 3 hexes away
            reach_map:iter( function(x, y, v)
                for xa, ya in H.adjacent_tiles(x, y) do
                    local dog = wesnoth.get_unit(xa, ya)
                    if dog and (dog.type == 'Dog') then
                        reach_map:remove(x, y)
                    end

                    if (H.distance_between(x, y, sheep.x, sheep.y) > 3) then
                        reach_map:remove(x, y)
                    end
                end
            end)
            --AH.put_labels(reach_map)

            -- Choose one of the possible locations  at random (or the current location, if no move possible)
            local x, y = sheep.x, sheep.y
            if (reach_map:size() > 0) then
                x, y = AH.LS_random_hex(reach_map)
                --print('Sheep -> :', x, y)
            end

            -- If this move remains within herding area or dogs have no moves left, or sheep doesn't move
            -- make it a full move, otherwise partial move
            local herding_area = self:herding_area(32, 28)
            local dogs = wesnoth.get_units { side = wesnoth.current.side, type = 'Dog', formula = '$this_unit.moves > 0' }
            if herding_area:get(x, y) or (not dogs[1]) or ((x == sheep.x) and (y == sheep.y)) then
                AH.movefull_stopunit(ai, sheep, x, y)
            else
                ai.move(sheep, x, y)
            end
        end

        function sheep:dog_move_eval()
            -- As a final step, any dog not adjacent to a sheep move along path
            local dogs = wesnoth.get_units { side = wesnoth.current.side, type = 'Dog',
                formula = '$this_unit.moves > 0',
                { "not", { { "filter_adjacent", { side = wesnoth.current.side, type = 'Ram,Sheep' } } } }
            }
            if dogs[1] then return 260000 end
            return 0
        end

        function sheep:dog_move_exec()
            -- We simply move the first dog first
            local dog = wesnoth.get_units { side = wesnoth.current.side, type = 'Dog',
                formula = '$this_unit.moves > 0',
                { "not", { { "filter_adjacent", { side = wesnoth.current.side, type = 'Ram,Sheep' } } } }
            }[1]

            local best_hex = AH.find_best_move(dog, function(x, y)
                -- Prefer hexes on road, otherwise at distance of 4 hexes from center
                local rating = 0
                if (wesnoth.get_terrain(x, y) == 'Rb') then
                    rating = rating + 1000 + AH.random(99) / 100.
                else
                    rating = rating - math.abs(H.distance_between(x, y, 32, 28) - 4)
                end

                return rating
            end)

            --print('Dog wandering')
            AH.movefull_stopunit(ai, dog, best_hex)
        end

        return sheep
    end
}
