# PortraitPad

Use an iPad as a **portrait** second screen for your Mac, for free. Built for reading
scores and running Cubase on the side while recording.

- **PortraitPad Host** (Mac, menu bar): creates a virtual portrait display that matches
  your iPad, captures it, and streams it with the Mac's hardware video encoder. Nothing is
  sent while the screen is still, so CPU use stays low while you record.
- **PortraitPad** (iPad): shows that display full screen. Optional touch control: tap to
  click, drag to drag, two fingers to scroll, two-finger tap to right-click.

It connects over the **USB cable** (preferred, lowest latency) or over **Wi-Fi**.

## What you need

- A Mac with macOS 13 Ventura or newer and **Xcode** (free, from the Mac App Store).
- An iPad with iPadOS 16 or newer and a USB cable.
- Your Apple ID. A free account works; see the 7-day note below.

## One-time setup

1. **Install Homebrew and XcodeGen.** Open the Terminal app and paste:

   ```sh
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   brew install xcodegen
   ```

2. **Get the code and make the Xcode project.** In Terminal:

   ```sh
   cd ~/Documents
   git clone https://github.com/sefiasfuri-star/Portraitpad.git
   cd Portraitpad
   xcodegen
   open PortraitPad.xcodeproj
   ```

3. **Sign in Xcode.** Xcode > Settings > Accounts > "+" > Apple ID.
   Then click the blue **PortraitPad** project at the top left, and for **each** of the two
   targets (PortraitPadHost and PortraitPad) open **Signing & Capabilities** and choose your
   name under **Team**.

4. **Turn on Developer Mode on the iPad** (first time only): plug the iPad into the Mac,
   then on the iPad go to Settings > Privacy & Security > Developer Mode, switch it on, and
   restart when asked.

## Install both apps (no Xcode window needed)

Plug the iPad in with the cable and unlock it, then in Finder open the `Portraitpad` folder
and double-click **Install or Update.command**. It builds both apps, puts **PortraitPad
Host** in Applications (set to open at login), and installs the iPad app.

The first time only:
- On the iPad, trust your developer certificate: Settings > General > VPN & Device
  Management > your Apple ID > Trust. Turn on Developer Mode if the iPad asks.
- On the Mac, allow **Screen Recording** for PortraitPad Host (System Settings > Privacy &
  Security > Screen & System Audio Recording), then quit it from its menu and open it again
  from Applications.

## Everyday use

1. Plug the iPad in and open **PortraitPad** on it.
2. That's it. PortraitPad Host is already running in the menu bar, and the screen appears.

When you unplug, macOS moves the windows back after a few seconds. Nothing else runs in the
background while the iPad isn't connected, apart from a check for the cable every two seconds.

**Every 7 days** (free Apple ID): if the iPad app won't open, plug in and double-click
**Refresh iPad.command**. It takes about a minute.

To arrange the screen next to your MacBook, use **Arrange Displays…** in the menu. macOS
remembers the position.

## Menu options

- **Open at Login**: on by default for the copy in Applications.
- **Control Mac from iPad touches**: off by default. Turning it on asks for the
  Accessibility permission (System Settings > Privacy & Security > Accessibility).
- **Orientation**: Portrait (default) or Landscape. The Mac rebuilds the screen in the new
  shape within a second or two; turn the iPad to match and the picture follows it.
- **Use Wi-Fi when no cable is connected**: on by default. The cable is always preferred.
- **Frame rate**: 60 fps is smoother, 30 fps uses a bit less power.
- **Quality**: High is the default. Use Best over USB for the sharpest moving image.
  When the screen stops changing, a full-quality frame is sent anyway, so still scores
  are always sharp.
- **Larger text or more space**: System Settings > Displays > PortraitPad, like any monitor.

## Troubleshooting

- **iPad stays on "Waiting for your Mac"**: make sure PortraitPad Host is running (menu
  bar icon), the iPad app is open in front, and the cable is connected. Unplug and
  replug, or try Wi-Fi with both on the same network.
- **Screen is black on the iPad**: Screen Recording permission is missing. Check the menu
  bar status line; it says what's wrong.
- **After rebuilding, macOS asks for permissions again**: normal for apps built from
  Xcode. Allow them again.

## How it works

The Mac app uses Apple's private `CGVirtualDisplay` API (the same one DeskPad and
BetterDisplay use) to create the screen, ScreenCaptureKit to capture it, and VideoToolbox to
encode H.264 in hardware. Over USB it talks to the iPad through `usbmuxd`, the service
Xcode and Finder use, so no network is involved. The iPad decodes with
`AVSampleBufferDisplayLayer`.
