import Foundation
import Network

/// Finds the iPad and opens a `MessageChannel` to it. Prefers the USB cable; falls back
/// to Wi-Fi (Bonjour, including direct peer-to-peer Wi-Fi) when allowed.
final class ConnectionManager {
    enum Route: String {
        case usb = "USB"
        case wifi = "Wi-Fi"
    }

    /// Called on the main queue with a channel that is open. Set its `onMessage`, then
    /// call `startReceiving()`.
    var onConnected: ((MessageChannel, Route) -> Void)?
    /// Called on the main queue when a channel passed to `onConnected` closes.
    var onDisconnected: ((MessageChannel) -> Void)?
    var wifiEnabled = true

    private let queue = DispatchQueue(label: "portraitpad.connect")
    private var browser: NWBrowser?
    private var wifiEndpoints: [NWEndpoint] = []
    private var timer: DispatchSourceTimer?
    private var busy = false // connecting or connected; touched only on `queue`

    func start() {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: PP.bonjourType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.wifiEndpoints = results.map(\.endpoint)
        }
        browser.start(queue: queue)
        self.browser = browser

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2.0)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard !busy else { return }
        busy = true

        for deviceID in USBMux.usbDeviceIDs() {
            if let fd = USBMux.connect(deviceID: deviceID, port: PP.port) {
                open(MessageChannel(transport: FDTransport(fd: fd, callbackQueue: queue)), route: .usb)
                return
            }
        }

        if wifiEnabled, let endpoint = wifiEndpoints.first {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcp)
            params.includePeerToPeer = true
            let connection = NWConnection(to: endpoint, using: params)
            open(MessageChannel(transport: NWTransport(connection: connection, queue: queue)), route: .wifi)
            return
        }

        busy = false
    }

    private func open(_ channel: MessageChannel, route: Route) {
        var didOpen = false
        channel.onReady = { [weak self] in
            didOpen = true
            DispatchQueue.main.async { self?.onConnected?(channel, route) }
        }
        channel.onClose = { [weak self] in
            guard let self else { return }
            self.queue.async { self.busy = false }
            if didOpen {
                DispatchQueue.main.async { self.onDisconnected?(channel) }
            }
        }
        channel.start()
    }
}
