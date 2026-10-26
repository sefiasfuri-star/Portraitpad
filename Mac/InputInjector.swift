import ApplicationServices
import CoreGraphics
import Foundation

/// Turns iPad touches into mouse clicks, drags and scrolls on the virtual display.
/// Needs the Accessibility permission (System Settings > Privacy & Security).
final class InputInjector {
    var displayID: CGDirectDisplayID = 0

    private var lastClickTime: TimeInterval = 0
    private var lastClickPoint = CGPoint.zero
    private var clickCount: Int64 = 1

    /// Shows the macOS permission prompt if needed. Returns true if already allowed.
    @discardableResult
    static func requestPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static var hasPermission: Bool { AXIsProcessTrusted() }

    func pointer(_ phase: PointerPhase, x: Float, y: Float) {
        let p = point(x, y)
        switch phase {
        case .down:
            let now = ProcessInfo.processInfo.systemUptime
            let near = hypot(p.x - lastClickPoint.x, p.y - lastClickPoint.y) < 12
            clickCount = (now - lastClickTime < 0.4 && near) ? min(clickCount + 1, 3) : 1
            lastClickTime = now
            lastClickPoint = p
            post(.mouseMoved, at: p, button: .left)
            post(.leftMouseDown, at: p, button: .left, clicks: clickCount)
        case .drag:
            post(.leftMouseDragged, at: p, button: .left, clicks: clickCount)
        case .up:
            post(.leftMouseUp, at: p, button: .left, clicks: clickCount)
        case .rightClick:
            post(.mouseMoved, at: p, button: .left)
            post(.rightMouseDown, at: p, button: .right)
            post(.rightMouseUp, at: p, button: .right)
        }
    }

    func scroll(x: Float, y: Float, dx: Float, dy: Float) {
        let p = point(x, y)
        // Scroll goes to whatever is under the pointer, so put the pointer there first.
        post(.mouseMoved, at: p, button: .left)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
        event.location = p
        event.post(tap: .cghidEventTap)
    }

    private func point(_ x: Float, _ y: Float) -> CGPoint {
        let bounds = CGDisplayBounds(displayID)
        let cx = min(max(CGFloat(x), 0), 1)
        let cy = min(max(CGFloat(y), 0), 1)
        return CGPoint(x: bounds.minX + cx * (bounds.width - 1), y: bounds.minY + cy * (bounds.height - 1))
    }

    private func post(_ type: CGEventType, at p: CGPoint, button: CGMouseButton, clicks: Int64 = 1) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button) else {
            return
        }
        event.setIntegerValueField(.mouseEventClickState, value: clicks)
        event.post(tap: .cghidEventTap)
    }
}
