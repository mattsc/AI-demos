return {
    activate = function(side, cfg)
        -- cfg contains extra options to be passed on to the CAs
        -- This needs to be set up as a string

        cfg = cfg or {}

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
            cfg_str = cfg_str .. ', attack_targets = {'
            for value in cfg.attack_targets:gmatch("(%w+),?") do cfg_str = cfg_str .. '\'' .. value .. '\',' end
            cfg_str = string.sub(cfg_str,1,-2) .. '}'
        end

        cfg_str = cfg_str .. ' }'

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        --print("Activating patrol for Side " .. side)

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = "bca_patrol",
                name = "bca_patrol",
                max_score = 300000,
                sticky = yes,
                evaluation = "return (...):patrol_eval(" .. cfg_str .. ")",
                execution = "(...):patrol_exec(" .. cfg_str .. ")"
            } }
        }
    end,

    remove = function(side)

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        --print("Removing patrol for Side " .. side)

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[bca_patrol]"
        }
    end
}
