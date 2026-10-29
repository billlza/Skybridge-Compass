import Foundation
import Network
import SkyBridgeProtocolCore

public typealias FramedReader = SkyBridgeProtocolCore.FramedReader
public typealias FramedReaderError = SkyBridgeProtocolCore.FramedReaderError

public extension SkyBridgeProtocolCore.FramedReader {
    static func nwConnection(_ connection: NWConnection) -> FramedReader {
        FramedReader { maximumLength in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(data: Data, isComplete: Bool), Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: (data ?? Data(), isComplete))
                }
            }
        }
    }
}
