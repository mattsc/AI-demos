#!/usr/bin/env python
from time import time
import re

assumed_max_turns_per_game = 50

class RecruitEvent:
    features = {}
    index = -1
    current_experience = 0
    max_experience = -1
    id = ""
    type = ""
    turn_met_fate = 0
    fate = ""
    def __init__(self,id,max_experience,type,cost,index,features):
        self.id = id
        self.max_experience = max_experience
        self.type = type
        self.cost = cost
        self.index = index
        self.features = features
        self.experience = 0

def comma_fixup(m):
    return m.group(1)+"__comma__"+m.group(3)

class OutputProcessor:
    features = []  # Map from feature name to feature_index
    #Note:  There will be different schema orderings for different datasets.  These schema orderings are reconciled
    # when csv files are imported by csv_normalizer.py
    prefix = "info ai/ml: "
    testing_prefix = "info ai/testing: "
    prerecruit = re.compile(prefix + "PRERECRUIT")
    recruit = re.compile(prefix +"RECRUIT")
    die_or_survive = re.compile(prefix + "(DEAD|SURVIVED).*")
    turn = re.compile(prefix + "TURN\s+(\d+)")
    winner = re.compile(testing_prefix + "WINNER: (\d+).*")
    draw = re.compile("^time over")
    commas_in_quotes = re.compile("('[^']*)(,)([^']*')")

    def filter_non_printable(self,str):
        return ''.join(c for c in str if ord(c) > 31 or ord(c) == 9)

    def do_filter(self,str,substring):
        n = str.find(substring)
        if (n>-1):
            return n,str[n+len(substring):].strip()
        return n,''

    def add_feature_to_dicts(self,feat_name,feat_value,feat_dict):
        if feat_name in self.features:
            pass
        else:
            self.features.append(feat_name)

        parsed_feat = None
        try:
            parsed_feat = int(feat_value)
        except ValueError:
            try:
                parsed_feat = float(feat_value)
            except ValueError:
                parsed_feat = feat_value
        assert(parsed_feat is not None)
        feat_dict[feat_name] = parsed_feat


    # Processes the ML Recruiting output of a single game.
    def process_game_stdout(self,stdout,ml_log_file,game_result_from_stderr=None):
        recruit_events = {}
        current_feats = {}
        next_event_index = 0
        winning_side = 0
        current_turn = 1
        expect_recruit = False
        for line in stdout.splitlines():
            line = self.filter_non_printable(line.strip())
            line = self.commas_in_quotes.sub(comma_fixup,line)
            match = self.prerecruit.search(line)
            if match:
                # It's a PRERECRUIT line where we see the values of all the features
                # We record them here and then add them to the recruit event in expect_recruit
                current_feats = {}
                feat_strings = line.split(',')
                feat_strings = [x.strip() for x in feat_strings]
                feat_strings = feat_strings[1:len(feat_strings)]  # Drop the "PRERECRUIT" thing at beginning of line
                for feat in feat_strings:
                    if not feat:
                        continue
                    mypair = feat.split(':')
                    feat_name = mypair[0].strip()
                    feat_value = mypair[1].strip()
                    self.add_feature_to_dicts(feat_name,feat_value,current_feats)
                expect_recruit = True
                continue
            elif expect_recruit:
                if self.recruit.search(line):
                    expect_recruit = False
                    d = line.split(",")
                    assert len(d) == 5,"We expect RECRUIT lines to have 4 elements following the RECRUIT label for a total of 5 comma separated values"
                    d = [x.strip() for x in d]
                    recruit_events[d[1]] = RecruitEvent(d[1],int(d[3]),d[2],d[4],next_event_index,current_feats)
                    current_feats = {}
                    next_event_index += 1
                else:
                    raise Exception("Expect a 'RECRUIT' to follow a 'PRERECRUIT'")
                continue
            elif self.turn.search(line):
                match = self.turn.search(line)
                current_turn = int(match.group(1).strip())
                # print "current turn is ", current_turn
                continue
            elif self.die_or_survive.search(line):
                match = self.die_or_survive.search(line)
                results = line.split(",")
                results = [x.strip() for x in results]
                feat_strings = results[1:len(results)]  # Drop the "PRERECRUIT", "DEAD", or "SURVIVED" thing at beginning of line
                temp_feats = {}
                unit_id = None
                for feat in feat_strings:
                    if not feat:
                        continue
                    mypair = feat.split(':')
                    assert len(mypair) == 2, "Feature doesn't have a value on the following line:" + line
                    feat_name = mypair[0].strip()
                    feat_value = mypair[1].strip()
                    if feat_name == "id":
                        unit_id = feat_value
                    else:
                        temp_feats[feat_name] = feat_value

                assert unit_id, "Missing unit ID in the following line: " + line
                if unit_id in recruit_events:
                    event = recruit_events[unit_id]
                    if match.group(1) == "SURVIVED":
                        event.fate = "survived"
                    else:
                        event.fate = "died"
                    for j in temp_feats.keys():
                        self.add_feature_to_dicts(j,temp_feats[j],event.features)
                continue
            elif self.winner.search(line):
                match = self.winner.search(line)
                winning_side = int(match.group(1))
                continue
            # TODO:  We should really have a way of writing draws to the log
#            elif self.draw.search(line):
#                winning_side = -1
#                continue

        if winning_side > 0 and current_turn <= assumed_max_turns_per_game:
            turn_game_ended = current_turn
            events = recruit_events.values()
            events = sorted(events, cmp=lambda x,y: cmp(x.index, y.index))
            for event in events:
                if int(event.features["side"]) == winning_side:
                    victory_points_for_win = assumed_max_turns_per_game - turn_game_ended
                    self.add_feature_to_dicts('future victory points',victory_points_for_win,event.features)
                    self.add_feature_to_dicts('future victory',1,event.features)
                    # print event.id, " is victorious"," side was ", event.features["side"]
                else:
                    victory_points_for_defeat = -1 * (assumed_max_turns_per_game - turn_game_ended)
                    self.add_feature_to_dicts("future victory points",victory_points_for_defeat,event.features)
                    self.add_feature_to_dicts("future victory",0,event.features)
                    # print event.id, " was defeated"," side was ", event.features["side"]
                if game_result_from_stderr != None:
                    if event.features["side"] == 1:
                        self.add_feature_to_dicts("data ai",game_result_from_stderr.ai_ident1,event.features)
                    else:
                        self.add_feature_to_dicts("data ai",game_result_from_stderr.ai_ident2,event.features)
                if event.fate == "survived":
                    self.add_feature_to_dicts("future survival",assumed_max_turns_per_game - event.features["turn"],event.features)
                else:
                    # print event.features["future survival"]
                    self.add_feature_to_dicts("future survival",int(event.features["future survival"]) - event.features["turn"],event.features)
                self.add_feature_to_dicts("data cost",event.cost,event.features)

            # self.features = sorted(self.features)  # Not a good idea to sort because values end up in different positions as the
            # file is processed
            # TODO:  This is a flaky way to sort self.features.  Should really do this with a comparator in the sort instead
            out_features = []
            for x in self.features:
                if (x in ["RECRUITED","friendly faction","enemy faction"] or x[0:4]  == "data" or x[0:6] == "future"):
                    out_features.append("_" + x)
                else:
                    out_features.append(x)

            out_features = sorted(out_features)
            final_out_features = []
            for x in out_features:
                if x[0] == "_":
                    final_out_features.append(x[1:])
                else:
                    final_out_features.append(x)

            self.features = final_out_features
            first_time = True
            final_output = ""
            for event in events:
                if first_time:
                    first_time = False
                    final_output += "SCHEMA:" + ", ".join(self.features)
                    final_output += "\n"
                outlist = []
                for x in self.features:
                    if x in event.features:
                        outlist.append(event.features[x])
                    else:
                        outlist.append("0")
                out = "%s" % outlist[0]
                for val in outlist[1:]:
                    out += ",%s" % val
                final_output += out + "\n"
            return final_output

    def process_game_stderr(self,stderr,game_result,start):
        for line in stderr.splitlines():
            str = self.filter_non_printable(line.strip())
            n,s = self.do_filter(str,'info ai/testing: WINNER:')
            if (n>-1):
                # print 'AND THE WINNER IS: '+s
                game_result.winner_side = s
                game_result.is_success = 'true'
                continue

            n,s = self.do_filter(str,'info ai/testing: VERSION:')
            if (n>-1):
                #print 'AND THE VERSION IS: '+s
                game_result.version_string = s
                n1 = s.rfind('(')
                n2 = s.rfind(')')
                if ((n1>-1) and (n2>-1) and (n2>n1)):
                    sz = s[n1+1:n2]
                    #parse local_modifications
                    n3 = sz.rfind('M')
                    if (n3>-1):
                        sz = sz[:n3]
                        game_result.local_modifications = 1
                    #parse svn_release
                    game_result.svn_release = sz
                continue

            n,s = self.do_filter(str,'info ai/testing: GAME_END_TURN:')
            if (n>-1):
                # print 'AND THE VICTORY_TURN IS: '+s
                game_result.end_turn = s
                continue

            n,s = self.do_filter(str,'info ai/testing: AI_IDENTIFIER1:')
            if (n>-1):
                #print 'AND THE AI_IDENTIFIER1 IS: '+s
                game_result.ai_ident1 = s.strip()
                continue

            n,s = self.do_filter(str,'info ai/testing: AI_IDENTIFIER2:')
            if (n>-1):
                #print 'AND THE AI_IDENTIFIER2 IS: '+s
                game_result.ai_ident2 = s.strip()
                continue

            n,s = self.do_filter(str,'info mp/connect: FACTION1:')
            if (n>-1):
                #print 'AND THE FACTION1 IS: '+s
                game_result.faction1 = s
                continue

            n,s = self.do_filter(str,'info mp/connect: FACTION2:')
            if (n>-1):
                #print 'AND THE FACTION2 IS: '+s
                game_result.faction2 = s
                continue
        game_result.duration = time() - start
        if (game_result.is_success!='true'):
            # TODO:  It gets to this spot when it's a draw.  Should be able to handle draws without throwing an error
            print 'Warning: not success!'
            print '===================='
            print 'stderr:'
            for line in stderr.splitlines():
                print self.filter_non_printable(line.strip())
            print '===================='

        return game_result

    def save_result(self,cfg,log_file,game_result):
        print 'Saving to log file....'
        print 'Game Duration: %0.1f seconds' % game_result.duration
        if (game_result.winner_side == "1"):
            losing_faction = game_result.faction2
            winning_faction = game_result.faction1
            winning_ai = game_result.ai_ident1
        else:
            losing_faction = game_result.faction1
            winning_faction = game_result.faction2
            winning_ai = game_result.ai_ident2

        log_file.write('"'+game_result.ai_config1+'", "'+game_result.ai_config2+'", "'+game_result.ai_ident1+'", "'+game_result.ai_ident2+'", "'+ str(game_result.duration)+'", "'+game_result.faction1+'", "'+game_result.faction2+'", "'+str(game_result.is_success)+'", "'+str(game_result.local_modifications)+'", "'+game_result.map+'", "'+str(game_result.svn_release)+'", "'+str(game_result.test)+'", "'+str(game_result.end_turn)+'", "'+str(game_result.version_string)+'", "'+str(game_result.winner_side)+'", "'+str(winning_faction)+'", "'+str(losing_faction)+'", "'+str(winning_ai)+"\n");
        log_file.flush();
        print 'WINNING FACTION:', winning_faction, "LOSING FACTION:", losing_faction, "WINNING AI:", winning_ai, "WINNING SIDE:", game_result.winner_side, "VICTORY TURN:", game_result.end_turn
        print 'Saved to log file'

def maps(cfg):
    mp = 1
    while 1:
        try:
            yield cfg.get('default','map' + repr(mp));
            mp= mp+1
        except:
            return



