import AppKit

NSApplication.shared.setActivationPolicy(.accessory)
let controller = Controller()
controller.start()
NSApplication.shared.run()
