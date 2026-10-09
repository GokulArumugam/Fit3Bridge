import AppIntents
import Fit3Kit

/// Which app icon/category the band should use for a Shortcuts-forwarded notification.
enum BandAppKind: String, AppEnum {
    case messages, mail, phone, other

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Band App"
    static var caseDisplayRepresentations: [BandAppKind: DisplayRepresentation] = [
        .messages: "Messages",
        .mail: "Mail",
        .phone: "Phone",
        .other: "Other",
    ]

    var forwardedApp: ForwardedApp {
        switch self {
        case .messages: return .messages
        case .mail: return .mail
        case .phone: return .phone
        case .other: return .other
        }
    }
}

/// Shortcuts action: "Send to Galaxy Fit3". Used by personal automations such as
/// "When I get a message from anyone → Send <Sender> <Message> to band".
struct SendToBandIntent: AppIntent {
    static var title: LocalizedStringResource = "Send to Galaxy Fit3"
    static var description = IntentDescription("Shows a notification on your Galaxy Fit3 band.")
    static var openAppWhenRun = false

    @Parameter(title: "Title")
    var title: String

    @Parameter(title: "Message", default: "")
    var message: String

    @Parameter(title: "App", default: .messages)
    var app: BandAppKind

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$title) and \(\.$message) to band as \(\.$app)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let notification = OutgoingNotification(app: app.forwardedApp,
                                                title: title.isEmpty ? app.forwardedApp.displayName : title,
                                                body: message)
        Logbook.shared.add("Shortcut: \(app.rawValue) – \(title)")
        let result = await BandManager.shared.deliver(notification)
        return .result(value: result)
    }
}

struct Fit3BridgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SendToBandIntent(),
                    phrases: ["Send to band with \(.applicationName)"],
                    shortTitle: "Send to Band",
                    systemImageName: "applewatch.radiowaves.left.and.right")
    }
}
