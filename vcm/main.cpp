
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

	// A failed start must not look like a clean stop.  The loop below ends in
	// destroy(), which calls exit(0), so a start failure that fell through to
	// it reported success; returning here keeps the failure off that path.
	// LOG_ALERT so mylog() prints regardless of dbg_level.
	//
	// The two branches are not alike.  A tcp-server failure at socket, bind or
	// listen returns before any thread exists, so nothing is abandoned.  Every
	// later failure - a pthread_create inside either init(), or ipc init(),
	// which runs only after the server threads are up - leaves running threads
	// behind for process exit to take down.  That is deliberate: destroy()
	// joins threads and then exit(0)s, which is the reporting we are avoiding.
	if(server->init() < 0) {
		__LOG(LOG_ALERT, "[CFG][%s:%d] startup aborted: tcp server init failed", _FILE_, __LINE__);
		return EXIT_FAILURE;
	}
	if(ipc->init() < 0) {
		__LOG(LOG_ALERT, "[CFG][%s:%d] startup aborted: ipc init failed", _FILE_, __LINE__);
		return EXIT_FAILURE;
	}
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


