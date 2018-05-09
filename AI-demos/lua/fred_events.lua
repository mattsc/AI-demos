local H = wesnoth.require "helper"

local fred_events = {}

function fred_events.is_fred()
    -- Check whether side is played by Fred
    -- We do this by testing whether the 'zone_control' CA exists
    -- Returns the side number of the first side for which the CA is found, false otherwise

    for _,side_info in ipairs(wesnoth.sides) do
        local stage = H.get_child(H.get_child(side_info.__cfg, 'ai'), 'stage')
        for CA in H.child_range(stage, 'candidate_action') do
            --print(CA.name)
            if (CA.name == 'zone_control') then return side_info.side end
        end
    end

    return false
end

function fred_events.fred_setup()
    -- Hello message for Fred AI
    local fred_side = fred_events.is_fred()
    if fred_side then
        -- First thing we do is set the name and id of the side leader
        -- This is done for the messages
        wesnoth.wml_actions.modify_unit {
            { 'filter', { side = fred_side, canrecruit = 'yes' } },
            id = 'Fred',
            name = 'Fred'
        }

        local version = wesnoth.get_variable('AI_Demos_version')
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

        -- Check whether fog is set
        local fog_set = false
        for _,side_info in ipairs(wesnoth.sides) do
            if side_info.fog or side_info.shroud then
                fog_set = true
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
        else
            if fog_set then
                wesnoth.fire_event("fred_lift_fog")
            end

            wesnoth.fire_event("fred_setup_events")
        end
    end
end

function fred_events.show_behavior()
    local options = { 'off', 'instructions only', 'instructions and fronts'}

    local fred_show_behavior = wesnoth.get_variable('fred_show_behavior') or 1
    fred_show_behavior = (fred_show_behavior % #options) + 1
    wesnoth.set_variable('fred_show_behavior', fred_show_behavior)

    local str = 'Show behavior now set to ' .. fred_show_behavior .. ': ' .. options[fred_show_behavior]
    wesnoth.message('Fred', str)
    print(str)
end

function fred_events.show_last_behavior()
    local fred_behavior_str = wesnoth.get_variable('fred_behavior_str') or 'No behavior instructions yet'

    wesnoth.message('Fred', fred_behavior_str)
    print(fred_behavior_str)
end

return fred_events
