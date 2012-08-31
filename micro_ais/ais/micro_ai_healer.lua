return {
    init = function(ai)

        local healers = {}

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}
        local LS = wesnoth.require "lua/location_set.lua"
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

        function healers:find_move_out_of_way(unit, not_id, dist_map, avoid)
            -- Find if there's a move out of the way for 'unit'
            -- not_id: exclude unit with this id (that's the one for which we consider the move)
            -- dist_map: distance map: unit will only move in direction of equal or decreasing distance
            -- Returns {x, y} of best move, or nil

           if (unit.id == not_id) then return end

           local reach = wesnoth.find_reach(unit)
           -- find the closest hex the unit can move to, but only in direction of cart
           local max_score = -9999
           local best_move = {}

           for i,r in ipairs(reach) do
               -- Make sure hex is unoccupied
               local unocc = (not wesnoth.get_unit(r[1], r[2]))
               -- Also exclude hexes given by 'avoid'
               local avoid_hex = false
               if avoid then
                   for j,a in ipairs(avoid) do
                       if (r[1] == a[1]) and (r[2] == a[2]) then avoid_hex = true end
                   end
               end

               if unocc and (not avoid_hex)
                   and (r[3] ~= unit.moves)  -- only counts if unit actually moves
                   and (dist_map:get(r[1], r[2]) <= dist_map:get(unit.x, unit.y))  -- and if not away from leaders
               then
                   -- Maximize moves left (most important), minimize distance to leaders
                   local score = max_score
                   score = 100 * r[3] - dist_map:get(r[1], r[2])
                   if (score > max_score) then
                       max_score = score
                       best_move = {r[1], r[2]}
                   end
               end
           end

           if (max_score > -9999) then
               return best_move
           end
        end

        function healers:move_special_unit(unit, special_rating)
            -- Find the best move for 'unit'
            -- special_rating: the rating that is particular to this kind of unit
            --   (the rest of the rating is done here)

            local leaders = wesnoth.get_units{ side = wesnoth.current.side, canrecruit = true }
            local dist_leaders = AH.distance_map(leaders)

            local all_units = wesnoth.get_units{ side = wesnoth.current.side }
            local units_noMP, units_MP = {}, {}
            for i,u in ipairs(all_units) do
                if (u.moves == 0) then
                    table.insert(units_noMP, u)
                else
                    table.insert(units_MP,u)
                end
            end

            -- Take all units with moves left off the map, for enemy path finding
            for i,u in ipairs(units_MP) do wesnoth.extract_unit(u) end
            -- Get an enemy_reach_map taking only AI units that cannot move into account
            local enemy_dstsrc = AH.get_enemy_dst_src()
            -- Put units back out there
            for i,u in ipairs(units_MP) do wesnoth.put_unit(u.x, u.y, u) end

            local rating_map = LS.create()
            local max_rating = -9e99
            local best_hex = {}

            local reach = wesnoth.find_reach(unit)
            for j,r in ipairs(reach) do

                -- Check if there's unit at the hex that cannot move away
                local unocc = true
                local unit_in_way = wesnoth.get_unit(r[1], r[2])
                if unit_in_way and (unit_in_way.id ~= unit.id) then
                    local move_away = self:find_move_out_of_way(unit_in_way, unit.id, dist_leaders)
                    if (not move_away) then unocc = false end
                end

                -- Only consider unoccupied hexes and those that are not farther from leaders
                if unocc then
                    local rating = 0

                    -- Hexes that enemies can reach are not good
                    for x, y in H.adjacent_tiles(r[1], r[2]) do
                        if enemy_dstsrc:get(x, y) then rating = rating - 1000 end
                    end

                    -- Add in the special unit rating
                    rating = rating + (special_rating:get(r[1], r[2]) or 0)

                    -- Add a very small penalty if unit needs to be moved out of the way
                    if unit_in_way then rating = rating - 0.1 end

                    -- If nothing else, want to get close to units with no MP left
                    -- Excluding those on keeps or castle (to exclude newly recruited units)
                    for i,u in ipairs(units_noMP) do
                        local terrain_info = wesnoth.get_terrain_info(wesnoth.get_terrain(u.x, u.y))
                        if (not terrain_info.keep) and (not terrain_info.castle) then
                            rating = rating + 1. / H.distance_between(u.x, u.y, r[1], r[2])
                        end
                    end

                    -- As a tie breaker, stay close to the leaders
                    rating = rating + dist_leaders:get(r[1], r[2]) * 0.001

                    rating_map:insert(r[1], r[2], rating)
                    --print('rating',r[1], r[2], rating)

                    if (rating > max_rating) then
                        max_rating = rating
                        best_hex = {r[1], r[2]}
                    end
                end
            end
            --print('best unit move', best_hex[1], best_hex[2], max_rating)
            --AH.put_labels(rating_map)

            return best_hex, max_rating
        end

----------------------------

        function healers:healer_eval()

            local all_healers = wesnoth.get_units { side = wesnoth.current.side, ability = "healing" }

            local healers = {}  -- Those without MP, but with variables.stopped set
            for i,h in ipairs(all_healers) do
                if (h.moves > 0) then
                    if (not self.data.healers_MP) then self.data.healers_MP = {} end
                    table.insert(self.data.healers_MP, h)
                end
                if h.variables.stopped then table.insert(healers, h) end
            end

            -- If healers with moves were found, take those moves away from them
            if self.data.healers_MP then return 94000 end

            -- If that ^ did not happen _and_ there are no stopped healer, we're done
            if (not healers[1]) then return 0 end

            -- Otherwise evaluate the move (need full evaluation here, rather than in exec())

            -- healer specific rating:
            local all_units = wesnoth.get_units{ side = wesnoth.current.side }
            local units_noMP, units_MP = {}, {}
            for i,u in ipairs(all_units) do
                if (u.moves == 0) then
                    table.insert(units_noMP, u)
                else
                    table.insert(units_MP,u)
                end
            end
            --print('#units_noMP, #units_MP', #units_noMP, #units_MP)

            -- Take all units with moves left off the map, for enemy path finding
            for i,u in ipairs(units_MP) do wesnoth.extract_unit(u) end
            -- Get an enemy_reach_map taking only AI units that cannot move into account
            local enemy_dstsrc = AH.get_enemy_dst_src()
            -- Put units back out there
            for i,u in ipairs(units_MP) do wesnoth.put_unit(u.x, u.y, u) end

            local special = LS.create()
            for i,u in ipairs(units_noMP) do
                local rating = 0.0
                rating = rating + u.max_hitpoints - u.hitpoints + u.experience / 5.
                -- Negative rating if we're next to another healer (that has moved already)
                if (u.__cfg.usage == "healer") then rating = rating - 30. end
                for x, y in H.adjacent_tiles(u.x, u.y) do
                    -- Larger bonus for every enemy that can reach unit
                    if enemy_dstsrc:get(x, y) then
                        rating = rating + 20
                    end
                end
                for x, y in H.adjacent_tiles(u.x, u.y) do
                    special:insert(x, y, (special:get(x, y) or 0) + rating)
                end
            end
            --AH.put_labels(special)

            -------- All the rest is common to special-unit moves --------
            local max_rating = -9e99
            for i,h in ipairs(healers) do
                h.moves = h.max_moves
                hex, rating = self:move_special_unit(h, special)
                if (rating > max_rating) then
                    self.data.hex, self.data.healer, max_rating = hex, h, rating
                end
                h.moves = 0
            end
            --print('best unit move', self.data.healer.id, self.data.hex[1], self.data.hex[2], max_rating)

            -- if no good rating was found, defer to later (unless no other unit can move)
            if (max_rating < 10) then
                local units_MP = wesnoth.get_units { side = wesnoth.current.side, formula = '$this_unit.moves > 0',
                    { "not", { ability = 'healing' } }
                }
                if units_MP[1] then
                    return 1000
                end
            end

            return 94000
        end

        function healers:healer_exec()

            -- If healers with MP were found, take MP away and set 'stopped' variable for each unit, then return
            if self.data.healers_MP then
                for i,h in ipairs(self.data.healers_MP) do
                    ai.stopunit_moves(h)
                    h.variables.stopped = true
                end
                self.data.healers_MP = nil
                return
            end

            -- If there's a unit in the way, move it away
            -- we checked before that that is possible
            local unit_in_way = wesnoth.get_unit(self.data.hex[1], self.data.hex[2])
            if unit_in_way and (unit_in_way.id ~= self.data.healer.id) then
                local dist_leaders = AH.distance_map(leaders)
                local move_away = self:find_move_out_of_way(unit_in_way, self.data.healer.id, dist_leaders)
                ai.move(unit_in_way, move_away[1], move_away[2])  -- this is not a full move!
            end

            self.data.healer.moves = self.data.healer.max_moves
            AH.movefull_stopunit(ai, self.data.healer, self.data.hex)
            self.data.healer.variables.stopped = nil
            self.data.hex, self.data.healer = nil, nil
        end

        return healers
    end
}
