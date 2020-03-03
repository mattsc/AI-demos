local AH = wesnoth.require "ai/lua/ai_helper.lua"
local COMP = wesnoth.require "~/add-ons/AI-demos/lua/compatibility.lua"

local ai_helper_local = {}

function ai_helper_local.movepartial_outofway_stopunit(ai, unit, x, y, cfg)
    local viewing_side = cfg and cfg.viewing_side or unit.side

    if (type(x) ~= 'number') then
        if x[1] then
            x, y = x[1], x[2]
        else
            x, y = x.x, x.y
        end
    end

    -- Only move unit out of way if the main unit can get there
    local path, cost = AH.find_path_with_shroud(unit, x, y, cfg)
    if (cost <= unit.moves) then
        local unit_in_way = COMP.get_unit(x, y)
        if unit_in_way and (unit_in_way ~= unit)
            and AH.is_visible_unit(viewing_side, unit_in_way)
        then
            AH.move_unit_out_of_way(ai, unit_in_way, cfg)
        end
    end

    local next_hop = AH.next_hop(unit, x, y)
    if next_hop and ((next_hop[1] ~= unit.x) or (next_hop[2] ~= unit.y)) then
        AH.checked_move(ai, unit, next_hop[1], next_hop[2])
    else
        AH.checked_stopunit_moves(ai, unit)
    end
end

return ai_helper_local
