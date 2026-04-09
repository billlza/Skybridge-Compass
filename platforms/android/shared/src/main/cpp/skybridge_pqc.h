/*
 * SkyBridge PQC JNI Bridge Header
 * 
 * This header defines the JNI interface for post-quantum cryptographic
 * operations using liboqs. It provides ML-KEM-768 and ML-DSA-65 support
 * for Android applications.
 * 
 * Algorithms:
 * - ML-KEM-768 (FIPS 203): Key Encapsulation Mechanism
 * - ML-DSA-65 (FIPS 204): Digital Signature Algorithm
 */

#ifndef SKYBRIDGE_PQC_H
#define SKYBRIDGE_PQC_H

#include <jni.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * ML-KEM-768 Constants (FIPS 203)
 */
#define MLKEM768_PUBLIC_KEY_SIZE    1184
#define MLKEM768_SECRET_KEY_SIZE    2400
#define MLKEM768_CIPHERTEXT_SIZE    1088
#define MLKEM768_SHARED_SECRET_SIZE 32

/*
 * ML-DSA-65 Constants (FIPS 204)
 */
#define MLDSA65_PUBLIC_KEY_SIZE     1952
#define MLDSA65_SECRET_KEY_SIZE     4032
#define MLDSA65_SIGNATURE_SIZE      3309

/*
 * Check if liboqs is available and properly initialized.
 * 
 * Returns: JNI_TRUE if available, JNI_FALSE otherwise
 */
JNIEXPORT jboolean JNICALL
Java_com_skybridge_compass_shared_crypto_providers_AndroidPQCCryptoProvider_nativeIsAvailable(
    JNIEnv *env,
    jclass clazz
);

/*
 * Generate an ML-KEM-768 key pair.
 * 
 * Returns: byte array containing [public_key || secret_key]
 *          public_key: 1184 bytes
 *          secret_key: 2400 bytes
 */
JNIEXPORT jbyteArray JNICALL
Java_com_skybridge_compass_shared_crypto_providers_AndroidPQCCryptoProvider_nativeMLKEM768KeyGen(
    JNIEnv *env,
    jobject thiz
);

/*
 * Perform ML-KEM-768 encapsulation.
 * 
 * Parameters:
 *   publicKey: 1184-byte public key
 * 
 * Returns: byte array containing [ciphertext || shared_secret]
 *          ciphertext: 1088 bytes
 *          shared_secret: 32 bytes
 */
JNIEXPORT jbyteArray JNICALL
Java_com_skybridge_compass_shared_crypto_providers_AndroidPQCCryptoProvider_nativeMLKEM768Encaps(
    JNIEnv *env,
    jobject thiz,
    jbyteArray publicKey
);

/*
 * Perform ML-KEM-768 decapsulation.
 * 
 * Parameters:
 *   ciphertext: 1088-byte ciphertext from encapsulation
 *   secretKey: 2400-byte secret key
 * 
 * Returns: 32-byte shared secret
 */
JNIEXPORT jbyteArray JNICALL
Java_com_skybridge_compass_shared_crypto_providers_AndroidPQCCryptoProvider_nativeMLKEM768Decaps(
    JNIEnv *env,
    jobject thiz,
    jbyteArray ciphertext,
    jbyteArray secretKey
);

/*
 * Generate an ML-DSA-65 key pair.
 * 
 * Returns: byte array containing [public_key || secret_key]
 *          public_key: 1952 bytes
 *          secret_key: 4032 bytes
 */
JNIEXPORT jbyteArray JNICALL
Java_com_skybridge_compass_shared_crypto_providers_AndroidPQCCryptoProvider_nativeMLDSA65KeyGen(
    JNIEnv *env,
    jobject thiz
);

/*
 * Sign a message using ML-DSA-65.
 * 
 * Parameters:
 *   message: The message to sign
 *   secretKey: 4032-byte secret key
 * 
 * Returns: Signature (approximately 3309 bytes)
 */
JNIEXPORT jbyteArray JNICALL
Java_com_skybridge_compass_shared_crypto_providers_AndroidPQCCryptoProvider_nativeMLDSA65Sign(
    JNIEnv *env,
    jobject thiz,
    jbyteArray message,
    jbyteArray secretKey
);

/*
 * Verify an ML-DSA-65 signature.
 * 
 * Parameters:
 *   message: The original message
 *   signature: The signature to verify
 *   publicKey: 1952-byte public key
 * 
 * Returns: JNI_TRUE if valid, JNI_FALSE otherwise
 */
JNIEXPORT jboolean JNICALL
Java_com_skybridge_compass_shared_crypto_providers_AndroidPQCCryptoProvider_nativeMLDSA65Verify(
    JNIEnv *env,
    jobject thiz,
    jbyteArray message,
    jbyteArray signature,
    jbyteArray publicKey
);

#ifdef __cplusplus
}
#endif

#endif /* SKYBRIDGE_PQC_H */
