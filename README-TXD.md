# TxD xDrip (Android)

A stripped-down front end over the [xDrip+](https://github.com/NightscoutFoundation/xDrip) engine
that does one job: get **Dexcom Stelo / G7 / ONE+** readings into **Health Connect** within minutes,
so apps that read Health Connect — specifically Food Health TxD — see glucose in near real time
instead of the ~3-hour delay of the vendor app's Health Connect export.

Android twin of the iOS `TxD-xDrip` fork (xDrip4iOS). Free app, GPL-3.0 like upstream.
Package `com.foodhealth.txd.xdrip`, app name "TxD xDrip". The full xDrip+ interface is still
there behind **Advanced**; the engine is unmodified apart from the items listed under "Code".

## What the wizard does
1. Sets the defaults a bridge needs: mg/dL, Health Connect send on.
2. Asks for the Health Connect permission (Blood glucose read + write only).
3. Picks a glucose source:
   - **Companion app (recommended)** — the Stelo/G7 app keeps the sensor; TxD xDrip reads each
     reading from that app's notifications (xDrip+ "UI based collector"). Needs *notification
     access* for TxD xDrip and Stelo notifications turned on. This is the Android equivalent of
     iOS coexistence: on Android only one app can hold the sensor's Bluetooth connection.
   - **Direct Bluetooth (advanced)** — xDrip+ owns the sensor (G7 source, 4-digit pairing code
     from the applicator). The Stelo app must be uninstalled first (xDrip+ docs).
4. Status page: source, connection, last reading, readings in 24 h, Health Connect state,
   glucose chart (3/6/12/24 h, 70–180 band).

## Code (our changes vs upstream `master` d6807f7)
- `app/src/main/java/com/eveningoutpost/dexdrip/txd/TxdBridge.kt` — defaults, Health Connect
  permission, source setup (companion / direct), status queries.
- `app/src/main/java/com/eveningoutpost/dexdrip/txd/TxdWizardActivity.kt` + `TxdChartView.kt`,
  `res/layout/activity_txd_wizard.xml`, `res/values/txd.xml`, `res/drawable/txd_*.xml` — the wizard.
- `AndroidManifest.xml` — launcher moved from `Home` to `TxdWizardActivity`; every component with an
  intent-filter now declares `android:exported` (required by targetSdk ≥ 31).
- `app/build.gradle` — applicationId `com.foodhealth.txd.xdrip`, **targetSdkVersion 36** (Play
  requires API 36 for new apps; upstream ships 26), versionCode `1`, versionName `1.0.0`
  (Play rejects a first upload with a huge versionCode), release signing from `TXDXDRIP_RELEASE_*` env vars, wear micro-app embed removed.
- `healthconnect/HealthGamut.java` — `minimalPermissionList` reduced to glucose read/write.
- API-34 receiver flags: `xdrip.java`, `Home.java`, `services/broadcastservice/BroadcastService.java`
  use `ContextCompat.registerReceiver(..., RECEIVER_EXPORTED)` for non-system broadcasts.
- `google-services.json` — added a client entry for the new package.
- `res/drawable-*/ic_launcher.png` — TxD xDrip icon (from the iOS fork).
- `res/values/internal.xml` — app name.

## Build
```bash
export JAVA_HOME="/usr/local/Cellar/openjdk@17/17.0.18/libexec/openjdk.jdk/Contents/Home"
export ANDROID_HOME=/usr/local/share/android-commandlinetools
cd fh-txd-xdrip-android
# debug (emulator)
./gradlew :app:assembleProdDebug       # app/build/outputs/apk/prod/debug/app-prod-debug.apk
# signed release bundle (keystore + passwords in .local/, gitignored)
set -a; . .local/androidKeys.txt; set +a
export TXDXDRIP_RELEASE_STORE_FILE="$(pwd)/.local/txd-xdrip-upload.jks"
./gradlew :app:bundleProdRelease       # app/build/outputs/bundle/prodRelease/app-prod-release.aab
```
Bump `versionCode` in `app/build.gradle` by 1 for every upload.

## Play upload
Play app exists (package `com.foodhealth.txd.xdrip`, "TxD xDrip", free). 1.0.0 (versionCode 1) is live on
internal testing (first bundle had to be uploaded by hand; the API cannot create apps). Everything after that
goes through `tools/play_release.py` (Android Publisher API v3, same service account + IPv4 pin as
`fh-txd-android/android/play_upload.py`):
```bash
/usr/bin/python3 tools/play_release.py status            # bundles, internal track, testers
/usr/bin/python3 tools/play_release.py release [aab]     # upload (optional) + roll out to internal
/usr/bin/python3 tools/play_release.py listing           # title/descriptions + icon, feature graphic, screenshots from .local/listing/
```
As of 2026-10-10 09:12 the API still returns 403 for this package although the service account has admin on
the app; a watcher retries every 30 min and runs `release` + `listing` when access opens.

## Verified on emulator (API 35)
Wizard end to end: Health Connect permission (glucose only), companion source + notification access,
status page, Advanced → xDrip+ Home. No sensor on the emulator, so the data path itself (Stelo
notification → BgReading → Health Connect) still needs a real phone with the Stelo app.

## Status and disclaimer
Experimental, community software, not a medical device. Not for treatment decisions. See
upstream `README.md`.
