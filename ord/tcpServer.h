#ifndef _TCPSERVER_H_
#define _TCPSERVER_H_

#ifndef _UTIL_H_
#include "util.h"
#endif

#include <hiredis/hiredis.h>

#ifndef TRUE
#define TRUE 1
#endif

#ifndef FALSE
#define FALSE 0
#endif

#define EVT_TARGET_COPYx
#define SENDQUEUE_ENABLEx
#define EVENT_DIR_PARTITIONx
#define FILENAME_VHL

#define CAM_RESET_FILE	"/opt/pim/bin/kill_test.sh"
#define MACHINE_TYPE_VHL_COMMON 12851
#define MACHINE_TYPE_VHL_0      12853
#define MACHINE_TYPE_VHL_1      12855
#define MACHINE_TYPE_BLACKBOX 06

#define OVL_MAX_QUEUE_SIZE  10
#define BUF_SIZE 1024
#define MAXPENDING 5
#define MAX_DATA_LEN  55
#define STR_LEN   256

#ifdef FILENAME_VHL
#define DATE_PTR	7
#else
#define DATE_PTR	0
#endif

#define MSG_Q_KEY	(0x64)

enum COMMAND_TAG {
  CMD_STATUSINFO_BLACKBOX = 41001,
  CMD_TIMESETTING_BLACKBOX,
  CMD_TIMESETTING_BLACKBOX_RESPONSE,
  CMD_EVENTREQ_BLACKBOX,
  CMD_EVENTACK_BLACKBOX,
  CMD_ERROR_BLACKBOX
};

enum RESPONSE {
  RES_NULL = 0,
  RES_OVERLAY,
  RES_RTC_SET,
  RES_EVT_COPY,
  RES_EVT_PRI,
  RES_ERROR
};

enum EVENT_TYPE {
  EVT_NULL = 0,
  EVT_COPY,
  EVT_PRI,
  EVT_TEST
};

enum EVENT_RESULT {
  EVT_RESULT_FAIL = 0,
  EVT_RESULT_SUCCESS
};

enum ERROR_TYPE {
  ERROR_NULL = 0,
  ERROR_COPY,
  ERROR_PRI
};

enum PIPE_MSG_TYPE {
  PMSG_TYPE_UNUSED = 0,
  PMSG_TYPE_1
};

enum COPY_TYPE {
  COPY_TYPE_UNUSED = 0,
  COPY_TYPE_HEAD = 1,
  COPY_TYPE_BODY = 2,
  COPY_TYPE_TAIL = 3
};

#pragma pack(push, 1)

struct OpsData {
	char tag[32]; // Changed from uint32_t to char array for string support
	float offset;
	float velocity;
};

union _Error {
  uint16_t data;
  uint8_t byte[2];
  struct {
    uint8_t cam0:1;
    uint8_t cam1:1;
    uint8_t cam2:1;
    uint8_t cam3:1;
    uint8_t wifi:1;
    uint8_t sd:1;
    uint8_t temp:1;
    uint8_t voltage:1;
    uint8_t reserved:8;
  };
};

union TOhtData {
  char byte[MAX_DATA_LEN];
  struct FORMAT{
    uint16_t machineType;
	  uint8_t machineID[6];
    uint16_t cmd;
    union {
      uint8_t value[45];
      union {
        SysTime curTime;
        struct {
          uint8_t eventType;
          union {
            uint8_t eventResult;
            char version[5];
          };
        };
        _Error error;
      };
    };
  }fmt;
};

struct TOrdConf {
  bool srt_enable;
  bool ops_enable;
  bool disk_manage;
  bool target_copy;
  bool rtc_reset;
  bool vib_enable;
  uint margin_sec;
  uint cameraNum;
  uint vhl_max;
  uint disk_manage_period;
  uint event_storage_size;
  uint debug_level;
  uint log_level;
  uint disk_limit_per;
  uint portNum;
  uint disk_limit_file;
  uint ovl_buffering;
  uint evt_copy_delay;
  uint err_send_period;
  char ip_addr[64];
};

#if 1
struct MultipleArg {
  int fd;
  uint8_t threadNum;
  uint16_t delay;
  uint8_t copyTail;
  uint8_t copyHead;
  long diff;
  uint8_t copyType;
  SysTime copyTime;
};
#endif

struct _BUFQueue {
#define QUEUE_SIZE  256
  uint8_t inptr;
  uint8_t outptr;
  uint8_t cmd[QUEUE_SIZE];
  int fd[QUEUE_SIZE];
};

struct _MSGQueue {
  long type;
  TOhtData data;
};

struct TVhlConf {
  uint8_t recMinute;
  CamConfig camConfig[4];
  char vhl_name[64];
  uint8_t event_storage_size;
  bool event_auto_remove;
  char tmp_path[256];
  char log_path[256];
  char mount_path[256];
  char event_path[256];
  char recycle_path[256];
  char json_path[256];
  char muxer[32];
};

#pragma pack(pop)

class CTCPServer
{
public :
	static CTCPServer* getInstance() ;

	int init() ;
	int destroy() ;

	int sendData() ;
  int sendDataIPC(char* data, int len);
  int sendDataTCP(int fd, char* data, int len);

	int waitingConnect() ;
	int waitingCopy(void* pData);
  int waitingDisk();
  int waitingError();
  int waitingRedis();
  int waitingGetOPS(int loop);
  long getEpochFromChar(char* filename, uint8_t offset, uint8_t opt, SysTime *fileTime);
  SysTime getTimeFromChar(char* filename, uint8_t offset);

private :
	int setMaxFD(int newFD, int maxFD);
	int parseRecvData(int fd, char* data, int len);
  int get_json_config();
  void init_json_config();
  int responseEvent(int fd, uint8_t type, uint8_t result);
  int checkSD();
  int call_copy(int fd, int tail);

public :
  int m_flagDestroy;
  TOrdConf _TOrdConf;
#ifdef SENDQUEUE_ENABLE
  _BUFQueue sendBuf;
#endif

private :
	pthread_t m_threadConnect;
  pthread_t m_threadCopy;
  pthread_t m_threadDisk;
  pthread_t m_threadError;
  pthread_t m_threadRedis;
  pthread_t m_threadGetOPS;

  OpsData opsData;
  TQueue _TOvlQueue;

	int m_serverSocket;
	int m_clientSocket;

	int m_fdMax;
  int e_fdMax;

	fd_set m_fds;
  fd_set e_fds;
  pthread_mutex_t m_fdsMutex; // Added for thread safety
  
  TVhlConf vhlConf;
  double disk_use_limit;
  double disk_size_mnt;
  double disk_size_evt;
  bool disk_size_over_evt;
  uint16_t errorData;
  uint8_t vhl_cnt;
  bool path_eq_f;
  bool vhl_new_f;
};

#endif
