# Compatibility

Every value in the matrix below came from real output (a built package, a device, or the toolchain
itself). Nothing here is copied from memory - if a cell says `unverified`, it has not been measured yet
and must not be quoted as working.

## Packaging matrix

Measured on the CI run that built both schemes (run 38029929962, the "Report control + postinst"
step) and on the device named in the last column. Toolchain SDK used for both: `iPhoneOS16.5.sdk`.

| Jailbreak | Scheme | iOS range | Architecture (`dpkg-deb -f`) | Path inside the deb | Runtime prefix | Verified |
|---|---|---|---|---|---|---|
| rootHide Bootstrap | `roothide` | 15.0-17.x | `iphoneos-arm64e` | `/Library/MobileSubstrate/DynamicLibraries/VolumeChordRecorder.dylib` | random jbroot, reached with `jbroot()` (never a literal `/var/jb`) | built by CI; loads and writes its stamp on iPhone 14 Pro Max, iOS 16.4.1 |
| Dopamine 2 | `rootless` | 15.0-16.6.1 | `iphoneos-arm64` | `/var/jb/Library/MobileSubstrate/DynamicLibraries/VolumeChordRecorder.dylib` | `/var/jb` | built by CI; **not yet installed on a rootless device** |

Both debs declare `Depends: mobilesubstrate` only: ElleKit provides `mobilesubstrate (= 99)`, and a
hard `preferenceloader` dependency would block installation on devices that do not have it.

One source builds both: `make package THEOS_PACKAGE_SCHEME=roothide FINALPACKAGE=1` (or `rootless`).
CI builds the matrix and uploads one artifact per scheme (here: 76,367 B roothide, 78,110 B rootless).

## Hook inventory

Enforced against the source by `scripts/vcr_check.py`; a class may only be hooked if it was observed on
a real device build.

| Class | Hooked selectors | If the class is absent |
|---|---|---|
| `SpringBoard` | `sendEvent:`, `pressesBegan:withEvent:`, `pressesEnded:withEvent:` (ungrouped) | never absent |
| `SBVolumeHardwareButtonActions` | `volumeIncreasePressDownWithModifiers:`, `volumeIncreasePressUp`, `volumeDecreasePressDownWithModifiers:`, `volumeDecreasePressUp` | press path falls back to the UIPress hooks |
| `SBVolumeControl` | `increaseVolume`, `decreaseVolume` | press path is the only trigger |
| `SBSensorActivityDataProvider` | `_handleNewDomainData:` (gated on `hidePrivacyDot`; the one place that does not call `%orig`) | nothing is hidden |
| `_UIStatusBarIndicatorBlobView` | `setAlpha:`, `setHidden:`, `didMoveToWindow` | iOS 16+ uses the item view below instead |
| `_UIStatusBarPrivacyIndicatorItemView` | `setAlpha:`, `setHidden:` | the blob view above covers 14/15 |
| `_UIPrivacyIndicatorBlobView` | `setAlpha:`, `setHidden:` | nothing to do (name is 17+) |
| `SBPrivacyBlobViewController` | `_updateBlobViews`, `_setVisible:animated:` | nothing to do |
| `MTMicrophoneUsageView` | `setAlpha:`, `setHidden:` | nothing to do |
| `MTPrivacyIndicatorViewController` | `_setIndicatorVisible:animated:` | nothing to do |

The six privacy-indicator classes above are the one row set that is not device-observed in the sense
this file means: they come from the build the owner ran before 2026-05-20 and are restored on request.
Measured on iOS 16.4.1, **none of the six exists** (`debugPrivacyIndicatorClasses` recorded
`hidePrivacyDot=1 (none present)`), so they install nothing there and the dot has to be hidden by the
`SBSensorActivityDataProvider` row instead. Each one is hooked only behind its own `objc_getClass` guard,
every one of them still calls `%orig`, and the load records which of the six the OS actually has - so a
wrong name is inert, and the next load says whether the restore did anything at all. `VCRDumpPrivacyClasses`
also records every class on the device whose name looks like a privacy/sensor/microphone indicator
(`debugPrivacyClassCandidates`), so the surviving names come from the running OS instead of another guess.

## Path rules used by this tweak

- Jailbreak paths (bootstrap tools, jailbreak-rooted data) go through the official `jbroot()` API from
  `#include <roothide.h>`: it resolves the live rootHide prefix at runtime and compiles to an empty stub
  for rootless/rootful builds. Hardcoded `/var/jb` or `/private/preboot` paths cannot work on rootHide
  because the jbroot name is randomised on every jailbreak.
- Capture files are user media, so they live on the normal root filesystem; the directory is probed at
  runtime (`VCRRecordingDirectory()` picks the first candidate it can actually write to and publishes it).
- Nothing is written into jailbreak directories by the tweak itself.

## Sources this was built from (read the upstream, not blog posts)

- roothide developer documentation - https://github.com/roothide/Developer
  (`README.md` for the scheme, `interface.md` for `jbroot`/`rootfs`, `roothide.md` for the random jbroot
  and `@loader_path/.jbroot/...` link paths, `entitlements.md` for sandbox and file access)
- roothide Bootstrap developer docs - https://roothidebootstrap.com/develop/
- Theos packaging and rootless documentation - https://theos.dev/docs/packaging ,
  https://theos.dev/docs/rootless - plus the toolchain itself, which outranks the docs:
  `grep -rn "THEOS_PACKAGE_SCHEME\|INSTALL_TARGET_PROCESSES" $THEOS/makefiles` and
  `ls $THEOS/vendor/mod/roothide`
- ElleKit (the hooking engine that provides `mobilesubstrate` on these jailbreaks) -
  https://github.com/evelyneee/ElleKit
- Dopamine (version and architecture support matrix) - https://github.com/opa334/Dopamine
- palera1n (the rootless route on iOS 17 for checkm8 devices) - https://github.com/palera1n/palera1n

## Known limits

- The tweak is SpringBoard-only by design (`Filter = { Bundles = (com.apple.springboard); }`): it is not
  injected into apps or daemons, so it cannot affect the boot chain and it cannot hang a third-party app.
- The microphone/camera privacy indicator is hidden only while **Hide Privacy Dot** is on; with it off
  (the default) every indicator hook passes the real value through. Where the version's indicator view
  classes exist they are forced to zero alpha; where they do not (measured: all six are absent on
  16.4.1) the sensor-activity update itself is dropped, which is the one hook in the tweak that does not
  call `%orig`. Nothing else that reads sensor-activity data is affected on this build, because the
  provider is SpringBoard's own and the tweak is injected into SpringBoard only.
- A video start that never reaches `isRecording` (session not running, media services reset, no usable
  connection) used to leave `vcrCameraRecording` set with nothing recording; every later chord then hit
  the "while recording, the release means STOP" rule and did nothing. A 2 s watchdog now clears the flag
  and says so, so the next chord works instead of the tweak looking dead.
- The chord's press-down selectors are not reported for every press on iOS 16.4.1 (device tally: 825
  press-ups against 283 press-downs). Both buttons releasing inside 150 ms is therefore also treated as
  the chord, which is what makes a quick press work when the press-down never arrives.
- An iOS 15.x or 17.x device has not been tested yet; those rows stay `unverified` until one is.
