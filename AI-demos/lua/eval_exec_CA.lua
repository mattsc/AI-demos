-- This is a collection of functions that can be used to evaluate and/or execute
-- individual candidate actions from the right-click menu
--
-- See the github wiki page for a detailed description of how to use them:
-- https://github.com/mattsc/Wesnoth-AI-Demos/wiki/CA-debugging

--local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local function debug_CA()
    -- Edit manually whether you want debug_CA mode or not
    return false
end

local function wrong_side(side)
    if (side ~= wesnoth.current.side) then
        wesnoth.message("!!!!! Error !!!!! You need to be in control of Side " .. side)
        return true
    end
    return false
end

local function CA_name()
    -- This function returns the name of the CA to be executed or evaluated
    -- It takes the value from WML variable 'debug_CA_name' if that variable exists,
    -- otherwise it defaults to 'recruit_orcs'

    local name = wml.variables.debug_CA_name
    return name or 'zone_control'
end

local function set_menus()
    -- Set the two menu items that have the selected CA name in them
    -- They need to be reset when that is changed, that's why this is done here

    wesnoth.wml_actions.set_menu_item {
        id = 'm01_eval',
        description = 'Evaluate Single Candidate Action: ' .. CA_name(),
        image = 'items/ring-red.png~CROP(26,26,20,20)',
        { 'command', {
            { 'lua', {
                code = 'wesnoth.dofile "~add-ons/AI-demos/lua/eval_exec_CA.lua".eval_exec_CA(false)'
            } },
        } },
        { 'default_hotkey', { key = 'v' } }
    }

    wesnoth.wml_actions.set_menu_item {
        id = 'm02_exec',
        description = 'Evaluate and Execute Single Candidate Action: ' .. CA_name(),
        image = 'items/ring-gold.png~CROP(26,26,20,20)',
        { 'command', {
            { 'lua', {
                code = 'wesnoth.dofile "~add-ons/AI-demos/lua/eval_exec_CA.lua".eval_exec_CA(true)'
            } },
        } },
        { 'default_hotkey', { key = 'x' } }
    }
end

local function get_all_CA_names()
    -- TODO: This is disabled for now, might be reinstated later

    --[[
    -- Return an array of CA names to choose from

    -- First, get all the custom AI functions
    local tmp_ai = wesnoth.dofile("~add-ons/AI-demos/lua/fred.lua").init(ai)

    -- Loop through the tmp_ai table and set up table of all available CAs
    local cas = {}
    for k,v in pairs(tmp_ai) do
        local pos = string.find(k, '_eval')
        if pos and (pos == string.len(k) - 4) then
            local name = string.sub(k, 1, pos-1)
            if (name ~= 'stats')
                and (name ~= 'reset_vars_turn')
                and (name ~= 'reset_vars_move')
                and (name ~= 'clear_self_data')
                and (name ~= 'recruit_rushers')
            then
                table.insert(cas, name)
            end
        end
    end

    -- Sort the CAs alphabetically
    table.sort(cas, function(a, b) return (a < b) end)

    return cas
    --]]
end

local function init_CA(self)
    wesnoth.clear_messages()
    if wrong_side(1) then return end

    -- Get the AI table and the CA functions
    local ai = wesnoth.debug_ai(wesnoth.current.side).ai
    local ca = wesnoth.dofile("~add-ons/AI-demos/lua/ca_zone_control.lua")

    -- First time we need to call reset_vars_turn:execution
    if (not self.data.turn_data) then
        wesnoth.dofile("~add-ons/AI-demos/lua/ca_reset_vars_turn.lua"):execution(nil, self, ai)
    end

    -- We always need to call reset_vars_move:evaluation first, to set up the move_data table
    wesnoth.dofile("~add-ons/AI-demos/lua/ca_reset_vars_move.lua"):evaluation(nil, self, ai)

    return ai, ca
end

local function highest_score_CA(ai)
    -- TODO: This is disabled for now, might be reinstated later

    --[[
    local cas = get_all_CA_names()

    local best_ca, max_score = '', 0
    for i,c in ipairs(cas) do
        wml.variables.debug_CA_name = c
        local score = eval_CA(ai, true)
        --wesnoth.message(c .. ': ' .. score)

        if (score > max_score) then
            best_ca, max_score = c, score
        end
    end

    return best_ca, max_score
    --]]
end

return {
    debug_CA = function()
        -- CA debugging mode is enabled if this function returns true,
        -- that is, only if 'debug_CA_mode=true' is set and if we're in debug mode
        local debug_CA_mode = debug_CA()
        if debug_CA_mode and wesnoth.game_config.debug then
            wesnoth.wml_actions.message {
                speaker = 'narrator',
                image = 'wesnoth-icon.png',
                caption = "Candidate Action Debugging Mode",
                message = "You are entering CA debugging mode. Check out the AI Demos github wiki about information on how to use this mode, or how to deactivate it."
            }

            wesnoth.sides[1].controller = 'human'
            wesnoth.sides[2].controller = 'human'

            wesnoth.fire_event("debug_CA")
        else
            wesnoth.wml_actions.clear_menu_item { id = 'm01_eval' }
            wesnoth.wml_actions.clear_menu_item { id = 'm02_exec' }
            wesnoth.wml_actions.clear_menu_item { id = 'm02a_units_info' }
            --wesnoth.wml_actions.clear_menu_item { id = 'm03_choose_ca' }
            --wesnoth.wml_actions.clear_menu_item { id = 'm04_highest_score_CA' }
            wesnoth.wml_actions.clear_menu_item { id = 'm05_play_turn' }
        end
    end,

    eval_exec_CA = function(exec_also)
        local self = dummy_self
        local ai, ca = init_CA(self)

        local score, action = ca:evaluation(nil, self, ai)
        local action_str = ''
        if action then
            action_str = action.zone_id .. '  ' .. action.action_str .. '  '
        end

        wesnoth.message("Eval score for " .. CA_name() .. ':  ' .. action_str .. score)

        if exec_also and (score > 0) then
            ca:execution(nil, self, ai)
        end
        dummy_self = self
    end,

    units_info = function(stdout_only)
        -- Shows some information for all units
        -- Specifically, this links the unit id to its position, name etc. for easier identification
        local tmp_units = wesnoth.get_units()
        local str = ''
        for _,u in ipairs(tmp_units) do
            str = str .. u.id .. ':    ' .. u.x .. ',' .. u.y
            str = str .. '    HP: ' .. u.hitpoints .. '/' .. u.max_hitpoints
            str = str .. '    XP: ' .. u.experience .. '/' .. u.max_experience
            str = str .. '    ' .. tostring(u.name)
            str = str .. '\n'
        end

        print(str)
        if (not stdout_only) then wesnoth.message(str) end
    end,

    -- TODO: This is disabled for now, might be reinstated later

    --[[
    choose_CA = function()
        -- Lets the user choose a CA from a menu
        -- The result is stored in WML variable 'debug_CA_name'
        if wrong_side(1) then return end

        local H = wesnoth.require "helper"

        local cas = get_all_CA_names()

        -- Let user choose one of the CAs
        local choice = H.get_user_choice(
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
        wml.variables.debug_CA_name = cas[choice]
        -- And set the menu items accordingly
        set_menus()
    end,
    --]]

    -- TODO: This is disabled for now, might be reinstated later

    --[[
    highest_score_CA = function(ai)
        -- Finds and displays the name of the highest-scoring CA
        if wrong_side(1) then return end

        local ca, score = highest_score_CA(ai)

        if (score > 0) then
            wesnoth.message('Highest scoring CA: ' .. ca .. ': ' .. score)
            wml.variables.debug_CA_name = ca
        else
            wesnoth.message('No CA has a score greater than 0')
            wml.variables.debug_CA_name = 'recruit_orcs'
        end
        -- And set the menu items accordingly
        set_menus()
    end,
    --]]

    play_turn = function(ai)
        -- Play through an entire AI turn
        if wrong_side(1) then return end

        local self = dummy_self

        while 1 do
            local ai, ca = init_CA(self)

            -- TODO: this is disabled for the time being
            -- local ca_name, score = highest_score_CA(ai)
            local ca_name, score = 'zone_control', ca:evaluation(nil, self, ai)

            if (score > 0) then
                wesnoth.wml_actions.message {
                    speaker = 'narrator',
                    caption = "Executing " .. ca_name .. " CA",
                    image = 'wesnoth-icon.png', message = "Score: " .. score
                }

                -- Need to evaluate the CA again first, so that 'self.data' gets set up
                wml.variables.debug_CA_name = ca_name
                ca:execution(nil, self, ai)
            else
                wesnoth.wml_actions.message {
                    speaker = 'narrator',
                    caption = "No more CAs with positive scores to execute",
                    image = 'wesnoth-icon.png', message = "That's all."
                }
                break
            end
        end

        dummy_self = self
    end,

    set_menus = function()
        -- Set the menus so that they display the name of the CA to be executed/evaluated
        set_menus()
    end
}
