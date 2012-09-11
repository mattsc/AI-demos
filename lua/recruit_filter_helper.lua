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

function analyze_enemy_unit(unit_type_id)
    local analysis = {}

    local unit = wesnoth.create_unit { type = unit_type_id }
    local can_poison = not (helper.get_child(unit.__cfg, "status").not_living or wesnoth.unit_ability(unit, 'regenerate'))
    local flat_defense = wesnoth.unit_defense(unit, "Gt")
    print(unit_type_id)

    for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
        local best_damage = 0
        local best_attack = nil

        for attack in helper.child_range(wesnoth.unit_types[recruit_id].__cfg, "attack") do
            local defense = flat_defense
            local poison = false
            -- TODO: handle more abilities (charge, steadfast, drain)
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

            defense = defense/100.0
            local attack_damage = attack.damage*attack.number*wesnoth.unit_resistance(unit, attack.type)*defense

            if poison then
                -- Add poison damage * probability of poisoning
                attack_damage = attack_damage + 800*(1-((1-defense)^attack.number))
            end

            if attack_damage > best_damage then
                best_damage = attack_damage
                best_attack = attack
            end
        end
        print(recruit_id, best_attack.name, best_damage)
    end
end
