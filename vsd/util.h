#ifndef _UTIL_H_
#define _UTIL_H_

//#include <stdio.h>
//#include <time.h>
#include <cstdio>
#include <unistd.h>
#include <stdint.h>
#include <unistd.h>
#include <cstring>
#include <stdlib.h>
#include <stdarg.h>
#include <pthread.h>
#include <syslog.h>
#include <endian.h>

#include <sys/stat.h>
#include <sys/time.h>
#include <sys/ioctl.h>
#include <sys/ipc.h>
#include <sys/msg.h>

#include <arpa/inet.h>
#include <json-c/json.h>

#define SW_VERSION   "1.5"
#define SEGFAULT_DEBUG
#define _FILE_  strrchr(__FILE__,'/')? strrchr(__FILE__,'/')+1:__FILE__
#define PROGRAM_NAME  "vsd"

#define PATH_LOG		"/var/log/cantops"
#define PATH_START_VIDEO_TIME	"/tmp/start_video_time"
#define PATH_ERROR_LOG    "/tmp/bg_chk_flag.bin"

#define USEC				(1UL)
#define MSEC				(1000UL * USEC)
#define SEC					(1000UL * MSEC)

#define PATH_MOUNT	"/mnt/sd_cam"
#define PATH_EVENT	"/mnt/sd_cam/event"
#define PATH_JSON   "/root/shared_v"
#define EVENT_FILE_NAME_PREFIX	"evt"
#define EDGE_JSON_FILE   "/root/shared_v/edgeconf_pim.json"
#define ORD_VCM_JSON_FILE   "/root/shared_v/ord_vcm_conf.json"
#define JSON_HEADER_VHL "VHL_CAM"
#define JSON_HEADER_ORD "ORD"
#define JSON_HEADER_VCM "VCM"
#define JSON_HEADER_NET "NETWORK"
#define JSON_TITLE_ETH0 "ETH0"
#define JSON_NAME_PREFIX  "edgeconf_"
#define JSON_NAME_SUFFIX  ".json"

#define KB	1024
#define MB	(KB*KB)
#define GB	(MB*KB)

void mylog( int opt, const char* _szfmt, ... );
#define __LOG(opt, fmt, args...) do { mylog(opt, (char*)fmt, ##args); } while(0)

extern uint8_t dbg_level;
extern uint8_t log_level;

union _SYSTEMTIME {
  uint8_t byte[16];
  struct {
    uint16_t wYear;
    uint16_t wMonth;
    uint16_t wDayOfWeek;
    uint16_t wDay;
    uint16_t wHour;
    uint16_t wMinute;
    uint16_t wSecond;
    uint16_t wMsecond;
  };
} ;

long getTick();

extern _SYSTEMTIME get_sys_time();

int is_dir_exist(const char* path);
uint64_t get_disk_size(const char *path);
uint64_t get_disk_use_size(const char *path);
uint64_t get_dir_use_size(const char *path);
uint16_t get_file_cnt(const char *path);
char* search_json_file(char* path, char* prefix, char* suffix);
void Eliminate(char *str, char ch);

#endif
