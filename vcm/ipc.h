#ifndef _IPC_H_
#define _IPC_H_

#ifndef _UTIL_H_
#include "util.h"
#endif

#ifndef _TCPSERVER_H_
#include "tcpServer.h"
#endif

#define MSG_Q_KEY (0x64)
#define USER_DATA_MAX_LEN 255

enum _OTIME_STEP {
	OTIME_NULL = 0,
	OTIME_CALL,
	OTIME_DURING
};

enum _WTIME_STEP {
	WTIME_NULL = 0,
	WTIME_CALL,
	WTIME_DURING
};

struct RecvQueue
{
    long type;
    char data[55];
};

struct SendQueue
{
    char type;
    char data[1024];
};
//#pragma pack(pop)

class IpcClient
{
public :
	static IpcClient* getInstance() ;

	int init() ;
	int destroy() ;

	int waitingRecv() ;
    int getBufLen();
    char getBufType();
    void clearBuf();
    char* getBufData();
    int destory();
    
private :
    int parseIpcRecvData(int msgId, char* data, int len);
    uint8_t ConvertStatus(uint8_t st);
    uint8_t ConvertMode(uint8_t md);

public :
    int m_flagDestroy;
    //int msg_id;
    //int msg_len;
    
    SendQueue sendBuf;
private :
    pthread_t m_threadRecv ;
};

#endif