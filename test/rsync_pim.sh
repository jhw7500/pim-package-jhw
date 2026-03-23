#!/bin/bash
FILE_NAME='pim.deb'
sshpass -p 'jhw' rsync -av --progress \
-e 'ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null' \
jhw@192.168.3.81:/home/jhw/ai/opencode/projects/pim-package-org/release/$FILE_NAME .
