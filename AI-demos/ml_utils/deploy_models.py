#!/usr/bin/env python
__author__ = 'SeattleDad'

from optparse import OptionParser
import re
import os
import shutil


usage = "Deploys all the models found in the source directory to the target directory.\n" +\
        "Usage: %prog [options] source_directory target_directory\n" + \
        "Example: %prog . ~/wesnoth/data/ai/models/"
parser = OptionParser(usage)

parser.add_option("-d", "--default_file", dest="default_file",default="default_gold_yield_2vc.json",
    help="Default file targeted by model.  Defaults to 'default_gold_yield_2vc.json'")

(options, args) = parser.parse_args()
if (len(args) != 2):
    parser.error("Incorrect number of arguments.  Requires a source and target directory as arguments. Run with --help for help")
source_dir = args[0]
target_dir = args[1]


for d in os.listdir(target_dir):
    for f in os.listdir(source_dir):
        if f.endswith(d + ".json"):
            print "Now deploying the model " + f + " to the directory " + d
            m = re.match("([^_]*)_" + d + ".json",f)
            assert m,"Badly formed source directory.  We are expecting factions there to be in sync with factions named in the target directory!"
            target_file_root = m.group(1)
            target_file_name = target_dir + "/" + d + "/" + target_file_root + ".json"
            shutil.copy(source_dir + "/" + f,target_file_name)
            shutil.copy(target_file_name,target_dir + "/" + d + "/" + options.default_file)



