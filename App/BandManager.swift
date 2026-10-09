import Foundation
import CoreBluetooth
import Combine
import Fit3Kit
#if os(iOS)
import UIKit
#endif

enum BandUUID {
    static let service = CBUUID(string: "1A1A") // 00001a1a-0000-1000-8000-00805f9b34fb
    static let notify = CBUUID(string: "797AE4E9-2E58-4FE8-B48D-B5C79599FB9B")
    static let write = CBUUID(string: "63E30BAD-4206-4596-839F-E47CBF7A4B5D")
}

struct DiscoveredBand: Identifiable {
    let id: UUID
    let name: String
    var rssi: Int
    let alreadyConnected: Bool
    let peripheral: CBPeripheral
}

/// A notification waiting to be shown on the band.
struct OutgoingNotification {
    var app: ForwardedApp
    var title: String
    var body: String
    var popup = true
    var created = Date()
}

/// Owns the CoreBluetooth connection and speaks Samsung's SAP protocol to the Galaxy Fit3.
/// Everything runs on the main queue.
final class BandManager: NSObject, ObservableObject {
    static let shared = BandManager()

    enum Phase: String {
        case bluetoothOff = "Bluetooth is off"
        case unauthorized = "Bluetooth permission denied"
        case noBand = "No band selected"
        case scanning = "Scanning…"
        case connecting = "Waiting for band (keep it nearby)…"
        case discovering = "Opening band services…"
        case handshake = "Handshaking with band…"
        case settingUp = "Setting up band…"
        case ready = "Connected"
    }

    // MARK: Published UI state
    @Published private(set) var phase: Phase = .noBand
    @Published private(set) var discovered: [DiscoveredBand] = []
    @Published private(set) var bandName: String?
    @Published private(set) var softwareVersion: String?
    @Published private(set) var battery: BatteryCodec.Reading?
    @Published private(set) var lastResult = ""
    @Published private(set) var faces: [WatchFaceCodec.Face] = []
    @Published private(set) var facesLoading = false
    @Published var showAllDevices = false

    var isReady: Bool { phase == .ready && notificationsReady }
    var hasSavedBand: Bool { savedPeripheralId != nil }

    // MARK: Bluetooth state
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withResponse
    private var generation = 0

    // MARK: SAP state
    private let reassembler = SapReassembler()
    private var transportMtu = 0
    private var sapReady = false
    private var gotSapReply = false
    private var notificationsReady = false
    private var assumedSession = false

    private enum SetupStage { case idle, waitInfo, waitDevice, waitSettings, waitAgreement, complete }
    private var setupStage: SetupStage = .idle

    // MARK: Write queue
    private var writeQueue: [[UInt8]] = []
    private var writeBusy = false
    private var writeToken = 0

    // MARK: Notifications
    private var outbox: [(OutgoingNotification, (String) -> Void)] = []
    enum AckResult { case accepted, rejected, connectionLost }
    private var ackHandlers: [Int32: (AckResult) -> Void] = [:]

    private let log = Logbook.shared
    private let defaults = UserDefaults.standard

    private var savedPeripheralId: UUID? {
        get { defaults.string(forKey: "band.peripheralId").flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: "band.peripheralId") }
    }

    private var storedTransportMtu: Int {
        get { defaults.integer(forKey: "band.transportMtu") }
        set { defaults.set(newValue, forKey: "band.transportMtu") }
    }

    private func nextSequence() -> Int32 {
        var value = Int32(truncatingIfNeeded: defaults.integer(forKey: "band.notificationSequence"))
        value = value <= 0 || value >= Int32.max - 1 ? 1 : value + 1
        defaults.set(Int(value), forKey: "band.notificationSequence")
        return value
    }

    // MARK: Lifecycle

    override init() {
        super.init()
        bandName = defaults.string(forKey: "band.name")
        softwareVersion = defaults.string(forKey: "band.softwareVersion")
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "Fit3BridgeCentral",
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
        #if os(iOS)
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.significantTimeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.syncTime()
        }
        center.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.syncTime()
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.requestBattery()
        }
        #endif
    }

    // MARK: Public API

    func startScan() {
        guard central.state == .poweredOn else { log.add("Scan requested but Bluetooth is not on"); return }
        discovered = []
        // A band already paired in iOS Settings may be connected and not advertising.
        for p in central.retrieveConnectedPeripherals(withServices: [BandUUID.service]) {
            discovered.append(DiscoveredBand(id: p.identifier, name: p.name ?? "Unknown", rssi: 0,
                                             alreadyConnected: true, peripheral: p))
        }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        if peripheral == nil { phase = .scanning }
        log.add("Scanning for bands…")
    }

    func stopScan() {
        if central.isScanning { central.stopScan() }
        if phase == .scanning { phase = hasSavedBand ? .connecting : .noBand }
    }

    func choose(_ band: DiscoveredBand) {
        stopScan()
        disconnect(forget: true)
        savedPeripheralId = band.id
        bandName = band.name
        defaults.set(band.name, forKey: "band.name")
        storedTransportMtu = 0
        log.add("Selected \(band.name) (\(band.id))")
        connect(band.peripheral)
    }

    func forgetBand() {
        disconnect(forget: true)
        savedPeripheralId = nil
        bandName = nil
        softwareVersion = nil
        battery = nil
        defaults.removeObject(forKey: "band.name")
        defaults.removeObject(forKey: "band.softwareVersion")
        phase = .noBand
        log.add("Band forgotten")
    }

    func reconnect() {
        guard let p = peripheral ?? savedPeripheral() else { return }
        log.add("Manual reconnect")
        disconnect(forget: false)
        connect(p)
    }

    func syncTime() {
        guard sapReady else { return }
        send(service: SapService.oobe, OobeCodec.initSettingsRequest(
            date: Date(), timeZone: .current, localeId: currentLocaleId(), hour24: uses24HourClock()))
        lastResult = "Time synced"
    }

    func requestBattery() {
        guard sapReady else { return }
        send(service: SapService.settings, BatteryCodec.request)
    }

    func sendTestNotification() {
        enqueue(OutgoingNotification(app: .test, title: "Hello from iPhone",
                                     body: "If you can read this, Fit3 Bridge works 🎉")) { [weak self] result in
            self?.lastResult = result
        }
    }

    /// Queue a notification. Completion receives a human readable result.
    /// Returns immediately; delivery waits (up to 2 minutes) for the band to be ready.
    func enqueue(_ notification: OutgoingNotification, completion: @escaping (String) -> Void = { _ in }) {
        outbox.removeAll { Date().timeIntervalSince($0.0.created) > 120 }
        if outbox.count >= 20 { outbox.removeFirst().1("Dropped: too many queued") }
        outbox.append((notification, completion))
        if isReady { flushOutbox() } else {
            log.add("Queued \(notification.app.rawValue) notification until band is ready")
            ensureConnecting()
        }
    }

    /// Async helper for App Intents / Shortcuts: waits for delivery (or timeout).
    @MainActor
    func deliver(_ notification: OutgoingNotification, timeout: TimeInterval = 25) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            var finished = false
            func finish(_ result: String) {
                guard !finished else { return }
                finished = true
                continuation.resume(returning: result)
            }
            enqueue(notification) { finish($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                finish("Band not reachable yet – will retry for 2 minutes")
            }
        }
    }

    /// Show a notification immediately if possible. Returns its sequence number (for later deletion).
    @discardableResult
    func show(_ n: OutgoingNotification, completion: ((String) -> Void)? = nil) -> Int32? {
        guard isReady else {
            enqueue(n) { completion?($0) }
            return nil
        }
        let sequence = nextSequence()
        let packet = NotificationCodec.newNotification(
            sequence: sequence, title: n.title, text: n.body, appName: n.app.displayName,
            packageName: n.app.packageName, when: n.created, appId: n.app.appId,
            popup: n.popup, category: n.app.category)
        send(service: SapService.notifications, packet)
        let label = "\(n.app.displayName): \(n.title)"
        var done = false
        ackHandlers[sequence] = { [weak self] ack in
            done = true
            let result: String
            switch ack {
            case .accepted: result = "Shown on band – \(label)"
            case .rejected: result = "Band rejected – \(label)"
            case .connectionLost: result = "Connection lost while sending – \(label)"
            }
            self?.log.add(result)
            completion?(result)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard !done, self?.ackHandlers.removeValue(forKey: sequence) != nil else { return }
            let result = "Sent (no confirmation from band) – \(label)"
            self?.log.add(result)
            completion?(result)
        }
        return sequence
    }

    // MARK: Watch faces

    func loadWatchFaces() {
        guard sapReady else { return }
        facesLoading = true
        send(service: SapService.watchface, WatchFaceCodec.allFacesInfoRequest)
        let gen = generation
        after(3, gen) { me in
            if me.facesLoading { me.send(service: SapService.watchface, WatchFaceCodec.installedFacesRequest) }
        }
        after(8, gen) { me in
            if me.facesLoading { me.facesLoading = false; me.lastResult = "Band did not send its watch faces" }
        }
    }

    func selectWatchFace(_ face: WatchFaceCodec.Face) {
        guard sapReady, let packet = WatchFaceCodec.setCurrentFaceRequest(id: face.wireId, sampler: face.sampler) else {
            lastResult = "Choose this face on the band (touch & hold the watch face)"
            return
        }
        lastResult = "Switching watch face…"
        send(service: SapService.watchface, packet)
    }

    // MARK: Test alerts

    /// Rings the band for 10 seconds, then turns it into a missed call.
    func sendTestCall() {
        startRinging(name: "Test call", number: "")
        lastResult = "Ringing for 10 s…"
        let gen = generation
        after(10, gen) { me in
            guard me.callRinging else { return }
            me.endCall(answered: false)
            me.lastResult = "Test call ended (missed)"
        }
    }

    // MARK: Calls (service 3 – Samsung call agent)

    private(set) var callRinging = false
    private var lastCaller = (name: "", number: "")

    /// Makes the band ring continuously (until `endCall`).
    func startRinging(name: String, number: String) {
        guard sapReady else {
            log.add("Call while band not connected – skipped")
            return
        }
        lastCaller = (name, number)
        callRinging = true
        send(service: SapService.call, CallCodec.enableNotification(true))
        send(service: SapService.call, CallCodec.contactPacket(name: name, number: number))
        send(service: SapService.call, CallCodec.state(.ringing))
    }

    /// Stops the ringing. If not answered, the band also gets a missed-call entry.
    func endCall(answered: Bool, notifyMissed: Bool = true) {
        guard callRinging else { return }
        callRinging = false
        guard sapReady else { return }
        if answered {
            send(service: SapService.call, CallCodec.state(.offhook))
            let gen = generation
            after(2, gen) { $0.send(service: SapService.call, CallCodec.state(.idle)) }
        } else {
            send(service: SapService.call, CallCodec.state(.idle))
            if notifyMissed {
                let caller = lastCaller
                let gen = generation
                after(2, gen) { $0.send(service: SapService.call, CallCodec.missedCallPacket(name: caller.name, number: caller.number)) }
            }
        }
    }

    private func handleCallAction(_ action: CallCodec.BandAction) {
        log.add("Band call button: \(action)")
        switch action {
        case .reject, .rejectWithMessage:
            // iOS does not let apps decline calls. Stop the band ringing at least.
            if callRinging {
                callRinging = false
                send(service: SapService.call, CallCodec.state(.idle))
            }
            lastResult = "Declining from the band isn't possible on iPhone – band silenced"
        case .silence:
            lastResult = "Band muted the call alert"
        default:
            break
        }
    }

    func dismiss(sequence: Int32) {
        guard sapReady else { return }
        send(service: SapService.notifications, NotificationCodec.deleteFromMobileRequest(sequence: sequence))
    }

    // MARK: Connection management

    private func savedPeripheral() -> CBPeripheral? {
        guard let id = savedPeripheralId else { return nil }
        return central.retrievePeripherals(withIdentifiers: [id]).first
    }

    private func ensureConnecting() {
        guard central.state == .poweredOn else { return }
        if let p = peripheral {
            if p.state == .disconnected { connect(p) }
        } else if let p = savedPeripheral() {
            connect(p)
        }
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        phase = .connecting
        // iOS keeps a pending connect alive forever (also in background), so no timeout needed.
        central.connect(p, options: nil)
        log.add("Connecting to \(p.name ?? p.identifier.uuidString)…")
    }

    private func resetSession() {
        generation += 1
        reassembler.reset()
        transportMtu = 0
        sapReady = false
        gotSapReply = false
        notificationsReady = false
        assumedSession = false
        setupStage = .idle
        writeQueue.removeAll()
        writeBusy = false
        writeToken += 1
        for handler in ackHandlers.values { handler(.connectionLost) }
        ackHandlers.removeAll()
    }

    private func disconnect(forget: Bool) {
        resetSession()
        if let p = peripheral, p.state != .disconnected { central.cancelPeripheralConnection(p) }
        writeChar = nil
        notifyChar = nil
        if forget { peripheral = nil }
    }

    /// Something went wrong mid-session: drop the link and let iOS reconnect.
    private func fail(_ reason: String) {
        log.add("⚠️ \(reason) – reconnecting")
        guard let p = peripheral else { return }
        resetSession()
        central.cancelPeripheralConnection(p) // didDisconnect will reconnect
    }

    // MARK: SAP protocol

    private func send(service: Int, _ message: [UInt8]) {
        guard sapReady, let p = peripheral else { return }
        do {
            let maxFrame = p.maximumWriteValueLength(for: writeType)
            let frames = try SapCodec.encodeMessage(service: service, message: message,
                                                    transportMtu: transportMtu, maxFrame: maxFrame)
            log.add("TX \(SapService.name(service)) \(preview(message))")
            writeQueue.append(contentsOf: frames)
            pump()
        } catch {
            log.add("Encode failed: \(error)")
        }
    }

    private func writeRaw(_ bytes: [UInt8]) {
        writeQueue.append(bytes)
        pump()
    }

    private func pump() {
        guard !writeBusy, !writeQueue.isEmpty, let p = peripheral, let c = writeChar, p.state == .connected else { return }
        if writeType == .withoutResponse && !p.canSendWriteWithoutResponse { return } // peripheralIsReady resumes
        let bytes = writeQueue.removeFirst()
        writeBusy = true
        writeToken += 1
        let token = writeToken
        p.writeValue(Data(bytes), for: c, type: writeType)
        let delay: TimeInterval = writeType == .withResponse ? 8 : 0.08
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.writeBusy, self.writeToken == token else { return }
            if self.writeType == .withResponse {
                self.fail("Band did not confirm a write")
            } else {
                self.writeBusy = false
                self.pump()
            }
        }
    }

    private func handleIncoming(_ data: [UInt8]) {
        if SapCodec.isCapabilityRequest(data) {
            handleCapability(data)
            return
        }
        guard let fragment = try? SapCodec.decodeFrame(data) else {
            log.add("RX (unparsed) \(preview(data))")
            return
        }
        guard let (service, message) = reassembler.push(fragment) else { return }
        gotSapReply = true
        log.add("RX \(SapService.name(service)) \(preview(message))")

        switch service {
        case SapService.oobe:
            if handleSetupReply(message) { return }
            if message.first == 0x41, let v = SapCodec.findSoftwareVersion(message) { setSoftwareVersion(v) }
        case SapService.settings:
            if let reading = BatteryCodec.parse(message) {
                battery = reading
                log.add("Battery \(reading.percent)%\(reading.charging ? " (charging)" : "")")
            }
        case SapService.notifications:
            if NotificationCodec.isIconCapability(message) {
                markNotificationsReady("band answered capability")
            } else if let ack = NotificationCodec.parseAck(message) {
                ackHandlers.removeValue(forKey: ack.sequence)?(ack.accepted ? .accepted : .rejected)
            } else if let command = NotificationCodec.parseBandCommand(message) {
                log.add("Band command: \(command)")
            }
        case SapService.call:
            if let action = CallCodec.parseBandAction(message) { handleCallAction(action) }
        case SapService.watchface:
            if let info = WatchFaceCodec.parseAllFacesInfo(message) {
                faces = info.faces; facesLoading = false
            } else if let list = WatchFaceCodec.parseInstalledFaces(message) {
                faces = list; facesLoading = false
            } else if let sel = WatchFaceCodec.parseSelection(message), sel.changed {
                lastResult = "Watch face changed"
                let gen = generation
                after(0.4, gen) { $0.loadWatchFaces() }
            }
        default:
            break // Health, weather, media etc. come later.
        }
    }

    private func handleCapability(_ data: [UInt8]) {
        let mtu = SapCodec.negotiatedTransportMtu(data)
        guard (15...500).contains(mtu), let response = try? SapCodec.capabilityResponse(data) else {
            fail("Invalid capability packet")
            return
        }
        let maxWrite = peripheral?.maximumWriteValueLength(for: writeType) ?? 0
        log.add("Band capability: transport MTU \(mtu), iOS write limit \(maxWrite)")
        guard maxWrite >= response.count else {
            fail("BLE MTU too small (\(maxWrite) < \(response.count))")
            return
        }
        transportMtu = mtu
        storedTransportMtu = mtu
        sapReady = true
        assumedSession = false
        writeRaw(response)
        phase = .settingUp
        let gen = generation
        after(0.22, gen) { $0.startSetup() }
        after(0.65, gen) { $0.requestNotificationCapability(attempt: 0) }
    }

    private func startSetup() {
        guard sapReady, setupStage == .idle || setupStage == .complete else { return }
        advance(.waitInfo)
        send(service: SapService.oobe, SapCodec.watchInfoRequest)
    }

    private func advance(_ stage: SetupStage) {
        setupStage = stage
        guard stage != .complete && stage != .idle else { return }
        let gen = generation
        after(15, gen) { me in
            guard me.setupStage == stage else { return }
            me.log.add("Setup step \(stage) timed out")
            me.setupStage = .idle
            if me.assumedSession && !me.gotSapReply {
                me.fail("Restored session is not responding")
            } else {
                me.setupFinished()
            }
        }
    }

    private func handleSetupReply(_ message: [UInt8]) -> Bool {
        guard let id = OobeCodec.responseId(message) else { return false }
        switch (setupStage, id) {
        case (.waitInfo, 1):
            if let v = SapCodec.findSoftwareVersion(message) { setSoftwareVersion(v) }
            advance(.waitDevice)
            send(service: SapService.oobe, OobeCodec.deviceStatusRequest)
        case (.waitDevice, 2):
            advance(.waitSettings)
            send(service: SapService.oobe, OobeCodec.initSettingsRequest(
                date: Date(), timeZone: .current, localeId: currentLocaleId(), hour24: uses24HourClock()))
        case (.waitSettings, 3):
            advance(.waitAgreement)
            send(service: SapService.oobe, OobeCodec.userAgreementRequest)
        case (.waitAgreement, 4):
            advance(.complete)
            setupFinished()
        default:
            return false
        }
        return true
    }

    private func setupFinished() {
        log.add("Band setup complete")
        if setupStage != .complete { setupStage = .complete }
        phase = .ready
        send(service: SapService.settings, SettingsCodec.languagePacket(localeId: currentLocaleId()))
        send(service: SapService.call, CallCodec.enableNotification(true)) // as the official plugin does on connect
        let gen = generation
        after(0.3, gen) { $0.requestBattery() }
        flushOutbox()
    }

    private func requestNotificationCapability(attempt: Int) {
        guard sapReady, !notificationsReady else { return }
        if attempt >= 3 {
            markNotificationsReady("no capability reply, trying anyway")
            return
        }
        send(service: SapService.notifications, NotificationCodec.iconCapabilityRequest)
        let gen = generation
        after(3, gen) { $0.requestNotificationCapability(attempt: attempt + 1) }
    }

    private func markNotificationsReady(_ why: String) {
        guard !notificationsReady else { return }
        notificationsReady = true
        log.add("Notifications ready (\(why))")
        objectWillChange.send()
        flushOutbox()
    }

    private func flushOutbox() {
        guard isReady, !outbox.isEmpty else { return }
        let pending = outbox
        outbox.removeAll()
        for (n, completion) in pending { show(n, completion: completion) }
    }

    private func setSoftwareVersion(_ v: String) {
        softwareVersion = v
        defaults.set(v, forKey: "band.softwareVersion")
    }

    // MARK: Helpers

    private func after(_ seconds: TimeInterval, _ gen: Int, _ work: @escaping (BandManager) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.generation == gen else { return }
            work(self)
        }
    }

    private func preview(_ bytes: [UInt8]) -> String {
        bytes.count > 48 ? Array(bytes.prefix(48)).hex + "… (\(bytes.count) bytes)" : bytes.hex
    }

    private func currentLocaleId() -> Int {
        BandLanguages.localeId(forLanguageTag: Locale.preferredLanguages.first ?? "en")
    }

    private func uses24HourClock() -> Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
        return !format.contains("a")
    }
}

// MARK: - CBCentralManagerDelegate

extension BandManager: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        log.add("Restored by iOS with \(restored.count) peripheral(s)")
        if let p = restored.first(where: { $0.identifier == savedPeripheralId }) ?? restored.first {
            peripheral = p
            p.delegate = self
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log.add("Bluetooth on")
            if let p = peripheral {
                if p.state == .connected {
                    // Restored while connected: re-open services; SAP session may still be alive.
                    phase = .discovering
                    p.discoverServices(nil)
                } else {
                    connect(p)
                }
            } else if let p = savedPeripheral() {
                connect(p)
            } else {
                phase = .noBand
            }
        case .unauthorized:
            phase = .unauthorized
        default:
            resetSession()
            phase = .bluetoothOff
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        let looksLikeBand = name.localizedCaseInsensitiveContains("fit3") ||
            name.localizedCaseInsensitiveContains("galaxy fit") ||
            name.localizedCaseInsensitiveContains("R390")
        guard looksLikeBand || (showAllDevices && !name.isEmpty) else { return }
        if let i = discovered.firstIndex(where: { $0.id == p.identifier }) {
            discovered[i].rssi = RSSI.intValue
        } else {
            discovered.append(DiscoveredBand(id: p.identifier, name: name, rssi: RSSI.intValue,
                                             alreadyConnected: false, peripheral: p))
            log.add("Found \(name) rssi \(RSSI)")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        log.add("BLE connected")
        resetSession()
        phase = .discovering
        p.discoverServices(nil) // nil: also log every service, useful for debugging
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log.add("Connect failed: \(error?.localizedDescription ?? "unknown")")
        resetSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.peripheral === p else { return }
            self.connect(p)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log.add("BLE disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        resetSession()
        writeChar = nil
        notifyChar = nil
        guard peripheral === p else { return }
        connect(p) // pending connect; completes whenever the band is back in range
    }
}

// MARK: - CBPeripheralDelegate

extension BandManager: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { fail("Service discovery failed: \(error.localizedDescription)"); return }
        let services = p.services ?? []
        log.add("Services: " + services.map { $0.uuid.uuidString }.joined(separator: ", "))
        guard let sap = services.first(where: { $0.uuid == BandUUID.service }) else {
            log.add("⚠️ SAP service 1A1A not found. Is this a Galaxy Fit3?")
            return
        }
        p.discoverCharacteristics(nil, for: sap)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { fail("Characteristic discovery failed: \(error.localizedDescription)"); return }
        let chars = service.characteristics ?? []
        log.add("Characteristics: " + chars.map { "\($0.uuid.uuidString)(\($0.properties.rawValue))" }.joined(separator: ", "))
        guard let notify = chars.first(where: { $0.uuid == BandUUID.notify }),
              let write = chars.first(where: { $0.uuid == BandUUID.write }) else {
            log.add("⚠️ SAP characteristics missing")
            return
        }
        notifyChar = notify
        writeChar = write
        writeType = write.properties.contains(.write) ? .withResponse : .withoutResponse
        log.add("Write mode: \(writeType == .withResponse ? "with response" : "without response"), " +
                "max write \(p.maximumWriteValueLength(for: writeType))")
        if notify.isNotifying && storedTransportMtu > 0 {
            // iOS restored us with an already-subscribed link; the band will not resend capability.
            assumeExistingSession()
        } else {
            p.setNotifyValue(true, for: notify)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        if let error {
            // An "insufficient authentication/encryption" error here usually means iOS is pairing.
            log.add("Subscribe error: \(error.localizedDescription)")
            return
        }
        guard c.uuid == BandUUID.notify, c.isNotifying else { return }
        phase = .handshake
        log.add("Subscribed, waiting for band handshake…")
        let gen = generation
        after(6, gen) { me in
            guard !me.sapReady else { return }
            if me.storedTransportMtu > 0 {
                me.assumeExistingSession()
            } else {
                me.after(9, gen) { me in
                    if !me.sapReady { me.fail("Band never sent its handshake") }
                }
            }
        }
    }

    /// Re-use the previous SAP session (after iOS restored the app). If the band does not answer
    /// the setup requests, `advance` timeout drops the link so a fresh handshake happens.
    private func assumeExistingSession() {
        guard !sapReady else { return }
        transportMtu = storedTransportMtu
        sapReady = true
        assumedSession = true
        phase = .settingUp
        log.add("Re-using existing session (transport MTU \(transportMtu))")
        startSetup()
        requestNotificationCapability(attempt: 0)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard error == nil, c.uuid == BandUUID.notify, let value = c.value else { return }
        handleIncoming([UInt8](value))
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let error { fail("Write failed: \(error.localizedDescription)"); return }
        writeBusy = false
        pump()
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        if !writeBusy { pump() }
    }
}
