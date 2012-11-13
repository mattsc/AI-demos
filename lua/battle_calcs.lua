local H = wesnoth.require "lua/helper.lua"
local AH = wesnoth.dofile "~/add-ons/AI-demos/lua/ai_helper.lua"
local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

local battle_calcs = {}

function battle_calcs.unit_attack_info(unit, cache)
    -- Return a table containing information about a unit's attack-related properties
    -- The result can be cached if variable 'cache' is given
    -- This is done in order to avoid duplication of slow processes, such as access to unit.__cfg

    -- Return table has sub-tables:
    --  - attacks: the attack tables from unit.__cfg
    --  - resist_mod: resistance modifiers (multiplicative factors) index by attack type
    --  - alignment: just that

    -- Set up a cache index.  We use id+max_hitpoints+side, since the
    -- unit can level up.  Side is added to avoid the problem of MP leaders sometimes having
    -- the same id when the game is started from the command-line
    local cind = 'UI-' .. unit.id .. unit.max_hitpoints .. unit.side
    --print(cind)

    -- If cache for this unit exists, return it
    if cache and cache[cind] then
        return cache[cind]
    end

    -- Otherwise collect the information
    local unit_cfg = unit.__cfg
    local unit_info = {
        attacks = {},
        resist_mod = {},
        alignment = unit_cfg.alignment
    }
    for attack in H.child_range(unit_cfg, 'attack') do
        -- Extract information for specials; we do this first because some
        -- custom special might have the same name as one of the default scalar fields
        local a = {}
        for special in H.child_range(attack, 'specials') do
            for i,sp in ipairs(special) do
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
        end

        -- Now extract the scalar (string and number) values from attack
        for k,v in pairs(attack) do
            if (type(v) == 'number') or (type(v) == 'string') then
                a[k] = v
            end
        end

        table.insert(unit_info.attacks, a)
    end

    local attack_types = { "arcane", "blade", "cold", "fire", "impact", "pierce" }
    for i,at in ipairs(attack_types) do
        unit_info.resist_mod[at] = wesnoth.unit_resistance(unit, at) / 100.
    end

    -- If we're caching, add this to 'cache'
    if cache then cache[cind] = unit_info end

    return unit_info
end

function battle_calcs.strike_damage(attacker, defender, att_weapon, def_weapon, cache)
    -- Return the single strike damage of an attack by 'attacker' on 'defender' with 'weapon' for both combatants
    -- Also returns the other information about the attack (since we're accessing the information already anyway)
    -- Here, 'weapon' is the weapon number in Lua counts, i.e., counts start at 1
    -- If def_weapon = 0, return 0 for defender damage
    -- This can be used for defenders that do not have the right kind of weapon, or if
    -- only the attacker damage is of interest
    --
    -- 'cache' can be given to cache strike damage and to pass through to battle_calcs.unit_attack_info()

    -- Set up a cache index.  We use id+max_hitpoints+side for each unit, since the
    -- unit can level up.  Side is added to avoid the problem of MP leaders sometimes having
    -- the same id when the game is started from the command-line
    local cind = 'SD-' .. attacker.id .. attacker.max_hitpoints .. attacker.side
    cind = cind .. 'x' .. defender.id .. defender.max_hitpoints .. defender.side
    cind = cind .. '-' .. att_weapon .. 'x' .. def_weapon
    --print(cind)

    -- If cache for this unit exists, return it
    if cache and cache[cind] then
        return cache[cind].att_damage, cache[cind].def_damage, cache[cind].att_attack, cache[cind].def_attack
    end

    -- If not cached, calculate the damage
    local attacker_info = battle_calcs.unit_attack_info(attacker, cache)
    local defender_info = battle_calcs.unit_attack_info(defender, cache)

    -- Attacker base damage
    local att_damage = attacker_info.attacks[att_weapon].damage

    -- Opponent resistance modifier
    local att_multiplier = defender_info.resist_mod[attacker_info.attacks[att_weapon].type]

    -- TOD modifier
    if (attacker_info.alignment ~= 'neutral') then
        local lawful_bonus = wesnoth.get_time_of_day().lawful_bonus
        if (lawful_bonus ~= 0) then
            if (attacker_info.alignment == 'lawful') then
                att_multiplier = att_multiplier * (1 + lawful_bonus / 100.)
            else
                att_multiplier = att_multiplier * (1 - lawful_bonus / 100.)
            end
        end
    end

    -- Now do all this for the defender, if def_weapon ~= 0
    local def_damage, def_multiplier = 0, 1.
    if (def_weapon ~= 0) then
        -- Defender base damage
        def_damage = defender_info.attacks[def_weapon].damage

        -- Opponent resistance modifier
        def_multiplier = attacker_info.resist_mod[defender_info.attacks[def_weapon].type]

        -- TOD modifier
        if (defender_info.alignment ~= 'neutral') then
            local lawful_bonus = wesnoth.get_time_of_day().lawful_bonus
            if (lawful_bonus ~= 0) then
                if (defender_info.alignment == 'lawful') then
                    def_multiplier = def_multiplier * (1 + lawful_bonus / 100.)
                else
                    def_multiplier = def_multiplier * (1 - lawful_bonus / 100.)
                end
            end
        end

    end

    -- Take 'charge' into account
    if attacker_info.attacks[att_weapon].charge then
        att_damage = att_damage * 2
        def_damage = def_damage * 2
    end

    -- Rounding of .5 values is done differently depending on whether the
    -- multiplier is greater or smaller than 1
    if (att_multiplier > 1) then
        att_damage = H.round(att_damage * att_multiplier - 0.001)
    else
        att_damage = H.round(att_damage * att_multiplier + 0.001)
    end

    if (def_weapon ~= 0) then
        if (def_multiplier > 1) then
            def_damage = H.round(def_damage * def_multiplier - 0.001)
        else
            def_damage = H.round(def_damage * def_multiplier + 0.001)
        end
    end

    -- If we're caching, add this to 'cache'
    if cache then
        cache[cind] = {
            att_damage = att_damage,
            def_damage = def_damage,
            att_attack = attacker_info.attacks[att_weapon],
            def_attack = defender_info.attacks[def_weapon]
        }
    end

    return att_damage, def_damage, attacker_info.attacks[att_weapon], defender_info.attacks[def_weapon]
end

function battle_calcs.best_weapons(attacker, defender, cache)
    -- Return the number of the best weapons for attacker and defender
    -- Ideally, we would do a full attack_rating here for all combinations,
    -- but that would take too long.  So we simply define the best weapons
    -- as those that has the biggest difference between
    -- damage done and damage received (the latter divided by 2)
    -- Returns 0 if defender does not have a weapon for this range
    --
    -- 'cache' can be given to cache best weapons

    -- Set up a cache index.  We use id+max_hitpoints+side for each unit, since the
    -- unit can level up.  Side is added to avoid the problem of MP leaders sometimes having
    -- the same id when the game is started from the command-line
    local cind = 'BW-' .. attacker.id .. attacker.max_hitpoints .. attacker.side
    cind = cind .. 'x' .. defender.id .. defender.max_hitpoints .. defender.side
    --print(cind)

    -- If cache for this unit exists, return it
    if cache and cache[cind] then
        return cache[cind].best_att_weapon, cache[cind].best_def_weapon
    end

    local attacker_info = battle_calcs.unit_attack_info(attacker, cache)
    local defender_info = battle_calcs.unit_attack_info(defender, cache)

    -- Best attacker weapon
    local max_rating, best_att_weapon, best_def_weapon = -9e99, 0, 0
    for i,att_weapon in ipairs(attacker_info.attacks) do
        local att_damage = battle_calcs.strike_damage(attacker, defender, i, 0, cache)

        local max_def_rating, tmp_best_def_weapon = -9e99, 0
        for j,def_weapon in ipairs(defender_info.attacks) do
            if (def_weapon.range == att_weapon.range) then
                local def_damage = battle_calcs.strike_damage(defender, attacker, j, 0, cache)
                local def_rating = def_damage * def_weapon.number
                if (def_rating > max_def_rating) then
                    max_def_rating, tmp_best_def_weapon = def_rating, j
                end
            end
        end

        local rating = att_damage * att_weapon.number
        if (max_def_rating > -9e99) then rating = rating - max_def_rating / 2. end
        --print(i, rating, att_damage, att_weapon.number, best_def_weapon, tmp_best_def_weapon)

        if (rating > max_rating) then
            max_rating, best_att_weapon, best_def_weapon = rating, i, tmp_best_def_weapon
        end
    end
    --print('Best attacker/defender weapon:', best_att_weapon, best_def_weapon)

    -- If we're caching, add this to 'cache'
    if cache then
        cache[cind] = { best_att_weapon = best_att_weapon, best_def_weapon = best_def_weapon }
    end

    return best_att_weapon, best_def_weapon
end

function battle_calcs.add_next_strike(cfg, arr, n_att, n_def, att_strike, hit_miss_counts, hit_miss_str)
    -- Recursive function that sets up the sequences of strikes (misses and hits)
    -- Each call corresponds to one strike of one of the combattants and can be
    -- either miss (value 0) or hit (1)
    --
    -- Inputs:
    -- - cfg: config table with sub-tables att/def for the attacker/defender with the following fields:
    --   - strikes: total number of strikes
    --   - max_hits: maximum number of hits the unit can survive
    --   - firststrike: set to true if attack has firststrike special
    -- - arr: an empty array that will hold the output table
    -- - Other parameters of for recursive use only and are initialized below

    -- On the first call of this function, initialize variables
    -- Counts for hits/misses by both units:
    --  - Indices 1 & 2: hit/miss for attacker
    --  - Indices 3 & 4: hit/miss for defender
    hit_miss_counts = hit_miss_counts or { 0, 0, 0, 0 }
    hit_miss_str = hit_miss_str or ''  -- string with the hit/miss sequence; for visualization only

    -- Strike counts
    --  - n_att/n_def = number of strikes taken by attacker/defender
    --  - att_strike: if true, it's the attacker's turn, otherwise it's the defender's turn
    if (not n_att) then
        if cfg.def.firststrike and (not cfg.att.firststrike) then
            n_att = 0
            n_def = 1
            att_strike = false
        else
            n_att = 1
            n_def = 0
            att_strike = true
        end
    else
        if att_strike then
            if (n_def < cfg.def.strikes) then
                n_def = n_def + 1
                att_strike = false
            else
                n_att = n_att + 1
            end
        else
            if (n_att < cfg.att.strikes) then
                n_att = n_att + 1
                att_strike = true
            else
                n_def = n_def + 1
            end
        end
    end

    -- Create both a hit and a miss
    for i = 0,1 do  -- 0:miss, 1: hit
        -- hit/miss counts and string for this call
        local tmp_hmc = AH.table_copy(hit_miss_counts)
        local tmp_hmstr = ''

        -- Flag whether the opponent was killed by this strike
        local killed_opp = false  -- Defaults to falso
        if att_strike then
            tmp_hmstr = hit_miss_str .. i  -- attacker hit/miss in string: 0 or 1
            tmp_hmc[i+1] = tmp_hmc[i+1] + 1  -- Increment hit/miss counts
            -- Set variable if opponent was killed:
            if (tmp_hmc[2] > cfg.def.max_hits) then killed_opp = true end
        -- Even values of n are strikes by the defender
        else
            tmp_hmstr = hit_miss_str .. (i+2)  -- defender hit/miss in string: 2 or 3
            tmp_hmc[i+3] = tmp_hmc[i+3] + 1  -- Increment hit/miss counts
            -- Set variable if opponent was killed:
            if (tmp_hmc[4] > cfg.att.max_hits) then killed_opp = true end
        end

        -- If we've reached the total number of strikes, add this hit/miss combination to table,
        -- but only if the opponent wasn't killed, as that would end the battle
        if (n_att + n_def < cfg.att.strikes + cfg.def.strikes) and (not killed_opp) then
            battle_calcs.add_next_strike(cfg, arr, n_att, n_def, att_strike, tmp_hmc, tmp_hmstr)
        -- Otherwise, call the next recursion level
        else
            --print(tmp_hmstr)
            table.insert(arr, { hit_miss_str = tmp_hmstr, hit_miss_counts = tmp_hmc })
        end
    end
end

function battle_calcs.battle_outcome_coefficients(cfg, cache)
    -- Determine the coefficients needed to calculate the hitpoint probability distribution
    -- of a given battle
    -- Inputs:
    -- - cfg: config table with sub-tables att/def for the attacker/defender with the following fields:
    --   - strikes: total number of strikes
    --   - max_hits: maximum number of hits the unit can survive
    --   - firststrike: whether the unit has firststrike weapon special on this attack
    -- The result can be cached if variable 'cache' is given
    --
    -- Output: table with the coefficients needed to calculate the distribution for both attacker and defender
    -- First index: number of hits landed on the defender.  Each of those contains an array of
    -- coefficient tables, of format:
    -- { num = value, am = value, ah = value, dm = value, dh = value }
    -- This gives one term in a sum of form:
    -- num * ahp^ah * (1-ahp)^am * dhp^dh * (1-dhp)^dm
    -- where ahp is the probability that the attacker will land a hit
    -- and dhp is the same for the defender
    -- Terms that have exponents of 0 are omitted


    -- Set up the cache id
    local cind = 'coeff-' .. cfg.att.strikes .. '-' .. cfg.att.max_hits
    if cfg.att.firststrike then cind = cind .. 'fs' end
    cind = cind .. 'x' .. cfg.def.strikes .. '-' .. cfg.def.max_hits
    if cfg.def.firststrike then cind = cind .. 'fs' end
    --print(cind)

    -- If cache for this unit exists, return it
    if cache and cache[cind] then
        return cache[cind].coeffs_att, cache[cind].coeffs_def
    end

    -- Get the hit/miss counts for the battle
    local hit_miss_counts = {}
    battle_calcs.add_next_strike(cfg, hit_miss_counts)
    --DBG.dbms(hit_miss_counts)

    -- We first calculate the coefficients for the defender HP distribution
    -- so this is sorted by the number of hits the attacker lands

    -- counts is an array 4 layers deep, where the indices are the number of misses/hits
    -- are the indices in order attacker miss, attacker hit, defender miss, defender hit
    -- This is so that they can be grouped by number of attacker hits/misses, for
    -- subsequent simplification
    -- The element value is number of times we get the given combination of hits/misses
    local counts = {}
    for i,c in ipairs(hit_miss_counts) do
        local i1 = c.hit_miss_counts[1]
        local i2 = c.hit_miss_counts[2]
        local i3 = c.hit_miss_counts[3]
        local i4 = c.hit_miss_counts[4]
        if not counts[i1] then counts[i1] = {} end
        if not counts[i1][i2] then counts[i1][i2] = {} end
        if not counts[i1][i2][i3] then counts[i1][i2][i3] = {} end
        counts[i1][i2][i3][i4] = (counts[i1][i2][i3][i4] or 0) + 1
    end
    --DBG.dbms(counts)

    local coeffs_def = {}
    for am,v1 in pairs(counts) do  -- attacker miss count
        for ah,v2 in pairs(v1) do  -- attacker hit count
            -- Set up the exponent coefficients for attacker hits/misses
        local exp = { }  -- Array for an individual set of coefficients
            -- Only populate those indices that have exponents > 0
            if (am > 0) then exp.am = am end
        if (ah > 0) then exp.ah = ah end

            -- We combine results by testing whether they produce the same sum
            -- with two very different hit probabilities, hp1 = 0.6, hp2 = 0.137
            -- This will only happen is the coefficients add up to multiples of 1
            local sum1, sum2 = 0,0
            local hp1, hp2 = 0.6, 0.137
            for dm,v3 in pairs(v2) do  -- defender miss count
                for dh,num in pairs(v3) do  -- defender hit count
                    --print(am, ah, dm, dh, num)
                    sum1 = sum1 + num * hp1^dh * (1-hp1)^dm
                    sum2 = sum2 + num * hp2^dh * (1-hp2)^dm
                end
            end
            --print('sum:', sum1, sum2, ah)

            -- Now, coefficients are set up for each value of total hits by attacker
            -- This holds all the coefficients that need to be added to get the propability
            -- of the defender receiving this number of hits
            if (not coeffs_def[ah]) then coeffs_def[ah] = {} end

            -- If sum1 and sum2 are equal, that means all the defender probs added up to 1, or
        -- multiple thereof, which means the can all be combine in the calculation
            if (math.abs(sum1 - sum2) < 1e-9) then
                exp.num = sum1
            table.insert(coeffs_def[ah], exp)
            -- If not, the defender probs don't add up to something nice and all
            -- need to be calculated one by one
            else
                for dm,v3 in pairs(v2) do  -- defender miss count
                    for dh,num in pairs(v3) do  -- defender hit count
                        local tmp_exp = AH.table_copy(exp)
                        tmp_exp.num = num
                        if (dm > 0) then tmp_exp.dm = dm end
                        if (dh > 0) then tmp_exp.dh = dh end
                        table.insert(coeffs_def[ah], tmp_exp)
                    end
                end
            end
        end
    end
    --DBG.dbms(coeffs_def)

    -- Now we do the same for the HP distribution of the attacker,
    -- which means everything needs to be sorted by defender hits
    local counts = {}
    for i,c in ipairs(hit_miss_counts) do
    local i1 = c.hit_miss_counts[3] -- note that the order here is different from above
        local i2 = c.hit_miss_counts[4]
        local i3 = c.hit_miss_counts[1]
    local i4 = c.hit_miss_counts[2]
        if not counts[i1] then counts[i1] = {} end
        if not counts[i1][i2] then counts[i1][i2] = {} end
        if not counts[i1][i2][i3] then counts[i1][i2][i3] = {} end
        counts[i1][i2][i3][i4] = (counts[i1][i2][i3][i4] or 0) + 1
    end
    --DBG.dbms(counts)

    local coeffs_att = {}
    for dm,v1 in pairs(counts) do  -- defender miss count
        for dh,v2 in pairs(v1) do  -- defender hit count
            -- Set up the exponent coefficients for attacker hits/misses
            local exp = { }  -- Array for an individual set of coefficients
            -- Only populate those indices that have exponents > 0
            if (dm > 0) then exp.dm = dm end
            if (dh > 0) then exp.dh = dh end

            -- We combine results by testing whether they produce the same sum
            -- with two very different hit probabilities, hp1 = 0.6, hp2 = 0.137
            -- This will only happen is the coefficients add up to multiples of 1
            local sum1, sum2 = 0,0
            local hp1, hp2 = 0.6, 0.137
        for am,v3 in pairs(v2) do  -- attacker miss count
                for ah,num in pairs(v3) do  -- attacker hit count
                    --print(am, ah, dm, dh, num)
                sum1 = sum1 + num * hp1^ah * (1-hp1)^am
                    sum2 = sum2 + num * hp2^ah * (1-hp2)^am
                end
            end
            --print('sum:', sum1, sum2, dh)

            -- Now, coefficients are set up for each value of total hits by attacker
            -- This holds all the coefficients that need to be added to get the propability
            -- of the defender receiving this number of hits
            if (not coeffs_att[dh]) then coeffs_att[dh] = {} end

            -- If sum1 and sum2 are equal, that means all the defender probs added up to 1, or
            -- multiple thereof, which means the can all be combine in the calculation
            if (math.abs(sum1 - sum2) < 1e-9) then
                exp.num = sum1
                table.insert(coeffs_att[dh], exp)
            -- If not, the defender probs don't add up to something nice and all
            -- need to be calculated one by one
            else
                for am,v3 in pairs(v2) do  -- defender miss count
                    for ah,num in pairs(v3) do  -- defender hit count
                        local tmp_exp = AH.table_copy(exp)
                    tmp_exp.num = num
                        if (am > 0) then tmp_exp.am = am end
                        if (ah > 0) then tmp_exp.ah = ah end
                    table.insert(coeffs_att[dh], tmp_exp)
                    end
                end
            end
        end
    end

    -- The probability for the number of hits with the most terms can be skipped
    -- and 1-sum(other_terms) can be used instead.  Set a flag for which term to skip
    local max_number, biggest_equation = 0, -1
    for hits,v in pairs(coeffs_att) do
        local number = 0
        for i,c in pairs(v) do number = number + 1 end
        if (number > max_number) then
            max_number, biggest_equation = number, hits
        end
    end
    coeffs_att[biggest_equation].skip = true

    local max_number, biggest_equation = 0, -1
    for hits,v in pairs(coeffs_def) do
        local number = 0
        for i,c in pairs(v) do number = number + 1 end
        if (number > max_number) then
            max_number, biggest_equation = number, hits
        end
    end
    coeffs_def[biggest_equation].skip = true
    --DBG.dbms(coeffs_def)

    -- If we're caching, add this to 'cache'
    if cache then cache[cind] = { coeffs_att = coeffs_att, coeffs_def = coeffs_def } end

    return coeffs_att, coeffs_def
end

function battle_calcs.print_coefficients()
    -- Print out the set of coefficients for a given number of attacker and defender strikes
    -- Also print numerical values for a given hit probability

    -- Configure these values at will
    local attacker_strikes, defender_strikes = 3, 3  -- number of strikes
    local att_hit_prob, def_hit_prob = 0.8, 0.4  -- probability of landing a hit attacker/defender
    local attacker_coeffs = true -- attacker coefficients if set to true, defender coefficients otherwise
    local defender_firststrike, attacker_firststrike = true, false

    -- Go through all combinations of maximum hits either attacker or defender can survive
    -- Note how this has to be crossed between ahits and defender_strikes and vice versa
    for ahits = defender_strikes,0,-1 do
        for dhits = attacker_strikes,0,-1 do
            -- Get the coefficients for this case
            local cfg = {
                att = { strikes = attacker_strikes, max_hits = ahits, firststrike = attacker_firststrike },
                def = { strikes = defender_strikes, max_hits = dhits, firststrike = defender_firststrike }
            }

            local coeffs, dummy = {}, {}
            if attacker_coeffs then
                coeffs = battle_calcs.battle_outcome_coefficients(cfg)
            else
                dummy, coeffs = battle_calcs.battle_outcome_coefficients(cfg)
            end

            print()
            print('Attacker: ' .. cfg.att.strikes .. ' strikes, can survive ' .. cfg.att.max_hits .. ' hits')
            print('Defender: ' .. cfg.def.strikes .. ' strikes, can survive ' .. cfg.def.max_hits .. ' hits')
            print('Chance of hits on defender: ')

            -- The first indices of coeffs are the possible number of hits the attacker can land on the defender
            for hits = 0,#coeffs do
                local hit_prob = 0.  -- probability for this number of hits
                local str = ''  -- output string

                local combs = coeffs[hits]  -- the combinations of coefficients to be evaluated
                for i,exp in ipairs(combs) do  -- exp: exponents (and factor) for a set
                    local prob = exp.num  -- probability for this set
                    str = str .. exp.num
                    if exp.am then
                       prob = prob * (1 - att_hit_prob) ^ exp.am
                       str = str .. ' pma^' .. exp.am
                    end
                    if exp.ah then
                        prob = prob * att_hit_prob ^ exp.ah
                        str = str .. ' pha^' .. exp.ah
                    end
                    if exp.dm then
                        prob = prob * (1 - def_hit_prob) ^ exp.dm
                        str = str .. ' pmd^' .. exp.dm
                    end
                    if exp.dh then
                       prob = prob * def_hit_prob ^ exp.dh
                        str = str .. ' phd^' .. exp.dh
                    end

                    hit_prob = hit_prob + prob  -- total probabilty for this number of hits landed
                    if (i ~= #combs) then str = str .. '  +  ' end
                end

                local skip_str = ''
                if combs.skip then skip_str = ' (skip)' end

                print(hits .. skip_str .. ':  ' .. str)
                print('      = ' .. hit_prob)
            end
        end
    end
end

function battle_calcs.hp_distribution(coeffs, att_hit_prob, def_hit_prob, starting_hp, damage, opp_attack)
    -- Multiply out the coefficients from battle_calcs.battle_outcome_coefficients()
    -- For a given attacker and defender hit/miss probability
    -- Also needed: the starting HP for the unit and the damage done by the opponent
    -- and the opponent attack information (opp_attack)

    local stats  = { hp_chance = {}, average_hp = 0 }
    local skip_hp, skip_prob = -1, 1
    for hits = 0,#coeffs do
        local hp = starting_hp - hits * damage
        if (hp < 0) then hp = 0 end

        -- Calculation of the outcome with the most terms can be skipped
        if coeffs[hits].skip then
            skip_hp = hp
        else
            local hp_prob = 0.  -- probability for this number of hits
            for i,exp in ipairs(coeffs[hits]) do  -- exp: exponents (and factor) for a set
                local prob = exp.num  -- probability for this set
                if exp.am then prob = prob * (1 - att_hit_prob) ^ exp.am end
                if exp.ah then prob = prob * att_hit_prob ^ exp.ah end
                if exp.dm then prob = prob * (1 - def_hit_prob) ^ exp.dm end
                if exp.dh then prob = prob * def_hit_prob ^ exp.dh end

                hp_prob = hp_prob + prob  -- total probabilty for this number of hits landed
            end

            stats.hp_chance[hp] = hp_prob
            stats.average_hp = stats.average_hp + hp * hp_prob

            -- Also subtract this probability from the total prob. (=1), to get prob. of skipped outcome
            skip_prob = skip_prob - hp_prob
        end
    end

    -- Add in the outcome that was skipped
    stats.hp_chance[skip_hp] = skip_prob
    stats.average_hp = stats.average_hp + skip_hp * skip_prob

    -- And always set hp_chance[0] since it is of such importance in the analysis
    stats.hp_chance[0] = stats.hp_chance[0] or 0

    -- Add poison probability
    if opp_attack and opp_attack.poison then
        stats.poisoned = 1. - stats.hp_chance[starting_hp]
    else
        stats.poisoned = 0
    end

    -- Add slow probability
    if opp_attack and opp_attack.slow then
        stats.slowed = 1. - stats.hp_chance[starting_hp]
    else
        stats.slowed = 0
    end

    return stats
end

function battle_calcs.battle_outcome(attacker, defender, cfg, cache)
    -- Calculate the stats of a combat by attacker vs. defender
    -- cfg: optional input parameters
    --  - att_weapon/def_weapon: attacker/defender weapon number
    --      if not given, get "best" weapon (Note: both must be given, or they will both be determined)
    --  - dst: { x, y }: the attack location; defaults to { attacker.x, attacker. y }

    cfg = cfg or {}

    local dst = cfg.dst or { attacker.x, attacker.y }

    local att_weapon, def_weapon = 0, 0
    if (not cfg.att_weapon) or (not cfg.def_weapon) then
        att_weapon, def_weapon = battle_calcs.best_weapons(attacker, defender, cache)
    else
        att_weapon, def_weapon = cfg.att_weapon, cfg.def_weapon
    end
    --print('Weapons:', att_weapon, def_weapon)

    -- Collect all the information needed for the calculation
    -- Strike damage and numbers
    local att_damage, def_damage, att_attack, def_attack =
        battle_calcs.strike_damage(attacker, defender, att_weapon, def_weapon, cache)
    --print(att_damage,def_damage)

    -- Take swarm into account
    local att_strikes, def_strikes = att_attack.number, 0
    if (def_damage > 0) then
        def_strikes = def_attack.number
    end
    --print(att_strikes, def_strikes)

    if att_attack.swarm then
        att_strikes = math.floor(att_strikes * attacker.hitpoints / attacker.max_hitpoints)
    end
    if def_attack and def_attack.swarm then
        def_strikes = math.floor(def_strikes * defender.hitpoints / defender.max_hitpoints)
    end

    -- Maximum number of hits that either unit can survive
    local att_max_hits = math.floor((attacker.hitpoints - 1) / def_damage)
    if (att_max_hits > def_strikes) then att_max_hits = def_strikes end
    local def_max_hits = math.floor((defender.hitpoints - 1) / att_damage)
    if (def_max_hits > att_strikes) then def_max_hits = att_strikes end

    -- Probability of landing a hit
    local att_hit_prob = wesnoth.unit_defense(defender, wesnoth.get_terrain(defender.x, defender.y)) / 100.
    local def_hit_prob = wesnoth.unit_defense(attacker, wesnoth.get_terrain(dst[1], dst[2])) / 100.

    -- Magical: attack and defense, and under all circumstances
    if att_attack.magical then att_hit_prob = 0.7 end
    if def_attack and def_attack.magical then def_hit_prob = 0.7 end

    -- Marksman: attack only, and only if terrain defense is less
    if att_attack.marksman and (att_hit_prob < 0.6) then
        att_hit_prob = 0.6
    end
    --print(att_damage, att_strikes, att_max_hits, att_hit_prob)
    --print(def_damage, def_strikes, def_max_hits, def_hit_prob)

    -- Get the coefficients for this kind of combat
    local def_firstrike = false
    if def_attack and def_attack.firststrike then def_firstrike = true end

    local cfg = {
        att = { strikes = att_strikes, max_hits = att_max_hits, firststrike = att_attack.firststrike },
        def = { strikes = def_strikes, max_hits = def_max_hits, firststrike = def_firstrike }
    }
    local att_coeffs, def_coeffs = battle_calcs.battle_outcome_coefficients(cfg, cache)

    -- And multiply out the factors
    -- Note that att_hit_prob, def_hit_prob need to be in that order for both calls
    local att_stats = battle_calcs.hp_distribution(att_coeffs, att_hit_prob, def_hit_prob, attacker.hitpoints, def_damage, def_attack)
    local def_stats = battle_calcs.hp_distribution(def_coeffs, att_hit_prob, def_hit_prob, defender.hitpoints, att_damage, att_attack)
    --DBG.dbms(att_stats)
    --DBG.dbms(def_stats)

    return att_stats, def_stats
end

function battle_calcs.simulate_combat_fake()
    -- A function to return a fake simulate_combat result
    -- Used to test how long simulate_combat takes
    -- It doesn't need any arguments -> can be called with the arguments of other simulate_combat functions
    local att_stats, def_stats = { hp_chance = {} }, { hp_chance = {} }

    for i = 0,38 do att_stats.hp_chance[i], def_stats.hp_chance[i] = 0, 0 end

    att_stats.hp_chance[21], att_stats.hp_chance[23], att_stats.hp_chance[25], att_stats.hp_chance[27] = 0.125, 0.375, 0.375, 0.125
    att_stats.poisoned, att_stats.slowed, att_stats.average_hp = 0.875, 0, 24

    def_stats.hp_chance[0], def_stats.hp_chance[2], def_stats.hp_chance[10] = 0.09, 0.42, 0.49
    def_stats.poisoned, def_stats.slowed, def_stats.average_hp = 0, 0, 1.74

    return att_stats, def_stats
end

function battle_calcs.simulate_combat_loc(attacker, dst, defender, weapon)
    -- Get simulate_combat results for unit 'attacker' attacking unit at 'defender'
    -- when on terrain of same type as that at 'dst', which is of form {x,y}
    -- If 'weapon' is set (to number of attack), use that weapon (starting at 1), otherwise use best weapon

    local attacker_dst = wesnoth.copy_unit(attacker)
    attacker_dst.x, attacker_dst.y = dst[1], dst[2]

    if weapon then
        return wesnoth.simulate_combat(attacker_dst, weapon, defender)
    else
        return wesnoth.simulate_combat(attacker_dst, defender)
    end
end

function battle_calcs.attack_rating(attacker, defender, dst, cfg, cache)
    -- Returns a common (but configurable) rating for attacks
    -- Inputs:
    -- att_stats: attacker stats table
    -- def_stats: defender stats table
    -- attackers: attacker unit table
    -- defender: defender unit table
    -- dst: the attack location in form { x, y }
    -- cfg: table of optional inputs and configurable rating parameters
    --  Optional inputs:
    --    - att_stats, def_stats: if given, use these stats, otherwise calculate them here
    --        Note: these are calculated in combination, that is they either both need to be passed or both be omitted
    --    - att_weapon/def_weapon: the attacker/defender weapon to be used if calculating battle stats here
    --        This parameter is meaningless (unused) if att_stats/def_stats are passed
    --        Defaults to weapon that does most damage to the opponent
    --        Note: as with the stats, they either both need to be passed or both be omitted
    -- cache: cache table to be passed to battle_calcs.battle_outcome
    --
    -- Returns:
    --   - Overall rating for the attack or attack combo
    --   - Defender rating: not additive for attack combos; needs to be calculated for the
    --     defender stats of the last attack in a combo (that works for everything except
    --     the rating whether the defender is about to level in the attack combo)
    --   - Attacker rating: this one is split up into two terms:
    --     - a term that is additive for individual attacks in a combo
    --     - a term that needs to be average for the individual attacks in a combo
    --   - att_stats, def_stats: useful if they were calculated here, rather than passed down

    cfg = cfg or {}

    -- Set up the config parameters for the rating
    local defender_starting_damage_weight = defender_starting_damage_weight or 0.33
    local xp_weight = cfg.xp_weight or 0.25
    local level_weight = cfg.level_weight or 1.0
    local defender_level_weight = cfg.defender_level_weight or 1.0
    local distance_leader_weight = cfg.distance_leader_weight or 0.02
    local defense_weight = cfg.defense_weight or 0.5
    local occupied_hex_penalty = cfg.occupied_hex_penalty or -0.01
    local own_value_weight = cfg.own_value_weight or 1.0

    -- Get att_stats, def_stats
    -- If they are passed in cfg, use those
    local att_stats, def_stats = {}, {}
    if (not cfg.att_stats) or (not cfg.def_stats) then
        -- If cfg specifies the weapons use those, otherwise use "best" weapons
        -- In the latter case, cfg.???_weapon will be nil, which will be passed on
        local battle_cfg = { att_weapon = cfg.att_weapon, def_weapon = cfg.def_weapon, dst = dst }
        att_stats,def_stats = battle_calcs.battle_outcome(attacker, defender, battle_cfg, cache)
    else
        att_stats, def_stats = cfg.att_stats, cfg.def_stats
    end

    -- We also need the leader (well, the location at least)
    -- because if there's no other difference, prefer location _between_ the leader and the defender
    local leader = wesnoth.get_units { side = attacker.side, canrecruit = 'yes' }[1]

    ------ All the attacker contributions: ------
    --print('Attacker:', attacker.id, att_stats.average_hp)

    -- Add up rating for the attacking unit
    -- We add this up in units of fraction of max_hitpoints
    -- It is multiplied by unit cost later, to get a gold equivalent value

    -- Average damage to unit is negative rating
    local damage = attacker.hitpoints - att_stats.average_hp
    -- Count poisoned as additional 8 HP damage times probability of being poisoned
    if (att_stats.poisoned ~= 0) then
        damage = damage + 8 * (att_stats.poisoned - att_stats.hp_chance[0])
    end
    -- Count slowed as additional 6 HP damage times probability of being slowed
    if (att_stats.slowed ~= 0) then
        damage = damage + 6 * (att_stats.slowed - att_stats.hp_chance[0])
    end

    -- Fraction damage (= fractional value of the unit)
    local value_fraction = - damage / attacker.max_hitpoints
    --print('  value_fraction damage:', value_fraction)

    -- Additional, subtract the chance to die, in order to (de)emphasize units that might die
    value_fraction = value_fraction - att_stats.hp_chance[0]
    --print('  value_fraction damage + CTD:', value_fraction)

    -- Being closer to leveling is good (this makes AI prefer units with lots of XP)
    local xp_bonus = 1. - (attacker.max_experience - attacker.experience) / attacker.max_experience
    value_fraction = value_fraction + xp_bonus * xp_weight
    --print('  XP bonus:', xp_bonus, value_fraction)

    -- In addition, potentially leveling up in this attack is a huge bonus,
    -- proportional to the chance of it happening and the chance of not dying itself
    local level_bonus = 0.
    local defender_level = wesnoth.unit_types[defender.type].level
    if (attacker.max_experience - attacker.experience <= defender_level) then
        level_bonus = 1. - att_stats.hp_chance[0]
    else
        if (attacker.max_experience - attacker.experience <= defender_level * 8) then
            level_bonus = (1. - att_stats.hp_chance[0]) * def_stats.hp_chance[0]
        end
    end
    value_fraction = value_fraction + level_bonus * level_weight
    --print('  level bonus:', level_bonus, value_fraction)

    -- Get a very small bonus for hexes in between defender and AI leader
    -- 'relative_distances' is larger for attack hexes closer to the side leader (possible values: -1 .. 1)
    local relative_distances =
        H.distance_between(defender.x, defender.y, leader.x, leader.y)
        - H.distance_between(dst[1], dst[2], leader.x, leader.y)
    value_fraction = value_fraction + relative_distances * distance_leader_weight
    --print('  relative_distances:', relative_distances, value_fraction)

    -- Add a very small penalty for attack hexes occupied by other units
    -- Note: it must be checked previously that the unit on the hex can move away
    if (dst[1] ~= attacker.x) or (dst[2] ~= attacker.y) then
        if wesnoth.get_unit(dst[1], dst[2]) then
            value_fraction = value_fraction + occupied_hex_penalty
        end
    end
    --print('  value_fraction after occupied_hex_penalty:', value_fraction)

    -- If attack is from a village, we count that as a 10 HP bonus
    local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(dst[1], dst[2])).village
    if is_village then
        value_fraction = value_fraction + 10 / attacker.max_hitpoints
    end
    --print('  value_fraction after village bonus:', value_fraction)

    -- Now convert this into gold-equivalent value
    local attacker_rating = value_fraction * wesnoth.unit_types[attacker.type].cost
    --print('-> attacker rating:', attacker_rating)

    ------ We also get a terrain defense rating, but this cannot simply be added to the rest ------
    local attacker_defense = - wesnoth.unit_defense(attacker, wesnoth.get_terrain(dst[1], dst[2])) / 100.
    attacker_defense = attacker_defense * defense_weight
    local attacker_rating_av = attacker_defense * wesnoth.unit_types[attacker.type].cost
    --print('-> attacker rating for averaging:', attacker_rating_av)

    ------ Now (most of) the same for the defender ------
    --print('Defender:', defender.id, def_stats.average_hp)

    -- Average damage to defender is positive rating
    local damage = defender.hitpoints - def_stats.average_hp
    -- Count poisoned as additional 8 HP damage times probability of being poisoned
    if (def_stats.poisoned ~= 0) then
        damage = damage + 8 * (def_stats.poisoned - def_stats.hp_chance[0])
    end
    -- Count slowed as additional 6 HP damage times probability of being slowed
    if (def_stats.slowed ~= 0) then
        damage = damage + 6 * (def_stats.slowed - def_stats.hp_chance[0])
    end

    -- Fraction damage (= fractional value of the unit)
    local value_fraction = damage / defender.max_hitpoints
    --print('  defender value_fraction damage:', value_fraction)

    -- Additional, add the chance to kill, in order to emphasize enemies we might be able to kill
    value_fraction = value_fraction + def_stats.hp_chance[0]
    --print('  defender value_fraction damage + CTD:', value_fraction)

    -- And prefer to attack already damage enemies
    local defender_starting_damage_fraction = (defender.max_hitpoints - defender.hitpoints) / defender.max_hitpoints
    value_fraction = value_fraction + defender_starting_damage_fraction * defender_starting_damage_weight
    --print('  defender_starting_damage_fraction:', defender_starting_damage_fraction, value_fraction)

    -- Being closer to leveling is good, we want to get rid of those enemies first
    local xp_bonus = 1. - (defender.max_experience - defender.experience) / defender.max_experience
    value_fraction = value_fraction + xp_bonus * xp_weight
    --print('  defender XP bonus:', xp_bonus, value_fraction)

    -- In addition, potentially leveling up in this attack is a huge bonus,
    -- proportional to the chance of it happening and the chance of not dying itself
    local defender_level_penalty = 0.
    local attacker_level = wesnoth.unit_types[attacker.type].level
    if (defender.max_experience - defender.experience <= attacker_level) then
        defender_level_penalty = 1. - def_stats.hp_chance[0]
    else
        if (defender.max_experience - defender.experience <= attacker_level * 8) then
            defender_level_penalty = (1. - def_stats.hp_chance[0]) * att_stats.hp_chance[0]
        end
    end
    value_fraction = value_fraction + defender_level_penalty * defender_level_weight
    --print('  defender level penalty:', defender_level_penalty, value_fraction)

    -- If defender is on a village, add a bonus rating (we want to get rid of those preferentially)
    -- So yes, this is positive, even though it's a plus for the defender
    local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(defender.x, defender.y)).village
    if is_village then
        value_fraction = value_fraction + 10 / attacker.max_hitpoints
    end
    --print('  value_fraction after village bonus:', value_fraction)

    -- Now convert this into gold-equivalent value
    local defender_rating = value_fraction * wesnoth.unit_types[defender.type].cost
    --print('-> defender rating:', defender_rating)

    -- Finally apply factor of own unit weight to defender unit weight
    attacker_rating = attacker_rating * own_value_weight
    attacker_rating_av = attacker_rating_av * own_value_weight

    local rating = defender_rating + attacker_rating + attacker_rating_av
    --print('---> rating:', rating)

    return rating, defender_rating, attacker_rating, attacker_rating_av, att_stats, def_stats
end

function battle_calcs.attack_combo_stats(tmp_attackers, tmp_dsts, defender, cache, cache_this_move)
    -- Calculate attack combination outcomes using
    -- tmp_attackers: array of attacker units (this is done so that
    --   the units need not be found here, as likely doing it in the
    --   calling function is more efficient (because of repetition)
    -- tmp_dsts: array of the hexes (format {x, y}) from which the attackers attack
    --   must be in same order as 'attackers'
    -- defender: the unit being attacked
    -- cache: the cache table to be passed through to other battle_calcs functions
    -- cache_this_move: an optional table of pre-calculated attack outcomes
    --   - This is different from the other cache tables used in this file
    --   - This table may only persist for this move (move, not turn !!!), as otherwise too many things change
    --
    -- Return values:
    --   - the rating for this attack combination calculated from battle_calcs.attack_rating() results
    --   - the sorted attackers and dsts arrays
    --   - att_stats: an array of stats for each attacker, in the same order as 'attackers'
    --   - defender combo stats: one set of stats containing the defender stats after the attack combination
    --   - def_stats: an array of defender stats for each individual attack, in the same order as 'attackers'

    cache_this_move = cache_this_move or {}

    --print()
    --print('Defender:', defender.id, defender.x, defender.y)
    --print('Attackers:')
    --for i,a in ipairs(tmp_attackers) do
    --    print('  ' .. a.id, a.x, a.y)
    --end

    -- We first simulate and rate the individual attacks
    local ratings, tmp_attacker_ratings = {}, {}
    local tmp_att_stats, tmp_def_stats = {}, {}
    for i,a in ipairs(tmp_attackers) do
        --print('\n', a.id)
        -- Initialize or use the 'cache_this_move' table
        local defender_ind = defender.x * 1000 + defender.y
        local att_ind = a.x * 1000 + a.y
        local dst_ind = tmp_dsts[i][1] * 1000 + tmp_dsts[i][2]
        if (not cache_this_move[defender_ind]) then cache_this_move[defender_ind] = {} end
        if (not cache_this_move[defender_ind][att_ind]) then cache_this_move[defender_ind][att_ind] = {} end

        if (not cache_this_move[defender_ind][att_ind][dst_ind]) then
            -- Get the base rating
            local base_rating, def_rating, att_rating, att_rating_av, att_stats, def_stats =
                battle_calcs.attack_rating(a, defender, tmp_dsts[i], {}, cache )
            tmp_attacker_ratings[i] = att_rating
            tmp_att_stats[i], tmp_def_stats[i] = att_stats, def_stats
            --print('rating:', base_rating, def_rating, att_rating, att_rating_av)
            --DBG.dbms(att_stats)

            -- But for combos, also want units with highest attack outcome uncertainties to go early
            -- So that we can change our mind in case of unfavorable outcome
            local outcome_variance = 0
            local av = tmp_def_stats[i].average_hp
            local n_outcomes = 0

            for hp,p in pairs(tmp_def_stats[i].hp_chance) do
                if (p > 0) then
                    local dhp_norm = (hp - av) / defender.max_hitpoints * wesnoth.unit_types[defender.type].cost
                    local dvar = p * dhp_norm^2
                    --print(hp,p,av, dvar)
                    outcome_variance = outcome_variance + dvar
                    n_outcomes = n_outcomes + 1
                end
            end
            outcome_variance = outcome_variance / n_outcomes
            --print('outcome_variance', outcome_variance)

            -- Note that this is a variance, not a standard deviations (as in, it's squared),
            -- so it does not matter much for low-variance attacks, but takes on large values for
            -- high variance attacks.  I think that is what we want.
            local rating = base_rating + outcome_variance

            -- If attacker has attack with 'slow' special, it should always go first
            -- Almost, bonus should not be quite as high as a really high CTK
            -- This isn't quite true in reality, but can be refined later
            if AH.has_weapon_special(a, "slow") then
                rating = rating + wesnoth.unit_types[defender.type].cost / 2.
            end

            --print('Final rating', rating, i)
            ratings[i] = { i, rating, base_rating, def_rating, att_rating, att_rating_av }

            -- Now add this attack to the cache_this_move table, so that next time around, we don't have to do this again
            cache_this_move[defender_ind][att_ind][dst_ind] = {
                rating = { -1, rating, base_rating, def_rating, att_rating, att_rating_av },  -- Cannot use { i, rating, ... } here, as 'i' might be different next time
                attacker_ratings = tmp_attacker_ratings[i],
                att_stats = tmp_att_stats[i],
                def_stats = tmp_def_stats[i]
            }
        else
            --print('Stats already exist')
            local tmp_rating = cache_this_move[defender_ind][att_ind][dst_ind].rating
            tmp_rating[1] = i
            ratings[i] = tmp_rating
            tmp_attacker_ratings[i] = cache_this_move[defender_ind][att_ind][dst_ind].attacker_ratings
            tmp_att_stats[i] = cache_this_move[defender_ind][att_ind][dst_ind].att_stats
            tmp_def_stats[i] = cache_this_move[defender_ind][att_ind][dst_ind].def_stats
        end
    end

    -- Now sort all the arrays based on this rating
    -- This will give the order in which the individual attacks are executed
    table.sort(ratings, function(a, b) return a[2] > b[2] end)

    -- Reorder attackers, dsts in this order
    local attackers, dsts, att_stats, def_stats, attacker_ratings = {}, {}, {}, {}, {}
    for i,r in ipairs(ratings) do
        attackers[i], dsts[i] = tmp_attackers[r[1]], tmp_dsts[r[1]]
    end
    -- Only keep the stats/ratings for the first attacker, the rest needs to be recalculated
    att_stats[1], def_stats[1] = tmp_att_stats[ratings[1][1]], tmp_def_stats[ratings[1][1]]
    attacker_ratings[1] = tmp_attacker_ratings[ratings[1][1]]

    tmp_attackers, tmp_dsts, tmp_att_stats, tmp_def_stats, tmp_attacker_ratings = nil, nil, nil, nil, nil
    -- Just making sure that everything worked:
    --print(#attackers, #dsts, #att_stats, #def_stats)
    --for i,a in ipairs(attackers) do print(i, a.id) end
    --DBG.dbms(dsts)
    --DBG.dbms(att_stats)
    --DBG.dbms(def_stats)

    -- Then we go through all the other attacks and calculate the outcomes
    -- based on all the possible outcomes of the previous attacks
    for i = 2,#attackers do
        --print('Attacker', i, attackers[i].id)

        att_stats[i] = { hp_chance = {} }
        def_stats[i] = { hp_chance = {} }

        for hp1,p1 in pairs(def_stats[i-1].hp_chance) do -- Note: need pairs(), not ipairs() !!
            if (hp1 == 0) then
                att_stats[i].hp_chance[attackers[i].hitpoints] =
                    (att_stats[i].hp_chance[attackers[i].hitpoints] or 0) + p1
                def_stats[i].hp_chance[0] = (def_stats[i].hp_chance[0] or 0) + p1
            else
                --print(hp1, p1)
                local org_hp = defender.hitpoints
                defender.hitpoints = hp1
                local ast, dst = battle_calcs.battle_outcome(attackers[i], defender, { dst = dsts[i] } , cache)
                defender.hitpoints = org_hp

                for hp2,p2 in pairs(ast.hp_chance) do
                    att_stats[i].hp_chance[hp2] = (att_stats[i].hp_chance[hp2] or 0) + p1 * p2
                end
                for hp2,p2 in pairs(dst.hp_chance) do
                    def_stats[i].hp_chance[hp2] = (def_stats[i].hp_chance[hp2] or 0) + p1 * p2
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
        for hp,p in pairs(att_stats[i].hp_chance) do av_hp = av_hp + hp*p end
        att_stats[i].average_hp = av_hp
        local av_hp = 0
        for hp,p in pairs(def_stats[i].hp_chance) do av_hp = av_hp + hp*p end
        def_stats[i].average_hp = av_hp
    end
    --DBG.dbms(att_stats)
    --DBG.dbms(def_stats)
    --print('Defender CTK:', def_stats[#attackers].hp_chance[0])

    -- Get the total rating for this attack combo:
    --   = sum of all the attacker ratings and the defender rating with the final def_stats
    -- Rating for first attack exists already
    local def_rating = ratings[1][4]
    local att_rating, att_rating_av = ratings[1][5], ratings[1][6]
    -- but the others need to be calculated with the new stats
    for i = 2,#attackers do
        local cfg = { att_stats = att_stats[i], def_stats = def_stats[i] }
        local r, dr, ar, ar_av = battle_calcs.attack_rating(attackers[i], defender, dsts[i], cfg, cache)
        --print(attackers[i].id, r, dr, ar, ar_av)

        def_rating = dr
        att_rating = att_rating + ar
        att_rating_av = att_rating_av + ar_av
    end
    -- and att_rating_av needs to be averaged rather than summed up
    att_rating_av = att_rating_av / #attackers

    local rating = def_rating + att_rating + att_rating_av
    --print(rating, def_rating, att_rating, att_rating_av)

    return rating, attackers, dsts, att_stats, def_stats[#attackers], def_stats
end

return battle_calcs
