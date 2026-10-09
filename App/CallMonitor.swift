import Foundation
import Fit3Kit
#if canImport(CallKit) && os(iOS)
import CallKit

/// Watches phone + VoIP (WhatsApp etc.) calls via CallKit and makes the band ring
/// using Samsung's call service, exactly like the official Android plugin.
/// iOS does not tell third-party apps who is calling, so the band shows a generic caller.
/// Only fires while the app is running – see KeepAlive for the background part.
final class CallMonitor: NSObject, CXCallObserverDelegate {
    static let shared = CallMonitor()

    private let observer = CXCallObserver()
    private var ringingCall: UUID?

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

        if incomingRinging, ringingCall == nil {
            ringingCall = call.uuid
            Logbook.shared.add("Incoming call detected")
            band.startRinging(name: "Incoming call", number: "")
            return
        }

        guard call.uuid == ringingCall, call.hasConnected || call.hasEnded else { return }
        ringingCall = nil
        let answered = call.hasConnected
        Logbook.shared.add(answered ? "Call answered" : "Missed call")
        band.endCall(answered: answered, notifyMissed: notifyMissed)
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
