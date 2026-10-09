# Fit3 Bridge

Unofficial iPhone companion for the **Samsung Galaxy Fit3 (SM-R390)**.

The Bluetooth protocol (Samsung "SAP" over BLE GATT service `0x1A1A`) is ported from
[yuriyurin/Fit3-App](https://github.com/yuriyurin/Fit3-App) (GPL-3.0-only), so this project is GPL-3.0 too.
Not affiliated with Samsung.

## What works / planned

| Feature | Status |
|---|---|
| Connect, handshake, first-run setup of the band | ✅ v0.1 (needs real-band testing) |
| Time / timezone / language sync | ✅ v0.1 |
| Battery level | ✅ v0.1 |
| Test notification | ✅ v0.1 |
| Incoming / missed call alerts (no caller name – iOS limit) | ✅ v0.1 |
| SMS/iMessage via Shortcuts "Message" automation | ✅ v0.1 |
| Gmail (via iCloud forward + Mail automation) | ⏭ next |
| Steps / heart rate / sleep → Apple Health | ⏭ later |
| WhatsApp messages | ❌ not possible on iOS without extra hardware |

## Layout

```
Fit3Kit/            Swift package: pure protocol code (no Bluetooth), testable on the Mac
  Sources/Fit3Kit/        SAMessage, SapCodec (frames/CRC/fragmenting), OOBE, battery, notifications
  Sources/Fit3KitChecks/  `swift run Fit3KitChecks` – checks against real captured packets
App/                iOS app (SwiftUI)
  BandManager.swift       CoreBluetooth + SAP session (handshake, setup, write queue, reconnect)
  CallMonitor.swift       CallKit call observer → band
  KeepAlive.swift         optional silent audio so iOS keeps the app running (for calls)
  SendToBandIntent.swift  Shortcuts action "Send to Galaxy Fit3"
  ContentView.swift       UI, scanner, protocol log, Shortcuts help
project.yml         XcodeGen spec → `xcodegen generate` creates Fit3Bridge.xcodeproj
```

## Build & install (free Apple ID)

1. Install **Xcode** from the App Store, open it once, accept the licence, and let it install the iOS platform.
2. Xcode → Settings → Accounts → **+** → Apple ID (a free account is fine).
3. `open ~/projects/Fit3Bridge/Fit3Bridge.xcodeproj`
4. Select the **Fit3Bridge** target → *Signing & Capabilities* → Team = *Your Name (Personal Team)*.
   If the bundle id is "not available", change `com.fit3bridge.gokul` to something unique.
5. Plug in the iPhone (USB-C), trust the Mac, then on the iPhone:
   Settings → Privacy & Security → **Developer Mode** → On (phone restarts).
6. Pick the iPhone as run destination and press **▶︎ Run**.
7. First launch only: iPhone Settings → General → VPN & Device Management → trust your developer certificate.

Free-account apps expire after **7 days** – just press Run again (or use SideStore to refresh on the phone).

## First connection

1. iPhone Settings → Bluetooth → ⓘ next to the Galaxy Fit3 → **Forget This Device**.
2. Reset the band (on the band: Settings → General → Reset) so it shows its pairing screen.
3. Open Fit3 Bridge → **Find my Galaxy Fit3** → tap the band. Accept any pairing prompt.
4. Status should go *Handshaking → Setting up → Connected*. Tap **Send test notification**.
5. If anything fails: Protocol log → share icon → send the log file.

## Regenerating the project

```
brew install xcodegen
cd ~/projects/Fit3Bridge && xcodegen generate
cd Fit3Kit && swift run Fit3KitChecks
```
