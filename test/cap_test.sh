#!/bin/bash

GST_DEBUG=GST_ELEMENT_FACTORY:4,GST_BUFFER:5 gst-launch-1.0 ...
#gst-launch-1.0 v4l2src do-timestamp=true ! videorate ! video/x-raw,framerate=15/1 ! jpegenc ! multifilesink location=frame_%03d.jpg
gst-launch-1.0 v4l2src device=/dev/video4 do-timestamp=true ! imxvideoconvert_g2d ! videorate ! video/x-raw,width=3840,height=1080,framerate=60/1 ! tee name=t1 \
        t1. ! queue ! videocrop left=1920 right=0 ! imxvideoconvert_g2d ! video/x-raw,framerate=15/1 ! jpegenc ! multifilesink location=/mnt/sd_cam/capture/test-%03d.jpg


:<<'END'
gst-launch-1.0 \
	v4l2src device=/dev/video4 do-timestamp=true num-buffers=5 ! imxvideoconvert_g2d ! video/x-raw,width=3840,height=1080,framerate=60/1 ! tee name=t1 \
		t1. ! queue ! videocrop top=0 bottom=0 left=1920 right=0 ! imxvideoconvert_g2d ! videorate ! video/x-raw,framerate=15/1 ! jpegenc ! tee name=t10 \
			t10. ! queue ! multifilesink location=/mnt/sd_cam/capture/ch0-%03d.jpg \
		t1. ! queue ! videocrop top=0 bottom=0 left=0 right=1920 ! imxvideoconvert_g2d ! videorate ! video/x-raw,framerate=15/1 ! jpegenc ! tee name=t11 \
			t11. ! queue ! multifilesink location=/mnt/sd_cam/capture/ch1-%03d.jpg

END
