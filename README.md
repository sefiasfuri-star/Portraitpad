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

## Install the iPad app

1. In Xcode's toolbar, pick the **PortraitPad** scheme and choose your iPad as the device.
2. Press **Run** (the ▶ button).
3. The first time, the iPad says the developer isn't trusted: go to Settings > General >
   VPN & Device Management, tap your Apple ID, and tap **Trust**. Then press Run again.
4. When the iPad asks to find devices on your local network, tap **Allow**.

> With a free Apple ID, iPad apps installed from Xcode stop opening after 7 days. Just
> plug in and press Run again to renew. A paid developer account makes it last a year.

## Run the Mac app

1. Pick the **PortraitPadHost** scheme, with "My Mac" as the device, and press **Run**.
   An iPad icon appears in the menu bar.
2. Open PortraitPad on the iPad with the cable connected. The Mac asks for **Screen
   Recording** permission: allow it in System Settings > Privacy & Security > Screen &
   System Audio Recording, then quit PortraitPad Host from its menu and run it again.
3. The iPad now shows a new portrait screen. Use **Arrange Displays…** in the menu to put
   it to the left or right of your MacBook screen, the same as any monitor. macOS
   remembers the position.

To use it without Xcode afterwards: in Xcode choose Product > Show Build Folder in Finder,
open Products/Debug, and drag **PortraitPad Host** into your Applications folder.

## Menu options

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
