# Status, decisions & next steps

_Last updated: 2026-10-09_

## TL;DR

| Area | State |
|---|---|
| Protocol (SAP over BLE) | ✅ ported, unit-checked against real captured packets (Swift 59 checks, JS 29) |
| **Verified on the real band** (via `web/` page in Bluefy on the iPhone) | ✅ connect + handshake + first-run setup, ✅ notifications show, ✅ **call ringing via call service (SAP 3)**, ✅ answer/hang-up → missed call, battery, time sync |
| Native iOS app (`App/`) | ✅ compiles (CI + local Xcode 27), IPA published as release `latest` — ❌ **never run on the phone yet** |
| Installing the app on the iPhone | ⛔ **blocked** – see "Installation" below |
| SMS via Shortcuts | implemented (App Intent), untested on device |
| Gmail | planned (iCloud-forward trick), not implemented |
| Watch face switching | implemented (app + web); **user actually wants installing new faces** → later |
| WhatsApp messages | ❌ not possible on iOS without extra hardware — deferred by user |

## Timeline of what happened

1. Research: Galaxy Fit3 is Android-only. iOS apps **cannot read other apps' notifications**; the only system
   path is ANCS, which the Fit3 firmware does not implement (stock firmware is compressed — scan inconclusive,
   but behaviour confirms: iPhone pairs, no notifications).
2. Found **yuriyurin/Fit3-App** (GPL-3.0 Android companion) → protocol is Samsung **SAP over plain BLE GATT**,
   no crypto. Ported framing/OOBE/battery/notifications to Swift (`Fit3Kit`) and JS (`web/fit3.js`).
3. Built native app `App/` + XcodeGen project + CI that produces an unsigned IPA.
4. Built the **Bluefy web test page** so the protocol could be tested without installing anything.
   First run failed with `Error: 2` → fixed by using the **full 128-bit service UUID** string in Web Bluetooth
   plus per-step logging/retries (web v3). After that: connect + notifications worked on the real band.
5. Calls initially sent as a normal notification → only a short buzz. **Decompiled Samsung's official
   Fit3 plugin** (`com.samsung.wearable.fit3plugin`, from apkpure, `jadx`) and found the dedicated
   **call agent = SAP service 3** (`providers/sacall/*`). Implemented it (web v5 + app) → band now rings
   continuously; user confirmed "all the things are working as expected".
6. User got Xcode (27.0) on the work Mac, but the Mac's corporate endpoint security **blocks the iPhone's USB
   data channel** (`usbmuxd: start failed ((iokit/common) not permitted)`), so Finder/Xcode never see the phone
   and Developer Mode never appears. Decided: wait for the user's **personal laptop**.

## Installation (current blocker)

Options, in order of preference:
1. **SideStore** (free): one-time setup from any personal Windows/Mac/Linux computer (see docs.sidestore.io,
   "iloader"/pairing file), then install `Fit3Bridge.ipa` from the `latest` release; SideStore re-signs with
   the user's free Apple ID and refreshes every 7 days **on the phone**.
2. **Xcode on a personal Mac**: open project, Signing → Personal Team (personal Apple ID, NOT a work account),
   iPhone Developer Mode on, ▶ Run. Free accounts expire every 7 days. `DEVELOPMENT_TEAM` in `project.yml` is
   empty — set it there (not only in Xcode) or `xcodegen generate` will wipe it.
3. **Paid Apple Developer (~₹8,700/yr) + TestFlight**: no computer at all; would need a CI workflow that signs
   and uploads to App Store Connect (not built yet).

Free-account notes: max 3 sideloaded apps, 7-day expiry; background modes (bluetooth-central, audio) and
App Intents work without paid entitlements.

## Next steps (roadmap)

**P0 — get the native app running**
- [ ] Install via SideStore / personal Mac (above).
- [ ] First run: forget band in iOS Bluetooth settings only if connection fails; app → "Find my Galaxy Fit3".
- [ ] Verify on device: handshake, test notification, **test call alert**, background reconnect after walking
      away, state restoration after the app is killed by iOS (NOT force-quit), keep-alive toggle.
- [ ] Verify `CallMonitor` with real incoming calls (needs "Keep running in background" on).
- [ ] Set up SMS automation (Shortcuts → Automation → Message → "Send to Galaxy Fit3") and verify it runs
      in the background (App Intent `openAppWhenRun = false`).
- [ ] Collect the in-app Protocol log (share icon) if anything fails.

**P1 — Gmail**
- Plan: Gmail → auto-forward to an **@icloud.com** address → Apple Mail app (iCloud has push) →
  Shortcuts **Email** automation → "Send to Galaxy Fit3" (App = Mail). Write in-app help + test.

**P2 — polish**
- Notification **app icons**: band asks for icons (`parseIconCapability`, `APP_ICON_<id>` request, large icons
  use chunked transfer with message 62). See Fit3-App `Fit3NotificationIconSender.kt` / `encodeNotificationIcon`.
- Handle band → phone call buttons on iOS (Decline can't decline on iOS; currently we just stop the band ringing).
- Missed-call clearing (`missedCallDeleteFromMobile`), DND sync.

**P3 — data**
- Health (steps/HR/sleep) → HealthKit: port `Fit3HealthCodec`, `Fit3HealthLargeDataReceiver`,
  `Fit3HealthAcceptance` from Fit3-App. Band sends GM capability requests on service 10 that need replies.
- Weather (`Fit3WeatherCodec`, Open-Meteo), band settings (`Fit3SettingsCodec`), find-my-band.

**P4 — installing new watch faces (user wants this, lowest priority)**
- Fit3-App installs faces / media / firmware over **Bluetooth Classic RFCOMM**
  (SPP UUID `db764ac8-4b08-7f25-aafe-59d03c27bae3`) — **iOS apps cannot open RFCOMM** without MFi.
- Research: does the band offer a BLE path (L2CAP CoC PSM → CoreBluetooth `openL2CAPChannel`, or file
  transfer over SAP service 30 `OTA_TRANSFER` on GATT)? Look in the Samsung plugin for L2CAP / BLE file transfer.
  If not possible, say so clearly.

**Parked**
- WhatsApp messages: needs ANCS or a hardware bridge (ESP32 acting as ANCS client + SAP host). User deferred.
- Caller name on calls: iOS gives third-party apps no caller ID (CXCallObserver has no number/name).

## Known limitations (iOS)

- No access to other apps' notifications (WhatsApp/Gmail app) — only via Shortcuts triggers (Messages, Mail).
- CallKit observer only fires while the app runs → `KeepAlive` (silent audio, mixWithOthers) toggle.
- Force-quitting the app from the app switcher stops background reconnection until it's opened again.
- Bluefy (web page) only works in the foreground — testing tool, not for daily use.
