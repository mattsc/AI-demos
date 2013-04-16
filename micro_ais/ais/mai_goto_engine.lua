return {
    init = function(ai)

        local goto_engine = {}

        local H = wesnoth.require "lua/helper.lua"
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        --local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

        function goto_engine:goto_eval(cfg)
            -- Find the goto units
            local units = wesnoth.get_units { side = wesnoth.current.side, canrecruit = "no",
                { "and", cfg.goto_units }, formula = '$this_unit.moves > 0'
            }

            -- Exclude released units
            if cfg.release_unit_at_goal then
                for i=#units,1,-1 do
                    local str = cfg.ca_id .. '-release-' .. units[i].id
                    if self.data[str] then
                        table.remove(units, i)
                    end
                end
            end

            local score = cfg.ca_score or 210000
            if units[1] then return score end
            return 0
        end

        function goto_engine:goto_exec(cfg)
            local units = wesnoth.get_units { side = wesnoth.current.side, canrecruit = "no",
                { "and", cfg.goto_units }, formula = '$this_unit.moves > 0'
            }

            -- Exclude released units
            if cfg.release_unit_at_goal then
                for i=#units,1,-1 do
                    local str = cfg.ca_id .. '-release-' .. units[i].id
                    if self.data[str] then
                        table.remove(units, i)
                    end
                end
            end
            --print('#units', #units)

            -- Find all locations matching [goto_goals], excluding border hexes
            local width, height = wesnoth.get_map_size()
            local locs = wesnoth.get_locations {
                x = '1-' .. width,
                y = '1-' .. height,
                { "and", cfg.goto_goals }
            }
            --print('#locs', #locs)

            local closest_hex, best_unit, max_rating = {}, {}, -9e99
            for i,u in ipairs(units) do
                for i,l in ipairs(locs) do

                    -- If use_straight_line is set, we simply find the closest
                    -- hex to the goal that the unit can get to
                    if cfg.use_straight_line then
                        local hex, unit, rating = AH.find_best_move(u, function(x, y)
                            local r = - H.distance_between(x, y, l[1], l[2])
                            -- Also add distance from unit as very small rating component
                            -- This is mostly here to keep unit in place when no better hexes are available
                            r = r - H.distance_between(x, y, u.x, u.y) / 1000.
                            return r
                        end, { no_random = true })

                        if (rating > max_rating) then
                            max_rating = rating
                            closest_hex, best_unit = hex, u
                        end
                    else  -- Otherwise find the best path to take
                        local path, cost = wesnoth.find_path(u, l[1], l[2])

                        -- Make all hexes within the unit's current MP equaivalent
                        if (cost <= u.moves) then cost = 0 end

                        rating = - cost

                        -- Add a small penalty for occupied hexes
                        -- (this mean occupied by an allied unit, as enemies make the hex unreachable)
                        local unit_in_way = wesnoth.get_unit(l[1], l[2])
                        if unit_in_way and ((unit_in_way.x ~= u.x) or (unit_in_way.y ~= u.y)) then
                            rating = rating - 0.01
                        end

                        if (rating > max_rating) then
                            max_rating = rating
                            closest_hex, best_unit = l, u
                        end
                    end
                end
            end
            --print(best_unit.id, best_unit.x, best_unit.y, closest_hex[1], closest_hex[2], max_rating)

            AH.movefull_outofway_stopunit(ai, best_unit, closest_hex[1], closest_hex[2])

            -- If release_unit_at_goal= or release_all_units_at_goal= key is set:
            -- Check if the unit made it to one of the goal hexes
            -- This needs to be done for the original goal hexes, not checking the SLF again,
            -- as that might have changed based on the new situation on the map
            if cfg.release_unit_at_goal or cfg.release_all_units_at_goal then
                local unit_at_goal = false
                for i,l in ipairs(locs) do
                    if (best_unit.x == l[1]) and (best_unit.y == l[2]) then
                        unit_at_goal = true
                        break
                    end
                end

                -- If a unit was found, mark either it or all units as released
                if unit_at_goal then
                    if cfg.release_unit_at_goal then
                        local str = cfg.ca_id .. '-release-' .. best_unit.id
                        --print("Made it to goal: ", best_unit.id, str)
                        self.data[str] = true
                    end
                end
            end
        end

        return goto_engine
    end
}
