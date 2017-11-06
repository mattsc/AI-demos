-- Making the generic_recruit_engine functions available as external CAs
-- They have to be added to the engine, in self.data.recruit, before that

wesnoth.require "~/add-ons/AI-demos/lua/set_CA_args.lua"

local ca_recruit_rushers = {}

function ca_recruit_rushers:evaluation(arg1, arg2, arg3)
    local ai, cfg, data = set_CA_args(arg1, arg2, arg3)
    return data.recruit:recruit_rushers_eval()
end

function ca_recruit_rushers:execution(arg1, arg2, arg3)
    local ai, cfg, data = set_CA_args(arg1, arg2, arg3)
    return data.recruit:recruit_rushers_exec()
end

return ca_recruit_rushers