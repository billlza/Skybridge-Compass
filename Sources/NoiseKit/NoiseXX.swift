import Foundation
import CryptoKit

public enum NoiseError: Error {
    case invalidPublicKey
    case invalidCiphertext
    case handshakeFailed(String)
}

public struct NoiseStaticKeyPair: Sendable {
    public let privateKey: Data
    public let publicKey: Data

    public init() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        self.privateKey = key.rawRepresentation
        self.publicKey = key.publicKey.rawRepresentation
    }

    fileprivate func privateKeyObject() throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
    }
}

public enum NoiseXX {
    public static let protocolName = "Noise_XX_25519_ChaChaPoly_SHA256"

    public static func makeStaticKeyPair() -> NoiseStaticKeyPair {
        NoiseStaticKeyPair()
    }

    public static func runInitiator(
        staticKey: NoiseStaticKeyPair,
        send: (Data) async throws -> Void,
        receive: () async throws -> Data
    ) async throws {
        var symmetric = SymmetricState(protocolName: protocolName)

        let eph = Curve25519.KeyAgreement.PrivateKey()
        let ephPub = eph.publicKey.rawRepresentation
        symmetric.mixHash(ephPub)
        try await send(ephPub)

        let message2 = try await receive()
        guard message2.count >= 32 else {
            throw NoiseError.handshakeFailed("message2 too short")
        }
        let responderEphemeral = message2.prefix(32)
        symmetric.mixHash(responderEphemeral)

        let ee = try dh(privateKey: eph, publicKey: responderEphemeral)
        symmetric.mixKey(ee)

        let encResponderStatic = message2.dropFirst(32)
        let responderStatic = try symmetric.decryptAndHash(Data(encResponderStatic))
        let es = try dh(privateKey: eph, publicKey: responderStatic)
        symmetric.mixKey(es)

        let initiatorStatic = staticKey.publicKey
        let encInitiatorStatic = try symmetric.encryptAndHash(initiatorStatic)
        try await send(encInitiatorStatic)

        let se = try dh(privateKey: staticKey.privateKeyObject(), publicKey: responderEphemeral)
        symmetric.mixKey(se)
    }

    public static func runResponder(
        staticKey: NoiseStaticKeyPair,
        send: (Data) async throws -> Void,
        receive: () async throws -> Data
    ) async throws {
        var symmetric = SymmetricState(protocolName: protocolName)

        let message1 = try await receive()
        guard message1.count == 32 else {
            throw NoiseError.handshakeFailed("message1 invalid length")
        }
        symmetric.mixHash(message1)

        let eph = Curve25519.KeyAgreement.PrivateKey()
        let ephPub = eph.publicKey.rawRepresentation
        symmetric.mixHash(ephPub)

        let ee = try dh(privateKey: eph, publicKey: message1)
        symmetric.mixKey(ee)

        let responderStatic = staticKey.publicKey
        let encResponderStatic = try symmetric.encryptAndHash(responderStatic)
        let es = try dh(privateKey: staticKey.privateKeyObject(), publicKey: message1)
        symmetric.mixKey(es)

        var message2 = Data()
        message2.append(ephPub)
        message2.append(encResponderStatic)
        try await send(message2)

        let message3 = try await receive()
        let initiatorStatic = try symmetric.decryptAndHash(message3)
        let se = try dh(privateKey: eph, publicKey: initiatorStatic)
        symmetric.mixKey(se)
    }

    private struct CipherState {
        private var key: SymmetricKey?
        private var nonce: UInt64 = 0

        mutating func initializeKey(_ keyBytes: Data) {
            key = SymmetricKey(data: keyBytes)
            nonce = 0
        }

        mutating func encrypt(ad: Data, plaintext: Data) throws -> Data {
            guard let key else {
                return plaintext
            }

            let nonceData = makeNonce(nonce)
            let nonce = try ChaChaPoly.Nonce(data: nonceData)
            let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: ad)
            self.nonce += 1
            return sealed.ciphertext + sealed.tag
        }

        mutating func decrypt(ad: Data, ciphertext: Data) throws -> Data {
            guard let key else {
                return ciphertext
            }
            guard ciphertext.count >= 16 else {
                throw NoiseError.invalidCiphertext
            }

            let nonceData = makeNonce(nonce)
            let nonce = try ChaChaPoly.Nonce(data: nonceData)
            let tag = ciphertext.suffix(16)
            let body = ciphertext.dropLast(16)
            let box = try ChaChaPoly.SealedBox(
                nonce: nonce,
                ciphertext: body,
                tag: tag
            )
            let plaintext = try ChaChaPoly.open(box, using: key, authenticating: ad)
            self.nonce += 1
            return plaintext
        }
    }

    private struct SymmetricState {
        private var ck: Data
        private var h: Data
        private var cipher = CipherState()

        init(protocolName: String) {
            let protoBytes = Data(protocolName.utf8)
            if protoBytes.count <= 32 {
                var padded = Data(protoBytes)
                padded.append(contentsOf: [UInt8](repeating: 0, count: 32 - protoBytes.count))
                self.h = padded
            } else {
                self.h = sha256(protoBytes)
            }
            self.ck = h
        }

        mutating func mixHash(_ data: Data) {
            h = sha256(h + data)
        }

        mutating func mixKey(_ input: Data) {
            let outputs = hkdf(chainingKey: ck, inputKeyMaterial: input, outputs: 2)
            ck = outputs[0]
            cipher.initializeKey(outputs[1])
        }

        mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
            let ciphertext = try cipher.encrypt(ad: h, plaintext: plaintext)
            mixHash(ciphertext)
            return ciphertext
        }

        mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
            let plaintext = try cipher.decrypt(ad: h, ciphertext: ciphertext)
            mixHash(ciphertext)
            return plaintext
        }
    }

    private static func dh(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        publicKey: Data
    ) throws -> Data {
        let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: pub)
        return sharedSecret.withUnsafeBytes { Data($0) }
    }

    private static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func hkdf(
        chainingKey: Data,
        inputKeyMaterial: Data,
        outputs: Int
    ) -> [Data] {
        let prk = hmac(key: chainingKey, data: inputKeyMaterial)
        var result: [Data] = []
        var previous = Data()
        for idx in 1...outputs {
            var data = Data()
            data.append(previous)
            data.append(UInt8(idx))
            let output = hmac(key: prk, data: data)
            result.append(output)
            previous = output
        }
        return result
    }

    private static func hmac(key: Data, data: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }

    private static func makeNonce(_ nonce: UInt64) -> Data {
        var nonceBytes = [UInt8](repeating: 0, count: 12)
        var value = nonce.littleEndian
        withUnsafeBytes(of: &value) { bytes in
            for (index, byte) in bytes.enumerated() {
                nonceBytes[4 + index] = byte
            }
        }
        return Data(nonceBytes)
    }
}
