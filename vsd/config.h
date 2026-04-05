#ifndef __CONFIG_H__
#define __CONFIG_H__

#include <yaml.h>

#include <string>

class Config {
public:
    Config();
    bool Load(void);

    std::string vsd_pipe_;
    uint16_t tcp_port_;

private:
    enum STATE_VALUE {
        START,
        //ACCEPT_SECTION,
        //ACCEPT_LIST,
        //ACCEPT_VALUES,
        ACCEPT_KEY,
        ACCEPT_VALUE,
        STOP,
        ERROR,
    };
    enum STATE_VALUE state_;
    //int error_;
    std::string key_;
    int ParseEvent(yaml_event_t *event);
};

#endif
