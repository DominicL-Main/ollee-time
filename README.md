# Ollee Time

A tiny iOS app that sets your Ollee watch's clock over Bluetooth LE: pick a time, tap one button,
and the watch jumps to it. Most useful for demoing or photographing a face at an exact time, and
for fixing a watch whose clock has drifted or reset.

The app talks to the watch directly — no Android phone, no official Ollee app, no cloud.

## How it works

The watch exposes the **Nordic UART service** (`6e400001-…`) and accepts framed commands on its RX
characteristic. Everything here is a re-implementation of the protocol reverse-engineered by
[Arthur86000/FreeOllee](https://github.com/Arthur86000/FreeOllee) and documented in
[kenblizzardcaron/FreeOllee-Faces `docs/reference/ollee-ble-protocol.md`](https://github.com/kenblizzardcaron/FreeOllee-Faces/blob/main/docs/reference/ollee-ble-protocol.md).

```
00 │ LEN │ AA 55 │ CRC16_hi CRC16_lo │ CMD TARGET │ payload…
```

- `LEN = (CMD TARGET payload).count + 4`
- `CRC` = CRC-16/CCITT-FALSE (poly `0x1021`, init `0xFFFF`, no reflection, no final xor) over `CMD TARGET payload`
- Frames longer than 20 bytes are split across writes; the watch reassembles them using `LEN`.

Setting the clock is `CMD = 0x02`, `TARGET = 0x23`, with a 20-byte little-endian payload:

| bytes | field |
|-------|-------|
| 0-3 | Unix epoch seconds |
| 4-7 | home UTC offset, seconds (two's complement) |
| 8-11 | latitude × 1000 |
| 12-15 | longitude × 1000 |
| 16-17 | constant `0x0003` |
| 18-19 | constant `0xFFFF` |

The watch acknowledges a write at `target + 0x20`, so a set-clock is confirmed on `0x43`.

**Verified:** the encoder reproduces the published golden vector exactly —
`build(now=1783729820, offset=-21600, lat=40140, lon=-105144)` produces
`001aaa55fb5302239c8e516aa0abffffcc9c00004865feff0300ffff`.

Because the watch renders `epoch + offset`, sending the absolute instant of the wall-clock time
you picked together with the phone's own offset is what makes it display that time.

## Project layout

```
project.yml                     XcodeGen spec (generates OlleeTime.xcodeproj)
OlleeTime/
  OlleeTimeApp.swift            app entry point
  ContentView.swift             the one screen: pick a time, pick the watch, send
  WatchLink.swift               CoreBluetooth scan/connect/write + acknowledgement
  OlleeProtocol.swift           framing, CRC, set-clock payload (no CoreBluetooth)
  PhoneLocation.swift           best-effort coordinates for the sun/moon face
.github/workflows/ios-build.yml builds an unsigned .ipa on a macOS runner
```

Building an `.ipa` needs macOS and Xcode, so the Xcode project is generated from `project.yml`
rather than committed.

## Build

### On a Mac

```bash
brew install xcodegen
xcodegen generate
open OlleeTime.xcodeproj
```

Pick your team under *Signing & Capabilities*, then Run (or Product ▸ Archive).

### On Windows / Linux (no Mac needed)

1. `PRODUCT_BUNDLE_IDENTIFIER` is already set to `com.dominiclm.olleetime`. Only change it if you
sign with a different Apple ID and hit a bundle-ID collision.
2. The app is published at `https://github.com/DominicL-Main/ollee-time`; push any change there.
3. Every push to `main` builds and publishes automatically (or start one by hand: **Actions** ▸ **Build IPA** ▸ **Run workflow**).
4. When the run finishes, open **Releases** and download `OlleeTime-unsigned.ipa`. The same file
stays reachable at a permanent URL that updates on every later run:

   ```
   https://github.com/DominicL-Main/ollee-time/releases/latest/download/OlleeTime-unsigned.ipa
   ```

The IPA is **unsigned** on purpose — SideStore signs it on-device with your Apple ID, so this is
exactly what it wants to receive. A free Apple ID needs re-signing every 7 days and allows three
sideloaded apps; a paid developer account lasts a year.

### Installing with SideStore

1. Make sure SideStore is installed, signed in with your Apple ID, and currently refreshed.
2. Get `OlleeTime-unsigned.ipa` onto the device — download it in Safari, or from the release above.
3. Open the file and choose **SideStore**, or use **My Apps ▸ +** and pick the IPA from Files.
4. Accept the Bluetooth prompt on first launch. Location is optional and only feeds the watch's
   sunrise/sunset face.

Bluetooth and location permission prompts appear on first launch — both are required for the
watch link and the sunrise/sunset face respectively.

## Use

1. Wake the watch (press a button) and make sure Bluetooth is enabled on it — the "lap" icon
   should be showing.
2. **Close the official Ollee app**, including on any other phone paired with the watch. The watch
   only accepts one BLE client at a time.
3. Open Ollee Time and tap your watch in the list. If you don't see it, wake the watch and tap
   **Rescan**; the advertised name may be generic, so the strongest-signal device is usually it.
4. Set the hour and minute, then tap **Set watch to …**.

The Activity card logs every frame (`TX`/`RX`) so you can see exactly what was sent and whether the
watch acknowledged it.

## Troubleshooting

- **No devices listed** — Bluetooth is off, permission was denied (Settings ▸ Ollee Time), or the
  watch is asleep. Wake it and tap Rescan.
- **"Ollee service not found"** — you connected to a different accessory, or the watch is holding a
  link with another phone. Forget it on the other phone, then retry.
- **Clock doesn't change** — on the watch, long-press the bottom-right button twice to re-enable
  Bluetooth and sync, then send again. If it still doesn't move, check that the official app is
  not open in the background.
- **Time reverts later** — the official Ollee app writes the phone's time on every connect/sync,
  so it will overwrite whatever this app set.
- **Sunrise/sunset face looks wrong** — send with location permission granted; without it the
  frame carries `0, 0`.

## Notes and limits

- The frame format is confirmed against HCI captures of the official app, but this iOS client has
  **not been tested on physical hardware** — the BLE transport path (connect, chunked write,
  acknowledgement) is new code.
- Latitude/longitude are best-effort: a fresh fix if available, otherwise `0, 0`, which sets the
  clock correctly and only affects the sun/moon face.
- The watch is not pairable/bonded by this app; iOS connects as an ordinary GATT central.
- The protocol facts originate with FreeOllee (no license declared) and FreeOllee-Faces (GPLv3).
  The Swift here is an independent implementation of the documented wire format, not copied code.
