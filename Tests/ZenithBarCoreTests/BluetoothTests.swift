import Foundation
import Testing
@testable import ZenithBarCore

// system_profiler's output on Steve's Mac on 2026-10-07 (docs/bluetooth.md), with the AirPods and
// the mouse connected as they would read, a device named by its address, and two entries System
// Settings leaves out: the AirPods' Bluetooth LE link, listed as connected under a changing
// address while the AirPods were not, and "steez", with no product ID or type.
private let profile = Data("""
    {"SPBluetoothDataType": [{"controller_properties": {"controller_address": "60:1A:2B:3C:4D:02",
        "controller_state": "attrib_on"},
      "device_connected": [
        {"steez AirPods ANC": {"device_address": "7C:1A:2B:3C:4D:03", "device_batteryLevelCase": "21%",
          "device_batteryLevelLeft": "100%", "device_batteryLevelRight": "94%", "device_minorType": "Headphones",
          "device_productID": "0x201B", "device_vendorID": "0x004C"}},
        {"MX Master 2S": {"device_address": "DB:1A:2B:3C:4D:06", "device_minorType": "Mouse"}},
        {"steez AirPods ANC": {"device_address": "C1:1A:2B:3C:4D:05", "device_batteryLevelLeft": "100%",
          "device_services": "0x400000 < BLE >"}}],
      "device_not_connected": [
        {"Xbox Wireless Controller": {"device_address": "AC:1A:2B:3C:4D:04", "device_minorType": "Gamepad"}},
        {"steez": {"device_address": "00:1A:2B:3C:4D:01", "device_rssi": "-55"}},
        {"AULA F75Max-1": {"device_address": "FC:1A:2B:3C:4D:07", "device_batteryLevelMain": "80%",
          "device_minorType": "Keyboard"}},
        {"11:22:33:44:55:66": {"device_address": "11:22:33:44:55:66"}}]}]}
    """.utf8)

@Test func readsTheStateFromSystemProfiler() throws {
    let state = try #require(bluetoothState(json: profile))
    #expect(state.powered == true)
    #expect(state.connected.map(\.name) == ["MX Master 2S", "steez AirPods ANC"])
    #expect(state.available.map(\.name) == ["AULA F75Max-1", "Xbox Wireless Controller"])
    let pods = try #require(state.connected.last)
    #expect(pods == BluetoothDevice(address: "7C:1A:2B:3C:4D:03", name: "steez AirPods ANC", connected: true, vendorID: 0x004C,
                                    productID: 0x201B, minorType: "Headphones", battery: 94))
    // A device not connected keeps no battery, as system_profiler's levels for it are the last it heard.
    #expect(state.available.first?.battery == nil)
    #expect(state.connected.first?.battery == nil)
    // The sound panel's lookup keeps every device, the one named by its address too.
    #expect(bluetoothDevices(json: profile).count == 7)
    #expect(bluetoothState(json: Data("nope".utf8)) == nil)
}

@Test func powerAndTheIcon() throws {
    var state = try #require(bluetoothState(json: profile))
    #expect(state.icon == .connected)
    #expect(state.icon?.glyph == "\u{F00B1}")
    state.devices = state.available
    #expect(state.icon == .on)
    let off = try #require(bluetoothState(json: Data("""
        {"SPBluetoothDataType": [{"controller_properties": {"controller_state": "attrib_off"}}]}
        """.utf8)))
    #expect(off.powered == false)
    #expect(off.icon == .off)
    #expect(bluetoothState(json: Data(#"{"SPBluetoothDataType": [{}]}"#.utf8))?.icon == nil)
    #expect(bluetoothCaption(powered: nil, phrase: 0) == "No adapter")
    #expect(bluetoothCaption(powered: false, phrase: 3) == "Turned off")
    #expect(bluetoothCaption(powered: true, phrase: 7) == "Polishing packets")
    #expect(bluetoothCaption(powered: true, phrase: 8) == "Untangling wires")
}

@Test func deviceSymbols() {
    #expect(bluetoothSymbol(BluetoothDevice(name: "steez AirPods ANC", vendorID: 0x004C, productID: 0x201B,
                                            minorType: "Headphones")) == "airpods.gen4")
    #expect(bluetoothSymbol(BluetoothDevice(name: "Steve's AirPods", vendorID: 0x004C, productID: 0x2099)) == "airpods")
    #expect(bluetoothSymbol(BluetoothDevice(name: "steez studio beatz", vendorID: 0x290B, productID: 0x0200,
                                            minorType: "Headphones")) == "headphones")
    #expect(bluetoothSymbol(BluetoothDevice(name: "MX Master 2S", minorType: "Mouse")) == "computermouse.fill")
    #expect(bluetoothSymbol(BluetoothDevice(name: "AULA F75Max-1", minorType: "Keyboard")) == "keyboard.fill")
    #expect(bluetoothSymbol(BluetoothDevice(name: "Xbox Wireless Controller", minorType: "Gamepad")) == "gamecontroller.fill")
    #expect(bluetoothSymbol(BluetoothDevice(name: "steez")) == nil)
}

@Test func pendingActionsSettle() throws {
    let state = try #require(bluetoothState(json: profile))
    let pending: [String: BluetoothAction] = [
        "7C:1A:2B:3C:4D:03": .connecting, // connected: done
        "DB:1A:2B:3C:4D:06": .disconnecting, // still connected: waits
        "AC:1A:2B:3C:4D:04": .connecting, // not yet: waits
        "FC:1A:2B:3C:4D:07": .disconnecting, // not connected: done
        "99:99:99:99:99:99": .connecting, // gone: done
    ]
    #expect(unsettled(pending, in: state) == ["DB:1A:2B:3C:4D:06": .disconnecting, "AC:1A:2B:3C:4D:04": .connecting])
    let pods = state.connected.last!
    #expect(bluetoothStatus(pods, pending: nil) == "94%")
    #expect(bluetoothStatus(pods, pending: .disconnecting) == "Disconnecting…")
    #expect(bluetoothStatus(state.available[0], pending: .connecting) == "Connecting…")
    #expect(bluetoothStatus(state.available[0], pending: nil) == "")
}
