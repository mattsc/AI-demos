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

            if units[1] then return 220000 end
            return 0
        end

        function goto_engine:goto_exec(cfg)
            local units = wesnoth.get_units { side = wesnoth.current.side, canrecruit = "no",
                { "and", cfg.goto_units }, formula = '$this_unit.moves > 0'
            }
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
                            return -H.distance_between(x, y, l[1], l[2])
                        end)

                        if (rating > max_rating) then
                            max_rating = rating
                            closest_hex, best_unit = hex, u
                        end
                    else  -- Otherwise find the best path to take
                        local path, cost = wesnoth.find_path(u, l[1], l[2])
                        rating = - cost / u.max_moves

                        if (rating > max_rating) then
                            max_rating = rating
                            closest_hex, best_unit = l, u
                        end
                    end
                end
            end
            --print(best_unit.id, closest_hex[1], closest_hex[2], max_rating)

            AH.movefull_stopunit(ai, best_unit, closest_hex[1], closest_hex[2])
        end

        return goto_engine
    end
}
