local H = wesnoth.require "lua/helper.lua"
local W = H.set_wml_action_metatable {}
local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

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

        local CA = {
            engine = "lua",
            id = parms.id,
            name = parms.id,
            max_score = parms.max_score,  -- This works even if parms.max_score is nil
            evaluation = "return (...):" .. parms.eval_name .. "(" .. cfg_str .. ")",
            execution = "(...):" .. parms.exec_name .. "(" .. cfg_str .. ")"
        }

        if parms.sticky then
            CA.sticky = "yes"
            CA.unit_x = parms.unit_x
            CA.unit_y = parms.unit_y
        end

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", CA }
        }
    end
end

function delete_CAs(side, CA_parms)
    -- Delete the candidate actions defined in 'CA_parms' from the AI of 'side'
    -- CA_parms is an array of tables, one for each CA to be removed
    -- We can simply pass the one used for add_CAs(), although only the
    -- CA_parms.id field is needed

    for i,parms in ipairs(CA_parms) do
        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[" .. parms.id .. "]"
        }
    end
end

function add_aspects(side, aspect_parms)
    -- Add the aspects defined in 'aspect_parms' to the AI of 'side'
    -- aspect_parms is an array of tables, one for each aspect to be added
    --
    -- Required keys for aspect_parms:
    --  - aspect: the aspect name (e.g. 'attacks' or 'aggression')
    --  - facet: A table describing the facet to be added
    --
    -- Examples of facets:
    -- 1. Simple aspect, e.g. aggression
    -- { value = 0.99 }
    --
    -- 2. Composite aspect, e.g. attacks
    --  {   name = "testing_ai_default::aspect_attacks",
    --      id = "dont_attack",
    --      invalidate_on_gamestate_change = "yes",
    --      { "filter_own", {
    --          type = "Dark Sorcerer"
    --      } }
    --  }

    for i,parms in ipairs(aspect_parms) do
        W.modify_ai {
            side = side,
            action = "add",
            path = "aspect[" .. parms.aspect .. "].facet",
            { "facet", parms.facet }
        }
    end
end

function delete_aspects(side, aspect_parms)
    -- Delete the aspects defined in 'aspect_parms' from the AI of 'side'
    -- aspect_parms is an array of tables, one for each CA to be removed
    -- We can simply pass the one used for add_aspects(), although only the
    -- aspect_parms.id field is needed

    for i,parms in ipairs(aspect_parms) do
        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "aspect[attacks].facet[" .. parms.id .. "]"
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

        -- The healers_can_attack CA is only added to the table if aggression ~= 0
        -- But: make sure we always try removal
        if (cfg.action == 'delete') or (cfg.aggression ~= 0) then
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
        if (cfg.action ~= 'delete') then
            -- Required keys
            if (not cfg.id) then
                H.wml_error("Messenger Escort Micro AI missing required id= key")
            end
            if (not cfg.goal_x) or (not cfg.goal_y) then
                H.wml_error("Messenger Escort Micro AI missing required goal_x= and/or goal_y= key")
            end
            cfg_me.id = cfg.id
            cfg_me.goal_x, cfg_me.goal_y = cfg.goal_x, cfg.goal_y
            cfg_me.waypoint_x, cfg_me.waypoint_y = cfg.waypoint_x, cfg.waypoint_y

            -- Optional keys
            cfg_me.enemy_death_chance = cfg.enemy_death_chance
            cfg_me.messenger_death_chance = cfg.messenger_death_chance
        end

        local CA_parms = {
            {
                id = 'attack', eval_name = 'attack_eval', exec_name = 'attack_exec',
                max_score = 300000, cfg_str = AH.serialize(cfg_me)
            },
            {
                id = 'messenger_move', eval_name = 'messenger_move_eval', exec_name = 'messenger_move_exec',
                max_score = 290000, cfg_str = AH.serialize(cfg_me)
            },
            {
                id = 'other_move', eval_name = 'other_move_eval', exec_name = 'other_move_exec',
                max_score = 280000, cfg_str = AH.serialize(cfg_me)
            },
        }

        -- Add, delete or change the CAs
        CA_action(cfg.action, cfg.side, CA_parms)

        return
    end

        --------- Lurkers Micro AI - side-wide AI ------------------------------------
    if (cfg.ai_type == 'lurkers') then
        local cfg_lurk = {}
        if (cfg.action ~= "delete") then
            -- Required keys
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

        local CA_parms = {
            {
                id = 'lurker_moves_lua', eval_name = 'lurker_attack_eval', exec_name = 'lurker_attack_exec',
                max_score = 100010, cfg_str = AH.serialize(cfg_lurk)
            },
        }

        -- Add, delete or change the CAs
        CA_action(cfg.action, cfg.side, CA_parms)

        return
    end

    --------- Protect Unit Micro AI - side-wide AI ------------------------------------
    if (cfg.ai_type == 'protect_unit') then
        local cfg_pu = {}
        if (cfg.action ~= 'delete') then
            -- Required keys
            if (not cfg.units) then
                H.wml_error("Protect Unit Micro AI missing required units= key")
            end
            cfg_pu.units = cfg.units
        end

        local unit_ids = ''
        local units = AH.split(cfg.units)
        for i = 1, #units, 3 do
            unit_ids = unit_ids .. units[i] .. ','
        end

        unit_ids = string.sub(unit_ids, 1, -2)
        cfg_pu.unit_ids = unit_ids

        local aspect_parms = {
            {
                aspect = "attacks",
                facet = {
                    name = "testing_ai_default::aspect_attacks",
                    id = "dont_attack",
                    invalidate_on_gamestate_change = "yes",
                    { "filter_own", {
                        { "not", {
                            id = unit_ids
                        } }
                    } }
                }
            }
        }

        local CA_parms = {
            {
                id = 'finish', eval_name = 'finish_eval', exec_name = 'finish_exec',
                max_score = 300000, cfg_str = AH.serialize(cfg_pu)
            },
            {
                id = 'attack', eval_name = 'attack_eval', exec_name = 'attack_exec',
                max_score = 95000, cfg_str = AH.serialize(cfg_pu)
            },
            {
                id = 'move', eval_name = 'move_eval', exec_name = 'move_exec',
                max_score = 94000, cfg_str = AH.serialize(cfg_pu)
            }
        }

        add_aspects(cfg.side, aspect_parms)
        -- Add, delete or change the CAs
        CA_action(cfg.action, cfg.side, CA_parms)

        -- Optional key
        if cfg.disable_move_leader_to_keep then
            W.modify_ai {
                side = side,
                action = "try_delete",
                path = "stage[main_loop].candidate_action[move_leader_to_keep]"
            }
        end

        if (cfg.action == "delete") then
            delete_aspects(cfg.side, aspect_parms)
            -- We also need to add the move_leader_to_keep CA back in
            -- This works even if it was not removed, it simply overwrites the existing CA
            W.modify_ai {
                side = side,
                action = "add",
                path = "stage[main_loop].candidate_action",
                { "candidate_action", {
                    id="move_leader_to_keep",
                    engine="cpp",
                    name="testing_ai_default::move_leader_to_keep_phase",
                    max_score=160000,
                    score=160000
                } }
            }
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

        local max_scores = {}
        max_scores["stationed_guardian"] = 100010
        max_scores["coward"] = 300000

        local unit = wesnoth.get_units { id=cfg.id }[1]

        local CA_parms = {
            {
                id = guardian_type .. '_' .. cfg.id, eval_name = guardian_type .. '_eval', exec_name = guardian_type .. '_exec',
                max_score = max_scores[guardian_type], sticky = true, unit_x = unit.x, unit_y = unit.y, cfg_str = AH.serialize(cfg_guardian)
            },
        }

        -- Add, delete or change the CAs
        CA_action(cfg.action, cfg.side, CA_parms)

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

        local CA_parms = {}
        if (cfg_animals.animal_type == 'big_animals') then
            CA_parms = {
                {
                    id = "big_animal", eval_name = 'big_eval', exec_name = 'big_exec',
                    max_score = 300000, cfg_str = AH.serialize(cfg_animals)
                }
            }
        end

        if (cfg_animals.animal_type == 'wolves') then
            CA_parms = {
                {
                    id = "wolves", eval_name = 'wolves_eval', exec_name = 'wolves_exec',
                    max_score = 95000, cfg_str = AH.serialize(cfg_animals)
                },
                {
                    id = "wolves_wander", eval_name = 'wolves_wander_eval', exec_name = 'wolves_wander_exec',
                    max_score = 90000, cfg_str = AH.serialize(cfg_animals)
                }
            }

           local wolves_aspects = {
                {
                    aspect = "attacks",
                    facet = {
                        name = "testing_ai_default::aspect_attacks",
                        id = "dont_attack",
                        invalidate_on_gamestate_change = "yes",
                        { "filter_enemy", {
                            { "not", {
                                type=cfg_animals.to_avoid
                            } }
                        } }
                    }
                }
            }
            if (cfg.action == "delete") then
                delete_aspects(cfg_animals.side, wolves_aspects)
            else
                add_aspects(cfg_animals.side, wolves_aspects)
            end
        end

        if (cfg_animals.animal_type == 'sheep') then
            CA_parms = {
                {
                    id = "close_enemy", eval_name = 'close_enemy_eval', exec_name = 'close_enemy_exec',
                    max_score = 300000
                },
                {
                    id = "sheep_runs_enemy", eval_name = 'sheep_runs_enemy_eval', exec_name = 'sheep_runs_enemy_exec',
                    max_score = 295000
                },
                {
                    id = "sheep_runs_dog", eval_name = 'sheep_runs_dog_eval', exec_name = 'sheep_runs_dog_exec',
                    max_score = 290000
                },
                {
                    id = "herd_sheep", eval_name = 'herd_sheep_eval', exec_name = 'herd_sheep_exec',
                    max_score = 280000
                },
                {
                    id = "sheep_move", eval_name = 'sheep_move_eval', exec_name = 'sheep_move_exec',
                    max_score = 270000
                },
                {
                    id = "dog_move", eval_name = 'dog_move_eval', exec_name = 'dog_move_exec',
                    max_score = 260000
                }
            }
        end

        if (cfg_animals.animal_type == 'forest_animals') then
            CA_parms = {
                {
                    id = "new_rabbit", eval_name = 'new_rabbit_eval', exec_name = 'new_rabbit_exec',
                    max_score = 310000
                },
                {
                    id = "tusker_attack", eval_name = 'tusker_attack_eval', exec_name = 'tusker_attack_exec',
                    max_score = 300000
                },
                {
                    id = "move", eval_name = 'move_eval', exec_name = 'move_exec',
                    max_score = 290000
                },
                {
                    id = "tusklet", eval_name = 'tusklet_eval', exec_name = 'tusklet_exec',
                    max_score = 280000
                }
            }
        end

        if (cfg_animals.animal_type == 'swarm') then
            CA_parms = {
                {
                    id = "scatter_swarm", eval_name = 'scatter_swarm_eval', exec_name = 'scatter_swarm_exec',
                    max_score = 300000
                },
                {
                    id = "move_swarm", eval_name = 'move_swarm_eval', exec_name = 'move_swarm_exec',
                    max_score = 290000
                }
            }
        end

        if (cfg_animals.animal_type == 'wolves_multipacks') then
            CA_parms = {
                {
                    id = "wolves_multipacks_attack", eval_name = 'wolves_multipacks_attack_eval', exec_name = 'wolves_multipacks_attack_exec',
                    max_score = 300000
                },
                {
                    id = "wolves_multipacks_attack", eval_name = 'wolves_multipacks_wander_eval', exec_name = 'wolves_multipacks_wander_exec',
                    max_score = 290000
                }
            }
        end

        if (cfg_animals.animal_type == 'hunter_unit') then
            local unit = wesnoth.get_units { id=cfg_animals.id }[1]
            CA_parms = {
                {
                    id = "hunter_unit_" .. cfg_animals.id, eval_name = 'hunt_and_rest_eval', exec_name = 'hunt_and_rest_exec',
                    max_score = 300000, sticky = true, unit_x = unit.x, unit_y = unit.y, cfg_str = AH.serialize(cfg_animals)
                }
            }
        end

        -- Add, delete or change the CAs
        CA_action(cfg.action, cfg.side, CA_parms)

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

        if (cfg.action ~= 'delete') then
            -- Required keys - add action only
            if (not cfg.waypoint_x) or (not cfg.waypoint_y) then
                H.wml_error("Patrol Micro AI missing required waypoint_x/waypoint_y= key")
            end
            cfg_p.waypoint_x = cfg.waypoint_x
            cfg_p.waypoint_y = cfg.waypoint_y

            -- Optional keys
            cfg_p.attack_all = cfg.attack_all
            cfg_p.attack_targets = cfg.attack_targets
        end

        local unit = wesnoth.get_units { id=cfg_p.id }[1]
        local CA_parms = {
            {
                id = "patrol_unit_" .. cfg_p.id, eval_name = 'patrol_eval', exec_name = 'patrol_exec',
                max_score = 300000, sticky = true, unit_x = unit.x, unit_y = unit.y, cfg_str = AH.serialize(cfg_p)
            },
        }

        -- Add, delete or change the CAs
        CA_action(cfg.action, cfg.side, CA_parms)

        return
    end

    --------- Recruiting Micro AI - side-wide AI ------------------------------------
    if (cfg.ai_type == 'recruiting') then
        local cfg_recruiting = {}

        if (not cfg.recruit_type) then
            H.wml_error("[micro_ai] missing required recruit_type= key")
        end
        local recruit_type = cfg.recruit_type

        if (not cfg.low_gold_recruit) and (cfg.recruit_type == 'random') and (cfg.action ~= 'delete') then
            H.wml_error("[micro_ai] missing required low_gold_recruit= key")
        end
        cfg_recruiting.low_gold_recruit = cfg.low_gold_recruit

        -- Add, delete and change the CAs
        if (cfg.action == 'add') then
            wesnoth.require("~add-ons/AI-demos/micro_ais/ais/recruit_" .. recruit_type .. "_CAs.lua").add(cfg.side, cfg_recruiting)
        end
        if (cfg.action == 'delete') then
            wesnoth.require("~add-ons/AI-demos/micro_ais/ais/recruit_" .. recruit_type .. "_CAs.lua").delete(cfg.side, cfg_recruiting)
        end
        if (cfg.action == 'change') then
            wesnoth.require("~add-ons/AI-demos/micro_ais/ais/recruit_" .. recruit_type .. "_CAs.lua").delete(cfg.side)
            wesnoth.require("~add-ons/AI-demos/micro_ais/ais/recruit_" .. recruit_type .. "_CAs.lua").add(cfg.side, cfg_recruiting)
        end

        return
    end

    ----------------------------------------------------------------
    -- If we got here, none of the valid ai_types was specified
    H.wml_error("invalid ai_type= in [micro_ai]")
end
