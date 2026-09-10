use serde::Deserialize;
use sha2::{Digest, Sha256};
use skybridge_core::ffi as bridge;
use std::ffi::CStr;
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

const ROOT_PIN: &str = "98cad7b47b290e8559c9d8fc1985266647830ac1d5168f24a28ad74f04ac75db";
const POLICY_DIGEST: &str = "eb583259f4fd8c19ae720e0d92bcc13bad1870e337151f2c1afe180a557111c6";

#[derive(Deserialize)]
struct PolicyFixture {
    schema_version: u32,
    algorithm: String,
    trust_root_identifier: String,
    policy_toml: String,
    policy_version: u32,
    // Schema 1 uses this historical wire name for the SHA3-256 state digest.
    #[serde(rename = "policy_digest_sha256_hex")]
    policy_state_digest_sha3_256_hex: String,
    detached_signature_hex: String,
    verification_key_hex: String,
    verification_key_sha256_pin_hex: String,
}

fn hex_bytes(value: &str) -> Vec<u8> {
    assert!(value.len().is_multiple_of(2));
    value
        .as_bytes()
        .chunks_exact(2)
        .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap())
        .collect()
}

fn fixture() -> PolicyFixture {
    let material: PolicyFixture =
        serde_json::from_str(include_str!("fixtures/qperiapt-production-trust-root.json")).unwrap();
    assert_eq!(material.schema_version, 1);
    assert_eq!(material.algorithm, "ML-DSA-65");
    assert_eq!(
        material.trust_root_identifier,
        "skybridge/qperiapt/production-root/v1"
    );
    assert_eq!(material.policy_version, 1);
    assert_eq!(material.policy_state_digest_sha3_256_hex, POLICY_DIGEST);
    assert_eq!(material.verification_key_sha256_pin_hex, ROOT_PIN);
    let key = hex_bytes(&material.verification_key_hex);
    assert_eq!(key.len(), 1952);
    assert!(Sha256::digest(&key).as_slice() == hex_bytes(ROOT_PIN));
    assert_eq!(hex_bytes(&material.detached_signature_hex).len(), 3309);
    material
}

fn decision() -> [u8; 40] {
    let material = fixture();
    let signature = hex_bytes(&material.detached_signature_hex);
    let key = hex_bytes(&material.verification_key_hex);
    let mut output = [0xa5; 40];
    let status = unsafe {
        bridge::skybridge_q_periapt_decision_from_signed_policy(
            material.policy_toml.as_ptr(),
            material.policy_toml.len(),
            signature.as_ptr(),
            signature.len(),
            key.as_ptr(),
            key.len(),
            std::ptr::null(),
            0,
            output.as_mut_ptr(),
            output.len(),
        )
    };
    assert_eq!(status, 0);
    assert_eq!(&output[..8], &[1, 1, 2, 1, 0, 0, 0, 1]);
    assert!(output[8..] == hex_bytes(POLICY_DIGEST));
    output
}

#[derive(Zeroize, ZeroizeOnDrop)]
struct Keys {
    sk_pq: [u8; 2400],
    pk_pq: [u8; 1184],
    sk_trad: [u8; 32],
    pk_trad: [u8; 32],
}

fn keys(decision: &[u8; 40]) -> Keys {
    let mut keys = Keys {
        sk_pq: [0; 2400],
        pk_pq: [0; 1184],
        sk_trad: [0; 32],
        pk_trad: [0; 32],
    };
    let status = unsafe {
        bridge::skybridge_q_periapt_generate_keypair(
            decision.as_ptr(),
            decision.len(),
            keys.sk_pq.as_mut_ptr(),
            keys.sk_pq.len(),
            keys.pk_pq.as_mut_ptr(),
            keys.pk_pq.len(),
            keys.sk_trad.as_mut_ptr(),
            keys.sk_trad.len(),
            keys.pk_trad.as_mut_ptr(),
            keys.pk_trad.len(),
        )
    };
    assert_eq!(status, 0);
    keys
}

fn encapsulate(
    decision: &[u8; 40],
    keys: &Keys,
    context: &[u8],
) -> ([u8; 1088], [u8; 32], Zeroizing<[u8; 32]>) {
    let mut pq = [0; 1088];
    let mut traditional = [0; 32];
    let mut secret = Zeroizing::new([0; 32]);
    let status = unsafe {
        bridge::skybridge_q_periapt_encapsulate(
            decision.as_ptr(),
            decision.len(),
            keys.pk_pq.as_ptr(),
            keys.pk_pq.len(),
            keys.pk_trad.as_ptr(),
            keys.pk_trad.len(),
            context.as_ptr(),
            context.len(),
            pq.as_mut_ptr(),
            pq.len(),
            traditional.as_mut_ptr(),
            traditional.len(),
            secret.as_mut_ptr(),
            secret.len(),
        )
    };
    assert_eq!(status, 0);
    (pq, traditional, secret)
}

fn decapsulate(
    decision: &[u8; 40],
    keys: &Keys,
    pq: &[u8],
    traditional: &[u8],
    context: &[u8],
) -> Zeroizing<[u8; 32]> {
    let mut secret = Zeroizing::new([0xa5; 32]);
    let status = unsafe {
        bridge::skybridge_q_periapt_decapsulate(
            decision.as_ptr(),
            decision.len(),
            keys.sk_pq.as_ptr(),
            keys.sk_pq.len(),
            pq.as_ptr(),
            pq.len(),
            keys.pk_pq.as_ptr(),
            keys.pk_pq.len(),
            keys.sk_trad.as_ptr(),
            keys.sk_trad.len(),
            traditional.as_ptr(),
            traditional.len(),
            keys.pk_trad.as_ptr(),
            keys.pk_trad.len(),
            context.as_ptr(),
            context.len(),
            secret.as_mut_ptr(),
            secret.len(),
        )
    };
    assert_eq!(status, 0);
    secret
}

#[test]
fn metadata_uses_all_five_forwarded_functions() {
    assert_eq!(bridge::skybridge_q_periapt_abi_version(), 2);
    assert_eq!(
        unsafe { CStr::from_ptr(bridge::skybridge_q_periapt_version()) }.to_bytes(),
        b"0.1.5"
    );
    assert_eq!(bridge::skybridge_q_periapt_fixed_suite_id_len(), 17);
    assert_eq!(
        unsafe { CStr::from_ptr(bridge::skybridge_q_periapt_fixed_suite_id()) }.to_bytes(),
        b"ML-KEM-768+X25519"
    );
    for (code, name) in [
        (0, "OK"),
        (-1, "ERR_NULL"),
        (-2, "ERR_LENGTH"),
        (-3, "ERR_POLICY"),
        (-4, "ERR_PANIC"),
        (-5, "ERR_INTERNAL"),
        (-6, "ERR_INVALID_KEYSHARE"),
        (-7, "ERR_ALIASING"),
        (-8, "ERR_ENTROPY"),
    ] {
        assert_eq!(
            unsafe { CStr::from_ptr(bridge::skybridge_q_periapt_status_name(code)) }
                .to_str()
                .unwrap(),
            name
        );
    }
}

#[test]
fn production_policy_keygen_and_context_bound_roundtrip_use_the_core_bridge() {
    let decision = decision();
    let keys = keys(&decision);
    let context = b"skybridge/windows/qperiapt/abi2/bridge-test/v1";
    let (pq, traditional, expected) = encapsulate(&decision, &keys, context);
    let actual = decapsulate(&decision, &keys, &pq, &traditional, context);
    assert!(
        *expected == *actual,
        "native Core roundtrip changed the shared secret"
    );
    let changed = decapsulate(
        &decision,
        &keys,
        &pq,
        &traditional,
        b"different application context",
    );
    assert!(
        *changed != *expected,
        "application context must affect the derived secret"
    );
}

#[test]
fn signed_policy_shape_rollback_and_alias_errors_keep_native_status_and_output_rules() {
    let material = fixture();
    let signature = hex_bytes(&material.detached_signature_hex);
    let key = hex_bytes(&material.verification_key_hex);
    for (signature_len, key_len, previous) in [
        (3308, 1952, vec![]),
        (3309, 1951, vec![]),
        (3309, 1952, {
            let mut value = vec![0; 36];
            value[3] = 2;
            value
        }),
    ] {
        let mut output = [0xa5; 40];
        let status = unsafe {
            bridge::skybridge_q_periapt_decision_from_signed_policy(
                material.policy_toml.as_ptr(),
                material.policy_toml.len(),
                signature.as_ptr(),
                signature_len,
                key.as_ptr(),
                key_len,
                previous.as_ptr(),
                previous.len(),
                output.as_mut_ptr(),
                output.len(),
            )
        };
        assert_eq!(status, -3);
        assert!(output.iter().all(|byte| *byte == 0));
    }
    let mut shared_input_output = [0x5a; 40];
    let status = unsafe {
        bridge::skybridge_q_periapt_decision_from_signed_policy(
            shared_input_output.as_ptr(),
            shared_input_output.len(),
            signature.as_ptr(),
            signature.len(),
            key.as_ptr(),
            key.len(),
            std::ptr::null(),
            0,
            shared_input_output.as_mut_ptr(),
            shared_input_output.len(),
        )
    };
    assert_eq!(status, -7);
    assert!(shared_input_output.iter().all(|byte| *byte == 0x5a));
    let mut short_output = [0x5a; 39];
    let status = unsafe {
        bridge::skybridge_q_periapt_decision_from_signed_policy(
            material.policy_toml.as_ptr(),
            material.policy_toml.len(),
            signature.as_ptr(),
            signature.len(),
            key.as_ptr(),
            key.len(),
            std::ptr::null(),
            0,
            short_output.as_mut_ptr(),
            short_output.len(),
        )
    };
    assert_eq!(status, -2);
    assert!(short_output.iter().all(|byte| *byte == 0x5a));
}

#[test]
fn encapsulation_component_lengths_and_large_context_fail_closed() {
    let decision = decision();
    let keys = keys(&decision);
    for (pq_len, traditional_len, context_len) in [
        (1183, 32, 1),
        (1185, 32, 1),
        (1184, 31, 1),
        (1184, 33, 1),
        (1184, 32, 65537),
    ] {
        let mut public_pq = keys.pk_pq.to_vec();
        public_pq.resize(pq_len, 0);
        let mut public_traditional = keys.pk_trad.to_vec();
        public_traditional.resize(traditional_len, 0);
        let context = vec![1; context_len];
        let mut pq = [0xa5; 1088];
        let mut traditional = [0xa5; 32];
        let mut secret = Zeroizing::new([0xa5; 32]);
        let status = unsafe {
            bridge::skybridge_q_periapt_encapsulate(
                decision.as_ptr(),
                decision.len(),
                public_pq.as_ptr(),
                public_pq.len(),
                public_traditional.as_ptr(),
                public_traditional.len(),
                context.as_ptr(),
                context.len(),
                pq.as_mut_ptr(),
                pq.len(),
                traditional.as_mut_ptr(),
                traditional.len(),
                secret.as_mut_ptr(),
                secret.len(),
            )
        };
        assert_eq!(status, -2);
        assert!(pq
            .iter()
            .chain(traditional.iter())
            .chain(secret.iter())
            .all(|byte| *byte == 0));
    }
}

#[test]
fn decapsulation_forwards_all_six_component_lengths_in_the_original_order() {
    let decision = decision();
    let keys = keys(&decision);
    let context = b"shape-test";
    let (pq, traditional, _) = encapsulate(&decision, &keys, context);
    for index in 0..6 {
        for longer in [false, true] {
            let mut parts = [
                Zeroizing::new(keys.sk_pq.to_vec()),
                Zeroizing::new(pq.to_vec()),
                Zeroizing::new(keys.pk_pq.to_vec()),
                Zeroizing::new(keys.sk_trad.to_vec()),
                Zeroizing::new(traditional.to_vec()),
                Zeroizing::new(keys.pk_trad.to_vec()),
            ];
            let len = parts[index].len();
            parts[index].resize(if longer { len + 1 } else { len - 1 }, 0);
            let mut output = Zeroizing::new([0xa5; 32]);
            let status = unsafe {
                bridge::skybridge_q_periapt_decapsulate(
                    decision.as_ptr(),
                    decision.len(),
                    parts[0].as_ptr(),
                    parts[0].len(),
                    parts[1].as_ptr(),
                    parts[1].len(),
                    parts[2].as_ptr(),
                    parts[2].len(),
                    parts[3].as_ptr(),
                    parts[3].len(),
                    parts[4].as_ptr(),
                    parts[4].len(),
                    parts[5].as_ptr(),
                    parts[5].len(),
                    context.as_ptr(),
                    context.len(),
                    output.as_mut_ptr(),
                    output.len(),
                )
            };
            assert_eq!(status, -2);
            assert!(output.iter().all(|byte| *byte == 0));
        }
    }
}

#[test]
fn independent_parallel_calls_do_not_share_operation_buffers() {
    let decision = decision();
    let workers: Vec<_> = (0..4)
        .map(|index| {
            std::thread::spawn(move || {
                let keys = keys(&decision);
                let context = [index; 16];
                let (pq, traditional, expected) = encapsulate(&decision, &keys, &context);
                let actual = decapsulate(&decision, &keys, &pq, &traditional, &context);
                assert!(
                    *actual == *expected,
                    "parallel native operation mixed buffers"
                );
            })
        })
        .collect();
    for worker in workers {
        worker.join().unwrap();
    }
}
