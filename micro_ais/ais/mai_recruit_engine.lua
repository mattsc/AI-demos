return {
    init = function(ai)

        local recruit_cas = {}
        -- The following external engine creates the CA functions recruit_rushers_eval and recruit_rushers_exec
        -- It also exposes find_best_recruit and find_best_recruit_hex for use by other recruit engines
        wesnoth.require("~add-ons/AI-demos/lua/generic-recruit_engine.lua").init(ai, recruit_cas)

        return recruit_cas
    end
}
