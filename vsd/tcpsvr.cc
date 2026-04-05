#include "tcpsvr.h"
#include "file_search.h"

#include <iostream>
#include <fstream>
#include <string.h>
#include <unistd.h>
//#include <sys/socket.h>
//#include <sys/un.h>
#include <netinet/in.h>
#include <fcntl.h>
#include <jsoncpp/json/json.h>
#include <sys/utsname.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <net/if.h>
#include <chrono>
#include <thread>

#include "encrypt.h"
#include "util.h"

#define UNUSED(x)           (void)(x)
#define EDGECONF_LOCK       "/tmp/edgeconf.lock"
#define EDGECONF_PATH "/root/shared_v/edgeconf_pim.json"

#define PASSWD_LOCK       "/tmp/.passwd.lock"
#define PASSWD_PATH "/root/shared_v/.passwd"

#define PIMERR_NOERR			0
#define PIMERR_CMD_NOT_FOUND	1
#define PIMERR_FAIL				2
#define PIMERR_FILE_NOT_FOUND	3
#define PIMERR_WRITE_FAIL		4
#define PIMERR_READ_FAIL		5
#define PIMERR_INVALID_PACKET	6

static int cmd_get_info(const Json::Value& data, std::string& ans) {
    UNUSED(data);
    ans = "{";
    {
        ans += "\"Version\":";
        std::ifstream ifs("/var/lib/dpkg/status");
        if (ifs.is_open()) {
            bool found = false;
            std::string ver;
            for (std::string line; std::getline(ifs, line);) {
                if(line.find("Package: pim") == 0) {
                    std::cout << line << std::endl;
                    found = true;
                    break;
                }
            }
            if(found==true) {
                found = false;
                for (std::string line; std::getline(ifs, line);) {
                    if(line.find("Version: ") == 0) {
                        std::cout << line << std::endl;
                        found = true;
                        ans += "\"";
                        ans += line.substr(9);
                        ans += "\"";
                        break;
                    }
                }
            }

            if(found==false) {
                ans += "null";    
            }
        } else {
            ans += "null";
        }
    }
    ans += ',';
    {
        ans += "\"Device ID\":";
        int fd = socket(AF_INET, SOCK_DGRAM, 0);
        if(fd < 0) {
            ans += "null";
        } else {
            struct ifreq ifr;
            ifr.ifr_addr.sa_family = AF_INET;
            strncpy(ifr.ifr_name , "wlp1s0" , IFNAMSIZ-1);
            ioctl(fd, SIOCGIFHWADDR, &ifr);
            close(fd);
            char str[16];
            sprintf(str, "%02x%02x%02x%02x%02x%02x",ifr.ifr_hwaddr.sa_data[0],ifr.ifr_hwaddr.sa_data[1],ifr.ifr_hwaddr.sa_data[2],ifr.ifr_hwaddr.sa_data[3],ifr.ifr_hwaddr.sa_data[4],ifr.ifr_hwaddr.sa_data[5]);
            ans += "\"";
            ans += str;
            ans += "\"";
        }
    }
    ans += ',';
    {
        struct utsname buffer;
        ans += "\"kernel version\":";
        if (uname(&buffer) < 0) {
            ans += "null";
        } else {
            ans += "\"";
            ans += buffer.release;
            ans += "\"";
        }
    }
    ans += ',';
    {
        ans += "\"OS version\":";
        std::ifstream ifs("/etc/issue");
        char buf[64];
        if(ifs.is_open()) {
            ifs.getline(buf, 64);
            char *p = strstr(buf, " \\");
            if(p != NULL) {
                *p = 0;
            }
            ans += "\"";
            ans += buf;
            ans += "\"";
        } else {
            ans += "null";
        }
    }
    ans += "}";
    std::cout << ans << std::endl;
    return PIMERR_NOERR;
}

static void json_update(Json::Value& a, const Json::Value& b) {
    if (!a.isObject() || !b.isObject()) return;

    for (const auto& key : b.getMemberNames()) {
        if (a[key].isObject()) {
            json_update(a[key], b[key]);
        } else {
            a[key] = b[key];
        }
    }
}

static bool GetAppConfigPath(std::string &conf_path) {
    std::string json_file = "";
    bool ret=false;
    
    //json_file = EDGECONF_PATH;
    json_file = search_json_file((char*)PATH_JSON, (char*)JSON_NAME_PREFIX, (char*)JSON_NAME_SUFFIX);
    //sprintf(str, "%s/%s*%s", PATH_JSON, JSON_NAME_PREFIX, JSON_NAME_SUFFIX);
    //json_file.find(JSON_NAME_SUFFIX);
    //json_file = search_json_file((char*)PATH_JSON, (char*)JSON_NAME_PREFIX, (char*)JSON_NAME_SUFFIX);
    std::cout << "GLOBAL_EDGECONF_PATH : " << json_file << std::endl;
    if(access(json_file.c_str(),F_OK) == 0){
        conf_path = json_file;
        ret=true;
    }
/*    
    if(access(GLOBAL_EDGECONF_PATH,F_OK) == 0){
        std::ifstream myfile;
        myfile.open(GLOBAL_EDGECONF_PATH);
        if(myfile.is_open())
        {
            getline(myfile,json_file);
            std::cout << "GLOBAL_EDGECONF_PATH : " << json_file << std::endl;
            myfile.close();

            if(access(json_file.c_str(),F_OK) == 0){
                conf_path = json_file;
                ret=true;
            }
        }
    }
*/
    return ret;
}

static int cmd_set_config(const Json::Value& data, std::string& ans) {
    UNUSED(ans);
    int ret = PIMERR_NOERR, retry = 5;
    bool config_adab = false;
    Json::Value config;
    Json::StyledWriter styledWriter;
    std::string prev_json_str, new_json_str;
    std::string json_file = "";    

    if( GetAppConfigPath(json_file) == true) {
        std::string::size_type n;
        n = json_file.find("/edgeconf_");
        if(n == std::string::npos) {
            return PIMERR_FILE_NOT_FOUND;
        }
    }

    while(retry--) {
        int file_desc = open(EDGECONF_LOCK, O_RDWR | O_CREAT | O_EXCL, 0444);
        if (file_desc == -1) {
            std::cout << "File Locked" << std::endl;
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        } else {
            {
                std::ifstream ifs(json_file);
                Json::Reader reader;
                if(reader.parse(ifs, config, false)==false) {
                    std::cout << "Parsing ERROR" << json_file << std::endl;
                    reader.parse("{}", config, false);
                }
                ifs.close();
            }

            prev_json_str = styledWriter.write(config);

            json_update(config, data);

            new_json_str = styledWriter.write(config);

            if(prev_json_str==new_json_str) {
                std::cout << "Same config" << std::endl;
            } else {  
                    if (file_desc == -1) {
                    } else {
                        std::ofstream ofs(json_file);
                        
                        ofs << styledWriter.write(config);
                        ofs.close();
                    }
            }

            close(file_desc);
            unlink(EDGECONF_LOCK);
            break;
        }
    }
    if(retry==0) {
        std::cout << "File Write Fail" << std::endl;
        return PIMERR_WRITE_FAIL;
    }

    if(config_adab==true) {
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-result"
        system("/usr/local/bin/adab reload");
#pragma GCC diagnostic pop 
    }

    return ret;
}

#if 1 /* Pointimage : Added by youstar02 start: 2022/09/18 */
static int cmd_set_password(const Json::Value& data, std::string& ans) {
    UNUSED(ans);
    int ret = PIMERR_NOERR, retry = 5;

	char cmd[1024] = { 0, };

	std::string cur_passwd, new_passwd;
    std::string passwd_file = "";    
	passwd_file = PASSWD_PATH;

	if(access((char *)passwd_file.c_str(), F_OK) != 0)
		return PIMERR_CMD_NOT_FOUND;

    while(retry--) {
        int file_desc = open(PASSWD_LOCK, O_RDWR | O_CREAT | O_EXCL, 0444);
        if (file_desc == -1) {
            std::cout << "File Locked" << std::endl;
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        } 
		else 
		{
			char passwd[MAX_PASSWD_STRING] = { 0, };
			char cur_pw[MAX_PASSWD_STRING] = { 0, };
			char new_pw[MAX_PASSWD_STRING] = { 0, };

			ret = encrypt_get_passwd((char *)passwd_file.c_str(), passwd);
			if(ret < 0)
			{
				std::cout << "failed to get passwd" << std::endl;
				ret = PIMERR_CMD_NOT_FOUND;
				goto err;
			}

			cur_passwd = data["current_pw"].asString();
			printf("get pw : %s(%d), cur pw : %s(%d)\n", passwd, strlen(passwd), (char *)cur_passwd.c_str(), strlen((char *)cur_passwd.c_str()));
			if(memcmp(passwd, (char *)cur_passwd.c_str(), strlen(passwd)) != 0)
			{
				std::cout << "failed to cur passwd" << std::endl;
				ret = PIMERR_CMD_NOT_FOUND;
				goto err;
			}

			new_passwd = data["new_pw"].asString();
			printf("get pw : %s(%d), cur pw : %s(%d), new pw : %s(%d)\n", 
					passwd, strlen(passwd), (char *)cur_passwd.c_str(), strlen((char *)cur_passwd.c_str()), (char *)new_passwd.c_str(), strlen((char *)new_passwd.c_str())  );
			ret = encrypt_change_passwd((char *)passwd_file.c_str(), (char *)cur_passwd.c_str(), (char *)new_passwd.c_str());
			if(ret < 0)
			{
				std::cout << "failed to change passwd" << " ret : " << ret << std::endl;
				ret = PIMERR_CMD_NOT_FOUND;
				goto err;
			}

err:
            close(file_desc);
            unlink(PASSWD_LOCK);
            break;
        }
    }
    if(retry==0) {
        std::cout << "File Write Fail" << std::endl;
        return PIMERR_WRITE_FAIL;
    }

	if(ret == 0)
	{
		//sprintf(cmd, "echo %s:%s | chpasswd", "semes", (char *)new_passwd.c_str());
        sprintf(cmd, "echo %s:%s | chpasswd", "user", (char *)new_passwd.c_str());
		system(cmd);
		sync();
	}

    return ret;
}

static int cmd_init_password(const Json::Value& data, std::string& ans) {
    UNUSED(ans);
    int ret = PIMERR_NOERR, retry = 5;

	char cmd[1024] = { 0, };
	std::string cur_passwd, new_passwd;

    std::string passwd_file = "";    
	passwd_file = PASSWD_PATH;

	if(access((char *)passwd_file.c_str(), F_OK) != 0)
		return PIMERR_CMD_NOT_FOUND;

    while(retry--) {
        int file_desc = open(PASSWD_LOCK, O_RDWR | O_CREAT | O_EXCL, 0444);
        if (file_desc == -1) {
            std::cout << "File Locked" << std::endl;
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        } 
		else 
		{
			char passwd[MAX_PASSWD_STRING] = { 0, };
			char cur_pw[MAX_PASSWD_STRING] = { 0, };
			char new_pw[MAX_PASSWD_STRING] = { 0, };

			ret = encrypt_get_passwd((char *)passwd_file.c_str(), passwd);
			if(ret < 0)
			{
				std::cout << "failed to get passwd" << std::endl;
				ret = PIMERR_CMD_NOT_FOUND;
				goto err;
			}

			//ret = encrypt_change_passwd((char *)passwd_file.c_str(), passwd, "semes");
            ret = encrypt_change_passwd((char *)passwd_file.c_str(), passwd, "user");
			if(ret < 0)
			{
				std::cout << "failed to change passwd" << " ret : " << ret << std::endl;
				ret = PIMERR_CMD_NOT_FOUND;
				goto err;
			}

err:
            close(file_desc);
            unlink(PASSWD_LOCK);
            break;
        }
    }
    if(retry==0) {
        std::cout << "File Write Fail" << std::endl;
        return PIMERR_WRITE_FAIL;
    }

	if(ret == 0)
	{
		//sprintf(cmd, "echo %s:%s | chpasswd", "semes", "semes");
        sprintf(cmd, "echo %s:%s | chpasswd", "user", "user");
		system(cmd);
		sync();
	}

    return ret;
}
#endif /* Pointimage : Added by youstar02 end  : 2022/09/18 */

#include <sstream>

static int cmd_get_config(const Json::Value& data, std::string& ans) {
    UNUSED(data);
    std::string json_file = "";
    if( GetAppConfigPath(json_file) == false) {
        std::cout << "CONF JSON PATH ERROR" << std::endl;
        return PIMERR_FILE_NOT_FOUND;
    }

    Json::Value config;
    {
        std::ifstream ifs(json_file);
        Json::Reader reader;
        if(reader.parse(ifs, config, false)==false) {
            std::cout << "CONF JSON PARSE ERROR" << std::endl;
            return PIMERR_READ_FAIL;
        }
        ifs.close();
    }
    Json::StreamWriterBuilder builder;
    builder["commentStyle"] = "None";
    builder["indentation"] = "";
    std::unique_ptr<Json::StreamWriter> writer(builder.newStreamWriter());
    std::stringstream ss;
    writer->write(config, &ss);
    ans = ss.str();
    std::cout << ans << std::endl;
    return PIMERR_NOERR;
}

static int cmd_get_some_config(const Json::Value& data, std::string& ans) {
    std::string json_file = "";
    if( GetAppConfigPath(json_file) == false) {
        std::cout << "ERROR" << std::endl;
        return PIMERR_FILE_NOT_FOUND;
    }

    Json::Value config;
    {
        std::ifstream ifs(json_file);
        Json::Reader reader;
        if(reader.parse(ifs, config, false)==false) {
            std::cout << "ERROR" << std::endl;
            return PIMERR_READ_FAIL;
        }
        ifs.close();
    }

    if(!data.isString()) {
        std::cout << "ERROR" << std::endl;
        return PIMERR_INVALID_PACKET;
    }

    std::string str_path = data.asString();
	Json::Value rd_value = Json::Path(str_path).resolve(config, Json::ValueType::nullValue);
    if(rd_value.isNull()) {
        std::cout << "ERROR" << std::endl;
        return PIMERR_FAIL;
    }

    Json::StreamWriterBuilder builder;
    builder["commentStyle"] = "None";
    builder["indentation"] = "";
    std::unique_ptr<Json::StreamWriter> writer(builder.newStreamWriter());
    std::stringstream ss;
    writer->write(rd_value, &ss);
    ans = ss.str();
    std::cout << ans << std::endl;
    return PIMERR_NOERR;
}


#include <sstream>

static std::string __progress_string="{}";
static int __update_state=0;

static int cmd_update(const Json::Value& data, std::string& ans) {
    UNUSED(ans);
    int ret = PIMERR_NOERR;
    std::string cls = data["CLASS"].asString();
    std::string filename = data["FILENAME"].asString();

    std::cout << "cmd_update" << cls << ", " << filename << std::endl;

    __progress_string="{}";
    __update_state = 1;

    std::thread thr = std::thread([filename](){
        FILE *fp;
#define MAXLINE         (512)
        char buff[MAXLINE];
        std::string exec = "/opt/pim/bin/fwdriver upgrade /shared/";
        exec += filename;
        fp = popen(exec.c_str(), "r");
        if(fp==NULL) {
            __update_state = 0;
            return;
        }
//        std::cout << "TEST" << std::endl;
        while(fgets(buff, MAXLINE, fp) != NULL) {
            Json::Reader reader;
            Json::Value root;
            if(reader.parse(buff, root)==true) {
                std::cout << buff << std::flush;
                __progress_string = buff;
            }else if(strncmp(buff,"ERROR:",strlen("ERROR:")) == 0) {
                __update_state = 0;
                std::cout << buff << std::flush;
                break;
            }
            else {
                std::cout << "JSON ERROR:" << buff << std::flush;
            }
        }
        int state = pclose(fp);
        printf("state is %d\n", state);
    });
    thr.detach();
    return ret;
}

static int cmd_get_update_status(const Json::Value& data, std::string& ans) {
    int ret=0;
    UNUSED(data);

    if(__update_state == 0) {
        ret = PIMERR_FAIL;
        ans = "{}";
    }else {
        ret = PIMERR_NOERR;
        ans = __progress_string;
    }

    return ret;
}

static int cmd_reset(const Json::Value& data, std::string& ans) {
    UNUSED(data);
    UNUSED(ans);
    std::thread thr = std::thread([](){
        std::this_thread::sleep_for(std::chrono::milliseconds(1000));
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-result"         
        system("reboot");
#pragma GCC diagnostic pop        
    });
    thr.detach();
    return PIMERR_NOERR;
}

static int cmd_strg_clear(const Json::Value& data, std::string& ans) {
    //std::cout <<"echo storage clear!!!" << std::endl;
    UNUSED(data);
    UNUSED(ans);
    std::thread thr = std::thread([](){
        std::this_thread::sleep_for(std::chrono::milliseconds(1000));
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-result"         
        system("rm -f /mnt/*.*");
#pragma GCC diagnostic pop        
    });
    thr.detach();
    return PIMERR_NOERR;

}

static int cmd_event_strg_clear(const Json::Value& data, std::string& ans) {
    //std::cout <<"echo event storage clear!!!" << std::endl;
    UNUSED(data);
    UNUSED(ans);
    std::thread thr = std::thread([](){
        std::this_thread::sleep_for(std::chrono::milliseconds(1000));
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-result"         
        system("rm -f /mnt/event/*.*");
#pragma GCC diagnostic pop        
    });
    thr.detach();
    return PIMERR_NOERR;

}


static int cmd_clean_shared(const Json::Value& data, std::string& ans) {
    UNUSED(ans);
    //std::cout << "cmd_clean_shared " << std::endl;
    std::string prefix="";
    std::string postfix="";

    if(data["PREFIX"].isString()) prefix = data["PREFIX"].asString();
    if(data["POSTFIX"].isString()) postfix = data["POSTFIX"].asString();

    CSearchFile seacher;
    FILE_LIST item_list;
    if(seacher.SearchFileList(item_list, "/shared", prefix, postfix) != 0)
        seacher.RemoveFileList(item_list);
    return PIMERR_NOERR;
}

static int cmd_upload_config(const Json::Value& data, std::string& ans) {
    UNUSED(ans);
    //std::cout << "cmd_upload_config" << std::endl;

    int ret=PIMERR_NOERR;
    std::string fpath     = "/shared/";
    std::string new_fpath = "/root/shared_v/";
    if(data["FNAME"].isString()) {
        fpath     += data["FNAME"].asString();
        new_fpath += data["FNAME"].asString();
    } else
        return PIMERR_INVALID_PACKET;

    if(access(fpath.c_str(),F_OK) != 0) return PIMERR_FILE_NOT_FOUND;   /* 파일이 존재하는지 확인 */
    if(chmod(fpath.c_str(), 0755) < 0) return PIMERR_FAIL;    /* 파일 권한 바꾸기 */
    if(chown(fpath.c_str(), 0, 0) < 0) return PIMERR_FAIL;    /* 파일 소유자 바꾸기 */

    //std::cout << "fpath : "<< fpath << std::endl;
    CSearchFile seacher;
    FILE_LIST item_list;
    if(seacher.SearchFileList(item_list, "/root/shared_v", "edgeconf_", ".json") != 0) /* 존재하는 conf file 삭제 */
        seacher.RemoveFileList(item_list);
    rename(fpath.c_str(), new_fpath.c_str());       /* 파일 이동 */

    return ret;
}

static int cmd_download_config(const Json::Value& data, std::string& ans) {
    UNUSED(data);
    //std::cout << "cmd_download_config " << std::endl;
    CSearchFile seacher;
    FILE_LIST item_list;
    if(seacher.SearchFileList(item_list, "/root/shared_v", "edgeconf_", ".json") != 1) /* 존재하는 conf file 확인 */
        return PIMERR_FILE_NOT_FOUND;
    std::string fpath = item_list.begin()->first;
    std::string fname = fpath.substr(fpath.find_last_of('/')+1);
    std::string new_fpath = "/shared/"+fname;

    {
        std::ifstream src(fpath.c_str(), std::ios::binary);
        std::ofstream dst(new_fpath.c_str(),std::ios::binary);
        dst << src.rdbuf();

        src.close();
        dst.close();
    }

    if(chmod(new_fpath.c_str(), 0755) < 0) return PIMERR_FAIL;    /* 파일 권한 바꾸기 */
    if(chown(new_fpath.c_str(), 0, 0) < 0) return PIMERR_FAIL;    /* 파일 소유자 바꾸기 */

    ans = "{\"FNAME\":\""+fname+"\"}";
    return PIMERR_NOERR;
}

static const struct {
    char cmd[32];
    int (*func)(const Json::Value&, std::string&);
}CMDS[] = {
    {"GET_INFO", cmd_get_info},
    {"SET_CONFIG", cmd_set_config},
    {"GET_CONFIG", cmd_get_config},
    {"GET_SOME_CONFIG", cmd_get_some_config},
    {"UPDATE", cmd_update},
    {"GET_UPDATE_STATUS", cmd_get_update_status},
    {"SET_RESET", cmd_reset},
    {"SET_STRG_CLEAR", cmd_strg_clear},
    {"SET_EVENT_STRG_CLEAR", cmd_event_strg_clear},
    {"CLEAN_SHARED", cmd_clean_shared},
    {"UPLOAD_CONFIG", cmd_upload_config},
    {"DOWNLOAD_CONFIG", cmd_download_config},
    {"SET_PASSWORD", cmd_set_password},
    {"INIT_PASSWORD", cmd_init_password},
    {"", NULL}
};

Tcpsvr::Tcpsvr() {
    run_flag_ = false;
    sock_ = -1;
    update_network_flag_ = false;
    reload_configfile_flag_ = false;
}

Tcpsvr::~Tcpsvr() {
}

bool Tcpsvr::Begin(uint16_t port) {

    unlink(EDGECONF_LOCK);

    if ((sock_ = socket(AF_INET, SOCK_STREAM, 0)) == -1) {
        std::cout << "can't create socket" << std::endl;
        return false;
    }

    std::cout << "sock_ : " << sock_ << ", port : " << (int)port << std::endl;

    struct sockaddr_in svr_addr;
    svr_addr.sin_family = AF_INET;
    svr_addr.sin_port = htons(port);
    svr_addr.sin_addr.s_addr = INADDR_ANY;
    memset(&(svr_addr.sin_zero), 0, 8);

    int opt = 1;
    setsockopt(sock_, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt)); 
    if (bind(sock_, (struct sockaddr *)&svr_addr, sizeof(struct sockaddr)) == -1) {
        std::cout << "bind error" << std::endl;
        close(sock_);
        return false;
    }

    if (listen(sock_, 1) == -1) {
        std::cout << "listen error" << std::endl;
        close(sock_);
        return false;
    }

    std::cout << "after accept" << std::endl;

    run_flag_ = true;
    thread_ = std::thread([this](){
        int n;
        char buf[5120];
        struct sockaddr_in client_addr;
        int client = -1, new_client = -1;
        unsigned int sin_size;
        fcntl(sock_, F_SETFL, O_NONBLOCK);
        while(run_flag_) {
            if ((new_client = accept(sock_, (struct sockaddr *)&client_addr, &sin_size)) != -1) {
                std::cout << "connected : " << new_client << std::endl;
                if(client != -1) {
                    close(client);
                }
                client = new_client;
                fcntl(client, F_SETFL, O_NONBLOCK);
            }

            if(client != -1) {
                n = recv(client, buf, sizeof(buf), 0);
                if(n==-1) {
                    switch(errno) {
                        break;
                    case EAGAIN:
                        break;
                    case ECONNRESET:
                        std::cout << "Connection reset by peer" << std::endl;
                        break;
                    default :
                        std::cout << "recv returns -1. errno=" << errno <<  std::endl;
                        break;
                    }
                } else if(n==0) {
                    std::cout << "connection closed : " << client << std::endl;
                    close(client);
                    client = -1;

                    if(update_network_flag_ == true) {
                        update_network_flag_ = false;
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-result"         
                        system("python3 /opt/cis/bin/update_network.py");
#pragma GCC diagnostic pop                         
                    }

                    if(reload_configfile_flag_ == true) {
                        reload_configfile_flag_ = false;
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-result"
                        system("python3 /opt/pim/bin/init.py");
                        system("python3 /opt/cis/bin/update_network.py");
#pragma GCC diagnostic pop
                    }
                } else {
                    Json::Reader reader;
                    Json::Value root;
                    std::cout << "received : " << n << std::endl;
                    buf[n] = 0;
                    std::cout << buf << std::endl;
                    if(reader.parse(buf, buf+n, root)==true) {
#if 0
                        for(auto iter=root.begin();iter != root.end();iter++) {
                            std::cout << iter.key() << std::endl;
                        }
#endif
                        std::string cmd = root["REQ"].asString();
                        std::string ans = "{}";
                        int ret = PIMERR_CMD_NOT_FOUND;
                        for(int i=0 ; CMDS[i].func != NULL ; i++) {
                            if(cmd == CMDS[i].cmd) {
                                ret = CMDS[i].func(root["DATA"], ans);
                                if(ret == PIMERR_NOERR) {
                                    if(cmd == "SET_CONFIG") {
                                        if(root["DATA"].isMember("NETWORK")==true) {
                                            update_network_flag_ = true;
                                        }
                                    }else if(cmd == "UPLOAD_CONFIG") {
                                        reload_configfile_flag_ = true;
                                    }
                                }
                                break;
                            }
                        }
                        sprintf(buf, "{\"REP\":\"%s\",\"RET\":%d,\"DATA\":%s}", cmd.c_str(), ret, ans.c_str());
                        send(client, buf, strlen(buf), 0);
                    } else {
                        std::cout << "JSON Parsing Error" << std::endl;
                    }
                }
            }

            std::this_thread::sleep_for(std::chrono::milliseconds(30));
        }
    });
    return true;
}

void Tcpsvr::Stop(void) {
    std::cout << "Tcpsvr::Stop()" << std::endl;
    if(run_flag_==true) { 
        run_flag_ = false;
        thread_.join();
        std::cout << "Tcpsvr::Stop() : run_flag_ = true, sock_ " << sock_ << std::endl;
        close(sock_);
    }
}
