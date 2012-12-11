local H = wesnoth.require "lua/helper.lua"
local W = H.set_wml_action_metatable {}

local grunt_rush_helper = {}

function grunt_rush_helper.is_GRFLS1()
    -- Check whether Side 1 is played by 'Rush AI for Freelands Side 1'
    -- We do this by testing whether the 'zone_control' CA exists
    local stage = H.get_child( H.get_child( wesnoth.sides[1].__cfg, 'ai'), 'stage')
    for CA in H.child_range(stage, 'candidate_action') do
        --print(CA.name)
        if (CA.name == 'zone_control') then return true end
    end

    return false
end

function grunt_rush_helper.GRFLS1_hello()
    -- Hello message for 'Rush AI for Freelands Side 1'
    if grunt_rush_helper.is_GRFLS1() then

        local version = wesnoth.get_variable('AI_Demos_version')
        version = version or '?.?.?'

        -- We first add a check here whether the AI is for Side 1 and the Freelands map
        -- None of these can be checked directly, but at least for mainline the method is unique anyway

        -- Map is checked through the map size and the starting location of the AI side
        -- This also takes care of the side check, so that does not have to be done separately
        local width, height = wesnoth.get_map_size()
        local start_loc = wesnoth.get_starting_location(wesnoth.current.side)

        if (width ~= 37) or (height ~= 24) or (start_loc[1] ~= 19) or (start_loc[2] ~= 4) then
            W.message {
                speaker = 'narrator',
                caption = "Message from the Freelands AI  (Fred v" .. version .. ")",
                image = 'wesnoth-icon.png', message = "I only know how to play Side 1 on the Freelands map.  Sorry!"
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

function grunt_rush_helper.GRFLS1_bye()
    -- Good bye message for 'Rush AI for Freelands Side 1'
    if grunt_rush_helper.is_GRFLS1() then
        W.delay { time = 300 }
        W.message {
            side = 1, canrecruit = 'yes',
            message = 'Good game, thanks !'
        }
    end
end


return grunt_rush_helper
