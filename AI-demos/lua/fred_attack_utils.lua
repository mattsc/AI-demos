local H = wesnoth.require "helper"
local FGM = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_map.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local FVS = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_virtual_state.lua"
local FDI = wesnoth.require "~/add-ons/AI-demos/lua/fred_data_incremental.lua"
local FCFG = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_config.lua"
local COMP = wesnoth.require "~/add-ons/AI-demos/lua/compatibility.lua"
--local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

-- Functions to perform fast evaluation of attacks and attack combinations.
-- The emphasis with all of this is on speed, not elegance.
-- This might result in redundant information being produced/passed and similar
-- or the format of cache tables being somewhat tedious, etc.
-- Note to self: working with Lua tables is generally much faster than with unit proxy tables.
-- Also, creating tables takes time, indexing by number is faster than by string, etc.


local function init_attack_outcome(unit_info)
    -- Initialize the attack outcome table, to make sure all fields are present
    --
    -- OPTIONAL INPUT:
    --  @unit_info: if given, initialize the table with the correct values for
    --    this unit before combat. Otherwise, set everything to zero.


    ----- Begin single_level_table() -----
    local function single_level_table(unit_info, levelup)
        -- @levelup: boolean indicating whether this is the levelup table
        --   The one difference is that the levelup table should not contain
        --   hp_chance[0], which should always be added to the top level table.
        local hp_chance = {}
        if (not levelup) then hp_chance[0] = 0 end
        if unit_info then hp_chance[unit_info.hitpoints] = 1 end

        local outcome = {
            average_hp = unit_info and unit_info.hitpoints or 0,
            poisoned = 0,
            slowed = 0,
            hp_chance = hp_chance,
            min_hp = unit_info and unit_info.hitpoints or 0
        }

        if unit_info and unit_info.status.poisoned then outcome.poisoned = 1 end
        if unit_info and unit_info.status.slowed then outcome.slowed = 1 end

        return outcome
    end
    ----- End single_level_table() -----


    local attack_outcome = single_level_table(unit_info, false)
    attack_outcome.levelup = single_level_table(nil, true)
    attack_outcome.levelup_chance = 0

    return attack_outcome
end

local function calc_stats_attack_outcome(outcome)
    -- Calculate and set the summary statistics values in an attack outcome table.
    -- The input table is manipulated directly for this, there is no return value.
    -- Values in the main table: stats for both main and levelup combined
    -- Values in levelup table: stats for levelup only

    local min_hp, min_hp_levelup = math.huge, math.huge
    local average_hp, average_hp_levelup, levelup_chance = 0, 0, 0

    for hp,chance in pairs(outcome.hp_chance) do
        average_hp = average_hp + hp * chance
        if (chance ~= 0) then
            if (hp < min_hp) then min_hp = hp end
        end
    end

    for hp,chance in pairs(outcome.levelup.hp_chance) do
        average_hp = average_hp + hp * chance
        average_hp_levelup = average_hp_levelup + hp * chance
        levelup_chance = levelup_chance + chance
        if (chance ~= 0) then
            if (hp < min_hp) then min_hp = hp end
            if (hp < min_hp_levelup) then min_hp_levelup = hp end
        end
    end

    outcome.average_hp = average_hp
    outcome.min_hp = min_hp
    outcome.levelup_chance = levelup_chance

    if (levelup_chance > 0) then
        outcome.levelup.average_hp = average_hp_levelup / levelup_chance
    end
    if min_hp_levelup then outcome.levelup.min_hp = min_hp_levelup end


    -- TODO: the following is just a sanity check for now, disable later
    local sum_chances = 0
    for _,chance in pairs(outcome.hp_chance) do
        sum_chances = sum_chances + chance
    end
    sum_chances = sum_chances + outcome.levelup_chance

    if (math.abs(sum_chances - 1) > 0.0001) then
        std_print('***** error: sum over outcomes not equal to 1: *****', sum_chances)
    end
end


local fred_attack_utils = {}

function fred_attack_utils.is_acceptable_attack(neg_rating, pos_rating, value_ratio)
    -- Evaluate whether an attack is acceptable, based on its negative and positive ratings.
    -- Negative rating comes from damage to the own units and healing of the enemies.
    -- Positive rating is the opposte.
    -- The smaller @value_ratio, the more aggressive the AI gets.
    -- As an example, if value_ratio = 0.5 -> it is okay for the positive rating to be
    -- only half as big as the negative rating.
    -- Note that @neg_rating is expected to be a negative number.

    -- TODO: this has become so simple, that it is essentially not worth having a function for it.
    --   Keeping it for now anyway, as we might expand it later.

    local sum = pos_rating + neg_rating * value_ratio

    -- Note: it's important that the equal sign is included here
    local is_acceptable = (sum >= 0)
    --std_print(string.format('is_acceptable_attack:  %.3f %.3f * %.3f = %.3f   is >= 0?  :  %s', pos_rating, neg_rating, value_ratio, sum, tostring(is_acceptable)))

    return is_acceptable
end

function fred_attack_utils.unit_damage(unit_info, att_outcome, dst, fred_data)
    -- Return a table with the different contributions to damage a unit is
    -- expected to experience in an attack.
    -- The attack att_outcome for the attacker need to be precalculated for this.
    -- Unit information is passed in unit_infos format, rather than as unit proxy tables for speed reasons.
    -- Note: damage is damage TO the unit, not damage done BY the unit
    --
    -- Returns a table with different information about the damage.  Not all of these
    -- are in the same units (some are damage in HP, other percentage chances etc.
    -- Most of this information is also easily available otherwise.  The purpose here
    -- is to collect only the essential information for attack ratings in one table
    --
    -- Input parameters:
    --  @unit_info: unit_info table produced by fred_utils.single_unit_info()
    --  @att_outcome: attack outcomes for the attackers as from attack_outcome or attack_combo_eval
    --  @dst: location of the unit for which to calculate this; this might or
    --   might not be the current location of the unit

    local move_data = fred_data.move_data

    ----- Begin get_delayed_damage() -----
    local function get_delayed_damage(unit_info, att_outcome, average_damage, dst, move_data)
        -- This does, in principle, not have to be a separate function, as it is only
        -- called once, but this way it can be made accessible from outside again, if needed.
        --
        -- Returns the damage the unit is expected to get from delayed effects, both
        -- positive and negative. The value returned is the actual damage times the
        -- probability of the effect.
        --  - Positive damage: poison
        --  - Negative damage: villages, regenerate, healthy trait
        --      Rest healing is not considered, as this is for attack evaluation.
        -- TODO: add healers
        -- Return value is in units of hitpoints
        --
        -- @dst: location of the unit for which to calculate this; this might or
        --   might not be the current location of the unit

        local delayed_damage = 0

        -- Positive delayed damage (poison etc.)

        -- Count poisoned as additional 8 HP damage times probability of being poisoned
        -- but only if the unit is not already poisoned
        -- Notes:
        --  - Unlike wesnoth.simulate_combat, attack_outcome does not count the
        --    HP=0 case counts as poisoned
        --  - No special treatment is needed for unpoisonable units (e.g. undead)
        --    as att_outcome.poisoned is always zero for them
        if (att_outcome.poisoned ~= 0) and (not unit_info.status.poisoned) then
            local poison_damage = 8
            if unit_info.traits.healthy then
                poison_damage = poison_damage * 0.75
            end
            delayed_damage = delayed_damage + poison_damage * att_outcome.poisoned
        end

        -- Negative delayed damage (healing)
        local is_village = FGM.get_value(move_data.village_map, dst[1], dst[2], 'owner')

        -- If unit is on a village, we count that as an 8 HP bonus (negative damage)
        -- multiplied by the chance to survive
        if is_village then
            delayed_damage = delayed_damage - 8 * (1 - att_outcome.hp_chance[0])
        -- Otherwise only: if unit can regenerate, this is an 8 HP bonus (negative damage)
        -- multiplied by the chance to survive and not be poisoned
        elseif unit_info.abilities.regenerate then
            delayed_damage = delayed_damage - 8 * (1 - att_outcome.hp_chance[0] - att_outcome.poisoned)
        end

        if unit_info.traits.healthy then
            delayed_damage = delayed_damage - 2
        end

        -- Units with healthy trait get an automatic 2 HP healing
        -- We don't need to check whether a unit is resting otherwise, as this
        -- is for attack calculations (meaning: they won't be resting)
        if unit_info.traits.healthy then
            delayed_damage = delayed_damage - 2
        end

        -- Positive damage needs to be capped at the amount of HP (can't lose more than that)
        -- Note: in principle, this is (HP-1), but that might cause a negative damage
        -- rating for units with average_hp < 1.
        -- Calculated with respect to average hitpoints
        local hp_before = unit_info.hitpoints - average_damage
        delayed_damage = math.min(delayed_damage, hp_before)

        -- Negative damage needs to be capped at amount by which hitpoints are below max_hitpoints
        -- Note that neg_hp_to_max is negative; delayed_damage cannot be smaller than that
        -- Calculated with respect to average hitpoints
        local neg_hp_to_max = hp_before - unit_info.max_hitpoints
        delayed_damage = math.max(delayed_damage, neg_hp_to_max)

        return delayed_damage
    end
    ----- End get_delayed_damage() -----


    --std_print(unit_info.id, unit_info.hitpoints, unit_info.max_hitpoints)
    local damage = {}

    -- Average damage from the attack.  This cannot be simply the average_hp field
    -- of att_outcome, as that accounts for leveling up differently than needed here
    -- Start with that as the default though:
    local average_damage = unit_info.hitpoints - att_outcome.average_hp
    --std_print('  average_damage raw:', average_damage)

    -- We want to include healing due to drain etc. in this damage, but not
    -- leveling up, so if there is a chance to level up, we need to do that differently.
    if (att_outcome.levelup_chance > 0) then
        average_damage = 0
        -- Note: the probabilities here do not add up to 1 -- that's intentional
        for hp,chance in pairs(att_outcome.hp_chance) do
            average_damage = average_damage + (unit_info.hitpoints - hp) * chance
        end
    end
    --std_print('  average_damage:', average_damage)

    -- Now add some of the other contributions
    damage.damage = average_damage
    damage.die_chance = att_outcome.hp_chance[0]

    damage.levelup_chance = att_outcome.levelup_chance
    --std_print('  levelup_chance', damage.levelup_chance)

    damage.delayed_damage = get_delayed_damage(unit_info, att_outcome, average_damage, dst, move_data)

    -- Slow is somewhat harder to account for correctly. It sort of takes half the
    -- unit away, but since it's temporary, we assign only half of that as "damage".
    -- We also separate it out, as it wears off at the end of the respective side turn.
    damage.slowed_damage = 0
    if (att_outcome.slowed ~= 0) and (not unit_info.status.slowed) then
        damage.slowed_damage = unit_info.max_hitpoints / 4 * att_outcome.slowed
    end

    -- Finally, add some info about the unit, just for convenience
    damage.id = unit_info.id
    damage.hitpoints = unit_info.hitpoints
    damage.max_hitpoints = unit_info.max_hitpoints
    damage.unit_value = unit_info.unit_value

    --DBG.dbms(damage)

    return damage
end

function fred_attack_utils.damage_rating_unit(damage, cfg)
    -- Calculate a damage rating for a unit from the table returned by
    -- fred_attack_utils.unit_damage()
    -- This is a total rating, adding up direct, delayed and slow damage.
    -- TODO: if needed, the function could return a table with separate ratings
    --
    -- Optional inputs:
    --  @cfg:
    --   - @levelup_weight: weight to use for the level-up rating
    --
    -- !!!! Note !!!!: unlike some previous versions, we count damage as negative
    -- in this rating

    local levelup_weight = cfg and cfg.levelup_weight or 1

    ----- Begin assign_ratings() -----
    function assign_ratings(new_rating, damage_rating, heal_rating)
        if (new_rating < 0) then
            damage_rating = damage_rating + new_rating
        else
            heal_rating = heal_rating + new_rating
        end
        --std_print('  -> damage_rating, heal_rating', damage_rating, heal_rating, new_rating)

        return damage_rating, heal_rating
    end
    ----- End assign_ratings() -----


    -- In principle, damage is a fraction of max_hitpoints. However, it should be
    -- more important for units already injured. Making it a fraction of hitpoints
    -- would overemphasize units close to dying, as that is also factored in. Thus,
    -- we use an effective HP value that's a weighted average of the two.
    -- TODO: splitting it 50/50 seems okay for now, but might have to be fine-tuned.
    local injured_fraction = 0.5
    local hp_eff = injured_fraction * damage.hitpoints + (1 - injured_fraction) * damage.max_hitpoints

    -- damage and delayed_damage can be both positive and negative
    -- slowed_damage and die_chance are always negative
    -- levelup_chance is always positive
    -- TODO: we do not currently split into positive and negative contributions WITHIN each type

    --std_print(damage.id)

    local damage_rating, heal_rating = 0, 0

    -- With this, fractional damage and ctd_rating (below) can still add up to more than 1, but
    -- not by as ridiculously much as it was before (which peaked at 2.5)
    local fractional_damage = damage.damage / hp_eff * (1 - 0.8 * damage.die_chance)

    local fractional_rating = - FU.weight_s(fractional_damage, 0.67)
    --std_print('  fractional_damage, fractional_rating:', fractional_damage, fractional_rating)
    damage_rating, heal_rating = assign_ratings(fractional_rating, damage_rating, heal_rating)

    local fractional_delayed_damage = damage.delayed_damage / hp_eff
    local fractional_delayed_rating = - FU.weight_s(fractional_delayed_damage, 0.67)
    --std_print('  fractional_delayed_damage, fractional_delayed_rating:', fractional_delayed_damage, fractional_delayed_rating)
    damage_rating, heal_rating = assign_ratings(fractional_delayed_rating, damage_rating, heal_rating)

    local fractional_slowed_damage = damage.slowed_damage / hp_eff
    local fractional_slowed_rating = - FU.weight_s(fractional_slowed_damage, 0.67)
    --std_print('  fractional_slowed_damage, fractional_slowed_rating:', fractional_slowed_damage, fractional_slowed_rating)
    damage_rating = damage_rating + fractional_slowed_rating
    --std_print('  -> damage_rating, heal_rating', damage_rating, heal_rating, fractional_slowed_rating)

    -- Additionally, add the chance to die, in order to emphasize units that might die
    -- This might result in fractional_damage > 1 in some cases, although usually not by much
    -- TODO: potentially balance this vs. damage rating, to limit it to not much more than 1
    local ctd_rating = - 1.5 * damage.die_chance^1.5
    --std_print('  ctd, ctd_rating:', damage.die_chance, ctd_rating)
    damage_rating = damage_rating + ctd_rating
    --std_print('  -> damage_rating, heal_rating', damage_rating, heal_rating, ctd_rating)

    -- Levelup chance: we use square rating here, as opposed to S-curve rating
    -- for the other contributions
    -- TODO: does that make sense?
    local lu_rating = damage.levelup_chance^2
    --std_print('  lu_chance, lu_rating:', damage.levelup_chance, lu_rating)
    -- TODO: Note that using levelup_weight<0 might underestimate (other) damage received
    heal_rating = heal_rating + lu_rating * levelup_weight
    --std_print('  -> damage_rating, heal_rating', damage_rating, heal_rating, lu_rating)

    -- Convert all the fractional ratings before to one in "gold units"
    damage_rating = damage_rating * damage.unit_value
    heal_rating = heal_rating * damage.unit_value

    --std_print('  unit_value, ratings:', damage.unit_value, damage_rating, heal_rating)

    return nil, damage_rating, heal_rating -- TODO: eventually clean this up
end

function fred_attack_utils.attack_rating(attacker_infos, defender_info, dsts, att_outcomes, def_outcome, cfg, fred_data)
    -- Returns a common (but configurable) rating for attacks of one or several attackers against one defender
    --
    -- Inputs:
    --  @attackers_infos: input array of attacker unit_info tables (must be an array even for single unit attacks)
    --  @defender_info: defender unit_info
    --  @dsts: array of attack locations in form { x, y } (must be an array even for single unit attacks)
    --  @att_outcomes: array of the attack outcomes of the attack combination(!) of the attackers
    --    (must be an array even for single unit attacks)
    --  @def_outcome: the combat outcome of the defender after facing the combination of all attackers
    --  @cfg:
    --   - @value_ratio: if different from default
    --   - @defender_loc: if different from the position of the unit in the tables
    --   - @levelup_weight: weight to use for the level-up rating of damage_rating_unit()
    --  @move_data: table with the game state
    --
    -- Returns:
    --   - Overall rating for the attack or attack combo
    --   - Attacker rating: the sum of all the attacker damage ratings
    --   - Defender rating: the combined defender damage rating
    --   - Extra rating: additional ratings that do not directly describe damage
    --       This should be used to help decide which attack to pick,
    --       but not for, e.g., evaluating counter attacks (which should be entirely damage based)
    --   Note: rating = defender_rating * defender_weight + attacker_rating * attacker_weight + extra_rating
    --          defender/attacker_rating are "damage done" ratings
    --          -> defender_rating >= 0; attacker_rating <= 0
    --          defender/attack_weight are set equal to value_ratio for the AI
    --          side, and to 1 for the other side

    local move_data = fred_data.move_data

    -- Set up the config parameters for the rating
    local terrain_defense_weight = FCFG.get_cfg_parm('terrain_defense_weight')
    local distance_leader_weight = FCFG.get_cfg_parm('distance_leader_weight')
    local occupied_hex_penalty = FCFG.get_cfg_parm('occupied_hex_penalty')
    local value_ratio = cfg.value_ratio

    -- TODO: Make cfg.value_ratio required for now. This is for testing at the moment, so that
    -- I don't forget to set it. It can be removed later
    if (not value_ratio) then error('No value_ratio passed to fred_attack_utils.attack_rating()') end

    local attacker_damages = {}
    --local attacker_rating = 0
    local neg_rating, pos_rating = 0, 0
    for i,attacker_info in ipairs(attacker_infos) do
        attacker_damages[i] = fred_attack_utils.unit_damage(attacker_info, att_outcomes[i], dsts[i], fred_data)
        local _, anr, apr = fred_attack_utils.damage_rating_unit(attacker_damages[i], cfg)
        neg_rating = neg_rating + anr
        pos_rating = pos_rating + apr
        --std_print(attacker_info.id, neg_rating, pos_rating, anr, apr)
    end

    local defender_x, defender_y
    if cfg and cfg.defender_loc then
        defender_x, defender_y = cfg.defender_loc[1], cfg.defender_loc[2]
    else
        defender_x, defender_y = move_data.units[defender_info.id][1], move_data.units[defender_info.id][2]
    end
    local defender_damage = fred_attack_utils.unit_damage(defender_info, def_outcome, { defender_x, defender_y }, fred_data)
    -- Rating for the defender is negative damage rating (as in, damage is good)
    local _, dnr, dpr = fred_attack_utils.damage_rating_unit(defender_damage, cfg)
    neg_rating = neg_rating - dpr -- minus sign and p/n switched
    pos_rating = pos_rating - dnr
    --std_print(defender_info.id, neg_rating, pos_rating, dnr, dpr)


    -- Bonus for turning enemy into walking corpse with plague.
    -- This is a large value as it directly creates an 8-gold unit, that is, it
    -- is not divided by the max_hp of the unit.
    -- TODO: this does not consider whether the plague weapon is actually the weapon used
    for i,attacker_info in ipairs(attacker_infos) do
        for _,weapon in ipairs(attacker_info.attacks) do
            if weapon.plague then
                --std_print('attacker #' .. i .. ' ' .. attacker_info.id ..' has plague special')
                local ctk
                if (#attacker_infos == 1) then
                    ctk = def_outcome.hp_chance[0]
                else
                    ctk = def_outcome.ctd_progression[i] - (def_outcome.ctd_progression[i - 1] or 0)
                end
                local plague_bonus = 8 * ctk

                -- Converting the defender is positive rating for attacker side (new WC)
                pos_rating = pos_rating + plague_bonus
                --std_print('  applying attacker plague bonus', pos_rating, plague_bonus, ctk)

                break
            end
        end
    end

    for _,weapon in ipairs(defender_info.attacks) do
        if weapon.plague then
            --std_print('defender ' .. defender_info.id ..' has plague special')
            for i,att_outcome in ipairs(att_outcomes) do
                local ctk = att_outcome.hp_chance[0]
                local plague_penalty = 8 * ctk

                -- Converting the attacker is (negative) contribution to the defender rating
                neg_rating = neg_rating - plague_penalty
                --std_print('  applying attacker #' .. i .. ' plague plague_penalty', neg_rating, plague_penalty, ctk)
            end

            break
        end
    end


    -- Now we add some extra ratings. They are positive for attacks that should be preferred
    -- and expressed in fraction of the defender maximum hitpoints
    -- They should be used to help decide which attack to pick all else being equal,
    -- but not for, e.g., evaluating counter attacks (which should be entirely damage based)
    local extra_rating = 0.

    -- If defender is on a village, add a bonus rating (we want to get rid of those preferentially)
    -- This is in addition to the damage bonus (penalty, if enemy) already included above (but as an extra rating)
    local defender_on_village = FGM.get_value(move_data.village_map, defender_x, defender_y, 'owner')
    if defender_on_village then
        extra_rating = extra_rating + 10.
    end

    -- Normalize so that it is in fraction of defender max_hitpoints
    extra_rating = extra_rating / defender_info.max_hitpoints

    -- Most of the time, we don't need a bonus for good terrain for the attacker,
    -- as that is covered in the damage calculation. However, this might give misleading
    -- results for units that can regenerate (they might get equal rating independent
    -- of the terrain) -> add a small bonus for terrain
    local defense_rating_attacker = 0.
    for i,attacker_info in ipairs(attacker_infos) do
        defense_rating_attacker = defense_rating_attacker + FDI.get_unit_defense(
            move_data.unit_copies[attacker_info.id],
            dsts[i][1], dsts[i][2],
            fred_data.caches.defense_maps
        )
    end
    defense_rating_attacker = defense_rating_attacker / #attacker_infos * terrain_defense_weight

    extra_rating = extra_rating + defense_rating_attacker

    -- Also, we add a small bonus for good terrain defense of the _defender_ on the _attack_ hexes
    -- This is in order to take good terrain away from defender on its next move
    local defense_rating_defender = 0.
    for _,dst in ipairs(dsts) do
        defense_rating_defender = defense_rating_defender + FDI.get_unit_defense(
            move_data.unit_copies[defender_info.id],
            dst[1], dst[2],
            fred_data.caches.defense_maps
        )
    end
    defense_rating_defender = defense_rating_defender / #dsts * terrain_defense_weight

    extra_rating = extra_rating + defense_rating_defender

    -- Get a very small bonus for hexes in between defender and AI leader
    -- 'relative_distances' is larger for attack hexes closer to the side leader (possible values: -1 .. 1)
    local rel_dist_rating = 0.
    for _,dst in ipairs(dsts) do
        local relative_distance =
            wesnoth.map.distance_between(defender_x, defender_y, move_data.my_leader[1], move_data.my_leader[2])
            - wesnoth.map.distance_between(dst[1], dst[2], move_data.my_leader[1], move_data.my_leader[2])
        rel_dist_rating = rel_dist_rating + relative_distance
    end
    rel_dist_rating = rel_dist_rating / #dsts * distance_leader_weight

    extra_rating = extra_rating + rel_dist_rating

    -- Add a very small penalty for attack hexes occupied by other own units that can move out of the way
    -- Note: it must be checked previously that the unit on the hex can move away,
    --    that is we only check move_data.my_unit_map_MP here
    for i,dst in ipairs(dsts) do
        local id = FGM.get_value(move_data.my_unit_map_MP, dst[1], dst[2], 'id')
        if id and (id ~= attacker_infos[i].id) then
            extra_rating = extra_rating - occupied_hex_penalty
        end
    end
    --std_print('extra_rating', extra_rating)

    -- Finally add up and apply factor of own unit damage to defender unit damage
    -- This is a number equivalent to 'aggression' in the default AI (but not numerically equal)
    -- TODO: clean up this code block; for the time being, I want it to crash is something's wrong
    local pos_weight, neg_weight
    if (attacker_infos[1].side == wesnoth.current.side) then
        neg_weight = value_ratio
        pos_weight = 1
    end
    if (defender_info.side == wesnoth.current.side) then
        neg_weight = 1
        pos_weight = value_ratio
    end
    --std_print('neg_weight, pos_weight', neg_weight, pos_weight)

    local rating = neg_rating * neg_weight + pos_rating * pos_weight + extra_rating

    --std_print('rating, neg_rating, pos_rating, extra_rating:', rating, neg_rating, pos_rating, extra_rating)

    -- The overall ratings take the value_ratio into account, the attacker and
    -- defender tables do not
    local rating_table = {
        rating = rating,
        --attacker_rating = attacker_rating,
        --defender_rating = defender_rating,
        neg_rating = neg_rating,
        pos_rating = pos_rating,
        extra_rating = extra_rating,
        neg_weight = neg_weight,
        pos_weight = pos_weight
        --value_ratio = value_ratio
    }
    --DBG.dbms(rating_table, false, 'rating_table')

    return rating_table, attacker_damages, defender_damage
end

function fred_attack_utils.get_total_damage_attack(weapon, attack, is_attacker, opponent_info)
    -- Get the (approximate) total damage an attack will do, as well as its three
    -- components: base_damage, extra_damage, regen_damage
    --
    -- @weapon: the weapon information as returned by wesnoth.simulate_combat(), that is,
    --   taking resistances etc. into account
    -- @attack: the attack information as returned by fred_utils.single_unit_info()
    --   If @attack == nil, that is, if the unit has no weapon at the range,
    --   it still returns values: zeros for normal damages, and the real regeneration
    --   values for the opponent. This is useful for when the defender does not have
    --   a weapon at the range, but the regeneration values for the attacker are
    --   needed in a unified way (as opposed to duplicating the code elsewhere).
    -- @is_attacker: set to 'true' if this is the attacker, 'false' for defender

    -- The following two are the same for the same opponent. That is, they make
    -- no difference for selecting the best weapon for a given attacker/defender
    -- pair, but they do matter if this is use to compare attacks between
    -- different units pairs
    local regen_damage = 0
    if opponent_info.abilities.regenerate then
        regen_damage = regen_damage - 8
    end
    if opponent_info.traits.healthy then
        regen_damage = regen_damage - 2
    end

    if (not attack) then
        return regen_damage, 0, 0, regen_damage
    end


    local base_damage = weapon.num_blows * weapon.damage

    -- Give bonus for weapon specials. This is not exactly what those specials
    -- do in all cases, but that's okay since this is only used to determine
    -- the strongest weapons or most effective attacks/units.

    local extra_damage = 0

    -- Count poison as additional 8 HP on total damage
    if attack.poison and (not opponent_info.status.poisoned) and (not opponent_info.status.unpoisonable) then
        local poison_damage = 8
        if opponent_info.traits.healthy then
           poison_damage = poison_damage * 0.75
        end
        extra_damage = extra_damage + poison_damage
    end

    -- Count slow as additional 4 HP on total damage
    if attack.slow and (not opponent_info.status.slowed) then
        extra_damage = extra_damage + 4
    end

    -- Count drains as additional 25% on total damage
    -- Don't use the full 50% healing that drains provides, as we want to
    -- emphasize the actual damage done over the benefit received
    if attack.drains and (not opponent_info.status.undrainable) then
        extra_damage = math.floor(extra_damage * 1.25)
    end

    -- Count berserk as additional 100% on total damage
    -- This is not exact at all and should, in principle, also be applied if
    -- the opponent has berserk.  However, since it is only used to find the
    -- strongest weapon, it's good enough. (It is unlikely that an attacker
    -- would choose to attack an opponent with the opponents berserk attack
    -- if that is not the attacker's strongest weapon.)
    if attack.berserk then
        extra_damage = math.floor(extra_damage * 2)
    end

    -- Double damage for backstab, but only if it was not active in the
    -- weapon table determination by wesnoth.simulate_combat()
    -- We do not quite give the full factor 2 though, as it is not active on all attacks.
    if is_attacker and attack.backstab and (not weapon.backstabs) then
        extra_damage = extra_damage * 1.8
    end

    -- Marksman, firststrike, magical and plague don't really change the damage. We just give
    -- a small bonus here as a tie breaker.
    -- Marksman and firststrike are only active on attack
    if is_attacker and attack.marksman then
        extra_damage = extra_damage + 2
    end
    if is_attacker and attack.firststrike then
        extra_damage = extra_damage + 2
    end
    if attack.magical then
        extra_damage = extra_damage + 2
    end
    if attack.plague and (not opponent_info.status.unplagueable) then
        extra_damage = extra_damage + 2
    end
    if attack.petrifies then
        extra_damage = extra_damage + 2
    end

    -- Notes on other weapons specials:
    --  - charge is automatically taken into account
    --  - swarm is automatically taken into account

    local total_damage = base_damage + extra_damage + regen_damage

    return total_damage, base_damage, extra_damage, regen_damage
end

function fred_attack_utils.attstat_to_outcome(unit_info, stat, enemy_ctd, enemy_level)
    -- Convert @stat as returned by wesnoth.simulate_combat to attack_outcome
    -- format. In addition to extracting information from @stat, this includes:
    --  - Only keep non-zero hp_chance values, except hp_chance[0] which is always needed
    --  - Setting up level-up information (and recalculating average_hp)
    --  - Setting min_hp
    --  - Poison/slow: correctly account for level-up and do not count HP=0

    local outcome = init_attack_outcome()
    for hp,chance in pairs(stat.hp_chance) do
        if (chance ~= 0) then
            outcome.hp_chance[hp] = chance
        end
    end

    if (enemy_level == 0) then enemy_level = 0.5 end  -- L0 units
    local levelup_chance = 0.
    -- If missing XP is <= level of attacker, it's a guaranteed level-up as long as the unit does not die
    -- This does work even for L0 units (with enemy_level = 0.5)
    if (unit_info.max_experience - unit_info.experience <= enemy_level) then
        levelup_chance = 1. - outcome.hp_chance[0]
    -- Otherwise, if a kill is needed, the level-up chance is that of the enemy dying
    elseif (unit_info.max_experience - unit_info.experience <= enemy_level * 8) then
        levelup_chance = enemy_ctd
    end

    if (levelup_chance > 0) then
        if unit_info.advances_to then
            outcome.levelup.type = unit_info.advances_to
            outcome.levelup.max_hp = wesnoth.unit_types[unit_info.advances_to].max_hitpoints
        else
            outcome.levelup.type = unit_info.type
            outcome.levelup.max_hp = unit_info.max_hitpoints + 3 -- Default AMLA
        end
        outcome.levelup.hp_chance[outcome.levelup.max_hp] = levelup_chance

        -- wesnoth.simulate_combat returns the level-up chance as part of the
        -- maximum hitpoints in the stats -> need to reset that
        local max_hp_chance = outcome.hp_chance[unit_info.max_hitpoints] - levelup_chance
        if (math.abs(max_hp_chance) < 1e-6) then
            outcome.hp_chance[unit_info.max_hitpoints] = nil
        else
            outcome.hp_chance[unit_info.max_hitpoints] = max_hp_chance
        end
    end

    -- We also need to adjust poison and slow for two reasons:
    --  1. If a level-up is involved, wesnoth.simulate_combat does not "heal" the unit
    --  2. We want the case of HP=0 to count as not poisoned/slowed
    outcome.poisoned = 0
    if (stat.poisoned > 0) then
        for hp,chance in pairs(outcome.hp_chance) do
            -- TODO: this will not always work 100% correctly with drain; others?
            if (hp < unit_info.hitpoints) and (hp ~= 0) then
                outcome.poisoned = outcome.poisoned + chance
            end
        end
    end
    outcome.slowed = 0
    if (stat.slowed > 0) then
        for hp,chance in pairs(outcome.hp_chance) do
            -- TODO: this will not always work 100% correctly with drain; others?
            if (hp < unit_info.hitpoints) and (hp ~= 0) then
                outcome.slowed = outcome.slowed + chance
            end
        end
    end

    calc_stats_attack_outcome(outcome)

    return outcome
end

function fred_attack_utils.attack_outcome(attacker_copy, defender_proxy, dst, attacker_info, defender_info, fred_data)
    -- Calculate the outcome of a combat by @attacker_copy vs. @defender_proxy at location @dst
    -- We use wesnoth.simulate_combat for this, but cache results when possible
    -- Inputs:
    -- @attacker_copy: private unit copy of the attacker (must be a copy, does not work with the proxy table)
    -- @defender_proxy: defender proxy table (must be a unit proxy table on the map, does not work with a copy)
    -- @dst: location from which the attacker will attack in form { x, y }
    -- @attacker_info, @defender_info: unit info for the two units (needed in addition to the units
    --   themselves in order to speed things up)

    local move_data = fred_data.move_data
    local attacks_cache = fred_data.caches.attacks

    local defender_defense = FDI.get_unit_defense(defender_proxy, defender_proxy.x, defender_proxy.y, fred_data.caches.defense_maps)
    local attacker_defense = FDI.get_unit_defense(attacker_copy, dst[1], dst[2], fred_data.caches.defense_maps)

    -- Units need to be identified by id and XP
    -- There is a very small chance that this could be ambiguous, ignore that for now
    local cache_att_id = attacker_info.id .. '-' .. attacker_info.experience
    local cache_def_id = defender_info.id .. '-' .. defender_info.experience

    -- TODO: this does not include differences due to XP, leadership, illumination etc.
    if attacks_cache[cache_att_id]
        and attacks_cache[cache_att_id][cache_def_id]
        and attacks_cache[cache_att_id][cache_def_id][attacker_defense]
        and attacks_cache[cache_att_id][cache_def_id][attacker_defense][defender_defense]
        and attacks_cache[cache_att_id][cache_def_id][attacker_defense][defender_defense][attacker_info.hitpoints]
        and attacks_cache[cache_att_id][cache_def_id][attacker_defense][defender_defense][attacker_info.hitpoints][defender_info.hitpoints]
    then
        return attacks_cache[cache_att_id][cache_def_id][attacker_defense][defender_defense][attacker_info.hitpoints][defender_info.hitpoints].att_outcome,
            attacks_cache[cache_att_id][cache_def_id][attacker_defense][defender_defense][attacker_info.hitpoints][defender_info.hitpoints].def_outcome,
            attacks_cache[cache_att_id][cache_def_id][attacker_defense][defender_defense][attacker_info.hitpoints][defender_info.hitpoints].att_weapon_i
    end

    local old_x, old_y = attacker_copy.x, attacker_copy.y
    attacker_copy.x, attacker_copy.y = dst[1], dst[2]

    local tmp_att_stat, tmp_def_stat, att_weapon
    local att_weapon_i, def_weapon_i

    -- TODO: This is always set to true for now, as it can otherwise cause discontinuities
    -- in the attack evaluations. Either find a better way to do this or remove later.
    local use_max_damage_weapons = true
    if use_max_damage_weapons then
        if (not attacks_cache.best_weapons)
            or (not attacks_cache.best_weapons[attacker_info.id])
            or (not attacks_cache.best_weapons[attacker_info.id][defender_info.id])
        then
            if (not attacks_cache[cache_att_id]) then
                attacks_cache[cache_att_id] = {}
            end
            if (not attacks_cache[cache_att_id][cache_def_id]) then
                attacks_cache[cache_att_id][cache_def_id] = {}
            end

            --std_print(' Finding highest-damage weapons: ', attacker_info.id, defender_info.id)

            local max_att_damage, max_def_damage = - math.huge, - math.huge

-- TODO: if there is only one weapon, don't need to simulate?

            for i_a,att in ipairs(attacker_info.attacks) do
                -- This is a bit wasteful the first time around, but shouldn't be too bad overall
                local _, _, att_weapon, _ = wesnoth.simulate_combat(attacker_copy, i_a, defender_proxy)

                local total_damage_attack = fred_attack_utils.get_total_damage_attack(att_weapon, att, true, defender_info)
                --std_print('  i_a:', i_a, total_damage_attack)

                if (total_damage_attack > max_att_damage) then
                    max_att_damage = total_damage_attack
                    att_weapon_i = i_a

                    -- Only for this attack do we need to check out the defender attacks
                    max_def_damage, def_weapon_i = - math.huge, nil -- need to reset these again

                    for i_d,def in ipairs(defender_info.attacks) do
                        if (att.range == def.range) then
                            -- This is a bit wasteful the first time around, but shouldn't be too bad overall
                            local _, _, _, def_weapon = wesnoth.simulate_combat(attacker_copy, i_a, defender_proxy, i_d)

                            local total_damage_defense = fred_attack_utils.get_total_damage_attack(def_weapon, def, false, attacker_info)

                            if (total_damage_defense > max_def_damage) then
                                max_def_damage = total_damage_defense
                                def_weapon_i = i_d
                            end

                            --std_print('    i_d:', i_d, total_damage_defense)
                        end
                    end
                end
            end
            --std_print('  --> best att/def:', att_weapon_i, max_att_damage, def_weapon_i, max_def_damage)

            if (not attacks_cache.best_weapons) then
                attacks_cache.best_weapons = {}
            end
            if (not attacks_cache.best_weapons[attacker_info.id]) then
                attacks_cache.best_weapons[attacker_info.id] = {}
            end

            attacks_cache.best_weapons[attacker_info.id][defender_info.id] = {
                att_weapon_i = att_weapon_i,
                def_weapon_i = def_weapon_i
            }

        else
            att_weapon_i = attacks_cache.best_weapons[attacker_info.id][defender_info.id].att_weapon_i
            def_weapon_i = attacks_cache.best_weapons[attacker_info.id][defender_info.id].def_weapon_i
            --std_print(' Reusing weapons: ', cache_att_id, defender_info.id, att_weapon_i, def_weapon_i)
        end

        tmp_att_stat, tmp_def_stat, att_weapon = wesnoth.simulate_combat(attacker_copy, att_weapon_i, defender_proxy, def_weapon_i)
    else
        -- Disable for now
        -- TODO: remove or reenable
        --tmp_att_stat, tmp_def_stat, att_weapon = wesnoth.simulate_combat(attacker_copy, defender_proxy)
    end

    if (not att_weapon_i) then
        att_weapon_i = att_weapon.attack_num + 1
    end
    --std_print(att_weapon_i)

    attacker_copy.x, attacker_copy.y = old_x, old_y


    local att_outcome = fred_attack_utils.attstat_to_outcome(attacker_info, tmp_att_stat, tmp_def_stat.hp_chance[0], defender_info.level)
    local def_outcome = fred_attack_utils.attstat_to_outcome(defender_info, tmp_def_stat, tmp_att_stat.hp_chance[0], attacker_info.level)


    if (not attacks_cache[cache_att_id]) then
        attacks_cache[cache_att_id] = {}
    end
    if (not attacks_cache[cache_att_id][cache_def_id]) then
        attacks_cache[cache_att_id][cache_def_id] = {}
    end
    if (not attacks_cache[cache_att_id][cache_def_id][attacker_defense]) then
        attacks_cache[cache_att_id][cache_def_id][attacker_defense] = {}
    end
    if (not attacks_cache[cache_att_id][cache_def_id][attacker_defense][defender_defense]) then
        attacks_cache[cache_att_id][cache_def_id][attacker_defense][defender_defense] = {}
    end
    if (not attacks_cache[cache_att_id][cache_def_id][attacker_defense][defender_defense][attacker_info.hitpoints]) then
        attacks_cache[cache_att_id][cache_def_id][attacker_defense][defender_defense][attacker_info.hitpoints] = {}
    end

    attacks_cache[cache_att_id][cache_def_id][attacker_defense][defender_defense][attacker_info.hitpoints][defender_info.hitpoints]
        = { att_outcome = att_outcome, def_outcome = def_outcome, att_weapon_i = att_weapon_i }

    return att_outcome, def_outcome, att_weapon_i
end

function fred_attack_utils.attack_combo_eval(combo, defender, cfg, fred_data)
    -- Evaluate attack combination outcomes using
    -- @combo: attack combo table in the format returned by fred_attack_utils.get_attack_combos()
    -- @defender: table describing the defender in form { id = loc }
    -- @cfg: configuration parameters to be passed through to attack_rating
    --
    -- Return value: table containing the following fields (or nil if no acceptable attacks are found)
    --   - att_outcomes: an array of outcomes for each attacker, in the order found for the "best attack",
    --       which is generally different from the order of @tmp_attacker_copies
    --   - def_outcome: one set of outcomes containing the defender outcome after the attack combination
    --       However, compared to the single-attacker def_outcome, this has an added table 'ctd_progression',
    --       which contains the chance to die in each of the attacks
    --   - rating_table: rating for this attack combination calculated from fred_attack_utils.attack_rating() results
    --   - attacker_damages, defender_damage: damage table for all attackers, and the combined damage for the defender

    local move_data = fred_data.move_data
    local attacks_cache = fred_data.caches.attacks

    ----- Begin combine_outcomes() -----
    local function combine_outcomes(hp1, chance1, att_outcome, def_outcome, att_combo_table, def_combo_table, def_combo_table_base, def_poisoned, def_slowed, old_def_poisoned, old_def_slowed)
        -- This function combines the outcomes for an attacker/defender pair that is
        -- not first in an attack combination with the statistics of the previous
        -- attacks. This gets called by both the "normal" and the level-up part of
        -- the combo evaluation code and is almost identical for the two versions.
        -- That plus the fact that it is a b-t complex are the reason why this is
        -- put into a function.

        -- Attacker outcome
        for hp2,chance2 in pairs(att_outcome.hp_chance) do
            att_combo_table.hp_chance[hp2] = (att_combo_table.hp_chance[hp2] or 0) + chance1 * chance2
        end
        if (att_outcome.levelup_chance > 0) then
            for hp2,chance2 in pairs(att_outcome.levelup.hp_chance) do
                att_combo_table.levelup.hp_chance[hp2] = (att_combo_table.levelup.hp_chance[hp2] or 0) + chance1 * chance2
            end
        end
        att_combo_table.poisoned = att_combo_table.poisoned + chance1 * att_outcome.poisoned
        att_combo_table.slowed = att_combo_table.slowed + chance1 * att_outcome.slowed

        -- Defender outcome
        for hp2,chance2 in pairs(def_outcome.hp_chance) do
            def_combo_table.hp_chance[hp2] = (def_combo_table.hp_chance[hp2] or 0) + chance1 * chance2

            -- HP=0 does not count as poisoned/slowed
            if (hp2 ~= 0) then
                -- If HP did not change (no hit made), the poison/slow chance carries through as it was
                -- We also include an increase in HP here, to account approximately for drain
                if (hp2 >= hp1) then
                    def_poisoned[hp2] = (def_poisoned[hp2] or 0) + (old_def_poisoned[hp2] or 0) * chance2
                    def_slowed[hp2] = (def_slowed[hp2] or 0) + (old_def_slowed[hp2] or 0) * chance2
                -- Otherwise, if a hit was made:
                else
                    -- If the attacker is a poisoner, the defender is poisoned for this case
                    if (def_outcome.poisoned > 0) then
                        def_poisoned[hp2] = (def_poisoned[hp2] or 0) + chance1 * chance2
                    -- If the attacker is not a poisoner, the previous poison chance carries through
                    else
                        def_poisoned[hp2] = (def_poisoned[hp2] or 0) + (old_def_poisoned[hp1] or 0) * chance2
                    end
                    -- If the attacker slows, the defender is slowed for this case
                    if (def_outcome.slowed > 0) then
                        def_slowed[hp2] = (def_slowed[hp2] or 0) + chance1 * chance2
                    -- If the attacker does not slow, the previous slow chance carries through
                    else
                        def_slowed[hp2] = (def_slowed[hp2] or 0) + (old_def_slowed[hp1] or 0) * chance2
                    end
                end
            end
        end

        -- Note: we put the following into the levelup table both for the base table and
        -- for the levelup table. A second levelup during the same attack combo is rather
        -- unlikely, so this is an acceptable approximation.
        if (def_outcome.levelup_chance > 0) then
            for hp2,chance2 in pairs(def_outcome.levelup.hp_chance) do
                def_combo_table_base.levelup.hp_chance[hp2] = (def_combo_table_base.levelup.hp_chance[hp2] or 0) + chance1 * chance2
            end

            -- Also, it is possible that no type/max_hp are set in the levelup table,
            -- if this is an attack combo with >2 units
            if (not def_combo_table_base.levelup.type) then
                def_combo_table_base.levelup.type = def_outcome.levelup.type
                def_combo_table_base.levelup.max_hp = def_outcome.levelup.max_hp
            end
        end
    end
    ----- End combine_outcomes() -----


    local tmp_attacker_copies, tmp_attacker_infos, tmp_dsts = {}, {}, {}
    for src,dst in pairs(combo) do
        local src_x, src_y = math.floor(src / 1000), src % 1000
        attacker_id = FGM.get_value(move_data.unit_map, src_x, src_y, 'id')
        --std_print(src_x, src_y, attacker_id)
        table.insert(tmp_attacker_infos, move_data.unit_infos[attacker_id])
        table.insert(tmp_attacker_copies, move_data.unit_copies[attacker_id])

        table.insert(tmp_dsts, { math.floor(dst / 1000), dst % 1000 } )
    end
    --DBG.dbms(tmp_dsts, false, 'tmp_dsts')
    --DBG.dbms(tmp_attacker_infos, false, 'tmp_attacker_infos')

    local defender_id, defender_loc = next(defender)
    local defender_proxy = COMP.get_unit(defender_loc[1], defender_loc[2])
    local defender_info = move_data.unit_infos[defender_id]
    --DBG.dbms(defender_info, false, 'defender_info')

    -- We first simulate and rate the individual attacks
    local ratings, tmp_att_outcomes, tmp_def_outcomes, tmp_att_weapons_i = {}, {}, {}, {}
    for i,attacker_copy in ipairs(tmp_attacker_copies) do
        tmp_att_outcomes[i], tmp_def_outcomes[i], tmp_att_weapons_i[i] =
            fred_attack_utils.attack_outcome(
                attacker_copy, defender_proxy, tmp_dsts[i],
                tmp_attacker_infos[i], defender_info,
                fred_data
            )

        local rating_table =
            fred_attack_utils.attack_rating(
                { tmp_attacker_infos[i] }, defender_info, { tmp_dsts[i] },
                { tmp_att_outcomes[i] }, tmp_def_outcomes[i], cfg, fred_data
            )

        --std_print(attacker_copy.id .. ' --> ' .. defender_info.id)
        --std_print('  CTD att, def:', tmp_att_outcomes[i].hp_chance[0], tmp_def_outcomes[i].hp_chance[0])
        --DBG.dbms(rating_table, false, 'rating_table')

        -- Need the 'i' here in order to specify the order of attackers, dsts below
        table.insert(ratings, { i, rating_table })
    end

    -- Sort all the arrays based on this rating
    -- This will give the order in which the individual attacks are executed
    -- That's an approximation of the best order, everything else is too expensive
    -- TODO: reconsider whether total rating is what we want here
    -- TODO: find a better way of ordering the attacks?
    table.sort(ratings, function(a, b) return a[2].rating > b[2].rating end)

    -- Reorder attackers, dsts in this order
    local attacker_copies, attacker_infos, att_weapons_i, dsts = {}, {}, {}, {}
    for i,rating in ipairs(ratings) do
        attacker_copies[i] = tmp_attacker_copies[rating[1]]
        dsts[i] = tmp_dsts[rating[1]]
        attacker_infos[i] = tmp_attacker_infos[rating[1]]
        att_weapons_i[i] = tmp_att_weapons_i[rating[1]]
    end

    -- Return nil when no units left
    -- TOOD: after removing ctd_limit, this should not happen any more. Verify and remove.
    if (#attacker_copies == 0) then return end

    -- Only keep the outcomes/ratings for the first attacker, the rest needs to be recalculated
    local att_outcomes, def_outcomes, rating_progression = {}, {}, {}
    att_outcomes[1], def_outcomes[1] = tmp_att_outcomes[ratings[1][1]], tmp_def_outcomes[ratings[1][1]]
    rating_progression[1] = ratings[1][2].rating

    tmp_att_outcomes, tmp_def_outcomes, ratings = nil, nil, nil

    -- TODO: For now, we just increase the defender experience by the level of the attacker,
    -- both here and in the loop below. This works when there is no chance to level up, and
    -- when the unit levels up during the current attack. It is inaccurate when, for example,
    -- the defender is 9 HP from leveling, and in the first attack against an L1 unit there
    -- is a non-zero and non-unity chance to kill the attacker. In that case, the defender
    -- might end up with +1 or +8 XP, in some cases even for the same final HP. This would
    -- then cause very different outcomes for the next attack(s). However, doing this
    -- correctly is prohibitively expensive, so we go with this approximation for now.

    local defender_xp = defender_info.experience
    defender_xp = defender_xp + attacker_infos[1].level

    -- Poison/slow need to be dealt with differently for the defender
    local def_poisoned = { base = {}, levelup = {} }
    if (def_outcomes[1].poisoned > 0) then
        for hp,chance in pairs(def_outcomes[1].hp_chance) do
            -- TODO: this will not always work 100% correctly with drain; others?
            if (hp < defender_info.hitpoints) and (hp ~= 0) then
                def_poisoned.base[hp] = (def_poisoned.base[hp] or 0) + chance
            end
        end
    end

    local def_slowed = { base = {}, levelup = {} }
    if (def_outcomes[1].slowed > 0) then
        for hp,chance in pairs(def_outcomes[1].hp_chance) do
            -- TODO: this will not always work 100% correctly with drain; others?
            -- Same for the follow-up attacks below
            if (hp < defender_info.hitpoints) and (hp ~= 0) then
                def_slowed.base[hp] = (def_slowed.base[hp] or 0) + chance
            end
        end
    end


    -- Then we go through all the other attacks and calculate the outcomes
    -- based on all the possible outcomes of the previous attacks
    for i = 2,#attacker_infos do
        att_outcomes[i] = init_attack_outcome()
        -- Levelup chance carries through from previous
        def_outcomes[i] = init_attack_outcome()
        def_outcomes[i].levelup_chance = def_outcomes[i-1].levelup_chance
        def_outcomes[i].levelup.max_hp = def_outcomes[i-1].levelup.max_hp
        def_outcomes[i].levelup.type = def_outcomes[i-1].levelup.type

        local old_def_poisoned = def_poisoned
        def_poisoned = { base = {}, levelup = {} }
        local old_def_slowed = def_slowed
        def_slowed = { base = {}, levelup = {} }

        -- The HP distribution without leveling
        for hp1,chance1 in pairs(def_outcomes[i-1].hp_chance) do -- Note: need pairs(), not ipairs() !!
            --std_print('  not leveled: ', hp1,chance1)
            if (hp1 == 0) then
                att_outcomes[i].hp_chance[attacker_infos[i].hitpoints] =
                    (att_outcomes[i].hp_chance[attacker_infos[i].hitpoints] or 0) + chance1
                def_outcomes[i].hp_chance[0] = (def_outcomes[i].hp_chance[0] or 0) + chance1
            else
                local org_hp = defender_info.hitpoints
                defender_proxy.hitpoints = hp1  -- Yes, we need both here. It speeds up other parts.
                defender_info.hitpoints = hp1

                local org_xp = defender_info.experience
                defender_proxy.experience = defender_xp
                defender_info.experience = defender_xp

                local aoc, doc = fred_attack_utils.attack_outcome(
                    attacker_copies[i], defender_proxy, dsts[i],
                    attacker_infos[i], defender_info,
                    fred_data
                )

                defender_proxy.hitpoints = org_hp
                defender_info.hitpoints = org_hp
                defender_proxy.experience = org_xp
                defender_info.experience = org_xp

                combine_outcomes(
                    hp1, chance1,
                    aoc, doc, att_outcomes[i], def_outcomes[i], def_outcomes[i],
                    def_poisoned.base, def_slowed.base, old_def_poisoned.base, old_def_slowed.base
                )
            end
        end

        -- This could be done to reduce the size of the hp_chance table, and thus the
        -- calculation time for multi-attacker combat. However, tests show that this
        -- really only makes a difference in rare-ish cases, and it has the disadvantage
        -- that hp_chances don't add up to 1 any more then (they could be re-normalized,
        -- of course). So, commenting this out for now, but leaving it for future reference.
        --DBG.dbms(def_outcomes[i].hp_chance)
        --for hp,chance in pairs(def_outcomes[i].hp_chance) do
        --    if (chance < 0.001) and (hp ~= defender_info.hitpoints) and (hp ~= 0) then
        --        def_outcomes[i].hp_chance[hp] = nil
        --    end
        --end


        -- The HP distribution after leveling
        if (def_outcomes[i-1].levelup_chance > 0) then
            for hp1,chance1 in pairs(def_outcomes[i-1].levelup.hp_chance) do -- Note: need pairs(), not ipairs() !!
                --std_print('  leveled: ', defender_info.id, defender_loc[1] .. ',' .. defender_loc[2], hp1, chance1)

                if (hp1 == 0) then
                    -- levelup.hp_chance should never contain a HP=0 entry, as those are
                    -- put directely into hp_chance at the top level
                    std_print('***** error: HP = 0 in levelup outcomes entcountered *****')
                else
                    -- This is not as efficient for accessing the tables as the method used
                    -- for caching normal outcomes, but it is more convenient and is needed
                    -- much less often, so this is good enough for now.
                    local def_str = string.format('%s-%d-%d-%d', defender_info.id, defender_loc[1], defender_loc[2], hp1)
                    local att_str = string.format('%s-%d-%d-%d', attacker_infos[i].id, dsts[i][1], dsts[i][2], attacker_infos[i].hitpoints)
                    --std_print(def_str, att_str)

                    local lu_outcomes = attacks_cache.levelup
                        and attacks_cache.levelup[def_str]
                        and attacks_cache.levelup[def_str][att_str]
                    if (not lu_outcomes) then
                        -- We create an entirely new unit in this case, replacing the
                        -- original defender_proxy by one of the correct advanced type
                        COMP.extract_unit(defender_proxy)

                        -- Setting XP to 0, as it is extremely unlikely that a
                        -- defender will level twice in a single attack combo
                        COMP.put_unit({
                            id = 'adv_' .. defender_info.id,  -- To distinguish from defender for caching
                            side = defender_info.side,
                            hitpoints = hp1,
                            type = def_outcomes[i-1].levelup.type,
                            random_traits = false,  -- The rest is needed to avoid OOS errors
                            name = "X",
                            random_gender = false
                        }, defender_loc[1], defender_loc[2])
                        local adv_defender_proxy = COMP.get_unit(defender_loc[1], defender_loc[2])
                        local adv_defender_info = FU.single_unit_info(adv_defender_proxy, fred_data.caches.unit_types)

                        local aoc, doc = fred_attack_utils.attack_outcome(
                            attacker_copies[i], adv_defender_proxy, dsts[i],
                            attacker_infos[i], adv_defender_info,
                            fred_data
                        )

                        COMP.erase_unit(defender_loc[1], defender_loc[2])
                        COMP.put_unit(defender_proxy)

                        lu_outcomes = { aoc = aoc, doc = doc}

                        if (not attacks_cache.levelup) then
                            attacks_cache.levelup = {}
                        end
                        if (not attacks_cache.levelup[def_str]) then
                            attacks_cache.levelup[def_str] = {}
                        end
                        if (not attacks_cache.levelup[def_str][att_str]) then
                            attacks_cache.levelup[def_str][att_str] = lu_outcomes
                        end
                    end

                    -- Attacker outcomes are the same as for the not leveled-up case, since an attacker
                    -- only does one fight -> everything goes into its base-level rating table
                    -- By contrast, everything for the defender gets added to the leveled-up table
                    -- except for the HP=0 case, which always goes into the base hp_chance directly.
                    combine_outcomes(
                        hp1, chance1,
                        lu_outcomes.aoc, lu_outcomes.doc, att_outcomes[i], def_outcomes[i].levelup, def_outcomes[i],
                        def_poisoned.levelup, def_slowed.levelup, old_def_poisoned.levelup, old_def_slowed.levelup
                    )
                    if def_outcomes[i].levelup.hp_chance[0] then
                        def_outcomes[i].hp_chance[0] = def_outcomes[i].hp_chance[0] + def_outcomes[i].levelup.hp_chance[0]
                        def_outcomes[i].levelup.hp_chance[0] = nil
                    end
                end
            end
        end


        ----- Begin sum_status() -----
        local function sum_status(status, def_status_table)
            def_outcomes[i][status] = 0
            for hp,chance in pairs(def_status_table.base) do
                def_outcomes[i][status] = def_outcomes[i][status] + chance
            end
            for hp,chance in pairs(def_status_table.levelup) do
                def_outcomes[i][status] = def_outcomes[i][status] + chance
                def_outcomes[i].levelup[status] = def_outcomes[i].levelup[status] + chance
            end
        end
        ----- End sum_status() -----


        -- Poison/slow chances for the defender need to be calculated now.  As for other
        -- parameters, the base table contains both the level-up and the base chance.
        sum_status('poisoned', def_poisoned)
        sum_status('slowed', def_slowed)

        calc_stats_attack_outcome(att_outcomes[i])
        calc_stats_attack_outcome(def_outcomes[i])

        -- We also add the progression of the chance to die through
        -- the attacks. this is needed for the plague rating.
        def_outcomes[i].ctd_progression = {}
        for j = 1,i do
            def_outcomes[i].ctd_progression[j] = def_outcomes[j].hp_chance[0]
        end


        -- Also add to the defender XP. Leveling up does not need to be considered
        -- here, as it is caught separately by the levelup_chance field in def_outcome
        defender_xp = defender_xp + attacker_infos[i].level

        local tmp_ai, tmp_dsts, tmp_as = {}, {}, {}
        for j = 1,i do
            tmp_ai[j] = attacker_infos[j]
            tmp_dsts[j] = dsts[j]
            tmp_as[j] = att_outcomes[j]
        end

        local rating_table = fred_attack_utils.attack_rating(
            tmp_ai, defender_info, tmp_dsts,
            tmp_as, def_outcomes[i], cfg, fred_data
        )
        rating_progression[i] = rating_table.rating
    end


    local rating_table, attacker_damages, defender_damage =
        fred_attack_utils.attack_rating(
            attacker_infos, defender_info, dsts,
            att_outcomes, def_outcomes[#attacker_infos], cfg, fred_data
        )

    rating_table.progression = rating_progression

    local weighted_progression, max_weighted_rating = {}, - math.huge
    for i,rating in ipairs(rating_progression) do
        local d_rating = rating - (rating_progression[i-1] or 0)
        local att_ctd = attacker_damages[i].die_chance
        local weight = 1 - FU.weight_s(att_ctd, 0.5)
        --std_print(i, rating, d_rating, att_ctd, weight)

        weighted_progression[i] = (weighted_progression[i-1] or 0) + d_rating * weight

        if (weighted_progression[i] > max_weighted_rating) then
            max_weighted_rating = weighted_progression[i]
        end
    end

    rating_table.weighted_progression = weighted_progression
    rating_table.max_weighted_rating = max_weighted_rating

    local combo_outcome = {
        att_outcomes = att_outcomes,
        def_outcome = def_outcomes[#attacker_infos],
        att_weapons_i = att_weapons_i,
        rating_table = rating_table,
        attacker_damages = attacker_damages,
        defender_damage = defender_damage,
        dsts = dsts
    }

    return combo_outcome
end

function fred_attack_utils.get_attack_combos(attackers, defender, cfg, reach_maps, get_strongest_attack, fred_data)
    -- Get all attack combinations of @attackers on @defender
    -- OR: get what is considered the strongest of those attacks (approximately)
    -- The former is in order to get all attack combos (but order of individual attacks doesn't matter),
    -- the latter is for a quick-and-dirty search for, for example, the strongest counter attack,
    -- when a full attack combination evaluation is too expensive. The strongest attack is defined
    -- here as the one which has the maximum sum of damage done to the defender
    --
    -- Required inputs:
    -- @attackers: array of attacker ids and locations: { id1 = { x1 , y1 }, id2 = ... }
    -- @defender: defender id and location: { id = { x, y } }
    --  @cfg: configuration parameters to be passed through to attack_rating
    --
    -- Optional inputs:
    -- @reach_maps: reach_maps for the attackers
    --   - This is _much_ faster if reach_maps is given; should be done for all attack combos for the side
    --     Only when the result depends on a hypothetical map situation (such as for counter attacks) should
    --     it be calculated here. If reach_maps are not given, @move_data must be provided
    --   - Even if @reach_maps is no given, move_data still needs  to contain the "original" reach_maps for the attackers.
    --     This is used to speed up the calculation. If the attacker (enemy) cannot get to a hex originally
    --     (remember that this is done with AI units with MP taken off the map), then it can also
    --     not get there after moving AI units into place.
    --   - Important: for units on the AI side, reach_maps must NOT included hexes with units that
    --     cannot move out of the way
    -- @get_strongest_attack (boolean): if set to 'true', don't return all attacks, but only the
    --   one deemed strongest as described above. If this is set, @fred_data must be provided
    --
    -- Return value:
    --   - attack combinations (either a single one or an array) of form { src = dst }, e.g.:
    --     {
    --         [21007] = 19006,
    --         [19003] = 19007
    --     }
    --   - all_attackers: all enemies which can attack the defender; these might be more units
    --     than what are used in any combo, depending on available hexes

    local move_data = fred_data.move_data

    local defender_id, defender_loc = next(defender)

    -- If reach_maps is not given, we need to calculate them
    if (not reach_maps) then
        reach_maps = FVS.virtual_reach_maps(attackers, { defender_loc }, nil, move_data)
    end

    ----- First, find which units in @attackers can get to hexes next to @defender -----

    local defender_proxy  -- If attack rating is needed, we need the defender proxy unit, not just the unit copy
    if get_strongest_attack then
        defender_proxy = COMP.get_unit(defender_loc[1], defender_loc[2])
    end

    local tmp_attacks_dst_src = {}

    local all_attackers = {}
    for xa,ya in H.adjacent_tiles(defender_loc[1], defender_loc[2]) do
        local dst = xa * 1000 + ya

        for attacker_id,attacker_loc in pairs(attackers) do
            if FGM.get_value(reach_maps[attacker_id], xa, ya, 'moves_left') then
                all_attackers[attacker_id] = true
                local _, rating
                if get_strongest_attack then
                    local att_outcome, def_outcome = fred_attack_utils.attack_outcome(
                        move_data.unit_copies[attacker_id], defender_proxy, { xa, ya },
                        move_data.unit_infos[attacker_id], move_data.unit_infos[defender_id],
                        fred_data
                    )

                    local rating_table = fred_attack_utils.attack_rating(
                        { move_data.unit_infos[attacker_id] }, move_data.unit_infos[defender_id], { { xa, ya } },
                        { att_outcome }, def_outcome,
                        cfg, fred_data
                    )

                    -- It's okay to use the full rating here, rather than just damage_rating
                    rating = rating_table.rating
                    --std_print(xa, ya, attacker_id, rating, rating_table.attacker_rating, rating_table.defender_rating, rating_table.extra_rating)
                end

                if (not tmp_attacks_dst_src[dst]) then
                    tmp_attacks_dst_src[dst] = {
                        { src = attacker_loc[1] * 1000 + attacker_loc[2], rating = rating },
                        dst = dst
                    }
                else
                    table.insert(tmp_attacks_dst_src[dst], { src = attacker_loc[1] * 1000 + attacker_loc[2], rating = rating })
                end
            end
        end
    end

    -- If no attacks are found, return empty table
    if (not next(tmp_attacks_dst_src)) then return {} end

    -- Because of the way how get_unit_hex_combos works, we want this to
    -- be an array, not a table with dsts as keys
    local attacks_dst_src = {}
    for _,dst in pairs(tmp_attacks_dst_src) do
        table.insert(attacks_dst_src, dst)
    end

    return FU.get_unit_hex_combos(attacks_dst_src, get_strongest_attack), all_attackers
end

function fred_attack_utils.calc_counter_attack(target, old_locs, new_locs, additional_units, virtual_reach_maps, cfg, fred_data)
    -- Get counter-attack outcomes of an AI unit in a hypothetical map situation
    -- Units are placed on the map and the move_data tables are adjusted inside this
    -- function in order to avoid code duplication and ensure consistency
    --
    -- Conditions that need to be met before calling this function (otherwise it won't work):
    --  - @target is a unit of the current side's AI
    --  - AI units with MP are taken off the map
    --  - AI units without MP are still on the map
    --  - All enemy units are on the map
    --
    -- INPUTS:
    -- @target: id and location of the unit for which to calculated the counter attack outcomes; syntax: { id = { x, y } }
    --          in other words, the location needs to be the new location of the unit
    -- @old_locs, @new_locs: arrays of locations of the current and goal locations
    --   of all AI units to be moved into different positions, such as all units
    --   involved in an attack combination
    --   If @old_locs and/or @new_locs is nil, the placing of units is skipped and it is assumed that this
    --   has already been done, e.g. by the virtual_state functions
    --  @additional_units: optional table for placing other units on the map, such as prerecruits
    --    calc_counter_attack() checks whether these units interfere with any of the @new_locs and does
    --    not place them if so, but it is assumed that interference with e.g. units_noMP
    --    has been checked.
    --  @virtual_reach_maps: allow passing a different reach_maps table. This saves time if counter
    --    attacks are calculated on several units for the same virtual situation, or if the
    --    reach maps are needed for other evaluations as well.
    --  @cfg: configuration parameters to be passed through to attack_rating

    local move_data = fred_data.move_data

    if old_locs or new_locs then
        FVS.set_virtual_state(old_locs, new_locs, additional_units, false, move_data)
    end

    local target_id, target_loc = next(target)

    -- The unit being attacked is included here and might have HP=0. Need to
    -- use only valid units.
    local attackers = {}
    for id,loc in pairs(move_data.enemies) do
        if (move_data.unit_infos[id].hitpoints > 0) then
            attackers[id] = loc
        end
    end

    -- If this is side 2, we set up a time area with the time of the next turn,
    -- as that is when the counter attack will happen.
    -- Note: nothing special needs to be done about caching, because the cache index
    -- contains the attacker and defender in order, with AI vs. enemy always
    -- happening during the AI turn, and enemy vs. AI always on the enemy turn.
    if (wesnoth.current.side == 2) then
        local next_turn_schedule = wesnoth.get_time_of_day(wesnoth.current.turn + 1)
        -- Setting a large time area is expensive -> use only for small radius around target
        -- Use radius = 2 to include potential healers or leadership; tested that that takes
        -- barely any more time than radius = 1.
        local time_area = {
            id = 'next_turn',
            x = target_loc[1],
            y = target_loc[2],
            radius = 2,
            { "time", next_turn_schedule }
        }
        wesnoth.add_time_area(time_area)
    end

    -- reach_maps must not be given here, as this is for a hypothetical situation
    -- on the map. Needs to be recalculated for that situation.
    -- Only want the best attack combo for this.
    local counter_attack, all_attackers = fred_attack_utils.get_attack_combos(
        attackers, target, cfg,
        virtual_reach_maps, true, fred_data
    )

    if (wesnoth.current.side == 2) then
        wesnoth.remove_time_area('next_turn')
    end

    local counter_attack_outcome
    if (next(counter_attack)) then
        -- Otherwise calculate the attack combo outcome
        local enemy_map = {}
        for id,loc in pairs(move_data.enemies) do
            enemy_map[loc[1] * 1000 + loc[2]] = id
        end

        counter_attack_outcome = fred_attack_utils.attack_combo_eval(counter_attack, target, cfg, fred_data)
    end

    if old_locs or new_locs then
        FVS.reset_state(old_locs, new_locs, false, move_data)
    end

    return counter_attack_outcome, counter_attack, all_attackers
end

function fred_attack_utils.get_disqualified_attack(combo)
    -- Set up a sub-table from @combo in the format needed by
    -- add_disqualified_attack() below
    local att_table = {}

    -- This add all attackers in the combo to the sub-table
    -- Note that these keys are different from the key identifying the sub-table as a whole
    for i_a,attacker_damage in ipairs(combo.attacker_damages) do
        local id, x, y = attacker_damage.id, combo.dsts[i_a][1], combo.dsts[i_a][2]
        local key = x * 1000 + y -- only position for this, no id
        att_table[key] = true
    end

    return att_table
end

function fred_attack_utils.is_disqualified_attack(combo, disqualified_attacks_this_key)
    -- Check whether a @combo has previously been identified as disqualified
    -- already in @disqualified_attacks_this_key
    --
    -- @disqualified_attacks_this_key: is only the table for this unit at this
    -- hex, not the entire disqualified_attacks table
    --
    -- Returns:
    --   true: if previously identified
    --   false, att_table: if this is new; here, att_table is the table to
    --      be inserted into disqualified_attacks_this_key; this is returned
    --      in order to avoid code duplication below

    -- The attack table for the new attack
    local att_table = fred_attack_utils.get_disqualified_attack(combo)

    -- Go through all the existing attack tables
    for _,disatt in ipairs(disqualified_attacks_this_key) do
        local exists_already = true

        -- Find whether there is an element in the new table that does not already
        -- exist in an old one
        for k,_ in pairs(att_table) do
            if (not disatt[k]) then
                exists_already = false
                break
            end
        end

        -- If we got to here with exists_already still set, that means that we
        -- found an existing attack that includes the new one -> return true
        if exists_already then
            return true
        end
    end

    -- If we got here, this means no existing combo was found
    return false, att_table
end

function fred_attack_utils.add_disqualified_attack(combo, i_a, disqualified_attacks)
    -- Add an attack combo to a table of disqualified attacks.  The array structure
    -- is as follows:
    --  {
    --      Orcish Grunt-14627016 = {
    --          [1] = {
    --                      [27016] = true
    --                },
    --          [2] = {
    --                      [27016] = true,
    --                      [28015] = true
    --                 }
    --      },
    --      Orcish Assassin-34817013 = {
    --          [1] = {
    --                      [17013] = true
    --          }
    --      }
    --  }
    --
    -- In other words, an attack is disqualified, if the counter attack on the
    -- unit described by the key (incl. its location) was found to be unacceptable.
    -- For that case, we save the locations of all units in the attack combination,
    -- as that has an effect on the possible counter attacks. Other attacks using
    -- that same combination, or a subset thereof, will expose the unit to the
    -- same counter attack
    -- TODO: this breaks down to some extent if
    --   1. the forward attack is stronger for follow-up attack,
    --   2. there are L0 units involved.
    --
    -- @combo: an array of the attack combo as used in get_attack_combos()
    -- @i_a: the number of the attacker in the combo that was disqualified
    -- @disqualified_attacks: the table in which disq. attacks are stored

    local id, x, y = combo.attacker_damages[i_a].id, combo.dsts[i_a][1], combo.dsts[i_a][2]
    local key = id .. (x * 1000 + y)

    local exists_already, tmp = false
    if not disqualified_attacks[key] then
        disqualified_attacks[key] = {}
        tmp = fred_attack_utils.get_disqualified_attack(combo)
    else
        exists_already, tmp = fred_attack_utils.is_disqualified_attack(combo, disqualified_attacks[key])
    end

    if (not exists_already) then
        table.insert(disqualified_attacks[key], tmp)
    end
end

return fred_attack_utils
