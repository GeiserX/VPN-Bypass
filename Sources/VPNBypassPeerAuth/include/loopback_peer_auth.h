#ifndef LOOPBACK_PEER_AUTH_H
#define LOOPBACK_PEER_AUTH_H

#include <sys/types.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Look up the uid that currently owns a loopback TCP socket whose local
// port is `host_order_port` (the client's ephemeral source port).
//
// Only sockets whose local address is 127.0.0.1 or ::1 count. A same
// port on en0 / another interface must not be treated as the client.
// `host_order_foreign_port` is the listener port on the far side of
// that connection; pass 0 to skip the foreign-port filter (listen
// sockets used by tests).
//
// Returns 0 and writes *out_uid when exactly one uid is found.
// Returns -1 (fail closed) when the port is unused, the lookup fails, or
// two different uids appear to own the same port.
int loopback_peer_uid_for_tcp_port(uint16_t host_order_port,
                                   uint16_t host_order_foreign_port,
                                   uid_t *out_uid);

#ifdef __cplusplus
}
#endif

#endif
