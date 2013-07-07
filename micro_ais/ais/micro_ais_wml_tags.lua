local H = wesnoth.require "lua/helper.lua"
local W = H.set_wml_action_metatable {}
local AH = wesnoth.require("~add-ons/AI-demos/lua/ai_helper.lua")

local function add_CAs(side, CA_parms, CA_cfg)
    -- Add the candidate actions defined in 'CA_parms' to the AI of 'side'
    -- CA_parms is an array of tables, one for each CA to be added (CA setup parameters)
    -- CA_cfg is a table with the parameters passed to the eval/exec functions
    --
    -- Required keys for CA_parms:
    --  - ca_id: is used for CA id/name and the eval/exec function names
    --  - score: the evaluation score
    -- Optional keys:
    --  - sticky: (boolean) whether this is a sticky BCA or not

    for i,parms in ipairs(CA_parms) do
        -- Make sure the id/name of each CA are unique.
        -- We do this by seeing if a CA by that name exists already.
        -- If not, we use the passed id in parms.ca_id
        -- If yes, we add a number to the end of parms.ca_id until we find an id that does not exist yet
        local ca_id, id_found = parms.ca_id, true

        -- If it's a sticky behavior CA, we also add the unit id to ca_id
        if parms.sticky then ca_id = ca_id .. "_" .. CA_cfg.id end

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

            if (id_found) then ca_id = parms.ca_id .. n end
            n = n+1
        end

        -- Always pass the ca_id and ca_score to the eval/exec functions
        CA_cfg.ca_id = ca_id
        CA_cfg.ca_score = parms.score

        local CA = {
            engine = "lua",
            id = ca_id,
            name = ca_id,
            max_score = parms.score,
            evaluation = "return (...):" .. (parms.eval_id or parms.ca_id) .. "_eval(" .. AH.serialize(CA_cfg) .. ")",
            execution = "(...):" .. (parms.eval_id or parms.ca_id) .. "_exec(" .. AH.serialize(CA_cfg) .. ")"
        }

        if parms.sticky then
            local unit = wesnoth.get_units { id = CA_cfg.id }[1]
            CA.sticky = "yes"
            CA.unit_x = unit.x
            CA.unit_y = unit.y
        end

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", CA }
        }
    end
end

local function delete_CAs(side, CA_parms)
    -- Delete the candidate actions defined in 'CA_parms' from the AI of 'side'
    -- CA_parms is an array of tables, one for each CA to be removed
    -- We can simply pass the one used for add_CAs(), although only the
    -- CA_parms.ca_id field is needed

    for i,parms in ipairs(CA_parms) do
        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[" .. parms.ca_id .. "]"
        }
    end
end

local function add_aspects(side, aspect_parms)
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

local function delete_aspects(side, aspect_parms)
    -- Delete the aspects defined in 'aspect_parms' from the AI of 'side'
    -- aspect_parms is an array of tables, one for each CA to be removed
    -- We can simply pass the one used for add_aspects(), although only the
    -- aspect_parms.aspect_id field is needed

    for i,parms in ipairs(aspect_parms) do
        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "aspect[attacks].facet[" .. parms.aspect_id .. "]"
        }
    end
end

function wesnoth.wml_actions.AID_micro_ai(cfg)
    -- Set up the [micro_ai] tag functionality for each Micro AI

    -- Check that the required common keys are all present and set correctly
    if (not cfg.ai_type) then H.wml_error("[micro_ai] is missing required ai_type= key") end
    if (not cfg.side) then H.wml_error("[micro_ai] is missing required side= key") end
    if (not cfg.action) then H.wml_error("[micro_ai] is missing required action= key") end

    if (cfg.action ~= 'add') and (cfg.action ~= 'delete') and (cfg.action ~= 'change') then
        H.wml_error("[micro_ai] unknown value for action=. Allowed values: add, delete or change")
    end

    -- Set up the configuration tables for the different Micro AIs
    local required_keys, optional_keys, CA_parms = {}, {}, {}
    cfg = cfg.__parsed

    ----- Add testing code for [AID_micro_ai] tag here
    if (cfg.ai_type == 'ai_id') then
        required_keys = {}
        optional_keys = {}
        local score = cfg.ca_score or 300000
        CA_parms = {
            { ca_id = 'mai_ai_move', score = score },
            { ca_id = 'mai_ai_attack', score = score - 1 }
        }

    -- If we got here, none of the valid ai_types was specified
    else
        H.wml_error("unknown value for ai_type= in [micro_ai]")
    end

    --------- Now go on to setting up the CAs ---------------------------------
    -- If cfg.ca_id is set, it gets added to the ca_id= key of all CAs
    -- This allows for selective removal of CAs
    if cfg.ca_id then
        for i,parms in ipairs(CA_parms) do
            -- Need to save eval_id first though
            parms.eval_id = parms.ca_id
            parms.ca_id = parms.ca_id .. '_' .. cfg.ca_id
        end
    end

    -- If action=delete, we do that and are done
    if (cfg.action == 'delete') then
        delete_CAs(cfg.side, CA_parms)
        return
    end

    -- Otherwise, set up the cfg table to be passed to the CA eval/exec functions
    local CA_cfg = {}

    -- Required keys
    for k, v in pairs(required_keys) do
        local child = H.get_child(cfg, v)
        if (not cfg[v]) and (not child) then
            H.wml_error("[micro_ai] tag (" .. cfg.ai_type .. ") is missing required parameter: " .. v)
        end
        CA_cfg[v] = cfg[v]
        if child then CA_cfg[v] = child end
    end

    -- Optional keys
    for k, v in pairs(optional_keys) do
        CA_cfg[v] = cfg[v]
        local child = H.get_child(cfg, v)
        if child then CA_cfg[v] = child end
    end

    -- Finally, set up the candidate actions themselves
    if (cfg.action == 'add') then add_CAs(cfg.side, CA_parms, CA_cfg) end
    if (cfg.action == 'change') then
        delete_CAs(cfg.side, CA_parms)
        add_CAs(cfg.side, CA_parms, CA_cfg)
    end
end
