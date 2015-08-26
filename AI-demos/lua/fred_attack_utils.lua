local H = wesnoth.require "lua/helper.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local FGUI = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_utils_incremental.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

-- Functions to perform fast evaluation of attacks and attack combinations.
-- The emphasis with all of this is on speed, not elegance.
-- This might result in redundant information being produced/passed and similar
-- or the format of cache tables being somewhat tedious, etc.
-- Note to self: working with Lua tables is generally much faster than with unit proxy tables.
-- Also, creating tables takes time, indexing by number is faster than by string, etc.

local fred_attack_utils = {}

function fred_attack_utils.is_acceptable_attack(damage_to_ai, damage_to_enemy, value_ratio)
    -- Evaluate whether an attack is acceptable, based on the damage to_enemy/to_ai ratio
    -- As an example, if value_ratio = 0.5 -> it is okay to do only half the damage
    -- to the enemy as is received. In other words, value own units only half of
    -- enemy units. The smaller value_ratio, the more aggressive the AI gets.
    -- Default is 0.8, meaning the AI is slightly more aggressive than even terms.
    --
    -- Inputs:
    -- @damage_to_ai, @damage_to_enemy: should be in gold units as returned by fred_attack_utils.
    --   Note, however, that attacker_rating (but not defender_rating!) is the negative of the damage!!
    --   This could be either the attacker (for to_ai) and defender (for to_enemy) rating of a single attack (combo)
    --   or the overall attack (for to_enemy) and counter attack rating (for to_ai)
    -- @value_ratio (optional): value for the minimum ratio of damage to_enemy/to_ai that is acceptable
    --   It is generally okay for the AI to take a little more damage than it deals out,
    --   so for the most part this value should be slightly smaller than 1.

    value_ratio = value_ratio or FU.cfg_default('value_ratio')

    -- Otherwise it depends on whether the numbers are positive or negative
    -- Negative damage means that one or several of the units are likely to level up
    if (damage_to_ai < 0) and (damage_to_enemy < 0) then
        return (damage_to_ai / damage_to_enemy) >= value_ratio
    end

    if (damage_to_ai <= 0) then damage_to_ai = 0.001 end
    if (damage_to_enemy <= 0) then damage_to_enemy = 0.001 end

    return (damage_to_enemy / damage_to_ai) >= value_ratio
end

function fred_attack_utils.delayed_damage(unit_info, att_stat, hp_before, x, y, gamedata)
    -- Returns the damage the unit gets from delayed actions, both positive and negative
    --  - Positive damage: poison, slow (counting slow as damage)
    --  - Negative damage: villages, regenerate
    -- TODO: add healers, rest healing
    -- This damage is in the same units (fractional gold) as the damage rating
    --
    -- @hp_before: HP of the unit before the delayed damage is applied; this might
    --   be different from unit_info.hitpoints. It is used to cap the amount of damage, if needed.
    -- @x,@y: location of the unit for which to calculate this; this might or
    --   might not be the current location of the unit

    local delayed_damage = 0

    -- Positive delayed damage (poison etc.)

    -- Count poisoned as additional 8 HP damage times probability of being poisoned
    -- but only if the unit is not already poisoned
    -- HP=0 case counts as poisoned in the att_stats, so that needs to be subtracted
    if (att_stat.poisoned ~= 0) and (not unit_info.poisoned) then
        delayed_damage = delayed_damage + 8 * (att_stat.poisoned - att_stat.hp_chance[0])
    end

    -- Count slowed as additional 4 HP damage times probability of being slowed
    -- but only if the unit is not already slowed
    -- HP=0 case counts as slowed in the att_stats, so that needs to be subtracted
    if (att_stat.slowed ~= 0) and (not unit_info.slowed) then
        delayed_damage = delayed_damage + 4 * (att_stat.slowed - att_stat.hp_chance[0])
    end

    -- Negative delayed damage (healing)
    local is_village = gamedata.village_map[x] and gamedata.village_map[x][y]

    -- If unit is on a village, we count that as an 8 HP bonus (negative damage)
    -- multiplied by the chance to survive
    if is_village then
        delayed_damage = delayed_damage - 8 * (1 - att_stat.hp_chance[0])
    -- Otherwise only: if unit can regenerate, this is an 8 HP bonus (negative damage)
    -- multiplied by the chance to survive
    elseif unit_info.regenerate then
        delayed_damage = delayed_damage - 8 * (1 - att_stat.hp_chance[0])
    end

    -- Positive damage needs to be capped at the amount of (HP - 1) (can't lose more than that)
    delayed_damage = math.min(delayed_damage, hp_before - 1)

    -- Negative damage needs to be capped at amount by which hitpoints are below max_hitpoints
    -- Note that neg_hp_to_max is negative; delayed_damage cannot be smaller than that
    local neg_hp_to_max = hp_before - unit_info.max_hitpoints
    delayed_damage = math.max(delayed_damage, neg_hp_to_max)

    -- Convert to fraction units
    local delayed_damage_rating = delayed_damage / unit_info.max_hitpoints * unit_info.cost

    return delayed_damage_rating, delayed_damage
end

function fred_attack_utils.damage_rating_unit(attacker_info, defender_info, att_stat, def_stat, cfg)
    -- Calculate the rating for the damage received by a single attacker on a defender.
    -- The attack att_stat both for the attacker and the defender need to be precalculated for this.
    -- Unit information is passed in unit_infos format, rather than as unit proxy tables for speed reasons.
    -- Note: this is _only_ the damage rating for the attacker, not both units
    -- Note: damage is damage TO the attacker, not damage done BY the attacker
    --
    -- Input parameters:
    --  @attacker_info, @defender_info: unit_info tables produced by fred_gamestate_utils.single_unit_info()
    --  @att_stat, @def_stat: attack statistics for the two units
    --
    -- Optional parameters:
    --  @cfg: the optional different weights listed right below

    local leveling_weight = (cfg and cfg.leveling_weight) or FU.cfg_default('leveling_weight')

    local damage = attacker_info.hitpoints - att_stat.average_hp

    -- Fractional damage (= fractional value of the attacker)
    local fractional_damage = damage / attacker_info.max_hitpoints

    -- Additionally, add the chance to die, in order to (de)emphasize units that might die
    fractional_damage = fractional_damage + att_stat.hp_chance[0]

    -- In addition, potentially leveling up in this attack is a huge bonus.
    -- Note: this can make the fractional damage negative (as it should)
    local defender_level = defender_info.level
    if (defender_level == 0) then defender_level = 0.5 end  -- L0 units

    local level_bonus = 0.
    -- If missing XP is <= level of attacker, it's a guaranteed level-up as long as the unit does not die
    if (attacker_info.max_experience - attacker_info.experience <= defender_level) then
        level_bonus = 1. - att_stat.hp_chance[0]
    -- Otherwise, if a kill is needed, the bonus is the chance of the defender
    -- dying times the attacker NOT dying
    elseif (attacker_info.max_experience - attacker_info.experience <= defender_level * 8) then
        level_bonus = (1. - att_stat.hp_chance[0]) * def_stat.hp_chance[0]
    end

    fractional_damage = fractional_damage - level_bonus * leveling_weight

    -- Now convert this into gold-equivalent value
    local unit_value = FU.unit_value(attacker_info, cfg)

    local rating = fractional_damage * unit_value
    --print('damage, fractional_damage, unit_value, rating', attacker_info.id, damage, fractional_damage, unit_value, rating)

    return rating
end

function fred_attack_utils.attack_rating(attacker_infos, defender_info, dsts, att_stats, def_stat, gamedata, cfg)
    -- Returns a common (but configurable) rating for attacks of one or several attackers against one defender
    --
    -- Inputs:
    --  @attackers_infos: input array of attacker unit_info tables (must be an array even for single unit attacks)
    --  @defender_info: defender unit_info
    --  @dsts: array of attack locations in form { x, y } (must be an array even for single unit attacks)
    --  @att_stats: array of the attack stats of the attack combination(!) of the attackers
    --    (must be an array even for single unit attacks)
    --  @def_stat: the combat stats of the defender after facing the combination of the attackers
    --  @gamedata: table with the game state as produced by fred_gamestate_utils.gamedata()
    --
    -- Optional inputs:
    --  @cfg: the different weights listed right below
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

    -- Set up the config parameters for the rating
    local defender_starting_damage_weight = (cfg and cfg.defender_starting_damage_weight) or FU.cfg_default('defender_starting_damage_weight')
    local terrain_defense_weight = (cfg and cfg.terrain_defense_weight) or FU.cfg_default('terrain_defense_weight')
    local distance_leader_weight = (cfg and cfg.distance_leader_weight) or FU.cfg_default('distance_leader_weight')
    local occupied_hex_penalty = (cfg and cfg.occupied_hex_penalty) or FU.cfg_default('occupied_hex_penalty')
    local value_ratio = (cfg and cfg.value_ratio) or FU.cfg_default('value_ratio')

    local attacker_damage_rating, attacker_delayed_damage_rating, attacker_delayed_damage = 0, 0, 0
    for i,attacker_info in ipairs(attacker_infos) do
        attacker_damage_rating = attacker_damage_rating - fred_attack_utils.damage_rating_unit(
            attacker_info, defender_info, att_stats[i], def_stat, cfg
        )

        -- Add in the delayed damage
        local tmp_addr, tmp_add = fred_attack_utils.delayed_damage(attacker_info, att_stats[i], att_stats[i].average_hp, dsts[i][1], dsts[i][2], gamedata)
        attacker_delayed_damage_rating = attacker_delayed_damage_rating + tmp_addr
        attacker_delayed_damage = attacker_delayed_damage + tmp_add
    end

    -- Delayed damage for the attacker is a negative rating
    local attacker_rating = attacker_damage_rating - attacker_delayed_damage_rating

    -- attacker_info is passed only to figure out whether the attacker might level up
    -- TODO: This is only works for the first attacker in a combo at the moment
    local defender_x, defender_y = gamedata.units[defender_info.id][1], gamedata.units[defender_info.id][2]
    local defender_damage_rating = fred_attack_utils.damage_rating_unit(
        defender_info, attacker_infos[1], def_stat, att_stats[1], cfg
    )

    -- Add in the delayed damage
    local defender_delayed_damage_rating, defender_delayed_damage = fred_attack_utils.delayed_damage(defender_info, def_stat, def_stat.average_hp, defender_x, defender_y, gamedata)

    -- Delayed damage for the defender is a positive rating
    local defender_rating = defender_damage_rating + defender_delayed_damage_rating

    -- Now we add some extra ratings. They are positive for attacks that should be preferred
    -- and expressed in fraction of the defender maximum hitpoints
    -- They should be used to help decide which attack to pick all else being equal,
    -- but not for, e.g., evaluating counter attacks (which should be entirely damage based)
    local extra_rating = 0.

    -- Prefer to attack already damaged enemies
    local defender_starting_damage = defender_info.max_hitpoints - defender_info.hitpoints
    extra_rating = extra_rating + defender_starting_damage * defender_starting_damage_weight

    -- If defender is on a village, add a bonus rating (we want to get rid of those preferentially)
    -- This is in addition to the damage bonus already included above (but as an extra rating)
    local defender_on_village = gamedata.village_map[defender_x] and gamedata.village_map[defender_x][defender_y]
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
        defense_rating_attacker = defense_rating_attacker + FGUI.get_unit_defense(
            gamedata.unit_copies[attacker_info.id],
            dsts[i][1], dsts[i][2],
            gamedata.defense_maps
        )
    end
    defense_rating_attacker = defense_rating_attacker / #attacker_infos * terrain_defense_weight

    extra_rating = extra_rating + defense_rating_attacker

    -- Also, we add a small bonus for good terrain defense of the _defender_ on the _attack_ hexes
    -- This is in order to take good terrain away from defender on its next move
    local defense_rating_defender = 0.
    for _,dst in ipairs(dsts) do
        defense_rating_defender = defense_rating_defender + FGUI.get_unit_defense(
            gamedata.unit_copies[defender_info.id],
            dst[1], dst[2],
            gamedata.defense_maps
        )
    end
    defense_rating_defender = defense_rating_defender / #dsts * terrain_defense_weight

    extra_rating = extra_rating + defense_rating_defender

    -- Get a very small bonus for hexes in between defender and AI leader
    -- 'relative_distances' is larger for attack hexes closer to the side leader (possible values: -1 .. 1)
    if gamedata.leaders[attacker_infos[1].side] then
        local leader_x, leader_y = gamedata.leaders[attacker_infos[1].side][1], gamedata.leaders[attacker_infos[1].side][2]

        local rel_dist_rating = 0.
        for _,dst in ipairs(dsts) do
            local relative_distance =
                H.distance_between(defender_x, defender_y, leader_x, leader_y)
                - H.distance_between(dst[1], dst[2], leader_x, leader_y)
            rel_dist_rating = rel_dist_rating + relative_distance
        end
        rel_dist_rating = rel_dist_rating / #dsts * distance_leader_weight

        extra_rating = extra_rating + rel_dist_rating
    end

    -- Add a very small penalty for attack hexes occupied by other own units that can move out of the way
    -- Note: it must be checked previously that the unit on the hex can move away,
    --    that is we only check gamedata.my_unit_map_MP here
    for i,dst in ipairs(dsts) do
        if gamedata.my_unit_map_MP[dst[1]] and gamedata.my_unit_map_MP[dst[1]][dst[2]] then
            if (gamedata.my_unit_map_MP[dst[1]][dst[2]].id ~= attacker_infos[i].id) then
                extra_rating = extra_rating - occupied_hex_penalty
            end
        end
    end

    -- Finally add up and apply factor of own unit damage to defender unit damage
    -- This is a number equivalent to 'aggression' in the default AI (but not numerically equal)
    -- TODO: clean up this code block; for the time being, I want it to crash is something's wrong
    local attacker_weight, defender_weight
    if (attacker_infos[1].side == wesnoth.current.side) then
        attacker_weight = value_ratio
        defender_weight = 1
    end
    if (defender_info.side == wesnoth.current.side) then
        attacker_weight = 1
        defender_weight = value_ratio
    end

    local rating = defender_rating * defender_weight + attacker_rating * attacker_weight + extra_rating
    local damage_rating = defender_damage_rating * defender_weight + attacker_damage_rating * attacker_weight + extra_rating
    local delayed_damage_rating = defender_delayed_damage_rating * defender_weight + attacker_delayed_damage_rating * attacker_weight + extra_rating

    --print('rating, attacker_rating, defender_rating, extra_rating:', rating, attacker_rating, defender_rating, extra_rating)

    -- The overall ratings take the value_ratio into account, the attacker and
    -- defender tables do not
    local rating_table = {
        rating = rating,
        damage_rating = damage_rating,
        delayed_damage = delayed_damage,
        attacker = {
            rating = attacker_rating,
            damage_rating = attacker_damage_rating,
            delayed_damage = attacker_delayed_damage,
            delayed_damage_rating = attacker_delayed_damage_rating
        },
        defender = {
            rating = defender_rating,
            damage_rating = defender_damage_rating,
            delayed_damage = defender_delayed_damage,
            delayed_damage_rating = defender_delayed_damage_rating
        },
        extra = {
            rating = extra_rating
            -- TODO: add the details? Not sure if there's a use for that
        },
        value_ratio = value_ratio
    }
    --DBG.dbms(rating_table)

    return rating_table
end

function fred_attack_utils.get_total_damage_attack(weapon, attack)
    -- Get the (approximate) total damage an attack will do
    --
    -- @weapon: the weapon information as returned by wesnoth.simulate_combat()
    -- @attack: the attack information as returned by fred_attack_utils.single_unit_info()

    local total_damage = weapon.num_blows * weapon.damage

    -- Give bonus for weapon specials.  This is not exactly what those specials
    -- do in all cases, but that's okay since this is only used to determine
    -- the strongest weapons.

    -- Count poison as additional 8 HP on total damage
    if attack.poison then
        total_damage = total_damage + 8
    end

    -- Count slow as additional 4 HP on total damage
    if attack.slow then
        total_damage = total_damage + 4
    end

    return total_damage
end

function fred_attack_utils.battle_outcome(attacker_copy, defender_proxy, dst, attacker_info, defender_info, gamedata, move_cache, cfg)
    -- Calculate the stats of a combat by @attacker_copy vs. @defender_proxy at location @dst
    -- We use wesnoth.simulate_combat for this, but cache results when possible
    -- Inputs:
    -- @attacker_copy: private unit copy of the attacker (must be a copy, does not work with the proxy table)
    -- @defender_proxy: defender proxy table (must be a unit proxy table on the map, does not work with a copy)
    -- @dst: location from which the attacker will attack in form { x, y }
    -- @attacker_info, @defender_info: unit info for the two units (needed in addition to the units
    --   themselves in order to speed things up)
    --  @gamedata: table with the game state as produced by fred_gamestate_utils.gamedata()
    --  @move_cache: for caching data *for this move only*, needs to be cleared after a gamestate change
    --
    --  Optional inputs:
    -- @cfg: configuration parameters (only use_max_damage_weapons so far, possibly to be extended)

    local use_max_damage_weapons = (cfg and cfg.use_max_damage_weapons) or FU.cfg_default('use_max_damage_weapons')

    local defender_defense = FGUI.get_unit_defense(defender_proxy, defender_proxy.x, defender_proxy.y, gamedata.defense_maps)
    local attacker_defense = FGUI.get_unit_defense(attacker_copy, dst[1], dst[2], gamedata.defense_maps)

    if move_cache[attacker_info.id]
        and move_cache[attacker_info.id][defender_info.id]
        and move_cache[attacker_info.id][defender_info.id][attacker_defense]
        and move_cache[attacker_info.id][defender_info.id][attacker_defense][defender_defense]
        and move_cache[attacker_info.id][defender_info.id][attacker_defense][defender_defense][attacker_info.hitpoints]
        and move_cache[attacker_info.id][defender_info.id][attacker_defense][defender_defense][attacker_info.hitpoints][defender_info.hitpoints]
    then
        return move_cache[attacker_info.id][defender_info.id][attacker_defense][defender_defense][attacker_info.hitpoints][defender_info.hitpoints].att_stat,
            move_cache[attacker_info.id][defender_info.id][attacker_defense][defender_defense][attacker_info.hitpoints][defender_info.hitpoints].def_stat
    end

    local old_x, old_y = attacker_copy.x, attacker_copy.y
    attacker_copy.x, attacker_copy.y = dst[1], dst[2]

    local tmp_att_stat, tmp_def_stat
    local att_weapon_i, def_weapon_i = nil, nil
    if use_max_damage_weapons then
        if (not move_cache.best_weapons)
            or (not move_cache.best_weapons[attacker_info.id])
            or (not move_cache.best_weapons[attacker_info.id][defender_info.id])
        then
            if (not move_cache[attacker_info.id]) then
                move_cache[attacker_info.id] = {}
            end
            if (not move_cache[attacker_info.id][defender_info.id]) then
                move_cache[attacker_info.id][defender_info.id] = {}
            end

            --print(' Finding highest-damage weapons: ', attacker_info.id, defender_proxy.id)

            local best_att, best_def = 0, 0

            for i_a,att in ipairs(attacker_info.attacks) do
                -- This is a bit wasteful the first time around, but shouldn't be too bad overall
                local _, _, att_weapon, _ = wesnoth.simulate_combat(attacker_copy, i_a, defender_proxy)

                --print('  i_a:', i_a, total_damage_attack)
                local total_damage_attack = fred_attack_utils.get_total_damage_attack(att_weapon, att)

                if (total_damage_attack > best_att) then
                    best_att = total_damage_attack
                    att_weapon_i = i_a

                    -- Only for this attack do we need to check out the defender attacks
                    best_def, def_weapon_i = 0, nil -- need to reset these again

                    for i_d,def in ipairs(defender_info.attacks) do
                        if (att.range == def.range) then
                            -- This is a bit wasteful the first time around, but shouldn't be too bad overall
                            local _, _, _, def_weapon = wesnoth.simulate_combat(attacker_copy, i_a, defender_proxy, i_d)

                            local total_damage_defense = def_weapon.num_blows * def_weapon.damage

                            if (total_damage_defense > best_def) then
                                best_def = total_damage_defense
                                def_weapon_i = i_d
                            end

                            --print('    i_d:', i_d, total_damage_defense)
                        end
                    end
                end
            end
            --print('  --> best att/def:', att_weapon_i, best_att, def_weapon_i, best_def)

            if (not move_cache.best_weapons) then
                move_cache.best_weapons = {}
            end
            if (not move_cache.best_weapons[attacker_info.id]) then
                move_cache.best_weapons[attacker_info.id] = {}
            end

            move_cache.best_weapons[attacker_info.id][defender_info.id] = {
                att_weapon_i = att_weapon_i,
                def_weapon_i = def_weapon_i
            }

        else
            att_weapon_i = move_cache.best_weapons[attacker_info.id][defender_info.id].att_weapon_i
            def_weapon_i = move_cache.best_weapons[attacker_info.id][defender_info.id].def_weapon_i
            --print(' Reusing weapons: ', attacker_info.id, defender_proxy.id, att_weapon_i, def_weapon_i)
        end

        tmp_att_stat, tmp_def_stat = wesnoth.simulate_combat(attacker_copy, att_weapon_i, defender_proxy, def_weapon_i)
    else
        tmp_att_stat, tmp_def_stat = wesnoth.simulate_combat(attacker_copy, defender_proxy)
    end

    attacker_copy.x, attacker_copy.y = old_x, old_y

    -- Extract only those hp_chances that are non-zero (except for hp_chance[0]
    -- which is always needed). This slows down this step a little, but significantly speeds
    -- up attack combination calculations
    local att_stat = {
        hp_chance = {},
        average_hp = tmp_att_stat.average_hp,
        poisoned = tmp_att_stat.poisoned,
        slowed = tmp_att_stat.slowed
    }

    att_stat.hp_chance[0] = tmp_att_stat.hp_chance[0]
    for i = 1,#tmp_att_stat.hp_chance do
        if (tmp_att_stat.hp_chance[i] ~= 0) then
            att_stat.hp_chance[i] = tmp_att_stat.hp_chance[i]
        end
    end

    local def_stat = {
        hp_chance = {},
        average_hp = tmp_def_stat.average_hp,
        poisoned = tmp_def_stat.poisoned,
        slowed = tmp_def_stat.slowed
    }

    def_stat.hp_chance[0] = tmp_def_stat.hp_chance[0]
    for i = 1,#tmp_def_stat.hp_chance do
        if (tmp_def_stat.hp_chance[i] ~= 0) then
            def_stat.hp_chance[i] = tmp_def_stat.hp_chance[i]
        end
    end

    if (not move_cache[attacker_info.id]) then
        move_cache[attacker_info.id] = {}
    end
    if (not move_cache[attacker_info.id][defender_info.id]) then
        move_cache[attacker_info.id][defender_info.id] = {}
    end
    if (not move_cache[attacker_info.id][defender_info.id][attacker_defense]) then
        move_cache[attacker_info.id][defender_info.id][attacker_defense] = {}
    end
    if (not move_cache[attacker_info.id][defender_info.id][attacker_defense][defender_defense]) then
        move_cache[attacker_info.id][defender_info.id][attacker_defense][defender_defense] = {}
    end
    if (not move_cache[attacker_info.id][defender_info.id][attacker_defense][defender_defense][attacker_info.hitpoints]) then
        move_cache[attacker_info.id][defender_info.id][attacker_defense][defender_defense][attacker_info.hitpoints] = {}
    end

    move_cache[attacker_info.id][defender_info.id][attacker_defense][defender_defense][attacker_info.hitpoints][defender_info.hitpoints]
        = { att_stat = att_stat, def_stat = def_stat }

    return att_stat, def_stat
end

function fred_attack_utils.attack_combo_eval(tmp_attacker_copies, defender_proxy, tmp_dsts, tmp_attacker_infos, defender_info, gamedata, move_cache, cfg)
    -- Calculate attack combination outcomes using
    -- @tmp_attacker_copies: array of attacker unit copies (must be copies, does not work with the proxy table)
    -- @defender_proxy: the unit being attacked (must be a unit proxy table on the map, does not work with a copy)
    -- @tmp_dsts: array of the hexes (format { x, y }) from which the attackers attack
    --   must be in same order as @attackers
    -- @tmp_attacker_infos, @defender_info: unit info for the attackers and defenders (needed in addition to the units
    --   themselves in order to speed things up)
    -- @gamedata, @move_cache: only needed to pass to the functions being called
    --    see fred_attack_utils.battle_outcome() for descriptions
    --
    -- Optional inputs:
    --  @cfg: configuration parameters to be passed through the battle_outcome, attack_rating
    --
    -- Return values (in this order):
    --   - att_stats: an array of stats for each attacker, in the order found for the "best attack",
    --       which is generally different from the order of @tmp_attacker_copies
    --   - defender combo stats: one set of stats containing the defender stats after the attack combination
    --   - The attacker_infos and dsts arrays, sorted in order of the individual attacks
    --   - The rating for this attack combination calculated from fred_attack_utils.attack_rating() results
    --   - The (summed up) attacker and (combined) defender rating, as well as the extra rating separately

    -- We first simulate and rate the individual attacks
    local ratings, tmp_att_stats, tmp_def_stats = {}, {}, {}
    for i,attacker_copy in ipairs(tmp_attacker_copies) do
        tmp_att_stats[i], tmp_def_stats[i] =
            fred_attack_utils.battle_outcome(
                attacker_copy, defender_proxy, tmp_dsts[i],
                tmp_attacker_infos[i], defender_info,
                gamedata, move_cache, cfg
            )

        local rating_table =
            fred_attack_utils.attack_rating(
                { tmp_attacker_infos[i] }, defender_info, { tmp_dsts[i] },
                { tmp_att_stats[i] }, tmp_def_stats[i], gamedata, cfg
            )

        -- Need the i here in order to specify the order of attackers, dsts below
        ratings[i] = { i, rating_table }
    end

    -- Sort all the arrays based on this rating
    -- This will give the order in which the individual attacks are executed
    -- That's an approximation of the best order, everything else is too expensive
    -- TODO: reconsider whether total rating is what we want here
    -- TODO: find a better way of ordering the attacks?
    table.sort(ratings, function(a, b) return a[2].rating > b[2].rating end)

    -- Reorder attackers, dsts in this order
    local attacker_copies, attacker_infos, dsts = {}, {}, {}
    for i,rating in ipairs(ratings) do
        attacker_copies[i] = tmp_attacker_copies[rating[1]]
        dsts[i] = tmp_dsts[rating[1]]
        attacker_infos[i] = tmp_attacker_infos[rating[1]]
    end

    -- Only keep the stats/ratings for the first attacker, the rest needs to be recalculated
    local att_stats, def_stats = {}, {}
    att_stats[1], def_stats[1] = tmp_att_stats[ratings[1][1]], tmp_def_stats[ratings[1][1]]

    tmp_att_stats, tmp_def_stats, ratings = nil, nil, nil

    -- Then we go through all the other attacks and calculate the outcomes
    -- based on all the possible outcomes of the previous attacks
    for i = 2,#attacker_infos do
        att_stats[i] = { hp_chance = {} }
        def_stats[i] = { hp_chance = {} }

        for hp1,prob1 in pairs(def_stats[i-1].hp_chance) do -- Note: need pairs(), not ipairs() !!
            if (hp1 == 0) then
                att_stats[i].hp_chance[attacker_infos[i].hitpoints] =
                    (att_stats[i].hp_chance[attacker_infos[i].hitpoints] or 0) + prob1
                def_stats[i].hp_chance[0] = (def_stats[i].hp_chance[0] or 0) + prob1
            else
                local org_hp = defender_info.hitpoints
                defender_proxy.hitpoints = hp1  -- Yes, we need both here. It speeds up other parts.
                defender_info.hitpoints = hp1

                local ast, dst = fred_attack_utils.battle_outcome(
                    attacker_copies[i], defender_proxy, dsts[i],
                    attacker_infos[i], defender_info,
                    gamedata, move_cache, cfg
                )

                defender_proxy.hitpoints = org_hp
                defender_info.hitpoints = org_hp

                for hp2,prob2 in pairs(ast.hp_chance) do
                    att_stats[i].hp_chance[hp2] = (att_stats[i].hp_chance[hp2] or 0) + prob1 * prob2
                end
                for hp2,prob2 in pairs(dst.hp_chance) do
                    def_stats[i].hp_chance[hp2] = (def_stats[i].hp_chance[hp2] or 0) + prob1 * prob2
                end

                -- Also do poisoned, slowed
                if (not att_stats[i].poisoned) then
                    att_stats[i].poisoned = ast.poisoned
                    att_stats[i].slowed = ast.slowed
                    def_stats[i].poisoned = 1. - (1. - dst.poisoned) * (1. - def_stats[i-1].poisoned)
                    def_stats[i].slowed = 1. - (1. - dst.slowed) * (1. - def_stats[i-1].slowed)
                end
            end
        end

        -- Get the average HP
        local av_hp = 0
        for hp,prob in pairs(att_stats[i].hp_chance) do av_hp = av_hp + hp * prob end
        att_stats[i].average_hp = av_hp

        local av_hp = 0
        for hp,prob in pairs(def_stats[i].hp_chance) do av_hp = av_hp + hp * prob end
        def_stats[i].average_hp = av_hp
    end

    local rating_table =
        fred_attack_utils.attack_rating(
            attacker_infos, defender_info, dsts,
            att_stats, def_stats[#attacker_infos], gamedata, cfg
        )

    return att_stats, def_stats[#attacker_infos], attacker_infos, dsts, rating_table
end

function fred_attack_utils.get_attack_combos(attackers, defender, reach_maps, get_strongest_attack, gamedata, move_cache, cfg)
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
    --
    -- Optional inputs:
    -- @reach_maps: reach_maps for the attackers in the form as returned by fred_gamestate_utils.get_mapstate()
    --   - This is _much_ faster if reach_maps is given; should be done for all attack combos for the side
    --     Only when the result depends on a hypothetical map situation (such as for counter attacks) should
    --     it be calculated here. If reach_maps are not given, @gamedata must be provided
    --   - Even if @reach_maps is no given, gamedata still needs  to contain the "original" reach_maps for the attackers.
    --     This is used to speed up the calculation. If the attacker (enemy) cannot get to a hex originally
    --     (remember that this is done with AI units with MP taken off the map), then it can also
    --     not get there after moving AI units into place.
    --   - Important: for units on the AI side, reach_maps must NOT included hexes with units that
    --     cannot move out of the way
    -- @get_strongest_attack (boolean): if set to 'true', don't return all attacks, but only the
    --   one deemed strongest as described above. If this is set, @gamedata and @move_cache nust be provided
    --  @cfg: configuration parameters to be passed through the battle_outcome, attack_rating
    --
    -- Return value: attack combinations (either a single one or an array) of form { src = dst }, e.g.:
    -- {
    --     [21007] = 19006,
    --     [19003] = 19007
    -- }

    local defender_id, defender_loc = next(defender)

    -- If reach_maps is not given, we need to calculate them
    if (not reach_maps) then
        reach_maps = {}

        for attacker_id,_ in pairs(attackers) do
            reach_maps[attacker_id] = {}

            -- Only calculate reach if the attacker could get there using its
            -- original reach. It cannot have gotten any better than this.
            local can_reach = false
            for xa,ya in H.adjacent_tiles(defender_loc[1], defender_loc[2]) do
                if gamedata.reach_maps[attacker_id][xa] and gamedata.reach_maps[attacker_id][xa][ya] then
                    can_reach = true
                    break
                end
            end

            if can_reach then
                -- For sides other than the current, we always use max_moves.
                -- For the current side, we always use current moves.
                local old_moves
                if (gamedata.unit_infos[attacker_id].side ~= wesnoth.current.side) then
                    old_moves = gamedata.unit_copies[attacker_id].moves
                    gamedata.unit_copies[attacker_id].moves = gamedata.unit_copies[attacker_id].max_moves
                end

                local reach = wesnoth.find_reach(gamedata.unit_copies[attacker_id])

                for _,r in ipairs(reach) do
                    if (not reach_maps[attacker_id][r[1]]) then reach_maps[attacker_id][r[1]] = {} end
                    reach_maps[attacker_id][r[1]][r[2]] = { moves_left = r[3] }
                end

                if (gamedata.unit_infos[attacker_id].side ~= wesnoth.current.side) then
                    gamedata.unit_copies[attacker_id].moves = old_moves
                end
            end
        end

        -- Eliminate hexes with other units that cannot move out of the way
        for id,reach_map in pairs(reach_maps) do
            for id_noMP,loc in pairs(gamedata.my_units_noMP) do
                if (id ~= id_noMP) then
                    if reach_map[loc[1]] then reach_map[loc[1]][loc[2]] = nil end
                end
            end
        end
    end

    ----- First, find which units in @attackers can get to hexes next to @defender -----

    local defender_proxy  -- If attack rating is needed, we need the defender proxy unit, not just the unit copy
    if get_strongest_attack then
        defender_proxy = wesnoth.get_unit(defender_loc[1], defender_loc[2])
    end

    local tmp_attacks_dst_src = {}

    for xa,ya in H.adjacent_tiles(defender_loc[1], defender_loc[2]) do
        local dst = xa * 1000 + ya

        for attacker_id,attacker_loc in pairs(attackers) do
            if reach_maps[attacker_id][xa] and reach_maps[attacker_id][xa][ya] then
                local _, rating
                if get_strongest_attack then
                    local att_stat, def_stat = fred_attack_utils.battle_outcome(
                        gamedata.unit_copies[attacker_id], defender_proxy, { xa, ya },
                        gamedata.unit_infos[attacker_id], gamedata.unit_infos[defender_id],
                        gamedata, move_cache, cfg
                    )

                    -- We mostly want the defender rating
                    -- However, we add attacker rating as a small contribution,
                    -- so that good terrain for the attacker will be preferred
                    local rating_table = fred_attack_utils.attack_rating(
                        { gamedata.unit_infos[attacker_id] }, gamedata.unit_infos[defender_id], { { xa, ya } },
                        { att_stat }, def_stat,
                        gamedata, cfg
                    )

                    -- It's okay to use the full rating here, rather than just damage_rating
                    rating = rating_table.defender.rating + (rating_table.attacker.rating + rating_table.extra.rating) / 100
                    --print(xa, ya, rating, rating_table.attacker.rating, rating_table.defender.rating, rating_table.extra.rating)
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

    -- Because of the way how the recursive function below works, we want this to
    -- be an array, not a table with dsts as keys
    local attacks_dst_src = {}
    for _,dst in pairs(tmp_attacks_dst_src) do
        table.insert(attacks_dst_src, dst)
    end

    -- Now go through all the attack combinations
    -- and either collect them all or find the "strongest" attack
    local all_combos, combo, best_combo = {}, {}
    local num_hexes = #attacks_dst_src
    local max_rating, rating, hex = -9e99, 0, 0
    local max_count = 1 -- Note: must be 1, not 0

    -- If get_strongest_attack is set, we cap this at 1,000 combos, assuming
    -- that we will have found something close to the strongest by then,
    -- esp. given that the method is only approximate anyway
    local count = 0

    -- Also, if get_strongest_attack is set, we only take combos that have
    -- the maximum number of attackers. Otherwise the comparison is not fair
    -- if there are, for example villages involved

    -- This is the recursive function adding units to each hex
    -- It is defined here so that we can use the variables above by closure
    local function add_attacks()
        hex = hex + 1  -- The hex counter

        for _,attack in ipairs(attacks_dst_src[hex]) do  -- Go through all the attacks (src and rating) for each hex
            if (not combo[attack.src]) then  -- If that unit has not been used yet, add it
                count = count + 1

                combo[attack.src] = attacks_dst_src[hex].dst
                if get_strongest_attack then
                    if (count > 1000) then break end
                    rating = rating + attack.rating  -- Rating is simply the sum of the individual ratings
                end

                if (hex < num_hexes) then
                    add_attacks()
                else
                    if get_strongest_attack then
                        -- Only keep attacks with the maximum number of units
                        local tmp_count = 0
                        for _,_ in pairs(combo) do tmp_count = tmp_count + 1 end
                        -- If this is less than current max_count, don't use this attack
                        if (tmp_count < max_count) then rating = -9e99 end
                        -- If it is more, reset the max_rating (forcing this combo to be taken)
                        if (tmp_count > max_count) then max_rating = -9e99 end

                        if (rating > max_rating) then
                            max_rating = rating
                            max_count = tmp_count
                            best_combo = {}
                            for k,v in pairs(combo) do best_combo[k] = v end
                        end
                    else
                        local new_combo = {}
                        for k,v in pairs(combo) do new_combo[k] = v end
                        table.insert(all_combos, new_combo)
                    end
                end

                -- Remove this attack from the rating and table again
                if get_strongest_attack then
                    rating = rating - attack.rating
                end

                combo[attack.src] = nil
            end
        end

        -- We need to call this once more, to account for the "no unit on this hex" case
        -- Yes, this is a code duplication (done so for simplicity and speed reasons)
        if (hex < num_hexes) then
            add_attacks()
        else
            if get_strongest_attack then
                -- Only keep attacks with the maximum number of units
                -- This also automatically excludes the empty combo
                local tmp_count = 0
                for _,_ in pairs(combo) do tmp_count = tmp_count + 1 end
                -- If this is less than current max_count, don't use this attack
                if (tmp_count < max_count) then rating = -9e99 end
                -- If it is more, reset the max_rating (forcing this combo to be taken)
                if (tmp_count > max_count) then max_rating = -9e99 end

                if (rating > max_rating) then
                    max_rating = rating
                    max_count = tmp_count
                    best_combo = {}
                    for k,v in pairs(combo) do best_combo[k] = v end
                end
            else
                local new_combo = {}
                for k,v in pairs(combo) do new_combo[k] = v end
                table.insert(all_combos, new_combo)
            end
        end
        hex = hex - 1
    end

    add_attacks()

    if get_strongest_attack then
        return best_combo
    else
        -- The last combo is always the empty combo -> remove it
        all_combos[#all_combos] = nil
        return all_combos
    end
end

function fred_attack_utils.calc_counter_attack(target, old_locs, new_locs, gamedata, move_cache, cfg)
    -- Get counter-attack statistics of an AI unit in a hypothetical maps situation
    -- Units are placed on the map and the gamedata tables are adjusted inside this
    -- function in order to avoid code duplication and ensure consistency
    --
    -- Conditions that need to be met before calling this function (otherwise it won't work):
    --  - @target is a unit of the current side's AI
    --  - AI units with MP are taken off the map
    --  - AI units without MP are still on the map
    --  - All enemy units are on the map
    --
    -- INPUTS:
    -- @target: id and location of the unit for which to calculated the counter attack stats; syntax: { id = { x, y } }
    -- @old_locs, @new_locs: arrays of locations of the current and goal locations
    --   of all AI units to be moved into different positions, such as all units
    --   involved in an attack combination
    --
    -- Optional inputs:
    --  @cfg: configuration parameters to be passed through the battle_outcome, attack_rating

    -- Two array to be made available below via closure
    local stored_units, ids = {}, {}

    ----- Begin adjust_gamedata_tables() -----
    local function adjust_gamedata_tables(old_locs, new_locs, store_units_in_way)
        -- Adjust all the gamedata tables to the new position, and reset them again later.
        -- This is a local function as only counter attack calculations should have to move units.
        --
        -- INPUTS:
        -- @old_locs, @new_locs as above
        -- @store_units_in_way (boolean): whether to store the locations of the units in the way. Needs to
        -- be set to 'true' when moving the units into their new locations, needs to be set to
        -- 'false' when moving them back, in which case the stored information will be used.

        -- If any of the hexes marked in @new_locs is occupied, we
        -- need to store that information as it otherwise will be overwritten.
        -- This needs to be done for all locations before any unit is moved
        -- in order to avoid conflicts of the units to be moved among themselves
        if store_units_in_way then
            for i_l,old_loc in ipairs(old_locs) do
                local x1, y1 = old_loc[1], old_loc[2]
                local x2, y2 = new_locs[i_l][1], new_locs[i_l][2]

                -- Store the ids of the units to be put onto the map.
                -- This includes units with MP that attack from their current position,
                -- but not units without MP (as the latter are already on the map)
                -- Note: this array might have missing elements -> needs to be iterated using pairs()
                if gamedata.my_unit_map_MP[x1] and gamedata.my_unit_map_MP[x1][y1] then
                    ids[i_l] = gamedata.my_unit_map_MP[x1][y1].id
                end

                -- By contrast, we only need to store the information about units in the way,
                -- if a unit  actually gets moved to the hex (independent of whether it has MP left or not)
                if (x1 ~= x2) or (y1 ~= y2) then
                    -- If there is another unit at the new location, store it
                    -- It does not matter for this whether this is a unit involved in the move or not
                    if gamedata.my_unit_map[x2] and gamedata.my_unit_map[x2][y2] then
                        stored_units[gamedata.my_unit_map[x2][y2].id] = { x2, y2 }
                    end
                end
            end
        end

        -- Now adjust all the gamedata tables
        for i_l,old_loc in ipairs(old_locs) do
            local x1, y1 = old_loc[1], old_loc[2]
            local x2, y2 = new_locs[i_l][1], new_locs[i_l][2]
            --print('Moving unit:', x1, y1, '-->', x2, y2)

            -- We only need to do this if the unit actually gets moved
            if (x1 ~= x2) or (y1 ~= y2) then
                local id = ids[i_l]

                -- Likely, not all of these tables have to be changed, but it takes
                -- very little time, so better safe than sorry
                gamedata.unit_copies[id].x, gamedata.unit_copies[id].y = x2, y2

                gamedata.units[id] = { x2, y2 }
                gamedata.my_units[id] = { x2, y2 }
                gamedata.my_units_MP[id] = { x2, y2 }

                if gamedata.unit_infos[id].canrecruit then
                    gamedata.leaders[wesnoth.current.side] = { x2, y2, id = id }
                end

                -- Note that the following might leave empty orphan table elements, but that doesn't matter
                gamedata.my_unit_map[x1][y1] = nil
                if (not gamedata.my_unit_map[x2]) then gamedata.my_unit_map[x2] = {} end
                gamedata.my_unit_map[x2][y2] = { id = id }

                gamedata.my_unit_map_MP[x1][y1] = nil
                if (not gamedata.my_unit_map_MP[x2]) then gamedata.my_unit_map_MP[x2] = {} end
                gamedata.my_unit_map_MP[x2][y2] = { id = id }
            end
        end

        -- Finally, if 'store_units_in_way' is not set (this is, when moving units back
        -- into place), restore the stored units into the maps again
        if (not store_units_in_way) then
            for id,loc in pairs(stored_units) do
                gamedata.my_unit_map[loc[1]][loc[2]] = { id = id }
                gamedata.my_unit_map_MP[loc[1]][loc[2]] = { id = id }
            end
        end
    end
    ----- End adjust_gamedata_tables() -----

    -- Mark the new positions of the units in the gamedata tables
    adjust_gamedata_tables(old_locs, new_locs, true)

    -- Put all the units with MP onto the  map (those without are already there)
    -- They need to be proxy units for the counter attack calculation.
    for _,id in pairs(ids) do
        wesnoth.put_unit(gamedata.unit_copies[id])
    end

    local target_id, target_loc = next(target)
    local target_proxy = wesnoth.get_unit(target_loc[1], target_loc[2])

    -- reach_maps must not be given here, as this is for a hypothetical situation
    -- on the map. Needs to be recalculated for that situation.
    -- Only want the best attack combo for this.
    local counter_attack = fred_attack_utils.get_attack_combos(
        gamedata.enemies, target,
        nil, true, gamedata, move_cache, cfg
    )

    local counter_attack_stat
    if (not next(counter_attack)) then
        -- If no attacks are found, we're done; use stats of unit as is
        local hp_chance = {}
        hp_chance[target_proxy.hitpoints] = 1
        hp_chance[0] = 0  -- hp_chance[0] is always assumed to be included, even when 0

        counter_attack_stat = {
            def_stat = {
                average_hp = target_proxy.hitpoints,
                min_hp = target_proxy.hitpoints,
                hp_chance = hp_chance,
                slowed = 0,
                poisoned = 0

            },
            rating_table = {
                rating = 0,
                damage_rating = 0,
                attacker = {
                    delayed_damage = 0,
                    delayed_damage_rating = 0,
                    rating = 0,
                    damage_rating = 0
                },
                defender = {
                    delayed_damage = 0,
                    delayed_damage_rating = 0,
                    rating = 0,
                    damage_rating = 0
                },
                extra = {
                    rating = 0
                }
            }
        }
    else
        -- Otherwise calculate the attack combo statistics
        local enemy_map = {}
        for id,loc in pairs(gamedata.enemies) do
            enemy_map[loc[1] * 1000 + loc[2]] = id
        end

        local attacker_copies, dsts, attacker_infos = {}, {}, {}
        for src,dst in pairs(counter_attack) do
            table.insert(attacker_copies, gamedata.unit_copies[enemy_map[src]])
            table.insert(attacker_infos, gamedata.unit_infos[enemy_map[src]])
            table.insert(dsts, { math.floor(dst / 1000), dst % 1000 } )
        end

        local combo_att_stats, combo_def_stat, sorted_atts, sorted_dsts, rating_table =
            fred_attack_utils.attack_combo_eval(
                attacker_copies, target_proxy, dsts,
                attacker_infos, gamedata.unit_infos[target_id],
                gamedata, move_cache, cfg
            )

        --combo_def_stat.rating = rating_table.rating
        --combo_def_stat.def_rating = rating_table.defender.rating
        --combo_def_stat.att_rating = rating_table.attacker.rating
        --combo_def_stat.def_delayed_damage_rating = rating_table.defender.delayed_damage_rating
        --combo_def_stat.att_delayed_damage_rating = rating_table.attacker.delayed_damage_rating

        -- Add min_hp field
        local min_hp = 0
        for hp = 0,target_proxy.hitpoints do
            if combo_def_stat.hp_chance[hp] and (combo_def_stat.hp_chance[hp] > 0) then
                min_hp = hp
                break
            end
        end
        combo_def_stat.min_hp = min_hp

        counter_attack_stat = {
            att_stats = combo_att_stats,
            def_stat = combo_def_stat,
            rating_table = rating_table
        }
    end

    -- Extract the units from the map
    for _,id in pairs(ids) do
        wesnoth.extract_unit(gamedata.unit_copies[id])
    end

    -- And put them back into their original locations
    adjust_gamedata_tables(new_locs, old_locs)

    return counter_attack_stat, counter_attack
end

return fred_attack_utils
