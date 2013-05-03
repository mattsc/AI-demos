local H = wesnoth.require "lua/helper.lua"
local W = H.set_wml_action_metatable {}
local AH = wesnoth.require("~add-ons/AI-demos/lua/ai_helper.lua")

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
    --  - cfg_table: a configuration table (Lua WML table format), to be passed to eval and exec functions
    --      Note: we pass the same string to both functions, even if it contains unnecessary parameters for one or the other
    --  - max_score: maximum score the CA can return

    for i,parms in ipairs(CA_parms) do
        cfg_table = parms.cfg_table or {}

        -- Make sure the id/name of each CA are unique.
        -- We do this by seeing if a CA by that name exists already.
        -- If yes, we use the passed id in parms.id
        -- If not, we add a number to the end of parms.id until we find an id that does not exist yet
        local ca_id, id_found = parms.id, true
        local n = 1
        while id_found do -- This is really just a precaution
            id_found = false

            for ai_tag in H.child_range(wesnoth.sides[side].__cfg, 'ai') do
                for stage in H.child_range(ai_tag, 'stage') do
                    for ca in H.child_range(stage, 'candidate_action') do
                        if (ca.name == ca_id) then id_found = true end
                        --print('---> found CA:', ca.name, id_found)
                    end
                end
            end

            if (id_found) then ca_id = parms.id .. n end
            n = n+1
        end

        -- If parameter pass_ca_id is set, pass the CA id to the eval/exec functions
        if parms.pass_ca_id then cfg_table.ca_id = ca_id end

        local CA = {
            engine = "lua",
            id = ca_id,
            name = ca_id,
            max_score = parms.max_score,  -- This works even if parms.max_score is nil
            evaluation = "return (...):" .. parms.eval_name .. "(" .. AH.serialize(cfg_table) .. ")",
            execution = "(...):" .. parms.exec_name .. "(" .. AH.serialize(cfg_table) .. ")"
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
    --  {   name = "ai_default_rca::aspect_attacks",
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

function wesnoth.wml_actions.AID_micro_ai(cfg)
    -- Set up the [micro_ai] tag functionality for each Micro AI

    -- Check that the required common keys are all present and set correctly
    if (not cfg.ai_type) then H.wml_error("[micro_ai] missing required ai_type= key") end
    if (not cfg.side) then H.wml_error("[micro_ai] missing required side= key") end
    if (not cfg.action) then H.wml_error("[micro_ai] missing required action= key") end

    if (cfg.action ~= 'add') and (cfg.action ~= 'delete') and (cfg.action ~= 'change') then
        H.wml_error("[micro_ai] invalid value for action=.  Allowed values: add, delete or change")
    end

    ----- Add testing code for [AID_micro_ai] tag here

    ----------------------------------------------------------------
    -- If we got here, none of the valid ai_types was specified
    H.wml_error("invalid ai_type= in [micro_ai]")
end
