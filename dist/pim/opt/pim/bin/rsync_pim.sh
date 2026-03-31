#!/bin/bash
FILE_NAME='pim.deb'
#sshpass -p 'jhw' \
rsync -av --progress \
-e ssh jhw@192.168.3.81:/home/jhw/ai/opencode/projects/pim-package-org/release/$FILE_NAME .
