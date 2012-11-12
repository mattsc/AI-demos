#!/usr/bin/env python
from subprocess import Popen,PIPE
from time import time, sleep
from datetime import datetime
import ConfigParser
import random
import sys
import os
import ml_utilities
from process_output_for_ml import *

class GameResult:
    ai_config1 = ''
    ai_config2 = ''
    ai_ident1 = ''
    ai_ident2 = ''
    duration = '0'
    faction1 = ''
    faction2 = ''
    is_success = 'false'
    local_modifications = 'false'
    map = ''
    svn_release = '0'
    test = 'default'
    end_turn = '0'
    version_string = ''
    winner_side = '0'

    def __init__(self,_ai_config1,_ai_config2,_faction1,_faction2,ml_ai_parms1,ml_ai_parms2,_map,_test):
        self.ai_config1 = _ai_config1
        self.ai_config2 = _ai_config2
        self.faction1 = _faction1
        self.faction2 = _faction2
        self.ml_ai_parms1 = ml_ai_parms1
        self.ml_ai_parms2 = ml_ai_parms2
        self.map = _map
        self.test = _test

def filter_non_printable(str):
    return ''.join(c for c in str if ord(c) > 31 or ord(c) == 9)

def build_ml_ai_parms(cfg,side):
    single_model = metric_cost_power = model = model_directory = False
    temp = cfg.get("default","single_model" + str(side))
    if temp:
        single_model = cfg.getboolean("default","single_model" + str(side))
        if single_model:
            single_model = "single_model=True"
    temp = cfg.get("default","model" + str(side)).strip()
    if temp:
        model = "model=" + temp

    temp=cfg.get("default","metric_cost_power" + str(side))
    if temp:
        temp=cfg.getfloat("default","metric_cost_power" + str(side))
        metric_cost_power="metric_cost_power=" + str(temp)
    temp=cfg.get("default","model_directory")
    if temp:
        temp=cfg.getfloat("default","model_directory" + str(temp))
        model_directory="model_directory=" + str(temp)
    retval = ""
    if single_model or model or metric_cost_power or model_directory:
        retval = "--parm {0}:user_team_name:"
        first_time = True
        for j in [single_model,model,metric_cost_power,model_directory]:
            if j:
                if not first_time:
                    connector = "^"
                else:
                    connector = ""
                    first_time = False
                retval += connector + j
    return retval





def construct_command_line(cfg,game):
    wesnoth = cfg.get('default','path_to_wesnoth_binary')
    options= cfg.get('default','arguments_to_wesnoth_binary')
    ai_config1='--ai-config 1:'+ game.ai_config1
    ai_config2='--ai-config 2:'+ game.ai_config2
    if (game.faction1):
        faction1 = ' --side 1:' + game.faction1
    else:
        faction1 = ''
    if (game.faction2):
        faction2 =  ' --side 2:' + game.faction2
    else:
        faction2 = ''
    if (game.map==''):
        optmap=''
    else:
        optmap='--scenario '+ game.map
    # Note:  The below gold override logic should be removed once the following bug is fixed:  https://gna.org/bugs/?19895
    dont_override_map_string = cfg.get('default','maps_where_gold_should_not_be_overridden')
    maps_where_gold_should_not_be_overridden = dont_override_map_string.split(",")
    maps_where_gold_should_not_be_overridden = [x.strip() for x in maps_where_gold_should_not_be_overridden]
    if game.map != '' and game.map.strip() in maps_where_gold_should_not_be_overridden:
        gold_override = ''
    else:
        gold_override = cfg.get('default','gold_override')

    return wesnoth+' '+options+' '+optmap+' '+ gold_override + ' '+ai_config1+' '+ai_config2 + " " + faction1 + " " + faction2 + " " +\
           game.ml_ai_parms1.format(1) + " " + game.ml_ai_parms2.format(2)

def do_filter(str,substring):
    n = str.find(substring)
    if (n>-1):
        return n,str[n+len(substring):].strip()
    return n,''

def run_game(cfg,game_result):

    command_line = construct_command_line(cfg,game_result)
    print 'Running: '+command_line
    command_obj = ml_utilities.Command(command_line)
    start = time()
    max_time = cfg.get('default',"max_run_time")
    stdout = ""
    stderr = ""
    stdout, stderr, returncode =  command_obj.run(int(max_time))
    if returncode == "timeout":
        print "Timeout!!!!!!!!!!!  Game terminated after {0} seconds".format(max_time)
        game_result.is_success = "timeout"

    print 'Finished'
    return (stderr,stdout,start)

def maps(cfg):
    mp = 1
    while 1:
        try:
            yield cfg.get('default','map' + repr(mp));
            mp= mp+1
        except:
            return

def tests(cfg):
    ai1=cfg.get('default','ai_config1').strip()
    ai2=cfg.get('default','ai_config2').strip()
    f1=cfg.get('default','faction1').strip()
    f2=cfg.get('default','faction2').strip()
    ml_ai_parms1 = build_ml_ai_parms(cfg,1)
    ml_ai_parms2 = build_ml_ai_parms(cfg,2)
    n=cfg.getint('default','number_of_tests')
    randomly_choose_sides = cfg.getboolean('default','randomly_choose_sides')
    maplist = []
    for map in maps(cfg):
        maplist.append(map)
    random.seed()
    for i in range(0, n):
        map = random.choice(maplist)
        if randomly_choose_sides:
            d = random.randint(0,1)
        else:
            d = 0
        print 'TEST: map '+map+' game '+str(i + 1)+ " of " + str(n)
        if (d==0):
            game_result = GameResult(ai1,ai2,f1,f2,ml_ai_parms1,ml_ai_parms2,map,'default')
        else:
            game_result = GameResult(ai2,ai1,f2,f1,ml_ai_parms2,ml_ai_parms1,map,'default')
        yield game_result

def write_compressed(cfg,stdout,stderr,i,):
    pass

# main

if len(sys.argv) != 2:
    print "ai_test2.py"
    print "Test harness for running and logging Battle for Wesnoth in nogui mode.  Run as follows:"
    print "ai_test2.py my_file.cfg"
    print "For an example .cfg file see wesnoth/utils/ai_test/ai_test2.cfg"
else:
    cfg = ConfigParser.ConfigParser()
    cfg.read(sys.argv[1])

    processor = OutputProcessor()

    log_file_name = datetime.now().strftime(cfg.get('default','log_file').strip())
    if os.path.isfile(log_file_name):
        print "Log file already exists.  Waiting a minute to start."
        sleep(60)
        log_file_name = datetime.now().strftime(cfg.get('default','log_file').strip())
        assert not os.path.isfile(log_file_name),"File name already exists!!!!!"

    log_file = open(log_file_name  , 'w')
    log_file.write('"ai_config1"'+', '+'"ai_config2"'+', '+'"ai_ident1"'+', '+'"ai_ident2"'+', '+ '"duration"'+', '+ \
                   '"faction1"'+', '+'"faction2"'+', '+'"is_success"'+', '+'"local_modifications"'+', '+'"map"'+', '+ \
                   '"svn_release"'+', '+'"test"'+', '+'"end_turn"'+', '+'"version_string"'+', '+'"winner_side"'+', '+ \
                   '"winner_faction"'+', '+'"loser_faction"'+', '+'"winner_ai"'+'\n');
    log_file.flush();
    ml_log_file_name = datetime.now().strftime(cfg.get('default','feature_file').strip())
    ml_log_file = None
    for test in tests(cfg):
        (stderrlines,stdoutlines,time_started) = run_game(cfg,test)
        game_result = processor.process_game_stderr(stderrlines,test,time_started)
        processor.save_result(cfg,log_file,game_result)
        ml_output = processor.process_game_stdout(stderrlines,ml_log_file,game_result)
        if ml_output:
            if ml_log_file == None:
                ml_log_file = open(ml_log_file_name  , 'w')
            ml_log_file.write(ml_output)
