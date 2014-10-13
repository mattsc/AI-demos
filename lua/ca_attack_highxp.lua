local AH = wesnoth.require "ai/lua/ai_helper.lua"
local BC = wesnoth.require "ai/lua/battle_calcs.lua"
local LS = wesnoth.require "lua/location_set.lua"

local min_units = 4
local min_attackers = 2

local ca_attack_highxp = {}

function ca_attack_highxp:evaluation(ai, cfg, self)
    -- Units with attacks left
    local attackers = AH.get_units_with_attacks { side = wesnoth.current.side }
    if (not attackers[1]) then return 0 end

    -- AI needs at least @min_units units total
    local units = wesnoth.get_units { side = wesnoth.current.side }
    if (#units < min_units) then return 0 end

    -- Is there an enemy within 3 XP of leveling up?
    local target
    local enemies = wesnoth.get_units {
        { "filter_side", { { "enemy_of", { side = wesnoth.current.side } } } }
    }

    for _,enemy in ipairs(enemies) do
        if ((enemy.experience + 3) >= enemy.max_experience) then
            target = enemy
            break
        end
    end

    if (not target) then return 0 end

    -- All possible attacks
    local attacks = AH.get_attacks(attackers, { include_occupied = true })

    -- Only attack the target if at least two AI units can attack it
    local src_map, dst_map = LS.create(), LS.create()
    for i=#attacks,1,-1 do
        if (attacks[i].target.x == target.x) and (attacks[i].target.y == target.y) then
            -- If there is an attack that would NOT result in leveling up,
            -- do not execute any attack, as the default AI will take care of this
            local attacker = wesnoth.get_unit(attacks[i].src.x, attacks[i].src.y)
            if (attacker.__cfg.level < target.max_experience - target.experience) then
                return 0
            end

            src_map:insert(attacks[i].src.x, attacks[i].src.y)
            dst_map:insert(attacks[i].dst.x, attacks[i].dst.y)
        else
            table.remove(attacks, i)
        end
    end
    if (src_map:size() < min_attackers) or (dst_map:size() < min_attackers) then
        return 0
    end

    -- Rate all the attacks
    local max_rating, best_attack = -9e99
    for _,att in ipairs(attacks) do
        local rating
        local attacker = wesnoth.get_unit(att.src.x, att.src.y)

        local attacker_copy = wesnoth.copy_unit(attacker)
        attacker_copy.x, attacker_copy.y = att.dst.x, att.dst.y

        local att_stats, def_stats, att_weapon, def_weapon = wesnoth.simulate_combat(attacker_copy, target)

        if (def_stats.hp_chance[0] > 0) then
            -- If a kill is possible, strongly prefer that attack
            rating = 1000 + def_stats.hp_chance[0]
        else
            -- Otherwise choose the attacker that would do the *least*
            -- damage if the target were not to level up
            local old_experience = target.experience
            target.experience = 0
            local att_stats, def_stats, att_weapon, def_weapon = wesnoth.simulate_combat(attacker_copy, target)
            target.experience = old_experience

            rating = def_stats.average_hp

            -- Damage taken by the AI unit is a lesser rating contribution
            local own_damage = attacker.hitpoints - att_stats.average_hp
            rating = rating - own_damage / 100.

            -- Strongly discourage poison or slow attacks
            if att_weapon.poisons or att_weapon.slows then
                rating = rating - 100
            end

            -- Minor penalty if the attack hex is occupied
            if att.attack_hex_occupied then
                rating = rating - 0.001
            end
        end

        if (rating > max_rating) then
            max_rating, best_attack = rating, att
        end
    end

    if best_attack then
        self.data.XP_attack = best_attack
        return 100010
    end

    return 0
end

function ca_attack_highxp:execution(ai, cfg, self)
    local attacker = wesnoth.get_unit(self.data.XP_attack.src.x, self.data.XP_attack.src.y)
    local defender = wesnoth.get_unit(self.data.XP_attack.target.x, self.data.XP_attack.target.y)

    AH.movefull_outofway_stopunit(ai, attacker, self.data.XP_attack.dst.x, self.data.XP_attack.dst.y)
    if (not attacker) or (not attacker.valid) then return end
    if (not defender) or (not defender.valid) then return end

    AH.checked_attack(ai, attacker, defender)
    self.data.XP_attack = nil
end

return ca_attack_highxp
