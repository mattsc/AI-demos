return {
    add = function(side, cfg_str)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                name = "wolves_multipacks_attack",
                id = "wolves_multipacks_attack",
                max_score = 300000,
                evaluation = "return (...):wolves_multipacks_attack_eval()",
                execution = "(...):wolves_multipacks_attack_exec()"
            } }
        }

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                name = "wolves_multipacks_wander",
                id = "wolves_multipacks_wander",
                max_score = 290000,
                evaluation = "return (...):wolves_multipacks_wander_eval()",
                execution = "(...):wolves_multipacks_wander_exec()"
            } }
        }
    end,

    delete = function(side)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[wolves_multipacks_attack]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[wolves_multipacks_wander_side]"
        }
    end
}
