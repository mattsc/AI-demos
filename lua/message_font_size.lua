local old_message = wesnoth.wml_actions.message

function wesnoth.wml_actions.message(cfg)
    local new_cfg = cfg.__literal

    -- Changing the message font size
    new_cfg.message = "<span font='" .. message_size .. "'>" .. cfg.message .. "</span>"

    -- All the rest is just for getting the caption text right, if it is not set
    local caption = cfg.caption
    if caption == nil or caption == "" then

        -- If speaker = narrator -> no caption
        if cfg.speaker == "narrator" then caption = ""

        -- If speaker = unit -> get unit name
        elseif cfg.speaker == "unit" then
            local ec = wesnoth.current.event_context
            local unit = wesnoth.get_unit(ec.x1,ec.y1)
            if unit == nil then caption = ""
            else caption = unit.__cfg.name end

        -- If speaker = second_unit -> get second_unit name
        elseif cfg.speaker == "second_unit" then 
            local ec = wesnoth.current.event_context
            local second_unit = wesnoth.get_unit(ec.x2,ec.y2)
            if second_unit == nil then caption = ""
            else caption = second_unit.__cfg.name end

        -- In all other cases, assume it's a unit id and get it, if it exists
        else
            local speaker = wesnoth.get_units { id = cfg.speaker }
            if speaker[1] == nil then caption = ""
            else caption = speaker[1].name end
        end
    end

    -- Finally, use larger font for caption
    new_cfg.caption = "<span font='" .. caption_size .. "'>" .. caption .. "</span>"

    old_message(new_cfg)
end
