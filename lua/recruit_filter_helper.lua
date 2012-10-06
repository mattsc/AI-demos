helper = wesnoth.require "lua/helper.lua"
local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

function archer_target(unit)
    local fire_resist = wesnoth.unit_resistance(unit, "fire")
    local pierce_resist = wesnoth.unit_resistance(unit, "pierce")
    local blade_resist = wesnoth.unit_resistance(unit, "blade")
    if fire_resist <= blade_resist and pierce_resist <= blade_resist then
        return false
    end
    for att in helper.child_range(unit.__cfg, "attack") do
        if att.range == 'ranged' then
            return false
        end
    end
    return true
end

function troll_target(unit)
    -- trolls are good counters for units that do poison damage
    for att in helper.child_range(unit.__cfg, 'attack') do
        for sp in helper.child_range(att, 'specials') do
            if helper.get_child(sp, 'poison') then
                return true
            end
        end
    end
    if wesnoth.unit_resistance(unit, "impact") <= 100 then
        return false
    end
    return true
end

function not_living(unit)
    return not (not helper.get_child(unit.__cfg, "status").not_living)
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
    local function get_best_attack(attacker_id, defender, unit_defense, can_poison)
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
        local steadfast = wesnoth.unit_ability(defender, "resistance")

        for attack in helper.child_range(wesnoth.unit_types[attacker_id].__cfg, "attack") do
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
                        if helper.get_child(special, 'drains') then
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

            if poison then
                -- Add 3/4 poison damage * probability of poisoning
                attack_damage = attack_damage + 600*(1-((1-defense)^attack.number))
            end

            if (not best_attack) or (attack_damage > best_damage) then
                best_damage = attack_damage
                best_attack = attack
            end
        end

        return best_attack, best_damage
    end

    local analysis = {}

    local unit = wesnoth.create_unit { type = unit_type_id }
    local can_poison = not (helper.get_child(unit.__cfg, "status").not_living or wesnoth.unit_ability(unit, 'regenerate'))
    local flat_defense = wesnoth.unit_defense(unit, "Gt")
    local best_defense = get_best_defense(unit)

    for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
        local recruit = wesnoth.create_unit { type = recruit_id }
        local can_poison_retaliation = not (helper.get_child(recruit.__cfg, "status").not_living or wesnoth.unit_ability(recruit, 'regenerate'))
        best_flat_attack, best_flat_damage = get_best_attack(recruit_id, unit, flat_defense, can_poison)
        best_high_defense_attack, best_high_defense_damage = get_best_attack(recruit_id, unit, best_defense, can_poison)
        best_retaliation, best_retaliation_damage = get_best_attack(unit_type_id, recruit, wesnoth.unit_defense(recruit, "Gt"), can_poison_retaliation)

        local result = {
            offense = { attack = best_flat_attack, damage = best_flat_damage },
            defense = { attack = best_high_defense_attack, damage = best_high_defense_damage },
            retaliation = { attack = best_retaliation, damage = best_retaliation_damage }
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
        efficiency[recruit_id] = flat_defense*(wesnoth.unit_types[recruit_id].max_hitpoints^1.3)/(wesnoth.unit_types[recruit_id].cost^2)
    end
    return efficiency
end
