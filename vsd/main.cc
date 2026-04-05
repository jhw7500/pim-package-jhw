#include <iostream>
//#include <sys/time.h>
#include <unistd.h>
#include <fcntl.h>
//#include <sys/ioctl.h>
#include <thread>
//#include <sys/types.h>
#include <sys/stat.h>
#include "app.h"
#include "util.h"


void hex_dump(const void *src, size_t length, size_t line_size, const char *prefix)
{
    int i = 0;
    const unsigned char *address = (const unsigned char *)src;
    const unsigned char *line = address;
    unsigned char c;

    printf("%s | ", prefix);
    while (length-- > 0) {
        printf("%02X ", *address++);
        if (!(++i % line_size) || (length == 0 && i % line_size)) {
            if (length == 0) {
                while (i++ % line_size)
                    printf("__ ");
            }
            printf(" |");
            while (line < address) {
                c = *line++;
                printf("%c", (c < 32 || c > 126) ? '.' : c);
            }
            printf("|\n");
            if (length > 0)
                printf("%s | ", prefix);
        }
    }
}

int main(void) {

    //printf("Init : Version : %s\n", SW_VERSION);
    __LOG(LOG_ALERT, "[SYS][%s:%d] version : %s", _FILE_, __LINE__, SW_VERSION);
    App app;
    return 0;
}
