import AppKit
import Foundation

/// Ties it together: when an iPad connects, create a matching portrait display, stream
/// it, and apply touches. Lives on the main queue.
final class HostController {
    var onStatusChange: ((String) -> Void)?
    private(set) var status = "Starting…" {
        didSet { onStatusChange?(status) }
    }

    var touchEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "touchEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "touchEnabled") }
    }

    var fps: Int {
        get { UserDefaults.standard.object(forKey: "fps") as? Int ?? 60 }
        set { UserDefaults.standard.set(newValue, forKey: "fps"); restartStream() }
    }

    /// Bits per second.
    var bitrate: Int {
        get { UserDefaults.standard.object(forKey: "bitrate") as? Int ?? 20_000_000 }
        set { UserDefaults.standard.set(newValue, forKey: "bitrate"); restartStream() }
    }

    var wifiEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "wifiEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "wifiEnabled"); connections.wifiEnabled = newValue }
    }

    private let connections = ConnectionManager()
    private let injector = InputInjector()
    private var channel: MessageChannel?
    private var route: ConnectionManager.Route = .usb
    private var hello: Hello?
    private var display: VirtualDisplay?
    private var displayRemoval: DispatchWorkItem?
    private var streamer: ScreenStreamer?

    func start() {
        connections.wifiEnabled = wifiEnabled
        connections.onConnected = { [weak self] channel, route in self?.attach(channel, route: route) }
        connections.onDisconnected = { [weak self] channel in self?.detach(channel) }
        connections.start()
        status = "Waiting for iPad — open PortraitPad on it"
    }

    func stop() {
        streamer?.stop()
        channel?.close()
        display = nil
    }

    private func attach(_ channel: MessageChannel, route: ConnectionManager.Route) {
        self.channel?.close()
        self.channel = channel
        self.route = route
        channel.onMessage = { [weak self] type, payload in
            DispatchQueue.main.async { self?.handle(type, payload) }
        }
        channel.startReceiving()
        status = "Connected via \(route.rawValue)…"
    }

    private func detach(_ channel: MessageChannel) {
        guard channel === self.channel else { return }
        self.channel = nil
        streamer?.stop()
        streamer = nil
        status = "Waiting for iPad — open PortraitPad on it"

        // Keep the screen around briefly so a quick reconnect doesn't shuffle windows.
        let removal = DispatchWorkItem { [weak self] in self?.display = nil }
        displayRemoval = removal
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: removal)
    }

    private func handle(_ type: PPMessage, _ payload: Data) {
        switch type {
        case .hello:
            guard let hello = try? JSONDecoder().decode(Hello.self, from: payload) else { return }
            self.hello = hello
            setUpDisplay(for: hello)
        case .pointer:
            guard touchEnabled else { return }
            var r = ByteReader(payload)
            guard let raw = r.u8(), let phase = PointerPhase(rawValue: raw),
                  let x = r.f32(), let y = r.f32() else { return }
            injector.pointer(phase, x: x, y: y)
        case .scroll:
            guard touchEnabled else { return }
            var r = ByteReader(payload)
            guard let x = r.f32(), let y = r.f32(), let dx = r.f32(), let dy = r.f32() else { return }
            injector.scroll(x: x, y: y, dx: dx, dy: dy)
        case .keyframeRequest:
            streamer?.requestKeyframe()
        case .format, .frame:
            break
        }
    }

    private func setUpDisplay(for hello: Hello) {
        displayRemoval?.cancel()
        displayRemoval = nil

        if let display, display.pixelWidth == hello.pixelWidth, display.pixelHeight == hello.pixelHeight {
            restartStream()
            return
        }

        display = nil
        guard let display = VirtualDisplay(pixelWidth: hello.pixelWidth, pixelHeight: hello.pixelHeight, ppi: hello.ppi) else {
            status = "Couldn't create the virtual display"
            return
        }
        self.display = display
        injector.displayID = display.displayID
        // Give macOS a moment to bring the new screen up before choosing its mode and capturing it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            display.selectNativeModeIfFirstTime()
            self?.restartStream()
        }
    }

    private func restartStream() {
        streamer?.stop()
        streamer = nil
        guard let channel, let display, let hello else { return }

        let streamer = ScreenStreamer()
        streamer.canSend = { [weak channel] in (channel?.pendingSends ?? .max) < 3 }
        streamer.onFormat = { [weak channel] data in channel?.send(.format, data) }
        streamer.onFrame = { [weak channel] data in channel?.send(.frame, data) }
        streamer.onStopped = { [weak self] error in
            DispatchQueue.main.async {
                self?.status = "Capture stopped: \(error?.localizedDescription ?? "unknown")"
            }
        }
        self.streamer = streamer
        injector.displayID = display.displayID

        let route = self.route
        let summary = "Streaming via \(route.rawValue) — \(hello.pixelWidth)×\(hello.pixelHeight) to \(hello.name)"
        Task { [weak self] in
            do {
                try await streamer.start(displayID: display.displayID, width: hello.pixelWidth,
                                         height: hello.pixelHeight, fps: self?.fps ?? 60,
                                         bitrate: self?.bitrate ?? 20_000_000)
                await MainActor.run {
                    // Settings may have changed while this was starting up.
                    if self?.streamer !== streamer { streamer.stop() } else { self?.status = summary }
                }
            } catch {
                await MainActor.run {
                    NSLog("PortraitPad capture failed: \(error)")
                    guard self?.streamer === streamer else { return }
                    self?.status = error is StreamerError
                        ? error.localizedDescription
                        : "Allow Screen Recording for PortraitPad Host (System Settings > Privacy & Security), then quit and reopen it"
                }
            }
        }
    }
}
