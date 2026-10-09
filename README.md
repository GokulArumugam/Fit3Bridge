# Fit3 Bridge

Unofficial iPhone companion for the **Samsung Galaxy Fit3 (SM-R390)**.

The Bluetooth protocol (Samsung "SAP" over BLE GATT service `0x1A1A`) is ported from
[yuriyurin/Fit3-App](https://github.com/yuriyurin/Fit3-App) (GPL-3.0-only), so this project is GPL-3.0 too.
Not affiliated with Samsung.

> **Working on this repo (human or AI agent)? Start with [`AGENTS.md`](AGENTS.md)**, then
> [`docs/STATUS.md`](docs/STATUS.md) (progress + next steps) and [`docs/PROTOCOL.md`](docs/PROTOCOL.md).

## What works / planned

| Feature | Status |
|---|---|
| Connect, handshake, first-run setup of the band | ✅ verified on the real band (web test page) |
| Notifications (test, SMS/Gmail samples) | ✅ verified on the real band |
| Incoming call **ringing** (Samsung call service) + missed call | ✅ verified on the real band |
| Time / language sync, battery | ✅ |
| Native iOS app (background connection, call alerts, Shortcuts SMS action) | ✅ builds in CI – ⏳ not yet installed on the phone |
| Gmail (via iCloud forward + Mail automation) | ⏭ next |
| Steps / heart rate / sleep → Apple Health | ⏭ later |
| Installing new watch faces | 🔬 research (needs Bluetooth Classic, which iOS apps can't use) |
| WhatsApp messages | ❌ not possible on iOS without extra hardware |

## Layout

```
Fit3Kit/            Swift package: pure protocol code (no Bluetooth), testable on the Mac
  Sources/Fit3Kit/        SAMessage, SapCodec (frames/CRC/fragmenting), OOBE, battery, notifications, calls, watch faces
  Sources/Fit3KitChecks/  `swift run Fit3KitChecks` – checks against real captured packets
App/                iOS app (SwiftUI)
  BandManager.swift       CoreBluetooth + SAP session (handshake, setup, write queue, reconnect)
  CallMonitor.swift       CallKit call observer → band
  KeepAlive.swift         optional silent audio so iOS keeps the app running (for calls)
  SendToBandIntent.swift  Shortcuts action "Send to Galaxy Fit3"
  ContentView.swift       UI, scanner, protocol log, Shortcuts help
web/                Web Bluetooth test page for the Bluefy browser (https://gokularumugam.github.io/Fit3Bridge/)
docs/               STATUS.md (progress/roadmap), PROTOCOL.md (protocol reference)
project.yml         XcodeGen spec → `xcodegen generate` creates Fit3Bridge.xcodeproj
```

## Install without a Mac/Xcode (recommended)

1. **Cloud build:** every push to `main` runs `.github/workflows/build.yml` on GitHub's macOS runners and
   publishes `Fit3Bridge.ipa` as the **latest** release (`https://github.com/<you>/Fit3Bridge/releases/tag/latest`).
2. **SideStore** (free) installs and signs the IPA on the iPhone with your free Apple ID and refreshes it
   every 7 days on the phone itself. One-time setup needs *any* computer (Windows/Linux/Mac, e.g. a friend's)
   to create the pairing file – see https://docs.sidestore.io. After that no computer is needed.
3. In SideStore: **My Apps → +** → pick the downloaded `Fit3Bridge.ipa`.

**Quick protocol test, no install at all:** `web/` is published to GitHub Pages by `pages.yml`.
Open `https://<you>.github.io/Fit3Bridge/` in the free **Bluefy** browser on the iPhone →
Connect → Send notification. (Foreground only – just for testing.)

## Build & install with Xcode (if you have a Mac you can use)

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
