# Galaxy Fit3 (SM-R390) protocol reference

Everything here is implemented in `Fit3Kit/Sources/Fit3Kit/*` (Swift) and `web/fit3.js` (JS).
Firmware tested: **R390XXU0AZA3**.

## Sources

- **yuriyurin/Fit3-App** (GPL-3.0-only, Kotlin, Android): https://github.com/yuriyurin/Fit3-App — transport,
  OOBE, notifications, watch faces, health, weather, media, firmware. Files referenced below live in
  `app/src/main/java/io/github/yuriyurin/fit3companion/{protocol,ble}/`. Its unit tests contain real captured vectors.
- **Samsung official plugin** `com.samsung.wearable.fit3plugin` (closed source). Used only to recover the
  **call agent**. How to reproduce (do not commit the output):
  ```bash
  curl -L -o plugin.apk "https://d.apkpure.com/b/APK/com.samsung.wearable.fit3plugin?version=latest"
  brew install jadx && jadx -d pluginsrc --no-res plugin.apk
  # interesting: sources/com/samsung/wearable/providers/sacall/**          (calls)
  #              sources/com/samsung/wearable/providers/notification/**    (notifications)
  #              sources/com/samsung/wearable/hostmanager/sharedlib/connection/ConnectionConstants.java (agent ids)
  #              sources/com/samsung/wearable/providers/common/SAMessageData.java (message encoding)
  ```
- yuriyurin/fit3-flasher contains the stock AZA3 firmware (mostly compressed; strings scan is not useful).

## GATT

| | UUID |
|---|---|
| Service | `00001a1a-0000-1000-8000-00805f9b34fb` (`0x1A1A`) — **use the full 128-bit string in Web Bluetooth/Bluefy** |
| Notify (band → phone) | `797ae4e9-2e58-4fe8-b48d-b5c79599fb9b` (+ CCCD 0x2902) |
| Write (phone → band) | `63e30bad-4206-4596-839f-e47cbf7a4b5d` — use write-with-response if the characteristic has `.write`, else without response (paced) |

No app-level crypto. iOS may show a system pairing prompt. ATT MTU must allow ≥ 108 bytes per write
(capability reply is 105 bytes); iOS negotiates this automatically.

## SAP transport framing (`SapCodec`)

One BLE notification/write == one frame.

```
frame  = prefix | body | crc16(body)            crc16 = CRC-16/ARC (poly 0xA001 reflected, init 0), big-endian
prefix = [len, len]                              if transportMtu < 256
       = [lenHi, lenLo, crc16(len) BE]           otherwise
body   = [flags, seq, svc, svc, payload…]        single (flags=0, seq byte 0x40) or FIRST fragment (flags=0x02)
       = [flags, seq, payload…]                  CONTINUE (flags=0x04) / LAST (flags=0x06)
         flags bits 1..2 = kind (0 single, 1 first, 2 continue, 3 last); seq low nibble = fragment no, bits 5..7 = stream
```

Live vector (WatchInfo request, MTU 500): `000dc5c10040010101040200000005000e60ea`.
Reassembly: one message at a time, ≤ 4096 bytes, ≤ 16 fragments.

### Handshake

1. Subscribe to notify characteristic.
2. Band sends a **105-byte capability request**: `data[0]=104, data[1]=0x14`; transport MTU = `data[0x2c]<<8 | data[0x2d]`.
3. Phone replies with the **same 105 bytes with `data[1]=0x15`** (raw, not framed).
4. Session ready. (If iOS restores an already-subscribed link, the band won't resend this — app re-uses the stored MTU.)

## Message encoding (Samsung `SAMessageData`)

First byte = header: `format<<7 | type<<6 | messageId` (format 0 fixed / 1 variable; type 0 request / 1 response).
Variable format: byte 2 = number of params. Params are `id` followed by:
- byte/bool → 1 byte; short → 2 LE; int → 4 LE; long → 8 LE
- string → **1-byte length** + UTF-8 (some fields, e.g. notification body, use 2-byte length)
Responses are typically `0x40 | id`.

## Services (SAP service id == Samsung "agent id")

| id | agent | used for |
|---|---|---|
| 1 | OOBE | setup, time/timezone/locale |
| 3 | **Call** | incoming call ringing, missed calls |
| 4 | Location | |
| 5 | Weather | |
| 6 | Band face | watch faces |
| 7 | Notification | notifications |
| 8 | Calendar | |
| 9 | Media | music control |
| 10 | Health | steps/HR/sleep |
| 11 | Full settings | battery, language, display settings |
| 15 / 19 / 24 | Widgets / Quick panel / Apps | ordering |
| 18 | Quick messages | |
| 30 | OTA transfer | firmware / file transfer control |

## OOBE / setup (service 1) — done on every connect

| step | phone → band | band reply |
|---|---|---|
| 1 WatchInfo | `01 04 02 00 00 00 05 00 0e` | `0x41 …` (contains `R390…` firmware string) |
| 2 Device status | `02 01 00` | `0x42 …` |
| 3 Init settings | `83 01 <localeLE16> 02 00 03 <len> <epochSecondsASCII> 04 <neg?1:0> <absOffsetLE16> 05 <24h?1:0>` | `0x43 …` |
| 4 User agreement | `84 01 01` | `0x44 …` |

Step 3 alone is also used as "sync time". Vector (2023-11-14 22:13:20Z, Moscow, locale 57):
`830139000200030a313730303030303030300400302a0501`.
Language: service 11 `01 04 <localeIdLE16>`; IDs in `BandLanguages` (en=13, en-US=100, hi=24, …).

## Battery (service 11)
Request `02`. Reply `0x42` with params `5=level(0-100)`, `6=charging(0-3)`, e.g. `42 05 3a 06 00` = 58 %.

## Notifications (service 7)

- Capability request `0d` → reply id 13 with icon format (param 5) and sizes (param 6). Send it after the
  handshake; the Android app waits for it before sending notifications.
- **New notification** (`0x80` = variable, id 0 popup; id 5 = silent):
  ```
  80 <nParams=10(+1 if category)>
    00 01                       type: normal
    01 <seq int32 LE>           sequence (>0, unique)
    06 <len> "<appId>"          app id as text (we use 20..25)
    02 <millis int64 LE>        time
    03 <len> <title ≤60B>
    04 <lenLE16> <body ≤100B>
    0e <len> <appName ≤60B>
    0f 01
    10 00
    [0c <len> <category>]       Android category (msg, email, …)
    12 <len> <packageName>
  ```
- Band ack: `40 01 <seq LE32> 0b <1=accepted>`.
- Delete from phone: `01 01 <seq LE32>`; clear all `08`.
- Band → phone: id 2 delete, 4 show on phone, 9 clear all, 10 action/reply (param 10 text), 3 app-icon request
  (`APP_ICON_<id>` URL, size), 62 icon-chunk ack.
- Icons (not implemented yet): include param 9 `APP_ICON_<id>` (+ param 19 = 1 first time); answer the band's
  id-3 request with `43 09 <url> 07 <len32 LE> <raw pixels> 23 <size int32>`; formats 1 (mono bitmap),
  2 (RGB565 LE), 3 (RGBA w/ inverted alpha), 5 (alpha byte + RGB565 BE). Large icons → chunked sender (msg 62).

## Calls (service 3) — from Samsung's `SACallHandlerService`

A normal notification with category `call` only buzzes once. Real call UI = call agent:

| message | bytes |
|---|---|
| Enable call notifications (sent on connect and before ringing) | `08 01` |
| Contact info (id 2, variable, 7 params) | `82 07  00 <1=voice,0=video>  07 01 00 00 00  05 <len> "com.samsung.android.providers.sacall.SACallHandlerService"  06 <millis LE64>  04 <len> <name ≤127B>  03 <len> <number ≤127B>  09 <dndException 0/1>` |
| Call state (id 3) | `03 01` ringing · `03 02` off-hook (answered) · `03 00` idle (ended) |
| Missed call (id 6, alert; id 10 = silent update) | `86 03  04 <len> <name>  03 <len> <number>  06 <millis LE64>` |
| Delete missed call from phone | `07` |
| Silence ringer → band | `00` |

Sequence on Android: RINGING → `08 01`, contact info, `03 01`. OFFHOOK → `03 02`. IDLE → `03 00`; if it was
never answered, 2 s later send missed call (id 6). If name == number the name is sent empty.

Band → phone requests: 1 silence/mute, 4 show call log on phone, 5 reject, 9 request missed-call sync,
13 call back (param 3 number), 14 reject with message (param 8 text), 15 clear missed call.
iOS cannot reject/silence calls from an app — we only stop the band ringing.

## Watch faces (service 6)

| | bytes |
|---|---|
| All faces info | req `00` → `c0 00 <curWireId> 01 <max> 02 <count> 03 <count> <entries…>` |
| Installed list | req `01` → `c1 03 <count> <entries…>` |
| Current face | req `02` → `42 04 <id> 1d <style>` |
| Select face | `03 04 <id> 1d <style>` → `43 04 <id> 1d <style>` |
| Delete face | `05 04 <id> 1d <style>` → `45 04 <id> 1d <style> 1a <ok>` |
| Install (after file transfer) | `04 04 <id> 1d <style>` → `44 16 <status> 04 <id> 1d <style>` |

Entry: `18 <nFields>` then fields: 4=id, 8/29=style, 11=current, 5/6/7/17/19 = length-prefixed blobs
(6 = name, often `wf_name-NNNNN` = full id). Unknown field → reject the whole list (fail closed).

**Installing new faces** needs the `.bin` file on the band: Fit3-App does it over **Bluetooth Classic RFCOMM**
(UUID `db764ac8-4b08-7f25-aafe-59d03c27bae3`) coordinated via service 30. iOS can't open RFCOMM → open research item
(see STATUS P4). Face `.bin` files ship inside the plugin APK: `assets/watchface/SM_R390/<name>/<name>.bin`.

## Health (service 10) — not implemented yet
Band starts with a GM capability request; must be answered before data requests work. See Fit3-App
`Fit3HealthCodec.kt`, `Fit3HealthLargeDataReceiver.kt`, `Fit3HealthAcceptance.kt`, `Fit3PedometerBackSync.kt`.
