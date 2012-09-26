return {
    activate = function(side, cfg)
        -- cfg contains extra options to be passed on to the CAs
        -- This needs to be set up as a string

        cfg = cfg or {}

        -- Add the x,y= keys
        local cfg_str = '{ x = "' .. cfg.x .. '", y = "' .. cfg.y .. '"'

        -- Add the enemy_x,enemy_y= keys
        local cfg_str = cfg_str .. ', enemy_x = "' .. cfg.enemy_x .. '", enemy_y = "' .. cfg.enemy_y .. '"'

        -- Add the healer_x,healer_y= keys
        if cfg.healer_x and cfg.healer_y then
            cfg_str = cfg_str .. ', healer_x = "' .. cfg.healer_x .. '", healer_y = "' .. cfg.healer_y .. '"'
        end

        -- Add the leader_x,leader_y= keys
        if cfg.leader_x and cfg.leader_y then
            cfg_str = cfg_str .. ', leader_x = "' .. cfg.leader_x .. '", leader_y = "' .. cfg.leader_y .. '"'
        end

        -- Closing bracket
        cfg_str = cfg_str .. ' }'

        --print('Bottleneck Defense: cfg_str = ',cfg_str)

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        --print("Activating bottleneck_defense for Side " .. side)

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "bottleneck_move",
                name = "bottleneck_move",
                max_score = 300000,
                evaluation = "return (...):bottleneck_move_eval(" .. cfg_str .. ")",
                execution = "(...):bottleneck_move_exec()"
            } }
        }

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "bottleneck_attack",
                name = "bottleneck_attack",
                max_score = 290000,
                evaluation = "return (...):bottleneck_attack_eval()",
                execution = "(...):bottleneck_attack_exec()"
            } }
        }
    end,

    remove = function(side)

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        --print("Removing bottleneck_defense for Side " .. side)

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[bottleneck_move]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[bottleneck_attack]"
        }
    end
}
