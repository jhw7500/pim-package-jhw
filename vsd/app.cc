#include "app.h"
#include "util.h"

#include <iostream>
#include <string>
#include <cstring>
#include <cerrno>
#include <cstdlib>

#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>

// A failed start must not look like a clean stop.  Begin() already returned
// false on a socket, bind or listen failure, but the caller tested it with an
// empty if-body and entered WaitCommand() anyway.  rc.local creates
// /var/run/vsd.pipe with touch, not mkfifo, so read() on that plain file
// returns 0 at EOF and the wait loop spun at 10 Hz forever - systemd kept the
// unit active with no TCP listener and no exit status ever appeared.
int App::Run(void) {
#if 0
    if(config_.Load()==true) {
        if(tcpsvr_.Begin(config_.tcp_port_)==true) {
        }
    } else {
    }
#endif
    if(tcpsvr_.Begin(config_.tcp_port_)==false) {
        __LOG(LOG_ALERT, "[SYS][%s:%d] startup aborted: tcp server begin failed on port %u",
              _FILE_, __LINE__, (unsigned)config_.tcp_port_);
        return EXIT_FAILURE;
    }

    int status = WaitCommand();
    tcpsvr_.Stop();

    return status;
}

int App::WaitCommand(void) {
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
        int open_errno = errno;
        __LOG(LOG_ALERT, "[SYS][%s:%d] cannot open command pipe %s - %s",
              _FILE_, __LINE__, fifoname, strerror(open_errno));
        return EXIT_FAILURE;
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

    return EXIT_SUCCESS;
}
