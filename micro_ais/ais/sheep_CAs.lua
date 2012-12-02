return {
    activate = function(side, cfg)
        -- cfg contains extra options to be passed on to the CAs
        -- This needs to be set up as a string

        cfg = cfg or {}

        -- Add the ??? keys (just an empty string for the template)
        -- Can b left like this at first.  Modify when adding parameters.
        local cfg_str = ''

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        --print("Activating template for Side " .. side)

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                name = "ca_close_enemy_side" .. side,
                id = "ca_close_enemy_side" .. side,
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
                name = "ca_sheep_runs_enemy_side" .. side,
                id = "ca_sheep_runs_enemy_side" .. side,
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
                name = "ca_sheep_runs_dog_side" .. side,
                id = "ca_sheep_runs_dog_side" .. side,
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
                name = "ca_herd_sheep_side" .. side,
                id = "ca_herd_sheep_side" .. side,
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
                name = "ca_sheep_move_side" .. side,
                id = "ca_sheep_move_side" .. side,
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
                name = "ca_dog_move_side" .. side,
                id = "ca_dog_move_side" .. side,
                max_score = 260000,
                evaluation = "return (...):dog_move_eval()",
                execution = "(...):dog_move_exec()"
            } }
        }
    end,

    remove = function(side)

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        --print("Removing template for Side " .. side)

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[ca_close_enemy_side" .. side .. "]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[ca_sheep_runs_enemy_side" .. side .. "]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[ca_sheep_runs_dog_side" .. side .. "]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[ca_herd_sheep_side" .. side .. "]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[ca_sheep_move_side" .. side .. "]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[ca_dog_move_side" .. side .. "]"
        }
    end
}
