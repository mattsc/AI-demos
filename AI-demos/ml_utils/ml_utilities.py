#!/usr/bin/env python
import subprocess
import re
import sys
import time

from subprocess import Popen,PIPE


def sh_escape(s):
    return '"' + s + '"'

def get_schema_from_arff(my_file):
    schema = []
    the_file = open(my_file,"r")
    for line in the_file:
        matcher = re.match("^@ATTRIBUTE\s+(.*)(real|\{)",line)
        if matcher:
            schema.append(matcher.group(1))
        elif re.match("^@DATA",line):
            break
    schema = [x.strip() for x in schema]
    return schema

def get_schema_from_csv(my_file):
    the_file = open(my_file,"r")
    first = the_file.readline()
    fields = first.strip().split(",")
    fields = [x.strip() for x in fields]
    return fields
    
    
def do_command(command_list_or_string,shell_flag,stdout_redirect_to_file=None):
    if (stdout_redirect_to_file):
        the_file = open(stdout_redirect_to_file,"w")
    else:
        the_file = None
    if stdout_redirect_to_file:
        stdout_print_string = " [stdout being printed to " + str(stdout_redirect_to_file) + "]"
    else:
        stdout_print_string = " [stdout being printed to stdout]"
    print command_list_or_string, stdout_print_string
    retval=subprocess.call(command_list_or_string,shell=shell_flag,stdout=the_file)
    assert retval==0,"Bad return value from subprocess call"
    if (stdout_redirect_to_file):
        the_file.close()

def print_percentages(command,fields,splitval):
    p = Popen(command, shell=True, bufsize=100000, stdout=PIPE)
    stdoutlines = p.stdout.readlines()
    total = 0.0
    for line in stdoutlines:
        data = line.strip().split()
        total += float(data[0])
    for line in stdoutlines:
        line = line.strip()
        m = re.search('(\d+)(.*)',line)
        first = m.group(1)
        rest = m.group(2).strip()
        output_list = [rest.split(splitval)[i] for i in fields]
        output = "\t".join(output_list)
        output = first + "\t" + output
        print "%-3.1f%%\t%s" % ((float(first) * 100)/total,output)
    print "Total:\t%d" % total

class Timeout(Exception):
    pass

def run_with_timeout(command, timeout=10):
    proc = subprocess.Popen(command, bufsize=100000000, stdout=PIPE, stderr=PIPE,shell=True)
    poll_seconds = .250
    deadline = time.time()+timeout
    while time.time() < deadline and proc.poll() == None:
        print "Now polling proc"
        time.sleep(poll_seconds)
    print "Program completed, now checking if it succeeded"

    if proc.poll() == None:
        if float(sys.version[:3]) >= 2.6:
            proc.terminate()
        raise Timeout()
    else:
        print "Program completed successfully!"
    stdout = proc.stdout.readlines()
    stderr = proc.stderr.readlines()
    return stdout, stderr, proc.returncode

import threading

class Command(object):
    def __init__(self, cmd):
        self.cmd = cmd
        self.process = None
        self.stdout = ""
        self.stderr = ""

    def run(self, timeout):
        def target():
            # print 'Thread started'
            self.process = subprocess.Popen(self.cmd, bufsize=100000000, stdout=PIPE, stderr=PIPE,shell=True)
            (self.stdout,self.stderr) = self.process.communicate()
            # print 'Thread finished'
        thread = threading.Thread(target=target)
        thread.start()
        thread.join(timeout)
        if thread.is_alive():
            print 'Terminating process'
            self.process.terminate()
            thread.join()
            self.returncode = "timeout"
        else:
            self.returncode = self.process.returncode
        return self.stdout, self.stderr, self.returncode