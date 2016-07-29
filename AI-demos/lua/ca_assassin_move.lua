local H = wesnoth.require "lua/helper.lua"
local AH = wesnoth.require "ai/lua/ai_helper.lua"
local BC = wesnoth.require "ai/lua/battle_calcs.lua"
local LS = wesnoth.require "lua/location_set.lua"
local MAIUV = wesnoth.require "ai/micro_ais/micro_ai_unit_variables.lua"
local MAISD = wesnoth.require "ai/micro_ais/micro_ai_self_data.lua"

local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"  ---- xxxxxx

local function get_units_target(filter, target_id)
    local units = AH.get_units_with_moves {
        side = wesnoth.current.side,
        { "and", filter }
    }

    local target = wesnoth.get_units { id = target_id }[1]

    return units, target
end

local function custom_cost(x, y, unit, rating_map)
    local terrain = wesnoth.get_terrain(x, y)
    local move_cost = wesnoth.unit_movement_cost(unit, terrain)

    move_cost = move_cost + (rating_map:get(x,y) or 0)

    return move_cost
end

local ca_assassin_move = {}

function ca_assassin_move:evaluation(cfg, data)
    local units, target = get_units_target(H.get_child(cfg, "filter"), cfg.target_id)
    if (not units[1]) then return 0 end
    if (not target) then return 0 end

    return cfg.ca_score
end

function ca_assassin_move:execution(cfg, data)
    local units, target = get_units_target(H.get_child(cfg, "filter"), cfg.target_id)
    local unit = units[1]
    --std_print(unit.id, target.id, target.x, target.y)

    local enemies = wesnoth.get_units {
        { "filter_side", { { "enemy_of", { side = wesnoth.current.side } } } },
        { "not", { id = cfg.target_id } }
    }
    --std_print('#enemies', #enemies)

    local enemy_attack_map = LS.create()
    for _,enemy in ipairs(enemies) do
        -- Need to "move" enemy next to unit for attack calculation
        -- Do this with a unit copy, so that no actual unit has to be moved
        local enemy_copy = wesnoth.copy_unit(enemy)
        enemy_copy.x = unit.x
        enemy_copy.y = unit.y + 1 -- this even seems to work at border of map

        local _, _, att_weapon, _ = wesnoth.simulate_combat(enemy_copy, unit)
        local max_damage = att_weapon.damage * att_weapon.num_blows
        --std_print('max_damage', enemy.id, max_damage)

        local old_moves = enemy.moves
        enemy.moves = enemy.max_moves
        local reach = wesnoth.find_reach(enemy, { ignore_units = true })
        enemy.moves = old_moves

        local single_attack_map = LS.create()
        for _,loc in ipairs(reach) do
            single_attack_map:insert(loc[1], loc[2], max_damage)
            for xa,ya in H.adjacent_tiles(loc[1], loc[2]) do
                single_attack_map:insert(xa, ya, max_damage)
            end
        end

        enemy_attack_map:union_merge(single_attack_map, function(x, y, v1, v2)
            return (v1 or 0) + v2
        end)
    end

    local rating_map = LS.create()

    enemy_attack_map:iter(function(x, y, value)
        local hit_chance = (wesnoth.unit_defense(unit, wesnoth.get_terrain(x, y))) / 100.

        local rating = hit_chance * value
        rating = rating / unit.max_hitpoints
        if (rating > 1) then rating = 1 end

        rating = rating * 5

        rating_map:insert(x, y, rating)
    end)

    local is_skirmisher = wesnoth.unit_ability(unit, "skirmisher")
    for _,enemy in ipairs(enemies) do
        -- Rate the hex the unit is on as unreachable
        rating_map:insert(enemy.x, enemy.y, (rating_map:get(enemy.x, enemy.y) or 0) + 100)

        -- All hexes adjacent to enemies get max_moves penalty
        -- except if unit is skirmisher or enemy is level 0
        local zoc_active = (not is_skirmisher)

        if zoc_active then
            local level = wesnoth.unit_types[enemy.type].level
            if (level == 0) then zoc_active = false end
        end

        if zoc_active then
            for xa,ya in H.adjacent_tiles(enemy.x, enemy.y) do
                rating_map:insert(xa, ya, (rating_map:get(xa, ya) or 0) + unit.max_moves)
            end
        end
    end
    --AH.put_labels(enemy_attack_map)
    --AH.put_labels(rating_map)

    local path, cost = wesnoth.find_path(unit, target.x, target.y,
        function(x, y, current_cost)
            return custom_cost(x, y, unit, rating_map)
        end
    )
    --std_print('cost:', cost)

    --DBG.dbms(path)
    local path_map = LS.of_pairs(path)
    AH.put_labels(path_map)

    -- We need to pick the farthest reachable hex along that path
    local farthest_hex = path[1]
    for i = 2,#path do
        local sub_path, sub_cost = wesnoth.find_path(unit, path[i][1], path[i][2], cfg)
        if sub_cost <= unit.moves then
            local unit_in_way = wesnoth.get_unit(path[i][1], path[i][2])
            if not unit_in_way then
                farthest_hex = path[i]
            end
        else
            break
        end
    end
    --std_print('farthest_hex', farthest_hex[1], farthest_hex[2])

    if farthest_hex then
        AH.checked_move_full(ai, unit, farthest_hex[1], farthest_hex[2])
    else
        AH.checked_stopunit_moves(ai, unit)
    end
end

return ca_assassin_move
