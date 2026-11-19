/* Cutting a voice sample down to a chosen part, and the selection math behind the waveform's trim handles. Foundation and AVFoundation, no AppKit. */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const OVTrimErrorDomain;
enum { OVTrimBadRange = 1, OVTrimCannotRead = 2, OVTrimWriteFailed = 3 };

/// The shortest part a selection may keep, in seconds.
extern const NSTimeInterval OVTrimMinKeep;
/// Fade in and out at the cut edges, in seconds (avoids a click).
extern const NSTimeInterval OVTrimDefaultFade;

/// New start for a selection [start, end] in a file `duration` long: 0 … end - minKeep. A NaN start becomes 0.
NSTimeInterval OVClampTrimStart(NSTimeInterval start, NSTimeInterval end, NSTimeInterval duration, NSTimeInterval minKeep);
/// New end: start + minKeep … duration. A NaN end becomes the duration.
NSTimeInterval OVClampTrimEnd(NSTimeInterval start, NSTimeInterval end, NSTimeInterval duration, NSTimeInterval minKeep);

/// Keeps [start, end] of `src` (any file AVAudioFile reads) and writes it to `dst` as 16-bit PCM WAV (24-bit when the
/// source has 24), with the source's sample rate and channel count and a `fade` (seconds) in and out. Atomic: written to
/// "<dst>.part.wav", then moved; on error `dst` is untouched and no .part file is left. Refuses a range that is not inside
/// the file or keeps less than OVTrimMinKeep.
BOOL OVTrimAudioFile(NSString *src, NSString *dst, NSTimeInterval start, NSTimeInterval end, NSTimeInterval fade, NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
