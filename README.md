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
  SpokenTime.swift              turns "quarter to nine pm" into an hour and minute
  VoiceClock.swift              continuous speech capture that reports each heard time
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

### Set the time by voice

Tap **Set the time by voice** and the app listens continuously; tap it again to stop. Every
complete time it hears goes straight to the watch, so "ten thirty", "quarter to nine pm", "seven
o'clock" and "half past six" all work without touching the wheel.

A phrase is only acted on once it is finished — a lone "ten" could still become "ten thirty" — and
a time spoken without am/pm resolves to whichever reading is nearer the current time, so "seven" at
6:50 pm means 19:00. Recognition runs on the device where the phone supports it.

The first use asks for Microphone and Speech Recognition permission; say "Allow".

Listening survives leaving the app: the `audio` background mode keeps the microphone live while
you switch apps, and the `bluetooth-central` mode keeps the watch link up, so a time heard in the
background still reaches the watch. It does **not** survive the Camera app recording video — iOS
gives the microphone to one app at a time, so recording interrupts listening. When the recording
stops, the app picks listening back up by itself; the button stays on and needs no second tap.

## Finding the watch

iOS gives apps no list of paired devices, so the app scans and every nearby accessory shows up,
most of them unnamed. Two things make the watch findable:

- **Find my watch for me** connects to nearby devices one at a time and stops at the first one that
  exposes the Ollee (Nordic UART) service. That service check is the same signature the Android ports
  rely on when they pick the watch out of `bondedDevices`; nothing about the advertised name is
  trustworthy. Devices that fail the check are marked with a struck-through icon so you can ignore
  them, and a green seal means the Ollee service was found.
- **The app remembers your watch.** The first successful connection stores the watch's identifier
  (which iOS keeps for that peripheral) and its name. On later launches the app asks iOS for that
  peripheral directly and connects without scanning first, so it reconnects in roughly a second
  instead of waiting for the list to fill up. The name is cached because iOS usually forgets it,
  which is why the watch can reappear under a real name rather than "Unnamed device". The remembered
  watch sorts to the top with a bookmark icon; **Forget** clears it.

Close the official Ollee app first: the watch accepts a single connection at a time.

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
