import AppKit
import ZenithBarCore
import ZenithBarKit

/// The battery item, read again at each change IOKit reports for a power source; a Mac without
/// a battery shows none.
@MainActor final class BatteryModule: BarModule {
    let keys = ["battery"]
    private var battery: Battery?
    private var host: ModuleHost!
    private var images = DrawingCache<Item?>()

    func start(_ host: ModuleHost) {
        self.host = host
        battery = Battery.read()
        Battery.watch { [weak self] in self?.read() }
    }

    func wake() { read() }

    private func read() {
        let next = Battery.read()
        guard next != battery else { return }
        battery = next
        host.changed(true)
    }

    func items(scale: CGFloat, theme: Theme) -> [(key: String, item: Item)] {
        guard let battery else { return [] }
        let shows = Drawn(battery: battery, foreground: theme.foreground, background: theme.background)
        guard let item = images.image("battery", scale: scale, shows: shows, draw: {
            battery.image(foreground: theme.foreground.nsColor, background: theme.background.nsColor, scale: scale)
        }) else { return [] }
        return [("battery", item)]
    }

    private struct Drawn: Equatable {
        var battery: Battery
        var foreground, background: RGBA
    }
}
