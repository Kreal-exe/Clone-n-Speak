#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const OVNativeAccentDidChangeNotification;

/// Native-accent speech, an optional download (~2.7 GB): the model's own voice speaks the text like a native speaker
/// and Seed-VC (GPL-3.0, its own PyTorch environment, run as a separate program) gives it the voice of the sample.
@interface OVNativeAccent : NSObject
+ (instancetype)shared;
@property (readonly) BOOL installed, installing;
@property (readonly) double progress;
@property (readonly, copy) NSString *step;
@property (readonly, nullable, copy) NSString *error;
/// What synth sends as "native_accent" for a voice that has it switched on (Voices page); nil until installed.
- (nullable NSDictionary *)workerSpec;
- (void)install;
- (BOOL)remove:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
