#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <notify.h>
#import <math.h>

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

static BOOL volumeUpPressed = NO;
static BOOL volumeDownPressed = NO;
static NSTimer *holdTimer = nil;
static NSTimer *maxRecordTimer = nil;
static AVAudioRecorder *recorder = nil;
static BOOL isRecording = NO;

#ifndef VCR_PRESS_TYPE_VOLUME_UP
#define VCR_PRESS_TYPE_VOLUME_UP 102
#endif
#ifndef VCR_PRESS_TYPE_VOLUME_DOWN
#define VCR_PRESS_TYPE_VOLUME_DOWN 103
#endif

static BOOL VCRPressTypeIsVolumeUp(NSInteger type) { return type == VCR_PRESS_TYPE_VOLUME_UP; }
static BOOL VCRPressTypeIsVolumeDown(NSInteger type) { return type == VCR_PRESS_TYPE_VOLUME_DOWN; }

static void VCRLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"%@ %@", VCRPrefix, msg);
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

static void VCRLoadPrefs(void) {
    vcrEnabled = VCRBoolPref(@"enabled", YES);
    vcrHaptics = VCRBoolPref(@"haptics", YES);
    vcrLogPresses = VCRBoolPref(@"logPresses", NO);
    vcrHoldSeconds = VCRDoublePref(@"holdSeconds", 2.0, 0.0, 10.0);
    vcrMaxRecordSeconds = VCRDoublePref(@"maxRecordSeconds", 600.0, 5.0, 7200.0);
    vcrVolumeChordTrigger = VCRBoolPref(@"volumeChordTrigger", NO);
    vcrThreeFingerSwipeDownTrigger = VCRBoolPref(@"threeFingerSwipeDownTrigger", YES);
    vcrThreeFingerSwipeDistance = (CGFloat)VCRDoublePref(@"threeFingerSwipeDistance", 140.0, 60.0, 500.0);
    vcrLogGestures = VCRBoolPref(@"logGestures", NO);

    VCRLog(@"Prefs loaded enabled=%d volumeChord=%d threeSwipe=%d swipeDistance=%.0f hold=%.2fs max=%.0fs haptics=%d logPresses=%d logGestures=%d SAFE_NO_NC=1",
           vcrEnabled, vcrVolumeChordTrigger, vcrThreeFingerSwipeDownTrigger, vcrThreeFingerSwipeDistance,
           vcrHoldSeconds, vcrMaxRecordSeconds, vcrHaptics, vcrLogPresses, vcrLogGestures);
}

static void VCRPlayHaptic(SystemSoundID soundID) {
    if (!vcrHaptics) return;
    AudioServicesPlaySystemSound(soundID);
}

static void VCRHapticStart(void) {
    VCRPlayHaptic(1519);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ VCRPlayHaptic(1520); });
}

static void VCRHapticStop(void) {
    VCRPlayHaptic(1520);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.13 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ VCRPlayHaptic(1520); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.28 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ VCRPlayHaptic(1519); });
}

static NSString *VCRRecordingDirectory(void) { return @"/var/mobile/Media/VolumeChordRecorder"; }

static NSString *VCRTimestampFilename(void) {
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"yyyyMMdd_HHmmss";
    return [NSString stringWithFormat:@"VCR_%@.m4a", [fmt stringFromDate:[NSDate date]]];
}

static void VCRStopRecording(void);

static void VCRStartRecording(void) {
    if (isRecording) return;

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
    if ([recorder record]) {
        isRecording = YES;
        VCRHapticStart();
        VCRLog(@"Recording started: %@", path);
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
    [recorder stop];
    recorder = nil;
    [[AVAudioSession sharedInstance] setActive:NO error:nil];
    isRecording = NO;
    VCRHapticStop();
    VCRLog(@"Recording stopped");
}

static void VCRToggleRecording(void) {
    if (!vcrEnabled) return;
    if (isRecording) VCRStopRecording();
    else VCRStartRecording();
}

static void VCRCancelHoldTimer(void) {
    if (holdTimer) {
        [holdTimer invalidate];
        holdTimer = nil;
    }
}

static void VCRCheckChord(void) {
    if (!vcrEnabled || !vcrVolumeChordTrigger) {
        VCRCancelHoldTimer();
        return;
    }

    if (volumeUpPressed && volumeDownPressed && !holdTimer) {
        VCRLog(@"Volume chord detected, hold %.2fs...", vcrHoldSeconds);
        holdTimer = [NSTimer scheduledTimerWithTimeInterval:vcrHoldSeconds repeats:NO block:^(__unused NSTimer *timer) {
            holdTimer = nil;
            if (volumeUpPressed && volumeDownPressed && vcrEnabled && vcrVolumeChordTrigger) {
                VCRLog(@"Volume chord confirmed");
                VCRToggleRecording();
            }
        }];
    }

    if (!volumeUpPressed || !volumeDownPressed) VCRCancelHoldTimer();
}

static NSMutableDictionary<NSValue *, NSValue *> *vcrGestureTouchPoints = nil;
static BOOL vcrThreeFingerTracking = NO;
static BOOL vcrThreeFingerTriggered = NO;
static CGPoint vcrThreeFingerStartCentroid = {0.0, 0.0};
static NSTimeInterval vcrThreeFingerStartTime = 0.0;
static NSTimeInterval vcrLastThreeFingerTriggerTime = 0.0;

static NSTimeInterval VCRNow(void) { return [NSDate timeIntervalSinceReferenceDate]; }

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

%hook SpringBoard

- (void)sendEvent:(UIEvent *)event {
    VCRProcessThreeFingerSwipeEvent(event);
    %orig(event);
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *press in presses) {
        NSInteger type = press.type;
        if (vcrLogPresses) VCRLog(@"press began type=%ld", (long)type);
        if (VCRPressTypeIsVolumeUp(type)) volumeUpPressed = YES;
        if (VCRPressTypeIsVolumeDown(type)) volumeDownPressed = YES;
    }
    VCRCheckChord();
    %orig;
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *press in presses) {
        NSInteger type = press.type;
        if (vcrLogPresses) VCRLog(@"press ended type=%ld", (long)type);
        if (VCRPressTypeIsVolumeUp(type)) volumeUpPressed = NO;
        if (VCRPressTypeIsVolumeDown(type)) volumeDownPressed = NO;
    }
    VCRCheckChord();
    %orig;
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    volumeUpPressed = NO;
    volumeDownPressed = NO;
    VCRCancelHoldTimer();
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        if (![bundleID isEqualToString:@"com.apple.springboard"]) return;
        VCRLoadPrefs();

        int prefsToken = 0;
        notify_register_dispatch("com.yourname.volumechordrecorder.prefschanged", &prefsToken, dispatch_get_main_queue(), ^(__unused int t) {
            VCRLoadPrefs();
            if (!vcrEnabled && isRecording) {
                VCRLog(@"Disabled from Settings while recording, stopping");
                VCRStopRecording();
            }
        });

        VCRLog(@"Loaded SAFE SpringBoard-only build, volumeUpType=%d volumeDownType=%d volumeChord=%d threeSwipe=%d", VCR_PRESS_TYPE_VOLUME_UP, VCR_PRESS_TYPE_VOLUME_DOWN, vcrVolumeChordTrigger, vcrThreeFingerSwipeDownTrigger);
    }
}
