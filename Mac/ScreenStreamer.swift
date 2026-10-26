import CoreMedia
import Foundation
import QuartzCore
import ScreenCaptureKit
import VideoToolbox

enum StreamerError: LocalizedError {
    case displayNotFound
    case encoderFailed

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "The virtual display didn't appear."
        case .encoderFailed: return "Couldn't start the video encoder."
        }
    }
}

/// Captures one display with ScreenCaptureKit and encodes it to H.264 with the
/// hardware encoder. ScreenCaptureKit only delivers a frame when something on the
/// screen changed, so a still score costs almost nothing.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    /// H.264 parameter sets payload (see `PPMessage.format`).
    var onFormat: ((Data) -> Void)?
    /// Frame payload (see `PPMessage.frame`).
    var onFrame: ((Data) -> Void)?
    /// Returns false while the link is backed up; frames are skipped instead of queued.
    var canSend: () -> Bool = { true }
    var onStopped: ((Error?) -> Void)?

    private let queue = DispatchQueue(label: "portraitpad.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var encoder: VideoEncoder?
    private var lastBuffer: CVPixelBuffer?
    private var forceKeyframe = true
    private var refineWork: DispatchWorkItem?

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int, bitrate: Int) async throws {
        var scDisplay: SCDisplay?
        // A freshly created virtual display can take a moment to become shareable.
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            scDisplay = content.displays.first { $0.displayID == displayID }
            if scDisplay != nil { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let scDisplay else { throw StreamerError.displayNotFound }

        guard let encoder = VideoEncoder(width: width, height: height, fps: fps, bitrate: bitrate) else {
            throw StreamerError.encoderFailed
        }
        encoder.onOutput = { [weak self] sample in self?.handleEncoded(sample) }

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.queueDepth = 5

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        queue.sync {
            self.encoder = encoder
            self.forceKeyframe = true
        }
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() {
        let stream = self.stream
        self.stream = nil
        stream?.stopCapture { _ in }
        queue.async {
            self.refineWork?.cancel()
            self.encoder?.invalidate()
            self.encoder = nil
            self.lastBuffer = nil
        }
    }

    func requestKeyframe() {
        queue.async {
            self.forceKeyframe = true
            self.encodeLast()
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lastBuffer = pixelBuffer
        if canSend() {
            encode(pixelBuffer)
        }
        scheduleRefine()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error)
    }

    // MARK: Encoding

    /// Live frames are tuned for speed. Once the screen has been still for a moment we
    /// send the last frame again as a keyframe, so text ends up crisp. This also covers
    /// any frames that were skipped while the link was busy.
    private func scheduleRefine() {
        refineWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.forceKeyframe = true
            self.encodeLast()
        }
        refineWork = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func encodeLast() {
        guard let lastBuffer else { return }
        if canSend() {
            encode(lastBuffer)
        } else {
            scheduleRefine()
        }
    }

    private func encode(_ pixelBuffer: CVPixelBuffer) {
        guard let encoder else { return }
        encoder.encode(pixelBuffer, forceKeyframe: forceKeyframe)
        forceKeyframe = false
    }

    private func handleEncoded(_ sample: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sample),
           let parameterSets = Self.parameterSets(format) {
            onFormat?(parameterSets)
        }

        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var payload = Data(count: length + 1)
        payload[0] = isKeyframe ? 1 : 0
        let status = payload.withUnsafeMutableBytes { raw -> OSStatus in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                       destination: raw.baseAddress!.advanced(by: 1))
        }
        guard status == noErr else { return }
        onFrame?(payload)
    }

    private static func parameterSets(_ format: CMFormatDescription) -> Data? {
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr else { return nil }

        var w = ByteWriter()
        w.u8(UInt8(count))
        for i in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
            w.u16(UInt16(size))
            w.bytes(Data(bytes: pointer, count: size))
        }
        return w.data
    }
}

/// Hardware H.264 encoder set up for low latency: no B-frames, real-time mode.
final class VideoEncoder {
    var onOutput: ((CMSampleBuffer) -> Void)?
    private var session: VTCompressionSession?

    init?(width: Int, height: Int, fps: Int, bitrate: Int) {
        let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { return nil }
        self.session = session

        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(session, key: key, value: value)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        // Keyframes are sent on demand (connect, stillness, errors), not on a timer.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 3600 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit { invalidate() }

    func encode(_ pixelBuffer: CVPixelBuffer, forceKeyframe: Bool) {
        guard let session else { return }
        // Timestamps only need to increase; capture is driven by screen changes.
        let pts = CMTime(value: Int64(CACurrentMediaTime() * 1_000_000), timescale: 1_000_000)
        let properties = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard status == noErr, let sample else { return }
            self?.onOutput?(sample)
        }
    }

    func invalidate() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }
}
