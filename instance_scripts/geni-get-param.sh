#!/bin/bash

# http://docs.cloudlab.us/advanced-topics.html#%28part._geni-get-param%29
# 10.5.5 Profile parameters
# geni-get "param name"
#
# does not work

param=$1
ns="http://www.protogeni.net/resources/rspec/ext/profile-parameters/1"
namePrefix="emulab.net.parameter."
varName="$namePrefix$param"
manifest=/tmp/manifest
geni-get manifest > $manifest



if [ $# -eq 0 ]; then
    xgrep -t -n a=$ns -x '//a:data_item/@name' $manifest \
        | sed -e "s/.*$namePrefix//"  -e 's/"//'
    exit
fi
if [ $param == "-h" -o $param == "--help" ]; then
    echo "usage:"
    echo " $0       => print parameter names"
    echo " $0 param => print value of the given parameter"
fi

xgrep -t -n a=$ns -x '//a:data_item[@name="'$varName'"]/text()' $manifest 