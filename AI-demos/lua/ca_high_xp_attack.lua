local H = wesnoth.require "lua/helper.lua"
local AH = wesnoth.require "ai/lua/ai_helper.lua"
local LS = wesnoth.require "lua/location_set.lua"

local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

-- Evaluation process:
--
-- Find all enemy units that could be caused to level up by an attack
--  - If only units that would cause them to level up can attack, CA score = 100,010.
--    This means the attack will be done before the default AI attacks, so that AI
--    units do not get used otherwise by the default AI
--  - If units that would not cause a leveling can also attack, CA score = 99,990,
--    meaning we see whether the default AI attacks that unit with one of those first
-- We also check whether it is possible to move an own unit out of the way
--
-- Attack rating:
-- 0. If the CTD (chance to die) of the AI unit is larger than the value of
--    aggression for the side, do not do the attack
-- 1. Otherwise, if the attack might result in a kill, do that preferentially:
--     rating = CTD of defender - CTD of attacker
-- 2. Otherwise, if the enemy is poisoned, do not attack (wait for it
--    weaken and attack on a later turn)
-- 3. Otherwise, calculate damage done to enemy (as if it were not leveling) and
--    own unit, expressed in partial loss of unit value (gold) and minimize both.
--    Damage to enemy is minimized because we want to level it with the weakest AI unit,
--    so that we can follow up with stronger units. In addition, use of poison or
--    slow attacks is strongly discouraged. See code for exact equations.

local ca_attack_highxp = {}

function ca_attack_highxp:evaluation(cfg, data)
    -- Note: (most of) the code below is set up to maximize speed. Do not
    -- "simplify" this unless you understand exactly what that means

    local units = AH.get_units_with_attacks { side = wesnoth.current.side }
    if (not units[1]) then return 0 end

    local max_unit_level = 0
    for _,unit in ipairs(units) do
        local level = wesnoth.unit_types[unit.type].level
        if (level > max_unit_level) then
            max_unit_level = level
        end
    end
    --print('max_unit_level:', max_unit_level)

    -- Are there enemy units within max_unit_level of leveling up
    -- and within potential reach of units that could level them
    local enemies = wesnoth.get_units {
        { "filter_side", { { "enemy_of", { side = wesnoth.current.side } } } }
    }

    -- Only mark them as potential targets if they close enough to an AI unit
    -- that could trigger them leveling up; this is not a sufficient criterion,
    -- but it is much faster than path finding, so it is done for preselection
    -- Caveat: this will not work with tunnels and teleports
    local target_infos = {}
    for i_e,enemy in ipairs(enemies) do
        local XP_to_levelup = enemy.max_experience - enemy.experience
        if (max_unit_level >= XP_to_levelup) then
            local potential_target = false
            local ind_attackers, ind_other_units = {}, {}
            for i_u,unit in ipairs(units) do
                if (H.distance_between(enemy.x, enemy.y, unit.x, unit.y) <= unit.moves + 1) then
                    if (wesnoth.unit_types[unit.type].level >= XP_to_levelup) then
                        potential_target = true
                        table.insert(ind_attackers, i_u)
                    else
                        table.insert(ind_other_units, i_u)
                    end
                end
            end

            if potential_target then
                local target_info = {
                    ind_target = i_e,
                    ind_attackers = ind_attackers,
                    ind_other_units = ind_other_units
                }
                table.insert(target_infos, target_info)
            end
        end
    end
    --print('#target_infos', #target_infos)
    --DBG.dbms(target_infos)

    if (not target_infos[1]) then return 0 end

    local max_ca_score, max_rating, best_attack = 0, 0

    -- The following is done so that we at most need to do find_reach() once per unit
    -- It is needed for all units in @units and for testing whether units can move out of the way
    local reaches = LS.create()

    for _,target_info in ipairs(target_infos) do
        local target = enemies[target_info.ind_target]
        print('\nchecking attack on: ', target.id, target.x, target.y)
        local can_force_level = {}

        local attack_hexes = LS.create()

        for xa,ya in H.adjacent_tiles(target.x, target.y) do
            --print('  checking: ' .. xa .. ',' .. ya)
            local unit_in_way = wesnoth.get_unit(xa, ya)

            if unit_in_way then
                if (unit_in_way.side == wesnoth.current.side) then
                    local uiw_reach
                    if reaches:get(unit_in_way.x, unit_in_way.y) then
                        uiw_reach = reaches:get(unit_in_way.x, unit_in_way.y)
                    else
                        uiw_reach = wesnoth.find_reach(unit_in_way)
                        reaches:insert(unit_in_way.x, unit_in_way.y, uiw_reach)
                    end

                    -- Check whether the unit to move out of the way has an unoccupied hex to move to.
                    -- We do not deal with cases where a unit can move out of the way for a
                    -- unit that is moving out of the way of the initial unit (etc.).
                    local can_move = false
                    for _,uiw_loc in ipairs(uiw_reach) do
                        -- Unit in the way of the unit in the way
                        local uiw_uiw = wesnoth.get_unit(uiw_loc[1], uiw_loc[2])
                        if (not uiw_uiw) then
                            can_move = true
                            break
                        end
                    end
                    if (not can_move) then
                        hex_blocked = unit_in_way.id
                        attack_hexes:insert(xa, ya, unit_in_way.id)
                    else
                        attack_hexes:insert(xa, ya, 'empty')
                    end
                end
            else
                attack_hexes:insert(xa, ya, 'empty')
            end
            --print('    hex_blocked: ', attack_hexes:get(xa, ya))
        end
        --DBG.dbms(attack_hexes)

        attack_hexes:iter(function(xa, ya, occupied)
            for _,i_a in ipairs(target_info.ind_attackers) do
                local attacker = units[i_a]
                if (occupied == 'empty') then
                    -- If the hex is not blocked, check all potential attackers
                    local reach
                    if reaches:get(attacker.x, attacker.y) then
                        reach = reaches:get(attacker.x, attacker.y)
                    else
                        reach = wesnoth.find_reach(attacker)
                        reaches:insert(attacker.x, attacker.y, reach)
                    end

                    for _,loc in ipairs(reach) do
                        if (loc[1] == xa) and (loc[2] == ya) then
                            local tmp = {
                                ind_attacker = i_a,
                                dst = { x = xa, y = ya },
                                src = { x = attacker.x, y = attacker.y }
                            }
                            table.insert(can_force_level, tmp)
                            break
                        end
                    end
                else
                    -- If hex is blocked by own units, check whether this unit
                    -- is one of the potential attackers
                    if (attacker.id == hex_blocked) then
                        local tmp = {
                            ind_attacker = i_a,
                            dst = { x = xa, y = ya },
                            src = { x = attacker.x, y = attacker.y }
                        }

                        table.insert(can_force_level,  tmp)
                    end
                end
            end
        end)
        --DBG.dbms(can_force_level)

        -- If a leveling attack is possible, check whether any of the other units can get there
        local ca_score = 100010

        attack_hexes:iter(function(xa, ya, occupied)
            if (ca_score == 100010) then  -- can not break out of the iteration with goto
                for _,i_u in ipairs(target_info.ind_other_units) do
                    local unit = units[i_u]
                    if (occupied == 'empty') then
                        -- If the hex is not blocked, check if unit can get there
                        local reach
                        if reaches:get(unit.x, unit.y) then
                            reach = reaches:get(unit.x, unit.y)
                        else
                            reach = wesnoth.find_reach(unit)
                            reaches:insert(unit.x, unit.y, reach)
                        end

                        for _,loc in ipairs(reach) do
                            if (loc[1] == xa) and (loc[2] == ya) then
                                ca_score = 99990
                                goto found_unit
                            end
                        end
                    else
                        -- If hex is blocked by own units, check whether this unit
                        -- is one of the potential attackers
                        if (unit.id == occupied) then
                            ca_score = 99990
                            goto found_unit
                        end
                    end
                end
                -- It is sufficient to find one unit that can get to any hex
                ::found_unit::
            end
        end)

        print('  ca_score, max_ca_score:', ca_score, max_ca_score)

        if (ca_score >= max_ca_score) then
            for _,attack_info in ipairs(can_force_level) do
                local attacker_copy = wesnoth.copy_unit(units[attack_info.ind_attacker])
                attacker_copy.x = attack_info.dst.x
                attacker_copy.y = attack_info.dst.y

                print('  attack hex: ' .. attack_info.dst.x .. ',' .. attack_info.dst.y, attacker_copy.id)

                -- Otherwise choose the attacker that would do the *least*
                -- damage if the target were not to level up
                -- We want the damage distribution here as if the target were not to level up
                -- the chance to die is the same in either case
                local old_experience = target.experience
                target.experience = 0
                local att_stats, def_stats, att_weapon = wesnoth.simulate_combat(attacker_copy, target)
                target.experience = old_experience
                --DBG.dbms(att_weapon)

                local rating = -1000
                local aggression = ai.get_aggression() -- xxxx placeholder for now

                --print('    attacker hp:', attacker_copy.hitpoints)
                --print('    attacker av_hp:', att_stats.average_hp)
                --print('    attacker CTD:', att_stats.hp_chance[0])
                --print('    defender av_hp:', def_stats.average_hp)
                --print('    defender CTD:', def_stats.hp_chance[0])
                --print('    aggression:', aggression)

                if (att_stats.hp_chance[0] <= aggression) then
                    if (def_stats.hp_chance[0] > 0) then
                        rating = 5000
                        rating = rating + def_stats.hp_chance[0] - att_stats.hp_chance[0]
                    elseif target.status.poisoned then
                        rating = -1002
                    else
                        rating = 1000

                        local enemy_value_loss = (target.hitpoints - def_stats.average_hp) / target.max_hitpoints
                        enemy_value_loss = enemy_value_loss * wesnoth.unit_types[target.type].cost
                        --print('enemy_value_loss', enemy_value_loss)

                        -- We want the _least_ damage to the enemy, so the minus sign is no typo!
                        rating = rating - enemy_value_loss

                        local own_value_loss = (attacker_copy.hitpoints - att_stats.average_hp) / attacker_copy.max_hitpoints
                        own_value_loss = own_value_loss + att_stats.hp_chance[0]
                        own_value_loss = own_value_loss * wesnoth.unit_types[attacker_copy.type].cost
                        --print('own_value_loss', own_value_loss)

                        rating = rating - own_value_loss

                        -- Strongly discourage poison or slow attacks
                        if att_weapon.poisons or att_weapon.slows then
                            rating = rating - 100
                        end

                        -- Minor penalty if the attack hex is occupied
                        --if att.attack_hex_occupied then
                        --    rating = rating - 0.001
                        --end
                    end
                end
                print('    -> rating', rating)

                if (rating > max_rating)
                    or ((rating > 0) and (ca_score > max_ca_score))
                then
                    max_rating = rating
                    max_ca_score = ca_score
                    best_attack = attack_info
                    best_attack.target = { x = target.x, y = target.y }
                    best_attack.ca_score = ca_score
                end
            end
        end
    end

    print('\n--> best rating, ca_score:', max_rating, max_ca_score)
    --DBG.dbms(best_attack)

    if best_attack then
        data.XP_attack = best_attack
    end

    return max_ca_score
end

function ca_attack_highxp:execution(cfg, data)
    local attacker = wesnoth.get_unit(data.XP_attack.src.x, data.XP_attack.src.y)
    local defender = wesnoth.get_unit(data.XP_attack.target.x, data.XP_attack.target.y)

    wesnoth.fire("message", { speaker = attacker.id, message = "Executing high XP attack, ca_score = " .. data.XP_attack.ca_score })

    AH.movefull_outofway_stopunit(ai, attacker, data.XP_attack.dst.x, data.XP_attack.dst.y)
    if (not attacker) or (not attacker.valid) then return end
    if (not defender) or (not defender.valid) then return end

    AH.checked_attack(ai, attacker, defender)
    data.XP_attack = nil
end

return ca_attack_highxp
