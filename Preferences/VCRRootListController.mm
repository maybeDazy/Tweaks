#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>

static NSString * const VCRPrefsID = @"com.yourname.volumechordrecorder";

@interface VCRRootListController : PSListController
@end

@implementation VCRRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [[self loadSpecifiersFromPlistName:@"Root" target:self] retain];
    }
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    id defaultValue = [specifier propertyForKey:@"default"];
    CFPreferencesAppSynchronize((__bridge CFStringRef)VCRPrefsID);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)VCRPrefsID);
    if (!value) return defaultValue;
    return [(id)CFBridgingRelease(value) autorelease];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)VCRPrefsID);
    CFPreferencesAppSynchronize((__bridge CFStringRef)VCRPrefsID);
    notify_post("com.yourname.volumechordrecorder.prefschanged");
}

- (void)openRecordingsFolder {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Recording Path"
                                                                   message:@"Saved to:\n/var/mobile/Media/VolumeChordRecorder/\n\nCheck over SSH, Filza, or your preferred file manager."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)respring {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Respring?"
                                                                   message:@"Restart SpringBoard to reload the tweak if injection/settings look stuck."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Respring" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        pid_t pid;
        const char *args[] = {"sbreload", NULL};
        posix_spawn(&pid, "/usr/bin/sbreload", NULL, NULL, (char * const *)args, NULL);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
