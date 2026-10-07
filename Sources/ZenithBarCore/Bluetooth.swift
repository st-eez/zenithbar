import Foundation

// What the Bluetooth item and panel show, read from `system_profiler SPBluetoothDataType -json`,
// after Omarchy 4's Bluetooth panel (`shell/plugins/panels/bluetooth/`) (docs/bluetooth.md), and
// the paired devices the sound panel matches to AirPods (docs/sound.md).

/// A paired device, as system_profiler lists it.
public struct BluetoothDevice: Equatable, Sendable {
    /// In capitals with colons, as "7C:1A:2B:3C:4D:03".
    public var address: String
    public var name: String
    public var connected: Bool
    public var vendorID: Int?
    public var productID: Int?
    /// Bluetooth's minor device class, as "Headphones".
    public var minorType: String?
    /// The lowest percent of its batteries but a case, as an AirPod's; nil while not connected,
    /// as system_profiler keeps the last levels it heard.
    public var battery: Int?

    public init(address: String = "", name: String = "", connected: Bool = false, vendorID: Int? = nil,
                productID: Int? = nil, minorType: String? = nil, battery: Int? = nil) {
        self.address = address
        self.name = name
        self.connected = connected
        self.vendorID = vendorID
        self.productID = productID
        self.minorType = minorType
        self.battery = battery
    }
}

public struct BluetoothState: Equatable, Sendable {
    /// Nil without a controller.
    public var powered: Bool?
    /// By name.
    public var devices: [BluetoothDevice]

    public init(powered: Bool? = nil, devices: [BluetoothDevice] = []) {
        self.powered = powered
        self.devices = devices
    }

    public var connected: [BluetoothDevice] { devices.filter(\.connected) }
    /// Paired and not connected.
    public var available: [BluetoothDevice] { devices.filter { !$0.connected } }

    /// The bar's icon, as Omarchy's: off, on, or on with a device connected; nil without a controller.
    public var icon: BluetoothIcon? {
        guard let powered else { return nil }
        return !powered ? .off : connected.isEmpty ? .on : .connected
    }
}

/// Material's Bluetooth glyphs in Nerd Fonts, as SF Symbols has no Bluetooth logo.
public enum BluetoothIcon: Equatable, Sendable {
    case on, connected, off

    public var glyph: String {
        switch self {
        case .on: "\u{F00AF}"
        case .connected: "\u{F00B1}"
        case .off: "\u{F00B2}"
        }
    }
}

/// system_profiler's JSON as the panel shows it, or nil when it is unreadable. A device whose
/// name is empty or an address is left out, as Omarchy's `hasHumanName`.
public func bluetoothState(json: Data) -> BluetoothState? {
    guard var state = parse(json) else { return nil }
    state.devices.removeAll { $0.name.trimmingCharacters(in: .whitespaces).isEmpty || bluetoothAddress(uid: $0.name) != nil }
    state.devices.sort { a, b in
        let order = a.name.localizedStandardCompare(b.name)
        return order == .orderedSame ? a.address < b.address : order == .orderedAscending
    }
    return state
}

/// Every paired device in system_profiler's JSON, by address, for the sound panel's AirPods.
public func bluetoothDevices(json: Data) -> [String: BluetoothDevice] {
    Dictionary((parse(json)?.devices ?? []).map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
}

private func parse(_ json: Data) -> BluetoothState? {
    guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
          let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
    var state = BluetoothState()
    func hex(_ value: Any?) -> Int? { (value as? String).flatMap { Int($0.replacingOccurrences(of: "0x", with: ""), radix: 16) } }
    for controller in controllers {
        if let properties = controller["controller_properties"] as? [String: Any],
           let power = properties["controller_state"] as? String {
            state.powered = power == "attrib_on"
        }
        // Connected and not connected devices are lists of one-entry objects keyed by name.
        for (key, value) in controller {
            guard let list = value as? [[String: [String: Any]]] else { continue }
            let connected = key == "device_connected"
            for (name, info) in list.flatMap({ $0 }) {
                guard let address = info["device_address"] as? String else { continue }
                // "100%" for each part, as an AirPod's left, right and case.
                let levels = info.compactMap { key, value -> Int? in
                    guard key.hasPrefix("device_batteryLevel"), key != "device_batteryLevelCase" else { return nil }
                    return (value as? String).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
                }
                state.devices.append(BluetoothDevice(address: address.uppercased(), name: name, connected: connected,
                                                     vendorID: hex(info["device_vendorID"]), productID: hex(info["device_productID"]),
                                                     minorType: info["device_minorType"] as? String,
                                                     battery: connected ? levels.min() : nil))
            }
        }
    }
    return state
}

/// The Bluetooth address a CoreAudio UID starts with, as "7C-1A-2B-3C-4D-03:output", in
/// capitals with colons; nil for a UID without one.
public func bluetoothAddress(uid: String) -> String? {
    let head = uid.prefix(17).uppercased()
    let parts = head.split(whereSeparator: { $0 == "-" || $0 == ":" })
    guard head.count == 17, parts.count == 6, parts.allSatisfy({ $0.count == 2 && UInt8($0, radix: 16) != nil }) else { return nil }
    return parts.joined(separator: ":")
}

/// Apple's AirPods by Bluetooth product ID, vendor 0x004C, as their SF Symbols.
private let airpodsModels: [Int: String] = [
    0x2002: "airpods", 0x200F: "airpods", // AirPods, 2nd generation
    0x2013: "airpods.gen3",
    0x2019: "airpods.gen4", 0x201B: "airpods.gen4", // AirPods 4, and with noise cancellation
    0x200E: "airpodspro", 0x2014: "airpodspro", 0x2024: "airpodspro", // Pro, Pro 2, Pro 2 USB-C
    0x200A: "airpodsmax", 0x201F: "airpodsmax", // Max, Max USB-C
]

/// The AirPods' model symbol by product ID, or nil for a device that is none.
public func airpodsSymbol(_ device: BluetoothDevice) -> String? {
    device.vendorID == 0x004C ? device.productID.flatMap { airpodsModels[$0] } : nil
}

/// A device's SF Symbol in the panel: the AirPods' model, then by its minor type; nil for the
/// Bluetooth glyph.
public func bluetoothSymbol(_ device: BluetoothDevice) -> String? {
    if let model = airpodsSymbol(device) { return model }
    if device.name.lowercased().contains("airpods") { return "airpods" }
    return switch device.minorType {
    case "Headphones", "Headset": "headphones"
    case "Keyboard": "keyboard.fill"
    case "Mouse": "computermouse.fill"
    case "Gamepad", "Joystick": "gamecontroller.fill"
    case "Loudspeaker", "Speaker": "hifispeaker.fill"
    case "Smartphone", "Cellular": "iphone"
    default: nil
    }
}

/// A click's action while it waits for the device to get there.
public enum BluetoothAction: Equatable, Sendable {
    case connecting, disconnecting
}

/// The actions the state has not carried out yet: a device gone, or connected as asked, settles its.
public func unsettled(_ pending: [String: BluetoothAction], in state: BluetoothState) -> [String: BluetoothAction] {
    pending.filter { address, action in
        state.devices.first { $0.address == address }.map { $0.connected != (action == .connecting) } ?? false
    }
}

/// The line under a device's name, as Omarchy's `statusText`: the action it waits for, else a
/// connected device's battery, else nothing.
public func bluetoothStatus(_ device: BluetoothDevice, pending: BluetoothAction?) -> String {
    switch pending {
    case .connecting: "Connecting…"
    case .disconnecting: "Disconnecting…"
    case nil: device.battery.map { "\($0)%" } ?? ""
    }
}

/// Omarchy's captions under "Bluetooth" while it is on, one every 2.8 s.
public let bluetoothPhrases = ["Untangling wires", "Streaming vikings", "Pairing mysteries", "Herding headsets",
                               "Taming radios", "Summoning speakers", "Wrangling codecs", "Polishing packets"]

/// The caption under "Bluetooth": a phrase while on, as Omarchy's `heroStatusText`.
public func bluetoothCaption(powered: Bool?, phrase: Int) -> String {
    switch powered {
    case nil: "No adapter"
    case false: "Turned off"
    case true: bluetoothPhrases[phrase % bluetoothPhrases.count]
    }
}
