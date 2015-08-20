#!/usr/bin/env python

import sys
import re

class CSVNormalizer:
    known_features = set()
    feature_list = []
    default_value = 0  # This is the default field value when we don't have a value for the field
    
    def __init__(self):
        self.known_features = set()
        self.feature_list = []

    def add_features_to_index_from_file_headers(self,file_list):
        # print "file_list", file_list
        feature_lists_from_headers = [x for x in self.get_last_headers(file_list)]
        # print "feature_lists_from_headers", feature_lists_from_headers
        for feature_list in feature_lists_from_headers:
                self.add_features_to_index(feature_list)

    def add_features_to_index(self,features):
        for f in features:
            if f in self.known_features:
                pass
            else:
                self.known_features.add(f) 
                self.feature_list.append(f)
    
    def get_feature_list(self):
        return self.feature_list
    
    def get_csv_header(self):
        return ", ".join(self.feature_list)
    
    def feat_values_to_dict(self,values):
        my_dict = {}
        for i in range(len(values)):
            my_dict[self.feature_list[i]] = values[i]
        return my_dict
    
    def feature_dict_to_csv_row(self,feature_dict):
        row = []
        for f in self.feature_list:
            if f in feature_dict:
                printval = feature_dict[f]
                if type(printval) == str:
                    printval = printval.strip()
                row.append(printval)
            else:
                row.append(self.default_value)
        out = "%s" % row[0]
        for val in row[1:]:
            out += ",%s" % val
        return out
    
    def get_list_of_feats_from_schema_row(self,line):
        match = re.match("^SCHEMA:(.*)",line)
        if not match:
            if re.search("friendly",line):
                match = re.match("^(.*)",line)
        assert match,"Missing schema row.  Expecting 'SCHEMA' or 'friendly' to signify a header row"
        header = match.group(1)
        list_of_feats = header.split(",")
        list_of_feats = [x.strip() for x in list_of_feats]
        return list_of_feats
            
    
    def get_last_headers(self,file_list):
        """
        Return the last header line in each csv file.
        We want to do this because we create multiple headers in each csv file, adding on fields to the header as we detect them
        """
        for f in file_list:
            g = open(f,'r')
            lines = g.readlines()
            header = None
            for line in lines:
                if re.match("^SCHEMA:(.*)",line) or re.search("friendly",line) :
                    header = line
            assert header,"CSV file doesn't have schema row (expecting 'SCHEMA' or 'friendly' to signify header row)"
            list_of_feats = self.get_list_of_feats_from_schema_row(header)
            yield list_of_feats
        
        
if __name__ == "__main__":
    if len(sys.argv) == 1 or "--help" in sys.argv or "-h" in sys.argv:
        print "Turns one or more irregular .csv files produced by wesnoth ml test harness into a single standard csv file "
        print "The resulting csv file is written to stdout"
        print "USAGE:  csv_normalizer.py file1.csv file2.csv ..."
        sys.exit(0)
    normer = CSVNormalizer()
    future_game_number_name = 'future game number'
    normer.add_features_to_index([future_game_number_name])
    normer.add_features_to_index_from_file_headers(sys.argv[1:])
    print normer.get_csv_header()
    forbidden_pairs = [("friendly Fencer","friendly Skeleton"),("friendly Thunderer","Friendly Drake Glider"),("friendly Orcish Grunt", "friendly Wose")]
    game_number = 0
    last_turn = 1000
    for filename in sys.argv[1:]:
        sys.stderr.write("Now processing " + filename + "\n")
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
                assert (last_feat_value_count == -1 or len(feat_values) == last_feat_value_count), \
                   "Inconsistent number of values for the following row.  Previous row had " + str(last_feat_value_count) + \
                   " values. This row has " + str(len(feat_values)) + " values.  The offending line is: \n" + line
                last_feat_value_count = len(feat_values)
                feat_dict = file_normer.feat_values_to_dict(feat_values)
                assert "turn" in feat_dict, ("Didn't find 'turn' in feature dictionary for dictionary.  Check to see if you have a truncated line at the end of the file being processed: " + str(feat_dict))
                if int(feat_dict["turn"]) < last_turn:
                    game_number += 1
                last_turn = int(feat_dict["turn"])
                feat_dict[future_game_number_name] = game_number
                for (a,b) in forbidden_pairs:
                    # TODO:  Make this parameterized in config
                    # We aren't expecting any of these units to be on the same side.  Comment out if usual foes are opposing
                    assert not (a in feat_dict and b in feat_dict and int(feat_dict[a]) > 0 and int(feat_dict[b]) > 0), \
                       ("Don't expect " + a + " and " + b + " to be on the same side!") 
                csv_row = normer.feature_dict_to_csv_row(feat_dict)
                print csv_row
                
                
            
    
        
        
    
    
                