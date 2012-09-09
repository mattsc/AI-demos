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
--    Just make the changes, save and the right-click should execute the changed version
-- 2. Launching game with Fred in control of Side 1
--    Only thing required is that era 'Default+Experimental AI' is used

local function CA_name()
    -- This function sets the name of the CA to be executed or evaluated
    -- It takes the value from WML variable 'debug_CA_name' if that variable exists,
    -- otherwise it defaults to 'recruit_orcs'

    local name = wesnoth.get_variable('debug_CA_name')
    return name or 'recruit_orcs'
end

return {
    debug_CA = function()
        local debug_CA_mode = true
        if debug_CA_mode and wesnoth.game_config.debug then
            wesnoth.fire_event("debug_CA")
        end
    end,

    eval_exec_CA = function(exec_also, ai)
        -- exec_also = nil/false: only evaluate the CA
        -- exec_also = true: also execute the CA, if eval score > 0
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
        local score = 0
        if found then
            -- Need to set up a fake 'self.data' table, as that does not exist outside the AI
            if not my_ai.data then my_ai.data = {} end

            score = eval_function()
            wesnoth.message("  Score : " .. score)
        else
            wesnoth.message("  Found no function of that name")
            return
        end

        if (score > 0) and exec_also then
            if ai then
                local exec_name = CA_name() .. '_exec'
                wesnoth.message("  -> Executing individual CA: " .. exec_name .. "()")

                -- Loop through the my_ai table until we find the function we are looking for
                local exec_function = ''
                for k,v in pairs(my_ai) do
                    if (k == exec_name) then
                        exec_function = v
                        exec_function()
                    end
                end
            else
                wesnoth.message("!!!!! Error !!!!!  CAs not activated for execution.  Use right-click option.")
            end
        end
    end,

    choose_CA = function()
        -- Let's the user choose a CA from a menu
        -- The result will be stored in WML variable 'debug_CA_name'

        -- Set up array of CAs to choose from
        -- Get all the custom AI functions
        local my_ai = wesnoth.dofile("~add-ons/AI-demos/lua/grunt-rush-Freelands-S1_engine.lua").init(ai)

        -- Loop through the my_ai table and set up table of all available CAs
        local cas = {}
        for k,v in pairs(my_ai) do
            local pos = string.find(k, '_eval')
            if (pos) then
                table.insert(cas, string.sub(k, 1, pos-1))
            end
        end

        -- Sort the CAs alphabetically
        table.sort(cas, function(a, b) return (a < b) end)

        -- Let user choose one of the CAs
        local choice = helper.get_user_choice(
            {
                speaker = "narrator",
                image = "wesnoth-icon.png", 
                caption = "Choose Candidate Action",
                message = "Which CA do you want to evaluate or execute?"
            },
            cas
        )
        --wesnoth.message(cas[choice])

        -- Now set the WML variable
        wesnoth.set_variable('debug_CA_name', cas[choice])
    end
}
