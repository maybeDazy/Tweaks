#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// VolumeChordRecorder
// Personal-use tweak: hold volume up + volume down together for 2 seconds to toggle recording.
// It intentionally gives vibration feedback and NSLog output. It does not attempt to hide recording.

static BOOL vcrUpPressed = NO;
static BOOL vcrDownPressed = NO;
static BOOL vcrIsRecording = NO;
static NSTimer *vcrHoldTimer = nil;
static AVAudioRecorder *vcrRecorder = nil;
static NSDateFormatter *vcrDateFormatter = nil;

static NSString * const VCRLogPrefix = @"[VolumeChordRecorder]";

static void VCRLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"%@ %@", VCRLogPrefix, msg);
}

static void VCRVibrate(void) {
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
}

static NSString *VCRRecordingDirectory(void) {
    return @"/var/mobile/Media/VolumeChordRecorder";
}

static NSString *VCRTimestamp(void) {
    if (!vcrDateFormatter) {
        vcrDateFormatter = [NSDateFormatter new];
        [vcrDateFormatter setDateFormat:@"yyyyMMdd_HHmmss"];
        [vcrDateFormatter setLocale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
    }
    return [vcrDateFormatter stringFromDate:[NSDate date]];
}

static NSString *VCRNewRecordingPath(void) {
    NSString *dir = VCRRecordingDirectory();
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions: @0755}
                                                    error:&dirError];
    if (dirError) {
        VCRLog(@"Failed creating recording dir %@ error=%@", dir, dirError);
    }
    return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"VCR_%@.m4a", VCRTimestamp()]];
}

static BOOL VCRStartRecording(void) {
    if (vcrIsRecording) {
        VCRLog(@"Already recording");
        return YES;
    }

    NSError *sessionError = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryRecord error:&sessionError];
    if (sessionError) {
        VCRLog(@"AVAudioSession setCategory failed: %@", sessionError);
        return NO;
    }

    sessionError = nil;
    [session setActive:YES error:&sessionError];
    if (sessionError) {
        VCRLog(@"AVAudioSession setActive failed: %@", sessionError);
        return NO;
    }

    NSString *path = VCRNewRecordingPath();
    NSURL *url = [NSURL fileURLWithPath:path];
    NSDictionary *settings = @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @44100,
        AVNumberOfChannelsKey: @1,
        AVEncoderAudioQualityKey: @(AVAudioQualityHigh)
    };

    NSError *recorderError = nil;
    vcrRecorder = [[AVAudioRecorder alloc] initWithURL:url settings:settings error:&recorderError];
    if (recorderError || !vcrRecorder) {
        VCRLog(@"AVAudioRecorder init failed: %@", recorderError);
        return NO;
    }

    [vcrRecorder prepareToRecord];
    BOOL ok = [vcrRecorder record];
    if (!ok) {
        VCRLog(@"AVAudioRecorder record returned NO");
        vcrRecorder = nil;
        return NO;
    }

    vcrIsRecording = YES;
    VCRVibrate();
    VCRLog(@"Recording started: %@", path);
    return YES;
}

static void VCRStopRecording(void) {
    if (!vcrIsRecording) {
        VCRLog(@"Not recording");
        return;
    }

    [vcrRecorder stop];
    vcrRecorder = nil;
    vcrIsRecording = NO;

    NSError *sessionError = nil;
    [[AVAudioSession sharedInstance] setActive:NO error:&sessionError];
    if (sessionError) {
        VCRLog(@"AVAudioSession deactivate warning: %@", sessionError);
    }

    VCRVibrate();
    VCRLog(@"Recording stopped. Files are in %@", VCRRecordingDirectory());
}

static void VCRToggleRecording(void) {
    if (vcrIsRecording) {
        VCRStopRecording();
    } else {
        VCRStartRecording();
    }
}

static void VCRCancelHoldTimer(void) {
    if (vcrHoldTimer) {
        [vcrHoldTimer invalidate];
        vcrHoldTimer = nil;
        VCRLog(@"Hold timer cancelled");
    }
}

static void VCRCheckChord(void) {
    if (vcrUpPressed && vcrDownPressed) {
        if (!vcrHoldTimer) {
            VCRLog(@"Volume chord detected. Hold for 2 seconds to toggle recording.");
            vcrHoldTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:NO block:^(NSTimer *timer) {
                vcrHoldTimer = nil;
                if (vcrUpPressed && vcrDownPressed) {
                    VCRLog(@"Volume chord held for 2 seconds. Toggling recording.");
                    VCRToggleRecording();
                } else {
                    VCRLog(@"Chord released before 2 seconds");
                }
            }];
        }
    } else {
        VCRCancelHoldTimer();
    }
}

static NSString *VCRDescribeUIPress(UIPress *press) {
    if (!press) return @"<nil>";
    return [NSString stringWithFormat:@"type=%ld phase=%ld force=%.2f", (long)press.type, (long)press.phase, press.force];
}

// IMPORTANT:
// UIPressType values for volume buttons vary by iOS/device. The defaults below are common candidates.
// If detection does not work, run log stream and inspect messages like:
//   [VolumeChordRecorder] pressesBegan candidate type=...
// Then adjust these functions.
static BOOL VCRPressLooksLikeVolumeUp(UIPress *press) {
    if (!press) return NO;
    NSInteger t = (NSInteger)press.type;
    return (t == 102 || t == 100); // candidate values; edit after checking logs if needed
}

static BOOL VCRPressLooksLikeVolumeDown(UIPress *press) {
    if (!press) return NO;
    NSInteger t = (NSInteger)press.type;
    return (t == 103 || t == 101); // candidate values; edit after checking logs if needed
}

static void VCRHandlePresses(NSSet<UIPress *> *presses, BOOL began) {
    for (UIPress *press in presses) {
        VCRLog(@"%@ candidate %@", began ? @"pressesBegan" : @"pressesEnded", VCRDescribeUIPress(press));
        if (VCRPressLooksLikeVolumeUp(press)) {
            vcrUpPressed = began;
            VCRLog(@"Volume UP %@", began ? @"DOWN" : @"UP");
        }
        if (VCRPressLooksLikeVolumeDown(press)) {
            vcrDownPressed = began;
            VCRLog(@"Volume DOWN %@", began ? @"DOWN" : @"UP");
        }
    }
    VCRCheckChord();
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    VCRLog(@"Loaded into com.apple.springboard. Recording dir=%@", VCRRecordingDirectory());
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    VCRHandlePresses(presses, YES);
    %orig;
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    VCRHandlePresses(presses, NO);
    %orig;
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    VCRHandlePresses(presses, NO);
    %orig;
}

%end

%ctor {
    VCRLog(@"ctor loaded in bundle=%@ process=%@", [[NSBundle mainBundle] bundleIdentifier], [[NSProcessInfo processInfo] processName]);
}
