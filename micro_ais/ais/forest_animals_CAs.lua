return {
    add = function(side, cfg_str)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "new_rabbit",
                name = "new_rabbit",
                max_score = 310000,
                evaluation="return (...):new_rabbit_eval()",
                execution="(...):new_rabbit_exec()"
            } }
        }
        
        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "tusker_attack",
                name = "tusker_attack",
                max_score = 300000,
                evaluation = "return (...):tusker_attack_eval()",
                execution = "(...):tusker_attack_exec()"
            } }
        }
        
        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "move",
                name = "move",
                max_score = 290000,
                evaluation = "return (...):move_eval()",
                execution = "(...):move_exec()"
            } }
        }
        
        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "tusklet",
                name = "tusklet",
                max_score = 280000,
                evaluation = "return (...):tusklet_eval()",
                execution = "(...):tusklet_exec()"
            } }
        }
    end,

    delete = function(side)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[new_rabbit]"
        }
        
        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[tusker_attack]"
        }
        
        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[move]"
        }
        
        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[tusklet]"
        }
    end
}
