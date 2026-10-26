import Foundation
import Network

/// A reliable byte stream. Implemented over Network.framework (Wi-Fi, and the iPad's
/// listening side) and over a raw socket file descriptor (the Mac's usbmuxd tunnel).
protocol ByteTransport: AnyObject {
    /// Calls `onReady` once the stream can be used, `onClose` once when it ends.
    func start(onReady: @escaping () -> Void, onClose: @escaping () -> Void)
    /// Reads exactly `count` bytes. Calls back with nil when the stream ended.
    func receive(exactly count: Int, completion: @escaping (Data?) -> Void)
    func send(_ data: Data, completion: @escaping () -> Void)
    func cancel()
}

final class NWTransport: ByteTransport {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var closed = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start(onReady: @escaping () -> Void, onClose: @escaping () -> Void) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                onReady()
            case .failed, .cancelled, .waiting:
                if !self.closed {
                    self.closed = true
                    self.connection.cancel()
                    onClose()
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func receive(exactly count: Int, completion: @escaping (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            if let data, data.count == count, error == nil {
                completion(data)
            } else {
                completion(nil)
            }
        }
    }

    func send(_ data: Data, completion: @escaping () -> Void) {
        connection.send(content: data, completion: .contentProcessed { _ in completion() })
    }

    func cancel() {
        connection.cancel()
    }
}

/// Frames `PPMessage`s over a `ByteTransport`.
final class MessageChannel {
    var onReady: (() -> Void)?
    var onMessage: ((PPMessage, Data) -> Void)?
    var onClose: (() -> Void)?

    private let transport: ByteTransport
    private let lock = NSLock()
    private var _pendingSends = 0
    private var closed = false

    init(transport: ByteTransport) {
        self.transport = transport
    }

    /// Messages handed to `send` that the transport hasn't finished with yet.
    /// The Mac uses this to skip frames instead of queueing up latency on a slow link.
    var pendingSends: Int {
        lock.lock(); defer { lock.unlock() }
        return _pendingSends
    }

    func start() {
        transport.start(onReady: { [weak self] in
            self?.onReady?()
        }, onClose: { [weak self] in
            self?.handleClose()
        })
    }

    /// Starts delivering incoming messages to `onMessage`. Call once, after `onReady`.
    func startReceiving() {
        receiveHeader()
    }

    func send(_ type: PPMessage, _ payload: Data = Data()) {
        var w = ByteWriter()
        w.u8(type.rawValue)
        w.u32(UInt32(payload.count))
        w.bytes(payload)
        lock.lock(); _pendingSends += 1; lock.unlock()
        transport.send(w.data) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self._pendingSends -= 1; self.lock.unlock()
        }
    }

    func close() {
        transport.cancel()
        handleClose()
    }

    private func handleClose() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        if !wasClosed { onClose?() }
    }

    private func receiveHeader() {
        transport.receive(exactly: 5) { [weak self] data in
            guard let self else { return }
            guard let data else { return self.close() }
            var r = ByteReader(data)
            guard let rawType = r.u8(), let length = r.u32(), Int(length) <= PP.maxPayload else {
                return self.close()
            }
            if length == 0 {
                self.deliver(rawType, Data())
                self.receiveHeader()
            } else {
                self.receivePayload(rawType, Int(length))
            }
        }
    }

    private func receivePayload(_ rawType: UInt8, _ length: Int) {
        transport.receive(exactly: length) { [weak self] data in
            guard let self else { return }
            guard let data else { return self.close() }
            self.deliver(rawType, data)
            self.receiveHeader()
        }
    }

    private func deliver(_ rawType: UInt8, _ payload: Data) {
        // Unknown types are skipped so older builds keep working with newer ones.
        if let type = PPMessage(rawValue: rawType) {
            onMessage?(type, payload)
        }
    }
}
