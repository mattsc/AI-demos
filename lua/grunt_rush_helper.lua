local H = wesnoth.require "lua/helper.lua"
local W = H.set_wml_action_metatable {}

local grunt_rush_helper = {}

function grunt_rush_helper.is_GRFLS1()
    -- Check whether Side 1 is played by 'Grunt Rush for Freelands Side 1' AI
    -- We do this by testing whether the 'rush_right' CA exists
    local stage = H.get_child( H.get_child( wesnoth.sides[1].__cfg, 'ai'), 'stage')
    for CA in H.child_range(stage, 'candidate_action') do
        --print(CA.name)
        if (CA.name == 'zone_control') then return true end
    end

    return false
end

function grunt_rush_helper.GRFLS1_hello()
    -- Hello message for 'Grunt Rush for Freelands Side 1' AI
    if grunt_rush_helper.is_GRFLS1() then

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

        -- Map is checked through the map size and the starting location of the AI side
        -- This also takes care of the side check, so that does not have to be done separately
        local width, height = wesnoth.get_map_size()
        local start_loc = wesnoth.get_starting_location(wesnoth.current.side)

        if (not can_recruit_grunts) or (width ~= 37) or (height ~= 24) or (start_loc[1] ~= 19) or (start_loc[2] ~= 4) then
            W.message {
                speaker = 'narrator',
                caption = "Message from the Freelands AI  (Fred v" .. version .. ")",
                image = 'wesnoth-icon.png', message = "I only know how to play Northerners for Side 1 on the Freelands map.  Sorry!"
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
