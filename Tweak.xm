#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <notify.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <math.h>

static NSString * const VCRPrefsID = @"com.yourname.volumechordrecorder";
static NSString * const VCRPrefix = @"[VolumeChordRecorder]";

static BOOL vcrEnabled = YES;
static BOOL vcrHaptics = YES;
static BOOL vcrLogPresses = YES;
static NSTimeInterval vcrHoldSeconds = 2.0;
static NSTimeInterval vcrMaxRecordSeconds = 600.0;

static BOOL vcrVolumeChordTrigger = YES;
static BOOL vcrThreeFingerSwipeDownTrigger = YES;
static CGFloat vcrThreeFingerSwipeDistance = 140.0;
static BOOL vcrLogGestures = NO;

static BOOL vcrNCTransparencyEnabled = NO;
static CGFloat vcrNCWallpaperAlpha = 0.00;
static CGFloat vcrNCBlurAlpha = 0.08;
static CGFloat vcrNCDimAlpha = 0.00;
static BOOL vcrNCLogViews = NO;
static BOOL vcrNCProtectNotificationCards = YES;
static BOOL vcrNCHideLockscreenWallpaper = YES;
static BOOL vcrNCLivePassthrough = YES;
static BOOL vcrNCActive = NO;
static BOOL vcrNCUseSnapshotUnderlay = NO;
static UIView *vcrNCSnapshotUnderlay = nil;
static NSHashTable<UIView *> *vcrNCLiveHiddenViews = nil;
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

static BOOL VCRPressTypeIsVolumeUp(NSInteger type) {
    return type == VCR_PRESS_TYPE_VOLUME_UP;
}

static BOOL VCRPressTypeIsVolumeDown(NSInteger type) {
    return type == VCR_PRESS_TYPE_VOLUME_DOWN;
}


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
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) result = CFBooleanGetValue((CFBooleanRef)value);
    else if (CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)value, kCFNumberCharType, &result);
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
    vcrVolumeChordTrigger = VCRBoolPref(@"volumeChordTrigger", YES);
    vcrThreeFingerSwipeDownTrigger = VCRBoolPref(@"threeFingerSwipeDownTrigger", YES);
    vcrThreeFingerSwipeDistance = (CGFloat)VCRDoublePref(@"threeFingerSwipeDistance", 140.0, 60.0, 500.0);
    vcrLogGestures = VCRBoolPref(@"logGestures", NO);

    vcrNCTransparencyEnabled = VCRBoolPref(@"ncTransparencyEnabled", NO);
    vcrNCWallpaperAlpha = (CGFloat)VCRDoublePref(@"ncWallpaperAlpha", 0.00, 0.0, 1.0);
    vcrNCBlurAlpha = (CGFloat)VCRDoublePref(@"ncBlurAlpha", 0.08, 0.0, 1.0);
    vcrNCDimAlpha = (CGFloat)VCRDoublePref(@"ncDimAlpha", 0.00, 0.0, 1.0);
    vcrNCLogViews = VCRBoolPref(@"ncLogViews", NO);
    vcrNCProtectNotificationCards = VCRBoolPref(@"ncProtectNotificationCards", YES);
    vcrNCLivePassthrough = VCRBoolPref(@"ncLivePassthrough", YES);
    vcrNCHideLockscreenWallpaper = VCRBoolPref(@"ncHideLockscreenWallpaper", VCRBoolPref(@"ncHideLockWallpaper", YES));
    vcrNCUseSnapshotUnderlay = VCRBoolPref(@"ncUseSnapshotUnderlay", NO);

    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if ([bundleID isEqualToString:@"com.apple.springboard"] || vcrLogGestures || vcrLogPresses || vcrNCLogViews) {
        VCRLog(@"Prefs loaded enabled=%d volumeChord=%d threeSwipe=%d swipeDistance=%.0f hold=%.2fs max=%.0fs haptics=%d logPresses=%d logGestures=%d ncEnabled=%d wallpaper=%.2f blur=%.2f dim=%.2f protectCards=%d live=%d hideLockWallpaper=%d snapshot=%d",
               vcrEnabled, vcrVolumeChordTrigger, vcrThreeFingerSwipeDownTrigger, vcrThreeFingerSwipeDistance,
               vcrHoldSeconds, vcrMaxRecordSeconds, vcrHaptics, vcrLogPresses, vcrLogGestures,
               vcrNCTransparencyEnabled, vcrNCWallpaperAlpha, vcrNCBlurAlpha, vcrNCDimAlpha,
               vcrNCProtectNotificationCards, vcrNCLivePassthrough, vcrNCHideLockscreenWallpaper, vcrNCUseSnapshotUnderlay);
    }
}

static void VCRPlayHaptic(SystemSoundID soundID) {
    if (!vcrHaptics) return;
    AudioServicesPlaySystemSound(soundID);
}

static void VCRHapticStart(void) {
    VCRPlayHaptic(1519);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        VCRPlayHaptic(1520);
    });
}

static void VCRHapticStop(void) {
    VCRPlayHaptic(1520);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.13 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        VCRPlayHaptic(1520);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.28 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        VCRPlayHaptic(1519);
    });
}

static NSString *VCRRecordingDirectory(void) {
    return @"/var/mobile/Media/VolumeChordRecorder";
}

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
            if (volumeUpPressed && volumeDownPressed && vcrEnabled) {
                VCRLog(@"Volume chord confirmed");
                VCRToggleRecording();
            }
        }];
    }

    if (!volumeUpPressed || !volumeDownPressed) {
        VCRCancelHoldTimer();
    }
}


static NSString * const VCRToggleRecordingNotification = @"com.yourname.volumechordrecorder.toggleRecording";

static BOOL VCRIsSpringBoardProcess(void) {
    return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"];
}

static NSMutableDictionary<NSValue *, NSValue *> *vcrGestureTouchPoints = nil;
static BOOL vcrThreeFingerTracking = NO;
static BOOL vcrThreeFingerTriggered = NO;
static CGPoint vcrThreeFingerStartCentroid = {0.0, 0.0};
static NSTimeInterval vcrThreeFingerStartTime = 0.0;
static NSTimeInterval vcrLastThreeFingerTriggerTime = 0.0;

static NSTimeInterval VCRNow(void) {
    return [NSDate timeIntervalSinceReferenceDate];
}

static CGPoint VCRCentroidForGestureTouches(void) {
    CGFloat x = 0.0;
    CGFloat y = 0.0;
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

    if (VCRIsSpringBoardProcess()) {
        VCRLog(@"Three-finger swipe down confirmed in SpringBoard; toggling recording");
        VCRToggleRecording();
    } else {
        if (vcrLogGestures) VCRLog(@"Three-finger swipe down confirmed in %@; notifying SpringBoard", [[NSBundle mainBundle] bundleIdentifier]);
        notify_post([VCRToggleRecordingNotification UTF8String]);
    }
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
        if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
            sawEndOrCancel = YES;
        }
    }

    NSUInteger activeCount = vcrGestureTouchPoints.count;
    NSTimeInterval now = VCRNow();

    if (!vcrThreeFingerTracking && activeCount >= 3) {
        vcrThreeFingerTracking = YES;
        vcrThreeFingerTriggered = NO;
        vcrThreeFingerStartCentroid = VCRCentroidForGestureTouches();
        vcrThreeFingerStartTime = now;
        if (vcrLogGestures) {
            VCRLog(@"Three-finger gesture tracking began count=%lu start=(%.1f, %.1f) process=%@",
                   (unsigned long)activeCount, vcrThreeFingerStartCentroid.x, vcrThreeFingerStartCentroid.y,
                   [[NSBundle mainBundle] bundleIdentifier]);
        }
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

    if (vcrGestureTouchPoints.count == 0) {
        VCRResetThreeFingerGesture();
    }
}


static BOOL VCRNameContains(NSString *name, NSString *needle) {
    return [name rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL VCRNameContainsAny(NSString *name, NSArray<NSString *> *needles) {
    for (NSString *needle in needles) {
        if (VCRNameContains(name, needle)) return YES;
    }
    return NO;
}

static void VCRSetBackgroundAlpha(UIView *view, CGFloat alpha) {
    view.opaque = NO;
    UIColor *bg = view.backgroundColor;
    if (bg) {
        view.backgroundColor = [bg colorWithAlphaComponent:alpha];
    } else if (alpha <= 0.01) {
        view.backgroundColor = [UIColor clearColor];
    }
}

static CGFloat VCRViewVisibleScreenAreaRatio(UIView *view) {
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

static BOOL VCRViewLooksLikeFullscreenBackgroundImage(UIView *view) {
    if (![view isKindOfClass:[UIImageView class]]) return NO;
    return VCRViewVisibleScreenAreaRatio(view) >= 0.55;
}

static BOOL VCRClassLooksLikeLockWallpaperOrPoster(NSString *className) {
    return VCRNameContainsAny(className, @[
        @"Wallpaper", @"Poster", @"PRPoster", @"CSPoster", @"PosterContent",
        @"PosterView", @"StaticWallpaper", @"LockScreenWallpaper",
        @"SBFWallpaper", @"SBWallpaper", @"SBFLegibility", @"CoverSheetBackground",
        @"DashBoardBackground", @"CSCoverSheetBackground", @"CoverSheetBackdrop",
        @"WallpaperEffect", @"WallpaperBackdrop", @"WallpaperContainer"
    ]);
}

static void VCRHideLockWallpaperOrPosterView(UIView *view, NSString *className) {
    if (!vcrNCTransparencyEnabled || !vcrNCHideLockscreenWallpaper || !view) return;
    if (VCRClassLooksLikeLockWallpaperOrPoster(className) || VCRViewLooksLikeFullscreenBackgroundImage(view)) {
        view.opaque = NO;
        view.alpha = vcrNCWallpaperAlpha;
        VCRSetBackgroundAlpha(view, vcrNCWallpaperAlpha);
        if (vcrNCLogViews) VCRLog(@"NC live pass-through hid %@ alpha=%.2f ratio=%.2f", className, view.alpha, VCRViewVisibleScreenAreaRatio(view));
    }
}

static UIImage *VCRCreateScreenSnapshotImage(void) {
    typedef UIImage *(*VCRCreateUIImageFunc)(void);
    typedef CGImageRef (*VCRCreateCGImageFunc)(void);

    static VCRCreateUIImageFunc createUIImage = NULL;
    static VCRCreateCGImageFunc createCGImage = NULL;
    static VCRCreateCGImageFunc getCGImage = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        createUIImage = (VCRCreateUIImageFunc)dlsym(RTLD_DEFAULT, "UICreateScreenUIImage");
        createCGImage = (VCRCreateCGImageFunc)dlsym(RTLD_DEFAULT, "UICreateScreenImage");
        getCGImage = (VCRCreateCGImageFunc)dlsym(RTLD_DEFAULT, "UIGetScreenImage");
    });

    @try {
        if (createUIImage) {
            UIImage *image = createUIImage();
            if (image) return image;
        }
        VCRCreateCGImageFunc cgFunc = createCGImage ?: getCGImage;
        if (cgFunc) {
            CGImageRef cg = cgFunc();
            if (cg) {
                UIImage *image = [UIImage imageWithCGImage:cg scale:[UIScreen mainScreen].scale orientation:UIImageOrientationUp];
                CGImageRelease(cg);
                return image;
            }
        }
    } @catch (NSException *exception) {
        VCRLog(@"Screen snapshot exception: %@", exception);
    }

    if (vcrNCLogViews) VCRLog(@"No usable screen snapshot function found; current-screen underlay skipped");
    return nil;
}

static void VCRRemoveNCSnapshotUnderlay(void) {
    if (vcrNCSnapshotUnderlay) {
        [vcrNCSnapshotUnderlay removeFromSuperview];
        vcrNCSnapshotUnderlay = nil;
        if (vcrNCLogViews) VCRLog(@"NC current-screen snapshot underlay removed");
    }
}

static void VCRUpdateNCSnapshotFrame(UIView *root) {
    if (!vcrNCSnapshotUnderlay || !root) return;
    CGRect frame = root.bounds;
    if (CGRectIsEmpty(frame)) frame = [UIScreen mainScreen].bounds;
    vcrNCSnapshotUnderlay.frame = frame;
}

static void VCRInstallNCSnapshotUnderlayIfNeeded(UIView *root) {
    if (!vcrNCTransparencyEnabled || !vcrNCUseSnapshotUnderlay || !root) return;

    if (vcrNCSnapshotUnderlay && vcrNCSnapshotUnderlay.superview) {
        VCRUpdateNCSnapshotFrame(root);
        return;
    }

    UIImage *image = VCRCreateScreenSnapshotImage();
    if (!image) return;

    CGRect frame = root.bounds;
    if (CGRectIsEmpty(frame)) frame = [UIScreen mainScreen].bounds;

    UIImageView *imageView = [[UIImageView alloc] initWithImage:image];
    imageView.frame = frame;
    imageView.contentMode = UIViewContentModeScaleAspectFill;
    imageView.clipsToBounds = YES;
    imageView.userInteractionEnabled = NO;
    imageView.accessibilityElementsHidden = YES;
    imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    [root insertSubview:imageView atIndex:0];
    vcrNCSnapshotUnderlay = imageView;

    if (vcrNCLogViews) VCRLog(@"NC current-screen snapshot underlay installed in %@", NSStringFromClass([root class]));
}

static BOOL VCRViewIsInsideProtectedNCContent(UIView *view);
static void VCRHideViewForLivePassthrough(UIView *view);
static void VCRApplyLivePassthroughRecursive(UIView *view, NSUInteger depth);

static BOOL VCRShouldSkipNCSubview(UIView *view, NSString *className) {
    if (VCRNameContainsAny(className, @[
        @"Privacy", @"Indicator", @"StatusBar", @"Battery", @"Signal", @"TimeItem",
        @"Label", @"Text", @"Button", @"Slider", @"Control", @"Icon",
        @"MediaControls", @"NowPlaying", @"Platter", @"NotificationCell",
        @"ShortLook", @"LongLook", @"Banner"
    ])) {
        return YES;
    }
    if ([view isKindOfClass:[UILabel class]] || [view isKindOfClass:[UIButton class]]) {
        return YES;
    }
    if ([view isKindOfClass:[UIImageView class]] && !VCRViewLooksLikeFullscreenBackgroundImage(view)) {
        return YES;
    }
    return NO;
}

static void VCRApplyNCTransparencyRecursive(UIView *view, NSUInteger depth) {
    if (!view || depth > 10) return;

    NSString *className = NSStringFromClass([view class]);
    if (VCRShouldSkipNCSubview(view, className)) return;
    if (vcrNCProtectNotificationCards && VCRViewIsInsideProtectedNCContent(view)) return;

    VCRHideLockWallpaperOrPosterView(view, className);
    BOOL isWallpaper = VCRClassLooksLikeLockWallpaperOrPoster(className) || VCRViewLooksLikeFullscreenBackgroundImage(view);
    BOOL isDimOrScrim = VCRNameContainsAny(className, @[
        @"Dimming", @"Dimmer", @"Scrim", @"Tint", @"Overlay"
    ]);
    BOOL isBlurOrMaterial = VCRNameContainsAny(className, @[
        @"Backdrop", @"VisualEffect", @"Material", @"Blur", @"Gaussian"
    ]);
    BOOL isGenericBackground = VCRNameContainsAny(className, @[
        @"BackgroundView", @"BackgroundContainer"
    ]);

    if (isWallpaper) {
        if (vcrNCLivePassthrough && vcrNCHideLockscreenWallpaper) {
            VCRHideViewForLivePassthrough(view);
        } else {
            view.alpha = vcrNCWallpaperAlpha;
            VCRSetBackgroundAlpha(view, vcrNCWallpaperAlpha);
        }
    } else if (isDimOrScrim) {
        view.alpha = vcrNCDimAlpha;
        VCRSetBackgroundAlpha(view, vcrNCDimAlpha);
    } else if (isBlurOrMaterial) {
        view.alpha = vcrNCBlurAlpha;
        VCRSetBackgroundAlpha(view, 0.0);
    } else if (isGenericBackground) {
        view.alpha = vcrNCWallpaperAlpha;
        VCRSetBackgroundAlpha(view, 0.0);
    }

    if (vcrNCLogViews && (isWallpaper || isDimOrScrim || isBlurOrMaterial || isGenericBackground)) {
        VCRLog(@"NC transparency touched %@ alpha=%.2f", className, view.alpha);
    }

    for (UIView *subview in view.subviews) {
        VCRApplyNCTransparencyRecursive(subview, depth + 1);
    }
}

static BOOL VCRClassNameLooksLikeNCContext(NSString *className) {
    return VCRNameContainsAny(className, @[
        @"CoverSheet", @"DashBoard", @"NotificationCenter", @"NCNotification",
        @"NotificationList", @"CombinedList", @"SBCoverSheet", @"SBDashBoard",
        @"CSCoverSheet", @"CSCombinedList"
    ]);
}

static BOOL VCRWindowLooksLikeNotificationCenter(UIWindow *window) {
    NSString *className = NSStringFromClass([window class]);
    return VCRClassNameLooksLikeNCContext(className) || VCRNameContainsAny(className, @[
        @"Notification", @"NC"
    ]);
}

static BOOL VCRViewIsInsideProtectedNCContent(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        NSString *className = NSStringFromClass([v class]);
        if (VCRNameContainsAny(className, @[
            @"Privacy", @"Indicator", @"StatusBar", @"Battery", @"Signal", @"TimeItem",
            @"MediaControls", @"NowPlaying", @"Platter", @"NotificationCell",
            @"CollectionViewCell", @"TableCell", @"ShortLook", @"LongLook", @"Banner",
            @"Button", @"Slider", @"Label", @"Text"
        ])) {
            return YES;
        }
    }
    return NO;
}

static BOOL VCRViewIsInsideNCContext(UIView *view) {
    if (!view || VCRViewIsInsideProtectedNCContent(view)) return NO;
    for (UIView *v = view; v; v = v.superview) {
        if (VCRClassNameLooksLikeNCContext(NSStringFromClass([v class]))) return YES;
    }
    UIWindow *window = view.window;
    return window && VCRWindowLooksLikeNotificationCenter(window);
}

static BOOL VCRClassNameLooksLikeWallpaperOrPoster(NSString *className) {
    return VCRNameContainsAny(className, @[
        @"Wallpaper", @"SBFWallpaper", @"SBWallpaper", @"CSWallpaper",
        @"LockScreenWallpaper", @"StaticWallpaper", @"WallpaperEffect",
        @"Poster", @"PRPoster", @"PosterContent", @"PosterSwitcher",
        @"CSPoster", @"CoverSheetBackground", @"DashBoardBackground",
        @"LockScreenBackground", @"BackdropWallpaper", @"BackgroundPoster"
    ]);
}

static BOOL VCRWindowLooksLikeWallpaperOrCoverSheet(UIWindow *window) {
    if (!window) return NO;
    NSString *className = NSStringFromClass([window class]);
    return VCRClassNameLooksLikeNCContext(className) || VCRNameContainsAny(className, @[
        @"Wallpaper", @"CoverSheet", @"DashBoard", @"NotificationCenter", @"Poster"
    ]);
}

static void VCREnsureLiveHiddenViewsTable(void) {
    if (!vcrNCLiveHiddenViews) {
        vcrNCLiveHiddenViews = [NSHashTable weakObjectsHashTable];
    }
}

static const void *VCRLiveOriginalAlphaKey = &VCRLiveOriginalAlphaKey;
static const void *VCRLiveOriginalHiddenKey = &VCRLiveOriginalHiddenKey;

static BOOL VCRViewShouldBeHiddenForLivePassthrough(UIView *view, NSString *className) {
    if (!vcrNCTransparencyEnabled || !vcrNCLivePassthrough || !vcrNCHideLockscreenWallpaper) return NO;
    if (!view || view == vcrNCSnapshotUnderlay) return NO;

    BOOL inNC = VCRViewIsInsideNCContext(view);
    if (!vcrNCActive && !inNC) return NO;

    if (VCRShouldSkipNCSubview(view, className)) return NO;

    BOOL wallpaperOrPoster = VCRClassNameLooksLikeWallpaperOrPoster(className);
    BOOL largeImageWallpaper = [view isKindOfClass:[UIImageView class]] && VCRViewLooksLikeFullscreenBackgroundImage(view);
    BOOL inRelevantWindow = VCRWindowLooksLikeWallpaperOrCoverSheet(view.window);

    return wallpaperOrPoster || (largeImageWallpaper && (inNC || inRelevantWindow));
}

static void VCRHideViewForLivePassthrough(UIView *view) {
    if (!view) return;
    VCREnsureLiveHiddenViewsTable();

    if (!objc_getAssociatedObject(view, VCRLiveOriginalAlphaKey)) {
        objc_setAssociatedObject(view, VCRLiveOriginalAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, VCRLiveOriginalHiddenKey, @(view.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [vcrNCLiveHiddenViews addObject:view];
    }

    view.opaque = NO;
    view.layer.opaque = NO;
    view.alpha = 0.0;
    view.hidden = YES;
    VCRSetBackgroundAlpha(view, 0.0);

    if (vcrNCLogViews) {
        VCRLog(@"Live NC passthrough hid %@", NSStringFromClass([view class]));
    }
}

static void VCRRestoreLivePassthroughViews(void) {
    if (!vcrNCLiveHiddenViews) return;
    NSArray<UIView *> *views = vcrNCLiveHiddenViews.allObjects;
    for (UIView *view in views) {
        NSNumber *alpha = objc_getAssociatedObject(view, VCRLiveOriginalAlphaKey);
        NSNumber *hidden = objc_getAssociatedObject(view, VCRLiveOriginalHiddenKey);
        if (alpha) view.alpha = alpha.doubleValue;
        if (hidden) view.hidden = hidden.boolValue;
        objc_setAssociatedObject(view, VCRLiveOriginalAlphaKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(view, VCRLiveOriginalHiddenKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    [vcrNCLiveHiddenViews removeAllObjects];
    if (vcrNCLogViews) VCRLog(@"Live NC passthrough restored %lu view(s)", (unsigned long)views.count);
}

static void VCRApplyLivePassthroughToView(UIView *view) {
    if (!view) return;
    NSString *className = NSStringFromClass([view class]);
    if (VCRViewShouldBeHiddenForLivePassthrough(view, className)) {
        VCRHideViewForLivePassthrough(view);
    }
}

static void VCRApplyLivePassthroughRecursive(UIView *view, NSUInteger depth) {
    if (!view || depth > 14) return;
    VCRApplyLivePassthroughToView(view);
    for (UIView *subview in view.subviews) {
        VCRApplyLivePassthroughRecursive(subview, depth + 1);
    }
}

static void VCRApplyLivePassthroughToAllWindows(void) {
    if (!vcrNCTransparencyEnabled || !vcrNCLivePassthrough || !vcrNCActive) return;
    UIApplication *app = [UIApplication sharedApplication];
    for (UIWindow *window in app.windows) {
        if (VCRWindowLooksLikeWallpaperOrCoverSheet(window) || VCRWindowLooksLikeNotificationCenter(window)) {
            window.opaque = NO;
            window.layer.opaque = NO;
            VCRSetBackgroundAlpha(window, 0.0);
        }
        VCRApplyLivePassthroughRecursive(window, 0);
    }
}

static void VCRMarkNCActive(void) {
    vcrNCActive = YES;
}

static void VCRMarkNCInactive(void) {
    vcrNCActive = NO;
    VCRRemoveNCSnapshotUnderlay();
    VCRRestoreLivePassthroughViews();
}

static void VCRApplyNCTransparencyToContainer(UIView *root) {
    if (!vcrNCTransparencyEnabled || !root) return;
    VCRMarkNCActive();
    if (vcrNCUseSnapshotUnderlay && !vcrNCLivePassthrough) {
        VCRInstallNCSnapshotUnderlayIfNeeded(root);
    } else {
        VCRRemoveNCSnapshotUnderlay();
    }
    root.opaque = NO;
    root.layer.opaque = NO;
    root.clipsToBounds = NO;
    VCRSetBackgroundAlpha(root, 0.0);
    VCRHideLockWallpaperOrPosterView(root, NSStringFromClass([root class]));
    VCRApplyNCTransparencyRecursive(root, 0);
    VCRApplyLivePassthroughRecursive(root, 0);
}

static void VCRFindAndApplyNCTransparencyInView(UIView *view, NSUInteger depth) {
    if (!vcrNCTransparencyEnabled || !view || depth > 12) return;

    NSString *className = NSStringFromClass([view class]);
    if (VCRClassNameLooksLikeNCContext(className)) {
        if (vcrNCLogViews) VCRLog(@"NC transparency context found %@", className);
        VCRApplyNCTransparencyToContainer(view);
        return;
    }

    for (UIView *subview in view.subviews) {
        VCRFindAndApplyNCTransparencyInView(subview, depth + 1);
    }
}

static void VCRApplyNCTransparencyToAllKnownWindows(void) {
    if (!vcrNCTransparencyEnabled) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *app = [UIApplication sharedApplication];
        for (UIWindow *window in app.windows) {
            if (VCRWindowLooksLikeNotificationCenter(window)) {
                if (vcrNCLogViews) VCRLog(@"Applying NC transparency to window %@", NSStringFromClass([window class]));
                window.opaque = NO;
                VCRSetBackgroundAlpha(window, 0.0);
                VCRApplyNCTransparencyToContainer(window);
            } else {
                VCRFindAndApplyNCTransparencyInView(window, 0);
            }
        }
        VCRApplyLivePassthroughToAllWindows();
    });
}

static void VCRScheduleNCTransparencyPass(NSTimeInterval delay) {
    if (!vcrNCTransparencyEnabled) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        VCRApplyNCTransparencyToAllKnownWindows();
    });
}

static void VCRScheduleNCTransparencyBurst(void) {
    if (!vcrNCTransparencyEnabled) return;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - vcrLastNCTransparencyBurst < 0.20) return;
    vcrLastNCTransparencyBurst = now;
    VCRScheduleNCTransparencyPass(0.00);
    VCRScheduleNCTransparencyPass(0.05);
    VCRScheduleNCTransparencyPass(0.15);
    VCRScheduleNCTransparencyPass(0.35);
    VCRScheduleNCTransparencyPass(0.70);
    VCRScheduleNCTransparencyPass(1.10);
}

static void VCRApplyNCTransparencyToContainerAndBurst(UIView *root) {
    VCRApplyNCTransparencyToContainer(root);
    VCRScheduleNCTransparencyBurst();
}

static void VCRApplyNCTransparencyToMaterialView(UIView *view) {
    if (!vcrNCTransparencyEnabled || !VCRViewIsInsideNCContext(view)) return;
    NSString *className = NSStringFromClass([view class]);
    if (VCRShouldSkipNCSubview(view, className)) return;
    view.opaque = NO;
    view.alpha = vcrNCBlurAlpha;
    VCRSetBackgroundAlpha(view, 0.0);
    if (vcrNCLogViews) VCRLog(@"NC transparency enforced material %@ alpha=%.2f", className, view.alpha);
}

%group VCRApplicationGestureHooks
%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    VCRProcessThreeFingerSwipeEvent(event);
    %orig(event);
}

%end
%end

%group VCRSpringBoardHooks
%hook SpringBoard

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
%end

%group VCRCSCoverSheetViewControllerHooks
%hook CSCoverSheetViewController

- (void)viewDidLoad {
    %orig;
    VCRApplyNCTransparencyToContainerAndBurst(((UIViewController *)self).view);
}

- (void)viewWillAppear:(BOOL)animated {
    VCRInstallNCSnapshotUnderlayIfNeeded(((UIViewController *)self).view);
    %orig;
    VCRApplyNCTransparencyToContainerAndBurst(((UIViewController *)self).view);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    VCRApplyNCTransparencyToContainerAndBurst(((UIViewController *)self).view);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    VCRMarkNCInactive();
}

- (void)viewDidLayoutSubviews {
    %orig;
    VCRApplyNCTransparencyToContainerAndBurst(((UIViewController *)self).view);
}

%end
%end

%group VCRSBDashBoardViewControllerHooks
%hook SBDashBoardViewController

- (void)viewDidLoad {
    %orig;
    VCRApplyNCTransparencyToContainerAndBurst(((UIViewController *)self).view);
}

- (void)viewWillAppear:(BOOL)animated {
    VCRInstallNCSnapshotUnderlayIfNeeded(((UIViewController *)self).view);
    %orig;
    VCRApplyNCTransparencyToContainerAndBurst(((UIViewController *)self).view);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    VCRApplyNCTransparencyToContainerAndBurst(((UIViewController *)self).view);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    VCRMarkNCInactive();
}

- (void)viewDidLayoutSubviews {
    %orig;
    VCRApplyNCTransparencyToContainerAndBurst(((UIViewController *)self).view);
}

%end
%end

%group VCRSBNotificationCenterViewControllerHooks
%hook SBNotificationCenterViewController

- (void)viewDidLoad {
    %orig;
    VCRApplyNCTransparencyToContainerAndBurst(((UIViewController *)self).view);
}

- (void)viewWillAppear:(BOOL)animated {
    VCRInstallNCSnapshotUnderlayIfNeeded(((UIViewController *)self).view);
    %orig;
    VCRApplyNCTransparencyToContainerAndBurst(((UIViewController *)self).view);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    VCRApplyNCTransparencyToContainerAndBurst(((UIViewController *)self).view);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    VCRMarkNCInactive();
}

- (void)viewDidLayoutSubviews {
    %orig;
    VCRApplyNCTransparencyToContainerAndBurst(((UIViewController *)self).view);
}

%end
%end

%group VCRNCNotificationListViewControllerHooks
%hook NCNotificationListViewController

- (void)viewDidLayoutSubviews {
    %orig;
    VCRApplyNCTransparencyToContainerAndBurst(((UIViewController *)self).view);
}

%end
%end


%group VCRCSCoverSheetBackgroundViewHooks
%hook CSCoverSheetBackgroundView
- (void)didMoveToWindow { %orig; VCRApplyNCTransparencyToContainerAndBurst((UIView *)self); }
- (void)layoutSubviews { %orig; VCRApplyNCTransparencyToContainerAndBurst((UIView *)self); }
- (void)setAlpha:(CGFloat)alpha { if (vcrNCTransparencyEnabled && vcrNCHideLockscreenWallpaper) { if (vcrNCLivePassthrough) { %orig(0.0); VCRHideViewForLivePassthrough((UIView *)self); } else { %orig(vcrNCWallpaperAlpha); } } else { %orig; } }
%end
%end

%group VCRSBFWallpaperViewHooks
%hook SBFWallpaperView
- (void)didMoveToWindow { %orig; VCRApplyNCTransparencyToContainerAndBurst((UIView *)self); }
- (void)layoutSubviews { %orig; VCRApplyNCTransparencyToContainerAndBurst((UIView *)self); }
- (void)setAlpha:(CGFloat)alpha { if (vcrNCTransparencyEnabled && vcrNCHideLockscreenWallpaper && VCRViewIsInsideNCContext((UIView *)self)) { if (vcrNCLivePassthrough) { %orig(0.0); VCRHideViewForLivePassthrough((UIView *)self); } else { %orig(vcrNCWallpaperAlpha); } } else { %orig; } }
%end
%end

%group VCRSBWallpaperEffectViewHooks
%hook SBWallpaperEffectView
- (void)didMoveToWindow { %orig; VCRApplyNCTransparencyToContainerAndBurst((UIView *)self); }
- (void)layoutSubviews { %orig; VCRApplyNCTransparencyToContainerAndBurst((UIView *)self); }
- (void)setAlpha:(CGFloat)alpha { if (vcrNCTransparencyEnabled && vcrNCHideLockscreenWallpaper && VCRViewIsInsideNCContext((UIView *)self)) { if (vcrNCLivePassthrough) { %orig(0.0); VCRHideViewForLivePassthrough((UIView *)self); } else { %orig(vcrNCWallpaperAlpha); } } else { %orig; } }
%end
%end

%group VCRCSPosterViewHooks
%hook CSPosterView
- (void)didMoveToWindow { %orig; VCRApplyNCTransparencyToContainerAndBurst((UIView *)self); }
- (void)layoutSubviews { %orig; VCRApplyNCTransparencyToContainerAndBurst((UIView *)self); }
- (void)setAlpha:(CGFloat)alpha { if (vcrNCTransparencyEnabled && vcrNCHideLockscreenWallpaper) { if (vcrNCLivePassthrough) { %orig(0.0); VCRHideViewForLivePassthrough((UIView *)self); } else { %orig(vcrNCWallpaperAlpha); } } else { %orig; } }
%end
%end

%group VCRPRPosterViewHooks
%hook PRPosterView
- (void)didMoveToWindow { %orig; VCRApplyNCTransparencyToContainerAndBurst((UIView *)self); }
- (void)layoutSubviews { %orig; VCRApplyNCTransparencyToContainerAndBurst((UIView *)self); }
- (void)setAlpha:(CGFloat)alpha { if (vcrNCTransparencyEnabled && vcrNCHideLockscreenWallpaper) { if (vcrNCLivePassthrough) { %orig(0.0); VCRHideViewForLivePassthrough((UIView *)self); } else { %orig(vcrNCWallpaperAlpha); } } else { %orig; } }
%end
%end

%group VCRCSCoverSheetViewHooks
%hook CSCoverSheetView

- (void)layoutSubviews {
    %orig;
    VCRApplyNCTransparencyToContainerAndBurst((UIView *)self);
}

%end
%end

%group VCRSBDashBoardViewHooks
%hook SBDashBoardView

- (void)layoutSubviews {
    %orig;
    VCRApplyNCTransparencyToContainerAndBurst((UIView *)self);
}

%end
%end

%group VCRSBCoverSheetWindowHooks
%hook SBCoverSheetWindow

- (void)layoutSubviews {
    %orig;
    VCRApplyNCTransparencyToContainerAndBurst((UIView *)self);
}

%end
%end

%group VCRSBNotificationCenterWindowHooks
%hook SBNotificationCenterWindow

- (void)layoutSubviews {
    %orig;
    VCRApplyNCTransparencyToContainerAndBurst((UIView *)self);
}

%end
%end

%group VCRUIVisualEffectViewHooks
%hook UIVisualEffectView

- (void)didMoveToWindow {
    %orig;
    VCRApplyNCTransparencyToMaterialView((UIView *)self);
    VCRScheduleNCTransparencyBurst();
}

- (void)layoutSubviews {
    %orig;
    VCRApplyNCTransparencyToMaterialView((UIView *)self);
}

- (void)setAlpha:(CGFloat)alpha {
    if (vcrNCTransparencyEnabled && VCRViewIsInsideNCContext((UIView *)self)) {
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
    VCRApplyNCTransparencyToMaterialView((UIView *)self);
    VCRScheduleNCTransparencyBurst();
}

- (void)layoutSubviews {
    %orig;
    VCRApplyNCTransparencyToMaterialView((UIView *)self);
}

- (void)setAlpha:(CGFloat)alpha {
    if (vcrNCTransparencyEnabled && VCRViewIsInsideNCContext((UIView *)self)) {
        %orig(vcrNCBlurAlpha);
        return;
    }
    %orig(alpha);
}

%end
%end


%group VCRUIViewLivePassthroughHooks
%hook UIView

- (void)didMoveToWindow {
    %orig;
    if (vcrNCTransparencyEnabled && vcrNCLivePassthrough && vcrNCActive) {
        VCRApplyLivePassthroughToView((UIView *)self);
    }
}

- (void)layoutSubviews {
    %orig;
    if (vcrNCTransparencyEnabled && vcrNCLivePassthrough && vcrNCActive) {
        VCRApplyLivePassthroughToView((UIView *)self);
    }
}

- (void)setAlpha:(CGFloat)alpha {
    if (vcrNCTransparencyEnabled && vcrNCLivePassthrough && vcrNCActive &&
        VCRViewShouldBeHiddenForLivePassthrough((UIView *)self, NSStringFromClass([self class]))) {
        %orig(0.0);
        return;
    }
    %orig(alpha);
}

- (void)setHidden:(BOOL)hidden {
    if (vcrNCTransparencyEnabled && vcrNCLivePassthrough && vcrNCActive &&
        VCRViewShouldBeHiddenForLivePassthrough((UIView *)self, NSStringFromClass([self class]))) {
        %orig(YES);
        return;
    }
    %orig(hidden);
}

%end
%end

%group VCRUIImageViewLivePassthroughHooks
%hook UIImageView

- (void)setImage:(UIImage *)image {
    if (vcrNCTransparencyEnabled && vcrNCLivePassthrough && vcrNCActive &&
        VCRViewShouldBeHiddenForLivePassthrough((UIView *)self, NSStringFromClass([self class]))) {
        %orig(image);
        VCRHideViewForLivePassthrough((UIView *)self);
        return;
    }
    %orig(image);
}

%end
%end

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        BOOL isSpringBoard = [bundleID isEqualToString:@"com.apple.springboard"];

        VCRLoadPrefs();

        %init(VCRApplicationGestureHooks);

        int prefsToken = 0;
        notify_register_dispatch("com.yourname.volumechordrecorder.prefschanged", &prefsToken, dispatch_get_main_queue(), ^(__unused int t) {
            VCRLoadPrefs();
            if (isSpringBoard) {
                if (!vcrEnabled && isRecording) {
                    VCRLog(@"Disabled from Settings while recording, stopping");
                    VCRStopRecording();
                }
                if (!vcrNCTransparencyEnabled || !vcrNCUseSnapshotUnderlay) VCRRemoveNCSnapshotUnderlay();
                if (!vcrNCTransparencyEnabled || !vcrNCLivePassthrough) VCRRestoreLivePassthroughViews();
                VCRApplyNCTransparencyToAllKnownWindows();
            }
        });

        if (isSpringBoard) {
            %init(VCRSpringBoardHooks);
            if (objc_getClass("CSCoverSheetViewController")) %init(VCRCSCoverSheetViewControllerHooks);
            if (objc_getClass("SBDashBoardViewController")) %init(VCRSBDashBoardViewControllerHooks);
            if (objc_getClass("SBNotificationCenterViewController")) %init(VCRSBNotificationCenterViewControllerHooks);
            if (objc_getClass("NCNotificationListViewController")) %init(VCRNCNotificationListViewControllerHooks);
            if (objc_getClass("CSCoverSheetBackgroundView")) %init(VCRCSCoverSheetBackgroundViewHooks);
            if (objc_getClass("SBFWallpaperView")) %init(VCRSBFWallpaperViewHooks);
            if (objc_getClass("SBWallpaperEffectView")) %init(VCRSBWallpaperEffectViewHooks);
            if (objc_getClass("CSPosterView")) %init(VCRCSPosterViewHooks);
            if (objc_getClass("PRPosterView")) %init(VCRPRPosterViewHooks);
            if (objc_getClass("CSCoverSheetView")) %init(VCRCSCoverSheetViewHooks);
            if (objc_getClass("SBDashBoardView")) %init(VCRSBDashBoardViewHooks);
            if (objc_getClass("SBCoverSheetWindow")) %init(VCRSBCoverSheetWindowHooks);
            if (objc_getClass("SBNotificationCenterWindow")) %init(VCRSBNotificationCenterWindowHooks);
            %init(VCRUIVisualEffectViewHooks);
            if (objc_getClass("MTMaterialView")) %init(VCRMTMaterialViewHooks);
            %init(VCRUIViewLivePassthroughHooks);
            %init(VCRUIImageViewLivePassthroughHooks);

            int toggleToken = 0;
            notify_register_dispatch([VCRToggleRecordingNotification UTF8String], &toggleToken, dispatch_get_main_queue(), ^(__unused int t) {
                VCRLoadPrefs();
                if (vcrEnabled && vcrThreeFingerSwipeDownTrigger) {
                    VCRLog(@"Received three-finger swipe toggle notification");
                    VCRToggleRecording();
                }
            });

            int applyToken = 0;
            notify_register_dispatch("com.yourname.volumechordrecorder.applyNCTransparency", &applyToken, dispatch_get_main_queue(), ^(__unused int t) {
                VCRLoadPrefs();
                if (!vcrNCTransparencyEnabled || !vcrNCUseSnapshotUnderlay) VCRRemoveNCSnapshotUnderlay();
                if (!vcrNCTransparencyEnabled || !vcrNCLivePassthrough) VCRRestoreLivePassthroughViews();
                VCRApplyNCTransparencyToAllKnownWindows();
            });

            VCRLog(@"Loaded into SpringBoard, volumeUpType=%d volumeDownType=%d volumeChord=%d threeSwipe=%d", VCR_PRESS_TYPE_VOLUME_UP, VCR_PRESS_TYPE_VOLUME_DOWN, vcrVolumeChordTrigger, vcrThreeFingerSwipeDownTrigger);
        } else {
            if (vcrLogGestures) VCRLog(@"Loaded gesture detector into %@", bundleID);
        }
    }
}