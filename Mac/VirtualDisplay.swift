import CoreGraphics
import Foundation

/// A portrait virtual screen that macOS treats like a real monitor. It exists while
/// this object is alive; releasing it makes macOS move windows back to other screens.
final class VirtualDisplay {
    let pixelWidth: Int
    let pixelHeight: Int
    private let display: CGVirtualDisplay

    var displayID: CGDirectDisplayID { display.displayID }

    init?(pixelWidth: Int, pixelHeight: Int, ppi: Double) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight

        // Retina layout: the default mode "looks like" half the iPad's pixels, rendered
        // at full resolution, so text in scores is as sharp as the iPad can show it.
        // The larger modes give "more space" and show up in System Settings > Displays.
        let baseW = pixelWidth / 2
        let baseH = pixelHeight / 2
        let scales: [Double] = [1.0, 0.85, 1.15, 1.3]
        let sizes = scales.map { s in (Self.even(Double(baseW) * s), Self.even(Double(baseH) * s)) }

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "PortraitPad"
        // Room for every mode at 2x, plus the iPad's own pixel count as a 1x mode.
        let maxW = sizes.map { $0.0 * 2 }.max() ?? pixelWidth
        let maxH = sizes.map { $0.1 * 2 }.max() ?? pixelHeight
        descriptor.maxPixelsWide = UInt32(max(maxW, pixelWidth))
        descriptor.maxPixelsHigh = UInt32(max(maxH, pixelHeight))
        let mmPerPixel = 25.4 / (ppi > 0 ? ppi : 264)
        descriptor.sizeInMillimeters = CGSize(width: Double(pixelWidth) * mmPerPixel,
                                              height: Double(pixelHeight) * mmPerPixel)
        // Fixed ids so macOS remembers where you placed the screen in Arrangement.
        descriptor.vendorID = 0x5050
        descriptor.productID = 0x0001
        descriptor.serialNum = UInt32(truncatingIfNeeded: pixelWidth &* 10_000 &+ pixelHeight)

        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }
        self.display = display

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        var modes = sizes.map { CGVirtualDisplayMode(width: $0.0, height: $0.1, refreshRate: 60) }
        modes.append(CGVirtualDisplayMode(width: pixelWidth, height: pixelHeight, refreshRate: 60))
        settings.modes = modes
        guard display.apply(settings) else { return nil }
    }

    /// Picks the Retina mode whose backing pixels match the iPad exactly. Only done the
    /// first time a given iPad size is seen, so a mode you choose later in System
    /// Settings sticks.
    func selectNativeModeIfFirstTime() {
        let key = "modeChosen-\(pixelWidth)x\(pixelHeight)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return }
        let matching = modes.filter { $0.pixelWidth == pixelWidth && $0.pixelHeight == pixelHeight }
        // Prefer the highest backing scale (pixels per point), i.e. the Retina mode.
        guard let best = matching.max(by: {
            Double($0.pixelWidth) / Double(max($0.width, 1)) < Double($1.pixelWidth) / Double(max($1.width, 1))
        }) else { return }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayWithDisplayMode(config, displayID, best, nil)
        if CGCompleteDisplayConfiguration(config, .permanently) == .success {
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    private static func even(_ v: Double) -> Int {
        Int((v / 2).rounded()) * 2
    }
}
