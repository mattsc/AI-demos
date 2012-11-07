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
    local id = 'unitinfo-' .. unit.id .. unit.type .. unit.side
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
        if cache then cache[id] = unit_info end

        return unit_info
    end
end

function battle_calcs.strike_damage(attacker, defender, att_weapon, def_weapon, cache)
    -- Return the single strike damage of an attack by 'attacker' on 'defender' with 'weapon' for both combatants
    -- Also returns the other information about the attack (since we're accessing the information already anyway)
    -- Here, 'weapon' is the weapon number in Lua counts, i.e., counts start at 1
    -- 'cache' can be given to pass through to battle_calcs.unit_attack_info()
    -- Right now we're not caching the results of strike_damage as it seems fast enough
    -- That might be changed later

    local attacker_info = battle_calcs.unit_attack_info(attacker, cache)
    local defender_info = battle_calcs.unit_attack_info(defender, cache)

    -- Base damage
    local att_damage = attacker_info.attacks[att_weapon].damage
    local def_damage = defender_info.attacks[def_weapon].damage

    -- Take 'charge' into account
    if attacker_info.attacks[att_weapon].charge then
        att_damage = att_damage * 2
        def_damage = def_damage * 2
    end

    -- Opponent resistance modifier
    local att_multiplier = defender_info.resist_mod[attacker_info.attacks[att_weapon].type]
    local def_multiplier = attacker_info.resist_mod[defender_info.attacks[def_weapon].type]

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

    -- Rounding of .5 values is done differently depending on whether the
    -- multiplier is greater or smaller than 1
    if (att_multiplier > 1) then
        att_damage = H.round(att_damage * att_multiplier - 0.001)
    else
        att_damage = H.round(att_damage * att_multiplier + 0.001)
    end
    if (def_multiplier > 1) then
        def_damage = H.round(def_damage * def_multiplier - 0.001)
    else
        def_damage = H.round(def_damage * def_multiplier + 0.001)
    end

    return att_damage, def_damage, attacker_info.attacks[att_weapon], defender_info.attacks[def_weapon]
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
    local id = 'coeff-' .. cfg.att.strikes .. '-' .. cfg.att.max_hits
    if cfg.att.firststrike then id = id .. 'fs' end
    id = id .. 'x' .. cfg.def.strikes .. '-' .. cfg.def.max_hits
    if cfg.def.firststrike then id = id .. 'fs' end
    --print(id)

    -- If cache for this unit exists, return it
    if cache and cache[id] then
        return cache[id][1], cache[id][2]
    else
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
        if cache then cache[id] = { coeffs_att, coeffs_def } end

        return coeffs_att, coeffs_def
    end
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

    -- Add poison probability
    if opp_attack.poison then
        stats.posioned = 1. - stats.hp_chance[starting_hp]
    else
        stats.poisoned = 0
    end

    -- Add slow probability
    if opp_attack.slow then
        stats.slowed = 1. - stats.hp_chance[starting_hp]
    else
        stats.slowed = 0
    end

    -- Finally, add in the outcome that was skipped
    stats.hp_chance[skip_hp] = skip_prob
    stats.average_hp = stats.average_hp + skip_hp * skip_prob

    -- Always set hp_chance[0] since it is of such importance in the analysis
    stats.hp_chance[0] = stats.hp_chance[0] or 0

    return stats
end

function battle_calcs.battle_outcome(attacker, defender, cfg, cache)
    -- Calculate the stats of a combat by attacker vs. defender
    -- cfg: input parameters
    --  - att_weapon/def_weapon: attacker/defender weapon number

    -- Collect all the information needed for the calculation
    -- Strike damage and numbers
    local att_damage, def_damage, att_attack, def_attack =
        battle_calcs.strike_damage(attacker, defender, cfg.att_weapon, cfg.def_weapon, cache)

    -- Take swarm into account
    local att_strikes, def_strikes = att_attack.number, def_attack.number
    if att_attack.swarm then
        att_strikes = math.floor(att_strikes * attacker.hitpoints / attacker.max_hitpoints)
    end
    if def_attack.swarm then
        def_strikes = math.floor(def_strikes * defender.hitpoints / defender.max_hitpoints)
    end

    -- Maximum number of hits that either unit can survive
    local att_max_hits = math.floor((attacker.hitpoints - 1) / def_damage)
    if (att_max_hits > def_strikes) then att_max_hits = def_strikes end
    local def_max_hits = math.floor((defender.hitpoints - 1) / att_damage)
    if (def_max_hits > att_strikes) then def_max_hits = att_strikes end

    -- Probability of landing a hit
    local att_hit_prob = wesnoth.unit_defense(defender, wesnoth.get_terrain(defender.x, defender.y)) / 100.
    local def_hit_prob = wesnoth.unit_defense(attacker, wesnoth.get_terrain(attacker.x, attacker.y)) / 100.

    -- Magical: attack and defense, and under all circumstances
    if att_attack.magical then att_hit_prob = 0.7 end
    if def_attack.magical then def_hit_prob = 0.7 end

    -- Marksman: attack only, and only if terrain defense is less
    if att_attack.marksman and (att_hit_prob < 0.6) then
        att_hit_prob = 0.6
    end
    --print(att_damage, att_strikes, att_max_hits, att_hit_prob)
    --print(def_damage, def_strikes, def_max_hits, def_hit_prob)

    -- Get the coefficients for this kind of combat
    local cfg = {
        att = { strikes = att_strikes, max_hits = att_max_hits, firststrike = att_attack.firststrike },
        def = { strikes = def_strikes, max_hits = def_max_hits, firststrike = def_attack.firststrike }
    }
    local att_coeffs, def_coeffs = battle_calcs.battle_outcome_coefficients(cfg, cache)

    -- And multiply out the factors
    -- Note that att_hit_prob, def_hit_prob need to be in that order for both calls
    local att_stats = battle_calcs.hp_distribution(att_coeffs, att_hit_prob, def_hit_prob, attacker.hitpoints, def_damage, def_attack)
    local def_stats = battle_calcs.hp_distribution(def_coeffs, att_hit_prob, def_hit_prob, defender.hitpoints, att_damage, att_attack)

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

function battle_calcs.attack_rating(att_stats, def_stats, attackers, defender, dsts, cfg)
    -- Returns a common (but configurable) kind of rating for attacks
    -- Inputs:
    -- att_stats: can be a single attacker stats table, or an array of several
    -- def_stats: has to be a single defender stats table
    -- attackers: single attacker unit or table of attacker units, in same order as att_stats
    -- defender: defender unit table
    -- dsts: the attack locations, in same order as att_stats
    -- cfg: table of configurable rating parameters
    --  - own_damage_weight (1.0): ratio of rating for own damage / enemy damage
    --  - ctk_weight (0.5): rating bonus for each % point of CTK
    --  - resource_weight (0.25): rating for each gold of resources used (all the attackers)
    --  - terrain_weight (0.111): rating for each % point of terrain defense
    --  - village_bonus (25): rating bonus if attacker is on a village
    --  - defender_village_bonus (5): rating bonus if defender is on a village
    --  - xp_weight (0.2): rating for each XP (both attackers and defenders)
    --  - distance_leader_weight (1.0): rating of attack hex distance from AI leader (relative to enemy distance from leader)
    --  - occupied_hex_penalty (-0.1): rating penalty if the attack hex is occupied
    --
    -- Returns:
    --   - Overall rating for the attack or attack combo
    --   - Attacker rating: this one is additive for the individual attacks in a combo
    --   - Defender rating: not additive for attack combos; needs to be calculated for the
    --     defender stats of the last attack in a combo (that works for everything except
    --     the rating whether the defender is about to level in the attack combo)

    -- Set up the rating config parameters
    cfg = cfg or {}
    local own_damage_weight = cfg.own_damage_weight or 1.0
    local ctk_weight = cfg.ctk_weight or 0.5
    local resource_weight = cfg.resource_weight or 0.25
    local terrain_weight = cfg.terrain_weight or 0.111
    local village_bonus = cfg.village_bonus or 25
    local defender_village_bonus = cfg.defender_village_bonus or 5
    local xp_weight = cfg.xp_weight or 0.2
    local distance_leader_weight = cfg.distance_leader_weight or 1.0
    local occupied_hex_penalty = cfg.occupied_hex_penalty or -0.1

    -- If att is a single stats table, make it a one-element array
    -- That way all the rest can be done in in the same way for single and combo attacks
    if att_stats.hp_chance then
        att_stats = { att_stats }
        attackers = { attackers }
        dsts = { dsts }
    end

    -- We also need the leader (well, the location at least)
    -- because if there's no other difference, prefer location _between_ the leader and the enemy
    local leader = wesnoth.get_units { side = attackers[1].side, canrecruit = 'yes' }[1]

    ---------- Collect the necessary information ----------
    ------ All the per-attacker contributions: ------
    local damage, ctd, resources_used = 0, 0, 0
    local xp_bonus = 0
    local attacker_about_to_level_bonus, defender_about_to_level_penalty = 0, 0
    local relative_distances, attacker_defenses, attackers_on_villages = 0, 0, 0
    local occupied_hexes = 0
    for i,as in ipairs(att_stats) do
        --print(attackers[i].id, as.average_hp)
        damage = damage + attackers[i].hitpoints - as.average_hp
        ctd = ctd + as.hp_chance[0]  -- Chance to die
        resources_used = resources_used + wesnoth.unit_types[attackers[i].type].cost

        -- If there's no chance to die, using unit with lots of XP is good
        -- Otherwise it's bad
        if (as.hp_chance[0] > 0) then
            xp_bonus = xp_bonus - attackers[i].experience
        else
            xp_bonus = xp_bonus + attackers[i].experience
        end

        -- The attack position (this is just for convenience)
        local x, y = dsts[i][1], dsts[i][2]

        -- Position units in between AI leader and defender
        -- This number is larger for attack hexes closer to the side leader
        relative_distances = relative_distances
            + H.distance_between(defender.x, defender.y, leader.x, leader.y)
            - H.distance_between(x, y, leader.x, leader.y)

        -- Terrain and village bonus
        attacker_defenses = attacker_defenses - wesnoth.unit_defense(attackers[i], wesnoth.get_terrain(x, y))
        local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(x, y)).village
        if is_village then
            attackers_on_villages = attackers_on_villages + 1
        end

        -- Count occupied attack hexes (which get a small rating penalty)
        -- Note: it must be checked previously that the unit on the hex can move away
        if (x ~= attackers[i].x) or (y ~= attackers[i].y) then
            if wesnoth.get_unit(x, y) then
                occupied_hexes = occupied_hexes + 1
            end
        end

        -- Will the attacker level in this attack (or likely do so?)
        local defender_level = wesnoth.unit_types[defender.type].level
        if (as.hp_chance[0] < 0.4) then
            if (attackers[i].max_experience - attackers[i].experience <= defender_level) then
                attacker_about_to_level_bonus = attacker_about_to_level_bonus + 100
            else
                if (attackers[i].max_experience - attackers[i].experience <= defender_level * 8) and (def_stats.hp_chance[0] >= 0.6) then
                    attacker_about_to_level_bonus = attacker_about_to_level_bonus + 50
                end
            end
        end

        -- Will the defender level in this attack (or likely do so?)
        local attacker_level = wesnoth.unit_types[attackers[i].type].level
        if (def_stats.hp_chance[0] < 0.6) then
            if (defender.max_experience - defender.experience <= attacker_level) then
                defender_about_to_level_penalty = defender_about_to_level_penalty - 2000
            else
                if (defender.max_experience - defender.experience <= attacker_level * 8) and (as.hp_chance[0] >= 0.4) then
                    defender_about_to_level_penalty = defender_about_to_level_penalty - 1000
                end
            end
        end
    end

    ------ All the defender-related information: ------
    local defender_damage = defender.hitpoints - def_stats.average_hp
    local ctk = def_stats.hp_chance[0]  -- Chance to kill

    -- XP bonus is positive for defender as well - want to get rid of high-XP opponents first
    -- Except if the defender will likely level up through the attack (dealt with above)
    local defender_xp_bonus = defender.experience

    local defender_cost = wesnoth.unit_types[defender.type].cost
    local defender_on_village = wesnoth.get_terrain_info(wesnoth.get_terrain(defender.x, defender.y)).village

    ---------- Now add all this together in a rating ----------
    -- We use separate attacker(s) and defender ratings, so that attack combos can be dealt with easily
    local defender_rating, attacker_rating = 0, 0

    -- Rating based on the attack outcome
    defender_rating = defender_rating + defender_damage + ctk * 100. * ctk_weight
    attacker_rating = attacker_rating - (damage + ctd * 100. * ctk_weight) * own_damage_weight

    -- Terrain and position related ratings
    attacker_rating = attacker_rating + relative_distances * distance_leader_weight
    attacker_rating = attacker_rating + attacker_defenses * terrain_weight
    attacker_rating = attacker_rating + attackers_on_villages * village_bonus
    attacker_rating = attacker_rating + occupied_hexes * occupied_hex_penalty

    -- XP-based rating
    defender_rating = defender_rating + defender_xp_bonus * xp_weight + defender_about_to_level_penalty
    attacker_rating = attacker_rating + xp_bonus * xp_weight + attacker_about_to_level_bonus

    -- Resources used (cost) of units on both sides
    -- Only the delta between ratings makes a difference -> absolute value meaningless
    -- Don't want this to be too highly rated, or single-unit attacks will always be chosen
    defender_rating = defender_rating + defender_cost * resource_weight
    attacker_rating = attacker_rating - resources_used * resource_weight

    -- Bonus (or penalty) for units on villages
    if defender_on_village then defender_rating = defender_rating + defender_village_bonus end

    local rating = defender_rating + attacker_rating
    --print('--> attack rating, defender_rating, attacker_rating:', rating, defender_rating, attacker_rating)
    return rating, defender_rating, attacker_rating
end

function battle_calcs.attack_combo_stats(tmp_attackers, tmp_dsts, enemy, precalc)
    -- Calculate attack combination outcomes using
    -- tmp_attackers: array of attacker units (this is done so that
    --   the units need not be found here, as likely doing it in the
    --   calling function is more efficient (because of repetition)
    -- tmp_dsts: array of the hexes (format {x, y}) from which the attackers attack
    --   must be in same order as 'attackers'
    -- enemy: the enemy being attacked
    -- precalc: an optional table of pre-calculated attack outcomes
    --   - As this is a table, we can modify it in here (add outcomes), which also modifies it in the calling function
    --
    -- Return values:
    --   - the rating for this attack combination as returned by battle_calcs.attack_rating()
    --   - the sorted attackers and dsts arrays
    --   - defender combo stats: one set of stats containing the defender stats after the attack combination
    --   - att_stats: an array of stats for each attacker, in the same order as 'attackers'
    --   - def_stats: an array of defender stats for each individual attack, in the same order as 'attackers'
    --
    -- Note: the combined defender stats are approximate in some cases (e.g. attacks
    -- with slow and drain, but should be good otherwise
    -- Doing all of it right is not possible for computation time reasons

    precalc = precalc or {}

    --print()
    --print('Enemy:', enemy.id, enemy.x, enemy.y)
    --print('Attackers:')
    --for i,a in ipairs(tmp_attackers) do
    --    print('  ' .. a.id, a.x, a.y)
    --end

    -- We first simulate and rate the individual attacks
    local ratings, tmp_attacker_ratings = {}, {}
    local tmp_att_stats, tmp_def_stats = {}, {}
    for i,a in ipairs(tmp_attackers) do
        -- Initialize or use the 'precalc' table
        local enemy_ind = enemy.x * 1000 + enemy.y
        local att_ind = a.x * 1000 + a.y
        local dst_ind = tmp_dsts[i][1] * 1000 + tmp_dsts[i][2]
        if (not precalc[enemy_ind]) then precalc[enemy_ind] = {} end
        if (not precalc[enemy_ind][att_ind]) then precalc[enemy_ind][att_ind] = {} end

        if (not precalc[enemy_ind][att_ind][dst_ind]) then
            --print('Calculating attack combo stats:', enemy_ind, att_ind, dst_ind)
            tmp_att_stats[i], tmp_def_stats[i] = battle_calcs.simulate_combat_loc(a, tmp_dsts[i], enemy)

            -- Get the base rating from battle_calcs.attack_rating()
            local rating, dummy, tmp_ar = battle_calcs.attack_rating(tmp_att_stats[i], tmp_def_stats[i], a, enemy, tmp_dsts[i])
            tmp_attacker_ratings[i] = tmp_ar
            --print('rating:', rating)

            -- But for combos, also want units with highest attack outcome uncertainties to go early
            -- So that we can change our mind in case of unfavorable outcome
            local outcome_variance = 0
            local av = tmp_def_stats[i].average_hp
            local n_outcomes = 0

            for hp,p in ipairs(tmp_def_stats[i].hp_chance) do
                if (p > 0) then
                    local dv = p * (hp - av)^2
                    --print(hp,p,av, dv)
                    outcome_variance = outcome_variance + dv
                    n_outcomes = n_outcomes + 1
                end
            end
            outcome_variance = outcome_variance / n_outcomes
            --print('outcome_variance', outcome_variance)

            -- Note that this is a variance, not a standard deviations (as in, it's squared),
            -- so it does not matter much for low-variance attacks, but takes on large values for
            -- high variance attacks.  I think that is what we want.
            rating = rating + outcome_variance

            -- If attacker has attack with 'slow' special, it should always go first
            -- This isn't quite true in reality, but can be refined later
            if AH.has_weapon_special(a, "slow") then
                rating = rating + 50  -- but not quite as high as a really high CTK
            end

            --print('Final rating', rating, i)
            ratings[i] = { i, rating }

            -- Now add this attack to the precalc table, so that next time around, we don't have to do this again
            precalc[enemy_ind][att_ind][dst_ind] = {
                rating = rating,  -- Cannot use { i, rating } here, as 'i' might be different next time
                attacker_ratings = tmp_attacker_ratings[i],
                att_stats = tmp_att_stats[i],
                def_stats = tmp_def_stats[i]
            }
        else
            --print('Stats already exist')
            ratings[i] = { i, precalc[enemy_ind][att_ind][dst_ind].rating }
            tmp_attacker_ratings[i] = precalc[enemy_ind][att_ind][dst_ind].attacker_ratings
            tmp_att_stats[i] = precalc[enemy_ind][att_ind][dst_ind].att_stats
            tmp_def_stats[i] = precalc[enemy_ind][att_ind][dst_ind].def_stats
        end
    end

    -- Now sort all the arrays based on this rating
    -- This will give the order in which the individual attacks are executed
    table.sort(ratings, function(a, b) return a[2] > b[2] end)

    -- Reorder attackers, dsts and stats in this order
    local attackers, dsts, att_stats, def_stats, attacker_ratings = {}, {}, {}, {}, {}
    for i,r in ipairs(ratings) do
        attackers[i], dsts[i] = tmp_attackers[r[1]], tmp_dsts[r[1]]
        att_stats[i], def_stats[i] = tmp_att_stats[r[1]], tmp_def_stats[r[1]]
        attacker_ratings[i] = tmp_attacker_ratings[r[1]]
    end
    tmp_attackers, tmp_dsts, tmp_att_stats, tmp_def_stats, tmp_attacker_ratings = nil, nil, nil, nil, nil
    -- Just making sure that everything worked:
    --print(#attackers, #dsts, #att_stats, #def_stats)
    --for i,a in ipairs(attackers) do print(i, a.id) end
    --DBG.dbms(dsts)
    --DBG.dbms(att_stats)
    --DBG.dbms(def_stats)

    -- Now on to the calculation of the combined defender stats
    -- This method gives the right results (and is independent of attack order)
    -- for most attacks, but isn't quite right for things like slow and drain
    -- Doing it right is prohibitive in terms of calculation time though, this
    -- is an acceptable approximation

    -- Build up a hp_chance array for the combined hp_chance
    -- For the first attack, it's simply the defenders hp_chance distribution
    local hp_combo = AH.table_copy(def_stats[1].hp_chance)
    -- Also get an approximate value for slowed/poisoned chance after attack combo
    -- (this is 1-slowed for calc. reasons; changed below)
    local slowed, poisoned = 1 - def_stats[1].slowed, 1 - def_stats[1].poisoned

    -- Then we go through all the other attacks
    for i = 2,#attackers do
        -- Need a temporary array of zeros for the new result (because several attacks can combine to the same HP)
        local tmp_array = {}
        for hp1,p1 in pairs(hp_combo) do tmp_array[hp1] = 0 end

        for hp1,p1 in pairs(hp_combo) do -- Note: need pairs(), not ipairs() !!
            -- If hp_combo is ~=0, "anker" the hp_chance array of the second attack here
            if (p1 > 0) then
                local dhp = hp1 - enemy.hitpoints  -- This is the offset in HP (starting point for the second attack)
                -- All percentages for the second attacks are considered, and if ~=0 offset by dhp
                for hp2,p2 in pairs(def_stats[i].hp_chance) do
                    if (p2>0) then
                        local new_hp = hp2 + dhp  -- The offset is defined to be negative
                        if (new_hp < 0) then new_hp = 0 end  -- HP can't go below 0
                        -- Also, for if the enemy has drain:
                        if (new_hp > enemy.max_hitpoints) then new_hp = enemy.max_hitpoints end
                        --print(enemy.id .. ': ' .. enemy.hitpoints .. '/' .. enemy.max_hitpoints ..':', hp1, p1, hp2, p2, dhp, new_hp)
                        tmp_array[new_hp] = tmp_array[new_hp] + p1*p2  -- New percentage is product of two individual ones
                    end
                end
            end
        end
        -- Finally, transfer result to hp_combo table for next iteration
        hp_combo = AH.table_copy(tmp_array)

        -- And the slowed/poisoned percentage (this is 1-slowed for calc. reasons; changed below)
        slowed = slowed * (1 - def_stats[i].slowed)
        poisoned = poisoned * (1 - def_stats[i].poisoned)
    end
    --DBG.dbms(hp_combo)
    --print('HPC[0]', hp_combo[0])

    -- Finally, set up the combined def_stats table
    local def_stats_combo = {}
    def_stats_combo.hp_chance = hp_combo
    local av_hp = 0
    for hp,p in ipairs(hp_combo) do av_hp = av_hp + hp*p end
    def_stats_combo.average_hp = av_hp

    -- Slowed/poisoned: go from 1-value -> value
    def_stats_combo.slowed, def_stats_combo.poisoned = 1. - slowed, 1. - poisoned

    -- Get the total rating for this attack combo:
    --   = sum of all the attacker ratings and the defender rating with the final def_stats
    -- -> we need one run through attack_rating() to get the defender rating given these stats
    -- It doesn't matter which attacker and att_stats are chosen for that
    local dummy, rating = battle_calcs.attack_rating(att_stats[1], def_stats_combo, attackers[1], enemy, dsts[1])
    for i,r in ipairs(attacker_ratings) do rating = rating + r end
    --print('    --> rating:', rating)

    return rating, attackers, dsts, att_stats, def_stats_combo, def_stats
end

return battle_calcs
