/*
 * SkyBridge PQC JNI Bridge Implementation
 * 
 * This file implements the JNI interface for post-quantum cryptographic
 * operations using liboqs. It provides ML-KEM-768 and ML-DSA-65 support.
 * 
 * When liboqs is not available (LIBOQS_AVAILABLE=0), fallback JNI entry
 * points are provided that return appropriate error values.
 */

#include "skybridge_pqc.h"
#include <stdlib.h>
#include <string.h>
#include <android/log.h>

#if LIBOQS_AVAILABLE
#include <oqs/oqs.h>
#endif

#define LOG_TAG "SkyBridgePQC"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* Helper function to throw a Java exception */
static void throw_exception(JNIEnv *env, const char *class_name, const char *message) {
    jclass exception_class = (*env)->FindClass(env, class_name);
    if (exception_class != NULL) {
        (*env)->ThrowNew(env, exception_class, message);
        (*env)->DeleteLocalRef(env, exception_class);
    }
}

/* Check if liboqs is available */
JNIEXPORT jboolean JNICALL
Java_com_skybridge_compass_shared_crypto_providers_AndroidPQCCryptoProvider_nativeIsAvailable(
    JNIEnv *env,
    jclass clazz
) {
    (void)env;
    (void)clazz;
    
#if LIBOQS_AVAILABLE
    /* Check if ML-KEM-768 is enabled */
    if (!OQS_KEM_alg_is_enabled(OQS_KEM_alg_ml_kem_768)) {
        LOGI("ML-KEM-768 is not enabled in liboqs");
        return JNI_FALSE;
    }
    
    /* Check if ML-DSA-65 is enabled */
    if (!OQS_SIG_alg_is_enabled(OQS_SIG_alg_ml_dsa_65)) {
        LOGI("ML-DSA-65 is not enabled in liboqs");
        return JNI_FALSE;
    }
    
    LOGI("liboqs PQC algorithms available");
    return JNI_TRUE;
#else
    LOGI("liboqs not compiled - PQC native support unavailable");
    return JNI_FALSE;
#endif
}

/* Generate ML-KEM-768 key pair */
JNIEXPORT jbyteArray JNICALL
Java_com_skybridge_compass_shared_crypto_providers_AndroidPQCCryptoProvider_nativeMLKEM768KeyGen(
    JNIEnv *env,
    jobject thiz
) {
    (void)thiz;
    
#if LIBOQS_AVAILABLE
    OQS_KEM *kem = OQS_KEM_new(OQS_KEM_alg_ml_kem_768);
    if (kem == NULL) {
        throw_exception(env, "java/lang/UnsupportedOperationException",
                       "Failed to initialize ML-KEM-768");
        return NULL;
    }
    
    uint8_t *public_key = malloc(kem->length_public_key);
    uint8_t *secret_key = malloc(kem->length_secret_key);
    
    if (public_key == NULL || secret_key == NULL) {
        free(public_key);
        free(secret_key);
        OQS_KEM_free(kem);
        throw_exception(env, "java/lang/OutOfMemoryError", "Failed to allocate key buffers");
        return NULL;
    }
    
    OQS_STATUS status = OQS_KEM_keypair(kem, public_key, secret_key);
    if (status != OQS_SUCCESS) {
        free(public_key);
        free(secret_key);
        OQS_KEM_free(kem);
        throw_exception(env, "java/lang/UnsupportedOperationException",
                       "ML-KEM-768 key generation failed");
        return NULL;
    }
    
    size_t total_size = kem->length_public_key + kem->length_secret_key;
    jbyteArray result = (*env)->NewByteArray(env, (jsize)total_size);
    if (result == NULL) {
        free(public_key);
        free(secret_key);
        OQS_KEM_free(kem);
        return NULL;
    }
    
    (*env)->SetByteArrayRegion(env, result, 0, (jsize)kem->length_public_key, (jbyte*)public_key);
    (*env)->SetByteArrayRegion(env, result, (jsize)kem->length_public_key, 
                               (jsize)kem->length_secret_key, (jbyte*)secret_key);
    
    OQS_MEM_secure_free(secret_key, kem->length_secret_key);
    free(public_key);
    OQS_KEM_free(kem);
    
    return result;
#else
    throw_exception(env, "java/lang/UnsupportedOperationException",
                   "liboqs not available - native PQC provider unavailable");
    return NULL;
#endif
}

/* ML-KEM-768 encapsulation */
JNIEXPORT jbyteArray JNICALL
Java_com_skybridge_compass_shared_crypto_providers_AndroidPQCCryptoProvider_nativeMLKEM768Encaps(
    JNIEnv *env,
    jobject thiz,
    jbyteArray publicKey
) {
    (void)thiz;
    (void)publicKey;
    
#if LIBOQS_AVAILABLE
    OQS_KEM *kem = OQS_KEM_new(OQS_KEM_alg_ml_kem_768);
    if (kem == NULL) {
        throw_exception(env, "java/lang/UnsupportedOperationException",
                       "Failed to initialize ML-KEM-768");
        return NULL;
    }
    
    jsize pk_len = (*env)->GetArrayLength(env, publicKey);
    if (pk_len != (jsize)kem->length_public_key) {
        OQS_KEM_free(kem);
        throw_exception(env, "java/lang/IllegalArgumentException",
                       "Invalid public key size for ML-KEM-768");
        return NULL;
    }
    
    jbyte *pk_bytes = (*env)->GetByteArrayElements(env, publicKey, NULL);
    if (pk_bytes == NULL) {
        OQS_KEM_free(kem);
        return NULL;
    }
    
    uint8_t *ciphertext = malloc(kem->length_ciphertext);
    uint8_t *shared_secret = malloc(kem->length_shared_secret);
    
    if (ciphertext == NULL || shared_secret == NULL) {
        free(ciphertext);
        free(shared_secret);
        (*env)->ReleaseByteArrayElements(env, publicKey, pk_bytes, JNI_ABORT);
        OQS_KEM_free(kem);
        throw_exception(env, "java/lang/OutOfMemoryError", "Failed to allocate buffers");
        return NULL;
    }
    
    OQS_STATUS status = OQS_KEM_encaps(kem, ciphertext, shared_secret, (uint8_t*)pk_bytes);
    (*env)->ReleaseByteArrayElements(env, publicKey, pk_bytes, JNI_ABORT);
    
    if (status != OQS_SUCCESS) {
        free(ciphertext);
        OQS_MEM_secure_free(shared_secret, kem->length_shared_secret);
        OQS_KEM_free(kem);
        throw_exception(env, "java/lang/UnsupportedOperationException",
                       "ML-KEM-768 encapsulation failed");
        return NULL;
    }
    
    size_t total_size = kem->length_ciphertext + kem->length_shared_secret;
    jbyteArray result = (*env)->NewByteArray(env, (jsize)total_size);
    if (result == NULL) {
        free(ciphertext);
        OQS_MEM_secure_free(shared_secret, kem->length_shared_secret);
        OQS_KEM_free(kem);
        return NULL;
    }
    
    (*env)->SetByteArrayRegion(env, result, 0, (jsize)kem->length_ciphertext, (jbyte*)ciphertext);
    (*env)->SetByteArrayRegion(env, result, (jsize)kem->length_ciphertext,
                               (jsize)kem->length_shared_secret, (jbyte*)shared_secret);
    
    free(ciphertext);
    OQS_MEM_secure_free(shared_secret, kem->length_shared_secret);
    OQS_KEM_free(kem);
    
    return result;
#else
    throw_exception(env, "java/lang/UnsupportedOperationException",
                   "liboqs not available - native PQC provider unavailable");
    return NULL;
#endif
}

/* ML-KEM-768 decapsulation */
JNIEXPORT jbyteArray JNICALL
Java_com_skybridge_compass_shared_crypto_providers_AndroidPQCCryptoProvider_nativeMLKEM768Decaps(
    JNIEnv *env,
    jobject thiz,
    jbyteArray ciphertext,
    jbyteArray secretKey
) {
    (void)thiz;
    (void)ciphertext;
    (void)secretKey;
    
#if LIBOQS_AVAILABLE
    OQS_KEM *kem = OQS_KEM_new(OQS_KEM_alg_ml_kem_768);
    if (kem == NULL) {
        throw_exception(env, "java/lang/UnsupportedOperationException",
                       "Failed to initialize ML-KEM-768");
        return NULL;
    }
    
    jsize ct_len = (*env)->GetArrayLength(env, ciphertext);
    jsize sk_len = (*env)->GetArrayLength(env, secretKey);
    
    if (ct_len != (jsize)kem->length_ciphertext) {
        OQS_KEM_free(kem);
        throw_exception(env, "java/lang/IllegalArgumentException",
                       "Invalid ciphertext size for ML-KEM-768");
        return NULL;
    }
    
    if (sk_len != (jsize)kem->length_secret_key) {
        OQS_KEM_free(kem);
        throw_exception(env, "java/lang/IllegalArgumentException",
                       "Invalid secret key size for ML-KEM-768");
        return NULL;
    }
    
    jbyte *ct_bytes = (*env)->GetByteArrayElements(env, ciphertext, NULL);
    jbyte *sk_bytes = (*env)->GetByteArrayElements(env, secretKey, NULL);
    
    if (ct_bytes == NULL || sk_bytes == NULL) {
        if (ct_bytes) (*env)->ReleaseByteArrayElements(env, ciphertext, ct_bytes, JNI_ABORT);
        if (sk_bytes) (*env)->ReleaseByteArrayElements(env, secretKey, sk_bytes, JNI_ABORT);
        OQS_KEM_free(kem);
        return NULL;
    }
    
    uint8_t *shared_secret = malloc(kem->length_shared_secret);
    if (shared_secret == NULL) {
        (*env)->ReleaseByteArrayElements(env, ciphertext, ct_bytes, JNI_ABORT);
        (*env)->ReleaseByteArrayElements(env, secretKey, sk_bytes, JNI_ABORT);
        OQS_KEM_free(kem);
        throw_exception(env, "java/lang/OutOfMemoryError", "Failed to allocate buffer");
        return NULL;
    }
    
    OQS_STATUS status = OQS_KEM_decaps(kem, shared_secret, (uint8_t*)ct_bytes, (uint8_t*)sk_bytes);
    
    (*env)->ReleaseByteArrayElements(env, ciphertext, ct_bytes, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, secretKey, sk_bytes, JNI_ABORT);
    
    if (status != OQS_SUCCESS) {
        OQS_MEM_secure_free(shared_secret, kem->length_shared_secret);
        OQS_KEM_free(kem);
        throw_exception(env, "java/lang/UnsupportedOperationException",
                       "ML-KEM-768 decapsulation failed");
        return NULL;
    }
    
    jbyteArray result = (*env)->NewByteArray(env, (jsize)kem->length_shared_secret);
    if (result != NULL) {
        (*env)->SetByteArrayRegion(env, result, 0, (jsize)kem->length_shared_secret, 
                                   (jbyte*)shared_secret);
    }
    
    OQS_MEM_secure_free(shared_secret, kem->length_shared_secret);
    OQS_KEM_free(kem);
    
    return result;
#else
    throw_exception(env, "java/lang/UnsupportedOperationException",
                   "liboqs not available - native PQC provider unavailable");
    return NULL;
#endif
}

/* Generate ML-DSA-65 key pair */
JNIEXPORT jbyteArray JNICALL
Java_com_skybridge_compass_shared_crypto_providers_AndroidPQCCryptoProvider_nativeMLDSA65KeyGen(
    JNIEnv *env,
    jobject thiz
) {
    (void)thiz;
    
#if LIBOQS_AVAILABLE
    OQS_SIG *sig = OQS_SIG_new(OQS_SIG_alg_ml_dsa_65);
    if (sig == NULL) {
        throw_exception(env, "java/lang/UnsupportedOperationException",
                       "Failed to initialize ML-DSA-65");
        return NULL;
    }
    
    uint8_t *public_key = malloc(sig->length_public_key);
    uint8_t *secret_key = malloc(sig->length_secret_key);
    
    if (public_key == NULL || secret_key == NULL) {
        free(public_key);
        free(secret_key);
        OQS_SIG_free(sig);
        throw_exception(env, "java/lang/OutOfMemoryError", "Failed to allocate key buffers");
        return NULL;
    }
    
    OQS_STATUS status = OQS_SIG_keypair(sig, public_key, secret_key);
    if (status != OQS_SUCCESS) {
        free(public_key);
        OQS_MEM_secure_free(secret_key, sig->length_secret_key);
        OQS_SIG_free(sig);
        throw_exception(env, "java/lang/UnsupportedOperationException",
                       "ML-DSA-65 key generation failed");
        return NULL;
    }
    
    size_t total_size = sig->length_public_key + sig->length_secret_key;
    jbyteArray result = (*env)->NewByteArray(env, (jsize)total_size);
    if (result == NULL) {
        free(public_key);
        OQS_MEM_secure_free(secret_key, sig->length_secret_key);
        OQS_SIG_free(sig);
        return NULL;
    }
    
    (*env)->SetByteArrayRegion(env, result, 0, (jsize)sig->length_public_key, (jbyte*)public_key);
    (*env)->SetByteArrayRegion(env, result, (jsize)sig->length_public_key,
                               (jsize)sig->length_secret_key, (jbyte*)secret_key);
    
    free(public_key);
    OQS_MEM_secure_free(secret_key, sig->length_secret_key);
    OQS_SIG_free(sig);
    
    return result;
#else
    throw_exception(env, "java/lang/UnsupportedOperationException",
                   "liboqs not available - native PQC provider unavailable");
    return NULL;
#endif
}

/* ML-DSA-65 sign */
JNIEXPORT jbyteArray JNICALL
Java_com_skybridge_compass_shared_crypto_providers_AndroidPQCCryptoProvider_nativeMLDSA65Sign(
    JNIEnv *env,
    jobject thiz,
    jbyteArray message,
    jbyteArray secretKey
) {
    (void)thiz;
    (void)message;
    (void)secretKey;
    
#if LIBOQS_AVAILABLE
    OQS_SIG *sig = OQS_SIG_new(OQS_SIG_alg_ml_dsa_65);
    if (sig == NULL) {
        throw_exception(env, "java/lang/UnsupportedOperationException",
                       "Failed to initialize ML-DSA-65");
        return NULL;
    }
    
    jsize sk_len = (*env)->GetArrayLength(env, secretKey);
    if (sk_len != (jsize)sig->length_secret_key) {
        OQS_SIG_free(sig);
        throw_exception(env, "java/lang/IllegalArgumentException",
                       "Invalid secret key size for ML-DSA-65");
        return NULL;
    }
    
    jsize msg_len = (*env)->GetArrayLength(env, message);
    jbyte *msg_bytes = (*env)->GetByteArrayElements(env, message, NULL);
    jbyte *sk_bytes = (*env)->GetByteArrayElements(env, secretKey, NULL);
    
    if (msg_bytes == NULL || sk_bytes == NULL) {
        if (msg_bytes) (*env)->ReleaseByteArrayElements(env, message, msg_bytes, JNI_ABORT);
        if (sk_bytes) (*env)->ReleaseByteArrayElements(env, secretKey, sk_bytes, JNI_ABORT);
        OQS_SIG_free(sig);
        return NULL;
    }
    
    uint8_t *signature = malloc(sig->length_signature);
    size_t sig_len = 0;
    
    if (signature == NULL) {
        (*env)->ReleaseByteArrayElements(env, message, msg_bytes, JNI_ABORT);
        (*env)->ReleaseByteArrayElements(env, secretKey, sk_bytes, JNI_ABORT);
        OQS_SIG_free(sig);
        throw_exception(env, "java/lang/OutOfMemoryError", "Failed to allocate signature buffer");
        return NULL;
    }
    
    OQS_STATUS status = OQS_SIG_sign(sig, signature, &sig_len, 
                                     (uint8_t*)msg_bytes, (size_t)msg_len,
                                     (uint8_t*)sk_bytes);
    
    (*env)->ReleaseByteArrayElements(env, message, msg_bytes, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, secretKey, sk_bytes, JNI_ABORT);
    
    if (status != OQS_SUCCESS) {
        free(signature);
        OQS_SIG_free(sig);
        throw_exception(env, "java/lang/UnsupportedOperationException",
                       "ML-DSA-65 signing failed");
        return NULL;
    }
    
    jbyteArray result = (*env)->NewByteArray(env, (jsize)sig_len);
    if (result != NULL) {
        (*env)->SetByteArrayRegion(env, result, 0, (jsize)sig_len, (jbyte*)signature);
    }
    
    free(signature);
    OQS_SIG_free(sig);
    
    return result;
#else
    throw_exception(env, "java/lang/UnsupportedOperationException",
                   "liboqs not available - native PQC provider unavailable");
    return NULL;
#endif
}

/* ML-DSA-65 verify */
JNIEXPORT jboolean JNICALL
Java_com_skybridge_compass_shared_crypto_providers_AndroidPQCCryptoProvider_nativeMLDSA65Verify(
    JNIEnv *env,
    jobject thiz,
    jbyteArray message,
    jbyteArray signature,
    jbyteArray publicKey
) {
    (void)thiz;
    (void)message;
    (void)signature;
    (void)publicKey;
    
#if LIBOQS_AVAILABLE
    OQS_SIG *sig = OQS_SIG_new(OQS_SIG_alg_ml_dsa_65);
    if (sig == NULL) {
        throw_exception(env, "java/lang/UnsupportedOperationException",
                       "Failed to initialize ML-DSA-65");
        return JNI_FALSE;
    }
    
    jsize pk_len = (*env)->GetArrayLength(env, publicKey);
    if (pk_len != (jsize)sig->length_public_key) {
        OQS_SIG_free(sig);
        throw_exception(env, "java/lang/IllegalArgumentException",
                       "Invalid public key size for ML-DSA-65");
        return JNI_FALSE;
    }
    
    jsize msg_len = (*env)->GetArrayLength(env, message);
    jsize sig_len = (*env)->GetArrayLength(env, signature);
    
    jbyte *msg_bytes = (*env)->GetByteArrayElements(env, message, NULL);
    jbyte *sig_bytes = (*env)->GetByteArrayElements(env, signature, NULL);
    jbyte *pk_bytes = (*env)->GetByteArrayElements(env, publicKey, NULL);
    
    if (msg_bytes == NULL || sig_bytes == NULL || pk_bytes == NULL) {
        if (msg_bytes) (*env)->ReleaseByteArrayElements(env, message, msg_bytes, JNI_ABORT);
        if (sig_bytes) (*env)->ReleaseByteArrayElements(env, signature, sig_bytes, JNI_ABORT);
        if (pk_bytes) (*env)->ReleaseByteArrayElements(env, publicKey, pk_bytes, JNI_ABORT);
        OQS_SIG_free(sig);
        return JNI_FALSE;
    }
    
    OQS_STATUS status = OQS_SIG_verify(sig, 
                                       (uint8_t*)msg_bytes, (size_t)msg_len,
                                       (uint8_t*)sig_bytes, (size_t)sig_len,
                                       (uint8_t*)pk_bytes);
    
    (*env)->ReleaseByteArrayElements(env, message, msg_bytes, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, signature, sig_bytes, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, publicKey, pk_bytes, JNI_ABORT);
    OQS_SIG_free(sig);
    
    return (status == OQS_SUCCESS) ? JNI_TRUE : JNI_FALSE;
#else
    throw_exception(env, "java/lang/UnsupportedOperationException",
                   "liboqs not available - native PQC provider unavailable");
    return JNI_FALSE;
#endif
}
