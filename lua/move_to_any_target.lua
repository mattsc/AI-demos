return {
    init = function(ai)
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"

        local move_to_any_target = {}

        function move_to_any_target:move_to_enemy_eval()
            local units = wesnoth.get_units {
                side = wesnoth.current.side,
                canrecruit = 'no',
                formula = '$this_unit.moves > 0'
            }

            if (not units[1]) then
                return 0
            end

            local unit = units[1]

            local distance, target = AH.get_closest_enemy({unit.x, unit.y})
            if (not target.x) then
                return 0
            end

            local x, y = wesnoth.find_vacant_tile(target.x, target.y)
            local destination = AH.next_hop(unit, x, y)

            if (not destination) then
                return 0
            end

            self.data.destination = destination
            self.data.unit = unit

            return 1
        end

        function move_to_any_target:move_to_enemy_exec()
            ai.move(self.data.unit, self.data.destination[1], self.data.destination[2])
        end

        return move_to_any_target
    end
}
