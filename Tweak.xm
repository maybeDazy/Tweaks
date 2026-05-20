#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <notify.h>
#import <objc/runtime.h>

static NSString * const VCRPrefsID = @"com.yourname.volumechordrecorder";
static NSString * const VCRPrefix = @"[VolumeChordRecorder]";

static BOOL vcrEnabled = YES;
static BOOL vcrHaptics = YES;
static BOOL vcrLogPresses = YES;
static NSTimeInterval vcrHoldSeconds = 2.0;
static NSTimeInterval vcrMaxRecordSeconds = 600.0;

// Notification Center / CoverSheet transparency customization.
// This only changes the Notification Center/CoverSheet background, wallpaper, blur,
// and dim layers. It intentionally does not hide or alter microphone/camera privacy dots.
static BOOL vcrNCTransparencyEnabled = NO;
static CGFloat vcrNCWallpaperAlpha = 0.00;
static CGFloat vcrNCBlurAlpha = 0.08;
static CGFloat vcrNCDimAlpha = 0.00;
static BOOL vcrNCLogViews = NO;
static NSTimeInterval vcrLastNCTransparencyBurst = 0.0;

static BOOL volumeUpPressed = NO;
static BOOL volumeDownPressed = NO;
static NSTimer *holdTimer = nil;
static NSTimer *maxRecordTimer = nil;
static AVAudioRecorder *recorder = nil;
static BOOL isRecording = NO;

// iPhoneOS SDK 16.x public UIKit headers do not expose UIPressTypeVolumeUp/Down.
// Keep these numeric fallbacks so the tweak compiles. If your device logs different
// type values, change them here and rebuild.
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
    vcrLogPresses = VCRBoolPref(@"logPresses", YES);
    vcrHoldSeconds = VCRDoublePref(@"holdSeconds", 2.0, 0.5, 10.0);
    vcrMaxRecordSeconds = VCRDoublePref(@"maxRecordSeconds", 600.0, 5.0, 7200.0);

    vcrNCTransparencyEnabled = VCRBoolPref(@"ncTransparencyEnabled", NO);
    vcrNCWallpaperAlpha = (CGFloat)VCRDoublePref(@"ncWallpaperAlpha", 0.00, 0.0, 1.0);
    vcrNCBlurAlpha = (CGFloat)VCRDoublePref(@"ncBlurAlpha", 0.08, 0.0, 1.0);
    vcrNCDimAlpha = (CGFloat)VCRDoublePref(@"ncDimAlpha", 0.00, 0.0, 1.0);
    vcrNCLogViews = VCRBoolPref(@"ncLogViews", NO);

    VCRLog(@"Prefs loaded enabled=%d hold=%.2fs max=%.0fs haptics=%d logPresses=%d ncEnabled=%d wallpaper=%.2f blur=%.2f dim=%.2f",
           vcrEnabled, vcrHoldSeconds, vcrMaxRecordSeconds, vcrHaptics, vcrLogPresses,
           vcrNCTransparencyEnabled, vcrNCWallpaperAlpha, vcrNCBlurAlpha, vcrNCDimAlpha);
}

static void VCRPlayHaptic(SystemSoundID soundID) {
    if (!vcrHaptics) return;
    AudioServicesPlaySystemSound(soundID);
}

static void VCRHapticStart(void) {
    // Recording started: stronger double pattern.
    // 1519/1520 are short system haptics on most iPhones.
    VCRPlayHaptic(1519);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        VCRPlayHaptic(1520);
    });
}

static void VCRHapticStop(void) {
    // Recording stopped: stronger triple pattern so it is clearly different from start.
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
    if (!vcrEnabled) {
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

static BOOL VCRShouldSkipNCSubview(UIView *view, NSString *className) {
    // Do not touch controls/text/content/status/privacy indicators.
    if (VCRNameContainsAny(className, @[
        @"Privacy", @"Indicator", @"StatusBar", @"Battery", @"Signal", @"TimeItem",
        @"Label", @"Text", @"Button", @"Slider", @"Control", @"Icon", @"Image",
        @"MediaControls", @"NowPlaying", @"PlatterCell", @"NotificationCell"
    ])) {
        return YES;
    }
    if ([view isKindOfClass:[UILabel class]] || [view isKindOfClass:[UIButton class]] || [view isKindOfClass:[UIImageView class]]) {
        return YES;
    }
    return NO;
}

static void VCRApplyNCTransparencyRecursive(UIView *view, NSUInteger depth) {
    if (!view || depth > 10) return;

    NSString *className = NSStringFromClass([view class]);
    if (VCRShouldSkipNCSubview(view, className)) return;

    BOOL isWallpaper = VCRNameContainsAny(className, @[
        @"Wallpaper", @"CSCoverSheetBackground", @"DashBoardBackground", @"CoverSheetBackground"
    ]);
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
        view.alpha = vcrNCWallpaperAlpha;
        VCRSetBackgroundAlpha(view, vcrNCWallpaperAlpha);
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
            @"CollectionViewCell", @"TableCell", @"Button", @"Slider", @"Label", @"Text"
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

static void VCRApplyNCTransparencyToContainer(UIView *root) {
    if (!vcrNCTransparencyEnabled || !root) return;
    root.opaque = NO;
    VCRSetBackgroundAlpha(root, 0.0);
    VCRApplyNCTransparencyRecursive(root, 0);
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
                // On some Dopamine/RootHide + iOS combinations the fully opened
                // Notification Center lives inside a generic SpringBoard window.
                // Scan for the CoverSheet/NotificationCenter subtree instead of
                // trusting the window class only.
                VCRFindAndApplyNCTransparencyInView(window, 0);
            }
        }
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
    // The interactive pull-down and the fully-presented CoverSheet use different
    // update passes. Re-apply shortly after completion so SpringBoard's final
    // material/background reset does not restore opacity.
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

// NOTE: This intentionally does NOT try to suppress Apple's microphone privacy indicator.
// iOS shows that indicator to tell the user the microphone is active.

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
    %orig;
    VCRApplyNCTransparencyToContainerAndBurst(((UIViewController *)self).view);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    VCRApplyNCTransparencyToContainerAndBurst(((UIViewController *)self).view);
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
    %orig;
    VCRApplyNCTransparencyToContainerAndBurst(((UIViewController *)self).view);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    VCRApplyNCTransparencyToContainerAndBurst(((UIViewController *)self).view);
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
    %orig;
    VCRApplyNCTransparencyToContainerAndBurst(((UIViewController *)self).view);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    VCRApplyNCTransparencyToContainerAndBurst(((UIViewController *)self).view);
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

%ctor {
    VCRLoadPrefs();
    %init(VCRSpringBoardHooks);
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
    int token = 0;
    notify_register_dispatch("com.yourname.volumechordrecorder.prefschanged", &token, dispatch_get_main_queue(), ^(__unused int t) {
        VCRLoadPrefs();
        if (!vcrEnabled && isRecording) {
            VCRLog(@"Disabled from Settings while recording, stopping");
            VCRStopRecording();
        }
        VCRApplyNCTransparencyToAllKnownWindows();
    });
    int applyToken = 0;
    notify_register_dispatch("com.yourname.volumechordrecorder.applyNCTransparency", &applyToken, dispatch_get_main_queue(), ^(__unused int t) {
        VCRLoadPrefs();
        VCRApplyNCTransparencyToAllKnownWindows();
    });
    VCRLog(@"Loaded into %@, volumeUpType=%d volumeDownType=%d", [[NSBundle mainBundle] bundleIdentifier], VCR_PRESS_TYPE_VOLUME_UP, VCR_PRESS_TYPE_VOLUME_DOWN);
}
