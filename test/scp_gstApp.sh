#!/bin/bash
#scp jhw@192.168.3.81://opt/desktop/gitlab/gst-jhw/gstapp/gstapp/app/bin/gstApp /home/user
sshpass -p jhw scp jhw@192.168.3.81:/opt/desktop/gitlab/gstApp/bin/gstApp bin/
cp bin/gstApp /usr/local/bin/ -f
#sshpass -p jhw scp jhw@192.168.3.81:/opt/desktop/gitlab/gst-jhw/gstapp/gstapp/test/bin /home/user/pim-package/test/bin/
#sshpass -p jhw scp jhw@192.168.3.81:/opt/desktop/gitlab/gst-jhw/gstapp/old/gstapp/app/bin/gstApp /home/user/pim-package/test/bin/

