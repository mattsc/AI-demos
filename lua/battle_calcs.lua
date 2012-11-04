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

    -- Set up a unit id.  We use id+type+side for this, since the
    -- unit can level up.  Side is added to avoid the problem of MP leaders sometimes having
    -- the same id when the game is started from the command-line
    local id = unit.id .. unit.type .. unit.side
    --print(id)

    -- If cache for this unit exists, return it
    if cache and cache[id] then
        return cache[id]
    else  -- otherwise collect the information
        local unit_cfg = unit.__cfg
        local unit_info = {
            attacks = {},
            resist_mod = {},
            alignment = unit_cfg.alignment
        }
        for attack in H.child_range(unit_cfg, 'attack') do
            table.insert(unit_info.attacks, attack)
        end

        local attack_types = { "arcane", "blade", "cold", "fire", "impact", "pierce" }
        for i,at in ipairs(attack_types) do
            unit_info.resist_mod[at] = wesnoth.unit_resistance(unit, at) / 100.
        end

        -- If we're caching, add this to 'cache'
        if cache then cache[id] = unit_info end

        return unit_info
    end
end

function battle_calcs.strike_damage(attacker, defender, weapon, cache)
    -- Return the single strike damage of an attack by 'attacker' on 'defender' with 'weapon'
    -- Here, 'weapon' is the weapon number in Lua counts, i.e., counts start at 1
    -- 'cache' can be given to pass through to battle_calcs.unit_attack_info()
    -- Right now we're not caching the results of strike_damage as it seems fast enough
    -- That might be changed later

    local attacker_info = battle_calcs.unit_attack_info(attacker, cache)
    local resist_mod = battle_calcs.unit_attack_info(defender, cache).resist_mod[attacker_info.attacks[weapon].type]

    -- Base damage time resistance modifyer
    local damage = attacker_info.attacks[weapon].damage * resist_mod

    -- Lawful bonus
    if (attacker_info.alignment ~= 'neutral') then
        local lawful_bonus = wesnoth.get_time_of_day().lawful_bonus
        if (lawful_bonus ~= 0) then
            if (attacker_info.alignment == 'lawful') then
                damage = damage * (1 + lawful_bonus / 100.)
            else
                damage = damage * (1 - lawful_bonus / 100.)
            end
        end
    end

    return H.round(damage)
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

function battle_calcs.battle_outcome_coefficients(cfg)
    -- Determine the coefficients needed to calculate the hitpoint probability distribution
    -- of a given battle
    -- Inputs:
    -- - cfg: config table with sub-tables att/def for the attacker/defender with the following fields:
    --   - strikes: total number of strikes
    --   - max_hits: maximum number of hits the unit can survive
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

return battle_calcs
