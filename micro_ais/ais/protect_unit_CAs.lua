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

        --print("Activating protect unit for Side " .. side)

        W.modify_ai {
            side = side,
            action = "add",
            path = "aspect[attacks].facet",
            { "facet", {
                name = "testing_ai_default::aspect_attacks",
                id = "dont_attack",
                invalidate_on_gamestate_change = "yes",
                { "filter_own", {
                    { "not", {
                        id = "Rossauba"
                    } }
                } }
            } }
        }
        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "finish",
                name = "finish",
                max_score = 300000,
                evaluation = "return (...):finish_eval('Rossauba', 1, 1)",
                execution = "(...):finish_exec()"
            } }
        }
        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "attack",
                name = "attack",
                max_score = 95000,
                evaluation = "return (...):attack_eval('Rossauba')",
                execution = "(...):attack_exec()"
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
                max_score = 94000,
                evaluation = "return (...):move_eval('Rossauba')",
                execution = "(...):move_exec('Rossauba', 1, 1)"
            } }
        }
    end,

    remove = function(side)

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        --print("Removing protect unit for Side " .. side)

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "aspect[attacks].facet[dont_attack]"
        }
        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[finish]"
        }
        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[attack]"
        }
        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[move]"
        }
    end
}
