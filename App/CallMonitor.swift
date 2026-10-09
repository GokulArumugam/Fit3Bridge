import Foundation
import Fit3Kit
#if canImport(CallKit) && os(iOS)
import CallKit

/// Watches phone + VoIP (WhatsApp etc.) calls via CallKit and buzzes the band.
/// iOS does not tell third-party apps who is calling, so the band only shows "Incoming call".
/// This only fires while the app is running – see KeepAlive for the background part.
final class CallMonitor: NSObject, CXCallObserverDelegate {
    static let shared = CallMonitor()

    private let observer = CXCallObserver()
    private var bandSequenceByCall: [UUID: Int32] = [:]
    private var ringingCalls: Set<UUID> = []

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "calls.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "calls.enabled") }
    }

    var notifyMissed: Bool {
        get { UserDefaults.standard.object(forKey: "calls.missed") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "calls.missed") }
    }

    func start() {
        observer.setDelegate(self, queue: .main)
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        guard enabled else { return }
        let band = BandManager.shared
        let incomingRinging = !call.isOutgoing && !call.hasConnected && !call.hasEnded

        if incomingRinging && !ringingCalls.contains(call.uuid) {
            ringingCalls.insert(call.uuid)
            Logbook.shared.add("Incoming call detected")
            let sequence = band.show(OutgoingNotification(app: .phone, title: "Incoming call",
                                                          body: "Check your iPhone"))
            if let sequence { bandSequenceByCall[call.uuid] = sequence }
            return
        }

        guard ringingCalls.contains(call.uuid), call.hasConnected || call.hasEnded else { return }
        ringingCalls.remove(call.uuid)
        if let sequence = bandSequenceByCall.removeValue(forKey: call.uuid) {
            band.dismiss(sequence: sequence)
        }
        if call.hasEnded && !call.hasConnected && notifyMissed {
            Logbook.shared.add("Missed call")
            band.show(OutgoingNotification(app: .phone, title: "Missed call", body: "Check your iPhone"))
        }
    }
}
#else
final class CallMonitor {
    static let shared = CallMonitor()
    var enabled = false
    var notifyMissed = false
    func start() {}
}
#endif
