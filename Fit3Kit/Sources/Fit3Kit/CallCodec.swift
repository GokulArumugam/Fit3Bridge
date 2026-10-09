// Call agent (SAP service 3). Recovered from the official Fit3 plugin
// (com.samsung.wearable.providers.sacall: CallPacketConstructor / CallPacketConstants).
//
// Incoming call:  enableNotification(true) -> contactPacket(...) -> state(.ringing)
// Answered:       state(.offhook) ... later state(.idle)
// Not answered:   state(.idle) -> (2 s later) missedCallPacket(...)
import Foundation

public enum CallCodec {
    public enum State: UInt8 { case idle = 0, ringing = 1, offhook = 2 }

    /// Requests the band sends to the phone on service 3.
    public enum BandAction: Equatable {
        case silence, showOnPhone, reject, missedSync, callBack, rejectWithMessage, clearMissed, unknown(Int)
    }

    static let agentName = "com.samsung.android.providers.sacall.SACallHandlerService"

    static func text(_ id: UInt8, _ value: String) -> [UInt8] {
        let bytes = NotificationCodec.utf8Prefix(value, maxBytes: 127)
        return [id, UInt8(bytes.count)] + bytes
    }

    public static func enableNotification(_ on: Bool = true) -> [UInt8] { [0x08, on ? 1 : 0] }
    public static func state(_ s: State) -> [UInt8] { [0x03, s.rawValue] }
    public static let missedCallDeleteFromMobile: [UInt8] = [0x07]

    public static func contactPacket(name: String, number: String, when date: Date = Date(),
                                     video: Bool = false, exception: Bool = false) -> [UInt8] {
        let shownName = name == number ? "" : name
        var out: [UInt8] = [0x82, 7]
        out += [0, video ? 0 : 1]                                       // call type (1 = voice)
        out += [7] + SAMessage.le(UInt32(1))                            // sequence id
        out += text(5, agentName)
        out += [6] + SAMessage.le(UInt64(max(0, (date.timeIntervalSince1970 * 1000).rounded())))
        out += text(4, shownName)
        out += text(3, number)
        out += [9, exception ? 1 : 0]
        return out
    }

    public static func missedCallPacket(name: String, number: String, when date: Date = Date(), alert: Bool = true) -> [UInt8] {
        let shownName = name == number ? "" : name
        var out: [UInt8] = [0x80 | (alert ? 6 : 10), 3]
        out += text(4, shownName)
        out += text(3, number)
        out += [6] + SAMessage.le(UInt64(max(0, (date.timeIntervalSince1970 * 1000).rounded())))
        return out
    }

    public static func parseBandAction(_ m: [UInt8]) -> BandAction? {
        guard let first = m.first, first & 0x40 == 0 else { return nil }
        switch Int(first & 0x3f) {
        case 1: return .silence
        case 4: return .showOnPhone
        case 5: return .reject
        case 9: return .missedSync
        case 13: return .callBack
        case 14: return .rejectWithMessage
        case 15: return .clearMissed
        case let id: return .unknown(id)
        }
    }
}
