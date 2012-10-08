-- This is a collection of functions that can be used to evaluate and/or execute
-- individual candidate actions from the right-click menu
--
-- See the github wiki page for a detailed description of how to use them:
-- https://github.com/mattsc/Wesnoth-AI-Demos/wiki/CA-debugging

local function wrong_side(side)
    if (side ~= wesnoth.current.side) then
        wesnoth.message("!!!!! Error !!!!!  You need to be in control of Side " .. side)
        return true
    end
    return false
end

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

local function eval_CA(no_messages)
    -- Evaluates the CA with name returned by CA_name()

    local eval_name = CA_name() .. '_eval'

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
        if (not no_messages) then wesnoth.message("Evaluation score for " .. CA_name() .. ': ' .. score) end
    else
        if (not no_messages) then wesnoth.message("Found no CA of that name: " .. CA_name()) end
    end

    -- At the end, transfer my_ai.data content to global self_data_table
    self_data_table = my_ai.data

    return score
end

local function exec_CA(ai, no_messages)
    -- Executes the CA with name returned by CA_name()

    if ai then
        local exec_name = CA_name() .. '_exec'
        if (not no_messages) then wesnoth.message("Executing CA: " .. CA_name()) end

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

local function highest_score_CA()
    local cas = get_all_CA_names()

    local best_ca, max_score = '', 0
    for i,c in ipairs(cas) do
        wesnoth.set_variable('debug_CA_name', c)
        local score = eval_CA(true)
        --wesnoth.message(c .. ': ' .. score)

        if (score > max_score) then
            best_ca, max_score = c, score
        end
    end

    return best_ca, max_score
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

    reset_vars = function(no_messages)
        -- Reset the 'self.data' variable to beginning-of-turn values
        if wrong_side(1) then return end

        -- Get the old selected CA name
        local name = CA_name()

        -- Set reset_var for execution
        wesnoth.set_variable('debug_CA_name', 'reset_vars')

        -- And call it for execution
        -- Don't need the actual 'ai_global' for that, but need a dummy table)
        exec_CA({}, no_messages)

        -- Now reset the CA name
        wesnoth.set_variable('debug_CA_name', name)
    end,

    eval_CA = function()
        -- This simply calls the function of the same name
        -- Done so that it is available from several functions inside this table
        if wrong_side(1) then return end
        eval_CA()
    end,

    eval_exec_CA = function(ai)
        -- This calls eval_CA(), then exec(CA) if the score is >0
        if wrong_side(1) then return end
        local score = eval_CA()
        if (score > 0) then exec_CA(ai) end
    end,

    choose_CA = function()
        -- Lets the user choose a CA from a menu
        -- The result is stored in WML variable 'debug_CA_name'
        if wrong_side(1) then return end

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
    end,

    highest_score_CA = function()
        -- Finds and displays the name of the highest-scoring CA
        if wrong_side(1) then return end

        local ca, score = highest_score_CA()

        if (score > 0) then
            wesnoth.message('Highest scoring CA: ' .. ca .. ': ' .. score)
            wesnoth.set_variable('debug_CA_name', ca)
        else
            wesnoth.message('No CA has a score greater than 0')
            wesnoth.set_variable('debug_CA_name', 'recruit_orcs')
        end
    end,

    play_turn = function(ai)
        -- Play through an entire AI turn
        if wrong_side(1) then return end

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        -- First reset all the variables
        wesnoth.set_variable('debug_CA_name', 'reset_vars')
        exec_CA({})

        while 1 do
            local ca, score = highest_score_CA()

            if (score > 0) then
                W.message {
                    speaker = 'narrator',
                    caption = "Executing " .. ca .. " CA",
                    image = 'wesnoth-icon.png', message = "Score: " .. score
                }

                -- Need to evaluate the CA again first, so that 'self.data' gets set up
                wesnoth.set_variable('debug_CA_name', ca)
                eval_CA(true)
                exec_CA(ai, true)
            else
                W.message {
                    speaker = 'narrator',
                    caption = "No more CAs with positive scores to execute",
                    image = 'wesnoth-icon.png', message = "Note that the RCA AI might still take over some moves at this point.  That cannot be simulated here."
                }
                break
            end
        end
    end
}
