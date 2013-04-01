return {
    init = function(ai)

        local test = {}

        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"

        function test:test_eval()
            -- Eval is positive (and very large) if any of the side's unit has MP left
            local units = wesnoth.get_units { side = wesnoth.current.side,
                formula = '$this_unit.moves > 0'
            }

            if units[1] then return 999999 end
            return 0
        end

        function test:test_exec()
            -- Simply move the first unit one hex south, or whatever is the
            -- closest vacant hex
            local unit = wesnoth.get_units { side = wesnoth.current.side,
                formula = '$this_unit.moves > 0'
            }[1]

            local x, y = wesnoth.find_vacant_tile(unit.x, unit.y + 1, unit)
            AH.movefull_stopunit(ai, unit, { x = x , y = y })
        end

        return test
    end
}
