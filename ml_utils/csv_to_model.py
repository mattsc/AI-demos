#!/usr/bin/env python

from optparse import OptionParser
import re
import os
from ml_utilities import sh_escape, get_schema_from_arff,do_command


usage = "Turns a normalized .csv file (produced by csv_normalizer.py) into a .arff file suitable for training " + \
    "and then trains a model on that file.  Note that unless run with the -a parameter, this will build a separate model " +\
    "for each faction.  Note that this command currently requires that it be issued in the directory in which input.csv resides.\n" + \
    "usage: %prog [options] input.csv"
parser = OptionParser(usage)
parser.add_option("-m", "--metric", dest="metric",default="'future xp+vc'",
                  help="Metric targeted by machine learner")
parser.add_option("-d","--default", dest="retain_default",default=False,action="store_true",help="Retain training events" + \
                    " produced by the default (non-machine learning) model.  Default is to delete these events.")
parser.add_option("-a","--all_factions",dest="no_faction",action="store_true",default=False,help="Build a model which works " + \
                "for all factions.  Defaults to build a separate model for each factions.")
parser.add_option("-k","--keep",dest="retain_temporary",help="Retain temporary files?",action="store_true",default=False)
parser.add_option("-r","--recruited_multiple",dest="dont_use_RECRUITED",help= " If this flag is set, then RECRUITED is dropped " + \
                "and all the 'recruited x' features are retained. Otherwise, we " + \
                "use a single feature for RECRUITED.  All features of the form 'recruited x' are dropped. "
                 ,action="store_true",default=False)
parser.add_option("-n","--neural_net_parm",dest="neural_net_parms",default="-addlayer 14",
                help="Parameters to pass to the neural net trainer.  Defaults to build a neural net with 14 hidden layers, " + \
                "via the parameter '-addlayer 14'")

strip_quotes = re.compile('[%s]' % re.escape("'"))
space_to_underscore = re.compile('[ ]')

def back_end_process(prefix,base_prefix,faction=""):
    """Do processing specific to a faction or else process a file for "all".  """

    # This command is needed to, in particular, strip out unneeded values from the RECRUITED column
    command = "waffles_transform dropunusedvalues " +  sh_escape(prefix) + ".arff"
    step1 = strip_quotes.sub('', prefix)
    clean_prefix = space_to_underscore.sub("_",step1)

    if not faction:
        matched = re.match("__[^_]*_(.*)",clean_prefix)
        faction = matched.group(1)
    print "Now processing the faction: " + str(faction)
    temp4_filename = "__temp4_" + faction +  ".arff"
    do_command(command,True,temp4_filename)

    final_prefix = base_prefix + "_" + faction

    command = "waffles_transform drophomogcols {0}".format(temp4_filename)
    do_command(command,True,final_prefix + ".arff")


    command = "waffles_learn train -seed 0 {0}.arff neuralnet {1}".format(final_prefix,options.neural_net_parms)
    do_command(command,True,final_prefix +  ".json")


(options, args) = parser.parse_args()
if (len(args) != 1):
    parser.error("Incorrect number of arguments.  Requires one .csv file as an argument. Run with --help for help")

input_file = args[0].strip()
current_directory = "."
assert input_file.endswith(".csv"),"Input must be a .csv file!"
assert input_file in os.listdir(current_directory), input_file + " not found in current directory!"
m = re.match("(.*)\.csv",input_file)
file_prefix = m.group(1)

temp0_file = "__temp0.csv"
if temp0_file not in os.listdir(current_directory):
    if options.retain_default:
        command = "cp " + sh_escape(input_file) + temp0_file
        do_command(command,True)
    else:
        command = "grep -v default " + sh_escape(input_file)
        do_command(command,True,temp0_file)


main_arff_file = file_prefix + ".arff"
if main_arff_file not in os.listdir(current_directory):
    command = "waffles_transform import {0} -columnnames".format(temp0_file)
    do_command(command,True,main_arff_file)


     
columns = get_schema_from_arff(main_arff_file)
metric = columns.index(options.metric)
command = 'waffles_transform swapcolumns ' + main_arff_file + " " +  str(metric) + " " + str(len(columns) -1)
temp2_file = "__temp2.arff"
if temp2_file not in os.listdir(current_directory):
    do_command(command,True,temp2_file)

columns = get_schema_from_arff(temp2_file)
delete_columns = []
# We want to delete all columns with "future" or "data" except for the last one, which is the output value of our ML model
for i in range(0,len(columns)-1):
    if re.search("^('future |'data )",columns[i]):
        delete_columns.append(i)
        
if options.dont_use_RECRUITED:
    kill_recruit = "RECRUITED"
else:
    kill_recruit = "recruited "
    
kill_string = "^'" + kill_recruit
for i in range(0,len(columns)-1):
    if re.search(kill_string,columns[i]):
        delete_columns.append(i)
 
strs = [str(x) for x in delete_columns]       
command = "waffles_transform dropcolumns " + temp2_file  + " " + ",".join(strs)
split_base = "__temp3"
temp3_file = split_base + ".arff"
if temp3_file not in os.listdir(current_directory):
    do_command(command,True,temp3_file)

if not options.no_faction:
    columns = get_schema_from_arff(temp3_file)
    command = "waffles_transform splitclass " + temp3_file + " " + str(columns.index("'friendly faction'")) + " -dropclass"
    if not any([x.startswith(split_base + "_") for x in os.listdir(current_directory)]):
        do_command(command,True)

if options.no_faction:
    back_end_process(split_base,file_prefix,"all")
else:
    for file in os.listdir("."):
        if file.startswith(split_base + "_") and file.endswith(".arff"):
            back_end_process(file[0:-5],file_prefix)

if not options.retain_temporary:
    removable_files = os.listdir(".")
    removable_files = [x for x in removable_files if x.startswith("__temp")]
    print "Now removing the following temporary files: " + str(removable_files)
    for f in removable_files:
            os.remove(f)





