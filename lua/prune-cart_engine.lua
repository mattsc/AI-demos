return {
    init = function(ai)

        local prune_cart = {}

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        local BC = wesnoth.require "~/add-ons/AI-demos/lua/battle_calcs.lua"
        local LS = wesnoth.require "lua/location_set.lua"
        --local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

        function prune_cart:get_level_up_attack_rating(attacker, target, loc)

            local max_rating = -9999
            local best_weapon = -1

            local target_level = wesnoth.unit_types[target.type].level
            local n_weapon = 0
            for weapon in H.child_range(attacker.__cfg, "attack") do
                n_weapon = n_weapon + 1

                local att_stats, def_stats = BC.simulate_combat_loc(attacker, loc, target, n_weapon)
                --DBG.dbms(att_stats,false,"variable",false)
                --print(attacker.id, att_stats.average_hp, def_stats.average_hp)

                -- Level-up attack when:
                -- 1. max_experience-experience <= target.level and chance to die = 0
                -- 2. max_experience-experience <= target.level*8 and chance to die = 0
                --   and chance to kill > 66% and remaining av hitpoints > 20
                -- #1 is a definite level up, #2 is not, so #1 gets priority

                local rating = -9999
                if (attacker.max_experience - attacker.experience <= target_level) then
                    if (att_stats.hp_chance[0] == 0) then
                        -- weakest enemy is best (favors stronger weapon)
                        rating = 15000 - def_stats.average_hp
                    end
                else
                    if (attacker.max_experience - attacker.experience <= 8 * target_level) and (att_stats.hp_chance[0] == 0) and (def_stats.hp_chance[0] >= 0.66) and (att_stats.average_hp >= 20) then
                        -- strongest attacker and weakest enemy is best
                        rating = 14000 + att_stats.average_hp - def_stats.average_hp/2.
                    end
                end
                --print("Level-up rating:",rating)

                if rating > max_rating then
                    max_rating = rating
                    best_weapon = n_weapon
                end
            end

            --print("Best level-up attack:", max_rating, best_weapon)
            return max_rating, best_weapon
        end

        function prune_cart:find_enemies_in_way(unit, goal_x, goal_y)
            -- Returns all enemies on or next to the path of the next step of 'unit' toward goal_x,goal_y
            -- Returns an empty table if no enemies were found (or the path is not possible etc.)

            local path, cost = wesnoth.find_path(unit, goal_x, goal_y, {ignore_units = true})

            -- If unit cannot get there (ignoring units):
            if cost >= 42424242 then return {} end

            -- Exclude the hex the unit is currently on
            table.remove(path, 1)

            local enemies_in_way = {}

            -- Find units on hexes adjacent to the path
            for i, p in ipairs(path) do
                local sub_path, sub_cost = wesnoth.find_path( unit, p[1], p[2], {ignore_units = true})

                if sub_cost <= unit.moves then
                    --print(i,p[1],p[2],sub_cost)

                    -- Check for enemy units on one of the adjacent hexes? (which includes hexes on path too)
                    for x, y in H.adjacent_tiles(p[1], p[2]) do
                        local enemy = wesnoth.get_units { x = x, y = y,
                            { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
                        }[1]
                        if enemy then
                            --print('  enemy next to path hex:',enemy.id)
                            -- This unit might already be in the list
                            local already_in_table = false
                            for j,e in ipairs(enemies_in_way) do
                                if (e.id == enemy.id) then already_in_table = true end
                            end
                            if (not already_in_table) then table.insert(enemies_in_way, enemy) end
                        end
                    end

                else  -- If we've reached the end of the path for this turn
                    return enemies_in_way
                end
            end

            -- Just in case we got here somehow
            return enemies_in_way
        end

        function prune_cart:find_close_enemies(unit, goal_x, goal_y)
            -- Returns array of enemies that are
            -- 1. Within 1 move of 'unit' (ignoring AI units)
            -- 2. Closer to 'unit' than any of the AI's unit (in number of turns to get there)
            -- 3. Once we're into the "end game", all enemies are considered here

            local enemies = wesnoth.get_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }

            -- First, need distance (in moves) of closest AI unit to 'unit'
            -- (assuming full MP)
            -- This is an emergency thing, so we include healers and leaders
            local my_units = wesnoth.get_units{ side = wesnoth.current.side, { "not", { id = unit.id } } }
            local intercept_units = {}
            local my_HP, enemy_HP = 0, 0
            for i,u in ipairs(my_units) do
                if (u.attacks_left > 0) and (u.canrecruit == false) and (u.__cfg.usage ~= "healer") then
                    table.insert(intercept_units, u)
                end
                my_HP = my_HP + u.hitpoints
            end
            for i,u in ipairs(enemies) do
                if (not u.canrecruit) then enemy_HP = enemy_HP + u.hitpoints end
            end

            local max_enemy_distance = 1
            if (wesnoth.current.turn > 2) and (my_HP > enemy_HP * 3) then
                --print('Going into offensive mode')
                    max_enemy_distance = 1000
            end
            --print('my HP, enemy HP:', my_HP, enemy_HP, max_enemy_distance)

            -- We measure this one to the end of the next move of 'unit'
            local tmp = unit.moves
            unit.moves = unit.max_moves

            local next_hop_unit = AH.next_hop(unit, goal_x, goal_y, {ignore_units = true})
            unit.moves = tmp

            local closest_my_unit = 9999
            for i,u in ipairs(my_units) do  -- This is from all units, not just the interceptors
                local tmp = u.moves
                u.moves = u.max_moves
                local reach, cost = wesnoth.find_path(u, next_hop_unit[1], next_hop_unit[2])
                u.moves = tmp

                if (cost / u.max_moves < closest_my_unit) then
                    closest_my_unit = cost / u.max_moves
                end
            end
            --print('closest_my_unit:', closest_my_unit)
            closest_my_unit = math.ceil(closest_my_unit)
            --print('closest_my_unit:', closest_my_unit)

            local close_enemies = {}
            for i,e in ipairs(enemies) do
                -- need to do this for max_moves of unit (moves on current turn most likely = 0)
                -- and distance to 'unit' after its next move
                local tmp = e.moves
                e.moves = e.max_moves
                local path, cost = wesnoth.find_path(e, next_hop_unit[1], next_hop_unit[2], {ignore_units = true})
                e.moves = tmp

                -- First, check if this unit is closer than any of the AI units
                --print('enemy', e.id, cost / e.max_moves)
                if (cost / e.max_moves <= closest_my_unit) then
                    --print('Closer than any AI unit',e.id)
                    table.insert(close_enemies, e)
                else -- if not, also include it if it is within 1 move (of current position, ignoring AI units)
                    -- need to do this for max_moves of unit (moves on current turn most likely = 0)
                    local tmp = e.moves
                    e.moves = e.max_moves
                    local reach = wesnoth.find_reach(e, {ignore_units = true})
                    e.moves = tmp
                    for j,r in ipairs(reach) do
                        if (H.distance_between(unit.x, unit.y, r[1], r[2]) <= max_enemy_distance ) then
                            --print('Within one move of cart',e.id)
                            table.insert(close_enemies, e)
                            break
                        end
                    end
                end
            end
            --print('#close_enemies',#close_enemies)

            return close_enemies
        end

        function prune_cart:find_best_attack_on_targets(targets, unit)
            -- Finds the best attacks on a list of targets
            -- 'unit' is not considered as attacker, but closeness to it rates the attack
            -- If no attack was found, return nil

            if (not targets[1]) then return end

            local max_rating = -9999
            local best_attack = {}

            -- Find all units that have attacks left
            -- Exclude healers and leaders
            local my_units = wesnoth.get_units{ side = wesnoth.current.side, formula = '$this_unit.attacks_left > 0',
                canrecruit = 'no', { "not", { id = unit.id } },
                {"not", { ability = "healing" } }
            }
            --print('#my_units', #my_units)
            if (not my_units[1]) then return end

            local my_attacks = AH.get_attacks(my_units, { simulate_combat = true })
            --DBG.dbms(my_attacks,false,"variable",false)

            for i, att in ipairs(my_attacks) do
                for j,t in ipairs(targets) do
                    if (att.target.x == t.x) and (att.target.y == t.y) then

                        -- Rating based on:
                        --    expected attacker and defender HP (defender HP being more important)
                        --    chance to kill target
                        --    closeness of attack hex to 'unit'
                        local rating = att.att_stats.average_hp - 2 * att.def_stats.average_hp
                        rating = rating + att.def_stats.hp_chance[0] * 50
                        rating = rating - 10 * H.distance_between(unit.x, unit.y, att.dst.x, att.dst.y)
                        --print('    rating:', rating, att.dst.x, att.dst.y)

                        if (rating > max_rating) then
                            max_rating = rating
                            best_attack = att
                        end
                    end
                end
            end
            --print(max_rating)
            --DBG.dbms(best_attack,false,"variable",false)

            if (max_rating > -9999) then
                return best_attack
            else
                return
            end
        end

        function prune_cart:deal_with_threats(unit, threat_function, goal_x, goal_y, threats_dealt_with)
            -- Attack units that are considered threats to 'unit'
            -- or move toward them
            -- Each threat unit is dealt with at least 2 AI units

            local deal_with_threats = true
            local threats_dealt_with = threats_dealt_with or {}  -- counter for which enemy has been dealt with

            while deal_with_threats do
                deal_with_threats = false -- this way, it needs to be reset to do another round

                -- Threats need to be evaluated anew each time -> need to do this in here
                -- cannot pass the threat function itself
                local threats = {}
                if (threat_function == 'enemies_in_way') then
                    threats = self:find_enemies_in_way(unit, goal_x, goal_y)
                else
                    threats = self:find_close_enemies(unit, goal_x, goal_y)
                end
                --print('#threats:', #threats, threat_function)
                --DBG.dbms(threats[1],false,"variable",false)
                if not threats[1] then break end

                local attack = self:find_best_attack_on_targets(threats, unit)
                --DBG.dbms(attack,false,"variable",false)

                if attack then  -- If an attack is possible, do it

                    local attacker = wesnoth.get_unit(attack.src.x, attack.src.y)
                    local defender = wesnoth.get_unit(attack.target.x, attack.target.y)

                    --W.message {speaker=attacker.id, message="Attacking" }
                    AH.movefull_stopunit(ai, attacker, attack.dst.x, attack.dst.y)
                    --print('Attacking',attacker.id, defender.id, attack.dst.x, attack.dst.y)
                    local def_id = defender.id -- This is in case the defender dies on this attack
                    ai.attack(attacker, defender)

                    -- And set up for reevaluation, and increment counter for this threat, and which units participated
                    deal_with_threats = true
                    threats_dealt_with[def_id] = (threats_dealt_with[def_id] or 0) + 1
                    if attacker.valid then  -- make sure attacker wasn't killed here
                        table.insert(self.data.protecting_units, {attacker.x, attacker.y})
                    end
                else  -- If no viable attack was found, we move the closest units toward each enemy (up to 2)

                    --print('Move units to intercept targets')
                    -- Want these sorted by closeness to 'unit', so that closest is considered first
                    table.sort(threats, function(a, b)
                        da = H.distance_between(unit.x, unit.y, a.x, a.y)
                        db = H.distance_between(unit.x, unit.y, b.x, b.y)
                        --print(da, db)
                        return da < db
                    end)

                    for i,t in ipairs(threats) do
                        for m = (threats_dealt_with[t.id] or 0), 1 do
                            -- Include healers and leaders
                            local my_units = wesnoth.get_units{ side = wesnoth.current.side, formula = '$this_unit.moves > 0',
                                { "not", { id = unit.id } }
                            }

                            local min_cost = 9999
                            local best_unit = {}
                            local x, y = wesnoth.find_vacant_tile(t.x, t.y, unit)
                            for j,u in ipairs(my_units) do
                                local path, cost = wesnoth.find_path(u, x, y)
                                if (cost < min_cost) then
                                    min_cost = cost
                                    best_unit = u
                                end
                            end

                            if (min_cost < 9999) then
                                local next_hop = AH.next_hop(best_unit, x, y)
                                --print('best unit',best_unit.id, x, y, next_hop[1], next_hop[2] )
                                AH.movefull_stopunit(ai, best_unit, next_hop)
                                table.insert(self.data.protecting_units, {best_unit.x, best_unit.y})
                            end
                        end
                    end
                end
            end

            return threats_dealt_with  -- so that next call to function knows about this
        end

        function prune_cart:find_move_out_of_way(unit, not_id, dist_map, avoid)
            -- Find if there's a move out of the way for 'unit'
            -- not_id: exclude unit with this id (that's the one for which we consider the move)
            -- dist_map: distance map: unit will only move in direction of equal or decreasing distance
            -- Returns {x, y} of best move, or nil

           if (unit.id == not_id) then return end

           local reach = wesnoth.find_reach(unit)
           -- find the closest hex the unit can move to, but only in direction of cart
           local max_score = -9999
           local best_move = {}

           for i,r in ipairs(reach) do
               -- Make sure hex is unoccupied
               local unocc = (not wesnoth.get_unit(r[1], r[2]))
               -- Also exclude hexes given by 'avoid'
               local avoid_hex = false
               if avoid then
                   for j,a in ipairs(avoid) do
                       if (r[1] == a[1]) and (r[2] == a[2]) then avoid_hex = true end
                   end
               end

               if unocc and (not avoid_hex)
                   and (r[3] ~= unit.moves)  -- only counts if unit actually moves
                   and (dist_map:get(r[1], r[2]) <= dist_map:get(unit.x, unit.y))  -- and if not away from cart
               then
                   -- Maximize moves left (most important), minimize distance to cart
                   local score = max_score
                   score = 100 * r[3] - dist_map:get(r[1], r[2])
                   if (score > max_score) then
                       max_score = score
                       best_move = {r[1], r[2]}
                   end
               end
           end

           if (max_score > -9999) then
               return best_move
           end
        end

        function prune_cart:move_special_unit(unit, id, special_rating)
            -- Find the best move for 'unit'
            -- id: id of the cart, needed for distance calculation
            -- special_rating: the rating that is particular to this kind of unit
            --   (the rest of the rating is done here)

            local cart = wesnoth.get_units{ id = id }[1]
            local dist_cart = AH.distance_map({cart})

            local units_MP = wesnoth.get_units{ side = wesnoth.current.side, formula = '$this_unit.moves > 0' }
            -- Take all units with moves left off the map, for enemy path finding
            for i,u in ipairs(units_MP) do wesnoth.extract_unit(u) end
            -- Get an enemy_reach_map taking only AI units that cannot move into account
            local enemy_dstsrc = AH.get_enemy_dst_src()
            -- Put units back out there
            for i,u in ipairs(units_MP) do wesnoth.put_unit(u.x, u.y, u) end

            local rating_map = LS.create()
            local max_rating = -9999
            local best_hex = {}

            local reach = wesnoth.find_reach(unit)
            for j,r in ipairs(reach) do

                -- Check if there's unit at the hex that cannot move away
                local unocc = true
                local unit_in_way = wesnoth.get_unit(r[1], r[2])
                if unit_in_way and (unit_in_way.id ~= unit.id) then
                    local move_away = self:find_move_out_of_way(unit_in_way, unit.id, dist_cart)
                    if (not move_away) then unocc = false end
                end

                -- Only consider occupied hexes and those that are not farther from cart
                if unocc then
                    local rating = 0

                    -- Hexes that enemies can reach are not good
                    for x, y in H.adjacent_tiles(r[1], r[2]) do
                        if enemy_dstsrc:get(x, y) then rating = rating - 100 end
                    end

                    -- Add in the special rating
                    rating = rating + (special_rating:get(r[1], r[2]) or 0)

                    -- Add a very small penalty if unit needs to be moved out of the way
                    if unit_in_way then rating = rating - 0.1 end

                    -- As a tie breaker, stay close to the cart
                    rating = rating - dist_cart:get(r[1], r[2]) * 0.001

                    rating_map:insert(r[1], r[2], rating)
                    --print('rating',r[1], r[2], rating)

                    if (rating > max_rating) then
                        max_rating = rating
                        best_hex = {r[1], r[2]}
                    end
                end
            end
            --print('best unit move', best_hex[1], best_hex[2], max_rating)
            --AH.put_labels(rating_map)

            -- If there's a unit in the way, move it away
            -- we checked before that that is possible
            local unit_in_way = wesnoth.get_unit(best_hex[1], best_hex[2])
            if unit_in_way and (unit_in_way.id ~= unit.id) then
                local move_away = self:find_move_out_of_way(unit_in_way, unit.id, dist_cart)
                ai.move(unit_in_way, move_away[1], move_away[2])  -- this is not a full move!
            end

            if (max_rating > -9999) then AH.movefull_stopunit(ai, unit, best_hex) end
            ai.stopunit_moves(unit)  -- in case unit was there already, or something went wrong
        end

        function prune_cart:three_different_units(list1, list2, list3)

            if list1 and list2 and list3 then
                for u1,v1 in pairs(list1) do
                    for u2,v2 in pairs(list2) do
                        for u3,v3 in pairs(list3) do
                            local tmp = {}
                            tmp[u1] = true
                            tmp[u2] = true
                            tmp[u3] = true
                            -- Cannot use # for count as keys are not numbers
                            -- Could do this with LS, but that has a lot of overhead
                            local count = 0
                            for tk,tv in pairs(tmp) do count = count + 1 end
                            --print(u1, u2, u3, count)
                            if (count == 3) then return true end
                        end
                    end
                end
            end

            -- If we got here, no 3-unit combination was found
            return false
        end


        function prune_cart:get_best_formation(hexes, weight_map, form_units, ids)
            -- Find the best formation (currently of 5 hexes)
            -- INPUTS:
            --   hexes: The map hexes to be considered for center of formation (LS)
            --        it also contains an additive value for hex rating
            --   weight: weighting function for hex that is minimum on "enemy side" (LS: same hexes as 'map)

            -- Get all units with and without MP left; do not use 'formula = ' (slow)
            --local units = wesnoth.get_units{ id = ids }
            local my_units = wesnoth.get_units{ side = wesnoth.current.side, { "not", { id = ids } } }
            local units_MP , units_noMP = {}, {}
            for i,u in ipairs(my_units) do
                if (u.moves == 0) then
                    table.insert(units_noMP, u)
                else
                    table.insert(units_MP, u)
                end
            end
            --print('#my_units, #units_MP, #units_noMP', #my_units, #units_MP, #units_noMP)
            my_units = nil  -- safeguard only

            -- Also need all enemies
            local enemies = wesnoth.get_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }
            --print('#enemies', #enemies)

            -- Take all units with moves left off the map, for enemy path finding
            for i,u in ipairs(units_MP) do wesnoth.extract_unit(u) end
            -- Get an enemy_reach_map taking only AI units that cannot move into account
            local enemy_reach_map = AH.get_enemy_dst_src()
            -- Put units back out there
            for i,u in ipairs(units_MP) do wesnoth.put_unit(u.x, u.y, u) end

            -- Also need a number of maps (this is for speed reasons, mostly)
            local MP_map = AH.get_dst_src(form_units)
            local noMP_map = LS.create()
            for i,u in ipairs(units_noMP) do
                noMP_map:insert(u.x, u.y, 1)
            end
            --AH.put_labels(noMP_map)
            --AH.put_labels(MP_map)

            local enemy_map = LS.create()
            for i,e in ipairs(enemies) do enemy_map:insert(e.x, e.y, 1) end
            --AH.put_labels(enemy_map)

            -- Map of hexes that AI units can reach
            -- This includes form_units and units_noMP, but not those not included in either of those
            local all_form_units = {}
            for i,u in ipairs(form_units) do table.insert(all_form_units, u) end
            for i,u in ipairs(units_noMP) do table.insert(all_form_units, u) end
            --print(#form_units, #units_noMP, #all_form_units)

            -- All hexes those units can reach (including those with MP=0)
            local all_reach_map = AH.get_dst_src(all_form_units)
            all_form_units = nil  -- safeguard only
            --AH.put_labels(all_reach_map)

            -- Reorganize all_reach_map so that it shows directly which units can get to which hex
            -- Needed later to identify how many units can get to hexes (done this way for speed reasons)
            all_reach_map:iter( function(x, y, v)
                local tmp_ids = {}
                for i,src in ipairs(v) do
                    local u = wesnoth.get_unit(src.x, src.y)
                    tmp_ids[u.id] = true
                end
                all_reach_map:insert(x, y, tmp_ids)
            end)
            --DBG.dbms(all_reach_map,false,"variable",false)

            -- Also get defense rating; currently only use the leader unit as example
            -- Cheap workaround for now .... -----
            local u1 = wesnoth.get_units{ side = wesnoth.current.side, canrecruit = 'yes'}
            if not u1[1] then
                u1 = wesnoth.get_units{ side = wesnoth.current.side, { "not", { id = ids } } }
            end
            u1 = u1[1]
            local eu1 = wesnoth.get_units { canrecruit = 'yes',
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }[1]

            local my_defense = LS.create()
            local enemy_defense = LS.create()

            local w,h,b = wesnoth.get_map_size()
            for x = 1,w do
                for y = 1,h do
                    local terrain = wesnoth.get_terrain(x, y)
                    if (string.sub(terrain, 1, 1) ~= 'C') and (string.sub(terrain, 1, 1) ~= 'K') then
                        my_defense:insert(x, y, wesnoth.unit_defense(u1, terrain))
                    end
                    enemy_defense:insert(x, y, wesnoth.unit_defense(eu1, terrain))
                end
            end
            -- Hexes with enemies cannot be reached
            -- We do this by deleting them from 'my_defense'
            for i,e in ipairs(enemies) do
                my_defense:remove(e.x, e.y)
            end
            --AH.put_labels(my_defense)
            --W.message { speaker = 'narrator', message = 'my defense' }

            -- Finally, eliminate 'hexes' that cannot be reached by at least 1 eligible unit
            -- !!!!! This is a work-around for now, need to come up with a better solution !!!!
            -- This needs to include units that have moved already
            hexes:iter( function(x, y, v)
                local units_in_reach = all_reach_map:get(x, y)
                if (not units_in_reach) then
                    hexes:remove(x, y)
                end
            end)
            --AH.put_labels(hexes)

            local max_rating = -9999
            local best_formation = {}

            local rating = LS.create()

            ----- For testing purposes only -----
            --local hexes = LS.create()
            --hexes:insert(16,9,1)
            --hexes:insert(16,10,1)

            hexes:iter(function(x, y, v)

                -- Find direction (orientation: ori) in which to set up the line
                local min = 9999
                local ori = 0
                for o = 0,5 do
                    local m = (weight_map:get(AH.xyoff(x, y, o, 'lu')) or 9999)
                        + (weight_map:get(AH.xyoff(x, y, o, 'ld')) or 9999)
                    if (m < min) then
                        min = m
                        ori = o
                    end
                end

                -- Now find possible formations for that orientation ('ori)
                -- Currently this is done for formations of 5; can be replaced by whatever is desired later

                local max_f = -9999
                local best_f ={ {x,y}, {x,y}, {x,y}, {x,y}, {x,y}}  -- Need to have the right format set up from beginning
                for o1u = -1, 1 do  -- hex "1 up"; 3 orientations total: ori-1, ori, ori+1
                    for o2u = -1, 1 do  -- hex "2 up"
                        local x1u, y1u = AH.xyoff(x, y, o1u+ori, 'u')
                        local x2u, y2u = AH.xyoff(x1u, y1u, o2u+ori, 'u')

                        -- Pulling everything that does not need to be in the inside loop out (for speed reasons)

                        -- Exposure rating: how many enemies can attack each "up" hex
                        -- assuming they prefer to attack closer to center hex if possible
                        local exp0u = o1u + 1
                        local exp1u = o2u - o1u + 1
                        local exp2u = 4 - exp0u - exp1u

                        -- We generally want to discourage ends that bend out toward the enemy
                        if (o2u == -1) then exp2u = exp2u * 1.25 end

                        -- Enemy hexes on the "up" half (3 hexes from which enemies could attack)
                        local xe1u, xe2u, ye1u, ye2u
                        local xe3u, ye3u = AH.xyoff(x2u, y2u, ori, 'lu')
                        if (o2u == -1) then
                            xe2u, ye2u = AH.xyoff(x2u, y2u, ori, 'ld')
                            xe1u, ye1u = AH.xyoff(x2u, y2u, ori, 'd')
                        else
                            xe2u, ye2u = AH.xyoff(x1u, y1u, ori, 'lu')
                            if (o1u == -1) then
                                xe1u, ye1u = AH.xyoff(x1u, y1u, ori, 'ld')
                            else
                                xe1u, ye1u = AH.xyoff(x, y, ori, 'lu')
                            end
                        end

                        -- As well as hexes behind the lines
                        local xb1u, xb2u, yb1u, yb2u
                        if (o1u == 1) then
                            xb2u, yb2u = AH.xyoff(x2u, y2u, ori, 'rd')
                            xb1u, yb1u = AH.xyoff(x1u, y1u, ori, 'rd')
                        else
                            xb1u, yb1u = AH.xyoff(x, y, ori, 'ru')
                            if (o2u == 1) then
                                xb2u, yb2u = AH.xyoff(x2u, y2u, ori, 'rd')
                            else
                                xb2u, yb2u = AH.xyoff(x1u, y1u, ori, 'ru')
                            end
                        end

                        -- Add large bonus for having the end of the chain
                        -- next to one of our own units that has no MP left
                        local bonus = 0
                        local xn, yn = AH.xyoff(x2u, y2u, ori, 'lu')
                        if noMP_map:get(xn, yn) then bonus = 0.8 end
                        local xn, yn = AH.xyoff(x2u, y2u, ori, 'ru')
                        if noMP_map:get(xn, yn) then bonus = 0.8 end
                        local xn, yn = AH.xyoff(x2u, y2u, ori, 'u')
                        if noMP_map:get(xn, yn) then bonus = 1.0 end
                        local f_bonus_u = (my_defense:get(x2u, y2u) or 0) * bonus

                        for o1d = -1, 1 do  -- hex "1 down"
                            for o2d =-1, 1 do  -- hex "2 down"

                                -- +1/-1 combo of o1, o2 (and vice versa) is not allowed
                                if (o1u*o2u ~= -1) and (o1d*o2d ~= -1) and (o1u*o1d ~= -1) then

                                    local x1d, y1d = AH.xyoff(x, y, o1d+ori, 'd')
                                    local x2d, y2d = AH.xyoff(x1d, y1d, o2d+ori, 'd')

                                    -- Exposure rating for the down hexes
                                    local exp0d = -o1d + 1
                                    local exp1d = -o2d + o1d + 1
                                    local exp2d = 4 - exp0d - exp1d

                                    -- We generally want to discourage ends that bend out toward the enemy
                                    -- (yes, the sign is opposite here from the "up" hexes)
                                    if (o2d == 1) then exp2d = exp2d * 1.25 end
                                    --print(exp0u, exp1u, exp2u, exp0d, exp1d, exp2d)

                                    -- Enemy hexes on the "down" half (3 hexes from which enemies could attack)
                                    local xe1d, xe2d, ye1d, ye2d
                                    local xe3d, ye3d = AH.xyoff(x2d, y2d, ori, 'ld')
                                    if (o2d == 1) then
                                        xe2d, ye2d = AH.xyoff(x2d, y2d, ori, 'lu')
                                        xe1d, ye1d = AH.xyoff(x2d, y2d, ori, 'u')
                                    else
                                        xe2d, ye2d = AH.xyoff(x1d, y1d, ori, 'ld')
                                        if (o1d == 1) then
                                            xe1d, ye1d = AH.xyoff(x1d, y1d, ori, 'lu')
                                        else
                                            xe1d, ye1d = AH.xyoff(x, y, ori, 'ld')
                                        end
                                    end

                                    -- As well as hexes behind the lines
                                    local xb1d, xb2d, yb1d, yb2d
                                    if (o1d == -1) then
                                        xb2d, yb2d = AH.xyoff(x2d, y2d, ori, 'ru')
                                        xb1d, yb1d = AH.xyoff(x1d, y1d, ori, 'ru')
                                    else
                                        xb1d, yb1d = AH.xyoff(x, y, ori, 'rd')
                                        if (o2d == -1) then
                                            xb2d, yb2d = AH.xyoff(x2d, y2d, ori, 'ru')
                                        else
                                            xb2d, yb2d = AH.xyoff(x1d, y1d, ori, 'rd')
                                        end
                                    end

                                    -- Formation rating for own units: probability to take damage times
                                    -- number of enemies that can attack here
                                    local f_own = -10000
                                    -- The exp.. can be 0, so need an extra step here, cannot use 'or'
                                    -- This excludes hexes occupied by enemies, and on the border of the map
                                    if my_defense:get(x, y) and my_defense:get(x1u, y1u)
                                        and my_defense:get(x2u, y2u) and my_defense:get(x1d, y1d)
                                        and my_defense:get(x2d, y2d)
                                    then
                                        f_own = 0
                                            - my_defense:get(x, y) * (exp0u + exp0d)
                                            - my_defense:get(x1u, y1u) * exp1u
                                            - my_defense:get(x2u, y2u) * exp2u
                                            - my_defense:get(x1d, y1d) * exp1d
                                            - my_defense:get(x2d, y2d) * exp2d
                                    end

                                    -- Formation rating for enemy units: damage an enemy can take on the given hex
                                    local f_enemy = 0
                                        + (enemy_defense:get(xe1u, ye1u) or 0)
                                        + (enemy_defense:get(xe2u, ye2u) or 0)
                                        + (enemy_defense:get(xe3u, ye3u) or 0)
                                        + (enemy_defense:get(xe1d, ye1d) or 0)
                                        + (enemy_defense:get(xe2d, ye2d) or 0)
                                        + (enemy_defense:get(xe3d, ye3d) or 0)

                                    -- Add large bonus for having the end of the chain
                                    -- next to one of our own units that has no MP left
                                    local bonus = 0
                                    local xn, yn = AH.xyoff(x2d, y2d, ori, 'ld')
                                    if noMP_map:get(xn, yn) then bonus = 0.8 end
                                    local xn, yn = AH.xyoff(x2d, y2d, ori, 'rd')
                                    if noMP_map:get(xn, yn) then bonus = 0.8 end
                                    local xn, yn = AH.xyoff(x2d, y2d, ori, 'd')
                                    if noMP_map:get(xn, yn) then bonus = 1.0 end
                                    local f_bonus = f_bonus_u + (my_defense:get(x2u, y2u) or 0) * bonus

                                    -- Doubling up units is a waste of resources
                                    local f_waste = 0
                                    if noMP_map:get(xe1u, ye1u) then f_waste = f_waste - 100000 end
                                    if noMP_map:get(xe1d, ye1d) then f_waste = f_waste - 100000 end
                                    if noMP_map:get(xe2u, ye2u) then f_waste = f_waste - 100 end
                                    if noMP_map:get(xe2d, ye2d) then f_waste = f_waste - 100 end
                                    --if noMP_map:get(xb1u, yb1u) then f_waste = f_waste - 100000 end
                                    --if noMP_map:get(xb1d, yb1d) then f_waste = f_waste - 100000 end
                                    --if noMP_map:get(xb2u, yb2u) then f_waste = f_waste - 100 end
                                    --if noMP_map:get(xb2d, yb2d) then f_waste = f_waste - 100 end

                                    -- If none of the unoccupied hexes can be reached by MP units
                                    --if ( (not MP_map:get(x, y)) or noMP_map:get(x, y) )
                                    --    and ( (not MP_map:get(x1u, y1u)) or noMP_map:get(x1u, y1u) )
                                    --    and ( (not MP_map:get(x2u, y2u)) or noMP_map:get(x2u, y2u) )
                                    --    and ( (not MP_map:get(x1d, y1d)) or noMP_map:get(x1d, y1d) )
                                    --    and ( (not MP_map:get(x2d, y2d)) or noMP_map:get(x2d, y2d) )
                                    --then
                                    --    f_waste = -100000
                                    --end

                                    -- Also exclude formation if not at least the 3 center hexes can be reached by different units
                                    --local three_units = self:three_different_units(all_reach_map:get(x, y),
                                    --    all_reach_map:get(x1u, y1u), all_reach_map:get(x1d, y1d)
                                    --)
                                    --print('3 units', three_units)
                                    --if (not three_units) then f_waste = -100000 end

                                    -- Hexes on the formation that cannot be reached by AI units,
                                    -- but can be reached by enemy get a serious reduction
                                    local f_nogo = 0
                                    if (not all_reach_map:get(x, y)) and enemy_reach_map:get(x, y) then f_nogo = f_nogo - 100 end
                                    if (not all_reach_map:get(x1u, y1u)) and enemy_reach_map:get(x1u, y1u) then f_nogo = f_nogo - 100 end
                                    if (not all_reach_map:get(x2u, y2u)) and enemy_reach_map:get(x2u, y2u) then f_nogo = f_nogo - 100 end
                                    if (not all_reach_map:get(x1d, y1d)) and enemy_reach_map:get(x1d, y1d) then f_nogo = f_nogo - 100 end
                                    if (not all_reach_map:get(x2d, y2d)) and enemy_reach_map:get(x2d, y2d) then f_nogo = f_nogo - 100 end

                                    -- Putting it all together
                                    local f = f_own + f_enemy * 1.0 + f_bonus + f_waste + f_nogo

                                    -- Add bonus for being closer to or farther from protected unit
                                    -- Any form of this always seems to make things worse, so it's disabled for now
                                    -- f = f - ((dist_cart:get(x, y) - 9) / 3.)^2.

                                    -- Add the blocking rating
                                    f = f + hexes:get(x, y)

                                    if (f > max_f) then
                                        max_f = f
                                        best_f = {
                                            { x, y, (my_defense:get(x, y) or 1000) * (exp0u + exp0d) },
                                            { x1u, y1u, (my_defense:get(x1u, y1u) or 1000) * exp1u },
                                            { x1d, y1d, (my_defense:get(x1d, y1d) or 1000) * exp1d },
                                            { x2u, y2u, (my_defense:get(x2u, y2u) or 1000) * exp2u },
                                            { x2d, y2d, (my_defense:get(x2d, y2d) or 1000) * exp2d }
                                        }
                                    end

                                    --print('formation rating', f, f_own, f_enemy, f_bonus, f_waste, f_nogo)
                                    -- Testing of the formations
                                    --local tmp = LS.create()
                                    --tmp:insert(x,y,exp0u+exp0d)
                                    --tmp:insert(x1u,y1u,exp1u)
                                    --tmp:insert(x2u,y2u,exp2u)
                                    --tmp:insert(x1d,y1d,exp1d)
                                    --tmp:insert(x2d,y2d,exp2d)
                                    --tmp:insert(xe1u,ye1u,111)
                                    --tmp:insert(xe2u,ye2u,222)
                                    --tmp:insert(xe3u,ye3u,333)
                                    --tmp:insert(xe1d,ye1d,-111)
                                    --tmp:insert(xe2d,ye2d,-222)
                                    --tmp:insert(xe3d,ye3d,-333)
                                    --tmp:insert(xb1u,yb1u,11)
                                    --tmp:insert(xb2u,yb2u,22)
                                    --tmp:insert(xb1d,yb1d,-11)
                                    --tmp:insert(xb2d,yb2d,-22)
                                    --AH.put_labels(tmp)
                                    --W.message{ speaker = 'narrator', message = 'This formation:' .. f }
                                end
                            end
                        end
                    end
                end

                --local tmp = LS.create()
                --tmp:insert(best_f[1][1], best_f[1][2], max_f)
                --tmp:insert(best_f[2][1], best_f[2][2], max_f)
                --tmp:insert(best_f[3][1], best_f[3][2], max_f)
                --tmp:insert(best_f[4][1], best_f[4][2], max_f)
                --tmp:insert(best_f[5][1], best_f[5][2], max_f)
                --AH.put_labels(tmp)
                --W.message{ speaker = 'narrator', message = 'Best formation for this hex' }

                -- If this best formation for this center hex is all occupied already
                -- or cannot be reached by at least 3 units, we give it a low rating
                -- If none of the unoccupied hexes can be reached by MP units

                if ( (not MP_map:get(best_f[1][1], best_f[1][2])) or noMP_map:get(best_f[1][1], best_f[1][2]) )
                    and ( (not MP_map:get(best_f[2][1], best_f[2][2])) or noMP_map:get(best_f[2][1], best_f[2][2]) )
                    and ( (not MP_map:get(best_f[3][1], best_f[3][2])) or noMP_map:get(best_f[3][1], best_f[3][2]) )
                    and ( (not MP_map:get(best_f[4][1], best_f[4][2])) or noMP_map:get(best_f[4][1], best_f[4][2]) )
                    and ( (not MP_map:get(best_f[5][1], best_f[5][2])) or noMP_map:get(best_f[5][1], best_f[5][2]) )
                then
                    max_f = -10000
                end

                -- Also exclude formation if not at least the 3 center hexes can be reached by different units
                local three_units = self:three_different_units(
                    all_reach_map:get(best_f[1][1], best_f[1][2]),
                    all_reach_map:get(best_f[2][1], best_f[2][2]),
                    all_reach_map:get(best_f[3][1], best_f[3][2])
                )
                --print('3 units', three_units)
                if (not three_units) then max_f = -10000 end


                if (max_f > max_rating) then
                    max_rating = max_f
                    best_formation = best_f
                end

                rating:insert(x, y, max_f)
            end)

            if (max_rating > -9999) then
                --local tmp = LS.create()
                --tmp:insert(best_formation[1][1], best_formation[1][2], max_rating)
                --tmp:insert(best_formation[2][1], best_formation[2][2], max_rating)
                --tmp:insert(best_formation[3][1], best_formation[3][2], max_rating)
                --tmp:insert(best_formation[4][1], best_formation[4][2], max_rating)
                --tmp:insert(best_formation[5][1], best_formation[5][2], max_rating)
                --AH.put_labels(tmp)
                --W.message{ speaker = 'narrator', message = 'Best formation' }
            end

            --print("Best formation score:", max_rating)
            --DBG.dbms(best_formation,false,"variable",false)
            --AH.put_labels(rating)
            --W.message{ speaker = 'narrator', message = 'Formation rating' }

            return best_formation, max_rating
        end

        function prune_cart:find_between_hexes(ids)
            -- Finds the hexes which are between 'units' and the enemies in a pathfinder sort of way
            -- Takes only AI units that cannot move any more into account

            -- This is returned as a LS
            -- The value of each hex is the number of enemy units it blocks *2

            -- Get all units with MP left; do not use 'formula = ' (slow)
            local units = wesnoth.get_units{ id = ids }
            local my_units = wesnoth.get_units{ side = wesnoth.current.side, { "not", { id = ids } } }
            local MP_units = {}
            for i,u in ipairs(my_units) do
                if (u.moves > 0) then table.insert(MP_units, u) end
            end
            --print(#my_units,#MP_units)
            my_units = nil  -- safeguard only

            -- Also need all enemies
            local enemies = wesnoth.get_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }

            -- Take all units with moves left off the map, for enemy path finding
            for i,u in ipairs(MP_units) do wesnoth.extract_unit(u) end
            -- 'units' also needs to be taken off (separately)
            for i,u in ipairs(units) do wesnoth.extract_unit(u) end

            -- Also, units that were used by deal_with_threats do not count as blocking enemies
            -- As they were not placed taking formations into account
            --print('Extracting self.data.protecting_units:', #self.data.protecting_units)
            local tmp_units = {}
            -- Need to do this as some of these units might already have been extracted previously
            for i,l in ipairs(self.data.protecting_units) do
                --print(l[1], l[2])
                local tmp = wesnoth.get_unit(l[1], l[2])
                if tmp then table.insert(tmp_units, tmp) end
            end
            --print('#tmp_units', #tmp_units)
            for i,u in ipairs(tmp_units) do wesnoth.extract_unit(u) end

            -- For speed reasons, we also set up an enemy map
            local enemy_map = LS.create()
            for i,e in ipairs(enemies) do enemy_map:insert(e.x, e.y, 1) end

            -- Now find the hexes between 'units' and 'enemies'
            local btw = LS.create()  -- temporary LS
            for i,e in ipairs(enemies) do
        for i2,unit in ipairs(units) do

                -- Path from enemy to 'units', with or without blocking by AI units
                local path, cost = wesnoth.find_path(e, unit.x, unit.y)
                local path_noblock, cost_noblock = wesnoth.find_path(e, unit.x, unit.y, {ignore_units = true})
                --print(e.id,cost,cost_noblock,e.max_moves)

                -- If path gets one move or more longer for unit, we consider it
                -- already blocked and does not need to be considered here
                -- or if more than 4 moves away
                if (cost - cost_noblock >= e.max_moves) or (cost_noblock > e.max_moves * 4) then
                    --print(e.id,'blocked already -> skipping this unit')
                else

                    for j = #path-1, 2, -1 do
                        -- Stop pathfinding if there's an enemy in the way either on the hex itself ...
                        local enemy_in_way = enemy_map:get(path[j][1], path[j][2])
                        if enemy_in_way then
                            break
                        else
                            btw:insert(path[j][1], path[j][2], 0)
                        end

                        -- ... or one of the surrounding hexes
                        local break_condition = false
                        for x, y in H.adjacent_tiles(path[j][1], path[j][2]) do
                            local enemy_in_way = enemy_map:get(x, y)
                            if enemy_in_way then
                                break_condition = true
                                break
                            else
                                btw:insert(x, y, 0)
                            end
                        end
                        if break_condition then break end
                    end
                end
        end
            end

            -- We need one extra hex of padding around this, otherwise some important hexes might be missed
            local between = LS.create()
            btw:iter( function(x, y, v)
                for xa, ya in H.adjacent_tiles(x, y) do
                    local enemy_in_way = enemy_map:get(xa, ya)
                    if not enemy_in_way then
                        between:insert(xa, ya, 0)
                    end
                end
            end)
            btw = nil

            -- And add rating for how many enemies this blocks out, weighted by their distance
            for i,e in ipairs(enemies) do
        for i2,unit in ipairs(units) do
                -- Path from enemy to 'unit'
                local path, cost = wesnoth.find_path(e, unit.x, unit.y)
                local path_noblock, cost_noblock = wesnoth.find_path(e, unit.x, unit.y, {ignore_units = true})
                --print(e.id,cost,cost_noblock,e.max_moves)

                -- If path gets more than one move longer for unit, it is
                -- already blocked and does not need to be considered here
                -- or if more than 4 moves away
                if (cost - cost_noblock > e.max_moves) or (cost_noblock > e.max_moves * 4) then
                    --print(e.id,'blocked already 2 -> skipping this unit')
                else

                    local tmp = LS.create()
                    for j = 1, #path-3 do
                        tmp:insert(path[j][1], path[j][2], 1)
                        for x, y in H.adjacent_tiles(path[j][1], path[j][2]) do
                            tmp:insert(x, y, 1)
                        end
                    end

                    tmp:iter( function(x, y, v)
                        if between:get(x, y) then
                            between:insert(x, y, between:get(x, y) + 2)
                        end
                    end)
                end
        end
            end
            --AH.put_labels(between)

            -- Put units back out there
            for i,u in ipairs(MP_units) do wesnoth.put_unit(u.x, u.y, u) end
            for i,u in ipairs(units) do wesnoth.put_unit(u.x, u.y, u) end
            for i,u in ipairs(tmp_units) do wesnoth.put_unit(u.x, u.y, u) end

            ----------------------------------------------
            -- We also define distance_map (larger toward units, smaller toward enemy)
            -- to determine in which direction lines should be foormed
            -- Need the following for hexes outside 'between' (see below) also,
            -- for now just use entire map (slow, to be improved later)
            local dist_units = AH.distance_map(units)
            local dist_enemies = AH.distance_map(enemies)

            local distance_map = LS.create()
            dist_enemies:union_merge(dist_units, function(x, y, v1, v2)
                local dw = math.sqrt(v1/#enemies) - math.sqrt(v2/#units)
                distance_map:insert(x, y, dw)
                return v1
            end)

            return between, distance_map
        end



        ----------------

        function prune_cart:cart_move_eval(id)
            -- This handles the move of the cart itself, but also attacking of enemies in the
            -- way of the cart and moving units toward enemy units that are potential threats to the cart
            -- It is all done in one CA, because only a certain number of units participate, even if more could

            local cart = wesnoth.get_units{ id = id, side = wesnoth.current.side, formula = '$this_unit.moves > 0' }[1]

            if cart then
                return 290000
            else
                return 0
            end
        end

        function prune_cart:cart_move_exec(id, goal_x, goal_y)

            local cart = wesnoth.get_units{ id = id, side = wesnoth.current.side, formula = '$this_unit.moves > 0' }[1]
            --W.message{ speaker = cart.id, message = 'Executing cart move' }

            -- First, deal with enemies in way of cart
            -- This is done before we move the cart
            self.data.protecting_units = {}
            local threats_dealt_with = self:deal_with_threats(cart, 'enemies_in_way', goal_x, goal_y)

            -- Next, move the cart itself
            local x, y = wesnoth.find_vacant_tile(goal_x, goal_y, cart)
            -- Find the next hop the cart can get to
            -- Ignore units in way, as a single unit far away could otherwise block the path,
            local next_hop = AH.next_hop(cart, x, y, {ignore_units = true})
            -- but need to be careful with that, as it could yield an unreachable hex
            next_hop = AH.next_hop(cart, next_hop[1], next_hop[2])

            if next_hop then
                if (next_hop[1] ~= cart.x) or (next_hop[2] ~= cart.y) then
                    local moving_cart = wesnoth.get_variable("moving_cart")
                    if moving_cart then
                        ai.move_full(cart, next_hop[1], next_hop[2])
                    end
                end
            end
            -- Make sure unit is really done after this
            ai.stopunit_all(cart)

            -- Finally, we find enemies that are close to the cart
            self:deal_with_threats(cart, 'close_enemies', goal_x, goal_y, threats_dealt_with)

            --W.message{ speaker = cart.id, message = 'Done cart move' }
        end

        ----------------

        function prune_cart:defensive_formation_eval(ids)

            -- Exclude leaders and healers
            local my_units = wesnoth.get_units{ side = wesnoth.current.side,
                formula = '($this_unit.moves > 0) and ($this_unit.hitpoints >= $this_unit.max_hitpoints / 2)',
                canrecruit = 'no', { "not", { id = ids } },
                { "not", { ability = "healing" } }
            }

            if my_units[1] then
                return 270000
            else
                return 0
            end
        end

        function prune_cart:defensive_formation_exec(ids)

            -- !!!! There's some duplication here between find_between_hexes() and
            -- get_best_formation().  Set up this way to be more versatile
            -- Need to evaluate for speed later

            if self.data.ids then
                ids = self.data.ids
                self.data.ids = nil
            end

            local between, distance_map = LS.create(), {}
            if (ids ~= '') then
                between, distance_map = self:find_between_hexes(ids)
            else
                --print("Calculating 'between' without protected unit")
                --W.message { speaker = 'narrator', message = 'Calculating between without protected unit' }

                -- Get any unit that cannot move any more and can be reached by an enemy
                -- and make it a center of a potential formation

                local my_units_noMP = wesnoth.get_units{ side = wesnoth.current.side, formula = '$this_unit.moves <= 0' }
                --print('#my_units_noMP', #my_units_noMP)

                local units_MP = wesnoth.get_units{ side = wesnoth.current.side, formula = '$this_unit.moves > 0' }
                -- Take all units with moves left off the map, for enemy path finding
                for i,u in ipairs(units_MP) do wesnoth.extract_unit(u) end
                -- Get an enemy_reach_map taking only AI units that cannot move into account
                local enemy_dstsrc = AH.get_enemy_dst_src()
                -- Put units back out there
                for i,u in ipairs(units_MP) do wesnoth.put_unit(u.x, u.y, u) end

                for i,u in ipairs(my_units_noMP) do
                    local rating = 0
                    for x, y in H.adjacent_tiles(u.x, u.y) do
                        if enemy_dstsrc:get(x, y) then
                            rating = rating + 1
                        end
                    end
                    if (rating > 1) then between:insert(u.x, u.y, 0) end
                end

                local enemies = wesnoth.get_units {
                    { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
                }
                distance_map = AH.distance_map(enemies)
                distance_map:iter( function(x, y, v)
                    local dw = math.sqrt(v)
                    distance_map:insert(x, y, dw)
                end)

                --AH.put_labels(between)
                --AH.put_labels(distance_map)
                --W.message { speaker = 'narrator', message = 'between' }

            end
            --AH.put_labels(between)
            --AH.put_labels(distance_map)
            --W.message { speaker = 'narrator', message = 'between' }

            -- Get units to be considered for moving into a formation
            -- Get all units first, except for the 'units'
            -- Don't use 'formula = ': too slow
            local my_units = wesnoth.get_units{ side = wesnoth.current.side, { "not", { id = ids } } }
            -- Then select units with MP, enough hitpoints etc.
            local form_units = {}
            for i,u in ipairs(my_units) do
                if (u.moves > 0) and (u.hitpoints >= u.max_hitpoints / 2) and (u.canrecruit == false) and (u.__cfg.usage ~= "healer") then
                    table.insert(form_units, u)
                end
            end
            --print(#form_units)
            my_units = nil  -- safeguard only

            local best_formation = self:get_best_formation(between, distance_map, form_units, ids)
            --W.message { speaker = 'narrator', message = 'formation rating' }

            -- Now we need to see how many units we can actually move there
            -- First, remove hexes that have units with MP=0 on them already
            for i = #best_formation, 1, -1 do
                local unit = wesnoth.get_unit(best_formation[i][1], best_formation[i][2])
                if unit then
                    if (unit.moves == 0) then
                        table.remove(best_formation, i)
                    end
                end
            end
            --DBG.dbms(best_formation,false,"variable",false)

            -- Find if a level-up attack is possible from any of the formation hexes
            local enemies = wesnoth.get_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }
            local enemy_map = LS.create()
            for i,e in ipairs(enemies) do enemy_map:insert(e.x, e.y, 1) end

            local max_rating = -9999
            local best_weapon, best_attacker, best_target, best_loc
            for i,f in ipairs(best_formation) do
                local dstsrc = AH.get_dst_src(form_units)
                local units_in_range = dstsrc:get(f[1], f[2])
                --DBG.dbms(units_in_range,false,"variable",false)

                if units_in_range then
                    for j,u in ipairs(units_in_range) do

                        for x,y in H.adjacent_tiles(f[1], f[2]) do
                            if enemy_map:get(x, y) then
                                local attacker = wesnoth.get_unit(u.x, u.y)
                                local target = wesnoth.get_unit(x, y)
                                --print(f[1], f[2], attacker.id, target.id)
                                local rating, weapon = self:get_level_up_attack_rating(attacker, target, {f[1], f[2]})
                                if (rating > max_rating) then
                                    max_rating = rating
                                    best_weapon = weapon
                                    best_attacker = attacker
                                    best_target = target
                                    best_loc = {f[1], f[2]}
                                    best_i = i
                                end
                            end
                        end
                    end
                end
            end
            --print('Level up attack rating:', max_rating)

            -- If a level-up attack was found, do it
            if (max_rating > -9999) then
                --W.message { speaker = best_attacker.id, message = "Attacking" }

                local unit_in_way = wesnoth.get_unit(best_loc[1], best_loc[2])
                if unit_in_way then
                    local units = wesnoth.get_units{ id = ids }
                    local dist_units = AH.distance_map(units)  -- if  ids == '' this will return zeros everywhere
                    local move_away = self:find_move_out_of_way(unit_in_way, best_attacker.id, dist_units, best_formation)
                    if move_away then
                        ai.move(unit_in_way, move_away[1], move_away[2])  -- this is not a full move!
                    else
                        ai.stopunit_moves(unit_in_way)  -- this is change of gamestate
                    end
                end
                -- check again that hex is available now
                local unit_in_way = wesnoth.get_unit(best_loc[1], best_loc[2])
                if unit_in_way then
                    if (unit_in_way.id == best_attacker.id) then unit_in_way = nil end
                end
                if (not unit_in_way) then
                    AH.movefull_stopunit(ai, best_attacker, best_loc)
                    ai.attack(best_attacker, best_target, best_weapon)
                end

                if (not best_target.valid) then
                    --print('Enemy was killed.  Reevaluating formations.')
                    return
                else
                    --print('Continuing with formation')
                end

                table.remove(best_formation, best_i)
            end

            -- Find units that can move there
            for i,f in ipairs(best_formation) do
                local dstsrc = AH.get_dst_src(form_units)
                local units_in_range = dstsrc:get(f[1], f[2])
                --DBG.dbms(units_in_range,false,"variable",false)

                local best_unit = {}
                local max_score = -9999
                if units_in_range then
                    for j,u in ipairs(units_in_range) do
                        local unit = wesnoth.get_unit(u.x, u.y)

                        -- Exclude leaders, 'units', healers ...
                        -- xxx need to exclude healers etc.
                        local protected_unit = false
                        for id in string.gmatch(ids, "%a+") do
                            if (id == unit.id) then protected_unit = true end
                        end
                        if (not protected_unit) and (not unit.canrecruit) and (unit.moves > 0) then
                            -- if exposure is high, then use low-experience units, otherwise the other way around
                            local score
                            if (f[3] <= 80) then
                                score = unit.hitpoints + unit.experience / 5.
                            else
                                score = unit.hitpoints - unit.experience / 5.
                            end
                            --print(unit.id, ' can reach', f[1], f[2],'   score:',score)
                            if (score > max_score) then
                                max_score = score
                                best_unit = unit
                            end
                        end
                    end
                end

                if (max_score > -9999) then
                    -- Need to test is there is a unit in the way that can be moved out
                    -- Previously we only checked for units with no MP left (unit might still be blocked in)

                    local unit_in_way = wesnoth.get_unit(f[1], f[2])
                    if unit_in_way then
                        -- This condition catches units that are almost as good as
                        -- best_unit, incl. best_unit itself
                        local sign = 1
                        if (f[3] > 80) then sign = -1 end
                        if (unit_in_way.hitpoints + sign * unit_in_way.experience / 5.+ 5
                            >= best_unit.hitpoints + sign * best_unit.experience / 5.) then
                            ai.stopunit_moves(unit_in_way)  -- this is change of gamestate
                        else
                            local units = wesnoth.get_units{ id = ids }
                            local dist_units = AH.distance_map(units)  -- if  ids == '' this will return zeros everywhere
                            local move_away = self:find_move_out_of_way(unit_in_way, best_unit.id, dist_units, best_formation)
                            if move_away then
                                ai.move(unit_in_way, move_away[1], move_away[2])  -- this is not a full move!
                            else
                                ai.stopunit_moves(unit_in_way)  -- this is change of gamestate
                            end
                        end
                    end
                    -- check again that hex is available now
                    local unit_in_way = wesnoth.get_unit(f[1], f[2])
                    if (not unit_in_way) then
                        --print('Moving:', best_unit.id, f[1], f[2])
                        AH.movefull_stopunit(ai, best_unit, f)
                    end

                    -- Best unit might or might not have moves, but only try attack if it is in position
                    if (best_unit.x == f[1]) and (best_unit.y == f[2]) then
                        -- Finally, check whether an attack from this position is possible and desirable
                        local max_rating = -9999
                        local best_target, best_weapon
                        for x,y in H.adjacent_tiles(f[1], f[2]) do

                            if enemy_map:get(x, y) then
                                local target = wesnoth.get_unit(x, y)
                                local n_weapon = 0
                                for weapon in H.child_range(best_unit.__cfg, "attack") do
                                    n_weapon = n_weapon + 1

                                    local att_stats, def_stats = wesnoth.simulate_combat(best_unit, n_weapon, target)
                                    --DBG.dbms(def_stats,false,"variable",false)

                                    local rating = 0
                                    -- This is an acceptable attack if:
                                    -- 1. There is no counter attack
                                    -- 2. Probability of death is 0% for attacker, loses < 10 HP on average
                                    if (att_stats.hp_chance[best_unit.hitpoints] == 1)
                                        or (best_unit.hitpoints - att_stats.average_hp < 10) and (att_stats.hp_chance[0] == 0)
                                    then
                                        -- Large bonus for chance of making a kill
                                        -- Otherwise mostly rating of hitpoints of both units
                                        -- Own HP three times as important -> preference to no-retaliation attack
                                        rating = target.max_hitpoints + def_stats.hp_chance[0]*100 + att_stats.average_hp * 3 - def_stats.average_hp
                                    end
                                    --print(best_unit.id, target.id, weapon.name, rating)
                                    if rating > max_rating then
                                        max_rating = rating
                                        best_target = target
                                        best_weapon = n_weapon
                                    end
                                end
                            end
                        end

                        if (max_rating > -9999) then
                            ai.attack(best_unit, best_target, best_weapon)

                            if (not best_target.valid) then
                                --print('Enemy was killed.  Reevaluating formations.')
                                return
                            else
                                --print('Continuing with formation')
                            end
                        end
                    end
                end
            end

        -- don't do the following for now
         if false then
            -- Now go over the hexes again, in case some of them were not reached, and move units toward them
            for i = #best_formation, 1, -1 do
                local unit = wesnoth.get_unit(best_formation[i][1], best_formation[i][2])
                if unit then
                    ai.stopunit_moves(unit)
                    table.remove(best_formation, i)
                end
            end
            --DBG.dbms(best_formation,false,"variable",false)

            -- Move the unit that can get closest
            for i,f in ipairs(best_formation) do
                local best_unit = {}
                local best_hop = {}
                local max_score = -9999
                local units = wesnoth.get_units{ side = wesnoth.current.side, formula = '$this_unit.moves > 0',
                    canrecruit = 'no', { "not", { id = id } },
                    {"not", { ability = "healing" } }
                }
                for j,u in ipairs(units) do
                    local nh = AH.next_hop(u, f[1], f[2])
                    if nh then
                        local score = -H.distance_between(f[1], f[2], nh[1], nh[2])

                        --print(u.id, ' can get within', -score)
                        if (score > max_score) then
                            max_score = score
                            best_unit = u
                            best_hop = nh
                        end
                    end
                end
                if (max_score > -9999) then
                    --print('Moving:', best_unit.id, best_hop[1], best_hop[2])
                    AH.movefull_stopunit(ai, best_unit, best_hop)
                end
            end
         end

            --W.message{ speaker = narrator, message = 'Done formation move' }
        end

        ---------------

        function prune_cart:healer_eval(id)
            local healers = wesnoth.get_units { side = wesnoth.current.side, ability = "healing",
                formula = '$this_unit.moves > 0', canrecruit = 'no', { "not", { id = id } }
            }

            if healers[1] then
                return 260000
            else
                return 0
            end

        end

        function prune_cart:healer_exec(id)
            --W.message{ speaker = 'narrator', message = 'Executing healer move' }

            AH.clear_labels()

            -------- Do the healer specific parts first --------

            -- Simply move the first healer first
            -- Others will be found the next time around for this CA
            local healer = wesnoth.get_units { side = wesnoth.current.side, ability = "healing",
                formula = '$this_unit.moves > 0', canrecruit = 'no', { "not", { id = id } }
            }[1]

            -- healer specific rating:
            local my_units_noMP = wesnoth.get_units{ side = wesnoth.current.side, formula = '$this_unit.moves <= 0',
                { "not", { id = id } }
            }
            --print('#my_units_noMP', #my_units_noMP)

            local units_MP = wesnoth.get_units{ side = wesnoth.current.side, formula = '$this_unit.moves > 0' }
            -- Take all units with moves left off the map, for enemy path finding
            for i,u in ipairs(units_MP) do wesnoth.extract_unit(u) end
            -- Get an enemy_reach_map taking only AI units that cannot move into account
            local enemy_dstsrc = AH.get_enemy_dst_src()
            -- Put units back out there
            for i,u in ipairs(units_MP) do wesnoth.put_unit(u.x, u.y, u) end

            local special = LS.create()
            for i,u in ipairs(my_units_noMP) do
                local rating = u.max_hitpoints - u.hitpoints + u.experience / 5.
                if (u.__cfg.usage == "healer") then rating = rating - 30. end
                -- Negative rating if we're next to another healer (that has moved already)
                for x, y in H.adjacent_tiles(u.x, u.y) do
                    -- Larger bonus for every enemy that can reach unit
                    if enemy_dstsrc:get(x, y) then
                        rating = rating + 20
                    end
                end
                for x, y in H.adjacent_tiles(u.x, u.y) do
                    special:insert(x, y, (special:get(x, y) or 0) + rating)
                end
            end
            --AH.put_labels(special)

            -------- All the rest is common to special-unit moves --------
            self:move_special_unit(healer, id, special)

            --W.message{ speaker = cart.id, message = 'Done healer move' }
        end

        ----

        function prune_cart:healing_eval(id)
            local healees = wesnoth.get_units { side = wesnoth.current.side,
                formula = '($this_unit.moves > 0) and ($this_unit.hitpoints < $this_unit.max_hitpoints - 10)',
                { "not", { id = id } }
            }

            if healees[1] then
                return 250000
            else
                return 0
            end

        end

        function prune_cart:healing_exec(id)
            --W.message{ speaker = 'narrator', message = 'Executing healing move' }

            -------- Do the healing specific parts first --------

            local healees = wesnoth.get_units { side = wesnoth.current.side,
                formula = '($this_unit.moves > 0) and ($this_unit.hitpoints < $this_unit.max_hitpoints - 10)',
                { "not", { id = id } }
            }

            -- Sort units, deal with most hurt unit first (giving a bonus for experience points)
            table.sort(healees, function(a, b)
                return (a.max_hitpoints - a.hitpoints + a.experience / 5.) > (b.max_hitpoints - b.hitpoints + b.experience / 5.)
            end)

            -- Simply move the first unit to be healed (most injured) first
            -- Others will be found the next time around for this CA
            local healing = healees[1]
            --print(healing.id, healing.max_hitpoints, healing.hitpoints, healing.hitpoints - healing.max_hitpoints)

            -- Healing specific rating:
            local healers = wesnoth.get_units { side = wesnoth.current.side, ability = "healing"}
            local villages = wesnoth.get_locations { terrain = "*^V*" }

            local special = LS.create()
            -- These ratings are not cumulative
            for i,h in ipairs(healers) do
                for x, y in H.adjacent_tiles(h.x, h.y) do
                    special:insert(x, y, 8)
                end
            end
            for i,v in ipairs(villages) do
                special:insert(v[1], v[2], 10)
            end
            --AH.put_labels(special)

            -------- All the rest is common to special-unit moves --------
            self:move_special_unit(healing, id, special)

            --W.message{ speaker = cart.id, message = 'Done healing move' }
        end

        ----

        function prune_cart:leader_eval(id)
            local leader = wesnoth.get_units { side = wesnoth.current.side, formula = '$this_unit.moves > 0',
                canrecruit = 'yes'
            }[1]

            if leader then
                return 240000
            else
                return 0
            end

        end

        function prune_cart:leader_exec(id)
            --W.message{ speaker = 'narrator', message = 'Executing leader move' }

            -------- Do the leader specific parts first --------

            local leader = wesnoth.get_units { side = wesnoth.current.side, formula = '$this_unit.moves > 0',
                canrecruit = 'yes'
            }[1]
            --print('Leader:', leader.id, wesnoth.unit_types[leader.type].level, wesnoth.sides[wesnoth.current.side].gold)

            -- !!!!!!!!!!!! I need to change this, use more accurate condition !!!!!!!!!!!!!
            if (wesnoth.sides[wesnoth.current.side].gold >= 15) then
                --print('Still gold left, stopunit_moves(leader)')
                ai.stopunit_moves(leader)
                return
            end

            -- Leader specific rating:
            local leader_level = wesnoth.unit_types[leader.type].level
            local my_units_noMP = wesnoth.get_units{ side = wesnoth.current.side, formula = '$this_unit.moves <= 0',
                { "not", { id = id } }
            }
            --print('#my_units_noMP', #my_units_noMP)

            local units_MP = wesnoth.get_units{ side = wesnoth.current.side, formula = '$this_unit.moves > 0' }
            -- Take all units with moves left off the map, for enemy path finding
            for i,u in ipairs(units_MP) do wesnoth.extract_unit(u) end
            -- Get an enemy_reach_map taking only AI units that cannot move into account
            local enemy_dstsrc = AH.get_enemy_dst_src()
            -- Put units back out there
            for i,u in ipairs(units_MP) do wesnoth.put_unit(u.x, u.y, u) end

            local special = LS.create()
            for i,u in ipairs(my_units_noMP) do
                local unit_level = wesnoth.unit_types[u.type].level
                if ( unit_level < leader_level) then
                    -- Small bonus for lower_level unit itself
                    local rating = leader_level - unit_level
                    for x, y in H.adjacent_tiles(u.x, u.y) do
                        -- Larger bonus for every enemy that can reach unit
                        if enemy_dstsrc:get(x, y) then
                            rating = rating + (leader_level - unit_level) * 10
                        end
                    end
                    for x, y in H.adjacent_tiles(u.x, u.y) do
                        special:insert(x, y, (special:get(x, y) or 0) + rating)
                    end
                end
            end
            --AH.put_labels(special)

            -------- All the rest is common to special-unit moves --------
            self:move_special_unit(leader, id, special)

            --W.message{ speaker = cart.id, message = 'Done leader move' }
        end

        function prune_cart:others_eval(id)
            -- Now we take all units that still have moves left
            local others = wesnoth.get_units { side = wesnoth.current.side, formula = '$this_unit.moves > 0'}

            if others[1] then
                return 230000
            else
                return 0
            end

        end

        function prune_cart:others_exec(id)
            --W.message{ speaker = 'narrator', message = 'Executing others move' }

            -------- Do the others specific parts first --------

            local others = wesnoth.get_units { side = wesnoth.current.side, formula = '$this_unit.moves > 0'}

            -- Simply move the first unit in the array first
            -- Others will be found the next time around for this CA
            local next_unit = others[1]

            -- Others specific rating:
            local my_units_noMP = wesnoth.get_units{ side = wesnoth.current.side, formula = '$this_unit.moves <= 0',
                { "not", { id = id } }
            }
            local special = AH.inverse_distance_map(my_units_noMP)
            --AH.put_labels(special)

            -------- All the rest is common to special-unit moves --------
            self:move_special_unit(next_unit, id, special)

            --W.message{ speaker = cart.id, message = 'Done others move' }
        end

        function prune_cart:more_defensive_formation_eval()

            -- Now we take all units that still have moves left
            -- See if there are injured units that can be reached by enemies
            -- or leaders or healers
            local my_units = wesnoth.get_units { side = wesnoth.current.side }
            local units_MP, units_to_protect = {}, {}
            for i,u in ipairs(my_units) do
                if (u.moves == 0) then
                    if (u.hitpoints < u.max_hitpoints - 10) or (u.canrecruit == true) or (u.__cfg.usage == "healer") then
                        table.insert(units_to_protect, u)
                    end
                else
                    table.insert(units_MP, u)
                end
            end

            -- Take all units with moves left off the map, for enemy path finding
            for i,u in ipairs(units_MP) do wesnoth.extract_unit(u) end
            -- Get an enemy_reach_map taking only AI units that cannot move into account
            local enemy_dstsrc = AH.get_enemy_dst_src()
            -- Put units back out there
            for i,u in ipairs(units_MP) do wesnoth.put_unit(u.x, u.y, u) end

            local ids = ''
            for i,u in ipairs(units_to_protect) do

                local in_enemy_reach = false
                for x, y in H.adjacent_tiles(u.x, u.y) do
                    if enemy_dstsrc:get(x, y) then in_enemy_reach = true end
                end
                if in_enemy_reach then
                    if (ids == '') then
                        ids = ids .. u.id
                    else
                        ids = ids .. ',' .. u.id
                    end
                end
            end
            --print(ids)

            if units_MP[1] and (ids ~= '') then
                self.data.ids = ids
                return 235000
            else
                self.data.ids = nil
                return 0
            end
        end

        function prune_cart:yet_more_defensive_formation_eval()

            -- Now we take all units that still have moves left and move them into formations without protecting anybody
            -- This cannot be combined with previous CA because of blacklisting

            local my_units = wesnoth.get_units { side = wesnoth.current.side }
            local units_MP = {}
            for i,u in ipairs(my_units) do
                if (u.moves > 0) then
                    table.insert(units_MP, u)
                end
            end

            if units_MP[1] then
                --print('yet more:', 234000)
                return 234000
            else
                --print('yet more:', 0)
                return 0
            end
        end

        return prune_cart
    end
}
