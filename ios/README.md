# RinaBoard iOS app

Open `RinaBoard.xcodeproj` in Xcode 16+ (or run the command below) and build
the `RinaBoard` scheme for an iOS 17+ simulator or device.

```sh
cd ios
xcodebuild -project RinaBoard.xcodeproj -scheme RinaBoard \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Sources under `RinaBoard/` are added automatically via a filesystem-synchronized
group; drop new Swift files or resources into the right subfolder and Xcode
picks them up on the next build. `Packages/RinaCore` is a local Swift package
(`swift test` from that directory runs its unit tests) providing the
transport-agnostic RinaLink protocol codec and models.

On-device: real Bluetooth/Wi-Fi/hotspot connectivity requires a physical
iPhone/iPad; the simulator can still exercise the UI and TCP paths against a
board on the same network.
