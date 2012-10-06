return {
    init = function(ai)

        local lurkers = {}

        local LS = wesnoth.require "lua/location_set.lua"
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"

        function lurkers:lurker_attack_evaluation()

            -- If any lurker has moves left, we return score just above standard combat CA
            local units = wesnoth.get_units { side = wesnoth.current.side, type = 'Swamp Lurker', formula = '$this_unit.moves > 0' }

            local eval = 0
            if units[1] then eval = 100010 end

            --print("Lurker eval: ",eval)
            return eval
        end

        function lurkers:lurker_attack_execution()

            -- We simply pick the first of the lurkers, they have no strategy
            local me = wesnoth.get_units { side = wesnoth.current.side, type = 'Swamp Lurker', formula = '$this_unit.moves > 0' }[1]
            --print("me at:" .. me.x .. "," .. me.y)

            -- Potential targets
            local targets = wesnoth.get_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }
            -- sort targets by hitpoints (lurkers choose lowest HP target)
            table.sort(targets, function (a,b) return (a.hitpoints < b.hitpoints) end)
            --print("Number of potential targets:", #targets)

            -- all reachable hexes
            local reach = LS.of_pairs( wesnoth.find_reach(me.x, me.y) )
            -- all reachable swamp hexes
            local reachable_swamp =
                 LS.of_pairs( wesnoth.get_locations { terrain = "S*",
                 { "and", { x = me.x, y = me.y, radius = me.moves } } } )
            reachable_swamp:inter(reach)
            --print("  reach: " .. reach:size() .. "    reach_swamp: " .. reachable_swamp:size())

            -- need to restrict that to reachable and not occupied by an ally (except own position)
            local reachable_swamp = reachable_swamp:filter(function(x, y, v)
                local occ_hex = wesnoth.get_units { x=x, y=y, { "not", { id = me.id } } }[1]
                return not occ_hex
            end)
            --print("  reach: " .. reach:size() .. "    reach_swamp no allies: " .. reachable_swamp:size())

            -- Attack the weakest reachable enemy
            local attacked = 0  -- Need this, because unit might die in attack
            for j, target in ipairs(targets) do

                -- Get reachable swamp next to target unit
                local rswamp_nt_target = LS.of_pairs(wesnoth.get_locations {  x=target.x, y=target.y, radius=1 } )
                rswamp_nt_target:inter(reachable_swamp)
                --print("  targets: " .. target.x .. "," .. target.y .. "  adjacent swamp: " .. rswamp_nt_target:size())

                -- if we found a reachable enemy, attack it
                -- since they are sorted by hitpoints, we can simply attack the first enemy found and break the loop
                if rswamp_nt_target:size() > 0 then

                    -- Choose one of the possible attack locations  at random
                    local rand = AH.random(1, rswamp_nt_target:size())
                    local dst = rswamp_nt_target:to_stable_pairs()
                    AH.movefull_stopunit(ai, me, dst[rand])
                    ai.attack(dst[rand][1], dst[rand][2], target.x, target.y)
                    attacked = 1
                    break
               end
            end

            -- If unit has moves left (that is, it didn't attack), go to random swamp hex
            -- Check first that unit wasn't killed in the attack
            if (attacked == 0) then

                -- get one of the reachable swamp hexes randomly
                local rand = AH.random(1, reachable_swamp:size())
                --print("  reach_swamp no allies: " .. reachable_swamp:size() .. "  rand #: " ..  rand)
                local dst = reachable_swamp:to_stable_pairs()
                AH.movefull_stopunit(ai, me, dst[rand])
            end
        end

        return lurkers
    end
}
