return {
    add = function(side, cfg)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}

        local cfg_str = '{ type = "' .. cfg.type .. '" , attack_terrain = "' .. cfg.attack_terrain .. '", wander_terrain = "' .. cfg.wander_terrain .. '" }'

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "lurker_moves_lua",
                name = "lurker_moves_lua",
                max_score = 100010,
                evaluation = "return (...):lurker_attack_eval(" .. cfg_str .. ")",
                execution = "(...):lurker_attack_exec(" .. cfg_str .. ")"
            } }
        }
    end,

    delete = function(side)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[lurker_moves_lua]"
        }
    end
}
