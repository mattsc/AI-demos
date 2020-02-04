local function fred_sides()
    -- Check which sides are played by Fred
    -- We do this by testing whether the 'zone_control' CA exists
    -- Returns an array of the side numbers played by Fred

    local fred_sides = {}
    for _,side_info in ipairs(wesnoth.sides) do
        local stage = wml.get_child(wml.get_child(side_info.__cfg, 'ai'), 'stage')
        for CA in wml.child_range(stage, 'candidate_action') do
            --std_print(CA.name)
            if (CA.name == 'zone_control') then
                table.insert(fred_sides, side_info.side)
                break
            end
        end
    end

    return fred_sides
end

local fred_scenario_setup = {}

function fred_scenario_setup.fred_scenario_setup()
    local fred_sides_table = fred_sides()

    if fred_sides_table[1] then
        -- First we set the names and ids of the leaders of all sides played by Fred
        -- This is done mostly for the messages
        for _,fred_side in pairs(fred_sides_table) do
            wesnoth.wml_actions.modify_unit {
                { 'filter', { side = fred_side, canrecruit = 'yes' } },
                id = 'Fred' .. fred_side,
                name = 'Fred Side ' .. fred_side
            }
        end

        -- We put this into a WML variable, so that it can easily be retrieved from replays
        wml.variables['AI_Demos_version'] = wesnoth.dofile('~/add-ons/AI-demos/version.lua')

        local version = wml.variables.AI_Demos_version
        version = version or '?.?.?'

        -- Freelands map is checked through the map size and the starting location of side 1
        local width, height = wesnoth.get_map_size()
        local start_loc = wesnoth.get_starting_location(1)

        if (width ~= 37) or (height ~= 24) or (start_loc[1] ~= 19) or ((start_loc[2] ~= 4) and (start_loc[2] ~= 20)) then
            wesnoth.wml_actions.message {
                id = 'Fred' .. fred_sides_table[1],
                caption = "Fred (Freelands AI v" .. version .. ")",
                message = "I currently only know how to play the Freelands map. Sorry!"
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
                id = 'Fred' .. fred_sides_table[1],
                message = "I'm noticing that you have fog/shroud turned on. I'm turning it off in order to help with testing."
            }
            wesnoth.wml_actions.modify_side {
                side = '1,2',
                fog = false,
                shroud = false
            }
        end

        -- Set the message and easter egg events
        wesnoth.require "~/add-ons/AI-demos/lua/fred_scenario_events.lua"

        -- Set the behavior display menu options
        wesnoth.wml_actions.set_menu_item {
            id = 'm08_show_behavior',
            description = "Toggle Fred's behavior analysis display",
            image = 'items/ring-white.png~CROP(26,26,20,20)',
            { 'show_if', {
                { 'lua', {
                    code = "return wesnoth.game_config.debug"
                } },
            } },
            { 'command', {
                { 'lua', {
                    code = "local options = { 'off', 'start turn instructions only', 'move instructions (text)', 'move instructions (map)', 'move instructions (text & map)' }"
                    .. " local fred_show_behavior = wml.variables.fred_show_behavior or 1"
                    .. " fred_show_behavior = (fred_show_behavior % #options) + 1"
                    .. " wml.variables.fred_show_behavior = fred_show_behavior"
                    .. " local str = 'Show behavior now set to ' .. fred_show_behavior .. ': ' .. options[fred_show_behavior] .. '    (press shift-b to change)'"
                    .. " wesnoth.message('Fred', str)"
                    .. " std_print(str)"
                } },
            } },
            { 'default_hotkey', { key = 'b', shift = 'yes' } }
        }

        wesnoth.wml_actions.set_menu_item {
            id = 'm09_last_behavior',
            description = "Fred's most recent behavior instructions",
            image = 'items/ring-white.png~CROP(26,26,20,20)',
            { 'show_if', {
                { 'lua', {
                    code = "return wesnoth.game_config.debug"
                } },
            } },
            { 'command', {
                { 'lua', {
                    code = "local fred_behavior_str = wml.variables.fred_behavior_str or 'No behavior instructions yet'"
                    .. " wesnoth.message('Fred', fred_behavior_str)"
                    .. " std_print(fred_behavior_str)"
                } },
            } },
            { 'default_hotkey', { key = 'b' } }
        }

        -- Also remove the variables and menu items at the end of the scenario.
        -- This is only important when playing Fred from the switchboard
        -- scenario in AI-demos, and going back to switchboard afterward.
        -- The behavior variables also need to be deleted when loading.
        wesnoth.add_event_handler {
            name = 'victory,defeat,time_over,enemies_defeated,preload',
            first_time_only = 'no',
            { 'clear_variable', { name = 'fred_behavior_str' } },
            { 'clear_variable', { name = 'fred_show_behavior' } }
        }
        wesnoth.add_event_handler {
            name = 'victory,defeat,time_over,enemies_defeated',
            first_time_only = 'no',
            { 'clear_variable', { name = 'AI_Demos_version' } },
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
