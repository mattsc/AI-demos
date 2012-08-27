local H = wesnoth.require "lua/helper.lua"
local W = H.set_wml_action_metatable {}
local LS = wesnoth.require "lua/location_set.lua"
local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

local ai_helper = {}

----- General helper functions ------

function ai_helper.got_1_11()
   if not wesnoth.compare_versions then return false end
   return wesnoth.compare_versions(wesnoth.game_config.version, ">=", "1.11.0-svn")
end

function ai_helper.got_exactly_1_11_0_svn()
   if not wesnoth.compare_versions then return false end
   return wesnoth.compare_versions(wesnoth.game_config.version, "==", "1.11.0-svn")
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

function ai_helper.random(min, max)
    -- Use this function as Lua's 'math.random' is not replay or MP safe

    if not max then min, max = 1, min end
    wesnoth.fire("set_variable", { name = "LUA_random", rand = string.format("%d..%d", min, max) })
    local res = wesnoth.get_variable "LUA_random"
    wesnoth.set_variable "LUA_random"
    return res
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
    -- Select a random hex out of the 
    -- This seems "inelegant", but I can't come up with another way without creating an extra array
    -- Return -1, -1 is set is empty

    local r = ai_helper.random(set:size())
    local i, xr, yr = 1, -1, -1
    set:iter( function(x, y, v)
        if (i == r) then xr, yr = x, y end
        i = i + 1
    end)

    return xr, yr
end

--------- Move related helper functions ----------

function ai_helper.get_dst_src_units(units, cfg)
    -- Get the dst_src LS for 'units'

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
    -- If units is given, use them, otherwise do it for all units on side
    
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

    -- If none of the hexes is unoccupied, use current position as default
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

    -- Otherwise, if 'ignore_units' is not set, return false if there's unit of other side,
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

    -- If this is an individual unit, turn it into and array
    if units.hitpoints then units = { units } end

    local max_rating, best_hex, best_unit = -9e99, {}, {}
    for i,u in ipairs(units) do
        -- Hexes each unit can reach
        local reach_map = ai_helper.get_reachable_unocc(u)
        reach_map:iter( function(x, y, v)
            -- Rate based un rating_function argument
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
    -- Other, configurable, parameters are given to function in 'cfg'

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
    -- Coordinates can be given as x and y components, or as a 2-element table { x, y }
    if (type(x) ~= 'number') then 
        if x[1] then
            x, y = x[1], x[2]
        else
            x, y = x.x, x.y
        end
    end

    if (x ~= unit.x) or (y ~= unit.y) then
        ai.move_full(unit, x, y)
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

    local unit_in_way = wesnoth.get_unit(x, y)
    if unit_in_way and ((unit_in_way.x ~= unit.x) or (unit_in_way.y ~= unit.y)) then
        ai_helper.move_unit_out_of_way(ai, unit_in_way, cfg)
    end

    if (x ~= unit.x) or (y ~= unit.y) then
        ai.move_full(unit, x, y)
    else
        ai.stopunit_moves(unit)
    end
end

---------- Attack related helper functions --------------

function ai_helper.simulate_combat_loc(attacker, dst, defender, weapon)
    -- Get simulate_combat results for unit 'attacker' attacking unit at 'defender'
    -- when on terrain as that at 'dst', which is of form {x,y}
    -- If 'weapon' is set (to number of attack), use that weapon (starting at 1), otherwise use best weapon

    local attacker_dst = wesnoth.copy_unit(attacker)
    attacker_dst.x, attacker_dst.y = dst[1], dst[2]

    if weapon then
        return wesnoth.simulate_combat( attacker_dst, weapon, defender)
    else
        return wesnoth.simulate_combat( attacker_dst, defender)
    end
end

function ai_helper.get_attacks_unit(unit, moves)
    -- Get all attacks a unit can do
    -- moves: if set, use this for 'moves' key, otherwise use "current"
    -- Returns {} if no attacks can be done, otherwise table with fields
    --   x, y: attack position
    --   att_loc: { x = x, y = y } of attacking unit (don't use id, could be ambiguous)
    --   def_loc: { x = x, y = y } of defending unit
    --   att_stats, def_stats: as returned by wesnoth.simulate_combat
    -- This is somewhat slow, but will hopefully replaced soon by built-in AI function

    -- Need to find reachable hexes that are
    -- 1. next to an enemy unit
    -- 2. not occupied by an allied unit (except for unit itself)
    W.store_reachable_locations { 
        { "filter", { x = unit.x, y = unit.y } },
        { "filter_location", {
            { "filter_adjacent_location", { 
                { "filter", 
                    { { "filter_side",
                        { { "enemy_of", { side = unit.side } } }
                    } }
                } 
            } },
            { "not", { 
                { "filter", { { "not", { x = unit.x, y = unit.y } } } }
            } }
        } },
        moves = moves or "current",
        variable = "tmp_locs"
    }
    local attack_loc = H.get_variable_array("tmp_locs")
    W.clear_variable { name = "tmp_locs" }
    --print("reachable attack locs:",unit.id,#attack_loc)

    -- Variable to store attacks
    local attacks = {}
    -- Current position of unit
    local x1, y1 = unit.x, unit.y

    -- Go through all attack locations
    for i,p in pairs(attack_loc) do

        -- Put unit at this position
        wesnoth.put_unit(p.x, p.y, unit)
        --print(i,' attack pos:',p.x,p.y)

        -- As there might be several attackable units from a position, need to find all those
        local targets = wesnoth.get_units {
            { "filter_side",
                { { "enemy_of", { side = unit.side } } }
            },
            { "filter_location", 
                { { "filter_adjacent_location", { x = p.x, y = p.y } } }
            }
        }
        --print('  number targets: ',#targets)

        for j,t in pairs(targets) do
            local att_stats, def_stats = wesnoth.simulate_combat(unit, t)

            table.insert(attacks, {
                x = p.x, y = p.y,
                att_loc = { x = x1, y = y1 },
                def_loc = { x = t.x, y = t.y },
                att_stats = att_stats,
                def_stats = def_stats
            } )
        end
    end

    -- Put unit back to its location
    wesnoth.put_unit(x1, y1, unit)

    return attacks
end

function ai_helper.get_attacks(units, moves)
    -- Wrapper function for ai_helper.get_attacks_unit
    -- Returns the same sort of table, but for the attacks of several units
    -- This is somewhat slow, but will hopefully replaced soon by built-in AI function

    local attacks = {}
    for k,u in pairs(units) do
        local attacks_unit = ai_helper.get_attacks_unit(u, moves)

        if attacks_unit[1] then
            for i,a in ipairs(attacks_unit) do
                table.insert(attacks, a)
            end
        end
    end

    return attacks
end

function ai_helper.get_attacks_unit_occupied(unit)
    -- Same as get_attacks_unit(), but also consider hexes that are occupied by a unit that can move away
    -- This only makes sense to be used with own units, not enemies,
    -- so it's a separate function from get_attacks-unit() and moves = 'max' does not make sense here
    -- Get all attacks a unit can do
    -- Returns {} if no attacks can be done, otherwise table with fields
    --   x, y: attack position
    --   att_loc: { x = x, y = y } of attacking unit (don't use id, could be ambiguous)
    --   def_loc: { x = x, y = y } of defending unit
    --   att_stats, def_stats: as returned by wesnoth.simulate_combat
    --   attack_hex_occupied: boolean storing whether an own unit that can move away is on the attack hex
    -- This is somewhat slow, but will hopefully replaced soon by built-in AI function

    -- Need to find reachable hexes that are
    -- 1. next to an enemy unit
    -- 2. not occupied by a unit of a different side (incl. allies)
    W.store_reachable_locations { 
        { "filter", { x = unit.x, y = unit.y } },
        { "filter_location", {
            { "filter_adjacent_location", { 
                { "filter", 
                    { { "filter_side",
                        { { "enemy_of", { side = unit.side } } }
                    } }
                } 
            } },
            { "not", { 
                { "filter", { { "not", { side = unit.side } } } }
            } }
        } },
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

        -- In this case, units on the side of 'unit' can still be at the attack hex.
        -- Only consider the hex if that unit can move away
        local can_move_away = true  -- whether a potential unit_in_way can move away

        local unit_in_way = wesnoth.get_unit(p.x, p.y)
        -- If unit_in_way is the unit itself, that doesn't count
        if unit_in_way and (unit_in_way.x == unit.x) and (unit_in_way.y == unit.y) then unit_in_way = nil end

        -- If there's a unit_in_way, and it is not the unit itself, check whether it can move away
        if unit_in_way and ((unit_in_way.x ~= unit.x) or (unit_in_way.y ~= unit.y)) then
            local move_away = ai_helper.get_reachable_unocc(unit_in_way)
            if (move_away:size() <= 1) then can_move_away = false end
            --print('Can move away:', unit_in_way.id, can_move_away)
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
                { "filter_location", 
                    { { "filter_adjacent_location", { x = p.x, y = p.y } } }
                }
            }
            --print('  number targets: ',#targets)

            local attack_hex_occupied = false
            if unit_in_way then attack_hex_occupied = true end

            for j,t in pairs(targets) do
                local att_stats, def_stats = wesnoth.simulate_combat(unit, t)

                table.insert(attacks, {
                    x = p.x, y = p.y,
                    att_loc = { x = x1, y = y1 },
                    def_loc = { x = t.x, y = t.y },
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

function ai_helper.get_attacks_occupied(units)
    -- Wrapper function for ai_helper.get_attacks_unit_occupied
    -- Returns the same sort of table, but for the attacks of several units
    -- This is somewhat slow, but will hopefully replaced soon by built-in AI function

    local attacks = {}
    for k,u in pairs(units) do
        local attacks_unit = ai_helper.get_attacks_unit_occupied(u)

        if attacks_unit[1] then
            for i,a in ipairs(attacks_unit) do
                table.insert(attacks, a)
            end
        end
    end

    return attacks
end

function ai_helper.get_reachable_attack_map(unit, cfg)
    -- Get all hexes that a unit can attack
    -- Return value is a location set, where the value is 1 for each hex that can be attacked
    -- cfg: parameters to wesnoth.find_reach, such as {additional_turns = 1}
    -- additionally, {moves = 'max'} can be set inside cfg, which sets unit MP to max_moves before calculation

    cfg = cfg or {}

    local old_moves = unit.moves
    if (cfg.moves == 'max') then unit.moves = unit.max_moves end

    local reach = LS.create()
    local initial_reach = wesnoth.find_reach(unit, cfg)

    local return_value = 1
    if (cfg.return_value == 'hitpoints') then return_value = unit.hitpoints end

    for i,loc in ipairs(initial_reach) do
        reach:insert(loc[1], loc[2], return_value)
        for x, y in H.adjacent_tiles(loc[1], loc[2]) do
            reach:insert(x, y, return_value)
        end
    end

    -- Reset unit moves (can be done whether it was changed or not)
    unit.moves = old_moves

    return reach
end

function ai_helper.attack_map(units, cfg)
    -- Attack map: number of units which can attack each hex
    -- Return value is a location set, where the value is the 
    --   number of units that can attack a hex
    -- cfg: parameters to wesnoth.find_reach, such as {additional_turns = 1}
    -- additional, {moves = 'max'} can be set inside cfg, which sets unit MP to max_moves before calculation

    local AM = LS.create()  -- attack map

    for i,u in ipairs(units) do
        local reach = ai_helper.get_reachable_attack_map(u, cfg)
        AM:union_merge(reach, function(x, y, v1, v2)
            return (v1 or 0) + v2
        end)
    end
    --ai_helper.put_labels(AM)
    --W.message {speaker="narrator", message="Attack map" }

    return AM
end

function ai_helper.add_next_attack_level(combos, attacks)
    -- Build up the combos for this recursion level, and call the next recursion level, if possible
    -- Need to build up a copy of the array, otherwise original is changed

    -- Set up the array, if this is the first recursion level
    if (not combos) then combos = {} end

    -- Array to hold combinations for this recursion level onlu
    local combos_this_level = {}

    for i,a in ipairs(attacks) do
        local hex_xy = a.y + a.x * 1000.  -- attack hex (src)
        local att_xy = a.att_loc.y + a.att_loc.x * 1000.  -- attacker hex (dst)
        if (not combos[1]) then  -- if this is the first recursion level, set up new combos for this level
            --print('New array') 
            table.insert(combos_this_level, {{ h = hex_xy, a = att_xy }})
        else
            -- Otherwise, we need to go through the already existing elements in 'combos'
            -- to see if either hex, or attacker is already used; and then add new attack to each
            for j,combo in ipairs(combos) do
                local this_combo = {}  -- needed because tables are pointers, need to create a separate one
                local add_combo = true
                for k,move in ipairs(combo) do
                    if (move.h == hex_xy) or (move.a == att_xy) then
                        add_combo = false
                        break
                    end
                    table.insert(this_combo, move)  -- insert individual moves to a combo
                end
                if add_combo then  -- and add it into the array, if it contains only unique moves
                    table.insert(this_combo, { h = hex_xy, a = att_xy })
                    table.insert(combos_this_level, this_combo)
                end
            end
        end
    end

    local combos_next_level = {}
    if combos_this_level[1] then  -- If moves were found for this level, also find those for the next level
        combos_next_level = ai_helper.add_next_attack_level(combos_this_level, attacks)
    end

    -- Finally, combine this level and next level combos
    combos_this_level = ai_helper.array_merge(combos_this_level, combos_next_level)
    return combos_this_level
end

function ai_helper.get_attack_combos(units, enemy)
    -- Calculate attack combination result by 'units' on 'enemy'
    -- Returns an array similar to that given by ai.get_attacks
    -- All combinations of all units are taken into account, as well as their order
    -- This can result in a _very_ large number of possible combinations
    -- Use ai_helper.get_attack_combos_no_order() instead if order does not matter

    -- The combos are obtained by recursive call of ai_helper.add_next_attack_level()

    local attacks = ai_helper.get_attacks(units)
    --print('# all attacks', #attacks)
    -- Eliminate those that are not on 'enemy'
    for i = #attacks,1,-1 do
        if (attacks[i].def_loc.x ~= enemy.x) or (attacks[i].def_loc.y ~= enemy.y) then
            table.remove(attacks, i)
        end
    end
    --print('# enemy attacks', #attacks)
    if (not attacks[1]) then return {} end

    -- The following is not needed any more
    --local hexes = LS.create()
    --for x,y in H.adjacent_tiles(enemy.x, enemy.y) do
    --    for i,a in ipairs(attacks) do
    --        if (a.x == x) and (a.y == y) then
    --            hexes:insert(x, y)
    --        end
    --    end
    --end
    --DBG.dbms(hexes)

    -- This recursive function does all the work:
    local combos = ai_helper.add_next_attack_level(combos, attacks)

    -- Output of all possible attack combinations:
    --for i,c in ipairs(combos) do
    --    local str = ''
    --    for j,m in ipairs(c) do
    --        str = str .. '   ' .. m.a .. '->' .. m.h
    --    end
    --    print(str)
    --end
    --print(#combos)

    return combos
end

function ai_helper.get_attack_combos_no_order(units, enemy)
    -- Calculate attack combination result by 'units' on 'enemy'
    -- Returns an array similar to that given by ai.get_attacks
    -- Only the combinations of which unit from which hex are considered, but not in which order the
    -- attacks are done
    -- Return values: 
    --   1. Attack combinations in form { dst = src }
    --   2. All the attacks indexed by [dst][src]

    local attacks = ai_helper.get_attacks_occupied(units)
    --print('# all attacks', #attacks)
    --Eliminate those that are not on 'enemy'
    for i = #attacks,1,-1 do
        if (attacks[i].def_loc.x ~= enemy.x) or (attacks[i].def_loc.y ~= enemy.y) then
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
        local xy = a.x * 1000 + a.y
        if (not attacks_dst_src[xy]) then attacks_dst_src[xy] = { 0 } end  -- for attack by no unit on this hex
        table.insert(attacks_dst_src[xy], a.att_loc.x * 1000 + a.att_loc.y )
    end
    --DBG.dbms(attacks_dst_src)

    -- Now we set up an array of all attack combinations
    -- at this time, this includes all the 'no unit attacks this hex' elements
    local attack_array = {}
    for dst,ads in pairs(attacks_dst_src) do
        --print(dst, ads)

        local org_array = ai_helper.table_copy(attack_array)
        attack_array = {}

        for i,src in ipairs(ads) do
            if (not org_array[1]) then
                local tmp = {}
                tmp[dst] = src
                table.insert(attack_array, tmp)
            else
                for j,o in ipairs(org_array) do
                    local tmp = ai_helper.table_copy(o)
                    tmp[dst] = src
                    table.insert(attack_array, tmp)
                end
            end
        end
    end
    --DBG.dbms(attack_array)
    --print('#attack_array before:', #attack_array)

    -- Now eliminate all that have same the unit on different hexes
    -- Also eliminate the combo that has no attacks on any hex (all zeros)
    -- Could be put into the loop above, but for simplicity, I'm keeping it here for now.

    local combos = {}
    for i,att in ipairs(attack_array) do
        -- We check for same units on different hexes by summing up all
        -- dst and src terms in two ways: simple sum, and sum of unique terms only
        -- Only if those are equal is the combo kept
        -- Also, zeros are eliminated in this step

        local sum_key, sum_value = 0, 0
        local tmp = {}
        for dst,src in pairs(att) do
            if (src == 0) then 
                att[dst] = nil
            else
                tmp[src] = src  -- no typo!!
                sum_value = sum_value + src
            end
        end

        for k,v in pairs(tmp) do
            sum_key = sum_key + k
        end
        --print(i,sum_key,sum_value)

        if (sum_key == sum_value) and (sum_key ~= 0) then
            table.insert(combos, att)
        end
    end
    --print('#combos after:', #combos)
    --DBG.dbms(combos)

    -- Finally, we set up a slightly different attacks_dst_src
    -- It's a double array with keys [dst][src] and contains the individual attacks
    -- This is for easy indexing later, and is returned as a second argument by the function
    local attacks_dst_src = {}
    for i,a in ipairs(attacks) do
        local xy_dst = a.x * 1000 + a.y
        local xy_src = a.att_loc.x * 1000 + a.att_loc.y

        if (not attacks_dst_src[xy_dst]) then attacks_dst_src[xy_dst] = { } end  -- for attack by no unit on this hex
        attacks_dst_src[xy_dst][xy_src] = a
    end
    --DBG.dbms(attacks_dst_src)

    return combos, attacks_dst_src
end

function ai_helper.attack_combo_stats(attackers, dsts, enemy)
    -- Calculate attack combination outcomes using
    -- attackers: array of attacker units (this is done so that
    --   the units need not be found here, as likely doing it in the
    --   calling function is more efficient (because of repetition)
    -- dsts: array of the hexes (format {x, y}) from which the attackers attack
    --   must be in same order as 'attackers'
    -- enemy: the enemy being attacked
    --
    -- Return values: see end of this function for explanations
    --
    -- Note: this whole thing is not correct for the hp_chance distribution,
    -- but chance_to_kill and average_hp should be approx. right

    -- For large number of attackers, we cannot go through all combinations (would take too long)
    --> Rate individual attacks first, and execute in that order
    local ratings = {}

    for i,a in ipairs(attackers) do
        local att_stats, def_stats = ai_helper.simulate_combat_loc(a, dsts[i], enemy)
        --DBG.dbms(att_stats)

        -- Damage done to own unit is bad
        local rating = att_stats.average_hp - a.hitpoints
        -- Damage done to enemy is good
        local rating = rating + enemy.hitpoints - def_stats.average_hp

        -- Chance to kill own unit is very bad
        rating = rating - att_stats.hp_chance[0] * 50
        -- Chance to kill enemy is very good
        rating = rating + def_stats.hp_chance[0] * 50

        --print(i, a.id, att_stats.average_hp, def_stats.average_hp, '  -->', rating)
        ratings[i] = { i, rating }
    end
    --DBG.dbms(ratings)

    -- Sort by rating
    table.sort(ratings, function(a, b) return a[2] > b[2] end)
    --DBG.dbms(ratings)

    -- Reorder attackers, dsts in this order
    local sorted_attackers, sorted_dsts = {}, {}
    for i,r in ipairs(ratings) do
        sorted_attackers[i], sorted_dsts[i] = attackers[r[1]], dsts[r[1]]
    end
    attackers, dsts, ratings = nil, nil, nil

    -- Now we calculate the attack combo stats
    -- This currently only takes damage into account, not poisoning etc.
    -- (will wait for 1.11 to do that)
    local enemy_hitpoints = enemy.hitpoints

    local combo_att_stats, combo_def_stats = {}, {}
    for i,attacker in ipairs(sorted_attackers) do
        local dst = sorted_dsts[i]
        --print(i, attacker.id, dst[1], dst[2])

        local att_stats, def_stats = ai_helper.simulate_combat_loc(attacker, dst, enemy)

        --print('  before:', enemy.hitpoints)
        enemy.hitpoints = def_stats.average_hp
        --print('  after: ', enemy.hitpoints, def_stats.hp_chance[0])

        -- For the enemy, we simply take the last stats
        combo_def_stats = def_stats

        -- For the attackers, we build up an array (in the same order as the attackers array)
        combo_att_stats[i] = att_stats
    end
    -- Reset the enemy's hitpoints
    enemy.hitpoints = enemy_hitpoints

    -- Finally, we return:
    -- - the sorted attackers and dsts arrays
    -- - defender stats: one set of stats
    -- - attacker_stats: an array of stats for each attacker, in the same order as 'attackers'
    return sorted_attackers, sorted_dsts, combo_def_stats, combo_att_stats
end

return ai_helper
