-- This is the manual 'AI handler'
-- Want this in a separate file, so that it can be changed on the fly
-- It loads the AI from another file which can then be executed by right-click menu

-- Start test scenario from command line with
-- /Applications/Wesnoth-1.11.app/Contents/MacOS/Wesnoth -d -l AI-demos-test.gz

-- Include all these, just in case (mostly not needed)
local H = wesnoth.require "lua/helper.lua"
local W = H.set_wml_action_metatable {}
local AH = wesnoth.dofile "~/add-ons/AI-demos/lua/ai_helper.lua"
local MAIH = wesnoth.dofile "ai/micro_ais/micro_ai_helper.lua"
local MAIUV = wesnoth.dofile "ai/micro_ais/micro_ai_unit_variables.lua"
local MAISD = wesnoth.dofile "ai/micro_ais/micro_ai_self_data.lua"
local BC = wesnoth.dofile "~/add-ons/AI-demos/lua/battle_calcs.lua"
local FGU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_gamestate_utils.lua"
local FGUI = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_gamestate_utils_incremental.lua"
local FAU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack_utils.lua"
local LS = wesnoth.dofile "lua/location_set.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"
H.set_wml_var_metatable(_G)

-- Clean up the screen
wesnoth.clear_messages()
AH.clear_labels()
print('\n---- Side ', wesnoth.current.side, '------------')

-- Check for debug mode and quit if it is not activated
if (not wesnoth.game_config.debug) then
    wesnoth.message("***** This option requires debug mode. Activate by typing ':debug' *****")
    return
end

-- Add shortcut to debug ai table
local ai = wesnoth.debug_ai(wesnoth.current.side).ai
--DBG.dbms(ai)

-- Load the custom AI into array 'my_ai'
fn = "~add-ons/AI-demos/lua/grunt_rush_Freelands_S1_engine.lua"
fn = "ai/micro_ais/cas/ca_fast_move.lua"
local self = { data = {} }

-----------------------------------------------------------------

local test_CA, exec_also = false, false

if test_CA then  -- Test a specific CA ...
    cfg = {}

    if (wesnoth.current.side == 1) then
        local start_time = wesnoth.get_time_stamp() / 1000.
        wesnoth.message('Start time:', start_time)
        local eval = wesnoth.dofile(fn):evaluation(ai, cfg, self)
        wesnoth.message('Eval score:', eval)
        wesnoth.message('Time after eval:', wesnoth.get_time_stamp() / 1000., wesnoth.get_time_stamp() / 1000. - start_time)
        if (exec_also) and (eval > 0) then
            wesnoth.dofile(fn):execution(ai, cfg, self)
            wesnoth.message('Time after exec:', wesnoth.get_time_stamp() / 1000., wesnoth.get_time_stamp() / 1000. - start_time)
        end
    else
        wesnoth.message("This only works when you're in control of Side 1")
    end

else  -- ... or do manual testing
    -- To initialize "old-style" AIs that do not use external CAs yet
    --local fred = wesnoth.dofile(fn).init()
    --DBG.dbms(fred)

    local leader = wesnoth.get_units{ side = 1, canrecruit = 'yes' }[1]
    local units = wesnoth.get_units{ side = 1, canrecruit = 'no' }
    local enemies = wesnoth.get_units{ side = 2, canrecruit = 'no' }
    print(#units, #enemies)
    local unit = units[1]
    local enemy = enemies[1]

    local start_time = wesnoth.get_time_stamp() / 1000.
    wesnoth.message('Start time:', start_time)

    ------- Do something with the units here -------

    wesnoth.message('Finish time:', wesnoth.get_time_stamp() / 1000. .. '  ' .. tostring(wesnoth.get_time_stamp() / 1000. - start_time))
end
