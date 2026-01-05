// 中文注释：OQSRAII.h 提供 C 接口，内部使用 C++ RAII 封装 liboqs 的 ML-DSA-65 与 ML-KEM-768
#pragma once

#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// 中文注释：统一的返回码约定（0 表示成功，非 0 表示失败）
#define OQSRAII_SUCCESS 0
#define OQSRAII_FAIL    1

// ========================= ML-DSA-65 =========================

// 中文注释：获取 ML-DSA-65 公钥长度
size_t oqs_raii_mldsa65_public_key_length(void);
// 中文注释：获取 ML-DSA-65 私钥长度
size_t oqs_raii_mldsa65_secret_key_length(void);
// 中文注释：获取 ML-DSA-65 签名长度（最大长度，具体由实现给出）
size_t oqs_raii_mldsa65_signature_length(void);

// 中文注释：生成 ML-DSA-65 密钥对
// 说明：调用方需提前分配好缓冲区，长度使用上述长度函数获取；返回 0 表示成功
int oqs_raii_mldsa65_keypair(unsigned char* pk_out, size_t pk_len,
                             unsigned char* sk_out, size_t sk_len);

// 中文注释：使用 ML-DSA-65 对消息进行签名
// 签名结果写入 sig_out，真实长度返回到 *sig_out_len
int oqs_raii_mldsa65_sign(const unsigned char* msg, size_t msg_len,
                          const unsigned char* sk, size_t sk_len,
                          unsigned char* sig_out, size_t* sig_out_len);

// 中文注释：验证 ML-DSA-65 签名，返回 true 表示验证通过
bool oqs_raii_mldsa65_verify(const unsigned char* msg, size_t msg_len,
                             const unsigned char* sig, size_t sig_len,
                             const unsigned char* pk, size_t pk_len);

// ========================= ML-KEM-768 =========================

// 中文注释：获取 ML-KEM-768 公钥长度
size_t oqs_raii_mlkem768_public_key_length(void);
// 中文注释：获取 ML-KEM-768 私钥长度
size_t oqs_raii_mlkem768_secret_key_length(void);
// 中文注释：获取 ML-KEM-768 密文长度
size_t oqs_raii_mlkem768_ciphertext_length(void);
// 中文注释：获取 ML-KEM-768 共享密钥长度
size_t oqs_raii_mlkem768_shared_secret_length(void);

// 中文注释：生成 ML-KEM-768 密钥对
int oqs_raii_mlkem768_keypair(unsigned char* pk_out, size_t pk_len,
                              unsigned char* sk_out, size_t sk_len);

// 中文注释：使用 ML-KEM-768 进行封装（Encapsulate）
// 说明：输入公钥，输出密文与共享密钥；调用方需提前分配缓冲区
int oqs_raii_mlkem768_encaps(const unsigned char* pk, size_t pk_len,
                             unsigned char* ct_out, size_t ct_len,
                             unsigned char* ss_out, size_t ss_len);

// 中文注释：使用 ML-KEM-768 进行解封装（Decapsulate）
// 说明：输入密文与私钥，输出共享密钥；调用方需提前分配缓冲区
int oqs_raii_mlkem768_decaps(const unsigned char* ct, size_t ct_len,
                             const unsigned char* sk, size_t sk_len,
                             unsigned char* ss_out, size_t ss_len);

#ifdef __cplusplus
}
#endif