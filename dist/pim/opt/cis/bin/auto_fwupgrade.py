import glob
import hashlib
import os
import posixpath
import shutil
import subprocess
import sys
import tarfile
import zipfile
import syslog
from lockfile import LockFile


UPGRADE_DIR = "/tmp/upgrade"
LOCK_PATH = "/tmp/fwupgrade"
AUTO_DIR = "/root/fwupgrade"
BACKUP_PREFIX = "_backup_"

def log_error(message):
    syslog.syslog(syslog.LOG_ERR, message)

def log_notice(message):
    syslog.syslog(syslog.LOG_NOTICE, message)

def is_backup_file(path):
    return os.path.basename(path).startswith(BACKUP_PREFIX)

def get_update_type(path):
    lower_path = path.lower()
    if lower_path.endswith(".deb"):
        return "deb"
    if zipfile.is_zipfile(path):
        return "zip"
    if tarfile.is_tarfile(path):
        return "tar"
    return None


def search_update_files(directory):
    update_files = []
    for path in sorted(glob.glob(os.path.join(directory, "*"))):
        if not os.path.isfile(path) or is_backup_file(path):
            continue
        if get_update_type(path) is not None:
            update_files.append(path)
    return update_files

def backup_update_file(path):
    backup_path = os.path.join(
        os.path.dirname(path),
        BACKUP_PREFIX + os.path.basename(path),
    )
    if os.path.exists(backup_path):
        os.remove(backup_path)
    os.rename(path, backup_path)

def remove_backup_files(directory):
    for path in glob.glob(os.path.join(directory, BACKUP_PREFIX + "*")):
        if os.path.isfile(path):
            os.remove(path)

def recreate_upgrade_dir():
    shutil.rmtree(UPGRADE_DIR, ignore_errors=True)
    os.makedirs(UPGRADE_DIR, exist_ok=True)


def ensure_safe_path(base_dir, target_path):
    base_dir = os.path.abspath(base_dir)
    target_path = os.path.abspath(target_path)
    if os.path.commonpath([base_dir, target_path]) != base_dir:
        raise ValueError("archive contains unsafe path")


def extract_zip(zip_path):
    recreate_upgrade_dir()
    with zipfile.ZipFile(zip_path) as archive:
        for member in archive.infolist():
            ensure_safe_path(UPGRADE_DIR, os.path.join(UPGRADE_DIR, member.filename))
        archive.extractall(UPGRADE_DIR)


def extract_tar(tar_path):
    recreate_upgrade_dir()
    with tarfile.open(tar_path) as archive:
        for member in archive.getmembers():
            ensure_safe_path(UPGRADE_DIR, os.path.join(UPGRADE_DIR, member.name))
        archive.extractall(UPGRADE_DIR)


def check_md5_list():
    md5_list_path = os.path.join(UPGRADE_DIR, "md5.list")
    if not os.path.isfile(md5_list_path):
        log_error("md5.list not found")
        return False

    with open(md5_list_path, "r") as md5_list:
        for line in md5_list:
            line = line.strip()
            if not line:
                continue
            parts = line.split(None, 1)
            if len(parts) != 2:
                log_error("invalid md5.list line")
                return False

            expected_md5, file_name = parts
            file_name = file_name.lstrip("*")
            file_path = os.path.join(UPGRADE_DIR, file_name)
            ensure_safe_path(UPGRADE_DIR, file_path)

            if not os.path.isfile(file_path):
                log_error("md5 target not found: " + file_name)
                return False

            md5_hash = hashlib.md5()
            with open(file_path, "rb") as target_file:
                for chunk in iter(lambda: target_file.read(1024 * 1024), b""):
                    md5_hash.update(chunk)

            if md5_hash.hexdigest() != expected_md5:
                log_error("md5 mismatch: " + file_name)
                return False

    return True


def make_executable(path):
    os.chmod(path, 0o755)


def make_shell_scripts_executable(directory):
    for root, _, files in os.walk(directory):
        for file_name in files:
            if file_name.endswith(".sh"):
                make_executable(os.path.join(root, file_name))


def run_script(path):
    if not os.path.isfile(path):
        print("ERROR: script not found: " + path)
        return False
    make_executable(path)
    return subprocess.call([path]) == 0


def upgrade_zip(zip_path):
    try:
        extract_zip(zip_path)
    except (OSError, ValueError, zipfile.BadZipFile) as exc:
        log_error("zip extract failed: " + str(exc))
        return False

    if not check_md5_list():
        return False

    make_shell_scripts_executable(UPGRADE_DIR)
    return run_script(os.path.join(UPGRADE_DIR, "setup.sh"))


def tar_has_pim_update(tar_path):
    with tarfile.open(tar_path) as archive:
        for member in archive.getmembers():
            name = posixpath.normpath(member.name)
            if name == "pim_update.sh" and member.isfile():
                return True
    return False


def upgrade_tar(tar_path):
    try:
        if not tar_has_pim_update(tar_path):
            log_error("pim_update.sh not found in tar")
            return False
        extract_tar(tar_path)
    except (OSError, ValueError, tarfile.TarError) as exc:
        log_error("tar extract failed: " + str(exc))
        return False

    make_shell_scripts_executable(UPGRADE_DIR)
    return run_script(os.path.join(UPGRADE_DIR, "pim_update.sh"))


def upgrade_deb(deb_path):
    return subprocess.call(["dpkg", "-i", deb_path]) == 0

def reboot_system():
    log_notice("reboot system after 1 minute")
    return subprocess.call(["shutdown", "-r", "+1"]) == 0

def run_update(path):
    update_type = get_update_type(path)
    if update_type == "zip":
        return upgrade_zip(path)
    if update_type == "tar":
        return upgrade_tar(path)
    if update_type == "deb":
        return upgrade_deb(path)

    log_error("unsupported file type: " + path)
    return False


def fw_upgrade(update_path, auto_mode):
    log_notice("do fw_upgrade: " + update_path)
    
    lock = LockFile(LOCK_PATH)
    if lock.is_locked():
        log_error("fwupgrade locked")
        return False

    lock.acquire()
    ret = False
    try:
        try:
            if auto_mode:
                subprocess.call(
                    ["dbuart", "<SETUARTMON,0>"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                subprocess.call(
                    ["cism", "stop"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )

            ret = run_update(update_path)
        finally:
            if auto_mode:
                subprocess.call(
                    ["cism", "start"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                subprocess.call(
                    ["dbuart", "<SETUARTMON,1>"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
    finally:
        shutil.rmtree(UPGRADE_DIR, ignore_errors=True)
        lock.release()

    if ret == True:
        log_notice("suc fw_upgrade: " + update_path)
    else :
        log_error("fail fw_upgrade: " + update_path)

    return ret

def run_auto_mode():
    update_files = search_update_files(AUTO_DIR)
    ret = True
    if len(update_files) > 0:
        log_notice(f"auto mode update_files {update_files}")
        remove_backup_files(AUTO_DIR)
        for update_file in update_files:
            if not os.path.isfile(update_file):
                continue
            if not fw_upgrade(update_file, True):
                ret = False
            backup_update_file(update_file)
        if not reboot_system():
            ret = False
    return ret

def main():
    if len(sys.argv) == 2:
        update_path = sys.argv[1]
        if not os.path.isfile(update_path):
            log_error("file not found: " + update_path)
            return 1
        return 0 if fw_upgrade(update_path, False) else 1

    return 0 if run_auto_mode() else 1


if __name__ == "__main__":
    syslog.openlog("fwup", syslog.LOG_PID, syslog.LOG_LOCAL0)
    sys.exit(main())
