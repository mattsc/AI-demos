return {
    init = function(ai)

        local patrol = {}

        local H = wesnoth.require "lua/helper.lua"
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

        function patrol:patrol_eval(cfg)
            local patrol = wesnoth.get_units({ id = cfg.id })[1]

            if patrol and (patrol.moves > 0) then return 300000 end
            return 0
        end

        function patrol:patrol_exec(cfg)
            -- acquire patrol
            local patrol = wesnoth.get_units( { id = cfg.id } )[1]
            
            cfg.waypoint_x = AH.split(cfg.waypoint_x, ",")
            cfg.waypoint_y = AH.split(cfg.waypoint_y, ",")
            
            for i = 1,#cfg.waypoint_x do
                cfg.waypoint_x[i] = tonumber(cfg.waypoint_x[i])
                cfg.waypoint_y[i] = tonumber(cfg.waypoint_y[i])
            end
            
            -- if not set, set next location (first move)
            if not self.data.next_step_x then
                self.data.next_step_x = cfg.waypoint_x[1]
                self.data.next_step_y = cfg.waypoint_y[1]
            end
            
            while patrol.moves > 0 do
                local enemies = wesnoth.get_units{ id = cfg.attack, { "filter_adjacent", { id = cfg.id } } }
                if next(enemies) then break end
                for i = 1,#cfg.waypoint_x do
                    local ally = wesnoth.get_units{ x = self.data.next_step_x, y = self.data.next_step_y, { "filter_adjacent", { id = cfg.id } } }[1]
                    -- if the patrol is on a waypoint or adjacent to one that is occupied...
                    if patrol.x == cfg.waypoint_x[i] and patrol.y == cfg.waypoint_y[i] or ally and (ally.x == cfg.waypoint_x[i] and ally.y == cfg.waypoint_y[i]) then
                        if i >= #cfg.waypoint_x then
                            -- ... move him to the first one, if he's on the last waypoint...
                            self.data.next_step_x = cfg.waypoint_x[1]
                            self.data.next_step_y = cfg.waypoint_y[1]
                        else
                            -- ... else move him on the next waypoint
                            self.data.next_step_x = cfg.waypoint_x[i+1]
                            self.data.next_step_y = cfg.waypoint_y[i+1]
                        end
                    end
                end
                
                -- perform the move
                local x, y = wesnoth.find_vacant_tile(self.data.next_step_x, self.data.next_step_y, patrol)
                local nh = AH.next_hop(patrol, x, y)
                if nh and ((nh[1] ~= patrol.x) or (nh[2] ~= patrol.y)) then
                    ai.move(patrol, nh[1], nh[2])
                else
                    ai.stopunit_moves(patrol)
                end
            end
            
             -- attack adjacent enemy (if specified)
             local enemies = wesnoth.get_units{ id = cfg.attack, { "filter_adjacent", { id = cfg.id } } }
             if next(enemies) then
                 for i,v in ipairs(enemies) do
                    ai.attack(patrol, v)
                    break
                end
            end
            
            -- Check if patrol is not killed
            if (type(patrol) ~= "userdata") then
                ai.stopunit_all(patrol)
            end
        end

        return patrol
    end
}
