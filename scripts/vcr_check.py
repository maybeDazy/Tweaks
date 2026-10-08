#!/usr/bin/env python3
"""Static checks for the VolumeChordRecorder sources. No device needed.

Usage: python3 scripts/vcr_check.py
Prints one line per check and exits non-zero if any check failed.
"""
import os, plistlib, sys

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


# --- 0. existing behaviour that must not regress ---
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
                  ("cameraPosition", 2), ("cameraLens", 2)]:
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
check("uploader invoked from a capture completion point", has("VCRUploadFinishedCapture("))
check("audio recorder delegate added (no completion callback before)",
      has("VCRRecorderDelegate") and has("recorder.delegate = vcrRecorderDelegate;"))
check("50 MB bot limit guarded",
      has("VCRTelegramMaxUploadBytes") and has("over the %.0f MB bot limit", uploader()))
check("multipart body streamed via a temp file",
      has("uploadTaskWithRequest:request fromFile:bodyFile", uploader()))
check("telegram notifications registered by the tweak",
      has("com.yourname.volumechordrecorder.telegramtest") and
      has("com.yourname.volumechordrecorder.telegramsendlatest"))

# --- 6. packaging ---
check("postinst is packaged (after-install hook or layout/DEBIAN/postinst)",
      "after-install" in UP or os.path.exists(os.path.join(ROOT, "layout", "DEBIAN", "postinst")))

failed = [(n, d) for n, ok, d in checks if not ok]
for name, ok, detail in checks:
    print("%s %s%s" % ("PASS" if ok else "FAIL", name,
                       ("  <- " + detail[:150]) if (not ok and detail) else ""))
print("\n%s: %d checks, %d failed" % ("OK" if not failed else "FAILED", len(checks), len(failed)))
sys.exit(1 if failed else 0)
