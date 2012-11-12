--Contains logic for computing the features for machine learning.  These are the attributes of a unit or of a game
--state that are useful in predicting how well we will do on the "Unit Goodness metrics" that are computed in ml_ai_futures
--See http://wiki.wesnoth.org/Machine_Learning_Recruiter#How_the_ML_Recruiter_works for an explanation

return {
    init = function(ai)
        ai.ml_debug_message("hello world, at beginning of ml_ai_features right now")
        local H = wesnoth.require('lua/helper.lua')
        wesnoth.require("~add-ons/AI-demos/lua/ml_utilities.lua")
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"

        local ml_ai = {}
        ai.ml_debug_message("hello world, finished initializing ml_ai_features right now")

        -- From http://stackoverflow.com/questions/656199/search-for-an-item-in-a-lua-list
        local function Set (list)
          local set = {}
          for _, l in ipairs(list) do set[l] = true end
          return set
        end

        function ml_ai:get_my_side_and_enemy_side()
            -- TODO:  Need to rewrite this to do multiplayer
            local my_side = wesnoth.current.side
            local enemy_side = 1
            if my_side == 1 then enemy_side = 2 end
            return my_side, enemy_side
        end

        function ml_ai:add_features(new_feature_table,old_feature_table)
            for k,v in pairs(new_feature_table) do  old_feature_table[k] = v end
        end

        function ml_ai:decision_feature_computer(omit_current_unit,fill_RECRUITED)  -- Compute the logical features
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

