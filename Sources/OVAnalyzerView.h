#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const OVAnalyzerErrorDomain;

/// Spectrogram with optional pitch (f0) and spectral-centroid curves, drawn in Core Graphics. Colors come from OVColor and are resolved at draw time.
@interface OVAnalyzerView : NSView
/// result is the dictionary of the `analyze_audio` command; the .u8 path is inside it. The file size must equal cols * rows.
/// On failure the view keeps what it showed before and `error` says why.
- (BOOL)loadResult:(NSDictionary *)result error:(NSError *_Nullable *_Nullable)error;
@property (nonatomic) BOOL showsPitch, showsCentroid;                 // curves over the spectrogram (pitch on, centroid off by default)
@property (nonatomic) NSTimeInterval position;                        // playback line
@property (nonatomic, copy, nullable) void (^onSeek)(NSTimeInterval t);
/// The pitch curve in view coordinates, one subpath per run of voiced frames (zeros break the line); NULL when there is none. Caller releases.
- (nullable CGPathRef)copyPitchPath CF_RETURNS_RETAINED;
@end

/// 8-bit spectrogram (row 0 = lowest frequency) as a cols x rows image with row 0 at the bottom. +1 (caller releases); NULL on a size mismatch.
CGImageRef _Nullable OVSpectrogramImage(NSData *u8, NSInteger cols, NSInteger rows, BOOL dark) CF_RETURNS_RETAINED;
/// 256-entry lookup built from the palette: background -> accentSoft -> accent -> text. Follows the current drawing appearance and palette.
NSColor *OVSpectrogramColor(uint8_t v);

NS_ASSUME_NONNULL_END
