#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// "Clipping at 0:12–0:13" for a region {start, end, kind, severity} of sample_check (seconds). A region that
/// starts and ends in the same second reads "Noise at 0:03"; hum (whole sample) reads "Mains hum".
NSString *OVRegionTooltip(NSDictionary *region);

/// What a sample_check advice code offers: @{@"text": sentence, @"button": title (optional), @"action": @"light"|@"dfn"
/// (optional, the Improve mode the button runs)}. nil for an unknown code.
NSDictionary *_Nullable OVAdviceInfo(NSString *code);

/// The `enhance` request for an Improve mode ("light" | "dfn" | "music"). strengthDb is clamped to 1…30.
/// `engineReady`: DeepFilterNet / the music-removal engine is installed (ignored for "light"). When it is not,
/// returns nil and sets *action to @"download" (the page then offers the download instead of running).
NSDictionary *_Nullable OVEnhanceRequest(NSString *mode, double strengthDb, NSString *audio, NSString *out,
                                         BOOL engineReady, NSString *_Nullable *_Nullable action);

/// Labels for one row of compare_samples' result: any of "Duplicate" (a later copy of an earlier sample),
/// "Much quieter" (6 dB under the median), "Noisier" (10 dB less noise margin than the median).
NSArray<NSString *> *OVCompareFlags(NSDictionary *result, NSUInteger index);

/// [[min, max], …] with `count` buckets in -1…1 from an audio file, nil when it cannot be read.
NSArray<NSArray<NSNumber *> *> *_Nullable OVWaveformPeaksForFile(NSString *path, NSUInteger count);

NS_ASSUME_NONNULL_END
