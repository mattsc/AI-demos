return {
    init = function(ai)

        local AH = wesnoth.require("~add-ons/AI-demos/lua/ai_helper.lua")

        local recruit_cas = {}
        -- The following external engine creates the CA functions recruit_rushers_eval and recruit_rushers_exec
        -- It also exposes find_best_recruit and find_best_recruit_hex for use by other recruit engines
        wesnoth.require("~add-ons/AI-demos/lua/generic-recruit_engine.lua").init(ai, recruit_cas)

        local recruit

        function recruit_cas:random_recruit_eval(cfg)
            -- Random recruiting from all the units the side has

            -- Check if leader is on keep
            local leader = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]
            if (not leader) or (not wesnoth.get_terrain_info(wesnoth.get_terrain(leader.x, leader.y)).keep) then
                return 0
            end

            -- Check if there is space left for recruiting
            local width, height, border = wesnoth.get_map_size()
            local castle = {
                locs = wesnoth.get_locations {
                    x = "1-"..width, y = "1-"..height,
                    { "and", {
                        x = leader.x, y = leader.y, radius = 200,
                        { "filter_radius", { terrain = 'C*^*,K*^*,*^Kov,*^Cov' } }
                    }}
                }
            }
            local no_space = true
            for i,c in ipairs(castle.locs) do
                local unit = wesnoth.get_unit(c[1], c[2])
                if (not unit) then
                    no_space = false
                    break
                end
            end
            if no_space then return 0 end

            -- Get a random recruit
            local possible_recruits = wesnoth.sides[wesnoth.current.side].recruit
            -- If cfg.skip_low_gold_recruiting is set, we take whatever recruit is selected,
            -- even if we cannot afford is.  Otherwise, we eliminate the ones that
            -- take more gold than the side has
            if (not cfg.skip_low_gold_recruiting) then
                for i = #possible_recruits,1,-1 do
                    if wesnoth.unit_types[possible_recruits[i]].cost > wesnoth.sides[wesnoth.current.side].gold then
                        table.remove(possible_recruits, i)
                    end
                end
            end

            -- We always call the exec function, no matter if the selected unit is affordable
            -- The point is that this will blacklist the CA if an unaffordable recruit was
            -- chosen -> no cheaper recruits will be selected in subsequent calls
            if possible_recruits[1] then
                recruit = possible_recruits[AH.random(#possible_recruits)]
            else
                recruit = wesnoth.sides[wesnoth.current.side].recruit[1]
            end

            return 180000
        end

        function recruit_cas:random_recruit_exec()
            -- Let this function blacklist itself if the chosen recruit is too expensive
            if wesnoth.unit_types[recruit].cost <= wesnoth.sides[wesnoth.current.side].gold then
                ai.recruit(recruit)
            end
        end

        return recruit_cas
    end
}
