return {
    init = function(ai)

        local wolves = {}

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        local LS = wesnoth.require "lua/location_set.lua"
        local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

        function wolves:wolves_eval()
            local wolves = wesnoth.get_units { side = wesnoth.current.side, type = 'Wolf', formula = '$this_unit.moves > 0' }
            -- Wolves hunt deer, but only close to the forest
            local prey = wesnoth.get_units { type = 'Deer', 
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} },
                { "filter_location", { terrain = '*^F*', radius = 3 } }
            }

            if wolves[1] and prey[1] then
                return 95000
            else
                return 0
            end
        end

        function wolves:wolves_exec()

            local wolves = wesnoth.get_units { side = wesnoth.current.side, type = 'Wolf', formula = '$this_unit.moves > 0' }
            -- Wolves hunt deer, but only close to the forest
            local prey = wesnoth.get_units { type = 'Deer', 
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} },
                { "filter_location", { terrain = '*^F*', radius = 3 } }
            }
            --print('#wolves, prey', #wolves, #prey)

            -- When wandering (later) they avoid dogs, but not here
            local avoid_units = wesnoth.get_units { type = 'Yeti,Giant Spider,Tarantula,Bear',
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }
            --print('#avoid_units', #avoid_units)
            -- negative hit for hexes the bears, spiders and yetis can attack
            local avoid = AH.attack_map(avoid_units, {moves = 'max'})

            -- Find prey that is closest to all 3 wolves
            local target = {}
            local min_dist = 9999
            for i,p in ipairs(prey) do 
                local dist = 0
                for j,w in ipairs(wolves) do
                    dist = dist + H.distance_between(w.x, w.y, p.x, p.y)
                end
                if (dist < min_dist) then
                    min_dist = dist
                    target = p
                end
            end
            --print('target:', target.x, target.y, target.id)

            -- Now sort wolf from furthest to closest
            table.sort(wolves, function(a, b)
                return H.distance_between(a.x, a.y, target.x, target.y) > H.distance_between(b.x, b.y, target.x, target.y)
            end)

            -- First wolf moves toward target, but tries to stay away from map edges
            local w,h,b = wesnoth.get_map_size()
            local wolf1 = AH.find_best_move(wolves[1], function(x, y)
                local d_1t = H.distance_between(x, y, target.x, target.y)
                local rating = -d_1t
                if x <= 5 then rating = rating - (6 - x) / 1.4 end
                if y <= 5 then rating = rating - (6 - y) / 1.4 end
                if (w - x) <= 5 then rating = rating - (6 - (w - x)) / 1.4 end
                if (h - y) <= 5 then rating = rating - (6 - (h - y)) / 1.4 end

               -- Hexes that enemy bears, yetis and spiders can reach get a massive negative hit
               -- meaning that they will only ever be chosen if there's no way around them
               if avoid:get(x, y) then rating = rating - 1000 end

               return rating
            end)
            --print('wolf 1 ->', wolves[1].x, wolves[1].y, wolf1[1], wolf1[2])
            --W.message { speaker = wolves[1].id, message = "Me first"}
            AH.movefull_stopunit(ai, wolves[1], wolf1)

            -- Second wolf wants to be (in descending priority):
            -- 1. Same distance from Wolf 1 and target
            -- 2. 2 hexes from Wolf 1
            -- 3. As close to target as possible
            local wolf2 = {}  -- Needed also for wolf3 below, thus defined here
            if wolves[2] then
                local d_1t = H.distance_between(wolf1[1], wolf1[2], target.x, target.y)
                wolf2 = AH.find_best_move(wolves[2], function(x, y)
                    local d_2t = H.distance_between(x, y, target.x, target.y)
                    local rating = -1 * (d_2t - d_1t) ^ 2.
                    local d_12 = H.distance_between(x, y, wolf1[1], wolf1[2])
                    rating = rating - (d_12 - 2.7) ^ 2
                    rating = rating - d_2t / 3.

                    -- Hexes that enemy bears, yetis and spiders can reach get a massive negative hit
                    -- meaning that they will only ever be chosen if there's no way around them
                    if avoid:get(x, y) then rating = rating - 1000 end

                    return rating
                end)
                --print('wolf 2 ->', wolves[2].x, wolves[2].y, wolf2[1], wolf2[2])
                --W.message { speaker = wolves[2].id, message = "Me second"}
                AH.movefull_stopunit(ai, wolves[2], wolf2)
            end

            -- Third wolf wants to be (in descending priority):
            -- Same as Wolf 2, but also 4 hexes from wolf 2
            if wolves[3] then
                local d_1t = H.distance_between(wolf1[1], wolf1[2], target.x, target.y)
                local wolf3 = AH.find_best_move(wolves[3], function(x, y)
                    local d_3t = H.distance_between(x, y, target.x, target.y)
                    local rating = -1 * (d_3t - d_1t) ^ 2.
                    local d_13 = H.distance_between(x, y, wolf1[1], wolf1[2])
                    local d_23 = H.distance_between(x, y, wolf2[1], wolf2[2])
                    rating = rating - (d_13 - 2.7) ^ 2 - (d_23 - 5.4) ^ 2
                    rating = rating - d_3t / 3.

                    -- Hexes that enemy bears, yetis and spiders can reach get a massive negative hit
                    -- meaning that they will only ever be chosen if there's no way around them
                    if avoid:get(x, y) then rating = rating - 1000 end

                    return rating
                end)
                --print('wolf 3 ->', wolves[3].x, wolves[3].y, wolf3[1], wolf3[2])
                --W.message { speaker = wolves[3].id, message = "Me third"}
                AH.movefull_stopunit(ai, wolves[3], wolf3)
            end
        end

        function wolves:wolves_wander_eval()
            -- When there's no prey left, the wolves wander and regroup
            local wolves = wesnoth.get_units { side = wesnoth.current.side, type = 'Wolf', formula = '$this_unit.moves > 0' }
            if wolves[1] then
                return 90000
            else
                return 0
            end
        end

        function wolves:wolves_wander_exec()

            local wolves = wesnoth.get_units { side = wesnoth.current.side, type = 'Wolf', formula = '$this_unit.moves > 0' }

            -- Number of wolves that can reach each hex
            local reach_map = LS.create()
            for i,w in ipairs(wolves) do
                local r = AH.get_reachable_unocc(w)
                reach_map:union_merge(r, function(x, y, v1, v2) return (v1 or 0) + (v2 or 0) end)
            end

            -- Add a random rating; avoid big animals, tuskers
            -- On their wandering, they avoid the dogs (but not when attacking)
            local avoid_units = wesnoth.get_units { type = 'Yeti,Giant Spider,Tarantula,Bear', 
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }
            --print('#avoid_units', #avoid_units)
            -- negative hit for hexes the bears, spiders and yetis can attack
            local avoid = AH.attack_map(avoid_units, {moves = 'max'})

            local max_rating = -9e99
            local goal_hex = {}
            reach_map:iter( function (x, y, v)
                local rating = v + AH.random(99)/100.
                if avoid:get(x, y) then rating = rating - 1000 end

                if (rating > max_rating) then
                    max_rating = rating
                    goal_hex = { x, y }
                end

                reach_map:insert(x, y, rating)
            end)
            --AH.put_labels(reach_map)
            --W.message { speaker = 'narrator', message = "Wolves random wander"}

            for i,w in ipairs(wolves) do
                -- For each wolf, we need to check that goal hex is reachable, and out of harm's way

                local best_hex = AH.find_best_move(w, function(x, y)
                    local rating = - H.distance_between(x, y, goal_hex[1], goal_hex[2])
                    if avoid:get(x, y) then rating = rating - 1000 end
                    return rating
                end)
                AH.movefull_stopunit(ai, w, best_hex)
            end
        end

        return wolves	
    end
}
