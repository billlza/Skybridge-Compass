import Foundation

enum H264AnnexBAccessUnitError: Error, Equatable {
    case empty
    case tooLarge(limit: Int)
    case missingStartCode
    case emptyNALUnit
    case tooManyNALUnits(limit: Int)
    case invalidNALUnitType(UInt8)
    case parameterSetTooLarge(limit: Int)
    case missingRenderableNALUnit
}

struct H264AnnexBAccessUnit: Equatable {
    static let maximumAccessUnitBytes = 8 * 1_024 * 1_024
    static let maximumNALUnitCount = 512
    static let maximumParameterSetBytes = 64 * 1_024

    let nalUnits: [Data]

    var sequenceParameterSet: Data? {
        nalUnits.last { Self.nalUnitType($0) == 7 }
    }

    var pictureParameterSet: Data? {
        nalUnits.last { Self.nalUnitType($0) == 8 }
    }

    var containsIDR: Bool {
        nalUnits.contains { Self.nalUnitType($0) == 5 }
    }

    static func parse(
        _ data: Data,
        maximumAccessUnitBytes: Int = maximumAccessUnitBytes,
        maximumNALUnitCount: Int = maximumNALUnitCount,
        maximumParameterSetBytes: Int = maximumParameterSetBytes
    ) throws -> H264AnnexBAccessUnit {
        guard !data.isEmpty else { throw H264AnnexBAccessUnitError.empty }
        guard data.count <= maximumAccessUnitBytes else {
            throw H264AnnexBAccessUnitError.tooLarge(limit: maximumAccessUnitBytes)
        }
        guard let initialStartCodeLength = startCodeLength(in: data, at: 0) else {
            throw H264AnnexBAccessUnitError.missingStartCode
        }

        var nalUnits: [Data] = []
        nalUnits.reserveCapacity(min(16, maximumNALUnitCount))
        var payloadStart = initialStartCodeLength
        var index = payloadStart

        while index < data.count {
            if let startCodeLength = startCodeLength(in: data, at: index) {
                try appendNALUnit(
                    data.subdata(in: payloadStart..<index),
                    to: &nalUnits,
                    maximumNALUnitCount: maximumNALUnitCount,
                    maximumParameterSetBytes: maximumParameterSetBytes
                )
                payloadStart = index + startCodeLength
                index = payloadStart
            } else {
                index += 1
            }
        }

        try appendNALUnit(
            data.subdata(in: payloadStart..<data.count),
            to: &nalUnits,
            maximumNALUnitCount: maximumNALUnitCount,
            maximumParameterSetBytes: maximumParameterSetBytes
        )
        return H264AnnexBAccessUnit(nalUnits: nalUnits)
    }

    func makeAVCCSampleData() throws -> Data {
        let renderableUnits = nalUnits.filter { unit in
            guard let type = Self.nalUnitType(unit) else { return false }
            return type != 7 && type != 8
        }
        guard renderableUnits.contains(where: { unit in
            guard let type = Self.nalUnitType(unit) else { return false }
            return (1...5).contains(type)
        }) else {
            throw H264AnnexBAccessUnitError.missingRenderableNALUnit
        }

        let outputCapacity = renderableUnits.reduce(0) { $0 + 4 + $1.count }
        var output = Data()
        output.reserveCapacity(outputCapacity)
        for unit in renderableUnits {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(unit)
        }
        return output
    }

    private static func appendNALUnit(
        _ unit: Data,
        to units: inout [Data],
        maximumNALUnitCount: Int,
        maximumParameterSetBytes: Int
    ) throws {
        guard !unit.isEmpty else { throw H264AnnexBAccessUnitError.emptyNALUnit }
        guard units.count < maximumNALUnitCount else {
            throw H264AnnexBAccessUnitError.tooManyNALUnits(limit: maximumNALUnitCount)
        }
        guard let first = unit.first, first & 0x80 == 0 else {
            throw H264AnnexBAccessUnitError.invalidNALUnitType(unit.first.map { $0 & 0x1F } ?? 0)
        }
        let type = first & 0x1F
        guard (1...23).contains(type) else {
            throw H264AnnexBAccessUnitError.invalidNALUnitType(type)
        }
        if type == 7 || type == 8 {
            guard unit.count <= maximumParameterSetBytes else {
                throw H264AnnexBAccessUnitError.parameterSetTooLarge(limit: maximumParameterSetBytes)
            }
        }
        units.append(unit)
    }

    private static func nalUnitType(_ unit: Data) -> UInt8? {
        unit.first.map { $0 & 0x1F }
    }

    private static func startCodeLength(in data: Data, at index: Int) -> Int? {
        guard index >= 0, index + 3 <= data.count else { return nil }
        if index + 4 <= data.count,
           data[index] == 0,
           data[index + 1] == 0,
           data[index + 2] == 0,
           data[index + 3] == 1 {
            return 4
        }
        if data[index] == 0, data[index + 1] == 0, data[index + 2] == 1 {
            return 3
        }
        return nil
    }
}
