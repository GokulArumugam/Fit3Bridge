import Foundation
#if os(iOS)
import AVFoundation

/// Optional: plays inaudible silence (mixed with other audio) so iOS keeps the app running.
/// Without this, iOS suspends the app in the background and CallKit call events are not
/// delivered until the app wakes up. Costs some battery – the user decides.
/// (Fine for a personal sideloaded app; the App Store would not accept it.)
final class KeepAlive {
    static let shared = KeepAlive()

    private var player: AVAudioPlayer?
    private var observing = false

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "keepAlive.enabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "keepAlive.enabled")
            newValue ? start() : stop()
        }
    }

    var isRunning: Bool { player?.isPlaying == true }

    func startIfEnabled() { if enabled { start() } }

    func start() {
        observeInterruptions()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if player == nil {
                let p = try AVAudioPlayer(data: Self.silentWav())
                p.numberOfLoops = -1
                p.volume = 0
                player = p
            }
            player?.play()
            Logbook.shared.add("Keep-alive running")
        } catch {
            Logbook.shared.add("Keep-alive failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        Logbook.shared.add("Keep-alive stopped")
    }

    private func observeInterruptions() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                               object: nil, queue: .main) { [weak self] note in
            guard let self, self.enabled,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            // Calls interrupt our session; resume afterwards.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start() }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.player = nil
            self?.startIfEnabled()
        }
    }

    /// One second of 8 kHz, 16-bit mono silence as a WAV file.
    private static func silentWav() -> Data {
        let sampleRate: UInt32 = 8000
        let samples = Int(sampleRate)
        let dataSize = UInt32(samples * 2)
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        d.append(Data(count: Int(dataSize)))
        return d
    }
}
#else
final class KeepAlive {
    static let shared = KeepAlive()
    var enabled = false
    var isRunning = false
    func startIfEnabled() {}
}
#endif
