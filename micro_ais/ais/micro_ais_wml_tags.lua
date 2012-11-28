local H = wesnoth.require "lua/helper.lua"
local W = H.set_wml_action_metatable {}
local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
local LS = wesnoth.require "lua/location_set.lua"
local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

function wesnoth.wml_actions.micro_ai(cfg)
    -- Set up the [micro_ai] tag
    -- Configuration tag for the micro AIs

    cfg = cfg or {}

    -- Check that the required attributes are set correctly
    if (not cfg.ai_type) then H.wml_error("[micro_ai] missing required ai_type= attribute") end
    if (not cfg.side) then H.wml_error("[micro_ai] missing required side= attribute") end
    if (not cfg.action) then H.wml_error("[micro_ai] missing required action= attribute") end

    if (cfg.action ~= 'add') and (cfg.action ~= 'delete') and (cfg.action ~= 'change') then
        H.wml_error("invalid action= in [micro_ai].  Allowed values: add, delete or change")
    end

    -- Now deal with each specific micro AI

    --------- Healer Support Micro AI ------------------------------------
    if (cfg.ai_type == 'healer_support') then
        -- If aggression = 0: Never let the healers participate in attacks
        -- This is done by not deleting the attacks aspect

        local cfg_hs = {}
        if cfg.injured_units_only then cfg_hs.injured_units_only = true end
        if cfg.max_threats then cfg_hs.max_threats = cfg.max_threats end

        -- Add the CAs
        if (cfg.action == 'add') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/healer_support_CAs.lua".activate(cfg.side, cfg_hs)
        end

        -- Change the CAs (done by deleting, then adding again, so that parameters get reset)
        if (cfg.action == 'change') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/healer_support_CAs.lua".remove(cfg.side)
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/healer_support_CAs.lua".activate(cfg.side, cfg_hs)
        end

        -- Remove the CAs
        if (cfg.action == 'delete') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/healer_support_CAs.lua".remove(cfg.side)
        end

        -- Configure the CAs
        if (cfg.action == 'add') or (cfg.action == 'change') then
            -- Aggression (keep or remove the healers_can_attack CA)
            local aggression = cfg.aggression or 1.0
            if (aggression == 0) then
                --print("[micro_ai] healer_support: Deleting the healers_can_attack CA of Side " .. cfg.side)
                W.modify_ai {
                    side = cfg.side,
                    action = "try_delete",
                    path = "stage[main_loop].candidate_action[healers_can_attack]"
                }
            end
        end

        return
    end

    --------- Bottleneck Defense Micro AI ------------------------------------
    if (cfg.ai_type == 'bottleneck_defense') then

        -- Set up the cfg array
        local cfg_bd = {}

        -- x,y for bottleneck defense
        if (not cfg.x) or (not cfg.y) then
            H.wml_error("Bottleneck Defense Micro AI missing required x= and/or y= attribute")
        else
            cfg_bd.x, cfg_bd.y = cfg.x, cfg.y
        end

        -- enemy_x,enemy_y for bottleneck defense
        if (not cfg.enemy_x) or (not cfg.enemy_y) then
            H.wml_error("Bottleneck Defense Micro AI missing required enemy_x= and/or enemy_y= attribute")
        else
            cfg_bd.enemy_x, cfg_bd.enemy_y = cfg.enemy_x, cfg.enemy_y
        end

        -- Optional keys: healer_x, healer_y
        if cfg.healer_x and cfg.healer_y then
            cfg_bd.healer_x = cfg.healer_x
            cfg_bd.healer_y = cfg.healer_y
        end

        -- Optional keys: leadership_x, leadership_y
        if cfg.leadership_x and cfg.leadership_y then
            cfg_bd.leadership_x = cfg.leadership_x
            cfg_bd.leadership_y = cfg.leadership_y
        end

        -- Optional key: active_side_leader
        if cfg.active_side_leader then
            cfg_bd.active_side_leader = cfg.active_side_leader
        end

        -- Add the CAs
        if (cfg.action == 'add') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/bottleneck_defense_CAs.lua".activate(cfg.side, cfg_bd)
        end

        -- Change the CAs (done by deleting, then adding again, so that parameters get reset)
        if (cfg.action == 'change') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/bottleneck_defense_CAs.lua".remove(cfg.side)
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/bottleneck_defense_CAs.lua".activate(cfg.side, cfg_bd)
        end

        -- Remove the CAs
        if (cfg.action == 'delete') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/bottleneck_defense_CAs.lua".remove(cfg.side)
        end

        return
    end

    --------- Micro AI Template ------------------------------------
    if (cfg.ai_type == 'template') then

         -- Set up the cfg array
        local cfg_template = {}

       -- Add the CAs
        if (cfg.action == 'add') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/template_CAs.lua".activate(cfg.side, cfg_template)
        end

        -- Change the CAs (done by deleting, then adding again, so that parameters get reset)
        if (cfg.action == 'change') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/template_CAs.lua".remove(cfg.side)
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/template_CAs.lua".activate(cfg.side, cfg_template)
        end

        -- Remove the CAs
        if (cfg.action == 'delete') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/template_CAs.lua".remove(cfg.side)
        end

        return
    end

    --------- Micro AI Animals ------------------------------------
    if (cfg.ai_type == 'animals') then

         -- Set up the cfg array
        local cfg_animals = {}

       -- Add the CAs
        if (cfg.action == 'add') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/dragon_CAs.lua".activate(cfg.side, cfg_messenger_escort)
        end

        -- Change the CAs (done by deleting, then adding again, so that parameters get reset)
        if (cfg.action == 'change') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/dragon_CAs.lua".remove(cfg.side)
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/dragon_CAs.lua".activate(cfg.side, cfg_messenger_escort)
        end

        -- Remove the CAs
        if (cfg.action == 'delete') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/dragon_CAs.lua".remove(cfg.side)
        end

        return
    end

    ----------------------------------------------------------------
    -- If we got here, none of the valid ai_types was specified
    H.wml_error("invalid ai_type= in [micro_ai]")
end
