-- This is a collection of functions that can be used to evaluate and/or execute
-- individual candidate actions from the right-click menu
--
-- See the github wiki page for a detailed description of how to use them:
-- https://github.com/mattsc/Wesnoth-AI-Demos/wiki/CA-debugging

local function CA_name()
    -- This function sets the name of the CA to be executed or evaluated
    -- It takes the value from WML variable 'debug_CA_name' if that variable exists,
    -- otherwise it defaults to 'recruit_orcs'

    local name = wesnoth.get_variable('debug_CA_name')
    return name or 'recruit_orcs'
end

return {
    debug_CA = function()
        -- CA debugging mode is enabled if this function returns true,
        -- that is, only if 'debug_CA_mode=true' is set and if we're in debug mode
        local debug_CA_mode = false
        if debug_CA_mode and wesnoth.game_config.debug then
            wesnoth.fire_event("debug_CA")
        end
    end,

    eval_exec_CA = function(exec_also, ai)
        -- Evaluates and potentially executes the CA with name returned by CA_name()
        -- Input:
        --   exec_also = nil/false: only evaluate the CA
        --   exec_also = true: also execute the CA, if eval score > 0
        --   ai: the ai function table

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
            -- Need to set up a fake 'self.data' table, as that does not exist outside the AI engine
            if not my_ai.data then my_ai.data = {} end
            score = eval_function()
            wesnoth.message("  Score : " .. score)
        else
            wesnoth.message("  Found no function of that name")
            return
        end

        -- If the score is positive and exec_also=true is set, execute the CA
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
                wesnoth.message("!!!!! Error !!!!!  CAs not activated for execution.")
            end
        end
    end,

    choose_CA = function()
        -- Lets the user choose a CA from a menu
        -- The result is stored in WML variable 'debug_CA_name'

        -- Set up array of CAs to choose from
        -- Get all the custom AI functions
        local my_ai = wesnoth.dofile("~add-ons/AI-demos/lua/grunt-rush-Freelands-S1_engine.lua").init(ai)

        -- Loop through the my_ai table and set up table of all available CAs
        local cas = {}
        for k,v in pairs(my_ai) do
            local pos = string.find(k, '_eval')
            if pos and (pos == string.len(k) - 4) then
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
