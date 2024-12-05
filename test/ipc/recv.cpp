
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
#define CFI_SID		"CANTOP"
#define CFI_VHL_NAME	"VD3001"
//#define CFI_PREFIX	"VD3001_20241122_102035"

enum MSG_TYPE {
  PMSG_TYPE_UNUSED = 0,
  PMSG_TYPE_IPC,
  PMSG_TYPE_OVERLAY,
  PMSG_TYPE_OSS
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

struct IpcBuffer
{
    long type;
    char data[64];
};

struct _MSGQueue {
  long type;
  union TCfiData cfi;
};
#pragma pack(pop)

int main(int argc, char *argv[])
{
  int ret = 0;
  int msg_id = msgget((key_t)MSG_Q_RES_KEY, IPC_CREAT | 0666);
  char strTmp[512];
  _MSGQueue msgBuf;

  if (msg_id == -1)
  {
    perror("msgget fail");
    //__LOG(LOG_ERR, "[IPC][%s:%d] ret:%d", _FILE_, __LINE__, ret);
    return msg_id;
  }

#if 1
	ret = msgctl(msg_id, IPC_RMID, NULL);
    if(ret < 0) {
		 perror("msgctl fail");
	}
#endif

  msg_id = msgget((key_t)MSG_Q_RES_KEY, IPC_CREAT | 0666);
  
  while (1)
  {
    usleep(1000);

    // msg_id = msgget((key_t)MSG_Q_KEY, IPC_CREAT | 0666);

    ret = msgrcv(msg_id, &msgBuf, sizeof(msgBuf) - sizeof(long), PMSG_TYPE_IPC, 0);
    if (ret <= 0)
    {
      perror("msgrcv fail");
      continue;
    }
    sprintf(strTmp, "len:%d, ver:0x%x, cmd_id:0x%x, tx_id:%d, ch:0x%x, reserved:%d, cap_cnt:%d\n",
            msgBuf.cfi.data.len, msgBuf.cfi.data.ver, msgBuf.cfi.data.cmd_id, msgBuf.cfi.data.tx_id, msgBuf.cfi.data.channel,
            msgBuf.cfi.data.reserved, msgBuf.cfi.data.cap_cnt);
    syslog(LOG_LOCAL0, "%s", strTmp);
  };


  return 0;
}
