// 中文注释：OQSRAII.cpp 使用 C++23 RAII 封装 liboqs，并提供稳定的 C 接口给 Swift 调用

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <span>

#include <oqs/oqs.h>

#include "../include/OQSRAII.h"

namespace {

// ========================= 安全清零工具 =========================
// 中文注释：在析构或敏感数据生命周期结束时，对内存进行安全清零，避免编译器优化导致清零无效
void secure_memzero(void* pointer, size_t size) noexcept {
    if (pointer == nullptr || size == 0) {
        return;
    }
#if defined(__STDC_LIB_EXT1__)
    memset_s(pointer, size, 0, size);
#else
    auto* volatile bytes = reinterpret_cast<volatile unsigned char*>(pointer);
    for (size_t index = 0; index < size; ++index) {
        bytes[index] = 0;
    }
#endif
}

void secure_memzero(std::span<unsigned char> buffer) noexcept {
    secure_memzero(buffer.data(), buffer.size());
}

template <typename Byte>
struct BufferView final {
    Byte* data = nullptr;
    size_t size = 0;

    [[nodiscard]] constexpr bool is_present() const noexcept {
        return data != nullptr || size == 0;
    }

    [[nodiscard]] constexpr bool has_at_least(size_t expected_size) const noexcept {
        return is_present() && size >= expected_size;
    }

    [[nodiscard]] constexpr std::span<Byte> as_span() const noexcept {
        return {data, size};
    }
};

using ReadonlyBytes = BufferView<const unsigned char>;
using WritableBytes = BufferView<unsigned char>;

[[nodiscard]] constexpr ReadonlyBytes readonly_bytes(const unsigned char* data, size_t size) noexcept {
    return {data, size};
}

[[nodiscard]] constexpr WritableBytes writable_bytes(unsigned char* data, size_t size) noexcept {
    return {data, size};
}

void secure_wipe_output(WritableBytes buffer, size_t size_to_wipe) noexcept {
    if (!buffer.is_present()) {
        return;
    }
    secure_memzero(buffer.data, std::min(buffer.size, size_to_wipe));
}

[[nodiscard]] constexpr int to_c_result(OQS_STATUS status) noexcept {
    return status == OQS_SUCCESS ? OQSRAII_SUCCESS : OQSRAII_FAIL;
}

[[nodiscard]] constexpr int fail_with_zero_length(size_t* output_length) noexcept {
    if (output_length != nullptr) {
        *output_length = 0;
    }
    return OQSRAII_FAIL;
}

// ========================= OQS 初始化守卫 =========================
// 中文注释：确保 OQS_init 只调用一次，避免重复初始化开销
struct OQSInitGuard final {
    OQSInitGuard() { OQS_init(); }
};

void ensure_oqs_initialized() noexcept {
    static const OQSInitGuard guard{};
    (void)guard;
}

template <auto FreeFn>
struct OqsDeleter final {
    template <typename T>
    void operator()(T* value) const noexcept {
        if (value != nullptr) {
            FreeFn(value);
        }
    }
};

using SignatureHandle = std::unique_ptr<OQS_SIG, OqsDeleter<&OQS_SIG_free>>;
using KEMHandle = std::unique_ptr<OQS_KEM, OqsDeleter<&OQS_KEM_free>>;

[[nodiscard]] SignatureHandle make_signature(const char* algorithm_name) noexcept {
    ensure_oqs_initialized();
    return SignatureHandle{OQS_SIG_new(algorithm_name)};
}

[[nodiscard]] KEMHandle make_kem(const char* algorithm_name) noexcept {
    ensure_oqs_initialized();
    return KEMHandle{OQS_KEM_new(algorithm_name)};
}

template <typename Handle, typename Member>
[[nodiscard]] size_t member_length(const Handle& handle, Member member) noexcept {
    return handle ? handle.get()->*member : 0U;
}

// ========================= ML-DSA-65 RAII 封装 =========================
class MlDsa65 final {
public:
    MlDsa65() noexcept : signature_(make_signature(OQS_SIG_alg_ml_dsa_65)) {}

    [[nodiscard]] size_t public_key_length() const noexcept {
        return member_length(signature_, &OQS_SIG::length_public_key);
    }

    [[nodiscard]] size_t secret_key_length() const noexcept {
        return member_length(signature_, &OQS_SIG::length_secret_key);
    }

    [[nodiscard]] size_t signature_length() const noexcept {
        return member_length(signature_, &OQS_SIG::length_signature);
    }

    [[nodiscard]] int keypair(WritableBytes public_key, WritableBytes secret_key) const noexcept {
        if (!signature_ || !public_key.has_at_least(public_key_length()) || !secret_key.has_at_least(secret_key_length())) {
            return OQSRAII_FAIL;
        }

        const auto status = OQS_SIG_keypair(signature_.get(), public_key.data, secret_key.data);
        if (status != OQS_SUCCESS) {
            secure_wipe_output(public_key, public_key.size);
            secure_wipe_output(secret_key, secret_key.size);
        }
        return to_c_result(status);
    }

    [[nodiscard]] int sign(
        ReadonlyBytes message,
        ReadonlyBytes secret_key,
        WritableBytes signature_output,
        size_t* signature_output_length
    ) const noexcept {
        if (!signature_ || signature_output_length == nullptr) {
            return fail_with_zero_length(signature_output_length);
        }

        const auto max_signature_length = signature_length();
        if (max_signature_length == 0
            || !message.is_present()
            || !secret_key.has_at_least(secret_key_length())
            || !signature_output.has_at_least(max_signature_length)) {
            return fail_with_zero_length(signature_output_length);
        }

        size_t actual_signature_length = 0;
        const auto status = OQS_SIG_sign(
            signature_.get(),
            signature_output.data,
            &actual_signature_length,
            message.data,
            message.size,
            secret_key.data
        );

        if (status != OQS_SUCCESS) {
            secure_wipe_output(signature_output, max_signature_length);
            return fail_with_zero_length(signature_output_length);
        }

        *signature_output_length = actual_signature_length;
        return OQSRAII_SUCCESS;
    }

    [[nodiscard]] bool verify(ReadonlyBytes message, ReadonlyBytes signature_bytes, ReadonlyBytes public_key) const noexcept {
        if (!signature_
            || !message.is_present()
            || !signature_bytes.is_present()
            || !public_key.has_at_least(public_key_length())) {
            return false;
        }

        return OQS_SIG_verify(
                   signature_.get(),
                   message.data,
                   message.size,
                   signature_bytes.data,
                   signature_bytes.size,
                   public_key.data
               ) == OQS_SUCCESS;
    }

private:
    SignatureHandle signature_;
};

// ========================= ML-KEM-768 RAII 封装 =========================
class MlKem768 final {
public:
    MlKem768() noexcept : kem_(make_kem(OQS_KEM_alg_ml_kem_768)) {}

    [[nodiscard]] size_t public_key_length() const noexcept {
        return member_length(kem_, &OQS_KEM::length_public_key);
    }

    [[nodiscard]] size_t secret_key_length() const noexcept {
        return member_length(kem_, &OQS_KEM::length_secret_key);
    }

    [[nodiscard]] size_t ciphertext_length() const noexcept {
        return member_length(kem_, &OQS_KEM::length_ciphertext);
    }

    [[nodiscard]] size_t shared_secret_length() const noexcept {
        return member_length(kem_, &OQS_KEM::length_shared_secret);
    }

    [[nodiscard]] int keypair(WritableBytes public_key, WritableBytes secret_key) const noexcept {
        if (!kem_ || !public_key.has_at_least(public_key_length()) || !secret_key.has_at_least(secret_key_length())) {
            return OQSRAII_FAIL;
        }

        const auto status = OQS_KEM_keypair(kem_.get(), public_key.data, secret_key.data);
        if (status != OQS_SUCCESS) {
            secure_wipe_output(public_key, public_key.size);
            secure_wipe_output(secret_key, secret_key.size);
        }
        return to_c_result(status);
    }

    [[nodiscard]] int encaps(ReadonlyBytes public_key, WritableBytes ciphertext, WritableBytes shared_secret) const noexcept {
        if (!kem_
            || !public_key.has_at_least(public_key_length())
            || !ciphertext.has_at_least(ciphertext_length())
            || !shared_secret.has_at_least(shared_secret_length())) {
            return OQSRAII_FAIL;
        }

        const auto status = OQS_KEM_encaps(kem_.get(), ciphertext.data, shared_secret.data, public_key.data);
        if (status != OQS_SUCCESS) {
            secure_wipe_output(ciphertext, ciphertext_length());
            secure_wipe_output(shared_secret, shared_secret_length());
        }
        return to_c_result(status);
    }

    [[nodiscard]] int decaps(ReadonlyBytes ciphertext, ReadonlyBytes secret_key, WritableBytes shared_secret) const noexcept {
        if (!kem_
            || !ciphertext.has_at_least(ciphertext_length())
            || !secret_key.has_at_least(secret_key_length())
            || !shared_secret.has_at_least(shared_secret_length())) {
            return OQSRAII_FAIL;
        }

        const auto status = OQS_KEM_decaps(kem_.get(), shared_secret.data, ciphertext.data, secret_key.data);
        if (status != OQS_SUCCESS) {
            secure_wipe_output(shared_secret, shared_secret_length());
        }
        return to_c_result(status);
    }

private:
    KEMHandle kem_;
};

} // namespace

// ========================= C 接口实现 =========================

size_t oqs_raii_mldsa65_public_key_length(void) {
    return MlDsa65{}.public_key_length();
}

size_t oqs_raii_mldsa65_secret_key_length(void) {
    return MlDsa65{}.secret_key_length();
}

size_t oqs_raii_mldsa65_signature_length(void) {
    return MlDsa65{}.signature_length();
}

int oqs_raii_mldsa65_keypair(unsigned char* pk_out, size_t pk_len, unsigned char* sk_out, size_t sk_len) {
    return MlDsa65{}.keypair(writable_bytes(pk_out, pk_len), writable_bytes(sk_out, sk_len));
}

int oqs_raii_mldsa65_sign(
    const unsigned char* msg,
    size_t msg_len,
    const unsigned char* sk,
    size_t sk_len,
    unsigned char* sig_out,
    size_t* sig_out_len
) {
    const auto requested_signature_capacity = sig_out_len != nullptr ? *sig_out_len : 0U;
    return MlDsa65{}.sign(
        readonly_bytes(msg, msg_len),
        readonly_bytes(sk, sk_len),
        writable_bytes(sig_out, requested_signature_capacity),
        sig_out_len
    );
}

bool oqs_raii_mldsa65_verify(
    const unsigned char* msg,
    size_t msg_len,
    const unsigned char* sig,
    size_t sig_len,
    const unsigned char* pk,
    size_t pk_len
) {
    return MlDsa65{}.verify(
        readonly_bytes(msg, msg_len),
        readonly_bytes(sig, sig_len),
        readonly_bytes(pk, pk_len)
    );
}

size_t oqs_raii_mlkem768_public_key_length(void) {
    return MlKem768{}.public_key_length();
}

size_t oqs_raii_mlkem768_secret_key_length(void) {
    return MlKem768{}.secret_key_length();
}

size_t oqs_raii_mlkem768_ciphertext_length(void) {
    return MlKem768{}.ciphertext_length();
}

size_t oqs_raii_mlkem768_shared_secret_length(void) {
    return MlKem768{}.shared_secret_length();
}

int oqs_raii_mlkem768_keypair(unsigned char* pk_out, size_t pk_len, unsigned char* sk_out, size_t sk_len) {
    return MlKem768{}.keypair(writable_bytes(pk_out, pk_len), writable_bytes(sk_out, sk_len));
}

int oqs_raii_mlkem768_encaps(
    const unsigned char* pk,
    size_t pk_len,
    unsigned char* ct_out,
    size_t ct_len,
    unsigned char* ss_out,
    size_t ss_len
) {
    return MlKem768{}.encaps(
        readonly_bytes(pk, pk_len),
        writable_bytes(ct_out, ct_len),
        writable_bytes(ss_out, ss_len)
    );
}

int oqs_raii_mlkem768_decaps(
    const unsigned char* ct,
    size_t ct_len,
    const unsigned char* sk,
    size_t sk_len,
    unsigned char* ss_out,
    size_t ss_len
) {
    return MlKem768{}.decaps(
        readonly_bytes(ct, ct_len),
        readonly_bytes(sk, sk_len),
        writable_bytes(ss_out, ss_len)
    );
}
