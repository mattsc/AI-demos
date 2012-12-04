return {
    add = function(side, cfg_str)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                    engine = "lua",
                    name = "scatter_swarm",
                    id = "scatter_swarm",
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
                    name = "move_swarm",
                    id = "move_swarm",
                    max_score = 290000,
                    evaluation = "return (...):move_swarm_eval()",
                    execution = "(...):move_swarm_exec()"
            } }
        }
    end,

    delete = function(side)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[scatter_swarm]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[move_swarm]"
        }
    end
}
