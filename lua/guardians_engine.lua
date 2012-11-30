return {
    init = function(ai)

        local guardians = {}

        local H = wesnoth.require "lua/helper.lua"
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"

        function guardians:return_guardian_eval(id, to_x, to_y)

            local unit = wesnoth.get_units { id=id }[1]

            if (unit.x~=to_x or unit.y~=to_y) then
                value = 100010
            else
                value = 99990
            end

            --print("Eval:", value)
            return value
        end

        function guardians:return_guardian_exec(id, to_x, to_y)

            local unit = wesnoth.get_units { id=id }[1]
            --print("Exec guardian move",unit.id)

            local nh = AH.next_hop(unit, to_x, to_y)
            if unit.moves~=0 then
                AH.movefull_stopunit(ai, unit, nh)
            end
        end

        return guardians
    end
}
