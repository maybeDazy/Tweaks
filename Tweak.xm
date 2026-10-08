#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <notify.h>
#import <math.h>
#import <objc/runtime.h>
#import <string.h>
#import "VCRTelegramUploader.h"
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
static NSString * const VCRPrefsID = @"com.yourname.volumechordrecorder";
static NSString * const VCRPrefix = @"[VolumeChordRecorder]";

static BOOL vcrEnabled = YES;
static BOOL vcrHaptics = YES;
static BOOL vcrLogPresses = NO;
static NSTimeInterval vcrHoldSeconds = 2.0;
static NSTimeInterval vcrMaxRecordSeconds = 600.0;
static BOOL vcrVolumeChordTrigger = NO;
static BOOL vcrThreeFingerSwipeDownTrigger = YES;
static CGFloat vcrThreeFingerSwipeDistance = 140.0;
static BOOL vcrLogGestures = NO;
static BOOL vcrHapticOnStart = YES;
static BOOL vcrHapticOnStop = YES;
static NSInteger vcrHapticStrength = 1;   // 0 light / 1 medium / 2 strong

static BOOL vcrNCTransparencyEnabled = NO;
static CGFloat vcrNCWallpaperAlpha = 0.00;
static CGFloat vcrNCBlurAlpha = 0.12;
static CGFloat vcrNCDimAlpha = 0.00;
static BOOL vcrNCLogViews = NO;
static NSTimeInterval vcrLastNCTransparencyBurst = 0.0;

static BOOL volumeUpPressed = NO;
static BOOL volumeDownPressed = NO;
static BOOL vcrChordPressed = NO;   // both buttons went down, even for a tap shorter than a tier
static NSTimer *holdTimer = nil;
static NSTimer *maxRecordTimer = nil;
static AVAudioRecorder *recorder = nil;
static AVAudioRecorder *vcrStoppingRecorder = nil;   // kept alive until the delegate reports the file
static BOOL isRecording = NO;
@class VCRRecorderDelegate;
static VCRRecorderDelegate *vcrRecorderDelegate = nil;
static int vcrTelegramTestToken = 0;
static int vcrTelegramLatestToken = 0;

// --- Camera capture (photo / video) ---
// Trigger: Volume Up + Volume Down chord (hold past holdSeconds then release = photo,
// keep holding to 2x holdSeconds = video start/stop). A 4-finger swipe is kept as an
// optional alternative. Runs inside SpringBoard, so camera access depends on
// SpringBoard's TCC authorization, not the tweak's.
static BOOL vcrCameraEnabled = NO;
static BOOL vcrCameraChordTrigger = YES;
static BOOL vcrCameraSwipeTrigger = NO;
static CGFloat vcrCameraSwipeDistance = 140.0;
static NSInteger vcrCameraFingerCount = 4;
// Device/quality selection. String-valued prefs so the Settings lists round-trip cleanly
// (integer-valued PSMultiValueSpecifier cells did not stick and always showed one title).
static NSString *vcrCameraPosition = @"back";        // back | front
static NSString *vcrCameraLens = @"wide";            // wide (1x) | ultrawide (0.5x), back only
static NSString *vcrCameraVideoQuality = @"1080p30"; // 720p30 | 1080p30 | 1080p60 | 4k30 | 4k60 | auto
static NSString *vcrCameraPhotoQuality = @"quality"; // speed | balanced | quality
// Chord tiers by hold time (H = Hold Seconds), decided on RELEASE so a long hold never
// fires two actions: [H,2H) => photo, [2H,3H) => video toggle, >=3H => audio toggle.
// While anything is recording the chord always means STOP, at any tier.
static NSInteger vcrChordStage = 0;   // 0 idle, 1 past H, 2 past 2H, 3 past 3H
static NSTimer *chordTimer2 = nil;
static NSTimer *chordTimer3 = nil;
static AVCaptureSession *vcrCaptureSession = nil;
static AVCapturePhotoOutput *vcrPhotoOutput = nil;
static AVCaptureMovieFileOutput *vcrMovieOutput = nil;
static BOOL vcrCameraRecording = NO;
static BOOL vcrCameraAuthorized = NO;
static dispatch_queue_t vcrCaptureQueue = nil;
static NSTimer *vcrMaxVideoTimer = nil;
static NSString *vcrCurrentVideoPath = nil;

#ifndef VCR_PRESS_TYPE_VOLUME_UP
#define VCR_PRESS_TYPE_VOLUME_UP 102
#endif
#ifndef VCR_PRESS_TYPE_VOLUME_DOWN
#define VCR_PRESS_TYPE_VOLUME_DOWN 103
#endif

static BOOL VCRPressTypeIsVolumeUp(NSInteger type) { return type == VCR_PRESS_TYPE_VOLUME_UP; }
static BOOL VCRPressTypeIsVolumeDown(NSInteger type) { return type == VCR_PRESS_TYPE_VOLUME_DOWN; }

static NSString *VCRDebugLogPath(void) {
    return @"/var/mobile/Library/Caches/VolumeChordRecorder.log";
}

// NSLog only reaches the unified log, which cannot be read on a device without a syslog
// tool (and cannot be read over SSH at all). Mirror every line to a file so it is possible
// to prove the tweak loaded and to see exactly which trigger fired. Capped at 512 KB.
static void VCRAppendLogLine(NSString *msg) {
    static NSDateFormatter *stampFormatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stampFormatter = [NSDateFormatter new];
        stampFormatter.dateFormat = @"HH:mm:ss.SSS";
    });

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [stampFormatter stringFromDate:[NSDate date]], msg];
    NSString *path = VCRDebugLogPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    @try {
        unsigned long long size = [handle seekToEndOfFile];
        if (size > 512ULL * 1024ULL) {
            [handle closeFile];
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }
    } @catch (__unused NSException *exception) {
        [handle closeFile];
    }
}

static void VCRDebugEvent(NSString *msg);   // defined below; VCRLog mirrors into the same ring

// Only the trigger/capture story belongs in the ring. The notification-center transparency code
// logs once per view and per window ("Applying NC transparency to window ..."), which buried the
// chord decisions and turned every one of those lines into a preferences write.
static BOOL VCRRingWorthy(NSString *message) {
    static NSArray<NSString *> *keywords = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[@"chord", @"Chord", @"Camera", @"camera", @"Record", @"record",
                     @"press", @"Press", @"Telegram", @"telegram", @"PREFS CRASH", @"HUD"];
    });
    for (NSString *keyword in keywords) {
        if ([message rangeOfString:keyword].location != NSNotFound) return YES;
    }
    return NO;
}

static void VCRLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"%@ %@", VCRPrefix, msg);
    VCRAppendLogLine(msg);
    // SpringBoard's sandbox denies the file above, so the only place these lines can actually be
    // read back is the preferences ring that "Show Debug Log" prints. The notification-center view
    // hooks fire for every touched view (hundreds of lines a minute), which would both drown the
    // ring and turn every one of them into a preferences write, so keep those out of the ring.
    if (VCRRingWorthy(msg)) VCRDebugEvent(msg);
}

// Diagnostic recorder for trigger plumbing. File writes are silently denied by SpringBoard's
// sandbox, so events go through CFPreferences instead - that always succeeds from SpringBoard
// and can be read back over SSH or from the Settings pane. Keeps a short rolling history.
static void VCRDebugEvent(NSString *msg) {
    static NSDateFormatter *vcrDebugFormatter = nil;
    static dispatch_once_t vcrDebugOnce;
    dispatch_once(&vcrDebugOnce, ^{
        vcrDebugFormatter = [NSDateFormatter new];
        vcrDebugFormatter.dateFormat = @"HH:mm:ss.SSS";
    });

    NSString *line = [NSString stringWithFormat:@"%@ %@", [vcrDebugFormatter stringFromDate:[NSDate date]], msg];
    CFStringRef domain = (__bridge CFStringRef)VCRPrefsID;

    long count = 0;
    CFPropertyListRef rawCount = CFPreferencesCopyAppValue(CFSTR("debugEventCount"), domain);
    if (rawCount) {
        if (CFGetTypeID(rawCount) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)rawCount, kCFNumberLongType, &count);
        CFRelease(rawCount);
    }
    count += 1;
    CFNumberRef newCount = CFNumberCreate(NULL, kCFNumberLongType, &count);
    CFPreferencesSetAppValue(CFSTR("debugEventCount"), newCount, domain);
    CFRelease(newCount);
    CFPreferencesSetAppValue(CFSTR("debugLastEvent"), (__bridge CFStringRef)line, domain);

    NSString *previous = nil;
    CFPropertyListRef rawHistory = CFPreferencesCopyAppValue(CFSTR("debugEvents"), domain);
    if (rawHistory) {
        if (CFGetTypeID(rawHistory) == CFStringGetTypeID()) previous = [NSString stringWithString:(__bridge NSString *)rawHistory];
        CFRelease(rawHistory);
    }
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *existing in [previous componentsSeparatedByString:@"\n"]) {
        if (existing.length > 0) [lines addObject:existing];
    }
    [lines addObject:line];
    while (lines.count > 14) [lines removeObjectAtIndex:0];
    CFPreferencesSetAppValue(CFSTR("debugEvents"), (__bridge CFStringRef)[lines componentsJoinedByString:@"\n"], domain);
    CFPreferencesAppSynchronize(domain);
}

// Aggregates trigger plumbing into a "label=count label=count" string so a single prefs read can
// prove which press types and which volume-change reasons actually arrive - the 8-line ring buffer
// above is too short to answer that.
static void VCRDebugBump(NSString *prefKey, NSString *label) {
    if (!label) return;
    CFStringRef domain = (__bridge CFStringRef)VCRPrefsID;

    NSString *existing = nil;
    CFPropertyListRef raw = CFPreferencesCopyAppValue((__bridge CFStringRef)prefKey, domain);
    if (raw) {
        if (CFGetTypeID(raw) == CFStringGetTypeID()) existing = [NSString stringWithString:(__bridge NSString *)raw];
        CFRelease(raw);
    }

    long long value = 0;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *token in [existing componentsSeparatedByString:@" "]) {
        if (token.length == 0) continue;
        NSRange separator = [token rangeOfString:@"="];
        if (separator.location == NSNotFound) continue;
        NSString *name = [token substringToIndex:separator.location];
        if ([name isEqualToString:label]) value = [[token substringFromIndex:separator.location + 1] longLongValue];
        else [parts addObject:token];
    }
    [parts addObject:[NSString stringWithFormat:@"%@=%lld", label, value + 1]];
    CFPreferencesSetAppValue((__bridge CFStringRef)prefKey, (__bridge CFStringRef)[parts componentsJoinedByString:@" "], domain);
    CFPreferencesAppSynchronize(domain);
}

// Lists the real classes/selectors that mention volume or buttons, straight from the running
// SpringBoard. Guessing a class name for a %hook crashes the tweak at load, so the names are read
// from the device instead of invented.
static void VCRDumpVolumeAPI(void) {
    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    for (unsigned int i = 0; i < classCount; i++) {
        const char *className = class_getName(classes[i]);
        if (!className || !strcasestr(className, "volume")) continue;

        NSMutableArray<NSString *> *selectors = [NSMutableArray array];
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(classes[i], &methodCount);
        for (unsigned int m = 0; m < methodCount; m++) {
            const char *selectorName = sel_getName(method_getName(methods[m]));
            if (strcasestr(selectorName, "volume") || strcasestr(selectorName, "button")) {
                [selectors addObject:[NSString stringWithUTF8String:selectorName]];
            }
        }
        free(methods);
        if (selectors.count > 0) {
            [groups addObject:[NSString stringWithFormat:@"%s :: %@", className, [selectors componentsJoinedByString:@", "]]];
        }
    }
    free(classes);

    NSString *dump = [groups componentsJoinedByString:@"\n"];
    if (dump.length > 4000) dump = [dump substringToIndex:4000];
    VCRDebugEvent([NSString stringWithFormat:@"volume API dump: %lu classes", (unsigned long)groups.count]);
    CFPreferencesSetAppValue(CFSTR("debugVolumeAPI"), (__bridge CFStringRef)dump, CFSTR("com.yourname.volumechordrecorder"));
    CFPreferencesAppSynchronize(CFSTR("com.yourname.volumechordrecorder"));
}

static BOOL VCRBoolPref(NSString *key, BOOL fallback) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)VCRPrefsID);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)VCRPrefsID);
    if (!value) return fallback;
    BOOL result = fallback;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        result = CFBooleanGetValue((CFBooleanRef)value);
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int n = fallback ? 1 : 0;
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &n);
        result = (n != 0);
    }
    CFRelease(value);
    return result;
}

static double VCRDoublePref(NSString *key, double fallback, double minValue, double maxValue) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)VCRPrefsID);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)VCRPrefsID);
    if (!value) return fallback;
    double result = fallback;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &result);
    else if (CFGetTypeID(value) == CFStringGetTypeID()) result = [(__bridge NSString *)value doubleValue];
    CFRelease(value);
    if (result < minValue) result = minValue;
    if (result > maxValue) result = maxValue;
    return result;
}

static NSString *VCRStringPref(NSString *key, NSString *fallback) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)VCRPrefsID);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)VCRPrefsID);
    if (!value) return fallback;
    NSString *result = fallback;
    if (CFGetTypeID(value) == CFStringGetTypeID()) result = [(__bridge NSString *)value copy];
    CFRelease(value);
    return result;
}

static void VCRLoadPrefs(void) {
    vcrNCTransparencyEnabled = VCRBoolPref(@"ncTransparencyEnabled", NO);
    vcrNCWallpaperAlpha = (CGFloat)VCRDoublePref(@"ncWallpaperAlpha", 0.00, 0.0, 1.0);
    vcrNCBlurAlpha = (CGFloat)VCRDoublePref(@"ncBlurAlpha", 0.12, 0.0, 1.0);
    vcrNCDimAlpha = (CGFloat)VCRDoublePref(@"ncDimAlpha", 0.00, 0.0, 1.0);
    vcrNCLogViews = VCRBoolPref(@"ncLogViews", NO);
    vcrEnabled = VCRBoolPref(@"enabled", YES);
    vcrHaptics = VCRBoolPref(@"haptics", YES);
    vcrLogPresses = VCRBoolPref(@"logPresses", NO);
    vcrHoldSeconds = VCRDoublePref(@"holdSeconds", 2.0, 0.2, 10.0);
    vcrMaxRecordSeconds = VCRDoublePref(@"maxRecordSeconds", 600.0, 5.0, 7200.0);
    vcrVolumeChordTrigger = VCRBoolPref(@"volumeChordTrigger", NO);
    vcrThreeFingerSwipeDownTrigger = VCRBoolPref(@"threeFingerSwipeDownTrigger", YES);
    vcrThreeFingerSwipeDistance = (CGFloat)VCRDoublePref(@"threeFingerSwipeDistance", 140.0, 60.0, 500.0);
    vcrLogGestures = VCRBoolPref(@"logGestures", NO);
    vcrCameraEnabled = VCRBoolPref(@"cameraEnabled", YES);
    vcrCameraChordTrigger = VCRBoolPref(@"cameraChordTrigger", YES);
    vcrCameraSwipeTrigger = VCRBoolPref(@"cameraSwipeTrigger", NO);
    vcrCameraSwipeDistance = (CGFloat)VCRDoublePref(@"cameraSwipeDistance", 140.0, 60.0, 500.0);
    vcrCameraPosition = VCRStringPref(@"cameraPosition", @"back");
    vcrCameraLens = VCRStringPref(@"cameraLens", @"wide");
    vcrCameraVideoQuality = VCRStringPref(@"cameraVideoQuality", @"1080p30");
    vcrCameraPhotoQuality = VCRStringPref(@"cameraPhotoQuality", @"quality");
    vcrHapticOnStart = VCRBoolPref(@"hapticOnStart", YES);
    vcrHapticOnStop = VCRBoolPref(@"hapticOnStop", YES);
    NSString *hapticStrength = VCRStringPref(@"hapticStrength", @"medium");
    vcrHapticStrength = [hapticStrength isEqualToString:@"light"] ? 0 : ([hapticStrength isEqualToString:@"strong"] ? 2 : 1);

    VCRLog(@"Camera prefs enabled=%d chord=%d swipe=%d swipeDistance=%.0f position=%@ lens=%@ quality=%@ photoQuality=%@ hapticStart=%d hapticStop=%d hapticStrength=%ld",
           vcrCameraEnabled, vcrCameraChordTrigger, vcrCameraSwipeTrigger, vcrCameraSwipeDistance,
           vcrCameraPosition, vcrCameraLens, vcrCameraVideoQuality, vcrCameraPhotoQuality,
           vcrHapticOnStart, vcrHapticOnStop, (long)vcrHapticStrength);

    VCRLog(@"Prefs loaded enabled=%d volumeChord=%d threeSwipe=%d swipeDistance=%.0f hold=%.2fs max=%.0fs haptics=%d logPresses=%d logGestures=%d nc=%d wallpaper=%.2f blur=%.2f dim=%.2f",
           vcrEnabled, vcrVolumeChordTrigger, vcrThreeFingerSwipeDownTrigger, vcrThreeFingerSwipeDistance,
           vcrHoldSeconds, vcrMaxRecordSeconds, vcrHaptics, vcrLogPresses, vcrLogGestures,
           vcrNCTransparencyEnabled, vcrNCWallpaperAlpha, vcrNCBlurAlpha, vcrNCDimAlpha);
}

static void VCRPlayHaptic(SystemSoundID soundID) {
    if (!vcrHaptics) return;
    AudioServicesPlaySystemSound(soundID);
}

static SystemSoundID VCRHapticSoundID(void) {
    switch (vcrHapticStrength) {
        case 0: return 1519;   // light
        case 2: return 1521;   // strong
        default: return 1520;  // medium
    }
}

static void VCRHapticStart(void) {
    if (!vcrHapticOnStart) return;
    VCRPlayHaptic(VCRHapticSoundID());
}

static void VCRHapticStop(void) {
    if (!vcrHapticOnStop) return;
    VCRPlayHaptic(VCRHapticSoundID());
}

// Short tick fired as each chord tier unlocks, so you can feel which mode you are about to get.
static void VCRHapticTick(void) {
    VCRPlayHaptic(VCRHapticSoundID());
}

// The previous on-screen notice used the system user-notification alert, created with a zero
// timeout and no button: that kind of alert is MODAL and can never be dismissed. It is what looked
// like a "REC" badge that would not turn off, and it ate every touch until a respring. Show an
// ordinary window instead - it is not interactive, so it cannot swallow a touch or the volume
// buttons, and it always hides itself.
static UIWindow *vcrHUDWindow = nil;
static UILabel *vcrHUDLabel = nil;
static NSTimer *vcrHUDTimer = nil;

static void VCRHUDHide(void) {
    if (vcrHUDTimer) { [vcrHUDTimer invalidate]; vcrHUDTimer = nil; }
    UIWindow *window = vcrHUDWindow;
    if (!window) return;
    [UIView animateWithDuration:0.25 animations:^{ window.alpha = 0.0; }
                     completion:^(__unused BOOL finished) { window.hidden = YES; }];
}

static void VCRShowNotification(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!vcrHUDWindow) {
                UIWindow *window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
                // A window created without a scene does not render on iOS 13+.
                for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    if ([scene isKindOfClass:[UIWindowScene class]]) {
                        window.windowScene = (UIWindowScene *)scene;
                        break;
                    }
                }
                window.windowLevel = UIWindowLevelAlert + 1.0;
                window.backgroundColor = [UIColor clearColor];
                window.userInteractionEnabled = NO;   // never steal a press or a gesture
                window.rootViewController = [[UIViewController alloc] init];
                window.rootViewController.view.backgroundColor = [UIColor clearColor];

                UIView *box = [[UIView alloc] init];
                box.translatesAutoresizingMaskIntoConstraints = NO;
                box.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
                box.layer.cornerRadius = 14.0;

                UILabel *label = [[UILabel alloc] init];
                label.translatesAutoresizingMaskIntoConstraints = NO;
                label.numberOfLines = 2;
                label.textAlignment = NSTextAlignmentCenter;
                label.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
                label.textColor = [UIColor whiteColor];

                [window.rootViewController.view addSubview:box];
                [box addSubview:label];
                [NSLayoutConstraint activateConstraints:@[
                    [box.centerXAnchor constraintEqualToAnchor:window.rootViewController.view.centerXAnchor],
                    [box.topAnchor constraintEqualToAnchor:window.rootViewController.view.topAnchor constant:64.0],
                    [label.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:18.0],
                    [label.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-18.0],
                    [label.topAnchor constraintEqualToAnchor:box.topAnchor constant:10.0],
                    [label.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-10.0],
                ]];
                vcrHUDWindow = window;
                vcrHUDLabel = label;
            }

            vcrHUDLabel.text = message;
            vcrHUDWindow.alpha = 1.0;
            vcrHUDWindow.hidden = NO;

            if (vcrHUDTimer) [vcrHUDTimer invalidate];
            vcrHUDTimer = [NSTimer scheduledTimerWithTimeInterval:1.4 repeats:NO block:^(__unused NSTimer *timer) {
                vcrHUDTimer = nil;
                VCRHUDHide();
            }];
        } @catch (NSException *exception) {
            VCRLog(@"HUD failed: %@ (%@)", title, exception.reason);
        }
    });
}

// /var/mobile/Media does not exist on this device at all, so every capture failed at the very first
// createDirectory call and not one file was ever saved (the folder was simply never there). Ask at
// runtime instead: take the first candidate that can actually hold a file, and publish the choice so
// the preferences bundle lists the same folder.
static NSString *VCRRecordingDirectory(void) {
    static NSString *chosen = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *candidates = @[
            @"/var/mobile/Media/VolumeChordRecorder",
            @"/var/mobile/Documents/VolumeChordRecorder",
            @"/var/jb/var/mobile/Documents/VolumeChordRecorder",
            @"/private/var/tmp/VolumeChordRecorder",
        ];
        NSFileManager *manager = [NSFileManager defaultManager];
        for (NSString *candidate in candidates) {
            if (![manager createDirectoryAtPath:candidate withIntermediateDirectories:YES attributes:nil error:nil]) continue;
            NSString *probe = [candidate stringByAppendingPathComponent:@".write-probe"];
            if (![@"probe" writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:nil]) continue;
            [manager removeItemAtPath:probe error:nil];
            chosen = candidate;
            break;
        }
        if (!chosen) chosen = @"/private/var/tmp/VolumeChordRecorder";
        CFPreferencesSetAppValue(CFSTR("vcrRecordingsDir"), (__bridge CFStringRef)chosen, (__bridge CFStringRef)VCRPrefsID);
        CFPreferencesAppSynchronize((__bridge CFStringRef)VCRPrefsID);
        VCRLog(@"Captures will be saved to %@", chosen);
    });
    return chosen;
}

static NSString *VCRTimestampFilenameWithExt(NSString *ext) {
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"yyyyMMdd_HHmmss";
    return [NSString stringWithFormat:@"VCR_%@.%@", [fmt stringFromDate:[NSDate date]], ext];
}

static NSString *VCRTimestampFilename(void) {
    return VCRTimestampFilenameWithExt(@"m4a");
}

// Newest media file in the recordings folder - used by the Settings "Send Latest Recording" button.
static NSURL *VCRNewestRecordingURL(void) {
    NSURL *dir = [NSURL fileURLWithPath:VCRRecordingDirectory() isDirectory:YES];
    NSArray<NSURL *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:dir
                                                           includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                                              options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                error:nil];
    NSSet<NSString *> *extensions = [NSSet setWithArray:@[@"m4a", @"mp4", @"mov", @"jpg", @"jpeg", @"png"]];
    NSURL *newest = nil;
    NSDate *newestDate = nil;
    for (NSURL *url in files) {
        if (![extensions containsObject:url.pathExtension.lowercaseString]) continue;
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

// AVAudioRecorder's delegate was never set before, so nothing reported when the m4a was finalised.
@interface VCRRecorderDelegate : NSObject <AVAudioRecorderDelegate>
@end

@implementation VCRRecorderDelegate
- (void)audioRecorderDidFinishRecording:(AVAudioRecorder *)finished successfully:(BOOL)successfully {
    NSURL *url = finished.url;
    vcrStoppingRecorder = nil;
    if (!successfully || !url) {
        VCRDebugEvent(@"telegram: audio finish unsuccessful");
        return;
    }
    VCRLog(@"Recording finalised: %@", url.path);
    VCRUploadFinishedCapture(url);
}
@end

static void VCRStopRecording(void);

static void VCRStartRecording(void) {
    if (isRecording) return;

    // ✅ 햅틱을 여기로 이동 (녹음 시작 전)
    VCRHapticStart();

    NSError *error = nil;
    NSString *dir = VCRRecordingDirectory();
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error];
    if (error) {
        VCRLog(@"Failed to create recording dir: %@", error);
        return;
    }

    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryRecord error:&error];
    if (error) VCRLog(@"AVAudioSession category error: %@", error);
    error = nil;
    [session setActive:YES error:&error];
    if (error) VCRLog(@"AVAudioSession active error: %@", error);

    NSString *path = [dir stringByAppendingPathComponent:VCRTimestampFilename()];
    NSURL *url = [NSURL fileURLWithPath:path];
    NSDictionary *settings = @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @44100,
        AVNumberOfChannelsKey: @1,
        AVEncoderAudioQualityKey: @(AVAudioQualityHigh)
    };

    recorder = [[AVAudioRecorder alloc] initWithURL:url settings:settings error:&error];
    if (error || !recorder) {
        VCRLog(@"Recorder init failed: %@", error);
        recorder = nil;
        return;
    }

    [recorder prepareToRecord];
    if (!vcrRecorderDelegate) vcrRecorderDelegate = [VCRRecorderDelegate new];
    recorder.delegate = vcrRecorderDelegate;
    if ([recorder record]) {
        isRecording = YES;
        VCRLog(@"Recording started: %@", path);
        VCRShowNotification(@"VolumeChordRecorder", @"S");
        if (maxRecordTimer) [maxRecordTimer invalidate];
        maxRecordTimer = [NSTimer scheduledTimerWithTimeInterval:vcrMaxRecordSeconds repeats:NO block:^(__unused NSTimer *timer) {
            VCRLog(@"Max recording time reached, stopping");
            VCRStopRecording();
        }];
    } else {
        VCRLog(@"Recorder failed to start");
        recorder = nil;
    }
}

static void VCRStopRecording(void) {
    if (!isRecording) return;
    if (maxRecordTimer) {
        [maxRecordTimer invalidate];
        maxRecordTimer = nil;
    }
    // -stop is asynchronous and AVAudioRecorder's delegate reference is weak, so hold the recorder
    // until the delegate reports the finished file (that callback is what uploads it).
    vcrStoppingRecorder = recorder;
    [vcrStoppingRecorder stop];
    recorder = nil;
    [[AVAudioSession sharedInstance] setActive:NO error:nil];
    isRecording = NO;
    VCRHapticStop();
    VCRLog(@"Recording stopped");
    VCRShowNotification(@"VolumeChordRecorder", @"E");
}

static void VCRToggleRecording(void) {
    if (!vcrEnabled) return;
    if (isRecording) VCRStopRecording();
    else VCRStartRecording();
}

// ===================== Camera capture =====================
// Silent by default: AVCapturePhotoOutput / AVCaptureMovieFileOutput do not play
// shutter/record sounds themselves (the system Camera app adds those). Files are
// written to the same VCR folder as audio recordings.

static void VCRTakePhoto(void);
static void VCRStartVideoRecording(void);
static void VCRStopVideoRecording(void);

static void VCRCameraCheckAuthorization(void) {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    VCRLog(@"Camera TCC authorizationStatus=%ld", (long)status);
    if (status == AVAuthorizationStatusAuthorized) {
        vcrCameraAuthorized = YES;
    } else if (status == AVAuthorizationStatusNotDetermined) {
        // SpringBoard is a system daemon; the prompt may or may not appear.
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            vcrCameraAuthorized = granted;
            VCRLog(@"Camera TCC request granted=%d", granted);
        }];
    } else {
        vcrCameraAuthorized = NO;
    }
}

static void VCRCameraEnsureSession(void) {
    if (vcrCaptureSession) return;
    if (!vcrCameraAuthorized) return;
    if (!vcrCaptureQueue) vcrCaptureQueue = dispatch_queue_create("com.yourname.volumechordrecorder.camera", DISPATCH_QUEUE_SERIAL);
    vcrCaptureSession = [[AVCaptureSession alloc] init];
    vcrPhotoOutput = [[AVCapturePhotoOutput alloc] init];
    vcrMovieOutput = [[AVCaptureMovieFileOutput alloc] init];
    VCRLog(@"Camera: session object created");
}

// Pick the capture device for the configured position (front/back) and lens (1x / 0.5x).
static AVCaptureDevice *VCRCameraSelectDevice(void) {
    AVCaptureDevicePosition position = [vcrCameraPosition isEqualToString:@"front"] ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
    AVCaptureDeviceType type = AVCaptureDeviceTypeBuiltInWideAngleCamera;
    if (position == AVCaptureDevicePositionBack && [vcrCameraLens isEqualToString:@"ultrawide"]) {
        type = AVCaptureDeviceTypeBuiltInUltraWideCamera; // 0.5x is back-only
    }
    AVCaptureDeviceDiscoverySession *discovery =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[type]
                                                               mediaType:AVMediaTypeVideo
                                                                position:position];
    AVCaptureDevice *device = discovery.devices.firstObject;
    if (!device && type != AVCaptureDeviceTypeBuiltInWideAngleCamera) {
        discovery = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
                                                                          mediaType:AVMediaTypeVideo
                                                                           position:position];
        device = discovery.devices.firstObject;
    }
    return device;
}

static AVCapturePhotoQualityPrioritization VCRCameraPhotoQualityValue(void) {
    if ([vcrCameraPhotoQuality isEqualToString:@"speed"]) return AVCapturePhotoQualityPrioritizationSpeed;
    if ([vcrCameraPhotoQuality isEqualToString:@"balanced"]) return AVCapturePhotoQualityPrioritizationBalanced;
    return AVCapturePhotoQualityPrioritizationQuality;
}

// "Video Quality" pref -> session preset (Camera-app-style resolution).
static NSString *VCRCameraVideoPresetConstant(void) {
    NSString *q = vcrCameraVideoQuality;
    if ([q hasPrefix:@"720p"]) return AVCaptureSessionPreset1280x720;
    if ([q hasPrefix:@"1080p"]) return AVCaptureSessionPreset1920x1080;
    if ([q hasPrefix:@"4k"] || [q hasPrefix:@"2160p"]) return AVCaptureSessionPreset3840x2160;
    return AVCaptureSessionPresetHigh; // auto
}

// Requested resolution/frame rate for the current quality pref. width == 0 means "auto".
typedef struct { int32_t width; int32_t height; int32_t fps; } VCRVideoTarget;

static VCRVideoTarget VCRVideoTargetForQuality(void) {
    NSString *q = vcrCameraVideoQuality;
    if ([q hasPrefix:@"720p"])  return (VCRVideoTarget){1280, 720, 30};
    if ([q hasPrefix:@"1080p"]) return (VCRVideoTarget){1920, 1080, [q hasSuffix:@"60"] ? 60 : 30};
    if ([q hasPrefix:@"4k"])    return (VCRVideoTarget){3840, 2160, [q hasSuffix:@"60"] ? 60 : 30};
    return (VCRVideoTarget){0, 0, 0};
}

// Frame rate from the same pref. 0 means "leave the device default" (auto).
static int32_t VCRCameraFPSForQuality(void) {
    if ([vcrCameraVideoQuality hasSuffix:@"60"]) return 60;
    if ([vcrCameraVideoQuality hasSuffix:@"30"]) return 30;
    return 0;
}

// The session preset alone does not decide the recording resolution, and the previous
// implementation forced the *largest* format that supported the frame rate - so every quality
// recorded at the biggest format and the selection appeared to do nothing. Pick the format whose
// dimensions match the request exactly, then pin the frame duration.
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
               (int)target.width, (int)target.height, (int)target.fps,
               device.localizedName, vcrCameraVideoQuality);
    }
    return chosen != nil;
}

// Log what the device actually ended up with. This is the line that proves a quality change took
// effect, and it is readable from "Show Debug Log" in Settings.
static void VCRCameraLogEffectiveVideoFormat(AVCaptureDevice *device) {
    if (!device) return;
    VCRVideoTarget target = VCRVideoTargetForQuality();
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription);
    CMTime duration = device.activeVideoMinFrameDuration;
    int32_t fps = 0;
    if (duration.value > 0 && duration.timescale > 0) {
        fps = (int32_t)((double)duration.timescale / (double)duration.value);
    }
    VCRLog(@"Camera: effective format %dx%d @ %dfps (quality=%@ requested=%dx%d@%dfps)",
           (int)dims.width, (int)dims.height, (int)fps, vcrCameraVideoQuality,
           (int)target.width, (int)target.height, (int)target.fps);
}

// Rebuild the (stopped) session for a capture mode. Must run on vcrCaptureQueue.
// Rebuilding the input each time makes position/lens changes take effect immediately.
static BOOL VCRCameraPrepareSession(BOOL forVideo) {
    if (!vcrCaptureSession) return NO;

    [vcrCaptureSession beginConfiguration];
    for (AVCaptureInput *inp in [vcrCaptureSession.inputs copy]) [vcrCaptureSession removeInput:inp];
    for (AVCaptureOutput *out in [vcrCaptureSession.outputs copy]) [vcrCaptureSession removeOutput:out];

    AVCaptureDevice *device = VCRCameraSelectDevice();
    if (!device) {
        [vcrCaptureSession commitConfiguration];
        VCRLog(@"Camera: no device for position=%ld lens=%ld", (long)vcrCameraPosition, (long)vcrCameraLens);
        return NO;
    }

    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (!input || ![vcrCaptureSession canAddInput:input]) {
        [vcrCaptureSession commitConfiguration];
        VCRLog(@"Camera: input failed %@", error);
        return NO;
    }
    [vcrCaptureSession addInput:input];

    if (forVideo) {
        NSString *preset = VCRCameraVideoPresetConstant();
        if (![vcrCaptureSession canSetSessionPreset:preset]) {
            VCRLog(@"Camera: preset %@ unsupported, falling back to High", preset);
            preset = AVCaptureSessionPresetHigh;
        }
        vcrCaptureSession.sessionPreset = preset;
        if (vcrMovieOutput && [vcrCaptureSession canAddOutput:vcrMovieOutput]) [vcrCaptureSession addOutput:vcrMovieOutput];
        else VCRLog(@"Camera: cannot add movie output");
        [vcrCaptureSession commitConfiguration];
        // Assigning the session preset re-picks the device format, so the requested resolution has
        // to be asserted after the commit - otherwise the preset silently wins.
        VCRCameraApplyVideoFormat(device);
        VCRLog(@"Camera: video preset=%@ device=%@ lens=%@ pos=%@ quality=%@ fps=%d",
               preset, device.localizedName, vcrCameraLens, vcrCameraPosition,
               vcrCameraVideoQuality, (int)VCRCameraFPSForQuality());
        VCRCameraLogEffectiveVideoFormat(device);
    } else {
        if ([vcrCaptureSession canSetSessionPreset:AVCaptureSessionPresetPhoto]) vcrCaptureSession.sessionPreset = AVCaptureSessionPresetPhoto;
        if (vcrPhotoOutput && [vcrCaptureSession canAddOutput:vcrPhotoOutput]) [vcrCaptureSession addOutput:vcrPhotoOutput];
        else VCRLog(@"Camera: cannot add photo output");
        [vcrCaptureSession commitConfiguration];
        VCRLog(@"Camera: photo session device=%@ lens=%@ pos=%@", device.localizedName, vcrCameraLens, vcrCameraPosition);
    }
    return YES;
}

static void VCRCameraStartRunningSync(void) {
    if (!vcrCaptureSession) return;
    if (!vcrCaptureSession.isRunning) [vcrCaptureSession startRunning];
}

static void VCRCameraStopRunning(void) {
    if (!vcrCaptureSession) return;
    if (vcrCaptureSession.isRunning) [vcrCaptureSession stopRunning];
}

@interface VCRPhotoCaptureDelegate : NSObject <AVCapturePhotoCaptureDelegate>
@end

@implementation VCRPhotoCaptureDelegate
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    if (error) {
        VCRLog(@"Camera photo error: %@", error);
        VCRShowNotification(@"VolumeChordRecorder", @"Photo failed");
    } else {
        NSData *imageData = [photo fileDataRepresentation];
        NSString *dir = VCRRecordingDirectory();
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *path = [dir stringByAppendingPathComponent:VCRTimestampFilenameWithExt(@"jpg")];
        NSError *writeError = nil;
        if (imageData && [imageData writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
            VCRLog(@"Camera photo saved: %@ (%lu bytes)", path, (unsigned long)imageData.length);
            VCRUploadFinishedCapture([NSURL fileURLWithPath:path]);
            VCRShowNotification(@"VolumeChordRecorder", @"Photo");
        } else {
            VCRLog(@"Camera photo write failed: %@", writeError);
        }
    }
    if (vcrCaptureQueue) dispatch_async(vcrCaptureQueue, ^{ VCRCameraStopRunning(); });
}
@end

@interface VCRMovieRecordingDelegate : NSObject <AVCaptureFileOutputRecordingDelegate>
@end

@implementation VCRMovieRecordingDelegate
- (void)captureOutput:(AVCaptureFileOutput *)output
didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL
  fromConnections:(NSArray<AVCaptureConnection *> *)connections
            error:(NSError *)error {
    BOOL wasRecording = vcrCameraRecording;
    vcrCameraRecording = NO;
    if (vcrMaxVideoTimer) { [vcrMaxVideoTimer invalidate]; vcrMaxVideoTimer = nil; }
    NSString *target = vcrCurrentVideoPath;
    vcrCurrentVideoPath = nil;

    if (error) VCRLog(@"Camera video error: %@", error);

    if (target) {
        NSError *moveError = nil;
        NSURL *targetURL = [NSURL fileURLWithPath:target];
        if ([[NSFileManager defaultManager] fileExistsAtPath:target]) {
            [[NSFileManager defaultManager] removeItemAtPath:target error:nil];
        }
        if ([[NSFileManager defaultManager] moveItemAtURL:outputFileURL toURL:targetURL error:&moveError]) {
            VCRLog(@"Camera video saved: %@", target);
            VCRShowNotification(@"VolumeChordRecorder", @"Video");
            VCRUploadFinishedCapture(targetURL);
        } else {
            VCRLog(@"Camera video move failed: %@", moveError);
        }
    }
    if (wasRecording) VCRHapticStop();
    if (vcrCaptureQueue) dispatch_async(vcrCaptureQueue, ^{ VCRCameraStopRunning(); });
}
@end

static void VCRTakePhoto(void) {
    if (!vcrEnabled || !vcrCameraEnabled) return;
    if (vcrCameraRecording) { VCRLog(@"Camera busy: video recording in progress"); return; }

    VCRCameraCheckAuthorization();
    VCRCameraEnsureSession();
    if (!vcrCaptureSession || !vcrPhotoOutput) {
        VCRLog(@"Camera unavailable for photo");
        VCRShowNotification(@"VolumeChordRecorder", @"Camera unavailable");
        return;
    }
    if (!vcrCaptureQueue) vcrCaptureQueue = dispatch_queue_create("com.yourname.volumechordrecorder.camera", DISPATCH_QUEUE_SERIAL);

    VCRHapticStart();
    AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];
    settings.photoQualityPrioritization = VCRCameraPhotoQualityValue();
    VCRPhotoCaptureDelegate *delegate = [VCRPhotoCaptureDelegate new];
    dispatch_async(vcrCaptureQueue, ^{
        if (VCRCameraPrepareSession(NO)) {
            VCRCameraStartRunningSync();
            [vcrPhotoOutput capturePhotoWithSettings:settings delegate:delegate];
        }
    });
    VCRLog(@"Camera photo triggered");
}

static void VCRStartVideoRecording(void) {
    if (!vcrEnabled || !vcrCameraEnabled) return;
    if (vcrCameraRecording) return;

    VCRCameraCheckAuthorization();
    VCRCameraEnsureSession();
    if (!vcrCaptureSession || !vcrMovieOutput) {
        VCRLog(@"Camera unavailable for video");
        VCRShowNotification(@"VolumeChordRecorder", @"Camera unavailable");
        return;
    }
    if (!vcrCaptureQueue) vcrCaptureQueue = dispatch_queue_create("com.yourname.volumechordrecorder.camera", DISPATCH_QUEUE_SERIAL);

    NSString *dir = VCRRecordingDirectory();
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:VCRTimestampFilenameWithExt(@"mp4")];
    vcrCurrentVideoPath = path;

    NSURL *tempURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"VCR_recording.mp4"]];
    [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];

    VCRMovieRecordingDelegate *delegate = [VCRMovieRecordingDelegate new];
    vcrCameraRecording = YES;
    dispatch_async(vcrCaptureQueue, ^{
        if (VCRCameraPrepareSession(YES)) {
            VCRCameraStartRunningSync();
            [vcrMovieOutput startRecordingToOutputFileURL:tempURL recordingDelegate:delegate];
            dispatch_async(dispatch_get_main_queue(), ^{
                VCRLog(@"Camera video recording started -> %@", path);
                VCRShowNotification(@"VolumeChordRecorder", @"REC");
            });
        } else {
            vcrCameraRecording = NO;
            if (vcrMaxVideoTimer) { [vcrMaxVideoTimer invalidate]; vcrMaxVideoTimer = nil; }
            VCRLog(@"Camera: video prepare failed, aborted");
            dispatch_async(dispatch_get_main_queue(), ^{
                VCRShowNotification(@"VolumeChordRecorder", @"Video failed");
            });
        }
    });
    VCRHapticStart();

    if (vcrMaxVideoTimer) [vcrMaxVideoTimer invalidate];
    vcrMaxVideoTimer = [NSTimer scheduledTimerWithTimeInterval:vcrMaxRecordSeconds repeats:NO block:^(__unused NSTimer *timer) {
        vcrMaxVideoTimer = nil;
        VCRLog(@"Camera max video time reached, stopping");
        VCRStopVideoRecording();
    }];
}

static void VCRStopVideoRecording(void) {
    AVCaptureMovieFileOutput *output = vcrMovieOutput;
    if (!output || (!vcrCameraRecording && !output.isRecording)) return;
    VCRLog(@"Camera video stopping (flag=%d output=%d)", vcrCameraRecording, output.isRecording);
    if (vcrMaxVideoTimer) { [vcrMaxVideoTimer invalidate]; vcrMaxVideoTimer = nil; }
    if (output.isRecording) {
        [output stopRecording];   // the delegate finishes the state transition
    } else {
        // The flag outlived a start that failed, so nothing would ever clear it and every later
        // start would be refused.
        vcrCameraRecording = NO;
        VCRLog(@"Camera: recording flag was stale, cleared");
    }
}

static void VCRToggleVideoRecording(void) {
    if (vcrCameraRecording) VCRStopVideoRecording();
    else VCRStartVideoRecording();
}

static void VCRCancelHoldTimer(void) {
    if (holdTimer) {
        [holdTimer invalidate];
        holdTimer = nil;
    }
}

static void VCRResetChordState(void) {
    VCRCancelHoldTimer();
    if (chordTimer2) { [chordTimer2 invalidate]; chordTimer2 = nil; }
    if (chordTimer3) { [chordTimer3 invalidate]; chordTimer3 = nil; }
    vcrChordStage = 0;
    vcrChordPressed = NO;
}

static void VCRStopAnyRecording(void) {
    if (vcrCameraRecording) VCRStopVideoRecording();
    if (isRecording) VCRStopRecording();
}

// Volume Up + Volume Down chord, resolved on release by how long it was held:
//   tier 0 (under H)     : nothing
//   tier 1 [H, 2H)       : photo
//   tier 2 [2H, 3H)      : video start/stop
//   tier 3 [3H, and up)  : audio start/stop   (only when the audio chord is enabled)
// If a recording is already running, ANY tier stops it - so stopping never needs a
// precise hold length and can never turn into an accidental photo.
static void VCRCheckChord(void) {
    BOOL bothPressed = volumeUpPressed && volumeDownPressed;
    BOOL cameraChord = vcrEnabled && vcrCameraEnabled && vcrCameraChordTrigger;
    BOOL audioChord = vcrEnabled && vcrVolumeChordTrigger;

    if (!bothPressed) {
        NSInteger stage = vcrChordStage;
        BOOL chordWasPressed = vcrChordPressed;   // read before the reset clears it
        VCRResetChordState();

        // Stopping must never depend on how long the buttons were held. A quick tap used to do
        // nothing at all (stage stayed 0), which is exactly the "REC will not turn off" report.
        if (chordWasPressed && (vcrCameraRecording || isRecording)) {
            VCRLog(@"Chord release (stage %ld) -> STOP active recording", (long)stage);
            VCRDebugEvent(@"chord -> STOP");
            VCRStopAnyRecording();
            return;
        }
        if (stage <= 0) return;

        if (vcrCameraRecording || isRecording) {
            VCRLog(@"Chord tier %ld -> STOP active recording", (long)stage);
            VCRStopAnyRecording();
            return;
        }
        if (cameraChord) {
            if (stage == 1) { VCRLog(@"Chord tier 1 -> photo"); VCRTakePhoto(); return; }
            if (stage == 2 || !audioChord) { VCRLog(@"Chord tier %ld -> video", (long)stage); VCRToggleVideoRecording(); return; }
            VCRLog(@"Chord tier 3 -> audio");
            VCRToggleRecording();
            return;
        }
        if (audioChord) { VCRLog(@"Chord (audio only) -> audio toggle"); VCRToggleRecording(); }
        return;
    }

    if (!cameraChord && !audioChord) { VCRResetChordState(); return; }
    vcrChordPressed = YES;
    if (holdTimer || chordTimer2 || chordTimer3) return; // already counting

    NSTimeInterval tier = MAX(0.4, vcrHoldSeconds);
    VCRLog(@"Volume chord down; tiers at %.1fs photo / %.1fs video / %.1fs audio (cam=%d aud=%d)",
           tier, tier * 2.0, tier * 3.0, cameraChord, audioChord);

    holdTimer = [NSTimer scheduledTimerWithTimeInterval:tier repeats:NO block:^(__unused NSTimer *t1) {
        holdTimer = nil;
        if (!(volumeUpPressed && volumeDownPressed)) return;
        vcrChordStage = 1;
        VCRHapticTick();
        chordTimer2 = [NSTimer scheduledTimerWithTimeInterval:tier repeats:NO block:^(__unused NSTimer *t2) {
            chordTimer2 = nil;
            if (!(volumeUpPressed && volumeDownPressed)) return;
            vcrChordStage = 2;
            VCRHapticTick();
            chordTimer3 = [NSTimer scheduledTimerWithTimeInterval:tier repeats:NO block:^(__unused NSTimer *t3) {
                chordTimer3 = nil;
                if (!(volumeUpPressed && volumeDownPressed)) return;
                vcrChordStage = 3;
                VCRHapticTick();
            }];
        }];
    }];
}

static NSMutableDictionary<NSValue *, NSValue *> *vcrGestureTouchPoints = nil;
static BOOL vcrThreeFingerTracking = NO;
static BOOL vcrThreeFingerTriggered = NO;
static CGPoint vcrThreeFingerStartCentroid = {0.0, 0.0};
static NSTimeInterval vcrThreeFingerStartTime = 0.0;
static NSTimeInterval vcrLastThreeFingerTriggerTime = 0.0;

static NSTimeInterval VCRNow(void) { return [NSDate timeIntervalSinceReferenceDate]; }

// --- Camera capture gesture state (4-finger swipe) ---
static NSMutableDictionary<NSValue *, NSValue *> *vcrCameraTouchPoints = nil;
static BOOL vcrCameraTracking = NO;
static BOOL vcrCameraTriggered = NO;
static CGPoint vcrCameraStartCentroid = {0.0, 0.0};
static NSTimeInterval vcrCameraStartTime = 0.0;
static NSTimeInterval vcrLastCameraTriggerTime = 0.0;

static BOOL VCRCameraGestureMayOwnTouches(NSUInteger count) {
    return (vcrCameraEnabled && vcrCameraSwipeTrigger) && count >= (NSUInteger)vcrCameraFingerCount;
}

static CGPoint VCRCentroidForCameraTouches(void) {
    CGFloat x = 0.0, y = 0.0;
    NSUInteger count = vcrCameraTouchPoints.count;
    if (count == 0) return CGPointZero;
    for (NSValue *value in vcrCameraTouchPoints.allValues) {
        CGPoint p = [value CGPointValue];
        x += p.x;
        y += p.y;
    }
    return CGPointMake(x / (CGFloat)count, y / (CGFloat)count);
}

static void VCRResetCameraGesture(void) {
    [vcrCameraTouchPoints removeAllObjects];
    vcrCameraTracking = NO;
    vcrCameraTriggered = NO;
    vcrCameraStartCentroid = CGPointZero;
    vcrCameraStartTime = 0.0;
}

static CGPoint VCRCentroidForGestureTouches(void) {
    CGFloat x = 0.0, y = 0.0;
    NSUInteger count = vcrGestureTouchPoints.count;
    if (count == 0) return CGPointZero;
    for (NSValue *value in vcrGestureTouchPoints.allValues) {
        CGPoint p = [value CGPointValue];
        x += p.x;
        y += p.y;
    }
    return CGPointMake(x / (CGFloat)count, y / (CGFloat)count);
}

static void VCRResetThreeFingerGesture(void) {
    [vcrGestureTouchPoints removeAllObjects];
    vcrThreeFingerTracking = NO;
    vcrThreeFingerTriggered = NO;
    vcrThreeFingerStartCentroid = CGPointZero;
    vcrThreeFingerStartTime = 0.0;
}

static void VCRTriggerRecordingFromThreeFingerSwipe(void) {
    NSTimeInterval now = VCRNow();
    if (now - vcrLastThreeFingerTriggerTime < 1.0) return;
    vcrLastThreeFingerTriggerTime = now;
    VCRLog(@"Three-finger swipe down confirmed in SpringBoard; toggling recording");
    VCRToggleRecording();
}

static void VCRProcessThreeFingerSwipeEvent(UIEvent *event) {
    if (!vcrEnabled || !vcrThreeFingerSwipeDownTrigger) return;
    if (!event || event.type != UIEventTypeTouches) return;

    NSSet<UITouch *> *touches = [event allTouches];
    if (touches.count == 0) return;
    if (!vcrGestureTouchPoints) vcrGestureTouchPoints = [NSMutableDictionary dictionary];

    BOOL sawEndOrCancel = NO;
    for (UITouch *touch in touches) {
        NSValue *key = [NSValue valueWithNonretainedObject:touch];
        CGPoint point = [touch locationInView:touch.window ?: touch.view];
        UITouchPhase phase = touch.phase;

        if (phase == UITouchPhaseBegan || phase == UITouchPhaseMoved || phase == UITouchPhaseStationary || phase == UITouchPhaseEnded) {
            vcrGestureTouchPoints[key] = [NSValue valueWithCGPoint:point];
        }
        if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) sawEndOrCancel = YES;
    }

    NSUInteger activeCount = vcrGestureTouchPoints.count;
    NSTimeInterval now = VCRNow();

    // Let the camera gesture handler own multi-touch streams that carry >= fingerCount
    // touches, so a 4-finger swipe does not also toggle audio recording.
    if (VCRCameraGestureMayOwnTouches(activeCount)) {
        if (vcrLogGestures) VCRLog(@"Three-finger tracker yields to camera gesture count=%lu", (unsigned long)activeCount);
        VCRResetThreeFingerGesture();
        return;
    }

    if (!vcrThreeFingerTracking && activeCount >= 3) {
        vcrThreeFingerTracking = YES;
        vcrThreeFingerTriggered = NO;
        vcrThreeFingerStartCentroid = VCRCentroidForGestureTouches();
        vcrThreeFingerStartTime = now;
        if (vcrLogGestures) VCRLog(@"Three-finger gesture tracking began count=%lu start=(%.1f, %.1f)", (unsigned long)activeCount, vcrThreeFingerStartCentroid.x, vcrThreeFingerStartCentroid.y);
    }

    if (vcrThreeFingerTracking && !vcrThreeFingerTriggered && activeCount >= 3) {
        CGPoint current = VCRCentroidForGestureTouches();
        CGFloat dy = current.y - vcrThreeFingerStartCentroid.y;
        CGFloat dx = fabs(current.x - vcrThreeFingerStartCentroid.x);
        NSTimeInterval elapsed = now - vcrThreeFingerStartTime;

        if (dy >= vcrThreeFingerSwipeDistance && dx <= MAX(120.0, vcrThreeFingerSwipeDistance * 1.25) && elapsed <= 1.6) {
            vcrThreeFingerTriggered = YES;
            VCRTriggerRecordingFromThreeFingerSwipe();
        } else if (elapsed > 2.0) {
            if (vcrLogGestures) VCRLog(@"Three-finger gesture timed out dy=%.1f dx=%.1f", dy, dx);
            VCRResetThreeFingerGesture();
            return;
        }
    }

    if (sawEndOrCancel) {
        for (UITouch *touch in touches) {
            if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
                [vcrGestureTouchPoints removeObjectForKey:[NSValue valueWithNonretainedObject:touch]];
            }
        }
    }

    if (vcrGestureTouchPoints.count == 0) VCRResetThreeFingerGesture();
}

static void VCRProcessCameraGestureEvent(UIEvent *event) {
    if (!vcrEnabled) return;
    if (!vcrCameraEnabled || !vcrCameraSwipeTrigger) return;
    if (!event || event.type != UIEventTypeTouches) return;

    NSSet<UITouch *> *touches = [event allTouches];
    if (touches.count == 0) return;
    if (!vcrCameraTouchPoints) vcrCameraTouchPoints = [NSMutableDictionary dictionary];

    BOOL sawEndOrCancel = NO;
    for (UITouch *touch in touches) {
        NSValue *key = [NSValue valueWithNonretainedObject:touch];
        CGPoint point = [touch locationInView:touch.window ?: touch.view];
        UITouchPhase phase = touch.phase;

        if (phase == UITouchPhaseBegan || phase == UITouchPhaseMoved || phase == UITouchPhaseStationary || phase == UITouchPhaseEnded) {
            vcrCameraTouchPoints[key] = [NSValue valueWithCGPoint:point];
        }
        if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) sawEndOrCancel = YES;
    }

    NSUInteger activeCount = vcrCameraTouchPoints.count;
    NSTimeInterval now = VCRNow();

    if (!vcrCameraTracking && activeCount >= (NSUInteger)vcrCameraFingerCount) {
        vcrCameraTracking = YES;
        vcrCameraTriggered = NO;
        vcrCameraStartCentroid = VCRCentroidForCameraTouches();
        vcrCameraStartTime = now;
        if (vcrLogGestures) VCRLog(@"Camera gesture tracking began count=%lu start=(%.1f, %.1f)", (unsigned long)activeCount, vcrCameraStartCentroid.x, vcrCameraStartCentroid.y);
    }

    if (vcrCameraTracking && !vcrCameraTriggered && activeCount >= (NSUInteger)vcrCameraFingerCount) {
        CGPoint current = VCRCentroidForCameraTouches();
        CGFloat dy = current.y - vcrCameraStartCentroid.y;
        CGFloat dx = fabs(current.x - vcrCameraStartCentroid.x);
        NSTimeInterval elapsed = now - vcrCameraStartTime;
        CGFloat distance = vcrCameraSwipeDistance;

        if (fabs(dy) >= distance && dx <= MAX(120.0, distance * 1.25) && elapsed <= 1.6) {
            vcrCameraTriggered = YES;
            if (now - vcrLastCameraTriggerTime >= 1.0) {
                vcrLastCameraTriggerTime = now;
                if (dy > 0.0) {
                    VCRLog(@"Camera gesture swipe down -> photo");
                    VCRTakePhoto();
                } else {
                    VCRLog(@"Camera gesture swipe up -> video toggle");
                    VCRToggleVideoRecording();
                }
            }
        } else if (elapsed > 2.0) {
            if (vcrLogGestures) VCRLog(@"Camera gesture timed out dy=%.1f dx=%.1f", dy, dx);
            VCRResetCameraGesture();
            return;
        }
    }

    if (sawEndOrCancel) {
        for (UITouch *touch in touches) {
            if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
                [vcrCameraTouchPoints removeObjectForKey:[NSValue valueWithNonretainedObject:touch]];
            }
        }
    }

    if (vcrCameraTouchPoints.count == 0) VCRResetCameraGesture();
}

static BOOL VCRNCNameContains(NSString *name, NSString *needle) {
    return [name rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL VCRNCNameContainsAny(NSString *name, NSArray<NSString *> *needles) {
    for (NSString *needle in needles) {
        if (VCRNCNameContains(name, needle)) return YES;
    }
    return NO;
}

static void VCRNCSetBackgroundAlpha(UIView *view, CGFloat alpha) {
    if (!view) return;

    view.opaque = NO;
    view.layer.opaque = NO;

    UIColor *bg = view.backgroundColor;
    if (bg) {
        view.backgroundColor = [bg colorWithAlphaComponent:alpha];
    } else if (alpha <= 0.01) {
        view.backgroundColor = [UIColor clearColor];
    }
}

static CGFloat VCRNCVisibleScreenAreaRatio(UIView *view) {
    if (!view || !view.window) return 0.0;

    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGRect rect = CGRectZero;

    @try {
        rect = [view convertRect:view.bounds toView:nil];
    } @catch (__unused NSException *exception) {
        return 0.0;
    }

    CGRect intersection = CGRectIntersection(rect, screenBounds);
    if (CGRectIsNull(intersection) || CGRectIsEmpty(intersection)) return 0.0;

    CGFloat screenArea = MAX(1.0, screenBounds.size.width * screenBounds.size.height);
    CGFloat viewArea = intersection.size.width * intersection.size.height;

    return viewArea / screenArea;
}

static BOOL VCRNCLooksLikeLargeBackgroundImage(UIView *view) {
    if (![view isKindOfClass:[UIImageView class]]) return NO;
    return VCRNCVisibleScreenAreaRatio(view) >= 0.55;
}

static BOOL VCRNCClassLooksLikeContext(NSString *className) {
    return VCRNCNameContainsAny(className, @[
        @"CoverSheet",
        @"DashBoard",
        @"NotificationCenter",
        @"NCNotification",
        @"NotificationList",
        @"CombinedList",
        @"SBCoverSheet",
        @"SBDashBoard",
        @"CSCoverSheet",
        @"CSCombinedList"
    ]);
}

static BOOL VCRNCWindowLooksLikeContext(UIWindow *window) {
    if (!window) return NO;
    NSString *className = NSStringFromClass([window class]);

    return VCRNCClassLooksLikeContext(className) ||
           VCRNCNameContainsAny(className, @[
               @"Notification",
               @"CoverSheet",
               @"DashBoard",
               @"NC"
           ]);
}

static BOOL VCRNCViewIsProtectedContent(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        NSString *className = NSStringFromClass([v class]);

        if (VCRNCNameContainsAny(className, @[
            @"Privacy",
            @"Indicator",
            @"StatusBar",
            @"Battery",
            @"Signal",
            @"TimeItem",
            @"MediaControls",
            @"NowPlaying",
            @"Platter",
            @"NotificationCell",
            @"CollectionViewCell",
            @"TableCell",
            @"ShortLook",
            @"LongLook",
            @"Banner",
            @"Button",
            @"Slider",
            @"Label",
            @"Text"
        ])) {
            return YES;
        }
    }

    return NO;
}

static BOOL VCRNCViewIsInsideContext(UIView *view) {
    if (!view || VCRNCViewIsProtectedContent(view)) return NO;

    for (UIView *v = view; v; v = v.superview) {
        if (VCRNCClassLooksLikeContext(NSStringFromClass([v class]))) return YES;
    }

    return VCRNCWindowLooksLikeContext(view.window);
}

static BOOL VCRNCShouldSkipSubview(UIView *view, NSString *className) {
    if (!view) return YES;

    if (VCRNCNameContainsAny(className, @[
        @"Privacy",
        @"Indicator",
        @"StatusBar",
        @"Battery",
        @"Signal",
        @"TimeItem",
        @"Label",
        @"Text",
        @"Button",
        @"Slider",
        @"Control",
        @"Icon",
        @"MediaControls",
        @"NowPlaying",
        @"Platter",
        @"NotificationCell",
        @"ShortLook",
        @"LongLook",
        @"Banner"
    ])) {
        return YES;
    }

    if ([view isKindOfClass:[UILabel class]] ||
        [view isKindOfClass:[UIButton class]] ||
        [view isKindOfClass:[UIControl class]]) {
        return YES;
    }

    if ([view isKindOfClass:[UIImageView class]] &&
        !VCRNCLooksLikeLargeBackgroundImage(view)) {
        return YES;
    }

    return NO;
}

static void VCRNCApplyRecursive(UIView *view, NSUInteger depth) {
    if (!vcrNCTransparencyEnabled || !view || depth > 12) return;

    NSString *className = NSStringFromClass([view class]);

    if (VCRNCShouldSkipSubview(view, className)) return;
    if (VCRNCViewIsProtectedContent(view)) return;

    BOOL isWallpaperOrBackground =
        VCRNCNameContainsAny(className, @[
            @"Wallpaper",
            @"Poster",
            @"BackgroundView",
            @"BackgroundContainer",
            @"CoverSheetBackground",
            @"DashBoardBackground",
            @"BackdropWallpaper",
            @"LockScreenBackground"
        ]) || VCRNCLooksLikeLargeBackgroundImage(view);

    BOOL isBlurOrMaterial =
        VCRNCNameContainsAny(className, @[
            @"Backdrop",
            @"VisualEffect",
            @"Material",
            @"Blur",
            @"Gaussian"
        ]);

    BOOL isDimOrScrim =
        VCRNCNameContainsAny(className, @[
            @"Dimming",
            @"Dimmer",
            @"Scrim",
            @"Tint",
            @"Overlay"
        ]);

    if (isWallpaperOrBackground) {
        view.alpha = vcrNCWallpaperAlpha;
        VCRNCSetBackgroundAlpha(view, vcrNCWallpaperAlpha);
    } else if (isBlurOrMaterial) {
        view.alpha = vcrNCBlurAlpha;
        VCRNCSetBackgroundAlpha(view, 0.0);
    } else if (isDimOrScrim) {
        view.alpha = vcrNCDimAlpha;
        VCRNCSetBackgroundAlpha(view, vcrNCDimAlpha);
    }

    if (vcrNCLogViews && (isWallpaperOrBackground || isBlurOrMaterial || isDimOrScrim)) {
        VCRLog(@"NC transparency touched %@ alpha=%.2f", className, view.alpha);
    }

    for (UIView *subview in view.subviews) {
        VCRNCApplyRecursive(subview, depth + 1);
    }
}

static void VCRNCApplyToContainer(UIView *root) {
    if (!vcrNCTransparencyEnabled || !root) return;

    root.opaque = NO;
    root.layer.opaque = NO;
    root.clipsToBounds = NO;

    VCRNCSetBackgroundAlpha(root, 0.0);
    VCRNCApplyRecursive(root, 0);
}

static void VCRNCFindAndApplyInView(UIView *view, NSUInteger depth) {
    if (!vcrNCTransparencyEnabled || !view || depth > 12) return;

    NSString *className = NSStringFromClass([view class]);

    if (VCRNCClassLooksLikeContext(className)) {
        if (vcrNCLogViews) VCRLog(@"NC transparency context found %@", className);
        VCRNCApplyToContainer(view);
        return;
    }

    for (UIView *subview in view.subviews) {
        VCRNCFindAndApplyInView(subview, depth + 1);
    }
}

static void VCRNCApplyToAllKnownWindows(void) {
    if (!vcrNCTransparencyEnabled) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *app = [UIApplication sharedApplication];

        for (UIWindow *window in app.windows) {
            if (VCRNCWindowLooksLikeContext(window)) {
                if (vcrNCLogViews) {
                    VCRLog(@"Applying NC transparency to window %@", NSStringFromClass([window class]));
                }

                window.opaque = NO;
                window.layer.opaque = NO;
                VCRNCSetBackgroundAlpha(window, 0.0);
                VCRNCApplyToContainer(window);
            } else {
                VCRNCFindAndApplyInView(window, 0);
            }
        }
    });
}

static void VCRNCSchedulePass(NSTimeInterval delay) {
    if (!vcrNCTransparencyEnabled) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        VCRNCApplyToAllKnownWindows();
    });
}

static void VCRNCScheduleBurst(void) {
    if (!vcrNCTransparencyEnabled) return;

    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - vcrLastNCTransparencyBurst < 0.25) return;

    vcrLastNCTransparencyBurst = now;

    VCRNCSchedulePass(0.00);
    VCRNCSchedulePass(0.08);
    VCRNCSchedulePass(0.20);
    VCRNCSchedulePass(0.45);
    VCRNCSchedulePass(0.80);
}

static void VCRNCApplyToContainerAndBurst(UIView *root) {
    VCRNCApplyToContainer(root);
    VCRNCScheduleBurst();
}

static void VCRNCApplyToMaterialView(UIView *view) {
    if (!vcrNCTransparencyEnabled || !VCRNCViewIsInsideContext(view)) return;

    NSString *className = NSStringFromClass([view class]);
    if (VCRNCShouldSkipSubview(view, className)) return;

    view.opaque = NO;
    view.layer.opaque = NO;
    view.alpha = vcrNCBlurAlpha;
    VCRNCSetBackgroundAlpha(view, 0.0);

    if (vcrNCLogViews) {
        VCRLog(@"NC transparency material %@ alpha=%.2f", className, view.alpha);
    }
}

%hook SBSensorActivityDataProvider
- (void)_handleNewDomainData:(id)arg1 {
    return;
}
%end

%hook SpringBoard

- (void)sendEvent:(UIEvent *)event {    
    VCRProcessCameraGestureEvent(event);
    VCRProcessThreeFingerSwipeEvent(event);
    %orig(event);
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    @try {
        for (UIPress *press in presses) {
            NSInteger type = press.type;
            // Type 104 is not a documented volume type, so record what the press really is.
            NSString *detail = [press description] ?: @"?";
            if (detail.length > 110) detail = [detail substringToIndex:110];
            VCRLog(@"press began type=%ld (state up=%d down=%d) %@", (long)type, volumeUpPressed, volumeDownPressed, detail);
            VCRDebugBump(@"debugPressTypes", [NSString stringWithFormat:@"began%ld", (long)type]);
            if (VCRPressTypeIsVolumeUp(type)) volumeUpPressed = YES;
            if (VCRPressTypeIsVolumeDown(type)) volumeDownPressed = YES;
        }
        VCRCheckChord();
    } @catch (NSException *exception) {
        VCRDebugEvent([NSString stringWithFormat:@"press hook exception: %@", exception.reason]);
    }
    %orig;
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    @try {
        for (UIPress *press in presses) {
            NSInteger type = press.type;
            VCRLog(@"press ended type=%ld", (long)type);
            VCRDebugBump(@"debugPressTypes", [NSString stringWithFormat:@"ended%ld", (long)type]);
            if (VCRPressTypeIsVolumeUp(type)) volumeUpPressed = NO;
            if (VCRPressTypeIsVolumeDown(type)) volumeDownPressed = NO;
        }
        VCRCheckChord();
    } @catch (NSException *exception) {
        VCRDebugEvent([NSString stringWithFormat:@"press hook exception: %@", exception.reason]);
    }
    %orig;
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    @try {
        VCRLog(@"pressesCancelled");
        VCRDebugEvent(@"pressesCancelled");
        volumeUpPressed = NO;
        volumeDownPressed = NO;
        VCRResetChordState();
    } @catch (NSException *exception) {
        VCRDebugEvent([NSString stringWithFormat:@"press cancel exception: %@", exception.reason]);
    }
    %orig;
}

%end

%group VCRCSCoverSheetViewControllerHooks
%hook CSCoverSheetViewController

- (void)viewDidLoad {
    %orig;
    VCRNCApplyToContainerAndBurst(((UIViewController *)self).view);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    VCRNCApplyToContainerAndBurst(((UIViewController *)self).view);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    VCRNCApplyToContainerAndBurst(((UIViewController *)self).view);
}

- (void)viewDidLayoutSubviews {
    %orig;
    VCRNCApplyToContainerAndBurst(((UIViewController *)self).view);
}

%end
%end

%group VCRSBDashBoardViewControllerHooks
%hook SBDashBoardViewController

- (void)viewDidLoad {
    %orig;
    VCRNCApplyToContainerAndBurst(((UIViewController *)self).view);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    VCRNCApplyToContainerAndBurst(((UIViewController *)self).view);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    VCRNCApplyToContainerAndBurst(((UIViewController *)self).view);
}

- (void)viewDidLayoutSubviews {
    %orig;
    VCRNCApplyToContainerAndBurst(((UIViewController *)self).view);
}

%end
%end

%group VCRSBNotificationCenterViewControllerHooks
%hook SBNotificationCenterViewController

- (void)viewDidLoad {
    %orig;
    VCRNCApplyToContainerAndBurst(((UIViewController *)self).view);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    VCRNCApplyToContainerAndBurst(((UIViewController *)self).view);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    VCRNCApplyToContainerAndBurst(((UIViewController *)self).view);
}

- (void)viewDidLayoutSubviews {
    %orig;
    VCRNCApplyToContainerAndBurst(((UIViewController *)self).view);
}

%end
%end

%group VCRNCNotificationListViewControllerHooks
%hook NCNotificationListViewController

- (void)viewDidLayoutSubviews {
    %orig;
    VCRNCApplyToContainerAndBurst(((UIViewController *)self).view);
}

%end
%end

%group VCRCSCoverSheetViewHooks
%hook CSCoverSheetView

- (void)layoutSubviews {
    %orig;
    VCRNCApplyToContainerAndBurst((UIView *)self);
}

%end
%end

%group VCRSBDashBoardViewHooks
%hook SBDashBoardView

- (void)layoutSubviews {
    %orig;
    VCRNCApplyToContainerAndBurst((UIView *)self);
}

%end
%end

%group VCRSBCoverSheetWindowHooks
%hook SBCoverSheetWindow

- (void)layoutSubviews {
    %orig;
    VCRNCApplyToContainerAndBurst((UIView *)self);
}

%end
%end

%group VCRSBNotificationCenterWindowHooks
%hook SBNotificationCenterWindow

- (void)layoutSubviews {
    %orig;
    VCRNCApplyToContainerAndBurst((UIView *)self);
}

%end
%end

%group VCRUIVisualEffectViewHooks
%hook UIVisualEffectView

- (void)didMoveToWindow {
    %orig;
    VCRNCApplyToMaterialView((UIView *)self);
    VCRNCScheduleBurst();
}

- (void)layoutSubviews {
    %orig;
    VCRNCApplyToMaterialView((UIView *)self);
}

- (void)setAlpha:(CGFloat)alpha {
    if (vcrNCTransparencyEnabled && VCRNCViewIsInsideContext((UIView *)self)) {
        %orig(vcrNCBlurAlpha);
        return;
    }

    %orig(alpha);
}

%end
%end

%group VCRMTMaterialViewHooks
%hook MTMaterialView

- (void)didMoveToWindow {
    %orig;
    VCRNCApplyToMaterialView((UIView *)self);
    VCRNCScheduleBurst();
}

- (void)layoutSubviews {
    %orig;
    VCRNCApplyToMaterialView((UIView *)self);
}

- (void)setAlpha:(CGFloat)alpha {
    if (vcrNCTransparencyEnabled && VCRNCViewIsInsideContext((UIView *)self)) {
        %orig(vcrNCBlurAlpha);
        return;
    }

    %orig(alpha);
}

%end
%end

// ===================== Volume hardware button chord =====================
// Volume presses do NOT arrive as UIPress type 102/103 in SpringBoard on iOS 16.4.1 - the only
// press type ever logged was 104 (that is not the volume keys). The real entry points below were
// read off the running SpringBoard with VCRDumpVolumeAPI(), never guessed: hooking an invented
// class name crashes the tweak at load.
//
// The *PressDown* / *PressUp pairs map exactly onto "both held" / "released", which is what the
// chord needs. The class is also feature-checked at %init time, like the other groups here.
// SpringBoard has died (which puts the device in safe mode) while the chord was in use, and this
// jailbreak leaves no crash report behind, so collect the reason ourselves. Exceptions come through
// the usual hook; fatal signals go through a descriptor opened once at load time, because only
// write() may be used that late.
static int vcrCrashDescriptor = -1;

static void VCRSignalHandler(int signalNumber) {
    if (vcrCrashDescriptor >= 0) {
        char line[64];
        int length = snprintf(line, sizeof line, "tweak fatal signal %d\n", signalNumber);
        if (length > 0) write(vcrCrashDescriptor, line, (size_t)length);
    }
    signal(signalNumber, SIG_DFL);
    raise(signalNumber);
}

static void VCRExceptionHandler(NSException *exception) {
    NSArray<NSString *> *frames = exception.callStackSymbols ?: @[];
    NSString *where = [frames subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)8, frames.count))].componentsJoinedByString:@" <- ";
    VCRDebugEvent([NSString stringWithFormat:@"TWEAK CRASH %@: %@ | %@", exception.name, exception.reason, where]);
}

// One place for the four volume hook bodies. The original SpringBoard handling runs first (%orig),
// and everything of ours is wrapped and deferred to the main queue, so a stray exception in here
// can never take the process down with it.
static void VCRVolumeButtonEvent(BOOL isIncrease, BOOL isDown) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (isIncrease) {
                volumeUpPressed = isDown;
                VCRDebugEvent(isDown ? @"volbtn + down" : @"volbtn + up");
                VCRDebugBump(@"debugVolBtn", isDown ? @"increase-down" : @"increase-up");
            } else {
                volumeDownPressed = isDown;
                VCRDebugEvent(isDown ? @"volbtn - down" : @"volbtn - up");
                VCRDebugBump(@"debugVolBtn", isDown ? @"decrease-down" : @"decrease-up");
            }
            VCRCheckChord();
        } @catch (NSException *exception) {
            VCRDebugEvent([NSString stringWithFormat:@"chord hook exception: %@", exception.reason]);
        }
    });
}

%group VCRVolumeButtonHooks
%hook SBVolumeHardwareButtonActions

- (void)volumeIncreasePressDownWithModifiers:(id)modifiers {
    %orig;
    VCRVolumeButtonEvent(YES, YES);
}

- (void)volumeIncreasePressUp {
    %orig;
    VCRVolumeButtonEvent(YES, NO);
}

- (void)volumeDecreasePressDownWithModifiers:(id)modifiers {
    %orig;
    VCRVolumeButtonEvent(NO, YES);
}

- (void)volumeDecreasePressUp {
    %orig;
    VCRVolumeButtonEvent(NO, NO);
}

%end
%end

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";

        NSSetUncaughtExceptionHandler(&VCRExceptionHandler);
        vcrCrashDescriptor = open("/private/var/tmp/VolumeChordRecorder.crash", O_WRONLY | O_CREAT | O_APPEND, 0644);
        {
            static const int signals[] = {SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP};
            for (unsigned long index = 0; index < sizeof(signals) / sizeof(signals[0]); index++) {
                signal(signals[index], VCRSignalHandler);
            }
        }

        // Load evidence. CFPreferences is sandbox-safe (unlike file writes, which SpringBoard
        // may deny silently), so this records whether the dylib was actually injected and what
        // bundle identifier the host process really reports. Written BEFORE the bundle check on
        // purpose, so a missing stamp means "not injected" rather than "check failed".
        CFStringRef vcrDomain = CFSTR("com.yourname.volumechordrecorder");
        CFPreferencesSetAppValue(CFSTR("debugLastLoadBundle"), (__bridge CFStringRef)bundleID, vcrDomain);
        CFPreferencesSetAppValue(CFSTR("debugLastLoadTime"), (__bridge CFStringRef)[[NSDate date] description], vcrDomain);
        CFPreferencesAppSynchronize(vcrDomain);

        if (![bundleID isEqualToString:@"com.apple.springboard"]) return;

        // Secondary volume signal. Volume button presses also surface as AVSystemController
        // volume-change notifications, so recording them tells us whether the press hook
        // actually receives volume presses at all.
        [[NSNotificationCenter defaultCenter] addObserverForName:@"AVSystemController_SystemVolumeDidChangeNotification"
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            NSString *reason = note.userInfo[@"AVSystemController_AudioVolumeChangeReasonNotificationParameter"];
            id volume = note.userInfo[@"AVSystemController_AudioVolumeNotificationParameter"];
            VCRDebugEvent([NSString stringWithFormat:@"volchange reason=%@ volume=%@", reason ?: @"?", volume ?: @"?"]);
            VCRDebugBump(@"debugVolchg", reason ?: @"(no reason)");
        }];

        VCRLoadPrefs();

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{ VCRDumpVolumeAPI(); });

        // Telegram uploads report into the same CFPreferences debug log the Settings pane shows.
        VCRTelegramSetLogger(^(NSString *message) { VCRDebugEvent(message); });

        notify_register_dispatch("com.yourname.volumechordrecorder.telegramtest", &vcrTelegramTestToken, dispatch_get_main_queue(), ^(__unused int t) {
            VCRTelegramSendText([NSString stringWithFormat:@"VolumeChordRecorder test from %@", [[UIDevice currentDevice] name]], nil);
        });
        notify_register_dispatch("com.yourname.volumechordrecorder.telegramsendlatest", &vcrTelegramLatestToken, dispatch_get_main_queue(), ^(__unused int t) {
            NSURL *newest = VCRNewestRecordingURL();
            if (!newest) {
                VCRDebugEvent(@"telegram: no recording found");
                return;
            }
            VCRTelegramSendFile(newest, VCRTelegramKindForPath(newest.path), nil);
        });

        int prefsToken = 0;
        notify_register_dispatch("com.yourname.volumechordrecorder.prefschanged", &prefsToken, dispatch_get_main_queue(), ^(__unused int t) {
            VCRLoadPrefs();
            if (!vcrEnabled && isRecording) {
                VCRLog(@"Disabled from Settings while recording, stopping");
                VCRStopRecording();
            }
            if (!vcrEnabled && vcrCameraRecording) {
                VCRLog(@"Disabled from Settings while recording video, stopping");
                VCRStopVideoRecording();
            }
            VCRNCApplyToAllKnownWindows();
        });
// Ungrouped hooks (SpringBoard volume/sendEvent, SBSensorActivityDataProvider) live in
// Logos' implicit _ungrouped group. Because this file uses %group elsewhere, Logos requires
// _ungrouped to be initialized explicitly or the whole file fails to build.
%init(_ungrouped);

if (objc_getClass("CSCoverSheetViewController")) %init(VCRCSCoverSheetViewControllerHooks);
if (objc_getClass("SBDashBoardViewController")) %init(VCRSBDashBoardViewControllerHooks);
if (objc_getClass("SBNotificationCenterViewController")) %init(VCRSBNotificationCenterViewControllerHooks);
if (objc_getClass("NCNotificationListViewController")) %init(VCRNCNotificationListViewControllerHooks);

if (objc_getClass("CSCoverSheetView")) %init(VCRCSCoverSheetViewHooks);
if (objc_getClass("SBDashBoardView")) %init(VCRSBDashBoardViewHooks);
if (objc_getClass("SBCoverSheetWindow")) %init(VCRSBCoverSheetWindowHooks);
if (objc_getClass("SBNotificationCenterWindow")) %init(VCRSBNotificationCenterWindowHooks);

%init(VCRUIVisualEffectViewHooks);

if (objc_getClass("MTMaterialView")) %init(VCRMTMaterialViewHooks);

if (objc_getClass("SBVolumeHardwareButtonActions")) %init(VCRVolumeButtonHooks);

int applyNCToken = 0;
notify_register_dispatch("com.yourname.volumechordrecorder.applyNCTransparency", &applyNCToken, dispatch_get_main_queue(), ^(__unused int t) {
    VCRLoadPrefs();
    VCRNCApplyToAllKnownWindows();
});
        VCRLog(@"Loaded SAFE SpringBoard-only build, volumeUpType=%d volumeDownType=%d volumeChord=%d threeSwipe=%d", VCR_PRESS_TYPE_VOLUME_UP, VCR_PRESS_TYPE_VOLUME_DOWN, vcrVolumeChordTrigger, vcrThreeFingerSwipeDownTrigger);
    }
}
