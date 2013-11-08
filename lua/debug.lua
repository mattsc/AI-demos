-- This is almost literally stolen from Wesnoth Lua Pack
-- The only difference is that I changed the default options of dbms

local debug_utils = {}

-- an extensive debug message function
-- It outputs information about type, value, length, and metatable of a variable of any lua kind.
-- It also distinguishes between general tables and tables which are also wml tables. (wml tables are a subamount of tables)
-- If a table isn't a wml table it displays info about the reason.
-- If the variable is a table or if it can be dumped to a table an extensive syntactically correct output is displayed.
-- arguments:
-- lua_var: the variable to investigate
-- clear (boolean/int, optional): if set, chat window will be cleared before displaying the message
--       if set to -1, only print message, don't display in chat window
-- name (string, optional): a name to be assigned to the variable, used in the message; useful if there are several
-- variables to be outputted to distinguish their messages
-- onscreen (boolean, optional): whether the message shall be displayed in a wml [message] dialog too
-- That [message] dialog can get very slow for large tables such as unit arrays.
function debug_utils.dbms(lua_var, clear, name, onscreen, wrap, only_return)
        if type(name) ~= "string" then name = "lua_var" end
        if type(onscreen) ~= "boolean" then onscreen = false end  -- !!!!! changed from WLP default

        local function dump_userdata(data)
                local metatable = getmetatable(data)
                if metatable == "side" then return data.__cfg, true end
                if metatable == "unit" then return data.__cfg, true end
                local data_to_string = tostring(data)
                if metatable == "translatable string" then return data_to_string, false end
                if metatable == "wml object" then return data.__literal, false end
                return data_to_string, true
        end

        local is_wml_table = true
        local result
        local wml_table_error
        local base_indent = "    "
        local function table_to_string(arg_table, indent, introduces_subtag, indices)
                local is_filled = false

                local function check_subtag()
                        local one, two = arg_table[1], arg_table[2]
                        if type(two) == "userdata" then
                                local invalidate_wml_table
                                two, invalidate_wml_table = dump_userdata(two)
                                if invalidate_wml_table then return false end
                        end
                        if type(one) ~= "string" or type(two) ~= "table" then return false end
                        return true
                end
                if is_wml_table and introduces_subtag then
                        if not check_subtag() then
                                wml_table_error = string.format("table introducing subtag at %s is not of the form {\"tag_name\", {}}", indices)
                                is_wml_table = false
                        end
                end

                local index = 1
                for current_key, current_value in pairs(arg_table) do
                        is_filled = true

                        local current_key_type = type(current_key)
                        local current_key_to_string = tostring(current_key)
                        local current_type = type(current_value)
                        local function no_wml_table(expected, index, type)
                                if not index then index = current_key_to_string end
                                if not type then type = current_type end
                                wml_table_error = string.format("value at %s[%s]: %s expected, got %s", indices, index, expected, type)
                                is_wml_table = false
                        end

                        if current_type == "userdata" then
                                local  invalidate_wml_table
                                current_value, invalidate_wml_table = dump_userdata(current_value)
                                current_type = type(current_value)
                                if is_wml_table and invalidate_wml_table then
                                        wml_table_error = string.format("userdata at %s[%s]", indices, current_key_to_string)
                                        is_wml_table = false
                                end
                        end

                        if is_wml_table and not introduces_subtag then
                                if current_key_type == "string" and (current_type == "table" or current_type == "function" or current_type == "thread") then
                                        no_wml_table("nil, boolean, number or string")
                                elseif current_key_type == "number" then
                                        if current_type ~= "table" then
                                                no_wml_table("table")
                                        elseif current_key ~= index then
                                                no_wml_table("value", tostring(index), "nil or fields traversed out-of-order")
                                        end
                                        index = index + 1
                                end
                        end

                        local length = 9
                        local left_bracket, right_bracket = "[", "]"
                        if current_key_type == "string" then
                                left_bracket, right_bracket = "", ""; length = length - 2
                        end
                        if current_type == "table" then
                                result = string.format("%s%s%s%s%s = {\n", result, indent, left_bracket, current_key_to_string, right_bracket)
                                table_to_string(current_value, string.format("%s%s%s", base_indent, indent, string.rep(" ", string.len(current_key_to_string) + length)),
                                        not introduces_subtag, string.format("%s[%s]", indices, current_key_to_string))
                                result = string.format("%s%s%s},\n", result, indent, string.rep(" ", string.len(current_key_to_string) + length))
                        else
                                local quote = ""; if current_type == "string" then quote = "\"" end
                                result = string.format("%s%s%s%s%s = %s%s%s,\n", result, indent, left_bracket, current_key_to_string, right_bracket, quote, tostring(current_value), quote)
                        end
                end
                if is_filled then result = string.sub(result, 1, string.len(result) - 2) .. "\n" end
        end

        local engine_is_wml_table
        if wesnoth then
                engine_is_wml_table = pcall(wesnoth.set_variable, "LUA_debug_msg", lua_var); wesnoth.set_variable("LUA_debug_msg")
        end

        local var_type, var_value = type(lua_var), tostring(lua_var)
        is_wml_table = var_type == "table"
        local invalidate_wml_table
        local metatable = getmetatable(lua_var)
        if var_type == "userdata" then
                lua_var, invalidate_wml_table= dump_userdata(lua_var)
                is_wml_table = not invalidate_wml_table
        end
        local new_var_type = type(lua_var)

        local format_string = "%s is of type %s, value %s"
        local format_string_length = format_string .. ", length %u"
        local format_string_length_newline = format_string_length .. ":\n%s"

        if new_var_type == "table" then
                local var_length = #lua_var
                result = "{\n"
                table_to_string(lua_var, base_indent, false, "")
                result = result .. "}"

                if is_wml_table then
                        result = string.format(format_string_length_newline, name, "WML table", var_value, var_length, result)
                elseif wml_table_error then
                        result = string.format(format_string_length .. ", but no WML table: %s:\n%s", name, "table", var_value, var_length, wml_table_error, result)
                else
                        result = string.format(format_string_length_newline, name, var_type, var_value, var_length, result)
                end
        elseif new_var_type == "string" then
                result = string.format(format_string_length, name, var_type, var_value, #lua_var)
        else
                result = string.format(format_string, name, var_type, var_value)
        end

        if metatable then result = string.format("%s\nwith a metatable:\n", result) end

        if wesnoth and is_wml_table ~= engine_is_wml_table  and (var_type == "table" or var_type == "userdata" or var_type == "function" or var_type == "thread") then
                result = string.format("warning: WML table inconsistently predicted, script says %s , engine %s \n%s", tostring(is_wml_table), tostring(engine_is_wml_table), result)
        end

        if clear and wesnoth then wesnoth.clear_messages() end
        if not only_return then
                print(result)
                if wesnoth and ((not clear) or (clear and (clear ~= -1))) then wesnoth.message("dbms", result) end;
        end
        local continue = true
        if onscreen and wesnoth and not only_return then
                local wrap = true
                if wrap then wesnoth.wml_actions.message({ speaker = "narrator", image = "wesnoth-icon.png", message = result })
                --else
                --        local wlp_utils = wesnoth.require "~add-ons/Wesnoth_Lua_Pack/wlp_utils.lua"
                --        local result = wlp_utils.message({ caption = "dbms", message = result })
                --        if result == -2 then continue = false end
                end
        end
        if metatable and continue then
                result = result .. debug_utils.dbms(metatable, false, string.format("The metatable %s", tostring(metatable)), onscreen, wrap, only_return)
        end
        return result
end


------------------------------------------------------------------------------------------------------------------------

-- a short debug message which outputs type, value and length if the given variable is a table
function debug_utils.sdbms(args)
        local type = type(args)
        local sargs = tostring(args)
        local message = string.format("TYPE: %s; VALUE: %s", type, sargs)
        if type == "table" then
                message = string.format("%s; LENGTH: %s", message, tostring(#args))
        end
        wesnoth.message(message); print(message)
end

------------------------------------------------------------------------------------------------------------------------

--~ sets an [inspect] tag (breakpoint) into wml on-the-fly (without scenario reload)
--~ usage:
--~             [set_menu_item]
--~                     [show_if]
--~                     [/show_if]
--~                     id=inspect
--~                     # wmllint: local spelling [inspect]
--~                     description=_"set an [inspect] tag"
--~                     [command]
--~                             [lua]
--~                                     code=<< wesnoth.dofile("~add-ons/Wesnoth_Lua_Pack/debug_utils.lua").set_inspect() >>
--~                             [/lua]
--~                     [/command]
--~             [/set_menu_item]

--~ conditions must be of the form
--~ $turn_number == 2 and false == $var
--~ (after variable substitution, being treated as the value of a wml action tag key, is must evaluate to a correct lua conditional expression)

function debug_utils.set_inspect()
        wesnoth.wml_actions.message({ speaker = "narrator", message = "Before which action tag ? Type the name. Example: \"unstore_unit\" (without the \"\")", image = "wesnoth-icon.png",
        {"text_input", { variable = "LUA_inspect_tag_name", text = "message" }},
        })
        local tag = tostring(wesnoth.get_variable("LUA_inspect_tag_name"))
        wesnoth.set_variable("LUA_inspect_tag_name")
        if not wesnoth.wml_actions[tag] then error(string.format("not a valid tag name: %s", tag)) end

        wesnoth.wml_actions.message({ speaker = "narrator", message = "Condition ? Example: \"$|turn_number == 2 and $|side_number == 3\" (without the \"\"):", image = "wesnoth-icon.png",
        {"text_input", { variable = "LUA_inspect_condition", text = "true" }},
        })
        local condition_userdata = wesnoth.tovconfig({ condition_string = wesnoth.get_variable("LUA_inspect_condition") })
        wesnoth.set_variable("LUA_inspect_condition")

        local function show_inspect()
                local condition_string = tostring((condition_userdata).condition_string)
                local condition_function_string = string.format("return %s", condition_string)
                local condition_function, error_message
                if wesnoth.compare_versions and wesnoth.compare_versions(string.sub(_VERSION, 5), ">=", "5.2") then
                        condition_function, error_message = load(condition_function_string)
                else
                        condition_function, error_message = loadstring(condition_function_string)
                end
                if not condition_function then error(string.format("error loading the condition: %s", error_message)) end
                return condition_function()
        end

        local call_num = 1
        local old_handler = wesnoth.wml_actions[tag]
        if not global_action_handler_storage then global_action_handler_storage = {} end
        if not global_action_handler_storage[tag] then global_action_handler_storage[tag] = old_handler end
        local function new_handler(cfg)
                if show_inspect() then
                        wesnoth.wml_actions.inspect({ name = string.format("invocation number: %u", call_num) })
                        call_num = call_num + 1
                end
                old_handler(cfg)
        end
        wesnoth.wml_actions[tag] = new_handler
end

--~ usage:
--~             [set_menu_item]
--~                     [show_if]
--~                     [/show_if]
--~                     id=remove_inspect
--~                     description=_"remove all [inspect] tags"
--~                     [command]
--~                             [lua]
--~                                     code=<< wesnoth.dofile("~add-ons/Wesnoth_Lua_Pack/debug_utils.lua").remove_inspect() >>
--~                             [/lua]
--~                     [/command]
--~             [/set_menu_item]
function debug_utils.remove_inspect()
        if not global_action_handler_storage then return end
        local settings = { speaker = "narrator", image = "wesnoth-icon.png", message = "Remove all breakpoints from before which action tag ?" }
        local options = {}
        local a_tag_is_left = false
        for k, v in pairs(global_action_handler_storage) do
                table.insert(options, k)
                a_tag_is_left = true
        end
        if not a_tag_is_left then return end
        local choice = helper.get_user_choice(settings, options)
        local tag = options[choice]
        wesnoth.wml_actions[tag] = global_action_handler_storage[tag]
        global_action_handler_storage[tag] = nil
end

------------------------------------------------------------------------------------------------------------------------

local function log_function_body(message, logger)
        assert(type(message) == "string")
        wesnoth.wml_actions.wml_message({ logger = logger, message = message })
        if wesnoth.game_config.debug then wesnoth.message(message) end
end

function debug_utils.dbg(message)
        log_function_body(message, "debug")
end

function debug_utils.wrn(message)
        log_function_body(message, "warning")
end

------------------------------------------------------------------------------------------------------------------------

return debug_utils
