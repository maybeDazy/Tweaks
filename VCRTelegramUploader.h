#import <Foundation/Foundation.h>

// Tweak.xm is Logos, so it compiles as Objective-C++ while this implementation is plain C/ObjC.
// Without the extern "C" guard the declarations take C++ linkage and the tweak fails to link with
// "Undefined symbols ... __Z19VCRTelegramSendFileP5NSURLP8NSString...".
#ifdef __cplusplus
extern "C" {
#endif

typedef void (^VCRTelegramLogBlock)(NSString *message);

FOUNDATION_EXPORT NSString * const VCRTelegramPrefsDomain;

// Reports upload outcomes through one logger so the tweak can route them into its CFPreferences
// debug log ("Show Debug Log" in Settings).
void VCRTelegramSetLogger(VCRTelegramLogBlock log);

BOOL VCRTelegramIsEnabled(void);
BOOL VCRTelegramWantsKind(NSString *kind);

// "audio" | "video" | "photo" | anything else -> "document".
NSString *VCRTelegramKindForPath(NSString *path);

// Schedules the upload and returns YES when a request was started. Completion is reported through
// the logger; a file over the 50 MB bot-API limit is skipped and logged.
BOOL VCRTelegramSendFile(NSURL *fileURL, NSString *kind, VCRTelegramLogBlock log);

void VCRTelegramSendText(NSString *text, VCRTelegramLogBlock log);

#ifdef __cplusplus
}
#endif
