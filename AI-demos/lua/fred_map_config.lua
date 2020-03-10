-- These collect all the scenario/map specific information
-- TODO: generalize so that it can be used on maps other than Freelands

local AH = wesnoth.require "ai/lua/ai_helper.lua"

local fred_map_config = {}

function fred_map_config.get_side_cfgs()
    local cfgs = {
        { start_hex = { 18, 4 } },
        { start_hex = { 20, 20 } }
    }

    return cfgs
end

function fred_map_config.get_attack_test_locs()
    -- TODO: this is really just a placeholder for now until I know whether this works
    -- It's easy to have this found automatically
    local locs = {
        attacker_loc = { 28, 13 },
        defender_loc = { 28, 14 }
    }

    return locs
end

function fred_map_config.get_raw_cfgs(zone_id)
    local cfg_all_map = {
        zone_id = 'all_map',
        ops_slf = { include_borders = 'no' },
        center_hexes = { { 20, 20 } }
    }

    local cfg_leader_threat = {
        zone_id = 'leader',
        ops_slf = { include_borders = 'no' },
    }

    local ops_slf_west = { x = '4-16,4-15,4-14,4-16,4-17', y = '1-6,7-12,13-15,16,17-23' }
    local center_hexes_west = { { 10, 13 } }

    local ops_slf_center = { x = '16-20,16-22,16-23,15-22,15-22,17-22,18-22', y = '7-8,9,10-12,13-14,15,16,17' }
    local center_hexes_center = { { 18, 12 }, { 20, 12 } }

    local ops_slf_east = { x = '21-34,23-34,24-34,23-34,22-34', y = '1-8,9,10-12,13-17,18-23' }
    local center_hexes_east = { { 28, 13 } }

    local cfg_right = {
        zone_id = 'right',
        zone_weight = 1
    }

    local cfg_center = {
        zone_id = 'center',
        zone_weight = 0.5
    }

    local cfg_left = {
        zone_id = 'left',
        zone_weight = 1
    }

    if (wesnoth.current.side == 1) then
        local enemy_leader_slf = { x = '17-22', y = '18-24' }

        cfg_right.ops_slf = ops_slf_west
        table.insert(cfg_right.ops_slf, { "or", enemy_leader_slf })
        cfg_right.center_hexes = center_hexes_west

        cfg_center.ops_slf = ops_slf_center
        table.insert(cfg_center.ops_slf, { "or", enemy_leader_slf })
        cfg_center.center_hexes = center_hexes_center

        cfg_left.ops_slf = ops_slf_east
        table.insert(cfg_left.ops_slf, { "or", enemy_leader_slf })
        cfg_left.center_hexes = center_hexes_east
    else
        local enemy_leader_slf = { x = '16-21', y = '1-7' }

        cfg_right.ops_slf = ops_slf_east
        table.insert(cfg_right.ops_slf, { "or", enemy_leader_slf })
        cfg_right.center_hexes = center_hexes_east

        cfg_center.ops_slf = ops_slf_center
        table.insert(cfg_center.ops_slf, { "or", enemy_leader_slf })
        cfg_center.center_hexes = center_hexes_center

        cfg_left.ops_slf = ops_slf_west
        table.insert(cfg_left.ops_slf, { "or", enemy_leader_slf })
        cfg_left.center_hexes = center_hexes_west
    end


    -- Replacement zones:
    local cfg_top = {
        zone_id = 'top',
        center_hexes = {}
    }
    for _,hex in ipairs(cfg_center.center_hexes) do table.insert(cfg_top.center_hexes, hex) end
    for _,hex in ipairs(cfg_left.center_hexes) do table.insert(cfg_top.center_hexes, hex) end
    cfg_top.ops_slf = AH.table_copy(cfg_center.ops_slf)
    table.insert(cfg_top.ops_slf, { "or", cfg_left.ops_slf })

    if (wesnoth.current.side == 1) then
        cfg_top.enemy_slf = { x = '17-34,21-34', y = '1-9,10' }
    else
        -- This one is much more complicated than for the other side, because of the uneven hex symmetry
        cfg_top.enemy_slf = { x = '4,6,8,10,12,14,16,4-18,20,4-21', y = '14,14,14,14,14,14,14,15,15,16-23' }
    end

    if (zone_id == 'leader_threat') then
        return cfg_leader_threat
    end

    if (not zone_id) then
        local zone_cfgs = {
            right = cfg_right,
            center = cfg_center,
            left = cfg_left
        }
        return zone_cfgs

    elseif (zone_id == 'all') then
        local all_cfgs = {
            leader_threat = cfg_leader_threat,
            right = cfg_right,
            center = cfg_center,
            left = cfg_left,
            top = cfg_top,
            all_map = cfg_all_map
        }
       return all_cfgs

    else
        local cfgs = {
            leader_threat = cfg_leader_threat,
            right = cfg_right,
            center = cfg_center,
            left = cfg_left,
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

function fred_map_config.replace_zone_ids()
    local zone_ids = { {
        old = { 'center', 'left' },
        new = 'top'
    } }

    return zone_ids
end

return fred_map_config
