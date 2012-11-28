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
                id = "bca_huntrest_{ID}",
                name = "bca_huntrest_{ID}",
                max_score = 300000,
                sticky = "yes",
                unit_x = cfg.x,
                unit_y = cfg.y,
                evaluation = "return (...):hunt_and_rest_eval('{ID}')",
                execution = "(...):hunt_and_rest_exec('{ID}', '{HUNT_X}', '{HUNT_X}', {HOME_X}, {HOME_Y}, {REST_TURNS})"
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
            path = "stage[main_loop].candidate_action[bca_huntrest_{ID}]"
        }
    end
}
