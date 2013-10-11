#!/usr/bin/env python

from optparse import OptionParser
import re
import os
from ml_utilities import sh_escape, do_command
from subprocess import Popen
from time import sleep


usage = "Runs a model on n processors and then builds a new model.  Finally it deploys the model in the deployment\n " + \
    "directory, giving the model a name derived from the model_directory.  \n\n" +\
    "usage: %prog [options] your_ai_test2.config model_directory deployment_directory \n\n" +\
    "Example usage:  %prog ai_test2.config ~/mymodels/model7/ ~/wesnoth/data/ai/models/ -c  ~/mymodels/model6/model6.csv\n\n " + \
    "This will result in an appropriate model7.json file being created in ~/wesnoth/data/ai/models/Drakes/, ~/wesnoth/data/ai/models/Rebels/, etc. \n" +\
    "Also, a copy of these models will be created in each of these directories called 'default_gold_yield_2vc.json'"
parser = OptionParser(usage)
parser.add_option("-m", "--metric", dest="metric",default="'future gold yield+2vc'",
                  help="Metric targeted by machine learner.  Default:  'future gold yield+2vc'")
parser.add_option("-d", "--default_file", dest="default_file",
    help="Default file targeted by model.  Defaults to 'default_gold_yield_2vc.json'")
parser.add_option("-p","--processors",dest="processors",default=2,type="int",help="Number of processors you want to use. (default: 2)")
parser.add_option("-c","--old_csv",dest="old_csv",default="",help="Old .csv file that you want to add to the new .csv file.")

strip_quotes = re.compile('[%s]' % re.escape("'"))
space_to_underscore = re.compile('[ ]')

(options, args) = parser.parse_args()
if len(args) != 3:
    parser.error("Incorrect number of arguments.  Requires four arguments. Run with --help for help")

ai_test_file = args[0].strip()
model_dir = args[1].strip()
deploy_dir = args[2].strip()

assert os.path.isfile(ai_test_file),"The ai_test2 configuration file named " + ai_test_file + " doesn't exist!"
assert os.path.isdir(deploy_dir),"Deployment directory doesn't exist!"
if options.old_csv:
    assert os.path.isfile(options.old_csv),"--old_csv file given, but the file doesn't exist!"


command = "ai_test2.py " + ai_test_file
jobs = []
for i in xrange(options.processors):
    print command
    jobs.append(Popen(command,shell=True))
    sleep(61)  # Need to wait one minute to avoid having both jobs write to the same time-stamped log file

all_done = False
while not all_done:
    all_done = all(q.poll() != None for q in jobs)
    sleep(10)

assert all(not p.poll() for p in jobs),"Error in ai_test2.py!!!!  Aborting job."

if not os.path.isdir(model_dir):
    os.mkdir(model_dir)

base_file_name = model_dir.strip("/").split("/")[-1]
command = "csv_normalizer.py {0} *.csv ".format(options.old_csv,base_file_name)
normalized_csv = "{0}/{1}.csv".format(model_dir,base_file_name)
do_command(command,True,normalized_csv)
olddir = os.getcwd()
os.chdir(model_dir)

metric = """-m "'{0}'" """.format(options.metric.strip("""'" """))  # Have to strip off, then put back on quotes and spaces
command = "csv_to_model.py {0} {1}".format(base_file_name + ".csv", metric)
do_command(command,True)
os.chdir(olddir)

if options.default_file:
    default_file = " -d " + options.default_file
else:
    default_file = ""

command = "deploy_models.py {0} {1} {2}".format(default_file,model_dir,deploy_dir)
do_command(command,True)
print "Model built and deployed to " + deploy_dir


