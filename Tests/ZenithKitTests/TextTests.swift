import AppKit
import Testing
import ZenithKit

/// Empty text, as a meter's blank detail or a plugin's blank icon, which the bar and the panel
/// measure and draw.
@Test func emptyTextIsSafe() {
    let font = NSFont.systemFont(ofSize: 13)
    #expect(NSAttributedString(string: "", attributes: [.font: font]).firstFont == nil)
    #expect(NSAttributedString(string: "A", attributes: [.font: font]).firstFont == font)
    #expect(inkBounds(NSAttributedString(string: "", attributes: [.font: font])).width == 0)
}
