#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Batch speech as a sheet: a text file (txt, md, srt) or pasted text, how to split it, one voice / language / preset
/// for all items, the folder for the audio files and the progress of the "batch" job. Closing the sheet does not stop the job.
@interface OVBatchSheet : NSWindowController
+ (void)showInWindow:(NSWindow *)window;
@end

NS_ASSUME_NONNULL_END
