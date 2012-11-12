#!/usr/bin/env python

import re
from optparse import OptionParser
import fileinput

usage = """
Copies over only the code needed to run predict methods in Battle for Wesnoth by stripping out all the code that's enclosed by MIN_PREDICT.
Usage:  copy_predict_only_waffles.py [options] [files]

Note that 'files' is optional.  If left blank, this will process the following files from source_dir:
GActivation.cpp         GDom.h                  GHolders.cpp            GMatrix.h               GTokenizer.cpp          GVec.h
GActivation.h           GError.cpp              GHolders.h              GNeuralNet.cpp          GTokenizer.h
GBitTable.cpp           GError.h                GLearner.cpp            GNeuralNet.h            GTransform.cpp
GBitTable.h             GHeap.cpp               GLearner.h              GRand.cpp               GTransform.h
GDom.cpp                GHeap.h                 GMatrix.cpp             GRand.h                 GVec.cpp
"""

parser = OptionParser(usage)
parser.add_option("-s","--source_dir",dest="source_dir",help="Directory you are copying from")
parser.add_option("-t","--target_dir",dest="target_dir",help="Directory you are copying to")
(options, args) = parser.parse_args()
if len(args) == 0:
    args = ["GActivation.h","GActivation.cpp","GBitTable.h","GBitTable.cpp","GDom.h","GDom.cpp","GError.h","GError.cpp","GHeap.h","GHeap.cpp",
            "GHolders.h","GHolders.cpp","GLearner.h","GLearner.cpp","GMatrix.h","GMatrix.cpp","GNeuralNet.h","GNeuralNet.cpp","GRand.h",
            "GRand.cpp","GTokenizer.h","GTokenizer.cpp","GTransform.h","GTransform.cpp","GVec.h","GVec.cpp"]
    
def skip_recursive(regex,the_lines,the_index,filename,recursion_level,out_file):
    assert recursion_level < 10,"Excessive recursion.  Probably bad syntax in " + out_file
    while the_index < len(the_lines):
        # if (the_index % 100) == 0:
        #    print "Now processing line", the_index
        line = the_lines[the_index]
        assert (the_index < len(the_lines)),"Mismatched #ifndef/#endif pair detected at end of" + filename
        if re.search(regex,line):
            return the_index+1
        elif re.search("^\s*#if",line):  
            # We have detected a new if, so we need to find the matching #end
            the_index = skip_recursive("^\s*#endif",the_lines,the_index+1,filename,recursion_level + 1,out_file)
        elif re.search("^\s*#else",line) and recursion_level == 0:
            # Note that this clause is not exercised in the Waffles build as of 20120729
            print "We detected a top-level else at line", the_index
            the_index += 1
            while not re.search("^\s*#endif",line):
                assert not re.search("^\s*#",line),"We are assuming that no other compiler directives are embedded inside a top-level 'else'"
                assert (index < len(the_lines)),"Mismatched #else/#endif pair detected at end of" + filename
                out_file.write(line)
                the_index += 1
        else:
            the_index += 1
    print "Warning!  Didn't find matching 'end' in", filename
    return the_index
    
for filename in args:
    in_file = open(options.source_dir + "/" + filename,"r")
    print "Now processing", filename
    out_file = open(options.target_dir + "/" + filename,"w")
    lines = in_file.readlines()
    # print "Read the lines for", filename, "  Now processing it"
    index = 0
    while (index < len(lines)):
        line = lines[index]
        if re.search("^\s*#ifndef.*MIN_PREDICT\s+$",line):
            # Note that we don't print out the line here
            index = skip_recursive("^\s*#endif\s+//.*MIN_PREDICT\s+$",lines,index + 1,filename,0,out_file)
        else:
            out_file.write(line)
            index += 1
            
