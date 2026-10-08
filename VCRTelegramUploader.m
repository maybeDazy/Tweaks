#import "VCRTelegramUploader.h"

NSString * const VCRTelegramPrefsDomain = @"com.yourname.volumechordrecorder";

// Bot API hard limit for uploading a file. 4K/60 clips pass this in seconds, so the size is checked
// before the request instead of discovering it as a rejected upload.
static const unsigned long long VCRTelegramMaxUploadBytes = 50ULL * 1024ULL * 1024ULL;

static VCRTelegramLogBlock gVCRTGLogger = nil;

void VCRTelegramSetLogger(VCRTelegramLogBlock log) { gVCRTGLogger = [log copy]; }

static id VCRTGPref(NSString *key, id fallback) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)VCRTelegramPrefsDomain);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)VCRTelegramPrefsDomain);
    if (!value) return fallback;
    return CFBridgingRelease(value);
}

static NSString *VCRTGTrimmedPref(NSString *key) {
    NSString *value = [VCRTGPref(key, @"") isKindOfClass:[NSString class]] ? VCRTGPref(key, @"") : @"";
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *VCRTGToken(void) { return VCRTGTrimmedPref(@"telegramBotToken"); }
static NSString *VCRTGChat(void)  { return VCRTGTrimmedPref(@"telegramChatID"); }

NSString *VCRTelegramKindForPath(NSString *path) {
    NSString *extension = path.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"m4a"]) return @"audio";
    if ([extension isEqualToString:@"mp4"] || [extension isEqualToString:@"mov"]) return @"video";
    if ([extension isEqualToString:@"jpg"] || [extension isEqualToString:@"jpeg"] || [extension isEqualToString:@"png"]) return @"photo";
    return @"document";
}

BOOL VCRTelegramWantsKind(NSString *kind) {
    if ([kind isEqualToString:@"audio"]) return [VCRTGPref(@"telegramSendAudio", @YES) boolValue];
    if ([kind isEqualToString:@"video"]) return [VCRTGPref(@"telegramSendVideo", @YES) boolValue];
    if ([kind isEqualToString:@"photo"]) return [VCRTGPref(@"telegramSendPhoto", @NO) boolValue];
    return NO;
}

BOOL VCRTelegramIsEnabled(void) {
    return [VCRTGPref(@"telegramEnabled", @NO) boolValue] && VCRTGToken().length > 0 && VCRTGChat().length > 0;
}

static void VCRTGLog(VCRTelegramLogBlock log, NSString *format, ...) {
    VCRTelegramLogBlock handler = log ?: gVCRTGLogger;
    if (!handler) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    handler(message);
}

static void VCRTGReportResult(NSDictionary *json, NSInteger status, NSString *method, VCRTelegramLogBlock log) {
    if (status == 200 && [json[@"ok"] boolValue]) {
        VCRTGLog(log, @"telegram: %@ ok", method);
        return;
    }
    NSString *description = [json[@"description"] isKindOfClass:[NSString class]] ? json[@"description"] : @"(no description)";
    VCRTGLog(log, @"telegram: %@ failed status=%ld %@", method, (long)status, description);
}

static void VCRTGHandleResponse(NSData *data, NSURLResponse *response, NSError *error, NSString *method, VCRTelegramLogBlock log) {
    if (error) {
        VCRTGLog(log, @"telegram: %@ failed %@", method, error.localizedDescription);
        return;
    }
    NSInteger status = [(NSHTTPURLResponse *)response statusCode];
    NSDictionary *json = nil;
    if (data.length) json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    VCRTGReportResult([json isKindOfClass:[NSDictionary class]] ? json : nil, status, method, log);
}

void VCRTelegramSendText(NSString *text, VCRTelegramLogBlock log) {
    NSString *token = VCRTGToken();
    NSString *chat = VCRTGChat();
    if (token.length == 0 || chat.length == 0) {
        VCRTGLog(log, @"telegram: not configured (token or chat id missing)");
        return;
    }

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.telegram.org/bot%@/sendMessage", token]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *payload = @{ @"chat_id": chat, @"text": text ?: @"VolumeChordRecorder test" };
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    request.HTTPBody = body;

    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
    NSURLSessionUploadTask *task = [session uploadTaskWithRequest:request fromData:body
                                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        VCRTGHandleResponse(data, response, error, @"sendMessage", log);
    }];
    [task resume];
}

BOOL VCRTelegramSendFile(NSURL *fileURL, NSString *kind, VCRTelegramLogBlock log) {
    if (!fileURL) return NO;
    if (!VCRTelegramIsEnabled()) {
        VCRTGLog(log, @"telegram: disabled or unconfigured, skipping %@", fileURL.lastPathComponent);
        return NO;
    }
    if (!VCRTelegramWantsKind(kind)) {
        VCRTGLog(log, @"telegram: kind %@ turned off, skipping", kind);
        return NO;
    }

    NSNumber *size = nil;
    [fileURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    unsigned long long bytes = size.unsignedLongLongValue;
    if (bytes == 0) {
        VCRTGLog(log, @"telegram: %@ is missing or empty", fileURL.lastPathComponent);
        return NO;
    }
    if (bytes > VCRTelegramMaxUploadBytes) {
        VCRTGLog(log, @"telegram: skipped %@ (%.1f MB over the %.0f MB bot limit)",
                 fileURL.lastPathComponent, bytes / 1048576.0, VCRTelegramMaxUploadBytes / 1048576.0);
        return NO;
    }

    NSString *method = @"sendDocument";
    NSString *field = @"document";
    if ([kind isEqualToString:@"audio"]) { method = @"sendAudio"; field = @"audio"; }
    else if ([kind isEqualToString:@"video"]) { method = @"sendVideo"; field = @"video"; }
    else if ([kind isEqualToString:@"photo"]) { method = @"sendPhoto"; field = @"photo"; }

    NSString *boundary = @"----VolumeChordRecorderBoundary";
    NSString *chat = VCRTGChat();

    // The multipart body goes to a temp file rather than NSMutableData so a large clip does not
    // have to be held in memory (twice) on the way out.
    NSMutableData *prologue = [NSMutableData data];
    [prologue appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n%@\r\n", boundary, chat] dataUsingEncoding:NSUTF8StringEncoding]];
    [prologue appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\n%@\r\n", boundary, fileURL.lastPathComponent] dataUsingEncoding:NSUTF8StringEncoding]];
    [prologue appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"%@\"; filename=\"%@\"\r\nContent-Type: application/octet-stream\r\n\r\n", boundary, field, fileURL.lastPathComponent] dataUsingEncoding:NSUTF8StringEncoding]];
    NSData *epilogue = [[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding];

    NSString *bodyPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"VCRTelegramBody.tmp"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:bodyPath error:nil];
    if (![fm createFileAtPath:bodyPath contents:prologue attributes:nil]) {
        VCRTGLog(log, @"telegram: cannot create the multipart body file");
        return NO;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:bodyPath];
    NSFileHandle *source = [NSFileHandle fileHandleForReadingAtPath:fileURL.path];
    if (!handle || !source) {
        [handle closeFile];
        [source closeFile];
        [fm removeItemAtPath:bodyPath error:nil];
        VCRTGLog(log, @"telegram: cannot read %@", fileURL.path);
        return NO;
    }

    @try {
        [handle seekToEndOfFile];   // append after the prologue written by createFileAtPath
        while (YES) {
            @autoreleasepool {
                NSData *chunk = [source readDataOfLength:1 << 20];
                if (chunk.length == 0) break;
                [handle writeData:chunk];
            }
        }
        [handle writeData:epilogue];
    } @catch (NSException *exception) {
        [handle closeFile];
        [source closeFile];
        [fm removeItemAtPath:bodyPath error:nil];
        VCRTGLog(log, @"telegram: building the body failed %@", exception.reason);
        return NO;
    }
    [handle closeFile];
    [source closeFile];

    unsigned long long bodyBytes = [[fm attributesOfItemAtPath:bodyPath error:nil] fileSize];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.telegram.org/bot%@/%@", VCRTGToken(), method]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"%llu", bodyBytes] forHTTPHeaderField:@"Content-Length"];

    VCRTGLog(log, @"telegram: uploading %@ (%llu bytes) via %@", fileURL.lastPathComponent, bodyBytes, method);

    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
    NSURLSessionUploadTask *task = [session uploadTaskWithRequest:request fromFile:[NSURL fileURLWithPath:bodyPath]
                                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        [[NSFileManager defaultManager] removeItemAtPath:bodyPath error:nil];
        VCRTGHandleResponse(data, response, error, method, log);
    }];
    [task resume];
    return YES;
}
