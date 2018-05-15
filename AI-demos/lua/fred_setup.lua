local function is_fred()
    -- Check whether side is played by Fred
    -- We do this by testing whether the 'zone_control' CA exists
    -- Returns the side number of the first side for which the CA is found, false otherwise

    for _,side_info in ipairs(wesnoth.sides) do
        local stage = wml.get_child(wml.get_child(side_info.__cfg, 'ai'), 'stage')
        for CA in wml.child_range(stage, 'candidate_action') do
            --print(CA.name)
            if (CA.name == 'zone_control') then return side_info.side end
        end
    end

    return false
end

local fred_setup = {}

function fred_setup.fred_setup()
    -- Hello message for Fred AI
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

        wesnoth.require "~/add-ons/AI-demos/lua/fred_events.lua"
    end
end

function fred_setup.show_behavior()
    local options = { 'off', 'instructions only', 'instructions and fronts'}

    local fred_show_behavior = wml.variables.fred_show_behavior or 1
    fred_show_behavior = (fred_show_behavior % #options) + 1
    wml.variables.fred_show_behavior = fred_show_behavior

    local str = 'Show behavior now set to ' .. fred_show_behavior .. ': ' .. options[fred_show_behavior]
    wesnoth.message('Fred', str)
    print(str)
end

function fred_setup.show_last_behavior()
    local fred_behavior_str = wml.variables.fred_behavior_str or 'No behavior instructions yet'

    wesnoth.message('Fred', fred_behavior_str)
    print(fred_behavior_str)
end

return fred_setup
