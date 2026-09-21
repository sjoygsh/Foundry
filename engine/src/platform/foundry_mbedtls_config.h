/*
 * Foundry's qualified Mbed TLS 3.6.7 configuration (M16 Step 1).
 *
 * The upstream default is the base because it carries the provider's tested
 * dependency closure. Foundry then removes protocol paths its wrapper will
 * never expose and adds the two replaceable platform seams qualification
 * needs: bounded allocation and an explicit civil-time source. The Step 2
 * wrapper must additionally restrict cipher suites, groups and signatures at
 * runtime exactly as engine/tests/tls_qualification.c does.
 */
#ifndef FOUNDRY_MBEDTLS_CONFIG_H
#define FOUNDRY_MBEDTLS_CONFIG_H

#include "mbedtls/mbedtls_config.h"

/* Public-internet M16 is TLS 1.3 only. */
#undef MBEDTLS_SSL_PROTO_TLS1_2
#undef MBEDTLS_SSL_SESSION_TICKETS
#undef MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_PSK_ENABLED
#undef MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_PSK_EPHEMERAL_ENABLED
#undef MBEDTLS_SSL_RENEGOTIATION
#undef MBEDTLS_SSL_DTLS_ANTI_REPLAY
#undef MBEDTLS_SSL_DTLS_CLIENT_PORT_REUSE
#undef MBEDTLS_SSL_DTLS_CONNECTION_ID
#undef MBEDTLS_SSL_DTLS_CONNECTION_ID_COMPAT
#undef MBEDTLS_SSL_DTLS_HELLO_VERIFY
#undef MBEDTLS_SSL_DTLS_SRTP
#undef MBEDTLS_SSL_PROTO_DTLS

/* No upstream socket or wall-clock helper crosses Foundry's platform seam. */
#undef MBEDTLS_NET_C
#undef MBEDTLS_TIMING_C
#define MBEDTLS_PLATFORM_MEMORY
#define MBEDTLS_PLATFORM_TIME_ALT

/* The protocol negotiates FNET/1 explicitly and retains the verified peer. */
#define MBEDTLS_SSL_ALPN
#define MBEDTLS_SSL_KEEP_PEER_CERTIFICATE
#define MBEDTLS_SSL_RECORD_SIZE_LIMIT

#endif /* FOUNDRY_MBEDTLS_CONFIG_H */
