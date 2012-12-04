local H = wesnoth.require "lua/helper.lua"
local W = H.set_wml_action_metatable {}
local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"

function add_CAs(side, CA_parms)
    -- Add the candidate actions defined in 'CA_parms' to the AI of 'side'
    -- CA_parms is an array of tables, one for each CA to be added
    --
    -- Required keys for CA_parms:
    --  - id: is used for both CA id and name
    --  - eval_name: name of the evaluation function
    --  - exec_name: name of the execution function
    --
    -- Optional keys for CA_parms:
    --  - cfg_str: a configuration string (in form of a Lua WML table), to be passed to eval and exec functions
    --      Note: we pass the same string to both functions, even if it contains unnecessary parameters for one or the other
    --  - max_score: maximum score the CA can return

    for i,parms in ipairs(CA_parms) do
        cfg_str = parms.cfg_str or ''

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                engine = "lua",
                id = parms.id,
                name = parms.id,
                max_score = parms.max_score,  -- This works even if parms.max_score is nil
                evaluation = "return (...):" .. parms.eval_name .. "(" .. cfg_str .. ")",
                execution = "(...):" .. parms.exec_name .. "(" .. cfg_str .. ")"
            } }
        }
    end
end

function delete_CAs(side, CA_parms)
    -- Delete the candidate actions defined in 'CA_parms' to the AI of 'side'
    -- CA_parms is an array of tables, one for each CA to be removed
    -- We can simply pass the one used for add_CAs(), although only the
    -- CA_parms.id field is required

    for i,parms in ipairs(CA_parms) do
        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[" .. parms.id .. "]"
        }
    end
end

function wesnoth.wml_actions.micro_ai(cfg)
    -- Set up the [micro_ai] tag functionality for each Micro AI

    -- Check that the required common keys are all present and set correctly
    if (not cfg.ai_type) then H.wml_error("[micro_ai] missing required ai_type= attribute") end
    if (not cfg.side) then H.wml_error("[micro_ai] missing required side= attribute") end
    if (not cfg.action) then H.wml_error("[micro_ai] missing required action= attribute") end

    if (cfg.action ~= 'add') and (cfg.action ~= 'delete') and (cfg.action ~= 'change') then
        H.wml_error("invalid action= in [micro_ai].  Allowed values: add, delete or change")
    end

    --------- Healer Support Micro AI - side-wide AI ------------------------------------
    if (cfg.ai_type == 'healer_support') then
        local cfg_hs = {}

        -- Optional keys
        if cfg.injured_units_only then cfg_hs.injured_units_only = true end
        if cfg.max_threats then cfg_hs.max_threats = cfg.max_threats end

        -- Add, change or delete the CAs
        if (cfg.action == 'add') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/healer_support_CAs.lua".add(cfg.side, cfg_hs)
        end
        if (cfg.action == 'delete') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/healer_support_CAs.lua".delete(cfg.side)
        end
        if (cfg.action == 'change') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/healer_support_CAs.lua".delete(cfg.side)
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/healer_support_CAs.lua".add(cfg.side, cfg_hs)
        end

        -- If aggression = 0: Never let the healers participate in attacks
        -- This is done by deleting the respective CA (after it was added above)
        if (cfg.action == 'add') or (cfg.action == 'change') then
            -- Aggression (keep or delete the healers_can_attack CA)
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

    --------- Bottleneck Defense Micro AI - side-wide AI ------------------------------------
    if (cfg.ai_type == 'bottleneck_defense') then
        local cfg_bd = {}

        if (cfg.action ~= 'delete') then
            -- Required keys
            if (not cfg.x) or (not cfg.y) then
                H.wml_error("Bottleneck Defense Micro AI missing required x= and/or y= attribute")
            end
            if (not cfg.enemy_x) or (not cfg.enemy_y) then
                H.wml_error("Bottleneck Defense Micro AI missing required enemy_x= and/or enemy_y= attribute")
            end
            cfg_bd.x, cfg_bd.y = cfg.x, cfg.y
            cfg_bd.enemy_x, cfg_bd.enemy_y = cfg.enemy_x, cfg.enemy_y

            -- Optional keys
            cfg_bd.healer_x = cfg.healer_x
            cfg_bd.healer_y = cfg.healer_y
            cfg_bd.leadership_x = cfg.leadership_x
            cfg_bd.leadership_y = cfg.leadership_y
            cfg_bd.active_side_leader = cfg.active_side_leader
        end

        -- Set up the CA add/delete parameters
        local CA_parms = {
            {
                id = 'bottleneck_move', eval_name = 'bottleneck_move_eval', exec_name = 'bottleneck_move_exec',
                max_score = 300000, cfg_str = AH.serialize(cfg_bd)
            },
            {
                id = 'bottleneck_attack', eval_name = 'bottleneck_attack_eval', exec_name = 'bottleneck_attack_exec',
                max_score = 290000, cfg_str = ''
            }
        }

        -- Add, delete and change the CAs
        if (cfg.action == 'add') then add_CAs(cfg.side, CA_parms) end
        if (cfg.action == 'delete') then delete_CAs(cfg.side, CA_parms) end
        if (cfg.action == 'change') then
            delete_CAs(cfg.side, CA_parms)
            add_CAs(cfg.side, CA_parms)
        end

        return
    end

   --------- Messenger Escort Micro AI - side-wide AI ------------------------------------
    if (cfg.ai_type == 'messenger_escort') then
        local cfg_me = {}

        -- Required keys
        if (cfg.action ~= 'delete') then
            if (not cfg.id) then
                H.wml_error("Messenger Escort Micro AI missing required id= attribute")
            end
            if (not cfg.goal_x) or (not cfg.goal_y) then
                H.wml_error("Messenger Escort Micro AI missing required goal_x= and/or goal_y= attribute")
            end
            cfg_me.id = cfg.id
            cfg_me.goal_x, cfg_me.goal_y = cfg.goal_x, cfg.goal_y
        end

        -- Optional keys
        if cfg.enemy_death_chance then
            cfg_me.enemy_death_chance = cfg.enemy_death_chance
        end
        if cfg.messenger_death_chance then
            cfg_me.messenger_death_chance = cfg.messenger_death_chance
        end

        -- Add, delete and change the CAs
        if (cfg.action == 'add') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/messenger_escort_CAs.lua".add(cfg.side, cfg_me)
        end
        if (cfg.action == 'delete') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/messenger_escort_CAs.lua".delete(cfg.side)
        end
        if (cfg.action == 'change') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/messenger_escort_CAs.lua".delete(cfg.side)
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/messenger_escort_CAs.lua".add(cfg.side, cfg_me)
        end

        return
    end

        --------- Lurkers Micro AI - side-wide AI ------------------------------------
    if (cfg.ai_type == 'lurkers') then
        local cfg_lurk = {}

        -- Required keys
        if (cfg.action ~= "delete") then
            if (not cfg.type) then
                H.wml_error("Lurkers Micro AI missing required type= attribute")
            end
            if (not cfg.attack_terrain) then
                H.wml_error("Lurkers Micro AI missing required attack_terrain= attribute")
            end
            if (not cfg.wander_terrain) then
                H.wml_error("Lurkers Micro AI missing required wander_terrain= attribute")
            end
            cfg_lurk.type = cfg.type
            cfg_lurk.attack_terrain = cfg.attack_terrain
            cfg_lurk.wander_terrain = cfg.wander_terrain
        end

        -- Add, delete and change the CAs
        if (cfg.action == 'add') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/lurkers_CAs.lua".add(cfg.side, cfg_lurk)
        end
        if (cfg.action == 'delete') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/lurkers_CAs.lua".delete(cfg.side)
        end
        if (cfg.action == 'change') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/lurkers_CAs.lua".delete(cfg.side)
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/lurkers_CAs.lua".add(cfg.side, cfg_lurk)
        end

        return
    end

    --------- Protect Unit Micro AI - side-wide AI ------------------------------------
    if (cfg.ai_type == 'protect_unit') then
        local cfg_pu = {}

        -- Required keys
        if (cfg.action ~= 'delete') then
            if (not cfg.units) then
                H.wml_error("Protect Unit Micro AI missing required units= attribute")
            end
            cfg_pu.units = cfg.units
        end

        -- Optional keys
        if cfg.disable_move_leader_to_keep then
            cfg_pu.disable_move_leader_to_keep = cfg.disable_move_leader_to_keep
        end

        -- Add, delete and change the CAs
        if (cfg.action == 'add') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/protect_unit_CAs.lua".add(cfg.side, cfg_pu)
        end
        if (cfg.action == 'delete') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/protect_unit_CAs.lua".delete(cfg.side)
        end
        if (cfg.action == 'change') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/protect_unit_CAs.lua".delete(cfg.side)
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/protect_unit_CAs.lua".add(cfg.side, cfg_pu)
        end

        return
    end

    --------- Micro AI Guardian - BCA AIs -----------------------------------
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

        -- Add, delete and change the CAs
        if (cfg.action == 'add') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/guardian_CAs.lua".add(cfg.side, cfg_guardian)
        end
        if (cfg.action == 'delete') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/guardian_CAs.lua".delete(cfg.side,guardian_type,cfg.id)
        end
        if (cfg.action == 'change') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/guardian_CAs.lua".delete(cfg.side,guardian_type,cfg.id)
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/guardian_CAs.lua".add(cfg.side, cfg_guardian)
        end

        return
    end

    --------- Micro AI Animals  - side-wide and BCA AIs ------------------------------------
    if (cfg.ai_type == 'animals') then

         -- Set up the cfg array
        local cfg_animals = {}
        local required_attributes = {}

        if (not cfg["animal_type"]) then H.wml_error("[micro_ai] animals missing required animal_type= attribute")
        else
            local animal_type = cfg["animal_type"]

            -- This list does not contain id because we check for that differently
            required_attributes["hunter"] = {"hunt_x", "hunt_y", "home_x", "home_y", "rest_turns"}
            required_attributes["wolves"] = {}

            if (animal_type == "hunter") then
                if (not cfg["id"]) then H.wml_error("[micro_ai] hunter missing required id= attribute")
                else
                    cfg_animals["id"] = cfg["id"]

                    -- Delete the CAs
                    if (cfg.action == 'delete') then
                        wesnoth.require "~add-ons/AI-demos/micro_ais/ais/hunter_CAs.lua".delete(cfg.side, cfg.id)
                    else

                        for j,i in pairs(required_attributes["hunter"]) do
                            if (not cfg[i]) then H.wml_error("[micro_ai] ".. "hunter" .." missing required " .. i .. "= attribute") end
                                cfg_animals[i] = cfg[i]
                            end

                        -- Add the CAs
                        if (cfg.action == 'add') then
                            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/hunter_CAs.lua".add(cfg.side, cfg_animals)
                        end

                        -- Change the CAs (done by deleting, then adding again, so that parameters get reset)
                        if (cfg.action == 'change') then
                            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/hunter_CAs.lua".delete(cfg.side, cfg.id)
                            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/hunter_CAs.lua".add(cfg.side, cfg_animals)
                        end
                    end
                end
            end

            if (animal_type == "wolves") then
                cfg_animals["to_avoid"] = cfg["to_avoid"]

                -- Delete the CAs
                if (cfg.action == 'delete') then
                    wesnoth.require "~add-ons/AI-demos/micro_ais/ais/wolves_CAs.lua".delete(cfg.side)
                else

                    -- Add the CAs
                    if (cfg.action == 'add') then
                        wesnoth.require "~add-ons/AI-demos/micro_ais/ais/wolves_CAs.lua".add(cfg.side, cfg_animals)
                    end

                    -- Change the CAs (done by deleting, then adding again, so that parameters get reset)
                    if (cfg.action == 'change') then
                        wesnoth.require "~add-ons/AI-demos/micro_ais/ais/wolves_CAs.lua".delete(cfg.side)
                        wesnoth.require "~add-ons/AI-demos/micro_ais/ais/wolves_CAs.lua".add(cfg.side, cfg_animals)
                    end
                end
            end

            if (animal_type == "wolves_multipacks") then
                -- Delete the CAs
                if (cfg.action == 'delete') then
                    wesnoth.require "~add-ons/AI-demos/micro_ais/ais/wolves_multipacks_CAs.lua".delete(cfg.side)
                else

                    -- Add the CAs
                    if (cfg.action == 'add') then
                        wesnoth.require "~add-ons/AI-demos/micro_ais/ais/wolves_multipacks_CAs.lua".add(cfg.side, cfg_animals)
                    end

                    -- Change the CAs (done by deleting, then adding again, so that parameters get reset)
                    if (cfg.action == 'change') then
                        wesnoth.require "~add-ons/AI-demos/micro_ais/ais/wolves_multipacks_CAs.lua".delete(cfg.side)
                        wesnoth.require "~add-ons/AI-demos/micro_ais/ais/wolves_multipacks_CAs.lua".add(cfg.side, cfg_animals)
                    end
                end
            end

            if (animal_type == "big_animals") then
                if (not cfg["type"]) then H.wml_error("[micro_ai] big_animals missing required type= attribute")
                    else
                    -- Delete the CAs
                    if (cfg.action == 'delete') then
                        wesnoth.require "~add-ons/AI-demos/micro_ais/ais/big_animals_CAs.lua".delete(cfg.side)
                    else

                        -- Add the CAs
                        if (cfg.action == 'add') then
                            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/big_animals_CAs.lua".add(cfg.side, cfg.type)
                        end

                        -- Change the CAs (done by deleting, then adding again, so that parameters get reset)
                        if (cfg.action == 'change') then
                            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/big_animals_CAs.lua".delete(cfg.side)
                            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/big_animals_CAs.lua".add(cfg.side, cfg.type)
                        end
                    end
                end
            end

            if (animal_type == "swarm") then
                -- Delete the CAs
                if (cfg.action == 'delete') then
                    wesnoth.require "~add-ons/AI-demos/micro_ais/ais/swarm_CAs.lua".delete(cfg.side)
                else

                    -- Add the CAs
                    if (cfg.action == 'add') then
                        wesnoth.require "~add-ons/AI-demos/micro_ais/ais/swarm_CAs.lua".add(cfg.side)
                    end

                    -- Change the CAs (done by deleting, then adding again, so that parameters get reset)
                    if (cfg.action == 'change') then
                        wesnoth.require "~add-ons/AI-demos/micro_ais/ais/swarm_CAs.lua".delete(cfg.side)
                        wesnoth.require "~add-ons/AI-demos/micro_ais/ais/swarm_CAs.lua".add(cfg.side)
                    end
                end
            end

            if (animal_type == "sheep") then
                -- Delete the CAs
                if (cfg.action == 'delete') then
                    wesnoth.require "~add-ons/AI-demos/micro_ais/ais/sheep_CAs.lua".delete(cfg.side)
                else

                    -- Add the CAs
                    if (cfg.action == 'add') then
                        wesnoth.require "~add-ons/AI-demos/micro_ais/ais/sheep_CAs.lua".add(cfg.side)
                    end

                    -- Change the CAs (done by deleting, then adding again, so that parameters get reset)
                    if (cfg.action == 'change') then
                        wesnoth.require "~add-ons/AI-demos/micro_ais/ais/sheep_CAs.lua".delete(cfg.side)
                        wesnoth.require "~add-ons/AI-demos/micro_ais/ais/sheep_CAs.lua".add(cfg.side)
                    end
                end
            end

            if (animal_type == "forest_animals") then
                -- Delete the CAs
                if (cfg.action == 'delete') then
                    wesnoth.require "~add-ons/AI-demos/micro_ais/ais/forest_animals_CAs.lua".delete(cfg.side)
                else

                    -- Add the CAs
                    if (cfg.action == 'add') then
                        wesnoth.require "~add-ons/AI-demos/micro_ais/ais/forest_animals_CAs.lua".add(cfg.side)
                    end

                    -- Change the CAs (done by deleting, then adding again, so that parameters get reset)
                    if (cfg.action == 'change') then
                        wesnoth.require "~add-ons/AI-demos/micro_ais/ais/forest_animals_CAs.lua".delete(cfg.side)
                        wesnoth.require "~add-ons/AI-demos/micro_ais/ais/forest_animals_CAs.lua".add(cfg.side)
                    end
                end
            end

        end
        return
    end

    --------- Patrol Micro AI - BCA AI ------------------------------------
    if (cfg.ai_type == 'bca_patrol') then
        local cfg_p = {}

        -- Required keys - for both add and delete actions
        if (not cfg.id) then
            H.wml_error("Patrol Micro AI missing required id= attribute")
        end
        cfg_p.id = cfg.id

        -- Required keys - add action only
        if (cfg.action ~= 'delete') then
            if (not cfg.waypoint_x) or (not cfg.waypoint_y) then
                H.wml_error("Patrol Micro AI missing required waypoint_x/waypoint_y= attribute")
            end
            cfg_p.waypoint_x = cfg.waypoint_x
            cfg_p.waypoint_y = cfg.waypoint_y
        end

        -- Optional keys
        if cfg.attack_all then
            cfg_p.attack_all = cfg.attack_all
        end
        if cfg.attack_targets then
            cfg_p.attack_targets = cfg.attack_targets
        end

        -- Add, delete and change the CAs
        if (cfg.action == 'add') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/patrol_CAs.lua".add(cfg.side, cfg_p)
        end
        if (cfg.action == 'delete') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/patrol_CAs.lua".delete(cfg.side, cfg_p)
        end
        if (cfg.action == 'change') then
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/patrol_CAs.lua".delete(cfg.side)
            wesnoth.require "~add-ons/AI-demos/micro_ais/ais/patrol_CAs.lua".add(cfg.side, cfg_p)
        end

        return
    end

    ----------------------------------------------------------------
    -- If we got here, none of the valid ai_types was specified
    H.wml_error("invalid ai_type= in [micro_ai]")
end

