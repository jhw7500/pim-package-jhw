
#include "tcpServer.h"

#ifndef _UTIL_H_
#include "util.h"
#endif

#define SW_VERSION   "4.8"

int main()
{
	//__LOG(LOG_INFO, "Init Version : %s", SW_VERSION);
    //log_level = 5;
	CTCPServer* server = CTCPServer::getInstance() ;
	//makeDir(PATH_LOG);
    //makeDir(PATH_MOUNT);
	//makeDir(PATH_EVENT);
	//makeDir(PATH_RECYCLE);

	//__E(LOG_LEVEL_EMG, "Init Version : %s\n", SW_VERSION);
	__LOG(LOG_NOTICE, "[CFG][%s:%d] version : %s", _FILE_, __LINE__, SW_VERSION);

	if(server->init() < 0) server->m_flagDestroy = 1;

	//setlogmask (LOG_UPTO (LOG_INFO));
	//openlog("slog", LOG_PID|LOG_CONS, LOG_USER);
	//syslog(LOG_CRIT |LOG_LOCAL0 , "Hello from my code ");
	//openlog("mylog", LOG_CONS, LOG_USER);
	//__LOG(LOG_INFO, "jhw : %s", SW_VERSION);
	//syslog(LOG_INFO | LOG_LOCAL0, "jhw log test :%s", SW_VERSION);
	//closelog();
	
	//int flagBreak = 0 ;
	//int szChar ;

	while(1)
	{
		usleep(10000);

		if(server->m_flagDestroy)
			break;
#ifdef SENDQUEUE_ENABLE
		if(server->sendBuf.inptr != server->sendBuf.outptr)
		{
			server->sendData();
		}
#endif

#if 0
		szChar = getchar() ;	

		switch(szChar)
		{
		case 's' :
			//server->sendData() ;
			break ;
		case 'q' :
			printf("BREAK\n") ;
			flagBreak = 1 ;
			break ;
		}

		if(flagBreak)
		{
			getchar() ;
			break ;
		}
#endif
	}
	//printf("before server->destroy()\n") ;
	server->destroy() ;
	//printf("after server->destroy()\n") ;

	return 1 ;
}


