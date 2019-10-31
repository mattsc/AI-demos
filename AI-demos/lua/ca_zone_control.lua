local H = wesnoth.require "helper"
local AH = wesnoth.require "ai/lua/ai_helper.lua"
local AHL = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper_local.lua"
local FGM = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_map.lua"
local FGUI = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_gamestate_utils_incremental.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local FS = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_status.lua"
local FVS = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_virtual_state.lua"
local FBU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_benefits_utilities.lua"
local FOU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_ops_utils.lua"
local FAU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack_utils.lua"
local LS = wesnoth.require "location_set"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"
local FRU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_retreat_utils.lua"
local FHU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_hold_utils.lua"
local FMLU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_move_leader_utils.lua"
local FCFG = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_config.lua"
local FMC = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_map_config.lua"

----- Attack: -----
local function get_attack_action(zone_cfg, fred_data)
    DBG.print_debug_time('eval', fred_data.turn_start_time, '  --> attack evaluation: ' .. zone_cfg.zone_id)
    --DBG.dbms(zone_cfg, false, 'zone_cfg')

    local move_data = fred_data.move_data
    local move_cache = fred_data.move_cache

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
            if move_data.unit_infos[id].canrecruit and (move_data.unit_infos[id].moves > 0) then
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
    --DBG.print_ts_delta(fred_data.turn_start_time, 'value_ratio', value_ratio)

    -- We need to make sure the units always use the same weapon below, otherwise
    -- the comparison is not fair.
    local cfg_attack = { value_ratio = value_ratio }

    local interactions = fred_data.ops_data.interaction_matrix.penalties['att']
    --DBG.dbms(interactions, false, 'interactions')
    local reserved_actions = fred_data.ops_data.reserved_actions
    local penalty_infos = { src = {}, dst = {} }

    local leader_id = move_data.leaders[wesnoth.current.side].id

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
            zone_units_attacks, target, cfg_attack, move_data.effective_reach_maps, false, move_data, move_cache
        )
        --DBG.print_ts_delta(fred_data.turn_start_time, '#attack_combos', #attack_combos)


        for j,combo in ipairs(attack_combos) do
            --DBG.print_ts_delta(fred_data.turn_start_time, 'combo ' .. j)

            -- Only check out the first 1000 attack combos to keep evaluation time reasonable
            -- TODO: can we have these ordered with likely good rating first?
            if (j > 1000) then break end

            local attempt_trapping = is_trappable_enemy

            local combo_outcome = FAU.attack_combo_eval(combo, target, cfg_attack, move_data, move_cache)

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

                        if (attacker_info.moves > 0) then
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
                                wesnoth.put_unit(move_data.unit_copies[id], dst[1], dst[2])
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
                                wesnoth.extract_unit(move_data.unit_copies[id])
                                move_data.unit_copies[id].x, move_data.unit_copies[id].y = move_data.units[id][1], move_data.units[id][2]
                            end
                            --std_print(id, dst[1], dst[2], move_data.unit_copies[id].x, move_data.unit_copies[id].y)
                        end

                        if can_reach then
                            do_attack = false
                        end
                    else
                        local unit_value = FU.unit_value(move_data.unit_infos[target_id])
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
                    local defense = FGUI.get_unit_defense(move_data.unit_copies[target_id], target_loc[1], target_loc[2], move_data.defense_maps)
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
                                    local defense = FGUI.get_unit_defense(move_data.unit_copies[target_id], xa, ya, move_data.defense_maps)
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
                        local unit_value = FU.unit_value(move_data.unit_infos[target_id])
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

                    poison_penalty = poison_penalty / target_info.max_hitpoints * FU.unit_value(target_info)
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

                    slow_penalty = slow_penalty / target_info.max_hitpoints * FU.unit_value(target_info)
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
    local max_total_rating, action
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
                    wesnoth.wml_actions.label { x = unit[1], y = unit[2], text = 'recruit\n' .. unit.type, color = '160,160,160' }
                end
                if (not attack_includes_leader) then
                    wesnoth.wml_actions.label { x = leader_goal[1], y = leader_goal[2], text = 'leader goal', color = '200,0,0' }
                end
            end

            for i_a,attacker_damage in ipairs(combo.attacker_damages) do
                if DBG.show_debug('attack_combos') then
                    local x, y = combo.dsts[i_a][1], combo.dsts[i_a][2]
                    wesnoth.wml_actions.label { x = x, y = y, text = attacker_damage.id }
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
                    local unit_proxy = wesnoth.get_unit(old_locs[i_a][1], old_locs[i_a][2])
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
                    table.insert(old_locs, move_data.leaders[wesnoth.current.side])
                    table.insert(new_locs, leader_goal)
                end
            end

            -- Also set the hitpoints for the defender
            local target_id, target_loc = next(combo.target)
            local target_proxy = wesnoth.get_unit(target_loc[1], target_loc[2])
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
            for x,y,_ in FGM.iter(move_data.reachable_castles_map[wesnoth.current.side]) do
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
                            power_available = power_available + FU.unit_current_power(move_data.unit_infos[id])
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

            local min_total_damage_rating = 9e99

            if (not acceptable_counter) then
                min_total_damage_rating = -9999 -- this is just for debug display purposes
                goto skip_counter_analysis
            end

            for i_a,attacker_damage in ipairs(combo.attacker_damages) do
                local attacker_info = move_data.unit_infos[attacker_damage.id]
                DBG.print_debug('attack_print_output', '  by', attacker_info.id, combo.dsts[i_a][1], combo.dsts[i_a][2])

                -- Now calculate the counter attack outcome
                local attacker_moved = {}
                attacker_moved[attacker_info.id] = { combo.dsts[i_a][1], combo.dsts[i_a][2] }

                local counter_outcomes = FAU.calc_counter_attack(
                    attacker_moved, nil, nil, nil, virtual_reach_maps, cfg_attack, move_data, move_cache
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
                if counter_outcomes and ((#combo.attacker_damages > 1) or (attacker_info.moves > 0)) then
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
                    and ((#combo.attacker_damages > 1) or (move_data.unit_infos[combo.attacker_damages[1].id].moves > 0))
                then
                    --std_print('       outnumbered in counter attack: ' .. #combo.attacker_damages .. ' vs. ' .. #damages_enemy_units)
                    local die_value = damages_my_units[i_a].die_chance * damages_my_units[i_a].unit_value
                    --std_print('           die value ' .. damages_my_units[i_a].id .. ': ', die_value, damages_my_units[i_a].unit_value)

                    if (die_value > 0) then
                        local kill_chance = combo.def_outcome.hp_chance[0]
                        local kill_value = kill_chance * FU.unit_value(move_data.unit_infos[target_id])
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
                    local unit_proxy = wesnoth.get_unit(old_locs[i_a][1], old_locs[i_a][2])
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
            if acceptable_counter and (#combo.attacker_damages == 1) then
                if (combo.att_outcomes[1].hp_chance[0] < 0.25) then
                    local attacker_info = move_data.unit_infos[combo.attacker_damages[1].id]

                    if (attacker_info.moves == 0) then
                        --DBG.print_ts_delta(fred_data.turn_start_time, '  by', attacker_info.id, combo.dsts[1][1], combo.dsts[1][2])

                        -- Now calculate the counter attack outcome
                        local attacker_moved = {}
                        attacker_moved[attacker_info.id] = { combo.dsts[1][1], combo.dsts[1][2] }

                        -- TODO: Use FVS here also?
                        local counter_outcomes = FAU.calc_counter_attack(
                            attacker_moved, old_locs, new_locs, fred_data.ops_data.place_holders, nil, cfg_attack, move_data, move_cache
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

                if (not max_total_rating) or (total_rating > max_total_rating) then
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
                wesnoth.wml_actions.label { x = target_loc[1], y = target_loc[2], text = "target", color = '255,0,0' }
                wesnoth.scroll_to_tile(target_loc[1], target_loc[2])
                wesnoth.wml_actions.message { speaker = 'narrator', message = msg_str}
                wesnoth.wml_actions.label { x = target_loc[1], y = target_loc[2], text = "" }
                for i_a,_ in ipairs(combo.attacker_damages) do
                    local x, y = combo.dsts[i_a][1], combo.dsts[i_a][2]
                    wesnoth.wml_actions.label { x = x, y = y, text = "" }
                end
                if (not attack_includes_leader) then
                    wesnoth.wml_actions.label { x = leader_goal[1], y = leader_goal[2], text = "" }
                end
                for _,unit in ipairs(fred_data.ops_data.place_holders) do
                    wesnoth.wml_actions.label { x = unit[1], y = unit[2], text = "" }
                end
            end
        end
    end

    if DBG.show_debug('attack_best_combo') then
        if action then
            local attack_includes_leader = false
            for _,unit in ipairs(fred_data.ops_data.place_holders) do
                wesnoth.wml_actions.label { x = unit[1], y = unit[2], text = 'recruit\n' .. unit.type, color = '160,160,160' }
            end
            for i_a,attacker in ipairs(action.units) do
                wesnoth.wml_actions.label { x = action.dsts[i_a][1], y = action.dsts[i_a][2], text = attacker.id }
                if move_data.unit_infos[attacker.id].canrecruit then
                    attack_includes_leader = true
                end
            end
            if (not attack_includes_leader) then
                wesnoth.wml_actions.label { x = leader_goal[1], y = leader_goal[2], text = 'leader goal', color = '200,0,0' }
            end
            local _,target_loc = next(action.enemy)
            wesnoth.wml_actions.label { x = target_loc[1], y = target_loc[2], text = "best target", color = '255,0,0' }
            wesnoth.scroll_to_tile(target_loc[1], target_loc[2])
            wesnoth.wml_actions.message { speaker = 'narrator', message = 'Best attack combo' }
            wesnoth.wml_actions.label { x = target_loc[1], y = target_loc[2], text = "" }
            for i_a,attacker in ipairs(action.units) do
                wesnoth.wml_actions.label { x = action.dsts[i_a][1], y = action.dsts[i_a][2], text = "" }
            end
            if (not attack_includes_leader) then
                wesnoth.wml_actions.label { x = leader_goal[1], y = leader_goal[2], text = "" }
            end
            for _,unit in ipairs(fred_data.ops_data.place_holders) do
                wesnoth.wml_actions.label { x = unit[1], y = unit[2], text = "" }
            end
        end
    end

    --DBG.dbms(disqualified_attacks, false, 'disqualified_attacks')

    return action  -- returns nil is no acceptable attack was found
end


----- Hold: -----
local function get_hold_action(zone_cfg, fred_data)
    DBG.print_debug_time('eval', fred_data.turn_start_time, '  --> hold evaluation (' .. zone_cfg.action_str .. '): ' .. zone_cfg.zone_id)

    local value_ratio = zone_cfg.value_ratio or fred_data.ops_data.behavior.orders.value_ratio
    local max_units = 3
    local max_hexes = 6
    local leader_derating = FCFG.get_cfg_parm('leader_derating')

    -- Ratio of forward to counter attack to consider for holding evaluation
    -- Set up so that:
    --   factor_counter + factor_forward = 1
    --   factor_counter / factor_forward = value_ratio
    local factor_counter = 1 / (1 + 1 / value_ratio)
    local factor_forward = 1 - factor_counter
    --std_print('factor_counter, factor_forward', factor_counter, factor_forward)

    local front_ld = 0
    if fred_data.ops_data.fronts.zones[zone_cfg.zone_id] then
        front_ld = fred_data.ops_data.fronts.zones[zone_cfg.zone_id].ld
    end
    local push_factor = fred_data.ops_data.behavior.zone_push_factors[zone_cfg.zone_id] or fred_data.ops_data.behavior.orders.push_factor
    local rel_push_factor = push_factor / value_ratio
    --std_print('push_factor, rel_push_factor: ' .. zone_cfg.zone_id, push_factor, rel_push_factor)

    local acceptable_ctd = rel_push_factor - 1
    if (acceptable_ctd < 0) then acceptable_ctd = 0 end
    --std_print('acceptable_ctd: ' .. acceptable_ctd)

    local acceptable_max_damage_ratio = rel_push_factor / 2
    --std_print('acceptable_max_damage_ratio: ' .. acceptable_max_damage_ratio)

    -- This uses the absolute push factor, not the relative one;
    -- Do not hold for push_factors < 1, unless there is very little damage to be expected
    -- TODO: there's a discontinuity here that might not be good
    local acceptable_actual_damage_ratio = push_factor
    if (push_factor < 1) then
        acceptable_actual_damage_ratio = push_factor^2 / 10.
    end
    --std_print(zone_cfg.zone_id .. ': acceptable_actual_damage_ratio: ' .. acceptable_actual_damage_ratio)


    local vuln_weight = FCFG.get_cfg_parm('vuln_weight')
    local vuln_rating_weight = vuln_weight * (1 / value_ratio - 1)
    if (vuln_rating_weight < 0) then
        vuln_rating_weight = 0
    end
    --std_print('vuln_weight, vuln_rating_weight', vuln_weight, vuln_rating_weight)

    local forward_weight = FCFG.get_cfg_parm('forward_weight')
    local forward_rating_weight = forward_weight * (1 / value_ratio)
    --std_print('forward_weight, forward_rating_weight', forward_weight, forward_rating_weight)

    local influence_ratio = fred_data.ops_data.behavior.orders.current_power_ratio
    local base_value_ratio = fred_data.ops_data.behavior.orders.base_value_ratio / fred_data.ops_data.behavior.orders.value_ratio * value_ratio
    local protect_forward_rating_weight = (influence_ratio / base_value_ratio) - 1
    protect_forward_rating_weight = protect_forward_rating_weight * FCFG.get_cfg_parm('protect_forward_weight')
    --std_print('protect_forward_rating_weight', protect_forward_rating_weight)


    local raw_cfg = FMC.get_raw_cfgs(zone_cfg.zone_id)
    --DBG.dbms(raw_cfg, false, 'raw_cfg')
    --DBG.dbms(zone_cfg, false, 'zone_cfg')

    local move_data = fred_data.move_data

    local protect_objectives = fred_data.ops_data.objectives.protect.zones[zone_cfg.zone_id] or {}
    --DBG.dbms(protect_objectives, false, 'protect_objectives')
    --std_print('protect_leader ' .. zone_cfg.zone_id, protect_objectives.protect_leader)

    -- Holders are those specified in zone_units, or all units except the leader otherwise
    -- Except when we are only trying to protect units (not other protect goals), in that
    -- case it has been pre-determined who can protect
    -- TODO: does it make sense to do this in the setup of the zone_cfg instead?
    local holders = {}

    if protect_objectives.units and (#protect_objectives.units > 0)
        and (not protect_objectives.protect_leader)
        and ((not protect_objectives.villages) or (#protect_objectives.villages == 0))
    then
        --std_print(zone_cfg.zone_id .. ': units to protect (and only units)')
        holders = {}
        for id,_ in pairs(protect_objectives.protect_pairings) do
            holders[id] = move_data.units[id][1] * 1000 + move_data.units[id][2]
        end
    elseif zone_cfg.zone_units then
        holders = zone_cfg.zone_units
    else
        for id,_ in pairs(move_data.my_units_MP) do
            if (not move_data.unit_infos[id].canrecruit) then
                holders[id] = FU.unit_base_power(move_data.unit_infos[id])
            end
        end
    end
    if (not next(holders)) then return end
    --DBG.dbms(holders, false, 'holders')


    local leader_goal = fred_data.ops_data.objectives.leader.final
    --DBG.dbms(leader_goal, false, 'leader_goal')

    local zone = wesnoth.get_locations(raw_cfg.ops_slf)
    if protect_objectives.protect_leader then
        -- When leader is threatened, we add area around goal position and all castle hexes
        -- TODO: this kind of works on Freelands, but probably not on all maps
        local add_hexes = wesnoth.get_locations {
            x = leader_goal[1], y = leader_goal[2], radius = 3
        }
        for _,hex in ipairs(add_hexes) do
            table.insert(zone, hex)
        end
        -- Castles are only added if the leader can get to a keep
        -- TODO: reevaluate later if this should be changed
        for x,y,_ in FGM.iter(move_data.reachable_castles_map[wesnoth.current.side]) do
            table.insert(zone, { x, y })
            for xa,ya in H.adjacent_tiles(x, y) do
                table.insert(zone, { xa, ya })
            end
        end
    end

    -- avoid_map is currently only used to exclude the leader's goal position from holding
    -- This is needed because otherwise the hold counter attack analysis of leader threats
    -- does not work.
    -- TODO: find a better way of dealing with this, using backup leader goals instead.
    -- avoid_map also opens up the option of including [avoid] tags or similar functionality later.
    local avoid_map = {}
    FGM.set_value(avoid_map, leader_goal[1], leader_goal[2], 'is_avoided', true)

    local zone_map = {}
    for _,loc in ipairs(zone) do
        if (not FGM.get_value(avoid_map, loc[1], loc[2], 'is_avoided')) then
            FGM.set_value(zone_map, loc[1], loc[2], 'in_zone', true)
        end
    end
    if DBG.show_debug('hold_zone_map') then
        DBG.show_fgumap_with_message(zone_map, 'in_zone', 'Zone map')
    end

    -- For the enemy rating, we need to put a 1-hex buffer around this
    -- So this includes the leader position (and at least part of avoid_map).
    -- TODO: I think this is okay, reconsider later
    local buffered_zone_map = {}
    for x,y,_ in FGM.iter(zone_map) do
        FGM.set_value(buffered_zone_map, x, y, 'in_zone', true)
        for xa,ya in H.adjacent_tiles(x, y) do
            FGM.set_value(buffered_zone_map, xa, ya, 'in_zone', true)
        end
    end
    if false then
        DBG.show_fgumap_with_message(buffered_zone_map, 'in_zone', 'Buffered zone map')
    end


    local enemy_zone_maps = {}
    local holders_influence = {}
    for enemy_id,_ in pairs(move_data.enemies) do
        enemy_zone_maps[enemy_id] = {}

        for x,y,_ in FGM.iter(buffered_zone_map) do
            local enemy_defense = FGUI.get_unit_defense(move_data.unit_copies[enemy_id], x, y, move_data.defense_maps)
            FGM.set_value(enemy_zone_maps[enemy_id], x, y, 'hit_chance', 1 - enemy_defense)

            local moves_left = FGM.get_value(move_data.reach_maps[enemy_id], x, y, 'moves_left')
            if moves_left then
                FGM.set_value(enemy_zone_maps[enemy_id], x, y, 'moves_left', moves_left)
            end
        end
    end

    for enemy_id,enemy_loc in pairs(move_data.enemies) do
        for x,y,_ in FGM.iter(zone_map) do
            --std_print(x,y)

            local enemy_hcs = {}
            local min_dist, max_dist
            for xa,ya in H.adjacent_tiles(x, y) do
                -- Need the range of distance whether the enemy can get there or not
                local dist = wesnoth.map.distance_between(enemy_loc[1], enemy_loc[2], xa, ya)
                if (not max_dist) or (dist > max_dist) then
                    max_dist = dist
                end
                if (not min_dist) or (dist < min_dist) then
                    min_dist = dist
                end

                local moves_left = FGM.get_value(enemy_zone_maps[enemy_id], xa, ya, 'moves_left')
                if moves_left then
                    local ehc = FGM.get_value(enemy_zone_maps[enemy_id], xa, ya, 'hit_chance')
                    table.insert(enemy_hcs, {
                        ehc = ehc, dist = dist
                    })
                end
            end

            local adj_hc, cum_weight = 0, 0
            if max_dist then
                local dd = max_dist - min_dist
                for _,data in ipairs(enemy_hcs) do
                    local w = (max_dist - data.dist) / dd
                    adj_hc = adj_hc + data.ehc * w
                    cum_weight = cum_weight + w
                end
            end

            -- Note that this will give a 'nil' on the hex the enemy is on,
            -- but that's okay as the AI cannot reach that hex anyway
            if (cum_weight > 0) then
                adj_hc = adj_hc / cum_weight
                FGM.set_value(enemy_zone_maps[enemy_id], x, y, 'adj_hit_chance', adj_hc)

                local enemy_count = (FGM.get_value(holders_influence, x, y, 'enemy_count') or 0) + 1
                FGM.set_value(holders_influence, x, y, 'enemy_count', enemy_count)
            end
        end

        if false then
            --DBG.show_fgumap_with_message(enemy_zone_maps[enemy_id], 'hit_chance', 'Enemy hit chance', move_data.unit_copies[enemy_id])
            --DBG.show_fgumap_with_message(enemy_zone_maps[enemy_id], 'moves_left', 'Enemy moves left', move_data.unit_copies[enemy_id])
            DBG.show_fgumap_with_message(enemy_zone_maps[enemy_id], 'adj_hit_chance', 'Enemy adjacent hit_chance', move_data.unit_copies[enemy_id])
        end
    end


    for id,_ in pairs(holders) do
        --std_print('\n' .. id, zone_cfg.zone_id)

        for x,y,_ in FGM.iter(move_data.unit_attack_maps[1][id]) do
            local unit_influence = FU.unit_terrain_power(move_data.unit_infos[id], x, y, move_data)
            local inf = FGM.get_value(holders_influence, x, y, 'my_influence') or 0
            FGM.set_value(holders_influence, x, y, 'my_influence', inf + unit_influence)

            local my_count = (FGM.get_value(holders_influence, x, y, 'my_count') or 0) + 1
            FGM.set_value(holders_influence, x, y, 'my_count', my_count)


            local enemy_influence = FGM.get_value(move_data.influence_maps, x, y, 'enemy_influence') or 0

            FGM.set_value(holders_influence, x, y, 'enemy_influence', enemy_influence)
            holders_influence[x][y].influence = inf + unit_influence - enemy_influence
        end
    end

    for x,y,data in FGM.iter(holders_influence) do
        if data.influence then
            local influence = data.influence
            local tension = data.my_influence + data.enemy_influence
            local vulnerability = tension - math.abs(influence)

            local ld = FGM.get_value(fred_data.ops_data.leader_distance_map, x, y, 'distance')
            vulnerability = vulnerability + ld / 10

            data.tension = tension
            data.vulnerability = vulnerability
        end
    end


    if DBG.show_debug('hold_influence_map') then
        --DBG.show_fgumap_with_message(holders_influence, 'my_influence', 'Holders influence')
        --DBG.show_fgumap_with_message(holders_influence, 'enemy_influence', 'Enemy influence')
        DBG.show_fgumap_with_message(holders_influence, 'influence', 'Influence')
        --DBG.show_fgumap_with_message(holders_influence, 'tension', 'tension')
        DBG.show_fgumap_with_message(holders_influence, 'vulnerability', 'vulnerability')
        --DBG.show_fgumap_with_message(holders_influence, 'my_count', 'My count')
        --DBG.show_fgumap_with_message(holders_influence, 'enemy_count', 'Enemy count')
    end


    local enemy_weights = {}
    for id,_ in pairs(holders) do
        enemy_weights[id] = {}
        for enemy_id,_ in pairs(move_data.enemies) do
            local att = fred_data.ops_data.unit_attacks[id][enemy_id]
            --DBG.dbms(att, false, 'att')

            -- It's probably okay to keep the hard-coded weight of 0.5 here, as the
            -- damage taken is most important for which units the enemy will select
            local weight = att.damage_counter.base_taken + att.damage_counter.extra_taken
            weight = weight - 0.5 * (att.damage_counter.base_done + att.damage_counter.extra_done)
            if (weight < 1) then weight = 1 end

            enemy_weights[id][enemy_id] = { weight = weight }
        end
    end
    --DBG.dbms(enemy_weights, false, 'enemy_weights')

    -- Eventual TODO: this contains both the leader hex and id;
    --   Eventually do this consistently as for other units, by changing one or the other
    local leader = move_data.leaders[wesnoth.current.side]

    -- protect_locs and assigned_enemies are only used to calculate between_map
    -- protect_locs being set also serves as flag whether a protect hold is desired
    -- If leader is to be protected we use leader_goal and castle hexes for between_map
    -- Otherwise, all the other hexes/units to be protected are used
    -- TODO: maybe always use all, but with different weights?
    -- Castles are only added if the leader can get to a keep
    -- TODO: reevaluate later if this should be changed
    local protect_locs, assigned_enemies
    if protect_objectives.protect_leader then
        local exposure = fred_data.ops_data.status.leader.exposure
        if (exposure > 0) then
            protect_locs = { {
                leader_goal[1], leader_goal[2],
                exposure = exposure
            } }
        end
        for _,loc in ipairs(fred_data.ops_data.status.castles.locs) do
            if (not protect_locs) then protect_locs = {} end
            table.insert(protect_locs, {
                loc[1], loc[2],
                exposure = 3
            })
        end
        assigned_enemies = fred_data.ops_data.objectives.leader.leader_threats.enemies
    else
        -- TODO: change format of protect_locs, so that simply objectives.protect can be taken
        local locs, exposures = {}, {}
        if protect_objectives.units then
            for _,unit in ipairs(protect_objectives.units) do
                -- It's possible for exposure to be zero, if the counter attack is much in favor of the AI unit
                local exposure = fred_data.ops_data.status.units[unit.id].exposure
                if (exposure > 0) then
                    table.insert(locs, unit)
                    table.insert(exposures, exposure)
                end
            end
        end
        if protect_objectives.villages then
            for _,village in ipairs(protect_objectives.villages) do
                table.insert(locs, village)

                local xy = village.x * 1000 + village.y
                table.insert(exposures, fred_data.ops_data.status.villages[xy].exposure)
            end
        end

        for i_l,loc in ipairs(locs) do
            if (not protect_locs) then
                protect_locs = {}
            end
            local protect_loc = { loc.x, loc.y, exposure = exposures[i_l] }
            table.insert(protect_locs, protect_loc)
        end

        assigned_enemies = fred_data.ops_data.assigned_enemies[zone_cfg.zone_id]
    end

    -- Just a safeguard
    if protect_locs and (not protect_locs[1]) then
        wesnoth.message('!!!!!!!!!! This should never happen: protect_locs table is empty !!!!!!!!!!')
        protect_locs = nil
    end

    if protect_locs then
        local min_ld, max_ld = math.huge, - math.huge
        for _,loc in ipairs(protect_locs) do
            local ld = FGM.get_value(fred_data.ops_data.leader_distance_map, loc[1], loc[2], 'distance')
            if (ld < min_ld) then min_ld = ld end
            if (ld > max_ld) then max_ld = ld end
        end
    end

    --DBG.dbms(fred_data.ops_data.status, false, 'fred_data.ops_data.status')
    --DBG.dbms(protect_objectives, false, 'protect_objectives')
    --DBG.dbms(protect_locs, false, 'protect_locs')
    --DBG.dbms(assigned_enemies, false, 'assigned_enemies')

    local between_map
    if protect_locs then
        local locs = {}
        for _,ploc in ipairs(protect_locs) do
            table.insert(locs, ploc)
        end
        local tmp_enemies = {}
        -- TODO: maybe we should always add both types of enemies, with different weights
        if assigned_enemies and next(assigned_enemies) then
            for id,_ in pairs(assigned_enemies) do
                tmp_enemies[id] = move_data.enemies[id]
            end
        elseif protect_objectives.enemies and next(protect_objectives.enemies) then
            for id,_ in pairs(protect_objectives.enemies) do
                tmp_enemies[id] = move_data.enemies[id]
            end
        else
            DBG.dbms(assigned_enemies, false, 'assigned_enemies')
            DBG.dbms(protect_objectives.enemies, false, 'protect_objectives.enemies')
            error(zone_cfg.zone_id .. ': either assigned_enemies or protect_objectives.enemies must contain enemies if protect_locs is given')
        end
        --DBG.dbms(tmp_enemies, false, 'tmp_enemies')

        between_map = FU.get_between_map(locs, tmp_enemies, move_data)

        if DBG.show_debug('hold_between_map') then
            DBG.show_fgumap_with_message(between_map, 'is_between', zone_cfg.zone_id .. ': between map: is_between')
            DBG.show_fgumap_with_message(between_map, 'distance', zone_cfg.zone_id .. ': between map: distance')
            --DBG.show_fgumap_with_message(between_map, 'blurred_distance', zone_cfg.zone_id .. ': between map: blurred distance')
            DBG.show_fgumap_with_message(between_map, 'perp_distance', zone_cfg.zone_id .. ': between map: perp_distance')
            --DBG.show_fgumap_with_message(between_map, 'blurred_perp_distance', zone_cfg.zone_id .. ': between map: blurred blurred_perp_distance')
            --DBG.show_fgumap_with_message(between_map, 'inv_cost', zone_cfg.zone_id .. ': between map: inv_cost')
            --DBG.show_fgumap_with_message(fred_data.ops_data.leader_distance_map, 'distance', 'leader distance')
            --DBG.show_fgumap_with_message(fred_data.ops_data.leader_distance_map, 'enemy_leader_distance', 'enemy_leader_distance')
        end
    end

    local pre_rating_maps = {}
    for id,_ in pairs(holders) do
        --std_print('\n' .. id, zone_cfg.zone_id)
        local min_eleader_distance
        for x,y,_ in FGM.iter(move_data.effective_reach_maps[id]) do
            if FGM.get_value(zone_map, x, y, 'in_zone') then
                --std_print(x,y)
                local can_hit = false
                for enemy_id,enemy_zone_map in pairs(enemy_zone_maps) do
                    if FGM.get_value(enemy_zone_map, x, y, 'adj_hit_chance') then
                        can_hit = true
                        break
                    end
                end

                if (not can_hit) then
                    local eld = FGM.get_value(fred_data.ops_data.advance_distance_maps[zone_cfg.zone_id], x, y, 'forward')

                    if (not min_eleader_distance) or (eld < min_eleader_distance) then
                        min_eleader_distance = eld
                    end
                end
            end
        end
        --std_print('  min_eleader_distance: ' .. min_eleader_distance)

        for x,y,_ in FGM.iter(move_data.effective_reach_maps[id]) do
            --std_print(x,y)

            -- If there is nothing to protect, and we can move farther ahead
            -- unthreatened than this hold position, don't hold here
            local move_here = false
            if FGM.get_value(zone_map, x, y, 'in_zone') then
                move_here = true
                if (not protect_locs) then
                    local threats = FGM.get_value(move_data.enemy_attack_map[1], x, y, 'ids')

                    if (not threats) then
                        local eld = FGM.get_value(fred_data.ops_data.advance_distance_maps[zone_cfg.zone_id], x, y, 'forward')

                        if min_eleader_distance and (eld > min_eleader_distance) then
                            move_here = false
                        end
                    end
                end
            end

            local tmp_enemies = {}
            if move_here then
                for enemy_id,_ in pairs(move_data.enemies) do
                    local enemy_adj_hc = FGM.get_value(enemy_zone_maps[enemy_id], x, y, 'adj_hit_chance')

                    if enemy_adj_hc then
                        --std_print(x,y)
                        --std_print('  ', enemy_id, enemy_adj_hc)

                        local my_hc = 1 - FGUI.get_unit_defense(move_data.unit_copies[id], x, y, move_data.defense_maps)
                        -- This is not directly a contribution to damage, it's just meant as a tiebreaker
                        -- Taking away good terrain from the enemy
                        local enemy_defense = 1 - FGM.get_value(enemy_zone_maps[enemy_id], x, y, 'hit_chance')
                        my_hc = my_hc - enemy_defense / 100

                        local att = fred_data.ops_data.unit_attacks[id][enemy_id]
                        local counter_max_taken = att.damage_counter.base_taken + att.damage_counter.extra_taken
                        local counter_actual_taken = my_hc * att.damage_counter.base_taken + att.damage_counter.extra_taken
                        local damage_taken = factor_counter * counter_actual_taken
                        damage_taken = damage_taken + factor_forward * (my_hc * att.damage_forward.base_taken + att.damage_forward.extra_taken)

                        local counter_max_done = att.damage_counter.base_done + att.damage_counter.extra_done
                        local counter_actual_done = enemy_adj_hc * att.damage_counter.base_done + att.damage_counter.extra_done
                        local damage_done = factor_counter * counter_actual_done
                        damage_done = damage_done + factor_forward * (enemy_adj_hc * att.damage_forward.base_done + att.damage_forward.extra_done)


                        -- Note: this is small (negative) for the strongest enemy
                        -- -> need to find minima the strongest enemies for this hex

                        if move_data.unit_infos[enemy_id].canrecruit then
                            damage_done = damage_done / leader_derating
                            damage_taken = damage_taken * leader_derating
                        end

                        local counter_rating = damage_done - damage_taken * value_ratio
                        table.insert(tmp_enemies, {
                            counter_max_taken = counter_max_taken,
                            counter_max_done = counter_max_done,
                            counter_actual_taken = counter_actual_taken,
                            counter_actual_done = counter_actual_done,
                            damage_taken = damage_taken,
                            damage_done = damage_done,
                            counter_rating = counter_rating,
                            enemy_id = enemy_id,
                            my_regen = att.my_regen,
                            enemy_regen = att.enemy_regen
                        })
                    end
                end

                -- Only keep the 3 strongest enemies (or fewer, if there are not 3)
                table.sort(tmp_enemies, function(a, b) return a.counter_rating < b.counter_rating end)
                local n = math.min(3, #tmp_enemies)
                for i = #tmp_enemies,n+1,-1 do
                    table.remove(tmp_enemies, i)
                end
            end

            if (#tmp_enemies > 0) then
                local damage_taken, damage_done = 0, 0
                local counter_actual_taken, counter_max_taken, counter_actual_damage = 0, 0, 0
                local enemy_value_loss = 0
                local cum_weight, n_enemies = 0, 0
                for _,enemy in pairs(tmp_enemies) do
                    local enemy_weight = enemy_weights[id][enemy.enemy_id].weight
                    --std_print('    ' .. id .. ' <-> ' .. enemy.enemy_id, enemy_weight, x .. ',' .. y, enemy.damage_taken, enemy.damage_done, enemy.counter_actual_taken, enemy.counter_actual_done, enemy.counter_max_taken)
                    cum_weight = cum_weight + enemy_weight
                    n_enemies = n_enemies + 1

                    damage_taken = damage_taken + enemy_weight * enemy.damage_taken

                    local frac_done = enemy.damage_done - enemy.enemy_regen
                    frac_done = frac_done / move_data.unit_infos[enemy.enemy_id].hitpoints
                    frac_done = FU.weight_s(frac_done, 0.5)
                    damage_done = damage_done + enemy_weight * frac_done * move_data.unit_infos[enemy.enemy_id].hitpoints

                    counter_actual_taken = counter_actual_taken + enemy.counter_actual_taken
                    counter_actual_damage = counter_actual_damage + enemy.counter_actual_taken - enemy.counter_actual_done
                    counter_max_taken = counter_max_taken + enemy.counter_max_taken

                    -- Enemy value loss is calculated per enemy whereas for the own unit, it
                    -- needs to be done on the sum (because of the non-linear weighting)
                    enemy_value_loss = enemy_value_loss
                        + FU.approx_value_loss(move_data.unit_infos[enemy.enemy_id], enemy.counter_actual_done, enemy.counter_max_done)

                    --std_print('  ', damage_taken, damage_done, cum_weight)
                end

                damage_taken = damage_taken / cum_weight * n_enemies
                damage_done = damage_done / cum_weight * n_enemies
                --std_print('  cum: ', damage_taken, damage_done, cum_weight)

                local my_value_loss, approx_ctd, unit_value = FU.approx_value_loss(move_data.unit_infos[id], counter_actual_taken, counter_max_taken)

                -- Yes, we are dividing the enemy value loss by our unit's value
                local value_loss = (my_value_loss - enemy_value_loss) / unit_value

                -- Healing bonus for villages
                local village_bonus = 0
                if FGM.get_value(move_data.village_map, x, y, 'owner') then
                    if move_data.unit_infos[id].abilities.regenerate then
                        -- Still give a bit of a bonus, to prefer villages if no other unit can get there
                        village_bonus = 2
                    else
                        village_bonus = 8
                    end
                end

                damage_taken = damage_taken - village_bonus - tmp_enemies[1].my_regen
                local frac_taken = damage_taken / move_data.unit_infos[id].hitpoints
                if (frac_taken) <= 1 then
                    frac_taken = FU.weight_s(frac_taken, 0.5)
                else
                    -- If this damage is higher than the unit's hitpoints, it needs
                    -- to be emphasized, not dampened. Note that this is not done
                    -- for the enemy, as enemy units for which this applies are
                    -- unlikely to attack.
                    frac_taken = frac_taken^2
                end
                damage_taken = frac_taken * move_data.unit_infos[id].hitpoints

                local av_outcome = damage_done - damage_taken * value_ratio
                --std_print(x .. ',' .. y, damage_taken, damage_done, village_bonus, av_outcome, value_ratio)

                if (not pre_rating_maps[id]) then
                    pre_rating_maps[id] = {}
                end
                FGM.set_value(pre_rating_maps[id], x, y, 'av_outcome', av_outcome)
                pre_rating_maps[id][x][y].counter_actual_taken = counter_actual_taken
                pre_rating_maps[id][x][y].counter_actual_damage = counter_actual_damage
                pre_rating_maps[id][x][y].counter_max_taken = counter_max_taken
                pre_rating_maps[id][x][y].my_value_loss = my_value_loss
                pre_rating_maps[id][x][y].enemy_value_loss = enemy_value_loss
                pre_rating_maps[id][x][y].value_loss = value_loss
                pre_rating_maps[id][x][y].approx_ctd = approx_ctd
                pre_rating_maps[id][x][y].x = x
                pre_rating_maps[id][x][y].y = y
                pre_rating_maps[id][x][y].id = id
            end
        end
    end

    if DBG.show_debug('hold_prerating_maps') then
        for id,pre_rating_map in pairs(pre_rating_maps) do
            DBG.show_fgumap_with_message(pre_rating_map, 'av_outcome', 'Average outcome', move_data.unit_copies[id])
            --DBG.show_fgumap_with_message(pre_rating_map, 'counter_actual_taken', 'Actual damage (taken) from counter attack', move_data.unit_copies[id])
            --DBG.show_fgumap_with_message(pre_rating_map, 'counter_actual_damage', 'Actual damage (taken - done) from counter attack', move_data.unit_copies[id])
            --DBG.show_fgumap_with_message(pre_rating_map, 'counter_max_taken', 'Max damage from counter attack', move_data.unit_copies[id])
            --DBG.show_fgumap_with_message(pre_rating_map, 'approx_ctd', 'Approximate chance to die', move_data.unit_copies[id])
            --DBG.show_fgumap_with_message(pre_rating_map, 'my_value_loss', 'My value loss', move_data.unit_copies[id])
            --DBG.show_fgumap_with_message(pre_rating_map, 'enemy_value_loss', 'Enemy value loss', move_data.unit_copies[id])
            DBG.show_fgumap_with_message(pre_rating_map, 'value_loss', 'Value loss', move_data.unit_copies[id])
            --DBG.show_fgumap_with_message(pre_rating_map, 'influence', 'Influence', move_data.unit_copies[id])
        end
    end


    local hold_here_maps = {}
    for id,pre_rating_map in pairs(pre_rating_maps) do
        --std_print('----- ' .. id .. ' -----')
        hold_here_maps[id] = {}

        local hold_here_map = {}
        for x,y,data in FGM.iter(pre_rating_map) do
            FGM.set_value(hold_here_map, x, y, 'av_outcome', data.av_outcome)
        end

        local adj_hex_map = {}
        for x,y,data in FGM.iter(hold_here_map) do
            for xa,ya in H.adjacent_tiles(x,y) do
                if (not FGM.get_value(hold_here_map, xa, ya, 'av_outcome'))
                    and FGM.get_value(pre_rating_map, xa, ya, 'av_outcome')
                then
                    --std_print('adjacent :' .. x .. ',' .. y, xa .. ',' .. ya)
                    FGM.set_value(adj_hex_map, xa, ya, 'av_outcome', data.av_outcome)
                end
            end
        end
        for x,y,data in FGM.iter(adj_hex_map) do
            FGM.set_value(hold_here_map, x, y, 'av_outcome', data.av_outcome)
        end

        local fraction_hp_missing = (move_data.unit_infos[id].max_hitpoints - move_data.unit_infos[id].hitpoints) / move_data.unit_infos[id].max_hitpoints
        local hp_rating = FU.weight_s(fraction_hp_missing, 0.5)
        local hp_damage_factor = 1 - hp_rating

        local acceptable_max_damage = acceptable_max_damage_ratio * move_data.unit_infos[id].hitpoints * hp_damage_factor
        local acceptable_actual_damage = acceptable_actual_damage_ratio * move_data.unit_infos[id].hitpoints * hp_damage_factor

        for x,y,data in FGM.iter(hold_here_map) do
            -- TODO: comment this out for now, but might need a condition like that again later
            --if (data.av_outcome >= 0) then
                local my_count = FGM.get_value(holders_influence, x, y, 'my_count')
                local enemy_count = FGM.get_value(holders_influence, x, y, 'enemy_count')

                -- TODO: comment this out for now, but might need a condition like that again later
                --if (my_count >= 3) then
                --    FGM.set_value(hold_here_maps[id], x, y, 'hold_here', true)
                --else
                    local value_loss = FGM.get_value(pre_rating_map, x, y, 'value_loss')
                    --std_print(string.format('  %d,%d: %5.3f  %5.3f', x, y, value_loss, rel_push_factor))

                    local approx_ctd = FGM.get_value(pre_rating_map, x, y, 'approx_ctd')
                    local is_acceptable_ctd = (approx_ctd <= acceptable_ctd)
                    --std_print(string.format('  %d,%d:  CtD   %5.3f  %6s   (%5.3f)', x, y, approx_ctd, tostring(is_acceptable_ctd), acceptable_ctd))

                    local max_damage = FGM.get_value(pre_rating_map, x, y, 'counter_max_taken')
                    local is_acceptable_max_damage = (max_damage <= acceptable_max_damage)
                    --std_print(string.format('  %d,%d:  MaxD  %5.3f  %6s   (%5.3f)', x, y, max_damage, tostring(is_acceptable_max_damage),  acceptable_max_damage))

                    -- counter_actual_damage does not include regeneration
                    -- Note that it is not included for the enemies either, but this is good enough for now.
                    -- This is the situation at the beginning of Fred's next turn, before enemies regenerate.
                    local actual_damage = FGM.get_value(pre_rating_map, x, y, 'counter_actual_damage')
                    if move_data.unit_infos[id].abilities.regenerate then
                        actual_damage = actual_damage - 8
                    end
                    local is_acceptable_actual_damage = (actual_damage <= acceptable_actual_damage)
                    --std_print(string.format('  %d,%d:  ActD  %5.3f  %6s   (%5.3f)', x, y, actual_damage, tostring(is_acceptable_actual_damage),  acceptable_actual_damage))

                    -- The overall push forward must be worth it
                    -- AND it should not be too far ahead of the front
                    -- TODO: currently these are done individually; not sure if
                    --   these two conditions should be combined (multiplied)
                    if is_acceptable_ctd and is_acceptable_max_damage and is_acceptable_actual_damage then
                        FGM.set_value(hold_here_maps[id], x, y, 'hold_here', true)

                        local ld = FGM.get_value(fred_data.ops_data.leader_distance_map, x, y, 'distance')
                        if (ld > front_ld + 1) then
                            local advance_factor = 1 / (ld - front_ld)

                            advance_factor = advance_factor
                           --FGM.set_value(hold_here_maps[id], x, y, 'hold_here', value_loss)
                           --std_print(x, y, ld, front_ld, f)

                            if (value_loss < - advance_factor) then
                                FGM.set_value(hold_here_maps[id], x, y, 'hold_here', false)
                            end
                        end
                    end
                --end
            --end
        end
    end

    local protect_here_maps = {}
    if protect_locs then
        for id,pre_rating_map in pairs(pre_rating_maps) do
            protect_here_maps[id] = {}
            for x,y,data in FGM.iter(pre_rating_map) do
                -- TODO: do we even need protect_here_maps any more? Just use between_map.is_between directly?
                if FGM.get_value(between_map, x, y, 'is_between') then
                    FGM.set_value(protect_here_maps[id], x, y, 'protect_here', true)
                end
            end
        end
    end

    if (not next(hold_here_maps)) and (not next(protect_here_maps)) then return end

    if DBG.show_debug('hold_here_map') then
        for id,hold_here_map in pairs(hold_here_maps) do
            DBG.show_fgumap_with_message(hold_here_map, 'hold_here', 'hold_here', move_data.unit_copies[id])
        end
        for id,protect_here_map in pairs(protect_here_maps) do
            DBG.show_fgumap_with_message(protect_here_map, 'protect_here', 'protect_here', move_data.unit_copies[id])
        end
    end

    local goal = fred_data.ops_data.hold_goals[zone_cfg.zone_id]
    --DBG.dbms(goal, false, 'goal')
    local ADmap = fred_data.ops_data.advance_distance_maps[zone_cfg.zone_id]
    local goal_forward = FGM.get_value(ADmap, goal[1], goal[2], 'forward')
    local goal_perp = FGM.get_value(ADmap, goal[1], goal[2], 'perp')
    --std_print(zone_cfg.zone_id .. ' hold_goal: ' .. (goal[1] or -1) .. ',' .. (goal[2] or -1), goal_forward, goal_perp)

    local hold_rating_maps = {}
    for id,hold_here_map in pairs(hold_here_maps) do
        local max_moves = move_data.unit_infos[id].max_moves
        --std_print('\n' .. id, zone_cfg.zone_id)
        local max_vuln
        for x,y,hold_here_data in FGM.iter(hold_here_map) do
            if hold_here_data.hold_here then
                local vuln = FGM.get_value(move_data.influence_maps, x, y, 'vulnerability') or 0

                if (not max_vuln) or (vuln > max_vuln) then
                    max_vuln = vuln
                end

                if (not hold_rating_maps[id]) then
                    hold_rating_maps[id] = {}
                end
                FGM.set_value(hold_rating_maps[id], x, y, 'vuln', vuln)
            end
        end

        if hold_rating_maps[id] then
            for x,y,hold_rating_data in FGM.iter(hold_rating_maps[id]) do
                local base_rating = FGM.get_value(pre_rating_maps[id], x, y, 'av_outcome')

                base_rating = base_rating / move_data.unit_infos[id].max_hitpoints
                base_rating = (base_rating + 1) / 2
                base_rating = FU.weight_s(base_rating, 0.75)

                local vuln_rating = base_rating + hold_rating_data.vuln / max_vuln * vuln_rating_weight

                local forward = FGM.get_value(ADmap, x, y, 'forward')
                local perp = FGM.get_value(ADmap, x, y, 'perp')
                local df = math.abs(forward - goal_forward) / max_moves
                local dp = math.abs(perp) / max_moves
                local cost = df ^ 1.5 + dp ^ 2
                cost = cost * max_moves

                vuln_rating = vuln_rating - forward_rating_weight * cost

                hold_rating_data.base_rating = base_rating
                hold_rating_data.vuln_rating = vuln_rating
                hold_rating_data.x = x
                hold_rating_data.y = y
                hold_rating_data.id = id
            end
        end
    end
    --DBG.dbms(hold_rating_maps, false, 'hold_rating_maps')

    -- If protecting is needed, do not do a no-protect hold with fewer
    -- than 3 units, unless that's all the holders available
    if protect_locs then
        local n_units,n_holders = 0, 0
        for _,_ in pairs(hold_rating_maps) do n_units = n_units + 1 end
        for _,_ in pairs(holders) do n_holders = n_holders + 1 end
        --std_print(n_units, n_holders)

        if (n_units < 3) and (n_units < n_holders) then
            hold_rating_maps = {}
        end
    end

    -- Add bonus for other strong hexes aligned *across* the direction
    -- of advancement of the enemies
    --FHU.convolve_rating_maps(hold_rating_maps, 'vuln_rating', between_map, fred_data.ops_data)

    if DBG.show_debug('hold_rating_maps') then
        for id,hold_rating_map in pairs(hold_rating_maps) do
            DBG.show_fgumap_with_message(hold_rating_map, 'base_rating', 'base_rating', move_data.unit_copies[id])
            DBG.show_fgumap_with_message(hold_rating_map, 'vuln_rating', 'vuln_rating_org', move_data.unit_copies[id])
            --DBG.show_fgumap_with_message(hold_rating_map, 'conv', 'conv', move_data.unit_copies[id])
            --DBG.show_fgumap_with_message(hold_rating_map, 'vuln_rating', 'vuln_rating', move_data.unit_copies[id])
        end
    end


    local max_inv_cost
    if between_map then
        for _,protect_loc in ipairs(protect_locs) do
            local inv_cost = FGM.get_value(between_map, protect_loc[1], protect_loc[2], 'inv_cost') or 0
            if (not max_inv_cost) or (inv_cost > max_inv_cost) then
                max_inv_cost = inv_cost
            end
        end
    end

    local protect_rating_maps = {}
    for id,protect_here_map in pairs(protect_here_maps) do
        local max_vuln
        for x,y,protect_here_data in FGM.iter(protect_here_map) do
            if protect_here_data.protect_here then
                local vuln = FGM.get_value(holders_influence, x, y, 'vulnerability')

                if (not max_vuln) or (vuln > max_vuln) then
                    max_vuln = vuln
                end

                if (not protect_rating_maps[id]) then
                    protect_rating_maps[id] = {}
                end
                FGM.set_value(protect_rating_maps[id], x, y, 'vuln', vuln)
            end
        end

        if protect_rating_maps[id] then
            for x,y,protect_rating_data in FGM.iter(protect_rating_maps[id]) do
                local protect_base_rating, cum_weight = 0, 0

                local my_defense = FGUI.get_unit_defense(move_data.unit_copies[id], x, y, move_data.defense_maps)
                local scaled_my_defense = FU.weight_s(my_defense, 0.67)

                for enemy_id,enemy_zone_map in pairs(enemy_zone_maps) do
                    local enemy_adj_hc = FGM.get_value(enemy_zone_map, x, y, 'adj_hit_chance')
                    if enemy_adj_hc then
                        local enemy_defense = 1 - FGM.get_value(enemy_zone_map, x, y, 'hit_chance')
                        local scaled_enemy_defense = FU.weight_s(enemy_defense, 0.67)
                        local scaled_enemy_adj_hc = FU.weight_s(enemy_adj_hc, 0.67)

                        local enemy_weight = enemy_weights[id][enemy_id].weight

                        local rating = scaled_enemy_adj_hc
                        -- TODO: shift more toward weak enemy terrain at small value_ratio?
                        rating = rating + (scaled_enemy_adj_hc + scaled_my_defense + scaled_enemy_defense / 100) * value_ratio
                        protect_base_rating = protect_base_rating + rating * enemy_weight

                        cum_weight = cum_weight + enemy_weight
                    end
                end

                local protect_base_rating = protect_base_rating / cum_weight
                --std_print('  ' .. x .. ',' .. y .. ': ' .. protect_base_rating, cum_weight)

                if FGM.get_value(move_data.village_map, x, y, 'owner') then
                    -- Prefer strongest unit on village (for protection)
                    -- Potential TODO: we might want this conditional on the threat to the village
                    protect_base_rating = protect_base_rating + 0.1 * move_data.unit_infos[id].hitpoints / 25 * value_ratio

                    -- For non-regenerating units, we also give a heal bonus
                    if (not move_data.unit_infos[id].abilities.regenerate) then
                        protect_base_rating = protect_base_rating + 0.25 * 8 / 25 * value_ratio
                    end
                end

                -- TODO: check if this is the right metric when between map does not exist
                local inv_cost = 0
                if between_map then
                    inv_cost = FGM.get_value(between_map, x, y, 'inv_cost') or 0
                end
                local d_dist = inv_cost - (max_inv_cost or 0)
                local protect_rating = protect_base_rating
                if (protect_forward_rating_weight > 0) then
                    local vuln = protect_rating_data.vuln
                    local terrain_mult = FGUI.get_unit_defense(move_data.unit_copies[id], x, y, move_data.defense_maps)
                    protect_rating = protect_rating + vuln / max_vuln * protect_forward_rating_weight * terrain_mult
                else
                    protect_rating = protect_rating + (d_dist - 2) / 10 * protect_forward_rating_weight
                end

                -- TODO: this might be too simplistic
                if protect_objectives.protect_leader then
                    local mult = 0
                    local power_ratio = fred_data.ops_data.behavior.orders.base_power_ratio
                    if (power_ratio < 1) then
                        mult = (1 / power_ratio - 1)
                    end

                    protect_rating = protect_rating * (1 - mult * (d_dist / 100))
                end

                protect_rating_data.protect_base_rating = protect_base_rating
                protect_rating_data.protect_rating = protect_rating
                protect_rating_data.x = x
                protect_rating_data.y = y
                protect_rating_data.id = id
            end
        end
    end

    -- Add bonus for other strong hexes aligned *across* the direction
    -- of advancement of the enemies
    --FHU.convolve_rating_maps(protect_rating_maps, 'protect_rating', between_map, fred_data.ops_data)

    if DBG.show_debug('hold_protect_rating_maps') then
        for id,protect_rating_map in pairs(protect_rating_maps) do
            DBG.show_fgumap_with_message(protect_rating_map, 'protect_base_rating', 'protect_base_rating', move_data.unit_copies[id])
            DBG.show_fgumap_with_message(protect_rating_map, 'protect_rating', 'protect_rating_org', move_data.unit_copies[id])
            --DBG.show_fgumap_with_message(protect_rating_map, 'vuln', 'vuln', move_data.unit_copies[id])
            --DBG.show_fgumap_with_message(protect_rating_map, 'conv', 'conv', move_data.unit_copies[id])
            --DBG.show_fgumap_with_message(protect_rating_map, 'protect_rating', 'protect_rating', move_data.unit_copies[id])
        end
    end

    if (not next(hold_rating_maps)) and (not next(protect_rating_maps)) then
        return
    end


    -- Map of adjacent villages that can be reached by the enemy
    local adjacent_village_map = {}
    for x,y,_ in FGM.iter(move_data.village_map) do
        if FGM.get_value(zone_map, x, y, 'in_zone') then

            local can_reach = false
            for enemy_id,enemy_zone_map in pairs(enemy_zone_maps) do
                if FGM.get_value(enemy_zone_map, x, y, 'moves_left') then
                    can_reach = true
                    break
                end
            end

            if can_reach then
                for xa,ya in H.adjacent_tiles(x,y) do
                    -- Eventual TODO: this currently only works for one adjacent village
                    -- which is fine on the Freelands map, but might not be on others
                    FGM.set_value(adjacent_village_map, xa, ya, 'village_xy', 1000 * x + y)
                end
            end
        end
    end
    --DBG.dbms(adjacent_village_map, false, 'adjacent_village_map')

    if false then
        DBG.show_fgumap_with_message(adjacent_village_map, 'village_xy', 'Adjacent vulnerable villages')
    end


    local cfg_combos = {
        max_units = max_units,
        max_hexes = max_hexes
    }
    local cfg_best_combo_hold = { zone_id = zone_cfg.zone_id, value_ratio = value_ratio }
    local cfg_best_combo_protect = {
        zone_id = zone_cfg.zone_id,
        protect_objectives = protect_objectives, -- TODO: can we not just get this from ops_data?
        find_best_protect_only = zone_cfg.find_best_protect_only,
        value_ratio = value_ratio
    }

    local combo_table = { hold = {}, all_hold = {}, protect = {}, all_protect = {} }

    -- TODO: also don't need some of the previous steps if find_best_protect_only == true
    if (not zone_cfg.find_best_protect_only) and (next(hold_rating_maps)) then
        --std_print('--> checking hold combos ' .. zone_cfg.zone_id)
        local hold_dst_src, hold_ratings = FHU.unit_rating_maps_to_dstsrc(hold_rating_maps, 'vuln_rating', move_data, cfg_combos)
        local hold_combos = FU.get_unit_hex_combos(hold_dst_src)
        --DBG.dbms(hold_combos, false, 'hold_combos')
        --std_print('#hold_combos ' .. zone_cfg.zone_id, #hold_combos)

        local best_hold_combo, all_best_hold_combo, combo_strs = FHU.find_best_combo(hold_combos, hold_ratings, 'vuln_rating', adjacent_village_map, between_map, fred_data, cfg_best_combo_hold)
        --DBG.dbms(combo_strs, false, 'combo_strs')

        -- There's some duplication in this table, that's just to make it easier later.
        combo_table.hold = {
            combo = best_hold_combo,
            protected_str = combo_strs.protected_str,
            protect_obj_str = combo_strs.protect_obj_str
        }
        combo_table.all_hold = {
            combo = all_best_hold_combo,
            protected_str = combo_strs.all_protected_str,
            protect_obj_str = combo_strs.protect_obj_str
        }

    end

    if protect_locs and next(protect_rating_maps) then
        --std_print('--> checking protect combos ' .. zone_cfg.zone_id)
        local protect_dst_src, protect_ratings = FHU.unit_rating_maps_to_dstsrc(protect_rating_maps, 'protect_rating', move_data, cfg_combos)
        local protect_combos = FU.get_unit_hex_combos(protect_dst_src)
        --DBG.dbms(protect_combos, false, 'protect_combos')
        --std_print('#protect_combos ' .. zone_cfg.zone_id, #protect_combos)

        local best_protect_combo, all_best_protect_combo, protect_combo_strs = FHU.find_best_combo(protect_combos, protect_ratings, 'protect_rating', adjacent_village_map, between_map, fred_data, cfg_best_combo_protect)
        --DBG.dbms(combo_strs, false, 'combo_strs')

        -- If no combo that protects the location was found, use the best of the others
        -- TODO: check whether it is better to use a normal hold in this case; may depend on
        --   how desperately we want to protect
--        if (not best_protect_combo) then
--            best_protect_combo = all_best_protect_combo
--        end

        -- There's some duplication in this table, that's just to make it easier later.
        combo_table.protect = {
            combo = best_protect_combo,
            protected_str = protect_combo_strs.protected_str,
            protect_obj_str = protect_combo_strs.protect_obj_str
        }
        combo_table.all_protect = {
            combo = all_best_protect_combo,
            protected_str = protect_combo_strs.all_protected_str,
            protect_obj_str = protect_combo_strs.protect_obj_str
        }
    end
    --DBG.dbms(combo_table, false, 'combo_table')

    if (not combo_table.hold.combo) and (not combo_table.all_hold.combo)
        and (not combo_table.protect.combo) and (not combo_table.all_protect.combo)
    then
        return
    end


    local action_str = zone_cfg.action_str
    local best_combo_type
    if (not combo_table.hold.combo) and (not combo_table.protect.combo) and (not combo_table.all_protect.combo) then
        -- Only as a last resort do we use all_best_hold_combo
        best_combo_type = 'all_hold'
    elseif (not combo_table.hold.combo) then
        if combo_table.protect.combo then
            best_combo_type = 'protect'
        else
            best_combo_type = 'all_protect'
        end
    elseif (not combo_table.protect.combo) then
        best_combo_type = 'hold'
    else
        -- TODO: if there is a best_protect_combo, should we always use it over best_hold_combo?
        --   This would also mean that we do not need to evaluate best_hold_combo if best_protect_combo is found
        local hold_distance, count = 0, 0
        for src,dst in pairs(combo_table.hold.combo) do
            local x, y =  math.floor(dst / 1000), dst % 1000
            local ld = FGM.get_value(fred_data.ops_data.leader_distance_map, x, y, 'distance')
            hold_distance = hold_distance + ld
            count = count + 1
        end
        hold_distance = hold_distance / count

        local protect_distance, count = 0, 0
        for src,dst in pairs(combo_table.protect.combo) do
            local x, y =  math.floor(dst / 1000), dst % 1000
            local ld = FGM.get_value(fred_data.ops_data.leader_distance_map, x, y, 'distance')
            protect_distance = protect_distance + ld
            count = count + 1
        end
        protect_distance = protect_distance / count

        --std_print(hold_distance, protect_distance)

        -- Potential TODO: this criterion might be too simple
        if (hold_distance > protect_distance + 1) then
            best_combo_type = 'hold'
        else
            best_combo_type = 'protect'
        end
    end
    --std_print('best_combo_type: ' .. best_combo_type)

    if DBG.show_debug('hold_best_combo') then
        local function show_hold_units(combo_type, combo_str, no_protect_locs_str)
            if combo_table[combo_type].combo then
                local dst_x, dst_y
                for src,dst in pairs(combo_table[combo_type].combo) do
                    src_x, src_y =  math.floor(src / 1000), src % 1000
                    dst_x, dst_y =  math.floor(dst / 1000), dst % 1000
                    local id = move_data.my_unit_map[src_x][src_y].id
                    wesnoth.wml_actions.label { x = dst_x, y = dst_y, text = id }
                end
                wesnoth.scroll_to_tile(dst_x, dst_y)
                wesnoth.wml_actions.message {
                    speaker = 'narrator',
                    caption = combo_str .. ' [' .. zone_cfg.zone_id .. ']',
                    message = 'Protect objectives: ' .. combo_table[combo_type].protect_obj_str .. '\nAction: ' .. action_str .. '\n    ' .. (combo_table[combo_type].protected_str or '')
                }
                for src,dst in pairs(combo_table[combo_type].combo) do
                    dst_x, dst_y =  math.floor(dst / 1000), dst % 1000
                    wesnoth.wml_actions.label { x = dst_x, y = dst_y, text = "" }
                end
            else
                wesnoth.wml_actions.message {
                    speaker = 'narrator',
                    caption = combo_str .. ' [' .. zone_cfg.zone_id .. ']',
                    message = 'Protect objectives: ' .. (combo_table[combo_type].protect_obj_str or no_protect_locs_str or 'None') .. '\nAction: ' .. (no_protect_locs_str or 'None found')
                }
            end
        end

        for _,unit in ipairs(fred_data.ops_data.place_holders) do
            wesnoth.wml_actions.label { x = unit[1], y = unit[2], text = 'recruit\n' .. unit.type, color = '160,160,160' }
        end
        wesnoth.wml_actions.label { x = leader_goal[1], y = leader_goal[2], text = 'leader goal', color = '200,0,0' }

        local no_protect_locs_str
        if (not protect_locs) then no_protect_locs_str = 'no protect locs' end
        show_hold_units('protect', 'Best protect combo', no_protect_locs_str)
        show_hold_units('all_protect', 'All best protect combo', no_protect_locs_str)
        show_hold_units('hold', 'Best hold combo')
        show_hold_units('all_hold', 'All best hold combo')
        show_hold_units(best_combo_type, 'Overall best combo')

        wesnoth.wml_actions.label { x = leader_goal[1], y = leader_goal[2], text = "" }
        for _,unit in ipairs(fred_data.ops_data.place_holders) do
            wesnoth.wml_actions.label { x = unit[1], y = unit[2], text = "" }
        end
    end

    local action = {
        action_str = action_str  .. '\n    ' .. combo_table[best_combo_type].protected_str,
        units = {},
        dsts = {}
    }
    for src,dst in pairs(combo_table[best_combo_type].combo) do
        src_x, src_y =  math.floor(src / 1000), src % 1000
        dst_x, dst_y =  math.floor(dst / 1000), dst % 1000
        local id = move_data.my_unit_map[src_x][src_y].id

        local tmp_unit = move_data.my_units[id]
        tmp_unit.id = id
        table.insert(action.units, tmp_unit)
        table.insert(action.dsts, { dst_x, dst_y })
    end
    --DBG.dbms(action, false, 'action')

    return action
end


----- Advance: -----
local function get_advance_action(zone_cfg, fred_data)
    -- Advancing is now only moving onto unthreatened hexes; everything
    -- else should be covered by holding, village grabbing, protecting, etc.

    DBG.print_debug_time('eval', fred_data.turn_start_time, '  --> advance evaluation: ' .. zone_cfg.zone_id)

    --DBG.dbms(zone_cfg, false, 'zone_cfg')
    local raw_cfg = FMC.get_raw_cfgs(zone_cfg.zone_id)
    --DBG.dbms(raw_cfg, false, 'raw_cfg')

    local move_data = fred_data.move_data
    local move_cache = fred_data.move_cache


    -- Advancers are those specified in zone_units, or all units except the leader otherwise
    local advancers = {}
    if zone_cfg.zone_units then
        advancers = zone_cfg.zone_units
    else
        for id,_ in pairs(move_data.my_units_MP) do
            if (not move_data.unit_infos[id].canrecruit) then
                advancers[id] = { move_data.my_units[id][1], move_data.my_units[id][2] }
            end
        end
    end
    if (not next(advancers)) then return end

    -- Maps of hexes to be avoided for each unit
    -- Currently this is only the final leader position
    local avoid_maps = {}
    local leader = move_data.leaders[wesnoth.current.side]
    local leader_goal = fred_data.ops_data.objectives.leader.final
    for id,_ in pairs(advancers) do
        avoid_maps[id] = {}
        if (id ~= leader.id) then
            FGM.set_value(avoid_maps[id], leader_goal[1], leader_goal[2], 'avoid', true)
        end
    end

    local value_ratio = zone_cfg.value_ratio or fred_data.ops_data.behavior.orders.value_ratio
    --std_print('value_ratio: ' .. zone_cfg.zone_id, value_ratio)
    -- Push factors are only set for zones with assigned enemies.
    local push_factor = fred_data.ops_data.behavior.zone_push_factors[zone_cfg.zone_id] or 1
    --std_print('push_factor: ' .. zone_cfg.zone_id, push_factor)

    --[[
    local behind_enemy_map = FU.behind_enemy_map(fred_data)
    if DBG.show_debug('advance_behind_enemy_map') then
        DBG.show_fgumap_with_message(behind_enemy_map, 'enemy_power', 'behind_enemy_map ')
    end

    if DBG.show_debug('advance_support_map') then
        DBG.show_fgumap_with_message(move_data.support_maps.total, 'support', 'Total support')
    end
    if DBG.show_debug('advance_unit_support_maps') then
        for id,support_unit_map in pairs(move_data.support_maps.units) do
            DBG.show_fgumap_with_message(support_unit_map, 'support', 'Unit support', move_data.unit_copies[id])
        end
    end

    -- Find hexes behind enemy lines with insufficient support for each unit
    -- It's not necessary to do this part separately, it's done this way for diagnostics purposes
    local insufficient_support_maps = {}
    for id,unit_loc in pairs(advancers) do
        insufficient_support_maps[id] = {}
        local current_power = FU.unit_current_power(move_data.unit_infos[id])

        for x,y,_ in FGM.iter(behind_enemy_map) do
            -- Note: support_maps decay with distance, while behind_enemy_map contain
            -- full enemy power. Thus the somewhat complex calculation here.
            local all_support = FGM.get_value(move_data.support_maps.total, x, y, 'support') or 0
            local own_support = FGM.get_value(move_data.support_maps.units[id], x, y, 'support') or 0
            local enemy_power = FGM.get_value(behind_enemy_map, x, y, 'enemy_power') or 0

            local support = all_support - own_support + current_power - enemy_power

            if (support < 0) then
                FGM.set_value(insufficient_support_maps[id], x, y, 'support', support)
            end
        end
    end

    if DBG.show_debug('advance_insufficient_support_maps') then
        for id,insufficient_support_map in pairs(insufficient_support_maps) do
            DBG.show_fgumap_with_message(insufficient_support_map, 'support', 'Insufficient support', move_data.unit_copies[id])
        end
    end
    --]]


    -- If we got here and nobody is holding already, that means a hold was attempted (with the same units
    -- now used for advancing) and either not possible or not deemed worth it.
    -- Either way, we should be careful with advancing into enemy threats.
    local already_holding = true
    if (not next(fred_data.ops_data.objectives.protect.zones[zone_cfg.zone_id].holders)) then
        already_holding = false
    end
    --std_print(zone_cfg.zone_id .. ': already_holding: ', already_holding)

    local safe_loc = false
    local unit_rating_maps = {}
    local max_rating, best_id, best_hex
    for id,xy in pairs(advancers) do
        local unit_loc = { math.floor(xy / 1000), xy % 1000 }
        -- Don't use ops_slf here, but pre-calculated zone_amps. The zone_map used can be
        -- different from that in the SLF, e.g. for the leader zone or if parts of a zone are
        -- to be avoided (the latter is not implemented yet).
        local is_unit_in_zone = FGM.get_value(fred_data.ops_data.zone_maps[zone_cfg.zone_id], unit_loc[1], unit_loc[2], 'in_zone')
        --std_print('is_unit_in_zone: ' .. id, zone_cfg.zone_id, is_unit_in_zone)

        unit_rating_maps[id] = {}

        local unit_value = FU.unit_value(move_data.unit_infos[id])

        -- Fastest unit first, after that strongest unit first
        -- These are small, mostly just tie breakers
        local max_moves = move_data.unit_infos[id].max_moves
        local rating_moves = move_data.unit_infos[id].moves / 10
        local rating_power = FU.unit_current_power(move_data.unit_infos[id]) / 1000

        -- Injured units are treated much more carefully by the AI.
        -- This part sets up a number of parameters for that.
        local fraction_hp_missing = (move_data.unit_infos[id].max_hitpoints - move_data.unit_infos[id].hitpoints) / move_data.unit_infos[id].max_hitpoints
        local hp_rating = FU.weight_s(fraction_hp_missing, 0.5)
        local hp_forward_factor = 1 - hp_rating
        -- The more injured the unit, the closer to 1 a value_ratio we use
        local unit_value_ratio = value_ratio + (1 - value_ratio) * hp_rating
        --std_print('unit_value_ratio', unit_value_ratio, value_ratio)
        local cfg_attack = { value_ratio = unit_value_ratio }

        local goal = fred_data.ops_data.advance_goals[zone_cfg.zone_id]
        local cost_map = {}
        if is_unit_in_zone then
            -- If the unit is in the zone, use the ops advance_distance_maps
            local ADmap = fred_data.ops_data.advance_distance_maps[zone_cfg.zone_id]
            local goal_forward = FGM.get_value(ADmap, goal[1], goal[2], 'forward')
            local goal_perp = FGM.get_value(ADmap, goal[1], goal[2], 'perp')
            for x,y,_ in FGM.iter(move_data.effective_reach_maps[id]) do
                if (not FGM.get_value(avoid_maps[id], x, y, 'avoid')) then
                    local forward = FGM.get_value(ADmap, x, y, 'forward')
                    local perp = FGM.get_value(ADmap, x, y, 'perp')

                    -- TODO: this is not good, should really expand the map in the first place
                    if (not forward) then
                        forward = wesnoth.map.distance_between(x, y, goal[1], goal[2]) + goal_forward
                        perp = 10
                    end

                    local df = math.abs(forward - goal_forward) / max_moves
                    local dp = math.abs(perp - goal_perp) / max_moves / 2
                    local cost = df ^ 1.5 + dp ^ 2
                    cost = cost * max_moves

                    FGM.set_value(cost_map, x, y, 'cost', cost)
                end
            end
        else
            -- If the unit is not in the zone, head straight toward the goal
            local cm = wesnoth.find_cost_map(
                { x = -1 }, -- SUF not matching any unit
                { { goal[1], goal[2], wesnoth.current.side, fred_data.move_data.unit_infos[id].type } },
                { ignore_units = true }
            )

            for _,cost in pairs(cm) do
                if (cost[3] > -1) then
                   local c = FGM.get_value(cost_map, cost[1], cost[2], 'cost') or 0
                   FGM.set_value(cost_map, cost[1], cost[2], 'cost', c + cost[3])
                end
            end
        end

        if DBG.show_debug('advance_cost_maps') then
            DBG.show_fgumap_with_message(cost_map, 'cost', zone_cfg.zone_id ..': advance cost map', move_data.unit_copies[id])
        end

        for x,y,_ in FGM.iter(move_data.effective_reach_maps[id]) do
            if (not FGM.get_value(avoid_maps[id], x, y, 'avoid')) then
                local rating = rating_moves + rating_power
                dist = FGM.get_value(cost_map, x, y, 'cost')

                -- Counter attack outcome
                local unit_moved = {}
                unit_moved[id] = { x, y }
                local old_locs = { { unit_loc[1], unit_loc[2] } }
                local new_locs = { { x, y } }
                -- TODO: Use FVS here also?
                local counter_outcomes = FAU.calc_counter_attack(
                    unit_moved, old_locs, new_locs, fred_data.ops_data.place_holders, nil, cfg_attack, move_data, move_cache
                )

                if counter_outcomes then
                    --DBG.dbms(counter_outcomes, false, 'counter_outcomes')
                    --std_print('  die_chance', counter_outcomes.def_outcome.hp_chance[0], id .. ': ' .. x .. ',' .. y)

                    -- This is the standard attack rating (roughly) in units of cost (gold)
                    local counter_rating = - counter_outcomes.rating_table.max_weighted_rating

                    if already_holding then
                        rating = rating + counter_rating
                        --std_print(x .. ',' .. y .. ': counter' , counter_rating, unit_value_ratio)
                    else
                        -- If nobody is holding, that means that the hold with these units was
                        -- considered not worth it, which means we should be much more careful
                        -- advancing them as well -> use mostly own damage rating
                        local _, damage_rating, heal_rating = FAU.damage_rating_unit(counter_outcomes.defender_damage)
                        local enemy_rating = 0
                        for _,attacker_damage in ipairs(counter_outcomes.attacker_damages) do
                            local _, er, ehr = FAU.damage_rating_unit(attacker_damage)
                            enemy_rating = enemy_rating + er + ehr
                        end
                        --std_print(x .. ',' .. y .. ': damage: ', counter_outcomes.defender_damage.damage, damage_rating, heal_rating)
                        --std_print('  enemy rating:', enemy_rating)

                        -- Note that damage ratings are negative
                        rating = rating + damage_rating + heal_rating
                        rating = rating - enemy_rating / 10
                    end

                    -- The die chance is already included in the rating, but we
                    -- want it to be even more important here (and very non-linear)
                    -- It's set to be quadratic and take unity value at the desperate attack
                    -- hp_chance[0]=0.85; but then it is the difference between die chances that
                    -- really matters, so we multiply by another factor 2.
                    -- This makes this a huge contribution to the rating.
                    local die_rating = - unit_value_ratio * unit_value * counter_outcomes.def_outcome.hp_chance[0] ^ 2 / 0.85^2 * 2
                    rating = rating + die_rating
                end

                if (not counter_outcomes) or (counter_outcomes.def_outcome.hp_chance[0] < 0.85) then
                    safe_loc = true
                end

                -- Everything is balanced against the value loss rating from the counter attack
                -- For now, let's set being one full move away equal to half the value of the unit,
                -- multiplied by push_factor
                -- Note: unit_value_ratio is already taken care of in both the location of the goal hex
                -- and the counter attack rating.  Is including the push factor overdoing it?

                rating = rating - dist * unit_value / 2 * push_factor * hp_forward_factor

                -- We additionally discourage locations behind enemy lines without sufficient support
                -- TODO: this is a large effect and it introduces a discontinuity, might
                --    need to do this differently
                -- Note: the support value in this table is negative
                -- This rating is bound in the range unit_value * [-1 .. 0].  It takes on value 0 when this
                -- is not a hex behind enemy lines without sufficient support.  It's value is -0.75*unit_value
                -- if missing support is equal to the units HP, and decreases asymptotically to -unit_value from there.
                -- It's supposed to be (mostly) balanced against the damage rating above.
                --[[
                local support = - (FGM.get_value(insufficient_support_maps[id], x, y, 'support') or 0)
                local support_rating = - unit_value * (1 - 0.25 ^ (support / move_data.unit_infos[id].hitpoints))
                rating = rating + support_rating
                --]]

                -- Small preference for villages we don't own (although this
                -- should mostly be covered by the village grabbing action already)
                -- Equal to gold difference between grabbing and not grabbing (not counting support)
                local village_bonus = 0
                local owner = FGM.get_value(move_data.village_map, x, y, 'owner')
                if owner and (owner ~= wesnoth.current.side) then
                    if (owner == 0) then
                        village_bonus = village_bonus + 2
                    else
                        village_bonus = village_bonus + 4
                    end
                end

                -- Somewhat larger preference for villages for injured units
                -- Also add a half-hex bonus for villages in general; no need not to go there
                -- all else being equal
                if owner and (not move_data.unit_infos[id].abilities.regenerate) then
                    village_bonus = unit_value * (1 / hp_forward_factor - 1) -- zero for uninjured unit
                end

                rating = rating + village_bonus * unit_value_ratio

                -- Small bonus for the terrain; this does not really matter for
                -- unthreatened hexes and is already taken into account in the
                -- counter attack calculation for others. Just a tie breaker.
                local my_defense = FGUI.get_unit_defense(move_data.unit_copies[id], x, y, move_data.defense_maps)
                rating = rating + my_defense / 10

                FGM.set_value(unit_rating_maps[id], x, y, 'rating', rating)

                if (not max_rating) or (rating > max_rating) then
                    max_rating = rating
                    best_id = id
                    best_hex = { x, y }
                end
            end
        end
    end
    --std_print('best unit: ' .. best_id, best_hex[1], best_hex[2])

    if DBG.show_debug('advance_unit_rating') then
        for id,unit_rating_map in pairs(unit_rating_maps) do
            DBG.show_fgumap_with_message(unit_rating_map, 'rating', zone_cfg.zone_id ..': advance unit rating (unit value = ' .. FU.unit_value(move_data.unit_infos[id]) .. ')', move_data.unit_copies[id])
        end
    end


    -- If no safe location is found, check for desperate attack
    local best_target, best_weapons
    local action_str = zone_cfg.action_str
    if (not safe_loc) then
        --std_print('----- no safe advance location found -----')

        local cfg_attack_desp = { value_ratio = 0.2 } -- mostly based on damage done to enemy

        local max_attack_rating, best_attacker_id, best_attack_hex
        for id,xy in pairs(advancers) do
            --std_print('checking desperate attacks for ' .. id)

            local attacker = {}
            attacker[id] = move_data.units[id]
            for enemy_id,enemy_loc in pairs(move_data.enemies) do
                if FGM.get_value(move_data.unit_attack_maps[1][id], enemy_loc[1], enemy_loc[2], 'current_power') then
                    --std_print('    potential target:' .. enemy_id)

                    local target = {}
                    target[enemy_id] = enemy_loc
                    local attack_combos = FAU.get_attack_combos(
                        attacker, target, cfg_attack_desp, move_data.effective_reach_maps, false, move_data, move_cache
                    )

                    for _,combo in ipairs(attack_combos) do
                        local combo_outcome = FAU.attack_combo_eval(combo, target, cfg_attack_desp, move_data, move_cache)
                        --std_print(next(combo))
                        --DBG.dbms(combo_outcome.rating_table, false, 'combo_outcome.rating_table')

                        local do_attack = true

                        -- Don't attack if chance of leveling up the enemy is higher than the kill chance
                        if (combo_outcome.def_outcome.levelup_chance > combo_outcome.def_outcome.hp_chance[0]) then
                            do_attack = false
                        end

                        -- If there's no chance to kill the enemy, don't do the attack if it ...
                        if do_attack and (combo_outcome.def_outcome.hp_chance[0] == 0) then
                            local unit_level = move_data.unit_infos[id].level
                            local enemy_dxp = move_data.unit_infos[enemy_id].max_experience - move_data.unit_infos[enemy_id].experience

                            -- .. will get the enemy a certain level-up on the counter
                            if (enemy_dxp <= 2 * unit_level) then
                                do_attack = false
                            end

                            -- .. will give the enemy a level-up with a kill on the counter,
                            -- unless that would be the case even without the attack
                            if do_attack then
                                if (unit_level == 0) then unit_level = 0.5 end  -- L0 units
                                if (enemy_dxp > unit_level * 8) and (enemy_dxp <= unit_level * 9) then
                                    do_attack = false
                                end
                            end
                        end

                        if do_attack and ((not max_attack_rating) or (combo_outcome.rating_table.rating > max_attack_rating)) then
                            max_attack_rating = combo_outcome.rating_table.rating
                            best_attacker_id = id
                            local _, dst = next(combo)
                            best_attack_hex = { math.floor(dst / 1000), dst % 1000 }
                            best_target = {}
                            best_target[enemy_id] = enemy_loc
                            best_weapons = combo_outcome.att_weapons_i
                            action_str = action_str .. ' (desperate attack)'
                        end
                    end
                end
            end
        end
        if best_attacker_id then
            --std_print('best desperate attack: ' .. best_attacker_id, best_attack_hex[1], best_attack_hex[2], next(best_target))
            best_id = best_attacker_id
            best_hex = best_attack_hex
        end
    end


    if best_id then
        DBG.print_debug('advance_output', zone_cfg.zone_id .. ': best advance: ' .. best_id .. ' -> ' .. best_hex[1] .. ',' .. best_hex[2])

        local best_unit = move_data.my_units[best_id]
        best_unit.id = best_id

        local action = {
            units = { best_unit },
            dsts = { best_hex },
            enemy = best_target,
            weapons = best_weapons,
            action_str = action_str
        }
        return action
    end
end


----- Retreat: -----
local function get_retreat_action(zone_cfg, fred_data)
    DBG.print_debug_time('eval', fred_data.turn_start_time, '  --> retreat evaluation: ' .. zone_cfg.zone_id)

    -- Combines moving leader to village or keep, and retreating other units.
    -- These are put in here together because we might want to weigh which one
    -- gets done first in the end.

    local move_data = fred_data.move_data
    local leader_objectives = fred_data.ops_data.objectives.leader
    local leader = move_data.leaders[wesnoth.current.side]
    --DBG.dbms(leader_objectives, false, 'leader_objectives')

    if (move_data.unit_infos[leader.id].moves > 0) then
        if leader_objectives.village then
            local action = {
                units = { leader },
                dsts = { { leader_objectives.village[1], leader_objectives.village[2] } },
                action_str = zone_cfg.action_str .. ' (move leader to village)'
            }
            --DBG.dbms(action, false, 'action')

            return action
        end

        -- This is only for moving leader back toward keep. Moving to a keep for
        -- recruiting is done as part of the recruitment action
        if leader_objectives.keep then
            local action = {
                units = { leader },
                dsts = { { leader_objectives.keep[1], leader_objectives.keep[2] } },
                action_str = zone_cfg.action_str .. ' (move leader to keep)'
            }
            --DBG.dbms(action, false, 'action')

            leader_objectives.keep = nil

            return action
        end

        if leader_objectives.other then
            local action = {
                units = { leader },
                dsts = { { leader_objectives.other[1], leader_objectives.other[2] } },
                action_str = zone_cfg.action_str .. ' (move leader toward keep or safety)'
            }
            --DBG.dbms(action, false, 'action')

            leader_objectives.other = nil

            return action
        end
    end

    --DBG.dbms(fred_data.ops_data.reserved_actions)
    local retreaters = {}
    for _,action in pairs(fred_data.ops_data.reserved_actions) do
        if (action.action_id == 'ret') then
            retreaters[action.id] = move_data.units[action.id]
        end
    end
    --DBG.dbms(retreaters, false, 'retreaters')

    if next(retreaters) then
        local retreat_utilities = FBU.retreat_utilities(move_data, fred_data.ops_data.behavior.orders.value_ratio)
        local retreat_combo = FRU.find_best_retreat(retreaters, retreat_utilities, fred_data)
        --DBG.dbms(retreat_combo, false, 'retreat_combo')

        if retreat_combo then
            local action = {
                units = {},
                dsts = {},
                action_str = zone_cfg.action_str
            }

            for src,dst in pairs(retreat_combo) do
                local src_x, src_y = math.floor(src / 1000), src % 1000
                local dst_x, dst_y = math.floor(dst / 1000), dst % 1000
                local unit = { src_x, src_y, id = move_data.my_unit_map[src_x][src_y].id }
                table.insert(action.units, unit)
                table.insert(action.dsts, { dst_x, dst_y })
            end
            --DBG.dbms(action, false, 'action')

            return action
        end
    end
end


------- Candidate Actions -------



----- CA: Zone control (max_score: 350000) -----
-- TODO: rename?
function get_zone_action(cfg, fred_data)
    -- Find the best action to do in the zone described in 'cfg'
    -- This is all done together in one function, rather than in separate CAs so that
    --  1. Zones get done one at a time (rather than one CA at a time)
    --  2. Relative scoring of different types of moves is possible

    -- **** Retreat severely injured units evaluation ****
    if (cfg.action_type == 'retreat') then
        --DBG.print_ts_delta(fred_data.turn_start_time, '  ' .. cfg.zone_id .. ': retreat_injured eval')
        -- TODO: heal_loc and safe_loc are not used at this time
        -- keep for now and see later if needed
        local action = get_retreat_action(cfg, fred_data)
        if action then
            --std_print(action.action_str)
            return action
        end
    end

    -- **** Attack evaluation ****
    if (cfg.action_type == 'attack') then
        --DBG.print_ts_delta(fred_data.turn_start_time, '  ' .. cfg.zone_id .. ': attack eval')
        local action = get_attack_action(cfg, fred_data)
        if action then
            --DBG.dbms(action, false, 'action')

            local milk_xp_die_chance_limit = FCFG.get_cfg_parm('milk_xp_die_chance_limit')
            if (milk_xp_die_chance_limit < 0) then milk_xp_die_chance_limit = 0 end

            if (action.enemy_leader_die_chance > milk_xp_die_chance_limit) then
                --std_print('*** checking if we can get some more XP before killing enemy leader: ' .. action.enemy_leader_die_chance .. ' > ' .. milk_xp_die_chance_limit)
                local move_data = fred_data.move_data

                -- Attackers are all units that cannot attack the enemy leader
                local attackers = {}
                for id,loc in pairs(move_data.my_units) do
                    if (move_data.unit_copies[id].attacks_left > 0) then
                        attackers[id] = loc[1] * 1000 + loc[2]
                    end
                end
                local ids = FGM.get_value(move_data.my_attack_map[1], move_data.enemy_leader_x, move_data.enemy_leader_y, 'ids') or {}
                for _,id in ipairs(ids) do
                    attackers[id] = nil
                end

                -- Targets are all enemies except for the leader
                local targets = {}
                for enemy_id,enemy_loc in pairs(move_data.enemies) do
                    if (not move_data.unit_infos[enemy_id].canrecruit) then
                        targets[enemy_id] = enemy_loc[1] * 1000 + enemy_loc[2]
                    end
                end

                if next(attackers) and next(targets) then
                    local xp_attack_cfg = {
                        zone_id = 'all_map',
                        action_type = 'attack',
                        action_str = 'XP milking attack',
                        zone_units = attackers,
                        targets = targets,
                        value_ratio = (2 - action.enemy_leader_die_chance) * fred_data.ops_data.behavior.orders.value_ratio
                    }
                    --DBG.dbms(xp_attack_cfg, false, 'xp_attack_cfg')

                    local xp_attack_action = get_attack_action(xp_attack_cfg, fred_data)
                    --DBG.dbms(xp_attack_action, false, 'xp_attack_action')

                    if xp_attack_action then
                        action = xp_attack_action
                    end
                end
            end

            --std_print(action.action_str)
            return action
        end
    end

    -- **** Hold position evaluation ****
    if (cfg.action_type == 'hold') then
        --DBG.print_ts_delta(fred_data.turn_start_time, '  ' .. cfg.zone_id .. ': hold eval')
        local action
        if cfg.use_stored_leader_protection then
            if fred_data.ops_data.stored_leader_protection[cfg.zone_id] then
                DBG.print_debug_time('eval', fred_data.turn_start_time, '  --> hold evaluation (' .. cfg.action_str .. '): ' .. cfg.zone_id)
                action = AH.table_copy(fred_data.ops_data.stored_leader_protection[cfg.zone_id])
                fred_data.ops_data.stored_leader_protection[cfg.zone_id] = nil
            end
        else
            action = get_hold_action(cfg, fred_data)
        end

        if action then
            --DBG.print_ts_delta(fred_data.turn_start_time, action.action_str)
            if cfg.evaluate_only then
                --std_print('eval only: ' .. str)
                --local str = cfg.action_str .. ':' .. cfg.zone_id
                local leader_status = fred_data.ops_data.status.leader
                --DBG.dbms(leader_status, false, 'leader_status')
                --DBG.dbms(action, false, 'action')

                -- The 0.1 is there to protect against rounding errors and minor protection
                -- improvements that might not be worth it.
                if (leader_status.best_protection[cfg.zone_id].exposure < leader_status.exposure - 0.1) then
                    fred_data.ops_data.stored_leader_protection[cfg.zone_id] = action
                end
            else
                return action
            end
        end
        --DBG.dbms(fred_data.ops_data.stored_leader_protection, false, 'fred_data.ops_data.stored_leader_protection')
    end

    -- **** Advance in zone evaluation ****
    if (cfg.action_type == 'advance') then
        --DBG.print_ts_delta(fred_data.turn_start_time, '  ' .. cfg.zone_id .. ': advance eval')
        local action = get_advance_action(cfg, fred_data)
        if action then
            --DBG.print_ts_delta(fred_data.turn_start_time, action.action_str)
            return action
        end
    end

    -- **** Recruit evaluation ****
    if (cfg.action_type == 'recruit') then
        --DBG.print_ts_delta(fred_data.turn_start_time, '  ' .. cfg.zone_id .. ': recruit eval')
        -- Important: we cannot check recruiting here, as the units
        -- are taken off the map at this time, so it needs to be checked
        -- by the function setting up the cfg
        local action = {
            action_str = cfg.action_str,
            type = 'recruit',
        }
        return action
    end

    return nil  -- This is technically unnecessary, just for clarity
end


local function do_recruit(fred_data, ai, action)
    local move_data = fred_data.move_data
    local leader_objectives = fred_data.ops_data.objectives.leader
    --DBG.dbms(leader_objectives, false, 'leader_objectives')
    --DBG.dbms(action, false, 'action')

    local prerecruit = leader_objectives.prerecruit

    -- This is just a safeguard for now, to make sure nothing goes wrong
    if (not prerecruit) or (not prerecruit.units) or (not prerecruit.units[1]) then
        DBG.dbms(prerecruit, false, 'prerecruit')
        error("Leader was instructed to recruit, but no units to be recruited are set.")
    end

    -- If @action is set, this means that recruiting is done because the leader is needed
    -- in an action. In this case, we need to re-evaluate recruiting, because the leader
    -- might not be able to reach its hex from the pre-evaluated keep, and because some
    -- of the pre-evaluated recruit hexes might be used in the action.
    if action then
        local leader_id, leader_dst = move_data.leaders[wesnoth.current.side].id
        for i_u,unit in ipairs(action.units) do
            if (unit.id == leader_id) then
                leader_dst = action.dsts[i_u]
            end
        end
        local from_keep = FGM.get_value(move_data.effective_reach_maps[leader_id], leader_dst[1], leader_dst[2], 'from_keep')
        --std_print(leader_id, leader_dst[1] .. ',' .. leader_dst[2] .. '  <--  ' .. from_keep[1] .. ',' .. from_keep[2])

        local outofway_units = {}
        for id,_ in pairs(move_data.my_units_can_move_away) do
            outofway_units[id] = true
        end
        --DBG.dbms(outofway_units, false, 'outofway_units')

        -- TODO: eventually we might switch this to Fred's own gamestate_utils maps
        local avoid_map = LS.create()
        for _,dst in ipairs(action.dsts) do
            avoid_map:insert(dst[1], dst[2], true)
        end
        --DBG.dbms(avoid_map, false, 'avoid_map')

        local cfg = { outofway_penalty = -0.1 }
        prerecruit = fred_data.recruit:prerecruit_units(from_keep, avoid_map, outofway_units, cfg)
        --DBG.dbms(prerecruit, false, 'prerecruit')
    end

    -- Move leader to keep, if needed
    local leader = move_data.leaders[wesnoth.current.side]
    local recruit_loc = prerecruit.loc
    if (leader[1] ~= recruit_loc[1]) or (leader[2] ~= recruit_loc[2]) then
        --std_print('Need to move leader to keep first')
        local unit = wesnoth.get_unit(leader[1], leader[2])
        AHL.movepartial_outofway_stopunit(ai, unit, recruit_loc[1], recruit_loc[2])
    end

    for _,recruit_unit in ipairs(prerecruit.units) do
       --std_print('  ' .. recruit_unit.recruit_type .. ' at ' .. recruit_unit.recruit_hex[1] .. ',' .. recruit_unit.recruit_hex[2])
       local uiw = wesnoth.get_unit(recruit_unit.recruit_hex[1], recruit_unit.recruit_hex[2])
       if uiw then
           -- Generally, move out of way in direction of own leader
           -- TODO: change this
           local leader_loc = move_data.leaders[wesnoth.current.side]
           local dx, dy  = leader_loc[1] - recruit_unit.recruit_hex[1], leader_loc[2] - recruit_unit.recruit_hex[2]
           local r = math.sqrt(dx * dx + dy * dy)
           if (r ~= 0) then dx, dy = dx / r, dy / r end

           --std_print('    uiw: ' .. uiw.id)
           AH.move_unit_out_of_way(ai, uiw, { dx = dx, dy = dy })

           -- Make sure the unit really is gone now
           uiw = wesnoth.get_unit(recruit_unit.recruit_hex[1], recruit_unit.recruit_hex[2])
           if uiw then
               error('Unit was supposed to move out of the way for recruiting : ' .. uiw.id .. ' at ' .. uiw.x .. ',' .. uiw.y)
           end
       end

       if (not uiw) then
           AH.checked_recruit(ai, recruit_unit.recruit_type, recruit_unit.recruit_hex[1], recruit_unit.recruit_hex[2])
       end
   end

   fred_data.ops_data.objectives.leader.prerecruit = nil
end


local ca_zone_control = {}

function ca_zone_control:evaluation(cfg, fred_data, ai_debug)
    local ai = ai_debug or ai

    local score_zone_control = 350000
    local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'zone_control'

    DBG.print_debug_time('eval', fred_data.turn_start_time, '     - Evaluating zone_control CA:')

    -- This forces the turn data to be reset each call (use with care!)
    if DBG.show_debug('reset_turn') then
        fred_data.turn_data = nil
    end


    if (not fred_data.turn_data)
        or (fred_data.turn_data.turn_number ~= wesnoth.current.turn)
    then
        FOU.set_turn_data(fred_data)
        fred_data.ops_data = {}
    end
    FOU.set_ops_data(fred_data)

    FOU.get_action_cfgs(fred_data)
    --DBG.dbms(fred_data.zone_cfgs, false, 'fred_data.zone_cfgs')

    for i_c,cfg in ipairs(fred_data.zone_cfgs) do
        --DBG.dbms(cfg, false, 'cfg')

        -- Reserved actions have already been evaluated and checked for validity.
        -- We can skip changing units on the map, calling evaluation functions etc.
        if (cfg.action_type == 'reserved_action') then
            local action = {
                action_str = fred_data.ops_data.interaction_matrix.abbrevs[cfg.reserved_id],
                zone_id = cfg.zone_id,
                units = {},
                dsts = {}
            }

            for _,reserved_action in pairs(fred_data.ops_data.reserved_actions) do
                if (reserved_action.action_id == cfg.reserved_id) then
                    local tmp_unit = AH.table_copy(fred_data.move_data.units[reserved_action.id])
                    tmp_unit.id = reserved_action.id
                    table.insert(action.units, tmp_unit)
                    table.insert(action.dsts, { reserved_action.x, reserved_action.y })
                end
            end
            --DBG.dbms(action, false, 'action')

            if action.units[1] then
                fred_data.zone_action = action

                DBG.print_debug_time('eval', fred_data.turn_start_time, '--> done with all cfgs')
                return score_zone_control, action
            end
        else
            -- Extract all AI units with MP left (for enemy path finding, counter attack placement etc.)
            local extracted_units = {}
            for id,loc in pairs(fred_data.move_data.my_units_MP) do
                local unit_proxy = wesnoth.get_unit(loc[1], loc[2])
                wesnoth.extract_unit(unit_proxy)
                table.insert(extracted_units, unit_proxy)  -- Not a proxy unit any more at this point
            end

            -- Put the prerecruited units onto the map
            --DBG.dbms(fred_data.ops_data.objectives.leader.prerecruit)
            --[[ Do not do this, as hexes should be available with penalty
            -- TODO: delete code later, once we know whether this works
            if fred_data.ops_data.objectives.leader.prerecruit then
                for _,recruit in ipairs(fred_data.ops_data.objectives.leader.prerecruit.units) do
                    --std_print('Putting pre-recruit onto map: ' .. recruit.recruit_type, recruit.recruit_hex[1] .. ',' .. recruit.recruit_hex[2])
                    wesnoth.put_unit({
                        type = recruit.recruit_type,
                        random_traits = false,
                        name = "X",
                        random_gender = false,
                        moves = 0
                    },
                    recruit.recruit_hex[1], recruit.recruit_hex[2])
                end
            end
            --]]

            local zone_action = get_zone_action(cfg, fred_data)

            --[[
            if fred_data.ops_data.objectives.leader.prerecruit then
                for _,recruit in ipairs(fred_data.ops_data.objectives.leader.prerecruit.units) do
                    --std_print('Removing pre-recruit onto map: ' .. recruit.recruit_type, recruit.recruit_hex[1] .. ',' .. recruit.recruit_hex[2])
                    wesnoth.erase_unit(recruit.recruit_hex[1], recruit.recruit_hex[2])
                end
            end
            --]]

            for _,extracted_unit in ipairs(extracted_units) do wesnoth.put_unit(extracted_unit) end

            if zone_action then
                zone_action.zone_id = cfg.zone_id
                --DBG.dbms(zone_action, false, 'zone_action')
                fred_data.zone_action = zone_action

                DBG.print_debug_time('eval', fred_data.turn_start_time, '--> done with all cfgs')
                return score_zone_control, zone_action
            end
        end
    end

    DBG.print_debug_time('eval', fred_data.turn_start_time, '--> done with all cfgs')

    return 0
end

function ca_zone_control:execution(cfg, fred_data, ai_debug)
    local ai = ai_debug or ai

    local action = fred_data.zone_action.zone_id .. ': ' .. fred_data.zone_action.action_str
    --DBG.dbms(fred_data.zone_action, false, 'fred_data.zone_action')


    -- If recruiting is set, we just do that, nothing else needs to be checked
    if (fred_data.zone_action.type == 'recruit') then
        DBG.print_debug_time('exec', fred_data.turn_start_time, '=> exec: ' .. action)
        do_recruit(fred_data, ai)
        return
    end


    local enemy_proxy
    if fred_data.zone_action.enemy then
        enemy_proxy = wesnoth.get_units { id = next(fred_data.zone_action.enemy) }[1]
    end

    local gamestate_changed = false

    while fred_data.zone_action.units and (#fred_data.zone_action.units > 0) do
        local next_unit_ind = 1

        -- If this is an attack combo, reorder units to
        --   - Use unit with best rating
        --   - Maximize chance of leveling up
        --   - Give maximum XP to unit closest to advancing
        if enemy_proxy and fred_data.zone_action.units[2] then
            local attacker_copies, attacker_infos = {}, {}
            local combo = {}
            for i,unit in ipairs(fred_data.zone_action.units) do
                table.insert(attacker_copies, fred_data.move_data.unit_copies[unit.id])
                table.insert(attacker_infos, fred_data.move_data.unit_infos[unit.id])

                combo[unit[1] * 1000 + unit[2]] = fred_data.zone_action.dsts[i][1] * 1000 + fred_data.zone_action.dsts[i][2]
            end

            local defender_info = fred_data.move_data.unit_infos[enemy_proxy.id]

            local cfg_attack = { value_ratio = fred_data.ops_data.behavior.orders.value_ratio }
            local combo_outcome = FAU.attack_combo_eval(combo, fred_data.zone_action.enemy, cfg_attack, fred_data.move_data, fred_data.move_cache)
            --std_print('\noverall kill chance: ', combo_outcome.defender_damage.die_chance)

            local enemy_level = defender_info.level
            if (enemy_level == 0) then enemy_level = 0.5 end
            --std_print('enemy level', enemy_level)

            -- Check if any unit has a chance to level up
            local levelups = { anybody = false }
            for ind,unit in ipairs(fred_data.zone_action.units) do
                local unit_info = fred_data.move_data.unit_infos[unit.id]
                local XP_diff = unit_info.max_experience - unit_info.experience

                local levelup_possible, levelup_certain = false, false
                if (XP_diff <= enemy_level) then
                    levelup_certain = true
                    levelups.anybody = true
                elseif (XP_diff <= enemy_level * 8) then
                    levelup_possible = true
                    levelups.anybody = true
                end
                --std_print('  ' .. unit_info.id, XP_diff, levelup_possible, levelup_certain)

                levelups[ind] = { certain = levelup_certain, possible = levelup_possible}
            end
            --DBG.dbms(levelups, false, 'levelups')


            --DBG.print_ts_delta(fred_data.turn_start_time, 'Reordering units for attack')
            local max_rating
            for ind,unit in ipairs(fred_data.zone_action.units) do
                local unit_info = fred_data.move_data.unit_infos[unit.id]

                local att_outcome, def_outcome = FAU.attack_outcome(
                    attacker_copies[ind], enemy_proxy,
                    fred_data.zone_action.dsts[ind],
                    attacker_infos[ind], defender_info,
                    fred_data.move_data, fred_data.move_cache
                )
                local rating_table, att_damage, def_damage =
                    FAU.attack_rating({ unit_info }, defender_info, { fred_data.zone_action.dsts[ind] }, { att_outcome }, def_outcome, cfg_attack, fred_data.move_data)

                -- The base rating is the individual attack rating
                local rating = rating_table.rating
                --std_print('  base_rating ' .. unit_info.id, rating)

                -- If the target can die, we might want to reorder, in order
                -- to maximize the chance to level up and give the most XP
                -- to the most appropriate unit
                if (combo_outcome.def_outcome.hp_chance[0] > 0) then
                    local XP_diff = unit_info.max_experience - unit_info.experience

                    local extra_rating
                    if levelups.anybody then
                        -- If any of the units has a chance to level up, the
                        -- main rating is maximizing this chance
                        if levelups[ind].possible then
                            local utility = def_outcome.hp_chance[0] * (1 - att_outcome.hp_chance[0])
                            -- Want least advanced and most valuable unit to go first
                            extra_rating = 100 * utility + XP_diff / 10
                            extra_rating = extra_rating + att_damage[1].unit_value / 100
                        elseif levelups[ind].certain then
                            -- use square on CTD, to be really careful with these units
                            local utility = (1 - att_outcome.hp_chance[0])^2
                            -- Want least advanced and most valuable unit to go first
                            extra_rating = 100 * utility + XP_diff / 10
                            extra_rating = extra_rating + att_damage[1].unit_value / 100
                        else
                            local utility = (1 - def_outcome.hp_chance[0]) * (1 - att_outcome.hp_chance[0])
                            -- Want most advanced and least valuable  unit to go last
                            extra_rating = 90 * utility + XP_diff / 10
                            extra_rating = extra_rating - att_damage[1].unit_value / 100
                        end
                        --std_print('    levelup utility', utility)
                    else
                        -- If no unit has a chance to level up, giving the
                        -- most XP to the most advanced unit is desirable, but
                        -- should not entirely dominate the attack rating
                        local xp_fraction = unit_info.experience / (unit_info.max_experience - 8)
                        if (xp_fraction > 1) then xp_fraction = 1 end
                        local x = 2 * (xp_fraction - 0.5)
                        local y = 2 * (def_outcome.hp_chance[0] - 0.5)

                        -- The following prefers units with low XP and no chance to kill
                        -- as well as units with high XP and high chance to kill
                        -- It is normalized to [0..1]
                        local utility = (x * y + 1) / 2
                        --std_print('      ' .. xp_fraction, def_outcome.hp_chance[0])
                        --std_print('      ' .. x, y, utility)

                        extra_rating = 10 * utility * (1 - att_outcome.hp_chance[0])^2

                        -- Also want most valuable unit to go first
                        extra_rating = extra_rating + att_damage[1].unit_value / 1000
                        --std_print('    XP gain utility', utility)
                    end

                    rating = rating + extra_rating
                    --std_print('    rating', rating)
                end

                if (not max_rating) or (rating > max_rating) then
                    max_rating, next_unit_ind = rating, ind
                end
            end
            --DBG.print_ts_delta(fred_data.turn_start_time, 'Best unit to go next:', fred_data.zone_action.units[next_unit_ind].id, max_rating, next_unit_ind)
        end
        --DBG.print_ts_delta(fred_data.turn_start_time, 'next_unit_ind', next_unit_ind)

        local unit = wesnoth.get_units { id = fred_data.zone_action.units[next_unit_ind].id }[1]
        if (not unit) then
            fred_data.zone_action = nil
            return
        end


        local dst = fred_data.zone_action.dsts[next_unit_ind]

        -- If this is the leader (and has MP left), recruit first
        local leader_objectives = fred_data.ops_data.objectives.leader
        if unit.canrecruit and (unit.moves > 0)
            and leader_objectives.prerecruit and leader_objectives.prerecruit.units and leader_objectives.prerecruit.units[1]
        then
            DBG.print_debug_time('exec', fred_data.turn_start_time, '=> exec: ' .. action .. ' (leader used -> recruit first)')
            do_recruit(fred_data, ai, fred_data.zone_action)
            gamestate_changed = true

            -- We also check here separately whether the leader can still get to dst.
            -- This is also caught below, but the ops analysis should never let this
            -- happen, so we want to know about it.
            local _,cost = wesnoth.find_path(unit, dst[1], dst[2])
            if (cost > unit.moves) then
                error('Leader was supposed to move to ' .. dst[1] .. ',' .. dst[2] .. ' after recruiting, but this is not possible. Check operations analysis.')
            end
        end

        DBG.print_debug_time('exec', fred_data.turn_start_time, '=> exec: ' .. action)

        -- The following are some tests to make sure the intended move is actually
        -- possible, as there might have been some interference with units moving
        -- out of the way. It is also possible that units that are supposed to
        -- move out of the way cannot actually do so in practice. Abandon the move
        -- and reevaluate in that case. However, we can only do this if the gamestate
        -- has actually be changed already, or the CA will be blacklisted
        if gamestate_changed then
            -- It's possible that one of the units got moved out of the way
            -- by a move of a previous unit and that it cannot reach the dst
            -- hex any more. In that case we stop and reevaluate.
            -- TODO: make sure up front that move combination is possible
            local _,cost = wesnoth.find_path(unit, dst[1], dst[2])
            if (cost > unit.moves) then
                fred_data.zone_action = nil
                return
            end

            -- It is also possible that a unit moving out of the way for a previous
            -- move of this combination is now in the way again and cannot move any more.
            -- We also need to stop execution in that case.
            -- Just checking for moves > 0 is not always sufficient.
            local unit_in_way
            if (unit.x ~= dst[1]) or (unit.y ~= dst[2]) then
                unit_in_way = wesnoth.get_unit(dst[1], dst[2])
            end
            if unit_in_way then
                uiw_reach = wesnoth.find_reach(unit_in_way)

                -- Check whether the unit to move out of the way has an unoccupied hex to move to.
                local unit_blocked = true
                for _,uiw_loc in ipairs(uiw_reach) do
                    -- Unit in the way of the unit in the way
                    local uiw_uiw = wesnoth.get_unit(uiw_loc[1], uiw_loc[2])
                    if (not uiw_uiw) then
                        unit_blocked = false
                        break
                    end
                end

                if unit_blocked then
                    fred_data.zone_action = nil
                    return
                end
            end
        end


        -- Generally, move out of way in direction of own leader
        local leader_loc = fred_data.move_data.leaders[wesnoth.current.side]
        local dx, dy  = leader_loc[1] - dst[1], leader_loc[2] - dst[2]
        local r = math.sqrt(dx * dx + dy * dy)
        if (r ~= 0) then dx, dy = dx / r, dy / r end

        -- However, if the unit in the way is part of the move combo, it needs to move in the
        -- direction of its own goal, otherwise it might not be able to reach it later
        local unit_in_way
        if (unit.x ~= dst[1]) or (unit.y ~= dst[2]) then
            unit_in_way = wesnoth.get_unit(dst[1], dst[2])
        end

        if unit_in_way then
            if unit_in_way.canrecruit then
                local leader_objectives = fred_data.ops_data.objectives.leader
                dx = leader_objectives.final[1] - unit_in_way.x
                dy = leader_objectives.final[2] - unit_in_way.y
                if (dx == 0) and (dy == 0) then -- this can happen if leader is on leader goal hex
                    -- In this case, as a last resort, move away from the enemy leader
                    dx = unit_in_way.x - fred_data.move_data.enemy_leader_x
                    dy = unit_in_way.y - fred_data.move_data.enemy_leader_y
                end
                local r = math.sqrt(dx * dx + dy * dy)
                if (r ~= 0) then dx, dy = dx / r, dy / r end
            else
                for i_u,u in ipairs(fred_data.zone_action.units) do
                    if (u.id == unit_in_way.id) then
                        --std_print('  unit is part of the combo', unit_in_way.id, unit_in_way.x, unit_in_way.y)

                        local uiw_dst = fred_data.zone_action.dsts[i_u]
                        local path, _ = wesnoth.find_path(unit_in_way, uiw_dst[1], uiw_dst[2])

                        -- If we can find an unoccupied hex along the path, move the
                        -- unit_in_way there, in order to maximize the chances of it
                        -- making it to its goal. However, do not move all the way and
                        -- do partial move only, in case something changes as result of
                        -- the original unit's action.
                        local moveto
                        for i = 2,#path do
                            local uiw_uiw = wesnoth.get_unit(path[i][1], path[i][2])
                            if (not uiw_uiw) then
                                moveto = { path[i][1], path[i][2] }
                                break
                            end
                        end

                        if moveto then
                            --std_print('    ' .. unit_in_way.id .. ': moving out of way to:', moveto[1], moveto[2])
                            AH.checked_move(ai, unit_in_way, moveto[1], moveto[2])

                            -- If this got to its final destination, attack with this unit first, otherwise it might be stranded
                            -- TODO: only if other units have chance to kill?
                            if (moveto[1] == uiw_dst[1]) and (moveto[2] == uiw_dst[2]) then
                                --std_print('      going to final destination')
                                dst = uiw_dst
                                next_unit_ind = i_u
                                unit = unit_in_way
                            end
                        else
                            if (not path) or (not path[1]) or (not path[2]) then
                                std_print('Trying to identify path table error !!!!!!!!')
                                std_print(i_u, u.id, unit_in_way.id)
                                std_print(unit.id, unit.x, unit.y)
                                DBG.dbms(fred_data.zone_action, -1)
                                DBG.dbms(dst, -1)
                                DBG.dbms(path, -1)
                            end
                            dx, dy = path[2][1] - path[1][1], path[2][2] - path[1][2]
                            local r = math.sqrt(dx * dx + dy * dy)
                            if (r ~= 0) then dx, dy = dx / r, dy / r end
                        end

                        break
                    end
                end
            end
        end

        if unit_in_way and (dx == 0) and (dy == 0) then
            error(unit_in_way.id .. " to move out of way with dx = dy = 0")
        end

        if fred_data.zone_action.partial_move then
            AHL.movepartial_outofway_stopunit(ai, unit, dst[1], dst[2], { dx = dx, dy = dy })
            if (unit.moves == 0) then
                fred_data.ops_data.used_units[unit.id] = fred_data.zone_action.zone_id
            end
        else
            AH.movefull_outofway_stopunit(ai, unit, dst[1], dst[2], { dx = dx, dy = dy })
            fred_data.ops_data.used_units[unit.id] = fred_data.zone_action.zone_id
        end
        gamestate_changed = true


        -- Remove these from the table
        table.remove(fred_data.zone_action.units, next_unit_ind)
        table.remove(fred_data.zone_action.dsts, next_unit_ind)

        -- Then do the attack, if there is one to do
        if enemy_proxy and (wesnoth.map.distance_between(unit.x, unit.y, enemy_proxy.x, enemy_proxy.y) == 1) then
            local weapon = fred_data.zone_action.weapons[next_unit_ind]
            table.remove(fred_data.zone_action.weapons, next_unit_ind)

            AH.checked_attack(ai, unit, enemy_proxy, weapon)

            -- If enemy got killed, we need to stop here
            if (not enemy_proxy.valid) then
                fred_data.zone_action.units = nil
            end

            -- Need to reset the enemy information if there are more attacks in this combo
            if fred_data.zone_action.units and fred_data.zone_action.units[1] then
                fred_data.move_data.unit_copies[enemy_proxy.id] = wesnoth.copy_unit(enemy_proxy)
                fred_data.move_data.unit_infos[enemy_proxy.id] = FU.single_unit_info(enemy_proxy)
            end
        end

        if (not unit) or (not unit.valid) then
            fred_data.zone_action.units = nil
        end
    end

    fred_data.zone_action = nil
end

return ca_zone_control
