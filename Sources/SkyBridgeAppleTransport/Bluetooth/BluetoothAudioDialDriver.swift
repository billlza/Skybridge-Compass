import CoreBluetooth
import Foundation

@MainActor
protocol BluetoothAudioDialEvents: AnyObject {
    func stateChanged(_ state: CBManagerState)
    func discovered(_ identifier: UUID)
    func connected(_ identifier: UUID)
    func disconnected(_ identifier: UUID, error: (any Error)?)
    func failed(_ error: any Error)
    func mayAccept(identifier: UUID, psm: UInt16) -> Bool
    func opened(_ transport: BluetoothControlFrameTransport, identifier: UUID, psm: UInt16)
}

/// One central and one candidate, with no automatic reconnect. Quiescence means the
/// app's local connection has been acknowledged closed, not that the physical radio
/// link used by other applications has disappeared.
@MainActor
protocol BluetoothAudioDialDriver: AnyObject {
    var events: (any BluetoothAudioDialEvents)? { get set }
    var isQuiescent: Bool { get }
    func start()
    func scan(serviceID: UUID)
    func stopScan()
    func connect(identifier: UUID)
    func open(psm: UInt16)
    func stop()
    func detach() throws
}

/// All Core Bluetooth objects stay on the selected main callback queue. After a
/// channel is handed off, this delegate never accesses its streams again; byte I/O
/// belongs to BluetoothControlFrameTransport's existing dedicated worker.
@MainActor
final class NativeBluetoothAudioDialDriver: NSObject, BluetoothAudioDialDriver,
    @MainActor CBCentralManagerDelegate, @MainActor CBPeripheralDelegate {
    weak var events: (any BluetoothAudioDialEvents)?
    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var scanningService: UUID?
    private var expectedService: CBUUID?
    private var expectedPSM: UInt16?
    private var psmService: CBService?
    private var psmCharacteristic: CBCharacteristic?
    private enum PSMPhase { case idle, services, characteristics, value, opening, closed }
    private var psmPhase = PSMPhase.idle
    private var pendingConnection = false, ownsConnection = false, pendingOpen = false
    private var closing = false, cancelIssued = false
    var isQuiescent: Bool {
        !pendingConnection && !ownsConnection && !pendingOpen && manager?.isScanning != true
    }

    func start() {
        precondition(manager == nil && !closing, "A Bluetooth dial driver is single-use")
        manager = CBCentralManager(delegate: self, queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }
    func scan(serviceID: UUID) {
        guard !closing, let manager, manager.state == .poweredOn, peripheral == nil else {
            events?.failed(BluetoothAudioConnectorError.notReady); return
        }
        scanningService = serviceID
        expectedService = CBUUID(nsuuid: serviceID)
        manager.scanForPeripherals(withServices: [CBUUID(nsuuid: serviceID)],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    func stopScan() {
        scanningService = nil
        if manager?.isScanning == true { manager?.stopScan() }
    }
    func connect(identifier: UUID) {
        guard !closing, !pendingConnection, !ownsConnection, let manager,
              manager.state == .poweredOn, let peripheral, peripheral.identifier == identifier else {
            events?.failed(BluetoothAudioConnectorError.notReady); return
        }
        stopScan(); pendingConnection = true; peripheral.delegate = self
        // Auto-reconnect is intentionally not enabled. A new connection needs a
        // fresh caller-owned operation, not a late OS reconnection of this stream.
        manager.connect(peripheral, options: nil)
    }
    func open(psm: UInt16) {
        guard !closing, ownsConnection, !pendingConnection, !pendingOpen, psmPhase == .idle,
              manager?.state == .poweredOn, let peripheral, let expectedService else {
            events?.failed(BluetoothAudioConnectorError.notReady); return
        }
        // The receiver publishes this characteristic with readEncryptionRequired.
        // Reading it lets Core Bluetooth establish link encryption before CoC and
        // checks that the discovered service still exposes the authenticated PSM.
        // Neither GATT discovery nor OS pairing replaces child authentication.
        expectedPSM = psm; psmPhase = .services
        peripheral.discoverServices([expectedService])
    }
    func stop() {
        closing = true; psmPhase = .closed; stopScan(); cancelIfPossible()
    }
    private func cancelIfPossible() {
        guard pendingConnection || ownsConnection, !cancelIssued,
              let manager, manager.state == .poweredOn, let peripheral else { return }
        cancelIssued = true
        manager.cancelPeripheralConnection(peripheral)
    }
    func detach() throws {
        guard closing, isQuiescent else { throw BluetoothAudioConnectorError.cleanupUnconfirmed }
        peripheral?.delegate = nil; manager?.delegate = nil
        peripheral = nil; manager = nil; events = nil
        psmService = nil; psmCharacteristic = nil; expectedService = nil; expectedPSM = nil
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === manager else { return }
        if closing { cancelIfPossible() }
        events?.stateChanged(central.state)
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === manager, !closing, scanningService != nil, self.peripheral == nil else { return }
        // Core Bluetooth applies the requested service filter, including overflow
        // advertisements. Names, RSSI and Bluetooth identifiers grant no trust.
        self.peripheral = peripheral
        stopScan()
        events?.discovered(peripheral.identifier)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === manager, peripheral === self.peripheral else { return }
        pendingConnection = false; ownsConnection = true
        if closing {
            // A connect callback may race cancellation. Cancel that actual local
            // connection too, and still await its terminal acknowledgement.
            cancelIssued = false; cancelIfPossible()
        }
        events?.connected(peripheral.identifier)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        guard central === manager, peripheral === self.peripheral else { return }
        pendingConnection = false; ownsConnection = false; pendingOpen = false
        let failure: any Error = error.map { native -> any Error in BluetoothAudioNativeFailure(operation: .connect, underlying: native) }
            ?? BluetoothAudioConnectorError.connectionFailed
        events?.disconnected(peripheral.identifier, error: failure)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        guard central === manager, peripheral === self.peripheral else { return }
        // With auto-reconnect disabled, Apple's disconnect callback is the
        // terminal barrier for further CBPeripheralDelegate callbacks. An open
        // request cancelled by disconnect need not receive a didOpen callback.
        pendingConnection = false; ownsConnection = false; pendingOpen = false
        events?.disconnected(peripheral.identifier,
            error: error.map { BluetoothAudioNativeFailure(operation: .disconnect, underlying: $0) })
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard peripheral === self.peripheral, !closing else { return }
        guard psmPhase == .services else { events?.failed(BluetoothAudioConnectorError.unexpectedCallback); return }
        if let error { events?.failed(BluetoothAudioNativeFailure(operation: .discoverServices, underlying: error)); return }
        let matches = peripheral.services?.filter { $0.uuid == expectedService } ?? []
        guard matches.count == 1, let service = matches.first else {
            events?.failed(BluetoothAudioConnectorError.missingPSMService); return
        }
        psmService = service; psmPhase = .characteristics
        peripheral.discoverCharacteristics([CBUUID(string: CBUUIDL2CAPPSMCharacteristicString)], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard peripheral === self.peripheral, !closing else { return }
        guard psmPhase == .characteristics, service === psmService else {
            events?.failed(BluetoothAudioConnectorError.unexpectedCallback); return
        }
        if let error { events?.failed(BluetoothAudioNativeFailure(operation: .discoverCharacteristics, underlying: error)); return }
        let matches = service.characteristics?.filter { $0.uuid == CBUUID(string: CBUUIDL2CAPPSMCharacteristicString) } ?? []
        guard matches.count == 1, let characteristic = matches.first, characteristic.properties.contains(.read) else {
            events?.failed(BluetoothAudioConnectorError.missingPSMCharacteristic); return
        }
        psmCharacteristic = characteristic; psmPhase = .value
        peripheral.readValue(for: characteristic)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard peripheral === self.peripheral, !closing else { return }
        guard psmPhase == .value, characteristic === psmCharacteristic, let expectedPSM else {
            events?.failed(BluetoothAudioConnectorError.unexpectedCallback); return
        }
        if let error { events?.failed(BluetoothAudioNativeFailure(operation: .readPSM, underlying: error)); return }
        do {
            let psm = try Self.verifiedPSM(characteristic.value, expected: expectedPSM)
            // Authorization may expire or be revoked while GATT or OS pairing is
            // pending. Recheck before asking the OS to open a native media stream.
            guard events?.mayAccept(identifier: peripheral.identifier, psm: psm) == true else { return }
            psmPhase = .opening; pendingOpen = true
            peripheral.openL2CAPChannel(psm)
        } catch { events?.failed(error) }
    }
    static func verifiedPSM(_ value: Data?, expected: UInt16) throws -> UInt16 {
        guard let value, value.count == 2, (1...255).contains(expected) else {
            throw BluetoothAudioConnectorError.invalidPSMValue
        }
        let bytes = Array(value)
        let actual = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        guard actual == expected else { throw BluetoothAudioConnectorError.psmMismatch }
        return expected
    }
    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: (any Error)?) {
        guard peripheral === self.peripheral else {
            channel?.inputStream?.close(); channel?.outputStream?.close(); return
        }
        let wasPending = pendingOpen; pendingOpen = false
        guard let channel else {
            if !closing {
                let failure: any Error = error.map { native -> any Error in BluetoothAudioNativeFailure(operation: .openL2CAP, underlying: native) }
                    ?? BluetoothAudioConnectorError.openFailed
                events?.failed(failure)
            }
            return
        }
        guard !closing, wasPending, error == nil, let owner = events,
              owner.mayAccept(identifier: peripheral.identifier, psm: channel.psm) else {
            channel.inputStream?.close(); channel.outputStream?.close()
            if !closing {
                let failure: any Error = error.map { native -> any Error in BluetoothAudioNativeFailure(operation: .openL2CAP, underlying: native) }
                    ?? BluetoothAudioConnectorError.unexpectedCallback
                events?.failed(failure)
            }
            return
        }
        let psm = channel.psm
        do {
            let transport = try BluetoothControlFrameTransport(acceptedChannel: channel)
            owner.opened(transport, identifier: peripheral.identifier, psm: psm)
        } catch { owner.failed(error) }
    }
}
