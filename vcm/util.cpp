#include "util.h"
#include <errno.h>

uint8_t dbg_level;
uint8_t log_level;

void mylog( int opt, const char* _szfmt, ... )
{
	va_list va;
	char strTmp[512]; 

	const char *debug_codes[] = {"emerg", "alert", "crit", "err", "warning", "notice", "info", "debug"};
	va_start( va, _szfmt );
	
	vsnprintf(strTmp, sizeof(strTmp), _szfmt, va);

	if(opt <= log_level || opt <= LOG_ALERT) 
	{
		syslog( opt|LOG_LOCAL0, "%s", strTmp);
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

		printf(" %s\n", strTmp);
		fflush(stdout);
	}

	va_end( va );
}

uint64_t get_disk_size(const char *path)
{
	int ret ;
	char str[64];
	FILE *fp;

	ret = snprintf(str, sizeof(str), "df --block-size=1 %s |awk '{print $2}'", path);
	if(ret < 0 || ret >= (int)sizeof(str)) {
		__LOG(LOG_CRIT, "[DSK][%s:%d] snprintf error or truncated", _FILE_, __LINE__);
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
	return atol(str);
}

uint64_t get_disk_use_size(const char *path)
{
	int ret ;
	char str[64];
	FILE *fp;

	ret = snprintf(str, sizeof(str), "df --block-size=1 %s |awk '{print $3}'", path);
	if(ret < 0 || ret >= (int)sizeof(str)) {
		__LOG(LOG_CRIT, "[DSK][%s:%d] snprintf error or truncated", _FILE_, __LINE__);
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

	ret = snprintf(str, sizeof(str), "du -sb %s |awk '{print $1}'", path);
	if(ret < 0 || ret >= (int)sizeof(str)) {
		__LOG(LOG_CRIT, "[DSK][%s:%d] snprintf error or truncated", _FILE_, __LINE__);
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
	return atol(str);
}

uint16_t get_file_cnt(const char *path, uint8_t depth)
{
	int ret ;
	char str[128];
	FILE *fp;

	if(depth)
		ret = snprintf(str, sizeof(str), "find %s -maxdepth %d -type f | wc -l", path, depth);
	else
		ret = snprintf(str, sizeof(str), "find %s -type f | wc -l", path);

	if(ret < 0 || ret >= (int)sizeof(str)) {
		__LOG(LOG_CRIT, "[DSK][%s:%d] snprintf error or truncated", _FILE_, __LINE__);
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
	if(t1.wYear > t2.wYear) return 1;
	else if(t1.wYear < t2.wYear) return -1;
	if(t1.wMonth > t2.wMonth) return 1;
	else if(t1.wMonth < t2.wMonth) return -1;
	if(t1.wDay > t2.wDay) return 1;
	else if(t1.wDay < t2.wDay) return -1;
	if(t1.wHour > t2.wHour) return 1;
	else if(t1.wHour < t2.wHour) return -1;
	if(t1.wMinute > t2.wMinute) return 1;
	else if(t1.wMinute < t2.wMinute) return -1;
	if(t1.wSecond > t2.wSecond) return 1;
	else if(t1.wSecond < t2.wSecond) return -1;
	return 0;
}

int is_dir_exist(const char* path)
{
	struct stat statbuf;
	int ret = stat(path, &statbuf);
	if(ret != -1) {
		if(S_ISDIR(statbuf.st_mode)) return 0;
	}
	return -1;
}

long getTick()
{
	struct timespec tspec;
	if (clock_gettime(CLOCK_MONOTONIC, &tspec) == -1) return 0;
	return tspec.tv_sec;
}

char* search_json_file(char* path, char* prefix, char* suffix)
{
	int ret;
	FILE *fp;
	static char str[128];
	const char* search_path = path;

	// Check access permission, if not accessible, try fallback
	if (access(path, R_OK | X_OK) != 0) {
		__LOG(LOG_WARNING, "[CFG][%s:%d] Cannot access %s (errno:%d), trying fallback...", _FILE_, __LINE__, path, errno);
		if (access(PATH_JSON_LOCAL, R_OK | X_OK) == 0) {
			search_path = PATH_JSON_LOCAL;
		} else {
			search_path = "/tmp";
		}
		__LOG(LOG_INFO, "[CFG][%s:%d] Fallback path selected: %s", _FILE_, __LINE__, search_path);
	}

    ret = snprintf(str, sizeof(str), "ls -ptr %s/%s*%s | grep -v '/$' | grep '\\%s$' | tail -1 | tr -d '\\r\\n'", search_path, prefix, suffix, suffix);
    __LOG(LOG_INFO, "[CFG][%s:%d] Search command: %s", _FILE_, __LINE__, str);

    fp = popen(str, "r");
    if (NULL == fp) {
        perror("popen() fail");
        __LOG(LOG_CRIT, "[CFG][%s:%d] popen fail", _FILE_, __LINE__);
		return (char*)"";
    }
    while (fgets(str, 128, fp));

	__LOG(LOG_INFO, "[CFG][%s:%d] search_json_file result: %s", _FILE_, __LINE__, str);
	ret = pclose(fp);
	return str;
}

void Eliminate(char *str, char ch)
{
    for (; *str != '\0'; str++) {
        if (*str == ch) {
            memmove(str, str + 1, strlen(str));
            str--;
        }
    }
}

void bubble_sort(int arr[], int count)
{
    int temp;
    for (int i = 0; i < count; i++) {
        for (int j = 0; j < count - 1; j++) {
            if (arr[j] > arr[j + 1]) {
                temp = arr[j];
                arr[j] = arr[j + 1];
                arr[j + 1] = temp;
            }
        }
    }
}

void makeDir(const char* path)
{
    __LOG(LOG_NOTICE, "[CFG][%s:%d] %s : %s", _FILE_, __LINE__, __FUNCTION__, path);
    mkdir(path, 0755);
}

json_object *json_find_obj (json_object * jobj, const char *find_key)
{
	size_t key_len = strlen(find_key);
    json_object_object_foreach(jobj, key, val) {
        if (strlen(key) == key_len && !memcmp (key, find_key, key_len)) return val;
    }
    return NULL;
}

int json_object_get_value(json_object *hobj, const char *name, void* data)
{
    int ret = 0;
    json_object *vobj = json_object_object_get(hobj, name);
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
        for(size_t i=0; i<arr->length; i++) {
            json_object *retrieved_obj = (json_object *)array_list_get_idx(arr, i);
			if (!retrieved_obj) continue;
            type = json_object_get_type(retrieved_obj);
            if(type == json_type_string) {
                char **str_arr = (char**)data;
                str_arr[i] = (char*)json_object_get_string(retrieved_obj);
                __LOG(LOG_INFO, "[CFG][%s:%d] %s[%d] : %s", _FILE_, __LINE__, name, (int)i, str_arr[i]);
            } else if(type == json_type_int) {
                int *int_arr = (int *)data;
                int_arr[i] = json_object_get_int(retrieved_obj);
                __LOG(LOG_INFO, "[CFG][%s:%d] %s[%d] : %d", _FILE_, __LINE__, name, (int)i, int_arr[i]);
            }
        }
    }
    return ret;
}

void init_queue(TQueue *queue, size_t capacity, size_t element_size) {
    queue->capacity = capacity;
    queue->element_size = element_size;
    queue->buffer = malloc(capacity * element_size);
    queue->inptr = 0;
    queue->outptr = 0;
    queue->size = 0;
}

int enqueue(TQueue *queue, const void *data) {
    if (queue->size == queue->capacity) return -1;
    void *target = (char *)queue->buffer + (queue->inptr * queue->element_size);
    memcpy(target, data, queue->element_size); 
    queue->inptr = (queue->inptr + 1) % queue->capacity;
    queue->size++;
    return 0;
}

int dequeue(TQueue *queue, void *data) {
    if (queue->size == 0) return -1;
    void *source = (char *)queue->buffer + (queue->outptr * queue->element_size);
    memcpy(data, source, queue->element_size);
    queue->outptr = (queue->outptr + 1) % queue->capacity;
    queue->size--;
    return 0;
}

void free_queue(TQueue *queue) {
    free(queue->buffer);
}
