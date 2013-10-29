-- This is the manual 'AI handler'
-- Want this in a separate file, so that it can be changed on the fly
-- It loads the AI from another file which can then be executed by right-click menu

-- Start test scenario from command line with
-- /Applications/Wesnoth-1.11.app/Contents/MacOS/Wesnoth -d -l AI-demos-test.gz

-- Include all these, just in case (mostly not needed)
local H = wesnoth.require "lua/helper.lua"
local W = H.set_wml_action_metatable {}
local AH = wesnoth.dofile "~/add-ons/AI-demos/lua/ai_helper.lua"
local BC = wesnoth.dofile "~/add-ons/AI-demos/lua/battle_calcs.lua"
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
local my_ai = wesnoth.dofile(fn).init(ai)
my_ai.data = {}
--DBG.dbms(my_ai)

-----------------------------------------------------------------

local test_CA, exec_also = false, false

if test_CA then  -- Test a specific CA ...

    if (wesnoth.current.side == 1) then
        local start_time = wesnoth.get_time_stamp() / 1000.
        wesnoth.message('Start time:', start_time)
        local eval = my_ai:zone_control_eval()
        wesnoth.message('Eval score:', eval)
        wesnoth.message('Time after eval:', wesnoth.get_time_stamp() / 1000., wesnoth.get_time_stamp() / 1000. - start_time)
        if (exec_also) and (eval > 0) then
            my_ai:zone_control_exec()
            wesnoth.message('Time after exec:', wesnoth.get_time_stamp() / 1000., wesnoth.get_time_stamp() / 1000. - start_time)
        end
    else
        wesnoth.message("This only works when you're in control of Side 1")
    end

else  -- ... or do manual testing

    local units = wesnoth.get_units{ side = 1, canrecruit = 'no' }
    local enemies = wesnoth.get_units{ side = 2, canrecruit = 'no' }
    --print(#units,#enemies)
    local attacker = units[1]
    local defender = enemies[1]

    local dst = { 20, 8 }

    local start_time = wesnoth.get_time_stamp() / 1000.
    wesnoth.message('Start time:', start_time)

    local cache={}
    local cfg = {att_weapon = 2, def_weapon = 2, dst = dst}

    for i=1,1 do
        att_stats,def_stats = BC.battle_outcome(attacker, defender, cfg, cache)
    end
    DBG.dbms(att_stats)
    DBG.dbms(def_stats)

    wesnoth.message('Time after loop:', wesnoth.get_time_stamp() / 1000. .. '  ' .. tostring(wesnoth.get_time_stamp() / 1000. - start_time))

    local r = BC.attack_rating(attacker, defender, dst, { att_weapon = 1, def_weapon = 1 })
    print('Rating weapon #1:', r)
    local r = BC.attack_rating(attacker, defender, dst)
    print('Rating best weapon',r)

    wesnoth.message('Finish time:', wesnoth.get_time_stamp() / 1000. .. '  ' .. tostring(wesnoth.get_time_stamp() / 1000. - start_time))
end
