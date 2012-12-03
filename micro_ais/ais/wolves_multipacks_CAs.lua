return {
    add = function(side, cfg_str)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                name = "ca_wolves_multipacks_attack_side" .. side,
                id = "ca_wolves_multipacks_attack_side" .. side,
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
                name = "ca_wolves_multipacks_wander_side" .. side,
                id = "ca_wolves_multipacks_wander_side" .. side,
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
            path = "stage[main_loop].candidate_action[ca_wolves_multipacks_attack_side" .. side .. "]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[ca_wolves_multipacks_wander_side" .. side .. "]"
        }
    end
}
