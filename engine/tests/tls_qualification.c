/* M16 Step 1: qualify the pinned provider without opening a socket. */

#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "mbedtls/ctr_drbg.h"
#include "mbedtls/entropy.h"
#include "mbedtls/platform.h"
#include "mbedtls/psa_util.h"
#include "mbedtls/pk.h"
#include "mbedtls/ssl.h"
#include "mbedtls/ssl_ciphersuites.h"
#include "mbedtls/x509_crt.h"
#include "psa/crypto.h"
#include "test/certs.h"

#define FOUNDRY_TLS_ALLOCATION_LIMIT (16u * 1024u * 1024u)
#define FOUNDRY_TLS_PIPE_CAPACITY (64u * 1024u)
#define FOUNDRY_TLS_HANDSHAKE_STEPS 4096u

typedef union AllocationHeader {
    struct {
        size_t size;
    } value;
    long double alignment;
    void *pointer_alignment;
} AllocationHeader;

static size_t allocation_used;
static size_t allocation_peak;

static void *bounded_calloc(size_t count, size_t size)
{
    AllocationHeader *allocation;
    size_t bytes;
    size_t total;

    if (size != 0 && count > SIZE_MAX / size) {
        return NULL;
    }
    bytes = count * size;
    if (bytes > SIZE_MAX - sizeof(AllocationHeader)) {
        return NULL;
    }
    total = bytes + sizeof(AllocationHeader);
    if (total > FOUNDRY_TLS_ALLOCATION_LIMIT - allocation_used) {
        return NULL;
    }
    allocation = (AllocationHeader *) calloc(1, total);
    if (allocation == NULL) {
        return NULL;
    }
    allocation->value.size = total;
    allocation_used += total;
    if (allocation_used > allocation_peak) {
        allocation_peak = allocation_used;
    }
    return allocation + 1;
}

static void bounded_free(void *pointer)
{
    AllocationHeader *allocation;

    if (pointer == NULL) {
        return;
    }
    allocation = ((AllocationHeader *) pointer) - 1;
    allocation_used -= allocation->value.size;
    memset(allocation, 0, allocation->value.size);
    free(allocation);
}

/* The committed test identities are valid at this explicit qualification time. */
static mbedtls_time_t qualification_time(mbedtls_time_t *out)
{
    const mbedtls_time_t value = (mbedtls_time_t) 1789948800;
    if (out != NULL) {
        *out = value;
    }
    return value;
}

typedef struct Pipe {
    unsigned char bytes[FOUNDRY_TLS_PIPE_CAPACITY];
    size_t offset;
    size_t length;
    size_t peak;
} Pipe;

typedef struct MemoryBio {
    Pipe *incoming;
    Pipe *outgoing;
} MemoryBio;

static int memory_send(void *context, const unsigned char *bytes, size_t length)
{
    MemoryBio *bio = (MemoryBio *) context;
    Pipe *pipe = bio->outgoing;

    if (length > INT_MAX) {
        return MBEDTLS_ERR_SSL_BAD_INPUT_DATA;
    }
    if (pipe->offset != 0 && pipe->offset + pipe->length + length > sizeof(pipe->bytes)) {
        memmove(pipe->bytes, pipe->bytes + pipe->offset, pipe->length);
        pipe->offset = 0;
    }
    if (length > sizeof(pipe->bytes) - pipe->offset - pipe->length) {
        return MBEDTLS_ERR_SSL_WANT_WRITE;
    }
    memcpy(pipe->bytes + pipe->offset + pipe->length, bytes, length);
    pipe->length += length;
    if (pipe->length > pipe->peak) {
        pipe->peak = pipe->length;
    }
    return (int) length;
}

static int memory_receive(void *context, unsigned char *bytes, size_t capacity)
{
    MemoryBio *bio = (MemoryBio *) context;
    Pipe *pipe = bio->incoming;
    size_t length;

    if (pipe->length == 0) {
        return MBEDTLS_ERR_SSL_WANT_READ;
    }
    length = capacity < pipe->length ? capacity : pipe->length;
    if (length > INT_MAX) {
        length = INT_MAX;
    }
    memcpy(bytes, pipe->bytes + pipe->offset, length);
    pipe->offset += length;
    pipe->length -= length;
    if (pipe->length == 0) {
        pipe->offset = 0;
    }
    return (int) length;
}

typedef struct Endpoint {
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config config;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context random;
    mbedtls_x509_crt trust;
    mbedtls_x509_crt certificate;
    mbedtls_pk_context private_key;
    MemoryBio bio;
} Endpoint;

static const int allowed_ciphersuites[] = {
    MBEDTLS_TLS1_3_AES_128_GCM_SHA256,
    0,
};
static const uint16_t allowed_groups[] = {
    MBEDTLS_SSL_IANA_TLS_GROUP_SECP256R1,
    0,
};
static const uint16_t allowed_signatures[] = {
    MBEDTLS_TLS1_3_SIG_ECDSA_SECP256R1_SHA256,
    MBEDTLS_TLS1_3_SIG_NONE,
};
static const char *allowed_protocols[] = {
    "fnet/1",
    NULL,
};

static void endpoint_zero(Endpoint *endpoint)
{
    memset(endpoint, 0, sizeof(*endpoint));
    mbedtls_ssl_init(&endpoint->ssl);
    mbedtls_ssl_config_init(&endpoint->config);
    mbedtls_entropy_init(&endpoint->entropy);
    mbedtls_ctr_drbg_init(&endpoint->random);
    mbedtls_x509_crt_init(&endpoint->trust);
    mbedtls_x509_crt_init(&endpoint->certificate);
    mbedtls_pk_init(&endpoint->private_key);
}

static void endpoint_free(Endpoint *endpoint)
{
    mbedtls_ssl_free(&endpoint->ssl);
    mbedtls_ssl_config_free(&endpoint->config);
    mbedtls_x509_crt_free(&endpoint->trust);
    mbedtls_x509_crt_free(&endpoint->certificate);
    mbedtls_pk_free(&endpoint->private_key);
    mbedtls_ctr_drbg_free(&endpoint->random);
    mbedtls_entropy_free(&endpoint->entropy);
    memset(endpoint, 0, sizeof(*endpoint));
}

static int endpoint_init(
    Endpoint *endpoint,
    int is_server,
    int supply_certificate,
    const char *server_name,
    Pipe *incoming,
    Pipe *outgoing)
{
    const unsigned char *certificate;
    const unsigned char *private_key;
    size_t certificate_length;
    size_t private_key_length;
    const unsigned char personalization[] = "foundry-m16-tls-qualification";
    int result;

    endpoint_zero(endpoint);
    endpoint->bio.incoming = incoming;
    endpoint->bio.outgoing = outgoing;

    result = mbedtls_ctr_drbg_seed(
        &endpoint->random,
        mbedtls_entropy_func,
        &endpoint->entropy,
        personalization,
        sizeof(personalization) - 1);
    if (result != 0) {
        return result;
    }
    result = mbedtls_x509_crt_parse(
        &endpoint->trust,
        (const unsigned char *) mbedtls_test_ca_crt_ec,
        mbedtls_test_ca_crt_ec_len);
    if (result != 0) {
        return result;
    }

    if (supply_certificate) {
        if (is_server) {
            certificate = (const unsigned char *) mbedtls_test_srv_crt_ec;
            certificate_length = mbedtls_test_srv_crt_ec_len;
            private_key = (const unsigned char *) mbedtls_test_srv_key_ec;
            private_key_length = mbedtls_test_srv_key_ec_len;
        } else {
            certificate = (const unsigned char *) mbedtls_test_cli_crt_ec;
            certificate_length = mbedtls_test_cli_crt_ec_len;
            private_key = (const unsigned char *) mbedtls_test_cli_key_ec;
            private_key_length = mbedtls_test_cli_key_ec_len;
        }
        result = mbedtls_x509_crt_parse(
            &endpoint->certificate,
            certificate,
            certificate_length);
        if (result != 0) {
            return result;
        }
        result = mbedtls_pk_parse_key(
            &endpoint->private_key,
            private_key,
            private_key_length,
            NULL,
            0,
            mbedtls_ctr_drbg_random,
            &endpoint->random);
        if (result != 0) {
            return result;
        }
    }

    result = mbedtls_ssl_config_defaults(
        &endpoint->config,
        is_server ? MBEDTLS_SSL_IS_SERVER : MBEDTLS_SSL_IS_CLIENT,
        MBEDTLS_SSL_TRANSPORT_STREAM,
        MBEDTLS_SSL_PRESET_DEFAULT);
    if (result != 0) {
        return result;
    }
    mbedtls_ssl_conf_min_tls_version(&endpoint->config, MBEDTLS_SSL_VERSION_TLS1_3);
    mbedtls_ssl_conf_max_tls_version(&endpoint->config, MBEDTLS_SSL_VERSION_TLS1_3);
    mbedtls_ssl_conf_authmode(&endpoint->config, MBEDTLS_SSL_VERIFY_REQUIRED);
    mbedtls_ssl_conf_ca_chain(&endpoint->config, &endpoint->trust, NULL);
    mbedtls_ssl_conf_rng(
        &endpoint->config,
        mbedtls_ctr_drbg_random,
        &endpoint->random);
    mbedtls_ssl_conf_ciphersuites(&endpoint->config, allowed_ciphersuites);
    mbedtls_ssl_conf_groups(&endpoint->config, allowed_groups);
    mbedtls_ssl_conf_sig_algs(&endpoint->config, allowed_signatures);
    mbedtls_ssl_conf_cert_profile(&endpoint->config, &mbedtls_x509_crt_profile_suiteb);
    mbedtls_ssl_conf_tls13_key_exchange_modes(
        &endpoint->config,
        MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_EPHEMERAL);
    result = mbedtls_ssl_conf_alpn_protocols(&endpoint->config, allowed_protocols);
    if (result != 0) {
        return result;
    }
    if (supply_certificate) {
        result = mbedtls_ssl_conf_own_cert(
            &endpoint->config,
            &endpoint->certificate,
            &endpoint->private_key);
        if (result != 0) {
            return result;
        }
    }
    result = mbedtls_ssl_setup(&endpoint->ssl, &endpoint->config);
    if (result != 0) {
        return result;
    }
    if (!is_server) {
        result = mbedtls_ssl_set_hostname(&endpoint->ssl, server_name);
        if (result != 0) {
            return result;
        }
    }
    mbedtls_ssl_set_bio(
        &endpoint->ssl,
        &endpoint->bio,
        memory_send,
        memory_receive,
        NULL);
    return 0;
}

static int expected_progress(int result)
{
    return result == 0 ||
           result == MBEDTLS_ERR_SSL_WANT_READ ||
           result == MBEDTLS_ERR_SSL_WANT_WRITE;
}

static int qualify_pair(
    const char *server_name,
    int client_certificate,
    int expect_success,
    size_t *wire_peak,
    size_t *handshake_call_peak)
{
    Endpoint client;
    Endpoint server;
    Pipe client_to_server;
    Pipe server_to_client;
    unsigned int step;
    size_t handshake_calls = 0;
    int client_result = MBEDTLS_ERR_SSL_WANT_READ;
    int server_result = MBEDTLS_ERR_SSL_WANT_READ;
    int client_complete = 0;
    int server_complete = 0;
    int result;

    memset(&client_to_server, 0, sizeof(client_to_server));
    memset(&server_to_client, 0, sizeof(server_to_client));
    endpoint_zero(&client);
    endpoint_zero(&server);

    result = endpoint_init(
        &client,
        0,
        client_certificate,
        server_name,
        &server_to_client,
        &client_to_server);
    if (result != 0) {
        endpoint_free(&client);
        endpoint_free(&server);
        return 1001;
    }
    result = endpoint_init(
        &server,
        1,
        1,
        NULL,
        &client_to_server,
        &server_to_client);
    if (result != 0) {
        endpoint_free(&client);
        endpoint_free(&server);
        return 1002;
    }

    for (step = 0; step < FOUNDRY_TLS_HANDSHAKE_STEPS; ++step) {
        if (!client_complete && expected_progress(client_result)) {
            client_result = mbedtls_ssl_handshake(&client.ssl);
            ++handshake_calls;
            client_complete = client_result == 0;
        }
        if (!server_complete && expected_progress(server_result)) {
            server_result = mbedtls_ssl_handshake(&server.ssl);
            ++handshake_calls;
            server_complete = server_result == 0;
        }
        if (client_complete && server_complete) {
            break;
        }
        if ((!expected_progress(client_result) && !client_complete) ||
            (!expected_progress(server_result) && !server_complete)) {
            break;
        }
    }

    if (client_to_server.peak > *wire_peak) {
        *wire_peak = client_to_server.peak;
    }
    if (server_to_client.peak > *wire_peak) {
        *wire_peak = server_to_client.peak;
    }
    if (handshake_calls > *handshake_call_peak) {
        *handshake_call_peak = handshake_calls;
    }

    if (expect_success) {
        static const unsigned char message[] = "fnet-qualified";
        unsigned char received[sizeof(message)];
        int write_result;
        int read_result;

        if (!client_complete || !server_complete) {
            result = 1101;
            goto cleanup;
        }
        if (mbedtls_ssl_get_verify_result(&client.ssl) != 0 ||
            mbedtls_ssl_get_verify_result(&server.ssl) != 0 ||
            mbedtls_ssl_get_peer_cert(&client.ssl) == NULL ||
            mbedtls_ssl_get_peer_cert(&server.ssl) == NULL) {
            result = 1102;
            goto cleanup;
        }
        if (strcmp(mbedtls_ssl_get_version(&client.ssl), "TLSv1.3") != 0 ||
            strcmp(mbedtls_ssl_get_ciphersuite(&client.ssl),
                   "TLS1-3-AES-128-GCM-SHA256") != 0 ||
            mbedtls_ssl_get_alpn_protocol(&client.ssl) == NULL ||
            strcmp(mbedtls_ssl_get_alpn_protocol(&client.ssl), "fnet/1") != 0) {
            result = 1103;
            goto cleanup;
        }
        write_result = mbedtls_ssl_write(&client.ssl, message, sizeof(message));
        if (write_result != (int) sizeof(message)) {
            result = 1104;
            goto cleanup;
        }
        read_result = mbedtls_ssl_read(&server.ssl, received, sizeof(received));
        if (read_result != (int) sizeof(message) ||
            memcmp(received, message, sizeof(message)) != 0) {
            result = 1105;
            goto cleanup;
        }
        result = 0;
    } else {
        if (client_complete && server_complete) {
            result = 1201;
            goto cleanup;
        }
        result = 0;
    }

cleanup:
    endpoint_free(&client);
    endpoint_free(&server);
    return result;
}

int foundry_tls_qualification_run(
    size_t *out_peak_bytes,
    size_t *out_wire_peak_bytes,
    size_t *out_handshake_call_peak)
{
    size_t wire_peak = 0;
    size_t handshake_call_peak = 0;
    int result;

    if (out_peak_bytes == NULL || out_wire_peak_bytes == NULL ||
        out_handshake_call_peak == NULL) {
        return 1;
    }
    allocation_used = 0;
    allocation_peak = 0;
    if (mbedtls_platform_set_calloc_free(bounded_calloc, bounded_free) != 0) {
        return 2;
    }
    if (mbedtls_platform_set_time(qualification_time) != 0) {
        return 3;
    }
    if (psa_crypto_init() != PSA_SUCCESS) {
        return 4;
    }

    result = qualify_pair("localhost", 1, 1, &wire_peak, &handshake_call_peak);
    if (result == 0) {
        result = qualify_pair(
            "wrong.invalid", 1, 0, &wire_peak, &handshake_call_peak);
    }
    if (result == 0) {
        result = qualify_pair(
            "localhost", 0, 0, &wire_peak, &handshake_call_peak);
    }

    mbedtls_psa_crypto_free();
    *out_peak_bytes = allocation_peak;
    *out_wire_peak_bytes = wire_peak;
    *out_handshake_call_peak = handshake_call_peak;
    if (result != 0) {
        return result;
    }
    if (allocation_used != 0) {
        return 5;
    }
    return 0;
}
