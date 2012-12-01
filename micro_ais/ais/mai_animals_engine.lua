return {
    init = function(ai)
        local animals = {}

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        local BC = wesnoth.dofile "~/add-ons/AI-demos/lua/battle_calcs.lua"
        local LS = wesnoth.require "lua/location_set.lua"
        local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

        function animals:attack_weakest_adj_enemy(unit)
            -- Attack the enemy with the fewest hitpoints adjacent to 'unit', if there is one
            -- Returns status of the attack:
            --   'attacked': if a unit was attacked
            --   'killed': if a unit was killed
            --   'no_attack': if no unit was attacked

            -- First check that the unit exists and has attacks left
            if (not unit.valid) then return 'no_attack' end
            if (unit.attacks_left == 0) then return 'no_attack' end

            local min_hp = 9e99
            local target = {}
            for x, y in H.adjacent_tiles(unit.x, unit.y) do
                local enemy = wesnoth.get_unit(x, y)
                if enemy and wesnoth.is_enemy(enemy.side, wesnoth.current.side) then
                    if (enemy.hitpoints < min_hp) then
                        min_hp = enemy.hitpoints
                        target = enemy
                    end
                end
            end
            if target.id then
                --W.message { speaker = unit.id, message = 'Attacking weakest adjacent enemy' }
                ai.attack(unit, target)
                if target.valid then
                    return 'attacked'
                else
                    return 'killed'
                end
            end

            return 'no_attack'
        end

        function animals:hunt_and_rest_eval(id)
            local unit = wesnoth.get_units { side = wesnoth.current.side, id = id,
                formula = '$this_unit.moves > 0'
            }[1]

            if unit then return 300000 end
            return 0
        end

        function animals:hunt_and_rest_exec(id, hunt_x, hunt_y, home_x, home_y, rest_turns)
            -- Unit with the given ID goes on a hunt, doing a random wander in area given by
            -- hunt_x,hunt_y (ranges), then retreats to
            -- position given by 'home_x,home_y' for 'rest_turns' turns, or until fully healed

            local unit = wesnoth.get_units { side = wesnoth.current.side, id = id,
                formula = '$this_unit.moves > 0'
            }[1]
            --print('Hunter: ', unit.id)

            -- If hunting_status is not set for the unit -> default behavior -> hunting
            if (not unit.variables.hunting_status) then
                -- Unit gets a new goal if none exist or on any move with 10% random chance
                local r = AH.random(10)
                if (not unit.variables.x) or (r >= 1) then
                    -- 'locs' includes border hexes, but that does not matter here
                    locs = wesnoth.get_locations { x = hunt_x, y = hunt_y }
                    local rand = AH.random(#locs)
                    --print('#locs', #locs, rand)
                    unit.variables.x, unit.variables.y = locs[rand][1], locs[rand][2]
                end
                --print('Hunter goto: ', unit.variables.x, unit.variables.y, r)

                -- Hexes the unit can reach
                local reach_map = AH.get_reachable_unocc(unit)

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
                        if enemy and wesnoth.is_enemy(enemy.side, wesnoth.current.side) then
                            if (enemy.hitpoints < enemy_hp) then enemy_hp = enemy.hitpoints end
                        end
                    end
                    rating = rating + 500 - enemy_hp  -- prefer attack on weakest enemy

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
                else  -- If hunter did not move, we need to stop it (also delete the goal)
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
                local attack_status = self:attack_weakest_adj_enemy(unit)

                -- If the enemy was killed, hunter returns home
                if unit.valid and (attack_status == 'killed') then
                    unit.variables.x = nil
                    unit.variables.y = nil
                    unit.variables.hunting_status = 'return'
                    W.message { speaker = unit.id, message = 'Now that I have eaten, I will go back home.' }
                end

                -- At this point, issue a 'return', so that no other action takes place this turn
                return
            end

            -- If we got here, this means the unit is either returning, or resting
            if (unit.variables.hunting_status == 'return') then
                goto_x, goto_y = wesnoth.find_vacant_tile(home_x, home_y)
                --print('Go home:', home_x, home_y, goto_x, goto_y)

                local next_hop = AH.next_hop(unit, goto_x, goto_y)
                if next_hop then
                    --print(next_hop[1], next_hop[2])
                    AH.movefull_stopunit(ai, unit, next_hop)

                    -- If there's an enemy on the 'home' hex and we got right next to it, attack that enemy
                    if (H.distance_between(home_x, home_y, next_hop[1], next_hop[2]) == 1) then
                        local enemy = wesnoth.get_unit(home_x, home_y)
                        if enemy and wesnoth.is_enemy(enemy.side, unit.side) then
                            W.message { speaker = unit.id, message = 'Get out of my pool!' }
                            ai.attack(unit, enemy)
                        end
                    end
                end

                -- We also attack the weakest adjacent enemy, if still possible
                self:attack_weakest_adj_enemy(unit)

                -- If the unit got home, start the resting counter
                if unit.valid and (unit.x == home_x) and (unit.y == home_y) then
                    unit.variables.hunting_status = 'resting'
                    unit.variables.resting_until = wesnoth.current.turn + rest_turns
                    W.message { speaker = unit.id, message = 'I made it home - resting now until the end of Turn ' .. unit.variables.resting_until .. ' or until fully healed.' }
                end

                -- At this point, issue a 'return', so that no other action takes place this turn
                return
            end

            -- If we got here, the only remaining action is resting
            if (unit.variables.hunting_status == 'resting') then
                -- So all we need to do is take moves away from the unit
                ai.stopunit_moves(unit)

                -- However, we do also attack the weakest adjacent enemy, if still possible
                self:attack_weakest_adj_enemy(unit)

                -- If this is the last turn of resting, we also remove the status and turn variable
                if unit.valid and (unit.hitpoints >= unit.max_hitpoints) and (unit.variables.resting_until <= wesnoth.current.turn) then
                    unit.variables.hunting_status = nil
                    unit.variables.resting_until = nil
                    W.message { speaker = unit.id, message = 'I am done resting.  It is time to go hunting again next turn.' }
                end
                return
            end

            -- In principle we should never get here, but just in case: reset variable, so that unit goes hunting on next turn
            unit.variables.hunting_status = nil
        end

        function animals:wolves_eval()
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

        function animals:wolves_exec(to_avoid)

            local wolves = wesnoth.get_units { side = wesnoth.current.side, type = 'Wolf', formula = '$this_unit.moves > 0' }
            -- Wolves hunt deer, but only close to the forest
            local prey = wesnoth.get_units { type = 'Deer',
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} },
                { "filter_location", { terrain = '*^F*', radius = 3 } }
            }
            --print('#wolves, prey', #wolves, #prey)

            -- When wandering (later) they avoid dogs, but not here
            local avoid_units = wesnoth.get_units { type = to_avoid,
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }
            --print('#avoid_units', #avoid_units)
            -- negative hit for hexes the bears, spiders and yetis can attack
            local avoid = BC.get_attack_map(avoid_units).units  -- max_moves=true is always set for enemy units

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

        function animals:wolves_wander_eval()
            -- When there's no prey left, the wolves wander and regroup
            local wolves = wesnoth.get_units { side = wesnoth.current.side, type = 'Wolf', formula = '$this_unit.moves > 0' }
            if wolves[1] then
                return 90000
            else
                return 0
            end
        end

        function animals:wolves_wander_exec(to_avoid)

            local wolves = wesnoth.get_units { side = wesnoth.current.side, type = 'Wolf', formula = '$this_unit.moves > 0' }

            -- Number of wolves that can reach each hex
            local reach_map = LS.create()
            for i,w in ipairs(wolves) do
                local r = AH.get_reachable_unocc(w)
                reach_map:union_merge(r, function(x, y, v1, v2) return (v1 or 0) + (v2 or 0) end)
            end

            -- Add a random rating; avoid big animals, tuskers
            -- On their wandering, they avoid the dogs (but not when attacking)
            local avoid_units = wesnoth.get_units { type = to_avoid,
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }
            --print('#avoid_units', #avoid_units)
            -- negative hit for hexes the bears, spiders and yetis can attack
            local avoid = BC.get_attack_map(avoid_units).units

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

        return animals
    end
}
