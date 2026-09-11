
#include "tcpServer.h"

#ifndef _UTIL_H_
#include "util.h"
#endif

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <limits.h>
#include <unistd.h>

#define SW_VERSION   "4.8"

static bool ord_valid_invocation_id(const char* value)
{
	if(value == NULL || strlen(value) != 32)
		return false;
	for(size_t i = 0; i < 32; i++)
	{
		if(!((value[i] >= '0' && value[i] <= '9') ||
		     (value[i] >= 'a' && value[i] <= 'f')))
			return false;
	}
	return true;
}

static int ord_readiness_paths(char* ready, size_t ready_size, char* temporary, size_t temporary_size)
{
	const char* run_dir = getenv("PIM_CAMERA_RUN_DIR");
	if(run_dir == NULL || run_dir[0] == '\0')
		run_dir = "/run/pim-camera";
	if(run_dir[0] != '/')
	{
		errno = EINVAL;
		return -1;
	}
	int ret = snprintf(ready, ready_size, "%s/ord-ready", run_dir);
	if(ret < 0 || static_cast<size_t>(ret) >= ready_size)
	{
		errno = ENAMETOOLONG;
		return -1;
	}
	ret = snprintf(temporary, temporary_size, "%s.tmp.%ld", ready, static_cast<long>(getpid()));
	if(ret < 0 || static_cast<size_t>(ret) >= temporary_size)
	{
		errno = ENAMETOOLONG;
		return -1;
	}
	return 0;
}

static int ord_clear_readiness()
{
	char ready[PATH_MAX];
	char temporary[PATH_MAX];
	if(ord_readiness_paths(ready, sizeof(ready), temporary, sizeof(temporary)) < 0)
		return -1;
	if(unlink(ready) < 0 && errno != ENOENT)
		return -1;
	if(unlink(temporary) < 0 && errno != ENOENT)
		return -1;
	return 0;
}

static int ord_write_all(int fd, const char* data, size_t size)
{
	while(size > 0)
	{
		ssize_t written = write(fd, data, size);
		if(written < 0 && errno == EINTR)
			continue;
		if(written <= 0)
		{
			if(written == 0)
				errno = EIO;
			return -1;
		}
		data += written;
		size -= static_cast<size_t>(written);
	}
	return 0;
}

static int ord_publish_readiness(const char* invocation_id)
{
	char ready[PATH_MAX];
	char temporary[PATH_MAX];
	char payload[34];
	if(!ord_valid_invocation_id(invocation_id))
	{
		errno = EINVAL;
		return -1;
	}
	if(ord_readiness_paths(ready, sizeof(ready), temporary, sizeof(temporary)) < 0)
		return -1;
	int length = snprintf(payload, sizeof(payload), "%s\n", invocation_id);
	if(length != 33)
	{
		errno = EINVAL;
		return -1;
	}

	int fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0644);
	if(fd < 0)
		return -1;
	if(ord_write_all(fd, payload, static_cast<size_t>(length)) < 0 || fsync(fd) < 0)
	{
		int saved_errno = errno;
		close(fd);
		unlink(temporary);
		errno = saved_errno;
		return -1;
	}
	if(close(fd) < 0)
	{
		int saved_errno = errno;
		unlink(temporary);
		errno = saved_errno;
		return -1;
	}
	if(rename(temporary, ready) < 0)
	{
		int saved_errno = errno;
		unlink(temporary);
		errno = saved_errno;
		return -1;
	}
	return 0;
}

int main()
{
	//__LOG(LOG_INFO, "Init Version : %s", SW_VERSION);
    //log_level = 5;
	const char* invocation_id = getenv("INVOCATION_ID");
	const bool managed_invocation = ord_valid_invocation_id(invocation_id);
	if(managed_invocation && ord_clear_readiness() < 0)
		return 1;
	CTCPServer* server = CTCPServer::getInstance() ;
	//makeDir(PATH_LOG);
    //makeDir(PATH_MOUNT);
	//makeDir(PATH_EVENT);
	//makeDir(PATH_RECYCLE);

	//__E(LOG_LEVEL_EMG, "Init Version : %s\n", SW_VERSION);
	__LOG(LOG_NOTICE, "[CFG][%s:%d] version : %s", _FILE_, __LINE__, SW_VERSION);

	if(server->init() != 0)
		return 1;
	if(managed_invocation && ord_publish_readiness(invocation_id) < 0)
		return 1;

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
