#!/usr/bin/env python
import re
# from ml_utilities import sh_escape, get_schema_from_arff,do_command
from csv_normalizer import CSVNormalizer
from optparse import OptionParser
import fileinput
        
usage = "%prog [options] input.csv output.csv \nTurns a .csv file that contains 'recruited x' features into one in which the recruited unit is added to the 'friendly x' count."
parser = OptionParser(usage)
parser.add_option("-d", "--drop-recruited", dest="drop_recruited",default=False,action="store_true",
                  help="Drop RECRUITED and 'recruited x' features")

(options, args) = parser.parse_args()
if (len(args) != 2):
    parser.error("Incorrect number of arguments.  Requires two arguments. Run with --help for help")
    
input_file = args[0]
output_file = open(args[1],"w")

file_normer = None
last_feat_value_count = -2  # Initialize with bogus value
for line in fileinput.input([input_file]):
    if re.search("^SCHEMA:|friendly",line):
        file_normer = CSVNormalizer()
        list_of_feats = file_normer.get_list_of_feats_from_schema_row(line)
        file_normer.add_features_to_index(list_of_feats) 
        if options.drop_recruited:
            output_feats = [x.strip() for x in list_of_feats if x != "RECRUITED" and not x.startswith("recruited ")]
        else:
            output_feats = list_of_feats
        output_file.write(",".join(output_feats))
        output_file.write("\n")
        last_feat_value_count = -1 
    else:
        assert(file_normer) 
        feat_values = line.split(",")
        assert (last_feat_value_count == -1 or len(feat_values) == last_feat_value_count), \
           "Inconsistent number of values for the following row.  Previous row had " + str(last_feat_value_count) + \
           " values. This row has " + str(len(feat_values)) + " values.  The offending line is: \n" + line
        last_feat_value_count = len(feat_values)
        feat_dict = file_normer.feat_values_to_dict(feat_values)
        assert "RECRUITED" in feat_dict,"This has to be run on a .csv file which contains the 'RECRUITED' feature."
        recruited_unit = feat_dict['RECRUITED']
        new_unit = 'friendly ' + recruited_unit
        if new_unit in feat_dict:
            feat_dict[new_unit] = str(int(feat_dict[new_unit]) + 1)
        else:
            feat_dict[new_unit] = "1"
#        if options.drop_recruited:
#            kill_values = [x for x in feat_dict.keys() if x == "RECRUITED" or x.startswith("recruited ")]
#            for i in kill_values:
#                del feat_dict[i]
        
        out_feat_values = [feat_dict[x].strip() for x in output_feats]
        
        output_file.write(",".join(out_feat_values))
        output_file.write("\n")


    
        
        
    
    
                