local H = wesnoth.require "helper"
local FAU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack_utils.lua"
local FDI = wesnoth.require "~/add-ons/AI-demos/lua/fred_data_incremental.lua"
local FGM = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_map.lua"
local FMC = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_map_config.lua"
local FMU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_map_utils.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"
local COMP = wesnoth.require "~/add-ons/AI-demos/lua/compatibility.lua"

local fred_advance = {}

function fred_advance.get_advance_action(zone_cfg, fred_data)
    -- Advancing is now only moving onto unthreatened hexes; everything
    -- else should be covered by holding, village grabbing, protecting, etc.

    DBG.print_debug_time('eval', fred_data.turn_start_time, '  - advance evaluation: ' .. zone_cfg.zone_id .. ' (' .. string.format('%.2f', zone_cfg.rating) .. ')')

    --DBG.dbms(zone_cfg, false, 'zone_cfg')
    local raw_cfg = FMC.get_raw_cfgs(zone_cfg.zone_id)
    --DBG.dbms(raw_cfg, false, 'raw_cfg')

    local move_data = fred_data.move_data

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
    local leader_goal = fred_data.ops_data.objectives.leader.final
    for id,_ in pairs(advancers) do
        avoid_maps[id] = {}
        if (id ~= move_data.my_leader.id) then
            FGM.set_value(avoid_maps[id], leader_goal[1], leader_goal[2], 'avoid', true)
        end
    end

    local value_ratio = zone_cfg.value_ratio or fred_data.ops_data.behavior.orders.value_ratio
    --std_print('value_ratio: ' .. zone_cfg.zone_id, value_ratio)
    -- Push factors are only set for zones with assigned enemies.
    --local push_factor = fred_data.ops_data.behavior.zone_push_factors[zone_cfg.zone_id] or 1
    local push_factor = fred_data.ops_data.behavior.orders.push_factor
    --std_print('push_factor: ' .. zone_cfg.zone_id, push_factor)


    -- If we got here and nobody is holding already, that means a hold was attempted (with the same units
    -- now used for advancing) and either not possible or not deemed worth it.
    -- Either way, we should be careful with advancing into enemy threats.
    local already_holding = true
    if (not next(fred_data.ops_data.objectives.protect.zones[zone_cfg.zone_id].holders)) then
        already_holding = false
    end
    --std_print(zone_cfg.zone_id .. ': already_holding: ', already_holding)


    -- Map of adjacent villages that can be reached by the enemy
    -- TODO: this currently ignores that the advancing unit itself might block the village from the enemy
    local adjacent_village_map = {}
    for x,y,_ in FGM.iter(move_data.village_map) do
        for enemy_id,_ in pairs(move_data.enemies) do
            local moves_left = FGM.get_value(move_data.reach_maps[enemy_id], x, y, 'moves_left')
            if moves_left then
                for xa,ya in H.adjacent_tiles(x,y) do
                    FGM.set_value(adjacent_village_map, xa, ya, 'village_xy', 1000 * x + y)
                end
            end
        end
    end
    if false then
        DBG.show_fgm_with_message(adjacent_village_map, 'village_xy', 'Adjacent vulnerable villages')
    end


    local safe_loc = false
    local unit_rating_maps = {}
    local max_rating, best_id, best_hex = - math.huge
    for id,xy in pairs(advancers) do
        local unit_loc = { math.floor(xy / 1000), xy % 1000 }
        -- Don't use ops_slf here, but pre-calculated zone_maps. The zone_map used can be
        -- different from that in the SLF, e.g. for the leader zone or if parts of a zone are
        -- to be avoided (the latter is not implemented yet).
        local is_unit_in_zone = FGM.get_value(fred_data.ops_data.zone_maps[zone_cfg.zone_id], unit_loc[1], unit_loc[2], 'in_zone')
        --std_print('is_unit_in_zone: ' .. id, zone_cfg.zone_id, is_unit_in_zone)

        unit_rating_maps[id] = {}

        local unit_value = move_data.unit_infos[id].unit_value

        -- Fastest unit first, after that strongest unit first
        -- These are small, mostly just tie breakers
        local max_moves = move_data.unit_infos[id].max_moves
        local rating_moves = move_data.unit_infos[id].moves / 10
        local rating_power = move_data.unit_infos[id].current_power / 1000

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
            goal_perp = goal_perp * FGM.get_value(ADmap, goal[1], goal[2], 'sign')
            --std_print('goal forward, perp: ' .. goal_forward .. ', ' .. goal_perp)
            for x,y,_ in FGM.iter(move_data.effective_reach_maps[id]) do
                if (not FGM.get_value(avoid_maps[id], x, y, 'avoid')) then
                    local forward = FGM.get_value(ADmap, x, y, 'forward')
                    local perp = FGM.get_value(ADmap, x, y, 'perp')

                    perp = perp * (FGM.get_value(ADmap, x, y, 'sign') or 1)

                    local df = math.abs(forward - goal_forward)
                    local dp = math.abs(perp - goal_perp)

                    -- We want to emphasize that small offsets are ok, but then have it increase quickly
                    --[[ TODO: probably don't want to do this, but leave code for now until sure
                    for xa,ya in H.adjacent_tiles(x, y) do
                        local adj_forward = FGM.get_value(ADmap, xa, ya, 'forward')
                        local apj_perp = FGM.get_value(ADmap, xa, ya, 'perp')
                        if adj_forward then
                            apj_perp = apj_perp * FGM.get_value(ADmap, xa, ya, 'sign')

                            adj_df = math.abs(adj_forward - goal_forward)
                            adj_dp = math.abs(apj_perp - goal_perp)
                            if (adj_df < df) then df = adj_df end
                            if (adj_dp < dp) then dp = adj_dp end
                        end
                    end
                    --]]

                    local cost = (df / max_moves)^ 1.5 + (dp / max_moves) ^ 2
                    cost = cost * max_moves

                    FGM.set_value(cost_map, x, y, 'cost', cost)
                    --cost_map[x][y].forward = forward
                    --cost_map[x][y].perp = perp
                    cost_map[x][y].df = df
                    cost_map[x][y].dp = dp
                end
            end
        else
            -- If the unit is not in the zone, move toward the goal hex via a path
            -- that has a penalty rating for hexes with overall negative full-move
            -- influence. This is done so that units take a somewhat longer router around
            -- the back of a zone rather than taking the shorter route straight
            -- into the middle of the enemies.
            -- TODO: this might have to be done differently for maps other than Freelands

            local unit_copy = move_data.unit_copies[id]
            local unit_infl = move_data.unit_infos[id].current_power
            -- We're doing this out here, so that it has not be done for each hex in the custom cost function
            local influence_mult = 1 / unit_infl
            --std_print('unit out of zone: ' .. id, unit_infl, influence_mult)
            --local path, cost = wesnoth.find_path(unit_copy, goal[1], goal[2], { ignore_units = true })
            local path, cost = COMP.find_path_custom_cost(unit_copy, goal[1], goal[2], function(x, y, current_cost)
                return FMU.influence_custom_cost(x, y, unit_copy, influence_mult, move_data.influence_maps, fred_data)
            end)

            -- Debug code for showing the path
            if false then
                local path_map = {}
                for _,loc in ipairs(path) do
                    FGM.set_value(path_map, loc[1], loc[2], 'cost', loc[3])
                end
                DBG.show_fgm_with_message(path_map, 'cost', 'path_map', unit_copy[id])
            end

            -- Find the hex one past the last the unit can reach
            -- This ignores enemies etc. but that should be fine
            local total_cost, path_goal_hex = 0
            for i = 2,#path do
                local x, y = path[i][1], path[i][2]
                local movecost = FDI.get_unit_movecost(unit_copy, x, y, fred_data.caches.movecost_maps)
                total_cost = total_cost + movecost
                --std_print(i, x, y, movecost, total_cost)
                path_goal_hex = path[i] -- This also works when the path is shorter than the unit's moves
                if (total_cost > move_data.unit_infos[id].moves) then
                    break
                end
            end
            --std_print('path goal hex: ', path_goal_hex[1], path_goal_hex[2])

            local cm = wesnoth.find_cost_map(
                { type = "xyz" }, -- SUF not matching any unit
                { { path_goal_hex[1], path_goal_hex[2], wesnoth.current.side, fred_data.move_data.unit_infos[id].type } },
                { ignore_units = true }
            )

            for _,cost in pairs(cm) do
                if (cost[3] > -1) then
                    FGM.add(cost_map, cost[1], cost[2], 'cost', cost[3])
                end
            end
        end

        if DBG.show_debug('advance_cost_maps') then
            --DBG.show_fgm_with_message(cost_map, 'forward', zone_cfg.zone_id ..': advance cost map forward', move_data.unit_copies[id])
            --DBG.show_fgm_with_message(cost_map, 'perp', zone_cfg.zone_id ..': advance cost map perp', move_data.unit_copies[id])
            DBG.show_fgm_with_message(cost_map, 'df', zone_cfg.zone_id ..': advance cost map delta forward', move_data.unit_copies[id])
            DBG.show_fgm_with_message(cost_map, 'dp', zone_cfg.zone_id ..': advance cost map delta perp', move_data.unit_copies[id])
            DBG.show_fgm_with_message(cost_map, 'cost', zone_cfg.zone_id ..': advance cost map', move_data.unit_copies[id])
        end

        -- Use a more defensive rating for units that have been isolated in enemy territory.
        -- However, we do not know whether that is a case until the end of the analysis,
        -- so we carry both ratings throughout that and use a flag that gets set along the way.
        local unit_df = FGM.get_value(cost_map, unit_loc[1], unit_loc[2], 'df')
        local use_defensive_rating = false
        -- TODO: the condition excludes units outside the zone; should they be included?
        if unit_df and (unit_df > 2) then
            use_defensive_rating = true
        end
        --std_print(id .. ' unit_df: ', unit_df, use_defensive_rating)

        local max_unit_rating, best_unit_hex = - math.huge
        local max_unit_def_rating, best_unit_def_hex = - math.huge
        for x,y,_ in FGM.iter(move_data.effective_reach_maps[id]) do
            if (not FGM.get_value(avoid_maps[id], x, y, 'avoid')) then
                local rating = rating_moves + rating_power
                FGM.set_value(unit_rating_maps[id], x, y, 'unit_rating', rating)

                -- Counter attack outcome
                local unit_moved = {}
                unit_moved[id] = { x, y }
                local old_locs = { { unit_loc[1], unit_loc[2] } }
                local new_locs = { { x, y } }
                -- TODO: Use FVS here also?
                local counter_outcomes = FAU.calc_counter_attack(
                    unit_moved, old_locs, new_locs, fred_data.ops_data.place_holders, nil, cfg_attack, fred_data
                )

                if counter_outcomes then
                    --DBG.dbms(counter_outcomes, false, 'counter_outcomes')
                    --std_print('  die_chance', counter_outcomes.def_outcome.hp_chance[0], id .. ': ' .. x .. ',' .. y)

                    -- This is the standard attack rating (roughly) in units of cost (gold)
                    local counter_rating = 0

--                    if already_holding then
--                        counter_rating = - counter_outcomes.rating_table.max_weighted_rating
                        --std_print(x .. ',' .. y .. ': counter' , counter_rating, unit_value_ratio)
--                    else
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
                        counter_rating = damage_rating + heal_rating
                        counter_rating = counter_rating - enemy_rating / 10
--                    end

                    -- The die chance is already included in the rating, but we
                    -- want it to be even more important here (and very non-linear)
                    -- It's set to be quadratic and take unity value at the desperate attack
                    -- hp_chance[0]=0.85; but then it is the difference between die chances that
                    -- really matters, so we multiply by another factor 2.
                    -- This makes this a huge contribution to the rating.
                    local die_rating = - unit_value_ratio * unit_value * counter_outcomes.def_outcome.hp_chance[0] ^ 2 / 0.85^2 * 2
                    counter_rating = counter_rating + die_rating

                    rating = rating + counter_rating
                    FGM.set_value(unit_rating_maps[id], x, y, 'counter_rating', counter_rating)
                end

                if (not counter_outcomes) or (counter_outcomes.def_outcome.hp_chance[0] < 0.85) then
                    safe_loc = true
                end

                -- Everything is balanced against the value loss rating from the counter attack
                -- For now, let's set being one full move away equal to half the value of the unit,
                -- multiplied by push_factor
                -- Note: unit_value_ratio is already taken care of in both the location of the goal hex
                -- and the counter attack rating.  Is including the push factor overdoing it?


                -- Small preference for villages we don't own (although this
                -- should mostly be covered by the village grabbing action already)
                -- Equal to gold difference between grabbing and not grabbing (not counting support)
                local village_bonus = 0
                local owner = FGM.get_value(move_data.village_map, x, y, 'owner')
                if owner and (owner ~= wesnoth.current.side) then
                    if (owner == 0) then
                        village_bonus = village_bonus + 3
                    else
                        village_bonus = village_bonus + 6
                    end
                end

                if FGM.get_value(adjacent_village_map, x, y, 'village_xy') then
                    village_bonus = village_bonus - 6
                end

                -- Somewhat larger preference for villages for injured units
                -- Also add a half-hex bonus for villages in general; no need not to go there
                -- all else being equal
                if owner and (not move_data.unit_infos[id].abilities.regenerate) then
                    village_bonus = village_bonus + unit_value * (1 / hp_forward_factor - 1) -- zero for uninjured unit
                end

                local bonus_rating = village_bonus

                -- Small bonus for the terrain; this does not really matter for
                -- unthreatened hexes and is already taken into account in the
                -- counter attack calculation for others. Just a tie breaker.
                local my_defense = FDI.get_unit_defense(move_data.unit_copies[id], x, y, fred_data.caches.defense_maps)
                bonus_rating = bonus_rating + my_defense / 10
                rating = rating + bonus_rating
                FGM.set_value(unit_rating_maps[id], x, y, 'bonus_rating', bonus_rating)

                local dist = FGM.get_value(cost_map, x, y, 'cost')
                local dist_rating = - dist * unit_value / 2 * push_factor * hp_forward_factor
                FGM.set_value(unit_rating_maps[id], x, y, 'dist_rating', dist_rating)

                local defensive_rating = rating - dist
                rating = rating + dist_rating

                FGM.set_value(unit_rating_maps[id], x, y, 'rating', rating)
                FGM.set_value(unit_rating_maps[id], x, y, 'defensive_rating', defensive_rating)

                local fm_infl = FGM.get_value(move_data.influence_maps, x, y, 'full_move_influence')
                FGM.set_value(unit_rating_maps[id], x, y, 'fm_infl', fm_infl)

                if (fm_infl >= 0) then use_defensive_rating = false end

                if (rating > max_unit_rating) then
                    max_unit_rating = rating
                    best_unit_hex = { x, y }
                end
                if (defensive_rating > max_unit_def_rating) then
                    max_unit_def_rating = defensive_rating
                    best_unit_def_hex = { x, y }
                end
            end
        end
        --std_print(id .. ' after use_defensive_rating: ' .. tostring(use_defensive_rating))

        if use_defensive_rating then
            if (max_unit_def_rating > max_rating) then
                max_rating = max_unit_def_rating
                best_id = id
                best_hex = best_unit_def_hex
            end
        else
            if (max_unit_rating > max_rating) then
                max_rating = max_unit_rating
                best_id = id
                best_hex = best_unit_hex
            end
        end
    end
    --std_print('best unit: ' .. best_id, best_hex[1], best_hex[2])

    if DBG.show_debug('advance_unit_rating') then
        for id,unit_rating_map in pairs(unit_rating_maps) do
            DBG.show_fgm_with_message(unit_rating_map, 'rating', zone_cfg.zone_id ..': advance unit rating (unit value = ' .. move_data.unit_infos[id].unit_value .. ')', move_data.unit_copies[id])
        end
    end
    if DBG.show_debug('advance_unit_rating_details') then
        for id,unit_rating_map in pairs(unit_rating_maps) do
            DBG.show_fgm_with_message(unit_rating_map, 'unit_rating', zone_cfg.zone_id ..': advance unit_rating (unit value = ' .. move_data.unit_infos[id].unit_value .. ')', move_data.unit_copies[id])
            DBG.show_fgm_with_message(unit_rating_map, 'dist_rating', zone_cfg.zone_id ..': advance dist_rating (unit value = ' .. move_data.unit_infos[id].unit_value .. ')', move_data.unit_copies[id])
            DBG.show_fgm_with_message(unit_rating_map, 'counter_rating', zone_cfg.zone_id ..': advance counter_rating (unit value = ' .. move_data.unit_infos[id].unit_value .. ')', move_data.unit_copies[id])
            DBG.show_fgm_with_message(unit_rating_map, 'bonus_rating', zone_cfg.zone_id ..': advance bonus_rating (unit value = ' .. move_data.unit_infos[id].unit_value .. ')', move_data.unit_copies[id])
            DBG.show_fgm_with_message(unit_rating_map, 'fm_infl', zone_cfg.zone_id ..': full move influence' .. move_data.unit_infos[id].unit_value .. ')', move_data.unit_copies[id])
            DBG.show_fgm_with_message(unit_rating_map, 'rating', zone_cfg.zone_id ..': advance total rating (unit value = ' .. move_data.unit_infos[id].unit_value .. ')', move_data.unit_copies[id])
            DBG.show_fgm_with_message(unit_rating_map, 'defensive_rating', zone_cfg.zone_id ..': advance total defensive_rating (unit value = ' .. move_data.unit_infos[id].unit_value .. ')', move_data.unit_copies[id])
        end
    end


    -- If no safe location is found, check for desperate attack
    local best_target, best_weapons
    local action_str = zone_cfg.action_str
    if (not safe_loc) then
        --std_print('----- no safe advance location found -----')

        local cfg_attack_desp = { value_ratio = 0.2 } -- mostly based on damage done to enemy

        local max_attack_rating, best_attacker_id, best_attack_hex = - math.huge
        for id,xy in pairs(advancers) do
            --std_print('checking desperate attacks for ' .. id)

            local attacker = {}
            attacker[id] = move_data.units[id]
            for enemy_id,enemy_loc in pairs(move_data.enemies) do
                if FGM.get_value(move_data.attack_maps[1][id], enemy_loc[1], enemy_loc[2], 'current_power') then
                    --std_print('    potential target:' .. enemy_id)

                    local target = {}
                    target[enemy_id] = enemy_loc
                    local attack_combos = FAU.get_attack_combos(
                        attacker, target, cfg_attack_desp, move_data.effective_reach_maps, false, fred_data
                    )

                    for _,combo in ipairs(attack_combos) do
                        local combo_outcome = FAU.attack_combo_eval(combo, target, cfg_attack_desp, fred_data)
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

                        if do_attack and (combo_outcome.rating_table.rating > max_attack_rating) then
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

return fred_advance
