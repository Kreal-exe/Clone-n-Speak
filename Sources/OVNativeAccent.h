#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const OVNativeAccentDidChangeNotification;

/// The native narrator of pronunciation training, an optional download (~2.7 GB): a native speaker's reading is given
/// the voice of the sample by Seed-VC (GPL-3.0, its own PyTorch environment, run as a separate program).
@interface OVNativeAccent : NSObject
+ (instancetype)shared;
@property (readonly) BOOL installed, installing;
@property (readonly) double progress;
@property (readonly, copy) NSString *step;
@property (readonly, nullable, copy) NSString *error;
/// What training sends as "native" (Seed-VC's Python and folder); nil until installed.
- (nullable NSDictionary *)workerSpec;
- (void)install;
- (BOOL)remove:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
