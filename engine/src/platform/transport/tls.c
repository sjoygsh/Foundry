/*
 * Mbed TLS 3.6.7 behind `platform`'s transport (M16 Step 2).
 *
 * The configuration is Step 1's qualified one, applied at runtime exactly as
 * engine/tests/tls_qualification.c proved it: TLS 1.3 only, one ciphersuite,
 * one group, one signature algorithm, the Suite B certificate profile,
 * ephemeral key exchange only and ALPN `fnet/1`. Two things are stricter than
 * the provider's defaults, and both are Foundry's decision (networking.md,
 * Step 2 Resolution):
 *
 *   - a peer's leaf certificate must carry an extendedKeyUsage naming its role
 *     (serverAuth or clientAuth). The provider only checks the extension when
 *     it happens to be present; an operator-issued identity always has one.
 *   - a client pins the server's key: the SHA-256 of its SubjectPublicKeyInfo,
 *     provisioned out of band, is compared inside certificate verification, so a
 *     mismatch fails the handshake rather than a check after it.
 *
 * Allocation goes through a counted, capped hook that zeroizes on free, and the
 * certificate clock is set explicitly before each handshake call. All of it is
 * process-wide provider state with one owning thread.
 */

#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "mbedtls/ctr_drbg.h"
#include "mbedtls/ecp.h"
#include "mbedtls/entropy.h"
#include "mbedtls/oid.h"
#include "mbedtls/pk.h"
#include "mbedtls/platform.h"
#include "mbedtls/platform_util.h"
#include "mbedtls/sha256.h"
#include "mbedtls/ssl.h"
#include "mbedtls/x509_crt.h"
#include "psa/crypto.h"

#include "foundry_transport.h"

/* The earliest civil time a certificate check will run at: 2026-01-01T00:00:00Z.
 * A clock that reads earlier than the provider's own qualification is broken, and
 * a broken clock refuses rather than guessing (networking.md §4.1). */
#define FOUNDRY_TLS_TIME_FLOOR ((int64_t) 1767225600)

/* Four certificates: the leaf, at most two intermediates and the root. */
#define FOUNDRY_TLS_MAX_CHAIN_DEPTH (FOUNDRY_TLS_MAX_CHAIN_CERTIFICATES - 1)

/* The header states the handshake-message bound `net` checks its limits against;
 * it is only true while the provider's input record keeps its default size. */
#if MBEDTLS_SSL_IN_CONTENT_LEN != FOUNDRY_TLS_MAX_HANDSHAKE_MESSAGE
#error "FOUNDRY_TLS_MAX_HANDSHAKE_MESSAGE must equal MBEDTLS_SSL_IN_CONTENT_LEN"
#endif

#define FOUNDRY_TLS_MAX_SERVER_NAME 253

/* ---- Process-wide provider state --------------------------------------- */

typedef union allocation_header {
    struct {
        size_t size;
    } value;
    long double alignment;
    void *pointer_alignment;
} allocation_header;

static size_t allocation_limit;
static size_t allocation_used;
static size_t allocation_peak;
static unsigned int runtime_references;
static mbedtls_time_t certificate_time;

static void *bounded_calloc(size_t count, size_t size)
{
    allocation_header *allocation;
    size_t bytes;
    size_t total;

    if (size != 0 && count > SIZE_MAX / size) {
        return NULL;
    }
    bytes = count * size;
    if (bytes > SIZE_MAX - sizeof(allocation_header)) {
        return NULL;
    }
    total = bytes + sizeof(allocation_header);
    if (total > allocation_limit - allocation_used) {
        return NULL;
    }
    allocation = (allocation_header *) calloc(1, total);
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

/* Key material passes through these blocks; none of it outlives its owner. */
static void bounded_free(void *pointer)
{
    allocation_header *allocation;
    size_t total;

    if (pointer == NULL) {
        return;
    }
    allocation = ((allocation_header *) pointer) - 1;
    total = allocation->value.size;
    allocation_used -= total;
    mbedtls_platform_zeroize(allocation, total);
    free(allocation);
}

static mbedtls_time_t foundry_time(mbedtls_time_t *out)
{
    if (out != NULL) {
        *out = certificate_time;
    }
    return certificate_time;
}

int foundry_tls_runtime_acquire(size_t limit)
{
    psa_status_t status;

    if (runtime_references == 0) {
        allocation_limit = limit;
        allocation_used = 0;
        allocation_peak = 0;
        if (mbedtls_platform_set_calloc_free(bounded_calloc, bounded_free) != 0 ||
            mbedtls_platform_set_time(foundry_time) != 0) {
            return FOUNDRY_TLS_CREDENTIALS_UNAVAILABLE;
        }
        status = psa_crypto_init();
        if (status == PSA_ERROR_INSUFFICIENT_MEMORY) {
            mbedtls_psa_crypto_free();
            return FOUNDRY_TLS_CREDENTIALS_MEMORY;
        }
        if (status != PSA_SUCCESS) {
            mbedtls_psa_crypto_free();
            return FOUNDRY_TLS_CREDENTIALS_ENTROPY;
        }
    }
    ++runtime_references;
    return FOUNDRY_TLS_CREDENTIALS_OK;
}

void foundry_tls_runtime_release(void)
{
    if (runtime_references == 0) {
        return;
    }
    --runtime_references;
    if (runtime_references == 0) {
        mbedtls_psa_crypto_free();
    }
}

size_t foundry_tls_allocated_bytes(void) { return allocation_used; }

size_t foundry_tls_allocation_peak(void) { return allocation_peak; }

/* ---- The qualified algorithm allowlist -------------------------------- */

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
static const char protocol_name[] = "fnet/1";
static const char *allowed_protocols[] = {
    protocol_name,
    NULL,
};

/* ---- Credentials -------------------------------------------------------- */

struct foundry_tls_credentials {
    int role;
    mbedtls_ssl_config config;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context random;
    mbedtls_x509_crt trust;
    mbedtls_x509_crt certificate;
    mbedtls_pk_context private_key;
    char server_name[FOUNDRY_TLS_MAX_SERVER_NAME + 1];
    uint8_t server_key[FOUNDRY_TLS_KEY_BYTES];
};

static int is_pem(const uint8_t *bytes, size_t length)
{
    static const char marker[] = "-----BEGIN ";
    const size_t marker_length = sizeof(marker) - 1;
    size_t index;

    if (length < marker_length) {
        return 0;
    }
    for (index = 0; index + marker_length <= length; ++index) {
        if (memcmp(bytes + index, marker, marker_length) == 0) {
            return 1;
        }
    }
    return 0;
}

/* PEM parsing wants a terminating NUL the caller's bytes need not have, so PEM
 * is copied into a counted, zeroized buffer first. DER is parsed in place. */
static uint8_t *terminated_copy(const uint8_t *bytes, size_t length)
{
    uint8_t *copy;

    if (length == SIZE_MAX) {
        return NULL;
    }
    copy = (uint8_t *) mbedtls_calloc(1, length + 1);
    if (copy != NULL) {
        memcpy(copy, bytes, length);
    }
    return copy;
}

static void release_copy(uint8_t *copy, size_t length)
{
    if (copy != NULL) {
        mbedtls_platform_zeroize(copy, length + 1);
        mbedtls_free(copy);
    }
}

static int is_allocation_failure(int result)
{
    return result == MBEDTLS_ERR_X509_ALLOC_FAILED ||
           result == MBEDTLS_ERR_PK_ALLOC_FAILED ||
           result == MBEDTLS_ERR_SSL_ALLOC_FAILED ||
           result == MBEDTLS_ERR_MPI_ALLOC_FAILED ||
           result == MBEDTLS_ERR_ECP_ALLOC_FAILED ||
           result == MBEDTLS_ERR_ASN1_ALLOC_FAILED ||
           result == MBEDTLS_ERR_CIPHER_ALLOC_FAILED ||
           result == MBEDTLS_ERR_MD_ALLOC_FAILED;
}

static int parse_certificates(mbedtls_x509_crt *chain, const uint8_t *bytes, size_t length, int failure)
{
    int result;

    if (bytes == NULL || length == 0) {
        return failure;
    }
    if (is_pem(bytes, length)) {
        uint8_t *copy = terminated_copy(bytes, length);
        if (copy == NULL) {
            return FOUNDRY_TLS_CREDENTIALS_MEMORY;
        }
        result = mbedtls_x509_crt_parse(chain, copy, length + 1);
        release_copy(copy, length);
    } else {
        result = mbedtls_x509_crt_parse_der(chain, bytes, length);
    }
    if (is_allocation_failure(result)) {
        return FOUNDRY_TLS_CREDENTIALS_MEMORY;
    }
    /* A positive result is a PEM bundle with some unparsable member: all or none. */
    return result == 0 ? FOUNDRY_TLS_CREDENTIALS_OK : failure;
}

static int parse_private_key(foundry_tls_credentials *credentials, const uint8_t *bytes, size_t length)
{
    int result;

    if (bytes == NULL || length == 0) {
        return FOUNDRY_TLS_CREDENTIALS_INVALID_KEY;
    }
    if (is_pem(bytes, length)) {
        uint8_t *copy = terminated_copy(bytes, length);
        if (copy == NULL) {
            return FOUNDRY_TLS_CREDENTIALS_MEMORY;
        }
        result = mbedtls_pk_parse_key(
            &credentials->private_key, copy, length + 1, NULL, 0,
            mbedtls_ctr_drbg_random, &credentials->random);
        release_copy(copy, length);
    } else {
        result = mbedtls_pk_parse_key(
            &credentials->private_key, bytes, length, NULL, 0,
            mbedtls_ctr_drbg_random, &credentials->random);
    }
    if (is_allocation_failure(result)) {
        return FOUNDRY_TLS_CREDENTIALS_MEMORY;
    }
    /* An encrypted key needs a password, and no password is ever an argument. */
    return result == 0 ? FOUNDRY_TLS_CREDENTIALS_OK : FOUNDRY_TLS_CREDENTIALS_INVALID_KEY;
}

static int has_role_usage(const mbedtls_x509_crt *certificate, int role)
{
    const char *oid = role == FOUNDRY_TLS_ROLE_SERVER ? MBEDTLS_OID_SERVER_AUTH : MBEDTLS_OID_CLIENT_AUTH;
    const size_t oid_length = role == FOUNDRY_TLS_ROLE_SERVER
                                  ? MBEDTLS_OID_SIZE(MBEDTLS_OID_SERVER_AUTH)
                                  : MBEDTLS_OID_SIZE(MBEDTLS_OID_CLIENT_AUTH);

    if (!mbedtls_x509_crt_has_ext_type(certificate, MBEDTLS_X509_EXT_EXTENDED_KEY_USAGE)) {
        return 0;
    }
    if (mbedtls_x509_crt_check_extended_key_usage(certificate, oid, oid_length) != 0) {
        return 0;
    }
    /* keyUsage is optional, but when present it must allow the signature TLS 1.3
     * CertificateVerify makes. */
    return mbedtls_x509_crt_check_key_usage(certificate, MBEDTLS_X509_KU_DIGITAL_SIGNATURE) == 0;
}

static int valid_server_name(const uint8_t *name, size_t length)
{
    size_t index;

    if (name == NULL || length == 0 || length > FOUNDRY_TLS_MAX_SERVER_NAME) {
        return 0;
    }
    if (name[0] == '.' || name[length - 1] == '.' || name[0] == '-') {
        return 0;
    }
    for (index = 0; index < length; ++index) {
        const uint8_t byte = name[index];
        const int letter = (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z');
        const int digit = byte >= '0' && byte <= '9';
        if (!letter && !digit && byte != '-' && byte != '.') {
            return 0;
        }
    }
    return 1;
}

static void credentials_free(foundry_tls_credentials *credentials)
{
    mbedtls_ssl_config_free(&credentials->config);
    mbedtls_x509_crt_free(&credentials->trust);
    mbedtls_x509_crt_free(&credentials->certificate);
    mbedtls_pk_free(&credentials->private_key);
    mbedtls_ctr_drbg_free(&credentials->random);
    mbedtls_entropy_free(&credentials->entropy);
    mbedtls_platform_zeroize(credentials, sizeof(*credentials));
    mbedtls_free(credentials);
}

int foundry_tls_credentials_create(
    const foundry_tls_credential_source *source,
    foundry_tls_credentials **out_credentials)
{
    static const unsigned char personalization[] = "foundry-m16-transport";
    foundry_tls_credentials *credentials;
    const mbedtls_ecp_keypair *key_pair;
    int result;

    if (out_credentials == NULL) {
        return FOUNDRY_TLS_CREDENTIALS_INVALID_ARGUMENT;
    }
    *out_credentials = NULL;
    if (runtime_references == 0) {
        return FOUNDRY_TLS_CREDENTIALS_UNAVAILABLE;
    }
    if (source == NULL ||
        (source->role != FOUNDRY_TLS_ROLE_SERVER && source->role != FOUNDRY_TLS_ROLE_CLIENT)) {
        return FOUNDRY_TLS_CREDENTIALS_INVALID_ARGUMENT;
    }
    if (source->role == FOUNDRY_TLS_ROLE_CLIENT) {
        if (!valid_server_name(source->server_name, source->server_name_length) ||
            source->server_key == NULL) {
            return FOUNDRY_TLS_CREDENTIALS_INVALID_ARGUMENT;
        }
    } else if (source->server_name_length != 0 || source->server_key != NULL) {
        return FOUNDRY_TLS_CREDENTIALS_INVALID_ARGUMENT;
    }

    credentials = (foundry_tls_credentials *) mbedtls_calloc(1, sizeof(*credentials));
    if (credentials == NULL) {
        return FOUNDRY_TLS_CREDENTIALS_MEMORY;
    }
    credentials->role = source->role;
    mbedtls_ssl_config_init(&credentials->config);
    mbedtls_entropy_init(&credentials->entropy);
    mbedtls_ctr_drbg_init(&credentials->random);
    mbedtls_x509_crt_init(&credentials->trust);
    mbedtls_x509_crt_init(&credentials->certificate);
    mbedtls_pk_init(&credentials->private_key);
    if (source->role == FOUNDRY_TLS_ROLE_CLIENT) {
        memcpy(credentials->server_name, source->server_name, source->server_name_length);
        credentials->server_name[source->server_name_length] = '\0';
        memcpy(credentials->server_key, source->server_key, FOUNDRY_TLS_KEY_BYTES);
    }

    result = mbedtls_ctr_drbg_seed(
        &credentials->random, mbedtls_entropy_func, &credentials->entropy,
        personalization, sizeof(personalization) - 1);
    if (result != 0) {
        credentials_free(credentials);
        return result == MBEDTLS_ERR_CTR_DRBG_ENTROPY_SOURCE_FAILED
                   ? FOUNDRY_TLS_CREDENTIALS_ENTROPY
                   : FOUNDRY_TLS_CREDENTIALS_MEMORY;
    }

    result = parse_certificates(
        &credentials->trust, source->trust, source->trust_length,
        FOUNDRY_TLS_CREDENTIALS_INVALID_TRUST);
    if (result == FOUNDRY_TLS_CREDENTIALS_OK) {
        result = parse_certificates(
            &credentials->certificate, source->certificate, source->certificate_length,
            FOUNDRY_TLS_CREDENTIALS_INVALID_CERTIFICATE);
    }
    if (result == FOUNDRY_TLS_CREDENTIALS_OK) {
        result = parse_private_key(credentials, source->private_key, source->private_key_length);
    }
    if (result != FOUNDRY_TLS_CREDENTIALS_OK) {
        credentials_free(credentials);
        return result;
    }

    /* The qualified signature algorithm is ECDSA over P-256, so the identity key
     * must be a P-256 key; anything else would only fail later, in a handshake. */
    key_pair = mbedtls_pk_get_type(&credentials->private_key) == MBEDTLS_PK_ECKEY
                   ? mbedtls_pk_ec(credentials->private_key)
                   : NULL;
    if (key_pair == NULL || mbedtls_ecp_keypair_get_group_id(key_pair) != MBEDTLS_ECP_DP_SECP256R1) {
        credentials_free(credentials);
        return FOUNDRY_TLS_CREDENTIALS_UNSUPPORTED_KEY;
    }
    result = mbedtls_pk_check_pair(
        &credentials->certificate.pk, &credentials->private_key,
        mbedtls_ctr_drbg_random, &credentials->random);
    if (result != 0) {
        credentials_free(credentials);
        return is_allocation_failure(result) ? FOUNDRY_TLS_CREDENTIALS_MEMORY
                                             : FOUNDRY_TLS_CREDENTIALS_KEY_MISMATCH;
    }
    if (!has_role_usage(&credentials->certificate, source->role)) {
        credentials_free(credentials);
        return FOUNDRY_TLS_CREDENTIALS_WRONG_USAGE;
    }

    result = mbedtls_ssl_config_defaults(
        &credentials->config,
        source->role == FOUNDRY_TLS_ROLE_SERVER ? MBEDTLS_SSL_IS_SERVER : MBEDTLS_SSL_IS_CLIENT,
        MBEDTLS_SSL_TRANSPORT_STREAM,
        MBEDTLS_SSL_PRESET_DEFAULT);
    if (result != 0) {
        credentials_free(credentials);
        return is_allocation_failure(result) ? FOUNDRY_TLS_CREDENTIALS_MEMORY
                                             : FOUNDRY_TLS_CREDENTIALS_UNAVAILABLE;
    }
    mbedtls_ssl_conf_min_tls_version(&credentials->config, MBEDTLS_SSL_VERSION_TLS1_3);
    mbedtls_ssl_conf_max_tls_version(&credentials->config, MBEDTLS_SSL_VERSION_TLS1_3);
    mbedtls_ssl_conf_authmode(&credentials->config, MBEDTLS_SSL_VERIFY_REQUIRED);
    mbedtls_ssl_conf_ca_chain(&credentials->config, &credentials->trust, NULL);
    mbedtls_ssl_conf_rng(&credentials->config, mbedtls_ctr_drbg_random, &credentials->random);
    mbedtls_ssl_conf_ciphersuites(&credentials->config, allowed_ciphersuites);
    mbedtls_ssl_conf_groups(&credentials->config, allowed_groups);
    mbedtls_ssl_conf_sig_algs(&credentials->config, allowed_signatures);
    mbedtls_ssl_conf_cert_profile(&credentials->config, &mbedtls_x509_crt_profile_suiteb);
    mbedtls_ssl_conf_tls13_key_exchange_modes(
        &credentials->config, MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_EPHEMERAL);
    result = mbedtls_ssl_conf_alpn_protocols(&credentials->config, allowed_protocols);
    if (result == 0) {
        result = mbedtls_ssl_conf_own_cert(
            &credentials->config, &credentials->certificate, &credentials->private_key);
    }
    if (result != 0) {
        credentials_free(credentials);
        return is_allocation_failure(result) ? FOUNDRY_TLS_CREDENTIALS_MEMORY
                                             : FOUNDRY_TLS_CREDENTIALS_UNAVAILABLE;
    }
    *out_credentials = credentials;
    return FOUNDRY_TLS_CREDENTIALS_OK;
}

void foundry_tls_credentials_destroy(foundry_tls_credentials *credentials)
{
    if (credentials != NULL) {
        credentials_free(credentials);
    }
}

/* ---- Sessions ----------------------------------------------------------- */

struct foundry_tls_session {
    mbedtls_ssl_context ssl;
    foundry_tls_credentials *credentials;
    int64_t fixed_time;
    void *carrier;
    foundry_tls_send_fn send;
    foundry_tls_receive_fn receive;
    /* The carrier's own failure, so a provider error it caused is reported as the
     * carrier's rather than as a protocol fault. */
    int carrier_status;
    int progressed;
    int server_key_mismatch;
    int chain_too_long;
    int have_peer_key;
    uint8_t peer_key[FOUNDRY_TLS_KEY_BYTES];
    /* The earliest notAfter the verified chain carries; 0 until one is seen. */
    int64_t valid_until;
};

static int session_send(void *context, const unsigned char *bytes, size_t length)
{
    foundry_tls_session *session = (foundry_tls_session *) context;
    int result = session->send(session->carrier, bytes, length > INT_MAX ? INT_MAX : length);

    if (result > 0) {
        session->progressed = 1;
        return result;
    }
    if (result == FOUNDRY_TLS_IO_WOULD_BLOCK) {
        return MBEDTLS_ERR_SSL_WANT_WRITE;
    }
    session->carrier_status = result == FOUNDRY_TLS_IO_EOF ? FOUNDRY_TLS_IO_RESET : result;
    return MBEDTLS_ERR_SSL_INTERNAL_ERROR;
}

static int session_receive(void *context, unsigned char *bytes, size_t capacity)
{
    foundry_tls_session *session = (foundry_tls_session *) context;
    int result = session->receive(session->carrier, bytes, capacity > INT_MAX ? INT_MAX : capacity);

    if (result > 0) {
        session->progressed = 1;
        return result;
    }
    if (result == FOUNDRY_TLS_IO_WOULD_BLOCK) {
        return MBEDTLS_ERR_SSL_WANT_READ;
    }
    session->carrier_status = result;
    /* Zero is the provider's end-of-stream. */
    return result == FOUNDRY_TLS_IO_EOF ? 0 : MBEDTLS_ERR_SSL_INTERNAL_ERROR;
}

/* A certificate's UTC time as seconds since the Unix epoch (proleptic Gregorian,
 * days-from-civil). The provider has already parsed and range-checked the fields. */
static int64_t civil_seconds(const mbedtls_x509_time *time)
{
    const int64_t month = time->mon;
    const int64_t year = (int64_t) time->year - (month <= 2 ? 1 : 0);
    const int64_t era = (year >= 0 ? year : year - 399) / 400;
    const int64_t year_of_era = year - era * 400;
    const int64_t day_of_year = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + time->day - 1;
    const int64_t day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    const int64_t days = era * 146097 + day_of_era - 719468;

    return days * 86400 + (int64_t) time->hour * 3600 + (int64_t) time->min * 60 + time->sec;
}

/* Called once per certificate the provider verifies, root first, leaf last. It
 * adds Foundry's two rules; it never clears a flag the provider set. */
static int verify_certificate(void *context, mbedtls_x509_crt *certificate, int depth, uint32_t *flags)
{
    foundry_tls_session *session = (foundry_tls_session *) context;
    const int peer_role = session->credentials->role == FOUNDRY_TLS_ROLE_CLIENT
                              ? FOUNDRY_TLS_ROLE_SERVER
                              : FOUNDRY_TLS_ROLE_CLIENT;
    const int64_t valid_to = civil_seconds(&certificate->valid_to);

    /* A chain is only as current as its first certificate to expire, so a live
     * session is judged against the earliest, not the leaf's alone. */
    if (session->valid_until == 0 || valid_to < session->valid_until) {
        session->valid_until = valid_to;
    }
    if (depth > FOUNDRY_TLS_MAX_CHAIN_DEPTH) {
        session->chain_too_long = 1;
        *flags |= MBEDTLS_X509_BADCERT_OTHER;
    }
    if (depth != 0) {
        return 0;
    }
    if (!has_role_usage(certificate, peer_role)) {
        *flags |= MBEDTLS_X509_BADCERT_EXT_KEY_USAGE;
    }
    if (mbedtls_sha256(certificate->pk_raw.p, certificate->pk_raw.len, session->peer_key, 0) != 0) {
        *flags |= MBEDTLS_X509_BADCERT_OTHER;
        return 0;
    }
    session->have_peer_key = 1;
    if (session->credentials->role == FOUNDRY_TLS_ROLE_CLIENT &&
        memcmp(session->peer_key, session->credentials->server_key, FOUNDRY_TLS_KEY_BYTES) != 0) {
        session->server_key_mismatch = 1;
        *flags |= MBEDTLS_X509_BADCERT_OTHER;
    }
    return 0;
}

static int classify(const foundry_tls_session *session, int result)
{
    if (result == MBEDTLS_ERR_SSL_WANT_READ) {
        return FOUNDRY_TLS_WANT_READ;
    }
    if (result == MBEDTLS_ERR_SSL_WANT_WRITE) {
        return FOUNDRY_TLS_WANT_WRITE;
    }
    if (session->carrier_status == FOUNDRY_TLS_IO_EOF || result == MBEDTLS_ERR_SSL_CONN_EOF) {
        return FOUNDRY_TLS_FAILED_CARRIER_EOF;
    }
    if (session->carrier_status == FOUNDRY_TLS_IO_RESET) {
        return FOUNDRY_TLS_FAILED_CARRIER_RESET;
    }
    if (session->carrier_status != 0) {
        return FOUNDRY_TLS_FAILED_CARRIER;
    }
    if (result == MBEDTLS_ERR_X509_CERT_VERIFY_FAILED ||
        result == MBEDTLS_ERR_SSL_NO_CLIENT_CERTIFICATE ||
        result == MBEDTLS_ERR_SSL_BAD_CERTIFICATE) {
        /* Foundry's own two rules are named only when they are the whole story; an
         * untrusted or expired chain is reported as that, with its flags. */
        const uint32_t provider_flags =
            mbedtls_ssl_get_verify_result(&session->ssl) & ~(uint32_t) MBEDTLS_X509_BADCERT_OTHER;
        if (provider_flags == 0 && session->chain_too_long) {
            return FOUNDRY_TLS_FAILED_CHAIN_LENGTH;
        }
        if (provider_flags == 0 && session->server_key_mismatch) {
            return FOUNDRY_TLS_FAILED_SERVER_KEY;
        }
        return FOUNDRY_TLS_FAILED_CERTIFICATE;
    }
    if (result == MBEDTLS_ERR_SSL_FATAL_ALERT_MESSAGE) {
        return FOUNDRY_TLS_FAILED_PEER_ALERT;
    }
    if (is_allocation_failure(result)) {
        return FOUNDRY_TLS_FAILED_MEMORY;
    }
    return FOUNDRY_TLS_FAILED_PROTOCOL;
}

int foundry_tls_civil_time(int64_t fixed_time, int64_t *out_seconds)
{
    const int64_t now = fixed_time != 0 ? fixed_time : (int64_t) time(NULL);

    if (now < FOUNDRY_TLS_TIME_FLOOR) {
        return 0;
    }
    *out_seconds = now;
    return 1;
}

static int set_certificate_time(const foundry_tls_session *session)
{
    int64_t now;

    if (!foundry_tls_civil_time(session->fixed_time, &now)) {
        return 0;
    }
    certificate_time = (mbedtls_time_t) now;
    return 1;
}

int foundry_tls_session_create(
    foundry_tls_credentials *credentials,
    int64_t fixed_time,
    void *carrier,
    foundry_tls_send_fn send,
    foundry_tls_receive_fn receive,
    foundry_tls_session **out_session)
{
    foundry_tls_session *session;
    int result;

    if (out_session == NULL) {
        return FOUNDRY_TLS_FAILED_INTERNAL;
    }
    *out_session = NULL;
    if (credentials == NULL || send == NULL || receive == NULL || fixed_time < 0) {
        return FOUNDRY_TLS_FAILED_INTERNAL;
    }
    session = (foundry_tls_session *) mbedtls_calloc(1, sizeof(*session));
    if (session == NULL) {
        return FOUNDRY_TLS_FAILED_MEMORY;
    }
    mbedtls_ssl_init(&session->ssl);
    session->credentials = credentials;
    session->fixed_time = fixed_time;
    session->carrier = carrier;
    session->send = send;
    session->receive = receive;

    result = mbedtls_ssl_setup(&session->ssl, &credentials->config);
    if (result == 0 && credentials->role == FOUNDRY_TLS_ROLE_CLIENT) {
        result = mbedtls_ssl_set_hostname(&session->ssl, credentials->server_name);
    }
    if (result != 0) {
        foundry_tls_session_destroy(session);
        return is_allocation_failure(result) ? FOUNDRY_TLS_FAILED_MEMORY : FOUNDRY_TLS_FAILED_INTERNAL;
    }
    mbedtls_ssl_set_verify(&session->ssl, verify_certificate, session);
    mbedtls_ssl_set_bio(&session->ssl, session, session_send, session_receive, NULL);
    *out_session = session;
    return FOUNDRY_TLS_DONE;
}

void foundry_tls_session_destroy(foundry_tls_session *session)
{
    if (session == NULL) {
        return;
    }
    mbedtls_ssl_free(&session->ssl);
    mbedtls_platform_zeroize(session, sizeof(*session));
    mbedtls_free(session);
}

int foundry_tls_session_handshake(foundry_tls_session *session, int *out_progressed)
{
    const char *protocol;
    int result;

    *out_progressed = 0;
    if (!set_certificate_time(session)) {
        return FOUNDRY_TLS_FAILED_CLOCK;
    }
    session->progressed = 0;
    result = mbedtls_ssl_handshake(&session->ssl);
    *out_progressed = session->progressed;
    if (result != 0) {
        return classify(session, result);
    }
    /* Completion is not enough: the peer must have been verified, and must have
     * agreed to speak FNET rather than simply not mentioning a protocol. */
    if (!session->have_peer_key || mbedtls_ssl_get_verify_result(&session->ssl) != 0) {
        return FOUNDRY_TLS_FAILED_CERTIFICATE;
    }
    protocol = mbedtls_ssl_get_alpn_protocol(&session->ssl);
    if (protocol == NULL || strcmp(protocol, protocol_name) != 0) {
        return FOUNDRY_TLS_FAILED_PROTOCOL;
    }
    return FOUNDRY_TLS_DONE;
}

int foundry_tls_session_read(
    foundry_tls_session *session,
    uint8_t *bytes,
    size_t capacity,
    size_t *out_length)
{
    int result;

    *out_length = 0;
    result = mbedtls_ssl_read(&session->ssl, bytes, capacity > INT_MAX ? INT_MAX : capacity);
    if (result > 0) {
        *out_length = (size_t) result;
        return FOUNDRY_TLS_DONE;
    }
    if (result == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) {
        return FOUNDRY_TLS_CLOSED;
    }
    if (result == 0) {
        /* The transport ended without a close_notify: truncation, not a close. */
        return FOUNDRY_TLS_FAILED_CARRIER_EOF;
    }
    return classify(session, result);
}

int foundry_tls_session_write(
    foundry_tls_session *session,
    const uint8_t *bytes,
    size_t length,
    size_t *out_length)
{
    int result;

    *out_length = 0;
    result = mbedtls_ssl_write(&session->ssl, bytes, length > INT_MAX ? INT_MAX : length);
    if (result >= 0) {
        *out_length = (size_t) result;
        return FOUNDRY_TLS_DONE;
    }
    return classify(session, result);
}

void foundry_tls_session_close_notify(foundry_tls_session *session)
{
    /* Advisory by design: shutdown is local and bounded, and a peer that is not
     * reading cannot hold it open (networking.md §4). */
    (void) mbedtls_ssl_close_notify(&session->ssl);
}

size_t foundry_tls_session_max_write(const foundry_tls_session *session)
{
    const int limit = mbedtls_ssl_get_max_out_record_payload(&session->ssl);
    return limit > 0 ? (size_t) limit : 0;
}

int foundry_tls_session_certificate_problem(const foundry_tls_session *session)
{
    const uint32_t flags = mbedtls_ssl_get_verify_result(&session->ssl);

    if (flags & MBEDTLS_X509_BADCERT_MISSING) {
        return FOUNDRY_TLS_CERTIFICATE_MISSING;
    }
    if (flags & MBEDTLS_X509_BADCERT_NOT_TRUSTED) {
        return FOUNDRY_TLS_CERTIFICATE_UNTRUSTED;
    }
    if (flags & MBEDTLS_X509_BADCERT_EXPIRED) {
        return FOUNDRY_TLS_CERTIFICATE_EXPIRED;
    }
    if (flags & MBEDTLS_X509_BADCERT_FUTURE) {
        return FOUNDRY_TLS_CERTIFICATE_NOT_YET_VALID;
    }
    if (flags & (MBEDTLS_X509_BADCERT_KEY_USAGE | MBEDTLS_X509_BADCERT_EXT_KEY_USAGE |
                 MBEDTLS_X509_BADCERT_NS_CERT_TYPE)) {
        return FOUNDRY_TLS_CERTIFICATE_WRONG_USAGE;
    }
    if (flags & MBEDTLS_X509_BADCERT_CN_MISMATCH) {
        return FOUNDRY_TLS_CERTIFICATE_WRONG_NAME;
    }
    return FOUNDRY_TLS_CERTIFICATE_REJECTED;
}

int foundry_tls_session_peer_key(const foundry_tls_session *session, uint8_t out_key[FOUNDRY_TLS_KEY_BYTES])
{
    if (!session->have_peer_key) {
        return -1;
    }
    memcpy(out_key, session->peer_key, FOUNDRY_TLS_KEY_BYTES);
    return 0;
}

int foundry_tls_session_valid_until(const foundry_tls_session *session, int64_t *out_seconds)
{
    if (!session->have_peer_key || session->valid_until == 0) {
        return -1;
    }
    *out_seconds = session->valid_until;
    return 0;
}
