return {
    init = function(ai)

        local generic_rush = {}
        -- More generic grunt rush (and can, in fact, be used with other unit types as well)

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        local LS = wesnoth.require "lua/location_set.lua"
        local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"
        local RFH = wesnoth.require "~/add-ons/AI-demos/lua/recruit_filter_helper.lua"

        function generic_rush:hp_ratio(my_units, enemies)
            -- Hitpoint ratio of own units / enemy units
            -- If arguments are not given, use all units on the side
            if (not my_units) then
                my_units = AH.get_live_units { { "filter_side", {{"allied_with", {side = wesnoth.current.side} }} } }
            end
            if (not enemies) then
                enemies = AH.get_live_units {
                    { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
                }
            end

            local my_hp, enemy_hp = 0, 0
            for i,u in ipairs(my_units) do my_hp = my_hp + u.hitpoints end
            for i,u in ipairs(enemies) do enemy_hp = enemy_hp + u.hitpoints end

            --print('HP ratio:', my_hp / (enemy_hp + 1e-6)) -- to avoid div by 0
            return my_hp / (enemy_hp + 1e-6), my_hp, enemy_hp
        end

        ------ Stats at beginning of turn -----------

        -- This will be blacklisted after first execution each turn
        function generic_rush:stats_eval()
            local score = 999999
            return score
        end

        function generic_rush:stats_exec()
            local tod = wesnoth.get_time_of_day()
            print(' Beginning of Turn ' .. wesnoth.current.turn .. ' (' .. tod.name ..') stats:')

            for i,s in ipairs(wesnoth.sides) do
                local total_hp = 0
                local units = AH.get_live_units { side = s.side }
                for i,u in ipairs(units) do total_hp = total_hp + u.hitpoints end
                print('   Player ' .. s.side .. ': ' .. #units .. ' Units with total HP: ' .. total_hp)
            end
        end

        ------- Recruit CA --------------

        wesnoth.require("~add-ons/AI-demos/lua/generic-recruit_engine.lua").init(ai, generic_rush)

        -------- Castle Switch CA --------------

        function generic_rush:castle_switch_eval()
            local leader = wesnoth.get_units {
                    side = wesnoth.current.side,
                    canrecruit = 'yes',
                    formula = '($this_unit.moves = $this_unit.max_moves) and ($this_unit.hitpoints = $this_unit.max_hitpoints)'
                }[1]
            if not leader then
                -- CA is irrelevant if no leader
                return 0
            end

            local keeps = wesnoth.get_locations { terrain = "K*,*^Kov" }
            if #keeps == 2 then
                -- Skip if there aren't extra keeps to evaluate
                -- In this situation we'd only switch keeps if we were running away
                return 0
            end

            local enemy_leaders = AH.get_live_units { canrecruit = 'yes',
	            { "filter_side", { { "enemy_of", {side = wesnoth.current.side} } } }
            }

            -- Look for the best keep
            local best_score, best_loc = 0, {}
            for i,loc in ipairs(keeps) do
                -- Only consider keeps within 3 turns movement
                local path, cost = wesnoth.find_path(leader, loc[1], loc[2])
                local score = 0
                -- Prefer closer keeps to enemy
                local turns = cost/leader.max_moves
                if turns <= 3 and turns > 0 then
                    score = 1/turns
                    for j,e in ipairs(enemy_leaders) do
                        score = score + 1 / H.distance_between(loc[1], loc[2], e.x, e.y) ^ 2.
                    end

                    if score > best_score then
                        best_score = score
                        best_loc = loc
                    end
                end
            end

            if best_score > 0 then
                self.data.target_keep = best_loc
                return 290000
            end

            return 0
        end

        function generic_rush:castle_switch_exec()
            local leader = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]

            local x, y = self.data.target_keep[1], self.data.target_keep[2]
            local next_hop = AH.next_hop(leader, x, y)
            if next_hop and ((next_hop[1] ~= leader.x) or (next_hop[2] ~= leader.y)) then

                -- See if there is a nearby village that can be captured en-route
                local close_villages = wesnoth.get_locations {
                    { "and", { x = next_hop[1], y = next_hop[2], radius = 3 }},
                    terrain = "*^V*",
                    owner_side = 0 }
                for i,loc in ipairs(close_villages) do
                    local path_village, cost_village = wesnoth.find_path(leader, loc[1], loc[2])
                    if cost_village <= leader.moves then
                        local dummy_leader = wesnoth.copy_unit(leader)
                        dummy_leader.x = loc[1]
                        dummy_leader.y = loc[2]
                        local path_keep, cost_keep = wesnoth.find_path(dummy_leader, x, y)
                        -- There is, go there instead
                        if cost_keep <= leader.max_moves then
                            next_hop = loc
                            break
                        end
                    end
                end

                ai.move(leader, next_hop[1], next_hop[2])
            end
        end

        ------- Grab Villages CA --------------

        function generic_rush:grab_villages_eval()
            if AH.print_eval() then print('     - Evaluating grab_villages CA:', os.clock()) end

            -- Determine the unit type for the rusher first (use other units first for grabbing villages)
            local rusher_type = 'Orcish Grunt'  -- The default

            -- Faction is checked by seeing if the side can recruit the rusher unit type
            for i,r in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                if (r == 'Elvish Fighter') or (r == 'Spearman') or (r == 'Skeleton')
                    or (r == 'Dwarvish Fighter') or (r == 'Drake Fighter') then
                    --print('grab_villages: Found in recruit list: ' .. r)
                    rusher_type = r
                end
            end

            -- Check if there are units with moves left
            local units = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'no',
                formula = '$this_unit.moves > 0'
            }
            if (not units[1]) then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end

            local enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }

            local villages = wesnoth.get_locations { terrain = '*^V*' }
            -- Just in case:
            if (not villages[1]) then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end
            --print('#units, #enemies', #units, #enemies)

            -- First check if attacks are possible for any unit
            local return_value = 200000
            local attacks = AH.get_attacks(units)
            -- If one with > 50% chance of kill is possible, set return_value to lower than combat CA
            for i,a in ipairs(attacks) do
                if (a.def_stats.hp_chance[0] > 0.5) then
                    return_value = 90000
                end
            end

            -- Now we check if a unit can get to a village
            local max_rating, best_village, best_unit = -9e99, {}, {}
            for i,u in ipairs(units) do
                for j,v in ipairs(villages) do
                    local path, cost = wesnoth.find_path(u, v[1], v[2])

                    local unit_in_way = wesnoth.get_unit(v[1], v[2])
                    if unit_in_way then
                        if (unit_in_way.id == u.id) then unit_in_way = nil end
                    end

                    -- Rate all villages that can be reached and are unoccupied by other units
                    if (cost <= u.moves) and (not unit_in_way) then
                        --print('Can reach:', u.id, v[1], v[2], cost)
                        local rating = 0

                        -- If an enemy can get within one move, we want to hold it
                        for k,e in ipairs(enemies) do
                            local path_e, cost_e = wesnoth.find_path(e, v[1], v[2])
                            if (cost_e <= e.max_moves) then
                                --print('  within enemy reach', e.id)
                                rating = rating + 10
                            end
                        end

                        -- Unowned and enemy-owned villages get a large bonus
                        local owner = wesnoth.get_village_owner(v[1], v[2])
                        if (not owner) then
                            rating = rating + 1000
                        else
                            if wesnoth.is_enemy(owner, wesnoth.current.side) then rating = rating + 2000 end
                        end

                        -- Grunts (or unit defined in 'rusher_type') are needed elsewhere, so use other units first
                        if (u.type ~= rusher_type) then rating = rating + 1 end

                        -- Finally, since these can be reached by the enemy, want the strongest orc to go first
                        rating = rating + u.hitpoints / 100.

                        if (rating > max_rating) then
                            max_rating, best_village, best_unit = rating, v, u
                        end

                        --print('  rating:', rating)
                    end
                end
            end
            --print('max_rating', max_rating)

            if (max_rating > -9e99) then
                self.data.unit, self.data.village = best_unit, best_village
                if (max_rating >= 1000) then
                    if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                    return return_value else return 0
                end
            end
            if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
            return 0
        end

        function generic_rush:grab_villages_exec()
            if AH.print_exec() then print('     - Executing grab_villages CA') end

            AH.movefull_stopunit(ai, self.data.unit, self.data.village)
            self.data.unit, self.data.village = nil, nil
        end

        ------- Spread Poison CA --------------

        function generic_rush:spread_poison_eval()
            if AH.print_eval() then print('     - Evaluating spread_poison CA:', os.clock()) end

            -- If a unit with a poisoned weapon can make an attack, we'll do that preferentially
            -- (with some exceptions)
            local poisoners = AH.get_live_units { side = wesnoth.current.side,
                formula = '$this_unit.attacks_left > 0',
                { "filter_wml", {
                    { "attack", {
                        { "specials", {
                            { "poison", { } }
                        } }
                    } }
                } },
                canrecruit = 'no'
            }
            --print('#poisoners', #poisoners)
            if (not poisoners[1]) then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end

            local attacks = AH.get_attacks(poisoners)
            --print('#attacks', #attacks)
            if (not attacks[1]) then
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 0
            end

            -- Go through all possible attacks with poisoners
            local max_rating, best_attack = -9e99, {}
            for i,a in ipairs(attacks) do
                local attacker = wesnoth.get_unit(a.att_loc.x, a.att_loc.y)
                local defender = wesnoth.get_unit(a.def_loc.x, a.def_loc.y)

                -- Don't try to poison a unit that cannot be poisoned
                local status = H.get_child(defender.__cfg, "status")
                local cant_poison = status.poisoned or status.not_living

                -- For now, we also simply don't poison units on villages (unless standard combat CA does it)
                local on_village = wesnoth.get_terrain_info(wesnoth.get_terrain(defender.x, defender.y)).village

                -- Also, poisoning units that would level up through the attack is very bad
                local about_to_level = defender.max_experience - defender.experience <= attacker.__cfg.level

                if (not cant_poison) and (not on_village) and (not about_to_level) then
                    -- Strongest enemy gets poisoned first
                    local rating = defender.hitpoints

                    -- Always attack enemy leader, if possible
                    if defender.canrecruit then rating = rating + 1000 end

                    -- Enemies that can regenerate are not good targets
                    if wesnoth.unit_ability(defender, 'regenerate') then rating = rating - 1000 end

                    -- More priority to enemies on strong terrain
                    local defender_defense = 100 - wesnoth.unit_defense(defender, wesnoth.get_terrain(defender.x, defender.y))
                    rating = rating + defender_defense / 2.

                    -- For the same attacker/defender pair, go to strongest terrain
                    local attack_defense = 100 - wesnoth.unit_defense(attacker, wesnoth.get_terrain(a.x, a.y))
                    rating = rating + attack_defense / 100.
                    --print('rating', rating)

                    if rating > max_rating then
                        max_rating, best_attack = rating, a
                    end
                end
            end

            if (max_rating > -9e99) then
                self.data.attack = best_attack
                if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
                return 190000
            end
            if AH.print_eval() then print('       - Done evaluating:', os.clock()) end
            return 0
        end

        function generic_rush:spread_poison_exec()
            if AH.print_exec() then print('     - Executing spread_poison CA') end

            local attacker = wesnoth.get_unit(self.data.attack.att_loc.x, self.data.attack.att_loc.y)
            local defender = wesnoth.get_unit(self.data.attack.def_loc.x, self.data.attack.def_loc.y)

            AH.movefull_stopunit(ai, attacker, self.data.attack.x, self.data.attack.y)

            -- Find the poison weapon
            -- If several attacks have poison, this will always find the last one
            local poison_weapon, weapon_number = -1, 0
            for att in H.child_range(attacker.__cfg, 'attack') do
                weapon_number = weapon_number + 1
                for sp in H.child_range(att, 'specials') do
                    if H.get_child(sp, 'poison') then
                        --print('is_poinsoner:', attacker.id, ' weapon number: ', weapon_number)
                        poison_weapon = weapon_number
                    end
                end
            end

            local dw = -1
            if AH.got_1_11() then dw = 0 end
            ai.attack(attacker, defender, poison_weapon + dw)

            self.data.attack = nil
        end

        return generic_rush
    end
}
