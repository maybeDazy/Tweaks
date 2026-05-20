#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <AudioToolbox/AudioToolbox.h>
#import <notify.h>
@import Darwin.POSIX.spawn;
@import Darwin.POSIX.sys.wait;

static NSString * const VCRPrefsID = @"com.yourname.volumechordrecorder";
static NSString * const VCRRecordingsDir = @"/var/mobile/Media/VolumeChordRecorder";

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

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSArray<NSURL *> *)recordingFileURLs {
    NSURL *dirURL = [NSURL fileURLWithPath:VCRRecordingsDir isDirectory:YES];
    NSArray<NSURL *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:dirURL
                                                            includingPropertiesForKeys:@[NSURLCreationDateKey, NSURLFileSizeKey]
                                                                               options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                 error:nil];
    NSPredicate *m4aOnly = [NSPredicate predicateWithBlock:^BOOL(NSURL *url, __unused NSDictionary *bindings) {
        return [[url.pathExtension lowercaseString] isEqualToString:@"m4a"];
    }];
    NSArray<NSURL *> *filtered = [files filteredArrayUsingPredicate:m4aOnly];
    return [filtered sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *dateA = nil;
        NSDate *dateB = nil;
        [a getResourceValue:&dateA forKey:NSURLCreationDateKey error:nil];
        [b getResourceValue:&dateB forKey:NSURLCreationDateKey error:nil];
        return [dateB compare:dateA];
    }];
}

- (NSString *)humanSizeForBytes:(unsigned long long)bytes {
    double value = (double)bytes;
    NSArray<NSString *> *units = @[@"B", @"KB", @"MB", @"GB"];
    NSUInteger unit = 0;
    while (value >= 1024.0 && unit + 1 < units.count) {
        value /= 1024.0;
        unit++;
    }
    if (unit == 0) return [NSString stringWithFormat:@"%llu %@", bytes, units[unit]];
    return [NSString stringWithFormat:@"%.1f %@", value, units[unit]];
}

- (NSString *)recordingsSummaryWithLimit:(NSUInteger)limit {
    NSArray<NSURL *> *files = [self recordingFileURLs];
    if (files.count == 0) {
        return [NSString stringWithFormat:@"No .m4a recordings found.\n\nPath:\n%@", VCRRecordingsDir];
    }

    NSMutableString *summary = [NSMutableString stringWithFormat:@"Path:\n%@\n\nTotal: %lu file(s)\n\n", VCRRecordingsDir, (unsigned long)files.count];
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"MM-dd HH:mm";

    NSUInteger count = MIN(limit, files.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSURL *url = files[i];
        NSDate *created = nil;
        NSNumber *size = nil;
        [url getResourceValue:&created forKey:NSURLCreationDateKey error:nil];
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        NSString *dateText = created ? [formatter stringFromDate:created] : @"unknown";
        NSString *sizeText = size ? [self humanSizeForBytes:size.unsignedLongLongValue] : @"unknown";
        [summary appendFormat:@"%lu. %@\n   %@ · %@\n", (unsigned long)(i + 1), url.lastPathComponent, dateText, sizeText];
    }
    if (files.count > count) {
        [summary appendFormat:@"\n...and %lu more file(s).", (unsigned long)(files.count - count)];
    }
    return summary;
}

- (void)openRecordingsFolder {
    [self showAlertWithTitle:@"Recording Path" message:[NSString stringWithFormat:@"Saved to:\n%@\n\nUse Filza or SSH/NewTerm to open this folder.", VCRRecordingsDir]];
}

- (void)showRecordingsList {
    NSString *message = [self recordingsSummaryWithLimit:12];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Recordings"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete Latest" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [self deleteLatestRecording];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete All" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [self deleteAllRecordings];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)deleteLatestRecording {
    NSArray<NSURL *> *files = [self recordingFileURLs];
    if (files.count == 0) {
        [self showAlertWithTitle:@"Delete Latest" message:@"No recordings to delete."];
        return;
    }
    NSURL *latest = files.firstObject;
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Delete Latest Recording?"
                                                                     message:latest.lastPathComponent
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        NSError *error = nil;
        BOOL ok = [[NSFileManager defaultManager] removeItemAtURL:latest error:&error];
        [self showAlertWithTitle:ok ? @"Deleted" : @"Delete Failed"
                         message:ok ? latest.lastPathComponent : [error localizedDescription]];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)deleteAllRecordings {
    NSArray<NSURL *> *files = [self recordingFileURLs];
    if (files.count == 0) {
        [self showAlertWithTitle:@"Delete All" message:@"No recordings to delete."];
        return;
    }
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Delete All Recordings?"
                                                                     message:[NSString stringWithFormat:@"This will delete %lu .m4a file(s) from:\n%@", (unsigned long)files.count, VCRRecordingsDir]
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete All" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        NSUInteger deleted = 0;
        NSMutableArray<NSString *> *errors = [NSMutableArray array];
        for (NSURL *url in files) {
            NSError *error = nil;
            if ([[NSFileManager defaultManager] removeItemAtURL:url error:&error]) {
                deleted++;
            } else if (error) {
                [errors addObject:[NSString stringWithFormat:@"%@: %@", url.lastPathComponent, error.localizedDescription]];
            }
        }
        NSString *message = errors.count ? [NSString stringWithFormat:@"Deleted %lu file(s).\n\nErrors:\n%@", (unsigned long)deleted, [errors componentsJoinedByString:@"\n"]] : [NSString stringWithFormat:@"Deleted %lu file(s).", (unsigned long)deleted];
        [self showAlertWithTitle:@"Delete All Complete" message:message];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)testHaptic {
    AudioServicesPlaySystemSound(1519);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AudioServicesPlaySystemSound(1520);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AudioServicesPlaySystemSound(1520);
    });
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

static int VCRSpawnProgram(const char *program, char * const argv[]) {
    pid_t pid = 0;
    int status = 0;
    char * const envp[] = {
        (char *)"PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin:/private/preboot/jb/usr/bin:/private/preboot/jb/bin",
        NULL
    };
    int rc = posix_spawnp(&pid, program, NULL, NULL, argv, envp);
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
        NSMutableString *attempts = [NSMutableString string];

        // Fast path: let PATH resolve sbreload in RootHide/rootless environments.
        char * const sbreloadArgs[] = {(char *)"sbreload", NULL};
        rc = VCRSpawnProgram("sbreload", sbreloadArgs);
        [attempts appendFormat:@"posix_spawnp(sbreload): %d\n", rc];
        if (rc == 0) return;

        // Absolute path attempts for environments where PATH is restricted.
        const char *sbreloadPaths[] = {
            "/usr/bin/sbreload",
            "/var/jb/usr/bin/sbreload",
            "/private/preboot/jb/usr/bin/sbreload",
            "/private/preboot/procursus/usr/bin/sbreload",
            NULL
        };

        for (int i = 0; sbreloadPaths[i] != NULL; i++) {
            if (VCRFileExists(sbreloadPaths[i])) {
                rc = VCRSpawnCommand(sbreloadPaths[i], sbreloadArgs);
                [attempts appendFormat:@"%s: %d\n", sbreloadPaths[i], rc];
                if (rc == 0) return;
            } else {
                [attempts appendFormat:@"%s: missing\n", sbreloadPaths[i]];
            }
        }

        // Notify fallback. Some jailbreak setups listen for this restart notification.
        notify_post("com.apple.springboard.restart");
        notify_post("com.apple.SpringBoard.restart");
        [attempts appendString:@"posted springboard restart notifications\n"];

        // Last fallback: kill SpringBoard by PATH then absolute path.
        char * const killallArgs[] = {(char *)"killall", (char *)"-9", (char *)"SpringBoard", NULL};
        rc = VCRSpawnProgram("killall", killallArgs);
        [attempts appendFormat:@"posix_spawnp(killall): %d\n", rc];
        if (rc == 0) return;

        const char *killallPaths[] = {
            "/usr/bin/killall",
            "/var/jb/usr/bin/killall",
            "/private/preboot/jb/usr/bin/killall",
            "/bin/killall",
            NULL
        };
        for (int i = 0; killallPaths[i] != NULL; i++) {
            if (VCRFileExists(killallPaths[i])) {
                rc = VCRSpawnCommand(killallPaths[i], killallArgs);
                [attempts appendFormat:@"%s: %d\n", killallPaths[i], rc];
                if (rc == 0) return;
            } else {
                [attempts appendFormat:@"%s: missing\n", killallPaths[i]];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *message = [NSString stringWithFormat:@"Respring command failed. Last status: %d\n\nAttempts:\n%@\nTry running sbreload manually from NewTerm/SSH.", rc, attempts];
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


- (void)applyNCTransparencyNow {
    CFPreferencesAppSynchronize((__bridge CFStringRef)VCRPrefsID);
    notify_post("com.yourname.volumechordrecorder.applyNCTransparency");
    notify_post("com.yourname.volumechordrecorder.prefschanged");
    [self showAlertWithTitle:@"Applied" message:@"Notification Center transparency preferences were sent to SpringBoard. If the current shade does not update immediately, close and reopen Notification Center or respring."];
}

@end
