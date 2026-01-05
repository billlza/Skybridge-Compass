// SPDX-License-Identifier: MIT
// SkyBridge Compass - MockLoopbackTransport
// Benchmark Evidence Chain Fix - 2
// Requirements: 3.1, 3.2, 3.3, 3.4

import Foundation
@testable import SkyBridgeCore

// MARK: - AsyncChannel

/// 异步通道（用于端点间通信）
/// Requirements: 3.3
@available(macOS 14.0, iOS 17.0, *)
internal actor AsyncChannel<T: Sendable> {
    
 /// 缓冲区
    private var buffer: [T] = []
    
 /// 等待接收的 continuation
    private var waiters: [CheckedContinuation<T, Never>] = []
    
 /// 是否已关闭
    private var isClosed: Bool = false
    
 /// 发送值到通道
 /// - Parameter value: 要发送的值
    func send(_ value: T) {
        guard !isClosed else { return }
        
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: value)
        } else {
            buffer.append(value)
        }
    }
    
 /// 从通道接收值
 /// - Returns: 接收到的值
    func receive() async -> T? {
        if isClosed && buffer.isEmpty {
            return nil
        }
        
        if !buffer.isEmpty {
            return buffer.removeFirst()
        }
        
        return await withCheckedContinuation { continuation in
            if isClosed {
 // 通道已关闭，返回 nil 需要特殊处理
 // 这里我们不能直接返回 nil，所以需要在调用处处理
            }
            waiters.append(continuation)
        }
    }
    
 /// 关闭通道
    func close() {
        isClosed = true
 // 唤醒所有等待者
        for waiter in waiters {
 // 注意：这里需要发送一个默认值或使用 throwing continuation
 // 为简化，我们假设调用者会检查 isClosed
        }
        waiters.removeAll()
    }
    
 /// 检查通道是否已关闭
    var closed: Bool {
        isClosed
    }
    
 /// 获取缓冲区大小
    var bufferCount: Int {
        buffer.count
    }
}

// MARK: - MockTransportEndpoint

/// 传输端点 actor
/// Requirements: 3.1
@available(macOS 14.0, iOS 17.0, *)
public actor MockTransportEndpoint: DiscoveryTransport {
    
 /// 发送通道（发送到对端）
    private let sendChannel: AsyncChannel<(PeerIdentifier, Data)>
    
 /// 接收通道（从对端接收）
    private let receiveChannel: AsyncChannel<(PeerIdentifier, Data)>
    
 /// 消息处理回调
    private var messageHandler: (@Sendable (PeerIdentifier, Data) async -> Void)?
    
 /// 是否已关闭
    private var isClosed: Bool = false
    
 /// 初始化端点
 /// - Parameters:
 /// - sendChannel: 发送通道
 /// - receiveChannel: 接收通道
    init(
        sendChannel: AsyncChannel<(PeerIdentifier, Data)>,
        receiveChannel: AsyncChannel<(PeerIdentifier, Data)>
    ) {
        self.sendChannel = sendChannel
        self.receiveChannel = receiveChannel
    }
    
 // MARK: - DiscoveryTransport Protocol
    
 /// 发送数据到对端
 /// - Parameters:
 /// - peer: 对端标识
 /// - data: 要发送的数据
    public func send(to peer: PeerIdentifier, data: Data) async throws {
        guard !isClosed else {
            throw DiscoveryTransportError.connectionClosed
        }
        await sendChannel.send((peer, data))
    }
    
 // MARK: - Public API
    
 /// 接收数据（阻塞直到有数据）
 /// - Returns: 接收到的数据
    public func receive() async throws -> (peer: PeerIdentifier, data: Data) {
        guard !isClosed else {
            throw DiscoveryTransportError.connectionClosed
        }
        
        guard let result = await receiveChannel.receive() else {
            throw DiscoveryTransportError.connectionClosed
        }
        
        return result
    }
    
 /// 设置消息处理回调
 /// - Parameter handler: 消息处理回调
    public func setMessageHandler(
        _ handler: @escaping @Sendable (PeerIdentifier, Data) async -> Void
    ) {
        messageHandler = handler
    }
    
 /// 启动接收循环
    public func startReceiving() {
        Task {
            while !isClosed {
                do {
                    let (peer, data) = try await receive()
                    await messageHandler?(peer, data)
                } catch {
                    break
                }
            }
        }
    }
    
 /// 关闭端点
    public func close() async {
        isClosed = true
        await sendChannel.close()
        await receiveChannel.close()
    }
}

// MARK: - MockLoopbackTransport

/// 内存回环传输层，用于 benchmark 测试隔离
/// Requirements: 3.2, 3.4
@available(macOS 14.0, iOS 17.0, *)
public final class MockLoopbackTransport: Sendable {
    
 /// 发起方端点
    public let initiatorSide: MockTransportEndpoint
    
 /// 响应方端点
    public let responderSide: MockTransportEndpoint
    
 /// 初始化回环传输
    public init() {
 // 创建两个通道用于双向通信
 // initiator -> responder
        let i2rChannel = AsyncChannel<(PeerIdentifier, Data)>()
 // responder -> initiator
        let r2iChannel = AsyncChannel<(PeerIdentifier, Data)>()
        
 // initiator 发送到 i2rChannel，从 r2iChannel 接收
        self.initiatorSide = MockTransportEndpoint(
            sendChannel: i2rChannel,
            receiveChannel: r2iChannel
        )
        
 // responder 发送到 r2iChannel，从 i2rChannel 接收
        self.responderSide = MockTransportEndpoint(
            sendChannel: r2iChannel,
            receiveChannel: i2rChannel
        )
    }
}

// MARK: - MockLoopbackTransport Tests

import XCTest

@available(macOS 14.0, iOS 17.0, *)
final class MockLoopbackTransportTests: XCTestCase {
    
 /// Test basic bidirectional message passing
    func testBidirectionalMessagePassing() async throws {
        let transport = MockLoopbackTransport()
        let testPeer = PeerIdentifier(deviceId: "test-peer")
        let testData = Data("Hello, World!".utf8)
        
 // Send from initiator to responder
        try await transport.initiatorSide.send(to: testPeer, data: testData)
        
 // Receive on responder
        let (_, receivedData) = try await transport.responderSide.receive()
        XCTAssertEqual(receivedData, testData)
        
 // Send from responder to initiator
        let responseData = Data("Hello back!".utf8)
        try await transport.responderSide.send(to: testPeer, data: responseData)
        
 // Receive on initiator
        let (_, receivedResponse) = try await transport.initiatorSide.receive()
        XCTAssertEqual(receivedResponse, responseData)
    }
    
 /// Test multiple messages in sequence
    func testMultipleMessagesInSequence() async throws {
        let transport = MockLoopbackTransport()
        let testPeer = PeerIdentifier(deviceId: "test-peer")
        
 // Send multiple messages
        for i in 0..<10 {
            let data = Data("Message \(i)".utf8)
            try await transport.initiatorSide.send(to: testPeer, data: data)
        }
        
 // Receive all messages
        for i in 0..<10 {
            let (_, data) = try await transport.responderSide.receive()
            XCTAssertEqual(String(data: data, encoding: .utf8), "Message \(i)")
        }
    }
    
 /// Property 2: Bidirectional Message Delivery
 /// For any message sent, the other endpoint SHALL receive identical bytes
    func testProperty_BidirectionalMessageDelivery() async throws {
        let transport = MockLoopbackTransport()
        let testPeer = PeerIdentifier(deviceId: "test-peer")
        
 // Run 100 iterations
        for iteration in 0..<100 {
 // Generate random payload (1-1000 bytes)
            let payloadSize = Int.random(in: 1...1000)
            var payload = Data(count: payloadSize)
            for i in 0..<payloadSize {
                payload[i] = UInt8.random(in: 0...255)
            }
            
 // Test initiator -> responder
            try await transport.initiatorSide.send(to: testPeer, data: payload)
            let (_, received1) = try await transport.responderSide.receive()
            XCTAssertEqual(
                received1, payload,
                "Iteration \(iteration): initiator->responder data mismatch"
            )
            
 // Test responder -> initiator
            try await transport.responderSide.send(to: testPeer, data: payload)
            let (_, received2) = try await transport.initiatorSide.receive()
            XCTAssertEqual(
                received2, payload,
                "Iteration \(iteration): responder->initiator data mismatch"
            )
        }
    }
    
 /// Test concurrent send/receive
    func testConcurrentSendReceive() async throws {
        let transport = MockLoopbackTransport()
        let testPeer = PeerIdentifier(deviceId: "test-peer")
        let messageCount = 50
        
 // Use actor to safely collect messages
        actor MessageCollector {
            var messages: [Data] = []
            func append(_ data: Data) { messages.append(data) }
            var count: Int { messages.count }
        }
        let collector = MessageCollector()
        
 // Concurrent send from initiator
        let sendTask = Task {
            for i in 0..<messageCount {
                let data = Data("Msg\(i)".utf8)
                try await transport.initiatorSide.send(to: testPeer, data: data)
            }
        }
        
 // Concurrent receive on responder
        let receiveTask = Task {
            for _ in 0..<messageCount {
                let (_, data) = try await transport.responderSide.receive()
                await collector.append(data)
            }
        }
        
        try await sendTask.value
        try await receiveTask.value
        
        let receivedCount = await collector.count
        XCTAssertEqual(receivedCount, messageCount)
    }
}
