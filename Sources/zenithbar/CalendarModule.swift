import AppKit
import ZenithBarCore
import ZenithBarKit

/// The calendar at the bar's right end, the date and the time, redrawn at each minute's start
/// on a timer set for it rather than a tick each second.
@MainActor final class CalendarModule: BarModule {
    let keys = ["calendar"]
    private var host: ModuleHost!
    private var clock: Timer?

    func start(_ host: ModuleHost) {
        self.host = host
        tick()
    }

    func wake() { tick() }

    private func tick() {
        clock?.invalidate()
        host.changed(true)
        let timer = Timer(fire: nextMinute(after: Date()), interval: 0, repeats: false) { [weak self] _ in
            onMain { self?.tick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    func items(scale: CGFloat, theme: Theme) -> [(key: String, item: Item)] {
        let (date, time) = clockText(Date())
        let bold = [NSAttributedString.Key.font: barFont(13, bold: true), .foregroundColor: theme.foreground.nsColor]
        let text = joined(NSAttributedString(string: date, attributes: bold), NSAttributedString(string: time, attributes: bold),
                          gap: 8)
        return [("calendar", Item(content: .text(text)))]
    }
}
