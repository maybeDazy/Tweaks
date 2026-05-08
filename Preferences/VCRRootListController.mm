#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>
@import Darwin.POSIX.spawn;
@import Darwin.POSIX.sys.wait;

static NSString * const VCRPrefsID = @"com.yourname.volumechordrecorder";

@interface VCRRootListController : PSListController
@end

@implementation VCRRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    id defaultValue = [specifier propertyForKey:@"default"];
    CFPreferencesAppSynchronize((__bridge CFStringRef)VCRPrefsID);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)VCRPrefsID);
    if (!value) return defaultValue;
    return CFBridgingRelease(value);
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

static int VCRSpawnCommand(const char *path, char * const argv[]) {
    pid_t pid = 0;
    int status = 0;
    int rc = posix_spawn(&pid, path, NULL, NULL, argv, NULL);
    if (rc != 0 || pid <= 0) return rc ?: -1;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return status;
}

static BOOL VCRFileExists(const char *path) {
    return [[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithUTF8String:path]];
}

- (void)vcrDoRespring {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int rc = -1;

        // RootHide/rootless setups can expose different sbreload paths.
        const char *sbreloadPaths[] = {
            "/usr/bin/sbreload",
            "/var/jb/usr/bin/sbreload",
            "/private/preboot/jb/usr/bin/sbreload",
            NULL
        };

        for (int i = 0; sbreloadPaths[i] != NULL; i++) {
            if (VCRFileExists(sbreloadPaths[i])) {
                char * const args[] = {(char *)"sbreload", NULL};
                rc = VCRSpawnCommand(sbreloadPaths[i], args);
                if (rc == 0) return;
            }
        }

        // Fallback: restart SpringBoard directly.
        const char *killallPaths[] = {
            "/usr/bin/killall",
            "/var/jb/usr/bin/killall",
            "/bin/killall",
            NULL
        };
        for (int i = 0; killallPaths[i] != NULL; i++) {
            if (VCRFileExists(killallPaths[i])) {
                char * const args[] = {(char *)"killall", (char *)"-9", (char *)"SpringBoard", NULL};
                rc = VCRSpawnCommand(killallPaths[i], args);
                if (rc == 0) return;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *message = [NSString stringWithFormat:@"Respring command failed. Last status: %d\n\nTry running sbreload manually from NewTerm/SSH.", rc];
            UIAlertController *failed = [UIAlertController alertControllerWithTitle:@"Respring Failed"
                                                                            message:message
                                                                     preferredStyle:UIAlertControllerStyleAlert];
            [failed addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:failed animated:YES completion:nil];
        });
    });
}

- (void)respring {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Respring?"
                                                                   message:@"Restart SpringBoard to reload the tweak and Preferences."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Respring" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [self vcrDoRespring];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
