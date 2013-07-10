return {
    init = function(ai,default_command_line_parms)
        local H = wesnoth.require('lua/helper.lua')
        local W = H.set_wml_action_metatable {}
        local recruit_ai = {}
        recruit_ai.data = {}
        local T = H.set_wml_tag_metatable{}
        local no_more_recruiting_for_turn = {0,0 }
        local ml_ai
        local ron_recruit = {}

        if not ai.ml_debug_message then   -- This means that ML Recruiter is not installed
            W.message {
                speaker = 'narrator',
                caption = "Message from the ML Recruiter",
                image = 'wesnoth-icon.png', message = "ML Recruiter is not installed.  Please download and install the patch." ..
                        "  See the instructions at http://wiki.wesnoth.org/Machine_Learning_Recruiter#Applying_the_patch"
            }
            function recruit_ai:recruit_eval(recruiter_obj)
                return 0
            end
            W.endlevel { result = 'defeat' }
            global_recruit_ai = {0,0}
            return recruit_ai
        else
            wesnoth.require('~add-ons/AI-demos/lua/ml_utilities.lua')
            local sides_with_leaders = get_sides_with_leaders()
            if #sides_with_leaders == 2 and wesnoth.is_enemy(sides_with_leaders[1],sides_with_leaders[2]) then
                ai.ml_debug_message("hello world, at beginning of ml_ai_general right now")
                ml_ai = wesnoth.require('~add-ons/AI-demos/lua/ml_ai_features.lua').init(ai)
                wesnoth.require("~add-ons/AI-demos/lua/generic_recruit_engine.lua").init(ai, ron_recruit)
                wesnoth.require('~add-ons/AI-demos/lua/class.lua')
                ai.ml_debug_message("hello world, finished initializing ml_ai_general right now")
                ai.ml_debug_message(string.format("Power to raise metric to: %.1f\tModel being used:%s\tUse a single, non-faction-specific model:%s\tmodel directory:%s\tCA Score:%d",
                    default_command_line_parms.default_metric_cost_power,default_command_line_parms.which_model,default_command_line_parms.single_model,
                    default_command_line_parms.model_directory,default_command_line_parms.recruit_CA_score))
            else
                W.message {
                    speaker = 'narrator',
                    caption = "Message from the ML Recruiter",
                    image = 'wesnoth-icon.png', message = "The ML Recruiter currently only works in scenarios in which there are exactly two leaders." ..
                            "  These leaders must be on opposing sides."
                }
                function recruit_ai:recruit_eval(recruiter_obj)
                    return 0
                end
                W.endlevel { result = 'defeat' }
                global_recruit_ai = {0,0}
                return recruit_ai
            end
        end

        local function get_command_line_parms()
            local retval = {}
            if wesnoth.sides[wesnoth.current.side].user_team_name then
                local user_parm = tostring(wesnoth.sides[wesnoth.current.side].user_team_name)
                if user_parm and user_parm:find("=") then
                    for _,v in ipairs(user_parm:split("^")) do
                        local my_parm = v:split("=")
                        val = my_parm[2]
                        if not (val:lower() == "false" or val:lower() == "nil") then
                            retval[my_parm[1]] = my_parm[2]
                            ai.ml_info_message("Command-line Parameters: " .. my_parm[1] .. " : " .. my_parm[2])
                        end
                    end
                end
            end
            return retval
        end

        local function initialize(ai,default_parms)
            ai.ml_debug_message("Initializing ML AI for side " .. wesnoth.current.side)
            wesnoth.require("~add-ons/AI-demos/lua/ml_ai_events.lua").init(ai)

            local parms = get_command_line_parms()

            local model_directory = "~add-ons/AI-demos/models/"
            if default_parms.model_directory then
                model_directory = default_parms.model_directory   -- This can be parameterized in the cfg files via model_directory
            end

            -- metric/cost gets raised to metric_cost_power.  WeightedRandom then chooses among the different options, weighting the
            -- different recruits by this amount.
            local metric_cost_power = tonumber(default_parms.default_metric_cost_power)
            if parms.metric_cost_power then
                metric_cost_power = tonumber(parms.metric_cost_power)
            end
            if global_recruit_ai == nil then
                global_recruit_ai = {}
            end
            if (metric_cost_power == 0) then
                ai.ml_info_message("Using RandomRecruiter because metric_cost_power was set to 0")
                global_recruit_ai[wesnoth.current.side] = RandomRecruiter()
            else
                local my_faction = "all"
                if not default_parms.single_model and not parms.single_model then
                    my_faction =  get_faction_for_side(wesnoth.current.side)
                    ai.ml_info_message("My faction is " .. my_faction .. " current side is " .. wesnoth.current.side)
                    my_faction = my_faction:gsub(" ","_")
                end

                local which_model = default_parms.which_model
                if parms.model then
                    which_model = parms.model
                end
                local model_file = model_directory .. my_faction .. "/" .. which_model

                local raise_unit_metrics_to_a_power = function(x) return math.pow(x,metric_cost_power) end
                local weighted_random = WeightedRandom(raise_unit_metrics_to_a_power)

                global_recruit_ai[wesnoth.current.side] = MLRecruiter(model_file,weighted_random)
            end
        end

        function random(min, max)
          if not max then min, max = 1, min end
          wesnoth.fire("set_variable", { name = "LUA_random", rand = string.format("%d..%d", min, max) })
          local res = wesnoth.get_variable "LUA_random"
          wesnoth.set_variable "LUA_random"
          return res
        end

        Recruiter = class(function(a,allowed_recruits)
            a.allowed_recruits = allowed_recruits
        end)

        function Recruiter:recruit()
            error("recruit() method is unimplemented in Recruiter base class!")
        end

        function Recruiter:set_allowed_recruits(a)
            self.recruits = a
        end

        function Recruiter:get_allowed_recruits(recruits)
            -- Fall back from method parameter to member value to all allowed values for this side
            return recruits or self.allowed_recruits or wesnoth.sides[wesnoth.current.side].recruit
        end

        RandomRecruiter = class(Recruiter,function(c,allowed_recruits)
            Recruiter.init(c,allowed_recruits)
            end)

        function RandomRecruiter:recruit(recruits)
            local my_recruits = self:get_allowed_recruits(recruits)
            local recruit =  my_recruits[random(#my_recruits)]
            ai.ml_info_message("RandomRecruiter randomly decided to recruit " .. recruit)
            return recruit
        end

        --Example of how to set up a recruiter that only recruits one kind of unit
        --Could also do this by just doing RandomRecruiter({"Dwarvish Thunderer"})
        ThundererRecruiter = class(RandomRecruiter,function(c)
            RandomRecruiter.init(c,{"Dwarvish Thunderer"})
        end)

        local function my_compare(a,b)
           return a.final_weight< b.final_weight
        end


        WeightedRandom = class(function (a,final_weighting_function,cost_weight_function)
            if (final_weighting_function == nil) then
                final_weighting_function = function(x) return x end
            end
            a.final_weighting_function = final_weighting_function
            if (cost_weight_function == nil) then
                cost_weight_function = function(x) return x end
            end
            a.cost_weight_function = cost_weight_function
        end)



        function  WeightedRandom:weighted_choice(weighted_unit_metric_dictionary)
            table.sort(weighted_unit_metric_dictionary,my_compare)
            local total = 0
            for unit,unit_info in ipairs(weighted_unit_metric_dictionary) do
                assert(unit_info.final_weight >= 0,
                    string.format("The final weight of %.1f for the unit %s is invalid!",unit_info.final_weight,unit))
                total = total + unit_info.final_weight
            end
            -- TODO:  If total == 0, we have a problem here.  Should randomly select a unit in this case
            for _,unit_info in ipairs(weighted_unit_metric_dictionary) do
                local percentage = ml_ai:round_to_n_places(unit_info.final_weight/total,3) * 1000
                unit_info.percentage = percentage
                ai.ml_info_message(string.format("%-40s\t%.1f%%",unit_info.display,percentage/10))
            end
            local random_num = random(1,1000)
            ai.ml_info_message("Random Number chosen was " .. random_num)
            local current = 1
            local last_unit = nil
            for _,unit_info in ipairs(weighted_unit_metric_dictionary) do
                last_unit = unit_info.unit
                if unit_info.percentage > 0 then
                    if random_num < (current + unit_info.percentage) then
                        return unit_info.unit
                    else
                        current = current + unit_info.percentage
                    end
                end
            end
            return last_unit -- If a rounding error has caused the total to be less than 1000, return unit with highest weight
        end



        function WeightedRandom:choose(unit_metric_dictionary)
            local weighted_metric_dictionary = {}
            ai.ml_info_message("unit type\t\t\tmetric\tcost\tmetric/\tweighted\t%")
            ai.ml_info_message("\t\t\t\t\t\tcost\tm/c\t\tof total")
            for unit,metric in pairs(unit_metric_dictionary) do
                if metric < 0.0 then
                    ai.ml_info_message(string.format("Negative metric of %.4f returned.  Changing to 0 for %s",metric,unit  ))
                    metric = 0.0
                end
                local metric_per_cost = metric/self.cost_weight_function(wesnoth.unit_types[unit].cost)
                local weighted_metric_per_cost = self.final_weighting_function(metric_per_cost)
                local the_display = string.format("%-20s\t%.2f\t%d\t%.3f\t%.6f",
                    unit,metric,wesnoth.unit_types[unit].cost,metric_per_cost,weighted_metric_per_cost)
                table.insert(weighted_metric_dictionary,{unit=unit,final_weight = weighted_metric_per_cost,display = the_display})
            end
            local best_unit = self:weighted_choice(weighted_metric_dictionary)
            assert(best_unit,"Programming error.  Returning a nil value in take_highest indicates something is very wrong")
            return best_unit
        end



        local function take_highest(weighted_unit_metric_dictionary)
            local highest_metric = -10000000
            local best_unit = nil
            for unit,weighted_metric in pairs(weighted_unit_metric_dictionary) do
                assert(weighted_metric >= 0,"Negative metrics are not supported")
                if weighted_metric > highest_metric then
                    highest_metric = weighted_metric
                    best_unit = unit
                end
            end
            return best_unit
        end

        WeightedMetric = class(function (a,cost_function)
            if (cost_function == nil) then
                cost_function = function(x) return x end
            end
            a.cost_function = cost_function
        end)


        function WeightedMetric:choose(unit_metric_dictionary)
            local weighted_metric_dictionary = {}
            ai.ml_info_message("unit type\t\t\tmetric\tcost\twt cost\tweighted metric")
            for unit,metric in pairs(unit_metric_dictionary) do
                if metric < 0 then
                    ai.ml_info_message(string.format("Warning!  Negative metric of %.4f returned.  Changing to 0",metric  ))
                    -- assert(metric >= 0,string.format("Negative metrics are not allowed yet in take_highest.  Unit: %s Metric: %.4f",unit,metric))
                    metric = 0.0
                end
                weight = self.cost_function(wesnoth.unit_types[unit].cost)
                weighted_metric = metric/weight
                ai.ml_info_message(string.format("%-20s\t%.4f\t%d\t%.2f\t%.4f",unit,metric,wesnoth.unit_types[unit].cost,weight,weighted_metric))
                weighted_metric_dictionary[unit] = weighted_metric
            end
            best_unit = take_highest(weighted_metric_dictionary)
            assert(best_unit,"Programming error.  Returning a nil value in take_highest indicates something is very wrong")
            return best_unit
        end

        MLRecruiter = class(Recruiter,function(c,model_file_path,decider,allowed_recruits)
            if (decider == nil) then
                decider = TakeHighest()
            end
            Recruiter.init(c,allowed_recruits)
            ai.ml_info_message("Now loading " .. model_file_path)
            ai.load_recruitment_model(model_file_path)
            c.unit_metric_decider = decider
            c.model_file_path = model_file_path
            end)

        function MLRecruiter:recruit(recruits)
            -- This logic assumes that we are dealing with unit-specific metrics.
            -- The metric describes the unit, so we need to fill in the unit that we recruited in the dictionary
            -- Consequently, we test each unit that's available to recruit, one-by-one
            assert(self.unit_metric_decider ~= nil and self.model_file_path ~= nil,"MLRecruiter hasn't been properly initialized")
            ai.ml_debug_message("self.model_file_path: " .. self.model_file_path .. " side is " .. wesnoth.current.side)
            local feature_dictionary = ml_ai:decision_feature_computer()
            local my_dictionary = {}
            local recruitable_units = self:get_allowed_recruits(recruits)
            local unit_metrics = {}
            ai.ml_debug_message("Feature dictionary without the 'RECRUIT'")
            output_feature_dictionary{dict=feature_dictionary,debug=true,label="DEBUG:,",ai=ai} -- Output feature dictionary for debug purposes
            for _,new_unit in ipairs(recruitable_units) do
                feature_dictionary.RECRUITED = new_unit
                local recruited_dependent_features = ml_ai:compute_recruited_dependent_features(function(x) return feature_dictionary[x] end)
                -- print("recruited dependent" .. table.tostring(recruited_dependent_features))
                local combined_features = return_merged_tables(recruited_dependent_features,feature_dictionary)
                -- print("feature_dictionary going to get_ml_recruitment_score " .. table.tostring(feature_dictionary))
                local metric = ai.get_ml_recruitment_score(combined_features,self.model_file_path)
                unit_metrics[new_unit] = metric
                ai.ml_debug_message(new_unit .. " has metric: " .. metric)
            end
            return self.unit_metric_decider:choose(unit_metrics)
        end

        HybridRecruiter = class(Recruiter,function(c,recruiter_probability_dictionary,allowed_recruits)
            Recruiter.init(c,allowed_recruits)
            c.prob_to_recruiter = {}
            c.prob_to_recruiter[0] = nil -- We should never reference 0
            local total_percent = 0
            local current_percent = 0
            for _,recruiter_percent in ipairs(recruiter_probability_dictionary) do
                local recruiter,percent = recruiter_percent[1],recruiter_percent[2]
                total_percent = total_percent + percent
                assert(percent <= 100 and percent >= 0,"Percent must be between 0 and 100")
                assert(math.floor(percent) == percent,"Percent probability for each recruiter must be an integer")
                for i = current_percent + 1,(current_percent + percent) do
                    c.prob_to_recruiter[i] = recruiter
                end
                current_percent = current_percent + percent
            end
            assert(total_percent == 100,"Total percentage of all recruiters in a HybridRecruiter must be 100!")
            end)

        function HybridRecruiter:recruit(recruits)
            --Choose which recruiter to call then hand off to that recruiter
            local prob = random(1,100)
            local recruiter = self.prob_to_recruiter[prob]
            ai.ml_debug_message("In HybridRecruiter",prob,recruiter)
            return recruiter:recruit(recruits)
        end

        function recruit_ai:recruit_eval(recruiter_obj)
            if no_more_recruiting_for_turn[wesnoth.current.side] == wesnoth.current.turn then  -- We decided we're done recruiting
                return 0
            end

            local recruit_eval = do_recruit_eval(self.data)
            if recruit_eval == 0 then
                return 0
            else
                self.unit_to_recruit = recruiter_obj:recruit()
                local cost_for_unit_we_want = wesnoth.unit_types[self.unit_to_recruit].cost
                ai.ml_info_message("Side: " .. wesnoth.current.side .. " Gold: " .. wesnoth.sides[wesnoth.current.side].gold .. " Unit we want: " .. self.unit_to_recruit)
                if cost_for_unit_we_want > wesnoth.sides[wesnoth.current.side].gold then
                    no_more_recruiting_for_turn[wesnoth.current.side] = wesnoth.current.turn
                    return 0
                end
                return default_command_line_parms.recruit_CA_score
            end
        end


        function recruit_ai:recruit_execution()
            if default_command_line_parms.use_RCA_AI_recruit_location then
                ai.recruit(self.unit_to_recruit)
            else
                local leader = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]
                self.data.recruit.best_hex, self.data.recruit.target_hex = ron_recruit:find_best_recruit_hex(leader, self.data)
                ai.recruit(self.unit_to_recruit,self.data.recruit.best_hex[1],self.data.recruit.best_hex[2])
            end
            ai.ml_info_message ("We just recruited a " .. self.unit_to_recruit .. " for side " .. wesnoth.current.side .. " Gold is now: " .. wesnoth.sides[wesnoth.current.side].gold)
        end

        initialize(ai,default_command_line_parms)

        return recruit_ai
    end --init
}
