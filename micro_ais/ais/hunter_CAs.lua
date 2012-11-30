return {
    activate = function(side, cfg)
        -- cfg contains extra options to be passed on to the CAs
        -- This needs to be set up as a string

        cfg = cfg or {}

        -- Add the id key
        local cfg_str = "'" .. cfg.id .. "', "
        
        -- Add the hunt_x, hunt_y keys
        local cfg_str = cfg_str .. "'" .. cfg.hunt_x .. "', " .. "'" .. cfg.hunt_y .. "', "

        -- Add the home_x, home_y keys
        local cfg_str = cfg_str ..  cfg.home_x .. ", "  .. cfg.home_y .. ", "

        -- Add the rest_turns key
        local cfg_str = cfg_str .. cfg.rest_turns

        -- Get the unit with the ID, so we don't have to ask for coordinates
        local unit = wesnoth.get_units { id=cfg.id }[1]
        
        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        --print("Activating template for Side " .. side)

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "bca_hunter_" .. cfg.id,
                name = "bca_hunter_" .. cfg.id,
                max_score = 300000,
                sticky = "yes",
                unit_x = unit.x,
                unit_y = unit.y,
                evaluation = "return (...):hunt_and_rest_eval(" .. cfg.id .. ")",
                execution = "(...):hunt_and_rest_exec(" .. cfg_str .. ")"
            } }
        }
    end,

    remove = function(side, id)

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        --print("Removing template for Side " .. side)

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[bca_hunter_" .. id .. "]"
        }
    end
}
