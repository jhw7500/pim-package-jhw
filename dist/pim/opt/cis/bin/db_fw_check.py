import getconfval
import json
import subprocess
import threading
import os.path
import sys
import logging
import logging.handlers
import dbver
from lockfile import LockFile


class Local1Logger:
    def __init__(self, ident="MyApp", level=logging.INFO):
        self.logger = logging.getLogger(ident)
        self.logger.setLevel(level)

        # 중복 핸들러 방지
        if not self.logger.handlers:
            syslog_handler = logging.handlers.SysLogHandler(
                address='/dev/log',
                facility=logging.handlers.SysLogHandler.LOG_LOCAL1
            )

            syslog_formatter = logging.Formatter(f'{ident}: %(message)s')
            syslog_handler.setFormatter(syslog_formatter)

            console_handler = logging.StreamHandler(sys.stdout)
            log_format = '%(asctime)s.%(msecs)03d [%(levelname)s] %(message)s'
            date_format = '%Y-%m-%d %H:%M:%S'
            console_formatter = logging.Formatter(log_format, datefmt=date_format)
            console_handler.setFormatter(console_formatter)

            self.logger.addHandler(syslog_handler)
            self.logger.addHandler(console_handler)

    def info(self, msg):
        self.logger.info(msg)

    def error(self, msg):
        self.logger.error(msg)

def stream_reader(pipe, log_func):
    with pipe:
        for line in iter(pipe.readline, ''):
            log_func(line.strip())

if __name__ == '__main__' :
    DB_FIRM_PATH = '/opt/cis/firmware'
    log = Local1Logger(ident='db_fw_checker')
    try :
        daughterboard_type = getconfval.get_json_val("daughterboard_type")
        if daughterboard_type == "analog" :
            fpath = os.path.join(DB_FIRM_PATH, 'db_ax_version.txt')
            if os.path.isfile(fpath) == True:
                with open(fpath, 'r', encoding='utf-8') as f:
                    db_fw = json.load(f)
        elif daughterboard_type == "ethercat" :
            fpath = os.path.join(DB_FIRM_PATH, 'db_cx_version.txt')
            if os.path.isfile(fpath) == True:
                with open(fpath, 'r', encoding='utf-8') as f:
                    db_fw = json.load(f)
        else :
            db_fw = None

    except :
        db_fw = None
    
    if db_fw is not None and all(k in db_fw for k in ['ver', 'fw_file']) :
        try :
            cur_ver = dbver.get_daughter_board_version()
        except :
            cur_ver = ''
        if cur_ver != db_fw['ver'] :
            log.info(f"try upgrade db_fw {db_fw['fw_file']} ({cur_ver} -> {db_fw['ver']})")
            fpath = os.path.join(DB_FIRM_PATH, db_fw['fw_file'])
            cmd = ['stm32update', fpath]
            
            lock = LockFile("/tmp/fwupgrade")
            if lock.is_locked():
                log.info(f"end, lock.is_locked")
            else:
                lock.acquire()
                try:
                    log.info(f"start, cmd: {' '.join(cmd)}")
                    proc = subprocess.Popen(
                        cmd,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        universal_newlines=True,
                        bufsize=1
                    )

                    t_out = threading.Thread(target=stream_reader, args=(proc.stdout, log.info))
                    t_err = threading.Thread(target=stream_reader, args=(proc.stderr, log.info))
                    t_out.start()
                    t_err.start()

                    proc.wait()
                    t_out.join()
                    t_err.join()

                    log.info(f"end (exit code = {proc.returncode})")
                except FileNotFoundError:
                    log.error(f"FileNotFoundError: {cmd[0]}")
                except Exception as e:
                    log.error(f"e: {e}")
                finally :
                    lock.release()
        else :
            log.info(f"db_fw version OK. ({cur_ver} -> {db_fw['ver']})")
