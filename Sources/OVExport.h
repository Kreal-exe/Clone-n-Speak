#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, OVExportFormat) { OVExportWAV, OVExportM4A /*AAC*/, OVExportFLAC, OVExportALAC /*.m4a, lossless*/, OVExportMP3, OVExportOGG };

extern NSErrorDomain const OVExportErrorDomain;

/// Native export of a WAV to WAV/M4A/FLAC/ALAC (AVFoundation) and MP3/OGG (ffmpeg through NSTask, when present).
/// Foundation + AVFoundation only: no AppKit, so it is testable on its own.
@interface OVExport : NSObject
/// @[@{@"id": @"wav", @"title", @"ext", @"lossless": @NO/YES, @"available": @YES, @"reason": nullable}] in enum order.
+ (NSArray<NSDictionary *> *)formats;
/// Unknown identifier → WAV.
+ (OVExportFormat)formatForIdentifier:(NSString *)identifier;
/// ~/.local/bin, /opt/homebrew/bin, /usr/local/bin, then `command -v ffmpeg` through /bin/sh -lc. Cached until +resetFFmpegCache.
/// Test hook: the environment variable CNS_FFMPEG_DIRS (colon-separated) replaces the whole search (no shell lookup).
+ (nullable NSString *)ffmpegPath;
+ (void)resetFFmpegCache;
/// src is a WAV (any rate/channels). dst without an extension gets one; an existing file is never overwritten
/// ("name 2.ext"). Returns the final path.
/// quality: M4A and MP3 — kbps; OGG — 0…10; negative (or 0 for the kbps formats) means the default
/// (M4A 192, MP3 192, OGG 5). WAV, FLAC and ALAC ignore it.
+ (nullable NSString *)exportFile:(NSString *)src to:(NSString *)dst format:(OVExportFormat)f quality:(NSInteger)quality error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
