#!/bin/bash
/opt/pim/bin/net_interface_change.sh eth0 ens1 eth0.yaml
/opt/pim/bin/net_interface_change.sh eth1 ens0 eth1.yaml
netplan apply

/opt/pim/bin/net_interface_change.sh ens0 eth0 eth1.yaml
/opt/pim/bin/net_interface_change.sh ens1 eth1 eth0.yaml
netplan apply
