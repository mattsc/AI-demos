return {
    activate = function(side, cfg)
        -- cfg contains extra options to be passed on to the CAs
        -- This needs to be set up as a string
        local max_scores = {}
        max_scores["stationed_guardian"] = 100010
        max_scores["coward"] = 300000
   
        cfg = cfg or {}
        local guardian_type = cfg.guardian_type

        local cfg_str = ''
        local exec_arguments = ''
        local eval_arguments = ''
		
		if (guardian_type=="stationed_guardian") then
          exec_arguments = "'" .. cfg.unitID .. "'," .. cfg.radius .. "," .. cfg.station_x .. "," .. cfg.station_y .. "," .. cfg.guard_x .. "," .. cfg.guard_y 
          eval_arguments = "'" .. cfg.unitID .. "'"
        end
        if (guardian_type=="coward") then
          exec_arguments = "'" .. cfg.unitID .. "'," .. cfg.radius .. "," .. cfg.seek_x .. "," .. cfg.seek_y .. "," .. cfg.avoid_x .. "," .. cfg.avoid_y 
          eval_arguments = "'" .. cfg.unitID .. "'"
        end
        if (guardian_type=="return_guardian") then
          exec_arguments = "'" .. cfg.unitID .. "'," .. cfg.to_x .. "," .. cfg.to_y 
          eval_arguments = "'" .. cfg.unitID .. "'," .. cfg.to_x .. "," .. cfg.to_y 
        end
        
        
        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}
        local unit = wesnoth.get_units { id=cfg.unitID }[1]
        --print("Activating template for Side " .. side)
        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
            name="bca_" .. guardian_type .. "_" .. cfg.unitID,
            id="bca_" .. guardian_type .. "_" .. cfg.unitID,
            engine="lua",
            max_score=max_scores[guardian_type],
            sticky=1,
            unit_x=unit.x,
            unit_y=unit.y,
            evaluation="return (...):" .. guardian_type .. "_eval(" .. eval_arguments .. ")",
            execution="(...):" .. guardian_type .. "_exec("..exec_arguments..")",
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
