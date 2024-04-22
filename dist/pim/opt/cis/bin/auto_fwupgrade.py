import os
import psutil
import glob
import sys
import subprocess
from lockfile import LockFile

def search_zip(pattern):
    conf_file = ""
    conf_list = glob.glob(pattern)
    for v in conf_list:
        fname = os.path.basename(v)
        if not fname.startswith('_backup_'):
            conf_file = v
    if conf_file != "":
        return conf_file
    else :
        return False

def rename_zip(zip_path):
    backup_pattern = os.path.dirname(zip_path)+"/_backup_*.zip"
    backup_list = glob.glob(backup_pattern)
    for v in backup_list:
        subprocess.call(['rm',v])
    backup_path = os.path.dirname(zip_path) + "/_backup_" + os.path.basename(zip_path)
    os.renames(zip_path,backup_path)

def fw_upgrade(zip_path,auto_mode):
    lock = LockFile("/tmp/fwupgrade")
    if lock.is_locked():
        return False
    else:
        lock.acquire()
        ret=False
        try:
            r=subprocess.call(['/opt/cis/bin/release_tool.sh','check',zip_path])
            if r == 0:
                if auto_mode == True :
                    subprocess.call(['cism','stop'])
                subprocess.call(['chmod','755','/tmp/upgrade/setup.sh'])
                subprocess.call(['/tmp/upgrade/setup.sh'])
                if auto_mode == True :
                    subprocess.call(['cism','start'])
                    rename_zip(zip_path)
                ret=True
            else:
                if auto_mode == True :
                    subprocess.call(['rm',zip_path])
                print("ERROR:zipfile err")
                ret=False
        finally:
            subprocess.call(['rm','-rf','/tmp/upgrade'])
            lock.release()
        return ret

#################################################
if len(sys.argv) == 2 :
    zip_path = sys.argv[1]
    if zip_path != False :
        if os.path.isfile(zip_path) == True:
            fw_upgrade(zip_path,False)
else:
    zip_path = search_zip(r"/root/fwupgrade/*.zip")
    if zip_path != False :
        if os.path.isfile(zip_path) == True:
            fw_upgrade(zip_path,True)