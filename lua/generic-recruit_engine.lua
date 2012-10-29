return {
    init = function(ai, ai_cas)
        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"

        function living(unit)
            return not helper.get_child(unit.__cfg, "status").not_living
        end

        function get_best_defense(unit)
            local terrain_archetypes = { "Wo", "Ww", "Wwr", "Ss", "Gt", "Ds", "Ft", "Hh", "Mm", "Vi", "Ch", "Uu", "At", "Qt", "^Uf", "Xt" }
            local best_defense = 100

            for i, terrain in ipairs(terrain_archetypes) do
                local defense = wesnoth.unit_defense(unit, terrain)
                if defense < best_defense then
                    best_defense = defense
                end
            end

            return best_defense
        end

        function analyze_enemy_unit(unit_type_id)
            local function get_best_attack(attacker, defender, unit_defense, can_poison)
                -- Try to find the average damage for each possible attack and return the one that deals the most damage.
                -- Would be preferable to call simulate combat, but that requires the defender to be on the map according
                -- to documentation and we are looking for hypothetical situations so would have to search for available
                -- locations for the defender that would have the desired defense. We would also need to remove nearby units
                -- in order to ensure that adjacent units are not modifying the result. In addition, the time of day is
                -- assumed to be neutral here, which is not assured in the simulation.
                -- Ideally, this function would be a clone of simulate combat, but run for each time of day in the scenario and on arbitrary terrain.
                -- In several cases this function only approximates the correct value (eg Thunderguard vs Goblin Spearman has damage capped by target health)
                -- In some cases (like poison), this approximation is preferred to the actual value.
                local best_damage = 0
                local best_attack = nil
                -- This doesn't actually check for the ability steadfast, but gives correct answer in the default era
                -- TODO: find a more reliable method
                local steadfast = false -- wesnoth.unit_ability(defender, "resistance")

                for attack in helper.child_range(wesnoth.unit_types[attacker.type].__cfg, "attack") do
                    local defense = unit_defense
                    local poison = false
                    -- TODO: handle more abilities (charge, drain)
                    for special in helper.child_range(attack, 'specials') do
                        local mod
                        if helper.get_child(special, 'poison') and can_poison then
                            poison = true
                        end

                        -- Handle marksman and magical
                        -- TODO: Make this work properly for UMC chance_to_hit
                        mod = helper.get_child(special, 'chance_to_hit')
                        if mod then
                            if mod.cumulative then
                                if mod.value > defense then
                                    defense = mod.value
                                end
                            else
                                defense = mod.value
                            end
                        end
                    end

                    -- Handle drain for defender
                    local drain_recovery = 0
                    for defender_attack in helper.child_range(defender.__cfg, 'attack') do
                        if (defender_attack.range == attack.range) then
                            for special in helper.child_range(defender_attack, 'specials') do
                                if helper.get_child(special, 'drains') and living(attacker) then
                                    -- TODO: handle chance to hit & resistance
                                    -- currently assumes no resistance and 50% chance to hit using supplied constant
                                    drain_recovery = defender_attack.damage*defender_attack.number*25
                                end
                            end
                        end
                    end

                    defense = defense/100.0
                    local resistance = wesnoth.unit_resistance(defender, attack.type)
                    if steadfast and (resistance < 100) then
                        resistance = 100 - ((100 - resistance) * 2)
                        if (resistance < 50) then
                            resistance = 50
                        end
                    end
                    local base_damage = attack.damage*resistance
                    if (base_damage < 100) and (attack.damage > 0) then
                        -- Damage is always at least 1
                        base_damage = 100
                    end
                    local attack_damage = base_damage*attack.number*defense-drain_recovery

                    local poison_damage = 0
                    if poison then
                        -- Add poison damage * probability of poisoning
                        poison_damage = 800*(1-((1-defense)^attack.number))
                        attack_damage = attack_damage + poison_damage
                    end

                    if (not best_attack) or (attack_damage > best_damage) then
                        best_damage = attack_damage
                        best_attack = attack
                    end
                end

                return best_attack, best_damage, poison_damage
            end

            local analysis = {}

            local unit = wesnoth.create_unit { type = unit_type_id }
            local can_poison = living(unit) or wesnoth.unit_ability(unit, 'regenerate')
            local flat_defense = wesnoth.unit_defense(unit, "Gt")
            local best_defense = get_best_defense(unit)

            for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                local recruit = wesnoth.create_unit { type = recruit_id }
                local can_poison_retaliation = living(recruit) or wesnoth.unit_ability(recruit, 'regenerate')
                best_flat_attack, best_flat_damage, flat_poison = get_best_attack(recruit, unit, flat_defense, can_poison)
                best_high_defense_attack, best_high_defense_damage, high_defense_poison = get_best_attack(recruit, unit, best_defense, can_poison)
                best_retaliation, best_retaliation_damage, retaliation_poison = get_best_attack(unit, recruit, wesnoth.unit_defense(recruit, "Gt"), can_poison_retaliation)

                local result = {
                    offense = { attack = best_flat_attack, damage = best_flat_damage, poison_damage = flat_poison },
                    defense = { attack = best_high_defense_attack, damage = best_high_defense_damage, poison_damage = high_defense_poison },
                    retaliation = { attack = best_retaliation, damage = best_retaliation_damage, poison_damage = retaliation_poison }
                }
                analysis[recruit_id] = result
            end

            return analysis
        end

        function get_hp_efficiency()
            local efficiency = {}
            for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                local unit = wesnoth.create_unit { type = recruit_id }
                local flat_defense = (100-wesnoth.unit_defense(unit, "Gt"))
                -- raw durability is a function of defense and hp
                -- efficiency decreases faster than cost increases to avoid recruiting many expensive units
                -- there is a requirement for bodies in order to block movement
                efficiency[recruit_id] = (wesnoth.unit_types[recruit_id].max_hitpoints^1.7)/(wesnoth.unit_types[recruit_id].cost^2)
            end
            return efficiency
        end

        function can_slow(unit)
            for defender_attack in helper.child_range(unit.__cfg, 'attack') do
                for special in helper.child_range(defender_attack, 'specials') do
                    if helper.get_child(special, 'slow') then
                        return true
                    end
                end
            end
            return false
        end

        function get_hp_ratio_with_gold()
            -- Hitpoint ratio of own units / enemy units
            -- Also convert available gold to a hp estimate
            my_units = AH.get_live_units {
                { "filter_side", {{"allied_with", {side = wesnoth.current.side} }} }
            }
            enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }

            local my_hp, enemy_hp = 0, 0
            for i,u in ipairs(my_units) do my_hp = my_hp + u.hitpoints end
            for i,u in ipairs(enemies) do enemy_hp = enemy_hp + u.hitpoints end

            my_hp = my_hp + wesnoth.sides[wesnoth.current.side].gold*2.3
            local enemy_gold = 0
            local enemies = wesnoth.get_sides {{"enemy_of", {side = wesnoth.current.side} }}
            for i,s in ipairs(enemies) do
                enemy_gold = enemy_gold + s.gold
            end
            enemy_hp = enemy_hp+enemy_gold*2.3
            hp_ratio = my_hp/(enemy_hp + 1e-6)

            return hp_ratio
        end

        function do_recruit_eval(data)
            -- Check if leader is on keep
            local leader = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]

            if (not leader) or (not wesnoth.get_terrain_info(wesnoth.get_terrain(leader.x, leader.y)).keep) then
                return 0
            end

            -- Check if there is enough gold to recruit a unit
            local gold = wesnoth.sides[wesnoth.current.side].gold
            local enough_gold = false
            for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                if wesnoth.unit_types[recruit_id].cost <= gold then
                    enough_gold = true
                    break
                end
            end
            if not enough_gold then
                return 0
            end

            local best_hex = ai_cas:find_best_recruit_hex(leader)
            if #best_hex == 0 then
                return 0
            end

            if data.recruit == nil then
                data.recruit = init_data()
            end
            data.recruit.best_hex = best_hex
            return 300000
        end

        function init_data()
            local data = {}
            data.hp_efficiency = get_hp_efficiency()

            -- Count enemies of each type
            local enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }}}
            }
            local enemy_counts = {}
            local enemy_types = {}

            local function add_unit_type(unit_type)
                if enemy_counts[unit_type] == nil then
                    table.insert(enemy_types, unit_type)
                    enemy_counts[unit_type] = 1
                else
                    enemy_counts[unit_type] = enemy_counts[unit_type] + 1
                end
            end

            -- Collect all enemies on map
            for i, unit in ipairs(enemies) do
                add_unit_type(unit.type)
            end
            -- Collect all possible enemy recruits and count them as virtual enemies
            local enemy_sides = wesnoth.get_sides({
                { "enemy_of", {side = wesnoth.current.side} },
                { "has_unit", { canrecruit = true }} })
            for i, side in ipairs(enemy_sides) do
                for j, unit_type in ipairs(wesnoth.sides[side.side].recruit) do
                    add_unit_type(unit_type)
                end
            end
            data.enemy_counts = enemy_counts
            data.enemy_types = enemy_types
            data.num_enemies = #enemies

            return data
        end

        function ai_cas:recruit_rushers_eval()
            local start_time, ca_name = os.clock(), 'recruit_rushers'
            if AH.print_eval() then print('     - Evaluating recruit_rushers CA:', os.clock()) end

            local score = do_recruit_eval(self.data)
            if score == 0 then
                -- We're done for the turn, discard data
                self.data.recruit = nil
            end

            AH.done_eval_messages(start_time, ca_name)
            return score
        end

        function ai_cas:recruit_rushers_exec()
            if AH.print_exec() then print('   ' .. os.clock() .. ' Executing recruit_rushers CA') end
            if AH.show_messages() then W.message { speaker = 'narrator', message = 'Recruiting' } end

            local efficiency = self.data.recruit.hp_efficiency
            local enemy_counts = self.data.recruit.enemy_counts
            local enemy_types = self.data.recruit.enemy_types
            local num_enemies =  self.data.recruit.num_enemies
            local hp_ratio = get_hp_ratio_with_gold()
            local distance_to_enemy, enemy_location = AH.get_closest_enemy()
            local best_hex = self.data.recruit.best_hex

            -- Determine effectiveness of recruitable units against each enemy unit type
            local recruit_effectiveness = {}
            local recruit_vulnerability = {}
            local attack_type_count = {} -- The number of units who will likely use a given attack type
            local attack_range_count = {} -- The number of units who will likely use a given attack range
            local unit_attack_type_count = {} -- The attack types a unit will use
            local unit_attack_range_count = {} -- The ranges a unit will use
            local enemy_type_count = 0
            for i, unit_type in ipairs(enemy_types) do
                local analysis = analyze_enemy_unit(unit_type)
                enemy_type_count = enemy_type_count + 1
                for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                    -- This line should be moved out of the loop!
                    local recruit_count = #(AH.get_live_units { side = wesnoth.current.side, type = recruit_id, canrecruit = 'no' })

                    if recruit_effectiveness[recruit_id] == nil then
                        recruit_effectiveness[recruit_id] = 0
                        recruit_vulnerability[recruit_id] = 0
                    end
                    recruit_effectiveness[recruit_id] = recruit_effectiveness[recruit_id] + analysis[recruit_id].defense.damage * enemy_counts[unit_type]^2
                    recruit_vulnerability[recruit_id] = recruit_vulnerability[recruit_id] + (analysis[recruit_id].retaliation.damage * enemy_counts[unit_type])^3

                    local attack_type = analysis[recruit_id].defense.attack.type
                    if attack_type_count[attack_type] == nil then
                        attack_type_count[attack_type] = 0
                    end
                    attack_type_count[attack_type] = attack_type_count[attack_type] + recruit_count

                    local attack_range = analysis[recruit_id].defense.attack.range
                    if attack_range_count[attack_range] == nil then
                        attack_range_count[attack_range] = 0
                    end
                    attack_range_count[attack_range] = attack_range_count[attack_range] + recruit_count

                    if unit_attack_type_count[recruit_id] == nil then
                        unit_attack_type_count[recruit_id] = {}
                    end
                    unit_attack_type_count[recruit_id][attack_type] = true

                    if unit_attack_range_count[recruit_id] == nil then
                        unit_attack_range_count[recruit_id] = {}
                    end
                    unit_attack_range_count[recruit_id][attack_range] = true
                end
            end
            for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                recruit_effectiveness[recruit_id] = (recruit_effectiveness[recruit_id] / (num_enemies)^2)^0.5
                recruit_vulnerability[recruit_id] = (recruit_vulnerability[recruit_id] / ((num_enemies)^2))
            end
            -- Correct count of units for each range
            local most_common_range = nil
            local most_common_range_count = 0
            for range, count in pairs(attack_range_count) do
                attack_range_count[range] = count/enemy_type_count
                if attack_range_count[range] > most_common_range_count then
                    most_common_range = range
                    most_common_range_count = attack_range_count[range]
                end
            end
            -- Correct count of units for each attack type
            for attack_type, count in pairs(attack_type_count) do
                attack_type_count[attack_type] = count/enemy_type_count
            end

            -- Find best recruit based on damage done to enemies present, speed, and hp/gold ratio

            local recruit_scores = {}
            local best_scores = {offense = 0, defense = 0, move = 0}
            for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                -- Count number of units with the same attack type. Used to avoid recruiting too many of the same unit
                local attack_types = 0
                local recruit_count = 0
                for attack_type, count in pairs(unit_attack_type_count[recruit_id]) do
                    attack_types = attack_types + 1
                    recruit_count = recruit_count + attack_type_count[attack_type]
                end
                recruit_count = recruit_count / attack_types
                local recruit_modifier = 1+recruit_count/50

                -- Use time to enemy to encourage recruiting fast units when the opponent is far away (game is beginning or we're winning)
                local recruit_unit = wesnoth.create_unit { type = recruit_id, x = best_hex[1], y = best_hex[2] }
                local path, cost = wesnoth.find_path(recruit_unit, enemy_location.x, enemy_location.y, {ignore_units = true})
                local move_score = ((wesnoth.unit_types[recruit_id].max_moves / cost)^0.5) / wesnoth.unit_types[recruit_id].cost^0.4

                -- Estimate effectiveness on offense and defense
                local offense_score = recruit_effectiveness[recruit_id]/(wesnoth.unit_types[recruit_id].cost^0.3*recruit_modifier^4)
                local defense_score = efficiency[recruit_id]/recruit_vulnerability[recruit_id]

                local unit_score = {offense = offense_score, defense = defense_score, move = move_score}
                recruit_scores[recruit_id] = unit_score
                for key, score in pairs(unit_score) do
                    if score > best_scores[key] then
                        best_scores[key] = score
                    end
                end

                if can_slow(recruit_unit) then
                    unit_score["slows"] = true
                end
            end
            local best_score = 0
            local recruit_type = nil
            local offense_weight = 2.5
            local defense_weight = 1/hp_ratio^0.7
            local move_weight = (distance_to_enemy/15)^2
            for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                local scores = recruit_scores[recruit_id]
                local offense_score = (scores["offense"]/best_scores["offense"])^0.5
                local defense_score = (scores["defense"]/best_scores["defense"])^0.5
                local move_score = scores["move"]/best_scores["move"]

                local score = offense_score*offense_weight + defense_score*defense_weight + move_score*move_weight

                local bonus =0
                if scores["slows"] then
                    bonus = bonus + 0.75
                end
                for attack_range, count in pairs(unit_attack_range_count[recruit_id]) do
                    bonus = bonus + 0.02 * most_common_range_count / (attack_range_count[attack_range]+1)
                end
                score = score + bonus

                --print(recruit_id .. " score: " .. offense_score*offense_weight .. " + " .. defense_score*defense_weight .. " + " .. move_score*move_weight  .. " + " .. bonus  .. " = " .. score)
                if score > best_score then
                    best_score = score
                    recruit_type = recruit_id
                end
            end
            if wesnoth.unit_types[recruit_type].cost <= wesnoth.sides[wesnoth.current.side].gold then
                ai.recruit(recruit_type, best_hex[1], best_hex[2])
            end
        end

        function ai_cas:find_best_recruit_hex(leader)
            -- Recruit on the castle hex that is closest to the combination of the enemy leaders
            local enemy_leaders = AH.get_live_units { canrecruit = 'yes',
	            { "filter_side", { { "enemy_of", {side = wesnoth.current.side} } } }
            }

            local castle = wesnoth.get_locations {
                x = leader.x, y = leader.y, radius = 200,
                { "filter_radius", { terrain = 'C*^*,K*^*,*^Kov,*^Cov' } }
            }
            local width,height,border = wesnoth.get_map_size()

            local max_rating, best_hex = -1, {}
            for i,c in ipairs(castle) do
                local rating = 0
                local unit = wesnoth.get_unit(c[1], c[2])
                if (not unit) and c[1] > 0 and c[1] <= width and c[2] > 0 and c[2] <= height then
                    for j,e in ipairs(enemy_leaders) do
                        rating = rating + 1 / H.distance_between(c[1], c[2], e.x, e.y) ^ 2.
                    end
                    if (rating > max_rating) then
                        max_rating, best_hex = rating, { c[1], c[2] }
                    end
                end
            end

            return best_hex
        end
    end -- init()
}
