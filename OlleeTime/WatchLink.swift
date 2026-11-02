import Combine
import CoreBluetooth
import CoreLocation
import Foundation

/// A peripheral seen while scanning.
struct DiscoveredWatch: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
}

/// One line in the on-screen activity log.
struct LogEntry: Identifiable {
    let id = UUID()
    let text: String
}

enum WatchLinkStatus: Equatable {
    case idle
    case bluetoothOff
    case unauthorized
    case scanning
    case connecting(String)
    case connected(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .idle: return "Not connected"
        case .bluetoothOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth permission denied"
        case .scanning: return "Searching for your watch…"
        case .connecting(let name): return "Connecting to \(name)…"
        case .connected(let name): return "Connected to \(name)"
        }
    }
}

enum WatchLinkError: LocalizedError {
    case notConnected
    case busy
    case timedOut
    case missingService
    case missingWriteCharacteristic
    case bluetoothUnavailable

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "The watch is not connected. Pick it from the list first."
        case .busy:
            return "Another update is already being sent."
        case .timedOut:
            return "The watch did not respond in time. Wake it with a button press and try again."
        case .missingService:
            return "This device does not expose the Ollee (Nordic UART) service. Make sure you picked the watch, not another accessory."
        case .missingWriteCharacteristic:
            return "The watch's write characteristic is missing. Disconnect the official Ollee app and reconnect."
        case .bluetoothUnavailable:
            return "Bluetooth is unavailable on this device."
        }
    }
}

struct SetClockOutcome {
    let acknowledged: Bool
    let frameHex: String
}

/// Owns the single BLE link to the watch and writes set-clock frames.
///
/// All CoreBluetooth callbacks arrive on the main queue, which keeps the published state consistent
/// with SwiftUI without extra hop plumbing.
final class WatchLink: NSObject, ObservableObject {

    @Published private(set) var status: WatchLinkStatus = .idle
    @Published private(set) var devices: [DiscoveredWatch] = []
    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var isSending = false

    var isConnected: Bool { status.isConnected }

    private var central: CBCentralManager?
    private var discovered: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var reassembler = OlleeProtocol.Reassembler()

    private var pendingChunks: [[UInt8]] = []
    private var sendContinuation: CheckedContinuation<SetClockOutcome, Error>?
    private var ackTimer: Timer?
    private var watchdog: Timer?
    private var connectedName = ""

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self,
                                   queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
        appendLog("Bluetooth starting…")
    }

    // MARK: - Scanning and connecting

    func rescan() {
        guard let central else { return }
        devices.removeAll()
        discovered.removeAll()
        central.stopScan()
        status = .scanning
        appendLog("Scanning for nearby devices…")
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func connect(to device: DiscoveredWatch) {
        guard let central, let target = discovered[device.id] else { return }
        central.stopScan()
        peripheral = target
        target.delegate = self
        connectedName = device.name
        status = .connecting(device.name)
        appendLog("Connecting to \(device.name)…")
        central.connect(target, options: nil)
    }

    func disconnect() {
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    func clearLog() {
        log.removeAll()
    }

    // MARK: - Setting the clock

    /// Sends the set-clock frame and resolves when the watch acknowledges or the wait expires.
    func sendClock(at date: Date,
                   coordinate: CLLocationCoordinate2D?) async throws -> SetClockOutcome {
        guard let peripheral, peripheral.state == .connected, writeCharacteristic != nil else {
            throw WatchLinkError.notConnected
        }
        guard !isSending else { throw WatchLinkError.busy }

        let (epoch, offset) = OlleeProtocol.displayTime(for: date)
        let latitude = Int32(clamping: Int(((coordinate?.latitude ?? 0) * 1000).rounded()))
        let longitude = Int32(clamping: Int(((coordinate?.longitude ?? 0) * 1000).rounded()))
        let frame = OlleeProtocol.setClockFrame(epoch: epoch,
                                                utcOffsetSeconds: offset,
                                                latitudeMilliDegrees: latitude,
                                                longitudeMilliDegrees: longitude)

        isSending = true
        pendingChunks = OlleeProtocol.chunks(of: frame)
        appendLog("TX \(frame.hexString)")

        return try await withCheckedThrowingContinuation { continuation in
            sendContinuation = continuation
            watchdog = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
                self?.completeSend(.failure(WatchLinkError.timedOut))
            }
            writeNextChunk()
        }
    }

    private var writeType: CBCharacteristicWriteType {
        guard let writeCharacteristic else { return .withResponse }
        return writeCharacteristic.properties.contains(.write) ? .withResponse : .withoutResponse
    }

    private func writeNextChunk() {
        guard let peripheral,
              let writeCharacteristic,
              peripheral.state == .connected,
              sendContinuation != nil else {
            completeSend(.failure(WatchLinkError.notConnected))
            return
        }

        guard !pendingChunks.isEmpty else {
            waitForAcknowledgement()
            return
        }

        let chunk = pendingChunks.removeFirst()
        let data = Data(chunk)

        if writeType == .withResponse {
            peripheral.writeValue(data, for: writeCharacteristic, type: .withResponse)
        } else {
            peripheral.writeValue(data, for: writeCharacteristic, type: .withoutResponse)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.writeNextChunk()
            }
        }
    }

    private func waitForAcknowledgement() {
        appendLog("Waiting for the watch to confirm…")
        ackTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            self?.completeSend(.success(SetClockOutcome(acknowledged: false, frameHex: "")))
        }
    }

    /// Single exit point for a send, so the continuation is never resumed twice.
    private func completeSend(_ result: Result<SetClockOutcome, Error>) {
        ackTimer?.invalidate()
        ackTimer = nil
        watchdog?.invalidate()
        watchdog = nil
        pendingChunks.removeAll()
        isSending = false

        guard let continuation = sendContinuation else { return }
        sendContinuation = nil
        continuation.resume(with: result)
    }

    private func appendLog(_ message: String) {
        log.append(LogEntry(text: "\(Self.timeFormatter.string(from: Date()))  \(message)"))
        if log.count > 80 {
            log.removeFirst(log.count - 80)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension WatchLink: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            appendLog("Bluetooth ready")
            rescan()
        case .poweredOff:
            status = .bluetoothOff
            appendLog("Bluetooth is off")
        case .unauthorized:
            status = .unauthorized
            appendLog("Bluetooth permission denied — enable it in Settings › Ollee Time")
        case .unsupported:
            status = .idle
            appendLog("This device does not support Bluetooth LE")
        default:
            status = .idle
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard !isConnected else { return }

        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "Unnamed device"
        let rssi = RSSI.intValue

        discovered[peripheral.identifier] = peripheral

        if let index = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[index] = DiscoveredWatch(id: peripheral.identifier, name: name, rssi: rssi)
        } else {
            devices.append(DiscoveredWatch(id: peripheral.identifier, name: name, rssi: rssi))
        }

        devices.sort { lhs, rhs in
            if lhs.rssi == 127 { return false }
            if rhs.rssi == 127 { return true }
            return lhs.rssi > rhs.rssi
        }
        if devices.count > 40 {
            devices.removeLast(devices.count - 40)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        appendLog("Connected — looking for the Ollee service…")
        peripheral.discoverServices([CBUUID(string: OlleeProtocol.serviceUUID)])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        appendLog("Connection failed: \(error?.localizedDescription ?? "unknown error")")
        self.peripheral = nil
        rescan()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        appendLog("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        self.peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        reassembler = OlleeProtocol.Reassembler()
        completeSend(.failure(WatchLinkError.notConnected))
        status = .idle
    }
}

// MARK: - CBPeripheralDelegate

extension WatchLink: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            appendLog("Service discovery failed: \(error.localizedDescription)")
            disconnect()
            return
        }

        let uuid = CBUUID(string: OlleeProtocol.serviceUUID)
        guard let service = peripheral.services?.first(where: { $0.uuid == uuid }) else {
            appendLog("Ollee service not found — is this the watch?")
            completeSend(.failure(WatchLinkError.missingService))
            disconnect()
            return
        }

        peripheral.discoverCharacteristics(
            [CBUUID(string: OlleeProtocol.writeCharacteristicUUID),
             CBUUID(string: OlleeProtocol.notifyCharacteristicUUID)],
            for: service
        )
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            appendLog("Characteristic discovery failed: \(error.localizedDescription)")
            disconnect()
            return
        }

        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case CBUUID(string: OlleeProtocol.writeCharacteristicUUID):
                writeCharacteristic = characteristic
            case CBUUID(string: OlleeProtocol.notifyCharacteristicUUID):
                notifyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }

        guard writeCharacteristic != nil else {
            appendLog("Write characteristic missing")
            completeSend(.failure(WatchLinkError.missingWriteCharacteristic))
            disconnect()
            return
        }

        // Mark the link usable as soon as a write path exists: the notify subscription can report
        // back late (or never) on some firmware, and a stuck "Connecting…" would block the UI.
        status = .connected(connectedName)
        if notifyCharacteristic == nil {
            appendLog("Ready (no notify characteristic — acknowledgements disabled)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            appendLog("Could not subscribe to watch replies: \(error.localizedDescription)")
        }
        status = .connected(connectedName)
        appendLog("Ready — the watch will now accept a new time")
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard sendContinuation != nil else { return }
        if let error {
            appendLog("Write failed: \(error.localizedDescription)")
            completeSend(.failure(error))
            return
        }
        writeNextChunk()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, let data = characteristic.value else { return }

        for frame in reassembler.ingest([UInt8](data)) {
            appendLog("RX \(frame.hex)\(frame.crcValid ? "" : " (bad CRC)")")

            let ackTarget = OlleeProtocol.targetSetClock &+ OlleeProtocol.responseOffset
            if frame.target == ackTarget, frame.crcValid, sendContinuation != nil {
                appendLog("Watch confirmed the new time")
                completeSend(.success(SetClockOutcome(acknowledged: true, frameHex: frame.hex)))
            }
        }
    }
}
