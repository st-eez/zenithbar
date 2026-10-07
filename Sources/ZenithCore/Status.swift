import Foundation

/// The calendar's two parts, "Mon Oct 6" with thin spaces between its words, about 4 pt in
/// JetBrains Mono, and "3:05PM".
public func clockText(_ date: Date, timeZone: TimeZone = .current) -> (date: String, time: String) {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "EEE MMM d"
    let day = formatter.string(from: date).replacingOccurrences(of: " ", with: "\u{2009}")
    formatter.dateFormat = "h:mma"
    return (day, formatter.string(from: date))
}

/// The start of the minute after `date`, when the clock next changes.
public func nextMinute(after date: Date) -> Date {
    Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60 + 60)
}

/// The filled SF Symbols speaker for a volume from 0 to 1, and whether it shows dim, as when
/// muted.
public func volumeSymbol(_ volume: Double, muted: Bool) -> (name: String, dim: Bool) {
    let percent = Int((volume * 100).rounded())
    if muted || percent == 0 { return ("speaker.slash.fill", true) }
    if percent >= 66 { return ("speaker.wave.3.fill", false) }
    if percent >= 33 { return ("speaker.wave.2.fill", false) }
    return ("speaker.wave.1.fill", false)
}
