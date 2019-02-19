-- Set up (and reset) hypothetical situations on the map that can be used for
-- analyses of ZoC, counter attacks etc.

local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local FAU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack_utils.lua"
local FVS = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_virtual_state.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

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

function fred_status.unit_exposure(own_rating, enemy_rating)
    -- @own_rating should be counted as positive contribution (that is, as returned by counter attacks)
    -- opposite for @enemy_rating
    -- Just done to standardize this
    local exposure = own_rating + enemy_rating / 10
    if (exposure < 0) then exposure = 0 end
    return exposure
end

function fred_status.check_exposures(objectives, cfg, fred_data)
    -- The virtual state needs to be set up for this, but virtual_reach_maps are calculated here

--- xxx leader, castles, units, villages

    local move_data = fred_data.move_data
    local zone_id = cfg and cfg.zone_id

    local units = {}
    for zid,protect_objectives in pairs(objectives.protect.zones) do
        for _,unit in ipairs(protect_objectives.units) do
            if (not zone_id) or (zone_id == zid) then
                units[unit.id] = { unit.x, unit.y }
            end
        end
    end
    --DBG.dbms(units, false, 'units')

    local villages = {}
    for zid,protect_objectives in pairs(objectives.protect.zones) do
        for _,village in ipairs(protect_objectives.villages) do
            if (not zone_id) or (zone_id == zid) then
                villages[village.x * 1000 + village.y] = {
                    loc = { village.x, village.y },
                    exposure = village.raw_benefit
                }
            end
        end
    end
    --DBG.dbms(villages, false, 'villages')

    local to_unit_locs, to_locs = {}, {}
    table.insert(to_unit_locs, objectives.leader.final)
    for x,y,_ in FU.fgumap_iter(move_data.reachable_castles_map[wesnoth.current.side]) do
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

    local virtual_reach_maps = FVS.virtual_reach_maps(move_data.enemies, to_unit_locs, to_locs, move_data)
    --DBG.dbms(virtual_reach_maps, false, 'virtual_reach_maps')

    local cfg_attack = { value_ratio = fred_data.turn_data.behavior.orders.value_ratio }
    local leader = move_data.leaders[wesnoth.current.side]
    local leader_target = {}
    leader_target[leader.id] = objectives.leader.final
    local counter_outcomes = FAU.calc_counter_attack(
        leader_target, nil, nil, nil, virtual_reach_maps, false, cfg_attack, move_data, fred_data.move_cache
    )
    --DBG.dbms(counter_outcomes)

    local defender_rating, attacker_rating, leader_exposure = 0, 0, 0
    local is_protected, is_significant_threat = true, false
    if counter_outcomes then
        is_protected = false
        defender_rating = counter_outcomes.rating_table.defender_rating
        attacker_rating = counter_outcomes.rating_table.attacker_rating
        local leader_info = move_data.unit_infos[leader.id]
        is_significant_threat = fred_status.is_significant_threat(
            leader_info,
            leader_info.hitpoints - counter_outcomes.def_outcome.average_hp,
            leader_info.hitpoints - counter_outcomes.def_outcome.min_hp
        )
        leader_exposure = fred_status.unit_exposure(defender_rating, attacker_rating)
    end
    --std_print('ratings: ' .. defender_rating, attacker_rating, is_significant_threat)

    local status = { leader = {
        exposure = leader_exposure,
        is_protected = is_protected,
        is_significant_threat = is_significant_threat
    } }


    local n_castles_threatened = 0
    for x,y,_ in FU.fgumap_iter(move_data.reachable_castles_map[wesnoth.current.side]) do
        --std_print('castle: ', x .. ',' .. y)
        for enemy_id,_ in pairs(move_data.enemies) do
            --DBG.show_fgumap_with_message(virtual_reach_maps[enemy_id], 'moves_left', 'virtual_reach_map', move_data.unit_copies[enemy_id])
            if FU.get_fgumap_value(virtual_reach_maps[enemy_id], x, y, 'moves_left') then
                n_castles_threatened = n_castles_threatened + 1
                break
            end
        end
    end
    --std_print('n_castles_threatened: ' .. n_castles_threatened)
    status.castles = {
        n_threatened = n_castles_threatened ,
        exposure = 3 * math.sqrt(n_castles_threatened)
    }


    status.villages = {}
    for xy,village in pairs(villages) do
        --std_print('  check protection of village: ' .. village.loc[1] .. ',' .. village.loc[2])
        local is_protected, exposure = true, 0
        for enemy_id,_ in pairs(move_data.enemies) do
            local moves_left = FU.get_fgumap_value(virtual_reach_maps[enemy_id], village.loc[1], village.loc[2], 'moves_left')
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
            target, nil, nil, nil, virtual_reach_maps, false, cfg_attack, move_data, fred_data.move_cache
        )
        local exposure, is_protected = 0, true
        if counter_outcomes then
            --DBG.dbms(counter_outcomes.rating_table, false, 'counter_outcomes.rating_table')
            is_protected = false
            exposure = fred_status.unit_exposure(counter_outcomes.rating_table.defender_rating, counter_outcomes.rating_table.attacker_rating)
        end
        status.units[id] = {
            exposure = exposure,
            is_protected = is_protected
        }
    end

    return status
end

return fred_status