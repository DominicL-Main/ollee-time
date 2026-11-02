import Combine
import CoreBluetooth
import CoreLocation
import Foundation

/// A peripheral seen while scanning.
struct DiscoveredWatch: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    /// Set when the advertisement itself carries the Nordic UART service UUID.
    var advertisesOlleeService: Bool = false
    /// `nil` until proven: true once the watch's service was seen, false once a probe ruled it out.
    var isWatch: Bool? = nil
    /// True for the peripheral remembered from an earlier session.
    var isSaved: Bool = false

    var isNamed: Bool { name != "Unnamed device" }
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
    @Published private(set) var isIdentifying = false
    @Published private(set) var identifyProgress: String?
    /// The name of the watch remembered from last time, `nil` until one has been connected.
    @Published private(set) var savedWatchName: String?

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

    private var probeQueue: [UUID] = []
    private var probeInFlight: UUID?
    private var probeTotal = 0
    private var probeDone = 0
    private var probeTimer: Timer?
    private var autoConnectAttempted = false
    private var isAutoReconnecting = false
    private var reconnectTimer: Timer?

    /// What iOS lets us keep between launches: the peripheral UUID is the stable handle, the name is
    /// only cached because iOS often forgets it.
    private struct SavedWatch: Codable {
        let id: String
        let name: String
        let savedAt: Date
    }

    private var savedWatch: SavedWatch? {
        didSet { savedWatchName = savedWatch?.name }
    }

    private static let savedWatchKey = "ollee.savedWatch"
    private static let legacyWatchKey = "ollee.lastWatchIdentifier"

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    override init() {
        super.init()
        loadSavedWatch()
        central = CBCentralManager(delegate: self,
                                   queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
        appendLog("Bluetooth starting…")
    }

    // MARK: - Scanning and connecting

    func rescan() {
        devices.removeAll()
        discovered.removeAll()
        startScan()
    }

    private func startScan() {
        guard let central else { return }
        central.stopScan()
        status = .scanning
        appendLog("Scanning for nearby devices…")
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func connect(to device: DiscoveredWatch) {
        guard !isIdentifying, let central, let target = discovered[device.id] else { return }
        autoConnectAttempted = true
        central.stopScan()
        peripheral = target
        target.delegate = self
        connectedName = device.name
        status = .connecting(device.name)
        appendLog("Connecting to \(device.name)…")
        central.connect(target, options: nil)
    }

    /// Connects to nearby devices one at a time until one exposes the Ollee (Nordic UART) service.
    ///
    /// Names cannot help here: iOS shows no paired-device list and the watch usually advertises no
    /// name, so the GATT table is the only reliable signature.
    func findWatch() {
        guard !isConnected, !isIdentifying else { return }
        let candidates = devices.filter { $0.isWatch != false }
        guard !candidates.isEmpty else {
            appendLog("Nothing to check yet — still scanning.")
            return
        }
        isIdentifying = true
        probeQueue = candidates.map(\.id)
        probeTotal = probeQueue.count
        probeDone = 0
        appendLog("Checking \(probeTotal) nearby devices for the Ollee service…")
        probeNext()
    }

    private func probeNext() {
        probeTimer?.invalidate()
        probeTimer = nil
        guard isIdentifying else { return }
        guard let central else {
            endIdentifying(with: "Bluetooth is unavailable.")
            return
        }
        guard let next = probeQueue.first(where: { discovered[$0] != nil }) else {
            endIdentifying(with: "No Ollee watch nearby. Wake it with a button press and try again.")
            return
        }
        probeQueue.removeAll { $0 == next }
        guard let target = discovered[next] else { return }

        probeDone += 1
        probeInFlight = next
        identifyProgress = "Checking device \(probeDone) of \(probeTotal)…"

        let label = devices.first { $0.id == next }?.name ?? "device"
        connectedName = label
        peripheral = target
        target.delegate = self
        status = .connecting(label)
        central.stopScan()
        central.connect(target, options: nil)

        probeTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            guard let self, self.isIdentifying, self.probeInFlight == next else { return }
            self.appendLog("\(label) did not answer — skipping")
            self.markWatch(next, isWatch: false)
            self.probeInFlight = nil
            self.peripheral = nil
            self.central?.cancelPeripheralConnection(target)
            self.probeNext()
        }
    }

    private func markWatch(_ id: UUID, isWatch: Bool) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].isWatch = isWatch
    }

    private func endIdentifying(with message: String?) {
        isIdentifying = false
        probeInFlight = nil
        identifyProgress = nil
        probeQueue.removeAll()
        probeTimer?.invalidate()
        probeTimer = nil
        peripheral = nil
        if let message { appendLog(message) }
        if let central, central.state == .poweredOn { startScan() }
    }

    private func finishIdentifySuccess() {
        isIdentifying = false
        probeInFlight = nil
        identifyProgress = nil
        probeQueue.removeAll()
        probeTimer?.invalidate()
        probeTimer = nil
        autoConnectAttempted = true
        appendLog("This one is the watch — \(connectedName)")
    }

    func disconnect() {
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    func clearLog() {
        log.removeAll()
    }

    // MARK: - Remembered watch

    private func loadSavedWatch() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.savedWatchKey),
           let saved = try? JSONDecoder().decode(SavedWatch.self, from: data) {
            savedWatch = saved
            return
        }
        // Carry over the identifier stored by earlier builds, which knew no name.
        if let legacy = defaults.string(forKey: Self.legacyWatchKey) {
            savedWatch = SavedWatch(id: legacy, name: "your watch", savedAt: Date())
        }
    }

    private func rememberWatch(id: UUID, name: String) {
        // Never remember the placeholder: a named watch keeps its name, an unnamed one keeps the
        // name it was given the first time.
        let remembered = name == "Unnamed device" ? (savedWatch?.name ?? "your watch") : name
        savedWatch = SavedWatch(id: id.uuidString, name: remembered, savedAt: Date())
        if let data = try? JSONEncoder().encode(savedWatch) {
            UserDefaults.standard.set(data, forKey: Self.savedWatchKey)
        }
    }

    func forgetSavedWatch() {
        let previous = savedWatchName
        savedWatch = nil
        UserDefaults.standard.removeObject(forKey: Self.savedWatchKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyWatchKey)
        appendLog("Forgot \(previous ?? "the saved watch") — pick it from the list next time")
    }

    /// Connects straight to the watch iOS already knows, without waiting for it to show up in a scan.
    ///
    /// Scanning takes seconds because every nearby accessory has to be listed first; the stored
    /// identifier lets CoreBluetooth reconnect in one call. If the watch is out of range the attempt
    /// is abandoned after a few seconds and the normal scan takes over.
    private func reconnectToSavedWatch() {
        guard !isConnected, !isIdentifying, !autoConnectAttempted,
              let central, central.state == .poweredOn else {
            startScan()
            return
        }
        guard let saved = savedWatch, let uuid = UUID(uuidString: saved.id) else {
            startScan()
            return
        }

        let known = central.retrievePeripherals(withIdentifiers: [uuid])
        guard let target = known.first else {
            appendLog("\(saved.name) is not known to iOS yet — scanning instead")
            startScan()
            return
        }

        autoConnectAttempted = true
        isAutoReconnecting = true
        peripheral = target
        target.delegate = self
        connectedName = saved.name
        status = .connecting(saved.name)
        appendLog("Reconnecting to \(saved.name)…")
        central.connect(target, options: nil)

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.savedReconnectTimedOut() }
        }
    }

    private func savedReconnectTimedOut() {
        reconnectTimer = nil
        guard isAutoReconnecting else { return }
        isAutoReconnecting = false
        if let pending = peripheral {
            // Drop the reference first so the resulting disconnect callback is ignored.
            peripheral = nil
            central?.cancelPeripheralConnection(pending)
        }
        appendLog("\(savedWatchName ?? "The saved watch") did not answer — showing everything nearby")
        startScan()
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
            devices.removeAll()
            discovered.removeAll()
            reconnectToSavedWatch()
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

        let advertisedName = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        let isSaved = savedWatch?.id == peripheral.identifier.uuidString
        // iOS keeps the peripheral's UUID across launches but usually drops its name, so a remembered
        // watch is labelled from the stored name instead of showing up as "Unnamed device" again.
        let name = advertisedName
            ?? (isSaved ? (savedWatch?.name ?? "Unnamed device") : "Unnamed device")
        let rssi = RSSI.intValue
        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let advertises = advertised.contains(CBUUID(string: OlleeProtocol.serviceUUID))

        discovered[peripheral.identifier] = peripheral

        // Once a watch has been used, reconnect to it silently instead of showing the list again.
        if !autoConnectAttempted,
           !isConnected,
           !isIdentifying,
           isSaved {
            appendLog("Your saved watch reappeared — reconnecting")
            connect(to: DiscoveredWatch(id: peripheral.identifier, name: name, rssi: rssi,
                                        advertisesOlleeService: advertises, isSaved: true))
            return
        }

        if let index = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            var updated = DiscoveredWatch(id: peripheral.identifier, name: name, rssi: rssi,
                                          advertisesOlleeService: advertises, isSaved: isSaved)
            updated.isWatch = devices[index].isWatch ?? (advertises ? true : nil)
            devices[index] = updated
        } else {
            var fresh = DiscoveredWatch(id: peripheral.identifier, name: name, rssi: rssi,
                                        advertisesOlleeService: advertises, isSaved: isSaved)
            fresh.isWatch = advertises ? true : nil
            devices.append(fresh)
        }

        // The remembered watch first, then confirmed watches, named devices, strongest signal — so
        // the watch climbs to the top even before it has been identified.
        devices.sort { lhs, rhs in
            if lhs.isSaved != rhs.isSaved { return lhs.isSaved }
            if (lhs.isWatch == true) != (rhs.isWatch == true) { return lhs.isWatch == true }
            if lhs.isNamed != rhs.isNamed { return lhs.isNamed }
            if (lhs.rssi == 127) != (rhs.rssi == 127) { return rhs.rssi == 127 }
            return lhs.rssi > rhs.rssi
        }
        if devices.count > 40 {
            devices.removeLast(devices.count - 40)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isAutoReconnecting = false
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        appendLog("Connected — looking for the Ollee service…")
        peripheral.discoverServices([CBUUID(string: OlleeProtocol.serviceUUID)])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        if isAutoReconnecting {
            isAutoReconnecting = false
            reconnectTimer?.invalidate()
            reconnectTimer = nil
            // `peripheral` here is the delegate parameter; the stored link is `self.peripheral`.
            self.peripheral = nil
            appendLog("\(savedWatchName ?? "The saved watch") did not answer — showing everything nearby")
            startScan()
            return
        }
        if isIdentifying, probeInFlight == peripheral.identifier {
            appendLog("Could not reach \(connectedName) — skipping")
            markWatch(peripheral.identifier, isWatch: false)
            probeInFlight = nil
            self.peripheral = nil
            probeNext()
            return
        }
        appendLog("Connection failed: \(error?.localizedDescription ?? "unknown error")")
        self.peripheral = nil
        rescan()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        // A late callback from a peripheral we already moved past must not tear down the current link.
        guard self.peripheral?.identifier == peripheral.identifier else { return }

        appendLog("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        self.peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        reassembler = OlleeProtocol.Reassembler()
        completeSend(.failure(WatchLinkError.notConnected))

        if isIdentifying, probeInFlight == peripheral.identifier {
            probeInFlight = nil
            probeNext()
            return
        }
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
            markWatch(peripheral.identifier, isWatch: false)
            if isIdentifying, probeInFlight == peripheral.identifier {
                appendLog("Not the watch — moving on")
                probeInFlight = nil
                probeTimer?.invalidate()
                probeTimer = nil
                central?.cancelPeripheralConnection(peripheral)
                probeNext()
                return
            }
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
        rememberWatch(id: peripheral.identifier, name: connectedName)
        markWatch(peripheral.identifier, isWatch: true)
        if isIdentifying {
            finishIdentifySuccess()
        }
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
