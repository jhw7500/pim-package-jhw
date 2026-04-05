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

#define SRT_QUEUE_ENABLE
#define SRT_ALWAYS
#define BUF_SIZE 			4096
#define SRT_MAX_QUEUE_SIZE	10
#define SRT_LOOP_PERIOD		500*MSEC
#define OPS_MAX_QUEUE_SIZE	10
#define OPS_LOOP_PERIOD		500*MSEC

extern char srtBuf[256];
extern pthread_mutex_t g_srtBufMutex;

enum MSG_TYPE {
  PMSG_TYPE_UNUSED = 0,
  PMSG_TYPE_IPC,
  PMSG_TYPE_OVERLAY,
  PMSG_TYPE_OSS
};

enum _EVENT_TYPE {
	EVT_NULL = 0,
	EVT_COPY,
	EVT_PRI
};

enum _COMMAND_TAG {
	CMD_STATUSINFO_BLACKBOX = 41001,
	CMD_TIMESETTING_BLACKBOX,
	CMD_TIMESETTING_BLACKBOX_RESPONSE,
	CMD_EVENTREQ_BLACKBOX,
	CMD_EVENTACK_BLACKBOX,
	CMD_ERROR_BLACKBOX
};

#pragma pack(push, 1)
struct _OVERLAY {
	uint8_t curMode:8;
	uint8_t curStatus:8;
	uint32_t curNodeID:32;
	uint32_t tagetNodeID:32;
	int curNodeOffset:32;
	double drivingSpeed;
	int eout:32;
	char loutSign:8;
	int lout:32;
	float fAxis1Torque;
	float fAxis2Torque;
	int error:32;
	uint8_t ohtDetectLevel:8;
	uint8_t obsDetectLevel:8;
};

struct TOpsData {
	uint32_t tag; // Changed from const char* to uint32_t to avoid dangling pointer
	float offset;
	float velocity;
	SysTime time;
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
    char byte[55];
	struct {
		uint16_t machineType;
		uint8_t machineID[6];
		uint16_t cmd;
		union {
			_OVERLAY ov;
			struct {
				uint8_t eventType;
				uint8_t eventResult;
			} ev;
			_Error error;
		};
	}fmt;
};

struct TVcmConf {
	bool srt_enable;
	bool srt_test;
	bool srt_auto_sync;
    bool file_time_check;
	bool target_copy;
	bool vib_enable;
	bool ops_enable;
	bool vib_test;
	uint portNum;
	uint srt_period;
	uint srt_delay;
	uint srt_buffering;
	uint srt_set_index;
	uint debug_level;
	uint log_level;
	uint ops_period;
	uint ops_delay;
	uint ops_buffering;
	char ip_addr[64];
} ;
extern TVcmConf _TVcmConf;

struct TVhlConf {
	char vhl_name[64];
	char line[64];
	char floor[64];
	char tmp_path[256];
	char log_path[256];
	char mount_path[256];
	char event_path[256];
	char recycle_path[256];
	char json_path[256];
	int recording_time;
	int event_storage_size;
	bool event_auto_remove;
	CamConfig camConfig[4];
} ;
extern TVhlConf _TVhlConf;

struct TVhlErr {
	bool power_current_err;
	bool cam_ch0_err;
	bool cam_ch1_err;
	bool cam_ch2_err;
	bool cam_ch3_err;
	bool wifi_err;
	bool sd_err;
	bool temp_err;
};
extern TVhlErr _TVhlErr;

#pragma pack(pop)

struct _SendQueue {
#define QUEUE_SIZE  256
	uint8_t inptr;
	uint8_t outptr;
	uint8_t buf[QUEUE_SIZE];
	int fd[QUEUE_SIZE];
};

class CTCPServer
{
public :
	static CTCPServer* getInstance() ;


	int init() ;
	int destroy() ;
	int SendDataForSetFD(uint16_t cmd, char* data, int len);
	int sendData(int fd, char* data, int len);
	int parseIpcRecvData(int msgId, char* data, int len);
	int parseTcpRecvData(int fd, char* data, int len);
	int waitingConnect() ;
	int waitingMakeSRT();
	int getDestoryFlag();
	void setDestoryFlag(int val);
	int waitingGetOPS(int loop);

private :
	int setMaxFD(int newFD, int maxFD) ;
	void init_json_config();
	int get_json_config();
	
public :
	int m_flagDestroy;
	pthread_mutex_t m_fileMutex = PTHREAD_MUTEX_INITIALIZER; // 파일 큐 보호용
	pthread_cond_t m_fileCond = PTHREAD_COND_INITIALIZER; // 파일 쓰기 신호용
	TQueue m_fileWriteQueue; // 파일 쓰기 태스크 큐
	
private :
	pthread_t m_threadConnect;
	pthread_t m_threadMakeSRT;
	pthread_t m_threadGetOPS;
	pthread_t m_threadFileWriter; // 파일 쓰기 전용 스레드
	pthread_mutex_t lock_ops = PTHREAD_MUTEX_INITIALIZER;
	pthread_mutex_t m_fdsMutex = PTHREAD_MUTEX_INITIALIZER; // FD sets 보호용
	TOpsData _TOpsData;
	
	int m_serverSocket ;
	int m_clientSocket ;

	//int m_pipe[2] ;

	int m_fdMax ;
	int o_fdMax ;
	int n_fdMax ;

	fd_set m_fds ;
	fd_set n_fds;
	fd_set o_fds;

	//_SendQueue send_queue;
	//char szBuf[BUF_SIZE] ;
};

#endif
