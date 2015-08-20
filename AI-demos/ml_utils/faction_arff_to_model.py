#!/usr/bin/env python

from optparse import OptionParser
import subprocess
import re
from ml_utilities import sh_escape, get_schema_from_arff,do_command

# def sh_escape(s):
#    return s.replace("(","\(").replace(")","\)").replace(" ","\ ").replace("'","\'").replace('"','\"')


usage = "Turns a normalized .csv file (produced by csv_normalizer) into a .arff file suitable for training\n" + \
    "usage: %prog [options] input.arff"
parser = OptionParser(usage)
parser.add_option("-f","--faction",dest="faction",help="Faction you want to learn a model for.  Defaults to build a model for all factions.")
parser.add_option("-r","--retain",dest="retain_temporary",help="Retain temporary files?",action="store_true",default=False)
(options, args) = parser.parse_args()

if options.faction == "'Knalgan Alliance'":
    faction = Knalgan
else:
    faction = options.faction

# Strip out unneeded values from the RECRUITED column
command = "waffles_transform dropunusedvalues " +  sh_escape(args[0]) + "_" + sh_escape(args[1])
do_command(command,True,"__temp10_" +  faction +  ".arff")

command = "waffles_transform drophomogcols __temp10_" + faction + ".arff"
do_command(command,True,"__temp11_" + faction + ".arff")

command = "waffles_learn train -seed 0 __temp11_{0}.arff neuralnet -addlayer {1:d}".format(faction,options.layers)
do_command(command,True,""     "__temp11_" + faction + ".arff")


if not options.retain_temporary:
    subprocess.call("rm __temp1* __temp2.arff __temp3.arff __temp4.arff",shell=True)



