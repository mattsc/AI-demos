return {
    add = function(side, cfg)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}

        -- Required key: id
        local cfg_str = '{ id = "' .. cfg.id .. '"'

        -- Required keys: goal_x, goal_y
        local cfg_str = cfg_str .. ', goal_x = "' .. cfg.goal_x .. '", goal_y = "' .. cfg.goal_y .. '"'

        -- Optional key: enemy_death_chance
        if cfg.enemy_death_chance then
            cfg_str = cfg_str .. ', enemy_death_chance = "' .. cfg.enemy_death_chance .. '"'
        end

        -- Optional key: messenger_death_chance
        if cfg.messenger_death_chance then
            cfg_str = cfg_str .. ', messenger_death_chance = "' .. cfg.messenger_death_chance .. '"'
        end

        cfg_str = cfg_str .. ' }'

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "attack",
                name = "attack",
                max_score = 300000,
                evaluation = "return (...):attack_eval(" .. cfg_str .. ")",
                execution = "(...):attack_exec()"
            } }
        }

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "messenger_move",
                name = "messenger_move",
                max_score = 290000,
                evaluation = "return (...):messenger_move_eval(" .. cfg_str .. ")",
                execution = "(...):messenger_move_exec(" .. cfg_str .. ")"
            } }
        }

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "other_move",
                name = "other_move",
                max_score = 280000,
                evaluation = "return (...):other_move_eval(" .. cfg_str .. ")",
                execution = "(...):other_move_exec(" .. cfg_str .. ")"
            } }
        }
    end,

    delete = function(side)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[attack]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[messenger_move]"
        }

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[other_move]"
        }
    end
}
