import Foundation
import CryptoKit

public struct IdentityFingerprint: Sendable, Codable {
    public let pairedID: String?
    public let macAddress: String?
    public let usnUUID: String?
    public let usbSerial: String?
    public let mdnsDeviceID: String?
    public let hostname: String?
    public let model: String?
    public let httpServer: String?
    public let portSpectrumHash: String?
    public let ipv4: String?
    public let ipv6: String?
    public let primaryConnectionType: String?
    
    public init(pairedID: String?, macAddress: String?, usnUUID: String?, usbSerial: String?, mdnsDeviceID: String?, hostname: String?, model: String?, httpServer: String?, portSpectrumHash: String?, ipv4: String?, ipv6: String?, primaryConnectionType: String?) {
        self.pairedID = pairedID
        self.macAddress = macAddress
        self.usnUUID = usnUUID
        self.usbSerial = usbSerial
        self.mdnsDeviceID = mdnsDeviceID
        self.hostname = hostname
        self.model = model
        self.httpServer = httpServer
        self.portSpectrumHash = portSpectrumHash
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.primaryConnectionType = primaryConnectionType
    }
}

struct IdentityResolver {
    static func areNamesSimilar(_ name1: String, _ name2: String) -> Bool {
        if name1 == name2 { return true }
        let clean1 = name1.filter { $0.isLetter || $0.isNumber }.lowercased()
        let clean2 = name2.filter { $0.isLetter || $0.isNumber }.lowercased()
        if !clean1.isEmpty && clean1 == clean2 { return true }
        if clean1.contains(clean2) || clean2.contains(clean1) {
            let minLength = min(clean1.count, clean2.count)
            if minLength >= 3 { return true }
        }
        let deviceKeywords = ["ipad", "iphone", "macbook", "imac", "airpods", "watch"]
        for keyword in deviceKeywords {
            if clean1.contains(keyword) && clean2.contains(keyword) {
                if clean1 == keyword || clean2 == keyword { return true }
            }
        }
        return false
    }
    func resolveIsLocal(_ device: DiscoveredDevice, selfId: SelfIdentitySnapshot) async -> Bool {
        Self.resolveIsLocalSynchronously(device: device, selfId: selfId)
    }
    
    static func resolveIsLocal(device: DiscoveredDevice, selfId: SelfIdentitySnapshot) async -> Bool {
        resolveIsLocalSynchronously(device: device, selfId: selfId)
    }

    static func resolveIsLocalSynchronously(
        device: DiscoveredDevice,
        selfId: SelfIdentitySnapshot
    ) -> Bool {
        if !selfId.deviceId.isEmpty,
           let deviceId = device.deviceId,
           deviceId == selfId.deviceId {
            return true
        }
        if isCanonicalSHA256Fingerprint(selfId.pubKeyFP),
           let fingerprint = device.pubKeyFP,
           isCanonicalSHA256Fingerprint(fingerprint),
           fingerprint == selfId.pubKeyFP {
            return true
        }

        let localMACs = selfId.macSet.filter(isUsableCanonicalMACAddress)
        let remoteMACs = device.macSet.filter(isUsableCanonicalMACAddress)
        return !localMACs.isEmpty && !localMACs.isDisjoint(with: remoteMACs)
    }

    private static func isCanonicalSHA256Fingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    private static func isUsableCanonicalMACAddress(_ value: String) -> Bool {
        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 6 else { return false }

        var octets: [UInt8] = []
        octets.reserveCapacity(6)
        for component in components {
            guard component.utf8.count == 2,
                  component.utf8.allSatisfy({ byte in
                      (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                  }),
                  let octet = UInt8(component, radix: 16) else {
                return false
            }
            octets.append(octet)
        }

        guard let firstOctet = octets.first,
              firstOctet & 0x01 == 0,
              octets.contains(where: { $0 != 0 }),
              octets.contains(where: { $0 != 0xFF }) else {
            return false
        }
        return true
    }
    
    func findMergeIndex(in devices: [DiscoveredDevice], candidate: DiscoveredDevice, candidateFP: IdentityFingerprint?) async -> Int? {
        let cIPv4 = candidate.ipv4
        let cIPv6 = candidate.ipv6
        let cName = candidate.name
        let cUID = candidate.uniqueIdentifier
        let cFP = candidate.pubKeyFP
        
        var bestIndex: Int?
        var bestScore = 0
        
        for (idx, existing) in devices.enumerated() {
            var score = 0
 // 🔧 修复：优先检查 UUID（id）匹配，用于同一设备的更新
            if existing.id == candidate.id { score += 200 }
            if let id1 = existing.deviceId, let id2 = candidate.deviceId, !id1.isEmpty, id1 == id2 { score += 100 }
            if let eFP = existing.pubKeyFP, let cFP = cFP, !eFP.isEmpty, !cFP.isEmpty, eFP == cFP { score += 80 }
            if let mac = candidateFP?.macAddress, existing.macSet.contains(mac) { score += 60 }
            if let ipv4 = existing.ipv4, let cIPv4 = cIPv4, ipv4 == cIPv4 { score += 40 }
            if let ipv6 = existing.ipv6, let cIPv6 = cIPv6, ipv6 == cIPv6 { score += 40 }
            if let uid = existing.uniqueIdentifier, let cUID = cUID, !uid.isEmpty, uid == cUID { score += 35 }
            if IdentityResolver.areNamesSimilar(existing.name, cName) { score += 20 }
            if let ps = candidateFP?.portSpectrumHash, let ePS = IdentityResolver.computePortSpectrumHash(from: existing.portMap), ps == ePS { score += 30 }
            if let http = candidateFP?.httpServer, let host = candidateFP?.hostname, !http.isEmpty, IdentityResolver.areNamesSimilar(existing.name, host) { score += 10 }
            
            if score > bestScore {
                bestScore = score
                bestIndex = idx
            }
        }
        return bestIndex
    }
    
    static func computePortSpectrumHash(from portMap: [String: Int]) -> String? {
        guard !portMap.isEmpty else { return nil }
        let parts = portMap
            .map { "\($0.key):\($0.value)" }
            .sorted()
            .joined(separator: "|")
        let data = Data(parts.utf8)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    func bestUniqueIdentifier(existing: DiscoveredDevice, candidate: DiscoveredDevice, candidateFP: IdentityFingerprint?) -> String? {
        if let mac = candidateFP?.macAddress, !mac.isEmpty { return mac }
        if let usn = candidateFP?.usnUUID, !usn.isEmpty { return usn }
        if let mdns = candidateFP?.mdnsDeviceID, !mdns.isEmpty { return mdns }
        if let http = candidateFP?.httpServer, !http.isEmpty { return http }
        if let cUID = candidate.uniqueIdentifier, !cUID.isEmpty { return cUID }
        return existing.uniqueIdentifier
    }
    public actor WeakFingerprintStore {
        public static let shared = WeakFingerprintStore()
        private let defaults = UserDefaults.standard
        private let prefix = "WeakFP."
        
        public func key(for device: DiscoveredDevice) -> String {
            return device.uniqueIdentifier ?? device.ipv4 ?? device.ipv6 ?? device.name
        }
        
        public func save(_ fp: IdentityFingerprint, for device: DiscoveredDevice) {
            let key = prefix + key(for: device)
            if let data = try? JSONEncoder().encode(fp) {
                defaults.set(data, forKey: key)
            }
        }
        
        public func load(for device: DiscoveredDevice) -> IdentityFingerprint? {
            let key = prefix + key(for: device)
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(IdentityFingerprint.self, from: data)
        }
    }
}
