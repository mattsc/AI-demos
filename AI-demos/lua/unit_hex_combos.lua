local H = wesnoth.require "lua/helper.lua"
local AH = wesnoth.require "ai/lua/ai_helper.lua"

local function get_unit_hex_combos(dst_src)
    -- This is a function which recursively finds all combinations of distributing
    -- units on hexes. The number of units and hexes does not have to be the same.
    -- @dst_src lists all units which can reach each hex in format:
    --  [1] = {
    --      [1] = { src = 17028 },
    --      [2] = { src = 16027 },
    --      [3] = { src = 15027 },
    --      dst = 18025
    --  },
    --  [2] = {
    --      [1] = { src = 17028 },
    --      [2] = { src = 16027 },
    --      dst = 20026
    --  },

    local all_combos, combo = {}, {}
    local num_hexes = #dst_src
    local hex = 0

    -- This is the recursive function adding units to each hex
    -- It is defined here so that we can use the variables above by closure
    local function add_combos()
        hex = hex + 1

        for _,ds in ipairs(dst_src[hex]) do
            if (not combo[ds.src]) then  -- If that unit has not been used yet, add it
                combo[ds.src] = dst_src[hex].dst

                if (hex < num_hexes) then
                    add_combos()
                else
                    local new_combo = {}
                    for k,v in pairs(combo) do new_combo[k] = v end
                    table.insert(all_combos, new_combo)
                end

                -- Remove this element from the table again
                combo[ds.src] = nil
            end
        end

        -- We need to call this once more, to account for the "no unit on this hex" case
        -- Yes, this is a code duplication (done so for simplicity and speed reasons)
        if (hex < num_hexes) then
            add_combos()
        else
            local new_combo = {}
            for k,v in pairs(combo) do new_combo[k] = v end
            table.insert(all_combos, new_combo)
        end

        hex = hex - 1
    end

    add_combos()

    -- The last combo is always the empty combo -> remove it
    all_combos[#all_combos] = nil

    return all_combos
end

local function make_dst_src(units, hexes)
    -- This functions determines which @units can reach which @hexes. It returns
    -- and array of the form usable by get_unit_hex_combos(dst_src) [see above]
    --
    -- We could be using location sets here also, but I prefer the 1000-based
    -- indices because they are easily human-readable. I don't think that the
    -- performance hit is noticeable.

    local dst_src_map = {}
    for _,unit in ipairs(units) do
        -- If the AI turns out to be slow, this could be pulled out to a higher
        -- level, to avoid calling it for each combination of hexes:
        local reach = wesnoth.find_reach(unit)

        for _,hex in ipairs(hexes) do
            for _,r in ipairs(reach) do
                if (r[1] == hex[1]) and (r[2] == hex[2]) then
                    --print(unit.id .. ' can reach ' .. r[1] .. ',' .. r[2])

                    dst = hex[1] * 1000 + hex[2]

                    if (not dst_src_map[dst]) then
                        dst_src_map[dst] = {
                            dst = dst,
                            { src = unit.x * 1000 + unit.y }
                        }
                    else
                        table.insert(dst_src_map[dst], { src = unit.x * 1000 + unit.y })
                    end

                    break
                end
            end
        end
    end

    -- Because of the way how the recursive function above works, we want this
    -- to be an array, not a map with dsts as keys
    local dst_src = {}
    for _,dst in pairs(dst_src_map) do
        table.insert(dst_src, dst)
    end

    return dst_src
end

local function get_best_combo(combos, min_units, cfg)
    -- TODO: This currently uses a specific rating function written for the
    -- Ashen Hearts campaign. Generalize to take rating function as an argument.
    --
    -- Rate a combination of units on goal hexes (for one row only)
    -- @min_units: minimum number of units needed to count as valid combo

    local hp_map = {}  -- Setting up hitpoint map for speed reasons
    local max_rating, best_combo = -9e99
    for _,combo in ipairs(combos) do
        local n_hexes = 0
        for dst,src in pairs(combo) do
            n_hexes = n_hexes + 1
        end

        if (n_hexes >= min_units) then
            local rating = 0

            -- Find the hexes at the ends of the line; these get an additional
            -- bonus for units with high HP
            local end_hexes = {}
            local max_dst, min_dst = -1, 9e99
            for src,dst in pairs(combo) do
                -- Since dst is 1000*x+y, and we want to sort by x, we can simply
                -- compare the dst values directly. It will even work for vertical
                -- lines. Only requirement is that the line is straight then.
                if (dst > max_dst) then max_dst = dst end
                if (dst < min_dst) then min_dst = dst end
            end

            for src,dst in pairs(combo) do
                local dst_x, dst_y = math.floor(dst / 1000), dst % 1000

                -- Need to ensure a positive rating for each unit, so that combo
                -- with most units is chosen, even if min_units < #hexes
                rating = rating + 1000

                -- Rating is distance from goal hex
                -- and distance from x=goal_x line
                rating = rating - H.distance_between(dst_x, dst_y, goal_hex[1], goal_hex[2])
                rating = rating - math.abs(dst_x - cfg.goal_x)

                -- Also use HP rating; use strongest available units
                if (not hp_map[src]) then
                    local src_x, src_y = math.floor(src / 1000), src % 1000
                    local unit = wesnoth.get_unit(src_x, src_y)
                    hp_map[src] = unit.hitpoints
                end

                rating = rating + hp_map[src] / 100.

                -- Additional hp bonus for the edge hexes
                if (dst == min_dst) or (dst == max_dst) then
                    rating = rating + hp_map[src] / 100.
                end
            end
            --print('Combo #' .. _ .. ': ', rating)

            if (rating > max_rating) then
                max_rating = rating
                best_combo = combo
            end
        end
    end

    if best_combo then
        return best_combo, max_rating
    end
end
