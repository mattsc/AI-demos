return {
    init = function(ai)
        ai.ml_debug_message("hello world, at beginning of ml_ai_features right now")
        H = wesnoth.require('lua/helper.lua')
        wesnoth.require("~add-ons/AI-demos/lua/ml_utilities.lua")
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        T = H.set_wml_tag_metatable{}
        U = H.set_wml_tag_metatable{}

        ml_ai = {}
        no_more_recruiting_for_turn = {0,0 }
        local dead_units = {}
        local last_attacker = nil
        local last_defender = nil
        ai.ml_debug_message("hello world, finished initializing ml_ai_features right now")

        function ml_ai:cures_self_of_poison(unit)
            -- Does this unit have the ability to cure itself of poison?
            local abilities = H.get_child(wesnoth.unit_types[unit.type].__cfg, "abilities")
            if abilities then
                local regenerate_dict = H.get_child(abilities,"regenerate")
                if regenerate_dict then
                    if regenerate_dict.poison == "cured" and regenerate_dict.affect_self == true then
                        ai.ml_debug_message("The unit " .. unit.id .. " can cure itself!")
                        return true
                    end
                else
                    return false
                end
            else
                return false
            end
        end

        function ml_ai:get_ability_dict(unit,ability)
            local abilities = H.get_child(wesnoth.unit_types[unit.type].__cfg, "abilities")
            if abilities then
                return H.get_child(abilities,ability)
            else
                return nil
            end
        end

        function ml_ai:get_ability_dicts(unit,ability)
            local abilities = H.get_child(wesnoth.unit_types[unit.type].__cfg, "abilities")
            if abilities then
                -- print(table.tostring(abilities))
                local retval = {}
                for _,j in ipairs(abilities) do
                    if j[1] == "heals" then
                        table.insert(retval,j)
                    end
                end
                if #retval > 0 then
                    return retval
                else
                    return nil
                end
            else
                return nil
            end
        end

        local function print_unit_type_ipairs(unit)
            -- local abilities = H.get_child(unit.__cfg, "abilities")
            for i, dict in ipairs(wesnoth.unit_types[unit.type].__cfg) do
                -- if  dict.abilities then
                    -- for _,ability in
                print(i,table.tostring(dict))
                -- if ability.id == id then return true end
            end
        end

        local function has_ability_by_id_via_type(unit, id)
            local abilities = H.get_child(unit.__cfg, "abilities")
            for i, ability in ipairs(abilities) do
                if ability[2].id == id then return true end
            end
        end

        -- From http://stackoverflow.com/questions/656199/search-for-an-item-in-a-lua-list
        local function Set (list)
          local set = {}
          for _, l in ipairs(list) do set[l] = true end
          return set
        end

        function ml_ai:sortpairs(t, lt)
          local u = { }
          for k, v in pairs(t) do table.insert(u, { key = k, value = v }) end
          table.sort(u, lt)
          return u
        end

        function ml_ai:get_my_side_and_enemy_side() 
            local my_side = wesnoth.current.side
            local enemy_side = 1
            if my_side == 1 then enemy_side = 2 end
            return my_side, enemy_side
        end


        function ml_ai:write_village_capture_message()
            local ev = wesnoth.current.event_context
            local u = wesnoth.get_units{x=ev.x1, y=ev.y1}[1]
            ai.ml_info_message("VILLAGE CAPTURE (id)," ..  u.id )
            u.variables.future_vc =  u.variables.future_vc and u.variables.future_vc + 1 or 1
        end

        function ml_ai:attack_begin_recorder()
            local ev = wesnoth.current.event_context
            assert(last_attacker == nil and last_defender == nil,string.format("Programming error:  last_attacker and last_defender weren't reset"))
            last_attacker = wesnoth.copy_unit(wesnoth.get_unit(ev.x1, ev.y1))
            last_defender = wesnoth.copy_unit(wesnoth.get_unit(ev.x2, ev.y2))
        end

        function ml_ai:report_poisoned_slowed_units(my_status)
            --Report poisoned or slowed units
            local status_dict = {}
            status_dict[my_status] = true
            local poisoned_units = wesnoth.get_units {
                { "filter_wml", {
                    { "status", status_dict }
                } }
            }

            for _,unit in ipairs(poisoned_units) do
                ai.ml_debug_message(my_status .. " unit: " ..  unit.id .. " " .. my_status ..  " by: " .. unit.variables[my_status .. "_by"]  .. " Hit points: "
                        .. unit.hitpoints)
            end
        end

        local function get_living_or_dead_unit(id)
            local sought_unit = wesnoth.get_units{id=id}[1]
            if not sought_unit then
                sought_unit = dead_units[id]
                ai.ml_debug_message("We just found the dead unit: " .. id)
            end
            assert(sought_unit,string.format("Programming error:  The following unit %s was not found among either the living or the dead",id))
            return sought_unit
        end

        function ml_ai:add_gold_yield(last_defender,defender,attacker)
            local damage_inflicted = last_defender.hitpoints - defender.hitpoints
            local gold_yield_for_attacker = (damage_inflicted / defender.max_hitpoints) * wesnoth.unit_types[defender.type].cost
            ai.ml_debug_message("gold_yield to be added is: " .. gold_yield_for_attacker)
            if  not attacker.variables.future_basic_gold_yield then
                attacker.variables.future_basic_gold_yield = 0
            end
            attacker.variables.future_basic_gold_yield = attacker.variables.future_basic_gold_yield + gold_yield_for_attacker
            if attacker.status.slowed and attacker.variables.slowed_by and (attacker.variables.slowed_by ~= defender.id) then
                local slowing_unit = get_living_or_dead_unit(attacker.variables.slowed_by)
                slowing_unit.variables.future_special_gold_yield =  zero_or_val(slowing_unit.variables.future_special_gold_yield) +
                        gold_yield_for_attacker
                ai.ml_debug_message("The slowing unit: " .. attacker.variables.slowed_by .. " gets credit for " .. gold_yield_for_attacker ..
                        " because it previously slowed the unit.")
            end
        end

        function ml_ai:poison_will_be_cured_or_slowed(poisoned)
            if ml_ai:cures_self_of_poison(poisoned) then
                ai.ml_debug_message(poisoned.id .. " will cure itself of poison!")
                local ability_dict = ml_ai:get_ability_dict(poisoned,"regenerate")
                return ability_dict.value
            elseif  #wesnoth.get_villages({ x = poisoned.x, y = poisoned.y}) == 1  then
                ai.ml_debug_message(poisoned.id .. " is in a village and will be cured of poison")
                return 8 -- TODO:  Is there a variable that tells how much you cure in a village?

            else
                local adjacent_units = AH.get_live_units{  { "filter_adjacent", { x=poisoned.x, y=poisoned.y, is_enemy=false }  } }
                local best_healer, best_heal_amount, best_cured_or_slowed  = nil,0, nil
                for _,u in ipairs(adjacent_units) do
                    local heal_dicts =   ml_ai:get_ability_dicts(u,"heals")
                    if heal_dicts then
                        ai.ml_debug_message(u.id .. " should be healing " .. poisoned.id)
                        local cured_or_slowed, my_heal_value
                        for _, dict in ipairs(heal_dicts) do
                        -- for _,dict in ipairs(heal_dicts) do
                            -- print("Heal dict for unit " .. table.tostring(dict))
                            if dict[2].poison=="cured" or dict[2].poison=="slowed" then
                                if not cured_or_slowed or cured_or_slowed == "slowed" then
                                    cured_or_slowed = dict[2].poison
                                end
                            end
                            if dict[2].value then
                                my_heal_value = dict[2].value
                            end
                        end
                        if cured_or_slowed and my_heal_value and my_heal_value >  best_heal_amount then
                            best_heal_amount =  my_heal_value  -- Will be 4 or 8 with standard units
                            best_healer = u
                            best_cured_or_slowed = cured_or_slowed
                        end
                    end
                end
                if best_healer then
                    ai.ml_debug_message(string.format("The poisoned unit %s had its poison %s by %s", poisoned.id, best_cured_or_slowed, best_healer.id))
                else
                    return false
                end
                return best_heal_amount, best_healer, best_cured_or_slowed
            end
        end

        function ml_ai:credit_poison_damage_to_poisoner_and_healer_for_gold_yield(poisoned)
            local hp_credit = 0
            local poisoner =  get_living_or_dead_unit(poisoned.variables.poisoned_by)
            local heal_amount, healer, cured_or_slowed = ml_ai:poison_will_be_cured_or_slowed(poisoned)
            if heal_amount and heal_amount > 0 then
                --We credit the poisoner for the healing that didn't get done
                hp_credit = math.min(heal_amount,poisoned.max_hitpoints - poisoned.hitpoints)
            else  -- The poison will take effect
                hp_credit = wesnoth.game_config.poison_amount
                hp_credit = math.min(hp_credit,poisoned.hitpoints -1)   --Poisoning can't reduce HP below 1
            end
            local gold_yield = (hp_credit / poisoned.max_hitpoints) *  wesnoth.unit_types[poisoned.type].cost
            poisoner.variables.future_special_gold_yield = zero_or_val(poisoner.variables.future_special_gold_yield) +
                    gold_yield
            ai.ml_debug_message(string.format("The poisoner %s was credited with %.2f and now has %.2f for poisoning %s",
                poisoner.id,gold_yield,poisoner.variables.future_special_gold_yield,poisoned.id))
            if healer then   -- Healing was done by a healer, not by regenerating or a village
                local healer_hp_credit
                if cured_or_slowed == "cured" then
                    --Poison slowers (e.g. an Elvish Shaman) are credited for keeping the poisoned unit from suffering
                    --damage on that turn.  Poison curers are credited with preventing poison damage for the next two turns.
                    --This is debatable, but seems reasonable
                    healer_hp_credit = math.min(2 * wesnoth.game_config.poison_amount,poisoned.hitpoints -1)
                else
                    healer_hp_credit = math.min(wesnoth.game_config.poison_amount,poisoned.hitpoints -1)
                end
                local healer_gold_yield = (healer_hp_credit / poisoned.max_hitpoints) *  wesnoth.unit_types[poisoned.type].cost
                healer.variables.future_special_gold_yield = zero_or_val(healer.variables.future_special_gold_yield) +
                        healer_gold_yield
                ai.ml_debug_message(string.format("The healer %s %s the poison for %s, preventing %d hit points of damage and was credited with %.2f and now has %.2f special_gold_yield",
                    healer.id,cured_or_slowed,poisoned.id,healer_hp_credit,healer_gold_yield,healer.variables.future_special_gold_yield))
            end
        end

        function ml_ai:credit_normal_damage_to_healer_for_gold_yield(injured_unit)
            if ml_ai:get_ability_dict(injured_unit,"regenerate") then
                ai.ml_debug_message(injured_unit.id .. " will heal itself, so doesn't need a healer!")
            elseif  #wesnoth.get_villages({ x = injured_unit.x, y = injured_unit.y}) == 1  then
                ai.ml_debug_message(injured_unit.id .. " is in a village and doesn't need a healer")
            else
                local adjacent_units = AH.get_live_units{  { "filter_adjacent", { x=injured_unit.x, y=injured_unit.y, is_enemy=false }  } }
                local best_healer, best_heal_amount  = nil,0
                for _,u in ipairs(adjacent_units) do
                    local heal_dicts =   ml_ai:get_ability_dicts(u,"heals")
                    if heal_dicts then
                        ai.ml_debug_message(u.id .. " should be healing " .. injured_unit.id)
                        local my_heal_value
                        for _, dict in ipairs(heal_dicts) do
                            if dict[2].value then
                                -- print("it has the value " .. dict[2].value)
                                my_heal_value = dict[2].value
                            end
                        end
                        if my_heal_value >  best_heal_amount then
                            best_heal_amount =  my_heal_value  -- Will be 4 or 8 with standard units
                            best_healer = u      --Pick adjacent unit with highest amount healed
                        end
                    end
                end
                if best_healer then
                    local healer_hp_credit = math.min(best_heal_amount,injured_unit.max_hitpoints - injured_unit.hitpoints)
                    local healer_gold_yield = (healer_hp_credit / injured_unit.max_hitpoints) *  wesnoth.unit_types[injured_unit.type].cost
                    best_healer.variables.future_special_gold_yield = zero_or_val(best_healer.variables.future_special_gold_yield) +
                            healer_gold_yield
                    ai.ml_debug_message(string.format("The healer %s healed the injured unit %s for %d hitpoints for %.2f gold yield",
                         best_healer.id, injured_unit.id, healer_hp_credit, healer_gold_yield))
                end
            end
        end

        function ml_ai:credit_poison_and_healing_damage()
            local units_for_side = AH.get_live_units{side=wesnoth.current.side }
            for _,unit in ipairs(units_for_side) do
                if unit.status.poisoned then
                    ml_ai:credit_poison_damage_to_poisoner_and_healer_for_gold_yield(unit)
                elseif unit.hitpoints < unit.max_hitpoints then
                    ml_ai:credit_normal_damage_to_healer_for_gold_yield(unit)
                end
            end
        end



        function ml_ai:update_poisoned_slowed_by(last_unit_checking_for_poison,unit_checking_for_poison,possible_poisoner,attack_defense,poisoned_slowed)
            if last_unit_checking_for_poison.hitpoints > 0 then -- Unit is alive
                if not last_unit_checking_for_poison.status[poisoned_slowed]  and unit_checking_for_poison.status[poisoned_slowed] == true then
                    unit_checking_for_poison.variables[poisoned_slowed .. "_by"] = possible_poisoner.id
                    ai.ml_debug_message(unit_checking_for_poison.id .. " was just " .. poisoned_slowed .. " by " .. possible_poisoner.id
                            .. attack_defense)
                end
            end
        end

        function ml_ai:sync_unit_variables_with_statuses()
            local statuses = {"poisoned","slowed"}
            for _, j in ipairs(AH.get_live_units{}) do
                for _,status in ipairs(statuses) do
                    if not j.status[status] and j.variables[status] then
                        j.variables[status .. "_by"] = nil
                    end
                end
                --We sync here just to be sure that it gets filled in for units that weren't recruited like Walking Corpses
                j.variables.old_max_experience =  j.max_experience
            end
        end

        function ml_ai:attack_end_recorder()
            local ev = wesnoth.current.event_context
            local attacker = wesnoth.get_units{x=ev.x1, y=ev.y1}[1]
            local defender = wesnoth.get_units{x=ev.x2, y=ev.y2}[1]
            assert(last_attacker and last_defender,string.format("Programming error:  last_attacker and last_defender shouldn't be nil"))


            if attacker.variables.future_basic_gold_yield then
                ai.ml_debug_message("gold_yield for attacker " .. attacker.id .. " was: " .. attacker.variables.future_basic_gold_yield)
            end
            ml_ai:add_gold_yield(last_defender,defender,attacker)
            ai.ml_debug_message("gold_yield for attacker " .. attacker.id .. " is now: " ..  attacker.variables.future_basic_gold_yield)

            if defender.variables.gold_yield then
                ai.ml_debug_message("gold_yield for defender " .. defender.id .. " was: " .. defender.variables.future_basic_gold_yield)
            end
            ml_ai:add_gold_yield(last_attacker,attacker,defender)
            ai.ml_debug_message("gold_yield for defender " .. defender.id .. " is now: " .. defender.variables.future_basic_gold_yield)

            ml_ai:update_poisoned_slowed_by(last_attacker,attacker,defender," while attacking","poisoned")
            ml_ai:update_poisoned_slowed_by(last_defender,defender,attacker, " while defending","poisoned")

            ml_ai:update_poisoned_slowed_by(last_defender,defender,attacker, " while defending","slowed")

            for unit,metric in pairs(defender.variables.__cfg) do
                ai.ml_debug_message ("defender.variables.__cfg",unit,metric)
            end

            if ml_ai:cures_self_of_poison(attacker) then
                ai.ml_debug_message(attacker.id .. " can cure itself of poison!")
            end

--[[            for key,val in pairs(wesnoth.unit_types[attacker.type].__cfg) do
                ai.ml_debug_message(string.format("The attacking unit %s has the following type property:  key:%s  val:%s",attacker.id,key,val))
            end]]



            last_attacker = nil
            last_defender = nil
        end

        function ml_ai:recruit_reporter()
            local ev = wesnoth.current.event_context
            local u = wesnoth.get_units{x=ev.x1, y=ev.y1}[1]
            -- Note:  We also do this in ml_ai:sync_unit_variables_with_statuses
            u.variables.old_max_experience =  u.max_experience
            ai.ml_info_message("RECRUIT (id:type:max_experience:cost)," .. u.id .. "," .. u.type .. "," .. u.max_experience ..  "," .. wesnoth.unit_types[u.type].cost )
        end

        function ml_ai:post_advance_reporter()
            local ev = wesnoth.current.event_context
            local u = wesnoth.get_units{x=ev.x1, y=ev.y1}[1]
            u.variables.experience_accumulated_on_previous_levels = zero_or_val(u.variables.old_max_experience) +
                    zero_or_val(u.variables.experience_accumulated_on_previous_levels)
            u.variables.old_max_experience = u.max_experience
            ai.ml_info_message("POST_ADVANCE (id:type:experience:max_experience), " .. u.id .. "," .. u.type .. "," .. u.experience .. "," .. u.max_experience)
        end

        local function record_final_unit_accomplishments(u,experience_override)
            local experience = u.experience
            if experience_override ~= nil then
                experience = experience_override
            end
            experience =  experience + zero_or_val(u.variables.experience_accumulated_on_previous_levels)
            u.variables.future_survival = wesnoth.current.turn
            u.variables.future_xp = experience
            u.variables.future_final_type = u.type
            u.variables.future_final_level = wesnoth.unit_types[u.type].level
        end

        local function get_accomplishment_dict(u)
            local unit_dict = {}
            for key,value in pairs(u.variables.__cfg) do
                if key:starts("future_") then
                    unit_dict[key:gsub("_"," ")] = value
                end
            end
            unit_dict.side = u.side
            unit_dict.id = u.id
            -- unit_dict.type = u.type
            -- unit_dict.level = wesnoth.unit_types[u.type].level
            return unit_dict
        end

        local function compute_dependent_futures(accomp_dict)
            accomp_dict["future gold yield"] =  zero_or_val(accomp_dict["future basic gold yield"]) +
                    zero_or_val(accomp_dict["future special gold yield"])
            accomp_dict["future xp+vc"] = zero_or_val(accomp_dict["future xp"]) + zero_or_val(accomp_dict["future vc"])
            -- Note:  I'd really rather multiply vc by wesnoth.game_config.village_income, but that doesn't seem to be working
            accomp_dict["future gold yield+2vc"] = zero_or_val(accomp_dict["future vc"]) * 2 +
                zero_or_val(accomp_dict["future gold yield"])
            return accomp_dict
        end

        local function print_survivors(ev,leader)
            local unit_that_killed_leader = wesnoth.get_units{x=ev.x2, y=ev.y2}[1]
            for _, i in ipairs(AH.get_live_units{}) do
                local experience
                if i.id == unit_that_killed_leader.id then
                    local experience_for_kill
                    local killed_leader_level = wesnoth.unit_types[leader.type].level
                    if killed_leader_level >= 1 then
                        experience_for_kill = killed_leader_level * 8
                    else
                        assert(killed_leader_level == 0)
                        experience_for_kill = 4
                    end
                    experience = i.experience + experience_for_kill
                    ai.ml_debug_message ("DEBUG:  " .. i.id .. " got " .. experience_for_kill ..
                            " experience points for the kill and had this much experience to start: " .. i.experience)
                else
                    experience = i.experience
                end
                record_final_unit_accomplishments(i,experience)
                local output_dict = compute_dependent_futures(get_accomplishment_dict(i))
                ml_ai:output_feature_dictionary{dict=output_dict,label="SURVIVED:,"}
            end
        end

        local function print_dead_units(dead_units)
            for _,j in pairs(dead_units) do
                local output_dict = compute_dependent_futures(get_accomplishment_dict(j))
                ml_ai:output_feature_dictionary{dict=output_dict,label="DEAD:,"}
            end
        end

        function ml_ai:die_reporter()
            local ev = wesnoth.current.event_context
            local u = wesnoth.get_units{x=ev.x1, y=ev.y1}[1]
            record_final_unit_accomplishments(u)
            local info_message = string.format("Died:  id:%s, level:%d, type:%s, xp:%d", u.id, u.variables.future_final_level,
                u.variables.future_final_type,u.variables.future_xp)
            ai.ml_info_message(info_message)
            dead_units[u.id] = wesnoth.copy_unit(u)
            -- ml_ai:output_feature_dictionary{dict=get_accomplishment_dict(u),label="DIE:, "}
            -- We assume that the game is over when a leader is killed.  This is a simplifying assumption until we can figure out what
            -- event indicates the end of a multiplayer scenario
            -- Note that this might also be problematic in a multiplayer game with more than two players
            if (u.canrecruit) then
                print_survivors(ev,u)
                print_dead_units(dead_units)

            end
        end

        function ml_ai:turn_reporter()
            ai.ml_info_message("TURN " .. wesnoth.current.turn)
        end


        function ml_ai:output_feature_dictionary(arg)
            local feature_dictionary = arg.dict
            local debug = arg.debug or false
            local label = arg.label or "PRERECRUIT:, "
            local out = ""
            local g = ml_ai:sortpairs(feature_dictionary,function(A,B) if A.key == "id" then return true elseif B.key == "id" then return false else return A.key < B.key end  end)
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
                ai.ml_debug_message(label .. out)
            else
                ai.ml_info_message(label .. out)
            end
        end

        function ml_ai:prerecruit_reporter()
            local feature_dictionary = ml_ai:decision_feature_computer(true,true)
            -- print("feature dictionary is " .. table.tostring(feature_dictionary) )
            local recruited_dependent_features = ml_ai:compute_recruited_dependent_features(function(x) return feature_dictionary[x] end)
            local combined_features = return_merged_tables(recruited_dependent_features,feature_dictionary)
            ml_ai:output_feature_dictionary{dict=combined_features}
        end

        function ml_ai:output_final_unit_stats()
            local feature_dictionary = ml_ai_unit_future_computer()
            ml_ai:output_feature_dictionary{dict=feature_dictionary}
        end

        function ml_ai:add_features(new_feature_table,old_feature_table)
            for k,v in pairs(new_feature_table) do  old_feature_table[k] = v end
        end

        function ml_ai:decision_feature_computer(omit_current_unit,fill_RECRUITED)  -- Compute the logical features
            --TODO:  All features should be factored out into a separate .lua file
            local feature_dictionary = ml_ai:unit_features(omit_current_unit,fill_RECRUITED)   --TODO:  This shouldn't be a special case
            local feature_list = {ml_ai.village_features,
                ml_ai.terrain_features,
                ml_ai.turn_feature,
                ml_ai.side_feature,
                ml_ai.faction_name_features,
                ml_ai.leader_hitpoint_features,
                ml_ai.time_of_day_feature,
                ml_ai.distance_to_leader}
            for _, feat in ipairs(feature_list) do
                ml_ai:add_features(feat(ml_ai),feature_dictionary)
            end
            return feature_dictionary
        end

        function ml_ai:compute_recruited_dependent_features(feature_accessor)
            local recruited = feature_accessor("RECRUITED")
            local feature_dictionary = {}
            -- print(table.tostring(wesnoth.unit_types[recruited].__cfg))
            feature_dictionary["recruited alignment"] = wesnoth.unit_types[recruited].__cfg.alignment
            feature_dictionary["recruited race"] = wesnoth.unit_types[recruited].__cfg.race
            feature_dictionary["recruited " .. recruited] = 1
            feature_dictionary["recruited unit count"] =   (#AH.get_live_units { side = wesnoth.current.side, type=recruited }  - 1)
            return feature_dictionary
        end

        function ml_ai:unit_features(omit_current_unit,fill_RECRUITED)
            local feature_dictionary = {}
            local myside = wesnoth.current.side
            local ev = wesnoth.current.event_context
            local u = wesnoth.get_units{x=ev.x1, y=ev.y1}[1]
            local recruited_unit_type = u.type
            if fill_RECRUITED then
                feature_dictionary.RECRUITED = recruited_unit_type
            end
            local unit_to_omit_id
            if omit_current_unit then
                unit_to_omit_id = u.id
            end
            
            local function fill_unit_count(units_deployed,unit_table)
                local unit_gold = 0
                for _, i in ipairs(units_deployed) do
                    unit_gold = unit_gold + wesnoth.unit_types[i.type].cost
                    if i.id ~= unit_to_omit_id then
                        if unit_table[i.type] == nil then
                            unit_table[i.type] = 1
                        else
                            unit_table[i.type] = unit_table[i.type] + 1  
                        end
                    end
                end
                return unit_gold
            end


            local unit_counts = {{},{}}
            local side_unit_gold_values = {0,0}
            local side_gold_values = {0,0 }

            local friendly_units = AH.get_live_units { side = wesnoth.current.side }
            local enemy_units = AH.get_live_units{ {"filter_side",{
                {"enemy_of",{side=wesnoth.current.side}}
            }} }


            local all_units = {friendly_units,enemy_units}
            for i=1,2 do
                side_unit_gold_values[i] = fill_unit_count(all_units[i],unit_counts[i])
            end

            side_gold_values[1] = wesnoth.sides[wesnoth.current.side].gold
            local best_enemy_gold = -100000000
            for side_no,side in ipairs(wesnoth.sides) do       --TODO:  Should really be checking if the side is an enemy of current side
                if wesnoth.is_enemy(side_no,wesnoth.current.side) and side.gold > best_enemy_gold then
                    best_enemy_gold = side.gold
                end
            end
            side_gold_values[2] = best_enemy_gold

            for i=1,2 do
                local prefixes ={"friendly ","enemy "}
                feature_dictionary[prefixes[i] .. "unit-gold"] = side_unit_gold_values[i]
                feature_dictionary[prefixes[i] .. "gold"] = side_gold_values[i]
                feature_dictionary[prefixes[i] .. "total-gold"] = side_unit_gold_values[i] + side_gold_values[i]
                local level3_or_higher = 0
                for key, value in pairs(unit_counts[i]) do
                    if wesnoth.unit_types[key].level >= 3 then
                        level3_or_higher = level3_or_higher + 1
                    else
                        feature_dictionary[prefixes[i] .. key] = value
                    end
                end
                feature_dictionary[prefixes[i] .. "level3+"] = level3_or_higher
            end
            feature_dictionary["total-gold-ratio"] = ml_ai:round_to_n_places(feature_dictionary["friendly total-gold"] /
                    (feature_dictionary["friendly total-gold"] + feature_dictionary["enemy total-gold"]),3)
            return feature_dictionary
        end

        function ml_ai:village_features()
            local feature_dictionary = {}
            local total_villages = wesnoth.get_locations { terrain="*^V*" }
            local friendly_villages = wesnoth.get_locations {owner_side = wesnoth.current.side}
            local enemy_side = 1
            if wesnoth.current.side == 1 then enemy_side = 2 end
            local enemy_villages = wesnoth.get_locations {owner_side = enemy_side} 
            local neutral_villages = #total_villages - (#friendly_villages + #enemy_villages) 
            feature_dictionary["village-neutral"] = neutral_villages
            if #friendly_villages + #enemy_villages > 0 then
                feature_dictionary["village-control-ratio"] = ml_ai:round_to_n_places(#friendly_villages/(#friendly_villages + #enemy_villages),3)
            else
                feature_dictionary["village-control-ratio"] = 0.5
            end
            feature_dictionary["village-control-margin"] = #friendly_villages - #enemy_villages
            feature_dictionary["village-enemy"] = #enemy_villages
            feature_dictionary["village-friendly"] = #friendly_villages
            return feature_dictionary
        end

        function ml_ai:round_to_n_places(number,n) 
            return H.round(number * 10^n) / 10^n
        end

        function ml_ai:terrain_features()
            local feature_dictionary = {}
            local width,height,border = wesnoth.get_map_size()
            local map_size = width * height
            local terrain_water_swamp = wesnoth.get_locations { terrain="W*,S*" }
            local terrain_mountain_hill = wesnoth.get_locations { terrain="M*,H*"}
            local terrain_forest = wesnoth.get_locations { terrain="*^F*" }
            feature_dictionary["terrain-map-size"] = map_size
            feature_dictionary["terrain-water-swamp"] = ml_ai:round_to_n_places((#terrain_water_swamp / map_size),3) 
            feature_dictionary["terrain-mountain-hill"] = ml_ai:round_to_n_places((#terrain_mountain_hill / map_size),3)
            feature_dictionary["terrain-forest"] = ml_ai:round_to_n_places((#terrain_forest /map_size),3)
            return feature_dictionary
        end

        function ml_ai:turn_feature(feature_dictionary)
            return {turn = wesnoth.current.turn}
        end

        function ml_ai:side_feature(feature_dictionary)
            return {side = wesnoth.current.side}
        end

        local function get_highest_hitpoints_percent(unit_list)
            local highest = -100000
            for _,u in ipairs(unit_list) do
                if u.hitpoints / u.max_hitpoints >  highest then
                    highest = u.hitpoints / u.max_hitpoints
                end
            end
            if highest < 0 then
                ai.ml_info_message("Warning!!  Very odd situation encountered where no leader on a side has positive number of hitpoints!!!!")
                return 0.0
            else
                return highest
            end
        end

        function ml_ai:leader_hitpoint_features()
            -- Leader hitpoints are important because if a leader is near death, the unit isn't going to be able to do much before end of game
            local feature_dictionary = {}
            local friendly_leaders = wesnoth.get_units { side = wesnoth.current.side, canrecruit = true }
            feature_dictionary["friendly leader hp pct"] =  get_highest_hitpoints_percent(friendly_leaders)
            local enemy_leaders = AH.get_live_units{canrecruit=true, {"filter_side",{
                {"enemy_of",{side=wesnoth.current.side}}
            }} }
            feature_dictionary["enemy leader hp pct"] =  get_highest_hitpoints_percent(enemy_leaders)
            return feature_dictionary
        end

        local faction_list = Set{"Northerners","Knalgan Alliance","Drakes","Undead","Loyalists","Rebels"}


        local function faction_from_recruit_list(recruit_list)
            local recruit_set = Set(recruit_list)
            if recruit_set["Skeleton"] ~= nil then return "Undead" end
            if recruit_set["Elvish Fighter"] ~= nil then return "Rebels" end
            if recruit_set["Drake Burner"] ~= nil then return "Drakes" end
            if recruit_set["Orcish Grunt"] ~= nil then return "Northerners" end
            if recruit_set["Dwarvish Fighter"] ~= nil then return "Knalgan Alliance" end
            if recruit_set["Horseman"] ~= nil then return "Loyalists" end
            assert(nil,"Error!  Failed to identify faction!  This feature only works with the standard multiplayer factions!")
        end

        function get_faction_for_side(side)
            return faction_from_recruit_list(wesnoth.sides[side].recruit)
        end

            

        function ml_ai:faction_name_features()
            local feature_dictionary = {}
            local my_side, enemy_side 
            my_side, enemy_side = ml_ai:get_my_side_and_enemy_side()
            feature_dictionary["friendly faction"] = get_faction_for_side(my_side)
            assert(faction_list[feature_dictionary["friendly faction"]],
                "Unable to identify friendly faction.  This feature only works with the standard factions")
            feature_dictionary["enemy faction"] = get_faction_for_side(enemy_side)
            assert(faction_list[feature_dictionary["enemy faction"]],
                "Unable to identify enemy faction.  This feature only works with the standard factions")
            return feature_dictionary
        end

        local time_to_integer = {dawn=1,morning=2,afternoon=3,dusk=4,first_watch=5,second_watch=6}
        function ml_ai:time_of_day_feature()
            local feature_dictionary = {}
            feature_dictionary["time of day"] = time_to_integer[wesnoth.get_time_of_day().id]
            return feature_dictionary
        end

        function ml_ai:distance_to_leader()
            -- Note that there's an assumption here that the side has only one leader.
            local feature_dictionary = {}
            local leader = wesnoth.get_units { side = wesnoth.current.side, canrecruit = true }[1]
            local enemies = AH.get_live_units    {  { "filter_side", {
                    {"enemy_of",{side = wesnoth.current.side}}
                 }  }}

            local closest, best = 1000000, nil
            for _,u in ipairs(enemies) do
                local distance = H.distance_between(leader.x,leader.y,u.x,u.y)
                if distance < closest then
                    closest,best = distance, u
                end
            end
            if best ~= nil then
                feature_dictionary["closest enemy to leader"] = closest
            end
            return feature_dictionary
        end
        
                
        return ml_ai
    end --init
}

