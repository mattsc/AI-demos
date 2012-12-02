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

        function animals:color_label(x, y, text)
            -- For displaying the wolf pack number in color underneath each wolf
            if (wesnoth.current.side == 2) then
                text = "<span color='#63B8FF'>" .. text .. "</span>"
            else
                text = "<span color='#98FB98'>" .. text .. "</span>"
            end
            W.label{ x = x, y = y, text = text }
        end

        function animals:assign_packs()
            -- Assign the pack numbers to each wolf.  Keeps numbers of existing packs
            -- (unless pack size is down to one).  Pack number is stored in wolf unit variables
            -- Also returns a table with the packs (locations and id's of each wolf in a pack)

            local wolves = wesnoth.get_units { side = wesnoth.current.side, type = 'Wolf' }
            --print('#wolves:', #wolves)

            -- Array for holding the packs
            local packs = {}
            -- Find wolves that already have a pack number assigned
            for i,w in ipairs(wolves) do
                if w.variables.pack then
                    if (not packs[w.variables.pack]) then packs[w.variables.pack] = {} end
                    table.insert(packs[w.variables.pack], { x = w.x, y = w.y, id = w.id })
                end
            end

            -- Remove packs of one
            -- Pack numbers might not be consecutive after a while -> need pairs(), not ipairs()
            for k,p in pairs(packs) do
                --print(' have pack:', k, ' #members:', #p)
                if (#p == 1) then
                    local wolf = wesnoth.get_unit(p[1].x, p[1].y)
                    wolf.variables.pack, wolf.variables.x, wolf.variables.y = nil, nil, nil
                    packs[k] = nil
                end
            end
            --print('After removing packs of 1')
            --for k,p in pairs(packs) do print(' have pack:', k, ' #members:', #p) end
            --DBG.dbms(packs)

            -- Wolves that are not in a pack (new ones or those removed above)
            local nopack_wolves = {}
            for i,w in ipairs(wolves) do
                if (not w.variables.pack) then
                    table.insert(nopack_wolves, w)
                    -- Also erase any goal one of these might have
                    w.variables.pack, w.variables.x, w.variables.y = nil, nil, nil
                end
            end
            --print('#nopack_wolves:', #nopack_wolves)

            -- Now assign the nopack wolves to packs
            -- First, go through packs that have only 2 members
            for k,p in pairs(packs) do
                if (#p == 2) then
                    local min_dist, best_wolf, best_ind = 9e99, {}, -1
                    for i,w in ipairs(nopack_wolves) do
                        local d1 = H.distance_between(w.x, w.y, p[1].x, p[1].y)
                        local d2 = H.distance_between(w.x, w.y, p[2].x, p[2].y)
                        if (d1 + d2 < min_dist) then
                            min_dist = d1 + d2
                            best_wolf, best_ind = w, i
                        end
                    end
                    if (min_dist < 9e99) then
                        table.insert(packs[k], { x = best_wolf.x, y = best_wolf.y, id = best_wolf.id })
                        best_wolf.variables.pack = k
                        table.remove(nopack_wolves, best_ind)
                    end
                end
            end
            --print('After completing packs of 2')
            --for k,p in pairs(packs) do print(' have pack:', k, ' #members:', #p) end

            -- Second, group remaining single wolves
            -- At the beginning of the scenario, this is all wolves
            while (#nopack_wolves > 0) do
                --print('Grouping the remaining wolves', #nopack_wolves)
                -- First find the first available pack number
                new_pack = 1
                while packs[new_pack] do new_pack = new_pack + 1 end
                --print('Building pack', new_pack)

                -- If there are <=3 wolves left, that's the pack (we also assign a single wolf to a 1-wolf pack here)
                if (#nopack_wolves <= 3) then
                    --print('<=3 nopack wolves left', #nopack_wolves)
                    packs[new_pack] = {}
                    for i,w in ipairs(nopack_wolves) do
                        table.insert(packs[new_pack], { x = w.x, y = w.y, id = w.id })
                        w.variables.pack = new_pack
                    end
                    break
                end

                -- If more than 3 wolves left, find those that are closest together
                -- They form the next pack
                --print('More than 3 nopack wolves left', #nopack_wolves)
                local min_dist = 9e99
                local best_wolves, best_ind = {}, {}
                for i,w1 in ipairs(nopack_wolves) do
                    for j,w2 in ipairs(nopack_wolves) do
                        for k,w3 in ipairs(nopack_wolves) do
                            local d12 = H.distance_between(w1.x, w1.y, w2.x, w2.y)
                            local d13 = H.distance_between(w1.x, w1.y, w3.x, w3.y)
                            local d23 = H.distance_between(w2.x, w2.y, w3.x, w3.y)
                            -- If it's the same wolf, that doesn't count
                            if (d12 == 0) then d12 = 999 end
                            if (d13 == 0) then d13 = 999 end
                            if (d23 == 0) then d23 = 999 end
                            if (d12 + d13 + d23 < min_dist) then
                                min_dist = d12 + d13 + d23
                                best_wolves = { w1, w2, w3 }
                                best_ind = { i, j, k }
                            end
                        end
                    end
                end
                -- Now insert the best pack into that 'packs' array
                packs[new_pack] = {}
                -- Need to count down for table.remove to work correctly
                for i = 3,1,-1 do
                    table.insert(packs[new_pack], { x = best_wolves[i].x, y = best_wolves[i].y, id = best_wolves[i].id })
                    best_wolves[i].variables.pack = new_pack
                    table.remove(nopack_wolves, best_ind[i])
                end
            end
            --print('After grouping remaining single wolves')
            --for k,p in pairs(packs) do print(' have pack:', k, ' #members:', #p) end

            --DBG.dbms(packs)
            -- Put labels out there for all wolves
            for k,p in pairs(packs) do
                for i,loc in ipairs(p) do
                    self:color_label(loc.x, loc.y, k)
                end
            end

            return packs
        end

        function animals:wolves_multipacks_attack_eval()
            -- If wolves have attacks left, call this CA
            -- It will generally be disabled by being black-listed, so as to avoid
            -- having to do the full attack evaluation for every single move
            local wolves = wesnoth.get_units { side = wesnoth.current.side, type = 'Wolf', formula = '$this_unit.attacks_left > 0' }

            if wolves[1] then return 300000 end
            return 0
        end

        function animals:wolves_multipacks_attack_exec()

            -- First get all the packs
            local packs = self:assign_packs()
            --DBG.dbms(packs)

            -- Attacks are dealt with on a pack by pack basis
            -- and I want all wolves in a pack to move first, before going on to the next pack
            -- which makes this slightly more complicated than it would be otherwise
            for pack_number,pack in pairs(packs) do

                local keep_attacking_this_pack = true    -- whether there might be attacks left
                local pack_attacked = false   -- whether an attack by the pack has happened

                -- This repeats until all wolves in a pack have attacked, or none can attack any more
                while keep_attacking_this_pack do
                    -- Get the wolves in the pack ...
                    local wolves, attacks = {}, {}
                    for i,p in ipairs(pack) do
                        -- Wolf might have moved in previous attack -> use id to identify it
                        local wolf = wesnoth.get_units { id = p.id }
                        -- Wolf could have died in previous attack
                        -- and only include wolves with attacks left to calc. possible attacks
                        if wolf[1] and (wolf[1].attacks_left > 0) then table.insert(wolves, wolf[1]) end
                    end

                    -- ... and check if any targets are in reach
                    local attacks = {}
                    if wolves[1] then attacks = AH.get_attacks(wolves, { simulate_combat = true }) end
                    --print('pack, wolves, attacks:', pack_number, #wolves, #attacks)
                    --DBG.dbms(attacks)

                    -- Eliminate targets that would split up the wolves by more than 3 hexes
                    -- This also takes care of wolves joining as a pack rather than attacking individually
                    for i=#attacks,1,-1 do
                        --print(i, attacks[i].x, attacks[i].y)
                        for j,w in ipairs(wolves) do
                            local nh = AH.next_hop(w, attacks[i].dst.x, attacks[i].dst.y)
                            local d = H.distance_between(nh[1], nh[2], attacks[i].dst.x, attacks[i].dst.y)
                            --print('  ', i, w.x, w.y, d)
                            if d > 3 then
                                table.remove(attacks, i)
                                --print('Removing attack')
                                break
                            end
                        end
                    end
                    --print('-> pack, wolves, attacks:', pack_number, #wolves, #attacks)

                    -- If valid attacks were found for this pack
                    if attacks[1] then
                        -- Figure out how many different wolves can reach each target, and on how many hexes
                        -- The target with the largest value for the smaller of these two numbers is chosen
                        -- This is not an exact method, but good enough in most cases
                        local diff_wolves, diff_hexes = {}, {}
                        for i,a in ipairs(attacks) do
                            -- Number different wolves
                            local att_xy = a.src.x + a.src.y * 1000
                            local def_xy = a.target.x + a.target.y * 1000
                            if (not diff_wolves[def_xy]) then diff_wolves[def_xy] = {} end
                            diff_wolves[def_xy][att_xy] = 1
                            -- Number different hexes
                            if (not diff_hexes[def_xy]) then diff_hexes[def_xy] = {} end
                            diff_hexes[def_xy][a.dst.x + a.dst.y * 1000] = 1
                        end
                        --DBG.dbms(diff_wolves)
                        --DBG.dbms(diff_hexes)

                        -- Find which target can be attacked by the most units, from the most hexes; and rate by fewest HP if equal
                        local max_rating, best_target = -9e99, {}
                        for k,t in pairs(diff_wolves) do
                            local n_w, n_h = 0, 0
                            for k1,w in pairs(t) do n_w = n_w + 1 end
                            for k2,h in pairs(diff_hexes[k]) do n_h = n_h + 1 end
                            local rating = math.min(n_w, n_h)

                            local target = wesnoth.get_unit( k % 1000, math.floor(k / 1000))
                            rating = rating - target.hitpoints / 100.

                            -- Also, any target sitting next to a wolf of the same pack that has
                            -- no attacks left is priority targeted (in order to stick with
                            -- the same target for all wolves of the pack)
                            for x, y in H.adjacent_tiles(target.x, target.y) do
                                local adj_unit = wesnoth.get_unit(x, y)
                                if adj_unit and (adj_unit.variables.pack == pack_number)
                                    and (adj_unit.side == wesnoth.current.side) and (adj_unit.attacks_left == 0)
                                then
                                    rating = rating + 10 -- very strongly favors this target
                                end
                            end

                            --print(k, n_w, n_h, rating)
                            if rating > max_rating then
                                max_rating, best_target = rating, target
                            end
                        end
                        --print('Best target:', best_target.id, best_target.x, best_target.y)

                        -- Now we know what the best target is, we need to attack now
                        -- This is done on a wolf-by-wolf basis, the while loop taking care of the next wolf in the pack
                        -- on subsequent iterations
                        local max_rating, best_attack = -9e99, {}
                        for i,a in ipairs(attacks) do
                            if (a.target.x == best_target.x) and (a.target.y == best_target.y) then
                                -- HP outcome is rating, twice as important for target as for attacker
                                local rating = a.att_stats.average_hp / 2. - a.def_stats.average_hp
                                if (rating > max_rating) then
                                    max_rating, best_attack = rating, a
                                end
                            end
                        end

                        local attacker = wesnoth.get_unit(best_attack.src.x, best_attack.src.y)
                        local defender = wesnoth.get_unit(best_attack.target.x, best_attack.target.y)
                        W.label { x = attacker.x, y = attacker.y, text = "" }
                        AH.movefull_stopunit(ai, attacker, best_attack.dst.x, best_attack.dst.y)
                        self:color_label(attacker.x, attacker.y, pack_number)

                        local a_x, a_y, d_x, d_y = attacker.x, attacker.y, defender.x, defender.y
                        ai.attack(attacker, defender)
                        -- Remove the labels, if one of the units died
                        if (not attacker.valid) then W.label { x = a_x, y = a_y, text = "" } end
                        if (not defender.valid) then W.label { x = d_x, y = d_y, text = "" } end

                        pack_attacked = true    -- This pack has done an attack
                    else
                        keep_attacking_this_pack = false    -- no more valid attacks found
                    end
                end

                -- Finally, if any of the wolves in this pack did attack, move the rest of the pack in close
               if pack_attacked then
                    local wolves_moves, wolves_no_moves = {}, {}
                    for i,p in ipairs(pack) do
                        -- Wolf might have moved in previous attack -> use id to identify it
                        local wolf = wesnoth.get_unit(p.x, p.y)
                        -- Wolf could have died in previous attack
                        if wolf then
                            if (wolf.moves > 0) then
                                table.insert(wolves_moves, wolf)
                            else
                                table.insert(wolves_no_moves, wolf)
                            end
                        end
                    end
                    --print('#wolves_moves, #wolves_no_moves', #wolves_moves, #wolves_no_moves)

                    -- If we have both wolves that have moved and those that have not moved,
                    -- move the latter toward the former
                    if wolves_moves[1] and wolves_no_moves[1] then
                        --print('Collecting stragglers')
                        for i,w in ipairs(wolves_moves) do
                            local best_hex = AH.find_best_move(w, function(x, y)
                                local rating = 0
                                for j,w_nm in ipairs(wolves_no_moves) do
                                    rating = rating - H.distance_between(x, y, w_nm.x, w_nm.y)
                                end
                                return rating
                            end)
                            W.label { x = w.x, y = w.y, text = "" }
                            AH.movefull_stopunit(ai, w, best_hex)
                            self:color_label(w.x, w.y, pack_number)
                        end
                    end
                end

            end

        end

        function animals:wolves_multipacks_wander_eval()
            -- When there's nothing to attack, the wolves wander and regroup into their packs
            local wolves = wesnoth.get_units { side = wesnoth.current.side, type = 'Wolf', formula = '$this_unit.moves > 0' }

            if wolves[1] then return 290000 end

            return 0
        end

        function animals:wolves_multipacks_wander_exec()

            -- First get all the packs
            local packs = self:assign_packs()
            --DBG.dbms(packs)

            for k,pack in pairs(packs) do

                -- If any of the wolves has a goal set, this is used for the entire pack
                local wolves, goal = {}, {}
                for i,loc in ipairs(pack) do
                    local wolf = wesnoth.get_unit(loc.x, loc.y)
                    --print(k, i, wolf.id)
                    table.insert(wolves, wolf)
                    -- If any of the wolves in the pack has a goal set, we use that one
                    if wolf.variables.x then
                        goal = { wolf.variables.x, wolf.variables.y }
                    end
                end

                -- If the position of any of the wolves is at the goal, delete it
                for i,w in ipairs(wolves) do
                    if (w.x == goal[1]) and (w.y == goal[2]) then goal = {} end
                end

                -- Pack gets a new goal if none exist or on any move with 10% random chance
                local r = AH.random(10)
                if (not goal[1]) or (r == 1) then
                    local w,h,b = wesnoth.get_map_size()
                    local locs = {}
                    locs = wesnoth.get_locations { x = '1-'..w, y = '1-'..h,
                        { "not", { terrain = '*^X*,Wo' } }
                    }
                    local rand = AH.random(#locs)
                    goal = { locs[rand][1], locs[rand][2] }
                end
                --print('Pack goal: ', goal[1], goal[2])

                -- This goal is saved with every wolf of the pack
                for i,w in ipairs(wolves) do
                    w.variables.x, w.variables.y = goal[1], goal[2]
                end

                -- The pack wanders with only 2 considerations
                -- 1. Keeping the pack together (most important)
                --   Going through all combinations of all hexes for all wolves is too expensive
                --   -> find hexes that can be reached by all wolves
                -- 2. Getting closest to the goal (secondary to 1.)

                -- Number of wolves that can reach each hex,
                local reach_map = LS.create()
                for i,w in ipairs(wolves) do
                    local reach = wesnoth.find_reach(w)
                    for j,loc in ipairs(reach) do
                        reach_map:insert(loc[1], loc[2], (reach_map:get(loc[1], loc[2]) or 0) + 100)
                    end
                end

                -- Keep only those hexes that can be reached by all wolves in the pack
                -- and add distance from goal for those
                local max_rating, goto_hex = -9e99, {}
                reach_map:iter( function(x, y, v)
                    local rating = reach_map:get(x, y)
                    if (rating == #pack * 100) then
                        rating = rating - H.distance_between(x, y, goal[1], goal[2])
                        reach_map:insert(x,y, rating)
                        if rating > max_rating then
                            max_rating, goto_hex = rating, { x, y }
                        end
                    else
                        reach_map:remove(x, y)
                    end
                end)

                -- Sort wolves by MP, the one with fewest moves goes first
                table.sort(wolves, function(a, b) return a.moves < b.moves end)

                -- If there's no hex that all units can reach, use the 'center of gravity' between them
                -- Then we move the first wolf (fewest MP) toward that hex, and the position of that wolf
                -- becomes the goto coordinates for the others
                if (not goto_hex[1]) then
                    local cg = { 0, 0 }  -- Center of gravity hex
                    for i,w in ipairs(wolves) do
                        cg = { cg[1] + w.x, cg[2] + w.y }
                    end
                    cg[1] = math.floor(cg[1] / #pack)
                    cg[2] = math.floor(cg[2] / #pack)
                    --print('cg', cg[1], cg[2])

                    -- Find closest move for Wolf #1 to that position, which then becomes the goto hex
                    goto_hex = AH.find_best_move(wolves[1], function(x, y)
                        return -H.distance_between(x, y, cg[1], cg[2])
                    end)
                    -- We could move this wolf right here, but for convenience all the actual moves are
                    -- grouped together below.  Speed wise that should not really make a difference, but could be optimized
                end
                --print('goto_hex', goto_hex[1], goto_hex[2])
                --AH.put_labels(reach_map)

                -- Now all wolves in the pack are moved toward goto_hex, starting with the one with fewest MP
                -- Distance to goal hex is taken into account as secondary criterion
                for i,w in ipairs(wolves) do
                    local best_hex = AH.find_best_move(w, function(x, y)
                        local rating = - H.distance_between(x, y, goto_hex[1], goto_hex[2])
                        rating = rating - H.distance_between(x, y, goal[1], goal[2]) / 100.
                        return rating
                    end)
                    W.label { x = w.x, y = w.y, text = "" }
                    AH.movefull_stopunit(ai, w, best_hex)
                    self:color_label(w.x, w.y, k)
                end
            end
        end

        function animals:yeti_terrain(set)
            -- Remove locations from LS that are not mountains or hills
            set:iter( function(x, y, v)
               local yeti_terr = wesnoth.match_location(x, y, { terrain = 'M*,M*^*,H*,H*^*' })
               if (not yeti_terr) then set:remove(x, y) end
            end)
            return set
        end

        function animals:big_eval(type)
            local units = wesnoth.get_units { side = wesnoth.current.side, type = type, formula = '$this_unit.moves > 0' }

            if units[1] then return 300000 end
            return 0
        end

        function animals:big_exec(type)
            -- Big animals just move toward goal that gets set occasionally
            -- Avoid the other big animals (bears, yetis, spiders) and the dogs, otherwise attack whatever is in their range
            -- The only difference in behavior is the area in which the units move

            local units = wesnoth.get_units { side = wesnoth.current.side, type = type, formula = '$this_unit.moves > 0' }
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
                    if (type == 'Bear') then
                        locs = wesnoth.get_locations { x = '1-40', y = '1-18',
                            { "not", { terrain = '*^X*,Wo' } },
                            { "not", { x = unit.x, y = unit.y, radius = 12 } }
                        }
                    end
                    if (type == 'Giant Spider,Tarantula') then
                        locs = wesnoth.get_locations { terrain = 'H*' }
                    end
                    if (type == 'Yeti') then
                        locs = wesnoth.get_locations { terrain = 'M*' }
                    end
                    local rand = AH.random(#locs)
                    --print(type, ': #locs', #locs, rand)
                    unit.variables.x, unit.variables.y = locs[rand][1], locs[rand][2]
                end
                --print('Big animal goto: ', type, unit.variables.x, unit.variables.y, r)

                -- hexes the unit can reach
                local reach_map = AH.get_reachable_unocc(unit)
                -- If this is a yeti, we only keep mountain and hill terrain
                if (type == 'Yeti') then self:yeti_terrain(reach_map) end

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

        return animals
    end
}
