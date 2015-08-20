#!/usr/bin/env python

import sys
import re

from csv_normalizer  import CSVNormalizer
from optparse import OptionParser

usage = "Analyzes recruitment in a .csv file or files and prints out subtotals.\n" +\
        "usage: %prog [options] *.csv\n\n" +\
        "Example usage:\n" +\
        "%prog *.csv -s \'enemy faction\'   (Subtotals by enemy faction)  \n" +\
        "%prog *.csv -s \'enemy faction\' -i 'friendly faction:Rebels'  (Subtotals by enemy faction, but only includes Rebel recruits)  \n" +\
        "%prog *.csv -s 'friendly Drake Burner:enemy Wose'  -i 'friendly faction:Drakes' (Subtotals by # of Drake Burners and then by # of enemy Wose)"

parser = OptionParser(usage)
parser.add_option("-s", "--subtotals", dest="subtotals",default="",
    help="Fields to subtotal by, separated by colons.")
parser.add_option("-d","--default_ai",dest="opposing_ai",default="default_ai_with_recruit_log",help="AI you are opposing.  Reports results for the AI that is *not* this AI.")
parser.add_option("-i","--include",dest="include",default=False,help="Feature:value pair you are including, separated by colon.  I.e.  'friendly faction:Drakes'")

def recursive_print(recruit_dict,level,subtotal_fields):
    level = level + 1
    indent = "\t" * (level -1)
    # print "level is", level
    new_dict = {}
    if level <= len(subtotal_fields):
        for key in sorted(recruit_dict.keys()):
            print "{0}Results for {1}:{2}".format(indent,str(subtotal_fields[level-1]),key)
            temp_dict = recursive_print(recruit_dict[key],level,subtotal_fields)
            for key in temp_dict.keys():
                if not key in new_dict.keys():
                    new_dict[key] = 0
                new_dict[key] += temp_dict[key]
    else:
        new_dict = recruit_dict
    # print "new dict is: " + str(new_dict)


    if level == 1:
        print "Grand Totals"

    faction_totals = {}
    for key in new_dict.keys():
        faction = key.split("|")[0]
        if faction not in faction_totals:
            faction_totals[faction] = 0
        faction_totals[faction] += new_dict[key]
    old_faction = "__first_time"
    for key in sorted(new_dict.keys()):
        assert(type(new_dict[key]) is int)
        (faction,unit) = key.split("|")
        if faction != old_faction:
            if old_faction != "__first_time":
                print "{0}{1:30}\t{2:d}\n".format(indent,"Total:",faction_totals[old_faction])
            print "{0}{1:30}\tCount\t%".format(indent,faction + " Recruitment",key)
            old_faction = faction
        print "{0}{1:30}\t{2:>d}\t{3:>.1%}".format(indent,unit,new_dict[key],float(new_dict[key])/faction_totals[faction])
    print "{0}{1:30}\t{2:>d}\n".format(indent,"Total:",faction_totals[faction])
    return new_dict
        
if __name__ == "__main__":
    (options, args) = parser.parse_args()
    if options.include:
        include_field_value = options.include.split(":")
        assert(len(include_field_value) == 2)
        include_field_value = [x.strip() for x in include_field_value]
        include_field_value = [x.strip() for x in include_field_value]
        # print include_field_value
    else:
        include_field_value = None
    subtotals = {}
    subtotal_fields = []
    for j in options.subtotals.split(":"):
        if j:
            subtotal_fields.append(j)
    if len(args) < 1:
        parser.error("You must specify at least one .csv file.  Run with --help for help.")
    normer = CSVNormalizer()
    for filename in args:
        f = open(filename,"r")
        lines = f.readlines()
        file_normer = None
        last_feat_value_count = -1
        for line in lines:
            if re.search("^SCHEMA:|friendly",line):
                file_normer = CSVNormalizer()
                list_of_feats = file_normer.get_list_of_feats_from_schema_row(line)
                file_normer.add_features_to_index(list_of_feats) 
                last_feat_value_count = -1  
            else:
                assert(file_normer) 
                feat_values = line.split(",")
                if last_feat_value_count != -1 and len(feat_values) != last_feat_value_count:
                   print "Warning!!!!  Inconsistent number of values for the following row.  Previous row had " + str(last_feat_value_count) + \
                   " values. This row has " + str(len(feat_values)) + " values.  The offending line is: \n" + line
                   continue
                last_feat_value_count = len(feat_values)
                feat_dict = file_normer.feat_values_to_dict(feat_values)
                if feat_dict["data ai"] != options.opposing_ai and \
                    (not include_field_value or feat_dict[include_field_value[0]] == include_field_value[1]):
                    curdict = subtotals
                    for j in subtotal_fields:
                        if str(feat_dict[j]) not in curdict:
                            curdict[str(feat_dict[j])] = {}
                        curdict = curdict[str(feat_dict[j])]
                    faction_recruited = feat_dict["friendly faction"] + "|" + feat_dict["RECRUITED"]
                    if faction_recruited not in curdict:
                        curdict[faction_recruited] = 0
                    curdict[faction_recruited] += 1
    # print "subtotals is: " + str(subtotals)

    recursive_print(subtotals,0,subtotal_fields)


                
                
            
    
        
        
    
    
                