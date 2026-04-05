
#include "util.h"
//#include <sys/sysinfo.h>

uint8_t dbg_level;
uint8_t log_level;

void mylog( int opt, const char* _szfmt, ... )
{
	va_list va;
	char strTmp[512]; 
	//struct sysinfo s_sysinfo_local;

	//const char *debug_codes[] = {"LOG_EMERG", "LOG_ALERT", "LOG_CRIT", "LOG_ERR", "LOG_WARNING", "LOG_NOTICE", "LOG_INFO", "LOG_DEBUG"};
	const char *debug_codes[] = {"emerg", "alert", "crit", "err", "warning", "notice", "info", "debug"};
	va_start( va, _szfmt );
	
	vsprintf(strTmp, _szfmt ,va);
/*
	struct timespec ts;
	if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0)
	{
		//(void)fprintf(stdout, "%ld %ld\n", ts.tv_sec, ts.tv_nsec);
	}
*/
    //if(sysinfo((struct sysinfo *)(&s_sysinfo_local)) == 0) {
        //(void)fprintf(stdout, "uptime is %ld sec\n", (uint64_t)s_sysinfo_local.uptime);
    //}

	if(opt <= log_level || opt <= LOG_ALERT) 
	{
		//syslog( opt|LOG_LOCAL0, "  [%5ld.%06ld] [%s]%s", ts.tv_sec, ts.tv_nsec/1000, debug_codes[opt], strTmp);
		syslog( opt|LOG_LOCAL0, "%s", strTmp);
	}

	if(opt <= dbg_level || opt <= LOG_ALERT) {
		_SYSTEMTIME saveTime = get_sys_time();
		const char *color_codes[] = {"\033[1;34m", "\033[0;34m", "\033[1;31m", "\033[1;35m", "\033[1;33m", "\033[1;32m", "\033[1;36m", "\033[0m"};
		printf("%s%04d-%02d-%02d %02d:%02d:%02d %s: [%s]\033[0m", color_codes[opt]
															, saveTime.wYear
															, saveTime.wMonth
															, saveTime.wDay
															, saveTime.wHour
															, saveTime.wMinute
															, saveTime.wSecond
															, PROGRAM_NAME, debug_codes[opt]
															);

		vprintf( _szfmt, va );
		printf("\n");
		fflush(stdout);
	}

	va_end( va );
}

uint64_t get_disk_size(const char *path)
{
	int ret ;
	char str[64];
	FILE *fp;

	ret = sprintf(str, "df --block-size=1 %s |awk '{print $2}'", path);
	if(ret < 0) {
		__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
	}
	__LOG(LOG_INFO, "[DSK][%s:%d] %s", _FILE_, __LINE__, str);
	fp = popen(str, "r");
	if (NULL == fp) {
		ret = -1;
		perror("popen() fail");
		__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
	}
	while (fgets(str, 64, fp));

	ret = pclose(fp);
	
	return atol(str);
}

uint64_t get_disk_use_size(const char *path)
{
	int ret ;
	char str[64];
	FILE *fp;

	ret = sprintf(str, "df --block-size=1 %s |awk '{print $3}'", path);
	if(ret < 0) {
		__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
	}
	__LOG(LOG_DEBUG, "[DSK][%s:%d] %s", _FILE_, __LINE__, str);
	fp = popen(str, "r");
	if (NULL == fp) {
		ret = -1;
		perror("popen() fail");
		__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
	}
	while (fgets(str, 64, fp));

	ret = pclose(fp);
	
	return atol(str);
}

uint64_t get_dir_use_size(const char *path)
{
	int ret ;
	char str[64];
	FILE *fp;

    if(is_dir_exist(path) < 0) {
        mkdir(path, 0755);
		__LOG(LOG_NOTICE, "[DSK][%s:%d] mkdir %s", _FILE_, __LINE__, path);
    }

	ret = sprintf(str, "du -sb %s |awk '{print $1}'", path);
	if(ret < 0) {
		__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
	}
	__LOG(LOG_DEBUG, "[DSK][%s:%d] %s", _FILE_, __LINE__, str);
	fp = popen(str, "r");
	if (NULL == fp) {
		ret = -1;
		perror("popen() fail");
		__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
	}
	while (fgets(str, 64, fp));

	ret = pclose(fp);
	
	return atol(str);
}

uint16_t get_file_cnt(const char *path)
{
	int ret ;
	char str[64];
	FILE *fp;

	ret = sprintf(str, "ls -lt %s | grep ^- | wc -l", path);
	if(ret < 0) {
		__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
	}
	__LOG(LOG_DEBUG, "[DSK][%s:%d] %s", _FILE_, __LINE__, str);
	fp = popen(str, "r");
	if (NULL == fp) {
		ret = -1;
		perror("popen() fail");
		__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
	}
	while (fgets(str, 64, fp));

	ret = pclose(fp);
	if(ret < 0) {
		__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
	}

	return atoi(str);
}

_SYSTEMTIME get_sys_time()
{
	time_t timer;
	struct tm lt;
	_SYSTEMTIME dateTime;

	timer = time(NULL);
	localtime_r(&timer, &lt);

	dateTime.wYear = lt.tm_year + 1900;
	dateTime.wMonth = lt.tm_mon + 1;
	dateTime.wDayOfWeek = lt.tm_wday + 1;
	dateTime.wDay = lt.tm_mday;
	dateTime.wHour = lt.tm_hour;
	dateTime.wMinute = lt.tm_min;
	dateTime.wSecond = lt.tm_sec;
	dateTime.wMsecond = 0;

	return dateTime;
}

int is_dir_exist(const char* path)
{
	struct stat statbuf;
	int ret = stat(path, &statbuf);

	if(ret != -1) {
		if(S_ISDIR(statbuf.st_mode)) {
			//__E(LOG_LEVEL_TRA, "Event folder Exist\n");
		}
	} else {
		//__E(LOG_LEVEL_TRA, "Event folder Not Exist\n");
	}

	return ret;
}

long getTick()
{
    //timeval tick;
    //gettimeofday (&tick, NULL);
    //return (tick.tv_sec+ tick.tv_usec/1000000);
	struct timespec tspec;

	if (clock_gettime(CLOCK_MONOTONIC, &tspec) == -1) {  
		/* 에러 처리*/
	}

	return tspec.tv_sec;
}

char* search_json_file(char* path, char* prefix, char* suffix)
{
	FILE *fp;
	static char str[128];

    sprintf(str, "ls -ptr %s/%s*%s | grep -v '/$' | tail -1 | tr -d '\r\n'", path, prefix, suffix);
    fp = popen(str, "r");
    if (NULL == fp)
    {
        perror("popen() fail");
        __LOG(LOG_CRIT, "[CFG][%s:%d] popen fail", _FILE_, __LINE__);
    }
    while (fgets(str, 128, fp));
	__LOG(LOG_INFO, "[CFG][%s:%d] search_json_file : %s", _FILE_, __LINE__, str);
	//Eliminate(str, '\n');

	return str;
}

void Eliminate(char *str, char ch)
{
    for (; *str != '\0'; str++)
    {
        if (*str == ch)
        {
            strcpy(str, str + 1);
            str--;
        }
    }
}
#if 0
uint16_t get_disk_use_size(const char *path)
{
	struct statvfs * statvfsBuf;
	uint64_t disk_total, disk_use;
	//int per;

	if(!(statvfsBuf = (struct statvfs *)malloc(sizeof(struct statvfs)))) {
		perror ("Failed to allocate memory to buffer");
		return -1;
	}

	if(statvfs(path, statvfsBuf) < 0) {
		__E(LOG_LEVEL_CRI, "statvfs() has failed\n");
		free(statvfsBuf);
		return -1;
	} else {

		//debug_printf("B:%ld\n", statvfsBuf->f_bsize);
		//debug_printf("T:%ld\n", statvfsBuf->f_blocks*statvfsBuf->f_bsize/KB);
		//debug_printf("F:%ld\n", (statvfsBuf->f_bfree)*statvfsBuf->f_bsize/KB);
		//debug_printf("U:%ld\n", (statvfsBuf->f_blocks - statvfsBuf->f_bfree)*statvfsBuf->f_bsize/KB);
		disk_total = statvfsBuf->f_blocks*statvfsBuf->f_bsize/1024;
		disk_use = (statvfsBuf->f_blocks - statvfsBuf->f_bfree)*statvfsBuf->f_bsize/1024;
		//per = (disk_use*100/disk_total);

		__E(LOG_LEVEL_TRA, "disk Total:%lu use:%lu\n", disk_total, disk_use);
		//debug_printf("used disk space : %d%%\n", per);
	}
	free(statvfsBuf);

	//per = 95;
	return disk_use/1024;
}
#endif

