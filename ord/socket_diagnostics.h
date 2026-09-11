#ifndef ORD_SOCKET_DIAGNOSTICS_H
#define ORD_SOCKET_DIAGNOSTICS_H

#include <arpa/inet.h>
#include <errno.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>

static inline int ord_bind_socket(
    int socket_fd,
    const struct sockaddr_in *address,
    char *diagnostic,
    size_t diagnostic_size)
{
    int ret = bind(
        socket_fd,
        reinterpret_cast<const struct sockaddr *>(address),
        sizeof(*address));
    if (ret >= 0) {
        if (diagnostic && diagnostic_size > 0)
            diagnostic[0] = '\0';
        return ret;
    }

    const int bind_errno = errno;
    char address_text[INET_ADDRSTRLEN] = "<invalid>";
    if (!inet_ntop(AF_INET, &address->sin_addr, address_text, sizeof(address_text)))
        snprintf(address_text, sizeof(address_text), "<invalid>");
    if (diagnostic && diagnostic_size > 0) {
        snprintf(
            diagnostic,
            diagnostic_size,
            "Server bind failed: address=%s port=%u errno=%d (%s)",
            address_text,
            static_cast<unsigned int>(ntohs(address->sin_port)),
            bind_errno,
            strerror(bind_errno));
    }
    errno = bind_errno;
    return ret;
}

#endif
