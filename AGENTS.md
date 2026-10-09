# AGENTS.md — start here

Context for any coding agent (or human) picking up this repo. Read this file fully, then
`docs/STATUS.md` (where we are + next steps) and `docs/PROTOCOL.md` (how the band talks).

## What this project is

**Fit3 Bridge** — an unofficial iPhone companion app for the **Samsung Galaxy Fit3 (SM-R390)** band.
Samsung only supports the Fit3 on Android. The owner switched from Android to an **iPhone 17** and the
band stopped getting notifications/calls. This repo re-implements the band's Bluetooth protocol on iOS.

Owner profile / preferences (keep in mind when proposing solutions):
- Lives in **India** (so Apple's EU-only "notification forwarding" is not available).
- iPhone only, **no Android device**, wants a **free** solution (free Apple ID, no paid developer account so far).
- Priorities: **calls, SMS, Gmail** notifications; band should **stay connected all the time**.
- WhatsApp notifications: explicitly **deferred** (impossible on iOS without extra hardware — see STATUS).
- Watch faces: wants to **install new faces** (not just switch) — **lowest priority**.
- Uses **Gmail** (not Apple Mail).
- Band firmware: **R390XXU0AZA3**.

## Repo layout

```
AGENTS.md            this file (CLAUDE.md is a symlink to it)
docs/STATUS.md       progress log, what's verified on the real band, blockers, roadmap
docs/PROTOCOL.md     protocol reference (GATT, SAP framing, every message we use, sources)
README.md            user-facing install instructions

Fit3Kit/             Swift package, pure protocol code (no CoreBluetooth) – testable on macOS
  Sources/Fit3Kit/        SAMessage, SapCodec (framing/CRC/fragments), SetupCodecs (OOBE/battery/
                          language), NotificationCodec, CallCodec, WatchFaceCodec
  Sources/Fit3KitChecks/  `swift run Fit3KitChecks` – assertion runner (XCTest not needed)
App/                 iOS app (SwiftUI, iOS 17+)
  BandManager.swift       CoreBluetooth central + SAP session: handshake, setup, write queue,
                          reconnect, state restoration, notifications, calls, watch faces
  CallMonitor.swift       CXCallObserver → band ringing via call service (SAP 3)
  KeepAlive.swift         optional silent-audio background keep-alive (needed for call alerts)
  SendToBandIntent.swift  App Intent "Send to Galaxy Fit3" (Shortcuts automations: SMS, email)
  ContentView.swift       UI: status, scanner, test buttons, watch faces, protocol log, help
  Logbook.swift           in-memory + file log (shareable from the app)
web/                 Web Bluetooth test page (runs in the free iOS "Bluefy" browser)
  fit3.js                 JS port of the same protocol (keep in sync with Fit3Kit!)
  fit3.test.mjs           `node web/fit3.test.mjs`
  index.html              test UI: connect, notify, real call ringing, watch faces, log
project.yml          XcodeGen spec – the .xcodeproj is generated from it
.github/workflows/   build.yml (unsigned IPA → release "latest"), pages.yml (web/ → GitHub Pages)
```

## Build / test commands

```bash
cd Fit3Kit && swift run Fit3KitChecks      # protocol checks (Swift) – must print "N passed, 0 failed"
node web/fit3.test.mjs                      # protocol checks (JS)
brew install xcodegen && xcodegen generate  # regenerate Fit3Bridge.xcodeproj after editing project.yml/adding files
xcodebuild -project Fit3Bridge.xcodeproj -scheme Fit3Bridge -sdk iphoneos \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build   # local compile check (needs Xcode)
```

Without Xcode you can still typecheck most app code against macOS:
`swiftc -typecheck -swift-version 5 -target arm64-apple-macos14.0 -I Fit3Kit/.build/out/Products/Debug App/*.swift`
(after `swift build` in Fit3Kit). SwiftUI `@State` macro / `navigationBarTitleDisplayMode` errors there are expected.

CI (GitHub Actions, macOS runner, Xcode 16.4):
- `build.yml` on every push to `main`: runs Fit3KitChecks, generates project, builds **unsigned** IPA,
  verifies bundle (Info.plist background modes, `Metadata.appintents`), publishes release tag **`latest`**
  → https://github.com/GokulArumugam/Fit3Bridge/releases/tag/latest
- `pages.yml` on changes under `web/`: runs JS tests, deploys → https://gokularumugam.github.io/Fit3Bridge/

## Conventions / rules

1. **Protocol changes go in BOTH** `Fit3Kit` (Swift) **and** `web/fit3.js`, each with a check/test using
   real captured vectors where possible. The web page is the fastest way to try things on the real band.
2. Keep `Fit3Kit` free of CoreBluetooth/UIKit so it stays testable on macOS / CI.
3. `App/` uses Swift 5 language mode; everything in `BandManager` runs on the main queue.
4. CI uses an **older Swift (Xcode 16.4)**: avoid very long `+`-chained array literals (type-checker timeouts) —
   build them with `var x = ...; x += ...`.
5. Bump `PAGE_VERSION` (and the `<span class="muted">vN</span>` in the title) in `web/index.html` on every web
   change; tell the user to open `...?v=N` to dodge Bluefy caching.
6. After adding/removing Swift files run `xcodegen generate` and commit the regenerated project.
7. Never commit the user's personal identifiers (band serial, Bluetooth MAC, Apple Team ID is OK if they want).
8. Do **not** commit decompiled Samsung code. Describe findings in `docs/PROTOCOL.md` instead.
9. License: GPL-3.0 (protocol derived from yuriyurin/Fit3-App, GPL-3.0-only).

## Where to start next time

See **docs/STATUS.md → "Next steps"**. Short version: the protocol is proven on the real band via the
web page; the native app builds in CI but has **never run on the phone** because installation is blocked
(the only Mac available so far is a locked-down work laptop). Step 1 is getting the IPA onto the iPhone
(SideStore from the user's personal laptop, or Xcode on a personal Mac), then test the native app.
