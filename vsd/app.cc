#include "app.h"

#include <iostream>
#include <string>
#include <cstring>

#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>

App::App() {
#if 0
    if(config_.Load()==true) {
        if(tcpsvr_.Begin(config_.tcp_port_)==true) {
        }
    } else {
    }
#endif
        if(tcpsvr_.Begin(config_.tcp_port_)==true) {
	}
    WaitCommand();
    tcpsvr_.Stop();
}

void App::WaitCommand(void) {
    int f;
    int len;
    char buffer[4096];
    const char* fifoname = config_.vsd_pipe_.c_str();
    printf("Fifoname : %s\n", fifoname);
#if 0
    unlink(fifoname);
    if(mkfifo(fifoname, 0666) == -1) {
        std::cout << "mkfifo fail" << std::endl;
        return ;
    }
#endif
    f = open(fifoname, O_RDWR);
    if(f < 0) {
        printf("open fail\n");
        return ;
    }    
    while(1) {
        usleep(100000);
        len = read(f, buffer, 4096);
        if(len > 0) {
            buffer[len] = 0;
            std::cout << "recv : " << buffer << std::endl;
            if(std::strcmp(buffer, "quit\n") == 0) {
                break;
            }
        } else {
        }        
    }    
    close(f);
    unlink(fifoname);
}
