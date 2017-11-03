----- CA: Stats at beginning of turn (max_score: 999990) -----
-- This will be blacklisted after first execution each turn

local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local ca_stats = {}

function ca_stats:evaluation(ai, cfg, self)
    return 999990
end

function ca_stats:execution(ai, cfg, self)
    local tod = wesnoth.get_time_of_day()
    print('\n**** Fred ' .. wesnoth.dofile('~/add-ons/AI-demos/version.lua') .. ' *******************************************************')
    DBG.print_ts('Beginning of Turn ' .. wesnoth.current.turn .. ' (' .. tod.name ..') stats')

    local sides = {}
    local leveled_units
    for id,_ in pairs(self.data.move_data.units) do
        local unit_side = self.data.move_data.unit_infos[id].side
        if (not sides[unit_side]) then sides[unit_side] = {} end

        sides[unit_side].num_units = (sides[unit_side].num_units or 0) + 1
        sides[unit_side].hitpoints = (sides[unit_side].hitpoints or 0) + self.data.move_data.unit_infos[id].hitpoints

        if self.data.move_data.unit_infos[id].canrecruit then
            sides[unit_side].leader_type = self.data.move_data.unit_copies[id].type
        else
            if (unit_side == wesnoth.current.side) and (self.data.move_data.unit_infos[id].level > 1) then
                if (not leveled_units) then leveled_units = '' end
                leveled_units = leveled_units
                    .. self.data.move_data.unit_infos[id].type .. ' ('
                    .. self.data.move_data.unit_infos[id].hitpoints .. '/' .. self.data.move_data.unit_infos[id].max_hitpoints .. ')  '
            end
        end
    end

    local total_villages = 0
    for x,tmp in pairs(self.data.move_data.village_map) do
        for y,village in pairs(tmp) do
            local owner = self.data.move_data.village_map[x][y].owner
            if (owner > 0) then
                sides[owner].num_villages = (sides[owner].num_villages or 0) + 1
            end

            total_villages = total_villages + 1
        end
    end

    for _,side_info in ipairs(wesnoth.sides) do
        local side = side_info.side
        local num_villages = sides[side].num_villages or 0
        print('  Side ' .. side .. ': '
            .. sides[side].num_units .. ' Units (' .. sides[side].hitpoints .. ' HP), '
            .. num_villages .. '/' .. total_villages .. ' villages  ('
            .. sides[side].leader_type .. ', ' .. side_info.gold .. ' gold)'
        )
    end

    if leveled_units then print('    Leveled units: ' .. leveled_units) end

    print('************************************************************************')
end

return ca_stats
