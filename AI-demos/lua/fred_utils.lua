local FDI = wesnoth.require "~/add-ons/AI-demos/lua/fred_data_incremental.lua"
local FCFG = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_config.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local fred_utils = {}

local function unit_value(unit_info, unit_types_cache)
    -- Get a gold-equivalent value for the unit
    -- Also returns (as a factor) the increase of value compared to cost with
    -- a contribution for the level of the unit

    local unit_value = unit_info.cost

    -- If this is the side leader, make damage to it much more important
    if unit_info.canrecruit and (unit_info.side == wesnoth.current.side) then
        local leader_weight = FCFG.get_cfg_parm('leader_weight')
        unit_value = unit_value * leader_weight
    end

    -- Being closer to leveling makes the unit more valuable, proportional to
    -- the difference between the unit and the leveled unit
    local cost_factor = 1.5
    if unit_info.advances_to then
        local advanced_cost = FDI.get_unit_type_attribute(unit_info.advances_to, 'cost', unit_types_cache)
        cost_factor = advanced_cost / unit_info.cost
    end

    local xp_weight = FCFG.get_cfg_parm('xp_weight')
    local xp_diff = unit_info.max_experience - unit_info.experience
    -- Square so that a few XP don't matter, but being close to leveling is important
    -- Units very close to leveling are considered even more valuable than leveled unit
    local xp_bonus
    if (xp_diff <= 1) then
        xp_bonus = 1.33
    elseif (xp_diff <= 8) then
        xp_bonus = 1.2
    else
        xp_bonus = (unit_info.experience / (unit_info.max_experience - 6))^2
    end
    unit_value = unit_value * (1. + xp_bonus * (cost_factor - 1) * xp_weight)

    --std_print('fred_utils.unit_value:', unit_info.id, unit_value, xp_bonus, xp_diff)

    -- TODO: probably want to make the unit level contribution configurable
    local value_factor = unit_value / unit_info.cost * math.sqrt(unit_info.level)

    return unit_value, value_factor
end

local function unit_base_power(hitpoints, max_hitpoints, max_damage)
    return max_damage * fred_utils.weight_s(hitpoints / max_hitpoints, 0.67)
end

local function unit_current_power(base_power, tod_mod)
    return base_power * tod_mod
end

----- End local functions -----


function fred_utils.weight_s(x, exp)
    -- S curve weighting of a variable that is meant as a fraction of a total.
    -- Thus, @x for the most part varies from 0 to 1, but does continues smoothly
    -- outside those ranges
    --
    -- Properties independent of @exp:
    --   f(0) = 0
    --   f(0.5) = 0.5
    --   f(1) = 1

    -- Examples for different exponents:
    -- exp:   0.000  0.100  0.200  0.300  0.400  0.500  0.600  0.700  0.800  0.900  1.000
    -- 0.50:  0.000  0.053  0.113  0.184  0.276  0.500  0.724  0.816  0.887  0.947  1.000
    -- 0.67:  0.000  0.069  0.145  0.229  0.330  0.500  0.670  0.771  0.855  0.931  1.000
    -- 1.00:  0.000  0.100  0.200  0.300  0.400  0.500  0.600  0.700  0.800  0.900  1.000
    -- 1.50:  0.000  0.142  0.268  0.374  0.455  0.500  0.545  0.626  0.732  0.858  1.000
    -- 2.00:  0.000  0.180  0.320  0.420  0.480  0.500  0.520  0.580  0.680  0.820  1.000

    local weight
    if (x >= 0.5) then
        return 0.5 + ((x - 0.5) * 2)^exp / 2
    else
        return 0.5 - ((0.5 - x) * 2)^exp / 2
    end
end

function fred_utils.print_weight_s(exp)
    -- Just for testing fred_utils.weight_s()
    local s1, s2 = '', ''
    for i=-5,15 do
        local x = 0.1 * i
        y = fred_utils.weight_s(x, exp)
        s1 = s1 .. string.format("%5.3f", x) .. '  '
        s2 = s2 .. string.format("%5.3f", y) .. '  '
    end
    std_print(s1)
    std_print(s2)
end

function fred_utils.get_unit_time_of_day_bonus(alignment, is_fearless, lawful_bonus)
    local multiplier = 1
    if (lawful_bonus ~= 0) then
        if (alignment == 'lawful') then
            multiplier = (1 + lawful_bonus / 100.)
        elseif (alignment == 'chaotic') then
            multiplier = (1 - lawful_bonus / 100.)
        elseif (alignment == 'liminal') then
            multipler = (1 - math.abs(lawful_bonus) / 100.)
        end
    end

    if is_fearless and (multiplier < 1) then
        multiplier = 1
    end

    return multiplier
end

function fred_utils.single_unit_info(unit_proxy, unit_types_cache)
    -- Collects unit information from proxy unit table @unit_proxy into a Lua table
    -- so that it is accessible faster.
    -- Note: Even accessing the directly readable fields of a unit proxy table
    -- is slower than reading from a Lua table; not even talking about unit_proxy.__cfg.
    --
    -- This can also be used on a unit type entry from wesnoth.unit_types, but in that
    -- case not all fields will be populated, of course, and anything depending on
    -- traits and the like will not necessarily be correct for the individual unit
    -- Note: this is currently disabled.
    --
    -- Important: this is slow, so it should only be called once at the beginning
    -- of each move, but it does need to be redone after each move, as it contains
    -- information like HP and XP (or the unit might have leveled up or been changed
    -- in an event).
    --
    -- Note: unit location information is NOT included; that is intentional

    -- This is by far the most expensive step in this function, but it cannot be skipped yet
    local unit_cfg = unit_proxy.__cfg

    local single_unit_info = {
        id = unit_proxy.id,
        canrecruit = unit_proxy.canrecruit,
        side = unit_proxy.side,

        moves = unit_proxy.moves,
        max_moves = unit_proxy.max_moves,
        hitpoints = unit_proxy.hitpoints,
        max_hitpoints = unit_proxy.max_hitpoints,
        experience = unit_proxy.experience,
        max_experience = unit_proxy.max_experience,

        type = unit_proxy.type,
        alignment = unit_proxy.alignment,
        cost = unit_proxy.cost,
        level = unit_proxy.level
    }

    -- Some of the cost maps are very expensive, so we only want to do them once for each
    -- movement_type. As accessing the movement_type is slow as well, add it to unit_info.
    -- If movement_type is not set, use the unit type.
    -- TODO: add variations
    single_unit_info.movement_type = wesnoth.unit_types[single_unit_info.type].__cfg.movement_type or single_unit_info.type

    -- Pick the first of the advances_to types, nil when there is none
    single_unit_info.advances_to = unit_proxy.advances_to[1]

    -- Include the ability type, such as: hides, heals, regenerate, skirmisher (set up as 'hides = true')
    -- Note that unit_proxy.abilities gives the id of the ability. This is different from
    -- the value below, which is the name of the tag (e.g. 'heals' vs. 'healing' and/or 'curing')
    single_unit_info.abilities = {}
    local abilities = wml.get_child(unit_cfg, "abilities")
    if abilities then
        for _,ability in ipairs(abilities) do
            single_unit_info.abilities[ability[1]] = true
        end
    end

    -- Information about the attacks indexed by weapon number,
    -- including specials (e.g. 'poison = true')
    single_unit_info.attacks = {}
    local max_damage = 0
    for i,attack in ipairs(unit_proxy.attacks) do
        -- Extract information for specials; we do this first because some
        -- custom special might have the same name as one of the default scalar fields
        local a = {}
        for _,sp in ipairs(attack.specials) do
            if (sp[1] == 'damage') then  -- this is 'backstab'
                if (sp[2].id == 'backstab') then
                    a.backstab = true
                else
                    if (sp[2].id == 'charge') then a.charge = true end
                end
            else
                -- magical, marksman
                if (sp[1] == 'chance_to_hit') then
                    a[sp[2].id] = true
                else
                    a[sp[1]] = true
                end
            end
        end
        a.damage = attack.damage
        a.number = attack.number
        a.range = attack.range
        a.type = attack.type

        table.insert(single_unit_info.attacks, a)

        -- TODO: potentially use FAU.get_total_damage_attack for this later, but for
        -- the time being these are too different, and have too different a purpose.
        total_damage = a.damage * a.number

        -- Just use blanket damage for poison and slow for now; might be refined later
        if a.poison then total_damage = total_damage + 8 end
        if a.slow then total_damage = total_damage + 4 end

        -- Also give some bonus for drain and backstab, but not to the full extent
        -- of what they can achieve
        if a.drains then total_damage = total_damage * 1.25 end
        if a.backstab then total_damage = total_damage * 1.33 end

        if (total_damage > max_damage) then
            max_damage = total_damage
        end
    end
    single_unit_info.max_damage = max_damage

    -- Time of day modifier: done here once so that it works on unit types also.
    -- It is repeated below if a unit is passed, to take the fearless trait into account.
    single_unit_info.tod_mod = fred_utils.get_unit_time_of_day_bonus(single_unit_info.alignment, false, wesnoth.get_time_of_day().lawful_bonus)

    -- The following can only be done on a real unit, not on a unit type
    -- Note: the unit_type functionality is currently not used, but since the only
    --   penalty is one simple conditional, we leave it in place.
    if (unit_proxy.x) then
        local unit_value, value_factor = unit_value(single_unit_info, unit_types_cache)
        single_unit_info.unit_value = unit_value
        single_unit_info.value_factor = value_factor

        single_unit_info.base_power = unit_base_power(single_unit_info.hitpoints, single_unit_info.max_hitpoints, max_damage)
        single_unit_info.current_power = unit_current_power(single_unit_info.base_power, single_unit_info.tod_mod)
        single_unit_info.status = {}
        local status = wml.get_child(unit_cfg, "status")
        for k,_ in pairs(status) do
            single_unit_info.status[k] = true
        end

        single_unit_info.traits = {}
        local mods = wml.get_child(unit_cfg, "modifications")
        for trait in wml.child_range(mods, 'trait') do
            single_unit_info.traits[trait.id] = true
        end

        -- Now we do this again, using the correct value for the fearless trait
        single_unit_info.tod_mod = fred_utils.get_unit_time_of_day_bonus(single_unit_info.alignment, single_unit_info.traits.fearless, wesnoth.get_time_of_day().lawful_bonus)

        -- Define what "good terrain" means for a unit
        local defense = wml.get_child(unit_cfg, "defense")
        -- Get the hit chances for all terrains and sort (best = lowest hit chance first)
        local hit_chances = {}
        for _,hit_chance in pairs(defense) do
            table.insert(hit_chances, { hit_chance = math.abs(hit_chance) })
        end
        table.sort(hit_chances, function(a, b) return a.hit_chance < b.hit_chance end)

        -- As "normal" we use the hit chance on "flat equivalent" terrain.
        -- That means on flat for most units, on cave for dwarves etc.
        -- and on shallow water for mermen, nagas etc.
        -- Use the best of those
        local flat_hc = math.min(defense.flat, defense.cave, defense.shallow_water)
        --std_print('best hit chance on flat, cave, shallow water:', flat_hc)
        --std_print(defense.flat, defense.cave, defense.shallow_water)

        -- Good terrain is now defined as 10% lesser hit chance than that, except
        -- when this is better than the third best terrain for the unit. An example
        -- are ghosts, which have 50% on all terrains.
        -- I have tested this for most mainline level 1 units and it seems to work pretty well.
        local good_terrain_hit_chance = flat_hc - 10
        if (good_terrain_hit_chance < hit_chances[3].hit_chance) then
            good_terrain_hit_chance = flat_hc
        end
        --std_print('good_terrain_hit_chance', good_terrain_hit_chance)

        single_unit_info.good_terrain_hit_chance = good_terrain_hit_chance / 100.
    else
        std_print('************ using this on a unit type ***********')
    end

    return single_unit_info
end

function fred_utils.approx_value_loss(unit_info, av_damage, max_damage)
    -- This is similar to FAU.damage_rating_unit (but simplified)
    -- TODO: maybe base the two on the same core function at some point

    -- Returns loss of value (as a negative number)

    -- In principle, damage is a fraction of max_hitpoints. However, it should be
    -- more important for units already injured. Making it a fraction of hitpoints
    -- would overemphasize units close to dying, as that is also factored in. Thus,
    -- we use an effective HP value that's a weighted average of the two.
    local injured_fraction = 0.5
    local hp = unit_info.hitpoints
    local hp_eff = injured_fraction * hp + (1 - injured_fraction) * unit_info.max_hitpoints

    -- Cap the damage at the hitpoints of the unit; larger damage is taken into
    -- account in the chance to die
    local real_damage = av_damage
    if (av_damage > hp) then
        real_damage = hp
    end
    local fractional_damage = real_damage / hp_eff
    local fractional_rating = - fred_utils.weight_s(fractional_damage, 0.67)
    --std_print('  fractional_damage, fractional_rating:', fractional_damage, fractional_rating)

    -- Additionally, add the chance to die, in order to emphasize units that might die
    -- This might result in fractional_damage > 1 in some cases
    -- Very approximate estimate of the CTD
    local approx_ctd = 0
    if (av_damage > hp) then
        approx_ctd = 0.5 + 0.5 * (1 - hp / av_damage)
    elseif (max_damage > hp) then
        approx_ctd = 0.5 * (max_damage - hp) / (max_damage - av_damage)
    end
    local ctd_rating = - 1.5 * approx_ctd^1.5
    fractional_rating = fractional_rating + ctd_rating
    --std_print('  ctd, ctd_rating, fractional_rating:', approx_ctd, ctd_rating, fractional_rating)

    -- Convert all the fractional ratings before to one in "gold units"
    -- We cap this at 1.5 times the unit value
    -- TODO: what's the best value here?
    if (fractional_rating < -1.5) then
        fractional_rating = -1.5
    end
    local unit_value = unit_info.unit_value
    local value_loss = fractional_rating * unit_value
    --std_print('  unit_value, value_loss:', unit_info.unit_value, value_loss)

    return value_loss, approx_ctd, unit_value
end

function fred_utils.get_unit_hex_combos(dst_src, get_best_combo, add_rating)
    -- Recursively find all combinations of distributing
    -- units on hexes. The number of units and hexes does not have to be the same.
    -- @dst_src lists all units which can reach each hex in format:
    --  [1] = {
    --      [1] = { src = 17028 },
    --      [2] = { src = 16027 },
    --      [3] = { src = 15027 },
    --      dst = 18025
    --  },
    --  [2] = {
    --      [1] = { src = 17028 },
    --      [2] = { src = 16027 },
    --      dst = 20026
    --  },
    --
    -- OPTIONAL INPUTS:
    --  @get_best_combo: find the highest rated combo; in this case, @dst_src needs to
    --    contain a rating key:
    --  [2] = {
    --      [1] = { src = 17028, rating = 0.91 },
    --      [2] = { src = 16027, rating = 0.87 },
    --      dst = 20026
    --  }
    --    The combo rating is then the sum of all the individual ratings entering a combo.
    --  @add_rating: add the sum of the individual ratings to each combo, using rating= field.
    --    Note that this means that this field needs to be separated out from the actual dst-src
    --    info when reading the table. Input needs to be of same format as for @get_best_combo.

    local all_combos, combo = {}, {}
    local num_hexes = #dst_src
    local hex = 0

    -- If get_best_combo is set, we cap this at 1,000 combos, assuming
    -- that we will have found something close to the strongest by then,
    -- esp. given that the method is only approximate anyway.
    -- Also, if get_best_combo is set, we only take combos that have
    -- the maximum number of attackers. Otherwise the comparison is not fair
    local max_count = 1 -- Note: must be 1, not 0
    local count = 0
    local max_rating, best_combo = - math.huge
    local rating = 0

    -- This is the recursive function adding units to each hex
    -- It is defined here so that we can use the variables above by closure
    local function add_combos()
        hex = hex + 1

        for _,ds in ipairs(dst_src[hex]) do
            if (not combo[ds.src]) then  -- If that unit has not been used yet, add it
                count = count + 1

                combo[ds.src] = dst_src[hex].dst

                if get_best_combo or add_rating then
                    if (count > 1000) then
                        combo[ds.src] = nil
                        break
                    end
                    rating = rating + ds.rating  -- Rating is simply the sum of the individual ratings
                end

                if (hex < num_hexes) then
                    add_combos()
                else
                    if get_best_combo then
                        -- Only keep combos with the maximum number of units
                        local tmp_count = 0
                        for _,_ in pairs(combo) do tmp_count = tmp_count + 1 end
                        -- If this is more than current max_count, reset the max_rating (forcing this combo to be taken)
                        if (tmp_count > max_count) then max_rating = - math.huge end

                        -- If this is less than current max_count, don't use this combo
                        if (rating > max_rating) and (tmp_count >= max_count) then
                            max_rating = rating
                            max_count = tmp_count
                            best_combo = {}
                            for k,v in pairs(combo) do best_combo[k] = v end
                        end
                    else
                        local new_combo = {}
                        for k,v in pairs(combo) do new_combo[k] = v end
                        if add_rating then new_combo.rating = rating end
                        table.insert(all_combos, new_combo)
                    end
                end

                -- Remove this element from the table again
                if get_best_combo or add_rating then
                    rating = rating - ds.rating
                end

                combo[ds.src] = nil
            end
        end

        -- We need to call this once more, to account for the "no unit on this hex" case
        -- Yes, this is a code duplication (done so for simplicity and speed reasons)
        if (hex < num_hexes) then
            add_combos()
        else
            if get_best_combo then
                -- Only keep attacks with the maximum number of units
                -- This also automatically excludes the empty combo
                local tmp_count = 0
                for _,_ in pairs(combo) do tmp_count = tmp_count + 1 end
                -- If this is more than current max_count, reset the max_rating (forcing this combo to be taken)
                if (tmp_count > max_count) then max_rating = - math.huge end

                -- If this is less than current max_count, don't use this attack
                if (rating > max_rating) and (tmp_count >= max_count)then
                    max_rating = rating
                    max_count = tmp_count
                    best_combo = {}
                    for k,v in pairs(combo) do best_combo[k] = v end
                end
            else
                local new_combo = {}
                for k,v in pairs(combo) do new_combo[k] = v end
                if add_rating then new_combo.rating = rating end
                table.insert(all_combos, new_combo)
            end
        end

        hex = hex - 1
    end

    add_combos()

    if get_best_combo then
        return best_combo
    end

    -- The last combo is always the empty combo -> remove it
    all_combos[#all_combos] = nil

    return all_combos
end

return fred_utils
