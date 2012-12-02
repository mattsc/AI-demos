return {
    init = function(ai)

        local patrol = {}

        local H = wesnoth.require "lua/helper.lua"
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"

        function patrol:patrol_eval(cfg)
            local patrol = wesnoth.get_units({ id = cfg.id })[1]

            if patrol and (patrol.moves > 0) then return 300000 end
            return 0
        end

        function patrol:patrol_exec(cfg)
            -- acquire patrol
            local patrol = wesnoth.get_units( { id = cfg.id } )[1]

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
            end

            -- perform the move
            local x, y = wesnoth.find_vacant_tile(self.data.next_step_x, self.data.next_step_y, patrol)
            local nh = AH.next_hop(patrol, x, y)
            AH.movefull_stopunit(ai, patrol, nh)
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
        end

        return patrol
    end
}
