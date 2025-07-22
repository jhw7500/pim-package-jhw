
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

#define MSG_Q_REQ_KEY (0x65)
#define MSG_Q_RES_KEY (0x66)
#define CFI_DATA_LEN 50
#define CFI_VERISON	0x300
#define CFI_CMD_ID	0x300
#define CTS_CAP_START_CMD_ID 0x900
#define CTS_CAP_STOP_CMD_ID 0x901
#define CFI_SID		"CANTOP"
#define CFI_VHL_NAME	"VD3001"
//#define CFI_PREFIX	"VD3001_20241122_102035"
#define INTERVAL_USEC 100000

enum PIPE_MSG_TYPE {
  PMSG_TYPE_UNUSED = 0,
  PMSG_TYPE_1
};

#pragma pack(push, 1)
union TCfiData {
  uint8_t byte[CFI_DATA_LEN];
  struct THeader {
    uint16_t len;
	uint16_t ver;
    uint8_t sid[6];
    uint16_t cmd_id;
    uint16_t tx_id;
    uint8_t channel;
    uint8_t reserved;
    uint16_t cap_cnt;
    uint8_t prefix[32];
  } data;
};

struct _MSGQueue {
  long type;
  union TCfiData cfi;
};
#pragma pack(pop)

int main(int argc, char *argv[])
{
	int ret = 0;
	int msg_id = msgget((key_t)MSG_Q_REQ_KEY, IPC_CREAT | 0666);
	char strTmp[512]; 
    bool loop = true;
    int loop_delay = INTERVAL_USEC;
	if (msg_id == -1) {
		ret = -1;
		perror("msgget fail");
		//__LOG(LOG_ERR, "[IPC][%s:%d] ret:%d", _FILE_, __LINE__, ret);
		return ret;
	}

	struct _MSGQueue msgBuf;
	msgBuf.type = PMSG_TYPE_1;
	msgBuf.cfi.data.len = CFI_DATA_LEN;
	msgBuf.cfi.data.ver = CFI_VERISON;
	memcpy(msgBuf.cfi.data.sid, CFI_SID, strlen(CFI_SID));
	msgBuf.cfi.data.cmd_id = CFI_CMD_ID;
    //msgBuf.cfi.data.cmd_id = CTS_CAP_STOP_CMD_ID;
	msgBuf.cfi.data.tx_id = 0;
	msgBuf.cfi.data.channel = 0x03;
	msgBuf.cfi.data.reserved = 0;
    msgBuf.cfi.data.cap_cnt = 1;
    int i = 0;
    //syslog(LOG_LOCAL0, "test");
    if(argc >= 3)
    {
        loop_delay = atoi(argv[2]);
    }
    else if(argc >= 2)
    {
        msgBuf.cfi.data.cap_cnt = atoi(argv[1]);
    }
    else
    {
        msgBuf.cfi.data.cap_cnt = 1;
    }

	time_t t = time(NULL);
	struct tm tm = *localtime(&t);
	char datetime[20];

	strftime(datetime, sizeof(datetime), "%Y%m%d_%H%M%S", &tm);

	memset(msgBuf.cfi.data.prefix, 0, 32);
	//sprintf((char *)msgBuf.cfi.data.prefix, "%s_%s", CFI_VHL_NAME, datetime);
	//memcpy(msgBuf.cfi.data.prefix, CFI_PREFIX, strlen(CFI_PREFIX));
	
	sprintf(strTmp, "len:%d, ver:0x%x, cmd_id:0x%x, tx_id:%d, ch:0x%x reserved:%d\n", \
		msgBuf.cfi.data.len, msgBuf.cfi.data.ver, msgBuf.cfi.data.cmd_id, msgBuf.cfi.data.tx_id, msgBuf.cfi.data.channel, msgBuf.cfi.data.reserved);
	syslog(LOG_LOCAL0, "%s", strTmp);

    struct timespec next;
    clock_gettime(CLOCK_MONOTONIC, &next);

	do
	{
        sprintf((char *)msgBuf.cfi.data.prefix, "%s_%d", CFI_VHL_NAME, i);
		//memcpy(msgBuf.cfi.byte, data, len);
		ret = msgsnd(msg_id, &msgBuf, msgBuf.cfi.data.len, IPC_NOWAIT);
        if(i++ > 1000) i = 0;
        if(msgBuf.cfi.data.tx_id++ > 1000) msgBuf.cfi.data.tx_id = 0;
		if(loop) usleep(250000);
#if 0
        next.tv_nsec += loop_delay * 1000;
        if (next.tv_nsec >= 1000000000) {
            next.tv_sec++;
            next.tv_nsec -= 1000000000;
        }
        clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);
#endif
	} while(loop);
#if 0
	if (ret < 0) {
		perror("msgsnd fail");
		__LOG(LOG_ERR, "[IPC][%s:%d] ret:%d", _FILE_, __LINE__, ret);
		return ret;
	} else {
		__LOG(LOG_INFO, "[IPC][%s:%d] send data msg_id(%d) byte  %d", _FILE_, __LINE__, msg_id, len);
	}
#endif
/*
	for (int i = 0; i < len; i++)
		__E(LOG_LEVEL_MSG, "%02x", data[i]);
	__E(LOG_LEVEL_MSG, "\n");
*/
	return 0;
}
