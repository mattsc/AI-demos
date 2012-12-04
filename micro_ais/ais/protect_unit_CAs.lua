return {
    add = function(side, cfg)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}

        local cfg_str = ''
        -- Is this somewhat clunky?
        local parse = {}
        for value in cfg.units:gmatch("(%w+),?") do table.insert(parse, value) end
        local ids = ''
        local ids2 = ''
        for i = 1,#parse,3 do
            cfg_str = cfg_str .. '\'' .. parse[i] .. '\', ' .. parse[i+1] .. ', ' .. parse[i+2] .. ', '
            ids = ids .. '\'' .. parse[i] .. '\','
            ids2 = ids2 .. parse[i] .. ','
        end
        cfg_str = string.sub(cfg_str,1,-3)
        ids = string.sub(ids,1,-2)
        ids2 = string.sub(ids2,1,-2)

        W.modify_ai {
            side = side,
            action = "add",
            path = "aspect[attacks].facet",
            { "facet", {
                name = "testing_ai_default::aspect_attacks",
                id = "dont_attack",
                invalidate_on_gamestate_change = "yes",
                { "filter_own", {
                    { "not", {
                        id = ids2
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
                id = "finish",
                name = "finish",
                max_score = 300000,
                evaluation = "return (...):finish_eval(" .. cfg_str .. ")",
                execution = "(...):finish_exec()"
            } }
        }

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "attack",
                name = "attack",
                max_score = 95000,
                evaluation = "return (...):attack_eval(" .. ids .. ")",
                execution = "(...):attack_exec()"
            } }
        }

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "move",
                name = "move",
                max_score = 94000,
                evaluation = "return (...):move_eval(" .. ids .. ")",
                execution = "(...):move_exec(" .. cfg_str .. ")"
            } }
        }

        if cfg.disable_move_leader_to_keep then
            W.modify_ai {
                side = side,
                action = "try_delete",
                path = "stage[main_loop].candidate_action[move_leader_to_keep]"
            }
        end
    end,

    delete = function(side)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "aspect[attacks].facet[dont_attack]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[finish]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[attack]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[move]"
        }

        -- We also need to add the move_leader_to_keep CA back in
        -- This works even if it was not removed, it simply overwrites the existing CA
        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                id="move_leader_to_keep",
                engine="cpp",
                name="testing_ai_default::move_leader_to_keep_phase",
                max_score=160000,
                score=160000
            } }
        }


    end
}
