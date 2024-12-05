#!/bin/bash

#GST_DEBUG=2 GST_DEBUG_DUMP_DOT_DIR=/var/log/cantops/dot/ ./bin/gstApp -e 0 -E 0 -N 1 -y 1 -C 1 -d 15 -c 0x3 -a 1 -f 1 --fmain0=30 --fcap0=30 --fcap1=30
./bin/gstApp -e 0 -E 0 -N 1 -y 1 -C 1 -a 1 -f 1 -c 0x3 -d $1
