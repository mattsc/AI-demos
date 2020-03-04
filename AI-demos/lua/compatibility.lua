-- Functions for simplifying complying with both 1.14 and 1.15 standards
-- Many of these could, in principle, be combined into few functions with
-- function names passed as arguments. I am doing it separately intentionally,
-- so that it is clear which functions are affected.

local AH = wesnoth.dofile "ai/lua/ai_helper.lua"
local H = wesnoth.require "helper"
local I = wesnoth.require "lua/wml/items.lua"

local compatibility = {}

function compatibility.change_max_moves(unit_proxy, max_moves)
    if wesnoth.compare_versions(wesnoth.game_config.version, '>=', '1.15.0') then
        unit_proxy.max_moves = max_moves
    else
        H.modify_unit(
            { id = unit_proxy.id} ,
            { max_moves = max_moves }
        )
    end
end

function compatibility.copy_unit(...)
    if wesnoth.compare_versions(wesnoth.game_config.version, '>=', '1.15.0') then
        return wesnoth.units.clone(...)
    else
        return wesnoth.copy_unit(...)
    end
end

function compatibility.create_unit(...)
    if wesnoth.compare_versions(wesnoth.game_config.version, '>=', '1.15.0') then
        return wesnoth.units.create(...)
    else
        return wesnoth.create_unit(...)
    end
end

function compatibility.debug_ai()
    if wesnoth.compare_versions(wesnoth.game_config.version, '>=', '1.15.0') then
        return wesnoth.sides.debug_ai(wesnoth.current.side).ai
    else
        return wesnoth.debug_ai(wesnoth.current.side).ai
    end
end

function compatibility.erase_unit(...)
    if wesnoth.compare_versions(wesnoth.game_config.version, '>=', '1.15.0') then
        return wesnoth.units.erase(...)
    else
        return wesnoth.erase_unit(...)
    end
end

function compatibility.extract_unit(...)
    if wesnoth.compare_versions(wesnoth.game_config.version, '>=', '1.15.0') then
        return wesnoth.units.extract(...)
    else
        return wesnoth.extract_unit(...)
    end
end

function compatibility.find_path_custom_cost(unit, x, y, cost_function)
    if wesnoth.compare_versions(wesnoth.game_config.version, '>=', '1.15.0') then
        return wesnoth.find_path(unit, x, y, { calculate = cost_function })
    else
        return wesnoth.find_path(unit, x, y, cost_function)
    end
end

function compatibility.get_closest_enemy(...)
    local distance, enemy = AH.get_closest_enemy(...)
    if wesnoth.compare_versions(wesnoth.game_config.version, '>=', '1.15.0') then
        local tmp = distance
        distance = enemy
        enemy = tmp
    end
    return distance, enemy
end

function compatibility.get_sides(side_filter)
    if wesnoth.compare_versions(wesnoth.game_config.version, '>=', '1.15.0') then
        return wesnoth.sides.find(side_filter)
    else
        return wesnoth.get_sides(side_filter)
    end
end

function compatibility.get_starting_location(side)
    if wesnoth.compare_versions(wesnoth.game_config.version, '>=', '1.15.0') then
        return wesnoth.sides[side].starting_location
    else
        return wesnoth.get_starting_location(side)
    end
end

function compatibility.get_unit(...)
    if wesnoth.compare_versions(wesnoth.game_config.version, '>=', '1.15.0') then
        return wesnoth.units.get(...)
    else
        return wesnoth.get_unit(...)
    end
end

function compatibility.get_units(...)
    if wesnoth.compare_versions(wesnoth.game_config.version, '>=', '1.15.0') then
        return wesnoth.units.find_on_map(...)
    else
        return wesnoth.get_units(...)
    end
end

function compatibility.is_enemy(...)
    if wesnoth.compare_versions(wesnoth.game_config.version, '>=', '1.15.0') then
        return wesnoth.sides.is_enemy(...)
    else
        return wesnoth.is_enemy(...)
    end
end

function compatibility.match_unit(unit, filter)
    if wesnoth.compare_versions(wesnoth.game_config.version, '>=', '1.15.0') then
        return unit:matches(filter)
    else
        return wesnoth.match_unit(unit, filter)
    end
end

function compatibility.place_halo(...)
    if wesnoth.compare_versions(wesnoth.game_config.version, '>=', '1.15.0') then
        return wesnoth.interface.add_item_halo(...)
    else
        return I.place_halo(...)
    end
end

function compatibility.put_unit(...)
    if wesnoth.compare_versions(wesnoth.game_config.version, '>=', '1.15.0') then
        return wesnoth.units.to_map(...)
    else
        return wesnoth.put_unit(...)
    end
end

function compatibility.remove(...)
    if wesnoth.compare_versions(wesnoth.game_config.version, '>=', '1.15.0') then
        return wesnoth.interface.remove_item(...)
    else
        return I.remove(...)
    end
end

function compatibility.unit_ability(unit, ability)
    if wesnoth.compare_versions(wesnoth.game_config.version, '>=', '1.15.0') then
        return unit:ability(ability)
    else
        return wesnoth.unit_ability(unit, ability)
    end
end

function compatibility.unit_defense(unit, terrain_type)
    if wesnoth.compare_versions(wesnoth.game_config.version, '>=', '1.15.0') then
        return 100 - unit:defense_on(terrain_type)
    else
        return wesnoth.unit_defense(unit, terrain_type)
    end
end

function compatibility.unit_movement_cost(unit, terrain_type)
    if wesnoth.compare_versions(wesnoth.game_config.version, '>=', '1.15.0') then
        return unit:movement_on(terrain_type)
    else
        return wesnoth.unit_movement_cost(unit, terrain_type)
    end
end

function compatibility.unit_resistance(unit, attack_type)
    if wesnoth.compare_versions(wesnoth.game_config.version, '>=', '1.15.0') then
        return 100 - unit:resistance_against(attack_type)
    else
        return wesnoth.unit_resistance(unit, attack_type)
    end
end

return compatibility
