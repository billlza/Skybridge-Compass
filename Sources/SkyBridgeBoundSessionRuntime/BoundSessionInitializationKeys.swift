import CBoundSession
import Foundation

/// Exact public bytes from the actual policy, committed identity and trusted
/// peer. Construction validates representation only, not key origin or trust.
public struct BoundSessionInitializationPublicKeys: Sendable {
    let policyVerificationKey: Data
    let localIdentityKey: Data
    let peerIdentityKey: Data
    let localRecipientKey: Data
    let peerRecipientKey: Data

    public init(policyVerificationKey: Data, localIdentityKey: Data, peerIdentityKey: Data,
                localRecipientKey: Data, peerRecipientKey: Data) throws {
        for key in [policyVerificationKey, localIdentityKey, peerIdentityKey] {
            guard key.count == 1952 else { throw BoundSessionInitializationError.invalidInput("ML-DSA-65 public key length") }
        }
        for key in [localRecipientKey, peerRecipientKey] {
            guard key.count == 1216 else { throw BoundSessionInitializationError.invalidInput("ML-KEM-768/X25519 public tuple length") }
        }
        self.policyVerificationKey = policyVerificationKey
        self.localIdentityKey = localIdentityKey
        self.peerIdentityKey = peerIdentityKey
        self.localRecipientKey = localRecipientKey
        self.peerRecipientKey = peerRecipientKey
    }
}

public struct BoundSessionInitializationKeyDigests: Sendable {
    /// Raw policy-key SHA-256, matching QPeriaptRuntimeSession.trustRootFingerprint.
    public let policyVerificationKeySHA256: Data
    /// Separate provider tuple domain; must NOT be used as Q's raw-key pin.
    public let policyRootFingerprint: Data
    public let localIdentityFingerprint: Data
    public let peerIdentityFingerprint: Data
    public let localRecipientDigest: Data
    public let peerRecipientDigest: Data
}

extension BoundSessionInitializationNative {
    /// Reuses the provider's native tuple/identity functions without creating a
    /// temporary memory service or duplicating the digest codec in App code.
    public static func keyDigests(_ keys: BoundSessionInitializationPublicKeys) throws -> BoundSessionInitializationKeyDigests {
        let capability = bs_ffi_capabilities_v6()
        guard capability == UInt64(BS_FFI_CAPABILITY_PROTECTED_INITIALIZATION_V6) else {
            throw BoundSessionInitializationError.capabilityUnavailable(actual: capability)
        }
        let inputs = [keys.policyVerificationKey, keys.localIdentityKey, keys.peerIdentityKey,
                      keys.localRecipientKey, keys.peerRecipientKey]
        var output = BsFfiInitializationKeyDigestsV6()
        let status = try withPublicBuffers(inputs) { buffers in
            var config = BsFfiInitializationKeyMaterialV6()
            config.abi_version = 6
            config.struct_size = UInt32(MemoryLayout<BsFfiInitializationKeyMaterialV6>.size)
            config.policy_verification_key = buffers[0]
            config.local_identity_verification_key = buffers[1]
            config.peer_identity_verification_key = buffers[2]
            config.local_recipient_public_key = buffers[3]
            config.peer_recipient_public_key = buffers[4]
            return bs_ffi_initialization_key_digests_v6(&config, &output)
        }
        guard status == BS_FFI_OK_V1 else {
            throw BoundSessionInitializationError.native(status: status, name: String(cString: bs_ffi_status_name_v1(status)))
        }
        guard output.abi_version == 6, output.struct_size == UInt32(MemoryLayout<BsFfiInitializationKeyDigestsV6>.size),
              withUnsafeBytes(of: &output.reserved, { $0.allSatisfy { $0 == 0 } }) else {
            throw BoundSessionInitializationError.nativeOutputContract("public-key digest layout")
        }
        return BoundSessionInitializationKeyDigests(
            policyVerificationKeySHA256: withUnsafeBytes(of: &output.policy_verification_key_sha256) { Data($0) },
            policyRootFingerprint: withUnsafeBytes(of: &output.policy_root_fingerprint) { Data($0) },
            localIdentityFingerprint: withUnsafeBytes(of: &output.local_identity_fingerprint) { Data($0) },
            peerIdentityFingerprint: withUnsafeBytes(of: &output.peer_identity_fingerprint) { Data($0) },
            localRecipientDigest: withUnsafeBytes(of: &output.local_recipient_digest) { Data($0) },
            peerRecipientDigest: withUnsafeBytes(of: &output.peer_recipient_digest) { Data($0) }
        )
    }
}

extension BoundSessionInitializationContext {
    /// The caller obtains all expected pins/state from its actual verified
    /// policy and committed identity/peer authority. Matching values establishes
    /// consistency with those inputs, not their provenance or current authority.
    public static func bindingPublicKeys(_ keys: BoundSessionInitializationPublicKeys,
                                         expectedPolicyKeyPin: Data,
                                         expectedLocalIdentityFingerprint: Data,
                                         expectedPeerIdentityFingerprint: Data,
                                         trustRootIdentifierSHA256: Data, trustedPolicyState: Data,
                                         providerIdentity: Data, initializationID: Data) throws -> Self {
        let derived = try BoundSessionInitializationNative.keyDigests(keys)
        guard derived.policyVerificationKeySHA256 == expectedPolicyKeyPin,
              derived.localIdentityFingerprint == expectedLocalIdentityFingerprint,
              derived.peerIdentityFingerprint == expectedPeerIdentityFingerprint,
              derived.localIdentityFingerprint != derived.peerIdentityFingerprint,
              derived.localRecipientDigest != derived.peerRecipientDigest else {
            throw BoundSessionInitializationError.invalidInput("original key material does not match policy/local/peer pins")
        }
        return try Self(trustRootFingerprint: derived.policyVerificationKeySHA256,
            trustRootIdentifierSHA256: trustRootIdentifierSHA256,
            localIdentityFingerprint: derived.localIdentityFingerprint, peerIdentityFingerprint: derived.peerIdentityFingerprint,
            trustedPolicyState: trustedPolicyState, localRecipientDigest: derived.localRecipientDigest,
            peerRecipientDigest: derived.peerRecipientDigest, providerIdentity: providerIdentity, initializationID: initializationID)
    }
}

private func withPublicBuffers<T>(_ values: [Data],
                                  operation: ([BsFfiBytesV1]) throws -> T) throws -> T {
    // Exactly five public buffers; each nested closure keeps its bytes borrowed
    // until the one synchronous native call returns. No pointer is retained.
    guard values.count == 5 else { throw BoundSessionInitializationError.invalidInput("public-key field count") }
    func borrow(_ index: Int, _ buffers: [BsFfiBytesV1]) throws -> T {
        guard index < values.count else { return try operation(buffers) }
        return try values[index].withUnsafeBytes { bytes in
            guard let pointer = bytes.bindMemory(to: UInt8.self).baseAddress else {
                throw BoundSessionInitializationError.invalidInput("empty public-key input")
            }
            return try borrow(index + 1, buffers + [BsFfiBytesV1(pointer: pointer, length: UInt(bytes.count))])
        }
    }
    return try borrow(0, [])
}
