#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const OVRuntimeDidChangeNotification;
extern NSNotificationName const OVLogNotification; // userInfo: @"line"

typedef NS_ENUM(NSInteger, OVRuntimeState) {
    OVRuntimeUnknown,
    OVRuntimeChecking,
    OVRuntimeReady,
    OVRuntimeMissing,
    OVRuntimeInstalling,
    OVRuntimeFailed,
};

/// Runs a process and streams its combined output line by line (on the main queue).
NSTask *_Nullable OVRunTask(NSString *path, NSArray<NSString *> *args, NSDictionary *_Nullable env,
                            void (^_Nullable onLine)(NSString *line),
                            void (^_Nullable done)(int status));

/// Finds a Python environment with OmniVoice (own or VoiceStudio's) or installs one.
@interface OVRuntime : NSObject
+ (instancetype)shared;

@property (readonly) OVRuntimeState state;
@property (readonly, nullable) NSString *pythonPath;
@property (readonly, nullable) NSString *sourceName;      // "OmniVoice UA" / "VoiceStudio"
@property (readonly, nullable) NSDictionary *info;         // python / mlx / mlx-audio versions, metal
@property (readonly, copy) NSString *stepTitle;            // current install step
@property (readonly) double progress;                      // 0…1, <0 = indeterminate
@property (readonly, nullable, copy) NSString *errorText;
@property (readonly) NSArray<NSDictionary *> *candidates;  // every probed interpreter: path, ok, source

/// User-chosen interpreter (overrides auto-detection). nil = auto.
@property (nullable, copy) NSString *customPython;

- (void)detect;
- (void)install;
- (void)cancelInstall;
- (void)log:(NSString *)line;
/// uv (downloaded into the app folder or found on the system) and the environment it runs with.
- (nullable NSString *)findUV;
- (NSDictionary *)uvEnv;
@end

NS_ASSUME_NONNULL_END
