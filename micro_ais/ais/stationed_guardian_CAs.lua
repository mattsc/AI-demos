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

        print("Activating template for Side " .. side)

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "go_home",
                name = "go_home",
                max_score = 300000,
                evaluation = "return (...):stationed_guardian_eval(" .. cfg_str .. ")",
                execution = "(...):stationed_guardian_exec('stationed1',4,4,13,7,15)"
            } }
        }
    end,

    remove = function(side)

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        print("Removing template for Side " .. side)

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[go_home]"
        }
    end
}
