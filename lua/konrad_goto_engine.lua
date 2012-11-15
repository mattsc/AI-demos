return {
    init = function(ai)

        local konrad_goto = {}

        local H = wesnoth.require "lua/helper.lua"
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"

        -------------------- Konrad patrol behavior -----------------------------------

        function konrad_goto:konrad_village_retreat_eval()

            -- Store Konrad if he is wounded
            units_to_heal = wesnoth.get_units
                { id = "Konrad",
                    formula = "(hitpoints < max_hitpoints) and ($this_unit.moves > 0)"
                }

            -- Store them in the AI's data structure and
            -- return score just higher than goto CA
            local score = 0
            if units_to_heal[1] then
                self.data.units_to_heal = units_to_heal
                score = 201000
            end

            --print("Village retreat eval:", score)
            return score
        end

        function konrad_goto:konrad_village_retreat_exec()

            local villages = { {13,7}, {25,12}, {28,16}, {30,21} }

            -- For each wounded unit
            for i,u in ipairs(self.data.units_to_heal) do
                --print("Heal unit:",u.id)

                -- Find the closest unoccupied village (if not occupied by unit itself)
                local d_min, j_min = 9999, -1
                for j,v in ipairs(villages) do
                    local uov = wesnoth.get_units { x=v[1], y=v[2], { "not", { id = u.id } } }[1]
                    if not uov then
                        d = H.distance_between(u.x,u.y,v[1],v[2])
                        --print("  distance to villages #",j,d)
                        if d < d_min then d_min = d; j_min = j end
                    end
                end
                --print("  -> min distance:",j_min,d_min)

                -- If an available village was found, move toward it, otherwise just sit there
                if j_min ~= -1 then
                    -- Find "next hop" on route to village
                    local nh = AH.next_hop(u, villages[j_min][1], villages[j_min][2])
                    --print("  -> move to:", nh[1], nh[2])

                    -- Move unit to village
                    AH.movefull_stopunit(ai, u, nh)
                end
            end

            self.data.units_to_heal = nil
        end

        function konrad_goto:konrad_change_goto_eval()

            -- Is Konrad at one of the waypoints?
            local unit_wp1 = wesnoth.get_units { id = "Konrad", x = 18, y = 9 }[1]
            local unit_wp2 = wesnoth.get_units { id = "Konrad", x = 25, y = 14 }[1]

            -- If so, return score just lower than goto CA
            local score = 0
            if unit_wp1 or unit_wp2 then
                score = 199990
            end

            --print("Change goto eval:", score)
            return score
        end

        function konrad_goto:konrad_change_goto_exec()

            -- We can simply modify Konrad at the waypoints
            -- If he's not there, nothing will happen
            H.modify_unit( { id = "Konrad", x = 18, y = 9 }, { goto_x = 25, goto_y = 14 } )
            H.modify_unit( { id = "Konrad", x = 25, y = 14 }, { goto_x = 35, goto_y = 23 } )

        end

        return konrad_goto
    end
}
