local AH = wesnoth.require "ai/lua/ai_helper.lua"
local AHL = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper_local.lua"
local LS = wesnoth.require "location_set"
local FA = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack.lua"
local FADV = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_advance.lua"
local FAU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack_utils.lua"
local FCFG = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_config.lua"
local FDM = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_data_move.lua"
local FDT = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_data_turn.lua"
local FGM = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_map.lua"
local FH = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_hold.lua"
local FOA = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_ops_analysis.lua"
local FR = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_retreat.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"
local COMP = wesnoth.require "~/add-ons/AI-demos/lua/compatibility.lua"

local function get_zone_action(cfg, fred_data)
    if (cfg.action_type == 'retreat') then
        local action = FR.get_retreat_action(cfg, fred_data)
        if action then
            return action
        end
    end

    if (cfg.action_type == 'attack') then
        local action = FA.get_attack_action(cfg, fred_data)
        if action then
            local milk_xp_die_chance_limit = FCFG.get_cfg_parm('milk_xp_die_chance_limit')
            if (milk_xp_die_chance_limit < 0) then milk_xp_die_chance_limit = 0 end

            if (action.enemy_leader_die_chance > milk_xp_die_chance_limit) then
                local move_data = fred_data.move_data

                -- XP milking attackers are all units that cannot attack the enemy leader
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

                    local xp_attack_action = FA.get_attack_action(xp_attack_cfg, fred_data)
                    if xp_attack_action then
                        action = xp_attack_action
                    end
                end
            end

            return action
        end
    end

    if (cfg.action_type == 'hold') then
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
            -- If evaluate_only flag is said, we store the action in ops_data.stored_leader_protection
            if cfg.evaluate_only then
                local leader_status = fred_data.ops_data.status.leader

                -- The 0.1 is there to protect against rounding errors and minor protection
                -- improvements that might not be worth it.
                if (leader_status.best_protection[cfg.zone_id].exposure < leader_status.exposure - 0.1) then
                    fred_data.ops_data.stored_leader_protection[cfg.zone_id] = action
                end
            else
                return action
            end
        end
    end

    if (cfg.action_type == 'advance') then
        local action = FADV.get_advance_action(cfg, fred_data)
        if action then
            return action
        end
    end

    if (cfg.action_type == 'recruit') then
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
end


local function do_recruit(fred_data, ai, action)
    local move_data = fred_data.move_data
    local leader = move_data.my_leader
    local prerecruit = fred_data.ops_data.objectives.leader.prerecruit

    -- This is just a safeguard, to make sure nothing went wrong
    if (not prerecruit) or (not prerecruit.units) or (not prerecruit.units[1]) then
        DBG.dbms(prerecruit, false, 'prerecruit')
        error("Leader was instructed to recruit, but no units to be recruited are set.")
    end

    -- If @action is passed, this means that recruiting is done because the leader is needed
    -- in an action. In this case, we need to re-evaluate recruiting, because the leader
    -- might not be able to reach its hex from the pre-evaluated keep, and because some
    -- of the pre-evaluated recruit hexes might be used in the action.
    if action then
        local leader_dst
        for i_u,unit in ipairs(action.units) do
            if (unit.id == leader.id) then
                leader_dst = action.dsts[i_u]
                break
            end
        end
        local from_keep = FGM.get_value(move_data.effective_reach_maps[leader.id], leader_dst[1], leader_dst[2], 'from_keep')
        --std_print(leader.id, leader_dst[1] .. ',' .. leader_dst[2] .. '  <--  ' .. from_keep[1] .. ',' .. from_keep[2])

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
    local recruit_loc = prerecruit.loc
    if (leader[1] ~= recruit_loc[1]) or (leader[2] ~= recruit_loc[2]) then
        --std_print('Need to move leader to keep first')
        local leader_proxy = COMP.get_unit(leader[1], leader[2])
        AHL.movepartial_outofway_stopunit(ai, leader_proxy, recruit_loc[1], recruit_loc[2])
    end

    for _,recruit_unit in ipairs(prerecruit.units) do
       --std_print('  ' .. recruit_unit.recruit_type .. ' at ' .. recruit_unit.recruit_hex[1] .. ',' .. recruit_unit.recruit_hex[2])
       local unit_in_way_proxy = COMP.get_unit(recruit_unit.recruit_hex[1], recruit_unit.recruit_hex[2])
       if unit_in_way_proxy then
           local dx, dy  = leader[1] - recruit_unit.recruit_hex[1], leader[2] - recruit_unit.recruit_hex[2]
           local r = math.sqrt(dx * dx + dy * dy)
           if (r ~= 0) then dx, dy = dx / r, dy / r end

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

----- End local functions -----


local ca_fred = {}

function ca_fred:evaluation(cfg, fred_data, ai_debug)
    local function clear_fred_data()
        for k,_ in pairs(fred_data) do
            if (k ~= 'data') then -- the 'data' field needs to be preserved for the engine
                fred_data[k] = nil
            end
        end
    end

    local turn_start_time = wesnoth.get_time_stamp() / 1000.
    local score_fred = 350000

    -- This forces the turn data to be reset each call (use with care!)
    if DBG.show_debug('reset_turn') then
        clear_fred_data()
    end

    fred_data.turn_start_time = turn_start_time
    fred_data.previous_time = turn_start_time -- This is only used for timing debug output
    DBG.print_debug_time('eval', - fred_data.turn_start_time, 'start evaluating fred CA:')
    DBG.print_timing(fred_data, 0, '-- start evaluating fred CA:')

    if (not fred_data.turn_data)
        or (fred_data.turn_data.turn_number ~= wesnoth.current.turn)
        or (fred_data.turn_data.side_number ~= wesnoth.current.side)
    then
        local ai = ai_debug or ai
        fred_data.recruit = {}
        local params = {
            high_level_fraction = 0,
            score_function = function () return 181000 end
        }
        wesnoth.require("~add-ons/AI-demos/lua/generic_recruit_engine.lua").init(ai, fred_data.recruit, params)

        -- These are most of the incremental cache data
        -- fred_data.caches.attacks is reset each move, which is done inside fred_data_move.lua
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
    FOA.set_ops_data(fred_data)

    DBG.print_timing(fred_data, 0, '   call get_action_cfgs()')
    FOA.get_action_cfgs(fred_data)
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
                DBG.print_timing(fred_data, 0, '-- end evaluation fred CA [1]')
                return score_fred, previous_action
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
                DBG.print_timing(fred_data, 0, '-- end evaluation fred CA [2]')
                return score_fred, action
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
                    DBG.print_timing(fred_data, 0, '-- end evaluation fred CA [3]')
                    return score_fred, zone_action
                end
            end
        end
    end

    if previous_action then
        DBG.print_debug_time('eval', fred_data.turn_start_time, '  + previous action left at end of loop (' .. string.format('%.2f', previous_action.score) .. ')')
        fred_data.zone_action = previous_action
        DBG.print_debug_time('eval', fred_data.turn_start_time, '  --> returning action ' .. previous_action.action_str .. ' (' .. previous_action.score .. ')')
        DBG.print_timing(fred_data, 0, '-- end evaluation fred CA [4]')
        return score_fred, previous_action
    end

    DBG.print_debug_time('eval', fred_data.turn_start_time, '  --> done with all cfgs: no action found')
    DBG.print_timing(fred_data, 0, '-- end evaluation fred CA [5]')

    -- Clearing fred_data is also done so that there is no chance of corruption of savefiles
    clear_fred_data()
    return 0
end


function ca_fred:execution(cfg, fred_data, ai_debug)
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

            local enemy_level = defender_info.level
            if (enemy_level == 0) then enemy_level = 0.5 end

            -- Check if any unit has a chance to level up
            local levelups = { anybody = false }
            for ind,attacker_info in ipairs(attacker_infos) do
                local XP_diff = attacker_info.max_experience - attacker_info.experience

                local levelup_possible, levelup_certain = false, false
                if (XP_diff <= enemy_level) then
                    levelup_certain = true
                    levelups.anybody = true
                elseif (XP_diff <= enemy_level * 8) then
                    levelup_possible = true
                    levelups.anybody = true
                end
                --std_print('  ' .. attacker_info.id, XP_diff, levelup_possible, levelup_certain)

                levelups[ind] = { certain = levelup_certain, possible = levelup_possible}
            end
            --DBG.dbms(levelups, false, 'levelups')

            --DBG.print_ts_delta(fred_data.turn_start_time, 'Reordering units for attack')
            local max_rating = - math.huge
            for ind,attacker_info in ipairs(attacker_infos) do
                local att_outcome, def_outcome = FAU.attack_outcome(
                    attacker_copies[ind], enemy_proxy,
                    fred_data.zone_action.dsts[ind],
                    attacker_infos[ind], defender_info,
                    fred_data
                )
                local rating_table, att_damage, def_damage =
                    FAU.attack_rating({ attacker_info }, defender_info, { fred_data.zone_action.dsts[ind] }, { att_outcome }, def_outcome, cfg_attack, fred_data)

                -- The base rating is the individual attack rating
                local rating = rating_table.rating
                --std_print('  base_rating ' .. attacker_info.id, rating)

                -- If the target can die, we might want to reorder, in order
                -- to maximize the chance to level up and give the most XP
                -- to the most appropriate unit
                if (combo_outcome.def_outcome.hp_chance[0] > 0) then
                    local XP_diff = attacker_info.max_experience - attacker_info.experience

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
                        local xp_fraction = attacker_info.experience / (attacker_info.max_experience - 8)
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

return ca_fred
