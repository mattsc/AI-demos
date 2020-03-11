-- Set up (and reset) hypothetical situations on the map that can be used for
-- analyses of ZoC, counter attacks etc.

local H = wesnoth.require "helper"
local FGM = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_map.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local FAU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack_utils.lua"
local FVS = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_virtual_state.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"
local COMP = wesnoth.require "~/add-ons/AI-demos/lua/compatibility.lua"

local fred_status = {}

function fred_status.is_significant_threat(unit_info, av_total_loss, max_total_loss)
    -- Currently this is only set up for the leader.
    -- TODO: generalize?
    --
    -- We only consider these leader threats, if they either
    --   - maximum damage reduces current HP by more than 75%
    --   - average damage is more than 50% of max HP
    -- Otherwise we assume the leader can deal with them alone

    local significant_threat = false
    if (max_total_loss >= unit_info.hitpoints * 0.75)
        or (av_total_loss >= unit_info.max_hitpoints * 0.5)
    then
        significant_threat = true
    end

    return significant_threat
end

function fred_status.unit_exposure(pos_counter_rating, neg_counter_rating)
    -- @pos_counter_rating needs to be a positive number (that is, as returned by
    --   and from the point of view of the counter attack)
    -- Equivalently, @neg_counter_rating needs to be negative (also as returned by the counter attack eval)
    -- Just done to standardize this
    local exposure = pos_counter_rating + neg_counter_rating / 10
    if (exposure < 0) then exposure = 0 end
    return exposure
end

function fred_status.check_exposures(objectives, combo, virtual_reach_maps, cfg, fred_data)
    -- The virtual state needs to be set up for this, but virtual_reach_maps are
    -- calculated here unless passed as a parameter.
    -- Potential TODO: skip evaluation of units/hexes that have already been shown
    -- to be protected. However, no expensive analysis is done for these anyway,
    -- they are sorted out both for reach_maps and counter attacks, so the overhead
    -- is likely small. Eventually can do some timing tests on this.
    --
    -- @cfg: optional parameters
    --   zone_id: if set, use only protect units/villages in that zone
    --   exclude_leader: if true, leader exposure is not checked and set to zero; this is
    --     to be used when the leader is part of the action to be checked

    local move_data = fred_data.move_data
    local zone_id = cfg and cfg.zone_id
    local exclude_leader = cfg and cfg.exclude_leader

    local units = {}
    for zid,protect_objectives in pairs(objectives.protect.zones) do
        if (not zone_id) or (zone_id == zid) then
            for _,unit in ipairs(protect_objectives.units) do
                units[unit.id] = { unit.x, unit.y }
            end
        end
    end
    --DBG.dbms(units, false, 'units')

    local villages = {}
    for zid,protect_objectives in pairs(objectives.protect.zones) do
        if (not zone_id) or (zone_id == zid) then
            for _,village in ipairs(protect_objectives.villages or {}) do
                villages[village.x * 1000 + village.y] = {
                    loc = { village.x, village.y },
                    exposure = village.raw_benefit
                }
            end
        end
    end
    --DBG.dbms(villages, false, 'villages')

    if (not virtual_reach_maps) then
        local to_unit_locs, to_locs = {}, {}
        if (not exclude_leader) then
            table.insert(to_unit_locs, objectives.leader.final)
        end
        for x,y,_ in FGM.iter(move_data.close_castles_map[wesnoth.current.side]) do
            table.insert(to_locs, { x, y })
        end
        for id,loc in pairs(units) do
            table.insert(to_unit_locs, loc)
        end
        for xy,village in pairs(villages) do
            table.insert(to_locs, village.loc)
        end
        --DBG.dbms(to_locs, false, 'to_locs')
        --DBG.dbms(to_unit_locs, false, 'to_unit_locs')

        virtual_reach_maps = FVS.virtual_reach_maps(move_data.enemies, to_unit_locs, to_locs, move_data)
        --DBG.dbms(virtual_reach_maps, false, 'virtual_reach_maps')
    end

    local cfg_attack = { value_ratio = fred_data.ops_data.behavior.orders.value_ratio }

    local leader_exposure, enemy_power, is_protected, is_significant_threat = 0, 0, true, false
    if (not exclude_leader) then
        local leader = move_data.my_leader
        local leader_target = {}
        leader_target[leader.id] = objectives.leader.final
        local counter_outcomes, _, all_attackers = FAU.calc_counter_attack(
            leader_target, nil, nil, nil, virtual_reach_maps, cfg_attack, move_data, fred_data.move_cache
        )
        --DBG.dbms(counter_outcomes)
        --DBG.dbms(all_attackers)

        local pos_rating, neg_rating  = 0, 0
        if counter_outcomes then
            is_protected = false
            pos_rating = counter_outcomes.rating_table.pos_rating
            neg_rating = counter_outcomes.rating_table.neg_rating
            --std_print('pos_rating, neg_rating', pos_rating, neg_rating)
            local leader_info = move_data.unit_infos[leader.id]
            is_significant_threat = fred_status.is_significant_threat(
                leader_info,
                leader_info.hitpoints - counter_outcomes.def_outcome.average_hp,
                leader_info.hitpoints - counter_outcomes.def_outcome.min_hp
            )
            leader_exposure = fred_status.unit_exposure(pos_rating, neg_rating)
            --std_print('leader_exposure', leader_exposure)
            for enemy_id,_ in pairs(all_attackers) do
                -- TODO: not 100% sure yet whether we should use only the zone enemies,
                --   or all enemies, or both for different purposes
                --if (not zone_id)
                --    or (not fred_data.ops_data.assigned_enemies[zone_id])
                --    or (fred_data.ops_data.assigned_enemies[zone_id][enemy_id])
                --then
                    enemy_power = enemy_power + FU.unit_current_power(move_data.unit_infos[enemy_id])
                --end
            end
        end
        --std_print('ratings: ' .. pos_rating, neg_rating, is_significant_threat)
    end

    local status = { leader = {
        exposure = leader_exposure,
        is_protected = is_protected,
        is_significant_threat = is_significant_threat,
        enemy_power = enemy_power
    } }


    local n_castles_threatened, castle_hexes = 0, {}
    for x,y,_ in FGM.iter(move_data.close_castles_map[wesnoth.current.side]) do
        --std_print('castle: ', x .. ',' .. y)
        for enemy_id,_ in pairs(move_data.enemies) do
            --DBG.show_fgumap_with_message(virtual_reach_maps[enemy_id], 'moves_left', 'virtual_reach_map', move_data.unit_copies[enemy_id])
            -- enemies with 0 HP are not in virtual_reach_maps
            if virtual_reach_maps[enemy_id] and FGM.get_value(virtual_reach_maps[enemy_id], x, y, 'moves_left') then
                n_castles_threatened = n_castles_threatened + 1
                table.insert(castle_hexes, { x, y })
                break
            end
        end
    end
    --std_print('n_castles_threatened: ' .. n_castles_threatened)
    status.castles = {
        n_threatened = n_castles_threatened ,
        exposure = 3 * math.sqrt(n_castles_threatened),
        locs = castle_hexes
    }


    status.villages = {}
    for xy,village in pairs(villages) do
        --std_print('  check protection of village: ' .. village.loc[1] .. ',' .. village.loc[2])
        local is_protected, exposure = true, 0
        for enemy_id,_ in pairs(move_data.enemies) do
            local moves_left = virtual_reach_maps[enemy_id] and FGM.get_value(virtual_reach_maps[enemy_id], village.loc[1], village.loc[2], 'moves_left')
            if moves_left then
                --std_print('  can reach this: ' .. enemy_id, moves_left)
                is_protected = false
                exposure = village.exposure
                break
            end
        end
        --std_print('  is_protected: ', is_protected)
        status.villages[xy] = {
            is_protected = is_protected,
            exposure = exposure
        }
    end


    status.units = {}
    for id,loc in pairs(units) do
        local target = {}
        target[id] = loc
        local counter_outcomes = FAU.calc_counter_attack(
            target, nil, nil, nil, virtual_reach_maps, cfg_attack, move_data, fred_data.move_cache
        )
        local exposure, is_protected = 0, true
        if counter_outcomes then
            --DBG.dbms(counter_outcomes.rating_table, false, 'counter_outcomes.rating_table')
            is_protected = false
            exposure = fred_status.unit_exposure(counter_outcomes.rating_table.pos_rating, counter_outcomes.rating_table.neg_rating)
        end
        status.units[id] = {
            exposure = exposure,
            is_protected = is_protected
        }
    end


    -- Add a terrain bonus if the combo hexes have better terrain defense for the enemies
    -- than those adjacent to the combo hexes that the enemies can reach with the combo in place
    -- Potential TODOs:
    --  - The value of status.terrain does not mean anything. Currently it is only used to
    --    determine whether good terrain is taken away from the enemies, so it's essentially used as a boolean
    --  - We add up all terrain (dis)advantages for all enemy units on the best adjacent hexes they
    --    can get to, even if there are more enemies than hexes
    --  - We might want to add something more sophisticated, indicating how useful the protected
    --    terrain is or something. It's also only a single-hex (plus adjacents) analysis for now.
    --    Might want to consider all hexes not reachable for the enemies any more.
    local unit_values = {}
    status.terrain = 0
    if combo then
        for src,dst in pairs(combo) do
            local dst_x, dst_y =  math.floor(dst / 1000), dst % 1000
            --std_print(dst_x, dst_y)
            for enemy_id,_ in pairs(move_data.enemies) do
                --std_print(enemy_id)
                if FGM.get_value(move_data.reach_maps[enemy_id], dst_x, dst_y, 'moves_left') then
                    local defense = 100 - COMP.unit_defense(move_data.unit_copies[enemy_id], wesnoth.get_terrain(dst_x, dst_y))
                    --std_print('  ' .. dst_x .. ',' .. dst_y .. ': ' .. enemy_id , defense)

                    local max_adj_defense = - math.huge
                    for xa,ya in H.adjacent_tiles(dst_x, dst_y) do
                        if FGM.get_value(virtual_reach_maps[enemy_id], xa, ya, 'moves_left') then
                            local adj_defense = 100 - COMP.unit_defense(move_data.unit_copies[enemy_id], wesnoth.get_terrain(xa, ya))
                            --std_print('    can reach adj: ' .. xa .. ',' .. ya, adj_defense)
                            if (adj_defense > max_adj_defense) then
                                max_adj_defense = adj_defense
                            end
                        end
                    end
                    --std_print('  defense, adj_defense: ', defense, max_adj_defense)

                    if (defense > max_adj_defense) then
                        local unit_value = unit_values[enemy_id]
                        if not unit_value then
                            unit_value = FU.unit_value(move_data.unit_infos[enemy_id], move_data.unit_types_cache)
                            --std_print('  value: ' .. enemy_id, unit_value)
                            unit_values[enemy_id] = unit_value
                        end

                        local terrain_bonus = (defense - max_adj_defense) / 100 * unit_value
                        status.terrain = status.terrain + terrain_bonus
                    end
                end
            end
        end
    end
    --std_print('terrain advantage: ' .. status.terrain)

    return status
end

return fred_status
