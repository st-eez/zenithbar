import Foundation
import Testing
@testable import ZenithCore

@Test func snapshotRowsFollowKosmos() throws {
    let json = """
        {"version":1,"profile":"home","displays":[{"id":1,"name":"Built-in","uuid":"B"},{"id":2,"name":"LG","uuid":"L"}],
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
    #expect(rows["L"]?.pills == [Pill(name: "1", glyphs: ":ghostty: :default:", emphasis: .focused),
                                 Pill(name: "2", glyphs: "", emphasis: .hidden)])
    #expect(rows["L"]?.frontApp == "Ghostty")
    #expect(rows["B"] == WorkspaceRow(pills: [Pill(name: "3", glyphs: "", emphasis: .shown)], frontApp: nil))
    #expect(rows.count == 2)
}

@Test func emptyFocusedWorkspaceShowsDesktop() throws {
    let json = """
        {"version":1,"displays":[{"id":1,"name":"Built-in","uuid":"B"}],
         "workspaces":[{"name":"4","display":1,"shown":true,"focused":true,"windows":[]}]}
        """
    let rows = workspaceRows(try #require(KosmosState.decode(Data(json.utf8))), icons: [:])
    #expect(rows["B"]?.frontApp == "Desktop")
}

@Test func workspacesJoinDisplaysByUUID() throws {
    // Two displays share number 1, as when Kosmos manages one of them; a workspace without a
    // displayUUID, from an older Kosmos, joins by number.
    let json = """
        {"version":1,"displays":[{"id":1,"uuid":"A"},{"id":1,"uuid":"B"},{"id":2,"uuid":"C"}],
         "workspaces":[
           {"name":"1","display":1,"displayUUID":"B","shown":true,"focused":true,"windows":[]},
           {"name":"2","display":1,"displayUUID":"A","shown":true,"focused":false,"windows":[]},
           {"name":"3","display":0,"displayUUID":"A","shown":false,"focused":false,"windows":[]},
           {"name":"4","display":2,"shown":true,"focused":false,"windows":[]},
           {"name":"5","display":1,"displayUUID":"Gone","shown":false,"focused":false,"windows":[]}]}
        """
    let rows = workspaceRows(try #require(KosmosState.decode(Data(json.utf8))), icons: [:])
    #expect(rows["A"]?.pills.map(\.name) == ["2", "3"])
    #expect(rows["B"] == WorkspaceRow(pills: [Pill(name: "1", glyphs: "", emphasis: .focused)], frontApp: "Desktop"))
    #expect(rows["C"]?.pills.map(\.name) == ["4"])
    #expect(rows.count == 3)
}

@Test func otherVersionsAreIgnored() {
    #expect(KosmosState.decode(Data(#"{"version":2,"displays":[],"workspaces":[]}"#.utf8)) == nil)
}

@Test func displaysWithoutUUIDShowNothing() throws {
    let json = #"{"version":1,"displays":[{"id":1,"name":"Old"}],"workspaces":[{"name":"1","display":1,"shown":true,"focused":true,"windows":[]}]}"#
    #expect(workspaceRows(try #require(KosmosState.decode(Data(json.utf8))), icons: [:]).isEmpty)
}

@Test func clockReadsLikeSketchyBar() {
    let date = Date(timeIntervalSince1970: 1_791_299_100) // 2026-10-06 15:05 UTC
    let (day, time) = clockText(date, timeZone: TimeZone(identifier: "UTC")!)
    #expect(day == "Tue\u{2009}Oct\u{2009}6")
    #expect(time == "3:05PM")
    #expect(nextMinute(after: date.addingTimeInterval(1)) == date.addingTimeInterval(60))
}

@Test func layoutPlacesBothEnds() {
    let edges = layout(left: [10, 20], right: [30, 5], width: 100, insets: (left: 2, right: 3), gap: 4, notch: nil)
    #expect(edges.left == [2, 16])
    #expect(edges.right == [67, 58])
}

@Test func leftRunStopsBeforeTheRightRun() {
    // The right run starts at 70, so the left run ends by 66.
    #expect(layout(left: [30, 30], right: [30], width: 100, insets: (left: 0, right: 0), gap: 4, notch: nil).left == [0, 34])
    #expect(layout(left: [30, 30, 5], right: [30], width: 100, insets: (left: 0, right: 0), gap: 4, notch: nil).left == [0, 34])
    // Items are left out from the end, so a short one after a long one goes too.
    #expect(layout(left: [30, 40, 1], right: [30], width: 100, insets: (left: 0, right: 0), gap: 4, notch: nil).left == [0])
    // Without a right run, the left run ends at the right inset.
    #expect(layout(left: [50, 46], right: [], width: 100, insets: (left: 0, right: 4), gap: 4, notch: nil).left == [0])
}

@Test func leftRunStopsBeforeTheNotch() {
    // The built-in display: 1728 pt wide, its notch from 771.5.
    let edges = layout(left: [700, 40], right: [100], width: 1728, insets: (left: 21, right: 23), gap: 16, notch: 771.5)
    #expect(edges.left == [21])
    #expect(edges.right == [1605])
    #expect(layout(left: [700, 18], right: [], width: 1728, insets: (left: 21, right: 23), gap: 16, notch: 771.5).left
        == [21, 737])
}

@Test func volumeGlyphs() {
    #expect(volumeGlyph(0.5, muted: true).dim)
    #expect(volumeGlyph(0, muted: false).dim)
    #expect(volumeGlyph(0.7, muted: false).glyph == "\u{1002A8}")
    #expect(!volumeGlyph(0.7, muted: false).dim)
    #expect(volumeGlyph(0.4, muted: false).glyph == "\u{1002A6}")
    #expect(volumeGlyph(0.1, muted: false).glyph == "\u{1002A4}")
}

@Test func wifiLevels() {
    #expect(wifiLevel(rssi: -45) == 4)
    #expect(wifiLevel(rssi: -55) == 4)
    #expect(wifiLevel(rssi: -56) == 3)
    #expect(wifiLevel(rssi: -66) == 3)
    #expect(wifiLevel(rssi: -67) == 2)
    #expect(wifiLevel(rssi: -78) == 1)
    #expect(wifiLevel(rssi: -89) == 0)
    #expect(wifiLevel(rssi: -120) == 0)
}

@Test func networkGlyphs() {
    #expect(networkGlyph(.wifi(rssi: -45)) == ("\u{F0928}", false))
    #expect(networkGlyph(.wifi(rssi: -70)).glyph == "\u{F0922}")
    #expect(networkGlyph(.wifi(rssi: -95)).glyph == "\u{F092F}")
    #expect(networkGlyph(.ethernet) == ("\u{F0200}", false))
    #expect(networkGlyph(.offline(wifiPower: false)) == ("\u{F092E}", true))
    #expect(networkGlyph(.offline(wifiPower: true)) == ("\u{F092B}", true))
    #expect(networkGlyph(.offline(wifiPower: nil)).dim)
}

@Test func primaryServiceSkipsTunnels() {
    let wifi = NetworkService(id: "W", interface: "en0", kind: .wifi, address: "192.168.1.50", router: "192.168.1.1")
    let lan = NetworkService(id: "E", interface: "en10", kind: .ethernet, address: "192.168.1.60", router: "192.168.1.1")
    let tailscale = NetworkService(id: "T", interface: "utun6", kind: .other, address: "100.64.0.1",
                                   router: "100.64.0.1")
    // Tailscale without an exit node, as measured: the store names en0.
    #expect(primaryService([tailscale, wifi], primaryInterface: "en0", order: ["W", "T"]) == wifi)
    #expect(primaryService([wifi, lan], primaryInterface: "en10", order: ["E", "W"]) == lan)
    // A tunnel taking the default route leaves the first service in the order with a router.
    #expect(primaryService([tailscale, wifi, lan], primaryInterface: "utun6", order: ["E", "W", "T"]) == lan)
    #expect(primaryService([tailscale, wifi], primaryInterface: "utun6", order: []) == wifi)
    #expect(primaryService([wifi], primaryInterface: nil, order: ["W"]) == nil)
    #expect(Route(primary: lan, wifiRSSI: -50, wifiPower: true) == .ethernet)
    #expect(Route(primary: wifi, wifiRSSI: -50, wifiPower: true) == .wifi(rssi: -50))
    #expect(Route(primary: nil, wifiRSSI: 0, wifiPower: false) == .offline(wifiPower: false))
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

@Test func pluginLinesDecode() throws {
    let line = #"""
        {"item":"agents","icon":"x","alert":true,"pages":[{"tab":"Claude","title":"Claude Code · Max","rows":[
          {"caption":"LIMITS"},{"meter":"Session","value":1.4,"detail":"95%","tone":"alert"},
          {"note":"Resets in","until":1000,"tone":"dim"},{"meter":"Wed","value":0.3,"detail":"163M","bold":true}]}]}
        """#
    let item = try #require(PluginItem.decode(Data(line.utf8)))
    #expect(item.alert && !item.hidden)
    let rows = try #require(item.pages.first?.rows)
    #expect(rows[0] == .caption("LIMITS"))
    #expect(rows[1] == .meter(label: "Session", value: 1, detail: "95%", tone: .alert, bold: false))
    #expect(rows[2] == .note(text: "Resets in", until: Date(timeIntervalSince1970: 1000), since: nil, detail: nil, tone: .dim))
    #expect(PluginItem.decode(Data(#"{"item":"a","icon":"x","pages":[{"tab":"","title":"","rows":[{"what":1}]}]}"#.utf8)) == nil)
}

@Test func notesTellTime() {
    let now = Date(timeIntervalSince1970: 100_000)
    #expect(noteText("Resets in", until: now.addingTimeInterval(2 * 86400 + 22 * 3600 + 5), since: nil, detail: nil, now: now)
        == "Resets in 2d 22h")
    #expect(noteText("Resets in", until: now.addingTimeInterval(3600 + 59 * 60), since: nil, detail: nil, now: now) == "Resets in 1h 59m")
    #expect(noteText("Updated", until: nil, since: now.addingTimeInterval(-180), detail: "5 sessions", now: now)
        == "Updated 3m ago  ·  5 sessions")
    #expect(noteText("Updated", until: nil, since: now, detail: nil, now: now) == "Updated just now")
}

@Test func configReadsPlugins() {
    let config = Config(json: Data(#"{"plugins":[{"command":["~/a","b"],"interval":900}]}"#.utf8))
    #expect(config?.plugins == [Config.Plugin(command: ["~/a", "b"], interval: 900)])
    #expect(Config(json: Data(#"{"plugins":[{"command":["a"],"interval":1}]}"#.utf8)) != nil)
    #expect(Config(json: Data(#"{"plugins":[{"command":["a"],"interval":0}]}"#.utf8)) == nil)
    #expect(Config(json: Data(#"{"plugins":[{"command":["a"],"interval":-5}]}"#.utf8)) == nil)
}
