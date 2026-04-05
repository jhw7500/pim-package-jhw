#ifndef __APP_H__
#define __APP_H__

#include "config.h"
#include "tcpsvr.h"

class App {
public:
    App();
    Config config_;

private:
    Tcpsvr tcpsvr_;
    void WaitCommand(void);
};

#endif