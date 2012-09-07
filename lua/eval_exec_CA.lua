-- This is a collection of functions that can be used to evaluate and/or execute
-- individual candidate actions from the right-click menu
--
-- Required: 
-- 1. Wesnoth needs to be launched in debug mode, i.e. with the -d option
--    Activating debug mode later does not work (actually, that's e requirement for the
--    menu option to be set up in era.cfg, rather than for these functions here
-- 2. The MP game needs to be launched from the MP lobby
-- 3. The name of the CA to be tested needs to be set in function CA_name() below
--
-- Not required:
-- 1. Reloading after making changes, either to this file, or to Fred's engine functions

local function CA_name()
    -- This function sets the name of the CA to be executed or evaluated
    -- Just edit it by hand
    return 'rush'
end

return {
    eval_CA = function()

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        local eval_name = CA_name() .. '_eval'
        wesnoth.message("Evaluating individual CA: " .. eval_name .. "()")

        -- Get all the custom AI functions
        local my_ai = wesnoth.dofile("~add-ons/AI-demos/lua/grunt-rush-Freelands-S1_engine.lua").init(ai)

        -- Loop through the my_ai table until we find the function we are looking for
        local found = false
        local eval_function = ''
        for k,v in pairs(my_ai) do
            if (k == eval_name) then
                found = true
                eval_function = v
                break
            end
        end

        -- Now display the evaluation score
        if found then
            -- Need to set up a fake 'self.data' table, as that does not exist outside the AI
            if not my_ai.data then my_ai.data = {} end

            local score = eval_function()
            wesnoth.message("  Score : " .. score)
        else
            wesnoth.message("  Found no function of that name")
        end
    end
}
