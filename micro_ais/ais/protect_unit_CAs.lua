return {
    activate = function(side, cfg)
        -- cfg contains extra options to be passed on to the CAs
        -- This needs to be set up as a string

        cfg = cfg or {}

        local cfg_str = ''

        -- Is this somewhat clunky?
        local parse = {}
        for value in cfg.id:gmatch("(%w+),?") do table.insert(parse, value) end
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


        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}
        --print("Activating protect unit for Side " .. side)
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

    remove = function(side)

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        --print("Removing protect unit for Side " .. side)

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
    end
}
