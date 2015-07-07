local H = wesnoth.require "lua/helper.lua"
local W = H.set_wml_action_metatable {}

local fred_messages = {}

function fred_messages.is_freelands()
    -- Check whether side is played by Fred
    -- We do this by testing whether the 'zone_control' CA exists
    local stage = H.get_child( H.get_child( wesnoth.sides[1].__cfg, 'ai'), 'stage')
    for CA in H.child_range(stage, 'candidate_action') do
        --print(CA.name)
        if (CA.name == 'zone_control') then return true end
    end

    return false
end

function fred_messages.fred_hello()
    -- Hello message for Fred AI
    if fred_messages.is_freelands() then

        local version = wesnoth.get_variable('AI_Demos_version')
        version = version or '?.?.?'

        -- We first add a check here whether the AI is for Side 1 and the Freelands map
        -- None of these can be checked directly, but at least for mainline the method is unique anyway

        -- Map is checked through the map size and the starting location of the AI side
        -- This also takes care of the side check, so that does not have to be done separately
        local width, height = wesnoth.get_map_size()
        local start_loc = wesnoth.get_starting_location(wesnoth.current.side)

        if (width ~= 37) or (height ~= 24) or (start_loc[1] ~= 19) or ((start_loc[2] ~= 4) and (start_loc[2] ~= 20)) then
            W.message {
                speaker = 'narrator',
                caption = "Message from the Freelands AI  (Fred v" .. version .. ")",
                image = 'wesnoth-icon.png', message = "I only know how to play Side 1 on the Freelands map. Sorry!"
            }
            W.endlevel { result = 'defeat' }
        else
            W.message {
                speaker = 'narrator',
                caption = "Hello from the Freelands AI  (Fred v" .. version .. ")",
                image = 'wesnoth-icon.png', message = "Good luck, have fun !"
            }
        end
    end
end

function fred_messages.fred_bye()
    -- Good bye message for Fred AI
    if fred_messages.is_freelands() then
        W.delay { time = 300 }
        W.message {
            side = 1, canrecruit = 'yes',
            message = 'Good game, thanks !'
        }
    end
end

return fred_messages
