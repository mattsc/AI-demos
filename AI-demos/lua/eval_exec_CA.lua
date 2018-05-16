-- This is a collection of functions that can be used to evaluate and/or execute
-- Fred's zone_control CA from the right-click menu
--
-- See the github wiki page for a detailed description of how to use them:
-- https://github.com/mattsc/Wesnoth-AI-Demos/wiki/CA-debugging

--local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local function debug_CA()
    -- Edit manually whether you want debug_CA mode or not
    return false
end

local function is_wrong_side(side)
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

    wesnoth.wml_actions.set_menu_item {
        id = 'm02a_units_info',
        description = "Show Units Info",
        image = 'items/ring-silver.png~CROP(26,26,20,20)',
        { 'command', {
            { 'lua', {
                code = 'wesnoth.dofile "~add-ons/AI-demos/lua/eval_exec_CA.lua".units_info()'
            } },
        } },
        { 'default_hotkey', { key = 'i' } }
    }

    wesnoth.wml_actions.set_menu_item {
        id = 'm05_play_turn',
        description = "Play an entire AI turn",
        image = 'items/ring-white.png~CROP(26,26,20,20)',
        { 'command', {
            { 'lua', {
                code = 'wesnoth.dofile "~add-ons/AI-demos/lua/eval_exec_CA.lua".play_turn()'
            } },
        } },
        { 'default_hotkey', { key = 'a', shift = 'yes' } }
    }
end

local function init_CA(self)
    wesnoth.clear_messages()
    if is_wrong_side(1) then return end

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

return {
    activate_CA_debugging_mode = function()
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

            set_menus()
        else
            wesnoth.wml_actions.clear_menu_item { id = 'm01_eval' }
            wesnoth.wml_actions.clear_menu_item { id = 'm02_exec' }
            wesnoth.wml_actions.clear_menu_item { id = 'm02a_units_info' }
            wesnoth.wml_actions.clear_menu_item { id = 'm05_play_turn' }
        end
    end,

    eval_exec_CA = function(exec_also)
        if is_wrong_side(1) then return end

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

    play_turn = function(ai)
        -- Play through an entire AI turn
        if is_wrong_side(1) then return end

        local self = dummy_self

        while 1 do
            local ai, ca = init_CA(self)

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
    end
}
