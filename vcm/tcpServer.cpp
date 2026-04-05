
#include "tcpServer.h"
#include <unistd.h>
#include <errno.h>

struct SrtQueueItem {
	char filePath[512];
	char entry[768];
};

static void sanitize_srt_text(char* out, size_t outSize, const char* in)
{
	if(out == NULL || outSize == 0) return;
	if(in == NULL) {
		out[0] = 0;
		return;
	}

	size_t j = 0;
	for(size_t i = 0; in[i] != 0 && (j + 1) < outSize; i++)
	{
		unsigned char c = (unsigned char)in[i];
		// Prevent newline injection into SRT structure.
		if(c == '\r' || c == '\n') {
			out[j++] = ' ';
			continue;
		}
		// Replace other control chars (except tab) with space.
		if(c < 0x20 && c != '\t') {
			out[j++] = ' ';
			continue;
		}
		out[j++] = (char)c;
	}
	out[j] = 0;
}

static void mark_session_complete(const char *timestamp) {
  char done_file[128];
  snprintf(done_file, sizeof(done_file), "/tmp/session_%s.all_done", timestamp);
  FILE *fp = fopen(done_file, "w");
  if (fp) {
    fprintf(fp, "%s\n", timestamp);
    fclose(fp);
    __LOG(LOG_NOTICE, "[SRT][%s:%d] Session complete: %s", _FILE_, __LINE__, timestamp);
  }
  
  // 개별 플래그 정리
  char video_flag[128], srt_flag[128];
  snprintf(video_flag, sizeof(video_flag), "/tmp/session_%s.video_done", timestamp);
  snprintf(srt_flag, sizeof(srt_flag), "/tmp/session_%s.srt_done", timestamp);
  unlink(video_flag);
  unlink(srt_flag);
}

static void check_and_mark_all_done(const char *timestamp) {
  char video_flag[128], srt_flag[128];
  snprintf(video_flag, sizeof(video_flag), "/tmp/session_%s.video_done", timestamp);
  snprintf(srt_flag, sizeof(srt_flag), "/tmp/session_%s.srt_done", timestamp);

  bool video_done = (access(video_flag, F_OK) == 0);
  bool srt_done = (access(srt_flag, F_OK) == 0);

  if (video_done && srt_done) {
    mark_session_complete(timestamp);
  }
}

static void mirror_recording_time_to_cam_state(const char* key, const char* value)
{
	if(key == NULL || value == NULL) return;

	char clean[128];
	size_t j = 0;
	for(size_t i = 0; value[i] != 0 && j + 1 < sizeof(clean); i++)
	{
		char c = value[i];
		if(c == '\r' || c == '\n') continue;
		clean[j++] = c;
	}
	clean[j] = 0;
	if(clean[0] == 0) return;

	char cmd[512];
	int ret = snprintf(cmd, sizeof(cmd),
		"bash -lc 'source /opt/pim/lib/cam_state.sh >/dev/null 2>&1 && cam_state_init >/dev/null 2>&1 && cam_recording_set \"%s\" \"%s\" >/dev/null 2>&1'",
		key, clean);
	if(ret < 0 || (size_t)ret >= sizeof(cmd)) {
		__LOG(LOG_ERR, "[SRT][%s:%d] mirror command overflow for key:%s", _FILE_, __LINE__, key);
		return;
	}

	ret = system(cmd);
	if(ret < 0) {
		__LOG(LOG_ERR, "[SRT][%s:%d] cam_state mirror failed for key:%s", _FILE_, __LINE__, key);
	}
}

static int append_text_file(const char* path, const char* text)
{
	if(path == NULL || text == NULL) return -1;

	FILE* f = fopen(path, "a");
	if(f == NULL) return -1;

	const size_t len = strlen(text);
	const size_t wr = fwrite(text, 1, len, f);
	int ret = 0;
	if(wr != len) ret = -1;
	fclose(f);
	return ret;
}

#define MAXPENDING 5

#ifdef SEGFAULT_DEBUG
#include <signal.h>

char vhlName[6];
char srtBuf[256];
pthread_mutex_t g_srtBufMutex = PTHREAD_MUTEX_INITIALIZER;
TVhlErr _TVhlErr;
TVhlConf _TVhlConf;
TVcmConf _TVcmConf;

void segfault_sigaction(int signal, siginfo_t *si, void *arg)
{
	CTCPServer* instance = CTCPServer::getInstance() ;
	__LOG(LOG_CRIT, "[CFG][%s:%d] cautght segault at address %p\n", _FILE_, __LINE__, si->si_addr);
	exit(0);
}
#endif

void* thread_waitingConnect(void* pData)
{
	CTCPServer* instance = CTCPServer::getInstance() ;
	__LOG(LOG_INFO, "[TCP][%s:%d] thread start", _FILE_, __LINE__);
	if(instance->waitingConnect() < 0) instance->m_flagDestroy = 1;

	return NULL ;
}

void* thread_waitingGetOPS(void* pData)
{
	CTCPServer* instance = CTCPServer::getInstance() ;
	__LOG(LOG_INFO, "[TCP][%s:%d] thread start", _FILE_, __LINE__);
	if(instance->waitingGetOPS(1) < 0) instance->m_flagDestroy = 1;

	return NULL ;
}

// 파일 쓰기 전용 워커 스레드 함수
void* thread_fileWriter(void* pData)
{
    CTCPServer* instance = CTCPServer::getInstance();
    SrtQueueItem item;
    __LOG(LOG_INFO, "[WRT][%s:%d] file writer thread start", _FILE_, __LINE__);

    while (1) {
        pthread_mutex_lock(&instance->m_fileMutex);
        while (instance->m_fileWriteQueue.size == 0 && !instance->m_flagDestroy) {
            pthread_cond_wait(&instance->m_fileCond, &instance->m_fileMutex);
        }

        if (instance->m_flagDestroy && instance->m_fileWriteQueue.size == 0) {
            pthread_mutex_unlock(&instance->m_fileMutex);
            break;
        }

        if (dequeue(&instance->m_fileWriteQueue, &item) == 0) {
            pthread_mutex_unlock(&instance->m_fileMutex);
            
            // 실제 디스크 쓰기 수행 (I/O 블로킹 발생 가능 지점)
            append_text_file(item.filePath, item.entry);
        } else {
            pthread_mutex_unlock(&instance->m_fileMutex);
        }
    }

    __LOG(LOG_NOTICE, "[WRT][%s:%d] file writer thread end", _FILE_, __LINE__);
    return NULL;
}

int CTCPServer::waitingGetOPS(int loop)
{
    redisContext *context;
    redisReply *reply;
	SysTime curTime;
	char str[256];
	uint ops_delay = _TVcmConf.ops_delay*MSEC;
	//TOpsData _TOpsDequeData;

	__LOG(LOG_NOTICE, "[RDS][%s:%d] redis thread start (loop:%d, delay:%d)", _FILE_, __LINE__, _TVcmConf.ops_period, ops_delay);
    // Redis server connect (default localhost:6379)
    context = redisConnect("127.0.0.1", 6379);
    if (context == NULL || context->err) {
        if (context) {
			__LOG(LOG_ERR, "[RDS][%s:%d] redis connection error: %s", _FILE_, __LINE__, context->errstr);
            redisFree(context);
        } else {
			__LOG(LOG_ERR, "[RDS][%s:%d] Connection error: can't allocate redis context", _FILE_, __LINE__);
        }
        return 1;
    }

	TQueue _TOpsQueue;
	init_queue(&_TOpsQueue, OPS_MAX_QUEUE_SIZE, sizeof(TOpsData));

    // redis loop
    do {
		if(m_flagDestroy)
			break;
        // redis key get
        reply = (redisReply *)redisCommand(context, "GET %s:%s", RDS_OPS_HEADER, RDS_DATA_CMD);
        
        // Redis
        if (reply->type == REDIS_REPLY_STRING && reply->str != NULL) {
        __LOG(LOG_DEBUG, "[RDS][%s:%d] '%s:%s' is: %s", _FILE_, __LINE__, RDS_OPS_HEADER, RDS_DATA_CMD, reply->str);
        pthread_mutex_lock(&lock_ops);
        // JSON parsing
        json_object *jobj = json_tokener_parse(reply->str);
            if (jobj == NULL) {
				__LOG(LOG_ERR, "[RDS][%s:%d] Failed to parse JSON", _FILE_, __LINE__);
                freeReplyObject(reply);
                usleep(500000);  // 500ms standby
                continue;  // next loop
            }

            json_object *val = json_find_obj(jobj, RDS_TAG_KEY);
            if (val != NULL) {
            const char* tag_str = json_object_get_string(val);
            _TOpsData.tag = (uint32_t)strtoul(tag_str, NULL, 10);
            __LOG(LOG_INFO, "[RDS][%s:%d] %s : %u", _FILE_, __LINE__, RDS_TAG_KEY, _TOpsData.tag);
            }

            val = json_find_obj(jobj, RDS_OFFSET_KEY);
            if (val != NULL && json_object_get_type(val) == json_type_double) {
            _TOpsData.offset = (float)json_object_get_double(val);
            __LOG(LOG_INFO, "[RDS][%s:%d] %s : %0.2f", _FILE_, __LINE__, RDS_OFFSET_KEY, _TOpsData.offset);
            }
			
			pthread_mutex_lock(&g_srtBufMutex);
			snprintf(srtBuf, sizeof(srtBuf), "%u(%0.2f)", _TOpsData.tag, _TOpsData.offset);
			pthread_mutex_unlock(&g_srtBufMutex);
			pthread_mutex_unlock(&lock_ops);
			_TOpsData.time = get_sys_time();

            // Enqueue the structure itself to avoid memory corruption
            enqueue(&_TOpsQueue, &_TOpsData);
            usleep(ops_delay);

            if(_TOpsQueue.size > _TVcmConf.ops_buffering)
                        {
                                TOpsData dequeuedData;
                                dequeue(&_TOpsQueue, &dequeuedData);

                                // Convert to JSON string just before sending
                                sprintf(str, "{\n\
\"REP\":\"SET_OVERLAY\",\n\
\"RET\":0,\n\
\"DATA\":{\n\
\"date\":\"%04d-%02d-%02d %02d:%02d:%02d\",\n\
\"name\":\"%s\",\n\
\"opsNodeID\":\"%u\",\n\
\"opsNodeOffset\":%0.2f\n}\n}", 
dequeuedData.time.wYear, dequeuedData.time.wMonth, dequeuedData.time.wDay, dequeuedData.time.wHour, \
dequeuedData.time.wMinute, dequeuedData.time.wSecond, _TVhlConf.vhl_name, dequeuedData.tag, dequeuedData.offset);

            __LOG(LOG_INFO, "[RDS][%s:%d] %s", _FILE_, __LINE__, str);
            SendDataForSetFD(PMSG_TYPE_OVERLAY, str, (int)strlen(str));
            }

            // JSON object free
            json_object_put(jobj);
        } else if (reply->type == REDIS_REPLY_NIL) {
			__LOG(LOG_ERR, "[RDS][%s:%d] '%s:%s' does not exist", _FILE_, __LINE__, RDS_OPS_HEADER, RDS_DATA_CMD);
        } else {
			__LOG(LOG_ERR, "[RDS][%s:%d] Failed to retrieve the value for '%s:%s'", _FILE_, __LINE__, RDS_OPS_HEADER, RDS_DATA_CMD);
        }

        // memory free
        freeReplyObject(reply);

        if(loop) usleep(_TVcmConf.ops_period - ops_delay);
    } while(loop);

	// queue free
	free_queue(&_TOpsQueue);
    // redis free
    redisFree(context);

    return 0;
}

void* thread_watingMakeSRT(void* pData)
{
	CTCPServer* instance = CTCPServer::getInstance() ;
	
	__LOG(LOG_INFO, "[SRT][%s:%d] thread start", _FILE_, __LINE__);
	if(instance->waitingMakeSRT() < 0) instance->m_flagDestroy = 1;

	return NULL ;
}

int CTCPServer::waitingMakeSRT()
{
	int ret = 0;
	uint i = 0, index = 0;
	FILE *fp;
	SysTime sysTime, srtPreTime, srtCurTime;
	char str[128];
	//char strTmp[512];
	//char *strTmp = (char *)malloc(512);
	char strTmp[512];
	//char strDeque[512];
	char prefixFileName[128];
	uint8_t srtMinStart, srtSecStart;
	long tmp1, tmp2; 
	long setTime;
	struct timeval  tv;
	uint64_t epochCurMsec, epochPreMsec = 0; 
	//struct tm* ptm;
	bool resync_f = false;
	TQueue _TSrtQueue;
	char *_TSrtDequeueStr;
	uint srt_delay = _TVcmConf.srt_delay*MSEC;
	//TString _TStr;
	//TString _TDequeue;
	//_TStr.str = (char *)malloc(512);
	//_TDequeue.str = (char *)malloc(512);
	//init_queue(&_TSrtQueue, SRT_MAX_QUEUE_SIZE, sizeof(TString));
#ifdef SRT_QUEUE_ENABLE
	init_queue(&_TSrtQueue, SRT_MAX_QUEUE_SIZE, sizeof(SrtQueueItem));
#endif
	//memset(srtBuf, 0, 512);
	//memcpy(srtBuf, "123", 3);
	//init_dateTime(srtPreTime);

    //sleep(3);

	do {
		usleep(100*MSEC);
		if(_TVcmConf.srt_test) {
			__LOG(LOG_NOTICE, "[SRT][%s:%d] test mode", _FILE_, __LINE__);
			sysTime = get_sys_time();
			char timeStr[128];
			snprintf(timeStr, sizeof(timeStr), "%04d%02d%02d %02d:%02d:%02d\n", sysTime.wYear, sysTime.wMonth, sysTime.wDay, sysTime.wHour, sysTime.wMinute+1, 0);
			__LOG(LOG_NOTICE, "[SRT][%s:%d] writing test time to %s: %s", _FILE_, __LINE__, PATH_START_VIDEO_TIME, timeStr);
			
			FILE *tf = fopen(PATH_START_VIDEO_TIME, "w");
			if (tf) {
				fputs(timeStr, tf);
				fclose(tf);
				ret = 0;
			} else {
				ret = -1;
				__LOG(LOG_ERR, "[SRT][%s:%d] Failed to open %s for writing", _FILE_, __LINE__, PATH_START_VIDEO_TIME);
			}
		}
		else {
			__LOG(LOG_INFO, "[SRT][%s:%d] normal mode", _FILE_, __LINE__);
			//sprintf(str, "touch %s %s_", PATH_START_VIDEO_TIME, PATH_START_VIDEO_TIME);
			//__LOG(LOG_NOTICE, "[SRT][%s:%d] %s", _FILE_, __LINE__, str);
			//ret = system(str);
		}

		if(ret < 0) {
			__LOG(LOG_CRIT,"[SRT][%s:%d] ret:%d", _FILE_, __LINE__, ret);
			continue;
		}
	} while(0);

set_start_time:
	__LOG(LOG_NOTICE,"[SRT][%s:%d] file read...", _FILE_, __LINE__);
	do {
		if(m_flagDestroy)
			break;

	    snprintf(str, sizeof(str), "cat %s 2>/dev/null | tr -d '\\n'", PATH_START_VIDEO_TIME);

		fp = popen(str, "r");
		if (NULL == fp) {
			ret = -1;
			perror("popen() fail");
			__LOG(LOG_ERR, "[SRT][%s:%d] ret:%d", _FILE_, __LINE__, ret);
            usleep(10*MSEC);
			continue;
		}
		while (fgets(str, 128, fp));
		ret = pclose(fp);

		if(strchr(str, ':') != NULL) {
			srtMinStart = (uint8_t)atoi(&str[12]);
			srtSecStart = (uint8_t)atoi(&str[15]);
			if(srtMinStart < 60 && srtSecStart < 60) {
				mirror_recording_time_to_cam_state("start_video_time", str);
				if(_TVcmConf.vib_enable)
				{
					__LOG(LOG_NOTICE, "[SRT][%s:%d] writing vib time to %s: %s", _FILE_, __LINE__, PATH_VIB_VIDEO_TIME, str);
					FILE *vf = fopen(PATH_VIB_VIDEO_TIME, "w");
					if (vf) {
						fprintf(vf, "%s\n", str);
						fclose(vf);
						mirror_recording_time_to_cam_state("start_video_time_vib", str);
						ret = 0;
					} else {
						ret = -1;
						__LOG(LOG_ERR, "[SRT][%s:%d] Failed to open %s for writing", _FILE_, __LINE__, PATH_VIB_VIDEO_TIME);
					}
					if (ret < 0)
					{
						__LOG(LOG_ERR, "[SRT][%s:%d] ret:%d", _FILE_, __LINE__, ret);
					}
				}
				break;
			}
		}
        usleep(10*MSEC);
	} while(1);

	while (_TVcmConf.srt_auto_sync)
	{
		if(m_flagDestroy)
			break;

		fp = popen("date +%s", "r");
		if (NULL == fp) {
			ret = -1;
			perror("popen() fail");
			__LOG(LOG_ERR, "[SRT][%s:%d] ret:%d", _FILE_, __LINE__, ret);
            usleep(100*MSEC);
			continue;
		}
		while (fgets(strTmp, 128, fp));
		ret = pclose(fp);
		tmp1 = atol(strTmp);
		snprintf(strTmp, sizeof(strTmp), "date -d '%s' +%%s", str);

		fp = popen(strTmp, "r");
		if (NULL == fp) {
			ret = -1;
			perror("popen() fail");
			__LOG(LOG_ERR, "[SRT][%s:%d] ret:%d", _FILE_, __LINE__, ret);
            usleep(100*MSEC);
			continue;
		}
		while (fgets(strTmp, 128, fp));
		ret = pclose(fp);
		tmp2 = atol(strTmp);

		if(tmp1 > tmp2) {
			__LOG(LOG_WARNING, "[SRT][%s:%d] time diff %d", _FILE_, __LINE__, tmp1-tmp2);
			//srtMinStart = sysTime.wMinute+_TVhlConf.recording_time;
#if 1
            if(tmp1 - tmp2 < 30)
            {
                __LOG(LOG_NOTICE, "[SRT][%s:%d] start time : %s", _FILE_, __LINE__, str);
                __LOG(LOG_INFO, "[SRT][%s:%d] start min : %d, sec : %d", _FILE_, __LINE__, srtMinStart, srtSecStart);
                break;
            }
#endif
		} else {
			//__LOG(LOG_NOTICE, "[SRT][%s:%d] start time : %s", _FILE_, __LINE__, str);
			__LOG(LOG_NOTICE, "[SRT][%s:%d] start min : %d, sec : %d", _FILE_, __LINE__, srtMinStart, srtSecStart);

#if 0
			sprintf(strTmp, "date -d '%s' +'%%Y%%m%%d_%%H%%M%%S'", str);
			fp = popen(strTmp, "r");
			if (NULL == fp) {
				ret = -1;
				perror("popen() fail");
				__LOG(LOG_ERR, "[SRT][%s:%d] ret:%d", _FILE_, __LINE__, ret);
			}
			while (fgets(str, 128, fp));
			ret = pclose(fp);
			sprintf(strTmp, "echo %s > %s_", str, PATH_START_VIDEO_TIME);
#endif
			break;
			//usleep((tmp2-tmp1-1)*SEC);
		}
		sprintf(strTmp, "date '+%%Y%%m%%d %%H:%%M:%%S' -d '%s %d min'", str, _TVhlConf.recording_time);
		__LOG(LOG_WARNING, "[SRT][%s:%d] %s", _FILE_, __LINE__, strTmp);
		fp = popen(strTmp, "r");
		if (NULL == fp) {
			ret = -1;
			perror("popen() fail");
			__LOG(LOG_ERR, "[SRT][%s:%d] ret:%d", _FILE_, __LINE__, ret);
            usleep(100*MSEC);
			continue;
		}
		while (fgets(str, 128, fp));
		ret = pclose(fp);
		srtMinStart = atoi(&str[12]);
		srtSecStart = atoi(&str[15]);
		//srtSecStart = 0;
		resync_f = true;
		__LOG(LOG_WARNING, "[SRT][%s:%d] file resync : %s", _FILE_, __LINE__, str);
	}

	__LOG(LOG_INFO, "[SRT][%s:%d] start wait...", _FILE_, __LINE__);
	do {
		if(m_flagDestroy)
			break;

		sysTime = get_sys_time();
		
		// 목표 시간(srtMinStart:srtSecStart) 대비 현재 시각 차이 계산
		int current_total_sec = sysTime.wMinute * 60 + sysTime.wSecond;
		int target_total_sec = (int)srtMinStart * 60 + (int)srtSecStart;
		int diff = current_total_sec - target_total_sec;

		// 60분 단위 순환 보정
		if (diff < -1800) diff += 3600;
		else if (diff > 1800) diff -= 3600;

		// 목표 시간을 지났거나(diff >= 0) 정각 근처라면 시작
		if(diff >= 0 && diff < 30) 
		{
			__LOG(LOG_INFO, "[SRT][%s:%d] start signal detected (diff:%d)", _FILE_, __LINE__, diff);
			__LOG(LOG_INFO, "[SRT][%s:%d] removing %s", _FILE_, __LINE__, PATH_START_VIDEO_TIME);
			ret = unlink(PATH_START_VIDEO_TIME);
			if(ret < 0 && errno != ENOENT) {
				__LOG(LOG_ERR, "[SRT][%s:%d] unlink fail: %s (errno:%d)", _FILE_, __LINE__, PATH_START_VIDEO_TIME, errno);
                usleep(MSEC);
				continue;
			}
			ret = 0; 
			break;
		}
        usleep(MSEC);

	} while(1);

    if(access("/dev/shm/sd_mount_flag", F_OK) != 0)
    {
        strncpy(_TVhlConf.tmp_path, FALLBACKDIR, sizeof(_TVhlConf.tmp_path)-1);
        __LOG(LOG_ERR, "[GST][%s:%d] sd card no mount...file dir fallback : %s", _FILE_, __LINE__, _TVhlConf.tmp_path);
    }

	struct timespec ts_init;
	clock_gettime(CLOCK_MONOTONIC, &ts_init);
	epochPreMsec = (uint64_t)ts_init.tv_sec * 1000 + (uint64_t)ts_init.tv_nsec / 1000000;

	while(1) {

		if(m_flagDestroy)
			break;

        if(access(PATH_START_VIDEO_TIME, F_OK) == 0) {
            __LOG(LOG_WARNING, "[SRT][%s:%d] reset start video time", _FILE_, __LINE__);
            goto set_start_time;
        }

		do		//if(sysTime.wSecond == 0) 
		{
			struct timespec ts_mono;
			clock_gettime(CLOCK_MONOTONIC, &ts_mono);
			epochCurMsec = (uint64_t)ts_mono.tv_sec * 1000 + (uint64_t)ts_mono.tv_nsec / 1000000;

			if(epochCurMsec - epochPreMsec < _TVcmConf.srt_period) break;

			ret = gettimeofday(&tv, NULL);
			if(ret < 0) {
				__LOG(LOG_ERR, "[SRT][%s:%d] gettimeofday ret:%d", _FILE_, __LINE__, ret);
			}
			
			sysTime = get_sys_time();

			// 현재 시각과 목표 시각의 차이 계산 (초 단위)
			int current_total_sec = sysTime.wMinute * 60 + sysTime.wSecond;
			int target_total_sec = (int)srtMinStart * 60 + (int)srtSecStart;
			int diff = current_total_sec - target_total_sec;

			// 60분(3600초) 단위 순환 보정
			if (diff < -1800) diff += 3600;
			else if (diff > 1800) diff -= 3600;

			if(diff >= 0 && diff < 10) 
			{
				// 이전 세션 완료 처리 (파일이 교체되므로 이전 파일은 완료됨)
				if (_TVcmConf.srt_enable && prefixFileName[0] != 0) {
					char lastTs[16];
					// prefixFileName: VD3000_20260209_143000
					const char* ts_ptr = strchr(prefixFileName, '_');
					if (ts_ptr && strlen(ts_ptr) >= 14) {
						strncpy(lastTs, ts_ptr + 1, 13);
						lastTs[13] = '\0';
						
						char srt_flag[128];
						snprintf(srt_flag, sizeof(srt_flag), "/tmp/session_%s.srt_done", lastTs);
						FILE *fp_flag = fopen(srt_flag, "w");
						if (fp_flag) fclose(fp_flag);
						check_and_mark_all_done(lastTs);
					}
				}

				if(resync_f) {
					srtSecStart = 0;
					tv.tv_sec += sysTime.wSecond;
					resync_f = false;
					//tv.tv_usec += sysTime.wMsecond;
				}
				snprintf(prefixFileName, sizeof(prefixFileName), "%s_%04d%02d%02d_%02d%02d%02d", _TVhlConf.vhl_name, \
						sysTime.wYear, sysTime.wMonth, sysTime.wDay, sysTime.wHour, srtMinStart, 0);

				i = 0;
				setTime = tv.tv_sec;
				srtPreTime.wMinute = 0;
				srtPreTime.wSecond = 0;
				srtPreTime.wMsecond = 0;
				srtMinStart += _TVhlConf.recording_time;
#if 0
				snprintf(strTmp, sizeof(strTmp), "cat /dev/null > %s/%s-data.srt", _TVhlConf.mount_path, prefixFileName);
				ret = system(strTmp);
                if(ret < 0) {
                    __LOG(LOG_ERR, "[SRT][%s:%d] ret:%d", _FILE_, __LINE__, ret);
                }
#endif
				//epochPreMsec = epochCurMsec;

                //if(_TVcmConf.file_time_check)
				sprintf(str, "%04d%02d%02d %02d:%02d:%02d", sysTime.wYear, sysTime.wMonth, sysTime.wDay, sysTime.wHour, sysTime.wMinute, srtSecStart);
				sprintf(strTmp, "echo %s | tee %s %s &>/dev/null", str, PATH_CHECK_VIDEO_TIME, PATH_COPY_VIDEO_TIME);
				__LOG(LOG_INFO, "[SRT][%s:%d] %s", _FILE_, __LINE__, strTmp);
				ret = system(strTmp);
				if (ret < 0)
				{
					__LOG(LOG_ERR, "[SRT][%s:%d] ret:%d", _FILE_, __LINE__, ret);
				}
				else {
					mirror_recording_time_to_cam_state("start_video_time_chk", str);
					mirror_recording_time_to_cam_state("start_video_time_cpy", str);
				}

				if(srtMinStart >= 60) srtMinStart -= 60;
				srtSecStart = 0;

                if(_TVcmConf.srt_enable) __LOG(LOG_INFO, "[SRT][%s:%d] filename : %s/%s-data.srt", _FILE_, __LINE__, _TVhlConf.tmp_path, prefixFileName);
                if(_TVcmConf.vib_test) __LOG(LOG_INFO, "[SRT][%s:%d] filename : %s/%s-vib.bin", _FILE_, __LINE__, _TVhlConf.tmp_path, prefixFileName);
				//srtMinOffset = srtMinStart % recording_time;
			}
			//__E(LOG_LEVEL_TRA, "%ld %ld %ld\n", epochCurMsec, epochPreMsec,  epochCurMsec - epochPreMsec);

			epochPreMsec = epochCurMsec;
			srtCurTime.wMsecond = (tv.tv_usec)/1000;
			srtCurTime.wSecond = (uint16_t)((tv.tv_sec-setTime)%60);
			srtCurTime.wMinute = (uint16_t)(((tv.tv_sec-setTime)/60)%60);

			//sprintf(str, " %s(%0.2f)", opsData.tag, opsData.offset);
			//if(_TVcmConf.ops_enable) sprintf(srtBuf, " %s(%0.2f)", opsData.tag, opsData.offset);

			char srtSnapshot[256];
			pthread_mutex_lock(&g_srtBufMutex);
			snprintf(srtSnapshot, sizeof(srtSnapshot), "%s", srtBuf);
			if(++index > _TVcmConf.srt_set_index) {
				index = 0;
				srtBuf[0] = 0;
			}
			pthread_mutex_unlock(&g_srtBufMutex);

			char srtSafe[256];
			sanitize_srt_text(srtSafe, sizeof(srtSafe), srtSnapshot);

			usleep(srt_delay);
			if(_TVcmConf.srt_enable)
			{
				SrtQueueItem item;
				snprintf(item.filePath, sizeof(item.filePath), "%s/%s-data.srt.part", _TVhlConf.tmp_path, prefixFileName);
				unsigned cueIndex = (unsigned)(++i);
				snprintf(item.entry, sizeof(item.entry),
					"%u\n00:%02u:%02u,%03u --> 00:%02u:%02u,%03u\n%04u-%02u-%02u %02u:%02u:%02u %s\n\n",
					cueIndex,
					(unsigned)srtPreTime.wMinute, (unsigned)srtPreTime.wSecond, (unsigned)srtPreTime.wMsecond,
					(unsigned)srtCurTime.wMinute, (unsigned)srtCurTime.wSecond, (unsigned)srtCurTime.wMsecond,
					(unsigned)sysTime.wYear, (unsigned)sysTime.wMonth, (unsigned)sysTime.wDay,
					(unsigned)sysTime.wHour, (unsigned)sysTime.wMinute, (unsigned)sysTime.wSecond,
					srtSafe);

#ifdef SRT_QUEUE_ENABLE
				// 비동기 쓰기 큐에 작업 추가 (기존 SRT 지연 큐 대신 사용)
				pthread_mutex_lock(&m_fileMutex);
				if (enqueue(&m_fileWriteQueue, &item) == 0) {
					pthread_cond_signal(&m_fileCond);
				} else {
					__LOG(LOG_ERR, "[SRT][%s:%d] file write queue full!", _FILE_, __LINE__);
				}
				pthread_mutex_unlock(&m_fileMutex);
#else
				pthread_mutex_lock(&m_fileMutex);
				if (enqueue(&m_fileWriteQueue, &item) == 0) {
					pthread_cond_signal(&m_fileCond);
				}
				pthread_mutex_unlock(&m_fileMutex);
#endif
			}
			memcpy(srtPreTime.byte, srtCurTime.byte, sizeof(SysTime));

			if(_TVcmConf.vib_test)
			{
				char srtSnapshot[256];
				pthread_mutex_lock(&g_srtBufMutex);
				snprintf(srtSnapshot, sizeof(srtSnapshot), "%s", srtBuf);
				pthread_mutex_unlock(&g_srtBufMutex);

				char srtSafe[256];
				sanitize_srt_text(srtSafe, sizeof(srtSafe), srtSnapshot);

				char vibPath[512];
				snprintf(vibPath, sizeof(vibPath), "%s/%s-vib.bin", _TVhlConf.tmp_path, prefixFileName);
				char vibEntry[768];
				unsigned cueIndex = (unsigned)(++i);
				snprintf(vibEntry, sizeof(vibEntry),
					"%u\n00:%02u:%02u,%03u --> 00:%02u:%02u,%03u\n%04u-%02u-%02u %02u:%02u:%02u %s\n\n",
					cueIndex,
					(unsigned)srtPreTime.wMinute, (unsigned)srtPreTime.wSecond, (unsigned)srtPreTime.wMsecond,
					(unsigned)srtCurTime.wMinute, (unsigned)srtCurTime.wSecond, (unsigned)srtCurTime.wMsecond,
					(unsigned)sysTime.wYear, (unsigned)sysTime.wMonth, (unsigned)sysTime.wDay,
					(unsigned)sysTime.wHour, (unsigned)sysTime.wMinute, (unsigned)sysTime.wSecond,
					srtSafe);

				// vib 데이터도 비동기 큐에 추가
				SrtQueueItem vibItem;
				strncpy(vibItem.filePath, vibPath, sizeof(vibItem.filePath)-1);
				strncpy(vibItem.entry, vibEntry, sizeof(vibItem.entry)-1);
				
				pthread_mutex_lock(&m_fileMutex);
				if (enqueue(&m_fileWriteQueue, &vibItem) == 0) {
					pthread_cond_signal(&m_fileCond);
				}
				pthread_mutex_unlock(&m_fileMutex);
			}
			
			//sleep(59);
		} while(0);

		//usleep(1000);
/*
		for (int i = 0; i <= o_fdMax; i++)
		{
			if (FD_ISSET(i, &o_fds))
				__E(LOG_LEVEL_TRA, "overlay set fd:%d/%d\n", i, o_fdMax);
		}
*/
		usleep(_TVcmConf.srt_period - srt_delay);
	}

#ifdef SRT_QUEUE_ENABLE
	free_queue(&_TSrtQueue);
#endif
	__LOG(LOG_CRIT, "[SRT][%s:%d] SRT thread end", _FILE_, __LINE__);

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

int CTCPServer::init()
{
	int ret ;

	m_flagDestroy = 0 ;

	m_serverSocket = -1 ;
	m_clientSocket = -1 ;

	m_fdMax = -1 ;
	o_fdMax = -1 ;
	n_fdMax = -1 ;
	//memset(fd_overlay, 0, FD_OVERLAY_NUM);

#ifdef SEGFAULT_DEBUG
	struct sigaction sa;
	memset(&sa, 0, sizeof(struct sigaction));
	sigemptyset(&sa.sa_mask);
	sa.sa_sigaction = segfault_sigaction;
	sa.sa_flags = SA_SIGINFO;
	sigaction(SIGSEGV, &sa, NULL);
#endif
	init_json_config();
	__LOG(LOG_INFO, "[TCP][%s:%d] init_json_config done", _FILE_, __LINE__);
	//get_vcm_config(ORD_VCM_JSON_FILE);
	//get_vhl_config(search_json_file((char*)PATH_JSON, (char*)JSON_NAME_PREFIX, (char*)JSON_NAME_SUFFIX));
	get_json_config();
	//get_vcm_config(ORD_VCM_JSON_FILE);
	//unsigned short serverPort = TCP_TEST_PORT ;
	sockaddr_in serverAddr ;

	__LOG(LOG_INFO, "[TCP][%s:%d] get_json_config done", _FILE_, __LINE__);
	m_serverSocket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP) ;
    
	if(m_serverSocket < 0) {
	__LOG(LOG_INFO, "[TCP][%s:%d] init_queue done", _FILE_, __LINE__);
		__LOG(LOG_CRIT, "[TCP][%s:%d] cannot create socket", _FILE_, __LINE__) ;
		//m_flagDestroy = 1;
		return m_serverSocket;
	}

	memset(&serverAddr, 0x0, sizeof(sockaddr_in)) ;

	serverAddr.sin_family 		= AF_INET ;
	serverAddr.sin_addr.s_addr 	= htonl(INADDR_ANY) ;

    memset(_TVcmConf.ip_addr, 0, sizeof(_TVcmConf.ip_addr));
	if(_TVcmConf.ip_addr != NULL && strcmp(_TVcmConf.ip_addr, ""))
		serverAddr.sin_addr.s_addr = inet_addr(_TVcmConf.ip_addr);

	__LOG(LOG_INFO, "[TCP][%s:%d] ip:%s, vhl_name:%s", _FILE_, __LINE__, _TVcmConf.ip_addr, _TVhlConf.vhl_name);
	__LOG(LOG_INFO, "[TCP][%s:%d] ip : %s, port : %d, socket : %d", _FILE_, __LINE__, inet_ntoa(serverAddr.sin_addr), _TVcmConf.portNum, m_serverSocket);
	serverAddr.sin_port 		= htons(_TVcmConf.portNum) ;
	
	int option = 1 ;
	setsockopt(m_serverSocket, SOL_SOCKET, SO_REUSEADDR, &option, sizeof(option)) ;

	ret = bind(m_serverSocket, (struct sockaddr*)&serverAddr, sizeof(sockaddr_in)) ;
	if(ret < 0) {
		__LOG(LOG_CRIT, "[TCP][%s:%d] Server bind failed", _FILE_, __LINE__) ;
		//m_flagDestroy = 1;
		return ret;
	}

	ret = listen(m_serverSocket, MAXPENDING) ;
	if(ret < 0 ) {
		__LOG(LOG_CRIT, "[TCP][%s:%d] Server listen failed", _FILE_, __LINE__) ;
		//m_flagDestroy = 1;
		return ret;
	}
	// create pipes. The pipe will be used to wake up blocked select().
	//pipe(m_pipe) ;

	FD_ZERO(&o_fds) ;
	FD_ZERO(&n_fds) ;
	FD_ZERO(&m_fds) ;
	FD_SET(m_serverSocket, &m_fds) ;
	//FD_SET(m_pipe[0], &m_fds) ;

	m_fdMax = setMaxFD(m_serverSocket, m_fdMax) ;
	//m_fdMax = setMaxFD(m_pipe[0], m_fdMax) ;

	// 파일 쓰기 큐 초기화 (충분한 크기 할당)
	init_queue(&m_fileWriteQueue, 100, sizeof(SrtQueueItem));

	if(ret < 0) {
		__LOG(LOG_CRIT, "[TCP][%s:%d] Server listen failed", _FILE_, __LINE__) ;
		//m_flagDestroy = 1;
		return ret;
	}

	ret = pthread_create(&m_threadConnect, NULL, &thread_waitingConnect, NULL);
	if(ret < 0)
		__LOG(LOG_CRIT, "[TCP][%s:%d] ret:%d", _FILE_, __LINE__, ret);

	// 파일 쓰기 워커 스레드 생성
	ret = pthread_create(&m_threadFileWriter, NULL, &thread_fileWriter, NULL);
	if(ret < 0)
		__LOG(LOG_CRIT, "[WRT][%s:%d] ret:%d", _FILE_, __LINE__, ret);

	// SRT 생성 스레드 무조건 생성 (테스트 및 안정성 확보)
	ret = pthread_create(&m_threadMakeSRT, NULL, &thread_watingMakeSRT, NULL);
	if(ret < 0)
		__LOG(LOG_CRIT, "[SRT][%s:%d] ret:%d", _FILE_, __LINE__, ret);

	if(_TVcmConf.ops_enable) {
		ret = pthread_create(&m_threadGetOPS, NULL, &thread_waitingGetOPS, NULL);
		if(ret < 0)
			__LOG(LOG_CRIT, "[TCP][%s:%d] ret:%d", _FILE_, __LINE__, ret);
	}
    //__LOG(LOG_EMERG, "[CFG][%s:%d] conf:%s", _FILE_, __LINE__, _TVhlConf.vhl_name);

	return ret;
}

int CTCPServer::destroy()
{
	int ret ;
	m_flagDestroy = 1 ;

	__LOG(LOG_EMERG, "[CFG][%s:%d] call server destroy", _FILE_, __LINE__) ;

	// away server thread.
	//write(m_pipe[1], &ret, 1) ;

	void* nStatus ;
	ret = pthread_join(m_threadConnect, &nStatus);
	if(ret < 0)
		__LOG(LOG_CRIT, "[TCP][%s:%d] ret:%d", _FILE_, __LINE__, ret);

	ret = pthread_join(m_threadMakeSRT, &nStatus);
	if(ret < 0)
		__LOG(LOG_CRIT, "[SRT][%s:%d] ret:%d", _FILE_, __LINE__, ret);

	ret = pthread_join(m_threadGetOPS, &nStatus);
	if(ret < 0)
	__LOG(LOG_CRIT, "[TCP][%s:%d] ret:%d", _FILE_, __LINE__, ret);

	// 파일 쓰기 워커 스레드 종료 대기
        pthread_mutex_lock(&m_fileMutex);
        pthread_cond_signal(&m_fileCond);
        pthread_mutex_unlock(&m_fileMutex);
        ret = pthread_join(m_threadFileWriter, &nStatus);
        if(ret < 0)
                __LOG(LOG_CRIT, "[WRT][%s:%d] ret:%d", _FILE_, __LINE__, ret);

        free_queue(&m_fileWriteQueue);

        //close(m_pipe[0]) ;
	//close(m_pipe[1]) ;

	if(m_serverSocket >= 0) {
		ret = close(m_serverSocket);
		if(ret < 0)
			__LOG(LOG_CRIT, "[TCP][%s:%d] ret:%d", _FILE_, __LINE__, ret);
	}

	if(m_clientSocket >= 0) {
		ret = close(m_clientSocket);
		if(ret < 0)
			__LOG(LOG_CRIT, "[TCP][%s:%d] ret:%d", _FILE_, __LINE__, ret);
	}

	//m_flagDestroy = 0 ;
	exit(0);

	return ret;
}

int CTCPServer::sendData(int fd, char* data, int len)
{
	int ret = 0;

	ret = send(fd, data, len, MSG_DONTWAIT);

	if(ret < 0) {
		perror("tcpsnd fail");
		__LOG(LOG_CRIT, "[TCP][%s:%d] ret:%d", _FILE_, __LINE__, ret);
		return ret;
	} else {
		__LOG(LOG_INFO, "[TCP][%s:%d] send data socket_id(%d) byte %d", _FILE_, __LINE__, fd, len);
		__LOG(LOG_DEBUG, "[TCP][%s:%d]\n%s", _FILE_, __LINE__, data);
	}

	return ret ;
}

int CTCPServer::waitingConnect()
{
	char szBuf[BUF_SIZE] ;

	int fd ;
	int ret ;
	unsigned int clientLen ;

	fd_set 	checkFds ;

	int nread ;

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

		pthread_mutex_lock(&m_fdsMutex);
		checkFds = m_fds ;
		pthread_mutex_unlock(&m_fdsMutex);

		ret = select(m_fdMax + 1, &checkFds, 0, 0, NULL) ;
		
		if(ret < 0)
		{
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
				if(ret < 0)
					__LOG(LOG_CRIT, "[TCP][%s:%d] ioctl ret:%d", _FILE_, __LINE__, ret);

				if(nread == 0)
					flagStatus = SERVER_CLOSES_CLIENT_CONNECTION ;
				else
					flagStatus = SERVER_RECEIVES_DATA ;
			}
			
			switch(flagStatus)
			{
			case SERVER_RECEIVES_CONNECTION_REQUEST :
				__LOG(LOG_NOTICE, "[TCP][%s:%d] server receive connection request fd %d", _FILE_, __LINE__, fd) ;
				m_clientSocket = accept(fd, (struct sockaddr*)&clientAddr, (socklen_t*)&clientLen) ;

				if(m_clientSocket < 0) {
					ret = m_clientSocket;
					__LOG(LOG_CRIT, "[TCP][%s:%d] accept ret:%d", _FILE_, __LINE__, ret);
					break;
				}
				
				__LOG(LOG_NOTICE, "[TCP][%s:%d] after accept & m_clientSocket : %d", _FILE_, __LINE__, m_clientSocket) ;
				__LOG(LOG_ALERT, "[TCP][%s:%d] client ip addr : %s", _FILE_, __LINE__, inet_ntoa(clientAddr.sin_addr));

				pthread_mutex_lock(&m_fdsMutex);
				FD_SET(m_clientSocket, &m_fds) ;
				m_fdMax = setMaxFD(m_clientSocket, m_fdMax) ;
				pthread_mutex_unlock(&m_fdsMutex);
				break ;

			case SERVER_RECEIVES_DATA :
				//__E(LOG_LEVEL_TRA, "SERVER_RECEIVES_DATA\n") ;
#if 0
				// 조건에 의해 client의 연결을 거부하는 경우,
				if([condition])
				{
					FD_CLR(fd, &m_readfds) ;
					clese(fd) ;
					break ;
				}
#endif
				memset(szBuf, 0, BUF_SIZE);
				nread = recv(fd, szBuf, BUF_SIZE, 0) ;

				if(nread > 0) {
					__LOG(LOG_INFO, "[TCP][%s:%d] recv data socket_id(%d) byte %d", _FILE_, __LINE__, fd, nread);
					ret = parseTcpRecvData(fd, szBuf, nread) ;
				}
				else
					__LOG(LOG_ERR, "[TCP][%s:%d] ret:%d", _FILE_, __LINE__, ret);

				break ;
			case SERVER_CLOSES_CLIENT_CONNECTION :
				pthread_mutex_lock(&m_fdsMutex);
				FD_CLR(fd, &m_fds);
				if(fd == m_fdMax) m_fdMax--;
				FD_CLR(fd, &o_fds);
				if(fd == o_fdMax) o_fdMax--;
				FD_CLR(fd, &n_fds);
				if(fd == n_fdMax) n_fdMax--;
				pthread_mutex_unlock(&m_fdsMutex);

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

void CTCPServer::init_json_config()
{
	uint8_t i;

	dbg_level = 0;
	log_level = 5;

	strncpy(_TVhlConf.vhl_name, "VD3000", sizeof(_TVhlConf.vhl_name)-1);
	_TVhlConf.recording_time = 1;
	strncpy(_TVhlConf.line, "NONAME", sizeof(_TVhlConf.line)-1);
	strncpy(_TVhlConf.floor, "NONAME", sizeof(_TVhlConf.floor)-1);
	_TVhlConf.event_storage_size = 5;
	_TVhlConf.event_auto_remove = TRUE;
	strncpy(_TVhlConf.tmp_path, PATH_TMP, sizeof(_TVhlConf.tmp_path)-1);
	strncpy(_TVhlConf.log_path, PATH_LOG, sizeof(_TVhlConf.log_path)-1);
	strncpy(_TVhlConf.mount_path, PATH_MOUNT, sizeof(_TVhlConf.mount_path)-1);
	strncpy(_TVhlConf.event_path, PATH_EVENT, sizeof(_TVhlConf.event_path)-1);
	strncpy(_TVhlConf.recycle_path, PATH_RECYCLE, sizeof(_TVhlConf.recycle_path)-1);
	strncpy(_TVhlConf.json_path, PATH_JSON, sizeof(_TVhlConf.json_path)-1);

    for(i=0; i<4; i++)
    {
		_TVhlConf.camConfig[i].enable = TRUE;
		_TVhlConf.camConfig[i].hflip = FALSE;
		_TVhlConf.camConfig[i].vflip = FALSE;
	}

	_TVcmConf.portNum = 10009;
	_TVcmConf.srt_enable = TRUE;
	_TVcmConf.srt_auto_sync = TRUE;
	_TVcmConf.srt_test = FALSE;
	_TVcmConf.srt_set_index = 1;
	_TVcmConf.srt_period = SRT_LOOP_PERIOD;
	_TVcmConf.srt_buffering = 0;
	_TVcmConf.srt_delay = 0;
	_TVcmConf.debug_level = 0;
	_TVcmConf.log_level = 5;
	memset(_TVcmConf.ip_addr, 0, sizeof(_TVcmConf.ip_addr));
	_TVcmConf.file_time_check = TRUE;
	_TVcmConf.ops_enable = FALSE;
	_TVcmConf.ops_period = OPS_LOOP_PERIOD;
	_TVcmConf.ops_buffering = 0;
	_TVcmConf.ops_delay = 0;
	_TVcmConf.vib_test = FALSE;
}

int CTCPServer::get_json_config()
{
	int ret = 0;

	json_object * pJsonObject = NULL;
    json_object *hobj = NULL, *sobj = NULL, *vobj = NULL;
    //json_object *dval;
	//const char* ipTitle;
	uint8_t i;
	char str[8];
	char* json_file;

	json_file = search_json_file(_TVhlConf.json_path, (char*)JSON_NAME_PREFIX, (char*)JSON_NAME_SUFFIX);
    __LOG(LOG_INFO, "[CFG][%s:%d] json file name : %s", _FILE_, __LINE__, json_file);

    if(strstr(json_file, JSON_NAME_PREFIX) == NULL && strstr(json_file, JSON_NAME_SUFFIX) == NULL) {
        __LOG(LOG_CRIT, "[CFG][%s:%d] json file name not match %s %s", _FILE_, __LINE__, JSON_NAME_PREFIX, JSON_NAME_SUFFIX);
        return -1;
    }

	pJsonObject = json_object_from_file(json_file);
	hobj = json_object_object_get(pJsonObject, JSON_HEADER_VHL);

	const char* tmp_str = NULL;
	if (json_object_get_value(hobj, "vhl_name", &tmp_str) == 0) strncpy(_TVhlConf.vhl_name, tmp_str, sizeof(_TVhlConf.vhl_name)-1);
	json_object_get_value(hobj, "recording_time", &_TVhlConf.recording_time);
	if (json_object_get_value(hobj, "line", &tmp_str) == 0) strncpy(_TVhlConf.line, tmp_str, sizeof(_TVhlConf.line)-1);
	if (json_object_get_value(hobj, "floor", &tmp_str) == 0) strncpy(_TVhlConf.floor, tmp_str, sizeof(_TVhlConf.floor)-1);
	json_object_get_value(hobj, "event_storage_size", &_TVhlConf.event_storage_size);
	json_object_get_value(hobj, "event_auto_remove", &_TVhlConf.event_auto_remove);
	if (json_object_get_value(hobj, "tmp_path", &tmp_str) == 0) strncpy(_TVhlConf.tmp_path, tmp_str, sizeof(_TVhlConf.tmp_path)-1);
	//if (json_object_get_value(hobj, "log_path", &tmp_str) == 0) strncpy(_TVhlConf.log_path, tmp_str, sizeof(_TVhlConf.log_path)-1);
	//if (json_object_get_value(hobj, "mount_path", &tmp_str) == 0) strncpy(_TVhlConf.mount_path, tmp_str, sizeof(_TVhlConf.mount_path)-1);
	//if (json_object_get_value(hobj, "event_path", &tmp_str) == 0) strncpy(_TVhlConf.event_path, tmp_str, sizeof(_TVhlConf.event_path)-1);
	//if (json_object_get_value(hobj, "recycle_path", &tmp_str) == 0) strncpy(_TVhlConf.recycle_path, tmp_str, sizeof(_TVhlConf.recycle_path)-1);
	//if (json_object_get_value(hobj, "json_path", &tmp_str) == 0) strncpy(_TVhlConf.json_path, tmp_str, sizeof(_TVhlConf.json_path)-1);

    for(i=0; i<4; i++)
    {
    snprintf(str, sizeof(str), "i2c%d", i/2? 1:2);
    sobj = json_object_object_get(hobj, str);
    snprintf(str, sizeof(str), "ch%d", i);
    vobj = json_object_object_get(sobj, str);
    json_object_get_value(vobj, "enable", &_TVhlConf.camConfig[i].enable);
    json_object_get_value(vobj, "hflip", &_TVhlConf.camConfig[i].hflip);
    json_object_get_value(vobj, "vflip", &_TVhlConf.camConfig[i].vflip);
    //json_object_get_value(vobj, "bps", &_TVhlConf.camConfig[i].bps);
    //json_object_get_value(vobj, "ae_on", &_TVhlConf.camConfig[i].ae_on);
    //json_object_get_value(vobj, "ae_gain", &_TVhlConf.camConfig[i].ae_gain);
    //json_object_get_value(vobj, "exp_time", &_TVhlConf.camConfig[i].exp_time);
    }

#if 0
    for(i=0; i<4; i++)
	{
        __LOG(LOG_NOTICE, "[CFG][%s:%d] ch%d en:%s, vflip:%s, hflip:%s", _FILE_, __LINE__, i, \
				_TVhlConf.camConfig[i].enable? "true":"false",  _TVhlConf.camConfig[i].vflip? "true":"false", _TVhlConf.camConfig[i].hflip? "true":"false");
    }
#endif

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
	hobj = json_object_object_get(pJsonObject, JSON_HEADER_ORD);
	json_object_get_value(hobj, "target_copy", &_TVcmConf.target_copy);
	json_object_get_value(hobj, "vib_enable", &_TVcmConf.vib_enable);

	hobj = json_object_object_get(pJsonObject, JSON_HEADER_VCM);
	json_object_get_value(hobj, "port_num", &_TVcmConf.portNum);
	json_object_get_value(hobj, "srt_enable", &_TVcmConf.srt_enable);
	json_object_get_value(hobj, "srt_auto_sync", &_TVcmConf.srt_auto_sync);
	json_object_get_value(hobj, "srt_test", &_TVcmConf.srt_test);
	json_object_get_value(hobj, "srt_set_index", &_TVcmConf.srt_set_index);
	json_object_get_value(hobj, "srt_period", &_TVcmConf.srt_period);
	json_object_get_value(hobj, "srt_buffering", &_TVcmConf.srt_buffering);
	json_object_get_value(hobj, "srt_delay", &_TVcmConf.srt_delay);
	json_object_get_value(hobj, "debug_level", &_TVcmConf.debug_level);
	json_object_get_value(hobj, "log_level", &_TVcmConf.log_level);
	json_object_get_value(hobj, "ip_static", &_TVcmConf.ip_addr);
	json_object_get_value(hobj, "file_time_check", &_TVcmConf.file_time_check);
	json_object_get_value(hobj, "ops_enable", &_TVcmConf.ops_enable);
	json_object_get_value(hobj, "ops_period", &_TVcmConf.ops_period);
	json_object_get_value(hobj, "ops_buffering", &_TVcmConf.ops_buffering);
	json_object_get_value(hobj, "ops_delay", &_TVcmConf.ops_delay);
	json_object_get_value(hobj, "vib_test", &_TVcmConf.vib_test);

	_TVcmConf.ops_period*=MSEC;

	if(_TVcmConf.srt_buffering > SRT_MAX_QUEUE_SIZE)
	{
		__LOG(LOG_ERR, "[CFG][%s:%d] srt_buffering %d over %d, force zero", _FILE_, __LINE__, _TVcmConf.srt_buffering, SRT_MAX_QUEUE_SIZE);
		_TVcmConf.srt_buffering = 0;
	}

	if(_TVcmConf.srt_delay > _TVcmConf.srt_period)
	{
		__LOG(LOG_ERR, "[CFG][%s:%d] srt_delay %d over %dmsec, force ", _FILE_, __LINE__, _TVcmConf.srt_delay, _TVcmConf.srt_period);
		_TVcmConf.srt_delay = 0;
	}

	if(_TVcmConf.ops_buffering > OPS_MAX_QUEUE_SIZE)
	{
		__LOG(LOG_ERR, "[CFG][%s:%d] ops_buffering %d over %d, force zero", _FILE_, __LINE__, _TVcmConf.ops_buffering, OPS_MAX_QUEUE_SIZE);
		_TVcmConf.ops_buffering = 0;
	}

	if(_TVcmConf.ops_delay > _TVcmConf.ops_period)
	{
		__LOG(LOG_ERR, "[CFG][%s:%d] ops_delay %d over %dmsec, force %dmsec", _FILE_, __LINE__, _TVcmConf.ops_delay, _TVcmConf.ops_period);
		_TVcmConf.ops_delay = 0;
	}

	dbg_level = _TVcmConf.debug_level;
	log_level = _TVcmConf.log_level;

	ret = json_object_put(pJsonObject);
	if(ret < 0)
		__LOG(LOG_ERR, "[CFG][%s:%d] ret:%d", _FILE_, __LINE__, ret);

    __LOG(LOG_INFO, "[CFG][%s:%d] ip:%s, portNum:%d, vhl_name:%s, line:%s, floor:%s, rec_time:%d, evt_size:%d, evt_auto_remove:%d, file_path:%s", \
        _FILE_, __LINE__, _TVcmConf.ip_addr, _TVcmConf.portNum, _TVhlConf.vhl_name, _TVhlConf.line, _TVhlConf.floor, \
		_TVhlConf.recording_time, _TVhlConf.event_storage_size, _TVhlConf.event_auto_remove, _TVhlConf.tmp_path);

    __LOG(LOG_INFO, "[CFG][%s:%d] ch0(en:%d, vflip:%d, hflip:%d), ch1(en:%d, vflip:%d, hflip:%d), ch2(en:%d, vflip:%d, hflip:%d), ch3(en:%d, vflip:%d, hflip:%d)", _FILE_, __LINE__, \
        _TVhlConf.camConfig[0].enable,  _TVhlConf.camConfig[0].vflip, _TVhlConf.camConfig[0].hflip, _TVhlConf.camConfig[1].enable,  _TVhlConf.camConfig[1].vflip, _TVhlConf.camConfig[1].hflip, \
        _TVhlConf.camConfig[2].enable,  _TVhlConf.camConfig[2].vflip, _TVhlConf.camConfig[2].hflip, _TVhlConf.camConfig[3].enable,  _TVhlConf.camConfig[3].vflip, _TVhlConf.camConfig[3].hflip);

    __LOG(LOG_INFO, "[CFG][%s:%d] srt_enable:%d, srt_test:%d, debug:%d, log:%d, " \
		"srt_i:%d, srt_period:%d, srt_buffering:%d, srt_delay%d, srt_auto_sync:%d, file_time_check:%d, target_copy:%d", \
        _FILE_, __LINE__, _TVcmConf.srt_enable, _TVcmConf.srt_test, _TVcmConf.debug_level, _TVcmConf.log_level, \
		_TVcmConf.srt_set_index, _TVcmConf.srt_period, _TVcmConf.srt_buffering, _TVcmConf.srt_delay, _TVcmConf.srt_auto_sync, \
		_TVcmConf.file_time_check, _TVcmConf.target_copy);
	
	__LOG(LOG_INFO, "[CFG][%s:%d] ops_en:%d, ops_period:%d, ops_buffering:%d, ops_delay:%d, vib_en:%d, vib_test:%d", \
		_FILE_, __LINE__, _TVcmConf.ops_enable, _TVcmConf.ops_period, _TVcmConf.ops_buffering, _TVcmConf.ops_delay, _TVcmConf.vib_enable, _TVcmConf.vib_test);

	return ret;
}

int CTCPServer::parseTcpRecvData(int fd, char* data, int len)
{
	int ret = 0;
	int i = 0;
	//json_parse(data, (char*)"REQ");
	const char* cmd;
	char str[1024];
	json_object *jobj = json_tokener_parse(data);
	enum json_type type = json_object_get_type(jobj);
	//json_parse(jobj);

	__LOG(LOG_DEBUG, "[TCP][%s:%d] %s", _FILE_, __LINE__, data);
	//debug_printf("json:%s\n", json_object_get_string(jobj));

	do {
		if(type != json_type_object) {
			__LOG(LOG_ERR, "[TCP][%s:%d] data not json type", _FILE_, __LINE__);
			break;
		}
			
		json_object *val;

		val = json_find_obj(jobj, "REQ");
		type = json_object_get_type(val);

		//debug_printf("value: %s\n", json_object_get_string(val));
		cmd = json_object_get_string(val);
		
		if(type == json_type_string) {
			__LOG(LOG_INFO, "[TCP][%s:%d] recv cmd : %s", _FILE_, __LINE__, cmd);
			if(strcmp(cmd, "SET_OVERLAY_START") == 0) {
				pthread_mutex_lock(&m_fdsMutex);
				if (!FD_ISSET(fd, &o_fds)) {
					FD_SET(fd, &o_fds);
					o_fdMax = setMaxFD(fd, o_fdMax);
					__LOG(LOG_NOTICE, "[OVL][%s:%d] fd add %d/%d", _FILE_, __LINE__, fd, o_fdMax);
				}
				pthread_mutex_unlock(&m_fdsMutex);
			}
			else if(strcmp(cmd, "SET_OVERLAY_STOP") == 0) {
				pthread_mutex_lock(&m_fdsMutex);
				if(fd == o_fdMax) o_fdMax--;
				FD_CLR(fd, &o_fds);
				pthread_mutex_unlock(&m_fdsMutex);
				__LOG(LOG_NOTICE, "[OVL][%s:%d] fd clear %d/%d", _FILE_, __LINE__, fd, o_fdMax);
			}
			else if(strcmp(cmd, "GET_VHL_CAM_NET_STAT") == 0) {
				pthread_mutex_lock(&m_fdsMutex);
				if (!FD_ISSET(fd, &n_fds)) {
					FD_SET(fd, &n_fds);
					n_fdMax = setMaxFD(fd, n_fdMax);
					__LOG(LOG_NOTICE, "[OSS][%s:%d] fd add %d/%d", _FILE_, __LINE__, fd, n_fdMax);
				}
				pthread_mutex_unlock(&m_fdsMutex);
				
				snprintf(str, sizeof(str), "{\n\"REP\":\"GET_VHL_CAM_NET_STAT\",\n\"RET\":0,\n}");
				ret = sendData(fd, str, (int)strlen(str));
				//if(ret < 0) __LOG(LOG_CRIT,"[SRT][%s:%d] ret:%d", _FILE_, __LINE__, ret);
			}
			else if(strcmp(cmd, "GET_CONFIG") == 0) {
				//json_parse(json_object_from_file(JSON_FILE), (char*)"VHL_CAM");
				//jsonConf.vhl_name = get_str_from_json(JSON_FILE, JSON_HEADER_VHL, "vhl_name");
				/*
				ret = get_vhl_config(EDGE_JSON_FILE);
				if(ret < 0) {
					__LOG(LOG_CRIT,"[SRT][%s:%d] ret:%d", _FILE_, __LINE__, ret);
					break;
				}
				*/
				//sprintf(str, " ");
#if 1
snprintf(str, sizeof(str), "{\n\
\"REP\":\"GET_CONFIG\",\n\
\"RET\":0,\n\
\"DATA\":{\n\
\"VHL_CAM\":{\n\
\"vhl_name\":\"%s\",\n\
\"line\":\"%s\",\n\
\"floor\":\"%s\",\n\
\"cam_ch0\":%s,\n\
\"cam_ch1\":%s,\n\
\"cam_ch2\":%s,\n\
\"cam_ch3\":%s,\n\
\"ch0_hflip\":%s,\n\
\"ch0_vflip\":%s,\n\
\"ch1_hflip\":%s,\n\
\"ch1_vflip\":%s,\n\
\"ch2_hflip\":%s,\n\
\"ch2_vflip\":%s,\n\
\"ch3_hflip\":%s,\n\
\"ch3_vflip\":%s,\n\
\"recording_time\":%d,\n\
\"event_storage_size\":%d,\n\
\"event_auto_remove\":%s,\n}\n}\n}", \
_TVhlConf.vhl_name, _TVhlConf.line, _TVhlConf.floor, \
_TVhlConf.camConfig[0].enable? "true":"false", _TVhlConf.camConfig[1].enable? "true":"false", \
_TVhlConf.camConfig[2].enable? "true":"false", _TVhlConf.camConfig[3].enable? "true":"false", \
_TVhlConf.camConfig[0].hflip? "true":"false", _TVhlConf.camConfig[0].vflip? "true":"false", \
_TVhlConf.camConfig[1].hflip? "true":"false", _TVhlConf.camConfig[1].vflip? "true":"false", \
_TVhlConf.camConfig[2].hflip? "true":"false", _TVhlConf.camConfig[2].vflip? "true":"false", \
_TVhlConf.camConfig[3].hflip? "true":"false", _TVhlConf.camConfig[3].vflip? "true":"false", \
_TVhlConf.recording_time, _TVhlConf.event_storage_size, _TVhlConf.event_auto_remove? "true":"false");
#else
ret = sprintf(str, "{\n\
\"REP\":\"GET_CONFIG\",\n\
\"RET\":0,\n\
\"DATA\":{\n\
\"VHL_CAM\":{\n\
\"vhl_name\":\"%s\",\n\
\"line\":\"%s\",\n\
\"floor\":\"%s\",\n\
\"recording_time\":%d,\n\
\"event_storage_size\":%d,\n\
\"event_auto_remove\":%s,\n\
\"ch0\":{\n\
enable:%s,\n\
hflip:%s,\n\
vflip:%s\n\
},\n\
\"ch1\":{\n\
enable:%s,\n\
hflip:%s,\n\
vflip:%s\n\
},\n\
\"ch2\":{\n\
enable:%s,\n\
hflip:%s,\n\
vflip:%s\n\
},\n\
\"ch3\":{\n\
enable:%s,\n\
hflip:%s,\n\
vflip:%s\n\
}\n\
\n}\n}\n}", \
_TVhlConf.vhl_name, _TVhlConf.line, _TVhlConf.floor, _TVhlConf.recording_time, _TVhlConf.event_storage_size, _TVhlConf.event_auto_remove? "true":"false", \
_TVhlConf.camConfig[0].enable? "true":"false", _TVhlConf.camConfig[0].hflip? "true":"false", _TVhlConf.camConfig[0].vflip? "true":"false",
_TVhlConf.camConfig[1].enable? "true":"false", _TVhlConf.camConfig[1].hflip? "true":"false", _TVhlConf.camConfig[1].vflip? "true":"false",
_TVhlConf.camConfig[2].enable? "true":"false", _TVhlConf.camConfig[2].hflip? "true":"false", _TVhlConf.camConfig[2].vflip? "true":"false",
_TVhlConf.camConfig[3].enable? "true":"false", _TVhlConf.camConfig[3].hflip? "true":"false", _TVhlConf.camConfig[3].vflip? "true":"false");
#endif
				ret = sendData(fd, str, strlen(str));
				//if(ret < 0) {__LOG(LOG_CRIT,"[SRT][%s:%d] ret:%d", _FILE_, __LINE__, ret); break;}
			}
			else if(strcmp(cmd, "GET_VHL_CAM_ERROR") == 0) {
snprintf(str, sizeof(str), "{\n\
\"REP\":\"GET_VHL_CAM_ERROR\",\n\
\"RET\":0,\n\
\"DATA\":{\n\
\"power_current_err\":\"%s\",\n\
\"cam_ch0_err\":\"%s\",\n\
\"cam_ch1_err\":\"%s\",\n\
\"cam_ch2_err\":%s,\n\
\"cam_ch3_err\":%s,\n\
\"wifi_err\":%s,\n\
\"sd_err\":%s,\n\
\"temp_err\":%s,\n}\n}", \
_TVhlErr.power_current_err? "true":"false",_TVhlErr.cam_ch0_err? "true":"false", _TVhlErr.cam_ch1_err? "true":"false", \
_TVhlErr.cam_ch2_err? "true":"false", _TVhlErr.cam_ch3_err? "true":"false", _TVhlErr.wifi_err? "true":"false", \
_TVhlErr.sd_err? "true":"false", _TVhlErr.temp_err? "true":"false");

				if(ret < 0) {
					__LOG(LOG_CRIT, "[TCP][%s:%d] ret:%d", _FILE_, __LINE__, ret);
					break;
				}

				ret = sendData(fd, str, strlen(str));
				//if(ret < 0) {__LOG(LOG_CRIT,"[SRT][%s:%d] ret:%d", _FILE_, __LINE__, ret); break;}
			}
			else {
				ret = -1;
				__LOG(LOG_CRIT, "[TCP][%s:%d] json cmd not match", _FILE_, __LINE__);
			}
			break;
		}
		
		val = json_find_obj(jobj, "REP");
		type = json_object_get_type(val);

		//debug_printf("value: %s\n", json_object_get_string(val));
		cmd = json_object_get_string(val);
		
		if(type == json_type_string) {
			__LOG(LOG_NOTICE, "[TCP][%s:%d] recv cmd : %s", _FILE_, __LINE__, cmd);
			if(strcmp(cmd, "SET_EVENT_STREAM") == 0) {
				__LOG(LOG_NOTICE, "[OSS][%s:%d] rep event oss", _FILE_, __LINE__);
			} else {
				ret = -1;
				__LOG(LOG_CRIT, "[TCP][%s:%d] json cmd not match", _FILE_, __LINE__);
			}
		}
	} while(0);

	ret = json_object_put(jobj);
	if(ret < 0)
		__LOG(LOG_CRIT, "[TCP][%s:%d] ret:%d", _FILE_, __LINE__, ret);

	return ret;
}

int CTCPServer::SendDataForSetFD(uint16_t type, char* data, int len)
{
	int i;
	int ret = 0;
	bool sendOss_f = false;
	//__E(LOG_LEVEL_TRA, "SendDataForSetFD\n");
	switch(type) {
		case PMSG_TYPE_OVERLAY:
			__LOG(LOG_INFO, "[OVL][%s:%d] pmsg type overlay", _FILE_, __LINE__);
			pthread_mutex_lock(&m_fdsMutex);
			for (i = 0; i <= o_fdMax; i++)
			{
				if(FD_ISSET(i, &o_fds)) {
					//__E(LOG_LEVEL_DBG, "Overlay send for fd:%d\n", i);
					ret = sendData(i, data, len);
				}
			}
			pthread_mutex_unlock(&m_fdsMutex);
			break;
		case PMSG_TYPE_OSS:
			__LOG(LOG_NOTICE, "[OSS][%s:%d] pmsg type oss", _FILE_, __LINE__);
			pthread_mutex_lock(&m_fdsMutex);
			for (i = 0; i <= n_fdMax; i++)
			{
				if(FD_ISSET(i, &n_fds)) {
					//__E(LOG_LEVEL_DBG, "OSS send for fd:%d\n", i);
					__LOG(LOG_NOTICE, "[OSS][%s:%d] send cmd event oss", _FILE_, __LINE__);
					ret = sendData(i, data, len);
					sendOss_f = true;
				}
			}
			pthread_mutex_unlock(&m_fdsMutex);
			if(!sendOss_f)
				__LOG(LOG_CRIT, "[OSS][%s:%d] don't send oss because fd is not exist", _FILE_, __LINE__);
			break;
		default:
			__LOG(LOG_ERR, "[IPC][%s:%d] pmsg type none", _FILE_, __LINE__);
			break;
	}

	return ret;
}

#if 0
int json_parse(char* data, char* key) 
{
		int ret = 0;
		json_object *jobj = json_tokener_parse(data);
		//      json_parse(jobj);
		uint8_t type;
		json_object *val = json_find_obj(jobj, key);
		type = json_object_get_type(val);

		switch (type)
		{
		case json_type_null:
			printf("json_type_null\n");
			break;
		case json_type_boolean:
			printf("json_type_boolean (%s)", key);
			printf("          value: %d\n", json_object_get_boolean(val));
			break;
		case json_type_double:
			printf("json_type_double (%s)", key);
			printf("          value: %lf\n", json_object_get_double(val));
			break;
		case json_type_int:
			printf("json_type_int (%s)", key);
			printf("          value: %d\n", json_object_get_int(val));
			break;
		case json_type_object:
			printf("json_type_object (%s)", key);
			jobj = json_object_object_get(val, key);
			//json_parse(jobj, (char*)"bitrate");
			break;
		case json_type_string:
			printf("json_type_string (%s)", key);
			printf("          value: '%s'\n", json_object_get_string(val));
			break;
		}

		json_object_put(jobj);
		// exit (0);
		return ret;
}
#endif
