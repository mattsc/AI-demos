local H = wesnoth.require "lua/helper.lua"
local W = H.set_wml_action_metatable {}
local LS = wesnoth.require "lua/location_set.lua"
local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

local ai_helper = {}

----- Debugging helper functions ------

function ai_helper.show_messages()
    -- Returns true or false (hard-coded).  To be used to
    -- show messages if in debug mode
    -- Just edit the following line (easier than trying to set WML variable)
    local show_messages_flag = false
    if wesnoth.game_config.debug then return show_messages_flag end
    return false
end

function ai_helper.print_exec()
    -- Returns true or false (hard-coded).  To be used to
    -- show which CA is being executed if in debug mode
    -- Just edit the following line (easier than trying to set WML variable)
    local print_exec_flag = true
    if wesnoth.game_config.debug then return print_exec_flag end
    return false
end

function ai_helper.print_eval()
    -- Returns true or false (hard-coded).  To be used to
    -- show which CA is being evaluated if in debug mode
    -- Just edit the following line (easier than trying to set WML variable)
    local print_eval_flag = false
    if wesnoth.game_config.debug then return print_eval_flag end
    return false
end

function ai_helper.done_eval_messages(start_time, ca_name)
    ca_name = ca_name or 'unknown'
    local dt = os.clock() - start_time
    if ai_helper.print_eval() then print('       - Done evaluating ' .. ca_name .. ':', os.clock(), ' ---------------> ', dt) end
    if (dt >= 10) then
        W.message{
            speaker = 'narrator',
            caption = 'Evaluation of candidate action ' .. ca_name .. ' took ' .. dt .. ' seconds',
            message = 'This took a really long time (which it should not).  If you can, would you mind sending us a screen grab of this situation?  Thanks!'
        }
    end
end

function ai_helper.clear_labels()
    -- Clear all labels on a map
    local w,h,b = wesnoth.get_map_size()
    for x = 1,w do
        for y = 1,h do
          W.label { x = x, y = y, text = "" }
        end
    end
end

function ai_helper.put_labels(map, factor)
    -- Take map (location set) and put label containing 'value' onto the map
    -- factor: multiply by 'factor' if set
    -- print 'nan' if element exists but is not a number

    factor = factor or 1

    ai_helper.clear_labels()
    map:iter(function(x, y, data)
          local out = tonumber(data) or 'nan'
          if (out ~= 'nan') then out = out * factor end
          W.label { x = x, y = y, text = out }
    end)
end

----- General functionality and maths helper functions ------

function ai_helper.got_1_11()
   if not wesnoth.compare_versions then return false end
   return wesnoth.compare_versions(wesnoth.game_config.version, ">=", "1.11.0")
end

function ai_helper.filter(input, condition)
    -- equivalent of filter() function in Formula AI

    local filtered_table = {}

    for i,v in ipairs(input) do
        if condition(v) then
            --print(i, "true")
            table.insert(filtered_table, v)
        end
    end

    return filtered_table
end

function ai_helper.choose(input, value)
    -- equivalent of choose() function in Formula AI
    -- Returns element of a table with the largest 'value' (a function)
    -- Also returns the max value and the index

    local max_value = -9e99
    local best_input = nil
    local best_key = nil

    for k,v in pairs(input) do
        if value(v) > max_value then
            max_value = value(v)
            best_input = v
            best_key = k
        end
        --print(k, value(v), max_value)
    end

    return best_input, max_value, best_key
end

function ai_helper.random(min, max)
    -- Use this function as Lua's 'math.random' is not replay or MP safe

    if not max then min, max = 1, min end
    wesnoth.fire("set_variable", { name = "LUA_random", rand = string.format("%d..%d", min, max) })
    local res = wesnoth.get_variable "LUA_random"
    wesnoth.set_variable "LUA_random"
    return res
end

function ai_helper.table_copy(t)
    -- Make a copy of a table (rather than just another pointer to the same table)
    local copy = {}
    for k,v in pairs(t) do copy[k] = v end
    return copy
end

function ai_helper.array_merge(a1, a2)
    -- Merge two arrays
    -- I want to do this without overwriting t1 or t2 -> create a new table
    -- This only works with arrays, not general tables
    local merger = {}
    for i,a in pairs(a1) do table.insert(merger, a) end
    for i,a in pairs(a2) do table.insert(merger, a) end
    return merger
end

--------- Location set related helper functions ----------

function ai_helper.get_LS_xy(index)
    -- Get the x,y coordinates from a location set index
    -- For some reason, there doesn't seem to be a LS function for this

    local tmp_set = LS.create()
    tmp_set.values[index] = 1
    local xy = tmp_set:to_pairs()[1]

    return xy[1], xy[2]
end

function ai_helper.LS_of_triples(table)
    -- Create a location set from a table of 3-element tables
    -- Elements 1 and 2 are x,y coordinates, #3 is value to be inserted

    local set = LS.create()
    for k,t in pairs(table) do
        set:insert(t[1], t[2], t[3])
    end
    return set
end

function ai_helper.to_triples(set)
    local res = {}
    set:iter(function(x, y, v) table.insert(res, { x, y, v }) end)
    return res
end

function ai_helper.LS_random_hex(set)
    -- Select a random hex from the hexes in location set 'set'
    -- This seems "inelegant", but I can't come up with another way without creating an extra array
    -- Return -1, -1 if set is empty

    local r = ai_helper.random(set:size())
    local i, xr, yr = 1, -1, -1
    set:iter( function(x, y, v)
        if (i == r) then xr, yr = x, y end
        i = i + 1
    end)

    return xr, yr
end

--------- Location, position or hex related helper functions ----------

function ai_helper.find_opposite_hex_adjacent(hex, center_hex)
    -- Find the hex that is opposite of 'hex' w.r.t. 'center_hex'
    -- Both input hexes are of format { x, y }
    -- Output: {opp_x, opp_y} -- or nil if 'hex' and 'center_hex' are not adjacent (or no opposite hex is found, e.g. for hexes on border)

    -- If the two input hexes are not adjacent, return nil
    if (H.distance_between(hex[1], hex[2], center_hex[1], center_hex[2]) ~= 1) then return nil end

    -- Finding the opposite x position is easy
    local opp_x = center_hex[1] + (center_hex[1] - hex[1])

    -- y is slightly more tricky, because of the hexagonal shape, but there's a neat trick
    -- that saves us from having to build in a lot of if statements
    -- Among the adjacent hexes, it is the one with the correct x, and y _different_ from hex[2]
    for x, y in H.adjacent_tiles(center_hex[1], center_hex[2]) do
        if (x == opp_x) and (y ~= hex[2]) then return { x, y } end
    end

    return nil
end

function ai_helper.find_opposite_hex(hex, center_hex)
    -- Find the hex that is opposite of 'hex' w.r.t. 'center_hex'
    -- Using "square coordinate" method by JaMiT
    -- Note: this also works for non-adjacent hexes, but might return hexes that are not on the map!
    -- Both input hexes are of format { x, y }
    -- Output: {opp_x, opp_y}

    -- Finding the opposite x position is easy
    local opp_x = center_hex[1] + (center_hex[1] - hex[1])

    -- Going to "square geometry" for y coordinate
    local y_sq = hex[2] * 2 - (hex[1] % 2)
    local yc_sq = center_hex[2] * 2 - (center_hex[1] % 2)

    -- Now the same equation as for x can be used for y
    local opp_y = yc_sq + (yc_sq - y_sq)
    opp_y = math.floor((opp_y + 1) / 2)

    return {opp_x, opp_y}
end

function ai_helper.is_opposite_adjacent(hex1, hex2, center_hex)
    -- Returns true if 'hex1' and 'hex2' are opposite from each other w.r.t center_hex

    local opp_hex = ai_helper.find_opposite_hex_adjacent(hex1, center_hex)

    if opp_hex and (opp_hex[1] == hex2[1]) and (opp_hex[2] == hex2[2]) then return true end
    return false
end

function ai_helper.get_closest_location(hex, location_filter)
    -- Get the location closest to 'hex' (in format { x, y })
    -- that matches 'location_filter' (in WML table format)
    -- Returns nil if no terrain matching the filter was found

    local locs = wesnoth.get_locations(location_filter)

    local max_rating, closest_hex = -9e99, {}
    for i,l in ipairs(locs) do
        local rating = -H.distance_between(hex[1], hex[2], l[1], l[2])
        if (rating > max_rating) then
            max_rating, best_hex = rating, l
        end
    end

    if (max_rating > -9e99) then
        return best_hex
    else
        return nil
    end
end

function ai_helper.distance_map(units, map)
    -- Get the distance map for all units in 'units' (as a location set)
    -- DM = sum ( distance_from_unit )
    -- This is done for all elements of 'map' (a locations set), or for the entire map if 'map' is not given

    local DM = LS.create()

    if map then
        map:iter(function(x, y, data)
            local dist = 0
            for i,u in ipairs(units) do
                dist = dist + H.distance_between(u.x, u.y, x, y)
            end
            DM:insert(x, y, dist)
        end)
    else
        local w,h,b = wesnoth.get_map_size()
        for x = 1,w do
            for y = 1,h do
                local dist = 0
                for i,u in ipairs(units) do
                    dist = dist + H.distance_between(u.x, u.y, x, y)
                end
                DM:insert(x, y, dist)
            end
        end
    end
    --ai_helper.put_labels(DM)
    --W.message {speaker="narrator", message="Distance map" }

    return DM
end

function ai_helper.inverse_distance_map(units, map)
    -- Get the inverse distance map for all units in 'units' (as a location set)
    -- IDM = sum ( 1 / (distance_from_unit+1) )
    -- This is done for all elements of 'map' (a locations set), or for the entire map if 'map' is not given

    local IDM = LS.create()
    if map then
        map:iter(function(x, y, data)
            local dist = 0
            for i,u in ipairs(units) do
                dist = dist + 1. / (H.distance_between(u.x, u.y, x, y) + 1)
            end
            IDM:insert(x, y, dist)
        end)
    else
        local w,h,b = wesnoth.get_map_size()
        for x = 1,w do
            for y = 1,h do
                local dist = 0
                for i,u in ipairs(units) do
                    dist = dist + 1. / (H.distance_between(u.x, u.y, x, y) + 1)
                end
                IDM:insert(x, y, dist)
            end
        end
    end
    --ai_helper.put_labels(IDM)
    --W.message {speaker="narrator", message="Inverse distance map" }

    return IDM
end

function ai_helper.generalized_distance(x1, y1, x2, y2)
    -- determines "distance of (x1,y1) from (x2,y2) even if
    -- x2 and y2 are not necessarily both given (or not numbers)

    -- Return 0 if neither is given
    if (not x2) and (not y2) then return 0 end

    -- If only one of the parameters is set
    if (not x2) then return math.abs(y1 - y2) end
    if (not y2) then return math.abs(x1 - x2) end

    -- Otherwise, return standard distance
    return H.distance_between(x1, y1, x2, y2)
end

function ai_helper.xyoff(x, y, ori, hex)
    -- Finds hexes at a certain offset from x,y
    -- ori: direction/orientation: north (0), ne (1), se (2), s (3), sw (4), nw (5)
    -- hex: string for the hex to be queried.  Possible values:
    --   's': self, 'u': up, 'lu': left up, 'ld': left down, 'ru': right up, 'rd': right down
    --   This is all relative "looking" in the direction of 'ori'
    -- returns x,y for the queried hex

    -- Unlike Lua default, we count 'ori' from 0 (north) to 5 (nw), so that modulo operator can be used
    ori = ori % 6

    if (hex == 's') then return x, y end

    -- This is all done with ifs, to keep it as fast as possible
    if (ori == 0)  then -- "north"
        if (hex == 'u') then return x, y-1 end
        if (hex == 'd') then return x, y+1 end
        local dy = 0
        if (x % 2) == 1 then dy=1 end
        if (hex == 'lu') then return x-1, y-dy end
        if (hex == 'ld') then return x-1, y+1-dy end
        if (hex == 'ru') then return x+1, y-dy end
        if (hex == 'rd') then return x+1, y+1-dy end
    end

    if (ori == 1)  then -- "north-east"
        local dy = 0
        if (x % 2) == 1 then dy=1 end
        if (hex == 'u') then return x+1, y-dy end
        if (hex == 'd') then return x-1, y+1-dy end
        if (hex == 'lu') then return x, y-1 end
        if (hex == 'ld') then return x-1, y-dy end
        if (hex == 'ru') then return x+1, y+1-dy end
        if (hex == 'rd') then return x, y+1 end
    end

    if (ori == 2)  then -- "south-east"
        local dy = 0
        if (x % 2) == 1 then dy=1 end
        if (hex == 'u') then return x+1, y+1-dy end
        if (hex == 'd') then return x-1, y-dy end
        if (hex == 'lu') then return x+1, y-dy end
        if (hex == 'ld') then return x, y-1 end
        if (hex == 'ru') then return x, y+1 end
        if (hex == 'rd') then return x-1, y+1-dy end
    end

    if (ori == 3)  then -- "south"
        if (hex == 'u') then return x, y+1 end
        if (hex == 'd') then return x, y-1 end
        local dy = 0
        if (x % 2) == 1 then dy=1 end
        if (hex == 'lu') then return x+1, y+1-dy end
        if (hex == 'ld') then return x+1, y-dy end
        if (hex == 'ru') then return x-1, y+1-dy end
        if (hex == 'rd') then return x-1, y-dy end
    end

    if (ori == 4)  then -- "south-west"
        local dy = 0
        if (x % 2) == 1 then dy=1 end
        if (hex == 'u') then return x-1, y+1-dy end
        if (hex == 'd') then return x+1, y-dy end
        if (hex == 'lu') then return x, y+1 end
        if (hex == 'ld') then return x+1, y+1-dy end
        if (hex == 'ru') then return x-1, y-dy end
        if (hex == 'rd') then return x, y-1 end
    end

    if (ori == 5)  then -- "north-west"
        local dy = 0
        if (x % 2) == 1 then dy=1 end
        if (hex == 'u') then return x-1, y-dy end
        if (hex == 'd') then return x+1, y+1-dy end
        if (hex == 'lu') then return x-1, y+1-dy end
        if (hex == 'ld') then return x, y+1 end
        if (hex == 'ru') then return x, y-1 end
        if (hex == 'rd') then return x+1, y-dy end
    end

    return
end

--------- Unit related helper functions ----------

function ai_helper.get_live_units(filter)
    -- Same as wesnoth.get_units(), except that it only returns non-petrified units

    filter = filter or {}

    -- So that 'filter' in calling function is not modified (if it's a variable):
    local live_filter = ai_helper.table_copy(filter)

    local filter_not_petrified = { "not", {
        { "filter_wml", {
            { "status", { petrified = "yes" } }
        } }
    } }

    -- Combine the two filters.  Doing it this way around is much easier (always works, no ifs required),
    -- but it means we need to make a copy of the filter above, so that the original does not get changed
    table.insert(live_filter, filter_not_petrified)

    return wesnoth.get_units(live_filter)
end

function ai_helper.get_closest_enemy()
    local enemies = ai_helper.get_live_units {
        { "filter_side", { { "enemy_of", {side = wesnoth.current.side} } } }
    }

    local leader = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]

    local closest_distance, location = 9e99, {}
    for i,u in ipairs(enemies) do
        enemy_distance = helper.distance_between(leader.x, leader.y, u.x, u.y)
        if enemy_distance < closest_distance then
            closest_distance = enemy_distance
            location = { x = u.x, y = u.y}
        end
    end

    return closest_distance, location
end

function ai_helper.has_ability(unit, ability)
    -- Returns true/false depending on whether unit has the given ability
    local has_ability = false
    local abilities = H.get_child(unit.__cfg, "abilities")
    if abilities then
        if H.get_child(abilities, ability) then has_ability = true end
    end
    return has_ability
end

function ai_helper.has_weapon_special(unit, special)
    -- Returns true/false depending on whether unit has a weapon with the given special
    -- Also returns the number of the first poisoned weapon
    local weapon_number = 0
    for att in H.child_range(unit.__cfg, 'attack') do
        weapon_number = weapon_number + 1
        for sp in H.child_range(att, 'specials') do
            if H.get_child(sp, special) then
                return true, weapon_number
            end
        end
    end
    return false
end

--------- Move related helper functions ----------

function ai_helper.get_dst_src_units(units, cfg)
    -- Get the dst_src LS for 'units'
    -- cfg: configuration table
    --   - moves: if set to 'max' use max_moves of units, rather than current moves

    local max_moves = false
    if cfg then
        if (cfg['moves'] == 'max') then max_moves = true end
    end

    local dstsrc = LS.create()
    for i,u in ipairs(units) do
        -- If {moves = 'max} is set
        local tmp = u.moves
        if max_moves then
            u.moves = u.max_moves
        end
        local reach = wesnoth.find_reach(u)
        if max_moves then
            u.moves = tmp
        end
        for j,r in ipairs(reach) do
            local tmp = dstsrc:get(r[1], r[2]) or {}
            table.insert(tmp, {x = u.x, y = u.y})
            dstsrc:insert(r[1], r[2], tmp)
        end
    end
    return dstsrc
end

function ai_helper.get_dst_src(units)
    -- Produces the same output as ai.get_dst_src()   (available in 1.11.0)
    -- If units is given, use them, otherwise do it for all units on the current side

    local my_units = {}
    if units then
        my_units = units
    else
        my_units = wesnoth.get_units { side = wesnoth.current.side }
    end

    return ai_helper.get_dst_src_units(my_units)
end

function ai_helper.get_enemy_dst_src()
    -- Produces the same output as ai.get_enemy_dst_src()   (available in 1.11.0)

    local enemies = wesnoth.get_units {
        { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
    }

    return ai_helper.get_dst_src_units(enemies, {moves = 'max'})
end

function ai_helper.my_moves()
    -- Produces a table with each (numerical) field of form:
    --   [1] = { dst = { x = 7, y = 16 },
    --           src = { x = 6, y = 16 } }

    local dstsrc = ai.get_dstsrc()

    local my_moves = {}
    for key,value in pairs(dstsrc) do
        --print("src: ",value[1].x,value[1].y,"    -- dst: ",key.x,key.y)
        table.insert( my_moves,
            {   src = { x = value[1].x , y = value[1].y },
                dst = { x = key.x , y = key.y }
            }
        )
    end

    return my_moves
end

function ai_helper.enemy_moves()
    -- Produces a table with each (numerical) field of form:
    --   [1] = { dst = { x = 7, y = 16 },
    --           src = { x = 6, y = 16 } }

    local dstsrc = ai.get_enemy_dstsrc()

    local enemy_moves = {}
    for key,value in pairs(dstsrc) do
        --print("src: ",value[1].x,value[1].y,"    -- dst: ",key.x,key.y)
        table.insert( enemy_moves,
            {   src = { x = value[1].x , y = value[1].y },
                dst = { x = key.x , y = key.y }
            }
        )
    end

    return enemy_moves
end

function ai_helper.next_hop(unit, x, y, cfg)
    -- Finds the next "hop" of 'unit' on its way to (x,y)
    -- Returns coordinates of the endpoint of the hop, and movement cost to get there
    -- only unoccupied hexes are considered
    -- cfg: extra options for wesnoth.find_path()

    local path, cost = wesnoth.find_path(unit, x, y, cfg)

    -- If unit cannot get there:
    if cost >= 42424242 then return nil, cost end

    -- If none of the hexes are unoccupied, use current position as default
    local next_hop, nh_cost = {unit.x, unit.y}, 0

    -- Go through loop to find reachable, unoccupied hex along the path
    for index, path_loc in ipairs(path) do
        local sub_path, sub_cost = wesnoth.find_path( unit, path_loc[1], path_loc[2], cfg)

        if sub_cost <= unit.moves then
            local unit_in_way = wesnoth.get_unit(path_loc[1], path_loc[2])
            if not unit_in_way then
                next_hop, nh_cost = path_loc, sub_cost
            end
        else
            break
        end
    end

    return next_hop, nh_cost
end

function ai_helper.can_reach(unit, x, y, cfg)
    -- Returns true if unit can reach (x,y), else false
    -- This only returns true if the hex is unoccupied, or at most occupied by unit on same side as 'unit'
    -- that can move away (can be modified with options below)
    -- cfg:
    --   moves = 'max' use max_moves instead of current moves
    --   ignore_units: if true, ignore both own and enemy units
    --   exclude_occupied: if true, exclude hex if there's a unit there, irrespective of value of 'ignore_units'

    -- If 'cfg' is not set, we need it as an empty array
    cfg = cfg or {}

    -- Is there a unit at the goal hex?
    local unit_in_way = wesnoth.get_unit(x, y)

    -- If there is, and 'exclude_occupied' is set, always return false
    if (cfg.exclude_occupied) and unit_in_way then return false end

    -- Otherwise, if 'ignore_units' is not set, return false if there's a unit of other side,
    -- or a unit of own side that cannot move away (this might be slow, don't know)
    if (not cfg.ignore_units) then
        -- If there's a unit at the goal that's not on own side (even ally), return false
        if unit_in_way and (unit_in_way.side ~= unit.side) then return false end

        -- If the unit in the way is on 'unit's' side and cannot move away, also return false
        if unit_in_way and (unit_in_way.side == unit.side) then
            -- need to pass the cfg here so that it works for enemy units (generally with no moves left) also
            local move_away = ai_helper.get_reachable_unocc(unit_in_way, cfg)
            if (move_away:size() <= 1) then return false end
        end
    end

    -- After all that, test whether our unit can actually get there
    -- Set moves to max_moves, if { moves = 'max' } is set
    local old_moves = unit.moves
    if (cfg.moves == 'max') then unit.moves = unit.max_moves end

    local can_reach = false
    local path, cost = wesnoth.find_path(unit, x, y, cfg)
    if (cost <= unit.moves) then can_reach = true end

    -- Reset moves
    unit.moves = old_moves

    return can_reach
end

function ai_helper.get_reachable_unocc(unit, cfg)
    -- Get all reachable hexes for unit that are unoccupied (incl. by allied units)
    -- Returned array is a location set, with value = 1 for each reachable hex
    -- cfg: parameters to wesnoth.find_reach, such as {additional_turns = 1}
    -- additional, {moves = 'max'} can be set inside cfg, which sets unit MP to max_moves before calculation

    local old_moves = unit.moves
    if cfg then
        if (cfg.moves == 'max') then unit.moves = unit.max_moves end
    end

    local reach = LS.create()
    local initial_reach = wesnoth.find_reach(unit, cfg)

    for i,loc in ipairs(initial_reach) do
        local unit_in_way = wesnoth.get_unit(loc[1], loc[2])
        if not unit_in_way then
            reach:insert(loc[1], loc[2], 1)
        end
    end

    -- Also need to include the hex the unit is on itself
    reach:insert(unit.x, unit.y, 1)

    -- Reset unit moves (can be done whether it was changed or not)
    unit.moves = old_moves

    return reach
end

function ai_helper.find_best_move(units, rating_function, cfg)
    -- Find the best move and best unit based on 'rating_function'
    -- INPUTS:
    --  units: single unit or table of units
    --  rating_function: function(x, y) with rating function for the hexes the unit can reach
    --  cfg: table with elements
    --    labels: if set, put labels with ratings onto map
    --    no_random: if set, do not add random value between 0.0001 and 0.0099 to each hex
    --               (otherwise that's the default)
    -- OUTPUTS:
    --  best_hex: format { x, y }
    --  best_unit: unit for which this rating function produced the maximum value
    -- If no valid moves were found, best_unit and best_hex are empty arrays

    -- If 'cfg' is not set, we need it as an empty array
    cfg = cfg or {}

    -- If this is an individual unit, turn it into an array
    if units.hitpoints then units = { units } end

    local max_rating, best_hex, best_unit = -9e99, {}, {}
    for i,u in ipairs(units) do
        -- Hexes each unit can reach
        local reach_map = ai_helper.get_reachable_unocc(u)
        reach_map:iter( function(x, y, v)
            -- Rate based on rating_function argument
            local rating = rating_function(x, y)

            -- If cfg.random is set, add some randomness (on 0.0001 - 0.0099 level)
            if (not cfg.no_random) then rating = rating + ai_helper.random(99) / 10000. end
            -- If cfg.labels is set: insert values for label map
            if cfg.labels then reach_map:insert(x, y, rating) end

            if rating > max_rating then
                max_rating, best_hex, best_unit = rating, { x, y }, u
            end
        end)
        if cfg.labels then ai_helper.put_labels(reach_map) end
    end

    return best_hex, best_unit
end

function ai_helper.move_unit_out_of_way(ai, unit, cfg)
    -- Find best close location to move unit to
    -- Main rating is the moves the unit still has left after that
    -- Other, configurable, parameters are given to function in 'cfg':
    --   - dx, dy: the direction in which moving out of the way is preferred
    --   - labels: if set, display labels of the rating for each hex the unit can reach

    cfg = cfg or {}

    local reach = wesnoth.find_reach(unit)
    local reach_map = LS.create()

    local max_rating, best_hex = -9e99, {}
    for i,r in ipairs(reach) do
        local unit_in_way = wesnoth.get_unit(r[1], r[2])
        if (not unit_in_way) then  -- also excludes current hex
            local rating = r[3]  -- also disfavors hexes next to enemy units for which r[3] = 0

            if cfg.dx then rating = rating + (r[1] - unit.x) * cfg.dx end
            if cfg.dy then rating = rating + (r[2] - unit.y) * cfg.dy end

            if cfg.labels then reach_map:insert(r[1], r[2], rating) end

            if (rating > max_rating) then
                max_rating, best_hex = rating, { r[1], r[2] }
            end
        end
    end
    if cfg.labels then ai_helper.put_labels(reach_map) end

    if (max_rating > -9e99) then
        --W.message { speaker = unit.id, message = 'Moving out of way' }
        ai.move(unit, best_hex[1], best_hex[2])
    end
end

function ai_helper.movefull_stopunit(ai, unit, x, y)
    -- Does ai.move_full for a unit if not at (x,y), otherwise ai.stopunit_moves
    -- Uses ai_helper.next_hop(), so that it works if unit cannot get there in one move
    -- Coordinates can be given as x and y components, or as a 2-element table { x, y }
    if (type(x) ~= 'number') then
        if x[1] then
            x, y = x[1], x[2]
        else
            x, y = x.x, x.y
        end
    end

    local next_hop = ai_helper.next_hop(unit, x, y)
    if next_hop and ((next_hop[1] ~= unit.x) or (next_hop[2] ~= unit.y)) then
        ai.move_full(unit, next_hop[1], next_hop[2])
    else
        ai.stopunit_moves(unit)
    end
end

function ai_helper.movefull_outofway_stopunit(ai, unit, x, y, cfg)
    -- Same as ai_help.movefull_stopunit(), but also moves unit out of way if there is one
    -- Additional input: cfg for ai_helper.move_unit_out_of_way()
    if (type(x) ~= 'number') then
        if x[1] then
            x, y = x[1], x[2]
        else
            x, y = x.x, x.y
        end
    end

    -- Only move unit out of way if the main unit can get there
    local path, cost = wesnoth.find_path(unit, x, y)
    if (cost <= unit.moves) then
        local unit_in_way = wesnoth.get_unit(x, y)
        if unit_in_way and ((unit_in_way.x ~= unit.x) or (unit_in_way.y ~= unit.y)) then
            --W.message { speaker = 'narrator', message = 'Moving out of way' }
            ai_helper.move_unit_out_of_way(ai, unit_in_way, cfg)
        end
    end

    local next_hop = ai_helper.next_hop(unit, x, y)
    if next_hop and ((next_hop[1] ~= unit.x) or (next_hop[2] ~= unit.y)) then
        ai.move_full(unit, next_hop[1], next_hop[2])
    else
        ai.stopunit_moves(unit)
    end
end

---------- Attack related helper functions --------------

function ai_helper.get_attacks_unit(unit, cfg)
    -- Get all attacks a unit can do
    -- This includes a variety of configurable options, passed in the 'cfg' table
    -- cfg: table with config parameters
    --  moves: "current" (default for units on current side) or "max" (always used for units on other sides)
    --  include_occupied (false): if set, also include hexes occupied by own-side units that can move away
    --  simulate_combat (false): if set, also simulate the combat and return result (this is slow; only set if needed)

    -- Returns {} if no attacks can be done, otherwise table with fields
    --   dst: { x = x, y = y } of attack position
    --   src: { x = x, y = y } of attacking unit (don't use id, could be ambiguous)
    --   target: { x = x, y = y } of defending unit
    --   att_stats, def_stats: as returned by wesnoth.simulate_combat (if cfg.simulate_combat is set)
    --   attack_hex_occupied: boolean storing whether an own unit that can move away is on the attack hex

    cfg = cfg or {}

    -- 'moves' can be either "current" or "max"
    -- For unit on current side: use "current" by default, or override by cfg.moves
    local moves = cfg.moves or "current"
    -- For unit on any other side, only moves="max" makes sense
    if (unit.side ~= wesnoth.current.side) then moves = "max" end

    -- Need to find reachable hexes that are
    -- 1. next to a (non-petrified) enemy unit
    -- 2. not occupied by a unit of a different side (incl. allies)
    W.store_reachable_locations {
        { "filter", { x = unit.x, y = unit.y } },
        { "filter_location", {
            { "filter_adjacent_location", {
                { "filter", {
                    { "filter_side",
                        { { "enemy_of", { side = unit.side } } }
                    },
                    { "not", {
                        { "filter_wml", {
                            { "status", { petrified = "yes" } }  -- This is important!
                        } }
                    } }
                } }
            } },
            { "not", {
                { "filter", { { "not", { side = unit.side } } } }
            } }
        } },
        moves = moves,
        variable = "tmp_locs"
    }

    local attack_loc = H.get_variable_array("tmp_locs")
    W.clear_variable { name = "tmp_locs" }
    --print("reachable attack locs:", unit.id, #attack_loc)

    -- Variable to store attacks
    local attacks = {}
    -- Current position of unit
    local x1, y1 = unit.x, unit.y

    -- Go through all attack locations
    for i,p in pairs(attack_loc) do

        -- At this point, units on the side of 'unit' can still be at the attack hex.
        -- By default, exclude those hexes, but if 'include_occupied' is set
        -- units that can move away are fine

        -- Flag whether a potential unit_in_way can move away
        -- We also set this to true if there is no unit in the way
        local can_move_away = true

        local unit_in_way = wesnoth.get_unit(p.x, p.y)
        -- If unit_in_way is the unit itself, that doesn't count
        if unit_in_way and (unit_in_way.x == unit.x) and (unit_in_way.y == unit.y) then unit_in_way = nil end

        -- If there's a unit_in_way, and it is not the unit itself, check whether it can move away
        if unit_in_way then
            if (not cfg.include_occupied) then
                can_move_away = false
            else
                local move_away = ai_helper.get_reachable_unocc(unit_in_way, { moves = moves })
                if (move_away:size() <= 1) then can_move_away = false end
                --print('Can move away:', unit_in_way.id, can_move_away)
            end
        end
        -- Now can_move_away = true if there's no unit, or if it can move away

        if can_move_away then
            -- Put 'unit' at this position
            -- Remove any unit that might be there first, except if this is the unit itself
            if unit_in_way then wesnoth.extract_unit(unit_in_way) end

            wesnoth.put_unit(p.x, p.y, unit)
            --print(i,' attack pos:',p.x,p.y)

            -- As there might be several attackable units from a position, need to find all those
            local targets = wesnoth.get_units {
                { "filter_side",
                    { { "enemy_of", { side = unit.side } } }
                },
                { "not", {
                    { "filter_wml", {
                        { "status", { petrified = "yes" } }  -- This is important!
                    } }
                } },
                { "filter_location",
                    { { "filter_adjacent_location", { x = p.x, y = p.y } } }
                }
            }
            --print('  number targets: ',#targets)

            local attack_hex_occupied = false
            if unit_in_way then attack_hex_occupied = true end

            for j,t in pairs(targets) do
                local att_stats, def_stats = nil, nil
                if cfg.simulate_combat then
                    att_stats, def_stats = wesnoth.simulate_combat(unit, t)
                end

                table.insert(attacks, {
                    dst = { x = p.x, y = p.y },
                    src = { x = x1, y = y1 },
                    target = { x = t.x, y = t.y },
                    att_stats = att_stats,
                    def_stats = def_stats,
                    attack_hex_occupied = attack_hex_occupied
                } )
            end

            -- Put unit(s) back
            wesnoth.put_unit(x1, y1, unit)
            if unit_in_way then wesnoth.put_unit(p.x, p.y, unit_in_way) end
        end
    end

    return attacks
end

function ai_helper.get_attacks(units, cfg)
    -- Wrapper function for ai_helper.get_attacks_unit
    -- Returns the same sort of table (and cfg has the same structure), but for the attacks of several units

    local attacks = {}
    for k,u in pairs(units) do
        local attacks_unit = ai_helper.get_attacks_unit(u, cfg)

        if attacks_unit[1] then
            for i,a in ipairs(attacks_unit) do
                table.insert(attacks, a)
            end
        end
    end

    return attacks
end

function ai_helper.get_attack_map_unit(unit, cfg)
    -- Get all hexes that a unit can attack
    -- Return value is a location set, where the values are tables, containing
    --   - units: the number of units (always 1 for this function)
    --   - hitpoints: the combined hitpoints of the units
    --   - srcs: an array containing the positions of the units
    -- cfg: table with config parameters
    --  max_moves: if set use max_moves for units (this setting is always used for units on other sides)

    cfg = cfg or {}

    -- 'moves' can be either "current" or "max"
    -- For unit on current side: use "current" by default, or override by cfg.moves
    local max_moves = cfg.max_moves
    -- For unit on any other side, only max_moves=true makes sense
    if (unit.side ~= wesnoth.current.side) then max_moves = true end

    local old_moves = unit.moves
    if max_moves then unit.moves = unit.max_moves end

    local reach = {}
    reach.units = LS.create()
    reach.hitpoints = LS.create()

    local initial_reach = wesnoth.find_reach(unit, cfg)

    for i,loc in ipairs(initial_reach) do
        reach.units:insert(loc[1], loc[2], 1)
        reach.hitpoints:insert(loc[1], loc[2], unit.hitpoints)
        for x, y in H.adjacent_tiles(loc[1], loc[2]) do
            reach.units:insert(x, y, 1)
            reach.hitpoints:insert(x, y, unit.hitpoints)
        end
    end

    -- Reset unit moves
    if max_moves then unit.moves = old_moves end

    return reach
end

function ai_helper.get_attack_map(units, cfg)
    -- Get all hexes that units can attack (this is really just a wrapper function for ai_helper.get_attack_map_unit()
    -- Return value is a location set, where the values are tables, containing
    --   - units: the number of units (always 1 for this function)
    --   - hitpoints: the combined hitpoints of the units
    --   - srcs: an array containing the positions of the units
    -- cfg: table with config parameters
    --  max_moves: if set use max_moves for units (this setting is always used for units on other sides)

    local attack_map1 = {}
    attack_map1.units = LS.create()
    attack_map1.hitpoints = LS.create()

    for i,u in ipairs(units) do
        local attack_map2 = ai_helper.get_attack_map_unit(u, cfg)
        attack_map1.units:union_merge(attack_map2.units, function(x, y, v1, v2)
            return (v1 or 0) + v2
        end)
        attack_map1.hitpoints:union_merge(attack_map2.hitpoints, function(x, y, v1, v2)
            return (v1 or 0) + v2
        end)
    end

    return attack_map1
end

function ai_helper.add_next_attack_combo_level(combos, attacks)
    -- This is called from ai_helper.get_attack_combos_full() and
    -- builds up the combos for the next recursion level.
    -- It also calls the next recursion level, if possible
    -- Important: function needs to make a copy of the input array, otherwise original is changed

    -- Set up the array, if this is the first recursion level
    if (not combos) then combos = {} end

    -- Array to hold combinations for this recursion level only
    local combos_this_level = {}

    for i,a in ipairs(attacks) do
        local dst = a.dst.y + a.dst.x * 1000.  -- attack hex (src)
        local src = a.src.y + a.src.x * 1000.  -- attacker hex (dst)
        if (not combos[1]) then  -- if this is the first recursion level, set up new combos for this level
            --print('New array')
            local move = {}
            move[dst] = src
            table.insert(combos_this_level, move)
        else
            -- Otherwise, we need to go through the already existing elements in 'combos'
            -- to see if either hex, or attacker is already used; and then add new attack to each
            for j,combo in ipairs(combos) do
                local this_combo = {}  -- needed because tables are pointers, need to create a separate one
                local add_combo = true
                for d,s in pairs(combo) do
                    if (d == dst) or (s == src) then
                        add_combo = false
                        break
                    end
                    this_combo[d] = s  -- insert individual moves to a combo
                end
                if add_combo then  -- and add it into the array, if it contains only unique moves
                    this_combo[dst] = src
                    table.insert(combos_this_level, this_combo)
                end
            end
        end
    end

    local combos_next_level = {}
    if combos_this_level[1] then  -- If moves were found for this level, also find those for the next level
        combos_next_level = ai_helper.add_next_attack_combo_level(combos_this_level, attacks)
    end

    -- Finally, combine this level and next level combos
    combos_this_level = ai_helper.array_merge(combos_this_level, combos_next_level)
    return combos_this_level
end

function ai_helper.get_attack_combos_full(units, enemy)
    -- Calculate attack combination result by 'units' on 'enemy'
    -- All combinations of all units are taken into account, as well as their order
    -- This can result in a _very_ large number of possible combinations
    -- Use ai_helper.get_attack_combos() instead if order does not matter
    -- Return value:
    --   1. Attack combinations in form { dst = src }

    -- The combos are obtained by recursive call of ai_helper.add_next_attack_combo_level()

    local attacks = ai_helper.get_attacks(units)
    --print('# all attacks', #attacks)
    -- Eliminate those that are not on 'enemy'
    for i = #attacks,1,-1 do
        if (attacks[i].target.x ~= enemy.x) or (attacks[i].target.y ~= enemy.y) then
            table.remove(attacks, i)
        end
    end
    --print('# enemy attacks', #attacks)
    if (not attacks[1]) then return {} end

    -- This recursive function does all the work:
    local combos = ai_helper.add_next_attack_combo_level(combos, attacks)

    return combos
end

function ai_helper.get_attack_combos(units, enemy, cfg)
    -- Calculate attack combination result by 'units' on 'enemy'
    -- All the unit/hex combinations are considered, but without specifying the order of the
    -- attacks.  Use ai_helper.get_attack_combos_full() if order matters.
    -- cfg: A config table to be passed on to ai_helper.get_attacks
    -- Return values:
    --   1. Attack combinations in form { dst = src }
    --   2. All the attacks indexed by [dst][src]

    local attacks = ai_helper.get_attacks(units, cfg)
    --print('# all attacks', #attacks, os.clock())

    --Eliminate those that are not on 'enemy'
    for i = #attacks,1,-1 do
        if (attacks[i].target.x ~= enemy.x) or (attacks[i].target.y ~= enemy.y) then
            table.remove(attacks, i)
        end
    end
    --print('# enemy attacks', #attacks)

    if (not attacks[1]) then return {}, {} end

    -- Find all hexes adjacent to enemy that can be reached by any attacker
    -- Put this into an array that has dst as key,
    -- and array of all units (src) that can get there as value (in from x*1000+y)
    local attacks_dst_src = {}
    for i,a in ipairs(attacks) do
        local xy = a.dst.x * 1000 + a.dst.y
        if (not attacks_dst_src[xy]) then attacks_dst_src[xy] = { 0 } end  -- for attack by no unit on this hex
        table.insert(attacks_dst_src[xy], a.src.x * 1000 + a.src.y )
    end
    --DBG.dbms(attacks_dst_src)

    -- Now we set up an array of all attack combinations
    -- at this time, this includes all the 'no unit attacks this hex' elements
    -- which have a value of 0 for 'src'
    -- They need to be kept in this part, so that we get the combos that do not
    -- use the maximum amount of units possible.  They will be eliminated below.
    local attack_array = {}
    -- For all values of 'dst'
    for dst,ads in pairs(attacks_dst_src) do
        local org_array = ai_helper.table_copy(attack_array)
        attack_array = {}

        -- Go through all the values of 'src'
        for i,src in ipairs(ads) do
            -- If the array does not exist, set it up
            if (not org_array[1]) then
                local tmp = {}
                tmp[dst] = src
                table.insert(attack_array, tmp)
            else  -- otherwise, add the new dst-src pair to each element of the existing array
                for j,o in ipairs(org_array) do
                    -- but only do so if that 'src' value does not exist already
                    -- except for 0's those all need to be kept
                    local add_attack = true
                    for d,s in pairs(o) do
                        if (s == src) and (src ~=0) then
                            add_attack = false
                            break
                        end
                    end
                    -- Finally, add it to the array
                    if add_attack then
                        local tmp = ai_helper.table_copy(o)
                        tmp[dst] = src
                        table.insert(attack_array, tmp)
                    end
                end
            end
        end
    end
    --DBG.dbms(attack_array)
    --print('#attack_array before:', #attack_array)

    -- Now eliminate all the 0s
    -- Also eliminate the combo that has no attacks on any hex (all zeros)
    for i,att in ipairs(attack_array) do
        local count = 0
        for dst,src in pairs(att) do
            if (src == 0) then
                att[dst] = nil
            else
                count = count + 1
            end
        end
        -- This last step eliminates the "empty attack combo" (the one with all zeros)
        if (count == 0) then table.remove(attack_array, i) end
    end
    --print('#attack_array after:', #attack_array)
    --DBG.dbms(attack_array)

    return attack_array
end

function ai_helper.attack_combo_stats(tmp_attackers, tmp_dsts, enemy, precalc)
    -- Calculate attack combination outcomes using
    -- tmp_attackers: array of attacker units (this is done so that
    --   the units need not be found here, as likely doing it in the
    --   calling function is more efficient (because of repetition)
    -- tmp_dsts: array of the hexes (format {x, y}) from which the attackers attack
    --   must be in same order as 'attackers'
    -- enemy: the enemy being attacked
    -- precalc: an optional table of pre-calculated attack outcomes
    --   - As this is a table, we can modify it in here (add outcomes), which also modifies it in the calling function
    --
    -- Return values:
    --   - the rating for this attack combination as returned by ai_helper.attack_rating()
    --   - the sorted attackers and dsts arrays
    --   - defender combo stats: one set of stats containing the defender stats after the attack combination
    --   - att_stats: an array of stats for each attacker, in the same order as 'attackers'
    --   - def_stats: an array of defender stats for each individual attack, in the same order as 'attackers'
    --
    -- Note: the combined defender stats are approximate in some cases (e.g. attacks
    -- with slow and drain, but should be good otherwise
    -- Doing all of it right is not possible for computation time reasons

    precalc = precalc or {}

    --print()
    --print('Enemy:', enemy.id, enemy.x, enemy.y)
    --print('Attackers:')
    --for i,a in ipairs(tmp_attackers) do
    --    print('  ' .. a.id, a.x, a.y)
    --end

    -- We first simulate and rate the individual attacks
    local ratings, tmp_attacker_ratings = {}, {}
    local tmp_att_stats, tmp_def_stats = {}, {}
    for i,a in ipairs(tmp_attackers) do
        -- Initialize or use the 'precalc' table
        local enemy_ind = enemy.x * 1000 + enemy.y
        local att_ind = a.x * 1000 + a.y
        local dst_ind = tmp_dsts[i][1] * 1000 + tmp_dsts[i][2]
        if (not precalc[enemy_ind]) then precalc[enemy_ind] = {} end
        if (not precalc[enemy_ind][att_ind]) then precalc[enemy_ind][att_ind] = {} end

        if (not precalc[enemy_ind][att_ind][dst_ind]) then
            --print('Calculating attack combo stats:', enemy_ind, att_ind, dst_ind)
            tmp_att_stats[i], tmp_def_stats[i] = ai_helper.simulate_combat_loc(a, tmp_dsts[i], enemy)

            -- Get the base rating from ai_helper.attack_rating()
            local rating, dummy, tmp_ar = ai_helper.attack_rating(tmp_att_stats[i], tmp_def_stats[i], a, enemy, tmp_dsts[i])
            tmp_attacker_ratings[i] = tmp_ar
            --print('rating:', rating)

            -- But for combos, also want units with highest attack outcome uncertainties to go early
            -- So that we can change our mind in case of unfavorable outcome
            local outcome_variance = 0
            local av = tmp_def_stats[i].average_hp
            local n_outcomes = 0

            for hp,p in ipairs(tmp_def_stats[i].hp_chance) do
                if (p > 0) then
                    local dv = p * (hp - av)^2
                    --print(hp,p,av, dv)
                    outcome_variance = outcome_variance + dv
                    n_outcomes = n_outcomes + 1
                end
            end
            outcome_variance = outcome_variance / n_outcomes
            --print('outcome_variance', outcome_variance)

            -- Note that this is a variance, not a standard deviations (as in, it's squared),
            -- so it does not matter much for low-variance attacks, but takes on large values for
            -- high variance attacks.  I think that is what we want.
            rating = rating + outcome_variance

            -- If attacker has attack with 'slow' special, it should always go first
            -- This isn't quite true in reality, but can be refined later
            if ai_helper.has_weapon_special(a, "slow") then
                rating = rating + 50  -- but not quite as high as a really high CTK
            end

            --print('Final rating', rating, i)
            ratings[i] = { i, rating }

            -- Now add this attack to the precalc table, so that next time around, we don't have to do this again
            precalc[enemy_ind][att_ind][dst_ind] = {
                rating = rating,  -- Cannot use { i, rating } here, as 'i' might be different next time
                attacker_ratings = tmp_attacker_ratings[i],
                att_stats = tmp_att_stats[i],
                def_stats = tmp_def_stats[i]
            }
        else
            --print('Stats already exist')
            ratings[i] = { i, precalc[enemy_ind][att_ind][dst_ind].rating }
            tmp_attacker_ratings[i] = precalc[enemy_ind][att_ind][dst_ind].attacker_ratings
            tmp_att_stats[i] = precalc[enemy_ind][att_ind][dst_ind].att_stats
            tmp_def_stats[i] = precalc[enemy_ind][att_ind][dst_ind].def_stats
        end
    end

    -- Now sort all the arrays based on this rating
    -- This will give the order in which the individual attacks are executed
    table.sort(ratings, function(a, b) return a[2] > b[2] end)

    -- Reorder attackers, dsts and stats in this order
    local attackers, dsts, att_stats, def_stats, attacker_ratings = {}, {}, {}, {}, {}
    for i,r in ipairs(ratings) do
        attackers[i], dsts[i] = tmp_attackers[r[1]], tmp_dsts[r[1]]
        att_stats[i], def_stats[i] = tmp_att_stats[r[1]], tmp_def_stats[r[1]]
        attacker_ratings[i] = tmp_attacker_ratings[r[1]]
    end
    tmp_attackers, tmp_dsts, tmp_att_stats, tmp_def_stats, tmp_attacker_ratings = nil, nil, nil, nil, nil
    -- Just making sure that everything worked:
    --print(#attackers, #dsts, #att_stats, #def_stats)
    --for i,a in ipairs(attackers) do print(i, a.id) end
    --DBG.dbms(dsts)
    --DBG.dbms(att_stats)
    --DBG.dbms(def_stats)

    -- Now on to the calculation of the combined defender stats
    -- This method gives the right results (and is independent of attack order)
    -- for most attacks, but isn't quite right for things like slow and drain
    -- Doing it right is prohibitive in terms of calculation time though, this
    -- is an acceptable approximation

    -- Build up a hp_chance array for the combined hp_chance
    -- For the first attack, it's simply the defenders hp_chance distribution
    local hp_combo = ai_helper.table_copy(def_stats[1].hp_chance)
    -- Also get an approximate value for slowed/poisoned chance after attack combo
    -- (this is 1-slowed for calc. reasons; changed below)
    local slowed, poisoned = 1 - def_stats[1].slowed, 1 - def_stats[1].poisoned

    -- Then we go through all the other attacks
    for i = 2,#attackers do
        -- Need a temporary array of zeros for the new result (because several attacks can combine to the same HP)
        local tmp_array = {}
        for hp1,p1 in pairs(hp_combo) do tmp_array[hp1] = 0 end

        for hp1,p1 in pairs(hp_combo) do -- Note: need pairs(), not ipairs() !!
            -- If hp_combo is ~=0, "anker" the hp_chance array of the second attack here
            if (p1 > 0) then
                local dhp = hp1 - enemy.hitpoints  -- This is the offset in HP (starting point for the second attack)
                -- All percentages for the second attacks are considered, and if ~=0 offset by dhp
                for hp2,p2 in pairs(def_stats[i].hp_chance) do
                    if (p2>0) then
                        local new_hp = hp2 + dhp  -- The offset is defined to be negative
                        if (new_hp < 0) then new_hp = 0 end  -- HP can't go below 0
                        -- Also, for if the enemy has drain:
                        if (new_hp > enemy.max_hitpoints) then new_hp = enemy.max_hitpoints end
                        --print(enemy.id .. ': ' .. enemy.hitpoints .. '/' .. enemy.max_hitpoints ..':', hp1, p1, hp2, p2, dhp, new_hp)
                        tmp_array[new_hp] = tmp_array[new_hp] + p1*p2  -- New percentage is product of two individual ones
                    end
                end
            end
        end
        -- Finally, transfer result to hp_combo table for next iteration
        hp_combo = ai_helper.table_copy(tmp_array)

        -- And the slowed/poisoned percentage (this is 1-slowed for calc. reasons; changed below)
        slowed = slowed * (1 - def_stats[i].slowed)
        poisoned = poisoned * (1 - def_stats[i].poisoned)
    end
    --DBG.dbms(hp_combo)
    --print('HPC[0]', hp_combo[0])

    -- Finally, set up the combined def_stats table
    local def_stats_combo = {}
    def_stats_combo.hp_chance = hp_combo
    local av_hp = 0
    for hp,p in ipairs(hp_combo) do av_hp = av_hp + hp*p end
    def_stats_combo.average_hp = av_hp

    -- Slowed/poisoned: go from 1-value -> value
    def_stats_combo.slowed, def_stats_combo.poisoned = 1. - slowed, 1. - poisoned

    -- Get the total rating for this attack combo:
    --   = sum of all the attacker ratings and the defender rating with the final def_stats
    -- -> we need one run through attack_rating() to get the defender rating given these stats
    -- It doesn't matter which attacker and att_stats are chosen for that
    local dummy, rating = ai_helper.attack_rating(att_stats[1], def_stats_combo, attackers[1], enemy, dsts[1])
    for i,r in ipairs(attacker_ratings) do rating = rating + r end
    --print('    --> rating:', rating)

    return rating, attackers, dsts, att_stats, def_stats_combo, def_stats
end

function ai_helper.attack_rating(att_stats, def_stats, attackers, defender, dsts, cfg)
    -- Returns a common (but configurable) kind of rating for attacks
    -- Inputs:
    -- att_stats: can be a single attacker stats table, or an array of several
    -- def_stats: has to be a single defender stats table
    -- attackers: single attacker unit or table of attacker units, in same order as att_stats
    -- defender: defender unit table
    -- dsts: the attack locations, in same order as att_stats
    -- cfg: table of configurable rating parameters
    --  - own_damage_weight (1.0): ratio of rating for own damage / enemy damage
    --  - ctk_weight (0.5): rating bonus for each % point of CTK
    --  - resource_weight (0.25): rating for each gold of resources used (all the attackers)
    --  - terrain_weight (0.111): rating for each % point of terrain defense
    --  - village_bonus (25): rating bonus if attacker is on a village
    --  - defender_village_bonus (5): rating bonus if defender is on a village
    --  - xp_weight (0.2): rating for each XP (both attackers and defenders)
    --  - distance_leader_weight (1.0): rating of attack hex distance from AI leader (relative to enemy distance from leader)
    --  - occupied_hex_penalty (0.1): rating penalty if the attack hex is occupied
    --
    -- Returns:
    --   - Overall rating for the attack or attack combo
    --   - Attacker rating: this one is additive for the individual attacks in a combo
    --   - Defender rating: not additive for attack combos; needs to be calculated for the
    --     defender stats of the last attack in a combo (that works for everything except
    --     the rating whether the defender is about to level in the attack combo)

    -- Set up the rating config parameters
    cfg = cfg or {}
    local own_damage_weight = cfg.own_damage_weight or 1.0
    local ctk_weight = cfg.ctk_weight or 0.5
    local resource_weight = cfg.resource_weight or 0.25
    local terrain_weight = cfg.terrain_weight or 0.111
    local village_bonus = cfg.village_bonus or 25
    local defender_village_bonus = cfg.defender_village_bonus or 5
    local xp_weight = cfg.xp_weight or 0.2
    local distance_leader_weight = cfg.distance_leader_weight or 1.0
    local occupied_hex_penalty = cfg.occupied_hex_penalty or 0.1

    -- If att is a single stats table, make it a one-element array
    -- That way all the rest can be done in in the same way for single and combo attacks
    if att_stats.hp_chance then
        att_stats = { att_stats }
        attackers = { attackers }
        dsts = { dsts }
    end

    -- We also need the leader (well, the location at least)
    -- because if there's no other difference, prefer location _between_ the leader and the enemy
    local leader = wesnoth.get_units { side = attackers[1].side, canrecruit = 'yes' }[1]

    ---------- Collect the necessary information ----------
    ------ All the per-attacker contributions: ------
    local damage, ctd, resources_used = 0, 0, 0
    local xp_bonus = 0
    local attacker_about_to_level_bonus, defender_about_to_level_penalty = 0, 0
    local relative_distances, attacker_defenses, attackers_on_villages = 0, 0, 0
    local occupied_hexes = 0
    for i,as in ipairs(att_stats) do
        --print(attackers[i].id, as.average_hp)
        damage = damage + attackers[i].hitpoints - as.average_hp
        ctd = ctd + as.hp_chance[0]  -- Chance to die
        resources_used = resources_used + wesnoth.unit_types[attackers[i].type].cost

        -- If there's no chance to die, using unit with lots of XP is good
        -- Otherwise it's bad
        if (as.hp_chance[0] > 0) then
            xp_bonus = xp_bonus - attackers[i].experience
        else
            xp_bonus = xp_bonus + attackers[i].experience
        end

        -- The attack position (this is just for convenience)
        local x, y = dsts[i][1], dsts[i][2]

        -- Position units in between AI leader and defender
        -- This number is larger for attack hexes closer to the side leader
        relative_distances = relative_distances
            + H.distance_between(defender.x, defender.y, leader.x, leader.y)
            - H.distance_between(x, y, leader.x, leader.y)

        -- Terrain and village bonus
        attacker_defenses = attacker_defenses - wesnoth.unit_defense(attackers[i], wesnoth.get_terrain(x, y))
        local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(x, y)).village
        if is_village then
            attackers_on_villages = attackers_on_villages + 1
        end

        -- Count occupied attack hexes (which get a small rating penalty)
        -- Note: it must be checked previously that the unit on the hex can move away
        if (x ~= attackers[i].x) or (y ~= attackers[i].y) then
            if wesnoth.get_unit(x, y) then
                occupied_hexes = occupied_hexes + 1
            end
        end

        -- Will the attacker level in this attack (or likely do so?)
        local defender_level = wesnoth.unit_types[defender.type].level
        if (as.hp_chance[0] < 0.4) then
            if (attackers[i].max_experience - attackers[i].experience <= defender_level) then
                attacker_about_to_level_bonus = attacker_about_to_level_bonus + 100
            else
                if (attackers[i].max_experience - attackers[i].experience <= defender_level * 8) and (def_stats.hp_chance[0] >= 0.6) then
                    attacker_about_to_level_bonus = attacker_about_to_level_bonus + 50
                end
            end
        end

        -- Will the defender level in this attack (or likely do so?)
        local attacker_level = wesnoth.unit_types[attackers[i].type].level
        if (def_stats.hp_chance[0] < 0.6) then
            if (defender.max_experience - defender.experience <= attacker_level) then
                defender_about_to_level_penalty = defender_about_to_level_penalty + 2000
            else
                if (defender.max_experience - defender.experience <= attacker_level * 8) and (as.hp_chance[0] >= 0.4) then
                    defender_about_to_level_penalty = defender_about_to_level_penalty + 1000
                end
            end
        end
    end

    ------ All the defender-related information: ------
    local defender_damage = defender.hitpoints - def_stats.average_hp
    local ctk = def_stats.hp_chance[0]  -- Chance to kill

    -- XP bonus is positive for defender as well - want to get rid of high-XP opponents first
    -- Except if the defender will likely level up through the attack (dealt with above)
    local defender_xp_bonus = defender.experience

    local defender_cost = wesnoth.unit_types[defender.type].cost
    local defender_on_village = wesnoth.get_terrain_info(wesnoth.get_terrain(defender.x, defender.y)).village

    ---------- Now add all this together in a rating ----------
    -- We use separate attacker(s) and defender ratings, so that attack combos can be dealt with easily
    local defender_rating, attacker_rating = 0, 0

    -- Rating based on the attack outcome
    defender_rating = defender_rating + defender_damage + ctk * 100. * ctk_weight
    attacker_rating = attacker_rating - (damage + ctd * 100. * ctk_weight) * own_damage_weight

    -- Terrain and position related ratings
    attacker_rating = attacker_rating + relative_distances * distance_leader_weight
    attacker_rating = attacker_rating + attacker_defenses * terrain_weight
    attacker_rating = attacker_rating + attackers_on_villages * village_bonus
    attacker_rating = attacker_rating - occupied_hexes * occupied_hex_penalty

    -- XP-based rating
    defender_rating = defender_rating + defender_xp_bonus * xp_weight - defender_about_to_level_penalty
    attacker_rating = attacker_rating + xp_bonus * xp_weight + attacker_about_to_level_bonus

    -- Resources used (cost) of units on both sides
    -- Only the delta between ratings makes a difference -> absolute value meaningless
    -- Don't want this to be too highly rated, or single-unit attacks will always be chosen
    defender_rating = defender_rating + defender_cost * resource_weight
    attacker_rating = attacker_rating - resources_used * resource_weight

    -- Bonus (or penalty) for units on villages
    if defender_on_village then defender_rating = defender_rating + defender_village_bonus end

    local rating = defender_rating + attacker_rating
    --print('--> attack rating, defender_rating, attacker_rating:', rating, defender_rating, attacker_rating)
    return rating, defender_rating, attacker_rating
end

return ai_helper
