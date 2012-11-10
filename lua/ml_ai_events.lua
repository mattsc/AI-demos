return {
    init = function(ai)

        local ml_ai = wesnoth.require('~add-ons/AI-demos/lua/ml_ai_features.lua').init(ai)

        local function findpattern(text, pattern, start)
          return string.sub(text, string.find(text, pattern, start))
        end


        if (ml_ai_events_already_run == nil) then
            ml_ai_events_already_run = true
            local game_events = wesnoth.game_events
            local old_on_event = game_events.on_event
            function game_events.on_event(name)
                -- ai.ml_debug_message("EVENT: " .. name)
                if name == "attack" then
                    ai.ml_debug_message("ATTACK Began!")
                    ml_ai:attack_begin_recorder()
                end
                if name == "attack_end" then
                    ai.ml_debug_message("ATTACK ENDED!")
                    ml_ai:attack_end_recorder()
                end

                if string.find(name,"turn") then
                    ml_ai:report_poisoned_slowed_units("poisoned")
                    ml_ai:report_poisoned_slowed_units("slowed")
                end
                if string.find(name,"^side %d+ turn$") then
                    -- Note that we do the crediting before the poison/heal takes effect
                    -- ml_ai:credit_poison_damage_to_poisoner_and_healer_for_gold_yield()
                    ml_ai:credit_poison_and_healing_damage()
                end

                if string.find(name,"^side %d+ turn refresh") then
                    ml_ai:sync_unit_variables_with_statuses()
                end

                if string.find(name,"^turn %d+$") then
                    ml_ai:turn_reporter()
                end
                if name == "die" then
                    ml_ai:die_reporter() -- Reports unit hit points after every death and at end of game
                end
                if name=="capture" then
                    ml_ai:write_village_capture_message()  -- Writes out which unit captured the village
                end
                if name=="prerecruit" then
                    ml_ai:prerecruit_reporter() -- Reports a snapshot before every recruit event
                end
                if name=="recruit" then
                    ml_ai:recruit_reporter() -- Reports the unit recruited
                end
                if name=="post_advance" then
                    ml_ai:post_advance_reporter() -- Reports a snapshot after every unit advancement
                end
                if old_on_event ~= nil then old_on_event(name) end
            end
        end
        ai.ml_debug_message("Just finished initializing ml_ai_events")
    end --init
}

