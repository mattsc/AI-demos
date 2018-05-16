local function is_fred()
    -- Check whether side is played by Fred
    -- We do this by testing whether the 'zone_control' CA exists
    -- Returns the side number of the first side for which the CA is found, false otherwise

    for _,side_info in ipairs(wesnoth.sides) do
        local stage = wml.get_child(wml.get_child(side_info.__cfg, 'ai'), 'stage')
        for CA in wml.child_range(stage, 'candidate_action') do
            --std_print(CA.name)
            if (CA.name == 'zone_control') then return side_info.side end
        end
    end

    return false
end

local fred_scenario_setup = {}

function fred_scenario_setup.fred_scenario_setup()
    local fred_side = is_fred()
    if fred_side then
        -- First thing we do is set the name and id of the side leader
        -- This is done for the messages
        wesnoth.wml_actions.modify_unit {
            { 'filter', { side = fred_side, canrecruit = 'yes' } },
            id = 'Fred',
            name = 'Fred'
        }

        local version = wml.variables.AI_Demos_version
        version = version or '?.?.?'

        -- We first add a check here whether the AI is for Side 1, Northerners and the Freelands map
        -- None of these can be checked directly, but at least for mainline the method is unique anyway

        -- Faction is checked by seeing if the side can recruit orcs
        local can_recruit_grunts = false
        for i,r in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
            if (r == 'Orcish Grunt') then
                can_recruit_grunts = true
                break
            end
        end

        -- Map is checked through the map size and the starting location of the AI side
        -- This also takes care of the side check, so that does not have to be done separately
        local width, height = wesnoth.get_map_size()
        local start_loc = wesnoth.get_starting_location(wesnoth.current.side)

        if (not can_recruit_grunts) or (width ~= 37) or (height ~= 24) or (start_loc[1] ~= 19) or ((start_loc[2] ~= 4) and (start_loc[2] ~= 20)) then
            wesnoth.wml_actions.message {
                id = 'Fred',
                caption = "Fred (Freelands AI v" .. version .. ")",
                message = "I currently only know how to play Northerners as Side 1 on the Freelands map. Sorry!"
            }
            wesnoth.wml_actions.endlevel { result = 'victory' }
            return
        end

        -- Turn off fog and shroud if set
        local fog_set = false
        for _,side_info in ipairs(wesnoth.sides) do
            if side_info.fog or side_info.shroud then
                fog_set = true
            end
        end
        if fog_set then
            wesnoth.wml_actions.message {
                id = 'Fred',
                message = "I'm noticing that you have fog/shroud turned on. I'm turning it off in order to help with testing."
            }
            wesnoth.wml_actions.modify_side {
                side = '1,2',
                fog = false,
                shroud = false
            }
        end

        -- We put this into a WML variable, so that it can easily be retrieved from replays
        wml.variables['AI_Demos_version'] = wesnoth.dofile('~/add-ons/AI-demos/version.lua')

        -- Set the message and easter egg events
        wesnoth.require "~/add-ons/AI-demos/lua/fred_scenario_events.lua"

        -- Set the behavior display menu options
        wesnoth.wml_actions.set_menu_item {
            id = 'm08_show_behavior',
            description = "Toggle Fred's behavior analysis display",
            image = 'items/ring-white.png~CROP(26,26,20,20)',
            { 'command', {
                { 'lua', {
                    code = "local options = { 'off', 'instructions only', 'instructions and fronts' }"
					.. " local fred_show_behavior = wml.variables.fred_show_behavior or 1"
					.. " fred_show_behavior = (fred_show_behavior % #options) + 1"
					.. " wml.variables.fred_show_behavior = fred_show_behavior"
					.. " local str = 'Show behavior now set to ' .. fred_show_behavior .. ': ' .. options[fred_show_behavior]"
					.. " wesnoth.message('Fred', str)"
					.. " std_print(str)"
                } },
            } },
            { 'default_hotkey', { key = 'b' } }
        }

        wesnoth.wml_actions.set_menu_item {
            id = 'm09_last_behavior',
            description = "Fred's most recent behavior instructions",
            image = 'items/ring-white.png~CROP(26,26,20,20)',
            { 'command', {
                { 'lua', {
                    code = "local fred_behavior_str = wml.variables.fred_behavior_str or 'No behavior instructions yet'"
					.. " wesnoth.message('Fred', fred_behavior_str)"
					.. " std_print(fred_behavior_str)"
                } },
            } },
            { 'default_hotkey', { key = 'b', shift = 'yes' } }
        }

        -- Also remove the variables and menu items at the end of the scenario.
        -- This is only important when playing Fred from the switchboard
        -- scenario in AI-demos, and going back to switchboard afterward.
        wesnoth.add_event_handler {
            name = 'victory,defeat,time_over,enemies_defeated',

            { 'clear_variable', { name = 'AI_Demos_version' } },
            { 'clear_variable', { name = 'fred_behavior_str' } },
            { 'clear_variable', { name = 'fred_show_behavior' } },
            { 'clear_menu_item', { id = 'm08_show_behavior' } },
            { 'clear_menu_item', { id = 'm09_last_behavior' } }
        }

        ---------- CA debugging mode ----------
        -- This needs to be activated here once, but this preload event is set
        -- to be removed after one use (because of all the other stuff in it),
        -- so we then also set up another preload event with first_time_only=no.
        -- That one will fire when saves/replays get loaded.
        wesnoth.dofile "~add-ons/AI-demos/lua/eval_exec_CA.lua".activate_CA_debugging_mode()

        wesnoth.add_event_handler {
            name = 'preload',
            first_time_only = 'no',

            { 'lua', {
                code = 'wesnoth.dofile "~add-ons/AI-demos/lua/eval_exec_CA.lua".activate_CA_debugging_mode()'
            } }
        }
    end
end

return fred_scenario_setup
