// Whether a bar's panel can take the keyboard for a text field without activating the bar's
// app, and how it gives the keyboard back (docs/network.md, the panel's focus).
//
//   zenithbar-probe focus
//       A small nonactivating panel at the pop up menu level in the built-in display's bottom
//       left corner, holding a secure text field, as the network panel's password field. Shows
//       it without key, then makes it key and the field first responder, posts "ab" to the
//       probe's own process (CGEventPostToPid, which no other app receives), and gives the
//       keyboard back two ways: ordering the panel out and in again with key refused, and
//       ordering it out. After each step reports the front process, the process WindowServer
//       sends keys to, whether the probe is active and whether the panel is key. Holds the
//       keyboard for about a second.
import AppKit
import CZenithBar

private final class KeyablePanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

@MainActor func focusProbe() -> Never {
    NSApplication.shared.setActivationPolicy(.accessory)
    let screen = builtInScreen()
    let panel = KeyablePanel(contentRect: NSRect(x: screen.frame.minX + 20, y: screen.frame.minY + 20, width: 220, height: 44),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .popUpMenu
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]
    panel.backgroundColor = .darkGray
    let field = NSSecureTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
    panel.contentView?.addSubview(field)
    let me = getpid()
    func name(_ pid: pid_t) -> String {
        pid == me ? "the probe" : NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
    }
    func report(_ step: String) {
        pumpEvents(0.3)
        print("\(step): front \(name(zenithbar_front_pid())) (NSWorkspace \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")), "
            + "keys to \(name(zenithbar_key_focus_pid())), probe active \(NSApp.isActive), panel key \(panel.isKeyWindow), "
            + "field editing \(field.currentEditor() != nil)")
    }
    report("before")
    panel.orderFrontRegardless()
    report("shown, key refused")
    panel.allowsKey = true
    panel.makeKey()
    panel.makeFirstResponder(field)
    report("made key")
    for character in ["a", "b"] {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: character == "a" ? 0 : 11, keyDown: down)
            event?.postToPid(me)
        }
    }
    pumpEvents(0.2)
    print("field after posting \"ab\" to the probe: \"\(field.stringValue)\"")
    panel.allowsKey = false
    panel.orderOut(nil)
    panel.orderFrontRegardless()
    report("ordered out and in, key refused")
    panel.allowsKey = true
    panel.makeKey()
    panel.makeFirstResponder(field)
    report("made key again")
    panel.allowsKey = false
    panel.orderOut(nil)
    report("ordered out")
    exit(0)
}
