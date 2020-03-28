local H = wesnoth.require "helper"
local AH = wesnoth.require "ai/lua/ai_helper.lua"
local FAU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack_utils.lua"
local FBU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_benefits_utilities.lua"
local FCFG = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_config.lua"
local FDI = wesnoth.require "~/add-ons/AI-demos/lua/fred_data_incremental.lua"
local FGM = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_map.lua"
local FS = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_status.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local FVS = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_virtual_state.lua"
local COMP = wesnoth.require "~/add-ons/AI-demos/lua/compatibility.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local fred_attack = {}

----- Attack: -----
function fred_attack.get_attack_action(zone_cfg, fred_data)
    DBG.print_debug_time('eval', fred_data.turn_start_time, '  - attack evaluation: ' .. zone_cfg.zone_id .. ' (' .. string.format('%.2f', zone_cfg.rating) .. ')')
    --DBG.dbms(zone_cfg, false, 'zone_cfg')

    local move_data = fred_data.move_data

    local leader_max_die_chance = FCFG.get_cfg_parm('leader_max_die_chance')

    local targets = {}
    if zone_cfg.targets then
        targets = zone_cfg.targets
    else
        targets = move_data.enemies
    end
    --DBG.dbms(targets, false, 'targets')


    -- Attackers is everybody in zone_cfg.zone_units is set,
    -- or all units with attacks left otherwise
    local zone_units_attacks = {}
    if zone_cfg.zone_units then
        for id,xy in pairs(zone_cfg.zone_units) do
            zone_units_attacks[id] = { move_data.units[id][1], move_data.units[id][2] }
        end
    else
        for id,loc in pairs(move_data.my_units) do
            local is_leader_and_off_keep = false
            if move_data.unit_infos[id].canrecruit and move_data.my_units_MP[id] then
                if (not wesnoth.get_terrain_info(wesnoth.get_terrain(loc[1], loc[2])).keep) then
                    is_leader_and_off_keep = true
                end
            end

            if (move_data.unit_copies[id].attacks_left > 0) then
                -- The leader counts as one of the attackers, but only if he's on his keep
                if (not is_leader_and_off_keep) then
                    zone_units_attacks[id] = loc
                end
            end
        end
    end
    --DBG.dbms(zone_units_attacks, false, 'zone_units_attacks')

    -- How much more valuable do we consider the enemy units than our own
    local value_ratio = zone_cfg.value_ratio
    local max_value_ratio = fred_data.ops_data.behavior.orders.max_value_ratio
    local rel_value_ratio = value_ratio / max_value_ratio
    --DBG.print_ts_delta(fred_data.turn_start_time, 'value_ratio, max_value_ratio, rel_value_ratio', value_ratio, max_value_ratio, rel_value_ratio)

    local acceptable_frac_die_value = (1 - rel_value_ratio)
    if (acceptable_frac_die_value < 0) then acceptable_frac_die_value = 0 end
    --acceptable_frac_die_value = acceptable_frac_die_value^2 * 2
    --DBG.print_ts_delta(fred_data.turn_start_time, zone_cfg.zone_id .. ': acceptable_frac_die_value', acceptable_frac_die_value, acceptable_frac_die_value*12)


    -- We need to make sure the units always use the same weapon below, otherwise
    -- the comparison is not fair.
    local cfg_attack = { value_ratio = value_ratio }

    local interactions = fred_data.ops_data.interaction_matrix.penalties['att']
    --DBG.dbms(interactions, false, 'interactions')
    local reserved_actions = fred_data.ops_data.reserved_actions
    local penalty_infos = { src = {}, dst = {} }

    local leader_id = move_data.my_leader.id

    local combo_ratings = {}
    for target_id, target_xy in pairs(targets) do
        local target_loc = move_data.units[target_id]
        local target = {}
        target[target_id]= target_loc

        local is_trappable_enemy = true
        if move_data.unit_infos[target_id].abilities.skirmisher then
            is_trappable_enemy = false
        end

        -- We also count unit that are already trapped as untrappable
        if move_data.trapped_enemies[target_id] then
            is_trappable_enemy = false
        end
        DBG.print_debug('attack_print_output', target_id, '  trappable:', is_trappable_enemy, target_loc[1], target_loc[2])

        local attack_combos = FAU.get_attack_combos(
            zone_units_attacks, target, cfg_attack, move_data.effective_reach_maps, false, fred_data
        )
        --DBG.print_ts_delta(fred_data.turn_start_time, '#attack_combos', #attack_combos)


        for j,combo in ipairs(attack_combos) do
            --DBG.print_ts_delta(fred_data.turn_start_time, 'combo ' .. j)

            -- Only check out the first 1000 attack combos to keep evaluation time reasonable
            -- TODO: can we have these ordered with likely good rating first?
            if (j > 1000) then break end

            local attempt_trapping = is_trappable_enemy

            local combo_outcome = FAU.attack_combo_eval(combo, target, cfg_attack, fred_data)

            -- For this first assessment, we use the full rating, that is, including
            -- all types of damage, extra rating, etc. While this is not accurate for
            -- the state at the end of the attack, it gives a good overall rating
            -- for the attacker/defender pairings involved.
            local combo_rating = combo_outcome.rating_table.rating

            -- Penalty for units and/or hexes planned to be used otherwise
            local penalty_rating, penalty_str = 0, ''
            local actions = {}
            for src,dst in pairs(combo) do
                if (not penalty_infos.src[src]) then
                    local x, y = math.floor(src / 1000), src % 1000
                    penalty_infos.src[src] = FGM.get_value(move_data.unit_map, x, y, 'id')
                end
                if (not penalty_infos.dst[dst]) then
                    penalty_infos.dst[dst] = { math.floor(dst / 1000), dst % 1000 }
                end
                local action = { id = penalty_infos.src[src], loc = penalty_infos.dst[dst] }
                table.insert(actions, action)
            end
            --DBG.dbms(actions, false, 'actions')
            --DBG.dbms(penalty_infos, false, 'penalty_infos')

            local penalty, str = FBU.action_penalty(actions, reserved_actions, interactions, move_data)
            penalty_rating = penalty_rating + penalty
            penalty_str = penalty_str .. str

            local bonus_rating = 0

            --DBG.dbms(combo_outcome.rating_table, false, 'combo_outcome.rating_table')
            --std_print('   combo ratings: ', combo_outcome.rating_table.rating, combo_outcome.rating_table.attacker.rating, combo_outcome.rating_table.defender.rating)


            local do_attack = true

            -- Don't do this attack if the leader has a chance to get killed, poisoned or slowed
            -- This is only the chance of poison/slow in this attack, if he is already
            -- poisoned/slowed, this is handled by the retreat code.
            -- Also don't do the attack if the leader ends up having low stats, unless he
            -- cannot move in the first place.
            if do_attack then
                for k,att_outcome in ipairs(combo_outcome.att_outcomes) do
                    local attacker_info = move_data.unit_infos[combo_outcome.attacker_damages[k].id]
                    if (attacker_info.canrecruit) then
                        if (att_outcome.hp_chance[0] > 0.0) then
                            do_attack = false
                            break
                        end

                        if (att_outcome.slowed > 0.0)
                            and (not attacker_info.status.slowed)
                        then
                            do_attack = false
                            break
                        end

                        if (att_outcome.poisoned > 0.0)
                            and (not attacker_info.status.poisoned)
                            and (not attacker_info.abilities.regenerate)
                        then
                            do_attack = false
                            break
                        end

                        if move_data.my_units_MP[attacker_info.id] then
                            if (att_outcome.average_hp < attacker_info.max_hitpoints / 2) then
                                do_attack = false
                                break
                            end
                        end

                    end
                end
            end

            if do_attack then
                -- Discourage attacks from hexes adjacent to villages that are
                -- unoccupied by an AI unit without MP or one of the attackers,
                -- except if it's the hex the target is on, of course

                local tmp_adj_villages_map = {}
                for _,dst in ipairs(combo_outcome.dsts) do
                    for xa,ya in H.adjacent_tiles(dst[1], dst[2]) do
                        if FGM.get_value(move_data.village_map, xa, ya, 'owner')
                            and (not FGM.get_value(move_data.my_unit_map_noMP, xa, ya, 'id'))
                            and ((xa ~= target_loc[1]) or (ya ~= target_loc[2]))
                        then
                            --std_print('next to village:')
                            FGM.set_value(tmp_adj_villages_map, xa, ya, 'is_village', true)
                        end
                    end
                end

                -- Now check how many of those villages there are that are not used in the attack
                local adj_villages_map = {}
                local n_adj_unocc_village = 0
                for x,y in FGM.iter(tmp_adj_villages_map) do
                    local is_used = false
                    for _,dst in ipairs(combo_outcome.dsts) do
                        if (dst[1] == x) and (dst[2] == y) then
                            --std_print('Village is used in attack:' .. x .. ',' .. y)
                            is_used = true
                            break
                        end
                    end
                    if (not is_used) then
                        n_adj_unocc_village = n_adj_unocc_village + 1
                        FGM.set_value(adj_villages_map, x, y, 'is_village', true)
                    end
                end
                tmp_adj_villages_map = nil

                -- For each such village found, we give a penalty eqivalent to 10 HP of the target
                -- and we do not do the attack at all if the CTD of the defender is low
                if (n_adj_unocc_village > 0) then
                    if (combo_outcome.def_outcome.hp_chance[0] == 0) then
                        -- TODO: this is probably still too simplistic, should really be
                        -- a function of damage done to both sides vs. healing at village
                        -- TODO: do we also place the prerecruits here?
                        for i_a,dst in pairs(combo_outcome.dsts) do
                            local id = combo_outcome.attacker_damages[i_a].id
                            --std_print(id, dst[1], dst[2], move_data.unit_copies[id].x, move_data.unit_copies[id].y)
                            if (not move_data.my_units_noMP[id]) then
                                COMP.put_unit(move_data.unit_copies[id], dst[1], dst[2])
                            end
                        end

                        local can_reach = false
                        for x,y in FGM.iter(adj_villages_map) do
                            local _, cost = wesnoth.find_path(move_data.unit_copies[target_id], x, y)
                            --std_print('cost', cost)
                            if (cost <= move_data.unit_infos[target_id].max_moves) then
                                can_reach = true
                                break
                            end
                        end
                        --std_print('can_reach', can_reach)

                        for i_a,dst in pairs(combo_outcome.dsts) do
                            local id = combo_outcome.attacker_damages[i_a].id
                            if (not move_data.my_units_noMP[id]) then
                                COMP.extract_unit(move_data.unit_copies[id])
                                move_data.unit_copies[id].x, move_data.unit_copies[id].y = move_data.units[id][1], move_data.units[id][2]
                            end
                            --std_print(id, dst[1], dst[2], move_data.unit_copies[id].x, move_data.unit_copies[id].y)
                        end

                        if can_reach then
                            do_attack = false
                        end
                    else
                        local unit_value = move_data.unit_infos[target_id].unit_value
                        local penalty = 10. / move_data.unit_infos[target_id].max_hitpoints * unit_value
                        penalty = penalty * n_adj_unocc_village
                        --std_print('Applying village penalty', bonus_rating, penalty)
                        bonus_rating = bonus_rating - penalty

                        -- In that case, also don't give the trapping bonus
                        attempt_trapping = false
                    end
                end
            end

            if do_attack then
                -- Do not attempt trapping if the unit is on good terrain,
                -- except if the target is down to less than half of its hitpoints
                if (move_data.unit_infos[target_id].hitpoints >= move_data.unit_infos[target_id].max_hitpoints/2) then
                    local defense = FDI.get_unit_defense(move_data.unit_copies[target_id], target_loc[1], target_loc[2], fred_data.caches.defense_maps)
                    if (defense >= (1 - move_data.unit_infos[target_id].good_terrain_hit_chance)) then
                        attempt_trapping = false
                    end
                end

                -- Give a bonus to attacks that trap the enemy
                -- TODO: Consider other cases than just two units on each side as well
                if attempt_trapping then
                    -- Set up a map containing all adjacent hexes that are either occupied
                    -- or used in the attack
                    local adj_occ_hex_map = {}
                    local count = 0
                    for _,dst in ipairs(combo_outcome.dsts) do
                        FGM.set_value(adj_occ_hex_map, dst[1], dst[2], 'is_occ', true)
                        count = count + 1
                    end

                    for xa,ya in H.adjacent_tiles(target_loc[1], target_loc[2]) do
                        if (not FGM.get_value(adj_occ_hex_map, xa, ya, 'is_occ')) then
                            -- Only units without MP on the AI side are on the map here
                            if FGM.get_value(move_data.my_unit_map_noMP, xa, ya, 'id') then
                                FGM.set_value(adj_occ_hex_map, xa, ya, 'is_occ', true)
                                count = count + 1
                            end
                        end
                    end

                    -- Check whether this is a valid trapping attack
                    local trapping_bonus = false
                    if (count > 1) then
                        trapping_bonus = true

                        -- If it gives the target access to good terrain, we don't do it,
                        -- except if the target is down to less than half of its hitpoints
                        if (move_data.unit_infos[target_id].hitpoints >= move_data.unit_infos[target_id].max_hitpoints/2) then
                            for xa,ya in H.adjacent_tiles(target_loc[1], target_loc[2]) do
                                if (not FGM.get_value(adj_occ_hex_map, xa, ya, 'is_occ')) then
                                    local defense = FDI.get_unit_defense(move_data.unit_copies[target_id], xa, ya, fred_data.caches.defense_maps)
                                    if (defense >= (1 - move_data.unit_infos[target_id].good_terrain_hit_chance)) then
                                        trapping_bonus = false
                                        break
                                    end
                                end
                            end
                        end

                        -- If the previous check did not disqualify the attack,
                        -- check if this would result in trapping
                        if trapping_bonus then
                            trapping_bonus = false
                            for x,y,_ in FGM.iter(adj_occ_hex_map) do
                                local opp_hex = AH.find_opposite_hex_adjacent({ x, y }, target_loc)
                                if opp_hex and FGM.get_value(adj_occ_hex_map, opp_hex[1], opp_hex[2], 'is_occ') then
                                    trapping_bonus = true
                                    break
                                end
                                if trapping_bonus then break end
                            end
                        end
                    end

                    -- If this is a valid trapping attack, we give a
                    -- bonus eqivalent to 8 HP * (1 - CTD) of the target
                    if trapping_bonus then
                        local unit_value = move_data.unit_infos[target_id].unit_value
                        local bonus = 8. / move_data.unit_infos[target_id].max_hitpoints * unit_value

                        -- Trapping is pointless if the target dies
                        bonus = bonus * (1 - combo_outcome.def_outcome.hp_chance[0])
                        -- Potential TODO: the same is true if one of the attackers needed for
                        -- trapping dies, but that already has a large penalty, and we'd have
                        -- to check that the unit is not trapped any more in combos with more
                        -- than 2 attackers. This is likely not worth the effort.

                        --std_print('Applying trapping bonus', bonus_rating, bonus)
                        bonus_rating = bonus_rating + bonus
                    end
                end

                -- Discourage use of poisoners:
                --  - In attacks that have a high chance to result in kill
                --  - Against unpoisonable units and units which are already poisoned
                --  - Against regenerating units
                --  - More than one poisoner
                -- These are independent of whether the poison attack is actually used in
                -- this attack combo, the motivation being that it takes away poison use
                -- from other attack where it may be more useful, rather than the use of
                -- it in this attack, as that is already taken care of in the attack outcome
                local number_poisoners = 0
                for i_a,attacker_damage in ipairs(combo_outcome.attacker_damages) do
                    local is_poisoner = false
                    for _,weapon in ipairs(move_data.unit_infos[attacker_damage.id].attacks) do
                        if weapon.poison then
                            number_poisoners = number_poisoners + 1
                            break
                        end
                    end
                end

                if (number_poisoners > 0) then
                    local poison_penalty = 0
                    local target_info = move_data.unit_infos[target_id]

                    -- Attack with chance to kill, penalty equivalent to 8 HP of the target times CTK
                    if (combo_outcome.def_outcome.hp_chance[0] > 0) then
                        poison_penalty = poison_penalty + 8. * combo_outcome.def_outcome.hp_chance[0] * number_poisoners
                    end

                    -- Already poisoned or unpoisonable unit
                    if target_info.status.poisoned or target_info.status.unpoisonable then
                        poison_penalty = poison_penalty + 8. * number_poisoners
                    end

                    -- Regenerating unit, but to a lesser degree, as poison is still useful here
                    if target_info.abilities.regenerate then
                        poison_penalty = poison_penalty + 4. * number_poisoners
                    end

                    -- More than one poisoner: don't quite use full amount as there's
                    -- a higher chance to poison target when several poisoners are used
                    -- In principle, one could could calculate the progressive chance
                    -- to poison here, but that seems overkill given the approximate nature
                    -- of the whole calculation in the first place
                    if (number_poisoners > 1) then
                        poison_penalty = poison_penalty + 6. * (number_poisoners - 1)
                    end

                    poison_penalty = poison_penalty / target_info.max_hitpoints * target_info.unit_value
                    bonus_rating = bonus_rating - poison_penalty
                end

                -- Discourage use of slow:
                --  - In attacks that have a high chance to result in kill
                --  - Against units which are already slowed
                --  - More than one slower
                local number_slowers = 0
                for i_a,attacker_damage in ipairs(combo_outcome.attacker_damages) do
                    local is_slower = false
                    for _,weapon in ipairs(move_data.unit_infos[attacker_damage.id].attacks) do
                        if weapon.slow then
                            number_slowers = number_slowers + 1
                            break
                        end
                    end
                end

                if (number_slowers > 0) then
                    local slow_penalty = 0
                    local target_info = move_data.unit_infos[target_id]

                    -- Attack with chance to kill, penalty equivalent to 4 HP of the target times CTK
                    if (combo_outcome.def_outcome.hp_chance[0] > 0) then
                        slow_penalty = slow_penalty + 4. * combo_outcome.def_outcome.hp_chance[0] * number_slowers
                    end

                    -- Already slowed unit
                    if target_info.status.slowed then
                        slow_penalty = slow_penalty + 4. * number_slowers
                    end

                    -- More than one slower
                    if (number_slowers > 1) then
                        slow_penalty = slow_penalty + 3. * (number_slowers - 1)
                    end

                    slow_penalty = slow_penalty / target_info.max_hitpoints * target_info.unit_value
                    bonus_rating = bonus_rating - slow_penalty
                end

                -- Discourage use of plaguers:
                --  - Against unplagueable units
                --  - More than one plaguer
                local number_plaguers = 0
                for i_a,attacker_damage in ipairs(combo_outcome.attacker_damages) do
                    local is_plaguer = false
                    for _,weapon in ipairs(move_data.unit_infos[attacker_damage.id].attacks) do
                        if weapon.plague then
                            number_plaguers = number_plaguers + 1
                            break
                        end
                    end
                end

                if (number_plaguers > 0) then
                    local plague_penalty = 0
                    local target_info = move_data.unit_infos[target_id]

                    -- This is a large penalty, as it is the equivalent of the gold value
                    -- of a walking corpse (that is, unlike other contributions, this
                    -- is not multiplied by unit_value / max_hitpoints).  However, as it
                    -- is not guaranteed that another attack would result in a new WC, we
                    -- only use half that value

                    -- Unplagueable unit
                    if target_info.status.unplagueable then
                        plague_penalty = plague_penalty + 0.5 * 8. * number_plaguers
                    end

                    -- More than one plaguer: don't quite use full amount as there's
                    -- a higher chance to plague target when several plaguers are used
                    if (number_plaguers > 1) then
                        plague_penalty = plague_penalty + 0.5 * 6. * (number_plaguers - 1)
                    end

                    --std_print('Applying plague penalty', bonus_rating, plague_penalty)

                    bonus_rating = bonus_rating - plague_penalty
                end
                --DBG.print_ts_delta(fred_data.turn_start_time, ' -----------------------> rating', combo_rating, bonus_rating)


                local pre_rating = combo_rating + bonus_rating

                -- Derate combo if it uses too many units for diminishing return
                local derating = 1
                local n_att = #combo_outcome.attacker_damages
                if (pre_rating > 0) and (n_att > 2) then
                    local progression = combo_outcome.rating_table.progression
                    -- dim_return is 1 if the last units adds exactly 1/n_att to the overall rating
                    -- It is s<1 if less value is added, >1 if more is added
                    local dim_return = (progression[n_att] - progression[n_att - 1]) / progression[n_att] * n_att
                    if (dim_return < 1) then
                        derating = math.sqrt(dim_return)
                    end
                    --std_print('derating', n_att, dim_return, derating)

                    pre_rating = pre_rating * derating
                end


                -- TODO: should penalty be applied before or after derating?
                local pre_rating = combo_rating + penalty_rating


                table.insert(combo_ratings, {
                    pre_rating = pre_rating,
                    bonus_rating = bonus_rating,
                    derating = derating,
                    penalty_rating = penalty_rating,
                    penalty_str = penalty_str,
                    dsts = combo_outcome.dsts,
                    weapons = combo_outcome.att_weapons_i,
                    target = target,
                    att_outcomes = combo_outcome.att_outcomes,
                    def_outcome = combo_outcome.def_outcome,
                    rating_table = combo_outcome.rating_table,
                    attacker_damages = combo_outcome.attacker_damages,
                    defender_damage = combo_outcome.defender_damage
                })

                --DBG.dbms(combo_ratings, false, 'combo_ratings')
            end
        end
    end
    table.sort(combo_ratings, function(a, b) return a.pre_rating > b.pre_rating end)
    --DBG.dbms(combo_ratings, false, 'combo_ratings')
    DBG.print_debug('attack_print_output', '#combo_ratings', #combo_ratings)

    -- Now check whether counter attacks are acceptable
    local max_total_rating, action = - math.huge
    local disqualified_attacks = {}
    local objectives = fred_data.ops_data.objectives
    local leader_goal = objectives.leader.final
    --DBG.dbms(leader_goal, false, 'leader_goal')
    local org_status = fred_data.ops_data.status
    --DBG.dbms(org_status, false, 'org_status')

    for count,combo in ipairs(combo_ratings) do
        if (count > 50) and action then break end
        DBG.print_debug('attack_print_output', '\nChecking counter attack for attack on', count, next(combo.target), zone_cfg.value_ratio, combo.rating_table.rating, action)

        -- Check whether an position in this combo was previously disqualified
        -- Only do so for large numbers of combos though; there is a small
        -- chance of a later attack that uses the same hexes being qualified
        -- because the hexes the units are on work better for the forward attack.
        -- So if there are not too many combos, we calculate all of them.
        -- As forward attacks are rated by their attack score, this is
        -- pretty unlikely though.
        local is_disqualified = false
        if (#combo_ratings > 100) then
            for i_a,attacker_damage in ipairs(combo.attacker_damages) do
                local id, x, y = attacker_damage.id, combo.dsts[i_a][1], combo.dsts[i_a][2]
                local key = id .. (x * 1000 + y)

                if disqualified_attacks[key] then
                    is_disqualified = FAU.is_disqualified_attack(combo, disqualified_attacks[key])
                    if is_disqualified then
                        break
                    end
                end
            end
        end
        --std_print('  is_disqualified', is_disqualified)

        if (not is_disqualified) then
            -- TODO: Need to apply correctly:
            --   - attack locs
            --   - new HP - use average
            --   - just apply level of opponent?
            --   - potential level-up
            --   - delayed damage
            --   - slow for defender (wear of for attacker at the end of the side turn)
            --   - plague

            local attack_includes_leader = false
            for i_a,attacker_damage in ipairs(combo.attacker_damages) do
                 if move_data.unit_infos[attacker_damage.id].canrecruit then
                     attack_includes_leader = true
                     break
                 end
            end
            --std_print('attack_includes_leader', attack_includes_leader)

            local old_locs, new_locs, old_HP_attackers = {}, {}, {}

            if DBG.show_debug('attack_combos') then
                for _,unit in ipairs(fred_data.ops_data.place_holders) do
                    wesnoth.label { x = unit[1], y = unit[2], text = 'recruit\n' .. unit.type, color = '160,160,160' }
                end
                if (not attack_includes_leader) then
                    wesnoth.label { x = leader_goal[1], y = leader_goal[2], text = 'leader goal', color = '200,0,0' }
                end
            end

            for i_a,attacker_damage in ipairs(combo.attacker_damages) do
                if DBG.show_debug('attack_combos') then
                    local x, y = combo.dsts[i_a][1], combo.dsts[i_a][2]
                    wesnoth.label { x = x, y = y, text = attacker_damage.id }
                end

                table.insert(old_locs, move_data.my_units[attacker_damage.id])
                table.insert(new_locs, combo.dsts[i_a])

                -- Apply average hitpoints from the forward attack as starting point
                -- for the counter attack. This isn't entirely accurate, but
                -- doing it correctly is too expensive, and this is better than doing nothing.
                -- TODO: It also sometimes overrates poisoned or slowed, as it might be
                -- counted for both attack and counter attack. This could be done more
                -- accurately by using a combined chance of getting poisoned/slowed, but
                -- for now we use this as good enough.
                table.insert(old_HP_attackers, move_data.unit_infos[attacker_damage.id].hitpoints)

                local hp = combo.att_outcomes[i_a].average_hp
                if (hp < 1) then hp = 1 end

                -- Need to round, otherwise the poison calculation might be wrong
                hp = H.round(hp)
                --std_print('attacker hp before, after:', old_HP_attackers[i_a], hp)

                move_data.unit_infos[attacker_damage.id].hitpoints = hp
                move_data.unit_copies[attacker_damage.id].hitpoints = hp

                -- If the unit is on the map, it also needs to be applied to the unit proxy
                if move_data.my_units_noMP[attacker_damage.id] then
                    local unit_proxy = COMP.get_unit(old_locs[i_a][1], old_locs[i_a][2])
                    unit_proxy.hitpoints = hp
                end
            end

            -- Note: attack_includes_leader and exclude_leader do not quite the same in how they
            -- apply penalties to the attack.
            -- TODO: need to rethink whether this is all correct. For example, if the attack does
            -- not include the leader, but he isn't placed, how do we apply the penalty?
           local exclude_leader = attack_includes_leader
           if (not exclude_leader) then
                for _,dst in ipairs(combo.dsts) do
                    if (dst[1] == leader_goal[1]) and (dst[2] == leader_goal[2]) then
                        exclude_leader = true
                        break
                    end
                end
                if (not exclude_leader) then
                    table.insert(old_locs, move_data.my_leader)
                    table.insert(new_locs, leader_goal)
                end
            end

            -- Also set the hitpoints for the defender
            local target_id, target_loc = next(combo.target)
            local target_proxy = COMP.get_unit(target_loc[1], target_loc[2])
            local old_HP_target = target_proxy.hitpoints
            local hp_org = old_HP_target - combo.defender_damage.damage

            -- As the counter attack happens on the enemy's side next turn,
            -- delayed damage also needs to be applied
            hp = H.round(hp_org - combo.defender_damage.delayed_damage)

            if (hp < 1) then hp = math.min(1, H.round(hp_org)) end
            --std_print('target hp before, after:', old_HP_target, hp_org, hp)

            move_data.unit_infos[target_id].hitpoints = hp
            move_data.unit_copies[target_id].hitpoints = hp
            target_proxy.hitpoints = hp



            local to_unit_locs, to_locs = {}, {}
            if (not attack_includes_leader) then
                table.insert(to_unit_locs, leader_goal)
            end
            -- Castles are only added if the leader can get to a keep
            -- TODO: reevaluate later if this should be changed
            for x,y,_ in FGM.iter(move_data.reachable_castles_map) do
                table.insert(to_locs, { x, y })
            end
            if objectives.protect.zones[zone_cfg.zone_id] then
                for _,unit in ipairs(objectives.protect.zones[zone_cfg.zone_id].units) do
                    table.insert(to_unit_locs, { unit.x, unit.y })
                end
                for _,village in pairs(objectives.protect.zones[zone_cfg.zone_id].villages) do
                    table.insert(to_locs, { village.x, village.y })
                end
            end
            for i_a,_ in ipairs(combo.attacker_damages) do
                table.insert(to_unit_locs, { combo.dsts[i_a][1], combo.dsts[i_a][2] })
            end
            --DBG.dbms(to_locs, false, 'to_locs')
            --DBG.dbms(to_unit_locs, false, 'to_unit_locs')

            -- The enemy being attacked is included here and might have HP=0. Need to
            -- use only valid enemies.
            local live_enemies = {}
            for id,loc in pairs(move_data.enemies) do
                if (move_data.unit_infos[id].hitpoints > 0) then
                    live_enemies[id] = loc
                end
            end

            FVS.set_virtual_state(old_locs, new_locs, fred_data.ops_data.place_holders, false, move_data)
            local virtual_reach_maps = FVS.virtual_reach_maps(live_enemies, to_unit_locs, to_locs, move_data)
            local status = FS.check_exposures(objectives, nil, virtual_reach_maps,
                { zone_id = zone_cfg.zone_id, exclude_leader = exclude_leader },
                fred_data
            )
            --DBG.dbms(status, false, 'status')

            local n_castles_threatened = org_status.castles.n_threatened
            local n_castles_protected = n_castles_threatened - status.castles.n_threatened
            --std_print('n_castles_protected: ', n_castles_protected, status.castles.n_threatened, n_castles_threatened)
            local castle_protect_bonus = math.sqrt(n_castles_protected) * 3
            --std_print('castle_protect_bonus', castle_protect_bonus)


            local village_protect_bonus = 0
            if objectives.protect.zones[zone_cfg.zone_id] then
                for _,village in pairs(objectives.protect.zones[zone_cfg.zone_id].villages) do
                    --std_print('  check protection of village: ' .. village.x .. ',' .. village.y)
                    local xy = 1000 * village.x + village.y
                    if status.villages[xy].is_protected then
                        --std_print('village is protected:', village.x .. ',' .. village.y, status.villages[xy].is_protected, village.raw_benefit)
                        -- TODO: should this be different if protection is possible otherwise? The problem
                        -- with that is that it then prefers attacks with more units (which have a higher
                        -- chance of protecting something behind them.
                        village_protect_bonus = village_protect_bonus + village.raw_benefit
                    end
                end
            end
            --std_print('village_protect_bonus', village_protect_bonus)


            -- Now check whether this attack protects the leader. If the leader is part
            -- of the attack, it is checked separately whether this is acceptable, thus
            -- the check is not performed in that case.
            -- For that rasons, this is also implemented as a penalty. Because attacks including
            -- the leader are considered acceptable. If this were a bonus, attacks without the
            -- leader would otherwise always be preferred.
            -- TODO: possibly make all protect checks penalties

            local leader_protect_penalty = 0
            if (not attack_includes_leader) then
                --std_print('--- checking leader protection: ' .. leader_id, leader_goal[1] .. ',' .. leader_goal[2])
                leader_protect_penalty = - status.leader.exposure
            end
            --std_print('leader_protect_penalty:', leader_protect_penalty)


            -- How much does protection of units increase
            local unit_protect_bonus = 0
            if objectives.protect.zones[zone_cfg.zone_id] then
                for _,unit in ipairs(objectives.protect.zones[zone_cfg.zone_id].units) do
                    --DBG.dbms(unit, false, "unit")

                    -- Only give the protect bonus for this protectee if _all_ attackers
                    -- are assigned as protectors for that unit. That not being the case
                    -- does not invalidate the attack, but we should not give a bonus for
                    -- protecting a unit with a weaker one.
                    local protect_pairings = objectives.protect.zones[zone_cfg.zone_id].protect_pairings
                    local try_protect = true
                    for i_a,attacker_damage in ipairs(combo.attacker_damages) do
                        --std_print('attacker: ', attacker_damage.id)
                        if (not protect_pairings[attacker_damage.id]) or (not protect_pairings[attacker_damage.id][unit.id]) then
                            try_protect = false
                            break
                        end
                    end
                    --std_print('  try_protect: ' .. unit.id, try_protect)

                    if try_protect then
                        local protect_unit_rating = status.units[unit.id].exposure
                        --std_print('protection: ' .. unit.id, org_status.units[unit.id].exposure - protect_unit_rating .. ' = ' .. org_status.units[unit.id].exposure .. ' - ' .. protect_unit_rating)
                        unit_protect_bonus = unit_protect_bonus + org_status.units[unit.id].exposure - protect_unit_rating
                    end
                end
            end
            --std_print('unit_protect_bonus', unit_protect_bonus)


            local acceptable_counter = true

            local power_needed = 0
            if status.leader.is_significant_threat
                and objectives.protect.zones[zone_cfg.zone_id]
                and objectives.protect.zones[zone_cfg.zone_id].protect_leader
            then
                local org_enemy_power = org_status.leader.best_protection and org_status.leader.best_protection[zone_cfg.zone_id] and org_status.leader.best_protection[zone_cfg.zone_id].zone_enemy_power or 0
                power_needed = status.leader.enemy_power - org_enemy_power
            end
            --std_print('power_needed', power_needed)

            if (power_needed > 2) then
                --std_print('--> checking resources for leader protection; power needed: ' .. power_needed)
                local power_available = 0
                for id,_ in pairs(fred_data.ops_data.assigned_units[zone_cfg.zone_id]) do
                    if move_data.my_units_MP[id] then
                        local is_used = false
                        for i_a,attacker_damage in ipairs(combo.attacker_damages) do
                            if (attacker_damage.id == id) then
                                is_used = true
                                break
                            end
                        end
                        -- TODO: should also check that unit can actually get there
                        if (not is_used) then
                            --std_print('  is_available: ' .. id)
                            power_available = power_available + move_data.unit_infos[id].current_power
                        end
                    end
                end
                --std_print('power_available: ' .. power_available)

                -- TODO: this is probably too simple, but let's see how it works
                if (power_available < value_ratio * power_needed) then
                    DBG.print_debug('attack_print_output', '    not enough units left to protect leader')
                    acceptable_counter = false
                end
            end

            local min_total_damage_rating = math.huge

            if (not acceptable_counter) then
                min_total_damage_rating = -9999 -- this is just for debug display purposes
                goto skip_counter_analysis
            end

            for i_a,attacker_damage in ipairs(combo.attacker_damages) do
                local attacker_info = move_data.unit_infos[attacker_damage.id]
                local attacker_can_move = true
                if move_data.my_units_noMP[attacker_info.id] then
                    attacker_can_move = false
                end
                DBG.print_debug('attack_print_output', '  by', attacker_info.id, combo.dsts[i_a][1], combo.dsts[i_a][2], 'can move:', attacker_can_move)

                -- Now calculate the counter attack outcome
                local attacker_moved = {}
                attacker_moved[attacker_info.id] = { combo.dsts[i_a][1], combo.dsts[i_a][2] }

                local counter_outcomes = FAU.calc_counter_attack(
                    attacker_moved, nil, nil, nil, virtual_reach_maps, cfg_attack, fred_data
                )
                --DBG.dbms(counter_outcomes, false, 'counter_outcomes')


                -- Note: the following is not strictly divided into attacker vs. defender
                -- any more, it's positive/negative ratings now, but the principle is still the same.
                -- forward attack: attacker damage rating and defender total rating
                -- counter attack: attacker total rating and defender damage rating
                -- as that is how the delayed damage is applied in game
                -- In addition, the counter attack damage needs to be multiplied
                -- by the chance of each unit to survive, otherwise units close
                -- to dying are much overrated
                -- That is then the damage that is used for the overall rating

                -- Damages to AI units (needs to be done for each counter attack
                -- as tables change upwards also)
                -- Delayed damages do not apply for attackers

                -- This is the damage on the AI attacker considered here
                -- in the counter attack
                local dam2 = counter_outcomes and counter_outcomes.defender_damage
                --DBG.dbms(dam2, false, 'dam2')

                local damages_my_units = {}
                for i_d,dam1 in ipairs(combo.attacker_damages) do
                    local dam = {}

                    -- First, take all the values as are from the forward combo outcome
                    for k,v in pairs(dam1) do
                        dam[k] = v
                    end

                    -- For the unit considered here, combine the results
                    -- For all other units they remain unchanged
                    if dam2 and (dam1.id == dam2.id) then
                        --std_print('-- my units --', dam1.id)
                        -- Unchanged: unit_value, max_hitpoints, id

                        --  damage: just add up the two
                        dam.damage = dam1.damage + dam2.damage
                        --std_print('  damage:', dam1.damage, dam2.damage, dam.damage)

                        local normal_damage_chance1 = 1 - dam1.die_chance - dam1.levelup_chance
                        local normal_damage_chance2 = 1 - dam2.die_chance - dam2.levelup_chance
                        --std_print('  normal_damage_chance (1, 2)', normal_damage_chance1,normal_damage_chance2)

                        --  - delayed_damage: only take that from the counter attack
                        --  TODO: this might underestimate poison etc.
                        dam.delayed_damage = dam2.delayed_damage
                        --std_print('  delayed_damage:', dam1.delayed_damage, dam2.delayed_damage, dam.delayed_damage)

                        --  - die_chance
                        dam.die_chance = dam1.die_chance + dam2.die_chance * normal_damage_chance1
                        --std_print('  die_chance:', dam1.die_chance, dam2.die_chance, dam.die_chance)

                        --  - levelup_chance
                        dam.levelup_chance = dam1.levelup_chance + dam2.levelup_chance * normal_damage_chance1
                        --std_print('  levelup_chance:', dam1.levelup_chance, dam2.levelup_chance, dam.levelup_chance)
                    end

                    damages_my_units[i_d] = dam
                end
                --DBG.dbms(damages_my_units, false, 'damages_my_units')


                -- Same for all the enemy units in the counter attack
                -- Delayed damages do not apply for same reason
                local dam1 = combo.defender_damage
                --DBG.dbms(dam1, false, 'dam1')

                local damages_enemy_units = {}
                local target_included = false
                if counter_outcomes then
                    for i_d,dam2 in ipairs(counter_outcomes.attacker_damages) do
                        local dam = {}

                        -- First, take all the values as are from the counter attack outcome
                        for k,v in pairs(dam2) do
                            dam[k] = v
                        end

                        -- For the unit considered here, combine the results
                        -- For all other units they remain unchanged
                        if dam1 and (dam1.id == dam2.id) then
                            --DBG.dbms(dam2, false, 'dam2')

                            -- For the target, we need to use the hitpoints from before the
                            -- forward attack, not from before the counter attack
                            dam.hitpoints = old_HP_target

                            target_included = true

                            --std_print('-- enemy units --', dam2.id)
                            -- Unchanged: unit_value, max_hitpoints, id

                            -- Derate the counter enemy rating by the CTD of the enemy. This is meant
                            -- to take into account that the enemy might or might not counter attack
                            -- when the CTD is high, so that the evaluation does not overrate
                            -- enemy units close to dying.
                            -- TODO: this is currently only done for the enemy rating, not the
                            -- AI unit rating. It might result in the AI being too timid.
                            local survival_weight = FU.weight_s(1 - dam2.die_chance, 0.75)
                            --std_print('  survival_weight, counter die chance', survival_weight, dam2.die_chance)

                            --  damage: just add up the two
                            dam.damage = dam1.damage + dam2.damage * survival_weight
                            --std_print('  damage:', dam1.damage, dam2.damage, dam.damage)

                            local normal_damage_chance1 = 1 - dam1.die_chance - dam1.levelup_chance
                            local normal_damage_chance2 = 1 - dam2.die_chance - dam2.levelup_chance
                            --std_print('  normal_damage_chance (1, 2)', normal_damage_chance1,normal_damage_chance2)

                            --  - delayed_damage: only take that from the forward attack
                            --  TODO: this might underestimate poison etc.
                            dam.delayed_damage = dam1.delayed_damage
                            --std_print('  delayed_damage:', dam1.delayed_damage, dam2.delayed_damage, dam.delayed_damage)

                            --  - die_chance
                            dam.die_chance = dam1.die_chance + dam2.die_chance * normal_damage_chance1 * survival_weight
                            --std_print('  die_chance:', dam1.die_chance, dam2.die_chance, dam.die_chance)

                            --  - levelup_chance
                            dam.levelup_chance = dam1.levelup_chance + dam2.levelup_chance * normal_damage_chance1 * survival_weight
                            --std_print('  levelup_chance:', dam1.levelup_chance, dam2.levelup_chance, dam.levelup_chance)
                        end

                        damages_enemy_units[i_d] = dam
                    end
                end

                -- The following covers both the case when there is no counter attack
                -- and when the target unit is not included in the counter attack
                if (not target_included) then
                    table.insert(damages_enemy_units, dam1)
                end

                --DBG.dbms(damages_enemy_units, false, 'damages_enemy_units')
                --DBG.dbms(combo, false, 'combo')

                --std_print('\nratings my units:')
                local neg_rating, pos_rating = 0, 0
                for _,damage in ipairs(damages_my_units) do
                    local _, nr, pr = FAU.damage_rating_unit(damage)
                    --std_print('  ' .. damage.id, nr, pr)
                    neg_rating = neg_rating + nr
                    pos_rating = pos_rating + pr
                end
                DBG.print_debug('attack_print_output', '    --> neg/pos rating after my units:', neg_rating, pos_rating)


                --std_print('ratings enemy units:')
                for _,damage in ipairs(damages_enemy_units) do
                    -- Enemy damage rating needs to be negative, and neg/pos switched
                    local _, nr, pr = FAU.damage_rating_unit(damage)
                    --std_print('  ' .. damage.id, nr, pr)
                    neg_rating = neg_rating - pr
                    pos_rating = pos_rating - nr
                end
                DBG.print_debug('attack_print_output', '    --> neg/pos rating after enemies:', neg_rating, pos_rating)

                local extra_rating = combo.rating_table.extra_rating
                DBG.print_debug('attack_print_output', '    --> extra rating:', extra_rating)
                DBG.print_debug('attack_print_output', '    --> bonus rating:', combo.bonus_rating)

                local value_ratio = zone_cfg.value_ratio
                DBG.print_debug('attack_print_output', '    --> value_ratio:', value_ratio)

                local damage_rating = neg_rating * value_ratio + pos_rating

                -- Also add in the bonus and extra ratings. They are
                -- used to select the best attack, but not to determine
                -- whether an attack is acceptable
                damage_rating = damage_rating + extra_rating + combo.bonus_rating

                DBG.print_debug('attack_print_output', '       --> damage_rating:', damage_rating)


                if (damage_rating < min_total_damage_rating) then
                    min_total_damage_rating = damage_rating
                end


                -- We next check whether the counter attack is acceptable
                -- This is different for the side leader and other units
                -- Also, it is different for attacks by individual units without MP;
                -- for those it simply matters whether the attack makes things
                -- better or worse, since there isn't a coice of moving someplace else
                if counter_outcomes and ((#combo.attacker_damages > 1) or attacker_can_move) then
                    local counter_min_hp = counter_outcomes.def_outcome.min_hp
                    -- If there's a chance of the leader getting poisoned, slowed or killed, don't do it
                    -- unless he is poisoned/slowed already
                    if attacker_info.canrecruit then
                        --std_print('Leader: slowed, poisoned %', counter_outcomes.def_outcome.slowed, counter_outcomes.def_outcome.poisoned)
                        if (counter_outcomes.def_outcome.slowed > 0.0) and (not attacker_info.status.slowed) then
                            DBG.print_debug('attack_print_output', '    leader: counter attack slow chance too high', counter_outcomes.def_outcome.slowed)
                            acceptable_counter = false
                            FAU.add_disqualified_attack(combo, i_a, disqualified_attacks)
                            break
                        end

                        if (counter_outcomes.def_outcome.poisoned > 0.0) and (not attacker_info.status.poisoned) and (not attacker_info.abilities.regenerate) then
                            DBG.print_debug('attack_print_output', '    leader: counter attack poison chance too high', counter_outcomes.def_outcome.poisoned)
                            acceptable_counter = false
                            FAU.add_disqualified_attack(combo, i_a, disqualified_attacks)
                            break
                        end

                        -- Add max damages from this turn and counter-attack
                        -- Note that this is not really the maximum damage from the attack, as
                        -- attacker.hitpoints is reduced to the average HP outcome of the attack
                        -- However, min_hp for the counter also contains this reduction, so
                        -- min_outcome below has the correct value (except for rounding errors,
                        -- that's why it is compared ot 0.5 instead of 0)
                        -- Note: we don't use this any more, but keep code for now for possibly resurrection
                        --local max_damage_attack = attacker.hitpoints - combo.att_outcomes[i_a].min_hp
                        --std_print('max_damage_attack, attacker.hitpoints, min_hp', max_damage_attack, attacker.hitpoints, combo.att_outcomes[i_a].min_hp)
                        -- Add damage from attack and counter attack
                        --local min_outcome = counter_min_hp - max_damage_attack
                        --std_print('Leader: min_outcome, counter_min_hp, max_damage_attack', min_outcome, counter_min_hp, max_damage_attack)

                        -- Approximate way of calculating the chance that the leader will die in the combination
                        -- of attack and counter attack. This should work reasonably well for small die chances, which
                        -- is all we're interested in. The exact value can only be obtained by running counter_calcs on
                        -- all combination of attacker/defender outcomes from the forward attack
                        local combined_hp_probs = {}
                        for hp_counter,chance_counter in pairs(counter_outcomes.def_outcome.hp_chance) do
                            if (chance_counter > 0) then
                                local dhp = hp_counter - move_data.unit_infos[attacker_info.id].hitpoints
                                for hp,chance in pairs(combo.att_outcomes[i_a].hp_chance) do
                                    if (chance > 0) then
                                        local new_hp = hp + dhp
                                        local added_chance = chance * chance_counter
                                        -- If the counter attack only involves a single unit (that is, the
                                        -- forward attack target itself), we can also multiply the
                                        -- counter chance by the survival chance of the target.
                                        -- This cannot be done accurately enough if there are more than one counter
                                        -- attackers, so we simply don't do it then (err on the conservative side).
                                        if (#counter_outcomes.att_outcomes == 1) then
                                            added_chance = added_chance * (1 - combo.def_outcome.hp_chance[0])
                                        end

                                        combined_hp_probs[new_hp] = (combined_hp_probs[new_hp] or 0) + added_chance
                                    end
                                end
                            end
                        end
                        --DBG.dbms(combined_hp_probs, false, 'combined_hp_probs')

                        local die_chance = 0
                        for hp,chance in pairs(combined_hp_probs) do
                            if (hp <= 0) then
                                die_chance = die_chance + chance
                            end
                        end
                        --std_print('Leader: die_chance', die_chance)

                        local av_outcome = counter_outcomes.def_outcome.average_hp
                        --std_print('Leader: av_outcome', av_outcome)

                        if (die_chance > leader_max_die_chance) or (av_outcome < attacker_info.max_hitpoints / 2) then
                            DBG.print_debug('attack_print_output', '    leader: counter attack outcome too low', die_chance)
                            acceptable_counter = false
                            FAU.add_disqualified_attack(combo, i_a, disqualified_attacks)
                            break
                        end
                    else  -- Or for normal units, evaluate whether the attack is worth it
                        if (not FAU.is_acceptable_attack(neg_rating, pos_rating, value_ratio)) then
                            DBG.print_debug('attack_print_output', '    non-leader: counter attack rating too low', pos_rating, neg_rating, value_ratio)
                            acceptable_counter = false
                            FAU.add_disqualified_attack(combo, i_a, disqualified_attacks)
                            break
                        end
                    end
                end


                -- Also don't expose one or two units too much, unless it is safe or
                -- there is a significant change to kill and value of kill is much
                -- larger than chance to die.
                -- Again single unit attacks of MP=0 units are dealt with separately
                local check_exposure = true
                local is_leader_threat = false

                -- If this is a leader threat, we do not check for exposure
                if objectives.leader.leader_threats
                    and objectives.leader.leader_threats.enemies
                    and objectives.leader.leader_threats.enemies[target_id]
                then
                    check_exposure = false
                    is_leader_threat = true
                end
                --std_print('check_exposure', check_exposure)


                -- Check whether die chance for units with high XP values is too high.
                -- This might not be sufficiently taken into account in the rating,
                -- especially if value_ratio is low.
                -- TODO: the equations used are pretty ad hoc at the moment. Refine?
                if (not is_leader_threat) and (damages_my_units[i_a].die_chance > 0) then
                    local id = damages_my_units[i_a].id
                    local xp = move_data.unit_infos[id].experience
                    local max_xp = move_data.unit_infos[id].max_experience
                    local min_xp = math.min(max_xp - 16, max_xp / 2)
                    if (min_xp < 0) then min_xp = 0 end

                    local xp_thresh = 0
                    if (xp > max_xp - 8) then
                        xp_thresh = 0.8 + 0.2 * (1 - (max_xp - xp) / 8)
                    elseif (xp > min_xp) then
                        xp_thresh = 0.8 * (xp - min_xp) / (max_xp - 8 - min_xp)
                    end

                    local survival_chance = 1 - damages_my_units[i_a].die_chance
                    --std_print(id, xp, min_xp, max_xp)
                    --std_print('  ' .. xp_thresh, survival_chance)

                    if (survival_chance < xp_thresh) then
                        DBG.print_debug('attack_print_output', '    non-leader: counter attack too dangerous for high-XP unit', survival_chance, xp_thresh, xp)
                        acceptable_counter = false
                        FAU.add_disqualified_attack(combo, i_a, disqualified_attacks)
                        break
                    end
                end


                -- If one of the attack hexes is adjacent to a unit with no MP
                -- left, we count this as not exposed
                if check_exposure then
                    for _,dst in pairs(combo.dsts) do
                        for xa,ya in H.adjacent_tiles(dst[1], dst[2]) do
                            if FGM.get_value(move_data.my_unit_map_noMP, xa, ya, 'id') then
                                check_exposure = false
                                break
                            end
                        end

                        if (not check_exposure) then break end
                    end
                end
                --std_print('check_exposure', check_exposure)

                if check_exposure and counter_outcomes
                    and (#combo.attacker_damages < 3) and (1.5 * #combo.attacker_damages < #damages_enemy_units)
                    and ((#combo.attacker_damages > 1) or attacker_can_move)
                then
                    --std_print('       outnumbered in counter attack: ' .. #combo.attacker_damages .. ' vs. ' .. #damages_enemy_units)
                    local die_value = damages_my_units[i_a].die_chance * damages_my_units[i_a].unit_value
                    local acceptable_die_value = acceptable_frac_die_value * damages_my_units[i_a].unit_value
                    --std_print('           die value ' .. damages_my_units[i_a].id .. ': ', die_value, damages_my_units[i_a].unit_value, acceptable_die_value)

                    local min_infl = math.huge
                    for _,dst in pairs(combo.dsts) do
                        local infl = FGM.get_value(move_data.influence_map, dst[1], dst[2], 'full_move_influence')
                        --std_print(' full_move_influence ' .. dst[1] .. ',' .. dst[2] .. ': ', infl)
                        if (infl < min_infl) then min_infl = infl end
                    end
                    --std_print(' min full_move_influence: ', min_infl)

                    if (min_infl < 0) then
                        local actual_rating = pos_rating + neg_rating
                        --std_print(actual_rating, pos_rating, neg_rating)
                        if (actual_rating < 0) then
                            DBG.print_debug('attack_print_output', '    non-leader: counter attack too isolated with negative rating', min_infl, actual_rating)
                            acceptable_counter = false
                            FAU.add_disqualified_attack(combo, i_a, disqualified_attacks)
                            break
                        end
                    end

                    if (die_value > acceptable_die_value) then
                        local kill_chance = combo.def_outcome.hp_chance[0]
                        local kill_value = kill_chance * move_data.unit_infos[target_id].unit_value
                        --std_print('         kill chance, kill_value: ', kill_chance, kill_value)

                        if (kill_chance < 0.33) or (kill_value < die_value * 2) then
                            DBG.print_debug('attack_print_output', '    non-leader: counter attack too exposed', die_value, kill_value, kill_chance)
                            acceptable_counter = false
                            FAU.add_disqualified_attack(combo, i_a, disqualified_attacks)
                            break
                        end
                    end
                end
            end

            ::skip_counter_analysis::

            FVS.reset_state(old_locs, new_locs, false, move_data)

            -- Now reset the hitpoints for attackers and defender
            for i_a,attacker_damage in ipairs(combo.attacker_damages) do
                move_data.unit_infos[attacker_damage.id].hitpoints = old_HP_attackers[i_a]
                move_data.unit_copies[attacker_damage.id].hitpoints = old_HP_attackers[i_a]
                if move_data.my_units_noMP[attacker_damage.id] then
                    local unit_proxy = COMP.get_unit(old_locs[i_a][1], old_locs[i_a][2])
                    unit_proxy.hitpoints = old_HP_attackers[i_a]
                end
            end

            move_data.unit_infos[target_id].hitpoints = old_HP_target
            move_data.unit_copies[target_id].hitpoints = old_HP_target
            target_proxy.hitpoints = old_HP_target


            -- Now we add the check for attacks by individual units with
            -- no MP. Here we simply compare the rating of not attacking
            -- vs. attacking. If attacking results in a better rating, we do it.
            -- But only if the chance to die in the forward attack is not too
            -- large; otherwise the enemy might as well waste the resources.
            -- Note that the acceptable counter checks above are different for noMP units
            if acceptable_counter and (#combo.attacker_damages == 1) then
                local attacker_info = move_data.unit_infos[combo.attacker_damages[1].id]
                if (combo.att_outcomes[1].hp_chance[0] < 0.25) then
                    if move_data.my_units_noMP[attacker_info.id] then
                        --DBG.print_ts_delta(fred_data.turn_start_time, '  by', attacker_info.id, combo.dsts[1][1], combo.dsts[1][2])

                        -- Now calculate the counter attack outcome
                        local attacker_moved = {}
                        attacker_moved[attacker_info.id] = { combo.dsts[1][1], combo.dsts[1][2] }

                        -- TODO: Use FVS here also?
                        local counter_outcomes = FAU.calc_counter_attack(
                            attacker_moved, old_locs, new_locs, fred_data.ops_data.place_holders, nil, cfg_attack, fred_data
                        )
                        --DBG.dbms(counter_outcomes, false, 'counter_outcomes')

                        --DBG.print_ts_delta(fred_data.turn_start_time, '   counter ratings no attack:', counter_outcomes.rating_table.rating, counter_outcomes.def_outcome.hp_chance[0])

                        -- Rating if no forward attack is done is done is only the counter attack rating
                        local no_attack_rating = 0
                        if counter_outcomes then
                            no_attack_rating = no_attack_rating - counter_outcomes.rating_table.rating
                        end
                        -- If an attack is done, it's the combined forward and counter attack rating
                        local with_attack_rating = min_total_damage_rating

                        --std_print('    V1: no attack rating: ', no_attack_rating, '<---', 0, -counter_outcomes.rating_table.rating)
                        --std_print('    V2: with attack rating:', with_attack_rating, '<---', combo.rating_table.rating, min_total_damage_rating)

                        if (with_attack_rating < no_attack_rating) then
                            acceptable_counter = false
                            -- Note the '1': (since this is a single-unit attack)
                            FAU.add_disqualified_attack(combo, 1, disqualified_attacks)
                        end
                        --std_print('acceptable_counter', acceptable_counter)
                    end
                else
                    -- Otherwise this is only acceptable if the chance to die
                    -- for the AI unit is not greater than for the enemy
                    if (combo.att_outcomes[1].hp_chance[0] > combo.def_outcome.hp_chance[0]) then
                        acceptable_counter = false
                    end
                end

                -- As a last option, if a unit cannot move and the attack with its main weapon has been found
                -- to be not acceptable, check whether it has another weapon with a range at which the enemy
                -- has no response. If so, this attack can be used without repercussion - but it should have
                -- lower priority than other attacks, as it might be possible for other units to free this unit.
                if (not acceptable_counter) and move_data.my_units_noMP[attacker_info.id] then
                    local target_id, target_loc = next(combo.target)
                    --std_print('Checking for unopposed attack: ' .. attacker_info.id, target_id)

                    local unit_attack = fred_data.ops_data.unit_attacks[attacker_info.id][target_id]
                    if unit_attack.nostrikeback then
                        --DBG.dbms(unit_attack.nostrikeback, false, 'nostrikeback')
                        acceptable_counter = true

                        local hitchance = 1 - FDI.get_unit_defense(move_data.unit_copies[target_id], target_loc[1], target_loc[2], fred_data.caches.defense_maps)
                        min_total_damage_rating = unit_attack.nostrikeback.base_done * hitchance
                            + unit_attack.nostrikeback.extra_done
                            - unit_attack.enemy_regen
                        -- Let's do other attacks first
                        -- TODO: might make this conditional on whether the unit actually has moves left
                        --   or is trapped, if it's the leader, ...
                        min_total_damage_rating = min_total_damage_rating - 100

                        local new_combo = {
                            attacker_damages = { { id = attacker_info.id } },
                            defender_damage = { id = target_id },
                            weapons = { unit_attack.nostrikeback.weapon },
                            target = combo.target,
                            dsts = combo.dsts,
                            rating_table = { rating = min_total_damage_rating },
                            derating = 1,
                            pre_rating = -999,
                            penalty_rating = combo.penalty_rating,
                            penalty_str = combo.penalty_str
                        }
                        -- It should be okay to modify the combo table here
                        -- This is done so that no incorrect information is accidentally used below
                        combo = new_combo
                    end
                end
            end

            --DBG.print_ts_delta(fred_data.turn_start_time, '  acceptable_counter', acceptable_counter)
            local total_rating = -9999
            local leader_protect_weight = FCFG.get_cfg_parm('leader_protect_weight')
            local castle_protect_weight = FCFG.get_cfg_parm('castle_protect_weight')
            local village_protect_weight = FCFG.get_cfg_parm('village_protect_weight')
            local unit_protect_weight = FCFG.get_cfg_parm('unit_protect_weight')
            if acceptable_counter then
                total_rating = min_total_damage_rating + combo.penalty_rating
                total_rating = total_rating + leader_protect_penalty * leader_protect_weight
                total_rating = total_rating + castle_protect_bonus * castle_protect_weight
                total_rating = total_rating + village_protect_bonus * village_protect_weight
                total_rating = total_rating + unit_protect_bonus * unit_protect_weight

                DBG.print_debug('attack_print_output', '  Penalty rating:', combo.penalty_rating, combo.penalty_str)
                DBG.print_debug('attack_print_output', '  Acceptable counter attack for attack on', count, next(combo.target), combo.rating_table.rating)
                DBG.print_debug('attack_print_output', '  leader protect penalty        ', leader_protect_penalty .. ' * ' .. leader_protect_weight)
                DBG.print_debug('attack_print_output', '  castle, village and unit protect bonus', castle_protect_bonus .. ' * ' .. castle_protect_weight .. '   --   ' .. village_protect_bonus .. ' * ' .. village_protect_weight .. '   --   ' .. unit_protect_bonus .. ' * ' .. unit_protect_weight)
                DBG.print_debug('attack_print_output', '    --> total_rating', total_rating)

                if (total_rating > 0) then
                    total_rating = total_rating * combo.derating
                end
                DBG.print_debug('attack_print_output', '    --> total_rating adjusted', total_rating)

                if (total_rating > max_total_rating) then
                    max_total_rating = total_rating

                    action = { units = {}, dsts = {}, enemy = combo.target }

                    -- This is done simply so that the table is shorter when displayed.
                    for _,attacker_damage in ipairs(combo.attacker_damages) do
                        local tmp_unit = move_data.my_units[attacker_damage.id]
                        tmp_unit.id = attacker_damage.id
                        table.insert(action.units, tmp_unit)
                    end

                    action.dsts = combo.dsts
                    action.weapons = combo.weapons
                    action.action_str = zone_cfg.action_str

                    local enemy_leader_die_chance = 0
                    if move_data.unit_infos[combo.defender_damage.id].canrecruit then
                        enemy_leader_die_chance = combo.defender_damage.die_chance
                    end
                    action.enemy_leader_die_chance = enemy_leader_die_chance
                end
            end

            if DBG.show_debug('attack_combos') then
                local msg_str = string.format('Attack combo %d/%d:    %.3f    (%.3f  max)\n'
                    .. '      damage rating:           %.3f * %.3f    (pre_rating: %.3f)\n'
                    .. '      penalties:               %.3f      %s\n'
                    .. '      leader protect penalty:  %.3f * %.2f\n'
                    .. '      castle protect bonus:   %.3f * %.2f\n'
                    .. '      village protect bonus:   %.3f * %.2f\n'
                    .. '      unit protect bonus:      %.3f * %.2f',
                    count, #combo_ratings, total_rating, (max_total_rating or 0), min_total_damage_rating,
                    combo.derating, combo.pre_rating, combo.penalty_rating, combo.penalty_str,
                    leader_protect_penalty, leader_protect_weight,
                    castle_protect_bonus, castle_protect_weight,
                    village_protect_bonus, village_protect_weight,
                    unit_protect_bonus, unit_protect_weight
                )
                wesnoth.label { x = target_loc[1], y = target_loc[2], text = "target", color = '255,0,0' }
                wesnoth.scroll_to_tile(target_loc[1], target_loc[2])
                wesnoth.wml_actions.message { speaker = 'narrator', message = msg_str}
                wesnoth.label { x = target_loc[1], y = target_loc[2], text = "" }
                for i_a,_ in ipairs(combo.attacker_damages) do
                    local x, y = combo.dsts[i_a][1], combo.dsts[i_a][2]
                    wesnoth.label { x = x, y = y, text = "" }
                end
                if (not attack_includes_leader) then
                    wesnoth.label { x = leader_goal[1], y = leader_goal[2], text = "" }
                end
                for _,unit in ipairs(fred_data.ops_data.place_holders) do
                    wesnoth.label { x = unit[1], y = unit[2], text = "" }
                end
            end
        end
    end

    if DBG.show_debug('attack_best_combo') then
        if action then
            local attack_includes_leader = false
            for _,unit in ipairs(fred_data.ops_data.place_holders) do
                wesnoth.label { x = unit[1], y = unit[2], text = 'recruit\n' .. unit.type, color = '160,160,160' }
            end
            for i_a,attacker in ipairs(action.units) do
                wesnoth.label { x = action.dsts[i_a][1], y = action.dsts[i_a][2], text = attacker.id }
                if move_data.unit_infos[attacker.id].canrecruit then
                    attack_includes_leader = true
                end
            end
            if (not attack_includes_leader) then
                wesnoth.label { x = leader_goal[1], y = leader_goal[2], text = 'leader goal', color = '200,0,0' }
            end
            local _,target_loc = next(action.enemy)
            wesnoth.label { x = target_loc[1], y = target_loc[2], text = "best target", color = '255,0,0' }
            wesnoth.scroll_to_tile(target_loc[1], target_loc[2])
            wesnoth.wml_actions.message { speaker = 'narrator', message = 'Best attack combo' }
            wesnoth.label { x = target_loc[1], y = target_loc[2], text = "" }
            for i_a,attacker in ipairs(action.units) do
                wesnoth.label { x = action.dsts[i_a][1], y = action.dsts[i_a][2], text = "" }
            end
            if (not attack_includes_leader) then
                wesnoth.label { x = leader_goal[1], y = leader_goal[2], text = "" }
            end
            for _,unit in ipairs(fred_data.ops_data.place_holders) do
                wesnoth.label { x = unit[1], y = unit[2], text = "" }
            end
        end
    end

    --DBG.dbms(disqualified_attacks, false, 'disqualified_attacks')

    return action  -- returns nil is no acceptable attack was found
end

return fred_attack
