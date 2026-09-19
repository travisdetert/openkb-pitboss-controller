import Foundation
// CoreBluetooth predates Swift concurrency and none of its types are marked
// Sendable, so passing a CBPeripheral into this file's queue hops trips the
// checker. The objects are in fact safe to touch on the central manager's
// queue, which is the only place this file touches them — `@preconcurrency`
// is the sanctioned annotation for that situation rather than silencing the
// individual warnings.
@preconcurrency import CoreBluetooth

/// A grill seen while scanning.
public struct DiscoveredGrill: Identifiable, Sendable, Equatable {
    public let id: UUID          // CoreBluetooth's per-app peripheral identifier
    public let name: String
    public let rssi: Int
}

public enum TransportError: Error, LocalizedError {
    case bluetoothUnavailable(String)
    case notConnected
    case serviceMissing
    case timedOut(String)
    case rpc(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let m): return m
        case .notConnected:                return "Not connected to the grill."
        case .serviceMissing:              return "The grill did not expose its RPC service."
        case .timedOut(let what):          return "Timed out waiting for \(what)."
        case .rpc(let m):                  return "The grill rejected the command: \(m)"
        case .badResponse(let m):          return "Unexpected reply from the grill: \(m)"
        }
    }
}

/// Mongoose-OS RPC over BLE, as the PBL board speaks it.
///
/// Mirrors `pytboss/ble.py`. The one structural difference is that bleak hands
/// you a device object while CoreBluetooth makes you drive a central manager,
/// so discovery, connection and teardown are explicit here.
///
/// Note on identity: macOS and iOS both rotate a peripheral's Bluetooth
/// address, so — exactly as in the desktop app — the stable handle is the
/// advertised *name*, not the address.
public final class BLETransport: NSObject, @unchecked Sendable {

    /// Delivered as the grill pushes frames on the debug-log characteristic.
    public var onDebugFrame: (@Sendable (DebugFrame) -> Void)?
    /// Called when the link drops for any reason other than a requested disconnect.
    public var onDisconnect: (@Sendable (Error?) -> Void)?

    /// Fired when a **standing reconnect** completes on its own — the link came
    /// back without anyone calling `connect`. The controller uses this to resume
    /// polling and record the gap, exactly as if it had reconnected by hand.
    public var onLinkRestored: (@Sendable () -> Void)?
    /// Diagnostics, routed to the host app's logger.
    public var onLog: (@Sendable (String) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?

    private var dataChar: CBCharacteristic?
    private var txControlChar: CBCharacteristic?
    private var rxControlChar: CBCharacteristic?
    private var debugLogChar: CBCharacteristic?

    /// All mutable state is confined to this queue, which is also the queue
    /// CoreBluetooth delivers its callbacks on.
    private let queue = DispatchQueue(label: "com.openkb.pit-boss.ble")

    // Pending async operations, keyed by what they're waiting for.
    private var powerOnWaiters: [CheckedContinuation<Void, Error>] = []
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var rpcWaiters: [Int: CheckedContinuation<Any?, Error>] = [:]

    private var discovered: [UUID: DiscoveredGrill] = [:]
    private var scanWaiter: CheckedContinuation<[DiscoveredGrill], Never>?
    private var nameFilter: String?

    private var lastCommandID = 0
    private var expectedResponseLength = 0
    private var responseBuffer = Data()
    private var intentionalDisconnect = false
    /// While true, an unexpected drop immediately re-arms `central.connect`.
    private var autoReconnect = false
    /// True while a standing reconnect is outstanding, so the ready path knows
    /// to announce the link rather than look for a waiter that doesn't exist.
    private var standingReconnect = false

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    public var isConnected: Bool {
        queue.sync { peripheral?.state == .connected && dataChar != nil }
    }

    // MARK: - Power

    /// Waits for the Bluetooth radio to be usable.
    ///
    /// On iOS the first call is what triggers the system permission prompt, so
    /// a denial surfaces here as a clear error rather than a silent no-op.
    public func waitUntilReady(timeout: TimeInterval = 10) async throws {
        try await withThrowingTimeout(timeout, what: "Bluetooth to become available") {
            try await withCheckedThrowingContinuation { cont in
                self.queue.async {
                    switch self.central.state {
                    case .poweredOn:
                        cont.resume()
                    case .unauthorized:
                        cont.resume(throwing: TransportError.bluetoothUnavailable(
                            "Pit Boss isn't allowed to use Bluetooth. Enable it in Settings › Privacy & Security › Bluetooth."))
                    case .poweredOff:
                        cont.resume(throwing: TransportError.bluetoothUnavailable(
                            "Bluetooth is switched off."))
                    case .unsupported:
                        cont.resume(throwing: TransportError.bluetoothUnavailable(
                            "This device has no Bluetooth LE radio."))
                    default:
                        self.powerOnWaiters.append(cont)  // .resetting / .unknown
                    }
                }
            }
        }
    }

    // MARK: - Scanning

    /// Scans for grills whose advertised name begins with `prefix`.
    ///
    /// Scanning with no service filter is required because the board does not
    /// advertise its RPC service UUID — which also means this only works with
    /// the app in the foreground on iOS.
    public func scan(prefix: String = "PB", seconds: TimeInterval = 8) async throws -> [DiscoveredGrill] {
        try await waitUntilReady()
        return await withCheckedContinuation { cont in
            queue.async {
                self.discovered.removeAll()
                self.nameFilter = prefix
                self.scanWaiter = cont
                self.central.scanForPeripherals(withServices: nil, options: nil)
                self.log("scanning for '\(prefix)*' for \(Int(seconds))s")
                self.queue.asyncAfter(deadline: .now() + seconds) {
                    self.central.stopScan()
                    let found = self.discovered.values.sorted { $0.rssi > $1.rssi }
                    // Log the names: the advertised name is the grill's stable
                    // identifier and it embeds the model, so it is the single
                    // most useful thing when a connection has to be diagnosed.
                    let names = found.map { "\($0.name) (\($0.rssi) dBm)" }.joined(separator: ", ")
                    self.log("scan finished: \(found.count) grill(s)\(names.isEmpty ? "" : " — \(names)")")
                    self.scanWaiter?.resume(returning: found)
                    self.scanWaiter = nil
                }
            }
        }
    }

    // MARK: - Connection

    /// How long to wait for a link before giving up and retrying.
    ///
    /// 90 seconds, not 30: on a weak link an establish genuinely took **84
    /// seconds** on this project's grill (-95 dBm). The old 30s limit reported
    /// a failure while CoreBluetooth was still succeeding underneath, so the
    /// app said "couldn't connect" about a connection that was working.
    public static let connectTimeout: TimeInterval = 90

    /// Connects to the grill whose advertised name begins with `name`, then
    /// waits until the RPC characteristics are discovered and subscribed.
    public func connect(name: String, timeout: TimeInterval = BLETransport.connectTimeout) async throws {
        try await waitUntilReady()

        let target: CBPeripheral
        do {
            target = try await withThrowingTimeout(timeout, what: "the grill to appear") {
            // Prefer a peripheral the system already has connected — that skips
            // the scan and is much faster.
            if let known = self.knownPeripheral(named: name) { return known }
            let found = try await self.scan(prefix: name, seconds: min(timeout, 10))
            guard let first = found.first,
                  let p = self.queue.sync(execute: { self.central.retrievePeripherals(withIdentifiers: [first.id]).first })
            else {
                throw TransportError.timedOut("the grill '\(name)' to appear")
            }
            return p
            }
        } catch {
            // Not advertising right now. Rather than just reporting failure,
            // leave a system-held connect armed so the link comes back on its
            // own once the grill is in range again.
            if armStandingConnect(named: name) {
                throw TransportError.timedOut(
                    "the grill '\(name)' to appear — waiting for it to come back")
            }
            throw error
        }

        let startedAt = Date()
        do {
            try await withThrowingTimeout(timeout, what: "the grill to connect") {
                try await withCheckedThrowingContinuation { cont in
                    self.queue.async {
                        self.intentionalDisconnect = false
                        self.peripheral = target
                        target.delegate = self
                        self.connectWaiter = cont
                        self.central.connect(target, options: nil)
                        self.log("connecting to \(target.name ?? name)")
                    }
                }
            }
        } catch {
            // Leave nothing half-connected: CoreBluetooth keeps trying forever
            // unless told otherwise, so a timeout that just walked away left a
            // connection completing in the background while the app retried
            // over the top of it.
            cancelPendingConnect()
            throw error
        }
        log("link established in \(Int(Date().timeIntervalSince(startedAt)))s")

        // Connected is not the same as usable: services and the notify
        // subscriptions still have to land before a command can be sent.
        try await withThrowingTimeout(timeout, what: "the grill's RPC service") {
            try await withCheckedThrowingContinuation { cont in
                self.queue.async {
                    if self.dataChar != nil, self.txControlChar != nil { cont.resume(); return }
                    self.readyWaiter = cont
                }
            }
        }
        log("connected and subscribed")
        // `async`, not `sync`: this runs at the tail of an async connect whose
        // continuations are resumed from `queue`, and a sync hop back onto that
        // queue is a deadlock waiting for the wrong scheduling to happen. There
        // is no result to wait for here.
        queue.async { [self] in
            autoReconnect = true
            standingReconnect = false
            if let id = peripheral?.identifier {
                // Remembered so a later reconnect — and the next launch — can
                // use retrievePeripherals() and skip the 10s scan entirely.
                Self.rememberPeripheral(id, forName: name)
            }
        }
    }

    // MARK: - Standing reconnect
    //
    // CoreBluetooth's `connect` has no timeout, and that is a feature, not the
    // problem the rest of this file treats it as: it is a *standing request*
    // the system holds until the peripheral comes back, and it completes even
    // while the app is suspended (the `bluetooth-central` background mode).
    //
    // That is the only reconnect that works for the real case — a phone in a
    // pocket during a six-hour cook. An app-level retry ladder is `Task.sleep`
    // on the main actor, which iOS freezes on suspend, so it recovers only
    // while someone is looking at the screen.

    /// Re-arms the system-held connect after an unexpected drop.
    ///
    /// Deliberately never timed out and never cancelled: cancelling is what
    /// previously threw away the reconnect and left recovery to a foreground
    /// ladder that could not run.
    private func rearmConnect() {
        guard autoReconnect, let p = peripheral else { return }
        standingReconnect = true
        central.connect(p, options: nil)
        log("standing reconnect armed — the system will reconnect when the grill is back in range")
    }

    /// True while the system is holding a reconnect for us. The app-level
    /// ladder checks this and stands down: two connects racing on one
    /// peripheral is how the backstop ends up cancelling the primary.
    public var hasStandingReconnect: Bool { queue.sync { standingReconnect } }

    /// Stops the system-held reconnect (an intentional disconnect, or giving up).
    public func stopAutoReconnect() {
        queue.sync {
            autoReconnect = false
            if standingReconnect, let p = peripheral {
                central.cancelPeripheralConnection(p)
                log("standing reconnect cancelled")
            }
            standingReconnect = false
        }
    }

    // MARK: - Remembered peripheral
    //
    // The identifier is stored per advertised name so a reconnect can go
    // straight to `retrievePeripherals(withIdentifiers:)`. Without it every
    // attempt paid a 10-second scan, because `retrieveConnectedPeripherals`
    // only ever returns peripherals that are *already* connected — which, after
    // a disconnect, is precisely never.
    private static let peripheralDefaultsKey = "pitboss.knownPeripherals"

    public static func rememberPeripheral(_ id: UUID, forName name: String) {
        var map = UserDefaults.standard.dictionary(forKey: peripheralDefaultsKey) as? [String: String] ?? [:]
        guard map[name] != id.uuidString else { return }
        map[name] = id.uuidString
        UserDefaults.standard.set(map, forKey: peripheralDefaultsKey)
    }

    public static func rememberedPeripheral(forName name: String) -> UUID? {
        let map = UserDefaults.standard.dictionary(forKey: peripheralDefaultsKey) as? [String: String] ?? [:]
        return map[name].flatMap(UUID.init(uuidString:))
    }

    /// A peripheral the system already has connected, so no scan is needed.
    ///
    /// Deliberately *not* extended to the remembered identifier. Connecting to a
    /// retrieved peripheral that has not just been seen issues a **pending**
    /// connect, which the system completes whenever the device next advertises
    /// — excellent for reconnecting, wrong for a first connect, where it sits
    /// silently instead of failing. Measured on a marginal link: skipping the
    /// scan turned a ~15s connect into no connect at all and no message, because
    /// the app suspended and its own timeout could not fire.
    ///
    /// The remembered identifier is used instead by `armStandingConnect`, where
    /// a pending connect is exactly the behaviour wanted.
    private func knownPeripheral(named name: String) -> CBPeripheral? {
        queue.sync {
            central.retrieveConnectedPeripherals(withServices: [CBUUID(string: MongooseUUID.rpcService)])
                .first { ($0.name ?? "").hasPrefix(name) }
        }
    }

    /// Falls back to a system-held connect when the grill is not advertising now.
    ///
    /// Returns true if one was armed. This is what turns "couldn't find your
    /// grill" into "it will connect when it's back", including after a relaunch
    /// and with the app suspended.
    @discardableResult
    private func armStandingConnect(named name: String) -> Bool {
        queue.sync {
            guard let id = Self.rememberedPeripheral(forName: name),
                  let known = central.retrievePeripherals(withIdentifiers: [id]).first
            else { return false }
            peripheral = known
            known.delegate = self
            autoReconnect = true
            standingReconnect = true
            intentionalDisconnect = false
            central.connect(known, options: nil)
            log("grill not advertising — armed a standing connect on the remembered radio")
            return true
        }
    }

    public func disconnect() {
        queue.async {
            self.intentionalDisconnect = true
            // Disarm first: otherwise the cancel below looks like an unexpected
            // drop to the standing reconnect and the app immediately reconnects
            // to a grill the user just asked it to let go of.
            self.autoReconnect = false
            self.standingReconnect = false
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
            self.teardown(error: nil, notify: false)
        }
    }

    // MARK: - RPC

    /// Sends an RPC call and waits for its reply.
    @discardableResult
    public func send(method: String, params: [String: Any] = [:], timeout: TimeInterval = 15) async throws -> Any? {
        let id: Int = queue.sync {
            lastCommandID = (lastCommandID + 1) & 2047   // the firmware's id space
            return lastCommandID
        }
        let body: [String: Any] = ["id": id, "method": method, "params": params]
        let payload = try JSONSerialization.data(withJSONObject: body)

        return try await withThrowingTimeout(timeout, what: "a reply to \(method)") {
            try await withCheckedThrowingContinuation { cont in
                self.queue.async {
                    guard let p = self.peripheral, p.state == .connected,
                          let data = self.dataChar, let tx = self.txControlChar else {
                        cont.resume(throwing: TransportError.notConnected); return
                    }
                    self.rpcWaiters[id] = cont

                    // Length first on tx_ctl, then the body in 20-byte writes.
                    let bytes = [UInt8](payload)
                    p.writeValue(Data(RPCFraming.encodeLength(bytes.count)),
                                 for: tx, type: .withResponse)
                    for chunk in RPCFraming.chunk(bytes) {
                        p.writeValue(Data(chunk), for: data, type: self.writeType(for: data))
                    }
                }
            }
        }
    }

    private func writeType(for char: CBCharacteristic) -> CBCharacteristicWriteType {
        char.properties.contains(.write) ? .withResponse : .withoutResponse
    }

    // MARK: - Internals

    private func log(_ message: String) { onLog?("[ble] \(message)") }

    /// Abandons an in-flight connect so a retry starts from a known state.
    private func cancelPendingConnect() {
        queue.sync {
            // Never cancel a system-held reconnect here. This is the cleanup
            // for a manual connect that timed out; cancelling the standing one
            // would throw away the mechanism that actually recovers the link.
            if standingReconnect {
                connectWaiter?.resume(throwing: TransportError.timedOut("the grill to connect"))
                connectWaiter = nil
                readyWaiter?.resume(throwing: TransportError.timedOut("the grill's RPC service"))
                readyWaiter = nil
                log("manual connect gave up; the standing reconnect is still armed")
                return
            }
            if let p = peripheral, p.state != .connected {
                central.cancelPeripheralConnection(p)
                log("abandoned an in-flight connect after timing out")
            }
            connectWaiter?.resume(throwing: TransportError.timedOut("the grill to connect"))
            connectWaiter = nil
            readyWaiter?.resume(throwing: TransportError.timedOut("the grill's RPC service"))
            readyWaiter = nil
        }
    }

    /// Clears connection state and fails every in-flight continuation, so a
    /// dropped link surfaces as an error instead of an await that never returns.
    private func teardown(error: Error?, notify: Bool) {
        dataChar = nil; txControlChar = nil; rxControlChar = nil; debugLogChar = nil
        expectedResponseLength = 0
        responseBuffer.removeAll()

        let failure = error ?? TransportError.notConnected
        connectWaiter?.resume(throwing: failure); connectWaiter = nil
        readyWaiter?.resume(throwing: failure); readyWaiter = nil
        for (_, waiter) in rpcWaiters { waiter.resume(throwing: failure) }
        rpcWaiters.removeAll()

        if notify { onDisconnect?(error) }
    }

    /// Races `body` against a timeout. CoreBluetooth has no timeouts of its own
    /// — `connect` in particular waits forever — so every await here is bounded.
    private func withThrowingTimeout<T: Sendable>(
        _ seconds: TimeInterval, what: String, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TransportError.timedOut(what)
            }
            guard let first = try await group.next() else {
                throw TransportError.timedOut(what)
            }
            group.cancelAll()
            return first
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLETransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("radio state: \(central.state.rawValue)")
        guard central.state == .poweredOn else { return }
        let waiters = powerOnWaiters
        powerOnWaiters.removeAll()
        for w in waiters { w.resume() }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // The advertised local name is the one that matters — CBPeripheral.name
        // can lag behind or be absent during a scan.
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? ""
        guard let prefix = nameFilter, name.hasPrefix(prefix) else { return }
        discovered[peripheral.identifier] = DiscoveredGrill(
            id: peripheral.identifier, name: name, rssi: RSSI.intValue)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("link up; discovering services")
        connectWaiter?.resume(); connectWaiter = nil
        peripheral.discoverServices([
            CBUUID(string: MongooseUUID.rpcService),
            CBUUID(string: MongooseUUID.debugService),
        ])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        log("connect failed: \(error?.localizedDescription ?? "unknown")")
        teardown(error: error ?? TransportError.notConnected, notify: true)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        log("disconnected: \(error?.localizedDescription ?? "requested")")
        let wasIntentional = intentionalDisconnect
        teardown(error: error, notify: !wasIntentional)
        // Re-arm straight away on an unexpected drop. This is what actually
        // recovers the link: the system holds the request and completes it when
        // the grill is back, with no app involvement and no foreground needed.
        if !wasIntentional { rearmConnect() }
    }
}

// MARK: - CBPeripheralDelegate

extension BLETransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            teardown(error: error, notify: true); return
        }
        guard let services = peripheral.services, !services.isEmpty else {
            teardown(error: TransportError.serviceMissing, notify: true); return
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        if let error {
            teardown(error: error, notify: true); return
        }
        for char in service.characteristics ?? [] {
            switch char.uuid.uuidString.uppercased() {
            case MongooseUUID.rpcData:      dataChar = char
            case MongooseUUID.rpcTxControl: txControlChar = char
            case MongooseUUID.rpcRxControl: rxControlChar = char; peripheral.setNotifyValue(true, for: char)
            case MongooseUUID.debugLog:     debugLogChar = char; peripheral.setNotifyValue(true, for: char)
            default: break
            }
        }
        // Ready once both halves of the RPC channel are in hand.
        if dataChar != nil, txControlChar != nil, rxControlChar != nil {
            if readyWaiter != nil {
                readyWaiter?.resume(); readyWaiter = nil
            } else if standingReconnect {
                // Nobody is awaiting this one — the system reconnected us.
                standingReconnect = false
                log("link restored by the system")
                onLinkRestored?()
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error { log("notify error: \(error.localizedDescription)"); return }
        guard let value = characteristic.value else { return }

        switch characteristic.uuid.uuidString.uppercased() {
        case MongooseUUID.debugLog:
            guard let line = String(data: value, encoding: .utf8) else { return }
            if let frame = DebugFrame.parse(line) { onDebugFrame?(frame) }

        case MongooseUUID.rpcRxControl:
            // A reply is waiting: its length arrives here, the body has to be
            // pulled off the data characteristic by reading it repeatedly.
            expectedResponseLength = RPCFraming.decodeLength([UInt8](value))
            responseBuffer.removeAll()
            if expectedResponseLength > 0, let data = dataChar {
                peripheral.readValue(for: data)
            }

        case MongooseUUID.rpcData:
            guard expectedResponseLength > 0 else { return }
            responseBuffer.append(value)
            if responseBuffer.count < expectedResponseLength {
                peripheral.readValue(for: characteristic)   // keep pulling
            } else {
                let payload = responseBuffer
                responseBuffer.removeAll()
                expectedResponseLength = 0
                deliverRPCResponse(payload)
            }

        default:
            break
        }
    }

    /// Matches a reply to its waiting call by `id`, as the firmware's RPC does.
    private func deliverRPCResponse(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? Int else {
            log("dropping unparseable RPC reply")
            return
        }
        guard let waiter = rpcWaiters.removeValue(forKey: id) else { return }

        if let err = object["error"] as? [String: Any] {
            let message = err["message"] as? String ?? "unknown error"
            waiter.resume(throwing: TransportError.rpc(message))
        } else {
            waiter.resume(returning: object["result"])
        }
    }
}
