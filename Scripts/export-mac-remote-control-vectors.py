#!/usr/bin/env python3
"""Export SBRC/SBMA interoperability vectors using the macOS production Swift sources."""

import argparse
from pathlib import Path
import subprocess
import tempfile


def between(text: str, start: str, end: str) -> str:
    offset = text.index(start)
    return text[offset:text.index(end, offset)]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mac_repository", type=Path)
    parser.add_argument("output", type=Path)
    arguments = parser.parse_args()
    repository = arguments.mac_repository.resolve(strict=True)
    read = lambda name: (repository / name).read_text(encoding="utf-8")
    session_keys = between(read("Sources/SkyBridgeProtocolCore/P2P/HandshakeCoreTypes.swift"),
                           "public struct SessionKeys:", "@available(macOS 14.0, iOS 17.0, *)\nextension SessionKeys")
    derivation = between(read("Sources/SkyBridgeCore/P2P/HandshakeContext.swift"),
                         "    private func deriveSessionKeys(\n        sharedSecret: SecureBytes,\n        suite:",
                         " // MARK: - Zeroization").replace("private func", "func", 1)
    finished = between(read("Sources/SkyBridgeCore/P2P/HandshakeDriver.swift"),
                       "    private func makeFinished(", "    private func verifyFinished(").replace("private func", "func", 1)
    finished_type = between(read("Sources/SkyBridgeProtocolCore/P2P/HandshakeMessages.swift"),
                            "public struct HandshakeFinished:", "    public static func decode(from data: Data) throws -> HandshakeFinished") + "}\n"
    # Only the non-cryptographic carrier types are supplied here. The derivation,
    # Finished, envelopes and media codec below are the exact product functions.
    prelude = '''import Foundation
import CryptoKit
public enum HandshakeRole: Sendable { case initiator, responder }
public enum CryptoSuite: Sendable {
    case mlkem768
    public var wireId: UInt16 { 0x0101 }
    public var kdfCompositionLabel: String { "v1-single" }
}
public enum HandshakeConstants { public static let protocolVersion: UInt8 = 1 }
typealias SecureBytes = Data
'''
    body = '''
extension Data { var hex: String { map { String(format: "%02x", $0) }.joined() } }
let secret = Data(0..<32)
let transcriptA = Data(32..<64)
let transcriptB = Data(64..<96)
let clientNonce = Data(96..<128)
let serverNonce = Data(128..<160)
let initiator = FixtureContext(role: .initiator)
let keys = try initiator.deriveSessionKeys(sharedSecret: secret, suite: .mlkem768,
    transcriptA: transcriptA, transcriptB: transcriptB, localNonce: clientNonce, remoteNonce: serverNonce)
let responderKeys = SessionKeys(sendKey: keys.receiveKey, receiveKey: keys.sendKey,
    negotiatedSuite: .mlkem768, role: .responder, transcriptHash: keys.transcriptHash)
let payload = Data("remote-control-wire-vector".utf8)
let sbrc = try RemoteControlSecureEnvelope.seal(payload, keys: responderKeys, packetType: .control, counter: 17)
let mediaKeys = SkyBridgeMediaKeyMaterial.derive(sendSecret: responderKeys.sendKey, receiveSecret: responderKeys.receiveKey,
    sessionId: responderKeys.sessionId, transcriptHash: responderKeys.transcriptHash, localRole: .responder)
let sbma = try SkyBridgeMediaPacketCodec.seal(payload: payload,
    header: SkyBridgeMediaPacketHeader(sessionIdHash: SkyBridgeMediaPacketCodec.sessionIdHash(keys.sessionId),
        sequence: 0, timestampSamples: 960, flags: 1, wireDirection: .responderToInitiator,
        transcriptPrefix: mediaKeys.send.transcriptPrefix, keyEpoch: 0, nonceCounter: 17), keys: mediaKeys.send)
let output: [String: Any] = [
    "schemaVersion": 1, "suiteWireId": 257, "sharedSecret": secret.hex,
    "transcriptA": transcriptA.hex, "transcriptB": transcriptB.hex,
    "clientNonce": clientNonce.hex, "serverNonce": serverNonce.hex,
    "sessionId": keys.sessionId, "transcriptHash": keys.transcriptHash.hex,
    "initiatorSendKey": keys.sendKey.hex, "responderSendKey": keys.receiveKey.hex,
    "initiatorFinished": try initiator.makeFinished(direction: .initiatorToResponder, sessionKeys: keys).encoded.hex,
    "responderFinished": try initiator.makeFinished(direction: .responderToInitiator, sessionKeys: responderKeys).encoded.hex,
    "plaintext": payload.hex, "sbrc": sbrc.hex, "sbma": sbma.hex,
    "mediaSendKey": mediaKeys.send.key.withUnsafeBytes { Data($0) }.hex,
    "mediaNonceSalt": mediaKeys.send.nonceSalt.hex
]
let json = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(json)
'''
    source = prelude + session_keys + finished_type + "struct FixtureContext { let role: HandshakeRole\n" + derivation + finished + "}\n"
    for name in ("Sources/SkyBridgeCore/RemoteControl/RemoteControlSecureEnvelope.swift",
                 "Sources/SkyBridgeRealtimeMedia/MediaProfile.swift",
                 "Sources/SkyBridgeRealtimeMedia/MediaKeys.swift",
                 "Sources/SkyBridgeRealtimeMedia/MediaPacket.swift"):
        source += read(name) + "\n"
    source += body
    with tempfile.TemporaryDirectory(prefix="skybridge-remote-control-vectors-") as directory:
        swift = Path(directory) / "main.swift"
        executable = Path(directory) / "vectors"
        swift.write_text(source, encoding="utf-8")
        subprocess.run(["swiftc", "-warnings-as-errors", str(swift), "-o", str(executable)], check=True)
        result = subprocess.run([str(executable)], check=True, capture_output=True)
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_bytes(result.stdout + b"\n")


if __name__ == "__main__":
    main()
