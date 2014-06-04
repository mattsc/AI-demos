local H = wesnoth.require "lua/helper.lua"
local FGUI = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_utils_incremental.lua"

-- Function to perform fast evaluation of attacks and attack combinations.
-- The emphasis with all of this is on speed, not elegance.
-- This might result in redundant information being produced/passed and similar.
-- Note to self: working with Lua tables is generally much faster than with unit proxy tables.
-- Also, creating tables takes time, indexing by number is faster than by sting, etc.

local fred_attack_utils = {}

function fred_attack_utils.damage_rating_unit(attacker_info, defender_info, att_stat, def_stat, is_village, cfg)
    -- Calculate the rating for the damage received by a single attacker on a defender.
    -- The attack att_stat both for the attacker and the defender need to be precalculated for this.
    -- Unit information is passed in unit_info format, rather than as unit proxy tables for speed reasons.
    -- Note: this is _only_ the damage rating for the attacker, not both units
    --
    -- Input parameters:
    --  @attacker_info, @defender_info: unit_info tables produced by fred_gamestate_utils.single_unit_info()
    --  @att_stats, @def_stats: attack statistics for the two units
    --  @is_village: whether the hex from which the attacker attacks is a village
    --    Set to nil or false if not, to anything if it is a village (does not have to be a boolean)
    --
    -- Optional parameters:
    --  @cfg: the optional different weights listed right below

    local leader_weight = (cfg and cfg.leader_weight) or 3.
    local xp_weight = (cfg and cfg.xp_weight) or 1.
    local level_weight = (cfg and cfg.level_weight) or 1.

    -- Note: damage is damage TO the attacker, not damage done BY the attacker
    local damage = attacker_info.hitpoints - att_stat.average_hp

    -- Count poisoned as additional 8 HP damage times probability of being poisoned
    if (att_stat.poisoned ~= 0) then
        damage = damage + 8 * (att_stat.poisoned - att_stat.hp_chance[0])
    end
    -- Count slowed as additional 4 HP damage times probability of being slowed
    if (att_stat.slowed ~= 0) then
        damage = damage + 4 * (att_stat.slowed - att_stat.hp_chance[0])
    end

    -- If attack is from a village, we count that as an 8 HP bonus
    if is_village then
        damage = damage - 8.
    -- Otherwise only: if attacker can regenerate, this is an 8 HP bonus
    elseif attacker_info.regenerate then
        damage = damage - 8.
    end

    if (damage < 0) then damage = 0 end

    -- Fraction damage (= fractional value of the attacker)
    local fractional_damage = damage / attacker_info.max_hitpoints

    -- Additionally, subtract the chance to die, in order to (de)emphasize units that might die
    fractional_damage = fractional_damage + att_stat.hp_chance[0]

    -- In addition, potentially leveling up in this attack is a huge bonus.
    -- we reduce the fractions damage by the chance of it happening multiplied
    -- by the chance of not dying itself.
    -- Note: this can make the fractional damage negative (as it should)
    local defender_level = defender_info.level
    if (defender_level == 0) then defender_level = 0.5 end  -- L0 units

    local level_bonus = 0.
    if (attacker_info.max_experience - attacker_info.experience <= defender_level) then
        level_bonus = 1. - att_stat.hp_chance[0]
    elseif (attacker_info.max_experience - attacker_info.experience <= defender_level * 8) then
        level_bonus = (1. - att_stat.hp_chance[0]) * def_stat.hp_chance[0]
    end

    fractional_damage = fractional_damage - level_bonus * level_weight

    -- Now convert this into gold-equivalent value
    local value = attacker_info.cost

    -- If this is the side leader, make damage to it much more important
    if attacker_info.canrecruit then
        value = value * leader_weight
    end

    -- Being closer to leveling makes the attacker more valuable
    -- TODO: consider using a more precise measure here
    local xp_bonus = attacker_info.experience / attacker_info.max_experience
    value = value * (1. + xp_bonus * xp_weight)

    local rating = fractional_damage * value
    --print('damage, fractional_damage, value, rating', attacker_info.id, damage, fractional_damage, value, rating)

    return rating
end

function fred_attack_utils.attack_rating(attacker_infos, defender_info, dsts, att_stats, def_stat, mapstate, unit_copies, defense_maps, cfg)
    -- Returns a common (but configurable) rating for attacks of one or several attackers against one defender
    --
    -- Inputs:
    --  @attackers_infos: input array of attacker unit_info tables (must be an array even for single unit attacks)
    --  @defender_info: defender unit_info
    --  @dsts: array of attack locations in form { x, y } (must be an array even for single unit attacks)
    --  @att_stats: array of the attack stats of the attack combination(!) of the attackers
    --    (must be an array even for single unit attacks)
    --  @def_stat: the combat stats of the defender after facing the combination of the attackers
    --  @mapstate: table with the map state as produced by fred_gamestate_utils.mapstate_reachmaps()
    --  @defense_maps: table of unit terrain defense values as produced by fred_gamestate_utils_incremental.get_unit_defense()
    -- Note: for speed reasons @mapstate and @defense_maps are _not_ optional
    --
    --  Optional inputs:
    --   @cfg: the different weights listed right below
    --
    -- Returns:
    --   - Overall rating for the attack or attack combo
    --   - Attacker rating: the sum of all the attacker damage ratings
    --   - Defender rating: the combined defender damage rating
    --   - Extra rating: additional ratings that do not directly describe damage
    --       This should be used to help decide which attack to pick,
    --       but not for, e.g., evaluating counter attacks (which should be entirely damage based)
    --   Note: rating = defender_rating - attacker_rating * own_value_weight + extra_rating

    -- Set up the config parameters for the rating
    local defender_starting_damage_weight = (cfg and cfg.defender_starting_damage_weight) or 0.33
    local defense_weight = (cfg and cfg.defense_weight) or 0.1
    local distance_leader_weight = (cfg and cfg.distance_leader_weight) or 0.002
    local occupied_hex_penalty = (cfg and cfg.occupied_hex_penalty) or 0.001
    local own_value_weight = (cfg and cfg.own_value_weight) or 1.0

    local attacker_rating = 0
    for i,attacker_info in ipairs(attacker_infos) do
        local attacker_on_village = mapstate.village_map[dsts[i][1]] and mapstate.village_map[dsts[i][1]][dsts[i][2]]
        attacker_rating = attacker_rating + fred_attack_utils.damage_rating_unit(
            attacker_info, defender_info, att_stats[i], def_stat, attacker_on_village, cfg
        )
    end

    local defender_x, defender_y = mapstate.units[defender_info.id][1], mapstate.units[defender_info.id][2]
    local defender_on_village = mapstate.village_map[defender_x] and mapstate.village_map[defender_x][defender_y]
    local defender_rating = fred_attack_utils.damage_rating_unit(
        defender_info, attacker_infos[1], def_stat, att_stats[1], defender_on_village, cfg
    )

    -- Now we add some extra ratings.  They are positive for attacks that should be preferred
    -- and expressed in fraction of the defender maximum hitpoints
    -- They should be used to help decide which attack to pick,
    -- but not for, e.g., evaluating counter attacks (which should be entirely damage based)
    local extra_rating = 0.

    -- Prefer to attack already damaged enemies
    local defender_starting_damage_fraction = defender_info.max_hitpoints - defender_info.hitpoints
    extra_rating = extra_rating + defender_starting_damage_fraction * defender_starting_damage_weight

    -- If defender is on a village, add a bonus rating (we want to get rid of those preferentially)
    -- This is in addition to the damage bonus already included above (but as an extra rating)
    if defender_on_village then
        extra_rating = extra_rating + 10.
    end

    -- Normalize so that it is in fraction of defender max_hitpoints
    extra_rating = extra_rating / defender_info.max_hitpoints

    -- We don't need a bonus for good terrain for the attacker, as that is covered in the damage calculation
    -- However, we add a small bonus for good terrain defense of the _defender_ on the _attack_ hexes
    -- This is in order to take good terrain away from defender on next move, all else being equal
    local defense_rating = 0.
    for _,dst in ipairs(dsts) do
        defense_rating = defense_rating + FGUI.get_unit_defense(
            unit_copies[defender_info.id],
            dst[1], dst[2],
            defense_maps
        )
    end
    defense_rating = defense_rating / #dsts * defense_weight

    extra_rating = extra_rating + defense_rating

    -- Get a very small bonus for hexes in between defender and AI leader
    -- 'relative_distances' is larger for attack hexes closer to the side leader (possible values: -1 .. 1)
    if mapstate.leaders[attacker_infos[1].side] then
        local leader_x, leader_y = mapstate.leaders[attacker_infos[1].side][1], mapstate.leaders[attacker_infos[1].side][2]

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
    --    that is we only check mapstate.my_unit_map_MP here
    for i,dst in ipairs(dsts) do
        if mapstate.my_unit_map_MP[dst[1]] and mapstate.my_unit_map_MP[dst[1]][dst[2]] then
            if (mapstate.my_unit_map_MP[dst[1]][dst[2]].id ~= attacker_infos[i].id) then
                extra_rating = extra_rating - occupied_hex_penalty
            end
        end
    end

    -- Finally add up and apply factor of own unit weight to defender unit weight
    -- This is a number equivalent to 'aggression' in the default AI (but applied differently)
    local rating = defender_rating - attacker_rating * own_value_weight + extra_rating

    --print('rating, attacker_rating, defender_rating, extra_rating:', rating, attacker_rating, defender_rating, extra_rating)

    return rating, attacker_rating, defender_rating, extra_rating
end

function fred_attack_utils.battle_outcome(attacker_copy, defender, dst, attacker_info, defender_info, mapstate, defense_maps, move_cache)
    -- Calculate the stats of a combat by @attacker_copy vs. @defender at location @dst
    -- We use wesnoth.simulate_combat for this, but cache results when possible
    -- Inputs:
    --  @attackers_copy: private unit copy of the attacker proxy table (this _must_ be a copy, not the proxy itself)
    --  @defender: defender proxy table (this _must_ be a unit proxy table on the map, not a copy)
    --  @dst: location from which the attacker will attack in form { x, y }
    -- @attacker_info, @defender_info: unit info for the two units (needed in addition to the units
    --   themselves in order to speed things up)
    --  @mapstate: table with the map state as produced by fred_gamestate_utils.mapstate_reachmaps()
    --  @defense_maps: table of unit terrain defense values as produced by fred_gamestate_utils_incremental.get_unit_defense()
    --  @move_cache: for caching data *for this move only*, needs to be cleared after a gamestate change
    -- Note: for speed reasons @mapstate, @defense_maps and @move_cache are _not_ optional

    local defender_defense = FGUI.get_unit_defense(defender, defender.x, defender.y, defense_maps)
    local attacker_defense = FGUI.get_unit_defense(attacker_copy, dst[1], dst[2], defense_maps)

    if move_cache[attacker_info.id]
        and move_cache[attacker_info.id][defender_info.id]
        and move_cache[attacker_info.id][defender_info.id][attacker_defense]
        and move_cache[attacker_info.id][defender_info.id][attacker_defense][defender_defense]
        and move_cache[attacker_info.id][defender_info.id][attacker_defense][defender_defense][attacker_info.hitpoints]
        and move_cache[attacker_info.id][defender_info.id][attacker_defense][defender_defense][attacker_info.hitpoints][defender_info.hitpoints]
    then
        return move_cache[attacker_info.id][defender_info.id][attacker_defense][defender_defense][attacker_info.hitpoints][defender_info.hitpoints].att_stats,
            move_cache[attacker_info.id][defender_info.id][attacker_defense][defender_defense][attacker_info.hitpoints][defender_info.hitpoints].def_stats
    end

    local old_x, old_y = attacker_copy.x, attacker_copy.y
    attacker_copy.x, attacker_copy.y = dst[1], dst[2]
    local tmp_att_stats, tmp_def_stats = wesnoth.simulate_combat(attacker_copy, defender)
    attacker_copy.x, attacker_copy.y = old_x, old_y

    -- Extract only those hp_chances that are non-zero (except for hp_chance[0]
    -- which is always needed).  This slows down this step a little, but significantly speeds
    -- up attack combination calculations

    local att_stats = {
        hp_chance = {},
        average_hp = tmp_att_stats.average_hp,
        poisoned = tmp_att_stats.poisoned,
        slowed = tmp_att_stats.slowed
    }

    att_stats.hp_chance[0] = tmp_att_stats.hp_chance[0]
    for i = 1,#tmp_att_stats.hp_chance do
        if (tmp_att_stats.hp_chance[i] ~= 0) then
            att_stats.hp_chance[i] = tmp_att_stats.hp_chance[i]
        end
    end

    local def_stats = {
        hp_chance = {},
        average_hp = tmp_def_stats.average_hp,
        poisoned = tmp_def_stats.poisoned,
        slowed = tmp_def_stats.slowed
    }

    def_stats.hp_chance[0] = tmp_def_stats.hp_chance[0]
    for i = 1,#tmp_def_stats.hp_chance do
        if (tmp_def_stats.hp_chance[i] ~= 0) then
            def_stats.hp_chance[i] = tmp_def_stats.hp_chance[i]
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
        = { att_stats = att_stats, def_stats = def_stats }

    return att_stats, def_stats
end

function fred_attack_utils.attack_combo_eval(tmp_attacker_copies, defender, tmp_dsts, tmp_attacker_infos, defender_info, mapstate, unit_copies, defense_maps, move_cache)
    -- Calculate attack combination outcomes using
    -- @tmp_attacker_copies: array of attacker unit copiess (must be copies, not the proxy tables themselves)
    -- @defender: the unit being attacked (must be the unit proxy table on the map, not a unit copy)
    -- @tmp_dsts: array of the hexes (format { x, y }) from which the attackers attack
    --   must be in same order as @attackers
    -- @tmp_attacker_infos, @defender_info: unit info for the attackers and defenders (needed in addition to the units
    --   themselves in order to speed things up)
    -- @mapstate, @defense_maps, @move_cache: only needed to pass to the functions being called
    --    see fred_attack_utils.battle_outcome() for descriptions
    --
    -- Return values (in this order):
    --   - att_stats: an array of stats for each attacker, in the order found for the "best attack",
    --       which is generally different from the order of @tmp_attacker_copies
    --   - defender combo stats: one set of stats containing the defender stats after the attack combination
    --   - The sorted attacker_infos and dsts arrays
    --   - The rating for this attack combination calculated from fred_attack_utils.attack_rating() results
    --   - The (summed up) attacker and (combined) defender rating, as well as the extra rating separately

    -- We first simulate and rate the individual attacks
    local ratings, tmp_att_stats, tmp_def_stats = {}, {}, {}
    for i,attacker_copy in ipairs(tmp_attacker_copies) do
        tmp_att_stats[i], tmp_def_stats[i] =
            fred_attack_utils.battle_outcome(
                attacker_copy, defender, tmp_dsts[i],
                tmp_attacker_infos[i], defender_info,
                mapstate, defense_maps, move_cache
            )

        local rating =
            fred_attack_utils.attack_rating(
                { tmp_attacker_infos[i] }, defender_info, { tmp_dsts[1] },
                { tmp_att_stats[i] }, tmp_def_stats[i], mapstate, unit_copies, defense_maps
            )

        ratings[i] = { i, rating }  -- Need the i here in order to specify the order of attackers, dsts
    end

    -- Sort all the arrays based on this rating
    -- This will give the order in which the individual attacks are executed
    -- That's an approximation of the best order, everything else is too expensive
    table.sort(ratings, function(a, b) return a[2] > b[2] end)

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
                defender.hitpoints = hp1  -- Yes, we need both here.  It speeds up other parts.
                defender_info.hitpoints = hp1

                local ast, dst = fred_attack_utils.battle_outcome(
                    attacker_copies[i], defender, dsts[i],
                    attacker_infos[i], defender_info,
                    mapstate, defense_maps, move_cache
                )

                defender.hitpoints = org_hp
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

    local rating, attacker_rating, defender_rating, extra_rating =
        fred_attack_utils.attack_rating(
            attacker_infos, defender_info, dsts,
            att_stats, def_stats[#attacker_infos], mapstate, unit_copies, defense_maps
        )

    return att_stats, def_stats[#attacker_infos], attacker_infos, dsts, rating, attacker_rating, defender_rating, extra_rating
end

function fred_attack_utils.get_attack_combos(attackers, defender, reachmaps, get_strongest_attack, gamedata, move_cache)
    -- Get all attack combinations of @attackers on @defender
    -- OR: get what is considered the strongest of those attacks (approximately)
    -- The former is in order to get all attack combos (but order of individual attacks doesn't matter),
    -- the latter is for a quick-and-dirty search for, for example, the strongest counter attack,
    -- when a full attack combination evaluation is too expensive.  The strongest attack is defined
    -- as the one which has the largest sum of damage done to the defender
    --
    -- Required inputs:
    -- @attackers: array of attacker ids and locations: { id1 = { x1 , y1 }, id2 = ... }
    -- @defender: defender id and location: { id = { x, y } }
    --
    -- Optional inputs:
    -- @reachmaps: reachmaps for the attackers in the form as returned by fred_gamestate_utils.get_gamestate()
    --   - This is _much_ faster if reachmaps is given; should be done for all attack combos for the side
    --     Only when the result depends on the new map situation (such as for counter attacks) should
    --     it be calculated here.  If reachmaps are not given, @gamedata must be provided
    --   - Even if @reachmap is no given, gamedata still needs  to contain the "original" reachmaps for the attackers.
    --     This is used to speed up the calculation.  If the attacker (enemy) cannot get to a hex originally
    --     (remember that this is done with AI units with MP taken off the map), then it can also
    --     not get there after moving AI units into place.
    --   - Important: for units on the AI side, reachmaps must NOT included hexes with units that
    --     cannot move out of the way
    -- @get_strongest_attack (boolean): if set to 'true', don't return all attacks, but only the
    --   one deemed strongest as described above.  If this is set, @gamedata and @move_cache nust be provided
    --
    -- Return value: attack combinations (either a single one or an array) of form { src = dst } :
    -- {
    --     [21007] = 19006,
    --     [19003] = 19007
    -- }

    local defender_id, defender_loc = next(defender)

    -- If reachmaps is not given, we need to calculate them
    if (not reachmaps) then
        reachmaps = {}

        for attacker_id,_ in pairs(attackers) do
            reachmaps[attacker_id] = {}

            -- Only calculate reach if the attacker could get there using its
            -- original reach.  It cannot have gotten any better than this.
            local can_reach = false
            for xa,ya in H.adjacent_tiles(defender_loc[1], defender_loc[2]) do
                if gamedata.reachmaps[attacker_id][xa] and gamedata.reachmaps[attacker_id][xa][ya] then
                    can_reach = true
                    break
                end
            end

            if can_reach then
                -- For sides other than the current, we always use max_moves.
                -- For the current side, we always use current moves.
                local old_moves
                if (gamedata.unit_info[attacker_id].side ~= wesnoth.current.side) then
                    old_moves = gamedata.unit_copies[attacker_id].moves
                    gamedata.unit_copies[attacker_id].moves = gamedata.unit_copies[attacker_id].max_moves
                end

                local reach = wesnoth.find_reach(gamedata.unit_copies[attacker_id])

                for _,r in ipairs(reach) do
                    if (not reachmaps[attacker_id][r[1]]) then reachmaps[attacker_id][r[1]] = {} end
                    reachmaps[attacker_id][r[1]][r[2]] = r[3]
                end

                if (gamedata.unit_info[attacker_id].side ~= wesnoth.current.side) then
                    gamedata.unit_copies[attacker_id].moves = old_moves
                end
            end
        end

        -- Eliminate hexes with other units that cannot move out of the way
        for id,reachmap in pairs(reachmaps) do
            for id_noMP,loc in pairs(gamedata.mapstate.my_units_noMP) do
                if (id ~= id_noMP) then
                    if reachmap[loc[1]] then reachmap[loc[1]][loc[2]] = nil end
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
            if reachmaps[attacker_id][xa] and reachmaps[attacker_id][xa][ya] then
                local _, rating
                if get_strongest_attack then
                    local att_stats, def_stats = fred_attack_utils.battle_outcome(
                        gamedata.unit_copies[attacker_id], defender_proxy, { xa, ya },
                        gamedata.unit_info[attacker_id], gamedata.unit_info[defender_id],
                        gamedata.mapstate, gamedata.defense_maps, move_cache
                    )

                    _,_,rating = fred_attack_utils.attack_rating(
                        { gamedata.unit_info[attacker_id] }, gamedata.unit_info[defender_id], { { xa, ya } },
                        { att_stats }, def_stats,
                        gamedata.mapstate, gamedata.unit_copies, gamedata.defense_maps
                    )
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

    ----- Now go through all the attack combinations -----
    -- and either collect them all or find the "strongest" attack
    local all_combos, combo, best_combo = {}, {}
    local num_hexes = #attacks_dst_src
    local max_rating, rating, hex = -9e99, 0, 0

    -- This is the recursive function adding units to each hex
    -- It is defined here so that we can use the variables above by closure
    local function add_attacks()
        hex = hex + 1  -- The hex counter

        for _,attack in ipairs(attacks_dst_src[hex]) do  -- Go through all the attacks (src and rating) for each hex
            if (not combo[attack.src]) then  -- If that unit has not been used yet, add it
                combo[attack.src] = attacks_dst_src[hex].dst

                if get_strongest_attack then
                    rating = rating + attack.rating  -- Rating is simply the sum of the individual ratings
                end

                if (hex < num_hexes) then
                    add_attacks()
                else
                    if get_strongest_attack then
                        if (rating > max_rating) then
                            max_rating = rating
                            best_combo = {}
                            for k,v in pairs(combo) do best_combo[k] = v end
                        end
                    else
                        local new_combo = {}
                        for k,v in pairs(combo) do new_combo[k] = v end
                        table.insert(all_combos, new_combo)
                    end
                end

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
                if (rating > max_rating) then
                    max_rating = rating
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

return fred_attack_utils
