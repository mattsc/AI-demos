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

            for i = 1,#cfg.waypoint_x do
                -- if the patrol is on a waypoint...
                if patrol.x==cfg.waypoint_x[i] and patrol.y==cfg.waypoint_y[i] then
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
                -- ... if not...
                if (self.data.next_step_x == cfg.waypoint_x[i] and self.data.next_step_y == cfg.waypoint_y[i]) then
                    -- Check if the patrol is adjacent to a waypoint
                    if H.distance_between( patrol.x,patrol.y,self.data.next_step_x,self.data.next_step_y ) == 1 then
                        if cfg.attack_targets then
                            -- Enemy on a waypoint?
                            if not next(wesnoth.get_units{ id = cfg.attack_targets, x = self.data.next_step_x, y = self.data.next_step_y }, nil) then
                                -- Check if we can reach the waypoint, if we can't then go to the next one.
                                if not AH.can_reach(patrol, self.data.next_step_x, self.data.next_step_y) then
                                    if i >= #cfg.waypoint_x then
                                        self.data.next_step_x = cfg.waypoint_x[1]
                                        self.data.next_step_y = cfg.waypoint_y[1]
                                    else
                                        self.data.next_step_x = cfg.waypoint_x[i+1]
                                        self.data.next_step_y = cfg.waypoint_y[i+1]
                                    end
                                end
                            end
                        end
                    end
                end
            end

            -- perform the move
            local x, y = wesnoth.find_vacant_tile(self.data.next_step_x, self.data.next_step_y, patrol)
            AH.movefull_stopunit(ai, patrol, x, y)
            
            -- attack adjacent enemy (if specified)
            if cfg.attack_all then
                local enemy = wesnoth.get_units {
                    { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
                }
                if patrol and enemy then
                    for i,v in ipairs(enemy) do
                        if H.distance_between( patrol.x,patrol.y,v.x,v.y ) == 1 then --they're adjacent
                            ai.attack( patrol, v )
                            break
                        end
                    end
                end
            elseif cfg.attack_targets then
                local enemy = wesnoth.get_units( { id = cfg.attack_targets } )
                if patrol and enemy then
                    for i,v in ipairs(enemy) do
                        if H.distance_between( patrol.x,patrol.y,v.x,v.y ) == 1 then --they're adjacent
                            ai.attack( patrol, v )
                            break
                        end
                    end
                end
            end
            ai.stopunit_attacks(patrol)
        end

        return patrol
    end
}
