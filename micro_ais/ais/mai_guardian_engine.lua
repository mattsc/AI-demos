return {
    init = function(ai)

        local guardians = {}

        local H = wesnoth.require "lua/helper.lua"
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"

        function guardians:coward_eval(cfg)

            local unit = wesnoth.get_units{ id = cfg.id }[1]
            if unit.moves > 0 then
                return 300000
            else
                return 0
            end
        end
        -- id, radius, seek_x, seek_y, avoid_x, avoid_y
        function guardians:coward_exec(cfg)
            --print("Coward exec " .. cfg.id)
            local unit = wesnoth.get_units{ id = cfg.id }[1]
            local reach = wesnoth.find_reach(unit)
            -- enemy units within reach
            local enemies = wesnoth.get_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} },
                { "filter_location", {x = unit.x, y = unit.y, radius = cfg.radius} }
            }

            -- if no enemies are within reach: keep unit from doing anything and exit
            if not enemies[1] then
                ai.stopunit_all(unit)
                return
            end

            -- Go through all hexes the unit can reach
            for i,r in ipairs(reach) do

                -- only consider unoccupied hexes
                local occ_hex = wesnoth.get_units { x=r[1], y=r[2], { "not", { id = unit.id } } }[1]
                if not occ_hex then
                    -- Find combined distance weighting of all enemy units within radius
                    local value = 0
                    for j,e in ipairs(enemies) do
                        local d = H.distance_between(r[1], r[2], e.x, e.y)
                        value = value + 1/ d^2
                    end
                    --wesnoth.fire("label", {x=r[1], y=r[2], text = math.floor(value*1000) } )

                    -- Store this weighting in the third field of each 'reach' element
                    reach[i][3] = value
                else
                    reach[i][3] = 9999
                end
            end

            -- Sort 'reach' by values, smallest first
            table.sort(reach, function(a, b) return a[3] < b[3] end )
            -- Select those within factor 2 of the minimum
            local best_pos = AH.filter(reach, function(tmp) return tmp[3] < reach[1][3]*2 end)

            -- Now take 'seek' and 'avoid' into account
            for i,b in ipairs(best_pos) do

                -- weighting based on distance from 'seek' and 'avoid'
                local ds = AH.generalized_distance(b[1], b[2], tonumber(cfg.seek_x), tonumber(cfg.seek_y))
                local da = AH.generalized_distance(b[1], b[2], tonumber(cfg.avoid_x), tonumber(cfg.avoid_y))
                --items.place_image(b[1], b[2], "items/ring-red.png")
                local value = 1 / (ds+1) - 1 / (da+1)^2 * 0.75

                --wesnoth.fire("label", {x=b[1], y=b[2], text = math.floor(value*1000) } )
                best_pos[i][3] = value
            end

            -- Sort 'best_pos" by value, largest first
            table.sort(best_pos, function(a, b) return a[3] > b[3] end)
            -- and select all those that have the maximum score
            local best_overall = AH.filter(best_pos, function(tmp) return tmp[3] == best_pos[1][3] end)

            -- As final step, if there are more than one remaining locations,
            -- we take the one with the minimum score in the distance-from_enemy criterion
            local min, mx, my = 9999, 0, 0
            for i,b in ipairs(best_overall) do

                --items.place_image(b[1], b[2], "items/ring-white.png")
                local value = 0
                for j,e in ipairs(enemies) do
                    local d = H.distance_between(b[1], b[2], e.x, e.y)
                    value = value + 1/d^2
                end

                if value < min then
                    min = value
                    mx,my = b[1], b[2]
                end
            end
            --items.place_image(mx, my, "items/ring-gold.png")

            -- (mx,my) is the position to move to
            if (mx ~= unit.x or my ~= unit.y) then
                ai.move(unit, mx, my)
            end

            -- Get unit again, just in case it was killed by a moveto event
            local unit = wesnoth.get_units{ id = cfg.id }[1]
            if unit then ai.stopunit_all(unit) end
        end

        function guardians:return_guardian_eval(cfg)

            local unit = wesnoth.get_units { id=cfg.id }[1]

            if (unit.x~=cfg.to_x or unit.y~=cfg.to_y) then
                value = 100010
            else
                value = 99990
            end

            --print("Eval:", value)
            return value
        end

        function guardians:return_guardian_exec(cfg)

            local unit = wesnoth.get_units { id=cfg.id }[1]
            --print("Exec guardian move",unit.id)

            local nh = AH.next_hop(unit, cfg.to_x, cfg.to_y)
            if unit.moves~=0 then
                AH.movefull_stopunit(ai, unit, nh)
            end
        end

        function guardians:stationed_guardian_eval(cfg)

            local unit = wesnoth.get_units { id=cfg.id }[1]
            if (unit.moves > 0) then
                value = 100010
            else
                value = 0
            end

            -- print("Eval:", value)
            return value
        end
        -- id, radius, s_x, s_y, g_x, g_y
        function guardians:stationed_guardian_exec(cfg)
            -- (s_x,s_y): coordinates where unit is stationed; tries to move here if there is nobody to attack
            -- (g_x,g_y): location that the unit guards
            --print ("Exec",id)
            local unit = wesnoth.get_units { id=cfg.id }[1]

            -- find if there are enemies within 'radius'
            local enemies = wesnoth.get_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} },
                { "filter_location", {x = unit.x, y = unit.y, radius = cfg.radius} }
            }

            -- if no enemies are within 'radius': keep unit from doing anything and exit
            if not enemies[1] then
                --print("No enemies close -> sleeping:",unit.id)
                ai.stopunit_moves(unit)
                return
            end

            -- Otherwise, unit will either attack or move toward station
            --print("Guardian unit waking up",unit.id)

            -- enemies must be within 'radius' of guard, (s_x,s_y) *and* (g_x,g_y)
            -- simultaneous for guard to attack
            local target = {}
            local min_dist = 9999
            for i,e in ipairs(enemies) do
                local ds = H.distance_between(cfg.station_x, cfg.station_y, e.x, e.y)
                local dg = H.distance_between(cfg.guard_x, cfg.guard_y, e.x, e.y)

                -- If valid target found, save the one with the shortest distance from (g_x,g_y)
                if (ds <= cfg.radius) and (dg <= cfg.radius) and (dg < min_dist) then
                    --print("target:", e.id, ds, dg)
                    target = e
                    min_dist = dg
                end
            end

            -- If a valid target was found, unit attacks this target, or moves toward it
            if (min_dist ~= 9999) then
                --print ("Go for enemy unit:", target.id)

                -- Find tiles adjacent to the target, and save the one that our unit
                -- can reach with the highest defense rating
                local best_defense = -9999
                local attack_loc = 0
                for x,y in H.adjacent_tiles(target.x, target.y) do
                    -- only consider unoccupied hexes
                    local occ_hex = wesnoth.get_units { x=x, y=y, { "not", { id = unit.id } } }[1]
                    if not occ_hex then
                        -- defense rating of the hex
                        local defense = 100 - wesnoth.unit_defense(unit, wesnoth.get_terrain(x, y))
                        --print(x,y,defense)
                        local nh = AH.next_hop(unit, x, y)
                        -- if this is best defense rating and unit can reach it, save this location
                        if (nh[1] == x) and (nh[2] == y) and (defense > best_defense) then
                            attack_loc = {x, y}
                            best_defense = defense
                        end
                    end
                end

                -- If a valid hex was found: move there and attack
                if (best_defense ~= -9999) then
                    --print("Attack at:",attack_loc[1],attack_loc[2],best_defense)
                    ai.move(unit, attack_loc[1],attack_loc[2])
                    -- There should be an ai.check_attack_action() here in case something weird is
                    -- done in a 'moveto' event.  Not implemented yet in Lua AI.
                    ai.attack(unit, target)
                else  -- otherwise move toward that enemy
                    --print("Cannot reach target, moving toward it")
                    local reach = wesnoth.find_reach(unit)

                    -- Go through all hexes the unit can reach, find closest to target
                    local nh = {}  -- cannot use next_hop here since target hex is occupied by enemy
                    local min_dist = 9999
                    for i,r in ipairs(reach) do
                        -- only consider unoccupied hexes
                        local occ_hex = wesnoth.get_units { x=r[1], y=r[2], { "not", { id = unit.id } } }[1]
                        if not occ_hex then
                            local d = H.distance_between(r[1], r[2], target.x, target.y)
                            if d < min_dist then
                                min_dist = d
                                nh = {r[1], r[2]}
                            end
                        end
                    end

                    -- Finally, execute the move toward the target
                    AH.movefull_stopunit(ai, unit, nh)
                end

            -- If no enemy within the target zone, move toward station position
            else
                --print "Move toward station"
                local nh = AH.next_hop(unit, cfg.station_x, cfg.station_y)
                AH.movefull_stopunit(ai, unit, nh)
            end

            -- Get unit again, just in case something was done to it in a 'moveto' or 'attack' event
            local unit = wesnoth.get_units{ id = id }[1]
            if unit then ai.stopunit_moves(unit) end
            -- If there are attacks left and unit ended up next to an enemy, we'll leave this to RCA AI
        end

        return guardians
    end
}
