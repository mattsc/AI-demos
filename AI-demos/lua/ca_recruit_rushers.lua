-- Making the generic_recruit_engine functions available as external CAs
-- They have to be added to the engine, in self.recruit, before that

local ca_recruit_rushers = {}

function ca_recruit_rushers:evaluation(ai, cfg, self)
    return self.recruit:recruit_rushers_eval()
end

function ca_recruit_rushers:execution(ai, cfg, self)
    return self.recruit:recruit_rushers_exec()
end

return ca_recruit_rushers