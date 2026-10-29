#include <oqs/oqs.h>

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int probe_kem(const char *algorithm) {
    int result = 1;
    OQS_KEM *kem = OQS_KEM_new(algorithm);
    uint8_t *public_key = NULL;
    uint8_t *secret_key = NULL;
    uint8_t *ciphertext = NULL;
    uint8_t *shared_secret = NULL;
    uint8_t *decapsulated_secret = NULL;

    if (kem == NULL) {
        fprintf(stderr, "required KEM could not be constructed: %s\n", algorithm);
        return result;
    }
    public_key = OQS_MEM_malloc(kem->length_public_key);
    secret_key = OQS_MEM_malloc(kem->length_secret_key);
    ciphertext = OQS_MEM_malloc(kem->length_ciphertext);
    shared_secret = OQS_MEM_malloc(kem->length_shared_secret);
    decapsulated_secret = OQS_MEM_malloc(kem->length_shared_secret);
    if (public_key == NULL || secret_key == NULL || ciphertext == NULL ||
        shared_secret == NULL || decapsulated_secret == NULL) {
        fprintf(stderr, "KEM probe allocation failed: %s\n", algorithm);
        goto cleanup;
    }
    if (OQS_KEM_keypair(kem, public_key, secret_key) != OQS_SUCCESS ||
        OQS_KEM_encaps(kem, ciphertext, shared_secret, public_key) != OQS_SUCCESS ||
        OQS_KEM_decaps(kem, decapsulated_secret, ciphertext, secret_key) != OQS_SUCCESS ||
        memcmp(shared_secret, decapsulated_secret, kem->length_shared_secret) != 0) {
        fprintf(stderr, "KEM round trip failed: %s\n", algorithm);
        goto cleanup;
    }

    ciphertext[0] ^= UINT8_C(1);
    const OQS_STATUS tampered_status =
        OQS_KEM_decaps(kem, decapsulated_secret, ciphertext, secret_key);
    if (tampered_status == OQS_SUCCESS &&
        memcmp(shared_secret, decapsulated_secret, kem->length_shared_secret) == 0) {
        fprintf(stderr, "tampered KEM ciphertext reproduced the valid secret: %s\n", algorithm);
        goto cleanup;
    }

    result = 0;

cleanup:
    OQS_MEM_insecure_free(public_key);
    if (secret_key != NULL) {
        OQS_MEM_secure_free(secret_key, kem->length_secret_key);
    }
    OQS_MEM_insecure_free(ciphertext);
    if (shared_secret != NULL) {
        OQS_MEM_secure_free(shared_secret, kem->length_shared_secret);
    }
    if (decapsulated_secret != NULL) {
        OQS_MEM_secure_free(decapsulated_secret, kem->length_shared_secret);
    }
    OQS_KEM_free(kem);
    return result;
}

static int probe_signature(const char *algorithm) {
    static const uint8_t original_message[] = "SkyBridge liboqs runtime probe";
    int result = 1;
    OQS_SIG *signature_algorithm = OQS_SIG_new(algorithm);
    uint8_t message[sizeof(original_message)];
    uint8_t *public_key = NULL;
    uint8_t *secret_key = NULL;
    uint8_t *signature = NULL;
    size_t signature_length = 0;

    if (signature_algorithm == NULL) {
        fprintf(stderr, "required signature could not be constructed: %s\n", algorithm);
        return result;
    }
    memcpy(message, original_message, sizeof(message));
    public_key = OQS_MEM_malloc(signature_algorithm->length_public_key);
    secret_key = OQS_MEM_malloc(signature_algorithm->length_secret_key);
    signature = OQS_MEM_malloc(signature_algorithm->length_signature);
    if (public_key == NULL || secret_key == NULL || signature == NULL) {
        fprintf(stderr, "signature probe allocation failed: %s\n", algorithm);
        goto cleanup;
    }
    if (OQS_SIG_keypair(signature_algorithm, public_key, secret_key) != OQS_SUCCESS ||
        OQS_SIG_sign(
            signature_algorithm,
            signature,
            &signature_length,
            message,
            sizeof(message),
            secret_key
        ) != OQS_SUCCESS ||
        signature_length == 0 || signature_length > signature_algorithm->length_signature ||
        OQS_SIG_verify(
            signature_algorithm,
            message,
            sizeof(message),
            signature,
            signature_length,
            public_key
        ) != OQS_SUCCESS) {
        fprintf(stderr, "signature round trip failed: %s\n", algorithm);
        goto cleanup;
    }

    message[0] ^= UINT8_C(1);
    if (OQS_SIG_verify(
            signature_algorithm,
            message,
            sizeof(message),
            signature,
            signature_length,
            public_key
        ) == OQS_SUCCESS) {
        fprintf(stderr, "signature accepted a tampered message: %s\n", algorithm);
        goto cleanup;
    }
    message[0] ^= UINT8_C(1);
    signature[0] ^= UINT8_C(1);
    if (OQS_SIG_verify(
            signature_algorithm,
            message,
            sizeof(message),
            signature,
            signature_length,
            public_key
        ) == OQS_SUCCESS) {
        fprintf(stderr, "signature accepted tampered signature bytes: %s\n", algorithm);
        goto cleanup;
    }

    result = 0;

cleanup:
    OQS_MEM_insecure_free(public_key);
    if (secret_key != NULL) {
        OQS_MEM_secure_free(secret_key, signature_algorithm->length_secret_key);
    }
    OQS_MEM_insecure_free(signature);
    OQS_SIG_free(signature_algorithm);
    return result;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fputs("expected exact liboqs version argument\n", stderr);
        return 64;
    }
    OQS_init();
    const char *actual_version = OQS_version();
    if (actual_version == NULL || strcmp(actual_version, argv[1]) != 0) {
        fprintf(stderr, "unexpected liboqs version: %s\n", actual_version != NULL ? actual_version : "<null>");
        OQS_destroy();
        return 1;
    }

    OQS_KEM *unexpected_kem = OQS_KEM_new("SkyBridge-invalid-KEM");
    OQS_SIG *unexpected_signature = OQS_SIG_new("SkyBridge-invalid-signature");
    if (unexpected_kem != NULL || unexpected_signature != NULL) {
        fputs("liboqs accepted an unknown algorithm identifier\n", stderr);
        OQS_KEM_free(unexpected_kem);
        OQS_SIG_free(unexpected_signature);
        OQS_destroy();
        return 2;
    }

    const char *required_kems[] = {OQS_KEM_alg_ml_kem_768, OQS_KEM_alg_ml_kem_1024};
    size_t enabled_kem_count = 0;
    for (int index = 0; index < OQS_KEM_alg_count(); ++index) {
        const char *identifier = OQS_KEM_alg_identifier((size_t)index);
        if (identifier == NULL) {
            fputs("liboqs returned a null KEM identifier\n", stderr);
            OQS_destroy();
            return 3;
        }
        if (OQS_KEM_alg_is_enabled(identifier) == 1) {
            ++enabled_kem_count;
        }
    }
    if (enabled_kem_count != sizeof(required_kems) / sizeof(required_kems[0])) {
        fprintf(stderr, "unexpected enabled KEM count: %zu\n", enabled_kem_count);
        OQS_destroy();
        return 3;
    }
    for (size_t index = 0; index < sizeof(required_kems) / sizeof(required_kems[0]); ++index) {
        if (OQS_KEM_alg_is_enabled(required_kems[index]) != 1) {
            fprintf(stderr, "required KEM is disabled: %s\n", required_kems[index]);
            OQS_destroy();
            return 3;
        }
        OQS_KEM *kem = OQS_KEM_new(required_kems[index]);
        if (kem == NULL || kem->length_public_key == 0 || kem->length_secret_key == 0 ||
            kem->length_ciphertext == 0 || kem->length_shared_secret == 0) {
            fprintf(stderr, "required KEM metadata is invalid: %s\n", required_kems[index]);
            OQS_KEM_free(kem);
            OQS_destroy();
            return 4;
        }
        OQS_KEM_free(kem);
        if (probe_kem(required_kems[index]) != 0) {
            OQS_destroy();
            return 5;
        }
    }

    const char *required_signatures[] = {OQS_SIG_alg_ml_dsa_65, OQS_SIG_alg_ml_dsa_87};
    size_t enabled_signature_count = 0;
    for (int index = 0; index < OQS_SIG_alg_count(); ++index) {
        const char *identifier = OQS_SIG_alg_identifier((size_t)index);
        if (identifier == NULL) {
            fputs("liboqs returned a null signature identifier\n", stderr);
            OQS_destroy();
            return 6;
        }
        if (OQS_SIG_alg_is_enabled(identifier) == 1) {
            ++enabled_signature_count;
        }
    }
    if (enabled_signature_count !=
        sizeof(required_signatures) / sizeof(required_signatures[0])) {
        fprintf(stderr, "unexpected enabled signature count: %zu\n", enabled_signature_count);
        OQS_destroy();
        return 6;
    }
    for (size_t index = 0; index < sizeof(required_signatures) / sizeof(required_signatures[0]); ++index) {
        if (OQS_SIG_alg_is_enabled(required_signatures[index]) != 1) {
            fprintf(stderr, "required signature is disabled: %s\n", required_signatures[index]);
            OQS_destroy();
            return 6;
        }
        OQS_SIG *signature = OQS_SIG_new(required_signatures[index]);
        if (signature == NULL || signature->length_public_key == 0 ||
            signature->length_secret_key == 0 || signature->length_signature == 0) {
            fprintf(stderr, "required signature metadata is invalid: %s\n", required_signatures[index]);
            OQS_SIG_free(signature);
            OQS_destroy();
            return 7;
        }
        OQS_SIG_free(signature);
        if (probe_signature(required_signatures[index]) != 0) {
            OQS_destroy();
            return 8;
        }
    }
    OQS_destroy();
    return 0;
}
