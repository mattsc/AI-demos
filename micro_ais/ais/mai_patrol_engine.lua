return {
    init = function(ai)

        local patrol = {}

        local H = wesnoth.require "lua/helper.lua"
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

        function patrol:patrol_eval(cfg)
            local patrol = wesnoth.get_units({ id = cfg.id })[1]

            -- Don't need to check if unit exists as this is a sticky CA
            if (patrol.moves > 0) then return 300000 end
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
                -- Check whether one of the enemies to be attacked is next to the patroller
                -- If so, don't move, but attack that enemy
                local enemies = wesnoth.get_units {
                    id = cfg.attack,
                    { "filter_adjacent", { id = cfg.id } },
                    { "filter_side", {{ "enemy_of", { side = wesnoth.current.side } }} }
                }
                if next(enemies) then break end

                -- Also check whether we're next to any unit (enemy or ally) which is on the next waypoint
                local unit_on_wp = wesnoth.get_units {
                    x = self.data.next_step_x, y = self.data.next_step_y,
                    { "filter_adjacent", { id = cfg.id } }
                }[1]
                for i = 1,#cfg.waypoint_x do
                    -- If the patrol is on a waypoint or adjacent to one that is occupied by any unit
                    if ((patrol.x == cfg.waypoint_x[i]) and (patrol.y == cfg.waypoint_y[i]))
                        or (unit_on_wp and ((unit_on_wp.x == cfg.waypoint_x[i]) and (unit_on_wp.y == cfg.waypoint_y[i])))
                    then
                        if i >= #cfg.waypoint_x then
                            -- Move him to the first one, if he's on the last waypoint
                            -- Unless cfg.one_time_only is set
                            if cfg.one_time_only then
                                self.data.next_step_x = cfg.waypoint_x[#cfg.waypoint_x]
                                self.data.next_step_y = cfg.waypoint_y[#cfg.waypoint_x]
                            else
                                self.data.next_step_x = cfg.waypoint_x[1]
                                self.data.next_step_y = cfg.waypoint_y[1]
                            end
                        else
                            -- ... else move him on the next waypoint
                            self.data.next_step_x = cfg.waypoint_x[i+1]
                            self.data.next_step_y = cfg.waypoint_y[i+1]
                        end
                    end
                end

                -- If we're on the last waypoint on one_time_only is set, stop here
                if cfg.one_time_only and
                   (patrol.x == cfg.waypoint_x[#cfg.waypoint_x]) and (patrol.y == cfg.waypoint_y[#cfg.waypoint_x])
                then
                    ai.stopunit_moves(patrol)
                else  -- otherwise move toward next WP
                    local x, y = wesnoth.find_vacant_tile(self.data.next_step_x, self.data.next_step_y, patrol)
                    local nh = AH.next_hop(patrol, x, y)
                    if nh and ((nh[1] ~= patrol.x) or (nh[2] ~= patrol.y)) then
                        ai.move(patrol, nh[1], nh[2])
                    else
                        ai.stopunit_moves(patrol)
                    end
                end
            end

            -- Attack unit on the last waypoint under all circumstances if cfg.one_time_only is set
            local enemies = {}
            if cfg.one_time_only then
                enemies = wesnoth.get_units{
                    x = cfg.waypoint_x[#cfg.waypoint_x],
                    y = cfg.waypoint_y[#cfg.waypoint_x],
                    { "filter_adjacent", { id = cfg.id } },
                    { "filter_side", {{ "enemy_of", { side = wesnoth.current.side } }} }
                }
            end

            -- Otherwise attack adjacent enemy (if specified)
            if (not next(enemies)) then
                local enemies = wesnoth.get_units{
                    id = cfg.attack,
                    { "filter_adjacent", { id = cfg.id } },
                    { "filter_side", {{ "enemy_of", { side = wesnoth.current.side } }} }
                }
            end

            if next(enemies) then
                for i,v in ipairs(enemies) do
                    ai.attack(patrol, v)
                    break
                end
            end

            -- Check that patrol is not killed
            if patrol and patrol.valid then ai.stopunit_all(patrol) end
        end

        return patrol
    end
}
