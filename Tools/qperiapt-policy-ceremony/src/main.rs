//! Offline signing ceremony for the SkyBridge Q-Periapt ABI2 production policy.
//!
//! The ceremony produces the exact provisioning material both apps compile in:
//!
//! 1. Validates the production policy TOML with the reviewed upstream policy
//!    engine and proves it resolves ML-KEM-768+X25519 / ContextBound.
//! 2. Generates (or reuses) the ML-DSA-65 production root from OS randomness.
//! 3. Signs `policy_signature_message(policy)` with hedged randomness and
//!    re-verifies the signed policy end to end before emitting anything.
//! 4. Writes the private root seed to an operator-chosen location *outside*
//!    the repository (0600), the canonical public provisioning record JSON,
//!    and the generated Swift material for the macOS and iOS registries.
//!
//! The signing key never enters the repository. Only public material —
//! policy bytes, detached signature, verification key, and its SHA-256 pin —
//! is committed.

use q_periapt_backends::{MlDsa65, ML_DSA_65_KEYGEN_SEED_LEN, ML_DSA_65_SIG_LEN};
use q_periapt_policy::{policy_signature_message, HybridSuite, Policy};
use q_periapt_sig::Signer;
use sha2::{Digest, Sha256};
use std::fs;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{SystemTime, UNIX_EPOCH};

const TOOL_NAME: &str = env!("CARGO_PKG_NAME");
const TOOL_VERSION: &str = env!("CARGO_PKG_VERSION");
const USAGE: &str = "\
usage: qperiapt-policy-ceremony \\
    --policy <production-policy.toml> \\
    --trust-root-identifier <canonical-id> \\
    --signing-key-out <path outside the repository> \\
    [--reuse-signing-key <existing seed record>] \\
    --record-out <public provisioning record .json> \\
    --swift-out <shared-module QPeriaptProductionTrustRootMaterial.swift>";

struct CeremonyError(String);

impl From<String> for CeremonyError {
    fn from(message: String) -> Self {
        Self(message)
    }
}

struct Arguments {
    policy_path: PathBuf,
    trust_root_identifier: String,
    signing_key_out: PathBuf,
    reuse_signing_key: Option<PathBuf>,
    record_out: PathBuf,
    swift_out: PathBuf,
}

fn assign_path(
    slot: &mut Option<PathBuf>,
    flag: &str,
    value: String,
) -> Result<(), CeremonyError> {
    if slot.replace(PathBuf::from(value)).is_some() {
        return Err(format!("{flag} was given twice").into());
    }
    Ok(())
}

fn parse_arguments() -> Result<Arguments, CeremonyError> {
    let mut policy_path = None;
    let mut trust_root_identifier = None;
    let mut signing_key_out = None;
    let mut reuse_signing_key = None;
    let mut record_out = None;
    let mut swift_out = None;

    let mut raw = std::env::args().skip(1);
    while let Some(flag) = raw.next() {
        let value = raw
            .next()
            .ok_or_else(|| format!("{flag} requires a value\n{USAGE}"))?;
        match flag.as_str() {
            "--policy" => assign_path(&mut policy_path, &flag, value)?,
            "--signing-key-out" => assign_path(&mut signing_key_out, &flag, value)?,
            "--reuse-signing-key" => assign_path(&mut reuse_signing_key, &flag, value)?,
            "--record-out" => assign_path(&mut record_out, &flag, value)?,
            "--swift-out" => assign_path(&mut swift_out, &flag, value)?,
            "--trust-root-identifier" => {
                if trust_root_identifier.replace(value).is_some() {
                    return Err("--trust-root-identifier was given twice".to_string().into());
                }
            }
            other => return Err(format!("unknown argument: {other}\n{USAGE}").into()),
        }
    }

    Ok(Arguments {
        policy_path: policy_path.ok_or_else(|| format!("--policy is required\n{USAGE}"))?,
        trust_root_identifier: trust_root_identifier
            .ok_or_else(|| format!("--trust-root-identifier is required\n{USAGE}"))?,
        signing_key_out: signing_key_out
            .ok_or_else(|| format!("--signing-key-out is required\n{USAGE}"))?,
        reuse_signing_key,
        record_out: record_out.ok_or_else(|| format!("--record-out is required\n{USAGE}"))?,
        swift_out: swift_out.ok_or_else(|| format!("--swift-out is required\n{USAGE}"))?,
    })
}

fn repository_root() -> Result<PathBuf, CeremonyError> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let root = manifest_dir
        .parent()
        .and_then(Path::parent)
        .ok_or_else(|| "cannot locate the repository root from the tool manifest".to_string())?;
    root.canonicalize()
        .map_err(|error| format!("cannot canonicalize repository root: {error}").into())
}

/// The private root must never land inside the repository, where it could be
/// committed or picked up by packaging.
fn require_outside_repository(path: &Path, root: &Path) -> Result<(), CeremonyError> {
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .ok_or_else(|| format!("{} has no parent directory", path.display()))?;
    let canonical_parent = parent.canonicalize().map_err(|error| {
        format!(
            "signing-key output directory {} is not usable: {error}",
            parent.display()
        )
    })?;
    if canonical_parent.starts_with(root) {
        return Err(format!(
            "refusing to write the private signing key inside the repository: {}",
            path.display()
        )
        .into());
    }
    Ok(())
}

fn os_random<const N: usize>() -> Result<[u8; N], CeremonyError> {
    let mut bytes = [0u8; N];
    getrandom::fill(&mut bytes)
        .map_err(|error| format!("operating-system randomness unavailable: {error}"))?;
    Ok(bytes)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn from_hex(text: &str) -> Result<Vec<u8>, CeremonyError> {
    if !text.len().is_multiple_of(2) {
        return Err("hex value has odd length".to_string().into());
    }
    (0..text.len())
        .step_by(2)
        .map(|index| {
            u8::from_str_radix(&text[index..index + 2], 16)
                .map_err(|error| CeremonyError(format!("invalid hex byte at {index}: {error}")))
        })
        .collect()
}

fn json_string(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for ch in value.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            ch if ch.is_control() => out.push_str(&format!("\\u{:04x}", ch as u32)),
            ch => out.push(ch),
        }
    }
    out.push('"');
    out
}

/// Minimal JSON field extraction for the seed record this tool itself wrote.
/// The record is flat, string-valued, and produced by `json_string` above.
fn seed_record_field(record: &str, key: &str) -> Result<String, CeremonyError> {
    let marker = format!("\"{key}\":");
    let start = record
        .find(&marker)
        .ok_or_else(|| format!("seed record is missing {key}"))?
        + marker.len();
    let rest = record[start..].trim_start();
    let mut chars = rest.chars();
    if chars.next() != Some('"') {
        return Err(format!("seed record field {key} is not a string").into());
    }
    let mut value = String::new();
    let mut escaped = false;
    for ch in chars {
        if escaped {
            value.push(match ch {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                other => other,
            });
            escaped = false;
        } else if ch == '\\' {
            escaped = true;
        } else if ch == '"' {
            return Ok(value);
        } else {
            value.push(ch);
        }
    }
    Err(format!("seed record field {key} is unterminated").into())
}

fn load_or_generate_seed(
    arguments: &Arguments,
) -> Result<[u8; ML_DSA_65_KEYGEN_SEED_LEN], CeremonyError> {
    let Some(existing) = &arguments.reuse_signing_key else {
        return os_random::<ML_DSA_65_KEYGEN_SEED_LEN>();
    };
    let record = fs::read_to_string(existing)
        .map_err(|error| format!("cannot read {}: {error}", existing.display()))?;
    let algorithm = seed_record_field(&record, "algorithm")?;
    if algorithm != "ML-DSA-65" {
        return Err(format!("seed record algorithm is {algorithm}, expected ML-DSA-65").into());
    }
    let identifier = seed_record_field(&record, "trust_root_identifier")?;
    if identifier != arguments.trust_root_identifier {
        return Err(format!(
            "seed record belongs to trust root {identifier}, not {}",
            arguments.trust_root_identifier
        )
        .into());
    }
    let seed_bytes = from_hex(&seed_record_field(&record, "keygen_seed_hex")?)?;
    let seed: [u8; ML_DSA_65_KEYGEN_SEED_LEN] = seed_bytes
        .try_into()
        .map_err(|_| "seed record keygen seed has the wrong length".to_string())?;
    Ok(seed)
}

fn write_signing_key_record(
    arguments: &Arguments,
    seed: &[u8; ML_DSA_65_KEYGEN_SEED_LEN],
    verification_key_pin: &[u8],
    created_at_unix: u64,
) -> Result<(), CeremonyError> {
    let record = format!(
        "{{\n  \"format\": \"skybridge-qperiapt-root-seed-v1\",\n  \"algorithm\": \"ML-DSA-65\",\n  \"trust_root_identifier\": {},\n  \"keygen_seed_hex\": {},\n  \"verification_key_sha256_hex\": {},\n  \"created_at_unix\": {},\n  \"handling\": \"PRIVATE root material. Store offline. Never commit. Required again only to sign a future policy version for this root.\"\n}}\n",
        json_string(&arguments.trust_root_identifier),
        json_string(&hex(seed)),
        json_string(&hex(verification_key_pin)),
        created_at_unix,
    );
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&arguments.signing_key_out)
        .map_err(|error| {
            format!(
                "cannot create signing-key record {} (existing files are never overwritten): {error}",
                arguments.signing_key_out.display()
            )
        })?;
    file.write_all(record.as_bytes())
        .map_err(|error| format!("cannot write signing-key record: {error}"))?;
    Ok(())
}

/// Everything the ceremony proved and emits publicly for one signed policy.
struct SignedPolicyArtifacts {
    policy_toml: String,
    policy_version: u32,
    policy_digest: [u8; 32],
    signature: Vec<u8>,
    verification_key: Vec<u8>,
    verification_key_pin: [u8; 32],
    created_at_unix: u64,
}

fn provisioning_record_json(arguments: &Arguments, artifacts: &SignedPolicyArtifacts) -> String {
    format!(
        "{{\n  \"schema_version\": 1,\n  \"generator\": {},\n  \"algorithm\": \"ML-DSA-65\",\n  \"trust_root_identifier\": {},\n  \"policy_toml\": {},\n  \"policy_version\": {},\n  \"policy_digest_sha256_hex\": {},\n  \"detached_signature_hex\": {},\n  \"verification_key_hex\": {},\n  \"verification_key_sha256_pin_hex\": {},\n  \"created_at_unix\": {}\n}}\n",
        json_string(&format!("{TOOL_NAME} {TOOL_VERSION}")),
        json_string(&arguments.trust_root_identifier),
        json_string(&artifacts.policy_toml),
        artifacts.policy_version,
        json_string(&hex(&artifacts.policy_digest)),
        json_string(&hex(&artifacts.signature)),
        json_string(&hex(&artifacts.verification_key)),
        json_string(&hex(&artifacts.verification_key_pin)),
        artifacts.created_at_unix,
    )
}

/// Renders bytes as a Swift `Data([...])` array body, 12 bytes per line.
/// Byte arrays fix the exact signed bytes at compile time; no runtime decode
/// or failure path exists for compiled-in material.
fn swift_byte_array(bytes: &[u8], indent: &str) -> String {
    let mut body = String::new();
    for chunk in bytes.chunks(12) {
        body.push_str(indent);
        for byte in chunk {
            body.push_str(&format!("0x{byte:02x}, "));
        }
        let trailing_space = body.pop();
        debug_assert_eq!(trailing_space, Some(' '));
        body.push('\n');
    }
    body
}

/// Renders the human-readable policy as doc-comment lines.
fn swift_doc_comment_lines(policy_toml: &str, indent: &str) -> String {
    let mut body = String::new();
    for line in policy_toml.split_inclusive('\n') {
        let line = line.strip_suffix('\n').unwrap_or(line);
        body.push_str(indent);
        body.push_str("/// ");
        body.push_str(line);
        body.push('\n');
    }
    body
}

fn generated_swift_material(
    arguments: &Arguments,
    artifacts: &SignedPolicyArtifacts,
) -> String {
    format!(
        r#"// GENERATED FILE - DO NOT EDIT BY HAND.
//
// Produced by Tools/{TOOL_NAME} {TOOL_VERSION} (created_at_unix={created_at_unix}).
// Canonical record: Config/qperiapt-production-trust-root.json. Reviewers
// re-derive `verificationKeySHA256Pin` from the record before release; the
// pin below is the independent trust anchor for the Q-Periapt ABI2 suite.

import Foundation

/// Public production trust-root material for the Q-Periapt ABI2 signed
/// policy, shared by every platform registry. Contains no secrets: the
/// ML-DSA-65 signing key stayed with the ceremony operator.
///
/// Signed policy (version {policy_version}, state digest
/// `{policy_digest_hex}`):
///
{policy_doc}public enum QPeriaptProductionTrustRootMaterial {{
    public static let trustRootIdentifier = "{trust_root_identifier}"

    /// Exact signed bytes; the detached signature verifies these.
    public static let policyTOML = Data([
{policy_bytes}    ])

    public static let detachedSignature = Data([
{signature_bytes}    ])

    public static let verificationKey = Data([
{verification_key_bytes}    ])

    /// Independently pinned SHA-256 of the verification key.
    public static let verificationKeySHA256Pin = Data([
{verification_key_pin_bytes}    ])

    /// Complete signed-policy material for registry construction.
    public static func makeSignedPolicyMaterial() -> QPeriaptSignedPolicyMaterial {{
        QPeriaptSignedPolicyMaterial(
            policyTOML: policyTOML,
            detachedSignature: detachedSignature,
            verificationKey: verificationKey,
            verificationKeySHA256Pin: verificationKeySHA256Pin,
            trustRootIdentifier: trustRootIdentifier
        )
    }}
}}
"#,
        created_at_unix = artifacts.created_at_unix,
        policy_version = artifacts.policy_version,
        policy_digest_hex = hex(&artifacts.policy_digest),
        policy_doc = swift_doc_comment_lines(&artifacts.policy_toml, ""),
        trust_root_identifier = arguments.trust_root_identifier,
        policy_bytes = swift_byte_array(artifacts.policy_toml.as_bytes(), "        "),
        signature_bytes = swift_byte_array(&artifacts.signature, "        "),
        verification_key_bytes = swift_byte_array(&artifacts.verification_key, "        "),
        verification_key_pin_bytes = swift_byte_array(&artifacts.verification_key_pin, "        "),
    )
}

fn run() -> Result<(), CeremonyError> {
    let arguments = parse_arguments()?;
    let repository = repository_root()?;
    require_outside_repository(&arguments.signing_key_out, &repository)?;

    let policy_toml = fs::read_to_string(&arguments.policy_path)
        .map_err(|error| format!("cannot read {}: {error}", arguments.policy_path.display()))?;

    // 1. The policy must be valid and must resolve the ABI2 hybrid suite
    //    before anything is signed.
    let parsed = Policy::from_toml(&policy_toml)
        .map_err(|error| format!("production policy rejected: {error}"))?;
    parsed
        .resolve_suite(&[HybridSuite::MlKem768X25519])
        .map_err(|error| format!("production policy does not resolve ABI2: {error}"))?;

    // 2. Root key material.
    let seed = load_or_generate_seed(&arguments)?;
    let (signing_key, verification_key) = MlDsa65::generate(seed);
    let verification_key_pin = Sha256::digest(verification_key);

    // 3. Hedged ML-DSA-65 signature over the domain-separated policy message.
    let message = policy_signature_message(policy_toml.as_bytes());
    let randomness = os_random::<32>()?;
    let mut signature_buffer = [0u8; ML_DSA_65_SIG_LEN];
    let signature_length = MlDsa65
        .sign(&signing_key, &message, &randomness, &mut signature_buffer)
        .map_err(|error| format!("ML-DSA-65 signing failed: {error:?}"))?;
    let signature = signature_buffer
        .get(..signature_length)
        .ok_or_else(|| format!("signer returned out-of-range length {signature_length}"))?;

    // 4. Full independent re-verification of what will ship.
    let authenticated =
        Policy::load_signed(&MlDsa65, &verification_key, policy_toml.as_bytes(), signature)
            .map_err(|error| format!("signed policy failed re-verification: {error}"))?;
    let decision = authenticated
        .resolve_suite(&[HybridSuite::MlKem768X25519])
        .map_err(|error| format!("signed policy failed re-resolution: {error}"))?;
    let policy_version = decision.resolved().policy_version();
    let trusted_state = decision.trusted_state();
    let policy_digest = trusted_state.digest();

    let created_at_unix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| format!("system clock is before the Unix epoch: {error}"))?
        .as_secs();

    // 5. Private material first: if this write fails nothing public exists.
    if arguments.reuse_signing_key.is_none() {
        write_signing_key_record(&arguments, &seed, &verification_key_pin, created_at_unix)?;
    }

    let artifacts = SignedPolicyArtifacts {
        policy_toml,
        policy_version,
        policy_digest,
        signature: signature.to_vec(),
        verification_key: verification_key.to_vec(),
        verification_key_pin: verification_key_pin.into(),
        created_at_unix,
    };

    let record = provisioning_record_json(&arguments, &artifacts);
    fs::write(&arguments.record_out, &record)
        .map_err(|error| format!("cannot write {}: {error}", arguments.record_out.display()))?;

    let swift = generated_swift_material(&arguments, &artifacts);
    fs::write(&arguments.swift_out, &swift)
        .map_err(|error| format!("cannot write {}: {error}", arguments.swift_out.display()))?;

    println!("ceremony complete: trust root {}", arguments.trust_root_identifier);
    println!("  policy version:            {policy_version}");
    println!("  policy digest (sha-256):   {}", hex(&policy_digest));
    println!("  verification key pin:      {}", hex(&verification_key_pin));
    println!("  private seed record:       {}", arguments.signing_key_out.display());
    println!("  public provisioning record:{}", arguments.record_out.display());
    println!("  swift material (shared):   {}", arguments.swift_out.display());
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(CeremonyError(message)) => {
            eprintln!("error: {message}");
            ExitCode::FAILURE
        }
    }
}
