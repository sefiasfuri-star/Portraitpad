import Darwin
import Foundation

/// Talks to usbmuxd, the macOS service that Finder and Xcode use to reach iPhones and
/// iPads over the cable. It can open a TCP connection to a port on the iPad, tunnelled
/// through USB, with no network involved.
enum USBMux {
    private static let socketPath = "/var/run/usbmuxd"

    /// Device ids of iPads/iPhones currently attached by USB. Blocking.
    static func usbDeviceIDs() -> [Int] {
        guard let fd = openSocket() else { return [] }
        defer { close(fd) }
        guard send(fd, ["MessageType": "ListDevices"]),
              let reply = receive(fd),
              let list = reply["DeviceList"] as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let props = entry["Properties"] as? [String: Any],
                  props["ConnectionType"] as? String == "USB" else { return nil }
            return (props["DeviceID"] as? Int) ?? (entry["DeviceID"] as? Int)
        }
    }

    /// Opens a tunnel to `port` on the device. Returns a connected socket, or nil if
    /// nothing is listening there (for example the iPad app isn't open). Blocking.
    static func connect(deviceID: Int, port: UInt16) -> Int32? {
        guard let fd = openSocket() else { return nil }
        let message: [String: Any] = [
            "MessageType": "Connect",
            "DeviceID": deviceID,
            // usbmuxd wants the port in network byte order.
            "PortNumber": Int(port.bigEndian),
        ]
        guard send(fd, message),
              let reply = receive(fd),
              reply["Number"] as? Int == 0 else {
            close(fd)
            return nil
        }
        // From here on the socket is a raw byte pipe to the iPad. Clear the handshake timeout.
        var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private static func openSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            for (i, byte) in pathBytes.prefix(buffer.count - 1).enumerated() {
                buffer[i] = byte
            }
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// usbmuxd packet: 16-byte little-endian header (length, version 1, type 8 = plist,
    /// tag) followed by an XML property list.
    private static func send(_ fd: Int32, _ message: [String: Any]) -> Bool {
        var body = message
        body["ClientVersionString"] = "PortraitPad"
        body["ProgName"] = "PortraitPad"
        guard let plist = try? PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0) else {
            return false
        }
        var packet = Data()
        for field in [UInt32(16 + plist.count), 1, 8, 1] {
            var le = field.littleEndian
            withUnsafeBytes(of: &le) { packet.append(contentsOf: $0) }
        }
        packet.append(plist)
        return writeAll(fd, packet)
    }

    private static func receive(_ fd: Int32) -> [String: Any]? {
        guard let header = readExactly(fd, 16) else { return nil }
        let length = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard length >= 16, length < 1_000_000, let body = readExactly(fd, Int(length) - 16) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: body, format: nil)) as? [String: Any]
    }

    static func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        var offset = 0
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return count == 0 }
            while offset < count {
                let n = read(fd, base.advanced(by: offset), count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        return ok ? data : nil
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base.advanced(by: offset), raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}

/// `ByteTransport` over a connected socket (the usbmuxd tunnel). Reads run on their own
/// thread so a blocking read never holds up sending.
final class FDTransport: ByteTransport {
    private let fd: Int32
    private let readQueue = DispatchQueue(label: "portraitpad.usb.read")
    private let writeQueue = DispatchQueue(label: "portraitpad.usb.write")
    private let callbackQueue: DispatchQueue
    private let lock = NSLock()
    private var closed = false
    private var onClose: (() -> Void)?

    init(fd: Int32, callbackQueue: DispatchQueue) {
        self.fd = fd
        self.callbackQueue = callbackQueue
    }

    func start(onReady: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onClose = onClose
        callbackQueue.async(execute: onReady)
    }

    func receive(exactly count: Int, completion: @escaping (Data?) -> Void) {
        readQueue.async { [self] in
            let data = isClosed ? nil : USBMux.readExactly(fd, count)
            if data == nil { shutDown() }
            callbackQueue.async { completion(data) }
        }
    }

    func send(_ data: Data, completion: @escaping () -> Void) {
        writeQueue.async { [self] in
            if !isClosed && !USBMux.writeAll(fd, data) { shutDown() }
            callbackQueue.async(execute: completion)
        }
    }

    func cancel() {
        shutDown()
    }

    private var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    private func shutDown() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        guard !wasClosed else { return }
        // Unblocks a pending read; the descriptor is closed once both queues are idle.
        Darwin.shutdown(fd, SHUT_RDWR)
        readQueue.async { [fd, writeQueue] in
            writeQueue.async { close(fd) }
        }
        if let onClose { callbackQueue.async(execute: onClose) }
    }
}
