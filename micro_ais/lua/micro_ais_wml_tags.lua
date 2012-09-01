local H = wesnoth.require "lua/helper.lua"
local W = H.set_wml_action_metatable {}
local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
local LS = wesnoth.require "lua/location_set.lua"
local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

function wesnoth.wml_actions.micro_ai(cfg)
    -- Set up the [micro_ai] tag
    -- Configuration tag for the micro AIs

    cfg = cfg or {}

    -- Check that the require attributes are set
    if (not cfg.ai_type) then H.wml_error("[micro_ai] missing required ai_type= attribute") end
    --print("[micro_ai]: Configuring Micro AI '" .. cfg.ai_type .. "'")
    if (not cfg.side) then H.wml_error("[micro_ai] missing required side= attribute") end

    -- Now deal with each specific micro AI
    if (cfg.ai_type == 'healer_support') then
        -- If never_attack = true: Never let the healers participate in attacks
        -- This is done by not deleting the attacks aspect
        if cfg.never_attack then
            --print("[micro_ai] healer_support: Deleting the healers_can_attack CA of Side " .. cfg.side)

	    W.modify_ai {
	        side = cfg.side,
	        action = "delete",
	        path = "stage[main_loop].candidate_action[healers_can_attack]"
	    }
        end
        return
    end

    -- If we got here, none of the valid ai_types was specified
    H.wml_error("invalid ai_type= in [micro_ai]")
end
