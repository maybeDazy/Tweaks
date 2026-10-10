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
| `SBSensorActivityDataProvider` | `_handleNewDomainData:` (pass-through only, `%orig` runs) | nothing to do |

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
- The microphone/camera privacy indicator is an iOS feature and is not hidden.
- An iOS 15.x or 17.x device has not been tested yet; those rows stay `unverified` until one is.
