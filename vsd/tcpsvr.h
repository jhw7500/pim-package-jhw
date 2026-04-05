#ifndef __TCPSVR_H__
#define __TCPSVR_H__

#include <thread>


class Tcpsvr {
public:
    Tcpsvr();
    ~Tcpsvr();
    bool Begin(uint16_t port);
    void Stop(void);
private:
    bool run_flag_;
    std::thread thread_;
    int sock_;
    bool update_network_flag_;
    bool reload_configfile_flag_;

    void cmd_get_info(std::string& ans);
};

#endif

