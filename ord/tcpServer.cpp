
#include "tcpServer.h"

static void ord_set_machine_id(const TVhlConf *conf, uint8_t out_machine_id[6])
{
	size_t n;

	memset(out_machine_id, 0, 6);
	if (!conf || !conf->vhl_name)
		return;
	n = strlen(conf->vhl_name);
	if (n > 6)
		n = 6;
	memcpy(out_machine_id, conf->vhl_name, n);
}

static bool ord_machine_id_matches(const TVhlConf *conf, const uint8_t in_machine_id[6])
{
	uint8_t expected[6];

	ord_set_machine_id(conf, expected);
	return memcmp(in_machine_id, expected, 6) == 0;
}

#include <errno.h>
#include <string.h>
#include <time.h>
#include <sys/statvfs.h>
#include <fcntl.h>
#include <unistd.h>
//#include <linux/kernel.h>

static void ord_chomp(char *s)
{
	if (!s)
		return;
	for (size_t i = 0; s[i] != 0; i++) {
		if (s[i] == '\n' || s[i] == '\r') {
			s[i] = 0;
			return;
		}
	}
}

static bool ord_is_safe_shell_token(const char *s)
{
	if (!s || !*s)
		return false;
	for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
		unsigned char c = *p;
		if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
			continue;
		if (c == '_' || c == '-' || c == '.' )
			continue;
		return false;
	}
	return true;
}

static bool ord_is_valid_rtc_time(const SysTime *t)
{
	if (!t)
		return false;
	if (t->wYear < 1900 || t->wYear > 2099)
		return false;
	if (t->wMonth < 1 || t->wMonth > 12)
		return false;
	if (t->wDay < 1 || t->wDay > 31)
		return false;
	if (t->wHour > 23)
		return false;
	if (t->wMinute > 59)
		return false;
	if (t->wSecond > 59)
		return false;
	/* tolerate wMsecond range differences across senders */
	return true;
}

static bool ord_validate_cmd_token_lines(const char *cmd)
{
	FILE *fp;
	char line[256];

	if (!cmd)
		return false;

	fp = popen(cmd, "r");
	if (!fp)
		return false;

	while (fgets(line, sizeof(line), fp)) {
		ord_chomp(line);
		if (!line[0])
			continue;
		if (!ord_is_safe_shell_token(line)) {
			__LOG(LOG_ERR, "[DSK][%s:%d] unsafe token from cmd: %s", _FILE_, __LINE__, line);
			pclose(fp);
			return false;
		}
	}

	if (pclose(fp) < 0)
		return false;
	return true;
}

static int ord_write_file_atomic(const char *path, const char *data)
{
	if (!path || !data)
		return -1;

	int fd = open(path, O_WRONLY | O_TRUNC | O_CREAT, 0644);
	if (fd < 0)
		return -1;

	const size_t len = strlen(data);
	ssize_t n = write(fd, data, len);
	int saved_errno = errno;
	(void)close(fd);
	if (n < 0 || (size_t)n != len) {
		errno = saved_errno;
		return -1;
	}
	return 0;
}


static int ord_get_df_used_avail_bytes(const char *path, uint64_t *out_used_bytes, uint64_t *out_avail_bytes)
{
	char cmd[128];
	char line[128];
	FILE *fp;
	unsigned long long used = 0;
	unsigned long long avail = 0;

	if (!path || !out_used_bytes || !out_avail_bytes)
		return -1;

	/* Match df(1) semantics: used + avail (non-root) */
	sprintf(cmd, "df --block-size=1 %s | awk 'NR==2 {print $3, $4}'", path);
	fp = popen(cmd, "r");
	if (!fp)
		return -1;
	if (!fgets(line, sizeof(line), fp)) {
		pclose(fp);
		return -1;
	}
	(void)pclose(fp);

	if (sscanf(line, "%llu %llu", &used, &avail) != 2)
		return -1;

	*out_used_bytes = (uint64_t)used;
	*out_avail_bytes = (uint64_t)avail;
	return 0;
}

static int ord_get_fs_used_avail_bytes(const char *path, uint64_t *out_used_bytes, uint64_t *out_avail_bytes)
{
	struct statvfs vfs;
	if (!path || !out_used_bytes || !out_avail_bytes)
		return -1;
	if (statvfs(path, &vfs) != 0)
		return ord_get_df_used_avail_bytes(path, out_used_bytes, out_avail_bytes);

	uint64_t frsize = vfs.f_frsize ? (uint64_t)vfs.f_frsize : (uint64_t)vfs.f_bsize;
	uint64_t used = (uint64_t)(vfs.f_blocks - vfs.f_bfree) * frsize;
	uint64_t avail = (uint64_t)vfs.f_bavail * frsize;

	*out_used_bytes = used;
	*out_avail_bytes = avail;
	return 0;
}


#ifdef SEGFAULT_DEBUG
#include <signal.h>

void segfault_sigaction(int signal, siginfo_t *si, void *arg)
{
	CTCPServer* instance = CTCPServer::getInstance() ;
	__LOG(LOG_CRIT, "[CFG][%s:%d] cautght segault at address %p", _FILE_, __LINE__, si->si_addr);
	exit(0);
}
#endif

void* thread_waitingConnect(void* pData)
{
	CTCPServer* instance = CTCPServer::getInstance() ;
	//__E(LOG_LEVEL_TRA, "Connect thread start");
	__LOG(LOG_INFO, "[TCP][%s:%d] thread start", _FILE_, __LINE__);
	if(instance->waitingConnect() < 0) instance->m_flagDestroy = 1;

	return NULL ;
}

void* thread_waitingCopy(void* pData)
{
	//uint32_t num = *(uint32_t *)pData;
	//MultipleArg *my_multiple_arg = (MultipleArg *)pData;
	CTCPServer* instance = CTCPServer::getInstance() ;
	//__E(LOG_LEVEL_TRA, "Copy thread start\n");
	__LOG(LOG_INFO, "[EVT][%s:%d] thread start", _FILE_, __LINE__);
	if(instance->waitingCopy((void* )pData) < 0) {
		__LOG(LOG_ERR, "[EVT][%s:%d] thread instance error", _FILE_, __LINE__);
		//if(pData) free(pData);
	}
	//if(instance->waitingCopy((void* )pData) < 0) instance->setDestoryFlag(1);

	return NULL ;
}

void* thread_waitingDisk(void* pData)
{
	//uint32_t num = *(uint32_t *)pData;
	//MultipleArg *my_multiple_arg = (MultipleArg *)pData;
	CTCPServer* instance = CTCPServer::getInstance() ;
	//__E(LOG_LEVEL_TRA, "Disk thread start\n");
	__LOG(LOG_INFO, "[DSK][%s:%d] thread start", _FILE_, __LINE__);
	if(instance->waitingDisk() < 0) instance->m_flagDestroy = 1;

	return NULL ;
}

void* thread_waitingError(void* pData)
{
	//uint32_t num = *(uint32_t *)pData;
	//MultipleArg *my_multiple_arg = (MultipleArg *)pData;
	CTCPServer* instance = CTCPServer::getInstance() ;
	__LOG(LOG_INFO, "[ERR][%s:%d] thread start", _FILE_, __LINE__);
	if(instance->waitingError() < 0) instance->m_flagDestroy = 1;

	return NULL ;
}

void* thread_waitingGetOPS(void* pData)
{
	CTCPServer* instance = CTCPServer::getInstance() ;
	__LOG(LOG_INFO, "[OPS][%s:%d] thread start", _FILE_, __LINE__);
	if(instance->waitingGetOPS(1) < 0) instance->m_flagDestroy = 1;

	return NULL ;
}

int CTCPServer::waitingGetOPS(int loop)
{
    redisContext *context;
    redisReply *reply;
	SysTime curTime;
	char str[256];
	const char *ops_tag = "";



    // Redis Server connect (default localhost:6379)
    context = redisConnect("127.0.0.1", 6379);
    if (context == NULL || context->err) {
        if (context) {
			__LOG(LOG_ERR, "[OPS][%s:%d] redis connection error: %s", _FILE_, __LINE__, context->errstr);
            redisFree(context);
        } else {
			__LOG(LOG_ERR, "[OPS][%s:%d] Connection error: can't allocate redis context", _FILE_, __LINE__);
        }
        return 1;
    }

	// 500ms loop
	do {
		if(m_flagDestroy)
			break;
		ops_tag = "";
		memset(opsData.tag, 0, sizeof(opsData.tag));
        // get key
        reply = (redisReply *)redisCommand(context, "GET %s:%s", RDS_OPS_HEADER, RDS_DATA_CMD);
        
        // output redis return value
        if (reply->type == REDIS_REPLY_STRING && reply->str != NULL) {
            __LOG(LOG_DEBUG, "[OPS][%s:%d] '%s:%s' is: %s", _FILE_, __LINE__, RDS_OPS_HEADER, RDS_DATA_CMD, reply->str);
			//pthread_mutex_lock(&lock_ops);
            // JSON parsing
            json_object *jobj = json_tokener_parse(reply->str);
            if (jobj == NULL) {
				__LOG(LOG_ERR, "[OPS][%s:%d] Failed to parse JSON", _FILE_, __LINE__);
                freeReplyObject(reply);
                usleep(500000);  // 500ms standby
                continue;  // next
            }

            json_object *val = json_find_obj(jobj, RDS_TAG_KEY);
            if (val != NULL && json_object_get_type(val) == json_type_string) {
				ops_tag = json_object_get_string(val);
				if (!ops_tag)
					ops_tag = "";
				strncpy(opsData.tag, ops_tag, sizeof(opsData.tag)-1);
				__LOG(LOG_INFO, "[OPS][%s:%d] %s : %s", _FILE_, __LINE__, RDS_TAG_KEY, opsData.tag);
            }

            val = json_find_obj(jobj, RDS_OFFSET_KEY);
            if (val != NULL && json_object_get_type(val) == json_type_double) {
                opsData.offset = json_object_get_double(val);
				__LOG(LOG_INFO, "[OPS][%s:%d] %s : %0.2f", _FILE_, __LINE__, RDS_OFFSET_KEY, opsData.offset);
            }
			
#if 0
            val = json_find_obj(jobj, RDS_VELOCITY_KEY);
            if (val != NULL && json_object_get_type(val) == json_type_double) {
                opsData.velocity = json_object_get_double(val);
				__LOG(LOG_INFO, "[OPS][%s:%d] %s : %0.3f", _FILE_, __LINE__, RDS_VELOCITY_KEY, opsData.velocity);
            }
#endif
			//sprintf(srtBuf, "%s(%0.2f)", opsData.tag, opsData.offset);
			//pthread_mutex_unlock(&lock_ops);
			curTime = get_sys_time();

snprintf(str, sizeof(str), "{\n\
 \"REP\":\"SET_OVERLAY\",\n\
 \"RET\":0,\n\
 \"DATA\":{\n\
 \"date\":\"%04d-%02d-%02d %02d:%02d:%02d\",\n\
 \"opsNodeID\":\"%s\",\n\
 \"opsNodeOffset\":%0.2f\n}\n}", curTime.wYear, curTime.wMonth, curTime.wDay, curTime.wHour, curTime.wMinute, curTime.wSecond, \
			opsData.tag, opsData.offset);
			//__LOG(LOG_NOTICE, "[RDS][%s:%d] %s", _FILE_, __LINE__, str);
			TOhtData _TOhtData;
			_TOhtData.fmt.machineType = htons(MACHINE_TYPE_BLACKBOX);
			ord_set_machine_id(&vhlConf, _TOhtData.fmt.machineID);
			_TOhtData.fmt.cmd = htons(CMD_STATUSINFO_BLACKBOX);
			int ret = sendDataIPC(_TOhtData.byte, MAX_DATA_LEN);
			//__LOG(LOG_NOTICE, "[RDS][%s:%d] after", _FILE_, __LINE__);
            // JSON object free
            json_object_put(jobj);
            memset(opsData.tag, 0, sizeof(opsData.tag));
        } else if (reply->type == REDIS_REPLY_NIL) {
			__LOG(LOG_ERR, "[OPS][%s:%d] '%s:%s' does not exist", _FILE_, __LINE__, RDS_OPS_HEADER, RDS_DATA_CMD);
        } else {
			__LOG(LOG_ERR, "[OPS][%s:%d] Failed to retrieve the value for '%s:%s'", _FILE_, __LINE__, RDS_OPS_HEADER, RDS_DATA_CMD);
        }

        // memory free
        freeReplyObject(reply);

        // 500ms stanby
        if(loop) usleep(500000);
    } while(loop);

    // redis free
    redisFree(context);

    return 0;
}

void* thread_waitingRedis(void* pData)
{
	CTCPServer* instance = CTCPServer::getInstance() ;
	__LOG(LOG_INFO, "[OPS][%s:%d] thread start", _FILE_, __LINE__);
	if(instance->waitingRedis() < 0) instance->m_flagDestroy = 1;

	return NULL ;
}

SysTime CTCPServer::getTimeFromChar(char* filename, uint8_t offset)
{
	SysTime fileTime;
	char temp[5];
	memset(temp, 0, 5);
	memcpy(temp, filename + offset, 4);
	fileTime.wYear = atoi(temp);
	memset(temp, 0, 4);
	memcpy(temp, filename + offset + 4, 2);
	fileTime.wMonth = atoi(temp);
	memcpy(temp, filename + offset + 6, 2);
	fileTime.wDay = atoi(temp);
	memcpy(temp, filename + offset + 9, 2);
	fileTime.wHour = atoi(temp);
	memcpy(temp, filename + offset + 11, 2);
	fileTime.wMinute = atoi(temp);
	memcpy(temp, filename + offset + 13, 2);
	fileTime.wSecond = atoi(temp);

	//__LOG(LOG_NOTICE, "[CPY][%s:%d] %04d:%02d:%02d:%02d:%02d:%02d", _FILE_, __LINE__, fileTime.wYear, fileTime.wMonth, fileTime.wDay, fileTime.wHour, fileTime.wMinute, fileTime.wSecond);

	return fileTime;
}

long CTCPServer::getEpochFromChar(char* filename, uint8_t offset, uint8_t opt, SysTime *fileTime)
{
	//SysTime fileTime;
    FILE *fp = NULL;
	char temp[5];
	uint8_t date_ptr = 0;
	char str[STR_LEN];
	int ret = 0;

	memset(temp, 0, 5);
	memcpy(temp, filename + offset, 4);
	fileTime->wYear = atoi(temp);
	memset(temp, 0, 4);
	memcpy(temp, filename + offset + 4, 2);
	fileTime->wMonth = atoi(temp);
	memcpy(temp, filename + offset + 6, 2);
	fileTime->wDay = atoi(temp);
	memcpy(temp, filename + offset + 9, 2);
	fileTime->wHour = atoi(temp);

	if (opt)
	{
		memcpy(temp, filename + offset + 12, 2);
		fileTime->wMinute = atoi(temp);
		memcpy(temp, filename + offset + 15, 2);
		fileTime->wSecond = atoi(temp);
	}
	else
	{
		memcpy(temp, filename + offset + 11, 2);
		fileTime->wMinute = atoi(temp);
		memcpy(temp, filename + offset + 13, 2);
		fileTime->wSecond = atoi(temp);
	}

	sprintf(str, "date -d '%04d%02d%02d %02d:%02d:%02d' +%%s", fileTime->wYear, fileTime->wMonth, fileTime->wDay,
				  fileTime->wHour, fileTime->wMinute, fileTime->wSecond);
	//__LOG(LOG_NOTICE, "[CPY][%s:%d] %s", _FILE_, __LINE__, str);
	fp = popen(str, "r");
	if (NULL == fp)
	{
		ret = -1;
		perror("popen() fail");
		__LOG(LOG_ERR, "[EVT][%s:%d] ret:%d", _FILE_, __LINE__, ret);
		return ret;
	}
	while (fgets(str, STR_LEN, fp));
	ret = pclose(fp);
	if (ret < 0) {
		__LOG(LOG_CRIT, "[EVT][%s:%d] ret:%d", _FILE_, __LINE__, ret);
	}

	return atol(str);
}

int CTCPServer::waitingError()
{
	int ret = 0, i = 0;
	FILE *fp;
	char str[128];
    bool err_new_f = 0;
    uint time_sec = 0;
	//uint16_t tmp = 0;

	//int fd = *(int *)pData;

	TOhtData _TOhtData;

	_TOhtData.fmt.machineType = htons(MACHINE_TYPE_BLACKBOX);
	ord_set_machine_id(&vhlConf, _TOhtData.fmt.machineID);
	_TOhtData.fmt.cmd = htons(CMD_ERROR_BLACKBOX);
	_TOhtData.fmt.error.data = 0;
	//sleep(1);

	while(1)
	{
		if(m_flagDestroy)
			break ;

		sprintf(str, "cat %s 2>/dev/null| tr -d '\n'", PATH_ERROR_LOG);
		fp = popen(str, "r");
		if (NULL == fp) {
			ret = -1;
			//perror("popen() fail");
			__LOG(LOG_ERR, "[ERR][%s:%d] ret:%d", _FILE_, __LINE__, ret);
			sleep(1);
			continue;
		}
		while (fgets(str, 128, fp));
		ret = pclose(fp);
		if (ret < 0) {
			__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
		}
		//__LOG(LOG_NOTICE, "[ERR][%s:%d] %s", _FILE_, __LINE__, str);
		errorData = atoi(str);
		__LOG(LOG_DEBUG, "[ERR][%s:%d] pre:0x%04x cur:0x%04x", _FILE_, __LINE__, _TOhtData.fmt.error.data, errorData);

		//ohtdata.fmt.error.byte[0] = tmp&0xff;
		//ohtdata.fmt.error.byte[1] = (tmp>>8)&0xff;
		
		if(errorData != _TOhtData.fmt.error.data || (vhl_new_f && (vhl_cnt > 0)) || time_sec > _TOrdConf.err_send_period)
		{
            time_sec = 0;
            err_new_f = 1;
			_TOhtData.fmt.error.data = errorData;
			__LOG(LOG_INFO, "[ERR][%s:%d] byte[0]:0x%02x byte[1]:0x%02x", _FILE_, __LINE__, _TOhtData.fmt.error.byte[0], _TOhtData.fmt.error.byte[1]);
            //for(int i=0; i<16; i++)
            __LOG(LOG_NOTICE, "[ERR][%s:%d] cam0:%d, cam1:%d, cam2:%d, cam3:%d, wifi:%d, sd:%d, temp:%d, voltage:%d", _FILE_, __LINE__, \
            _TOhtData.fmt.error.cam0, _TOhtData.fmt.error.cam1, _TOhtData.fmt.error.cam2, _TOhtData.fmt.error.cam3, _TOhtData.fmt.error.wifi, _TOhtData.fmt.error.sd, _TOhtData.fmt.error.temp, _TOhtData.fmt.error.voltage);
            //__LOG(LOG_ALERT, "[ERR][%s:%d] (%d) %d", _FILE_, __LINE__, i, e_fdMax);
            for (i = 0; i <= e_fdMax; i++)
            {
                if(FD_ISSET(i, &e_fds)) {
                    __LOG(LOG_NOTICE, "[ERR][%s:%d] send cmd event ERR DATA(%d)", _FILE_, __LINE__, i);
					ret = sendDataTCP(i, _TOhtData.byte, 12);
                    err_new_f = 0;
                    vhl_new_f = 0;
                }
			}
            if(err_new_f) __LOG(LOG_NOTICE, "[ERR][%s:%d] not send cmd event ERR because oht not connect", _FILE_, __LINE__);

			ret = sendDataIPC(_TOhtData.byte, 12);
		}

		sleep(1);
        if(_TOrdConf.err_send_period) time_sec++;
	}

	//free(pData);

	return ret;
}

int CTCPServer::waitingDisk()
{
	int ret = 0;
	FILE *fp;
	char str[STR_LEN];
	char tmp[128];
	uint16_t disk_file_cnt_mnt;
	uint16_t disk_file_cnt_evt;
	double disk_use_mnt;
	double disk_use_evt;
	SysTime sysTime;
	char mv_time[64];
	char mv_path[128];
	bool disk_op_f;
	uint16_t tail_recycle = 1;
	uint16_t tail_event = 1;
	uint16_t tail_mnt = 1;
	uint8_t fileSet_cnt = _TOrdConf.cameraNum+_TOrdConf.srt_enable+_TOrdConf.vib_enable;

#if 0
	while(1)
	{
		sleep(1);
	    sprintf(str, "cat %s 2>/dev/null | tr -d '\n'", PATH_START_VIDEO_TIME);

		fp = popen(str, "r");
		if (NULL == fp) {
			ret = -1;
			perror("popen() fail");
			__LOG(LOG_ERR, "[SRT][%s:%d] ret:%d", _FILE_, __LINE__, ret);
			continue;
		}
		while (fgets(str, 128, fp));
		ret = pclose(fp);

		if(strchr(str, ':') != NULL) break;
	}
	sleep(10);
#endif

	//getRecycleMovePath(move_path);
	//getRecycleDelPath(del_path);

    checkSD();

	while(1)
	{
		if(m_flagDestroy)
			break ;

        sprintf(str, "cat %s 2>/dev/null | tr -d '\n'", "/dev/shm/sd_mount_flag");
        fp = popen(str, "r");
        if (NULL == fp) {
            ret = -1;
            perror("popen() fail");
            __LOG(LOG_ERR, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
			sleep(1);
            continue;
        }
        while (fgets(str, 128, fp));
        ret = pclose(fp);

		if(strchr(str, '1') != NULL) {
			__LOG(LOG_NOTICE, "[DSK][%s:%d] new sd card mount : /dev/shm/sd_mount_flag set", _FILE_, __LINE__);
			checkSD();
			if (ord_write_file_atomic("/dev/shm/sd_mount_flag", "2\n") < 0) {
				__LOG(LOG_ERR, "[DSK][%s:%d] failed to reset sd_mount_flag. errno=%d(%s)", _FILE_, __LINE__, errno, strerror(errno));
			}
			__LOG(LOG_NOTICE, "[DSK][%s:%d] sd_mount_flag reset", _FILE_, __LINE__);
		}

		if (access(PATH_MOUNT, W_OK) != 0) {
			__LOG(LOG_INFO, "[DSK][%s:%d] %s not writable, skip disk management", _FILE_, __LINE__, PATH_MOUNT);
			sleep(_TOrdConf.disk_manage_period);
			continue;
		}

		do
		{
			disk_op_f = FALSE;
			memset(tmp, 0, sizeof(tmp));
			memset(str, 0, sizeof(str));
			disk_file_cnt_mnt = get_file_cnt(PATH_MOUNT, 1);
			disk_file_cnt_evt = get_file_cnt(PATH_EVENT, 1);
			{
				uint64_t used_bytes = 0;
				uint64_t avail_bytes = 0;
				if (ord_get_fs_used_avail_bytes(PATH_MOUNT, &used_bytes, &avail_bytes) == 0) {
					disk_use_mnt = (double)used_bytes / GB;
				} else {
					disk_use_mnt = (double)get_disk_use_size(PATH_MOUNT) / GB;
				}
			}
			disk_use_evt = (double)get_dir_use_size(PATH_EVENT)/GB;

			__LOG(LOG_INFO, "[DSK][%s:%d] %s : %0.1f/%0.1fGB, %d/%d", _FILE_, __LINE__, PATH_MOUNT, disk_use_mnt, disk_use_limit, disk_file_cnt_mnt, _TOrdConf.disk_limit_file);
			__LOG(LOG_INFO, "[DSK][%s:%d] evt : %0.1f/%0.1fGB", _FILE_, __LINE__, disk_use_evt, disk_size_evt);

			if (disk_file_cnt_mnt > _TOrdConf.disk_limit_file)
			{
				disk_op_f = TRUE;
                __LOG(LOG_NOTICE, "[DSK][%s:%d] %s file cnt : %d > %d", _FILE_, __LINE__, PATH_MOUNT, disk_file_cnt_mnt, _TOrdConf.disk_limit_file);
				ret = sprintf(str, "ls -pt %s | grep -v '/$' | tail -n %d | head -1", PATH_MOUNT, tail_mnt);
				fp = popen(str, "r");
				if (NULL == fp)
				{
					ret = -1;
					perror("popen() fail");
					__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
					break;
				}
				while (fgets(tmp, sizeof(tmp), fp));
				ord_chomp(tmp);

				ret = pclose(fp);
				if (ret < 0)
				{
					__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
					break;
				}

				__LOG(LOG_INFO, "[DSK][%s:%d] move target : %s", _FILE_, __LINE__, tmp);
				//__LOG(LOG_NOTICE, "[DSK][%s:%d] log_level : %d, %d, %d", _FILE_, __LINE__, LOG_INFO, log_level, _TOrdConf.log_level);
				//__LOG(LOG_NOTICE, "[DSK][%s:%d] strlen : %d, sizeof : %d", _FILE_, __LINE__, strlen(tmp), sizeof(tmp));
				if ((strstr(tmp, vhlConf.muxer) != NULL || strstr(tmp, ".srt") != NULL || strstr(tmp, ".bin") != NULL) && (strstr(tmp, vhlConf.vhl_name) != NULL))
				{
					char *date_ptr = strchr(tmp, '_');
					int date_index = (int)(date_ptr - tmp) + 1;
					sysTime = getTimeFromChar(tmp, date_index);
					__LOG(LOG_INFO, "[DSK][%s:%d] file date_index:%d", _FILE_, __LINE__, date_index);
                    if(sysTime.wYear >= 1900 && sysTime.wMonth <= 12 && sysTime.wDay <= 31 && sysTime.wHour <= 23 && sysTime.wMinute <= 59 && sysTime.wSecond <= 59)
                    {
						if (snprintf(mv_time, sizeof(mv_time), "%04d%02d%02d_%02d", sysTime.wYear, sysTime.wMonth, sysTime.wDay, sysTime.wHour) >= (int)sizeof(mv_time)) {
							ret = -1;
							break;
						}
					    //__LOG(LOG_NOTICE, "[DSK][%s:%d] mv_dir : %s", _FILE_, __LINE__, mv_time);
					    if (snprintf(mv_path, sizeof(mv_path), "%s/%s", PATH_RECYCLE, mv_time) >= (int)sizeof(mv_path)) {
							ret = -1;
							break;
						}
					    //__LOG(LOG_NOTICE, "[DSK][%s:%d] mv_path : %s", _FILE_, __LINE__, mv_path);
					    //makeDir(mv_path);
							if (snprintf(str, sizeof(str), "mkdir -p %s", mv_path) >= (int)sizeof(str)) {
								ret = -1;
								break;
							}
							ret = system(str);
							if (ret < 0) {
								__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
								break;
							}
					    //makeDir(my_strdup_printf("%s_%04d%02d%02d_%02d", vhlConf.vhl_name, sysTime.wYear, sysTime.wMonth, sysTime.wDay, sysTime.wHour));
					    if (snprintf(str, sizeof(str), "mv -f %s/*%s* %s/", PATH_MOUNT, mv_time, mv_path) >= (int)sizeof(str)) {
							ret = -1;
							break;
						}
							//sprintf(str, "mv -f %s/%s_%s* %s/", PATH_MOUNT, vhlConf.vhl_name, mv_time, mv_path);
					}
					else
					{
						__LOG(LOG_ERR, "[DSK][%s:%d] %s is not available format in %s", _FILE_, __LINE__, tmp, PATH_MOUNT);
						{
							char list_cmd[STR_LEN];
							sprintf(list_cmd, "ls -pt %s | grep -v '/$' | tail -n %d", PATH_MOUNT, fileSet_cnt);
							if (!ord_validate_cmd_token_lines(list_cmd)) {
								ret = -1;
								break;
							}
							sprintf(str, "ls -pt %s | grep -v '/$' | tail -n %d | xargs -t -I %% sh -c '{ rm -f %s/%%; }'", PATH_MOUNT, fileSet_cnt, PATH_MOUNT);
						}
					}
				}
				else
				{
					//sprintf(str, "rm -f %s/%s", PATH_MOUNT, tmp);
					__LOG(LOG_ERR, "[DSK][%s:%d] %s is not available format in %s", _FILE_, __LINE__, tmp, PATH_MOUNT);
					{
						char list_cmd[STR_LEN];
						sprintf(list_cmd, "ls -pt %s | grep -v '/$' | tail -n %d", PATH_MOUNT, fileSet_cnt);
						if (!ord_validate_cmd_token_lines(list_cmd)) {
							ret = -1;
							break;
						}
						sprintf(str, "ls -pt %s | grep -v '/$' | tail -n %d | xargs -t -I %% sh -c '{ rm -f %s/%%; }'", PATH_MOUNT, fileSet_cnt, PATH_MOUNT);
					}
				}

				__LOG(LOG_NOTICE, "[DSK][%s:%d] %s", _FILE_, __LINE__, str);
				ret = system(str);
				if (ret < 0) {
					__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
					tail_mnt+=_TOrdConf.cameraNum;
				}
				else tail_mnt = 1;
			}

			if (disk_use_mnt > disk_use_limit)
            {
				disk_op_f = TRUE;
				__LOG(LOG_NOTICE, "[DSK][%s:%d] %s %0.1f/%0.1f/%0.1fGB file %d/%d", _FILE_, __LINE__, PATH_MOUNT, \
					disk_use_mnt, disk_use_limit, disk_size_mnt, disk_file_cnt_mnt, _TOrdConf.disk_limit_file);

				// ret = sprintf(str, "find %s -maxdepth 1 -type f | grep -E '%s' | sort -r | tail -n 1 | head -n 1 | cut -d'/' -f6-", del_path, CAM_FILE_EXTENSION);
				// ret = sprintf(str, "ls -pt %s | grep -v '/$' | grep -E '%s' | tail -1", del_path, CAM_FILE_EXTENSION);
				//ret = sprintf(str, "find %s -maxdepth 1 -type d -exec stat --format='%%Y %%n' {} + | sort -r | tail -n 1 | head -n 1 | cut -d' ' -f2-", PATH_RECYCLE);	//time
				//ret = sprintf(str, "ls -d %s/*/ | sort -r |tail -1 |head -1", PATH_RECYCLE);		//name*/
                ret = sprintf(str, "find %s -mindepth 1 -maxdepth 1 -type d | sort -r |tail -n %d |head -1 |xargs basename", PATH_RECYCLE, tail_recycle);  //name
				__LOG(LOG_NOTICE, "[DSK][%s:%d] %s", _FILE_, __LINE__, str);
				fp = popen(str, "r");
				if (NULL == fp)
				{
					ret = -1;
					perror("popen() fail");
					__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
					break;
				}
				while (fgets(tmp, sizeof(tmp), fp));
				ord_chomp(tmp);
				//__E(LOG_LEVEL_TRA, "%s\n", str);

				ret = pclose(fp);
				if (ret < 0)
				{
					__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
					break;
				}
				__LOG(LOG_INFO, "[DSK][%s:%d] remove target : %s", _FILE_, __LINE__, tmp);

				if (tmp[0] == 0)
                {
                    sprintf(str, "ls -l %s | grep ^- | wc -l", PATH_RECYCLE);
                    fp = popen(str, "r");
                    if (NULL == fp)
                    {
                        ret = -1;
                        perror("popen() fail");
                        __LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
                        break;
                    }
					while (fgets(tmp, sizeof(tmp), fp));
					ord_chomp(tmp);
                    ret = pclose(fp);

					__LOG(LOG_ERR, "[DSK][%s:%d] no file in recycle folder, delete file in %s", _FILE_, __LINE__, PATH_MOUNT);
					{
						char list_cmd[STR_LEN];
						sprintf(list_cmd, "ls -pt %s | grep -v '/$' | tail -n %d", PATH_MOUNT, fileSet_cnt);
						if (!ord_validate_cmd_token_lines(list_cmd)) {
							ret = -1;
							break;
						}
						sprintf(str, "ls -pt %s | grep -v '/$' | tail -n %d | xargs -t -I %% sh -c '{ rm -f %s/%%; }'", PATH_MOUNT, fileSet_cnt, PATH_MOUNT);
					}
				}
				else
				{
					sysTime = getTimeFromChar(tmp, 0);
					if(sysTime.wYear >= 1900 && sysTime.wMonth <= 12 && sysTime.wDay <= 31 && sysTime.wHour <= 23)
                    {
						int n = snprintf(str, sizeof(str), "rm -r %s/%04d%02d%02d_%02d*", PATH_RECYCLE,
								sysTime.wYear, sysTime.wMonth, sysTime.wDay, sysTime.wHour);
						if (n < 0 || n >= (int)sizeof(str)) {
							ret = -1;
							break;
						}
					}
					else
					{
						__LOG(LOG_ERR, "[DSK][%s:%d] %s is not available format in %s", _FILE_, __LINE__, tmp, PATH_RECYCLE);
						memset(mv_path, 0, sizeof(mv_path));
						memcpy(mv_path, tmp, 11);
						if (!ord_is_safe_shell_token(mv_path)) {
							__LOG(LOG_ERR, "[DSK][%s:%d] unsafe recycle token: %s", _FILE_, __LINE__, mv_path);
							ret = -1;
							break;
						}
						if (snprintf(str, sizeof(str), "rm -r %s/%s*", PATH_RECYCLE, mv_path) >= (int)sizeof(str)) {
							ret = -1;
							break;
						}
					}
				}

				__LOG(LOG_NOTICE, "[DSK][%s:%d] %s", _FILE_, __LINE__, str);
				ret = system(str);
                if (ret != 0) {
                    __LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
					tail_recycle++;
                    //break;
                }
				else tail_recycle = 1;
			}

  			(disk_use_evt > disk_size_evt) ? (disk_size_over_evt=true):(disk_size_over_evt=false);
			//__LOG(LOG_NOTICE, "[DSK][%s:%d] _TOrdConf.event_auto_remove:%d", _FILE_, __LINE__, _TOrdConf.event_auto_remove);
			if((disk_size_over_evt || disk_file_cnt_evt > 15000) && vhlConf.event_auto_remove)
			{
				disk_op_f = TRUE;
				__LOG(LOG_NOTICE, "[DSK][%s:%d] evt : %0.1f/%0.1fGB %d/%d", _FILE_, __LINE__, disk_use_evt, disk_size_evt, disk_file_cnt_evt, 15000);
				ret = snprintf(str, sizeof(str), "ls -pt %s | grep -v '/$' | tail -n %d | head -1", PATH_EVENT, tail_event);
				if (ret < 0 || ret >= (int)sizeof(str)) {
					ret = -1;
					break;
				}
				__LOG(LOG_NOTICE, "[DSK][%s:%d] %s", _FILE_, __LINE__, str);
				// ret = sprintf(str, "ls -ptr /mnt/event | grep -v '/$' | awk 'NR == 1 {print $0; exit}'");
				fp = popen(str, "r");
				if (NULL == fp)
				{ 
					ret = -1;
					perror("popen() fail");
					__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
					break;
				}
				while (fgets(tmp, sizeof(tmp), fp));
				ord_chomp(tmp);
				ret = pclose(fp);
				if (ret < 0)
				{
					__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
					break;
				}
				// memset(tmp, 0, 25);
				// memcpy(tmp, str, 24);
				__LOG(LOG_INFO, "[DSK][%s:%d] evt remove target : %s", _FILE_, __LINE__, tmp);
				if((strstr(tmp, vhlConf.muxer) != NULL || strstr(tmp, ".srt") != NULL || strstr(tmp, ".bin") != NULL) && (strstr(tmp, vhlConf.vhl_name) != NULL))
				{
                    sysTime = getTimeFromChar(tmp, strlen(vhlConf.vhl_name)+1+4);
					if(sysTime.wYear >= 1900 && sysTime.wMonth <= 12 && sysTime.wDay <= 31 && sysTime.wHour <= 23 && sysTime.wMinute <= 59 && sysTime.wSecond <= 59)
                    {
						ret = snprintf(str, sizeof(str), "rm -r %s/%s_%s_%04d%02d%02d_%02d%02d*", PATH_EVENT, EVENT_FILE_NAME_PREFIX, vhlConf.vhl_name, \
								sysTime.wYear, sysTime.wMonth, sysTime.wDay, sysTime.wHour, sysTime.wMinute);
						if (ret < 0 || ret >= (int)sizeof(str)) {
							ret = -1;
							break;
						}
					}
					else
					{
						__LOG(LOG_ERR, "[DSK][%s:%d] %s is not available format in %s", _FILE_, __LINE__, tmp, PATH_EVENT);
						ord_chomp(tmp);
						if (!ord_is_safe_shell_token(tmp)) {
							__LOG(LOG_ERR, "[DSK][%s:%d] unsafe evt token: %s", _FILE_, __LINE__, tmp);
							ret = -1;
							break;
						}
						ret = snprintf(str, sizeof(str), "rm -r %s/%s*", PATH_EVENT, tmp);
						if (ret < 0 || ret >= (int)sizeof(str)) {
							ret = -1;
							break;
						}
					}
				}
				else
				{
					__LOG(LOG_ERR, "[DSK][%s:%d] %s is not available format in %s", _FILE_, __LINE__, tmp, PATH_EVENT);
					{
						char list_cmd[STR_LEN];
						ret = snprintf(list_cmd, sizeof(list_cmd), "ls -pt %s | grep -v '/$' | tail -n %d | head -n %d", PATH_EVENT, fileSet_cnt, fileSet_cnt);
						if (ret < 0 || ret >= (int)sizeof(list_cmd)) {
							ret = -1;
							break;
						}
						if (!ord_validate_cmd_token_lines(list_cmd)) {
							ret = -1;
							break;
						}
						ret = snprintf(str, sizeof(str), "ls -pt %s | grep -v '/$' | tail -n %d | head -n %d | xargs -t -I %% sh -c '{ rm -rf %s/%%; }'", \
									PATH_EVENT, fileSet_cnt, fileSet_cnt, PATH_EVENT);
						if (ret < 0 || ret >= (int)sizeof(str)) {
							ret = -1;
							break;
						}
					}
				}

				//ret = sprintf(str, "rm -f /%s/%s*", PATH_EVENT, tmp);
				__LOG(LOG_NOTICE, "[DSK][%s:%d] %s", _FILE_, __LINE__, str);
				ret = system(str);
				if (ret < 0) {
					__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
					tail_event++;
				}
				else tail_event = 1;
			}
		} while (0);

        if (disk_op_f || tail_mnt > 1 || tail_recycle > 1 || tail_event > 1)
            sleep(10);
        else
		    sleep(_TOrdConf.disk_manage_period);
	}

	__LOG(LOG_NOTICE, "[DSK][%s:%d] thread end", _FILE_, __LINE__);

	return ret;
}

int CTCPServer::waitingCopy(void* pData)
{
	FILE *fp;
	//long arg = *(long *)pData;
	MultipleArg *arg = (MultipleArg *)pData;
	int ret = 0;
	char str[512];
	uint64_t disk_use;
	char fileName[128];
	bool target_copy_err;
	int fd = arg->fd;
	char rmsChar[32] = "";
	float rmsMax;
	//uint64_t disk_limit = vhlConf.event_storage_size*1024 - _TOrdConf.free_space;
	//uint8_t disk_limit_per, disk_use_per;

	__LOG(LOG_NOTICE, "[EVT][%s:%d] thNum%d fd:%d diff:%d delay:%d copyTail:%d copyHead:%d copyType:%d", _FILE_, __LINE__, \
				 arg->threadNum, arg->fd, arg->diff, arg->delay, arg->copyTail, arg->copyHead, arg->copyType);
	
	do
	{
		if(m_flagDestroy)
			break ;

		__LOG(LOG_NOTICE, "[EVT][%s:%d] thNum%d sleep : %dsec", _FILE_, __LINE__, arg->threadNum, arg->delay);

		usleep((arg->delay)*SEC);

		//__LOG(LOG_NOTICE, "[CPY][%s:%d] wake up", _FILE_, __LINE__);
target_copy:
		target_copy_err = FALSE;
		if(_TOrdConf.vib_enable)
		{
			do
			{
				snprintf(fileName, sizeof(fileName), "%s/%s_%04d%02d%02d_%02d%02d%02d-vib.bin", PATH_MOUNT, vhlConf.vhl_name, arg->copyTime.wYear, \
						arg->copyTime.wMonth, arg->copyTime.wDay, arg->copyTime.wHour, arg->copyTime.wMinute, 0);
				//sprintf(str, "cp /home/user/VD3001_20250115_123700-vib.bin %s", fileName);
				//system(str);
				//sprintf(fileName, "%s/VD3001_20250116_095000-vib.bin", PATH_MOUNT);
				__LOG(LOG_NOTICE, "[EVT][%s:%d] read rms fileName : %s", _FILE_, __LINE__, fileName);

				FILE *file = fopen(fileName, "rb");
				if (!file) {
					__LOG(LOG_ERR, "[EVT][%s:%d] fopen() fail", _FILE_, __LINE__);
					break;
				}

				if (fseek(file, 28, SEEK_SET) != 0) {
					__LOG(LOG_ERR, "[EVT][%s:%d] fseek() fail", _FILE_, __LINE__);
					fclose(file);
					break;
				}

				if (fread(&rmsMax, sizeof(float), 1, file) != 1) {
					__LOG(LOG_ERR, "[EVT][%s:%d] fread() fail", _FILE_, __LINE__);
					fclose(file);
					break;
				}

				__LOG(LOG_NOTICE, "[EVT][%s:%d] rmsMax:%f", _FILE_, __LINE__, rmsMax);
				sprintf(rmsChar, "_rmsMax_%0.1f", rmsMax);
			} while(0);
		}
		
		snprintf(fileName, sizeof(fileName), "%s_%04d%02d%02d_%02d%02d%02d", vhlConf.vhl_name, arg->copyTime.wYear, arg->copyTime.wMonth, \
				arg->copyTime.wDay, arg->copyTime.wHour, arg->copyTime.wMinute, 0);	//arg->copyTime.wSecond);

		__LOG(LOG_NOTICE, "[EVT][%s:%d] thNum%d wake up, target name : %s", _FILE_, __LINE__, arg->threadNum, fileName);

		if(_TOrdConf.target_copy)
		{
			if(vhlConf.camConfig[0].enable) {
				ret = snprintf(str, sizeof(str), "cp %s/%s-ch0.%s %s/%s_%s%s-ch0.%s", PATH_MOUNT, fileName, vhlConf.muxer, PATH_EVENT,EVENT_FILE_NAME_PREFIX, fileName, rmsChar, vhlConf.muxer);
				__LOG(LOG_NOTICE, "[EVT][%s:%d] thNum%d : %s", _FILE_, __LINE__, arg->threadNum, str);
				ret = system(str);
				if(ret != 0) {
					__LOG(LOG_ERR, "[EVT][%s:%d] thNum%d ret:%d", _FILE_, __LINE__, arg->threadNum, ret);
					target_copy_err = TRUE;
					//goto tail_copy;
				}
			}
			if(vhlConf.camConfig[1].enable) {
				ret = snprintf(str, sizeof(str), "cp %s/%s-ch1.%s %s/%s_%s%s-ch1.%s", PATH_MOUNT, fileName, vhlConf.muxer, PATH_EVENT,EVENT_FILE_NAME_PREFIX, fileName, rmsChar, vhlConf.muxer);
				__LOG(LOG_NOTICE, "[EVT][%s:%d] thNum%d : %s", _FILE_, __LINE__, arg->threadNum, str);
				ret = system(str);
				if(ret != 0) {
					__LOG(LOG_ERR, "[EVT][%s:%d] thNum%d ret:%d", _FILE_, __LINE__, arg->threadNum, ret);
					target_copy_err = TRUE;
					//goto tail_copy;
				}
			}
			if(vhlConf.camConfig[2].enable) {
				ret = snprintf(str, sizeof(str), "cp %s/%s-ch2.%s %s/%s_%s%s-ch2.%s", PATH_MOUNT, fileName, vhlConf.muxer, PATH_EVENT,EVENT_FILE_NAME_PREFIX, fileName, rmsChar, vhlConf.muxer);
				__LOG(LOG_NOTICE, "[EVT][%s:%d] thNum%d : %s", _FILE_, __LINE__, arg->threadNum, str);
				ret = system(str);
				if(ret != 0) {
					__LOG(LOG_ERR, "[EVT][%s:%d] thNum%d ret:%d", _FILE_, __LINE__, arg->threadNum, ret);
					target_copy_err = TRUE;
					//goto tail_copy;
				}
			}
			if(vhlConf.camConfig[3].enable) {
				ret = snprintf(str, sizeof(str), "cp %s/%s-ch3.%s %s/%s_%s%s-ch3.%s", PATH_MOUNT, fileName, vhlConf.muxer, PATH_EVENT,EVENT_FILE_NAME_PREFIX, fileName, rmsChar, vhlConf.muxer);
				__LOG(LOG_NOTICE, "[EVT][%s:%d] thNum%d : %s", _FILE_, __LINE__, arg->threadNum, str);
				ret = system(str);
				if(ret != 0) {
					__LOG(LOG_ERR, "[EVT][%s:%d] thNum%d ret:%d", _FILE_, __LINE__, arg->threadNum, ret);
					target_copy_err = TRUE;
					//goto tail_copy;
				}
			}
			if(_TOrdConf.srt_enable) {
				ret = snprintf(str, sizeof(str), "cp %s/%s-data.srt %s/%s_%s%s-data.srt", PATH_MOUNT, fileName, PATH_EVENT,EVENT_FILE_NAME_PREFIX, fileName, rmsChar);
				__LOG(LOG_NOTICE, "[EVT][%s:%d] thNum%d : %s", _FILE_, __LINE__, arg->threadNum, str);
				ret = system(str);
				if(ret != 0) {
					__LOG(LOG_ERR, "[EVT][%s:%d] thNum%d ret:%d", _FILE_, __LINE__, arg->threadNum, ret);
					target_copy_err = TRUE;
					//goto tail_copy;
				}
			}
			if(_TOrdConf.vib_enable) {
				ret = snprintf(str, sizeof(str), "cp %s/%s-vib.bin %s/%s_%s%s-vib.bin", PATH_MOUNT, fileName, PATH_EVENT,EVENT_FILE_NAME_PREFIX, fileName, rmsChar);
				__LOG(LOG_NOTICE, "[EVT][%s:%d] thNum%d : %s", _FILE_, __LINE__, arg->threadNum, str);
				ret = system(str);
				if(ret != 0) {
					__LOG(LOG_ERR, "[EVT][%s:%d] thNum%d ret:%d", _FILE_, __LINE__, arg->threadNum, ret);
					target_copy_err = TRUE;
					//goto tail_copy;
				}
			}

			if(target_copy_err) goto tail_copy;

			if(arg->copyType == COPY_TYPE_HEAD || arg->copyType == COPY_TYPE_TAIL)
			{
				sprintf(str, "date '+%%Y:%%m:%%d:%%H:%%M:%%S' -d '%04d%02d%02d %02d:%02d:%02d %d min %s'", arg->copyTime.wYear, arg->copyTime.wMonth, arg->copyTime.wDay, \
					arg->copyTime.wHour, arg->copyTime.wMinute, arg->copyTime.wSecond, vhlConf.recMinute, arg->copyType == COPY_TYPE_HEAD? "ago":"");
				__LOG(LOG_NOTICE, "[EVT][%s:%d] thNum%d : %s", _FILE_, __LINE__, arg->threadNum, str);
				fp = popen(str, "r");
				if (NULL == fp) {
					ret = -1;
					perror("popen() fail");
					__LOG(LOG_ERR, "[EVT][%s:%d] thNum%d ret:%d", _FILE_, __LINE__, arg->threadNum, ret);
					break;
				}
				while (fgets(str, STR_LEN, fp));
				ret = pclose(fp);
				//__E(LOG_LEVEL_TRA, "%s\n", str);
				arg->copyTime.wYear = atoi(str);
				arg->copyTime.wMonth = atoi(str+5);
				arg->copyTime.wDay = atoi(str+8);
				arg->copyTime.wHour = atoi(str+11);
				arg->copyTime.wMinute = atoi(str+14);
				arg->copyTime.wSecond = atoi(str+17);
				//sprintf(fileName, "%s_%s", vhlConf.vhl_name, str);
				//__E(LOG_LEVEL_TRA, "%s\n", fileName);
				arg->copyType = COPY_TYPE_BODY;

				goto target_copy;
			}
		}
		else
		{
					tail_copy:
			__LOG(LOG_NOTICE, "[EVT][%s:%d] thNum%d wake up", _FILE_, __LINE__, arg->threadNum);
			{
				char list_cmd[STR_LEN];
				sprintf(list_cmd, "ls -ptr %s | grep -v '/$'| grep %s | tail -%d | head -%d", \
							PATH_MOUNT, vhlConf.vhl_name, arg->copyTail, arg->copyHead);
				if (!ord_validate_cmd_token_lines(list_cmd)) {
					ret = -1;
					break;
				}
			}
			ret = sprintf(str, "ls -ptr %s | grep -v '/$'| grep %s | tail -%d | head -%d | xargs -t -I %% sh -c '{ cp -a %s/%% %s/%s_%%; }'", \
								PATH_MOUNT, vhlConf.vhl_name, arg->copyTail, arg->copyHead, PATH_MOUNT, PATH_EVENT, EVENT_FILE_NAME_PREFIX);

			__LOG(LOG_NOTICE, "[EVT][%s:%d] thNum%d tail copy : %s", _FILE_, __LINE__, arg->threadNum, str);
			ret = system(str);
			if(ret != 0) {
				__LOG(LOG_ERR, "[EVT][%s:%d] thNum%d ret:%d", _FILE_, __LINE__, arg->threadNum, ret);
				break;
			}
		}

	} while(0);

	if(fd > 0)
	{
		if(ret != 0)
			responseEvent(fd, EVT_COPY, EVT_RESULT_FAIL);
		else
			responseEvent(fd, EVT_COPY, EVT_RESULT_SUCCESS);
	}

    ret = system("sync");
    if(ret != 0) {
        __LOG(LOG_ERR, "[EVT][%s:%d] thNum%d sync fail(%d)", _FILE_, __LINE__, arg->threadNum, ret);
    }
	//if(ret < 0) __LOG(LOG_CRIT,"[%s:%d][DSK] ret:%d", _FILE_, __LINE__, ret);

	__LOG(LOG_NOTICE, "[EVT][%s:%d] thNum%d end : sync", _FILE_, __LINE__, arg->threadNum);
	//if(fp) pclose(fp);
	free(arg);

#if 0
	if(err < 0) 
		sendBuf.cmd[sendBuf.inptr++] = RES_ERROR;
	else
		sendBuf.cmd[sendBuf.inptr++] = RES_EVT_COPY;
#endif

	return ret;
}

CTCPServer* CTCPServer::getInstance()
{
	static CTCPServer instance ;
	return &instance ;
}

int CTCPServer::setMaxFD(int newFD, int maxFD)
{
	maxFD = (newFD > maxFD) ? newFD : maxFD ;

	return maxFD ;
}

void CTCPServer::init_json_config()
{
	uint8_t i;

	dbg_level = 0;
	log_level = 5;

	strncpy(vhlConf.vhl_name, "VD3000", sizeof(vhlConf.vhl_name)-1);
	vhlConf.recMinute = 1;
	vhlConf.event_storage_size = 5;
	vhlConf.event_auto_remove = TRUE;
	strncpy(vhlConf.tmp_path, PATH_TMP, sizeof(vhlConf.tmp_path)-1);
	strncpy(vhlConf.log_path, PATH_LOG, sizeof(vhlConf.log_path)-1);
	strncpy(vhlConf.mount_path, PATH_MOUNT, sizeof(vhlConf.mount_path)-1);
	strncpy(vhlConf.event_path, PATH_EVENT, sizeof(vhlConf.event_path)-1);
	strncpy(vhlConf.recycle_path, PATH_RECYCLE, sizeof(vhlConf.recycle_path)-1);
	strncpy(vhlConf.json_path, PATH_JSON, sizeof(vhlConf.json_path)-1);
	strncpy(vhlConf.muxer, "mp4", sizeof(vhlConf.muxer)-1);

    for(i=0; i<4; i++)
    {
		vhlConf.camConfig[i].enable = TRUE;
		vhlConf.camConfig[i].hflip = FALSE;
		vhlConf.camConfig[i].vflip = FALSE;
	}
	
	_TOrdConf.srt_enable = TRUE;
	_TOrdConf.vib_enable = FALSE;
	_TOrdConf.vhl_max = 1;
	_TOrdConf.portNum = 10007;
	_TOrdConf.margin_sec = 10;
	memset(_TOrdConf.ip_addr, 0, sizeof(_TOrdConf.ip_addr));
	_TOrdConf.disk_manage = TRUE;
	_TOrdConf.target_copy = TRUE;
	_TOrdConf.disk_limit_per = 95;
	_TOrdConf.disk_limit_file = 1000;
	_TOrdConf.disk_manage_period = 40;
	_TOrdConf.rtc_reset = true;
	_TOrdConf.debug_level = 0;
	_TOrdConf.log_level = 5;
	_TOrdConf.ovl_buffering = 0;
    _TOrdConf.err_send_period = 0;
}

int CTCPServer::get_json_config()
{
	int ret = 0;
	json_object * pJsonObject = NULL;
    json_object *hobj = NULL, *sobj = NULL, *vobj = NULL;
	char* json_file;
	char str[8];
	uint8_t i;
	int max_bps = 0;
	const char* tmp_str = NULL;

	json_file = search_json_file(vhlConf.json_path, (char*)JSON_NAME_PREFIX, (char*)JSON_NAME_SUFFIX);
    __LOG(LOG_INFO, "[CFG][%s:%d] json file name : %s", _FILE_, __LINE__, json_file);

    if(strstr(json_file, JSON_NAME_PREFIX) == NULL || strstr(json_file, JSON_NAME_SUFFIX) == NULL) {
        __LOG(LOG_CRIT, "[CFG][%s:%d] json file name not match %s %s", _FILE_, __LINE__, JSON_NAME_PREFIX, JSON_NAME_SUFFIX);
        return -1;
    }

	pJsonObject = json_object_from_file(json_file);
	hobj = json_object_object_get(pJsonObject, JSON_HEADER_VHL);
	if (json_object_get_value(hobj, "vhl_name", &tmp_str) == 0) strncpy(vhlConf.vhl_name, tmp_str, sizeof(vhlConf.vhl_name)-1);
	json_object_get_value(hobj, "recording_time", &vhlConf.recMinute);
	json_object_get_value(hobj, "event_storage_size", &vhlConf.event_storage_size);
	json_object_get_value(hobj, "event_auto_remove", &vhlConf.event_auto_remove);
	if (json_object_get_value(hobj, "tmp_path", &tmp_str) == 0) strncpy(vhlConf.tmp_path, tmp_str, sizeof(vhlConf.tmp_path)-1);
	if (json_object_get_value(hobj, "muxer", &tmp_str) == 0) strncpy(vhlConf.muxer, tmp_str, sizeof(vhlConf.muxer)-1);

    for(i=0; i<4; i++)
    {
		sprintf(str, "i2c%d", i/2? 1:2);
		sobj = json_object_object_get(hobj, str);
		sprintf(str, "ch%d", i);
        vobj = json_object_object_get(sobj, str);
        json_object_get_value(vobj, "enable", &vhlConf.camConfig[i].enable);
        json_object_get_value(vobj, "hflip", &vhlConf.camConfig[i].hflip);
        json_object_get_value(vobj, "vflip", &vhlConf.camConfig[i].vflip);
        json_object_get_value(vobj, "bps", &vhlConf.camConfig[i].bps);

		if(vhlConf.camConfig[i].bps[0] > max_bps) max_bps = vhlConf.camConfig[i].bps[0];
	}
	json_object_put(pJsonObject); // Free first file

	char ord_json_file[256];
	if (access(ORD_VCM_JSON_FILE, R_OK) == 0) {
		strncpy(ord_json_file, ORD_VCM_JSON_FILE, sizeof(ord_json_file)-1);
	} else {
		snprintf(ord_json_file, sizeof(ord_json_file), "%s/ord_vcm_conf.json", PATH_JSON_LOCAL);
		__LOG(LOG_WARNING, "[CFG][%s:%d] %s not found, trying fallback: %s", _FILE_, __LINE__, ORD_VCM_JSON_FILE, ord_json_file);
	}

	pJsonObject = json_object_from_file(ord_json_file);
	if (!pJsonObject) {
		__LOG(LOG_CRIT, "[CFG][%s:%d] Failed to load JSON config from %s", _FILE_, __LINE__, ord_json_file);
		return -1;
	}

	hobj = json_object_object_get(pJsonObject, JSON_HEADER_VCM);
	json_object_get_value(hobj, "srt_enable", &_TOrdConf.srt_enable);
	json_object_get_value(hobj, "ops_enable", &_TOrdConf.ops_enable);

	hobj = json_object_object_get(pJsonObject, JSON_HEADER_ORD);
	json_object_get_value(hobj, "port_num", &_TOrdConf.portNum);
	json_object_get_value(hobj, "vhl_max", &_TOrdConf.vhl_max);
	json_object_get_value(hobj, "copy_margin_sec", &_TOrdConf.margin_sec);
	if (json_object_get_value(hobj, "ip_static", &tmp_str) == 0) strncpy(_TOrdConf.ip_addr, tmp_str, sizeof(_TOrdConf.ip_addr)-1);
	json_object_get_value(hobj, "disk_manage", &_TOrdConf.disk_manage);
	json_object_get_value(hobj, "target_copy", &_TOrdConf.target_copy);
	json_object_get_value(hobj, "disk_limit_file", &_TOrdConf.disk_limit_file);
	json_object_get_value(hobj, "disk_manage_period", &_TOrdConf.disk_manage_period);
	json_object_get_value(hobj, "rtc_reset", &_TOrdConf.rtc_reset);
	json_object_get_value(hobj, "debug_level", &_TOrdConf.debug_level);
	json_object_get_value(hobj, "log_level", &_TOrdConf.log_level);
	json_object_get_value(hobj, "disk_limit_per", &_TOrdConf.disk_limit_per);
	json_object_get_value(hobj, "vib_enable", &_TOrdConf.vib_enable);
	json_object_get_value(hobj, "ovl_buffering", &_TOrdConf.ovl_buffering);
	json_object_get_value(hobj, "evt_copy_delay", &_TOrdConf.evt_copy_delay);
    json_object_get_value(hobj, "err_send_period", &_TOrdConf.err_send_period);

	dbg_level = _TOrdConf.debug_level;
	log_level = _TOrdConf.log_level;
	_TOrdConf.event_storage_size = vhlConf.event_storage_size;
	
	if(strcmp(PATH_MOUNT, vhlConf.tmp_path) == 0) {
        path_eq_f = 1;
    } else {
        path_eq_f = 0;
        _TOrdConf.evt_copy_delay += ((max_bps/1024)*vhlConf.recMinute);
    }

	json_object_put(pJsonObject); // Free second file
	return 0;
}

int CTCPServer::init()
{
	int ret ;
	int option = 1 ;
	char str[STR_LEN];
	FILE *fp;

	m_flagDestroy = 0 ;

	m_serverSocket = -1 ;
	m_clientSocket = -1 ;

	m_fdMax = -1 ;
	e_fdMax = -1 ;

    disk_use_limit = 0;
    disk_size_mnt = 0;
    disk_size_evt = 0;
    disk_size_over_evt = 0;
    errorData = 0;
    vhl_cnt = 0;
    path_eq_f = 0;
    vhl_new_f = 0;

#ifdef SENDQUEUE_ENABLE
	sendBuf.inptr = 0;
	sendBuf.outptr = 0;
	memset(sendBuf.cmd, 0, QUEUE_SIZE);
#endif

#ifdef SEGFAULT_DEBUG
	struct sigaction sa;
	memset(&sa, 0, sizeof(struct sigaction));
	sigemptyset(&sa.sa_mask);
	sa.sa_sigaction = segfault_sigaction;
	sa.sa_flags = SA_SIGINFO;
	sigaction(SIGSEGV, &sa, NULL);
#endif

	init_json_config();

    sleep(2);

	ret = get_json_config();
	if(ret < 0) {
		__LOG(LOG_CRIT, "[CFG][%s:%d] get json config fail", _FILE_, __LINE__);
		return ret;
	}

    //checkSD();
	init_queue(&_TOvlQueue, OVL_MAX_QUEUE_SIZE, MAX_DATA_LEN);

	//unsigned short serverPort = TCP_TEST_PORT ;
	sockaddr_in serverAddr ;

	m_serverSocket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP) ;

	if(m_serverSocket < 0) {
		__LOG(LOG_CRIT, "[TCP][%s:%d] cannot create socket", _FILE_, __LINE__) ;
		//m_flagDestroy = 1;
		return m_serverSocket;
	}

	memset(&serverAddr, 0x0, sizeof(sockaddr_in)) ;

	serverAddr.sin_family 		= AF_INET ;
	serverAddr.sin_addr.s_addr 	= htonl(INADDR_ANY) ;
	//serverAddr.sin_addr.s_addr = inet_addr("192.168.1.28");
	//serverAddr.sin_addr.s_addr = inet_addr("100.100.100.101");

	memset(_TOrdConf.ip_addr, 0, sizeof(_TOrdConf.ip_addr));
	if(strlen(_TOrdConf.ip_addr) > 0)
		serverAddr.sin_addr.s_addr = inet_addr(_TOrdConf.ip_addr);
	else
		serverAddr.sin_addr.s_addr = htonl(INADDR_ANY);
	
	__LOG(LOG_INFO, "[TCP][%s:%d] ip : %s, port : %d, socket : %d", _FILE_, __LINE__, inet_ntoa(serverAddr.sin_addr), _TOrdConf.portNum, m_serverSocket);
	serverAddr.sin_port = htons(_TOrdConf.portNum) ;

	setsockopt(m_serverSocket, SOL_SOCKET, SO_REUSEADDR, &option, sizeof(option)) ;

	ret = bind(m_serverSocket, (struct sockaddr*)&serverAddr, sizeof(sockaddr_in));
	if(ret < 0 ) {
		__LOG(LOG_CRIT, "[TCP][%s:%d] Server bind failed", _FILE_, __LINE__) ;
		//m_flagDestroy = 1;
		return ret;
	}

	ret = listen(m_serverSocket, MAXPENDING);
	if(ret < 0 ) {
		__LOG(LOG_CRIT, "[TCP][%s:%d] Server listen failed", _FILE_, __LINE__) ;
		//m_flagDestroy = 1;
		return ret;
	}

	// create pipes. The pipe will be used to wake up blocked select().
	//pipe(m_pipe) ;

	FD_ZERO(&m_fds) ;
	FD_ZERO(&e_fds) ;
	FD_SET(m_serverSocket, &m_fds) ;
	//FD_SET(m_pipe[0], &m_fds) ;

	m_fdMax = setMaxFD(m_serverSocket, m_fdMax) ;
	//setMaxFD(m_pipe[0]) ;

	ret = pthread_create(&m_threadConnect, NULL, &thread_waitingConnect, NULL);
	if(ret < 0) {
		__LOG(LOG_CRIT, "[TCP][%s:%d] ret:%d", _FILE_, __LINE__, ret);
		return ret;
	}

	ret = pthread_create(&m_threadError, NULL, &thread_waitingError, NULL);
	if(ret < 0) {
		__LOG(LOG_CRIT, "[TCP][%s:%d] ret:%d", _FILE_, __LINE__, ret);
		return ret;
	}

	if(_TOrdConf.vib_enable) {
		ret = pthread_create(&m_threadRedis, NULL, &thread_waitingRedis, NULL);
		if(ret < 0) {
			__LOG(LOG_CRIT, "[TCP][%s:%d] ret:%d", _FILE_, __LINE__, ret);
			return ret;
		}
	}

	if(_TOrdConf.disk_manage) {
		ret = pthread_create(&m_threadDisk, NULL, &thread_waitingDisk, NULL);
		if(ret < 0) {
			__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
			return ret;
		}
	}

	//ret = pthread_create(&m_threadGetOPS, NULL, &thread_waitingGetOPS, NULL);

	return ret;
}

int CTCPServer::destroy()
{
	int ret ;
	m_flagDestroy = 1 ;

	__LOG(LOG_EMERG, "[CFG][%s:%d] call server destroy", _FILE_, __LINE__) ;

	// away server thread.
	//write(m_pipe[1], &ret, 1) ;
	free_queue(&_TOvlQueue);

	void* nStatus ;
	ret = pthread_join(m_threadConnect, &nStatus);
	if(ret != 0)
		__LOG(LOG_CRIT, "[TCP][%s:%d] ret:%d", _FILE_, __LINE__, ret);

	if(_TOrdConf.disk_manage) {
		ret = pthread_join(m_threadDisk, &nStatus);
		if(ret != 0)
			__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
	}

	ret = pthread_join(m_threadError, &nStatus);
	if(ret != 0)
		__LOG(LOG_CRIT, "[ERR][%s:%d] ret:%d", _FILE_, __LINE__, ret);

	if(_TOrdConf.vib_enable) {
		ret = pthread_join(m_threadRedis, &nStatus);
		if(ret != 0)
			__LOG(LOG_CRIT, "[OPS][%s:%d] ret:%d", _FILE_, __LINE__, ret);
	}

	//close(m_pipe[0]) ;
	//close(m_pipe[1]) ;

	if(m_serverSocket >= 0) {
		ret = close(m_serverSocket);
		if(ret < 0)
			__LOG(LOG_CRIT, "[TCP][%s:%d] ret:%d", _FILE_, __LINE__, ret);
		//__E(LOG_LEVEL_TRA, "ret1 : %d\n", ret) ;
	}

	if(m_clientSocket >= 0) {
		ret = close(m_clientSocket);
		if(ret < 0)
			__LOG(LOG_CRIT, "[TCP][%s:%d] ret:%d", _FILE_, __LINE__, ret);
		//__E(LOG_LEVEL_TRA, "ret2 : %d\n", ret) ;
	}

	//m_flagDestroy = 0 ;

	exit(0);

	return 1 ;
}

int CTCPServer::sendDataIPC(char* data, int len)
{
	static time_t last_eagain_log_sec;
	int ret = 0;
	int msg_id = msgget((key_t)MSG_Q_KEY, IPC_CREAT | 0660);
	
	if (msg_id == -1) {
		ret = -1;
		perror("msgget fail");
		__LOG(LOG_ERR, "[IPC][%s:%d] ret:%d", _FILE_, __LINE__, ret);
		return ret;
	}

	_MSGQueue msgBuf;
	msgBuf.type = PMSG_TYPE_1;

	memcpy(msgBuf.data.byte, data, len);
	for (int attempt = 0; attempt < 2; attempt++) {
		ret = msgsnd(msg_id, &msgBuf, len, IPC_NOWAIT);
		if (ret >= 0) {
			__LOG(LOG_INFO, "[IPC][%s:%d] send data msg_id(%d) byte  %d", _FILE_, __LINE__, msg_id, len);
			break;
		}
		int send_errno = errno;
		if (send_errno == EAGAIN) {
			time_t now = time(NULL);
			if (now - last_eagain_log_sec >= 5) {
				__LOG(LOG_WARNING, "[IPC][%s:%d] msgq full (vcm down?). drop data. errno=%d(%s)", _FILE_, __LINE__, send_errno, strerror(send_errno));
				last_eagain_log_sec = now;
			}
			return 0;
		}
		if (attempt == 0 && (send_errno == EIDRM || send_errno == ENOENT || send_errno == EINVAL)) {
			msg_id = msgget((key_t)MSG_Q_KEY, IPC_CREAT | 0660);
			if (msg_id == -1)
				break;
			continue;
		}
		errno = send_errno;
		perror("msgsnd fail");
		__LOG(LOG_ERR, "[IPC][%s:%d] ret:%d errno=%d(%s)", _FILE_, __LINE__, ret, send_errno, strerror(send_errno));
		return ret;
	}

/*
	for (int i = 0; i < len; i++)
		__E(LOG_LEVEL_MSG, "%02x", data[i]);
	__E(LOG_LEVEL_MSG, "\n");
*/
	return 0;
}

int CTCPServer::sendDataTCP(int fd, char* data, int len)
{
	if (!data || len <= 0)
		return 0;

	size_t total_sent = 0;
	int eagain_attempts = 0;

	while (total_sent < (size_t)len) {
		size_t remaining = (size_t)len - total_sent;
		errno = 0;
		ssize_t n = send(fd, data + total_sent, remaining, MSG_DONTWAIT);
		if (n > 0) {
			total_sent += (size_t)n;
			eagain_attempts = 0;
			continue;
		}
		if (n == 0) {
			__LOG(LOG_ERR, "[TCP][%s:%d] send returned 0", _FILE_, __LINE__);
			return -1;
		}

		int send_errno = errno;
		if (send_errno == EINTR)
			continue;
		if (send_errno == EAGAIN || send_errno == EWOULDBLOCK) {
			if (++eagain_attempts >= 3) {
				__LOG(LOG_WARNING, "[TCP][%s:%d] send would block (fd=%d). drop. sent=%zu/%d", _FILE_, __LINE__, fd, total_sent, len);
				return -1;
			}
			usleep(1000);
			continue;
		}

		errno = send_errno;
		perror("tcpsnd fail");
		__LOG(LOG_CRIT,"[TCP][%s:%d] ret:%d errno=%d(%s)", _FILE_, __LINE__, (int)n, send_errno, strerror(send_errno));
		return -1;
	}

	__LOG(LOG_INFO, "[TCP][%s:%d] send data socket_id(%d) byte %d", _FILE_, __LINE__, fd, len);
	for (int i = 0; i < len; i++)
		__LOG(LOG_DEBUG, "[TCP][%s:%d] (%d)0x%02x", _FILE_, __LINE__, i, data[i]);

	return 0;
}

int CTCPServer::responseEvent(int fd, uint8_t type, uint8_t result)
{
	TOhtData _TOhtData;
	const char *typeStr[] = {"null", "copy", "priority", "test", "overlay", "rtc", "error", ""};

	_TOhtData.fmt.machineType = htons(MACHINE_TYPE_BLACKBOX);
	ord_set_machine_id(&vhlConf, _TOhtData.fmt.machineID);
	_TOhtData.fmt.cmd = htons(CMD_EVENTACK_BLACKBOX);
	_TOhtData.fmt.eventType = type;
	_TOhtData.fmt.eventResult = result;

	__LOG(LOG_NOTICE, "[EVT][%s:%d] %s event result : %s", _FILE_, __LINE__, typeStr[type], result? "success":"fail");

	return sendDataTCP(fd, _TOhtData.byte, 12);
}

int CTCPServer::waitingConnect()
{
	char szBuf[BUF_SIZE] ;

	int fd ;
	int ret = 0;

	unsigned int clientLen ;

	fd_set 	checkFds ;

	int nread = 0;

	int flagAccept = 0 ;

	const unsigned char SERVER_RECEIVES_CONNECTION_REQUEST 	= 1 ;
	const unsigned char SERVER_RECEIVES_DATA 		= 2 ;
	const unsigned char SERVER_CLOSES_CLIENT_CONNECTION 	= 3 ;
	unsigned char flagStatus = 0 ;

	sockaddr_in clientAddr ;

	while(1)
	{
		usleep(10000) ;

		if(m_flagDestroy)
			break ;

		checkFds = m_fds ;

		ret = select(m_fdMax + 1, &checkFds, 0, 0, NULL);
		if(ret < 0) {
			__LOG(LOG_CRIT, "[TCP][%s:%d] selecet ret:%d", _FILE_, __LINE__, ret);
			continue;
		}


		for(fd = 0; fd <= m_fdMax ; fd++)
		{
			if(!FD_ISSET(fd, &checkFds))
				continue ;

			//if(FD_ISSET(m_pipe[0], &checkFds))
				//break ;

			if(fd == m_serverSocket)
			{
				flagStatus = SERVER_RECEIVES_CONNECTION_REQUEST ;
			}
			else
			{
				ret = ioctl(fd, FIONREAD, &nread);
				if(ret < 0) {
					__LOG(LOG_CRIT, "[TCP][%s:%d] ioctl ret:%d", _FILE_, __LINE__, ret);
					/* Fall back to treating as readable; recv() handles real state */
					nread = 1;
				}

				if(nread == 0) 
					flagStatus = SERVER_CLOSES_CLIENT_CONNECTION ;
				else
					flagStatus = SERVER_RECEIVES_DATA ;
			}
			
			switch(flagStatus)
			{
			case SERVER_RECEIVES_CONNECTION_REQUEST :
				__LOG(LOG_NOTICE, "[TCP][%s:%d] server receive connection request oht(%d)", _FILE_, __LINE__, fd) ;
				clientLen = sizeof(clientAddr);
				m_clientSocket = accept(fd, (struct sockaddr*)&clientAddr, (socklen_t*)&clientLen) ;

				if(m_clientSocket < 0) {
					ret = m_clientSocket;
					__LOG(LOG_CRIT, "[TCP][%s:%d] accept ret:%d", _FILE_, __LINE__, ret);
					break;
				}
 /*
				//debug_printf("%s\n",inet_ntoa(clientAddr.sin_addr));
				if (strcmp(inet_ntoa(clientAddr.sin_addr), get_str_from_json(JSON_FILE, "VSD", "ip_oht")) == 0)
					fd_oht = m_clientSocket;
				if (strcmp(inet_ntoa(clientAddr.sin_addr), get_str_from_json(JSON_FILE, "VSD", "ip_pc")) == 0)
					fd_pc = m_clientSocket;
*/
				__LOG(LOG_NOTICE, "[TCP][%s:%d] after accept & m_clientSocket : %d", _FILE_, __LINE__, m_clientSocket) ;
				__LOG(LOG_ALERT, "[TCP][%s:%d] client ip addr : %s", _FILE_, __LINE__, inet_ntoa(clientAddr.sin_addr));

				if(vhl_cnt >= _TOrdConf.vhl_max) {
					__LOG(LOG_ALERT, "[TCP][%s:%d] vhl connect fail (vhl_cnt:%d vhl_max:%d)", _FILE_, __LINE__, vhl_cnt, _TOrdConf.vhl_max);
					close(m_clientSocket);
					break;
        		}

                vhl_new_f = 1;
				vhl_cnt++;

				FD_SET(m_clientSocket, &m_fds) ;
				m_fdMax = setMaxFD(m_clientSocket, m_fdMax) ;
				FD_SET(m_clientSocket, &e_fds) ;
				e_fdMax = setMaxFD(m_clientSocket, e_fdMax) ;
				break ;

			case SERVER_RECEIVES_DATA :
				//sendBuf.fd[sendBuf.inptr] = fd;
				nread = recv(fd, szBuf, BUF_SIZE, 0) ;

				if (nread > 0) 
				{
					__LOG(LOG_INFO, "[TCP][%s:%d] recv data socket_id(%d) byte %d", _FILE_, __LINE__, fd, nread);
					for (int i = 0; i < nread; i++)
						__LOG(LOG_DEBUG, "[TCP][%s:%d] (%d)0x%02x", _FILE_, __LINE__, i, szBuf[i]);

					ret = parseRecvData(fd, szBuf, nread);
					if(ret != 0) {
						__LOG(LOG_ERR, "[TCP][%s:%d] parseRecvData err!", _FILE_, __LINE__);
					}
					// send(fd_pc, szBuf, nread, 0);
					// debug_printf("pc send\n");
				}
				else
					__LOG(LOG_ERR, "[TCP][%s:%d] ret:%d", _FILE_, __LINE__, ret);

				break ;
			case SERVER_CLOSES_CLIENT_CONNECTION :
				FD_CLR(fd, &m_fds);
				if (fd == m_fdMax) {
					for (int j = m_fdMax; j >= 0; j--) {
						if (FD_ISSET(j, &m_fds)) {
							m_fdMax = j;
							break;
						}
						if (j == 0)
							m_fdMax = -1;
					}
				}
				FD_CLR(fd, &e_fds) ;
				if (fd == e_fdMax) {
					for (int j = e_fdMax; j >= 0; j--) {
						if (FD_ISSET(j, &e_fds)) {
							e_fdMax = j;
							break;
						}
						if (j == 0)
							e_fdMax = -1;
					}
				}
                if(vhl_cnt)vhl_cnt--;
				ret = close(fd);
				if(ret < 0)
					__LOG(LOG_CRIT, "[TCP][%s:%d] ret:%d", _FILE_, __LINE__, ret);
					
				__LOG(LOG_ALERT, "[TCP][%s:%d] server close FD by client (ip : %s, fd : %d)", _FILE_, __LINE__, inet_ntoa(clientAddr.sin_addr), fd) ;
				break ;
			}
		}
	}

	__LOG(LOG_NOTICE, "[TCP][%s:%d] connect thread end", _FILE_, __LINE__);

	return ret;
}

int CTCPServer::parseRecvData(int fd, char* data, int len)
{
    uint16_t i = 0, cmd;
	int ret = 0;
	SysTime curTime;
	TOhtData _TOhtData;
    FILE *fp = NULL;
	char temp[4];
	char str[STR_LEN];
	
	if (len <= 0)
		return -1;

	if(len > MAX_DATA_LEN) {
		__LOG(LOG_ERR, "[EVT][%s:%d] recv byte %d > %d : resize %d", _FILE_, __LINE__, len, MAX_DATA_LEN, MAX_DATA_LEN);
		len = MAX_DATA_LEN;
		//return -1;
	}

	memset(_TOhtData.byte, 0, sizeof(_TOhtData.byte));
	if (len < 10) {
		__LOG(LOG_ERR, "[EVT][%s:%d] recv byte %d < header(10)", _FILE_, __LINE__, len);
		return -1;
	}

	memcpy(_TOhtData.byte, data, len);

	if(!ord_machine_id_matches(&vhlConf, _TOhtData.fmt.machineID)) {
		//printk("VHL name not match :: data:%c%c%c%c%c%c json:%s\n", data[2],data[3],data[4],data[5],data[6],data[7], vhlConf.vhl_name);
		__LOG(LOG_ERR, "[EVT][%s:%d] VHL name not match data:%c%c%c%c%c%c json:%s", _FILE_, __LINE__, data[2],data[3],data[4],data[5],data[6],data[7], vhlConf.vhl_name);
		return -1;
	}

	_TOhtData.fmt.machineType = ntohs(_TOhtData.fmt.machineType);

	if(_TOhtData.fmt.machineType != MACHINE_TYPE_VHL_COMMON && _TOhtData.fmt.machineType != MACHINE_TYPE_VHL_0 && _TOhtData.fmt.machineType != MACHINE_TYPE_VHL_1) {
		__LOG(LOG_ERR, "[EVT][%s:%d] machineType : %d", _FILE_, __LINE__, _TOhtData.fmt.machineType);
		return -1;
	}

	cmd = ntohs(_TOhtData.fmt.cmd);
	_TOhtData.fmt.machineType = htons(MACHINE_TYPE_BLACKBOX);

    switch (cmd)
    {
	case CMD_STATUSINFO_BLACKBOX:
		__LOG(LOG_DEBUG, "[EVT][%s:%d] recv cmd : overaly", _FILE_, __LINE__);
		if (len != MAX_DATA_LEN) {
			__LOG(LOG_WARNING, "[EVT][%s:%d] recv overlay len %d != %d", _FILE_, __LINE__, len, MAX_DATA_LEN);
		}
		if(_TOrdConf.ops_enable)
		{
			__LOG(LOG_WARNING, "[EVT][%s:%d] Don't send ipc because ops_enable is true", _FILE_, __LINE__);
		}
		else
		{
			//ret = sendDataIPC(_TOhtData.byte, MAX_DATA_LEN);
			enqueue(&_TOvlQueue, _TOhtData.byte);
			if(_TOvlQueue.inptr - _TOvlQueue.outptr > _TOrdConf.ovl_buffering)
			{
				//char dequeStr[MAX_DATA_LEN];
				dequeue(&_TOvlQueue, _TOhtData.byte);
				sendDataIPC(_TOhtData.byte, MAX_DATA_LEN);
			}
		}
        //if(ret < 0) __LOG(LOG_CRIT,"[%s:%d][DSK] ret:%d", _FILE_, __LINE__, ret);
#ifdef SENDQUEUE_ENABLE
		sendBuf.cmd[sendBuf.inptr++] = RES_OVERLAY;
#endif
        break;
	case CMD_TIMESETTING_BLACKBOX:
		__LOG(LOG_ALERT, "[EVT][%s:%d] recv cmd : rtc", _FILE_, __LINE__);
		if (len < 26) {
			__LOG(LOG_ERR, "[EVT][%s:%d] recv rtc len %d < 26", _FILE_, __LINE__, len);
			ret = -1;
			break;
		}
		_TOhtData.fmt.cmd = htons(CMD_TIMESETTING_BLACKBOX_RESPONSE);
		_TOhtData.fmt.curTime.wYear = ntohs(_TOhtData.fmt.curTime.wYear);
		_TOhtData.fmt.curTime.wMonth = ntohs(_TOhtData.fmt.curTime.wMonth);
		_TOhtData.fmt.curTime.wDayOfWeek = ntohs(_TOhtData.fmt.curTime.wDayOfWeek);
		_TOhtData.fmt.curTime.wDay = ntohs(_TOhtData.fmt.curTime.wDay);
		_TOhtData.fmt.curTime.wHour = ntohs(_TOhtData.fmt.curTime.wHour);
		_TOhtData.fmt.curTime.wMinute = ntohs(_TOhtData.fmt.curTime.wMinute);
		_TOhtData.fmt.curTime.wSecond = ntohs(_TOhtData.fmt.curTime.wSecond);
		_TOhtData.fmt.curTime.wMsecond = ntohs(_TOhtData.fmt.curTime.wMsecond);
		if (!ord_is_valid_rtc_time(&_TOhtData.fmt.curTime)) {
			__LOG(LOG_ERR, "[EVT][%s:%d] invalid time %04d-%02d-%02d %02d:%02d:%02d", _FILE_, __LINE__,
				_TOhtData.fmt.curTime.wYear, _TOhtData.fmt.curTime.wMonth, _TOhtData.fmt.curTime.wDay,
				_TOhtData.fmt.curTime.wHour, _TOhtData.fmt.curTime.wMinute, _TOhtData.fmt.curTime.wSecond);
			ret = -1;
			break;
		}
		ret = sprintf(str, "hwclock --set --date=\"%04d-%02d-%02d %02d:%02d:%02d\"", \
                        _TOhtData.fmt.curTime.wYear, _TOhtData.fmt.curTime.wMonth, _TOhtData.fmt.curTime.wDay, \
                        _TOhtData.fmt.curTime.wHour, _TOhtData.fmt.curTime.wMinute, _TOhtData.fmt.curTime.wSecond);
		//ret = sprintf(str, "date -s \"%04d-%02d-%02d %02d:%02d:%02d\"", \
                        ohtdata.fmt.curTime.wYear, ohtdata.fmt.curTime.wMonth, ohtdata.fmt.curTime.wDay, \
                        ohtdata.fmt.curTime.wHour, ohtdata.fmt.curTime.wMinute, ohtdata.fmt.curTime.wSecond);

		//err = shell_script(str, (char *)"r");
        __LOG(LOG_ALERT, "[EVT][%s:%d] %s", _FILE_, __LINE__, str);
		ret = system(str);
        if(ret != 0) {
			__LOG(LOG_ERR, "[EVT][%s:%d] %s ret:%d", _FILE_, __LINE__, str, ret);
			break;
		}
		ret = sprintf(str, "hwclock -s && systemctl restart rsyslog");
		//ret = sprintf(str, "hwclock --systohc");
		//ret = sprintf(str, "hwclock -w");
		//err = shell_script(str, (char *)"r");
        __LOG(LOG_NOTICE, "[EVT][%s:%d] %s", _FILE_, __LINE__, str);
		ret = system(str);
        if(ret != 0) {
			__LOG(LOG_ERR, "[EVT][%s:%d] %s ret:%d", _FILE_, __LINE__, str, ret);
			break;
		}
		
        if(_TOrdConf.rtc_reset)
		{
			__LOG(LOG_NOTICE, "[EVT][%s:%d] %s", _FILE_, __LINE__, CAM_RESET_FILE);
			ret = system(CAM_RESET_FILE);
			if(ret != 0) {
				__LOG(LOG_ERR, "[EVT][%s:%d] %s ret:%d", _FILE_, __LINE__, CAM_RESET_FILE, ret);
				break;
			}
		}

		ret = sendDataTCP(fd, _TOhtData.byte, 26);

#ifdef SENDQUEUE_ENABLE
		sendBuf.cmd[sendBuf.inptr++] = RES_RTC_SET;
#endif
        break;
    //case CMD_TIMESETTING_BLACKBOX_RESPONSE:
        //break; 
	case CMD_EVENTREQ_BLACKBOX:
		if (len < 11) {
			__LOG(LOG_ERR, "[EVT][%s:%d] recv event len %d < 11", _FILE_, __LINE__, len);
			ret = -1;
			break;
		}
		if(_TOhtData.fmt.eventType == EVT_COPY)
		{
			__LOG(LOG_NOTICE, "[EVT][%s:%d] recv cmd : event copy", _FILE_, __LINE__);
			
			if(disk_size_over_evt && !vhlConf.event_auto_remove) {
				__LOG(LOG_ERR, "[EVT][%s:%d] evt auto remove false and evt disk size over!", _FILE_, __LINE__);
				ret = -1;
				break;
			}

			sprintf(str, "ls -l %s | grep ^- | wc -l", PATH_MOUNT);
			fp = popen(str, "r");
			if (NULL == fp) {
				ret = -1;
				perror("popen() fail");
				__LOG(LOG_ERR, "[EVT][%s:%d] ret:%d", _FILE_, __LINE__, ret);
				break;
			}
			while (fgets(str, STR_LEN, fp));

			ret = pclose(fp);
			int filecnt = atoi(str);

			if(filecnt < 1)	
			{
				__LOG(LOG_ERR, "[EVT][%s:%d] %s folder file cnt : %d", _FILE_, __LINE__, PATH_MOUNT, filecnt);
				ret = -1;
				break;
			}

			ret = call_copy(fd, 1);
		}
		else if(_TOhtData.fmt.eventType == EVT_PRI) 
		{
			__LOG(LOG_EMERG, "[EVT][%s:%d] recv cmd : event oss", _FILE_, __LINE__);
			_TOhtData.fmt.cmd = htons(CMD_EVENTACK_BLACKBOX);
			_TOhtData.fmt.eventType = EVT_PRI;
			_TOhtData.fmt.eventResult = EVT_RESULT_SUCCESS;

			ret = sendDataIPC(_TOhtData.byte, 12);
			if(ret < 0) break;

			ret = sendDataTCP(fd, _TOhtData.byte, 12);
			if(ret < 0) break;

#ifdef SENDQUEUE_ENABLE
			sendBuf.cmd[sendBuf.inptr++] = RES_EVT_PRI;
#endif
		} 
		else if(_TOhtData.fmt.eventType == EVT_TEST) 
		{
			//ret = sprintf(str, "ls -ptr %s | grep -v '/$'| grep %s | tail -%d | head -%d | xargs -t -I %% sh -c '{ cp -a %s/%% /test/%s_%%; }'", \
									PATH_MOUNT, vhlConf.vhl_name, arg->copyTail, arg->copyHead, PATH_MOUNT, EVENT_FILE_NAME_PREFIX);
			memset(str, 0, sizeof(str));
			ret = sprintf(str, "dpkg -l |grep pim | awk '{print $3}'");

			__LOG(LOG_NOTICE, "[EVT][%s:%d] %s", _FILE_, __LINE__, str);
#if 1
			fp = popen(str, "r");
			if (NULL == fp) {
				ret = -1;
				perror("popen() fail");
				__LOG(LOG_ERR,"[EVT][%s:%d] ret : %d", _FILE_, __LINE__, ret);
				break;
			}
			while (fgets(str, STR_LEN, fp));
			__LOG(LOG_NOTICE, "[VET][%s:%d] pim-package version : %s", _FILE_, __LINE__, str);
#endif
			_TOhtData.fmt.cmd = htons(CMD_EVENTACK_BLACKBOX);
			_TOhtData.fmt.eventType = EVT_TEST;
			//ohtdata.fmt.eventResult = EVT_RESULT_SUCCESS;
			//snprintf(ohtdata.fmt.version, 5, "%s", str);
			memcpy(_TOhtData.fmt.version, str, 5);
			ret = sendDataTCP(fd, _TOhtData.byte, 16);
		} 
		else 
		{
			ret = -1;
		}

        break;
    //case CMD_EVENTACK_BLACKBOX:
        //break;
    case CMD_ERROR_BLACKBOX:
		__LOG(LOG_ERR, "[EVT][%s:%d] recv cmd : error", _FILE_, __LINE__);
		_TOhtData.fmt.cmd = htons(CMD_ERROR_BLACKBOX);
        _TOhtData.fmt.error.data = errorData;
        __LOG(LOG_NOTICE, "[EVT][%s:%d] byte[0]:0x%02x byte[1]:0x%02x", _FILE_, __LINE__, _TOhtData.fmt.error.byte[0], _TOhtData.fmt.error.byte[1]);
        __LOG(LOG_INFO, "[EVT][%s:%d] cam0:%d, cam1:%d, cam2:%d, cam3:%d", _FILE_, __LINE__, \
                        _TOhtData.fmt.error.cam0, _TOhtData.fmt.error.cam1, _TOhtData.fmt.error.cam2, _TOhtData.fmt.error.cam3);
        __LOG(LOG_INFO, "[EVT][%s:%d] wifi:%d, sd:%d, temp:%d, voltage:%d", _FILE_, __LINE__, \
                        _TOhtData.fmt.error.wifi, _TOhtData.fmt.error.sd, _TOhtData.fmt.error.temp, _TOhtData.fmt.error.voltage);
        __LOG(LOG_NOTICE, "[EVT][%s:%d] send cmd event ERR (%d)", _FILE_, __LINE__, i);
		ret = sendDataTCP(fd, _TOhtData.byte, 12);
		//if(ret < 0) __LOG(LOG_CRIT,"[%s:%d][DSK] ret:%d", _FILE_, __LINE__, ret);
#ifdef SENDQUEUE_ENABLE
		sendBuf.cmd[sendBuf.inptr++] = RES_ERROR;
#endif
        break;
    default:
		__LOG(LOG_ERR, "[EVT][%s:%d] not match cmd(%d)", _FILE_, __LINE__, _TOhtData.fmt.cmd);
        break;
    }
	
	if(ret != 0) {
		if(cmd == CMD_EVENTREQ_BLACKBOX) {
			ret = responseEvent(fd, _TOhtData.fmt.eventType, EVT_RESULT_FAIL);
		} else if(cmd == CMD_TIMESETTING_BLACKBOX) {
			ret = responseEvent(fd, 5, EVT_RESULT_FAIL);
		} else if(cmd == CMD_ERROR_BLACKBOX) {
			ret = responseEvent(fd, 6, EVT_RESULT_FAIL);
		} else if(cmd == CMD_STATUSINFO_BLACKBOX) {
			ret = responseEvent(fd, 4, EVT_RESULT_FAIL);
		}
	}
	//if(fp != NULL) ret = pclose(fp);
	//if(ret < 0) __LOG(LOG_CRIT,"[%s:%d][DSK] ret:%d", _FILE_, __LINE__, ret);
	//__E(LOG_LEVEL_MSG, "res queue in:%d out:%d cmd:%d fd:%d\n", sendBuf.inptr, sendBuf.outptr, sendBuf.cmd[sendBuf.inptr-1], sendBuf.fd[sendBuf.inptr-1]);
	//free(str);
    return ret;
}

int CTCPServer::checkSD()
{
    char str[STR_LEN];
    int ret = 0;

    //__LOG(LOG_NOTICE, "[CFG][%s:%d] %s", _FILE_, __LINE__, __FUNCTION__);

    sprintf(str, "mkdir -p %s", PATH_MOUNT);
    ret = system(str);
    if(ret < 0) {
        __LOG(LOG_CRIT, "[DSK][%s:%d] %S, ret : %d", _FILE_, __LINE__, str, ret);
    }
    sprintf(str, "mkdir -p %s", PATH_EVENT);
    ret = system(str);
    if(ret < 0) {
        __LOG(LOG_CRIT, "[DSK][%s:%d] %S, ret : %d", _FILE_, __LINE__, str, ret);
    }
    sprintf(str, "mkdir -p %s", PATH_RECYCLE);
    ret = system(str);
    if(ret < 0) {
        __LOG(LOG_CRIT, "[DSK][%s:%d] %S, ret : %d", _FILE_, __LINE__, str, ret);
    }
    sprintf(str, "mkdir -p %s", PATH_LOG);
    ret = system(str);
    if(ret < 0) {
        __LOG(LOG_CRIT, "[DSK][%s:%d] %S, ret : %d", _FILE_, __LINE__, str, ret);
    }
    sprintf(str, "mkdir -p %s", PATH_TMP);
    ret = system(str);
    if(ret < 0) {
        __LOG(LOG_CRIT, "[DSK][%s:%d] %S, ret : %d", _FILE_, __LINE__, str, ret);
    }

	{
		uint64_t used_bytes = 0;
		uint64_t avail_bytes = 0;
		if (ord_get_fs_used_avail_bytes(PATH_MOUNT, &used_bytes, &avail_bytes) == 0) {
			double used_gb = (double)used_bytes / GB;
			double avail_gb = (double)avail_bytes / GB;
			disk_size_mnt = used_gb + avail_gb;
			disk_use_limit = (double)disk_size_mnt * _TOrdConf.disk_limit_per / 100;
		} else {
			disk_size_mnt = (double)get_disk_size(PATH_MOUNT) / GB;
			disk_use_limit = (double)disk_size_mnt * _TOrdConf.disk_limit_per / 100;
		}
	}

	disk_size_evt = (disk_size_mnt * vhlConf.event_storage_size) / 100;

	__LOG(LOG_NOTICE, "[DSK][%s:%d] %s size : %0.1f/%0.1f/%0.1fGB", _FILE_, __LINE__, PATH_MOUNT, (double)get_disk_use_size(PATH_MOUNT)/GB, disk_use_limit, disk_size_mnt);
	__LOG(LOG_NOTICE, "[DSK][%s:%d] %s size : %0.1f/%0.1fGB", _FILE_, __LINE__, PATH_EVENT, (double)get_dir_use_size(PATH_EVENT)/GB, disk_size_evt);

	    return ret;
}

int CTCPServer::call_copy(int fd, int tail)
{
	int ret = 0;
	long cmp1, cmp2;
	uint8_t date_ptr = 0;
	char str[STR_LEN];
	FILE *fp = NULL;
	SysTime fileTime;
	static uint8_t th_i = 0;

set_target:
	if (_TOrdConf.target_copy)
	{
		ret = sprintf(str, "cat %s 2>/dev/null | tr -d '\n'", PATH_COPY_VIDEO_TIME);
		date_ptr = 0;
	}
	else
	{
		ret = sprintf(str, "ls -ptr %s | grep -v '/$' |grep %s |grep .%s | tail -%d | head -1", PATH_MOUNT, vhlConf.vhl_name, vhlConf.muxer, tail);
		date_ptr = strlen(vhlConf.vhl_name) + 1;
	}

	// fp = popen("ls -ptr /mnt | grep -v '/$'| tail -1", "r");
	// fp = popen("ls -ptr /mnt | grep -v '/$' | grep .mp4 | tail -1", "r");
	//__LOG(LOG_NOTICE, "[CPY][%s:%d] %s", _FILE_, __LINE__, str);

	fp = popen(str, "r");
	if (NULL == fp)
	{
		ret = -1;
		perror("popen() fail");
		__LOG(LOG_ERR, "[CPY][%s:%d] ret:%d", _FILE_, __LINE__, ret);
		return ret;
	}
	while (fgets(str, STR_LEN, fp));

	__LOG(LOG_INFO, "[CPY][%s:%d] target file date : %s", _FILE_, __LINE__, str);
	ret = pclose(fp);
	if (ret < 0)
	{
		__LOG(LOG_ERR, "[CPY][%s:%d] ret:%d", _FILE_, __LINE__, ret);
		return ret;
	}

	cmp1 = getEpochFromChar(str, date_ptr, _TOrdConf.target_copy, &fileTime);
	if (cmp1 < 0)
	{
		ret = -1;
		__LOG(LOG_ERR, "[CPY][%s:%d] cmp1:%d", _FILE_, __LINE__, cmp1);
		return ret;
	}

	fp = popen("date +%s", "r");
	if (NULL == fp)
	{
		ret = -1;
		perror("popen() fail");
		__LOG(LOG_ERR, "[CPY][%s:%d] ret:%d", _FILE_, __LINE__, ret);
		return ret;
	}
	while (fgets(str, STR_LEN, fp));
	// debug_printf("%s", str);
	cmp2 = atol(str);
	ret = pclose(fp);
	if (ret < 0)
	{
		__LOG(LOG_ERR, "[CPY][%s:%d] ret:%d", _FILE_, __LINE__, ret);
		return ret;
	}

	MultipleArg *multiArg;
	multiArg = (MultipleArg *)malloc(sizeof(MultipleArg));
	static MultipleArg preArg;

	multiArg->diff = cmp2 - cmp1;
	multiArg->fd = fd;
	memcpy(multiArg->copyTime.byte, fileTime.byte, sizeof(SysTime));
	//__LOG(LOG_NOTICE, "[CPY][%s:%d] %04d%02d%02d", _FILE_, __LINE__, multiArg->copyTime.wYear, multiArg->copyTime.wMonth, multiArg->copyTime.wDay);
	__LOG(LOG_INFO, "[CPY][%s:%d] fd : %d, sys : %ld, file : %ld, diff : %ld", _FILE_, __LINE__, fd, cmp2, cmp1, multiArg->diff);

	if (multiArg->diff < 0)
	{
		__LOG(LOG_ERR, "[CPY][%s:%d] diff negative", _FILE_, __LINE__);
		free(multiArg);
		if (_TOrdConf.target_copy)
		{
			ret = -1;
			return ret;
		}
		else
		{
			tail++;
			goto set_target;
		}
	}
	else if (multiArg->diff < _TOrdConf.margin_sec)
	{
		//__E(LOG_LEVEL_TRA, "start time copy\n");
		multiArg->delay = (vhlConf.recMinute * 60) - multiArg->diff + _TOrdConf.evt_copy_delay;
		multiArg->copyHead = (_TOrdConf.cameraNum + _TOrdConf.srt_enable + _TOrdConf.vib_enable) * 2;
		if(path_eq_f) multiArg->copyTail = (_TOrdConf.cameraNum + _TOrdConf.srt_enable + _TOrdConf.vib_enable) * 3;
		else multiArg->copyTail = multiArg->copyHead;
		multiArg->copyType = COPY_TYPE_HEAD;
	}
	else if (multiArg->diff < (vhlConf.recMinute * 60 - _TOrdConf.margin_sec))
	{
		//__E(LOG_LEVEL_TRA, "normal time copy\n");
		multiArg->delay = (vhlConf.recMinute * 60) - multiArg->diff + _TOrdConf.evt_copy_delay;
		multiArg->copyHead = (_TOrdConf.cameraNum + _TOrdConf.srt_enable + _TOrdConf.vib_enable);
		if(path_eq_f) multiArg->copyTail = (_TOrdConf.cameraNum + _TOrdConf.srt_enable + _TOrdConf.vib_enable) * 2;
		else multiArg->copyTail = multiArg->copyHead;
		multiArg->copyType = COPY_TYPE_BODY;
	}
	else if (multiArg->diff < vhlConf.recMinute * 60)
	{
		//__E(LOG_LEVEL_TRA, "end time copy\n");
		multiArg->delay = (vhlConf.recMinute * 60) * 2 - multiArg->diff + _TOrdConf.evt_copy_delay;
		multiArg->copyHead = (_TOrdConf.cameraNum + _TOrdConf.srt_enable + _TOrdConf.vib_enable) * 2;
		if(path_eq_f) multiArg->copyTail = (_TOrdConf.cameraNum + _TOrdConf.srt_enable + _TOrdConf.vib_enable) * 3;
		else multiArg->copyTail = multiArg->copyHead;
		multiArg->copyType = COPY_TYPE_TAIL;
	}
	else
	{
		__LOG(LOG_ERR, "[CPY][%s:%d] exception time", _FILE_, __LINE__);
		multiArg->delay = 0;
		multiArg->copyType = COPY_TYPE_UNUSED;
		ret = -1;
		free(multiArg);
		return ret;
	}

	if(compSysTime(multiArg->copyTime, preArg.copyTime) == 0 && multiArg->copyType == preArg.copyType)
	{
		__LOG(LOG_INFO, "[CPY][%s:%d] copy time is duplicate", _FILE_, __LINE__);
		free(multiArg);
		return ret;
	}


	multiArg->threadNum = th_i++;
	ret = pthread_create(&m_threadCopy, NULL, &thread_waitingCopy, (void *)multiArg);
	if(ret != 0)
	{
		free(multiArg);
		__LOG(LOG_ERR, "[CPY][%s:%d] ret:%d", _FILE_, __LINE__, ret);
		return ret;
	}
	{
		int detachRet = pthread_detach(m_threadCopy);
		if(detachRet != 0)
			__LOG(LOG_ERR, "[CPY][%s:%d] pthread_detach ret:%d", _FILE_, __LINE__, detachRet);
	}

	memcpy(&preArg, multiArg, sizeof(MultipleArg));

	return ret;
}

int CTCPServer::waitingRedis()
{
	redisContext *context = NULL, *context_cmd = NULL;
	redisReply *reply = NULL, *valueReply = NULL;
	json_object *jobj = NULL;
	const char *logKey = "RDS";
	int fd = 0;
	bool trig_event = false;

    // Redis server connect (default localhost:6379)
    context = redisConnect("127.0.0.1", 6379);
    if (context == NULL || context->err) {
        if (context) {
			__LOG(LOG_ERR, "[%s][%s:%d] Connection error: %s", logKey, _FILE_, __LINE__, context->errstr);
            redisFree(context);
        } else {
			__LOG(LOG_ERR, "[%s][%s:%d] Connection error: can't allocate redis context", logKey, _FILE_, __LINE__);
        }
        return -1;
    }

    // Keyspace Notifications subscribe
    reply = (redisReply *)redisCommand(context, "SUBSCRIBE __keyspace@0__:%s:%s", RDS_VIB_HEADER, RDS_TRIG_CMD);
    if (reply == NULL) {
		__LOG(LOG_ERR, "[%s][%s:%d] Failed to subscribe to keyspace notifications", logKey, _FILE_, __LINE__);
        redisFree(context);
        return -1;
    }

	__LOG(LOG_NOTICE, "[%s][%s:%d] key events for '%s:%s'. Waiting for changes...", logKey, _FILE_, __LINE__, RDS_VIB_HEADER, RDS_TRIG_CMD);
    freeReplyObject(reply);

    context_cmd = redisConnect("127.0.0.1", 6379);
    if (context_cmd == NULL || context_cmd->err) {
        if (context_cmd) {
			__LOG(LOG_ERR, "[%s][%s:%d] Connection error (command) : %s", logKey, _FILE_, __LINE__, context_cmd->errstr);
            redisFree(context_cmd);
        } else {
			__LOG(LOG_ERR, "[%s][%s:%d] Connection error: can't allocate redis command context", logKey, _FILE_, __LINE__);
        }
        redisFree(context);
        return 1;
    }

    // redis loop for event
    while (redisGetReply(context, (void **)&reply) == REDIS_OK) {
		if(m_flagDestroy) break;

        if (reply->type == REDIS_REPLY_ARRAY && reply->elements == 3) {
            const char *event = reply->element[2]->str;
			__LOG(LOG_INFO, "[%s][%s:%d] Key '%s:%s' event detected: %s", logKey, _FILE_, __LINE__, RDS_VIB_HEADER, RDS_TRIG_CMD, event); 
#if 0
			for (int i = 0; i <= m_fdMax; i++)
			{
				if(FD_ISSET(i, &m_fds)) {
					//__E(LOG_LEVEL_DBG, "OSS send for fd:%d\n", i);
					//__LOG(LOG_NOTICE, "[OSS][%s:%d] send cmd event oss", _FILE_, __LINE__);
					fd = i;
					break;
				}
			}
#endif
            // event process
            if (strcmp(event, "set") == 0) {
				//__LOG(LOG_NOTICE, "[%s][%s:%d] Key '%s:%s' was modified", logKey, _FILE_, __LINE__, RDS_VIB_HEADER, RDS_TRIG_CMD);
                valueReply = (redisReply *)redisCommand(context_cmd, "GET %s:%s", RDS_VIB_HEADER, RDS_TRIG_CMD);
                if (valueReply != NULL && valueReply->type == REDIS_REPLY_STRING) {
					__LOG(LOG_DEBUG, "[%s][%s:%d] Value of '%s:%s': %s", logKey, _FILE_, __LINE__, RDS_VIB_HEADER, RDS_TRIG_CMD, valueReply->str); 
					jobj = json_tokener_parse(valueReply->str);
					if (jobj == NULL) {
						__LOG(LOG_ERR, "[%s][%s:%d] Failed to parse JSON", logKey, _FILE_, __LINE__);
						freeReplyObject(valueReply);
						valueReply = NULL;
						continue;
					}
					trig_event = false;
					json_object_get_value(jobj, RDS_TRIG_KEY, &trig_event);
					if(trig_event == true)
					{
						__LOG(LOG_NOTICE, "[%s][%s:%d] %s : true", logKey, _FILE_, __LINE__, RDS_TRIG_KEY); 
						if(call_copy(fd, 1) < 0)
						{
							__LOG(LOG_ERR, "[%s][%s:%d] Failed to copy event", logKey, _FILE_, __LINE__);
						}
						else
						{
#if 1
							redisReply *setReply = (redisReply *)redisCommand(
								context_cmd,
								"SET %s:%s %s",
								RDS_VIB_HEADER,
								RDS_TRIG_CMD,
								"{ \"trigger\": false }"
							);
							if (setReply != NULL && setReply->type == REDIS_REPLY_STATUS && strcmp(setReply->str, "OK") == 0) {
								__LOG(LOG_NOTICE, "[%s][%s:%d] Successfully updated '%s:%s' to false", logKey, _FILE_, __LINE__, RDS_VIB_HEADER, RDS_TRIG_CMD);
							} else {
								__LOG(LOG_ERR, "[%s][%s:%d] Failed to update '%s:%s' to false", logKey, _FILE_, __LINE__, RDS_VIB_HEADER, RDS_TRIG_CMD);
							}
							if (setReply != NULL) {
								freeReplyObject(setReply);
								setReply = NULL;
							}
#endif
						}
					}
					else
					{
						__LOG(LOG_DEBUG, "[%s][%s:%d] %s : false", logKey, _FILE_, __LINE__, RDS_TRIG_KEY); 
					}
					json_object_put(jobj);
					jobj = NULL;
#if 0
					json_object *jobjobj = json_find_obj(jobj, RDS_TRIG_CMD);
					if (jobjobj != NULL && json_object_get_type(jobjobj) == json_type_boolean) {
						const char *val = json_object_get_string(jobjobj);
						printf("%s : %s\n", RDS_TRIG_CMD, val);
					}
#endif
                } else {
					__LOG(LOG_ERR, "[%s][%s:%d] Failed to retrieve the value of '%s:%s' or key does not exist.", logKey, _FILE_, __LINE__, RDS_VIB_HEADER, RDS_TRIG_CMD);
                }

				if (valueReply != NULL) {
					freeReplyObject(valueReply);
					valueReply = NULL;
				}
            } else if (strcmp(event, "del") == 0) {
                //printf("Key 'OPS:recent_data' was deleted.\n");
				//__LOG(LOG_NOTICE, "[%s][%s:%d] Key '%s:%s' was modified", logKey, _FILE_, __LINE__, RDS_VIB_HEADER, RDS_TRIG_CMD);
            } else if (strcmp(event, "expire") == 0) {
                //printf("Key 'OPS:recent_data' has expired.\n");
				//__LOG(LOG_NOTICE, "[%s][%s:%d] Key '%s:%s' was modified", logKey, _FILE_, __LINE__, RDS_VIB_HEADER, RDS_TRIG_CMD);
            }
        }
		if (reply != NULL) {
			freeReplyObject(reply);
			reply = NULL;
		}
    }

    // free
	if (jobj != NULL) {
		json_object_put(jobj);
		jobj = NULL;
	}
	if (reply != NULL) {
		freeReplyObject(reply);
		reply = NULL;
	}
	if (valueReply != NULL) {
		freeReplyObject(valueReply);
		valueReply = NULL;
	}
    redisFree(context);
	redisFree(context_cmd);

    return 0;
}

#ifdef SENDQUEUE_ENABLE
int CTCPServer::sendData()
{
	//char szBuf[128] ;
	int len = 0;
	int ret = 0;
	//void* nStatus;

	_MSGQueue msgBuf;
	int msg_id = msgget((key_t)MSG_Q_KEY, IPC_CREAT | 0660);

	if (msg_id == -1)
	{
		perror("msgget fail");
		return -1;
	}
	
	msgBuf.type = PMSG_TYPE_1;
	ohtdata.fmt.machineType = htons(MACHINE_TYPE_BLACKBOX);
	//debug_printf("send data\n");

	switch (sendBuf.cmd[sendBuf.outptr])
	{
	case RES_OVERLAY:
		__E(LOG_LEVEL_DBG, "RES_OVERLAY\n");
		ohtdata.fmt.cmd = htons(CMD_STATUSINFO_BLACKBOX);
		//ohtdata.fmt.curTime = get_sys_time();
		len = 55;
		memcpy(msgBuf.data.byte, ohtdata.byte, len);
		for (int attempt = 0; attempt < 2; attempt++) {
			if (msgsnd(msg_id, &msgBuf, len*sizeof(char), IPC_NOWAIT) >= 0)
				break;
			int send_errno = errno;
			if (send_errno == EAGAIN)
				break;
			if (attempt == 0 && (send_errno == EIDRM || send_errno == ENOENT || send_errno == EINVAL)) {
				msg_id = msgget((key_t)MSG_Q_KEY, IPC_CREAT | 0660);
				if (msg_id == -1)
					break;
				continue;
			}
			errno = send_errno;
			perror("msgsnd fail");
			break;
		}
		__E(LOG_LEVEL_DBG, "Send Data msg_id(%d) byte  %d\n", msg_id, len);
		break;
	case RES_RTC_SET:
		__E(LOG_LEVEL_DBG, "RES_RTC_SET\n");
		ohtdata.fmt.cmd = htons(CMD_TIMESETTING_BLACKBOX_RESPONSE);
		//ohtdata.fmt.curTime = get_sys_time();
		len = 26;
		ret = send(sendBuf.fd[sendBuf.outptr], ohtdata.byte, len, 0);
		__E(LOG_LEVEL_DBG, "Send Data socket_id(%d) byte  %d\n", sendBuf.fd[sendBuf.outptr], len);
		break;
	case RES_EVT_COPY:
		__E(LOG_LEVEL_DBG, "RES_EVT_COPY\n");
		ohtdata.fmt.cmd = htons(CMD_EVENTACK_BLACKBOX);
		ohtdata.fmt.eventType = EVT_COPY;
		ohtdata.fmt.eventResult = EVT_RESULT_SUCCESS;
		len = 12;
		ret = send(sendBuf.fd[sendBuf.outptr], ohtdata.byte, len, 0);
		__E(LOG_LEVEL_DBG, "Send Data socket_id(%d) byte  %d\n", sendBuf.fd[sendBuf.outptr], len);
		break;
	case RES_EVT_PRI:
		__E(LOG_LEVEL_DBG, "RES_EVT_PRI\n");
		ohtdata.fmt.cmd = htons(CMD_EVENTACK_BLACKBOX);
		ohtdata.fmt.eventType = EVT_PRI;
		ohtdata.fmt.eventResult = EVT_RESULT_SUCCESS;
		len = 12;
		memcpy(msgBuf.data.byte, ohtdata.byte, len);
		//ret = send(sendBuf.fd[sendBuf.outptr], ohtdata.byte, len, 0);
		for (int attempt = 0; attempt < 2; attempt++) {
			if (msgsnd(msg_id, &msgBuf, len*sizeof(char), IPC_NOWAIT) >= 0)
				break;
			int send_errno = errno;
			if (send_errno == EAGAIN)
				break;
			if (attempt == 0 && (send_errno == EIDRM || send_errno == ENOENT || send_errno == EINVAL)) {
				msg_id = msgget((key_t)MSG_Q_KEY, IPC_CREAT | 0660);
				if (msg_id == -1)
					break;
				continue;
			}
			errno = send_errno;
			perror("msgsnd fail");
			break;
		}
		__E(LOG_LEVEL_DBG, "Send Data msg_id(%d) byte  %d\n", msg_id, len);
		break;
	case RES_ERROR:
		__E(LOG_LEVEL_DBG, "RES_ERROR\n");
		ohtdata.fmt.cmd = htons(CMD_ERROR_BLACKBOX);
		//ohtdata.fmt.Error = ERROR_NULL;
		//ohtdata.fmt.Reserved = 0;
		len = 12;
		ret = send(sendBuf.fd[sendBuf.outptr], ohtdata.byte, len, 0);
		__E(LOG_LEVEL_DBG, "Send Data socket_id(%d) byte  %d\n", sendBuf.fd[sendBuf.outptr], len);
		break;
	default:
		__E(LOG_LEVEL_CRI, "CMD_ERROR : not defined\n");
		return 0;
		break;
	}

	for (int i = 0; i < len; i++)
		__E(LOG_LEVEL_MSG, "%02x", ohtdata.byte[i]);
	__E(LOG_LEVEL_MSG, "\n");
	//debug_printf("%s\n", ohtdata.byte);
	
	//pthread_join(m_threadConnect, &nStatus) ;
	sendBuf.outptr++;
	return ret;
}
#endif

#if 0
#include <dirent.h>
#include <sys/stat.h>

uint16_t dircnt = 0;
uint32_t calc = 0;

void calc_dir(const char* name, int level)
{
	DIR *dir;
	struct dirent* entry;
	struct stat buf;

	if(!(dir = opendir(name)))
		return;
	if(!(entry = readdir(dir)))
		return;

	do {
		if (entry->d_type = DT_DIR)
		{
			char path[1024];
			int len = snprintf(path, sizeof(path)-1, "%s%s", name, entry->d_name);
			path[len] = 0;
			if(strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
				continue;
			}
			dircnt++;
			calc_dir(path, level+1);
		} else {
			stat(entry->d_name, &buf);
			calc += buf.st_size;

		} 
	} while(entry = readdir(dir));
	closedir(dir);
}

int shell_script(char* buf, char* mod)
{
	FILE* fp;
	
	fp = popen(buf, mod);
	debug_printf("shell in : %s\n", buf);
	// fp = popen("ls -ptr /mnt/event/ | grep -v '/$' | head -5 | xargs rm -f", "w");
	if (NULL == fp)
	{
		perror("popen() fail");
		return -1;
	}
	while (fgets(str, STR_LEN, fp));
	pclose(fp); 

	debug_printf("shell out : %s\n", str);
	
	return 0;
}

#include <signal.h>
#include <unistd.h>
#include <time.h>

void timer(int signum)
{
    debug_printf("timer\n");
}

static void timer_handler( int sig, siginfo_t *si, void *uc ) 
{ 
    debug_printf("timer\n");
}

int createTimer( timer_t *timerID, int sec, int msec )  
{  
    struct sigevent         te;  
    struct itimerspec       its;  
    struct sigaction        sa;  
    int                     sigNo = SIGRTMIN;  
   
    /* Set up signal handler. */  
    sa.sa_flags = SA_SIGINFO;  
    sa.sa_sigaction = timer_handler;     // 타이머 호출시 호출할 함수

    sigemptyset(&sa.sa_mask);  
  
    if (sigaction(sigNo, &sa, NULL) == -1)  
    {  
        debug_printf("sigaction error\n");
        return -1;  
    }  
   
    /* Set and enable alarm */  
    te.sigev_notify = SIGEV_SIGNAL;  
    te.sigev_signo = sigNo;  
    te.sigev_value.sival_ptr = timerID;  
    timer_create(CLOCK_REALTIME, &te, timerID);  
   
    its.it_interval.tv_sec = sec;
    its.it_interval.tv_nsec = msec * 1000000;  
    its.it_value.tv_sec = sec;
    
    its.it_value.tv_nsec = msec * 1000000;
    timer_settime(*timerID, 0, &its, NULL);  
   
    return 0;  
}
#endif
