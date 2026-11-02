import Foundation

/// Frames for the Ollee watch's Bluetooth Low Energy protocol.
///
/// Transport is the Nordic UART service; every message is a `00 LEN AA 55 CRC16 02 TARGET payload`
/// frame with a CRC-16/CCITT-FALSE over the inner bytes. The protocol was reverse-engineered by
/// Arthur86000's FreeOllee and is documented in
/// https://github.com/kenblizzardcaron/FreeOllee-Faces/blob/main/docs/reference/ollee-ble-protocol.md
///
/// This file is an independent implementation of those wire facts (no GPL code copied).
enum OlleeProtocol {

    // MARK: - Transport (Nordic UART service)

    static let serviceUUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    static let writeCharacteristicUUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
    static let notifyCharacteristicUUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

    // MARK: - Frame layout

    /// Every frame observed from the official app starts with this command byte.
    static let command: UInt8 = 0x02
    /// `02 23` — set clock plus location. Written by the official app on every sync.
    static let targetSetClock: UInt8 = 0x23
    /// The watch answers a write at `target + 0x20`, so `0x23` is acknowledged at `0x43`.
    static let responseOffset: UInt8 = 0x20
    /// Payload per BLE write for the watch's default 23-byte ATT MTU (`MTU - 3`).
    static let chunkSize = 20

    // MARK: - Set clock

    /// 20-byte `TARGET_SET_CLOCK` payload. All fields are little-endian.
    ///
    /// | bytes | field                                             |
    /// |-------|---------------------------------------------------|
    /// | 0-3   | Unix epoch seconds                                |
    /// | 4-7   | home UTC offset in seconds (two's complement)     |
    /// | 8-11  | latitude × 1000                                   |
    /// | 12-15 | longitude × 1000                                  |
    /// | 16-17 | constant `0x0003`                                 |
    /// | 18-19 | constant `0xFFFF`                                 |
    static func setClockPayload(epoch: UInt32,
                                utcOffsetSeconds: Int32,
                                latitudeMilliDegrees: Int32,
                                longitudeMilliDegrees: Int32) -> [UInt8] {
        var payload: [UInt8] = []
        payload += littleEndian(epoch)
        payload += littleEndian(UInt32(bitPattern: utcOffsetSeconds))
        payload += littleEndian(UInt32(bitPattern: latitudeMilliDegrees))
        payload += littleEndian(UInt32(bitPattern: longitudeMilliDegrees))
        payload += littleEndian(UInt16(0x0003))
        payload += littleEndian(UInt16(0xFFFF))
        assert(payload.count == 20, "set-clock payload must be 20 bytes")
        return payload
    }

    /// A complete set-clock frame, ready to be split with `chunks(of:)`.
    static func setClockFrame(epoch: UInt32,
                              utcOffsetSeconds: Int32,
                              latitudeMilliDegrees: Int32,
                              longitudeMilliDegrees: Int32) -> [UInt8] {
        let payload = setClockPayload(epoch: epoch,
                                      utcOffsetSeconds: utcOffsetSeconds,
                                      latitudeMilliDegrees: latitudeMilliDegrees,
                                      longitudeMilliDegrees: longitudeMilliDegrees)
        return frame(target: targetSetClock, payload: payload)
    }

    /// Wraps `CMD TARGET payload` in the `00 LEN AA 55 CRC16` envelope.
    static func frame(target: UInt8, payload: [UInt8]) -> [UInt8] {
        let inner = [command, target] + payload
        let crc = crc16CCITTFalse(inner)
        var out: [UInt8] = [
            0x00,
            UInt8(inner.count + 4),
            0xAA,
            0x55,
            UInt8(crc >> 8),
            UInt8(crc & 0xFF)
        ]
        out += inner
        return out
    }

    /// CRC-16/CCITT-FALSE: polynomial `0x1021`, initial value `0xFFFF`, no reflection, no xor-out.
    static func crc16CCITTFalse(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if crc & 0x8000 != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc = crc << 1
                }
            }
        }
        return crc
    }

    /// Splits a frame into writes the watch can reassemble via its `LEN` field.
    static func chunks(of frame: [UInt8]) -> [[UInt8]] {
        stride(from: 0, to: frame.count, by: chunkSize).map { start in
            Array(frame[start..<min(start + chunkSize, frame.count)])
        }
    }

    // MARK: - Notifications

    /// A frame received from the watch.
    struct Frame {
        let command: UInt8
        let target: UInt8
        let payload: [UInt8]
        let crcValid: Bool

        var hex: String {
            ([command, target] + payload).hexString
        }
    }

    /// Rebuilds whole frames from the notify characteristic, which delivers 20-byte chunks.
    struct Reassembler {
        private var buffer: [UInt8] = []

        init() {}

        mutating func ingest(_ bytes: [UInt8]) -> [Frame] {
            buffer += bytes
            var frames: [Frame] = []

            while buffer.count >= 6 {
                // Re-sync on the `00 ?? AA 55` preamble if we ever start mid-frame.
                guard buffer[0] == 0x00, buffer[2] == 0xAA, buffer[3] == 0x55 else {
                    buffer.removeFirst()
                    continue
                }

                let length = Int(buffer[1])
                guard length >= 2 else {
                    // Not a plausible length — drop a byte and try to re-sync.
                    buffer.removeFirst()
                    continue
                }

                let total = 6 + length
                guard buffer.count >= total else { break }

                let expectedCRC = (UInt16(buffer[4]) << 8) | UInt16(buffer[5])
                let body = Array(buffer[6..<total])
                buffer.removeFirst(total)

                frames.append(Frame(command: body[0],
                                    target: body[1],
                                    payload: Array(body.dropFirst(2)),
                                    crcValid: OlleeProtocol.crc16CCITTFalse(body) == expectedCRC))
            }

            return frames
        }
    }

    // MARK: - Time helpers

    /// Epoch and UTC offset that make the watch *display* `date`'s wall-clock time.
    ///
    /// The watch renders local time as `epoch + utcOffset`, so pairing the absolute instant of the
    /// chosen wall-clock time with the phone's own offset reproduces exactly what the user picked.
    static func displayTime(for date: Date,
                            timeZone: TimeZone = .current) -> (epoch: UInt32, utcOffset: Int32) {
        let epoch = UInt32(clamping: Int(date.timeIntervalSince1970))
        let offset = Int32(clamping: timeZone.secondsFromGMT(for: date))
        return (epoch, offset)
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }
}

extension Array where Element == UInt8 {
    /// Space-separated lowercase hex, for logs.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
