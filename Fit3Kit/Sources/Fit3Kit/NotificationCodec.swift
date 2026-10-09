// Port of Fit3NotificationCodec.kt from yuriyurin/Fit3-App (GPL-3.0-only).
import Foundation

/// Notification Agent (service 7) packets.
public enum NotificationCodec {
    public static let newWithPopup = 0
    public static let deleteFromMobile = 1
    public static let deleteFromBand = 2
    public static let showOnDevice = 4
    public static let newWithNoPopup = 5
    public static let clearAllFromMobile = 8
    public static let clearAllFromBand = 9
    public static let notificationAction = 10

    public enum BandCommand: Equatable {
        case delete(sequence: Int32)
        case showOnPhone(sequence: Int32)
        case clearAll
    }

    /// Truncate to at most `maxBytes` of UTF-8 without splitting a character.
    static func utf8Prefix(_ value: String, maxBytes: Int) -> [UInt8] {
        var out: [UInt8] = []
        for scalar in value.unicodeScalars {
            let encoded = Array(String(scalar).utf8)
            if out.count + encoded.count > maxBytes { break }
            out += encoded
        }
        return out
    }

    private static func shortText(_ id: UInt8, _ value: String) -> [UInt8] {
        let bytes = utf8Prefix(value, maxBytes: 60)
        return [id, UInt8(bytes.count)] + bytes
    }

    private static func body(_ value: String) -> [UInt8] {
        let bytes = utf8Prefix(value, maxBytes: 100)
        return [4, UInt8(bytes.count & 0xff), UInt8(bytes.count >> 8)] + bytes
    }

    public static func newNotification(
        sequence: Int32,
        title: String,
        text: String,
        appName: String,
        packageName: String,
        when date: Date,
        appId: Int,
        popup: Bool = true,
        category: String? = nil
    ) -> [UInt8] {
        precondition(sequence > 0)
        let hasCategory = !(category ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        let millis = UInt64(max(0, (date.timeIntervalSince1970 * 1000).rounded()))
        var out: [UInt8] = []
        out.append(UInt8(0x80 | (popup ? newWithPopup : newWithNoPopup)))
        out.append(UInt8(10 + (hasCategory ? 1 : 0)))
        out += [0, 1]                                                 // normal notification
        out += [1] + SAMessage.le(UInt32(bitPattern: sequence))       // sequence
        out += shortText(6, String(appId))                            // app id
        out += [2] + SAMessage.le(millis)                             // time (ms)
        out += shortText(3, title)
        out += body(text)
        out += shortText(14, appName)
        out += [15, 1]
        out += [16, 0]
        if hasCategory, let category { out += shortText(12, category) }
        out += shortText(18, packageName)
        return out
    }

    /// Ask the band which icon format it supports. The band only accepts
    /// notifications after this exchange in the Android app, so we always do it.
    public static let iconCapabilityRequest: [UInt8] = [0x0d]

    public static func isIconCapability(_ message: [UInt8]) -> Bool {
        guard let h = SAMessage.parseHeader(message) else { return false }
        return h.id == 13 && message.count >= 2
    }

    public static func deleteFromMobileRequest(sequence: Int32) -> [UInt8] {
        SAMessage.fixedRequest(deleteFromMobile, SAMessage.intParam(1, sequence))
    }

    public static let clearAllFromMobileRequest: [UInt8] = SAMessage.fixedRequest(clearAllFromMobile)

    /// Band acknowledgement of a new notification: (sequence, accepted).
    public static func parseAck(_ message: [UInt8]) -> (sequence: Int32, accepted: Bool)? {
        guard message.count == 8, message[0] == 0x40, message[1] == 1, message[6] == 11,
              let seq = SAMessage.readLEInt32(message, 2) else { return nil }
        return (seq, message[7] == 1)
    }

    public static func parseBandCommand(_ message: [UInt8]) -> BandCommand? {
        guard let h = SAMessage.parseHeader(message), h.type == SAMessage.typeRequest else { return nil }
        func findSequence() -> Int32? {
            guard message.count >= 6 else { return nil }
            for i in 1...(message.count - 5) where message[i] == 1 {
                if let v = SAMessage.readLEInt32(message, i + 1), v > 0 { return v }
            }
            return nil
        }
        switch h.id {
        case deleteFromBand: return findSequence().map { .delete(sequence: $0) }
        case clearAllFromBand: return .clearAll
        case showOnDevice: return findSequence().map { .showOnPhone(sequence: $0) }
        default: return nil
        }
    }
}

/// Fixed "apps" we forward from iOS. IDs >= 20 match the range Samsung allocates for wearable apps.
public enum ForwardedApp: String, CaseIterable, Codable, Sendable {
    case test, phone, messages, mail, other

    public var appId: Int {
        switch self {
        case .test: return 20
        case .phone: return 21
        case .messages: return 22
        case .mail: return 23
        case .other: return 24
        }
    }

    public var displayName: String {
        switch self {
        case .test: return "Fit3 Bridge"
        case .phone: return "Phone"
        case .messages: return "Messages"
        case .mail: return "Mail"
        case .other: return "iPhone"
        }
    }

    /// Android package names the band firmware may already know icons/behaviour for.
    public var packageName: String {
        switch self {
        case .test: return "com.fit3bridge.app"
        case .phone: return "com.samsung.android.dialer"
        case .messages: return "com.samsung.android.messaging"
        case .mail: return "com.google.android.gm"
        case .other: return "com.fit3bridge.other"
        }
    }

    /// Android Notification.CATEGORY_* values.
    public var category: String? {
        switch self {
        case .phone: return "call"
        case .messages: return "msg"
        case .mail: return "email"
        default: return nil
        }
    }
}
