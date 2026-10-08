#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <AudioToolbox/AudioToolbox.h>
#import <notify.h>
@import Darwin.POSIX.spawn;
@import Darwin.POSIX.sys.wait;

static NSString * const VCRPrefsID = @"com.yourname.volumechordrecorder";
static NSString * const VCRRecordingsDir = @"/var/mobile/Media/VolumeChordRecorder";

enum { VCRSliderLabelTag = 9001, VCRSliderControlTag = 9002, VCRSliderValueTag = 9003 };

// This bundle is loaded inside the Settings app, so the standard user defaults of the host process
// are the Settings app's own domain - never ours (our bundle id is com.volumechordrecorder.prefs).
// Always address the tweak's domain explicitly through CFPreferences.
static id VCRPrefsValue(NSString *key) {
    if (![key isKindOfClass:[NSString class]]) return nil;
    CFPreferencesAppSynchronize((__bridge CFStringRef)VCRPrefsID);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)VCRPrefsID);
    if (!value) return nil;
    return CFBridgingRelease(value);
}

static void VCRPrefsSet(NSString *key, id value) {
    if (![key isKindOfClass:[NSString class]]) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)VCRPrefsID);
    CFPreferencesAppSynchronize((__bridge CFStringRef)VCRPrefsID);
}

// Bundle-side diagnostics go into the same two keys the tweak's VCRDebugEvent() maintains, so one
// "Show Debug Log" shows trigger events, camera format and Telegram results together.
static void VCRPrefsLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *message = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSString *existing = VCRPrefsValue(@"debugEvents");
    for (NSString *line in [existing componentsSeparatedByString:@"\n"]) {
        if (line.length > 0) [lines addObject:line];
    }
    [lines addObject:message];
    while (lines.count > 8) [lines removeObjectAtIndex:0];
    VCRPrefsSet(@"debugEvents", [lines componentsJoinedByString:@"\n"]);
}

// Settings aborted while a choice row was tapped and rootHide left no crash report behind, so
// record the reason where it can actually be read: the same ring the tweak writes to, shown by
// "Show Debug Log". Keep the handler to plain C-level work only.
static void VCRPrefsRecordException(NSException *exception) {
    NSString *line = [NSString stringWithFormat:@"PREFS CRASH %@: %@", exception.name, exception.reason];
    NSString *existing = VCRPrefsValue(@"debugEvents");
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *item in [existing componentsSeparatedByString:@"\n"]) {
        if (item.length > 0) [lines addObject:item];
    }
    [lines addObject:line];
    NSArray<NSString *> *symbols = [exception.callStackSymbols subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)10, exception.callStackSymbols.count))];
    [lines addObject:[symbols componentsJoinedByString:@" | "]];
    while (lines.count > 12) [lines removeObjectAtIndex:0];
    VCRPrefsSet(@"debugEvents", [lines componentsJoinedByString:@"\n"]);
}

__attribute__((constructor)) static void VCRPrefsInstallExceptionHandler(void) {
    NSSetUncaughtExceptionHandler(&VCRPrefsRecordException);
}

@interface VCRRootListController : PSListController
@end

@interface VCRRootListController (Private)
- (void)vcrTryOpenURLs:(NSArray<NSString *> *)urls atIndex:(NSUInteger)index path:(NSString *)path;
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

// ---- Custom rows -------------------------------------------------------------------------
// PreferenceLoader's PSMultiValueSpecifier cells never persisted in this bundle (no camera* key
// ever reached the domain on device) and PreferenceLoader has no slider cell at all, so slider and
// choice rows are drawn here and written through setPreferenceValue:specifier:, which uses
// CFPreferences like the rest of the tweak.

// vcrDefault is optional: the plain `default` key of the specifier is used when it is absent.
- (id)vcrDefaultForSpecifier:(PSSpecifier *)specifier {
    id value = [specifier propertyForKey:@"vcrDefault"];
    return value ?: [specifier propertyForKey:@"default"];
}

- (id)vcrRawValueForKey:(NSString *)key fallback:(id)fallback {
    id value = VCRPrefsValue(key);
    return value ?: fallback;
}

- (void)vcrWriteValue:(id)value forSpecifier:(PSSpecifier *)specifier {
    [self setPreferenceValue:value specifier:specifier];
}

- (NSString *)vcrTitleForSpecifier:(PSSpecifier *)specifier {
    NSArray *titles = [specifier propertyForKey:@"vcrTitles"] ?: @[];
    NSArray *values = [specifier propertyForKey:@"vcrValues"] ?: @[];
    id current = [self vcrRawValueForKey:[specifier propertyForKey:@"vcrKey"]
                                fallback:[self vcrDefaultForSpecifier:specifier]];
    NSUInteger index = [values indexOfObject:current];
    if (index != NSNotFound && index < titles.count) return titles[index];
    id fallback = [self vcrDefaultForSpecifier:specifier];
    return fallback ? [NSString stringWithFormat:@"%@", fallback] : @"(default)";
}

- (UITableViewCell *)vcrCellContainingControl:(UIView *)control {
    for (UIView *view = control; view; view = view.superview) {
        if ([view isKindOfClass:[UITableViewCell class]]) return (UITableViewCell *)view;
    }
    return nil;
}

- (void)vcrSliderChanged:(UISlider *)slider {
    UITableViewCell *cell = [self vcrCellContainingControl:slider];
    UILabel *valueLabel = [cell.contentView viewWithTag:VCRSliderValueTag];
    double value = round(slider.value * 10.0) / 10.0;
    if (valueLabel) valueLabel.text = [NSString stringWithFormat:@"%.1fs", value];
}

// Written once per drag on touch-up rather than on every tick, so a drag does not post ~60
// preference changes into the tweak.
- (void)vcrSliderCommitted:(UISlider *)slider {
    UITableViewCell *cell = [self vcrCellContainingControl:slider];
    NSIndexPath *indexPath = cell ? [self.tableView indexPathForCell:cell] : nil;
    PSSpecifier *specifier = indexPath ? [self specifierAtIndexPath:indexPath] : nil;
    if (!specifier) return;
    double value = round(slider.value * 10.0) / 10.0;
    [self vcrWriteValue:@(value) forSpecifier:specifier];
    VCRPrefsLog(@"slider %@ = %.1fs", [specifier propertyForKey:@"vcrKey"], value);
}

- (UITableViewCell *)vcrSliderCellForTableView:(UITableView *)tableView specifier:(PSSpecifier *)specifier {
    static NSString *reuse = @"VCRSliderRow";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuse];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UILabel *label = [[UILabel alloc] init];
        label.font = [UIFont systemFontOfSize:14.0];
        label.tag = VCRSliderLabelTag;
        label.translatesAutoresizingMaskIntoConstraints = NO;

        UISlider *slider = [[UISlider alloc] init];
        slider.tag = VCRSliderControlTag;
        slider.continuous = YES;
        slider.translatesAutoresizingMaskIntoConstraints = NO;
        [slider addTarget:self action:@selector(vcrSliderChanged:) forControlEvents:UIControlEventValueChanged];
        [slider addTarget:self action:@selector(vcrSliderCommitted:)
         forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];

        UILabel *value = [[UILabel alloc] init];
        value.font = [UIFont monospacedDigitSystemFontOfSize:14.0 weight:UIFontWeightRegular];
        value.textAlignment = NSTextAlignmentRight;
        value.tag = VCRSliderValueTag;
        value.translatesAutoresizingMaskIntoConstraints = NO;

        [cell.contentView addSubview:label];
        [cell.contentView addSubview:slider];
        [cell.contentView addSubview:value];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16.0],
            [label.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [label.widthAnchor constraintEqualToConstant:130.0],
            [value.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16.0],
            [value.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [value.widthAnchor constraintEqualToConstant:58.0],
            [slider.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:8.0],
            [slider.trailingAnchor constraintEqualToAnchor:value.leadingAnchor constant:-8.0],
            [slider.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        ]];
    }

    NSNumber *minimum = [specifier propertyForKey:@"vcrMin"] ?: @0.2;
    NSNumber *maximum = [specifier propertyForKey:@"vcrMax"] ?: @5.0;
    double value = [[self vcrRawValueForKey:[specifier propertyForKey:@"vcrKey"]
                                   fallback:[self vcrDefaultForSpecifier:specifier]] doubleValue];
    if (!(value >= minimum.doubleValue)) value = minimum.doubleValue;
    if (value > maximum.doubleValue) value = maximum.doubleValue;

    UILabel *label = [cell.contentView viewWithTag:VCRSliderLabelTag];
    UISlider *slider = [cell.contentView viewWithTag:VCRSliderControlTag];
    UILabel *valueLabel = [cell.contentView viewWithTag:VCRSliderValueTag];
    label.text = [specifier propertyForKey:@"label"];
    slider.minimumValue = minimum.floatValue;
    slider.maximumValue = maximum.floatValue;
    slider.value = (float)value;
    valueLabel.text = [NSString stringWithFormat:@"%.1fs", value];
    return cell;
}

- (void)vcrPresentChoicesForSpecifier:(PSSpecifier *)specifier indexPath:(NSIndexPath *)indexPath {
    NSArray *titles = [specifier propertyForKey:@"vcrTitles"] ?: @[];
    NSArray *values = [specifier propertyForKey:@"vcrValues"] ?: @[];
    NSString *key = [specifier propertyForKey:@"vcrKey"];
    if (titles.count == 0 || titles.count != values.count || !key) return;

    id current = [self vcrRawValueForKey:key fallback:[self vcrDefaultForSpecifier:specifier]];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[specifier propertyForKey:@"label"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger i = 0; i < titles.count; i++) {
        NSString *title = titles[i];
        NSString *label = [values[i] isEqual:current] ? [@"\u2713 " stringByAppendingString:title] : title;
        id value = values[i];
        [sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self vcrWriteValue:value forSpecifier:specifier];
            VCRPrefsLog(@"choice %@ = %@", key, value);
            // reloadRows throws if the row count no longer matches; a full reload always works.
            @try {
                [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
            } @catch (__unused NSException *exception) {
                [self.tableView reloadData];
            }
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    // The popover anchor only matters on iPad, and Settings has aborted around this presentation
    // before, so keep it out of the way of the phone path entirely.
    if (self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        sheet.popoverPresentationController.sourceView = cell ?: self.view;
        sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    }
    @try {
        [self presentViewController:sheet animated:YES completion:nil];
    } @catch (NSException *exception) {
        VCRPrefsLog(@"choice sheet failed: %@ (%@)", exception.name, exception.reason);
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSString *kind = [specifier propertyForKey:@"vcrKind"];

    if ([kind isEqualToString:@"slider"]) {
        return [self vcrSliderCellForTableView:tableView specifier:specifier];
    }
    if ([kind isEqualToString:@"choice"]) {
        static NSString *reuse = @"VCRChoiceRow";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuse];
        cell.textLabel.text = [specifier propertyForKey:@"label"];
        cell.detailTextLabel.text = [self vcrTitleForSpecifier:specifier];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    return [super tableView:tableView cellForRowAtIndexPath:indexPath];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    if ([[specifier propertyForKey:@"vcrKind"] isEqualToString:@"choice"]) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [self vcrPresentChoicesForSpecifier:specifier indexPath:indexPath];
        return;
    }
    [super tableView:tableView didSelectRowAtIndexPath:indexPath];
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
    NSSet<NSString *> *mediaExtensions = [NSSet setWithArray:@[@"m4a", @"mp4", @"mov", @"jpg", @"jpeg", @"png"]];
    NSPredicate *mediaOnly = [NSPredicate predicateWithBlock:^BOOL(NSURL *url, __unused NSDictionary *bindings) {
        return [mediaExtensions containsObject:[url.pathExtension lowercaseString]];
    }];
    NSArray<NSURL *> *filtered = [files filteredArrayUsingPredicate:mediaOnly];
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
        return [NSString stringWithFormat:@"No recordings or photos found.\n\nPath:\n%@", VCRRecordingsDir];
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

// Open the recordings folder in Filza. Filza's URL scheme is not consistently documented,
// so try the known forms in order and fall back to showing / copying the path.
- (void)openRecordingsFolder {
    NSString *path = VCRRecordingsDir;
    NSArray<NSString *> *candidates = @[
        [@"filza://view" stringByAppendingString:path],
        [NSString stringWithFormat:@"filza://localhost%@", path],
        [NSString stringWithFormat:@"filza://%@", path],
    ];
    [self vcrTryOpenURLs:candidates atIndex:0 path:path];
}

- (void)vcrTryOpenURLs:(NSArray<NSString *> *)urls atIndex:(NSUInteger)index path:(NSString *)path {
    if (index >= urls.count) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Could not open Filza"
                                                                       message:[NSString stringWithFormat:@"Tried filza:// but nothing handled it.\n\nPath:\n%@", path]
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Copy Path" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [UIPasteboard generalPasteboard].string = path;
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    NSURL *url = [NSURL URLWithString:urls[index]];
    if (!url) { [self vcrTryOpenURLs:urls atIndex:index + 1 path:path]; return; }
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
        if (!success) [self vcrTryOpenURLs:urls atIndex:index + 1 path:path];
    }];
}

- (void)showRecordingPath {
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
                                                                     message:[NSString stringWithFormat:@"This will delete %lu media file(s) from:\n%@", (unsigned long)files.count, VCRRecordingsDir]
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

// Read back the tweak's trigger diagnostics. They live in CFPreferences rather than a file
// because SpringBoard's sandbox silently denies file writes from the injected dylib.
- (void)showDebugLog {
    NSString *loadedBundle = VCRPrefsValue(@"debugLastLoadBundle") ?: @"(never - tweak not injected)";
    NSString *loadedAt = VCRPrefsValue(@"debugLastLoadTime") ?: @"?";
    NSString *events = VCRPrefsValue(@"debugEvents") ?: @"(no events yet)";
    NSNumber *count = VCRPrefsValue(@"debugEventCount") ?: @0;

    NSString *message = [NSString stringWithFormat:@"injected into: %@\nloaded at: %@\nevents seen: %@\n\n%@",
                         loadedBundle, loadedAt, count, events];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Trigger Debug Log"
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copy All" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [UIPasteboard generalPasteboard].string = message;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)clearDebugLog {
    for (NSString *key in @[@"debugEvents", @"debugLastEvent", @"debugEventCount"]) {
        VCRPrefsSet(key, nil);
    }
    [self showAlertWithTitle:@"Debug Log" message:@"Cleared. Press the volume buttons, then reopen this."];
}

// The uploader lives in the tweak (SpringBoard), not in this bundle, so these buttons ask it to
// run - which also exercises the real code path instead of a copy of it.
- (void)showVolumeAPIDump {
    NSString *dump = VCRPrefsValue(@"debugVolumeAPI") ?: @"(not collected yet - respring with the latest build)";
    NSString *pressTypes = VCRPrefsValue(@"debugPressTypes") ?: @"(none)";
    NSString *volChanges = VCRPrefsValue(@"debugVolchg") ?: @"(none)";
    NSString *message = [NSString stringWithFormat:@"press types: %@\nvolume changes: %@\n\n%@", pressTypes, volChanges, dump];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Volume API (from SpringBoard)"
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copy All" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [UIPasteboard generalPasteboard].string = message;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)sendTelegramTest {
    notify_post("com.yourname.volumechordrecorder.telegramtest");
    [self showAlertWithTitle:@"Telegram"
                     message:@"Test requested. Open \"Show Debug Log\" in a few seconds: it reports sendMessage ok, or the API error (401 = bad token, 400 = bad chat id)."];
}

- (void)sendTelegramLatest {
    notify_post("com.yourname.volumechordrecorder.telegramsendlatest");
    [self showAlertWithTitle:@"Telegram"
                     message:@"Uploading the newest recording. See \"Show Debug Log\" for the result."];
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




- (void)setLivePassthroughNCTransparency {
    CFPreferencesSetAppValue(CFSTR("ncTransparencyEnabled"), kCFBooleanTrue, (__bridge CFStringRef)VCRPrefsID);
    CFPreferencesSetAppValue(CFSTR("ncLivePassthrough"), kCFBooleanTrue, (__bridge CFStringRef)VCRPrefsID);
    CFPreferencesSetAppValue(CFSTR("ncHideLockscreenWallpaper"), kCFBooleanTrue, (__bridge CFStringRef)VCRPrefsID);
    CFPreferencesSetAppValue(CFSTR("ncHideLockWallpaper"), kCFBooleanTrue, (__bridge CFStringRef)VCRPrefsID);
    CFPreferencesSetAppValue(CFSTR("ncUseSnapshotUnderlay"), kCFBooleanFalse, (__bridge CFStringRef)VCRPrefsID);
    CFPreferencesSetAppValue(CFSTR("ncProtectNotificationCards"), kCFBooleanTrue, (__bridge CFStringRef)VCRPrefsID);

    NSNumber *wallpaper = @0.0;
    NSNumber *blur = @0.04;
    NSNumber *dim = @0.0;
    CFPreferencesSetAppValue(CFSTR("ncWallpaperAlpha"), (__bridge CFPropertyListRef)wallpaper, (__bridge CFStringRef)VCRPrefsID);
    CFPreferencesSetAppValue(CFSTR("ncBlurAlpha"), (__bridge CFPropertyListRef)blur, (__bridge CFStringRef)VCRPrefsID);
    CFPreferencesSetAppValue(CFSTR("ncDimAlpha"), (__bridge CFPropertyListRef)dim, (__bridge CFStringRef)VCRPrefsID);
    CFPreferencesAppSynchronize((__bridge CFStringRef)VCRPrefsID);

    notify_post("com.yourname.volumechordrecorder.prefschanged");
    notify_post("com.yourname.volumechordrecorder.applyNCTransparency");
    _specifiers = nil;
    [self reloadSpecifiers];
    [self showAlertWithTitle:@"Live NC Passthrough Set"
                     message:@"Applied: Hide Lock Screen Wallpaper ON, Snapshot Fallback OFF, Wallpaper 0.00, Blur 0.04, Dim 0.00. This tries to keep the actual current SpringBoard/app surface visible. If a video app pauses rendering when fully covered, enable Snapshot Fallback or use a SpringBoard/home-screen video source."];
}

// Backward compatibility if an old plist still points to the old selector.
- (void)setCurrentScreenNCTransparency {
    [self setLivePassthroughNCTransparency];
}

- (void)setReadableNCTransparency {
    CFPreferencesSetAppValue(CFSTR("ncTransparencyEnabled"), kCFBooleanTrue, (__bridge CFStringRef)VCRPrefsID);
    CFPreferencesSetAppValue(CFSTR("ncProtectNotificationCards"), kCFBooleanTrue, (__bridge CFStringRef)VCRPrefsID);
    CFPreferencesSetAppValue(CFSTR("ncLivePassthrough"), kCFBooleanTrue, (__bridge CFStringRef)VCRPrefsID);
    CFPreferencesSetAppValue(CFSTR("ncHideLockscreenWallpaper"), kCFBooleanTrue, (__bridge CFStringRef)VCRPrefsID);
    CFPreferencesSetAppValue(CFSTR("ncHideLockWallpaper"), kCFBooleanTrue, (__bridge CFStringRef)VCRPrefsID);
    CFPreferencesSetAppValue(CFSTR("ncUseSnapshotUnderlay"), kCFBooleanFalse, (__bridge CFStringRef)VCRPrefsID);

    NSNumber *wallpaper = @0.0;
    NSNumber *blur = @0.16;
    NSNumber *dim = @0.18;
    CFPreferencesSetAppValue(CFSTR("ncWallpaperAlpha"), (__bridge CFPropertyListRef)wallpaper, (__bridge CFStringRef)VCRPrefsID);
    CFPreferencesSetAppValue(CFSTR("ncBlurAlpha"), (__bridge CFPropertyListRef)blur, (__bridge CFStringRef)VCRPrefsID);
    CFPreferencesSetAppValue(CFSTR("ncDimAlpha"), (__bridge CFPropertyListRef)dim, (__bridge CFStringRef)VCRPrefsID);
    CFPreferencesAppSynchronize((__bridge CFStringRef)VCRPrefsID);

    notify_post("com.yourname.volumechordrecorder.prefschanged");
    notify_post("com.yourname.volumechordrecorder.applyNCTransparency");
    _specifiers = nil;
    [self reloadSpecifiers];
    [self showAlertWithTitle:@"Readable NC Transparency Set"
                     message:@"Applied: Hide Lock Screen Wallpaper ON, Snapshot Fallback OFF, Wallpaper 0.00, Blur 0.16, Dim 0.18, Protect Notification Cards ON. Close and reopen Notification Center to test."];
}


- (void)vcrSetPrefKey:(NSString *)key value:(id)value {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)VCRPrefsID);
}

- (void)setLivePassthroughPreset {
    [self vcrSetPrefKey:@"ncTransparencyEnabled" value:@YES];
    [self vcrSetPrefKey:@"ncLivePassthrough" value:@YES];
    [self vcrSetPrefKey:@"ncHideLockscreenWallpaper" value:@YES];
    [self vcrSetPrefKey:@"ncHideLockWallpaper" value:@YES];
    [self vcrSetPrefKey:@"ncUseSnapshotUnderlay" value:@NO];
    [self vcrSetPrefKey:@"ncWallpaperAlpha" value:@0.0];
    [self vcrSetPrefKey:@"ncBlurAlpha" value:@0.08];
    [self vcrSetPrefKey:@"ncDimAlpha" value:@0.0];
    CFPreferencesAppSynchronize((__bridge CFStringRef)VCRPrefsID);
    notify_post("com.yourname.volumechordrecorder.prefschanged");
    notify_post("com.yourname.volumechordrecorder.applyNCTransparency");
    _specifiers = nil;
    [self reloadSpecifiers];
    [self showAlertWithTitle:@"Live Passthrough Preset"
                     message:@"Enabled live current-screen passthrough and disabled snapshot underlay. Close and pull down Notification Center again; respring if the old wallpaper layer is cached."];
}

- (void)applyNCTransparencyNow {
    CFPreferencesAppSynchronize((__bridge CFStringRef)VCRPrefsID);
    notify_post("com.yourname.volumechordrecorder.applyNCTransparency");
    notify_post("com.yourname.volumechordrecorder.prefschanged");
    [self showAlertWithTitle:@"Applied" message:@"Notification Center transparency preferences were sent to SpringBoard. If the current shade does not update immediately, close and reopen Notification Center or respring."];
}

@end
