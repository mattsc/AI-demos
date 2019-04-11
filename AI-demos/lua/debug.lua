local FGM = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_map.lua"

-- Note: Assigning this table is slow compared to accessing values in it. It is
-- thus done outside the functions below, so that it is not done over and over
-- for each function call.
local debug_cfg = {
    eval = false,
    exec = true,

    show_behavior = 1,

    analysis = false,
    analysis_leader_distance_map = false,
    analysis_enemy_initial_reach_maps = false,
    analysis_influence_maps = false,
    analysis_unit_influence_maps = false,
    analysis_zone_influence_maps = false,

    attack_print_output = false,
    attack_combos = false,
    attack_best_combo = false,

    hold_zone_map = false,
    hold_influence_map = false,
    hold_between_map = false,
    hold_prerating_maps = false,
    hold_here_map = false,
    hold_rating_maps = false,
    hold_protect_rating_maps = false,
    hold_best_units_hexes = false,
    hold_combo_base_rating = false,
    hold_combo_formation_rating = false,
    hold_combo_counter_rating = false,
    hold_best_combo = false,

    advance_map = false,
    advance_behind_enemy_map = false,
    advance_support_map = false,
    advance_unit_support_maps = false,
    advance_insufficient_support_maps = false,
    advance_unit_rating = false,

    reset_turn = false
}


local debug_utils = {}

function debug_utils.show_debug(debug_type)
    return debug_cfg[debug_type]
end

function debug_utils.print_ts(...)
    -- Print arguments preceded by a time stamp in seconds
    -- Also return that time stamp

    local ts = wesnoth.get_time_stamp() / 1000.

    local arg = { ... }
    arg[#arg+1] = string.format('[ t = %.3f ]', ts)

    std_print(table.unpack(arg))

    return ts
end

function debug_utils.print_ts_delta(start_time, ...)
    -- @start_time: time stamp in seconds as returned by wesnoth.get_time_stamp / 1000.

    -- Same as ai_helper.print_ts(), but also adds time elapsed since
    -- the time given in the first argument (in seconds)
    -- Returns time stamp as well as time elapsed

    local ts = wesnoth.get_time_stamp() / 1000.
    local delta = ts - start_time

    local arg = { ... }
    arg[#arg+1] = string.format('[ t = %.3f, dt = %.3f ]', ts, delta)

    std_print(table.unpack(arg))

    return ts, delta
end

function debug_utils.print_debug(debug_type, ...)
    if debug_utils.show_debug(debug_type) then std_print(...) end
end

function debug_utils.print_debug_time(debug_type, start_time, ...)
    if debug_utils.show_debug(debug_type) then
        if start_time then
            debug_utils.print_ts_delta(start_time, ...)
        else
            std_print(...)
        end
    end
end

function debug_utils.clear_labels()
    -- Clear all labels on the map
    local width, height = wesnoth.get_map_size()
    for x = 1,width do
        for y = 1,height do
            wesnoth.wml_actions.label { x = x, y = y, text = "" }
        end
    end
end

function debug_utils.put_fgumap_labels(map, key, cfg)
    -- Take @map (in the format as defined in fred_gamestate_utils (fgu) and put
    -- labels containing the values of @key onto the map.
    -- Print 'nan' if element exists but is not a number or a boolean.
    -- Print 'nil' if element is just that
    -- @cfg: table with optional parameters:
    --   - show_coords: (boolean) use hex coordinates as labels instead of value
    --   - factor=1: (number) if value is a number, multiply by this factor

    local factor = (cfg and cfg.factor) or 1

    debug_utils.clear_labels()

    local min, max = 9e99, -9e99
    for x,y,data in FGM.iter(map) do
        local out = data[key]

        if (type(out) == 'number') then
            if (out > max) then max = out end
            if (out < min) then min = out end
        end
    end

    if (min > max) then
        min, max = 0, 1
    end

    if (min == max) then
        min = max - 1
    end

    min = min - (max - min) * 0.2

    for x,y,data in FGM.iter(map) do
        local out = data[key]
        local red_fac, green_fac, blue_fac = 1, 1, 1

        if cfg and cfg.show_coords then
            out = x .. ',' .. y
        end

        if (type(out) ~= 'string') then
            if (type(out) == 'boolean') then
                if out then
                    out = 'true'
                else
                    out = 'false'
                    red_fac, green_fac, blue_fac = 1, 0, 0
                end
            else
                if out then
                    out = tonumber(out) or 'nan'
                else
                    out = 'nil'
                end
            end
        end

        if (type(out) == 'number') then
            color_fac = (out - min) / (max - min)
            if (color_fac < 0.5) then
                red_fac = color_fac + 0.5
                green_fac = 0
                blue_fac = 0
            elseif (color_fac < 0.75) then
                red_fac = 1
                green_fac = (color_fac - 0.5) * 4
                blue_fac = green_fac / 2
            else
                red_fac = 1
                green_fac = 1
                blue_fac = (color_fac - 0.75) * 4
            end

            out = out * factor
        end

        wesnoth.wml_actions.label {
            x = x, y = y,
            text = out,
            color = 255 * red_fac .. ',' .. 255 * green_fac .. ',' .. 255 * blue_fac
        }
    end
end

function debug_utils.show_fgumap_with_message(map, key, text, cfg)
    -- @cfg: optional table with display configuration parameters:
    --   @x,@y: coordinates to scroll to; if omitted, no scrolling is done
    --   @id: speaker id; if omitted, a narrator message is shown
    --   @no_halo: if set, do not display a halo in the speaker unit location
    -- Thus, it's possible to pass a unit as @cfg

    debug_utils.put_fgumap_labels(map, key)
    if cfg and cfg.x and cfg.y then
        wesnoth.scroll_to_tile(cfg.x,cfg.y)
        if (not cfg.no_halo) then
            wesnoth.wml_actions.item { x = cfg.x, y = cfg.y, halo = "halo/teleport-8.png" }
        end
    end
    wesnoth.wml_actions.redraw {}
    local id = cfg and cfg.id
    if id then
        wesnoth.wml_actions.message { speaker = 'narrator', message = text .. ': ' .. id }
    else
        wesnoth.wml_actions.message { speaker = 'narrator', message = text }
    end
    if cfg and cfg.x and cfg.y and (not cfg.no_halo) then
        wesnoth.wml_actions.remove_item { x = cfg.x, y = cfg.y, image = "halo/teleport-8.png" }
    end
    debug_utils.clear_labels()
    wesnoth.wml_actions.redraw {}
end


-- The remainder is almost literally stolen from Wesnoth Lua Pack
-- The only difference is that I changed the default options of dbms

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
                std_print(result)
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

return debug_utils
