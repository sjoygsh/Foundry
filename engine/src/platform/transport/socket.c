/*
 * Nonblocking IPv4 TCP for `platform`'s transport (M16 Step 2).
 *
 * Why C: Zig 0.16's `std.Io.net` blocks — it has no would-block result and a
 * connect with a timeout is an unimplemented panic — and `std.os.windows.ws2_32`
 * declares no Winsock function at all. Compiling this file against each target's
 * own headers means no socket layout, flag or error number is transcribed by
 * hand. Nothing here waits: readiness is a zero-timeout poll or select, and no
 * call ever blocks the owning thread.
 */

#if !defined(_WIN32)
#define _POSIX_C_SOURCE 200809L
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif
#endif

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

#include <limits.h>
#include <string.h>

#include "foundry_transport.h"

#if defined(_WIN32)

#ifndef WSA_FLAG_NO_HANDLE_INHERIT
#define WSA_FLAG_NO_HANDLE_INHERIT 0x80
#endif

typedef SOCKET native_socket;
#define NATIVE_INVALID INVALID_SOCKET

static int last_error(void) { return WSAGetLastError(); }

static int map_error(int error)
{
    switch (error) {
    case WSAEWOULDBLOCK:
    case WSAEINTR:
        return FOUNDRY_SOCKET_WOULD_BLOCK;
    case WSAEINPROGRESS:
    case WSAEALREADY:
        return FOUNDRY_SOCKET_IN_PROGRESS;
    case WSAECONNRESET:
    case WSAECONNABORTED:
    case WSAENETRESET:
    case WSAESHUTDOWN:
    case WSAENOTCONN:
        return FOUNDRY_SOCKET_RESET;
    case WSAECONNREFUSED:
        return FOUNDRY_SOCKET_REFUSED;
    case WSAEADDRINUSE:
        return FOUNDRY_SOCKET_ADDRESS_IN_USE;
    case WSAEADDRNOTAVAIL:
        return FOUNDRY_SOCKET_ADDRESS_UNAVAILABLE;
    case WSAENETUNREACH:
    case WSAEHOSTUNREACH:
        return FOUNDRY_SOCKET_UNREACHABLE;
    case WSAETIMEDOUT:
        return FOUNDRY_SOCKET_TIMED_OUT;
    case WSAEACCES:
        return FOUNDRY_SOCKET_PERMISSION;
    case WSAEMFILE:
    case WSAENOBUFS:
        return FOUNDRY_SOCKET_RESOURCES;
    case WSAENETDOWN:
    case WSANOTINITIALISED:
    case WSASYSNOTREADY:
        return FOUNDRY_SOCKET_NETWORK_DOWN;
    default:
        return FOUNDRY_SOCKET_FAILED;
    }
}

static void close_native(native_socket socket_handle) { closesocket(socket_handle); }

static native_socket open_native(void)
{
    return WSASocketW(
        AF_INET,
        SOCK_STREAM,
        IPPROTO_TCP,
        NULL,
        0,
        WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT);
}

static int make_nonblocking(native_socket socket_handle)
{
    u_long enabled = 1;
    if (ioctlsocket(socket_handle, FIONBIO, &enabled) != 0) {
        return map_error(last_error());
    }
    /* Accepted sockets are not created by `open_native`; keep them out of child
     * processes too. */
    SetHandleInformation((HANDLE) socket_handle, HANDLE_FLAG_INHERIT, 0);
    return FOUNDRY_SOCKET_OK;
}

#else

typedef int native_socket;
#define NATIVE_INVALID (-1)

static int last_error(void) { return errno; }

static int map_error(int error)
{
    if (error == EAGAIN || error == EWOULDBLOCK || error == EINTR) {
        return FOUNDRY_SOCKET_WOULD_BLOCK;
    }
    switch (error) {
    case EINPROGRESS:
    case EALREADY:
        return FOUNDRY_SOCKET_IN_PROGRESS;
    case ECONNRESET:
    case ECONNABORTED:
    case EPIPE:
    case ENOTCONN:
    case ENETRESET:
        return FOUNDRY_SOCKET_RESET;
    case ECONNREFUSED:
        return FOUNDRY_SOCKET_REFUSED;
    case EADDRINUSE:
        return FOUNDRY_SOCKET_ADDRESS_IN_USE;
    case EADDRNOTAVAIL:
        return FOUNDRY_SOCKET_ADDRESS_UNAVAILABLE;
    case ENETUNREACH:
    case EHOSTUNREACH:
        return FOUNDRY_SOCKET_UNREACHABLE;
    case ETIMEDOUT:
        return FOUNDRY_SOCKET_TIMED_OUT;
    case EACCES:
    case EPERM:
        return FOUNDRY_SOCKET_PERMISSION;
    case EMFILE:
    case ENFILE:
    case ENOBUFS:
    case ENOMEM:
        return FOUNDRY_SOCKET_RESOURCES;
    case ENETDOWN:
        return FOUNDRY_SOCKET_NETWORK_DOWN;
    default:
        return FOUNDRY_SOCKET_FAILED;
    }
}

static void close_native(native_socket socket_handle) { close(socket_handle); }

static native_socket open_native(void) { return socket(AF_INET, SOCK_STREAM, IPPROTO_TCP); }

static int make_nonblocking(native_socket socket_handle)
{
    int flags = fcntl(socket_handle, F_GETFL, 0);
    if (flags < 0 || fcntl(socket_handle, F_SETFL, flags | O_NONBLOCK) != 0) {
        return map_error(last_error());
    }
    flags = fcntl(socket_handle, F_GETFD, 0);
    if (flags < 0 || fcntl(socket_handle, F_SETFD, flags | FD_CLOEXEC) != 0) {
        return map_error(last_error());
    }
#if defined(SO_NOSIGPIPE)
    {
        /* macOS has no MSG_NOSIGNAL; a peer reset must not kill the process. */
        int enabled = 1;
        if (setsockopt(socket_handle, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) != 0) {
            return map_error(last_error());
        }
    }
#endif
    return FOUNDRY_SOCKET_OK;
}

#endif

#if defined(MSG_NOSIGNAL)
#define SEND_FLAGS MSG_NOSIGNAL
#else
#define SEND_FLAGS 0
#endif

static foundry_socket widen(native_socket socket_handle)
{
    return (foundry_socket) socket_handle;
}

static native_socket narrow(foundry_socket socket_handle)
{
    return (native_socket) socket_handle;
}

static void fill_address(struct sockaddr_in *out, const uint8_t address[4], uint16_t port)
{
    memset(out, 0, sizeof(*out));
    out->sin_family = AF_INET;
    out->sin_port = htons(port);
    memcpy(&out->sin_addr, address, 4);
}

/* Small game messages; latency matters more than coalescing them. */
static void disable_coalescing(native_socket socket_handle)
{
    int enabled = 1;
    (void) setsockopt(
        socket_handle, IPPROTO_TCP, TCP_NODELAY, (const char *) &enabled, sizeof(enabled));
}

int foundry_socket_startup(void)
{
#if defined(_WIN32)
    WSADATA data;
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) {
        return FOUNDRY_SOCKET_NETWORK_DOWN;
    }
    if (LOBYTE(data.wVersion) != 2 || HIBYTE(data.wVersion) != 2) {
        WSACleanup();
        return FOUNDRY_SOCKET_NETWORK_DOWN;
    }
#endif
    return FOUNDRY_SOCKET_OK;
}

void foundry_socket_cleanup(void)
{
#if defined(_WIN32)
    WSACleanup();
#endif
}

int foundry_socket_listen(
    const uint8_t address[4],
    uint16_t port,
    int backlog,
    foundry_socket *out_socket,
    uint16_t *out_port)
{
    struct sockaddr_in bound;
    native_socket listener;
    int enabled = 1;
    int result;
#if defined(_WIN32)
    int length = (int) sizeof(bound);
#else
    socklen_t length = (socklen_t) sizeof(bound);
#endif

    *out_socket = FOUNDRY_SOCKET_INVALID;
    *out_port = 0;
    listener = open_native();
    if (listener == NATIVE_INVALID) {
        return map_error(last_error());
    }
    result = make_nonblocking(listener);
    if (result != FOUNDRY_SOCKET_OK) {
        close_native(listener);
        return result;
    }
#if defined(_WIN32)
    /* Windows' SO_REUSEADDR would let another process steal the port; exclusive
     * use is the safe default there. */
    if (setsockopt(listener, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (const char *) &enabled, sizeof(enabled)) != 0) {
        result = map_error(last_error());
        close_native(listener);
        return result;
    }
#else
    /* Lets a restarted server bind while old connections sit in TIME_WAIT; an
     * active listener on the same address still refuses the bind. */
    if (setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled)) != 0) {
        result = map_error(last_error());
        close_native(listener);
        return result;
    }
#endif
    fill_address(&bound, address, port);
    if (bind(listener, (const struct sockaddr *) &bound, sizeof(bound)) != 0 ||
        listen(listener, backlog) != 0 ||
        getsockname(listener, (struct sockaddr *) &bound, &length) != 0) {
        result = map_error(last_error());
        close_native(listener);
        return result;
    }
    *out_socket = widen(listener);
    *out_port = ntohs(bound.sin_port);
    return FOUNDRY_SOCKET_OK;
}

int foundry_socket_accept(
    foundry_socket listener,
    foundry_socket *out_socket,
    uint8_t out_address[4],
    uint16_t *out_port)
{
    struct sockaddr_in peer;
    native_socket accepted;
    int result;
#if defined(_WIN32)
    int length = (int) sizeof(peer);
#else
    socklen_t length = (socklen_t) sizeof(peer);
#endif

    *out_socket = FOUNDRY_SOCKET_INVALID;
    memset(&peer, 0, sizeof(peer));
    accepted = accept(narrow(listener), (struct sockaddr *) &peer, &length);
    if (accepted == NATIVE_INVALID) {
        result = map_error(last_error());
        /* A connection reset before it was accepted is nothing to accept. */
        return result == FOUNDRY_SOCKET_RESET ? FOUNDRY_SOCKET_WOULD_BLOCK : result;
    }
    result = make_nonblocking(accepted);
    if (result != FOUNDRY_SOCKET_OK) {
        close_native(accepted);
        return result;
    }
    disable_coalescing(accepted);
    memcpy(out_address, &peer.sin_addr, 4);
    *out_port = ntohs(peer.sin_port);
    *out_socket = widen(accepted);
    return FOUNDRY_SOCKET_OK;
}

int foundry_socket_connect(const uint8_t address[4], uint16_t port, foundry_socket *out_socket)
{
    struct sockaddr_in target;
    native_socket connector;
    int result;

    *out_socket = FOUNDRY_SOCKET_INVALID;
    connector = open_native();
    if (connector == NATIVE_INVALID) {
        return map_error(last_error());
    }
    result = make_nonblocking(connector);
    if (result != FOUNDRY_SOCKET_OK) {
        close_native(connector);
        return result;
    }
    disable_coalescing(connector);
    fill_address(&target, address, port);
    if (connect(connector, (const struct sockaddr *) &target, sizeof(target)) == 0) {
        *out_socket = widen(connector);
        return FOUNDRY_SOCKET_OK;
    }
    result = map_error(last_error());
    /* A nonblocking connect reports "in progress" as EINPROGRESS on POSIX and as
     * WSAEWOULDBLOCK on Windows; an interrupted one continues in the kernel. */
    if (result == FOUNDRY_SOCKET_IN_PROGRESS || result == FOUNDRY_SOCKET_WOULD_BLOCK) {
        *out_socket = widen(connector);
        return FOUNDRY_SOCKET_IN_PROGRESS;
    }
    close_native(connector);
    return result;
}

static int pending_error(native_socket socket_handle)
{
    int error = 0;
#if defined(_WIN32)
    int length = (int) sizeof(error);
    if (getsockopt(socket_handle, SOL_SOCKET, SO_ERROR, (char *) &error, &length) != 0) {
        return map_error(last_error());
    }
#else
    socklen_t length = (socklen_t) sizeof(error);
    if (getsockopt(socket_handle, SOL_SOCKET, SO_ERROR, &error, &length) != 0) {
        return map_error(last_error());
    }
#endif
    return error == 0 ? FOUNDRY_SOCKET_OK : map_error(error);
}

int foundry_socket_connect_result(foundry_socket socket_handle)
{
    native_socket connector = narrow(socket_handle);
#if defined(_WIN32)
    /* Windows reports a failed nonblocking connect in the exception set, which is
     * the documented route; WSAPoll misreported it on older releases. */
    fd_set writable;
    fd_set failed;
    struct timeval immediately = {0, 0};
    int ready;

    FD_ZERO(&writable);
    FD_ZERO(&failed);
    FD_SET(connector, &writable);
    FD_SET(connector, &failed);
    ready = select(0, NULL, &writable, &failed, &immediately);
    if (ready == SOCKET_ERROR) {
        return map_error(last_error());
    }
    if (ready == 0) {
        return FOUNDRY_SOCKET_IN_PROGRESS;
    }
    if (FD_ISSET(connector, &failed)) {
        int result = pending_error(connector);
        return result == FOUNDRY_SOCKET_OK ? FOUNDRY_SOCKET_FAILED : result;
    }
    return pending_error(connector);
#else
    struct pollfd watched;
    int ready;

    watched.fd = connector;
    watched.events = POLLOUT;
    watched.revents = 0;
    ready = poll(&watched, 1, 0);
    if (ready < 0) {
        int result = map_error(last_error());
        return result == FOUNDRY_SOCKET_WOULD_BLOCK ? FOUNDRY_SOCKET_IN_PROGRESS : result;
    }
    if (ready == 0) {
        return FOUNDRY_SOCKET_IN_PROGRESS;
    }
    {
        int result = pending_error(connector);
        if (result != FOUNDRY_SOCKET_OK) {
            return result;
        }
        /* Hung up with no recorded error is still a failed connect. */
        if ((watched.revents & POLLOUT) == 0) {
            return FOUNDRY_SOCKET_FAILED;
        }
        return FOUNDRY_SOCKET_OK;
    }
#endif
}

int64_t foundry_socket_send(foundry_socket socket_handle, const uint8_t *bytes, size_t length)
{
    int result;
#if defined(_WIN32)
    int sent;
    int bounded = length > (size_t) INT_MAX ? INT_MAX : (int) length;
    sent = send(narrow(socket_handle), (const char *) bytes, bounded, 0);
    if (sent != SOCKET_ERROR) {
        return sent;
    }
#else
    ssize_t sent;
    size_t bounded = length > (size_t) INT_MAX ? (size_t) INT_MAX : length;
    sent = send(narrow(socket_handle), bytes, bounded, SEND_FLAGS);
    if (sent >= 0) {
        return (int64_t) sent;
    }
#endif
    result = map_error(last_error());
    return result == FOUNDRY_SOCKET_IN_PROGRESS ? FOUNDRY_SOCKET_WOULD_BLOCK : result;
}

int64_t foundry_socket_receive(foundry_socket socket_handle, uint8_t *bytes, size_t capacity)
{
    int result;
#if defined(_WIN32)
    int received;
    int bounded = capacity > (size_t) INT_MAX ? INT_MAX : (int) capacity;
    received = recv(narrow(socket_handle), (char *) bytes, bounded, 0);
    if (received != SOCKET_ERROR) {
        return received;
    }
#else
    ssize_t received;
    size_t bounded = capacity > (size_t) INT_MAX ? (size_t) INT_MAX : capacity;
    received = recv(narrow(socket_handle), bytes, bounded, 0);
    if (received >= 0) {
        return (int64_t) received;
    }
#endif
    result = map_error(last_error());
    return result == FOUNDRY_SOCKET_IN_PROGRESS ? FOUNDRY_SOCKET_WOULD_BLOCK : result;
}

void foundry_socket_close(foundry_socket socket_handle)
{
    if (socket_handle != FOUNDRY_SOCKET_INVALID) {
        close_native(narrow(socket_handle));
    }
}
