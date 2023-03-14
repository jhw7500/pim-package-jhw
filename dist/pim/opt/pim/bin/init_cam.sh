pkill -9 vcm
pkill -9 ord
pkill -9 streamApp
pkill -9 PIMCAM
sleep 2
modprobe -r imx8-media-dev
sleep 2
modprobe -r max9296
#rmmod imx8-media-dev
#rmmod max9296

sleep 1
modprobe max9296
sleep 1
modprobe imx8-media-dev
sleep 5
PIMCAM -j /root/shared_v/edgeconf_pim.json &
/opt/pim/bin/vcm &
/opt/pim/bin/ord &
