return {
    init = function(ai)

        local bottleneck_defense = {}

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}
        local LS = wesnoth.require "lua/location_set.lua"
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

        function bottleneck_defense:get_rating(unit, hex_def, hex_healer, hex_leader, hex_healing, is_leader, is_healer)
            -- Calculate rating of a unit given a hex's defense, healer, leader and healing values
            -- Don't want to extract is_healer and is_leader inside this function, as it is very slow

            local rating = 0

            -- Defense positioning rating
            if hex_def and (not is_healer) and (not is_leader) then
                rating = hex_def + unit.hitpoints/10. + unit.experience/100.
            end

            -- Healer positioning rating
            if hex_healer and is_healer then
                local healer_rating = hex_healer + unit.hitpoints/10. + unit.experience/100.
                if (healer_rating > rating) then rating = healer_rating end
            end

            -- Leader positioning rating
            if hex_leader and is_leader then
                local leader_rating = hex_leader + unit.hitpoints/10. + unit.experience/100.
                if (leader_rating > rating) then rating = leader_rating end
            end

            -- Injured unit positioning
            if hex_healing and (unit.hitpoints < unit.max_hitpoints) then
                local healing_rating = hex_healing + (unit.max_hitpoints - unit.hitpoints)
                if (healing_rating > rating) then rating = healing_rating end
            end

            return rating
        end

        function bottleneck_defense:move_out_of_way(unit)
            -- Find the best move out of the way for a unit
            -- Only move toward the east (=away from enemy)
            -- and choose the shortest possible move

            -- just a sanity check: unit to move out of the way needs to be on our side:
            if (unit.side ~= wesnoth.current.side) then return nil end

           local reach_map = AH.LS_of_triples(wesnoth.find_reach(unit))

           -- Find all the occupied hexes, by any unit
           -- (too slow if we do this inside the loop for a specific hex)
           local all_units = wesnoth.get_units { }
           local occ_hexes = LS:create()
           for i,u in ipairs(all_units) do
               occ_hexes:insert(u.x, u.y)
           end
           --DBG.dbms(occ_hexes,false,"variable",false)

           -- find the closest unoccupied reachable hex in the east
           local best_reach = -1
           local best_hex = 0
           for ind,r in pairs(reach_map.values) do
               -- (r > best_reach) : move shorter than previous best move
               -- (x > unit.x) : move toward east ***** map-specific *****
               -- (not occ_hex) : unoccupied hexes only
               local x = AH.get_LS_xy(ind)
               if (r > best_reach) and (x > unit.x) and (not occ_hexes.values[ind]) then
                   best_reach = r
                   best_hex = ind
               end
           end
           --print("Best reach: ",unit.id, best_reach,best_hex)

           if best_reach > -1 then return best_hex end
        end

        function bottleneck_defense:get_level_up_attack_rating(attacker, ind, targets, unit_in_way, target_level)

            local max_rating = 0
            local best_tar = {}
            local best_weapon = -1

            local x, y = AH.get_LS_xy(ind)
            -- Go through the targets
            for i,t in ipairs(targets) do

                local target_level = t.__cfg.level
                local n_weapon = 0
                for weapon in H.child_range(attacker.__cfg, "attack") do
                    n_weapon = n_weapon + 1

                    local x1, y1 = attacker.x, attacker.y

                    local att_stats, def_stats = 0, 0
                    -- if there's already a unit there
                    if unit_in_way then
                        --print("in the way:", unit_in_way.id,x,y,attacker.id)
                        wesnoth.put_unit(13, 5, unit_in_way)   -- ***** map-specific *****
                        wesnoth.put_unit(x, y, attacker)
                        att_stats, def_stats = wesnoth.simulate_combat(attacker, n_weapon, t)
                        wesnoth.put_unit(x1, y1, attacker)
                        wesnoth.put_unit(x, y, unit_in_way)
                    else
                        wesnoth.put_unit(x, y, attacker)
                        att_stats, def_stats = wesnoth.simulate_combat(attacker, n_weapon, t)
                        wesnoth.put_unit(x1, y1, attacker)
                    end
                    --DBG.dbms(att_stats,false,"variable",false)
                    --print(attacker.id, att_stats.average_hp, def_stats.average_hp)

                    -- Level-up attack when:
                    -- 1. max_experience-experience <= target.level and chance to die = 0
                    -- 2. max_experience-experience <= target.level*8 and chance to die = 0
                    --   and chance to kill > 66% and remaining av hitpoints > 20
                    -- #1 is a definite level up, #2 is not, so #1 gets priority

                    local rating = 0
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
                        best_tar = t
                        best_weapon = n_weapon
                    end
                end
            end

            --print("Best level-up attack:", max_rating, best_weapon)
            return max_rating, best_weapon, best_tar
        end

        function bottleneck_defense:bottleneck_move_eval(cfg)
            -- Find the best unit move
            -- get all units with moves left
            local units = wesnoth.get_units { side = wesnoth.current.side, formula = '$this_unit.moves > 0' }

            -- No units with moves left, nothing to be done here
            if (not units[1]) then return 0 end

            -- Set up the arrays that tell the AI where to defend the bottleneck
            -- Get the x and y coordinates (this assumes that cfg.x and cfg.y have the same length)
            local def_coords = {}
            for x in string.gmatch(cfg.x, "%d+") do
                table.insert(def_coords, { x })
            end
            local i = 1
            for y in string.gmatch(cfg.y, "%d+") do
                table.insert(def_coords[i], y)
                table.insert(def_coords[i], 10010 - i * 10) -- the rating
                i = i + 1
            end
            --DBG.dbms(def_coords)

            -- ***** start map-specific information *****
            -- defense positioning
            local coords = {
                {14,6,1000}, {14,10,1000},
                {15,8,990}, {15,9,990},
                {15,7,980}, {15,10,980}, {16,7,980}, {16,8,980}, {16,9,980},
                {15,6,970}, {15,11,970}, {16,6,970}, {16,10,970},
                {17,7,970}, {17,8,970}, {17,9,970}, {17,10,970},
                {18,6,960}, {18,7,960}, {18,8,960}, {18,9,960}
            }
            local coords = AH.array_merge(def_coords, coords)
            local def_map = AH.LS_of_triples(coords)
            --AH.put_labels(def_map)
            --W.message {speaker="narrator", message="Defense map" }

            -- healer positioning
            local coords = { {14,7,10000}, {14,9,10000},
                {15,9,5000}, {15,8,4990}, {15,10,4990}, {15,7,4990},
                {16,8,4980}, {16,9,4980}, {16,7,4980},
                {17,7,970}, {17,8,970}, {17,9,970}, {17,10,970},
                {18,6,960}, {18,7,960}, {18,8,960}, {18,9,960}
            }
            local healer_map = AH.LS_of_triples(coords)
            --AH.put_labels(healer_map)
            --W.message {speaker="narrator", message="Healer map" }

            -- leader positioning
            local coords = { {14,7,10000}, {14,9,10000},
                {15,8,4000}, {15,9,3990}, {15,7,3990}, {15,10,3990},
                {16,8,3980}, {16,7,3980}, {16,9,3980},
                {17,7,970}, {17,8,970}, {17,9,970}, {17,10,970},
                {18,6,960}, {18,7,960}, {18,8,960}, {18,9,960}
            }
            local leader_map = AH.LS_of_triples(coords)
            --AH.put_labels(leader_map)
            --W.message {speaker="narrator", message="leader map" }

            -- healing map: positions next to healers, needs to be calculated each time
            -- Get all locations next to a healer with x>13, and excluding (14,8)
            local healers = wesnoth.get_units { side = wesnoth.current.side, ability = "healing" }
            local healing_map = LS.create()
            for i,h in ipairs(healers) do
                for x, y in H.adjacent_tiles(h.x, h.y) do
                    if (x > 13) and not((x == 14) and (y == 8)) then
                        healing_map:insert(x, y, 3000 + h.x/100.)  -- farther away from enemy is good **** map-specific
                    end
                end
            end
            --AH.put_labels(healing_map)
            --W.message {speaker="narrator", message="Healing map" }

            -- Find all attack positions next to enemies
            -- This part would be *a lot* easier if ai.get_attacks() existed already
            -- Will be redone when that has been added
            local attack_locs = wesnoth.get_locations { x="14-999",
                { "filter_adjacent_location", {
                    { "filter", { { "not", {side = wesnoth.current.side} } } }
                } }
            }
            local attack_map = LS.create()
            for i,l in ipairs(attack_locs) do

                local data = {}
                -- For each location, store the attackable enemies, and whether there is a unit in the way
                -- (want to do this here, rather than in the loop, for speed reasons)
                local targets = wesnoth.get_units {
                    { "not", {side = wesnoth.current.side} },
                    { "filter_location",
                        { { "filter_adjacent_location", { x = l[1], y = l[2] } } }
                    }
                }
                --print(l[1], l[2], #targets)
                data.targets = targets

                local unit_in_way = wesnoth.get_unit(l[1], l[2])
                if unit_in_way then
                    data.unit_in_way = unit_in_way
                end
                attack_map:insert(l[1], l[2], data)
            end
            --AH.put_labels(attack_map)
            --W.message {speaker="narrator", message="Attack map" }

            -- ***** end map-specific information *****


            -- First, get the rating of all units in their current positions
            -- A move is only considered if it improves the overall rating,
            -- that is, its rating must be higher than:
            --   1. the rating of the unit on the target hex (if there is one)
            --   2. the rating of the currently considered unit on its current hex
            local all_units = wesnoth.get_units { side = wesnoth.current.side }
            local occ_hexes = LS.create()
            for i,u in ipairs(all_units) do

                -- Is this a healer or leader?
                local is_healer = (u.__cfg.usage == "healer")
                local is_leader = ((u.type == "Sergeant") or (u.type == "Lieutenant") or (u.type == "General"))

                local rating = self:get_rating(u, def_map:get(u.x, u.y), healer_map:get(u.x, u.y), leader_map:get(u.x, u.y), healing_map:get(u.x, u.y), is_leader, is_healer)
                occ_hexes:insert(u.x, u.y, rating)

                -- A unit that cannot move any more, (or at least cannot move out of the way)
                -- must be considered to have a very high rating (it's in the best position
                -- it can possibly achieve)
                local best_move_away = self:move_out_of_way(u)
                if (not best_move_away) then occ_hexes:insert(u.x, u.y, 20000) end
            end
            --AH.put_labels(occ_hexes)
            --W.message {speaker="narrator", message="occupied hexes" }


            -- Go through all units with moves left
            -- Variables to store best unit/move
            local max_rating = 0
            local best_unit = {}
            local best_hex = -1

            for i,u in ipairs(units) do

                -- Is this a healer or leader?
                local is_healer = (u.__cfg.usage == "healer")
                local is_leader = ((u.type == "Sergeant") or (u.type == "Lieutenant") or (u.type == "General"))

                local current_rating = self:get_rating(u, def_map:get(u.x, u.y), healer_map:get(u.x, u.y), leader_map:get(u.x, u.y), healing_map:get(u.x, u.y), is_leader, is_healer)
                --print("Finding move for:",u.id, u.x, u.y, current_rating)

                -- Find all hexes the unit can reach ...
                local reach_map = LS.of_pairs(wesnoth.find_reach(u))

                -- ... and go through all of them
                for ind,r in pairs(reach_map.values) do
                    local rating = self:get_rating(u, def_map.values[ind], healer_map.values[ind], leader_map.values[ind], healing_map.values[ind], is_leader, is_healer)
                    --print(" ->",ind,rating,occ_hexes.values[ind])

                    -- A move is only considered if it improves the overall rating,
                    -- that is, its rating must be higher than:
                    --   1. the rating of the unit on the target hex (if there is one)
                    --   2. the rating of the currently considered unit on its current hex
                    if occ_hexes.values[ind] and (occ_hexes.values[ind] >= rating) then rating = 0 end
                    if (rating <= current_rating) then rating = 0 end
                    --print("   ->",ind,rating,occ_hexes.values[ind])

                    -- If the target hex is occupied, give it a (very) small penalty
                    if occ_hexes.values[ind] then rating = rating - 0.001 end

                    -- Now only valid and possible moves should have a rating > 0
                    if rating > max_rating then
                        max_rating = rating
                        best_unit = u
                        best_hex = ind
                    end

                    -- Finally, we check whether a level-up attack is possible from this hex
                    if attack_map.values[ind] then
                        local lu_rating, weapon, target = self:get_level_up_attack_rating(u, ind, attack_map.values[ind].targets, attack_map.values[ind].unit_in_way)
                        -- Very small penalty if there's a unit in the way
                        if attack_map.values[ind].unit_in_way then lu_rating = lu_rating - 0.001 end

                        if occ_hexes.values[ind] and (occ_hexes.values[ind] >= lu_rating) then lu_rating = 0 end
                        if (lu_rating <= current_rating) then lu_rating = 0 end

                        if (lu_rating > max_rating) then
                            --print("New best level-up attack",u.id, ind, lu_rating, target.id, weapon)
                            max_rating = lu_rating
                            best_unit = u
                            best_hex = ind
                            self.data.lu_target = target
                            self.data.lu_weapon = weapon
                        end
                    end

                end
            end

            --print("Best move:",best_unit.id,max_rating,AH.get_LS_xy(best_hex))

            -- If there's another unit in the best location, moving it out of the way becomes the best move
            -- It should have been checked that this is possible
            local x, y = AH.get_LS_xy(best_hex)
            local unit_in_way = wesnoth.get_units { x=x, y=y, { "not", { id = best_unit.id } } }[1]
            if unit_in_way then
                best_hex = self:move_out_of_way(unit_in_way)
                best_unit = unit_in_way
                --print("Moving out of way:", best_unit.id, AH.get_LS_xy(best_hex))

                -- also need to delete these, they will be reset on the next turn
                self.data.lu_target = nil
                self.data.lu_weapon = nil
            end

            if max_rating == 0 then
                -- In this case we take MP away from all units
                -- This is done so that the RCA AI CAs can be kept in place
                self.data.bottleneck_moves_done = true
            else
                self.data.bottleneck_moves_done = false
                self.data.unit = best_unit
                self.data.hex = best_hex
            end
            return 300000
        end

        function bottleneck_defense:bottleneck_move_exec()

            if self.data.bottleneck_moves_done then
                local units = wesnoth.get_units { side = wesnoth.current.side, formula = '$this_unit.moves > 0' }
                for i,u in ipairs(units) do
                    ai.stopunit_moves(u)
                end
            else
                local x, y = AH.get_LS_xy(self.data.hex)
                --print("Moving unit:",self.data.unit.id, self.data.unit.x, self.data.unit.y, " ->", x, y, " -- turn:", wesnoth.current.turn)

                if (self.data.unit.x ~= x) or (self.data.unit.y ~= y) then  -- test needed for level-up move
                    ai.move(self.data.unit, x, y)   -- don't want full move, as this might be stepping out of the way
                end

                -- If this is a move for a level-up attack, do that one also
                if self.data.lu_target then
                    --print("Level-up attack",self.data.unit.id, self.data.lu_target.id, self.data.lu_weapon)
                    --W.message {speaker=self.data.unit.id, message="Level-up attack" }

                    local dw = -1
                    if AH.got_1_11() then dw = 0 end
                    ai.attack(self.data.unit, self.data.lu_target, self.data.lu_weapon + dw)
                end
            end

            self.data.unit = nil
            self.data.hex = nil
            self.data.lu_target = nil
            self.data.lu_weapon = nil
            self.data.bottleneck_moves_done = nil
        end

        function bottleneck_defense:bottleneck_attack_eval()

            -- All units with attacks_left and enemies next to them
            -- This will be much easier once the 'attacks' variable is implemented
            local attackers = wesnoth.get_units {
                side = wesnoth.current.side, formula = "$this_unit.attacks_left > 0",
                { "filter_adjacent", { { "not", {side = wesnoth.current.side} } }
                }
            }
            --print("\n\nAttackers:",#attackers)
            if (not attackers[1]) then return 0 end

            -- Variables to store best attacker/target pair
            local max_rating = 0
            local best_att = {}
            local best_tar = {}
            local best_weapon = -1

            -- Now loop through the attackers, and all attacks for each
            for i,a in ipairs(attackers) do

                local targets = wesnoth.get_units {
                    { "not", {side = wesnoth.current.side} },
                    { "filter_adjacent", { id = a.id } }
                }
                --print("  ",a.id,#targets)

                for j,t in ipairs(targets) do

                    local n_weapon = 0
                    for weapon in H.child_range(a.__cfg, "attack") do
                        n_weapon = n_weapon + 1

                        local att_stats, def_stats = wesnoth.simulate_combat(a, n_weapon, t)
                        --DBG.dbms(def_stats,false,"variable",false)

                        local rating = 0
                        -- This is an acceptable attack if:
                        -- 1. There is no counter attack
                        -- 2. Probability of death is >=67% for enemy, 0% for attacker
                        if (att_stats.hp_chance[a.hitpoints] == 1)
                            or (def_stats.hp_chance[0] >= 0.67) and (att_stats.hp_chance[0] == 0)
                        then
                            rating = 1000 + t.max_hitpoints + def_stats.hp_chance[0]*100 + att_stats.average_hp - def_stats.average_hp
                            -- if there's a chance to make the kill, unit closest to leveling up goes first, otherwise the other unit
                            if (def_stats.hp_chance[0] >= 0.67) then
                                rating = rating + (a.experience - a.max_experience) / 10.
                            else
                                rating = rating - (a.experience - a.max_experience) / 10.
                            end
                        end
                        --print(a.id, t.id,weapon.name, rating)
                        if rating > max_rating then
                            max_rating = rating
                            best_att = a
                            best_tar = t
                            best_weapon = n_weapon
                        end
                    end
                end
            end

            --print("Best attack:",best_att.id, best_tar.id, max_rating, best_weapon)

            if max_rating == 0 then
                -- In this case we take attacks away from all units
                -- This is done so that the RCA AI CAs can be kept in place
                self.data.bottleneck_attacks_done = true
            else
                self.data.bottleneck_attacks_done = false
                self.data.attacker = best_att
                self.data.target = best_tar
                self.data.weapon = best_weapon
            end
            return 290000
        end

        function bottleneck_defense:bottleneck_attack_exec()

            if self.data.bottleneck_attacks_done then
                local units = wesnoth.get_units { side = wesnoth.current.side, formula = '$this_unit.attacks_left > 0' }
                for i,u in ipairs(units) do
                    ai.stopunit_attacks(u)
                end
            else
                --W.message {speaker=self.data.attacker.id, message="Attacking" }

                local dw = -1
                if AH.got_1_11() then dw = 0 end
                ai.attack(self.data.attacker, self.data.target, self.data.weapon + dw)
            end

            self.data.attacker = nil
            self.data.target = nil
            self.data.weapon = nil
            self.data.bottleneck_attacks_done = nil
        end

        return bottleneck_defense
    end
}
