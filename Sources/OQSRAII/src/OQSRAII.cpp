// 中文注释：OQSRAII.cpp 使用 C++ RAII 封装 liboqs，并提供 C 接口给 Swift 调用

#include <vector>
#include <cstddef>
#include <cstdint>
#include <cstring>

#include <oqs/oqs.h>

#include "../include/OQSRAII.h"

// ========================= 安全清零工具 =========================
// 中文注释：在析构或敏感数据生命周期结束时，对内存进行安全清零，避免编译器优化导致清零无效
static void secure_memzero(void* p, size_t n) {
    if (p == nullptr || n == 0) return;
#if defined(__STDC_LIB_EXT1__)
 // 中文注释：优先使用 C11 的 memset_s
    memset_s(p, n, 0, n);
#else
 // 中文注释：退化实现，使用 volatile 指针避免优化
    volatile unsigned char* vp = reinterpret_cast<volatile unsigned char*>(p);
    for (size_t i = 0; i < n; ++i) vp[i] = 0;
#endif
}

static bool readonly_buffer_valid(const unsigned char* p, size_t n) {
    return (p != nullptr) || (n == 0);
}

static bool writable_buffer_valid(unsigned char* p, size_t n) {
    return (p != nullptr) || (n == 0);
}

static void secure_wipe_output(unsigned char* p, size_t n) {
    secure_memzero(p, n);
}

// ========================= OQS 初始化守卫 =========================
// 中文注释：确保 OQS_init 只调用一次，避免重复初始化开销
struct OQSInitGuard {
    OQSInitGuard() { OQS_init(); }
    ~OQSInitGuard() {}
};

static OQSInitGuard& oqs_guard() {
    static OQSInitGuard g;
    return g;
}

// ========================= 安全缓冲区 =========================
// 中文注释：RAII 安全缓冲区，析构自动清零
class SecureBuffer {
public:
    explicit SecureBuffer(size_t n = 0) : buf_(n) {}
    ~SecureBuffer() { secure_memzero(buf_.data(), buf_.size()); }
    unsigned char* data() { return buf_.data(); }
    const unsigned char* data() const { return buf_.data(); }
    size_t size() const { return buf_.size(); }
    void resize(size_t n) { buf_.resize(n); }
private:
    std::vector<unsigned char> buf_;
};

// ========================= ML-DSA-65 RAII 封装 =========================
class MlDsa65 {
public:
    MlDsa65() { oqs_guard(); sig_ = OQS_SIG_new(OQS_SIG_alg_ml_dsa_65); }
    ~MlDsa65() { if (sig_) OQS_SIG_free(sig_); }
    size_t public_key_length() const { return sig_ ? sig_->length_public_key : 0; }
    size_t secret_key_length() const { return sig_ ? sig_->length_secret_key : 0; }
    size_t signature_length() const { return sig_ ? sig_->length_signature : 0; }
    int keypair(unsigned char* pk, size_t pk_len, unsigned char* sk, size_t sk_len) const {
        if (!sig_) return OQSRAII_FAIL;
        const size_t expected_pk_len = public_key_length();
        const size_t expected_sk_len = secret_key_length();
        if (!writable_buffer_valid(pk, pk_len) || !writable_buffer_valid(sk, sk_len)) return OQSRAII_FAIL;
        if (pk_len < expected_pk_len || sk_len < expected_sk_len) return OQSRAII_FAIL;
        OQS_STATUS rc = OQS_SIG_keypair(sig_, pk, sk);
        if (rc != OQS_SUCCESS) {
            secure_wipe_output(pk, pk_len);
            secure_wipe_output(sk, sk_len);
        }
        return rc == OQS_SUCCESS ? OQSRAII_SUCCESS : OQSRAII_FAIL;
    }
    int sign(const unsigned char* msg, size_t msg_len,
             const unsigned char* sk, size_t sk_len,
             unsigned char* sig_out, size_t* sig_out_len) const {
        if (!sig_) return OQSRAII_FAIL;
        if (!sig_out_len) return OQSRAII_FAIL;
        const size_t max_sig = signature_length();
        if (max_sig == 0) return OQSRAII_FAIL;
        if (!readonly_buffer_valid(msg, msg_len) || !readonly_buffer_valid(sk, sk_len)) {
            *sig_out_len = 0;
            return OQSRAII_FAIL;
        }
        if (!writable_buffer_valid(sig_out, *sig_out_len)) {
            *sig_out_len = 0;
            return OQSRAII_FAIL;
        }
        if (sk_len < secret_key_length() || *sig_out_len < max_sig) {
            *sig_out_len = 0;
            return OQSRAII_FAIL;
        }
        OQS_STATUS rc = OQS_SIG_sign(sig_, sig_out, sig_out_len, msg, msg_len, sk);
        if (rc != OQS_SUCCESS) {
            secure_wipe_output(sig_out, max_sig);
            *sig_out_len = 0;
        }
        return rc == OQS_SUCCESS ? OQSRAII_SUCCESS : OQSRAII_FAIL;
    }
    bool verify(const unsigned char* msg, size_t msg_len,
                const unsigned char* sig, size_t sig_len,
                const unsigned char* pk, size_t pk_len) const {
        if (!sig_) return false;
        if (!readonly_buffer_valid(msg, msg_len) || !readonly_buffer_valid(sig, sig_len) || !readonly_buffer_valid(pk, pk_len)) return false;
        if (pk_len < public_key_length()) return false;
        OQS_STATUS rc = OQS_SIG_verify(sig_, msg, msg_len, sig, sig_len, pk);
        return rc == OQS_SUCCESS;
    }
private:
    OQS_SIG* sig_ = nullptr;
};

// ========================= ML-KEM-768 RAII 封装 =========================
class MlKem768 {
public:
    MlKem768() { oqs_guard(); kem_ = OQS_KEM_new(OQS_KEM_alg_ml_kem_768); }
    ~MlKem768() { if (kem_) OQS_KEM_free(kem_); }
    size_t public_key_length() const { return kem_ ? kem_->length_public_key : 0; }
    size_t secret_key_length() const { return kem_ ? kem_->length_secret_key : 0; }
    size_t ciphertext_length() const { return kem_ ? kem_->length_ciphertext : 0; }
    size_t shared_secret_length() const { return kem_ ? kem_->length_shared_secret : 0; }
    int keypair(unsigned char* pk, size_t pk_len, unsigned char* sk, size_t sk_len) const {
        if (!kem_) return OQSRAII_FAIL;
        const size_t expected_pk_len = public_key_length();
        const size_t expected_sk_len = secret_key_length();
        if (!writable_buffer_valid(pk, pk_len) || !writable_buffer_valid(sk, sk_len)) return OQSRAII_FAIL;
        if (pk_len < expected_pk_len || sk_len < expected_sk_len) return OQSRAII_FAIL;
        OQS_STATUS rc = OQS_KEM_keypair(kem_, pk, sk);
        if (rc != OQS_SUCCESS) {
            secure_wipe_output(pk, pk_len);
            secure_wipe_output(sk, sk_len);
        }
        return rc == OQS_SUCCESS ? OQSRAII_SUCCESS : OQSRAII_FAIL;
    }
    int encaps(const unsigned char* pk, size_t pk_len,
               unsigned char* ct_out, size_t ct_len,
               unsigned char* ss_out, size_t ss_len) const {
        if (!kem_) return OQSRAII_FAIL;
        if (!readonly_buffer_valid(pk, pk_len) || !writable_buffer_valid(ct_out, ct_len) || !writable_buffer_valid(ss_out, ss_len)) return OQSRAII_FAIL;
        if (pk_len < public_key_length()) return OQSRAII_FAIL;
        if (ct_len < ciphertext_length() || ss_len < shared_secret_length()) return OQSRAII_FAIL;
        OQS_STATUS rc = OQS_KEM_encaps(kem_, ct_out, ss_out, pk);
        if (rc != OQS_SUCCESS) {
            secure_wipe_output(ct_out, ct_len);
            secure_wipe_output(ss_out, ss_len);
        }
        return rc == OQS_SUCCESS ? OQSRAII_SUCCESS : OQSRAII_FAIL;
    }
    int decaps(const unsigned char* ct, size_t ct_len,
               const unsigned char* sk, size_t sk_len,
               unsigned char* ss_out, size_t ss_len) const {
        if (!kem_) return OQSRAII_FAIL;
        if (!readonly_buffer_valid(ct, ct_len) || !readonly_buffer_valid(sk, sk_len) || !writable_buffer_valid(ss_out, ss_len)) return OQSRAII_FAIL;
        if (ct_len < ciphertext_length() || sk_len < secret_key_length()) return OQSRAII_FAIL;
        if (ss_len < shared_secret_length()) return OQSRAII_FAIL;
        OQS_STATUS rc = OQS_KEM_decaps(kem_, ss_out, ct, sk);
        if (rc != OQS_SUCCESS) {
            secure_wipe_output(ss_out, ss_len);
        }
        return rc == OQS_SUCCESS ? OQSRAII_SUCCESS : OQSRAII_FAIL;
    }
private:
    OQS_KEM* kem_ = nullptr;
};

// ========================= C 接口实现 =========================

// ML-DSA-65 长度查询
size_t oqs_raii_mldsa65_public_key_length(void) {
    MlDsa65 dsa;
    return dsa.public_key_length();
}
size_t oqs_raii_mldsa65_secret_key_length(void) {
    MlDsa65 dsa;
    return dsa.secret_key_length();
}
size_t oqs_raii_mldsa65_signature_length(void) {
    MlDsa65 dsa;
    return dsa.signature_length();
}

// ML-DSA-65 密钥对
int oqs_raii_mldsa65_keypair(unsigned char* pk_out, size_t pk_len,
                             unsigned char* sk_out, size_t sk_len) {
    MlDsa65 dsa;
    return dsa.keypair(pk_out, pk_len, sk_out, sk_len);
}

// ML-DSA-65 签名
int oqs_raii_mldsa65_sign(const unsigned char* msg, size_t msg_len,
                          const unsigned char* sk, size_t sk_len,
                          unsigned char* sig_out, size_t* sig_out_len) {
    MlDsa65 dsa;
    return dsa.sign(msg, msg_len, sk, sk_len, sig_out, sig_out_len);
}

// ML-DSA-65 验签
bool oqs_raii_mldsa65_verify(const unsigned char* msg, size_t msg_len,
                             const unsigned char* sig, size_t sig_len,
                             const unsigned char* pk, size_t pk_len) {
    MlDsa65 dsa;
    return dsa.verify(msg, msg_len, sig, sig_len, pk, pk_len);
}

// ML-KEM-768 长度查询
size_t oqs_raii_mlkem768_public_key_length(void) {
    MlKem768 kem;
    return kem.public_key_length();
}
size_t oqs_raii_mlkem768_secret_key_length(void) {
    MlKem768 kem;
    return kem.secret_key_length();
}
size_t oqs_raii_mlkem768_ciphertext_length(void) {
    MlKem768 kem;
    return kem.ciphertext_length();
}
size_t oqs_raii_mlkem768_shared_secret_length(void) {
    MlKem768 kem;
    return kem.shared_secret_length();
}

// ML-KEM-768 密钥对
int oqs_raii_mlkem768_keypair(unsigned char* pk_out, size_t pk_len,
                              unsigned char* sk_out, size_t sk_len) {
    MlKem768 kem;
    return kem.keypair(pk_out, pk_len, sk_out, sk_len);
}

// ML-KEM-768 封装
int oqs_raii_mlkem768_encaps(const unsigned char* pk, size_t pk_len,
                             unsigned char* ct_out, size_t ct_len,
                             unsigned char* ss_out, size_t ss_len) {
    MlKem768 kem;
    return kem.encaps(pk, pk_len, ct_out, ct_len, ss_out, ss_len);
}

// ML-KEM-768 解封装
int oqs_raii_mlkem768_decaps(const unsigned char* ct, size_t ct_len,
                             const unsigned char* sk, size_t sk_len,
                             unsigned char* ss_out, size_t ss_len) {
    MlKem768 kem;
    return kem.decaps(ct, ct_len, sk, sk_len, ss_out, ss_len);
}
