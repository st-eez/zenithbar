import AppKit
import ZenithBarKit

// First, so a crash anywhere in starting counts; only when launchd, its parent, started it, so
// a run by hand counts nothing (docs/overview.md, install).
if getppid() == 1 {
    let launches = LaunchGuard.standard
    guard launches.launch() else {
        let reason = "ZenithBar exited within \(Int(launches.healthy)) s of launching \(launches.limit) times in a row; "
            + "it starts again by launchctl kickstart, at login or by script/install.sh"
        log.error("\(reason, privacy: .public)")
        FileHandle.standardError.write(Data("\(Date().formatted(.iso8601)) \(reason)\n".utf8))
        exit(0)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + launches.healthy) { launches.clear() }
}
NSApplication.shared.setActivationPolicy(.accessory)
let controller = Controller()
controller.start()
NSApplication.shared.run()
