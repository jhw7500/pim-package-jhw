#ifndef __APP_H__
#define __APP_H__

#include "config.h"
#include "tcpsvr.h"

class App {
public:
    // Run() carries the startup status out to main().  A constructor cannot,
    // and that constructor-only shape is what let a failed Begin() fall
    // through into the command wait loop.
    int Run(void);
    Config config_;

private:
    Tcpsvr tcpsvr_;
    int WaitCommand(void);
};

#endif