// Port of Fit3OobeCodec.kt, Fit3BatteryCodec.kt and Fit3Languages.kt from yuriyurin/Fit3-App (GPL-3.0-only).
import Foundation

/// Samsung plugin's four-message OOBE (first-run setup) exchange, service 1.
public enum OobeCodec {
    public static let deviceStatusRequest: [UInt8] = [0x02, 0x01, 0x00]
    public static let userAgreementRequest: [UInt8] = [0x84, 0x01, 0x01]

    /// Message 3: language, roaming, epoch seconds (ASCII), UTC offset, 24h flag.
    /// Also used on its own to sync the time.
    public static func initSettingsRequest(date: Date, timeZone: TimeZone, localeId: Int, hour24: Bool = true) -> [UInt8] {
        precondition((0...0xffff).contains(localeId))
        let offset = timeZone.secondsFromGMT(for: date)
        let absOffset = abs(offset)
        let epoch = Array(String(Int64(date.timeIntervalSince1970.rounded(.down))).utf8)
        var out: [UInt8] = [0x83]                                           // variable request, id 3
        out += [1, UInt8(localeId & 0xff), UInt8(localeId >> 8)]            // locale
        out += [2, 0]                                                       // roaming off
        out += [3, UInt8(epoch.count)] + epoch                              // time
        out += [4, offset < 0 ? 1 : 0, UInt8(absOffset & 0xff), UInt8((absOffset >> 8) & 0xff)]
        out += [5, hour24 ? 1 : 0]
        return out
    }

    /// Returns 1...4 for OOBE responses 0x41...0x44.
    public static func responseId(_ message: [UInt8]) -> Int? {
        guard let h = message.first, (0x41...0x44).contains(h) else { return nil }
        return Int(h & 0x3f)
    }
}

/// Settings service 11, MSG_BATTERY_INFO (id 2).
public enum BatteryCodec {
    public static let request = SAMessage.fixedRequest(2)

    public struct Reading: Equatable {
        public let percent: Int
        public let charging: Bool
        public init(percent: Int, charging: Bool) { self.percent = percent; self.charging = charging }
    }

    public static func parse(_ message: [UInt8]) -> Reading? {
        guard let h = SAMessage.parseHeader(message), h.type == SAMessage.typeResponse, h.id == 2 else { return nil }
        var level: Int?
        var charging: Int?
        var i = 1
        while i + 1 < message.count {
            let id = message[i], value = Int(message[i + 1])
            if id == 5, value <= 100 { level = value }
            if id == 6, value <= 3 { charging = value }
            i += 2
        }
        if level == nil || charging == nil, message.count > 2 {
            for p in 1..<(message.count - 1) {
                let value = Int(message[p + 1])
                if message[p] == 5, value <= 100 { level = value }
                if message[p] == 6, value <= 3 { charging = value }
            }
        }
        guard let l = level, let c = charging else { return nil }
        return Reading(percent: l, charging: c != 0)
    }
}

public enum SettingsCodec {
    public static let msgLanguage = 1
    public static let msgFullSettings = 32
    public static let fullSettingsRequest = SAMessage.fixedRequest(msgFullSettings)

    public static func languagePacket(localeId: Int) -> [UInt8] {
        SAMessage.fixedRequest(msgLanguage, SAMessage.shortParam(4, localeId))
    }
}

/// Language IDs the R390 firmware understands (Samsung LocaleUtils IDs).
public enum BandLanguages {
    public static let ids: [String: Int] = [
        "ar": 0, "az-AZ": 2, "be-BY": 92, "bg": 4,
        "bn-BD": 79, "bn-IN": 93, "bs": 7, "ca": 8,
        "cs": 9, "da": 10, "de": 11, "el": 12,
        "en": 13, "en-CA": 77, "en-PH": 78, "en-US": 100,
        "es-ES": 14, "es-US": 83, "et-EE": 101, "eu-ES": 91,
        "fa": 17, "fi": 18, "fr": 20, "fr-CA": 84,
        "ga": 21, "gl-ES": 104, "hi": 24, "hr": 25,
        "hu": 26, "hy-AM": 90, "id": 28, "is-IS": 29,
        "it": 30, "he": 31, "ja": 32, "ka-GE": 105,
        "kk-KZ": 34, "ko": 37, "ky-KG": 38, "lt": 40,
        "lv": 41, "mk-MK": 43, "mn-MN": 45, "mr-IN": 46,
        "ms-MY": 47, "nb": 49, "nl": 51, "pl": 54,
        "pt-BR": 82, "pt-PT": 55, "ro": 56, "ru": 57,
        "sk": 59, "sl": 60, "sq-AL": 61, "sr": 62,
        "sv": 63, "tg": 87, "th": 68, "tk": 88,
        "fil": 19, "tr": 69, "uk": 71, "ur-PK": 72,
        "uz-UZ": 89, "vi": 73, "zh-CN": 96, "zh-HK": 80,
        "zh-TW": 81,
    ]

    /// Best match for an iOS language tag such as "en-IN", "hi-IN", "en-US". Falls back to English.
    public static func localeId(forLanguageTag tag: String) -> Int {
        let parts = tag.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let lang = parts.first?.lowercased() else { return 13 }
        if parts.count > 1, let id = ids["\(lang)-\(parts.last!.uppercased())"] { return id }
        if let id = ids[lang] { return id }
        if let key = ids.keys.sorted().first(where: { $0.hasPrefix(lang + "-") }) { return ids[key]! }
        return 13
    }
}
