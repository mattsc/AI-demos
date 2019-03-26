local H = wesnoth.require "helper"

local fred_gamestate_map = {}

function fred_gamestate_map.get_value(map, x, y, key)
    if (not key) then error("Required parameter 'key' is missing in call to fred_gamestate_map.get_value()") end
    return (map[x] and map[x][y] and map[x][y][key])
end

function fred_gamestate_map.set_value(map, x, y, key, value)
    if (not map[x]) then map[x] = {} end
    if (not map[x][y]) then map[x][y] = {} end
    map[x][y][key] = value
end

function fred_gamestate_map.add(map, x, y, key, value)
    local old_value = fred_gamestate_map.get_value(map, x, y, key) or 0
    fred_gamestate_map.set_value(map, x, y, key, old_value + value)
end

function fred_gamestate_map.iter(map)
    function each_hex(state)
        while state.x ~= nil do
            local child = map[state.x]
            state.y = next(child, state.y)
            if state.y == nil then
                state.x = next(map, state.x)
            else
                return state.x, state.y, child[state.y]
            end
        end
    end

    return each_hex, { x = next(map) }
end

function fred_gamestate_map.normalize(map, key)
    local mx
    for _,_,data in fred_gamestate_map.iter(map) do
        if (not mx) or (data[key] > mx) then
            mx = data[key]
        end
    end
    for _,_,data in fred_gamestate_map.iter(map) do
        data[key] = data[key] / mx
    end
end

function fred_gamestate_map.blur(map, key)
    for x,y,data in fred_gamestate_map.iter(map) do
        local blurred_data = data[key]
        if blurred_data then
            local count = 1
            local adj_weight = 0.5
            for xa,ya in H.adjacent_tiles(x, y) do
                local value = fred_gamestate_map.get_value(map, xa, ya, key)
                if value then
                    blurred_data = blurred_data + value * adj_weight
                   count = count + adj_weight
                end
            end
            fred_gamestate_map.set_value(map, x, y, 'blurred_' .. key, blurred_data / count)
        end
    end
end

return fred_gamestate_map
