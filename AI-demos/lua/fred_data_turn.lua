local FGM = wesnoth.require "~/add-ons/AI-demos/lua/fred_gamestate_map.lua"
local DBG = wesnoth.dofile "~/add-ons/AI-demos/lua/debug.lua"

local fred_data_turn = {}

function fred_data_turn.set_turn_data(fred_data)
    -- The if statement below is so that debugging works when starting the evaluation in the
    -- middle of the turn.  In normal gameplay, we can just use the existing enemy reach maps,
    -- so that we do not have to double-calculate them.
    local move_data = fred_data.move_data
    local enemy_initial_reach_maps = {}
    if (not next(move_data.my_units_noMP)) then
        --std_print('Using existing enemy move map')
        for enemy_id,_ in pairs(move_data.enemies) do
            enemy_initial_reach_maps[enemy_id] = {}
            for x,y,data in FGM.iter(move_data.reach_maps[enemy_id]) do
                FGM.set_value(enemy_initial_reach_maps[enemy_id], x, y, 'moves_left', data.moves_left)
            end
        end
    else
        --std_print('Need to create new enemy move map')
        for enemy_id,_ in pairs(move_data.enemies) do
            enemy_initial_reach_maps[enemy_id] = {}

            local old_moves = move_data.unit_copies[enemy_id].moves
            move_data.unit_copies[enemy_id].moves = move_data.unit_copies[enemy_id].max_moves
            local reach = wesnoth.find_reach(move_data.unit_copies[enemy_id], { ignore_units = true })
            move_data.unit_copies[enemy_id].moves = old_moves

            for _,loc in ipairs(reach) do
                FGM.set_value(enemy_initial_reach_maps[enemy_id], loc[1], loc[2], 'moves_left', loc[3])
            end
        end
    end

    if DBG.show_debug('ops_enemy_initial_reach_maps') then
        for enemy_id,_ in pairs(move_data.enemies) do
            DBG.show_fgm_with_message(enemy_initial_reach_maps[enemy_id], 'moves_left', 'enemy_initial_reach_maps', move_data.unit_copies[enemy_id])
        end
    end

    fred_data.turn_data = {
        turn_number = wesnoth.current.turn,
        side_number = wesnoth.current.side,
        enemy_initial_reach_maps = enemy_initial_reach_maps
    }
end

function fred_data_turn.update_turn_data(fred_data)
    -- In case an enemy has died
    for enemy_id,eirm in pairs(fred_data.turn_data.enemy_initial_reach_maps) do
        if (not fred_data.move_data.enemies[enemy_id]) then
            fred_data.turn_data.enemy_initial_reach_maps[enemy_id] = nil
        end
    end
end

return fred_data_turn
