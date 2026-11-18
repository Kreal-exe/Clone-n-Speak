// Audio side of the Realtime page: microphone (an input AUHAL on the chosen device) -> 48 kHz mono blocks -> Unix
// socket of cns_realtime.py -> replies -> ring -> AVAudioSourceNode on the chosen output device.
//
// Threads: the capture callback and the render callback are real-time threads: they touch only the preallocated C
// state (OVRtRing / OVRtAssembler / atomics), never a lock, an allocation or the Objective-C runtime. One sender
// thread (blocks -> socket) and one receiver thread (socket -> output ring) do the socket work.
// Nothing is recorded or kept: audio lives in the rings for a few hundred milliseconds.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "OVAudioDevices.h"
#import "OVRtRing.h"

NS_ASSUME_NONNULL_BEGIN

@interface OVRealtimeIO : NSObject
/// blockSeconds is rounded to a multiple of 10 ms (OVRtBlockFrames) and must equal the engine's block_s.
- (instancetype)initWithInput:(OVAudioDevice *)input output:(OVAudioDevice *)output blockSeconds:(double)blockSeconds;

/// Microphone permission of this app. +requestMicrophoneAccess: asks (the system dialog names Clone'n'Speak) and calls
/// back on the main queue.
+ (AVAuthorizationStatus)microphoneStatus;
+ (void)requestMicrophoneAccess:(void (^)(BOOL granted))done;

@property (nonatomic) BOOL monitorOwnVoice;                     // mixes the unprocessed microphone into the output
@property (readonly) uint32_t blockFrame;
/// Hardware latency of the two devices, milliseconds (Latency + SafetyOffset + BufferFrameSize + StreamLatency each).
@property (readonly) double inputHardwareMs, outputHardwareMs;
/// Called on the main queue, once, when the session breaks (socket closed, engine failed, ...). The text says what to do.
@property (nonatomic, copy, nullable) void (^onError)(NSString *message);

/// Connects to the engine's socket, retrying until `timeout` (the model needs 3-15 s to load); completion on main.
- (void)connectToSocket:(NSString *)path timeout:(NSTimeInterval)timeout completion:(void (^)(NSString *_Nullable error))done;
/// Starts the microphone and the output (after a successful connect). Returns NO + text on failure.
- (BOOL)startAudio:(NSString *_Nullable *_Nullable)error;
/// Graceful end: sends quit, stops both devices, closes the socket. Safe to call twice.
- (void)stop;
@property (readonly) BOOL running;

/// {"set": changes} to the engine (pitch, index_rate, protect, silent_threshold).
- (void)sendSet:(NSDictionary<NSString *, NSNumber *> *)changes;

/// Call from a timer while running: ends the session (onError) when the microphone delivers nothing for 2 s, its capture fails or its permission is revoked.
- (void)checkHealth;
/// Peak of the microphone since the last call, 0...1 (resets).
- (float)takeInputLevel;
/// p50 / p95 of capture -> playback in ms (block time included), the sample count, our own dropped blocks plus the
/// blocks the engine reported dropped, and the output underruns.
- (void)getP50:(double *)p50 p95:(double *)p95 count:(uint64_t *)count dropped:(uint64_t *)dropped underruns:(uint64_t *)underruns;
@end

NS_ASSUME_NONNULL_END
