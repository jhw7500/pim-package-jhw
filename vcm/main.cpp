
#include "tcpServer.h"
#include "ipc.h"

#ifndef _UTIL_H_
#include "util.h"
#endif

#define SW_VERSION   "4.4"

int main()
{
	char mdata[1024];
    int mlen;
    char mtype;
	log_level = 6;
	//sleep(1);
	CTCPServer* server = CTCPServer::getInstance() ;
	IpcClient* ipc = IpcClient::getInstance() ;

	__LOG(LOG_NOTICE, "[CFG][%s:%d] version : %s", _FILE_, __LINE__, SW_VERSION);

	if(server->init() < 0) server->m_flagDestroy = 1;
	if(ipc->init() < 0) ipc->m_flagDestroy = 1;
	//int flagBreak = 0 ;
	//int szChar ;

	while(1)
	{
		usleep(10000);
		if(ipc->m_flagDestroy || server->m_flagDestroy)
			break;
		
		mtype = ipc->getBufType();
		if(mtype != PMSG_TYPE_UNUSED)	//if(ipc->getMsgLen())
		{
			//__E(LOG_LEVEL_DBG, "mtype %d\n", mtype);
			mlen = ipc->getBufLen();
			memcpy(mdata, ipc->getBufData(), mlen);
			//printf("buflen %d\n",mlen);
			//server->parseIpcRecvData(ipc->getMsgID(), ipc->getMsgData(), ipc->getMsgLen());
			server->SendDataForSetFD(mtype, mdata, mlen);
			ipc->clearBuf();
		}
	}

	//printf("before destroy()\n") ;
	
	server->destroy();
	ipc->destory();
	//printf("after destroy()\n") ;
	//exit(0);

	return 1 ;
}


