return {
    add = function(side, cfg_str)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                name = "close_enemy",
                id = "close_enemy",
                max_score = 300000,
                evaluation = "return (...):close_enemy_eval()",
                execution = "(...):close_enemy_exec()"
            } }
        }

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                name = "sheep_runs_enemy",
                id = "sheep_runs_enemy",
                max_score = 295000,
                evaluation = "return (...):sheep_runs_enemy_eval()",
                execution = "(...):sheep_runs_enemy_exec()"
            } }
        }

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                name = "sheep_runs_dog",
                id = "sheep_runs_dog",
                max_score = 290000,
                evaluation = "return (...):sheep_runs_dog_eval()",
                execution = "(...):sheep_runs_dog_exec()"
            } }
        }

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                name = "herd_sheep",
                id = "herd_sheep",
                max_score = 280000,
                evaluation = "return (...):herd_sheep_eval()",
                execution = "(...):herd_sheep_exec()"
            } }
        }

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                name = "sheep_move",
                id = "sheep_move",
                max_score = 270000,
                evaluation = "return (...):sheep_move_eval()",
                execution = "(...):sheep_move_exec()"
            } }
        }

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                name = "dog_move",
                id = "dog_move",
                max_score = 260000,
                evaluation = "return (...):dog_move_eval()",
                execution = "(...):dog_move_exec()"
            } }
        }
    end,

    delete = function(side)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[close_enemy]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[sheep_runs_enemy]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[sheep_runs_dog]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[herd_sheep]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[sheep_move]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[dog_move]"
        }
    end
}
