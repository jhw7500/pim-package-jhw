
#include "ipc.h"

void* thread_waitingRecv(void* pData)
{
	IpcClient* instance = IpcClient::getInstance() ;

	__LOG(LOG_INFO, "[IPC][%s:%d] thread start", _FILE_, __LINE__);

	if(instance->waitingRecv() < 0) instance->m_flagDestroy = 1;

	return NULL ;
}

IpcClient* IpcClient::getInstance()
{
	static IpcClient instance ;

    return &instance ;
}

int IpcClient::init()
{
    int ret = 0;
	m_flagDestroy = 0;
	
#if 1
    int msg_id = msgget((key_t)MSG_Q_KEY, IPC_CREAT | 0660);

    if(msg_id == -1) {
        perror("msgget fail");
		__LOG(LOG_CRIT, "[IPC][%s:%d] ret:%d", _FILE_, __LINE__, ret);
        return msg_id;
    }
	ret = msgctl(msg_id, IPC_RMID, NULL);
    if(ret < 0) {
		 perror("msgctl fail");
		 __LOG(LOG_CRIT, "[IPC][%s:%d] ret:%d", _FILE_, __LINE__, ret);
	}
 #endif
	ret = pthread_create(&m_threadRecv, NULL, &thread_waitingRecv, NULL);
    if(ret < 0)
		__LOG(LOG_CRIT, "[IPC][%s:%d] ret:%d", _FILE_, __LINE__, ret);

    return ret;
}

int IpcClient::destory()
{
    int ret = 0;
    void* nStatus ;

	__LOG(LOG_EMERG, "[IPC][%s:%d] call server destroy", _FILE_, __LINE__) ;
	ret = pthread_join(m_threadRecv, &nStatus);
	if(ret < 0)
		__LOG(LOG_CRIT, "[IPC][%s:%d] ret:%d", _FILE_, __LINE__, ret);

    int msg_id = msgget((key_t)MSG_Q_KEY, IPC_CREAT | 0660);

    if(msg_id == -1) {
        perror("msgget fail");
		__LOG(LOG_CRIT, "[IPC][%s:%d] ret:%d", _FILE_, __LINE__, ret);
        return msg_id;
    }

	ret = msgctl(msg_id, IPC_RMID, NULL);
    if(ret < 0) {
		perror("msgctl fail");
		__LOG(LOG_CRIT, "[IPC][%s:%d] ret:%d", _FILE_, __LINE__, ret);
	}
	exit(0);

    return ret;
}

#if 1
int IpcClient::getBufLen()
{
    return strlen(sendBuf.data);
}

char IpcClient::getBufType()
{
    return sendBuf.type;
}


char* IpcClient::getBufData()
{
    return sendBuf.data;
}

void IpcClient::clearBuf()
{
    memset((char*)&sendBuf, 0, sizeof(sendBuf));
    
    return;
}
#endif
int IpcClient::waitingRecv()
{
    int ret;
    int i;
    int msg_id;
	RecvQueue recvMsg;

	msg_id = msgget((key_t)MSG_Q_KEY, IPC_CREAT | 0660);

    if(msg_id == -1) {
		ret = -1;
        perror("msgget fail");
		__LOG(LOG_CRIT, "[IPC][%s:%d] ret:%d", _FILE_, __LINE__, ret);
        return -1;
    }


    while(1) {

        usleep(10000);

        if(m_flagDestroy)
            break;

		//msg_id = msgget((key_t)MSG_Q_KEY, IPC_CREAT | 0666);

		ret = msgrcv(msg_id, &recvMsg, sizeof(recvMsg) - sizeof(long), PMSG_TYPE_IPC, 0);
        if(ret <= 0) {
            perror("msgrcv fail");
			__LOG(LOG_ERR, "[IPC][%s:%d] ret:%d", _FILE_, __LINE__, ret);
            continue;
        }
       __LOG(LOG_INFO, "[IPC][%s:%d] recv data msg_id(%d) byte %d", _FILE_, __LINE__, msg_id, ret);
		ret = parseIpcRecvData(msg_id, recvMsg.data, ret);
        if(ret < 0) {
			__LOG(LOG_ERR, "[IPC][%s:%d] ret:%d", _FILE_, __LINE__, ret);
            continue;
        }
/*
        printf("IPC recv data len %d : ", ret);
        for(i=0;i<ret;i++)
            printf("%02x", msg.data[i]);
        printf("\n");
*/
        //ret = parseRecvData(msg.data, ret);
    };

	__LOG(LOG_NOTICE, "[TCP][%s:%d] ipc thread end", _FILE_, __LINE__);

    return ret;
}

//#include <string>


int IpcClient::parseIpcRecvData(int msgId, char* data, int len)
{
	int ret = 0;
	int i;
	int64_t tmp64;;
	int32_t tmp32;
	
	TOhtData _TOhtData;
	SysTime curTime;
	static SysTime preTime;
	long whour, wsec, wmin, wdiff;
	static long setTime;
	//static uint8_t preStatus = 0;
	//std::string cstr;
	FILE *fp = NULL;
	//static char strBuf[256];
	char strTmp[512];
	struct timeval  tv;
	static _OTIME_STEP otime_stat = OTIME_NULL;
	static _WTIME_STEP wtime_stat = WTIME_NULL;

	//CTCPServer* server = CTCPServer::getInstance() ;
	//SendQueue sendBuf;
	
	if(len > 55) {
		__LOG(LOG_ERR, "[IPC][%s:%d] byte %d > 55 max size over", _FILE_, __LINE__, len);
		return -1;
	}

    //__E(LOG_LEVEL_DBG, "Recv data msg_id(%d) byte %d\n", msgId, len);
	for(i=0;i<len;i++)
        __LOG(LOG_DEBUG, "[IPC][%s:%d] (%d)%02x", _FILE_, __LINE__, i, data[i]);

	memset(_TOhtData.byte, 0, sizeof(_TOhtData.byte));
	memcpy(_TOhtData.byte, data, len);
	_TOhtData.fmt.cmd = htole16(be16toh(_TOhtData.fmt.cmd));

	//for(int i=0;i<len;i++) debug_printf("[%d]%x ", i,oht.byte[i]);
		//debug_printf("\n");
	//debug_printf("start time:%ld curStatus:%d\n",startTime, oht.fmt.ov.curStatus);
	switch(_TOhtData.fmt.cmd)
	{
		case CMD_STATUSINFO_BLACKBOX:
			//if(_TVcmConf.ops_enable == TRUE) break;

			curTime = get_sys_time();
			ret = gettimeofday(&tv, NULL);
			if(ret < 0) {
				__LOG(LOG_ERR, "[IPC][%s:%d] ret:%d", _FILE_, __LINE__, ret);
				break;
			}
			curTime.wMsecond = (tv.tv_usec) / 1000 ;

			switch(otime_stat)
			{
				case OTIME_NULL:
					if(_TOhtData.fmt.ov.curStatus == 0x02) {
						if(wtime_stat == WTIME_NULL) {
							setTime = tv.tv_sec;
							wtime_stat = WTIME_CALL;
							__LOG(LOG_NOTICE, "[OVL][%s:%d] wtime call", _FILE_, __LINE__);
						}
					} else {
						if(wtime_stat != WTIME_NULL) __LOG(LOG_NOTICE, "[OVL][%s:%d] wtime null", _FILE_, __LINE__);
						wtime_stat = WTIME_NULL;
					}
					break;
				case OTIME_CALL:
					setTime = tv.tv_sec;
					otime_stat = OTIME_DURING;
					__LOG(LOG_NOTICE, "[OVL][%s:%d] wtime set", _FILE_, __LINE__);
					break;
				case OTIME_DURING:
					wtime_stat = WTIME_DURING;
					if(tv.tv_sec-setTime > 3600) {
						otime_stat = OTIME_NULL;
						wtime_stat = WTIME_NULL;
						__LOG(LOG_NOTICE, "[OVL][%s:%d] wtime over", _FILE_, __LINE__);
					}
					break;
				default:
					__LOG(LOG_ERR, "[OVL][%s:%d] wtime type unused", _FILE_, __LINE__);
					break;
			}

			switch(wtime_stat)
			{
				case WTIME_CALL:
					wdiff = wsec = tv.tv_sec-setTime; wmin = wsec/60; whour = wmin/60; wmin %= 60; wsec %= 60;
					if(wdiff >= 5) {
						wtime_stat = WTIME_DURING;
						__LOG(LOG_NOTICE, "[OVL][%s:%d] wtime during", _FILE_, __LINE__);
					}
					break;
				case WTIME_DURING:
					wdiff = wsec = tv.tv_sec-setTime; wmin = wsec/60; whour = wmin/60; wmin %= 60; wsec %= 60;
					//__E(LOG_LEVEL_TRA, "%d %d\n", tv.tv_sec, setTime);
					break;
				default:
					wdiff = 0; wmin = 0; whour = 0; wsec = 0;
					break;
			}
			//__E(LOG_LEVEL_TRA, "%d %d %d\n", whour, wmin, wsec);


			//preStatus = oht.fmt.ov.curStatus;
			if(len < 55)
			{
				//oht.fmt.ov.curNodeID = htole32(be32toh(oht.fmt.ov.curNodeID));
			}
			else
			{
				_TOhtData.fmt.ov.curNodeID = htole32(be32toh(_TOhtData.fmt.ov.curNodeID));
				_TOhtData.fmt.ov.tagetNodeID = htole32(be32toh(_TOhtData.fmt.ov.tagetNodeID));

				_TOhtData.fmt.ov.curNodeOffset = htole32(be32toh(_TOhtData.fmt.ov.curNodeOffset));
				tmp64 = htobe64(le64toh(*(int64_t*)&_TOhtData.fmt.ov.drivingSpeed));
				_TOhtData.fmt.ov.drivingSpeed = *(double*)&tmp64;
				_TOhtData.fmt.ov.eout = htole32(be32toh(_TOhtData.fmt.ov.eout));

				_TOhtData.fmt.ov.lout = htole32(be32toh(_TOhtData.fmt.ov.lout));
				tmp32 = htobe32(le32toh(*(int32_t*)&_TOhtData.fmt.ov.fAxis1Torque));
				_TOhtData.fmt.ov.fAxis1Torque = *(float*)&tmp32;
				tmp32 = htobe32(le32toh(*(int32_t*)&_TOhtData.fmt.ov.fAxis2Torque));
				_TOhtData.fmt.ov.fAxis2Torque = *(float*)&tmp32;
				_TOhtData.fmt.ov.error = htole32(be32toh(_TOhtData.fmt.ov.error));
				
				if(_TOhtData.fmt.ov.loutSign != '+' && _TOhtData.fmt.ov.loutSign != '-') _TOhtData.fmt.ov.loutSign = '?';

				_TOhtData.fmt.ov.curMode = ConvertMode(_TOhtData.fmt.ov.curMode);
				_TOhtData.fmt.ov.curStatus = ConvertStatus(_TOhtData.fmt.ov.curStatus);
				//debug_printf("Tick:%ld h:%ld m:%ld s:%ld\n",getTick()-startTime, whour, wmin, wsec);
#if 1

ret = snprintf(sendBuf.data, sizeof(sendBuf.data), "{\n\
\"REP\":\"SET_OVERLAY\",\n\
\"RET\":0,\n\
\"DATA\":{\n\
\"date\":\"%04d-%02d-%02d %02d:%02d:%02d\",\n\
\"name\":\"%s\",\n\
\"mode\":\"%c\",\n\
\"CurStatus\":\"%c\",\n\
\"curNodeID\":%d,\n\
\"TargetNodeID\":%d,\n\
\"CurNodeOffset\":%d,\n\
\"DrivingSpeed\":%.02f,\n\
\"Eout\":%d,\n\
\"lout_sign\":\"%c\",\n\
\"lout\":%.01f,\n\
\"fAxit1Torque\":%.01f,\n\
\"fAxit2Torque\":%.01f,\n\
\"Error\":%d,\n\
\"OHTDetectLevel\":%d,\n\
\"OBSDetectLevel\":%d", \
curTime.wYear, curTime.wMonth, curTime.wDay, curTime.wHour, curTime.wMinute, curTime.wSecond, _TVhlConf.vhl_name, \
_TOhtData.fmt.ov.curMode, _TOhtData.fmt.ov.curStatus, _TOhtData.fmt.ov.curNodeID, _TOhtData.fmt.ov.tagetNodeID, _TOhtData.fmt.ov.curNodeOffset, \
_TOhtData.fmt.ov.drivingSpeed, _TOhtData.fmt.ov.eout, _TOhtData.fmt.ov.loutSign, float(_TOhtData.fmt.ov.lout)/10, _TOhtData.fmt.ov.fAxis1Torque, \
_TOhtData.fmt.ov.fAxis2Torque, _TOhtData.fmt.ov.error, _TOhtData.fmt.ov.ohtDetectLevel, _TOhtData.fmt.ov.obsDetectLevel);

				}

				if(wtime_stat == WTIME_DURING) {
				             char timeBuf[64];
                snprintf(timeBuf, sizeof(timeBuf), ",\n\"WaitingTime\":\"%02ld:%02ld:%02ld\"\n}\n}", whour, wmin, wsec);
				             strncat(sendBuf.data, timeBuf, sizeof(sendBuf.data) - strlen(sendBuf.data) - 1);
            }
				else {
				             strncat(sendBuf.data, "\n}\n}", sizeof(sendBuf.data) - strlen(sendBuf.data) - 1);
            }

			__LOG(LOG_DEBUG, "[IPC][%s:%d] parse data \n%s", _FILE_, __LINE__, sendBuf.data);
			sendBuf.type = PMSG_TYPE_OVERLAY;
#else
			cstr = "{\n\"REP\":\"SET_OVERLAY\",\n\"RET\":0,\n";
			cstr += "\"DATA\":{\n";
			cstr += "\"date\":\"2022-01-04 14:26\",\n";
			cstr += "\"name\":\"VD3003\",\n"; 
			cstr += "\"mode\":" + std::to_string(oht.fmt.ov.curMode) + ",\n";
			cstr += "\"CurStatus\":" + std::to_string(oht.fmt.ov.status) + ",\n";
			cstr += "\"curNodeID\":" + std::to_string(oht.fmt.ov.curNodeID) + ",\n";
			cstr += "\"TargetNodeID\":" + std::to_string(oht.fmt.ov.tagetNodeID) + ",\n";
			cstr += "\"CurNodeOffset\":" + std::to_string(oht.fmt.ov.curNodeOffset) + ",\n";
			cstr += "\"DrivingSpeed\":" + std::to_string(oht.fmt.ov.drivingSpeed) + ",\n";
			cstr += "\"Eout\":" + std::to_string(oht.fmt.ov.eout) + ",\n";
			//cstr += "\"lout_sign\":" + std::to_string(oht.fmt.ov.loutSign) + ",\n";
			cstr += "\"lout_sign\":\"";
			cstr += oht.fmt.ov.loutSign;
			cstr += "\",\n";
			cstr += "\"lout\":" + std::to_string(oht.fmt.ov.lout) + ",\n";
			cstr += "\"fAxit1Torque\":" + std::to_string(oht.fmt.ov.fAxis1Torque) + ",\n";
			cstr += "\"fAxit2Torque\":" + std::to_string(oht.fmt.ov.fAxis2Torque) + ",\n";
			cstr += "\"Error\":" + std::to_string(oht.fmt.ov.error) + ",\n";
			cstr += "\"OHTDetectLevel\":" + std::to_string(oht.fmt.ov.ohtDetectLevel) + ",\n";
			cstr += "\"OBSDetectLevel\":" + std::to_string(oht.fmt.ov.obsDetectLevel) + ",\n";
			cstr += "\"WaitingTime\":\"00:00:00\"\n}\n} ";
			//cstr += "\"WaitingTime\":" + "00:00:00" + ",\n";
			//debug_printf("cstr:%s", cstr.c_str());
			snprintf(str, cstr.length(), "%s", cstr.c_str());
			//debug_printf("%ld %ld\n", strlen(str), cstr.length());
#endif
			//sprintf(str, "{\n\"REP\":\"SET_OVERLAY\",\n\"RET\":0,\n}");
			//sendBuf.data[strlen(sendBuf.data)] = 0;
#if 0
			ret = sprintf(str2, "echo \"%d\n00:00:%02d,%03d --> 00:00:%02d,%03d\n%s\" >> /mnt/%c%c%c%c%c%c_%02d%02d%02d_%02d%02d00-data.srt", \
			curTime.wSecond, curTime.wSecond, msec_f%2? 500:0, msec_f%2? curTime.wSecond+1:curTime.wSecond, msec_f%2? 0:500, str, \
			oht.fmt.machineID[0], oht.fmt.machineID[1], oht.fmt.machineID[2], oht.fmt.machineID[3], oht.fmt.machineID[4], oht.fmt.machineID[5], \
			curTime.wYear, curTime.wMonth, curTime.wDay, curTime.wHour, curTime.wMinute);
			msec_f++;
#endif
			if(1) {
#if 0
				if(preTime.wSecond > curTime.wSecond) {
					preTime.wSecond = 0;
					preTime.wMsecond = 0;
				}
#endif
				pthread_mutex_lock(&g_srtBufMutex);
				ret = snprintf(srtBuf, sizeof(srtBuf),
					"%s, %c, %c, %d/%d(%d), %.02fm/s, %dV, (%c)%.01fA, %.01f%%/%.01f%%, E%d, Level %d, Level %d", \
				_TVhlConf.vhl_name, _TOhtData.fmt.ov.curMode, _TOhtData.fmt.ov.curStatus, _TOhtData.fmt.ov.curNodeID, \
				_TOhtData.fmt.ov.tagetNodeID, _TOhtData.fmt.ov.curNodeOffset, _TOhtData.fmt.ov.drivingSpeed, \
				_TOhtData.fmt.ov.eout, _TOhtData.fmt.ov.loutSign, float(_TOhtData.fmt.ov.lout)/10, _TOhtData.fmt.ov.fAxis1Torque, \
				_TOhtData.fmt.ov.fAxis2Torque, _TOhtData.fmt.ov.error, _TOhtData.fmt.ov.ohtDetectLevel, _TOhtData.fmt.ov.obsDetectLevel);

				if(wtime_stat == WTIME_DURING) {
					int used = ret;
					if(used < 0) used = 0;
					if(used >= (int)sizeof(srtBuf)) used = (int)sizeof(srtBuf) - 1;
					snprintf(srtBuf + used, sizeof(srtBuf) - (size_t)used, ", %02ld:%02ld:%02ld", whour, wmin, wsec);
				}
				pthread_mutex_unlock(&g_srtBufMutex);
#if 0
				ret = sprintf(strTmp, "echo \'%d\n00:00:%02d,%03d --> 00:00:%02d,%03d\n%s\' >> /mnt/%s_%02d%02d%02d_%02d%02d00-data.srt", \
				preTime.wSecond, preTime.wSecond, preTime.wMsecond, curTime.wSecond, curTime.wMsecond, strBuf, _TVhlConf.vhl_name, \
				curTime.wYear, curTime.wMonth, curTime.wDay, curTime.wHour, curTime.wMinute);

				//ret = sprintf(strTmp, "echo \'%d\n00:00:%02d,%03d --> 00:00:%02d,%03d\n%04d-%02d-%02d %02d:%02d:%02d %s\' >> /mnt/%s_%02d%02d%02d_%02d%02d00-data.srt", \
				preTime.wSecond, preTime.wSecond, preTime.wMsecond, curTime.wSecond, curTime.wMsecond, \
				curTime.wYear, curTime.wMonth, curTime.wDay, curTime.wHour, curTime.wMinute, curTime.wSecond, strBuf, _TVhlConf.vhl_name, \
				curTime.wYear, curTime.wMonth, curTime.wDay, curTime.wHour, curTime.wMinute);

				//ret = sprintf(strBuf, "%s, %c, %c, %d/%d(%d), %.10gmm/s, %dmV, (%c)%dmA, %.10g%%/%.10g%%, E%d, Level %d, Level %d ", \
				_TVhlConf.vhl_name, oht.fmt.ov.curMode, oht.fmt.ov.curStatus, oht.fmt.ov.curNodeID, oht.fmt.ov.tagetNodeID, oht.fmt.ov.curNodeOffset, \
				oht.fmt.ov.drivingSpeed, oht.fmt.ov.eout, oht.fmt.ov.loutSign, oht.fmt.ov.lout, oht.fmt.ov.fAxis1Torque, \
				oht.fmt.ov.fAxis2Torque, oht.fmt.ov.error, oht.fmt.ov.ohtDetectLevel, oht.fmt.ov.obsDetectLevel);
				//ret = sprintf(strBuf, "%04d-%02d-%02d %02d:%02d:%02d %s, %c, %c, %d/%d(%d), %.10gmm/s, %dmV, (%c)%dmA, %.10g%%/%.10g%%, E%d, Level %d, Level %d ", \
				curTime.wYear, curTime.wMonth, curTime.wDay, curTime.wHour, curTime.wMinute, curTime.wSecond, _TVhlConf.vhl_name, \
				oht.fmt.ov.curMode, oht.fmt.ov.curStatus, oht.fmt.ov.curNodeID, oht.fmt.ov.tagetNodeID, oht.fmt.ov.curNodeOffset, \
				oht.fmt.ov.drivingSpeed, oht.fmt.ov.eout, oht.fmt.ov.loutSign, oht.fmt.ov.lout, oht.fmt.ov.fAxis1Torque, \
				oht.fmt.ov.fAxis2Torque, oht.fmt.ov.error, oht.fmt.ov.ohtDetectLevel, oht.fmt.ov.obsDetectLevel);

				//memcpy(preoht.byte, oht.byte, strlen(oht.byte));

				ret = system(strTmp);
				__E(LOG_LEVEL_DBG, "%s : ret %d\n", strTmp, ret);
				if(ret != 0) {
					__E(LOG_LEVEL_CRI, "ERROR %d : %s \n", ret, strTmp);
				}
				//__E(LOG_LEVEL_CRI, "%s\n", strTmp);

				memcpy(preTime.byte, curTime.byte, sizeof(SysTime));
#endif
			}
			
			break;
		case CMD_EVENTACK_BLACKBOX:
			//memset(oht.byte,0,sizeof(oht.byte));
			//sprintf(str, "{\"REQ\":\"%s\",\"RET\":%d}", "SET_EVENT_STREAM", ret);
			if(_TOhtData.fmt.ev.eventType == EVT_PRI) {
				ret = snprintf(sendBuf.data, sizeof(sendBuf.data), "{\n\"REQ\":\"%s\"\n}", "SET_EVENT_STREAM");
				//__LOG(LOG_EMERG, "[OSS][%s:%d] recv cmd : event oss", _FILE_, __LINE__);
				__LOG(LOG_DEBUG, "[OSS][%s:%d] \n%s", _FILE_, __LINE__, sendBuf.data);
				sendBuf.type = PMSG_TYPE_OSS;
				otime_stat = OTIME_CALL;
				//server->SendDataForSetFD(PMSG_TYPE_OSS, sendBuf.data, strlen(sendBuf.data));
			}
			break;
		case CMD_ERROR_BLACKBOX:
            __LOG(LOG_INFO, "[ERR][%s:%d] ipc error cmd recive", _FILE_, __LINE__);
            __LOG(LOG_INFO, "[ERR][%s:%d] cam0:%d, cam1:%d cam2:%d, cam3:%d, sd:%d, power:%d, temp:%d, wifi:%d", _FILE_, __LINE__, \
                        _TOhtData.fmt.error.cam0, _TOhtData.fmt.error.cam1, _TOhtData.fmt.error.cam2, _TOhtData.fmt.error.cam3, \
						_TOhtData.fmt.error.sd, _TOhtData.fmt.error.voltage, _TOhtData.fmt.error.temp, _TOhtData.fmt.error.wifi);

			_TVhlErr.cam_ch0_err = _TOhtData.fmt.error.cam0;
			_TVhlErr.cam_ch1_err = _TOhtData.fmt.error.cam1;
			_TVhlErr.cam_ch2_err = _TOhtData.fmt.error.cam2;
			_TVhlErr.cam_ch3_err = _TOhtData.fmt.error.cam3;
			_TVhlErr.sd_err = _TOhtData.fmt.error.sd;
			_TVhlErr.power_current_err = _TOhtData.fmt.error.voltage;
			_TVhlErr.temp_err = _TOhtData.fmt.error.temp;
			_TVhlErr.wifi_err = _TOhtData.fmt.error.wifi;
			break;
		default:
			sendBuf.type = PMSG_TYPE_UNUSED;
			__LOG(LOG_ERR, "[IPC][%s:%d] pmsg type unused", _FILE_, __LINE__);
			ret = -1;
			break;
	}
	
	//__E(LOG_LEVEL_DBG, "sendBuf.type %d\n", sendBuf.type);
	//sendData(oht.byte, len);

	do {

	} while(0);

	//if(fp != NULL) pclose(fp);

	return ret;
}

uint8_t IpcClient::ConvertStatus(uint8_t st)
{
	int ret;

	switch(st)
	{
		case 0x00: ret = 'I'; break;
		case 0x01: ret = 'G'; break;
		case 0x02: ret = 'A'; break;
		case 0x03: ret = 'U'; break;
		case 0x04: ret = 'N'; break;
		case 0x05: ret = 'L'; break;
		case 0x06: ret = 'O'; break;
		case 0x07: ret = 'P'; break;
		case 0x08: ret = 'R'; break;
		case 0x09: ret = 'C'; break;
		case 0x0A: ret = 'V'; break;
		case 0x0B: ret = 'B'; break;
		case 0x0C: ret = 'D'; break;
		case 0x0D: ret = 'Z'; break;
		case 0x0E: ret = 'E'; break;
		case 0x0F: ret = 'F'; break;
		case 0x21: ret = 'T'; break;
		case 0x22: ret = 'H'; break;
		default: ret = '?'; break;
	}

	return ret;
}

uint8_t IpcClient::ConvertMode(uint8_t md)
{
	int ret;

	switch(md)
	{
		case 0x01: ret = 'M'; break;
		case 0x10: ret = 'A'; break;
		default: ret = '?'; break;
	}

	return ret;
}
