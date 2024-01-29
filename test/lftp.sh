#!/usr/bin/env bash
FTP_SERVER="100.100.100.100"
USERNAME="your_username"
PASSWORD="your_password"
REMOTE_DIR="Downlaods"

FILE_TO_TRANSFER="/mnt/sd_cam/VD3000_20240126_134000-ch0.mp4"

lftp -u "$FTP_SERVER" <<EOF
cd "$REMOTE_DIR"
put "$FILE_TO_TRANSFER"
bye
EOF
