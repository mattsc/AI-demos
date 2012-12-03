return {
    add = function(side, cfg)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}

        W.modify_ai {
            side = side,
            action = "add",
            path = "aspect[attacks].facet",
            { "facet", {
                name = "testing_ai_default::aspect_attacks",
                id = "dont_attack_used_on_side" .. side,
                invalidate_on_gamestate_change = "yes",
                { "filter_enemy", {
                    { "not", {
                        type=cfg.to_avoid
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
                name = "ca_wolves_side" .. side,
                id = "ca_wolves_side" .. side,
                max_score = 95000,
                evaluation = "return (...):wolves_eval('" .. cfg.to_avoid .. "')",
                execution = "(...):wolves_exec('" .. cfg.to_avoid .. "')"
            } }
        }

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                name = "ca_wolves_wander_side" .. side,
                id = "ca_wolves_wander_side" .. side,
                max_score = 90000,
                evaluation = "return (...):wolves_wander_eval('" .. cfg.to_avoid .. "')",
                execution = "(...):wolves_wander_exec('" .. cfg.to_avoid .. "')"
            } }
        }
    end,

    delete = function(side)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "aspect[attacks].facet[dont_attack_used_on_side" .. side .. "]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[ca_wolves_side" .. side .. "]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[ca_wolves_wander_side" .. side .. "]"
        }
    end
}
