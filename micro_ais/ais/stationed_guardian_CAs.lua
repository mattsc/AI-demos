return {
    activate = function(side, cfg)
        -- cfg contains extra options to be passed on to the CAs
        -- This needs to be set up as a string

        cfg = cfg or {}

        -- Add the ??? keys (just an empty string for the template)
        -- Can b left like this at first.  Modify when adding parameters.
        local cfg_str = ''
        local exec_arguments = "'" .. cfg.unitID .. "'," .. cfg.radius .. "," .. cfg.station_x .. "," .. cfg.station_y .. "," .. cfg.guard_x .. "," .. cfg.guard_y 
        
        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        --print("Activating template for Side " .. side)

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
            name="bca_statguard_" .. cfg.unitID,
            id="bca_statguard_" .. cfg.unitID,
            engine="lua",
            max_score=100010,
            sticky=1,
            evaluation="return (...):stationed_guardian_eval('"..cfg.unitID.."')",
            execution="(...):stationed_guardian_exec("..exec_arguments..")",
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
            path = "stage[main_loop].candidate_action[stat_guard]"
        }
    end
}
