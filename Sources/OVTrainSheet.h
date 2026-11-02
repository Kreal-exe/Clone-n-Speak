#import <Cocoa/Cocoa.h>
#import "OVStore.h"

NS_ASSUME_NONNULL_BEGIN

/// Pronunciation training of one voice in one language, as a sheet: the numbers of every round (pronunciation and
/// likeness), each round to listen to and pick by ear, a native narrator through Seed-VC when it is downloaded.
@interface OVTrainSheet : NSWindowController
/// `text`: what is on the Speech page — languages without built-in phrases learn on its first sentences.
+ (void)showForVoice:(OVVoice *)voice language:(NSString *)language text:(NSString *)text window:(NSWindow *)window;
@end

NS_ASSUME_NONNULL_END
