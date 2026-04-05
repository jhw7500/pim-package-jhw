
#include "util.h"
//#include <sys/sysinfo.h>

uint8_t dbg_level;
uint8_t log_level;

void mylog( int opt, const char* _szfmt, ... )
{
	va_list va;
	va_list va2;
	char strTmp[512]; 
	//struct sysinfo s_sysinfo_local;

	//const char *debug_codes[] = {"LOG_EMERG", "LOG_ALERT", "LOG_CRIT", "LOG_ERR", "LOG_WARNING", "LOG_NOTICE", "LOG_INFO", "LOG_DEBUG"};
	const char *debug_codes[] = {"emerg", "alert", "crit", "err", "warning", "notice", "info", "debug"};
	va_start( va, _szfmt );
	va_copy(va2, va);
	vsnprintf(strTmp, sizeof(strTmp), _szfmt, va2);
	va_end(va2);
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
        //syslog( opt|LOG_LOCAL0, "log_level:%d", log_level);
	}

	if(opt <= dbg_level || opt <= LOG_ALERT) {
		SysTime saveTime = get_sys_time();
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
		printf("%s\n", strTmp);
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
		return 0;
	}
	while (fgets(str, 64, fp));

	ret = pclose(fp);
	if(ret < 0) {
		__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
	}
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
		return 0;
	}
	while (fgets(str, 64, fp));

	ret = pclose(fp);
	if(ret < 0) {
		__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
	}
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
		return 0;
	}
	while (fgets(str, 64, fp));

	ret = pclose(fp);
	if(ret < 0) {
		__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
	}
	
	return atol(str);
}

uint16_t get_file_cnt(const char *path, uint8_t depth)
{
	int ret ;
	char str[128];
	FILE *fp;

    if(is_dir_exist(path) < 0) {
        mkdir(path, 0755);
        __LOG(LOG_NOTICE, "[DSK][%s:%d] mkdir %s", _FILE_, __LINE__, path);
        //return 0;
    }

	//ret = sprintf(str, "ls -lt %s | grep ^- | wc -l", path);
	if(depth)
		ret = sprintf(str, "find %s -maxdepth %d -type f | wc -l", path, depth);
	else
		ret = sprintf(str, "find %s -type f | wc -l", path);

	if(ret < 0) {
		__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
	}
	__LOG(LOG_DEBUG, "[DSK][%s:%d] %s", _FILE_, __LINE__, str);
	fp = popen(str, "r");
	if (NULL == fp) {
		ret = -1;
		perror("popen() fail");
		__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
		return 0;
	}
	while (fgets(str, 64, fp));

	ret = pclose(fp);
	if(ret < 0) {
		__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
	}

	return atoi(str);
}

SysTime get_sys_time()
{
	time_t timer;
	struct tm lt;
	SysTime dateTime;

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

int compSysTime(SysTime t1, SysTime t2)
{
	if(t1.wYear > t2.wYear)
		return 1;
	else if(t1.wYear < t2.wYear)
		return -1;
	
	if(t1.wMonth > t2.wMonth)
		return 1;
	else if(t1.wMonth < t2.wMonth)
		return -1;

	if(t1.wDay > t2.wDay)
		return 1;
	else if(t1.wDay < t2.wDay)
		return -1;

	if(t1.wHour > t2.wHour)
		return 1;
	else if(t1.wHour < t2.wHour)
		return -1;

	if(t1.wMinute > t2.wMinute)
		return 1;
	else if(t1.wMinute < t2.wMinute)
		return -1;

	if(t1.wSecond > t2.wSecond)
		return 1;
	else if(t1.wSecond < t2.wSecond)
		return -1;

	return 0;
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
	int ret ;
	FILE *fp;
	static char str[128];

    sprintf(str, "ls -ptr %s/%s*%s | grep -v '/$' | grep '\\%s$' | tail -1 | tr -d '\r\n'", path, prefix, suffix, suffix);
	//sprintf(str, "find %s/ -maxdepth 1 -type f -name \"%s*%s\" -printf '%%T+ %%p\\n' | sort -r | head -n 1 | cut -d\" \" -f2- | tr -d '\\r\\n'", path, prefix, suffix);
	
    fp = popen(str, "r");
    if (NULL == fp)
    {
        perror("popen() fail");
        __LOG(LOG_CRIT, "[CFG][%s:%d] popen fail", _FILE_, __LINE__);
    }
    while (fgets(str, 128, fp));
	
	__LOG(LOG_INFO, "[CFG][%s:%d] search_json_file : %s", _FILE_, __LINE__, str);
	ret = pclose(fp);
	if(ret < 0) {
		__LOG(LOG_CRIT, "[DSK][%s:%d] ret:%d", _FILE_, __LINE__, ret);
	}
	//Eliminate(str, '\n');

	return str;
}

void Eliminate(char *str, char ch)
{
    for (; *str != '\0'; str++)
    {
        if (*str == ch)
        {
	memmove(str, str + 1, strlen(str));
            str--;
        }
    }
}

void bubble_sort(int arr[], int count)    // 매개변수로 정렬할 배열과 요소의 개수를 받음
{
    int temp;

    for (int i = 0; i < count; i++)    // 요소의 개수만큼 반복
    {
        for (int j = 0; j < count - 1; j++)   // 요소의 개수 - 1만큼 반복
        {
            if (arr[j] > arr[j + 1])          // 현재 요소의 값과 다음 요소의 값을 비교하여
            {                                 // 큰 값을
                temp = arr[j];
                arr[j] = arr[j + 1];
                arr[j + 1] = temp;            // 다음 요소로 보냄
            }
        }
    }
}

void makeDir(const char* path)
{
#if 0
    struct stat st = {0};

    if (stat(path, &st) == -1) {
        if(mkdir(path, 0755) == -1)
        {
            __LOG(LOG_INFO, "[CFG][%s:%d] %s : %s fail", _FILE_, __LINE__, __FUNCTION__, path);
        }
    }
#endif
    __LOG(LOG_NOTICE, "[CFG][%s:%d] %s : %s", _FILE_, __LINE__, __FUNCTION__, path);
    mkdir(path, 0755);
    return;
}

json_object *json_find_obj (json_object * jobj, const char *find_key)
{
    size_t key_len = strlen(find_key);
    json_object_object_foreach(jobj, key, val) {
        if (strlen(key) == key_len && !memcmp (key, find_key, key_len)) return val;
    }
    return NULL;    // not found.
}

int json_object_get_value(json_object *hobj, const char *name, void* data)
{
    int ret = 0;
    //json_object *vobj = json_find_obj(obj, (char *)name);
    json_object *vobj;

    vobj = json_object_object_get(hobj, name);

    if (!vobj) {
        __LOG(LOG_ERR, "[CFG][%s:%d] not exist: %s", _FILE_, __LINE__, name);
        return -1;
    }

    enum json_type type = json_object_get_type(vobj);

    if(type == json_type_string) {
        char **val = (char**)data;
        *val = (char*)json_object_get_string(vobj);
        __LOG(LOG_INFO, "[CFG][%s:%d] %s : %s", _FILE_, __LINE__, name, *val);
    }
    else if(type == json_type_int) {
        int *val = (int *)data;
        *val = json_object_get_int(vobj);
        __LOG(LOG_INFO, "[CFG][%s:%d] %s : %d", _FILE_, __LINE__, name, *val);
    }
    else if(type == json_type_boolean) {
        bool *val = (bool *)data;
        *val = json_object_get_boolean(vobj);
        __LOG(LOG_INFO, "[CFG][%s:%d] %s : %s", _FILE_, __LINE__, name, *val? "TRUE":"FALSE");
    }
    else if(type == json_type_double) {
        double *val = (double *)data;
        *val = json_object_get_double(vobj);
        __LOG(LOG_INFO, "[CFG][%s:%d] %s : %f", _FILE_, __LINE__, name, *val);
    }
    else if(type == json_type_array) {
        array_list *arr = json_object_get_array(vobj);
        //g_print("len:%ld arr->size:%ld arr->len:%ld\n", json_object_array_length(vobj), arr->size, arr->length);
        for(size_t i=0; i<arr->length; i++)
        {
            json_object *retrieved_obj = (json_object *)array_list_get_idx(arr, i);

			if (!retrieved_obj) continue;

            type = json_object_get_type(retrieved_obj);
            if(type == json_type_string) {
                char **arr = (char**)data;
                arr[i] = (char*)json_object_get_string(retrieved_obj);
                __LOG(LOG_INFO, "[CFG][%s:%d] %s[%d] : %s", _FILE_, __LINE__, name, i, arr[i]);
            }
            else if(type == json_type_int) {
                int *arr = (int *)data;
                arr[i] = json_object_get_int(retrieved_obj);
                __LOG(LOG_INFO, "[CFG][%s:%d] %s[%d] : %d", _FILE_, __LINE__, name, i, arr[i]);
            }
            else if(type == json_type_boolean) {
                bool *arr = (bool *)data;
                arr[i] = json_object_get_boolean(retrieved_obj);
                __LOG(LOG_INFO, "[CFG][%s:%d] %s[%d] : %s", _FILE_, __LINE__, name, i, arr[i]? "TRUE":"FALSE");
            }
            else if(type == json_type_double) {
                double *arr = (double *)data;
                arr[i] = json_object_get_double(retrieved_obj);
                __LOG(LOG_INFO, "[CFG][%s:%d] %s[%d] : %f", _FILE_, __LINE__, name, i, arr[i]);
            }
            else if(type == json_type_null)
            {
                __LOG(LOG_ERR, "[CFG][%s:%d] not exist : %s", _FILE_, __LINE__, name);
				return -1;
            }
            else
            {
                __LOG(LOG_ERR, "[CFG][%s:%d] unsupport type : %d", _FILE_, __LINE__, type);
				return -1;
            }
        }
    }
    else if(type == json_type_null)
    {
        __LOG(LOG_ERR, "[CFG][%s:%d] not exist : %s", _FILE_, __LINE__, name);
		return -1;
    }
    else
    {
        __LOG(LOG_ERR, "[CFG][%s:%d] unsupport type : %d", "CFG", _FILE_, __LINE__, type);
		return -1;
    }

    //ret = json_object_put(vobj);

    return ret;
}

void init_queue(TQueue *queue, size_t capacity, size_t element_size) {
    queue->capacity = capacity;
    queue->element_size = element_size;
    queue->buffer = malloc(capacity * element_size);  // 총 메모리 크기 = 용량 * 요소 크기
    queue->inptr = 0;
    queue->outptr = 0;
    queue->size = 0;
}

int enqueue(TQueue *queue, const void *data) {
    if (queue->size == queue->capacity) {
        return -1;
    }
    void *target = (char *)queue->buffer + (queue->inptr * queue->element_size);
    memcpy(target, data, queue->element_size); 
    queue->inptr = (queue->inptr + 1) % queue->capacity;
    queue->size++;
    return 0;
}

int dequeue(TQueue *queue, void *data) {
    if (queue->size == 0) {
        return -1;
    }
    void *source = (char *)queue->buffer + (queue->outptr * queue->element_size);
    memcpy(data, source, queue->element_size);
    queue->outptr = (queue->outptr + 1) % queue->capacity;
    queue->size--;
    return 0;
}

void free_queue(TQueue *queue) {
    free(queue->buffer);
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
