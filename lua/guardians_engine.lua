return {
    init = function(ai)

        local guardians = {}

        local H = wesnoth.require "lua/helper.lua"
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"

        function guardians:coward_eval(id)

            local unit = wesnoth.get_units{ id = id }[1]

            if unit.moves > 0 then
                return 300000
            else
                return 0
            end
        end

        function guardians:coward_exec(id, radius, seek_x, seek_y, avoid_x, avoid_y)

            local unit = wesnoth.get_units{ id = id }[1]
            local reach = wesnoth.find_reach(unit)
            -- enemy units within reach
            local enemies = wesnoth.get_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} },
                { "filter_location", {x = unit.x, y = unit.y, radius = radius} }
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
                local ds = AH.generalized_distance(b[1], b[2], tonumber(seek_x), tonumber(seek_y))
                local da = AH.generalized_distance(b[1], b[2], tonumber(avoid_x), tonumber(avoid_y))
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
            local unit = wesnoth.get_units{ id = id }[1]
            if unit then ai.stopunit_all(unit) end
        end

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
