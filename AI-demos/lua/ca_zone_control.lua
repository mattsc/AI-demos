local H = wesnoth.require "helper"
local AH = wesnoth.require "ai/lua/ai_helper.lua"
local AHL = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper_local.lua"
local FGM = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_map.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local FS = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_status.lua"
local FVS = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_virtual_state.lua"
local FBU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_benefits_utilities.lua"
local FDI = wesnoth.require "~/add-ons/AI-demos/lua/fred_data_incremental.lua"
local FDM = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_data_move.lua"
local FDT = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_data_turn.lua"
local FOU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_ops_utils.lua"
local FA = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack.lua"
local FAU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack_utils.lua"
local FMU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_map_utils.lua"
local LS = wesnoth.require "location_set"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"
local FRU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_retreat_utils.lua"
local FH = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_hold.lua"
local FHU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_hold_utils.lua"
local FMLU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_move_leader_utils.lua"
local FCFG = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_config.lua"
local FMC = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_map_config.lua"
local COMP = wesnoth.require "~/add-ons/AI-demos/lua/compatibility.lua"


----- Advance: -----
local function get_advance_action(zone_cfg, fred_data)
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

                    -- TODO: this is not good, should really expand the map in the first place
                    if (not forward) then
                        forward = wesnoth.map.distance_between(x, y, goal[1], goal[2]) + goal_forward
                        perp = 10
                    end

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
                if FGM.get_value(move_data.unit_attack_maps[1][id], enemy_loc[1], enemy_loc[2], 'current_power') then
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


----- Retreat: -----
local function get_retreat_action(zone_cfg, fred_data)
    DBG.print_debug_time('eval', fred_data.turn_start_time, '  - retreat evaluation: ' .. zone_cfg.zone_id .. ' (' .. string.format('%.2f', zone_cfg.rating) .. ')')

    -- Combines moving leader to village or keep, and retreating other units.
    -- These are put in here together because we might want to weigh which one
    -- gets done first in the end.

    local move_data = fred_data.move_data
    local leader_objectives = fred_data.ops_data.objectives.leader
    --DBG.dbms(leader_objectives, false, 'leader_objectives')

    if move_data.my_units_MP[move_data.my_leader.id] then
        if leader_objectives.village then
            local action = {
                units = { move_data.my_leader },
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
                units = { move_data.my_leader },
                dsts = { { leader_objectives.keep[1], leader_objectives.keep[2] } },
                action_str = zone_cfg.action_str .. ' (move leader to keep)'
            }
            --DBG.dbms(action, false, 'action')

            leader_objectives.keep = nil

            return action
        end

        if leader_objectives.other then
            local action = {
                units = { move_data.my_leader },
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
        local action = FA.get_attack_action(cfg, fred_data)
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
                local ids = FGM.get_value(move_data.my_attack_map[1], move_data.my_leader[1], move_data.my_leader[2], 'ids') or {}
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
                        rating = 999999,
                        value_ratio = (2 - action.enemy_leader_die_chance) * fred_data.ops_data.behavior.orders.value_ratio
                    }
                    --DBG.dbms(xp_attack_cfg, false, 'xp_attack_cfg')

                    local xp_attack_action = FA.get_attack_action(xp_attack_cfg, fred_data)
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
                DBG.print_debug_time('eval', fred_data.turn_start_time, '  - hold evaluation (' .. cfg.action_str .. '): ' .. cfg.zone_id .. ' (' .. string.format('%.2f', cfg.rating) .. ')')
                action = AH.table_copy(fred_data.ops_data.stored_leader_protection[cfg.zone_id])
                fred_data.ops_data.stored_leader_protection[cfg.zone_id] = nil
            end
        else
            action = FH.get_hold_action(cfg, fred_data)
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
        DBG.print_debug_time('eval', fred_data.turn_start_time, '  - recruit evaluation: ' .. cfg.zone_id .. ' (' .. string.format('%.2f', cfg.rating) .. ')')
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
        local leader_id, leader_dst = move_data.my_leader.id
        for i_u,unit in ipairs(action.units) do
            if (unit.id == leader_id) then
                leader_dst = action.dsts[i_u]
            end
        end
        local from_keep = FGM.get_value(move_data.effective_reach_maps[leader_id], leader_dst[1], leader_dst[2], 'from_keep')
        --std_print(leader_id, leader_dst[1] .. ',' .. leader_dst[2] .. '  <--  ' .. from_keep[1] .. ',' .. from_keep[2])

        -- TODO: eventually we might switch this to Fred's own gamestate maps
        local avoid_map = LS.create()
        for _,dst in ipairs(action.dsts) do
            avoid_map:insert(dst[1], dst[2], true)
        end
        --DBG.dbms(avoid_map, false, 'avoid_map')

        local cfg = { outofway_penalty = -0.1 }
        prerecruit = fred_data.recruit:prerecruit_units(from_keep, avoid_map, move_data.my_units_can_move_away, cfg)
        --DBG.dbms(prerecruit, false, 'prerecruit')
    end

    -- Move leader to keep, if needed
    local leader = move_data.my_leader
    local recruit_loc = prerecruit.loc
    if (leader[1] ~= recruit_loc[1]) or (leader[2] ~= recruit_loc[2]) then
        --std_print('Need to move leader to keep first')
        local unit_proxy = COMP.get_unit(leader[1], leader[2])
        AHL.movepartial_outofway_stopunit(ai, unit_proxy, recruit_loc[1], recruit_loc[2])
    end

    for _,recruit_unit in ipairs(prerecruit.units) do
       --std_print('  ' .. recruit_unit.recruit_type .. ' at ' .. recruit_unit.recruit_hex[1] .. ',' .. recruit_unit.recruit_hex[2])
       local unit_in_way_proxy = COMP.get_unit(recruit_unit.recruit_hex[1], recruit_unit.recruit_hex[2])
       if unit_in_way_proxy then
           -- Generally, move out of way in direction of own leader
           -- TODO: change this
           local dx, dy  = leader[1] - recruit_unit.recruit_hex[1], leader[2] - recruit_unit.recruit_hex[2]
           local r = math.sqrt(dx * dx + dy * dy)
           if (r ~= 0) then dx, dy = dx / r, dy / r end

           --std_print('    unit_in_way: ' .. unit_in_way_proxy.id)
           AH.move_unit_out_of_way(ai, unit_in_way_proxy, { dx = dx, dy = dy })

           -- Make sure the unit really is gone now
           unit_in_way_proxy = COMP.get_unit(recruit_unit.recruit_hex[1], recruit_unit.recruit_hex[2])
           if unit_in_way_proxy then
               error('Unit was supposed to move out of the way for recruiting : ' .. unit_in_way_proxy.id .. ' at ' .. unit_in_way_proxy.x .. ',' .. unit_in_way_proxy.y)
           end
       end

       if (not unit_in_way_proxy) then
           AH.checked_recruit(ai, recruit_unit.recruit_type, recruit_unit.recruit_hex[1], recruit_unit.recruit_hex[2])
       end
   end

   fred_data.ops_data.objectives.leader.prerecruit = nil
end


local ca_zone_control = {}

function ca_zone_control:evaluation(cfg, fred_data, ai_debug)
    local function clear_fred_data()
        for k,_ in pairs(fred_data) do
            if (k ~= 'data') then -- the 'data' field needs to be preserved for the engine
                fred_data[k] = nil
            end
        end
    end

    turn_start_time = wesnoth.get_time_stamp() / 1000.

    -- This forces the turn data to be reset each call (use with care!)
    if DBG.show_debug('reset_turn') then
        clear_fred_data()
    end

    fred_data.turn_start_time = turn_start_time
    fred_data.previous_time = turn_start_time -- This is only used for timing debug output
    DBG.print_debug_time('eval', - fred_data.turn_start_time, 'start evaluating zone_control CA:')
    DBG.print_timing(fred_data, 0, '-- start evaluating zone_control CA:')

    local score_zone_control = 350000

    if (not fred_data.turn_data)
        or (fred_data.turn_data.turn_number ~= wesnoth.current.turn)
        or (fred_data.turn_data.side_number ~= wesnoth.current.side)
    then
        clear_fred_data() -- in principle this should not be necessary, but it's cheap, so keeping it as an insurance policy

        local ai = ai_debug or ai
        fred_data.recruit = {}
        local params = {
            high_level_fraction = 0,
            score_function = function () return 181000 end
        }
        wesnoth.require("~add-ons/AI-demos/lua/generic_recruit_engine.lua").init(ai, fred_data.recruit, params)

        -- These are the incremental data
        fred_data.caches = {
            defense_maps = {},
            movecost_maps = {},
            unit_types = {}
        }

        FDM.get_move_data(fred_data)
        FDT.set_turn_data(fred_data)

    else
        FDM.get_move_data(fred_data)
        FDT.update_turn_data(fred_data)
    end

    DBG.print_timing(fred_data, 0, '   call set_ops_data()')
    FOU.set_ops_data(fred_data)

    DBG.print_timing(fred_data, 0, '   call get_action_cfgs()')
    FOU.get_action_cfgs(fred_data)
    --DBG.dbms(fred_data.action_cfgs, false, 'fred_data.action_cfgs')

    local previous_action

    for i_c,cfg in ipairs(fred_data.action_cfgs) do
        --DBG.dbms(cfg, false, 'cfg')

        if previous_action then
            DBG.print_debug_time('eval', fred_data.turn_start_time, '  + previous action found (' .. string.format('%.2f', previous_action.score) .. ')')
            if (previous_action.score < cfg.rating) then
                DBG.print_debug_time('eval', fred_data.turn_start_time, '      current action has higher score (' .. string.format('%.2f', cfg.rating) .. ') -> evaluating current action')
            else
                fred_data.zone_action = previous_action
                DBG.print_debug_time('eval', fred_data.turn_start_time, '      current action has lower score (' .. string.format('%.2f', cfg.rating) .. ') -> executing previous action')
                DBG.print_debug_time('eval', fred_data.turn_start_time, '--> returning action ' .. previous_action.action_str .. ' (' .. previous_action.score .. ')')
                DBG.print_timing(fred_data, 0, '-- end evaluation zone_control CA [1]')
                return score_zone_control, previous_action
            end
        end

        -- Reserved actions have already been evaluated and checked for validity.
        -- We can skip changing units on the map, calling evaluation functions etc.
        if (cfg.action_type == 'reserved_action') then
            local action = {
                action_str = fred_data.ops_data.interaction_matrix.abbrevs[cfg.reserved_id],
                zone_id = cfg.zone_id,
                units = {},
                dsts = {}
            }

            DBG.print_debug_time('eval', fred_data.turn_start_time, '  - reserved action (' .. action.action_str .. ') evaluation: ' .. cfg.zone_id .. ' (' .. string.format('%.2f', cfg.rating) .. ')')

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

                DBG.print_debug_time('eval', fred_data.turn_start_time, '--> returning action ' .. action.action_str .. ' (' .. string.format('%.2f', cfg.rating) .. ')')
                DBG.print_timing(fred_data, 0, '-- end evaluation zone_control CA [2]')
                return score_zone_control, action
            end
        else
            -- Extract all AI units with MP left (for enemy path finding, counter attack placement etc.)
            local extracted_units = {}
            for id,loc in pairs(fred_data.move_data.my_units_MP) do
                local unit_proxy = COMP.get_unit(loc[1], loc[2])
                COMP.extract_unit(unit_proxy)
                table.insert(extracted_units, unit_proxy)  -- Not a proxy unit any more at this point
            end

            local zone_action = get_zone_action(cfg, fred_data)

            for _,extracted_unit in ipairs(extracted_units) do COMP.put_unit(extracted_unit) end

            if zone_action then
                DBG.print_debug_time('eval', fred_data.turn_start_time, '      --> action found')

                zone_action.zone_id = cfg.zone_id
                --DBG.dbms(zone_action, false, 'zone_action')

                -- If a score is returned as part of the action table, that means that it is lower than the
                -- max possible score, and it should be checked whether another action should be done first.
                -- Currently this only applies to holds vs. village grabbing, but it is set up
                -- so that it can be used more generally.
                if zone_action.score
                    and (zone_action.score < cfg.rating) and (zone_action.score > 0)
                then
                    DBG.print_debug_time('eval', fred_data.turn_start_time,
                        string.format('          score (%.2f) < config rating (%.2f) --> checking next action first', zone_action.score, cfg.rating)
                    )
                    if (not previous_action) or (previous_action.score < zone_action.score) then
                        previous_action = zone_action
                    end
                else
                    fred_data.zone_action = zone_action

                    DBG.print_debug_time('eval', fred_data.turn_start_time, '  --> returning action ' .. zone_action.action_str .. ' (' .. cfg.rating .. ')')
                    DBG.print_timing(fred_data, 0, '-- end evaluation zone_control CA [3]')
                    return score_zone_control, zone_action
                end
            end
        end
    end

    if previous_action then
        DBG.print_debug_time('eval', fred_data.turn_start_time, '  + previous action left at end of loop (' .. string.format('%.2f', previous_action.score) .. ')')
        fred_data.zone_action = previous_action
        DBG.print_debug_time('eval', fred_data.turn_start_time, '  --> returning action ' .. previous_action.action_str .. ' (' .. previous_action.score .. ')')
        DBG.print_timing(fred_data, 0, '-- end evaluation zone_control CA [4]')
        return score_zone_control, previous_action
    end

    DBG.print_debug_time('eval', fred_data.turn_start_time, '  --> done with all cfgs: no action found')
    DBG.print_timing(fred_data, 0, '-- end evaluation zone_control CA [5]')

    -- This is mostly done so that there is no chance of corruption of savefiles
    clear_fred_data()
    return 0
end

function ca_zone_control:execution(cfg, fred_data, ai_debug)
    local ai = ai_debug or ai

    local action = fred_data.zone_action.zone_id .. ': ' .. fred_data.zone_action.action_str
    --DBG.dbms(fred_data.zone_action, false, 'fred_data.zone_action')


    -- If recruiting is set, we just do that, nothing else needs to be checked
    if (fred_data.zone_action.type == 'recruit') then
        DBG.print_debug_time('exec', fred_data.turn_start_time, 'exec: ' .. action)
        do_recruit(fred_data, ai)
        return
    end


    local enemy_proxy
    if fred_data.zone_action.enemy then
        enemy_proxy = COMP.get_units { id = next(fred_data.zone_action.enemy) }[1]
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
            local combo_outcome = FAU.attack_combo_eval(combo, fred_data.zone_action.enemy, cfg_attack, fred_data)
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
            local max_rating = - math.huge
            for ind,unit in ipairs(fred_data.zone_action.units) do
                local unit_info = fred_data.move_data.unit_infos[unit.id]

                local att_outcome, def_outcome = FAU.attack_outcome(
                    attacker_copies[ind], enemy_proxy,
                    fred_data.zone_action.dsts[ind],
                    attacker_infos[ind], defender_info,
                    fred_data
                )
                local rating_table, att_damage, def_damage =
                    FAU.attack_rating({ unit_info }, defender_info, { fred_data.zone_action.dsts[ind] }, { att_outcome }, def_outcome, cfg_attack, fred_data)

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
                            -- Want most advanced and least valuable unit to go last
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

                if (rating > max_rating) then
                    max_rating, next_unit_ind = rating, ind
                end
            end
            --DBG.print_ts_delta(fred_data.turn_start_time, 'Best unit to go next:', fred_data.zone_action.units[next_unit_ind].id, max_rating, next_unit_ind)
        end
        --DBG.print_ts_delta(fred_data.turn_start_time, 'next_unit_ind', next_unit_ind)

        local unit_proxy = COMP.get_units { id = fred_data.zone_action.units[next_unit_ind].id }[1]
        if (not unit_proxy) then
            fred_data.zone_action = nil
            return
        end


        local dst = fred_data.zone_action.dsts[next_unit_ind]

        -- If this is the leader (and has MP left), recruit first
        local leader_objectives = fred_data.ops_data.objectives.leader
        if unit_proxy.canrecruit and fred_data.move_data.my_units_MP[unit_proxy.id]
            and leader_objectives.prerecruit and leader_objectives.prerecruit.units and leader_objectives.prerecruit.units[1]
        then
            DBG.print_debug_time('exec', fred_data.turn_start_time, 'exec: ' .. action .. ' (leader used -> recruit first)')
            do_recruit(fred_data, ai, fred_data.zone_action)
            gamestate_changed = true

            -- We also check here separately whether the leader can still get to dst.
            -- This is also caught below, but the ops analysis should never let this
            -- happen, so we want to know about it.
            local _,cost = wesnoth.find_path(unit_proxy, dst[1], dst[2])
            if (cost > unit_proxy.moves) then
                error('Leader was supposed to move to ' .. dst[1] .. ',' .. dst[2] .. ' after recruiting, but this is not possible. Check operations analysis.')
            end
        end

        DBG.print_debug_time('exec', fred_data.turn_start_time, 'exec: ' .. action .. ' ' .. unit_proxy.id)

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
            local _,cost = wesnoth.find_path(unit_proxy, dst[1], dst[2])
            if (cost > unit_proxy.moves) then
                fred_data.zone_action = nil
                return
            end

            -- It is also possible that a unit moving out of the way for a previous
            -- move of this combination is now in the way again and cannot move any more.
            -- We also need to stop execution in that case.
            -- Just checking for moves > 0 is not always sufficient.
            local unit_in_way_proxy
            if (unit_proxy.x ~= dst[1]) or (unit_proxy.y ~= dst[2]) then
                unit_in_way_proxy = COMP.get_unit(dst[1], dst[2])
            end
            if unit_in_way_proxy then
                uiw_reach = wesnoth.find_reach(unit_in_way_proxy)

                -- Check whether the unit to move out of the way has an unoccupied hex to move to.
                local unit_blocked = true
                for _,uiw_loc in ipairs(uiw_reach) do
                    -- Unit in the way of the unit in the way
                    if (not COMP.get_unit(uiw_loc[1], uiw_loc[2])) then
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
        local leader_loc = fred_data.move_data.my_leader
        local dx, dy  = leader_loc[1] - dst[1], leader_loc[2] - dst[2]
        local r = math.sqrt(dx * dx + dy * dy)
        if (r ~= 0) then dx, dy = dx / r, dy / r end

        -- However, if the unit in the way is part of the move combo, it needs to move in the
        -- direction of its own goal, otherwise it might not be able to reach it later
        local unit_in_way_proxy
        if (unit_proxy.x ~= dst[1]) or (unit_proxy.y ~= dst[2]) then
            unit_in_way_proxy = COMP.get_unit(dst[1], dst[2])
        end

        if unit_in_way_proxy then
            if unit_in_way_proxy.canrecruit then
                local leader_objectives = fred_data.ops_data.objectives.leader
                dx = leader_objectives.final[1] - unit_in_way_proxy.x
                dy = leader_objectives.final[2] - unit_in_way_proxy.y
                if (dx == 0) and (dy == 0) then -- this can happen if leader is on leader goal hex
                    -- In this case, as a last resort, move away from the enemy leader
                    dx = unit_in_way_proxy.x - leader_loc[1]
                    dy = unit_in_way_proxy.y - leader_loc[2]
                end
                local r = math.sqrt(dx * dx + dy * dy)
                if (r ~= 0) then dx, dy = dx / r, dy / r end
            else
                for i_u,u in ipairs(fred_data.zone_action.units) do
                    if (u.id == unit_in_way_proxy.id) then
                        --std_print('  unit is part of the combo', unit_in_way_proxy.id, unit_in_way_proxy.x, unit_in_way_proxy.y)

                        local uiw_dst = fred_data.zone_action.dsts[i_u]
                        local path, _ = wesnoth.find_path(unit_in_way_proxy, uiw_dst[1], uiw_dst[2])

                        -- If we can find an unoccupied hex along the path, move the
                        -- unit_in_way_proxy there, in order to maximize the chances of it
                        -- making it to its goal. However, do not move all the way and
                        -- do partial move only, in case something changes as result of
                        -- the original unit's action.
                        local moveto
                        for i = 2,#path do
                            if (not COMP.get_unit(path[i][1], path[i][2])) then
                                moveto = { path[i][1], path[i][2] }
                                break
                            end
                        end

                        if moveto then
                            --std_print('    ' .. unit_in_way_proxy.id .. ': moving out of way to:', moveto[1], moveto[2])
                            AH.checked_move(ai, unit_in_way_proxy, moveto[1], moveto[2])

                            -- If this got to its final destination, attack with this unit first, otherwise it might be stranded
                            -- TODO: only if other units have chance to kill?
                            if (moveto[1] == uiw_dst[1]) and (moveto[2] == uiw_dst[2]) then
                                --std_print('      going to final destination')
                                dst = uiw_dst
                                next_unit_ind = i_u
                                unit_proxy = unit_in_way_proxy
                            end
                        else
                            if (not path) or (not path[1]) or (not path[2]) then
                                std_print('Trying to identify path table error !!!!!!!!')
                                std_print(i_u, u.id, unit_in_way_proxy.id)
                                std_print(unit_proxy.id, unit_proxy.x, unit_proxy.y)
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

        if unit_in_way_proxy and (dx == 0) and (dy == 0) then
            error(unit_in_way_proxy.id .. " to move out of way with dx = dy = 0")
        end

        if fred_data.zone_action.partial_move then
            AHL.movepartial_outofway_stopunit(ai, unit_proxy, dst[1], dst[2], { dx = dx, dy = dy })
            if (unit_proxy.moves == 0) then
                fred_data.ops_data.used_units[unit_proxy.id] = fred_data.zone_action.zone_id
            end
        else
            AH.movefull_outofway_stopunit(ai, unit_proxy, dst[1], dst[2], { dx = dx, dy = dy })
            fred_data.ops_data.used_units[unit_proxy.id] = fred_data.zone_action.zone_id
        end
        gamestate_changed = true


        -- Remove these from the table
        table.remove(fred_data.zone_action.units, next_unit_ind)
        table.remove(fred_data.zone_action.dsts, next_unit_ind)

        -- Then do the attack, if there is one to do
        if enemy_proxy and (wesnoth.map.distance_between(unit_proxy.x, unit_proxy.y, enemy_proxy.x, enemy_proxy.y) == 1) then
            local weapon = fred_data.zone_action.weapons[next_unit_ind]
            table.remove(fred_data.zone_action.weapons, next_unit_ind)

            AH.checked_attack(ai, unit_proxy, enemy_proxy, weapon)

            -- If enemy got killed, we need to stop here
            if (not enemy_proxy.valid) then
                fred_data.zone_action.units = nil
            end

            -- Need to reset the enemy information if there are more attacks in this combo
            if fred_data.zone_action.units and fred_data.zone_action.units[1] then
                fred_data.move_data.unit_copies[enemy_proxy.id] = COMP.copy_unit(enemy_proxy)
                fred_data.move_data.unit_infos[enemy_proxy.id] = FU.single_unit_info(enemy_proxy, fred_data.caches.unit_types)
            end
        end

        if (not unit_proxy) or (not unit_proxy.valid) then
            fred_data.zone_action.units = nil
        end
    end

    fred_data.zone_action = nil
end

return ca_zone_control
