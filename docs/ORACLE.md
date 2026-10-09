# On-device diagnostic oracles

The tweak is a SpringBoard-only dylib, so "it crashed" usually means SpringBoard died and came back.
rootHide keeps no crash reports, and file logging is silently denied to SpringBoard, so the evidence
lands in three places. Read them in this order.

## 1. The preference ring (what happened, in order)

```bash
SSHPASS=... python scripts/vcr_device.py --host <HOST> get \
  /private/var/mobile/Library/Preferences/com.yourname.volumechordrecorder.plist ./p.plist
python -c "import plistlib;d=plistlib.load(open('p.plist','rb'));print(d.get('debugEvents',''))"
```

`debugEvents` holds the last ~14 lines with timestamps. The ring is overwritten constantly, so a burst
of unrelated events (the power button is pressed far more often than the chord) pushes anything older
out - which is exactly why the counters below exist.

## 2. Sticky counters (survive the ring being pushed)

```bash
python -c "import plistlib;d=plistlib.load(open('p.plist','rb'));[print('%-22s %s' % (k,d.get(k))) for k in \
  ('debugLastLoadTime','debugLastLoadBundle','debugPressTypes','debugVolumeSelectors','debugChordCounts','debugOtherPresses','debugVolumeAPI')]"
```

| Key | Means |
|---|---|
| `debugLastLoadTime` / `debugLastLoadBundle` | wrote a stamp just before the bundle check, so its absence means the dylib never ran in that process |
| `debugPressTypes` | press type counters (`began102`, `ended104`, ...) - shows which UIPress types the OS actually delivers |
| `debugVolumeSelectors` | which volume entry points fired: `increaseDown`, `increaseUp`, `increaseVolumeIntent` (the `SBVolumeControl` path) |
| `debugChordCounts` | how the chord was armed, including `paired-press` (two presses inside the pairing window) |
| `debugOtherPresses` | power-button presses, counted instead of logged so they cannot drown the ring |
| `debugVolumeAPI` | the class/selector dump taken from the running SpringBoard (the hook allowlist is built from this) |

## 3. The fatal-signal log (only for real crashes)

`VCRRecordingDirectory()/tweak-crash.log` is opened before anything else and SIGSEGV/SIGBUS/SIGABRT/
SIGILL/SIGTRAP are trapped into it. A watchdog kill is SIGKILL and cannot be caught, so an empty log
plus a respring means "blocked the main thread", not "crashed".

```bash
SSHPASS=... python scripts/vcr_device.py --host <HOST> sh "cat /var/mobile/Media/VolumeChordRecorder/tweak-crash.log 2>/dev/null; ls -la /var/mobile/Documents/VolumeChordRecorder/ 2>/dev/null"
```

## Verdict table

| Symptom | Evidence to look for |
|---|---|
| Tweak not active at all | no `debugLastLoadTime` after a respring, dylib present in `/usr/lib/TweakInject/` |
| Chord never arms | `debugChordCounts` empty while `debugPressTypes` shows volume presses |
| Volume keys dead | `debugVolumeSelectors` empty - the press hooks are not being called on this OS build |
| Settings option "crashes" it | SpringBoard PID changes right after a toggle; `PREFS CHANGED CRASH` line in the ring |
| Respring button does nothing | the alert's attempts list shows `jbroot(...)` rc values (EGRESS/ENOENT means the tool is not there) |
