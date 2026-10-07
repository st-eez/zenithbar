import CZenith
import Foundation
import ZenithCore
import ZenithKit

/// Kosmos's state, pushed to Zenith's Mach port on every change and asked for over Kosmos's
/// socket at launch and after a wake, and the commands a click sends Kosmos. Nothing runs a
/// process (docs/overview.md).
final class KosmosLink: Sendable {
    static let portName = "io.github.st-eez.zenith"
    static let socketPath = NSHomeDirectory() + "/Library/Application Support/Kosmos/ipc.sock"

    private let queue = DispatchQueue(label: "zenith.kosmos", qos: .userInitiated)
    private let received: @Sendable (KosmosState) -> Void
    nonisolated(unsafe) private var source: DispatchSourceMachReceive?

    init(received: @escaping @Sendable (KosmosState) -> Void) {
        self.received = received
    }

    /// False when another process holds Zenith's port, as another Zenith does.
    func start() -> Bool {
        let port = zenith_mach_register(Self.portName)
        guard port != MACH_PORT_NULL else { return false }
        let source = DispatchSource.makeMachReceiveSource(port: port, queue: queue)
        source.setEventHandler { [self] in
            // Only the newest of the snapshots waiting matters, as each holds the whole state.
            var newest: Data?
            while true {
                var length: UInt32 = 0
                guard let bytes = zenith_mach_receive(port, &length) else { break }
                newest = Data(bytesNoCopy: bytes, count: Int(length), deallocator: .free)
            }
            if let newest, let state = KosmosState.decode(newest) { received(state) }
        }
        source.activate()
        self.source = source
        refresh()
        return true
    }

    /// Asks Kosmos for its state, as after a wake, when pushes may have been missed.
    func refresh() {
        queue.async { [self] in
            guard let reply = Self.request(["state"]) else { return log.notice("Kosmos did not answer state") }
            guard reply.exitCode == 0, let state = KosmosState.decode(Data(reply.stdout.utf8)) else {
                return log.error("Kosmos's state was not a version 1 snapshot: \(reply.stdout.prefix(200), privacy: .public)")
            }
            received(state)
        }
    }

    func send(_ args: [String]) {
        queue.async {
            let command = args.joined(separator: " ")
            guard let reply = Self.request(args) else { return log.notice("Kosmos did not answer \(command, privacy: .public)") }
            if reply.exitCode != 0 { log.notice("kosmos \(command, privacy: .public): \(reply.stderr, privacy: .public)") }
        }
    }

    private struct Reply: Decodable {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    /// One request on Kosmos's socket: a frame of a 4 byte big endian length and a JSON body
    /// each way (Kosmos's docs/ipc.md). Nil when Kosmos does not answer within 2 s.
    private static func request(_ args: [String]) -> Reply? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        // A Kosmos that quits or restarts mid-request closes its end; without this the write
        // raises SIGPIPE, which ends Zenith, as Kosmos's own client guards against.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.map { UInt8(bitPattern: $0) }) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0,
              let body = try? JSONSerialization.data(withJSONObject: ["args": args, "protocol": 1]) else { return nil }
        var length = UInt32(body.count).bigEndian
        guard write(fd, &length, 4) == 4, body.withUnsafeBytes({ write(fd, $0.baseAddress, body.count) }) == body.count,
              let header = read(fd, count: 4) else { return nil }
        let size = header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard size < 1 << 24, let reply = read(fd, count: Int(size)) else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: reply)
    }

    private static func read(_ fd: Int32, count: Int) -> Data? {
        var data = Data(count: count), done = 0
        while done < count {
            let got = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + done, count - done) }
            guard got > 0 else { return nil }
            done += got
        }
        return data
    }
}
