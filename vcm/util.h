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
#include <sys/types.h>

#include <arpa/inet.h>
#include <json-c/json.h>

#define SEGFAULT_DEBUG
#define _FILE_  strrchr(__FILE__,'/')? strrchr(__FILE__,'/')+1:__FILE__
#define PROGRAM_NAME  "vcm"

#define CAM_FILE_EXTENSION  "mp4|srt"

#define PATH_LOG		"/var/log/cantops"
#define PATH_START_VIDEO_TIME	"/tmp/start_video_time"
#define PATH_START_VIDEO_TIME_ACTUAL	"/tmp/cam_state/recording/start_video_time"
#define PATH_CHECK_VIDEO_TIME	"/tmp/start_video_time_chk"
#define PATH_COPY_VIDEO_TIME	"/tmp/start_video_time_cpy"
#define PATH_VIB_VIDEO_TIME	"/tmp/start_video_time_vib"
#define PATH_ERROR_LOG    "/tmp/bg_chk_flag.bin"

#define USEC				(1UL)
#define MSEC				(1000UL * USEC)
#define SEC					(1000UL * MSEC)

#define PATH_MOUNT	"/mnt/sd_cam"
#define PATH_EVENT	"/mnt/sd_cam/event"
#define PATH_RECYCLE	"/mnt/sd_cam/recycle"
#define PATH_JSON   "/root/shared_v"
#define PATH_JSON_LOCAL "/tmp/shared_v"
#define PATH_TMP    "/tmp"
#define FALLBACKDIR     "/dev/shm"
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

#define RDS_VIB_HEADER      "VIB"
#define RDS_OPS_HEADER      "OPS"
#define RDS_DATA_CMD        "recent_data"
#define RDS_TRIG_CMD        "trig_event"
#define RDS_TRIG_KEY        "trigger"
#define RDS_TIME_KEY        "time"
#define RDS_RMS_KEY         "rms"
#define RDS_THRESHOLD_KEY   "threshold"
#define RDS_TAG_KEY         "tag"
#define RDS_OFFSET_KEY      "offset"
#define RDS_VELOCITY_KEY    "velocity"

#define KB	1024
#define MB	(KB*KB)
#define GB	(MB*KB)

void mylog( int opt, const char* _szfmt, ... );
#define __LOG(opt, fmt, args...) do { mylog(opt, (char*)fmt, ##args); } while(0)

extern uint8_t dbg_level;
extern uint8_t log_level;

typedef struct TQueue {
    void *buffer;
    size_t capacity;
    size_t element_size;
    size_t inptr;      
    size_t outptr;
    size_t size;   
} TQueue;

#pragma pack(push, 1)
typedef struct {
    bool enable;
    bool vflip;
    bool hflip;
    int bps[2];
    int gop[2];
    bool ae_on;
    uint ae_gain;
    uint lsc;
    uint iso;
    uint32_t exp_time;
    const char *awb;
} CamConfig;

union SysTime {
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
#pragma pack(pop)

long getTick();

SysTime get_sys_time();
int compSysTime(SysTime t1, SysTime t2);

int is_dir_exist(const char* path);
void makeDir(const char* path);
uint64_t get_disk_size(const char *path);
uint64_t get_disk_use_size(const char *path);
uint64_t get_dir_use_size(const char *path);
uint16_t get_file_cnt(const char *path, uint8_t depth);
char* search_json_file(char* path, char* prefix, char* suffix);
void Eliminate(char *str, char ch);
int json_object_get_value(json_object *hobj, const char *name, void* data);
json_object *json_find_obj (json_object * jobj, const char *find_key);
void bubble_sort(int arr[], int count);

void init_queue(TQueue *queue, size_t capacity, size_t element_size);
int enqueue(TQueue *queue, const void *data);
int dequeue(TQueue *queue, void *data);
void free_queue(TQueue *queue);

#endif
