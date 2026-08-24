#include "loopback_peer_auth.h"

#include <arpa/inet.h>
#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <unistd.h>

int loopback_peer_uid_for_tcp_port(uint16_t host_order_port, uid_t *out_uid) {
    if (out_uid == NULL || host_order_port == 0) {
        return -1;
    }

    // insi_lport is stored in network byte order (same as inp_lport).
    const int port_nbo = (int)htons(host_order_port);

    int list_bytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (list_bytes <= 0) {
        return -1;
    }
    list_bytes += (int)sizeof(pid_t) * 64;
    pid_t *pids = calloc((size_t)list_bytes / sizeof(pid_t) + 1, sizeof(pid_t));
    if (pids == NULL) {
        return -1;
    }
    int got_bytes = proc_listpids(PROC_ALL_PIDS, 0, pids, list_bytes);
    if (got_bytes <= 0) {
        free(pids);
        return -1;
    }
    const int npids = got_bytes / (int)sizeof(pid_t);

    int found = 0;
    uid_t found_uid = 0;

    for (int i = 0; i < npids; i++) {
        const pid_t pid = pids[i];
        if (pid <= 0) {
            continue;
        }

        int fd_bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
        if (fd_bytes <= 0) {
            continue;
        }
        struct proc_fdinfo *fds = malloc((size_t)fd_bytes);
        if (fds == NULL) {
            continue;
        }
        int fd_got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, fd_bytes);
        if (fd_got <= 0) {
            free(fds);
            continue;
        }
        const int nfd = fd_got / (int)sizeof(struct proc_fdinfo);
        for (int j = 0; j < nfd; j++) {
            if (fds[j].proc_fdtype != PROX_FDTYPE_SOCKET) {
                continue;
            }
            struct socket_fdinfo si;
            memset(&si, 0, sizeof(si));
            int si_got = proc_pidfdinfo(pid, fds[j].proc_fd, PROC_PIDFDSOCKETINFO,
                                        &si, (int)sizeof(si));
            if (si_got < (int)sizeof(struct socket_info)) {
                continue;
            }
            if (si.psi.soi_protocol != IPPROTO_TCP) {
                continue;
            }
            if (si.psi.soi_family != AF_INET && si.psi.soi_family != AF_INET6) {
                continue;
            }
            // pri_in and pri_tcp.tcpsi_ini share the same leading in_sockinfo.
            if (si.psi.soi_proto.pri_in.insi_lport != port_nbo) {
                continue;
            }

            struct proc_bsdinfo bsd;
            memset(&bsd, 0, sizeof(bsd));
            if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, (int)sizeof(bsd)) <= 0) {
                free(fds);
                free(pids);
                return -1;
            }
            if (!found) {
                found = 1;
                found_uid = bsd.pbi_uid;
            } else if (found_uid != bsd.pbi_uid) {
                free(fds);
                free(pids);
                return -1;
            }
        }
        free(fds);
    }
    free(pids);

    if (!found) {
        return -1;
    }
    *out_uid = found_uid;
    return 0;
}
