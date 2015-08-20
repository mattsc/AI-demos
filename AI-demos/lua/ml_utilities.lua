--.
-- Utilities for ML AI
--
--

local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"

-- From http://lua-users.org/wiki/CopyTable
function deepcopy(object)
    local lookup_table = {}
    local function _copy(object)
        if type(object) ~= "table" then
            return object
        elseif lookup_table[object] then
            return lookup_table[object]
        end
        local new_table = {}
        lookup_table[object] = new_table
        for index, value in pairs(object) do
            new_table[_copy(index)] = _copy(value)
        end
        return setmetatable(new_table, getmetatable(object))
    end
    return _copy(object)
end


-- From http://lua-users.org/wiki/TableUtils
function table.val_to_str ( v )
    if "string" == type( v ) then
        v = string.gsub( v, "\n", "\\n" )
        if string.match( string.gsub(v,"[^'\"]",""), '^"+$' ) then
            return "'" .. v .. "'"
        end
        return '"' .. string.gsub(v,'"', '\\"' ) .. '"'
    else
        return "table" == type( v ) and table.tostring( v ) or
                tostring( v )
    end
end

function table.key_to_str ( k )
    if "string" == type( k ) and string.match( k, "^[_%a][_%a%d]*$" ) then
        return k
    else
        return "[" .. table.val_to_str( k ) .. "]"
    end
end

function table.tostring( tbl )
    local result, done = {}, {}
    for k, v in ipairs( tbl ) do
        table.insert( result, table.val_to_str( v ) )
        done[ k ] = true
    end
    for k, v in pairs( tbl ) do
        if not done[ k ] then
            table.insert( result,
                table.key_to_str( k ) .. "=" .. table.val_to_str( v ) )
        end
    end
    return "{" .. table.concat( result, "," ) .. "}"
end

--From http://lua-users.org/wiki/SplitJoin
function string:split(sep)
    local sep, fields = sep or ":", {}
    local pattern = string.format("([^%s]+)", sep)
    self:gsub(pattern, function(c) fields[#fields+1] = c end)
    return fields
end

--From http://lua-users.org/wiki/StringRecipes
function string.starts(String,Start)
    return string.sub(String,1,string.len(Start))==Start
end


function pairsByKeys (t, f)
    local a = {}
    for n in pairs(t) do table.insert(a, n) end
    table.sort(a, f)
    local i = 0      -- iterator variable
    local iter = function ()   -- iterator function
        i = i + 1
        if a[i] == nil then return nil
        else return a[i], t[a[i]]
        end
    end
    return iter
end

function zero_or_val(value)
    -- Return zero if the value is nil.  Otherwise return the value
    return value and value or 0
end

function return_merged_tables(t1,t2)
    local combined = {}
    for k,v in pairs(t1) do combined[k] = v end
    for k,v in pairs(t2) do combined[k] = v end
    return combined
end

local function sortpairs(t, lt)
    local u = { }
    for k, v in pairs(t) do table.insert(u, { key = k, value = v }) end
    table.sort(u, lt)
    return u
end


function output_feature_dictionary(arg)
    local feature_dictionary = arg.dict
    local debug = arg.debug or false
    local label = arg.label or "PRERECRUIT:, "
    local out = ""
    local g = sortpairs(feature_dictionary,
        function(A,B) if A.key == "id" then return true elseif B.key == "id" then return false else return A.key < B.key end  end)
    for _, i in ipairs(g) do
        if type(i.value) == "number" and math.floor(i.value) ~= i.value then
            out = out .. string.format("%s:%.3f,",i.key,i.value)
        else
            if string.find(i.value,",") then
                out = out .. string.format("%s:'%s', ",i.key,i.value)
            else
                out = out .. i.key .. ":" .. i.value  .. ", "
            end
        end
    end
    if debug then
        arg.ai.ml_debug_message(label .. out)
    else
        arg.ai.ml_info_message(label .. out)
    end
end

function get_sides_with_leaders()
    local sides = wesnoth.sides
    local sides_with_leaders = {}
    for _, side_info in ipairs(sides) do
        local leaders_on_this_side = #AH.get_live_units{canrecruit=true, side = side_info.side }
        if leaders_on_this_side >= 1 then
            table.insert(sides_with_leaders,side_info.side)
        end
    end
    return sides_with_leaders
end
