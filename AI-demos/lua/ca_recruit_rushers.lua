-- Making the generic_recruit_engine functions available as external CAs
-- They have to be added to the engine, in self.data.recruit, before that

local ca_recruit_rushers = {}

function ca_recruit_rushers:evaluation(cfg, data)
    return data.recruit:recruit_rushers_eval()
end

function ca_recruit_rushers:execution(cfg, data)
    return data.recruit:recruit_rushers_exec()
end

return ca_recruit_rushers