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

            local n_wp = #cfg.waypoint_x  -- just for convenience

            if (not self.data['waypoints_' .. patrol.id]) then
                self.data['waypoints_' .. patrol.id] = {}
                for i = 1,n_wp do
                    self.data['waypoints_' .. patrol.id][i] = { tonumber(cfg.waypoint_x[i]), tonumber(cfg.waypoint_y[i]) }
                end
            end

            -- if not set, set next location (first move)
            if (not self.data['next_step_' .. patrol.id]) then
                self.data['next_step_' .. patrol.id] = self.data['waypoints_' .. patrol.id][1]
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
                    x = self.data['next_step_' .. patrol.id][1],
                    y = self.data['next_step_' .. patrol.id][2],
                    { "filter_adjacent", { id = cfg.id } }
                }[1]

                for i,wp in ipairs(self.data['waypoints_' .. patrol.id]) do
                    -- If the patrol is on a waypoint or adjacent to one that is occupied by any unit
                    if ((patrol.x == wp[1]) and (patrol.y == wp[2]))
                        or (unit_on_wp and ((unit_on_wp.x == wp[1]) and (unit_on_wp.y == wp[2])))
                    then
                        if (i == n_wp) then
                            -- Move him to the first one, if he's on the last waypoint
                            -- Unless cfg.one_time_only is set
                            if cfg.one_time_only then
                                self.data['next_step_' .. patrol.id] = self.data['waypoints_' .. patrol.id][n_wp]
                            else
                                self.data['next_step_' .. patrol.id] = self.data['waypoints_' .. patrol.id][1]
                            end
                        else
                            -- ... else move him on the next waypoint
                            self.data['next_step_' .. patrol.id] = self.data['waypoints_' .. patrol.id][i+1]
                        end
                    end
                end

                -- If we're on the last waypoint on one_time_only is set, stop here
                if cfg.one_time_only and
                    (patrol.x == self.data['waypoints_' .. patrol.id][n_wp][1]) and
                    (patrol.y == self.data['waypoints_' .. patrol.id][n_wp][2])
                then
                    ai.stopunit_moves(patrol)
                else  -- otherwise move toward next WP
                    local x, y = wesnoth.find_vacant_tile(self.data['next_step_' .. patrol.id][1], self.data['next_step_' .. patrol.id][2], patrol)
                    local nh = AH.next_hop(patrol, x, y)
                    if nh and ((nh[1] ~= patrol.x) or (nh[2] ~= patrol.y)) then
                        ai.move(patrol, nh[1], nh[2])

                        -- If we get to the last waypoint, and cfg.out_and_back is set
                        if cfg.out_and_back and
                            (nh[1] == self.data['waypoints_' .. patrol.id][n_wp][1]) and
                            (nh[2] == self.data['waypoints_' .. patrol.id][n_wp][2])
                        then
                            local tmp_wp = {}
                            for i = 1,n_wp do
                                tmp_wp[n_wp-i+1] = self.data['waypoints_' .. patrol.id][i]
                            end
                            self.data['waypoints_' .. patrol.id] = tmp_wp
                        end
                    else
                        ai.stopunit_moves(patrol)
                    end
                end
            end

            -- Attack unit on the last waypoint under all circumstances if cfg.one_time_only is set
            local enemies = {}
            if cfg.one_time_only then
                enemies = wesnoth.get_units{
                    x = self.data['waypoints_' .. patrol.id][n_wp][1],
                    y = self.data['waypoints_' .. patrol.id][n_wp][2],
                    { "filter_adjacent", { id = cfg.id } },
                    { "filter_side", {{ "enemy_of", { side = wesnoth.current.side } }} }
                }
            end

            -- Otherwise attack adjacent enemy (if specified)
            if (not next(enemies)) then
                enemies = wesnoth.get_units{
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
