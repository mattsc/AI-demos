return {
    add = function(side)
        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        --print("Activating template for Side " .. side)

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                    engine = "lua",
                    name = "ca_scatter_swarm_side" .. side,
                    id = "ca_scatter_swarm_side" .. side,
                    max_score = 300000,
                    evaluation = "return (...):scatter_swarm_eval()",
                    execution = "(...):scatter_swarm_exec()"
            } }
        }

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                    engine = "lua",
                    name = "ca_move_swarm_side" .. side,
                    id = "ca_move_swarm_side" .. side,
                    max_score = 290000,
                    evaluation = "return (...):move_swarm_eval()",
                    execution = "(...):move_swarm_exec()"
            } }
        }
    end,

    delete = function(side)

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        --print("Removing template for Side " .. side)

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[ca_scatter_swarm_side" .. side .. "]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[ca_move_swarm_side" .. side .. "]"
        }
    end
}
