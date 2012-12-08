return {
    add = function(side, cfg)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}
        
        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                name = "random_recruit",
                id = "random_recruit",
                max_score = 180000,
                evaluation = "return (...):random_recruit_eval('" .. cfg.low_gold_recruit .. "')",
                execution = "(...):random_recruit_exec()"
            } }
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[recruitment]"
        }
    end,

    delete = function(side)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}
        
        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[random_recruit]"
        }

        -- We also need to add the recruitment CA back in
        -- This works even if it was not removed, it simply overwrites the existing CA
        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                id="recruitment",
                engine="cpp",
                name="testing_ai_default::aspect_recruitment_phase",
                max_score=180000,
                score=180000
            } }
        }
    end
}
