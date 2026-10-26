import AVFoundation
import CoreMedia
import Network
import UIKit

/// Listens for the Mac (over USB or Wi-Fi), decodes the H.264 stream into the video
/// view, and sends touches back.
final class Receiver: ObservableObject {
    @Published private(set) var streaming = false
    @Published private(set) var connected = false

    let videoView = VideoView()

    private let queue = DispatchQueue(label: "portraitpad.net", qos: .userInteractive)
    private var listener: NWListener?
    private var channel: MessageChannel?
    private var format: CMVideoFormatDescription?
    private let hello = Receiver.helloPayload()

    init() {
        videoView.onPointer = { [weak self] phase, point in
            var w = ByteWriter()
            w.u8(phase.rawValue)
            w.f32(Float(point.x))
            w.f32(Float(point.y))
            self?.send(.pointer, w.data)
        }
        videoView.onScroll = { [weak self] point, delta in
            var w = ByteWriter()
            w.f32(Float(point.x))
            w.f32(Float(point.y))
            w.f32(Float(delta.x))
            w.f32(Float(delta.y))
            self?.send(.scroll, w.data)
        }
    }

    /// Call when the app becomes active. iOS stops networking in the background.
    func start() {
        queue.async { self.startListener() }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.channel?.close()
            self.channel = nil
        }
    }

    private func startListener() {
        guard listener == nil else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true
        params.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: PP.port),
              let listener = try? NWListener(using: params, on: port) else { return retryListener() }

        listener.service = NWListener.Service(name: UIDevice.current.name, type: PP.bonjourType)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.retryListener() }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func retryListener() {
        listener?.cancel()
        listener = nil
        queue.asyncAfter(deadline: .now() + 1) { self.startListener() }
    }

    private func accept(_ connection: NWConnection) {
        // One Mac at a time; a new connection replaces the old one.
        channel?.close()
        format = nil
        let channel = MessageChannel(transport: NWTransport(connection: connection, queue: queue))
        self.channel = channel

        channel.onReady = { [weak self, weak channel] in
            guard let self, let channel else { return }
            channel.onMessage = { [weak self] type, payload in self?.handle(type, payload) }
            channel.startReceiving()
            channel.send(.hello, self.hello)
            DispatchQueue.main.async {
                self.videoView.flush()
                self.connected = true
            }
        }
        channel.onClose = { [weak self, weak channel] in
            guard let self, let channel, channel === self.channel else { return }
            self.channel = nil
            DispatchQueue.main.async {
                self.connected = false
                self.streaming = false
            }
        }
        channel.start()
    }

    private func send(_ type: PPMessage, _ payload: Data) {
        queue.async { self.channel?.send(type, payload) }
    }

    /// Read on the main thread (UIScreen is main-thread only).
    private static func helloPayload() -> Data {
        // `nativeBounds` is always in portrait-up orientation.
        let size = UIScreen.main.nativeBounds.size
        let hello = Hello(pixelWidth: Int(size.width), pixelHeight: Int(size.height),
                          ppi: 264, name: UIDevice.current.name)
        return (try? JSONEncoder().encode(hello)) ?? Data()
    }

    // MARK: Video

    private func handle(_ type: PPMessage, _ payload: Data) {
        switch type {
        case .format:
            format = Self.makeFormat(payload)
            if let format {
                let dimensions = CMVideoFormatDescriptionGetDimensions(format)
                let size = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
                DispatchQueue.main.async { self.videoView.videoSize = size }
            }
        case .frame:
            guard let format, let sample = Self.makeSample(payload, format: format) else { return }
            if !videoView.enqueue(sample) {
                channel?.send(.keyframeRequest)
            }
            if !streaming {
                DispatchQueue.main.async { self.streaming = true }
            }
        default:
            break
        }
    }

    private static func makeFormat(_ payload: Data) -> CMVideoFormatDescription? {
        var r = ByteReader(payload)
        guard let count = r.u8(), count > 0 else { return nil }
        var sets: [Data] = []
        for _ in 0..<count {
            guard let length = r.u16(), let bytes = r.bytes(Int(length)) else { return nil }
            sets.append(bytes)
        }

        // CoreMedia wants C pointers to every parameter set at once.
        let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: p, count: set.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)

        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
            parameterSetPointers: pointers, parameterSetSizes: sizes,
            nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        return status == noErr ? format : nil
    }

    private static func makeSample(_ payload: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        // payload[0] is the keyframe flag; the rest is the AVCC access unit.
        let length = payload.count - 1
        guard length > 0 else { return nil }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: length, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = payload.withUnsafeBytes { raw -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!.advanced(by: 1), blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == noErr else { return nil }

        var sample: CMSampleBuffer?
        var sampleSize = length
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }

        // No clock: show each frame the moment it's decoded.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
