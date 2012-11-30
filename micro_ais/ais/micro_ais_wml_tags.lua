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

   --------- Messenger Escort Micro AI ------------------------------------
    if (cfg.ai_type == 'messenger_escort') then

         -- Set up the cfg array
        local cfg_me = {}

        -- id for messenger escort
        if (not cfg.id) then
            H.wml_error("Messenger Escort Micro AI missing required id= attribute")
        else
            cfg_me.id = cfg.id
        end

        -- goal_x,goal_y for messenger escort
        if (not cfg.goal_x) or (not cfg.goal_y) then
            H.wml_error("Messenger Escort Micro AI missing required goal_x= and/or goal_y= attribute")
        else
            cfg_me.goal_x, cfg_me.goal_y = cfg.goal_x, cfg.goal_y
        end

        -- Optional: enemy_death_chance
        if cfg.enemy_death_chance then
            cfg_me.enemy_death_chance = cfg.enemy_death_chance
        end

        -- Optional: messenger_death_chance
        if cfg.messenger_death_chance then
            cfg_me.messenger_death_chance = cfg.messenger_death_chance
        end

       -- Add the CAs
        if (cfg.action == 'add') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/messenger_escort_CAs.lua".activate(cfg.side, cfg_me)
        end

        -- Change the CAs (done by deleting, then adding again, so that parameters get reset)
        if (cfg.action == 'change') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/messenger_escort_CAs.lua".remove(cfg.side)
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/messenger_escort_CAs.lua".activate(cfg.side, cfg_me)
        end

        -- Remove the CAs
        if (cfg.action == 'delete') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/messenger_escort_CAs.lua".remove(cfg.side)
        end

        return
    end

        --------- Lurkers Micro AI ------------------------------------
    if (cfg.ai_type == 'lurkers') then

         -- Set up the cfg array
        local cfg_lurk = {}

        -- Add the CAs
        if (cfg.action == 'add') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/lurkers_CAs.lua".activate(cfg.side, cfg_lurk)
        end

        -- Change the CAs (done by deleting, then adding again, so that parameters get reset)
        if (cfg.action == 'change') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/lurkers_CAs.lua".remove(cfg.side)
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/lurkers_CAs.lua".activate(cfg.side, cfg_lurk)
        end

        -- Remove the CAs
        if (cfg.action == 'delete') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/lurkers_CAs.lua".remove(cfg.side)
        end

        return
    end

    --------- Protect Unit Micro AI ------------------------------------
    if (cfg.ai_type == 'protect_unit') then

         -- Set up the cfg array
        local cfg_pu = {}

        -- units for protect unit
        if (not cfg.units) then
            H.wml_error("Protect Unit Micro AI missing required units= attribute")
        else
            cfg_pu.units = cfg.units
        end

        -- Optional: disable_move_leader_to_keep for protect unit
        if cfg.disable_move_leader_to_keep then
            cfg_pu.disable_move_leader_to_keep = cfg.disable_move_leader_to_keep
        end

        -- Add the CAs
        if (cfg.action == 'add') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/protect_unit_CAs.lua".activate(cfg.side, cfg_pu)
        end

        -- Change the CAs (done by deleting, then adding again, so that parameters get reset)
        if (cfg.action == 'change') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/protect_unit_CAs.lua".remove(cfg.side)
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/protect_unit_CAs.lua".activate(cfg.side, cfg_pu)
        end

        -- Remove the CAs
        if (cfg.action == 'delete') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/protect_unit_CAs.lua".remove(cfg.side)
        end

        return
    end

    --------- Micro AI Guardian-----------------------------------
    if (cfg.ai_type == 'guardian') then
        -- We handle all types of guardians here.  Confirm we have made a choice
        if (not cfg.guardian_type) then H.wml_error("[micro_ai] missing required guardian_type= attribute") end
        local guardian_type = cfg.guardian_type

         -- Set up the cfg array
        local cfg_guardian = {}
        local required_attributes = {}
        local optional_attributes = {}
        required_attributes["stationed_guardian"] = {"id", "radius", "station_x", "station_y", "guard_x", "guard_y"}
        optional_attributes["stationed_guardian"] = {}

        required_attributes["coward"] = {"id", "radius"}
        optional_attributes["coward"] = {"seek_x", "seek_y","avoid_x","avoid_y"}

        required_attributes["return_guardian"] = {"id", "to_x", "to_y"}
        optional_attributes["return_guardian"] = {}
        if (cfg.action~='delete') then
            --Check that we know about this type of guardian
            if (not required_attributes[guardian_type]) then H.wml_error("[micro_ai] unknown guardian type '" .. guardian_type .."'") end

            --Add in the required attributes
           for j,i in pairs(required_attributes[guardian_type]) do
                if (not cfg[i]) then H.wml_error("[micro_ai] ".. guardian_type .." missing required " .. i .. "= attribute") end
                cfg_guardian[i] = cfg[i]
            end

            --Add in the optional attributes
            for j,i in pairs(optional_attributes[guardian_type]) do
              cfg_guardian[i] = cfg[i] or "''"
            end
        end

        --Lastly, specify the type
        cfg_guardian.guardian_type = guardian_type

       -- Add the CAs
        if (cfg.action == 'add') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/guardian_CAs.lua".activate(cfg.side, cfg_guardian)
        end

        -- Change the CAs (done by deleting, then adding again, so that parameters get reset)
        if (cfg.action == 'change') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/guardian_CAs.lua".remove(cfg.side,guardian_type,cfg.id)
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/guardian_CAs.lua".activate(cfg.side, cfg_guardian)
        end

        -- Remove the CAs
        if (cfg.action == 'delete') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/guardian_CAs.lua".remove(cfg.side,guardian_type,cfg.id)
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
        local required_attributes = {}

        -- This list does not contain id because we check for that differently
        required_attributes["hunter"] = {"hunt_x", "hunt_y", "home_x", "home_y", "rest_turns",}

        if (not cfg["id"]) then H.wml_error("[micro_ai] hunter missing required id= attribute")
        else
            cfg_animals["id"] = cfg["id"]

            -- Remove the CAs
            if (cfg.action == 'delete') then
                wesnoth.require "~add-ons/AI-demos/micro_ais/ais/hunter_CAs.lua".remove(cfg.side, cfg.id)
            else

                for j,i in pairs(required_attributes["hunter"]) do
                    if (not cfg[i]) then H.wml_error("[micro_ai] ".. "hunter" .." missing required " .. i .. "= attribute") end
                        cfg_animals[i] = cfg[i]
                    end

                -- Add the CAs
                if (cfg.action == 'add') then
                    wesnoth.require "~add-ons/AI-demos/micro_ais/ais/hunter_CAs.lua".activate(cfg.side, cfg_animals)
                end

                -- Change the CAs (done by deleting, then adding again, so that parameters get reset)
                if (cfg.action == 'change') then
                    wesnoth.require "~add-ons/AI-demos/micro_ais/ais/hunter_CAs.lua".remove(cfg.side, cfg.id)
                    wesnoth.require "~add-ons/AI-demos/micro_ais/ais/hunter_CAs.lua".activate(cfg.side, cfg_animals)
                end
            end
        end

        return
    end

    ----------------------------------------------------------------
    -- If we got here, none of the valid ai_types was specified
    H.wml_error("invalid ai_type= in [micro_ai]")
end

