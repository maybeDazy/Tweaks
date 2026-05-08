#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <notify.h>

// ── 프라이빗 클래스 선언 ──────────────────────────────────────
// UIView 계열: hidden/alpha 접근을 위해 상속 명시
@interface _UIStatusBarIndicatorBlobView : UIView
@end

@interface _UIStatusBarPrivacyIndicatorItemView : UIView
@end

@interface _UIPrivacyIndicatorBlobView : UIView
@end

@interface MTMicrophoneUsageView : UIView
@end

// UIViewController 계열: self.view 접근을 위해 상속 명시
@interface SBPrivacyBlobViewController : UIViewController
- (void)_updateBlobViews;
- (void)_setVisible:(BOOL)visible animated:(BOOL)animated;
@end

@interface MTPrivacyIndicatorViewController : UIViewController
- (void)_setIndicatorVisible:(BOOL)visible animated:(BOOL)animated;
@end

// ── 상수 / 전역 변수 ──────────────────────────────────────────

static NSString * const VCRPrefsID = @"com.yourname.volumechordrecorder";
static NSString * const VCRPrefix  = @"[VolumeChordRecorder]";

static BOOL            vcrEnabled            = YES;
static BOOL            vcrHaptics            = YES;
static BOOL            vcrLogPresses         = YES;
static BOOL            vcrHidePrivacyDot     = NO;
static NSTimeInterval  vcrHoldSeconds        = 2.0;
static NSTimeInterval  vcrMaxRecordSeconds   = 600.0;

static BOOL            volumeUpPressed       = NO;
static BOOL            volumeDownPressed     = NO;
static NSTimer        *holdTimer             = nil;
static NSTimer        *maxRecordTimer        = nil;
static AVAudioRecorder*recorder              = nil;
static BOOL            isRecording           = NO;

#ifndef VCR_PRESS_TYPE_VOLUME_UP
#define VCR_PRESS_TYPE_VOLUME_UP   102
#endif
#ifndef VCR_PRESS_TYPE_VOLUME_DOWN
#define VCR_PRESS_TYPE_VOLUME_DOWN 103
#endif

static BOOL VCRPressTypeIsVolumeUp(NSInteger t)   { return t == VCR_PRESS_TYPE_VOLUME_UP;   }
static BOOL VCRPressTypeIsVolumeDown(NSInteger t) { return t == VCR_PRESS_TYPE_VOLUME_DOWN; }

// ── 유틸 ──────────────────────────────────────────────────────

static void VCRLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"%@ %@", VCRPrefix, msg);
}

static BOOL VCRBoolPref(NSString *key, BOOL fallback) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)VCRPrefsID);
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)VCRPrefsID);
    if (!v) return fallback;
    BOOL result = fallback;
    if (CFGetTypeID(v) == CFBooleanGetTypeID())
        result = CFBooleanGetValue((CFBooleanRef)v);
    else if (CFGetTypeID(v) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)v, kCFNumberCharType, &result);
    CFRelease(v);
    return result;
}

static double VCRDoublePref(NSString *key, double fallback, double lo, double hi) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)VCRPrefsID);
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)VCRPrefsID);
    if (!v) return fallback;
    double result = fallback;
    if (CFGetTypeID(v) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &result);
    CFRelease(v);
    if (result < lo) result = lo;
    if (result > hi) result = hi;
    return result;
}

static void VCRLoadPrefs(void) {
    vcrEnabled          = VCRBoolPref(@"enabled",            YES);
    vcrHaptics          = VCRBoolPref(@"haptics",            YES);
    vcrLogPresses       = VCRBoolPref(@"logPresses",         YES);
    vcrHidePrivacyDot   = VCRBoolPref(@"hidePrivacyDot",     NO);
    vcrHoldSeconds      = VCRDoublePref(@"holdSeconds",      2.0,   0.5,    10.0);
    vcrMaxRecordSeconds = VCRDoublePref(@"maxRecordSeconds", 600.0, 5.0, 7200.0);
    VCRLog(@"Prefs loaded enabled=%d hold=%.2fs max=%.0fs haptics=%d logPresses=%d hidePrivacyDot=%d",
           vcrEnabled, vcrHoldSeconds, vcrMaxRecordSeconds,
           vcrHaptics, vcrLogPresses, vcrHidePrivacyDot);
}

// ── 햅틱 ──────────────────────────────────────────────────────

static void VCRPlayHaptic(SystemSoundID s) {
    if (!vcrHaptics) return;
    AudioServicesPlaySystemSound(s);
}

static void VCRHapticStart(void) {
    VCRPlayHaptic(1519);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ VCRPlayHaptic(1520); });
}

static void VCRHapticStop(void) {
    VCRPlayHaptic(1520);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.13 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ VCRPlayHaptic(1520); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.28 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ VCRPlayHaptic(1519); });
}

// ── 녹음 ──────────────────────────────────────────────────────

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
    VCRHapticStart();
    NSError *error = nil;
    NSString *dir = VCRRecordingDirectory();
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                withIntermediateDirectories:YES attributes:nil error:&error];
    if (error) { VCRLog(@"Failed to create recording dir: %@", error); return; }

    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryRecord error:&error];
    if (error) VCRLog(@"AVAudioSession category error: %@", error);
    error = nil;
    [session setActive:YES error:&error];
    if (error) VCRLog(@"AVAudioSession active error: %@", error);

    NSString *path = [dir stringByAppendingPathComponent:VCRTimestampFilename()];
    NSDictionary *settings = @{
        AVFormatIDKey:            @(kAudioFormatMPEG4AAC),
        AVSampleRateKey:          @44100,
        AVNumberOfChannelsKey:    @1,
        AVEncoderAudioQualityKey: @(AVAudioQualityHigh)
    };

    recorder = [[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:path]
                                           settings:settings error:&error];
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
        maxRecordTimer = [NSTimer scheduledTimerWithTimeInterval:vcrMaxRecordSeconds
                                                         repeats:NO
                                                           block:^(__unused NSTimer *t) {
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
    if (maxRecordTimer) { [maxRecordTimer invalidate]; maxRecordTimer = nil; }
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

// ── 볼륨 코드 감지 ────────────────────────────────────────────

static void VCRCancelHoldTimer(void) {
    if (holdTimer) { [holdTimer invalidate]; holdTimer = nil; }
}

static void VCRCheckChord(void) {
    if (!vcrEnabled) { VCRCancelHoldTimer(); return; }

    if (volumeUpPressed && volumeDownPressed && !holdTimer) {
        VCRLog(@"Volume chord detected, hold %.2fs...", vcrHoldSeconds);
        holdTimer = [NSTimer scheduledTimerWithTimeInterval:vcrHoldSeconds
                                                    repeats:NO
                                                      block:^(__unused NSTimer *t) {
            holdTimer = nil;
            if (volumeUpPressed && volumeDownPressed && vcrEnabled) {
                VCRLog(@"Volume chord confirmed");
                VCRToggleRecording();
            }
        }];
    }

    if (!volumeUpPressed || !volumeDownPressed) VCRCancelHoldTimer();
}

// ═════════════════════════════════════════════════════════════
// MARK: - SpringBoard 훅 (볼륨 버튼 감지)
// ═════════════════════════════════════════════════════════════

%hook SpringBoard

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *press in presses) {
        NSInteger type = press.type;
        if (vcrLogPresses) VCRLog(@"press began type=%ld", (long)type);
        if (VCRPressTypeIsVolumeUp(type))   volumeUpPressed   = YES;
        if (VCRPressTypeIsVolumeDown(type)) volumeDownPressed = YES;
    }
    VCRCheckChord();
    %orig;
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *press in presses) {
        NSInteger type = press.type;
        if (vcrLogPresses) VCRLog(@"press ended type=%ld", (long)type);
        if (VCRPressTypeIsVolumeUp(type))   volumeUpPressed   = NO;
        if (VCRPressTypeIsVolumeDown(type)) volumeDownPressed = NO;
    }
    VCRCheckChord();
    %orig;
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    volumeUpPressed   = NO;
    volumeDownPressed = NO;
    VCRCancelHoldTimer();
    %orig;
}

%end   // SpringBoard

// ═════════════════════════════════════════════════════════════
// MARK: - 프라이버시 도트 숨기기 (iOS 14~17)
//
//  hidePrivacyDot = NO(기본값)  → 아무것도 변경하지 않음
//  hidePrivacyDot = YES         → 마이크·카메라 표시등 모두 숨김
//
//  변경 후 반드시 Respring 필요.
// ═════════════════════════════════════════════════════════════

// ── 기존 도트 훅 전체를 아래로 교체 ──

// UIView 레벨에서 class name 검사 — iOS 버전별 클래스명 차이 흡수
// 성능: containsString 검사만 하므로 오버헤드 미미
%hook UIView

- (void)didMoveToWindow {
    %orig;
    if (!vcrHidePrivacyDot) return;
    NSString *cn = NSStringFromClass(self.class);
    if ([cn containsString:@"PrivacyBlob"]    ||
        [cn containsString:@"PrivacyIndicator"] ||
        [cn containsString:@"BlobView"]       ||
        [cn containsString:@"MicrophoneUsage"] ||
        [cn containsString:@"IndicatorBlobView"]) {
        self.hidden = YES;
        self.layer.opacity = 0.0;
    }
}

- (void)setHidden:(BOOL)hidden {
    if (vcrHidePrivacyDot) {
        NSString *cn = NSStringFromClass(self.class);
        if ([cn containsString:@"PrivacyBlob"]    ||
            [cn containsString:@"PrivacyIndicator"] ||
            [cn containsString:@"BlobView"]       ||
            [cn containsString:@"MicrophoneUsage"] ||
            [cn containsString:@"IndicatorBlobView"]) {
            %orig(YES);
            return;
        }
    }
    %orig;
}

%end

// SpringBoard: "마이크 사용 중" 배너 — 알림 수신 자체를 차단
%hook SBPrivacyBlobViewController
- (void)viewDidLoad {
    %orig;
    if (!vcrHidePrivacyDot) return;
    self.view.hidden = YES;
    self.view.layer.opacity = 0.0;
}
- (void)_updateBlobViews { if (!vcrHidePrivacyDot) %orig; }
- (void)_setVisible:(BOOL)v animated:(BOOL)a { %orig(vcrHidePrivacyDot ? NO : v, a); }
- (void)viewWillAppear:(BOOL)animated {        // 재등장 차단
    if (vcrHidePrivacyDot) return;
    %orig;
}
%end

%hook MTPrivacyIndicatorViewController
- (void)viewDidLoad {
    %orig;
    if (vcrHidePrivacyDot) self.view.hidden = YES;
}
- (void)_setIndicatorVisible:(BOOL)v animated:(BOOL)a { %orig(vcrHidePrivacyDot ? NO : v, a); }
- (void)viewWillAppear:(BOOL)animated {
    if (vcrHidePrivacyDot) return;
    %orig;
}
%end

// ═════════════════════════════════════════════════════════════
// MARK: - 초기화
// ═════════════════════════════════════════════════════════════

%ctor {
    VCRLoadPrefs();
    int token = 0;
    notify_register_dispatch("com.yourname.volumechordrecorder.prefschanged",
                             &token, dispatch_get_main_queue(), ^(__unused int t) {
        VCRLoadPrefs();
        if (!vcrEnabled && isRecording) {
            VCRLog(@"Disabled from Settings while recording, stopping");
            VCRStopRecording();
        }
    });
    VCRLog(@"Loaded into %@, volumeUpType=%d volumeDownType=%d hidePrivacyDot=%d",
           [[NSBundle mainBundle] bundleIdentifier],
           VCR_PRESS_TYPE_VOLUME_UP, VCR_PRESS_TYPE_VOLUME_DOWN, vcrHidePrivacyDot);
}
