local H = wesnoth.require "lua/helper.lua"
local W = H.set_wml_action_metatable {}
local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
local FGUI = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_utils_incremental.lua"
local FCFG = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_config.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local fred_utils = {}

function fred_utils.get_fgumap_value(map, x, y, key)
    return (map[x] and map[x][y] and map[x][y][key])
end

function fred_utils.set_fgumap_value(map, x, y, key, value)
    if (not map[x]) then map[x] = {} end
    if (not map[x][y]) then map[x][y] = {} end
    map[x][y][key] = value
end

function fred_utils.fgumap_add(map, x, y, key, value)
    local old_value = fred_utils.get_fgumap_value(map, x, y, key) or 0
    fred_utils.set_fgumap_value(map, x, y, key, old_value + value)
end

function fred_utils.fgumap_iter(map)
    function each_hex(state)
        while state.x ~= nil do
            local child = map[state.x]
            state.y = next(child, state.y)
            if state.y == nil then
                state.x = next(map, state.x)
            else
                return state.x, state.y, child[state.y]
            end
        end
    end

    return each_hex, { x = next(map) }
end

function fred_utils.fgumap_normalize(map, key)
    local mx
    for _,_,data in fred_utils.fgumap_iter(map) do
        if (not mx) or (data[key] > mx) then
            mx = data[key]
        end
    end
    for _,_,data in fred_utils.fgumap_iter(map) do
        data[key] = data[key] / mx
    end
end

function fred_utils.fgumap_blur(map, key)
    for x,y,data in fred_utils.fgumap_iter(map) do
        local blurred_data = data[key]
        if blurred_data then
            local count = 1
            local adj_weight = 0.5
            for xa,ya in H.adjacent_tiles(x, y) do
                local value = fred_utils.get_fgumap_value(map, xa, ya, key)
                if value then
                    blurred_data = blurred_data + value * adj_weight
                   count = count + adj_weight
                end
            end
            fred_utils.set_fgumap_value(map, x, y, 'blurred_' .. key, blurred_data / count)
        end
    end
end

function fred_utils.weight_s(x, exp)
    -- S curve weighting of a variable that is meant as a fraction of a total.
    -- Thus, @x for the most part varies from 0 to 1, but does continues smoothly
    -- outside those ranges
    --
    -- Properties independent of @exp:
    --   f(0) = 0
    --   f(0.5) = 0.5
    --   f(1) = 1

    -- Examples for different exponents:
    -- exp:   0.000  0.100  0.200  0.300  0.400  0.500  0.600  0.700  0.800  0.900  1.000
    -- 0.50:  0.000  0.053  0.113  0.184  0.276  0.500  0.724  0.816  0.887  0.947  1.000
    -- 0.67:  0.000  0.069  0.145  0.229  0.330  0.500  0.670  0.771  0.855  0.931  1.000
    -- 1.00:  0.000  0.100  0.200  0.300  0.400  0.500  0.600  0.700  0.800  0.900  1.000
    -- 1.50:  0.000  0.142  0.268  0.374  0.455  0.500  0.545  0.626  0.732  0.858  1.000
    -- 2.00:  0.000  0.180  0.320  0.420  0.480  0.500  0.520  0.580  0.680  0.820  1.000

    local weight
    if (x >= 0.5) then
        weight = 0.5 + ((x - 0.5) * 2)^exp / 2
    else
        weight = 0.5 - ((0.5 - x) * 2)^exp / 2
    end

    return weight
end

function fred_utils.print_weight_s(exp)
    local s1, s2 = '', ''
    for i=-5,15 do
        local x = 0.1 * i
        y = fred_utils.weight_s(x, exp)
        s1 = s1 .. string.format("%5.3f", x) .. '  '
        s2 = s2 .. string.format("%5.3f", y) .. '  '
    end
    print(s1)
    print(s2)
end

function fred_utils.get_unit_time_of_day_bonus(alignment, is_fearless, lawful_bonus)
    local multiplier = 1
    if (lawful_bonus ~= 0) then
        if (alignment == 'lawful') then
            multiplier = (1 + lawful_bonus / 100.)
        elseif (alignment == 'chaotic') then
            multiplier = (1 - lawful_bonus / 100.)
        elseif (alignment == 'liminal') then
            multipler = (1 - math.abs(lawful_bonus) / 100.)
        end
    end

    if is_fearless and (multiplier < 1) then
        multiplier = 1
    end

    return multiplier
end

function fred_utils.unit_value(unit_info)
    -- Get a gold-equivalent value for the unit

    local xp_weight = FCFG.get_cfg_parm('xp_weight')

    local unit_value = unit_info.cost

    -- If this is the side leader, make damage to it much more important
    if unit_info.canrecruit and (unit_info.side == wesnoth.current.side) then
        local leader_weight = FCFG.get_cfg_parm('leader_weight')
        unit_value = unit_value * leader_weight
    end

    -- Being closer to leveling makes the unit more valuable, proportional to
    -- the difference between the unit and the leveled unit
    local cost_factor = 1.5
    if unit_info.advances_to then
        local advanced_cost = wesnoth.unit_types[unit_info.advances_to].cost
        cost_factor = advanced_cost / unit_info.cost
    end

    local xp_diff = unit_info.max_experience - unit_info.experience

    -- Square so that a few XP don't matter, but being close to leveling is important
    -- Units very close to leveling are considered even more valuable than leveled unit
    local xp_bonus
    if (xp_diff <= 1) then
        xp_bonus = 1.33
    elseif (xp_diff <= 8) then
        xp_bonus = 1.2
    else
        xp_bonus = (unit_info.experience / (unit_info.max_experience - 6))^2
    end

    unit_value = unit_value * (1. + xp_bonus * (cost_factor - 1) * xp_weight)

    --print('fred_utils.unit_value:', unit_info.id, unit_value, xp_bonus, xp_diff)

    return unit_value
end

function fred_utils.unit_base_power(unit_info)
    -- Use sqrt() here so that just missing a few HP does not matter much
    local hp_mod = fred_utils.weight_s(unit_info.hitpoints / unit_info.max_hitpoints, 0.67)

    local power = unit_info.max_damage
    power = power * hp_mod

    return power
end

function fred_utils.unit_current_power(unit_info)
    local power = fred_utils.unit_base_power(unit_info)
    power = power * unit_info.tod_mod

    return power
end

function fred_utils.unit_terrain_power(unit_info, x, y, move_data)
    local power = fred_utils.unit_current_power(unit_info)

    local defense = FGUI.get_unit_defense(move_data.unit_copies[unit_info.id], x, y, move_data.defense_maps)
    power = power * defense

    return power
end

function fred_utils.unittype_base_power(unit_type)
    local unittype_info = fred_utils.single_unit_info(wesnoth.unit_types[unit_type])
    -- Need to set hitpoints manually
    unittype_info.hitpoints = unittype_info.max_hitpoints

    return fred_utils.unit_base_power(unittype_info)
end

function fred_utils.moved_toward_zone(unit_copy, zone_cfgs, side_cfgs)
    --print(unit_copy.id, unit_copy.x, unit_copy.y)

    local start_hex = side_cfgs[unit_copy.side].start_hex

    local to_zone_id, score
    for zone_id,cfg in pairs(zone_cfgs) do
        for _,center_hex in ipairs(cfg.center_hexes) do
            local _,cost_new = wesnoth.find_path(unit_copy, center_hex[1], center_hex[2], { ignore_units = true })

            local old_hex = { unit_copy.x, unit_copy.y }
            unit_copy.x, unit_copy.y = start_hex[1], start_hex[2]

            local _,cost_start = wesnoth.find_path(unit_copy, center_hex[1], center_hex[2], { ignore_units = true })

            unit_copy.x, unit_copy.y = old_hex[1], old_hex[2]

            local rating = cost_start - cost_new
            -- As a tie breaker, prefer zone that is originally farther away
            rating = rating + cost_start / 1000

            --print('  ' .. zone_id, cost_start, cost_new, rating)

            if (not score) or (rating > score) then
               to_zone_id, score = zone_id, rating
            end
        end
    end

    return to_zone_id
end

function fred_utils.smooth_cost_map(unit_proxy, loc, is_inverse_map)
    -- Smooth means that it does not add discontinuities for not having enough
    -- MP left to enter certain terrain at the end of a turn. This is done by setting
    -- moves and max_moves to 98 (99 being the move cost for impassable terrain).
    -- Thus, there could still be some such effect for very long paths, but this is
    -- good enough for all practical purposes.
    --
    -- Returns an FGU_map with the cost (key: 'cost')
    --
    -- INPUTS:
    --  @unit_proxy: use the proxy here, because it might have already been extracted
    --     in the calling function (to save time)
    --  @loc (optional): the hex from where to calculate the cost map. If omitted, use
    --     the current location of the unit
    --  @is_inverse_map (optional): if true, calculate the inverse map, that is, the
    --     move cost for moving toward @loc, rather than away from it. These two are
    --     almost the same, except for the asymmetry of entering the two extreme hexes
    --     of any path.

    local old_loc, uiw
    if loc and ((loc[1] ~= unit_proxy.x) or (loc[2] ~= unit_proxy.y)) then
        uiw = wesnoth.get_unit(loc[1], loc[2])
        if uiw then wesnoth.extract_unit(uiw) end
        old_loc = { unit_proxy.x, unit_proxy.y }
        H.modify_unit(
            { id = unit_proxy.id} ,
            { x = loc[1], y = loc[2] }
        )
    end
    local old_moves, old_max_moves = unit_proxy.moves, unit_proxy.max_moves
    H.modify_unit(
        { id = unit_proxy.id} ,
        { moves = 98, max_moves = 98 }
    )

    local cm = wesnoth.find_cost_map(unit_proxy.x, unit_proxy.y, { ignore_units = true })

    H.modify_unit(
        { id = unit_proxy.id},
        { moves = old_moves, max_moves = old_max_moves }
    )
    if old_loc then
        H.modify_unit(
            { id = unit_proxy.id} ,
            { x = old_loc[1], y = old_loc[2] }
        )
        if uiw then wesnoth.put_unit(uiw) end
    end

    local movecost_0
    if is_inverse_map then
        movecost_0 = wesnoth.unit_movement_cost(unit_proxy, wesnoth.get_terrain(loc[1], loc[2]))
    end

    local cost_map = {}
    for _,cost in pairs(cm) do
        local x, y, c = cost[1], cost[2], cost[3]
        if (c > -1) then
            if is_inverse_map then
                movecost = wesnoth.unit_movement_cost(unit_proxy, wesnoth.get_terrain(x, y))
                c = c + movecost_0 - movecost
            end

            fred_utils.set_fgumap_value(cost_map, cost[1], cost[2], 'cost', c)
        end
    end

    if false then
        DBG.show_fgumap_with_message(cost_map, 'cost', 'cost_map', unit_proxy.id)
    end

    return cost_map
end

function fred_utils.get_leader_distance_map(zone_cfgs, side_cfgs, move_data)
    local leader_loc, enemy_leader_loc
    for side,cfg in ipairs(side_cfgs) do
        if (side == wesnoth.current.side) then
            leader_loc = cfg.start_hex
        else
            enemy_leader_loc = cfg.start_hex
        end
    end

    -- Need a map with the distances to the enemy and own leaders
    local leader_cx, leader_cy = AH.cartesian_coords(leader_loc[1], leader_loc[2])
    local enemy_leader_cx, enemy_leader_cy = AH.cartesian_coords(enemy_leader_loc[1], enemy_leader_loc[2])

    local dist_btw_leaders = math.sqrt( (enemy_leader_cx - leader_cx)^2 + (enemy_leader_cy - leader_cy)^2 )

    local leader_distance_map = {}
    local width, height = wesnoth.get_map_size()
    for x = 1,width do
        for y = 1,height do
            local cx, cy = AH.cartesian_coords(x, y)

            local leader_dist = math.sqrt( (leader_cx - cx)^2 + (leader_cy - cy)^2 )
            local enemy_leader_dist = math.sqrt( (enemy_leader_cx - cx)^2 + (enemy_leader_cy - cy)^2 )

            if (not leader_distance_map[x]) then leader_distance_map[x] = {} end
            leader_distance_map[x][y] = {
                my_leader_distance = leader_dist,
                enemy_leader_distance = enemy_leader_dist,
                distance = (leader_dist - enemy_leader_dist) / 2
            }

        end
    end

    -- Enemy leader distance maps. These are calculated using wesnoth.find_cost_map() for
    -- each unit type from the start hex of the enemy leader.
    -- TODO: Doing this by unit type may cause problems once Fred can play factions
    -- with unit types that have different variations (i.e. Walking Corpses). Fix later.
    local enemy_leader_distance_maps = {}
    for zone_id,cfg in pairs(zone_cfgs) do
        enemy_leader_distance_maps[zone_id] = {}

        local old_terrain = {}
        local avoid_locs = wesnoth.get_locations { { "not", cfg.ops_slf  } }
        for _,avoid_loc in ipairs(avoid_locs) do
            table.insert(old_terrain, {avoid_loc[1], avoid_loc[2], wesnoth.get_terrain(avoid_loc[1], avoid_loc[2])})
            wesnoth.set_terrain(avoid_loc[1], avoid_loc[2], "Xv")
        end

        for id,unit_loc in pairs(move_data.my_units) do
            local typ = move_data.unit_infos[id].type -- can't use type, that's reserved

            if (not enemy_leader_distance_maps[zone_id][typ]) then
                local unit_proxy = wesnoth.get_unit(unit_loc[1], unit_loc[2])
                enemy_leader_distance_maps[zone_id][typ] = fred_utils.smooth_cost_map(unit_proxy, enemy_leader_loc, true)
            end
        end

        for _,terrain in ipairs(old_terrain) do
            wesnoth.set_terrain(terrain[1], terrain[2], terrain[3])
        end
        -- The above procedure unsets village ownership
        for x,y,data in fred_utils.fgumap_iter(move_data.village_map) do
            if (data.owner > 0) then
                wesnoth.set_village_owner(x, y, data.owner)
            end
        end
    end

    -- Also need this for the full map
    enemy_leader_distance_maps['all_map'] = {}
    for id,unit_loc in pairs(move_data.my_units) do
        local typ = move_data.unit_infos[id].type -- can't use type, that's reserved

        if (not enemy_leader_distance_maps['all_map'][typ]) then
            local unit_proxy = wesnoth.get_unit(unit_loc[1], unit_loc[2])
            enemy_leader_distance_maps['all_map'][typ] = fred_utils.smooth_cost_map(unit_proxy, enemy_leader_loc, true)
        end
    end

    return leader_distance_map, enemy_leader_distance_maps
end

function fred_utils.single_unit_info(unit_proxy)
    -- Collects unit information from proxy unit table @unit_proxy into a Lua table
    -- so that it is accessible faster.
    -- Note: Even accessing the directly readable fields of a unit proxy table
    -- is slower than reading from a Lua table; not even talking about unit_proxy.__cfg.
    --
    -- This can also be used on a unit type entry from wesnoth.unit_types, but in that
    -- case not all fields will be populated, of course, and anything depending on
    -- traits and the like will not necessarily be correct for the individual unit
    --
    -- Important: this is slow, so it should only be called once at the  beginning
    -- of each move, but it does need to be redone after each move, as it contains
    -- information like HP and XP (or the unit might have level up or been changed
    -- in an event).
    --
    -- Note: unit location information is NOT included
    -- See above for the format and type of information included.

    local unit_cfg = unit_proxy.__cfg

    local single_unit_info = {
        id = unit_proxy.id,
        canrecruit = unit_proxy.canrecruit,
        side = unit_proxy.side,

        moves = unit_proxy.moves,
        max_moves = unit_proxy.max_moves,
        hitpoints = unit_proxy.hitpoints,
        max_hitpoints = unit_proxy.max_hitpoints,
        experience = unit_proxy.experience,
        max_experience = unit_proxy.max_experience,

        type = unit_proxy.type,
        alignment = unit_cfg.alignment,
        cost = unit_cfg.cost,
        level = unit_cfg.level
    }

    -- Pick the first of the advances_to types, nil when there is none
    single_unit_info.advances_to = unit_proxy.advances_to[1]

    -- Include the ability type, such as: hides, heals, regenerate, skirmisher (set up as 'hides = true')
    single_unit_info.abilities = {}
    local abilities = H.get_child(unit_proxy.__cfg, "abilities")
    if abilities then
        for _,ability in ipairs(abilities) do
            single_unit_info.abilities[ability[1]] = true
        end
    end

    -- Information about the attacks indexed by weapon number,
    -- including specials (e.g. 'poison = true')
    single_unit_info.attacks = {}
    local max_damage = 0
    for attack in H.child_range(unit_cfg, 'attack') do
        -- Extract information for specials; we do this first because some
        -- custom special might have the same name as one of the default scalar fields
        local a = {}
        for special in H.child_range(attack, 'specials') do
            for _,sp in ipairs(special) do
                if (sp[1] == 'damage') then  -- this is 'backstab'
                    if (sp[2].id == 'backstab') then
                        a.backstab = true
                    else
                        if (sp[2].id == 'charge') then a.charge = true end
                    end
                else
                    -- magical, marksman
                    if (sp[1] == 'chance_to_hit') then
                        a[sp[2].id] = true
                    else
                        a[sp[1]] = true
                    end
                end
            end
        end

        -- Now extract the scalar (string and number) values from attack
        for k,v in pairs(attack) do
            if (type(v) == 'number') or (type(v) == 'string') then
                a[k] = v
            end
        end

        table.insert(single_unit_info.attacks, a)

        -- TODO: potentially use FAU.get_total_damage_attack for this later, but for
        -- the time being these are too different, and have too different a purpose.
        total_damage = a.damage * a.number

        -- Just use blanket damage for poison and slow for now; might be refined later
        if a.poison then total_damage = total_damage + 8 end
        if a.slow then total_damage = total_damage + 4 end

        -- Also give some bonus for drain and backstab, but not to the full extent
        -- of what they can achieve
        if a.drains then total_damage = total_damage * 1.25 end
        if a.backstab then total_damage = total_damage * 1.33 end

        if (total_damage > max_damage) then
            max_damage = total_damage
        end
    end
    single_unit_info.max_damage = max_damage

    -- Time of day modifier: done here once so that it works on unit types also.
    -- It is repeated below if a unit is passed, to take the fearless trait into account.
    single_unit_info.tod_mod = fred_utils.get_unit_time_of_day_bonus(single_unit_info.alignment, false, wesnoth.get_time_of_day().lawful_bonus)


    -- The following can only be done on a real unit, not on a unit type
    if (unit_proxy.x) then
        single_unit_info.status = {}
        local status = H.get_child(unit_cfg, "status")
        for k,_ in pairs(status) do
            single_unit_info.status[k] = true
        end


        single_unit_info.traits = {}
        local mods = H.get_child(unit_cfg, "modifications")
        for trait in H.child_range(mods, 'trait') do
            single_unit_info.traits[trait.id] = true
        end


        -- Now we do this again, using the correct value for the fearless trait
        single_unit_info.tod_mod = fred_utils.get_unit_time_of_day_bonus(single_unit_info.alignment, single_unit_info.traits.fearless, wesnoth.get_time_of_day().lawful_bonus)

        -- Define what "good terrain" means for a unit
        local defense = H.get_child(unit_proxy.__cfg, "defense")

        -- Get the hit chances for all terrains and sort (best = lowest hit chance first)
        local hit_chances = {}
        for _,hit_chance in pairs(defense) do
            table.insert(hit_chances, { hit_chance = math.abs(hit_chance) })
        end
        table.sort(hit_chances, function(a, b) return a.hit_chance < b.hit_chance end)

        -- As "normal" we use the hit chance on "flat equivalent" terrain.
        -- That means on flat for most units, on cave for dwarves etc.
        -- and on shallow water for mermen, nagas etc.
        -- Use the best of those
        local flat_hc = math.min(defense.flat, defense.cave, defense.shallow_water)
        --print('best hit chance on flat, cave, shallow water:', flat_hc)
        --print(defense.flat, defense.cave, defense.shallow_water)

        -- Good terrain is now defined as 10% lesser hit chance than that, except
        -- when this is better than the third best terrain for the unit. An example
        -- are ghosts, which have 50% on all terrains.
        -- I have tested this for most mainline level 1 units and it seems to work pretty well.
        local good_terrain_hit_chance = flat_hc - 10
        if (good_terrain_hit_chance < hit_chances[3].hit_chance) then
            good_terrain_hit_chance = flat_hc
        end
        --print('good_terrain_hit_chance', good_terrain_hit_chance)

        single_unit_info.good_terrain_hit_chance = good_terrain_hit_chance / 100.


        -- Resistances to the 6 default attack types
        local attack_types = { "arcane", "blade", "cold", "fire", "impact", "pierce" }
        single_unit_info.resistances = {}
        for _,attack_type in ipairs(attack_types) do
            single_unit_info.resistances[attack_type] = wesnoth.unit_resistance(unit_proxy, attack_type) / 100.
        end
    end

    return single_unit_info
end

function fred_utils.get_unit_hex_combos(dst_src, get_best_combo)
    -- Recursively find all combinations of distributing
    -- units on hexes. The number of units and hexes does not have to be the same.
    -- @dst_src lists all units which can reach each hex in format:
    --  [1] = {
    --      [1] = { src = 17028 },
    --      [2] = { src = 16027 },
    --      [3] = { src = 15027 },
    --      dst = 18025
    --  },
    --  [2] = {
    --      [1] = { src = 17028 },
    --      [2] = { src = 16027 },
    --      dst = 20026
    --  },
    --
    -- OPTIONAL INPUTS:
    --  @get_best_combo: find the highest rated combo; in this case, @dst_src needs to
    --    contain a rating key:
    --  [2] = {
    --      [1] = { src = 17028, rating = 0.91 },
    --      [2] = { src = 16027, rating = 0.87 },
    --      dst = 20026
    --  }
    --    The combo rating is then the sum of all the individual ratings entering a combo.

    local all_combos, combo = {}, {}
    local num_hexes = #dst_src
    local hex = 0

    -- If get_best_combo is set, we cap this at 1,000 combos, assuming
    -- that we will have found something close to the strongest by then,
    -- esp. given that the method is only approximate anyway.
    -- Also, if get_best_combo is set, we only take combos that have
    -- the maximum number of attackers. Otherwise the comparison is not fair
    local max_count = 1 -- Note: must be 1, not 0
    local count = 0
    local max_rating, best_combo
    local rating = 0

    -- This is the recursive function adding units to each hex
    -- It is defined here so that we can use the variables above by closure
    local function add_combos()
        hex = hex + 1

        for _,ds in ipairs(dst_src[hex]) do
            if (not combo[ds.src]) then  -- If that unit has not been used yet, add it
                count = count + 1

                combo[ds.src] = dst_src[hex].dst

                if get_best_combo then
                    if (count > 1000) then break end
                    rating = rating + ds.rating  -- Rating is simply the sum of the individual ratings
                end

                if (hex < num_hexes) then
                    add_combos()
                else
                    if get_best_combo then
                        -- Only keep combos with the maximum number of units
                        local tmp_count = 0
                        for _,_ in pairs(combo) do tmp_count = tmp_count + 1 end
                        -- If this is more than current max_count, reset the max_rating (forcing this combo to be taken)
                        if (tmp_count > max_count) then max_rating = nil end

                        -- If this is less than current max_count, don't use this combo
                        if ((not max_rating) or (rating > max_rating)) and (tmp_count >= max_count) then
                            max_rating = rating
                            max_count = tmp_count
                            best_combo = {}
                            for k,v in pairs(combo) do best_combo[k] = v end
                        end
                    else
                        local new_combo = {}
                        for k,v in pairs(combo) do new_combo[k] = v end
                        table.insert(all_combos, new_combo)
                    end
                end

                -- Remove this element from the table again
                if get_best_combo then
                    rating = rating - ds.rating
                end

                combo[ds.src] = nil
            end
        end

        -- We need to call this once more, to account for the "no unit on this hex" case
        -- Yes, this is a code duplication (done so for simplicity and speed reasons)
        if (hex < num_hexes) then
            add_combos()
        else
            if get_best_combo then
                -- Only keep attacks with the maximum number of units
                -- This also automatically excludes the empty combo
                local tmp_count = 0
                for _,_ in pairs(combo) do tmp_count = tmp_count + 1 end
                -- If this is more than current max_count, reset the max_rating (forcing this combo to be taken)
                if (tmp_count > max_count) then max_rating = nil end

                -- If this is less than current max_count, don't use this attack
                if ((not max_rating) or (rating > max_rating)) and (tmp_count >= max_count)then
                    max_rating = rating
                    max_count = tmp_count
                    best_combo = {}
                    for k,v in pairs(combo) do best_combo[k] = v end
                end
            else
                local new_combo = {}
                for k,v in pairs(combo) do new_combo[k] = v end
                table.insert(all_combos, new_combo)
            end
        end

        hex = hex - 1
    end

    add_combos()


    if get_best_combo then
        return best_combo
    end

    -- The last combo is always the empty combo -> remove it
    all_combos[#all_combos] = nil

    return all_combos
end

return fred_utils
