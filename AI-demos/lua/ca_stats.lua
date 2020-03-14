----- CA: Stats at beginning of turn (max_score: 999990) -----
-- This will be blacklisted after first execution each turn

local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"
local COMP = wesnoth.require "~/add-ons/AI-demos/lua/compatibility.lua"

local ca_stats = {}

function ca_stats:evaluation()
    return 999990
end

function ca_stats:execution()
    local tod = wesnoth.get_time_of_day()
    std_print('\n**** Fred Side ' .. wesnoth.current.side .. ' (version ' .. wesnoth.dofile('~/add-ons/AI-demos/version.lua') .. ') *******************************************************')
    DBG.print_ts('Beginning of Turn ' .. wesnoth.current.turn .. ' (' .. tod.name ..') stats')

    local sides = {}
    local leveled_units
    for _,unit_proxy in ipairs(COMP.get_units()) do
        local unit_side = unit_proxy.side
        if (not sides[unit_side]) then sides[unit_side] = {} end

        sides[unit_side].num_units = (sides[unit_side].num_units or 0) + 1
        sides[unit_side].hitpoints = (sides[unit_side].hitpoints or 0) + unit_proxy.hitpoints

        if unit_proxy.canrecruit then
            sides[unit_side].leader_type = unit_proxy.type
            sides[unit_side].leader_hp = unit_proxy.hitpoints
            sides[unit_side].leader_max_hp = unit_proxy.max_hitpoints
        else
            if (unit_side == wesnoth.current.side) and (unit_proxy.level > 1) then
                if (not leveled_units) then leveled_units = '' end
                leveled_units = leveled_units
                    .. unit_proxy.type .. ' ('
                    .. unit_proxy.hitpoints .. '/' .. unit_proxy.max_hitpoints .. ')  '
            end
        end
    end

    local total_villages = 0
    for _,village in ipairs(wesnoth.get_villages()) do
        local owner = wesnoth.get_village_owner(village[1], village[2]) or 0
        if (owner > 0) then
            sides[owner].num_villages = (sides[owner].num_villages or 0) + 1
        end

        total_villages = total_villages + 1
    end

    for _,side_info in ipairs(wesnoth.sides) do
        local side = side_info.side
        local num_villages = sides[side].num_villages or 0
        std_print('  Side ' .. side .. ': '
            .. sides[side].num_units .. ' Units (' .. sides[side].hitpoints .. ' HP), '
            .. num_villages .. '/' .. total_villages .. ' villages  ('
            .. sides[side].leader_type .. ', ' .. sides[side].leader_hp .. '/' .. sides[side].leader_max_hp .. ' HP, ' .. side_info.gold .. ' gold)'
        )
    end

    if leveled_units then std_print('    Leveled units: ' .. leveled_units) end

    std_print('************************************************************************************')
end

return ca_stats
