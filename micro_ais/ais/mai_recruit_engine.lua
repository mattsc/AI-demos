return {
    init = function(ai)

        local recruit_cas = {}
        -- The following external engine creates the CA functions recruit_rushers_eval and recruit_rushers_exec
        -- It also exposes find_best_recruit and find_best_recruit_hex for use by other recruit engines
        wesnoth.require("~add-ons/AI-demos/lua/generic-recruit_engine.lua").init(ai, recruit_cas)

        local recruit

        function recruit_cas:random_recruit_eval(cfg)
            local low_gold_recruit = cfg.low_gold_recruit

            -- Check if leader is on keep
            local leader = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]

            if (not leader) or (not wesnoth.get_terrain_info(wesnoth.get_terrain(leader.x, leader.y)).keep) then
                return 0
            end

            -- Check if there is no space left for recruiting
            local width,height,border = wesnoth.get_map_size()
            local castle = {
                locs = wesnoth.get_locations {
                    x = "1-"..width, y = "1-"..height,
                    { "and", {
                        x = leader.x, y = leader.y, radius = 200,
                        { "filter_radius", { terrain = 'C*^*,K*^*,*^Kov,*^Cov' } }
                    }}
                },
                x = leader.x,
                y = leader.y
            }
            local no_space = true
            for i,c in ipairs(castle.locs) do
                local unit = wesnoth.get_unit(c[1], c[2])
                if (not unit) then
                    no_space = false
                    break
                end
            end
            if no_space then
                return 0
            end

            local possible_recruits = wesnoth.sides[wesnoth.current.side].recruit
            recruit = possible_recruits[math.random(#possible_recruits)]
            if low_gold_recruit == "affordable" then
                while #possible_recruits > 0 do
                    local i = 1
                    if #possible_recruits > 1 then
                        i = math.random(#possible_recruits)
                    end
                    recruit = possible_recruits[i]
                    table.remove(possible_recruits, i)
                    if wesnoth.unit_types[recruit].cost <= wesnoth.sides[wesnoth.current.side].gold then
                        return 180000
                    end
                end
            else
                -- Use random without regard to gold as default
                if wesnoth.unit_types[recruit].cost <= wesnoth.sides[wesnoth.current.side].gold then
                    return 180000
                end
            end

            return 0
        end

        function recruit_cas:random_recruit_exec()
            ai.recruit(recruit)
        end

        return recruit_cas
    end
}
