import SwiftUI
import UIKit

@main
struct PortraitPadApp: App {
    @StateObject private var receiver = Receiver()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(receiver: receiver)
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        UIApplication.shared.isIdleTimerDisabled = true // keep the screen on
                        receiver.start()
                    case .background:
                        UIApplication.shared.isIdleTimerDisabled = false
                        receiver.stop()
                    default:
                        break
                    }
                }
        }
    }
}

struct ContentView: View {
    @ObservedObject var receiver: Receiver

    var body: some View {
        ZStack {
            VideoContainer(view: receiver.videoView)
            if !receiver.streaming {
                VStack(spacing: 16) {
                    Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                        .font(.system(size: 64, weight: .light))
                    Text(receiver.connected ? "Connected, starting…" : "Waiting for your Mac")
                        .font(.title2.weight(.semibold))
                    Text("Open PortraitPad Host on the Mac, then connect the USB cable or use the same Wi-Fi.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 420)
                }
                .foregroundStyle(.white)
                .padding()
                .allowsHitTesting(false)
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { receiver.start() }
    }
}

private struct VideoContainer: UIViewRepresentable {
    let view: VideoView
    func makeUIView(context: Context) -> VideoView { view }
    func updateUIView(_ uiView: VideoView, context: Context) {}
}
