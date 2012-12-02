return {
    activate = function(side, cfg_str)
        -- cfg contains extra options to be passed on to the CAs
        -- This needs to be set up as a string

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        --print("Activating bottleneck_defense for Side " .. side)

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

    remove = function(side)

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        --print("Removing bottleneck_defense for Side " .. side)

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
