return {
    activate = function(side, types)
        -- cfg contains extra options to be passed on to the CAs
        -- This needs to be set up as a string

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        --print("Activating template for Side " .. side)

        W.modify_ai {
            side = side,
            action = "add",
            path = "stage[main_loop].candidate_action",
            { "candidate_action", {
                    engine = "lua",
                    name = "ca_big_animal_side" .. side,
                    id = "ca_big_animal_side" .. side,
                    max_score = 300000,
                    evaluation = "return (...):big_eval('" .. types .. "')",
                    execution = "(...):big_exec('" .. types .. "')"
            } }
        }
    end,

    remove = function(side)

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}

        --print("Removing template for Side " .. side)

        W.modify_ai {
            side = side,
            action = "try_delete",
            path = "stage[main_loop].candidate_action[ca_big_animal_side" .. side .. "]"
        }
    end
}
