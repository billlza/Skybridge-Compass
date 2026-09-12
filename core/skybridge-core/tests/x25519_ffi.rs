use skybridge_core::ffi::{skybridge_x25519_shared_secret, SkybridgeErrorCode};

fn bytes(hex: &str) -> [u8; 32] {
    std::array::from_fn(|index| u8::from_str_radix(&hex[index * 2..index * 2 + 2], 16).unwrap())
}

#[test]
fn rfc7748_agreement_and_basepoint_vectors() {
    let alice = bytes("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
    let bob_public = bytes("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f");
    let expected = bytes("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742");
    let mut result = [0u8; 32];
    assert_eq!(
        unsafe {
            skybridge_x25519_shared_secret(
                alice.as_ptr(),
                32,
                bob_public.as_ptr(),
                32,
                result.as_mut_ptr(),
                32,
            )
        },
        SkybridgeErrorCode::Ok
    );
    assert_eq!(result, expected);
    let mut basepoint = [0u8; 32];
    basepoint[0] = 9;
    assert_eq!(
        unsafe {
            skybridge_x25519_shared_secret(
                alice.as_ptr(),
                32,
                basepoint.as_ptr(),
                32,
                result.as_mut_ptr(),
                32,
            )
        },
        SkybridgeErrorCode::Ok
    );
    assert_eq!(
        result,
        bytes("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
    );
}

#[test]
fn malformed_and_noncontributory_inputs_fail_without_a_secret() {
    let private = [7u8; 32];
    let zero_peer = [0u8; 32];
    let mut result = [99u8; 32];
    assert_eq!(
        unsafe {
            skybridge_x25519_shared_secret(
                private.as_ptr(),
                32,
                zero_peer.as_ptr(),
                32,
                result.as_mut_ptr(),
                32,
            )
        },
        SkybridgeErrorCode::CryptoError
    );
    assert_eq!(result, [0; 32]);
    assert_eq!(
        unsafe {
            skybridge_x25519_shared_secret(
                std::ptr::null(),
                32,
                zero_peer.as_ptr(),
                32,
                result.as_mut_ptr(),
                32,
            )
        },
        SkybridgeErrorCode::InvalidInput
    );
    assert_eq!(
        unsafe {
            skybridge_x25519_shared_secret(
                private.as_ptr(),
                31,
                zero_peer.as_ptr(),
                32,
                result.as_mut_ptr(),
                32,
            )
        },
        SkybridgeErrorCode::InvalidInput
    );
    assert_eq!(
        unsafe {
            skybridge_x25519_shared_secret(
                private.as_ptr(),
                32,
                zero_peer.as_ptr(),
                32,
                result.as_mut_ptr(),
                31,
            )
        },
        SkybridgeErrorCode::InvalidInput
    );
}
