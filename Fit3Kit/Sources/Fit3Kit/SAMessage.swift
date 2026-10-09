// Port of SaMessageCodec.kt from yuriyurin/Fit3-App (GPL-3.0-only).
import Foundation

public struct Fit3Error: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

@inline(__always)
func ensure(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw Fit3Error(message()) }
}

/// Minimal implementation of Samsung SAMessageData used by Fit3 small control packets.
public enum SAMessage {
    public static let formatFixed = 0
    public static let formatVariable = 1
    public static let typeRequest = 0
    public static let typeResponse = 1

    public struct Header: Equatable {
        public let format: Int
        public let type: Int
        public let id: Int
    }

    public static func header(format: Int, type: Int, id: Int) -> UInt8 {
        precondition((0...1).contains(format) && (0...1).contains(type) && (0...63).contains(id))
        return UInt8((format << 7) | (type << 6) | id)
    }

    public static func parseHeader(_ message: [UInt8]) -> Header? {
        guard let value = message.first.map(Int.init) else { return nil }
        return Header(format: (value >> 7) & 1, type: (value >> 6) & 1, id: value & 0x3f)
    }

    public static func fixedRequest(_ id: Int, _ params: [UInt8]...) -> [UInt8] {
        [header(format: formatFixed, type: typeRequest, id: id)] + params.flatMap { $0 }
    }

    public static func byteParam(_ id: Int, _ value: Int) -> [UInt8] {
        [UInt8(id), UInt8(value)]
    }

    public static func shortParam(_ id: Int, _ value: Int) -> [UInt8] {
        [UInt8(id), UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]
    }

    public static func intParam(_ id: Int, _ value: Int32) -> [UInt8] {
        [UInt8(id)] + le(UInt32(bitPattern: value))
    }

    public static func le(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8((value >> ($0 * 8)) & 0xff) }
    }

    public static func le(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> UInt64($0 * 8)) & 0xff) }
    }

    public static func readLEInt32(_ bytes: [UInt8], _ offset: Int) -> Int32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[offset + i]) << (i * 8) }
        return Int32(bitPattern: v)
    }
}

public extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard let bytes = parseHexBytes(hex) else { return nil }
        self = bytes
    }
}

func parseHexBytes(_ hex: String) -> [UInt8]? {
    let chars = Array(hex.replacingOccurrences(of: " ", with: ""))
    guard chars.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    var i = 0
    while i < chars.count {
        guard let b = UInt8(String([chars[i], chars[i + 1]]), radix: 16) else { return nil }
        out.append(b)
        i += 2
    }
    return out
}
