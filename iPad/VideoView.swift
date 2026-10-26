import AVFoundation
import UIKit

/// Shows the decoded Mac screen and turns gestures into pointer events:
/// tap = click, drag = click-and-drag, two-finger drag = scroll, two-finger tap = right-click.
final class VideoView: UIView {
    /// Positions are normalized 0...1 within the picture.
    var onPointer: ((PointerPhase, CGPoint) -> Void)?
    var onScroll: ((CGPoint, CGPoint) -> Void)?

    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    /// Grabbed once on the main thread, so frames can be enqueued from the network
    /// queue without touching the UIView.
    private var videoLayer: AVSampleBufferDisplayLayer!

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        videoLayer = layer as? AVSampleBufferDisplayLayer
        videoLayer.videoGravity = .resizeAspect
        backgroundColor = .black
        isMultipleTouchEnabled = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let rightTap = UITapGestureRecognizer(target: self, action: #selector(handleRightTap(_:)))
        rightTap.numberOfTouchesRequired = 2
        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        drag.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        let recognizers: [UIGestureRecognizer] = [tap, rightTap, drag, scroll]
        recognizers.forEach(addGestureRecognizer)
    }

    /// Returns false if the decoder failed and needs a fresh keyframe.
    func enqueue(_ sample: CMSampleBuffer) -> Bool {
        if videoLayer.status == .failed {
            videoLayer.flush()
            return false
        }
        videoLayer.enqueue(sample)
        return true
    }

    func flush() {
        videoLayer.flush()
    }

    // MARK: Gestures

    private var scrollLast = CGPoint.zero

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let p = normalized(g.location(in: self))
        onPointer?(.down, p)
        onPointer?(.up, p)
    }

    @objc private func handleRightTap(_ g: UITapGestureRecognizer) {
        onPointer?(.rightClick, normalized(g.location(in: self)))
    }

    @objc private func handleDrag(_ g: UIPanGestureRecognizer) {
        let location = g.location(in: self)
        switch g.state {
        case .began:
            // Press where the finger first landed, not where the pan was recognized.
            let t = g.translation(in: self)
            onPointer?(.down, normalized(CGPoint(x: location.x - t.x, y: location.y - t.y)))
            onPointer?(.drag, normalized(location))
        case .changed:
            onPointer?(.drag, normalized(location))
        case .ended, .cancelled, .failed:
            onPointer?(.up, normalized(location))
        default:
            break
        }
    }

    @objc private func handleScroll(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        switch g.state {
        case .began:
            scrollLast = t
        case .changed:
            let delta = CGPoint(x: t.x - scrollLast.x, y: t.y - scrollLast.y)
            scrollLast = t
            onScroll?(normalized(g.location(in: self)), delta)
        default:
            break
        }
    }

    /// Maps a point in the view to 0...1 within the (aspect-fit) picture.
    private func normalized(_ p: CGPoint) -> CGPoint {
        let native = UIScreen.main.nativeBounds.size
        let rect = AVMakeRect(aspectRatio: native, insideRect: bounds)
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return CGPoint(x: min(max((p.x - rect.minX) / rect.width, 0), 1),
                       y: min(max((p.y - rect.minY) / rect.height, 0), 1))
    }
}
