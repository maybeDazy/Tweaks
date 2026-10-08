# VolumeChordRecorder — video quality fix, hold-seconds slider, Telegram upload

Repo root for all paths below: `C:/Users/server/Desktop/VolumeChordRecorder_roothide_src/Tweaks`
(the git repo root IS the `Tweaks/` folder). Branch `main`, remote `origin`.

## Goal

Make video quality actually take effect, expose hold-seconds as draggable sliders (for the audio
and camera volume chords), and upload every finished audio/video/photo capture to Telegram —
plus fix the smaller defects found while reading the code.

## Current context / assumptions

Verified by reading the code and the device (do not re-derive these):

- Layout: `Tweak.xm` (1591 lines, the SpringBoard dylib) + `Preferences/VCRRootListController.mm`
  (prefs bundle) + `Preferences/Resources/Root.plist` (575 lines, the Settings UI) + `Makefile`
  (`VolumeChordRecorder_FILES = Tweak.xm`, `VolumeChordRecorder_FRAMEWORKS = UIKit AVFoundation AudioToolbox`).
- Prefs domain is `com.yourname.volumechordrecorder`, read in the tweak via
  `VCRBoolPref`/`VCRDoublePref`/`VCRStringPref` (Tweak.xm:126-165) and in the bundle via
  `-readPreferenceValue:` / `-setPreferenceValue:specifier:` overrides that already write through
  CFPreferences (VCRRootListController.mm:28-42). The bundle's override posts the Darwin
  notification `com.yourname.volumechordrecorder.prefschanged`.
- The tweak observes that notification and calls `VCRLoadPrefs()` (Tweak.xm:1552-1558).
- **On-device prefs prove the four `PSMultiValueSpecifier` cells have never persisted**: the live
  plist contains `cameraEnabled`, `cameraChordTrigger`, `holdSeconds`, `volumeChordTrigger`, … but
  none of `cameraVideoQuality`, `cameraPosition`, `cameraLens`, `cameraPhotoQuality`, even though
  the user tried to change video quality. Switch and text cells do persist.
- **Video quality is also ignored in code**: `VCRCameraPrepareSession()` sets
  `vcrCaptureSession.sessionPreset` and commits (Tweak.xm:516-527), and only *then* calls
  `VCRCameraApplyFrameRate()` (Tweak.xm:457-489), which picks the **largest-area format that
  supports the fps** — so 720p/1080p selections are silently replaced by the biggest format.
- `vcrHoldSeconds` is read with a minimum of `0.0` (Tweak.xm:174) and the user's device currently
  stores `holdSeconds = 0`, so the tier collapses to the `MAX(0.4, …)` floor (Tweak.xm:704).
- Hold seconds is a `PSEditTextCell` (Root.plist:83-98). PreferenceLoader has no built-in slider
  cell; the bundle must draw its own row.
- Debug evidence channel: file writes from the injected dylib are **silently denied by
  SpringBoard's sandbox** (proved on device). `VCRDebugEvent()` (Tweak.xm:126-165 region) writes
  to CFPreferences instead and the Settings "Show Debug Log" button displays it. Keep using it.
- CI: `.github/workflows/build.yml` builds the roothide deb on push and uploads the artifact
  `VolumeChordRecorder-roothide-deb`. `gh secret list` shows `TELEGRAM_BOT_TOKEN` and
  `TELEGRAM_CHAT_ID` **already exist** — so the user already owns a bot. The token value must be
  pasted into the Settings pane for device-side uploads (secrets are not readable from here).
- The build environment (roothide/theos on the `oracle` box) has
  `/home/ubuntu/theos/vendor/include/Preferences/PSSpecifier.h` and `PSListController.h`;
  `PSListController` declares `- (PSSpecifier *)specifierAtIndexPath:(NSIndexPath *)`, and
  `PSSpecifier.h` declares `PSCellClassKey` (`@"cellClass"`) — so both custom-row routes exist.
  This plan uses `specifierAtIndexPath:` because it does not depend on how PL instantiates cells.
- `Tweaks/postinst` exists in the repo but is **not packaged**: the deb's `control.tar.gz` contains
  only `./control`, so installing never restarts SpringBoard. Adding it removes a whole class of
  "did the new build even load?" confusion.
- No local build is possible (Docker Desktop down, WSL unavailable). The only build is
  GitHub Actions; the only runtime is the device (iPhone 14 Pro Max, iOS 16.4.1, rootHide,
  `100.90.218.125`, user `mobile`).
- Device quirks that shape the verification steps: `kill -9 <SpringBoard PID>` drops the device off
  SSH/Tailscale for 10+ minutes (it sleeps — ask the user to wake the screen); cfprefsd flushes the
  prefs plist lazily, so wait ≥30 s before reading it and never conclude "the write did not happen"
  from a stale mtime; `plutil -p` does not exist on iOS — pull the plist over SFTP and parse it
  with Python `plistlib`.

Assumption to confirm with the user (see Open questions): one hold-seconds value shared by the
audio and camera chords, not two separate values.

## Architecture / proposed approach

Two independent layers. (1) In the prefs bundle, add a tiny custom-row layer — a
`cellForRowAtIndexPath:` override that draws slider rows and choice rows itself, plus a
`didSelectRowAtIndexPath:` override that presents a `UIAlertController` action sheet for choices —
so selection and persistence go through the bundle's own CFPreferences write path instead of
PreferenceLoader's `PSMultiValueSpecifier`, and the selected value is always shown in the row.
(2) In the tweak, fix the capture-format ordering so the chosen resolution survives, then add a
self-contained Telegram uploader (`VCRTelegramUploader.m`, its own file so `Tweak.xm` does not grow
further) that is invoked from the three existing completion points (audio stop, video move, photo
write) and reports its result into the existing CFPreferences debug log.

## Step-by-step tasks

Each task is: write the check first, see it fail, implement, see it pass, commit.

### Task 0 — Add the local static check harness (do this first, everything else uses it)

Create `scripts/vcr_check.py`. It is the only automatable test in this repo (the tweak cannot run
off-device), so it must assert real things: plist structure, exact source strings and their order.

```python
#!/usr/bin/env python3
"""Static checks for the VolumeChordRecorder sources. No device needed.

Usage: python3 scripts/vcr_check.py
Prints one line per check and exits non-zero on the first failure.
"""
import os, plistlib, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T = open(os.path.join(ROOT, "Tweak.xm"), encoding="utf-8").read()
MM = open(os.path.join(ROOT, "Preferences", "VCRRootListController.mm"), encoding="utf-8").read()
PLIST_PATH = os.path.join(ROOT, "Preferences", "Resources", "Root.plist")
PLIST = plistlib.load(open(PLIST_PATH, "rb"))
CELLS = PLIST["items"] if "items" in PLIST else PLIST
CELLS = [c for c in CELLS if isinstance(c, dict)]
UP = open(os.path.join(ROOT, "Makefile"), encoding="utf-8").read()

checks = []
def check(name, ok, detail=""):
    checks.append((name, bool(ok), detail))

def cell_for_key(key):
    for c in CELLS:
        if c.get("key") == key:
            return c
    return None

def has(path, needle):
    src = {"Tweak.xm": T, "mm": MM, "Makefile": UP}[path]
    return needle in src

def order(path, first, second):
    src = {"Tweak.xm": T, "mm": MM}[path]
    a, b = src.find(first), src.find(second)
    return a != -1 and b != -1 and a < b

# --- existing behaviour that must not regress ---
check("prefs domain unchanged", has("mm", '"com.yourname.volumechordrecorder"'))
check("prefs notification name unchanged",
      has("Tweak.xm", "com.yourname.volumechordrecorder.prefschanged"))
check("CFPreferences debug recorder still present", has("Tweak.xm", "static void VCRDebugEvent"))
check("bundle still overrides setPreferenceValue:specifier:", has("mm", "- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier"))

# --- task 1: video quality ---
check("quality -> exact format helper exists", has("Tweak.xm", "VCRCameraApplyVideoFormat"))
check("target resolution table exists", has("Tweak.xm", "VCRVideoTarget"))
check("format is applied AFTER commitConfiguration (preset no longer wins)",
      order("Tweak.xm", "commitConfiguration];\n            VCRCameraApplyVideoFormat", "VCRLog(@\"Camera: video preset="))
check("effective format is logged", has("Tweak.xm", "Camera: video preset=") and has("Tweak.xm", "Camera: effective format"))
check("hold seconds floor is 0.2, not 0.0", 'VCRDoublePref(@"holdSeconds", 2.0, 0.2' in T)

# --- task 2/3: custom rows ---
check("slider row dispatch present", has("mm", '"vcrKind"'))
check("slider changed handler present", has("mm", "vcrSliderChanged:"))
check("choice action sheet present", has("mm", "vcrPresentChoicesForSpecifier"))
check("cellForRowAtIndexPath override present", has("mm", "- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath"))
check("didSelectRowAtIndexPath override present", has("mm", "- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath"))

c = cell_for_key("holdSeconds")
check("holdSeconds is a slider row", c and c.get("vcrKind") == "slider", repr(c))
check("holdSeconds slider bounds 0.2..5.0",
      c and float(c.get("vcrMin", 0)) == 0.2 and float(c.get("vcrMax", 0)) == 5.0, repr(c))
for key, want in [("cameraVideoQuality", 6), ("cameraPhotoQuality", 3), ("cameraPosition", 2), ("cameraLens", 2)]:
    c = cell_for_key(key)
    check("choice row %s present with %d titles" % (key, want),
          c and c.get("vcrKind") == "choice" and len(c.get("vcrTitles", [])) == want
          and len(c.get("vcrValues", [])) == len(c.get("vcrTitles", [])), repr(c))
    check("choice row %s is no longer PSMultiValueSpecifier" % key,
          c and c.get("cell") != "PSMultiValueSpecifier", repr(c))
check("no PSMultiValueSpecifier cells left", not any(c.get("cell") == "PSMultiValueSpecifier" for c in CELLS))
check("video quality titles/values kept from before",
      cell_for_key("cameraVideoQuality").get("vcrValues") ==
      ["720p30", "1080p30", "1080p60", "4k30", "4k60", "auto"])

# --- task 4/5: telegram ---
check("telegram uploader source exists", os.path.exists(os.path.join(ROOT, "VCRTelegramUploader.m")))
check("uploader compiled into the tweak", "VolumeChordRecorder_FILES = Tweak.xm VCRTelegramUploader.m" in UP)
check("uploader is called from audio stop", has("Tweak.xm", "VCRTelegramSendFile("))
check("telegram settings cells exist",
      all(cell_for_key(k) for k in ["telegramEnabled", "telegramBotToken", "telegramChatID",
                                    "telegramSendAudio", "telegramSendVideo", "telegramSendPhoto"]))
check("telegram test button wired",
      any(c.get("action") == "sendTelegramTest" for c in CELLS))
check("50 MB bot limit is guarded", has("VCRTelegramUploader.m", "50") and has("VCRTelegramUploader.m", "limit"))
check("postinst is packaged", "postinst" in UP or os.path.exists(os.path.join(ROOT, "postinst")) and "SUBPROJECTS" in UP)

failed = [c for c in checks if not c[1]]
for name, ok, detail in checks:
    print("%s %s%s" % ("PASS" if ok else "FAIL", name, ("  <- " + detail[:120]) if (not ok and detail) else ""))
print("\n%s: %d checks, %d failed" % ("OK" if not failed else "FAILED", len(checks), len(failed)))
sys.exit(1 if failed else 0)
```

Run it now — it must fail (nothing is implemented yet):

```
cd C:/Users/server/Desktop/VolumeChordRecorder_roothide_src/Tweaks
python3 scripts/vcr_check.py
```

Expected: `FAIL` for every task-1..5 check, ending with `FAILED: 27 checks, 19 failed` (the exact
count may drift by one as you add checks — what matters is that the task-1..5 lines are `FAIL`).

Commit:
```
git add scripts/vcr_check.py
git commit -m "Add static check harness for tweak sources and prefs plist"
```

### Task 1 — Video quality: pick the exact format, and prove it in the log

Edit `Tweak.xm`.

1.1 Replace `VCRCameraFPSForQuality`'s implicit mapping with an explicit target table. Insert right
after `VCRCameraVideoPresetConstant()` (ends Tweak.xm:446):

```objc
// Requested resolution/frame rate for the current quality pref. width==0 means "auto".
typedef struct { int32_t width; int32_t height; int32_t fps; } VCRVideoTarget;

static VCRVideoTarget VCRVideoTargetForQuality(void) {
    NSString *q = vcrCameraVideoQuality;
    if ([q hasPrefix:@"720p"])  return (VCRVideoTarget){1280, 720, 30};
    if ([q hasPrefix:@"1080p"]) return (VCRVideoTarget){1920, 1080, [q hasSuffix:@"60"] ? 60 : 30};
    if ([q hasPrefix:@"4k"])    return (VCRVideoTarget){3840, 2160, [q hasSuffix:@"60"] ? 60 : 30};
    return (VCRVideoTarget){0, 0, 0};
}
```

1.2 Replace the whole body of `VCRCameraApplyFrameRate()` (Tweak.xm:455-489) with an
exact-match version that only accepts the requested resolution:

```objc
// The session preset alone does not decide the recorded resolution, and the previous
// implementation forced the *largest* format supporting the frame rate - so every quality
// recorded at the biggest format and the selection appeared to do nothing. Pick the format
// whose dimensions match the request exactly, then pin the frame duration.
static BOOL VCRCameraApplyVideoFormat(AVCaptureDevice *device) {
    if (!device) return NO;
    VCRVideoTarget target = VCRVideoTargetForQuality();

    NSError *error = nil;
    if (![device lockForConfiguration:&error]) {
        VCRLog(@"Camera: lockForConfiguration failed %@", error);
        return NO;
    }

    AVCaptureDeviceFormat *chosen = nil;
    if (target.width > 0) {
        for (AVCaptureDeviceFormat *format in device.formats) {
            CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
            if (dims.width != target.width || dims.height != target.height) continue;
            float maxRate = 0.0f;
            for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
                if (range.maxFrameRate > maxRate) maxRate = range.maxFrameRate;
            }
            if (maxRate + 0.001f < (float)target.fps) continue;
            chosen = format;
            break;
        }
    }

    if (chosen) {
        device.activeFormat = chosen;
        device.activeVideoMinFrameDuration = CMTimeMake(1, target.fps);
        device.activeVideoMaxFrameDuration = CMTimeMake(1, target.fps);
    }
    [device unlockForConfiguration];

    if (target.width > 0 && !chosen) {
        VCRLog(@"Camera: no %dx%d@%dfps format on %@ - quality %@ ignored",
               target.width, target.height, target.fps, device.localizedName, vcrCameraVideoQuality);
    }
    return chosen != nil;
}

// Log what the device actually ended up with. This is the line that proves a quality change
// took effect; it is read back from "Show Debug Log" in Settings.
static void VCRCameraLogEffectiveVideoFormat(AVCaptureDevice *device) {
    if (!device) return;
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription);
    int32_t fps = 0;
    if (device.activeVideoMinFrameDuration.timescale > 0) {
        fps = (int32_t)(device.activeVideoMinFrameDuration.timescale / MAX(1, device.activeVideoMinFrameDuration.value));
    }
    VCRLog(@"Camera: effective format %dx%d @ %dfps (quality=%@ requested=%dx%d@%dfps)",
           (int)dims.width, (int)dims.height, (int)fps, vcrCameraVideoQuality,
           (int)VCRVideoTargetForQuality().width, (int)VCRVideoTargetForQuality().height,
           (int)VCRVideoTargetForQuality().fps);
}
```

1.3 In `VCRCameraPrepareSession()` video branch (Tweak.xm:516-527), call the format picker **after**
`commitConfiguration` (the preset assignment re-picks the device format, so the last write must
win), and log the effective format:

```objc
        vcrCaptureSession.sessionPreset = preset;
        if (vcrMovieOutput && [vcrCaptureSession canAddOutput:vcrMovieOutput]) [vcrCaptureSession addOutput:vcrMovieOutput];
        else VCRLog(@"Camera: cannot add movie output");
        [vcrCaptureSession commitConfiguration];
        VCRCameraApplyVideoFormat(device);          // preset re-picks activeFormat; re-assert the choice
        VCRLog(@"Camera: video preset=%@ device=%@ lens=%@ pos=%@ quality=%@ fps=%d",
               preset, device.localizedName, vcrCameraLens, vcrCameraPosition,
               vcrCameraVideoQuality, (int)VCRCameraFPSForQuality());
        VCRCameraLogEffectiveVideoFormat(device);
```

1.4 Clamp the hold pref so `holdSeconds = 0` cannot collapse the tiers. In `VCRLoadPrefs()`
(Tweak.xm:174):

```objc
    vcrHoldSeconds = VCRDoublePref(@"holdSeconds", 2.0, 0.2, 10.0);
```

Verify:
```
python3 scripts/vcr_check.py
```
Expected: the 5 task-1 lines now `PASS`; still `FAIL` for tasks 2-5.

Commit:
```
git add Tweak.xm scripts/vcr_check.py
git commit -m "Video quality: pick the exact requested format after commit and log the effective one; clamp hold seconds minimum"
```

### Task 2 — Hold seconds as a slider

2.1 In `Preferences/Resources/Root.plist`, replace the `PSEditTextCell` block for `holdSeconds`
(lines 83-98) with:

```xml
		<dict>
			<key>cell</key>
			<string>PSLinkCell</string>
			<key>label</key>
			<string>Hold Seconds</string>
			<key>vcrKind</key>
			<string>slider</string>
			<key>vcrKey</key>
			<string>holdSeconds</string>
			<key>vcrDefault</key>
			<real>2.0</real>
			<key>vcrMin</key>
			<real>0.2</real>
			<key>vcrMax</key>
			<real>5.0</real>
		</dict>
```

2.2 In `Preferences/VCRRootListController.mm`, add an ivar-free custom-row layer. Insert after the
existing `- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier` (ends line 42):

```objc
// ---- Custom rows -------------------------------------------------------------------------
// PreferenceLoader's PSMultiValueSpecifier cells never persisted in this bundle (no camera* key
// ever reached the domain) and PreferenceLoader has no slider cell at all, so slider and choice
// rows are drawn here and written through setPreferenceValue:specifier: below, which uses
// CFPreferences like the rest of the tweak.

- (id)vcrRawValueForKey:(NSString *)key fallback:(id)fallback {
    if (![key isKindOfClass:[NSString class]]) return fallback;
    CFPreferencesAppSynchronize((__bridge CFStringRef)VCRPrefsID);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)VCRPrefsID);
    if (!value) return fallback;
    return CFBridgingRelease(value);
}

- (void)vcrWriteValue:(id)value forSpecifier:(PSSpecifier *)specifier {
    [self setPreferenceValue:value specifier:specifier];
}

- (NSString *)vcrTitleForSpecifier:(PSSpecifier *)specifier {
    NSArray *titles = [specifier propertyForKey:@"vcrTitles"] ?: @[];
    NSArray *values = [specifier propertyForKey:@"vcrValues"] ?: @[];
    id current = [self vcrRawValueForKey:[specifier propertyForKey:@"vcrKey"]
                                fallback:[specifier propertyForKey:@"vcrDefault"]];
    NSUInteger index = [values indexOfObject:current];
    if (index != NSNotFound && index < titles.count) return titles[index];
    return [specifier propertyForKey:@"vcrDefault"] ? [NSString stringWithFormat:@"%@", [specifier propertyForKey:@"vcrDefault"]] : @"(default)";
}

- (void)vcrSliderChanged:(UISlider *)slider {
    UITableViewCell *cell = nil;
    for (UIView *view = slider; view; view = view.superview) {
        if ([view isKindOfClass:[UITableViewCell class]]) { cell = (UITableViewCell *)view; break; }
    }
    UILabel *valueLabel = [cell.contentView viewWithTag:VCRSliderValueTag];
    double value = round(slider.value * 10.0) / 10.0;
    if (valueLabel) valueLabel.text = [NSString stringWithFormat:@"%.1fs", value];
}

- (void)vcrSliderCommitted:(UISlider *)slider {
    UITableViewCell *cell = nil;
    for (UIView *view = slider; view; view = view.superview) {
        if ([view isKindOfClass:[UITableViewCell class]]) { cell = (UITableViewCell *)view; break; }
    }
    NSIndexPath *indexPath = cell ? [self.tableView indexPathForCell:cell] : nil;
    PSSpecifier *specifier = indexPath ? [self specifierAtIndexPath:indexPath] : nil;
    if (!specifier) return;
    double value = round(slider.value * 10.0) / 10.0;
    [self vcrWriteValue:@(value) forSpecifier:specifier];
    VCRPrefsLog(@"slider %@ = %.1fs", [specifier propertyForKey:@"vcrKey"], value);
}

- (UITableViewCell *)vcrSliderCellForTableView:(UITableView *)tableView specifier:(PSSpecifier *)specifier {
    static NSString *reuse = @"VCRSliderRow";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuse];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UILabel *label = [[UILabel alloc] init];
        label.font = [UIFont systemFontOfSize:14.0];
        label.tag = VCRSliderLabelTag;
        label.translatesAutoresizingMaskIntoConstraints = NO;

        UISlider *slider = [[UISlider alloc] init];
        slider.tag = VCRSliderControlTag;
        slider.continuous = YES;
        slider.translatesAutoresizingMaskIntoConstraints = NO;
        [slider addTarget:self action:@selector(vcrSliderChanged:) forControlEvents:UIControlEventValueChanged];
        [slider addTarget:self action:@selector(vcrSliderCommitted:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];

        UILabel *value = [[UILabel alloc] init];
        value.font = [UIFont monospacedDigitSystemFontOfSize:14.0 weight:UIFontWeightRegular];
        value.textAlignment = NSTextAlignmentRight;
        value.tag = VCRSliderValueTag;
        value.translatesAutoresizingMaskIntoConstraints = NO;

        [cell.contentView addSubview:label];
        [cell.contentView addSubview:slider];
        [cell.contentView addSubview:value];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16.0],
            [label.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [label.widthAnchor constraintEqualToConstant:130.0],
            [value.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16.0],
            [value.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [value.widthAnchor constraintEqualToConstant:58.0],
            [slider.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:8.0],
            [slider.trailingAnchor constraintEqualToAnchor:value.leadingAnchor constant:-8.0],
            [slider.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        ]];
    }

    NSNumber *minimum = [specifier propertyForKey:@"vcrMin"] ?: @0.2;
    NSNumber *maximum = [specifier propertyForKey:@"vcrMax"] ?: @5.0;
    double value = [[self vcrRawValueForKey:[specifier propertyForKey:@"vcrKey"]
                                   fallback:[specifier propertyForKey:@"vcrDefault"]] doubleValue];
    if (!(value >= minimum.doubleValue)) value = minimum.doubleValue;
    if (value > maximum.doubleValue) value = maximum.doubleValue;

    UILabel *label = [cell.contentView viewWithTag:VCRSliderLabelTag];
    UISlider *slider = [cell.contentView viewWithTag:VCRSliderControlTag];
    UILabel *valueLabel = [cell.contentView viewWithTag:VCRSliderValueTag];
    label.text = [specifier propertyForKey:@"label"];
    slider.minimumValue = minimum.floatValue;
    slider.maximumValue = maximum.floatValue;
    slider.value = (float)value;
    valueLabel.text = [NSString stringWithFormat:@"%.1fs", value];
    return cell;
}

- (void)vcrPresentChoicesForSpecifier:(PSSpecifier *)specifier indexPath:(NSIndexPath *)indexPath {
    NSArray *titles = [specifier propertyForKey:@"vcrTitles"] ?: @[];
    NSArray *values = [specifier propertyForKey:@"vcrValues"] ?: @[];
    NSString *key = [specifier propertyForKey:@"vcrKey"];
    if (titles.count == 0 || titles.count != values.count || !key) return;

    id current = [self vcrRawValueForKey:key fallback:[specifier propertyForKey:@"vcrDefault"]];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[specifier propertyForKey:@"label"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger i = 0; i < titles.count; i++) {
        NSString *title = titles[i];
        BOOL selected = [values[i] isEqual:current];
        NSString *label = selected ? [@"\u2713 " stringByAppendingString:title] : title;
        id value = values[i];
        [sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self vcrWriteValue:value forSpecifier:specifier];
            VCRPrefsLog(@"choice %@ = %@", key, value);
            NSIndexPath *path = [self.tableView indexPathForCell:[self.tableView cellForRowAtIndexPath:indexPath]];
            if (path) [self.tableView reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationNone];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSString *kind = [specifier propertyForKey:@"vcrKind"];

    if ([kind isEqualToString:@"slider"]) {
        return [self vcrSliderCellForTableView:tableView specifier:specifier];
    }
    if ([kind isEqualToString:@"choice"]) {
        static NSString *reuse = @"VCRChoiceRow";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuse];
        cell.textLabel.text = [specifier propertyForKey:@"label"];
        cell.detailTextLabel.text = [self vcrTitleForSpecifier:specifier];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    return [super tableView:tableView cellForRowAtIndexPath:indexPath];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    if ([[specifier propertyForKey:@"vcrKind"] isEqualToString:@"choice"]) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [self vcrPresentChoicesForSpecifier:specifier indexPath:indexPath];
        return;
    }
    [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}
```

2.3 Add the tags and a debug hook near the top of the same file (after line 10):

```objc
enum { VCRSliderLabelTag = 9001, VCRSliderControlTag = 9002, VCRSliderValueTag = 9003 };

// The prefs bundle cannot call the tweak directly; diagnostics go to the same prefs keys the
// tweak's VCRDebugEvent() writes, so everything shows up in one place: "Show Debug Log".
static void VCRPrefsLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *message = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSString *existing = [[NSUserDefaults standardUserDefaults] objectForKey:@"debugEvents"];
    for (NSString *line in [existing componentsSeparatedByString:@"\n"]) {
        if (line.length > 0) [lines addObject:line];
    }
    [lines addObject:message];
    while (lines.count > 8) [lines removeObjectAtIndex:0];
    [[NSUserDefaults standardUserDefaults] setObject:[lines componentsJoinedByString:@"\n"] forKey:@"debugEvents"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}
```

Verify: `python3 scripts/vcr_check.py` → the 4 task-2 lines `PASS`.
(`- (void)setPreferenceValue:` may be flagged unused-warning-clean; the bundle has no linter.)

Commit:
```
git add Preferences/Resources/Root.plist Preferences/VCRRootListController.mm
git commit -m "Hold seconds: replace the text cell with a real slider row written through CFPreferences"
```

### Task 3 — Choice rows for the four broken multi-value cells

3.1 In `Preferences/Resources/Root.plist`, replace each of the four
`PSMultiValueSpecifier` dicts (lines 277-382) with a `vcrKind = choice` row. The titles/values are
unchanged from today; only the cell type and key names change. Shape to use for all four:

```xml
		<dict>
			<key>cell</key>
			<string>PSLinkCell</string>
			<key>label</key>
			<string>Camera (Front/Back)</string>
			<key>vcrKind</key>
			<string>choice</string>
			<key>vcrKey</key>
			<string>cameraPosition</string>
			<key>vcrDefault</key>
			<string>back</string>
			<key>vcrTitles</key>
			<array>
				<string>Back</string>
				<string>Front</string>
			</array>
			<key>vcrValues</key>
			<array>
				<string>back</string>
				<string>front</string>
			</array>
		</dict>
```

Same for `cameraLens` (`1x (Wide)`/`0.5x (Ultra Wide)` → `wide`/`ultrawide`), `cameraVideoQuality`
(the six existing pairs, default `1080p30`), `cameraPhotoQuality` (three existing pairs, default
`quality`). Copy the title/value strings verbatim from lines 277-382 so the visible labels do not
change.

3.2 Also fix the stale Debug Log footer (Root.plist:533) — it still describes the file log that the
sandbox blocks:

```xml
			<key>footerText</key>
			<string>Trigger diagnostics live in the app preferences (proved on device: SpringBoard's sandbox silently denies file writes from the tweak). "Show Debug Log" shows whether the tweak was injected, how many trigger events arrived and the last few events, including camera format and Telegram results.</string>
```

Verify: `python3 scripts/vcr_check.py` → all task-2/3 lines `PASS`, including
`no PSMultiValueSpecifier cells left`.

Commit:
```
git add Preferences/Resources/Root.plist
git commit -m "Prefs: selection rows built by the bundle instead of PSMultiValueSpecifier (which never persisted here)"
```

### Task 4 — Telegram settings UI + test path

4.1 Append a new group before the closing `</array>` of Root.plist (line 573):

```xml
		<dict>
			<key>cell</key>
			<string>PSGroupCell</string>
			<key>label</key>
			<string>Telegram Upload</string>
			<key>footerText</key>
			<string>Bot API uploads are capped at 50 MB, so 4K/60 clips are skipped with a note in the debug log. The token is stored in this preferences file in plain text.</string>
		</dict>
		<dict>
			<key>cell</key>
			<string>PSSwitchCell</string>
			<key>label</key>
			<string>Upload Finished Captures</string>
			<key>key</key>
			<string>telegramEnabled</string>
			<key>default</key>
			<false/>
			<key>defaults</key>
			<string>com.yourname.volumechordrecorder</string>
			<key>PostNotification</key>
			<string>com.yourname.volumechordrecorder.prefschanged</string>
		</dict>
		<dict>
			<key>cell</key>
			<string>PSEditTextCell</string>
			<key>label</key>
			<string>Bot Token</string>
			<key>key</key>
			<string>telegramBotToken</string>
			<key>default</key>
			<string></string>
			<key>defaults</key>
			<string>com.yourname.volumechordrecorder</string>
			<key>PostNotification</key>
			<string>com.yourname.volumechordrecorder.prefschanged</string>
		</dict>
		<dict>
			<key>cell</key>
			<string>PSEditTextCell</string>
			<key>keyboard</key>
			<string>numbersAndPunctuation</string>
			<key>label</key>
			<string>Chat ID</string>
			<key>key</key>
			<string>telegramChatID</string>
			<key>default</key>
			<string></string>
			<key>defaults</key>
			<string>com.yourname.volumechordrecorder</string>
			<key>PostNotification</key>
			<string>com.yourname.volumechordrecorder.prefschanged</string>
		</dict>
		<dict>
			<key>cell</key>
			<string>PSSwitchCell</string>
			<key>label</key>
			<string>Send Audio Recordings</string>
			<key>key</key>
			<string>telegramSendAudio</string>
			<key>default</key>
			<true/>
			<key>defaults</key>
			<string>com.yourname.volumechordrecorder</string>
			<key>PostNotification</key>
			<string>com.yourname.volumechordrecorder.prefschanged</string>
		</dict>
		<dict>
			<key>cell</key>
			<string>PSSwitchCell</string>
			<key>label</key>
			<string>Send Videos</string>
			<key>key</key>
			<string>telegramSendVideo</string>
			<key>default</key>
			<true/>
			<key>defaults</key>
			<string>com.yourname.volumechordrecorder</string>
			<key>PostNotification</key>
			<string>com.yourname.volumechordrecorder.prefschanged</string>
		</dict>
		<dict>
			<key>cell</key>
			<string>PSSwitchCell</string>
			<key>label</key>
			<string>Send Photos</string>
			<key>key</key>
			<string>telegramSendPhoto</string>
			<key>default</key>
			<false/>
			<key>defaults</key>
			<string>com.yourname.volumechordrecorder</string>
			<key>PostNotification</key>
			<string>com.yourname.volumechordrecorder.prefschanged</string>
		</dict>
		<dict>
			<key>cell</key>
			<string>PSButtonCell</string>
			<key>label</key>
			<string>Send Test (uses SpringBoard)</string>
			<key>action</key>
			<string>sendTelegramTest</string>
		</dict>
		<dict>
			<key>cell</key>
			<string>PSButtonCell</string>
			<key>label</key>
			<string>Send Latest Recording</string>
			<key>action</key>
			<string>sendTelegramLatest</string>
		</dict>
```

4.2 In `VCRRootListController.mm`, add the two actions. They must NOT do networking themselves —
the bundle cannot link the tweak's uploader, so they ask the tweak (in SpringBoard) to do it and
the result lands in the debug log:

```objc
// The uploader lives in the tweak (SpringBoard), not in this bundle, so these buttons just ask
// it to run - that also proves the real code path, not a copy of it.
- (void)sendTelegramTest {
    notify_post("com.yourname.volumechordrecorder.telegramtest");
    [self showAlertWithTitle:@"Telegram"
                     message:@"Test requested. Open \"Show Debug Log\" in a few seconds: it reports sendMessage ok, or the API error (401 = bad token, 400 = bad chat id)."];
}

- (void)sendTelegramLatest {
    notify_post("com.yourname.volumechordrecorder.telegramsendlatest");
    [self showAlertWithTitle:@"Telegram"
                     message:@"Uploading the newest recording. See \"Show Debug Log\" for the result."];
}
```

Verify:
```
python3 scripts/vcr_check.py
```
Expected: `telegram settings cells exist`, `telegram test button wired`, `50 MB bot limit is
guarded` … the last two still `FAIL` until task 5. Expect `FAILED: … , ~6 failed`.

Commit:
```
git add Preferences/Resources/Root.plist Preferences/VCRRootListController.mm
git commit -m "Telegram: settings cells plus test/latest buttons that ask SpringBoard to upload"
```

### Task 5 — Telegram uploader in the tweak

5.1 Create `VCRTelegramUploader.h` (repo root, next to `Tweak.xm`):

```objc
#import <Foundation/Foundation.h>

typedef void (^VCRTelegramLogBlock)(NSString *message);

FOUNDATION_EXPORT NSString * const VCRTelegramPrefsDomain;

BOOL VCRTelegramIsEnabled(void);
BOOL VCRTelegramSendFile(NSURL *fileURL, NSString *kind, VCRTelegramLogBlock log);
void VCRTelegramSendText(NSString *text, VCRTelegramLogBlock log);
BOOL VCRTelegramWantsKind(NSString *kind);
```

5.2 Create `VCRTelegramUploader.m`:

```objc
#import "VCRTelegramUploader.h"

NSString * const VCRTelegramPrefsDomain = @"com.yourname.volumechordrecorder";

// Bot API hard limit for uploading a file. 4K/60 clips pass this quickly, so it must be checked
// before the request rather than discovering it as a 413.
static const unsigned long long VCRTelegramMaxUploadBytes = 50ULL * 1024ULL * 1024ULL;

static id VCRTGPref(NSString *key, id fallback) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)VCRTelegramPrefsDomain);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)VCRTelegramPrefsDomain);
    if (!value) return fallback;
    return CFBridgingRelease(value);
}

static NSString *VCRTGToken(void) { return [VCRTGPref(@"telegramBotToken", @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]; }
static NSString *VCRTGChat(void)  { return [VCRTGPref(@"telegramChatID",  @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]; }

BOOL VCRTelegramIsEnabled(void) { return [VCRTGPref(@"telegramEnabled", @NO) boolValue] && VCRTGToken().length > 0 && VCRTGChat().length > 0; }

BOOL VCRTelegramWantsKind(NSString *kind) {
    if ([kind isEqualToString:@"audio"]) return [VCRTGPref(@"telegramSendAudio", @YES) boolValue];
    if ([kind isEqualToString:@"video"]) return [VCRTGPref(@"telegramSendVideo", @YES) boolValue];
    if ([kind isEqualToString:@"photo"]) return [VCRTGPref(@"telegramSendPhoto", @NO) boolValue];
    return NO;
}

// kind -> (api method, multipart field name)
static void VCRTGEndpoint(NSString *kind, NSString **method, NSString **field) {
    if ([kind isEqualToString:@"audio"]) { *method = @"sendAudio";    *field = @"audio";    return; }
    if ([kind isEqualToString:@"video"]) { *method = @"sendVideo";    *field = @"video";    return; }
    if ([kind isEqualToString:@"photo"]) { *method = @"sendPhoto";    *field = @"photo";    return; }
    *method = @"sendDocument"; *field = @"document";
}

static void VCRTGLog(VCRTelegramLogBlock log, NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (log) log(message);
}

static void VCRTGFinish(NSDictionary *json, NSInteger status, NSString *method, VCRTelegramLogBlock log) {
    if (status == 200 && [json[@"ok"] boolValue]) { VCRTGLog(log, @"telegram: %@ ok", method); return; }
    NSString *description = json[@"description"] ?: @"(no description)";
    VCRTGLog(log, @"telegram: %@ failed status=%ld %@", method, (long)status, description);
}

static void VCRTGPostRequest(NSURLRequest *request, NSURL *bodyFile, NSString *method, VCRTelegramLogBlock log) {
    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
    NSURLSessionUploadTask *task = [session uploadTaskWithRequest:request fromFile:bodyFile
                                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (bodyFile) [[NSFileManager defaultManager] removeItemAtURL:bodyFile error:nil];
        if (error) { VCRTGLog(log, @"telegram: %@ failed %@", method, error.localizedDescription); return; }
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        NSDictionary *json = nil;
        if (data.length) json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        VCRTGFinish(json, status, method, log);
    }];
    [task resume];
}

void VCRTelegramSendText(NSString *text, VCRTelegramLogBlock log) {
    NSString *token = VCRTGToken();
    NSString *chat = VCRTGChat();
    if (token.length == 0 || chat.length == 0) { VCRTGLog(log, @"telegram: not configured"); return; }

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.telegram.org/bot%@/sendMessage", token]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *payload = @{ @"chat_id": chat, @"text": text ?: @"VolumeChordRecorder test" };
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    NSURLSessionUploadTask *task = [[NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]]
        uploadTaskWithRequest:request fromData:request.HTTPBody
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) { VCRTGLog(log, @"telegram: sendMessage failed %@", error.localizedDescription); return; }
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            VCRTGFinish(json, status, @"sendMessage", log);
        }];
    [task resume];
}

BOOL VCRTelegramSendFile(NSURL *fileURL, NSString *kind, VCRTelegramLogBlock log) {
    if (!fileURL) return NO;
    if (!VCRTelegramIsEnabled()) { VCRTGLog(log, @"telegram: disabled or unconfigured, skipping %@", fileURL.lastPathComponent); return NO; }
    if (!VCRTelegramWantsKind(kind)) { VCRTGLog(log, @"telegram: kind %@ turned off, skipping", kind); return NO; }

    NSNumber *size = nil;
    [fileURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    unsigned long long bytes = size.unsignedLongLongValue;
    if (bytes == 0) { VCRTGLog(log, @"telegram: %@ is missing or empty", fileURL.lastPathComponent); return NO; }
    if (bytes > VCRTelegramMaxUploadBytes) {
        VCRTGLog(log, @"telegram: skipped %@ (%.1f MB over the %.0f MB bot limit)",
                 fileURL.lastPathComponent, bytes / 1048576.0, VCRTelegramMaxUploadBytes / 1048576.0);
        return NO;
    }

    NSString *method = nil, *field = nil;
    VCRTGEndpoint(kind, &method, &field);
    NSString *token = VCRTGToken();
    NSString *chat = VCRTGChat();
    NSString *boundary = @"----VolumeChordRecorderBoundary";

    // Build the multipart body in a temp file (not NSMutableData) so a large clip does not have to
    // fit in memory twice.
    NSMutableData *prologue = [NSMutableData data];
    [prologue appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n%@\r\n", boundary, chat] dataUsingEncoding:NSUTF8StringEncoding]];
    [prologue appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\n%@\r\n", boundary, fileURL.lastPathComponent] dataUsingEncoding:NSUTF8StringEncoding]];
    [prologue appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"%@\"; filename=\"%@\"\r\nContent-Type: application/octet-stream\r\n\r\n", boundary, field, fileURL.lastPathComponent] dataUsingEncoding:NSUTF8StringEncoding]];
    NSData *epilogue = [[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding];

    NSString *bodyPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"VCRTelegramBody.tmp"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:bodyPath error:nil];
    if (![fm createFileAtPath:bodyPath contents:prologue attributes:nil]) {
        VCRTGLog(log, @"telegram: cannot create body file"); return NO;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:bodyPath];
    NSFileHandle *source = [NSFileHandle fileHandleForReadingAtPath:fileURL.path];
    if (!handle || !source) {
        [handle closeFile]; [source closeFile];
        VCRTGLog(log, @"telegram: cannot read %@", fileURL.path); return NO;
    }
    @try {
        while (YES) {
            @autoreleasepool {
                NSData *chunk = [source readDataOfLength:1 << 20];
                if (chunk.length == 0) break;
                [handle writeData:chunk];
            }
        }
        [handle writeData:epilogue];
    } @catch (NSException *exception) {
        VCRTGLog(log, @"telegram: body build failed %@", exception.reason);
        [handle closeFile]; [source closeFile];
        [fm removeItemAtPath:bodyPath error:nil];
        return NO;
    }
    [handle closeFile]; [source closeFile];

    unsigned long long bodyBytes = [[fm attributesOfItemAtPath:bodyPath error:nil] fileSize];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.telegram.org/bot%@/%@", token, method]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"%llu", bodyBytes] forHTTPHeaderField:@"Content-Length"];

    VCRTGLog(log, @"telegram: uploading %@ (%llu bytes) via %@", fileURL.lastPathComponent, bodyBytes, method);
    VCRTGPostRequest(request, [NSURL fileURLWithPath:bodyPath], method, log);
    return YES;
}
```

5.3 `Makefile`: add the source file.

```make
VolumeChordRecorder_FILES = Tweak.xm VCRTelegramUploader.m
```

5.4 Wire the call sites in `Tweak.xm`.

(a) Include the header next to the other imports at the top of `Tweak.xm`:

```objc
#import "VCRTelegramUploader.h"
```

(b) Hand the uploader the tweak's debug log, once, at the top of the `%ctor` body (right after
`VCRLoadPrefs();` around Tweak.xm:1550) — and handle the two Settings buttons there too:

```objc
        // Telegram uploads report into the same CFPreferences debug log the Settings pane shows.
        VCRTelegramSetLogger(^(NSString *message) { VCRDebugEvent(message); });

        notify_register_dispatch("com.yourname.volumechordrecorder.telegramtest", &telegramTestToken, dispatch_get_main_queue(), ^(__unused int t) {
            VCRTelegramSendText([NSString stringWithFormat:@"VolumeChordRecorder test from %@", [[UIDevice currentDevice] name]], nil);
        });
        notify_register_dispatch("com.yourname.volumechordrecorder.telegramsendlatest", &telegramLatestToken, dispatch_get_main_queue(), ^(__unused int t) {
            NSURL *newest = VCRNewestRecordingURL();
            if (!newest) { VCRDebugEvent(@"telegram: no recording found"); return; }
            VCRTelegramSendFile(newest, VCRTelegramKindForPath(newest.path), nil);
        });
```

This needs two additions to the header/implementation (keep them tiny and in the uploader where the
data lives):

Add to `VCRTelegramUploader.h`:
```objc
void VCRTelegramSetLogger(VCRTelegramLogBlock log);
NSString *VCRTelegramKindForPath(NSString *path);
```
Add to `VCRTelegramUploader.m`:
```objc
static VCRTelegramLogBlock gVCRTGLogger = nil;
void VCRTelegramSetLogger(VCRTelegramLogBlock log) { gVCRTGLogger = [log copy]; }

NSString *VCRTelegramKindForPath(NSString *path) {
    NSString *ext = path.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"m4a"]) return @"audio";
    if ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"]) return @"video";
    if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"] || [ext isEqualToString:@"png"]) return @"photo";
    return @"document";
}
```
(`VCRTelegramSendText(..., nil)` then still logs, because `VCRTGLog` falls back to
`gVCRTGLogger` — implement `VCRTGLog` as `VCRTelegramLogBlock handler = log ?: gVCRTGLogger;`.)

(c) Reported completion points. Add a small helper near `VCRRecordingDirectory()`
(Tweak.xm:289):

```objc
// Newest media file in the recordings folder - used by the Settings "Send Latest Recording" button.
static NSURL *VCRNewestRecordingURL(void) {
    NSURL *dir = [NSURL fileURLWithPath:VCRRecordingDirectory() isDirectory:YES];
    NSArray<NSURL *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:dir
                                                           includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                                              options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                error:nil];
    NSURL *newest = nil; NSDate *newestDate = nil;
    NSSet<NSString *> *exts = [NSSet setWithArray:@[@"m4a", @"mp4", @"mov", @"jpg", @"jpeg", @"png"]];
    for (NSURL *url in files) {
        if (![exts containsObject:url.pathExtension.lowercaseString]) continue;
        NSDate *modified = nil;
        [url getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
        if (!newest || [modified compare:newestDate] == NSOrderedDescending) { newest = url; newestDate = modified; }
    }
    return newest;
}

static void VCRUploadFinishedCapture(NSURL *fileURL) {
    if (!fileURL) return;
    VCRTelegramSendFile(fileURL, VCRTelegramKindForPath(fileURL.path), nil);
}
```

(d) Audio: `AVAudioRecorder`'s delegate is currently never set, so nothing tells us when the m4a is
finalized. Add a delegate and use it as the upload trigger.

Add near `VCRPhotoCaptureDelegate` (Tweak.xm:548):

```objc
@interface VCRRecorderDelegate : NSObject <AVAudioRecorderDelegate>
@end

@implementation VCRRecorderDelegate
- (void)audioRecorderDidFinishRecording:(AVAudioRecorder *)recorder successfully:(BOOL)successfully {
    NSURL *url = recorder.url;
    if (!successfully || !url) { VCRDebugEvent(@"telegram: audio finish unsuccessful"); return; }
    VCRUploadFinishedCapture(url);
}
@end
```

In `VCRStartRecording()` (Tweak.xm:303-354): keep the finished URL and set the delegate.

```objc
static VCRRecorderDelegate *vcrRecorderDelegate = nil;   // add next to the other statics near line 34
```
```objc
    [recorder prepareToRecord];
    if (!vcrRecorderDelegate) vcrRecorderDelegate = [VCRRecorderDelegate new];
    recorder.delegate = vcrRecorderDelegate;
    if ([recorder record]) {
```

In `VCRStopRecording()` (Tweak.xm:356-369) keep `[recorder stop]` as the trigger and do NOT nil
`recorder` before the delegate fires — change `recorder = nil;` to keep the URL for the delegate:

```objc
static void VCRStopRecording(void) {
    if (!isRecording) return;
    if (maxRecordTimer) { [maxRecordTimer invalidate]; maxRecordTimer = nil; }
    AVAudioRecorder *stopping = recorder;   // the delegate uploads from stopping.url
    [stopping stop];
    recorder = nil;
    [[AVAudioSession sharedInstance] setActive:NO error:nil];
    isRecording = NO;
    VCRHapticStop();
    VCRLog(@"Recording stopped");
    VCRShowNotification(@"VolumeChordRecorder", @"E");
}
```

(e) Video: in `VCRMovieRecordingDelegate`
`captureOutput:didFinishRecordingToOutputFileAtURL:...` (Tweak.xm:577-604), right after the
successful move:

```objc
        if ([[NSFileManager defaultManager] moveItemAtURL:outputFileURL toURL:targetURL error:&moveError]) {
            VCRLog(@"Camera video saved: %@", target);
            VCRShowNotification(@"VolumeChordRecorder", @"Video");
            VCRUploadFinishedCapture(targetURL);
        } else {
```

(f) Photo: in `VCRPhotoCaptureDelegate`
`captureOutput:didFinishProcessingPhoto:error:` (Tweak.xm:552-...), after a successful write, add
`VCRUploadFinishedCapture([NSURL fileURLWithPath:path]);` inside the success branch (find the
existing `VCRLog(@"Camera photo saved: ...")` line and add it right after).

Verify (must be red before, green after):
```
python3 scripts/vcr_check.py
```
Expected: `OK: 29 checks, 0 failed`.

Commit:
```
git add Makefile Tweak.xm VCRTelegramUploader.h VCRTelegramUploader.m scripts/vcr_check.py
git commit -m "Telegram: upload finished audio/video/photo captures, test and send-latest paths, 50 MB guard"
```

### Task 6 — Package the postinst so installs restart SpringBoard

The repo already has `postinst` but the deb does not ship it. Add the package-level hook to the
root `Makefile` (after `include $(THEOS_MAKE_PATH)/aggregate.mk`):

```make
_SUBPROJECTS = $(SUBPROJECTS)

after-install::
	install.exec "killall -9 SpringBoard"
```

If theos is already packaging `postinst` (verify: unpack the built deb —
`python3 -c "import tarfile,io,sys; ..."` or simply `ar t packages/*.deb` shows only
`control.tar.gz`/`data.tar.lzma`, then
`python3 -c "import tarfile;s=tarfile.open('packages/x.deb');print([m.name for m in s])"`), keep the
script but make it also re-register the bundle. The check in `scripts/vcr_check.py`
(`postinst is packaged`) must pass; if theos ignores the file, declare it explicitly with
`VolumeChordRecorder_INSTALL_TARGET` / a `layout/DEBIAN/postinst` copy instead — prefer the latter:

```
mkdir -p layout/DEBIAN && cp postinst layout/DEBIAN/postinst && chmod 755 layout/DEBIAN/postinst
```

Verify after the CI build (see validation below) that the deb contains it:

```
python3 - <<'PY'
import io, tarfile
deb = "packages/com.yourname.volumechordrecorder_0.0.10_iphoneos-arm64e.deb"
raw = open(deb, "rb").read()
off, members = 8, {}
while off + 60 <= len(raw):
    head = raw[off:off+60]; off += 60
    name = head[0:16].decode().strip(); size = int(head[48:58].decode().strip())
    members[name] = raw[off:off+size]; off += size + (size % 2)
print(sorted(tarfile.open(fileobj=io.BytesIO(members["control.tar.gz"]), mode="r:gz").getnames()))
PY
```
Expected: `['./control', './postinst']` (previously `['./control']`).

Commit:
```
git add Makefile layout/DEBIAN/postinst postinst
git commit -m "Package postinst so installing the deb restarts SpringBoard"
```

### Task 7 — Shell/API plumbing: build, install, read the device back

These three scripts already exist in `C:/Users/server/Desktop/vcr_deb_20261007/` from the previous
session: `vcr_install.py`, `vcr_respring2.py`. Two things must be fixed in them, and one new script
is needed. (Paths outside the repo are intentional: they are the operator's toolbox.)

7.1 `vcr_respring2.py` must verify the restart instead of trusting "kill sent". Replace the kill
block with a PID-checked kill:

```python
def springboard_pid(c):
    _, out, _ = c.exec_command("launchctl list 2>/dev/null | awk '/com.apple.SpringBoard/{print $1}'", timeout=10)
    return (out.read().decode().strip().splitlines() or [""])[0]

before = springboard_pid(c)
print("springboard pid before: %s" % before, flush=True)
c.exec_command("sudo -S -p '' kill -9 %s" % before, timeout=8)[0].write(PASS + "\n")
print("kill sent -> %s" % before, flush=True)
```
Then, after reconnecting, assert the PID changed and print it:
```python
after = springboard_pid(c2)
print("springboard pid after: %s (%s)" % (after, "RESTARTED" if after != before else "NOT RESTARTED"))
```
Expected output on a real respring: `springboard pid before: 12345` … `springboard pid after: 23456 (RESTARTED)`.

7.2 Create `C:/Users/server/Desktop/vcr_deb_20261007/vcr_read_prefs.py` so every task has a
mechanical read-back:

```python
"""Pull the tweak's prefs domain off the device and print the keys we care about."""
import os, plistlib, subprocess, sys, tempfile

HOST = os.environ.get("KT_HOST", "100.90.218.125")
PY = sys.executable
TOOL = r"C:\Users\server\Desktop\Tweaks_Reverse\tools\ios_ssh.py"
REMOTE = "/var/mobile/Library/Preferences/com.yourname.volumechordrecorder.plist"

local = os.path.join(tempfile.gettempdir(), "vcr_prefs.plist")
for attempt in range(3):
    rc = subprocess.run([PY, TOOL, "get", REMOTE, local], capture_output=True, text=True)
    if rc.returncode == 0 and os.path.exists(local):
        break
print(plistlib.load(open(local, "rb")))
```
Run it with `SSHPASS` set and `KT_HOST` exported, exactly like `vcr_install.py`.

## Tests / validation

Per-task loop (this repo has no off-device runtime, so there are exactly three levels):

1. Static/red-green: `python3 scripts/vcr_check.py` — must show the task's lines `FAIL` before the
   edit and `PASS` after, and end `OK: N checks, 0 failed` at the end of each task.
2. Build: push and watch CI.
   ```
   git push origin main
   sleep 8
   RID=$(gh run list --limit 1 --json databaseId -q '.[0].databaseId')
   timeout 520 gh run watch $RID --exit-status --interval 15 >/dev/null 2>&1
   gh run view $RID --json conclusion -q .conclusion      # expect: success
   gh run --log-failed 2>/dev/null | grep -i "error:" | head   # expect: no output on success
   ```
   Download and stash the deb:
   ```
   OUT=C:/Users/server/Desktop/vcr_deb_20261007
   rm -f "$OUT"/*.deb && gh run download $RID --name VolumeChordRecorder-roothide-deb --dir "$OUT"
   ls "$OUT"/*.deb
   ```
3. Device: install, respring (PID-verified), then assert the debug log lines. Export once per shell:
   ```
   export KT_HOST=100.90.218.125 SSHPASS=<from the operator's env, never typed here>
   PY="C:/Users/server/AppData/Local/Programs/Python/Python314/python.exe"
   "$PY" "$OUT/vcr_install.py"        # expect: dpkg rc=0, dylib + Root.plist sizes printed
   "$PY" "$OUT/vcr_respring2.py"      # expect: springboard pid after: <new> (RESTARTED)
   ```
   Then wait for TCP 22 and read the prefs:
   ```
   for i in $(seq 1 15); do sleep 20; timeout 8 bash -c 'exec 3<>/dev/tcp/100.90.218.125/22' 2>/dev/null && break; done
   "$PY" "$OUT/vcr_read_prefs.py"
   ```
   Assertions, in order:
   - `debugLastLoadBundle` == `com.apple.springboard` (tweak is injected).
   - After opening Settings and picking 720p30 manually: `cameraVideoQuality` == `720p30` in the
     plist (proves the choice row persists — this is exactly what never worked before) and the
     debug log's last `choice cameraVideoQuality = 720p30` line.
   - `holdSeconds` present as a float within 0.2…5.0 after dragging the slider.
   - After one video capture with 720p30: `Camera: effective format 1280x720 @ 30fps` in
     "Show Debug Log" (before the fix this reported the largest format, e.g. 4032x3024/3840x2160).
   - After `Send Test (uses SpringBoard)`: `telegram: sendMessage ok`, or a specific API error
     (`status=401` bad token, `status=400` bad chat id).
   - After a capture with upload enabled and a small clip: `telegram: uploading … via sendVideo`
     then `telegram: sendVideo ok`, and the file appears in the Telegram chat.
   - After a >50 MB clip: `telegram: skipped … over the 50 MB bot limit`.

If the device goes offline after the respring (expected: it sleeps, 10+ minutes), ask the user to
press the power/side button to wake the screen, then re-run the TCP wait loop.

## Risks, tradeoffs, and open questions

- **Blocking unknown that predates this plan**: it is still unproven whether volume-button presses
  reach `-[SpringBoard pressesBegan:]` as `UIPress` type 102/103 on this iOS 16.4.1 build. The
  installed build already records every press into the debug log (`press began type=…`) and every
  `AVSystemController_SystemVolumeDidChangeNotification`. **Do this first, before task 2**: press
  volume-up, volume-down, then both together, open "Show Debug Log" and look. If `press began` never
  appears but `volchange` does, the slider is pointless until the trigger is moved to the
  AVSystemController path — that becomes a new task, not a tweak of the hold value.
- One hold-seconds value shared by audio and camera (recommended: fewer knobs, matches the current
  single-tier design). If the user wants separate values, add `holdSecondsAudio` /
  `holdSecondsCamera` and have `VCRCheckChord()` pick the base from the active chord — 20 lines,
  but it needs a decision on how tiers 2/3 scale.
- Telegram stores the bot token in plaintext in
  `/var/mobile/Library/Preferences/com.yourname.volumechordrecorder.plist` (mode 600, mobile-owned,
  outside the sandbox's reach for other apps). Keychain would be better but brings entitlement risk
  inside SpringBoard; the tradeoff is noted in the UI footer.
- 50 MB bot-API cap: 4K/60 clips hit it in seconds. The uploader skips and logs; no compression is
  attempted (YAGNI until asked).
- Uploads are plain `NSURLSession` tasks from SpringBoard — no background session, so a lock screen
  mid-upload can fail the transfer. The "Send Latest Recording" button is the manual retry.
- The bundle cannot link the tweak's uploader, so the test button goes through a Darwin
  notification and the result appears in "Show Debug Log" rather than in an immediate alert. This is
  deliberate (it exercises the real path) but is one extra tap for the user.
- Custom plist keys (`vcrKind`, `vcrKey`, `vcrTitles`, `vcrValues`) rely on PreferenceLoader passing
  unknown properties through to `PSSpecifier` — the headers confirm `propertyForKey:` is a plain
  dictionary lookup, and `loadSpecifiersFromPlistName:` copies every key into `properties`. If a
  future PL version strips them, the rows fall back to `super` rendering (visible as plain rows with
  no detail text) instead of crashing.
- `cellForRowAtIndexPath:` now returns plain `UITableViewCell`s for two row kinds; PL's own
  height/selection behaviour for those rows is bypassed. Verified as acceptable by design, but if
  row heights look wrong, add `- (CGFloat)tableView:heightForRowAtIndexPath:` returning 44.0 for the
  slider row only.
- Task 6 assumes theos honours a root `Makefile` `after-install` hook; the fallback
  (`layout/DEBIAN/postinst`) is the guaranteed path and should be used if the ar listing does not
  show `./postinst`.
