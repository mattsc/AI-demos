return {
    add = function(side, cfg)
        -- cfg contains extra options to be passed on to the CAs
        -- This needs to be set up as a string

        cfg = cfg or {}
        local cfg_str = '{ dummy = false' -- This is a dirty trick ...
        -- Only one option so far, so this is easy
        if cfg.injured_units_only then
            cfg_str = cfg_str ..', injured_units_only = true'
        end
        if cfg.max_threats then
            cfg_str = cfg_str ..', max_threats = ' .. cfg.max_threats
        end
        cfg_str = cfg_str .. ' }'
        --print('cfg_str', cfg_str)

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        --print("Activating healer_support for Side " .. side)

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "initialize_healer_support",
                name = "initialize_healer_support",
                max_score = 999990,
                evaluation = "return (...):initialize_healer_support_eval()",
                execution = "(...):initialize_healer_support_exec()"
            } }
        }

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "healer_support",
                name = "healer_support",
                max_score = 105000,
                evaluation = "return (...): healer_support_eval(" .. cfg_str .. ")",
                execution = "(...):healer_support_exec()"
            } }
        }

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "healers_can_attack",
                name = "healers_can_attack",
                max_score = 99990,
                evaluation = "return (...): healers_can_attack_eval()",
                execution = "(...): healers_can_attack_eval()"
            } }
        }
    end,

    delete = function(side)

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        --print("Removing healer_support for Side " .. side)

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[initialize_healer_support]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[healer_support]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[healers_can_attack]"
        }
    end
}
