#!/usr/bin/env python

import re
from optparse import OptionParser
import fileinput

usage = """
Analyzes a log file output by ai_test2.py for winning percentage by faction.  Optionally provides subtotals by map for
each faction.

In the below command, *.log represents the log files being analyzed, so the below command will work if you are
in the directory with the log files being analyzed.
Usage:  analyze_log.py [options] *.log
"""
parser = OptionParser(usage)
parser.add_option("-d","--default_ai",dest="opposing_ai",default="default_ai_with_recruit_log",help="AI you are opposing.  Reports results for the AI that is *not* this AI.")
parser.add_option("-m","--maps",dest="map_totals",default=False,action="store_true")
parser.add_option("-s","--sides",dest="side_totals",default=False,action="store_true")
(options, args) = parser.parse_args()

if len(args) < 1:
    parser.error("You must specify at least one .log file.  Run with --help for help.")

ai_grand_totals = {}

class FactionData:
    def __init__(self):
        self.opponents = {}
        self.maps = {}
        self.sides = {}

def process_log_for_factions():
    wins = {}
    losses = {}
    total_time = 0
    total_turns = 0
    total_timeouts = 0
    total_not_success = 0
    for line in fileinput.input(args):
        if re.search("is_success",line):
            # Exclude the schema row
            continue
        fields = line.split(",")
        fields = [x.strip() for x in fields]
        fields = [x.strip('"') for x in fields]
        is_success = fields[7].strip()
        # print "is_success is ", is_success
        if is_success == "timeout":
            total_timeouts += 1
            continue
        elif is_success != "true":
            total_not_success += 1
            # Exclude games which didn't end in a success.
            continue
        ais = [fields[2],fields[3]]
        factions = [fields[5],fields[6]]
        winning_side = int(fields[14]) - 1   # Change label from 1 - 2 to 0 - 1
        total_time += float(fields[4])
        total_turns +=int(fields[12])

        # print "ais is", ais
        winner_ai = fields[17]
        game_map = fields[9]

        number_of_opposing_ais = sum([x == options.opposing_ai for x in ais])
        assert number_of_opposing_ais == 1,"opposing_ai not set properly.  Only one of the following two AIs should be the opposing AI: " +  \
                ais[0] + " " + ais[1]
        # print "winning side is", winning_side
        # print "ais is", ais
        # print "factions is ", factions
        # print "options.opposing_ai", options.opposing_ai
        if (ais[0] == options.opposing_ai):
            faction_being_tested = factions[1]
            opponent = factions[0]
            side = 2
        else:
            faction_being_tested = factions[0]
            opponent = factions[1]
            side = 1
        winner_ai = ais[winning_side]
        if winner_ai not in ai_grand_totals:
            ai_grand_totals[winner_ai] = 0
        ai_grand_totals[winner_ai] += 1
        if (winner_ai != options.opposing_ai):
            # The AI being tested won
            win_or_loss = wins
        else:
            win_or_loss = losses

        # print "faction being tested is", faction_being_tested
        if faction_being_tested not in wins:
            wins[faction_being_tested] = FactionData()
        if faction_being_tested not in losses:
            losses[faction_being_tested] = FactionData()

        data = win_or_loss[faction_being_tested]
        if opponent in data.opponents:
            data.opponents[opponent] += 1
        else:
            data.opponents[opponent] = 1
        if game_map in data.maps:
            data.maps[game_map] += 1
        else:
            data.maps[game_map] = 1
        if side in data.sides:
            data.sides[side] += 1
        else:
            data.sides[side] = 1

    factions = set(wins.keys())
    factions= factions.union(losses.keys())
    factions = [x for x in factions]
    factions.sort()

    print "Overall Stats"
    print "{0:30}\t{1}\t{2}".format("AI","Wins","Win %")
    for ai in ai_grand_totals:
        print "{0:30}\t{1}\t{2:.1%}".format(ai,ai_grand_totals[ai],float(ai_grand_totals[ai])/sum(ai_grand_totals.values()))
    total_games = sum(ai_grand_totals.values())
    print "{0:30}\t{1}".format("Totals:",total_games)

    if options.map_totals:
        print "\nOverall Map Totals:"
        all_maps = set()
        for friendly_faction in factions:
            all_maps = all_maps.union(wins[friendly_faction].maps)
            all_maps = all_maps.union(losses[friendly_faction].maps)
        print "{0:40}\t{1}\t{2}\t{3}".format("Map","Wins","Losses","Win %")
        for map in all_maps:
            map_wins = reduce(lambda x, y: x+ (y or 0), [wins[x].maps[map] for x in factions if x in wins and map in wins[x].maps], 0)
            map_losses = reduce(lambda x, y: x+ (y or 0), [losses[x].maps[map] for x in factions if x in losses and map in losses[x].maps], 0)
            assert map_wins+map_losses > 0,"Programming Error:  Zero wins for sum of map wins and losses!"
            print "{0:40}\t{1}\t{2}\t{3:.1%}".format(map,map_wins,map_losses,float(map_wins)/(map_wins + map_losses))

    if options.side_totals:
        print "\nOverall Side Totals:"
        for side in [1,2]:
            side_wins = reduce(lambda x, y: x+ (y or 0), [wins[x].sides[side] for x in factions if x in wins and side in wins[x].sides], 0)
            side_losses = reduce(lambda x, y: x+ (y or 0), [losses[x].sides[side] for x in factions if x in losses and side in losses[x].sides], 0)
            assert side_wins+side_losses > 0,"Programming Error:  Zero wins for sum of side wins and losses!"
            print "{0:5}\t{1}\t{2}\t{3:.1%}".format(side,side_wins,side_losses,float(side_wins)/(side_wins + side_losses))

    print "\nGames Timed out:  {0}\tGames ending in errors or draws: {1}\n".format(total_timeouts,total_not_success)
    print "Time per game (in seconds, including errors/timeouts): {0:.1f}".format(total_time/float(total_games + total_timeouts + total_not_success))
    print "Time per turn of completed games: {0:.2f}\n".format(total_time/total_turns)

    for friendly_faction in factions:
        "---------------------{0} vs. Opponents --------------------------".format(friendly_faction)
        "{0:30}\t{1}\t{2}\t{3}".format("sides","wins","losses","win %")
        faction_wins = wins[friendly_faction]
        faction_losses = losses[friendly_faction]
        total_wins = 0
        total_losses = 0
        for opponent in set(faction_wins.opponents).union(faction_losses.opponents):
            total_wins += faction_wins.opponents[opponent] if (opponent in faction_wins.opponents) else 0
            total_losses += faction_losses.opponents[opponent] if (opponent in faction_losses.opponents) else 0
            wins_vs_opponent = faction_wins.opponents[opponent] if (opponent in faction_wins.opponents) else 0
            losses_vs_opponent = faction_losses.opponents[opponent] if (opponent in faction_losses.opponents) else 0
            win_pct = float(wins_vs_opponent) / (wins_vs_opponent + losses_vs_opponent) if (wins_vs_opponent + losses_vs_opponent) != 0 else 0.0
            print "{0:33}\t{1:d}\t{2:d}\t{3:.1%}".format(friendly_faction + " vs " + opponent,wins_vs_opponent,losses_vs_opponent,win_pct)
        print "Total {0:27}\t{1:d}\t{2:d}\t{3:.1%}\n".format(friendly_faction,total_wins,total_losses,(float(total_wins)/(total_wins + total_losses)))

        if options.map_totals:
            map_total_wins = 0
            map_total_losses = 0
            for the_map in set(faction_wins.maps).union(faction_losses.maps):
                map_total_wins += faction_wins.maps[the_map] if (the_map in faction_wins.maps) else 0
                map_total_losses += faction_losses.maps[the_map] if (the_map in faction_losses.maps) else 0
                wins_on_map = faction_wins.maps[the_map] if (the_map in faction_wins.maps) else 0
                losses_on_map = faction_losses.maps[the_map] if (the_map in faction_losses.maps) else 0
                win_pct = float(wins_on_map) / (wins_on_map + losses_on_map) if (wins_on_map + losses_on_map) != 0 else 0.0
                print "{0:58}\t{1:d}\t{2:d}\t{3:.1%}".format(friendly_faction + " on " + the_map,wins_on_map,losses_on_map,win_pct)
            print "{0:58}\t{1:d}\t{2:d}\t{3:.1%}\n".format("Total " + friendly_faction,map_total_wins,map_total_losses,(float(total_wins)/(total_wins + total_losses)))
            assert map_total_wins == total_wins and map_total_losses == total_losses, "Programming error!  Map totals should equal faction totals!"

        if options.side_totals:
            side_total_wins = 0
            side_total_losses = 0
            for the_side in set(faction_wins.sides).union(faction_losses.sides):
                side_total_wins += faction_wins.sides[the_side] if (the_side in faction_wins.sides) else 0
                side_total_losses += faction_losses.sides[the_side] if (the_side in faction_losses.sides) else 0
                wins_on_side = faction_wins.sides[the_side] if (the_side in faction_wins.sides) else 0
                losses_on_side = faction_losses.sides[the_side] if (the_side in faction_losses.sides) else 0
                win_pct = float(wins_on_side) / (wins_on_side + losses_on_side) if (wins_on_side + losses_on_side) != 0 else 0.0
                print "{0:58}\t{1:d}\t{2:d}\t{3:.1%}".format(friendly_faction + " as Side " + str(the_side),wins_on_side,losses_on_side,win_pct)
            print "{0:58}\t{1:d}\t{2:d}\t{3:.1%}\n".format("Total " + friendly_faction,side_total_wins,side_total_losses,(float(total_wins)/(total_wins + total_losses)))
            assert side_total_wins == total_wins and side_total_losses == total_losses, "Programming error!  Side totals should equal faction totals!"



process_log_for_factions()





