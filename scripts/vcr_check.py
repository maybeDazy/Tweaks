#!/usr/bin/env python3
"""Static checks for the VolumeChordRecorder sources. No device needed.

Usage: python3 scripts/vcr_check.py
Prints one line per check and exits non-zero if any check failed.
"""
import os, plistlib, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T = open(os.path.join(ROOT, "Tweak.xm"), encoding="utf-8").read()
MM = open(os.path.join(ROOT, "Preferences", "VCRRootListController.mm"), encoding="utf-8").read()
PLIST_PATH = os.path.join(ROOT, "Preferences", "Resources", "Root.plist")
PLIST = plistlib.load(open(PLIST_PATH, "rb"))
UP = open(os.path.join(ROOT, "Makefile"), encoding="utf-8").read()
CELLS = [c for c in PLIST.get("items", PLIST) if isinstance(c, dict)]

checks = []


def check(name, ok, detail=""):
    checks.append((name, bool(ok), detail))


def cell_for_key(key):
    for c in CELLS:
        if c.get("key") == key:
            return c
    return None


def has(needle, src=None):
    if src is None:
        src = T
    return needle in src


def order(first, second, src=None):
    if src is None:
        src = T
    a, b = src.find(first), src.find(second)
    return a != -1 and b != -1 and a < b


def uploader():
    path = os.path.join(ROOT, "VCRTelegramUploader.m")
    return open(path, encoding="utf-8").read() if os.path.exists(path) else ""


def balanced(src):
    src = re.sub(r'@?"(\\.|[^"\\\n])*"', '""', src)   # strip strings first: // inside a URL is not a comment
    src = re.sub(r"'(\\.|[^'\\\n])*'", "''", src)
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    src = re.sub(r"//[^\n]*", "", src)
    return (src.count("{") - src.count("}") == 0 and
            src.count("(") - src.count(")") == 0 and
            src.count("[") - src.count("]") == 0)


# --- 0. structure and existing behaviour that must not regress ---
check("Tweak.xm delimiters balanced", balanced(T))
check("prefs bundle delimiters balanced", balanced(MM))
check("Logos hooks balanced (%%hook == %%end minus %%group)",
      len(re.findall(r"^%hook ", T, re.M)) + len(re.findall(r"^%group", T, re.M)) == len(re.findall(r"^%end", T, re.M)),
      "%%hook=%%group=%%end must match or nothing compiles")
check("prefs domain unchanged", has('"com.yourname.volumechordrecorder"', MM))
check("prefs notification name unchanged", has("com.yourname.volumechordrecorder.prefschanged"))
check("CFPreferences debug recorder still present", has("static void VCRDebugEvent"))
check("bundle still overrides setPreferenceValue:specifier:",
      has("- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier", MM))
check("bundle reads prefs through CFPreferences, not NSUserDefaults",
      "NSUserDefaults" not in MM,
      "the bundle id is com.volumechordrecorder.preferences, so standardUserDefaults is the Settings app domain")

# --- 1. video quality ---
check("exact-format helper exists", has("VCRCameraApplyVideoFormat"))
check("target resolution table exists", has("VCRVideoTarget"))
check("format applied after the movie output is added (preset no longer wins)",
      order("canAddOutput:vcrMovieOutput", "VCRCameraApplyVideoFormat(device);"))
check("effective format is logged", has("Camera: video preset=") and has("Camera: effective format"))
check("hold seconds floor is 0.2, not 0.0", 'VCRDoublePref(@"holdSeconds", 2.0, 0.2' in T)

# --- 2. slider row ---
check("slider row dispatch present", has('"vcrKind"', MM))
check("slider changed handler present", has("vcrSliderChanged:", MM))
check("slider commit handler present", has("vcrSliderCommitted:", MM))
check("prefs-bundle debug logger present", has("static void VCRPrefsLog", MM))
check("choice action sheet present", has("vcrPresentChoicesForSpecifier", MM))
check("cellForRowAtIndexPath override present",
      has("- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath", MM))
check("didSelectRowAtIndexPath override present",
      has("- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath", MM))

c = cell_for_key("holdSeconds")
check("holdSeconds is a slider row", c and c.get("vcrKind") == "slider", repr(c))
check("holdSeconds slider bounds 0.2..5.0",
      c and float(c.get("vcrMin", 0)) == 0.2 and float(c.get("vcrMax", 0)) == 5.0, repr(c))
check("holdSeconds is no longer a text cell", c and c.get("cell") != "PSEditTextCell", repr(c))

# --- 3. choice rows ---
for key, want in [("cameraVideoQuality", 6), ("cameraPhotoQuality", 3),
                  ("cameraPosition", 2), ("cameraLens", 2), ("hapticStrength", 3)]:
    c = cell_for_key(key)
    check("choice row %s present with %d titles" % (key, want),
          c and c.get("vcrKind") == "choice" and len(c.get("vcrTitles", [])) == want
          and len(c.get("vcrValues", [])) == len(c.get("vcrTitles", [])), repr(c))
    check("choice row %s is no longer PSMultiValueSpecifier" % key,
          c and c.get("cell") != "PSMultiValueSpecifier", repr(c))
check("no PSMultiValueSpecifier cells left",
      not any(c.get("cell") == "PSMultiValueSpecifier" for c in CELLS))
check("video quality values kept from before",
      (cell_for_key("cameraVideoQuality") or {}).get("vcrValues") ==
      ["720p30", "1080p30", "1080p60", "4k30", "4k60", "auto"])

# --- 4. telegram settings ---
check("telegram settings cells exist",
      all(cell_for_key(k) for k in ["telegramEnabled", "telegramBotToken", "telegramChatID",
                                    "telegramSendAudio", "telegramSendVideo", "telegramSendPhoto"]))
check("telegram test button wired", any(c.get("action") == "sendTelegramTest" for c in CELLS))
check("telegram send-latest button wired", any(c.get("action") == "sendTelegramLatest" for c in CELLS))
check("telegram buttons are implemented in the bundle",
      has("sendTelegramTest", MM) and has("sendTelegramLatest", MM))

# --- 5. telegram uploader ---
check("uploader source exists", os.path.exists(os.path.join(ROOT, "VCRTelegramUploader.m")))
check("uploader compiled into the tweak",
      "VolumeChordRecorder_FILES = Tweak.xm VCRTelegramUploader.m" in UP)
check("uploader header included by the tweak", has('#import "VCRTelegramUploader.h"'))
check("uploader header is C++-safe (Tweak.xm compiles as Objective-C++)",
      'extern "C"' in open(os.path.join(ROOT, "VCRTelegramUploader.h"), encoding="utf-8").read())
check("uploader invoked from a capture completion point", has("VCRUploadFinishedCapture("))
check("audio recorder delegate added (no completion callback before)",
      has("VCRRecorderDelegate") and has("recorder.delegate = vcrRecorderDelegate;"))
check("50 MB bot limit guarded",
      has("VCRTelegramMaxUploadBytes", uploader()) and has("over the %.0f MB bot limit", uploader()))
check("multipart body streamed via a temp file",
      has("uploadTaskWithRequest:request fromFile:", uploader()) and
      has("seekToEndOfFile", uploader()))
check("volume chord hooks the real SpringBoard class read off the device",
      has("SBVolumeHardwareButtonActions") and has("volumeIncreasePressDownWithModifiers:")
      and has("volumeIncreasePressUp") and has("volumeDecreasePressDownWithModifiers:")
      and has("volumeDecreasePressUp"))
check("volume button hooks are feature-checked before %init",
      'if (objc_getClass("SBVolumeHardwareButtonActions")) %init(VCRVolumeButtonHooks);' in T)
check("trigger diagnostics aggregate press types and volume reasons",
      has("VCRDebugBump") and has('VCRDebugBump(@"debugPressTypes"') and has('VCRDebugBump(@"debugVolchg"'))
check("volume API is read from the device instead of guessed",
      has("VCRDumpVolumeAPI") and has("objc_copyClassList") and has("debugVolumeAPI"))
check("telegram notifications registered by the tweak",
      has("com.yourname.volumechordrecorder.telegramtest") and
      has("com.yourname.volumechordrecorder.telegramsendlatest"))

# --- 5b. regressions that were reported from the device ---
# A CFUserNotificationDisplayNotice with timeout 0 and no default button is modal and can never be
# dismissed ("REC would not turn off"), and it eats touches until a respring.
check("no undismissable modal alert is used for on-screen notices",
      "CFUserNotificationDisplayNotice" not in T)
check("on-screen notice is a non-interactive, self-hiding HUD",
      has("vcrHUDWindow") and has("userInteractionEnabled = NO") and has("VCRHUDHide"))
check("notice window attaches to a scene (iOS 13+ would not render otherwise)",
      has("window.windowScene = (UIWindowScene *)scene"))
# Stopping a running capture must not require holding the chord long enough to open a tier.
check("any chord release stops a running capture",
      has("vcrChordPressed") and has("if (chordWasPressed && (vcrCameraRecording || isRecording))"))
check("video stop also trusts the file output, not only the flag",
      has("AVCaptureMovieFileOutput *output = vcrMovieOutput;") and has("output.isRecording"))
check("REC is announced only after the recording actually starts",
      order("startRecordingToOutputFileURL:", 'VCRShowNotification(@"VolumeChordRecorder", @"REC")') and
      has('VCRShowNotification(@"VolumeChordRecorder", @"Video failed")'))
check("tweak decisions reach the prefs ring (the file log is sandbox-denied)",
      has("VCRDebugEvent(msg);") and has("VCRRingWorthy"))
check("the prefs ring is long enough to hold a chord sequence", has("lines.count > 14"))
check("prefs bundle records why Settings aborted",
      "NSSetUncaughtExceptionHandler" in MM and "PREFS CRASH" in MM)
check("choice sheet keeps the popover path off the phone",
      "UIUserInterfaceSizeClassRegular" in MM)
# --- 5c. saving was impossible: /var/mobile/Media does not exist on the device ---
check("the captures directory is chosen at runtime, not hard-coded",
      has("static NSString *VCRRecordingDirectory(void) {") and has("write-probe") and
      has("vcrRecordingsDir") and not has('static NSString *VCRRecordingDirectory(void) { return'))
check("the preferences bundle follows the directory the tweak published",
      "VCRRecordingsDirPath()" in MM and "VCRPrefsValue" in MM)
# --- 5d. SpringBoard died (safe mode) with no crash report: collect the reason ourselves ---
# The device went into safe mode because AVFoundation raised, and the exception escaped to kill
# SpringBoard: the requested photo prioritisation must never exceed what the output allows.
check("photo prioritisation is clamped to what the output allows",
      has("MIN(VCRCameraPhotoQualityValue(), vcrPhotoOutput.maxPhotoQualityPrioritization)"))
check("the photo capability is raised when the output is created",
      has("maxPhotoQualityPrioritization = AVCapturePhotoQualityPrioritizationQuality"))
check("photo and video capture cannot let an exception escape",
      has("Camera photo exception") and has("Camera video exception"))
check("the tweak catches its own exceptions and fatal signals",
      has("NSSetUncaughtExceptionHandler(&VCRExceptionHandler)") and has("VCRSignalHandler") and
      has("tweak fatal signal") and has("TWEAK CRASH"))
# Device evidence: a simultaneous volume-up+down press arrives as ONE UIPress of type 104 - never
# as 102/103 - and with releases for both buttons but no press-down, so the chord must accept it.
# Type 104 is the power button on this device. Arming the chord from it made the tweak fire from the
# power button, so the chord must only ever be armed by the two volume press types (or their hooks).
# The trigger path has to stay provable from one SSH read: the ring is overwritten within seconds and
# the capture folder is invisible to a plain shell, so these keys carry the evidence instead.
check("the trigger path keeps sticky per-attempt evidence",
      has('VCRStickyNote(@"debugLastChordArmed"') and has('VCRStickyNote(@"debugLastChordRelease"')
      and has('VCRStickyNote(@"debugLastAction"') and has('VCRStickyNote(@"debugLastCapture"'))
check("every capture type reports its size",
      has('(unsigned long long)[vcrAttributes fileSize]')
      and has('path.lastPathComponent, (unsigned long)imageData.length')
      and has('(unsigned long long)[vcrVideoAttributes fileSize]'))
check("only volume presses reach the ring",
      has("if (VCRPressTypeIsVolumeUp(type) || VCRPressTypeIsVolumeDown(type)) VCRLog(@\"press ended")
      and has("VCRDebugBump(@\"debugOtherPresses\", @\"power\")"))
check("the power button cannot arm the chord",
      has("VCR_PRESS_TYPE_POWER 104")
      and has("// The power button must never arm the chord")
      and has('VCRDebugBump(@"debugOtherPresses", @"power")')
      and (not has("vcrChordConsolidatedPress")))
check("every volume hook counts itself before calling the original",
      has('VCRDebugBump(@"debugVolumeSelectors", @"increaseDown")')
      and has('VCRDebugBump(@"debugVolumeSelectors", @"decreaseUp")'))
# Logos will not compile %orig inside an ObjC exception block, and skipping %orig entirely would
# take the system's own volume handling away with it.
check("every volume hook still runs the original handling",
      has('VCRDebugBump(@"debugVolumeSelectors", @"increaseDown");\n    %orig;')
      and has('VCRDebugBump(@"debugVolumeSelectors", @"decreaseUp");\n    %orig;'))
check("no hook wraps %orig in an exception block",
      not has("@try { %orig; }"))
# Changing any option posts prefschanged, and that handler runs inside SpringBoard.
check("the settings-changed handler is guarded and records its steps",
      has("prefs changed -> reload") and has("PREFS CHANGED CRASH"))
check("the Notification Center re-apply cannot re-enter or storm the main thread",
      has("vcrNCApplyInFlight") and has("vcrNCApplyAgain") and has("NC apply exception"))
check("the finished capture reports its size",
      has("(unsigned long long)[vcrAttributes fileSize]"))
check("the fatal-signal log is written where SpringBoard can write",
      has("tweak-crash.log") and has("VCRRecordingDirectory() stringByAppendingPathComponent"))
check("signal handlers are installed in the initialiser",
      has("signal(signals[index], VCRSignalHandler)"))
# --- 5e. hooks must not be able to take the process down ---
check("volume hooks run the original first and wrap their own work",
      order("%orig;", "VCRVolumeButtonEvent(YES, YES)") and has("@catch (NSException *exception)"))
check("press hooks are wrapped in @try",
      has("press hook exception") and has("press cancel exception"))
check("press type 104 is identified from the real press object",
      has("[press description]"))
check("camera quality rows and the hold slider are real prefs rows",
      cell_for_key("cameraVideoQuality") is not None and cell_for_key("cameraPhotoQuality") is not None
      and cell_for_key("holdSeconds") is not None and
      (cell_for_key("cameraVideoQuality") or {}).get("vcrKind") == "choice" and
      (cell_for_key("holdSeconds") or {}).get("vcrKind") == "slider")

# --- 5c. chord trigger ported from the SneakyCam reverse engineering ---
# SparkRecorder decides its chord from increaseLastPressed/decreaseLastPressed (a timestamp gap), not
# from the buttons being held at the same instant; and it hooks SBVolumeControl, not the press pair.
_pair_window = re.search(r"VCRChordPairWindow\s*=\s*([0-9.]+)", T)
check("the paired-press window is a small bounded constant",
      _pair_window is not None and 0.05 <= float(_pair_window.group(1)) <= 1.0)
check("both buttons remember when they last went down",
      has("vcrVolumeUpPressedAt = now") and has("vcrVolumeDownPressedAt = now"))
check("paired presses arm the chord inside the press branch (never on a release)",
      re.search(r"if \(isDown\) \{[\s\S]{0,1000}<= VCRChordPairWindow\)\s*\{\s*"
                r"volumeUpPressed = YES;\s*volumeDownPressed = YES;", T) is not None)
check("the pair-forced flags are cleared when the chord resolves",
      re.search(r"volumeUpPressed = NO;\s*volumeDownPressed = NO;\s*\n\s*// Stopping must never depend",
                T) is not None)
check("SBVolumeControl is hooked as a second trigger source",
      has("%group VCRVolumeControlHooks") and has("- (void)increaseVolume {")
      and has("- (void)decreaseVolume {"))
check("the SBVolumeControl group is registered behind an objc_getClass guard",
      has('if (objc_getClass("SBVolumeControl")) %init(VCRVolumeControlHooks);'))
_iv = T[T.find("- (void)increaseVolume {"):][:200]
_dv = T[T.find("- (void)decreaseVolume {"):][:200]
check("SBVolumeControl hooks run the original before our handler",
      order('VCRDebugBump(@"debugVolumeSelectors", @"increaseVolumeIntent");', "%orig;", _iv)
      and order("%orig;", "VCRVolumeButtonEvent(YES, YES);", _iv)
      and order('VCRDebugBump(@"debugVolumeSelectors", @"decreaseVolumeIntent");', "%orig;", _dv)
      and order("%orig;", "VCRVolumeButtonEvent(NO, YES);", _dv))

# --- 5d. no hook may swallow the original implementation ---
# A %hook body that never calls %orig replaces a system method with nothing. If a caller waits on
# that method's side effects the whole process stops, and the failure only shows up on the iOS
# builds whose call order needs it - so it is banned here rather than diagnosed later.
_hook_blocks, _cur, _start = [], None, 0
for _n, _ln in enumerate(T.split("\n"), 1):
    _s = _ln.strip()
    if _s.startswith("%hook ") and _cur is None:
        _cur, _start = _s[6:].strip(), _n
    elif _s == "%end" and _cur is not None:
        _hook_blocks.append((_cur, _start, _n, "\n".join(T.split("\n")[_start - 1:_n])))
        _cur = None
_swallow = [(c, s) for c, s, e, body in _hook_blocks if "%orig" not in body]
check("every %hook passes the original call through",
      len(_hook_blocks) >= 12 and not _swallow,
      "hook blocks=%d, without %%orig: %s" % (len(_hook_blocks), _swallow))

# --- 6. packaging ---
check("postinst is packaged (after-install hook or layout/DEBIAN/postinst)",
      "after-install" in UP or os.path.exists(os.path.join(ROOT, "layout", "DEBIAN", "postinst")))

failed = [(n, d) for n, ok, d in checks if not ok]
for name, ok, detail in checks:
    print("%s %s%s" % ("PASS" if ok else "FAIL", name,
                       ("  <- " + detail[:150]) if (not ok and detail) else ""))
print("\n%s: %d checks, %d failed" % ("OK" if not failed else "FAILED", len(checks), len(failed)))
sys.exit(1 if failed else 0)
