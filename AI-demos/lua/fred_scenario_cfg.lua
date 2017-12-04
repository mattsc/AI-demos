-- These collect all the scenario/map specific information
-- TODO: generalize so that it can be used on maps other than Freelands

local fred_scenario_cfg = {}

function fred_scenario_cfg.get_side_cfgs()
    local cfgs = {
        { start_hex = { 18, 4 } },
        { start_hex = { 20, 20 } }
    }

    return cfgs
end

function fred_scenario_cfg.get_attack_test_locs()
    -- TODO: this is really just a placeholder for now until I know whether this works
    -- It's easy to have this found automatically
    local locs = {
        attacker_loc = { 28, 13 },
        defender_loc = { 28, 14 }
    }

    return locs
end

function fred_scenario_cfg.get_raw_cfgs(zone_id)
    local cfg_leader_threat = {
        zone_id = 'leader_threat',
        ops_slf = {},
    }

    local cfg_west = {
        zone_id = 'west',
        ops_slf = { x = '1-15,1-14,1-21', y = '1-12,13-16,17-24' },
        center_hexes = { { 10, 13 } },
        zone_weight = 1,
    }

    local cfg_center = {
        zone_id = 'center',
        center_hexes = { { 18, 12 }, { 20, 12 } },
        ops_slf = { x = '16-20,16-22,16-23,15-22,15-23', y = '6-7,8-9,10-12,13-17,18-24' },
        zone_weight = 0.5,
    }

    local cfg_east = {
        zone_id = 'east',
        center_hexes = { { 28, 13 } },
        ops_slf = { x = '21-34,23-34,24-34,23-34,17-34', y = '1-7,8-9,10-12,13-17,18-24' },
        zone_weight = 1,
    }

    local cfg_top = {
        zone_id = 'top',
        ops_slf = { x = '17-20,21-34', y = '1-9,1-10' }
    }

    local cfg_all_map = {
        zone_id = 'all_map',
        ops_slf = {},
        center_hexes = { { 20, 20 } }
    }


    if (zone_id == 'leader_threat') then
        return cfg_leader_threat
    end

    if (not zone_id) then
        local zone_cfgs = {
            west = cfg_west,
            center = cfg_center,
            east = cfg_east
        }
       return zone_cfgs

    elseif (zone_id == 'all') then
        local all_cfgs = {
            leader_threat = cfg_leader_threat,
            west = cfg_west,
            center = cfg_center,
            east = cfg_east,
            top = cfg_top,
            all_map = cfg_all_map
        }
       return all_cfgs

    else
        local cfgs = {
            leader_threat = cfg_leader_threat,
            west = cfg_west,
            center = cfg_center,
            east = cfg_east,
            top = cfg_top,
            all_map = cfg_all_map
        }

        for _,cfg in pairs(cfgs) do
            if (cfg.zone_id == zone_id) then
                return cfg
            end
        end
    end
end

function fred_scenario_cfg.replace_zone_ids()
    local zone_ids = {
        old = { 'center', 'east' },
        new = 'top'
    }

    return zone_ids
end

return fred_scenario_cfg
