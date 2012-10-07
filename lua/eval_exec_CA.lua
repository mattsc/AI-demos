-- This is a collection of functions that can be used to evaluate and/or execute
-- individual candidate actions from the right-click menu
--
-- See the github wiki page for a detailed description of how to use them:
-- https://github.com/mattsc/Wesnoth-AI-Demos/wiki/CA-debugging

local function CA_name()
    -- This function returns the name of the CA to be executed or evaluated
    -- It takes the value from WML variable 'debug_CA_name' if that variable exists,
    -- otherwise it defaults to 'recruit_orcs'

    local name = wesnoth.get_variable('debug_CA_name')
    return name or 'recruit_orcs'
end

local function get_all_CA_names()
    -- Return an array of CA names to choose from

    -- First, get all the custom AI functions
    local tmp_ai = wesnoth.dofile("~add-ons/AI-demos/lua/grunt-rush-Freelands-S1_engine.lua").init(ai)

    -- Loop through the tmp_ai table and set up table of all available CAs
    local cas = {}
    for k,v in pairs(tmp_ai) do
        local pos = string.find(k, '_eval')
        if pos and (pos == string.len(k) - 4) then
            local name = string.sub(k, 1, pos-1)
            if (name ~= 'stats') and (name ~= 'reset_vars') then
                table.insert(cas, name)
            end
        end
    end

    -- Sort the CAs alphabetically
    table.sort(cas, function(a, b) return (a < b) end)

    return cas
end

local function eval_CA()
    -- Evaluates the CA with name returned by CA_name()

    local eval_name = CA_name() .. '_eval'
    wesnoth.message("Evaluating individual CA: " .. eval_name .. "()")

    -- Get all the custom AI functions
    my_ai = wesnoth.dofile("~add-ons/AI-demos/lua/grunt-rush-Freelands-S1_engine.lua").init(ai)

    -- Need to set up a fake 'self.data' table, as that does not exist outside the AI engine
    -- This is taken from the global table 'self_data_table', because it needs to persist between moves
    my_ai.data = self_data_table

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

    -- Now display and return the evaluation score
    local score = 0
    if found then
        score = eval_function()
        wesnoth.message("  Score : " .. score)
    else
        wesnoth.message("  Found no function of that name")
    end

    -- At the end, transfer my_ai.data content to global self_data_table
    self_data_table = my_ai.data

    return score
end

local function exec_CA(ai)
    -- Executes the CA with name returned by CA_name()

    if ai then
        local exec_name = CA_name() .. '_exec'
        wesnoth.message("  -> Executing individual CA: " .. exec_name .. "()")

        -- Get all the custom AI functions
        my_ai = wesnoth.dofile("~add-ons/AI-demos/lua/grunt-rush-Freelands-S1_engine.lua").init(ai)

        -- Need to set up a fake 'self.data' table, as that does not exist outside the AI engine
        -- This is taken from the global table 'self_data_table', because it needs to persist between moves
        my_ai.data = self_data_table

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

return {
    debug_CA = function()
        -- CA debugging mode is enabled if this function returns true,
        -- that is, only if 'debug_CA_mode=true' is set and if we're in debug mode
        local debug_CA_mode = true
        if debug_CA_mode and wesnoth.game_config.debug then
            wesnoth.fire_event("debug_CA")
        end
    end,

    reset_vars = function()
        -- Get the old selected CA name
        local name = CA_name()

        -- Set reset_var for execution
        wesnoth.set_variable('debug_CA_name', 'reset_vars')

        -- And call it for execution
        -- Don't need the actual 'ai_global' for that, but need a dummy table)
        exec_CA({})

        -- Now reset the CA name
        wesnoth.set_variable('debug_CA_name', name)
    end,

    eval_CA = function()
        -- This simply calls the function of the same name
        -- Done so that it is available from several functions inside this table
        eval_CA()
    end,

    eval_exec_CA = function(ai)
        -- This calls eval_CA(), then exec(CA) if the score is >0
        local score = eval_CA()
        if (score > 0) then exec_CA(ai) end
    end,

    choose_CA = function()
        -- Lets the user choose a CA from a menu
        -- The result is stored in WML variable 'debug_CA_name'

        local cas = get_all_CA_names()

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
