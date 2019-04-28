-- This is the manual 'AI handler'
-- Want this in a separate file, so that it can be changed on the fly
-- It loads the AI from another file which can then be executed by right-click menu

-- Start test scenario from command line with
-- /Applications/Wesnoth-1.11.app/Contents/MacOS/Wesnoth -d -l AI-demos-test.gz

-- Include all these, just in case (mostly not needed)
local H = wesnoth.require "helper"
local AH = wesnoth.require "ai/lua/ai_helper.lua"
local MAIH = wesnoth.require "ai/micro_ais/micro_ai_helper.lua"
local MAIUV = wesnoth.require "ai/micro_ais/micro_ai_unit_variables.lua"
local MAISD = wesnoth.require "ai/micro_ais/micro_ai_self_data.lua"
local BC = wesnoth.require "ai/lua/battle_calcs.lua"
local FGU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_gamestate_utils.lua"
local FGUI = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_gamestate_utils_incremental.lua"
local FU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_utils.lua"
local FAU = wesnoth.dofile "~/add-ons/AI-demos/lua/fred_attack_utils.lua"
local LS = wesnoth.require "location_set"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

-- Clean up the screen
wesnoth.clear_messages()
AH.clear_labels()
std_print('\n---- Side ', wesnoth.current.side, '------------')

-- Check for debug mode and quit if it is not activated
if (not wesnoth.game_config.debug) then
    wesnoth.message("***** This option requires debug mode. Activate by typing ':debug' *****")
    return
end

-- Add shortcut to debug ai table
local ai = wesnoth.debug_ai(wesnoth.current.side).ai
--DBG.dbms(ai, false, 'ai')

local fn_fred = "~add-ons/AI-demos/lua/fred.lua"
local fn = "ai/micro_ais/cas/ca_fast_move.lua"
local self = { data = {} }
local cfg = {}

-----------------------------------------------------------------

local test_CA, exec_also, exec_loop = true, false, false

if test_CA then  -- Test a specific CA ...
    --local cfg = { ca_score = 300000 }
    local cfg = { ca_score = 300000, target_id='Bad Orc', { "filter", { type = 'Orcish Grunt' } } }

    eval = 1

    if (wesnoth.current.side == 1) then
        while (eval > 0)  do
            local start_time = wesnoth.get_time_stamp() / 1000.
            wesnoth.message('Start time:', start_time)
            eval = wesnoth.dofile(fn):evaluation(ai, cfg, self)
            wesnoth.message('Eval score:', eval)
            wesnoth.message('Time after eval:', wesnoth.get_time_stamp() / 1000., wesnoth.get_time_stamp() / 1000. - start_time)
            if (eval > 0) and (exec_also or exec_loop) then
                wesnoth.dofile(fn):execution(ai, cfg, self)
                wesnoth.message('Time after exec:', wesnoth.get_time_stamp() / 1000., wesnoth.get_time_stamp() / 1000. - start_time)
            end

            -- Only do another iteration if ca_exec_loop is set.
            -- The loop is also broken if evaluation resulted in a score of 0.
            if (not exec_loop) then
                eval = 0
            end
        end
    else
        wesnoth.message("This only works when you're in control of Side 1")
    end

else  -- ... or do manual testing
    -- Set up Fred's variables
    local move_data = FGU.get_move_data()
    local move_cache = {}
    --for k,_ in pairs(move_data) do
    --    std_print(k)
    --end


    local leader = wesnoth.get_units { side = 1, canrecruit = 'yes' }[1]
    local units = wesnoth.get_units { side = 1, canrecruit = 'no' }
    local enemies = wesnoth.get_units { side = 2, canrecruit = 'no' }
    std_print('#units, #enemies', #units, #enemies)
    local unit = units[1]
    local enemy = enemies[1]

    local start_time = wesnoth.get_time_stamp()
    wesnoth.message('Start time:', start_time)
    std_print('Start time:', start_time)

    ------- Begin: Do something with the units here -------



    local end_time = wesnoth.get_time_stamp()
    wesnoth.message('Finish time:', end_time .. '  ' .. tostring(end_time - start_time))
    std_print('Finish time:', end_time .. '  ' .. tostring(end_time - start_time))
end
