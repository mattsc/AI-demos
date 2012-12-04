return {
    add = function(side, cfg)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                    engine = "lua",
                    name = "ca_big_animal_side" .. side,
                    id = "ca_big_animal_side" .. side,
                    max_score = 300000,
                    evaluation = "return (...):big_eval('" .. cfg.type .. "')",
                    execution = "(...):big_exec('" .. cfg.type .. "')"
            } }
        }
    end,

    delete = function(side)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[ca_big_animal_side" .. side .. "]"
        }
    end
}
