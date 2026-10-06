import Foundation
import Testing
@testable import ZenithCore

@Test func snapshotRowsFollowKosmos() throws {
    let json = """
        {"version":1,"profile":"home","displays":[{"id":1,"name":"Built-in"},{"id":2,"name":"LG"}],
         "workspaces":[
           {"name":"1","display":2,"shown":true,"focused":true,"windows":[{"id":5,"app":"Ghostty","x":0,"y":0},
                                                                          {"id":6,"app":"Nobody","x":900,"y":0}]},
           {"name":"2","display":2,"shown":false,"focused":false,"windows":[]},
           {"name":"3","display":1,"shown":true,"focused":false,"windows":[]},
           {"name":"9","display":0,"shown":false,"focused":false,"windows":[]}],
         "focused":{"window":5,"app":"Ghostty","workspace":"1"},"extra":true}
        """
    let state = try #require(KosmosState.decode(Data(json.utf8)))
    let rows = workspaceRows(state, icons: ["Ghostty": ":ghostty:", "Default": ":default:"])
    #expect(rows[2]?.pills == [Pill(name: "1", glyphs: ":ghostty: :default:", emphasis: .focused),
                               Pill(name: "2", glyphs: "", emphasis: .hidden)])
    #expect(rows[2]?.frontApp == "Ghostty")
    #expect(rows[1] == WorkspaceRow(pills: [Pill(name: "3", glyphs: "", emphasis: .shown)], frontApp: nil))
    #expect(rows[0] == nil)
}

@Test func emptyFocusedWorkspaceShowsDesktop() throws {
    let json = """
        {"version":1,"displays":[{"id":1,"name":"Built-in"}],
         "workspaces":[{"name":"4","display":1,"shown":true,"focused":true,"windows":[]}]}
        """
    let rows = workspaceRows(try #require(KosmosState.decode(Data(json.utf8))), icons: [:])
    #expect(rows[1]?.frontApp == "Desktop")
}

@Test func otherVersionsAreIgnored() {
    #expect(KosmosState.decode(Data(#"{"version":2,"displays":[],"workspaces":[]}"#.utf8)) == nil)
}

@Test func displayNumbersMatchKosmos() {
    #expect(displayNumber(uuid: "B", active: 1, managed: ["A", "B"]) == 1)
    #expect(displayNumber(uuid: "b", active: 2, managed: ["A", "B"]) == 2)
    #expect(displayNumber(uuid: "C", active: 2, managed: ["A", "B"]) == 0)
}

@Test func clockReadsLikeSketchyBar() {
    let date = Date(timeIntervalSince1970: 1_791_299_100) // 2026-10-06 15:05 UTC
    let (day, time) = clockText(date, timeZone: TimeZone(identifier: "UTC")!)
    #expect(day == "Tue\u{2009}Oct\u{2009}6")
    #expect(time == "3:05PM")
    #expect(nextMinute(after: date.addingTimeInterval(1)) == date.addingTimeInterval(60))
}

@Test func layoutPlacesBothEnds() {
    let edges = layout(left: [10, 20], right: [30, 5], width: 100, insets: (left: 2, right: 3))
    #expect(edges.left == [2, 12])
    #expect(edges.right == [67, 62])
}

@Test func volumeGlyphs() {
    #expect(volumeGlyph(0.5, muted: true).dim)
    #expect(volumeGlyph(0, muted: false).dim)
    #expect(volumeGlyph(0.7, muted: false).glyph == "\u{1002A8}")
    #expect(!volumeGlyph(0.7, muted: false).dim)
    #expect(volumeGlyph(0.4, muted: false).glyph == "\u{1002A6}")
    #expect(volumeGlyph(0.1, muted: false).glyph == "\u{1002A4}")
}

@Test func themeColors() {
    #expect(RGBA(hex: "#ff000080") == RGBA(hex: "#ff000080"))
    #expect(RGBA(hex: "#7aa2f7")?.alpha == 1)
    #expect(RGBA(hex: "#a9b1d680")?.alpha == 128.0 / 255)
    #expect(RGBA(hex: "7aa2f7") == nil)
    #expect(Theme(json: Data(##"{"background":"#000000"}"##.utf8)) == nil)
}

@Test func stylesOutlineTheBar() {
    let width = 1000.0
    let standard = BarStyle.standard.outline(width: width)
    #expect(standard.contains(CGPoint(x: 1, y: 1)) && standard.contains(CGPoint(x: 999, y: 24)))
    let floating = BarStyle.floating.outline(width: width)
    #expect(!floating.contains(CGPoint(x: 230, y: 12)))
    #expect(floating.contains(CGPoint(x: 245, y: 24)))
    // The rounded bottom corner leaves its corner point clear.
    #expect(!floating.contains(CGPoint(x: 240.5, y: 0.5)))
    let tab = BarStyle.tab.outline(width: width)
    // The flare fills the corner where the bar meets the edge, outside its 12 pt arc...
    #expect(tab.contains(CGPoint(x: 239, y: 24.5)))
    // ...and leaves clear the inside of the arc.
    #expect(!tab.contains(CGPoint(x: 230, y: 15)))
    #expect(tab.contains(CGPoint(x: 761, y: 24.5)))
}

@Test func configReadsStyle() {
    #expect(Config(json: Data(#"{"style":"tab"}"#.utf8))?.style == .tab)
    #expect(Config(json: Data("{}".utf8))?.style == .standard)
    #expect(Config(json: Data(#"{"style":"wavy"}"#.utf8)) == nil)
}
