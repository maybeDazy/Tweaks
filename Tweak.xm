#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <notify.h>
#import <math.h>
#import <objc/runtime.h>
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

static BOOL vcrNCTransparencyEnabled = NO;
static CGFloat vcrNCWallpaperAlpha = 0.00;
static CGFloat vcrNCBlurAlpha = 0.12;
static CGFloat vcrNCDimAlpha = 0.00;
static BOOL vcrNCLogViews = NO;
static NSTimeInterval vcrLastNCTransparencyBurst = 0.0;

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
    vcrNCTransparencyEnabled = VCRBoolPref(@"ncTransparencyEnabled", NO);
    vcrNCWallpaperAlpha = (CGFloat)VCRDoublePref(@"ncWallpaperAlpha", 0.00, 0.0, 1.0);
    vcrNCBlurAlpha = (CGFloat)VCRDoublePref(@"ncBlurAlpha", 0.12, 0.0, 1.0);
    vcrNCDimAlpha = (CGFloat)VCRDoublePref(@"ncDimAlpha", 0.00, 0.0, 1.0);
    vcrNCLogViews = VCRBoolPref(@"ncLogViews", NO);
    vcrEnabled = VCRBoolPref(@"enabled", YES);
    vcrHaptics = VCRBoolPref(@"haptics", YES);
    vcrLogPresses = VCRBoolPref(@"logPresses", NO);
    vcrHoldSeconds = VCRDoublePref(@"holdSeconds", 2.0, 0.0, 10.0);
    vcrMaxRecordSeconds = VCRDoublePref(@"maxRecordSeconds", 600.0, 5.0, 7200.0);
    vcrVolumeChordTrigger = VCRBoolPref(@"volumeChordTrigger", NO);
    vcrThreeFingerSwipeDownTrigger = VCRBoolPref(@"threeFingerSwipeDownTrigger", YES);
    vcrThreeFingerSwipeDistance = (CGFloat)VCRDoublePref(@"threeFingerSwipeDistance", 140.0, 60.0, 500.0);
    vcrLogGestures = VCRBoolPref(@"logGestures", NO);

    VCRLog(@"Prefs loaded enabled=%d volumeChord=%d threeSwipe=%d swipeDistance=%.0f hold=%.2fs max=%.0fs haptics=%d logPresses=%d logGestures=%d nc=%d wallpaper=%.2f blur=%.2f dim=%.2f",
           vcrEnabled, vcrVolumeChordTrigger, vcrThreeFingerSwipeDownTrigger, vcrThreeFingerSwipeDistance,
           vcrHoldSeconds, vcrMaxRecordSeconds, vcrHaptics, vcrLogPresses, vcrLogGestures,
           vcrNCTransparencyEnabled, vcrNCWallpaperAlpha, vcrNCBlurAlpha, vcrNCDimAlpha);
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.13 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        VCRPlayHaptic(1520);
    });
}

static void VCRShowNotification(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CFUserNotificationDisplayNotice(
            0,                          // timeout (0 = no timeout)
            0,                          // flags
            NULL,                       // icon
            NULL,                       // sound
            NULL,                       // localization
            (CFStringRef)title,         // title
            (CFStringRef)message,       // message
            NULL                        // default button
        );
    });
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
    [recorder stop];
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
            VCRNCApplyToAllKnownWindows();
        });
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

int applyNCToken = 0;
notify_register_dispatch("com.yourname.volumechordrecorder.applyNCTransparency", &applyNCToken, dispatch_get_main_queue(), ^(__unused int t) {
    VCRLoadPrefs();
    VCRNCApplyToAllKnownWindows();
});
        VCRLog(@"Loaded SAFE SpringBoard-only build, volumeUpType=%d volumeDownType=%d volumeChord=%d threeSwipe=%d", VCR_PRESS_TYPE_VOLUME_UP, VCR_PRESS_TYPE_VOLUME_DOWN, vcrVolumeChordTrigger, vcrThreeFingerSwipeDownTrigger);
    }
}
