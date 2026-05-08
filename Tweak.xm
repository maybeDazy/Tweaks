#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <notify.h>

// ── 프라이빗 클래스 선언 (컴파일러에게 상속 관계 알림) ──
@interface SBPrivacyBlobViewController : UIViewController
- (void)_updateBlobViews;
@end

@interface MTPrivacyIndicatorViewController : UIViewController
- (void)_setIndicatorVisible:(BOOL)visible animated:(BOOL)animated;
@end
#import <notify.h>

static NSString * const VCRPrefsID = @"com.yourname.volumechordrecorder";
static NSString * const VCRPrefix = @"[VolumeChordRecorder]";

static BOOL vcrEnabled = YES;
static BOOL vcrHaptics = YES;
static BOOL vcrLogPresses = YES;
static NSTimeInterval vcrHoldSeconds = 2.0;
static NSTimeInterval vcrMaxRecordSeconds = 600.0;

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

static BOOL VCRPressTypeIsVolumeUp(NSInteger type)   { return type == VCR_PRESS_TYPE_VOLUME_UP;   }
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
    CFRelease(value);
    if (result < minValue) result = minValue;
    if (result > maxValue) result = maxValue;
    return result;
}

static void VCRLoadPrefs(void) {
    vcrEnabled        = VCRBoolPref(@"enabled",          YES);
    vcrHaptics        = VCRBoolPref(@"haptics",          YES);
    vcrLogPresses     = VCRBoolPref(@"logPresses",       YES);
    vcrHoldSeconds    = VCRDoublePref(@"holdSeconds",    2.0, 0.5,  10.0);
    vcrMaxRecordSeconds = VCRDoublePref(@"maxRecordSeconds", 600.0, 5.0, 7200.0);
    VCRLog(@"Prefs loaded enabled=%d hold=%.2fs max=%.0fs haptics=%d logPresses=%d",
           vcrEnabled, vcrHoldSeconds, vcrMaxRecordSeconds, vcrHaptics, vcrLogPresses);
}

static void VCRPlayHaptic(SystemSoundID soundID) {
    if (!vcrHaptics) return;
    AudioServicesPlaySystemSound(soundID);
}
static void VCRHapticStart(void) { VCRPlayHaptic(1519); }
static void VCRHapticStop(void) {
    VCRPlayHaptic(1520);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.16 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        VCRPlayHaptic(1520);
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
    if (error) { VCRLog(@"Failed to create recording dir: %@", error); return; }

    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryRecord error:&error];
    if (error) VCRLog(@"AVAudioSession category error: %@", error);
    error = nil;
    [session setActive:YES error:&error];
    if (error) VCRLog(@"AVAudioSession active error: %@", error);

    NSString *path = [dir stringByAppendingPathComponent:VCRTimestampFilename()];
    NSDictionary *settings = @{
        AVFormatIDKey:              @(kAudioFormatMPEG4AAC),
        AVSampleRateKey:            @44100,
        AVNumberOfChannelsKey:      @1,
        AVEncoderAudioQualityKey:   @(AVAudioQualityHigh)
    };

    recorder = [[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:path] settings:settings error:&error];
    if (error || !recorder) { VCRLog(@"Recorder init failed: %@", error); recorder = nil; return; }

    [recorder prepareToRecord];
    if ([recorder record]) {
        isRecording = YES;
        VCRHapticStart();
        VCRLog(@"Recording started: %@", path);
        if (maxRecordTimer) [maxRecordTimer invalidate];
        maxRecordTimer = [NSTimer scheduledTimerWithTimeInterval:vcrMaxRecordSeconds repeats:NO block:^(__unused NSTimer *t) {
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

static void VCRCancelHoldTimer(void) {
    if (holdTimer) { [holdTimer invalidate]; holdTimer = nil; }
}

static void VCRCheckChord(void) {
    if (!vcrEnabled) { VCRCancelHoldTimer(); return; }
    if (volumeUpPressed && volumeDownPressed && !holdTimer) {
        VCRLog(@"Volume chord detected, hold %.2fs...", vcrHoldSeconds);
        holdTimer = [NSTimer scheduledTimerWithTimeInterval:vcrHoldSeconds repeats:NO block:^(__unused NSTimer *t) {
            holdTimer = nil;
            if (volumeUpPressed && volumeDownPressed && vcrEnabled) {
                VCRLog(@"Volume chord confirmed");
                VCRToggleRecording();
            }
        }];
    }
    if (!volumeUpPressed || !volumeDownPressed) VCRCancelHoldTimer();
}

// ═══════════════════════════════════════════════════
// MARK: - SpringBoard 훅 (볼륨 버튼 감지)
// ═══════════════════════════════════════════════════

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

%end  // ← ✅ SpringBoard 훅 종료 (원본에서 누락됨)

// ═══════════════════════════════════════════════════
// MARK: - 프라이버시 도트 숨기기 (iOS 14~17)
// ═══════════════════════════════════════════════════

// 상태바 우상단 blob 뷰 (UIKit)
%hook _UIStatusBarIndicatorBlobView
- (void)setAlpha:(CGFloat)alpha { %orig(0.0); }
- (void)setHidden:(BOOL)hidden  { %orig(YES);  }
%end

// 인디케이터 아이템 뷰 (iOS 16+)
%hook _UIStatusBarPrivacyIndicatorItemView
- (void)setAlpha:(CGFloat)alpha { %orig(0.0); }
- (void)setHidden:(BOOL)hidden  { %orig(YES);  }
%end

// Control Center 상단 점 (SpringBoard)
%hook SBPrivacyBlobViewController
- (void)viewDidLoad {
    %orig;
    self.view.hidden = YES;
    self.view.alpha  = 0.0;
}
- (void)_updateBlobViews { /* 업데이트 차단 */ }
%end

// MediaToolbox 마이크 인디케이터 (iOS 15+)
%hook MTMicrophoneUsageView
- (void)setAlpha:(CGFloat)alpha { %orig(0.0); }
- (void)setHidden:(BOOL)hidden  { %orig(YES);  }
%end

%hook MTPrivacyIndicatorViewController
- (void)viewDidLoad {
    %orig;
    self.view.hidden = YES;
}
- (void)_setIndicatorVisible:(BOOL)visible animated:(BOOL)animated {
    %orig(NO, animated);
}
%end

// ═══════════════════════════════════════════════════
// MARK: - 초기화
// ═══════════════════════════════════════════════════

%ctor {
    VCRLoadPrefs();
    int token = 0;
    notify_register_dispatch("com.yourname.volumechordrecorder.prefschanged", &token, dispatch_get_main_queue(), ^(__unused int t) {
        VCRLoadPrefs();
        if (!vcrEnabled && isRecording) {
            VCRLog(@"Disabled from Settings while recording, stopping");
            VCRStopRecording();
        }
    });
    VCRLog(@"Loaded into %@, volumeUpType=%d volumeDownType=%d",
           [[NSBundle mainBundle] bundleIdentifier],
           VCR_PRESS_TYPE_VOLUME_UP, VCR_PRESS_TYPE_VOLUME_DOWN);
}