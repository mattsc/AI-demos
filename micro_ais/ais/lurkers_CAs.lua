return {
    activate = function(side, cfg)
        -- cfg contains extra options to be passed on to the CAs
        -- This needs to be set up as a string

        cfg = cfg or {}

        -- Add the ??? keys (just an empty string for the lurkers)
        -- Can b left like this at first.  Modify when adding parameters.
        local cfg_str = ''

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        --print("Activating lurkers for Side " .. side)

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "lurker_moves_lua",
                name = "lurker_moves_lua",
                max_score = 100010,
                evaluation = "return (...):lurker_attack_eval()",
                execution = "(...):lurker_attack_exec()"
            } }
        }
    end,

    remove = function(side)

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        --print("Removing lurkers for Side " .. side)

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[lurker_moves_lua]"
        }
    end
}
