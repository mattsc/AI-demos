return {
    init = function(ai)

        local ml_ai_futures = wesnoth.require('~add-ons/AI-demos/lua/ml_ai_futures.lua').init(ai)

        local function findpattern(text, pattern, start)
          return string.sub(text, string.find(text, pattern, start))
        end

        local function a_human_is_in_the_game()
            local sides = wesnoth.sides
            for _, side in ipairs(sides) do
                if side.controller ~= "ai" and side.controller ~= "null" then
                    ai.ml_debug_message("A human is in the game, so we are not defining events due to the bug reported at https://gna.org/bugs/?20280")
                    return true
                end
            end
            return false
        end

        if (ml_ai_events_already_run == nil and not a_human_is_in_the_game()) then
            ml_ai_events_already_run = true
            local game_events = wesnoth.game_events
            local old_on_event = game_events.on_event
            function game_events.on_event(name)
                -- ai.ml_debug_message("EVENT: " .. name)
                if name == "attack" then
                    ai.ml_debug_message("ATTACK Began!")
                    ml_ai_futures:attack_begin_recorder()
                end
                if name == "attack_end" then
                    ai.ml_debug_message("ATTACK ENDED!")
                    ml_ai_futures:attack_end_recorder()
                end

                if string.find(name,"turn") then
                    ml_ai_futures:report_poisoned_slowed_units("poisoned")
                    ml_ai_futures:report_poisoned_slowed_units("slowed")
                end
                if string.find(name,"^side %d+ turn$") then
                    -- Note that we do the crediting before the poison/heal takes effect
                    -- ml_ai:credit_poison_damage_to_poisoner_and_healer_for_gold_yield()
                    ml_ai_futures:credit_poison_and_healing_damage()
                end

                if string.find(name,"^side %d+ turn refresh") then
                    ml_ai_futures:sync_unit_variables_with_statuses()
                end

                if string.find(name,"^turn %d+$") then
                    ml_ai_futures:turn_reporter()
                end
                if name == "die" then
                    ml_ai_futures:die_reporter() -- Reports unit hit points after every death and at end of game
                end
                if name=="capture" then
                    ml_ai_futures:write_village_capture_message()  -- Writes out which unit captured the village
                end
                if name=="prerecruit" then
                    ml_ai_futures:prerecruit_reporter() -- Reports a snapshot before every recruit event
                end
                if name=="recruit" then
                    ml_ai_futures:recruit_reporter() -- Reports the unit recruited
                end
                if name=="post_advance" then
                    ml_ai_futures:post_advance_reporter() -- Reports a snapshot after every unit advancement
                end
                if old_on_event ~= nil then old_on_event(name) end
            end
        end
        ai.ml_debug_message("Just finished initializing ml_ai_events")
    end --init
}

