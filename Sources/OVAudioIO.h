/* Decoding of any audio/video file AVFoundation can read into a float32 WAV (task 6.5). AVFoundation and CoreMedia, no AppKit. */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    double sampleRate;          // 0 = as in the file; capped at 96000
    BOOL mono;                  // YES = downmix to one channel
    NSTimeInterval maxSeconds;  // 0 = no limit
} OVDecodeOptions;

extern NSErrorDomain const OVAudioIOErrorDomain;
enum { OVAudioIONoAudio = 1, OVAudioIOUnsupported = 2, OVAudioIOTooLong = 3, OVAudioIOEmpty = 4, OVAudioIOWriteFailed = 5 };

/// Any audio or video file AVFoundation reads -> float32 WAV. Atomic: on error `dstWav` does not exist.
BOOL OVDecodeAudio(NSString *src, NSString *dstWav, OVDecodeOptions opts, double *_Nullable seconds, NSError *_Nullable *_Nullable error);

typedef NS_ENUM(NSInteger, OVMediaKind) { OVMediaUnknown, OVMediaAudio, OVMediaVideo };
/// By AVAsset contents: a video track means Video; otherwise an audio track means Audio.
OVMediaKind OVMediaKindOfFile(NSString *path);
/// mp4 mov m4v (for open panels).
NSArray<NSString *> *OVVideoExtensions(void);

NS_ASSUME_NONNULL_END
