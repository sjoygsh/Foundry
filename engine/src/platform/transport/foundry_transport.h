/*
 * The C seam under `platform`'s authenticated transport (M16 Step 2).
 *
 * Two small translation units sit behind this header and nothing above
 * `platform` can include it:
 *
 *   socket.c  nonblocking IPv4 TCP over the target's own socket API — BSD
 *             sockets on macOS and Linux, Winsock 2 on Windows — compiled
 *             against that target's headers, so no layout or constant is
 *             transcribed by hand.
 *   tls.c     the qualified Mbed TLS 3.6.7 configuration: credentials,
 *             sessions, bounded allocation and the certificate clock.
 *
 * Zig owns everything with a lifetime a caller can see — handles, the stream
 * state machine, carriers and error mapping (`../transport.zig`). This layer
 * owns only what needs the platform's or the provider's C declarations.
 *
 * Only fixed-width integers, byte pointers and opaque pointers cross it. No
 * provider type, secret or raw socket leaves `platform` (ADR-0045).
 */
#ifndef FOUNDRY_TRANSPORT_H
#define FOUNDRY_TRANSPORT_H

#include <stddef.h>
#include <stdint.h>

/* ---- Native sockets --------------------------------------------------- */

/* A POSIX descriptor or a Windows SOCKET, widened so one type fits both. */
typedef uint64_t foundry_socket;
#define FOUNDRY_SOCKET_INVALID UINT64_MAX

/* Results. Byte counts are non-negative; everything else is one of these. */
#define FOUNDRY_SOCKET_OK 0
#define FOUNDRY_SOCKET_WOULD_BLOCK (-1)
#define FOUNDRY_SOCKET_IN_PROGRESS (-2)
#define FOUNDRY_SOCKET_RESET (-3)
#define FOUNDRY_SOCKET_REFUSED (-4)
#define FOUNDRY_SOCKET_ADDRESS_IN_USE (-5)
#define FOUNDRY_SOCKET_ADDRESS_UNAVAILABLE (-6)
#define FOUNDRY_SOCKET_UNREACHABLE (-7)
#define FOUNDRY_SOCKET_TIMED_OUT (-8)
#define FOUNDRY_SOCKET_PERMISSION (-9)
#define FOUNDRY_SOCKET_RESOURCES (-10)
#define FOUNDRY_SOCKET_NETWORK_DOWN (-11)
#define FOUNDRY_SOCKET_FAILED (-12)

/* Process-wide socket library start and stop; Winsock's reference count. */
int foundry_socket_startup(void);
void foundry_socket_cleanup(void);

/* Opens a nonblocking listener. `port` zero asks the OS for one; the bound port is
 * written to `out_port` either way. */
int foundry_socket_listen(
    const uint8_t address[4],
    uint16_t port,
    int backlog,
    foundry_socket *out_socket,
    uint16_t *out_port);

/* Accepts one pending connection without waiting. */
int foundry_socket_accept(
    foundry_socket listener,
    foundry_socket *out_socket,
    uint8_t out_address[4],
    uint16_t *out_port);

/* Starts a nonblocking connect: OK, IN_PROGRESS or a failure. On failure no socket
 * is left open. */
int foundry_socket_connect(const uint8_t address[4], uint16_t port, foundry_socket *out_socket);

/* Whether a connect has finished, without waiting: OK, IN_PROGRESS or its failure. */
int foundry_socket_connect_result(foundry_socket socket);

/* At most `length` bytes; a count, WOULD_BLOCK, RESET or a failure. Never SIGPIPE. */
int64_t foundry_socket_send(foundry_socket socket, const uint8_t *bytes, size_t length);

/* At most `capacity` bytes; a positive count, 0 at an orderly end of stream,
 * WOULD_BLOCK, RESET or a failure. */
int64_t foundry_socket_receive(foundry_socket socket, uint8_t *bytes, size_t capacity);

void foundry_socket_close(foundry_socket socket);

/* ---- TLS 1.3 ------------------------------------------------------------ */

typedef struct foundry_tls_credentials foundry_tls_credentials;
typedef struct foundry_tls_session foundry_tls_session;

#define FOUNDRY_TLS_ROLE_SERVER 1
#define FOUNDRY_TLS_ROLE_CLIENT 2

#define FOUNDRY_TLS_KEY_BYTES 32

/* The carrier a session reads and writes ciphertext through. Each returns a
 * positive byte count or one of these. */
#define FOUNDRY_TLS_IO_WOULD_BLOCK (-1)
#define FOUNDRY_TLS_IO_EOF (-2)
#define FOUNDRY_TLS_IO_RESET (-3)
#define FOUNDRY_TLS_IO_FAILED (-4)
typedef int (*foundry_tls_send_fn)(void *carrier, const uint8_t *bytes, size_t length);
typedef int (*foundry_tls_receive_fn)(void *carrier, uint8_t *bytes, size_t capacity);

/* Session results. */
#define FOUNDRY_TLS_DONE 0
#define FOUNDRY_TLS_WANT_READ 1
#define FOUNDRY_TLS_WANT_WRITE 2
#define FOUNDRY_TLS_CLOSED 3
#define FOUNDRY_TLS_FAILED_CERTIFICATE (-1)
#define FOUNDRY_TLS_FAILED_SERVER_KEY (-2)
#define FOUNDRY_TLS_FAILED_CHAIN_LENGTH (-3)
#define FOUNDRY_TLS_FAILED_PEER_ALERT (-4)
#define FOUNDRY_TLS_FAILED_PROTOCOL (-5)
#define FOUNDRY_TLS_FAILED_CARRIER_EOF (-6)
#define FOUNDRY_TLS_FAILED_CARRIER_RESET (-7)
#define FOUNDRY_TLS_FAILED_CARRIER (-8)
#define FOUNDRY_TLS_FAILED_MEMORY (-9)
#define FOUNDRY_TLS_FAILED_CLOCK (-10)
#define FOUNDRY_TLS_FAILED_INTERNAL (-11)

/* Credential results. */
#define FOUNDRY_TLS_CREDENTIALS_OK 0
#define FOUNDRY_TLS_CREDENTIALS_INVALID_ARGUMENT (-1)
#define FOUNDRY_TLS_CREDENTIALS_INVALID_TRUST (-2)
#define FOUNDRY_TLS_CREDENTIALS_INVALID_CERTIFICATE (-3)
#define FOUNDRY_TLS_CREDENTIALS_INVALID_KEY (-4)
#define FOUNDRY_TLS_CREDENTIALS_KEY_MISMATCH (-5)
#define FOUNDRY_TLS_CREDENTIALS_UNSUPPORTED_KEY (-6)
#define FOUNDRY_TLS_CREDENTIALS_WRONG_USAGE (-7)
#define FOUNDRY_TLS_CREDENTIALS_MEMORY (-8)
#define FOUNDRY_TLS_CREDENTIALS_ENTROPY (-9)
#define FOUNDRY_TLS_CREDENTIALS_UNAVAILABLE (-10)

/* The process-wide provider: allocation hooks, PSA crypto and the certificate
 * clock. Reference counted; the first acquirer's allocation limit governs until
 * the last release. Returns 0, or FOUNDRY_TLS_CREDENTIALS_ENTROPY when the
 * provider cannot seed itself from the OS. One owning thread (ADR-0045). */
int foundry_tls_runtime_acquire(size_t allocation_limit);
void foundry_tls_runtime_release(void);
size_t foundry_tls_allocated_bytes(void);
size_t foundry_tls_allocation_peak(void);

typedef struct foundry_tls_credential_source {
    int role;
    const uint8_t *trust;
    size_t trust_length;
    const uint8_t *certificate;
    size_t certificate_length;
    const uint8_t *private_key;
    size_t private_key_length;
    /* Client only: the separately granted server identity, and its pinned key. */
    const uint8_t *server_name;
    size_t server_name_length;
    const uint8_t *server_key;
} foundry_tls_credential_source;

int foundry_tls_credentials_create(
    const foundry_tls_credential_source *source,
    foundry_tls_credentials **out_credentials);
void foundry_tls_credentials_destroy(foundry_tls_credentials *credentials);

/* `fixed_time` is 0 for the OS civil clock, or seconds since the Unix epoch
 * for a deterministic proof. */
int foundry_tls_session_create(
    foundry_tls_credentials *credentials,
    int64_t fixed_time,
    void *carrier,
    foundry_tls_send_fn send,
    foundry_tls_receive_fn receive,
    foundry_tls_session **out_session);
void foundry_tls_session_destroy(foundry_tls_session *session);

/* One provider handshake call. `out_progressed` is set when ciphertext moved. */
int foundry_tls_session_handshake(foundry_tls_session *session, int *out_progressed);

/* One record's worth of plaintext at most. DONE with a length, WANT_READ,
 * WANT_WRITE, CLOSED on the peer's close_notify, or a failure. */
int foundry_tls_session_read(
    foundry_tls_session *session,
    uint8_t *bytes,
    size_t capacity,
    size_t *out_length);

/* Mbed TLS's write contract: after WANT_WRITE, call again with the same bytes. */
int foundry_tls_session_write(
    foundry_tls_session *session,
    const uint8_t *bytes,
    size_t length,
    size_t *out_length);

/* One nonblocking close_notify attempt; the result is advisory. */
void foundry_tls_session_close_notify(foundry_tls_session *session);

/* The largest plaintext one write can carry. */
size_t foundry_tls_session_max_write(const foundry_tls_session *session);

/* After FOUNDRY_TLS_FAILED_CERTIFICATE: the first applicable of these, so provider
 * verification flags never cross this seam. */
#define FOUNDRY_TLS_CERTIFICATE_REJECTED 0
#define FOUNDRY_TLS_CERTIFICATE_MISSING 1
#define FOUNDRY_TLS_CERTIFICATE_UNTRUSTED 2
#define FOUNDRY_TLS_CERTIFICATE_EXPIRED 3
#define FOUNDRY_TLS_CERTIFICATE_NOT_YET_VALID 4
#define FOUNDRY_TLS_CERTIFICATE_WRONG_USAGE 5
#define FOUNDRY_TLS_CERTIFICATE_WRONG_NAME 6
int foundry_tls_session_certificate_problem(const foundry_tls_session *session);

/* SHA-256 of the verified peer's SubjectPublicKeyInfo; 0 on success. */
int foundry_tls_session_peer_key(const foundry_tls_session *session, uint8_t out_key[FOUNDRY_TLS_KEY_BYTES]);

#endif /* FOUNDRY_TRANSPORT_H */
