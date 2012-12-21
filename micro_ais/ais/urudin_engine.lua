return {
    init = function(ai)

        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"

        local urudin = { }

        -- This is taken almost literally from 'Ka'lian under Attack' in 'Legend of Wesmere'
        function urudin:retreat()
            local urudin = wesnoth.get_units({side = 3, id="Urudin"})[1]
            if urudin and urudin.valid then
                local mhp, hp = urudin.max_hitpoints, urudin.hitpoints
                local turn = wesnoth.current.turn
                if (turn >= 5) or (hp < mhp / 2) then
                    AH.movefull_stopunit(ai, urudin, 33, 8)
                end
            end
        end

        return urudin
    end
}
