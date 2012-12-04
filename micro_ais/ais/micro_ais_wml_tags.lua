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

function CA_action(action, side, CA_parms)
    if (action == 'add') then add_CAs(side, CA_parms) end
    if (action == 'delete') then delete_CAs(side, CA_parms) end
    if (action == 'change') then
        delete_CAs(side, CA_parms)
        add_CAs(side, CA_parms)
    end
end

function wesnoth.wml_actions.micro_ai(cfg)
    -- Set up the [micro_ai] tag functionality for each Micro AI

    -- Check that the required common keys are all present and set correctly
    if (not cfg.ai_type) then H.wml_error("[micro_ai] missing required ai_type= key") end
    if (not cfg.side) then H.wml_error("[micro_ai] missing required side= key") end
    if (not cfg.action) then H.wml_error("[micro_ai] missing required action= key") end

    if (cfg.action ~= 'add') and (cfg.action ~= 'delete') and (cfg.action ~= 'change') then
        H.wml_error("[micro_ai] invalid value for action=.  Allowed values: add, delete or change")
    end

    --------- Healer Support Micro AI - side-wide AI ------------------------------------
    if (cfg.ai_type == 'healer_support') then
        local cfg_hs = {}
        if (cfg.action ~= 'delete') then
            -- Optional keys
            cfg_hs.aggression = cfg.aggression or 1.0
            cfg_hs.injured_units_only = cfg.injured_units_only
            cfg_hs.max_threats = cfg.max_threats
        end

        -- Set up the CA add/delete parameters
        local CA_parms = {
            {
                id = 'initialize_healer_support', eval_name = 'initialize_healer_support_eval', exec_name = 'initialize_healer_support_exec',
                max_score = 999990, cfg_str = ''
            },
            {
                id = 'healer_support', eval_name = 'healer_support_eval', exec_name = 'healer_support_exec',
                max_score = 105000, cfg_str = AH.serialize(cfg_hs)
            },
        }

        -- The healers_can_attack CA is only added if aggression ~= 0
        if (cfg.aggression ~= 0) then
            table.insert(CA_parms,
                {
                    id = 'healers_can_attack', eval_name = 'healers_can_attack_eval', exec_name = 'healers_can_attack_exec',
                    max_score = 99990, cfg_str = ''
                }
            )
        end

        -- Add, delete or change the CAs
        CA_action(cfg.action, cfg.side, CA_parms)

        return
    end

    --------- Bottleneck Defense Micro AI - side-wide AI ------------------------------------
    if (cfg.ai_type == 'bottleneck_defense') then
        local cfg_bd = {}
        if (cfg.action ~= 'delete') then
            -- Required keys
            if (not cfg.x) or (not cfg.y) then
                H.wml_error("Bottleneck Defense Micro AI missing required x= and/or y= key")
            end
            if (not cfg.enemy_x) or (not cfg.enemy_y) then
                H.wml_error("Bottleneck Defense Micro AI missing required enemy_x= and/or enemy_y= key")
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

        -- Add, delete or change the CAs
        CA_action(cfg.action, cfg.side, CA_parms)

        return
    end

   --------- Messenger Escort Micro AI - side-wide AI ------------------------------------
    if (cfg.ai_type == 'messenger_escort') then
        local cfg_me = {}

        -- Required keys
        if (cfg.action ~= 'delete') then
            if (not cfg.id) then
                H.wml_error("Messenger Escort Micro AI missing required id= key")
            end
            if (not cfg.goal_x) or (not cfg.goal_y) then
                H.wml_error("Messenger Escort Micro AI missing required goal_x= and/or goal_y= key")
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
                H.wml_error("Lurkers Micro AI missing required type= key")
            end
            if (not cfg.attack_terrain) then
                H.wml_error("Lurkers Micro AI missing required attack_terrain= key")
            end
            if (not cfg.wander_terrain) then
                H.wml_error("Lurkers Micro AI missing required wander_terrain= key")
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
                H.wml_error("Protect Unit Micro AI missing required units= key")
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
    if (cfg.ai_type == 'guardian_unit') then
        -- We handle these types of guardians here: stationed, return, coward
        if (not cfg.guardian_type) then H.wml_error("[micro_ai] missing required guardian_type= key") end
        local guardian_type = cfg.guardian_type

        -- Since this is a BCA, the unit id needs to be present even for removal
        if (not cfg.id) then H.wml_error("[micro_ai] missing required id= key") end

         -- Set up the cfg array
        local cfg_guardian = { guardian_type = guardian_type }
        local required_keys, optional_keys = {}, {}

        required_keys["stationed_guardian"] = { "id", "radius", "station_x", "station_y", "guard_x", "guard_y" }
        optional_keys["stationed_guardian"] = {}

        required_keys["coward"] = { "id", "radius" }
        optional_keys["coward"] = { "seek_x", "seek_y","avoid_x","avoid_y" }

        required_keys["return_guardian"] = { "id", "to_x", "to_y" }
        optional_keys["return_guardian"] = {}

        if (cfg.action~='delete') then
            --Check that we know about this type of guardian
            if (not required_keys[guardian_type]) then
                H.wml_error("[micro_ai] unknown value for guardian_type= key: '" .. guardian_type .."'")
            end

            --Add in the required keys
           for k,v in pairs(required_keys[guardian_type]) do
                if (not cfg[v]) then H.wml_error("[micro_ai] ".. guardian_type .." missing required " .. v .. "= key") end
                cfg_guardian[v] = cfg[v]
            end

            --Add in the optional keys
            for k,v in pairs(optional_keys[guardian_type]) do
              cfg_guardian[v] = cfg[v] or "''"
            end
        end

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
        -- We handle these types of animal AIs here:
        --    BCAs: hunter_unit
        --    side-wide AIs: wolves, wolves_multipack, big_animals, forest_animals, swarm, sheep
        if (not cfg.animal_type) then H.wml_error("[micro_ai] missing required animal_type= key") end
        local animal_type = cfg.animal_type

        -- For the BCAs, the unit id needs to be present even for removal
        if (animal_type == "hunter_unit") then
            if (not cfg.id) then H.wml_error("[micro_ai] missing required id= key") end
        end

         -- Set up the cfg array
        local cfg_animals = { animal_type = animal_type }
        local required_keys, optional_keys = {}, {}

        -- This list does not contain id because we check for that differently
        required_keys["hunter_unit"] = { "id", "hunt_x", "hunt_y", "home_x", "home_y", "rest_turns" }
        optional_keys["hunter_unit"] = {}

        required_keys["wolves"] = {}
        optional_keys["wolves"] = { "to_avoid" }

        required_keys["wolves_multipacks"] = {}
        optional_keys["wolves_multipacks"] = {}

        required_keys["big_animals"] = { "type" }
        optional_keys["big_animals"] = {}

        required_keys["forest_animals"] = {}
        optional_keys["forest_animals"] = {}

        required_keys["swarm"] = {}
        optional_keys["swarm"] = {}

        required_keys["sheep"] = {}
        optional_keys["sheep"] = {}

        if (cfg.action~='delete') then
            --Check that we know about this type of animal AI
            if (not required_keys[animal_type]) then
                H.wml_error("[micro_ai] unknown value for animal_type= key: '" .. animal_type .."'")
            end

            --Add in the required keys
           for k,v in pairs(required_keys[animal_type]) do
                if (not cfg[v]) then H.wml_error("[micro_ai] ".. animal_type .." missing required " .. v .. "= key") end
                cfg_animals[v] = cfg[v]
            end

            --Add in the optional keys
            for k,v in pairs(optional_keys[animal_type]) do
              cfg_animals[v] = cfg[v] or "''"
            end
        end

        -- Add, delete and change the CAs
        if (cfg.action == 'add') then
            wesnoth.require("~add-ons/AI-demos/micro_ais/ais/" .. animal_type .. "_CAs.lua").add(cfg.side, cfg_animals)
        end
        if (cfg.action == 'delete') then
            wesnoth.require("~add-ons/AI-demos/micro_ais/ais/" .. animal_type .. "_CAs.lua").delete(cfg.side, cfg.id)
        end
        if (cfg.action == 'change') then
            wesnoth.require("~add-ons/AI-demos/micro_ais/ais/" .. animal_type .. "_CAs.lua").delete(cfg.side, cfg.id)
            wesnoth.require("~add-ons/AI-demos/micro_ais/ais/" .. animal_type .. "_CAs.lua").add(cfg.side, cfg_animals)
        end

        return
    end

    --------- Patrol Micro AI - BCA AI ------------------------------------
    if (cfg.ai_type == 'patrol_unit') then
        local cfg_p = {}

        -- Required keys - for both add and delete actions
        if (not cfg.id) then
            H.wml_error("Patrol Micro AI missing required id= key")
        end
        cfg_p.id = cfg.id

        -- Required keys - add action only
        if (cfg.action ~= 'delete') then
            if (not cfg.waypoint_x) or (not cfg.waypoint_y) then
                H.wml_error("Patrol Micro AI missing required waypoint_x/waypoint_y= key")
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
