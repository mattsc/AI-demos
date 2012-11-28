return {
    activate = function(side, cfg)
        -- cfg contains extra options to be passed on to the CAs
        -- This needs to be set up as a string

        cfg = cfg or {}

        -- Add the ??? keys (just an empty string for the messenger_escort)
        -- Can b left like this at first.  Modify when adding parameters.
        local cfg_str = '\'messenger\', 28, 1'

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        --print("Activating messenger escort for Side " .. side)

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "attack",
                name = "attack",
                max_score = 300000,
                evaluation = "return (...):attack_eval(" .. cfg_str .. ")",
                execution = "(...):attack_exec()"
            } }
        }
        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "messenger_move",
                name = "messenger_move",
                max_score = 290000,
                evaluation = "return (...):messenger_move_eval(" .. cfg_str .. ")",
                execution = "(...):messenger_move_exec(" .. cfg_str .. ")"
            } }
        }
        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "other_move",
                name = "other_move",
                max_score = 280000,
                evaluation = "return (...):other_move_eval(" .. cfg_str .. ")",
                execution = "(...):other_move_exec('messenger')"
            } }
        }
    end,

    remove = function(side)

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        --print("Removing messenger escort for Side " .. side)

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[attack]"
        }
        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[messenger_move]"
        }
        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[other_move]"
        }
    end
}
