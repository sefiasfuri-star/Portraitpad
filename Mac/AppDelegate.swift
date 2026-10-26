import AppKit

@main
enum PortraitPadHostMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let host = HostController()
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "ipad", accessibilityDescription: "PortraitPad") {
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "PortraitPad"
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        host.onStatusChange = { [weak self] text in
            self?.statusLine.title = text
            // Dimmed icon while not streaming.
            self?.statusItem.button?.appearsDisabled = !text.hasPrefix("Streaming")
        }
        host.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        host.stop()
    }

    // Rebuilt every time it opens so checkmarks are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        statusLine.isEnabled = false
        statusLine.title = host.status
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let touch = item("Control Mac from iPad touches", #selector(toggleTouch))
        touch.state = host.touchEnabled ? .on : .off
        menu.addItem(touch)

        let wifi = item("Use Wi-Fi when no cable is connected", #selector(toggleWifi))
        wifi.state = host.wifiEnabled ? .on : .off
        menu.addItem(wifi)

        let fpsMenu = NSMenu()
        for fps in [30, 60] {
            let i = item("\(fps) fps", #selector(setFPS(_:)))
            i.tag = fps
            i.state = host.fps == fps ? .on : .off
            fpsMenu.addItem(i)
        }
        let fpsItem = NSMenuItem(title: "Frame rate", action: nil, keyEquivalent: "")
        fpsItem.submenu = fpsMenu
        menu.addItem(fpsItem)

        let qualityMenu = NSMenu()
        for (name, rate) in [("Normal", 12_000_000), ("High", 20_000_000), ("Best (USB)", 40_000_000)] {
            let i = item(name, #selector(setBitrate(_:)))
            i.tag = rate
            i.state = host.bitrate == rate ? .on : .off
            qualityMenu.addItem(i)
        }
        let qualityItem = NSMenuItem(title: "Quality", action: nil, keyEquivalent: "")
        qualityItem.submenu = qualityMenu
        menu.addItem(qualityItem)

        menu.addItem(.separator())
        menu.addItem(item("Arrange Displays…", #selector(openDisplaySettings)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit PortraitPad Host", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func toggleTouch() {
        host.touchEnabled.toggle()
        if host.touchEnabled && !InputInjector.hasPermission {
            InputInjector.requestPermission()
        }
    }

    @objc private func toggleWifi() {
        host.wifiEnabled.toggle()
    }

    @objc private func setFPS(_ sender: NSMenuItem) {
        host.fps = sender.tag
    }

    @objc private func setBitrate(_ sender: NSMenuItem) {
        host.bitrate = sender.tag
    }

    @objc private func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
