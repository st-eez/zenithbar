import AppKit
@preconcurrency import CoreBluetooth
@preconcurrency import IOBluetooth
import ZenithBarCore
import ZenithBarKit

// Private, as blueutil calls it: 1 on, 0 off. Undocumented; macOS has no public way to set
// Bluetooth's power (docs/bluetooth.md, power).
@_silgen_name("IOBluetoothPreferenceSetControllerPowerState") private func setControllerPowerState(_ state: Int32)

/// The paired devices and the controller's power, for the Bluetooth item and panel
/// (docs/bluetooth.md). Read from system_profiler, which needs no permission, again whenever
/// CoreBluetooth's state or IOBluetooth's connections change, which need Bluetooth permission.
/// Nothing polls.
@MainActor final class Bluetooth: NSObject, CBCentralManagerDelegate {
    private(set) var state = BluetoothState()
    /// Clicks waiting for their device, by address.
    private(set) var pending: [String: BluetoothAction] = [:]
    private let changed: @MainActor () -> Void
    private var central: CBCentralManager?
    private var connects: IOBluetoothUserNotification?
    private var reading = false, readAgain = false

    init(changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        super.init()
        read()
        // Asking at launch would prompt; the panel's first open asks (`opened`).
        if CBManager.authorization == .allowedAlways { listen() }
        log.info("Bluetooth permission at launch: \(CBManager.authorization.rawValue, privacy: .public) (0 not asked, 2 denied, 3 allowed)")
    }

    /// The panel opened: reads again, for the batteries, and asks for Bluetooth permission the
    /// first time, as starting CoreBluetooth makes macOS prompt.
    func opened() {
        if central == nil, CBManager.authorization == .notDetermined { listen() }
        read()
    }

    private func listen() {
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    /// Called once it starts, after the prompt's answer, and as the power changes.
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let allowed = central.state != .unauthorized
        MainActor.assumeIsolated {
            // IOBluetooth calls `connected` for each device connected now, then for each new connection.
            if allowed, connects == nil {
                connects = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
            }
            readTwice()
        }
    }

    @objc private func connected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
        readTwice()
    }

    @objc private func disconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        readTwice()
    }

    // MARK: reads

    /// Reads now and 2 s later, as system_profiler may lag an event and AirPods report their
    /// batteries after connecting (docs/bluetooth.md, events). Unconfirmed: nothing connected
    /// while the probes ran.
    private func readTwice() {
        read()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in MainActor.assumeIsolated { self?.read() } }
    }

    /// system_profiler off the main thread, about 140 ms and 40 ms of CPU, once at a time.
    func read() {
        guard !reading else { return readAgain = true }
        reading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPBluetoothDataType", "-json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var next: BluetoothState?
            if (try? process.run()) != nil {
                next = bluetoothState(json: pipe.fileHandleForReading.readDataToEndOfFile())
                process.waitUntilExit()
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reading = false
                    if let next { self.received(next) } else { log.error("Could not read Bluetooth from system_profiler") }
                    if self.readAgain {
                        self.readAgain = false
                        self.read()
                    }
                }
            }
        }
    }

    private func received(_ next: BluetoothState) {
        let settled = unsettled(pending, in: next)
        guard next != state || settled != pending else { return }
        state = next
        pending = settled
        changed()
    }

    // MARK: actions

    /// Whether IOBluetooth may be used, asking or pointing to System Settings when not.
    private func allowed() -> Bool {
        switch CBManager.authorization {
        case .allowedAlways: return true
        case .notDetermined: listen()
        default: NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
        }
        return false
    }

    func connect(_ address: String) {
        guard allowed(), let device = IOBluetoothDevice(addressString: address) else { return }
        begin(address, .connecting)
        // Answers through `connectionComplete(_:status:)`.
        let status = device.openConnection(self)
        if status != kIOReturnSuccess { failed(address, "connect", status) }
    }

    @objc private func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        if status != kIOReturnSuccess, let address = device.addressString { failed(address, "connect", status) }
        readTwice()
    }

    func disconnect(_ address: String) {
        guard allowed(), let device = IOBluetoothDevice(addressString: address) else { return }
        begin(address, .disconnecting)
        let status = device.closeConnection()
        if status != kIOReturnSuccess { failed(address, "disconnect", status) }
        readTwice()
    }

    /// CoreBluetooth's state change reads it back.
    func setPower(_ on: Bool) {
        guard allowed() else { return }
        DispatchQueue.global(qos: .userInitiated).async { setControllerPowerState(on ? 1 : 0) }
    }

    /// Marks the device waiting, for 20 s at most, as Omarchy's `pendingTimeout`.
    private func begin(_ address: String, _ action: BluetoothAction) {
        pending[address] = action
        changed()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pending[address] == action else { return }
                self.pending[address] = nil
                self.changed()
            }
        }
    }

    #if DEBUG
    /// Draws the device named `name` connected with `battery`, until the next read, for captures
    /// without connecting it (Controller.watchTestHooks).
    func pretend(connected name: String, battery: Int?) {
        guard let index = state.devices.firstIndex(where: { $0.name == name }) else { return }
        state.devices[index].connected = true
        state.devices[index].battery = battery
        changed()
    }
    #endif

    private func failed(_ address: String, _ action: String, _ status: IOReturn) {
        log.error("Could not \(action, privacy: .public) Bluetooth device \(address, privacy: .public): \(String(format: "0x%08x", status), privacy: .public)")
        pending[bluetoothAddress(uid: address) ?? address] = nil
        changed()
    }
}
