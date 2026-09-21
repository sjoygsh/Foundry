/*
 * Disposable TLS identities for the transport proofs (M16 Step 2). Test-only.
 *
 * networking.md §4.1: tests generate disposable identities; no key is ever
 * committed. This file is linked into `engine/tests/transport_streams.zig` and
 * nothing else — it is not an operator tool, and Foundry ships no certificate
 * issuer. Every identity is a fresh P-256 key with fixed validity dates, so a
 * proof that injects a clock gets the same verdict on every machine.
 *
 * Nothing allocated here outlives a call: the provider's allocation hooks are
 * process-wide, and a Transport's accounting must see these calls balance.
 */

#include <stdint.h>
#include <string.h>

#include "mbedtls/asn1.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/ecp.h"
#include "mbedtls/entropy.h"
#include "mbedtls/oid.h"
#include "mbedtls/pk.h"
#include "mbedtls/sha256.h"
#include "mbedtls/x509_crt.h"

#define FOUNDRY_TEST_PEM_BYTES 4096

typedef struct foundry_test_authority {
    char name[128];
    char certificate[FOUNDRY_TEST_PEM_BYTES];
    char private_key[FOUNDRY_TEST_PEM_BYTES];
} foundry_test_authority;

typedef struct foundry_test_identity {
    char certificate[FOUNDRY_TEST_PEM_BYTES];
    char private_key[FOUNDRY_TEST_PEM_BYTES];
    uint8_t key_sha256[32];
} foundry_test_identity;

/* Usage bits for `foundry_test_issue`. */
#define FOUNDRY_TEST_SERVER_AUTH 1
#define FOUNDRY_TEST_CLIENT_AUTH 2

typedef struct random_source {
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context drbg;
} random_source;

static int random_open(random_source *random)
{
    static const unsigned char personalization[] = "foundry-m16-test-identities";
    mbedtls_entropy_init(&random->entropy);
    mbedtls_ctr_drbg_init(&random->drbg);
    return mbedtls_ctr_drbg_seed(
        &random->drbg, mbedtls_entropy_func, &random->entropy,
        personalization, sizeof(personalization) - 1);
}

static void random_close(random_source *random)
{
    mbedtls_ctr_drbg_free(&random->drbg);
    mbedtls_entropy_free(&random->entropy);
}

static int generate_key(mbedtls_pk_context *key, random_source *random)
{
    int result = mbedtls_pk_setup(key, mbedtls_pk_info_from_type(MBEDTLS_PK_ECKEY));
    if (result != 0) {
        return result;
    }
    return mbedtls_ecp_gen_key(
        MBEDTLS_ECP_DP_SECP256R1, mbedtls_pk_ec(*key), mbedtls_ctr_drbg_random, &random->drbg);
}

static int load_key(mbedtls_pk_context *key, const char *pem, random_source *random)
{
    return mbedtls_pk_parse_key(
        key, (const unsigned char *) pem, strlen(pem) + 1, NULL, 0,
        mbedtls_ctr_drbg_random, &random->drbg);
}

static int key_fingerprint(mbedtls_pk_context *key, uint8_t out[32])
{
    unsigned char der[256];
    int length = mbedtls_pk_write_pubkey_der(key, der, sizeof(der));
    if (length < 0) {
        return length;
    }
    return mbedtls_sha256(der + sizeof(der) - (size_t) length, (size_t) length, out, 0);
}

/* One certificate. `issuer_key` NULL means self-signed. */
static int write_certificate(
    char *out,
    mbedtls_pk_context *subject_key,
    const char *subject_name,
    mbedtls_pk_context *issuer_key,
    const char *issuer_name,
    uint8_t serial,
    int is_authority,
    int usage,
    const char *dns_name,
    const char *not_before,
    const char *not_after,
    random_source *random)
{
    mbedtls_x509write_cert writer;
    mbedtls_asn1_sequence server_auth;
    mbedtls_asn1_sequence client_auth;
    mbedtls_asn1_sequence *usages = NULL;
    mbedtls_x509_san_list san;
    const unsigned char serial_bytes[1] = {serial};
    int result;

    mbedtls_x509write_crt_init(&writer);
    mbedtls_x509write_crt_set_version(&writer, MBEDTLS_X509_CRT_VERSION_3);
    mbedtls_x509write_crt_set_md_alg(&writer, MBEDTLS_MD_SHA256);
    mbedtls_x509write_crt_set_subject_key(&writer, subject_key);
    mbedtls_x509write_crt_set_issuer_key(&writer, issuer_key != NULL ? issuer_key : subject_key);

    result = mbedtls_x509write_crt_set_subject_name(&writer, subject_name);
    if (result == 0) {
        result = mbedtls_x509write_crt_set_issuer_name(&writer, issuer_name != NULL ? issuer_name : subject_name);
    }
    if (result == 0) {
        result = mbedtls_x509write_crt_set_serial_raw(&writer, (unsigned char *) serial_bytes, sizeof(serial_bytes));
    }
    if (result == 0) {
        result = mbedtls_x509write_crt_set_validity(&writer, not_before, not_after);
    }
    if (result == 0) {
        result = mbedtls_x509write_crt_set_basic_constraints(&writer, is_authority, -1);
    }
    if (result == 0) {
        result = mbedtls_x509write_crt_set_subject_key_identifier(&writer);
    }
    if (result == 0) {
        result = mbedtls_x509write_crt_set_authority_key_identifier(&writer);
    }
    if (result == 0) {
        result = mbedtls_x509write_crt_set_key_usage(
            &writer,
            is_authority ? (MBEDTLS_X509_KU_KEY_CERT_SIGN | MBEDTLS_X509_KU_CRL_SIGN)
                         : MBEDTLS_X509_KU_DIGITAL_SIGNATURE);
    }
    if (result == 0 && usage != 0) {
        memset(&server_auth, 0, sizeof(server_auth));
        memset(&client_auth, 0, sizeof(client_auth));
        server_auth.buf.tag = MBEDTLS_ASN1_OID;
        server_auth.buf.p = (unsigned char *) MBEDTLS_OID_SERVER_AUTH;
        server_auth.buf.len = MBEDTLS_OID_SIZE(MBEDTLS_OID_SERVER_AUTH);
        client_auth.buf.tag = MBEDTLS_ASN1_OID;
        client_auth.buf.p = (unsigned char *) MBEDTLS_OID_CLIENT_AUTH;
        client_auth.buf.len = MBEDTLS_OID_SIZE(MBEDTLS_OID_CLIENT_AUTH);
        if (usage & FOUNDRY_TEST_SERVER_AUTH) {
            usages = &server_auth;
        }
        if (usage & FOUNDRY_TEST_CLIENT_AUTH) {
            client_auth.next = usages;
            usages = &client_auth;
        }
        result = mbedtls_x509write_crt_set_ext_key_usage(&writer, usages);
    }
    if (result == 0 && dns_name != NULL) {
        memset(&san, 0, sizeof(san));
        san.node.type = MBEDTLS_X509_SAN_DNS_NAME;
        san.node.san.unstructured_name.p = (unsigned char *) dns_name;
        san.node.san.unstructured_name.len = strlen(dns_name);
        result = mbedtls_x509write_crt_set_subject_alternative_name(&writer, &san);
    }
    if (result == 0) {
        result = mbedtls_x509write_crt_pem(
            &writer, (unsigned char *) out, FOUNDRY_TEST_PEM_BYTES,
            mbedtls_ctr_drbg_random, &random->drbg);
    }
    mbedtls_x509write_crt_free(&writer);
    return result;
}

/* A self-signed root, or with `parent` an intermediate authority under it. */
int foundry_test_authority_create(
    foundry_test_authority *out,
    const foundry_test_authority *parent,
    const char *name,
    uint8_t serial)
{
    random_source random;
    mbedtls_pk_context key;
    mbedtls_pk_context parent_key;
    int result;

    memset(out, 0, sizeof(*out));
    if (strlen(name) >= sizeof(out->name)) {
        return -1;
    }
    memcpy(out->name, name, strlen(name));
    mbedtls_pk_init(&key);
    mbedtls_pk_init(&parent_key);
    result = random_open(&random);
    if (result == 0) {
        result = generate_key(&key, &random);
    }
    if (result == 0 && parent != NULL) {
        result = load_key(&parent_key, parent->private_key, &random);
    }
    if (result == 0) {
        result = write_certificate(
            out->certificate, &key, name,
            parent != NULL ? &parent_key : NULL, parent != NULL ? parent->name : NULL,
            serial, 1, 0, NULL, "20260101000000", "20360101000000", &random);
    }
    if (result == 0) {
        result = mbedtls_pk_write_key_pem(&key, (unsigned char *) out->private_key, sizeof(out->private_key));
    }
    mbedtls_pk_free(&parent_key);
    mbedtls_pk_free(&key);
    random_close(&random);
    return result;
}

/* An end-entity identity issued by `authority`. `usage` is FOUNDRY_TEST_* bits, or 0
 * for a certificate with no extendedKeyUsage at all. */
int foundry_test_issue(
    foundry_test_identity *out,
    const foundry_test_authority *authority,
    const char *subject_name,
    const char *dns_name,
    int usage,
    uint8_t serial,
    const char *not_before,
    const char *not_after)
{
    random_source random;
    mbedtls_pk_context key;
    mbedtls_pk_context issuer_key;
    int result;

    memset(out, 0, sizeof(*out));
    mbedtls_pk_init(&key);
    mbedtls_pk_init(&issuer_key);
    result = random_open(&random);
    if (result == 0) {
        result = generate_key(&key, &random);
    }
    if (result == 0) {
        result = load_key(&issuer_key, authority->private_key, &random);
    }
    if (result == 0) {
        result = write_certificate(
            out->certificate, &key, subject_name, &issuer_key, authority->name,
            serial, 0, usage, dns_name, not_before, not_after, &random);
    }
    if (result == 0) {
        result = mbedtls_pk_write_key_pem(&key, (unsigned char *) out->private_key, sizeof(out->private_key));
    }
    if (result == 0) {
        result = key_fingerprint(&key, out->key_sha256);
    }
    mbedtls_pk_free(&issuer_key);
    mbedtls_pk_free(&key);
    random_close(&random);
    return result;
}
