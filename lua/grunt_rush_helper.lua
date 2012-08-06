local H = wesnoth.require "lua/helper.lua"
local W = H.set_wml_action_metatable {}

local grunt_rush_helper = {}

function grunt_rush_helper.is_GRFLS1()
    -- Check whether Side 1 is played by 'Grunt Rush for Freelands Side 1' AI
    -- We do this by testing whether the 'rush_right' CA exists

    local stage = H.get_child( H.get_child( wesnoth.sides[1].__cfg, 'ai'), 'stage')
    for CA in H.child_range(stage, 'candidate_action') do
        --print(CA.name)
        if (CA.name == 'rush_right') then return true end
    end

    return false
end

function grunt_rush_helper.GRFLS1_hello()
    -- Hello message for 'Grunt Rush for Freelands Side 1' AI
    if grunt_rush_helper.is_GRFLS1() then
        W.message { 
            speaker = 'narrator',
            caption = "Hello from the Freelands AI",
            image = 'wesnoth-icon.png', message = "Good luck, have fun !"
        }
    end
end

function grunt_rush_helper.GRFLS1_bye()
    -- Good bye message for 'Grunt Rush for Freelands Side 1' AI
    if grunt_rush_helper.is_GRFLS1() then
        W.delay { time = 300 }
        W.message { 
            side = 1, canrecruit = 'yes', 
            message = 'Good game, thanks !'
        }
    end
end


return grunt_rush_helper
