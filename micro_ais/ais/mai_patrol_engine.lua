return {
    init = function(ai)

        local patrol = {}

        local H = wesnoth.require "lua/helper.lua"
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"

        function patrol:patrol_eval()
            -- acquire Jabb
            local jabb = wesnoth.get_units({ id = "Goblin Handler Jabb" })[1]

            if jabb and (jabb.moves > 0) then return 300000 end
            return 0
        end

        function patrol:patrol_exec()
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

        return patrol
    end
}
