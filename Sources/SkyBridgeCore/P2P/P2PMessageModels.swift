import Foundation

// MARK: - P2P消息
public enum P2PMessage: Codable {
    case authChallenge(Data)
    case authResponse(Data)
    case remoteDesktopFrame(Data)
    case fileTransferRequest(FileTransferRequest)
    case fileTransferData(Data)
    case systemCommand(SystemCommand)
    case heartbeat
    
    private enum CodingKeys: String, CodingKey {
        case type, payload
    }
    
    private enum MessageType: String, Codable {
        case authChallenge, authResponse, remoteDesktopFrame
        case fileTransferRequest, fileTransferData, systemCommand, heartbeat
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)
        
        switch type {
        case .authChallenge:
            let data = try container.decode(Data.self, forKey: .payload)
            self = .authChallenge(data)
        case .authResponse:
            let data = try container.decode(Data.self, forKey: .payload)
            self = .authResponse(data)
        case .remoteDesktopFrame:
            let data = try container.decode(Data.self, forKey: .payload)
            self = .remoteDesktopFrame(data)
        case .fileTransferRequest:
            let request = try container.decode(FileTransferRequest.self, forKey: .payload)
            self = .fileTransferRequest(request)
        case .fileTransferData:
            let data = try container.decode(Data.self, forKey: .payload)
            self = .fileTransferData(data)
        case .systemCommand:
            let command = try container.decode(SystemCommand.self, forKey: .payload)
            self = .systemCommand(command)
        case .heartbeat:
            self = .heartbeat
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .authChallenge(let data):
            try container.encode(MessageType.authChallenge, forKey: .type)
            try container.encode(data, forKey: .payload)
        case .authResponse(let data):
            try container.encode(MessageType.authResponse, forKey: .type)
            try container.encode(data, forKey: .payload)
        case .remoteDesktopFrame(let data):
            try container.encode(MessageType.remoteDesktopFrame, forKey: .type)
            try container.encode(data, forKey: .payload)
        case .fileTransferRequest(let request):
            try container.encode(MessageType.fileTransferRequest, forKey: .type)
            try container.encode(request, forKey: .payload)
        case .fileTransferData(let data):
            try container.encode(MessageType.fileTransferData, forKey: .type)
            try container.encode(data, forKey: .payload)
        case .systemCommand(let command):
            try container.encode(MessageType.systemCommand, forKey: .type)
            try container.encode(command, forKey: .payload)
        case .heartbeat:
            try container.encode(MessageType.heartbeat, forKey: .type)
        }
    }
}

// MARK: - 文件传输请求
// FileTransferRequest 定义已移至 FileTransferModels.swift 中

// MARK: - 系统命令
public struct SystemCommand: Codable {
    public let id: String
    public let type: CommandType
    public let parameters: [String: String]
    public let timestamp: Date
    
    public enum CommandType: String, Codable, CaseIterable {
        case shutdown = "shutdown"
        case restart = "restart"
        case sleep = "sleep"
        case lock = "lock"
        case screenshot = "screenshot"
        case volumeUp = "volume_up"
        case volumeDown = "volume_down"
        case mute = "mute"
        case brightness = "brightness"
        case custom = "custom"
    }
    
    public init(id: String = UUID().uuidString, type: CommandType, parameters: [String: String] = [:]) {
        self.id = id
        self.type = type
        self.parameters = parameters
        self.timestamp = Date()
    }
}
