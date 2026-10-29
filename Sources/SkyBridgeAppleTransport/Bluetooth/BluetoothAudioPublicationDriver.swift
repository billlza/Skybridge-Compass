import CoreBluetooth
import Foundation

/// The driver owns one peripheral manager. Audio byte I/O leaves this queue immediately when
/// an admitted channel is handed to BluetoothControlFrameTransport's dedicated worker.
@MainActor
protocol BluetoothAudioPublicationEvents: AnyObject {
    func stateChanged(_ state: CBManagerState)
    func published(psm: UInt16, error: (any Error)?)
    func serviceAdded(error: (any Error)?)
    func advertisingStarted(error: (any Error)?)
    func unpublished(psm: UInt16, error: (any Error)?)
    func mayAccept(psm: UInt16) -> Bool
    func opened(_ transport: BluetoothControlFrameTransport, psm: UInt16)
    func candidateFailed(_ error: any Error)
}

@MainActor
protocol BluetoothAudioPublicationDriver: AnyObject {
    var events: (any BluetoothAudioPublicationEvents)? { get set }
    var isAdvertising: Bool { get }
    func start()
    func publish()
    func addService(id: UUID, psm: UInt16)
    func advertise(id: UUID)
    func stopAdvertisingAndRemoveServices()
    func unpublish(psm: UInt16)
}

/// The delegate's isolated conformance matches the explicitly selected main callback queue.
/// No unchecked Sendable conformance or cross-executor Core Bluetooth object transfer is used.
@MainActor
final class NativeBluetoothAudioPublicationDriver: NSObject, BluetoothAudioPublicationDriver,
    @MainActor CBPeripheralManagerDelegate {
    weak var events: (any BluetoothAudioPublicationEvents)?
    private var manager: CBPeripheralManager?
    private var service: CBMutableService?
    private var readablePSM: UInt16?
    var isAdvertising: Bool { manager?.isAdvertising == true }

    func start() {
        precondition(manager == nil, "A Bluetooth publication driver is single-use")
        manager = CBPeripheralManager(delegate: self, queue: .main,
            options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
    }
    func publish() {
        guard let manager else { events?.published(psm: 0, error: BluetoothAudioListenerError.notReady); return }
        manager.publishL2CAPChannel(withEncryption: true)
    }
    func addService(id: UUID, psm: UInt16) {
        guard let manager else { events?.serviceAdded(error: BluetoothAudioListenerError.notReady); return }
        readablePSM = psm
        let value = CBMutableService(type: CBUUID(nsuuid: id), primary: true)
        value.characteristics = [CBMutableCharacteristic(type: CBUUID(string: CBUUIDL2CAPPSMCharacteristicString),
            properties: .read, value: nil, permissions: .readEncryptionRequired)]
        service = value
        manager.add(value)
    }
    func advertise(id: UUID) {
        guard let manager else { events?.advertisingStarted(error: BluetoothAudioListenerError.notReady); return }
        manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [CBUUID(nsuuid: id)]])
    }
    func stopAdvertisingAndRemoveServices() {
        readablePSM = nil
        manager?.stopAdvertising(); manager?.removeAllServices()
    }
    func unpublish(psm: UInt16) {
        guard let manager else { events?.unpublished(psm: psm, error: BluetoothAudioListenerError.notReady); return }
        manager.unpublishL2CAPChannel(psm)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        events?.stateChanged(peripheral.state)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: (any Error)?) {
        guard peripheral === manager else { return }
        events?.published(psm: PSM, error: error)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
        guard peripheral === manager else { return }
        guard service.uuid == self.service?.uuid else {
            events?.serviceAdded(error: BluetoothAudioListenerError.unexpectedCallback); return
        }
        events?.serviceAdded(error: error)
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: (any Error)?) {
        guard peripheral === manager else { return }
        events?.advertisingStarted(error: error)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didUnpublishL2CAPChannel PSM: CBL2CAPPSM, error: (any Error)?) {
        guard peripheral === manager else { return }
        events?.unpublished(psm: PSM, error: error)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard peripheral === manager, let psm = readablePSM, let service,
              request.characteristic.service?.uuid == service.uuid,
              request.characteristic.uuid == CBUUID(string: CBUUIDL2CAPPSMCharacteristicString) else {
            peripheral.respond(to: request, withResult: .requestNotSupported); return
        }
        guard (0...2).contains(request.offset) else {
            peripheral.respond(to: request, withResult: .invalidOffset); return
        }
        // Apple's PSM characteristic is little endian; the authenticated MAIN route is big endian.
        request.value = Data([UInt8(truncatingIfNeeded: psm), UInt8(truncatingIfNeeded: psm >> 8)]).subdata(in: request.offset..<2)
        peripheral.respond(to: request, withResult: .success)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: (any Error)?) {
        guard peripheral === manager else { return }
        guard let channel else {
            if let error { events?.candidateFailed(error) }
            else { events?.candidateFailed(BluetoothAudioListenerError.unexpectedCallback) }
            return
        }
        guard let owner = events, error == nil, owner.mayAccept(psm: channel.psm) else {
            channel.inputStream?.close(); channel.outputStream?.close()
            if let error { events?.candidateFailed(error) }
            return
        }
        let psm = channel.psm
        do { owner.opened(try BluetoothControlFrameTransport(acceptedChannel: channel), psm: psm) }
        catch { owner.candidateFailed(error) }
    }
}
