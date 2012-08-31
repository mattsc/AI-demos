local H = wesnoth.require "lua/helper.lua"
local W = H.set_wml_action_metatable {}
local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
local LS = wesnoth.require "lua/location_set.lua"
local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

function wesnoth.wml_actions.micro_ai(cfg)
    -- Set up tag [micro_ai]
    -- Configuration tag for the micro AIs

    cfg = cfg or {}

    if cfg.micro_ai then
        W.message { speaker = 'narrator', message = "Configuring Micro AI '" .. micro_ai .. "'" }
    else
        W.message { speaker = 'narrator', message = "[micro_ai] requires an 'micro_ai=' key" }
    end
end
