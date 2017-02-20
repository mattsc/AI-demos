local H = wesnoth.require "lua/helper.lua"
local W = H.set_wml_action_metatable {}
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"

local fred_village_utils = {}

function fred_village_utils.village_goals(zone_cfgs, side_cfgs, gamedata)
    -- Village goals are those that are:
    --  - on my side of the map
    --  - not owned by me
    -- We set those up as arrays, one for each zone
    --  - if a village is found that is not in a zone, assign it zone 'other'

    local my_start_hex, enemy_start_hex
    for side,cfgs in ipairs(side_cfgs) do
        if (side == wesnoth.current.side) then
            my_start_hex = cfgs.start_hex
        else
            enemy_start_hex = cfgs.start_hex
        end
    end

    local zone_maps = {}
    for zone_id,cfg in pairs(zone_cfgs) do
        zone_maps[zone_id] = {}
        local zone = wesnoth.get_locations(cfg.ops_slf)
        for _,loc in ipairs(zone) do
            FU.set_fgumap_value(zone_maps[zone_id], loc[1], loc[2], 'in_zone', true)
        end
    end

    local zone_village_goals, protect_villages_maps = {} , {}
    for x,y,village in FU.fgumap_iter(gamedata.village_map) do
        local my_distance = H.distance_between(x, y, my_start_hex[1], my_start_hex[2])
        local enemy_distance = H.distance_between(x, y, enemy_start_hex[1], enemy_start_hex[2])

        local threats = FU.get_fgumap_value(gamedata.enemy_attack_map[1], x, y, 'ids')

        if (my_distance <= enemy_distance) or (not threats) then
            local village_zone
            for zone_id,_ in pairs(zone_maps) do
                if FU.get_fgumap_value(zone_maps[zone_id], x, y, 'in_zone') then
                    village_zone = zone_id
                    break
                end
            end
            if (not village_zone) then village_zone = 'other' end

            if (village.owner ~= wesnoth.current.side) then
                if (not zone_village_goals[village_zone]) then
                    zone_village_goals[village_zone] = {}
                end

                local grab_only = true
                if (my_distance <= enemy_distance) then
                    grab_only = false
                end
                table.insert(zone_village_goals[village_zone], {
                    x = x, y = y,
                    owner = village.owner,
                    grab_only = grab_only
                })
            end

            if (not protect_villages_maps[village_zone]) then
                protect_villages_maps[village_zone] = {}
            end
            FU.set_fgumap_value(protect_villages_maps[village_zone], x, y, 'protect', true)
        end
    end

    return zone_village_goals, protect_villages_maps
end


function fred_village_utils.assign_grabbers(zone_village_goals, assigned_units, immediate_actions, gamedata)
    -- assigned_units and immediate_actions are modified directly in place

    -- Villages that can be reached are dealt with separately from others
    -- Only go over those found above
    local villages_in_reach = { by_village = {}, by_unit = {} }

    for zone_id,villages in pairs(zone_village_goals) do
        for _,village in ipairs(villages) do
            local tmp_in_reach = {
                x = village.x, y = village.y,
                owner = village.owner, zone_id = zone_id,
                units = {}
            }

            local ids = FU.get_fgumap_value(gamedata.my_move_map[1], village.x, village.y, 'ids', {})

            for _,id in pairs(ids) do
                local loc = gamedata.my_units[id]
                -- Only include the leader if he's on the keep
                if (not gamedata.unit_infos[id].canrecruit)
                    or wesnoth.get_terrain_info(wesnoth.get_terrain(loc[1], loc[2])).keep
                then
                    --print(id, loc[1], loc[2])

                    table.insert(tmp_in_reach.units, id)

                    -- For this is sufficient to just count how many villages a unit can get to
                    if (not villages_in_reach.by_unit[id]) then
                        villages_in_reach.by_unit[id] = 1
                    else
                        villages_in_reach.by_unit[id] = villages_in_reach.by_unit[id] + 1
                    end
                end
            end

            if (#tmp_in_reach.units > 0) then
                table.insert(villages_in_reach.by_village, tmp_in_reach)
            end
        end
    end


    -- Now find best villages for those units
    -- This is one where we need to do the full analysis at this layer,
    -- as it determines which units goes into which zone
    local best_captures = {}
    local keep_trying = true
    while keep_trying do
        keep_trying = false

        local max_rating, best_id, best_index
        for i_v,village in ipairs(villages_in_reach.by_village) do
            local base_rating = 1000
            if (village.owner ~= 0) then
                base_rating = base_rating + 1200
            end
            base_rating = base_rating / #village.units

            -- Prefer villages farther back
            local add_rating_village = - FU.get_fgumap_value(gamedata.leader_distance_map, village.x, village.y, 'distance')

            for _,id in ipairs(village.units) do
                local unit_rating = base_rating / (villages_in_reach.by_unit[id]^2)

                -- Use most injured unit first (but less important than choice of village)
                local ui = gamedata.unit_infos[id]
                local add_rating_unit = (ui.max_hitpoints - ui.hitpoints) / ui.max_hitpoints
                if ui.status.poisoned then
                    add_rating_unit = add_rating_unit + 8 / ui.max_hitpoints
                end

                -- And finally, prefer the fastest unit, but at an even lesser level
                add_rating_unit = add_rating_unit + ui.max_moves / 100.

                -- Finally, prefer the leader, if possible, but only in the minor ratings
                if ui.canrecruit then
                    add_rating_unit = add_rating_unit * 2
                end

                local total_rating = unit_rating + add_rating_village + add_rating_unit
                --print(id, add_rating_unit, total_rating, ui.canrecruit)

                if (not max_rating) or (total_rating > max_rating) then
                    max_rating = total_rating
                    best_id, best_index = id, i_v
                end
            end
        end

        if best_id then
            table.insert(best_captures, {
                id = best_id ,
                x = villages_in_reach.by_village[best_index].x,
                y = villages_in_reach.by_village[best_index].y,
                zone_id = villages_in_reach.by_village[best_index].zone_id
            })

            -- We also need to delete both this village and unit from the list
            -- before considering the next village/unit
            -- 1. Each unit that could reach this village can reach one village less overall
            for _,id in ipairs(villages_in_reach.by_village[best_index].units) do
                villages_in_reach.by_unit[id] = villages_in_reach.by_unit[id] - 1
            end

            -- 2. Remove theis village
            table.remove(villages_in_reach.by_village, best_index)

            -- 3. Remove this unit
            villages_in_reach.by_unit[best_id] = nil

            -- 4. Remove this unit from all other villages
            for _,village in ipairs(villages_in_reach.by_village) do
                for i = #village.units,1,-1 do
                    if (village.units[i] == best_id) then
                        table.remove(village.units, i)
                    end
                end
            end

            keep_trying = true
        end
    end

    for _,capture in ipairs(best_captures) do
        assigned_units[capture.id] = {
            action = {
                action = 'grab village',
                x = capture.x, y = capture.y
            },
            zone_id = capture.zone_id
        }

        -- This currently only works for single-unit actions; can be expanded as needed
        local unit = gamedata.my_units[capture.id]
        unit.id = capture.id
        table.insert(immediate_actions, {
            id = capture.id,
            units = { unit },
            dsts = { { capture.x, capture.y } },
            zone_id = capture.zone_id,
            action = capture.zone_id .. ': grab village'
        })
    end

    return best_captures
end


return fred_village_utils
