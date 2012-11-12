return {
    init = function(ai)

        local patrols = {}

        local H = wesnoth.require "lua/helper.lua"
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"

        -------------------- Konrad patrol behavior -----------------------------------

        function patrols:konrad_village_retreat_evaluation()

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

        function patrols:konrad_village_retreat_execution()

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

        function patrols:konrad_change_goto_evaluation()

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

        function patrols:konrad_change_goto_execution()

            -- We can simply modify Konrad at the waypoints
            -- If he's not there, nothing will happen
            H.modify_unit( { id = "Konrad", x = 18, y = 9 }, { goto_x = 25, goto_y = 14 } )
            H.modify_unit( { id = "Konrad", x = 25, y = 14 }, { goto_x = 35, goto_y = 23 } )

        end

        ------------------------ Jabb patrol behavior (from 'A Rough Life') ----------------------------


        function patrols:patrol_eval()
            -- acquire Jabb
            local jabb = wesnoth.get_units({ id = "Goblin Handler Jabb" })[1]

            if jabb and (jabb.moves > 0) then return 300000 end
            return 0
        end

        function patrols:patrol_exec()
            -- acquire Jabb
            local jabb = wesnoth.get_units( { id = "Goblin Handler Jabb" } )[1]

            -- these are the waypoints
            local steps = { {6,17},{7,14},{11,14},{11,18} }

            -- This is where Jabb will move next
            if not self.data.next_step_x then
                self.data.next_step_x = 7
                self.data.next_step_y = 14
            end

            for index, location in ipairs( steps ) do
                -- if Jabb is on a waypoint...
                if jabb.x==location[1] and jabb.y==location[2] then
                    if index >= #steps then
                        -- ... move him to the first one, if he's on the last waypoint...
                        self.data.next_step_x = steps[1][1]
                        self.data.next_step_y = steps[1][2]
                    else
                        -- ... else move him on the next waypoint
                        self.data.next_step_x = steps[index+1][1]
                        self.data.next_step_y = steps[index+1][2]
                    end
                end
            end

            -- perform the move
            local x, y = wesnoth.find_vacant_tile(self.data.next_step_x, self.data.next_step_y, jabb)
            local nh = AH.next_hop( jabb, x, y)
            AH.movefull_stopunit(ai, jabb, nh)
            -- at this point, Jabb should attack Jacques if adjacent
            local jacques = wesnoth.get_units( { id = "Jacques" } )[1]
            if jabb and jacques then
                if H.distance_between( jabb.x,jabb.y,jacques.x,jacques.y ) == 1 then --they're adjacent
                    ai.attack( jabb, jacques )
                end
            end
        end

        return patrols
    end
}
