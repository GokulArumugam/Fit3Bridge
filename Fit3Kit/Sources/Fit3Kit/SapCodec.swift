// Port of the transport parts of Fit3SapCodec.kt from yuriyurin/Fit3-App (GPL-3.0-only).
//
// Wire format (one BLE notification/write == one frame):
//   prefix | body | crc16(body) (big endian, CRC-16/ARC)
//   prefix = [len, len]                       when transport MTU < 256
//          = [lenHi, lenLo, crc16(len) BE]     otherwise
//   body   = flags, seq/stream, serviceId, serviceId, payload...  (first/single fragment)
//          = flags, seq/stream, payload...                          (continuation)
import Foundation

public enum SapService {
    public static let oobe = 1
    public static let call = 3
    public static let location = 4
    public static let weather = 5
    public static let watchface = 6
    public static let notifications = 7
    public static let calendar = 8
    public static let media = 9
    public static let health = 10
    public static let settings = 11
    public static let widgets = 15
    public static let quickMessages = 18
    public static let quickPanel = 19
    public static let apps = 24
    public static let otaTransfer = 30

    public static func name(_ id: Int) -> String {
        switch id {
        case oobe: return "OOBE"
        case call: return "CALL"
        case weather: return "WEATHER"
        case watchface: return "FACE"
        case notifications: return "NOTI"
        case media: return "MEDIA"
        case health: return "HEALTH"
        case settings: return "SETTINGS"
        default: return "SVC\(id)"
        }
    }
}

public enum SapCodec {
    public static let capabilityRequestOpcode: UInt8 = 0x14
    public static let capabilityResponseOpcode: UInt8 = 0x15

    /// Read-only WatchInfo request from the official plugin (OOBE message 1).
    public static let watchInfoRequest: [UInt8] = [0x01, 0x04, 0x02, 0, 0, 0, 0x05, 0, 0x0e]

    // MARK: CRC

    public static func crc16<S: Sequence>(_ data: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xa001 : crc >> 1
            }
        }
        return crc
    }

    static func crcBytes<S: Sequence>(_ data: S) -> [UInt8] where S.Element == UInt8 {
        let v = crc16(data)
        return [UInt8(v >> 8), UInt8(v & 0xff)]
    }

    // MARK: Capability handshake (band -> phone, 105 bytes)

    public static func isCapabilityRequest(_ data: [UInt8]) -> Bool {
        data.count == 105 && data[1] == capabilityRequestOpcode
    }

    public static func capabilityResponse(_ request: [UInt8]) throws -> [UInt8] {
        try ensure(request.count == 105 && request[0] == 104, "Invalid Fit3 capability length")
        try ensure(request[1] == capabilityRequestOpcode, "Not a capability request")
        var response = request
        response[1] = capabilityResponseOpcode
        return response
    }

    public static func negotiatedTransportMtu(_ request: [UInt8]) -> Int {
        precondition(request.count == 105)
        return (Int(request[0x2c]) << 8) | Int(request[0x2d])
    }

    // MARK: Encoding

    public static func encodeSingle(service: Int, message: [UInt8], transportMtu: Int) throws -> [UInt8] {
        try ensure((1...31).contains(service) && !message.isEmpty, "Bad service/message")
        try ensure((15...500).contains(transportMtu), "Bad transport MTU \(transportMtu)")
        let body: [UInt8] = [0, 0x40, UInt8(service), UInt8(service)] + message
        let frame = try encodeTransportBody(body, transportMtu: transportMtu)
        try ensure(frame.count <= transportMtu, "Fragmentation required")
        return frame
    }

    /// Encode one SAP message into one or more frames.
    /// - Parameters:
    ///   - transportMtu: value announced by the band; decides the prefix layout.
    ///   - maxFrame: largest frame we may write in one GATT write (defaults to transportMtu).
    public static func encodeMessage(service: Int, message: [UInt8], transportMtu: Int,
                                     maxFrame: Int? = nil, stream: Int = 0) throws -> [[UInt8]] {
        try ensure((1...31).contains(service) && !message.isEmpty, "Bad service/message")
        try ensure((15...500).contains(transportMtu), "Bad transport MTU \(transportMtu)")
        try ensure((0...7).contains(stream), "Bad stream")
        let limit = min(maxFrame ?? transportMtu, transportMtu)

        if let single = try? encodeSingle(service: service, message: message, transportMtu: transportMtu),
           single.count <= limit {
            return [single]
        }

        let prefixSize = transportMtu < 256 ? 2 : 4
        let crcSize = 2
        let firstCapacity = limit - prefixSize - crcSize - 4
        let continueCapacity = limit - prefixSize - crcSize - 2
        try ensure(firstCapacity > 0 && continueCapacity > 0, "MTU too small")

        var out: [[UInt8]] = []
        var sequence = 0
        let firstTake = min(firstCapacity, message.count)
        let firstBody: [UInt8] = [1 << 1, UInt8((stream << 5) | sequence), UInt8(service), UInt8(service)]
            + message[0..<firstTake]
        out.append(try encodeTransportBody(firstBody, transportMtu: transportMtu))
        var offset = firstTake
        sequence += 1

        while offset < message.count {
            try ensure(sequence <= 15, "SAP message needs more than 16 fragments")
            let take = min(continueCapacity, message.count - offset)
            let last = offset + take >= message.count
            let kind = last ? 3 : 2
            let body: [UInt8] = [UInt8(kind << 1), UInt8((stream << 5) | sequence)]
                + message[offset..<(offset + take)]
            out.append(try encodeTransportBody(body, transportMtu: transportMtu))
            offset += take
            sequence += 1
        }
        return out
    }

    static func encodeTransportBody(_ body: [UInt8], transportMtu: Int) throws -> [UInt8] {
        let prefix: [UInt8]
        if transportMtu < 256 {
            try ensure(body.count <= 255, "Body too long")
            prefix = [UInt8(body.count), UInt8(body.count)]
        } else {
            try ensure(body.count <= 0xffff, "Body too long")
            let length: [UInt8] = [UInt8(body.count >> 8), UInt8(body.count & 0xff)]
            prefix = length + crcBytes(length)
        }
        return prefix + body + crcBytes(body)
    }

    // MARK: Decoding

    public struct Fragment: Equatable {
        public let kind: Int          // 0 single, 1 first, 2 continue, 3 last
        public let sequence: Int
        public let stream: Int
        public let serviceId: Int?
        public let payload: [UInt8]
    }

    public static func decodeFrame(_ frame: [UInt8]) throws -> Fragment {
        try ensure(frame.count >= 8, "Frame too short")
        let shortLength = Int(frame[0])
        let shortOk = frame[0] == frame[1] && shortLength + 4 == frame.count
        let longLength = (shortLength << 8) | Int(frame[1])
        let longOk = frame.count >= 10 && longLength + 6 == frame.count &&
            Array(frame[2...3]) == crcBytes(frame[0...1])
        let prefixSize: Int
        if shortOk { prefixSize = 2 } else if longOk { prefixSize = 4 } else { throw Fit3Error("Invalid SAP frame prefix") }

        let body = Array(frame[prefixSize..<(frame.count - 2)])
        try ensure(Array(frame[(frame.count - 2)...]) == crcBytes(body), "Invalid SAP frame CRC")
        try ensure(body.count >= 2, "Body too short")
        let flags = Int(body[0])
        try ensure((flags >> 6) == 0, "Unsupported SAP control frame")
        let kind = (flags >> 1) & 3
        let seqFlags = Int(body[1])
        let first = kind == 0 || kind == 1
        if first { try ensure(body.count >= 4 && body[2] == body[3], "Bad service header") }
        return Fragment(
            kind: kind,
            sequence: seqFlags & 0x0f,
            stream: seqFlags >> 5,
            serviceId: first ? Int(body[2]) : nil,
            payload: Array(body[(first ? 4 : 2)...])
        )
    }

    public static func findSoftwareVersion(_ message: [UInt8]) -> String? {
        let ascii = String(decoding: message.map { $0 < 128 ? $0 : 0x2e }, as: UTF8.self)
        guard let range = ascii.range(of: "R390[A-Z0-9]{7,12}", options: .regularExpression) else { return nil }
        return String(ascii[range])
    }
}

/// Assembles one SAP message at a time; invalid continuations are dropped.
public final class SapReassembler {
    private var serviceId: Int?
    private var stream = -1
    private var nextSequence = 0
    private var data: [UInt8] = []

    public init() {}

    public func push(_ fragment: SapCodec.Fragment) -> (service: Int, message: [UInt8])? {
        if fragment.kind == 0 {
            reset()
            return fragment.serviceId.map { ($0, fragment.payload) }
        }
        if fragment.kind == 1 {
            reset()
            guard fragment.sequence == 0, let id = fragment.serviceId else { return nil }
            serviceId = id
            stream = fragment.stream
            nextSequence = 1
            data = fragment.payload
            return nil
        }
        guard let id = serviceId else { return nil }
        if fragment.stream != stream || fragment.sequence != nextSequence ||
            !(2...3).contains(fragment.kind) || data.count + fragment.payload.count > 4096 {
            reset()
            return nil
        }
        data += fragment.payload
        nextSequence += 1
        guard fragment.kind == 3 else { return nil }
        let result = (id, data)
        reset()
        return result
    }

    public func reset() {
        serviceId = nil
        stream = -1
        nextSequence = 0
        data = []
    }
}
