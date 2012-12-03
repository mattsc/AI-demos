return {
    add = function(side, cfg_str)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "bottleneck_move",
                name = "bottleneck_move",
                max_score = 300000,
                evaluation = "return (...):bottleneck_move_eval(" .. cfg_str .. ")",
                execution = "(...):bottleneck_move_exec()"
            } }
        }

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "bottleneck_attack",
                name = "bottleneck_attack",
                max_score = 290000,
                evaluation = "return (...):bottleneck_attack_eval()",
                execution = "(...):bottleneck_attack_exec()"
            } }
        }
    end,

    delete = function(side)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[bottleneck_move]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[bottleneck_attack]"
        }
    end
}
