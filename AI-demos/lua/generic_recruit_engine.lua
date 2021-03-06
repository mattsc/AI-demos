return {
    -- init parameters:
    -- ai: a reference to the ai engine so recruit has access to ai functions
    --   It is also possible to pass an ai table directly to the execution function, which will then override the value passed here
    -- ai_cas: an object reference to store the CAs and associated data
    --   the CA will use the function names ai_cas:recruit_rushers_eval/exec, so should be referenced by the object name used by the calling AI
    --   ai_cas also has the functions find_best_recruit, find_best_recruit_hex, prerecruit_units and analyze_enemy_unit added to it
    --     find_best_recruit, find_best_recruit_hex may be useful for writing recruitment code separately from the engine
    -- params: parameters to configure recruitment
    --      score_function: function that returns the CA score when recruit_rushers_eval wants to recruit
    --          (default returns the RCA recruitment score)
    --      randomness: a measure of randomness in recruitment
    --          higher absolute values increase randomness, with values above about 3 being close to completely random
    --          (default = 0.1)
    --      min_turn_1_recruit: function that returns true if only enough units to grab nearby villages should be recruited turn 1, false otherwise
    --          (default always returns false)
    --      leader_takes_village: function that returns true if and only if the leader is going to move to capture a village this turn
    --          (default always returns true)
    --      enemy_types: array of default enemy unit types to consider if there are no enemies on the map
    --          and no enemy sides exist or have recruit lists
    -- params to eval/exec functions:
    --      avoid_map: location set listing hexes on which we should
    --          not recruit, unless no other hexes are available
    --      outofway_units: a table of type { id = true } listing units that
    --          can move out of the way to make place for recruiting. It
    --          must be checked beforehand that these units are able to move,
    --          away. This is not done here.

    init = function(ai, ai_cas, params)
        if not params then
            params = {}
        end
        math.randomseed(os.time())

        local AH = wesnoth.require "ai/lua/ai_helper.lua"
        local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"
        local LS = wesnoth.require "location_set"
        local COMP = wesnoth.require "~/add-ons/AI-demos/lua/compatibility.lua"

        local function print_time(...)
            if turn_start_time then
                AH.print_ts_delta(turn_start_time, ...)
            else
                AH.print_ts(...)
            end
        end

        local recruit_data = {}

        local no_village_cost = function(recruit_id)
            return wesnoth.unit_types[recruit_id].cost+wesnoth.unit_types[recruit_id].level+wesnoth.sides[wesnoth.current.side].village_gold
        end

        local get_hp_efficiency = function (table, recruit_id)
            -- raw durability is a function of hp and the regenerates ability
            -- efficiency decreases faster than cost increases to avoid recruiting many expensive units
            -- there is a requirement for bodies in order to block movement

            -- There is currently an assumption that opponents will average about 15 damage per strike
            -- and that two units will attack per turn until the unit dies to estimate the number of hp
            -- gained from regeneration
            local effective_hp = wesnoth.unit_types[recruit_id].max_hitpoints

            local unit = COMP.create_unit {
                type = recruit_id,
                random_traits = false,
                name = "X",
                random_gender = false
            }
            -- Find the best regeneration ability and use it to estimate hp regained by regeneration
            local abilities = wml.get_child(unit.__cfg, "abilities")
            local regen_amount = 0
            if abilities then
                for regen in wml.child_range(abilities, "regenerate") do
                    if regen.value > regen_amount then
                        regen_amount = regen.value
                    end
                end
                effective_hp = effective_hp + (regen_amount * effective_hp/30)
            end
            local hp_score = math.max(math.log(effective_hp/20),0.01)
            local efficiency = hp_score/(wesnoth.unit_types[recruit_id].cost^2)
            local no_village_efficiency = hp_score/(no_village_cost(recruit_id)^2)

            table[recruit_id] = {efficiency, no_village_efficiency}
            return {efficiency, no_village_efficiency}
        end
        local efficiency = {}
        setmetatable(efficiency, { __index = get_hp_efficiency })

        function poisonable(unit)
            return not unit.status.unpoisonable
        end

        function drainable(unit)
            return not unit.status.undrainable
        end

        function get_best_defense(unit)
            local terrain_archetypes = { "Wo", "Ww", "Wwr", "Ss", "Gt", "Ds", "Ft", "Hh", "Mm", "Vi", "Ch", "Uu", "At", "Qt", "^Uf", "Xt" }
            local best_defense = 100

            for i, terrain in ipairs(terrain_archetypes) do
                local defense = COMP.unit_defense(unit, terrain)
                if defense < best_defense then
                    best_defense = defense
                end
            end

            return best_defense
        end

        function analyze_enemy_unit(enemy_type, ally_type)
            local function get_best_attack(attacker, defender, defender_defense, attacker_defense, can_poison)
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
                local best_attack
                local best_poison_damage = 0
                -- Steadfast is currently disabled because it biases the AI too much in favour of Guardsmen
                -- Basically it sees the defender stats for damage and wrongfully concludes that the unit is amazing
                -- This may be rectifiable by looking at retaliation damage as well.
                local steadfast = false

                for attack in wml.child_range(wesnoth.unit_types[attacker.type].__cfg, "attack") do
                    local defense = defender_defense
                    local poison = false
                    local damage_multiplier = 1
                    local damage_bonus = 0
                    local weapon_damage = attack.damage

                    for special in wml.child_range(attack, 'specials') do
                        local mod
                        if wml.get_child(special, 'poison') and can_poison then
                            poison = true
                        end

                        -- Handle marksman and magical
                        mod = wml.get_child(special, 'chance_to_hit')
                        if mod then
                            if mod.value then
                                if mod.cumulative then
                                    if mod.value > defense then
                                        defense = mod.value
                                    end
                                else
                                    defense = mod.value
                                end
                            elseif mod.add then
                                defense = defense + mod.add
                            elseif mod.sub then
                                defense = defense - mod.sub
                            elseif mod.multiply then
                                defense = defense * mod.multiply
                            elseif mod.divide then
                                defense = defense / mod.divide
                            end
                        end

                        -- Handle most damage specials (assumes all are cumulative)
                        mod = wml.get_child(special, 'damage')
                        if mod and mod.active_on ~= "defense" then
                            local special_multiplier = 1
                            local special_bonus = 0

                            if mod.multiply then
                                special_multiplier = special_multiplier*mod.multiply
                            end
                            if mod.divide then
                                special_multiplier = special_multiplier/mod.divide
                            end
                            if mod.add then
                                special_bonus = special_bonus+mod.add
                            end
                            if mod.subtract then
                                special_bonus = special_bonus-mod.subtract
                            end

                            if mod.backstab then
                                -- Assume backstab happens on only 1/2 of attacks
                                -- TODO: find out what actual probability of getting to backstab is
                                damage_multiplier = damage_multiplier*(special_multiplier*0.5 + 0.5)
                                damage_bonus = damage_bonus+(special_bonus*0.5)
                                if mod.value then
                                    weapon_damage = (weapon_damage+mod.value)/2
                                end
                            else
                                damage_multiplier = damage_multiplier*special_multiplier
                                damage_bonus = damage_bonus+special_bonus
                                if mod.value then
                                    weapon_damage = mod.value
                                end
                            end
                        end
                    end

                    -- Handle drain for defender
                    local drain_recovery = 0
                    local defender_attacks = defender.attacks
                    for i_d = 1,#defender_attacks do
                        local defender_attack = defender_attacks[i_d]
                        if (defender_attack.range == attack.range) then
                            for _,sp in ipairs(defender_attack.specials) do
                                if (sp[1] == 'drains') and drainable(attacker) then
                                    -- TODO: calculate chance to hit
                                    -- currently assumes 50% chance to hit using supplied constant
                                    local attacker_resistance = COMP.unit_resistance(attacker, defender_attack.type)
                                    drain_recovery = (defender_attack.damage*defender_attack.number*attacker_resistance*attacker_defense/2)/10000
                                end
                            end
                        end
                    end

                    defense = defense/100.0
                    local resistance = COMP.unit_resistance(defender, attack.type)
                    if steadfast and (resistance < 100) then
                        resistance = 100 - ((100 - resistance) * 2)
                        if (resistance < 50) then
                            resistance = 50
                        end
                    end
                    local base_damage = (weapon_damage+damage_bonus)*resistance*damage_multiplier
                    if (resistance > 100) then
                        base_damage = base_damage-1
                    end
                    base_damage = math.floor(base_damage/100 + 0.5)
                    if (base_damage < 1) and (attack.damage > 0) then
                        -- Damage is always at least 1
                        base_damage = 1
                    end
                    local attack_damage = base_damage*attack.number*defense-drain_recovery

                    local poison_damage = 0
                    if poison then
                        -- Add poison damage * probability of poisoning
                        poison_damage = wesnoth.game_config.poison_amount*(1-((1-defense)^attack.number))
                    end

                    if (not best_attack) or (attack_damage+poison_damage > best_damage+best_poison_damage) then
                        best_damage = attack_damage
                        best_poison_damage = poison_damage
                        best_attack = attack
                    end
                end

                return best_attack, best_damage, best_poison_damage
            end

            -- Use cached information when possible: this is expensive
            local analysis = {}
            if not recruit_data.analyses then
                recruit_data.analyses = {}
            else
                if recruit_data.analyses[enemy_type] then
                    analysis = recruit_data.analyses[enemy_type] or {}
                end
            end
            if analysis[ally_type] then
                return analysis[ally_type]
            end

            local unit = COMP.create_unit {
                type = enemy_type,
                random_traits = false,
                name = "X",
                random_gender = false
            }
            local can_poison = poisonable(unit) and (not COMP.unit_ability(unit, 'regenerate'))
            local flat_defense = COMP.unit_defense(unit, "Gt")
            local best_defense = get_best_defense(unit)

            local recruit = COMP.create_unit {
                type = ally_type,
                random_traits = false,
                name = "X",
                random_gender = false
            }
            local recruit_flat_defense = COMP.unit_defense(recruit, "Gt")
            local recruit_best_defense = get_best_defense(recruit)

            local can_poison_retaliation = poisonable(recruit) and (not COMP.unit_ability(recruit, 'regenerate'))
            best_flat_attack, best_flat_damage, flat_poison = get_best_attack(recruit, unit, flat_defense, recruit_best_defense, can_poison)
            best_high_defense_attack, best_high_defense_damage, high_defense_poison = get_best_attack(recruit, unit, best_defense, recruit_flat_defense, can_poison)
            best_retaliation, best_retaliation_damage, retaliation_poison = get_best_attack(unit, recruit, recruit_flat_defense, best_defense, can_poison_retaliation)

            local result = {
                offense = { attack = best_flat_attack, damage = best_flat_damage, poison_damage = flat_poison },
                defense = { attack = best_high_defense_attack, damage = best_high_defense_damage, poison_damage = high_defense_poison },
                retaliation = { attack = best_retaliation, damage = best_retaliation_damage, poison_damage = retaliation_poison }
            }
            analysis[ally_type] = result

            -- Cache result before returning
            recruit_data.analyses[enemy_type] = analysis
            return analysis[ally_type]
        end

        function can_slow(unit)
            local attacks = unit.attacks
            for i_a = 1,#attacks do
                for _,sp in ipairs(attacks[i_a].specials) do
                    if (sp[1] == 'slow') then
                        return true
                    end
                end
            end
            return false
        end

        function get_hp_ratio_with_gold()
            function sum_gold_for_sides(side_filter)
                -- sum positive amounts of gold for a set of sides
                -- positive only because it is used to estimate the number of enemy units that could appear
                -- and negative numbers shouldn't subtract from the number of units on the map
                local gold = 0
                local sides = COMP.get_sides(side_filter)
                for i,s in ipairs(sides) do
                    if s.gold > 0 then
                        gold = gold + s.gold
                    end
                end

                return gold
            end

            -- Hitpoint ratio of own units / enemy units
            -- Also convert available gold to a hp estimate
            my_unit_proxies = AH.get_live_units {
                { "filter_side", {{"allied_with", {side = wesnoth.current.side} }} }
            }
            enemy_proxies = AH.get_live_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }

            local my_hp, enemy_hp = 0, 0
            for i,u in ipairs(my_unit_proxies) do my_hp = my_hp + u.hitpoints end
            for i,u in ipairs(enemy_proxies) do enemy_hp = enemy_hp + u.hitpoints end

            my_hp = my_hp + sum_gold_for_sides({{"allied_with", {side = wesnoth.current.side} }})*2.3
            enemy_hp = enemy_hp+sum_gold_for_sides({{"enemy_of", {side = wesnoth.current.side} }})*2.3
            hp_ratio = my_hp/(enemy_hp + 1e-6)

            return hp_ratio
        end

        function do_recruit_eval(data, outofway_units)
            outofway_units = outofway_units or {}

            -- Check if leader exists
            local leader_proxy = COMP.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]
            if not leader_proxy then
                return 0
            end

            -- Check if there is enough gold to recruit a unit
            local cheapest_unit_cost = AH.get_cheapest_recruit_cost()
            local current_gold = wesnoth.sides[wesnoth.current.side].gold
            if cheapest_unit_cost > current_gold then
                return 0
            end

            -- Minimum requirements satisfied, init recruit data if needed for more complex evaluations
            if data.recruit == nil then
                data.recruit = init_data()
            end
            get_current_castle(leader_proxy, data)

            -- Do not recruit now if we want to recruit elsewhere unless
            -- a) there is a nearby village recruiting would let us capture, or
            -- b) we have enough gold to recruit at both locations
            -- c) we are now at the other location
            local village_target_available = get_village_target(leader_proxy, data)[1]
            if (not village_target_available) and
               (cheapest_unit_cost > current_gold - data.recruit.prerecruit.total_cost) and
               (leader_proxy.x ~= data.recruit.prerecruit.loc[1] or leader_proxy.y ~= data.recruit.prerecruit.loc[2]) then
                return 1
            end

            local cant_recruit_at_location_score = 0
            if data.recruit.prerecruit.total_cost > 0 then
                cant_recruit_at_location_score = 1
            end

            if not wesnoth.get_terrain_info(wesnoth.get_terrain(leader_proxy.x, leader_proxy.y)).keep then
                return cant_recruit_at_location_score
            end

            -- Check for space to recruit a unit
            local no_space = true
            for i,c in ipairs(data.castle.locs) do
                local unit_proxy = COMP.get_unit(c[1], c[2])
                if (not unit_proxy) or (outofway_units[unit_proxy.id] and (not unit_proxy.canrecruit)) then
                    no_space = false
                    break
                end
            end
            if no_space then
                return cant_recruit_at_location_score
            end

            -- Check for minimal recruit option
            if wesnoth.current.turn == 1 and params.min_turn_1_recruit and params.min_turn_1_recruit() then
                if not village_target_available then
                    return cant_recruit_at_location_score
                end
            end

            local score = 180000 -- default score if one not provided. Same as Default AI
            if params.score_function then
                score = params.score_function()
            end
            return score
        end

        function init_data()
            local data = {}

            -- Count enemies of each type
            local enemy_proxies = AH.get_live_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }}}
            }
            local enemy_counts = {}
            local enemy_types = {}
            local possible_enemy_recruit_count = 0

            local function add_unit_type(unit_type)
                if not enemy_counts[unit_type] then
                    table.insert(enemy_types, unit_type)
                    enemy_counts[unit_type] = 1
                else
                    enemy_counts[unit_type] = enemy_counts[unit_type] + 1
                end
            end

            -- Collect all enemies on map
            for i, enemy_proxy in ipairs(enemy_proxies) do
                add_unit_type(enemy_proxy.type)
            end
            -- Collect all possible enemy recruits and count them as virtual enemies
            local enemy_sides = COMP.get_sides({
                { "enemy_of", {side = wesnoth.current.side} },
                { "has_unit", { canrecruit = true }} })
            for i, side in ipairs(enemy_sides) do
                possible_enemy_recruit_count = possible_enemy_recruit_count + #(wesnoth.sides[side.side].recruit)
                for j, unit_type in ipairs(wesnoth.sides[side.side].recruit) do
                    add_unit_type(unit_type)
                end
            end

            -- If no enemies were found, check params.enemy_types,
            -- otherwise add a small number of "representative" unit types
            if #enemy_types == 0 then
                if params.enemy_types then
                    for _,enemy_type in ipairs(params.enemy_types) do
                        add_unit_type(enemy_type)
                    end
                else
                    add_unit_type('Orcish Grunt')
                    add_unit_type('Orcish Archer')
                    add_unit_type('Wolf Rider')
                    add_unit_type('Spearman')
                    add_unit_type('Bowman')
                    add_unit_type('Cavalryman')
                end
            end

            data.enemy_counts = enemy_counts
            data.enemy_types = enemy_types
            data.num_enemies = math.max(#enemy_proxies, 1)
            data.possible_enemy_recruit_count = possible_enemy_recruit_count
            data.cheapest_unit_cost = AH.get_cheapest_recruit_cost()

            data.prerecruit = {
                total_cost = 0,
                units = {}
            }

            return data
        end

        function ai_cas:recruit_rushers_eval(outofway_units)
            local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'recruit_rushers'
            if AH.print_eval() then print_time('     - Evaluating recruit_rushers CA:') end

            local score = do_recruit_eval(recruit_data, outofway_units)
            if score == 0 then
                -- We're done for the turn, discard data
                recruit_data.recruit = nil
            end

            if AH.print_eval() then AH.done_eval_messages(start_time, ca_name) end
            return score
        end

        -- Select a unit and hex to recruit to.
        function select_recruit(leader, avoid_map, outofway_units, cfg)
            local enemy_counts = recruit_data.recruit.enemy_counts
            local enemy_types = recruit_data.recruit.enemy_types
            local num_enemies =  recruit_data.recruit.num_enemies
            local hp_ratio = get_hp_ratio_with_gold()

            -- Determine effectiveness of recruitable units against each enemy unit type
            local recruit_effectiveness = {}
            local recruit_vulnerability = {}
            local attack_type_count = {} -- The number of units who will likely use a given attack type
            local attack_range_count = {} -- The number of units who will likely use a given attack range
            local unit_attack_type_count = {} -- The attack types a unit will use
            local unit_attack_range_count = {} -- The ranges a unit will use
            local enemy_type_count = 0
            local poisoner_count = 0.1 -- Number of units with a poison attack (set to slightly > 0 because we divide by it later)
            local poisonable_count = 0 -- Number of units that the opponents control that are hurt by poison
            local recruit_count = {}
            for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                recruit_count[recruit_id] = #(AH.get_live_units { side = wesnoth.current.side, type = recruit_id, canrecruit = 'no' })
            end
            -- Count prerecruited units as recruited
            for i, prerecruited in ipairs(recruit_data.recruit.prerecruit.units) do
                recruit_count[prerecruited.recruit_type] = recruit_count[prerecruited.recruit_type] + 1
            end

            for i, unit_type in ipairs(enemy_types) do
                enemy_type_count = enemy_type_count + 1
                local poison_vulnerable = false
                for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                    local analysis = analyze_enemy_unit(unit_type, recruit_id)

                    if not recruit_effectiveness[recruit_id] then
                        recruit_effectiveness[recruit_id] = {damage = 0, poison_damage = 0}
                        recruit_vulnerability[recruit_id] = 0
                    end

                    recruit_effectiveness[recruit_id].damage = recruit_effectiveness[recruit_id].damage + analysis.defense.damage * enemy_counts[unit_type]^2
                    if analysis.defense.poison_damage and analysis.defense.poison_damage > 0 then
                        poison_vulnerable = true
                        recruit_effectiveness[recruit_id].poison_damage = recruit_effectiveness[recruit_id].poison_damage +
                            analysis.defense.poison_damage * enemy_counts[unit_type]^2
                    end
                    recruit_vulnerability[recruit_id] = recruit_vulnerability[recruit_id] + (analysis.retaliation.damage * enemy_counts[unit_type])^3

                    local attack_type = analysis.defense.attack.type
                    if not attack_type_count[attack_type] then
                        attack_type_count[attack_type] = 0
                    end
                    attack_type_count[attack_type] = attack_type_count[attack_type] + recruit_count[recruit_id]

                    local attack_range = analysis.defense.attack.range
                    if not attack_range_count[attack_range] then
                        attack_range_count[attack_range] = 0
                    end
                    attack_range_count[attack_range] = attack_range_count[attack_range] + recruit_count[recruit_id]

                    if not unit_attack_type_count[recruit_id] then
                        unit_attack_type_count[recruit_id] = {}
                    end
                    unit_attack_type_count[recruit_id][attack_type] = true

                    if not unit_attack_range_count[recruit_id] then
                        unit_attack_range_count[recruit_id] = {}
                    end
                    unit_attack_range_count[recruit_id][attack_range] = true
                end
                if poison_vulnerable then
                    poisonable_count = poisonable_count + enemy_counts[unit_type]
                end
            end
            for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                -- Count the number of units with the poison ability
                -- This could be wrong if all the units on the enemy side are immune to poison, but since poison has no effect then anyway it doesn't matter
                if recruit_effectiveness[recruit_id].poison_damage > 0 then
                    poisoner_count = poisoner_count + recruit_count[recruit_id]
                end
            end
            -- Subtract the number of possible recruits for the enemy from the list of poisonable units
            -- This works perfectly unless some of the enemy recruits cannot be poisoned.
            -- However, there is no problem with this since poison is generally less useful in such situations and subtracting them too discourages such recruiting
            local poison_modifier = math.max(0, math.min(((poisonable_count-recruit_data.recruit.possible_enemy_recruit_count) / (poisoner_count*5)), 1))^2
            for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                -- Ensure effectiveness and vulnerability are positive.
                -- Negative values imply that drain is involved and the amount drained is very high
                if recruit_effectiveness[recruit_id].damage <= 0 then
                    recruit_effectiveness[recruit_id].damage = 0.01
                else
                    recruit_effectiveness[recruit_id].damage = (recruit_effectiveness[recruit_id].damage / (num_enemies)^2)^0.5
                end
                recruit_effectiveness[recruit_id].poison_damage = (recruit_effectiveness[recruit_id].poison_damage / (num_enemies)^2)^0.5 * poison_modifier
                if recruit_vulnerability[recruit_id] <= 0 then
                    recruit_vulnerability[recruit_id] = 0.01
                else
                    recruit_vulnerability[recruit_id] = (recruit_vulnerability[recruit_id] / ((num_enemies)^2))^0.5
                end
            end
            -- Correct count of units for each range
            local most_common_range
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

            local recruit_type

            repeat
                recruit_data.recruit.best_hex, recruit_data.recruit.target_hex = ai_cas:find_best_recruit_hex(leader, recruit_data, avoid_map, outofway_units, cfg)
                if recruit_data.recruit.best_hex == nil or recruit_data.recruit.best_hex[1] == nil then
                    return nil
                end
                recruit_type = ai_cas:find_best_recruit(attack_type_count, unit_attack_type_count, recruit_effectiveness, recruit_vulnerability, attack_range_count, unit_attack_range_count, most_common_range_count)
            until recruit_type ~= nil

            return recruit_type
        end

        -- Consider recruiting as many units as possible at a location where the leader currently isn't
        -- These units will eventually be considered already recruited when trying to recruit at the current location
        -- Recruit will also recruit these units first once the leader moves to that location
        function ai_cas:prerecruit_units(from_loc, avoid_map, outofway_units, cfg)
            if recruit_data.recruit == nil then
                recruit_data.recruit = init_data()
            end

            local leader_proxy = COMP.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]
            if leader_proxy == nil then
                return nil
            end
            leader_copy = COMP.copy_unit(leader_proxy)
            leader_copy.x, leader_copy.y = from_loc[1], from_loc[2]

            -- only track one prerecruit location at a time
            if recruit_data.recruit.prerecruit.loc == nil
            or from_loc[1] ~= recruit_data.recruit.prerecruit.loc[1]
            or from_loc[2] ~= recruit_data.recruit.prerecruit.loc[2] then
                recruit_data.recruit.prerecruit = {
                    loc = from_loc,
                    total_cost = 0,
                    units = {}
                }
            end

            get_current_castle(leader_copy, recruit_data)

            -- recruit as many units as possible at that location
            while #recruit_data.castle.locs > 0 do
                local recruit_type = select_recruit(leader_copy, avoid_map, outofway_units, cfg)
                if recruit_type == nil then
                    break
                end
                local unit_cost = wesnoth.unit_types[recruit_type].cost
                if unit_cost > wesnoth.sides[wesnoth.current.side].gold - recruit_data.recruit.prerecruit.total_cost then
                    break
                end
                local queued_recruit = {
                    recruit_type = recruit_type,
                    recruit_hex = recruit_data.recruit.best_hex,
                    target_hex = recruit_data.recruit.target_hex
                }
                table.insert(recruit_data.recruit.prerecruit.units, queued_recruit)
                remove_hex_from_castle(recruit_data.castle, queued_recruit.recruit_hex)
                recruit_data.recruit.prerecruit.total_cost = recruit_data.recruit.prerecruit.total_cost + unit_cost
            end

            -- Provide the prerecruit data to the caller
            return recruit_data.recruit.prerecruit
        end

        function ai_cas:clear_prerecruit()
                recruit_data = {}
                recruit_data.recruit = init_data()
        end

        -- recruit a unit
        function ai_cas:recruit_rushers_exec(ai_local, avoid_map, outofway_units, no_exec, cfg)
            -- Optional input:
            --  @no_exec: if set, only go through the calculation and return true,
            --    but don't actually do anything. This is just a hack for now until
            --    we know if this works as desired.
            --    TODO: implement in a less awkward way later

            if ai_local then ai = ai_local end

            if AH.show_messages() then wesnoth.wml_actions.message { speaker = 'narrator', message = 'Recruiting' } end

            local leader_proxy = COMP.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]
            -- If leader location == prerecruit location, recruit units from prerecruit list instead of trying locally
            local recruit_type
            local max_cost = wesnoth.sides[wesnoth.current.side].gold
            if recruit_data.recruit.prerecruit.loc ~= nil
            and leader_proxy.x == recruit_data.recruit.prerecruit.loc[1] and leader_proxy.y == recruit_data.recruit.prerecruit.loc[2]
            and #recruit_data.recruit.prerecruit.units > 0 then
                local recruit_unit_data = table.remove(recruit_data.recruit.prerecruit.units, 1)
                recruit_hex = recruit_unit_data.recruit_hex
                target_hex = recruit_unit_data.target_hex
                recruit_type = recruit_unit_data.recruit_type
                if target_hex ~= nil and target_hex[1] ~= nil then
                    table.insert(recruit_data.castle.assigned_villages_x, target_hex[1])
                    table.insert(recruit_data.castle.assigned_villages_y, target_hex[2])
                end
                recruit_data.recruit.prerecruit.total_cost = recruit_data.recruit.prerecruit.total_cost - wesnoth.unit_types[recruit_type].cost
            else
                recruit_type = select_recruit(leader_proxy, avoid_map, outofway_units, cfg)
                if recruit_type == nil then
                    return false
                end
                recruit_hex = recruit_data.recruit.best_hex
                target_hex = recruit_data.recruit.target_hex

                -- Consider prerecruited units to already be recruited if there is no target hex
                -- Targeted hexes won't be available at the prerecruit location and we don't want to miss getting the associated villages
                if recruit_data.recruit.target_hex == nil or recruit_data.recruit.target_hex[1] == nil then
                    max_cost = max_cost - recruit_data.recruit.prerecruit.total_cost
                end
            end

            if wesnoth.unit_types[recruit_type].cost <= max_cost then
                -- It is possible that there's a unit on the recruit hex if a
                -- outofway_units table is passed.

                -- Placeholder: TODO: implement better way of doing this
                if no_exec then return true end

                local unit_in_way_proxy = COMP.get_unit(recruit_hex[1], recruit_hex[2])
                if unit_in_way_proxy then
                    AH.move_unit_out_of_way(ai, unit_in_way_proxy)
                end


                AH.checked_recruit(ai, recruit_type, recruit_hex[1], recruit_hex[2])

                local unit_proxy = COMP.get_unit(recruit_hex[1], recruit_hex[2])

                -- If the recruited unit cannot reach the target hex, return it to the pool of targets
                if target_hex and target_hex[1] then
                    local path, cost = wesnoth.find_path(unit_proxy, target_hex[1], target_hex[2], {viewing_side=0, max_cost=unit_proxy.max_moves+1})
                    if cost > unit_proxy.max_moves then
                        -- The last village added to the list should be the one we tried to aim for, check anyway
                        local last = #recruit_data.castle.assigned_villages_x
                        if (recruit_data.castle.assigned_villages_x[last] == target_hex[1]) and (recruit_data.castle.assigned_villages_y[last] == target_hex[2]) then
                            table.remove(recruit_data.castle.assigned_villages_x)
                            table.remove(recruit_data.castle.assigned_villages_y)
                        end
                    end
                end

                return true, unit_proxy
            else
                -- This results in the CA being blacklisted -> clear cache
                recruit_data.recruit = nil

                return false
            end
        end

        function get_current_castle(leader, data)
            if (not data.castle) or (data.castle.x ~= leader.x) or (data.castle.y ~= leader.y) then
                data.castle = {}
                local width,height,border = wesnoth.get_map_size()

                data.castle = {
                    locs = wesnoth.get_locations {
                        x = "1-"..width, y = "1-"..height,
                        { "and", {
                            x = leader.x, y = leader.y, radius = 200,
                            { "filter_radius", { terrain = 'C*,K*,C*^*,K*^*,*^K*,*^C*' } }
                        } },
                        { "not", { -- exclude hex leader is on
                            x = leader.x, y = leader.y
                        } }
                    },
                    x = leader.x,
                    y = leader.y
                }
            end
        end

        function remove_hex_from_castle(castle, hex)
            for i,c in ipairs(castle.locs) do
                if c[1] == hex[1] and c[2] == hex[2] then
                    table.remove(castle.locs, i)
                    break
                end
            end
        end

        function ai_cas:find_best_recruit_hex(leader, data, avoid_map, outofway_units, cfg)
            -- Find the best recruit hex
            -- First choice: a hex that can reach an unowned village
            -- Second choice: a hex close to the enemy
            --
            -- Optional inputs:
            --  @avoid_map: location set listing hexes on which we should
            --    not recruit, unless no other hexes are available
            --  @outofway_units: a table of type { id = true } listing units that
            --    can move out of the way to make place for recruiting
            --  @cfg: table containing parameters to configure the hex rating
            --    castle_rating_map: an FGmap containing an additive rating contribution
            --       Note: we do not include the FGmap functions here, but can access it manually
            --    outofway_penalty: penalty to be used for hexes with units that can
            --      move out of the way (default: -100)

            outofway_units = outofway_units or {}
            local outofway_penalty = cfg and cfg.outofway_penalty or -100

            get_current_castle(leader, data)

            local best_hex, village = get_village_target(leader, data)
            if village[1] then
                table.insert(data.castle.assigned_villages_x, village[1])
                table.insert(data.castle.assigned_villages_y, village[2])
            else
                -- no available village, look for hex closest to enemy leader
                -- and also the closest enemy
                local max_rating = - math.huge

                local enemy_leader_proxies = AH.get_live_units { canrecruit = 'yes',
                    { "filter_side", { { "enemy_of", {side = wesnoth.current.side} } } }
                }
                local _, closest_enemy_location = COMP.get_closest_enemy()

                for i,c in ipairs(data.castle.locs) do
                    local rating = 0
                    local unit_proxy = COMP.get_unit(c[1], c[2])
                    if (not unit_proxy) or outofway_units[unit_proxy.id] then
                        for j,e in ipairs(enemy_leader_proxies) do
                            rating = rating + 1 / wesnoth.map.distance_between(c[1], c[2], e.x, e.y) ^ 2.
                        end
                        rating = rating + 1 / wesnoth.map.distance_between(c[1], c[2], closest_enemy_location.x, closest_enemy_location.y) ^ 2.

                        -- If there's a unit on the hex (that is marked as being able
                        -- to move out of the way, otherwise we don't get here), give
                        -- a pretty stiff penalty, but make it possible to recruit here
                        if unit_proxy then
                            --std_print('  Out of way penalty', c[1], c[2], unit_proxy.id)
                            rating = rating + outofway_penalty
                        end

                        if avoid_map and avoid_map:get(c[1], c[2]) then
                            --std_print('Avoid hex for recruiting:', c[1], c[2])
                            rating = rating - 1000.
                        end

                        if cfg and cfg.castle_rating_map
                            and cfg.castle_rating_map[c[1]] and cfg.castle_rating_map[c[1]][c[2]]
                        then
                            local custom_rating = cfg.castle_rating_map[c[1]][c[2]].rating or 0
                            --std_print('custom_rating:', c[1] .. ',' .. c[2], custom_rating)
                            rating = rating + custom_rating
                        end

                        --std_print(c[1], c[2], rating)
                        if (rating > max_rating) then
                            max_rating, best_hex = rating, { c[1], c[2] }
                        end
                    end
                end
            end

            if AH.print_eval() then
                if village[1] then
                    std_print("Recruit at: " .. best_hex[1] .. "," .. best_hex[2] .. " -> " .. village[1] .. "," .. village[2])
                else
                    std_print("Recruit at: " .. best_hex[1] .. "," .. best_hex[2])
                end
            end
            return best_hex, village
        end

        function ai_cas:find_best_recruit(attack_type_count, unit_attack_type_count, recruit_effectiveness, recruit_vulnerability, attack_range_count, unit_attack_range_count, most_common_range_count)
            -- Find best recruit based on damage done to enemies present, speed, and hp/gold ratio
            local recruit_scores = {}
            local best_scores = {offense = 0, defense = 0, move = 0}
            local best_hex = recruit_data.recruit.best_hex
            local target_hex = recruit_data.recruit.target_hex

            local reference_hex = target_hex[1] and target_hex or best_hex
            local distance_to_enemy, enemy_location = COMP.get_closest_enemy(reference_hex, wesnoth.current.side, { viewing_side = 0 })

            -- If no enemy is on the map, then we first use closest enemy start hex,
            -- and if that does not exist either, a location mirrored w.r.t the center of the map
            if not enemy_location then
                local enemy_sides = wesnoth.sides.find({ { "enemy_of", {side = wesnoth.current.side} } })
                local min_dist = math.huge
                for _, side in ipairs(enemy_sides) do
                    local enemy_start_hex = wesnoth.special_locations[side.side]
                    if enemy_start_hex then
                        local dist = wesnoth.map.distance_between(reference_hex[1], reference_hex[2], enemy_start_hex[1], enemy_start_hex[2])
                        if dist < min_dist then
                            min_dist = dist
                            enemy_location = { x = enemy_start_hex[1], y = enemy_start_hex[2] }
                        end
                    end
                end
                if not enemy_location then
                    local width, height = wesnoth.get_map_size()
                    enemy_location = { x = width + 1 - reference_hex[1], y = height + 1 - reference_hex[2] }
                end
                distance_to_enemy = wesnoth.map.distance_between(reference_hex[1], reference_hex[2], enemy_location.x, enemy_location.y)
            end

            local gold_limit = math.huge
            if recruit_data.castle.loose_gold_limit >= recruit_data.recruit.cheapest_unit_cost then
                gold_limit = recruit_data.castle.loose_gold_limit
            end

            local recruitable_units = {}

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
                local efficiency_index = 1
                local unit_cost = wesnoth.unit_types[recruit_id].cost

                -- Use time to enemy to encourage recruiting fast units when the opponent is far away (game is beginning or we're winning)
                -- Base distance on
                local recruit_unit = COMP.create_unit {
                    type = recruit_id,
                    x = best_hex[1],
                    y = best_hex[2],
                    random_traits = false,
                    name = "X",
                    random_gender = false
                }
                if target_hex[1] then
                    local path, cost = wesnoth.find_path(recruit_unit, target_hex[1], target_hex[2], {viewing_side=0, max_cost=wesnoth.unit_types[recruit_id].max_moves+1})
                    if cost > wesnoth.unit_types[recruit_id].max_moves then
                        -- Unit cost is effectively higher if cannot reach the village
                        efficiency_index = 2
                        unit_cost = no_village_cost(recruit_id)
                    end

                    -- Later calculations are based on where the unit will be after initial move
                    recruit_unit.x = target_hex[1]
                    recruit_unit.y = target_hex[2]
                end

                local path, cost = wesnoth.find_path(recruit_unit, enemy_location.x, enemy_location.y, {ignore_units = true})
                local time_to_enemy = cost / wesnoth.unit_types[recruit_id].max_moves
                local move_score = 1 / (time_to_enemy * unit_cost^0.5)

                local eta = math.ceil(time_to_enemy)
                if target_hex[1] then
                    -- expect a 1 turn delay to reach village
                    eta = eta + 1
                end
                -- divide the lawful bonus by eta before running it through the function because the function converts from 0 centered to 1 centered

                local lawful_bonus = 0
                local eta_turn = wesnoth.current.turn + eta
                if eta_turn <= wesnoth.game_config.last_turn then
                    lawful_bonus = wesnoth.get_time_of_day(wesnoth.current.turn + eta).lawful_bonus / eta^2
                end
                local damage_bonus = AH.get_unit_time_of_day_bonus(recruit_unit.alignment, lawful_bonus)
                -- Estimate effectiveness on offense and defense
                local offense_score =
                    (recruit_effectiveness[recruit_id].damage*damage_bonus+recruit_effectiveness[recruit_id].poison_damage)
                    /(wesnoth.unit_types[recruit_id].cost^0.3*recruit_modifier^4)
                local defense_score = efficiency[recruit_id][efficiency_index]/recruit_vulnerability[recruit_id]

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
                if COMP.match_unit(recruit_unit, { ability = "healing" }) then
                    unit_score["heals"] = true
                end
                if COMP.match_unit(recruit_unit, { ability = "skirmisher" }) then
                    unit_score["skirmisher"] = true
                end
                recruitable_units[recruit_id] = recruit_unit
            end
            local healer_count, healable_count = get_unit_counts_for_healing()
            local best_score = 0
            local recruit_type
            local offense_weight = 2.5
            local defense_weight = 1/hp_ratio^0.5
            local move_weight = math.max((distance_to_enemy/20)^2, 0.25)
            local randomness = params.randomness or 0.1

            -- Bonus for higher-level units, as unit cost is penalized otherwise
            local high_level_fraction = params.high_level_fraction or 0
            local all_unit_proxies = AH.get_live_units {
                side = wesnoth.current.side,
                { "not", { canrecruit = "yes" }}
            }
            local level_count = {}
            for _,unit_proxy in ipairs(all_unit_proxies) do
                local level = unit_proxy.level
                level_count[level] = (level_count[level] or 0) + 1
            end
            local min_recruit_level, max_recruit_level = math.huge, -math.huge
            for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                local level = wesnoth.unit_types[recruit_id].level
                if (level < min_recruit_level) then min_recruit_level = level end
                if (level > max_recruit_level) then max_recruit_level = level end
            end
            if (min_recruit_level < 1) then min_recruit_level = 1 end
            local unit_deficit = {}
            for i=min_recruit_level+1,max_recruit_level do
                -- If no non-leader units are on the map yet, we set up the situation as if there were
                -- one of each level. This is in order to get the situation for the first recruit right.
                local n_units = #all_unit_proxies
                local n_units_this_level = level_count[i] or 0
                if (n_units == 0) then
                    n_units = max_recruit_level - min_recruit_level
                    n_units_this_level = 1
                end
                unit_deficit[i] = high_level_fraction ^ (i - min_recruit_level) * n_units - n_units_this_level
            end

            for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                local level_bonus = 0
                local level = wesnoth.unit_types[recruit_id].level
                if (level > min_recruit_level) and (unit_deficit[level] > 0) then
                    level_bonus = 0.25 * unit_deficit[level]^2
                end
                local scores = recruit_scores[recruit_id]
                local offense_score = (scores["offense"]/best_scores["offense"])^0.5
                local defense_score = (scores["defense"]/best_scores["defense"])^0.5
                local move_score = (scores["move"]/best_scores["move"])--^0.5

                local bonus = math.random()*randomness
                if scores["slows"] then
                    bonus = bonus + 0.4
                end
                if scores["heals"] then
                    bonus = bonus + (healable_count/(healer_count+1))/20
                end
                if scores["skirmisher"] then
                    bonus = bonus + 0.1
                end
                for attack_range, count in pairs(unit_attack_range_count[recruit_id]) do
                    bonus = bonus + 0.02 * most_common_range_count / (attack_range_count[attack_range]+1)
                end
                local race = wesnoth.races[wesnoth.unit_types[recruit_id].race]
                local num_traits = race and race.num_traits or 0
                bonus = bonus + 0.03 * num_traits^2
                if target_hex[1] then
                    recruitable_units[recruit_id].x = best_hex[1]
                    recruitable_units[recruit_id].y = best_hex[2]
                    local path, cost = wesnoth.find_path(recruitable_units[recruit_id], target_hex[1], target_hex[2], {viewing_side=0, max_cost=wesnoth.unit_types[recruit_id].max_moves+1})
                    if cost > wesnoth.unit_types[recruit_id].max_moves then
                        -- penalty if the unit can't reach the target village
                        bonus = bonus - 0.2
                    end
                end

                local score = offense_score*offense_weight + defense_score*defense_weight + move_score*move_weight + bonus + level_bonus

                if AH.print_eval() then
                    std_print(recruit_id .. " score: " .. offense_score*offense_weight .. " + " .. defense_score*defense_weight .. " + " .. move_score*move_weight  .. " + " .. bonus  .. " + " .. level_bonus  .. " = " .. score)
                end
                if score > best_score and wesnoth.unit_types[recruit_id].cost <= gold_limit then
                    best_score = score
                    recruit_type = recruit_id
                end
            end

            return recruit_type
        end

        function get_unit_counts_for_healing()
            local num_healers = #AH.get_live_units {
                side = wesnoth.current.side,
                ability = "healing",
                { "not", { canrecruit = "yes" }}
            }
            local num_healable = #AH.get_live_units {
                side = wesnoth.current.side,
                { "not", { ability = "regenerates" }}
            }
            return num_healers, num_healable
        end

        function get_village_target(leader, data)
            -- Only consider villages reachable by our fastest unit
            local fastest_unit_speed = 0
            for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                if wesnoth.unit_types[recruit_id].max_moves > fastest_unit_speed then
                    fastest_unit_speed = wesnoth.unit_types[recruit_id].max_moves
                end
            end

            -- get a list of all unowned and enemy-owned villages within fastest_unit_speed
            -- this may have false positives (villages that can't be reached due to difficult/impassible terrain)
            local exclude_map = LS.create()
            if data.castle.assigned_villages_x and data.castle.assigned_villages_x[1] then
                for i,x in ipairs(data.castle.assigned_villages_x) do
                    exclude_map:insert(x, data.castle.assigned_villages_y[i])
                end
            end

            local all_villages = wesnoth.get_villages()
            local villages = {}
            for _,v in ipairs(all_villages) do
                local owner = wesnoth.get_village_owner(v[1], v[2])
                if ((not owner) or COMP.is_enemy(owner, wesnoth.current.side))
                    and (not exclude_map:get(v[1], v[2]))
                then
                    for _,loc in ipairs(data.castle.locs) do
                        local dist = wesnoth.map.distance_between(v[1], v[2], loc[1], loc[2])
                        if (dist <= fastest_unit_speed) then
                           table.insert(villages, v)
                           break
                        end
                    end
                end
            end

            local hex, target, shortest_distance = {}, {}, AH.no_path

            if not data.castle.assigned_villages_x then
                data.castle.assigned_villages_x = {}
                data.castle.assigned_villages_y = {}

                if not params.leader_takes_village or params.leader_takes_village() then
                    -- skip one village for the leader
                    for i,v in ipairs(villages) do
                        local path, cost = wesnoth.find_path(leader, v[1], v[2], {max_cost = leader.max_moves+1})
                        if cost <= leader.max_moves then
                            table.insert(data.castle.assigned_villages_x, v[1])
                            table.insert(data.castle.assigned_villages_y, v[2])
                            table.remove(villages, i)
                            break
                        end
                    end
                end
            end

            local village_count = #villages
            local test_units = get_test_units()
            local num_recruits = #test_units
            local total_village_distance = {}
            for j,c in ipairs(data.castle.locs) do
                c_index = c[1] + c[2]*1000
                total_village_distance[c_index] = 0
                for i,v in ipairs(villages) do
                    total_village_distance[c_index] = total_village_distance[c_index] + wesnoth.map.distance_between(c[1], c[2], v[1], v[2])
                end
            end

            local width,height,border = wesnoth.get_map_size()
            if (not recruit_data.unit_distances) then recruit_data.unit_distances = {} end
            for i,v in ipairs(villages) do
                local close_castle_hexes = {}
                for _,loc in ipairs(data.castle.locs) do
                    local dist = wesnoth.map.distance_between(v[1], v[2], loc[1], loc[2])
                    if (dist <= fastest_unit_speed) then
                        if (not COMP.get_unit(loc[1], loc[2])) then
                           table.insert(close_castle_hexes, loc)
                        end
                    end
                end

                for u,unit in ipairs(test_units) do
                    test_units[u].x = v[1]
                    test_units[u].y = v[2]
                end

                local viable_village = false
                local village_best_hex, village_shortest_distance = {}, AH.no_path
                for j,c in ipairs(close_castle_hexes) do
                    if c[1] > 0 and c[2] > 0 and c[1] <= width and c[2] <= height then
                        local distance = 0
                        for x,unit in ipairs(test_units) do
                            local key = unit.type .. '_' .. v[1] .. '-' .. v[2] .. '_' .. c[1]  .. '-' .. c[2]
                            local path, unit_distance
                            if (not recruit_data.unit_distances[key]) then
                                path, unit_distance = wesnoth.find_path(unit, c[1], c[2], {viewing_side=0, max_cost=fastest_unit_speed+1})
                                recruit_data.unit_distances[key] = unit_distance
                            else
                                unit_distance = recruit_data.unit_distances[key]
                            end

                            distance = distance + unit_distance

                            -- Village is only viable if at least one unit can reach it
                            if unit_distance <= unit.max_moves then
                                viable_village = true
                            end
                        end
                        distance = distance / num_recruits

                        if distance < village_shortest_distance
                        or (distance == village_shortest_distance and distance < AH.no_path
                            and total_village_distance[c[1] + c[2]*1000] > total_village_distance[village_best_hex[1]+village_best_hex[2]*1000])
                        then
                            village_best_hex = c
                            village_shortest_distance = distance
                        end
                    end
                end
                if village_shortest_distance < shortest_distance then
                    hex = village_best_hex
                    target = v
                    shortest_distance = village_shortest_distance
                end

                if not viable_village then
                    -- this village could not be reached by any unit
                    -- eliminate it from consideration
                    table.insert(data.castle.assigned_villages_x, v[1])
                    table.insert(data.castle.assigned_villages_y, v[2])
                    village_count = village_count - 1
                end
            end

            data.castle.loose_gold_limit = math.floor(wesnoth.sides[wesnoth.current.side].gold/village_count + 0.5)

            return hex, target
        end

        function get_test_units()
            local test_units, num_recruits = {}, 0
            local movetypes = {}
            for x,id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                local custom_movement = wml.get_child(wesnoth.unit_types[id].__cfg, "movement_costs")
                local movetype = wesnoth.unit_types[id].__cfg.movement_type
                if custom_movement
                or (not movetypes[movetype])
                or (movetypes[movetype] < wesnoth.unit_types[id].max_moves)
                then
                    if not custom_movement then
                        movetypes[movetype] = wesnoth.unit_types[id].max_moves
                    end
                    num_recruits = num_recruits + 1
                    test_units[num_recruits] = COMP.create_unit({
                        type = id,
                        side = wesnoth.current.side,
                        random_traits = false,
                        name = "X",
                        random_gender = false
                    })
                end
            end

            return test_units
        end
    end -- init()
}
