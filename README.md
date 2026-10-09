# TxD xDrip

A stripped-down front end over the [xDrip4iOS](https://github.com/JohanDegraeve/xdripswift) engine
that does one job: read a **Dexcom Stelo / G7 / ONE+** sensor over Bluetooth in real time and write
every reading to **Apple Health** immediately, so apps that read Apple Health — specifically
[Food Health TxD](https://www.aifoodlogios.com) — see glucose within minutes instead of the ~3-hour
delay of the vendor app's Health export.

The full xDrip4iOS interface is still there behind the **Advanced** button; the engine (Bluetooth
transmitters, Core Data, HealthKit writer) is unmodified apart from two internal wrappers.

## What it does
1. Sets the defaults a bridge needs: Master mode, mg/dL, Apple Health write on.
2. Asks for the Apple Health permission (Blood Glucose, write).
3. Adds "Dexcom G7/ONE+/Stelo" in **Coexistence** mode — the vendor app keeps owning the sensor;
   this app only listens to the same Bluetooth session. No pairing code, nothing changes in the
   Stelo app.
4. Shows a status page: connection, last reading, readings in 24 h, last Apple Health write.

Readings arrive every ~5 minutes with backfill. The app listens in the background
(`bluetooth-central`, CoreBluetooth state restoration); keep it installed and don't force-quit the
Stelo app.

## Build
Requires Xcode (tested with Xcode 27). Create `xDripConfigOverride.xcconfig` at the repo root:

    XDRIP_DEVELOPMENT_TEAM = <your Apple team id>
    MAIN_APP_DISPLAY_NAME = TxD xDrip

Then either open `xdrip.xcodeproj`, scheme `xdrip`, and Run on your iPhone, or:

    xcodebuild -project xdrip.xcodeproj -scheme xdrip -configuration Release -destination 'generic/platform=iOS' \
      -derivedDataPath "$PWD/build/DerivedData" SYMROOT="$PWD/build/Products" OBJROOT="$PWD/build/Intermediates" \
      -allowProvisioningUpdates build
    xcrun devicectl device install app --device <UDID> build/Products/Release-iphoneos/xdrip.app

(`SYMROOT`/`OBJROOT` are required: the upstream project leaves them empty.)

## Code
- `xDrip/TxD/TxDBridgeModel.swift` — defaults, Health authorization, add-device in coexistence,
  status polling.
- `xDrip/TxD/TxDSimpleRootView.swift` — the wizard (Start → Apple Health → Connect → Status).
- `xDrip/Application Delegate/XdripApp.swift` — root view swapped to the wizard.
- `xDrip/SwiftUIViews/BluetoothPeripherals/BluetoothPeripheralDetailState.swift` — two internal
  wrappers at the end of the file (`txdBeginScan`, `txdSetTransmitterId`).

## Sensors
- Dexcom Stelo, G7, ONE+: supported (direct Bluetooth, coexistence or primary).
- Abbott Lingo / Libre 3: not supported for direct reading (encrypted Bluetooth); xDrip4iOS only
  gets Libre 3 data through the LibreLinkUp cloud follower, which Lingo does not offer. Lingo users
  stay on the Apple Health path (delayed).

## Status and disclaimer
Experimental, community software, not a medical device. Not for treatment decisions. See the
upstream project's notes in `README-xdrip4ios-upstream.md`.

## License
GPL-3.0, same as xDrip4iOS. Upstream: https://github.com/JohanDegraeve/xdripswift
