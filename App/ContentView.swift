import SwiftUI

struct ContentView: View {
    @EnvironmentObject var band: BandManager
    @State private var showingScanner = false
    @State private var callsEnabled = CallMonitor.shared.enabled
    @State private var missedCalls = CallMonitor.shared.notifyMissed
    @State private var keepAlive = KeepAlive.shared.enabled

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if band.hasSavedBand { actionsSection }
                alertsSection
                Section("Help & debugging") {
                    NavigationLink("Set up SMS forwarding (Shortcuts)") { ShortcutsHelpView() }
                    NavigationLink("Protocol log") { LogView() }
                }
            }
            .navigationTitle("Fit3 Bridge")
            .sheet(isPresented: $showingScanner) { ScannerView() }
        }
    }

    private var statusSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "applewatch.side.right")
                    .font(.system(size: 36))
                    .foregroundStyle(band.isReady ? .green : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(band.bandName ?? "No band").font(.headline)
                    Text(band.phase.rawValue).font(.subheadline).foregroundStyle(.secondary)
                    if let v = band.softwareVersion {
                        Text("Firmware \(v)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let b = band.battery {
                    Label("\(b.percent)%", systemImage: b.charging ? "battery.100.bolt" : batteryIcon(b.percent))
                        .font(.subheadline.monospacedDigit())
                }
            }
            .padding(.vertical, 4)
            if !band.lastResult.isEmpty {
                Text(band.lastResult).font(.footnote).foregroundStyle(.secondary)
            }
            Button(band.hasSavedBand ? "Choose a different band" : "Find my Galaxy Fit3") {
                showingScanner = true
            }
        }
    }

    private var actionsSection: some View {
        Section("Band") {
            Button("Send test notification") { band.sendTestNotification() }
                .disabled(!band.isReady)
            Button("Sync time") { band.syncTime() }
                .disabled(!band.isReady)
            Button("Refresh battery") { band.requestBattery() }
                .disabled(!band.isReady)
            Button("Reconnect") { band.reconnect() }
            Button("Forget band", role: .destructive) { band.forgetBand() }
        }
    }

    private var alertsSection: some View {
        Section {
            Toggle("Incoming call alerts", isOn: $callsEnabled)
                .onChange(of: callsEnabled) { _, v in CallMonitor.shared.enabled = v }
            Toggle("Missed call alerts", isOn: $missedCalls)
                .onChange(of: missedCalls) { _, v in CallMonitor.shared.notifyMissed = v }
                .disabled(!callsEnabled)
            Toggle("Keep running in background", isOn: $keepAlive)
                .onChange(of: keepAlive) { _, v in KeepAlive.shared.enabled = v }
        } header: {
            Text("Calls")
        } footer: {
            Text("iOS pauses apps in the background, so call alerts only work reliably with "
                 + "\"Keep running in background\" on. It plays inaudible silence and uses a little extra battery. "
                 + "iOS does not let apps see the caller's name.")
        }
    }

    private func batteryIcon(_ p: Int) -> String {
        switch p {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}

struct ScannerView: View {
    @EnvironmentObject var band: BandManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if band.discovered.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Looking for your band…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(band.discovered) { device in
                        Button {
                            band.choose(device)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                    Text(device.alreadyConnected ? "Connected to iPhone" : "Signal \(device.rssi) dBm")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                    }
                } footer: {
                    Text("Before connecting: in iPhone Settings → Bluetooth, tap ⓘ next to the band and "
                         + "choose \"Forget This Device\". Then reset the band (on the band: Settings → General → Reset) "
                         + "so it shows the pairing screen. If iOS asks to pair, accept.")
                }
                Section {
                    Toggle("Show all Bluetooth devices", isOn: $band.showAllDevices)
                        .onChange(of: band.showAllDevices) { _, _ in band.startScan() }
                }
            }
            .navigationTitle("Find band")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Rescan") { band.startScan() } }
            }
            .onAppear { band.startScan() }
            .onDisappear { band.stopScan() }
        }
    }
}

struct LogView: View {
    @EnvironmentObject var log: Logbook

    var body: some View {
        List(log.lines.reversed()) { line in
            VStack(alignment: .leading, spacing: 2) {
                Text(log.format(line)).font(.caption2).foregroundStyle(.secondary)
                Text(line.text).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Protocol log")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ShareLink(item: log.fileURL) { Image(systemName: "square.and.arrow.up") }
                Button("Clear") { log.clear() }
            }
        }
    }
}

struct ShortcutsHelpView: View {
    var body: some View {
        List {
            Section("SMS / iMessage → band") {
                step(1, "Open the Shortcuts app → Automation → + → Message.")
                step(2, "Leave Sender and Message Contains empty (= every message). Choose \"Run Immediately\" and turn off \"Notify When Run\". Tap Next.")
                step(3, "New Blank Automation → Add Action → search \"Send to Galaxy Fit3\".")
                step(4, "Title: tap it → Select Variable → Shortcut Input → change it to Sender.")
                step(5, "Message: Shortcut Input → Content. App: Messages. Tap Done.")
            }
            Section("Gmail → band") {
                Text("iOS only runs email automations for Apple's Mail app, not Gmail. "
                     + "We'll set this up in the next step (forward Gmail to an iCloud address that Apple Mail pushes instantly).")
                    .font(.callout)
            }
            Section("Test it") {
                Text("Ask someone to text you, or send yourself an iMessage from another device. "
                     + "Check the Protocol log if nothing shows up.")
                    .font(.callout)
            }
        }
        .navigationTitle("Shortcuts setup")
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.headline).frame(width: 22)
            Text(text).font(.callout)
        }
    }
}
