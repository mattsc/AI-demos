return {
    init = function(ai)

        local wolves = {}

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        local LS = wesnoth.require "lua/location_set.lua"
        local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

        function wolves:color_label(x, y, text)
            -- For displaying the wolf pack number in color underneath each wolf
            if (wesnoth.current.side == 2) then 
                text = "<span color='#63B8FF'>" .. text .. "</span>"
            else
                text = "<span color='#98FB98'>" .. text .. "</span>"
            end
            W.label{ x = x, y = y, text = text }
        end

        function wolves:assign_packs()
            -- Assign the pack numbers to each wolf.  Keeps numbers of existing packs 
            -- (unless pack size is down to one).  Pack number is stored in wolf unit variables
            -- Also returns a table with the packs (locations and id's of each wolf in a pack)

            local wolves = wesnoth.get_units { side = wesnoth.current.side, type = 'Wolf' }
            --print('#wolves:', #wolves)

            -- Array for holding the packs
            local packs = {}
            -- Find wolves that already have a pack number assigned
            for i,w in ipairs(wolves) do
                if w.variables.pack then
                    if (not packs[w.variables.pack]) then packs[w.variables.pack] = {} end
                    table.insert(packs[w.variables.pack], { x = w.x, y = w.y, id = w.id })
                end
            end

            -- Remove packs of one
            -- Pack numbers might not be consecutive after a while -> need pairs(), not ipairs()
            for k,p in pairs(packs) do
                --print(' have pack:', k, ' #members:', #p)
                if (#p == 1) then
                    local wolf = wesnoth.get_unit(p[1].x, p[1].y)
                    wolf.variables.pack, wolf.variables.x, wolf.variables.y = nil, nil, nil
                    packs[k] = nil
                end
            end
            --print('After removing packs of 1')           
            --for k,p in pairs(packs) do print(' have pack:', k, ' #members:', #p) end
            --DBG.dbms(packs)

            -- Wolves that are not in a pack (new ones or those removed above)
            local nopack_wolves = {}
            for i,w in ipairs(wolves) do
                if (not w.variables.pack) then 
                    table.insert(nopack_wolves, w)
                    -- Also erase any goal one of these might have
                    w.variables.pack, w.variables.x, w.variables.y = nil, nil, nil
                end
            end
            --print('#nopack_wolves:', #nopack_wolves)

            -- Now assign the nopack wolves to packs
            -- First, go through packs that have only 2 members
            for k,p in pairs(packs) do
                if (#p == 2) then
                    local min_dist, best_wolf, best_ind = 9e99, {}, -1
                    for i,w in ipairs(nopack_wolves) do
                        local d1 = H.distance_between(w.x, w.y, p[1].x, p[1].y)
                        local d2 = H.distance_between(w.x, w.y, p[2].x, p[2].y)
                        if (d1 + d2 < min_dist) then
                            min_dist = d1 + d2
                            best_wolf, best_ind = w, i
                        end                        
                    end
                    if (min_dist < 9e99) then
                        table.insert(packs[k], { x = best_wolf.x, y = best_wolf.y, id = best_wolf.id })
                        best_wolf.variables.pack = k
                        table.remove(nopack_wolves, best_ind)
                    end
                end
            end
            --print('After completing packs of 2')           
            --for k,p in pairs(packs) do print(' have pack:', k, ' #members:', #p) end

            -- Second, group remaining single wolves
            -- At the beginning of the scenario, this is all wolves
            while (#nopack_wolves > 0) do
                --print('Grouping the remaining wolves', #nopack_wolves)
                -- First find the first available pack number
                new_pack = 1
                while packs[new_pack] do new_pack = new_pack + 1 end
                --print('Building pack', new_pack)

                -- If there are <=3 wolves left, that's the pack (we also assign a single wolf to a 1-wolf pack here)
                if (#nopack_wolves <= 3) then
                    --print('<=3 nopack wolves left', #nopack_wolves)
                    packs[new_pack] = {}
                    for i,w in ipairs(nopack_wolves) do
                        table.insert(packs[new_pack], { x = w.x, y = w.y, id = w.id })
                        w.variables.pack = new_pack
                    end
                    break
                end

                -- If more than 3 wolves left, find those that are closest together
                -- They form the next pack
                --print('More than 3 nopack wolves left', #nopack_wolves)
                local min_dist = 9e99
                local best_wolves, best_ind = {}, {}
                for i,w1 in ipairs(nopack_wolves) do
                    for j,w2 in ipairs(nopack_wolves) do
                        for k,w3 in ipairs(nopack_wolves) do
                            local d12 = H.distance_between(w1.x, w1.y, w2.x, w2.y)
                            local d13 = H.distance_between(w1.x, w1.y, w3.x, w3.y)
                            local d23 = H.distance_between(w2.x, w2.y, w3.x, w3.y)
                            -- If it's the same wolf, that doesn't count
                            if (d12 == 0) then d12 = 999 end
                            if (d13 == 0) then d13 = 999 end
                            if (d23 == 0) then d23 = 999 end
                            if (d12 + d13 + d23 < min_dist) then
                                min_dist = d12 + d13 + d23
                                best_wolves = { w1, w2, w3 }
                                best_ind = { i, j, k }
                            end
                        end
                    end
                end
                -- Now insert the best pack into that 'packs' array
                packs[new_pack] = {}
                -- Need to count down for table.remove to work correctly
                for i = 3,1,-1 do
                    table.insert(packs[new_pack], { x = best_wolves[i].x, y = best_wolves[i].y, id = best_wolves[i].id })
                    best_wolves[i].variables.pack = new_pack
                    table.remove(nopack_wolves, best_ind[i])
                end
            end
            --print('After grouping remaining single wolves')           
            --for k,p in pairs(packs) do print(' have pack:', k, ' #members:', #p) end

            --DBG.dbms(packs)
            -- Put labels out there for all wolves
            for k,p in pairs(packs) do
                for i,loc in ipairs(p) do
                    self:color_label(loc.x, loc.y, k)
                end
            end

            return packs
        end

        function wolves:wolves_attack_eval()
            -- If wolves have attacks left, call this CA
            -- It will generally be disabled by being black-listed, so as to avoid
            -- having to do the full attack evaluation for every single move
            local wolves = wesnoth.get_units { side = wesnoth.current.side, type = 'Wolf', formula = '$this_unit.attacks_left > 0' }

            if wolves[1] then return 300000 end
            return 0
        end

        function wolves:wolves_attack_exec()
            
            -- First get all the packs
            local packs = self:assign_packs()
            --DBG.dbms(packs)

            -- Attacks are dealt with on a pack by pack basis
            -- and I want all wolves in a pack to move first, before going on to the next pack
            -- which makes this slightly more complicated than it would be otherwise
            for pack_number,pack in pairs(packs) do

                local keep_attacking_this_pack = true    -- whether there might be attacks left
                local pack_attacked = false   -- whether an attack by the pack has happened

                -- This repeats until all wolves in a pack have attacked, or none can attack any more
                while keep_attacking_this_pack do
                    -- Get the wolves in the pack ...
                    local wolves, attacks = {}, {}
                    for i,p in ipairs(pack) do
                        -- Wolf might have moved in previous attack -> use id to identify it
                        local wolf = wesnoth.get_units { id = p.id }
                        -- Wolf could have died in previous attack
                        -- and only include wolves with attacks left to calc. possible attacks
                        if wolf[1] and (wolf[1].attacks_left > 0) then table.insert(wolves, wolf[1]) end
                    end

                    -- ... and check if any targets are in reach
                    local attacks = {}
                    if wolves[1] then attacks = AH.get_attacks(wolves) end
                    --print('pack, wolves, attacks:', pack_number, #wolves, #attacks)
                    --DBG.dbms(attacks)

                    -- Eliminate targets that would split up the wolves by more than 3 hexes
                    -- This also takes care of wolves joining as a pack rather than attacking individually
                    for i=#attacks,1,-1 do
                        --print(i, attacks[i].x, attacks[i].y)
                        for j,w in ipairs(wolves) do
                            local nh = AH.next_hop(w, attacks[i].x, attacks[i].y)
                            local d = H.distance_between(nh[1], nh[2], attacks[i].x, attacks[i].y)
                            --print('  ', i, w.x, w.y, d)
                            if d > 3 then
                                table.remove(attacks, i)
                                --print('Removing attack')
                                break
                            end
                        end
                    end
                    --print('-> pack, wolves, attacks:', pack_number, #wolves, #attacks)

                    -- If valid attacks were found for this pack
                    if attacks[1] then
                        -- Figure out how many different wolves can reach each target, and on how many hexes
                        -- The target with the largest value for the smaller of these two numbers is chosen
                        -- This is not an exact method, but good enough in most cases
                        local diff_wolves, diff_hexes = {}, {}
                        for i,a in ipairs(attacks) do
                            -- Number different wolves
                            local att_xy = a.att_loc.x + a.att_loc.y * 1000
                            local def_xy = a.def_loc.x + a.def_loc.y * 1000
                            if (not diff_wolves[def_xy]) then diff_wolves[def_xy] = {} end
                            diff_wolves[def_xy][att_xy] = 1
                            -- Number different hexes
                            if (not diff_hexes[def_xy]) then diff_hexes[def_xy] = {} end
                            diff_hexes[def_xy][a.x + a.y * 1000] = 1
                        end
                        --DBG.dbms(diff_wolves)
                        --DBG.dbms(diff_hexes)

                        -- Find which target can be attacked by the most units, from the most hexes; and rate by fewest HP if equal
                        local max_rating, best_target = -9e99, {}
                        for k,t in pairs(diff_wolves) do
                            local n_w, n_h = 0, 0
                            for k1,w in pairs(t) do n_w = n_w + 1 end
                            for k2,h in pairs(diff_hexes[k]) do n_h = n_h + 1 end
                            local rating = math.min(n_w, n_h)

                            local target = wesnoth.get_unit( k % 1000, math.floor(k / 1000))
                            rating = rating - target.hitpoints / 100.

                            -- Also, any target sitting next to a wolf of the same pack that has 
                            -- no attacks left is priority targeted (in order to stick with 
                            -- the same target for all wolves of the pack)
                            for x, y in H.adjacent_tiles(target.x, target.y) do
                                local adj_unit = wesnoth.get_unit(x, y)
                                if adj_unit and (adj_unit.variables.pack == pack_number) 
                                    and (adj_unit.side == wesnoth.current.side) and (adj_unit.attacks_left == 0)
                                then
                                    rating = rating + 10 -- very strongly favors this target
                                end
                            end

                            --print(k, n_w, n_h, rating)
                            if rating > max_rating then
                                max_rating, best_target = rating, target
                            end
                        end
                        --print('Best target:', best_target.id, best_target.x, best_target.y)

                        -- Now we know what the best target is, we need to attack now
                        -- This is done on a wolf-by-wolf basis, the while loop taking care of the next wolf in the pack
                        -- on subsequent iterations
                        local max_rating, best_attack = -9e99, {}
                        for i,a in ipairs(attacks) do
                            if (a.def_loc.x == best_target.x) and (a.def_loc.y == best_target.y) then
                                -- HP outcome is rating, twice as important for target as for attacker
                                local rating = a.att_stats.average_hp / 2. - a.def_stats.average_hp
                                if (rating > max_rating) then
                                    max_rating, best_attack = rating, a
                                end
                            end
                        end

                        local attacker = wesnoth.get_unit(best_attack.att_loc.x, best_attack.att_loc.y)
                        local defender = wesnoth.get_unit(best_attack.def_loc.x, best_attack.def_loc.y)
                        W.label { x = attacker.x, y = attacker.y, text = "" }
                        AH.movefull_stopunit(ai, attacker, best_attack.x, best_attack.y)
                        self:color_label(attacker.x, attacker.y, pack_number)

                        local a_x, a_y, d_x, d_y = attacker.x, attacker.y, defender.x, defender.y
                        ai.attack(attacker, defender)
                        -- Remove the labels, if one of the units died
                        if (not attacker.valid) then W.label { x = a_x, y = a_y, text = "" } end
                        if (not defender.valid) then W.label { x = d_x, y = d_y, text = "" } end

                        pack_attacked = true    -- This pack has done an attack
                    else
                        keep_attacking_this_pack = false    -- no more valid attacks found
                    end
                end

                -- Finally, if any of the wolves in this pack did attack, move the rest of the pack in close
               if pack_attacked then
                    local wolves_moves, wolves_no_moves = {}, {}
                    for i,p in ipairs(pack) do
                        -- Wolf might have moved in previous attack -> use id to identify it
                        local wolf = wesnoth.get_unit(p.x, p.y)
                        -- Wolf could have died in previous attack
                        if wolf then
                            if (wolf.moves > 0) then
                                table.insert(wolves_moves, wolf)
                            else
                                table.insert(wolves_no_moves, wolf)
                            end
                        end
                    end
                    --print('#wolves_moves, #wolves_no_moves', #wolves_moves, #wolves_no_moves)

                    -- If we have both wolves that have moved and those that have not moved,
                    -- move the latter toward the former
                    if wolves_moves[1] and wolves_no_moves[1] then
                        --print('Collecting stragglers')
                        for i,w in ipairs(wolves_moves) do
                            local best_hex = AH.find_best_move(w, function(x, y)
                                local rating = 0
                                for j,w_nm in ipairs(wolves_no_moves) do
                                    rating = rating - H.distance_between(x, y, w_nm.x, w_nm.y)
                                end
                                return rating
                            end)
                            W.label { x = w.x, y = w.y, text = "" }
                            AH.movefull_stopunit(ai, w, best_hex)
                            self:color_label(w.x, w.y, pack_number)
                        end
                    end
                end

            end

        end

        function wolves:wolves_wander_eval()
            -- When there's nothing to attack, the wolves wander and regroup into their packs
            local wolves = wesnoth.get_units { side = wesnoth.current.side, type = 'Wolf', formula = '$this_unit.moves > 0' }

            if wolves[1] then return 290000 end

            return 0
        end

        function wolves:wolves_wander_exec()

            -- First get all the packs
            local packs = self:assign_packs()
            --DBG.dbms(packs)

            for k,pack in pairs(packs) do

                -- If any of the wolves has a goal set, this is used for the entire pack
                local wolves, goal = {}, {}
                for i,loc in ipairs(pack) do
                    local wolf = wesnoth.get_unit(loc.x, loc.y)
                    --print(k, i, wolf.id)
                    table.insert(wolves, wolf)
                    -- If any of the wolves in the pack has a goal set, we use that one
                    if wolf.variables.x then
                        goal = { wolf.variables.x, wolf.variables.y }
                    end
                end

                -- If the position of any of the wolves is at the goal, delete it
                for i,w in ipairs(wolves) do
                    if (w.x == goal[1]) and (w.y == goal[2]) then goal = {} end
                end

                -- Pack gets a new goal if none exist or on any move with 10% random chance
                local r = AH.random(10)
                if (not goal[1]) or (r == 1) then
                    local w,h,b = wesnoth.get_map_size()
                    local locs = {}
                    locs = wesnoth.get_locations { x = '1-'..w, y = '1-'..h, 
                        { "not", { terrain = '*^X*,Wo' } }
                    }
                    local rand = AH.random(#locs)
                    goal = { locs[rand][1], locs[rand][2] }
                end
                --print('Pack goal: ', goal[1], goal[2])

                -- This goal is saved with every wolf of the pack
                for i,w in ipairs(wolves) do
                    w.variables.x, w.variables.y = goal[1], goal[2]
                end

                -- The pack wanders with only 2 considerations
                -- 1. Keeping the pack together (most important)
                --   Going through all combinations of all hexes for all wolves is too expensive
                --   -> find hexes that can be reached by all wolves
                -- 2. Getting closest to the goal (secondary to 1.)

                -- Number of wolves that can reach each hex, 
                local reach_map = LS.create()
                for i,w in ipairs(wolves) do
                    local reach = wesnoth.find_reach(w)
                    for j,loc in ipairs(reach) do
                        reach_map:insert(loc[1], loc[2], (reach_map:get(loc[1], loc[2]) or 0) + 100)
                    end
                end

                -- Keep only those hexes that can be reached by all wolves in the pack
                -- and add distance from goal for those
                local max_rating, goto_hex = -9e99, {}
                reach_map:iter( function(x, y, v)
                    local rating = reach_map:get(x, y)
                    if (rating == #pack * 100) then
                        rating = rating - H.distance_between(x, y, goal[1], goal[2])
                        reach_map:insert(x,y, rating)
                        if rating > max_rating then
                            max_rating, goto_hex = rating, { x, y }
                        end
                    else
                        reach_map:remove(x, y)
                    end
                end)

                -- Sort wolves by MP, the one with fewest moves goes first
                table.sort(wolves, function(a, b) return a.moves < b.moves end)

                -- If there's no hex that all units can reach, use the 'center of gravity' between them
                -- Then we move the first wolf (fewest MP) toward that hex, and the position of that wolf
                -- becomes the goto coordinates for the others
                if (not goto_hex[1]) then
                    local cg = { 0, 0 }  -- Center of gravity hex
                    for i,w in ipairs(wolves) do
                        cg = { cg[1] + w.x, cg[2] + w.y }
                    end
                    cg[1] = math.floor(cg[1] / #pack)
                    cg[2] = math.floor(cg[2] / #pack)
                    --print('cg', cg[1], cg[2])

                    -- Find closest move for Wolf #1 to that position, which then becomes the goto hex
                    goto_hex = AH.find_best_move(wolves[1], function(x, y)
                        return -H.distance_between(x, y, cg[1], cg[2])
                    end)
                    -- We could move this wolf right here, but for convenience all the actual moves are 
                    -- grouped together below.  Speed wise that should not really make a difference, but could be optimized
                end
                --print('goto_hex', goto_hex[1], goto_hex[2])
                --AH.put_labels(reach_map)

                -- Now all wolves in the pack are moved toward goto_hex, starting with the one with fewest MP
                -- Distance to goal hex is taken into account as secondary criterion
                for i,w in ipairs(wolves) do
                    local best_hex = AH.find_best_move(w, function(x, y)
                        local rating = - H.distance_between(x, y, goto_hex[1], goto_hex[2])
                        rating = rating - H.distance_between(x, y, goal[1], goal[2]) / 100.
                        return rating
                    end)
                    W.label { x = w.x, y = w.y, text = "" }
                    AH.movefull_stopunit(ai, w, best_hex)
                    self:color_label(w.x, w.y, k)
                end
            end
        end

        return wolves	
    end
}
