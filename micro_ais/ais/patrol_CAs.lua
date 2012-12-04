return {
    add = function(side, cfg)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}

        -- Required key: id
        local cfg_str = '{ id = "' .. cfg.id .. '"'

        -- Required keys: waypoint_x, waypoint_y
        local cfg_str = cfg_str .. ', waypoint_x = {' .. cfg.waypoint_x .. '}, waypoint_y = {' .. cfg.waypoint_y .. '}'

        -- Optional key: attack_all
        if cfg.attack_all then
            cfg_str = cfg_str .. ', attack_all = ' .. tostring(cfg.attack_all)
        end

        -- Optional key: attack_targets
        if cfg.attack_targets then
            cfg_str = cfg_str .. ', attack_targets = "' .. cfg.attack_targets .. '"'
        end

        cfg_str = cfg_str .. ' }'

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "patrol_unit_" .. cfg.id,
                name = "patrol_unit_" .. cfg.id,
                max_score = 300000,
                sticky = yes,
                evaluation = "return (...):patrol_eval(" .. cfg_str .. ")",
                execution = "(...):patrol_exec(" .. cfg_str .. ")"
            } }
        }
    end,

    delete = function(side, cfg)
        local W = wesnoth.require "lua/helper.lua".set_wml_action_metatable {}

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[patrol_unit_" .. cfg.id .. "]"
        }
    end
}
