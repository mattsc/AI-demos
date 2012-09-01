return {
    init = function(ai)

        local grunt_rush = {}
        -- More generic grunt rush (and can, in fact, be used with other unit types as well)

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        local LS = wesnoth.require "lua/location_set.lua"
        local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

        ------ Stats at beginning of turn -----------

        -- This will be blacklisted after first execution each turn
        function grunt_rush:stats_eval()
            local score = 999999
            return score
        end

        function grunt_rush:stats_exec(type)
            -- type: check whether this unit type is on the recruit list, otherwise end the game
            type = type or 'None'  -- in case we forget to set the type

            local tod = wesnoth.get_time_of_day()
            print(' Beginning of Turn ' .. wesnoth.current.turn .. ' (' .. tod.name ..') stats:')

            for i,s in ipairs(wesnoth.sides) do
                local total_hp = 0
                local units = wesnoth.get_units { side = s.side }
                for i,u in ipairs(units) do total_hp = total_hp + u.hitpoints end
                print('   Player ' .. s.side .. ': ' .. #units .. ' Units with total HP: ' .. total_hp)
            end

            -- We also add a check here whether the AI uses the right faction
            -- This cannot be checked directly, but at least for mainline the method is unique anyway
            -- Yes, this is done every turn, but it takes so little time and is only done once, it doesn't matter

            -- Faction is checked by seeing if the side can recruit orcs
            local can_recruit_grunts = false
            for i,r in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                if (r == type) then
                    can_recruit_grunts = true
                    break
                end
            end

            if (not can_recruit_grunts) then
                W.message { 
                    speaker = 'narrator',
                    caption = "Message from the Grunt Rush AI",
                    image = 'wesnoth-icon.png', message = "I only know how to play if I can recruit the following unit type: " .. type .. ".  Sorry!"
                }
                W.endlevel { result = 'defeat' }
            end
        end

        ----

        function grunt_rush:recruit_orcs_eval()
            -- Check if there is enough gold to recruit at least a grunt
            if (wesnoth.sides[wesnoth.current.side].gold < 12) then return 0 end

            -- Check if leader is on keep
            local leader = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]
            if (not wesnoth.get_terrain_info(wesnoth.get_terrain(leader.x, leader.y)).keep) then return 0 end

            -- If there's at least one free castle hex, go to recruiting
            local castle = wesnoth.get_locations {
                x = leader.x, y = leader.y, radius = 5,
                { "filter_radius", { terrain = 'C*,K*' } }
            }
            for i,c in ipairs(castle) do
                local unit = wesnoth.get_unit(c[1], c[2])
                if (not unit) then return 180000 end
            end

            -- Otherwise: no recruiting
            return 0
        end

        function grunt_rush:recruit_orcs_exec()
            -- Recruiting logic (in that order):
            -- - If there isn't an assassin, recruit one
            -- - If we have <60% grunts (not counting leader), recruit a grunt
            -- - If average grunt HP < 25(?), recruit a grunt
            -- - If there isn't an Archer, or wolf, recruit one
            -- - If there are fewer than 3 Assassins, recruit one
            -- - Otherwise, recruit randomly from Archer, Assassin, Wolf Rider
            -- All of this is contingent on having enough gold (eval checked for gold >= 12)
            -- -> if not enough gold for something else, recruit a grunt at the end

            -- Recruit on the castle hex that is closest to the combination of the enemy leaders
            local enemy_leaders = wesnoth.get_units { canrecruit = 'yes',
	        { "filter_side", { { "enemy_of", {side = wesnoth.current.side} } } }
            }

            local leader = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]
            local castle = wesnoth.get_locations {
                x = leader.x, y = leader.y, radius = 5,
                { "filter_radius", { terrain = 'C*,K*' } }
            }

            local max_rating, best_hex = -9e99, {}
            for i,c in ipairs(castle) do
                local rating = -9e99
                local unit = wesnoth.get_unit(c[1], c[2])
                if (not unit) then
                    for j,e in ipairs(enemy_leaders) do
                        rating = rating + 1 / H.distance_between(c[1], c[2], e.x, e.y) ^ 2.
                    end
                    if (rating > max_rating) then 
                        max_rating, best_hex = rating, { c[1], c[2] }
                    end
                end
            end

            -- Recruit an assassin, if there is none
            local assassin = wesnoth.get_units { side = wesnoth.current.side, type = 'Orcish Assassin' }[1]
            if (not assassin) and (wesnoth.sides[wesnoth.current.side].gold >= 17) then
                --print('recruiting assassin')
                ai.recruit('Orcish Assassin', best_hex[1], best_hex[2])
                return
            end

            -- Recruit an orc if we have fewer than 60% grunts (not counting the leader)
            local grunts = wesnoth.get_units { side = wesnoth.current.side, type = 'Orcish Grunt' }
            local all_units_nl = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'no' }
            if (#grunts / (#all_units_nl + 0.0001) < 0.6) then  -- +0.0001 to avoid div-by-zero
                --print('recruiting grunt based on numbers')
                ai.recruit('Orcish Grunt', best_hex[1], best_hex[2])
                return
            end

            -- Recruit an orc if their average HP is <25
            local av_hp_grunts = 0
            for i,g in ipairs(grunts) do av_hp_grunts = av_hp_grunts + g.hitpoints / #grunts end
            if (av_hp_grunts < 25) then
                --print('recruiting grunt based on average hitpoints:', av_hp_grunts)
                ai.recruit('Orcish Grunt', best_hex[1], best_hex[2])
                return
            end

            -- Recruit an archer, if there is none
            local archer = wesnoth.get_units { side = wesnoth.current.side, type = 'Orcish Archer' }[1]
            if (not archer) and (wesnoth.sides[wesnoth.current.side].gold >= 14) then
                --print('recruiting archer')
                ai.recruit('Orcish Archer', best_hex[1], best_hex[2])
                return
            end

            -- Recruit a wolf rider, if there is none
            local wolfrider = wesnoth.get_units { side = wesnoth.current.side, type = 'Wolf Rider' }[1]
            if (not wolfrider) and (wesnoth.sides[wesnoth.current.side].gold >= 17) then
                --print('recruiting wolfrider')
                ai.recruit('Wolf Rider', best_hex[1], best_hex[2])
                return
            end

            -- Recruit an assassin, if there are fewer than 3 (additional action to previous single assassin recruit)
            local assassins = wesnoth.get_units { side = wesnoth.current.side, type = 'Orcish Assassin' }
            if (#assassins < 3) and (wesnoth.sides[wesnoth.current.side].gold >= 17) then
                --print('recruiting assassin based on numbers')
                ai.recruit('Orcish Assassin', best_hex[1], best_hex[2])
                return
            end

            -- If we got here, none of the previous conditions kicked in -> random recruit
            -- (if gold >= 17, for simplicity)
            if (wesnoth.sides[wesnoth.current.side].gold >= 17) then
                W.set_variable { name = "LUA_random", rand = 'Orcish Archer,Orcish Assassin,Wolf Rider' }
                local type = wesnoth.get_variable "LUA_random"
                wesnoth.set_variable "LUA_random"
                --print('random recruit: ', type)

                ai.recruit(type, best_hex[1], best_hex[2])
                return
            end

            -- If we got here, there wasn't enough money to recruit something other than a grunt
            --print('recruiting grunt based on gold')
            ai.recruit('Orcish Grunt', best_hex[1], best_hex[2])
        end

---------------------

        function grunt_rush:recruit_general_eval(rusher_type)
            -- The type of unit for the rush defaults to grunt, but can be set as something else
            if (not rusher_type) then rusher_type = 'Orcish Grunt' end

            -- Start the rush recruiting after first 3 other units have been recruited
            local units = wesnoth.get_units { side = wesnoth.current.side }
            if (#units < 4) then return 0 end

            -- Check if there is enough gold to recruit the rusher_type unit
            if (wesnoth.sides[wesnoth.current.side].gold < wesnoth.unit_types[rusher_type].cost) then return 0 end

            -- Check if leader is on keep
            local leader = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]

            -- Check if we have fewer than 60% rusher_type units
            local rushers = wesnoth.get_units { side = wesnoth.current.side, type = rusher_type }
            local all_units = wesnoth.get_units { side = wesnoth.current.side }
            -- This one is just for stats display in the terminal window
	    local enemies = wesnoth.get_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
	    }
            --print('#all_units, #rushers, #enemies', #all_units, #rushers, #enemies)

            if (#rushers / (#all_units+1) > 0.6) then return 0 end
            if (not wesnoth.get_terrain_info(wesnoth.get_terrain(leader.x, leader.y)).keep) then return 0 end

            local castle = wesnoth.get_locations {
                x = leader.x, y = leader.y, radius = 10,
                { "filter_radius", { terrain = 'C*,K*' } }
            }
            for i,c in ipairs(castle) do
                --print(i, c[1], c[2])
                local unit = wesnoth.get_unit(c[1], c[2])
                if (not unit) then return 300000 end
            end

            return 0
        end

        function grunt_rush:recruit_general_exec(rusher_type)
            -- The type of unit for the rush defaults to grunt, but can be set as something else
            if (not rusher_type) then rusher_type = 'Orcish Grunt' end

            -- Recruit on the castle hex that is closest to the combination of the enemy leaders
            local enemy_leaders = wesnoth.get_units { canrecruit = 'yes',
	        { "filter_side", { { "enemy_of", {side = wesnoth.current.side} } } }
            }

            local leader = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]
            local castle = wesnoth.get_locations {
                x = leader.x, y = leader.y, radius = 5,
                { "filter_radius", { terrain = 'C*,K*' } }
            }

            local max_rating, best_hex = -9e99, {}
            for i,c in ipairs(castle) do
                local rating = -9e99
                local unit = wesnoth.get_unit(c[1], c[2])
                if (not unit) then
                    for j,e in ipairs(enemy_leaders) do
                        rating = rating + 1 / H.distance_between(c[1], c[2], e.x, e.y) ^ 2.
                    end
                    if (rating > max_rating) then 
                        max_rating, best_hex = rating, { c[1], c[2] }
                    end
                end
            end

            ai.recruit(rusher_type, best_hex[1], best_hex[2])
        end

---------------------

        function grunt_rush:grab_villages_eval(rusher_type)
            -- In principle this is for grunts, but a different unit type can be passed as an argument
            if (not rusher_type) then rusher_type = 'Orcish Grunt' end

            -- Check if there are units with moves left
            local units = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'no', 
                formula = '$this_unit.moves > 0'
            }
            if (not units[1]) then return 0 end

	    local enemies = wesnoth.get_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
	    }

            local villages = wesnoth.get_locations { terrain = '*^V*' }
            -- Just in case:
            if (not villages[1]) then return 0 end
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
                if (max_rating >= 1000) then return return_value else return 0 end
            end
            return 0
        end

        function grunt_rush:grab_villages_exec()
            AH.movefull_stopunit(ai, self.data.unit, self.data.village)
            self.data.unit, self.data.village = nil, nil
        end

---------------------------

        function grunt_rush:spread_poison_eval()
            -- If a unit with a poisoned weapon can make an attack, we'll do that preferentially
            -- (with some exceptions)
            local poisoners = wesnoth.get_units { side = wesnoth.current.side, 
                formula = '$this_unit.attacks_left > 0',
                { "filter_wml", {
                    { "attack", {
                        { "specials", {
                            { "poison", { } }
                        } }
                    } }
                } }
            }
            --print('#poisoners', #poisoners)
            if (not poisoners[1]) then return 0 end

            local attacks = AH.get_attacks(poisoners)
            --print('#attacks', #attacks)
            if (not attacks[1]) then return 0 end

            -- Go through all possible attacks with poisoners
            local max_rating, best_attack = -9e99, {}
            for i,a in ipairs(attacks) do
                local attacker = wesnoth.get_unit(a.att_loc.x, a.att_loc.y)
                local defender = wesnoth.get_unit(a.def_loc.x, a.def_loc.y)

                -- Don't try to poison an already poisoned unit
                local poisoned = H.get_child(defender.__cfg, "status").poisoned

                -- For now, we also simply don't poison units on villages (unless standard combat CA does it)
                local on_village = wesnoth.get_terrain_info(wesnoth.get_terrain(defender.x, defender.y)).village

                -- Also, poisoning units that would level up through the attack is very bad
                local about_to_level = defender.max_experience - defender.experience <= attacker.__cfg.level

                if (not poisoned) and (not on_village) and (not about_to_level) then
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
                return 190000
            end
            return 0
        end

        function grunt_rush:spread_poison_exec()
            local attacker = wesnoth.get_unit(self.data.attack.att_loc.x, self.data.attack.att_loc.y)
            local defender = wesnoth.get_unit(self.data.attack.def_loc.x, self.data.attack.def_loc.y)

            AH.movefull_stopunit(ai, attacker, self.data.attack.x, self.data.attack.y)
            local dw = -1
            if AH.got_1_11() then dw = 0 end
            ai.attack(attacker, defender, 2 + dw)

            self.data.attack = nil
        end

        return grunt_rush	
    end
}
