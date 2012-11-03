local AH = wesnoth.dofile "~/add-ons/AI-demos/lua/ai_helper.lua"
local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

local battle_calcs = {}

function battle_calcs.add_next_strike(att_cfg, def_cfg, arr, n, hit_miss_counts, hit_miss_str)
    -- Recursive function that sets up the sequences of strikes (misses and hits)
    -- Each call corresponds to one strike of one of the combattants and can be
    -- either miss (value 0) or hit (1)
    --
    -- Inputs:
    -- - att_cfg, def_cfg: config table for the attacker and defender with the following fields:
    --   - strikes: total number of strikes
    --   - max_hits: maximum number of hits the unit can survive
    -- - arr: an empty array that will hold the output table
    -- - Other parameters of for recursive use only and are initialized below

    -- On the first call of this function, initialize variables
    n = (n or 0) + 1  -- Strike counts (sum of both attacker and defender strikes)
    -- Counts for hits/misses by both units:
    --  - Indices 1 & 2: hit/miss for attacker
    --  - Indices 3 & 4: hit/miss for defender
    hit_miss_counts = hit_miss_counts or { 0, 0, 0, 0 }
    hit_miss_str = hit_miss_str or ''  -- string with the hit/miss sequence; for visualization only

    -- Create both a hit and a miss
    for i = 0,1 do  -- 0:miss, 1: hit
        -- hit/miss counts and string for this call
        local tmp_hmc = AH.table_copy(hit_miss_counts)
        local tmp_hmstr = ''

        -- Flag whether the opponent was killed by this strike
        local killed_opp = false  -- Defaults to falso

        -- Odd values of n are strikes by the attacker
        if (n % 2 == 1) then
            tmp_hmstr = hit_miss_str .. i  -- attacker hit/miss in string: 0 or 1
            tmp_hmc[i+1] = tmp_hmc[i+1] + 1  -- Increment hit/miss counts
            -- Set variable if opponent was killed:
            if (tmp_hmc[2] > def_cfg.max_hits) then killed_opp = true end
        -- Even values of n are strikes by the defender
        else
            tmp_hmstr = hit_miss_str .. (i+2)  -- defender hit/miss in string: 2 or 3
            tmp_hmc[i+3] = tmp_hmc[i+3] + 1  -- Increment hit/miss counts
            -- Set variable if opponent was killed:
            if (tmp_hmc[4] > att_cfg.max_hits) then killed_opp = true end
        end

        -- If we've reached the total number of strikes, add this hit/miss combination to table,
        -- but only if the opponent wasn't killed, as that would end the battle
        if (n < att_cfg.strikes + def_cfg.strikes) and (not killed_opp) then
            battle_calcs.add_next_strike(att_cfg, def_cfg, arr, n, tmp_hmc, tmp_hmstr)
        -- Otherwise, call the next recursion level
        else
            table.insert(arr, { hit_miss_str = tmp_hmstr, hit_miss_counts = tmp_hmc })
        end
    end
end

function battle_calcs.battle_outcome_coefficients(att_cfg, def_cfg)
    -- Determine the coefficients needed to calculate the hitpoint probability distribution
    -- of a given battle
    -- Inputs:
    -- - att_cfg, def_cfg: config table for the attacker and defender with the following fields:
    --   - strikes: total number of strikes
    --   - max_hits: maximum number of hits the unit can survive
    --
    -- Output: table with the coefficients needed to calculate the distribution
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
    battle_calcs.add_next_strike(att_cfg, def_cfg, hit_miss_counts)
    --DBG.dbms(hit_miss_counts)

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

    local coeffs = {}
    for am,v1 in pairs(counts) do  -- attacker miss count
        for ah,v2 in pairs(v1) do  -- attacker hit count
            -- Set up the exponent coefficients for attacker hits/misses
            local exp = { }  -- Array for an individual set of coefficients
            -- Only populate those indices that have exponents > 0
            if (am > 0) then exp.am = am end
            if (ah > 0) then exp.ah = ah end

            -- We combine defender results by testing whether they produce the same sum
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
            if (not coeffs[ah]) then coeffs[ah] = {} end

            -- If sum1 and sum2 are equal, that means all the defender probs added up to 1, or
            -- multiple thereof, which means the can all be combine in the calculation
            if (math.abs(sum1 - sum2) < 1e-9) then
                exp.num = sum1
                table.insert(coeffs[ah], exp)
            -- If not, the defender probs don't add up to something nice and all
            -- need to be calculated one by one
            else
                for dm,v3 in pairs(v2) do  -- defender miss count
                    for dh,num in pairs(v3) do  -- defender hit count
                        local tmp_exp = AH.table_copy(exp)
                        tmp_exp.num = num
                        if (dm > 0) then tmp_exp.dm = dm end
                        if (dh > 0) then tmp_exp.dh = dh end
                        table.insert(coeffs[ah], tmp_exp)
                    end
                end
            end
        end
    end
    --DBG.dbms(coeffs)

    return coeffs
end

function battle_calcs.print_coefficients()
    -- Print out the set of coefficients for a given number of attacker and defender strikes
    -- Also print numerical values for a given hit probability

    -- Configure these values at will
    local attacker_strikes, defender_strikes = 3, 3  -- number of strikes
    local att_hit_prob, def_hit_prob = 0.8, 0.4  -- probability of landing a hit attacker/defender

    -- Go through all combinations of maximum hits either attacker or defender can survive
    for ahits = attacker_strikes,0,-1 do
        for dhits = defender_strikes,0,-1 do
            -- Get the coefficients for this case
            local att_cfg = { strikes = attacker_strikes, max_hits = ahits }
            local def_cfg = { strikes = attacker_strikes, max_hits = dhits }

            local coeffs = battle_calcs.battle_outcome_coefficients(att_cfg, def_cfg)

            print()
            print('Attacker: ' .. att_cfg.strikes .. ' strikes, can survive ' .. att_cfg.max_hits .. ' hits')
            print('Defender: ' .. def_cfg.strikes .. ' strikes, can survive ' .. def_cfg.max_hits .. ' hits')
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

                print(hits .. ':  ' .. str)
                print('      = ' .. hit_prob)
            end
        end
    end
end

return battle_calcs
