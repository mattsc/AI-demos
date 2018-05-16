-- Fred events (start/end messages, Easter eggs, etc.) are set up using Lua
-- so that they can be inserted conditionally only into Fred games, and not
-- into every game when AI-demos is active.

---------- Start message ----------
wesnoth.add_event_handler {
    name = 'side 1 turn 1',

    { 'message', {
        id = 'Fred',
        caption = "Fred (Freelands AI v$AI_Demos_version)",
        message = "Good luck, have fun!\n\n<i>Note: This is an <span color='#C00000' weight='bold'>intermediate development release</span> uploaded in the middle of rebalancing Fred's overall behavior. Thus, some new problems with Fred's gameplay are expected and not all of the old issues have been dealt with yet.</i>"
    } }
}

---------- End message ----------
wesnoth.add_event_handler {
    name = 'last_breath',
    { 'filter', { canrecruit = 'yes' } },

    { 'message', {
        id = 'Fred',
        message = "Good game, thanks!",
        scroll = 'no'
    } }
}

---------- Assassin exclaim ----------
-- Assassin exclaims in frustration if he misses all 3 strikes (2 events)
-- Assassin Event 1: The actual message. This is a separate event and without
-- first_time_only=yes, so that it only fires once per scenario
wesnoth.add_event_handler {
    name = 'assassin_message',

    { 'set_variable', {
        name = 'random',
        rand = "Oh come on!,I don't believe this!,What the …"
    } },
    { 'message', {
        id = '$unit.id',
        message = "$random"
    } },
    { 'clear_variable', { name = 'random' } }
}

-- Assassin Event 2: The trigger
wesnoth.add_event_handler {
    name = 'attack end',
    first_time_only = 'no',

    -- Only happens for assassins on Fred's side
    { 'filter', {
        type = 'Orcish Assassin',
        { 'filter_side', {
            { 'has_unit', { id = 'Fred' } }
        } }
    } },
    -- Only if the defender is not poisoned after the attack. This also
    -- excludes attacks in which then enemy is already poisoned beforehand,
    -- but that does not matter, as it is not supposed to show every time anyway.
    { 'filter_second', {
        { 'filter_wml', {
            { 'not', {
                { 'status', { poisoned = 'yes' } }
            } }
        } }
    } },
    -- Only after the poison attack
    { 'filter_attack', { range = 'ranged' } },

    -- And even if all this is true, the message is only displayed with a 33% chance
    -- Also need to check that defender did not die, otherwise he might not count as
    -- poisoned (if this was the first hit)
    { 'set_variable', {
        name = 'random',
        rand = "1..3"
    } },

    { 'if', {
        { 'variable', {
            name = 'random',
            equals = 1
        } },
        { 'variable', {
            name = 'second_unit.hitpoints',
            greater_than = 0
        } },

        { 'then', {
            { 'fire_event', {
                name = 'assassin_message',
                { 'primary_unit' , { id = '$unit.id' } }
            } }
        } }
    } },

    { 'clear_variable', { name = 'random' } }
}

---------- Goblin boasts ----------
-- Goblin with 1HP boasts if he survives an attack (2 events)
-- Goblin Event 1: The actual message. This is a separate event and without
-- first_time_only=yes, so that it only fires once per scenario
wesnoth.add_event_handler {
    name = 'goblin_boasts',

    { 'message', {
        id = '$unit.id',
        message = "Haw Haw!"
    } },

    { 'set_variable', {
        name = 'boast_goblin_id',
        value = "$unit.id"
    } },

    { 'event', {
        name = 'last breath',
        { 'filter', { id = '$boast_goblin_id' } },

        { 'message', {
            id = '$unit.id',
            message = "I guess that's what I get for being cocky."
        } },

        { 'clear_variable', { name = 'boast_goblin_id' } }
    } }
}

-- Goblin Event 2: The trigger
wesnoth.add_event_handler {
    name = 'attack',
    first_time_only = 'no',

    -- Only happens for goblins on Fred's side that have 1 HP before the attack
    { 'filter_second', {
        race = 'goblin',
        { 'filter_side', {
            { 'has_unit', { id = 'Fred' } }
        } },
        { 'filter_wml', { hitpoints = 1 } }
    } },

    -- Attack end without filter, so it has to be the same attack
    { 'event', {
        name = 'attack end',

        -- 50% chance of the goblin boasting, if he still has 1 HP
        { 'set_variable', {
            name = 'random',
            rand = "1..2"
        } },

        { 'if', {
            { 'variable', {
                name = 'random',
                equals = 1
            } },
            { 'variable', {
                name = 'second_unit.hitpoints',
                greater_than = 0
            } },

            { 'then', {
                { 'fire_event', {
                    name = 'goblin_boasts',
                    { 'primary_unit' , { id = '$second_unit.id' } }
                } }
            } }
        } },

        { 'clear_variable', { name = 'random' } }
    } }
}

---------- Lucky level-up message ----------
-- Unit with fewer than 5 HP surviving and leveling up exclaims (2 events)
-- Lucky Level-up Event 1: The actual message. This is a separate event and without
-- first_time_only=yes, so that it only fires once per scenario
wesnoth.add_event_handler {
    name = 'lucky_levelup',

    { 'message', {
        id = '$unit.id',
        message = "Ha! What does not kill you, makes you stronger."
    } }
}

-- Lucky Level-up Event 2: The trigger
wesnoth.add_event_handler {
    name = 'attack',
    first_time_only = 'no',

    -- For any unit on Fred's side being attacked
    { 'filter_second', {
        { 'filter_side', {
            { 'has_unit', { id = 'Fred' } }
        } },
    } },

    -- If HP < 5, XP = max_XP-1 and attacker is at least level 1
    { 'if', {
        { 'variable', {
            name = 'unit.level',
            greater_than = 0
        } },
        { 'variable', {
            name = 'second_unit.hitpoints',
            less_than = 5
        } },
        { 'variable', {
            name = 'second_unit.experience',
            equals = '$($second_unit.max_experience-1)'
        } },

        { 'then', {
            { 'event', {
                name = 'attack end',

                -- 33% chance of the message being triggered, if the unit survived
                { 'set_variable', {
                    name = 'random',
                    rand = "1..3"
                } },

                { 'if', {
                    { 'variable', {
                        name = 'random',
                        equals = 1
                    } },
                    { 'variable', {
                        name = 'second_unit.hitpoints',
                        greater_than = 0
                    } },

                    { 'then', {
                        { 'fire_event', {
                            name = 'lucky_levelup',
                            { 'primary_unit' , { id = '$second_unit.id' } }
                        } }
                    } }
                } },

                { 'clear_variable', { name = 'random' } }
            } }
        } }
    } }
}

---------- Fred angry message ----------
-- Leveled-up unit with decent HP being killed causes Fred to exclaim (2 events)
-- Fred Angry Event 1: The actual message. This is a separate event and without
-- first_time_only=yes, so that it only fires once per scenario
wesnoth.add_event_handler {
    name = 'Fred_angry',

    { 'message', {
        id = 'Fred',
        message = "You'll pay for that!"
    } }
}

-- Fred Angry Event 2: The trigger
wesnoth.add_event_handler {
    name = 'attack',
    first_time_only = 'no',
    -- For any unit on Fred's side (other than Fred himself) being attacked
    { 'filter_second', {
        canrecruit = 'no',
        { 'filter_side', {
            { 'has_unit', { id = 'Fred' } }
        } },
    } },

    -- If HP > 19 and level > 1
    { 'if', {
        { 'variable', {
            name = 'second_unit.hitpoints',
            greater_than = 19
        } },
        { 'variable', {
            name = 'second_unit.level',
            greater_than = 1
        } },


        { 'then', {
            { 'event', {
                name = 'attack end',

                -- 50% chance of the message being triggered, if the unit survived
                { 'set_variable', {
                    name = 'random',
                    rand = "1..2"
                } },

                { 'if', {
                    { 'variable', {
                        name = 'random',
                        equals = 1
                    } },
                    { 'variable', {
                        name = 'second_unit.hitpoints',
                        less_than_equal_to = 0
                    } },

                    { 'then', {
                        { 'fire_event', { name = 'Fred_angry' } }
                    } }
                } },

                { 'clear_variable', { name = 'random' } }
            } }
        } }
    } }
}
