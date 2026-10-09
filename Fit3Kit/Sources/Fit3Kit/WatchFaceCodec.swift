// Port of the watch-face parts of Fit3SapCodec.kt from yuriyurin/Fit3-App (GPL-3.0-only).
import Foundation

/// Watch faces (service 6). Only faces already installed on the band can be selected over BLE;
/// installing new faces needs Bluetooth Classic RFCOMM, which iOS apps cannot use.
public enum WatchFaceCodec {
    public static let allFacesInfoRequest: [UInt8] = [0x00]
    public static let installedFacesRequest: [UInt8] = [0x01]
    public static let currentFaceRequest: [UInt8] = [0x02]

    public struct Face: Equatable, Identifiable, Sendable {
        public let id: Int          // full id (may be > 255, from the wf_name-NNNNN name)
        public let wireId: Int      // low byte the band uses on the wire
        public let sampler: Int     // style
        public let name: String?
        public let current: Bool
        public var selectable: Bool { (1...255).contains(wireId) }
        public var label: String {
            if let name, !name.hasPrefix("wf_name-") { return name }
            return "Face \(id)"
        }
    }

    public struct FacesInfo: Equatable, Sendable {
        public let currentId: Int
        public let maximum: Int?
        public let faces: [Face]
    }

    public static func setCurrentFaceRequest(id: Int, sampler: Int) -> [UInt8]? {
        guard (1...255).contains(id), (0...9).contains(sampler) else { return nil }
        return [0x03, 0x04, UInt8(id), 0x1d, UInt8(sampler)]
    }

    static func parseEntries(_ m: [UInt8], start: Int, count: Int) -> [Face]? {
        guard count <= 100 else { return nil }
        var off = start
        var out: [Face] = []
        for _ in 0..<count {
            guard off + 2 <= m.count, m[off] == 24 else { return nil }
            off += 1
            let fields = Int(m[off]); off += 1
            guard (1...32).contains(fields) else { return nil }
            var seen = Set<UInt8>()
            var id: Int?, sampler: Int?, name: String?, current = false
            for _ in 0..<fields {
                guard off + 2 <= m.count else { return nil }
                let field = m[off]; off += 1
                guard seen.insert(field).inserted else { return nil }
                let value = Int(m[off]); off += 1
                switch field {
                case 5, 6, 7, 17, 19:
                    guard off + value <= m.count else { return nil }
                    if field == 6 {
                        let text = String(decoding: m[off..<(off + value)], as: UTF8.self)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
                        name = text.isEmpty ? nil : text
                    }
                    off += value
                case 4, 8...16, 18, 29, 30:
                    if field == 4 { id = value }
                    if field == 8 || field == 29 {
                        if let s = sampler, s != value { return nil }
                        sampler = value
                    }
                    if field == 11 {
                        guard value <= 1 else { return nil }
                        current = value == 1
                    }
                default:
                    return nil
                }
            }
            guard let wire = id, let style = sampler else { return nil }
            var fullId = wire
            if let name, name.hasPrefix("wf_name-"), name.count == 13, let n = Int(name.dropFirst(8)) {
                guard n >= 1, n & 255 == wire else { return nil }
                fullId = n
            }
            out.append(Face(id: fullId, wireId: wire, sampler: style, name: name, current: current))
        }
        guard off == m.count, out.filter(\.current).count <= 1 else { return nil }
        return out
    }

    /// Response to `allFacesInfoRequest`.
    public static func parseAllFacesInfo(_ m: [UInt8]) -> FacesInfo? {
        guard m.count >= 9, m[0] == 0xc0, m[1] == 0, m[3] == 1, m[5] == 2, m[7] == 3, m[6] == m[8] else { return nil }
        let maximum = Int(m[4]), count = Int(m[8])
        guard maximum > 0, count <= maximum, let faces = parseEntries(m, start: 9, count: count) else { return nil }
        let current = faces.first(where: \.current)
        if !faces.isEmpty { guard let c = current, c.wireId == Int(m[2]) else { return nil } }
        return FacesInfo(currentId: current?.id ?? Int(m[2]), maximum: maximum, faces: faces)
    }

    /// Response to `installedFacesRequest`.
    public static func parseInstalledFaces(_ m: [UInt8]) -> [Face]? {
        guard m.count >= 3, m[0] & 0x7f == 0x41, m[1] == 3 else { return nil }
        return parseEntries(m, start: 3, count: Int(m[2]))
    }

    /// Response to current-face (0x42) or set-face (0x43): [hdr, 4, id, 29, sampler].
    public static func parseSelection(_ m: [UInt8]) -> (id: Int, sampler: Int, changed: Bool)? {
        guard m.count == 5, m[0] == 0x42 || m[0] == 0x43 else { return nil }
        var id: Int?, sampler: Int?
        for i in stride(from: 1, to: 5, by: 2) {
            switch m[i] {
            case 4: id = Int(m[i + 1])
            case 29: sampler = Int(m[i + 1])
            default: return nil
            }
        }
        guard let id, let sampler else { return nil }
        return (id, sampler, m[0] == 0x43)
    }
}
