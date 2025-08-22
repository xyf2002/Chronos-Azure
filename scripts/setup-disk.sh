#!/bin/bash

# Define storage folder
STORAGEDIR=/storage
# Create folder
sudo mkdir -p ${STORAGEDIR}

# Create disk space
sudo /usr/local/etc/emulab/mkextrafs.pl -f ${STORAGEDIR}

sudo chmod 777 ${STORAGEDIR}